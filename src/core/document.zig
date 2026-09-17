const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const cursor_mod = @import("cursor.zig");
const Cursor = cursor_mod.Cursor;
const CursorSet = cursor_mod.CursorSet;
const UndoHistory = @import("undo.zig").UndoHistory;
const UndoOp = @import("undo.zig").UndoOp;
const syntax = @import("syntax.zig");
const lsp = @import("lsp.zig");
const snippets = @import("snippets.zig");
pub const text_file = @import("text_file.zig");
pub const TextEncoding = text_file.TextEncoding;
pub const TextFormat = text_file.TextFormat;

/// Default display name. Ownership is tracked by pointer identity — a file
/// literally named "untitled" must still get its heap name freed.
var next_document_id = std.atomic.Value(u64).init(1);

const default_display_name: []const u8 = "untitled";

/// A document represents an open file (or unsaved buffer) being edited.
/// It owns the text buffer, cursor state, file metadata, and undo history.
pub const Document = struct {
    buffer: Buffer,
    id: u64 = 0,
    edit_depth: usize = 0,
    edit_before: []Cursor = &.{},
    edit_after: []Cursor = &.{},
    edit_revision: u64 = 0,
    cursors: CursorSet,
    history: UndoHistory,
    allocator: Allocator,
    snippet_session: ?snippets.Session = null,

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
    format_rules: @import("editorconfig.zig").Properties = .{},
    format: TextFormat = .{},
    /// On-disk identity, size and mtime recorded at load/save.
    disk_stamp: ?text_file.Stamp = null,
    /// The disk copy changed under a dirty buffer (or the file vanished):
    /// saving prompts before overwriting. Cleared by save/reload.
    external_changed: bool = false,
    /// Transient quick-open preview: hidden from tab bars, sessions, and
    /// LSP sync; promoted to a real document on finder commit.
    preview: bool = false,

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
    /// Lint diagnostics from Lua extensions (zide.set_diagnostics) — a
    /// separate list because LSP publishes clear+replace `diagnostics`
    /// wholesale. Replaced per set_diagnostics call.
    lint_diagnostics: std.ArrayList(lsp.Diagnostic),

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
            .id = next_document_id.fetchAdd(1, .monotonic),
            .cursors = cursors,
            .history = UndoHistory.init(allocator),
            .allocator = allocator,
            .diagnostics = .empty,
            .lint_diagnostics = .empty,
            .line_states = .empty,
        };
    }

    pub fn deinit(self: *Document) void {
        self.cancelSnippet(false);
        self.history.deinit();
        self.cursors.deinit();
        self.buffer.deinit();
        self.line_states.deinit(self.allocator);
        for (self.diagnostics.items) |*d| {
            d.deinit(self.allocator);
        }
        self.diagnostics.deinit(self.allocator);
        self.clearLintDiagnostics();
        self.lint_diagnostics.deinit(self.allocator);
        if (self.file_path) |p| {
            self.allocator.free(p);
        }
        // Free display_name only if heap-allocated. Compare by pointer, not
        // content — a file literally named "untitled" must still be freed.
        if (self.display_name.ptr != default_display_name.ptr) {
            self.allocator.free(self.display_name);
        }
    }

    /// Drop all LSP diagnostics (frees their messages).
    pub fn clearDiagnostics(self: *Document) void {
        for (self.diagnostics.items) |*d| {
            d.deinit(self.allocator);
        }
        self.diagnostics.clearRetainingCapacity();
    }

    /// Drop all extension lint diagnostics (frees their messages).
    pub fn clearLintDiagnostics(self: *Document) void {
        for (self.lint_diagnostics.items) |*d| {
            d.deinit(self.allocator);
        }
        self.lint_diagnostics.clearRetainingCapacity();
    }

    /// Iterate LSP and lint diagnostics as one sequence — every consumer
    /// (gutter markers, underlines, status bar) goes through this so
    /// extension diagnostics render exactly like LSP ones.
    pub const DiagnosticIterator = struct {
        doc: *const Document,
        idx: usize = 0,

        pub fn next(self: *DiagnosticIterator) ?*const lsp.Diagnostic {
            const lsp_items = self.doc.diagnostics.items;
            if (self.idx < lsp_items.len) {
                defer self.idx += 1;
                return &lsp_items[self.idx];
            }
            const lint_items = self.doc.lint_diagnostics.items;
            const li = self.idx - lsp_items.len;
            if (li < lint_items.len) {
                defer self.idx += 1;
                return &lint_items[li];
            }
            return null;
        }
    };

    pub fn diagIter(self: *const Document) DiagnosticIterator {
        return .{ .doc = self };
    }

    /// Open a file into this document, replacing its current content.
    /// Strict decoding and preparation precede every state change.
    pub fn open(self: *Document, io: std.Io, path: []const u8) !void {
        return self.openWithEncoding(io, path, null);
    }

    pub fn openWithEncoding(self: *Document, io: std.Io, path: []const u8, encoding: ?TextEncoding) !void {
        const decoded = try text_file.read(self.allocator, io, path, encoding, std.math.maxInt(usize));
        defer self.allocator.free(decoded.text);
        var replacement = try Buffer.init(self.allocator);
        errdefer replacement.deinit();
        try replacement.loadText(decoded.text);
        replacement.version = self.buffer.version +% 1;
        const owned_path = try @import("file_identity.zig").absolute(self.allocator, io, path);
        errdefer self.allocator.free(owned_path);
        const name = try self.allocator.dupe(u8, std.fs.path.basename(path));
        self.cancelSnippet(false);
        self.buffer.deinit();
        self.buffer = replacement;
        if (self.file_path) |old| self.allocator.free(old);
        if (self.display_name.ptr != default_display_name.ptr) self.allocator.free(self.display_name);
        self.file_path = owned_path;
        self.display_name = name;
        self.format = decoded.format;
        self.dirty = false;
        // Stale history/highlight state from the previous content must not
        // survive — undoing across a file swap would corrupt the new buffer.
        self.history.clear();
        self.invalidateLineStates(0);
        self.resetCursors();
        self.detectLineEndings();
        self.external_changed = false;
        self.refreshDiskStamp(io);
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
        self.cancelSnippet(false);
        self.history.clear();
        self.dirty = false;
        self.resetCursors();
        self.detectLineEndings();
        self.invalidateLineStates(0);
    }

    /// Save the document to its file path.
    pub fn save(self: *Document, io: std.Io) !void {
        return self.saveWithFormat(io, null);
    }

    pub fn saveWithFormat(self: *Document, io: std.Io, format: ?TextFormat) !void {
        const path = self.file_path orelse return error.NoFilePath;
        const chosen = format orelse self.format;
        const text = try self.buffer.textAlloc(self.allocator);
        defer self.allocator.free(text);
        try text_file.write(self.allocator, io, path, text, chosen);
        self.format = chosen;
        self.history.markSaved();
        self.dirty = false;
        self.external_changed = false;
        self.refreshDiskStamp(io);
    }

    /// Save to a new path (Save As).
    pub fn saveAs(self: *Document, io: std.Io, path: []const u8) !void {
        return self.saveAsWithFormat(io, path, null);
    }

    pub fn saveAsWithFormat(self: *Document, io: std.Io, path: []const u8, format: ?TextFormat) !void {
        const owned_path = try @import("file_identity.zig").absolute(self.allocator, io, path);
        errdefer self.allocator.free(owned_path);
        const name = try self.allocator.dupe(u8, std.fs.path.basename(path));
        errdefer self.allocator.free(name);
        const chosen = format orelse self.format;
        const text = try self.buffer.textAlloc(self.allocator);
        defer self.allocator.free(text);
        try text_file.write(self.allocator, io, path, text, chosen);
        if (self.file_path) |old| {
            self.allocator.free(old);
        }
        self.file_path = owned_path;
        if (self.display_name.ptr != default_display_name.ptr) self.allocator.free(self.display_name);
        self.display_name = name;
        self.format = chosen;
        self.history.markSaved();
        self.dirty = false;
        self.external_changed = false;
        self.refreshDiskStamp(io);
    }

    /// Record the file's current identity, size and mtime (null on failure).
    pub fn refreshDiskStamp(self: *Document, io: std.Io) void {
        self.disk_stamp = if (self.file_path) |path| text_file.Stamp.read(io, path) catch null else null;
    }

    /// True when the disk copy no longer matches what was loaded/saved
    /// (different identity, size or mtime, or the file is unavailable).
    pub fn checkExternalChange(self: *const Document, io: std.Io) bool {
        const path = self.file_path orelse return false;
        const recorded = self.disk_stamp orelse return false;
        const current = (text_file.Stamp.read(io, path) catch return true) orelse return true;
        return !std.meta.eql(current, recorded);
    }

    /// Re-read and validate before replacing the buffer. Preserve all cursor
    /// and scroll state (clamped on success); failures leave history intact.
    pub fn reloadFromDisk(self: *Document, io: std.Io) !void {
        return self.reloadWithEncoding(io, self.format.encoding);
    }

    pub fn reloadWithEncoding(self: *Document, io: std.Io, encoding: ?TextEncoding) !void {
        const path = self.file_path orelse return error.NoFilePath;
        const decoded = try text_file.read(self.allocator, io, path, encoding, std.math.maxInt(usize));
        defer self.allocator.free(decoded.text);
        var replacement = try Buffer.init(self.allocator);
        errdefer replacement.deinit();
        try replacement.loadText(decoded.text);
        replacement.version = self.buffer.version +% 1;
        self.cancelSnippet(false);
        self.buffer.deinit();
        self.buffer = replacement;
        self.format = decoded.format;
        self.dirty = false;
        self.external_changed = false;
        self.history.clear();
        self.invalidateLineStates(0);
        self.detectLineEndings();
        // Content changed: bump so syncLspDocuments pushes a fresh didChange.
        self.lsp_version +%= 1;
        for (self.cursors.cursors.items) |*c| {
            c.offset = cursor_mod.floorBoundary(&self.buffer, c.offset);
            if (c.anchor) |a| c.anchor = cursor_mod.floorBoundary(&self.buffer, a);
            c.preferred_col = self.buffer.offsetToPos(c.offset).col;
        }
        self.scroll_top = @min(self.scroll_top, self.buffer.lineCount() -| 1);
        self.refreshDiskStamp(io);
    }

    /// Explicit composite edit. Capture cursors before callers reposition them.
    pub fn beginEdit(self: *Document) !void {
        try self.beginImplicitEdit();
        self.history.beginGroup();
    }
    pub fn endEdit(self: *Document) void {
        self.history.endGroup();
        self.endImplicitEdit();
    }
    fn beginImplicitEdit(self: *Document) !void {
        if (self.edit_depth == 0) {
            const before = try self.allocator.dupe(Cursor, self.cursors.cursors.items);
            errdefer self.allocator.free(before);
            self.edit_after = try self.allocator.alloc(Cursor, before.len);
            self.edit_before = before;
            self.edit_revision = self.history.current_revision;
        }
        self.edit_depth += 1;
    }
    fn endImplicitEdit(self: *Document) void {
        self.edit_depth -= 1;
        if (self.edit_depth != 0) return;
        if (self.history.current_revision != self.edit_revision) {
            const count = self.cursors.count();
            std.debug.assert(count <= self.edit_after.len);
            @memcpy(self.edit_after[0..count], self.cursors.cursors.items);
            self.history.attachCursors(self.edit_before, self.edit_after, count);
            self.dirty = !self.history.isSaved();
        } else {
            self.allocator.free(self.edit_before);
            self.allocator.free(self.edit_after);
        }
        self.edit_before = &.{};
        self.edit_after = &.{};
    }

    pub const RangeEdit = struct { start: usize, end: usize, text: []const u8 };

    /// All owned data and capacity needed to commit an edit without allocation.
    /// Preparing several documents before committing any provides workspace atomicity.
    pub const PreparedEdit = struct {
        allocator: Allocator,
        id: u64,
        version: u64,
        depth: usize,
        first_offset: usize = 0,
        ops: std.ArrayList(UndoOp) = .empty,
        before: ?[]Cursor = null,
        after: ?[]Cursor = null,
        primary_after: ?Cursor = null,

        pub fn deinit(self: *PreparedEdit) void {
            for (self.ops.items) |op| self.allocator.free(op.text);
            self.ops.deinit(self.allocator);
            if (self.before) |cursors| self.allocator.free(cursors);
            if (self.after) |cursors| self.allocator.free(cursors);
        }

        pub fn commit(self: *PreparedEdit, doc: *Document, force_group: bool) void {
            std.debug.assert(doc.id == self.id and doc.buffer.version == self.version and doc.edit_depth == self.depth);
            if (self.ops.items.len == 0) {
                if (self.primary_after) |c| doc.cursors.primary().* = c;
                return;
            }
            doc.validateSnippet();
            if (doc.edit_depth == 0) {
                doc.edit_before = self.before.?;
                doc.edit_after = self.after.?;
                self.before = null;
                self.after = null;
                doc.edit_revision = doc.history.current_revision;
            }
            doc.edit_depth += 1;
            defer doc.endImplicitEdit();
            const grouped = force_group or self.ops.items.len > 1;
            if (grouped) doc.history.beginGroup();
            defer if (grouped) doc.history.endGroup();
            for (self.ops.items) |op| {
                if (doc.snippet_session) |*session| {
                    if (!session.edit(op.offset, if (op.op_type == .delete) op.text.len else 0, if (op.op_type == .insert) op.text.len else 0)) doc.cancelSnippet(false);
                }
                switch (op.op_type) {
                    .insert => {
                        _ = doc.buffer.insert(op.offset, op.text) catch unreachable;
                        doc.cursors.adjustAfterInsert(op.offset, op.text.len);
                    },
                    .delete => {
                        _ = doc.buffer.delete(op.offset, op.text.len);
                        doc.cursors.adjustAfterDelete(op.offset, op.text.len);
                    },
                }
                doc.history.appendPrepared(op);
            }
            self.ops.clearRetainingCapacity();
            if (self.primary_after) |c| doc.cursors.primary().* = c;
            doc.markDirty();
            doc.invalidateLineStates(doc.buffer.offsetToPos(self.first_offset).line);
        }
    };

    /// All allocations precede content/history mutation. Ranges use original
    /// byte offsets and must be disjoint, in descending order.
    pub fn applyRanges(self: *Document, ranges: []const RangeEdit) !void {
        var prepared = try self.prepareRanges(ranges);
        defer prepared.deinit();
        prepared.commit(self, false);
    }

    pub fn prepareRanges(self: *Document, ranges: []const RangeEdit) !PreparedEdit {
        var prepared: PreparedEdit = .{ .allocator = self.allocator, .id = self.id, .version = self.buffer.version, .depth = self.edit_depth };
        errdefer prepared.deinit();
        const ops = &prepared.ops;
        var bytes: usize = 0;
        var lines: usize = 0;
        var previous = self.buffer.byteLen();
        for (ranges) |r| {
            if (r.start > r.end or r.end > previous) return error.InvalidRange;
            previous = r.start;
            try ops.ensureUnusedCapacity(self.allocator, 2);
            if (r.end > r.start) {
                const deleted = try self.allocator.alloc(u8, r.end - r.start);
                for (deleted, 0..) |*byte, i| byte.* = self.buffer.byteAt(r.start + i).?;
                ops.appendAssumeCapacity(.{ .op_type = .delete, .offset = r.start, .text = deleted, .cursor_before = self.cursors.primary().offset, .cursor_after = r.start });
            }
            if (r.text.len > 0) {
                const inserted = try self.allocator.dupe(u8, r.text);
                ops.appendAssumeCapacity(.{ .op_type = .insert, .offset = r.start, .text = inserted, .cursor_before = r.start, .cursor_after = r.start + inserted.len });
                bytes += inserted.len;
                lines += std.mem.count(u8, inserted, "\n");
            }
        }
        if (ops.items.len == 0) return prepared;
        try self.history.undo_stack.ensureUnusedCapacity(self.allocator, ops.items.len);
        try self.buffer.reserveInsert(bytes, lines);
        if (self.edit_depth == 0) {
            prepared.before = try self.allocator.dupe(Cursor, self.cursors.cursors.items);
            prepared.after = try self.allocator.alloc(Cursor, self.cursors.cursors.items.len);
        }
        prepared.first_offset = ranges[ranges.len - 1].start;
        return prepared;
    }

    /// Replace one byte range and put the primary cursor after its replacement.
    pub fn replaceRange(self: *Document, start: usize, end: usize, text: []const u8) !void {
        try self.beginImplicitEdit();
        defer self.endImplicitEdit();
        try self.applyRanges(&.{.{ .start = start, .end = end, .text = text }});
        const c = self.cursors.primary();
        c.offset = start + text.len;
        c.preferred_col = self.buffer.offsetToPos(c.offset).col;
        c.clearSelection();
    }
    pub fn insertAtCursor(self: *Document, text: []const u8) !void {
        if (text.len == 0) return;
        const c = self.cursors.primaryConst();
        if (c.selectionRange()) |r| return self.replaceRange(r.start, r.end, text);
        try self.replaceRange(c.offset, c.offset, text);
    }
    pub fn deleteSelection(self: *Document) !void {
        const r = self.cursors.primaryConst().selectionRange() orelse return;
        try self.replaceRange(r.start, r.end, "");
    }
    /// Explicit byte-count APIs; keyboard character deletion uses boundaries.
    pub fn deleteForward(self: *Document, count: usize) !void {
        const c = self.cursors.primaryConst();
        if (c.hasSelection()) return self.deleteSelection();
        try self.replaceRange(c.offset, c.offset + @min(count, self.buffer.byteLen() - c.offset), "");
    }
    pub fn deleteBackward(self: *Document, count: usize) !void {
        const c = self.cursors.primaryConst();
        if (c.hasSelection()) return self.deleteSelection();
        try self.replaceRange(c.offset -| count, c.offset, "");
    }
    pub fn insertAtAllCursors(self: *Document, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.cursors.count() == 1) return self.insertAtCursor(text);
        try self.editAll(text, 0, false, false);
    }
    pub fn deleteForwardAll(self: *Document, count: usize) !void {
        try self.editAll("", count, false, false);
    }
    pub fn deleteBackwardAll(self: *Document, count: usize) !void {
        try self.editAll("", count, true, false);
    }
    pub fn deleteCharacterAll(self: *Document, backward: bool) !void {
        try self.editAll("", 0, backward, true);
    }

    fn editAll(self: *Document, text: []const u8, count: usize, backward: bool, character: bool) !void {
        const ranges = try self.allocator.alloc(RangeEdit, self.cursors.count());
        defer self.allocator.free(ranges);
        for (self.cursors.cursors.items, ranges) |c, *r| {
            r.* = .{ .start = c.offset, .end = c.offset, .text = text };
            if (c.selectionRange()) |sel| {
                r.start = sel.start;
                r.end = sel.end;
            } else if (text.len == 0) {
                if (backward) {
                    r.start = if (character) cursor_mod.previousBoundary(&self.buffer, c.offset) else c.offset -| count;
                } else r.end = if (character) cursor_mod.nextBoundary(&self.buffer, c.offset) else c.offset + @min(count, self.buffer.byteLen() - c.offset);
            }
        }
        std.mem.sort(RangeEdit, ranges, {}, struct {
            fn less(_: void, a: RangeEdit, b: RangeEdit) bool {
                return if (a.start == b.start) a.end > b.end else a.start > b.start;
            }
        }.less);
        // Union overlapping selections so the same original bytes are edited once.
        var n: usize = 0;
        for (ranges) |r| {
            if (n > 0 and (r.end > ranges[n - 1].start or r.start == ranges[n - 1].start)) {
                ranges[n - 1].start = r.start;
                ranges[n - 1].end = @max(r.end, ranges[n - 1].end);
            } else {
                ranges[n] = r;
                n += 1;
            }
        }
        try self.beginImplicitEdit();
        defer self.endImplicitEdit();
        try self.applyRanges(ranges[0..n]);
        for (self.cursors.cursors.items) |*c| {
            c.clearSelection();
            c.preferred_col = self.buffer.offsetToPos(c.offset).col;
        }
        self.cursors.mergeCursors();
    }
    pub fn lineEnding(self: *const Document) []const u8 {
        return if (self.crlf) "\r\n" else "\n";
    }
    pub fn undoAction(self: *Document) !bool {
        self.cancelSnippet(false);
        if (!try self.history.undoCursors(&self.buffer, &self.cursors)) return false;
        self.markDirty();
        self.invalidateLineStates(0);
        return true;
    }
    pub fn redoAction(self: *Document) !bool {
        self.cancelSnippet(false);
        if (!try self.history.redoCursors(&self.buffer, &self.cursors)) return false;
        self.markDirty();
        self.invalidateLineStates(0);
        return true;
    }

    /// Preparation includes text, live ranges, buffer capacity and undo snapshots.
    /// Nothing observable changes until every allocation has succeeded.
    pub fn insertSnippet(self: *Document, template: *const snippets.Template, start: usize, end: usize, use_tabs: bool, indent_width: usize) !void {
        if (self.cursors.count() != 1) return error.MultipleCursors;
        if (start > end or end > self.buffer.byteLen()) return error.InvalidRange;
        const line_start = self.buffer.line_starts.items[self.buffer.offsetToPos(start).line];
        var indent_end = line_start;
        while (self.buffer.byteAt(indent_end)) |c| {
            if (c != ' ' and c != '\t') break;
            indent_end += 1;
        }
        const base = try self.allocator.alloc(u8, indent_end - line_start);
        defer self.allocator.free(base);
        for (base, 0..) |*byte, i| byte.* = self.buffer.byteAt(line_start + i).?;
        var expansion = try template.expand(self.allocator, base, use_tabs, indent_width, self.lineEnding());
        defer expansion.deinit(self.allocator);
        expansion.session.relocate(start);
        var edit = try self.prepareRanges(&.{.{ .start = start, .end = end, .text = expansion.text }});
        defer edit.deinit();
        const has_stops = expansion.session.stops.len > 0;
        const first = if (has_stops) expansion.session.active() else expansion.session.final;
        edit.primary_after = .{ .offset = if (has_stops) first.end else first.start, .anchor = if (has_stops and first.start != first.end) first.start else null };
        self.cancelSnippet(false);
        edit.commit(self, true);
        self.cursors.primary().preferred_col = self.buffer.offsetToPos(self.cursors.primary().offset).col;
        if (has_stops) {
            self.snippet_session = expansion.session;
            expansion.session.stops = &.{};
        }
        self.history.merge_allowed = false;
    }

    pub fn cancelSnippet(self: *Document, clear_selection: bool) void {
        if (self.snippet_session) |*session| {
            session.deinit(self.allocator);
            self.snippet_session = null;
            self.history.merge_allowed = false;
            if (clear_selection) self.cursors.primary().clearSelection();
        }
    }

    pub fn validateSnippet(self: *Document) void {
        if (self.snippet_session) |*session| {
            const c = self.cursors.primaryConst();
            if (self.cursors.count() != 1 or !session.contains(c.offset, c.anchor)) self.cancelSnippet(false);
        }
    }

    pub fn navigateSnippet(self: *Document, previous: bool) bool {
        self.validateSnippet();
        const session = if (self.snippet_session) |*s| s else return false;
        self.history.merge_allowed = false;
        if (previous) {
            session.current -|= 1;
        } else if (session.current + 1 < session.stops.len) {
            session.current += 1;
        } else {
            const offset = session.final.start;
            self.cancelSnippet(true);
            self.cursors.primary().* = .{ .offset = offset, .preferred_col = self.buffer.offsetToPos(offset).col };
            return true;
        }
        const r = session.active();
        self.cursors.primary().* = .{ .offset = r.end, .anchor = if (r.start == r.end) null else r.start, .preferred_col = self.buffer.offsetToPos(r.end).col };
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
        try self.beginEdit();
        defer self.endEdit();
        const pos = self.cursorPos();
        const line_start = self.buffer.posToOffset(pos.line, 0);
        const line_end = if (pos.line + 1 < self.buffer.lineCount())
            self.buffer.line_starts.items[pos.line + 1] // includes the \n
        else
            self.buffer.byteLen();
        const len = line_end - line_start;
        if (len == 0) return;
        const c = self.cursors.primary();
        try self.applyRanges(&.{.{ .start = line_start, .end = line_end, .text = "" }});
        c.offset = @min(line_start, self.buffer.byteLen());
        c.preferred_col = self.buffer.offsetToPos(c.offset).col;
        c.clearSelection();
        self.markDirty();
        self.invalidateLineStates(pos.line);
    }

    /// Duplicate the current line below.
    pub fn duplicateLine(self: *Document) !void {
        try self.beginEdit();
        defer self.endEdit();
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
        try self.applyRanges(&.{.{ .start = line_end, .end = line_end, .text = dup }});
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
        const n_cursors = self.cursors.count();
        const cur_remap = try self.allocator.alloc(?LineCol, n_cursors);
        defer self.allocator.free(cur_remap);
        const anc_remap = try self.allocator.alloc(?LineCol, n_cursors);
        defer self.allocator.free(anc_remap);
        @memset(cur_remap, null);
        @memset(anc_remap, null);
        for (self.cursors.cursors.items[0..n_cursors], 0..) |c, i| {
            const p = self.buffer.offsetToPos(c.offset);
            if (p.line == line_a or p.line == line_b) {
                cur_remap[i] = .{ .line = if (p.line == line_a) line_b else line_a, .col = p.col };
            }
            if (c.anchor) |a| {
                const ap = self.buffer.offsetToPos(a);
                if (ap.line == line_a or ap.line == line_b) {
                    anc_remap[i] = .{ .line = if (ap.line == line_a) line_b else line_a, .col = ap.col };
                }
            }
        }

        try self.beginEdit();
        defer self.endEdit();

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

        try self.applyRanges(&.{.{ .start = a_start, .end = b_end, .text = new_text }});

        // Remap cursors onto their moved lines.
        for (self.cursors.cursors.items[0..n_cursors], 0..) |*c, i| {
            if (cur_remap[i]) |p| {
                c.offset = cursor_mod.lineOffset(&self.buffer, p.line, p.col);
                c.preferred_col = p.col;
            }
            if (anc_remap[i]) |p| {
                c.anchor = cursor_mod.lineOffset(&self.buffer, p.line, p.col);
            }
        }

        self.markDirty();
        self.invalidateLineStates(line_a);
    }

    /// Delete a word forward from cursor (Ctrl+Delete).
    pub fn deleteWordForward(self: *Document) !void {
        try self.beginEdit();
        defer self.endEdit();
        const c = self.cursors.primary();
        const start = c.offset;
        var tmp = c.*;
        tmp.moveWordRight(&self.buffer);
        const end = tmp.offset;
        if (end > start) {
            try self.applyRanges(&.{.{ .start = start, .end = end, .text = "" }});
            self.markDirty();
            self.invalidateLineStates(self.buffer.offsetToPos(start).line);
        }
    }

    /// Delete a word backward from cursor (Ctrl+Backspace).
    pub fn deleteWordBackward(self: *Document) !void {
        try self.beginEdit();
        defer self.endEdit();
        const c = self.cursors.primary();
        const end = c.offset;
        if (end == 0) return;
        var tmp = c.*;
        tmp.moveWordLeft(&self.buffer);
        const start = tmp.offset;
        if (end > start) {
            try self.applyRanges(&.{.{ .start = start, .end = end, .text = "" }});
            self.markDirty();
            self.invalidateLineStates(self.buffer.offsetToPos(start).line);
        }
    }

    /// Dedent the current line (remove leading spaces/tab).
    pub fn dedentLine(self: *Document, tab_width: usize) !void {
        try self.beginEdit();
        defer self.endEdit();
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
        try self.applyRanges(&.{.{ .start = line_start, .end = line_start + remove, .text = "" }});
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

        try self.beginEdit();
        defer self.endEdit();

        var edits: std.ArrayList(RangeEdit) = .empty;
        defer edits.deinit(self.allocator);

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
                    try edits.append(self.allocator, .{ .start = sa, .end = sa + suf_len, .text = "" });
                }
                const pre_at = line_start + ws;
                try edits.append(self.allocator, .{ .start = pre_at, .end = pre_at + pre_len, .text = "" });
            }
            try self.applyRanges(edits.items);
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
                    try edits.append(self.allocator, .{ .start = at, .end = at, .text = t });
                }
                const indent = if (any_nonblank) @min(min_indent, ws) else ws;
                const at = line_start + indent;
                try edits.append(self.allocator, .{ .start = at, .end = at, .text = lead });
            }
            try self.applyRanges(edits.items);
        }

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
        self.dirty = !self.history.isSaved();
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

    pub fn detectLineEndings(self: *Document) void {
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

    /// File extension of `file_path` without the leading dot — null when the
    /// document is untitled or its name has no extension.
    pub fn fileExtension(self: *const Document) ?[]const u8 {
        const path = self.file_path orelse return null;
        const ext = std.fs.path.extension(path);
        const ext_clean = if (ext.len > 0 and ext[0] == '.') ext[1..] else ext;
        if (ext_clean.len == 0) return null;
        return ext_clean;
    }

    /// Detect language from the file extension using the editor's language registry.
    pub fn detectLanguage(self: *Document, editor: anytype) void {
        const ext = self.fileExtension() orelse return;
        self.language = editor.findLanguage(ext);
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

test "document open rejects binary files" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(t.io, "blob.bin", .{});
    try f.writeStreamingAll(t.io, "MZ\x00\x01\x02binary\x00bytes");
    f.close(t.io);
    const tf = try tmp.dir.createFile(t.io, "fine.txt", .{});
    try tf.writeStreamingAll(t.io, "plain text\n");
    tf.close(t.io);

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try std.Io.Dir.realPathFile(tmp.dir, t.io, ".", &tmp_path_buf)];

    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    const bin_path = try std.fmt.bufPrint(&path_buf, "{s}/blob.bin", .{tmp_path});
    try std.testing.expectError(error.BinaryFile, doc.open(t.io, bin_path));
    // Buffer restored to empty — a catching caller isn't left holding bytes
    try std.testing.expectEqual(@as(usize, 0), doc.buffer.byteLen());

    const txt_path = try std.fmt.bufPrint(&path_buf, "{s}/fine.txt", .{tmp_path});
    try doc.open(t.io, txt_path);
    try std.testing.expectEqualStrings("plain text", doc.lineContent(0));
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

test "document external change detection and reload" {
    const t = std.testing;
    const path = ".zig-cache/zide-test-external.txt";
    {
        const f = try std.Io.Dir.cwd().createFile(t.io, path, .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "hello\nworld\n");
    }
    defer std.Io.Dir.cwd().deleteFile(t.io, path) catch {};

    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.open(t.io, path);
    try t.expect(doc.disk_stamp != null);
    try t.expect(!doc.checkExternalChange(t.io));

    // Rewrite behind the editor's back until the mtime visibly moves
    // (Windows file times tick coarsely — same churn as the filetree test).
    var attempts: usize = 0;
    while (!doc.checkExternalChange(t.io) and attempts < 10_000) : (attempts += 1) {
        const f = std.Io.Dir.cwd().createFile(t.io, path, .{}) catch break;
        defer f.close(t.io);
        f.writeStreamingAll(t.io, "hello\nworld\nagain\n") catch break;
    }
    try t.expect(doc.checkExternalChange(t.io));

    // Reload picks up new content, keeps the cursor, clears flags
    doc.cursors.primary().offset = 12; // end of the old content
    try doc.reloadFromDisk(t.io);
    try t.expectEqualStrings("hello\nworld\nagain\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqual(@as(usize, 12), doc.cursors.primaryConst().offset);
    try t.expect(!doc.checkExternalChange(t.io));
    try t.expect(!doc.dirty);

    // Saving re-stamps the mtime so our own write isn't a "change"
    try doc.buffer.loadText("mine\n");
    doc.dirty = true;
    try doc.save(t.io);
    try t.expect(!doc.checkExternalChange(t.io));
    try t.expect(!doc.external_changed);

    // A vanished file counts as changed
    try std.Io.Dir.cwd().deleteFile(t.io, path);
    try t.expect(doc.checkExternalChange(t.io));
}

test "saved checkpoint survives undo redo branching and trimming" {
    const t = std.testing;
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "saved.txt" });
    defer t.allocator.free(path);
    try doc.loadText("a");
    doc.cursors.primary().moveToEnd(&doc.buffer);
    try doc.insertAtCursor("b");
    try doc.saveAs(t.io, path);
    try t.expect(!doc.dirty);
    _ = try doc.undoAction();
    try t.expectEqualStrings("a", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(doc.dirty);
    _ = try doc.redoAction();
    try t.expect(!doc.dirty);
    try doc.insertAtCursor("c"); // saving split adjacent typing into a new group
    _ = try doc.undoAction();
    try t.expectEqualStrings("ab", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(!doc.dirty);
    _ = try doc.undoAction();
    try doc.save(t.io); // save an earlier history state
    try t.expect(!doc.dirty);
    try doc.insertAtCursor("x"); // branch cannot inherit the discarded revision
    try t.expect(doc.dirty);
    try t.expect(!doc.history.canRedo());
    doc.history.max_size = 1;
    try doc.insertAtCursor("yz");
    _ = try doc.undoAction();
    try t.expectEqualStrings("ax", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(doc.dirty);
    const old_checkpoint = doc.history.saved_revision;
    try t.expectError(error.NoFilePath, blk: {
        const old_path = doc.file_path;
        doc.file_path = null;
        defer doc.file_path = old_path;
        break :blk doc.save(t.io);
    });
    try t.expectEqual(old_checkpoint, doc.history.saved_revision);
}

test "multi-cursor history restores positions selections and primary identity" {
    const t = std.testing;
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.loadText("a\na");
    doc.cursors.primary().* = .{ .offset = 1, .anchor = 0, .preferred_col = 7 };
    try doc.cursors.addCursor(3);
    doc.cursors.cursors.items[1].anchor = 2;
    const before = try t.allocator.dupe(Cursor, doc.cursors.cursors.items);
    defer t.allocator.free(before);
    try doc.insertAtAllCursors("long");
    const after = try t.allocator.dupe(Cursor, doc.cursors.cursors.items);
    defer t.allocator.free(after);
    _ = try doc.undoAction();
    try t.expectEqualStrings("a\na", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualSlices(Cursor, before, doc.cursors.cursors.items);
    _ = try doc.redoAction();
    try t.expectEqualStrings("long\nlong", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualSlices(Cursor, after, doc.cursors.cursors.items);
}

test "large block edits include every cursor and retain one complete undo group" {
    const t = std.testing;
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    for ([_]usize{ 257, 300, 1000 }) |count| {
        const text = try t.allocator.alloc(u8, count * 2);
        defer t.allocator.free(text);
        for (0..count) |i| @memcpy(text[i * 2 ..][0..2], "a\n");
        try doc.loadText(text);
        try doc.cursors.setBlockSelection(&doc.buffer, 0, 0, count - 1, 0);
        try doc.insertAtAllCursors("!");
        try t.expectEqual(count, std.mem.count(u8, doc.buffer.slice(0, doc.buffer.byteLen()), "!"));
        _ = try doc.undoAction();
        try t.expectEqualStrings(text, doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expectEqual(count, doc.cursors.count());
        try doc.deleteCharacterAll(false);
        try t.expectEqual(count, doc.buffer.byteLen());
        _ = try doc.undoAction();
        try doc.cursors.setBlockSelection(&doc.buffer, 0, 1, count - 1, 1);
        try doc.deleteCharacterAll(true);
        try t.expectEqual(count, doc.buffer.byteLen());
        _ = try doc.undoAction();
        try doc.cursors.setBlockSelection(&doc.buffer, 0, 0, count - 1, 1);
        try doc.insertAtAllCursors("xyz");
        try t.expectEqual(count, std.mem.count(u8, doc.buffer.slice(0, doc.buffer.byteLen()), "xyz"));
        _ = try doc.undoAction();
        try t.expectEqualStrings(text, doc.buffer.slice(0, doc.buffer.byteLen()));
    }
}

test "line movement remaps more than 256 cursors and undoes all of them" {
    const t = std.testing;
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.loadText("a" ** 300 ++ "\nbb");
    for (1..300) |i| try doc.cursors.addCursor(i);
    try doc.moveLineDown();
    for (doc.cursors.cursors.items, 0..) |c, i| try t.expectEqual(i + 3, c.offset);
    _ = try doc.undoAction();
    for (doc.cursors.cursors.items, 0..) |c, i| try t.expectEqual(i, c.offset);
}

test "character deletion uses each cursor's UTF-8 width and CRLF boundary" {
    const t = std.testing;
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    const text = "\xc3\xa9\n\xe7\x95\x8c\n\xf0\x9f\x98\x80\r\nx";
    try doc.loadText(text);
    try doc.cursors.addCursor(3);
    try doc.cursors.addCursor(7);
    try doc.deleteCharacterAll(false);
    try t.expectEqualStrings("\n\n\r\nx", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = try doc.undoAction();
    for (doc.cursors.cursors.items) |*c| c.moveRight(&doc.buffer);
    try doc.deleteCharacterAll(true);
    try t.expectEqualStrings("\n\n\r\nx", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = try doc.undoAction();
    doc.cursors.clearSecondary();
    doc.cursors.primary().offset = 11;
    try doc.deleteCharacterAll(false);
    try t.expectEqualStrings("\xc3\xa9\n\xe7\x95\x8c\n\xf0\x9f\x98\x80x", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = try doc.undoAction();
    doc.cursors.primary().offset = 13;
    try doc.deleteCharacterAll(true);
    try t.expectEqualStrings("\xc3\xa9\n\xe7\x95\x8c\n\xf0\x9f\x98\x80x", doc.buffer.slice(0, doc.buffer.byteLen()));
}

fn checkAtomicMultiEdit(allocator: Allocator) !void {
    const t = std.testing;
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.loadText("a\na");
    try doc.cursors.addCursor(2);
    // Fail only allocations in the edit, after building a valid initial document.
    doc.allocator = allocator;
    doc.buffer.allocator = allocator;
    doc.history.allocator = allocator;
    doc.cursors.allocator = allocator;
    doc.insertAtAllCursors("long\n") catch |err| {
        try t.expectEqualStrings("a\na", doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expectEqual(@as(usize, 2), doc.cursors.cursors.items[1].offset);
        try t.expect(!doc.history.canUndo());
        try t.expect(!doc.dirty);
        return err;
    };
    doc.buffer.allocator = t.allocator; // verification must not consume the next injected failure
    try t.expectEqualStrings("long\na\nlong\na", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "allocation failure never partially applies a multi-cursor edit" {
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        checkAtomicMultiEdit(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            continue;
        };
        try std.testing.expect(!failing.has_induced_failure);
        return;
    }
    return error.TestUnexpectedResult;
}

fn checkAtomicUndo(allocator: Allocator) !void {
    const t = std.testing;
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.loadText("a\nb");
    try doc.cursors.addCursor(2);
    try doc.insertAtAllCursors("xyz\n");
    const before = try t.allocator.dupe(u8, doc.buffer.slice(0, doc.buffer.byteLen()));
    defer t.allocator.free(before);
    const cursors = try t.allocator.dupe(Cursor, doc.cursors.cursors.items);
    defer t.allocator.free(cursors);
    doc.allocator = allocator;
    doc.history.allocator = allocator;
    doc.buffer.allocator = allocator;
    doc.cursors.allocator = allocator;
    _ = doc.undoAction() catch |err| {
        doc.buffer.allocator = t.allocator;
        try t.expectEqualStrings(before, doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expectEqualSlices(Cursor, cursors, doc.cursors.cursors.items);
        try t.expect(doc.history.canUndo());
        try t.expect(!doc.history.canRedo());
        try t.expect(doc.dirty);
        return err;
    };
    doc.buffer.allocator = t.allocator;
    try t.expectEqualStrings("a\nb", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "undo allocation failure preserves buffer cursors and history" {
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        checkAtomicUndo(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            continue;
        };
        try std.testing.expect(!failing.has_induced_failure);
        return;
    }
    return error.TestUnexpectedResult;
}

test "line swaps remap EOF carets and anchors by original logical line" {
    const t = std.testing;
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.loadText("a\nbb");
    doc.cursors.primary().offset = 4;
    doc.cursors.primary().anchor = 2;
    try doc.cursors.addCursor(0);
    const before = try t.allocator.dupe(Cursor, doc.cursors.cursors.items);
    defer t.allocator.free(before);
    try doc.swapAdjacentLines(0);
    try t.expectEqualStrings("bb\na", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqual(@as(usize, 2), doc.cursors.primary().offset);
    try t.expectEqual(@as(?usize, 0), doc.cursors.primary().anchor);
    try t.expectEqual(@as(usize, 3), doc.cursors.cursors.items[1].offset);
    const after = try t.allocator.dupe(Cursor, doc.cursors.cursors.items);
    defer t.allocator.free(after);
    _ = try doc.undoAction();
    try t.expectEqualSlices(Cursor, before, doc.cursors.cursors.items);
    _ = try doc.redoAction();
    try t.expectEqualSlices(Cursor, after, doc.cursors.cursors.items);
    try doc.loadText("a\n");
    doc.cursors.primary().offset = 2;
    doc.cursors.primary().anchor = 0;
    try doc.swapAdjacentLines(0);
    try t.expectEqualStrings("\na", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqual(@as(usize, 0), doc.cursors.primary().offset);
    try t.expectEqual(@as(?usize, 1), doc.cursors.primary().anchor);
    try doc.loadText("a\nbb\nc");
    doc.cursors.primary().offset = 6;
    doc.cursors.primary().anchor = 5;
    try doc.swapAdjacentLines(0);
    try t.expectEqual(@as(usize, 6), doc.cursors.primary().offset);
    try t.expectEqual(@as(?usize, 5), doc.cursors.primary().anchor);
}

test "save and Save As failures preserve bytes and all saved metadata" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "café.txt" });
    defer t.allocator.free(path);
    const dest = try std.fs.path.join(t.allocator, &.{ root, "other.txt" });
    defer t.allocator.free(dest);
    const format: TextFormat = .{ .encoding = .windows1252 };
    try text_file.write(t.allocator, t.io, path, "café\r\n", format);
    try text_file.atomicWrite(t.allocator, t.io, dest, "destination");
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.openWithEncoding(t.io, path, .windows1252);
    try doc.insertAtCursor("edit ");
    const revision = doc.history.saved_revision;
    const stamp = doc.disk_stamp;
    for (std.enums.values(text_file.FailureStage)) |stage| {
        text_file.testing_failure = stage;
        defer text_file.testing_failure = null;
        if (doc.save(t.io)) |_| return error.ExpectedFailure else |_| {}
        if (doc.saveAsWithFormat(t.io, dest, .{ .encoding = .utf16_be, .bom = true })) |_| return error.ExpectedFailure else |_| {}
        try t.expectEqualStrings(path, doc.file_path.?);
        try t.expectEqualStrings("café.txt", doc.display_name);
        try t.expectEqualDeep(format, doc.format);
        try t.expectEqual(revision, doc.history.saved_revision);
        try t.expectEqual(stamp, doc.disk_stamp);
        try t.expect(doc.dirty);
        const old = try tmp.dir.readFileAlloc(t.io, "café.txt", t.allocator, .limited(100));
        defer t.allocator.free(old);
        try t.expectEqualStrings("caf\xe9\r\n", old);
        const other = try tmp.dir.readFileAlloc(t.io, "other.txt", t.allocator, .limited(100));
        defer t.allocator.free(other);
        try t.expectEqualStrings("destination", other);
        var it = tmp.dir.iterate();
        var count: usize = 0;
        while (try it.next(t.io)) |_| count += 1;
        try t.expectEqual(@as(usize, 2), count);
    }
    try doc.insertAtCursor("😀");
    try t.expectError(error.UnrepresentableText, doc.save(t.io));
    try t.expectEqualDeep(format, doc.format);
    try doc.saveWithFormat(t.io, .{});
    try t.expectEqualDeep(TextFormat{}, doc.format);
    try t.expect(!doc.dirty);
}

test "malformed and binary opens and reloads preserve the entire document" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "text.txt" });
    defer t.allocator.free(path);
    try text_file.write(t.allocator, t.io, path, "a\r\nb\r\nc", .{ .encoding = .utf16_le, .bom = true });
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.open(t.io, path);
    try doc.insertAtCursor("é");
    doc.scroll_top = 2;
    doc.scroll_left = 3;
    doc.cursors.primary().anchor = 0;
    try doc.cursors.addCursor(doc.buffer.byteLen());
    const before = try doc.buffer.textAlloc(t.allocator);
    defer t.allocator.free(before);
    const cursors = try t.allocator.dupe(Cursor, doc.cursors.cursors.items);
    defer t.allocator.free(cursors);
    const revision = doc.history.current_revision;
    const stamp = doc.disk_stamp;
    for ([_][]const u8{ "\xff\xfe\x00\xd8", "\xff\xfe\x00\x00", "\xff\xfe\x00" }) |bytes| {
        try text_file.atomicWrite(t.allocator, t.io, path, bytes);
        if (doc.reloadFromDisk(t.io)) |_| return error.ExpectedFailure else |_| {}
        if (doc.open(t.io, path)) |_| return error.ExpectedFailure else |_| {}
        try t.expectEqualStrings(before, doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expectEqualSlices(Cursor, cursors, doc.cursors.cursors.items);
        try t.expectEqual(revision, doc.history.current_revision);
        try t.expectEqual(stamp, doc.disk_stamp);
        try t.expectEqual(@as(usize, 2), doc.scroll_top);
        try t.expectEqual(@as(usize, 3), doc.scroll_left);
        try t.expect(doc.dirty and doc.crlf);
        try t.expectEqualDeep(TextFormat{ .encoding = .utf16_le, .bom = true }, doc.format);
    }
}

test "open and reload allocation failures preserve content history and cursors" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "wide.txt" });
    defer t.allocator.free(path);
    try text_file.write(t.allocator, t.io, path, "new 😀\r\n", .{ .encoding = .utf16_le, .bom = true });
    for ([_]bool{ false, true }) |reload| {
        var completed = false;
        for (0..64) |fail_index| {
            var doc = try Document.init(t.allocator);
            defer doc.deinit();
            try doc.loadText("old\ntext");
            try doc.setFilePath(if (reload) path else "original.txt");
            try doc.insertAtCursor("edit ");
            doc.cursors.primary().anchor = 0;
            doc.scroll_top = 1;
            doc.scroll_left = 2;
            const before = doc.cursors.primary().*;
            const revision = doc.history.current_revision;
            var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
            doc.allocator = failing.allocator();
            const result = if (reload) doc.reloadWithEncoding(t.io, .utf16_le) else doc.open(t.io, path);
            doc.allocator = t.allocator;
            doc.buffer.allocator = t.allocator;
            if (result) |_| {
                try t.expectEqualStrings("new 😀\r\n", doc.buffer.slice(0, doc.buffer.byteLen()));
                completed = true;
                break;
            } else |err| {
                try t.expectEqual(error.OutOfMemory, err);
                try t.expectEqualStrings("edit old\ntext", doc.buffer.slice(0, doc.buffer.byteLen()));
                try t.expectEqualDeep(before, doc.cursors.primary().*);
                try t.expectEqual(revision, doc.history.current_revision);
                try t.expectEqual(@as(usize, 1), doc.scroll_top);
                try t.expectEqual(@as(usize, 2), doc.scroll_left);
                try t.expect(doc.dirty);
                try t.expectEqualDeep(TextFormat{}, doc.format);
                try t.expectEqualStrings(if (reload) path else "original.txt", doc.file_path.?);
            }
        }
        try t.expect(completed);
    }
}

test "every Save As allocation failure leaves destination and document unchanged" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "saved.txt" });
    defer t.allocator.free(path);
    try text_file.atomicWrite(t.allocator, t.io, path, "original disk");
    for (0..64) |fail_index| {
        var doc = try Document.init(t.allocator);
        defer doc.deinit();
        try doc.loadText("café😀");
        try doc.setFilePath("old.txt");
        doc.cursors.primary().offset = 3;
        try doc.insertAtCursor("edit"); // Interior gap exercises fallible snapshots.
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        doc.allocator = failing.allocator();
        const result = doc.saveAsWithFormat(t.io, path, .{ .encoding = .utf16_be, .bom = true });
        doc.allocator = t.allocator;
        if (result) |_| {
            try t.expect(!doc.dirty);
            return;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expect(doc.dirty and doc.history.canUndo());
            try t.expectEqualStrings("old.txt", doc.file_path.?);
            try t.expectEqualDeep(TextFormat{}, doc.format);
            const bytes = try tmp.dir.readFileAlloc(t.io, "saved.txt", t.allocator, .limited(100));
            defer t.allocator.free(bytes);
            try t.expectEqualStrings("original disk", bytes);
            var it = tmp.dir.iterate();
            var count: usize = 0;
            while (try it.next(t.io)) |_| count += 1;
            try t.expectEqual(@as(usize, 1), count);
        }
    }
    return error.ExpectedSuccess;
}
