const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const cursor_mod = @import("cursor.zig");
const Cursor = cursor_mod.Cursor;
const CursorSet = cursor_mod.CursorSet;
const UndoHistory = @import("undo.zig").UndoHistory;
const syntax = @import("syntax.zig");
const lsp = @import("lsp.zig");

/// Default display name. Ownership is tracked by pointer identity — a file
/// literally named "untitled" must still get its heap name freed.
const default_display_name: []const u8 = "untitled";

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
    display_name: []const u8 = default_display_name,

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

    pub fn init(allocator: Allocator) !Document {
        var buffer = try Buffer.init(allocator);
        errdefer buffer.deinit();
        const cursors = try CursorSet.init(allocator);
        return .{
            .buffer = buffer,
            .cursors = cursors,
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
        // Free display_name only if heap-allocated. Compare by pointer, not
        // content — a file literally named "untitled" must still be freed.
        if (self.display_name.ptr != default_display_name.ptr) {
            self.allocator.free(self.display_name);
        }
    }

    /// Open a file into this document, replacing its current content.
    pub fn open(self: *Document, io: std.Io, path: []const u8) !void {
        try self.buffer.loadFile(io, path);
        // Store owned copy of path
        if (self.file_path) |old| {
            self.allocator.free(old);
        }
        self.file_path = try self.allocator.dupe(u8, path);
        // Extract filename for display
        self.setDisplayNameFromPath(path);
        self.dirty = false;
        // Stale history/highlight state from the previous content must not
        // survive — undoing across a file swap would corrupt the new buffer.
        self.history.clear();
        self.invalidateLineStates(0);
        self.resetCursors();
        self.detectLineEndings();
    }

    /// Update the stored file path (e.g. after a rename on disk) without
    /// touching buffer contents, history, or dirty state.
    pub fn setFilePath(self: *Document, path: []const u8) !void {
        const duped = try self.allocator.dupe(u8, path);
        if (self.file_path) |old| {
            self.allocator.free(old);
        }
        self.file_path = duped;
        self.setDisplayNameFromPath(path);
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
    pub fn save(self: *Document, io: std.Io) !void {
        const path = self.file_path orelse return error.NoFilePath;
        try self.buffer.saveFile(io, path);
        self.dirty = false;
    }

    /// Save to a new path (Save As).
    pub fn saveAs(self: *Document, io: std.Io, path: []const u8) !void {
        try self.buffer.saveFile(io, path);
        if (self.file_path) |old| {
            self.allocator.free(old);
        }
        self.file_path = try self.allocator.dupe(u8, path);
        self.setDisplayNameFromPath(path);
        self.dirty = false;
    }

    /// Insert text at the primary cursor position.
    /// Replaces the active selection (if any) as a single undo step.
    pub fn insertAtCursor(self: *Document, text: []const u8) !void {
        if (self.cursors.primary().hasSelection()) {
            self.history.beginGroup();
            defer self.history.endGroup();
            try self.deleteSelection();
            return self.insertAtCursorRaw(text);
        }
        try self.insertAtCursorRaw(text);
    }

    /// Insert at the primary cursor without selection handling (internal).
    fn insertAtCursorRaw(self: *Document, text: []const u8) !void {
        const c = self.cursors.primary();
        const cursor_before = c.offset;
        const len = try self.buffer.insert(c.offset, text);
        self.cursors.adjustAfterInsert(cursor_before, len);
        try self.history.recordInsert(cursor_before, text, cursor_before, c.offset);
        self.markDirty();
        self.invalidateLineStates(self.buffer.offsetToPos(cursor_before).line);
    }

    /// Delete `count` bytes forward from the primary cursor (like pressing Delete).
    /// With an active selection, deletes the selection instead.
    pub fn deleteForward(self: *Document, count: usize) !void {
        const c = self.cursors.primary();
        if (c.hasSelection()) return self.deleteSelection();
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
    /// With an active selection, deletes the selection instead.
    pub fn deleteBackward(self: *Document, count: usize) !void {
        const c = self.cursors.primary();
        if (c.hasSelection()) return self.deleteSelection();
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
        self.invalidateLineStates(self.buffer.offsetToPos(range.start).line);
    }

    // ======================================================================
    // Multi-cursor editing — process all cursors (highest offset first)
    // ======================================================================

    /// Insert `text` at every cursor position. One undo step for the whole edit.
    pub fn insertAtAllCursors(self: *Document, text: []const u8) !void {
        if (self.cursors.count() == 1) return self.insertAtCursor(text);
        self.history.beginGroup();
        defer self.history.endGroup();
        var min_edit: usize = std.math.maxInt(usize);
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
            min_edit = @min(min_edit, pos);
        }
        self.cursors.mergeCursors();
        self.markDirty();
        if (min_edit != std.math.maxInt(usize)) {
            self.invalidateLineStates(self.buffer.offsetToPos(min_edit).line);
        }
    }

    /// Delete one unit forward from every cursor. One undo step for the whole edit.
    pub fn deleteForwardAll(self: *Document, count_arg: usize) !void {
        if (self.cursors.count() == 1) return self.deleteForward(count_arg);
        self.history.beginGroup();
        defer self.history.endGroup();
        var min_edit: usize = std.math.maxInt(usize);
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
                min_edit = @min(min_edit, range.start);
            } else {
                if (c.offset >= self.buffer.byteLen()) continue;
                const pos = c.offset;
                const actual_count = @min(count_arg, self.buffer.byteLen() - pos);
                if (actual_count == 0) continue;
                const deleted = self.buffer.slice(pos, pos + actual_count);
                try self.history.recordDelete(pos, deleted, pos, pos);
                const actual = self.buffer.delete(pos, actual_count);
                self.cursors.adjustOthersAfterDelete(idx, pos, actual);
                min_edit = @min(min_edit, pos);
            }
        }
        self.cursors.mergeCursors();
        self.markDirty();
        if (min_edit != std.math.maxInt(usize)) {
            self.invalidateLineStates(self.buffer.offsetToPos(min_edit).line);
        }
    }

    /// Delete one unit backward from every cursor. One undo step for the whole edit.
    pub fn deleteBackwardAll(self: *Document, count_arg: usize) !void {
        if (self.cursors.count() == 1) return self.deleteBackward(count_arg);
        self.history.beginGroup();
        defer self.history.endGroup();
        var min_edit: usize = std.math.maxInt(usize);
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
                min_edit = @min(min_edit, range.start);
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
                min_edit = @min(min_edit, del_pos);
            }
        }
        self.cursors.mergeCursors();
        self.markDirty();
        if (min_edit != std.math.maxInt(usize)) {
            self.invalidateLineStates(self.buffer.offsetToPos(min_edit).line);
        }
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
        self.cursors.adjustAfterDelete(line_start, len);
        c.offset = @min(line_start, self.buffer.byteLen());
        c.preferred_col = self.buffer.offsetToPos(c.offset).col;
        c.clearSelection();
        self.markDirty();
        self.invalidateLineStates(pos.line);
    }

    /// Duplicate the current line below.
    pub fn duplicateLine(self: *Document) !void {
        const pos = self.cursorPos();
        const line = self.lineContent(pos.line);
        // Build: line terminator + line content (match the document's endings)
        const term: []const u8 = if (self.crlf) "\r\n" else "\n";
        var dup = try self.allocator.alloc(u8, term.len + line.len);
        defer self.allocator.free(dup);
        @memcpy(dup[0..term.len], term);
        @memcpy(dup[term.len..], line);
        // Insert at end of current line
        const line_end = self.buffer.posToOffset(pos.line, line.len);
        const c = self.cursors.primary();
        const cursor_before = c.offset;
        const len = try self.buffer.insert(line_end, dup);
        self.cursors.adjustAfterInsert(line_end, len);
        try self.history.recordInsert(line_end, dup, cursor_before, c.offset);
        self.markDirty();
        self.invalidateLineStates(pos.line);
    }

    /// Move the current line up (swap with the line above). Single undo step.
    pub fn moveLineUp(self: *Document) !void {
        const pos = self.cursorPos();
        if (pos.line == 0) return;
        try self.swapAdjacentLines(pos.line - 1);
    }

    /// Move the current line down (swap with the line below). Single undo step.
    pub fn moveLineDown(self: *Document) !void {
        const pos = self.cursorPos();
        if (pos.line + 1 >= self.buffer.lineCount()) return;
        try self.swapAdjacentLines(pos.line);
    }

    /// Swap lines `line_a` and `line_a + 1` as raw byte spans, preserving each
    /// line's own ending (CRLF-safe). Records undo as one group and remaps all
    /// cursors/anchors inside the swapped region onto their moved lines.
    fn swapAdjacentLines(self: *Document, line_a: usize) !void {
        const line_b = line_a + 1;
        const a_start = self.buffer.line_starts.items[line_a];
        const b_start = self.buffer.line_starts.items[line_b];
        const b_end = if (line_b + 1 < self.buffer.lineCount())
            self.buffer.line_starts.items[line_b + 1]
        else
            self.buffer.byteLen();
        const region_len = b_end - a_start;
        if (region_len == 0) return;

        // Snapshot (line, col) of cursors/anchors inside the region; total
        // length is unchanged, so offsets outside the region stay valid.
        const LineCol = struct { line: usize, col: usize };
        var cur_remap = [_]?LineCol{null} ** 256;
        var anc_remap = [_]?LineCol{null} ** 256;
        const n_cursors = @min(self.cursors.cursors.items.len, cur_remap.len);
        for (self.cursors.cursors.items[0..n_cursors], 0..) |c, i| {
            if (c.offset >= a_start and c.offset < b_end) {
                const p = self.buffer.offsetToPos(c.offset);
                cur_remap[i] = .{ .line = if (p.line == line_a) line_b else line_a, .col = p.col };
            }
            if (c.anchor) |a| {
                if (a >= a_start and a < b_end) {
                    const p = self.buffer.offsetToPos(a);
                    anc_remap[i] = .{ .line = if (p.line == line_a) line_b else line_a, .col = p.col };
                }
            }
        }

        const cursor_before = self.cursors.primary().offset;
        self.history.beginGroup();
        defer self.history.endGroup();

        // Record the removal before mutating (recordDelete dupes internally).
        try self.history.recordDelete(a_start, self.buffer.slice(a_start, b_end), cursor_before, cursor_before);

        // Dupe both spans — slice() may return the shared scratch buffer,
        // which the delete/insert below would invalidate.
        const a_full = try self.allocator.dupe(u8, self.buffer.slice(a_start, b_start));
        defer self.allocator.free(a_full);
        const b_full = try self.allocator.dupe(u8, self.buffer.slice(b_start, b_end));
        defer self.allocator.free(b_full);

        const new_text = try self.allocator.alloc(u8, region_len);
        defer self.allocator.free(new_text);
        const b_has_term = b_full.len > 0 and b_full[b_full.len - 1] == '\n';
        if (b_has_term) {
            // Both lines keep their own terminators: B then A.
            @memcpy(new_text[0..b_full.len], b_full);
            @memcpy(new_text[b_full.len..], a_full);
        } else {
            // line_b is the last line (no terminator): B takes A's terminator
            // and A becomes the new unterminated last line.
            const term_len: usize = if (a_full.len >= 2 and a_full[a_full.len - 2] == '\r') 2 else 1;
            @memcpy(new_text[0..b_full.len], b_full);
            @memcpy(new_text[b_full.len..][0..term_len], a_full[a_full.len - term_len ..]);
            @memcpy(new_text[b_full.len + term_len ..], a_full[0 .. a_full.len - term_len]);
        }

        _ = self.buffer.delete(a_start, region_len);
        _ = try self.buffer.insert(a_start, new_text);

        // Remap cursors onto their moved lines.
        for (self.cursors.cursors.items[0..n_cursors], 0..) |*c, i| {
            if (cur_remap[i]) |p| {
                c.offset = self.buffer.posToOffset(p.line, p.col);
                c.preferred_col = p.col;
            }
            if (anc_remap[i]) |p| {
                c.anchor = self.buffer.posToOffset(p.line, p.col);
            }
        }

        try self.history.recordInsert(a_start, new_text, cursor_before, self.cursors.primary().offset);
        self.markDirty();
        self.invalidateLineStates(line_a);
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
            self.invalidateLineStates(self.buffer.offsetToPos(start).line);
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
            self.invalidateLineStates(self.buffer.offsetToPos(start).line);
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
        self.invalidateLineStates(pos.line);
    }

    /// Toggle comments on every line covered by the primary selection (or the
    /// cursor's line). `prefix` is inserted after the block's minimum
    /// indentation; for languages without line comments (CSS, HTML) pass the
    /// block markers and each line is wrapped `prefix line suffix`.
    /// Uncomments when every non-blank covered line is already commented.
    /// One undo step; selections and secondary cursors are preserved.
    pub fn toggleComment(self: *Document, prefix: []const u8, suffix: ?[]const u8) !void {
        if (prefix.len == 0) return;
        const c = self.cursors.primary();

        // Line range covered by the selection (or just the cursor line).
        var first_line: usize = undefined;
        var last_line: usize = undefined;
        if (c.selectionRange()) |range| {
            first_line = self.buffer.offsetToPos(range.start).line;
            const end_pos = self.buffer.offsetToPos(range.end);
            last_line = end_pos.line;
            // A selection ending at column 0 doesn't include that line.
            if (last_line > first_line and end_pos.col == 0) last_line -= 1;
        } else {
            first_line = self.cursorPos().line;
            last_line = first_line;
        }

        // Pass 1: are all non-blank lines commented? Where is the min indent?
        var all_commented = true;
        var any_nonblank = false;
        var min_indent: usize = std.math.maxInt(usize);
        var scan = first_line;
        while (scan <= last_line) : (scan += 1) {
            const content = self.lineContent(scan);
            const ws = leadingWhitespace(content);
            if (ws == content.len) continue; // blank line
            any_nonblank = true;
            min_indent = @min(min_indent, ws);
            if (!lineIsCommented(content[ws..], prefix, suffix)) all_commented = false;
        }

        const cursor_before = c.offset;
        self.history.beginGroup();
        defer self.history.endGroup();

        // Process bottom-up so earlier lines' offsets stay valid; within a
        // line, the higher-offset edit (suffix) goes first for the same reason.
        if (any_nonblank and all_commented) {
            // --- Uncomment ---
            var ln = last_line + 1;
            while (ln > first_line) {
                ln -= 1;
                const content = self.lineContent(ln);
                const ws = leadingWhitespace(content);
                if (ws == content.len) continue;
                const trimmed = content[ws..];
                if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
                const line_start = self.buffer.posToOffset(ln, 0);

                // Plan both deletions before mutating (content is invalidated
                // by the first edit). Each strips one space we likely added.
                var suf_at: ?usize = null;
                var suf_len: usize = 0;
                if (suffix) |suf| {
                    const t = std.mem.trimEnd(u8, trimmed, " \t");
                    if (!(t.len >= prefix.len + suf.len and std.mem.endsWith(u8, t, suf))) continue;
                    var start_in_line = ws + t.len - suf.len;
                    suf_len = suf.len;
                    if (start_in_line > ws + prefix.len and content[start_in_line - 1] == ' ') {
                        start_in_line -= 1;
                        suf_len += 1;
                    }
                    suf_at = line_start + start_in_line;
                }
                var pre_len = prefix.len;
                if (trimmed.len > prefix.len and trimmed[prefix.len] == ' ') pre_len += 1;
                if (suf_at) |sa| {
                    // Degenerate "/* */": don't let the prefix's space-eat
                    // overlap the suffix region that's about to be deleted.
                    if (line_start + ws + pre_len > sa) pre_len = prefix.len;
                }

                if (suf_at) |sa| {
                    const deleted = self.buffer.slice(sa, sa + suf_len);
                    try self.history.recordDelete(sa, deleted, cursor_before, cursor_before);
                    _ = self.buffer.delete(sa, suf_len);
                    self.cursors.adjustAfterDelete(sa, suf_len);
                }
                const pre_at = line_start + ws;
                const deleted = self.buffer.slice(pre_at, pre_at + pre_len);
                try self.history.recordDelete(pre_at, deleted, cursor_before, cursor_before);
                _ = self.buffer.delete(pre_at, pre_len);
                self.cursors.adjustAfterDelete(pre_at, pre_len);
            }
        } else {
            // --- Comment ---
            const lead = try std.mem.concat(self.allocator, u8, &.{ prefix, " " });
            defer self.allocator.free(lead);
            const trail: ?[]u8 = if (suffix) |suf|
                try std.mem.concat(self.allocator, u8, &.{ " ", suf })
            else
                null;
            defer if (trail) |t| self.allocator.free(t);

            var ln = last_line + 1;
            while (ln > first_line) {
                ln -= 1;
                const content = self.lineContent(ln);
                const ws = leadingWhitespace(content);
                // Skip blank lines, unless the whole block is blank (then the
                // single-blank-line case should still produce a comment).
                if (any_nonblank and ws == content.len) continue;
                const line_start = self.buffer.posToOffset(ln, 0);
                const line_len = content.len;

                if (trail) |t| {
                    const at = line_start + line_len;
                    const len = try self.buffer.insert(at, t);
                    self.cursors.adjustAfterInsert(at, len);
                    try self.history.recordInsert(at, t, cursor_before, cursor_before);
                }
                const indent = if (any_nonblank) @min(min_indent, ws) else ws;
                const at = line_start + indent;
                const len = try self.buffer.insert(at, lead);
                self.cursors.adjustAfterInsert(at, len);
                try self.history.recordInsert(at, lead, cursor_before, cursor_before);
            }
        }

        self.markDirty();
        self.invalidateLineStates(first_line);
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
        // Free old display name if heap-allocated (pointer identity, see deinit)
        if (self.display_name.ptr != default_display_name.ptr) {
            self.allocator.free(self.display_name);
        }
        // Extract basename
        const basename = std.fs.path.basename(path);
        self.display_name = self.allocator.dupe(u8, basename) catch default_display_name;
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

/// Count leading spaces/tabs.
fn leadingWhitespace(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i;
}

/// Whether a line (already trimmed of leading whitespace) carries a comment:
/// starts with `prefix`, and — when `suffix` is given — also ends with it
/// (ignoring trailing whitespace) without overlapping the prefix.
fn lineIsCommented(trimmed: []const u8, prefix: []const u8, suffix: ?[]const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;
    if (suffix) |suf| {
        const t = std.mem.trimEnd(u8, trimmed, " \t");
        return t.len >= prefix.len + suf.len and std.mem.endsWith(u8, t, suf);
    }
    return true;
}

// ---- Tests ----

test "document new and load text" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
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
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello world");
    try std.testing.expect(!doc.dirty);

    try doc.insertAtCursor("// ");
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("// hello world", doc.lineContent(0));
}

test "document delete forward" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello");
    try doc.deleteForward(1);
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("ello", doc.lineContent(0));
}

test "document delete backward" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello");
    doc.cursors.primary().offset = 5; // end
    try doc.deleteBackward(1);
    try std.testing.expect(doc.dirty);
    try std.testing.expectEqualStrings("hell", doc.lineContent(0));
}

test "document selection delete" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
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
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("line one\nline two\nline three");
    doc.cursors.primary().offset = 14; // "line two" offset 5 → 9+5=14
    const pos = doc.cursorPos();
    try std.testing.expectEqual(@as(usize, 1), pos.line);
    try std.testing.expectEqual(@as(usize, 5), pos.col);
}

test "document ensure cursor visible" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
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
    var doc = try Document.init(allocator);
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

test "backspace deletes the selection" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello world");
    const c = doc.cursors.primary();
    c.offset = 0;
    c.startSelection();
    c.offset = 5; // select "hello"
    try doc.deleteBackward(1);
    try std.testing.expectEqualStrings(" world", doc.lineContent(0));
    try std.testing.expect(!doc.cursors.primary().hasSelection());
    try std.testing.expectEqual(@as(usize, 0), doc.cursors.primary().offset);
}

test "delete key deletes the selection" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello world");
    const c = doc.cursors.primary();
    c.offset = 6;
    c.startSelection();
    c.offset = 11; // select "world"
    try doc.deleteForward(1);
    try std.testing.expectEqualStrings("hello ", doc.lineContent(0));
    try std.testing.expect(!doc.cursors.primary().hasSelection());
}

test "insert replaces selection as one undo step" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello world");
    const c = doc.cursors.primary();
    c.offset = 0;
    c.startSelection();
    c.offset = 5; // select "hello"
    try doc.insertAtCursor("goodbye");
    try std.testing.expectEqualStrings("goodbye world", doc.lineContent(0));

    // Single undo restores the original text (delete+insert grouped)
    _ = try doc.undoAction();
    try std.testing.expectEqualStrings("hello world", doc.lineContent(0));
}

test "paste path replaces selection (insertAtAllCursors, single cursor)" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("abc def");
    const c = doc.cursors.primary();
    c.offset = 4;
    c.startSelection();
    c.offset = 7; // select "def"
    try doc.insertAtAllCursors("xyz");
    try std.testing.expectEqualStrings("abc xyz", doc.lineContent(0));
}

test "move line up/down with undo restores exactly" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("one\ntwo\nthree");
    doc.cursors.primary().gotoPos(&doc.buffer, 1, 1); // on "two"

    try doc.moveLineUp();
    try std.testing.expectEqualStrings("two", doc.lineContent(0));
    try std.testing.expectEqualStrings("one", doc.lineContent(1));
    // Cursor followed the moved line, same column
    const p = doc.cursorPos();
    try std.testing.expectEqual(@as(usize, 0), p.line);
    try std.testing.expectEqual(@as(usize, 1), p.col);

    // Single undo restores original buffer
    _ = try doc.undoAction();
    try std.testing.expectEqualStrings("one", doc.lineContent(0));
    try std.testing.expectEqualStrings("two", doc.lineContent(1));
    try std.testing.expectEqualStrings("three", doc.lineContent(2));

    // Move last line up over the unterminated boundary, then undo
    doc.cursors.primary().gotoPos(&doc.buffer, 2, 0); // on "three"
    try doc.moveLineUp();
    try std.testing.expectEqualStrings("one", doc.lineContent(0));
    try std.testing.expectEqualStrings("three", doc.lineContent(1));
    try std.testing.expectEqualStrings("two", doc.lineContent(2));
    try std.testing.expectEqualStrings("one\nthree\ntwo", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = try doc.undoAction();
    try std.testing.expectEqualStrings("one\ntwo\nthree", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "move line preserves CRLF endings" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("aaa\r\nbbb\r\nccc");
    doc.cursors.primary().gotoPos(&doc.buffer, 0, 0); // on "aaa"

    try doc.moveLineDown();
    try std.testing.expectEqualStrings("bbb\r\naaa\r\nccc", doc.buffer.slice(0, doc.buffer.byteLen()));

    // Move "aaa" (now line 1) past the unterminated last line
    try doc.moveLineDown();
    try std.testing.expectEqualStrings("bbb\r\nccc\r\naaa", doc.buffer.slice(0, doc.buffer.byteLen()));

    _ = try doc.undoAction();
    _ = try doc.undoAction();
    try std.testing.expectEqualStrings("aaa\r\nbbb\r\nccc", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "multi-cursor insert is one undo step" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("a\nb\nc");
    doc.cursors.primary().offset = 0;
    try doc.cursors.addCursor(2); // start of "b"
    try doc.cursors.addCursor(4); // start of "c"

    try doc.insertAtAllCursors("->");
    try std.testing.expectEqualStrings("->a", doc.lineContent(0));
    try std.testing.expectEqualStrings("->b", doc.lineContent(1));
    try std.testing.expectEqualStrings("->c", doc.lineContent(2));

    _ = try doc.undoAction();
    try std.testing.expectEqualStrings("a\nb\nc", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "duplicate line uses CRLF in CRLF documents" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("aaa\r\nbbb");
    doc.cursors.primary().gotoPos(&doc.buffer, 0, 0);
    try doc.duplicateLine();
    try std.testing.expectEqualStrings("aaa\r\naaa\r\nbbb", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "toggle comment single line round trip" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("    const x = 1;");
    doc.cursors.primary().offset = 8;

    try doc.toggleComment("//", null);
    try std.testing.expectEqualStrings("    // const x = 1;", doc.lineContent(0));
    // Cursor shifted with the inserted prefix
    try std.testing.expectEqual(@as(usize, 11), doc.cursors.primary().offset);

    try doc.toggleComment("//", null);
    try std.testing.expectEqualStrings("    const x = 1;", doc.lineContent(0));
    try std.testing.expectEqual(@as(usize, 8), doc.cursors.primary().offset);
}

test "toggle comment multi-line selection aligns at min indent, skips blanks" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("if (x) {\n    a();\n\n        b();\n}");
    const c = doc.cursors.primary();
    c.offset = 0;
    c.startSelection();
    c.offset = doc.buffer.byteLen();

    try doc.toggleComment("//", null);
    try std.testing.expectEqualStrings("// if (x) {", doc.lineContent(0));
    try std.testing.expectEqualStrings("//     a();", doc.lineContent(1));
    try std.testing.expectEqualStrings("", doc.lineContent(2)); // blank untouched
    try std.testing.expectEqualStrings("//         b();", doc.lineContent(3));
    try std.testing.expectEqualStrings("// }", doc.lineContent(4));
    // Selection survives the edit
    try std.testing.expect(c.hasSelection());

    // All commented now -> toggling again uncomments
    try doc.toggleComment("//", null);
    try std.testing.expectEqualStrings("if (x) {\n    a();\n\n        b();\n}", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "toggle comment mixed selection comments everything" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("// done\npending");
    const c = doc.cursors.primary();
    c.offset = 0;
    c.startSelection();
    c.offset = doc.buffer.byteLen();

    try doc.toggleComment("//", null);
    try std.testing.expectEqualStrings("// // done", doc.lineContent(0));
    try std.testing.expectEqualStrings("// pending", doc.lineContent(1));
}

test "toggle comment is one undo step" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("a\nb\nc");
    const c = doc.cursors.primary();
    c.offset = 0;
    c.startSelection();
    c.offset = doc.buffer.byteLen();

    try doc.toggleComment("//", null);
    try std.testing.expectEqualStrings("// a\n// b\n// c", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = try doc.undoAction();
    try std.testing.expectEqualStrings("a\nb\nc", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "toggle comment block style wraps each line" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("color: red;\n  margin: 0;");
    const c = doc.cursors.primary();
    c.offset = 0;
    c.startSelection();
    c.offset = doc.buffer.byteLen();

    try doc.toggleComment("/*", "*/");
    try std.testing.expectEqualStrings("/* color: red; */", doc.lineContent(0));
    try std.testing.expectEqualStrings("/*   margin: 0; */", doc.lineContent(1));

    try doc.toggleComment("/*", "*/");
    try std.testing.expectEqualStrings("color: red;\n  margin: 0;", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "toggle comment selection ending at column 0 excludes that line" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("one\ntwo\nthree");
    const c = doc.cursors.primary();
    c.offset = 0;
    c.startSelection();
    c.offset = doc.buffer.posToOffset(2, 0); // selects "one\ntwo\n"

    try doc.toggleComment("#", null);
    try std.testing.expectEqualStrings("# one", doc.lineContent(0));
    try std.testing.expectEqualStrings("# two", doc.lineContent(1));
    try std.testing.expectEqualStrings("three", doc.lineContent(2));
}

test "toggle comment CRLF document keeps line endings" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("aaa\r\nbbb");
    const c = doc.cursors.primary();
    c.offset = 0;
    c.startSelection();
    c.offset = doc.buffer.byteLen();

    try doc.toggleComment("/*", "*/");
    try std.testing.expectEqualStrings("/* aaa */\r\n/* bbb */", doc.buffer.slice(0, doc.buffer.byteLen()));

    try doc.toggleComment("/*", "*/");
    try std.testing.expectEqualStrings("aaa\r\nbbb", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "document line ending detection" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator);
    defer doc.deinit();

    try doc.loadText("hello\r\nworld");
    try std.testing.expect(doc.crlf);

    try doc.loadText("hello\nworld");
    try std.testing.expect(!doc.crlf);
}
