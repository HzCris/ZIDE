const std = @import("std");
const Allocator = std.mem.Allocator;

/// A text buffer storing content as a contiguous byte array with a cached line index.
/// Designed for correctness and clean API first; can be upgraded to a block-based
/// rope (dte pattern) later for large file performance.
pub const Buffer = struct {
    /// Raw text bytes (UTF-8)
    content: std.ArrayList(u8),
    /// Cached byte offsets of each line start. line_starts[0] == 0 always.
    /// line_starts[n] is the byte offset where line n begins.
    line_starts: std.ArrayList(usize),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Buffer {
        var line_starts: std.ArrayList(usize) = .empty;
        // Line 0 always starts at offset 0
        line_starts.append(allocator, 0) catch {};
        return .{
            .content = .empty,
            .line_starts = line_starts,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.content.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
    }

    /// Load text into the buffer, replacing existing content.
    pub fn loadText(self: *Buffer, text: []const u8) !void {
        self.content.clearRetainingCapacity();
        try self.content.appendSlice(self.allocator, text);
        self.rebuildLineIndex();
    }

    /// Load a file into the buffer.
    pub fn loadFile(self: *Buffer, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        const size = stat.size;

        self.content.clearRetainingCapacity();
        try self.content.ensureTotalCapacity(self.allocator, size);
        const bytes = try file.readAll(self.content.allocatedSlice()[0..size]);
        self.content.items.len = bytes;
        self.rebuildLineIndex();
    }

    /// Save the buffer to a file.
    pub fn saveFile(self: *const Buffer, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(self.content.items);
    }

    /// Total number of bytes in the buffer.
    pub fn byteLen(self: *const Buffer) usize {
        return self.content.items.len;
    }

    /// Number of lines. Always >= 1 (empty buffer has 1 empty line).
    pub fn lineCount(self: *const Buffer) usize {
        return self.line_starts.items.len;
    }

    /// Get the content of a single line (without newline). Returns empty slice for out-of-bounds.
    pub fn lineContent(self: *const Buffer, line: usize) []const u8 {
        if (line >= self.line_starts.items.len) return "";
        const start = self.line_starts.items[line];
        const end = if (line + 1 < self.line_starts.items.len)
            self.line_starts.items[line + 1] - 1 // exclude the \n
        else
            self.content.items.len;
        if (start > self.content.items.len) return "";
        const actual_end = @min(end, self.content.items.len);
        if (start >= actual_end) return "";
        // Strip trailing \r for CRLF support
        const line_bytes = self.content.items[start..actual_end];
        if (line_bytes.len > 0 and line_bytes[line_bytes.len - 1] == '\r') {
            return line_bytes[0 .. line_bytes.len - 1];
        }
        return line_bytes;
    }

    /// Get the byte offset for a (line, col) position. Col is in bytes, not characters.
    pub fn posToOffset(self: *const Buffer, line: usize, col: usize) usize {
        if (line >= self.line_starts.items.len) return self.content.items.len;
        const line_start = self.line_starts.items[line];
        const line_end = if (line + 1 < self.line_starts.items.len)
            self.line_starts.items[line + 1]
        else
            self.content.items.len;
        return @min(line_start + col, line_end);
    }

    /// Convert a byte offset to (line, col).
    pub fn offsetToPos(self: *const Buffer, offset: usize) struct { line: usize, col: usize } {
        const clamped = @min(offset, self.content.items.len);
        // Binary search for the line
        var lo: usize = 0;
        var hi: usize = self.line_starts.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts.items[mid] <= clamped) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line = lo - 1;
        const col = clamped - self.line_starts.items[line];
        return .{ .line = line, .col = col };
    }

    /// Insert text at byte offset. Returns the number of bytes inserted.
    pub fn insert(self: *Buffer, offset: usize, text: []const u8) !usize {
        if (text.len == 0) return 0;
        const pos = @min(offset, self.content.items.len);
        try self.content.insertSlice(self.allocator, pos, text);
        self.updateLineIndexAfterInsert(pos, text);
        return text.len;
    }

    /// Delete `count` bytes starting at `offset`. Returns actual bytes deleted.
    pub fn delete(self: *Buffer, offset: usize, count: usize) usize {
        if (count == 0) return 0;
        const pos = @min(offset, self.content.items.len);
        const actual = @min(count, self.content.items.len - pos);
        if (actual == 0) return 0;
        const deleted = self.content.items[pos .. pos + actual];
        self.updateLineIndexAfterDelete(pos, deleted);
        self.content.replaceRange(self.allocator, pos, actual, &.{}) catch {};
        return actual;
    }

    /// Get a slice of the raw content.
    pub fn slice(self: *const Buffer, start: usize, end: usize) []const u8 {
        const s = @min(start, self.content.items.len);
        const e = @min(end, self.content.items.len);
        if (s >= e) return "";
        return self.content.items[s..e];
    }

    /// Get the byte at an offset, or null if out of bounds.
    pub fn byteAt(self: *const Buffer, offset: usize) ?u8 {
        if (offset >= self.content.items.len) return null;
        return self.content.items[offset];
    }

    /// Rebuild the entire line index from scratch.
    fn rebuildLineIndex(self: *Buffer) void {
        self.line_starts.clearRetainingCapacity();
        self.line_starts.append(self.allocator, 0) catch {};
        for (self.content.items, 0..) |byte, i| {
            if (byte == '\n') {
                self.line_starts.append(self.allocator, i + 1) catch {};
            }
        }
    }

    /// Incrementally update line index after inserting text at `pos`.
    fn updateLineIndexAfterInsert(self: *Buffer, pos: usize, text: []const u8) void {
        // Count newlines in inserted text and collect their positions
        var new_lines: std.ArrayList(usize) = .empty;
        defer new_lines.deinit(self.allocator);
        for (text, 0..) |byte, i| {
            if (byte == '\n') {
                new_lines.append(self.allocator, pos + i + 1) catch {};
            }
        }

        // Shift all line starts after pos by text.len
        for (self.line_starts.items) |*ls| {
            if (ls.* > pos) {
                ls.* += text.len;
            }
        }

        // Insert new line starts
        if (new_lines.items.len > 0) {
            // Find insertion point in line_starts
            var insert_idx: usize = self.line_starts.items.len;
            for (self.line_starts.items, 0..) |ls, i| {
                if (ls > pos) {
                    insert_idx = i;
                    break;
                }
            }
            self.line_starts.insertSlice(self.allocator, insert_idx, new_lines.items) catch {};
        }
    }

    /// Incrementally update line index after deleting text that was at `pos`.
    fn updateLineIndexAfterDelete(self: *Buffer, pos: usize, deleted: []const u8) void {
        // Count newlines in deleted text
        var nl_count: usize = 0;
        for (deleted) |byte| {
            if (byte == '\n') nl_count += 1;
        }

        if (nl_count > 0) {
            // Remove line starts that fall within the deleted range
            var write: usize = 0;
            for (self.line_starts.items) |ls| {
                if (ls > pos and ls <= pos + deleted.len) {
                    continue; // skip this line start — it was in the deleted range
                }
                self.line_starts.items[write] = ls;
                write += 1;
            }
            self.line_starts.items.len = write;
        }

        // Shift all line starts after pos by -deleted.len
        for (self.line_starts.items) |*ls| {
            if (ls.* > pos) {
                ls.* -= deleted.len;
            }
        }
    }
};

// ---- Tests ----

test "empty buffer" {
    const allocator = std.testing.allocator;
    var buf = Buffer.init(allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.byteLen());
    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());
    try std.testing.expectEqualStrings("", buf.lineContent(0));
}

test "load text and line access" {
    const allocator = std.testing.allocator;
    var buf = Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("hello\nworld\nfoo");
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
    try std.testing.expectEqualStrings("hello", buf.lineContent(0));
    try std.testing.expectEqualStrings("world", buf.lineContent(1));
    try std.testing.expectEqualStrings("foo", buf.lineContent(2));
}

test "insert and delete" {
    const allocator = std.testing.allocator;
    var buf = Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("hello world");
    _ = try buf.insert(5, "\n");
    try std.testing.expectEqual(@as(usize, 2), buf.lineCount());
    try std.testing.expectEqualStrings("hello", buf.lineContent(0));
    try std.testing.expectEqualStrings(" world", buf.lineContent(1));

    // Delete the newline
    _ = buf.delete(5, 1);
    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());
    try std.testing.expectEqualStrings("hello world", buf.lineContent(0));
}

test "offset to pos conversion" {
    const allocator = std.testing.allocator;
    var buf = Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("abc\ndef\nghi");
    const pos0 = buf.offsetToPos(0);
    try std.testing.expectEqual(@as(usize, 0), pos0.line);
    try std.testing.expectEqual(@as(usize, 0), pos0.col);

    const pos5 = buf.offsetToPos(5);
    try std.testing.expectEqual(@as(usize, 1), pos5.line);
    try std.testing.expectEqual(@as(usize, 1), pos5.col);

    const pos8 = buf.offsetToPos(8);
    try std.testing.expectEqual(@as(usize, 2), pos8.line);
    try std.testing.expectEqual(@as(usize, 0), pos8.col);
}

test "insert multiline text" {
    const allocator = std.testing.allocator;
    var buf = Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("ab");
    _ = try buf.insert(1, "x\ny\nz");
    // Content is now "ax\ny\nzb"
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
    try std.testing.expectEqualStrings("ax", buf.lineContent(0));
    try std.testing.expectEqualStrings("y", buf.lineContent(1));
    try std.testing.expectEqualStrings("zb", buf.lineContent(2));
}
