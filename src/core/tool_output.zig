//! Bounded, indexed UTF-8 tool output. Escape sequences are never rendered as controls.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Sanitizer = struct {
    escape: enum { none, esc, csi, string, string_esc } = .none,
    pending: [4]u8 = undefined,
    len: u3 = 0,
    expected: u3 = 0,

    pub fn feed(self: *Sanitizer, allocator: Allocator, out: *std.ArrayList(u8), bytes: []const u8, done: bool) !void {
        for (bytes) |byte| {
            switch (self.escape) {
                .esc => {
                    self.escape = switch (byte) {
                        '[' => .csi,
                        ']', 'P', '^', '_' => .string,
                        else => .none,
                    };
                    continue;
                },
                .csi => {
                    if (byte >= 0x40 and byte <= 0x7e) self.escape = .none;
                    continue;
                },
                .string => {
                    if (byte == 7) self.escape = .none else if (byte == 27) self.escape = .string_esc;
                    continue;
                },
                .string_esc => {
                    self.escape = if (byte == '\\') .none else .string;
                    continue;
                },
                .none => {},
            }
            if (self.len > 0) {
                if (byte & 0xc0 == 0x80) {
                    self.pending[self.len] = byte;
                    self.len += 1;
                    if (self.len == self.expected) {
                        try out.appendSlice(allocator, if (std.unicode.utf8ValidateSlice(self.pending[0..self.len])) self.pending[0..self.len] else "�");
                        self.len = 0;
                    }
                    continue;
                }
                try out.appendSlice(allocator, "�");
                self.len = 0;
            }
            if (byte == 27) {
                self.escape = .esc;
                continue;
            }
            if (byte < 32 and byte != '\n' and byte != '\t') continue;
            if (byte == 127) continue;
            if (byte < 128) {
                try out.append(allocator, byte);
                continue;
            }
            self.expected = std.unicode.utf8ByteSequenceLength(byte) catch {
                try out.appendSlice(allocator, "�");
                continue;
            };
            self.pending[0] = byte;
            self.len = 1;
        }
        if (done and self.len > 0) {
            try out.appendSlice(allocator, "�");
            self.len = 0;
        }
    }
};

pub const Output = struct {
    text: std.ArrayList(u8) = .empty,
    starts: std.ArrayList(usize) = .empty,
    truncated: bool = false,
    pub fn deinit(self: *Output, allocator: Allocator) void {
        self.text.deinit(allocator);
        self.starts.deinit(allocator);
    }
    pub fn append(self: *Output, allocator: Allocator, bytes: []const u8) !void {
        var length = @min((4 * 1024 * 1024) -| self.text.items.len, bytes.len);
        while (length < bytes.len and length > 0 and bytes[length] & 0xc0 == 0x80) length -= 1;
        const offset = self.text.items.len;
        try self.text.ensureUnusedCapacity(allocator, length);
        try self.starts.ensureUnusedCapacity(allocator, std.mem.count(u8, bytes[0..length], "\n"));
        self.text.appendSliceAssumeCapacity(bytes[0..length]);
        for (bytes[0..length], 0..) |byte, i| if (byte == '\n') {
            self.starts.appendAssumeCapacity(offset + i + 1);
        };
        self.truncated = self.truncated or length < bytes.len;
    }
    pub fn count(self: *const Output) usize {
        return self.starts.items.len + 1;
    }
    pub fn line(self: *const Output, index: usize) []const u8 {
        if (index >= self.count()) return "";
        const start = if (index == 0) 0 else self.starts.items[index - 1];
        const end = if (index < self.starts.items.len) self.starts.items[index] - 1 else self.text.items.len;
        return self.text.items[start..end];
    }
};

test "streamed output removes ANSI strings and preserves split UTF-8" {
    const a = std.testing.allocator;
    var filter: Sanitizer = .{};
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try filter.feed(a, &bytes, "\x1b[31mca\xc3", false);
    try filter.feed(a, &bytes, "\xa9\x1b[0m\x1b]title\x07\n\xff", true);
    try std.testing.expectEqualStrings("caé\n�", bytes.items);
    var output: Output = .{};
    defer output.deinit(a);
    try output.append(a, bytes.items);
    try std.testing.expectEqualStrings("�", output.line(1));
}
