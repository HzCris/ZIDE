const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Allocator = std.mem.Allocator;

/// Round down to a code-point boundary; the middle of CRLF is not a caret stop.
pub fn floorBoundary(buf: *const Buffer, offset: usize) usize {
    var off = @min(offset, buf.byteLen());
    while (off > 0 and ((buf.byteAt(off) orelse 0) & 0xc0) == 0x80) off -= 1;
    if (off > 0 and buf.byteAt(off) == '\n' and buf.byteAt(off - 1) == '\r') off -= 1;
    return off;
}
pub fn previousBoundary(buf: *const Buffer, offset: usize) usize {
    if (offset == 0) return 0;
    return floorBoundary(buf, @min(offset, buf.byteLen()) - 1);
}
pub fn nextBoundary(buf: *const Buffer, offset: usize) usize {
    const off = floorBoundary(buf, offset);
    if (off >= buf.byteLen()) return buf.byteLen();
    if (buf.byteAt(off) == '\r' and buf.byteAt(off + 1) == '\n') return off + 2;
    return @min(buf.byteLen(), off + utf8ByteLen(buf.byteAt(off).?));
}
pub fn lineOffset(buf: *const Buffer, line: usize, col: usize) usize {
    if (line >= buf.lineCount()) return buf.byteLen();
    const start = buf.line_starts.items[line];
    var end = if (line + 1 < buf.lineCount()) buf.line_starts.items[line + 1] - 1 else buf.byteLen();
    if (end > start and buf.byteAt(end - 1) == '\r') end -= 1;
    return floorBoundary(buf, start + @min(col, end - start));
}

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
        self.offset = lineOffset(buf, line, col);
        self.preferred_col = col;
    }

    /// Move right by one code point, treating CRLF as a single newline.
    pub fn moveRight(self: *Cursor, buf: *const Buffer) void {
        self.offset = nextBoundary(buf, self.offset);
        self.preferred_col = buf.offsetToPos(self.offset).col;
    }

    /// Move left by one code point, treating CRLF as a single newline.
    pub fn moveLeft(self: *Cursor, buf: *const Buffer) void {
        self.offset = previousBoundary(buf, self.offset);
        self.preferred_col = buf.offsetToPos(self.offset).col;
    }

    /// Move up one line, preserving preferred column.
    pub fn moveUp(self: *Cursor, buf: *Buffer) void {
        const p = buf.offsetToPos(self.offset);
        if (p.line == 0) return;
        self.offset = lineOffset(buf, p.line - 1, self.preferred_col);
    }

    /// Move down one line, preserving preferred column.
    pub fn moveDown(self: *Cursor, buf: *Buffer) void {
        const p = buf.offsetToPos(self.offset);
        if (p.line + 1 >= buf.lineCount()) return;
        self.offset = lineOffset(buf, p.line + 1, self.preferred_col);
    }

    /// Move to beginning of current line.
    pub fn moveHome(self: *Cursor, buf: *const Buffer) void {
        const p = buf.offsetToPos(self.offset);
        self.offset = buf.posToOffset(p.line, 0);
        self.preferred_col = 0;
    }

    /// Move up N lines (for Page Up).
    pub fn moveUpN(self: *Cursor, buf: *Buffer, n: usize) void {
        const p = buf.offsetToPos(self.offset);
        const target_line = p.line -| n;
        self.offset = lineOffset(buf, target_line, self.preferred_col);
    }

    /// Move down N lines (for Page Down).
    pub fn moveDownN(self: *Cursor, buf: *Buffer, n: usize) void {
        const p = buf.offsetToPos(self.offset);
        const max_line = buf.lineCount() -| 1;
        const target_line = @min(p.line + n, max_line);
        self.offset = lineOffset(buf, target_line, self.preferred_col);
    }

    /// Move right by one word. Walks bytes via byteAt — a full-buffer slice()
    /// here copied the whole document into scratch whenever the gap was
    /// interior (i.e. after any edit), on every Ctrl+Arrow.
    pub fn moveWordRight(self: *Cursor, buf: *const Buffer) void {
        const len = buf.byteLen();
        var off = floorBoundary(buf, self.offset);
        // Stop at a line end when approaching it, then cross one complete
        // newline on the next command. CRLF must never be split.
        if (buf.byteAt(off) == '\n' or
            (buf.byteAt(off) == '\r' and buf.byteAt(off + 1) == '\n'))
        {
            self.offset = nextBoundary(buf, off);
            self.preferred_col = buf.offsetToPos(self.offset).col;
            return;
        }
        // Skip current word chars
        while (off < len and isWordChar(buf.byteAt(off).?)) off += 1;
        // Skip non-word, non-newline chars (whitespace, punctuation)
        while (off < len) {
            const b = buf.byteAt(off).?;
            if (isWordChar(b) or b == '\n') break;
            off += 1;
        }
        self.offset = floorBoundary(buf, off);
        self.preferred_col = buf.offsetToPos(self.offset).col;
    }

    /// Move left by one word.
    pub fn moveWordLeft(self: *Cursor, buf: *const Buffer) void {
        if (self.offset == 0) return;
        var off = self.offset - 1;
        // Skip non-word chars backwards
        while (off > 0 and !isWordChar(buf.byteAt(off) orelse 0)) off -= 1;
        // Skip word chars backwards to start of word
        while (off > 0 and isWordChar(buf.byteAt(off - 1) orelse 0)) off -= 1;
        self.offset = floorBoundary(buf, off);
        self.preferred_col = buf.offsetToPos(off).col;
    }

    /// Smart Home: move to first non-whitespace on the line,
    /// or to column 0 if already there.
    pub fn moveSmartHome(self: *Cursor, buf: *Buffer) void {
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
    pub fn moveEnd(self: *Cursor, buf: *Buffer) void {
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

    pub fn init(allocator: Allocator) !CursorSet {
        var cs = CursorSet{
            .cursors = .empty,
            .allocator = allocator,
        };
        // Always at least one cursor — primary() indexes [0] unconditionally,
        // so a swallowed failure here would be a guaranteed crash later.
        try cs.cursors.append(allocator, .{});
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

    /// Replace all cursors with a block (column) selection: one cursor per
    /// line between `anchor_line` and `head_line`, each selecting the byte
    /// column span anchor_col..head_col (clamped to that line's length).
    /// Lines shorter than the span get a zero-width cursor at their end —
    /// they still take part in subsequent multi-cursor edits. The head
    /// line's cursor becomes primary so continued dragging extends from it.
    pub fn setBlockSelection(
        self: *CursorSet,
        buffer: *Buffer,
        anchor_line: usize,
        anchor_col: usize,
        head_line: usize,
        head_col: usize,
    ) !void {
        const last_line = buffer.lineCount() -| 1;
        const lo = @min(@min(anchor_line, head_line), last_line);
        const hi = @min(@max(anchor_line, head_line), last_line);

        try self.cursors.ensureTotalCapacity(self.allocator, hi - lo + 1);
        self.cursors.clearRetainingCapacity();
        // Never leave the set empty — primary() indexes [0] unconditionally.
        // Capacity for one cursor is guaranteed: init() appended one.
        errdefer if (self.cursors.items.len == 0) self.cursors.appendAssumeCapacity(.{});

        var line = lo;
        while (line <= hi) : (line += 1) {
            const line_len = buffer.lineContent(line).len;
            const a = @min(anchor_col, line_len);
            const h = @min(head_col, line_len);
            var cur = Cursor{
                .offset = lineOffset(buffer, line, h),
                .preferred_col = head_col,
            };
            if (a != h) cur.anchor = lineOffset(buffer, line, a);
            try self.cursors.append(self.allocator, cur);
        }

        // The drag head must be the primary cursor (index 0). Cursors were
        // appended top-down, so a downward drag leaves the head at the end.
        if (head_line > anchor_line and self.cursors.items.len > 1) {
            const last = self.cursors.items.len - 1;
            std.mem.swap(Cursor, &self.cursors.items[0], &self.cursors.items[last]);
        }
    }

    /// Merge cursors that ended up at the same offset. Keeps primary (index 0) if duplicated.
    pub fn mergeCursors(self: *CursorSet) void {
        if (self.cursors.items.len <= 1) return;
        // Sort secondary cursors (index 1+) by offset for O(n log n) dedup
        if (self.cursors.items.len > 2) {
            std.mem.sort(Cursor, self.cursors.items[1..], {}, struct {
                fn lessThan(_: void, a: Cursor, b: Cursor) bool {
                    return a.offset < b.offset;
                }
            }.lessThan);
        }
        // Linear scan: remove duplicates (same offset as primary or as previous cursor)
        const primary_offset = self.cursors.items[0].offset;
        var write: usize = 1;
        var prev_offset: usize = self.cursors.items[1].offset;
        const is_first_dup = (prev_offset == primary_offset);
        if (!is_first_dup) {
            write = 2;
        }
        var read: usize = 2;
        while (read < self.cursors.items.len) : (read += 1) {
            const cur_offset = self.cursors.items[read].offset;
            if (cur_offset != prev_offset and cur_offset != primary_offset) {
                self.cursors.items[write] = self.cursors.items[read];
                write += 1;
            }
            prev_offset = cur_offset;
        }
        self.cursors.items.len = write;
    }

    /// Fill `buf` with cursor indices sorted by offset descending (highest first).
    /// Returns the filled slice. Caller provides buffer of at least `count()` entries.
    pub fn sortedDescending(self: *const CursorSet, buf: []usize) []usize {
        const n = self.cursors.items.len;
        std.debug.assert(buf.len >= n);
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
    var buf = try Buffer.init(allocator);
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
    var buf = try Buffer.init(allocator);
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

test "block selection: one selecting cursor per line, head is primary" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("alpha one\nbeta two\ngamma three");

    var cs = try CursorSet.init(allocator);
    defer cs.deinit();

    // Drag from (0, 2) down to (2, 7): cols 2..7 on each line
    try cs.setBlockSelection(&buf, 0, 2, 2, 7);
    try std.testing.expectEqual(@as(usize, 3), cs.count());

    // Primary is the drag head (line 2)
    const p = cs.primary().pos(&buf);
    try std.testing.expectEqual(@as(usize, 2), p.line);
    try std.testing.expectEqual(@as(usize, 7), p.col);

    // Every cursor selects bytes 2..7 of its line
    for (cs.cursors.items) |c| {
        const r = c.selectionRange().?;
        const line = buf.offsetToPos(c.offset).line;
        try std.testing.expectEqual(buf.posToOffset(line, 2), r.start);
        try std.testing.expectEqual(buf.posToOffset(line, 7), r.end);
    }
}

test "block selection: short lines clamp, zero-width cursor kept" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("longer line\nab\n\nlonger again");

    var cs = try CursorSet.init(allocator);
    defer cs.deinit();

    // Column span 4..8 — "ab" and the empty line are shorter than 4
    try cs.setBlockSelection(&buf, 0, 4, 3, 8);
    try std.testing.expectEqual(@as(usize, 4), cs.count());

    var zero_width: usize = 0;
    for (cs.cursors.items) |c| {
        const pos = buf.offsetToPos(c.offset);
        if (pos.line == 1 or pos.line == 2) {
            // Clamped to line end, no selection
            try std.testing.expect(!c.hasSelection());
            zero_width += 1;
        } else {
            try std.testing.expect(c.hasSelection());
        }
    }
    try std.testing.expectEqual(@as(usize, 2), zero_width);
}

test "block selection: upward drag keeps head primary, lines clamp to buffer" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("one\ntwo\nthree");

    var cs = try CursorSet.init(allocator);
    defer cs.deinit();

    // Drag upward from (2, 3) to (0, 1)
    try cs.setBlockSelection(&buf, 2, 3, 0, 1);
    try std.testing.expectEqual(@as(usize, 3), cs.count());
    const p = cs.primary().pos(&buf);
    try std.testing.expectEqual(@as(usize, 0), p.line); // head on top line
    try std.testing.expectEqual(@as(usize, 1), p.col);

    // Anchor/head lines past the end clamp instead of crashing
    try cs.setBlockSelection(&buf, 1, 0, 99, 2);
    try std.testing.expectEqual(@as(usize, 2), cs.count());
}

test "cursor set adjust after insert" {
    const allocator = std.testing.allocator;
    var cs = try CursorSet.init(allocator);
    defer cs.deinit();

    cs.primary().offset = 10;
    try cs.addCursor(20);

    cs.adjustAfterInsert(5, 3);
    try std.testing.expectEqual(@as(usize, 13), cs.cursors.items[0].offset);
    try std.testing.expectEqual(@as(usize, 23), cs.cursors.items[1].offset);
}

test "vertical page block and direct positions stay on UTF-8 boundaries" {
    const t = std.testing;
    var buf = try Buffer.init(t.allocator);
    defer buf.deinit();
    try buf.loadText("x\n\xc3\xa9\r\n\xf0\x9f\x98\x80\nabc");
    var c = Cursor{};
    c.gotoPos(&buf, 0, 1);
    c.moveDown(&buf);
    try t.expectEqual(@as(usize, 2), c.offset);
    try t.expectEqual(@as(usize, 1), c.preferred_col);
    c.moveDownN(&buf, 1);
    try t.expectEqual(@as(usize, 6), c.offset);
    c.moveDown(&buf);
    try t.expectEqual(@as(usize, 12), c.offset);
    c.moveUpN(&buf, 2);
    try t.expectEqual(@as(usize, 2), c.offset);
    c.gotoPos(&buf, 2, 3);
    try t.expectEqual(@as(usize, 6), c.offset);
    c.gotoPos(&buf, 1, 99);
    try t.expectEqual(@as(usize, 4), c.offset);
    c.moveRight(&buf);
    try t.expectEqual(@as(usize, 6), c.offset);
    c.moveLeft(&buf);
    try t.expectEqual(@as(usize, 4), c.offset);
    var cs = try CursorSet.init(t.allocator);
    defer cs.deinit();
    try cs.setBlockSelection(&buf, 0, 1, 2, 3);
    for (cs.cursors.items) |cur| {
        try t.expectEqual(cur.offset, floorBoundary(&buf, cur.offset));
        if (cur.anchor) |a| try t.expectEqual(a, floorBoundary(&buf, a));
    }
}
