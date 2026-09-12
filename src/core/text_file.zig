//! Disk bytes are decoded strictly into UTF-8. No lossy substitutions or writes.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const TextEncoding = enum { utf8, utf16_le, utf16_be, windows1252 };
pub const TextFormat = struct {
    encoding: TextEncoding = .utf8,
    bom: bool = false,

    pub fn label(self: TextFormat) []const u8 {
        return switch (self.encoding) {
            .utf8 => if (self.bom) "UTF-8 BOM" else "UTF-8",
            .utf16_le => if (self.bom) "UTF-16 LE BOM" else "UTF-16 LE",
            .utf16_be => if (self.bom) "UTF-16 BE BOM" else "UTF-16 BE",
            .windows1252 => "Windows-1252",
        };
    }
};

pub const formats = [_]TextFormat{
    .{},                                     .{ .bom = true },
    .{ .encoding = .utf16_le, .bom = true }, .{ .encoding = .utf16_be, .bom = true },
    .{ .encoding = .windows1252 },
};
pub const Decoded = struct { text: []u8, format: TextFormat };

pub fn pathKey(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    return std.fs.path.resolve(allocator, &.{ root, path });
}

const cp1252 = [_]u21{
    0x20ac, 0,      0x201a, 0x192,  0x201e, 0x2026, 0x2020, 0x2021,
    0x2c6,  0x2030, 0x160,  0x2039, 0x152,  0,      0x17d,  0,
    0,      0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
    0x2dc,  0x2122, 0x161,  0x203a, 0x153,  0,      0x17e,  0x178,
};

pub fn validate(text: []const u8) !void {
    const view = std.unicode.Utf8View.init(text) catch return error.MalformedEncoding;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if ((cp < 32 and cp != '\t' and cp != '\n' and cp != '\r' and cp != 12) or
            (cp >= 0x7f and cp <= 0x9f)) return error.BinaryFile;
    }
}

fn appendUtf8(out: *std.ArrayList(u8), allocator: Allocator, cp: u21) !void {
    var bytes: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &bytes) catch return error.MalformedEncoding;
    try out.appendSlice(allocator, bytes[0..n]);
}

pub fn decode(allocator: Allocator, bytes: []const u8, override: ?TextEncoding) !Decoded {
    var format: TextFormat = .{ .encoding = override orelse .utf8 };
    var skip: usize = 0;
    const detected: ?TextEncoding = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) .utf8 else if (std.mem.startsWith(u8, bytes, "\xff\xfe")) .utf16_le else if (std.mem.startsWith(u8, bytes, "\xfe\xff")) .utf16_be else null;
    if (detected) |enc| {
        if (override == null or override.? == enc) {
            format = .{ .encoding = enc, .bom = true };
            skip = if (enc == .utf8) 3 else 2;
        }
    }
    const raw = bytes[skip..];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (format.encoding) {
        .utf8 => {
            if (!std.unicode.utf8ValidateSlice(raw)) {
                if (override == null and detected == null) return error.EncodingRequired;
                return error.MalformedEncoding;
            }
            try out.appendSlice(allocator, raw);
        },
        .utf16_le, .utf16_be => {
            if (raw.len % 2 != 0) return error.MalformedEncoding;
            const endian: std.builtin.Endian = if (format.encoding == .utf16_le) .little else .big;
            var i: usize = 0;
            while (i < raw.len) {
                const first = std.mem.readInt(u16, raw[i..][0..2], endian);
                i += 2;
                var cp: u21 = first;
                if (first >= 0xd800 and first <= 0xdbff) {
                    if (i == raw.len) return error.MalformedEncoding;
                    const second = std.mem.readInt(u16, raw[i..][0..2], endian);
                    i += 2;
                    if (second < 0xdc00 or second > 0xdfff) return error.MalformedEncoding;
                    cp = 0x10000 + ((@as(u21, first) - 0xd800) << 10) + (second - 0xdc00);
                } else if (first >= 0xdc00 and first <= 0xdfff) return error.MalformedEncoding;
                try appendUtf8(&out, allocator, cp);
            }
        },
        .windows1252 => for (raw) |b| {
            const cp: u21 = if (b >= 0x80 and b <= 0x9f) cp1252[b - 0x80] else b;
            if (cp == 0 and b != 0) return error.MalformedEncoding;
            try appendUtf8(&out, allocator, cp);
        },
    }
    try validate(out.items);
    return .{ .text = try out.toOwnedSlice(allocator), .format = format };
}

pub fn encode(allocator: Allocator, text: []const u8, format: TextFormat) ![]u8 {
    try validate(text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (format.bom) try out.appendSlice(allocator, switch (format.encoding) {
        .utf8 => "\xef\xbb\xbf",
        .utf16_le => "\xff\xfe",
        .utf16_be => "\xfe\xff",
        .windows1252 => return error.InvalidFormat,
    });
    if (format.encoding == .utf8) {
        try out.appendSlice(allocator, text);
    } else {
        var it = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
        while (it.nextCodepoint()) |cp| switch (format.encoding) {
            .utf8 => unreachable,
            .windows1252 => {
                if (cp < 0x80 or (cp >= 0xa0 and cp <= 0xff)) {
                    try out.append(allocator, @intCast(cp));
                } else {
                    const idx = std.mem.indexOfScalar(u21, &cp1252, cp) orelse return error.UnrepresentableText;
                    try out.append(allocator, @intCast(idx + 0x80));
                }
            },
            .utf16_le, .utf16_be => {
                const endian: std.builtin.Endian = if (format.encoding == .utf16_le) .little else .big;
                var units: [2]u16 = undefined;
                const n: usize = if (cp <= 0xffff) 1 else 2;
                if (n == 1) {
                    units[0] = @intCast(cp);
                } else {
                    units[0] = @intCast(0xd800 + ((cp - 0x10000) >> 10));
                    units[1] = @intCast(0xdc00 + ((cp - 0x10000) & 0x3ff));
                }
                for (units[0..n]) |unit| {
                    var bytes: [2]u8 = undefined;
                    std.mem.writeInt(u16, &bytes, unit, endian);
                    try out.appendSlice(allocator, &bytes);
                }
            },
        };
    }
    return out.toOwnedSlice(allocator);
}

pub fn read(allocator: Allocator, io: std.Io, path: []const u8, override: ?TextEncoding, limit: usize) !Decoded {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
    defer allocator.free(bytes);
    return decode(allocator, bytes, override);
}

pub fn write(allocator: Allocator, io: std.Io, path: []const u8, text: []const u8, format: TextFormat) !void {
    const bytes = try encode(allocator, text, format);
    defer allocator.free(bytes);
    try atomicWrite(allocator, io, path, bytes);
}

pub const FailureStage = enum { write, sync, replace };
/// Test-only fault injection; thread-local so background searches are unaffected.
pub threadlocal var testing_failure: ?FailureStage = null;

pub fn atomicWrite(allocator: Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    // Resolve existing symlinks before creating the sibling: save the target,
    // retaining the link itself. Errors other than a missing new file are fatal.
    const destination = try writeTarget(allocator, io, path, 0);
    defer allocator.free(destination);
    const stat = cwd.statFile(io, destination, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const original_permissions = if (stat != null) try filePermissions(io, destination) else null;
    const dacl = if (builtin.os.tag == .windows and stat != null) try WindowsDacl.read(allocator, destination) else null;
    defer if (dacl) |bytes_sd| allocator.free(bytes_sd);
    if (stat) |s| {
        if (s.kind != .file) return error.NotFile;
        const p = original_permissions.?;
        if (if (builtin.os.tag == .windows) p.toAttributes().READONLY else p.readOnly()) return error.AccessDenied;
    }
    var atomic = try cwd.createFileAtomic(io, destination, .{ .replace = true });
    defer atomic.deinit(io);
    if (builtin.is_test and testing_failure == .write) {
        try atomic.file.writeStreamingAll(io, bytes[0 .. bytes.len / 2]);
        return error.InjectedWriteFailure;
    }
    try atomic.file.writeStreamingAll(io, bytes);
    if (dacl) |bytes_sd| {
        const dir_path = try atomic.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(dir_path);
        const name = std.fmt.hex(atomic.file_basename_hex);
        const temp_path = try std.fs.path.join(allocator, &.{ dir_path, &name });
        defer allocator.free(temp_path);
        try WindowsDacl.apply(allocator, temp_path, bytes_sd, null);
    }
    if (original_permissions) |p| try atomic.file.setPermissions(io, p);
    if (builtin.is_test and testing_failure == .sync) return error.InjectedSyncFailure;
    try atomic.file.sync(io);
    if (builtin.is_test and testing_failure == .replace) return error.InjectedReplaceFailure;
    try atomic.replace(io);
}

/// Access-control lists are separate from Zig's Windows File.Permissions
/// (attributes). Copy the DACL before replacement so restrictive file ACLs
/// cannot be broadened by the temporary sibling's inherited permissions.
const WindowsDacl = struct {
    extern "advapi32" fn GetFileSecurityW([*:0]const u16, u32, ?*anyopaque, u32, *u32) callconv(.winapi) i32;
    extern "advapi32" fn SetFileSecurityW([*:0]const u16, u32, *const anyopaque) callconv(.winapi) i32;
    extern "advapi32" fn GetSecurityDescriptorControl(*const anyopaque, *u16, *u32) callconv(.winapi) i32;

    fn read(allocator: Allocator, path: []const u8) ![]u8 {
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
        defer allocator.free(wide);
        var needed: u32 = 0;
        _ = GetFileSecurityW(wide, 4, null, 0, &needed);
        if (needed == 0) return error.AccessDenied;
        const bytes_sd = try allocator.alloc(u8, needed);
        errdefer allocator.free(bytes_sd);
        if (GetFileSecurityW(wide, 4, bytes_sd.ptr, @intCast(bytes_sd.len), &needed) == 0) return error.AccessDenied;
        return bytes_sd;
    }
    fn apply(allocator: Allocator, path: []const u8, bytes_sd: []const u8, protect: ?bool) !void {
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
        defer allocator.free(wide);
        var control: u16 = 0;
        var revision: u32 = 0;
        if (GetSecurityDescriptorControl(bytes_sd.ptr, &control, &revision) == 0) return error.AccessDenied;
        const protected = protect orelse (control & 0x1000 != 0);
        const flags: u32 = 4 | @as(u32, if (protected) 0x80000000 else 0x20000000);
        if (SetFileSecurityW(wide, flags, bytes_sd.ptr) == 0) return error.AccessDenied;
    }
};

fn filePermissions(io: std.Io, path: []const u8) !std.Io.File.Permissions {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    if (builtin.os.tag == .windows) {
        // Zig 0.16 fileStatWindows currently returns .default_file instead
        // of the attributes reported by the OS.
        const w = std.os.windows;
        var status: w.IO_STATUS_BLOCK = undefined;
        var info: w.FILE.BASIC_INFORMATION = undefined;
        switch (w.ntdll.NtQueryInformationFile(file.handle, &status, &info, @sizeOf(w.FILE.BASIC_INFORMATION), .Basic)) {
            .SUCCESS => return @enumFromInt(@as(u32, @bitCast(info.FileAttributes))),
            .ACCESS_DENIED => return error.AccessDenied,
            else => return error.Unexpected,
        }
    }
    return (try file.stat(io)).permissions;
}

fn writeTarget(allocator: Allocator, io: std.Io, path: []const u8, depth: usize) ![]u8 {
    if (depth >= 40) return error.SymLinkLoop;
    const cwd = std.Io.Dir.cwd();
    if (cwd.realPathFileAlloc(io, path, allocator)) |resolved| {
        defer allocator.free(resolved);
        return allocator.dupe(u8, resolved);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    // A dangling link must survive too: resolve its target relative to the
    // link's parent, then create the missing target as an ordinary new file.
    var link: [std.fs.max_path_bytes]u8 = undefined;
    const n = cwd.readLink(io, path, &link) catch |err| switch (err) {
        error.FileNotFound, error.NotLink => return allocator.dupe(u8, path),
        else => return err,
    };
    const joined = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(path) orelse ".", link[0..n] });
    defer allocator.free(joined);
    return writeTarget(allocator, io, joined, depth + 1);
}

test "all formats round trip strictly with BOM and line endings intact" {
    const a = std.testing.allocator;
    for (formats) |base| for ([_]bool{ false, true }) |bom| {
        if (base.encoding == .windows1252 and bom) continue;
        const f: TextFormat = .{ .encoding = base.encoding, .bom = bom };
        const text = if (f.encoding == .windows1252) "café — “€”\r\nfin\n" else "café — 😀界\r\nfin\n";
        const bytes = try encode(a, text, f);
        defer a.free(bytes);
        const decoded = try decode(a, bytes, if (bom) null else f.encoding);
        defer a.free(decoded.text);
        try std.testing.expectEqualStrings(text, decoded.text);
        try std.testing.expectEqualDeep(f, decoded.format);
    };
    try std.testing.expectError(error.EncodingRequired, decode(a, "caf\xe9", null));
    try std.testing.expectError(error.MalformedEncoding, decode(a, "\xff\xfe\x00\xd8", null));
    try std.testing.expectError(error.MalformedEncoding, decode(a, "\xfe\xff\x00", null));
    try std.testing.expectError(error.MalformedEncoding, decode(a, "\x81", .windows1252));
    try std.testing.expectError(error.BinaryFile, decode(a, "a\x00b", null));
    try std.testing.expectError(error.BinaryFile, decode(a, "\xff\xfe\x00\x00", null));
    try std.testing.expectError(error.UnrepresentableText, encode(a, "😀", .{ .encoding = .windows1252 }));
}

test "atomic write failures keep original and remove temporary siblings" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "original.txt" });
    defer a.free(path);
    try atomicWrite(a, io, path, "original");
    for (std.enums.values(FailureStage)) |stage| {
        testing_failure = stage;
        defer testing_failure = null;
        if (atomicWrite(a, io, path, "replacement")) |_| return error.ExpectedFailure else |_| {}
        const bytes = try tmp.dir.readFileAlloc(io, "original.txt", a, .limited(100));
        defer a.free(bytes);
        try std.testing.expectEqualStrings("original", bytes);
        var it = tmp.dir.iterate();
        var count: usize = 0;
        while (try it.next(io)) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

test "atomic save preserves platform file permissions" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "permissions.txt" });
    defer t.allocator.free(path);
    try atomicWrite(t.allocator, t.io, path, "before");
    const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        @enumFromInt(@as(u32, @bitCast(std.os.windows.FILE.ATTRIBUTE{ .HIDDEN = true, .ARCHIVE = true })))
    else
        .fromMode(0o640);
    {
        const file = try tmp.dir.openFile(t.io, "permissions.txt", .{ .mode = .read_write });
        defer file.close(t.io);
        try file.setPermissions(t.io, permissions);
    }
    try atomicWrite(t.allocator, t.io, path, "after");
    const saved_permissions = try filePermissions(t.io, path);
    if (builtin.os.tag == .windows) {
        try t.expectEqual(permissions, saved_permissions);
    } else try t.expectEqual(@intFromEnum(permissions), @intFromEnum(saved_permissions) & 0o7777);
    const readonly: std.Io.File.Permissions = if (builtin.os.tag == .windows)
        @enumFromInt(@as(u32, @bitCast(std.os.windows.FILE.ATTRIBUTE{ .HIDDEN = true, .ARCHIVE = true, .READONLY = true })))
    else
        permissions.setReadOnly(true);
    const file = try tmp.dir.openFile(t.io, "permissions.txt", .{ .mode = .read_write });
    defer file.close(t.io);
    try file.setPermissions(t.io, readonly);
    defer file.setPermissions(t.io, permissions) catch {};
    try t.expectError(error.AccessDenied, atomicWrite(t.allocator, t.io, path, "denied"));
    const bytes = try tmp.dir.readFileAlloc(t.io, "permissions.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("after", bytes);
}

test "atomic save follows existing and dangling file symlinks" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "alias" });
    defer t.allocator.free(path);
    tmp.dir.symLink(t.io, "target", "alias", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer tmp.dir.deleteFile(t.io, "alias") catch {};
    try atomicWrite(t.allocator, t.io, path, "first");
    try atomicWrite(t.allocator, t.io, path, "second");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try tmp.dir.readLink(t.io, "alias", &buf);
    const bytes = try tmp.dir.readFileAlloc(t.io, "target", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("second", bytes);
}

test "Windows atomic replacement preserves protected file DACL" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "acl.txt" });
    defer t.allocator.free(path);
    try atomicWrite(t.allocator, t.io, path, "before");
    const inherited = try WindowsDacl.read(t.allocator, path);
    defer t.allocator.free(inherited);
    try WindowsDacl.apply(t.allocator, path, inherited, true);
    const original = try WindowsDacl.read(t.allocator, path);
    defer t.allocator.free(original);
    try atomicWrite(t.allocator, t.io, path, "after");
    const saved = try WindowsDacl.read(t.allocator, path);
    defer t.allocator.free(saved);
    try t.expectEqualSlices(u8, original, saved);
}
