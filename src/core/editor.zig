const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const CommandRegistry = @import("commands.zig").CommandRegistry;
const registerBuiltins = @import("commands.zig").registerBuiltins;
const SystemClipboard = @import("clipboard.zig").SystemClipboard;
const KeybindMap = @import("keybind.zig").KeybindMap;
const Layout = @import("layout.zig").Layout;
const SplitDirection = @import("layout.zig").SplitDirection;
const theme_mod = @import("theme.zig");
const EditorTheme = theme_mod.EditorTheme;
const TuiTheme = theme_mod.TuiTheme;

/// The central editor state. NOT a global singleton — passed explicitly.
/// Owns open documents, the command registry, and global editor settings.
pub const Editor = struct {
    documents: std.ArrayList(Document),
    active_doc_idx: usize = 0,
    commands: CommandRegistry,
    allocator: Allocator,

    /// Whether the editor should keep running.
    running: bool = true,
    /// Status bar message (transient).
    status_message: []const u8 = "",
    /// Buffer for formatted status messages.
    status_buf: [128]u8 = undefined,

    /// Internal clipboard (used when system clipboard unavailable).
    clipboard: []const u8 = "",
    /// Optional frontend-provided clipboard (e.g. SDL3 native clipboard on Wayland).
    clipboard_get_fn: ?*const fn () []const u8 = null,
    clipboard_set_fn: ?*const fn ([]const u8) void = null,
    /// Number of visible lines for page up/down.
    page_size: usize = 30,

    /// Indentation settings.
    use_tabs: bool = false,
    tab_width: usize = 4,

    /// Editor interaction mode.
    mode: Mode = .normal,
    /// Find/replace input buffers.
    find_buf: [256]u8 = undefined,
    find_buf_len: usize = 0,
    replace_buf: [256]u8 = undefined,
    replace_buf_len: usize = 0,
    /// Which field is active in find_replace mode (false=find, true=replace).
    replace_field_active: bool = false,
    /// File open input buffer.
    open_buf: [512]u8 = undefined,
    open_buf_len: usize = 0,
    /// Command palette input buffer.
    palette_buf: [256]u8 = undefined,
    palette_buf_len: usize = 0,
    /// Go to line input buffer.
    goto_buf: [32]u8 = undefined,
    goto_buf_len: usize = 0,
    /// Saved cursor offset when entering find mode (for incremental search).
    find_origin: usize = 0,

    /// Word wrap (soft-wrap long lines in display).
    word_wrap: bool = true,
    /// Text area width in columns (set by TUI frontend for visual-row movement).
    text_width: u16 = 80,
    /// Auto-close brackets/quotes when typing opening character.
    auto_close_brackets: bool = true,
    /// Auto-save dirty documents after a period of inactivity.
    auto_save: bool = false,
    /// Auto-save delay in milliseconds (default 5 seconds).
    auto_save_interval_ms: u32 = 5000,
    /// Minimum digit width for line number gutter (default 3).
    gutter_min_digits: usize = 3,
    /// Left-click clears secondary cursors (default true).
    click_clears_cursors: bool = true,
    /// Maximum undo history size per document (0 = unlimited).
    max_undo_history: usize = 100,
    /// Command palette selection index (for Tab cycling).
    palette_selected: usize = 0,

    /// Data-driven keybinding map (populated with CUA defaults, modifiable via Lua).
    keybinds: KeybindMap,

    /// Layout tree for split panes (GUI).
    layout: Layout = undefined,
    /// Currently focused pane index.
    active_pane: u8 = 0,

    /// GUI editor theme (colors for editor area, overlays, gutter, etc.).
    theme: EditorTheme = theme_mod.gui_dark,
    /// TUI editor theme (ANSI or RGB colors for terminal rendering).
    tui_theme: TuiTheme = theme_mod.tui_terminal,
    /// Name of the active GUI theme preset ("dark", "light", "high_contrast", or "custom").
    theme_name: []const u8 = "dark",
    /// Name of the active TUI theme preset ("terminal", "dark", "light", "high_contrast", or "custom").
    tui_theme_name: []const u8 = "terminal",

    /// Settings panel selection index.
    settings_selected: usize = 0,
    /// Settings panel: which numeric field is being edited (null = none).
    settings_editing: ?usize = null,
    /// Settings panel: buffer for editing numeric values.
    settings_num_buf: [16]u8 = undefined,
    settings_num_len: usize = 0,

    pub const Mode = enum {
        normal,
        find,
        find_replace,
        file_open,
        save_as,
        command_palette,
        goto_line,
        confirm_quit,
        settings,
    };

    pub fn init(allocator: Allocator) !Editor {
        var editor = Editor{
            .documents = .empty,
            .commands = CommandRegistry.init(allocator),
            .allocator = allocator,
            .keybinds = KeybindMap.init(allocator),
            .layout = try Layout.init(allocator),
        };
        // Always have at least one empty document
        var doc = Document.init(allocator);
        doc.history.max_size = editor.max_undo_history;
        try doc.loadText("");
        try editor.documents.append(allocator, doc);
        // Register built-in commands
        try registerBuiltins(&editor.commands);
        // Load default keybindings
        try editor.keybinds.loadDefaults();
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        for (self.documents.items) |*doc| {
            doc.deinit();
        }
        self.documents.deinit(self.allocator);
        self.commands.deinit();
        self.keybinds.deinit();
        self.layout.deinit();
        if (self.clipboard.len > 0) {
            self.allocator.free(self.clipboard);
        }
    }

    /// Get the currently active document (from the focused pane).
    pub fn activeDoc(self: *Editor) *Document {
        const doc_idx = self.activeDocIdx();
        return &self.documents.items[doc_idx];
    }

    pub fn activeDocConst(self: *const Editor) *const Document {
        const doc_idx = self.activeDocIdx();
        return &self.documents.items[doc_idx];
    }

    /// Get the document index for the currently focused pane.
    fn activeDocIdx(self: *const Editor) usize {
        if (self.active_pane < self.layout.panes.items.len) {
            return self.layout.panes.items[self.active_pane].doc_idx;
        }
        return self.active_doc_idx;
    }

    /// Open a new empty document and make it active (in the focused pane).
    pub fn newDocument(self: *Editor) !*Document {
        var doc = Document.init(self.allocator);
        doc.history.max_size = self.max_undo_history;
        try doc.loadText("");
        try self.documents.append(self.allocator, doc);
        const idx = self.documents.items.len - 1;
        self.active_doc_idx = idx;
        self.paneShowDoc(idx);
        return self.activeDoc();
    }

    /// Open a file into a new document tab (in the focused pane).
    pub fn openFile(self: *Editor, path: []const u8) !*Document {
        var doc = Document.init(self.allocator);
        doc.history.max_size = self.max_undo_history;
        try doc.open(path);
        try self.documents.append(self.allocator, doc);
        const idx = self.documents.items.len - 1;
        self.active_doc_idx = idx;
        self.paneShowDoc(idx);
        return self.activeDoc();
    }

    /// Close the active document. Returns false if it was the last one
    /// (creates a new empty document in that case).
    pub fn closeActiveDoc(self: *Editor) bool {
        if (self.documents.items.len <= 1) {
            // Reset to empty document
            self.documents.items[0].deinit();
            self.documents.items[0] = Document.init(self.allocator);
            self.documents.items[0].loadText("") catch {};
            self.active_doc_idx = 0;
            self.paneShowDoc(0);
            return false;
        }
        const removed_idx = self.active_doc_idx;
        self.documents.items[removed_idx].deinit();
        _ = self.documents.orderedRemove(removed_idx);
        if (self.active_doc_idx >= self.documents.items.len) {
            self.active_doc_idx = self.documents.items.len - 1;
        }
        // Fix up all pane doc indices after document removal:
        // - Panes pointing at the removed doc get reassigned to active_doc_idx
        // - Panes pointing above the removed doc shift down by 1
        for (self.layout.panes.items) |*pane| {
            if (pane.doc_idx == removed_idx) {
                pane.doc_idx = self.active_doc_idx;
            } else if (pane.doc_idx > removed_idx) {
                pane.doc_idx -= 1;
            }
        }
        return true;
    }

    /// Switch to the next document tab (in the focused pane).
    pub fn nextDoc(self: *Editor) void {
        if (self.documents.items.len <= 1) return;
        self.active_doc_idx = (self.active_doc_idx + 1) % self.documents.items.len;
        self.paneShowDoc(self.active_doc_idx);
    }

    /// Switch to the previous document tab (in the focused pane).
    pub fn prevDoc(self: *Editor) void {
        if (self.documents.items.len <= 1) return;
        if (self.active_doc_idx == 0) {
            self.active_doc_idx = self.documents.items.len - 1;
        } else {
            self.active_doc_idx -= 1;
        }
        self.paneShowDoc(self.active_doc_idx);
    }

    /// Switch to document at index (in the currently focused pane).
    pub fn switchToDoc(self: *Editor, idx: usize) void {
        if (idx < self.documents.items.len) {
            self.active_doc_idx = idx;
            self.paneShowDoc(idx);
        }
    }

    /// Execute a command by name.
    pub fn execCommand(self: *Editor, name: []const u8, args: ?[]const u8) bool {
        return self.commands.execute(self, name, args);
    }

    /// Execute an action by name. Handles special actions (quit, save, find, etc.)
    /// that aren't in the command registry, then falls back to execCommand.
    /// Returns true if the action was recognized and handled.
    pub fn execAction(self: *Editor, action: []const u8) bool {
        if (std.mem.eql(u8, action, "quit")) {
            if (self.hasUnsavedChanges()) {
                self.mode = .confirm_quit;
            } else {
                self.running = false;
            }
            return true;
        }
        if (std.mem.eql(u8, action, "save")) {
            self.activeDoc().save() catch {};
            return true;
        }
        if (std.mem.eql(u8, action, "find")) {
            self.mode = .find;
            self.find_buf_len = 0;
            self.find_origin = self.activeDoc().cursors.primary().offset;
            return true;
        }
        if (std.mem.eql(u8, action, "find_replace")) {
            self.mode = .find_replace;
            self.find_buf_len = 0;
            self.replace_buf_len = 0;
            self.replace_field_active = false;
            self.find_origin = self.activeDoc().cursors.primary().offset;
            return true;
        }
        if (std.mem.eql(u8, action, "file_open")) {
            self.mode = .file_open;
            self.open_buf_len = 0;
            return true;
        }
        if (std.mem.eql(u8, action, "save_as")) {
            self.mode = .save_as;
            // Pre-fill with current file path if available
            if (self.activeDocConst().file_path) |path| {
                const len = @min(path.len, self.open_buf.len);
                @memcpy(self.open_buf[0..len], path[0..len]);
                self.open_buf_len = len;
            } else {
                self.open_buf_len = 0;
            }
            return true;
        }
        if (std.mem.eql(u8, action, "command_palette")) {
            self.mode = .command_palette;
            self.palette_buf_len = 0;
            self.palette_selected = 0;
            return true;
        }
        if (std.mem.eql(u8, action, "goto_line")) {
            self.mode = .goto_line;
            self.goto_buf_len = 0;
            return true;
        }
        if (std.mem.eql(u8, action, "settings")) {
            self.mode = .settings;
            self.settings_selected = 0;
            self.settings_editing = null;
            return true;
        }
        if (std.mem.eql(u8, action, "new_document")) {
            _ = self.newDocument() catch {};
            return true;
        }
        if (std.mem.eql(u8, action, "close_tab")) {
            _ = self.closeActiveDoc();
            return true;
        }
        // Split pane actions
        if (std.mem.eql(u8, action, "split_vertical")) {
            self.splitActive(.horizontal); // horizontal = side by side
            return true;
        }
        if (std.mem.eql(u8, action, "split_horizontal")) {
            self.splitActive(.vertical); // vertical = top/bottom
            return true;
        }
        if (std.mem.eql(u8, action, "close_pane")) {
            self.closePaneAction();
            return true;
        }
        if (std.mem.eql(u8, action, "focus_next_pane")) {
            self.focusNextPane();
            return true;
        }
        if (std.mem.eql(u8, action, "focus_prev_pane")) {
            self.focusPrevPane();
            return true;
        }
        // Fall back to command registry
        return self.commands.execute(self, action, null);
    }

    /// Number of open documents.
    pub fn docCount(self: *const Editor) usize {
        return self.documents.items.len;
    }

    /// Set the clipboard content (both internal and system).
    pub fn setClipboard(self: *Editor, text: []const u8) void {
        if (self.clipboard.len > 0) {
            self.allocator.free(self.clipboard);
        }
        self.clipboard = self.allocator.dupe(u8, text) catch "";
        // Use frontend clipboard if available, otherwise system clipboard
        if (self.clipboard_set_fn) |setFn| {
            setFn(text);
        } else {
            _ = SystemClipboard.setText(text);
        }
    }

    /// Get clipboard text (prefer system clipboard, fall back to internal).
    pub fn getClipboard(self: *Editor) []const u8 {
        // Use frontend clipboard if available, otherwise system clipboard
        if (self.clipboard_get_fn) |getFn| {
            const text = getFn();
            if (text.len > 0) {
                // Update internal clipboard (don't free — frontend owns this memory)
                if (self.clipboard.len > 0) {
                    self.allocator.free(self.clipboard);
                }
                self.clipboard = self.allocator.dupe(u8, text) catch return self.clipboard;
                return self.clipboard;
            }
        } else if (SystemClipboard.getText(self.allocator)) |sys_text| {
            // Update internal clipboard with system contents
            if (self.clipboard.len > 0) {
                self.allocator.free(self.clipboard);
            }
            self.clipboard = sys_text;
        }
        return self.clipboard;
    }

    /// Auto-save all dirty documents that have a file path.
    /// Returns the number of documents saved.
    pub fn autoSaveAll(self: *Editor) usize {
        var saved: usize = 0;
        for (self.documents.items) |*doc| {
            if (doc.dirty and doc.file_path != null) {
                doc.save() catch continue;
                saved += 1;
            }
        }
        if (saved > 0) {
            const msg = std.fmt.bufPrint(&self.status_buf, "Auto-saved {d} file(s)", .{saved}) catch "Auto-saved";
            self.status_message = msg;
        }
        return saved;
    }

    /// Check if any document has unsaved changes.
    pub fn hasUnsavedChanges(self: *const Editor) bool {
        for (self.documents.items) |doc| {
            if (doc.dirty) return true;
        }
        return false;
    }

    // ---- Split pane operations ----

    /// Split the currently focused pane. The new pane shows the same document.
    pub fn splitActive(self: *Editor, direction: SplitDirection) void {
        const current_doc_idx = self.activeDocIdx();
        const new_pane = self.layout.splitPane(self.active_pane, direction, current_doc_idx) catch return;
        self.active_pane = new_pane;
        // Keep active_doc_idx in sync for compatibility
        self.active_doc_idx = current_doc_idx;
    }

    /// Close the currently focused pane. If it's the last pane, does nothing.
    pub fn closePaneAction(self: *Editor) void {
        if (self.layout.paneCount() <= 1) return;
        const closed_pane = self.active_pane;
        // Move focus to a sibling before closing
        if (self.layout.nextPane(closed_pane)) |next| {
            self.active_pane = next;
        } else {
            self.active_pane = 0;
        }
        _ = self.layout.closePane(closed_pane);
        // Update active_doc_idx to match new focused pane
        self.active_doc_idx = self.activeDocIdx();
    }

    /// Focus the next pane in traversal order.
    pub fn focusNextPane(self: *Editor) void {
        if (self.layout.nextPane(self.active_pane)) |next| {
            self.active_pane = next;
            self.active_doc_idx = self.activeDocIdx();
        }
    }

    /// Focus the previous pane in traversal order.
    pub fn focusPrevPane(self: *Editor) void {
        if (self.layout.prevPane(self.active_pane)) |prev| {
            self.active_pane = prev;
            self.active_doc_idx = self.activeDocIdx();
        }
    }

    /// Set the active pane by pane ID and update active_doc_idx.
    pub fn focusPane(self: *Editor, pane_id: u8) void {
        if (pane_id < self.layout.panes.items.len) {
            self.active_pane = pane_id;
            self.active_doc_idx = self.layout.panes.items[pane_id].doc_idx;
        }
    }

    /// Switch the active pane to show a specific document.
    pub fn paneShowDoc(self: *Editor, doc_idx: usize) void {
        if (self.active_pane < self.layout.panes.items.len) {
            self.layout.panes.items[self.active_pane].doc_idx = doc_idx;
            self.active_doc_idx = doc_idx;
        }
    }
};

// ---- Tests ----

test "editor init and basic operations" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator);
    defer editor.deinit();

    // Should start with one empty document
    try std.testing.expectEqual(@as(usize, 1), editor.docCount());
    try std.testing.expectEqual(@as(usize, 0), editor.activeDoc().buffer.byteLen());
}

test "editor command execution" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator);
    defer editor.deinit();

    try editor.activeDoc().loadText("hello");
    // Execute cursor_right command
    try std.testing.expect(editor.execCommand("cursor_right", null));
    try std.testing.expectEqual(@as(usize, 1), editor.activeDoc().cursors.primary().offset);

    // Non-existent command returns false
    try std.testing.expect(!editor.execCommand("nonexistent", null));
}

test "editor insert via command" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator);
    defer editor.deinit();

    try editor.activeDoc().loadText("hello");
    _ = editor.execCommand("insert_char", "X");
    try std.testing.expectEqualStrings("Xhello", editor.activeDoc().lineContent(0));
}

test "editor multiple documents" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator);
    defer editor.deinit();

    try editor.activeDoc().loadText("doc1");
    _ = try editor.newDocument();
    try editor.activeDoc().loadText("doc2");

    try std.testing.expectEqual(@as(usize, 2), editor.docCount());
    try std.testing.expectEqual(@as(usize, 1), editor.active_doc_idx);
    try std.testing.expectEqualStrings("doc2", editor.activeDoc().lineContent(0));

    editor.prevDoc();
    try std.testing.expectEqualStrings("doc1", editor.activeDoc().lineContent(0));

    editor.nextDoc();
    try std.testing.expectEqualStrings("doc2", editor.activeDoc().lineContent(0));
}

test "editor undo via command" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator);
    defer editor.deinit();

    try editor.activeDoc().loadText("hello");
    _ = editor.execCommand("insert_char", "X");
    try std.testing.expectEqualStrings("Xhello", editor.activeDoc().lineContent(0));

    _ = editor.execCommand("undo", null);
    try std.testing.expectEqualStrings("hello", editor.activeDoc().lineContent(0));

    _ = editor.execCommand("redo", null);
    try std.testing.expectEqualStrings("Xhello", editor.activeDoc().lineContent(0));
}
