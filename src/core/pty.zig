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

    const is_windows = builtin.os.tag == .windows;
    const is_linux = builtin.os.tag == .linux;

    pub fn spawn(allocator: Allocator, command: []const u8, cols: u16, rows: u16) !Pty {
        if (is_windows) {
            return spawnWindows(allocator, command, cols, rows);
        } else if (is_linux) {
            return spawnLinux(allocator, command, cols, rows);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    pub fn deinit(self: *Pty) void {
        if (is_windows) {
            self.deinitWindows();
        } else if (is_linux) {
            self.deinitLinux();
        }
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

    fn spawnLinux(allocator: Allocator, command: []const u8, cols: u16, rows: u16) !Pty {
        if (!is_linux) unreachable;

        // openpty() to get master/slave pair
        var master: std.posix.fd_t = undefined;
        var slave: std.posix.fd_t = undefined;
        var ws: std.posix.winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        const rc = std.c.openpty(&master, &slave, null, null, &ws);
        if (rc != 0) return error.OpenPtyFailed;
        errdefer std.posix.close(master);

        const pid = try std.posix.fork();
        if (pid == 0) {
            // Child process
            std.posix.close(master);

            // Create new session, set controlling terminal
            _ = std.c.setsid();
            _ = std.c.ioctl(slave, std.posix.T.IOCSCTTY, @as(?*anyopaque, null));

            // Redirect stdio to slave
            std.posix.dup2(slave, 0) catch std.posix.exit(1);
            std.posix.dup2(slave, 1) catch std.posix.exit(1);
            std.posix.dup2(slave, 2) catch std.posix.exit(1);
            if (slave > 2) std.posix.close(slave);

            // Determine shell
            const shell = std.posix.getenv("SHELL") orelse "/bin/bash";

            // Use the command or fall back to shell
            _ = command;
            const argv = [_:null]?[*:0]const u8{ @ptrCast(shell.ptr), null };
            _ = std.c.execvp(@ptrCast(shell.ptr), &argv);
            std.posix.exit(1);
        }

        // Parent process
        std.posix.close(slave);

        return Pty{
            .allocator = allocator,
            .master_fd = master,
            .child_pid = pid,
        };
    }

    fn readLinux(self: *Pty, buf: []u8) !usize {
        if (!is_linux) unreachable;
        const fd = self.master_fd orelse return error.NotStarted;
        const n = std.posix.read(fd, buf) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        return n;
    }

    fn writeLinux(self: *Pty, data: []const u8) !void {
        if (!is_linux) unreachable;
        const fd = self.master_fd orelse return error.NotStarted;
        var offset: usize = 0;
        while (offset < data.len) {
            const n = std.posix.write(fd, data[offset..]) catch return error.WriteFailed;
            offset += n;
        }
    }

    fn resizeLinux(self: *Pty, cols: u16, rows: u16) void {
        if (!is_linux) unreachable;
        const fd = self.master_fd orelse return;
        var ws: std.posix.winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = std.c.ioctl(fd, std.posix.T.IOCSWINSZ, &ws);
    }

    fn deinitLinux(self: *Pty) void {
        if (!is_linux) unreachable;
        if (self.child_pid) |pid| {
            // Send SIGHUP to gracefully terminate
            std.posix.kill(pid, std.posix.SIG.HUP) catch {};
            // Reap child
            _ = std.posix.waitpid(pid, .{}) catch {};
        }
        if (self.master_fd) |fd| std.posix.close(fd);
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
