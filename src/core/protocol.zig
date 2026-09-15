//! Managed, bounded Content-Length stdio transport for LSP and DAP.
//! All pipe I/O runs off the editor thread; overflow is an explicit failure.
const std = @import("std");
const Allocator = std.mem.Allocator;
const jobs = @import("jobs.zig");
const windows = @import("builtin").os.tag == .windows;
pub const max_frame = 16 * 1024 * 1024;

pub const Queue = struct {
    messages: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    pub fn push(self: *Queue, allocator: Allocator, message: []u8) !void {
        if (self.messages.items.len >= 256 or self.bytes + message.len > 32 * 1024 * 1024) return error.ProtocolOverflow;
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
    incoming: Queue = .{},
    outgoing: Queue = .{},
    stderr_text: std.ArrayList(u8) = .empty,
    failure: ?anyerror = null,
    done: bool = false,
    closing: bool = false,
    wake: ?*const fn () void = null,

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
        defer self.mutex.unlock(self.io);
        if (self.closing or self.done or self.failure != null) return error.NotRunning;
        self.outgoing.push(self.allocator, frame) catch |err| {
            self.failure = err;
            if (self.wake) |wake| wake();
            return err;
        };
        self.outgoing_ready.set(self.io);
    }

    pub fn take(self: *Peer) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.incoming.pop();
    }

    fn failed(self: *Peer, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.closing) {
            self.failure = err;
            if (self.wake) |wake| wake();
        }
    }

    fn run(self: *Peer) void {
        self.runProcess() catch |err| self.failed(err);
        self.mutex.lockUncancelable(self.io);
        self.done = true;
        if (self.wake) |wake| wake();
        self.mutex.unlock(self.io);
    }

    fn runProcess(self: *Peer) !void {
        var group = try jobs.ProcessGroup.init();
        defer group.deinit();
        var child = try std.process.spawn(self.io, .{
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
        while (true) {
            const message = try reader.read(self.allocator);
            errdefer self.allocator.free(message);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.incoming.push(self.allocator, message);
            if (self.wake) |wake| wake();
        }
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
