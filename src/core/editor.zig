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
pub const search_mod = @import("search.zig");
pub const text_file = @import("text_file.zig");
const text_input = @import("text_input.zig");
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

    /// Fuzzy file finder (quick_open) — see finderOpen. Typed filter:
    finder_buf: [256]u8 = undefined,
    finder_buf_len: usize = 0,
    /// Selected row in finder_matches.
    finder_selected: usize = 0,
    /// Workspace-relative file paths (owned), snapshot taken by finderOpen.
    finder_files: std.ArrayList([]u8) = .empty,
    /// Indices into finder_files matching the filter (basename hits first).
    finder_matches: std.ArrayList(u32) = .empty,
    /// Owned snapshot of the workspace root ("" = cwd) paths join against.
    finder_root: ?[]u8 = null,
    /// A transient preview document sits at the end of `documents`.
    finder_preview_appended: bool = false,
    /// Active doc index to restore when the finder is cancelled.
    finder_prev_active: usize = 0,

    /// Workspace search & replace panel state/engine (see search.zig).
    search: search_mod.SearchPanel,
    /// The docked results panel is shown.
    search_visible: bool = false,
    /// Keyboard focus is on the panel (frontends route keys to it, like
    /// filetree_focused).
    search_focused: bool = false,
    /// Go to line input buffer.
    goto_buf: [32]u8 = undefined,
    goto_buf_len: usize = 0,
    /// Saved cursor offset when entering find mode (for incremental search).
    find_origin: usize = 0,
    find_case_sensitive: bool = true,
    find_whole_word: bool = false,
    encoding_choices: std.ArrayList(EncodingChoice) = .empty,
    encoding_action: EncodingAction = .choose,
    encoding_doc_id: ?u64 = null,
    encoding_path: ?[]u8 = null,
    encoding_selected: usize = 0,
    reopen_encoding: ?text_file.TextEncoding = null,
    reopen_after_save: bool = false,
    save_as_id: ?u64 = null,
    save_as_format: ?text_file.TextFormat = null,
    pending_save_id: ?u64 = null,
    pending_save_path: ?[]u8 = null,
    pending_save_format: ?text_file.TextFormat = null,
    pending_save_overwrite: bool = false,
    pending_destination_stamp: ?text_file.Stamp = null,
    save_destination_conflict: bool = false,
    close_after_save_id: ?u64 = null,
    finder_skipped: usize = 0,

    /// Word wrap (soft-wrap long lines in display).
    word_wrap: bool = true,
    /// Text area width in columns (set by TUI frontend for visual-row movement).
    text_width: u16 = 80,
    /// Auto-close brackets/quotes when typing opening character.
    auto_close_brackets: bool = true,
    /// Auto-save dirty documents after a period of inactivity.
    auto_save: bool = false,
    renderer_active: @import("renderer_settings.zig").Mode = .auto,
    renderer_preference: @import("renderer_settings.zig").Mode = .auto,
    renderer_is_software: bool = false,
    deadlines: @import("deadlines.zig").Deadlines = .{},
    recovery_enabled: bool = true,
    recovery: ?@import("recovery.zig").Manager = null,
    recovery_offer_pending: bool = false,
    recovery_reported_error: ?anyerror = null,
    /// Auto-save delay in milliseconds (default 5 seconds).
    auto_save_interval_ms: u32 = 5000,
    /// Minimum digit width for line number gutter (default 3).
    gutter_min_digits: usize = 3,
    /// Left-click clears secondary cursors (default true).
    click_clears_cursors: bool = true,
    /// Save open files + cursors on quit and restore them on a bare launch.
    session_persistence: bool = false,
    /// Run language servers (off = none are started and running ones are
    /// stopped on the next frame — takes effect immediately).
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

    /// Editor windows — each owns a split-pane layout tree and its focused
    /// pane. `windows.items[0]` is the primary window (created in init,
    /// never removed); the GUI may add secondaries (newWindow) and the TUI
    /// only ever renders window 0. Entries are heap-allocated so pointers
    /// (and `&win.open`, handed to dvui) stay stable while the list grows.
    ///
    /// Invariants: I1 `windows.items.len >= 1`, item 0 is the primary;
    /// I2 `active_window < windows.items.len`; I3 each window's
    /// `active_pane` is a live leaf of its layout; I4 `active_doc_idx`
    /// mirrors the active window's active editor pane; I5 every `.editor`
    /// index in every window is `< documents.items.len`; I6 a terminal index
    /// is shown by at most one live pane across all windows (terminals are
    /// moved, never copied); I7 window ids are monotonic and never reused.
    windows: std.ArrayList(*EditorWindow) = .empty,
    /// Index into `windows` of the window that has keyboard focus.
    active_window: usize = 0,
    /// Next `EditorWindow.id` (0 is the primary).
    next_window_id: u32 = 1,
    /// The frontend can host more than one OS window (the GUI sets it from
    /// its backend; false in the TUI and in tests → window commands fall
    /// back to splits).
    multi_window_supported: bool = false,
    /// Cap on secondary windows (1 primary + 4 = dvui's SDL window limit).
    max_secondary_windows: usize = 4,
    /// Secondary windows get a menu bar + status bar (true) or are bare
    /// pane containers (false). File tree and search panel always stay in
    /// the primary window.
    secondary_window_chrome: bool = true,

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
    /// Bumped by every change to the GUI theme, colors or mono font (menu,
    /// palette, Lua zide.set). Each GUI window re-applies its dvui theme
    /// when its applied revision differs — dvui themes are per window.
    theme_revision: u32 = 1,

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

    /// Running language servers (heap-allocated: pointer-stable while the
    /// list grows; each client also owns a deep copy of its config). Started
    /// lazily by lspNotifyOpen / syncLspDocuments, retired by lspTick.
    lsp_clients: std.ArrayList(*lsp_mod.LspClient) = .empty,
    /// Wake callback copied into each client's reader thread (the TUI sets
    /// it before its loop, like terminal_wake_fn; the GUI polls every frame).
    lsp_wake_fn: ?*const fn () void = null,
    /// True while extensions/*.lua are being (re)loaded — register_lsp tags
    /// configs so reload_extensions can drop and re-add exactly those.
    loading_extensions: bool = false,

    /// Lua state for extension callbacks (set by lua_settings.registerApi;
    /// null in tests that don't create one). Owned by main.zig and must
    /// outlive the editor — Editor.deinit releases refs into it.
    lua: ?*zlua.Lua = null,
    /// Registered event handlers per event (zide.on): registry ref plus an
    /// optional language filter.
    lua_event_handlers: lua_api.EventHandlers = lua_api.EventHandlers.initFill(.empty),
    /// Recursion guard for event firing (e.g. a save handler that saves).
    lua_event_depth: u8 = 0,
    /// Shared state for zide.spawn worker threads (created on first use;
    /// refcounted teardown lets detached workers outlive the editor).
    jobs: @import("jobs.zig").Manager,
    problems: @import("diagnostics.zig").Store,
    lsp_tools: @import("lsp_tools.zig").State = .{},
    tasks: @import("tasks.zig").State = .{},
    tool_panel: @import("tool_panel.zig").State = .{},
    git: @import("git.zig").State = .{},
    dap: @import("dap.zig").State = .{},
    editorconfig_enabled: bool = true,
    project_formatting: @import("editorconfig.zig").Cache,
    lua_jobs: std.ArrayList(lua_api.BackgroundJob) = .empty,
    /// Wake callback fired when a spawn result lands (TUI sets this like
    /// terminal_wake_fn; the GUI polls every frame and leaves it null).
    lua_wake_fn: ?*const fn () void = null,

    /// Completion items from LSP.
    completion_items: std.ArrayList(EditorCompletionItem),
    /// Whether the completion popup is active.
    completion_active: bool = false,
    /// Currently selected completion item index.
    completion_selected: usize = 0,
    /// Document the completion request was made for — acceptance is refused
    /// (and the list dropped) when the active document changed meanwhile.
    completion_doc_idx: usize = 0,
    completion_context: ?CompletionContext = null,
    completion_generation: u64 = 0,
    /// Document the .confirm_overwrite prompt was opened for (tab clicks and
    /// window switches must not redirect Overwrite/Reload to another file).
    confirm_overwrite_doc: usize = 0,
    /// Document the .confirm_close prompt (closing a dirty tab) was opened
    /// for — resolved by index, bounds-checked when answered.
    confirm_close_doc: usize = 0,
    /// Window whose Settings dialog is open (an EditorWindow.id): the dialog
    /// stays in the window it was opened from instead of following focus.
    settings_window_id: u32 = 0,

    /// Registered language servers: the built-in zls seed plus every
    /// zide.register_lsp call. Newest registration wins per language
    /// (see lspConfigFor); a document's server is looked up by its
    /// language name at open time.
    lsp_configs: std.ArrayList(LspConfig),

    /// Open terminal emulators (null entries are closed/freed terminals).
    terminals: std.ArrayList(?*terminal_mod.Terminal),

    /// Registered languages (Zig + Markdown built-in, then Lua extensions).
    /// Each LanguageDef is individually heap-allocated because documents hold
    /// `*const LanguageDef` — pointers must stay stable when extensions
    /// register new languages, and re-registering an existing name replaces
    /// the struct IN PLACE (same slot) so those pointers keep working.
    /// Lookup by extension is newest-first (see findLanguage).
    languages: std.ArrayList(*syntax.LanguageDef),
    /// Per-language profiles keyed by LOWERCASED language name (owned
    /// keys). Independent of LanguageDef lifetime: works for built-ins and
    /// for names registered later — or never.
    lang_profiles: std.StringHashMapUnmanaged(LanguageProfile) = .empty,
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

    pub const EncodingChoice = struct { path: []u8, encoding: text_file.TextEncoding };
    pub const EncodingAction = enum { choose, open, reopen, save };

    pub const CompletionContext = struct {
        doc_id: u64,
        version: u64,
        cursor_offset: usize,
        client: ?*lsp_mod.LspClient = null,
        request_id: ?i64 = null,
        generation: u64,
    };
    pub const EditorCompletionItem = lsp_mod.CompletionEntry;

    pub const LspConfig = lsp_mod.ServerConfig;

    /// Longest language name that can have a profile (stack-lowercased).
    pub const max_lang_name = 64;

    /// Per-language overrides of the global editor settings (null = use
    /// the global value). Set from Lua via zide.set_language or the same
    /// keys on zide.register_language.
    pub const LanguageSettings = struct {
        tab_width: ?usize = null,
        use_tabs: ?bool = null,
        word_wrap: ?bool = null,
        auto_close_brackets: ?bool = null,
    };

    /// Everything ZIDE keeps per language beyond its syntax definition:
    /// setting overrides and a keybind overlay (see lookupKeybind).
    pub const LanguageProfile = struct {
        settings: LanguageSettings = .{},
        keybinds: KeybindMap,
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
        /// Fuzzy file finder (quick_open) with live preview.
        file_finder,
        confirm_quit,
        /// Closing a tab whose document has unsaved changes — Save /
        /// Discard / Cancel for that one document (resolveCloseDoc).
        confirm_close,
        /// Save requested but the file changed on disk since load —
        /// user picks overwrite / reload / cancel (resolveOverwrite).
        confirm_overwrite,
        encoding_picker,
        confirm_reopen,
        confirm_encoding,
        recovery_picker,
        lsp_panel,
        symbol_rename,
        workspace_preview,
        task_save_prompt,
        tool_panel,
        git_stage_prompt,
        settings,
        filetree_prompt,
    };

    /// One editor window: a layout tree of panes plus its focused pane.
    /// See the `windows` field for the invariants. (Named EditorWindow
    /// because both frontends already have a `Window` in scope.)
    pub const EditorWindow = struct {
        pub const Pos = struct { x: i32, y: i32 };
        /// Monotonic id (never reused) — the GUI uses it as the dvui id_extra.
        id: u32,
        layout: Layout,
        active_pane: u8 = 0,
        /// Cleared when the OS asks to close this window (the GUI hands
        /// `&open` to dvui as the child window's open_flag);
        /// retireClosedWindows reaps it at the top of the next frame.
        open: bool = true,
        /// GUI-owned hint: where to place the OS window on first show
        /// (screen coordinates). Consumed by the GUI.
        spawn_pos: ?Pos = null,
        /// The documents this window owns, in tab order (indices into
        /// Editor.documents). A document lives in exactly one window
        /// (invariant I8): showing it elsewhere moves the tab (adoptDoc),
        /// closing a window hands its tabs to the primary.
        tabs: std.ArrayList(usize) = .empty,
    };

    pub const WindowError = error{ Unsupported, TooManyWindows, OutOfMemory };

    pub fn init(allocator: Allocator, io: std.Io) !Editor {
        var editor = Editor{
            .documents = .empty,
            .commands = CommandRegistry.init(allocator),
            .allocator = allocator,
            .io = io,
            .jobs = .{ .allocator = allocator, .io = io },
            .problems = .{ .allocator = allocator, .io = io },
            .project_formatting = .{ .allocator = allocator, .io = io },
            .keybinds = KeybindMap.init(allocator),
            .completion_items = .empty,
            .lsp_configs = .empty,
            .terminals = .empty,
            .languages = .empty,
            .lang_syntax_overrides = .empty,
            .search = .{ .allocator = allocator, .io = io },
        };
        // The primary window lives as long as the editor (invariant I1).
        const primary = try allocator.create(EditorWindow);
        errdefer allocator.destroy(primary);
        primary.* = .{ .id = 0, .layout = try Layout.init(allocator) };
        errdefer primary.layout.deinit();
        try editor.windows.append(allocator, primary);
        errdefer editor.windows.deinit(allocator);
        // Register built-in languages (heap-allocated: see `languages` doc)
        const zig_lang = try allocator.create(syntax.LanguageDef);
        zig_lang.* = syntax.lang_zig;
        errdefer allocator.destroy(zig_lang);
        try editor.languages.append(allocator, zig_lang);
        const md_lang = try allocator.create(syntax.LanguageDef);
        md_lang.* = syntax.lang_markdown;
        errdefer allocator.destroy(md_lang);
        try editor.languages.append(allocator, md_lang);
        // Default language server: zls from PATH for Zig. A later
        // zide.register_lsp for "zig" wins (newest registration first).
        var zls_cfg = try lsp_mod.ServerConfig.fromArgv(allocator, &.{"zig"}, &.{"zls"});
        errdefer zls_cfg.deinit(allocator);
        try editor.lsp_configs.append(allocator, zls_cfg);
        // Always have at least one empty document
        var doc = try Document.init(allocator);
        doc.history.max_size = editor.max_undo_history;
        try doc.loadText("");
        try editor.documents.append(allocator, doc);
        try primary.tabs.append(allocator, 0);
        // Register built-in commands
        try registerBuiltins(&editor.commands);
        // Load default keybindings
        try editor.keybinds.loadDefaults();
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        if (self.recovery) |*recovery| {
            recovery.setWake(null);
            recovery.flush(self.documents.items, self.recovery_enabled);
            self.reportRecoveryError();
            recovery.deinit();
            self.recovery = null;
        }
        for (self.encoding_choices.items) |entry| self.allocator.free(entry.path);
        self.encoding_choices.deinit(self.allocator);
        if (self.encoding_path) |p| self.allocator.free(p);
        if (self.pending_save_path) |p| self.allocator.free(p);
        // Language servers first: joins their reader threads and resets
        // document flags while the documents are still alive.
        self.stopAllLsp();
        self.lsp_tools.deinit(self.allocator);
        self.lsp_clients.deinit(self.allocator);
        // Release Lua refs next: touches the command registry and needs
        // the (caller-owned, still-alive) Lua state.
        lua_api.deinitLua(self);
        self.tasks.deinit(self);
        self.git.deinit(self);
        self.dap.deinit(self);
        self.tool_panel.deinit(self.allocator);
        self.jobs.deinit();
        self.problems.deinit();
        self.project_formatting.deinit();
        for (self.documents.items) |*doc| {
            doc.deinit();
        }
        self.documents.deinit(self.allocator);
        self.commands.deinit();
        self.keybinds.deinit();
        var prof_it = self.lang_profiles.iterator();
        while (prof_it.next()) |entry| {
            entry.value_ptr.keybinds.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.lang_profiles.deinit(self.allocator);
        for (self.windows.items) |win| {
            win.layout.deinit();
            win.tabs.deinit(self.allocator);
            self.allocator.destroy(win);
        }
        self.windows.deinit(self.allocator);
        // Free Lua-registered languages (built-in Zig has null arena)
        for (self.languages.items) |lang| {
            lang.deinit();
            self.allocator.destroy(lang);
        }
        self.clearCompletionItems();
        self.completion_items.deinit(self.allocator);
        for (self.lsp_configs.items) |*cfg| cfg.deinit(self.allocator);
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
        self.finderClearFiles();
        self.finder_files.deinit(self.allocator);
        self.finder_matches.deinit(self.allocator);
        self.search.deinit();
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

    // ---- Windows: accessors ----

    /// The window that has keyboard focus (invariant I2 keeps the index valid).
    pub fn activeWindow(self: *const Editor) *EditorWindow {
        return self.windows.items[self.active_window];
    }

    /// Layout tree of the focused window.
    pub fn activeLayout(self: *const Editor) *Layout {
        return &self.activeWindow().layout;
    }

    /// Focused pane id within the focused window.
    pub fn activePaneId(self: *const Editor) u8 {
        return self.activeWindow().active_pane;
    }

    /// True when `pane_id` of window `win_idx` is THE focused pane — the
    /// frontends gate key input, IME and modal overlays on this.
    pub fn isActivePane(self: *const Editor, win_idx: usize, pane_id: u8) bool {
        return win_idx == self.active_window and pane_id == self.activePaneId();
    }

    /// Document shown by window `win_idx`'s focused pane. A terminal pane
    /// (or an out-of-range index) reports the editor-wide active document.
    pub fn windowDocIdx(self: *const Editor, win_idx: usize) usize {
        if (win_idx >= self.windows.items.len) return self.active_doc_idx;
        const win = self.windows.items[win_idx];
        if (win.active_pane < win.layout.panes.items.len) {
            return switch (win.layout.panes.items[win.active_pane].content) {
                .editor => |idx| idx,
                .terminal => self.active_doc_idx,
            };
        }
        return self.active_doc_idx;
    }

    /// Get the document index for the currently focused pane.
    fn activeDocIdx(self: *const Editor) usize {
        return self.windowDocIdx(self.active_window);
    }

    /// Check if the currently focused pane is a terminal.
    pub fn activePaneIsTerminal(self: *const Editor) bool {
        const win = self.activeWindow();
        if (win.active_pane < win.layout.panes.items.len) {
            return win.layout.panes.items[win.active_pane].content == .terminal;
        }
        return false;
    }

    /// Get the terminal index of the active pane (if it's a terminal).
    pub fn activePaneTerminalIdx(self: *const Editor) ?usize {
        const win = self.activeWindow();
        if (win.active_pane < win.layout.panes.items.len) {
            return switch (win.layout.panes.items[win.active_pane].content) {
                .terminal => |idx| idx,
                .editor => null,
            };
        }
        return null;
    }

    /// After a document was removed from `documents` (index `removed`),
    /// fix every window: tab lists drop it and shift the indices above it;
    /// panes that showed the removed document now show `replacement`,
    /// higher indices shift down by one. Shared by closeDocAt and the
    /// finder's preview pop.
    fn retargetDocIndex(self: *Editor, removed: usize, replacement: usize) void {
        for (self.windows.items) |win| {
            var ti: usize = 0;
            while (ti < win.tabs.items.len) {
                const d = &win.tabs.items[ti];
                if (d.* == removed) {
                    _ = win.tabs.orderedRemove(ti);
                    continue;
                }
                if (d.* > removed) d.* -= 1;
                ti += 1;
            }
            for (win.layout.panes.items) |*pane| {
                switch (pane.content) {
                    .editor => |*idx| {
                        if (idx.* == removed) {
                            idx.* = replacement;
                        } else if (idx.* > removed) {
                            idx.* -= 1;
                        }
                    },
                    .terminal => {},
                }
            }
        }
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
        return self.openFileWithEncoding(path, self.knownEncoding(path), true);
    }

    pub fn openFileWithEncoding(self: *Editor, path: []const u8, encoding: ?text_file.TextEncoding, interactive: bool) !*Document {
        if (try self.findDocument(path)) |idx| {
            self.switchToDoc(idx);
            return self.activeDoc();
        }
        var doc = try Document.init(self.allocator);
        var transferred = false;
        errdefer if (!transferred) doc.deinit();
        doc.history.max_size = self.max_undo_history;
        doc.openWithEncoding(self.io, path, encoding) catch |err| {
            if (interactive and (err == error.EncodingRequired or err == error.BinaryFile)) self.requestOpenEncoding(path);
            return err;
        };
        try self.documents.append(self.allocator, doc);
        transferred = true;
        const idx = self.documents.items.len - 1;
        self.active_doc_idx = idx;
        self.paneShowDoc(idx);
        const active = self.activeDoc();
        self.resolveFormatting(active);
        self.problems.project(active, .lsp) catch {};
        self.problems.project(active, .lua) catch {};
        active.detectLanguage(self);
        self.lspNotifyOpen(active);
        const id = active.id;
        if (encoding) |enc| self.rememberEncoding(active.file_path.?, enc) catch {};
        lua_api.fireEvent(self, .open, active);
        return &self.documents.items[self.docIndexForId(id) orelse return error.DocumentClosed];
    }

    /// Open `path` into the current (startup-empty) document — the CLI
    /// first-file / session-restore path that bypasses openFile. Keeps
    /// the post-open bookkeeping (language detection, LSP notify,
    /// extension event) in one place so bypass sites can't drift.
    pub fn openIntoActive(self: *Editor, path: []const u8) !void {
        const doc = self.activeDoc();
        doc.openWithEncoding(self.io, path, self.knownEncoding(path)) catch |err| {
            if (err == error.EncodingRequired or err == error.BinaryFile) self.requestOpenEncoding(path);
            return err;
        };
        doc.detectLanguage(self);
        self.lspNotifyOpen(doc);
        self.resolveFormatting(doc);
        self.problems.project(doc, .lsp) catch {};
        self.problems.project(doc, .lua) catch {};
        lua_api.fireEvent(self, .open, doc);
    }

    /// Open `path`, or switch to the tab that already has it open
    /// (separator-normalized compare, case-insensitive on Windows).
    pub fn openOrFocus(self: *Editor, path: []const u8) !*Document {
        if (try self.findDocument(path)) |idx| {
            self.switchToDoc(idx);
            return self.activeDoc();
        }
        return try self.openFile(path);
    }

    pub fn pathsEqual(self: *const Editor, a: []const u8, b: []const u8) bool {
        return @import("file_identity.zig").same(self.allocator, self.io, a, b) catch false;
    }

    pub fn findDocument(self: *const Editor, path: []const u8) !?usize {
        const identity = @import("file_identity.zig");
        const key = try identity.key(self.allocator, self.io, path);
        defer self.allocator.free(key);
        for (self.documents.items, 0..) |doc, idx| {
            const p = doc.file_path orelse continue;
            if (doc.preview) continue;
            const doc_key = try identity.key(self.allocator, self.io, p);
            defer self.allocator.free(doc_key);
            if (identity.equalKeys(key, doc_key)) return idx;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Fuzzy file finder (quick_open) — Ctrl+E overlay with live preview.
    // The preview shows in the pane behind the overlay; it is NOT a tab:
    // one transient Document rides at the end of `documents`, hidden from
    // tab bars / sessions / LSP, reused per peek, popped on cancel and
    // promoted to a normal document on commit.
    // ------------------------------------------------------------------

    const finder_max_files = 20_000;
    const finder_max_matches = 200;

    /// Enter .file_finder mode with a fresh workspace file snapshot.
    pub fn finderOpen(self: *Editor) void {
        self.finder_skipped = 0;
        self.finderClearFiles();
        self.finder_buf_len = 0;
        self.finder_selected = 0;
        self.finder_prev_active = self.active_doc_idx;
        const root = self.filetree_root orelse "";
        self.finder_root = self.allocator.dupe(u8, root) catch null;
        const open_root = if (root.len == 0) "." else root;
        if (std.Io.Dir.cwd().openDir(self.io, open_root, .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(self.io);
            self.finderWalk(d, "", 0);
        } else |_| {}
        self.finderFilter();
        self.mode = .file_finder;
    }

    /// Collect relative file paths under `dir`, skipping dot-entries and
    /// zig-out, bounded by depth and finder_max_files.
    fn finderWalk(self: *Editor, dir: std.Io.Dir, prefix: []const u8, depth: usize) void {
        if (depth > 12) return;
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (self.finder_files.items.len >= finder_max_files) return;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            switch (entry.kind) {
                .file => {
                    const rel = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, entry.name }) catch continue;
                    self.finder_files.append(self.allocator, rel) catch self.allocator.free(rel);
                },
                .directory => {
                    if (std.mem.eql(u8, entry.name, "zig-out")) continue;
                    var sub = dir.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                    defer sub.close(self.io);
                    const sub_prefix = std.fmt.allocPrint(self.allocator, "{s}{s}/", .{ prefix, entry.name }) catch continue;
                    defer self.allocator.free(sub_prefix);
                    self.finderWalk(sub, sub_prefix, depth + 1);
                },
                else => {},
            }
        }
    }

    /// Case-insensitive subsequence match.
    fn fuzzySubseq(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        var ni: usize = 0;
        for (haystack) |hc| {
            if (std.ascii.toLower(hc) == std.ascii.toLower(needle[ni])) {
                ni += 1;
                if (ni == needle.len) return true;
            }
        }
        return false;
    }

    /// Recompute finder_matches from the current filter: basename
    /// subsequence hits rank ahead of path-only hits.
    pub fn finderFilter(self: *Editor) void {
        self.finder_matches.clearRetainingCapacity();
        const filter = self.finder_buf[0..self.finder_buf_len];
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            for (self.finder_files.items, 0..) |path, i| {
                if (self.finder_matches.items.len >= finder_max_matches) break;
                const base_hit = fuzzySubseq(std.fs.path.basename(path), filter);
                const hit = if (pass == 0)
                    base_hit
                else
                    !base_hit and fuzzySubseq(path, filter);
                if (hit) self.finder_matches.append(self.allocator, @intCast(i)) catch return;
            }
            if (filter.len == 0) break; // empty filter: pass 0 matched all
        }
        if (self.finder_selected >= self.finder_matches.items.len) self.finder_selected = 0;
    }

    /// Filter changed: re-rank from the top and refresh the preview.
    pub fn finderRefresh(self: *Editor) void {
        self.finder_selected = 0;
        self.finderFilter();
        self.finderPreviewSelected();
    }

    /// Move the finder selection and preview the newly selected file.
    pub fn finderMove(self: *Editor, down: bool) void {
        const count = self.finder_matches.items.len;
        if (count == 0) return;
        if (down) {
            if (self.finder_selected + 1 < count) self.finder_selected += 1;
        } else {
            self.finder_selected -|= 1;
        }
        self.finderPreviewSelected();
    }

    /// Root-joined path of the selected match (written into `buf` when the
    /// workspace root isn't the cwd).
    fn finderSelectedPath(self: *Editor, buf: []u8) ?[]const u8 {
        if (self.finder_selected >= self.finder_matches.items.len) return null;
        const rel = self.finder_files.items[self.finder_matches.items[self.finder_selected]];
        const root = self.finder_root orelse "";
        if (root.len == 0) return rel;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, rel }) catch null;
    }

    /// Show the selected match in the pane behind the finder overlay.
    /// Already-open files get their real tab shown instead.
    pub fn finderPreviewSelected(self: *Editor) void {
        if (self.mode != .file_finder) return;
        var pbuf: [1024]u8 = undefined;
        const path = self.finderSelectedPath(&pbuf) orelse return;
        for (self.documents.items, 0..) |*doc, idx| {
            if (doc.preview) continue;
            const dp = doc.file_path orelse continue;
            if (self.pathsEqual(dp, path)) {
                self.finderDropPreview();
                self.active_doc_idx = idx;
                self.paneShowDoc(idx);
                return;
            }
        }
        if (!self.finder_preview_appended) {
            var doc = Document.init(self.allocator) catch return;
            doc.preview = true;
            self.documents.append(self.allocator, doc) catch {
                doc.deinit();
                return;
            };
            self.finder_preview_appended = true;
        }
        const pidx = self.documents.items.len - 1;
        const pdoc = &self.documents.items[pidx];
        pdoc.openWithEncoding(self.io, path, self.knownEncoding(path)) catch {
            // Unreadable/binary — drop the peek, show where we were.
            self.finderDropPreview();
            self.finderShowPrev();
            self.finder_skipped += 1;
            self.status_message = std.fmt.bufPrint(&self.status_buf, "{d} preview(s) skipped; open to choose encoding", .{self.finder_skipped}) catch "Preview skipped";
            return;
        };
        pdoc.detectLanguage(self);
        // The preview doc is reused across peeks — don't carry the previous
        // file's scroll into this one.
        pdoc.scroll_top = 0;
        pdoc.scroll_left = 0;
        self.active_doc_idx = pidx;
        self.paneShowDoc(pidx);
    }

    /// PageUp/PageDown while the finder is open: scroll the previewed
    /// document behind the panel (keyboard parity with the wheel).
    pub fn finderScrollPage(self: *Editor, down: bool) void {
        const doc = self.activeDoc();
        if (down) {
            const max_top = doc.buffer.lineCount() -| 1;
            doc.scroll_top = @min(doc.scroll_top + self.page_size, max_top);
        } else {
            doc.scroll_top -|= self.page_size;
        }
    }

    /// Escape: drop any preview and restore the view exactly as it was.
    pub fn finderCancel(self: *Editor) void {
        self.finderDropPreview();
        self.finderShowPrev();
        self.mode = .normal;
        self.finderClearFiles();
    }

    /// Enter: promote the preview to a real tab (or focus/open the file).
    pub fn finderCommit(self: *Editor) void {
        var pbuf: [1024]u8 = undefined;
        const maybe_path = self.finderSelectedPath(&pbuf);
        self.mode = .normal;
        const path = maybe_path orelse {
            // Nothing selected — behave like cancel.
            self.finderDropPreview();
            self.finderShowPrev();
            self.finderClearFiles();
            return;
        };
        if (self.finder_preview_appended) {
            const pidx = self.documents.items.len - 1;
            const pdoc = &self.documents.items[pidx];
            if (pdoc.file_path != null and self.pathsEqual(pdoc.file_path.?, path)) {
                // Promote in place — same post-open bookkeeping as openFile.
                pdoc.preview = false;
                self.finder_preview_appended = false;
                self.active_doc_idx = pidx;
                self.paneShowDoc(pidx);
                self.lspNotifyOpen(pdoc);
                lua_api.fireEvent(self, .open, pdoc);
                self.finderClearFiles();
                return;
            }
            // Preview is stale (selection changed without a refresh) —
            // drop it and open cleanly below.
            self.finderDropPreview();
            self.finderShowPrev();
        }
        _ = self.openOrFocus(path) catch {};
        self.finderClearFiles();
    }

    /// Pop and free the transient preview document, if present.
    fn finderDropPreview(self: *Editor) void {
        if (!self.finder_preview_appended) return;
        self.finder_preview_appended = false;
        if (self.documents.pop()) |popped| {
            var doc = popped;
            doc.deinit();
            // Any pane that showed the preview (a split made while the
            // finder was open, another window) now points past the end —
            // send it back to the pre-finder document.
            const popped_idx = self.documents.items.len;
            const fallback = @min(self.finder_prev_active, self.documents.items.len -| 1);
            self.retargetDocIndex(popped_idx, fallback);
        }
    }

    /// Point the active pane back at the pre-finder document (clamped).
    fn finderShowPrev(self: *Editor) void {
        const target = @min(self.finder_prev_active, self.documents.items.len -| 1);
        self.active_doc_idx = target;
        self.paneShowDoc(target);
    }

    // ------------------------------------------------------------------
    // Workspace search & replace panel (find_in_files)
    // ------------------------------------------------------------------

    /// Ctrl+Shift+F cycle: hidden → shown + focused; shown but editor
    /// focused → focus the panel; panel focused → hide (results persist
    /// for next_result / prev_result).
    pub fn searchToggle(self: *Editor) void {
        if (!self.search_visible) {
            self.search_visible = true;
            self.search_focused = true;
            self.search.field = .query;
        } else if (!self.search_focused) {
            self.search_focused = true;
        } else {
            self.search_visible = false;
            self.search_focused = false;
        }
    }

    /// Hide the panel (Escape). Results persist for next/prev_result.
    pub fn searchHide(self: *Editor) void {
        self.search_visible = false;
        self.search_focused = false;
    }

    /// Run the search with the panel's current inputs.
    pub fn searchStart(self: *Editor) void {
        self.search.start(self);
        if (self.search.matches.items.len > 0 or self.search.searching) {
            self.search.field = .results;
        }
    }

    /// Open the selected result at its match (real tab, match selected).
    pub fn searchOpenSelected(self: *Editor) void {
        const sp = &self.search;
        if (sp.selected >= sp.matches.items.len) return;
        const m = sp.matches.items[sp.selected];
        const path = sp.paths.items[m.path_idx];
        _ = self.openOrFocus(path) catch {
            const msg = std.fmt.bufPrint(&self.status_buf, "Cannot open {s}", .{path}) catch "Cannot open result";
            self.status_message = msg;
            return;
        };
        const doc = self.activeDoc();
        // Positions may be stale after edits — clamp defensively.
        const line = @min(m.line, @as(u32, @intCast(doc.buffer.lineCount() -| 1)));
        const line_len = doc.buffer.lineContent(line).len;
        const col = @min(m.col, @as(u32, @intCast(line_len)));
        const start_off = doc.buffer.posToOffset(line, col);
        doc.cursors.clearSecondary();
        const c = doc.cursors.primary();
        c.anchor = start_off;
        c.offset = @min(start_off + sp.query_len, doc.buffer.byteLen());
        c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
        self.search_focused = false;
    }

    /// Cycle to the next/previous result and jump to it (works with the
    /// panel hidden — quickfix style).
    pub fn searchCycleResult(self: *Editor, forward: bool) void {
        const sp = &self.search;
        const count = sp.matches.items.len;
        if (count == 0) {
            self.status_message = "No search results (Ctrl+Shift+F to search)";
            return;
        }
        if (forward) {
            sp.selected = (sp.selected + 1) % count;
        } else {
            sp.selected = if (sp.selected == 0) count - 1 else sp.selected - 1;
        }
        self.searchOpenSelected();
        const msg = std.fmt.bufPrint(&self.status_buf, "Result {d}/{d}", .{ sp.selected + 1, count }) catch "";
        self.status_message = msg;
    }

    /// Execute the armed replace and report; re-runs the search after so
    /// the results reflect the new state.
    pub fn searchExecuteReplace(self: *Editor, scope: search_mod.ReplaceScope) void {
        const res = self.search.executeReplace(self, scope);
        self.search.start(self);
        const noun: []const u8 = if (scope == .open_only) "open doc(s)" else "file(s)";
        const msg = std.fmt.bufPrint(&self.status_buf, "Replaced {d} match(es) in {d} {s}; {d} failed", .{ res.count, res.files, noun, res.failed }) catch "Replace done";
        self.status_message = msg;
    }

    /// Free the workspace snapshot (paths, matches, root).
    fn finderClearFiles(self: *Editor) void {
        for (self.finder_files.items) |p| self.allocator.free(p);
        self.finder_files.clearRetainingCapacity();
        self.finder_matches.clearRetainingCapacity();
        if (self.finder_root) |r| {
            self.allocator.free(r);
            self.finder_root = null;
        }
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
        if (saved) |d| lua_api.fireEvent(self, .save, d);
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
            text_input.set(&self.open_buf, &self.open_buf_len, name);
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
                self.setDocPath(doc, new_abs) catch {};
            } else if (dp.len > old_abs.len and
                filetree_mod.normPathEql(dp[0..old_abs.len], old_abs) and
                (dp[old_abs.len] == '/' or dp[old_abs.len] == '\\'))
            {
                // Document inside a renamed directory
                const joined = std.mem.concat(self.allocator, u8, &.{ new_abs, dp[old_abs.len..] }) catch continue;
                defer self.allocator.free(joined);
                self.setDocPath(doc, joined) catch {};
            }
        }
    }

    /// Close the active document. Returns false if it was the last one
    /// (creates a new empty document in that case).
    pub fn closeActiveDoc(self: *Editor) bool {
        return self.closeDocAt(self.active_doc_idx);
    }

    /// Close the document at `doc_idx`, asking first when it has unsaved
    /// changes: enters .confirm_close (answered by resolveCloseDoc) and
    /// returns false; a clean document closes right away (true). Every
    /// close-tab path (Ctrl+W, the menus, a tab's ×) goes through here.
    pub fn requestCloseDoc(self: *Editor, doc_idx: usize) bool {
        if (doc_idx >= self.documents.items.len) return false;
        if (self.documents.items[doc_idx].dirty) {
            self.confirm_close_doc = doc_idx;
            self.mode = .confirm_close;
            return false;
        }
        _ = self.closeDocAt(doc_idx);
        return true;
    }

    pub const CloseChoice = enum { save, discard, cancel };

    /// What resolveCloseDoc did: the tab closed, it stays open, or the
    /// document is untitled — it is active now and the frontend runs its
    /// Save As flow, closing the tab once that wrote the file.
    pub const CloseOutcome = enum { closed, kept, needs_path };

    /// Resolve the .confirm_close prompt for the document it was opened for
    /// (confirm_close_doc), not whatever is active when answered. Save
    /// writes the file and closes the tab; a file that changed on disk
    /// meanwhile gets the overwrite prompt instead and the tab stays.
    pub fn resolveCloseDoc(self: *Editor, choice: CloseChoice) CloseOutcome {
        self.mode = .normal;
        const idx = self.confirm_close_doc;
        if (idx >= self.documents.items.len) {
            self.status_message = "Close cancelled (the document is gone)";
            return .kept;
        }
        switch (choice) {
            .cancel => return .kept,
            .discard => {
                _ = self.closeDocAt(idx);
                return .closed;
            },
            .save => {
                const id = self.documents.items[idx].id;
                switch (self.saveDocument(id, .{})) {
                    .formatting => {
                        self.close_after_save_id = id;
                        return .kept;
                    },
                    .needs_path => {
                        self.close_after_save_id = id;
                        return .needs_path;
                    },
                    .saved => {
                        const current = self.docIndexForId(id) orelse return .closed;
                        if (self.documents.items[current].dirty) return .kept;
                        _ = self.closeDocAt(current);
                        return .closed;
                    },
                    else => return .kept,
                }
            },
        }
    }

    /// Text of the .confirm_close prompt (both frontends draw it).
    pub fn confirmClosePrompt(self: *const Editor, buf: []u8) []const u8 {
        const name: []const u8 = if (self.confirm_close_doc < self.documents.items.len)
            self.documents.items[self.confirm_close_doc].display_name
        else
            "Document";
        return std.fmt.bufPrint(buf, "{s} has unsaved changes! [S]ave [D]iscard [C]ancel", .{name}) catch "Unsaved changes! [S]ave [D]iscard [C]ancel";
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
            self.forgetRecovery(self.documents.items[0].id);
            // Send didClose before resetting
            self.lspForgetDoc(&self.documents.items[0]);
            self.documents.items[0].deinit();
            self.documents.items[0] = fresh;
            self.active_doc_idx = 0;
            // Don't convert a focused terminal pane into an editor pane.
            if (!self.activePaneIsTerminal()) self.paneShowDoc(0);
            return false;
        }
        const removed_idx = doc_idx;
        // The owning window's neighbouring tab takes over its views (the tab
        // after it, else the one before); other windows only shift indices.
        var owner_repl: ?usize = null;
        var emptied_owner: ?usize = null;
        if (self.docWindow(removed_idx)) |oi| {
            const owner = self.windows.items[oi];
            if (std.mem.indexOfScalar(usize, owner.tabs.items, removed_idx)) |pos| {
                _ = owner.tabs.orderedRemove(pos);
                if (owner.tabs.items.len > 0) {
                    owner_repl = owner.tabs.items[@min(pos, owner.tabs.items.len - 1)];
                } else {
                    emptied_owner = oi;
                }
            }
        }
        self.lspForgetDoc(&self.documents.items[removed_idx]);
        self.forgetRecovery(self.documents.items[removed_idx].id);
        self.documents.items[removed_idx].deinit();
        _ = self.documents.orderedRemove(removed_idx);
        if (self.active_doc_idx > removed_idx) {
            self.active_doc_idx -= 1;
        } else if (self.active_doc_idx >= self.documents.items.len) {
            self.active_doc_idx = self.documents.items.len - 1;
        }
        const replacement = if (owner_repl) |r| (if (r > removed_idx) r - 1 else r) else self.active_doc_idx;
        self.retargetDocIndex(removed_idx, replacement);
        if (emptied_owner) |oi| {
            if (oi == 0) {
                // The main window cannot show nothing: a fresh untitled document.
                if (self.appendUntitled(0)) |fresh| {
                    for (self.windows.items[0].layout.panes.items) |*pane| {
                        if (pane.content == .editor) pane.content = .{ .editor = fresh };
                    }
                }
            } else {
                // Its last tab closed: the window goes with it (reaped next frame).
                self.requestCloseWindow(oi);
            }
        }
        self.active_doc_idx = self.windowDocIdx(self.active_window);
        return true;
    }

    /// Switch to the next tab of the focused window (in its focused pane).
    pub fn nextDoc(self: *Editor) void {
        self.cycleTab(true);
    }

    /// Switch to the previous tab of the focused window (in its focused pane).
    pub fn prevDoc(self: *Editor) void {
        self.cycleTab(false);
    }

    fn cycleTab(self: *Editor, forward: bool) void {
        const win = self.activeWindow();
        const n = win.tabs.items.len;
        if (n <= 1) return;
        const shown = self.windowDocIdx(self.active_window);
        const pos = std.mem.indexOfScalar(usize, win.tabs.items, shown) orelse 0;
        const next = if (forward) (pos + 1) % n else (pos + n - 1) % n;
        self.switchToDoc(win.tabs.items[next]);
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
            switch (self.saveDocument(self.activeDoc().id, .{})) {
                .needs_path => return self.execAction("save_as"),
                else => {},
            }
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
            self.startSaveAs(self.activeDoc().id, null);
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
            self.settings_window_id = self.activeWindow().id;
            self.settings_selected = 0;
            self.settings_editing = null;
            return true;
        }
        if (std.mem.eql(u8, action, "new_document")) {
            _ = self.newDocument() catch {};
            return true;
        }
        if (std.mem.eql(u8, action, "close_tab")) {
            _ = self.requestCloseDoc(self.active_doc_idx);
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
        // Window actions (GUI; the TUI and unsupported backends split instead)
        if (std.mem.eql(u8, action, "open_in_new_window")) {
            self.openInNewWindow();
            return true;
        }
        if (std.mem.eql(u8, action, "move_pane_to_new_window")) {
            self.movePaneToNewWindow();
            return true;
        }
        if (std.mem.eql(u8, action, "close_window")) {
            self.requestCloseWindow(self.active_window);
            return true;
        }
        if (std.mem.eql(u8, action, "detach_terminal")) {
            self.detachTerminal();
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
        // Preview docs are invisible (no tab), so don't count them.
        var n: usize = 0;
        for (self.documents.items) |*doc| {
            if (!doc.preview) n += 1;
        }
        return n;
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
        if (self.project_formatting.refresh() catch false) {
            for (self.documents.items) |*doc| self.resolveFormatting(doc);
        }
        for (self.documents.items) |*doc| {
            const path = doc.file_path orelse continue;
            if (doc.external_changed) continue; // flagged; waiting on the user
            if (doc.disk_mtime == null) continue; // no stamp to compare
            const st = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch {
                doc.external_changed = true;
                doc.history.saved_revision = null;
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

    pub fn findIncremental(self: *Editor) void {
        self.findFrom(self.find_origin, true);
    }
    pub fn findNext(self: *Editor) void {
        const c = self.activeDoc().cursors.primaryConst();
        self.findFrom(if (c.selectionRange()) |r| r.end else c.offset, false);
    }
    fn findFrom(self: *Editor, origin: usize, incremental: bool) void {
        const doc = self.activeDoc();
        const needle = self.find_buf[0..self.find_buf_len];
        const start = @min(origin, doc.buffer.byteLen());
        const c = doc.cursors.primary();
        if (needle.len == 0) {
            if (incremental) {
                c.offset = @import("cursor.zig").floorBoundary(&doc.buffer, start);
                c.clearSelection();
            }
            self.status_message = "";
            return;
        }
        const content = doc.buffer.slice(0, doc.buffer.byteLen());
        var hit = search_mod.findInText(content, needle, self.find_case_sensitive, self.find_whole_word, start);
        var wrapped = false;
        if (hit == null) {
            hit = search_mod.findInText(content, needle, self.find_case_sensitive, self.find_whole_word, 0);
            wrapped = hit != null;
        }
        if (hit) |at| {
            c.anchor = at;
            c.offset = at + needle.len;
            c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
            self.status_message = if (wrapped) "Search wrapped" else "";
        } else {
            if (incremental) {
                c.offset = @import("cursor.zig").floorBoundary(&doc.buffer, start);
                c.clearSelection();
            }
            self.status_message = "No matches found";
        }
    }
    pub fn replaceOne(self: *Editor) void {
        const doc = self.activeDoc();
        const needle = self.find_buf[0..self.find_buf_len];
        if (needle.len == 0) return;
        if (doc.cursors.primaryConst().selectionRange()) |r| {
            const content = doc.buffer.slice(0, doc.buffer.byteLen());
            if (r.end - r.start == needle.len and search_mod.findInText(content, needle, self.find_case_sensitive, self.find_whole_word, r.start) == r.start) {
                doc.beginEdit() catch {
                    self.status_message = "Replace failed";
                    return;
                };
                defer doc.endEdit();
                doc.replaceRange(r.start, r.end, self.replace_buf[0..self.replace_buf_len]) catch {
                    self.status_message = "Replace failed";
                    return;
                };
                self.findNext();
                return;
            }
        }
        self.findNext();
    }
    pub fn replaceAll(self: *Editor) void {
        const n = search_mod.replaceAllInDoc(self.activeDoc(), self.find_buf[0..self.find_buf_len], self.replace_buf[0..self.replace_buf_len], self.find_case_sensitive, self.find_whole_word) catch {
            self.status_message = "Replace failed; document unchanged";
            return;
        };
        self.status_message = std.fmt.bufPrint(&self.status_buf, "Replaced {d} occurrence(s)", .{n}) catch "Replaced all";
    }

    pub fn knownEncoding(self: *const Editor, path: []const u8) ?text_file.TextEncoding {
        const absolute = text_file.pathKey(self.allocator, self.io, path) catch return null;
        defer self.allocator.free(absolute);
        for (self.encoding_choices.items) |choice| {
            if (filetree_mod.normPathEql(choice.path, absolute)) return choice.encoding;
        }
        return null;
    }
    pub fn rememberEncoding(self: *Editor, path: []const u8, encoding: text_file.TextEncoding) !void {
        const absolute = try text_file.pathKey(self.allocator, self.io, path);
        errdefer self.allocator.free(absolute);
        for (self.encoding_choices.items) |*choice| {
            if (filetree_mod.normPathEql(choice.path, absolute)) {
                choice.encoding = encoding;
                self.allocator.free(absolute);
                return;
            }
        }
        try self.encoding_choices.append(self.allocator, .{ .path = absolute, .encoding = encoding });
    }
    fn requestOpenEncoding(self: *Editor, path: []const u8) void {
        const owned = self.allocator.dupe(u8, path) catch return;
        self.cancelEncoding();
        self.encoding_path = owned;
        self.encoding_action = .open;
        self.mode = .encoding_picker;
        self.status_message = "Choose an encoding to open this file";
    }
    pub fn startEncoding(self: *Editor, action: EncodingAction) void {
        if (self.activePaneIsTerminal()) return;
        self.cancelEncoding();
        self.encoding_doc_id = self.activeDoc().id;
        self.encoding_action = action;
        self.mode = .encoding_picker;
    }
    pub fn cancelEncoding(self: *Editor) void {
        self.close_after_save_id = null;
        if (self.encoding_path) |p| self.allocator.free(p);
        self.encoding_path = null;
        self.encoding_doc_id = null;
        self.reopen_encoding = null;
        self.reopen_after_save = false;
        self.encoding_selected = 0;
        self.mode = .normal;
        self.clearPendingSave();
    }
    pub fn encodingTitle(self: *const Editor) []const u8 {
        return switch (self.encoding_action) {
            .choose => "File Encoding",
            .open => "Open with Encoding",
            .reopen => "Reopen with Encoding",
            .save => "Save with Encoding",
        };
    }
    pub fn encodingCount(self: *const Editor) usize {
        return if (self.encoding_action == .choose) 2 else text_file.formats.len;
    }
    pub fn encodingLabel(self: *const Editor, idx: usize) []const u8 {
        if (self.encoding_action == .choose) return if (idx == 0) "Reopen with Encoding" else "Save with Encoding";
        return text_file.formats[idx].label();
    }
    pub fn chooseEncoding(self: *Editor, idx: usize) void {
        if (idx >= self.encodingCount()) return;
        if (self.encoding_action == .choose) {
            self.encoding_action = if (idx == 0) .reopen else .save;
            self.encoding_selected = 0;
            return;
        }
        const format = text_file.formats[idx];
        if (self.encoding_action == .open) {
            const path = self.encoding_path orelse return;
            _ = self.openFileWithEncoding(path, format.encoding, false) catch |err| {
                self.status_message = std.fmt.bufPrint(&self.status_buf, "Cannot decode: {s}", .{@errorName(err)}) catch "Cannot decode";
                return;
            };
            self.cancelEncoding();
            return;
        }
        const id = self.encoding_doc_id orelse return;
        const di = self.docIndexForId(id) orelse {
            self.cancelEncoding();
            return;
        };
        if (self.encoding_action == .save) {
            self.mode = .normal;
            switch (self.saveDocument(id, .{ .format = format })) {
                .needs_path => self.startSaveAs(id, format),
                else => {},
            }
        } else {
            if (self.documents.items[di].file_path == null) {
                self.status_message = "Save the untitled document before reopening";
                return;
            }
            self.reopen_encoding = format.encoding;
            if (self.documents.items[di].dirty) self.mode = .confirm_reopen else self.finishReopen();
        }
    }
    fn finishReopen(self: *Editor) void {
        const id = self.encoding_doc_id orelse return;
        const idx = self.docIndexForId(id) orelse {
            self.cancelEncoding();
            return;
        };
        const enc = self.reopen_encoding orelse return;
        const doc = &self.documents.items[idx];
        doc.reloadWithEncoding(self.io, enc) catch |err| {
            self.status_message = std.fmt.bufPrint(&self.status_buf, "Reload failed: {s}", .{@errorName(err)}) catch "Reload failed";
            self.cancelEncoding();
            return;
        };
        if (doc.file_path) |p| self.rememberEncoding(p, enc) catch {};
        self.status_message = "Reopened with selected encoding";
        self.cancelEncoding();
    }
    pub fn resolveReopen(self: *Editor, choice: CloseChoice) void {
        switch (choice) {
            .cancel => self.cancelEncoding(),
            .discard => self.finishReopen(),
            .save => {
                const id = self.encoding_doc_id orelse return;
                self.reopen_after_save = true;
                self.mode = .normal;
                switch (self.saveDocument(id, .{})) {
                    .needs_path => self.startSaveAs(id, null),
                    else => {},
                }
            },
        }
    }
    pub fn startSaveAs(self: *Editor, id: u64, format: ?text_file.TextFormat) void {
        const idx = self.docIndexForId(id) orelse return;
        self.save_as_id = id;
        self.save_as_format = format;
        text_input.set(&self.open_buf, &self.open_buf_len, self.documents.items[idx].file_path orelse "");
        self.mode = .save_as;
    }
    pub fn finishSaveAs(self: *Editor, path: []const u8) SaveOutcome {
        const id = self.save_as_id orelse return .{ .failed = error.DocumentClosed };
        const format = self.save_as_format;
        self.mode = .normal;
        self.save_as_id = null;
        self.save_as_format = null;
        return self.saveDocument(id, .{ .path = path, .format = format });
    }
    pub fn cancelSaveAs(self: *Editor) void {
        self.save_as_id = null;
        self.save_as_format = null;
        self.cancelEncoding();
    }
    fn holdSave(self: *Editor, id: u64, options: SaveOptions) !void {
        const path = if (options.path) |p| try self.allocator.dupe(u8, p) else null;
        if (self.pending_save_path) |p| self.allocator.free(p);
        self.pending_save_path = path;
        self.pending_save_id = id;
        self.pending_save_format = options.format;
        self.pending_save_overwrite = options.overwrite;
        self.pending_destination_stamp = options.destination_stamp;
    }
    fn clearPendingSave(self: *Editor) void {
        if (self.pending_save_path) |p| self.allocator.free(p);
        self.pending_save_path = null;
        self.pending_save_id = null;
        self.pending_save_format = null;
        self.pending_save_overwrite = false;
        self.pending_destination_stamp = null;
        self.save_destination_conflict = false;
    }
    pub fn resolveEncodingSave(self: *Editor, convert: bool) void {
        self.mode = .normal;
        const id = self.pending_save_id orelse return;
        if (!convert) {
            self.cancelEncoding();
            return;
        }
        const path = self.pending_save_path;
        self.pending_save_path = null;
        defer if (path) |p| self.allocator.free(p);
        _ = self.saveDocument(id, .{ .format = .{}, .path = path, .overwrite = self.pending_save_overwrite, .destination_stamp = self.pending_destination_stamp });
    }

    pub const SaveOutcome = union(enum) { saved, formatting, needs_path, conflict, destination_exists, unrepresentable, failed: anyerror };
    pub const SaveOptions = struct { overwrite: bool = false, interactive: bool = true, refresh_tree: bool = true, format: ?text_file.TextFormat = null, path: ?[]const u8 = null, destination_stamp: ?text_file.Stamp = null, skip_format: bool = false, format_group: ?u64 = null };

    pub fn overwritePrompt(self: *const Editor) []const u8 {
        return if (self.save_destination_conflict) "Destination exists! [O]verwrite [C]ancel" else "File changed on disk! [O]verwrite [R]eload [C]ancel";
    }

    pub fn docIndexForId(self: *const Editor, id: u64) ?usize {
        for (self.documents.items, 0..) |doc, i| if (doc.id == id) return i;
        return null;
    }
    fn saveBlocker(self: *Editor, idx: usize) ?SaveOutcome {
        const doc = &self.documents.items[idx];
        if (doc.file_path == null) return .needs_path;
        if (doc.external_changed or doc.checkExternalChange(self.io)) {
            doc.external_changed = true;
            return .conflict;
        }
        return null;
    }
    fn showSaveBlocker(self: *Editor, idx: usize, result: SaveOutcome) void {
        self.switchToDoc(idx);
        self.mode = .normal;
        switch (result) {
            .formatting => self.status_message = "Formatting before save",
            .conflict => {
                self.save_destination_conflict = false;
                self.confirm_overwrite_doc = idx;
                self.mode = .confirm_overwrite;
                self.status_message = "File changed on disk; save cancelled";
            },
            .destination_exists => {
                self.confirm_overwrite_doc = idx;
                self.save_destination_conflict = true;
                self.mode = .confirm_overwrite;
                self.status_message = "Save As destination exists; confirm overwrite";
            },
            .needs_path => self.status_message = "Use Save As for the untitled document, then quit again",
            .failed => |err| self.status_message = std.fmt.bufPrint(&self.status_buf, "Save failed: {s}", .{@errorName(err)}) catch "Save failed",
            .unrepresentable => {
                self.mode = .confirm_encoding;
                self.status_message = "Text cannot be represented in Windows-1252";
            },
            .saved => {},
        }
    }
    /// Stable IDs survive save hooks opening or closing tabs. Do not hold a
    /// document pointer across the extension notification at the end.
    pub fn saveDocument(self: *Editor, id: u64, options: SaveOptions) SaveOutcome {
        const idx = self.docIndexForId(id) orelse return .{ .failed = error.DocumentClosed };
        const doc = &self.documents.items[idx];
        const same_path = options.path == null or (doc.file_path != null and self.pathsEqual(doc.file_path.?, options.path.?));
        if (options.path) |path| {
            const owner = self.findDocument(path) catch |err| return .{ .failed = err };
            if (owner) |other| if (other != idx) {
                self.switchToDoc(other);
                self.status_message = "Destination is already open; save its document instead";
                self.cancelEncoding();
                return .{ .failed = error.DestinationOpen };
            };
            if (!same_path) {
                const stamp = text_file.Stamp.read(self.io, path) catch |err| {
                    if (options.interactive) self.showSaveBlocker(idx, .{ .failed = err });
                    return .{ .failed = err };
                };
                if (stamp) |current| if (!options.overwrite or options.destination_stamp == null or !std.meta.eql(current, options.destination_stamp.?)) {
                    if (options.interactive) {
                        var held = options;
                        held.destination_stamp = current;
                        self.holdSave(id, held) catch return .{ .failed = error.OutOfMemory };
                        self.showSaveBlocker(idx, .destination_exists);
                    }
                    return .destination_exists;
                };
            }
        }
        if (!options.overwrite and same_path) if (self.saveBlocker(idx)) |blocker| {
            if (options.interactive) {
                self.holdSave(id, options) catch return .{ .failed = error.OutOfMemory };
                self.showSaveBlocker(idx, blocker);
            }
            return blocker;
        };
        const old_path = if (options.path != null and doc.file_path != null) self.allocator.dupe(u8, doc.file_path.?) catch return .{ .failed = error.OutOfMemory } else null;
        defer if (old_path) |p| self.allocator.free(p);
        if (self.lsp_tools.maybeFormatSave(self, doc, options) catch |err| {
            self.showSaveBlocker(idx, .{ .failed = err });
            return .{ .failed = err };
        }) return .formatting;
        self.prepareProjectFormatting(doc, options.path orelse doc.file_path orelse return .needs_path, options.format_group) catch |err| {
            if (options.interactive) self.showSaveBlocker(idx, .{ .failed = err });
            return .{ .failed = err };
        };
        const result = if (options.path) |p| doc.saveAsWithFormat(self.io, p, options.format) else doc.saveWithFormat(self.io, options.format);
        result catch |err| {
            const outcome: SaveOutcome = if (err == error.UnrepresentableText) .unrepresentable else .{ .failed = err };
            if (options.interactive) {
                if (outcome == .unrepresentable) {
                    self.holdSave(id, options) catch return .{ .failed = error.OutOfMemory };
                } else self.cancelEncoding();
                self.showSaveBlocker(idx, outcome);
            }
            return outcome;
        };
        if (options.path != null) {
            const saved_path = doc.file_path;
            doc.file_path = old_path;
            self.lspForgetDoc(doc);
            doc.file_path = saved_path;
            self.relanguageDoc(doc);
            self.resolveFormatting(doc);
        }
        if (options.format != null or doc.format.encoding == .windows1252 or
            ((doc.format.encoding == .utf16_le or doc.format.encoding == .utf16_be) and !doc.format.bom))
            if (doc.file_path) |p| self.rememberEncoding(p, doc.format.encoding) catch {};
        if (self.pending_save_id == id) self.clearPendingSave();
        self.status_message = std.fmt.bufPrint(&self.status_buf, "Saved {s}", .{doc.display_name}) catch "Saved";
        self.lspDidSave(doc);
        const saved_version = doc.buffer.version;
        self.forgetRecovery(id);
        if (options.refresh_tree) self.noteFileSaved(options.path != null, doc) else lua_api.fireEvent(self, .save, doc);
        if (options.interactive and self.encoding_doc_id == id and self.reopen_after_save) {
            const current = self.docIndexForId(id) orelse {
                self.cancelEncoding();
                return .saved;
            };
            if (self.documents.items[current].buffer.version == saved_version and !self.documents.items[current].dirty) {
                self.finishReopen();
            } else {
                self.cancelEncoding();
                self.status_message = "Document changed during save; reopen cancelled";
            }
        }
        if (self.close_after_save_id == id) {
            self.close_after_save_id = null;
            if (self.docIndexForId(id)) |current| {
                if (!self.documents.items[current].dirty) _ = self.closeDocAt(current);
            }
        }
        return .saved;
    }
    fn dirtyDocumentIds(self: *Editor) ![]u64 {
        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(self.allocator);
        for (self.documents.items) |doc| if (doc.dirty) {
            try ids.append(self.allocator, doc.id);
        };
        return ids.toOwnedSlice(self.allocator);
    }
    pub fn saveAllAndQuit(self: *Editor) void {
        self.mode = .normal;
        const ids = self.dirtyDocumentIds() catch {
            self.status_message = "Save failed: out of memory";
            return;
        };
        defer self.allocator.free(ids);
        // Preflight the whole batch before writing any document.
        for (ids) |id| {
            const idx = self.docIndexForId(id) orelse continue;
            if (self.saveBlocker(idx)) |blocker| {
                self.holdSave(id, .{}) catch {
                    self.status_message = "Save failed: out of memory";
                    return;
                };
                self.showSaveBlocker(idx, blocker);
                return;
            }
        }
        var saved: usize = 0;
        defer if (saved > 0) self.noteFileSaved(false, null);
        for (ids) |id| {
            const idx = self.docIndexForId(id) orelse continue;
            if (!self.documents.items[idx].dirty) continue;
            switch (self.saveDocument(id, .{ .refresh_tree = false })) {
                .saved => saved += 1,
                .formatting => {
                    self.lsp_tools.quit_after_format = true;
                    return;
                },
                else => return,
            }
        }
        // Save hooks can create new dirty content; never discard it on exit.
        if (!self.hasUnsavedChanges()) self.running = false else self.status_message = "Unsaved changes remain; quit cancelled";
    }

    pub const OverwriteChoice = enum { overwrite, reload, cancel };

    /// Resolve the .confirm_overwrite prompt for the document it was opened
    /// for (confirm_overwrite_doc), not whatever is active when answered.
    pub fn resolveOverwrite(self: *Editor, choice: OverwriteChoice) void {
        if (self.save_destination_conflict and choice == .reload) return;
        self.mode = .normal;
        const id = self.pending_save_id orelse blk: {
            if (self.confirm_overwrite_doc >= self.documents.items.len) {
                self.status_message = "Save cancelled (the document was closed)";
                return;
            }
            break :blk self.documents.items[self.confirm_overwrite_doc].id;
        };
        const idx = self.docIndexForId(id) orelse {
            self.cancelEncoding();
            return;
        };
        const doc = &self.documents.items[idx];
        const path = self.pending_save_path;
        self.pending_save_path = null;
        defer if (path) |p| self.allocator.free(p);
        switch (choice) {
            .overwrite => {
                _ = self.saveDocument(id, .{ .overwrite = true, .format = self.pending_save_format, .path = path, .destination_stamp = self.pending_destination_stamp });
            },
            .reload => {
                self.cancelEncoding();
                doc.reloadFromDisk(self.io) catch |err| {
                    const msg = std.fmt.bufPrint(&self.status_buf, "Reload failed: {s}", .{@errorName(err)}) catch "Reload failed";
                    self.status_message = msg;
                    return;
                };
                const msg = std.fmt.bufPrint(&self.status_buf, "Reloaded {s} from disk", .{doc.display_name}) catch "Reloaded";
                self.status_message = msg;
            },
            .cancel => {
                self.cancelEncoding();
                self.status_message = "Save cancelled";
            },
        }
    }

    /// Auto-save all dirty documents that have a file path.
    /// Returns the number of documents saved.
    pub fn autoSaveAll(self: *Editor) usize {
        const ids = self.dirtyDocumentIds() catch return 0;
        defer self.allocator.free(ids);
        var saved: usize = 0;
        var failed: usize = 0;
        for (ids) |id| {
            const idx = self.docIndexForId(id) orelse continue;
            if (!self.documents.items[idx].dirty) continue;
            if (id == self.pending_save_id or
                (id == self.encoding_doc_id and (self.mode == .encoding_picker or self.mode == .confirm_reopen))) continue;
            switch (self.saveDocument(id, .{ .interactive = false, .refresh_tree = false })) {
                .saved => saved += 1,
                .needs_path, .formatting => {},
                else => failed += 1,
            }
        }
        if (saved > 0) {
            self.noteFileSaved(false, null);
            self.status_message = std.fmt.bufPrint(&self.status_buf, "Auto-saved {d} file(s)", .{saved}) catch "Auto-saved";
        }
        if (failed > 0) self.status_message = std.fmt.bufPrint(&self.status_buf, "Auto-save: {d} saved, {d} failed (encoding, conflict or I/O)", .{ saved, failed }) catch "Auto-save failed";
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

        self.saveSessionTo(path) catch {
            self.status_message = "Session save failed";
        };
    }

    pub fn saveSessionTo(self: *Editor, path: []const u8) !void {
        const bytes = try self.sessionTextAlloc();
        defer self.allocator.free(bytes);
        try text_file.atomicWrite(self.allocator, self.io, path, bytes);
    }

    pub fn sessionTextAlloc(self: *Editor) ![]u8 {
        // Active index within the saved (path-bearing) list, not all docs.
        var active_saved: usize = 0;
        var n: usize = 0;
        for (self.documents.items, 0..) |*doc, i| {
            if (doc.file_path == null or doc.preview) continue;
            if (i == self.active_doc_idx) active_saved = n;
            n += 1;
        }

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);

        var buf: [1024]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "active {d}\n", .{active_saved}) catch return error.OutOfMemory;
        output.appendSlice(self.allocator, head) catch return error.OutOfMemory;
        for (self.encoding_choices.items) |choice| {
            const line = std.fmt.allocPrint(self.allocator, "encoding {s} {s}\n", .{ @tagName(choice.encoding), choice.path }) catch return error.OutOfMemory;
            defer self.allocator.free(line);
            output.appendSlice(self.allocator, line) catch return error.OutOfMemory;
        }
        for (self.documents.items) |*doc| {
            if (doc.preview) continue;
            const fp = doc.file_path orelse continue;
            const line = try std.fmt.allocPrint(self.allocator, "doc {d} {d} {s}\n", .{
                doc.cursors.primaryConst().offset, doc.scroll_top, fp,
            });
            defer self.allocator.free(line);
            output.appendSlice(self.allocator, line) catch return error.OutOfMemory;
        }
        return output.toOwnedSlice(self.allocator);
    }

    /// Restore the session written by saveSession (files, cursor positions,
    /// scroll, active tab). Files that no longer open are skipped. Returns
    /// the number of documents restored; 0 unless session_persistence is on.
    pub fn restoreSession(self: *Editor) usize {
        if (!self.session_persistence) return 0;
        const path = sessionFilePath() orelse return 0;
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) catch return 0;
        defer self.allocator.free(content);

        return self.restoreSessionText(content);
    }

    pub fn restoreSessionText(self: *Editor, content: []const u8) usize {
        var choices = std.mem.splitScalar(u8, content, '\n');
        while (choices.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!std.mem.startsWith(u8, line, "encoding ")) continue;
            var fields = std.mem.splitScalar(u8, line[9..], ' ');
            const enc = std.meta.stringToEnum(text_file.TextEncoding, fields.next() orelse continue) orelse continue;
            self.rememberEncoding(fields.rest(), enc) catch {};
        }
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
                    doc.openWithEncoding(self.io, file_path, self.knownEncoding(file_path)) catch continue;
                    doc.detectLanguage(self);
                    self.lspNotifyOpen(doc);
                    const id = doc.id;
                    lua_api.fireEvent(self, .open, doc);
                    doc = &self.documents.items[self.docIndexForId(id) orelse continue];
                } else {
                    doc = self.openFileWithEncoding(file_path, self.knownEncoding(file_path), false) catch continue;
                }
                const offset = std.fmt.parseInt(usize, off_str, 10) catch 0;
                const scroll = std.fmt.parseInt(usize, scroll_str, 10) catch 0;
                const c = doc.cursors.primary();
                c.offset = @import("cursor.zig").floorBoundary(&doc.buffer, offset);
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
        const win = self.activeWindow();
        const current_doc_idx = self.activeDocIdx();
        const new_pane = win.layout.splitPane(win.active_pane, direction, .{ .editor = current_doc_idx }) catch return;
        win.active_pane = new_pane;
        // Keep active_doc_idx in sync for compatibility
        self.active_doc_idx = current_doc_idx;
    }

    /// Close the currently focused pane. If it's the last pane, does nothing.
    pub fn closePaneAction(self: *Editor) void {
        const win = self.activeWindow();
        if (win.layout.paneCount() <= 1) {
            // The only pane of a secondary window: closing it closes the window.
            if (self.active_window != 0) {
                self.requestCloseWindow(self.active_window);
                return;
            }
            // Common confusion: panes are splits, not tabs. Say so instead
            // of silently doing nothing.
            self.status_message = "No split panes open — Ctrl+W closes the current tab";
            return;
        }
        const closed_pane = win.active_pane;
        // If closing a terminal pane, clean up the terminal
        if (closed_pane < win.layout.panes.items.len) {
            switch (win.layout.panes.items[closed_pane].content) {
                .terminal => |idx| {
                    self.closeTerminal(idx);
                    return;
                },
                .editor => {},
            }
        }
        // Move focus to a sibling before closing
        win.active_pane = win.layout.nextPane(closed_pane) orelse 0;
        _ = win.layout.closePane(closed_pane);
        // Update active_doc_idx to match new focused pane
        self.active_doc_idx = self.activeDocIdx();
    }

    /// Focus the next pane in traversal order (within the focused window).
    pub fn focusNextPane(self: *Editor) void {
        const win = self.activeWindow();
        if (win.layout.nextPane(win.active_pane)) |next| {
            win.active_pane = next;
            self.active_doc_idx = self.activeDocIdx();
        }
    }

    /// Focus the previous pane in traversal order (within the focused window).
    pub fn focusPrevPane(self: *Editor) void {
        const win = self.activeWindow();
        if (win.layout.prevPane(win.active_pane)) |prev| {
            win.active_pane = prev;
            self.active_doc_idx = self.activeDocIdx();
        }
    }

    /// Set the active pane (of the focused window) by pane ID and update active_doc_idx.
    pub fn focusPane(self: *Editor, pane_id: u8) void {
        const win = self.activeWindow();
        if (pane_id < win.layout.panes.items.len) {
            win.active_pane = pane_id;
            switch (win.layout.panes.items[pane_id].content) {
                .editor => |idx| self.active_doc_idx = idx,
                .terminal => {},
            }
        }
    }

    /// Give window `idx` the keyboard focus (no-op for a bad index).
    pub fn focusWindow(self: *Editor, idx: usize) void {
        if (idx >= self.windows.items.len) return;
        if (idx != self.active_window) {
            // A prompt or popup opened in one window must not resolve
            // against another window's document — leave it on the way out.
            self.cancelTransientMode();
            // The file tree and search panel live in the primary window.
            if (idx != 0) {
                self.filetree_focused = false;
                self.search_focused = false;
            }
        }
        self.active_window = idx;
        self.ensureValidActivePane();
        self.active_doc_idx = self.windowDocIdx(idx);
    }

    /// Focus pane `pane_id` of window `win_idx` — the frontends' click path.
    pub fn focusPaneIn(self: *Editor, win_idx: usize, pane_id: u8) void {
        self.focusWindow(win_idx);
        self.focusPane(pane_id);
    }

    /// Show document `doc_idx` in window `win_idx` (a window's tab bar).
    pub fn showDocIn(self: *Editor, win_idx: usize, doc_idx: usize) void {
        self.focusWindow(win_idx);
        self.switchToDoc(doc_idx);
    }

    /// Leave transient input and completion modes. Settings and pending file
    /// decisions follow window focus; the latter retain their document IDs.
    pub fn cancelTransientMode(self: *Editor) void {
        switch (self.mode) {
            .normal, .settings, .encoding_picker, .confirm_reopen, .confirm_encoding, .confirm_overwrite, .save_as => {},
            .file_finder => self.finderCancel(),
            .filetree_prompt => self.cancelFiletreePrompt(),
            else => self.mode = .normal,
        }
        self.clearCompletionItems();
    }

    // ---- Windows: create / close ----

    /// Open a new window whose single pane shows `content` and focus it.
    /// error.Unsupported when the frontend cannot host OS windows (callers
    /// fall back to a split); error.TooManyWindows at the cap (status set).
    pub fn newWindow(self: *Editor, content: PaneContent) WindowError!usize {
        if (!self.multi_window_supported) return error.Unsupported;
        if (self.windows.items.len - 1 >= self.max_secondary_windows) {
            self.status_message = std.fmt.bufPrint(&self.status_buf, "Window limit reached ({d} extra windows)", .{self.max_secondary_windows}) catch "Window limit reached";
            return error.TooManyWindows;
        }
        const win = try self.allocator.create(EditorWindow);
        errdefer self.allocator.destroy(win);
        win.* = .{ .id = self.next_window_id, .layout = try Layout.init(self.allocator) };
        errdefer win.layout.deinit();
        win.layout.panes.items[0].content = content;
        try self.windows.append(self.allocator, win);
        self.next_window_id += 1;
        const idx = self.windows.items.len - 1;
        // The document's tab moves with its view (the source pane switches
        // to its neighbouring tab, or the main window gets a fresh untitled).
        if (content == .editor) self.adoptDoc(idx, content.editor);
        self.focusWindow(idx);
        return idx;
    }

    /// Close window `idx` now: its views go away, the documents stay open,
    /// terminals shown there are stopped (invariant I6 — they are shown
    /// nowhere else). Never closes the primary. Frontends should go through
    /// requestCloseWindow + retireClosedWindows so a frame is never cut in half.
    pub fn closeWindow(self: *Editor, idx: usize) bool {
        if (idx == 0 or idx >= self.windows.items.len) return false;
        const win = self.windows.items[idx];
        // A Settings dialog open in this window carries on in the primary.
        if (win.id == self.settings_window_id) self.settings_window_id = self.windows.items[0].id;
        // Its documents stay open: the tabs go back to the main window.
        self.windows.items[0].tabs.appendSlice(self.allocator, win.tabs.items) catch {};
        win.tabs.deinit(self.allocator);
        // Recycled pane slots are reset to an editor by closePane, so every
        // .terminal slot is a live view.
        for (win.layout.panes.items) |pane| {
            if (pane.content == .terminal) self.destroyTerminal(pane.content.terminal);
        }
        win.layout.deinit();
        self.allocator.destroy(win);
        _ = self.windows.orderedRemove(idx);
        if (self.active_window == idx) {
            self.active_window = 0;
        } else if (self.active_window > idx) {
            self.active_window -= 1;
        }
        self.ensureValidActivePane();
        self.active_doc_idx = self.windowDocIdx(self.active_window);
        return true;
    }

    /// Ask window `idx` to close: the primary goes through the quit flow
    /// (unsaved-changes prompt); a secondary is flagged and reaped by
    /// retireClosedWindows at the top of the next frame.
    pub fn requestCloseWindow(self: *Editor, idx: usize) void {
        if (idx >= self.windows.items.len) return;
        if (idx == 0) {
            self.focusWindow(0);
            _ = self.execAction("quit");
            return;
        }
        self.windows.items[idx].open = false;
    }

    /// Close every secondary window whose close was requested (OS close
    /// button via the GUI's open flag, or requestCloseWindow). Frontends
    /// call this before drawing any window.
    pub fn retireClosedWindows(self: *Editor) void {
        var i: usize = self.windows.items.len;
        while (i > 1) {
            i -= 1;
            if (!self.windows.items[i].open) _ = self.closeWindow(i);
        }
    }

    /// Show the active document in a new window (TUI / unsupported: split).
    pub fn openInNewWindow(self: *Editor) void {
        self.showDocInNewWindow(self.active_doc_idx);
    }

    /// Move `doc_idx` into a new window — its tab goes with it (newWindow
    /// repoints the source pane). Without window support this is a
    /// side-by-side split showing the document.
    pub fn showDocInNewWindow(self: *Editor, doc_idx: usize) void {
        if (doc_idx >= self.documents.items.len) return;
        _ = self.newWindow(.{ .editor = doc_idx }) catch |err| {
            if (err == error.Unsupported) {
                self.splitActive(.horizontal);
                self.paneShowDoc(doc_idx);
            }
        };
    }

    /// Move the focused pane into a new window. The source window loses that
    /// view: an editor's tab moves along (newWindow gives a pane left behind
    /// the neighbouring tab); a terminal is never shown twice, so a lone
    /// terminal pane leaves a fresh untitled document in the main window,
    /// and a secondary that loses its only pane closes. Without window
    /// support: a split (documents) or a second terminal at the side.
    pub fn movePaneToNewWindow(self: *Editor) void {
        const src_idx = self.active_window;
        const src = self.activeWindow();
        const src_pane = src.active_pane;
        if (src_pane >= src.layout.panes.items.len) return;
        const content = src.layout.panes.items[src_pane].content;
        _ = self.newWindow(content) catch |err| {
            if (err == error.Unsupported) {
                switch (content) {
                    .terminal => self.openTerminalRight(),
                    .editor => self.splitActive(.horizontal),
                }
            }
            return;
        };
        if (src.layout.paneCount() > 1) {
            src.active_pane = src.layout.nextPane(src_pane) orelse 0;
            _ = src.layout.closePane(src_pane);
            ensureValidActivePaneIn(src);
        } else if (content == .terminal) {
            if (src_idx == 0) {
                if (self.appendUntitled(0)) |fresh| src.layout.panes.items[src_pane].content = .{ .editor = fresh };
            } else {
                self.requestCloseWindow(src_idx);
            }
        }
    }

    /// Move the focused terminal pane into its own window (Ctrl+Alt+`).
    /// Without window support (TUI, -Dgpu) a second terminal opens at the side.
    pub fn detachTerminal(self: *Editor) void {
        if (!self.activePaneIsTerminal()) {
            self.status_message = "Focus a terminal pane to detach it";
            return;
        }
        self.movePaneToNewWindow();
    }

    /// Chords a focused terminal pane must not swallow: the pane / window /
    /// terminal management bindings (everything else is typed into the
    /// shell). Returns the bound action for `combo` when it is one of those.
    pub fn terminalPassthroughAction(self: *Editor, combo: []const u8) ?[]const u8 {
        const action = self.lookupKeybind(combo) orelse return null;
        const allowed = [_][]const u8{
            "toggle_terminal",     "close_terminal",  "close_pane",      "detach_terminal",
            "open_terminal_right", "focus_next_pane", "focus_prev_pane", "close_window",
        };
        for (allowed) |a| {
            if (std.mem.eql(u8, action, a)) return action;
        }
        return null;
    }

    /// Title for window `win_idx`: "ZIDE — <document>[*]" / "ZIDE — Terminal".
    pub fn windowTitle(self: *const Editor, win_idx: usize, buf: []u8) [:0]const u8 {
        if (win_idx < self.windows.items.len) {
            const win = self.windows.items[win_idx];
            if (win.active_pane < win.layout.panes.items.len) {
                switch (win.layout.panes.items[win.active_pane].content) {
                    .terminal => return std.fmt.bufPrintZ(buf, "ZIDE — Terminal", .{}) catch "ZIDE",
                    .editor => |di| if (di < self.documents.items.len) {
                        const doc = &self.documents.items[di];
                        const dirty: []const u8 = if (doc.dirty) "*" else "";
                        return std.fmt.bufPrintZ(buf, "ZIDE — {s}{s}", .{ doc.display_name, dirty }) catch "ZIDE";
                    },
                }
            }
        }
        return std.fmt.bufPrintZ(buf, "ZIDE", .{}) catch "ZIDE";
    }

    /// First editor (non-terminal) leaf of `win`, if any.
    fn firstEditorPaneIn(self: *Editor, win: *EditorWindow) ?u8 {
        var leaves: std.ArrayList(u8) = .empty;
        defer leaves.deinit(self.allocator);
        win.layout.collectLeaves(0, &leaves) catch return null;
        for (leaves.items) |pid| {
            if (pid < win.layout.panes.items.len and win.layout.panes.items[pid].content == .editor) return pid;
        }
        return null;
    }

    /// Switch the active pane to show a specific document. A focused
    /// terminal pane is never replaced (that would orphan a live shell):
    /// the document goes to the window's first editor pane, splitting one
    /// in when the window has none.
    pub fn paneShowDoc(self: *Editor, doc_idx: usize) void {
        const win = self.activeWindow();
        if (win.active_pane >= win.layout.panes.items.len) return;
        if (win.layout.panes.items[win.active_pane].content == .terminal) {
            if (self.firstEditorPaneIn(win)) |pid| {
                win.active_pane = pid;
            } else {
                const new_pane = win.layout.splitPane(win.active_pane, .horizontal, .{ .editor = doc_idx }) catch return;
                win.active_pane = new_pane;
            }
        }
        win.layout.panes.items[win.active_pane].content = .{ .editor = doc_idx };
        self.active_doc_idx = doc_idx;
        // A document lives in one window: showing it here moves its tab here.
        self.adoptDoc(self.active_window, doc_idx);
    }

    // ---- Per-window tab lists (invariant I8) ----

    /// The window whose tab bar lists `doc_idx`, if any (the finder's
    /// preview document is listed nowhere).
    pub fn docWindow(self: *const Editor, doc_idx: usize) ?usize {
        for (self.windows.items, 0..) |win, wi| {
            for (win.tabs.items) |d| {
                if (d == doc_idx) return wi;
            }
        }
        return null;
    }

    /// The finder's transient preview rides hidden at the end of `documents`.
    fn isPreviewDoc(self: *const Editor, doc_idx: usize) bool {
        return self.finder_preview_appended and doc_idx + 1 == self.documents.items.len;
    }

    /// Make window `target` the owner of `doc_idx`'s tab. The previous
    /// owner's panes that showed it switch to its neighbouring tab; when it
    /// was that window's last tab, a secondary window is asked to close and
    /// the primary gets a fresh untitled document (a pane never shows
    /// nothing). No-op for the finder's preview, and while the finder is
    /// peeking at documents (its commit adopts).
    fn adoptDoc(self: *Editor, target: usize, doc_idx: usize) void {
        if (target >= self.windows.items.len or doc_idx >= self.documents.items.len) return;
        if (self.isPreviewDoc(doc_idx) or self.mode == .file_finder) return;
        const owner_idx = self.docWindow(doc_idx);
        if (owner_idx == target) return;
        self.windows.items[target].tabs.append(self.allocator, doc_idx) catch return;
        const oi = owner_idx orelse return;
        const owner = self.windows.items[oi];
        const pos = std.mem.indexOfScalar(usize, owner.tabs.items, doc_idx) orelse return;
        _ = owner.tabs.orderedRemove(pos);
        self.repointLostTab(oi, doc_idx, pos);
    }

    /// Window `owner_idx` just lost the tab of `doc_idx` (it sat at `pos`):
    /// its panes that showed the document switch to the neighbouring tab —
    /// the one now at `pos`, else the last one.
    fn repointLostTab(self: *Editor, owner_idx: usize, doc_idx: usize, pos: usize) void {
        const owner = self.windows.items[owner_idx];
        const replacement: usize = if (owner.tabs.items.len > 0)
            owner.tabs.items[@min(pos, owner.tabs.items.len - 1)]
        else if (owner_idx == 0)
            (self.appendUntitled(0) orelse return)
        else {
            // The view left with its tab: the window closes (reaped next
            // frame; it keeps its still-valid view until then).
            self.requestCloseWindow(owner_idx);
            return;
        };
        for (owner.layout.panes.items) |*pane| {
            if (pane.content == .editor and pane.content.editor == doc_idx) pane.content = .{ .editor = replacement };
        }
        if (owner_idx == self.active_window) self.active_doc_idx = self.windowDocIdx(owner_idx);
    }

    /// A fresh empty document owned by window `win_idx` (appended to its
    /// tab list, not shown anywhere yet). Null when allocation fails.
    fn appendUntitled(self: *Editor, win_idx: usize) ?usize {
        var doc = Document.init(self.allocator) catch return null;
        doc.history.max_size = self.max_undo_history;
        doc.loadText("") catch {
            doc.deinit();
            return null;
        };
        self.documents.append(self.allocator, doc) catch {
            doc.deinit();
            return null;
        };
        const idx = self.documents.items.len - 1;
        self.windows.items[win_idx].tabs.append(self.allocator, idx) catch {};
        return idx;
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
        const win = self.activeWindow();
        const new_pane = win.layout.splitPane(win.active_pane, direction, .{ .terminal = term_idx }) catch return;
        win.active_pane = new_pane;
    }

    /// Close a terminal by index: stop PTY, close its pane, focus a neighbor.
    /// If it's the last live pane, convert it to an editor instead of closing.
    pub fn closeTerminal(self: *Editor, term_idx: usize) void {
        if (term_idx >= self.terminals.items.len) return;
        // Find the pane showing this terminal (at most one across all
        // windows — invariant I6)
        outer: for (self.windows.items, 0..) |win, w| {
            for (win.layout.panes.items, 0..) |pane, i| {
                if (pane.content == .terminal and pane.content.terminal == term_idx) {
                    const pane_u8: u8 = @intCast(i);
                    if (w != 0 and win.layout.paneCount() <= 1) {
                        // Sole pane of a secondary window: the window goes with
                        // it. Deferred to the reap so the frontend can finish
                        // the frame; closeWindow stops the terminal then.
                        self.requestCloseWindow(w);
                        return;
                    }
                    if (win.active_pane == pane_u8) {
                        win.active_pane = win.layout.nextPane(pane_u8) orelse 0;
                    }
                    const closed = win.layout.closePane(pane_u8);
                    if (!closed) {
                        // Last live pane of the main window — convert to an editor so the user isn't stuck on a blank pane.
                        win.layout.panes.items[i].content = .{ .editor = self.active_doc_idx };
                        win.active_pane = pane_u8;
                    }
                    ensureValidActivePaneIn(win);
                    break :outer;
                }
            }
        }
        // Deinit the terminal and null out the entry
        self.destroyTerminal(term_idx);
        // Ensure the focused pane is a valid leaf in its live tree
        self.ensureValidActivePane();
        self.active_doc_idx = self.activeDocIdx();
    }

    /// Stop and free terminal `term_idx`, leaving a null slot (indices stay stable).
    fn destroyTerminal(self: *Editor, term_idx: usize) void {
        if (term_idx >= self.terminals.items.len) return;
        if (self.terminals.items[term_idx]) |t| {
            t.deinit();
            self.terminals.items[term_idx] = null;
        }
    }

    /// Make sure `win.active_pane` points to a real leaf in its layout tree.
    /// If it doesn't, fall back to the first leaf.
    fn ensureValidActivePaneIn(win: *EditorWindow) void {
        if (win.layout.findLeafNode(win.active_pane) != null) return;
        win.active_pane = win.layout.firstLeafPane(0) orelse 0;
    }

    /// ensureValidActivePaneIn for the focused window.
    fn ensureValidActivePane(self: *Editor) void {
        ensureValidActivePaneIn(self.activeWindow());
    }

    /// Toggle terminal: focus existing terminal, or open one. If already in terminal, go back.
    pub fn toggleTerminal(self: *Editor) void {
        // If currently in a terminal pane, focus the nearest non-terminal
        // pane of the same window
        if (self.activePaneIsTerminal()) {
            const win = self.activeWindow();
            var leaves: std.ArrayList(u8) = .empty;
            defer leaves.deinit(self.allocator);
            win.layout.collectLeaves(0, &leaves) catch return;
            for (leaves.items) |pid| {
                if (pid == win.active_pane) continue;
                if (pid < win.layout.panes.items.len) {
                    if (win.layout.panes.items[pid].content == .editor) {
                        self.focusPane(pid);
                        return;
                    }
                }
            }
            // A terminal-only window (a detached terminal): nothing to go back to here.
            self.status_message = "No editor pane in this window";
            return;
        }

        // From an editor pane — always open a new bottom terminal.
        self.openTerminal();
    }

    /// Close the active pane's terminal (if it is one).
    pub fn closeActiveTerminal(self: *Editor) void {
        if (self.activePaneTerminalIdx()) |idx| self.closeTerminal(idx);
    }

    // ---- Language / syntax theme operations ----

    // ---- Language servers: configs and clients ----
    //
    // Any number of servers, each registered from Lua (zide.register_lsp)
    // and started lazily the first time a document of a language it serves
    // opens. Documents route to "the running client whose config serves
    // doc.language" — nothing is cached on Documents or LanguageDefs (their
    // names die on re-registration).

    /// The registration that would serve `lang_name` — newest first, so a
    /// later zide.register_lsp overrides an earlier one (and the built-in
    /// zls seed). Null when nothing serves the language.
    pub fn lspConfigFor(self: *Editor, lang_name: []const u8) ?*lsp_mod.ServerConfig {
        var i = self.lsp_configs.items.len;
        while (i > 0) {
            i -= 1;
            const cfg = &self.lsp_configs.items[i];
            if (cfg.servesLanguage(lang_name)) return cfg;
        }
        return null;
    }

    /// The running client serving `lang_name` (handshake may still be pending).
    pub fn lspClientForLanguage(self: *const Editor, lang_name: []const u8) ?*lsp_mod.LspClient {
        for (self.lsp_clients.items) |client| {
            const cfg = if (client.config) |*c| c else continue;
            if (cfg.servesLanguage(lang_name)) return client;
        }
        return null;
    }

    /// The running client for a document's language, if any.
    pub fn lspClientForDoc(self: *const Editor, doc: *const Document) ?*lsp_mod.LspClient {
        const lang = doc.language orelse return null;
        return self.lspClientForLanguage(lang.name);
    }

    // ---- Per-language profiles (setting overrides + keybind overlays) ----

    /// Lowercase `name` into `buf`; null when it doesn't fit (such names
    /// simply have no profile).
    fn langKey(name: []const u8, buf: *[max_lang_name]u8) ?[]const u8 {
        if (name.len > buf.len) return null;
        return std.ascii.lowerString(buf, name);
    }

    /// Get-or-create the profile for a language (any case). The pointer is
    /// valid until the next profile is created.
    pub fn langProfile(self: *Editor, name: []const u8) !*LanguageProfile {
        var buf: [max_lang_name]u8 = undefined;
        const key = langKey(name, &buf) orelse return error.NameTooLong;
        if (self.lang_profiles.getPtr(key)) |p| return p;
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.lang_profiles.putNoClobber(self.allocator, owned_key, .{ .keybinds = KeybindMap.init(self.allocator) });
        return self.lang_profiles.getPtr(owned_key).?;
    }

    /// The profile for a language name, if one exists (never creates).
    pub fn langProfileNamed(self: *const Editor, name: []const u8) ?*const LanguageProfile {
        var buf: [max_lang_name]u8 = undefined;
        const key = langKey(name, &buf) orelse return null;
        return self.lang_profiles.getPtr(key);
    }

    /// The profile for a document's language, if any.
    pub fn langProfileFor(self: *const Editor, doc: *const Document) ?*const LanguageProfile {
        const lang = doc.language orelse return null;
        return self.langProfileNamed(lang.name);
    }

    /// Effective settings for a document: the language's override when
    /// set, else the global default. Frontends hoist one call per frame.
    pub fn tabWidthFor(self: *const Editor, doc: *const Document) usize {
        if (self.editorconfig_enabled) {
            if (doc.format_rules.tab_width) |width| return width;
            if (doc.format_rules.indent_size) |width| return width;
        }
        if (self.langProfileFor(doc)) |p| {
            if (p.settings.tab_width) |v| return v;
        }
        return self.tab_width;
    }

    pub fn useTabsFor(self: *const Editor, doc: *const Document) bool {
        if (self.editorconfig_enabled) if (doc.format_rules.use_tabs) |tabs| return tabs;
        if (self.langProfileFor(doc)) |p| {
            if (p.settings.use_tabs) |v| return v;
        }
        return self.use_tabs;
    }

    pub fn indentWidthFor(self: *const Editor, doc: *const Document) usize {
        if (self.editorconfig_enabled) {
            if (doc.format_rules.indent_is_tab) return self.tabWidthFor(doc);
            if (doc.format_rules.indent_size) |width| return width;
        }
        if (self.langProfileFor(doc)) |profile| if (profile.settings.tab_width) |width| return width;
        return self.tab_width;
    }

    pub fn startRecovery(self: *Editor) void {
        const base = @import("lua_settings.zig").getConfigDir() orelse {
            self.status_message = "Recovery unavailable: no configuration directory";
            return;
        };
        self.startRecoveryAt(base, self.filetree_root orelse ".") catch |err| {
            self.status_message = std.fmt.bufPrint(&self.status_buf, "Recovery unavailable: {s}", .{@errorName(err)}) catch "Recovery unavailable";
            std.log.err("Recovery startup: {s}", .{@errorName(err)});
        };
    }

    pub fn startDebugWorkspace(self: *Editor) void {
        if (@import("lua_settings.zig").getConfigDir()) |base| self.dap.configureStorage(self, base, self.filetree_root orelse ".");
    }

    pub fn startRecoveryAt(self: *Editor, base: []const u8, workspace: []const u8) !void {
        if (self.recovery != null) return;
        self.recovery = try @import("recovery.zig").Manager.init(self.allocator, self.io, base, workspace);
        self.recovery.?.setWake(self.lua_wake_fn);
        self.recovery_offer_pending = self.recovery.?.candidates.items.len > 0;
        self.reportRecoveryError();
    }

    fn reportRecoveryError(self: *Editor) void {
        if (self.recovery) |*recovery| if (recovery.failure) |err| {
            if (self.recovery_reported_error == null or self.recovery_reported_error.? != err) {
                self.status_message = std.fmt.bufPrint(&self.status_buf, "Recovery: {s}; earlier snapshots retained", .{@errorName(err)}) catch "Recovery snapshot failed";
                std.log.err("Recovery: {s}; earlier snapshots retained", .{@errorName(err)});
                self.recovery_reported_error = err;
            }
            recovery.failure = null;
        };
    }

    fn forgetRecovery(self: *Editor, id: u64) void {
        if (self.recovery) |*recovery| recovery.forget(id) catch |err| {
            recovery.failure = err;
            self.reportRecoveryError();
        };
    }

    pub fn serviceTick(self: *Editor, now: i128) void {
        self.deadlines.tick(self, now);
        self.tasks.tick(self);
        self.git.tick(self, now);
        self.dap.tick(self, now);
        if (self.recovery) |*recovery| {
            recovery.tick(self.documents.items, now, self.recovery_enabled);
            self.deadlines.next_service = recovery.next_deadline;
            self.reportRecoveryError();
        }
        if (self.recovery_offer_pending and self.mode == .normal) {
            self.recovery_offer_pending = false;
            self.showRecovery();
        }
    }

    pub fn discardAndQuit(self: *Editor) void {
        if (self.recovery) |*recovery| recovery.discard(self.documents.items);
        self.reportRecoveryError();
        self.running = false;
    }

    pub fn showRecovery(self: *Editor) void {
        if (self.recovery) |*recovery| if (recovery.candidates.items.len > 0) {
            self.mode = .recovery_picker;
            return;
        };
        self.status_message = "No recovery snapshots for this workspace";
    }

    pub fn resolveRecovery(self: *Editor, choice: enum { recover, discard, later }) void {
        self.mode = .normal;
        if (choice == .later) return;
        const recovery = if (self.recovery) |*r| r else return;
        var index: usize = 0;
        while (index < recovery.candidates.items.len) {
            const candidate = &recovery.candidates.items[index];
            if (choice == .recover and !candidate.restored) {
                self.recoverSnapshot(candidate.parsed.value) catch |err| {
                    recovery.failure = err;
                    index += 1;
                    continue;
                };
                candidate.restored = true;
            }
            recovery.removeCandidate(index) catch |err| {
                recovery.failure = err;
                index += 1;
            };
        }
        self.status_message = if (choice == .recover) "Recovered documents are unsaved; review before saving" else "Recovery snapshots discarded";
        self.reportRecoveryError();
    }

    fn recoverSnapshot(self: *Editor, snapshot: @import("recovery.zig").Snapshot) !void {
        const existing = if (snapshot.path) |path| try self.findDocument(path) else null;
        const replace = if (existing) |index| !self.documents.items[index].dirty else false;
        var restored = try @import("recovery.zig").restore(self.allocator, self.io, snapshot, existing == null or replace);
        errdefer restored.deinit();
        restored.history.max_size = self.max_undo_history;
        if (replace) {
            const old = &self.documents.items[existing.?];
            restored.id = old.id;
            restored.buffer.version = old.buffer.version +% 1;
            restored.lsp_version = old.lsp_version +% 1;
        } else {
            try self.documents.ensureUnusedCapacity(self.allocator, 1);
            try self.activeWindow().tabs.ensureUnusedCapacity(self.allocator, 1);
        }
        // A failed transfer leaves the original stale snapshot and live documents intact.
        try self.recovery.?.captureSync(&restored);
        const index = if (replace) existing.? else self.documents.items.len;
        if (replace) {
            self.lspForgetDoc(&self.documents.items[index]);
            self.documents.items[index].deinit();
            self.documents.items[index] = restored;
        } else self.documents.appendAssumeCapacity(restored);
        self.relanguageDoc(&self.documents.items[index]);
        self.resolveFormatting(&self.documents.items[index]);
        self.switchToDoc(index);
        self.lspNotifyOpen(&self.documents.items[index]);
    }

    pub fn resolveFormatting(self: *Editor, doc: *Document) void {
        doc.format_rules = if (doc.file_path) |path| self.project_formatting.resolve(path) catch .{} else .{};
    }

    fn prepareProjectFormatting(self: *Editor, doc: *Document, path: []const u8, format_group: ?u64) !void {
        if (!self.editorconfig_enabled) return;
        _ = try self.project_formatting.refresh();
        const rules = try self.project_formatting.resolve(path);
        if (rules.eol == null and rules.final_newline == null and !(rules.trim orelse false)) return;
        const before = try doc.buffer.textAlloc(self.allocator);
        defer self.allocator.free(before);
        const after = try @import("editorconfig.zig").normalize(self.allocator, before, rules, doc.crlf);
        defer self.allocator.free(after);
        var ranges: std.ArrayList(Document.RangeEdit) = .empty;
        defer ranges.deinit(self.allocator);
        var old_at: usize = 0;
        var new_at: usize = 0;
        while (old_at < before.len or new_at < after.len) {
            const old_end = if (std.mem.indexOfScalarPos(u8, before, old_at, '\n')) |end| end + 1 else before.len;
            const new_end = if (std.mem.indexOfScalarPos(u8, after, new_at, '\n')) |end| end + 1 else after.len;
            const old_line = before[old_at..old_end];
            const new_line = after[new_at..new_end];
            var prefix: usize = 0;
            while (prefix < old_line.len and prefix < new_line.len and old_line[prefix] == new_line[prefix]) : (prefix += 1) {}
            if (prefix != old_line.len or prefix != new_line.len) try ranges.append(self.allocator, .{ .start = old_at + prefix, .end = old_end, .text = new_line[prefix..] });
            old_at = old_end;
            new_at = new_end;
        }
        std.mem.reverse(Document.RangeEdit, ranges.items);
        const join = format_group != null and doc.history.undo_stack.items.len > 0 and doc.history.undo_stack.items[doc.history.undo_stack.items.len - 1].group_id == format_group.?;
        if (join) {
            doc.history.beginGroup();
            doc.history.active_group = format_group.?;
        }
        defer if (join) doc.history.endGroup();
        try doc.applyRanges(ranges.items);
        doc.detectLineEndings();
    }

    pub fn wordWrapFor(self: *const Editor, doc: *const Document) bool {
        if (self.langProfileFor(doc)) |p| {
            if (p.settings.word_wrap) |v| return v;
        }
        return self.word_wrap;
    }

    pub fn autoCloseBracketsFor(self: *const Editor, doc: *const Document) bool {
        if (self.langProfileFor(doc)) |p| {
            if (p.settings.auto_close_brackets) |v| return v;
        }
        return self.auto_close_brackets;
    }

    // ---- Keybind lookup (per-language overlay, then the global map) ----

    /// Resolve a key combo: the active document's language overlay first
    /// (zide.bind with { language = ... }), then the global map. Overlays
    /// apply only while the editor pane owns the keyboard — tree/search
    /// chords are global navigation and a terminal pane has no language.
    /// Frontends try the exact combo, then (for shift chords) the stripped
    /// one, through this same function: an overlay's exact match beats the
    /// global exact match, but a global exact match beats an overlay's
    /// shift-stripped fallback.
    pub fn lookupKeybind(self: *const Editor, combo: []const u8) ?[]const u8 {
        if (!self.filetree_focused and !self.search_focused and !self.activePaneIsTerminal()) {
            if (self.langProfileFor(self.activeDocConst())) |p| {
                if (p.keybinds.get(combo)) |action| return action;
            }
        }
        return self.keybinds.get(combo);
    }

    /// Status-bar text for a document's language: the language name plus
    /// the server name once one is up for it — `c (clangd)`.
    pub fn languageStatusText(self: *const Editor, doc: *const Document, buf: []u8) []const u8 {
        const lang = doc.language orelse return "plain text";
        if (self.lspClientForLanguage(lang.name)) |client| {
            if (client.isReady()) {
                return std.fmt.bufPrint(buf, "{s} ({s})", .{ lang.name, client.name() }) catch lang.name;
            }
        }
        return lang.name;
    }

    /// Absolute workspace root handed to servers: the file tree's root when
    /// the tree exists (already canonical), else `filetree_root` resolved
    /// against the cwd. Computed once per server start — re-rooting later
    /// needs lsp_restart. Caller frees.
    pub fn lspRootPathAlloc(self: *Editor) ![]u8 {
        if (self.filetree) |*ft| return self.allocator.dupe(u8, ft.root_path);
        const configured: []const u8 = self.filetree_root orelse ".";
        const rel: []const u8 = if (configured.len == 0) "." else configured;
        var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(self.io, &cwd_buf) catch 0;
        const cwd: []const u8 = if (cwd_len > 0) cwd_buf[0..cwd_len] else ".";
        return std.fs.path.resolve(self.allocator, &.{ cwd, rel });
    }

    /// Start the server described by `cfg`: heap-allocated client, wake fn
    /// wired before its reader thread exists. On failure the config is
    /// marked failed so the per-frame lazy start doesn't retry every frame,
    /// and the status bar says why (the log has the details).
    fn startLspClient(self: *Editor, cfg: *lsp_mod.ServerConfig) ?*lsp_mod.LspClient {
        const root = self.lspRootPathAlloc() catch return null;
        defer self.allocator.free(root);
        const first_lang: []const u8 = if (cfg.languages.len > 0) cfg.languages[0] else "?";

        const client = self.allocator.create(lsp_mod.LspClient) catch return null;
        client.* = lsp_mod.LspClient.init(self.allocator, self.io);
        client.tui_wake_fn = self.lsp_wake_fn;
        client.start(cfg, root) catch |err| {
            cfg.failed = true;
            std.log.warn("LSP[{s}] failed to start for {s} ({s}) — argv[0]: {s}", .{ cfg.displayName(), first_lang, @errorName(err), if (cfg.argv.len > 0) cfg.argv[0] else "" });
            self.status_message = std.fmt.bufPrint(&self.status_buf, "LSP for {s}: cannot start {s} ({s}) — see zide.log", .{ first_lang, cfg.displayName(), @errorName(err) }) catch "LSP server failed to start — see zide.log";
            client.deinit();
            self.allocator.destroy(client);
            return null;
        };
        self.lsp_clients.append(self.allocator, client) catch {
            client.deinit();
            self.allocator.destroy(client);
            return null;
        };
        std.log.info("LSP[{s}] started for {s} (root: {s})", .{ client.name(), first_lang, root });
        return client;
    }

    /// Stop and free the client at `idx`; documents it served forget they
    /// were opened so the next sync re-opens them on whatever serves them.
    fn stopLspClient(self: *Editor, idx: usize) void {
        const client = self.lsp_clients.items[idx];
        self.lsp_tools.clientStopped(self, client);
        var producer_buf: [256]u8 = undefined;
        self.problems.clear(.lsp, client.diagnosticSource(&producer_buf));
        if (self.completion_context) |ctx| {
            if (ctx.client == client) self.clearCompletionItems();
        }
        if (client.config) |*cfg| {
            for (self.documents.items) |*doc| {
                if (!doc.lsp_opened) continue;
                const lang = doc.language orelse continue;
                if (cfg.servesLanguage(lang.name)) {
                    doc.lsp_opened = false;
                    doc.clearDiagnostics();
                }
            }
        }
        client.deinit();
        self.allocator.destroy(client);
        _ = self.lsp_clients.orderedRemove(idx);
    }

    /// Stop every language server (quit, lsp_enabled=false, lsp_restart).
    pub fn stopAllLsp(self: *Editor) void {
        while (self.lsp_clients.items.len > 0) {
            self.stopLspClient(self.lsp_clients.items.len - 1);
        }
    }

    /// Palette `lsp_restart`: stop everything, forgive failures, and let
    /// the lazy start bring servers back for the open documents.
    pub fn restartLsp(self: *Editor) void {
        self.stopAllLsp();
        for (self.lsp_configs.items) |*cfg| cfg.failed = false;
        self.status_message = "LSP: restarting language servers";
    }

    /// reload_extensions, before re-running extensions/*.lua: drop the
    /// configs those files registered last time (init.lua's persist).
    pub fn dropExtensionLspConfigs(self: *Editor) void {
        var i: usize = 0;
        while (i < self.lsp_configs.items.len) {
            if (self.lsp_configs.items[i].from_extension) {
                var cfg = self.lsp_configs.orderedRemove(i);
                cfg.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
    }

    /// reload_extensions, after re-running extensions/*.lua: stop servers
    /// whose registration vanished or changed. Identical registrations keep
    /// their server (no clangd restart on every reload).
    pub fn reconcileLspClients(self: *Editor) void {
        var i: usize = 0;
        while (i < self.lsp_clients.items.len) {
            const client = self.lsp_clients.items[i];
            const running_cfg = if (client.config) |*c| c else {
                self.stopLspClient(i);
                continue;
            };
            const first_lang: []const u8 = if (running_cfg.languages.len > 0) running_cfg.languages[0] else "";
            const current = self.lspConfigFor(first_lang);
            if (current == null or !current.?.eql(running_cfg)) {
                std.log.info("LSP[{s}] registration changed or removed — stopping", .{client.name()});
                self.stopLspClient(i);
                continue;
            }
            i += 1;
        }
    }

    /// Per-frame LSP work: honour the enable switch, retire dead servers,
    /// drain their messages, then sync documents (starting servers lazily).
    pub fn lspTick(self: *Editor) void {
        if (!self.lsp_enabled) {
            if (self.lsp_clients.items.len > 0) self.stopAllLsp();
            return;
        }
        // Dead-server sweep: exited/crashed on its own, or rejected
        // initialize. Its config is marked failed so the lazy start below
        // doesn't respawn a crashing server every frame.
        var i: usize = 0;
        while (i < self.lsp_clients.items.len) {
            const client = self.lsp_clients.items[i];
            if (!client.isDead()) {
                i += 1;
                continue;
            }
            const reason = if (client.peer) |peer| peer.errorState() orelse error.ServerExited else error.ServerExited;
            std.log.warn("LSP[{s}]: {s} — run lsp_restart to bring it back", .{ client.name(), @errorName(reason) });
            self.status_message = std.fmt.bufPrint(&self.status_buf, "LSP {s}: {s} — run lsp_restart", .{ client.name(), @errorName(reason) }) catch "LSP server exited — run lsp_restart";
            if (client.config) |*dead_cfg| {
                for (self.lsp_configs.items) |*cfg| {
                    if (cfg.eql(dead_cfg)) cfg.failed = true;
                }
            }
            self.stopLspClient(i);
        }
        // Index loop: a definition response can open a file, which may
        // start a server and grow the list under us.
        var j: usize = 0;
        while (j < self.lsp_clients.items.len) : (j += 1) {
            self.lsp_clients.items[j].pollMessages(self);
            self.lsp_clients.items[j].expireRequests(self, std.Io.Clock.now(.awake, self.io).nanoseconds);
        }
        self.syncLspDocuments();
    }

    /// Find a registered language by file extension. Newest registration
    /// wins: a user extension that claims `.zig` or `.md` overrides the
    /// built-in, and a later extension overrides an earlier one.
    /// The returned pointer stays valid for the editor's lifetime
    /// (each LanguageDef is its own heap allocation — appends never
    /// relocate, and re-registering a name replaces the struct in place).
    pub fn findLanguage(self: *const Editor, ext: []const u8) ?*const syntax.LanguageDef {
        var i = self.languages.items.len;
        while (i > 0) {
            i -= 1;
            const lang = self.languages.items[i];
            if (lang.matchesExtension(ext)) return lang;
        }
        return null;
    }

    /// Find a registered language by name (case-insensitive).
    pub fn findLanguageByName(self: *const Editor, name: []const u8) ?*syntax.LanguageDef {
        for (self.languages.items) |lang| {
            if (std.ascii.eqlIgnoreCase(lang.name, name)) return lang;
        }
        return null;
    }

    /// Re-detect a document's language after its path or the language
    /// registry changed (rename, save-as, reload_extensions). Untitled
    /// documents keep whatever language was set on them. When the language
    /// actually changes the document is forgotten on the LSP side first —
    /// the didClose goes out under the old language — and the next LSP
    /// sync re-opens it under the new one. Same pointer = nothing to do
    /// (in-place re-registration already invalidated the highlight cache).
    pub fn relanguageDoc(self: *Editor, doc: *Document) void {
        const ext = doc.fileExtension() orelse return;
        const new_lang = self.findLanguage(ext);
        if (new_lang == doc.language) return;
        self.lspForgetDoc(doc);
        doc.language = new_lang;
        doc.invalidateLineStates(0);
    }

    /// Point a document at a new path (rename on disk): the LSP forget
    /// happens first so the didClose names the OLD uri, then the language
    /// is re-detected from the new name.
    pub fn setDocPath(self: *Editor, doc: *Document, path: []const u8) !void {
        self.lspForgetDoc(doc);
        try doc.setFilePath(path);
        self.relanguageDoc(doc);
        self.resolveFormatting(doc);
    }

    /// Save As: write `path`, adopt it, re-detect the language, then the
    /// shared post-save bookkeeping (file tree, extensions). Nothing is
    /// touched when the write fails except that the document is re-opened
    /// on the LSP side under its old uri by the next sync (harmless).
    pub fn saveDocAs(self: *Editor, doc: *Document, path: []const u8) !void {
        switch (self.saveDocument(doc.id, .{ .path = path, .interactive = false })) {
            .saved => {},
            .formatting => return error.FormattingInProgress,
            .destination_exists => return error.DestinationExists,
            .unrepresentable => return error.UnrepresentableText,
            .conflict => return error.ExternalChange,
            .needs_path => return error.NoFilePath,
            .failed => |err| return err,
        }
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

    /// Send didOpen for a document whose server is ready. When a
    /// registration serves the document's language but no client runs
    /// yet, the server is started here — lazily, the moment a file opens —
    /// and the didOpen lands in a later sync once its handshake completes.
    pub fn lspNotifyOpen(self: *Editor, doc: *Document) void {
        if (!self.lsp_enabled) return;
        if (doc.lsp_opened or doc.preview) return;
        const path = doc.file_path orelse return;
        const lang = doc.language orelse return;

        const client = self.lspClientForLanguage(lang.name) orelse blk: {
            const cfg = self.lspConfigFor(lang.name) orelse return;
            if (cfg.failed) return;
            break :blk self.startLspClient(cfg) orelse return;
        };
        if (!client.isReady()) return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        const cfg = if (client.config) |*c| c else return;
        const lang_id = cfg.languageIdFor(lang.name);
        const text = doc.buffer.slice(0, doc.buffer.byteLen());

        client.sendDidOpen(uri, lang_id, doc.lsp_version, text) catch return;
        doc.lsp_opened = true;
        doc.lsp_last_synced = doc.lsp_version;
        std.log.info("LSP[{s}] didOpen: {s} (languageId={s})", .{ client.name(), uri, lang_id });
    }

    /// Forget a document on the LSP side: didClose for its CURRENT path,
    /// `lsp_opened` cleared, the server's diagnostics dropped. Path and
    /// language are taken as they are at call time, so callers that change
    /// either (rename, save-as, re-detection) must call this FIRST.
    /// No-op when the document was never opened with LSP.
    pub fn lspForgetDoc(self: *Editor, doc: *Document) void {
        if (!doc.lsp_opened) return;
        doc.lsp_opened = false;
        doc.clearDiagnostics();
        const client = self.lspClientForDoc(doc) orelse return;
        const path = doc.file_path orelse return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        client.sendDidClose(uri) catch {};
    }

    /// Send didSave notification.
    fn lspDidSave(self: *Editor, doc: *Document) void {
        if (!doc.lsp_opened) return;
        const client = self.lspClientForDoc(doc) orelse return;
        const path = doc.file_path orelse return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        client.sendDidSave(uri) catch {};
    }

    /// Sync open documents with their servers: didOpen for documents not
    /// yet registered (starting a server lazily when one is configured for
    /// their language), didChange for edited ones. Runs every frame.
    pub fn syncLspDocuments(self: *Editor) void {
        if (self.completion_context != null and !self.completionCurrent()) self.clearCompletionItems();
        if (!self.lsp_enabled) return;

        var i: usize = 0;
        while (i < self.documents.items.len) : (i += 1) {
            const doc = &self.documents.items[i];
            // Transient previews never touch the server (no didOpen churn
            // while the user arrows through the finder).
            if (doc.preview) continue;
            // Send didOpen for docs that haven't been registered with LSP yet
            if (!doc.lsp_opened) {
                self.lspNotifyOpen(doc);
                continue; // didOpen includes the full text, so no didChange needed
            }

            if (doc.lsp_version == doc.lsp_last_synced) continue;

            const client = self.lspClientForDoc(doc) orelse continue;
            if (!client.isReady()) continue;
            const path = doc.file_path orelse continue;
            const uri = lsp_mod.pathToUri(self.allocator, path) catch continue;
            defer self.allocator.free(uri);

            const text = doc.buffer.slice(0, doc.buffer.byteLen());
            client.sendDidChange(uri, doc.lsp_version, text) catch continue;
            doc.lsp_last_synced = doc.lsp_version;
        }
    }

    /// Clear all completion items (frees memory).
    pub fn clearCompletionItems(self: *Editor) void {
        self.completion_context = null;
        self.completion_generation +%= 1;
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
        try self.addCompletionEntry(.{ .label = label, .detail = detail, .insert_text = insert_text });
    }
    pub fn addCompletionEntry(self: *Editor, item: EditorCompletionItem) !void {
        try self.completion_items.append(self.allocator, item);
        if (self.completion_context == null) self.completion_context = .{
            .doc_id = self.activeDoc().id,
            .version = self.activeDoc().buffer.version,
            .cursor_offset = self.activeDoc().cursors.primaryConst().offset,
            .generation = self.completion_generation,
        };
        self.completion_active = true;
    }
    fn completionCurrent(self: *const Editor) bool {
        const ctx = self.completion_context orelse return false;
        const idx = self.docIndexForId(ctx.doc_id) orelse return false;
        if (idx != self.activeDocIdx() or ctx.generation != self.completion_generation) return false;
        const doc = &self.documents.items[idx];
        return doc.buffer.version == ctx.version and doc.cursors.primaryConst().offset == ctx.cursor_offset;
    }
    pub fn completionResponseCurrent(self: *const Editor, client: ?*lsp_mod.LspClient, id: i64) bool {
        const ctx = self.completion_context orelse return false;
        return ctx.client == client and ctx.request_id == id and self.completionCurrent();
    }

    /// Trigger LSP completion at the current cursor position.
    pub fn triggerCompletion(self: *Editor) void {
        self.clearCompletionItems();
        const doc = self.activeDoc();
        const lsp_client = self.lspClientForDoc(doc) orelse return;
        if (!lsp_client.isReady()) return;
        const path = doc.file_path orelse return;
        if (!doc.lsp_opened) return;
        self.completion_doc_idx = self.activeDocIdx();

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        const cursor = doc.cursors.primary();
        const pos = doc.buffer.offsetToPos(cursor.offset);
        const column = if (lsp_client.position_encoding == .utf16) lsp_mod.byteColToUtf16(doc.buffer.lineContent(pos.line), pos.col) else @as(u32, @intCast(pos.col));

        // The server must see edits made since the preceding frame first.
        if (doc.lsp_version != doc.lsp_last_synced) {
            lsp_client.sendDidChange(uri, doc.lsp_version, doc.buffer.slice(0, doc.buffer.byteLen())) catch return;
            doc.lsp_last_synced = doc.lsp_version;
        }
        const request_id = lsp_client.sendCompletion(uri, @intCast(pos.line), column) catch return;
        if (lsp_client.pending.getPtr(request_id)) |request| {
            request.doc_id = doc.id;
            request.version = doc.buffer.version;
            request.cursor = cursor.offset;
        }
        self.completion_context = .{
            .doc_id = doc.id,
            .version = doc.buffer.version,
            .cursor_offset = cursor.offset,
            .client = lsp_client,
            .request_id = request_id,
            .generation = self.completion_generation,
        };
    }

    /// Trigger LSP go-to-definition at the current cursor position.
    pub fn triggerGotoDefinition(self: *Editor) void {
        const doc = self.activeDoc();
        const lsp_client = self.lspClientForDoc(doc) orelse return;
        if (!lsp_client.isReady()) return;
        const path = doc.file_path orelse return;
        if (!doc.lsp_opened) return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        const cursor = doc.cursors.primary();
        const pos = doc.buffer.offsetToPos(cursor.offset);
        const column = if (lsp_client.position_encoding == .utf16) lsp_mod.byteColToUtf16(doc.buffer.lineContent(pos.line), pos.col) else @as(u32, @intCast(pos.col));

        if (doc.lsp_version != doc.lsp_last_synced) {
            lsp_client.sendDidChange(uri, doc.lsp_version, doc.buffer.slice(0, doc.buffer.byteLen())) catch return;
            doc.lsp_last_synced = doc.lsp_version;
        }
        const request_id = lsp_client.sendGotoDefinition(uri, @intCast(pos.line), column) catch return;
        if (lsp_client.pending.getPtr(request_id)) |request| {
            request.doc_id = doc.id;
            request.version = doc.buffer.version;
            request.cursor = cursor.offset;
        }
    }

    /// Validate the completion's single-line UTF-16 range against this document.
    fn completionByteRange(doc: *Document, range: lsp_mod.LspRange, cursor_offset: usize, encoding: @import("workspace_edit.zig").Encoding) !struct { start: usize, end: usize } {
        if (range.start.line != range.end.line or range.start.line >= doc.lineCount() or range.start.character > range.end.character) return error.InvalidCompletionEdit;
        const start = try @import("workspace_edit.zig").offset(doc, range.start, encoding);
        const end = try @import("workspace_edit.zig").offset(doc, range.end, encoding);
        if (cursor_offset < start or cursor_offset > end) return error.InvalidCompletionEdit;
        return .{ .start = start, .end = end };
    }
    pub fn acceptCompletion(self: *Editor) void {
        if (!self.completion_active) return;
        defer self.clearCompletionItems();
        if (!self.completionCurrent() or self.completion_doc_idx != self.activeDocIdx() or self.completion_selected >= self.completion_items.items.len) return;
        const item = self.completion_items.items[self.completion_selected];
        const doc = self.activeDoc();
        const offset = doc.cursors.primaryConst().offset;
        const encoding = if (self.completion_context.?.client) |client| client.position_encoding else .utf16;
        var start = offset;
        var end = offset;
        if (item.edit) |edit| {
            const range = switch (edit) {
                .replace => |r| r,
                .insert_replace => |r| blk: {
                    const insert = completionByteRange(doc, r.insert, offset, encoding) catch {
                        self.status_message = "Invalid completion range";
                        return;
                    };
                    const replace = completionByteRange(doc, r.replace, offset, encoding) catch {
                        self.status_message = "Invalid completion range";
                        return;
                    };
                    if (insert.start != replace.start or insert.end > replace.end) {
                        self.status_message = "Invalid completion range";
                        return;
                    }
                    break :blk r.replace;
                },
            };
            const bytes = completionByteRange(doc, range, offset, encoding) catch {
                self.status_message = "Invalid completion range";
                return;
            };
            start = bytes.start;
            end = bytes.end;
        } else {
            while (start > 0 and isIdentChar(doc.buffer.byteAt(start - 1) orelse 0)) start -= 1;
        }
        doc.beginEdit() catch {
            self.status_message = "Completion failed: out of memory";
            return;
        };
        defer doc.endEdit();
        doc.replaceRange(start, end, item.insert_text orelse item.label) catch {
            self.status_message = "Completion failed: out of memory";
        };
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

test "per-language settings fall back to globals" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    editor.tab_width = 4;
    editor.use_tabs = false;

    const prof = try editor.langProfile("Zig");
    prof.settings.tab_width = 2;
    doc.language = editor.findLanguage("zig");
    try std.testing.expectEqual(@as(usize, 2), editor.tabWidthFor(doc));
    try std.testing.expectEqual(false, editor.useTabsFor(doc)); // not overridden → global
    try std.testing.expectEqual(editor.word_wrap, editor.wordWrapFor(doc));
    try std.testing.expectEqual(editor.auto_close_brackets, editor.autoCloseBracketsFor(doc));
    // Case-insensitive key → the same profile
    try std.testing.expectEqual(@as(?*const Editor.LanguageProfile, prof), editor.langProfileNamed("ZIG"));
    try std.testing.expectEqual(@as(?*const Editor.LanguageProfile, prof), editor.langProfileFor(doc));
    // Plain text and languages without a profile → globals
    doc.language = null;
    try std.testing.expectEqual(@as(usize, 4), editor.tabWidthFor(doc));
    doc.language = editor.findLanguage("md");
    try std.testing.expectEqual(@as(usize, 4), editor.tabWidthFor(doc));
    try std.testing.expect(editor.langProfileNamed("markdown") == null);
}

test "keybind overlay precedence and focus gating" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();
    const doc = editor.activeDoc();

    const prof = try editor.langProfile("Zig");
    try prof.keybinds.set("ctrl+k", "zig_thing");
    try prof.keybinds.set("ctrl+shift+j", "zig_shift_thing");

    // No language → global map
    try std.testing.expectEqualStrings("delete_line", editor.lookupKeybind("ctrl+k").?);
    // Zig doc → overlay wins for its combos, global map for the rest
    doc.language = editor.findLanguage("zig");
    try std.testing.expectEqualStrings("zig_thing", editor.lookupKeybind("ctrl+k").?);
    try std.testing.expectEqualStrings("undo", editor.lookupKeybind("ctrl+z").?);
    try std.testing.expectEqualStrings("zig_shift_thing", editor.lookupKeybind("ctrl+shift+j").?);
    try std.testing.expect(editor.lookupKeybind("ctrl+shift+zz") == null);
    // Another language → global map
    doc.language = editor.findLanguage("md");
    try std.testing.expectEqualStrings("delete_line", editor.lookupKeybind("ctrl+k").?);
    // Tree / search focus: overlays don't apply
    doc.language = editor.findLanguage("zig");
    editor.filetree_focused = true;
    try std.testing.expectEqualStrings("delete_line", editor.lookupKeybind("ctrl+k").?);
    editor.filetree_focused = false;
    editor.search_focused = true;
    try std.testing.expectEqualStrings("delete_line", editor.lookupKeybind("ctrl+k").?);
    editor.search_focused = false;
    try std.testing.expectEqualStrings("zig_thing", editor.lookupKeybind("ctrl+k").?);
}

test "relanguageDoc and setDocPath follow the document path" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    try std.testing.expect(doc.language == null);

    // Untitled: nothing to detect, manual language (none) is kept
    editor.relanguageDoc(doc);
    try std.testing.expect(doc.language == null);

    try doc.setFilePath("notes.md"); // no disk I/O
    editor.relanguageDoc(doc);
    try std.testing.expectEqualStrings("markdown", doc.language.?.name);

    // Rename path: forget-on-LSP (no-op here) → new path → re-detect
    try editor.setDocPath(doc, "main.zig");
    try std.testing.expectEqualStrings("zig", doc.language.?.name);
    try std.testing.expectEqualStrings("main.zig", doc.file_path.?);
    try std.testing.expect(!doc.lsp_opened);

    try editor.setDocPath(doc, "x.txt");
    try std.testing.expect(doc.language == null);
}

test "lsp config resolution" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();

    // The built-in seed: zls from PATH serves zig (any case), id lowercased
    const seed = editor.lspConfigFor("Zig").?;
    try std.testing.expectEqualStrings("zls", seed.argv[0]);
    try std.testing.expectEqualStrings("zig", seed.languageIdFor("Zig"));
    try std.testing.expect(editor.lspConfigFor("python") == null);

    // A config for another language doesn't affect zig
    try editor.lsp_configs.append(allocator, try lsp_mod.ServerConfig.fromArgv(allocator, &.{"Python"}, &.{ "pyright-langserver", "--stdio" }));
    try std.testing.expectEqualStrings("zls", editor.lspConfigFor("zig").?.argv[0]);
    try std.testing.expectEqualStrings("pyright-langserver", editor.lspConfigFor("PYTHON").?.argv[0]);

    // A later zig registration wins over the seed (newest first)
    try editor.lsp_configs.append(allocator, try lsp_mod.ServerConfig.fromArgv(allocator, &.{"zig"}, &.{"C:/tools/zls-0.16/zls.exe"}));
    try std.testing.expectEqualStrings("C:/tools/zls-0.16/zls.exe", editor.lspConfigFor("Zig").?.argv[0]);

    // One server, several languages, per-language ids
    try editor.lsp_configs.append(allocator, try lsp_mod.ServerConfig.fromArgv(allocator, &.{ "c", "cpp" }, &.{"clangd"}));
    try std.testing.expectEqualStrings("clangd", editor.lspConfigFor("cpp").?.argv[0]);
    try std.testing.expectEqualStrings("cpp", editor.lspConfigFor("c").?.languageIdFor("cpp"));

    // No clients run in tests; document routing is null-safe
    try std.testing.expect(editor.lspClientForDoc(editor.activeDoc()) == null);
    try std.testing.expect(editor.lspClientForLanguage("zig") == null);

    // reload bookkeeping: extension-tagged configs are dropped, others stay
    var ext_cfg = try lsp_mod.ServerConfig.fromArgv(allocator, &.{"lua"}, &.{"lua-language-server"});
    ext_cfg.from_extension = true;
    try editor.lsp_configs.append(allocator, ext_cfg);
    const before = editor.lsp_configs.items.len;
    editor.dropExtensionLspConfigs();
    try std.testing.expectEqual(before - 1, editor.lsp_configs.items.len);
    try std.testing.expect(editor.lspConfigFor("lua") == null);
    try std.testing.expect(editor.lspConfigFor("cpp") != null);

    // lsp_restart forgives failures; reconcile with no clients is a no-op
    editor.lspConfigFor("cpp").?.failed = true;
    editor.restartLsp();
    try std.testing.expect(!editor.lspConfigFor("cpp").?.failed);
    editor.reconcileLspClients();
    editor.lspTick();
    try std.testing.expectEqual(@as(usize, 0), editor.lsp_clients.items.len);
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

test "fuzzy finder: filter, preview, commit and cancel" {
    const t = std.testing;
    const root = ".zig-cache/zide-test-finder";
    std.Io.Dir.cwd().createDirPath(t.io, root ++ "/docs") catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(t.io, root ++ "/alpha.zig", .{});
        f.close(t.io);
    }
    {
        const f = try std.Io.Dir.cwd().createFile(t.io, root ++ "/docs/readme.md", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "# hi\n");
    }
    defer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.filetree_root = try t.allocator.dupe(u8, root);

    editor.finderOpen();
    try t.expectEqual(Editor.Mode.file_finder, editor.mode);
    try t.expectEqual(@as(usize, 2), editor.finder_files.items.len);
    try t.expectEqual(@as(usize, 1), editor.documents.items.len); // no preview yet

    // Type "read" → readme.md matches; the preview doc appears (hidden)
    @memcpy(editor.finder_buf[0..4], "read");
    editor.finder_buf_len = 4;
    editor.finderRefresh();
    try t.expectEqual(@as(usize, 1), editor.finder_matches.items.len);
    try t.expect(editor.finder_preview_appended);
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    try t.expect(editor.activeDoc().preview);
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, "readme.md"));
    try t.expectEqual(@as(usize, 1), editor.docCount()); // preview has no tab

    // Escape restores exactly the pre-finder state
    editor.finderCancel();
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqual(@as(usize, 1), editor.documents.items.len);
    try t.expectEqual(@as(usize, 0), editor.active_doc_idx);
    try t.expectEqual(@as(usize, 0), editor.finder_files.items.len);

    // Commit promotes the preview to a real tab
    editor.finderOpen();
    @memcpy(editor.finder_buf[0..5], "alpha");
    editor.finder_buf_len = 5;
    editor.finderRefresh();
    try t.expect(editor.finder_preview_appended);
    editor.finderCommit();
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    try t.expect(!editor.activeDoc().preview);
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, "alpha.zig"));
    try t.expectEqual(@as(usize, 2), editor.docCount());

    // Selecting an already-open file shows its real tab — no preview doc
    editor.finderOpen();
    @memcpy(editor.finder_buf[0..5], "alpha");
    editor.finder_buf_len = 5;
    editor.finderRefresh();
    try t.expect(!editor.finder_preview_appended);
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    editor.finderCommit();
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, "alpha.zig"));
}

test "windows: primary only after init, splits stay in the focused window" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try t.expectEqual(@as(usize, 1), editor.windows.items.len);
    try t.expectEqual(@as(u32, 0), editor.windows.items[0].id);
    try t.expectEqual(@as(usize, 0), editor.active_window);
    try t.expect(editor.isActivePane(0, 0));
    try t.expect(!editor.isActivePane(1, 0));
    try t.expectEqual(@as(usize, 1), editor.activeLayout().paneCount());

    editor.splitActive(.horizontal);
    try t.expectEqual(@as(usize, 2), editor.windows.items[0].layout.paneCount());
    try t.expectEqual(editor.windows.items[0].active_pane, editor.activePaneId());
    try t.expectEqual(@as(usize, 0), editor.windowDocIdx(0));
    editor.closePaneAction();
    try t.expectEqual(@as(usize, 1), editor.activeLayout().paneCount());
    try t.expect(editor.activeLayout().findLeafNode(editor.activePaneId()) != null);
}

test "finder cancel repoints a pane split while the preview was showing" {
    const t = std.testing;
    const root = ".zig-cache/zide-test-finder-split";
    std.Io.Dir.cwd().createDirPath(t.io, root) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(t.io, root ++ "/beta.zig", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "const b = 2;\n");
    }
    defer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.filetree_root = try t.allocator.dupe(u8, root);

    editor.finderOpen();
    @memcpy(editor.finder_buf[0..4], "beta");
    editor.finder_buf_len = 4;
    editor.finderRefresh();
    try t.expect(editor.finder_preview_appended);
    const preview_idx = editor.documents.items.len - 1;
    // A split made while the finder is open shows the preview document too
    editor.splitActive(.horizontal);
    for (editor.activeLayout().panes.items) |pane| {
        try t.expectEqual(preview_idx, pane.content.editor);
    }
    // Escape pops the preview — no pane may keep pointing past the end
    editor.finderCancel();
    try t.expectEqual(@as(usize, 1), editor.documents.items.len);
    for (editor.activeLayout().panes.items) |pane| {
        try t.expect(pane.content.editor < editor.documents.items.len);
    }
    try t.expectEqual(@as(usize, 0), editor.active_doc_idx);
}

test "windows: unsupported frontend falls back to splits" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try t.expectError(error.Unsupported, editor.newWindow(.{ .editor = 0 }));
    try t.expect(editor.execAction("open_in_new_window"));
    try t.expectEqual(@as(usize, 1), editor.windows.items.len);
    try t.expectEqual(@as(usize, 2), editor.activeLayout().paneCount());
    try t.expect(editor.execAction("move_pane_to_new_window"));
    try t.expectEqual(@as(usize, 1), editor.windows.items.len);
    try t.expectEqual(@as(usize, 3), editor.activeLayout().paneCount());
}

test "windows: open_in_new_window shows the active document in a new window" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    _ = try editor.newDocument();
    try t.expectEqual(@as(usize, 1), editor.active_doc_idx);
    try t.expect(editor.execAction("open_in_new_window"));
    try t.expectEqual(@as(usize, 2), editor.windows.items.len);
    try t.expectEqual(@as(usize, 1), editor.active_window);
    try t.expectEqual(@as(u32, 1), editor.windows.items[1].id);
    try t.expectEqual(@as(usize, 1), editor.windowDocIdx(1));
    // The view moved: the source pane shows the neighbouring document
    try t.expectEqual(@as(usize, 0), editor.windowDocIdx(0));
    try t.expect(editor.isActivePane(1, 0));
    try t.expect(!editor.isActivePane(0, 0));
    var buf: [64]u8 = undefined;
    try t.expect(std.mem.startsWith(u8, editor.windowTitle(1, &buf), "ZIDE — "));
}

test "windows: each window owns its tabs (open, cycle, move, close window)" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    // The primary owns the initial document.
    try t.expectEqualSlices(usize, &.{0}, editor.windows.items[0].tabs.items);
    // Moving the sole document out: its tab goes along; the primary cannot
    // show nothing and gets a fresh untitled document.
    try t.expect(editor.execAction("open_in_new_window"));
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    try t.expectEqualSlices(usize, &.{1}, editor.windows.items[0].tabs.items);
    try t.expectEqualSlices(usize, &.{0}, editor.windows.items[1].tabs.items);
    try t.expectEqual(@as(usize, 1), editor.windowDocIdx(0));
    try t.expectEqual(@as(usize, 0), editor.windowDocIdx(1));
    // New documents join the window they were opened in (the child here).
    _ = try editor.newDocument(); // 2
    try t.expectEqualSlices(usize, &.{ 0, 2 }, editor.windows.items[1].tabs.items);
    try t.expectEqual(@as(?usize, 1), editor.docWindow(2));
    // Ctrl+Tab cycles within the window only.
    editor.nextDoc();
    try t.expectEqual(@as(usize, 0), editor.windowDocIdx(1));
    editor.nextDoc();
    try t.expectEqual(@as(usize, 2), editor.windowDocIdx(1));
    editor.prevDoc();
    try t.expectEqual(@as(usize, 0), editor.windowDocIdx(1));
    editor.focusWindow(0);
    editor.nextDoc(); // a single tab: nothing to cycle
    try t.expectEqual(@as(usize, 1), editor.windowDocIdx(0));
    // Showing a document in another window moves its tab (a tab drop); the
    // old owner's pane switches to the neighbouring tab.
    editor.showDocIn(0, 0);
    try t.expectEqualSlices(usize, &.{ 1, 0 }, editor.windows.items[0].tabs.items);
    try t.expectEqualSlices(usize, &.{2}, editor.windows.items[1].tabs.items);
    try t.expectEqual(@as(usize, 2), editor.windowDocIdx(1));
    try t.expectEqual(@as(usize, 0), editor.windowDocIdx(0));
    // Closing a window hands its tabs back to the primary — documents stay.
    try t.expect(editor.closeWindow(1));
    try t.expectEqual(@as(usize, 3), editor.documents.items.len);
    try t.expectEqualSlices(usize, &.{ 1, 0, 2 }, editor.windows.items[0].tabs.items);
}

test "windows: closing tabs — the owner's neighbour takes over; the last tab closes a secondary" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    _ = try editor.newDocument(); // 1
    _ = try editor.newDocument(); // 2
    _ = try editor.newDocument(); // 3
    // Move 2 and 3 into a child window: tabs [2, 3]
    editor.showDocInNewWindow(2);
    editor.showDocIn(1, 3);
    try t.expectEqualSlices(usize, &.{ 0, 1 }, editor.windows.items[0].tabs.items);
    try t.expectEqualSlices(usize, &.{ 2, 3 }, editor.windows.items[1].tabs.items);
    try t.expectEqual(@as(usize, 3), editor.windowDocIdx(1));
    // Close 3 (the child's active tab): its neighbour 2 takes over the pane.
    try t.expect(editor.closeDocAt(3));
    try t.expectEqual(@as(usize, 2), editor.windowDocIdx(1));
    try t.expectEqualSlices(usize, &.{2}, editor.windows.items[1].tabs.items);
    // Close the child's last tab: the window is asked to close.
    try t.expect(editor.closeDocAt(2));
    try t.expect(!editor.windows.items[1].open);
    editor.retireClosedWindows();
    try t.expectEqual(@as(usize, 1), editor.windows.items.len);
    try t.expectEqualSlices(usize, &.{ 0, 1 }, editor.windows.items[0].tabs.items);
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    // Closing the primary's last tab while a child holds the other document:
    // the primary gets a fresh untitled rather than stealing the child's.
    editor.showDocInNewWindow(1); // child owns 1; primary [0]
    editor.focusWindow(0);
    try t.expect(editor.closeDocAt(0));
    try t.expectEqual(@as(usize, 2), editor.documents.items.len); // 0 = the child's (shifted), 1 = fresh
    try t.expectEqualSlices(usize, &.{1}, editor.windows.items[0].tabs.items);
    try t.expectEqualSlices(usize, &.{0}, editor.windows.items[1].tabs.items);
    try t.expectEqual(@as(usize, 1), editor.windowDocIdx(0));
    try t.expectEqual(@as(usize, 0), editor.windowDocIdx(1));
    // The Settings dialog belongs to the window it was opened from, survives
    // a window switch, and falls back to the primary when that window closes.
    editor.focusWindow(1);
    try t.expect(editor.execAction("settings"));
    try t.expectEqual(editor.windows.items[1].id, editor.settings_window_id);
    editor.focusWindow(0);
    try t.expectEqual(Editor.Mode.settings, editor.mode);
    try t.expect(editor.closeWindow(1));
    try t.expectEqual(@as(u32, 0), editor.settings_window_id);
    editor.mode = .normal;
}

test "windows: closeDocAt repoints panes in every window" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    _ = try editor.newDocument(); // 1
    _ = try editor.newDocument(); // 2
    _ = try editor.newWindow(.{ .editor = 2 });
    editor.focusWindow(0);
    editor.switchToDoc(1);
    try t.expect(editor.closeDocAt(1));
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    // The secondary showed doc 2 → shifted down to 1
    try t.expectEqual(@as(usize, 1), editor.windows.items[1].layout.panes.items[0].content.editor);
    // The primary showed the removed doc → a live index
    try t.expect(editor.windows.items[0].layout.panes.items[0].content.editor < editor.documents.items.len);
}

test "windows: movePaneToNewWindow leaves a view behind only for a sole pane" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    editor.movePaneToNewWindow();
    try t.expectEqual(@as(usize, 2), editor.windows.items.len);
    try t.expectEqual(@as(usize, 1), editor.windows.items[0].layout.paneCount());
    try t.expectEqual(@as(usize, 1), editor.active_window);

    editor.focusWindow(0);
    editor.splitActive(.horizontal);
    try t.expectEqual(@as(usize, 2), editor.windows.items[0].layout.paneCount());
    editor.movePaneToNewWindow();
    try t.expectEqual(@as(usize, 3), editor.windows.items.len);
    try t.expectEqual(@as(usize, 1), editor.windows.items[0].layout.paneCount());
    const primary = editor.windows.items[0];
    try t.expect(primary.layout.findLeafNode(primary.active_pane) != null);
}

test "windows: cap on secondary windows" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    editor.max_secondary_windows = 2;
    _ = try editor.newWindow(.{ .editor = 0 });
    _ = try editor.newWindow(.{ .editor = 0 });
    try t.expectError(error.TooManyWindows, editor.newWindow(.{ .editor = 0 }));
    try t.expect(std.mem.startsWith(u8, editor.status_message, "Window limit reached"));
    try t.expectEqual(@as(usize, 3), editor.windows.items.len);
}

test "windows: closeWindow keeps focus valid and never reuses ids" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    const a = try editor.newWindow(.{ .editor = 0 }); // id 1
    const b = try editor.newWindow(.{ .editor = 0 }); // id 2
    try t.expectEqual(@as(usize, 2), b);
    try t.expect(!editor.closeWindow(0));
    try t.expect(editor.closeWindow(a)); // active (b) shifts down
    try t.expectEqual(@as(usize, 1), editor.active_window);
    try t.expectEqual(@as(u32, 2), editor.windows.items[1].id);
    const c = try editor.newWindow(.{ .editor = 0 });
    try t.expectEqual(@as(u32, 3), editor.windows.items[c].id);
    try t.expect(editor.closeWindow(editor.active_window));
    try t.expectEqual(@as(usize, 0), editor.active_window);
    // The moved document's tab came back to the primary, which kept showing
    // the untitled document it received when its only tab left.
    try t.expectEqual(@as(usize, 1), editor.active_doc_idx);
    try t.expectEqualSlices(usize, &.{ 1, 0 }, editor.windows.items[0].tabs.items);
}

test "windows: requestCloseWindow defers to the reap; the primary routes to quit" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    const w = try editor.newWindow(.{ .editor = 0 });
    editor.requestCloseWindow(w);
    try t.expectEqual(@as(usize, 2), editor.windows.items.len);
    try t.expect(!editor.windows.items[w].open);
    editor.retireClosedWindows();
    try t.expectEqual(@as(usize, 1), editor.windows.items.len);
    try t.expectEqual(@as(usize, 0), editor.active_window);

    editor.requestCloseWindow(0);
    try t.expect(!editor.running);
    editor.running = true;
    editor.activeDoc().dirty = true;
    editor.requestCloseWindow(0);
    try t.expect(editor.running);
    try t.expectEqual(Editor.Mode.confirm_quit, editor.mode);
    editor.activeDoc().dirty = false;
}

test "windows: close_pane on the sole pane of a secondary requests its close" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    const w = try editor.newWindow(.{ .editor = 0 });
    try t.expect(editor.execAction("close_pane"));
    try t.expect(!editor.windows.items[w].open);
    editor.retireClosedWindows();
    try t.expectEqual(@as(usize, 1), editor.windows.items.len);
    // In the primary the sole pane stays and the status bar explains
    try t.expect(editor.execAction("close_pane"));
    try t.expectEqual(@as(usize, 1), editor.windows.items.len);
    try t.expect(editor.status_message.len > 0);
}

test "windows: a terminal-only secondary closes with its terminal" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    // Fake terminal slots — Terminal.init would fork a shell.
    try editor.terminals.append(t.allocator, null);
    try editor.terminals.append(t.allocator, null);
    const w = try editor.newWindow(.{ .terminal = 1 });
    try t.expect(editor.activePaneIsTerminal());
    try t.expectEqual(@as(?usize, 1), editor.activePaneTerminalIdx());
    try t.expect(editor.execAction("toggle_terminal"));
    try t.expectEqualStrings("No editor pane in this window", editor.status_message);
    // close_terminal on the sole pane → window requested closed, reaped later
    try t.expect(editor.execAction("close_terminal"));
    try t.expect(!editor.windows.items[w].open);
    try t.expectEqual(@as(usize, 2), editor.windows.items.len);
    editor.retireClosedWindows();
    try t.expectEqual(@as(usize, 1), editor.windows.items.len);
    try t.expectEqual(@as(usize, 2), editor.terminals.items.len);
}

test "windows: paneShowDoc never replaces a terminal pane" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.terminals.append(t.allocator, null);
    editor.windows.items[0].layout.panes.items[0].content = .{ .terminal = 0 };
    try t.expect(editor.activePaneIsTerminal());
    editor.switchToDoc(0);
    // An editor pane was split in; the terminal view survived
    try t.expectEqual(@as(usize, 2), editor.activeLayout().paneCount());
    try t.expect(!editor.activePaneIsTerminal());
    var terminals: usize = 0;
    for (editor.activeLayout().panes.items) |pane| {
        if (pane.content == .terminal) terminals += 1;
    }
    try t.expectEqual(@as(usize, 1), terminals);
    // With an editor pane present the document goes there and focus follows
    editor.focusPane(0);
    try t.expect(editor.activePaneIsTerminal());
    editor.switchToDoc(0);
    try t.expectEqual(@as(usize, 2), editor.activeLayout().paneCount());
    try t.expect(!editor.activePaneIsTerminal());
}

test "windows: switching windows cancels transient prompts; stale completions are refused" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    editor.mode = .goto_line;
    _ = try editor.newWindow(.{ .editor = 0 }); // focusWindow(1) cancels the prompt
    try t.expectEqual(Editor.Mode.normal, editor.mode);

    _ = try editor.newDocument();
    editor.completion_doc_idx = 0; // computed for doc 0, doc 1 is active now
    try editor.addCompletionItem(try t.allocator.dupe(u8, "foo"), null, null);
    try t.expect(editor.completion_active);
    editor.acceptCompletion();
    try t.expect(!editor.completion_active);
    try t.expectEqual(@as(usize, 0), editor.completion_items.items.len);
}

test "windows: detach_terminal guard, move, and terminal passthrough chords" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.keybinds.loadDefaults();
    editor.multi_window_supported = true;
    try t.expect(editor.execAction("detach_terminal"));
    try t.expectEqualStrings("Focus a terminal pane to detach it", editor.status_message);
    try t.expectEqual(@as(usize, 1), editor.windows.items.len);

    try editor.terminals.append(t.allocator, null);
    editor.windows.items[0].layout.panes.items[0].content = .{ .terminal = 0 };
    try t.expect(editor.execAction("detach_terminal"));
    try t.expectEqual(@as(usize, 2), editor.windows.items.len);
    try t.expectEqual(@as(usize, 1), editor.active_window);
    try t.expect(editor.activePaneIsTerminal());
    // The primary kept an editor view — a terminal is never shown twice
    try t.expect(editor.windows.items[0].layout.panes.items[0].content == .editor);

    // Terminal panes let the management chords through, nothing else
    try t.expectEqualStrings("toggle_terminal", editor.terminalPassthroughAction("ctrl+`").?);
    try t.expectEqualStrings("detach_terminal", editor.terminalPassthroughAction("ctrl+alt+`").?);
    try t.expectEqualStrings("close_pane", editor.terminalPassthroughAction("ctrl+alt+q").?);
    try t.expect(editor.terminalPassthroughAction("ctrl+s") == null);
    try t.expect(editor.terminalPassthroughAction("ctrl+c") == null);
}

/// Test helper: bounded wait for the search worker to finish.
fn waitSearch(sp: *search_mod.SearchPanel) void {
    var spins: usize = 0;
    while (sp.searching and spins < 10_000_000) : (spins += 1) {
        _ = sp.drain();
        std.Thread.yield() catch {};
    }
    _ = sp.drain();
}

test "workspace search and replace end to end" {
    const t = std.testing;
    const root = ".zig-cache/zide-test-search";
    std.Io.Dir.cwd().createDirPath(t.io, root ++ "/sub") catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(t.io, root ++ "/a.txt", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "the cat sat\nno match here\ncat again\n");
    }
    {
        const f = try std.Io.Dir.cwd().createFile(t.io, root ++ "/sub/b.zig", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "// cat in zig\n");
    }
    defer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.filetree_root = try t.allocator.dupe(u8, root);

    // Open a.txt and edit the buffer — the search must see the buffer,
    // not the stale disk copy.
    const doc0 = try editor.openFile(root ++ "/a.txt");
    try doc0.insertAtCursor("cat extra\n");

    const sp = &editor.search;
    @memcpy(sp.query_buf[0..3], "cat");
    sp.query_len = 3;
    sp.start(&editor);
    waitSearch(sp);
    // 3 buffer hits in a.txt (2 original + 1 typed) + 1 in b.zig on disk;
    // a.txt's disk copy is skipped because the doc is open.
    try t.expectEqual(@as(usize, 4), sp.matches.items.len);
    try t.expectEqual(@as(usize, 2), sp.paths.items.len);

    // Exclude filter drops disk-walked files (open docs always searched)
    @memcpy(sp.exclude_buf[0..5], "*.zig");
    sp.exclude_len = 5;
    sp.start(&editor);
    waitSearch(sp);
    try t.expectEqual(@as(usize, 3), sp.matches.items.len);
    sp.exclude_len = 0;
    sp.start(&editor);
    waitSearch(sp);
    try t.expectEqual(@as(usize, 4), sp.matches.items.len);

    // Jump to the b.zig hit: opens the file with the match selected
    var zig_idx: usize = 0;
    for (sp.matches.items, 0..) |m, i| {
        if (std.mem.endsWith(u8, sp.paths.items[m.path_idx], "b.zig")) zig_idx = i;
    }
    sp.selected = zig_idx;
    editor.searchOpenSelected();
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, "b.zig"));
    try t.expectEqualStrings("cat", editor.activeDoc().selectedText().?);

    // Replace in open docs only: a.txt buffer changes, b.zig untouched...
    // except b.zig is now open too (we just jumped into it) — so replace
    // open-only converts every open buffer and leaves nothing on disk.
    @memcpy(sp.replace_buf[0..3], "dog");
    sp.replace_len = 3;
    editor.searchExecuteReplace(.open_only);
    waitSearch(sp);
    try t.expectEqual(@as(usize, 0), sp.matches.items.len);
    const adoc = &editor.documents.items[1]; // a.txt (0 = initial untitled)
    const atext = adoc.buffer.slice(0, adoc.buffer.byteLen());
    try t.expect(std.mem.indexOf(u8, atext, "cat") == null);
    try t.expect(std.mem.indexOf(u8, atext, "dog") != null);
    try t.expect(adoc.dirty);

    // Disk-scope replace: put a needle in an unopened file and replace .all
    {
        const f = try std.Io.Dir.cwd().createFile(t.io, root ++ "/sub/c.txt", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "closed cat file\n");
    }
    sp.start(&editor);
    waitSearch(sp);
    try t.expectEqual(@as(usize, 1), sp.matches.items.len);
    editor.searchExecuteReplace(.all);
    waitSearch(sp);
    try t.expectEqual(@as(usize, 0), sp.matches.items.len);
    const rewritten = try std.Io.Dir.cwd().readFileAlloc(t.io, root ++ "/sub/c.txt", t.allocator, .limited(4096));
    defer t.allocator.free(rewritten);
    try t.expectEqualStrings("closed dog file\n", rewritten);
}

test "close tab: a dirty document prompts; discard closes, cancel keeps it" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    _ = try editor.newDocument(); // index 1, active
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    // Clean: closes at once
    try t.expect(editor.execAction("close_tab"));
    try t.expectEqual(@as(usize, 1), editor.documents.items.len);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    // Dirty: prompts instead
    const d2 = try editor.newDocument();
    try d2.insertAtCursor("draft");
    try t.expect(editor.execAction("close_tab"));
    try t.expectEqual(Editor.Mode.confirm_close, editor.mode);
    try t.expectEqual(@as(usize, 1), editor.confirm_close_doc);
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    // Cancel keeps the tab
    try t.expectEqual(Editor.CloseOutcome.kept, editor.resolveCloseDoc(.cancel));
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    try t.expect(editor.documents.items[1].dirty);
    // A tab's × names an index; discard closes it
    try t.expect(!editor.requestCloseDoc(1));
    try t.expectEqual(Editor.Mode.confirm_close, editor.mode);
    try t.expectEqual(Editor.CloseOutcome.closed, editor.resolveCloseDoc(.discard));
    try t.expectEqual(@as(usize, 1), editor.documents.items.len);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    // Untitled + Save: the frontend must run Save As; the document stays and becomes active
    const d3 = try editor.newDocument();
    try d3.insertAtCursor("draft");
    editor.switchToDoc(0);
    try t.expect(!editor.requestCloseDoc(1));
    try t.expectEqual(Editor.CloseOutcome.needs_path, editor.resolveCloseDoc(.save));
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    try t.expectEqual(@as(usize, 1), editor.active_doc_idx);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    // A prompt whose document vanished resolves to nothing
    editor.confirm_close_doc = 7;
    editor.mode = .confirm_close;
    try t.expectEqual(Editor.CloseOutcome.kept, editor.resolveCloseDoc(.discard));
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
}

test "close tab: Save writes the file and closes the tab" {
    const t = std.testing;
    const path = ".zig-cache/zide-test-close-save.txt";
    {
        const f = try std.Io.Dir.cwd().createFile(t.io, path, .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "one\n");
    }
    defer std.Io.Dir.cwd().deleteFile(t.io, path) catch {};
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = try editor.openFile(path);
    try doc.insertAtCursor("two ");
    try t.expect(doc.dirty);
    try t.expect(!editor.requestCloseDoc(editor.active_doc_idx));
    try t.expectEqual(Editor.Mode.confirm_close, editor.mode);
    try t.expectEqual(Editor.CloseOutcome.closed, editor.resolveCloseDoc(.save));
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    // Only an untitled buffer remains (the last document is always replaced by one)
    try t.expectEqual(@as(usize, 1), editor.documents.items.len);
    try t.expect(editor.documents.items[0].file_path == null);
    const written = try std.Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(4096));
    defer t.allocator.free(written);
    try t.expectEqualStrings("two one\n", written);
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

fn testWriteFile(dir: std.Io.Dir, path: []const u8, text: []const u8) !void {
    const file = try dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, text);
}

test "save and quit preflights all files and conflict resolution never resumes quit" {
    const t = std.testing;
    for ([_]Editor.OverwriteChoice{ .cancel, .reload, .overwrite }) |choice| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, t.io, ".", t.allocator);
        defer t.allocator.free(root);
        const a = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
        defer t.allocator.free(a);
        const b = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
        defer t.allocator.free(b);
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        try editor.activeDoc().loadText("a");
        try editor.activeDoc().saveAs(t.io, a);
        try editor.activeDoc().insertAtCursor("local ");
        _ = try editor.newDocument();
        try editor.activeDoc().loadText("b");
        try editor.activeDoc().saveAs(t.io, b);
        try editor.activeDoc().insertAtCursor("local ");
        try testWriteFile(tmp.dir, "b.txt", "external");
        // Guarantee a stale stamp independent of filesystem timestamp precision.
        editor.activeDoc().disk_mtime = -1;
        editor.switchToDoc(0);
        editor.saveAllAndQuit();
        try t.expect(editor.running);
        try t.expectEqual(Editor.Mode.confirm_overwrite, editor.mode);
        try t.expectEqual(@as(usize, 1), editor.confirm_overwrite_doc);
        const first = try tmp.dir.readFileAlloc(t.io, "a.txt", t.allocator, .limited(100));
        defer t.allocator.free(first);
        try t.expectEqualStrings("a", first);
        const second = try tmp.dir.readFileAlloc(t.io, "b.txt", t.allocator, .limited(100));
        defer t.allocator.free(second);
        try t.expectEqualStrings("external", second);
        editor.resolveOverwrite(choice);
        try t.expect(editor.running);
        try t.expectEqual(Editor.Mode.normal, editor.mode);
        if (choice != .cancel) {
            editor.saveAllAndQuit();
            try t.expect(!editor.running);
            try t.expect(!editor.hasUnsavedChanges());
        } else {
            try t.expectEqual(@as(usize, 1), editor.autoSaveAll());
            try t.expect(editor.documents.items[1].dirty);
            try t.expect(editor.documents.items[1].external_changed);
        }
    }
}

test "save and quit keeps untitled files and survives a failed write after a successful one" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.activeDoc().insertAtCursor("draft");
    editor.saveAllAndQuit();
    try t.expect(editor.running);
    try t.expect(editor.activeDoc().dirty);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(path);
    try editor.activeDoc().saveAs(t.io, path);
    try editor.activeDoc().insertAtCursor("local ");
    _ = try editor.newDocument();
    try editor.activeDoc().insertAtCursor("unsaved");
    try editor.activeDoc().setFilePath(root); // an existing directory cannot be written as a file
    editor.saveAllAndQuit();
    try t.expect(editor.running);
    try t.expect(!editor.documents.items[0].dirty);
    try t.expect(editor.documents.items[1].dirty);
}

test "externally deleted buffers stay dirty after undo returns to the old checkpoint" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "deleted.txt" });
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("a");
    try doc.saveAs(t.io, path);
    try doc.insertAtCursor("x");
    try tmp.dir.deleteFile(t.io, "deleted.txt");
    editor.pollExternalChanges();
    _ = try doc.undoAction();
    try t.expect(doc.dirty);
    editor.saveAllAndQuit();
    try t.expect(editor.running);
    try t.expectEqual(Editor.Mode.confirm_overwrite, editor.mode);
}

fn testLoadCompletion(editor: *Editor, json: []const u8) !void {
    editor.clearCompletionItems();
    editor.completion_doc_idx = editor.activeDocIdx();
    const items = try lsp_mod.parseCompletionItems(std.testing.allocator, json);
    defer std.testing.allocator.free(items);
    for (items) |item| try editor.addCompletionEntry(item);
}

test "completion applies textEdit range and newText as one reversible edit" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("foobar");
    doc.cursors.primary().offset = 3;
    try testLoadCompletion(&editor,
        \\{"result":[{"label":"foobaz","insertText":"wrong","textEdit":{"newText":"foobaz","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":6}}}}]}
    );
    editor.acceptCompletion();
    try t.expectEqualStrings("foobaz", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqual(@as(usize, 6), doc.cursors.primary().offset);
    _ = try doc.undoAction();
    try t.expectEqualStrings("foobar", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqual(@as(usize, 3), doc.cursors.primary().offset);
    try t.expect(!doc.history.canUndo());
    _ = try doc.redoAction();
    try t.expectEqualStrings("foobaz", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "completion supports UTF-16 insert-replace edits and rejects invalid positions" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    const original = "\xf0\x9f\x98\x80foobar";
    try doc.loadText(original);
    doc.cursors.primary().offset = 7;
    try testLoadCompletion(&editor,
        \\{"result":[{"label":"foobaz","textEdit":{"newText":"foobaz","insert":{"start":{"line":0,"character":2},"end":{"line":0,"character":5}},"replace":{"start":{"line":0,"character":2},"end":{"line":0,"character":8}}}}]}
    );
    editor.acceptCompletion();
    try t.expectEqualStrings("\xf0\x9f\x98\x80foobaz", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = try doc.undoAction();
    const invalid = [_][]const u8{
        \\{"result":[{"label":"bad","textEdit":{"newText":"bad","range":{"start":{"line":0,"character":1},"end":{"line":0,"character":8}}}}]}
        ,
        \\{"result":[{"label":"bad","textEdit":{"newText":"bad","range":{"start":{"line":0,"character":2},"end":{"line":0,"character":90}}}}]}
        ,
        \\{"result":[{"label":"bad","textEdit":{"newText":"bad","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":2}}}}]}
        ,
    };
    for (invalid) |json| {
        try testLoadCompletion(&editor, json);
        editor.acceptCompletion();
        try t.expectEqualStrings(original, doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expect(!doc.history.canUndo());
    }
}

test "completion fallback works and stale responses cannot target reused tabs" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.activeDoc().loadText("foo");
    editor.activeDoc().cursors.primary().offset = 3;
    try testLoadCompletion(&editor, "{\"result\":[{\"label\":\"foobaz\"}]}");
    editor.acceptCompletion();
    try t.expectEqualStrings("foobaz", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    _ = try editor.activeDoc().undoAction();
    try testLoadCompletion(&editor, "{\"result\":[{\"label\":\"foobaz\"}]}");
    editor.completion_context.?.request_id = 2;
    try t.expect(!editor.completionResponseCurrent(null, 1));
    try t.expect(editor.completionResponseCurrent(null, 2));
    try editor.activeDoc().insertAtCursor("x");
    try t.expect(!editor.completionResponseCurrent(null, 2));
    editor.acceptCompletion();
    try t.expectEqualStrings("foox", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    try testLoadCompletion(&editor, "{\"result\":[{\"label\":\"foobaz\"}]}");
    editor.activeDoc().cursors.primary().moveLeft(&editor.activeDoc().buffer);
    editor.acceptCompletion();
    try t.expectEqualStrings("foox", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    try testLoadCompletion(&editor, "{\"result\":[{\"label\":\"foobaz\"}]}");
    _ = editor.closeDocAt(0); // replace the last tab with a different document ID
    editor.acceptCompletion();
    try t.expectEqual(@as(usize, 0), editor.activeDoc().buffer.byteLen());
}

test "shared find replaces empty text and visits adjacent and wrapped Unicode matches" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.activeDoc().loadText("éé é");
    text_input.set(&editor.find_buf, &editor.find_buf_len, "é");
    editor.findIncremental();
    try t.expectEqual(@as(usize, 2), editor.activeDoc().cursors.primary().offset);
    editor.findNext();
    try t.expectEqual(@as(usize, 4), editor.activeDoc().cursors.primary().offset);
    editor.replaceOne();
    try t.expectEqualStrings("é é", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    try t.expectEqual(@as(usize, 5), editor.activeDoc().cursors.primary().offset);
    _ = try editor.activeDoc().undoAction();
    try t.expectEqual(@as(usize, 4), editor.activeDoc().cursors.primary().offset);
    _ = try editor.activeDoc().redoAction();
    try t.expectEqual(@as(usize, 5), editor.activeDoc().cursors.primary().offset);
    editor.findNext();
    try t.expectEqual(@as(usize, 2), editor.activeDoc().cursors.primary().offset);
    try t.expectEqualStrings("Search wrapped", editor.status_message);
}

test "encoding picker preserves stable targets and dirty reopen cancellation" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "café.txt" });
    defer t.allocator.free(path);
    try text_file.atomicWrite(t.allocator, t.io, path, "caf\xe9");
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try t.expectError(error.EncodingRequired, editor.openFile(path));
    try t.expectEqual(Editor.Mode.encoding_picker, editor.mode);
    try t.expectEqual(@as(usize, 1), editor.documents.items.len);
    editor.cancelEncoding();
    try t.expectEqual(@as(usize, 1), editor.documents.items.len);
    try t.expectError(error.EncodingRequired, editor.openFile(path));
    editor.chooseEncoding(4);
    const id = editor.activeDoc().id;
    try t.expectEqualStrings("café", editor.activeDoc().buffer.slice(0, 5));
    try t.expectEqual(@as(?text_file.TextEncoding, .windows1252), editor.knownEncoding(path));
    try editor.activeDoc().insertAtCursor("draft ");
    editor.startEncoding(.reopen);
    editor.chooseEncoding(0);
    try t.expectEqual(Editor.Mode.confirm_reopen, editor.mode);
    editor.resolveReopen(.cancel);
    try t.expect(editor.activeDoc().dirty);
    editor.startEncoding(.reopen);
    editor.chooseEncoding(0);
    editor.resolveReopen(.discard); // Invalid UTF-8 leaves the draft intact.
    try t.expectEqualStrings("draft café", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    try t.expect(editor.activeDoc().history.canUndo());
    editor.startEncoding(.save);
    _ = try editor.newDocument();
    try editor.activeDoc().insertAtCursor("other tab");
    const other = editor.activeDoc().id;
    editor.chooseEncoding(2);
    const idx = editor.docIndexForId(id).?;
    try t.expectEqualDeep(text_file.TextFormat{ .encoding = .utf16_le, .bom = true }, editor.documents.items[idx].format);
    try t.expect(!editor.documents.items[idx].dirty);
    try t.expect(editor.documents.items[editor.docIndexForId(other).?].dirty);
    editor.switchToDoc(idx);
    editor.activeDoc().cursors.primary().offset = 0;
    try editor.activeDoc().insertAtCursor("saved ");
    editor.startEncoding(.reopen);
    editor.chooseEncoding(2);
    editor.resolveReopen(.save);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(!editor.activeDoc().dirty);
    try t.expectEqualStrings("saved draft café", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
}

test "reopen waits for its decision and save hooks cannot redirect or discard edits" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "hooks.txt" });
    defer t.allocator.free(path);
    for ([_]bool{ false, true }) |edit_in_hook| {
        try text_file.write(t.allocator, t.io, path, "café", .{ .encoding = .windows1252 });
        var lua = try zlua.Lua.init(t.allocator);
        defer lua.deinit();
        lua.openLibs();
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        @import("lua_settings.zig").registerApi(lua, &editor);
        const original = try editor.openFileWithEncoding(path, .windows1252, false);
        const id = original.id;
        try original.insertAtCursor("draft ");
        editor.startEncoding(.reopen);
        editor.chooseEncoding(4);
        try t.expectEqual(Editor.Mode.confirm_reopen, editor.mode);
        try t.expectEqual(@as(usize, 0), editor.autoSaveAll());
        try t.expectEqual(Editor.Mode.confirm_reopen, editor.mode);
        try t.expect(original.dirty);
        const before = try tmp.dir.readFileAlloc(t.io, "hooks.txt", t.allocator, .limited(100));
        defer t.allocator.free(before);
        try t.expectEqualStrings("caf\xe9", before);
        if (edit_in_hook) {
            try lua.doString("zide.on('save', function() zide.insert('hook ') end)");
        } else {
            _ = try editor.newDocument();
            editor.multi_window_supported = true;
            const window = try editor.newWindow(.{ .editor = editor.activeDocIdx() });
            editor.focusWindow(window);
            try t.expectEqual(Editor.Mode.confirm_reopen, editor.mode);
            try lua.doString("zide.on('save', function() zide.exec('new_document'); zide.insert('hook tab') end)");
        }
        editor.resolveReopen(.save);
        const doc = &editor.documents.items[editor.docIndexForId(id).?];
        try t.expectEqual(Editor.Mode.normal, editor.mode);
        try t.expectEqual(edit_in_hook, doc.dirty);
        try t.expectEqualStrings(if (edit_in_hook) "draft hook café" else "draft café", doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expect(editor.encoding_doc_id == null);
        try t.expect(editor.pending_save_id == null);
        if (edit_in_hook) {
            try t.expectEqualStrings("Document changed during save; reopen cancelled", editor.status_message);
            try t.expect(doc.history.canUndo());
        } else {
            try t.expect(editor.activeDoc().id != id);
            try t.expectEqualStrings("hook tab", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
        }
        const after = try tmp.dir.readFileAlloc(t.io, "hooks.txt", t.allocator, .limited(100));
        defer t.allocator.free(after);
        try t.expectEqualStrings("draft caf\xe9", after);
    }
}

test "encoding save handles untitled paths conflicts and unrepresentable text without retargeting" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "new.txt" });
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.activeDoc().insertAtCursor("😀");
    const id = editor.activeDoc().id;
    editor.startEncoding(.save);
    editor.chooseEncoding(4);
    try t.expectEqual(Editor.Mode.save_as, editor.mode);
    _ = try editor.newDocument();
    try t.expectEqual(Editor.SaveOutcome.unrepresentable, editor.finishSaveAs(path));
    try t.expectEqual(Editor.Mode.confirm_encoding, editor.mode);
    try t.expect(editor.documents.items[editor.docIndexForId(id).?].file_path == null);
    editor.resolveEncodingSave(false);
    editor.switchToDoc(editor.docIndexForId(id).?);
    editor.startEncoding(.save);
    editor.chooseEncoding(4);
    try t.expectEqual(Editor.SaveOutcome.unrepresentable, editor.finishSaveAs(path));
    editor.switchToDoc(1);
    editor.resolveEncodingSave(true);
    const doc = &editor.documents.items[editor.docIndexForId(id).?];
    try t.expectEqualStrings(path, doc.file_path.?);
    try t.expectEqualDeep(text_file.TextFormat{}, doc.format);
    try t.expect(!doc.dirty);
    try doc.insertAtCursor("x");
    try text_file.atomicWrite(t.allocator, t.io, path, "external");
    doc.external_changed = true;
    editor.switchToDoc(editor.docIndexForId(id).?);
    editor.startEncoding(.save);
    editor.chooseEncoding(3);
    try t.expectEqual(Editor.Mode.confirm_overwrite, editor.mode);
    editor.resolveOverwrite(.cancel);
    try t.expectEqualDeep(text_file.TextFormat{}, doc.format);
    editor.startEncoding(.save);
    editor.chooseEncoding(3);
    editor.switchToDoc(1);
    editor.multi_window_supported = true;
    _ = try editor.newWindow(.{ .editor = 1 });
    try t.expectEqual(Editor.Mode.confirm_overwrite, editor.mode);
    editor.resolveOverwrite(.overwrite);
    try t.expectEqualDeep(text_file.TextFormat{ .encoding = .utf16_be, .bom = true }, doc.format);
}

test "autosave and workspace replacements report failures and preserve source formats" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "legacy.txt" });
    defer t.allocator.free(path);
    const utf16 = try std.fs.path.join(t.allocator, &.{ root, "wide.txt" });
    defer t.allocator.free(utf16);
    try text_file.write(t.allocator, t.io, path, "café cat", .{ .encoding = .windows1252 });
    try text_file.write(t.allocator, t.io, utf16, "😀cat", .{ .encoding = .utf16_le, .bom = true });
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.filetree_root = try t.allocator.dupe(u8, root);
    text_input.set(&editor.search.query_buf, &editor.search.query_len, "cat");
    editor.search.start(&editor);
    waitSearch(&editor.search);
    try t.expectEqual(@as(usize, 1), editor.search.files_skipped);
    try t.expectEqual(@as(usize, 1), editor.search.matches.items.len);
    try t.expectEqual(@as(u32, 4), editor.search.matches.items[0].col);
    try editor.rememberEncoding(path, .windows1252);
    editor.search.start(&editor);
    waitSearch(&editor.search);
    try t.expectEqual(@as(usize, 2), editor.search.matches.items.len);
    text_input.set(&editor.search.replace_buf, &editor.search.replace_len, "😀");
    const result = editor.search.executeReplace(&editor, .all);
    try t.expectEqual(@as(usize, 1), result.failed);
    try t.expectEqual(@as(usize, 1), result.files);
    try t.expectEqual(@as(usize, 1), result.count);
    for (std.enums.values(text_file.FailureStage)) |stage| {
        text_file.testing_failure = stage;
        defer text_file.testing_failure = null;
        if (search_mod.replaceAllInFile(t.allocator, t.io, path, "cat", "dog", true, false, .windows1252)) |_| return error.ExpectedFailure else |_| {}
    }
    const doc = try editor.openFile(path);
    try doc.insertAtCursor("edit ");
    for (std.enums.values(text_file.FailureStage)) |stage| {
        text_file.testing_failure = stage;
        defer text_file.testing_failure = null;
        try t.expectEqual(@as(usize, 0), editor.autoSaveAll());
        try t.expect(doc.dirty);
        try t.expectEqualDeep(text_file.TextFormat{ .encoding = .windows1252 }, doc.format);
    }
    try doc.insertAtCursor("😀");
    editor.mode = .find;
    try t.expectEqual(@as(usize, 0), editor.autoSaveAll());
    try t.expectEqual(Editor.Mode.find, editor.mode);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "failed") != null);
    try t.expect(doc.dirty);
    const bytes = try tmp.dir.readFileAlloc(t.io, "legacy.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("caf\xe9 cat", bytes);
}

test "session restores explicit BOM-less encodings and reads old session records" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "café space.txt" });
    defer t.allocator.free(path);
    const session = try std.fs.path.join(t.allocator, &.{ root, "session" });
    defer t.allocator.free(session);
    try text_file.write(t.allocator, t.io, path, "café\r\n😀", .{ .encoding = .utf16_be });
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    _ = try editor.openFileWithEncoding(path, .utf16_be, false);
    const bytes = try editor.sessionTextAlloc();
    defer t.allocator.free(bytes);
    var lua = try zlua.Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var restored = try Editor.init(t.allocator, t.io);
    defer restored.deinit();
    @import("lua_settings.zig").registerApi(lua, &restored);
    try lua.doString("zide.on('open', function() opened_text = zide.get_text(); zide.exec('new_document') end)");
    try t.expectEqual(@as(usize, 1), restored.restoreSessionText(bytes));
    try lua.doString("assert(opened_text == 'café\\r\\n😀')");
    try t.expectEqualDeep(text_file.TextFormat{ .encoding = .utf16_be }, restored.activeDoc().format);
    try t.expectEqualStrings("café\r\n😀", restored.activeDoc().buffer.slice(0, restored.activeDoc().buffer.byteLen()));
    try text_file.atomicWrite(t.allocator, t.io, session, "old session");
    for (std.enums.values(text_file.FailureStage)) |stage| {
        text_file.testing_failure = stage;
        defer text_file.testing_failure = null;
        if (editor.saveSessionTo(session)) |_| return error.ExpectedFailure else |_| {}
        const previous = try tmp.dir.readFileAlloc(t.io, "session", t.allocator, .limited(100));
        defer t.allocator.free(previous);
        try t.expectEqualStrings("old session", previous);
    }
    try text_file.write(t.allocator, t.io, path, "plain", .{});
    var old = try Editor.init(t.allocator, t.io);
    defer old.deinit();
    const old_text = try std.fmt.allocPrint(t.allocator, "active 0\ndoc 2 0 {s}\n", .{path});
    defer t.allocator.free(old_text);
    try t.expectEqual(@as(usize, 1), old.restoreSessionText(old_text));
    try t.expectEqual(@as(usize, 2), old.activeDoc().cursors.primary().offset);
}
