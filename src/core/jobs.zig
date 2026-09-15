//! Owned, cancellable subprocesses. Worker threads never invoke Lua or edit documents.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = builtin.os.tag == .windows;

pub const Options = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    environ: ?*const std.process.Environ.Map = null,
    output_limit: usize = 4 * 1024 * 1024,
    strict_output: bool = false,
};

pub const Snapshot = struct {
    stdout: []u8,
    stderr: []u8,
    code: ?u8,
    failure: ?anyerror,
    cancelled: bool,
    truncated: bool,
    done: bool,
    revision: u64,

    pub fn deinit(self: Snapshot, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const Job = struct {
    id: u64,
    allocator: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    options: Options,
    future: ?std.Io.Future(void) = null,
    mutex: std.Io.Mutex = .init,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    code: ?u8 = null,
    failure: ?anyerror = null,
    cancelled: bool = false,
    truncated: bool = false,
    done: bool = false,
    revision: u64 = 0,
    wake_fn: ?*const fn () void = null,

    pub fn snapshot(self: *Job, allocator: Allocator, consume: bool) !Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stdout = try allocator.dupe(u8, self.stdout.items);
        errdefer allocator.free(stdout);
        const stderr = try allocator.dupe(u8, self.stderr.items);
        if (consume) {
            self.stdout.clearRetainingCapacity();
            self.stderr.clearRetainingCapacity();
        }
        return .{ .stdout = stdout, .stderr = stderr, .code = self.code, .failure = self.failure, .cancelled = self.cancelled, .truncated = self.truncated, .done = self.done, .revision = self.revision };
    }

    pub fn isDone(self: *Job) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.done;
    }

    pub fn cancel(self: *Job) void {
        self.mutex.lockUncancelable(self.io);
        if (!self.done) self.cancelled = true;
        self.mutex.unlock(self.io);
        if (self.future) |*future| future.cancel(self.io);
        self.future = null;
    }

    fn changed(self: *Job) void {
        self.revision +%= 1;
        if (self.wake_fn) |wake| wake();
    }

    fn append(self: *Job, stream: usize, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const out = if (stream == 0) &self.stdout else &self.stderr;
        const available = self.options.output_limit -| (self.stdout.items.len + self.stderr.items.len);
        if (bytes.len > available and self.options.strict_output) return error.StreamTooLong;
        const count = @min(available, bytes.len);
        try out.appendSlice(self.allocator, bytes[0..count]);
        const newly_truncated = count < bytes.len and !self.truncated;
        self.truncated = self.truncated or count < bytes.len;
        if (count != 0 or newly_truncated) self.changed();
    }

    fn run(self: *Job) void {
        self.runProcess() catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.failure = err;
            self.mutex.unlock(self.io);
        };
        self.mutex.lockUncancelable(self.io);
        self.done = true;
        self.changed();
        self.mutex.unlock(self.io);
    }

    fn runProcess(self: *Job) !void {
        var group = try ProcessGroup.init();
        defer group.deinit();
        var child = try std.process.spawn(self.io, .{
            .argv = self.options.argv,
            .cwd = if (self.options.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = self.options.environ,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (windows) null else 0,
            .create_no_window = windows,
            .start_suspended = windows,
        });
        defer child.kill(self.io);
        try group.attach(&child);
        // Terminate the owned group before child.kill closes pipes on cancellation.
        defer if (child.id != null) group.terminate();
        var buffers: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(self.allocator, self.io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        while (true) {
            const finished = if (reader.fill(4096, .none)) |_| false else |err| switch (err) {
                error.EndOfStream => true,
                else => return err,
            };
            for (0..2) |i| {
                const stream = reader.reader(i);
                const bytes = stream.buffered();
                try self.append(i, bytes);
                stream.toss(bytes.len);
            }
            if (finished) break;
        }
        try reader.checkAnyError();
        const term = try child.wait(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        switch (term) {
            .exited => |code| self.code = code,
            else => self.failure = error.AbnormalExit,
        }
    }

    fn deinit(self: *Job) void {
        self.cancel();
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub const Manager = struct {
    allocator: Allocator,
    io: std.Io,
    jobs: std.ArrayList(*Job) = .empty,
    next_id: u64 = 1,
    wake_fn: ?*const fn () void = null,
    closing: bool = false,

    pub fn start(self: *Manager, options: Options) !u64 {
        if (self.closing) return error.ShuttingDown;
        if (options.argv.len == 0 or options.argv[0].len == 0) return error.MissingProgram;
        if (self.jobs.items.len >= 64) return error.TooManyJobs;
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .id = self.next_id, .allocator = self.allocator, .io = self.io, .arena = std.heap.ArenaAllocator.init(self.allocator), .options = options, .wake_fn = self.wake_fn };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        var owned = options;
        const argv = try a.alloc([]const u8, options.argv.len);
        for (options.argv, argv) |arg, *copy| copy.* = try a.dupe(u8, arg);
        owned.argv = argv;
        if (options.cwd) |cwd| owned.cwd = try a.dupe(u8, cwd);
        if (options.environ) |env| {
            const clone = try a.create(std.process.Environ.Map);
            clone.* = try env.clone(a);
            owned.environ = clone;
        }
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        job.options = owned;
        job.future = try self.io.concurrent(Job.run, .{job});
        self.next_id += 1;
        self.jobs.appendAssumeCapacity(job);
        return job.id;
    }

    pub fn get(self: *Manager, id: u64) ?*Job {
        for (self.jobs.items) |job| if (job.id == id) return job;
        return null;
    }

    pub fn cancel(self: *Manager, id: u64) void {
        if (self.get(id)) |job| job.cancel();
    }

    pub fn remove(self: *Manager, id: u64) void {
        for (self.jobs.items, 0..) |job, i| if (job.id == id) {
            job.deinit();
            _ = self.jobs.swapRemove(i);
            return;
        };
    }

    pub fn setWake(self: *Manager, wake: ?*const fn () void) void {
        self.wake_fn = wake;
        for (self.jobs.items) |job| {
            job.mutex.lockUncancelable(self.io);
            job.wake_fn = wake;
            job.mutex.unlock(self.io);
        }
    }

    pub fn deinit(self: *Manager) void {
        self.closing = true;
        self.setWake(null);
        for (self.jobs.items) |job| job.deinit();
        self.jobs.deinit(self.allocator);
    }
};

/// Windows job objects are assigned while suspended, before a child can spawn
/// descendants. POSIX children enter their own process group during spawn.
pub const ProcessGroup = struct {
    handle: if (windows) ?std.os.windows.HANDLE else ?std.posix.pid_t = null,

    pub fn init() !ProcessGroup {
        if (windows) {
            const handle = CreateJobObjectW(null, null) orelse return error.JobObjectFailed;
            errdefer _ = CloseHandle(handle);
            var limits = std.mem.zeroes(ExtendedLimits);
            limits.basic.flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (SetInformationJobObject(handle, 9, &limits, @sizeOf(ExtendedLimits)) == 0) return error.JobObjectFailed;
            return .{ .handle = handle };
        }
        return .{};
    }

    pub fn attach(self: *ProcessGroup, child: *std.process.Child) !void {
        if (windows) {
            if (AssignProcessToJobObject(self.handle.?, child.id.?) == 0) return error.JobObjectFailed;
            if (ResumeThread(child.thread_handle) == std.math.maxInt(u32)) return error.ResumeFailed;
        } else self.handle = child.id;
    }

    pub fn terminate(self: *ProcessGroup) void {
        if (self.handle) |handle| {
            if (windows) {
                _ = TerminateJobObject(handle, 1);
            } else {
                _ = std.c.kill(-handle, std.c.SIG.KILL);
            }
        }
    }

    pub fn deinit(self: *ProcessGroup) void {
        if (windows) if (self.handle) |handle| {
            _ = CloseHandle(handle);
        };
        self.handle = null;
    }
};

const BasicLimits = extern struct {
    process_time: i64,
    job_time: i64,
    flags: u32,
    min_working_set: usize,
    max_working_set: usize,
    active_process_limit: u32,
    affinity: usize,
    priority: u32,
    scheduling: u32,
};
const ExtendedLimits = extern struct {
    basic: BasicLimits,
    io_counters: [6]u64,
    process_memory_limit: usize,
    job_memory_limit: usize,
    peak_process_memory: usize,
    peak_job_memory: usize,
};
extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?[*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(std.os.windows.HANDLE, u32, *const anyopaque, u32) callconv(.winapi) c_int;
extern "kernel32" fn AssignProcessToJobObject(std.os.windows.HANDLE, std.os.windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn ResumeThread(std.os.windows.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn TerminateJobObject(std.os.windows.HANDLE, u32) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(std.os.windows.HANDLE) callconv(.winapi) c_int;

test "managed jobs report output and cancel a running process" {
    const t = std.testing;
    var manager: Manager = .{ .allocator = t.allocator, .io = t.io };
    defer manager.deinit();
    const id = try manager.start(.{ .argv = if (windows) &.{ "cmd", "/c", "echo managed-output" } else &.{ "sh", "-c", "printf managed-output" } });
    const job = manager.get(id).?;
    for (0..500) |_| {
        if (job.isDone()) break;
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    try t.expect(job.isDone());
    const result = try job.snapshot(t.allocator, false);
    defer result.deinit(t.allocator);
    try t.expectEqual(@as(?u8, 0), result.code);
    try t.expect(std.mem.indexOf(u8, result.stdout, "managed-output") != null);
    manager.remove(id);
    const slow = try manager.start(.{ .argv = if (windows) &.{ "powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", "Start-Sleep -Seconds 30" } else &.{ "sh", "-c", "sleep 30" } });
    try std.Io.sleep(t.io, .fromMilliseconds(100), .awake);
    manager.cancel(slow);
    const cancelled = try manager.get(slow).?.snapshot(t.allocator, false);
    defer cancelled.deinit(t.allocator);
    try t.expect(cancelled.cancelled and cancelled.done);
}
