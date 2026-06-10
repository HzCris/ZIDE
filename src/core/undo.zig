const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;

/// Type of edit operation recorded for undo/redo.
pub const OpType = enum {
    insert,
    delete,
};

/// A single undo operation recording what was inserted or deleted.
pub const UndoOp = struct {
    op_type: OpType,
    /// Byte offset where the operation occurred.
    offset: usize,
    /// The text that was inserted (for insert) or deleted (for delete).
    /// Owned by the UndoHistory allocator.
    text: []const u8,
    /// Cursor offset before the operation.
    cursor_before: usize,
    /// Cursor offset after the operation.
    cursor_after: usize,
    /// Group ID for merging adjacent operations.
    group_id: u32,
};

/// Undo/redo history for a document.
pub const UndoHistory = struct {
    undo_stack: std.ArrayList(UndoOp),
    redo_stack: std.ArrayList(UndoOp),
    allocator: Allocator,
    next_group_id: u32 = 1,
    /// Whether we're currently replaying (undo/redo in progress).
    recording: bool = true,
    /// Maximum number of undo operations to keep (0 = unlimited).
    max_size: usize = 100,
    /// Explicit group nesting depth (beginGroup/endGroup). While > 0, all
    /// recorded ops share `active_group` so one undo reverts them together.
    group_depth: u32 = 0,
    /// Forced group id while group_depth > 0.
    active_group: u32 = 0,

    pub fn init(allocator: Allocator) UndoHistory {
        return .{
            .undo_stack = .empty,
            .redo_stack = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UndoHistory) void {
        for (self.undo_stack.items) |op| {
            self.allocator.free(op.text);
        }
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |op| {
            self.allocator.free(op.text);
        }
        self.redo_stack.deinit(self.allocator);
    }

    /// Begin an explicit undo group: every operation recorded until the
    /// matching endGroup shares one group id (single undo step).
    /// Re-entrant — nested begin/end pairs join the outermost group.
    pub fn beginGroup(self: *UndoHistory) void {
        if (self.group_depth == 0) {
            self.active_group = self.next_group_id;
            self.next_group_id += 1;
        }
        self.group_depth += 1;
    }

    /// End an explicit undo group started with beginGroup.
    pub fn endGroup(self: *UndoHistory) void {
        if (self.group_depth > 0) self.group_depth -= 1;
        // Oversized groups are exempt from trimming while open; enforce the
        // cap once the group is complete (may evict the whole group).
        if (self.group_depth == 0) self.trimOldest();
    }

    /// Record an insert operation.
    pub fn recordInsert(self: *UndoHistory, offset: usize, text: []const u8, cursor_before: usize, cursor_after: usize) !void {
        if (!self.recording) return;
        self.clearRedoStack();
        const group_id = self.resolveGroupId(.insert, offset, text);
        const owned_text = try self.allocator.dupe(u8, text);
        try self.undo_stack.append(self.allocator, .{
            .op_type = .insert,
            .offset = offset,
            .text = owned_text,
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
            .group_id = group_id,
        });
        self.trimOldest();
    }

    /// Record a delete operation.
    pub fn recordDelete(self: *UndoHistory, offset: usize, deleted_text: []const u8, cursor_before: usize, cursor_after: usize) !void {
        if (!self.recording) return;
        self.clearRedoStack();
        const group_id = self.resolveGroupId(.delete, offset, deleted_text);
        const owned_text = try self.allocator.dupe(u8, deleted_text);
        try self.undo_stack.append(self.allocator, .{
            .op_type = .delete,
            .offset = offset,
            .text = owned_text,
            .cursor_before = cursor_before,
            .cursor_after = cursor_after,
            .group_id = group_id,
        });
        self.trimOldest();
    }

    /// Undo one group of operations. Returns the cursor position to restore, or null if nothing to undo.
    pub fn undo(self: *UndoHistory, buffer: *Buffer) !?usize {
        if (self.undo_stack.items.len == 0) return null;

        self.recording = false;
        defer self.recording = true;

        const group_id = self.undo_stack.items[self.undo_stack.items.len - 1].group_id;
        var cursor_pos: usize = 0;

        // Undo all ops in this group (they're in order, undo in reverse)
        while (self.undo_stack.items.len > 0) {
            const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (top.group_id != group_id) break;

            const op = self.undo_stack.pop().?;
            cursor_pos = op.cursor_before;

            // Reverse the operation
            switch (op.op_type) {
                .insert => {
                    // Undo insert = delete
                    _ = buffer.delete(op.offset, op.text.len);
                },
                .delete => {
                    // Undo delete = insert
                    _ = try buffer.insert(op.offset, op.text);
                },
            }

            // Move to redo stack
            try self.redo_stack.append(self.allocator, op);
        }

        return cursor_pos;
    }

    /// Redo one group of operations. Returns the cursor position to restore, or null if nothing to redo.
    pub fn redo(self: *UndoHistory, buffer: *Buffer) !?usize {
        if (self.redo_stack.items.len == 0) return null;

        self.recording = false;
        defer self.recording = true;

        const group_id = self.redo_stack.items[self.redo_stack.items.len - 1].group_id;
        var cursor_pos: usize = 0;

        while (self.redo_stack.items.len > 0) {
            const top = &self.redo_stack.items[self.redo_stack.items.len - 1];
            if (top.group_id != group_id) break;

            const op = self.redo_stack.pop().?;
            cursor_pos = op.cursor_after;

            // Re-apply the operation
            switch (op.op_type) {
                .insert => {
                    _ = try buffer.insert(op.offset, op.text);
                },
                .delete => {
                    _ = buffer.delete(op.offset, op.text.len);
                },
            }

            // Move back to undo stack
            try self.undo_stack.append(self.allocator, op);
        }

        return cursor_pos;
    }

    /// Check if there are operations to undo.
    pub fn canUndo(self: *const UndoHistory) bool {
        return self.undo_stack.items.len > 0;
    }

    /// Check if there are operations to redo.
    pub fn canRedo(self: *const UndoHistory) bool {
        return self.redo_stack.items.len > 0;
    }

    /// Clear all history (e.g., after loading a new file).
    pub fn clear(self: *UndoHistory) void {
        for (self.undo_stack.items) |op| {
            self.allocator.free(op.text);
        }
        self.undo_stack.items.len = 0;
        self.clearRedoStack();
        self.next_group_id = 1;
        self.group_depth = 0;
    }

    // --- Internal ---

    /// Evict oldest undo operations if the stack exceeds max_size.
    /// Always evicts whole groups — a partially trimmed group would apply a
    /// partial undo and corrupt the buffer. The currently open group (if any)
    /// is exempt until endGroup, so the stack may transiently exceed max_size.
    fn trimOldest(self: *UndoHistory) void {
        if (self.max_size == 0) return; // unlimited
        if (self.undo_stack.items.len <= self.max_size) return;
        var evict_to: usize = 0;
        while (self.undo_stack.items.len - evict_to > self.max_size) {
            const gid = self.undo_stack.items[evict_to].group_id;
            if (self.group_depth > 0 and gid == self.active_group) break;
            while (evict_to < self.undo_stack.items.len and self.undo_stack.items[evict_to].group_id == gid) {
                self.allocator.free(self.undo_stack.items[evict_to].text);
                evict_to += 1;
            }
        }
        if (evict_to > 0) {
            const remaining = self.undo_stack.items.len - evict_to;
            std.mem.copyForwards(UndoOp, self.undo_stack.items[0..remaining], self.undo_stack.items[evict_to..]);
            self.undo_stack.items.len = remaining;
        }
    }

    fn clearRedoStack(self: *UndoHistory) void {
        for (self.redo_stack.items) |op| {
            self.allocator.free(op.text);
        }
        self.redo_stack.items.len = 0;
    }

    /// Determine group ID based on adjacency with previous operation.
    /// Adjacent same-type single-char operations on the same logical action get merged.
    fn resolveGroupId(self: *UndoHistory, op_type: OpType, offset: usize, text: []const u8) u32 {
        // Explicit group open — everything joins it.
        if (self.group_depth > 0) return self.active_group;

        if (self.undo_stack.items.len == 0) {
            defer self.next_group_id += 1;
            return self.next_group_id;
        }

        const prev = &self.undo_stack.items[self.undo_stack.items.len - 1];

        // Multi-char operations always start a new group
        if (text.len != 1 or prev.text.len != 1) {
            defer self.next_group_id += 1;
            return self.next_group_id;
        }

        // Newlines always start a new group
        if (text[0] == '\n' or prev.text[0] == '\n') {
            defer self.next_group_id += 1;
            return self.next_group_id;
        }

        // Different operation types start a new group
        if (op_type != prev.op_type) {
            defer self.next_group_id += 1;
            return self.next_group_id;
        }

        // Check adjacency
        switch (op_type) {
            .insert => {
                // Typing forward: new offset = prev offset + 1
                if (offset == prev.offset + prev.text.len) {
                    return prev.group_id;
                }
            },
            .delete => {
                // Backspace: new offset = prev offset - 1
                // Delete key: same offset
                if (offset == prev.offset -| 1 or offset == prev.offset) {
                    return prev.group_id;
                }
            },
        }

        defer self.next_group_id += 1;
        return self.next_group_id;
    }
};

// ---- Tests ----

test "undo single insert" {
    const allocator = std.testing.allocator;
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
    // Whole oversized group evicted at endGroup — empty, but never partial
    try std.testing.expectEqual(@as(usize, 0), hist.undo_stack.items.len);
}

test "new edit clears redo" {
    const allocator = std.testing.allocator;
    var buf = @import("buffer.zig").Buffer.init(allocator);
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
