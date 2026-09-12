//! Bounded, single-line UTF-8 input shared by the frontends.
const std = @import("std");

pub fn floor(text: []const u8, limit: usize) usize {
    var n = @min(text.len, limit);
    while (n > 0 and n < text.len and text[n] & 0xc0 == 0x80) n -= 1;
    return n;
}

pub fn append(buf: []u8, len: *usize, text: []const u8) void {
    const view = std.unicode.Utf8View.init(text) catch return;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch unreachable;
        if (cp < 32 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x2028 or cp == 0x2029) continue;
        if (bytes.len > buf.len - len.*) break;
        @memcpy(buf[len.*..][0..bytes.len], bytes);
        len.* += bytes.len;
    }
}

pub fn appendCodepoint(buf: []u8, len: *usize, cp: u21) void {
    var bytes: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &bytes) catch return;
    append(buf, len, bytes[0..n]);
}

pub fn backspace(buf: []const u8, len: *usize) void {
    if (len.* > 0) len.* = floor(buf[0..len.*], len.* - 1);
}

pub fn set(buf: []u8, len: *usize, text: []const u8) void {
    len.* = 0;
    append(buf, len, text);
}

test "single-line Unicode input rejects malformed sequences and respects capacity" {
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    append(&buf, &len, "é😀界");
    try std.testing.expectEqualStrings("é😀", buf[0..len]);
    backspace(&buf, &len);
    try std.testing.expectEqualStrings("é", buf[0..len]);
    append(&buf, &len, "x\xff");
    try std.testing.expectEqualStrings("é", buf[0..len]);
    append(&buf, &len, "\r\n\t\x1bA");
    appendCodepoint(&buf, &len, 0x754c);
    try std.testing.expectEqualStrings("éA界", buf[0..len]);
    set(&buf, &len, "😀😀x");
    try std.testing.expectEqualStrings("😀😀", buf[0..len]);
}
