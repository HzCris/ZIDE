const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const CommandRegistry = @import("commands.zig").CommandRegistry;
const registerBuiltins = @import("commands.zig").registerBuiltins;
const SystemClipboard = @import("clipboard.zig").SystemClipboard;
const fileicons = @import("fileicons.zig");
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
pub const lua_api = @import("lua_api.zig");
const zlua = @import("zlua");

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
    /// Start the LSP client at launch (off = no language server process;
    /// takes effect at the next launch).
    lsp_enabled: bool = true,
    /// Render syntax colors (off = plain-text editor look, instant).
    syntax_highlighting: bool = true,
    /// Color file tree rows by git status (off = no git subprocesses).
    filetree_git_colors: bool = true,
    /// Select the active file in the tree whenever the active document
    /// changes (tab switch, open) — VS Code's auto-reveal. GUI-driven.
    filetree_auto_reveal: bool = true,
    /// Nerdfont file icons in the TUI tree rows (off by default — the
    /// terminal font must be a patched Nerd Font for the glyphs to show).
    tui_filetree_icons: bool = false,
    /// GUI tree row font size in points; rows and icons scale together.
    /// 0 = the theme's UI font size.
    filetree_font_size: f32 = 0,
    /// GUI tree icon size as a percentage of the row font (50-200).
    filetree_icon_scale: u16 = 90,
    /// Icon overrides from `zide.set_icon` (lowercase basename/ext keys,
    /// owned) — consulted by both frontends before the built-in tables.
    icon_overrides: fileicons.OverrideMap = .empty,
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

    /// Lua state for extension callbacks (set by lua_settings.registerApi;
    /// null in tests that don't create one). Owned by main.zig and must
    /// outlive the editor — Editor.deinit releases refs into it.
    lua: ?*zlua.Lua = null,
    /// Lua registry refs of event handlers per event (zide.on).
    lua_event_refs: lua_api.EventRefs = lua_api.EventRefs.initFill(.empty),
    /// Recursion guard for event firing (e.g. a save handler that saves).
    lua_event_depth: u8 = 0,
    /// Shared state for zide.spawn worker threads (created on first use;
    /// refcounted teardown lets detached workers outlive the editor).
    lua_spawn: ?*lua_api.SpawnState = null,
    /// Wake callback fired when a spawn result lands (TUI sets this like
    /// terminal_wake_fn; the GUI polls every frame and leaves it null).
    lua_wake_fn: ?*const fn () void = null,

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
    /// Rel-path marked for a move via 'x' (owned); 'p' pastes it into the
    /// selected folder.
    filetree_move_src: ?[]u8 = null,
    /// All marked sources for a bulk 'x' move (includes the first; the
    /// single `filetree_move_src` stays as the pending flag + display).
    filetree_move_srcs: std.ArrayList([]u8) = .empty,
    /// File clipboard (tree Ctrl+C/X/V): root-relative paths + whether
    /// paste moves (cut) or copies. Cleared when the root changes.
    filetree_clip_paths: std.ArrayList([]u8) = .empty,
    filetree_clip_cut: bool = false,

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
        /// Save requested but the file changed on disk since load —
        /// user picks overwrite / reload / cancel (resolveOverwrite).
        confirm_overwrite,
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
        // Register built-in languages (heap-allocated: see `languages` doc)
        const zig_lang = try allocator.create(syntax.LanguageDef);
        zig_lang.* = syntax.lang_zig;
        errdefer allocator.destroy(zig_lang);
        try editor.languages.append(allocator, zig_lang);
        const md_lang = try allocator.create(syntax.LanguageDef);
        md_lang.* = syntax.lang_markdown;
        errdefer allocator.destroy(md_lang);
        try editor.languages.append(allocator, md_lang);
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
        // Release Lua refs first: touches the command registry and needs
        // the (caller-owned, still-alive) Lua state.
        lua_api.deinitLua(self);
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
        if (self.filetree_move_src) |src| self.allocator.free(src);
        for (self.filetree_move_srcs.items) |p| self.allocator.free(p);
        self.filetree_move_srcs.deinit(self.allocator);
        for (self.filetree_clip_paths.items) |p| self.allocator.free(p);
        self.filetree_clip_paths.deinit(self.allocator);
        var ov_it = self.icon_overrides.keyIterator();
        while (ov_it.next()) |k| self.allocator.free(k.*);
        self.icon_overrides.deinit(self.allocator);
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
        lua_api.fireEvent(self, .open, active.file_path);
        return active;
    }

    /// Open `path` into the current (startup-empty) document — the CLI
    /// first-file / session-restore path that bypasses openFile. Keeps
    /// the post-open bookkeeping (language detection, LSP notify,
    /// extension event) in one place so bypass sites can't drift.
    pub fn openIntoActive(self: *Editor, path: []const u8) !void {
        const doc = self.activeDoc();
        try doc.open(self.io, path);
        doc.detectLanguage(self);
        self.lspNotifyOpen(doc);
        lua_api.fireEvent(self, .open, doc.file_path);
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
            self.filetree.?.git_enabled = self.filetree_git_colors;
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

    /// Mark the selected entry for a move (tree 'x'). 'p' pastes it into
    /// the selected folder; Escape cancels.
    pub fn startFiletreeMove(self: *Editor) void {
        const ft = self.ensureFiletree() orelse return;
        const paths = ft.selectionRelPaths(self.allocator) catch return;
        if (paths.len == 0) {
            self.allocator.free(paths);
            self.status_message = "File tree: nothing selected";
            return;
        }
        self.cancelFiletreeMove();
        self.filetree_move_src = self.allocator.dupe(u8, paths[0]) catch {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
            return;
        };
        self.filetree_move_srcs.appendSlice(self.allocator, paths) catch {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
            self.cancelFiletreeMove();
            return;
        };
        self.allocator.free(paths); // container only — the strings moved into the list
        const n = self.filetree_move_srcs.items.len;
        const msg = if (n > 1)
            std.fmt.bufPrint(&self.status_buf, "Move: {d} items — select the target folder, press p", .{n}) catch "Move: press p on the target folder"
        else
            std.fmt.bufPrint(&self.status_buf, "Move: {s} — select the target folder, press p", .{std.fs.path.basenamePosix(self.filetree_move_src.?)}) catch "Move: press p on the target folder";
        self.status_message = msg;
    }

    /// Drop a pending 'x' move mark.
    pub fn cancelFiletreeMove(self: *Editor) void {
        if (self.filetree_move_src) |old| self.allocator.free(old);
        self.filetree_move_src = null;
        for (self.filetree_move_srcs.items) |p| self.allocator.free(p);
        self.filetree_move_srcs.clearRetainingCapacity();
    }

    /// Apply a pending 'x' move (tree 'p'): target = the selected folder,
    /// or the parent of a selected file.
    pub fn applyFiletreeMove(self: *Editor) void {
        const ft = self.ensureFiletree() orelse return;
        const src = self.filetree_move_src orelse {
            self.status_message = "File tree: nothing marked — press x on an entry first";
            return;
        };
        const dest_idx = ft.opTargetDir();
        if (self.filetree_move_srcs.items.len > 1) {
            self.filetreeMoveManyTo(self.filetree_move_srcs.items, dest_idx);
            self.cancelFiletreeMove();
        } else {
            self.filetreeMoveTo(src, dest_idx);
        }
    }

    /// Bulk form of filetreeMoveTo: move every path in `srcs` into
    /// `dest_idx`, refreshing once at the end. Individual failures are
    /// counted rather than aborting the batch.
    pub fn filetreeMoveManyTo(self: *Editor, srcs: []const []u8, dest_idx: u32) void {
        const ft = self.ensureFiletree() orelse return;
        var ok: usize = 0;
        var failed: usize = 0;
        var skip: SkipNote = .{};
        for (srcs) |src| {
            const new_rel = ft.moveRelTo(self.allocator, src, dest_idx) catch |err| {
                failed += 1;
                skip.record(src, err);
                continue;
            };
            self.fixupDocPathsAfterRename(ft, src, new_rel);
            self.allocator.free(new_rel);
            ok += 1;
        }
        ft.clearMulti();
        ft.refresh() catch {};
        ft.gitRefresh();
        self.fileOpBulkStatus("Moved", ok, failed, &skip);
    }

    /// Move `src_rel` into the directory node `dest_idx` — shared by the
    /// x/p keys (both frontends) and GUI drag & drop. `src_rel` may alias
    /// `filetree_move_src` or a node's rel_path: it is only read before
    /// the tree refresh, and the mark is freed last.
    pub fn filetreeMoveTo(self: *Editor, src_rel: []const u8, dest_idx: u32) void {
        const ft = self.ensureFiletree() orelse return;
        const src_idx = ft.findByPath(src_rel) orelse {
            self.status_message = "Move failed: entry no longer exists";
            self.cancelFiletreeMove();
            return;
        };
        const new_rel = ft.moveEntry(self.allocator, src_idx, dest_idx) catch |err| {
            self.status_message = switch (err) {
                error.InvalidMove => "Move: invalid target (same place, or inside the moved entry)",
                error.PathAlreadyExists => "Move failed: that name already exists in the target",
                else => blk: {
                    const msg = std.fmt.bufPrint(&self.status_buf, "Move failed: {s}", .{@errorName(err)}) catch "Move failed";
                    break :blk msg;
                },
            };
            return; // keep the mark — the user can pick another target
        };
        defer self.allocator.free(new_rel);
        self.fixupDocPathsAfterRename(ft, src_rel, new_rel);
        ft.refresh() catch {};
        ft.gitRefresh();
        _ = ft.expandToPath(new_rel) catch null;
        const msg = std.fmt.bufPrint(&self.status_buf, "Moved to {s}", .{new_rel}) catch "Moved";
        self.status_message = msg;
        self.cancelFiletreeMove();
    }

    /// Register (or replace) an icon override from `zide.set_icon`.
    /// `key` is an extension ("zig") or exact basename ("Makefile",
    /// "src"), matched case-insensitively.
    pub fn setIconOverride(self: *Editor, key: []const u8, kind: fileicons.IconKind, color: ?fileicons.Rgb) !void {
        if (key.len == 0 or key.len > 64) return error.InvalidName;
        const lower = try self.allocator.alloc(u8, key.len);
        errdefer self.allocator.free(lower);
        for (key, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        const gop = try self.icon_overrides.getOrPut(self.allocator, lower);
        if (gop.found_existing) self.allocator.free(lower);
        gop.value_ptr.* = .{ .kind = kind, .color = color };
    }

    /// Icon for a tree entry: Lua overrides layered over the built-ins.
    pub fn filetreeIconFor(self: *const Editor, name: []const u8, is_dir: bool) fileicons.FileIcon {
        return fileicons.iconForWithOverrides(&self.icon_overrides, name, is_dir);
    }

    /// Fill the file clipboard from the current tree selection.
    pub fn filetreeClipCapture(self: *Editor, cut: bool) void {
        const ft = self.ensureFiletree() orelse return;
        const paths = ft.selectionRelPaths(self.allocator) catch return;
        if (paths.len == 0) {
            self.allocator.free(paths);
            self.status_message = "File tree: nothing selected";
            return;
        }
        self.filetreeClipClear();
        self.filetree_clip_paths.appendSlice(self.allocator, paths) catch {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
            return;
        };
        self.allocator.free(paths); // container only — strings moved into the list
        self.filetree_clip_cut = cut;
        const n = self.filetree_clip_paths.items.len;
        const verb: []const u8 = if (cut) "Cut" else "Copied";
        const plural: []const u8 = if (n == 1) "" else "s";
        const msg = std.fmt.bufPrint(&self.status_buf, "{s} {d} item{s} — Ctrl+V on a folder pastes", .{ verb, n, plural }) catch "";
        self.status_message = msg;
    }

    pub fn filetreeClipClear(self: *Editor) void {
        for (self.filetree_clip_paths.items) |p| self.allocator.free(p);
        self.filetree_clip_paths.clearRetainingCapacity();
        self.filetree_clip_cut = false;
    }

    /// Whether `rel` is in the cut set (the GUI dims those rows).
    pub fn filetreeClipContains(self: *const Editor, rel: []const u8) bool {
        for (self.filetree_clip_paths.items) |p| {
            if (std.mem.eql(u8, p, rel)) return true;
        }
        return false;
    }

    /// Paste the file clipboard into the selected folder (or a selected
    /// file's parent): cut moves, copy copies recursively. No-clobber per
    /// entry; failures are counted and the batch continues.
    pub fn filetreePaste(self: *Editor) void {
        const ft = self.ensureFiletree() orelse return;
        if (self.filetree_clip_paths.items.len == 0) {
            self.status_message = "File clipboard is empty — Ctrl+C/X in the tree first";
            return;
        }
        const dest_idx = ft.opTargetDir();
        var ok: usize = 0;
        var failed: usize = 0;
        var skip: SkipNote = .{};
        var last_new: ?[]u8 = null;
        defer if (last_new) |p| self.allocator.free(p);
        for (self.filetree_clip_paths.items) |src| {
            const new_rel = blk: {
                if (self.filetree_clip_cut) {
                    break :blk ft.moveRelTo(self.allocator, src, dest_idx) catch |err| {
                        failed += 1;
                        skip.record(src, err);
                        continue;
                    };
                }
                break :blk ft.copyEntryTo(self.allocator, src, dest_idx) catch |err| {
                    failed += 1;
                    skip.record(src, err);
                    continue;
                };
            };
            if (self.filetree_clip_cut) self.fixupDocPathsAfterRename(ft, src, new_rel);
            if (last_new) |p| self.allocator.free(p);
            last_new = new_rel;
            ok += 1;
        }
        const was_cut = self.filetree_clip_cut;
        if (was_cut) self.filetreeClipClear();
        ft.clearMulti();
        ft.refresh() catch {};
        ft.gitRefresh();
        if (last_new) |p| _ = ft.expandToPath(p) catch null;
        self.fileOpBulkStatus(if (was_cut) "Moved" else "Pasted", ok, failed, &skip);
    }

    /// OS drag & drop import: copy `abs` into directory node `dest_idx`,
    /// refresh, and reveal the result.
    pub fn filetreeImportAbs(self: *Editor, abs: []const u8, dest_idx: u32) void {
        const ft = self.ensureFiletree() orelse return;
        const new_rel = ft.importAbsPath(self.allocator, abs, dest_idx) catch |err| {
            const msg = std.fmt.bufPrint(&self.status_buf, "Import failed — {s}: {s}", .{ std.fs.path.basename(abs), fileOpSkipReason(err) }) catch "Import failed";
            self.status_message = msg;
            return;
        };
        defer self.allocator.free(new_rel);
        ft.refresh() catch {};
        ft.gitRefresh();
        _ = ft.expandToPath(new_rel) catch null;
        const msg = std.fmt.bufPrint(&self.status_buf, "Imported {s}", .{new_rel}) catch "Imported";
        self.status_message = msg;
    }

    /// Call after any successful save so the file tree stays current
    /// (git colors always; full rescan when Save As created a new file)
    /// and extensions hear about it. The GUI's native-dialog save path
    /// bypasses execAction("save"), so every save site must call this
    /// rather than relying on the action hook. `saved` is the document
    /// that was written — pass null only for bulk saves that fire the
    /// extension event per document themselves (autoSaveAll).
    pub fn noteFileSaved(self: *Editor, new_file: bool, saved: ?*const Document) void {
        if (self.filetree) |*ft| {
            if (new_file) ft.refresh() catch {};
            ft.gitRefresh();
        }
        if (saved) |d| lua_api.fireEvent(self, .save, d.file_path);
    }

    /// Change the file tree root (settings dialog, root-up). Empty/blank
    /// path resets to the current directory. On failure the previous root
    /// is restored and the tree brought back — a typo in the dialog must
    /// not nuke the panel. Does NOT persist to init.lua; callers decide.
    pub fn setFiletreeRoot(self: *Editor, path: []const u8) bool {
        // Root-relative state can't survive a root swap.
        self.filetreeClipClear();
        self.cancelFiletreeMove();
        const trimmed = std.mem.trim(u8, path, " \t");
        const new_root: ?[]const u8 = if (trimmed.len == 0)
            null
        else
            self.allocator.dupe(u8, trimmed) catch return false;

        const old_root = self.filetree_root;
        self.filetree_root = new_root;
        if (self.filetree) |*ft| ft.deinit();
        self.filetree = null;
        self.filetree_visible = true;
        if (self.ensureFiletree() != null) {
            if (old_root) |o| self.allocator.free(o);
            const msg = std.fmt.bufPrint(&self.status_buf, "File tree root: {s}", .{self.filetree.?.root_path}) catch "";
            self.status_message = msg;
            return true;
        }
        // Failed — keep the failure message visible across the restore
        // (the restore's ensure would otherwise overwrite status_buf).
        var fail_buf: [128]u8 = undefined;
        const fail_len = @min(self.status_message.len, fail_buf.len);
        @memcpy(fail_buf[0..fail_len], self.status_message[0..fail_len]);
        if (self.filetree_root) |bad| self.allocator.free(bad);
        self.filetree_root = old_root;
        self.filetree_visible = true;
        _ = self.ensureFiletree();
        @memcpy(self.status_buf[0..fail_len], fail_buf[0..fail_len]);
        self.status_message = self.status_buf[0..fail_len];
        return false;
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
        // Copy out — setFiletreeRoot deinits the tree `parent` points into
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = @min(parent.len, buf.len);
        @memcpy(buf[0..n], parent[0..n]);
        _ = self.setFiletreeRoot(buf[0..n]);
    }

    /// Expand the tree to `path` (absolute, or relative to the tree root)
    /// and select it — no focus or visibility change. Returns false when
    /// the path is outside the root or doesn't exist in it.
    pub fn filetreeRevealPath(self: *Editor, path: []const u8) bool {
        const ft = if (self.filetree) |*f| f else return false;
        var rel_owned: ?[]u8 = ft.relFromAbs(self.allocator, path) catch null;
        if (rel_owned == null and !std.fs.path.isAbsolute(path)) {
            // CLI-opened relative paths: try as-is, the default root is cwd.
            const r = self.allocator.dupe(u8, path) catch return false;
            filetree_mod.normalizeSeps(r);
            rel_owned = r;
        }
        const rel = rel_owned orelse return false;
        defer self.allocator.free(rel);
        return (ft.expandToPath(rel) catch null) != null;
    }

    /// Begin a file-tree prompt (mode → .filetree_prompt). For .create the
    /// target is the selected directory (or the parent of a selected file);
    /// rename/delete require a non-root selection.
    pub fn startFiletreePrompt(self: *Editor, kind: FiletreePromptKind) void {
        const ft = if (self.filetree) |*f| f else return;
        var target_idx: u32 = 0;
        switch (kind) {
            .create => {
                target_idx = ft.opTargetDir();
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
                if (ft.multi.count() > 0) {
                    // Bulk delete of the multi-selection (ancestors cover
                    // their selected descendants via selectionRelPaths).
                    const paths = ft.selectionRelPaths(self.allocator) catch return;
                    defer {
                        for (paths) |p| self.allocator.free(p);
                        self.allocator.free(paths);
                    }
                    var ok: usize = 0;
                    var failed: usize = 0;
                    var skip: SkipNote = .{};
                    for (paths) |p| {
                        const idx = ft.findByPath(p) orelse {
                            failed += 1;
                            skip.record(p, error.FileNotFound);
                            continue;
                        };
                        ft.deleteEntry(idx) catch |err| {
                            failed += 1;
                            skip.record(p, err);
                            continue;
                        };
                        ok += 1;
                    }
                    ft.clearMulti();
                    ft.refresh() catch {};
                    ft.gitRefresh();
                    self.fileOpBulkStatus("Deleted", ok, failed, &skip);
                    return;
                }
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

    /// Human-readable reason for a skipped bulk file operation.
    fn fileOpSkipReason(err: anyerror) []const u8 {
        return switch (err) {
            error.PathAlreadyExists => "name already exists in the target",
            error.InvalidMove, error.InvalidCopy => "invalid target (same place, or inside the entry)",
            error.FileNotFound => "entry no longer exists",
            error.AccessDenied => "access denied",
            else => @errorName(err),
        };
    }

    /// Tracks the last skip in a bulk loop so the status line can say
    /// WHICH entry was skipped and WHY, not just a count.
    const SkipNote = struct {
        name_buf: [128]u8 = undefined,
        name_len: usize = 0,
        reason: []const u8 = "",

        fn record(self: *SkipNote, src_rel: []const u8, err: anyerror) void {
            const base = std.fs.path.basenamePosix(src_rel);
            self.name_len = @min(base.len, self.name_buf.len);
            @memcpy(self.name_buf[0..self.name_len], base[0..self.name_len]);
            self.reason = fileOpSkipReason(err);
        }

        fn name(self: *const SkipNote) []const u8 {
            return self.name_buf[0..self.name_len];
        }
    };

    /// Compose the "{Verb} N item(s)" status with skip details appended.
    fn fileOpBulkStatus(self: *Editor, verb: []const u8, ok: usize, failed: usize, skip: *const SkipNote) void {
        const plural: []const u8 = if (ok == 1) "" else "s";
        const msg = if (failed == 0)
            std.fmt.bufPrint(&self.status_buf, "{s} {d} item{s}", .{ verb, ok, plural }) catch verb
        else if (failed == 1)
            std.fmt.bufPrint(&self.status_buf, "{s} {d} item{s} — skipped {s}: {s}", .{ verb, ok, plural, skip.name(), skip.reason }) catch verb
        else
            std.fmt.bufPrint(&self.status_buf, "{s} {d} item{s} — {d} skipped (last {s}: {s})", .{ verb, ok, plural, failed, skip.name(), skip.reason }) catch verb;
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

    /// Deliver finished zide.spawn results to their Lua callbacks.
    /// Called by both frontends' main loops.
    pub fn pumpLuaJobs(self: *Editor) void {
        lua_api.pumpLuaJobs(self);
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
            // Disk changed since load/save (external edit or delete) —
            // don't clobber it silently; let the user decide.
            if (doc.file_path != null and doc.checkExternalChange(self.io)) {
                doc.external_changed = true;
                self.mode = .confirm_overwrite;
                return true;
            }
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
            self.noteFileSaved(false, doc);
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

    /// Poll open documents for external changes (frontends call this on a
    /// ~1.5s timer, like the file tree's probe). Clean buffers reload in
    /// place; dirty buffers are flagged so save prompts; vanished files are
    /// flagged AND marked dirty so quit protects the surviving buffer.
    pub fn pollExternalChanges(self: *Editor) void {
        for (self.documents.items) |*doc| {
            const path = doc.file_path orelse continue;
            if (doc.external_changed) continue; // flagged; waiting on the user
            if (doc.disk_mtime == null) continue; // no stamp to compare
            const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch {
                doc.external_changed = true;
                doc.dirty = true;
                const msg = std.fmt.bufPrint(&self.status_buf, "{s}: file deleted on disk (buffer kept)", .{doc.display_name}) catch "File deleted on disk (buffer kept)";
                self.status_message = msg;
                continue;
            };
            if (st.mtime.nanoseconds == doc.disk_mtime.?) continue;
            if (doc.dirty) {
                doc.external_changed = true;
                const msg = std.fmt.bufPrint(&self.status_buf, "{s} changed on disk — saving will ask", .{doc.display_name}) catch "File changed on disk";
                self.status_message = msg;
            } else {
                doc.reloadFromDisk(self.io) catch {
                    doc.external_changed = true;
                    continue;
                };
                const msg = std.fmt.bufPrint(&self.status_buf, "{s} reloaded (changed on disk)", .{doc.display_name}) catch "Reloaded (changed on disk)";
                self.status_message = msg;
            }
        }
    }

    pub const OverwriteChoice = enum { overwrite, reload, cancel };

    /// Resolve the .confirm_overwrite prompt for the active document.
    pub fn resolveOverwrite(self: *Editor, choice: OverwriteChoice) void {
        const doc = self.activeDoc();
        self.mode = .normal;
        switch (choice) {
            .overwrite => {
                doc.save(self.io) catch |err| {
                    const msg = std.fmt.bufPrint(&self.status_buf, "Save failed: {s}", .{@errorName(err)}) catch "Save failed";
                    self.status_message = msg;
                    return;
                };
                self.lspDidSave(doc);
                self.noteFileSaved(false, doc);
                const msg = std.fmt.bufPrint(&self.status_buf, "Saved {s} (overwrote external change)", .{doc.display_name}) catch "Saved";
                self.status_message = msg;
            },
            .reload => {
                doc.reloadFromDisk(self.io) catch |err| {
                    const msg = std.fmt.bufPrint(&self.status_buf, "Reload failed: {s}", .{@errorName(err)}) catch "Reload failed";
                    self.status_message = msg;
                    return;
                };
                const msg = std.fmt.bufPrint(&self.status_buf, "Reloaded {s} from disk", .{doc.display_name}) catch "Reloaded";
                self.status_message = msg;
            },
            .cancel => {
                self.status_message = "Save cancelled (file changed on disk)";
            },
        }
    }

    /// Auto-save all dirty documents that have a file path.
    /// Returns the number of documents saved.
    pub fn autoSaveAll(self: *Editor) usize {
        var saved: usize = 0;
        for (self.documents.items) |*doc| {
            if (doc.dirty and doc.file_path != null) {
                // Never auto-clobber an external change — a timer can't
                // ask; flag it and let the explicit save path prompt.
                if (doc.external_changed or doc.checkExternalChange(self.io)) {
                    doc.external_changed = true;
                    continue;
                }
                doc.save(self.io) catch continue;
                saved += 1;
                // Per-document extension event; the file tree note below
                // runs once for the whole batch (it shells out to git).
                lua_api.fireEvent(self, .save, doc.file_path);
            }
        }
        if (saved > 0) {
            self.noteFileSaved(false, null);
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
                    self.openIntoActive(file_path) catch continue;
                    doc = self.activeDoc();
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

test "editor external-change poll and save guard" {
    const t = std.testing;
    const path = ".zig-cache/zide-test-editor-external.txt";
    {
        const f = try std.Io.Dir.cwd().createFile(t.io, path, .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "one\n");
    }
    defer std.Io.Dir.cwd().deleteFile(t.io, path) catch {};

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = try editor.openFile(path);

    // Rewrite on disk until the mtime visibly moves (coarse Windows ticks)
    var attempts: usize = 0;
    while (!doc.checkExternalChange(t.io) and attempts < 10_000) : (attempts += 1) {
        const f = std.Io.Dir.cwd().createFile(t.io, path, .{}) catch break;
        defer f.close(t.io);
        f.writeStreamingAll(t.io, "two\n") catch break;
    }

    // Clean buffer: poll reloads in place
    editor.pollExternalChanges();
    try t.expectEqualStrings("two\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(!doc.external_changed);

    // Dirty buffer: poll flags instead of reloading
    try doc.insertAtCursor("local ");
    attempts = 0;
    while (!doc.checkExternalChange(t.io) and attempts < 10_000) : (attempts += 1) {
        const f = std.Io.Dir.cwd().createFile(t.io, path, .{}) catch break;
        defer f.close(t.io);
        f.writeStreamingAll(t.io, "three\n") catch break;
    }
    editor.pollExternalChanges();
    try t.expect(doc.external_changed);
    try t.expectEqualStrings("local two\n", doc.buffer.slice(0, doc.buffer.byteLen()));

    // Save now prompts instead of clobbering
    try t.expect(editor.execAction("save"));
    try t.expectEqual(Editor.Mode.confirm_overwrite, editor.mode);

    // Reload choice takes the disk content ("three\n" survived the blocked
    // save) and returns to normal mode
    editor.resolveOverwrite(.reload);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqualStrings("three\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(!doc.dirty);
    try t.expect(!doc.external_changed);

    // Overwrite choice: dirty the buffer, change disk again, save over it
    try doc.insertAtCursor("mine ");
    attempts = 0;
    while (!doc.checkExternalChange(t.io) and attempts < 10_000) : (attempts += 1) {
        const f = std.Io.Dir.cwd().createFile(t.io, path, .{}) catch break;
        defer f.close(t.io);
        f.writeStreamingAll(t.io, "four\n") catch break;
    }
    try t.expect(editor.execAction("save"));
    try t.expectEqual(Editor.Mode.confirm_overwrite, editor.mode);
    editor.resolveOverwrite(.overwrite);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(!doc.dirty);
    try t.expect(!doc.checkExternalChange(t.io)); // mtime re-stamped
}
