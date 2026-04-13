const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Allocator = std.mem.Allocator;

/// A cursor position in the buffer.
pub const Cursor = struct {
    /// Byte offset into the buffer content.
    offset: usize = 0,
    /// Desired column for vertical movement (preserved across up/down).
    /// Stored as byte column, not character column.
    preferred_col: usize = 0,
    /// Selection anchor. If set, selection is between anchor and offset.
    anchor: ?usize = null,

    /// Position type returned by Buffer.offsetToPos.
    pub const Pos = @TypeOf(@as(Buffer, undefined).offsetToPos(0));

    /// Get (line, col) from this cursor's offset.
    pub fn pos(self: *const Cursor, buf: *const Buffer) Pos {
        return buf.offsetToPos(self.offset);
    }

    /// Move cursor to a specific (line, col).
    pub fn gotoPos(self: *Cursor, buf: *const Buffer, line: usize, col: usize) void {
        self.offset = buf.posToOffset(line, col);
        self.preferred_col = col;
    }

    /// Move right by one byte (UTF-8 aware: skip continuation bytes).
    pub fn moveRight(self: *Cursor, buf: *const Buffer) void {
        if (self.offset >= buf.byteLen()) return;
        self.offset += utf8ByteLen(buf.content.items[self.offset]);
        self.offset = @min(self.offset, buf.byteLen());
        self.preferred_col = buf.offsetToPos(self.offset).col;
    }

    /// Move left by one byte (UTF-8 aware: skip back over continuation bytes).
    pub fn moveLeft(self: *Cursor, buf: *const Buffer) void {
        if (self.offset == 0) return;
        self.offset -= 1;
        // Skip UTF-8 continuation bytes (10xxxxxx)
        while (self.offset > 0 and (buf.content.items[self.offset] & 0xC0) == 0x80) {
            self.offset -= 1;
        }
        self.preferred_col = buf.offsetToPos(self.offset).col;
    }

    /// Move up one line, preserving preferred column.
    pub fn moveUp(self: *Cursor, buf: *const Buffer) void {
        const p = buf.offsetToPos(self.offset);
        if (p.line == 0) return;
        self.offset = buf.posToOffset(p.line - 1, self.preferred_col);
        // Clamp to end of target line
        const target_line_len = buf.lineContent(p.line - 1).len;
        if (self.preferred_col > target_line_len) {
            self.offset = buf.posToOffset(p.line - 1, target_line_len);
        }
    }

    /// Move down one line, preserving preferred column.
    pub fn moveDown(self: *Cursor, buf: *const Buffer) void {
        const p = buf.offsetToPos(self.offset);
        if (p.line + 1 >= buf.lineCount()) return;
        self.offset = buf.posToOffset(p.line + 1, self.preferred_col);
        // Clamp to end of target line
        const target_line_len = buf.lineContent(p.line + 1).len;
        if (self.preferred_col > target_line_len) {
            self.offset = buf.posToOffset(p.line + 1, target_line_len);
        }
    }

    /// Move to beginning of current line.
    pub fn moveHome(self: *Cursor, buf: *const Buffer) void {
        const p = buf.offsetToPos(self.offset);
        self.offset = buf.posToOffset(p.line, 0);
        self.preferred_col = 0;
    }

    /// Move up N lines (for Page Up).
    pub fn moveUpN(self: *Cursor, buf: *const Buffer, n: usize) void {
        const p = buf.offsetToPos(self.offset);
        const target_line = p.line -| n;
        self.offset = buf.posToOffset(target_line, self.preferred_col);
        const target_line_len = buf.lineContent(target_line).len;
        if (self.preferred_col > target_line_len) {
            self.offset = buf.posToOffset(target_line, target_line_len);
        }
    }

    /// Move down N lines (for Page Down).
    pub fn moveDownN(self: *Cursor, buf: *const Buffer, n: usize) void {
        const p = buf.offsetToPos(self.offset);
        const max_line = buf.lineCount() -| 1;
        const target_line = @min(p.line + n, max_line);
        self.offset = buf.posToOffset(target_line, self.preferred_col);
        const target_line_len = buf.lineContent(target_line).len;
        if (self.preferred_col > target_line_len) {
            self.offset = buf.posToOffset(target_line, target_line_len);
        }
    }

    /// Move right by one word.
    pub fn moveWordRight(self: *Cursor, buf: *const Buffer) void {
        const content = buf.slice(0, buf.byteLen());
        var off = self.offset;
        // Skip current word chars
        while (off < content.len and isWordChar(content[off])) off += 1;
        // Skip non-word, non-newline chars (whitespace, punctuation)
        while (off < content.len and !isWordChar(content[off]) and content[off] != '\n') off += 1;
        self.offset = off;
        self.preferred_col = buf.offsetToPos(off).col;
    }

    /// Move left by one word.
    pub fn moveWordLeft(self: *Cursor, buf: *const Buffer) void {
        const content = buf.slice(0, buf.byteLen());
        if (self.offset == 0) return;
        var off = self.offset - 1;
        // Skip non-word chars backwards
        while (off > 0 and !isWordChar(content[off])) off -= 1;
        // Skip word chars backwards to start of word
        while (off > 0 and isWordChar(content[off - 1])) off -= 1;
        self.offset = off;
        self.preferred_col = buf.offsetToPos(off).col;
    }

    /// Smart Home: move to first non-whitespace on the line,
    /// or to column 0 if already there.
    pub fn moveSmartHome(self: *Cursor, buf: *const Buffer) void {
        const p = buf.offsetToPos(self.offset);
        const line = buf.lineContent(p.line);
        var first_non_ws: usize = 0;
        for (line) |ch| {
            if (ch != ' ' and ch != '\t') break;
            first_non_ws += 1;
        }
        if (p.col == first_non_ws or first_non_ws >= line.len) {
            // Already at first non-ws (or line is all whitespace): go to col 0
            self.offset = buf.posToOffset(p.line, 0);
            self.preferred_col = 0;
        } else {
            self.offset = buf.posToOffset(p.line, first_non_ws);
            self.preferred_col = first_non_ws;
        }
    }

    /// Move to start of buffer.
    pub fn moveToStart(self: *Cursor) void {
        self.offset = 0;
        self.preferred_col = 0;
    }

    /// Move to end of buffer.
    pub fn moveToEnd(self: *Cursor, buf: *const Buffer) void {
        self.offset = buf.byteLen();
        self.preferred_col = buf.offsetToPos(self.offset).col;
    }

    /// Move to end of current line.
    pub fn moveEnd(self: *Cursor, buf: *const Buffer) void {
        const p = buf.offsetToPos(self.offset);
        const line_len = buf.lineContent(p.line).len;
        self.offset = buf.posToOffset(p.line, line_len);
        self.preferred_col = line_len;
    }

    /// Start a selection from current position (set anchor).
    pub fn startSelection(self: *Cursor) void {
        self.anchor = self.offset;
    }

    /// Clear the selection.
    pub fn clearSelection(self: *Cursor) void {
        self.anchor = null;
    }

    /// Get the selection range (start, end) as byte offsets, or null if no selection.
    pub fn selectionRange(self: *const Cursor) ?struct { start: usize, end: usize } {
        const a = self.anchor orelse return null;
        if (a <= self.offset) {
            return .{ .start = a, .end = self.offset };
        } else {
            return .{ .start = self.offset, .end = a };
        }
    }

    /// Check if this cursor has an active selection.
    pub fn hasSelection(self: *const Cursor) bool {
        return self.anchor != null;
    }
};

/// A set of cursors supporting multi-cursor editing.
pub const CursorSet = struct {
    cursors: std.ArrayList(Cursor),
    allocator: Allocator,

    pub fn init(allocator: Allocator) CursorSet {
        var cs = CursorSet{
            .cursors = .empty,
            .allocator = allocator,
        };
        // Always have at least one cursor
        cs.cursors.append(allocator, .{}) catch {};
        return cs;
    }

    pub fn deinit(self: *CursorSet) void {
        self.cursors.deinit(self.allocator);
    }

    /// The primary (first) cursor.
    pub fn primary(self: *CursorSet) *Cursor {
        return &self.cursors.items[0];
    }

    pub fn primaryConst(self: *const CursorSet) *const Cursor {
        return &self.cursors.items[0];
    }

    /// Add a cursor at offset. Deduplicates (won't add if one already exists there).
    pub fn addCursor(self: *CursorSet, offset: usize) !void {
        for (self.cursors.items) |c| {
            if (c.offset == offset) return;
        }
        try self.cursors.append(self.allocator, .{ .offset = offset });
    }

    /// Remove all cursors except the primary.
    pub fn clearSecondary(self: *CursorSet) void {
        if (self.cursors.items.len > 1) {
            self.cursors.items.len = 1;
        }
    }

    /// Number of active cursors.
    pub fn count(self: *const CursorSet) usize {
        return self.cursors.items.len;
    }

    /// Remove a cursor by index. Won't remove the last cursor.
    pub fn removeCursor(self: *CursorSet, idx: usize) void {
        if (self.cursors.items.len <= 1) return;
        if (idx >= self.cursors.items.len) return;
        _ = self.cursors.orderedRemove(idx);
    }

    /// Merge cursors that ended up at the same offset. Keeps primary (index 0) if duplicated.
    pub fn mergeCursors(self: *CursorSet) void {
        if (self.cursors.items.len <= 1) return;
        var i: usize = 1;
        while (i < self.cursors.items.len) {
            var dup = false;
            for (self.cursors.items[0..i]) |existing| {
                if (self.cursors.items[i].offset == existing.offset) {
                    dup = true;
                    break;
                }
            }
            if (dup) {
                _ = self.cursors.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Fill `buf` with cursor indices sorted by offset descending (highest first).
    /// Returns the filled slice. Caller provides buffer of at least `count()` entries.
    pub fn sortedDescending(self: *const CursorSet, buf: []usize) []usize {
        const n = @min(self.cursors.items.len, buf.len);
        for (0..n) |i| buf[i] = i;
        const items = self.cursors.items;
        std.mem.sort(usize, buf[0..n], items, struct {
            fn cmp(ctx: []const Cursor, a: usize, b: usize) bool {
                return ctx[a].offset > ctx[b].offset;
            }
        }.cmp);
        return buf[0..n];
    }

    /// Adjust all cursor offsets after an insert at `pos` of `len` bytes.
    pub fn adjustAfterInsert(self: *CursorSet, pos: usize, len: usize) void {
        for (self.cursors.items) |*c| {
            if (c.offset >= pos) {
                c.offset += len;
            }
            if (c.anchor) |*a| {
                if (a.* >= pos) {
                    a.* += len;
                }
            }
        }
    }

    /// Adjust all cursor offsets after a delete at `pos` of `len` bytes.
    pub fn adjustAfterDelete(self: *CursorSet, pos: usize, len: usize) void {
        for (self.cursors.items) |*c| {
            if (c.offset > pos) {
                if (c.offset >= pos + len) {
                    c.offset -= len;
                } else {
                    c.offset = pos;
                }
            }
            if (c.anchor) |*a| {
                if (a.* > pos) {
                    if (a.* >= pos + len) {
                        a.* -= len;
                    } else {
                        a.* = pos;
                    }
                }
            }
        }
    }

    /// Adjust all cursor offsets EXCEPT `skip_idx` after an insert.
    pub fn adjustOthersAfterInsert(self: *CursorSet, skip_idx: usize, pos: usize, len: usize) void {
        for (self.cursors.items, 0..) |*c, i| {
            if (i == skip_idx) continue;
            if (c.offset >= pos) c.offset += len;
            if (c.anchor) |*a| {
                if (a.* >= pos) a.* += len;
            }
        }
    }

    /// Adjust all cursor offsets EXCEPT `skip_idx` after a delete.
    pub fn adjustOthersAfterDelete(self: *CursorSet, skip_idx: usize, pos: usize, len: usize) void {
        for (self.cursors.items, 0..) |*c, i| {
            if (i == skip_idx) continue;
            if (c.offset > pos) {
                c.offset = if (c.offset >= pos + len) c.offset - len else pos;
            }
            if (c.anchor) |*a| {
                if (a.* > pos) {
                    a.* = if (a.* >= pos + len) a.* - len else pos;
                }
            }
        }
    }
};

fn isWordChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn utf8ByteLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte & 0xE0 == 0xC0) return 2;
    if (first_byte & 0xF0 == 0xE0) return 3;
    if (first_byte & 0xF8 == 0xF0) return 4;
    return 1; // invalid byte, treat as single
}

// ---- Tests ----

test "cursor movement" {
    const allocator = std.testing.allocator;
    var buf = Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("hello\nworld");

    var cursor: Cursor = .{};
    try std.testing.expectEqual(@as(usize, 0), cursor.offset);

    cursor.moveRight(&buf);
    try std.testing.expectEqual(@as(usize, 1), cursor.offset);

    cursor.moveEnd(&buf);
    try std.testing.expectEqual(@as(usize, 5), cursor.offset);

    cursor.moveDown(&buf);
    const p = cursor.pos(&buf);
    try std.testing.expectEqual(@as(usize, 1), p.line);
    try std.testing.expectEqual(@as(usize, 5), p.col);

    cursor.moveHome(&buf);
    try std.testing.expectEqual(@as(usize, 6), cursor.offset);
}

test "cursor preferred column" {
    const allocator = std.testing.allocator;
    var buf = Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("long line here\nhi\nanother long line");

    var cursor: Cursor = .{};
    cursor.moveEnd(&buf); // end of "long line here" → col 14
    try std.testing.expectEqual(@as(usize, 14), cursor.preferred_col);

    cursor.moveDown(&buf); // "hi" only has 2 chars, should clamp
    const p = cursor.pos(&buf);
    try std.testing.expectEqual(@as(usize, 1), p.line);
    try std.testing.expectEqual(@as(usize, 2), p.col);
    // preferred_col should still be 14
    try std.testing.expectEqual(@as(usize, 14), cursor.preferred_col);

    cursor.moveDown(&buf); // "another long line" → should restore to col 14
    const p2 = cursor.pos(&buf);
    try std.testing.expectEqual(@as(usize, 2), p2.line);
    try std.testing.expectEqual(@as(usize, 14), p2.col);
}

test "selection" {
    var cursor: Cursor = .{ .offset = 5 };
    try std.testing.expect(!cursor.hasSelection());

    cursor.startSelection();
    cursor.offset = 10;
    try std.testing.expect(cursor.hasSelection());

    const range = cursor.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 5), range.start);
    try std.testing.expectEqual(@as(usize, 10), range.end);

    cursor.clearSelection();
    try std.testing.expect(!cursor.hasSelection());
}

test "cursor set adjust after insert" {
    const allocator = std.testing.allocator;
    var cs = CursorSet.init(allocator);
    defer cs.deinit();

    cs.primary().offset = 10;
    try cs.addCursor(20);

    cs.adjustAfterInsert(5, 3);
    try std.testing.expectEqual(@as(usize, 13), cs.cursors.items[0].offset);
    try std.testing.expectEqual(@as(usize, 23), cs.cursors.items[1].offset);
}
