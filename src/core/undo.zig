const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const Cursor = @import("cursor.zig").Cursor;
const CursorSet = @import("cursor.zig").CursorSet;

pub const OpType = enum { insert, delete };

/// Owned primitive edit. Only the first/last operation of a group owns its
/// before/after cursor snapshot, respectively.
pub const UndoOp = struct {
    op_type: OpType,
    offset: usize,
    text: []const u8,
    cursor_before: usize,
    cursor_after: usize,
    group_id: u64 = 0,
    revision_before: u64 = 0,
    revision_after: u64 = 0,
    cursors_before: ?[]Cursor = null,
    cursors_after: ?struct { storage: []Cursor, len: usize } = null,
};

pub const UndoHistory = struct {
    undo_stack: std.ArrayList(UndoOp) = .empty,
    redo_stack: std.ArrayList(UndoOp) = .empty,
    allocator: Allocator,
    next_group_id: u64 = 1,
    recording: bool = true,
    max_size: usize = 100,
    group_depth: u32 = 0,
    active_group: u64 = 0,
    current_revision: u64 = 0,
    next_revision: u64 = 1,
    saved_revision: ?u64 = 0,
    merge_allowed: bool = false,

    pub fn init(allocator: Allocator) UndoHistory {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *UndoHistory) void {
        self.clear();
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }
    fn freeOp(self: *UndoHistory, op: UndoOp) void {
        self.allocator.free(op.text);
        if (op.cursors_before) |s| self.allocator.free(s);
        if (op.cursors_after) |s| self.allocator.free(s.storage);
    }
    pub fn markSaved(self: *UndoHistory) void {
        self.saved_revision = self.current_revision;
        self.merge_allowed = false;
    }
    pub fn isSaved(self: *const UndoHistory) bool {
        return self.saved_revision == self.current_revision;
    }
    pub fn beginGroup(self: *UndoHistory) void {
        if (self.group_depth == 0) {
            self.active_group = self.next_group_id;
            self.next_group_id += 1;
        }
        self.group_depth += 1;
    }
    pub fn endGroup(self: *UndoHistory) void {
        if (self.group_depth > 0) self.group_depth -= 1;
        if (self.group_depth == 0) {
            self.merge_allowed = false;
            self.trimOldest();
        }
    }
    pub fn recordInsert(self: *UndoHistory, offset: usize, text: []const u8, before: usize, after: usize) !void {
        try self.record(.insert, offset, text, before, after);
    }
    pub fn recordDelete(self: *UndoHistory, offset: usize, text: []const u8, before: usize, after: usize) !void {
        try self.record(.delete, offset, text, before, after);
    }
    fn record(self: *UndoHistory, kind: OpType, offset: usize, text: []const u8, before: usize, after: usize) !void {
        if (!self.recording or text.len == 0) return;
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        self.appendPrepared(.{ .op_type = kind, .offset = offset, .text = owned, .cursor_before = before, .cursor_after = after });
    }
    /// Takes ownership; caller reserves stack space and all buffer allocations first.
    pub fn appendPrepared(self: *UndoHistory, prepared: UndoOp) void {
        var op = prepared;
        self.clearRedoStack();
        op.group_id = self.resolveGroupId(op.op_type, op.offset, op.text);
        op.revision_before = self.current_revision;
        op.revision_after = self.next_revision;
        self.next_revision += 1;
        self.current_revision = op.revision_after;
        self.undo_stack.appendAssumeCapacity(op);
        self.merge_allowed = true;
        self.trimOldest();
    }
    /// Takes ownership of snapshots allocated before the edit. Coalesced typing
    /// retains the original before-state and replaces only its after-state.
    pub fn attachCursors(self: *UndoHistory, before: []Cursor, after: []Cursor, count: usize) void {
        const last = self.undo_stack.items.len - 1;
        const gid = self.undo_stack.items[last].group_id;
        var first = last;
        while (first > 0 and self.undo_stack.items[first - 1].group_id == gid) first -= 1;
        if (self.undo_stack.items[first].cursors_before == null) {
            self.undo_stack.items[first].cursors_before = before;
        } else self.allocator.free(before);
        for (self.undo_stack.items[first..]) |*op| {
            if (op.cursors_after) |s| self.allocator.free(s.storage);
            op.cursors_after = null;
        }
        self.undo_stack.items[last].cursors_after = .{ .storage = after, .len = count };
    }
    pub fn undo(self: *UndoHistory, buffer: *Buffer) !?usize {
        return self.replay(buffer, null, false);
    }
    pub fn redo(self: *UndoHistory, buffer: *Buffer) !?usize {
        return self.replay(buffer, null, true);
    }
    pub fn undoCursors(self: *UndoHistory, buffer: *Buffer, cursors: *CursorSet) !bool {
        return (try self.replay(buffer, cursors, false)) != null;
    }
    pub fn redoCursors(self: *UndoHistory, buffer: *Buffer, cursors: *CursorSet) !bool {
        return (try self.replay(buffer, cursors, true)) != null;
    }
    fn replay(self: *UndoHistory, buffer: *Buffer, cursors: ?*CursorSet, forward: bool) !?usize {
        const source = if (forward) &self.redo_stack else &self.undo_stack;
        const target = if (forward) &self.undo_stack else &self.redo_stack;
        if (source.items.len == 0) return null;
        const gid = source.items[source.items.len - 1].group_id;
        var first = source.items.len - 1;
        while (first > 0 and source.items[first - 1].group_id == gid) first -= 1;
        var bytes: usize = 0;
        var lines: usize = 0;
        var snapshot: ?[]Cursor = null;
        for (source.items[first..]) |op| {
            if ((op.op_type == .insert) == forward) {
                bytes += op.text.len;
                lines += std.mem.count(u8, op.text, "\n");
            }
            if (forward) {
                if (op.cursors_after) |s| snapshot = s.storage[0..s.len];
            } else if (op.cursors_before) |s| {
                snapshot = s;
            }
        }
        try target.ensureUnusedCapacity(self.allocator, source.items.len - first);
        try buffer.reserveInsert(bytes, lines);
        if (cursors) |cs| if (snapshot) |s| {
            try cs.cursors.ensureTotalCapacity(cs.allocator, s.len);
        };
        var cursor_pos: usize = 0;
        while (source.items.len > first) {
            const op = source.pop().?;
            if ((op.op_type == .insert) == forward) {
                _ = buffer.insert(op.offset, op.text) catch unreachable; // reserved above
            } else _ = buffer.delete(op.offset, op.text.len);
            cursor_pos = if (forward) op.cursor_after else op.cursor_before;
            self.current_revision = if (forward) op.revision_after else op.revision_before;
            target.appendAssumeCapacity(op);
        }
        if (cursors) |cs| {
            if (snapshot) |s| {
                cs.cursors.items.len = s.len;
                @memcpy(cs.cursors.items, s);
            } else {
                cs.clearSecondary();
                cs.primary().* = .{ .offset = cursor_pos, .preferred_col = buffer.offsetToPos(cursor_pos).col };
            }
        }
        self.merge_allowed = false;
        if (forward) self.trimOldest();
        return cursor_pos;
    }
    pub fn canUndo(self: *const UndoHistory) bool {
        return self.undo_stack.items.len > 0;
    }
    pub fn canRedo(self: *const UndoHistory) bool {
        return self.redo_stack.items.len > 0;
    }
    pub fn clear(self: *UndoHistory) void {
        for (self.undo_stack.items) |op| self.freeOp(op);
        self.undo_stack.clearRetainingCapacity();
        self.clearRedoStack();
        self.group_depth = 0;
        self.current_revision = self.next_revision;
        self.next_revision += 1;
        self.markSaved();
    }
    fn trimOldest(self: *UndoHistory) void {
        if (self.max_size == 0 or self.undo_stack.items.len <= self.max_size) return;
        const newest = self.undo_stack.items[self.undo_stack.items.len - 1].group_id;
        var n: usize = 0;
        while (self.undo_stack.items.len - n > self.max_size) {
            const gid = self.undo_stack.items[n].group_id;
            if (gid == newest) break;
            while (n < self.undo_stack.items.len and self.undo_stack.items[n].group_id == gid) : (n += 1) self.freeOp(self.undo_stack.items[n]);
        }
        std.mem.copyForwards(UndoOp, self.undo_stack.items[0..], self.undo_stack.items[n..]);
        self.undo_stack.items.len -= n;
    }
    fn clearRedoStack(self: *UndoHistory) void {
        for (self.redo_stack.items) |op| self.freeOp(op);
        self.redo_stack.clearRetainingCapacity();
    }
    fn resolveGroupId(self: *UndoHistory, kind: OpType, offset: usize, text: []const u8) u64 {
        if (self.group_depth > 0) return self.active_group;
        if (self.merge_allowed and self.undo_stack.items.len > 0) {
            const prev = self.undo_stack.items[self.undo_stack.items.len - 1];
            if (text.len == 1 and prev.text.len == 1 and text[0] != '\n' and prev.text[0] != '\n' and kind == prev.op_type) {
                if ((kind == .insert and offset == prev.offset + 1) or (kind == .delete and (offset == prev.offset -| 1 or offset == prev.offset))) return prev.group_id;
            }
        }
        defer self.next_group_id += 1;
        return self.next_group_id;
    }
};

// ---- Tests ----

test "undo single insert" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("hello");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();

    // Insert " world" at offset 5
    _ = try buf.insert(5, " world");
    try hist.recordInsert(5, " world", 5, 11);
    try std.testing.expectEqualStrings("hello world", buf.slice(0, buf.byteLen()));

    // Undo
    const cursor = try hist.undo(&buf);
    try std.testing.expectEqual(@as(?usize, 5), cursor);
    try std.testing.expectEqualStrings("hello", buf.slice(0, buf.byteLen()));
}

test "redo after undo" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("hello");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();

    _ = try buf.insert(5, " world");
    try hist.recordInsert(5, " world", 5, 11);

    // Undo
    _ = try hist.undo(&buf);
    try std.testing.expectEqualStrings("hello", buf.slice(0, buf.byteLen()));

    // Redo
    const cursor = try hist.redo(&buf);
    try std.testing.expectEqual(@as(?usize, 11), cursor);
    try std.testing.expectEqualStrings("hello world", buf.slice(0, buf.byteLen()));
}

test "undo delete" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("hello world");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();

    // Delete " world" (offset 5, len 6)
    const deleted = buf.slice(5, 11);
    try hist.recordDelete(5, deleted, 5, 5);
    _ = buf.delete(5, 6);
    try std.testing.expectEqualStrings("hello", buf.slice(0, buf.byteLen()));

    // Undo → restores " world"
    _ = try hist.undo(&buf);
    try std.testing.expectEqualStrings("hello world", buf.slice(0, buf.byteLen()));
}

test "grouping adjacent inserts" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();

    // Type "abc" one char at a time
    _ = try buf.insert(0, "a");
    try hist.recordInsert(0, "a", 0, 1);
    _ = try buf.insert(1, "b");
    try hist.recordInsert(1, "b", 1, 2);
    _ = try buf.insert(2, "c");
    try hist.recordInsert(2, "c", 2, 3);

    try std.testing.expectEqualStrings("abc", buf.slice(0, buf.byteLen()));

    // All three should be in the same group → single undo removes all
    _ = try hist.undo(&buf);
    try std.testing.expectEqualStrings("", buf.slice(0, buf.byteLen()));
}

test "newline breaks group" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();

    // Type "ab\nc"
    _ = try buf.insert(0, "a");
    try hist.recordInsert(0, "a", 0, 1);
    _ = try buf.insert(1, "b");
    try hist.recordInsert(1, "b", 1, 2);
    _ = try buf.insert(2, "\n");
    try hist.recordInsert(2, "\n", 2, 3);
    _ = try buf.insert(3, "c");
    try hist.recordInsert(3, "c", 3, 4);

    try std.testing.expectEqualStrings("ab\nc", buf.slice(0, buf.byteLen()));

    // Undo should remove "c" (group 3)
    _ = try hist.undo(&buf);
    try std.testing.expectEqualStrings("ab\n", buf.slice(0, buf.byteLen()));

    // Undo should remove "\n" (group 2)
    _ = try hist.undo(&buf);
    try std.testing.expectEqualStrings("ab", buf.slice(0, buf.byteLen()));

    // Undo should remove "ab" (group 1)
    _ = try hist.undo(&buf);
    try std.testing.expectEqualStrings("", buf.slice(0, buf.byteLen()));
}

test "explicit group undone as one step" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("hello");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();

    // Multi-char + positionally distant ops would normally be separate groups
    hist.beginGroup();
    _ = buf.delete(0, 2); // "llo"
    try hist.recordDelete(0, "he", 2, 0);
    _ = try buf.insert(3, "!!");
    try hist.recordInsert(3, "!!", 3, 5);
    hist.endGroup();
    try std.testing.expectEqualStrings("llo!!", buf.slice(0, buf.byteLen()));

    // One undo reverts both
    _ = try hist.undo(&buf);
    try std.testing.expectEqualStrings("hello", buf.slice(0, buf.byteLen()));
    try std.testing.expect(!hist.canUndo());

    // One redo re-applies both
    _ = try hist.redo(&buf);
    try std.testing.expectEqualStrings("llo!!", buf.slice(0, buf.byteLen()));
}

test "nested groups join the outermost group" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();

    hist.beginGroup();
    _ = try buf.insert(0, "aa");
    try hist.recordInsert(0, "aa", 0, 2);
    hist.beginGroup(); // nested — same group
    _ = try buf.insert(2, "bb");
    try hist.recordInsert(2, "bb", 2, 4);
    hist.endGroup();
    _ = try buf.insert(4, "cc");
    try hist.recordInsert(4, "cc", 4, 6);
    hist.endGroup();

    _ = try hist.undo(&buf);
    try std.testing.expectEqualStrings("", buf.slice(0, buf.byteLen()));
}

test "trim evicts whole groups only" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();
    hist.max_size = 3;

    // Group of 2 ops, then 2 multi-char singles (each its own group)
    hist.beginGroup();
    _ = try buf.insert(0, "aa");
    try hist.recordInsert(0, "aa", 0, 2);
    _ = try buf.insert(2, "bb");
    try hist.recordInsert(2, "bb", 2, 4);
    hist.endGroup();
    _ = try buf.insert(4, "cc");
    try hist.recordInsert(4, "cc", 4, 6);
    // Stack: [aa, bb, cc] (3 ≤ max). Next op exceeds → the FIRST WHOLE GROUP
    // (aa+bb) must go, never just "aa".
    _ = try buf.insert(6, "dd");
    try hist.recordInsert(6, "dd", 6, 8);
    try std.testing.expectEqual(@as(usize, 2), hist.undo_stack.items.len);

    // Undo both remaining groups — must restore exactly to post-group state
    _ = try hist.undo(&buf); // removes "dd"
    _ = try hist.undo(&buf); // removes "cc"
    try std.testing.expectEqualStrings("aabb", buf.slice(0, buf.byteLen()));
    try std.testing.expect(!hist.canUndo());
}

test "open group exempt from trim until endGroup" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();
    hist.max_size = 2;

    hist.beginGroup();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try buf.insert(i, "x");
        try hist.recordInsert(i, "x", i, i + 1);
    }
    // Open group may exceed the cap without being split
    try std.testing.expectEqual(@as(usize, 5), hist.undo_stack.items.len);
    hist.endGroup();
    // Retain the complete newest group above the limit.
    try std.testing.expectEqual(@as(usize, 5), hist.undo_stack.items.len);
    _ = try hist.undo(&buf);
    try std.testing.expectEqualStrings("", buf.slice(0, buf.byteLen()));
}

test "new edit clears redo" {
    const allocator = std.testing.allocator;
    var buf = try @import("buffer.zig").Buffer.init(allocator);
    defer buf.deinit();
    try buf.loadText("hello");

    var hist = UndoHistory.init(allocator);
    defer hist.deinit();

    _ = try buf.insert(5, "!");
    try hist.recordInsert(5, "!", 5, 6);

    // Undo
    _ = try hist.undo(&buf);
    try std.testing.expect(hist.canRedo());

    // New edit should clear redo
    _ = try buf.insert(5, "?");
    try hist.recordInsert(5, "?", 5, 6);
    try std.testing.expect(!hist.canRedo());
}
