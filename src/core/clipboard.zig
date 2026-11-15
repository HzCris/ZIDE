//! The system clipboard: the Win32 API on Windows, `wl-copy` / `xclip` /
//! `xsel` on Linux, and an in-process fallback when neither is there.
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
// Linux helpers run through the process-wide Io/environ globals — the
// clipboard is called from paths that don't thread an io parameter.
const lua_settings = @import("lua_settings.zig");
const jobs = @import("jobs.zig");

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
        const env = lua_settings.process_environ orelse return .none;
        if (env.get("WAYLAND_DISPLAY") != null) return .wayland;
        if (env.get("DISPLAY") != null) return .x11;
        return .none;
    }

    fn getTextLinux(allocator: Allocator) ?[]const u8 {
        const backend = detectLinuxBackend();
        switch (backend) {
            .wayland => {
                return runClipboardRead(allocator, &.{ "wl-paste", "--no-newline" }) catch null;
            },
            .x11 => {
                // Try xclip first, then xsel — unless xclip timed out: xsel
                // would wait on the same unresponsive selection owner.
                if (runClipboardRead(allocator, &.{ "xclip", "-selection", "clipboard", "-o" }) catch return null) |text| return text;
                return runClipboardRead(allocator, &.{ "xsel", "--clipboard", "--output" }) catch null;
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

    /// How long a Linux clipboard reader may take. The selection owner
    /// serves the data, and an unresponsive one used to hang the paste —
    /// and with it the whole TUI — for as long as it stayed stuck.
    const read_timeout_ms = 2000;
    /// Largest clipboard text a reader may deliver (stdout plus stderr).
    const read_limit = 1024 * 1024 + 4096;

    /// Run a reader through a job (the spawn lock, and a kill of its whole
    /// process group when it overruns) and return its stdout. Null when it
    /// is missing, fails, prints nothing or too much; error.Timeout when it
    /// overran the deadline.
    fn runClipboardRead(allocator: Allocator, argv: []const []const u8) error{Timeout}!?[]const u8 {
        const io = lua_settings.global_io orelse return null;
        var manager: jobs.Manager = .{ .allocator = allocator, .io = io };
        defer manager.deinit(); // on a timeout this kills the reader
        const id = manager.start(.{ .argv = argv, .output_limit = read_limit, .strict_output = true }) catch return null;
        const job = manager.get(id) orelse return null;
        const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromMilliseconds(read_timeout_ms), .clock = .awake });
        var nap_ms: i64 = 1;
        while (!job.isDone()) {
            if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) {
                std.log.warn("clipboard: {s} gave no answer within {d} ms", .{ argv[0], read_timeout_ms });
                return error.Timeout;
            }
            io.sleep(.fromMilliseconds(nap_ms), .awake) catch return null;
            nap_ms = @min(nap_ms * 2, 10);
        }
        const result = job.snapshot(allocator, true) catch return null;
        allocator.free(result.stderr);
        if (result.failure != null or result.code != 0 or result.stdout.len == 0) {
            allocator.free(result.stdout);
            return null;
        }
        return result.stdout;
    }

    /// Spawn a command and write text to its stdin.
    fn runClipboardWrite(argv: []const []const u8, text: []const u8) bool {
        const io = lua_settings.global_io orelse return false;
        var child = jobs.spawnLocked(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return false;

        // Write text to the child's stdin, then close it for EOF.
        if (child.stdin) |stdin| {
            stdin.writeStreamingAll(io, text) catch {};
            stdin.close(io);
            child.stdin = null;
        }

        const term = child.wait(io) catch return false;
        return term == .exited and term.exited == 0;
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
    extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalSize(hMem: *anyopaque) callconv(.winapi) usize;

    fn getTextWindows(allocator: Allocator) ?[]const u8 {
        if (OpenClipboard(null) == 0) return null;
        defer _ = CloseClipboard();

        const handle = GetClipboardData(CF_UNICODETEXT) orelse return null;
        return readTextBlock(allocator, handle);
    }

    /// The CF_UNICODETEXT text in global memory block `handle`, as UTF-8
    /// with `\n` line breaks (null when empty or unreadable). The NUL scan
    /// stops at the end of the block: a producer that left out the
    /// terminator can't send it past the allocation.
    fn readTextBlock(allocator: Allocator, handle: *anyopaque) ?[]const u8 {
        const max_units = GlobalSize(handle) / 2;
        const wide_ptr: ?[*]const u16 = @ptrCast(@alignCast(GlobalLock(handle)));
        const wide = wide_ptr orelse return null;
        defer _ = GlobalUnlock(handle);

        const len = std.mem.indexOfScalar(u16, wide[0..max_units], 0) orelse max_units;
        if (len == 0) return null;
        return decodeUtf16Text(allocator, wide[0..len]) catch null;
    }

    fn setTextWindows(text: []const u8) bool {
        // Convert UTF-8 to UTF-16
        const wide_len = std.unicode.calcUtf16LeLen(text) catch return false;
        const byte_size = (wide_len + 1) * 2; // +1 for null terminator, *2 for u16

        const hmem = GlobalAlloc(GMEM_MOVEABLE, byte_size) orelse return false;
        const ptr: ?[*]u16 = @ptrCast(@alignCast(GlobalLock(hmem)));
        if (ptr == null) {
            _ = GlobalFree(hmem);
            return false;
        }
        const wide = ptr.?;

        // Encode UTF-8 to UTF-16LE
        var i: usize = 0;
        var view = std.unicode.Utf8View.init(text) catch {
            _ = GlobalUnlock(hmem);
            _ = GlobalFree(hmem);
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

        if (OpenClipboard(null) == 0) {
            _ = GlobalFree(hmem);
            return false;
        }
        _ = EmptyClipboard();
        if (SetClipboardData(CF_UNICODETEXT, hmem) == null) {
            // Clipboard did not take ownership — free our allocation.
            _ = GlobalFree(hmem);
            _ = CloseClipboard();
            return false;
        }
        _ = CloseClipboard();
        return true;
    }
};

/// Clipboard UTF-16 (code units in native order, as Windows keeps them in
/// memory) as UTF-8, with every `\r\n` turned into `\n` — the editor's
/// form (paste converts to the document's own line ending). The data is
/// WTF-16 in practice (a string cut in the middle of a pair), so an
/// unpaired surrogate becomes U+FFFD: failing the whole conversion made a
/// paste fall back to the stale internal clipboard without a word.
pub fn decodeUtf16Text(allocator: Allocator, wide: []const u16) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, wide.len);
    var i: usize = 0;
    while (i < wide.len) {
        const unit = wide[i];
        i += 1;
        var cp: u21 = unit;
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            if (i < wide.len and std.unicode.utf16IsLowSurrogate(wide[i])) {
                cp = 0x10000 + ((@as(u21, unit & 0x3ff) << 10) | (wide[i] & 0x3ff));
                i += 1;
            } else cp = std.unicode.replacement_character;
        } else if (std.unicode.utf16IsLowSurrogate(unit)) {
            cp = std.unicode.replacement_character;
        } else if (unit == '\r' and i < wide.len and wide[i] == '\n') {
            continue; // the `\n` that follows is the line break
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable; // surrogates were replaced
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

test "clipboard UTF-16 decodes with LF line breaks and U+FFFD for unpaired surrogates" {
    const t = std.testing;
    const cases = [_]struct { wide: []const u16, utf8: []const u8 }{
        // Windows line breaks become `\n`; a lone `\r` or `\n` stays.
        .{ .wide = &.{ 'a', '\r', '\n', 'b', '\r', '\n' }, .utf8 = "a\nb\n" },
        .{ .wide = &.{ 'a', '\r', 'b', '\n', '\r' }, .utf8 = "a\rb\n\r" },
        // A pair is one code point (😀); é is two UTF-8 bytes.
        .{ .wide = &.{ 0xD83D, 0xDE00, 0xE9 }, .utf8 = "\u{1F600}\u{E9}" },
        // Unpaired halves: a high one before a letter or at the end, a low one alone.
        .{ .wide = &.{ 'x', 0xD800, 'y' }, .utf8 = "x\u{FFFD}y" },
        .{ .wide = &.{ 'x', 0xDBFF }, .utf8 = "x\u{FFFD}" },
        .{ .wide = &.{ 0xDC00, 'z', 0xD800, 0xD800, 0xDC00 }, .utf8 = "\u{FFFD}z\u{FFFD}\u{10000}" },
        // A surrogate half followed by CRLF: both repairs apply.
        .{ .wide = &.{ 0xD83D, '\r', '\n' }, .utf8 = "\u{FFFD}\n" },
    };
    for (cases) |case| {
        const got = try decodeUtf16Text(t.allocator, case.wide);
        defer t.allocator.free(got);
        try t.expectEqualStrings(case.utf8, got);
        try t.expect(std.unicode.utf8ValidateSlice(got));
    }
}

test "Windows clipboard blocks are read within their GlobalSize when the terminator is missing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const t = std.testing;
    const C = SystemClipboard;
    // A block with no NUL anywhere: every unit of the whole allocation
    // (which may be larger than requested) is 'a'.
    const hmem = C.GlobalAlloc(C.GMEM_MOVEABLE, 6) orelse return error.SkipZigTest;
    defer _ = C.GlobalFree(hmem);
    const units = C.GlobalSize(hmem) / 2;
    try t.expect(units >= 3);
    {
        const ptr: [*]u16 = @ptrCast(@alignCast(C.GlobalLock(hmem) orelse return error.SkipZigTest));
        defer _ = C.GlobalUnlock(hmem);
        @memset(ptr[0..units], 'a');
    }
    const text = C.readTextBlock(t.allocator, hmem) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(text);
    try t.expectEqual(units, text.len);
    for (text) |c| try t.expectEqual(@as(u8, 'a'), c);

    // A terminated block with CRLF and an unpaired surrogate.
    {
        const ptr: [*]u16 = @ptrCast(@alignCast(C.GlobalLock(hmem) orelse return error.SkipZigTest));
        defer _ = C.GlobalUnlock(hmem);
        @memcpy(ptr[0..3], &[_]u16{ 0xD800, '\r', '\n' });
        if (units > 3) ptr[3] = 0;
    }
    const repaired = C.readTextBlock(t.allocator, hmem) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(repaired);
    try t.expectEqualStrings("\u{FFFD}\n", repaired);
}
