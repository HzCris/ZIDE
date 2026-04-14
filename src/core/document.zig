const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const cursor_mod = @import("cursor.zig");
const Cursor = cursor_mod.Cursor;
const CursorSet = cursor_mod.CursorSet;
const UndoHistory = @import("undo.zig").UndoHistory;
const syntax = @import("syntax.zig");
const lsp = @import("lsp.zig");

/// A document represents an open file (or unsaved buffer) being edited.
/// It owns the text buffer, cursor state, file metadata, and undo history.
pub const Document = struct {
    buffer: Buffer,
    cursors: CursorSet,
    history: UndoHistory,
    allocator: Allocator,

    /// Absolute file path, or null for unsaved/new buffers.
    file_path: ?[]const u8 = null,
    /// Display name shown in tabs (filename portion or "untitled").
    display_name: []const u8 = "untitled",

    /// Whether the buffer has unsaved modifications.
    dirty: bool = false,
    /// Whether the file is read-only.
    readonly: bool = false,
    /// Whether the file uses CRLF line endings.
    crlf: bool = false,

    /// Scroll state: top visible line.
    scroll_top: usize = 0,
    /// Scroll state: left horizontal offset (in columns).
    scroll_left: usize = 0,

    /// LSP document version (incremented on each edit).
    lsp_version: i32 = 0,
    /// Last version sent to LSP via didChange.
    lsp_last_synced: i32 = 0,
    /// Whether didOpen was sent for this document.
    lsp_opened: bool = false,
    /// LSP diagnostics from the language server.
    diagnostics: std.ArrayList(lsp.Diagnostic),

    /// Detected language for syntax highlighting (null = plain text).
    language: ?*const syntax.LanguageDef = null,
    /// Cached line states for syntax highlighting (state entering each line).
    line_states: std.ArrayList(syntax.LineState),

    pub fn init(allocator: Allocator) Document {
        return .{
            .buffer = Buffer.init(allocator),
            .cursors = CursorSet.init(allocator),
            .history = UndoHistory.init(allocator),
            .allocator = allocator,
            .diagnostics = .empty,
            .line_states = .empty,
        };
    }

    pub fn deinit(self: *Document) void {
        self.history.deinit();
        self.cursors.deinit();
        self.buffer.deinit();
        self.line_states.deinit(self.allocator);
        for (self.diagnostics.items) |*d| {
            d.deinit(self.allocator);
        }
        self.diagnostics.deinit(self.allocator);
        if (self.file_path) |p| {
            self.allocator.free(p);
        }
        // Free display_name only if it was heap-allocated (not the default "untitled")
        if (!std.mem.eql(u8, self.display_name, "untitled")) {
            self.allocator.free(self.display_name);
        }
    }

    /// Open a file into this document.
    pub fn open(self: *Document, path: []const u8) !void {
        try self.buffer.loadFile(path);
        // Store owned copy of path
        if (self.file_path) |old| {
            self.allocator.free(old);
        }
        self.file_path = try self.allocator.dupe(u8, path);
        // Extract filename for display
        self.setDisplayNameFromPath(path);
        self.dirty = false;
        self.resetCursors();
        self.detectLineEndings();
    }

    /// Load text directly (for new buffers, testing, etc.).
    pub fn loadText(self: *Document, text: []const u8) !void {
        try self.buffer.loadText(text);
        self.history.clear();
        self.dirty = false;
        self.resetCursors();
        self.detectLineEndings();
        self.invalidateLineStates(0);
    }

    /// Save the document to its file path.
    pub fn save(self: *Document) !void {
        const path = self.file_path orelse return error.NoFilePath;
        try self.buffer.saveFile(path);
        self.dirty = false;
    }

    /// Save to a new path (Save As).
    pub fn saveAs(self: *Document, path: []const u8) !void {
        try self.buffer.saveFile(path);
        if (self.file_path) |old| {
            self.allocator.free(old);
        }
        self.file_path = try self.allocator.dupe(u8, path);
        self.setDisplayNameFromPath(path);
        self.dirty = false;
    }

    /// Insert text at the primary cursor position.
    pub fn insertAtCursor(self: *Document, text: []const u8) !void {
        const c = self.cursors.primary();
        const cursor_before = c.offset;
        const len = try self.buffer.insert(c.offset, text);
        self.cursors.adjustAfterInsert(cursor_before, len);
        try self.history.recordInsert(cursor_before, text, cursor_before, c.offset);
        self.markDirty();
        self.invalidateLineStates(self.buffer.offsetToPos(cursor_before).line);
    }

    /// Delete `count` bytes forward from the primary cursor (like pressing Delete).
    pub fn deleteForward(self: *Document, count: usize) !void {
        const c = self.cursors.primary();
        if (c.offset >= self.buffer.byteLen()) return;
        const cursor_before = c.offset;
        const actual_count = @min(count, self.buffer.byteLen() - c.offset);
        if (actual_count == 0) return;
        const deleted_text = self.buffer.slice(c.offset, c.offset + actual_count);
        // Record before delete — recordDelete dupes the text internally
        try self.history.recordDelete(cursor_before, deleted_text, cursor_before, cursor_before);
        _ = self.buffer.delete(c.offset, actual_count);
        self.cursors.adjustAfterDelete(cursor_before, actual_count);
        self.markDirty();
        self.invalidateLineStates(self.buffer.offsetToPos(cursor_before).line);
    }

    /// Delete `count` bytes backward from the primary cursor (like pressing Backspace).
    pub fn deleteBackward(self: *Document, count: usize) !void {
        const c = self.cursors.primary();
        if (c.offset == 0) return;
        const cursor_before = c.offset;
        const del_count = @min(count, c.offset);
        const del_pos = c.offset - del_count;
        const deleted_text = self.buffer.slice(del_pos, del_pos + del_count);
        // Record before delete — recordDelete dupes the text internally
        try self.history.recordDelete(del_pos, deleted_text, cursor_before, del_pos);
        _ = self.buffer.delete(del_pos, del_count);
        self.cursors.adjustAfterDelete(del_pos, del_count);
        self.markDirty();
        self.invalidateLineStates(self.buffer.offsetToPos(del_pos).line);
    }

    /// Delete the current selection (if any) for the primary cursor.
    pub fn deleteSelection(self: *Document) !void {
        const c = self.cursors.primary();
        const range = c.selectionRange() orelse return;
        const cursor_before = c.offset;
        const del_len = range.end - range.start;
        const deleted_text = self.buffer.slice(range.start, range.end);
        // Record before delete — recordDelete dupes the text internally
        try self.history.recordDelete(range.start, deleted_text, cursor_before, range.start);
        _ = self.buffer.delete(range.start, del_len);
        self.cursors.adjustAfterDelete(range.start, del_len);
        c.offset = range.start;
        c.clearSelection();
        self.markDirty();
    }

    // ======================================================================
    // Multi-cursor editing — process all cursors (highest offset first)
    // ======================================================================

    /// Insert `text` at every cursor position.
    pub fn insertAtAllCursors(self: *Document, text: []const u8) !void {
        if (self.cursors.count() == 1) return self.insertAtCursor(text);
        var idx_buf: [256]usize = undefined;
        const order = self.cursors.sortedDescending(&idx_buf);
        for (order) |idx| {
            const c = &self.cursors.cursors.items[idx];
            if (c.hasSelection()) {
                const range = c.selectionRange().?;
                const del_len = range.end - range.start;
                const deleted = self.buffer.slice(range.start, range.end);
                try self.history.recordDelete(range.start, deleted, range.end, range.start);
                const actual = self.buffer.delete(range.start, del_len);
                c.offset = range.start;
                c.clearSelection();
                self.cursors.adjustOthersAfterDelete(idx, range.start, actual);
            }
            const pos = c.offset;
            const len = try self.buffer.insert(pos, text);
            c.offset = pos + len;
            c.preferred_col = self.buffer.offsetToPos(c.offset).col;
            self.cursors.adjustOthersAfterInsert(idx, pos, len);
            try self.history.recordInsert(pos, text, pos, c.offset);
        }
        self.cursors.mergeCursors();
        self.markDirty();
    }

    /// Delete one unit forward from every cursor.
    pub fn deleteForwardAll(self: *Document, count_arg: usize) !void {
        if (self.cursors.count() == 1) return self.deleteForward(count_arg);
        var idx_buf: [256]usize = undefined;
        const order = self.cursors.sortedDescending(&idx_buf);
        for (order) |idx| {
            const c = &self.cursors.cursors.items[idx];
            if (c.hasSelection()) {
                const range = c.selectionRange().?;
                const del_len = range.end - range.start;
                const deleted = self.buffer.slice(range.start, range.end);
                const before = c.offset;
                try self.history.recordDelete(range.start, deleted, before, range.start);
                const actual = self.buffer.delete(range.start, del_len);
                c.offset = range.start;
                c.clearSelection();
                self.cursors.adjustOthersAfterDelete(idx, range.start, actual);
            } else {
                if (c.offset >= self.buffer.byteLen()) continue;
                const pos = c.offset;
                const actual_count = @min(count_arg, self.buffer.byteLen() - pos);
                if (actual_count == 0) continue;
                const deleted = self.buffer.slice(pos, pos + actual_count);
                try self.history.recordDelete(pos, deleted, pos, pos);
                const actual = self.buffer.delete(pos, actual_count);
                self.cursors.adjustOthersAfterDelete(idx, pos, actual);
            }
        }
        self.cursors.mergeCursors();
        self.markDirty();
    }

    /// Delete one unit backward from every cursor.
    pub fn deleteBackwardAll(self: *Document, count_arg: usize) !void {
        if (self.cursors.count() == 1) return self.deleteBackward(count_arg);
        var idx_buf: [256]usize = undefined;
        const order = self.cursors.sortedDescending(&idx_buf);
        for (order) |idx| {
            const c = &self.cursors.cursors.items[idx];
            if (c.hasSelection()) {
                const range = c.selectionRange().?;
                const del_len = range.end - range.start;
                const deleted = self.buffer.slice(range.start, range.end);
                const before = c.offset;
                try self.history.recordDelete(range.start, deleted, before, range.start);
                const actual = self.buffer.delete(range.start, del_len);
                c.offset = range.start;
                c.clearSelection();
                self.cursors.adjustOthersAfterDelete(idx, range.start, actual);
            } else {
                if (c.offset == 0) continue;
                const del_count = @min(count_arg, c.offset);
                const del_pos = c.offset - del_count;
                const deleted = self.buffer.slice(del_pos, del_pos + del_count);
                const before = c.offset;
                try self.history.recordDelete(del_pos, deleted, before, del_pos);
                const actual = self.buffer.delete(del_pos, del_count);
                c.offset = del_pos;
                c.preferred_col = self.buffer.offsetToPos(c.offset).col;
                self.cursors.adjustOthersAfterDelete(idx, del_pos, actual);
            }
        }
        self.cursors.mergeCursors();
        self.markDirty();
    }

    /// Undo the last edit group. Returns true if something was undone.
    pub fn undoAction(self: *Document) !bool {
        const cursor_pos = try self.history.undo(&self.buffer) orelse return false;
        self.cursors.primary().offset = cursor_pos;
        self.cursors.primary().preferred_col = self.buffer.offsetToPos(cursor_pos).col;
        self.dirty = self.history.canUndo();
        self.lsp_version +%= 1;
        self.invalidateLineStates(0);
        return true;
    }

    /// Redo the last undone edit group. Returns true if something was redone.
    pub fn redoAction(self: *Document) !bool {
        const cursor_pos = try self.history.redo(&self.buffer) orelse return false;
        self.cursors.primary().offset = cursor_pos;
        self.cursors.primary().preferred_col = self.buffer.offsetToPos(cursor_pos).col;
        self.markDirty();
        self.invalidateLineStates(0);
        return true;
    }

    /// Get the selected text for the primary cursor, or null if no selection.
    pub fn selectedText(self: *Document) ?[]const u8 {
        const c = self.cursors.primaryConst();
        const range = c.selectionRange() orelse return null;
        return self.buffer.slice(range.start, range.end);
    }

    /// Get the primary cursor's current line and column.
    pub fn cursorPos(self: *const Document) Cursor.Pos {
        return self.cursors.primaryConst().pos(&self.buffer);
    }

    /// Total line count.
    pub fn lineCount(self: *const Document) usize {
        return self.buffer.lineCount();
    }

    /// Get content of a specific line.
    pub fn lineContent(self: *Document, line: usize) []const u8 {
        return self.buffer.lineContent(line);
    }

    /// Ensure scroll position keeps the cursor visible.
    pub fn ensureCursorVisible(self: *Document, visible_lines: usize, visible_cols: usize) void {
        const pos = self.cursorPos();

        // Vertical scrolling
        if (pos.line < self.scroll_top) {
            self.scroll_top = pos.line;
        } else if (visible_lines > 0 and pos.line >= self.scroll_top + visible_lines) {
            self.scroll_top = pos.line - visible_lines + 1;
        }

        // Horizontal scrolling
        if (pos.col < self.scroll_left) {
            self.scroll_left = pos.col;
        } else if (visible_cols > 0 and pos.col >= self.scroll_left + visible_cols) {
            self.scroll_left = pos.col - visible_cols + 1;
        }
    }

    /// Delete the entire line the cursor is on.
    pub fn deleteLine(self: *Document) !void {
        const pos = self.cursorPos();
        const line_start = self.buffer.posToOffset(pos.line, 0);
        const line_end = if (pos.line + 1 < self.buffer.lineCount())
            self.buffer.line_starts.items[pos.line + 1] // includes the \n
        else
            self.buffer.byteLen();
        const len = line_end - line_start;
        if (len == 0) return;
        const c = self.cursors.primary();
        const cursor_before = c.offset;
        const deleted = self.buffer.slice(line_start, line_end);
        const new_cursor = @min(line_start, self.buffer.byteLen() - len);
        try self.history.recordDelete(line_start, deleted, cursor_before, new_cursor);
        _ = self.buffer.delete(line_start, len);
        c.offset = @min(line_start, self.buffer.byteLen());
        c.preferred_col = self.buffer.offsetToPos(c.offset).col;
        c.clearSelection();
        self.markDirty();
    }

    /// Duplicate the current line below.
    pub fn duplicateLine(self: *Document) !void {
        const pos = self.cursorPos();
        const line = self.lineContent(pos.line);
        // Build: \n + line content
        var dup = try self.allocator.alloc(u8, line.len + 1);
        defer self.allocator.free(dup);
        dup[0] = '\n';
        @memcpy(dup[1..], line);
        // Insert at end of current line
        const line_end = self.buffer.posToOffset(pos.line, line.len);
        const c = self.cursors.primary();
        const cursor_before = c.offset;
        const len = try self.buffer.insert(line_end, dup);
        self.cursors.adjustAfterInsert(line_end, len);
        try self.history.recordInsert(line_end, dup, cursor_before, c.offset);
        self.markDirty();
    }

    /// Move the current line up.
    pub fn moveLineUp(self: *Document) !void {
        const pos = self.cursorPos();
        if (pos.line == 0) return;
        const cur_line = self.lineContent(pos.line);
        const prev_line = self.lineContent(pos.line - 1);
        // Build replacement: current_line \n prev_line
        const total = cur_line.len + 1 + prev_line.len;
        var buf = try self.allocator.alloc(u8, total);
        defer self.allocator.free(buf);
        @memcpy(buf[0..cur_line.len], cur_line);
        buf[cur_line.len] = '\n';
        @memcpy(buf[cur_line.len + 1 ..], prev_line);
        // Replace from start of prev line to end of current line
        const start = self.buffer.posToOffset(pos.line - 1, 0);
        const end = self.buffer.posToOffset(pos.line, cur_line.len);
        const del_len = end - start;
        _ = self.buffer.delete(start, del_len);
        _ = try self.buffer.insert(start, buf);
        // Move cursor to same column on the now-moved line
        const c = self.cursors.primary();
        c.offset = self.buffer.posToOffset(pos.line - 1, pos.col);
        c.preferred_col = pos.col;
        self.markDirty();
    }

    /// Move the current line down.
    pub fn moveLineDown(self: *Document) !void {
        const pos = self.cursorPos();
        if (pos.line + 1 >= self.buffer.lineCount()) return;
        const cur_line = self.lineContent(pos.line);
        const next_line = self.lineContent(pos.line + 1);
        // Build replacement: next_line \n current_line
        const total = next_line.len + 1 + cur_line.len;
        var buf = try self.allocator.alloc(u8, total);
        defer self.allocator.free(buf);
        @memcpy(buf[0..next_line.len], next_line);
        buf[next_line.len] = '\n';
        @memcpy(buf[next_line.len + 1 ..], cur_line);
        // Replace from start of current line to end of next line
        const start = self.buffer.posToOffset(pos.line, 0);
        const end = self.buffer.posToOffset(pos.line + 1, next_line.len);
        const del_len = end - start;
        _ = self.buffer.delete(start, del_len);
        _ = try self.buffer.insert(start, buf);
        // Move cursor to same column on the now-moved line
        const c = self.cursors.primary();
        c.offset = self.buffer.posToOffset(pos.line + 1, pos.col);
        c.preferred_col = pos.col;
        self.markDirty();
    }

    /// Delete a word forward from cursor (Ctrl+Delete).
    pub fn deleteWordForward(self: *Document) !void {
        const c = self.cursors.primary();
        const start = c.offset;
        var tmp = c.*;
        tmp.moveWordRight(&self.buffer);
        const end = tmp.offset;
        if (end > start) {
            const del_len = end - start;
            const deleted = self.buffer.slice(start, end);
            try self.history.recordDelete(start, deleted, start, start);
            _ = self.buffer.delete(start, del_len);
            self.cursors.adjustAfterDelete(start, del_len);
            self.markDirty();
        }
    }

    /// Delete a word backward from cursor (Ctrl+Backspace).
    pub fn deleteWordBackward(self: *Document) !void {
        const c = self.cursors.primary();
        const end = c.offset;
        if (end == 0) return;
        var tmp = c.*;
        tmp.moveWordLeft(&self.buffer);
        const start = tmp.offset;
        if (end > start) {
            const del_len = end - start;
            const deleted = self.buffer.slice(start, end);
            try self.history.recordDelete(start, deleted, end, start);
            _ = self.buffer.delete(start, del_len);
            self.cursors.adjustAfterDelete(start, del_len);
            self.markDirty();
        }
    }

    /// Dedent the current line (remove leading spaces/tab).
    pub fn dedentLine(self: *Document, tab_width: usize) !void {
        const pos = self.cursorPos();
        const line = self.lineContent(pos.line);
        const line_start = self.buffer.posToOffset(pos.line, 0);
        var remove: usize = 0;
        if (line.len > 0 and line[0] == '\t') {
            remove = 1;
        } else {
            const tab_w = @max(tab_width, 1);
            for (line) |ch| {
                if (ch == ' ' and remove < tab_w) {
                    remove += 1;
                } else break;
            }
        }
        if (remove == 0) return;
        const c = self.cursors.primary();
        const cursor_before = c.offset;
        const deleted = self.buffer.slice(line_start, line_start + remove);
        const cursor_after = if (cursor_before >= line_start + remove) cursor_before - remove else if (cursor_before > line_start) line_start else cursor_before;
        try self.history.recordDelete(line_start, deleted, cursor_before, cursor_after);
        _ = self.buffer.delete(line_start, remove);
        self.cursors.adjustAfterDelete(line_start, remove);
        self.markDirty();
    }

    /// Go to a specific line number (1-based), placing cursor at start.
    pub fn gotoLine(self: *Document, line_num: usize) void {
        const target = if (line_num > 0) line_num - 1 else 0;
        const clamped = @min(target, self.buffer.lineCount() -| 1);
        const c = self.cursors.primary();
        c.offset = self.buffer.posToOffset(clamped, 0);
        c.preferred_col = 0;
        c.clearSelection();
    }

    // --- Internal helpers ---

    /// Mark the document as dirty and increment LSP version.
    fn markDirty(self: *Document) void {
        self.dirty = true;
        self.lsp_version +%= 1;
    }

    fn resetCursors(self: *Document) void {
        self.cursors.clearSecondary();
        const c = self.cursors.primary();
        c.offset = 0;
        c.preferred_col = 0;
        c.clearSelection();
        self.scroll_top = 0;
        self.scroll_left = 0;
    }

    fn setDisplayNameFromPath(self: *Document, path: []const u8) void {
        // Free old display name if heap-allocated
        if (!std.mem.eql(u8, self.display_name, "untitled")) {
            self.allocator.free(self.display_name);
        }
        // Extract basename
        const basename = std.fs.path.basename(path);
        self.display_name = self.allocator.dupe(u8, basename) catch "untitled";
    }

    fn detectLineEndings(self: *Document) void {
        // Scan first few KB for \r\n
        const scan_len = @min(self.buffer.byteLen(), 8192);
        const content = self.buffer.slice(0, scan_len);
        for (content) |byte| {
            if (byte == '\r') {
                self.crlf = true;
                return;
            }
            if (byte == '\n') {
                self.crlf = false;
                return;
            }
        }
    }

    /// Detect language from the file extension using the editor's language registry.
    pub fn detectLanguage(self: *Document, editor: anytype) void {
        const path = self.file_path orelse return;
        const ext = std.fs.path.extension(path);
        // Strip leading '.' from extension
        const ext_clean = if (ext.len > 0 and ext[0] == '.') ext[1..] else ext;
        if (ext_clean.len == 0) return;
        self.language = editor.findLanguage(ext_clean);
        self.invalidateLineStates(0);
    }

    /// Invalidate cached line states from `from_line` onward.
    pub fn invalidateLineStates(self: *Document, from_line: usize) void {
        if (from_line < self.line_states.items.len) {
            self.line_states.items.len = from_line;
        }
    }

    /// Ensure line states are computed up to (and including) `target_line`.
    /// Returns the state entering `target_line`.
    pub fn ensureLineState(self: *Document, target_line: usize) syntax.LineState {
        const lang = self.language orelse return .normal;

        // Compute states from where we left off
        var line_idx = self.line_states.items.len;
        var state: syntax.LineState = if (line_idx > 0)
            self.line_states.items[line_idx - 1]
        else
            .normal;

        var span_buf: [syntax.MAX_SPANS]syntax.HighlightSpan = undefined;

        while (line_idx <= target_line) : (line_idx += 1) {
            // Store state entering this line
            self.line_states.append(self.allocator, state) catch return .normal;
            // Tokenize to get state exiting this line
            const line_content = self.buffer.lineContent(line_idx);
            const result = syntax.tokenizeLine(line_content, lang, state, &span_buf);
            state = result.state;
        }

        if (target_line < self.line_states.items.len) {
            return self.line_states.items[target_line];
        }
        return .normal;
    }
};

// ---- Tests ----

test "document new and load text" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello\nworld");
    try std.testing.expectEqual(@as(usize, 2), doc.lineCount());
    try std.testing.expectEqualStrings("hello", doc.lineContent(0));
    try std.testing.expectEqualStrings("world", doc.lineContent(1));
    try std.testing.expect(!doc.dirty);
    try std.testing.expectEqualStrings("untitled", doc.display_name);
}

test "document insert and dirty tracking" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello world");
    try std.testing.expect(!doc.dirty);

    try doc.insertAtCursor("// ");
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("// hello world", doc.lineContent(0));
}

test "document delete forward" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello");
    try doc.deleteForward(1);
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("ello", doc.lineContent(0));
}

test "document delete backward" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello");
    doc.cursors.primary().offset = 5; // end
    try doc.deleteBackward(1);
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("hell", doc.lineContent(0));
}

test "document selection delete" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello world");
    // Select "hello"
    doc.cursors.primary().offset = 0;
    doc.cursors.primary().startSelection();
    doc.cursors.primary().offset = 5;
    try doc.deleteSelection();
    try std.testing.expectEqualStrings(" world", doc.lineContent(0));
    try std.testing.expect(!doc.cursors.primary().hasSelection());
}

test "document cursor position" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("line one\nline two\nline three");
    doc.cursors.primary().offset = 14; // "line two" offset 5 → 9+5=14
    const pos = doc.cursorPos();
    try std.testing.expectEqual(@as(usize, 1), pos.line);
    try std.testing.expectEqual(@as(usize, 5), pos.col);
}

test "document ensure cursor visible" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("a\nb\nc\nd\ne\nf\ng\nh\ni\nj");
    // Move cursor to line 8
    doc.cursors.primary().gotoPos(&doc.buffer, 8, 0);
    doc.ensureCursorVisible(5, 80);
    // scroll_top should have moved so line 8 is visible
    try std.testing.expect(doc.scroll_top <= 8);
    try std.testing.expect(doc.scroll_top + 5 > 8);
}

test "document undo redo" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello");
    try doc.insertAtCursor("// ");
    try std.testing.expectEqualStrings("// hello", doc.lineContent(0));

    // Undo the insert
    const undone = try doc.undoAction();
    try std.testing.expect(undone);
    try std.testing.expectEqualStrings("hello", doc.lineContent(0));

    // Redo the insert
    const redone = try doc.redoAction();
    try std.testing.expect(redone);
    try std.testing.expectEqualStrings("// hello", doc.lineContent(0));
}

test "document line ending detection" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello\r\nworld");
    try std.testing.expect(doc.crlf);

    try doc.loadText("hello\nworld");
    try std.testing.expect(!doc.crlf);
}
