const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// Cross-platform system clipboard access.
/// Windows: Win32 OpenClipboard/GetClipboardData/SetClipboardData
/// Linux: wl-copy/wl-paste (Wayland) or xclip/xsel (X11)
pub const SystemClipboard = struct {
    /// Get text from the system clipboard. Caller owns returned slice.
    /// Returns null if clipboard is empty or unavailable.
    pub fn getText(allocator: Allocator) ?[]const u8 {
        if (builtin.os.tag == .windows) {
            return getTextWindows(allocator);
        }
        if (builtin.os.tag == .linux) {
            return getTextLinux(allocator);
        }
        return null;
    }

    /// Set text to the system clipboard.
    /// Returns true on success.
    pub fn setText(text: []const u8) bool {
        if (builtin.os.tag == .windows) {
            return setTextWindows(text);
        }
        if (builtin.os.tag == .linux) {
            return setTextLinux(text);
        }
        return false;
    }

    // =========================================================================
    // Linux implementation (Wayland: wl-copy/wl-paste, X11: xclip/xsel)
    // =========================================================================

    const LinuxBackend = enum { wayland, x11, none };

    fn detectLinuxBackend() LinuxBackend {
        if (std.process.hasEnvVarConstant("WAYLAND_DISPLAY")) return .wayland;
        if (std.process.hasEnvVarConstant("DISPLAY")) return .x11;
        return .none;
    }

    fn getTextLinux(allocator: Allocator) ?[]const u8 {
        const backend = detectLinuxBackend();
        switch (backend) {
            .wayland => {
                return runClipboardRead(allocator, &.{ "wl-paste", "--no-newline" });
            },
            .x11 => {
                // Try xclip first, then xsel
                return runClipboardRead(allocator, &.{ "xclip", "-selection", "clipboard", "-o" }) orelse
                    runClipboardRead(allocator, &.{ "xsel", "--clipboard", "--output" });
            },
            .none => return null,
        }
    }

    fn setTextLinux(text: []const u8) bool {
        const backend = detectLinuxBackend();
        switch (backend) {
            .wayland => {
                return runClipboardWrite(&.{"wl-copy"}, text);
            },
            .x11 => {
                // Try xclip first, then xsel
                if (runClipboardWrite(&.{ "xclip", "-selection", "clipboard" }, text)) return true;
                return runClipboardWrite(&.{ "xsel", "--clipboard", "--input" }, text);
            },
            .none => return false,
        }
    }

    /// Spawn a command and capture its stdout as clipboard text.
    fn runClipboardRead(allocator: Allocator, argv: []const []const u8) ?[]const u8 {
        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch return null;

        var stdout = std.ArrayList(u8).init(allocator);
        var stderr = std.ArrayList(u8).init(allocator);
        defer stderr.deinit();

        child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024) catch {
            stdout.deinit();
            return null;
        };

        const term = child.wait() catch {
            stdout.deinit();
            return null;
        };

        if (term != .Exited or term.Exited != 0) {
            stdout.deinit();
            return null;
        }

        if (stdout.items.len == 0) {
            stdout.deinit();
            return null;
        }

        return stdout.toOwnedSlice() catch {
            stdout.deinit();
            return null;
        };
    }

    /// Spawn a command and write text to its stdin.
    fn runClipboardWrite(argv: []const []const u8, text: []const u8) bool {
        // Use page_allocator since we don't store the result and this is a short-lived operation.
        var child = std.process.Child.init(argv, std.heap.page_allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch return false;

        // Write text to child's stdin, then close it so the child sees EOF.
        if (child.stdin) |stdin| {
            stdin.writeAll(text) catch {};
            stdin.close();
            child.stdin = null;
        }

        const term = child.wait() catch return false;
        return term == .Exited and term.Exited == 0;
    }

    // =========================================================================
    // Windows implementation
    // =========================================================================

    const CF_UNICODETEXT: c_uint = 13;
    const GMEM_MOVEABLE: c_uint = 0x0002;

    extern "user32" fn OpenClipboard(hWndNewOwner: ?*anyopaque) callconv(.winapi) c_int;
    extern "user32" fn CloseClipboard() callconv(.winapi) c_int;
    extern "user32" fn GetClipboardData(uFormat: c_uint) callconv(.winapi) ?*anyopaque;
    extern "user32" fn SetClipboardData(uFormat: c_uint, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "user32" fn EmptyClipboard() callconv(.winapi) c_int;

    extern "kernel32" fn GlobalAlloc(uFlags: c_uint, dwBytes: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalLock(hMem: *anyopaque) callconv(.winapi) ?[*]u8;
    extern "kernel32" fn GlobalUnlock(hMem: *anyopaque) callconv(.winapi) c_int;

    fn getTextWindows(allocator: Allocator) ?[]const u8 {
        if (OpenClipboard(null) == 0) return null;
        defer _ = CloseClipboard();

        const handle = GetClipboardData(CF_UNICODETEXT) orelse return null;
        const wide_ptr: ?[*]const u16 = @ptrCast(@alignCast(GlobalLock(handle)));
        if (wide_ptr == null) return null;
        const wide = wide_ptr.?;
        defer _ = GlobalUnlock(handle);

        // Find length of null-terminated UTF-16 string
        var len: usize = 0;
        while (wide[len] != 0) len += 1;
        if (len == 0) return null;

        // Convert UTF-16 to UTF-8
        const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..len]) catch return null;
        return utf8;
    }

    fn setTextWindows(text: []const u8) bool {
        // Convert UTF-8 to UTF-16
        const wide_len = std.unicode.calcUtf16LeLen(text) catch return false;
        const byte_size = (wide_len + 1) * 2; // +1 for null terminator, *2 for u16

        const hmem = GlobalAlloc(GMEM_MOVEABLE, byte_size) orelse return false;
        const ptr: ?[*]u16 = @ptrCast(@alignCast(GlobalLock(hmem)));
        if (ptr == null) return false;
        const wide = ptr.?;

        // Encode UTF-8 to UTF-16LE
        var i: usize = 0;
        var view = std.unicode.Utf8View.init(text) catch {
            _ = GlobalUnlock(hmem);
            return false;
        };
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (cp < 0x10000) {
                wide[i] = @intCast(cp);
                i += 1;
            } else {
                // Surrogate pair
                const val = cp - 0x10000;
                wide[i] = @intCast(0xD800 + (val >> 10));
                wide[i + 1] = @intCast(0xDC00 + (val & 0x3FF));
                i += 2;
            }
        }
        wide[i] = 0; // null terminate

        _ = GlobalUnlock(hmem);

        if (OpenClipboard(null) == 0) return false;
        _ = EmptyClipboard();
        _ = SetClipboardData(CF_UNICODETEXT, hmem);
        _ = CloseClipboard();
        return true;
    }
};
