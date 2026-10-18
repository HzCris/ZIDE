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
const snippets_mod = @import("snippets.zig");
pub const snippet_panel_mod = @import("snippet_panel.zig");
pub const snippet_form_mod = @import("snippet_form.zig");
pub const snippet_file = @import("snippet_file.zig");
const nav_history = @import("nav_history.zig");
const picker_mod = @import("picker.zig");
const WalkIgnore = @import("walk_ignore.zig").WalkIgnore;
const zlua = @import("zlua");

/// The central editor state. NOT a global singleton — passed explicitly.
/// Owns open documents, the command registry, and global editor settings.
pub const Editor = struct {
    documents: std.ArrayList(Document),
    active_doc_idx: usize = 0,
    commands: CommandRegistry,
    snippets: snippets_mod.Registry = .{},
    snippet_owner: ?struct { document: u64, window: u32, pane: u8 } = null,
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

    /// Editor interaction mode. Change it only through setMode.
    mode: Mode = .normal,
    /// setMode is running a leave-hook: a nested setMode only assigns.
    mode_leaving: bool = false,
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
    /// Id of the transient preview document (`Document.preview`), null
    /// when there is none. Invariant P: a preview exists only while
    /// mode == .file_finder, has no tab, is never dirty, saved or given
    /// diagnostics, and is always found by this id — never by position.
    finder_preview_id: ?u64 = null,
    /// Id of the document to show again when the finder is cancelled
    /// (null once finderCommit claims the session).
    finder_prev_doc: ?u64 = null,

    /// Workspace search & replace panel state/engine (see search.zig).
    search: search_mod.SearchPanel,
    /// Back/forward history of the positions jumps left behind.
    nav: nav_history.History,
    /// The generic pick-list overlay (go-to-symbol, …), shown in `Mode.picker`.
    picker: picker_mod.Picker,
    /// Recently closed files, newest last — `reopen_closed_tab` brings them back.
    closed_tabs: std.ArrayList(ClosedTab) = .empty,
    /// Recently opened project folders, newest first (persisted in the config dir).
    recent_projects: std.ArrayList([]u8) = .empty,
    recent_loaded: bool = false,
    recent_selected: usize = 0,
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
    /// The server each LSP-opened document got its didOpen from (document
    /// id → `LspClient.generation`): its didChange/didSave/didClose go to
    /// that server even after a newer registration takes over the language,
    /// and stopping a server forgets only the documents it had open.
    lsp_doc_owner: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Documents whose full text does not fit one LSP frame (document id →
    /// the `lsp_version` found too large): not sent, and not re-checked
    /// until an edit changes the version.
    lsp_too_large: std.AutoHashMapUnmanaged(u64, i32) = .empty,
    /// Largest frame a full-text didOpen/didChange may take (the transport's
    /// limit; tests lower it instead of building 16 MiB documents).
    lsp_frame_limit: usize = @import("protocol.zig").max_frame,
    /// Wake callback copied into each client's reader thread (the TUI sets
    /// it before its loop, like terminal_wake_fn; the GUI polls every frame).
    lsp_wake_fn: ?*const fn () void = null,
    /// True while extensions/*.lua are being (re)loaded — register_lsp tags
    /// configs so reload_extensions can drop and re-add exactly those.
    loading_extensions: bool = false,
    /// The extension file being run right now (borrowed from the loader);
    /// a snippet registered meanwhile records it as its `source`.
    loading_extension_name: ?[]const u8 = null,

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
    review: @import("review.zig").State = .{},
    editorconfig_enabled: bool = true,
    project_formatting: @import("editorconfig.zig").Cache,
    lua_jobs: std.ArrayList(lua_api.BackgroundJob) = .empty,
    /// Wake callback fired when a spawn result lands (TUI sets this like
    /// terminal_wake_fn; the GUI polls every frame and leaves it null).
    lua_wake_fn: ?*const fn () void = null,

    /// Completion items from LSP.
    completion_items: std.ArrayList(EditorCompletionItem),
    /// Every item the server sent (the owner); `completion_items` is the
    /// prefix-filtered view the frontends draw.
    completion_all: std.ArrayList(EditorCompletionItem) = .empty,
    /// A re-request is in flight: the visible list is the previous reply,
    /// kept for continuity, and must not be accepted.
    completion_stale: bool = false,
    /// Open the popup while typing (trigger characters and identifiers).
    completion_auto: bool = true,
    /// Identifier characters typed before the popup opens by itself (1–8):
    /// raise it for languages with huge standard libraries.
    completion_min_chars: usize = 1,
    /// Signature help near the caret (non-modal): the active signature's
    /// label, the active parameter's byte range in it and a documentation
    /// line. Owned. Dropped once the caret leaves the line it was shown on.
    signature: ?Signature = null,
    signature_doc_id: u64 = 0,
    signature_line: usize = 0,
    /// Ask for signature help when a trigger character ("(" or ",") is typed.
    signature_help_auto: bool = true,
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
    confirm_overwrite_doc: ?u64 = null,
    /// Document the .confirm_close prompt (closing a dirty tab) was opened
    /// for — resolved by id when answered; cancels if the document is gone.
    confirm_close_doc: ?u64 = null,
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

    /// Snippets side panel (snippet_panel.zig): shown, owning the keyboard,
    /// its side (null = opposite the file tree, see snippetsSide), GUI
    /// width in pixels, TUI width in columns, whether a click only selects
    /// an item and a double-click inserts it (false: a click inserts), and
    /// the rows.
    snippets_visible: bool = false,
    snippets_focused: bool = false,
    snippets_side: ?FiletreeSide = null,
    snippets_width: f32 = 260,
    tui_snippets_width: u16 = 32,
    snippets_double_click: bool = false,
    snippet_panel: snippet_panel_mod.State = .{},
    /// The "Save as snippet" form (snippet_form.zig), shown while
    /// `mode == .snippet_form`.
    snippet_form: snippet_form_mod.State = .{},
    /// The command of the snippet a `.snippet_delete_confirm` prompt is
    /// about (owned; freed when the prompt ends).
    snippet_delete_target: ?[]u8 = null,
    /// The panel's type-to-filter text (snippet_panel.View.filter).
    snippets_filter: [snippet_panel_mod.max_filter]u8 = undefined,
    snippets_filter_len: usize = 0,

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
        /// TUI prompt for `open_folder` (the GUI answers with a native dialog).
        folder_open,
        save_as,
        command_palette,
        /// The generic pick-list overlay (`Editor.picker`).
        picker,
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
        /// Pick a recently opened project folder.
        recent_projects,
        lsp_panel,
        symbol_rename,
        workspace_preview,
        task_save_prompt,
        tool_panel,
        git_stage_prompt,
        settings,
        filetree_prompt,
        /// The Save / Edit / Copy snippet form (`snippet_form`): a dvui
        /// dialog pinned to `snippet_form.window_id` in the GUI, a bottom
        /// band in the TUI.
        snippet_form,
        /// "Delete snippet … from my-snippets.lua?" (`snippet_delete_target`):
        /// `y` deletes, any other key cancels — the TUI's status line, the
        /// GUI's small dialog.
        snippet_delete_confirm,
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
            .nav = .init(allocator),
            .picker = .init(allocator),
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
        self.review.deinit(self);
        self.dap.deinit(self);
        self.tool_panel.deinit(self.allocator);
        self.jobs.deinit();
        self.problems.deinit();
        self.project_formatting.deinit();
        for (self.documents.items) |*doc| {
            doc.deinit();
        }
        self.documents.deinit(self.allocator);
        self.lsp_doc_owner.deinit(self.allocator);
        self.lsp_too_large.deinit(self.allocator);
        self.commands.deinit();
        self.snippet_panel.deinit(self.allocator);
        self.snippet_form.deinit(self.allocator);
        self.freeSnippetDeleteTarget();
        self.snippets.deinit(self.allocator);
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
        self.completion_all.deinit(self.allocator);
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
        self.nav.deinit();
        self.picker.deinit();
        self.clearSignature();
        for (self.closed_tabs.items) |e| self.allocator.free(e.path);
        self.closed_tabs.deinit(self.allocator);
        for (self.recent_projects.items) |p| self.allocator.free(p);
        self.recent_projects.deinit(self.allocator);
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

    // ---- Keyboard focus (normal mode) ----
    //
    // In normal mode exactly one of the file tree, the search panel, the
    // focused terminal pane and the focused editor pane owns the keyboard.
    // The two panel flags stay plain fields (frontends read them), but only
    // takeKeyboardFocus sets one; every way a pane takes focus clears both,
    // and normalizeKeyboardFocus repairs direct writes once per tick.

    /// Who gets keys and text in normal mode.
    pub const KeyboardOwner = enum { editor, terminal, filetree, snippets, search };
    /// What takeKeyboardFocus hands the keyboard to: the focused pane
    /// (editor or terminal, whichever it is) or one of the side panels.
    pub const FocusTarget = enum { pane, filetree, snippets, search };

    /// Pure read. The side panels live in the primary window and own the
    /// keyboard only while it is focused (the tree before the Snippets
    /// panel before the search panel); otherwise the focused pane does.
    pub fn keyboardOwner(self: *const Editor) KeyboardOwner {
        if (self.active_window == 0) {
            if (self.filetree_focused) return .filetree;
            if (self.snippets_focused) return .snippets;
            if (self.search_focused) return .search;
        }
        return if (self.activePaneIsTerminal()) .terminal else .editor;
    }

    /// THE setter of panel focus. `.pane` gives the keyboard back to the
    /// focused pane (every panel flag cleared). A panel target focuses the
    /// primary window, shows the panel, takes the keyboard from the other
    /// panels and closes the editor's completion popup; false when the file
    /// tree cannot be opened (the tree is then hidden and unfocused).
    pub fn takeKeyboardFocus(self: *Editor, target: FocusTarget) bool {
        if (target != .pane and self.active_window != 0) self.focusWindow(0);
        if (target == .filetree) {
            // A tree that cannot open leaves the current owner alone.
            self.filetree_visible = true;
            if (self.ensureFiletree() == null) return false;
        }
        self.filetree_focused = false;
        self.snippets_focused = false;
        self.search_focused = false;
        switch (target) {
            .pane => return true,
            .filetree => self.filetree_focused = true,
            .snippets => {
                self.snippets_visible = true;
                self.snippets_focused = true;
            },
            .search => {
                self.search_visible = true;
                self.search_focused = true;
            },
        }
        self.clearCompletionItems();
        return true;
    }

    /// Repair panel focus that a direct flag write, or a panel hidden under
    /// it, left inconsistent: a flag whose panel is hidden (or whose tree
    /// was never built) is cleared, all are while a secondary window is
    /// focused, and when several are set the tree keeps the keyboard, then
    /// the Snippets panel. First thing in serviceTick.
    pub fn normalizeKeyboardFocus(self: *Editor) void {
        if (self.active_window != 0) {
            self.filetree_focused = false;
            self.snippets_focused = false;
            self.search_focused = false;
            return;
        }
        if (!self.filetree_visible or self.filetree == null) self.filetree_focused = false;
        if (!self.snippets_visible) self.snippets_focused = false;
        if (!self.search_visible) self.search_focused = false;
        if (self.filetree_focused) {
            self.snippets_focused = false;
            self.search_focused = false;
        }
        if (self.snippets_focused) self.search_focused = false;
    }

    /// The editing chords a focused side panel takes over (panelAction).
    const PanelChord = enum { copy, cut, paste, select_all, delete_word_backward, delete_word_forward };

    /// Clipboard and word-delete chords while a side panel owns the
    /// keyboard (normal mode): the tree copies, cuts and pastes files, the
    /// search panel edits its focused field, and the other chords are
    /// swallowed so the document behind the panel is never edited. True =
    /// consumed, and the caller must not run the action; false for any
    /// other action, for the editor and terminal owners, and in modal modes.
    pub fn panelAction(self: *Editor, action: []const u8) bool {
        if (self.mode != .normal) return false;
        const chord = std.meta.stringToEnum(PanelChord, action) orelse return false;
        switch (self.keyboardOwner()) {
            .editor, .terminal => return false,
            .filetree => switch (chord) {
                .copy => self.filetreeClipCapture(false),
                .cut => self.filetreeClipCapture(true),
                .paste => self.filetreePaste(),
                .select_all, .delete_word_backward, .delete_word_forward => {},
            },
            // The Snippets panel edits nothing: the chords are swallowed.
            .snippets => {},
            .search => self.searchFieldChord(chord),
        }
        return true;
    }

    /// The search panel's focused text field; null on the results list.
    fn searchInputSlot(self: *Editor) ?struct { buf: []u8, len: *usize } {
        const sp = &self.search;
        return switch (sp.field) {
            .query => .{ .buf = &sp.query_buf, .len = &sp.query_len },
            .replace => .{ .buf = &sp.replace_buf, .len = &sp.replace_len },
            .filter => .{ .buf = &sp.filter_buf, .len = &sp.filter_len },
            .exclude => .{ .buf = &sp.exclude_buf, .len = &sp.exclude_len },
            .results => null,
        };
    }

    /// A panelAction chord on the search panel's focused field. The fields
    /// are single-line with the caret at the end, so copy/cut take the whole
    /// field, paste appends the clipboard's first line, and word delete
    /// drops trailing spaces plus the word before them (a space is ASCII, so
    /// the cut always lands on a UTF-8 boundary). Edits disarm a pending
    /// Replace confirmation.
    fn searchFieldChord(self: *Editor, chord: PanelChord) void {
        const slot = self.searchInputSlot() orelse return;
        const text = slot.buf[0..slot.len.*];
        switch (chord) {
            .copy, .cut => {
                if (text.len > 0) self.setClipboard(text);
                if (chord == .cut) {
                    slot.len.* = 0;
                    self.search.confirm_armed = false;
                }
            },
            .paste => {
                const clip = self.getClipboard();
                self.search.appendText(clip[0 .. std.mem.indexOfAny(u8, clip, "\r\n") orelse clip.len]);
            },
            .delete_word_backward => {
                var n = text.len;
                while (n > 0 and text[n - 1] == ' ') n -= 1;
                while (n > 0 and text[n - 1] != ' ') n -= 1;
                slot.len.* = n;
                self.search.confirm_armed = false;
            },
            .select_all, .delete_word_forward => {},
        }
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
    /// Ends quick-open first: the new document must not land behind the
    /// preview.
    pub fn newDocument(self: *Editor) !*Document {
        self.finderCancel();
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
        // Background opens (goto-definition, debugger frames, extensions)
        // end quick-open instead of landing behind its preview.
        self.finderCancel();
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
        const id = active.id;
        if (encoding) |enc| self.rememberEncoding(active.file_path.?, enc) catch {};
        self.afterOpen(active);
        return &self.documents.items[self.docIndexForId(id) orelse return error.DocumentClosed];
    }

    /// Post-open bookkeeping shared by every path that turns a file into a
    /// real document (open, open-into-active, quick-open promotion, session
    /// restore): language, EditorConfig rules, stored Problems, LSP didOpen,
    /// then the extension `open` event LAST — its handlers may open or
    /// close documents, so callers re-find `doc` by id afterwards.
    fn afterOpen(self: *Editor, doc: *Document) void {
        doc.detectLanguage(self);
        self.resolveFormatting(doc);
        self.problems.project(doc, .lsp) catch {};
        self.problems.project(doc, .lua) catch {};
        self.lspNotifyOpen(doc);
        lua_api.fireEvent(self, .open, doc);
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
        self.afterOpen(doc);
    }

    /// Open `path`, or switch to the tab that already has it open
    /// (separator-normalized compare, case-insensitive on Windows).
    pub fn openOrFocus(self: *Editor, path: []const u8) !*Document {
        self.finderCancel();
        if (try self.findDocument(path)) |idx| {
            self.switchToDoc(idx);
            return self.activeDoc();
        }
        return try self.openFile(path);
    }

    pub fn pathsEqual(self: *const Editor, a: []const u8, b: []const u8) bool {
        return @import("file_identity.zig").same(self.allocator, self.io, a, b) catch false;
    }

    /// Index of the open (non-preview) document for `path`, compared by
    /// file identity. Only an unresolvable `path` itself is an error: an
    /// open document whose own key can't be resolved (reserved device
    /// name, unreachable share, access denied, sharing violation) is
    /// compared by its raw absolute path instead, so one odd tab never
    /// blocks opening or saving every other file.
    pub fn findDocument(self: *const Editor, path: []const u8) !?usize {
        const identity = @import("file_identity.zig");
        const key = try identity.key(self.allocator, self.io, path);
        defer self.allocator.free(key);
        var raw: ?[]u8 = null; // `path` made absolute, computed on first need
        defer if (raw) |r| self.allocator.free(r);
        for (self.documents.items, 0..) |doc, idx| {
            const p = doc.file_path orelse continue;
            if (doc.preview) continue;
            const doc_key = identity.key(self.allocator, self.io, p) catch {
                if (raw == null) raw = identity.absolute(self.allocator, self.io, path) catch null;
                if (identity.equalKeys(key, p) or (raw != null and identity.equalKeys(raw.?, p))) return idx;
                continue;
            };
            defer self.allocator.free(doc_key);
            if (identity.equalKeys(key, doc_key)) return idx;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Fuzzy file finder (quick_open) — Ctrl+E overlay with live preview.
    // The preview shows in the pane behind the overlay; it is NOT a tab:
    // one transient Document (`preview` flag, named by finder_preview_id)
    // hidden from tab bars / sessions / LSP, reused per peek, removed when
    // the session ends and promoted to a normal document on commit. Every
    // way out of .file_finder goes through setMode, whose leave-hook
    // (finderEndSession) ends the session — see invariant P on the fields.
    // ------------------------------------------------------------------

    const finder_max_files = 20_000;
    const finder_max_matches = 200;

    /// Enter .file_finder mode with a fresh workspace file snapshot.
    pub fn finderOpen(self: *Editor) void {
        // A second Ctrl+E starts over, and a preview left behind by a
        // direct `mode` write never survives into a new session.
        self.finderCancel();
        self.finderDropPreview();
        self.finder_skipped = 0;
        self.finderClearFiles();
        self.finder_buf_len = 0;
        self.finder_selected = 0;
        self.finder_prev_doc = self.activeDoc().id;
        const root = self.filetree_root orelse "";
        self.finder_root = self.allocator.dupe(u8, root) catch null;
        const open_root = if (root.len == 0) "." else root;
        if (std.Io.Dir.cwd().openDir(self.io, open_root, .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(self.io);
            var ignore = WalkIgnore.load(self.allocator, self.io, d);
            defer ignore.deinit(self.allocator);
            self.finderWalk(d, &ignore, "", 0);
        } else |_| {}
        self.finderFilter();
        self.setMode(.file_finder);
    }

    /// Collect relative file paths under `dir`, skipping dot-entries and
    /// `ignore` names, bounded by depth and finder_max_files.
    fn finderWalk(self: *Editor, dir: std.Io.Dir, ignore: *const WalkIgnore, prefix: []const u8, depth: usize) void {
        if (depth > 12) return;
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (self.finder_files.items.len >= finder_max_files) return;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (ignore.skips(entry.name, prefix.len == 0)) continue;
            switch (entry.kind) {
                .file => {
                    const rel = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, entry.name }) catch continue;
                    self.finder_files.append(self.allocator, rel) catch self.allocator.free(rel);
                },
                .directory => {
                    var sub = dir.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                    defer sub.close(self.io);
                    const sub_prefix = std.fmt.allocPrint(self.allocator, "{s}{s}/", .{ prefix, entry.name }) catch continue;
                    defer self.allocator.free(sub_prefix);
                    self.finderWalk(sub, ignore, sub_prefix, depth + 1);
                },
                else => {},
            }
        }
    }

    /// Command palette: does `name` match what was typed? The typed letters
    /// must appear in the name in that order; case does not matter, and a
    /// space or dash stands for a name's underscore, so "set baseline"
    /// finds review_set_baseline.
    pub fn paletteMatch(name: []const u8, filter: []const u8) bool {
        var ni: usize = 0;
        for (filter) |raw| {
            const want = std.ascii.toLower(raw);
            const separator = want == ' ' or want == '-' or want == '_';
            while (ni < name.len) : (ni += 1) {
                const have = std.ascii.toLower(name[ni]);
                if (have == want or (separator and (have == '_' or have == '-' or have == ' '))) {
                    ni += 1;
                    break;
                }
            } else return false;
        }
        return true;
    }

    /// The palette's highlighted command: the selected match of the typed
    /// text, or the last match when the selection sits past the end (the
    /// list shrank under it). Null when nothing matches.
    pub fn paletteSelectedName(self: *Editor) ?[]const u8 {
        const filter = self.palette_buf[0..self.palette_buf_len];
        const names = self.commands.allNames() catch return null;
        var matches: usize = 0;
        var last: ?[]const u8 = null;
        for (names) |name| {
            if (!paletteMatch(name, filter)) continue;
            if (matches == self.palette_selected) return name;
            last = name;
            matches += 1;
        }
        return last;
    }

    /// Tab in the palette: spell the highlighted command out in the input,
    /// so what Enter will run is in plain view; the highlight stays on it.
    pub fn paletteComplete(self: *Editor) void {
        const name = self.paletteSelectedName() orelse return;
        const len = @min(name.len, self.palette_buf.len);
        @memcpy(self.palette_buf[0..len], name[0..len]);
        self.palette_buf_len = len;
        self.palette_selected = 0;
        const names = self.commands.allNames() catch return;
        var index: usize = 0;
        for (names) |candidate| {
            if (!paletteMatch(candidate, name[0..len])) continue;
            if (candidate.ptr == name.ptr) {
                self.palette_selected = index;
                return;
            }
            index += 1;
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

    pub const FinderRange = struct { start: usize, end: usize };

    /// The rows of finder_matches a list `rows` tall shows: scrolled so the
    /// selection is always visible, so every match (up to 200) is
    /// reachable. Frontends draw `finder_matches.items[start..end]` and
    /// never write finder_selected — the core keeps it in range.
    pub fn finderVisibleRange(self: *const Editor, rows: usize) FinderRange {
        const count = self.finder_matches.items.len;
        if (count == 0 or rows == 0) return .{ .start = 0, .end = 0 };
        const sel = @min(self.finder_selected, count - 1);
        const start = (sel + 1) -| rows;
        return .{ .start = start, .end = @min(count, start + rows) };
    }

    /// Root-joined path of the selected match, always copied into `buf`
    /// (finderClearFiles frees the snapshot the match points into).
    fn finderSelectedPath(self: *Editor, buf: []u8) ?[]const u8 {
        if (self.finder_selected >= self.finder_matches.items.len) return null;
        const rel = self.finder_files.items[self.finder_matches.items[self.finder_selected]];
        const root = self.finder_root orelse "";
        if (root.len == 0) return std.fmt.bufPrint(buf, "{s}", .{rel}) catch null;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, rel }) catch null;
    }

    /// Show the selected match in the pane behind the finder overlay.
    /// Already-open files get their real tab shown instead.
    pub fn finderPreviewSelected(self: *Editor) void {
        if (self.mode != .file_finder) return;
        var pbuf: [1024]u8 = undefined;
        const path = self.finderSelectedPath(&pbuf) orelse return;
        for (self.documents.items) |*doc| {
            if (doc.preview) continue;
            const dp = doc.file_path orelse continue;
            if (self.pathsEqual(dp, path)) {
                // Dropping the preview shifts indices: re-find by id.
                const id = doc.id;
                self.finderDropPreview();
                const idx = self.docIndexForId(id) orelse return;
                self.active_doc_idx = idx;
                self.paneShowDoc(idx);
                return;
            }
        }
        // A preview a Lua timer edited is kept as a tab, never overwritten.
        if (self.finderPreviewIdx()) |old| if (self.documents.items[old].dirty) self.finderDropPreview();
        const pidx = self.finderPreviewIdx() orelse blk: {
            var doc = Document.init(self.allocator) catch return;
            doc.preview = true;
            doc.history.max_size = self.max_undo_history;
            self.documents.append(self.allocator, doc) catch {
                doc.deinit();
                return;
            };
            self.finder_preview_id = doc.id;
            break :blk self.documents.items.len - 1;
        };
        const pdoc = &self.documents.items[pidx];
        pdoc.openWithEncoding(self.io, path, self.knownEncoding(path)) catch {
            // Unreadable/binary — drop the peek, show where we were.
            self.finderDropPreview();
            self.finderShowPrev();
            self.finder_skipped += 1;
            self.status_message = std.fmt.bufPrint(&self.status_buf, "{d} preview(s) skipped; open to choose encoding", .{self.finder_skipped}) catch "Preview skipped";
            return;
        };
        // The preview document is reused across peeks: nothing of the
        // previous file may carry over (a LICENSE after a .zig must not
        // stay Zig; rules, diagnostics and scroll are per file).
        pdoc.language = null;
        pdoc.detectLanguage(self);
        self.resolveFormatting(pdoc);
        pdoc.clearDiagnostics();
        pdoc.clearLintDiagnostics();
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
    /// Also the chokepoint commands and opens call first (a no-op outside
    /// the finder), so nothing acts on — or lands behind — a preview.
    pub fn finderCancel(self: *Editor) void {
        if (self.mode == .file_finder) {
            self.setMode(.normal);
        } else if (self.finder_preview_id != null or self.finder_prev_doc != null) {
            // A direct `mode` write left the session behind (a frontend
            // that does not go through setMode yet): end it now.
            self.finderEndSession();
        }
    }

    /// Enter: promote the preview to a real tab (or focus/open the file).
    pub fn finderCommit(self: *Editor) void {
        if (self.mode != .file_finder) return;
        var pbuf: [1024]u8 = undefined;
        const path = self.finderSelectedPath(&pbuf) orelse {
            // Nothing selected — behave like cancel.
            self.finderCancel();
            return;
        };
        // The jump leaves the pre-finder document, not the preview.
        if (self.finderReturnId()) |id| if (self.docIndexForId(id)) |ri| self.recordNavPointFor(ri);
        if (self.finderPreviewIdx()) |pidx| {
            const pdoc = &self.documents.items[pidx];
            if (pdoc.file_path != null and self.pathsEqual(pdoc.file_path.?, path)) {
                // Promote in place. The session is claimed first, so the
                // leave-hook neither removes the document nor restores the
                // old view — `pidx` stays valid across setMode.
                pdoc.preview = false;
                self.finder_preview_id = null;
                self.finder_prev_doc = null;
                self.setMode(.normal);
                self.paneShowDoc(pidx); // outside the finder: adopts the tab
                self.afterOpen(&self.documents.items[pidx]);
                return;
            }
        }
        // Stale or no preview (the file is already open, or the selection
        // moved without a refresh): end the session, then open or focus.
        self.setMode(.normal);
        _ = self.openOrFocus(path) catch {};
    }

    /// Index of the live preview document (by id, and still flagged).
    fn finderPreviewIdx(self: *const Editor) ?usize {
        const id = self.finder_preview_id orelse return null;
        const idx = self.docIndexForId(id) orelse return null;
        return if (self.documents.items[idx].preview) idx else null;
    }

    /// Where quick-open returns to: the pre-finder document while it is
    /// still open, else the active window's first tab, else any real
    /// document (null only when nothing but a preview exists).
    fn finderReturnId(self: *const Editor) ?u64 {
        if (self.finder_prev_doc) |id| if (self.docIndexForId(id)) |idx| {
            if (!self.documents.items[idx].preview) return id;
        };
        for (self.activeWindow().tabs.items) |di| {
            if (di < self.documents.items.len and !self.documents.items[di].preview) return self.documents.items[di].id;
        }
        for (self.documents.items) |*doc| if (!doc.preview) return doc.id;
        return null;
    }

    /// Remove the transient preview document, if any: panes that showed
    /// it (a split made meanwhile, another window) go to finderReturnId.
    /// Safety net: a preview with edits (a Lua timer typed into it), or
    /// the last document standing, becomes a real tab instead of being
    /// freed.
    fn finderDropPreview(self: *Editor) void {
        const pidx = self.finderPreviewIdx() orelse {
            self.finder_preview_id = null;
            return;
        };
        self.finder_preview_id = null;
        const dirty = self.documents.items[pidx].dirty;
        const back = if (dirty) null else self.finderReturnId();
        const back_id = back orelse {
            self.documents.items[pidx].preview = false;
            // adoptDoc is suppressed while the finder is open: add the tab here.
            if (self.docWindow(pidx) == null) self.activeWindow().tabs.append(self.allocator, pidx) catch {};
            self.status_message = if (dirty) "Quick-open preview had edits; kept it open as a tab" else "Quick-open preview kept open as a tab";
            return;
        };
        var doc = self.documents.orderedRemove(pidx);
        doc.deinit();
        const back_idx = self.docIndexForId(back_id).?;
        self.retargetDocIndex(pidx, back_idx);
        if (self.active_doc_idx == pidx) {
            self.active_doc_idx = back_idx;
        } else if (self.active_doc_idx > pidx) {
            self.active_doc_idx -= 1;
        }
        self.active_doc_idx = self.windowDocIdx(self.active_window);
    }

    /// Point the active pane back at the pre-finder document (or where
    /// finderReturnId says, when that one closed meanwhile).
    fn finderShowPrev(self: *Editor) void {
        const id = self.finderReturnId() orelse return;
        const idx = self.docIndexForId(id) orelse return;
        self.active_doc_idx = idx;
        self.paneShowDoc(idx);
    }

    /// Leave-hook of .file_finder (setMode runs it while the mode is still
    /// .file_finder, so adoptDoc stays suppressed): drop the preview, show
    /// the pre-finder document again unless finderCommit claimed the
    /// session, free the snapshot. May remove a document, so callers
    /// re-find indices by id.
    fn finderEndSession(self: *Editor) void {
        self.finderDropPreview();
        if (self.finder_prev_doc != null) self.finderShowPrev();
        self.finder_prev_doc = null;
        self.finderClearFiles();
    }

    // ------------------------------------------------------------------
    // Workspace search & replace panel (find_in_files)
    // ------------------------------------------------------------------

    /// Ctrl+Shift+F cycle: hidden → shown + focused; shown but something
    /// else owns the keyboard → focus the panel; panel focused → hide
    /// (results persist for next_result / prev_result).
    pub fn searchToggle(self: *Editor) void {
        if (!self.search_visible) {
            self.search.field = .query;
            _ = self.takeKeyboardFocus(.search);
        } else if (self.keyboardOwner() != .search) {
            _ = self.takeKeyboardFocus(.search);
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
        _ = self.openSelectedSearchResult();
    }

    fn openSelectedSearchResult(self: *Editor) bool {
        const sp = &self.search;
        if (sp.selected >= sp.matches.items.len) return false;
        const old = sp.matches.items[sp.selected];
        if (old.path_idx >= sp.paths.items.len) return false;
        const generation = sp.generation;
        // Opening fires Lua hooks, which may alter documents or search state.
        const path = self.allocator.dupe(u8, sp.paths.items[old.path_idx]) catch return false;
        defer self.allocator.free(path);
        const opened = self.navOpen(path) catch {
            const msg = std.fmt.bufPrint(&self.status_buf, "Cannot open {s}", .{path}) catch "Cannot open result";
            self.status_message = msg;
            return false;
        };
        if (sp.generation != generation or opened.file_path == null or !self.pathsEqual(opened.file_path.?, path)) {
            self.status_message = "Search changed; select a result again";
            return false;
        }
        const id = opened.id;
        const m = (sp.refreshedMatch(old, opened) catch {
            self.status_message = "Cannot refresh search results";
            return false;
        }) orelse {
            self.status_message = "Match no longer exists; file results refreshed";
            return false;
        };
        const idx = self.docIndexForId(id) orelse return false;
        self.switchToDoc(idx);
        const doc = &self.documents.items[idx];
        const start_off = doc.buffer.posToOffset(m.line, m.col);
        const end_off = start_off + m.len;
        const cursor = @import("cursor.zig");
        if (cursor.floorBoundary(&doc.buffer, start_off) != start_off or cursor.floorBoundary(&doc.buffer, end_off) != end_off) {
            self.status_message = "Match is not a complete character";
            return false;
        }
        doc.cursors.clearSecondary();
        const c = doc.cursors.primary();
        c.anchor = start_off;
        c.offset = end_off;
        c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
        _ = self.takeKeyboardFocus(.pane);
        return true;
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
        if (!self.openSelectedSearchResult()) return;
        const msg = std.fmt.bufPrint(&self.status_buf, "Result {d}/{d}", .{ sp.selected + 1, sp.matches.items.len }) catch "";
        self.status_message = msg;
    }

    pub fn searchArmReplace(self: *Editor) void {
        self.search.confirm_armed = false;
        if (!self.search.criteriaCurrent()) {
            self.status_message = "Run search after changing its criteria";
        } else if (self.search.searching) {
            self.status_message = "Wait for search to finish before replacing";
        } else if (self.search.matches.items.len > 0) self.search.confirm_armed = true;
    }

    /// Execute the armed replace and report; re-runs the search after so
    /// the results reflect the new state.
    pub fn searchExecuteReplace(self: *Editor, scope: search_mod.ReplaceScope) void {
        if (!self.search.criteriaCurrent() or self.search.searching) {
            self.searchArmReplace();
            return;
        }
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
    /// status message, and the panel hidden and unfocused so the failure
    /// doesn't repeat every frame) if the root directory can't be opened.
    pub fn ensureFiletree(self: *Editor) ?*filetree_mod.FileTree {
        if (self.filetree == null) {
            const root = self.filetree_root orelse ".";
            self.filetree = filetree_mod.FileTree.init(self.allocator, self.io, root) catch |err| {
                const msg = std.fmt.bufPrint(&self.status_buf, "File tree: cannot open '{s}': {s}", .{ root, @errorName(err) }) catch "File tree: open failed";
                self.status_message = msg;
                self.filetree_visible = false;
                self.filetree_focused = false;
                return null;
            };
            self.filetree.?.git_enabled = self.filetree_git_colors;
            self.filetree.?.gitRefresh();
        }
        return &self.filetree.?;
    }

    /// Ctrl+B cycle: hidden → shown + focused; shown but something else
    /// owns the keyboard → focus the tree (scrolled to its selection); tree
    /// focused → hide (focus returns to the pane). Gives a full keyboard
    /// round-trip together with Escape.
    pub fn toggleFiletree(self: *Editor) void {
        if (self.filetree_visible and self.keyboardOwner() == .filetree) {
            self.filetree_visible = false;
            self.filetree_focused = false;
            return;
        }
        const was_visible = self.filetree_visible;
        if (!self.takeKeyboardFocus(.filetree)) return;
        if (was_visible) self.filetree.?.scroll_to_selected = true;
    }

    /// Ctrl+Alt+B: the same cycle as toggleFiletree for the Snippets panel.
    pub fn toggleSnippets(self: *Editor) void {
        if (self.snippets_visible and self.keyboardOwner() == .snippets) {
            self.snippets_visible = false;
            self.snippets_focused = false;
            return;
        }
        const was_visible = self.snippets_visible;
        _ = self.takeKeyboardFocus(.snippets);
        if (was_visible) self.snippet_panel.scroll_to_selected = true;
    }

    /// Where the Snippets panel docks: its own setting, else opposite the
    /// file tree.
    pub fn snippetsSide(self: *const Editor) FiletreeSide {
        return self.snippets_side orelse (if (self.filetree_side == .left) .right else .left);
    }

    /// `snippet_panel.sync`'s view of which languages the editor knows.
    const KnownLanguages = struct {
        editor: *const Editor,
        pub fn isKnown(self: KnownLanguages, name: []const u8) bool {
            return self.editor.findLanguageByName(name) != null;
        }
    };

    /// The Snippets panel's rows for the main window's document (the file
    /// tree's auto-reveal follows the same one). Rebuilds only when the
    /// registry, the document's language or a toggle changed. Frontends
    /// call it before reading the rows, after handling input.
    pub fn syncSnippetPanel(self: *Editor) *snippet_panel_mod.State {
        const doc = &self.documents.items[self.windowDocIdx(0)];
        self.snippet_panel.sync(self.allocator, self.snippets.items.items, .{
            .revision = self.snippets.revision,
            .language = if (doc.language) |lang| lang.name else null,
            .any_language = doc.file_path == null and doc.language == null,
            .languages_known = self.languages.items.len,
            .filter = self.snippets_filter[0..self.snippets_filter_len],
        }, KnownLanguages{ .editor = self });
        return &self.snippet_panel;
    }

    /// Type-to-filter in the Snippets panel: typed text narrows the rows
    /// (name, trigger or group containing it), Backspace edits it and
    /// Escape clears it (true when there was something to clear). The
    /// frontends sync the panel afterwards.
    pub fn snippetsFilterAppend(self: *Editor, text: []const u8) void {
        text_input.append(&self.snippets_filter, &self.snippets_filter_len, text);
    }
    pub fn snippetsFilterBackspace(self: *Editor) void {
        text_input.backspace(&self.snippets_filter, &self.snippets_filter_len);
    }
    pub fn snippetsFilterClear(self: *Editor) bool {
        const had = self.snippets_filter_len > 0;
        self.snippets_filter_len = 0;
        return had;
    }

    /// Enter or a click on panel row `index`: a group opens or closes, an
    /// item is inserted. The rows are fresh afterwards.
    pub fn activateSnippetRow(self: *Editor, index: usize) void {
        const panel = self.syncSnippetPanel();
        const row = panel.rowAt(index) orelse return;
        switch (row.kind) {
            .group => panel.toggle(self.allocator, row.group),
            .item => self.insertSnippetFromPanel(row.def),
        }
        _ = self.syncSnippetPanel();
    }

    /// Insert registry definition `index` from the Snippets panel into the
    /// main window's document and give it the keyboard, so Tab walks the
    /// fields right away. An untitled document without a language adopts
    /// the snippet's language first (indentation and the language check
    /// read it). Refusals explain themselves in the status bar and leave
    /// the panel focused.
    pub fn insertSnippetFromPanel(self: *Editor, index: usize) void {
        if (self.mode != .normal or index >= self.snippets.items.items.len) return;
        if (self.active_window != 0) self.focusWindow(0);
        if (self.activePaneIsTerminal()) {
            self.status_message = "Snippets insert into an editor pane: focus one first";
            return;
        }
        const doc = self.activeDoc();
        if (doc.readonly) {
            self.status_message = if (doc.reader != null) "Read-only review view — Enter opens the real file" else "Read-only document";
            return;
        }
        if (doc.cursors.count() != 1) {
            self.status_message = "Snippets require a single cursor";
            return;
        }
        const def = &self.snippets.items.items[index];
        if (doc.file_path == null and doc.language == null and !std.mem.eql(u8, def.language, "*")) {
            const lang = self.findLanguageByName(def.language) orelse {
                self.status_message = std.fmt.bufPrint(&self.status_buf, "No language named '{s}' is registered", .{def.language}) catch "The snippet's language is not registered";
                return;
            };
            self.setDocLanguage(doc, lang);
        }
        _ = self.takeKeyboardFocus(.pane);
        _ = self.execCommand(def.command, null);
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
        const had_keyboard = self.keyboardOwner() == .filetree;
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
        // The failed attempt unfocused the tree; the restored one gets the
        // keyboard back if it had it (tree Backspace into an unreadable parent).
        if (had_keyboard and self.filetree != null) _ = self.takeKeyboardFocus(.filetree);
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
        self.setMode(.filetree_prompt);
    }

    /// Cancel the file-tree prompt and return to normal mode.
    pub fn cancelFiletreePrompt(self: *Editor) void {
        self.freeFiletreePromptTarget();
        if (self.mode == .filetree_prompt) self.setMode(.normal);
    }

    /// Leave-hook of .filetree_prompt (and part of cancelFiletreePrompt).
    fn freeFiletreePromptTarget(self: *Editor) void {
        if (self.filetree_prompt_target) |old| self.allocator.free(old);
        self.filetree_prompt_target = null;
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
            self.confirm_close_doc = self.documents.items[doc_idx].id;
            self.setMode(.confirm_close);
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
        self.setMode(.normal);
        const id = self.confirm_close_doc;
        self.confirm_close_doc = null;
        const idx = (if (id) |target| self.docIndexForId(target) else null) orelse {
            self.status_message = "Close cancelled (the document is gone)";
            return .kept;
        };
        switch (choice) {
            .cancel => return .kept,
            .discard => {
                _ = self.closeDocAt(idx);
                return .closed;
            },
            .save => {
                const target_id = self.documents.items[idx].id;
                switch (self.saveDocument(target_id, .{})) {
                    .formatting => {
                        self.close_after_save_id = target_id;
                        return .kept;
                    },
                    .needs_path => {
                        self.close_after_save_id = target_id;
                        return .needs_path;
                    },
                    .saved => {
                        const current = self.docIndexForId(target_id) orelse return .closed;
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
        const idx = if (self.confirm_close_doc) |id| self.docIndexForId(id) else null;
        const name: []const u8 = if (idx) |i|
            self.documents.items[i].display_name
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
            self.rememberClosed(&self.documents.items[0]);
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
        self.rememberClosed(&self.documents.items[removed_idx]);
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
    // ------------------------------------------------------------------
    // Navigation history — navigate_back / navigate_forward.

    /// The caret position of document `idx` as a history point; null for a
    /// quick-open preview (never a place to return to).
    fn navPos(self: *Editor, idx: usize) ?nav_history.Pos {
        if (idx >= self.documents.items.len) return null;
        const doc = &self.documents.items[idx];
        if (doc.preview) return null;
        const p = doc.buffer.offsetToPos(doc.cursors.primary().offset);
        return .{ .doc_id = doc.id, .path = doc.file_path, .line = p.line, .col = p.col };
    }

    /// Remember the active document's caret so `navigate_back` can return
    /// here. Jumping commands call this before they move the caret.
    pub fn recordNavPoint(self: *Editor) void {
        self.recordNavPointFor(self.activeDocIdx());
    }

    pub fn recordNavPointFor(self: *Editor, idx: usize) void {
        const pos = self.navPos(idx) orelse return;
        self.nav.record(pos) catch {};
    }

    /// Open or focus `path` as a jump: the caret it leaves is recorded first.
    pub fn navOpen(self: *Editor, path: []const u8) !*Document {
        self.recordNavPoint();
        return self.openOrFocus(path);
    }

    /// `goto_line`'s apply — a recorded jump, so navigate_back undoes it.
    pub fn jumpToLine(self: *Editor, line_num: usize) void {
        self.recordNavPoint();
        self.activeDoc().gotoLine(line_num);
    }

    /// Move through the history. False (with a status message) when there
    /// is nowhere to go; entries whose document is gone are dropped.
    pub fn navigate(self: *Editor, dir: nav_history.Direction) bool {
        const here = self.navPos(self.activeDocIdx()) orelse return false;
        // Opening a file runs extension hooks that may close documents, so
        // the position being left keeps its own copy of the path.
        const from_path = if (here.path) |p| self.allocator.dupe(u8, p) catch return false else null;
        defer if (from_path) |p| self.allocator.free(p);
        const from: nav_history.Pos = .{ .doc_id = here.doc_id, .path = from_path, .line = here.line, .col = here.col };
        while (self.nav.take(dir, from)) |taken| {
            var entry = taken;
            defer entry.deinit(self.allocator);
            if (self.applyNav(entry)) {
                self.nav.leave(dir, from) catch {};
                return true;
            }
        }
        self.status_message = if (dir == .back) "Nothing to go back to" else "Nothing to go forward to";
        return false;
    }

    fn applyNav(self: *Editor, entry: nav_history.Entry) bool {
        var idx = self.docIndexForId(entry.doc_id);
        if (idx == null) {
            const path = entry.path orelse return false; // an untitled buffer that was closed
            const doc = self.openOrFocus(path) catch return false;
            idx = self.docIndexForId(doc.id);
        }
        const i = idx orelse return false;
        if (self.documents.items[i].preview) return false;
        self.switchToDoc(i);
        const doc = &self.documents.items[i];
        const line = @min(entry.line, doc.buffer.lineCount() -| 1);
        doc.gotoLine(line + 1);
        doc.cursors.primary().gotoPos(&doc.buffer, line, entry.col);
        self.setMode(.normal);
        return true;
    }

    // ------------------------------------------------------------------
    // Reopen closed tab.

    pub const ClosedTab = struct { path: []u8, line: usize, col: usize };
    const closed_tabs_capacity: usize = 20;

    /// Remember a named document that is about to close so
    /// `reopen_closed_tab` can bring it back at its caret. One entry per
    /// file (the newest wins); untitled buffers and previews are not kept.
    fn rememberClosed(self: *Editor, doc: *const Document) void {
        if (doc.preview) return;
        const path = doc.file_path orelse return;
        const owned = self.allocator.dupe(u8, path) catch return;
        var i: usize = 0;
        while (i < self.closed_tabs.items.len) {
            if (self.pathsEqual(self.closed_tabs.items[i].path, owned)) {
                const old = self.closed_tabs.orderedRemove(i);
                self.allocator.free(old.path);
                continue;
            }
            i += 1;
        }
        const p = doc.buffer.offsetToPos(doc.cursors.primaryConst().offset);
        self.closed_tabs.append(self.allocator, .{ .path = owned, .line = p.line, .col = p.col }) catch {
            self.allocator.free(owned);
            return;
        };
        if (self.closed_tabs.items.len > closed_tabs_capacity) {
            const oldest = self.closed_tabs.orderedRemove(0);
            self.allocator.free(oldest.path);
        }
    }

    /// Reopen the most recently closed file that is not open now, at the
    /// caret it was closed with. False (with a status message) when the
    /// list is empty or the file cannot be opened.
    pub fn reopenClosedTab(self: *Editor) bool {
        while (self.closed_tabs.pop()) |entry| {
            defer self.allocator.free(entry.path);
            if ((self.findDocument(entry.path) catch null) != null) continue;
            self.recordNavPoint();
            const doc = self.openOrFocus(entry.path) catch |err| {
                if (err != error.EncodingRequired and err != error.BinaryFile) {
                    self.status_message = std.fmt.bufPrint(&self.status_buf, "Cannot reopen {s}: {s}", .{ std.fs.path.basename(entry.path), @errorName(err) }) catch "Cannot reopen closed tab";
                }
                return false;
            };
            const line = @min(entry.line, doc.buffer.lineCount() -| 1);
            doc.gotoLine(line + 1);
            doc.cursors.primary().gotoPos(&doc.buffer, line, entry.col);
            return true;
        }
        self.status_message = "No closed tabs to reopen";
        return false;
    }

    // ------------------------------------------------------------------
    // Signature help.

    pub const Signature = struct { label: []u8, param_start: usize, param_end: usize, doc: []u8 };

    pub fn clearSignature(self: *Editor) void {
        if (self.signature) |s| {
            self.allocator.free(s.label);
            self.allocator.free(s.doc);
        }
        self.signature = null;
    }

    /// Show `label`, with `param_start..param_end` highlighted, for the
    /// active document's caret line.
    pub fn setSignature(self: *Editor, label: []const u8, param_start: usize, param_end: usize, doc: []const u8) !void {
        const l = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(l);
        const d = try self.allocator.dupe(u8, doc);
        errdefer self.allocator.free(d);
        self.clearSignature();
        const active = self.activeDoc();
        self.signature = .{ .label = l, .param_start = @min(param_start, l.len), .param_end = @min(@max(param_start, param_end), l.len), .doc = d };
        self.signature_doc_id = active.id;
        self.signature_line = active.buffer.offsetToPos(active.cursors.primaryConst().offset).line;
    }

    /// Whether to draw the signature popup now; one left behind on another
    /// line is dropped here.
    pub fn signatureVisible(self: *Editor) bool {
        if (self.signature == null) return false;
        const doc = self.activeDoc();
        if (doc.id != self.signature_doc_id or self.mode != .normal) return false;
        if (doc.buffer.offsetToPos(doc.cursors.primaryConst().offset).line != self.signature_line) {
            self.clearSignature();
            return false;
        }
        return true;
    }

    fn signatureTriggerByte(self: *Editor, b: u8) bool {
        const client = self.lspClientForDoc(self.activeDoc()) orelse return false;
        return client.capabilities.isSignatureTrigger(b);
    }

    // ------------------------------------------------------------------
    // Generic pick-list overlay (go-to-symbol; Lua extensions later).

    /// Show the list prepared with `picker.begin` / `picker.add`.
    pub fn openPicker(self: *Editor) void {
        self.picker.refilter();
        self.setMode(.picker);
    }

    pub fn pickerCancel(self: *Editor) void {
        self.setMode(.normal);
    }

    /// Enter: leave picker mode, then hand the chosen payload to the callback.
    pub fn pickerConfirm(self: *Editor) void {
        const payload = self.picker.selectedPayload();
        const on_pick = self.picker.on_pick;
        self.setMode(.normal);
        if (payload) |p| if (on_pick) |cb| cb(self, p);
    }

    pub fn pickerTyped(self: *Editor, text: []const u8) void {
        self.picker.typeText(text);
        if (self.picker.on_query) |cb| cb(self, self.picker.filter());
    }

    pub fn pickerBackspace(self: *Editor) void {
        self.picker.backspace();
        if (self.picker.on_query) |cb| cb(self, self.picker.filter());
    }

    /// Open `path` at `line` / `col` (0-based; `columns` says whether `col`
    /// counts bytes or UTF-16 units) as a recorded jump. Problems, task
    /// output, references and symbol pickers all land here.
    pub fn jumpToLocation(self: *Editor, path: []const u8, line: u32, col: u32, columns: @import("diagnostics.zig").Columns) void {
        // Opening can run extensions that replace the store `path` lives in.
        const owned = self.allocator.dupe(u8, path) catch return;
        defer self.allocator.free(owned);
        const doc = self.navOpen(owned) catch |err| {
            self.status_message = std.fmt.bufPrint(&self.status_buf, "Cannot open {s}: {s}", .{ std.fs.path.basename(owned), @errorName(err) }) catch "Cannot open location";
            return;
        };
        doc.gotoLine(line +| 1);
        const byte_col = if (columns == .utf16) lsp_mod.utf16ColToByte(doc.lineContent(line), col) else col;
        doc.cursors.primary().gotoPos(&doc.buffer, line, byte_col);
        self.setMode(.normal);
    }

    // ------------------------------------------------------------------
    // Projects: open folder, recent projects, re-root from the tree.

    /// Nine, so the TUI picker's digit keys cover every row.
    pub const recent_projects_max: usize = 9;

    fn recentProjectsPath(buf: []u8) ?[]const u8 {
        const lua_settings = @import("lua_settings.zig");
        const dir = lua_settings.getConfigDir() orelse return null;
        return std.fmt.bufPrint(buf, "{s}/recent_projects", .{dir}) catch null;
    }

    /// Load `~/.config/zide/recent_projects` once: one path per line,
    /// newest first.
    pub fn ensureRecentProjects(self: *Editor) void {
        if (self.recent_loaded) return;
        self.recent_loaded = true;
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = recentProjectsPath(&pbuf) orelse return;
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024)) catch return;
        defer self.allocator.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (self.recent_projects.items.len >= recent_projects_max) break;
            const owned = self.allocator.dupe(u8, line) catch return;
            self.recent_projects.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                return;
            };
        }
    }

    fn saveRecentProjects(self: *Editor) void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = recentProjectsPath(&pbuf) orelse return;
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{}) catch return;
        defer file.close(self.io);
        for (self.recent_projects.items) |p| {
            file.writeStreamingAll(self.io, p) catch return;
            file.writeStreamingAll(self.io, "\n") catch return;
        }
    }

    /// Put the current tree root at the top of the recent-projects list.
    pub fn rememberProject(self: *Editor) void {
        const ft = self.ensureFiletree() orelse return;
        self.ensureRecentProjects();
        const owned = self.allocator.dupe(u8, ft.root_path) catch return;
        var i: usize = 0;
        while (i < self.recent_projects.items.len) {
            if (self.pathsEqual(self.recent_projects.items[i], owned)) {
                self.allocator.free(self.recent_projects.orderedRemove(i));
                continue;
            }
            i += 1;
        }
        self.recent_projects.insert(self.allocator, 0, owned) catch {
            self.allocator.free(owned);
            return;
        };
        while (self.recent_projects.items.len > recent_projects_max) self.allocator.free(self.recent_projects.pop().?);
        self.saveRecentProjects();
    }

    /// Open `path` as the project: it becomes the file tree root and the
    /// language-server workspace (servers restart) and joins the recent
    /// list. False (with the tree's message) when the folder is unusable.
    pub fn openProject(self: *Editor, path: []const u8) bool {
        if (!self.setFiletreeRoot(path)) return false;
        self.rememberProject();
        self.restartLsp();
        if (self.filetree) |*ft| {
            self.status_message = std.fmt.bufPrint(&self.status_buf, "Project: {s}", .{ft.root_path}) catch "Project opened";
        }
        return true;
    }

    /// `recent_projects`: show the picker, or say when there is nothing to pick.
    pub fn startRecentProjects(self: *Editor) void {
        self.ensureRecentProjects();
        if (self.recent_projects.items.len == 0) {
            self.status_message = "No recent projects yet";
            return;
        }
        self.recent_selected = 0;
        self.setMode(.recent_projects);
    }

    pub fn cancelRecentProjects(self: *Editor) void {
        self.setMode(.normal);
    }

    /// Open recent project `idx`; a folder that cannot be opened any more
    /// leaves the list.
    pub fn chooseRecentProject(self: *Editor, idx: usize) void {
        self.setMode(.normal);
        if (idx >= self.recent_projects.items.len) return;
        const copy = self.allocator.dupe(u8, self.recent_projects.items[idx]) catch return;
        defer self.allocator.free(copy);
        if (!self.openProject(copy)) {
            self.allocator.free(self.recent_projects.orderedRemove(idx));
            self.saveRecentProjects();
        }
    }

    /// Tree `o`: the selected folder (or a selected file's folder) becomes
    /// the project root.
    pub fn filetreeOpenSelectedAsRoot(self: *Editor) void {
        const ft = self.ensureFiletree() orelse return;
        const target = ft.opTargetDir();
        if (target == 0) {
            self.status_message = "File tree: that folder is already the root";
            return;
        }
        const abs = ft.absPathAlloc(self.allocator, target) catch return;
        defer self.allocator.free(abs);
        _ = self.openProject(abs);
    }

    pub fn switchToDoc(self: *Editor, idx: usize) void {
        if (idx < self.documents.items.len) {
            if (idx != self.activeDocIdx()) self.cancelSnippets();
            self.active_doc_idx = idx;
            self.paneShowDoc(idx);
        }
    }

    /// Deliver finished zide.spawn results to their Lua callbacks.
    /// Called by both frontends' main loops.
    pub fn pumpLuaJobs(self: *Editor) void {
        lua_api.pumpLuaJobs(self);
    }

    /// Execute a command by name. Commands act on real documents, so an
    /// open quick-open session ends first.
    pub fn execCommand(self: *Editor, name: []const u8, args: ?[]const u8) bool {
        self.finderCancel();
        return self.commands.execute(self, name, args);
    }

    /// Execute an action by name. Handles special actions (quit, save, find, etc.)
    /// that aren't in the command registry, then falls back to execCommand.
    /// Returns true if the action was recognized and handled. Ends an open
    /// quick-open session first (menus, keybinds and Lua exec all land here).
    pub fn execAction(self: *Editor, action: []const u8) bool {
        self.finderCancel();
        self.validateSnippetState();
        defer self.validateSnippetState();
        if (std.mem.eql(u8, action, "quit")) {
            if (self.hasUnsavedChanges()) {
                self.setMode(.confirm_quit);
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
            self.setMode(.find);
            self.find_buf_len = 0;
            self.find_origin = self.activeDoc().cursors.primary().offset;
            return true;
        }
        if (std.mem.eql(u8, action, "find_replace")) {
            self.setMode(.find_replace);
            self.find_buf_len = 0;
            self.replace_buf_len = 0;
            self.replace_field_active = false;
            self.find_origin = self.activeDoc().cursors.primary().offset;
            return true;
        }
        if (std.mem.eql(u8, action, "file_open")) {
            self.setMode(.file_open);
            self.open_buf_len = 0;
            return true;
        }
        if (std.mem.eql(u8, action, "save_as")) {
            self.startSaveAs(self.activeDoc().id, null);
            return true;
        }
        if (std.mem.eql(u8, action, "command_palette")) {
            self.setMode(.command_palette);
            self.palette_buf_len = 0;
            self.palette_selected = 0;
            return true;
        }
        if (std.mem.eql(u8, action, "goto_line")) {
            self.setMode(.goto_line);
            self.goto_buf_len = 0;
            return true;
        }
        if (std.mem.eql(u8, action, "settings")) {
            self.setMode(.settings);
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
        if (std.mem.eql(u8, action, "reopen_closed_tab")) {
            _ = self.reopenClosedTab();
            return true;
        }
        if (std.mem.eql(u8, action, "open_folder")) {
            self.setMode(.folder_open);
            self.open_buf_len = 0;
            return true;
        }
        if (std.mem.eql(u8, action, "recent_projects")) {
            self.startRecentProjects();
            return true;
        }
        if (std.mem.eql(u8, action, "navigate_back")) {
            _ = self.navigate(.back);
            return true;
        }
        if (std.mem.eql(u8, action, "navigate_forward")) {
            _ = self.navigate(.forward);
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
            const recorded = doc.disk_stamp orelse continue;
            const current = text_file.Stamp.read(self.io, path) catch {
                doc.external_changed = true;
                doc.history.saved_revision = null;
                doc.dirty = true;
                self.status_message = "Cannot check file on disk (buffer kept; saving will ask)";
                continue;
            };
            const stamp = current orelse {
                doc.external_changed = true;
                doc.history.saved_revision = null;
                doc.dirty = true;
                const msg = std.fmt.bufPrint(&self.status_buf, "{s}: file deleted on disk (buffer kept)", .{doc.display_name}) catch "File deleted on disk (buffer kept)";
                self.status_message = msg;
                continue;
            };
            if (std.meta.eql(stamp, recorded)) continue;
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
        self.setMode(.encoding_picker);
        self.status_message = "Choose an encoding to open this file";
    }
    pub fn startEncoding(self: *Editor, action: EncodingAction) void {
        if (self.activePaneIsTerminal()) return;
        self.cancelEncoding();
        self.encoding_doc_id = self.activeDoc().id;
        self.encoding_action = action;
        self.setMode(.encoding_picker);
    }
    pub fn cancelEncoding(self: *Editor) void {
        self.close_after_save_id = null;
        if (self.encoding_path) |p| self.allocator.free(p);
        self.encoding_path = null;
        self.encoding_doc_id = null;
        self.reopen_encoding = null;
        self.reopen_after_save = false;
        self.encoding_selected = 0;
        self.setMode(.normal);
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
            self.setMode(.normal);
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
            if (self.documents.items[di].dirty) self.setMode(.confirm_reopen) else self.finishReopen();
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
                self.setMode(.normal);
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
        self.setMode(.save_as);
    }
    pub fn finishSaveAs(self: *Editor, path: []const u8) SaveOutcome {
        const id = self.save_as_id orelse return .{ .failed = error.DocumentClosed };
        const format = self.save_as_format;
        self.setMode(.normal);
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
        self.setMode(.normal);
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
    /// Show why an interactive save stopped. Leaves the current mode first
    /// (ending quick-open can remove its preview and shift indices, so the
    /// document is found by id afterwards), then shows it and enters the
    /// prompt the outcome needs.
    fn showSaveBlocker(self: *Editor, id: u64, result: SaveOutcome) void {
        self.setMode(.normal);
        self.switchToDoc(self.docIndexForId(id) orelse return);
        switch (result) {
            .formatting => self.status_message = "Formatting before save",
            .conflict => {
                self.save_destination_conflict = false;
                self.confirm_overwrite_doc = id;
                self.setMode(.confirm_overwrite);
                self.status_message = "File changed on disk; save cancelled";
            },
            .destination_exists => {
                self.confirm_overwrite_doc = id;
                self.save_destination_conflict = true;
                self.setMode(.confirm_overwrite);
                self.status_message = "Save As destination exists; confirm overwrite";
            },
            .needs_path => self.status_message = "Use Save As for the untitled document, then quit again",
            .failed => |err| if (err != error.ReadOnlyDocument) {
                self.status_message = std.fmt.bufPrint(&self.status_buf, "Save failed: {s}", .{@errorName(err)}) catch "Save failed";
            },
            .unrepresentable => {
                self.setMode(.confirm_encoding);
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
        // Invariant P: a quick-open preview is never written anywhere.
        if (doc.preview) return .{ .failed = error.PreviewDocument };
        // A read-only document (the review reader, a server's stderr) has
        // nothing of the user's to save; Save As would write synthesized text.
        if (doc.readonly) {
            self.status_message = if (doc.reader != null) "Read-only review view — Enter opens the real file" else "Read-only document";
            return .{ .failed = error.ReadOnlyDocument };
        }
        const same_path = options.path == null or (doc.file_path != null and self.pathsEqual(doc.file_path.?, options.path.?));
        if (options.path) |path| {
            const owner = self.findDocument(path) catch |err| return .{ .failed = err };
            if (owner) |other| if (other != idx) {
                // cancelEncoding leaves the current mode, which can shift
                // indices: switch to the destination by id afterwards.
                const other_id = self.documents.items[other].id;
                self.cancelEncoding();
                if (self.docIndexForId(other_id)) |current| self.switchToDoc(current);
                self.status_message = "Destination is already open; save its document instead";
                return .{ .failed = error.DestinationOpen };
            };
            if (!same_path) {
                const stamp = text_file.Stamp.read(self.io, path) catch |err| {
                    if (options.interactive) self.showSaveBlocker(id, .{ .failed = err });
                    return .{ .failed = err };
                };
                if (stamp) |current| if (!options.overwrite or options.destination_stamp == null or !std.meta.eql(current, options.destination_stamp.?)) {
                    if (options.interactive) {
                        var held = options;
                        held.destination_stamp = current;
                        self.holdSave(id, held) catch return .{ .failed = error.OutOfMemory };
                        self.showSaveBlocker(id, .destination_exists);
                    }
                    return .destination_exists;
                };
            }
        }
        if (!options.overwrite and same_path) if (self.saveBlocker(idx)) |blocker| {
            if (options.interactive) {
                self.holdSave(id, options) catch return .{ .failed = error.OutOfMemory };
                self.showSaveBlocker(id, blocker);
            }
            return blocker;
        };
        const old_path = if (options.path != null and doc.file_path != null) self.allocator.dupe(u8, doc.file_path.?) catch return .{ .failed = error.OutOfMemory } else null;
        defer if (old_path) |p| self.allocator.free(p);
        // A server that does not have this document open (too large to
        // send, or not synced yet) cannot format it: save it as it is and
        // say why, instead of failing with ServerNotReady.
        const unformatted = self.formatSkipReason(doc, options);
        var format_options = options;
        if (unformatted != null) format_options.skip_format = true;
        if (self.lsp_tools.maybeFormatSave(self, doc, format_options) catch |err| {
            // Auto-save never switches tabs or closes prompts; it retries.
            if (options.interactive) self.showSaveBlocker(id, .{ .failed = err });
            return .{ .failed = err };
        }) return .formatting;
        const editorconfig_skipped = self.prepareProjectFormatting(doc, options.path orelse doc.file_path orelse return .needs_path, options.format_group) catch |err| {
            if (options.interactive) self.showSaveBlocker(id, .{ .failed = err });
            return .{ .failed = err };
        };
        const result = if (options.path) |p| doc.saveAsWithFormat(self.io, p, options.format) else doc.saveWithFormat(self.io, options.format);
        result catch |err| {
            const outcome: SaveOutcome = if (err == error.UnrepresentableText) .unrepresentable else .{ .failed = err };
            if (options.interactive) {
                if (outcome == .unrepresentable) {
                    self.holdSave(id, options) catch return .{ .failed = error.OutOfMemory };
                } else self.cancelEncoding();
                self.showSaveBlocker(id, outcome);
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
        self.status_message = if (editorconfig_skipped) |why|
            std.fmt.bufPrint(&self.status_buf, "Saved {s} without .editorconfig rules ({s})", .{ doc.display_name, @errorName(why) }) catch "Saved without .editorconfig rules"
        else if (unformatted) |why|
            std.fmt.bufPrint(&self.status_buf, "Saved {s} unformatted ({s})", .{ doc.display_name, why }) catch "Saved unformatted"
        else
            std.fmt.bufPrint(&self.status_buf, "Saved {s}", .{doc.display_name}) catch "Saved";
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
    /// Why format-on-save must pass over `doc` (null = format as usual): a
    /// server that would format it does not have the document open — it is
    /// too large to send, or not yet synced. A format-save of this very
    /// document that is already in flight keeps waiting for its reply.
    fn formatSkipReason(self: *const Editor, doc: *const Document, options: SaveOptions) ?[]const u8 {
        if (!self.lsp_tools.format_on_save or options.skip_format or doc.lsp_opened) return null;
        if (self.lsp_tools.save) |pending| if (pending.id == doc.id) return null;
        const client = self.lspClientForDoc(doc) orelse return null;
        if (!client.capabilities.format_document) return null;
        return if (self.lsp_too_large.contains(doc.id)) "too large for the language server" else "not synced with the language server";
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
        self.setMode(.normal);
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
                self.showSaveBlocker(id, blocker);
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
        self.setMode(.normal);
        const target = self.confirm_overwrite_doc;
        self.confirm_overwrite_doc = null;
        const id = self.pending_save_id orelse blk: {
            const idx = (if (target) |doc_id| self.docIndexForId(doc_id) else null) orelse {
                self.status_message = "Save cancelled (the document was closed)";
                return;
            };
            break :blk self.documents.items[idx].id;
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
                // Another document's format-on-save is still in flight (or
                // this is a preview a Lua timer edited): retried on the next
                // auto-save tick, not a failure.
                .failed => |err| if (err != error.FormattingInProgress and err != error.PreviewDocument) {
                    failed += 1;
                },
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
                    const id = doc.id;
                    self.afterOpen(doc);
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

    /// Split the currently focused pane. The new pane shows the same
    /// document and takes the keyboard.
    pub fn splitActive(self: *Editor, direction: SplitDirection) void {
        const win = self.activeWindow();
        const current_doc_idx = self.activeDocIdx();
        const new_pane = win.layout.splitPane(win.active_pane, direction, .{ .editor = current_doc_idx }) catch return;
        self.cancelSnippets();
        win.active_pane = new_pane;
        // Keep active_doc_idx in sync for compatibility
        self.active_doc_idx = current_doc_idx;
        _ = self.takeKeyboardFocus(.pane);
    }

    /// Close the currently focused pane. If it's the last pane, does nothing.
    pub fn closePaneAction(self: *Editor) void {
        const win = self.activeWindow();
        // A terminal pane closes first, split or not: closeTerminal turns
        // the main window's sole pane back into an editor pane and closes
        // a secondary window with its only pane, so Ctrl+Alt+Q never
        // strands a shell behind the "no split panes" message.
        if (win.active_pane < win.layout.panes.items.len) {
            switch (win.layout.panes.items[win.active_pane].content) {
                .terminal => |idx| {
                    self.cancelSnippets();
                    self.closeTerminal(idx);
                    return;
                },
                .editor => {},
            }
        }
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
        self.cancelSnippets();
        // Focus moves to the closed pane's sibling (its first leaf) — the
        // spatial neighbour, not the next pane in traversal order.
        if (win.layout.closePane(closed_pane)) |sibling| win.active_pane = sibling;
        ensureValidActivePaneIn(win);
        // Update active_doc_idx to match new focused pane
        self.active_doc_idx = self.activeDocIdx();
    }

    /// Focus the next pane in traversal order (within the focused window);
    /// the pane takes the keyboard from a focused side panel (F6).
    pub fn focusNextPane(self: *Editor) void {
        const win = self.activeWindow();
        if (win.layout.nextPane(win.active_pane)) |next| {
            if (next != win.active_pane) self.cancelSnippets();
            win.active_pane = next;
            self.active_doc_idx = self.activeDocIdx();
        }
        _ = self.takeKeyboardFocus(.pane);
    }

    /// Focus the previous pane in traversal order (within the focused
    /// window); like focusNextPane it takes the keyboard from the panels.
    pub fn focusPrevPane(self: *Editor) void {
        const win = self.activeWindow();
        if (win.layout.prevPane(win.active_pane)) |prev| {
            if (prev != win.active_pane) self.cancelSnippets();
            win.active_pane = prev;
            self.active_doc_idx = self.activeDocIdx();
        }
        _ = self.takeKeyboardFocus(.pane);
    }

    /// Set the active pane (of the focused window) by pane ID and update
    /// active_doc_idx. The pane takes the keyboard from the side panels.
    pub fn focusPane(self: *Editor, pane_id: u8) void {
        const win = self.activeWindow();
        if (pane_id < win.layout.panes.items.len) {
            if (pane_id != win.active_pane) self.cancelSnippets();
            win.active_pane = pane_id;
            switch (win.layout.panes.items[pane_id].content) {
                .editor => |idx| self.active_doc_idx = idx,
                .terminal => {},
            }
            _ = self.takeKeyboardFocus(.pane);
        }
    }

    /// Give window `idx` the keyboard focus (no-op for a bad index). Its
    /// focused pane owns the keyboard afterwards: the side panels live in
    /// the primary window and always let go (a panel re-takes it through
    /// takeKeyboardFocus, which focuses the primary first).
    pub fn focusWindow(self: *Editor, idx: usize) void {
        if (idx >= self.windows.items.len) return;
        if (idx != self.active_window) {
            // A prompt or popup opened in one window must not resolve
            // against another window's document — leave it on the way out.
            self.cancelTransientMode();
        }
        self.active_window = idx;
        self.ensureValidActivePane();
        self.active_doc_idx = self.windowDocIdx(idx);
        _ = self.takeKeyboardFocus(.pane);
    }

    /// Focus pane `pane_id` of window `win_idx` — the frontends' click path.
    pub fn focusPaneIn(self: *Editor, win_idx: usize, pane_id: u8) void {
        self.focusWindow(win_idx);
        self.focusPane(pane_id);
    }

    /// Show document `doc_idx` in window `win_idx` (a window's tab bar).
    /// The pane takes the keyboard from the side panels (focusWindow).
    pub fn showDocIn(self: *Editor, win_idx: usize, doc_idx: usize) void {
        // focusWindow can end quick-open, whose preview removal shifts
        // indices: keep the id and find the document again afterwards.
        const id: ?u64 = if (doc_idx < self.documents.items.len) self.documents.items[doc_idx].id else null;
        self.focusWindow(win_idx);
        if (id) |doc_id| if (self.docIndexForId(doc_id)) |idx| self.switchToDoc(idx);
    }

    /// Leave transient input and completion modes. Settings and pending file
    /// decisions follow window focus; the latter retain their document IDs.
    /// Every other prompt ends through setMode, so its owner resolves as
    /// cancelled (a rename preview answers the server applied=false, a git
    /// stage or task save prompt releases its pending operation).
    pub fn cancelTransientMode(self: *Editor) void {
        self.cancelSnippets();
        switch (self.mode) {
            // The snippet form is pinned to one window, like Settings: what
            // was typed into it survives a switch to another window.
            .normal, .settings, .snippet_form, .encoding_picker, .confirm_reopen, .confirm_encoding, .confirm_overwrite, .save_as => {},
            else => self.setMode(.normal),
        }
        self.clearCompletionItems();
    }

    /// THE way to change `mode` (every write in this file goes through it;
    /// frontends and other modules adopt it). Runs the leave-hook of the
    /// OLD mode, then assigns:
    ///   .file_finder       → finderEndSession (drops the preview, restores
    ///                        the pre-finder view, frees the snapshot)
    ///   .filetree_prompt   → frees the prompt target
    ///   .workspace_preview → lsp_tools.resolvePreview(false)
    ///   .git_stage_prompt  → git.resolveStage(false)
    ///   .task_save_prompt  → tasks.resolveSave(.cancel)
    /// Leaving one of the last three this way CANCELS it; to accept, call
    /// the resolver, which leaves the mode itself.
    /// Rules: hooks never run Lua or open documents; the finder hook may
    /// REMOVE the preview document, so callers re-find indices and pointers
    /// by id afterwards; the resolvers a hook calls leave their own mode
    /// with a guarded direct write (`if (mode == .x) mode = .normal`) — a
    /// setMode from inside a hook would only assign (mode_leaving).
    pub fn setMode(self: *Editor, new: Mode) void {
        const old = self.mode;
        if (old == new) return;
        // Re-entry from a hook (a resolver that did call setMode) assigns
        // only: running the old mode's hook again would never end.
        if (!self.mode_leaving) {
            self.mode_leaving = true;
            defer self.mode_leaving = false;
            switch (old) {
                .file_finder => self.finderEndSession(),
                .filetree_prompt => self.freeFiletreePromptTarget(),
                .workspace_preview => self.lsp_tools.resolvePreview(self, false),
                .git_stage_prompt => self.git.resolveStage(self, false),
                .task_save_prompt => self.tasks.resolveSave(self, .cancel),
                .snippet_form => self.snippet_form.reset(self.allocator),
                .snippet_delete_confirm => self.freeSnippetDeleteTarget(),
                else => {},
            }
        }
        self.mode = new;
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
        // A Settings dialog or a snippet form open in this window carries
        // on in the primary, with what was typed.
        if (win.id == self.settings_window_id) self.settings_window_id = self.windows.items[0].id;
        if (win.id == self.snippet_form.window_id) self.snippet_form.window_id = self.windows.items[0].id;
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
            if (src.layout.closePane(src_pane)) |sibling| src.active_pane = sibling;
            ensureValidActivePaneIn(src);
        } else if (content == .terminal) {
            if (src_idx == 0) {
                if (self.appendUntitled(0)) |fresh| src.layout.panes.items[src_pane].content = .{ .editor = fresh };
            } else {
                // The source window closes, and closeWindow stops every
                // terminal its panes still show: the moved terminal must not
                // be one of them (invariant I6). Any live document index
                // serves the frame the window has left (no tab is adopted).
                src.layout.panes.items[src_pane].content = .{ .editor = @min(self.active_doc_idx, self.documents.items.len - 1) };
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

    /// Make window `target` the owner of `doc_idx`'s tab. The previous
    /// owner's panes that showed it switch to its neighbouring tab; when it
    /// was that window's last tab, a secondary window is asked to close and
    /// the primary gets a fresh untitled document (a pane never shows
    /// nothing). No-op for the finder's preview, and while the finder is
    /// peeking at documents (its commit adopts).
    fn adoptDoc(self: *Editor, target: usize, doc_idx: usize) void {
        if (target >= self.windows.items.len or doc_idx >= self.documents.items.len) return;
        if (self.documents.items[doc_idx].preview or self.mode == .file_finder) return;
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
        const command = if (builtin.os.tag == .windows)
            "powershell.exe"
        else
            posixShell(self.io, if (std.c.getenv("SHELL")) |shell| std.mem.span(shell) else null);
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
        _ = self.takeKeyboardFocus(.pane);
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
                    if (win.layout.closePane(pane_u8)) |sibling| {
                        // A focused terminal hands focus to its sibling pane.
                        if (win.active_pane == pane_u8) win.active_pane = sibling;
                    } else {
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
        // The focused pane is a terminal but a side panel has the keyboard:
        // hand it to that terminal rather than leave it or open another.
        if (self.activePaneIsTerminal() and self.keyboardOwner() != .terminal) {
            _ = self.takeKeyboardFocus(.pane);
            return;
        }
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
        if (self.activePaneTerminalIdx()) |idx| {
            self.closeTerminal(idx);
        } else {
            // From the palette or the View menu with an editor pane focused.
            self.status_message = "Close terminal: focus a terminal pane first (Ctrl+Alt+Q closes any pane)";
        }
    }

    // ---- Language / syntax theme operations ----

    // ---- Language servers: configs and clients ----
    //
    // Any number of servers, each registered from Lua (zide.register_lsp)
    // and started lazily the first time a document of a language it serves
    // opens. A document opens on the running client of the NEWEST
    // registration for doc.language (lspConfigFor) and then stays with that
    // server (lsp_doc_owner) until it is closed there — nothing is cached on
    // Documents or LanguageDefs (their names die on re-registration).

    /// Index of the registration that would serve `lang_name`: newest first.
    fn lspConfigIndexFor(self: *const Editor, lang_name: []const u8) ?usize {
        var i = self.lsp_configs.items.len;
        while (i > 0) {
            i -= 1;
            if (self.lsp_configs.items[i].servesLanguage(lang_name)) return i;
        }
        return null;
    }

    /// The registration that would serve `lang_name` — newest first, so a
    /// later zide.register_lsp overrides an earlier one (and the built-in
    /// zls seed). Null when nothing serves the language.
    pub fn lspConfigFor(self: *Editor, lang_name: []const u8) ?*lsp_mod.ServerConfig {
        return &self.lsp_configs.items[self.lspConfigIndexFor(lang_name) orelse return null];
    }

    /// The running client of the registration that serves `lang_name` (see
    /// lspConfigFor; its handshake may still be pending). An older server
    /// that also lists the language is never picked: when the newest
    /// registration has no client yet, this is null and lspNotifyOpen
    /// starts one.
    pub fn lspClientForLanguage(self: *const Editor, lang_name: []const u8) ?*lsp_mod.LspClient {
        const wanted = &self.lsp_configs.items[self.lspConfigIndexFor(lang_name) orelse return null];
        for (self.lsp_clients.items) |client| {
            const cfg = if (client.config) |*c| c else continue;
            if (cfg.eql(wanted)) return client;
        }
        return null;
    }

    /// The server a document talks to: the one that got its didOpen while
    /// it is open there (null if that server is gone), else the client for
    /// its language.
    pub fn lspClientForDoc(self: *const Editor, doc: *const Document) ?*lsp_mod.LspClient {
        if (doc.lsp_opened) if (self.lsp_doc_owner.get(doc.id)) |generation| return self.lspClientByGeneration(generation);
        const lang = doc.language orelse return null;
        return self.lspClientForLanguage(lang.name);
    }

    fn lspClientByGeneration(self: *const Editor, generation: u64) ?*lsp_mod.LspClient {
        for (self.lsp_clients.items) |client| if (client.generation == generation) return client;
        return null;
    }

    /// Whether `doc` is open on `client`. A document opened without an
    /// owner record (a failed record insert) counts as open on every
    /// server of its language, so a stop re-opens it rather than strands it.
    fn lspDocOpenOn(self: *const Editor, doc: *const Document, client: *const lsp_mod.LspClient) bool {
        if (!doc.lsp_opened) return false;
        if (self.lsp_doc_owner.get(doc.id)) |generation| return generation == client.generation;
        const cfg = if (client.config) |*c| c else return false;
        const lang = doc.language orelse return false;
        return cfg.servesLanguage(lang.name);
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

    /// Review verdicts persist under the config dir; the record itself is
    /// picked per repository once Git has found the root (review.tick).
    pub fn startReviewWorkspace(self: *Editor) void {
        if (@import("lua_settings.zig").getConfigDir()) |base| self.review.configureStorage(self, base);
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
        self.normalizeKeyboardFocus();
        self.deadlines.tick(self, now);
        self.tasks.tick(self);
        self.git.tick(self, now);
        self.review.tick(self, now);
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
            self.setMode(.recovery_picker);
            return;
        };
        self.status_message = "No recovery snapshots for this workspace";
    }

    pub fn resolveRecovery(self: *Editor, choice: enum { recover, discard, later }) void {
        self.setMode(.normal);
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

    /// Save-time EditorConfig normalization (trim_trailing_whitespace,
    /// end_of_line, insert_final_newline) as minimal per-line edits: each
    /// changed line pair loses its common prefix AND suffix, so a trim is a
    /// pure delete before the line break and CRLF→LF deletes only the `\r`.
    /// Carets never cross a line break (see mapNormalized), and the edit is
    /// its own undo group, never merged into the user's typing. EditorConfig
    /// trouble never fails a save: returns the error that made it skip the
    /// rules (an unreadable .editorconfig), else null.
    fn prepareProjectFormatting(self: *Editor, doc: *Document, path: []const u8, format_group: ?u64) !?anyerror {
        if (!self.editorconfig_enabled) return null;
        // A cached .editorconfig that can no longer be re-read (replaced by
        // a directory, share gone) counts as unchanged.
        _ = self.project_formatting.refresh() catch false;
        const rules = self.project_formatting.resolve(path) catch |err| {
            std.log.warn("EditorConfig for {s}: {s}; saved without normalizing", .{ path, @errorName(err) });
            const skipped: ?anyerror = err;
            return skipped;
        };
        // An explicit end_of_line rule decides what Enter inserts from now on.
        defer if (rules.eol) |eol| {
            doc.crlf = eol == .crlf;
        };
        if (rules.eol == null and rules.final_newline == null and !(rules.trim orelse false)) return null;
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
            var suffix: usize = 0;
            while (suffix < old_line.len - prefix and suffix < new_line.len - prefix and
                old_line[old_line.len - 1 - suffix] == new_line[new_line.len - 1 - suffix]) : (suffix += 1)
            {}
            if (prefix + suffix != old_line.len or prefix + suffix != new_line.len) try ranges.append(self.allocator, .{
                .start = old_at + prefix,
                .end = old_end - suffix,
                .text = new_line[prefix .. new_line.len - suffix],
            });
            old_at = old_end;
            new_at = new_end;
        }
        if (ranges.items.len == 0) {
            doc.detectLineEndings();
            return null;
        }
        // Where every caret and anchor must end up, from the ascending
        // ranges: the commit alone would push a caret sitting at an
        // insertion point (end of line, EOF) past the inserted line break.
        const Cursor = @import("cursor.zig").Cursor;
        const targets = try self.allocator.dupe(Cursor, doc.cursors.cursors.items);
        defer self.allocator.free(targets);
        const clamped = try self.allocator.alloc(bool, targets.len);
        defer self.allocator.free(clamped);
        for (targets, clamped) |*c, *in_span| {
            const moved = mapNormalized(ranges.items, c.offset);
            in_span.* = moved.in_span;
            c.offset = moved.offset;
            if (c.anchor) |a| c.anchor = mapNormalized(ranges.items, a).offset;
        }
        std.mem.reverse(Document.RangeEdit, ranges.items);
        const join = format_group != null and doc.history.undo_stack.items.len > 0 and doc.history.undo_stack.items[doc.history.undo_stack.items.len - 1].group_id == format_group.?;
        // Its own undo group (or the formatter's, when joining one): never
        // coalesced into the user's typing — a lone 1-byte trim would
        // otherwise merge into the preceding Backspace run.
        doc.history.merge_allowed = false;
        try doc.beginEdit();
        defer doc.endEdit();
        if (join) doc.history.active_group = format_group.?;
        try doc.applyRanges(ranges.items);
        // Before endEdit, so undo/redo restore these positions too.
        if (doc.cursors.cursors.items.len == targets.len) {
            for (doc.cursors.cursors.items, targets, clamped) |*c, target, in_span| {
                c.* = target;
                // Only a caret the edit moved gets a new sticky column.
                if (in_span) c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
            }
            doc.cursors.mergeCursors();
        }
        doc.detectLineEndings();
        return null;
    }

    /// Map an offset through ascending, disjoint normalization ranges. A
    /// position inside a changed span or at either of its edges lands at
    /// the span start — before any inserted line-break material, so a
    /// caret at the end of a line (or at EOF) stays on its line.
    fn mapNormalized(ranges: []const Document.RangeEdit, offset: usize) struct { offset: usize, in_span: bool } {
        var removed: usize = 0;
        var inserted: usize = 0;
        for (ranges) |r| {
            if (offset < r.start) break;
            if (offset <= r.end) return .{ .offset = r.start - removed + inserted, .in_span = true };
            removed += r.end - r.start;
            inserted += r.text.len;
        }
        return .{ .offset = offset - removed + inserted, .in_span = false };
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
        if (self.keyboardOwner() == .editor) {
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
        if (self.lspClientForDoc(doc)) |client| {
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

    /// Stop and free the client at `idx`; the documents open on it (and
    /// only those — another server of the same language keeps its own)
    /// forget they were opened, so the next sync re-opens them on whatever
    /// serves them now.
    fn stopLspClient(self: *Editor, idx: usize) void {
        const client = self.lsp_clients.items[idx];
        self.lsp_tools.clientStopped(self, client);
        var producer_buf: [256]u8 = undefined;
        self.problems.clear(.lsp, client.diagnosticSource(&producer_buf));
        if (self.completion_context) |ctx| {
            if (ctx.client == client) self.clearCompletionItems();
        }
        for (self.documents.items) |*doc| {
            if (!self.lspDocOpenOn(doc, client)) continue;
            doc.lsp_opened = false;
            _ = self.lsp_doc_owner.remove(doc.id);
            doc.clearDiagnostics();
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
    /// whose registration vanished, changed, or is now outranked for every
    /// language it lists. Identical registrations keep their server (no
    /// clangd restart on every reload); a server outranked for only some of
    /// its languages keeps running, and its documents of those languages
    /// close there so the next sync opens them on the newer registration.
    pub fn reconcileLspClients(self: *Editor) void {
        var i: usize = 0;
        while (i < self.lsp_clients.items.len) {
            const client = self.lsp_clients.items[i];
            const running_cfg = if (client.config) |*c| c else {
                self.stopLspClient(i);
                continue;
            };
            var serves_any = false;
            for (running_cfg.languages) |lang| {
                const current = self.lspConfigFor(lang) orelse continue;
                if (current.eql(running_cfg)) serves_any = true;
            }
            if (!serves_any) {
                std.log.info("LSP[{s}] registration changed or removed — stopping", .{client.name()});
                self.stopLspClient(i);
                continue;
            }
            for (self.documents.items) |*doc| {
                if (!doc.lsp_opened) continue;
                const owner = self.lsp_doc_owner.get(doc.id) orelse continue;
                if (owner != client.generation) continue;
                const lang = doc.language orelse continue;
                const current = self.lspConfigFor(lang.name);
                if (current == null or !current.?.eql(running_cfg)) self.lspForgetDoc(doc);
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
        // Index loop: the list may change under a response (a Lua hook run
        // while handling one can stop clients). Replies that would open or
        // save a file — whose hooks may restart servers — only queue that
        // work for lsp_tools.tick below.
        var j: usize = 0;
        while (j < self.lsp_clients.items.len) : (j += 1) {
            self.lsp_clients.items[j].pollMessages(self);
            if (j >= self.lsp_clients.items.len) break;
            self.lsp_clients.items[j].expireRequests(self, std.Io.Clock.now(.awake, self.io).nanoseconds);
        }
        // Deferred work the responses queued (the goto-definition jump, the
        // post-format save), run outside any client's message handling.
        self.lsp_tools.tick(self);
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
        self.setDocLanguage(doc, self.findLanguage(ext));
    }

    /// Give a document another language (or none): the LSP forgets it
    /// under the old one first and the highlight cache is dropped. Same
    /// pointer = nothing to do.
    pub fn setDocLanguage(self: *Editor, doc: *Document, lang: ?*const syntax.LanguageDef) void {
        if (lang == doc.language) return;
        self.lspForgetDoc(doc);
        doc.language = lang;
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
    /// A document whose full text cannot fit one frame is marked for its
    /// current version and skipped until an edit changes it, so a huge file
    /// is not JSON-escaped again on every sync.
    pub fn lspNotifyOpen(self: *Editor, doc: *Document) void {
        if (!self.lsp_enabled) return;
        if (doc.lsp_opened or doc.preview) return;
        const path = doc.file_path orelse return;
        const lang = doc.language orelse return;
        if (self.lspTooLargeNow(doc)) return;

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
        if (self.lspFrameTooLarge(doc, uri.len + lang_id.len)) {
            self.markLspTooLarge(doc);
            return;
        }
        const text = doc.buffer.slice(0, doc.buffer.byteLen());

        client.sendDidOpen(uri, lang_id, doc.lsp_version, text) catch return;
        doc.lsp_opened = true;
        doc.lsp_last_synced = doc.lsp_version;
        _ = self.lsp_too_large.remove(doc.id);
        // Without the record the document still works: it counts as open on
        // every server of its language (lspDocOpenOn).
        self.lsp_doc_owner.put(self.allocator, doc.id, client.generation) catch {};
        std.log.info("LSP[{s}] didOpen: {s} (languageId={s})", .{ client.name(), uri, lang_id });
    }

    /// Forget a document on the LSP side: didClose (to the server that has
    /// it) for its CURRENT path, `lsp_opened` cleared, the server's
    /// diagnostics dropped, and its versioned Problems entries too — their
    /// versions belong to this document instance. Path and language are
    /// taken as they are at call time, so callers that change either
    /// (rename, save-as, re-detection) must call this FIRST. Also drops a
    /// too-large mark (the next sync measures again); nothing else happens
    /// when the document was never opened with LSP.
    pub fn lspForgetDoc(self: *Editor, doc: *Document) void {
        _ = self.lsp_too_large.remove(doc.id);
        if (!doc.lsp_opened) return;
        const client = self.lspClientForDoc(doc);
        doc.lsp_opened = false;
        _ = self.lsp_doc_owner.remove(doc.id);
        doc.clearDiagnostics();
        const path = doc.file_path orelse return;
        self.problems.forgetVersioned(path);
        const server = client orelse return;

        const uri = lsp_mod.pathToUri(self.allocator, path) catch return;
        defer self.allocator.free(uri);

        server.sendDidClose(uri) catch {};
    }

    /// `doc` was found too large for one frame at its current version.
    fn lspTooLargeNow(self: *const Editor, doc: *const Document) bool {
        const version = self.lsp_too_large.get(doc.id) orelse return false;
        return version == doc.lsp_version;
    }

    /// Remember that `doc` does not fit one frame at its current version;
    /// say so once per document (later versions update the mark quietly).
    fn markLspTooLarge(self: *Editor, doc: *const Document) void {
        const first = !self.lsp_too_large.contains(doc.id);
        self.lsp_too_large.put(self.allocator, doc.id, doc.lsp_version) catch return;
        if (!first) return;
        std.log.warn("LSP: {s} ({d} bytes) does not fit one message; not sent to the language server", .{ doc.display_name, doc.buffer.byteLen() });
        self.status_message = std.fmt.bufPrint(&self.status_buf, "LSP: {s} is too large for the language server", .{doc.display_name}) catch "LSP: document too large for the language server";
    }

    /// Whether a full-text didOpen/didChange of `doc` would exceed
    /// `lsp_frame_limit`. `extra` is the variable unescaped part (uri,
    /// languageId); 256 bytes cover the method, the JSON keys and the
    /// version. Escaping never shrinks a byte and at most sextuples one
    /// (`\u00XX`), so only documents near the limit are scanned, counting
    /// the escapes lsp.writeJsonString writes.
    fn lspFrameTooLarge(self: *const Editor, doc: *Document, extra: usize) bool {
        const envelope = extra +| 256;
        if (envelope >= self.lsp_frame_limit) return true;
        const room = self.lsp_frame_limit - envelope;
        const len = doc.buffer.byteLen();
        if (len +| 2 > room) return true;
        if (len <= (room - 2) / 6) return false;
        var escaped: usize = 2; // the quotes
        for (doc.buffer.slice(0, len)) |c| {
            escaped += switch (c) {
                '"', '\\', '\n', '\r', '\t' => 2,
                else => if (c < 0x20) 6 else 1,
            };
            if (escaped > room) return true;
        }
        return false;
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

            if (self.lspFrameTooLarge(doc, uri.len)) {
                // The server cannot get this version: close the document
                // there rather than leave it a stale copy. It re-opens once
                // an edit makes it fit (lspNotifyOpen measures per version).
                self.lspForgetDoc(doc);
                self.markLspTooLarge(doc);
                continue;
            }
            const text = doc.buffer.slice(0, doc.buffer.byteLen());
            client.sendDidChange(uri, doc.lsp_version, text) catch continue;
            doc.lsp_last_synced = doc.lsp_version;
        }
    }

    /// Clear all completion items (frees memory).
    pub fn clearCompletionItems(self: *Editor) void {
        self.completion_context = null;
        self.completion_generation +%= 1;
        for (self.completion_all.items) |*item| {
            self.allocator.free(item.label);
            if (item.detail) |d| self.allocator.free(d);
            if (item.insert_text) |t| self.allocator.free(t);
        }
        self.completion_all.clearRetainingCapacity();
        self.completion_items.clearRetainingCapacity();
        self.completion_active = false;
        self.completion_stale = false;
        self.completion_selected = 0;
    }

    /// Add a completion item (called from LSP response handler).
    pub fn addCompletionItem(self: *Editor, label: []const u8, detail: ?[]const u8, insert_text: ?[]const u8) !void {
        try self.addCompletionEntry(.{ .label = label, .detail = detail, .insert_text = insert_text });
    }
    pub fn addCompletionEntry(self: *Editor, item: EditorCompletionItem) !void {
        // Both appends are reserved first: once the item is in the owner
        // list a failure must not hand it back to the caller to free.
        try self.completion_all.ensureUnusedCapacity(self.allocator, 1);
        try self.completion_items.ensureUnusedCapacity(self.allocator, 1);
        self.completion_all.appendAssumeCapacity(item);
        if (self.completion_context == null) self.completion_context = .{
            .doc_id = self.activeDoc().id,
            .version = self.activeDoc().buffer.version,
            .cursor_offset = self.activeDoc().cursors.primaryConst().offset,
            .generation = self.completion_generation,
        };
        if (self.completionMatches(item)) {
            self.completion_items.appendAssumeCapacity(item);
            self.completion_active = true;
        }
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

    /// The identifier bytes just before the caret — what the popup is
    /// filtered by (at most 64 bytes).
    fn completionPrefix(self: *const Editor, buf: *[64]u8) []const u8 {
        const doc = &self.documents.items[self.activeDocIdx()];
        const caret = doc.cursors.primaryConst().offset;
        var start = caret;
        while (start > 0 and caret - start < buf.len and isIdentChar(doc.buffer.byteAt(start - 1) orelse 0)) start -= 1;
        var i: usize = 0;
        while (start + i < caret) : (i += 1) buf[i] = doc.buffer.byteAt(start + i) orelse 0;
        return buf[0..i];
    }

    fn completionPrefixLen(self: *const Editor) usize {
        var pbuf: [64]u8 = undefined;
        return self.completionPrefix(&pbuf).len;
    }

    fn completionMatches(self: *const Editor, item: EditorCompletionItem) bool {
        var pbuf: [64]u8 = undefined;
        const prefix = self.completionPrefix(&pbuf);
        if (prefix.len == 0) return true;
        return std.ascii.startsWithIgnoreCase(item.label, prefix);
    }

    /// Rebuild the visible list for the prefix now before the caret (after
    /// typing). No match leaves the popup closed until the next reply.
    pub fn refilterCompletion(self: *Editor) void {
        self.completion_items.clearRetainingCapacity();
        for (self.completion_all.items) |item| {
            if (self.completionMatches(item)) self.completion_items.append(self.allocator, item) catch break;
        }
        if (self.completion_selected >= self.completion_items.items.len) self.completion_selected = 0;
        self.completion_active = self.completion_items.items.len > 0;
    }

    fn completionTriggerByte(self: *Editor, b: u8) bool {
        const client = self.lspClientForDoc(self.activeDoc()) orelse return false;
        return client.capabilities.isCompletionTrigger(b);
    }

    /// Does typing `b` keep the popup open? Identifier characters narrow
    /// it and a server trigger character refreshes it; anything else
    /// dismisses it (the frontends ask before passing the key through).
    pub fn completionKeepsOnByte(self: *Editor, b: u8) bool {
        return isIdentChar(b) or self.completionTriggerByte(b);
    }

    /// After `insert_char` typed `text`: open, refresh or dismiss the
    /// completion popup.
    pub fn afterTypedText(self: *Editor, text: []const u8) void {
        if (self.mode != .normal or text.len == 0) return;
        if (self.activeDoc().cursors.count() > 1) return;
        const b = text[0];
        if (b == ')' and self.signature != null) self.clearSignature();
        if (self.signature_help_auto and self.signatureTriggerByte(b)) self.lsp_tools.startQuiet(self, .signature_help);
        if (self.completionTriggerByte(b)) {
            if (self.completion_auto or self.completion_active) self.requestCompletion(false);
            return;
        }
        if (isIdentChar(b)) {
            if (self.completion_active) {
                self.refilterCompletion();
                self.requestCompletion(true);
            } else if (self.completion_auto and self.completionPrefixLen() >= self.completion_min_chars) {
                self.requestCompletion(false);
            }
            return;
        }
        if (self.completion_active) self.clearCompletionItems();
    }

    /// Trigger LSP completion at the current cursor position.
    pub fn triggerCompletion(self: *Editor) void {
        self.requestCompletion(false);
    }

    /// Ask the server for completions at the caret. `keep` leaves the
    /// current (filtered) list visible, marked stale, until the reply
    /// replaces it.
    fn requestCompletion(self: *Editor, keep: bool) void {
        if (!keep) self.clearCompletionItems();
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
        if (keep) self.completion_stale = true;
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
        // The list on screen belongs to a superseded request: its edits no
        // longer fit the text, so close it rather than apply them.
        if (self.completion_stale) {
            self.clearCompletionItems();
            return;
        }
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

    pub fn registerSnippet(self: *Editor, spec: snippets_mod.Spec) ![]const u8 {
        var def = try snippets_mod.Definition.init(self.allocator, spec, self.loading_extensions);
        errdefer def.deinit(self.allocator);
        if (self.loading_extension_name) |name| def.source = try self.allocator.dupe(u8, name);
        var replace: ?usize = null;
        for (self.snippets.items.items, 0..) |*old, i| {
            if (std.mem.eql(u8, old.command, def.command)) {
                replace = i;
                break;
            }
        }
        if (replace == null) try self.snippets.items.ensureUnusedCapacity(self.allocator, 1);
        try self.commands.registerSnippet(def.command, def.description);
        if (replace) |i| {
            self.snippets.items.items[i].deinit(self.allocator);
            self.snippets.items.items[i] = def;
        } else self.snippets.items.appendAssumeCapacity(def);
        self.snippets.revision += 1;
        return def.command;
    }

    pub fn dropExtensionSnippets(self: *Editor) void {
        self.cancelSnippets();
        var i = self.snippets.items.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.snippets.items.items[i].from_extension) continue;
            var def = self.snippets.items.orderedRemove(i);
            self.commands.removeSnippet(def.command);
            def.deinit(self.allocator);
        }
        self.snippets.revision += 1;
    }

    /// Drop the snippet registered as `command`, palette entry included;
    /// false when there is none.
    pub fn removeSnippet(self: *Editor, command: []const u8) bool {
        for (self.snippets.items.items, 0..) |*def, i| {
            if (!std.mem.eql(u8, def.command, command)) continue;
            self.cancelSnippets();
            var removed = self.snippets.items.orderedRemove(i);
            self.commands.removeSnippet(removed.command);
            removed.deinit(self.allocator);
            self.snippets.revision += 1;
            return true;
        }
        return false;
    }

    /// Where the panel keeps the user's own snippets:
    /// `<config dir>/extensions/my-snippets.lua`; null without a config
    /// directory.
    pub fn mySnippetsPath(buf: []u8) ?[]const u8 {
        return @import("lua_settings.zig").extensionFilePath(buf, snippet_file.file_name);
    }

    /// snippet_save_selection (Ctrl+Alt+S): open the form, prefilled from
    /// the selection, to save it to my-snippets.lua. A refusal goes to the
    /// status bar and opens nothing.
    pub fn startSnippetSave(self: *Editor) void {
        if (self.mode != .normal) return;
        if (self.activePaneIsTerminal()) {
            self.status_message = "Save as snippet: focus an editor pane with a selection first";
            return;
        }
        const doc = self.activeDoc();
        if (doc.cursors.count() != 1) {
            self.status_message = "Save as snippet: needs a single cursor";
            return;
        }
        const selection = doc.selectedText() orelse "";
        if (selection.len == 0) {
            self.status_message = "Save as snippet: select the code first";
            return;
        }
        if (!std.unicode.utf8ValidateSlice(selection)) {
            self.status_message = "Save as snippet: the selection is not valid UTF-8";
            return;
        }
        // The selection may sit in a shared scratch buffer: prepare it now.
        const body = snippet_form_mod.prepareBody(self.allocator, selection) catch {
            self.status_message = "Save as snippet: out of memory";
            return;
        };
        defer self.allocator.free(body);
        if (body.len == 0) {
            // Only blanks and line breaks were selected.
            self.status_message = "Save as snippet: select the code first";
            return;
        }
        if (body.len >= snippet_form_mod.max_body) {
            self.status_message = "Save as snippet: the selection is too long (8 KiB max)";
            return;
        }
        const form = &self.snippet_form;
        form.reset(self.allocator);
        form.set(.folder, form.lastFolder());
        form.set(.language, if (doc.language) |lang| lang.name else "*");
        form.setRaw(.body, body);
        self.openSnippetForm(.save);
    }

    /// Show the form, its fields already filled, pinned to the active window.
    fn openSnippetForm(self: *Editor, kind: snippet_form_mod.Kind) void {
        const form = &self.snippet_form;
        form.kind = kind;
        form.field = .name;
        form.error_message = "";
        form.window_id = self.activeWindow().id;
        self.setMode(.snippet_form);
    }

    /// Leave the form without saving (Escape, Cancel, the dialog's X).
    pub fn cancelSnippetForm(self: *Editor) void {
        if (self.mode == .snippet_form) self.setMode(.normal);
    }

    /// Save the form: check it the way the registry would, write its block
    /// to my-snippets.lua, register the snippet and leave the form. False
    /// keeps the form open with `snippet_form.error_message` saying why.
    pub fn submitSnippetForm(self: *Editor) bool {
        const form = &self.snippet_form;
        form.error_message = "";
        const spec = form.spec();
        var probe = snippets_mod.Definition.init(self.allocator, spec, true) catch |err| {
            form.error_message = snippet_form_mod.errorMessage(err);
            return false;
        };
        defer probe.deinit(self.allocator);
        if (self.commands.get(probe.command)) |existing| {
            if (!existing.snippet) {
                form.error_message = snippets_mod.errorMessage(error.CommandConflict);
                return false;
            }
        }
        var path_buf: [512]u8 = undefined;
        const path = mySnippetsPath(&path_buf) orelse {
            form.error_message = "No config directory (HOME / USERPROFILE is not set)";
            return false;
        };
        // The file open in a tab with unsaved edits: writing would lose them.
        const open_doc: ?usize = self.findDocument(path) catch null;
        if (open_doc) |idx| {
            if (self.documents.items[idx].dirty) {
                form.error_message = "my-snippets.lua has unsaved changes in a tab: save or close it first";
                return false;
            }
        }
        const text = snippet_file.read(self.allocator, self.io, path) catch |err| {
            form.error_message = form.fail("Cannot read my-snippets.lua: {s}", .{@errorName(err)});
            return false;
        };
        defer self.allocator.free(text);
        if (form.editing) |old| {
            // Editing: the block must still be there as the panel wrote it
            // (a hand edit may have removed or doubled its markers) — else
            // the file is the place to work on it.
            const found = snippet_file.findBlock(text, old) catch |err| {
                self.snippetFormOpenFileInstead(path, switch (err) {
                    error.Duplicate => "my-snippets.lua has two blocks for this snippet: opening the file",
                    error.Unterminated => "my-snippets.lua has a damaged block for this snippet (no `-- zide:end` line): opening the file",
                });
                return true;
            };
            if (found == null) {
                self.snippetFormOpenFileInstead(path, "my-snippets.lua no longer has a block for this snippet: opening the file");
                return true;
            }
            // A new name must not take over another snippet's block.
            if (!std.mem.eql(u8, old, probe.command)) {
                const clash = snippet_file.findBlock(text, probe.command) catch null;
                if (clash != null) {
                    form.error_message = "my-snippets.lua already has a snippet with this name";
                    return false;
                }
            }
        }
        const block = snippet_file.renderBlock(self.allocator, probe.command, spec) catch |err| {
            form.error_message = switch (err) {
                error.MarkerInBody => "A snippet body cannot contain a `-- zide:` marker line",
                error.OutOfMemory => "Save as snippet: out of memory",
            };
            return false;
        };
        defer self.allocator.free(block);
        const lookup = form.editing orelse probe.command;
        const new_text = snippet_file.upsert(self.allocator, text, lookup, block) catch |err| {
            form.error_message = switch (err) {
                error.Duplicate => "my-snippets.lua has two blocks for this snippet: fix the file by hand",
                error.Unterminated => "my-snippets.lua has a damaged block for this snippet (no `-- zide:end` line): fix the file by hand",
                error.OutOfMemory => "Save as snippet: out of memory",
            };
            return false;
        };
        defer self.allocator.free(new_text);
        snippet_file.write(self.allocator, self.io, path, new_text) catch |err| {
            form.error_message = form.fail("Cannot write my-snippets.lua: {s}", .{@errorName(err)});
            return false;
        };
        // A clean tab shows the new text at once (the external-change poll
        // would reload it a second later and overwrite the status line).
        if (open_doc) |idx| self.documents.items[idx].reloadFromDisk(self.io) catch {};
        // A renamed snippet: its old definition goes with its old name.
        if (form.editing) |old| {
            if (!std.mem.eql(u8, old, probe.command)) _ = self.removeSnippet(old);
        }
        // Register it the way the file will on the next load: an extension
        // snippet from my-snippets.lua.
        self.loading_extensions = true;
        self.loading_extension_name = snippet_file.file_name;
        const registered = self.registerSnippet(spec);
        self.loading_extensions = false;
        self.loading_extension_name = null;
        const command = registered catch |err| {
            // Written, so it is live after a reload; say what went wrong now.
            self.status_message = snippets_mod.errorMessage(err);
            self.setMode(.normal);
            return true;
        };
        form.rememberFolder(spec.group);
        self.status_message = std.fmt.bufPrint(&self.status_buf, "Saved to my-snippets.lua: {s}", .{spec.description}) catch "Saved to my-snippets.lua";
        self.setMode(.normal);
        if (self.snippets_visible) self.selectSnippetRow(command);
        return true;
    }

    // ---- Snippets panel: edit, copy and delete the user's own ----

    fn freeSnippetDeleteTarget(self: *Editor) void {
        if (self.snippet_delete_target) |target| self.allocator.free(target);
        self.snippet_delete_target = null;
    }

    /// Fill the form from a registered snippet (its body with the blanks).
    fn fillSnippetFormFrom(self: *Editor, def: *const snippets_mod.Definition) void {
        const form = &self.snippet_form;
        form.reset(self.allocator);
        form.set(.name, def.description);
        form.set(.folder, def.group);
        form.set(.trigger, def.prefix);
        form.set(.language, def.language);
        form.setRaw(.notes, def.notes);
        form.setRaw(.body, def.body);
    }

    /// F2 / the context menu on a snippet of my-snippets.lua: the form
    /// with its fields; Save rewrites its block (a new name moves it).
    pub fn startSnippetEdit(self: *Editor, def_index: usize) void {
        if (self.mode != .normal or def_index >= self.snippets.items.items.len) return;
        const def = &self.snippets.items.items[def_index];
        self.fillSnippetFormFrom(def);
        self.snippet_form.editing = self.allocator.dupe(u8, def.command) catch {
            self.status_message = "Edit snippet: out of memory";
            return;
        };
        self.openSnippetForm(.edit);
    }

    /// F2 / the context menu on any other snippet: the form with its
    /// fields; Save puts a copy into my-snippets.lua (under the same name
    /// it replaces the original in the panel, since that file loads last).
    pub fn startSnippetCopy(self: *Editor, def_index: usize) void {
        if (self.mode != .normal or def_index >= self.snippets.items.items.len) return;
        self.fillSnippetFormFrom(&self.snippets.items.items[def_index]);
        self.openSnippetForm(.copy);
    }

    /// Delete on a snippet of my-snippets.lua: ask first.
    pub fn startSnippetDelete(self: *Editor, def_index: usize) void {
        if (self.mode != .normal or def_index >= self.snippets.items.items.len) return;
        const def = &self.snippets.items.items[def_index];
        if (!snippet_file.isMine(def)) {
            self.status_message = "Only snippets in my-snippets.lua can be deleted here (F2 copies one there)";
            return;
        }
        self.freeSnippetDeleteTarget();
        self.snippet_delete_target = self.allocator.dupe(u8, def.command) catch {
            self.status_message = "Delete snippet: out of memory";
            return;
        };
        self.setMode(.snippet_delete_confirm);
    }

    /// The question both frontends ask while `.snippet_delete_confirm`.
    pub fn snippetDeletePrompt(self: *const Editor, buf: []u8) []const u8 {
        const name: []const u8 = if (self.snippet_delete_target) |cmd| (if (self.snippets.command(cmd)) |def| def.description else cmd) else "";
        return std.fmt.bufPrint(buf, "Delete snippet \"{s}\" from my-snippets.lua? [Y]es / any other key cancels: ", .{name}) catch "Delete this snippet from my-snippets.lua? [Y]es / any other key cancels: ";
    }

    pub fn cancelSnippetDelete(self: *Editor) void {
        if (self.mode == .snippet_delete_confirm) self.setMode(.normal);
    }

    /// `y` to the question: the block leaves my-snippets.lua and the
    /// snippet leaves the registry and the panel.
    pub fn applySnippetDelete(self: *Editor) void {
        if (self.mode != .snippet_delete_confirm) return;
        var cmd_buf: [512]u8 = undefined;
        const target = self.snippet_delete_target orelse {
            self.setMode(.normal);
            return;
        };
        const n = @min(target.len, cmd_buf.len);
        @memcpy(cmd_buf[0..n], target[0..n]);
        const command: []const u8 = cmd_buf[0..n];
        self.setMode(.normal); // frees the target
        var name_buf: [128]u8 = undefined;
        const name: []const u8 = blk: {
            const def = self.snippets.command(command) orelse break :blk command;
            const m = @min(def.description.len, name_buf.len);
            @memcpy(name_buf[0..m], def.description[0..m]);
            break :blk name_buf[0..m];
        };
        var path_buf: [512]u8 = undefined;
        const path = mySnippetsPath(&path_buf) orelse {
            self.status_message = "No config directory (HOME / USERPROFILE is not set)";
            return;
        };
        const open_doc: ?usize = self.findDocument(path) catch null;
        if (open_doc) |idx| {
            if (self.documents.items[idx].dirty) {
                self.status_message = "my-snippets.lua has unsaved changes in a tab: save or close it first";
                return;
            }
        }
        const text = snippet_file.read(self.allocator, self.io, path) catch |err| {
            self.status_message = std.fmt.bufPrint(&self.status_buf, "Cannot read my-snippets.lua: {s}", .{@errorName(err)}) catch "Cannot read my-snippets.lua";
            return;
        };
        defer self.allocator.free(text);
        const removal = snippet_file.remove(self.allocator, text, command) catch {
            self.status_message = "Delete snippet: out of memory";
            return;
        };
        defer self.allocator.free(removal.text);
        if (removal.removed > 0) {
            snippet_file.write(self.allocator, self.io, path, removal.text) catch |err| {
                self.status_message = std.fmt.bufPrint(&self.status_buf, "Cannot write my-snippets.lua: {s}", .{@errorName(err)}) catch "Cannot write my-snippets.lua";
                return;
            };
            if (open_doc) |idx| self.documents.items[idx].reloadFromDisk(self.io) catch {};
        }
        _ = self.removeSnippet(command);
        self.status_message = if (removal.removed > 0)
            std.fmt.bufPrint(&self.status_buf, "Deleted from my-snippets.lua: {s}", .{name}) catch "Deleted from my-snippets.lua"
        else
            std.fmt.bufPrint(&self.status_buf, "my-snippets.lua had no block for {s}: removed from the panel only", .{name}) catch "my-snippets.lua had no block for it: removed from the panel only";
    }

    /// F2 / the context menu on the panel's selected row: a snippet of
    /// my-snippets.lua opens for editing, any other for copying there.
    pub fn snippetPanelEdit(self: *Editor) void {
        const def_index = self.snippetPanelSelectedDef() orelse return;
        if (snippet_file.isMine(&self.snippets.items.items[def_index])) self.startSnippetEdit(def_index) else self.startSnippetCopy(def_index);
    }

    /// Delete on the panel's selected row (snippets of my-snippets.lua only).
    pub fn snippetPanelDelete(self: *Editor) void {
        const def_index = self.snippetPanelSelectedDef() orelse return;
        self.startSnippetDelete(def_index);
    }

    /// The registry index of the panel's selected item; a group or no
    /// selection says so in the status bar.
    fn snippetPanelSelectedDef(self: *Editor) ?usize {
        const panel = &self.snippet_panel;
        if (panel.rowAt(panel.selected)) |row| {
            if (row.kind == .item and row.def < self.snippets.items.items.len) return row.def;
        }
        self.status_message = "Select a snippet first";
        return null;
    }

    /// Edit found no usable block: say so, leave the form and open the
    /// file, where the snippet can be fixed by hand.
    fn snippetFormOpenFileInstead(self: *Editor, path: []const u8, message: []const u8) void {
        self.cancelSnippetForm();
        _ = self.openOrFocus(path) catch null;
        self.status_message = message;
    }

    /// Put the panel's selection on the snippet registered as `command`,
    /// opening its group when it is closed.
    fn selectSnippetRow(self: *Editor, command: []const u8) void {
        var opened = false;
        while (true) {
            const panel = self.syncSnippetPanel();
            const defs = self.snippets.items.items;
            for (panel.rows.items, 0..) |row, i| {
                if (row.kind != .item or row.def >= defs.len) continue;
                if (std.mem.eql(u8, defs[row.def].command, command)) {
                    panel.selected = i;
                    panel.scroll_to_selected = true;
                    return;
                }
            }
            if (opened) return;
            const def = self.snippets.command(command) orelse return;
            for (panel.groups.items, 0..) |g, gi| {
                if (!g.expanded and std.mem.eql(u8, g.name, def.group) and std.ascii.eqlIgnoreCase(g.language, def.language)) {
                    panel.toggle(self.allocator, gi);
                    opened = true;
                    break;
                }
            }
            if (!opened) return;
        }
    }

    pub fn editorOwnsInput(self: *Editor) bool {
        return self.mode == .normal and self.keyboardOwner() == .editor;
    }

    pub fn cancelSnippets(self: *Editor) void {
        for (self.documents.items) |*doc| doc.cancelSnippet(false);
        self.snippet_owner = null;
    }

    /// Frontends also call this after mouse/visual cursor movement and mode changes.
    pub fn validateSnippetState(self: *Editor) void {
        if (self.snippet_owner) |owner| {
            if (!self.editorOwnsInput() or owner.document != self.activeDoc().id or
                owner.window != self.activeWindow().id or owner.pane != self.activePaneId())
            {
                self.cancelSnippets();
                return;
            }
            self.activeDoc().validateSnippet();
            if (self.activeDoc().snippet_session == null) self.snippet_owner = null;
        }
    }

    fn insertSnippetDefinition(self: *Editor, def: *const snippets_mod.Definition, start: usize, end: usize) void {
        const doc = self.activeDoc();
        doc.insertSnippet(&def.template, start, end, self.useTabsFor(doc), self.indentWidthFor(doc)) catch |err| {
            self.status_message = snippets_mod.errorMessage(err);
            return;
        };
        self.clearCompletionItems();
        self.snippet_owner = if (doc.snippet_session != null)
            .{ .document = doc.id, .window = self.activeWindow().id, .pane = self.activePaneId() }
        else
            null;
    }

    pub fn insertSnippetCommand(self: *Editor, name: []const u8) void {
        if (!self.editorOwnsInput()) return;
        const def = self.snippets.command(name) orelse return;
        const doc = self.activeDoc();
        if (doc.cursors.count() != 1) {
            self.status_message = "Snippets require a single cursor";
            return;
        }
        if (!def.matchesLanguage(if (doc.language) |l| l.name else null)) {
            self.status_message = "Snippet language does not match this document";
            return;
        }
        const cursor = doc.cursors.primaryConst();
        const range = cursor.selectionRange();
        self.insertSnippetDefinition(def, if (range) |r| r.start else cursor.offset, if (range) |r| r.end else cursor.offset);
    }

    /// True means a matching trigger was handled, including a reported allocation failure.
    pub fn expandSnippet(self: *Editor, explicit: bool) bool {
        if (!self.editorOwnsInput()) return false;
        const doc = self.activeDoc();
        if (doc.cursors.count() != 1) {
            if (explicit) self.status_message = "Snippets require a single cursor";
            return false;
        }
        const c = doc.cursors.primaryConst();
        if (c.hasSelection()) {
            if (explicit) self.status_message = "Snippet expansion requires an unselected trigger";
            return false;
        }
        const start = snippets_mod.triggerStart(&doc.buffer, c.offset) orelse {
            if (explicit) self.status_message = "No matching snippet trigger";
            return false;
        };
        // Compare directly against the buffer: no scratch allocation or truncated trigger.
        const language = if (doc.language) |l| l.name else null;
        var global: ?*const snippets_mod.Definition = null;
        var specific: ?*const snippets_mod.Definition = null;
        for (self.snippets.items.items) |*def| {
            if (def.prefix.len != c.offset - start or !def.matchesLanguage(language)) continue;
            var matches = true;
            for (def.prefix, 0..) |byte, i| if (doc.buffer.byteAt(start + i).? != byte) {
                matches = false;
                break;
            };
            if (!matches) continue;
            if (std.mem.eql(u8, def.language, "*")) global = def else specific = def;
        }
        const def = specific orelse global orelse {
            if (explicit) self.status_message = "No matching snippet trigger";
            return false;
        };
        self.insertSnippetDefinition(def, start, c.offset);
        return true;
    }

    pub fn navigateSnippet(self: *Editor, previous: bool) bool {
        self.validateSnippetState();
        if (!self.editorOwnsInput() or !self.activeDoc().navigateSnippet(previous)) return false;
        self.clearCompletionItems();
        self.validateSnippetState();
        return true;
    }

    pub const SnippetKey = enum { tab, shift_tab, escape };

    /// Shared GUI/TUI priority: field, exact trigger, completion, indentation.
    pub fn handleSnippetKey(self: *Editor, key: SnippetKey) bool {
        self.validateSnippetState();
        if (!self.editorOwnsInput()) return false;
        switch (key) {
            .tab => {
                if (self.navigateSnippet(false) or self.expandSnippet(false)) return true;
                if (self.completion_active) self.acceptCompletion() else _ = self.execCommand("indent", null);
                return true;
            },
            .shift_tab => {
                if (!self.navigateSnippet(true)) {
                    self.clearCompletionItems();
                    _ = self.execCommand("dedent", null);
                }
                return true;
            },
            .escape => {
                if (self.activeDoc().snippet_session == null) return false;
                self.activeDoc().cancelSnippet(true);
                self.snippet_owner = null;
                self.clearCompletionItems();
                return true;
            },
        }
    }

    fn isIdentChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '@';
    }
};

/// The shell a POSIX terminal pane runs: `$SHELL` when it names something
/// that can run, else /bin/bash, else /bin/sh — no bash (or a desktop
/// session without SHELL) must not leave a dead pane.
fn posixShell(io: std.Io, env_shell: ?[]const u8) []const u8 {
    if (env_shell) |shell| if (shell.len > 0 and canExecute(io, shell)) return shell;
    if (canExecute(io, "/bin/bash")) return "/bin/bash";
    return "/bin/sh";
}

fn canExecute(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

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
    editor.lsp_enabled = false;
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
    try t.expect(editor.finder_preview_id != null);
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
    try t.expect(editor.finder_preview_id != null);
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
    try t.expect(editor.finder_preview_id == null);
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    editor.finderCommit();
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, "alpha.zig"));
}

test "quick open and workspace search skip .gitignore names" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "vendor");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".gitignore", .data = "vendor/\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "keep.txt", .data = "needle\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "vendor/lib.txt", .data = "needle\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.filetree_root = try t.allocator.dupe(u8, root);

    editor.finderOpen();
    try t.expectEqual(@as(usize, 1), editor.finder_files.items.len);
    try t.expectEqualStrings("keep.txt", editor.finder_files.items[0]);

    text_input.set(&editor.search.query_buf, &editor.search.query_len, "needle");
    editor.search.start(&editor);
    waitSearch(&editor.search);
    try t.expectEqual(@as(usize, 1), editor.search.matches.items.len);
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

test "windows: closing a split pane focuses its sibling, not the far pane" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const win = editor.windows.items[0];

    // [A | [B / C]], C focused: close_pane lands on B (traversal order
    // would wrap to A on the far side).
    editor.splitActive(.horizontal); // A = 0 | B = 1
    editor.splitActive(.vertical); // B = 1 / C = 2
    try t.expectEqual(@as(u8, 2), win.active_pane);
    editor.closePaneAction();
    try t.expectEqual(@as(usize, 2), win.layout.paneCount());
    try t.expectEqual(@as(u8, 1), win.active_pane);

    // Same shape with C a terminal: closing that terminal focuses B too.
    editor.splitActive(.vertical);
    const c = win.active_pane;
    try editor.terminals.append(t.allocator, null); // fake slot: no shell
    win.layout.panes.items[c].content = .{ .terminal = 0 };
    editor.closeTerminal(0);
    try t.expectEqual(@as(usize, 2), win.layout.paneCount());
    try t.expectEqual(@as(u8, 1), win.active_pane);

    // And moving C into its own window leaves B focused behind it.
    editor.multi_window_supported = true;
    editor.splitActive(.vertical);
    editor.movePaneToNewWindow();
    try t.expectEqual(@as(usize, 2), editor.windows.items.len);
    try t.expectEqual(@as(usize, 2), win.layout.paneCount());
    try t.expectEqual(@as(u8, 1), win.active_pane);
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
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, root);

    editor.finderOpen();
    @memcpy(editor.finder_buf[0..4], "beta");
    editor.finder_buf_len = 4;
    editor.finderRefresh();
    const preview_idx = editor.docIndexForId(editor.finder_preview_id.?).?;
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
    editor.setMode(.normal);
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

test "panes: close_pane closes a terminal that is the main window's only pane" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.terminals.append(t.allocator, null); // fake slot: no shell
    const win = editor.windows.items[0];
    win.layout.panes.items[0].content = .{ .terminal = 0 };
    try t.expect(editor.activePaneIsTerminal());
    // The sole pane: the terminal goes and the pane shows the document
    // again, with no "no split panes" lecture.
    try t.expect(editor.execAction("close_pane"));
    try t.expect(!editor.activePaneIsTerminal());
    try t.expectEqual(@as(usize, 1), win.layout.paneCount());
    try t.expect(editor.terminals.items[0] == null);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "No split panes") == null);
    // An editor pane that is the only pane still gets the explanation.
    try t.expect(editor.execAction("close_pane"));
    try t.expect(std.mem.indexOf(u8, editor.status_message, "No split panes") != null);
    // close_terminal from an editor pane says what it needs.
    try t.expect(editor.execAction("close_terminal"));
    try t.expect(std.mem.indexOf(u8, editor.status_message, "terminal") != null);
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
    editor.setMode(.goto_line);
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

test "keyboard focus: panels are exclusive and any pane focus takes it back" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, root);
    editor.filetree_visible = false;
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());

    // One panel at a time; taking one shows it and closes the completion popup.
    try editor.addCompletionItem(try t.allocator.dupe(u8, "foo"), null, null);
    try t.expect(editor.takeKeyboardFocus(.filetree));
    try t.expect(editor.filetree_visible and editor.filetree != null);
    try t.expectEqual(Editor.KeyboardOwner.filetree, editor.keyboardOwner());
    try t.expect(!editor.completion_active and !editor.editorOwnsInput());
    try t.expect(editor.takeKeyboardFocus(.search));
    try t.expect(editor.search_visible and !editor.filetree_focused);
    try t.expectEqual(Editor.KeyboardOwner.search, editor.keyboardOwner());
    try t.expect(editor.takeKeyboardFocus(.filetree));
    try t.expect(!editor.search_focused and editor.search_visible);

    // Every way a pane takes focus takes the keyboard back — clicking the
    // pane that is already active included.
    const PaneFocus = enum { focus_pane, next_pane, prev_pane, split, focus_window, show_doc, take_pane };
    for (std.enums.values(PaneFocus), 0..) |how, i| {
        try t.expect(editor.takeKeyboardFocus(if (i % 2 == 0) .filetree else .search));
        switch (how) {
            .focus_pane => editor.focusPane(editor.activePaneId()),
            .next_pane => editor.focusNextPane(),
            .prev_pane => editor.focusPrevPane(),
            .split => editor.splitActive(.horizontal),
            .focus_window => editor.focusWindow(0),
            .show_doc => editor.showDocIn(0, 0),
            .take_pane => try t.expect(editor.takeKeyboardFocus(.pane)),
        }
        try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
        try t.expect(editor.editorOwnsInput());
    }

    // Structural moves (tab cycling, switching documents) leave it alone.
    _ = try editor.newDocument();
    try t.expect(editor.takeKeyboardFocus(.filetree));
    editor.nextDoc();
    editor.switchToDoc(0);
    try t.expectEqual(Editor.KeyboardOwner.filetree, editor.keyboardOwner());

    // Ctrl+B / Ctrl+Shift+F: focused → hidden (the pane gets the keys),
    // hidden → shown + focused, shown behind another owner → focused.
    editor.toggleFiletree();
    try t.expect(!editor.filetree_visible and !editor.filetree_focused);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    editor.toggleFiletree();
    try t.expectEqual(Editor.KeyboardOwner.filetree, editor.keyboardOwner());
    editor.searchToggle();
    try t.expectEqual(Editor.KeyboardOwner.search, editor.keyboardOwner());
    try t.expect(editor.filetree_visible);
    editor.filetree.?.scroll_to_selected = false;
    editor.toggleFiletree();
    try t.expectEqual(Editor.KeyboardOwner.filetree, editor.keyboardOwner());
    try t.expect(editor.filetree.?.scroll_to_selected);
    editor.searchToggle();
    try t.expectEqual(Editor.KeyboardOwner.search, editor.keyboardOwner());
    editor.searchToggle();
    try t.expect(!editor.search_visible);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
}

test "keyboard focus: a focused panel outranks a terminal pane" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, root);
    // Fake terminal slot — Terminal.init would start a shell.
    try editor.terminals.append(t.allocator, null);
    editor.activeLayout().panes.items[0].content = .{ .terminal = 0 };
    try t.expectEqual(Editor.KeyboardOwner.terminal, editor.keyboardOwner());

    // The tree over a terminal owns the keys; the bound copy chord copies
    // the selected file instead of reaching the shell.
    try t.expect(editor.takeKeyboardFocus(.filetree));
    try t.expectEqual(Editor.KeyboardOwner.filetree, editor.keyboardOwner());
    try t.expect(editor.panelAction("copy"));
    try t.expectEqual(@as(usize, 1), editor.filetree_clip_paths.items.len);
    try t.expectEqualStrings("a.txt", editor.filetree_clip_paths.items[0]);
    try t.expect(!editor.filetree_clip_cut);
    try t.expect(editor.panelAction("cut"));
    try t.expect(editor.filetree_clip_cut);
    try t.expect(editor.panelAction("select_all")); // swallowed
    try t.expect(!editor.panelAction("save")); // not a panel chord
    try t.expect(editor.lookupKeybind("ctrl+c") != null);

    // Clicking the terminal hands it the keyboard; Ctrl+C is the shell's again.
    editor.focusPaneIn(0, editor.activePaneId());
    try t.expectEqual(Editor.KeyboardOwner.terminal, editor.keyboardOwner());
    try t.expect(!editor.panelAction("copy"));

    // Ctrl+` while a panel holds the keyboard over the terminal focuses
    // that terminal instead of opening another one.
    try t.expect(editor.takeKeyboardFocus(.search));
    const panes = editor.activeLayout().paneCount();
    try t.expect(editor.execAction("toggle_terminal"));
    try t.expectEqual(Editor.KeyboardOwner.terminal, editor.keyboardOwner());
    try t.expectEqual(panes, editor.activeLayout().paneCount());

    // F6 and splits release a panel too.
    try t.expect(editor.takeKeyboardFocus(.filetree));
    try t.expect(editor.execAction("focus_next_pane"));
    try t.expectEqual(Editor.KeyboardOwner.terminal, editor.keyboardOwner());
    try t.expect(editor.takeKeyboardFocus(.search));
    editor.splitActive(.horizontal);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expectEqual(panes + 1, editor.activeLayout().paneCount());
}

test "keyboard focus: windows, hidden panels and failed trees never own it" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.multi_window_supported = true;
    editor.filetree_root = try t.allocator.dupe(u8, root);

    // A new window takes the keyboard from a panel of the primary.
    try t.expect(editor.takeKeyboardFocus(.search));
    const w = try editor.newWindow(.{ .editor = 0 });
    try t.expectEqual(w, editor.active_window);
    try t.expect(!editor.search_focused and !editor.filetree_focused);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    // A flag written while a secondary is focused owns nothing (a pure
    // read) and the next tick clears it.
    editor.search_focused = true;
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    editor.normalizeKeyboardFocus();
    try t.expect(!editor.search_focused);
    // Asking for a panel from the secondary focuses the primary first.
    try t.expect(editor.takeKeyboardFocus(.filetree));
    try t.expectEqual(@as(usize, 0), editor.active_window);
    try t.expectEqual(Editor.KeyboardOwner.filetree, editor.keyboardOwner());

    // A panel hidden under its focus (Lua, Settings) keeps none.
    editor.filetree_visible = false;
    editor.normalizeKeyboardFocus();
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    editor.search_visible = false;
    editor.search_focused = true;
    editor.normalizeKeyboardFocus();
    try t.expect(!editor.search_focused);
    // Both set by direct writes: the tree keeps the keyboard, and
    // serviceTick normalizes first thing.
    editor.filetree_visible = true;
    editor.search_visible = true;
    editor.filetree_focused = true;
    editor.search_focused = true;
    try t.expectEqual(Editor.KeyboardOwner.filetree, editor.keyboardOwner());
    editor.serviceTick(0);
    try t.expect(editor.filetree_focused and !editor.search_focused);

    // A failed re-root (tree Backspace into an unreadable parent) keeps the
    // keyboard on the restored tree.
    try t.expect(!editor.setFiletreeRoot("zide-no-such-dir/missing"));
    try t.expect(editor.filetree != null);
    try t.expectEqual(Editor.KeyboardOwner.filetree, editor.keyboardOwner());

    // A tree whose root cannot be opened never takes the keyboard, and a
    // search panel that had it keeps it.
    try t.expect(editor.takeKeyboardFocus(.pane));
    editor.filetree.?.deinit();
    editor.filetree = null;
    t.allocator.free(editor.filetree_root.?);
    editor.filetree_root = try t.allocator.dupe(u8, "zide-no-such-dir/missing");
    try t.expect(!editor.takeKeyboardFocus(.filetree));
    try t.expect(!editor.filetree_visible and !editor.filetree_focused);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    editor.toggleFiletree();
    try t.expect(!editor.filetree_visible and !editor.filetree_focused);
    try t.expect(editor.takeKeyboardFocus(.search));
    try t.expect(!editor.takeKeyboardFocus(.filetree));
    try t.expectEqual(Editor.KeyboardOwner.search, editor.keyboardOwner());
}

const PanelTestClipboard = struct {
    // Nothing reaches the system clipboard; getClipboard reads editor.clipboard.
    fn set(_: []const u8) void {}
    fn get() []const u8 {
        return "";
    }
};

test "panelAction: search field owns clipboard and word-delete chords" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.clipboard_set_fn = PanelTestClipboard.set;
    editor.clipboard_get_fn = PanelTestClipboard.get;
    const doc = editor.activeDoc();
    try doc.loadText("document text");
    const version = doc.buffer.version;

    // While the editor owns the keyboard the chords are the document's.
    try t.expect(!editor.panelAction("paste"));
    try t.expect(editor.takeKeyboardFocus(.search));
    editor.search.field = .query;
    text_input.set(&editor.search.query_buf, &editor.search.query_len, "foo bar");
    editor.search.confirm_armed = true;

    try t.expect(editor.panelAction("delete_word_backward"));
    try t.expectEqualStrings("foo ", editor.search.query());
    try t.expect(!editor.search.confirm_armed);
    try t.expect(editor.panelAction("delete_word_forward")); // caret at the end: nothing
    try t.expect(editor.panelAction("select_all"));
    try t.expectEqualStrings("foo ", editor.search.query());

    // Paste takes the clipboard's first line.
    editor.setClipboard("needle\nx");
    try t.expect(editor.panelAction("paste"));
    try t.expectEqualStrings("foo needle", editor.search.query());
    try t.expect(editor.panelAction("copy"));
    try t.expectEqualStrings("foo needle", editor.clipboard);

    // Word delete stops at a space, never inside a multi-byte character;
    // cut empties the field and disarms a pending Replace.
    editor.search.field = .replace;
    text_input.set(&editor.search.replace_buf, &editor.search.replace_len, "héllo wörld  ");
    try t.expect(editor.panelAction("delete_word_backward"));
    try t.expectEqualStrings("héllo ", editor.search.replacement());
    editor.search.confirm_armed = true;
    try t.expect(editor.panelAction("cut"));
    try t.expectEqualStrings("héllo ", editor.clipboard);
    try t.expectEqualStrings("", editor.search.replacement());
    try t.expect(!editor.search.confirm_armed);

    // The results list has no text: the chords are swallowed.
    editor.search.field = .results;
    try t.expect(editor.panelAction("paste"));
    try t.expectEqualStrings("foo needle", editor.search.query());

    // Other actions, and modal modes, are not the panel's.
    try t.expect(!editor.panelAction("undo"));
    editor.setMode(.find);
    try t.expect(!editor.panelAction("paste"));
    editor.setMode(.normal);

    // The document behind the panel never changed.
    try t.expectEqual(version, doc.buffer.version);
    try t.expectEqualStrings("document text", doc.buffer.slice(0, doc.buffer.byteLen()));
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
    try t.expectEqual(d2.id, editor.confirm_close_doc.?);
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
    editor.confirm_close_doc = std.math.maxInt(u64);
    editor.setMode(.confirm_close);
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
        editor.activeDoc().disk_stamp.?.mtime = -1;
        editor.switchToDoc(0);
        editor.saveAllAndQuit();
        try t.expect(editor.running);
        try t.expectEqual(Editor.Mode.confirm_overwrite, editor.mode);
        try t.expectEqual(@as(?u64, editor.documents.items[1].id), editor.confirm_overwrite_doc);
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
        // Starts inside the surrogate pair.
        \\{"result":[{"label":"foobad","textEdit":{"newText":"bad","range":{"start":{"line":0,"character":1},"end":{"line":0,"character":8}}}}]}
        ,
        // Spans two lines (a completion edit is single-line).
        \\{"result":[{"label":"foobad","textEdit":{"newText":"bad","range":{"start":{"line":0,"character":2},"end":{"line":1,"character":0}}}}]}
        ,
        // Inverted.
        \\{"result":[{"label":"foobad","textEdit":{"newText":"bad","range":{"start":{"line":0,"character":8},"end":{"line":0,"character":2}}}}]}
        ,
    };
    for (invalid) |json| {
        try testLoadCompletion(&editor, json);
        editor.acceptCompletion();
        try t.expectEqualStrings(original, doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expect(!doc.history.canUndo());
    }
    // A character past the line end means the line end (LSP spec).
    try testLoadCompletion(&editor,
        \\{"result":[{"label":"foobad","textEdit":{"newText":"bad","range":{"start":{"line":0,"character":2},"end":{"line":0,"character":90}}}}]}
    );
    editor.acceptCompletion();
    try t.expectEqualStrings("\xf0\x9f\x98\x80bad", doc.buffer.slice(0, doc.buffer.byteLen()));
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
    editor.setMode(.find);
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

/// Test helper: type `text` into the quick-open filter (live preview).
fn finderType(ed: *Editor, text: []const u8) void {
    text_input.set(&ed.finder_buf, &ed.finder_buf_len, text);
    ed.finderRefresh();
}

/// Test helper: invariant P holds — no preview document, no session left,
/// every pane shows a live document.
fn expectNoPeek(ed: *const Editor) !void {
    const t = std.testing;
    try t.expect(ed.finder_preview_id == null);
    try t.expect(ed.finder_prev_doc == null);
    for (ed.documents.items) |*doc| try t.expect(!doc.preview);
    for (ed.windows.items) |win| for (win.layout.panes.items) |pane| switch (pane.content) {
        .editor => |idx| try t.expect(idx < ed.documents.items.len),
        .terminal => {},
    };
}

test "quick open: a command ends the session; later documents are never taken for the preview" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "beta.txt", .data = "beta\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, root);

    editor.finderOpen();
    finderType(&editor, "beta");
    try t.expect(editor.activeDoc().preview);
    // A command (menu, keybind, Lua exec) ends quick-open first.
    try t.expect(editor.execAction("find"));
    try t.expectEqual(Editor.Mode.find, editor.mode);
    try expectNoPeek(&editor);
    editor.setMode(.normal);
    // The next appended document is a real tab, not a stale preview...
    try t.expect(editor.execAction("new_document"));
    const draft_id = editor.activeDoc().id;
    try editor.activeDoc().insertAtCursor("unsaved draft");
    try t.expect(editor.docWindow(editor.docIndexForId(draft_id).?) != null);
    // ...so the next peek cannot load a file into it, and Escape keeps it.
    editor.finderOpen();
    finderType(&editor, "beta");
    try t.expect(editor.activeDoc().preview);
    try t.expect(editor.activeDoc().id != draft_id);
    editor.finderCancel();
    try expectNoPeek(&editor);
    const kept = editor.activeDoc();
    try t.expectEqual(draft_id, kept.id);
    try t.expect(kept.dirty);
    try t.expectEqualStrings("unsaved draft", kept.buffer.slice(0, kept.buffer.byteLen()));
}

test "quick open: every other way out of the finder ends the session and keeps the draft" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "alpha.txt", .data = "alpha\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "beta.txt", .data = "beta\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const beta = try std.fs.path.join(t.allocator, &.{ root, "beta.txt" });
    defer t.allocator.free(beta);
    const Exit = enum { request_close, cancel_encoding, start_encoding, save_untitled, new_document, open_file };
    for (std.enums.values(Exit)) |way_out| {
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        editor.lsp_enabled = false;
        editor.filetree_root = try t.allocator.dupe(u8, root);
        const draft_id = editor.activeDoc().id;
        try editor.activeDoc().insertAtCursor("draft");
        editor.finderOpen();
        finderType(&editor, "alpha");
        try t.expect(editor.activeDoc().preview);
        switch (way_out) {
            .request_close => try t.expect(!editor.requestCloseDoc(editor.docIndexForId(draft_id).?)),
            .cancel_encoding => editor.cancelEncoding(),
            .start_encoding => editor.startEncoding(.choose),
            .save_untitled => try t.expectEqual(Editor.SaveOutcome.needs_path, editor.saveDocument(draft_id, .{})),
            .new_document => _ = try editor.newDocument(),
            .open_file => _ = try editor.openFile(beta),
        }
        try t.expect(editor.mode != .file_finder);
        try expectNoPeek(&editor);
        const idx = editor.docIndexForId(draft_id).?;
        const draft = &editor.documents.items[idx];
        try t.expectEqualStrings("draft", draft.buffer.slice(0, draft.buffer.byteLen()));
        try t.expect(draft.dirty);
        try t.expect(editor.docWindow(idx) != null);
    }
}

test "quick open: cancel returns to the pre-finder document by id" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "peek.txt", .data = "peek\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    {
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        editor.lsp_enabled = false;
        editor.filetree_root = try t.allocator.dupe(u8, root);
        _ = try editor.newDocument(); // B
        _ = try editor.newDocument(); // C
        _ = try editor.newDocument(); // D
        editor.switchToDoc(1);
        const b_id = editor.activeDoc().id;
        editor.finderOpen();
        finderType(&editor, "peek");
        try t.expect(editor.activeDoc().preview);
        // A tab closes while the finder is open: every index shifts.
        try t.expect(editor.closeDocAt(0));
        editor.finderCancel();
        try expectNoPeek(&editor);
        try t.expectEqual(b_id, editor.activeDoc().id);
        try t.expectEqual(@as(usize, 3), editor.documents.items.len);
    }
    {
        // The only document closes during the finder: one untitled remains.
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        editor.lsp_enabled = false;
        editor.filetree_root = try t.allocator.dupe(u8, root);
        editor.finderOpen();
        finderType(&editor, "peek");
        try t.expect(editor.activeDoc().preview);
        _ = editor.closeDocAt(0);
        editor.finderCancel();
        try expectNoPeek(&editor);
        try t.expectEqual(@as(usize, 1), editor.documents.items.len);
        try t.expect(editor.activeDoc().file_path == null);
        try t.expectEqualSlices(usize, &.{0}, editor.windows.items[0].tabs.items);
    }
}

test "quick open: promotion runs the post-open bookkeeping; previews stay bare" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".editorconfig", .data = "root = true\n[*]\nindent_style = space\nindent_size = 3\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "LICENSE", .data = "MIT\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const license = try std.fs.path.join(t.allocator, &.{ root, "LICENSE" });
    defer t.allocator.free(license);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, root);
    // A stored lint finding for LICENSE (an extension ran on it earlier).
    const finding: lsp_mod.Diagnostic = .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 1, .severity = .warning, .message = "license lint" };
    try editor.problems.replace(license, "lint", .lua, null, .bytes, &.{finding});

    editor.finderOpen();
    finderType(&editor, "a.zig");
    try t.expectEqualStrings("zig", editor.activeDoc().language.?.name);
    // The reused preview sheds the previous file: LICENSE is plain text.
    finderType(&editor, "LICENSE");
    const peek = editor.activeDoc();
    try t.expect(peek.preview);
    try t.expect(std.mem.endsWith(u8, peek.file_path.?, "LICENSE"));
    try t.expect(peek.language == null);
    try t.expectEqual(@as(usize, 3), editor.indentWidthFor(peek));
    try t.expectEqual(@as(usize, 0), peek.lint_diagnostics.items.len); // no diagnostics on a peek
    editor.finderCommit();
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try expectNoPeek(&editor);
    const doc = editor.activeDoc();
    try t.expect(std.mem.endsWith(u8, doc.file_path.?, "LICENSE"));
    try t.expect(editor.docWindow(editor.active_doc_idx) != null);
    try t.expectEqual(@as(usize, 3), editor.indentWidthFor(doc));
    try t.expectEqual(@as(usize, 1), doc.lint_diagnostics.items.len); // projected on commit
}

test "windows: a window switch cancels rename previews, stage and task-save prompts at their owners" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.multi_window_supported = true;
    _ = try editor.newWindow(.{ .editor = 0 });
    editor.focusWindow(0);

    // Git: a stage waiting on its save prompt is released, not orphaned
    // (a later stage would fail with GitOperationInProgress forever).
    editor.git.mutation = .{ .path = try t.allocator.dupe(u8, "a.txt"), .old_path = null, .unstage = false };
    editor.setMode(.git_stage_prompt);
    editor.focusWindow(1);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.git.mutation == null);

    // Tasks: the run waiting on its save prompt is cancelled (never spawned).
    editor.focusWindow(0);
    try editor.activeDoc().insertAtCursor("dirty");
    const tasks = @import("tasks.zig");
    try editor.tasks.register(&editor, try tasks.Config.create(t.allocator, .{ .name = "never", .argv = &.{"zide-test-never-spawned"} }));
    const run_id = try editor.tasks.request(&editor, "never");
    try t.expectEqual(Editor.Mode.task_save_prompt, editor.mode);
    try t.expect(editor.tasks.get(run_id).?.job == null);
    editor.focusWindow(1);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.tasks.pending == null);
    try t.expectEqual(tasks.Status.cancelled, editor.tasks.get(run_id).?.status);

    // LSP: a workspace-edit preview is declined (not left blocking renames).
    editor.lsp_tools.preview = .{ .allocator = t.allocator };
    editor.setMode(.workspace_preview);
    editor.focusWindow(0);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.lsp_tools.preview == null);
}

test "auto-save while another document formats never switches tabs or closes quick-open" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.zig", .data = "const b = 2;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "notes\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const a_path = try std.fs.path.join(t.allocator, &.{ root, "a.zig" });
    defer t.allocator.free(a_path);
    const b_path = try std.fs.path.join(t.allocator, &.{ root, "b.zig" });
    defer t.allocator.free(b_path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, root);
    const a = try editor.openFile(a_path);
    const a_id = a.id;
    try a.insertAtCursor("// a\n");
    const a_version = a.buffer.version;
    const b = try editor.openFile(b_path);
    const b_id = b.id;
    try b.insertAtCursor("// b\n");
    // A format-on-save for `a` is in flight (fake server, no process).
    const client = try t.allocator.create(lsp_mod.LspClient);
    client.* = lsp_mod.LspClient.init(t.allocator, t.io);
    editor.lsp_clients.append(t.allocator, client) catch |err| {
        client.deinit();
        t.allocator.destroy(client);
        return err;
    };
    client.config = try lsp_mod.ServerConfig.fromArgv(t.allocator, &.{"zig"}, &.{"test-server"});
    client.capabilities.format_document = true;
    // Documents route to the newest registration's server, and only a
    // document the server has open can format: register it, sync `b`.
    var registration = try client.config.?.clone(t.allocator);
    editor.lsp_configs.append(t.allocator, registration) catch |err| {
        registration.deinit(t.allocator);
        return err;
    };
    editor.documents.items[editor.docIndexForId(b_id).?].lsp_opened = true;
    editor.lsp_tools.format_on_save = true;
    editor.lsp_tools.formatting = .{ .method = .format_document, .doc_id = a_id, .version = a_version, .serial = 1, .generation = client.generation };
    editor.lsp_tools.save = .{ .id = a_id, .options = .{}, .owned_path = null };

    editor.finderOpen();
    finderType(&editor, "notes");
    const peek_id = editor.activeDoc().id;
    try t.expect(editor.activeDoc().preview);
    // `b` cannot format while `a` does: retried next tick, not a failure,
    // and nothing interactive happens behind the user's back.
    try t.expectEqual(@as(usize, 0), editor.autoSaveAll());
    try t.expectEqual(Editor.Mode.file_finder, editor.mode);
    try t.expectEqual(peek_id, editor.activeDoc().id);
    try t.expect(editor.documents.items[editor.docIndexForId(b_id).?].dirty);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "failed") == null);
    editor.finderCancel();
    try expectNoPeek(&editor);
}

/// A registered, handshaken language server with no process behind it:
/// every frame it is sent queues in its detached peer (testSentFrames).
/// Its registration is appended too, so it is the newest for `languages`.
/// Clear `initialized` before teardown — a fake peer never answers the
/// shutdown handshake.
fn testLspServer(editor: *Editor, languages: []const []const u8, argv: []const []const u8) !*lsp_mod.LspClient {
    const protocol = @import("protocol.zig");
    const client = try editor.allocator.create(lsp_mod.LspClient);
    client.* = lsp_mod.LspClient.init(editor.allocator, editor.io);
    editor.lsp_clients.append(editor.allocator, client) catch |err| {
        client.deinit();
        editor.allocator.destroy(client);
        return err;
    };
    client.peer = try protocol.Peer.detached(editor.allocator, editor.io);
    client.config = try lsp_mod.ServerConfig.fromArgv(editor.allocator, languages, argv);
    var registration = try client.config.?.clone(editor.allocator);
    editor.lsp_configs.append(editor.allocator, registration) catch |err| {
        registration.deinit(editor.allocator);
        return err;
    };
    client.initialized = true;
    client.capabilities.format_document = true;
    return client;
}

/// The frames sent to a testLspServer so far, oldest first.
fn testSentFrames(client: *lsp_mod.LspClient) []const []u8 {
    return client.peer.?.outgoing.messages.items;
}

test "LSP: a document too big for one frame is marked per version, not re-sent every sync" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "big.zig", .data = "const a = 1;\n" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "big.zig", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    defer for (editor.lsp_clients.items) |client| {
        client.initialized = false;
    };
    editor.lsp_enabled = false;
    editor.editorconfig_enabled = false;
    const doc = try editor.openFile(path);
    const id = doc.id;
    const server = try testLspServer(&editor, &.{"zig"}, &.{"test-server"});
    editor.lsp_enabled = true;
    editor.lsp_frame_limit = 1024;

    // Too big: marked for this version, nothing sent, the user told once.
    try doc.insertAtCursor("// " ++ "x" ** 1000 ++ "\n");
    editor.syncLspDocuments();
    try t.expect(!doc.lsp_opened);
    try t.expectEqual(@as(?i32, doc.lsp_version), editor.lsp_too_large.get(id));
    try t.expectEqual(@as(usize, 0), testSentFrames(server).len);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "too large") != null);
    // The same version is never measured again — even once it would fit,
    // it waits for an edit instead of being escaped on every sync.
    editor.lsp_frame_limit = @import("protocol.zig").max_frame;
    editor.syncLspDocuments();
    try t.expect(!doc.lsp_opened);
    try t.expectEqual(@as(usize, 0), testSentFrames(server).len);
    // Format-on-save cannot format what the server does not have: the file
    // is saved as it is, and the status bar says why.
    editor.lsp_tools.format_on_save = true;
    try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(id, .{}));
    try t.expect(std.mem.indexOf(u8, editor.status_message, "unformatted (too large") != null);
    try t.expect(!doc.dirty and editor.lsp_tools.save == null);

    // An edit changes the version: measured again, it fits and opens.
    try doc.insertAtCursor(" ");
    editor.syncLspDocuments();
    try t.expect(doc.lsp_opened);
    try t.expect(editor.lsp_too_large.get(id) == null);
    try t.expectEqual(@as(usize, 1), testSentFrames(server).len);
    try t.expect(std.mem.indexOf(u8, testSentFrames(server)[0], "textDocument/didOpen") != null);
    try t.expectEqual(server, editor.lspClientForDoc(doc).?);

    // Growing past the limit while open closes it on the server (no stale
    // copy there) and drops the server's versioned Problems for it.
    const problem: lsp_mod.Diagnostic = .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 1, .severity = .err, .message = "problem" };
    try editor.problems.replace(path, "test-server", .lsp, doc.lsp_version, .utf16, &.{problem});
    editor.lsp_frame_limit = 1024;
    try doc.insertAtCursor("y");
    editor.syncLspDocuments();
    try t.expect(!doc.lsp_opened);
    try t.expectEqual(@as(?i32, doc.lsp_version), editor.lsp_too_large.get(id));
    try t.expectEqual(@as(usize, 2), testSentFrames(server).len);
    try t.expect(std.mem.indexOf(u8, testSentFrames(server)[1], "textDocument/didClose") != null);
    try t.expectEqual(@as(usize, 0), editor.problems.entries.items.len);
    editor.syncLspDocuments();
    try t.expectEqual(@as(usize, 2), testSentFrames(server).len);

    // Closing the document drops its mark.
    try t.expect(editor.closeDocAt(editor.docIndexForId(id).?));
    try t.expect(editor.lsp_too_large.get(id) == null);
}

test "LSP: the newest registration serves a language; a server keeps and forgets only its own documents" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.zig", .data = "const b = 2;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.md", .data = "# notes\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    defer for (editor.lsp_clients.items) |client| {
        client.initialized = false;
    };
    editor.lsp_enabled = false;
    editor.editorconfig_enabled = false;
    var ids: [3]u64 = undefined;
    for ([_][]const u8{ "a.zig", "b.zig", "notes.md" }, &ids) |name, *id| {
        const p = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(p);
        id.* = (try editor.openFile(p)).id;
    }
    const a = &editor.documents.items[editor.docIndexForId(ids[0]).?];
    const b = &editor.documents.items[editor.docIndexForId(ids[1]).?];
    const md = &editor.documents.items[editor.docIndexForId(ids[2]).?];
    editor.lsp_enabled = true;

    // `old` serves zig and markdown; b and the notes open there.
    const old = try testLspServer(&editor, &.{ "zig", "markdown" }, &.{"old-server"});
    editor.lspNotifyOpen(b);
    editor.lspNotifyOpen(md);
    try t.expectEqual(@as(usize, 2), testSentFrames(old).len);
    // A newer zig-only registration takes over zig opens although `old` is
    // running and listed first.
    const new = try testLspServer(&editor, &.{"zig"}, &.{"new-server"});
    try t.expectEqual(new, editor.lspClientForLanguage("zig").?);
    try t.expectEqual(old, editor.lspClientForLanguage("markdown").?);
    editor.syncLspDocuments();
    try t.expect(a.lsp_opened);
    try t.expectEqual(new, editor.lspClientForDoc(a).?);
    try t.expectEqual(@as(usize, 1), testSentFrames(new).len);
    // An open document keeps talking to the server that has it.
    try t.expectEqual(old, editor.lspClientForDoc(b).?);
    try b.insertAtCursor("// edit\n");
    editor.syncLspDocuments();
    try t.expectEqual(@as(usize, 3), testSentFrames(old).len);
    try t.expect(std.mem.indexOf(u8, testSentFrames(old)[2], "textDocument/didChange") != null);
    try t.expectEqual(@as(usize, 1), testSentFrames(new).len);

    // Reload reconcile: `old` still serves markdown and keeps running; its
    // zig document closes there and opens on the newer registration.
    editor.reconcileLspClients();
    try t.expectEqual(@as(usize, 2), editor.lsp_clients.items.len);
    try t.expect(!b.lsp_opened and md.lsp_opened);
    try t.expectEqual(@as(usize, 4), testSentFrames(old).len);
    try t.expect(std.mem.indexOf(u8, testSentFrames(old)[3], "textDocument/didClose") != null);
    editor.syncLspDocuments();
    try t.expect(b.lsp_opened);
    try t.expectEqual(new, editor.lspClientForDoc(b).?);
    try t.expectEqual(@as(usize, 2), testSentFrames(new).len);

    // Stopping `old` forgets only the notes: a and b stay open on `new`,
    // so no duplicate didOpen follows.
    editor.lsp_enabled = false; // nothing may start "old-server" for real
    old.initialized = false;
    editor.stopLspClient(std.mem.indexOfScalar(*lsp_mod.LspClient, editor.lsp_clients.items, old).?);
    try t.expect(!md.lsp_opened and a.lsp_opened and b.lsp_opened);
    try t.expectEqual(new, editor.lspClientForDoc(a).?);
    try t.expectEqual(new, editor.lspClientForDoc(b).?);
    try t.expectEqual(@as(usize, 2), testSentFrames(new).len);
}

test "quick open: the visible range scrolls with the selection and Enter opens what is selected" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    for (0..12) |i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d:0>2}.txt", .{i});
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = name });
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, root);

    editor.finderOpen();
    try t.expectEqual(@as(usize, 12), editor.finder_matches.items.len);
    try t.expectEqual(Editor.FinderRange{ .start = 0, .end = 8 }, editor.finderVisibleRange(8));
    try t.expectEqual(Editor.FinderRange{ .start = 0, .end = 0 }, editor.finderVisibleRange(0));
    for (0..9) |_| editor.finderMove(true);
    try t.expectEqual(@as(usize, 9), editor.finder_selected);
    try t.expectEqual(Editor.FinderRange{ .start = 2, .end = 10 }, editor.finderVisibleRange(8));
    const selected = try t.allocator.dupe(u8, editor.finder_files.items[editor.finder_matches.items[9]]);
    defer t.allocator.free(selected);
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, selected)); // the peek matches
    editor.finderCommit();
    try expectNoPeek(&editor);
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, selected));
}

test "windows: detaching a lone terminal from a secondary keeps exactly one view of it" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    try editor.terminals.append(t.allocator, null); // fake slot: no shell
    editor.windows.items[0].layout.panes.items[0].content = .{ .terminal = 0 };
    try t.expect(editor.execAction("detach_terminal")); // primary → window 1
    try t.expect(editor.execAction("detach_terminal")); // window 1 → window 2
    try t.expectEqual(@as(usize, 3), editor.windows.items.len);
    try t.expect(!editor.windows.items[1].open);
    // Before the reap too: the closing window no longer shows the terminal,
    // so closeWindow cannot stop the one that moved (invariant I6).
    var views: usize = 0;
    for (editor.windows.items) |win| for (win.layout.panes.items) |pane| {
        if (pane.content == .terminal and pane.content.terminal == 0) views += 1;
    };
    try t.expectEqual(@as(usize, 1), views);
    const left_behind = editor.windows.items[1].layout.panes.items[0].content;
    try t.expect(left_behind == .editor and left_behind.editor < editor.documents.items.len);
    editor.retireClosedWindows();
    try t.expectEqual(@as(usize, 2), editor.windows.items.len);
    try t.expectEqual(@as(?usize, 0), editor.activePaneTerminalIdx());
}

test "terminal shell: $SHELL when it can run, else /bin/bash, else /bin/sh" {
    const t = std.testing;
    const fallback = posixShell(t.io, null);
    try t.expect(std.mem.eql(u8, fallback, "/bin/bash") or std.mem.eql(u8, fallback, "/bin/sh"));
    try t.expectEqualStrings(fallback, posixShell(t.io, ""));
    try t.expectEqualStrings(fallback, posixShell(t.io, "/no/such/zide-shell"));
    // (Windows' access() ignores the execute bit; the positive case is POSIX's.)
    if (@import("builtin").os.tag != .windows) try t.expectEqualStrings("/bin/sh", posixShell(t.io, "/bin/sh"));
}

test "EditorConfig save normalization keeps carets on their line and in their own undo step" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".editorconfig", .data =
        \\root = true
        \\[trim.txt]
        \\trim_trailing_whitespace = true
        \\[crlf.txt]
        \\end_of_line = lf
        \\[final.txt]
        \\insert_final_newline = true
        \\[typing.txt]
        \\trim_trailing_whitespace = true
        \\insert_final_newline = true
        \\[merge.txt]
        \\trim_trailing_whitespace = true
        \\
    });
    const Case = struct { name: []const u8, disk: []const u8, caret: usize, saved: []const u8, line: usize, col: usize };
    const cases = [_]Case{
        // Enter on an indented line, then save: the caret stays on the emptied line.
        .{ .name = "trim.txt", .disk = "fn main() {\n    \n}\n", .caret = 16, .saved = "fn main() {\n\n}\n", .line = 1, .col = 0 },
        // CRLF→LF deletes only the \r: an end-of-line caret stays put.
        .{ .name = "crlf.txt", .disk = "abc\r\ndef\r\n", .caret = 3, .saved = "abc\ndef\n", .line = 0, .col = 3 },
        // The final newline goes in after a caret at EOF.
        .{ .name = "final.txt", .disk = "abc", .caret = 3, .saved = "abc\n", .line = 0, .col = 3 },
    };
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    for (cases) |case| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = case.name, .data = case.disk });
        const path = try std.fs.path.join(t.allocator, &.{ root, case.name });
        defer t.allocator.free(path);
        const doc = try editor.openFile(path);
        const id = doc.id;
        doc.cursors.primary().offset = case.caret;
        try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(id, .{}));
        const saved = &editor.documents.items[editor.docIndexForId(id).?];
        try t.expectEqualStrings(case.saved, saved.buffer.slice(0, saved.buffer.byteLen()));
        const pos = saved.buffer.offsetToPos(saved.cursors.primaryConst().offset);
        try t.expectEqual(case.line, pos.line);
        try t.expectEqual(case.col, pos.col);
        const disk = try tmp.dir.readFileAlloc(t.io, case.name, t.allocator, .limited(100));
        defer t.allocator.free(disk);
        try t.expectEqualStrings(case.saved, disk);
        // An explicit end_of_line rule also decides what Enter inserts next.
        if (std.mem.eql(u8, case.name, "crlf.txt")) try t.expect(!saved.crlf);
    }
    {
        // Typing continues on the same line after a (auto-)save mid-word.
        try tmp.dir.writeFile(t.io, .{ .sub_path = "typing.txt", .data = "x" });
        const path = try std.fs.path.join(t.allocator, &.{ root, "typing.txt" });
        defer t.allocator.free(path);
        const doc = try editor.openFile(path);
        const id = doc.id;
        doc.cursors.primary().offset = 1;
        try doc.insertAtCursor("foo ");
        try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(id, .{}));
        const saved = &editor.documents.items[editor.docIndexForId(id).?];
        try saved.insertAtCursor("bar");
        try t.expectEqualStrings("xfoobar\n", saved.buffer.slice(0, saved.buffer.byteLen()));
    }
    {
        // A lone 1-byte trim is its own undo step, not part of the Backspace run.
        try tmp.dir.writeFile(t.io, .{ .sub_path = "merge.txt", .data = "abc" });
        const path = try std.fs.path.join(t.allocator, &.{ root, "merge.txt" });
        defer t.allocator.free(path);
        const doc = try editor.openFile(path);
        const id = doc.id;
        doc.cursors.primary().offset = 3;
        try doc.insertAtCursor("  ");
        try doc.deleteCharacterAll(true);
        try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(id, .{}));
        const saved = &editor.documents.items[editor.docIndexForId(id).?];
        try t.expectEqualStrings("abc", saved.buffer.slice(0, saved.buffer.byteLen()));
        try t.expect(try saved.undoAction());
        try t.expectEqualStrings("abc ", saved.buffer.slice(0, saved.buffer.byteLen()));
        try t.expect(saved.dirty);
    }
}

test "EditorConfig trouble never fails a save" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "cached");
    try tmp.dir.createDirPath(t.io, "broken/.editorconfig"); // unreadable from the start
    try tmp.dir.writeFile(t.io, .{ .sub_path = "cached/.editorconfig", .data = "root = true\n[*]\ntrim_trailing_whitespace = true\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "cached/a.txt", .data = "a\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "broken/b.txt", .data = "b\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const a_path = try std.fs.path.join(t.allocator, &.{ root, "cached", "a.txt" });
    defer t.allocator.free(a_path);
    const b_path = try std.fs.path.join(t.allocator, &.{ root, "broken", "b.txt" });
    defer t.allocator.free(b_path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    // Opening caches cached/.editorconfig; then it becomes a directory, so
    // re-checking the cache fails — that counts as unchanged.
    const a = try editor.openFile(a_path);
    const a_id = a.id;
    try a.insertAtCursor("edit ");
    try tmp.dir.deleteFile(t.io, "cached/.editorconfig");
    try tmp.dir.createDirPath(t.io, "cached/.editorconfig");
    try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(a_id, .{}));
    try t.expect(!editor.documents.items[editor.docIndexForId(a_id).?].dirty);
    // Resolving fails outright: the save goes ahead without the rules.
    const b = try editor.openFile(b_path);
    const b_id = b.id;
    try b.insertAtCursor("edit  ");
    try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(b_id, .{}));
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.startsWith(u8, editor.status_message, "Saved"));
    const disk = try tmp.dir.readFileAlloc(t.io, "broken/b.txt", t.allocator, .limited(100));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("edit  b\n", disk);
}

test "an open document whose path has no identity never blocks opening or saving others" {
    const t = std.testing;
    const builtin = @import("builtin");
    const identity = @import("file_identity.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.txt", .data = "other\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const other = try std.fs.path.join(t.allocator, &.{ root, "other.txt" });
    defer t.allocator.free(other);
    const copy = try std.fs.path.join(t.allocator, &.{ root, "copy.txt" });
    defer t.allocator.free(copy);
    // Windows: a reserved device name (BadPathName); POSIX: an over-long
    // name component (NameTooLong). Stands in for an unreachable share,
    // AccessDenied or a sharing violation.
    const odd = try std.fs.path.join(t.allocator, &.{ root, if (builtin.os.tag == .windows) "nul" else "x" ** 300 });
    defer t.allocator.free(odd);
    if (builtin.os.tag == .windows) {
        const key = identity.key(t.allocator, t.io, odd);
        if (key) |k| t.allocator.free(k) else |_| {}
        try t.expect(std.meta.isError(key)); // the precondition, verified
    }
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try editor.activeDoc().setFilePath(odd); // no disk I/O
    const doc = try editor.openFile(other);
    try t.expect(std.mem.endsWith(u8, doc.file_path.?, "other.txt"));
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    _ = try editor.openOrFocus(other); // finds the open tab again
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    // Save As compares the destination with every open document.
    try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(editor.activeDoc().id, .{ .path = copy }));
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, "copy.txt"));
}

fn caretLine(editor: *Editor) usize {
    const doc = editor.activeDoc();
    return doc.buffer.offsetToPos(doc.cursors.primary().offset).line;
}

test "navigation: back returns to the caret a jump left, forward re-jumps" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const a_id = editor.activeDoc().id;
    try editor.activeDoc().insertAtCursor("one\ntwo\nthree\nfour\n");
    editor.activeDoc().gotoLine(2);
    // A jump records where it left from, then lands elsewhere.
    editor.recordNavPoint();
    const b = try editor.newDocument();
    const b_id = b.id;
    try b.insertAtCursor("x\ny\nz\n");
    b.gotoLine(3);
    try t.expect(editor.execAction("navigate_back"));
    try t.expectEqual(a_id, editor.activeDoc().id);
    try t.expectEqual(@as(usize, 1), caretLine(&editor));
    try t.expect(editor.execAction("navigate_forward"));
    try t.expectEqual(b_id, editor.activeDoc().id);
    try t.expectEqual(@as(usize, 2), caretLine(&editor));
    // Nothing further forward: stays put and says so.
    try t.expect(editor.execAction("navigate_forward"));
    try t.expectEqual(b_id, editor.activeDoc().id);
    try t.expectEqualStrings("Nothing to go forward to", editor.status_message);
}

test "navigation: go to line is a recorded jump; a closed untitled buffer is skipped" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const a_id = editor.activeDoc().id;
    try editor.activeDoc().insertAtCursor("1\n2\n3\n4\n5\n");
    editor.activeDoc().gotoLine(1);
    editor.jumpToLine(5);
    try t.expectEqual(@as(usize, 4), caretLine(&editor));
    try t.expect(editor.execAction("navigate_back"));
    try t.expectEqual(@as(usize, 0), caretLine(&editor));
    // A point in an untitled document that is closed afterwards cannot be
    // reached and is dropped on the way back.
    editor.recordNavPoint();
    _ = try editor.newDocument();
    editor.recordNavPoint();
    _ = try editor.newDocument();
    try t.expect(editor.requestCloseDoc(1));
    try t.expect(editor.execAction("navigate_back"));
    try t.expectEqual(a_id, editor.activeDoc().id);
}

test "reopen closed tab: the last closed file returns at its caret; open files and untitled buffers are skipped" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "a.txt", "b.txt" }) |name| {
        const f = try tmp.dir.createFile(t.io, name, .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "one\ntwo\nthree\n");
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const a_path = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a_path);
    const b_path = try std.fs.path.join(t.allocator, &.{ root, "b.txt" });
    defer t.allocator.free(b_path);

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    const a = try editor.openFile(a_path); // index 1
    a.gotoLine(2);
    _ = try editor.openFile(b_path); // index 2, active
    try t.expect(editor.requestCloseDoc(1)); // a is clean: closed at once
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    // An untitled buffer closed meanwhile is not remembered.
    _ = try editor.newDocument();
    try t.expect(editor.requestCloseDoc(editor.activeDocIdx()));
    try t.expect(editor.execAction("reopen_closed_tab"));
    try t.expect(editor.pathsEqual(editor.activeDoc().file_path.?, a_path));
    try t.expectEqual(@as(usize, 1), caretLine(&editor));
    // b closed, then opened again by hand: its entry is skipped and the
    // list is empty.
    const b_idx = (try editor.findDocument(b_path)).?;
    try t.expect(editor.requestCloseDoc(b_idx));
    _ = try editor.openFile(b_path);
    try t.expect(editor.execAction("reopen_closed_tab"));
    try t.expectEqualStrings("No closed tabs to reopen", editor.status_message);
}

test "projects: open folder re-roots the tree, keeps recents newest-first and persists them" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "alpha/src");
    try tmp.dir.createDirPath(t.io, "beta");
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const alpha = try std.fs.path.join(t.allocator, &.{ root, "alpha" });
    defer t.allocator.free(alpha);
    const beta = try std.fs.path.join(t.allocator, &.{ root, "beta" });
    defer t.allocator.free(beta);
    const lua_settings = @import("lua_settings.zig");
    lua_settings.test_config_dir = root; // recent_projects lands in the temp dir
    defer lua_settings.test_config_dir = null;
    {
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        editor.lsp_enabled = false;
        try t.expect(editor.openProject(alpha));
        try t.expect(std.mem.endsWith(u8, editor.filetree.?.root_path, "alpha"));
        try t.expect(editor.openProject(beta));
        try t.expect(editor.openProject(alpha)); // again: moves to the top, no duplicate
        try t.expectEqual(@as(usize, 2), editor.recent_projects.items.len);
        try t.expect(editor.pathsEqual(editor.recent_projects.items[0], alpha));
        try t.expect(editor.pathsEqual(editor.recent_projects.items[1], beta));
        // The tree's `o` re-roots into the selected folder.
        const ft = editor.ensureFiletree().?;
        const src_node = ft.findByPath("src").?;
        ft.selected = ft.rowOf(src_node).?;
        editor.filetreeOpenSelectedAsRoot();
        try t.expect(std.mem.endsWith(u8, editor.filetree.?.root_path, "src"));
        try t.expectEqual(@as(usize, 3), editor.recent_projects.items.len);
        // A missing folder is refused and the current project stays.
        try t.expect(!editor.openProject("Z:/no/such/folder/zide-test"));
        try t.expect(std.mem.endsWith(u8, editor.filetree.?.root_path, "src"));
    }
    // A fresh editor reads the persisted list back.
    var again = try Editor.init(t.allocator, t.io);
    defer again.deinit();
    again.ensureRecentProjects();
    try t.expectEqual(@as(usize, 3), again.recent_projects.items.len);
    try t.expect(std.mem.endsWith(u8, again.recent_projects.items[0], "src"));
}

test "completion: the typed prefix filters the list and typing keeps the popup open" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.insertAtCursor("fo");
    // Items as a server reply adds them (the editor owns the strings).
    try editor.addCompletionEntry(.{ .label = try t.allocator.dupe(u8, "foo") });
    try editor.addCompletionEntry(.{ .label = try t.allocator.dupe(u8, "Fob") });
    try editor.addCompletionEntry(.{ .label = try t.allocator.dupe(u8, "bar") });
    try t.expect(editor.completion_active);
    try t.expectEqual(@as(usize, 3), editor.completion_all.items.len);
    try t.expectEqual(@as(usize, 2), editor.completion_items.items.len);
    try t.expect(editor.completionKeepsOnByte('x'));
    try t.expect(editor.completionKeepsOnByte('_'));
    try t.expect(!editor.completionKeepsOnByte(' '));
    // Another identifier character narrows the list and keeps the popup
    // (no server here, so the refresh request is simply skipped).
    try t.expect(editor.execCommand("insert_char", "o"));
    try t.expect(editor.completion_active);
    try t.expectEqual(@as(usize, 1), editor.completion_items.items.len);
    try t.expectEqualStrings("foo", editor.completion_items.items[0].label);
    try t.expect(!editor.completion_stale);
    // A space dismisses it.
    try t.expect(editor.execCommand("insert_char", " "));
    try t.expect(!editor.completion_active);
    try t.expectEqual(@as(usize, 0), editor.completion_all.items.len);
}

test "command palette: matching ignores case, a space reads as an underscore, Tab completes the highlighted name" {
    const t = std.testing;
    try t.expect(Editor.paletteMatch("review_set_baseline", "Set Baseline"));
    try t.expect(Editor.paletteMatch("review_set_baseline", "rsb"));
    try t.expect(Editor.paletteMatch("review_set_baseline", "set-baseline"));
    try t.expect(!Editor.paletteMatch("review_set_baseline", "baseline set"));
    try t.expect(Editor.paletteMatch("anything", ""));
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try t.expect(editor.execAction("command_palette"));
    const typed = "set baseline";
    @memcpy(editor.palette_buf[0..typed.len], typed);
    editor.palette_buf_len = typed.len;
    try t.expectEqualStrings("review_set_baseline", editor.paletteSelectedName().?);
    editor.paletteComplete();
    try t.expectEqualStrings("review_set_baseline", editor.palette_buf[0..editor.palette_buf_len]);
    try t.expectEqualStrings("review_set_baseline", editor.paletteSelectedName().?);
    // A selection past the last match means the last match.
    editor.palette_selected = 999;
    try t.expectEqualStrings("review_set_baseline", editor.paletteSelectedName().?);
    // Nothing typed: the first command, alphabetically.
    editor.palette_buf_len = 0;
    editor.palette_selected = 0;
    const names = try editor.commands.allNames();
    try t.expectEqualStrings(names[0], editor.paletteSelectedName().?);
    // Nothing matches: nothing to run or complete.
    const junk = "zzzzqqqq";
    @memcpy(editor.palette_buf[0..junk.len], junk);
    editor.palette_buf_len = junk.len;
    try t.expect(editor.paletteSelectedName() == null);
    editor.paletteComplete();
    try t.expectEqualStrings(junk, editor.palette_buf[0..editor.palette_buf_len]);
}
