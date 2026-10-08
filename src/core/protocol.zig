//! Managed, bounded Content-Length stdio transport for LSP and DAP.
//! All pipe I/O runs off the editor thread. A full outgoing queue is an
//! explicit failure; a full incoming queue stalls the reader (back-pressure)
//! and only a consumer that stops taking messages ends the session.
const std = @import("std");
const Allocator = std.mem.Allocator;
const jobs = @import("jobs.zig");
const windows = @import("builtin").os.tag == .windows;
pub const max_frame = 16 * 1024 * 1024;

pub const Queue = struct {
    messages: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    pub const max_messages = 256;
    pub const max_bytes = 32 * 1024 * 1024;

    /// Whether one more message of `len` bytes fits under both limits.
    pub fn hasRoom(self: *const Queue, len: usize) bool {
        return self.messages.items.len < max_messages and len <= max_bytes - self.bytes;
    }
    pub fn push(self: *Queue, allocator: Allocator, message: []u8) !void {
        if (!self.hasRoom(message.len)) return error.ProtocolOverflow;
        try self.messages.append(allocator, message);
        self.bytes += message.len;
    }
    pub fn pop(self: *Queue) ?[]u8 {
        if (self.messages.items.len == 0) return null;
        const message = self.messages.orderedRemove(0);
        self.bytes -= message.len;
        return message;
    }
    fn deinit(self: *Queue, allocator: Allocator) void {
        for (self.messages.items) |message| allocator.free(message);
        self.messages.deinit(allocator);
    }
};

pub const Peer = struct {
    allocator: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    future: ?std.Io.Future(void) = null,
    mutex: std.Io.Mutex = .init,
    outgoing_ready: std.Io.Event = .unset,
    /// Set by `take`; the reader waits on it while `incoming` is full.
    incoming_space: std.Io.Event = .unset,
    incoming: Queue = .{},
    outgoing: Queue = .{},
    stderr_text: std.ArrayList(u8) = .empty,
    failure: ?anyerror = null,
    done: bool = false,
    closing: bool = false,
    /// Called from the peer's threads — and from `send` on the editor
    /// thread — never while `mutex` is held: a wake may block.
    wake: ?*const fn () void = null,
    /// How long the reader waits for room in a full `incoming` queue before
    /// declaring the consumer stuck (`ProtocolOverflow`). Generous: a
    /// blocking native file dialog stalls the GUI thread legitimately.
    consumer_timeout_ms: i64 = 30_000,

    pub fn start(allocator: Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, wake: ?*const fn () void) !*Peer {
        if (argv.len == 0 or argv[0].len == 0) return error.MissingProgram;
        const self = try allocator.create(Peer);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .arena = std.heap.ArenaAllocator.init(allocator), .argv = undefined, .cwd = null, .wake = wake };
        errdefer self.arena.deinit();
        const args = try self.arena.allocator().alloc([]const u8, argv.len);
        for (argv, args) |arg, *owned| owned.* = try self.arena.allocator().dupe(u8, arg);
        self.argv = args;
        if (cwd) |path| self.cwd = try self.arena.allocator().dupe(u8, path);
        self.future = try io.concurrent(run, .{self});
        return self;
    }

    /// A peer with no process behind it (tests and fakes): `send` queues
    /// into `outgoing`, and messages pushed into `incoming` come out of `take`.
    pub fn detached(allocator: Allocator, io: std.Io) !*Peer {
        const self = try allocator.create(Peer);
        self.* = .{ .allocator = allocator, .io = io, .arena = std.heap.ArenaAllocator.init(allocator), .argv = &.{}, .cwd = null };
        return self;
    }

    pub fn deinit(self: *Peer) void {
        self.setWake(null);
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.mutex.unlock(self.io);
        if (self.future) |*future| future.cancel(self.io);
        self.incoming.deinit(self.allocator);
        self.outgoing.deinit(self.allocator);
        self.stderr_text.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn setWake(self: *Peer, wake: ?*const fn () void) void {
        self.mutex.lockUncancelable(self.io);
        self.wake = wake;
        self.mutex.unlock(self.io);
    }

    pub fn stopped(self: *Peer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.done or self.failure != null;
    }

    pub fn errorState(self: *Peer) ?anyerror {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failure;
    }

    pub fn stderrAlloc(self: *Peer, allocator: Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return allocator.dupe(u8, self.stderr_text.items);
    }

    pub fn send(self: *Peer, body: []const u8) !void {
        if (body.len == 0 or body.len > max_frame) return error.ProtocolOverflow;
        const frame = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        errdefer self.allocator.free(frame);
        self.mutex.lockUncancelable(self.io);
        if (self.closing or self.done or self.failure != null) {
            self.mutex.unlock(self.io);
            return error.NotRunning;
        }
        // The editor thread must never block here: a full outgoing queue fails.
        self.outgoing.push(self.allocator, frame) catch |err| {
            self.failure = err;
            const wake = self.wake;
            self.mutex.unlock(self.io);
            if (wake) |f| f();
            return err;
        };
        self.outgoing_ready.set(self.io);
        self.mutex.unlock(self.io);
    }

    pub fn take(self: *Peer) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const message = self.incoming.pop() orelse return null;
        self.incoming_space.set(self.io);
        return message;
    }

    /// Messages are waiting for `take`.
    pub fn hasIncoming(self: *Peer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.incoming.messages.items.len > 0;
    }

    fn failed(self: *Peer, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        const wake = if (self.closing) null else blk: {
            self.failure = err;
            break :blk self.wake;
        };
        self.mutex.unlock(self.io);
        if (wake) |f| f();
    }

    fn run(self: *Peer) void {
        self.runProcess() catch |err| self.failed(err);
        self.mutex.lockUncancelable(self.io);
        self.done = true;
        const wake = self.wake;
        self.mutex.unlock(self.io);
        if (wake) |f| f();
    }

    /// Queue one message read from the server (ownership passes to the
    /// queue; freed here on failure). A full queue applies back-pressure:
    /// the reader stops reading — the server blocks on its stdout pipe —
    /// until `take` makes room. Only a consumer that takes nothing for
    /// `consumer_timeout_ms` fails the session.
    fn deliver(self: *Peer, message: []u8) !void {
        errdefer self.allocator.free(message);
        const deadline: std.Io.Clock.Timestamp = .fromNow(self.io, .{ .raw = .fromMilliseconds(self.consumer_timeout_ms), .clock = .awake });
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const room = self.incoming.hasRoom(message.len);
            if (room) {
                self.incoming.push(self.allocator, message) catch |err| {
                    self.mutex.unlock(self.io);
                    return err;
                };
            } else self.incoming_space.reset(); // only this thread waits on it
            const wake = self.wake;
            self.mutex.unlock(self.io);
            if (wake) |f| f();
            if (room) return;
            if (deadline.durationFromNow(self.io).raw.nanoseconds <= 0) return error.ProtocolOverflow;
            self.incoming_space.waitTimeout(self.io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => {}, // deadline or a spurious wakeup: check again
                error.Canceled => |e| return e,
            };
        }
    }

    fn runProcess(self: *Peer) !void {
        var group = try jobs.ProcessGroup.init();
        defer group.deinit();
        var child = try jobs.spawnLocked(self.io, .{
            .argv = self.argv,
            .cwd = if (self.cwd) |path| .{ .path = path } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (windows) null else 0,
            .create_no_window = windows,
            .start_suspended = windows,
        });
        defer child.kill(self.io);
        try group.attach(&child);
        defer group.terminate();
        var writer = try self.io.concurrent(writeLoop, .{ self, child.stdin.? });
        defer writer.cancel(self.io);
        var stderr_reader = try self.io.concurrent(readStderr, .{ self, child.stderr.? });
        defer stderr_reader.cancel(self.io);
        var reader: FrameReader = .{ .io = self.io, .file = child.stdout.? };
        while (true) try self.deliver(try reader.read(self.allocator));
    }

    fn readStderr(self: *Peer, file: std.Io.File) void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = file.readStreaming(self.io, &.{&buffer}) catch return;
            if (count == 0) return;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const length = @min(count, (64 * 1024) -| self.stderr_text.items.len);
            self.stderr_text.appendSlice(self.allocator, buffer[0..length]) catch return;
        }
    }

    fn writeLoop(self: *Peer, file: std.Io.File) void {
        self.writeMessages(file) catch |err| self.failed(err);
    }
    fn writeMessages(self: *Peer, file: std.Io.File) !void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const message = self.outgoing.pop();
            if (message == null) self.outgoing_ready.reset();
            self.mutex.unlock(self.io);
            if (message) |bytes| {
                defer self.allocator.free(bytes);
                try file.writeStreamingAll(self.io, bytes);
            } else try self.outgoing_ready.wait(self.io);
        }
    }
};

pub const FrameReader = struct {
    io: std.Io,
    file: std.Io.File,
    buf: [8192]u8 = undefined,
    at: usize = 0,
    end: usize = 0,

    fn byte(self: *FrameReader) !u8 {
        if (self.at == self.end) {
            self.end = try self.file.readStreaming(self.io, &.{&self.buf});
            self.at = 0;
            if (self.end == 0) return error.EndOfStream;
        }
        defer self.at += 1;
        return self.buf[self.at];
    }

    pub fn read(self: *FrameReader, allocator: Allocator) ![]u8 {
        var header: [8192]u8 = undefined;
        var n: usize = 0;
        while (n < header.len) {
            header[n] = try self.byte();
            n += 1;
            if (n >= 4 and std.mem.eql(u8, header[n - 4 .. n], "\r\n\r\n")) break;
        } else return error.HeaderTooLarge;
        const size = try contentLength(header[0..n]);
        const body = try allocator.alloc(u8, size);
        errdefer allocator.free(body);
        var written: usize = 0;
        while (written < size) {
            if (self.at == self.end) {
                self.end = try self.file.readStreaming(self.io, &.{&self.buf});
                self.at = 0;
                if (self.end == 0) return error.EndOfStream;
            }
            const count = @min(size - written, self.end - self.at);
            @memcpy(body[written..][0..count], self.buf[self.at..][0..count]);
            self.at += count;
            written += count;
        }
        return body;
    }
};

pub fn contentLength(header: []const u8) !usize {
    var size: ?usize = null;
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "Content-Length")) {
            if (size != null) return error.InvalidHeader;
            size = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch return error.InvalidHeader;
        }
    }
    const length = size orelse return error.InvalidHeader;
    if (length == 0 or length > max_frame) return error.ProtocolOverflow;
    return length;
}

test "protocol framing and queue overflow fail explicitly without losing earlier messages" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 2), try contentLength("Content-Type: application/json\r\nContent-Length: 2\r\n\r\n"));
    try t.expectError(error.InvalidHeader, contentLength("Content-Length: 2\r\nContent-Length: 3\r\n\r\n"));
    try t.expectError(error.ProtocolOverflow, contentLength("Content-Length: 999999999\r\n\r\n"));
    var queue: Queue = .{};
    defer queue.deinit(t.allocator);
    for (0..256) |_| try queue.push(t.allocator, try t.allocator.dupe(u8, "original"));
    const extra = try t.allocator.dupe(u8, "extra");
    defer t.allocator.free(extra);
    try t.expectError(error.ProtocolOverflow, queue.push(t.allocator, extra));
    const first = queue.pop().?;
    defer t.allocator.free(first);
    try t.expectEqualStrings("original", first);
}

fn queuedIncoming(peer: *Peer) usize {
    peer.mutex.lockUncancelable(peer.io);
    defer peer.mutex.unlock(peer.io);
    return peer.incoming.messages.items.len;
}

const TestProducer = struct {
    fn run(peer: *Peer, count: usize, result: *?anyerror) void {
        for (0..count) |i| {
            var buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            const message = peer.allocator.dupe(u8, text) catch |err| {
                result.* = err;
                return;
            };
            peer.deliver(message) catch |err| {
                result.* = err;
                return;
            };
        }
    }
};

test "a full incoming queue stalls the reader instead of failing a busy session" {
    const t = std.testing;
    const peer = try Peer.detached(t.allocator, t.io);
    defer peer.deinit();
    var result: ?anyerror = null;
    var producer = try t.io.concurrent(TestProducer.run, .{ peer, 300, &result });
    defer producer.cancel(t.io);
    // Consumer busy for a while: the reader fills the queue, then waits.
    const start = std.Io.Clock.now(.awake, t.io).nanoseconds;
    while (queuedIncoming(peer) < Queue.max_messages and std.Io.Clock.now(.awake, t.io).nanoseconds - start < 5 * std.time.ns_per_s) {
        try std.Io.sleep(t.io, .fromMilliseconds(2), .awake);
    }
    try std.Io.sleep(t.io, .fromMilliseconds(50), .awake);
    try t.expectEqual(@as(usize, Queue.max_messages), queuedIncoming(peer));
    try t.expect(result == null and peer.errorState() == null);
    // Slow drain: every message arrives, in order, and the session survives.
    var received: usize = 0;
    while (received < 300 and std.Io.Clock.now(.awake, t.io).nanoseconds - start < 20 * std.time.ns_per_s) {
        const message = peer.take() orelse {
            try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
            continue;
        };
        defer t.allocator.free(message);
        var buf: [24]u8 = undefined;
        try t.expectEqualStrings(try std.fmt.bufPrint(&buf, "{d}", .{received}), message);
        received += 1;
        if (received % 64 == 0) try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    producer.await(t.io);
    try t.expectEqual(@as(usize, 300), received);
    try t.expect(result == null and peer.errorState() == null and !peer.stopped());
}

test "only a consumer that stops taking messages overflows the incoming queue" {
    const t = std.testing;
    const peer = try Peer.detached(t.allocator, t.io);
    defer peer.deinit();
    peer.consumer_timeout_ms = 30;
    var result: ?anyerror = null;
    TestProducer.run(peer, Queue.max_messages + 1, &result);
    try t.expectEqual(@as(?anyerror, error.ProtocolOverflow), result);
    // Nothing already queued is lost (the rejected message is freed).
    try t.expectEqual(@as(usize, Queue.max_messages), queuedIncoming(peer));
    const first = peer.take().?;
    defer t.allocator.free(first);
    try t.expectEqualStrings("0", first);
}

/// Wake probe: counts wakes that ran while their caller still held the
/// peer mutex (tryLock fails then — the probe runs on the locking thread).
const WakeProbe = struct {
    var peer: ?*Peer = null;
    var calls: usize = 0;
    var under_lock: usize = 0;

    fn wake() void {
        calls += 1;
        const p = peer orelse return;
        if (p.mutex.tryLock()) p.mutex.unlock(p.io) else under_lock += 1;
    }
};

test "peer wakes run after the peer mutex is released" {
    const t = std.testing;
    const peer = try Peer.detached(t.allocator, t.io);
    defer peer.deinit();
    peer.wake = &WakeProbe.wake;
    WakeProbe.peer = peer;
    WakeProbe.calls = 0;
    WakeProbe.under_lock = 0;
    defer WakeProbe.peer = null;
    try peer.deliver(try t.allocator.dupe(u8, "message"));
    for (0..Queue.max_messages) |_| try peer.send("x");
    try t.expectError(error.ProtocolOverflow, peer.send("x")); // outgoing never blocks
    try t.expectEqual(@as(?anyerror, error.ProtocolOverflow), peer.errorState());
    peer.failed(error.EndOfStream);
    try t.expectEqual(@as(usize, 3), WakeProbe.calls);
    try t.expectEqual(@as(usize, 0), WakeProbe.under_lock);
    const message = peer.take().?;
    defer t.allocator.free(message);
    try t.expectEqualStrings("message", message);
}
