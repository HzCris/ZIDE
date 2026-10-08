//! File URI encoding at the protocol boundary (RFC 8089).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn encode(allocator: Allocator, path: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const drive = path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
    const unc = std.mem.startsWith(u8, path, "\\\\");
    if (!drive and !unc and !std.mem.startsWith(u8, path, "/")) return error.RelativePath;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, if (drive) "file:///" else if (unc) "file:" else "file://");
    for (path) |byte| {
        const c = if ((drive or unc) and byte == '\\') '/' else byte;
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/:", c) != null) {
            try out.append(allocator, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(allocator, &.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: Allocator, uri: []const u8, windows: bool) ![]const u8 {
    if (uri.len < 5 or !std.ascii.eqlIgnoreCase(uri[0..5], "file:")) return error.UnsupportedUriScheme;
    var path = uri[5..];
    var authority: []const u8 = "";
    if (std.mem.startsWith(u8, path, "//")) {
        path = path[2..];
        const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidFileUri;
        authority = path[0..slash];
        path = path[slash..];
    }
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfAny(u8, path, "?#\\") != null) return error.InvalidFileUri;
    const remote = authority.len != 0 and !std.ascii.eqlIgnoreCase(authority, "localhost");
    if (remote and (!windows or std.mem.indexOfAny(u8, authority, "%:@?#\\") != null)) return error.UnsupportedFileAuthority;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (remote) {
        try out.appendSlice(allocator, "\\\\");
        try out.appendSlice(allocator, authority);
    }
    const local_start = out.items.len;
    var i: usize = 0;
    while (i < path.len) {
        var c = path[i];
        if (c == '%') {
            if (i + 2 >= path.len) return error.InvalidFileUri;
            const hi = std.fmt.charToDigit(path[i + 1], 16) catch return error.InvalidFileUri;
            const lo = std.fmt.charToDigit(path[i + 2], 16) catch return error.InvalidFileUri;
            c = hi * 16 + lo;
            // Encoded separators must not change the path's structure.
            if (c == '/' or (windows and c == '\\')) return error.InvalidFileUri;
            i += 3;
        } else i += 1;
        if (c == 0) return error.InvalidFileUri;
        try out.append(allocator, if (windows and c == '/') '\\' else c);
    }
    // A drive letter is checked after decoding: vscode-uri servers write
    // `file:///c%3A/Users/…`, which must not become the rooted `\c:\Users\…`.
    if (!remote) {
        const local = out.items[local_start..];
        const sep: u8 = if (windows) '\\' else '/';
        if (local.len >= 4 and local[0] == sep and std.ascii.isAlphabetic(local[1]) and local[2] == ':' and local[3] == sep)
            _ = out.orderedRemove(local_start);
    }
    if (!std.unicode.utf8ValidateSlice(out.items)) return error.InvalidFileUri;
    return out.toOwnedSlice(allocator);
}

test "file URI preserves roots and reserved filename bytes on both platforms" {
    const t = std.testing;
    const cases = [_]struct { path: []const u8, uri: []const u8, windows: bool }{
        .{ .path = "/tmp/100%20done#?.zig", .uri = "file:///tmp/100%2520done%23%3F.zig", .windows = false },
        .{ .path = "C:\\project\\100%20done#.zig", .uri = "file:///C:/project/100%2520done%23.zig", .windows = true },
        .{ .path = "\\\\server\\share\\my file.zig", .uri = "file://server/share/my%20file.zig", .windows = true },
        .{ .path = "/tmp/caf\xc3\xa9.zig", .uri = "file:///tmp/caf%C3%A9.zig", .windows = false },
    };
    for (cases) |case| {
        const uri = try encode(t.allocator, case.path);
        defer t.allocator.free(uri);
        try t.expectEqualStrings(case.uri, uri);
        const path = try decode(t.allocator, uri, case.windows);
        defer t.allocator.free(path);
        try t.expectEqualStrings(case.path, path);
    }
    for ([_][]const u8{ "file:///tmp/%", "file:///tmp/%00", "file:///tmp/%2F", "file:///tmp/a#b" }) |bad|
        try t.expectError(error.InvalidFileUri, decode(t.allocator, bad, false));
    try t.expectError(error.UnsupportedUriScheme, decode(t.allocator, "https://example.com", false));
    try t.expectError(error.UnsupportedFileAuthority, decode(t.allocator, "file://remote/share/x", false));
}

test "file URI decodes vscode-style percent-encoded drive letters" {
    const t = std.testing;
    const cases = [_]struct { uri: []const u8, path: []const u8, windows: bool }{
        .{ .uri = "file:///c%3A/Users/x/a.ts", .path = "c:\\Users\\x\\a.ts", .windows = true },
        .{ .uri = "file:///C%3a/Users/x/a.ts", .path = "C:\\Users\\x\\a.ts", .windows = true },
        .{ .uri = "file:///C:/x", .path = "C:\\x", .windows = true },
        .{ .uri = "file://localhost/c%3A/x", .path = "c:\\x", .windows = true },
        .{ .uri = "file://server/c%24/a%20b.ts", .path = "\\\\server\\c$\\a b.ts", .windows = true },
        .{ .uri = "file:///c%3A/x/a.ts", .path = "c:/x/a.ts", .windows = false },
        .{ .uri = "file:///tmp/a%3Ab", .path = "/tmp/a:b", .windows = false },
    };
    for (cases) |case| {
        const path = try decode(t.allocator, case.uri, case.windows);
        defer t.allocator.free(path);
        try t.expectEqualStrings(case.path, path);
        if (case.windows) try t.expect(std.fs.path.isAbsoluteWindows(path));
    }
    // Encoded separators are still refused, before or after the drive.
    for ([_][]const u8{ "file:///c%3A%2FUsers/x", "file:///c%3A/Users%2Fx", "file:///c%3A/Users%5Cx" }) |bad|
        try t.expectError(error.InvalidFileUri, decode(t.allocator, bad, true));
}
