const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Cross-platform pseudo-terminal abstraction.
/// Windows: ConPTY (CreatePseudoConsole)
/// Linux: posix openpty + fork/exec
pub const Pty = struct {
    allocator: Allocator,

    // Windows ConPTY handles
    hpc: if (is_windows) ?HPCON else void = if (is_windows) null else {},
    input_handle: if (is_windows) ?HANDLE else void = if (is_windows) null else {},
    output_handle: if (is_windows) ?HANDLE else void = if (is_windows) null else {},
    process_handle: if (is_windows) ?HANDLE else void = if (is_windows) null else {},
    thread_handle: if (is_windows) ?HANDLE else void = if (is_windows) null else {},

    // Linux PTY
    master_fd: if (is_linux) ?std.posix.fd_t else void = if (is_linux) null else {},
    child_pid: if (is_linux) ?std.posix.pid_t else void = if (is_linux) null else {},
    /// The reader polls the master AND the read end of this pipe; `shutdown`
    /// closes the write end so the reader always returns, even when some
    /// other process still holds the slave (a disowned job, `setsid`).
    shutdown_pipe: if (is_linux) [2]std.posix.fd_t else void = if (is_linux) .{ -1, -1 } else {},

    const is_windows = builtin.os.tag == .windows;
    const is_linux = builtin.os.tag == .linux;

    /// A pseudo console handle taken out of a Pty (`takeConsole`).
    pub const Console = if (is_windows) ?HPCON else void;

    pub fn spawn(allocator: Allocator, command: []const u8, cols: u16, rows: u16) !Pty {
        if (is_windows) {
            return spawnWindows(allocator, command, cols, rows);
        } else if (is_linux) {
            return spawnLinux(allocator, command, cols, rows);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Stop the child and release every handle. Call `shutdown` and join
    /// the reader thread first.
    pub fn deinit(self: *Pty) void {
        if (is_windows) {
            self.deinitWindows();
        } else if (is_linux) {
            self.deinitLinux();
        }
    }

    /// Make a blocked `read` return (EndOfStream) for good, without closing
    /// the handle it reads — the reader can then be joined safely. Windows:
    /// closes the pseudo console (ConPTY then ends the output pipe); Linux:
    /// signals the shutdown pipe.
    pub fn shutdown(self: *Pty) void {
        if (is_windows) {
            closeConsole(self.takeConsole());
        } else if (is_linux) {
            const w = self.shutdown_pipe[1];
            if (w >= 0) {
                _ = std.c.close(w);
                self.shutdown_pipe[1] = -1;
            }
        }
    }

    /// Take the pseudo console out of this Pty (null afterwards, so resize
    /// and deinit skip it); pass it to `closeConsole`. Windows only — the
    /// caller serializes against `resize`.
    pub fn takeConsole(self: *Pty) Console {
        if (!is_windows) return {};
        const hpc = self.hpc;
        self.hpc = null;
        return hpc;
    }

    pub fn closeConsole(console: Console) void {
        if (!is_windows) return;
        if (console) |hpc| ClosePseudoConsole(hpc);
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        if (is_windows) {
            return self.readWindows(buf);
        } else if (is_linux) {
            return self.readLinux(buf);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    pub fn write(self: *Pty, data: []const u8) !void {
        if (is_windows) {
            return self.writeWindows(data);
        } else if (is_linux) {
            return self.writeLinux(data);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        if (is_windows) {
            self.resizeWindows(cols, rows);
        } else if (is_linux) {
            self.resizeLinux(cols, rows);
        }
    }

    // =========================================================================
    // Windows ConPTY implementation
    // =========================================================================

    fn spawnWindows(allocator: Allocator, command: []const u8, cols: u16, rows: u16) !Pty {
        if (!is_windows) unreachable;

        // Create pipes for PTY I/O. Handles are nulled as ownership moves so
        // the errdefer can never double-close (previously every error path
        // after CreatePseudoConsole closed all four handles twice).
        var pty_read_in: ?HANDLE = null;
        var app_write_in: ?HANDLE = null;
        var app_read_out: ?HANDLE = null;
        var pty_write_out: ?HANDLE = null;
        errdefer {
            if (pty_read_in) |h| _ = CloseHandle(h);
            if (app_write_in) |h| _ = CloseHandle(h);
            if (app_read_out) |h| _ = CloseHandle(h);
            if (pty_write_out) |h| _ = CloseHandle(h);
        }

        if (CreatePipe(&pty_read_in, &app_write_in, null, 0) == 0) return error.PipeCreationFailed;
        if (CreatePipe(&app_read_out, &pty_write_out, null, 0) == 0) return error.PipeCreationFailed;

        // Create pseudo console
        const size = COORD{ .X = @intCast(cols), .Y = @intCast(rows) };
        var hpc: HPCON = undefined;
        const hr = CreatePseudoConsole(size, pty_read_in, pty_write_out, 0, &hpc);
        if (hr != 0) return error.ConPtyCreationFailed;
        errdefer ClosePseudoConsole(hpc);

        // Close the PTY-side pipe ends — ConPTY owns them now
        _ = CloseHandle(pty_read_in.?);
        pty_read_in = null;
        _ = CloseHandle(pty_write_out.?);
        pty_write_out = null;

        // Set up STARTUPINFOEX with pseudo console attribute
        var attr_list_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);

        const attr_list_buf = try allocator.alloc(u8, attr_list_size);
        defer allocator.free(attr_list_buf);

        const attr_list: LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(attr_list_buf.ptr);
        if (InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_list_size) == 0) {
            return error.AttributeListFailed;
        }
        defer DeleteProcThreadAttributeList(attr_list);

        // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
        if (UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(HPCON), null, null) == 0) {
            return error.AttributeUpdateFailed;
        }

        // Build command line as wide string. Reserve one slot for the null
        // terminator — an exactly-buffer-sized command would write OOB.
        var cmd_buf: [512]u16 = undefined;
        const cmd_len = std.unicode.utf8ToUtf16Le(cmd_buf[0 .. cmd_buf.len - 1], command) catch return error.CommandTooLong;
        cmd_buf[cmd_len] = 0;

        var si: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        si.lpAttributeList = attr_list;
        // CRITICAL: without STARTF_USESTDHANDLES (with NULL handles), Windows
        // "std handle duplication" copies OUR std handles into the child when
        // they aren't live console handles — overriding the pseudoconsole
        // attachment. That made the shell write to zide's (dead, post-
        // FreeConsole) handles instead of the ConPTY → blank terminal pane.
        // NULL std handles let the console connect hand the child fresh
        // ConPTY handles. (Same approach as wezterm's portable-pty.)
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;

        var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);

        const create_result = CreateProcessW(
            null,
            @ptrCast(&cmd_buf),
            null,
            null,
            0, // bInheritHandles = FALSE
            EXTENDED_STARTUPINFO_PRESENT,
            null,
            null,
            @ptrCast(&si),
            &pi,
        );

        if (create_result == 0) return error.ProcessCreationFailed;

        // We don't need the main thread handle
        _ = CloseHandle(pi.hThread);

        return Pty{
            .allocator = allocator,
            .hpc = hpc,
            .input_handle = app_write_in,
            .output_handle = app_read_out,
            .process_handle = pi.hProcess,
            .thread_handle = null,
        };
    }

    fn readWindows(self: *Pty, buf: []u8) !usize {
        if (!is_windows) unreachable;
        const handle = self.output_handle orelse return error.NotStarted;
        var bytes_read: u32 = 0;
        const result = ReadFile(handle, buf.ptr, @intCast(buf.len), &bytes_read, null);
        if (result == 0) {
            // Check if process exited
            return error.EndOfStream;
        }
        if (bytes_read == 0) return error.EndOfStream;
        return @intCast(bytes_read);
    }

    fn writeWindows(self: *Pty, data: []const u8) !void {
        if (!is_windows) unreachable;
        const handle = self.input_handle orelse return error.NotStarted;
        var written: u32 = 0;
        var offset: usize = 0;
        while (offset < data.len) {
            const remaining: u32 = @intCast(data.len - offset);
            const result = WriteFile(handle, data[offset..].ptr, remaining, &written, null);
            if (result == 0) return error.WriteFailed;
            offset += @intCast(written);
        }
    }

    fn resizeWindows(self: *Pty, cols: u16, rows: u16) void {
        if (!is_windows) unreachable;
        const hpc = self.hpc orelse return;
        const size = COORD{ .X = @intCast(cols), .Y = @intCast(rows) };
        _ = ResizePseudoConsole(hpc, size);
    }

    fn deinitWindows(self: *Pty) void {
        if (!is_windows) unreachable;
        // Close pseudo console first (sends exit signal to shell)
        if (self.hpc) |hpc| ClosePseudoConsole(hpc);
        // Wait briefly for process, then terminate
        if (self.process_handle) |ph| {
            _ = WaitForSingleObject(ph, 500); // 500ms grace period
            _ = TerminateProcess(ph, 0);
            _ = CloseHandle(ph);
        }
        if (self.input_handle) |h| _ = CloseHandle(h);
        if (self.output_handle) |h| _ = CloseHandle(h);
        if (self.thread_handle) |h| _ = CloseHandle(h);
    }

    // =========================================================================
    // Linux posix PTY implementation
    // =========================================================================

    // openpty/execvpe aren't declared in std.c; both live in libc proper
    // (openpty merged from libutil in glibc 2.34; execvpe is in glibc and
    // musl), so "c" externs suffice.
    extern "c" fn openpty(
        amaster: *std.posix.fd_t,
        aslave: *std.posix.fd_t,
        name: ?[*]u8,
        termp: ?*const anyopaque,
        winp: ?*const std.posix.winsize,
    ) c_int;
    extern "c" fn execvpe(
        file: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) c_int;

    /// The environment for a terminal child: ours, with TERM naming the
    /// terminal ZIDE emulates (an inherited TERM describes the outer
    /// terminal — kitty, tmux — whose sequences ZIDE does not parse, and a
    /// desktop launch has none) and COLORTERM advertising truecolor unless
    /// already set. The strings are borrowed from `environ`; only the
    /// pointer array is allocated.
    fn childEnvironment(allocator: Allocator) ![:null]?[*:0]const u8 {
        var count: usize = 0;
        while (std.c.environ[count] != null) : (count += 1) {}
        const env = try allocator.allocSentinel(?[*:0]const u8, count + 2, null);
        @memset(env, null);
        var n: usize = 0;
        var has_colorterm = false;
        for (std.c.environ[0..count]) |entry| {
            const e = entry orelse continue;
            const s = std.mem.span(e);
            if (std.mem.startsWith(u8, s, "TERM=")) continue;
            if (std.mem.startsWith(u8, s, "COLORTERM=")) has_colorterm = true;
            env[n] = e;
            n += 1;
        }
        env[n] = "TERM=xterm-256color";
        n += 1;
        if (!has_colorterm) env[n] = "COLORTERM=truecolor";
        return env;
    }

    fn spawnLinux(allocator: Allocator, command: []const u8, cols: u16, rows: u16) !Pty {
        if (!is_linux) unreachable;

        // Everything the child needs is prepared before fork(): the child of
        // a multithreaded process must not allocate. It execs or _exits, so
        // only the parent frees. (The editor passes $SHELL / bash / sh;
        // "/bin/sh" is only the last resort for an empty command.)
        const prog_z: [:0]u8 = if (command.len > 0)
            try allocator.dupeZ(u8, command)
        else
            try allocator.dupeZ(u8, if (std.c.getenv("SHELL")) |s| std.mem.span(s) else "/bin/sh");
        defer allocator.free(prog_z);
        const envp = try childEnvironment(allocator);
        defer allocator.free(envp);

        // The reader's shutdown pipe (close-on-exec: no child inherits it)
        var shutdown_pipe: [2]std.posix.fd_t = undefined;
        if (std.c.pipe2(&shutdown_pipe, .{ .CLOEXEC = true }) != 0) return error.PipeCreationFailed;
        errdefer {
            _ = std.c.close(shutdown_pipe[0]);
            _ = std.c.close(shutdown_pipe[1]);
        }

        // openpty() to get master/slave pair
        var master: std.posix.fd_t = undefined;
        var slave: std.posix.fd_t = undefined;
        var ws: std.posix.winsize = .{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };

        const rc = openpty(&master, &slave, null, null, &ws);
        if (rc != 0) return error.OpenPtyFailed;
        errdefer _ = std.c.close(master);
        // openpty's descriptors are inheritable: without close-on-exec every
        // later child (language servers, git, tasks, other shells) would keep
        // this terminal's master and slave open. (dup2 onto the child's
        // stdio below clears the flag on those copies, as it should.)
        _ = std.c.fcntl(master, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        _ = std.c.fcntl(slave, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));

        // std.posix.fork/dup2/exit/getenv were removed in 0.16 — this
        // whole child setup goes through libc directly.
        const pid = std.c.fork();
        if (pid < 0) {
            _ = std.c.close(slave);
            return error.ForkFailed;
        }
        if (pid == 0) {
            // Child process
            _ = std.c.close(master);

            // Create new session, set controlling terminal
            _ = std.c.setsid();
            _ = std.c.ioctl(slave, std.posix.T.IOCSCTTY, @as(?*anyopaque, null));

            // Redirect stdio to slave
            if (std.c.dup2(slave, 0) < 0) std.c._exit(1);
            if (std.c.dup2(slave, 1) < 0) std.c._exit(1);
            if (std.c.dup2(slave, 2) < 0) std.c._exit(1);
            if (slave > 2) _ = std.c.close(slave);

            const argv = [_:null]?[*:0]const u8{ prog_z.ptr, null };
            _ = execvpe(prog_z.ptr, &argv, envp.ptr);
            std.c._exit(127);
        }

        // Parent process
        _ = std.c.close(slave);

        return Pty{
            .allocator = allocator,
            .master_fd = master,
            .child_pid = pid,
            .shutdown_pipe = shutdown_pipe,
        };
    }

    fn readLinux(self: *Pty, buf: []u8) !usize {
        if (!is_linux) unreachable;
        const fd = self.master_fd orelse return error.NotStarted;
        // Wait for output or `shutdown` (poll ignores a negative fd, so a
        // Pty without the pipe just waits on the master).
        var fds = [_]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.shutdown_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, -1) catch return error.EndOfStream;
        if (fds[1].revents != 0) return error.EndOfStream;
        // Readable, or hung up (the read then fails with EIO)
        const n = std.posix.read(fd, buf) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        return n;
    }

    fn writeLinux(self: *Pty, data: []const u8) !void {
        if (!is_linux) unreachable;
        const fd = self.master_fd orelse return error.NotStarted;
        var offset: usize = 0;
        while (offset < data.len) {
            // std.posix.write was removed in 0.16 — raw fd writes go
            // through libc, matching the rest of this file's std.c usage.
            const rc = std.c.write(fd, data[offset..].ptr, data.len - offset);
            if (rc <= 0) return error.WriteFailed;
            offset += @intCast(rc);
        }
    }

    fn resizeLinux(self: *Pty, cols: u16, rows: u16) void {
        if (!is_linux) unreachable;
        const fd = self.master_fd orelse return;
        var ws: std.posix.winsize = .{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = std.c.ioctl(fd, std.posix.T.IOCSWINSZ, &ws);
    }

    fn deinitLinux(self: *Pty) void {
        if (!is_linux) unreachable;
        if (self.child_pid) |pid| {
            // Ask nicely, then give the shell ~500 ms before SIGKILL: a child
            // that ignores HUP would otherwise park every window in a
            // blocking waitpid (closing a detached terminal window ends here).
            std.posix.kill(pid, std.posix.SIG.HUP) catch {};
            var status: c_int = 0;
            var reaped = false;
            var waited_ms: usize = 0;
            while (waited_ms < 500) : (waited_ms += 10) {
                // (std.posix.waitpid was removed in 0.16)
                if (std.c.waitpid(pid, &status, std.c.W.NOHANG) != 0) {
                    reaped = true;
                    break;
                }
                const ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
            }
            if (!reaped) {
                std.posix.kill(pid, std.posix.SIG.KILL) catch {};
                _ = std.c.waitpid(pid, &status, 0);
            }
        }
        if (self.master_fd) |fd| _ = std.c.close(fd);
        for (&self.shutdown_pipe) |*fd| {
            if (fd.* >= 0) _ = std.c.close(fd.*);
            fd.* = -1;
        }
    }
};

// =============================================================================
// Windows API declarations for ConPTY
// =============================================================================

const HANDLE = std.os.windows.HANDLE;
const HPCON = HANDLE;
const COORD = extern struct { X: c_short, Y: c_short };
const LPPROC_THREAD_ATTRIBUTE_LIST = *anyopaque;

const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x00080000;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const STARTF_USESTDHANDLES: u32 = 0x00000100;

const STARTUPINFOW = extern struct {
    cb: u32 = 0,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW = .{},
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE = null,
    hThread: ?HANDLE = null,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: i32,
};

// Win32 API imports
extern "kernel32" fn CreatePipe(
    hReadPipe: *?HANDLE,
    hWritePipe: *?HANDLE,
    lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
    nSize: u32,
) callconv(.c) i32;

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: ?HANDLE,
    hOutput: ?HANDLE,
    dwFlags: u32,
    phPC: *HPCON,
) callconv(.c) i32; // HRESULT

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.c) i32;

extern "kernel32" fn ClosePseudoConsole(
    hPC: HPCON,
) callconv(.c) void;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: i32,
    dwCreationFlags: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.c) i32;

extern "kernel32" fn ReadFile(
    hFile: ?HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.c) i32;

extern "kernel32" fn WriteFile(
    hFile: ?HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.c) i32;

extern "kernel32" fn CloseHandle(hObject: ?HANDLE) callconv(.c) i32;
extern "kernel32" fn TerminateProcess(hProcess: ?HANDLE, uExitCode: u32) callconv(.c) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: ?HANDLE, dwMilliseconds: u32) callconv(.c) u32;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
    dwAttributeCount: u32,
    dwFlags: u32,
    lpSize: *usize,
) callconv(.c) i32;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    dwFlags: u32,
    Attribute: usize,
    lpValue: ?HPCON,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.c) i32;

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
) callconv(.c) void;

// =============================================================================
// Tests
// =============================================================================

test "pty struct size" {
    // Basic compilation test — ensure struct layout works
    const pty = Pty{ .allocator = std.testing.allocator };
    _ = pty;
}
