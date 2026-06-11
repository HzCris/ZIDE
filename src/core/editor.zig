const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const CommandRegistry = @import("commands.zig").CommandRegistry;
const registerBuiltins = @import("commands.zig").registerBuiltins;
const SystemClipboard = @import("clipboard.zig").SystemClipboard;
const KeybindMap = @import("keybind.zig").KeybindMap;
const Layout = @import("layout.zig").Layout;
const PaneContent = @import("layout.zig").PaneContent;
const SplitDirection = @import("layout.zig").SplitDirection;
pub const terminal_mod = @import("terminal.zig");
const theme_mod = @import("theme.zig");
const EditorTheme = theme_mod.EditorTheme;
const TuiTheme = theme_mod.TuiTheme;
const SyntaxTheme = theme_mod.SyntaxTheme;
const TuiSyntaxTheme = theme_mod.TuiSyntaxTheme;
const syntax = @import("syntax.zig");
pub const lsp_mod = @import("lsp.zig");
pub const filetree_mod = @import("filetree.zig");

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
    /// Save open files + cursors on quit and restore them on a bare launch.
    session_persistence: bool = false,
    /// Maximum undo history size per document (0 = unlimited).
    max_undo_history: usize = 100,
    /// Command palette selection index (for Tab cycling).
    palette_selected: usize = 0,

    /// The std.Io instance (from Juicy Main; std.testing.io in tests) —
    /// threaded through file/process/timing operations like an Allocator.
    io: std.Io,

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

    /// Path to a custom monospace TTF font. Empty = use DVUI default ("Vera Sans Mono").
    /// Owned by the editor allocator when non-empty.
    mono_font_path: []const u8 = "",
    /// Base size for the monospace font. 0 = DVUI default.
    mono_font_size: f32 = 0,

    /// Optional wake callback copied onto every spawned Terminal so its
    /// reader thread can unblock a blocking frontend event loop (the TUI
    /// sets this; the GUI repaints on its own cadence and leaves it null).
    terminal_wake_fn: ?*const fn () void = null,

    /// Settings panel selection index.
    settings_selected: usize = 0,
    /// Settings panel: which numeric field is being edited (null = none).
    settings_editing: ?usize = null,
    /// Settings panel: buffer for editing numeric values.
    settings_num_buf: [16]u8 = undefined,
    settings_num_len: usize = 0,

    /// LSP client (null if not started).
    lsp: ?*lsp_mod.LspClient = null,

    /// Language served by `lsp`. Documents in any other language are not
    /// synced to the server — zls would otherwise receive (and squiggle)
    /// .txt/.md/etc. buffers as if they were Zig source.
    lsp_language: []const u8 = "zig",

    /// Completion items from LSP.
    completion_items: std.ArrayList(EditorCompletionItem),
    /// Whether the completion popup is active.
    completion_active: bool = false,
    /// Currently selected completion item index.
    completion_selected: usize = 0,

    /// Lua-registered LSP server configs (language → command).
    lsp_configs: std.ArrayList(LspConfig),

    /// Open terminal emulators (null entries are closed/freed terminals).
    terminals: std.ArrayList(?*terminal_mod.Terminal),

    /// Registered languages (Zig built-in + Lua-loaded extensions).
    /// Each LanguageDef is individually heap-allocated because documents hold
    /// `*const LanguageDef` — pointers must stay stable when extensions
    /// register new languages. (Was std.SegmentedList; removed in Zig 0.16.)
    languages: std.ArrayList(*syntax.LanguageDef),
    /// GUI syntax highlight colors.
    syntax_theme: SyntaxTheme = theme_mod.syn_gui_dark,
    /// TUI syntax highlight colors.
    tui_syntax_theme: TuiSyntaxTheme = theme_mod.syn_tui_terminal,
    /// Per-language GUI syntax theme overrides (keyed by language name).
    lang_syntax_overrides: std.ArrayList(LangSyntaxOverride),

    /// File tree side panel model (created lazily by `ensureFiletree`).
    filetree: ?filetree_mod.FileTree = null,
    /// Whether the file tree side panel is shown.
    filetree_visible: bool = true,
    /// Whether the file tree has keyboard focus (frontends route keys to it).
    filetree_focused: bool = false,
    /// Which side of the window the file tree docks on.
    filetree_side: FiletreeSide = .left,
    /// GUI file tree panel width in pixels.
    filetree_width: f32 = 240,
    /// TUI file tree panel width in columns.
    tui_filetree_width: u16 = 30,
    /// TUI file tree scroll offset (rows).
    tui_filetree_scroll: usize = 0,
    /// Starting directory for the file tree (null = current directory). Owned.
    filetree_root: ?[]const u8 = null,
    /// Which file-tree prompt is active while mode == .filetree_prompt.
    filetree_prompt_kind: FiletreePromptKind = .create,
    /// Rel-path of the prompt's target node (owned; survives refreshes).
    filetree_prompt_target: ?[]u8 = null,

    pub const EditorCompletionItem = struct {
        label: []const u8,
        detail: ?[]const u8 = null,
        insert_text: ?[]const u8 = null,
    };

    pub const LspConfig = struct {
        language: []const u8,
        command: []const u8,
    };

    pub const LangSyntaxOverride = struct {
        name: []const u8,
        gui_theme: SyntaxTheme,
        tui_theme: TuiSyntaxTheme,
    };

    pub const FiletreeSide = enum { left, right };

    pub const FiletreePromptKind = enum { create, rename, delete_confirm };

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
        filetree_prompt,
    };

    pub fn init(allocator: Allocator, io: std.Io) !Editor {
        var editor = Editor{
            .documents = .empty,
            .commands = CommandRegistry.init(allocator),
            .allocator = allocator,
            .io = io,
            .keybinds = KeybindMap.init(allocator),
            .layout = try Layout.init(allocator),
            .completion_items = .empty,
            .lsp_configs = .empty,
            .terminals = .empty,
            .languages = .empty,
            .lang_syntax_overrides = .empty,
        };
        // Register built-in Zig language (heap-allocated: see `languages` doc)
        const zig_lang = try allocator.create(syntax.LanguageDef);
        zig_lang.* = syntax.lang_zig;
        errdefer allocator.destroy(zig_lang);
        try editor.languages.append(allocator, zig_lang);
        // Always have at least one empty document
        var doc = try Document.init(allocator);
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
        // Free Lua-registered languages (built-in Zig has null arena)
        for (self.languages.items) |lang| {
            lang.deinit();
            self.allocator.destroy(lang);
        }
        self.clearCompletionItems();
        self.completion_items.deinit(self.allocator);
        for (self.lsp_configs.items) |cfg| {
            self.allocator.free(cfg.language);
            self.allocator.free(cfg.command);
        }
        self.lsp_configs.deinit(self.allocator);
        for (self.terminals.items) |maybe_term| {
            if (maybe_term) |term| term.deinit();
        }
        self.terminals.deinit(self.allocator);
        self.languages.deinit(self.allocator);
        for (self.lang_syntax_overrides.items) |ov| {
            self.allocator.free(ov.name);
        }
        self.lang_syntax_overrides.deinit(self.allocator);
        if (self.clipboard.len > 0) {
            self.allocator.free(self.clipboard);
        }
        if (self.mono_font_path.len > 0) {
            self.allocator.free(self.mono_font_path);
        }
        if (self.filetree) |*ft| ft.deinit();
        if (self.filetree_root) |r| self.allocator.free(r);
        if (self.filetree_prompt_target) |tgt| self.allocator.free(tgt);
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
            return switch (self.layout.panes.items[self.active_pane].content) {
                .editor => |idx| idx,
                .terminal => self.active_doc_idx,
            };
        }
        return self.active_doc_idx;
    }

    /// Check if the currently focused pane is a terminal.
    pub fn activePaneIsTerminal(self: *const Editor) bool {
        if (self.active_pane < self.layout.panes.items.len) {
            return self.layout.panes.items[self.active_pane].content == .terminal;
        }
        return false;
    }

    /// Get the terminal index of the active pane (if it's a terminal).
    pub fn activePaneTerminalIdx(self: *const Editor) ?usize {
        if (self.active_pane < self.layout.panes.items.len) {
            return switch (self.layout.panes.items[self.active_pane].content) {
                .terminal => |idx| idx,
                .editor => null,
            };
        }
        return null;
    }

    /// Open a new empty document and make it active (in the focused pane).
    pub fn newDocument(self: *Editor) !*Document {
        var doc = try Document.init(self.allocator);
        errdefer doc.deinit();
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
        var doc = try Document.init(self.allocator);
        errdefer doc.deinit();
        doc.history.max_size = self.max_undo_history;
        try doc.open(self.io, path);
        try self.documents.append(self.allocator, doc);
        const idx = self.documents.items.len - 1;
        self.active_doc_idx = idx;
        self.paneShowDoc(idx);
        const active = self.activeDoc();
        active.detectLanguage(self);
        self.lspNotifyOpen(active);
        return active;
    }

    /// Open `path`, or switch to the tab that already has it open
    /// (separator-normalized compare, case-insensitive on Windows).
    pub fn openOrFocus(self: *Editor, path: []const u8) !*Document {
        for (self.documents.items, 0..) |*doc, idx| {
            const dp = doc.file_path orelse continue;
            if (filetree_mod.normPathEql(dp, path)) {
                self.switchToDoc(idx);
                return self.activeDoc();
            }
        }
        return try self.openFile(path);
    }

    /// Get the file tree, creating it on first use. Returns null (with a
    /// status message, and the panel hidden so the failure doesn't repeat
    /// every frame) if the root directory can't be opened.
    pub fn ensureFiletree(self: *Editor) ?*filetree_mod.FileTree {
        if (self.filetree == null) {
            const root = self.filetree_root orelse ".";
            self.filetree = filetree_mod.FileTree.init(self.allocator, self.io, root) catch |err| {
                const msg = std.fmt.bufPrint(&self.status_buf, "File tree: cannot open '{s}': {s}", .{ root, @errorName(err) }) catch "File tree: open failed";
                self.status_message = msg;
                self.filetree_visible = false;
                return null;
            };
            self.filetree.?.gitRefresh();
        }
        return &self.filetree.?;
    }

    /// Ctrl+B cycle: hidden → shown + focused; shown but editor focused →
    /// focus the tree; tree focused → hide (focus returns to the editor).
    /// Gives a full keyboard round-trip together with Escape.
    pub fn toggleFiletree(self: *Editor) void {
        if (!self.filetree_visible) {
            self.filetree_visible = true;
            if (self.ensureFiletree() != null) self.filetree_focused = true;
        } else if (!self.filetree_focused) {
            if (self.ensureFiletree() != null) {
                self.filetree_focused = true;
                self.filetree.?.scroll_to_selected = true;
            } else {
                self.filetree_visible = false;
            }
        } else {
            self.filetree_visible = false;
            self.filetree_focused = false;
        }
    }

    /// Re-root the file tree at the parent of the current root (tree
    /// Backspace/'u'). The new root sticks for the session via
    /// filetree_root (not persisted to init.lua).
    pub fn filetreeRootUp(self: *Editor) void {
        const ft = self.ensureFiletree() orelse return;
        const parent = std.fs.path.dirname(ft.root_path) orelse {
            self.status_message = "File tree: already at the filesystem root";
            return;
        };
        const new_root = self.allocator.dupe(u8, parent) catch return;
        if (self.filetree_root) |old| self.allocator.free(old);
        self.filetree_root = new_root;
        if (self.filetree) |*old_ft| old_ft.deinit();
        self.filetree = null;
        if (self.ensureFiletree() == null) return;
        const msg = std.fmt.bufPrint(&self.status_buf, "File tree root: {s}", .{self.filetree.?.root_path}) catch "";
        self.status_message = msg;
    }

    /// Begin a file-tree prompt (mode → .filetree_prompt). For .create the
    /// target is the selected directory (or the parent of a selected file);
    /// rename/delete require a non-root selection.
    pub fn startFiletreePrompt(self: *Editor, kind: FiletreePromptKind) void {
        const ft = if (self.filetree) |*f| f else return;
        var target_idx: u32 = 0;
        switch (kind) {
            .create => {
                const sel = ft.selectedNodeIdx() orelse 0;
                target_idx = if (ft.nodes.items[sel].kind == .dir) sel else ft.nodes.items[sel].parent;
            },
            .rename, .delete_confirm => {
                const sel = ft.selectedNodeIdx() orelse {
                    self.status_message = "File tree: nothing selected";
                    return;
                };
                if (sel == 0) return;
                target_idx = sel;
            },
        }
        const target = self.allocator.dupe(u8, ft.nodes.items[target_idx].rel_path) catch return;
        if (self.filetree_prompt_target) |old| self.allocator.free(old);
        self.filetree_prompt_target = target;
        self.filetree_prompt_kind = kind;
        self.open_buf_len = 0;
        if (kind == .rename) {
            // Prefill the input with the current name
            const name = ft.nodes.items[target_idx].name;
            const n = @min(name.len, self.open_buf.len);
            @memcpy(self.open_buf[0..n], name[0..n]);
            self.open_buf_len = n;
        }
        self.mode = .filetree_prompt;
    }

    /// Cancel the file-tree prompt and return to normal mode.
    pub fn cancelFiletreePrompt(self: *Editor) void {
        if (self.filetree_prompt_target) |old| self.allocator.free(old);
        self.filetree_prompt_target = null;
        self.mode = .normal;
    }

    /// Apply the active file-tree prompt (Enter / 'y'): perform the file
    /// operation, refresh the tree, report via status message, and return
    /// to normal mode.
    pub fn applyFiletreePrompt(self: *Editor) void {
        defer self.cancelFiletreePrompt();
        const ft = if (self.filetree) |*f| f else return;
        const target = self.filetree_prompt_target orelse return;
        const input = self.open_buf[0..self.open_buf_len];
        switch (self.filetree_prompt_kind) {
            .create => {
                const parent_idx = ft.findByPath(target) orelse 0;
                const created = ft.createEntry(self.allocator, parent_idx, input) catch |err| {
                    self.filetreeOpError("Create", err);
                    return;
                };
                defer self.allocator.free(created);
                ft.refresh() catch {};
                ft.gitRefresh();
                _ = ft.expandToPath(created) catch null;
                const msg = std.fmt.bufPrint(&self.status_buf, "Created {s}", .{created}) catch "Created";
                self.status_message = msg;
            },
            .rename => {
                const idx = ft.findByPath(target) orelse {
                    self.status_message = "Rename failed: entry no longer exists";
                    return;
                };
                const new_rel = ft.renameEntry(self.allocator, idx, input) catch |err| {
                    self.filetreeOpError("Rename", err);
                    return;
                };
                defer self.allocator.free(new_rel);
                self.fixupDocPathsAfterRename(ft, target, new_rel);
                ft.refresh() catch {};
                ft.gitRefresh();
                _ = ft.expandToPath(new_rel) catch null;
                const msg = std.fmt.bufPrint(&self.status_buf, "Renamed to {s}", .{new_rel}) catch "Renamed";
                self.status_message = msg;
            },
            .delete_confirm => {
                const idx = ft.findByPath(target) orelse {
                    self.status_message = "Delete failed: entry no longer exists";
                    return;
                };
                ft.deleteEntry(idx) catch |err| {
                    self.filetreeOpError("Delete", err);
                    return;
                };
                ft.refresh() catch {};
                ft.gitRefresh();
                const msg = std.fmt.bufPrint(&self.status_buf, "Deleted {s}", .{target}) catch "Deleted";
                self.status_message = msg;
            },
        }
    }

    fn filetreeOpError(self: *Editor, op: []const u8, err: anyerror) void {
        const msg = std.fmt.bufPrint(&self.status_buf, "{s} failed: {s}", .{ op, @errorName(err) }) catch "File operation failed";
        self.status_message = msg;
    }

    /// After a rename on disk, point open documents at the new path —
    /// both the renamed entry itself and anything inside a renamed dir.
    fn fixupDocPathsAfterRename(self: *Editor, ft: *filetree_mod.FileTree, old_rel: []const u8, new_rel: []const u8) void {
        const old_abs = std.fs.path.join(self.allocator, &.{ ft.root_path, old_rel }) catch return;
        defer self.allocator.free(old_abs);
        const new_abs = std.fs.path.join(self.allocator, &.{ ft.root_path, new_rel }) catch return;
        defer self.allocator.free(new_abs);
        for (self.documents.items) |*doc| {
            const dp = doc.file_path orelse continue;
            if (filetree_mod.normPathEql(dp, old_abs)) {
                doc.setFilePath(new_abs) catch {};
            } else if (dp.len > old_abs.len and
                filetree_mod.normPathEql(dp[0..old_abs.len], old_abs) and
                (dp[old_abs.len] == '/' or dp[old_abs.len] == '\\'))
            {
                // Document inside a renamed directory
                const joined = std.mem.concat(self.allocator, u8, &.{ new_abs, dp[old_abs.len..] }) catch continue;
                defer self.allocator.free(joined);
                doc.setFilePath(joined) catch {};
            }
        }
    }

    /// Close the active document. Returns false if it was the last one
    /// (creates a new empty document in that case).
    pub fn closeActiveDoc(self: *Editor) bool {
        return self.closeDocAt(self.active_doc_idx);
    }

    /// Close the document at `idx` (e.g. a tab's close button) without
    /// stealing a focused terminal pane. Returns false if it was the last
    /// document (replaced with a fresh empty one in that case).
    pub fn closeDocAt(self: *Editor, doc_idx: usize) bool {
        if (doc_idx >= self.documents.items.len) return false;
        if (self.documents.items.len <= 1) {
            // Build the replacement first — deinit'ing the old document and
            // then failing to construct a new one would leave items[0] invalid.
            var fresh = Document.init(self.allocator) catch return false;
            fresh.history.max_size = self.max_undo_history;
            fresh.loadText("") catch {};
            // Send didClose before resetting
            self.lspDidClose(&self.documents.items[0]);
            self.documents.items[0].deinit();
            self.documents.items[0] = fresh;
            self.active_doc_idx = 0;
            // Don't convert a focused terminal pane into an editor pane.
            if (!self.activePaneIsTerminal()) self.paneShowDoc(0);
            return false;
        }
        const removed_idx = doc_idx;
        self.lspDidClose(&self.documents.items[removed_idx]);
        self.documents.items[removed_idx].deinit();
        _ = self.documents.orderedRemove(removed_idx);
        if (self.active_doc_idx > removed_idx) {
            self.active_doc_idx -= 1;
        } else if (self.active_doc_idx >= self.documents.items.len) {
            self.active_doc_idx = self.documents.items.len - 1;
        }
        // Fix up all pane doc indices after document removal:
        // - Editor panes pointing at the removed doc get reassigned to active_doc_idx
        // - Editor panes pointing above the removed doc shift down by 1
        for (self.layout.panes.items) |*pane| {
            switch (pane.content) {
                .editor => |*idx| {
                    if (idx.* == removed_idx) {
                        idx.* = self.active_doc_idx;
                    } else if (idx.* > removed_idx) {
                        idx.* -= 1;
                    }
                },
                .terminal => {},
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
            const doc = self.activeDoc();
            doc.save(self.io) catch |err| {
                if (err == error.NoFilePath) {
                    // Untitled buffer — route to Save As instead of silently
                    // dropping the save.
                    return self.execAction("save_as");
                }
                const msg = std.fmt.bufPrint(&self.status_buf, "Save failed: {s}", .{@errorName(err)}) catch "Save failed";
                self.status_message = msg;
                return true;
            };
            self.lspDidSave(doc);
            if (self.filetree) |*ft| ft.gitRefresh();
            const msg = std.fmt.bufPrint(&self.status_buf, "Saved {s}", .{doc.display_name}) catch "Saved";
            self.status_message = msg;
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
        if (std.mem.eql(u8, action, "next_doc")) {
            self.nextDoc();
            return true;
        }
        if (std.mem.eql(u8, action, "prev_doc")) {
            self.prevDoc();
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
        // Terminal actions — work in both frontends. (An old gate claimed the
        // TUI "can't host PTYs"; it can — terminal-in-terminal is how vim's
        // :terminal works, the TUI renders the grid as cells, and the reader
        // thread wakes the event loop via terminal_wake_fn.)
        if (std.mem.eql(u8, action, "toggle_terminal")) {
            self.toggleTerminal();
            return true;
        }
        if (std.mem.eql(u8, action, "close_terminal")) {
            self.closeActiveTerminal();
            return true;
        }
        if (std.mem.eql(u8, action, "open_terminal_right")) {
            self.openTerminalRight();
            return true;
        }
        // LSP actions
        if (std.mem.eql(u8, action, "lsp_completion")) {
            self.triggerCompletion();
            return true;
        }
        if (std.mem.eql(u8, action, "lsp_goto_definition")) {
            self.triggerGotoDefinition();
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
                    // Reset before the fallible dupe — returning the freed
                    // slice on OOM was a use-after-free.
                    self.clipboard = "";
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
                doc.save(self.io) catch continue;
                saved += 1;
            }
        }
        if (saved > 0) {
            if (self.filetree) |*ft| ft.gitRefresh();
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

    // ---- Session persistence ----

    /// Path of the session file (~/.config/zide/session). Static buffer.
    fn sessionFilePath() ?[]const u8 {
        const lua_settings = @import("lua_settings.zig");
        const dir = lua_settings.getConfigDir() orelse return null;
        const S = struct {
            var buf: [600]u8 = undefined;
        };
        return std.fmt.bufPrint(&S.buf, "{s}/session", .{dir}) catch null;
    }

    /// Write the session file: the active tab plus one
    /// `doc <cursor> <scroll> <path>` line per open file (path last — it may
    /// contain spaces). Untitled buffers are not recorded. Called on normal
    /// exit by both frontends; no-op unless session_persistence is enabled.
    pub fn saveSession(self: *Editor) void {
        if (!self.session_persistence) return;
        const lua_settings = @import("lua_settings.zig");
        const path = sessionFilePath() orelse return;
        if (lua_settings.getConfigDir()) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        }

        // Active index within the saved (path-bearing) list, not all docs.
        var active_saved: usize = 0;
        var n: usize = 0;
        for (self.documents.items, 0..) |*doc, i| {
            if (doc.file_path == null) continue;
            if (i == self.active_doc_idx) active_saved = n;
            n += 1;
        }

        const file = std.Io.Dir.cwd().createFile(self.io, path, .{}) catch return;
        defer file.close(self.io);

        var buf: [1024]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "active {d}\n", .{active_saved}) catch return;
        file.writeStreamingAll(self.io, head) catch return;
        for (self.documents.items) |*doc| {
            const fp = doc.file_path orelse continue;
            const line = std.fmt.bufPrint(&buf, "doc {d} {d} {s}\n", .{
                doc.cursors.primaryConst().offset, doc.scroll_top, fp,
            }) catch continue; // path too long for buf — skip that file
            file.writeStreamingAll(self.io, line) catch return;
        }
    }

    /// Restore the session written by saveSession (files, cursor positions,
    /// scroll, active tab). Files that no longer open are skipped. Returns
    /// the number of documents restored; 0 unless session_persistence is on.
    pub fn restoreSession(self: *Editor) usize {
        if (!self.session_persistence) return 0;
        const path = sessionFilePath() orelse return 0;
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) catch return 0;
        defer self.allocator.free(content);

        var active: usize = 0;
        var opened: usize = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.startsWith(u8, line, "active ")) {
                active = std.fmt.parseInt(usize, line["active ".len..], 10) catch 0;
            } else if (std.mem.startsWith(u8, line, "doc ")) {
                var fields = std.mem.splitScalar(u8, line["doc ".len..], ' ');
                const off_str = fields.next() orelse continue;
                const scroll_str = fields.next() orelse continue;
                const file_path = fields.rest();
                if (file_path.len == 0) continue;

                var doc: *Document = undefined;
                if (opened == 0) {
                    // Replace the initial empty document, like a CLI file open.
                    doc = self.activeDoc();
                    doc.open(self.io, file_path) catch continue;
                    doc.detectLanguage(self);
                    self.lspNotifyOpen(doc);
                } else {
                    doc = self.openFile(file_path) catch continue;
                }
                const offset = std.fmt.parseInt(usize, off_str, 10) catch 0;
                const scroll = std.fmt.parseInt(usize, scroll_str, 10) catch 0;
                const c = doc.cursors.primary();
                c.offset = @min(offset, doc.buffer.byteLen());
                c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
                doc.scroll_top = @min(scroll, doc.buffer.lineCount() -| 1);
                opened += 1;
            }
        }
        if (opened > 0) {
            self.switchToDoc(@min(active, self.documents.items.len - 1));
        }
        return opened;
    }

    // ---- Split pane operations ----

    /// Split the currently focused pane. The new pane shows the same document.
    pub fn splitActive(self: *Editor, direction: SplitDirection) void {
        const current_doc_idx = self.activeDocIdx();
        const new_pane = self.layout.splitPane(self.active_pane, direction, .{ .editor = current_doc_idx }) catch return;
        self.active_pane = new_pane;
        // Keep active_doc_idx in sync for compatibility
        self.active_doc_idx = current_doc_idx;
    }

    /// Close the currently focused pane. If it's the last pane, does nothing.
    pub fn closePaneAction(self: *Editor) void {
        if (self.layout.paneCount() <= 1) {
            // Common confusion: panes are splits, not tabs. Say so instead
            // of silently doing nothing.
            self.status_message = "No split panes open — Ctrl+W closes the current tab";
            return;
        }
        const closed_pane = self.active_pane;
        // If closing a terminal pane, clean up the terminal
        if (closed_pane < self.layout.panes.items.len) {
            switch (self.layout.panes.items[closed_pane].content) {
                .terminal => |idx| {
                    self.closeTerminal(idx);
                    return;
                },
                .editor => {},
            }
        }
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
            switch (self.layout.panes.items[pane_id].content) {
                .editor => |idx| self.active_doc_idx = idx,
                .terminal => {},
            }
        }
    }

    /// Switch the active pane to show a specific document.
    pub fn paneShowDoc(self: *Editor, doc_idx: usize) void {
        if (self.active_pane < self.layout.panes.items.len) {
            self.layout.panes.items[self.active_pane].content = .{ .editor = doc_idx };
            self.active_doc_idx = doc_idx;
        }
    }

    // ---- Terminal operations ----

    /// Open a new terminal in a bottom split pane.
    pub fn openTerminal(self: *Editor) void {
        self.openTerminalSplit(.vertical);
    }

    pub fn openTerminalRight(self: *Editor) void {
        self.openTerminalSplit(.horizontal);
    }

    fn openTerminalSplit(self: *Editor, direction: @import("layout.zig").SplitDirection) void {
        const builtin = @import("builtin");
        const command = if (builtin.os.tag == .windows) "powershell.exe" else "/bin/bash";
        const term = terminal_mod.Terminal.init(self.allocator, self.io, 80, 24, command) catch |err| {
            std.log.err("Failed to open terminal: {}", .{err});
            self.status_message = "Failed to open terminal (see zide.log)";
            return;
        };
        term.wake_fn = self.terminal_wake_fn;
        self.terminals.append(self.allocator, term) catch return;
        const term_idx = self.terminals.items.len - 1;
        const new_pane = self.layout.splitPane(self.active_pane, direction, .{ .terminal = term_idx }) catch return;
        self.active_pane = new_pane;
    }

    /// Close a terminal by index: stop PTY, close its pane, focus a neighbor.
    /// If it's the last live pane, convert it to an editor instead of closing.
    pub fn closeTerminal(self: *Editor, term_idx: usize) void {
        if (term_idx >= self.terminals.items.len) return;
        // Find the pane showing this terminal
        for (self.layout.panes.items, 0..) |pane, i| {
            if (pane.content == .terminal and pane.content.terminal == term_idx) {
                const pane_u8: u8 = @intCast(i);
                if (self.active_pane == pane_u8) {
                    if (self.layout.nextPane(self.active_pane)) |next| {
                        self.active_pane = next;
                    } else {
                        self.active_pane = 0;
                    }
                }
                const closed = self.layout.closePane(pane_u8);
                if (!closed) {
                    // It's the last live pane — convert to editor so the user isn't stuck on a blank pane.
                    self.layout.panes.items[i].content = .{ .editor = self.active_doc_idx };
                    self.active_pane = pane_u8;
                }
                break;
            }
        }
        // Deinit the terminal and null out the entry
        if (self.terminals.items[term_idx]) |t| {
            t.deinit();
            self.terminals.items[term_idx] = null;
        }
        // Ensure active_pane is a valid leaf in the live tree
        self.ensureValidActivePane();
        self.active_doc_idx = self.activeDocIdx();
    }

    /// Make sure active_pane points to a real leaf in the layout tree.
    /// If it doesn't, find the first valid leaf (preferring editor panes).
    fn ensureValidActivePane(self: *Editor) void {
        // Check if active_pane is actually a leaf in the tree
        if (self.layout.findLeafNode(self.active_pane) != null) return;
        // Not found — find first editor leaf, fallback to any leaf
        if (self.layout.firstLeafPane(0)) |pid| {
            self.active_pane = pid;
        } else {
            self.active_pane = 0;
        }
    }

    /// Toggle terminal: focus existing terminal, or open one. If already in terminal, go back.
    pub fn toggleTerminal(self: *Editor) void {
        // If currently in a terminal pane, focus the nearest non-terminal pane
        if (self.activePaneIsTerminal()) {
            var leaves: std.ArrayList(u8) = .empty;
            defer leaves.deinit(self.allocator);
            self.layout.collectLeaves(0, &leaves) catch return;
            for (leaves.items) |pid| {
                if (pid == self.active_pane) continue;
                if (pid < self.layout.panes.items.len) {
                    if (self.layout.panes.items[pid].content == .editor) {
                        self.focusPane(pid);
                        return;
                    }
                }
            }
            return;
        }

        // From an editor pane — always open a new bottom terminal.
        self.openTerminal();
    }

    /// Close the active pane's terminal (if it is one).
    pub fn closeActiveTerminal(self: *Editor) void {
        if (self.active_pane < self.layout.panes.items.len) {
            switch (self.layout.panes.items[self.active_pane].content) {
                .terminal => |idx| self.closeTerminal(idx),
                .editor => {},
            }
        }
    }

    // ---- Language / syntax theme operations ----

    /// Resolve the command used to start the LSP server for `lsp_language`.
    /// A `zide.register_lsp{ language, command }` entry from init.lua whose
    /// language matches (case-insensitive) overrides the default "zls" —
    /// e.g. a full path to the zls binary matching the active toolchain.
    /// First matching entry wins. Must be called after the Lua config loaded.
    pub fn lspServerCommand(self: *const Editor) []const u8 {
        for (self.lsp_configs.items) |cfg| {
            if (std.ascii.eqlIgnoreCase(cfg.language, self.lsp_language)) return cfg.command;
        }
        return "zls";
    }

    /// Find a registered language by file extension.
    /// The returned pointer stays valid for the editor's lifetime
    /// (each LanguageDef is its own heap allocation — appends never relocate).
    pub fn findLanguage(self: *const Editor, ext: []const u8) ?*const syntax.LanguageDef {
        for (self.languages.items) |lang| {
            if (lang.matchesExtension(ext)) return lang;
        }
        return null;
    }

    /// Get the resolved GUI syntax theme for a language (per-lang override or global).
    /// Case-insensitive: syn_theme_python.lua matches a language named "Python".
    pub fn syntaxThemeFor(self: *const Editor, lang_name: ?[]const u8) *const SyntaxTheme {
        if (lang_name) |name| {
            for (self.lang_syntax_overrides.items) |*ov| {
                if (std.ascii.eqlIgnoreCase(ov.name, name)) return &ov.gui_theme;
            }
        }
        return &self.syntax_theme;
    }

    /// Get the resolved TUI syntax theme for a language (per-lang override or global).
    /// Case-insensitive: syn_theme_python.lua matches a language named "Python".
    pub fn tuiSyntaxThemeFor(self: *const Editor, lang_name: ?[]const u8) *const TuiSyntaxTheme {
        if (lang_name) |name| {
            for (self.lang_syntax_overrides.items) |*ov| {
                if (std.ascii.eqlIgnoreCase(ov.name, name)) return &ov.tui_theme;
            }
        }
        return &self.tui_syntax_theme;
    }

    // ---- LSP integration ----

    /// Send didOpen notification if LSP is ready, the document has a file
    /// path, and its language is the one the server understands.
    pub fn lspNotifyOpen(self: *Editor, doc: *Document) void {
        const lsp_client = self.lsp orelse return;
        if (!lsp_client.isReady()) return;
        const path = doc.file_path orelse return;
        if (doc.lsp_opened) return;
        const lang = doc.language orelse return;
        if (!std.ascii.eqlIgnoreCase(lang.name, self.lsp_language)) return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        const lang_id: []const u8 = lang.name;
        const text = doc.buffer.slice(0, doc.buffer.byteLen());

        lsp_client.sendDidOpen(uri, lang_id, doc.lsp_version, text) catch return;
        doc.lsp_opened = true;
        doc.lsp_last_synced = doc.lsp_version;
        std.log.info("LSP didOpen: {s} (lang={s})", .{ uri, lang_id });
    }

    /// Send didClose notification if the document was opened with LSP.
    fn lspDidClose(self: *Editor, doc: *Document) void {
        const lsp_client = self.lsp orelse return;
        if (!doc.lsp_opened) return;
        const path = doc.file_path orelse return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        lsp_client.sendDidClose(uri) catch {};
        doc.lsp_opened = false;
    }

    /// Send didSave notification.
    fn lspDidSave(self: *Editor, doc: *Document) void {
        const lsp_client = self.lsp orelse return;
        if (!doc.lsp_opened) return;
        const path = doc.file_path orelse return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        lsp_client.sendDidSave(uri) catch {};
    }

    /// Sync dirty documents with the LSP server (send didChange for modified docs).
    /// Also sends didOpen for documents that were opened before the LSP finished initializing.
    pub fn syncLspDocuments(self: *Editor) void {
        const lsp_client = self.lsp orelse return;
        if (!lsp_client.isReady()) return;

        for (self.documents.items) |*doc| {
            // Send didOpen for docs that haven't been registered with LSP yet
            if (!doc.lsp_opened) {
                self.lspNotifyOpen(doc);
                continue; // didOpen includes the full text, so no didChange needed
            }

            if (doc.lsp_version == doc.lsp_last_synced) continue;

            const path = doc.file_path orelse continue;
            const uri = lsp_mod.pathToUri(self.allocator, path) catch continue;
            defer self.allocator.free(uri);

            const text = doc.buffer.slice(0, doc.buffer.byteLen());
            lsp_client.sendDidChange(uri, doc.lsp_version, text) catch continue;
            doc.lsp_last_synced = doc.lsp_version;
        }
    }

    /// Clear all completion items (frees memory).
    pub fn clearCompletionItems(self: *Editor) void {
        for (self.completion_items.items) |*item| {
            self.allocator.free(item.label);
            if (item.detail) |d| self.allocator.free(d);
            if (item.insert_text) |t| self.allocator.free(t);
        }
        self.completion_items.clearRetainingCapacity();
        self.completion_active = false;
        self.completion_selected = 0;
    }

    /// Add a completion item (called from LSP response handler).
    pub fn addCompletionItem(self: *Editor, label: []const u8, detail: ?[]const u8, insert_text: ?[]const u8) !void {
        try self.completion_items.append(self.allocator, .{
            .label = label,
            .detail = detail,
            .insert_text = insert_text,
        });
        self.completion_active = true;
    }

    /// Trigger LSP completion at the current cursor position.
    pub fn triggerCompletion(self: *Editor) void {
        const lsp_client = self.lsp orelse return;
        if (!lsp_client.isReady()) return;
        const doc = self.activeDoc();
        const path = doc.file_path orelse return;
        if (!doc.lsp_opened) return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        const cursor = doc.cursors.primary();
        const pos = doc.buffer.offsetToPos(cursor.offset);
        // LSP positions are UTF-16 code units, not bytes
        const utf16_col = lsp_mod.byteColToUtf16(doc.buffer.lineContent(pos.line), pos.col);

        _ = lsp_client.sendCompletion(uri, @intCast(pos.line), utf16_col) catch return;
    }

    /// Trigger LSP go-to-definition at the current cursor position.
    pub fn triggerGotoDefinition(self: *Editor) void {
        const lsp_client = self.lsp orelse return;
        if (!lsp_client.isReady()) return;
        const doc = self.activeDoc();
        const path = doc.file_path orelse return;
        if (!doc.lsp_opened) return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        const cursor = doc.cursors.primary();
        const pos = doc.buffer.offsetToPos(cursor.offset);
        // LSP positions are UTF-16 code units, not bytes
        const utf16_col = lsp_mod.byteColToUtf16(doc.buffer.lineContent(pos.line), pos.col);

        _ = lsp_client.sendGotoDefinition(uri, @intCast(pos.line), utf16_col) catch return;
    }

    /// Accept the currently selected completion item.
    /// Replaces the word prefix (characters before cursor back to word boundary) with the completion text.
    pub fn acceptCompletion(self: *Editor) void {
        if (!self.completion_active) return;
        if (self.completion_selected >= self.completion_items.items.len) {
            self.clearCompletionItems();
            return;
        }

        const item = self.completion_items.items[self.completion_selected];
        const text = item.insert_text orelse item.label;

        const doc = self.activeDoc();
        const cursor = doc.cursors.primary();
        // Prefix replacement must not be diverted into deleting a selection,
        // and the delete+insert pair should undo as one step.
        cursor.clearSelection();
        doc.history.beginGroup();
        defer doc.history.endGroup();

        // Find the start of the word prefix (scan back from cursor)
        var prefix_start = cursor.offset;
        while (prefix_start > 0) {
            const prev = doc.buffer.byteAt(prefix_start - 1) orelse break;
            if (isIdentChar(prev)) {
                prefix_start -= 1;
            } else {
                break;
            }
        }

        // Delete the prefix
        const prefix_len = cursor.offset - prefix_start;
        if (prefix_len > 0) {
            // Move cursor to start of prefix, then delete forward
            doc.cursors.primary().offset = prefix_start;
            doc.deleteForward(prefix_len) catch {};
        }

        // Insert completion text
        doc.insertAtCursor(text) catch {};

        self.clearCompletionItems();
    }

    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '@';
    }
};

// ---- Tests ----

test "editor init and basic operations" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();

    // Should start with one empty document
    try std.testing.expectEqual(@as(usize, 1), editor.docCount());
    try std.testing.expectEqual(@as(usize, 0), editor.activeDoc().buffer.byteLen());
}

test "editor command execution" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
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
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();

    try editor.activeDoc().loadText("hello");
    _ = editor.execCommand("insert_char", "X");
    try std.testing.expectEqualStrings("Xhello", editor.activeDoc().lineContent(0));
}

test "editor multiple documents" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
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

test "per-language syntax theme override resolution" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();

    const name = try allocator.dupe(u8, "python");
    var ov_gui = editor.syntax_theme;
    ov_gui.keyword = .{ .r = 1, .g = 2, .b = 3 };
    try editor.lang_syntax_overrides.append(allocator, .{
        .name = name,
        .gui_theme = ov_gui,
        .tui_theme = editor.tui_syntax_theme,
    });

    // Case-insensitive match (file syn_theme_python.lua vs language "Python")
    const resolved = editor.syntaxThemeFor("Python");
    try std.testing.expectEqual(@as(u8, 1), resolved.keyword.r);
    // Unknown language falls back to the global theme
    const fallback = editor.syntaxThemeFor("ruby");
    try std.testing.expectEqual(editor.syntax_theme.keyword.r, fallback.keyword.r);
}

test "lsp server command resolution" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();

    // No config registered: default
    try std.testing.expectEqualStrings("zls", editor.lspServerCommand());

    // Config for another language doesn't affect the zig server
    try editor.lsp_configs.append(allocator, .{
        .language = try allocator.dupe(u8, "Python"),
        .command = try allocator.dupe(u8, "pyright-langserver"),
    });
    try std.testing.expectEqualStrings("zls", editor.lspServerCommand());

    // Case-insensitive match on lsp_language overrides the command
    try editor.lsp_configs.append(allocator, .{
        .language = try allocator.dupe(u8, "Zig"),
        .command = try allocator.dupe(u8, "C:/tools/zls-0.16/zls.exe"),
    });
    try std.testing.expectEqualStrings("C:/tools/zls-0.16/zls.exe", editor.lspServerCommand());
}

test "editor undo via command" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();

    try editor.activeDoc().loadText("hello");
    _ = editor.execCommand("insert_char", "X");
    try std.testing.expectEqualStrings("Xhello", editor.activeDoc().lineContent(0));

    _ = editor.execCommand("undo", null);
    try std.testing.expectEqualStrings("hello", editor.activeDoc().lineContent(0));

    _ = editor.execCommand("redo", null);
    try std.testing.expectEqualStrings("Xhello", editor.activeDoc().lineContent(0));
}
