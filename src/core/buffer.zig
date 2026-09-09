const std = @import("std");
const Allocator = std.mem.Allocator;

/// A text buffer using a gap buffer for efficient insert/delete at the cursor.
/// The logical content is `data[0..gap_start] ++ data[gapEnd()..data.len]`.
/// The gap sits at the last edit point; edits near the gap are O(1).
pub const Buffer = struct {
    /// Physical storage including the gap.
    data: []u8 = &[_]u8{},
    /// Total logical content bytes (excludes gap).
    content_len: usize = 0,
    /// Byte position in data[] where the gap starts.
    gap_start: usize = 0,
    /// Cached byte offsets of each line start. line_starts[0] == 0 always.
    /// line_starts[n] is the logical byte offset where line n begins.
    line_starts: std.ArrayList(usize),
    allocator: Allocator,
    /// Scratch buffer for lineContent/slice when the requested range spans the gap.
    scratch: std.ArrayList(u8),
    /// Edit generation — bumped on every content change. Lets caches (e.g.
    /// the find match count) detect staleness without rescanning.
    version: u64 = 0,

    // -- Gap helpers --

    /// Size of the gap in bytes.
    fn gapLen(self: *const Buffer) usize {
        return self.data.len - self.content_len;
    }

    /// Physical index where post-gap content begins.
    fn gapEnd(self: *const Buffer) usize {
        return self.gap_start + self.gapLen();
    }

    /// Convert a logical byte offset to its physical index in data[].
    fn logToPhys(self: *const Buffer, logical: usize) usize {
        if (logical < self.gap_start) return logical;
        return logical + self.gapLen();
    }

    pub fn init(allocator: Allocator) !Buffer {
        var line_starts: std.ArrayList(usize) = .empty;
        errdefer line_starts.deinit(allocator);
        // line_starts[0] == 0 is a hard invariant (offsetToPos underflows
        // without it) — propagate failure instead of silently breaking it.
        try line_starts.append(allocator, 0);
        return .{
            .line_starts = line_starts,
            .allocator = allocator,
            .scratch = .empty,
        };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.data.len > 0) self.allocator.free(self.data);
        self.line_starts.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }

    /// Load text into the buffer, replacing existing content.
    pub fn loadText(self: *Buffer, text: []const u8) !void {
        const gap_size: usize = @max(text.len / 4, 256);
        const total = text.len + gap_size;
        if (self.data.len < total) {
            if (self.data.len > 0) self.allocator.free(self.data);
            self.data = try self.allocator.alloc(u8, total);
        }
        @memcpy(self.data[0..text.len], text);
        self.content_len = text.len;
        self.gap_start = text.len;
        self.version +%= 1;
        try self.rebuildLineIndex();
    }

    /// Load a file into the buffer.
    pub fn loadFile(self: *Buffer, io: std.Io, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const size: usize = @intCast(try file.length(io));

        const gap_size: usize = @max(size / 4, 1024);
        const total = size + gap_size;
        if (self.data.len < total) {
            if (self.data.len > 0) self.allocator.free(self.data);
            self.data = try self.allocator.alloc(u8, total);
        }
        // Tolerate short reads (file shrank between length() and read).
        var file_reader = file.reader(io, &.{});
        const bytes = try file_reader.interface.readSliceShort(self.data[0..size]);
        self.content_len = bytes;
        self.gap_start = bytes;
        self.version +%= 1;
        try self.rebuildLineIndex();
    }

    /// Save the buffer to a file.
    pub fn saveFile(self: *const Buffer, io: std.Io, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        // Write pre-gap content
        if (self.gap_start > 0) {
            try file.writeStreamingAll(io, self.data[0..self.gap_start]);
        }
        // Write post-gap content
        const ge = self.gapEnd();
        if (ge < self.data.len) {
            try file.writeStreamingAll(io, self.data[ge..]);
        }
    }

    /// Total number of bytes in the buffer.
    pub fn byteLen(self: *const Buffer) usize {
        return self.content_len;
    }

    /// Number of lines. Always >= 1 (empty buffer has 1 empty line).
    pub fn lineCount(self: *const Buffer) usize {
        return self.line_starts.items.len;
    }

    /// Get the content of a single line (without newline). Returns empty slice for out-of-bounds.
    pub fn lineContent(self: *Buffer, line: usize) []const u8 {
        if (line >= self.line_starts.items.len) return "";
        const start = self.line_starts.items[line];
        const end = if (line + 1 < self.line_starts.items.len)
            self.line_starts.items[line + 1] - 1 // exclude the \n
        else
            self.content_len;
        if (start >= end) return "";
        const raw = self.getRange(start, end);
        // Strip trailing \r for CRLF support
        if (raw.len > 0 and raw[raw.len - 1] == '\r') {
            return raw[0 .. raw.len - 1];
        }
        return raw;
    }

    /// Get the byte offset for a (line, col) position. Col is in bytes, not characters.
    pub fn posToOffset(self: *const Buffer, line: usize, col: usize) usize {
        if (line >= self.line_starts.items.len) return self.content_len;
        const line_start = self.line_starts.items[line];
        const line_end = if (line + 1 < self.line_starts.items.len)
            self.line_starts.items[line + 1]
        else
            self.content_len;
        return @min(line_start + col, line_end);
    }

    /// Convert a byte offset to (line, col).
    pub fn offsetToPos(self: *const Buffer, offset: usize) struct { line: usize, col: usize } {
        const clamped = @min(offset, self.content_len);
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
        const pos = @min(offset, self.content_len);
        try self.reserveInsert(text.len, std.mem.count(u8, text, "\n"));
        self.moveGap(pos);
        @memcpy(self.data[self.gap_start .. self.gap_start + text.len], text);
        self.gap_start += text.len;
        self.content_len += text.len;
        self.version +%= 1;
        self.updateLineIndexAfterInsert(pos, text);
        return text.len;
    }

    /// Delete `count` bytes starting at `offset`. Returns actual bytes deleted.
    pub fn delete(self: *Buffer, offset: usize, count: usize) usize {
        if (count == 0) return 0;
        const pos = @min(offset, self.content_len);
        const actual = @min(count, self.content_len - pos);
        if (actual == 0) return 0;
        // Move gap to deletion point
        self.moveGap(pos);
        // Text to delete is now contiguous right after the gap
        const ge = self.gapEnd();
        const deleted = self.data[ge .. ge + actual];
        self.updateLineIndexAfterDelete(pos, deleted);
        // Expand gap to absorb deleted text (no data movement)
        self.content_len -= actual;
        self.version +%= 1;
        return actual;
    }

    /// Get a slice of the logical content.
    pub fn slice(self: *Buffer, start: usize, end: usize) []const u8 {
        const s = @min(start, self.content_len);
        const e = @min(end, self.content_len);
        if (s >= e) return "";
        return self.getRange(s, e);
    }

    /// Get the byte at a logical offset, or null if out of bounds.
    pub fn byteAt(self: *const Buffer, offset: usize) ?u8 {
        if (offset >= self.content_len) return null;
        return self.data[self.logToPhys(offset)];
    }

    // -- Internal helpers --

    /// Return a contiguous view of logical bytes [start..end).
    /// If the range doesn't span the gap, returns a direct slice into data[].
    /// If it spans the gap, assembles into the scratch buffer.
    fn getRange(self: *Buffer, start: usize, end: usize) []const u8 {
        if (start >= end) return "";
        const gl = self.gapLen();

        if (end <= self.gap_start) {
            // Entirely before gap
            return self.data[start..end];
        } else if (start >= self.gap_start) {
            // Entirely after gap
            return self.data[start + gl .. end + gl];
        } else {
            // Spans the gap: assemble in scratch buffer
            const pre_len = self.gap_start - start;
            const post_start = self.gapEnd();
            const post_len = end - self.gap_start;
            self.scratch.clearRetainingCapacity();
            self.scratch.ensureTotalCapacity(self.allocator, pre_len + post_len) catch return "";
            self.scratch.appendSlice(self.allocator, self.data[start..self.gap_start]) catch return "";
            self.scratch.appendSlice(self.allocator, self.data[post_start .. post_start + post_len]) catch return "";
            return self.scratch.items;
        }
    }

    /// Move the gap so it starts at logical position `pos`.
    fn moveGap(self: *Buffer, pos: usize) void {
        if (pos == self.gap_start) return;
        const gl = self.gapLen();
        if (pos < self.gap_start) {
            // Move gap left: shift data[pos..gap_start] right by gap_len
            const count = self.gap_start - pos;
            std.mem.copyBackwards(u8, self.data[pos + gl .. pos + gl + count], self.data[pos .. pos + count]);
        } else {
            // Move gap right: shift data[gap_end..pos+gap_len] left by gap_len
            const count = pos - self.gap_start;
            const ge = self.gap_start + gl;
            std.mem.copyForwards(u8, self.data[self.gap_start .. self.gap_start + count], self.data[ge .. ge + count]);
        }
        self.gap_start = pos;
    }

    /// Grow the buffer so the gap has at least `min_extra` bytes.
    fn grow(self: *Buffer, min_extra: usize) !void {
        const new_gap = @max(min_extra * 2, 1024);
        const new_cap = self.content_len + new_gap;
        const new_data = try self.allocator.alloc(u8, new_cap);

        // Copy pre-gap content
        if (self.gap_start > 0) {
            @memcpy(new_data[0..self.gap_start], self.data[0..self.gap_start]);
        }
        // Copy post-gap content to end of new buffer
        const post_len = self.content_len - self.gap_start;
        if (post_len > 0) {
            const old_ge = self.gapEnd();
            @memcpy(new_data[new_cap - post_len .. new_cap], self.data[old_ge .. old_ge + post_len]);
        }

        if (self.data.len > 0) self.allocator.free(self.data);
        self.data = new_data;
        // gap_start stays the same; gap_len = data.len - content_len (now larger)
    }

    /// Rebuild the entire line index from scratch.
    fn rebuildLineIndex(self: *Buffer) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(self.allocator, 0);
        // Pre-gap content
        for (self.data[0..self.gap_start], 0..) |byte, i| {
            if (byte == '\n') {
                try self.line_starts.append(self.allocator, i + 1);
            }
        }
        // Post-gap content
        const ge = self.gapEnd();
        for (self.data[ge..], 0..) |byte, i| {
            if (byte == '\n') {
                try self.line_starts.append(self.allocator, self.gap_start + i + 1);
            }
        }
    }

    /// Reserve buffer and line-index storage before an edit or undo replay.
    pub fn reserveInsert(self: *Buffer, bytes: usize, lines: usize) !void {
        try self.line_starts.ensureUnusedCapacity(self.allocator, lines);
        if (bytes > self.gapLen()) try self.grow(bytes);
    }

    /// Update the index without allocating; insert() reserved its capacity.
    fn updateLineIndexAfterInsert(self: *Buffer, pos: usize, text: []const u8) void {
        const n = std.mem.count(u8, text, "\n");
        var at: usize = 0;
        while (at < self.line_starts.items.len and self.line_starts.items[at] <= pos) : (at += 1) {}
        for (self.line_starts.items[at..]) |*ls| ls.* += text.len;
        const old_len = self.line_starts.items.len;
        self.line_starts.items.len += n;
        std.mem.copyBackwards(usize, self.line_starts.items[at + n ..], self.line_starts.items[at..old_len]);
        var write = at;
        for (text, 0..) |byte, i| if (byte == '\n') {
            self.line_starts.items[write] = pos + i + 1;
            write += 1;
        };
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
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.byteLen());
    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());
    try std.testing.expectEqualStrings("", buf.lineContent(0));
}

test "load text and line access" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("hello\nworld\nfoo");
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
    try std.testing.expectEqualStrings("hello", buf.lineContent(0));
    try std.testing.expectEqualStrings("world", buf.lineContent(1));
    try std.testing.expectEqualStrings("foo", buf.lineContent(2));
}

test "insert and delete" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
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
    var buf = try Buffer.init(allocator);
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
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("ab");
    _ = try buf.insert(1, "x\ny\nz");
    // Content is now "ax\ny\nzb"
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
    try std.testing.expectEqualStrings("ax", buf.lineContent(0));
    try std.testing.expectEqualStrings("y", buf.lineContent(1));
    try std.testing.expectEqualStrings("zb", buf.lineContent(2));
}

test "gap buffer insert at different positions" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("abcdef");
    // Insert at end (gap is already at end after load)
    _ = try buf.insert(6, "g");
    try std.testing.expectEqualStrings("abcdefg", buf.lineContent(0));
    // Insert at beginning (moves gap)
    _ = try buf.insert(0, "Z");
    try std.testing.expectEqualStrings("Zabcdefg", buf.lineContent(0));
    // Insert in middle
    _ = try buf.insert(4, "!");
    try std.testing.expectEqualStrings("Zabc!defg", buf.lineContent(0));
    try std.testing.expectEqual(@as(usize, 9), buf.byteLen());
}

test "gap buffer delete and re-insert" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("hello world");
    // Delete "world"
    _ = buf.delete(6, 5);
    try std.testing.expectEqualStrings("hello ", buf.lineContent(0));
    // Re-insert
    _ = try buf.insert(6, "zig");
    try std.testing.expectEqualStrings("hello zig", buf.lineContent(0));
}

test "gap buffer byteAt" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("abc");
    try std.testing.expectEqual(@as(u8, 'a'), buf.byteAt(0).?);
    try std.testing.expectEqual(@as(u8, 'b'), buf.byteAt(1).?);
    try std.testing.expectEqual(@as(u8, 'c'), buf.byteAt(2).?);
    try std.testing.expect(buf.byteAt(3) == null);

    // Insert in middle — byteAt should still work across gap
    _ = try buf.insert(1, "X");
    try std.testing.expectEqual(@as(u8, 'a'), buf.byteAt(0).?);
    try std.testing.expectEqual(@as(u8, 'X'), buf.byteAt(1).?);
    try std.testing.expectEqual(@as(u8, 'b'), buf.byteAt(2).?);
    try std.testing.expectEqual(@as(u8, 'c'), buf.byteAt(3).?);
}

test "gap buffer slice spanning gap" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try buf.loadText("abcdefghij");
    // Insert in middle to create gap at position 5
    _ = try buf.insert(5, "X");
    // Content: "abcdeXfghij"
    // Slice spanning the gap
    try std.testing.expectEqualStrings("deXfg", buf.slice(3, 8));
    try std.testing.expectEqualStrings("abcdeXfghij", buf.slice(0, 11));
}
