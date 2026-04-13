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
    }

    // --- Internal ---

    fn clearRedoStack(self: *UndoHistory) void {
        for (self.redo_stack.items) |op| {
            self.allocator.free(op.text);
        }
        self.redo_stack.items.len = 0;
    }

    /// Determine group ID based on adjacency with previous operation.
    /// Adjacent same-type single-char operations on the same logical action get merged.
    fn resolveGroupId(self: *UndoHistory, op_type: OpType, offset: usize, text: []const u8) u32 {
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
