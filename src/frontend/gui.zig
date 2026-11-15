//! The GUI frontend: one DVUI frame function on SDL3 that paints the editor's
//! state and turns events into commands. It draws the menus, the tabs, the
//! panes and their text (by hand: gutter, syntax colors, selections, carets),
//! the file tree, the Snippets, search and terminal panels, the find bar, the
//! tool views, the Settings dialog and the extra OS windows. Its tests run
//! under `zig build test-gui`, in hidden windows.
const std = @import("std");
const text_input = @import("../core/text_input.zig");
const build_options = @import("build_options");
const dvui = if (build_options.has_gui) @import("dvui") else struct {};
const Editor = @import("../core/editor.zig").Editor;
const Document = @import("../core/document.zig").Document;
const Buffer = @import("../core/buffer.zig").Buffer;
const LayoutNode = @import("../core/layout.zig").LayoutNode;
const Layout = @import("../core/layout.zig").Layout;
const ThemeColor = @import("../core/theme.zig").ThemeColor;
const theme_mod = @import("../core/theme.zig");
const status_mod = @import("../core/status_message.zig");
const syntax = @import("../core/syntax.zig");
const search_mod = @import("../core/search.zig");
const brackets = @import("../core/brackets.zig");
const review_reader = @import("../core/review_reader.zig");
const review = @import("../core/review.zig");
const lsp = @import("../core/lsp.zig");
const terminal_mod = @import("../core/terminal.zig");
const filetree_mod = @import("../core/filetree.zig");
const FileTree = filetree_mod.FileTree;
const fileicons = @import("../core/fileicons.zig");
const snippet_panel = @import("../core/snippet_panel.zig");
const snippets_mod = @import("../core/snippets.zig");
const snippet_form_mod = @import("../core/snippet_form.zig");
const snippet_file = @import("../core/snippet_file.zig");
const find_bar_mod = @import("../core/find_bar.zig");
const icons = @import("icons.zig");
const cursor_mod = @import("../core/cursor.zig");
const keybind = @import("../core/keybind.zig");
const lua_settings = @import("../core/lua_settings.zig");
const lua_api = @import("../core/lua_api.zig");
const jobs = @import("../core/jobs.zig");

/// Convert a ThemeColor to a dvui.Color.
fn toDvui(c: ThemeColor) dvui.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// Get the color for a diagnostic severity.
fn diagnosticColor(severity: lsp.DiagnosticSeverity) dvui.Color {
    return switch (severity) {
        .err => .{ .r = 0xE0, .g = 0x40, .b = 0x40, .a = 0xFF },
        .warning => .{ .r = 0xE0, .g = 0xC0, .b = 0x40, .a = 0xFF },
        .information => .{ .r = 0x40, .g = 0xA0, .b = 0xE0, .a = 0xFF },
        .hint => .{ .r = 0x80, .g = 0x80, .b = 0xA0, .a = 0xFF },
    };
}

/// Get the worst severity diagnostic on a given line (lowest enum = worst).
fn worstDiagnosticOnLine(doc: *Document, line: usize) ?*const lsp.Diagnostic {
    var worst: ?*const lsp.Diagnostic = null;
    var diag_it = doc.diagIter();
    while (diag_it.next()) |d| {
        if (d.start_line <= line and d.end_line >= line) {
            if (worst) |w| {
                if (@intFromEnum(d.severity) < @intFromEnum(w.severity)) {
                    worst = d;
                }
            } else {
                worst = d;
            }
        }
    }
    return worst;
}

// ---------------------------------------------------------------------------
// Custom DVUI themes — control the app chrome (menus, tabs, scrollbars, etc.)
// These use the same Vera Sans fonts as DVUI's built-in Adwaita themes.
// ---------------------------------------------------------------------------

/// Name under which the bundled (or user-overridden) mono font is registered with DVUI.
pub const custom_mono_family = "zide-mono";

/// Bundled default mono font (Fira Code Nerd Font Mono — covers box-drawing,
/// powerline glyphs, devicons, etc.). Used unless the user sets `mono_font_path`.
pub const bundled_mono_ttf = @embedFile("bundled_mono_font");

/// Return the DVUI theme matching the current editor theme preset.
/// If `use_custom_mono` is true, the mono font is switched to `custom_mono_family`
/// (which must be registered beforehand via `dvui.Window.addFont`).
/// If `mono_size` > 0, it overrides the default mono size.
pub fn dvuiThemeForPreset(preset_name: []const u8, use_custom_mono: bool, mono_size: f32) dvui.Theme {
    var theme: dvui.Theme = if (std.mem.eql(u8, preset_name, "light"))
        dvui_light
    else if (std.mem.eql(u8, preset_name, "high_contrast"))
        dvui_high_contrast
    else
        dvui_dark;

    const family: []const u8 = if (use_custom_mono) custom_mono_family else "Vera Sans Mono";
    const size: f32 = if (mono_size > 0) mono_size else dvui.Font.DefaultSize;
    theme.font_mono = .find(.{ .family = family, .size = size });
    return theme;
}

const dvui_dark: dvui.Theme = blk: {
    @setEvalBranchQuota(3200);
    break :blk .{
        .name = "ZIDE Dark",
        .dark = true,

        .font_body = .find(.{ .family = "Vera Sans" }),
        .font_heading = .find(.{ .family = "Vera Sans", .weight = .bold }),
        .font_title = .find(.{ .family = "Vera Sans", .size = dvui.Font.DefaultSize + 2 }),
        .font_mono = .find(.{ .family = "Vera Sans Mono" }),

        .focus = .{ .r = 0x35, .g = 0x84, .b = 0xe4 }, // accent blue
        .fill = .{ .r = 0x1e, .g = 0x1e, .b = 0x24 },
        .text = .{ .r = 0xe1, .g = 0xe1, .b = 0xe6 },
        .text_select = .{ .r = 0x32, .g = 0x60, .b = 0x98 },
        .border = .{ .r = 0x50, .g = 0x50, .b = 0x5a },

        .control = .{
            .fill = .{ .r = 0x3a, .g = 0x3a, .b = 0x44 },
            .fill_hover = .{ .r = 0x48, .g = 0x48, .b = 0x54 },
            .fill_press = .{ .r = 0x56, .g = 0x56, .b = 0x64 },
            .border = .{ .r = 0x60, .g = 0x60, .b = 0x6a },
        },

        .window = .{
            .fill = .{ .r = 0x28, .g = 0x28, .b = 0x30 },
            .border = .{ .r = 0x50, .g = 0x50, .b = 0x5a },
        },

        .highlight = .{
            .fill = .{ .r = 0x35, .g = 0x84, .b = 0xe4 },
            .fill_hover = .{ .r = 0x40, .g = 0x90, .b = 0xf0 },
            .fill_press = .{ .r = 0x2a, .g = 0x74, .b = 0xd4 },
            .text = dvui.Color.white,
        },

        .err = .{
            .fill = .{ .r = 0xc0, .g = 0x1c, .b = 0x28 },
            .text = dvui.Color.white,
            .border = .{ .r = 0xe0, .g = 0x40, .b = 0x40 },
        },
    };
};

const dvui_light: dvui.Theme = blk: {
    @setEvalBranchQuota(3200);
    break :blk .{
        .name = "ZIDE Light",
        .dark = false,

        .font_body = .find(.{ .family = "Vera Sans" }),
        .font_heading = .find(.{ .family = "Vera Sans", .weight = .bold }),
        .font_title = .find(.{ .family = "Vera Sans", .size = dvui.Font.DefaultSize + 2 }),
        .font_mono = .find(.{ .family = "Vera Sans Mono" }),

        .focus = .{ .r = 0x35, .g = 0x84, .b = 0xe4 },
        .fill = dvui.Color.white,
        .fill_hover = .{ .r = 0xd2, .g = 0xd2, .b = 0xd2 },
        .fill_press = .{ .r = 0xb8, .g = 0xb8, .b = 0xb8 },
        .text = .{ .r = 0x1e, .g = 0x1e, .b = 0x1e },
        .text_select = .{ .r = 0x91, .g = 0xbc, .b = 0xf0 },
        .border = .{ .r = 0xa0, .g = 0xa0, .b = 0xa0 },

        .control = .{
            .fill = .{ .r = 0xe0, .g = 0xe0, .b = 0xe0 },
            .fill_hover = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 },
            .fill_press = .{ .r = 0xc0, .g = 0xc0, .b = 0xc0 },
            .border = .{ .r = 0xa0, .g = 0xa0, .b = 0xa0 },
        },

        .window = .{
            .fill = .{ .r = 0xf0, .g = 0xf0, .b = 0xf0 },
            .border = .{ .r = 0xb0, .g = 0xb0, .b = 0xb0 },
        },

        .highlight = .{
            .fill = .{ .r = 0x35, .g = 0x84, .b = 0xe4 },
            .fill_hover = .{ .r = 0x40, .g = 0x90, .b = 0xf0 },
            .fill_press = .{ .r = 0x2a, .g = 0x74, .b = 0xd4 },
            .text = dvui.Color.white,
            .border = .{ .r = 0x2a, .g = 0x6a, .b = 0xc0 },
        },

        .err = .{
            .fill = .{ .r = 0xe0, .g = 0x1b, .b = 0x24 },
            .text = dvui.Color.white,
            .border = .{ .r = 0xc0, .g = 0x10, .b = 0x18 },
        },
    };
};

const dvui_high_contrast: dvui.Theme = blk: {
    @setEvalBranchQuota(3200);
    break :blk .{
        .name = "ZIDE High Contrast",
        .dark = true,

        .font_body = .find(.{ .family = "Vera Sans" }),
        .font_heading = .find(.{ .family = "Vera Sans", .weight = .bold }),
        .font_title = .find(.{ .family = "Vera Sans", .size = dvui.Font.DefaultSize + 2 }),
        .font_mono = .find(.{ .family = "Vera Sans Mono" }),

        .focus = .{ .r = 0xff, .g = 0xff, .b = 0x00 }, // yellow
        .fill = dvui.Color.black,
        .text = dvui.Color.white,
        .text_select = .{ .r = 0x00, .g = 0x5a, .b = 0xc8 },
        .border = .{ .r = 0x80, .g = 0x80, .b = 0x80 },

        .control = .{
            .fill = .{ .r = 0x28, .g = 0x28, .b = 0x28 },
            .fill_hover = .{ .r = 0x40, .g = 0x40, .b = 0x40 },
            .fill_press = .{ .r = 0x58, .g = 0x58, .b = 0x58 },
            .border = .{ .r = 0xc0, .g = 0xc0, .b = 0xc0 },
        },

        .window = .{
            .fill = .{ .r = 0x0a, .g = 0x0a, .b = 0x0a },
            .border = .{ .r = 0xc0, .g = 0xc0, .b = 0xc0 },
        },

        .highlight = .{
            .fill = .{ .r = 0x00, .g = 0x5a, .b = 0xc8 },
            .fill_hover = .{ .r = 0x00, .g = 0x70, .b = 0xe0 },
            .fill_press = .{ .r = 0x00, .g = 0x50, .b = 0xb0 },
            .text = dvui.Color.white,
            .border = .{ .r = 0xff, .g = 0xff, .b = 0x00 },
        },

        .err = .{
            .fill = .{ .r = 0xff, .g = 0x00, .b = 0x00 },
            .text = dvui.Color.white,
            .border = .{ .r = 0xff, .g = 0x80, .b = 0x80 },
        },
    };
};

/// Editor-pane scrollbar band: the mouse hit zone along the pane's right
/// edge (the pill thumb drags, clicks in the band page toward the click).
const editor_sb_band: f32 = 12;
/// Selection mode for drag after multi-click (extends by word/line) or
/// Shift+Alt+drag (block/column selection).
const DragMode = enum { char, word, line, block };
const blink_interval_ms: i128 = 530;

/// OS drag & drop staging slot (see onSdlDropFile). Fixed slots — a drop
/// of more than 16 items imports the first 16.
const DropSlot = struct { path: [1024]u8 = undefined, len: usize = 0, x: f32 = 0, y: f32 = 0 };

/// Tab drag-out: a left press on a tab label arms it, motion past the
/// threshold drags, a release outside the tab bar opens the document in a
/// new window (or in the ZIDE window under the pointer).
const TabDrag = struct {
    state: enum { idle, armed, dragging } = .idle,
    doc_idx: usize = 0,
    /// documents.len when the drag armed — a close/open in between shifts
    /// the indices, so the drag is cancelled then.
    doc_count: usize = 0,
    press_pt: dvui.Point.Physical = .{},
    /// The bar's rect this frame — a release inside it is a cancel.
    bar_rect: dvui.Rect.Physical = .{},
};

/// Per-OS-window GUI state. One instance per `Editor.EditorWindow`, keyed
/// by its id; the pane/mouse/key code reaches the window being rendered
/// through `win_ui` (set by frame() before each window's widgets — the same
/// "current window" pattern dvui itself uses). Everything that is per
/// panel (file tree, search) or per process (timers, memos) stays a
/// file-level var: those panels only ever render in the primary window.
pub const WinUi = struct {
    /// `EditorWindow.id` this state belongs to (primary = 0).
    win_id: u32,
    /// SDL window id (SDL_GetWindowID) — routes OS file drops to the
    /// window they landed on. Primary set in main.zig, children on their
    /// creation frame.
    sdl_window_id: u32 = 0,
    /// Child dvui window exists and has fonts + theme applied.
    created: bool = false,
    /// `Editor.theme_revision` this window last applied.
    theme_gen_applied: u32 = 0,
    /// Hash of the last window title pushed to SDL.
    title_hash: u64 = 0,
    /// One-frame flag: the active pane retakes dvui focus (after a tab click).
    refocus_editor: bool = false,

    // --- Editor-pane mouse interaction ---
    /// Persistent state across frames for mouse drag tracking.
    drag_active: bool = false,
    drag_anchor_offset: usize = 0,
    /// Pane that owns the active drag. Every editor pane iterates the
    /// window's event list; without ownership the first-rendered pane
    /// consumed drags that started in another pane and moved the wrong
    /// document's cursor.
    drag_pane: u8 = 0,
    /// Cached editor area for stable mouse mapping during drag. Without
    /// this, subpixel layout shifts cause the mouse-to-offset mapping to
    /// oscillate, producing visible gyration.
    drag_area: dvui.Rect.Physical = .{},
    /// When true, the user explicitly scrolled (wheel) so
    /// ensureCursorVisible is skipped. Cleared when the cursor moves.
    scroll_pinned: bool = false,
    /// A chord on Space ran this frame (Ctrl+Space = completion): Windows
    /// also delivers a plain " " text event for it, which must not type.
    swallow_space: bool = false,
    /// Editor-pane scrollbar state (mirrors the file tree's pill scrollbar).
    editor_sb_drag: bool = false,
    editor_sb_pane: u8 = 0,
    editor_sb_grab_dy: f32 = 0,
    editor_sb_hover_pane: ?u8 = null,
    /// The tool dialog's table: its scroll state, which view it was built
    /// for (a new view starts at the top) and the row it last followed.
    tool_grid_si: dvui.ScrollInfo = .{},
    tool_grid_kind: ?@import("../core/tool_panel.zig").Kind = null,
    tool_grid_followed: ?usize = null,
    /// Multi-click detection (double-click = word, triple-click = line).
    last_click_time_ns: i128 = 0,
    last_click_offset: usize = 0,
    click_count: u8 = 1,
    drag_mode: DragMode = .char,
    /// Word/line boundaries anchored by double/triple-click for drag extension.
    drag_word_start: usize = 0,
    drag_word_end: usize = 0,
    /// Anchor (line, col) for block-selection drags.
    block_anchor_line: usize = 0,
    block_anchor_col: usize = 0,
    /// Cursor blink state.
    blink_time_ns: i128 = 0,
    blink_last_offset: usize = 0,

    // --- OS file drops staged by the SDL backend between frames ---
    drop_slots: [16]DropSlot = @splat(.{}),
    drop_count: usize = 0,

    /// Tab drag-out state (see TabDrag).
    tab_drag: TabDrag = .{},
};

/// Process-wide GUI state: one WinUi per editor window plus the mono font
/// bytes every dvui window registers (each dvui.Window owns its own font
/// database, so child windows re-register the same bytes).
pub const GuiState = struct {
    allocator: std.mem.Allocator,
    /// Heap entries → pointers stay stable while the list grows.
    wins: std.ArrayList(*WinUi) = .empty,
    mono_font_bytes: []const u8 = bundled_mono_ttf,
    /// True when mono_font_bytes was read from the user's font file (owned).
    mono_font_owned: bool = false,

    pub fn init(allocator: std.mem.Allocator) !GuiState {
        var g = GuiState{ .allocator = allocator };
        errdefer g.deinit();
        _ = try g.winUi(0);
        return g;
    }

    /// Call after every dvui.Window using the font bytes is gone.
    pub fn deinit(self: *GuiState) void {
        for (self.wins.items) |w| self.allocator.destroy(w);
        self.wins.deinit(self.allocator);
        if (self.mono_font_owned) self.allocator.free(self.mono_font_bytes);
    }

    pub fn primary(self: *GuiState) *WinUi {
        return self.wins.items[0];
    }

    pub fn find(self: *GuiState, win_id: u32) ?*WinUi {
        for (self.wins.items) |w| {
            if (w.win_id == win_id) return w;
        }
        return null;
    }

    /// Find-or-create the state for editor window `win_id`.
    pub fn winUi(self: *GuiState, win_id: u32) !*WinUi {
        if (self.find(win_id)) |w| return w;
        const w = try self.allocator.create(WinUi);
        w.* = .{ .win_id = win_id };
        try self.wins.append(self.allocator, w);
        return w;
    }

    pub fn bySdlWindow(self: *GuiState, sdl_id: u32) ?*WinUi {
        for (self.wins.items) |w| {
            if (w.sdl_window_id == sdl_id) return w;
        }
        return null;
    }

    /// Drop state for windows the core no longer has (never the primary).
    pub fn retireMissing(self: *GuiState, editor: *Editor) void {
        var i: usize = self.wins.items.len;
        while (i > 1) {
            i -= 1;
            const w = self.wins.items[i];
            var alive = false;
            for (editor.windows.items) |ew| {
                if (ew.id == w.win_id) {
                    alive = true;
                    break;
                }
            }
            if (!alive) {
                _ = self.wins.orderedRemove(i);
                self.allocator.destroy(w);
            }
        }
    }
};

/// For the context-less SDL drop callback (set by main.zig for the GUI's lifetime).
pub var active_state: ?*GuiState = null;

/// The window whose section frame() is currently rendering — set before
/// any of its widgets run, like dvui.current_window. `cur_win` is its index
/// in `editor.windows`.
var win_ui: *WinUi = undefined;
var cur_win: usize = 0;

/// Layout tree of editor window `win_idx`.
fn winLayout(editor: *Editor, win_idx: usize) *Layout {
    return &editor.windows.items[win_idx].layout;
}

/// Read the user's mono font file (if configured) into `g`; the bundled
/// Fira Code Nerd Font stays the fallback. Runs once at GUI startup.
pub fn loadMonoFont(g: *GuiState, editor: *Editor, io: std.Io) void {
    if (editor.mono_font_path.len == 0) return;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, editor.mono_font_path, g.allocator, .limited(64 * 1024 * 1024)) catch |err| {
        std.log.warn("Failed to read mono font {s}: {} — falling back to bundled font", .{ editor.mono_font_path, err });
        return;
    };
    g.mono_font_bytes = bytes;
    g.mono_font_owned = true;
}

/// Register the mono font under `custom_mono_family` in the PRIMARY
/// window's font database and (re)apply the editor theme so font_mono
/// resolves to it. Runs once at startup, before any child window exists:
/// when the user's font can't be registered, every window falls back to
/// the bundled font (the user's bytes are freed while nothing holds them).
pub fn applyWindowFonts(win: *dvui.Window, g: *GuiState, editor: *Editor) void {
    registerMonoFont(win, g, true);
    win.theme = dvuiThemeForPreset(editor.theme_name, true, editor.mono_font_size);
}

/// applyWindowFonts for a child window: a registration failure falls back
/// to the bundled font in that window only — the primary and the other
/// children still draw with the user's bytes, so they are never freed here.
fn applyChildWindowFonts(win: *dvui.Window, g: *GuiState, editor: *Editor) void {
    registerMonoFont(win, g, false);
    win.theme = dvuiThemeForPreset(editor.theme_name, true, editor.mono_font_size);
}

/// The bytes stay owned by GuiState (shared by every window) — a null
/// allocator tells dvui not to free them. `global_fallback` (primary only)
/// switches GuiState to the bundled font when the user's font fails.
fn registerMonoFont(win: *dvui.Window, g: *GuiState, global_fallback: bool) void {
    win.addFont(custom_mono_family, g.mono_font_bytes, null) catch |err| {
        std.log.warn("Failed to register mono font: {} — falling back to bundled font", .{err});
        if (!g.mono_font_owned) return; // the bundled font itself failed
        if (global_fallback) {
            g.allocator.free(g.mono_font_bytes);
            g.mono_font_bytes = bundled_mono_ttf;
            g.mono_font_owned = false;
        }
        win.addFont(custom_mono_family, bundled_mono_ttf, null) catch |err2| {
            std.log.warn("Failed to register bundled mono font: {}", .{err2});
        };
    };
}

/// Render a single frame of the GUI. Returns false to quit.
///
/// Per-process work (polls, auto-save, file-tree focus handback) runs once;
/// everything window-scoped goes through the section helpers below with
/// `win_ui`/`cur_win` pointing at the window being drawn.
pub fn frame(editor: *Editor, g: *GuiState) bool {
    if (!build_options.has_gui) return false;
    editor.validateSnippetState();
    defer editor.validateSnippetState();

    // Windows whose close was requested (OS close button via the open flag,
    // close_window, the last pane closing) go away before anything is drawn;
    // dvui destroys their child windows in the primary end().
    editor.retireClosedWindows();
    g.retireMissing(editor);

    // The focused editor window follows OS keyboard focus — a title-bar
    // click produces no dvui event, so this is polled once per frame.
    syncActiveWindowFromOs(editor, g);

    // Primary window section.
    win_ui = g.primary();
    cur_win = 0;
    applyThemeIfStale(editor);

    // --- Global keyboard shortcuts (before widgets consume events) ---
    dispatchGlobalKeys(editor);

    // Check if quit was requested via keybind/command
    if (!editor.running) return false;

    // Side band edge-drag resize (uses last frame's band rects). A drag
    // well past a band's minimum hides it (Ctrl+B / Ctrl+Alt+B bring it
    // back at its old width); the status bar says so before the release.
    if (editor.filetree_visible and editor.filetree != null) {
        if (handleBandResize(&filetree_band, editor.filetree_side, &editor.filetree_width, 120, 600, "filetree_width")) {
            editor.filetree_visible = false;
            editor.filetree_focused = false;
            editor.status_message = "File tree hidden — Ctrl+B shows it again";
        } else if (filetree_band.resizing) {
            bandDragHint(editor, filetree_band.hide_pending, "Release to hide the file tree");
        }
    } else {
        filetree_band.reset();
    }
    if (editor.snippets_visible) {
        if (handleBandResize(&snippets_band, editor.snippetsSide(), &editor.snippets_width, 120, 600, "snippets_width")) {
            editor.snippets_visible = false;
            editor.snippets_focused = false;
            editor.status_message = "Snippets panel hidden — Ctrl+Alt+B shows it again";
        } else if (snippets_band.resizing) {
            bandDragHint(editor, snippets_band.hide_pending, "Release to hide the Snippets panel");
        }
    } else {
        snippetsBandGone();
    }
    if (editor.terminal_panel_visible and editor.terminal_panel != null) {
        const lim = Editor.terminal_panel_limits;
        const edge = editor.terminal_panel_side;
        const hid = if (edge == .bottom)
            handleBandResizeAt(&terminal_panel_band, .bottom, &editor.terminal_panel_height, lim.min_height, lim.max_height, "terminal_panel_height")
        else
            handleBandResizeAt(&terminal_panel_band, edge, &editor.terminal_panel_width, lim.min_width, lim.max_width, "terminal_panel_width");
        if (hid) {
            editor.hideTerminalPanel();
            editor.status_message = "Terminal panel hidden — Ctrl+Shift+` shows it again";
        } else if (terminal_panel_band.resizing) {
            bandDragHint(editor, terminal_panel_band.hide_pending, "Release to hide the terminal panel");
        }
    } else {
        terminal_panel_band.reset();
    }

    // OS file drops staged by the SDL backend between frames.
    processFileDrops(editor);

    // Pick up files created/removed outside ZIDE: cheap dir-mtime probe
    // every ~1.5s; the full rescan + git refresh runs only when it fires.
    // Paused while a drag-move is in flight (row indices must stay stable).
    if (editor.filetree_visible and !filetree_dnd_armed and !filetree_dnd_active) {
        if (editor.filetree) |*ft| {
            const poll_now: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
            if (poll_now - filetree_poll_ns > 1500 * std.time.ns_per_ms) {
                filetree_poll_ns = poll_now;
                if (ft.checkExternalChanges()) {
                    ft.refresh() catch {};
                    ft.gitRefresh();
                }
            }
        }
    }

    // Pull in workspace-search results from the background worker
    _ = editor.search.drain();

    editor.serviceTick(std.Io.Clock.now(.awake, editor.io).nanoseconds);

    // After the keybinds and serviceTick's focus repair, before any pane.
    trackKeyboardOwner(editor);

    // Set again by whichever window draws the find bar this frame.
    find_bar_geom = null;

    menuBar(editor);
    modalDialogs(editor);
    tabBar(editor);
    statusBar(editor);
    editorArea(editor, true);

    // --- Primary window close / app quit → the quit flow (unsaved prompt) ---
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        const wants_quit = (e.evt == .window and e.evt.window.action == .close) or
            (e.evt == .app and e.evt.app.action == .quit);
        if (wants_quit) {
            e.handled = true;
            // The prompt shows in the primary window; a side panel there
            // keeps the keyboard if it had it.
            if (editor.active_window != 0) editor.focusWindow(0);
            _ = editor.execAction("quit");
            dvui.refresh(null, @src(), null);
        }
    }

    // --- Secondary windows ---
    childWindows(editor, g);

    // Work raised from inside a pane (the palette, terminal key
    // passthrough) runs only now: the split widgets hold pointers into the
    // layout tree while the panes render.
    runDeferred(editor);

    // A window to reap or create, or a theme to apply, needs another frame
    // even without input.
    if (needsAnotherFrame(editor, g)) dvui.refresh(null, @src(), null);

    return editor.running;
}

/// Keybind chords for the current window, dispatched from the raw event
/// list before any dvui widget (menus, panels) can consume them.
fn dispatchGlobalKeys(editor: *Editor) void {
    // Input in this window makes it the active one. SDL's keyboard focus
    // (syncActiveWindowFromOs) can lag a frame behind a click on an inactive
    // window — that click would otherwise act on the previously active
    // window (a file double-clicked in the tree opened in the other window).
    if (cur_win != editor.active_window) {
        for (dvui.events()) |*e| {
            const is_input = switch (e.evt) {
                .mouse => |me| me.action == .press or me.action == .focus,
                .key => |key| key.action == .down or key.action == .repeat,
                .text => |te| te.action == .value and te.action.value.txt.len > 0,
                else => false,
            };
            if (is_input) {
                editor.focusWindow(cur_win);
                break;
            }
        }
    }

    // --- Global keyboard shortcuts (before widgets consume events) ---
    // Process keybinds here so DVUI widgets (menus, etc.) cannot consume them first.
    win_ui.swallow_space = false;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .key) continue;
        const key = e.evt.key;
        if (key.action != .down and key.action != .repeat) continue;

        // F-keys are never text input, so they go through the keybind map
        // even unmodified (f12 = goto definition, f6 = focus pane, ...).
        if (!(key.mod.control() or key.mod.alt() or isFKey(key.code))) continue;

        // Tab switching always works (even during modals). Through
        // execAction, which ends quick-open first like every command.
        if (key.mod.control() and key.code == .tab) {
            e.handled = true;
            _ = editor.execAction(if (key.mod.shift()) "prev_doc" else "next_doc");
            continue;
        }

        // A terminal pane (or the terminal panel) that owns the keyboard
        // gets every other chord; handleTerminalKeyEvents hands the
        // pane/window management ones back (terminalPassthroughAction). A
        // side panel focused over a terminal owns the keyboard instead, so
        // its chords run here.
        if (editor.keyboardOwner() == .terminal or editor.keyboardOwner() == .terminal_panel) continue;

        // Keybinds only in normal mode (not during find/replace/palette)
        if (guiMode(editor) != .normal) continue;
        if (isModifierKey(key.code)) continue;

        const action = chordAction(editor, key, false) orelse continue;
        e.handled = true;
        win_ui.scroll_pinned = false;
        if (key.code == .space) win_ui.swallow_space = true;
        // A focused side panel takes the clipboard and word-delete chords
        // (the tree copies files, the search panel edits its field): they
        // must never edit the document behind it.
        if (!editor.panelAction(action)) execGuiAction(editor, action);
    }
}

/// The action bound to a key event: the exact chord, else (for a Shift
/// chord on a symbol or F-key, never on a letter: Ctrl+Shift+Z is not
/// undo) the chord without Shift. `passthrough_only` limits the lookup to
/// the chords a focused terminal pane must not swallow.
fn chordAction(editor: *Editor, key: dvui.Event.Key, passthrough_only: bool) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const combo = dvuiKeyToStr(key, &buf);
    if (combo.len == 0) return null;
    if (comboAction(editor, combo, passthrough_only)) |action| return action;
    if (!key.mod.shift() or !keybind.allowsShiftFallback(combo)) return null;
    var buf2: [64]u8 = undefined;
    return comboAction(editor, dvuiKeyToStrNoShift(key, &buf2), passthrough_only);
}

fn comboAction(editor: *Editor, combo: []const u8, passthrough_only: bool) ?[]const u8 {
    return if (passthrough_only) editor.terminalPassthroughAction(combo) else editor.lookupKeybind(combo);
}

fn isFKey(code: dvui.enums.Key) bool {
    return switch (code) {
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => true,
        else => false,
    };
}

/// Shift, Ctrl, Alt or Cmd pressed on its own.
fn isModifierKey(code: dvui.enums.Key) bool {
    return switch (code) {
        .left_shift, .right_shift, .left_control, .right_control, .left_alt, .right_alt, .left_command, .right_command => true,
        else => false,
    };
}

/// Ctrl, Alt or Cmd held: a chord, never a prompt's answer letter.
fn hasCommandMod(mod: dvui.enums.Mod) bool {
    return mod.control() or mod.alt() or mod.command();
}

/// The keyboard owner (and where it was) as of the last frame. When it
/// changes and lands on an editor pane (Escape or Enter in a side panel,
/// Ctrl+B, F6 to another pane, a window switch, a command), that pane
/// takes dvui focus (filetree_release_focus): its movement and typing
/// handlers are gated on holding it. Null before the first frame, so the
/// editor pane also starts out with the keyboard.
const OwnerSeen = struct { owner: Editor.KeyboardOwner, window: usize, pane: u8 };
var owner_seen: ?OwnerSeen = null;

fn trackKeyboardOwner(editor: *Editor) void {
    const now: OwnerSeen = .{ .owner = editor.keyboardOwner(), .window = editor.active_window, .pane = editor.activePaneId() };
    if (owner_seen) |seen| {
        if (std.meta.eql(seen, now)) return;
    }
    owner_seen = now;
    if (now.owner == .editor) filetree_release_focus = true;
}

/// Key and text events go to the file tree: normal mode (as the current
/// window sees it) and the tree owns the keyboard.
fn treeTakesKeys(editor: *const Editor) bool {
    return guiMode(editor) == .normal and editor.keyboardOwner() == .filetree;
}

/// Key and text events go to the Snippets panel (typing filters its rows).
fn snippetsTakesKeys(editor: *const Editor) bool {
    return guiMode(editor) == .normal and editor.keyboardOwner() == .snippets;
}

/// Key and text events go to the search panel.
fn searchTakesKeys(editor: *const Editor) bool {
    return guiMode(editor) == .normal and editor.keyboardOwner() == .search;
}

/// Key and text events go to the focused terminal pane.
fn terminalTakesKeys(editor: *const Editor) bool {
    return guiMode(editor) == .normal and editor.keyboardOwner() == .terminal;
}

/// Key and text events go to the terminal panel's shell.
fn terminalPanelTakesKeys(editor: *const Editor) bool {
    return guiMode(editor) == .normal and editor.keyboardOwner() == .terminal_panel;
}

/// Key and text events go to the focused editor pane: modal prompts live
/// in it, and in normal mode it must own the keyboard (a side panel never
/// shares it).
fn editorTakesKeys(editor: *const Editor) bool {
    return guiMode(editor) != .normal or editor.keyboardOwner() == .editor;
}

/// Menu bar of the current window.
fn menuBar(editor: *Editor) void {
    // --- Menu bar ---
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .style = .window,
            .background = true,
            .expand = .horizontal,
            .name = "menubar",
        });
        defer hbox.deinit();
        dismissFinderOnBarPress(editor, hbox.data().rectScale().r);

        var m = dvui.menu(@src(), .horizontal, .{});
        defer m.deinit();

        // ---- File ----
        if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "New              Ctrl+N", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.newDocument() catch {};
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Open File        Ctrl+O", .{}, .{ .expand = .horizontal }) != null) {
                openFileDialog(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Open Folder      Ctrl+Shift+O", .{}, .{ .expand = .horizontal }) != null) {
                openFolderDialog(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Recent Projects", .{ .submenu = true }, .{ .expand = .horizontal })) |r2| {
                var rw = dvui.floatingMenu(@src(), .{ .from = r2 }, .{});
                defer rw.deinit();
                editor.ensureRecentProjects();
                if (editor.recent_projects.items.len == 0) dvui.labelNoFmt(@src(), "(none yet)", .{}, .{});
                for (editor.recent_projects.items, 0..) |path, idx| {
                    if (dvui.menuItemLabel(@src(), path, .{}, .{ .expand = .horizontal, .id_extra = idx }) != null) {
                        editor.chooseRecentProject(idx);
                        m.close();
                        break;
                    }
                }
            }
            if (dvui.menuItemLabel(@src(), "Save             Ctrl+S", .{}, .{ .expand = .horizontal }) != null) {
                save(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Save As          Ctrl+Shift+S", .{}, .{ .expand = .horizontal }) != null) {
                saveAs(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Close Tab        Ctrl+W", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("close_tab"); // asks about unsaved changes
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Reopen Closed Tab Ctrl+Shift+T", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("reopen_closed_tab");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Exit             Ctrl+Q", .{}, .{ .expand = .horizontal }) != null) {
                // Same path as Ctrl+Q and the OS close button: prompt for
                // unsaved changes instead of dropping them.
                _ = editor.execAction("quit");
                m.close();
            }
        }

        // ---- Edit ----
        if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            // Like their keys: the find bar's box has undo steps of its own.
            if (dvui.menuItemLabel(@src(), "Undo             Ctrl+Z", .{}, .{ .expand = .horizontal }) != null) {
                if (!editor.panelAction("undo")) _ = editor.execCommand("undo", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Redo             Ctrl+Y", .{}, .{ .expand = .horizontal }) != null) {
                if (!editor.panelAction("redo")) _ = editor.execCommand("redo", null);
                m.close();
            }
            // Like their keys: a focused side panel takes them.
            if (dvui.menuItemLabel(@src(), "Cut              Ctrl+X", .{}, .{ .expand = .horizontal }) != null) {
                if (!editor.panelAction("cut")) _ = editor.execCommand("cut", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Copy             Ctrl+C", .{}, .{ .expand = .horizontal }) != null) {
                if (!editor.panelAction("copy")) _ = editor.execCommand("copy", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Paste            Ctrl+V", .{}, .{ .expand = .horizontal }) != null) {
                if (!editor.panelAction("paste")) _ = editor.execCommand("paste", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Select All       Ctrl+A", .{}, .{ .expand = .horizontal }) != null) {
                if (!editor.panelAction("select_all")) _ = editor.execCommand("select_all", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Save Selection as Snippet…  Ctrl+Alt+S", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("snippet_save_selection", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Toggle Comment   Ctrl+/", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("toggle_comment", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Find             Ctrl+F", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("find");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Find Next        F3", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("find_next", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Find Previous    Shift+F3", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("find_previous", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Replace          Ctrl+H", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("find_replace");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Go to Line       Ctrl+G", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("goto_line");
                m.close();
            }
        }

        // ---- View ----
        if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Command Palette  Ctrl+P", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("command_palette");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "File Tree        Ctrl+B", .{}, .{ .expand = .horizontal }) != null) {
                // Like Ctrl+B: from a secondary window this raises the primary.
                execGuiAction(editor, "toggle_filetree");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Snippets         Ctrl+Alt+B", .{}, .{ .expand = .horizontal }) != null) {
                // Like Ctrl+Alt+B: the panel lives in the primary window.
                execGuiAction(editor, "toggle_snippets");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Terminal Panel   Ctrl+Shift+`", .{}, .{ .expand = .horizontal }) != null) {
                // Like Ctrl+Shift+`: the panel lives in the primary window.
                execGuiAction(editor, "toggle_terminal_panel");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Reveal in Tree", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("filetree_reveal", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Next Tab         Ctrl+Tab", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("next_doc");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Prev Tab         Ctrl+Shift+Tab", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("prev_doc");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Split Vertical   Alt+\\", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("split_vertical");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Split Horizontal Alt+Shift+\\", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("split_horizontal");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Close Pane       Ctrl+Alt+Q", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("close_pane");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Close Terminal", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("close_terminal");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Open in New Window  Ctrl+Shift+N", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("open_in_new_window");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Move Pane to New Window", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("move_pane_to_new_window");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Close Window", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("close_window");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Detach Terminal  Ctrl+Alt+`", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("detach_terminal");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Dock Terminal in Panel", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("dock_terminal");
                m.close();
            }
        }

        // ---- Preferences ----
        if (dvui.menuItemLabel(@src(), "Preferences", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Settings", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("settings");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Open Settings File", .{}, .{ .expand = .horizontal }) != null) {
                openSettingsFile(editor);
                m.close();
            }
            // Theme submenu
            if (dvui.menuItemLabel(@src(), "Theme", .{ .submenu = true }, .{ .expand = .horizontal })) |r2| {
                var tw = dvui.floatingMenu(@src(), .{ .from = r2 }, .{});
                defer tw.deinit();
                if (dvui.menuItemLabel(@src(), "Dark — deep grays, soft white text", .{}, .{ .expand = .horizontal }) != null) {
                    switchTheme(editor, "dark");
                    m.close();
                }
                if (dvui.menuItemLabel(@src(), "Light — white background, dark text", .{}, .{ .expand = .horizontal }) != null) {
                    switchTheme(editor, "light");
                    m.close();
                }
                if (dvui.menuItemLabel(@src(), "High Contrast — black background, bright text", .{}, .{ .expand = .horizontal }) != null) {
                    switchTheme(editor, "high_contrast");
                    m.close();
                }
            }
            if (dvui.menuItemLabel(@src(), "Open Theme File", .{}, .{ .expand = .horizontal }) != null) {
                openThemeFile(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Open Theme Folder", .{}, .{ .expand = .horizontal }) != null) {
                openThemeFolder(editor.io);
                m.close();
            }
        }

        // ---- Help ----
        if (dvui.menuItemLabel(@src(), "Help", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Documentation", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("open_documentation", null);
                m.close();
            }
            _ = dvui.menuItemLabel(@src(), "About ZIDE v0.0.1", .{}, .{ .expand = .horizontal });
        }
    }
}

/// The editor mode as seen by the current window: the Settings dialog and
/// the snippet form are modal only for the window they are open in —
/// everywhere else the mode reads as normal so keys, clicks and the shell
/// keep working there.
fn guiMode(editor: *const Editor) Editor.Mode {
    const win_id = editor.windows.items[cur_win].id;
    if (editor.mode == .settings and win_id != editor.settings_window_id) return .normal;
    if (editor.mode == .snippet_form and win_id != snippetFormWindowId(editor)) return .normal;
    return editor.mode;
}

/// The window the snippet form's dialog shows in: the one it was opened
/// from, or the primary once that one has closed (closeWindow moves a
/// Settings dialog the same way; without this the form would stay open
/// with no window drawing it, and Ctrl+Alt+S would do nothing).
fn snippetFormWindowId(editor: *const Editor) u32 {
    const id = editor.snippet_form.window_id;
    for (editor.windows.items) |win| {
        if (win.id == id) return id;
    }
    return editor.windows.items[0].id;
}

/// Quick-open ends when the menu bar or the tab bar of its window is
/// pressed: a menu command or a tab switch acts on real documents, never
/// on the view behind the preview. The press itself stays unhandled so
/// the bar still gets it.
fn dismissFinderOnBarPress(editor: *Editor, bar: dvui.Rect.Physical) void {
    if (editor.mode != .file_finder or cur_win != editor.active_window) return;
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .press or me.floating_win != dvui.subwindowCurrentId()) continue;
        if (bar.contains(me.p)) {
            editor.finderCancel();
            return;
        }
    }
}

/// Dialogs of the current window (Settings, the snippet form, the delete
/// confirmations) and the active window's prompts. Declared before the
/// panes so their widgets consume their events first.
fn modalDialogs(editor: *Editor) void {
    if (cur_win == editor.active_window) {
        // zide.exec("file_open") and the palette land in this mode (Ctrl+O
        // opens the dialog directly): answer with the native picker. The
        // mode goes first: opening may start the encoding prompt.
        if (editor.mode == .file_open) {
            editor.setMode(.normal);
            openFileDialog(editor);
        }
        if (editor.mode == .folder_open) {
            editor.setMode(.normal);
            openFolderDialog(editor);
        }
        if (editor.mode == .save_as) saveAs(editor);
        if (editor.mode == .recovery_picker) recoveryDialog(editor);
        if (editor.mode == .tool_panel or editor.mode == .task_save_prompt or editor.mode == .git_stage_prompt) toolDialog(editor);
        if (editor.mode == .lsp_panel or editor.mode == .symbol_rename or editor.mode == .workspace_preview) lspDialog(editor);
        if (editor.mode == .encoding_picker or editor.mode == .confirm_reopen or editor.mode == .confirm_encoding) encodingDialog(editor);
        if (editor.mode == .recent_projects) recentProjectsDialog(editor);
    }
    // --- Settings dialog (modal floating window) ---
    // Declared before the panes so its widgets consume their events first;
    // the panes' raw event loops only see what the dialog left unhandled.
    // The dialog stays in the window it was opened from (it does not follow
    // focus); the other windows keep working meanwhile (guiMode).
    if (editor.mode == .settings) {
        if (editor.windows.items[cur_win].id == editor.settings_window_id) settingsDialog(editor);
    } else {
        // Re-arm the text-setting pre-fill for the next dialog open
        settings_text_prefill = true;
    }
    // --- Snippet form ("Save as snippet") — the same rules: a modal dvui
    // dialog, declared before the panes, pinned to its window. ---
    if (editor.mode == .snippet_form) {
        if (editor.windows.items[cur_win].id == snippetFormWindowId(editor)) snippetFormDialog(editor);
    } else {
        // The next open puts the caret in Name again.
        snippet_form_focus_pending = true;
        snippet_form_error_hash = null;
    }

    // Delete confirmation dialog (clickable) — same declared-before-panes
    // rule as the settings dialog so its buttons win the event race.
    if (editor.mode == .filetree_prompt and editor.filetree_prompt_kind == .delete_confirm and editor.active_window == cur_win) {
        filetreeDeleteDialog(editor);
    }
    // The Snippets panel's "Delete snippet" question, the same way.
    if (editor.mode == .snippet_delete_confirm and editor.active_window == cur_win) snippetDeleteDialog(editor);
}

/// Tab bar of the current window: the documents it owns (EditorWindow.tabs);
/// the highlight is the one shown in its focused pane.
fn tabBar(editor: *Editor) void {
    const td = &win_ui.tab_drag;
    const this_win = editor.windows.items[cur_win];
    // The main window hides the bar with a single document (as always); an
    // extra window keeps it so its tab can be dragged back.
    if (cur_win == 0 and this_win.tabs.items.len <= 1) {
        td.state = .idle; // no bar, nothing to drag
        return;
    }
    // A drag whose document list changed under it (close/open) points at a
    // different document now — cancel rather than move the wrong one.
    if (td.state != .idle and (td.doc_idx >= editor.documents.items.len or td.doc_count != editor.documents.items.len)) {
        td.state = .idle;
    }
    tabDragPrePass(editor);

    // Clicks, drops, closes and moves are collected during the loop and
    // applied after it: each one edits the tab list the loop walks.
    var acts: TabBarActions = .{};

    var tab_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .style = .content,
        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
    });
    defer tab_box.deinit();
    const bar_rs = tab_box.data().rectScale();
    td.bar_rect = bar_rs.r;
    const scale = bar_rs.s;
    dismissFinderOnBarPress(editor, bar_rs.r);

    for (this_win.tabs.items) |i| {
        if (i >= editor.documents.items.len) continue;
        const doc = &editor.documents.items[i];
        if (doc.preview) continue; // hidden from the tab bar
        const is_active = (i == editor.windowDocIdx(cur_win));
        var label_buf: [256]u8 = undefined;
        const dirty_marker: []const u8 = if (doc.dirty) " *" else "";
        const label = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ doc.display_name, dirty_marker }) catch doc.display_name;

        // Tab container: label + close button
        var tab = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = @intCast(i),
            .background = true,
            .style = if (is_active) .highlight else .control,
            .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
            .border = .{ .x = 1, .y = 1, .w = 1, .h = 1 },
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        });
        defer tab.deinit();

        // The label sits in a plain box with our own mouse handling: a
        // dvui.button would capture the press and swallow the release the
        // drag needs, and its focus handling stole focus from the pane.
        var lbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = @intCast(i),
            .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        });
        const label_rect = lbox.data().rectScale().r;
        dvui.labelNoFmt(@src(), label, .{}, .{ .id_extra = @intCast(i), .gravity_y = 0.5 });
        lbox.deinit();
        tabHandleMouse(editor, i, label_rect, scale, &acts);

        // Right-click menu — the guaranteed path to a new window
        {
            const ctext = dvui.context(@src(), .{ .rect = label_rect }, .{ .id_extra = @intCast(i) });
            defer ctext.deinit();
            if (ctext.activePoint()) |cp| {
                var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{});
                defer fw.deinit();
                if (dvui.menuItemLabel(@src(), "Move to New Window", .{}, .{ .expand = .horizontal }) != null) {
                    acts.new_window = doc.id;
                    fw.close();
                }
                if (dvui.menuItemLabel(@src(), "Close Tab", .{}, .{ .expand = .horizontal }) != null) {
                    acts.close = doc.id;
                    fw.close();
                }
            }
        }

        // Close button (x)
        if (dvui.button(@src(), "\xc3\x97", .{}, .{ // × (multiplication sign)
            .id_extra = @intCast(i),
            .background = false,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
            .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        })) {
            acts.close = doc.id;
        }
    }

    applyTabBarActions(editor, acts);
}

/// Tab-bar actions of one frame, by document id (an earlier action, or the
/// quick-open preview going away, can shift the indices).
const TabBarActions = struct {
    /// Plain click: show the document in this window.
    show: ?u64 = null,
    /// Drag released off the bar at `p`.
    drop: ?struct { id: u64, p: dvui.Point.Physical } = null,
    close: ?u64 = null,
    new_window: ?u64 = null,
};

/// Run what the tab loop collected, after it finished.
fn applyTabBarActions(editor: *Editor, acts: TabBarActions) void {
    if (acts.show) |id| if (editor.docIndexForId(id)) |idx| {
        editor.showDocIn(cur_win, idx);
        win_ui.refocus_editor = true;
    };
    if (acts.drop) |d| if (editor.docIndexForId(d.id)) |idx| tabDrop(editor, idx, d.p);
    // Closing goes by document, not by switching to it first (that would
    // hijack a focused terminal pane's content); a document with unsaved
    // changes gets the Save / Discard / Cancel prompt.
    if (acts.close) |id| {
        if (editor.docIndexForId(id)) |idx| _ = editor.requestCloseDoc(idx);
    } else if (acts.new_window) |id| {
        if (!editor.multi_window_supported) {
            editor.setStatus(.warning, "This build has no extra windows (SDL3 renderer backend needed)");
        } else if (editor.docIndexForId(id)) |idx| editor.showDocInNewWindow(idx);
    }
}

/// Before the tabs each frame: Escape cancels a drag, and a drag whose
/// release never reached this window (SDL routes it to the window under the
/// pointer, or it got lost) drops where the pointer is now.
fn tabDragPrePass(editor: *Editor) void {
    const td = &win_ui.tab_drag;
    if (td.state != .dragging) return;
    var release_pending = false;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .key => |key| {
                if (key.action == .down and key.code == .escape) {
                    e.handled = true;
                    td.state = .idle;
                    editor.status_message = "";
                    return;
                }
            },
            .mouse => |me| {
                if (me.action == .release) release_pending = true;
            },
            else => {},
        }
    }
    if (release_pending) return; // tabHandleMouse takes it from here
    if (comptime dvui.Backend.support_child_os_wins) {
        const c = dvui.backend.c;
        var gx: f32 = 0;
        var gy: f32 = 0;
        const buttons = c.SDL_GetGlobalMouseState(&gx, &gy);
        if ((buttons & c.SDL_BUTTON_LMASK) == 0) {
            td.state = .idle;
            tabDropAt(editor, td.doc_idx, gx, gy);
        }
    }
}

/// Raw mouse handling for one tab label: press arms, motion drags, release
/// clicks or drops. One state machine per window (win_ui.tab_drag), in event
/// order — a press and its release in the same frame both resolve here. A
/// click or drop is recorded in `acts` (tabBar applies it after its loop).
fn tabHandleMouse(editor: *Editor, doc_idx: usize, r: dvui.Rect.Physical, scale: f32, acts: *TabBarActions) void {
    const td = &win_ui.tab_drag;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.floating_win != dvui.subwindowCurrentId()) continue;
        const inside = r.contains(me.p);
        const mine = td.state != .idle and td.doc_idx == doc_idx;
        switch (me.action) {
            .focus => if (inside) {
                e.handled = true;
            },
            .press => if (inside and me.button == .left) {
                e.handled = true;
                td.* = .{
                    .state = .armed,
                    .doc_idx = doc_idx,
                    .doc_count = editor.documents.items.len,
                    .press_pt = me.p,
                    .bar_rect = td.bar_rect,
                };
            },
            .motion => if (mine) {
                e.handled = true;
                if (td.state == .armed) {
                    const dx = me.p.x - td.press_pt.x;
                    const dy = me.p.y - td.press_pt.y;
                    const threshold = 6 * scale;
                    if (dx * dx + dy * dy > threshold * threshold) {
                        td.state = .dragging;
                        editor.status_message = "Drop outside the tab bar to open in a new window (Esc cancels)";
                    }
                }
            },
            .release => if (mine) {
                e.handled = true;
                const was_dragging = td.state == .dragging;
                td.state = .idle;
                const id = editor.documents.items[doc_idx].id;
                if (was_dragging) {
                    acts.drop = .{ .id = id, .p = me.p };
                } else {
                    // A plain click shows the document in this window
                    acts.show = id;
                }
            },
            .position => {
                if (mine and td.state == .dragging) {
                    dvui.cursorSet(.arrow_all);
                } else if (inside and td.state == .idle) {
                    dvui.cursorSet(.hand);
                }
            },
            else => {},
        }
    }
}

/// Release after a drag: back on the bar cancels (no tab reordering);
/// anywhere else drops at the pointer's screen position.
fn tabDrop(editor: *Editor, doc_idx: usize, p: dvui.Point.Physical) void {
    editor.status_message = "";
    if (win_ui.tab_drag.bar_rect.contains(p)) return;
    if (comptime dvui.Backend.support_child_os_wins) {
        const c = dvui.backend.c;
        var gx: f32 = 0;
        var gy: f32 = 0;
        _ = c.SDL_GetGlobalMouseState(&gx, &gy);
        tabDropAt(editor, doc_idx, gx, gy);
    } else {
        editor.setStatus(.warning, "This build has no extra windows (SDL3 renderer backend needed)");
    }
}

/// Drop at a screen position: another ZIDE window there shows the document,
/// otherwise a new window opens at that spot. Wayland has no global pointer
/// position and ignores window placement — the compositor decides there.
fn tabDropAt(editor: *Editor, doc_idx: usize, gx: f32, gy: f32) void {
    editor.status_message = "";
    if (doc_idx >= editor.documents.items.len) return;
    if (!editor.multi_window_supported) {
        editor.setStatus(.warning, "This build has no extra windows (SDL3 renderer backend needed)");
        return;
    }
    if (comptime dvui.Backend.support_child_os_wins) {
        const c = dvui.backend.c;
        const st = active_state orelse return;
        const wayland = isWayland();
        if (!wayland) {
            const fx: c_int = @intFromFloat(gx);
            const fy: c_int = @intFromFloat(gy);
            for (st.wins.items) |w| {
                const sw = c.SDL_GetWindowFromID(w.sdl_window_id);
                if (sw == null) continue;
                var wx: c_int = 0;
                var wy: c_int = 0;
                var ww: c_int = 0;
                var wh: c_int = 0;
                _ = c.SDL_GetWindowPosition(sw, &wx, &wy);
                _ = c.SDL_GetWindowSize(sw, &ww, &wh);
                if (fx < wx or fx >= wx + ww or fy < wy or fy >= wy + wh) continue;
                // Back onto the window the drag started from: nothing to do.
                if (w.win_id == win_ui.win_id) return;
                for (editor.windows.items, 0..) |ew, idx| {
                    if (ew.id == w.win_id) {
                        // Showing it there moves its tab (the source pane
                        // switches to its neighbouring tab).
                        editor.showDocIn(idx, doc_idx);
                        w.refocus_editor = true;
                        _ = c.SDL_RaiseWindow(sw);
                        return;
                    }
                }
            }
        }
        const before = editor.windows.items.len;
        editor.showDocInNewWindow(doc_idx);
        if (editor.windows.items.len > before and !wayland) {
            editor.windows.items[before].spawn_pos = .{ .x = @intFromFloat(gx), .y = @intFromFloat(gy) };
        }
    }
}

/// SDL video driver is Wayland (no global pointer position, no window placement).
fn isWayland() bool {
    if (comptime dvui.Backend.support_child_os_wins) {
        const drv = dvui.backend.c.SDL_GetCurrentVideoDriver();
        if (drv == null) return false;
        return std.mem.eql(u8, std.mem.span(drv), "wayland");
    }
    return false;
}

/// Status bar of the current window.
fn statusBar(editor: *Editor) void {
    // --- Status bar (renderText only — no TextLayoutWidgets, no layout instability) ---
    {
        const status_font = dvui.Font.theme(.body);
        const status_h = status_font.lineHeight();

        var status_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .style = .content,
            .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
            .min_size_content = .{ .h = status_h },
        });
        defer status_box.deinit();

        // The document shown in THIS window's focused pane (a terminal pane
        // reads "Terminal" instead of the document it falls back to).
        const doc = &editor.documents.items[editor.windowDocIdx(cur_win)];
        const pos = doc.cursorPos();
        const this_win = editor.windows.items[cur_win];
        const term_active = this_win.active_pane < this_win.layout.panes.items.len and
            this_win.layout.panes.items[this_win.active_pane].content == .terminal;

        const swd = status_box.data();
        const srs = swd.contentRectScale();
        const sarea = srs.r;
        const sscale = srs.s;
        const status_text_color = toDvui(editor.theme.status_fg);

        // Left: Ln/Col (+ cursor count if multi-cursor)
        var pos_buf: [160]u8 = undefined;
        const cursor_count = doc.cursors.count();
        // Show the detected language (and its server once up) so it's
        // obvious what syntax/LSP applies.
        var lang_buf: [64]u8 = undefined;
        const lang_name = editor.languageStatusText(doc, &lang_buf);
        // Review progress and this file's verdict, while changed files are listed.
        var review_buf: [48]u8 = undefined;
        const review_segment = if (term_active) "" else editor.review.statusSegment(editor, &review_buf);
        const review_sep: []const u8 = if (review_segment.len > 0) " | " else "";
        // The terminal panel owning the keyboard (primary window only) says
        // so too: typing is not going to the document.
        const panel_active = cur_win == 0 and editor.keyboardOwner() == .terminal_panel;
        const pos_str: []const u8 = if (term_active)
            "Terminal"
        else if (panel_active)
            "Terminal panel"
        else if (cursor_count > 1)
            std.fmt.bufPrint(&pos_buf, "{d} cursors | Ln {d}, Col {d} | {s}{s}{s}", .{ cursor_count, pos.line + 1, pos.col + 1, lang_name, review_sep, review_segment }) catch "?"
        else
            std.fmt.bufPrint(&pos_buf, "Ln {d}, Col {d} | {s}{s}{s}", .{ pos.line + 1, pos.col + 1, lang_name, review_sep, review_segment }) catch "?";
        dvui.renderText(.{
            .font = status_font,
            .text = pos_str,
            .rs = srs,
            .p = .{ .x = sarea.x, .y = sarea.y },
            .color = status_text_color,
        }) catch {};

        // Right block geometry first: the center text is clipped to the
        // room before it, so a long message never runs under the file name.
        const enc = doc.format.label();
        const enc_w = status_font.textSize(enc).w * sscale;
        const dirty_str: []const u8 = if (doc.dirty) " [Modified]" else "";
        var name_buf: [256]u8 = undefined;
        const name_str = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ doc.display_name, dirty_str }) catch doc.display_name;
        const name_w = status_font.textSize(name_str).w * sscale;
        const name_x = sarea.x + sarea.w - enc_w - 16 * sscale - name_w;
        const center_x = sarea.x + status_font.textSize(pos_str).w * sscale + 20 * sscale;
        const center_limit = if (term_active) sarea.x + sarea.w else name_x - 12 * sscale;
        const center_clip: dvui.Rect.Physical = .{ .x = center_x, .y = sarea.y, .w = @max(0, center_limit - center_x), .h = sarea.h };

        // Center: transient status message ("Saved", "Cannot open: ...",
        // file-tree results) takes priority over the line diagnostic —
        // previously these were never rendered in normal mode at all.
        // A new one is a highlighted block for a few seconds (drawn last,
        // over the rest of the bar), then plain text clipped to its slot.
        const message = editor.statusView(std.Io.Clock.now(.awake, editor.io).nanoseconds);
        const message_block: ?dvui.Rect.Physical = if (message.fresh) statusBlockRect(status_font, sscale, sarea, center_x, message.text) else null;
        const line_diag = if (term_active) null else worstDiagnosticOnLine(doc, pos.line);
        if (message.text.len > 0) {
            if (!message.fresh) {
                const prev_clip = dvui.clip(center_clip);
                defer dvui.clipSet(prev_clip);
                dvui.renderText(.{
                    .font = status_font,
                    .text = message.text,
                    .rs = srs,
                    .p = .{ .x = center_x, .y = sarea.y },
                    .color = status_text_color,
                }) catch {};
            }
        } else if (line_diag) |diag| {
            const diag_color = diagnosticColor(diag.severity);
            const prefix: []const u8 = switch (diag.severity) {
                .err => "Error: ",
                .warning => "Warning: ",
                .information => "Info: ",
                .hint => "Hint: ",
            };
            var diag_buf: [256]u8 = undefined;
            const max_msg = text_input.floor(diag.message, diag_buf.len - prefix.len);
            @memcpy(diag_buf[0..prefix.len], prefix);
            @memcpy(diag_buf[prefix.len..][0..max_msg], diag.message[0..max_msg]);
            const diag_str = diag_buf[0 .. prefix.len + max_msg];
            // Position after cursor info with some padding
            const prev_clip = dvui.clip(center_clip);
            defer dvui.clipSet(prev_clip);
            dvui.renderText(.{
                .font = status_font,
                .text = diag_str,
                .rs = srs,
                .p = .{ .x = center_x, .y = sarea.y },
                .color = diag_color,
            }) catch {};
        }

        // Right: filename + dirty marker (nothing for a terminal pane)
        if (!term_active) {
            const enc_rect: dvui.Rect.Physical = .{ .x = sarea.x + sarea.w - enc_w, .y = sarea.y, .w = enc_w, .h = sarea.h };
            enc_rect.fill(.{}, .{ .color = toDvui(editor.theme.status_bg), .fade = 1.0 });
            renderOverlayText(status_font, enc, enc_rect.x, enc_rect.y, srs, status_text_color);
            for (dvui.events()) |*e| {
                if (e.handled or e.evt != .mouse) continue;
                const me = e.evt.mouse;
                // Not through a message block that covers the label.
                if (message_block) |block| if (block.contains(me.p)) continue;
                if (me.action == .press and me.button == .left and enc_rect.contains(me.p)) {
                    e.handle(@src(), swd);
                    // The picker acts on this window's document; switching
                    // windows only when needed keeps a side panel's keyboard.
                    if (editor.active_window != cur_win) editor.focusWindow(cur_win);
                    editor.startEncoding(.choose);
                }
            }
            dvui.renderText(.{
                .font = status_font,
                .text = name_str,
                .rs = srs,
                .p = .{ .x = name_x, .y = sarea.y },
                .color = status_text_color,
            }) catch {};
        }

        if (message_block) |block| drawStatusBlock(editor, status_font, srs, block, message);
    }
}

/// Where a new status message's block goes. It starts in the message slot
/// (`slot_x`, where the plain text is drawn afterwards) and moves left over
/// the rest of the bar when the text needs the room; never wider than `bar`.
fn statusBlockRect(font: dvui.Font, scale: f32, bar: dvui.Rect.Physical, slot_x: f32, text: []const u8) dvui.Rect.Physical {
    const pad = status_block_pad * scale;
    const w = @min(bar.w, font.textSize(text).w * scale + pad * 2);
    const x = @max(bar.x, @min(slot_x - pad, bar.x + bar.w - w));
    return .{ .x = x, .y = bar.y - scale, .w = w, .h = bar.h + scale * 2 };
}

/// Blank space either side of a status message block's text (natural pixels).
const status_block_pad: f32 = 8;

/// The highlighted block of a new status message, in its level's colors; a
/// text too wide even for the whole bar ends in "…".
fn drawStatusBlock(editor: *Editor, font: dvui.Font, rs: dvui.RectScale, block: dvui.Rect.Physical, message: status_mod.View) void {
    const pair = theme_mod.statusBlock(&editor.theme, message.level);
    const rad = 4 * rs.s;
    block.fill(.{ .x = rad, .y = rad, .w = rad, .h = rad }, .{ .color = toDvui(pair.bg), .fade = 1.0 });
    const pad = status_block_pad * rs.s;
    const room = block.w - pad * 2;
    var buf: [status_mod.Flash.capacity + 3]u8 = undefined;
    var text = message.text;
    if (font.textSize(text).w * rs.s > room + 0.5) {
        const ellipsis = "…";
        const fit = fitOverlayText(font, text, room - font.textSize(ellipsis).w * rs.s, rs.s);
        @memcpy(buf[0..fit.len], fit);
        @memcpy(buf[fit.len..][0..ellipsis.len], ellipsis);
        text = buf[0 .. fit.len + ellipsis.len];
    }
    const prev_clip = dvui.clip(block);
    defer dvui.clipSet(prev_clip);
    renderOverlayText(font, text, block.x + pad, block.y + rs.s, rs, toDvui(pair.fg));
}

/// Editor area of the current window: the split-pane tree, the find bar
/// under it when this window shows it, plus (primary window only,
/// side_panels) the docked file tree, Snippets panel, terminal panel and
/// search panel.
fn editorArea(editor: *Editor, side_panels: bool) void {
    // --- Editor area (expand=.both, LAST child) ---
    // The file tree, the Snippets panel and a side-docked terminal panel
    // dock left or right of the split tree as fixed-size siblings in an
    // hbox; the splits expand into the rest, above a bottom-docked
    // terminal panel (a fixed-height strip between the side bands). The
    // docked search panel (when shown) sits below them all as a
    // fixed-height strip.
    {
        var main_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer main_col.deinit();
        {
            var content_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer content_row.deinit();
            const row_rect = content_row.data().contentRect();
            const tree = side_panels and editor.filetree_visible and editor.ensureFiletree() != null;
            const snippets_w: f32 = if (side_panels) snippetsBandWidth(editor, row_rect.w, tree) else 0;
            const snippets_side = editor.snippetsSide();
            const tp_edge = editor.terminal_panel_side;
            const tp_size: f32 = if (side_panels) terminalPanelBandSize(editor, row_rect, tree, snippets_w) else 0;
            // Call order is the left-to-right order: on a shared side the
            // tree is the outermost band, then the Snippets panel, then
            // the terminal panel.
            if (tree and editor.filetree_side == .left) filetreePanel(editor);
            if (snippets_w > 0 and snippets_side == .left) snippetsPanel(editor, snippets_w);
            if (tp_size > 0 and tp_edge == .left) terminalPanel(editor, tp_size, .left);
            {
                var center_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
                defer center_col.deinit();
                renderPanes(editor);
                // The find bar: under the panes of the window it was opened
                // in, above a bottom-docked terminal panel.
                if (editor.find_bar.visible and editor.windows.items[cur_win].id == editor.find_bar.window_id) findBarGui(editor);
                if (tp_size > 0 and tp_edge == .bottom) terminalPanel(editor, tp_size, .bottom);
            }
            if (tp_size > 0 and tp_edge == .right) terminalPanel(editor, tp_size, .right);
            if (snippets_w > 0 and snippets_side == .right) snippetsPanel(editor, snippets_w);
            if (tree and editor.filetree_side == .right) filetreePanel(editor);
        }
        if (side_panels and editor.search_visible) searchPanelGui(editor);
        // Modal prompts normally live in the focused editor pane. With a
        // terminal pane focused (a detached terminal window, Ctrl+Q from a
        // shell) there is none — drive and draw them at window level.
        // Not Settings or the snippet form: dvui dialogs whose own entries
        // take the keys and text. This stand-in would feed every event they
        // leave to handleModalKey (a no-op for both) and claim text input
        // for the whole editor area, away from the focused entry.
        if (editor.active_window == cur_win and editor.mode != .normal and editor.mode != .settings and editor.mode != .snippet_form and editor.activePaneIsTerminal()) {
            windowLevelModal(editor, main_col.data());
        }
    }
}

/// The split tree of the current window. `rendering_panes` is set while the
/// paned widgets hold pointers into the layout — see DeferredQueue.
fn renderPanes(editor: *Editor) void {
    rendering_panes = true;
    defer rendering_panes = false;
    renderLayout(editor, 0);
}

/// Window-level stand-in for editorPane's modal handling when the focused
/// pane is a terminal: routes key/text events to the modal handlers and
/// draws the overlay over the whole editor area.
fn windowLevelModal(editor: *Editor, wd: *dvui.WidgetData) void {
    const mode = editor.mode;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        // A key that closed or switched the prompt ends its input.
        if (editor.mode != mode) break;
        switch (e.evt) {
            .key => |key| {
                if (key.action != .down and key.action != .repeat) continue;
                e.handle(@src(), wd);
                handleModalKey(editor, key);
            },
            .text => |te| switch (te.action) {
                .value => |val| {
                    // `selected` = uncommitted IME composition, not text.
                    if (val.txt.len > 0 and !val.selected) {
                        e.handle(@src(), wd);
                        handleModalText(editor, val.txt);
                    }
                },
                else => {},
            },
            else => {},
        }
    }
    const rs = wd.contentRectScale();
    dvui.wantTextInput(rs.r.toNatural());
    if (editor.mode != .normal) drawModalOverlay(editor, rs.r, rs, rs.s);
}

/// True while renderLayout runs (dvui.paned holds `ratioPtr` pointers into
/// the layout tree until it deinits; a split/close in between would leave
/// them dangling).
var rendering_panes: bool = false;

/// Work raised from inside a pane that must wait until every window has
/// rendered: ANY command can split or close panes (a Lua one through
/// zide.exec), so the palette's Enter and a terminal's passthrough chord
/// both land here, in order. Names are copied: a command that runs first
/// may free the registry or keymap strings a later entry pointed into.
const DeferredQueue = struct {
    const capacity = 4;
    const max_name = 256;

    const Kind = enum {
        /// execGuiAction (keybind action names; GUI dialogs for save/open).
        action,
        /// Editor.execCommand (what the palette runs).
        command,
    };
    const Entry = struct {
        kind: Kind,
        len: usize,
        buf: [max_name]u8,

        fn name(self: *const Entry) []const u8 {
            return self.buf[0..self.len];
        }
    };

    entries: [capacity]Entry = undefined,
    len: usize = 0,

    /// False when the queue is full or the name too long (not queued).
    fn push(self: *DeferredQueue, kind: Kind, name: []const u8) bool {
        if (self.len == capacity or name.len > max_name) return false;
        const e = &self.entries[self.len];
        e.kind = kind;
        e.len = name.len;
        @memcpy(e.buf[0..name.len], name);
        self.len += 1;
        return true;
    }

    /// The oldest entry, copied out, or null when empty.
    fn pop(self: *DeferredQueue) ?Entry {
        if (self.len == 0) return null;
        const first = self.entries[0];
        std.mem.copyForwards(Entry, self.entries[0 .. self.len - 1], self.entries[1..self.len]);
        self.len -= 1;
        return first;
    }
};
var deferred: DeferredQueue = .{};

/// Queue `name` for frame()'s end (see DeferredQueue); a full queue drops
/// it and says so rather than run it under the split widgets.
fn deferRun(editor: *Editor, kind: DeferredQueue.Kind, name: []const u8) void {
    if (!deferred.push(kind, name)) lua_api.setStatusError(editor, "Not run (too many at once): ", name);
}

/// Drain the deferred queue (after every window rendered) and draw its
/// effect (a split, the find bar) without waiting for more input.
fn runDeferred(editor: *Editor) void {
    var ran = false;
    // Nothing queues while no pane renders; the bound just rules out a spin.
    var budget: usize = DeferredQueue.capacity;
    while (budget > 0) : (budget -= 1) {
        const entry = deferred.pop() orelse break;
        ran = true;
        switch (entry.kind) {
            .action => execGuiAction(editor, entry.name()),
            .command => _ = editor.execCommand(entry.name(), null),
        }
    }
    if (ran) dvui.refresh(null, @src(), null);
}

/// Actions whose UI lives in the primary window only.
fn isPrimaryPanelAction(action: []const u8) bool {
    return std.mem.eql(u8, action, "toggle_filetree") or
        std.mem.eql(u8, action, "toggle_snippets") or
        std.mem.eql(u8, action, "toggle_terminal_panel") or
        std.mem.eql(u8, action, "filetree_reveal") or
        std.mem.eql(u8, action, "find_in_files");
}

/// Re-apply the dvui theme of the current window when the editor's theme
/// revision moved (dvui themes are per window; dvui.themeSet only touches
/// the current one).
fn applyThemeIfStale(editor: *Editor) void {
    if (win_ui.theme_gen_applied != editor.theme_revision) {
        dvui.themeSet(dvuiThemeForPreset(editor.theme_name, true, editor.mono_font_size));
        win_ui.theme_gen_applied = editor.theme_revision;
    }
}

/// Some window is waiting to be reaped or created — dvui would otherwise
/// sleep in waitEventTimeout until the next input event.
fn needsAnotherFrame(editor: *Editor, g: *GuiState) bool {
    for (editor.windows.items, 0..) |ew, i| {
        if (!ew.open) return true;
        if (i > 0) {
            const ui = g.find(ew.id) orelse return true;
            if (!ui.created) return true;
        }
    }
    return false;
}

/// The focused editor window follows the OS keyboard focus.
fn syncActiveWindowFromOs(editor: *Editor, g: *GuiState) void {
    if (comptime dvui.Backend.support_child_os_wins) {
        if (editor.windows.items.len <= 1) return;
        const c = dvui.backend.c;
        const focused = c.SDL_GetKeyboardFocus();
        if (focused == null) return;
        const ui = g.bySdlWindow(c.SDL_GetWindowID(focused)) orelse return;
        for (editor.windows.items, 0..) |ew, idx| {
            if (ew.id == ui.win_id) {
                if (idx != editor.active_window) editor.focusWindow(idx);
                return;
            }
        }
    }
}

/// Bring the primary OS window forward (its panels were asked for from a
/// secondary window).
fn raisePrimaryWindow() void {
    if (comptime dvui.Backend.support_child_os_wins) {
        const st = active_state orelse return;
        const c = dvui.backend.c;
        const w = c.SDL_GetWindowFromID(st.primary().sdl_window_id);
        if (w != null) _ = c.SDL_RaiseWindow(w);
    }
}

/// First placement of a new child window: at the spawn hint (a tab drop
/// point, screen coordinates) or cascaded from the primary window.
/// Wayland ignores window positions — the compositor decides there.
fn positionNewWindow(editor: *Editor, g: *GuiState, win_idx: usize, window: *dvui.backend.c.SDL_Window) void {
    const c = dvui.backend.c;
    if (editor.windows.items[win_idx].spawn_pos) |pos| {
        _ = c.SDL_SetWindowPosition(window, pos.x - 60, pos.y - 20);
        return;
    }
    const primary = c.SDL_GetWindowFromID(g.primary().sdl_window_id);
    if (primary == null) return;
    var px: c_int = 0;
    var py: c_int = 0;
    _ = c.SDL_GetWindowPosition(primary, &px, &py);
    const cascade: usize = @min(win_idx, 8);
    const step: c_int = @intCast(40 * cascade);
    _ = c.SDL_SetWindowPosition(window, px + step, py + step);
}

/// Secondary OS windows: one dvui child window per editor.windows[1..],
/// drawn one after another inside the primary frame. Children are created
/// only here, never from inside another child (OsWindowWidget nests them
/// under the current dvui window).
fn childWindows(editor: *Editor, g: *GuiState) void {
    if (comptime dvui.Backend.support_child_os_wins) {
        const c = dvui.backend.c;
        var i: usize = 1;
        while (i < editor.windows.items.len) : (i += 1) {
            const ew = editor.windows.items[i];
            const ui = g.winUi(ew.id) catch continue;
            if (!ui.created) {
                // dvui destroys a retired child one frame after it stops
                // being drawn; creating the replacement in that frame would
                // trip the backend's SDL window-count guard (process exit
                // past 5 windows). Wait a frame.
                var n: c_int = 0;
                const arr = c.SDL_GetWindows(&n);
                if (arr != null) c.SDL_free(@ptrCast(arr));
                if (n >= 5) continue;
            }
            var tbuf: [256]u8 = undefined;
            const title_z = editor.windowTitle(i, &tbuf);
            const os_win = dvui.osWindow(@src(), .{
                .title = title_z,
                .size = .{ .w = 900, .h = 600 },
                .min_size = .{ .w = 400, .h = 300 },
                .hidden = true,
            }, .{ .id_extra = ew.id, .open_flag = &ew.open });
            // Always ends the child frame — never `return` inside this block.
            defer os_win.deinit();
            const child_dvui = os_win.inner.dvui_win;
            const child_backend = os_win.inner.backend;
            win_ui = ui;
            cur_win = i;
            if (!ui.created) {
                // The child copied the parent's theme before it had the mono
                // font: register the font and re-theme before any widget.
                applyChildWindowFonts(child_dvui, g, editor);
                ui.theme_gen_applied = editor.theme_revision;
                ui.sdl_window_id = c.SDL_GetWindowID(child_backend.window);
                // Every child presents on its own; vsync per child would
                // divide the frame rate by the window count.
                _ = c.SDL_SetRenderVSync(child_backend.renderer, 0);
                positionNewWindow(editor, g, i, child_backend.window);
                ew.spawn_pos = null;
                _ = c.SDL_ShowWindow(child_backend.window);
                _ = c.SDL_RaiseWindow(child_backend.window);
                ui.created = true;
                ui.title_hash = std.hash.Wyhash.hash(0, title_z);
            } else {
                const th = std.hash.Wyhash.hash(0, title_z);
                if (th != ui.title_hash) {
                    ui.title_hash = th;
                    _ = c.SDL_SetWindowTitle(child_backend.window, title_z.ptr);
                }
            }
            applyThemeIfStale(editor);

            dispatchGlobalKeys(editor);
            processFileDrops(editor);
            if (editor.secondary_window_chrome) menuBar(editor);
            modalDialogs(editor);
            if (editor.secondary_window_chrome) {
                tabBar(editor);
                statusBar(editor);
            }
            editorArea(editor, false);
        }
        // Back to the primary context for whatever runs after the windows.
        win_ui = g.primary();
        cur_win = 0;
    }
}

/// Recursively render the layout tree. Split nodes use dvui.paned() for
/// draggable dividers; leaf nodes render an editor pane.
fn renderLayout(editor: *Editor, node_idx: u8) void {
    if (!build_options.has_gui) return;
    if (node_idx >= winLayout(editor, cur_win).nodes.items.len) return;

    switch (winLayout(editor, cur_win).nodes.items[node_idx]) {
        .leaf => |pane_id| {
            if (pane_id < winLayout(editor, cur_win).panes.items.len) {
                const pane = winLayout(editor, cur_win).panes.items[pane_id];
                switch (pane.content) {
                    .editor => editorPane(editor, pane_id),
                    .terminal => |term_idx| terminalPane(editor, pane_id, term_idx),
                }
            }
        },
        .split => |s| {
            var paned = dvui.paned(@src(), .{
                .direction = if (s.direction == .horizontal) .horizontal else .vertical,
                .collapsed_size = 100,
                .split_ratio = winLayout(editor, cur_win).ratioPtr(node_idx),
                .handle_size = 4,
                .handle_dynamic = .{
                    .handle_size_max = 8,
                    .distance_max = 16,
                },
            }, .{
                .expand = .both,
                .id_extra = node_idx,
            });
            defer paned.deinit();

            if (paned.showFirst()) {
                renderLayout(editor, s.first);
            }
            if (paned.showSecond()) {
                renderLayout(editor, s.second);
            }
        },
    }
}

// ===========================================================================
// File tree side panel
// ===========================================================================

/// GUI scroll offset (in rows) for the file tree panel.
var filetree_scroll: usize = 0;

/// One-frame flag: the keyboard just came back to an editor pane (from the
/// tree, the search panel, another pane or window — trackKeyboardOwner, or
/// the tree's own Escape/Enter, the Snippets panel's Escape and inserts),
/// so the active editor pane takes dvui focus back: its movement/typing
/// handlers are gated on holding dvui widget focus, which a panel grabbed
/// on click. Without this, Escape "worked" but the editor stayed deaf.
var filetree_release_focus: bool = false;
/// A docked side band's edge-drag resize: its content rect + scale from
/// the last draw — the drag runs at the top of frame() (before any pane
/// consumes events), so it works the same whichever side the band docks
/// on — and whether its editor-facing edge is being dragged.
const BandResize = struct {
    rect: ?dvui.Rect.Physical = null,
    scale: f32 = 1,
    resizing: bool = false,
    /// The width the drag started from: put back when the drag ends by
    /// hiding the band, so it comes back at its old width.
    start_width: f32 = 0,
    /// The pointer is past the hide threshold: the release hides the band.
    hide_pending: bool = false,

    /// No band this frame: nothing to grab, and a drag in flight ends.
    fn reset(self: *BandResize) void {
        self.rect = null;
        self.resizing = false;
        self.hide_pending = false;
    }
};
/// The file tree's band (its rect also targets OS file drops).
var filetree_band: BandResize = .{};
/// Double-click state for tree rows: single click on a row NAME only
/// selects; a second click on the same row within the threshold toggles
/// a folder or opens a file. (The +/- glyph stays single-click.)
const filetree_double_click_ms: i128 = 400;
var filetree_last_click_ns: i128 = 0;
var filetree_last_click_row: usize = std.math.maxInt(usize);
/// Drag & drop move state: a press on a row name arms it, motion past
/// ~5px engages, release over a folder (or the header/empty space =
/// root) moves the entry there.
const FiletreeDndTarget = union(enum) { none, root, row: usize };
var filetree_dnd_armed: bool = false;
var filetree_dnd_active: bool = false;
var filetree_dnd_press: dvui.Point.Physical = .{};
var filetree_dnd_src_row: usize = 0;
var filetree_dnd_target: FiletreeDndTarget = .none;
/// Selection snapshot taken when the drag arms — the drag carries this
/// cargo even if the live selection changes (or a background refresh
/// clears the multi set) before the drop lands.
var filetree_dnd_paths: ?[][]u8 = null;

fn filetreeDndFreePaths(editor: *Editor) void {
    if (filetree_dnd_paths) |paths| {
        for (paths) |p| editor.allocator.free(p);
        editor.allocator.free(paths);
        filetree_dnd_paths = null;
    }
}

/// Arm a row drag and snapshot what it will move.
fn filetreeDndArm(editor: *Editor, ft: *FileTree, p: dvui.Point.Physical, r: usize) void {
    filetree_dnd_armed = true;
    filetree_dnd_active = false;
    filetree_dnd_press = p;
    filetree_dnd_src_row = r;
    filetreeDndFreePaths(editor);
    filetree_dnd_paths = ft.selectionRelPaths(editor.allocator) catch null;
}
/// Last external-change mtime probe (see the poll in frame()).
var filetree_poll_ns: i128 = 0;
/// Last open-document external-change probe (see the poll in frame()).
var doc_poll_ns: i128 = 0;
/// Row under the mouse cursor (hover highlight); null when the pointer
/// is outside the panel or a drag is in flight.
var filetree_hover_row: ?usize = null;
/// Scrollbar state: thumb drag with the grab offset inside the thumb,
/// plus hover over the scrollbar band for the wider/brighter thumb.
var filetree_sb_drag: bool = false;
var filetree_sb_grab_dy: f32 = 0;
var filetree_sb_hover: bool = false;
/// `/` search state: incremental case-insensitive substring jump over
/// the visible rows (letters are taken by the j/k/a/r/d/x/p bindings,
/// so type-ahead needs the vim-style `/` prefix).
var filetree_search_active: bool = false;
var filetree_search_buf: [64]u8 = undefined;
var filetree_search_len: usize = 0;
var filetree_search_miss: bool = false;
/// Header icon-button hover: 0 = none, 1 = new file, 2 = collapse all.
var filetree_hdr_hover: u8 = 0;
/// Hash of the file path last auto-revealed (0 = none) — auto-reveal
/// fires once per active-document change, not per frame.
var filetree_autoreveal_last: u64 = 0;
/// Row band geometry from the last panel frame — lets OS-drop targeting
/// map a drop point to a row without re-deriving the layout.
var filetree_rows_geom: ?struct { rows_y: f32, line_height: f32 } = null;

/// Registered as the SDL backend's drop_file_fn (main.zig, GUI startup).
/// Runs synchronously during event pumping — stash into the state of the
/// window the drop landed on (unknown window → primary) and return; the
/// slots are consumed once per frame by processFileDrops.
pub fn onSdlDropFile(path: []const u8, x: f32, y: f32, window_id: u32) void {
    const st = active_state orelse return;
    const ui = st.bySdlWindow(window_id) orelse st.primary();
    if (ui.drop_count >= ui.drop_slots.len) return;
    if (path.len == 0 or path.len > ui.drop_slots[0].path.len) return;
    const s = &ui.drop_slots[ui.drop_count];
    @memcpy(s.path[0..path.len], path);
    s.len = path.len;
    s.x = x;
    s.y = y;
    ui.drop_count += 1;
}

/// Consume the current window's staged OS file drops: dropped on the tree
/// panel (primary window only) = import into the folder under the cursor;
/// dropped on the editor = open the file in that window (or re-root the
/// tree when a folder was dropped).
fn processFileDrops(editor: *Editor) void {
    if (!build_options.has_gui) return;
    if (win_ui.drop_count == 0) return;
    defer win_ui.drop_count = 0;
    const scale = windowPointScale();
    for (win_ui.drop_slots[0..win_ui.drop_count]) |*s| {
        const path = s.path[0..s.len];
        var handled = false;
        if (cur_win == 0 and editor.filetree_visible) {
            if (filetree_band.rect) |pr| {
                const px = s.x * scale;
                const py = s.y * scale;
                if (px >= pr.x and px <= pr.x + pr.w and py >= pr.y and py <= pr.y + pr.h) {
                    if (editor.filetree) |*ft| {
                        const dest_idx: u32 = blk: {
                            const g = filetree_rows_geom orelse break :blk 0;
                            const row = filetreeRowAt(ft, g.rows_y, g.line_height, py) orelse break :blk 0;
                            const node_idx = ft.visible.items[row];
                            break :blk if (ft.nodes.items[node_idx].kind == .dir) node_idx else ft.nodes.items[node_idx].parent;
                        };
                        editor.filetreeImportAbs(path, dest_idx);
                        handled = true;
                    }
                }
            }
        }
        if (!handled) {
            // Dropped on the editor: folders become the tree root, files
            // open as tabs in the window they were dropped on (with the
            // usual binary-file guard).
            editor.focusWindow(cur_win);
            if (std.Io.Dir.openDirAbsolute(editor.io, path, .{})) |d| {
                d.close(editor.io);
                _ = editor.setFiletreeRoot(path);
            } else |_| {
                _ = editor.navOpen(path) catch |err| {
                    if (err == error.BinaryFile) {
                        guiNotify(editor, "Not opened: binary or unsupported text encoding", .{});
                    } else {
                        guiNotify(editor, "Open failed: {s}", .{@errorName(err)});
                    }
                };
            }
        }
    }
}

/// Physical pixels per SDL window coordinate in the current window: the
/// factor the SDL backend maps mouse events with (pixel size / window
/// size), which drop coordinates need too. Not rs.s, which also folds in
/// the display's content scale (at 125%/150% a drop landed on the wrong
/// tree row, or missed the panel and opened a folder as the root).
fn windowPointScale() f32 {
    const b = dvui.currentWindow().backend;
    const w = b.windowSize().w;
    return if (w > 0) b.pixelSize().w / w else 1.0;
}

/// File tree side panel — custom row rendering in the editorPane style
/// (no per-row widgets; we own scrolling, selection, and input). Renders
/// the core model's flattened visible list, which the TUI draws identically.
fn filetreePanel(editor: *Editor) void {
    if (!build_options.has_gui) return;
    const ft = if (editor.filetree) |*f| f else return;

    // Auto-reveal: when the document shown in this (the main) window
    // changes (tab click, Ctrl+Tab, open), select it in the tree — without
    // stealing keyboard focus. Not the focused window's document: a focus
    // change to another window would jump the tree under the pointer.
    if (editor.filetree_auto_reveal) {
        const doc = &editor.documents.items[editor.windowDocIdx(cur_win)];
        if (doc.file_path) |p| {
            const h = std.hash.Fnv1a_64.hash(p);
            if (h != filetree_autoreveal_last) {
                filetree_autoreveal_last = h;
                _ = editor.filetreeRevealPath(p);
            }
        } else {
            filetree_autoreveal_last = 0;
        }
    }
    // The `/` search only lives while the tree owns the keyboard.
    if (editor.keyboardOwner() != .filetree) filetree_search_active = false;

    const panel_w = std.math.clamp(editor.filetree_width, 120, 600);
    var pbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
        .min_size_content = .{ .w = panel_w },
        .background = true,
        .style = .window,
        .name = "filetree_panel",
    });
    defer pbox.deinit();

    const wd = pbox.data();
    const rs = wd.contentRectScale();
    const scale = rs.s;
    const area = rs.r;
    filetree_band.rect = area;
    filetree_band.scale = scale;

    var font = dvui.Font.theme(.body);
    if (editor.filetree_font_size > 0) font = font.withSize(editor.filetree_font_size);
    const line_height = font.lineHeight() * scale;
    if (line_height <= 0 or area.h <= 0 or area.w <= 0) return;

    // Column geometry shared by the painter and the mouse handler.
    const m = filetreeMetrics(area, scale, line_height);
    const header_h = m.rows_y - area.y;
    const visible_rows = m.visible_rows;

    // Input first — clicks/keys can expand or collapse rows, so every
    // count and clamp below must see the post-input state (a stale
    // row_count here was an index-out-of-bounds panic on collapse).
    handleFiletreeMouse(editor, ft, wd, m);
    if (treeTakesKeys(editor)) handleFiletreeKeys(editor, ft, wd, visible_rows);
    // SDL only delivers .text events while someone declares a text-input
    // region, and the editor pane only does that for itself — without
    // this, `/` search never receives its query characters. Declared
    // after the input: a click may just have given the tree the keyboard.
    if (treeTakesKeys(editor)) dvui.wantTextInput(area.toNatural());
    const tree_focused = editor.keyboardOwner() == .filetree;

    // Reveal/create/nav flagged the selection for scroll-into-view.
    if (ft.scroll_to_selected) {
        ft.scroll_to_selected = false;
        filetreeEnsureSelectedVisible(ft, visible_rows);
    }
    // Clamp scroll when rows disappeared (collapse/refresh).
    const row_count = ft.visible.items.len;
    if (filetree_scroll > 0 and filetree_scroll + visible_rows > row_count) {
        filetree_scroll = row_count -| visible_rows;
    }

    // Inline create/rename entry target (delete confirm is a dialog).
    // Rename draws over the entry's own row; create inserts a pseudo-row
    // right below its parent directory.
    var inline_rename_row: ?usize = null;
    var inline_rename_icon: fileicons.FileIcon = .{ .kind = .generic, .color = null };
    var inline_create_slot: ?usize = null;
    var inline_depth: u16 = 1;
    if (filetreeInlineTarget(editor, ft)) |it| {
        inline_rename_row = it.rename_row;
        inline_create_slot = it.create_slot;
        inline_depth = it.depth;
        inline_rename_icon = it.icon;
        // Keep the entry on-screen while typing.
        if (it.create_slot orelse it.rename_row) |slot| {
            if (slot < filetree_scroll) {
                filetree_scroll = slot;
            } else if (visible_rows > 0 and slot >= filetree_scroll + visible_rows) {
                filetree_scroll = slot - visible_rows + 1;
            }
        }
    }
    // Frame geometry for OS-drop targeting (consumed by processFileDrops).
    filetree_rows_geom = .{ .rows_y = m.rows_y, .line_height = line_height };

    // --- Header: clickable ^ up-button + root path, truncated from the
    // left so the tail (the part you care about) stays readable ---
    const header_fg = toDvui(editor.theme.overlay_fg);
    const dim = toDvui(editor.theme.overlay_dim);
    fillBar(area, 0, header_h, toDvui(editor.theme.gutter_bg));
    // Root is the operation target (empty-space click) — mark the header.
    if (ft.root_selected) {
        fillBar(area, 0, header_h, toDvui(editor.theme.selection).opacity(0.35));
    }
    if (filetree_dnd_active) {
        switch (filetree_dnd_target) {
            .root => fillBar(area, 0, header_h, toDvui(editor.theme.overlay_selection)),
            else => {},
        }
    }
    const hdr_color = if (tree_focused) header_fg else dim;
    const up_sz = @min(header_h - 4 * scale, 13 * scale);
    renderIconTinted("ft_up", icons.tvg(.arrow_up) orelse dvui.entypo.level_up, .{
        .x = area.x + 6 * scale,
        .y = area.y + (header_h - up_sz) / 2,
        .w = up_sz,
        .h = up_sz,
    }, scale, hdr_color);
    // Right-aligned header buttons: new file, collapse all.
    const btn_y = area.y + (header_h - m.hdr_btn_sz) / 2;
    const b1_color = if (filetree_hdr_hover == 1) header_fg else dim;
    const b2_color = if (filetree_hdr_hover == 2) header_fg else dim;
    renderIconTinted("ft_new", icons.tvg(.new_file) orelse dvui.entypo.plus, .{
        .x = m.hdr_btn1_x,
        .y = btn_y,
        .w = m.hdr_btn_sz,
        .h = m.hdr_btn_sz,
    }, scale, b1_color);
    renderIconTinted("ft_collapse", icons.tvg(.collapse_all) orelse dvui.entypo.squared_minus, .{
        .x = m.hdr_btn2_x,
        .y = btn_y,
        .w = m.hdr_btn_sz,
        .h = m.hdr_btn_sz,
    }, scale, b2_color);

    const char_w = font.textSize("M").w * scale;
    const path_x = area.x + m.up_btn_w;
    const avail_px = m.hdr_btn1_x - path_x - 6 * scale;
    if (filetree_search_active) {
        // `/` search replaces the path while typing; warn color on no match.
        var sbuf: [96]u8 = undefined;
        const stxt = std.fmt.bufPrint(&sbuf, "/{s}_", .{filetree_search_buf[0..filetree_search_len]}) catch "/_";
        const scolor = if (filetree_search_miss) toDvui(editor.theme.overlay_warn) else hdr_color;
        const prev_clip = dvui.clip(.{ .x = path_x, .y = area.y, .w = @max(0, avail_px), .h = header_h });
        renderOverlayText(font, stxt, path_x, area.y + 2 * scale, rs, scolor);
        dvui.clipSet(prev_clip);
    } else {
        const budget: usize = if (char_w > 0 and avail_px > char_w) @intFromFloat(@floor(avail_px / char_w)) else 0;
        const tail = filetree_mod.pathTail(ft.root_path, budget);
        if (tail.len == ft.root_path.len) {
            renderOverlayText(font, tail, path_x, area.y + 2 * scale, rs, hdr_color);
        } else {
            var hdr_buf: [600]u8 = undefined;
            const short = filetree_mod.pathTail(ft.root_path, budget -| 3);
            const txt = std.fmt.bufPrint(&hdr_buf, "...{s}", .{short}) catch short;
            renderOverlayText(font, txt, path_x, area.y + 2 * scale, rs, hdr_color);
        }
    }

    // --- Rows ---
    const text_color = toDvui(editor.theme.text);
    const sel_bg = toDvui(editor.theme.selection);
    const guide_color = toDvui(editor.theme.panel_border);
    // Type icons render as text from the mono font (bundled Fira Code
    // Nerd Font — the devicon glyphs are guaranteed present), sized by
    // filetree_icon_scale relative to the row text, evened out per glyph
    // family (iconFamilyScale), and re-centered vertically.
    const icon_font = dvui.Font.theme(.mono).withSize(font.size * filetreeIconScale(editor));
    var row = filetree_scroll;
    var y = m.rows_y;
    while (row < row_count and y + line_height <= area.y + area.h + 0.5) : (row += 1) {
        const idx = ft.visible.items[row];
        const node = ft.nodes.items[idx];
        // Inline create entry: a pseudo-row that pushes later rows down.
        if (inline_create_slot) |slot| {
            if (slot == row) {
                filetreeDrawInlineEntry(editor, m, rs, font, y, inline_depth, null);
                y += line_height;
                if (y + line_height > area.y + area.h + 0.5) break;
            }
        }
        // Inline rename: the entry's own row becomes the input box.
        if (inline_rename_row) |rr| {
            if (rr == row) {
                filetreeDrawInlineEntry(editor, m, rs, font, y, inline_depth, inline_rename_icon);
                y += line_height;
                continue;
            }
        }
        if (!filetree_dnd_active) {
            if (filetree_hover_row) |hr| {
                if (hr == row and row != ft.selected) {
                    fillBar(area, y - area.y, line_height, sel_bg.opacity(0.3));
                }
            }
        }
        if (row != ft.selected and ft.isMultiSelected(idx)) {
            fillBar(area, y - area.y, line_height, sel_bg.opacity(0.55));
        }
        if (row == ft.selected) {
            // Dimmed bar when the tree doesn't own the keyboard.
            const bar = if (tree_focused) sel_bg else sel_bg.opacity(0.45);
            fillBar(area, y - area.y, line_height, bar);
        }
        if (filetree_dnd_active) {
            switch (filetree_dnd_target) {
                .row => |tr| if (tr == row) fillBar(area, y - area.y, line_height, toDvui(editor.theme.overlay_selection)),
                else => {},
            }
        }
        const x = m.rowX(node.depth);
        // Indent guides: one vertical line per ancestor level, centered
        // under that level's chevron column, so deep nesting stays readable.
        var lvl: usize = 0;
        while (lvl < node.depth -| 1) : (lvl += 1) {
            const gx = area.x + m.pad_l + @as(f32, @floatFromInt(lvl)) * m.indent_w + m.chevron_w / 2;
            const guide: dvui.Rect.Physical = .{ .x = gx, .y = y, .w = @max(1.0, 1 * scale), .h = line_height };
            guide.fill(.{}, .{ .color = guide_color, .fade = 1.0 });
        }
        const icon_y = y + (line_height - m.icon_size) / 2;
        if (node.kind == .dir) {
            const chev: []const u8 = if (node.expanded) (icons.tvg(.chevron_down) orelse dvui.entypo.chevron_small_down) else (icons.tvg(.chevron_right) orelse dvui.entypo.chevron_small_right);
            const chev_name: []const u8 = if (node.expanded) "ft_chev_open" else "ft_chev";
            renderIconTinted(chev_name, chev, .{
                .x = x + (m.chevron_w - m.icon_size) / 2,
                .y = icon_y,
                .w = m.icon_size,
                .h = m.icon_size,
            }, scale, dim);
        }
        // Entries sitting in the cut clipboard render dimmed.
        const in_cut = editor.filetree_clip_cut and editor.filetreeClipContains(node.rel_path);
        // Type icon: nerdfont glyphs (per-language logos where they
        // exist) rendered as text from the bundled mono Nerd Font, in
        // fixed accent colors plus zide.set_icon overrides.
        const fi = editor.filetreeIconFor(node.name, node.kind == .dir);
        var tint: dvui.Color = if (fi.color) |c|
            .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 }
        else
            text_color.opacity(0.75);
        if (in_cut) tint = tint.opacity(0.45);
        const icon_glyph = fi.nerd orelse fileicons.nerdGlyph(fi.kind);
        const glyph_font = icon_font.withSize(icon_font.size * iconFamilyScale(icon_glyph));
        const glyph_dy = (line_height - glyph_font.lineHeight() * scale) / 2;
        renderOverlayText(glyph_font, icon_glyph, x + m.chevron_w, y + glyph_dy, rs, tint);
        // Git status drives the name color (dirs roll up contained changes)
        const status = ft.statusFor(idx);
        var row_color = if (status) |st| toDvui(switch (st) {
            .added => editor.theme.git_added,
            .modified => editor.theme.git_modified,
            .deleted => editor.theme.git_deleted,
            .untracked => editor.theme.git_untracked,
        }) else text_color;
        if (in_cut) row_color = row_color.opacity(0.45);
        // Badge column: status letter for files, a dot for dirty dirs.
        var badge_left = m.badge_right;
        if (status) |st| {
            const badge: []const u8 = if (node.kind == .dir) "\u{2022}" else switch (st) {
                .added => "A",
                .modified => "M",
                .deleted => "D",
                .untracked => "U",
            };
            const bw = font.textSize(badge).w * scale;
            badge_left = m.badge_right - bw;
            renderOverlayText(font, badge, badge_left, y, rs, row_color);
        }
        // Name, clipped so long names never run under the badge or bar.
        const name_x = x + m.chevron_w + m.icon_w;
        const clip_w = @max(0, badge_left - 4 * scale - area.x);
        const prev_clip = dvui.clip(.{ .x = area.x, .y = y, .w = clip_w, .h = line_height });
        renderOverlayText(font, node.name, name_x, y, rs, row_color);
        dvui.clipSet(prev_clip);
        y += line_height;
    }

    // Inline create entry appended past the last row (or in an empty tree).
    if (inline_create_slot) |slot| {
        if (slot >= row_count and row >= row_count and y + line_height <= area.y + area.h + 0.5) {
            filetreeDrawInlineEntry(editor, m, rs, font, y, inline_depth, null);
        }
    }

    // --- Scrollbar: slim pill over the right edge of the rows ---
    if (filetreeSbThumb(ft, m)) |thumb| {
        const active = filetree_sb_drag or filetree_sb_hover;
        const sb_color = if (active) header_fg.opacity(0.6) else dim.opacity(0.45);
        const rad = thumb.w / 2;
        thumb.fill(.{ .x = rad, .y = rad, .w = rad, .h = rad }, .{ .color = sb_color, .fade = 1.0 });
    }

    // Separator line on the editor-facing edge — without it the panel
    // blends straight into the line-number gutter.
    const sep_w = @max(1.0, 1 * scale);
    const sep_x = if (editor.filetree_side == .left) area.x + area.w - sep_w else area.x;
    const sep_rect: dvui.Rect.Physical = .{ .x = sep_x, .y = area.y, .w = sep_w, .h = area.h };
    sep_rect.fill(.{}, .{ .color = toDvui(editor.theme.panel_border), .fade = 1.0 });

    // Right-click context menu over the panel.
    filetreeContextMenu(editor, area);
}

/// Drag a side band's editor-facing edge to resize it, VS Code style:
/// `width` (logical px) follows the pointer within `min`..`max`, and the
/// chosen width persists to init.lua under `setting` on release. Dragged
/// well past the minimum (under half of it) the band stays at its
/// minimum until the release, which hides it instead: the width goes
/// back to what the drag started from, nothing is persisted, and the
/// call returns true so the caller hides its band and says so. Runs
/// from frame() with the previous frame's rect so it always sees events
/// before the panes.
fn handleBandResize(band: *BandResize, side: Editor.FiletreeSide, width: *f32, min: f32, max: f32, setting: []const u8) bool {
    return handleBandResizeAt(band, if (side == .left) .left else .right, width, min, max, setting);
}

/// handleBandResize for a band docked at any edge: `size` is the width of
/// a left/right band (its editor-facing edge is vertical) or the height of
/// a bottom band (its top edge).
fn handleBandResizeAt(band: *BandResize, edge: Editor.DockEdge, size: *f32, min: f32, max: f32, setting: []const u8) bool {
    if (!build_options.has_gui) return false;
    const prect = band.rect orelse return false;
    const scale = band.scale;
    if (scale <= 0) return false;
    const grab: f32 = 4 * scale;
    var hide = false;

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        // Same subwindow rule as handleFiletreeMouse: a press on a
        // floating window overlapping the edge band must not grab it.
        if (me.floating_win != dvui.subwindowCurrentId()) continue;
        const near_edge = switch (edge) {
            .left, .right => blk: {
                const edge_x = if (edge == .left) prect.x + prect.w else prect.x;
                break :blk me.p.x >= edge_x - grab and me.p.x <= edge_x + grab and
                    me.p.y >= prect.y and me.p.y <= prect.y + prect.h;
            },
            .bottom => me.p.y >= prect.y - grab and me.p.y <= prect.y + grab and
                me.p.x >= prect.x and me.p.x <= prect.x + prect.w,
        };

        switch (me.action) {
            .position => {
                if (near_edge or band.resizing) dvui.cursorSet(if (edge == .bottom) .arrow_n_s else .arrow_w_e);
            },
            .press => {
                if (me.button == .left and near_edge) {
                    e.handled = true;
                    band.resizing = true;
                    band.start_width = size.*;
                    band.hide_pending = false;
                }
            },
            .motion => {
                if (band.resizing) {
                    e.handled = true;
                    const phys = switch (edge) {
                        .left => me.p.x - prect.x,
                        .right => (prect.x + prect.w) - me.p.x,
                        .bottom => (prect.y + prect.h) - me.p.y,
                    };
                    const s = phys / scale;
                    band.hide_pending = s < min / 2;
                    size.* = std.math.clamp(s, min, max);
                }
            },
            .release => {
                if (band.resizing) {
                    e.handled = true;
                    band.resizing = false;
                    if (band.hide_pending) {
                        band.hide_pending = false;
                        size.* = band.start_width;
                        hide = true;
                        continue;
                    }
                    // Persist the chosen size
                    var buf: [32]u8 = undefined;
                    const num = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(size.*))}) catch "";
                    if (num.len > 0) lua_settings.writeSettingToFile(setting, num) catch {};
                }
            },
            else => {},
        }
    }
    return hide;
}

/// While a band is dragged: `hint` in the status bar past the hide
/// threshold, and cleared again back inside it — only the hint, so a
/// message that came up during the drag (a panel that ran out of room)
/// stays.
fn bandDragHint(editor: *Editor, past_threshold: bool, hint: []const u8) void {
    if (past_threshold) {
        editor.status_message = hint;
    } else if (std.mem.eql(u8, editor.status_message, hint)) {
        editor.status_message = "";
    }
}

/// Keep the tree selection inside the visible row window.
fn filetreeEnsureSelectedVisible(ft: *FileTree, visible_rows: usize) void {
    if (ft.selected < filetree_scroll) {
        filetree_scroll = ft.selected;
    } else if (visible_rows > 0 and ft.selected >= filetree_scroll + visible_rows) {
        filetree_scroll = ft.selected - visible_rows + 1;
    }
}

/// Resolve the drop target under the cursor while drag-moving: a row,
/// the root (header or empty space below the rows), or none outside.
fn filetreeDropTarget(ft: *const FileTree, area: dvui.Rect.Physical, rows_y: f32, line_height: f32, p: dvui.Point.Physical) FiletreeDndTarget {
    if (p.x < area.x or p.x > area.x + area.w or
        p.y < area.y or p.y > area.y + area.h) return .none;
    if (p.y < rows_y) return .root; // header
    if (filetreeRowAt(ft, rows_y, line_height, p.y)) |r| return .{ .row = r };
    return .root; // empty space below the rows
}

/// Visible row index under a physical y position, or null.
fn filetreeRowAt(ft: *const FileTree, rows_y: f32, line_height: f32, my: f32) ?usize {
    if (my < rows_y or line_height <= 0) return null;
    const rel: usize = @intFromFloat(@floor((my - rows_y) / line_height));
    const row = filetree_scroll + rel;
    if (row >= ft.visible.items.len) return null;
    return row;
}

/// Per-frame file tree layout metrics (physical px) — one place for the
/// column geometry so the painter and the mouse handler can't drift.
const FiletreeMetrics = struct {
    area: dvui.Rect.Physical,
    scale: f32,
    line_height: f32,
    rows_y: f32,
    rows_h: f32,
    visible_rows: usize,
    /// Left padding before depth-1 content.
    pad_l: f32,
    /// Horizontal shift per depth level.
    indent_w: f32,
    /// Expander column, reserved on every row so icons align.
    chevron_w: f32,
    /// Square edge of chevron/type icons.
    icon_size: f32,
    /// Icon column width incl. the gap before the name.
    icon_w: f32,
    /// Header up-button click zone, measured from area.x.
    up_btn_w: f32,
    /// Header icon buttons (new file, collapse all), right-aligned.
    hdr_btn_sz: f32,
    hdr_btn1_x: f32,
    hdr_btn2_x: f32,
    /// Scrollbar band (left edge + width) over the rows' right edge.
    sb_x: f32,
    sb_w: f32,
    /// Right x where git badges end.
    badge_right: f32,

    /// Left x of a row's chevron column at `depth`.
    fn rowX(m: FiletreeMetrics, depth: u16) f32 {
        return m.area.x + m.pad_l + @as(f32, @floatFromInt(depth -| 1)) * m.indent_w;
    }
};

fn filetreeMetrics(area: dvui.Rect.Physical, scale: f32, line_height: f32) FiletreeMetrics {
    const header_h = line_height + 4 * scale;
    const rows_h = area.h - header_h;
    const icon_size = @round(line_height * 0.72);
    const sb_w = 6 * scale;
    const sb_x = area.x + area.w - sb_w - 1 * scale;
    const hdr_btn_sz = @min(header_h - 4 * scale, 14 * scale);
    const hdr_btn2_x = area.x + area.w - sb_w - hdr_btn_sz - 4 * scale;
    return .{
        .hdr_btn_sz = hdr_btn_sz,
        .hdr_btn1_x = hdr_btn2_x - hdr_btn_sz - 6 * scale,
        .hdr_btn2_x = hdr_btn2_x,
        .area = area,
        .scale = scale,
        .line_height = line_height,
        .rows_y = area.y + header_h,
        .rows_h = rows_h,
        .visible_rows = if (rows_h > line_height) @intFromFloat(@floor(rows_h / line_height)) else 1,
        .pad_l = 6 * scale,
        .indent_w = 12 * scale,
        .chevron_w = 14 * scale,
        .icon_size = icon_size,
        .icon_w = icon_size + 5 * scale,
        .up_btn_w = 22 * scale,
        .sb_x = sb_x,
        .sb_w = sb_w,
        .badge_right = sb_x - 2 * scale,
    };
}

/// Scrollbar thumb rect, or null when every row fits.
fn filetreeSbThumb(ft: *const FileTree, m: FiletreeMetrics) ?dvui.Rect.Physical {
    const count = ft.visible.items.len;
    if (count <= m.visible_rows or m.rows_h <= 0) return null;
    const count_f: f32 = @floatFromInt(count);
    const vis_f: f32 = @floatFromInt(m.visible_rows);
    const thumb_h = @min(m.rows_h, @max(20 * m.scale, m.rows_h * vis_f / count_f));
    const denom: f32 = @floatFromInt(count - m.visible_rows);
    const frac = @min(1.0, @as(f32, @floatFromInt(filetree_scroll)) / denom);
    return .{
        .x = m.sb_x + 1 * m.scale,
        .y = m.rows_y + (m.rows_h - thumb_h) * frac,
        .w = m.sb_w - 2 * m.scale,
        .h = thumb_h,
    };
}

/// Visible logical lines in an editor pane rect (minimum 1).
fn editorSbVisLines(area: dvui.Rect.Physical, line_height: f32) usize {
    if (line_height <= 0 or area.h <= line_height) return 1;
    return @intFromFloat(@floor(area.h / line_height));
}

/// The largest scroll_top that still fills the view, i.e. where the thumb's
/// travel ends. With word wrap the last lines take more rows than lines, so
/// the logical-line answer (`lineCount - vis`) left the bottom rows cut off
/// and unreachable by the thumb: walk back from the end counting wrapped
/// rows until the view is full. `text_area_w_logical` is in unscaled font
/// units, as `guiWrapLineRows` expects.
fn editorMaxScrollTop(doc: *Document, font: dvui.Font, text_area_w_logical: f32, vis: usize, tab_width: usize, do_wrap: bool) usize {
    const total = doc.buffer.lineCount();
    if (!do_wrap) return total -| vis;
    var rows: usize = 0;
    var top: usize = total;
    while (top > 0) {
        var eb: [16384]u8 = undefined;
        const shown = displayLine(doc.buffer.lineContent(top - 1), tab_width, &eb);
        const line_rows = guiWrapLineRows(shown, font, text_area_w_logical);
        if (rows + line_rows > vis) break;
        rows += line_rows;
        top -= 1;
    }
    return @min(top, total -| 1);
}

/// The review reader's soft row tint for a row kind, if it has one.
fn reviewRowTint(editor: *const Editor, kind: ?review_reader.LineKind) ?dvui.Color {
    const k = kind orelse return null;
    return switch (k) {
        .added => toDvui(editor.theme.review_added_bg),
        .modified => toDvui(editor.theme.review_modified_bg),
        .ghost => toDvui(editor.theme.review_ghost_bg),
        .marker, .context => null,
    };
}

/// The gutter number of a row: in the review reader the real file's line
/// (blank for ghost and marker rows), else the row's own.
fn gutterNumber(doc: *const Document, line_idx: usize, buf: []u8) []const u8 {
    if (doc.reader) |info| {
        if (line_idx >= info.real_line.len) return "";
        const real = info.real_line[line_idx] orelse return "";
        return std.fmt.bufPrint(buf, "{d}", .{real + 1}) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}", .{line_idx + 1}) catch "";
}

/// Editor-pane scrollbar thumb rect, or null when the whole buffer fits
/// (`max_top` from `editorMaxScrollTop` is 0). The thumb's length is the
/// logical-line approximation; its travel maps scroll_top onto 0..max_top.
/// Works off the rect's right edge, so the events' gutter-trimmed rect and
/// the render rect agree.
fn editorSbThumb(doc: *const Document, area: dvui.Rect.Physical, line_height: f32, scale: f32, max_top: usize) ?dvui.Rect.Physical {
    if (area.h <= 0 or line_height <= 0 or max_top == 0) return null;
    const vis = editorSbVisLines(area, line_height);
    const total_f: f32 = @floatFromInt(@max(doc.buffer.lineCount(), vis + max_top));
    const vis_f: f32 = @floatFromInt(vis);
    const thumb_h = @min(area.h, @max(20 * scale, area.h * vis_f / total_f));
    const denom: f32 = @floatFromInt(max_top);
    const frac = @min(1.0, @as(f32, @floatFromInt(doc.scroll_top)) / denom);
    const pill_w = 6 * scale;
    return .{
        .x = area.x + area.w - pill_w - 2 * scale,
        .y = area.y + (area.h - thumb_h) * frac,
        .w = pill_w,
        .h = thumb_h,
    };
}

/// filetree_icon_scale as a multiplier (the setting is a percentage).
fn filetreeIconScale(editor: *const Editor) f32 {
    return @as(f32, @floatFromInt(std.math.clamp(editor.filetree_icon_scale, 50, 200))) / 100.0;
}

/// Nerd Font sub-sets draw at visibly different sizes — Seti glyphs
/// (including the Zig zero) are small in the em square while Font
/// Awesome fills it. Per-family compensation so tree icons read evenly.
fn iconFamilyScale(glyph: []const u8) f32 {
    const len = std.unicode.utf8ByteSequenceLength(glyph[0]) catch return 1.0;
    if (glyph.len < len) return 1.0;
    const cp = std.unicode.utf8Decode(glyph[0..len]) catch return 1.0;
    return if (cp >= 0xE5FA and cp <= 0xE6B7)
        1.3 // seti-ui
    else if (cp >= 0xE700 and cp <= 0xE8FF)
        1.2 // devicons and extensions
    else if (cp >= 0xEA60 and cp <= 0xEBFF)
        1.15 // codicons
    else if (cp >= 0xF400 and cp <= 0xF533)
        1.1 // octicons
    else if (cp >= 0xF0001)
        1.15 // material design (supplementary plane)
    else
        1.0; // font awesome & friends
}

/// Paint a tinted TinyVG icon into a physical rect. dvui caches the
/// rasterized texture per (glyph, height, tint).
fn renderIconTinted(name: []const u8, tvg_bytes: []const u8, rect: dvui.Rect.Physical, scale: f32, color: dvui.Color) void {
    dvui.renderIcon(name, tvg_bytes, .{ .r = rect, .s = scale }, .{}, .{
        .fill_color = color,
        .stroke_color = color,
    }) catch {};
}

/// Jump the selection to the next visible row whose name contains the
/// `/` search query (case-insensitive), scanning forward from the current
/// selection and wrapping. Sets the miss flag for header feedback.
fn filetreeSearchJump(ft: *FileTree, visible_rows: usize) void {
    const q = filetree_search_buf[0..filetree_search_len];
    filetree_search_miss = false;
    if (q.len == 0) return;
    const n = ft.visible.items.len;
    if (n == 0) {
        filetree_search_miss = true;
        return;
    }
    const start = @min(ft.selected, n - 1);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = (start + i) % n;
        const name = ft.nodes.items[ft.visible.items[r]].name;
        if (std.ascii.indexOfIgnoreCase(name, q) != null) {
            ft.clearMulti();
            ft.root_selected = false;
            ft.selected = r;
            filetreeEnsureSelectedVisible(ft, visible_rows);
            return;
        }
    }
    filetree_search_miss = true;
}

/// Paint the inline create/rename entry row (mode == .filetree_prompt).
/// The prompt state machine — keys, text input, apply/cancel — is the
/// shared one; this is purely the in-panel rendering of `open_buf`.
/// `base_icon` fixes the icon (rename keeps the entry's own); null means
/// live-classify the typed name, flipping to a folder on a trailing '/'.
fn filetreeDrawInlineEntry(editor: *Editor, m: FiletreeMetrics, rs: dvui.RectScale, font: dvui.Font, y: f32, depth: u16, base_icon: ?fileicons.FileIcon) void {
    const scale = m.scale;
    const area = m.area;
    const input = editor.open_buf[0..editor.open_buf_len];
    fillBar(area, y - area.y, m.line_height, toDvui(editor.theme.overlay_bg));
    const fi = base_icon orelse blk: {
        const is_dir = input.len > 0 and (input[input.len - 1] == '/' or input[input.len - 1] == '\\');
        break :blk editor.filetreeIconFor(if (is_dir) "" else input, is_dir);
    };
    const text_color = toDvui(editor.theme.text);
    const tint: dvui.Color = if (fi.color) |c|
        .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 }
    else
        text_color.opacity(0.75);
    const x = m.rowX(depth);
    const icon_glyph = fi.nerd orelse fileicons.nerdGlyph(fi.kind);
    const icon_font = dvui.Font.theme(.mono)
        .withSize(font.size * filetreeIconScale(editor) * iconFamilyScale(icon_glyph));
    const icon_font_dy = (m.line_height - icon_font.lineHeight() * scale) / 2;
    renderOverlayText(icon_font, icon_glyph, x + m.chevron_w, y + icon_font_dy, rs, tint);
    // Input box: text and caret over an underline.
    const name_x = x + m.chevron_w + m.icon_w;
    const box_w = @max(0, m.badge_right - name_x);
    const fg = toDvui(editor.theme.overlay_fg);
    const line_w = @max(1.0, 1 * scale);
    const underline: dvui.Rect.Physical = .{ .x = name_x, .y = y + m.line_height - line_w, .w = box_w, .h = line_w };
    underline.fill(.{}, .{ .color = fg, .fade = 1.0 });
    const prev_clip = dvui.clip(.{ .x = name_x, .y = y, .w = box_w, .h = m.line_height });
    renderOverlayText(font, input, name_x, y, rs, text_color);
    dvui.clipSet(prev_clip);
    const tw = font.textSize(input).w * scale;
    const caret: dvui.Rect.Physical = .{
        .x = @min(name_x + tw + 1 * scale, m.badge_right - line_w),
        .y = y + 2 * scale,
        .w = line_w,
        .h = m.line_height - 4 * scale,
    };
    caret.fill(.{}, .{ .color = fg, .fade = 1.0 });
}

fn handleFiletreeMouse(editor: *Editor, ft: *FileTree, wd: *dvui.WidgetData, m: FiletreeMetrics) void {
    const area = m.area;
    const rows_y = m.rows_y;
    const line_height = m.line_height;
    const visible_rows = m.visible_rows;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;

        // Events over an open floating window (context menu, dialogs)
        // belong to it — dvui tags each mouse event with the topmost
        // subwindow under the pointer. Without this check the raw rect
        // tests below stole the context menu's clicks, so its items
        // never fired.
        if (me.floating_win != dvui.subwindowCurrentId()) continue;

        // Click-away: while an inline create/rename is open, any press
        // that isn't on the entry row cancels it (like Escape). The
        // press is consumed — a dismiss click shouldn't also select.
        if (me.action == .press and editor.mode == .filetree_prompt and
            editor.filetree_prompt_kind != .delete_confirm)
        {
            const on_entry = blk: {
                const it = filetreeInlineTarget(editor, ft) orelse break :blk false;
                const entry_row = it.rename_row orelse (it.create_slot orelse break :blk false);
                const rel_row: i64 = @as(i64, @intCast(entry_row)) - @as(i64, @intCast(filetree_scroll));
                const ey = rows_y + @as(f32, @floatFromInt(rel_row)) * line_height;
                break :blk me.p.x >= area.x and me.p.x <= area.x + area.w and
                    me.p.y >= ey and me.p.y < ey + line_height;
            };
            if (!on_entry) {
                e.handle(@src(), wd);
                editor.cancelFiletreePrompt();
            }
            continue;
        }

        // In-flight scrollbar-thumb drag: track motion/release even
        // outside the panel, like the drag-move below.
        if (filetree_sb_drag) {
            if (me.action == .motion) {
                e.handle(@src(), wd);
                if (filetreeSbThumb(ft, m)) |thumb| {
                    const usable = m.rows_h - thumb.h;
                    if (usable > 0) {
                        const frac = std.math.clamp((me.p.y - rows_y - filetree_sb_grab_dy) / usable, 0, 1);
                        const denom: f32 = @floatFromInt(ft.visible.items.len - visible_rows);
                        filetree_scroll = @intFromFloat(@round(frac * denom));
                    }
                }
                continue;
            }
            if (me.action == .release) {
                e.handle(@src(), wd);
                filetree_sb_drag = false;
                continue;
            }
        }

        // In-flight drag-move: track motion/release even outside the panel
        if (filetree_dnd_armed or filetree_dnd_active) {
            if (me.action == .motion) {
                if (!filetree_dnd_active) {
                    const dx = me.p.x - filetree_dnd_press.x;
                    const dy = me.p.y - filetree_dnd_press.y;
                    if (dx * dx + dy * dy > 25) { // ~5px threshold
                        filetree_dnd_active = true;
                        filetree_last_click_ns = 0; // a drag is not a click
                    }
                }
                if (filetree_dnd_active) {
                    e.handle(@src(), wd);
                    filetree_dnd_target = filetreeDropTarget(ft, area, rows_y, line_height, me.p);
                    dvui.cursorSet(.arrow_all);
                    if (filetree_dnd_src_row < ft.visible.items.len) {
                        const src_idx = ft.visible.items[filetree_dnd_src_row];
                        const src_name = ft.nodes.items[src_idx].name;
                        const tgt_name: []const u8 = switch (filetree_dnd_target) {
                            .none => "(no target)",
                            .root => std.fs.path.basename(ft.root_path),
                            .row => |tr| ft.nodes.items[ft.visible.items[tr]].name,
                        };
                        const drag_n: usize = if (filetree_dnd_paths) |p| p.len else 1;
                        // File names are arbitrary bytes: setStatusText
                        // makes them safe to draw.
                        var msg_buf: [600]u8 = undefined;
                        const msg = if (drag_n > 1)
                            std.fmt.bufPrint(&msg_buf, "Move {d} items -> {s}", .{ drag_n, tgt_name }) catch ""
                        else
                            std.fmt.bufPrint(&msg_buf, "Move {s} -> {s}", .{ src_name, tgt_name }) catch "";
                        lua_api.setStatusText(editor, "", msg);
                    }
                }
                continue;
            }
            if (me.action == .release) {
                defer {
                    filetree_dnd_armed = false;
                    filetree_dnd_active = false;
                    filetree_dnd_target = .none;
                    filetreeDndFreePaths(editor);
                }
                if (filetree_dnd_active) {
                    e.handle(@src(), wd);
                    editor.status_message = "";
                    if (filetree_dnd_src_row < ft.visible.items.len) {
                        const src_idx = ft.visible.items[filetree_dnd_src_row];
                        const dest_idx: ?u32 = switch (filetree_dnd_target) {
                            .none => null,
                            .root => 0,
                            .row => |tr| blk: {
                                if (tr >= ft.visible.items.len) break :blk null;
                                const tnode = ft.visible.items[tr];
                                break :blk if (ft.nodes.items[tnode].kind == .dir) tnode else ft.nodes.items[tnode].parent;
                            },
                        };
                        if (dest_idx) |di| {
                            // The press-time snapshot is what moves — the
                            // live set may have changed since the drag armed.
                            if (filetree_dnd_paths) |paths| {
                                if (paths.len > 1) {
                                    editor.filetreeMoveManyTo(paths, di);
                                } else if (paths.len == 1) {
                                    editor.filetreeMoveTo(paths[0], di);
                                }
                            } else {
                                editor.filetreeMoveTo(ft.nodes.items[src_idx].rel_path, di);
                            }
                        }
                    }
                }
                continue;
            }
        }

        const inside = me.p.x >= area.x and me.p.x <= area.x + area.w and
            me.p.y >= area.y and me.p.y <= area.y + area.h;
        if (me.action == .position) {
            // Hover feedback (row highlight + scrollbar brightening);
            // cleared whenever the pointer leaves the panel.
            filetree_sb_hover = inside and me.p.x >= m.sb_x and me.p.y >= rows_y;
            filetree_hover_row = if (inside and !filetree_sb_hover)
                filetreeRowAt(ft, rows_y, line_height, me.p.y)
            else
                null;
            filetree_hdr_hover = 0;
            if (inside and me.p.y < rows_y) {
                if (me.p.x >= m.hdr_btn1_x and me.p.x < m.hdr_btn1_x + m.hdr_btn_sz) {
                    filetree_hdr_hover = 1;
                } else if (me.p.x >= m.hdr_btn2_x and me.p.x < m.hdr_btn2_x + m.hdr_btn_sz) {
                    filetree_hdr_hover = 2;
                }
            }
            if (inside) dvui.cursorSet(.arrow);
            continue;
        }
        if (!inside) continue;

        switch (me.action) {
            .press => {
                editor.dismissStatus();
                filetree_search_active = false;
                const row = filetreeRowAt(ft, rows_y, line_height, me.p.y);
                if (me.button == .right) {
                    // Select the row under the cursor (keeping any multi
                    // selection that includes it) but leave the press
                    // unhandled — the panel's ContextWidget consumes it.
                    if (row) |r| {
                        if (!ft.isMultiSelected(ft.visible.items[r])) ft.clearMulti();
                        ft.root_selected = false;
                        ft.selected = r;
                    }
                    _ = editor.takeKeyboardFocus(.filetree);
                    continue;
                }
                e.handle(@src(), wd);
                dvui.focusWidget(wd.id, null, e.num);
                _ = editor.takeKeyboardFocus(.filetree);
                if (guiMode(editor) != .normal) continue;
                // Scrollbar band: drag the thumb, or page toward the click.
                if (me.p.y >= rows_y and me.p.x >= m.sb_x) {
                    if (filetreeSbThumb(ft, m)) |thumb| {
                        if (me.p.y >= thumb.y and me.p.y < thumb.y + thumb.h) {
                            filetree_sb_drag = true;
                            filetree_sb_grab_dy = me.p.y - thumb.y;
                        } else if (me.p.y < thumb.y) {
                            filetree_scroll = filetree_scroll -| visible_rows;
                        } else {
                            const max_top = ft.visible.items.len -| visible_rows;
                            filetree_scroll = @min(filetree_scroll + visible_rows, max_top);
                        }
                    }
                    continue;
                }
                if (me.p.y < rows_y) {
                    // Header: icon buttons on the right, up-button on the left
                    if (me.p.x >= m.hdr_btn1_x and me.p.x < m.hdr_btn1_x + m.hdr_btn_sz) {
                        editor.startFiletreePrompt(.create);
                    } else if (me.p.x >= m.hdr_btn2_x and me.p.x < m.hdr_btn2_x + m.hdr_btn_sz) {
                        _ = editor.execCommand("filetree_collapse_all", null);
                    } else if (me.p.x <= area.x + m.up_btn_w) {
                        editor.filetreeRootUp();
                    }
                    continue;
                }
                if (row == null) {
                    // Empty space below the rows: target the root for
                    // create/paste/move (it has no row of its own).
                    ft.clearMulti();
                    ft.root_selected = true;
                    filetree_last_click_ns = 0;
                    continue;
                }
                if (row) |r| {
                    // Multi-select: Ctrl toggles, Shift ranges — both skip
                    // the double-click machinery but still arm a drag of
                    // the resulting selection (VS Code gesture).
                    if (me.mod.control() and !me.mod.shift()) {
                        ft.toggleMultiAt(r) catch {};
                        filetree_last_click_ns = 0;
                        const still_selected = ft.isMultiSelected(ft.visible.items[r]) or
                            (ft.multi.count() == 0 and ft.selected == r);
                        if (still_selected) filetreeDndArm(editor, ft, me.p, r);
                        continue;
                    }
                    if (me.mod.shift()) {
                        ft.selectRangeTo(r) catch {};
                        filetree_last_click_ns = 0;
                        filetreeDndArm(editor, ft, me.p, r);
                        continue;
                    }
                    // Plain click inside a multi selection keeps it (so
                    // the group can be dragged); outside it, back to a
                    // single selection.
                    if (!ft.isMultiSelected(ft.visible.items[r])) ft.clearMulti();
                    ft.root_selected = false;
                    ft.selected = r;
                    const idx = ft.visible.items[r];
                    const node = ft.nodes.items[idx];

                    const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
                    const is_double = r == filetree_last_click_row and
                        now_ns - filetree_last_click_ns < filetree_double_click_ms * std.time.ns_per_ms;

                    // Single click on the chevron toggles a folder; row
                    // names need a double click (toggle dir / open file) so
                    // a stray click never opens or collapses anything.
                    const rx = m.rowX(node.depth);
                    const in_chevron = node.kind == .dir and me.p.x >= rx and me.p.x < rx + m.chevron_w;

                    if (in_chevron) {
                        ft.toggle(idx) catch {};
                        filetree_last_click_ns = 0; // action fired — no chain
                    } else if (is_double) {
                        if (node.kind == .dir) {
                            ft.toggle(idx) catch {};
                        } else {
                            openFiletreeFile(editor, ft, idx);
                        }
                        filetree_last_click_ns = 0;
                    } else {
                        filetree_last_click_ns = now_ns;
                        filetree_last_click_row = r;
                    }
                    // Arm drag & drop from any name press (the chevron press
                    // already mutated the tree, so its row may be stale)
                    if (!in_chevron) {
                        filetreeDndArm(editor, ft, me.p, r);
                    }
                }
            },
            .wheel_y => |delta| {
                e.handle(@src(), wd);
                const rows_per_notch: f32 = 3;
                const pixels_per_notch: f32 = dvui.scroll_speed;
                const scroll_rows: i32 = @intFromFloat(@round(-delta / pixels_per_notch * rows_per_notch));
                const max_top: i64 = @intCast(ft.visible.items.len -| visible_rows);
                const new_top = @as(i64, @intCast(filetree_scroll)) + scroll_rows;
                filetree_scroll = @intCast(@max(0, @min(new_top, max_top)));
                // Rows moved under the cursor — recompute the hover row.
                filetree_hover_row = filetreeRowAt(ft, rows_y, line_height, me.p.y);
            },
            else => {},
        }
    }
}

/// Keys while the tree owns the keyboard (treeTakesKeys). Ctrl/Alt/Cmd
/// chords are left for the global keybind map.
fn handleFiletreeKeys(editor: *Editor, ft: *FileTree, wd: *dvui.WidgetData, visible_rows: usize) void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        // A key can hand the keyboard away (Enter opens a file, Escape,
        // `d` opens the delete prompt): the rest is not the tree's.
        if (!treeTakesKeys(editor)) break;
        switch (e.evt) {
            .key => |key| {
                if (key.action != .down and key.action != .repeat) continue;
                // Keep the "press p" hint visible while a move is pending
                if (editor.filetree_move_src == null) editor.dismissStatus();
                if (hasCommandMod(key.mod)) continue;
                if (filetree_search_active) {
                    switch (key.code) {
                        .escape, .enter => {
                            e.handle(@src(), wd);
                            filetree_search_active = false;
                            continue;
                        },
                        .backspace => {
                            e.handle(@src(), wd);
                            if (filetree_search_len > 0) filetree_search_len -= 1;
                            filetreeSearchJump(ft, visible_rows);
                            continue;
                        },
                        // Arrows and friends leave search mode, then
                        // navigate normally via the switch below.
                        .up, .down, .left, .right, .home, .end => filetree_search_active = false,
                        // Letters arrive via the text event — swallow the
                        // raw keys so j/k/a/r/d/x/p don't fire mid-query.
                        else => {
                            e.handle(@src(), wd);
                            continue;
                        },
                    }
                }
                switch (key.code) {
                    .up, .k => {
                        e.handle(@src(), wd);
                        if (key.mod.shift() and key.code == .up) {
                            ft.selectRangeTo(ft.selected -| 1) catch {};
                        } else {
                            ft.clearMulti();
                            ft.moveSelection(-1);
                        }
                        filetreeEnsureSelectedVisible(ft, visible_rows);
                    },
                    .down, .j => {
                        e.handle(@src(), wd);
                        if (key.mod.shift() and key.code == .down) {
                            ft.selectRangeTo(ft.selected + 1) catch {};
                        } else {
                            ft.clearMulti();
                            ft.moveSelection(1);
                        }
                        filetreeEnsureSelectedVisible(ft, visible_rows);
                    },
                    .home => {
                        e.handle(@src(), wd);
                        ft.clearMulti();
                        ft.selected = 0;
                        filetreeEnsureSelectedVisible(ft, visible_rows);
                    },
                    .end => {
                        e.handle(@src(), wd);
                        ft.clearMulti();
                        ft.selected = ft.visible.items.len -| 1;
                        filetreeEnsureSelectedVisible(ft, visible_rows);
                    },
                    .enter, .right => {
                        e.handle(@src(), wd);
                        const idx = ft.selectedNodeIdx() orelse continue;
                        if (ft.nodes.items[idx].kind == .dir) {
                            if (key.code == .right) {
                                ft.expand(idx) catch {};
                            } else {
                                ft.toggle(idx) catch {};
                            }
                        } else {
                            openFiletreeFile(editor, ft, idx);
                            _ = editor.takeKeyboardFocus(.pane);
                            filetree_release_focus = true;
                        }
                    },
                    .left => {
                        e.handle(@src(), wd);
                        const idx = ft.selectedNodeIdx() orelse continue;
                        const node = ft.nodes.items[idx];
                        if (node.kind == .dir and node.expanded) {
                            ft.collapse(idx) catch {};
                        } else if (idx != 0 and node.parent != 0) {
                            if (ft.rowOf(node.parent)) |prow| {
                                ft.selected = prow;
                                filetreeEnsureSelectedVisible(ft, visible_rows);
                            }
                        }
                    },
                    .a => {
                        e.handle(@src(), wd);
                        editor.startFiletreePrompt(.create);
                    },
                    .r => {
                        e.handle(@src(), wd);
                        if (key.mod.shift()) {
                            _ = editor.execCommand("filetree_refresh", null);
                        } else {
                            editor.startFiletreePrompt(.rename);
                        }
                    },
                    .d => {
                        e.handle(@src(), wd);
                        editor.startFiletreePrompt(.delete_confirm);
                    },
                    .x => {
                        e.handle(@src(), wd);
                        editor.startFiletreeMove();
                    },
                    .p => {
                        e.handle(@src(), wd);
                        editor.applyFiletreeMove();
                    },
                    .backspace, .u => {
                        e.handle(@src(), wd);
                        editor.filetreeRootUp();
                    },
                    .o => {
                        e.handle(@src(), wd);
                        editor.filetreeOpenSelectedAsRoot();
                    },
                    .escape => {
                        e.handle(@src(), wd);
                        // A pending move mark cancels first, then a multi
                        // selection; only then does focus leave the tree.
                        if (editor.filetree_move_src != null) {
                            editor.cancelFiletreeMove();
                            editor.status_message = "Move cancelled";
                        } else if (ft.multi.count() > 0) {
                            ft.clearMulti();
                        } else {
                            _ = editor.takeKeyboardFocus(.pane);
                            filetree_release_focus = true;
                        }
                    },
                    else => {},
                }
            },
            .text => |te| {
                // While the tree owns the keyboard, text either drives the
                // `/` search or is swallowed so letters never insert into
                // the document behind the panel.
                switch (te.action) {
                    .value => |val| {
                        // Uncommitted IME composition is not typed text.
                        if (val.selected) continue;
                        e.handle(@src(), wd);
                        if (filetree_search_active) {
                            for (val.txt) |ch| {
                                if (ch < 32 or ch >= 127) continue;
                                if (filetree_search_len < filetree_search_buf.len) {
                                    filetree_search_buf[filetree_search_len] = ch;
                                    filetree_search_len += 1;
                                }
                            }
                            filetreeSearchJump(ft, visible_rows);
                        } else if (val.txt.len == 1 and val.txt[0] == '/') {
                            filetree_search_active = true;
                            filetree_search_len = 0;
                            filetree_search_miss = false;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

/// Status message + dvui toast — for errors the user must actually see
/// (the status bar alone was easy to miss in the first smoke test).
/// A failure: in the status bar and as a toast. `args` must not point into
/// `editor.status_buf` (the message is formatted there).
fn guiNotify(editor: *Editor, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&editor.status_buf, fmt, args) catch return;
    editor.setStatus(.err, msg);
    dvui.toast(@src(), .{ .message = msg });
}

/// Open the file behind a tree node (deduped against open tabs).
fn openFiletreeFile(editor: *Editor, ft: *FileTree, idx: u32) void {
    const abs = ft.absPathAlloc(editor.allocator, idx) catch return;
    defer editor.allocator.free(abs);
    _ = editor.navOpen(abs) catch |err| {
        if (err == error.BinaryFile) {
            guiNotify(editor, "Not opened: binary or unsupported text encoding", .{});
        } else {
            guiNotify(editor, "Open failed: {s}", .{@errorName(err)});
        }
    };
}

/// Clickable delete confirmation (mode == .filetree_prompt with kind ==
/// .delete_confirm). Declared from frame() before the panes, like the
/// settings dialog, so its buttons see events first. Keys go through the
/// modal key path: only `y` (or the Delete button) deletes.
fn filetreeDeleteDialog(editor: *Editor) void {
    if (!build_options.has_gui) return;
    var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{ .min_size_content = .{ .w = 340 } });
    defer float.deinit();
    float.dragAreaSet(dvui.windowHeader("Delete", "", null));

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(8) });
    defer vbox.deinit();

    const count = if (editor.filetree) |*ft| ft.selectionCount() else 1;
    var buf: [600]u8 = undefined;
    const what = if (count > 1)
        std.fmt.bufPrint(&buf, "Delete {d} selected items?", .{count}) catch "Delete the selection?"
    else
        std.fmt.bufPrint(&buf, "Delete {s}?", .{editor.filetree_prompt_target orelse ""}) catch "Delete?";
    dvui.labelNoFmt(@src(), what, .{}, .{});
    dvui.labelNoFmt(@src(), "Folders delete recursively. Press y to delete; Enter, n or Esc cancels.", .{}, .{
        .color_text = toDvui(editor.theme.overlay_hint),
    });

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 1.0,
        .padding = .{ .x = 0, .y = 8, .w = 0, .h = 0 },
    });
    defer hbox.deinit();
    if (dvui.button(@src(), "Cancel", .{}, .{})) {
        editor.cancelFiletreePrompt();
        dvui.focusSubwindow(null, null);
    }
    if (dvui.button(@src(), "Delete", .{}, .{})) {
        editor.applyFiletreePrompt();
        dvui.focusSubwindow(null, null);
    }
}

const FiletreeInlineTarget = struct {
    rename_row: ?usize,
    create_slot: ?usize,
    depth: u16,
    icon: fileicons.FileIcon,
};

/// Resolve where the inline create/rename entry lives this frame — used
/// by both the painter and the click-away hit test. Null when no
/// create/rename prompt is active.
fn filetreeInlineTarget(editor: *Editor, ft: *FileTree) ?FiletreeInlineTarget {
    if (editor.mode != .filetree_prompt) return null;
    if (editor.filetree_prompt_kind == .delete_confirm) return null;
    const target = editor.filetree_prompt_target orelse return null;
    var out: FiletreeInlineTarget = .{
        .rename_row = null,
        .create_slot = null,
        .depth = 1,
        .icon = .{ .kind = .generic, .color = null },
    };
    switch (editor.filetree_prompt_kind) {
        .rename => {
            const tidx = ft.findByPath(target) orelse return null;
            const trow = ft.rowOf(tidx) orelse return null;
            out.rename_row = trow;
            const tnode = ft.nodes.items[tidx];
            out.depth = tnode.depth;
            out.icon = editor.filetreeIconFor(tnode.name, tnode.kind == .dir);
        },
        .create => {
            const pidx = ft.findByPath(target) orelse 0;
            if (pidx != 0) {
                if (ft.rowOf(pidx)) |prow| {
                    out.create_slot = prow + 1;
                    out.depth = ft.nodes.items[pidx].depth + 1;
                } else {
                    out.create_slot = 0; // parent collapsed out of view
                }
            } else {
                out.create_slot = 0;
            }
        },
        .delete_confirm => unreachable,
    }
    return out;
}

/// Right-click context menu for the file tree panel. The right press has
/// already selected the row (handleFiletreeMouse leaves it unhandled).
fn filetreeContextMenu(editor: *Editor, area: dvui.Rect.Physical) void {
    const ctext = dvui.context(@src(), .{ .rect = area }, .{});
    defer ctext.deinit();

    if (ctext.activePoint()) |cp| {
        var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "New File/Folder    a", .{}, .{ .expand = .horizontal }) != null) {
            editor.startFiletreePrompt(.create);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Rename             r", .{}, .{ .expand = .horizontal }) != null) {
            editor.startFiletreePrompt(.rename);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Delete             d", .{}, .{ .expand = .horizontal }) != null) {
            editor.startFiletreePrompt(.delete_confirm);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Copy Path", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("filetree_copy_path", null);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Copy Relative Path", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("filetree_copy_relative_path", null);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Reveal in Explorer", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("filetree_reveal_explorer", null);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Open as Root       o", .{}, .{ .expand = .horizontal }) != null) {
            editor.filetreeOpenSelectedAsRoot();
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Up One Folder      u", .{}, .{ .expand = .horizontal }) != null) {
            editor.filetreeRootUp();
            fw.close();
        }
        const side_label: []const u8 = if (editor.filetree_side == .left)
            "Move Tree to Right"
        else
            "Move Tree to Left";
        if (dvui.menuItemLabel(@src(), side_label, .{}, .{ .expand = .horizontal }) != null) {
            editor.filetree_side = if (editor.filetree_side == .left) .right else .left;
            lua_settings.writeStringSettingToFile("filetree_side", @tagName(editor.filetree_side)) catch {};
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Refresh            R", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("filetree_refresh", null);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Reveal Current File", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("filetree_reveal", null);
            fw.close();
        }
    }
}

// ===========================================================================
// Snippets side panel
// ===========================================================================

/// The Snippets band (see BandResize).
var snippets_band: BandResize = .{};
/// Row under the pointer: the hover bar, and the preview follows it. Null
/// outside the rows, and after keyboard navigation until the pointer
/// moves again, so the selection drives the preview.
var snippets_hover_row: ?usize = null;
/// Where the pointer was when the hover row was last set: every frame ends
/// with a synthetic position event at the pointer, which must not undo a
/// keyboard move.
var snippets_hover_pt: ?dvui.Point.Physical = null;
/// Scrollbar state, as the file tree's: thumb drag with the grab offset
/// inside the thumb, plus hover over the band for the brighter thumb.
var snippets_sb_drag: bool = false;
var snippets_sb_grab_dy: f32 = 0;
var snippets_sb_hover: bool = false;
/// The row last clicked and its frame time: the second press of a
/// double-click must not insert an item again, or close the group it
/// just opened.
var snippets_last_click_ns: i128 = 0;
var snippets_last_click_row: usize = std.math.maxInt(usize);
/// Registry index of the definition the preview showed last frame (null:
/// none) — the tests read it.
var snippets_preview_def: ?u32 = null;
/// The preview's scroll offset (physical px; back to 0 when the previewed
/// item changes) and how much of its content did not fit last frame: the
/// wheel over the preview, or its scrollbar, scrolls long notes.
var snippets_preview_scroll: f32 = 0;
var snippets_preview_overflow: f32 = 0;
var snippets_pv_sb_drag: bool = false;
var snippets_pv_sb_grab_dy: f32 = 0;
var snippets_pv_sb_hover: bool = false;
/// Visual rows the preview's code block took last frame — the tests read it.
var snippets_preview_code_rows: usize = 0;
/// snippets_double_click: the last double-click already inserted its
/// item, so a third press right after must not insert it again.
var snippets_last_click_inserted: bool = false;

/// The Snippets band's logical width this frame: its setting, narrowed so
/// the panes keep 240 px beside the bands. 0 = no band: hidden, the row
/// not laid out yet, or no room — the panel then hides itself and says so
/// (a band that cannot appear must not keep the keyboard, and Ctrl+Alt+B
/// must not be left cycling a panel nobody can see).
fn snippetsBandWidth(editor: *Editor, row_w: f32, tree_shown: bool) f32 {
    if (!editor.snippets_visible) return 0;
    if (row_w <= 0) {
        snippetsBandGone();
        return 0;
    }
    const tree_w: f32 = if (tree_shown) std.math.clamp(editor.filetree_width, 120, 600) else 0;
    const w = @min(std.math.clamp(editor.snippets_width, 120, 600), row_w - tree_w - 240);
    if (w >= 120) return w;
    snippetsBandGone();
    if (editor.keyboardOwner() == .snippets) filetree_release_focus = true;
    editor.snippets_visible = false;
    editor.snippets_focused = false;
    editor.setStatus(.warning, "Snippets panel: no room beside the editor — widen the window, then Ctrl+Alt+B");
    return 0;
}

/// No Snippets band this frame (hidden, or no room for it): nothing to
/// grab, hover or drag until it is drawn again.
fn snippetsBandGone() void {
    snippets_band.reset();
    snippets_hover_row = null;
    snippets_hover_pt = null;
    snippets_sb_drag = false;
    snippets_sb_hover = false;
    snippets_pv_sb_drag = false;
    snippets_pv_sb_hover = false;
}

/// Per-frame Snippets panel layout (physical px) — one place for the
/// geometry so the painter and the mouse handler can't drift.
const SnippetsMetrics = struct {
    area: dvui.Rect.Physical,
    scale: f32,
    line_height: f32,
    /// The title row's height; the filter box's row follows it.
    header_h: f32,
    /// The type-to-filter box, inset in its row under the header (the rows
    /// start below that row). A click on it gives the panel the keyboard,
    /// and typing then narrows the rows.
    filter: dvui.Rect.Physical,
    rows_y: f32,
    rows_h: f32,
    visible_rows: usize,
    /// The preview block under the rows; h = 0 when the panel is too short.
    preview: dvui.Rect.Physical,
    /// Left padding before a group's chevron.
    pad_l: f32,
    chevron_w: f32,
    icon_size: f32,
    /// Where group names start, and item names, indented under them.
    group_x: f32,
    item_x: f32,
    /// Scrollbar band (left edge + width) over the rows' right edge.
    sb_x: f32,
    sb_w: f32,
};

/// `row_count` is the list as last built: a short list leaves the room it
/// does not need to the preview.
fn snippetsMetrics(area: dvui.Rect.Physical, scale: f32, line_height: f32, row_count: usize) SnippetsMetrics {
    const header_h = line_height + 4 * scale;
    // The filter box's row: a box a little taller than its text, with a
    // few px of air above and below.
    const filter_h = line_height + 10 * scale;
    const top_h = header_h + filter_h;
    // The preview keeps at least 40% of the panel — sized by its content,
    // the list would grow and shrink under the pointer as the hover moved
    // — and takes whatever a short list leaves free (an empty list shows
    // a hint: keep it a few rows).
    const rows_f: f32 = @floatFromInt(if (row_count == 0) 6 else row_count);
    const list_h = top_h + rows_f * line_height + 4 * scale;
    var preview_h = @max(@floor(area.h * 0.4), @floor(area.h - list_h));
    const list_min = top_h + 3 * line_height;
    if (area.h - preview_h < list_min) preview_h = @max(0, area.h - list_min);
    if (preview_h < 3 * line_height) preview_h = 0;
    const rows_h = @max(0, area.h - top_h - preview_h);
    const sb_w = 6 * scale;
    const pad_l = 6 * scale;
    const chevron_w = 14 * scale;
    const group_x = area.x + pad_l + chevron_w + 4 * scale;
    return .{
        .area = area,
        .scale = scale,
        .line_height = line_height,
        .header_h = header_h,
        .filter = .{
            .x = area.x + 6 * scale,
            .y = area.y + header_h + 3 * scale,
            .w = @max(0, area.w - 12 * scale),
            .h = filter_h - 6 * scale,
        },
        .rows_y = area.y + top_h,
        .rows_h = rows_h,
        .visible_rows = if (rows_h > line_height) @intFromFloat(@floor(rows_h / line_height)) else 1,
        .preview = .{ .x = area.x, .y = area.y + area.h - preview_h, .w = area.w, .h = preview_h },
        .pad_l = pad_l,
        .chevron_w = chevron_w,
        .icon_size = @round(line_height * 0.72),
        .group_x = group_x,
        .item_x = group_x + 10 * scale,
        .sb_x = area.x + area.w - sb_w - 1 * scale,
        .sb_w = sb_w,
    };
}

/// Row index under a physical y position, or null off the drawn rows.
fn snippetsRowAt(panel: *const snippet_panel.State, m: SnippetsMetrics, y: f32) ?usize {
    if (y < m.rows_y or y >= m.rows_y + m.rows_h or m.line_height <= 0) return null;
    const rel: usize = @intFromFloat(@floor((y - m.rows_y) / m.line_height));
    if (rel >= m.visible_rows) return null;
    const row = panel.scroll + rel;
    return if (row < panel.rows.items.len) row else null;
}

/// Scrollbar thumb rect, or null when every row fits (as filetreeSbThumb).
fn snippetsSbThumb(panel: *const snippet_panel.State, m: SnippetsMetrics) ?dvui.Rect.Physical {
    const count = panel.rows.items.len;
    if (count <= m.visible_rows or m.rows_h <= 0) return null;
    const count_f: f32 = @floatFromInt(count);
    const vis_f: f32 = @floatFromInt(m.visible_rows);
    const thumb_h = @min(m.rows_h, @max(20 * m.scale, m.rows_h * vis_f / count_f));
    const denom: f32 = @floatFromInt(count - m.visible_rows);
    const frac = @min(1.0, @as(f32, @floatFromInt(panel.scroll)) / denom);
    return .{
        .x = m.sb_x + 1 * m.scale,
        .y = m.rows_y + (m.rows_h - thumb_h) * frac,
        .w = m.sb_w - 2 * m.scale,
        .h = thumb_h,
    };
}

/// The Snippets side panel, modelled on Kate's Snippets tool view: the
/// snippets for the main window's document, filed in collapsible groups
/// (snippet_panel.zig owns the rows). A click or Enter inserts an item at
/// the caret and hands the keyboard back so Tab walks its blanks; the
/// preview at the bottom shows what the hovered (else the selected) item
/// inserts. While the panel has the keyboard, typing narrows the rows (the
/// filter box under the header), and F2 / Delete — or the right-click menu
/// — edit, copy or delete the selected snippet. Custom rows in the file
/// tree's style; `width` is the band's logical width this frame
/// (snippetsBandWidth).
fn snippetsPanel(editor: *Editor, width: f32) void {
    if (!build_options.has_gui) return;
    var pbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
        .min_size_content = .{ .w = width },
        .background = true,
        .style = .window,
        .name = "snippets_panel",
        .tag = "snippets_panel",
    });
    defer pbox.deinit();

    const wd = pbox.data();
    const rs = wd.contentRectScale();
    const scale = rs.s;
    const area = rs.r;
    snippets_band.rect = area;
    snippets_band.scale = scale;

    const font = dvui.Font.theme(.body);
    const line_height = font.lineHeight() * scale;
    if (line_height <= 0 or area.h <= 0 or area.w <= 0) return;
    // The input is hit-tested against the layout drawn last frame: the
    // rows as the list had them.
    const rows_before = editor.snippet_panel.rows.items.len;
    var m = snippetsMetrics(area, scale, line_height, rows_before);

    // Input first, then the sync: a click or a key can open or close a
    // group, narrow the filter or give an untitled file a language, and
    // every count and clamp below must see the rows that left (a stale row
    // count was an out-of-bounds panic in the file tree).
    handleSnippetsMouse(editor, wd, m);
    if (snippetsTakesKeys(editor)) handleSnippetsKeys(editor, wd, m.visible_rows);
    // SDL delivers .text events only while someone declares a text-input
    // region (see filetreePanel): without this the filter never hears the
    // typing. After the input: a click may just have given the panel the
    // keyboard, Enter or Escape handed it back.
    if (snippetsTakesKeys(editor)) dvui.wantTextInput(m.filter.toNatural());
    const panel = editor.syncSnippetPanel();
    const rows = panel.rows.items;
    // Rows came or went: the list and the preview share the panel anew.
    if (rows.len != rows_before) m = snippetsMetrics(area, scale, line_height, rows.len);
    const defs = editor.snippets.items.items;
    const focused = editor.keyboardOwner() == .snippets;

    if (snippets_hover_row) |h| {
        if (h >= rows.len) snippets_hover_row = null;
    }
    // Keyboard navigation flagged the selection for scroll-into-view.
    if (panel.scroll_to_selected) {
        panel.scroll_to_selected = false;
        if (panel.selected < panel.scroll) {
            panel.scroll = panel.selected;
        } else if (panel.selected >= panel.scroll + m.visible_rows) {
            panel.scroll = panel.selected + 1 - m.visible_rows;
        }
    }
    // Clamp the scroll when rows disappeared (a group closed, a reload).
    panel.scroll = @min(panel.scroll, rows.len -| m.visible_rows);

    const header_fg = toDvui(editor.theme.overlay_fg);
    const dim = toDvui(editor.theme.overlay_dim);
    const text_color = toDvui(editor.theme.text);
    const sel_bg = toDvui(editor.theme.selection);
    // Edges, dividers and indent guides: the panel border color, lighter
    // than the gutter line so the panel reads as a box.
    const guide_color = toDvui(editor.theme.panel_border);
    const line_w = @max(1.0, 1 * scale);
    {
        const prev_clip = dvui.clip(area);
        defer dvui.clipSet(prev_clip);

        // --- Header: "Snippets — <language>", bold while it has the keyboard ---
        fillBar(area, 0, m.header_h, toDvui(editor.theme.gutter_bg));
        const header_line: dvui.Rect.Physical = .{ .x = area.x, .y = area.y + m.header_h - line_w, .w = area.w, .h = line_w };
        header_line.fill(.{}, .{ .color = guide_color, .fade = 1.0 });
        var title_buf: [128]u8 = undefined;
        const title: []const u8 = if (std.fmt.bufPrint(&title_buf, "Snippets — {s}", .{panel.languageLabel()})) |t| blk: {
            // The label is cut at 64 bytes, maybe inside a character.
            sanitizeUtf8(t);
            break :blk t;
        } else |_| "Snippets";
        const title_font = if (focused) dvui.Font.theme(.heading) else font;
        const title_fit = fitOverlayText(title_font, title, area.w - 16 * scale, scale);
        renderOverlayText(title_font, title_fit, area.x + 8 * scale, area.y + 2 * scale, rs, if (focused) header_fg else dim);

        // --- Filter box under the header: the text the rows are narrowed
        //     to, in the search panel's input box colored as dvui colors a
        //     text entry: the content color inside, the focus color around
        //     it and a caret while typing lands there (not while a prompt
        //     or a dialog takes it). Opaque inside: the gutter color is
        //     translucent, and through it the border's fill washed the
        //     typing out. ---
        const ui_theme = dvui.themeGet();
        drawSearchBox(font, rs, m.filter.x, m.filter.y, m.filter.w, m.filter.h, scale, "Type to filter", panel.filterText(), snippetsTakesKeys(editor), text_color, dim, ui_theme.focus, ui_theme.color(.content, .fill));

        // --- Rows: groups (chevron, name, count) and their items (name,
        //     Tab trigger right-aligned) ---
        if (rows.len == 0) {
            _ = drawWrappedText(font, panel.emptyHint(), area.x + 8 * scale, m.rows_y + 4 * scale, area.w - 16 * scale, m.rows_y + m.rows_h, rs, dim);
        }
        // Any-language mode lists several languages' groups: each says whose.
        const any_language = panel.anyLanguage();
        // Counts and triggers end here, clear of the scrollbar.
        const text_right = m.sb_x - 4 * scale;
        var r = panel.scroll;
        var y = m.rows_y;
        while (r < rows.len and y + line_height <= m.rows_y + m.rows_h + 0.5) : ({
            r += 1;
            y += line_height;
        }) {
            const row = rows[r];
            if (snippets_hover_row) |h| {
                if (h == r and r != panel.selected) fillBar(area, y - area.y, line_height, sel_bg.opacity(0.3));
            }
            if (r == panel.selected) {
                // Dimmed bar when the panel doesn't own the keyboard.
                fillBar(area, y - area.y, line_height, if (focused) sel_bg else sel_bg.opacity(0.45));
            }
            switch (row.kind) {
                .group => {
                    const group = panel.groups.items[row.group];
                    const chev: []const u8 = if (group.expanded) (icons.tvg(.chevron_down) orelse dvui.entypo.chevron_small_down) else (icons.tvg(.chevron_right) orelse dvui.entypo.chevron_small_right);
                    renderIconTinted(if (group.expanded) "snip_chev_open" else "snip_chev", chev, .{
                        .x = area.x + m.pad_l + (m.chevron_w - m.icon_size) / 2,
                        .y = y + (line_height - m.icon_size) / 2,
                        .w = m.icon_size,
                        .h = m.icon_size,
                    }, scale, dim);
                    var count_buf: [16]u8 = undefined;
                    const count = std.fmt.bufPrint(&count_buf, "{d}", .{group.count}) catch "";
                    const count_x = text_right - font.textSize(count).w * scale;
                    renderOverlayText(font, count, count_x, y, rs, dim);
                    // Name (after the language in any-language mode),
                    // clipped so it never runs under the count.
                    const name_clip = dvui.clip(.{ .x = area.x, .y = y, .w = @max(0, count_x - 6 * scale - area.x), .h = line_height });
                    defer dvui.clipSet(name_clip);
                    var x = m.group_x;
                    if (any_language) {
                        renderOverlayText(font, group.language, x, y, rs, dim);
                        x += font.textSize(group.language).w * scale + 6 * scale;
                    }
                    renderOverlayText(font, group.name, x, y, rs, text_color);
                },
                .item => {
                    // Indent guide under the group's chevron, as the tree
                    // draws for its folders.
                    const guide: dvui.Rect.Physical = .{ .x = area.x + m.pad_l + m.chevron_w / 2, .y = y, .w = line_w, .h = line_height };
                    guide.fill(.{}, .{ .color = guide_color, .fade = 1.0 });
                    if (row.def >= defs.len) continue;
                    const def = &defs[row.def];
                    const x = m.item_x;
                    var name_right = text_right;
                    if (def.hasTrigger()) {
                        const trigger_x = text_right - font.textSize(def.prefix).w * scale;
                        // Only beside a name that keeps a few letters.
                        if (trigger_x - 8 * scale > x + 4 * font.textSize("M").w * scale) {
                            renderOverlayText(font, def.prefix, trigger_x, y, rs, dim);
                            name_right = trigger_x - 8 * scale;
                        }
                    }
                    const name_clip = dvui.clip(.{ .x = area.x, .y = y, .w = @max(0, name_right - area.x), .h = line_height });
                    defer dvui.clipSet(name_clip);
                    renderOverlayText(font, def.description, x, y, rs, text_color);
                },
            }
        }

        // --- Scrollbar: slim pill over the right edge of the rows ---
        if (snippetsSbThumb(panel, m)) |thumb| {
            const active = snippets_sb_drag or snippets_sb_hover;
            const sb_color = if (active) header_fg.opacity(0.6) else dim.opacity(0.45);
            const rad = thumb.w / 2;
            thumb.fill(.{ .x = rad, .y = rad, .w = rad, .h = rad }, .{ .color = sb_color, .fade = 1.0 });
        }

        // --- Preview of the hovered, else the selected, item; a new one
        //     starts at its top ---
        const preview_def = panel.previewDef(snippets_hover_row);
        if (!std.meta.eql(preview_def, snippets_preview_def)) {
            snippets_preview_scroll = 0;
            snippets_pv_sb_drag = false;
        }
        snippets_preview_def = preview_def;
        if (m.preview.h > 0) {
            const preview: ?*const snippets_mod.Definition = blk: {
                const di = snippets_preview_def orelse break :blk null;
                break :blk if (di < defs.len) &defs[di] else null;
            };
            drawSnippetPreview(editor, preview, m, rs, font);
        } else {
            snippets_preview_overflow = 0;
        }

        // Separator line on the editor-facing edge, as the file tree's.
        const sep_w = line_w;
        const sep_x = if (editor.snippetsSide() == .left) area.x + area.w - sep_w else area.x;
        const sep_rect: dvui.Rect.Physical = .{ .x = sep_x, .y = area.y, .w = sep_w, .h = area.h };
        sep_rect.fill(.{}, .{ .color = guide_color, .fade = 1.0 });
    }

    // Right-click context menu over the panel.
    snippetsContextMenu(editor, area);
}

/// The preview block under the rows: the code `def` inserts (the editor's
/// mono font, tabs at the document's indent width, the blanks tinted), how
/// to fill it in, then its notes word-wrapped. What does not fit scrolls:
/// the wheel over the block, or its scrollbar (snippets_preview_scroll).
/// A null `def` (no item highlighted) says how to get one.
fn drawSnippetPreview(editor: *Editor, def: ?*const snippets_mod.Definition, m: SnippetsMetrics, rs: dvui.RectScale, font: dvui.Font) void {
    const scale = m.scale;
    const pv = m.preview;
    const dim = toDvui(editor.theme.overlay_dim);
    const text_color = toDvui(editor.theme.text);
    const line_w = @max(1.0, 1 * scale);
    const top_line: dvui.Rect.Physical = .{ .x = pv.x, .y = pv.y, .w = pv.w, .h = line_w };
    top_line.fill(.{}, .{ .color = toDvui(editor.theme.panel_border), .fade = 1.0 });
    const x = pv.x + 8 * scale;
    // Text ends clear of the scrollbar band.
    const max_w = m.sb_x - 4 * scale - x;
    const content_top = pv.y + line_w;
    const bottom = pv.y + pv.h;
    const d = def orelse {
        snippets_preview_overflow = 0;
        _ = drawWrappedText(font, "Point at a snippet, or select one, to see the code it inserts", x, content_top + 5 * scale, max_w, bottom - 4 * scale, rs, dim);
        return;
    };

    // Everything below scrolls together, clipped to the block.
    const prev_clip = dvui.clip(.{ .x = pv.x, .y = content_top, .w = pv.w, .h = @max(0, bottom - content_top) });
    defer dvui.clipSet(prev_clip);
    var y = content_top + 5 * scale - snippets_preview_scroll;
    const no_limit = std.math.inf(f32);

    // --- Code block: every line, soft-wrapped to the block as the notes
    //     are (a continued row sits two columns in), the blanks tinted ---
    const mono = dvui.Font.theme(.mono);
    const mono_lh = mono.lineHeight() * scale;
    const text = d.template.text;
    const has_blanks = for (d.template.stops) |stop| {
        if (stop.number != 0) break true;
    } else false;
    const doc = &editor.documents.items[editor.windowDocIdx(0)];
    const tab_w = editor.indentWidthFor(doc);
    const code_x = pv.x + 4 * scale;
    const code_w = @max(0, m.sb_x - 2 * scale - code_x);
    const cont_indent = mono.textSize("  ").w * scale;
    const wrap: PreviewWrap = .{
        .font = mono,
        .first_w = @max(0, code_w - 8 * scale) / scale,
        .cont_w = @max(0, code_w - 8 * scale - cont_indent) / scale,
    };
    const code_rows = previewCodeRows(text, tab_w, wrap);
    snippets_preview_code_rows = code_rows;
    if (mono_lh > 0 and code_rows > 0) {
        const code_rect: dvui.Rect.Physical = .{
            .x = code_x,
            .y = y,
            .w = code_w,
            .h = @as(f32, @floatFromInt(code_rows)) * mono_lh + 8 * scale,
        };
        const rad = 3 * scale;
        code_rect.fill(.{ .x = rad, .y = rad, .w = rad, .h = rad }, .{ .color = toDvui(editor.theme.gutter_bg), .fade = 1.0 });
        strokeRect(code_rect, line_w, toDvui(editor.theme.panel_border));
        const code_clip = dvui.clip(code_rect);
        defer dvui.clipSet(code_clip);
        const blank_bg = toDvui(editor.theme.selection).opacity(0.6);
        var ly = y + 4 * scale;
        var start: usize = 0;
        while (start <= text.len) {
            const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
            const line = std.mem.trimEnd(u8, text[start..end], "\r");
            var buf: [512]u8 = undefined;
            const shown = displayLine(line, tab_w, &buf);
            var pos: usize = 0;
            var first = true;
            while (true) {
                const row_end = wrap.rowEnd(shown, pos, first);
                const rx = x + (if (first) @as(f32, 0) else cont_indent);
                // The blanks on this row, tinted under the text; an empty
                // one is a thin bar where the caret will stand.
                for (d.template.stops) |stop| {
                    if (stop.number == 0) continue;
                    if (stop.start == stop.end) {
                        // On the row holding its column — the row's end
                        // only on the line's last row.
                        if (stop.start < start or stop.start > start + line.len) continue;
                        const col = displayCol(line, shown, stop.start - start, tab_w);
                        if (col < pos or col > row_end or (col == row_end and row_end < shown.len)) continue;
                        const cx = rx + mono.textSize(shown[pos..col]).w * scale;
                        const bar: dvui.Rect.Physical = .{ .x = cx - 1 * scale, .y = ly, .w = 2 * scale, .h = mono_lh };
                        bar.fill(.{ .x = 2 * scale, .y = 2 * scale, .w = 2 * scale, .h = 2 * scale }, .{ .color = blank_bg, .fade = 1.0 });
                        continue;
                    }
                    const lo = @max(stop.start, start);
                    const hi = @min(stop.end, start + line.len);
                    if (lo >= hi) continue;
                    const lo_col = @max(displayCol(line, shown, lo - start, tab_w), pos);
                    const hi_col = @min(displayCol(line, shown, hi - start, tab_w), row_end);
                    if (lo_col >= hi_col) continue;
                    const lo_x = rx + mono.textSize(shown[pos..lo_col]).w * scale;
                    const hi_x = rx + mono.textSize(shown[pos..hi_col]).w * scale;
                    const tint: dvui.Rect.Physical = .{ .x = lo_x - 1 * scale, .y = ly, .w = @max(2 * scale, hi_x - lo_x + 2 * scale), .h = mono_lh };
                    tint.fill(.{ .x = 2 * scale, .y = 2 * scale, .w = 2 * scale, .h = 2 * scale }, .{ .color = blank_bg, .fade = 1.0 });
                }
                renderOverlayText(mono, shown[pos..row_end], rx, ly, rs, text_color);
                ly += mono_lh;
                if (row_end >= shown.len) break;
                pos = row_end;
                first = false;
            }
            if (end >= text.len) break;
            start = end + 1;
        }
        y = code_rect.y + code_rect.h + 6 * scale;
    }

    // --- How to fill it in, then the notes ---
    if (has_blanks) y = drawWrappedText(font, "Tab jumps between the highlighted blanks", x, y, max_w, no_limit, rs, dim);
    if (d.hasTrigger()) {
        var trigger_buf: [256]u8 = undefined;
        const trigger = std.fmt.bufPrint(&trigger_buf, "trigger: {s} + Tab", .{d.prefix}) catch "Type its trigger, then Tab";
        y = drawWrappedText(font, trigger, x, y, max_w, no_limit, rs, dim);
    }
    if (d.notes.len > 0) y = drawWrappedText(font, d.notes, x, y + 4 * scale, max_w, no_limit, rs, text_color);

    // --- What did not fit: the wheel scrolls that far. A block that grew
    //     (fewer rows, a taller window) pulls the scroll back in ---
    const content_h = y + 4 * scale + snippets_preview_scroll - content_top;
    snippets_preview_overflow = @max(0, content_h - (bottom - content_top));
    if (snippets_preview_scroll > snippets_preview_overflow) {
        snippets_preview_scroll = snippets_preview_overflow;
        dvui.refresh(null, @src(), null);
    }
    if (snippetsPreviewThumb(m)) |thumb| {
        const active = snippets_pv_sb_drag or snippets_pv_sb_hover;
        const sb_color = if (active) toDvui(editor.theme.overlay_fg).opacity(0.6) else dim.opacity(0.45);
        const rad = thumb.w / 2;
        thumb.fill(.{ .x = rad, .y = rad, .w = rad, .h = rad }, .{ .color = sb_color, .fade = 1.0 });
    }
}

/// The preview's scrollbar thumb, or null when its content fits.
fn snippetsPreviewThumb(m: SnippetsMetrics) ?dvui.Rect.Physical {
    const pv = m.preview;
    if (pv.h <= 0 or snippets_preview_overflow <= 0) return null;
    const content_h = pv.h + snippets_preview_overflow;
    const thumb_h = @min(pv.h, @max(20 * m.scale, pv.h * pv.h / content_h));
    const frac = std.math.clamp(snippets_preview_scroll / snippets_preview_overflow, 0, 1);
    return .{
        .x = m.sb_x + 1 * m.scale,
        .y = pv.y + (pv.h - thumb_h) * frac,
        .w = m.sb_w - 2 * m.scale,
        .h = thumb_h,
    };
}

/// How the preview wraps its code to the block: the logical px a line's
/// first row may take (`first_w`) and what the rows it continues on may
/// (`cont_w`: two columns less, the continuation being indented).
const PreviewWrap = struct {
    font: dvui.Font,
    first_w: f32,
    cont_w: f32,

    /// Where the row starting at `pos` of the drawn line `shown` ends.
    fn rowEnd(w: PreviewWrap, shown: []const u8, pos: usize, first: bool) usize {
        if (shown.len == 0) return 0;
        return guiWrapAdvanceRow(shown, w.font, if (first) w.first_w else w.cont_w, pos);
    }
};

/// The visual rows the preview's code block needs for `text`.
fn previewCodeRows(text: []const u8, tab_w: usize, wrap: PreviewWrap) usize {
    var rows: usize = 0;
    var start: usize = 0;
    while (start <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[start..end], "\r");
        var buf: [512]u8 = undefined;
        const shown = displayLine(line, tab_w, &buf);
        var pos: usize = 0;
        var first = true;
        while (true) {
            rows += 1;
            const row_end = wrap.rowEnd(shown, pos, first);
            if (row_end >= shown.len) break;
            pos = row_end;
            first = false;
        }
        if (end >= text.len) break;
        start = end + 1;
    }
    return rows;
}

/// Outline `r` with a `w`-thick line of `color` just inside its edges.
fn strokeRect(r: dvui.Rect.Physical, w: f32, color: dvui.Color) void {
    const edges = [_]dvui.Rect.Physical{
        .{ .x = r.x, .y = r.y, .w = r.w, .h = w },
        .{ .x = r.x, .y = r.y + r.h - w, .w = r.w, .h = w },
        .{ .x = r.x, .y = r.y, .w = w, .h = r.h },
        .{ .x = r.x + r.w - w, .y = r.y, .w = w, .h = r.h },
    };
    for (edges) |edge| edge.fill(.{}, .{ .color = color, .fade = 1.0 });
}

/// Draw `text` word-wrapped to `max_w` physical px from (x, top), breaking
/// at its newlines too, while rows fit above `bottom`; text that does not
/// fit ends in an ellipsis on the last row. Returns the y below the last
/// row drawn.
fn drawWrappedText(font: dvui.Font, text: []const u8, x: f32, top: f32, max_w: f32, bottom: f32, rs: dvui.RectScale, color: dvui.Color) f32 {
    const scale = rs.s;
    const lh = font.lineHeight() * scale;
    if (lh <= 0 or max_w <= 0 or scale <= 0) return top;
    var y = top;
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |par| {
        var pos: usize = 0;
        while (true) {
            if (y + lh > bottom + 0.5) return y;
            const end = if (par.len == 0) 0 else guiWrapAdvanceRow(par, font, max_w / scale, pos);
            const row = std.mem.trimEnd(u8, par[pos..end], " ");
            const more = end < par.len or paragraphs.peek() != null;
            if (more and y + 2 * lh > bottom + 0.5) {
                // The last row that fits: cut it to make room for the ellipsis.
                const ellipsis = "\u{2026}";
                const cut = fitOverlayText(font, row, max_w - font.textSize(ellipsis).w * scale, scale);
                renderOverlayText(font, cut, x, y, rs, color);
                renderOverlayText(font, ellipsis, x + font.textSize(cut).w * scale, y, rs, color);
                return y + lh;
            }
            renderOverlayText(font, row, x, y, rs, color);
            y += lh;
            if (end >= par.len) break;
            pos = end;
        }
    }
    return y;
}

/// Clicks, the wheel and hover over the Snippets panel. Position and
/// motion events are never marked handled: the file tree tracks its drags
/// and hover outside its own rect, and a band drawn before it must not
/// swallow them. A right press selects the row under it and stays
/// unhandled for the context menu.
fn handleSnippetsMouse(editor: *Editor, wd: *dvui.WidgetData, m: SnippetsMetrics) void {
    const panel = &editor.snippet_panel;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        // Events over an open floating window (context menu, dialogs)
        // belong to it (see handleFiletreeMouse).
        if (me.floating_win != dvui.subwindowCurrentId()) continue;

        // In-flight scrollbar-thumb drag: follows the pointer outside the
        // panel too.
        if (snippets_sb_drag) {
            if (me.action == .motion) {
                if (snippetsSbThumb(panel, m)) |thumb| {
                    const usable = m.rows_h - thumb.h;
                    if (usable > 0) {
                        const frac = std.math.clamp((me.p.y - m.rows_y - snippets_sb_grab_dy) / usable, 0, 1);
                        const denom: f32 = @floatFromInt(panel.rows.items.len - m.visible_rows);
                        panel.scroll = @intFromFloat(@round(frac * denom));
                    }
                }
                continue;
            }
            if (me.action == .release) {
                snippets_sb_drag = false;
                continue;
            }
        }
        if (snippets_pv_sb_drag) {
            if (me.action == .motion) {
                if (snippetsPreviewThumb(m)) |thumb| {
                    const usable = m.preview.h - thumb.h;
                    if (usable > 0) {
                        const frac = std.math.clamp((me.p.y - m.preview.y - snippets_pv_sb_grab_dy) / usable, 0, 1);
                        snippets_preview_scroll = frac * snippets_preview_overflow;
                    }
                }
                continue;
            }
            if (me.action == .release) {
                snippets_pv_sb_drag = false;
                continue;
            }
        }

        const inside = m.area.contains(me.p);
        const in_sb_band = me.p.x >= m.sb_x and me.p.y >= m.rows_y and me.p.y < m.rows_y + m.rows_h;
        const in_preview = m.preview.h > 0 and m.preview.contains(me.p);
        const in_pv_sb_band = in_preview and me.p.x >= m.sb_x;
        switch (me.action) {
            .position => {
                if (!inside) {
                    snippets_hover_row = null;
                    snippets_hover_pt = null;
                    snippets_sb_hover = false;
                    snippets_pv_sb_hover = false;
                    continue;
                }
                // A text cursor over the filter box: typing goes there.
                dvui.cursorSet(if (m.filter.contains(me.p)) .ibeam else .arrow);
                snippets_sb_hover = in_sb_band;
                snippets_pv_sb_hover = in_pv_sb_band and snippetsPreviewThumb(m) != null;
                // Only a pointer that moved sets the hover: a keyboard
                // move cleared it, and the frame's closing position event
                // at the same spot must not bring it back.
                if (snippets_hover_pt) |pt| {
                    if (pt.x == me.p.x and pt.y == me.p.y) continue;
                }
                snippets_hover_pt = me.p;
                snippets_hover_row = if (in_sb_band) null else snippetsRowAt(panel, m, me.p.y);
            },
            // A left press's focus event, handled so dvui keeps its widget
            // focus: unhandled, it clears it at the end of the frame, and
            // the editor pane that just took it back for an insert would
            // stay deaf (it only re-takes focus when the owner changes).
            .focus => if (inside) e.handle(@src(), wd),
            .press => {
                if (!inside) continue;
                if (me.button == .right) {
                    // The row under the pointer is what the context menu
                    // acts on: select it and take the keyboard, so F2 or
                    // Delete act on it too. Unhandled: the panel's
                    // ContextWidget opens the menu on this press (as the
                    // file tree's).
                    if (!in_sb_band) {
                        if (snippetsRowAt(panel, m, me.p.y)) |r| panel.selected = r;
                    }
                    _ = editor.takeKeyboardFocus(.snippets);
                    dvui.focusWidget(wd.id, null, e.num);
                    continue;
                }
                if (me.button != .left) continue;
                e.handle(@src(), wd);
                // The rows can change under the pointer: hover anew.
                snippets_hover_pt = null;
                // Scrollbar band, when the rows overflow: drag the thumb,
                // or page toward the click.
                if (in_sb_band) {
                    if (snippetsSbThumb(panel, m)) |thumb| {
                        if (me.p.y >= thumb.y and me.p.y < thumb.y + thumb.h) {
                            snippets_sb_drag = true;
                            snippets_sb_grab_dy = me.p.y - thumb.y;
                        } else if (me.p.y < thumb.y) {
                            panel.scroll -|= m.visible_rows;
                        } else {
                            panel.scroll = @min(panel.scroll + m.visible_rows, panel.rows.items.len -| m.visible_rows);
                        }
                        continue;
                    }
                }
                if (in_pv_sb_band) {
                    if (snippetsPreviewThumb(m)) |thumb| {
                        if (me.p.y >= thumb.y and me.p.y < thumb.y + thumb.h) {
                            snippets_pv_sb_drag = true;
                            snippets_pv_sb_grab_dy = me.p.y - thumb.y;
                        } else {
                            const page: f32 = if (me.p.y < thumb.y) -m.preview.h else m.preview.h;
                            snippets_preview_scroll = std.math.clamp(snippets_preview_scroll + page, 0, snippets_preview_overflow);
                        }
                        continue;
                    }
                }
                const row_idx = snippetsRowAt(panel, m, me.p.y);
                const now_ns = dvui.frameTimeNS();
                const repeat = row_idx != null and row_idx.? == snippets_last_click_row and
                    now_ns - snippets_last_click_ns < filetree_double_click_ms * std.time.ns_per_ms;
                snippets_last_click_row = row_idx orelse std.math.maxInt(usize);
                snippets_last_click_ns = now_ns;
                if (!repeat) snippets_last_click_inserted = false;
                // A refused insert explains itself in the status bar: the
                // second press must not wipe that.
                if (!repeat) editor.dismissStatus();
                const is_item = if (row_idx) |r| (if (panel.rowAt(r)) |row| row.kind == .item else false) else false;
                if (is_item and guiMode(editor) == .normal) {
                    panel.selected = row_idx.?;
                    if (editor.snippets_double_click) {
                        // A click selects the item — its preview stays put
                        // — and gives the panel the keyboard; the second
                        // press of a double-click inserts it, once (a third
                        // press right after inserts nothing more).
                        if (!repeat) {
                            _ = editor.takeKeyboardFocus(.snippets);
                            dvui.focusWidget(wd.id, null, e.num);
                        } else if (!snippets_last_click_inserted) {
                            snippets_last_click_inserted = true;
                            snippetsInsert(editor, row_idx.?);
                        }
                    } else if (!repeat) {
                        // A click inserts; the second press of a
                        // double-click must not insert it again.
                        snippetsInsert(editor, row_idx.?);
                    }
                    continue;
                }
                // The header, the filter box, a group, the preview or the
                // empty space: the panel takes the keyboard (typing then
                // filters), and a group opens or closes.
                _ = editor.takeKeyboardFocus(.snippets);
                dvui.focusWidget(wd.id, null, e.num);
                if (guiMode(editor) != .normal or repeat) continue;
                if (row_idx) |r| editor.activateSnippetRow(r);
            },
            .wheel_y => |delta| {
                if (!inside) continue;
                e.handle(@src(), wd);
                const notches = -delta / dvui.scroll_speed;
                if (in_preview) {
                    // Over the preview: its notes scroll, three lines a notch.
                    snippets_preview_scroll = std.math.clamp(snippets_preview_scroll + notches * 3 * m.line_height, 0, snippets_preview_overflow);
                    continue;
                }
                const rows_per_notch: f32 = 3;
                const scroll_rows: i64 = @intFromFloat(@round(notches * rows_per_notch));
                const max_top: i64 = @intCast(panel.rows.items.len -| m.visible_rows);
                panel.scroll = @intCast(std.math.clamp(@as(i64, @intCast(panel.scroll)) + scroll_rows, 0, max_top));
                // Rows moved under the pointer — recompute the hover row.
                snippets_hover_pt = me.p;
                snippets_hover_row = if (in_sb_band) null else snippetsRowAt(panel, m, me.p.y);
            },
            else => {},
        }
    }
}

/// Insert the item on row `index` (a click or Enter). When that gave the
/// editor the keyboard — a refusal (a terminal pane, a read-only file,
/// several cursors) leaves it where it was — its pane takes dvui focus
/// back and follows the caret, so Tab walks the blanks right away.
fn snippetsInsert(editor: *Editor, index: usize) void {
    editor.activateSnippetRow(index);
    if (editor.keyboardOwner() == .editor) {
        filetree_release_focus = true;
        win_ui.scroll_pinned = false;
    }
    dvui.refresh(null, @src(), null);
}

/// Keys and text while the Snippets panel owns the keyboard
/// (snippetsTakesKeys). Ctrl/Alt/Cmd chords are left for the global
/// keybind map. Typed text narrows the rows (the panel's filter):
/// Backspace edits it, Escape clears it, and Escape with no filter hands
/// the keyboard back. Space is typed into the filter like any other
/// character — it never inserts (its text event would land in the first
/// blank) — and Tab is swallowed so dvui does not walk its widget focus to
/// the menu bar. F2 edits the selected snippet when it is one of
/// my-snippets.lua and copies it there otherwise; Delete asks before
/// deleting one of mine. An F-key gets here only while unbound:
/// dispatchGlobalKeys runs F-keys through the keybind map first, so a
/// user's binding for f2 wins over the panel's F2.
fn handleSnippetsKeys(editor: *Editor, wd: *dvui.WidgetData, visible_rows: usize) void {
    const panel = &editor.snippet_panel;
    const page: isize = @intCast(@max(1, visible_rows));
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        // Enter on an item and Escape hand the keyboard back, F2 and
        // Delete open a dialog: the rest of the input is not the panel's.
        if (!snippetsTakesKeys(editor)) break;
        const key = switch (e.evt) {
            .key => |key| key,
            .text => |te| {
                switch (te.action) {
                    .value => |val| {
                        // `selected` = uncommitted IME composition.
                        if (val.txt.len == 0 or val.selected) continue;
                        e.handle(@src(), wd);
                        // Windows also types a " " for a Ctrl+Space chord,
                        // which the keybind map already ran.
                        if (win_ui.swallow_space and std.mem.eql(u8, val.txt, " ")) {
                            win_ui.swallow_space = false;
                            continue;
                        }
                        editor.snippetsFilterAppend(val.txt);
                        _ = editor.syncSnippetPanel();
                        // The rows changed under the pointer: the
                        // selection (the first match) drives the preview.
                        snippets_hover_row = null;
                    },
                    else => {},
                }
                continue;
            },
            else => continue,
        };
        if (key.action != .down and key.action != .repeat) continue;
        if (hasCommandMod(key.mod)) continue;
        switch (key.code) {
            .up => panel.move(-1),
            .down => panel.move(1),
            .page_up => panel.move(-page),
            .page_down => panel.move(page),
            .home => panel.home(),
            .end => panel.end(),
            // Left and Right can close or open a group: the next key
            // moves over the rebuilt rows.
            .left => {
                panel.left(editor.allocator);
                _ = editor.syncSnippetPanel();
            },
            .right => {
                panel.right(editor.allocator);
                _ = editor.syncSnippetPanel();
            },
            .backspace => {
                editor.snippetsFilterBackspace();
                _ = editor.syncSnippetPanel();
            },
            .enter => {
                // Handled before the insert: the pane that gets the
                // keyboard must not see it too.
                e.handle(@src(), wd);
                snippets_hover_row = null;
                const row = panel.rowAt(panel.selected) orelse continue;
                if (row.kind == .item) {
                    snippetsInsert(editor, panel.selected);
                } else {
                    editor.activateSnippetRow(panel.selected);
                }
                continue;
            },
            .escape => {
                e.handle(@src(), wd);
                // A filter is cleared first, and the panel keeps the
                // keyboard; the rows come back around the selection.
                if (editor.snippetsFilterClear()) {
                    _ = editor.syncSnippetPanel();
                    snippets_hover_row = null;
                    continue;
                }
                _ = editor.takeKeyboardFocus(.pane);
                filetree_release_focus = true;
                // A pane drawn before the panel takes it on the next frame.
                dvui.refresh(null, @src(), null);
                continue;
            },
            // A dialog opens (the snippet form, the delete question):
            // handled first, so it does not see the key too. A held key's
            // repeat does nothing — Delete would ask again the moment the
            // question was answered.
            .f2, .delete => {
                e.handle(@src(), wd);
                if (key.action != .down) continue;
                snippets_hover_row = null;
                if (key.code == .f2) editor.snippetPanelEdit() else editor.snippetPanelDelete();
                continue;
            },
            .tab => {},
            else => continue,
        }
        e.handle(@src(), wd);
        // The selection drives the preview again.
        snippets_hover_row = null;
    }
}

/// Right-click context menu for the Snippets panel, about the selected row
/// (the right press selected the row under it, handleSnippetsMouse): on a
/// snippet of my-snippets.lua Edit and Delete, on any other snippet Copy
/// to My Snippets — F2 and Delete do the same from the keyboard — then, on
/// any row, dock the panel on the other side (persisted, like the tree's
/// side).
fn snippetsContextMenu(editor: *Editor, area: dvui.Rect.Physical) void {
    const ctext = dvui.context(@src(), .{ .rect = area }, .{});
    defer ctext.deinit();

    if (ctext.activePoint()) |cp| {
        var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{});
        defer fw.deinit();

        // These open a dialog: the snippet form, or the delete question.
        const panel = &editor.snippet_panel;
        const defs = editor.snippets.items.items;
        const selected_def: ?u32 = if (panel.rowAt(panel.selected)) |row| (if (row.kind == .item and row.def < defs.len) row.def else null) else null;
        if (selected_def) |def| {
            if (snippet_file.isMine(&defs[def])) {
                if (dvui.menuItemLabel(@src(), "Edit Snippet…      F2", .{}, .{ .expand = .horizontal, .tag = "snippets_menu_edit" }) != null) {
                    editor.startSnippetEdit(def);
                    fw.close();
                }
                if (dvui.menuItemLabel(@src(), "Delete Snippet     Del", .{}, .{ .expand = .horizontal, .tag = "snippets_menu_delete" }) != null) {
                    editor.startSnippetDelete(def);
                    fw.close();
                }
            } else if (dvui.menuItemLabel(@src(), "Copy to My Snippets…   F2", .{}, .{ .expand = .horizontal, .tag = "snippets_menu_copy" }) != null) {
                editor.startSnippetCopy(def);
                fw.close();
            }
        }

        const other: Editor.FiletreeSide = if (editor.snippetsSide() == .left) .right else .left;
        const side_label: []const u8 = if (other == .left) "Move Snippets to Left" else "Move Snippets to Right";
        if (dvui.menuItemLabel(@src(), side_label, .{}, .{ .expand = .horizontal }) != null) {
            editor.snippets_side = other;
            lua_settings.writeStringSettingToFile("snippets_side", @tagName(other)) catch {};
            fw.close();
        }
    }
}

/// "Delete snippet" question (mode .snippet_delete_confirm), modelled on
/// filetreeDeleteDialog: a modal dialog declared from modalDialogs before
/// the panes, so its buttons see their clicks first. Keys go through the
/// modal key path (handleSnippetDeleteKeyGui): only `y`, or the Delete
/// button, deletes. It takes no text, and swallows what comes: the
/// answering letter's text event follows its key, and once the question
/// is answered it would land in the panel's filter (the panel keeps the
/// keyboard throughout).
fn snippetDeleteDialog(editor: *Editor) void {
    if (!build_options.has_gui) return;
    var float = dvui.floatingWindow(@src(), .{ .modal = true }, .{ .min_size_content = .{ .w = 340 } });
    defer {
        float.deinit();
        // A button answered: the base window takes the keyboard back. Only
        // after deinit — inside the dialog, "the current subwindow" is the
        // dialog itself.
        if (editor.mode != .snippet_delete_confirm) dvui.focusSubwindow(null, null);
    }
    float.dragAreaSet(dvui.windowHeader("Delete snippet", "", null));

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(8) });
    defer vbox.deinit();
    for (dvui.events()) |*e| {
        if (!e.handled and e.evt == .text) e.handle(@src(), vbox.data());
    }

    // The snippet's name; its command when a reload took it away meanwhile.
    const name: []const u8 = if (editor.snippet_delete_target) |command|
        (if (editor.snippets.command(command)) |def| def.description else command)
    else
        "";
    var buf: [600]u8 = undefined;
    const question = std.fmt.bufPrint(&buf, "Delete \"{s}\" from my-snippets.lua?", .{name}) catch "Delete this snippet from my-snippets.lua?";
    dvui.labelNoFmt(@src(), question, .{}, .{});
    dvui.labelNoFmt(@src(), "Press y to delete; Enter, n or Esc cancels.", .{}, .{
        .color_text = toDvui(editor.theme.overlay_hint),
    });

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 1.0,
        .padding = .{ .x = 0, .y = 8, .w = 0, .h = 0 },
    });
    defer hbox.deinit();
    if (dvui.button(@src(), "Cancel", .{}, .{ .tag = "snippet_delete_cancel" })) {
        editor.cancelSnippetDelete();
    }
    if (dvui.button(@src(), "Delete", .{}, .{ .tag = "snippet_delete_button" })) {
        editor.applySnippetDelete();
    }
}

/// The main editor text editing pane — custom line-by-line rendering.
/// No TextLayoutWidget or ScrollArea; we own rendering, scrolling, and input.
/// Double-click detection for search result rows.
var search_last_click_ns: i128 = 0;
var search_last_click_idx: usize = std.math.maxInt(usize);
/// Grouped display list (file headers + match rows), rebuilt per frame.
const SearchDispEntry = union(enum) {
    header: struct { path_idx: u32, count: u32 },
    match: usize,
};
var search_disp: std.ArrayList(SearchDispEntry) = .empty;
/// Results viewport scroll, in display rows.
var search_scroll_rows: usize = 0;
/// Last selection scrolled into view (wheel browsing must not snap back).
var search_last_sel: usize = std.math.maxInt(usize);
/// Collapsed file groups (path_idx set); cleared per search generation.
var search_collapsed: std.AutoHashMapUnmanaged(u32, void) = .empty;
var search_gen_seen: u64 = std.math.maxInt(u64);
/// Display index of the sticky (pinned) header drawn last frame, if any —
/// clicks on the first result row toggle it instead of the row beneath.
var search_sticky: ?usize = null;

/// Docked workspace search & replace panel (bottom strip), VS Code-style:
/// bordered input boxes with placeholders and inline Aa/W toggle chips,
/// results grouped under file headers (icon + name + dir + count) with the
/// match highlighted inside each excerpt. It takes keys while it owns the
/// keyboard (Editor.keyboardOwner() == .search — same model as the file
/// tree); global ctrl/fkey chords are handled by frame()'s dispatcher
/// before this runs (the clipboard ones through Editor.panelAction).
fn searchPanelGui(editor: *Editor) void {
    if (!build_options.has_gui) return;
    const sp = &editor.search;

    // New search: collapsed-file set and viewport are stale — reset.
    if (sp.generation != search_gen_seen) {
        search_gen_seen = sp.generation;
        search_collapsed.clearRetainingCapacity();
        search_scroll_rows = 0;
        search_sticky = null;
    }

    var pbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .style = .content,
        .min_size_content = .{ .h = 324 },
        .name = "search_panel",
    });
    defer pbox.deinit();

    const wd = pbox.data();
    const rs = wd.contentRectScale();
    const scale = rs.s;
    const area = rs.r;
    if (area.w <= 0 or area.h <= 0) return;
    const render_rs: dvui.RectScale = .{ .r = area, .s = scale };

    const font = dvui.Font.theme(.mono);
    const lh = font.lineHeight() * scale;
    const pad: f32 = 8 * scale;
    const gap: f32 = 4 * scale;
    const box_h = lh + 6 * scale;
    const row_h = lh + 3 * scale;
    const box_w = @min(area.w - pad * 2, 520 * scale);
    const half_w = (box_w - gap) / 2;

    const fg = toDvui(editor.theme.text);
    // Secondary text blends the THEME text color toward the panel — a
    // fixed gray (gutter_text) was unreadable on the light theme.
    const dim = fg.opacity(0.55);
    const sel_bg = toDvui(editor.theme.selection);
    const accent = toDvui(editor.theme.cursor);
    const box_bg = toDvui(editor.theme.gutter_bg);

    // Geometry: search on row 1, replace + include share row 2,
    // exclude on row 3
    const search_y = area.y + pad;
    const row2_y = search_y + box_h + gap;
    const replace_x = area.x + pad;
    const filter_x = replace_x + half_w + gap;
    const row3_y = row2_y + box_h + gap;
    const status_y = row3_y + box_h + gap;
    const results_y = status_y + lh + gap;
    const rows_visible: usize = if (row_h > 0 and area.y + area.h > results_y)
        @intFromFloat(@floor((area.y + area.h - results_y) / row_h))
    else
        0;
    // Toggle chips, right-aligned inside the search box
    const chip_h = box_h - 6 * scale;
    const chip_w = 26 * scale;
    const chip_y = search_y + 3 * scale;
    const chip_word_x = area.x + pad + box_w - chip_w - 4 * scale;
    const chip_case_x = chip_word_x - chip_w - 4 * scale;

    // NOTE: mouse clicks below map rows via LAST frame's display list
    // (search_disp) — the list is rebuilt AFTER input handling, because
    // input can restart the search and free/shrink the match lists the
    // display entries index into. Drawing from a pre-input list crashed
    // on exactly that (stale index out of bounds).

    // --- Mouse ---
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        const inside = me.p.x >= area.x and me.p.x <= area.x + area.w and
            me.p.y >= area.y and me.p.y <= area.y + area.h;
        switch (me.action) {
            .press => {
                if (!inside or me.button != .left) continue;
                e.handle(@src(), wd);
                _ = editor.takeKeyboardFocus(.search);
                // Toggle chips (inside the search box) first
                if (me.p.y >= chip_y and me.p.y < chip_y + chip_h) {
                    if (me.p.x >= chip_case_x and me.p.x < chip_case_x + chip_w) {
                        sp.case_sensitive = !sp.case_sensitive;
                        if (sp.query_len > 0) editor.searchStart();
                        continue;
                    }
                    if (me.p.x >= chip_word_x and me.p.x < chip_word_x + chip_w) {
                        sp.whole_word = !sp.whole_word;
                        if (sp.query_len > 0) editor.searchStart();
                        continue;
                    }
                }
                const in_box_x = me.p.x >= area.x + pad and me.p.x <= area.x + pad + box_w;
                if (in_box_x and me.p.y >= search_y and me.p.y < search_y + box_h) {
                    sp.field = .query;
                } else if (in_box_x and me.p.y >= row2_y and me.p.y < row2_y + box_h) {
                    sp.field = if (me.p.x < filter_x) .replace else .filter;
                } else if (in_box_x and me.p.y >= row3_y and me.p.y < row3_y + box_h and me.p.x < filter_x) {
                    sp.field = .exclude;
                } else if (me.p.y >= results_y) {
                    const row: usize = @intFromFloat(@floor((me.p.y - results_y) / row_h));
                    var disp_idx = search_scroll_rows + row;
                    // The sticky header overlays the first result row —
                    // clicks there act on it, not on the row beneath.
                    if (row == 0) {
                        if (search_sticky) |sidx| disp_idx = sidx;
                    }
                    if (disp_idx < search_disp.items.len) {
                        sp.field = .results;
                        switch (search_disp.items[disp_idx]) {
                            .header => |h| {
                                // Toggle collapse for this file group
                                if (search_collapsed.contains(h.path_idx)) {
                                    _ = search_collapsed.remove(h.path_idx);
                                } else {
                                    search_collapsed.put(editor.allocator, h.path_idx, {}) catch {};
                                }
                            },
                            .match => |mi| {
                                // Last-frame index — bounds-check against
                                // the current list before using it.
                                if (mi >= sp.matches.items.len) continue;
                                const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
                                const dbl = mi == search_last_click_idx and
                                    (now_ns - search_last_click_ns) < 400 * std.time.ns_per_ms;
                                sp.selected = mi;
                                search_last_click_ns = now_ns;
                                search_last_click_idx = mi;
                                if (dbl) {
                                    editor.searchOpenSelected();
                                    win_ui.scroll_pinned = false;
                                }
                            },
                        }
                    }
                }
            },
            .wheel_y => |delta| {
                if (!inside) continue;
                e.handle(@src(), wd);
                const dr: i32 = @intFromFloat(@round(-delta / dvui.scroll_speed * 3));
                const max_top: i64 = @intCast(search_disp.items.len -| rows_visible);
                const nt = @as(i64, @intCast(search_scroll_rows)) + dr;
                search_scroll_rows = @intCast(@max(0, @min(nt, max_top)));
            },
            else => {},
        }
    }

    // --- Keys/text while the panel owns the keyboard (read after the
    //     clicks above: a click on the panel takes it) ---
    if (searchTakesKeys(editor)) {
        handleSearchKeysGui(editor, wd);
        // Still the owner after the keys (Escape hides the panel)?
        if (searchTakesKeys(editor)) dvui.wantTextInput(area.toNatural());
    }
    const focused = editor.keyboardOwner() == .search;

    // --- Rebuild the grouped display list AFTER all input (input can
    //     restart the search and replace the match lists) ---
    search_disp.clearRetainingCapacity();
    {
        var last_path: ?u32 = null;
        var hdr_idx: usize = 0;
        for (sp.matches.items, 0..) |m, i| {
            if (last_path == null or last_path.? != m.path_idx) {
                hdr_idx = search_disp.items.len;
                search_disp.append(editor.allocator, .{ .header = .{ .path_idx = m.path_idx, .count = 0 } }) catch break;
                last_path = m.path_idx;
            }
            // Collapsed groups keep their header (and full count) only
            if (!search_collapsed.contains(m.path_idx)) {
                search_disp.append(editor.allocator, .{ .match = i }) catch break;
            }
            search_disp.items[hdr_idx].header.count += 1;
        }
    }
    // Scroll the newly selected match into view (but let the wheel roam)
    if (rows_visible > 0 and sp.selected != search_last_sel) {
        search_last_sel = sp.selected;
        for (search_disp.items, 0..) |ent, r| {
            if (ent == .match and ent.match == sp.selected) {
                if (r < search_scroll_rows + 1) search_scroll_rows = r -| 1;
                if (r >= search_scroll_rows + rows_visible) search_scroll_rows = r - rows_visible + 1;
                break;
            }
        }
    }
    if (search_scroll_rows >= search_disp.items.len) search_scroll_rows = search_disp.items.len -| 1;

    // --- Draw: input boxes + chips ---
    drawSearchBox(font, render_rs, area.x + pad, search_y, box_w, box_h, scale, "Search", sp.query(), focused and sp.field == .query, fg, dim, accent, box_bg);
    drawSearchBox(font, render_rs, replace_x, row2_y, half_w, box_h, scale, "Replace", sp.replacement(), focused and sp.field == .replace, fg, dim, accent, box_bg);
    drawSearchBox(font, render_rs, filter_x, row2_y, half_w, box_h, scale, "files to include", sp.filter(), focused and sp.field == .filter, fg, dim, accent, box_bg);
    drawSearchBox(font, render_rs, replace_x, row3_y, half_w, box_h, scale, "files to exclude", sp.exclude(), focused and sp.field == .exclude, fg, dim, accent, box_bg);
    drawSearchChip(font, render_rs, chip_case_x, chip_y, chip_w, chip_h, scale, "Aa", sp.case_sensitive, fg, dim, sel_bg);
    drawSearchChip(font, render_rs, chip_word_x, chip_y, chip_w, chip_h, scale, "W", sp.whole_word, fg, dim, sel_bg);

    // --- Status / confirm row ---
    var sbuf: [300]u8 = undefined;
    if (sp.confirm_armed) {
        const tgt = sp.replaceTargets(editor);
        const txt = std.fmt.bufPrint(&sbuf, "Replace {d} match(es)? [A]ll ({d} open + {d} on disk — disk is NOT undoable) / [O]pen docs only / [C]ancel", .{ sp.matches.items.len, tgt.open, tgt.disk }) catch "Replace? [A]ll / [O]pen only / [C]ancel";
        renderOverlayText(font, txt, area.x + pad, status_y, render_rs, fg);
    } else {
        const busy: []const u8 = if (sp.searching) "  searching…" else "";
        const cap: []const u8 = if (sp.capped) "  (capped at 2000)" else "";
        const main_txt = std.fmt.bufPrint(&sbuf, "{d} results in {d} files, {d} skipped{s}{s}", .{ sp.matches.items.len, sp.resultFileCount(), sp.files_skipped, busy, cap }) catch "";
        renderOverlayText(font, main_txt, area.x + pad, status_y, render_rs, fg);
        const main_w = font.textSize(main_txt).w * scale;
        renderOverlayText(font, "   Alt+C case · Alt+W word · Tab fields · Enter on Replace = replace all", area.x + pad + main_w, status_y, render_rs, dim);
    }

    // --- Results: file headers + highlighted match rows ---
    if (rows_visible == 0 or search_disp.items.len == 0) return;

    const prev_clip = dvui.clip(area);
    defer dvui.clipSet(prev_clip);

    // Sticky header: decided BEFORE drawing — row 0 renders the pinned
    // header IN PLACE OF the row beneath it (never painted over content;
    // fills don't reliably cover already-drawn text).
    search_sticky = null;
    if (search_scroll_rows < search_disp.items.len and
        search_disp.items[@min(search_scroll_rows, search_disp.items.len - 1)] != .header)
    {
        var hi: usize = @min(search_scroll_rows, search_disp.items.len - 1);
        while (true) {
            if (search_disp.items[hi] == .header) {
                search_sticky = hi;
                break;
            }
            if (hi == 0) break;
            hi -= 1;
        }
    }

    var r: usize = 0;
    while (r < rows_visible) : (r += 1) {
        const ry = results_y + @as(f32, @floatFromInt(r)) * row_h;
        if (r == 0) {
            if (search_sticky) |si| {
                var sticky_bg = box_bg;
                sticky_bg.a = 255;
                const bar: dvui.Rect.Physical = .{ .x = area.x, .y = ry, .w = area.w, .h = row_h };
                bar.fill(.{}, .{ .color = sticky_bg, .fade = 1.0 });
                const sep_line: dvui.Rect.Physical = .{ .x = area.x, .y = ry + row_h - @max(1.0, 1 * scale), .w = area.w, .h = @max(1.0, 1 * scale) };
                sep_line.fill(.{}, .{ .color = dim, .fade = 1.0 });
                drawSearchHeaderRow(editor, font, render_rs, area, pad, scale, row_h, ry, search_disp.items[si].header, fg, dim);
                continue;
            }
        }
        const disp_idx = search_scroll_rows + r;
        if (disp_idx >= search_disp.items.len) break;
        switch (search_disp.items[disp_idx]) {
            .header => |h| {
                drawSearchHeaderRow(editor, font, render_rs, area, pad, scale, row_h, ry, h, fg, dim);
            },
            .match => |mi| {
                if (mi >= sp.matches.items.len) continue;
                const m = sp.matches.items[mi];
                const is_sel = mi == sp.selected;
                if (is_sel) {
                    const bar: dvui.Rect.Physical = .{ .x = area.x, .y = ry, .w = area.w, .h = row_h };
                    bar.fill(.{}, .{ .color = sel_bg, .fade = 1.0 });
                }
                var x = area.x + pad + 18 * scale;
                var lbuf: [16]u8 = undefined;
                const line_txt = std.fmt.bufPrint(&lbuf, "{d}", .{m.line + 1}) catch "";
                renderOverlayText(font, line_txt, x, ry, render_rs, dim);
                x += font.textSize("00000").w * scale;

                // Fit the excerpt to the row, VS Code style: cut with "…"
                // and shift the window so the match is always visible.
                const char_w = font.textSize("0").w * scale;
                const avail = area.x + area.w - pad - x;
                if (char_w <= 0 or avail < char_w * 8) continue;
                const max_chars: usize = @intFromFloat(@floor(avail / char_w));
                // Highlight THIS row's occurrence (col mapped through the
                // excerpt's trim offset); lines with several matches get one
                // row each, so first-occurrence-always looked like dupes.
                const hit_opt: ?usize = if (m.col >= m.excerpt_off and
                    (m.col - m.excerpt_off) + m.len <= m.excerpt.len)
                    m.col - m.excerpt_off
                else
                    null;
                var start: usize = 0;
                var end: usize = m.excerpt.len;
                var lead = false;
                var trail = false;
                if (m.excerpt.len > max_chars) {
                    var span = max_chars - 1;
                    trail = true;
                    if (hit_opt) |hit| {
                        const h_end = @min(hit + m.len, m.excerpt.len);
                        if (h_end > span) {
                            lead = true;
                            span = max_chars - 2;
                            start = h_end -| (span * 2 / 3);
                        }
                    }
                    end = @min(m.excerpt.len, start + span);
                    if (end == m.excerpt.len) trail = false;
                    start = text_input.floor(m.excerpt, start);
                    end = text_input.floor(m.excerpt, end);
                }
                if (lead) {
                    renderOverlayText(font, "…", x, ry, render_rs, dim);
                    x += char_w;
                }
                if (hit_opt) |hit| {
                    const h_end = @min(hit + m.len, m.excerpt.len);
                    const c_pre_end = std.math.clamp(hit, start, end);
                    const c_hit_end = std.math.clamp(h_end, start, end);
                    const pre = m.excerpt[start..c_pre_end];
                    const mid = m.excerpt[c_pre_end..c_hit_end];
                    const post = m.excerpt[c_hit_end..end];
                    if (pre.len > 0) {
                        renderOverlayText(font, pre, x, ry, render_rs, fg);
                        x += font.textSize(pre).w * scale;
                    }
                    if (mid.len > 0) {
                        const mid_w = font.textSize(mid).w * scale;
                        const hl: dvui.Rect.Physical = .{ .x = x - 1 * scale, .y = ry, .w = mid_w + 2 * scale, .h = row_h };
                        hl.fill(.{ .x = 2 * scale, .y = 2 * scale, .w = 2 * scale, .h = 2 * scale }, .{ .color = accent.opacity(0.35), .fade = 1.0 });
                        renderOverlayText(font, mid, x, ry, render_rs, fg);
                        x += mid_w;
                    }
                    if (post.len > 0) {
                        renderOverlayText(font, post, x, ry, render_rs, fg);
                        x += font.textSize(post).w * scale;
                    }
                } else {
                    const win = m.excerpt[start..end];
                    renderOverlayText(font, win, x, ry, render_rs, fg);
                    x += font.textSize(win).w * scale;
                }
                if (trail) {
                    renderOverlayText(font, "…", x, ry, render_rs, dim);
                }
            },
        }
    }
}

/// Move the result selection over VISIBLE matches only — matches inside
/// collapsed file groups are skipped (collapse is GUI view state, so the
/// core moveSelection can't know about it). A selection already inside a
/// folded group escapes to the next visible match in the given direction.
fn searchMoveVisible(editor: *Editor, down: bool, step: usize) void {
    const sp = &editor.search;
    const count = sp.matches.items.len;
    if (count == 0) return;
    var cur = @min(sp.selected, count - 1);
    var moved: usize = 0;
    while (moved < step) {
        var i = cur;
        const next: ?usize = blk: {
            while (true) {
                if (down) {
                    if (i + 1 >= count) break :blk null;
                    i += 1;
                } else {
                    if (i == 0) break :blk null;
                    i -= 1;
                }
                if (!search_collapsed.contains(sp.matches.items[i].path_idx)) break :blk i;
            }
        };
        if (next) |n| {
            cur = n;
            moved += 1;
        } else break;
    }
    sp.selected = cur;
}

/// One file-group header row: collapse chevron, type glyph, name, dim
/// directory, right-aligned match count. Used for list rows AND the
/// sticky pinned header.
fn drawSearchHeaderRow(editor: *Editor, font: dvui.Font, render_rs: dvui.RectScale, area: dvui.Rect.Physical, pad: f32, scale: f32, row_h: f32, ry: f32, h: anytype, fg: dvui.Color, dim: dvui.Color) void {
    const sp = &editor.search;
    if (h.path_idx >= sp.paths.items.len) return;
    const path = sp.paths.items[h.path_idx];
    const sep = std.mem.lastIndexOfAny(u8, path, "/\\");
    const base = if (sep) |s| path[s + 1 ..] else path;
    const dir = if (sep) |s| path[0..s] else "";
    const collapsed = search_collapsed.contains(h.path_idx);
    // Collapse chevron
    const chev_sz = @min(row_h - 4 * scale, 12 * scale);
    const chev: []const u8 = if (collapsed) (icons.tvg(.chevron_right) orelse dvui.entypo.chevron_small_right) else (icons.tvg(.chevron_down) orelse dvui.entypo.chevron_small_down);
    renderIconTinted(if (collapsed) "srch_chev" else "srch_chev_open", chev, .{
        .x = area.x + pad,
        .y = ry + (row_h - chev_sz) / 2,
        .w = chev_sz,
        .h = chev_sz,
    }, scale, dim);
    // File-type glyph (same nerdfont machinery as the tree)
    const icon_x = area.x + pad + 14 * scale;
    const fi = editor.filetreeIconFor(base, false);
    const tint: dvui.Color = if (fi.color) |c| .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 } else fg.opacity(0.75);
    const glyph = fi.nerd orelse fileicons.nerdGlyph(fi.kind);
    const glyph_font = font.withSize(font.size * 0.85 * iconFamilyScale(glyph));
    const glyph_dy = (row_h - glyph_font.lineHeight() * scale) / 2;
    renderOverlayText(glyph_font, glyph, icon_x, ry + glyph_dy, render_rs, tint);
    const name_x = icon_x + 18 * scale;
    renderOverlayText(font, base, name_x, ry, render_rs, fg);
    if (dir.len > 0) {
        const base_w = font.textSize(base).w * scale;
        renderOverlayText(font, dir, name_x + base_w + 8 * scale, ry, render_rs, dim);
    }
    var cbuf: [16]u8 = undefined;
    const count_txt = std.fmt.bufPrint(&cbuf, "{d}", .{h.count}) catch "";
    const count_w = font.textSize(count_txt).w * scale;
    renderOverlayText(font, count_txt, area.x + area.w - pad - count_w, ry, render_rs, dim);
}

/// Bordered input box with placeholder text and a cursor when active.
fn drawSearchBox(font: dvui.Font, rs: dvui.RectScale, x: f32, y: f32, w: f32, h: f32, scale: f32, placeholder: []const u8, value: []const u8, active: bool, fg: dvui.Color, dim: dvui.Color, accent: dvui.Color, box_bg: dvui.Color) void {
    const rad = 3 * scale;
    const border: dvui.Rect.Physical = .{ .x = x, .y = y, .w = w, .h = h };
    border.fill(.{ .x = rad, .y = rad, .w = rad, .h = rad }, .{ .color = if (active) accent else dim, .fade = 1.0 });
    const bw = @max(1.0, 1 * scale);
    const inner: dvui.Rect.Physical = .{ .x = x + bw, .y = y + bw, .w = w - bw * 2, .h = h - bw * 2 };
    inner.fill(.{ .x = rad, .y = rad, .w = rad, .h = rad }, .{ .color = box_bg, .fade = 1.0 });

    const lh = font.lineHeight() * rs.s;
    const ty = y + (h - lh) / 2;
    const tx = x + 6 * scale;
    const prev_clip = dvui.clip(inner);
    defer dvui.clipSet(prev_clip);
    if (value.len == 0 and !active) {
        renderOverlayText(font, placeholder, tx, ty, rs, dim);
        return;
    }
    var buf: [300]u8 = undefined;
    const cursor: []const u8 = if (active) "_" else "";
    const txt = std.fmt.bufPrint(&buf, "{s}{s}", .{ value, cursor }) catch value;
    renderOverlayText(font, txt, tx, ty, rs, fg);
}

/// Small toggle chip (Aa / W) inside the search box.
fn drawSearchChip(font: dvui.Font, rs: dvui.RectScale, x: f32, y: f32, w: f32, h: f32, scale: f32, label: []const u8, on: bool, fg: dvui.Color, dim: dvui.Color, sel_bg: dvui.Color) void {
    const rad = 3 * scale;
    if (on) {
        const chip: dvui.Rect.Physical = .{ .x = x, .y = y, .w = w, .h = h };
        chip.fill(.{ .x = rad, .y = rad, .w = rad, .h = rad }, .{ .color = sel_bg, .fade = 1.0 });
    }
    const lh = font.lineHeight() * rs.s;
    const tw = font.textSize(label).w * rs.s;
    renderOverlayText(font, label, x + (w - tw) / 2, y + (h - lh) / 2, rs, if (on) fg else dim);
}

/// Keys while the search panel owns the keyboard (mirrors the TUI handler;
/// ctrl/fkey chords were already taken by frame()'s global dispatcher —
/// the clipboard and word-delete ones through Editor.panelAction).
fn handleSearchKeysGui(editor: *Editor, wd: *dvui.WidgetData) void {
    const sp = &editor.search;
    // The letter that answered the Replace prompt: its text event must not
    // also land in the Replace field.
    var answer_letter: ?u8 = null;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        // Escape hides the panel, Enter on a result opens it: the rest of
        // the input is not the panel's.
        if (!searchTakesKeys(editor)) break;
        switch (e.evt) {
            .key => |key| {
                if (key.action != .down and key.action != .repeat) continue;
                if (sp.confirm_armed) {
                    // Only a plain letter answers (Ctrl+A is select-all,
                    // never "replace all on disk").
                    if (hasCommandMod(key.mod)) continue;
                    switch (key.code) {
                        .a => {
                            e.handle(@src(), wd);
                            editor.searchExecuteReplace(.all);
                            answer_letter = 'a';
                        },
                        .o => {
                            e.handle(@src(), wd);
                            editor.searchExecuteReplace(.open_only);
                            answer_letter = 'o';
                        },
                        .c, .escape => {
                            e.handle(@src(), wd);
                            sp.confirm_armed = false;
                            if (key.code == .c) answer_letter = 'c';
                        },
                        else => {},
                    }
                    continue;
                }
                // Global chords — Alt+C / Alt+W among them: find_toggle_case
                // and find_toggle_whole_word flip the panel's two buttons
                // while it has the keyboard.
                if (key.mod.control() or key.mod.alt() or key.mod.command()) continue;
                switch (key.code) {
                    .escape => {
                        e.handle(@src(), wd);
                        editor.searchHide();
                    },
                    .tab => {
                        e.handle(@src(), wd);
                        sp.cycleField();
                    },
                    .enter => {
                        e.handle(@src(), wd);
                        switch (sp.field) {
                            .query, .filter, .exclude => editor.searchStart(),
                            .replace => {
                                editor.searchArmReplace();
                            },
                            .results => {
                                editor.searchOpenSelected();
                                win_ui.scroll_pinned = false;
                            },
                        }
                    },
                    .up => {
                        e.handle(@src(), wd);
                        searchMoveVisible(editor, false, 1);
                    },
                    .down => {
                        e.handle(@src(), wd);
                        searchMoveVisible(editor, true, 1);
                    },
                    .page_up => {
                        e.handle(@src(), wd);
                        searchMoveVisible(editor, false, 8);
                    },
                    .page_down => {
                        e.handle(@src(), wd);
                        searchMoveVisible(editor, true, 8);
                    },
                    .backspace => {
                        e.handle(@src(), wd);
                        sp.backspace();
                    },
                    else => {},
                }
            },
            .text => |te| {
                switch (te.action) {
                    .value => |val| {
                        // `selected` = uncommitted IME composition.
                        if (val.txt.len == 0 or val.selected) continue;
                        e.handle(@src(), wd);
                        if (answer_letter) |letter| {
                            answer_letter = null;
                            if (val.txt.len == 1 and std.ascii.toLower(val.txt[0]) == letter) continue;
                        }
                        sp.appendText(val.txt);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

// ===========================================================================
// The find bar (Ctrl+F): a row under the panes that stays open
// ===========================================================================

/// The bar's toggle buttons, in the order they are drawn: Aa and W sit in
/// the text box, All beside it. `action` is the command a hover hint looks
/// up the key of.
const find_bar_buttons = [_]struct { which: find_bar_mod.Toggle, label: []const u8, action: []const u8 }{
    .{ .which = .match_case, .label = "Aa", .action = "find_toggle_case" },
    .{ .which = .whole_word, .label = "W", .action = "find_toggle_whole_word" },
    .{ .which = .highlight_all, .label = "All", .action = "find_toggle_highlight_all" },
};

/// The bar as drawn this frame, in physical pixels: where its box and
/// buttons are (clicks, hover hints and tests go through it). It is shown
/// in one window at a time, so one record serves; null while no window
/// draws it.
const FindBarGeom = struct {
    area: dvui.Rect.Physical = .{},
    box: dvui.Rect.Physical = .{},
    /// The part of the box that shows text (left of its Aa and W buttons).
    text: dvui.Rect.Physical = .{},
    /// In `find_bar_buttons` order.
    toggles: [find_bar_buttons.len]dvui.Rect.Physical = @splat(.{}),
    count: dvui.Rect.Physical = .{},
    prev: dvui.Rect.Physical = .{},
    next: dvui.Rect.Physical = .{},
    close: dvui.Rect.Physical = .{},
    scale: f32 = 1,
};
var find_bar_geom: ?FindBarGeom = null;
/// A left press landed in the box: the drag after it selects there.
var find_bar_drag: bool = false;
/// Double / triple click in the box (the word, then everything).
var find_bar_click_ns: i128 = 0;
var find_bar_click_offset: usize = 0;
var find_bar_click_count: u8 = 0;
/// The box's caret blinks from its last move, in a pane's rhythm; it shows
/// at once when the box takes the keyboard.
var find_bar_blink_ns: i128 = 0;
var find_bar_blink_caret: usize = std.math.maxInt(usize);
var find_bar_had_keys: bool = false;

/// Key and text events go to the find bar's box (in the window that shows it).
fn findBarTakesKeys(editor: *const Editor) bool {
    return guiMode(editor) == .normal and editor.keyboardOwner() == .find_bar;
}

/// Where everything sits in the bar's content rect: `Find`, the box (as
/// wide as the row allows, 520 at most) with Aa and W at its right end,
/// then All, the count, previous and next; close at the far right.
fn findBarLayout(font: dvui.Font, area: dvui.Rect.Physical, scale: f32) FindBarGeom {
    const pad = 8 * scale;
    const gap = 6 * scale;
    const box_h = font.lineHeight() * scale + 6 * scale;
    const y = area.y + (area.h - box_h) / 2;
    const chip_w = 26 * scale;
    const all_w = font.textSize("All").w * scale + 12 * scale;
    const count_w = font.textSize("100000+ found").w * scale;
    const btn = box_h;
    var g: FindBarGeom = .{ .area = area, .scale = scale };
    var x = area.x + pad + font.textSize("Find").w * scale + gap;
    const after = gap + all_w + gap + count_w + gap + btn + 2 * scale + btn + gap * 2 + btn + pad;
    const box_w = std.math.clamp(area.x + area.w - x - after, 80 * scale, 520 * scale);
    g.box = .{ .x = x, .y = y, .w = box_w, .h = box_h };
    const chip_y = y + 3 * scale;
    const chip_h = box_h - 6 * scale;
    const word_x = x + box_w - chip_w - 4 * scale;
    const case_x = word_x - chip_w - 4 * scale;
    g.toggles[0] = .{ .x = case_x, .y = chip_y, .w = chip_w, .h = chip_h };
    g.toggles[1] = .{ .x = word_x, .y = chip_y, .w = chip_w, .h = chip_h };
    const text_x = x + 6 * scale;
    g.text = .{ .x = text_x, .y = y, .w = @max(0, case_x - 4 * scale - text_x), .h = box_h };
    x += box_w + gap;
    g.toggles[2] = .{ .x = x, .y = y, .w = all_w, .h = box_h };
    x += all_w + gap;
    g.count = .{ .x = x, .y = y, .w = count_w, .h = box_h };
    x += count_w + gap;
    g.prev = .{ .x = x, .y = y, .w = btn, .h = box_h };
    x += btn + 2 * scale;
    g.next = .{ .x = x, .y = y, .w = btn, .h = box_h };
    g.close = .{ .x = area.x + area.w - pad - btn, .y = y, .w = btn, .h = box_h };
    return g;
}

/// The find bar of the current window: hand-painted like the search
/// panel, with a real text box (find_bar.zig holds the state and the
/// searching). It takes keys while its box owns the keyboard; the Ctrl /
/// Alt / F-key chords were dispatched before it runs — the clipboard, word
/// and undo ones into the box through Editor.panelAction.
fn findBarGui(editor: *Editor) void {
    if (!build_options.has_gui) return;
    const fb = &editor.find_bar;
    const font = dvui.Font.theme(.mono);
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .style = .content,
        .min_size_content = .{ .h = font.lineHeight() + 14 },
        .name = "find_bar",
    });
    defer bar.deinit();

    const wd = bar.data();
    const rs = wd.contentRectScale();
    if (rs.r.w <= 0 or rs.r.h <= 0) return;
    const g = findBarLayout(font, rs.r, rs.s);
    find_bar_geom = g;

    findBarMouse(editor, wd, font, g);
    if (fb.visible and findBarTakesKeys(editor)) findBarKeys(editor, wd);
    // Closed by its button or Escape: nothing to draw (the row goes next frame).
    if (!fb.visible) {
        find_bar_geom = null;
        find_bar_drag = false;
        return;
    }
    if (findBarTakesKeys(editor)) dvui.wantTextInput(g.box.toNatural());
    findBarDraw(editor, font, .{ .r = rs.r, .s = rs.s }, g);
    findBarHints(editor, g);
}

/// Byte offset in the box's text under physical x `px`: the nearer edge of
/// the character there.
fn findBarOffsetAt(box: *const find_bar_mod.Needle, font: dvui.Font, g: FindBarGeom, px: f32) usize {
    const text = box.text();
    var at = @min(box.scroll, text.len);
    const target = (px - g.text.x) / g.scale;
    var x: f32 = 0;
    while (at < text.len) {
        const end = box.next(at);
        const w = font.textSize(text[at..end]).w;
        if (target < x + w / 2) break;
        x += w;
        at = end;
    }
    return at;
}

/// Clicks on the bar: any press gives its box the keyboard (the search
/// starts where the caret in the text is); a button acts, a press in the
/// box places the caret (Shift extends, a drag selects, a double-click
/// takes the word, a third click everything).
fn findBarMouse(editor: *Editor, wd: *dvui.WidgetData, font: dvui.Font, g: FindBarGeom) void {
    const fb = &editor.find_bar;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        if (!fb.visible) break;
        const me = e.evt.mouse;
        const inside = g.area.contains(me.p);
        switch (me.action) {
            .press => {
                // A new press ends a drag whose release never arrived.
                find_bar_drag = false;
                if (!inside or me.button != .left) continue;
                e.handle(@src(), wd);
                if (cur_win != editor.active_window) editor.focusWindow(cur_win);
                fb.focus(editor);
                // Under a prompt the click only says where the keyboard goes
                // afterwards, like a click on the file tree.
                if (guiMode(editor) != .normal) continue;
                win_ui.scroll_pinned = false;
                editor.dismissStatus();
                if (g.close.contains(me.p)) {
                    fb.close(editor);
                    continue;
                }
                if (g.prev.contains(me.p)) {
                    fb.step(editor, false);
                    continue;
                }
                if (g.next.contains(me.p)) {
                    fb.step(editor, true);
                    continue;
                }
                var toggled = false;
                for (find_bar_buttons, g.toggles) |button, rect| {
                    if (rect.contains(me.p)) {
                        fb.toggle(editor, button.which);
                        toggled = true;
                        break;
                    }
                }
                if (toggled or !g.box.contains(me.p)) continue;
                const offset = findBarOffsetAt(&fb.needle, font, g, me.p.x);
                const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
                const again = offset == find_bar_click_offset and now_ns - find_bar_click_ns < 400 * std.time.ns_per_ms;
                find_bar_click_count = if (again and find_bar_click_count < 3) find_bar_click_count + 1 else 1;
                find_bar_click_ns = now_ns;
                find_bar_click_offset = offset;
                if (me.mod.shift()) {
                    fb.needle.setCaret(offset, true);
                } else switch (find_bar_click_count) {
                    2 => fb.needle.selectWordAt(offset),
                    3 => fb.needle.selectAll(),
                    else => {
                        fb.needle.setCaret(offset, false);
                        find_bar_drag = true;
                    },
                }
            },
            .motion => {
                if (!find_bar_drag) continue;
                e.handle(@src(), wd);
                fb.needle.setCaret(findBarOffsetAt(&fb.needle, font, g, me.p.x), true);
            },
            .release => {
                if (me.button == .left) find_bar_drag = false;
            },
            .position => {
                if (inside) dvui.cursorSet(if (g.text.contains(me.p)) .ibeam else .arrow);
            },
            else => {},
        }
    }
}

/// Keys while the box owns the keyboard: Enter / Shift+Enter go to the next
/// / previous match, Escape closes the bar, Up / Down walk the earlier
/// searches, the arrows, Home / End, Backspace and Delete edit the box
/// (Shift selects), and typed text lands at its caret.
fn findBarKeys(editor: *Editor, wd: *dvui.WidgetData) void {
    const fb = &editor.find_bar;
    const box = &fb.needle;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        // Escape closed the bar: the rest of the input is not its.
        if (!findBarTakesKeys(editor)) break;
        switch (e.evt) {
            .key => |key| {
                if (key.action != .down and key.action != .repeat) continue;
                if (isModifierKey(key.code)) continue;
                if (hasCommandMod(key.mod)) continue; // dispatched globally
                const shift = key.mod.shift();
                switch (key.code) {
                    .escape, .enter, .up, .down, .left, .right, .home, .end, .backspace, .delete, .tab => {},
                    else => continue, // a text key: its text event follows
                }
                e.handle(@src(), wd);
                win_ui.scroll_pinned = false;
                editor.dismissStatus();
                switch (key.code) {
                    .escape => fb.close(editor),
                    .enter => fb.step(editor, !shift),
                    .up => fb.historyStep(editor, true),
                    .down => fb.historyStep(editor, false),
                    .left => box.moveLeft(shift),
                    .right => box.moveRight(shift),
                    .home => box.moveHome(shift),
                    .end => box.moveEnd(shift),
                    .backspace => if (box.backspace()) fb.edited(editor),
                    .delete => if (box.deleteForward()) fb.edited(editor),
                    // One box for now: Tab stays in it.
                    else => {},
                }
            },
            .text => |te| switch (te.action) {
                .value => |val| {
                    // `selected` = uncommitted IME composition.
                    if (val.txt.len == 0 or val.selected) continue;
                    e.handle(@src(), wd);
                    // Windows types a " " for Ctrl+Space; the chord already ran.
                    if (win_ui.swallow_space and std.mem.eql(u8, val.txt, " ")) {
                        win_ui.swallow_space = false;
                        continue;
                    }
                    win_ui.scroll_pinned = false;
                    if (box.insert(val.txt)) fb.edited(editor);
                },
                else => {},
            },
            else => {},
        }
    }
}

/// What fits a text box `max_w` logical pixels wide, for LineEdit.scrollToCaret.
const FindBarFit = struct { font: dvui.Font, max_w: f32 };

fn findBarFits(ctx: FindBarFit, piece: []const u8) bool {
    return ctx.font.textSize(piece).w <= ctx.max_w;
}

fn findBarDraw(editor: *Editor, font: dvui.Font, rs: dvui.RectScale, g: FindBarGeom) void {
    const fb = &editor.find_bar;
    const box = &fb.needle;
    const scale = g.scale;
    const focused = findBarTakesKeys(editor);
    const fg = toDvui(editor.theme.text);
    const dim = fg.opacity(0.55);
    const sel_bg = toDvui(editor.theme.selection);
    const accent = toDvui(editor.theme.cursor);
    const warn = toDvui(editor.theme.overlay_warn);
    const line_w = @max(1.0, scale);
    const rad = 3 * scale;
    const corners: dvui.Rect.Physical = .{ .x = rad, .y = rad, .w = rad, .h = rad };
    const lh = font.lineHeight() * scale;
    const text_y = g.box.y + (g.box.h - lh) / 2;

    const prev_clip = dvui.clip(g.area);
    defer dvui.clipSet(prev_clip);

    // A line between the panes and the bar.
    (dvui.Rect.Physical{ .x = g.area.x, .y = g.area.y, .w = g.area.w, .h = line_w }).fill(.{}, .{ .color = toDvui(editor.theme.panel_border), .fade = 1.0 });
    renderOverlayText(font, "Find", g.area.x + 8 * scale, text_y, rs, if (focused) fg else dim);

    const count = fb.count(editor);
    const none = box.len > 0 and count.total == 0;

    // The box: its edge in the caret color while it has the keyboard, the
    // whole box tinted when the text matches nothing.
    g.box.fill(corners, .{ .color = toDvui(editor.theme.gutter_bg), .fade = 1.0 });
    if (none) g.box.fill(corners, .{ .color = warn.opacity(0.2), .fade = 1.0 });
    g.box.stroke(corners, .{ .thickness = line_w, .color = if (none) warn else if (focused) accent else dim, .closed = true });

    // Its text, scrolled so the caret is in view (two pixels stay free for it).
    {
        const text_clip = dvui.clip(g.text);
        defer dvui.clipSet(text_clip);
        box.scrollToCaret(FindBarFit{ .font = font, .max_w = @max(0, g.text.w / scale - 2) }, findBarFits);
        const text = box.text();
        const first = @min(box.scroll, text.len);
        const shown = fitOverlayText(font, text[first..], g.text.w, scale);
        const last = first + shown.len;
        if (text.len == 0) {
            renderOverlayText(font, "Enter: next match · Shift+Enter: previous", g.text.x, text_y, rs, dim);
        } else {
            if (if (focused) box.selection() else null) |r| {
                const a = std.math.clamp(r.start, first, last);
                const b = std.math.clamp(r.end, first, last);
                const x0 = font.textSize(text[first..a]).w * scale;
                const x1 = font.textSize(text[first..b]).w * scale;
                if (x1 > x0) {
                    (dvui.Rect.Physical{ .x = g.text.x + x0, .y = g.box.y + 3 * scale, .w = x1 - x0, .h = g.box.h - 6 * scale }).fill(.{}, .{ .color = sel_bg, .fade = 1.0 });
                }
            }
            renderOverlayText(font, shown, g.text.x, text_y, rs, fg);
        }
        if (focused and box.caret >= first and box.caret <= last) {
            const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
            if (box.caret != find_bar_blink_caret or !find_bar_had_keys) {
                find_bar_blink_ns = now_ns;
                find_bar_blink_caret = box.caret;
            }
            const cycle = @mod(@divFloor(now_ns - find_bar_blink_ns, std.time.ns_per_ms), blink_interval_ms * 2);
            const blink_on = cycle < blink_interval_ms;
            if (blink_on) {
                const cx = g.text.x + font.textSize(text[first..box.caret]).w * scale;
                (dvui.Rect.Physical{ .x = cx, .y = g.box.y + 3 * scale, .w = @max(2.0, 2 * scale), .h = g.box.h - 6 * scale }).fill(.{}, .{ .color = accent, .fade = 1.0 });
            }
            // Wake up for the next blink instead of repainting all the time.
            const until: i128 = if (blink_on) blink_interval_ms - cycle else blink_interval_ms * 2 - cycle;
            const micros: i32 = @intCast(@max(until * 1000, 1000));
            dvui.animation(dvui.Id.extendId(null, @src(), 0), "_blink", .{ .start_time = micros, .end_time = micros + 1000 });
        }
    }
    find_bar_had_keys = focused;

    // The toggles: Aa and W in the box, All beside it with an edge of its own.
    for (find_bar_buttons, g.toggles, 0..) |button, rect, i| {
        const lit = fb.isOn(button.which);
        drawSearchChip(font, rs, rect.x, rect.y, rect.w, rect.h, scale, button.label, lit, fg, dim, sel_bg);
        if (i == 2 and !lit) rect.stroke(corners, .{ .thickness = line_w, .color = dim, .closed = true });
    }

    // "3 of 17" — in the warning color when there is nothing to count.
    var count_buf: [32]u8 = undefined;
    const count_txt = find_bar_mod.countLabel(count, box.len > 0, &count_buf);
    if (count_txt.len > 0) renderOverlayText(font, count_txt, g.count.x, text_y, rs, if (none) warn else if (count.current != null) fg else dim);

    // Previous, next, close.
    const icon_sz = @min(g.prev.h - 8 * scale, 14 * scale);
    const glyphs = [_]struct { rect: dvui.Rect.Physical, name: []const u8, tvg: []const u8 }{
        .{ .rect = g.prev, .name = "find_prev", .tvg = icons.tvg(.chevron_up) orelse dvui.entypo.chevron_small_up },
        .{ .rect = g.next, .name = "find_next", .tvg = icons.tvg(.chevron_down) orelse dvui.entypo.chevron_small_down },
        .{ .rect = g.close, .name = "find_close", .tvg = icons.tvg(.close) orelse dvui.entypo.cross },
    };
    for (glyphs) |glyph| {
        const is_close = glyph.rect.x == g.close.x;
        // The close glyph is drawn small inside its own frame.
        const sz = if (is_close) @min(glyph.rect.h - 2 * scale, icon_sz * 1.5) else icon_sz;
        renderIconTinted(glyph.name, glyph.tvg, .{
            .x = glyph.rect.x + (glyph.rect.w - sz) / 2,
            .y = glyph.rect.y + (glyph.rect.h - sz) / 2,
            .w = sz,
            .h = sz,
        }, scale, if (none and !is_close) dim else fg);
    }
}

/// "Match case (Alt+C)": `what`, then in brackets the key that is always
/// `fixed` and the key bound to `action` — whichever exist.
fn findBarHintText(editor: *const Editor, what: []const u8, fixed: []const u8, action: []const u8, buf: []u8) []const u8 {
    var key_buf: [keybind.max_combo_len]u8 = undefined;
    const bound = if (editor.keybinds.comboFor(action)) |combo| keybind.displayCombo(combo, &key_buf) else "";
    if (fixed.len == 0 and bound.len == 0) return what;
    const sep: []const u8 = if (fixed.len > 0 and bound.len > 0) ", " else "";
    return std.fmt.bufPrint(buf, "{s} ({s}{s}{s})", .{ what, fixed, sep, bound }) catch what;
}

/// A hint that shows while the pointer rests on `rect`. (dvui derives a
/// tooltip's id from its source line and parent alone — the options'
/// id_extra is not used — so each hint gets a parent of its own.)
fn findBarHint(rect: dvui.Rect.Physical, text: []const u8, id_extra: usize) void {
    var parent = dvui.virtualParent(@src(), .{ .id_extra = id_extra });
    defer parent.deinit();
    dvui.tooltip(@src(), .{ .active_rect = rect, .position = .vertical, .delay = 400_000 }, "{s}", .{text}, .{});
}

/// Hover hints for the bar's buttons: what each one is, and its key.
fn findBarHints(editor: *const Editor, g: FindBarGeom) void {
    var buf: [96]u8 = undefined;
    for (find_bar_buttons, g.toggles, 0..) |button, rect, i| {
        findBarHint(rect, findBarHintText(editor, button.which.label(), "", button.action, &buf), i);
    }
    findBarHint(g.prev, findBarHintText(editor, "Previous match", "Shift+Enter", "find_previous", &buf), 10);
    findBarHint(g.next, findBarHintText(editor, "Next match", "Enter", "find_next", &buf), 11);
    findBarHint(g.close, "Close (Escape)", 12);
}

/// Marks for the find bar's matches where a pane's scroll bar runs: a short
/// line at each match's height in the document, one per pixel row at most.
/// A document shorter than the view is not stretched over the bar: its
/// marks sit beside their lines.
fn drawFindMarks(doc: *const Document, list: *const find_bar_mod.MatchList, area: dvui.Rect.Physical, line_height: f32, scale: f32, color: dvui.Color) void {
    const starts = doc.buffer.line_starts.items;
    if (starts.len == 0 or area.h <= 0) return;
    const mark_h = @max(2.0, 2 * scale);
    const mark_w = 6 * scale;
    const x = area.x + area.w - mark_w - 2 * scale;
    const total: f32 = @floatFromInt(@max(starts.len, editorSbVisLines(area, line_height)));
    var line: usize = 0;
    var last_y: f32 = -1;
    for (list.items.items) |m| {
        while (line + 1 < starts.len and starts[line + 1] <= m.start) line += 1;
        const y = @floor(area.y + (area.h - mark_h) * @as(f32, @floatFromInt(line)) / total);
        if (y == last_y) continue;
        last_y = y;
        (dvui.Rect.Physical{ .x = x, .y = y, .w = mark_w, .h = mark_h }).fill(.{}, .{ .color = color, .fade = 1.0 });
    }
}

fn editorPane(editor: *Editor, pane_id: u8) void {
    if (!build_options.has_gui) return;

    const is_active_pane = editor.isActivePane(cur_win, pane_id);

    // Get the document for THIS pane (not necessarily the active doc).
    var pane_doc_idx = switch (winLayout(editor, cur_win).panes.items[pane_id].content) {
        .editor => |idx| idx,
        .terminal => return, // terminal panes handled by terminalPane()
    };
    var doc = &editor.documents.items[pane_doc_idx];

    // --- Container box for the editor area ---
    var ebox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .style = .window,
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .name = "editor_pane",
        .id_extra = pane_id,
    });
    defer ebox.deinit();

    const wd = ebox.data();
    const rs = wd.contentRectScale();
    const scale = rs.s;
    const area = rs.r; // physical pixel rect of content area

    // --- Font metrics ---
    const font = dvui.Font.theme(.mono);
    const lh = font.lineHeight();
    const line_height: f32 = lh * scale; // physical pixels per line
    if (line_height <= 0) return;

    const visible_lines_f = area.h / line_height;
    const visible_lines: usize = @intFromFloat(@floor(visible_lines_f));
    if (visible_lines == 0) return;

    // Keep Page Up/Down in step with the viewport (the TUI does the same;
    // previously the GUI paged by a fixed count regardless of window size).
    if (is_active_pane and visible_lines > 1) {
        editor.page_size = visible_lines - 1;
    }

    // --- Line number gutter width (needed for mouse + rendering) ---
    const line_count_for_gutter = doc.buffer.lineCount();
    const gutter_digits_early = guiLineNumberDigits(line_count_for_gutter, editor.gutter_min_digits);
    const digit_width_early = font.textSize("0").w * scale;
    const gutter_padding_early: f32 = 8 * scale;
    const gutter_total_width = @as(f32, @floatFromInt(gutter_digits_early)) * digit_width_early + gutter_padding_early * 2 + 1 * scale;

    // Store logical text area width for visual-row movement calculations
    // (in unscaled font units, matching what guiWrapAdvanceRow uses)
    const text_area_w_logical = @max(0.0, area.w - gutter_total_width) / scale;
    if (is_active_pane) editor.text_width = if (text_area_w_logical > 0) @intFromFloat(text_area_w_logical) else 80;

    // Take dvui focus back when the keyboard returned to this editor pane
    // (from a side panel, another pane or window, a tab click): movement
    // and typing below are is_focused-gated.
    if (is_active_pane and (filetree_release_focus or win_ui.refocus_editor)) {
        filetree_release_focus = false;
        win_ui.refocus_editor = false;
        dvui.focusWidget(wd.id, null, null);
    }

    // --- Handle keyboard events (before rendering) — only for the focused
    // pane, and not while a side panel owns the keyboard. Modal prompts
    // (mode != .normal) still route through here. ---
    if (is_active_pane and editorTakesKeys(editor)) {
        _ = handleGuiKeyEvents(editor, wd);

        // Re-fetch doc after key events — close_tab may have changed/freed the active document
        pane_doc_idx = switch (winLayout(editor, cur_win).panes.items[pane_id].content) {
            .editor => |idx| idx,
            .terminal => return,
        };
        doc = &editor.documents.items[pane_doc_idx];
    }
    // Per-language settings, resolved once per pane per frame
    const do_wrap = editor.wordWrapFor(doc);
    const tab_width = editor.tabWidthFor(doc);

    // --- Handle mouse events ---
    // Block mouse clicks/drags when a modal is active so they don't go to
    // editor text. The settings dialog's widgets run before the panes, so
    // anything still unhandled here is a click outside the dialog.
    if (guiMode(editor) != .normal) {
        if (is_active_pane) {
            for (dvui.events()) |*e| {
                if (e.handled) continue;
                if (e.evt != .mouse) continue;
                switch (e.evt.mouse.action) {
                    .press, .release, .motion => e.handle(@src(), wd),
                    .wheel_y => |delta| {
                        // Quick-open: let the wheel peek deeper into the
                        // live preview behind the finder panel.
                        if (editor.mode == .file_finder) {
                            e.handle(@src(), wd);
                            win_ui.scroll_pinned = true;
                            const scroll_lines: i32 = @intFromFloat(@round(-delta / dvui.scroll_speed * 3));
                            const new_top = @as(i64, @intCast(doc.scroll_top)) + scroll_lines;
                            const max_top: i64 = @intCast(doc.buffer.lineCount() -| 1);
                            doc.scroll_top = @intCast(@max(0, @min(new_top, max_top)));
                        }
                    },
                    else => {},
                }
            }
        }
    } else {
        // Cache text area (excluding gutter) when not dragging to prevent subpixel
        // layout shifts from causing mouse-to-offset oscillation (gyration fix).
        if (!win_ui.drag_active) {
            win_ui.drag_area = .{
                .x = area.x + gutter_total_width,
                .y = area.y,
                .w = area.w - gutter_total_width,
                .h = area.h,
            };
        }
        handleMouseEvents(editor, pane_id, wd, win_ui.drag_area, font, line_height, scale);

        // Right-click context menu — watches the whole pane content area;
        // handleMouseEvents leaves right presses unhandled (after placing
        // the cursor) so the ContextWidget can consume them here.
        paneContextMenu(editor, pane_id, area);
    }

    // --- Ensure cursor visible (unless user is scrolling with wheel or dragging) ---
    if (is_active_pane and !win_ui.scroll_pinned and !win_ui.drag_active) {
        if (do_wrap) {
            guiEnsureCursorVisibleWrapped(doc, font, text_area_w_logical, visible_lines, tab_width);
        } else {
            guiEnsureCursorVisibleNoWrap(doc, font, text_area_w_logical, visible_lines, tab_width);
        }
    }

    // --- Request text input from SDL — only for the focused pane that
    // takes keys (never under a side panel that owns the keyboard) ---
    // A modal prompt lives in this pane, so in any other mode the pane
    // takes text input and dvui focus even when it is not focused.
    // Settings and the snippet form are excluded: their DVUI dialogs' own
    // text entries request input and focus; grabbing it here would steal
    // their focus each frame (and the pane's prompt handling, which ignores
    // both modes, would get the typing).
    const focused = if (dvui.focusedWidgetId()) |fid| fid == wd.id else false;
    const takes_keys = is_active_pane and editorTakesKeys(editor);
    if (takes_keys) {
        const needs_text = focused or (editor.mode != .normal and editor.mode != .settings and editor.mode != .snippet_form);
        if (needs_text) {
            dvui.wantTextInput(area.toNatural());
            if (!focused) dvui.focusWidget(wd.id, null, 0);
        }
    }
    // Carets show where typing goes: not while a side panel owns the
    // keyboard, even though this pane may still hold dvui focus.
    const show_carets = focused and takes_keys;

    // Full editor area for rendering (includes gutter).
    // win_ui.drag_area is the text-only area (for mouse mapping), but we render
    // gutter + text across the full area.
    const render_area = area;
    const render_rs: dvui.RectScale = .{ .r = render_area, .s = scale };

    // --- Clip to editor area ---
    const old_clip = dvui.clip(render_area);
    defer dvui.clipSet(old_clip);

    // --- Line number gutter width ---
    const line_count = doc.buffer.lineCount();
    const gutter_digits = guiLineNumberDigits(line_count, editor.gutter_min_digits);
    const digit_width = font.textSize("0").w * scale;
    const gutter_padding: f32 = 8 * scale; // padding on each side of line numbers
    const gutter_width = @as(f32, @floatFromInt(gutter_digits)) * digit_width + gutter_padding * 2;
    const gutter_sep_width: f32 = 1 * scale; // thin separator line

    // --- Horizontal scroll offset in pixels ---
    const char_width = font.textSize("M").w * scale;
    const scroll_x: f32 = @as(f32, @floatFromInt(doc.scroll_left)) * char_width;

    // Text area starts after gutter
    const text_area_x = render_area.x + gutter_width + gutter_sep_width;
    const text_clip_rect: dvui.Rect.Physical = .{
        .x = text_area_x,
        .y = render_area.y,
        .w = render_area.w - gutter_width - gutter_sep_width,
        .h = render_area.h,
    };

    // --- Render visible lines ---
    const cursor_pos = doc.cursorPos();
    const text_color = toDvui(editor.theme.text);
    const sel_color = toDvui(editor.theme.selection);
    const caret_color = toDvui(editor.theme.cursor);
    // The bracket under the caret and its partner (outlined where carets show).
    const bracket_pair: ?brackets.Pair = if (show_carets) brackets.matchAtCaret(&doc.buffer, doc.cursors.primaryConst().offset) else null;
    const gutter_text_color = toDvui(editor.theme.gutter_text);
    const gutter_active_color = toDvui(editor.theme.gutter_text_active);
    const gutter_bg_color = toDvui(editor.theme.gutter_bg);
    const gutter_sep_color = toDvui(editor.theme.gutter_separator);

    // Draw gutter background
    const gutter_bg_rect: dvui.Rect.Physical = .{
        .x = render_area.x,
        .y = render_area.y,
        .w = gutter_width,
        .h = render_area.h,
    };
    gutter_bg_rect.fill(.{}, .{ .color = gutter_bg_color, .fade = 1.0 });

    // Draw gutter separator line
    const sep_rect: dvui.Rect.Physical = .{
        .x = render_area.x + gutter_width,
        .y = render_area.y,
        .w = gutter_sep_width,
        .h = render_area.h,
    };
    sep_rect.fill(.{}, .{ .color = gutter_sep_color, .fade = 1.0 });

    // When wrapping, disable horizontal scroll
    const eff_scroll_x: f32 = if (do_wrap) 0 else scroll_x;
    if (do_wrap) doc.scroll_left = 0;

    // Text area width in pixels (for wrap measurement)
    const text_area_w = @max(0.0, text_clip_rect.w);

    // Wrap continuation marker style
    const wrap_marker_color = toDvui(editor.theme.wrap_marker);

    // The find bar's matches in this document: a soft fill behind each one
    // with its All button on, and an outline around the one the bar is on.
    // (Asked before any line is read: listing the matches reads the whole
    // buffer through its shared scratch slice.)
    const find_paint = editor.find_bar.paint(editor, doc);
    const find_fill = toDvui(editor.theme.find_match_bg);
    const find_edge = toDvui(editor.theme.find_match_border);

    // --- Render lines (gutter + text in two clips) ---
    // Every column below is snapped to a code-point boundary of the drawn
    // line before it slices text for dvui (which decodes with `catch
    // unreachable`): the last line of defence against a tokenizer, Lua or
    // server column that lands inside a UTF-8 sequence.
    var line_idx: usize = doc.scroll_top;
    var y: f32 = render_area.y;
    const lang_opt = if (editor.syntax_highlighting) doc.language else null;

    while (line_idx < line_count and y < render_area.y + render_area.h) {
        // Tokenizer state first: ensureLineState reads earlier lines, and a
        // lineContent slice may alias the buffer's one shared scratch.
        const line_state: syntax.LineState = if (lang_opt != null) doc.ensureLineState(line_idx) else .normal;
        // Review reader rows: ghost and marker rows are old or synthetic
        // text — drawn in their own color, never tokenized.
        const row_kind: ?review_reader.LineKind = if (doc.reader) |info| info.kindAt(line_idx) else null;
        const row_plain = if (row_kind) |k| (k == .ghost or k == .marker) else false;
        const row_text_color: dvui.Color = if (row_kind) |k| switch (k) {
            .ghost => toDvui(editor.theme.review_ghost_fg),
            .marker => toDvui(editor.theme.review_marker_fg),
            else => text_color,
        } else text_color;
        const orig_line = doc.buffer.lineContent(line_idx);
        const line_start_offset = doc.buffer.line_starts.items[line_idx];
        var tab_exp_buf: [16384]u8 = undefined;
        const line_text = displayLine(orig_line, tab_width, &tab_exp_buf);
        const needs_wrap = do_wrap and line_text.len > 0 and @as(f32, @floatFromInt(line_text.len)) * char_width > text_area_w;

        // Pre-compute expanded selection ranges on this line (constant across
        // wrap rows). Every cursor can carry one — block selection puts a
        // selection on each secondary cursor, not just the primary.
        const SelSpan = struct { start: usize, end: usize, to_eol: bool };
        var line_sels: [64]SelSpan = undefined;
        var line_sel_count: usize = 0;
        for (doc.cursors.cursors.items) |cur| {
            if (line_sel_count >= line_sels.len) break;
            const sel = cur.selectionRange() orelse continue;
            if (!(sel.end > line_start_offset and sel.start <= line_start_offset + orig_line.len)) continue;
            const s_in: usize = if (sel.start > line_start_offset)
                @min(sel.start - line_start_offset, orig_line.len)
            else
                0;
            const e_in: usize = if (sel.end > line_start_offset)
                @min(sel.end - line_start_offset, orig_line.len)
            else
                0;
            const past_eol = sel.end > line_start_offset + orig_line.len;
            const s_exp = displayCol(orig_line, line_text, s_in, tab_width);
            const e_exp = if (past_eol) line_text.len + 1 else displayCol(orig_line, line_text, e_in, tab_width);
            line_sels[line_sel_count] = .{ .start = s_exp, .end = e_exp, .to_eol = past_eol };
            line_sel_count += 1;
        }

        // Find-bar matches on this line as expanded column spans, constant
        // across wrap rows like the selections (the first 256 of a line —
        // more than any line one can read shows).
        const HitSpan = struct { start: usize, end: usize, current: bool };
        var line_hits: [256]HitSpan = undefined;
        var line_hit_count: usize = 0;
        if (find_paint.all != null or find_paint.current != null) {
            const line_end_offset = line_start_offset + orig_line.len;
            const listed: []const find_bar_mod.Match = if (find_paint.all) |list| list.within(line_start_offset, line_end_offset) else &.{};
            const on: ?find_bar_mod.Match = if (find_paint.current) |m| (if (m.start < line_end_offset and m.end > line_start_offset) m else null) else null;
            for (listed) |m| {
                if (line_hit_count + 1 >= line_hits.len) break; // one slot stays free for `on`
                if (on) |cur| {
                    if (cur.start == m.start and cur.end == m.end) continue;
                }
                line_hits[line_hit_count] = .{
                    .start = displayCol(orig_line, line_text, m.start -| line_start_offset, tab_width),
                    .end = displayCol(orig_line, line_text, @min(m.end -| line_start_offset, orig_line.len), tab_width),
                    .current = false,
                };
                line_hit_count += 1;
            }
            if (on) |m| {
                line_hits[line_hit_count] = .{
                    .start = displayCol(orig_line, line_text, m.start -| line_start_offset, tab_width),
                    .end = displayCol(orig_line, line_text, @min(m.end -| line_start_offset, orig_line.len), tab_width),
                    .current = true,
                };
                line_hit_count += 1;
            }
        }

        // Pre-compute expanded column for primary cursor on this line
        const cursor_on_line = show_carets and cursor_pos.line == line_idx;
        const cursor_exp: usize = if (cursor_on_line) displayCol(orig_line, line_text, cursor_pos.col, tab_width) else 0;

        // Pre-compute expanded columns for secondary cursors on this line
        var sc_exp_cols: [64]usize = undefined;
        var sc_count: usize = 0;
        if (show_carets and doc.cursors.count() > 1) {
            for (doc.cursors.cursors.items[1..]) |sc| {
                const sc_pos = doc.buffer.offsetToPos(sc.offset);
                if (sc_pos.line != line_idx) continue;
                if (sc_count >= 64) break;
                sc_exp_cols[sc_count] = displayCol(orig_line, line_text, sc_pos.col, tab_width);
                sc_count += 1;
            }
        }

        // Tokenize line for syntax highlighting
        var span_buf: [syntax.MAX_SPANS]syntax.HighlightSpan = undefined;
        var span_count: usize = 0;
        var exp_starts: [syntax.MAX_SPANS]usize = undefined;
        var exp_ends: [syntax.MAX_SPANS]usize = undefined;
        const lang_name: ?[]const u8 = if (doc.language) |l| l.name else null;
        // syntax_highlighting=false: skip tokenizing → plain text render
        if (if (row_plain) null else lang_opt) |lang| {
            const result = syntax.tokenizeLine(orig_line, lang, line_state, &span_buf);
            span_count = result.count;
            for (0..span_count) |si| {
                exp_starts[si] = displayCol(orig_line, line_text, span_buf[si].start, tab_width);
                exp_ends[si] = displayCol(orig_line, line_text, span_buf[si].end, tab_width);
            }
        }

        var wrap_row: usize = 0;
        var byte_pos: usize = 0;

        while (y < render_area.y + render_area.h) {
            const row_start = byte_pos;
            const row_end = if (needs_wrap)
                guiWrapAdvanceRow(line_text, font, text_area_w / scale, byte_pos)
            else
                line_text.len;
            const segment = line_text[row_start..row_end];

            // --- Gutter: line number on first row, wrap marker on continuation ---
            {
                if (wrap_row == 0) {
                    var num_buf: [16]u8 = undefined;
                    const num_str = gutterNumber(doc, line_idx, &num_buf);
                    const num_text_w = @as(f32, @floatFromInt(num_str.len)) * digit_width;
                    const num_x = render_area.x + gutter_width - gutter_padding - num_text_w;
                    const num_color = if (cursor_pos.line == line_idx) gutter_active_color else gutter_text_color;
                    dvui.renderText(.{
                        .font = font,
                        .text = num_str,
                        .rs = render_rs,
                        .p = .{ .x = num_x, .y = y },
                        .color = num_color,
                    }) catch {};
                } else {
                    // Wrap continuation marker "."
                    const dot_w = char_width;
                    const dot_x = render_area.x + gutter_width - gutter_padding - dot_w;
                    dvui.renderText(.{
                        .font = font,
                        .text = ".",
                        .rs = render_rs,
                        .p = .{ .x = dot_x, .y = y },
                        .color = wrap_marker_color,
                    }) catch {};
                }
                // Diagnostic marker: colored dot at left edge of gutter
                if (wrap_row == 0) {
                    const git_mark = editor.git.marker(doc, line_idx);
                    if (git_mark != .none) {
                        const mark_rect: dvui.Rect.Physical = .{ .x = render_area.x + gutter_width - 2 * scale, .y = y, .w = 2 * scale, .h = if (git_mark == .deleted) 3 * scale else line_height };
                        mark_rect.fill(.{}, .{ .color = toDvui(switch (git_mark) {
                            .added => editor.theme.git_added,
                            .modified => editor.theme.git_modified,
                            .deleted => editor.theme.git_deleted,
                            .none => editor.theme.git_modified,
                        }), .fade = 1.0 });
                    }
                    const debug_mark = editor.dap.marker(doc.id, line_idx);
                    if (debug_mark != .none) dvui.renderText(.{ .font = font, .text = switch (debug_mark) {
                        .execution => ">",
                        .breakpoint => "●",
                        .unverified => "○",
                        .none => "",
                    }, .rs = render_rs, .p = .{ .x = render_area.x, .y = y }, .color = if (debug_mark == .execution) dvui.Color{ .r = 240, .g = 200, .b = 40 } else dvui.Color{ .r = 230, .g = 80, .b = 70 } }) catch {};
                    if (if (debug_mark == .none) worstDiagnosticOnLine(doc, line_idx) else null) |diag| {
                        const diag_color = diagnosticColor(diag.severity);
                        const dot_r: f32 = 3 * scale;
                        const dot_cx = render_area.x + gutter_padding * 0.5;
                        const dot_cy = y + line_height * 0.5;
                        const dot_rect: dvui.Rect.Physical = .{
                            .x = dot_cx - dot_r,
                            .y = dot_cy - dot_r,
                            .w = dot_r * 2,
                            .h = dot_r * 2,
                        };
                        dot_rect.fill(.{ .x = dot_r, .y = dot_r, .w = dot_r, .h = dot_r }, .{ .color = diag_color, .fade = 1.0 });
                    }
                }
            }

            // --- Text content (clipped to text area) ---
            {
                const prev_clip = dvui.clip(text_clip_rect);
                defer dvui.clipSet(prev_clip);

                const base_x = text_area_x - eff_scroll_x;
                // For wrapped rows, x is always text_area_x (no scroll)
                const row_x = if (needs_wrap) text_area_x else base_x;

                // Review reader: the row's soft tint, under the selection.
                if (reviewRowTint(editor, row_kind)) |tint| {
                    (dvui.Rect.Physical{ .x = text_area_x, .y = y, .w = text_area_w, .h = line_height }).fill(.{}, .{ .color = tint, .fade = 1.0 });
                }

                // Selection highlights (every cursor's, pre-computed above).
                // A selection that runs on past the line end also covers the
                // end of its last row, up to the text area's edge — blank
                // lines and a selection that starts at the line end included.
                const last_row = row_end >= line_text.len;
                for (line_sels[0..line_sel_count]) |ls| {
                    const in_row = ls.start < row_end and ls.end > row_start;
                    const at_eol = ls.to_eol and last_row and ls.start >= row_start and ls.start <= row_end;
                    if (!in_row and !at_eol) continue;
                    const sel_byte_start = if (ls.start > row_start) ls.start - row_start else 0;
                    const sel_byte_end = if (ls.end < row_end) ls.end - row_start else segment.len;

                    const sx_start = font.textSize(segment[0..@min(sel_byte_start, segment.len)]).w * scale;
                    const sx_end = font.textSize(segment[0..@min(sel_byte_end, segment.len)]).w * scale;

                    // Selection continuing past this line fills to the edge
                    const sw = if (ls.to_eol and last_row)
                        (text_area_x + text_area_w) - (row_x + sx_start)
                    else
                        sx_end - sx_start;

                    if (sw > 0) {
                        const sr: dvui.Rect.Physical = .{ .x = row_x + sx_start, .y = y, .w = sw, .h = line_height };
                        sr.fill(.{}, .{ .color = sel_color, .fade = 0.3 });
                    }
                }

                // Find-bar matches: the soft fill, under the text.
                for (line_hits[0..line_hit_count]) |hit| {
                    if (hit.current or hit.start >= row_end or hit.end <= row_start) continue;
                    const hx0 = font.textSize(segment[0..@min(@max(hit.start, row_start) - row_start, segment.len)]).w * scale;
                    const hx1 = font.textSize(segment[0..@min(@min(hit.end, row_end) - row_start, segment.len)]).w * scale;
                    if (hx1 > hx0) {
                        (dvui.Rect.Physical{ .x = row_x + hx0, .y = y, .w = hx1 - hx0, .h = line_height }).fill(.{}, .{ .color = find_fill, .fade = 1.0 });
                    }
                }

                // Text (syntax-highlighted or plain)
                if (segment.len > 0) {
                    if (span_count > 0) {
                        // Per-span syntax-colored rendering (accumulated x position)
                        const syn_theme = editor.syntaxThemeFor(lang_name);
                        var seg_pos: usize = 0;
                        var draw_x: f32 = row_x;
                        for (0..span_count) |si| {
                            if (exp_ends[si] <= row_start or exp_starts[si] >= row_end) continue;
                            // Span edges are boundaries (displayCol); an
                            // overlapping or out-of-order span never draws
                            // text a second time.
                            const vis_start = @max(seg_pos, if (exp_starts[si] > row_start) exp_starts[si] - row_start else 0);
                            const vis_end = if (exp_ends[si] < row_end) exp_ends[si] - row_start else segment.len;
                            // Gap before span → default text color
                            if (vis_start > seg_pos) {
                                const gap = segment[seg_pos..vis_start];
                                dvui.renderText(.{
                                    .font = font,
                                    .text = gap,
                                    .rs = render_rs,
                                    .p = .{ .x = draw_x, .y = y },
                                    .color = row_text_color,
                                }) catch {};
                                draw_x += font.textSize(gap).w * scale;
                            }
                            // Span → syntax color
                            if (vis_end > vis_start) {
                                const span_text = segment[vis_start..vis_end];
                                const token_color = if (syn_theme.colorForToken(span_buf[si].token)) |tc| toDvui(tc) else row_text_color;
                                dvui.renderText(.{
                                    .font = font,
                                    .text = span_text,
                                    .rs = render_rs,
                                    .p = .{ .x = draw_x, .y = y },
                                    .color = token_color,
                                }) catch {};
                                draw_x += font.textSize(span_text).w * scale;
                            }
                            if (vis_end > seg_pos) seg_pos = vis_end;
                        }
                        // Trailing text after last span → default text color
                        if (seg_pos < segment.len) {
                            dvui.renderText(.{
                                .font = font,
                                .text = segment[seg_pos..],
                                .rs = render_rs,
                                .p = .{ .x = draw_x, .y = y },
                                .color = row_text_color,
                            }) catch {};
                        }
                    } else {
                        dvui.renderText(.{
                            .font = font,
                            .text = segment,
                            .rs = render_rs,
                            .p = .{ .x = row_x, .y = y },
                            .color = row_text_color,
                        }) catch {};
                    }
                }

                // Matching-bracket highlight: an outline in the caret color
                // around the bracket under the caret and its partner (a fill
                // would fight the selection tint).
                if (bracket_pair) |pair| {
                    for ([_]usize{ pair.open, pair.close }) |off| {
                        if (off < line_start_offset or off >= line_start_offset + orig_line.len) continue;
                        const exp = displayCol(orig_line, line_text, off - line_start_offset, tab_width);
                        if (exp < row_start or exp >= row_end) continue;
                        const local = exp - row_start;
                        const bx = font.textSize(segment[0..local]).w * scale;
                        const bw = font.textSize(segment[local .. local + 1]).w * scale;
                        const br: dvui.Rect.Physical = .{ .x = row_x + bx, .y = y, .w = bw, .h = line_height };
                        br.stroke(.{}, .{ .thickness = 1 * scale, .color = caret_color, .closed = true });
                    }
                }

                // The match the find bar is on: an outline over the text
                // (it is selected, so the selection's fill is under it).
                for (line_hits[0..line_hit_count]) |hit| {
                    if (!hit.current or hit.start >= row_end or hit.end <= row_start) continue;
                    const hx0 = font.textSize(segment[0..@min(@max(hit.start, row_start) - row_start, segment.len)]).w * scale;
                    const hx1 = font.textSize(segment[0..@min(@min(hit.end, row_end) - row_start, segment.len)]).w * scale;
                    if (hx1 > hx0) {
                        const outline: dvui.Rect.Physical = .{ .x = row_x + hx0, .y = y, .w = hx1 - hx0, .h = line_height };
                        outline.stroke(.{}, .{ .thickness = @max(1.0, scale), .color = find_edge, .closed = true });
                    }
                }

                // Diagnostic underlines. Their columns are byte columns of
                // the buffer line from servers, Lua and task matchers —
                // possibly off a boundary or past the end (a file that was
                // not open when they arrived was never snapped) — so they
                // map through displayCol like everything drawn here.
                var diag_it = doc.diagIter();
                while (diag_it.next()) |diag| {
                    if (diag.start_line != line_idx) continue;
                    const d_start = displayCol(orig_line, line_text, diag.start_col, tab_width);
                    const d_end = if (diag.end_line == line_idx)
                        displayCol(orig_line, line_text, diag.end_col, tab_width)
                    else
                        line_text.len; // runs on past this line
                    const ul_start = @max(d_start, row_start) - row_start;
                    const ul_end = @min(d_end, row_end) -| row_start;
                    if (ul_end <= ul_start) continue;
                    const ux_start = font.textSize(segment[0..ul_start]).w * scale;
                    const ux_end = font.textSize(segment[0..ul_end]).w * scale;
                    const ul_rect: dvui.Rect.Physical = .{
                        .x = row_x + ux_start,
                        .y = y + line_height - 2 * scale,
                        .w = ux_end - ux_start,
                        .h = 2 * scale,
                    };
                    ul_rect.fill(.{}, .{ .color = diagnosticColor(diag.severity), .fade = 0.8 });
                }

                // Cursor (using pre-computed expanded col, with blink)
                if (cursor_on_line) {
                    const on_last_seg = row_end >= line_text.len;
                    if (cursor_exp >= row_start and (cursor_exp < row_end or (on_last_seg and cursor_exp == row_end))) {
                        // Blink: reset timer when cursor moves, then toggle visibility
                        const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
                        const cur_offset = doc.cursors.primary().offset;
                        if (cur_offset != win_ui.blink_last_offset) {
                            win_ui.blink_time_ns = now_ns;
                            win_ui.blink_last_offset = cur_offset;
                        }
                        const elapsed: i128 = now_ns - win_ui.blink_time_ns;
                        const cycle = @mod(@divFloor(elapsed, std.time.ns_per_ms), blink_interval_ms * 2);
                        const blink_on = cycle < blink_interval_ms;

                        if (blink_on) {
                            const col_in_seg = cursor_exp - row_start;
                            const clamped = @min(col_in_seg, segment.len);
                            const cx = font.textSize(segment[0..clamped]).w * scale;
                            const cr: dvui.Rect.Physical = .{ .x = row_x + cx - 1, .y = y, .w = 3, .h = line_height };
                            cr.fill(.{}, .{ .color = caret_color, .fade = 1.0 });
                        }
                        // Schedule wakeup for next blink transition instead of continuous refresh
                        const time_until_toggle: i128 = if (blink_on)
                            blink_interval_ms - cycle
                        else
                            blink_interval_ms * 2 - cycle;
                        const micros: i32 = @intCast(@max(time_until_toggle * 1000, 1000));
                        const blink_id = dvui.Id.extendId(null, @src(), 0);
                        dvui.animation(blink_id, "_blink", .{
                            .start_time = micros,
                            .end_time = micros + 1000,
                        });
                    }
                }

                // Secondary cursors (using pre-computed expanded cols, no blink)
                if (sc_count > 0) {
                    for (sc_exp_cols[0..sc_count]) |sc_col| {
                        const sc_on_last = row_end >= line_text.len;
                        if (sc_col >= row_start and (sc_col < row_end or (sc_on_last and sc_col == row_end))) {
                            const sc_in_seg = sc_col - row_start;
                            const sc_clamped = @min(sc_in_seg, segment.len);
                            const sc_cx = font.textSize(segment[0..sc_clamped]).w * scale;
                            const sc_r: dvui.Rect.Physical = .{ .x = row_x + sc_cx - 1, .y = y, .w = 3, .h = line_height };
                            sc_r.fill(.{}, .{ .color = caret_color, .fade = 0.7 });
                        }
                    }
                }
            }

            y += line_height;
            wrap_row += 1;
            byte_pos = row_end;

            if (!needs_wrap or byte_pos >= line_text.len) break;
        }

        line_idx += 1;
    }

    // --- Draw tildes for lines past end of file ---
    {
        const prev_clip = dvui.clip(text_clip_rect);
        defer dvui.clipSet(prev_clip);
        const tilde_color = toDvui(editor.theme.tilde);
        while (y < render_area.y + render_area.h) : (y += line_height) {
            dvui.renderText(.{
                .font = font,
                .text = "~",
                .rs = render_rs,
                .p = .{ .x = text_area_x, .y = y },
                .color = tilde_color,
            }) catch {};
        }
    }

    // --- Focused pane indicator (subtle border highlight) ---
    if (is_active_pane and (winLayout(editor, cur_win).paneCount() > 1 or editor.windows.items.len > 1)) {
        const focus_color = toDvui(editor.theme.selection);
        const border_w: f32 = 2 * scale;
        // Top
        (dvui.Rect.Physical{ .x = render_area.x, .y = render_area.y, .w = render_area.w, .h = border_w }).fill(.{}, .{ .color = focus_color, .fade = 0.6 });
        // Bottom
        (dvui.Rect.Physical{ .x = render_area.x, .y = render_area.y + render_area.h - border_w, .w = render_area.w, .h = border_w }).fill(.{}, .{ .color = focus_color, .fade = 0.6 });
        // Left
        (dvui.Rect.Physical{ .x = render_area.x, .y = render_area.y, .w = border_w, .h = render_area.h }).fill(.{}, .{ .color = focus_color, .fade = 0.6 });
        // Right
        (dvui.Rect.Physical{ .x = render_area.x + render_area.w - border_w, .y = render_area.y, .w = border_w, .h = render_area.h }).fill(.{}, .{ .color = focus_color, .fade = 0.6 });
    }

    // --- Find-bar marks where the scroll bar runs (All on), under the thumb ---
    if (find_paint.all) |list| drawFindMarks(doc, list, render_area, line_height, scale, find_edge);

    // --- Scrollbar: slim pill over the right edge (matches the file tree) ---
    const sb_max_top = editorMaxScrollTop(doc, font, text_area_w_logical, editorSbVisLines(render_area, line_height), tab_width, do_wrap);
    if (editorSbThumb(doc, render_area, line_height, scale, sb_max_top)) |thumb| {
        const active = (win_ui.editor_sb_drag and win_ui.editor_sb_pane == pane_id) or
            win_ui.editor_sb_hover_pane == pane_id;
        const sb_color = if (active)
            toDvui(editor.theme.text).opacity(0.55)
        else
            toDvui(editor.theme.gutter_text).opacity(0.4);
        const rad = thumb.w / 2;
        thumb.fill(.{ .x = rad, .y = rad, .w = rad, .h = rad }, .{ .color = sb_color, .fade = 1.0 });
    }

    // --- Modal overlays (find_replace, command_palette, goto_line, confirm_quit) ---
    // Only render modals in the focused pane.
    if (is_active_pane and guiMode(editor) != .normal) {
        drawModalOverlay(editor, render_area, render_rs, scale);
    }

    // --- Signature help (above the caret line), then the completion popup on top ---
    if (is_active_pane and pane_doc_idx < editor.documents.items.len and editor.documents.items[pane_doc_idx].id == editor.signature_doc_id and editor.signatureVisible()) {
        drawSignatureHelpGui(editor, render_area, font, line_height, scale);
    }
    // --- Completion popup (renders on top, only in active pane) ---
    if (is_active_pane and editor.completion_active and editor.completion_items.items.len > 0 and
        editor.completion_doc_idx == pane_doc_idx)
    {
        drawCompletionPopupGui(editor, render_area, font, line_height, scale);
    }
}

/// The signature of the call at the caret: the label with the active
/// parameter highlighted, and a documentation line under it when there is
/// one. Sits above the caret line (below it when there is no room).
fn drawSignatureHelpGui(editor: *Editor, render_area: dvui.Rect.Physical, font: dvui.Font, line_height: f32, scale: f32) void {
    if (!build_options.has_gui) return;
    const sig = editor.signature orelse return;
    const pad: f32 = 4 * scale;
    const doc = editor.activeDoc();
    const cursor_pos = doc.buffer.offsetToPos(doc.cursors.primaryConst().offset);
    const tab_width = editor.tabWidthFor(doc);
    const gutter_digits = guiLineNumberDigits(doc.lineCount(), editor.gutter_min_digits);
    const char_w = font.textSize("0").w * scale;
    const gutter_w = @as(f32, @floatFromInt(gutter_digits + 1)) * char_w + 8 * scale;
    const line_text = doc.lineContent(cursor_pos.line);
    var visual_col: usize = 0;
    var byte_col: usize = 0;
    while (byte_col < cursor_pos.col and byte_col < line_text.len) : (byte_col += 1) {
        if (line_text[byte_col] == '\t') {
            visual_col = (visual_col / tab_width + 1) * tab_width;
        } else {
            visual_col += 1;
        }
    }
    const rows: f32 = if (sig.doc.len > 0) 2 else 1;
    const popup_h = rows * line_height + pad * 2;
    const label_w = font.textSize(sig.label).w * scale;
    const doc_w: f32 = if (sig.doc.len > 0) font.textSize(sig.doc).w * scale else 0;
    const popup_w = @min(@max(label_w, doc_w) + pad * 2, render_area.w);
    const cursor_x = render_area.x + gutter_w + @as(f32, @floatFromInt(visual_col)) * char_w;
    const popup_x = @max(render_area.x, @min(cursor_x, render_area.x + render_area.w - popup_w));
    const cursor_y_rel: f32 = if (cursor_pos.line >= doc.scroll_top) @as(f32, @floatFromInt(cursor_pos.line - doc.scroll_top)) * line_height else 0;
    var popup_y = render_area.y + cursor_y_rel - popup_h;
    if (popup_y < render_area.y) popup_y = render_area.y + cursor_y_rel + line_height;
    const bg = toDvui(editor.theme.overlay_bg);
    const fg = toDvui(editor.theme.overlay_fg);
    const dim = toDvui(editor.theme.overlay_dim);
    const highlight = toDvui(editor.theme.overlay_selection);
    const box: dvui.Rect.Physical = .{ .x = popup_x, .y = popup_y, .w = popup_w, .h = popup_h };
    box.fill(.{}, .{ .color = bg, .fade = 1.0 });
    const rs: dvui.RectScale = .{ .r = box, .s = scale };
    const text_y = popup_y + pad;
    const x0 = popup_x + pad;
    const param = sig.label[sig.param_start..sig.param_end];
    if (param.len > 0) {
        const before_w = font.textSize(sig.label[0..sig.param_start]).w * scale;
        const param_w = font.textSize(param).w * scale;
        const bar: dvui.Rect.Physical = .{ .x = x0 + before_w, .y = text_y, .w = param_w, .h = line_height };
        bar.fill(.{}, .{ .color = highlight, .fade = 1.0 });
    }
    renderOverlayText(font, sig.label, x0, text_y, rs, fg);
    if (sig.doc.len > 0) renderOverlayText(font, sig.doc, x0, text_y + line_height, rs, dim);
}

/// Render a terminal pane in the GUI using the cell grid.
fn terminalPane(editor: *Editor, pane_id: u8, term_idx: usize) void {
    if (!build_options.has_gui) return;
    if (term_idx >= editor.terminals.items.len) return;

    const term = editor.terminals.items[term_idx] orelse return;
    const is_active_pane = editor.isActivePane(cur_win, pane_id);

    // Container box
    var ebox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .style = .window,
        .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
        .name = "terminal_pane",
        .id_extra = pane_id,
    });
    defer ebox.deinit();

    const wd = ebox.data();
    const rs = wd.contentRectScale();
    const scale = rs.s;
    const area = rs.r;

    // Get monospace font metrics (same as editorPane)
    const metrics = terminalCellMetrics(scale) orelse return;
    fitTerminalGrid(term, area, metrics);

    // Handle mouse clicks — focus this pane when clicked.
    // Gated to normal mode so clicks meant for a modal (settings dialog,
    // find bar, ...) don't refocus the terminal behind it.
    if (guiMode(editor) == .normal) {
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (me.p.x < area.x or me.p.x > area.x + area.w or
                me.p.y < area.y or me.p.y > area.y + area.h) continue;
            switch (me.action) {
                .focus, .press => {
                    e.handle(@src(), wd);
                    dvui.focusWidget(wd.id, null, e.num);
                    editor.focusPaneIn(cur_win, pane_id);
                },
                else => {},
            }
        }
    }

    // Keyboard input for the terminal — only while it owns the keyboard:
    // not under a modal (unconsumed keys would be typed into the shell)
    // and not while the file tree or search panel is focused over it.
    // Printable characters arrive as text events, which SDL only sends
    // while someone declares a text-input region.
    if (is_active_pane and terminalTakesKeys(editor)) {
        dvui.wantTextInput(area.toNatural());
        if (handleTerminalKeyEvents(editor, term, wd, .terminal)) return; // terminal was freed
    }

    // Only while typing goes here (a side panel focused over the terminal
    // owns the keyboard) does the caret show.
    drawTerminalGrid(term, area, metrics, is_active_pane and editor.keyboardOwner() == .terminal);

    // Active pane indicator (same as editor)
    if (is_active_pane and (winLayout(editor, cur_win).paneCount() > 1 or editor.windows.items.len > 1)) {
        const focus_color: dvui.Color = .{ .r = 0x35, .g = 0x84, .b = 0xe4, .a = 0xFF };
        const border_w: f32 = 2 * scale;
        (dvui.Rect.Physical{ .x = area.x, .y = area.y, .w = border_w, .h = area.h }).fill(.{}, .{ .color = focus_color, .fade = 0.6 });
    }
}

/// The monospace cell of a terminal grid at `scale`: the theme's mono
/// font, its line height and the advance of "M" (physical pixels). Null
/// when the font reports no size (nothing can be drawn).
const TerminalCellMetrics = struct { font: dvui.Font, line_height: f32, cell_w: f32, scale: f32 };
fn terminalCellMetrics(scale: f32) ?TerminalCellMetrics {
    const font = dvui.Font.theme(.mono);
    const line_height: f32 = font.lineHeight() * scale;
    if (line_height <= 0) return null;
    const cell_w = font.textSize("M").w * scale;
    if (cell_w <= 0) return null;
    return .{ .font = font, .line_height = line_height, .cell_w = cell_w, .scale = scale };
}

/// Resize the shell's grid to the cells that fit `area` — once the size
/// repeats: dvui lays a new window (or a fresh split, or a fresh band) out
/// over two frames, expanding widgets get their min size first and the
/// real rect on the next frame. Resizing on that first measurement shrank
/// the grid to one row and dropped the shell's screen (a detached terminal
/// came up blank).
fn fitTerminalGrid(term: *terminal_mod.Terminal, area: dvui.Rect.Physical, m: TerminalCellMetrics) void {
    const visible_cols: u16 = @intFromFloat(@max(1.0, area.w / m.cell_w));
    const visible_rows: u16 = @intFromFloat(@max(1.0, area.h / m.line_height));
    if (visible_cols != term.cols or visible_rows != term.rows) {
        if (visible_cols == term.pending_cols and visible_rows == term.pending_rows) {
            term.resizeGrid(visible_cols, visible_rows);
        } else {
            term.pending_cols = visible_cols;
            term.pending_rows = visible_rows;
            dvui.refresh(null, @src(), null);
        }
    }
}

/// Draw a shell's cell grid into `area` (clipped to it): backgrounds, the
/// text as same-color spans, underlines, the caret when `show_cursor`,
/// and the exit message once the program has ended.
fn drawTerminalGrid(term: *terminal_mod.Terminal, area: dvui.Rect.Physical, m: TerminalCellMetrics, show_cursor: bool) void {
    const font = m.font;
    const scale = m.scale;
    const line_height = m.line_height;
    const cell_w = m.cell_w;

    // Clip to terminal area
    const old_clip = dvui.clip(area);
    defer dvui.clipSet(old_clip);
    const render_rs: dvui.RectScale = .{ .r = area, .s = scale };

    // Lock terminal mutex and render cell grid
    term.mutex.lockUncancelable(term.io);
    defer term.mutex.unlock(term.io);

    const t_cols = term.cols;
    const t_rows = term.rows;
    const t_cursor_row = term.cursor_row;
    const t_cursor_col = term.cursor_col;
    const t_cursor_visible = term.cursor_visible;
    const t_exited = term.exited;

    // Render rows using span-based text rendering (same approach as editorPane).
    // Rendering individual characters at grid positions causes spacing issues because
    // renderText handles character advance internally; we must render strings.
    for (0..t_rows) |r| {
        const y = area.y + @as(f32, @floatFromInt(r)) * line_height;

        // --- Background pass: draw non-default cell backgrounds ---
        for (0..t_cols) |c| {
            const cell = term.cellAtUnsafe(@intCast(r), @intCast(c));
            const bg_color = if (cell.reverse) cell.fg else cell.bg;
            if (bg_color.r != 0x1E or bg_color.g != 0x1E or bg_color.b != 0x24) {
                const x = area.x + @as(f32, @floatFromInt(c)) * cell_w;
                (dvui.Rect.Physical{ .x = x, .y = y, .w = cell_w, .h = line_height }).fill(.{}, .{
                    .color = .{ .r = bg_color.r, .g = bg_color.g, .b = bg_color.b, .a = 0xFF },
                    .fade = 1.0,
                });
            }
        }

        // --- Text pass: render spans of same-color text as strings ---
        // Build row text and split into spans when fg color changes.
        var row_buf: [1024]u8 = undefined;
        var buf_len: usize = 0;
        var span_start_col: usize = 0;

        const first_cell = term.cellAtUnsafe(@intCast(r), 0);
        var span_fg: terminal_mod.Color = if (first_cell.reverse) first_cell.bg else first_cell.fg;
        var draw_x: f32 = area.x;

        for (0..t_cols) |c| {
            const cell = term.cellAtUnsafe(@intCast(r), @intCast(c));
            const fg = if (cell.reverse) cell.bg else cell.fg;

            // Flush span if fg color changed
            if (fg.r != span_fg.r or fg.g != span_fg.g or fg.b != span_fg.b) {
                if (buf_len > 0) {
                    dvui.renderText(.{
                        .font = font,
                        .text = row_buf[0..buf_len],
                        .rs = render_rs,
                        .p = .{ .x = draw_x, .y = y },
                        .color = .{ .r = span_fg.r, .g = span_fg.g, .b = span_fg.b, .a = 0xFF },
                    }) catch {};
                    draw_x += font.textSize(row_buf[0..buf_len]).w * scale;
                } else {
                    // Empty span (spaces) — advance by cell count
                    draw_x += @as(f32, @floatFromInt(c - span_start_col)) * cell_w;
                }
                buf_len = 0;
                span_start_col = c;
                span_fg = fg;
            }

            // Encode cell codepoint into the row buffer
            if (cell.codepoint >= 32 and cell.codepoint != 0) {
                if (buf_len + 4 <= row_buf.len) {
                    const len = std.unicode.utf8Encode(cell.codepoint, row_buf[buf_len..][0..4]) catch {
                        row_buf[buf_len] = ' ';
                        buf_len += 1;
                        continue;
                    };
                    buf_len += len;
                }
            } else {
                if (buf_len < row_buf.len) {
                    row_buf[buf_len] = ' ';
                    buf_len += 1;
                }
            }
        }

        // Flush final span
        if (buf_len > 0) {
            dvui.renderText(.{
                .font = font,
                .text = row_buf[0..buf_len],
                .rs = render_rs,
                .p = .{ .x = draw_x, .y = y },
                .color = .{ .r = span_fg.r, .g = span_fg.g, .b = span_fg.b, .a = 0xFF },
            }) catch {};
        }

        // --- Underline pass ---
        for (0..t_cols) |c| {
            const cell = term.cellAtUnsafe(@intCast(r), @intCast(c));
            if (cell.underline) {
                const fg_color = if (cell.reverse) cell.bg else cell.fg;
                const x = area.x + @as(f32, @floatFromInt(c)) * cell_w;
                const ul_y = y + line_height - 2 * scale;
                (dvui.Rect.Physical{ .x = x, .y = ul_y, .w = cell_w, .h = 1 * scale }).fill(.{}, .{
                    .color = .{ .r = fg_color.r, .g = fg_color.g, .b = fg_color.b, .a = 0xFF },
                    .fade = 1.0,
                });
            }
        }
    }

    // Draw cursor — measure text prefix up to cursor column for accurate
    // positioning.
    if (show_cursor and t_cursor_visible and !t_exited) {
        var prefix_buf: [512]u8 = undefined;
        var prefix_len: usize = 0;
        for (0..@as(usize, t_cursor_col)) |c| {
            const cell = term.cellAtUnsafe(t_cursor_row, @intCast(c));
            if (cell.codepoint >= 32 and cell.codepoint != 0) {
                if (prefix_len + 4 <= prefix_buf.len) {
                    const len = std.unicode.utf8Encode(cell.codepoint, prefix_buf[prefix_len..][0..4]) catch {
                        prefix_buf[prefix_len] = ' ';
                        prefix_len += 1;
                        continue;
                    };
                    prefix_len += len;
                }
            } else {
                if (prefix_len < prefix_buf.len) {
                    prefix_buf[prefix_len] = ' ';
                    prefix_len += 1;
                }
            }
        }
        const cx = area.x + font.textSize(prefix_buf[0..prefix_len]).w * scale;
        const cy = area.y + @as(f32, @floatFromInt(t_cursor_row)) * line_height;
        const cursor_rect = dvui.Rect.Physical{ .x = cx, .y = cy, .w = 2 * scale, .h = line_height };
        cursor_rect.fill(.{}, .{
            .color = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC, .a = 0xCC },
            .fade = 1.0,
        });
    }

    // Show exit message
    if (t_exited) {
        const msg = "[Process exited \u{2014} press any key to close]";
        const msg_y = area.y + @as(f32, @floatFromInt(t_rows / 2)) * line_height;
        const msg_x = area.x + 8 * scale;
        dvui.renderText(.{
            .font = font,
            .text = msg,
            .rs = render_rs,
            .p = .{ .x = msg_x, .y = msg_y },
            .color = .{ .r = 0x88, .g = 0x88, .b = 0x88, .a = 0xFF },
        }) catch {};
    }
}

// ===========================================================================
// Terminal panel: one shell docked at an edge of the primary window
// ===========================================================================

/// The terminal panel's band (see BandResize): its editor-facing edge
/// resizes it, like the tree's.
var terminal_panel_band: BandResize = .{};

/// The terminal panel's size this frame: its width at a side, its height
/// at the bottom (logical px), or 0 when hidden — also when it would leave
/// the panes less than 240 px beside the side bands, or less than half the
/// rows under it: then it hides itself, says so, and lets go of the
/// keyboard (the shell keeps running; Ctrl+Shift+` brings it back).
fn terminalPanelBandSize(editor: *Editor, row: dvui.Rect, tree_shown: bool, snippets_w: f32) f32 {
    if (!editor.terminal_panel_visible or editor.terminal_panel == null) return 0;
    if (row.w <= 0 or row.h <= 0) {
        terminal_panel_band.reset();
        return 0;
    }
    const lim = Editor.terminal_panel_limits;
    const size: f32 = switch (editor.terminal_panel_side) {
        .bottom => blk: {
            const h = @min(std.math.clamp(editor.terminal_panel_height, lim.min_height, lim.max_height), row.h / 2);
            break :blk if (h >= lim.min_height) h else 0;
        },
        .left, .right => blk: {
            const tree_w: f32 = if (tree_shown) std.math.clamp(editor.filetree_width, 120, 600) else 0;
            const w = @min(std.math.clamp(editor.terminal_panel_width, lim.min_width, lim.max_width), row.w - tree_w - snippets_w - 240);
            break :blk if (w >= lim.min_width) w else 0;
        },
    };
    if (size > 0) return size;
    terminal_panel_band.reset();
    editor.hideTerminalPanel();
    editor.setStatus(.warning, "Terminal panel: no room beside the editor — enlarge the window, then Ctrl+Shift+`");
    return 0;
}

/// The terminal panel band: a header ("Terminal", bold while it has the
/// keyboard, with the way out) over the shell's grid, sized to the band.
/// A click gives the shell the keyboard; typing reaches it through the
/// same path as a terminal pane's (handleTerminalKeyEvents); a right
/// click offers the other edges, undocking, hiding and closing.
fn terminalPanel(editor: *Editor, size: f32, edge: Editor.DockEdge) void {
    if (!build_options.has_gui) return;
    var pbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = if (edge == .bottom) .horizontal else .vertical,
        .min_size_content = if (edge == .bottom) .{ .h = size } else .{ .w = size },
        .background = true,
        .style = .window,
        .name = "terminal_panel",
        .tag = "terminal_panel",
    });
    defer pbox.deinit();

    const wd = pbox.data();
    const rs = wd.contentRectScale();
    const scale = rs.s;
    const area = rs.r;
    terminal_panel_band.rect = area;
    terminal_panel_band.scale = scale;
    if (area.w <= 0 or area.h <= 0) return;

    const font = dvui.Font.theme(.body);
    const header_h = @ceil(font.lineHeight() * scale + 6 * scale);
    const line_w = @max(1.0, 1 * scale);
    const grid_area: dvui.Rect.Physical = .{
        .x = area.x + 2 * scale,
        .y = area.y + header_h,
        .w = @max(0, area.w - 4 * scale),
        .h = @max(0, area.h - header_h - 2 * scale),
    };
    const focused = editor.keyboardOwner() == .terminal_panel;

    // A press anywhere on the band gives the shell the keyboard (the
    // press's .focus event too, else the editor pane behind stays deaf).
    // Not under a modal: a click meant for a dialog must not refocus.
    if (guiMode(editor) == .normal) {
        for (dvui.events()) |*e| {
            if (e.handled or e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (me.floating_win != dvui.subwindowCurrentId()) continue;
            if (!area.contains(me.p)) continue;
            switch (me.action) {
                .focus => e.handle(@src(), wd),
                .press => {
                    // A right press takes the keyboard too but stays
                    // unhandled: the panel's ContextWidget opens the menu on
                    // it (as the Snippets panel's).
                    if (me.button == .left) e.handle(@src(), wd);
                    dvui.focusWidget(wd.id, null, e.num);
                    _ = editor.takeKeyboardFocus(.terminal_panel);
                },
                else => {},
            }
        }
    }

    const term = editor.terminalPanelTerminal();
    if (term) |t| {
        if (terminalCellMetrics(scale)) |m| fitTerminalGrid(t, grid_area, m);
    }
    if (terminalPanelTakesKeys(editor)) {
        dvui.wantTextInput(grid_area.toNatural());
        if (handleTerminalKeyEvents(editor, term, wd, .terminal_panel)) return; // the shell was closed
    }

    const header_fg = toDvui(editor.theme.overlay_fg);
    const dim = toDvui(editor.theme.overlay_dim);
    const border = toDvui(editor.theme.panel_border);
    {
        const prev_clip = dvui.clip(area);
        defer dvui.clipSet(prev_clip);

        // Header, bold while it has the keyboard; the hint says the way out.
        fillBar(area, 0, header_h, toDvui(editor.theme.gutter_bg));
        const header_line: dvui.Rect.Physical = .{ .x = area.x, .y = area.y + header_h - line_w, .w = area.w, .h = line_w };
        header_line.fill(.{}, .{ .color = border, .fade = 1.0 });
        const title: []const u8 = if (focused) "Terminal — Ctrl+` back to the editor" else "Terminal — Ctrl+Shift+` focuses";
        const title_font = if (focused) dvui.Font.theme(.heading) else font;
        const title_fit = fitOverlayText(title_font, title, area.w - 16 * scale, scale);
        renderOverlayText(title_font, title_fit, area.x + 8 * scale, area.y + 2 * scale, rs, if (focused) header_fg else dim);

        if (term) |t| {
            if (terminalCellMetrics(scale)) |m| drawTerminalGrid(t, grid_area, m, focused);
        }
    }

    // Separator on the edge facing the panes.
    const sep_rect: dvui.Rect.Physical = switch (edge) {
        .left => .{ .x = area.x + area.w - line_w, .y = area.y, .w = line_w, .h = area.h },
        .right => .{ .x = area.x, .y = area.y, .w = line_w, .h = area.h },
        .bottom => .{ .x = area.x, .y = area.y, .w = area.w, .h = line_w },
    };
    sep_rect.fill(.{}, .{ .color = border, .fade = 1.0 });

    terminalPanelContextMenu(editor, area);
}

/// Right-click menu of the terminal panel: the two other edges, undock
/// into a split, hide, close the shell. The moves persist (Editor.movePanel).
fn terminalPanelContextMenu(editor: *Editor, area: dvui.Rect.Physical) void {
    const ctext = dvui.context(@src(), .{ .rect = area }, .{});
    defer ctext.deinit();

    if (ctext.activePoint()) |cp| {
        var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{});
        defer fw.deinit();
        const edge = editor.terminal_panel_side;
        if (edge != .left and dvui.menuItemLabel(@src(), "Move Terminal to Left", .{}, .{ .expand = .horizontal, .tag = "terminal_panel_menu_left" }) != null) {
            editor.movePanel(.terminal, .left);
            fw.close();
        }
        if (edge != .right and dvui.menuItemLabel(@src(), "Move Terminal to Right", .{}, .{ .expand = .horizontal, .tag = "terminal_panel_menu_right" }) != null) {
            editor.movePanel(.terminal, .right);
            fw.close();
        }
        if (edge != .bottom and dvui.menuItemLabel(@src(), "Move Terminal to Bottom", .{}, .{ .expand = .horizontal, .tag = "terminal_panel_menu_bottom" }) != null) {
            editor.movePanel(.terminal, .bottom);
            fw.close();
        }
        // These change the layout: after the panes finished (DeferredQueue).
        if (dvui.menuItemLabel(@src(), "Undock into a Split", .{}, .{ .expand = .horizontal }) != null) {
            deferRun(editor, .action, "undock_terminal");
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Hide Panel", .{}, .{ .expand = .horizontal }) != null) {
            deferRun(editor, .action, "hide_terminal_panel");
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Close Terminal", .{}, .{ .expand = .horizontal }) != null) {
            deferRun(editor, .action, "close_terminal_panel");
            fw.close();
        }
    }
}

/// Keys and text for the focused terminal pane while it owns the keyboard
/// (terminalTakesKeys). Printable characters come from `.text` events only,
/// so the OS keyboard layout decides what a key types (Shift+7 on a German
/// layout is `/`; AltGr and dead keys work); key events carry the special
/// keys and the Ctrl/Alt chords. `owner` is who `term` is for: the focused
/// terminal pane (`.terminal`) or the terminal panel (`.terminal_panel`);
/// the events are taken only while that owner has the keyboard. A null
/// `maybe_term` (a slot without a shell) keeps the chords and swallows the
/// rest. Returns true if the terminal was closed and the caller must stop
/// using the terminal.
fn handleTerminalKeyEvents(editor: *Editor, maybe_term: ?*terminal_mod.Terminal, wd: *dvui.WidgetData, owner: Editor.KeyboardOwner) bool {
    if (!build_options.has_gui) return false;

    const events = dvui.events();
    // The shell has ended: the next key closes the pane (the pane says so)
    // — once per frame, deferred like the chords since it changes the
    // layout.
    var closing = false;
    for (events, 0..) |*e, i| {
        if (e.handled) continue;
        if (guiMode(editor) != .normal or editor.keyboardOwner() != owner) break;

        switch (e.evt) {
            .key => |key| {
                if (key.action != .down and key.action != .repeat) continue;
                if (isModifierKey(key.code)) continue;

                // Pane / window / terminal management chords (ctrl+` toggle,
                // ctrl+alt+q close, ctrl+alt+` detach, F6 focus, ...) are not
                // typed into the shell. They mutate the layout, so they run
                // after the panes finished rendering (DeferredQueue).
                if (key.mod.control() or key.mod.alt() or isFKey(key.code)) {
                    if (chordAction(editor, key, true)) |action| {
                        e.handle(@src(), wd);
                        deferRun(editor, .action, action);
                        continue;
                    }
                }
                const term = maybe_term orelse {
                    e.handle(@src(), wd); // nothing to type into
                    continue;
                };
                if (term.exited) {
                    e.handle(@src(), wd);
                    if (!closing) {
                        closing = true;
                        deferRun(editor, .action, "close_terminal");
                    }
                    continue;
                }

                var out: [16]u8 = undefined;
                // Special keys (arrows, F-keys, enter, backspace, etc.) with
                // modifiers — arrows in the program's cursor-key mode.
                const special_cp: u21 = mapDvuiKey(key.code);
                if (special_cp != 0) {
                    e.handle(@src(), wd);
                    const n = encodeSpecialKey(term, special_cp, key.mod.control(), key.mod.alt(), key.mod.shift(), &out);
                    if (n > 0) term.writeInput(out[0..n]);
                    continue;
                }

                // Printable keys type through their text event. A Ctrl or
                // Alt chord has none and is encoded here from the key's
                // unshifted character, unless the keystroke typed one after
                // all (AltGr; Ctrl+Alt on Windows) — then its text wins.
                const base = printableKeyChar(key.code) orelse continue;
                const text_ev = keystrokeText(events, i);
                const route = terminalKeyRoute(key.mod.control(), key.mod.alt(), text_ev != null);
                if (route == .text) continue;
                e.handle(@src(), wd);
                if (route == .chord_drop_text) text_ev.?.handled = true;
                const cp: u21 = if (key.mod.shift() and !key.mod.control()) std.ascii.toUpper(base) else base;
                const n = terminal_mod.Terminal.encodeKey(cp, key.mod.control(), key.mod.alt(), false, &out);
                if (n > 0) term.writeInput(out[0..n]);
            },
            .text => |te| switch (te.action) {
                .value => |val| {
                    // IME composition updates are not final text; control
                    // characters come as key events.
                    if (val.selected or !isTypedText(val.txt)) continue;
                    e.handle(@src(), wd);
                    const term = maybe_term orelse continue;
                    if (term.exited) {
                        if (!closing) {
                            closing = true;
                            deferRun(editor, .action, "close_terminal");
                        }
                        continue;
                    }
                    term.writeInput(val.txt);
                },
                else => {},
            },
            else => {},
        }
    }
    return false;
}

/// How the terminal treats a printable key-down (handleTerminalKeyEvents).
const TermKeyRoute = enum {
    /// Its text event types it: a plain or Shift key, or a character that
    /// AltGr (or Ctrl+Alt on Windows) produced.
    text,
    /// Encode the Ctrl/Alt chord from the key event.
    chord,
    /// Encode the Ctrl chord and drop the keystroke's text event (Windows
    /// types a ' ' with Ctrl+Space that must not follow its NUL).
    chord_drop_text,
};

fn terminalKeyRoute(ctrl: bool, alt: bool, has_text: bool) TermKeyRoute {
    if (!ctrl and !alt) return .text;
    if (alt) return if (has_text) .text else .chord;
    return if (has_text) .chord_drop_text else .chord;
}

/// The final text event a keystroke produced, if any: SDL queues it right
/// behind the key-down, before the next key event.
fn keystrokeText(events: []dvui.Event, key_index: usize) ?*dvui.Event {
    for (events[key_index + 1 ..]) |*e| {
        switch (e.evt) {
            .text => |te| return if (!e.handled and te.action == .value and !te.action.value.selected) e else null,
            .key => return null,
            else => {},
        }
    }
    return null;
}

/// Text a key typed: no control bytes (those arrive as key events).
fn isTypedText(txt: []const u8) bool {
    if (txt.len == 0) return false;
    for (txt) |b| {
        if (b < 0x20 or b == 0x7f) return false;
    }
    return true;
}

/// Map DVUI key enum to a codepoint for terminal key encoding (the keys
/// that never arrive as text); 0 for any other key. Space is printable: it
/// types through its text event, and Ctrl/Alt+Space go through
/// printableKeyChar.
fn mapDvuiKey(key: dvui.enums.Key) u21 {
    return switch (key) {
        .up => 0xF700,
        .down => 0xF701,
        .left => 0xF702,
        .right => 0xF703,
        .home => 0xF704,
        .end => 0xF705,
        .page_up => 0xF706,
        .page_down => 0xF707,
        .insert => 0xF708,
        .delete => 0xF709,
        .enter => 0x0D,
        .tab => 0x09,
        .backspace => 0x08,
        .escape => 0x1B,
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => terminal_mod.key_f1 + @as(u21, @intCast(@intFromEnum(key) - @intFromEnum(dvui.enums.Key.f1))),
        else => 0,
    };
}

/// Terminal.encodeKey, in application cursor-key mode (DECCKM: ncurses
/// programs expect ESC O A for Up) when the program switched it on.
fn encodeSpecialKey(term: *terminal_mod.Terminal, key: u21, ctrl: bool, alt: bool, shift: bool, out: *[16]u8) u8 {
    return terminal_mod.Terminal.encodeKeyMode(key, ctrl, alt, shift, term.appCursorKeys(), out);
}

/// The unshifted character of a printable key, for the terminal's Ctrl/Alt
/// chords (Ctrl+C → ETX, Alt+b → ESC b). Plain typing never uses this: the
/// layout's text events do.
fn printableKeyChar(code: dvui.enums.Key) ?u8 {
    return switch (code) {
        .space => ' ',
        .backslash => '\\',
        else => {
            const name = key_name_map.get(@tagName(code)) orelse return null;
            return if (name.len == 1) name[0] else null;
        },
    };
}

/// Right-click context menu for an editor pane. The ContextWidget consumes
/// right presses inside `area`; handleMouseEvents has already focused the
/// pane and placed the cursor at the click point.
fn paneContextMenu(editor: *Editor, pane_id: u8, area: dvui.Rect.Physical) void {
    const ctext = dvui.context(@src(), .{ .rect = area }, .{ .id_extra = pane_id });
    defer ctext.deinit();

    if (ctext.activePoint()) |cp| {
        var fw = dvui.floatingMenu(@src(), .{ .from = dvui.Rect.Natural.fromPoint(cp) }, .{});
        defer fw.deinit();

        if (dvui.menuItemLabel(@src(), "Cut              Ctrl+X", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("cut", null);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Copy             Ctrl+C", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("copy", null);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Paste            Ctrl+V", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("paste", null);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Select All       Ctrl+A", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("select_all", null);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Save Selection as Snippet…  Ctrl+Alt+S", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execCommand("snippet_save_selection", null);
            fw.close();
        }
        if (dvui.menuItemLabel(@src(), "Go to Definition F12", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execAction("lsp_goto_definition");
            fw.close();
        }
    }
}

/// Handle mouse events for the custom editor pane.
fn handleMouseEvents(editor: *Editor, pane_id: u8, wd: *dvui.WidgetData, area: dvui.Rect.Physical, font: dvui.Font, line_height: f32, scale: f32) void {
    defer editor.validateSnippetState();
    const pane_doc_idx = switch (winLayout(editor, cur_win).panes.items[pane_id].content) {
        .editor => |idx| idx,
        .terminal => return,
    };
    const doc = &editor.documents.items[pane_doc_idx];
    const tab_width = editor.tabWidthFor(doc);
    const do_wrap = editor.wordWrapFor(doc);
    // `area` is the text area (gutter trimmed), so its width is the wrap width.
    const sb_max_top = editorMaxScrollTop(doc, font, area.w / scale, editorSbVisLines(area, line_height), tab_width, do_wrap);
    const double_click_threshold_ms: u64 = 400;
    const double_click_distance: f32 = 5; // pixels

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;

        const me = e.evt.mouse;

        // Only match events inside our area (or drag/scrollbar-drag continuation)
        if (!win_ui.drag_active and !(win_ui.editor_sb_drag and win_ui.editor_sb_pane == pane_id)) {
            if (me.p.x < area.x or me.p.x > area.x + area.w or
                me.p.y < area.y or me.p.y > area.y + area.h)
                continue;
        }

        switch (me.action) {
            .focus => {
                e.handle(@src(), wd);
                dvui.focusWidget(wd.id, null, e.num);
            },
            .press => {
                editor.dismissStatus();
                if (me.button == .right) {
                    // Right-click: focus the pane and move the cursor to the
                    // click point — unless it lands inside the current
                    // selection (standard context-menu behavior, so Cut/Copy
                    // act on the selection). Deliberately left unhandled: the
                    // pane's ContextWidget (created after this) consumes the
                    // press and opens the context menu.
                    // Focusing the pane takes the keyboard from the side panels.
                    editor.focusPaneIn(cur_win, pane_id);
                    const offset = screenToOffset(doc, area, font, line_height, scale, me.p, tab_width, do_wrap);
                    const c = doc.cursors.primary();
                    const inside_selection = if (c.selectionRange()) |r|
                        offset >= r.start and offset <= r.end
                    else
                        false;
                    if (!inside_selection) {
                        if (doc.cursors.count() > 1) doc.cursors.clearSecondary();
                        c.clearSelection();
                        c.offset = offset;
                        c.preferred_col = doc.buffer.offsetToPos(offset).col;
                    }
                    continue;
                }

                e.handle(@src(), wd);
                dvui.focusWidget(wd.id, null, e.num);
                win_ui.scroll_pinned = false;

                // Focus this pane on click (it takes the keyboard back from
                // the tree and the search panel)
                editor.focusPaneIn(cur_win, pane_id);

                // Scrollbar band: drag the thumb, or page toward the click.
                if (me.p.x >= area.x + area.w - editor_sb_band * scale) {
                    if (editorSbThumb(doc, area, line_height, scale, sb_max_top)) |thumb| {
                        win_ui.scroll_pinned = true;
                        if (me.p.y >= thumb.y and me.p.y < thumb.y + thumb.h) {
                            win_ui.editor_sb_drag = true;
                            win_ui.editor_sb_pane = pane_id;
                            win_ui.editor_sb_grab_dy = me.p.y - thumb.y;
                        } else {
                            const vis = editorSbVisLines(area, line_height);
                            if (me.p.y < thumb.y) {
                                doc.scroll_top -|= vis;
                            } else {
                                doc.scroll_top = @min(doc.scroll_top + vis, sb_max_top);
                            }
                        }
                        continue;
                    }
                }

                const offset = screenToOffset(doc, area, font, line_height, scale, me.p, tab_width, do_wrap);

                // Alt+click: add a cursor; Shift+Alt+drag: block selection
                if (me.mod.alt()) {
                    if (me.mod.shift()) {
                        const p = doc.buffer.offsetToPos(offset);
                        doc.cursors.clearSecondary();
                        const c = doc.cursors.primary();
                        c.clearSelection();
                        c.offset = offset;
                        c.preferred_col = p.col;
                        win_ui.drag_active = true;
                        win_ui.drag_pane = pane_id;
                        win_ui.drag_mode = .block;
                        win_ui.block_anchor_line = p.line;
                        win_ui.block_anchor_col = p.col;
                    } else {
                        addCursorAt(doc, offset);
                    }
                    continue;
                }

                const c = doc.cursors.primary();

                // Regular click clears secondary cursors
                if (editor.click_clears_cursors and doc.cursors.count() > 1) {
                    doc.cursors.clearSecondary();
                }

                // Detect multi-click (double/triple)
                const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
                const elapsed_ms: u64 = if (now_ns > win_ui.last_click_time_ns)
                    @intCast(@divFloor(now_ns - win_ui.last_click_time_ns, std.time.ns_per_ms))
                else
                    double_click_threshold_ms + 1;

                // Check if click is close in time and position to previous
                const pos_close = blk: {
                    const click_pos = doc.buffer.offsetToPos(offset);
                    const last_pos = doc.buffer.offsetToPos(win_ui.last_click_offset);
                    _ = double_click_distance;
                    break :blk click_pos.line == last_pos.line and
                        (if (click_pos.col > last_pos.col) click_pos.col - last_pos.col else last_pos.col - click_pos.col) < 10;
                };

                if (elapsed_ms < double_click_threshold_ms and pos_close) {
                    win_ui.click_count = if (win_ui.click_count >= 3) 1 else win_ui.click_count + 1;
                } else {
                    win_ui.click_count = 1;
                }
                win_ui.last_click_time_ns = now_ns;
                win_ui.last_click_offset = offset;

                if (me.mod.shift()) {
                    // Shift+click extends selection
                    if (c.anchor == null) c.anchor = c.offset;
                    c.offset = offset;
                    c.preferred_col = doc.buffer.offsetToPos(offset).col;
                } else if (win_ui.click_count == 2) {
                    // Double-click: select word
                    const ws = wordBoundaryAt(doc, offset);
                    c.anchor = ws.start;
                    c.offset = ws.end;
                    c.preferred_col = doc.buffer.offsetToPos(ws.end).col;
                    win_ui.drag_active = true;
                    win_ui.drag_pane = pane_id;
                    win_ui.drag_mode = .word;
                    win_ui.drag_word_start = ws.start;
                    win_ui.drag_word_end = ws.end;
                } else if (win_ui.click_count == 3) {
                    // Triple-click: select entire line
                    const ls = lineBoundaryAt(doc, offset);
                    c.anchor = ls.start;
                    c.offset = ls.end;
                    c.preferred_col = doc.buffer.offsetToPos(ls.end).col;
                    win_ui.drag_active = true;
                    win_ui.drag_pane = pane_id;
                    win_ui.drag_mode = .line;
                    win_ui.drag_word_start = ls.start;
                    win_ui.drag_word_end = ls.end;
                } else {
                    // Single click: place cursor
                    c.offset = offset;
                    c.preferred_col = doc.buffer.offsetToPos(offset).col;
                    c.clearSelection();
                    win_ui.drag_active = true;
                    win_ui.drag_pane = pane_id;
                    win_ui.drag_mode = .char;
                    win_ui.drag_anchor_offset = offset;
                }
            },
            .release => {
                if (win_ui.editor_sb_drag and win_ui.editor_sb_pane == pane_id) {
                    e.handle(@src(), wd);
                    win_ui.editor_sb_drag = false;
                }
                if (win_ui.drag_active and win_ui.drag_pane == pane_id) {
                    e.handle(@src(), wd);
                    win_ui.drag_active = false;
                }
            },
            .motion => {
                if (win_ui.editor_sb_drag and win_ui.editor_sb_pane == pane_id) {
                    e.handle(@src(), wd);
                    if (editorSbThumb(doc, area, line_height, scale, sb_max_top)) |thumb| {
                        const usable = area.h - thumb.h;
                        if (usable > 0) {
                            const denom: f32 = @floatFromInt(sb_max_top);
                            const frac = std.math.clamp((me.p.y - win_ui.editor_sb_grab_dy - area.y) / usable, 0.0, 1.0);
                            doc.scroll_top = @intFromFloat(@round(frac * denom));
                        }
                    }
                    continue;
                }
                if (win_ui.drag_active and win_ui.drag_pane == pane_id) {
                    e.handle(@src(), wd);
                    // Auto-scroll when dragging past edges
                    const live_area = wd.contentRectScale().r;
                    if (me.p.y < live_area.y and doc.scroll_top > 0) {
                        doc.scroll_top -|= 1;
                    } else if (me.p.y > live_area.y + live_area.h) {
                        if (doc.scroll_top < sb_max_top) doc.scroll_top += 1;
                    }
                    const offset = screenToOffset(doc, area, font, line_height, scale, me.p, tab_width, do_wrap);
                    const c = doc.cursors.primary();

                    switch (win_ui.drag_mode) {
                        .char => {
                            c.offset = offset;
                            c.preferred_col = doc.buffer.offsetToPos(offset).col;
                            c.anchor = win_ui.drag_anchor_offset;
                        },
                        .word => {
                            // Extend selection by word boundaries, always keeping original word selected
                            const ws = wordBoundaryAt(doc, offset);
                            if (offset < win_ui.drag_word_start) {
                                // Dragging above original word
                                c.anchor = win_ui.drag_word_end;
                                c.offset = @min(ws.start, win_ui.drag_word_start);
                            } else if (offset >= win_ui.drag_word_end) {
                                // Dragging below original word
                                c.anchor = win_ui.drag_word_start;
                                c.offset = @max(ws.end, win_ui.drag_word_end);
                            } else {
                                // Still within original word
                                c.anchor = win_ui.drag_word_start;
                                c.offset = win_ui.drag_word_end;
                            }
                            c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
                        },
                        .line => {
                            // Extend selection by line boundaries, always keeping original line selected
                            const ls = lineBoundaryAt(doc, offset);
                            if (offset < win_ui.drag_word_start) {
                                c.anchor = win_ui.drag_word_end;
                                c.offset = @min(ls.start, win_ui.drag_word_start);
                            } else if (offset >= win_ui.drag_word_end) {
                                c.anchor = win_ui.drag_word_start;
                                c.offset = @max(ls.end, win_ui.drag_word_end);
                            } else {
                                c.anchor = win_ui.drag_word_start;
                                c.offset = win_ui.drag_word_end;
                            }
                            c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
                        },
                        .block => {
                            // Block (column) selection: cursor per line, same col span
                            const p = doc.buffer.offsetToPos(offset);
                            doc.cursors.setBlockSelection(
                                &doc.buffer,
                                win_ui.block_anchor_line,
                                win_ui.block_anchor_col,
                                p.line,
                                p.col,
                            ) catch {};
                        },
                    }
                }
            },
            .wheel_y => |delta| {
                e.handle(@src(), wd);
                win_ui.scroll_pinned = true;
                const lines_per_notch: f32 = 3;
                const pixels_per_notch: f32 = dvui.scroll_speed;
                const scroll_lines: i32 = @intFromFloat(@round(-delta / pixels_per_notch * lines_per_notch));
                const new_top = @as(i64, @intCast(doc.scroll_top)) + scroll_lines;
                const max_top: i64 = @intCast(doc.buffer.lineCount() -| 1);
                doc.scroll_top = @intCast(@max(0, @min(new_top, max_top)));
            },
            .position => {
                if (me.p.x >= area.x and me.p.x <= area.x + area.w and
                    me.p.y >= area.y and me.p.y <= area.y + area.h)
                {
                    const in_band = me.p.x >= area.x + area.w - editor_sb_band * scale and
                        editorSbThumb(doc, area, line_height, scale, sb_max_top) != null;
                    win_ui.editor_sb_hover_pane = if (in_band) pane_id else null;
                    if (!in_band) dvui.cursorSet(.ibeam);
                }
            },
            else => {},
        }
    }
}

/// Find word boundaries around a byte offset (for double-click selection).
/// Every byte of a non-ASCII character is a word byte (cursor.isWordByte),
/// so `café` selects whole and a boundary never splits a character.
fn wordBoundaryAt(doc: *Document, offset: usize) struct { start: usize, end: usize } {
    const buf_len = doc.buffer.byteLen();
    const content = doc.buffer.slice(0, buf_len);
    if (content.len == 0) return .{ .start = 0, .end = 0 };

    const pos = @min(offset, content.len -| 1);

    if (cursor_mod.isWordByte(content[pos])) {
        // Inside a word — expand both directions
        var start = pos;
        while (start > 0 and cursor_mod.isWordByte(content[start - 1])) start -= 1;
        var end = pos;
        while (end < content.len and cursor_mod.isWordByte(content[end])) end += 1;
        return .{ .start = start, .end = end };
    } else {
        // On whitespace/punctuation — select the run of non-word chars
        var start = pos;
        while (start > 0 and !cursor_mod.isWordByte(content[start - 1]) and content[start - 1] != '\n') start -= 1;
        var end = pos;
        while (end < content.len and !cursor_mod.isWordByte(content[end]) and content[end] != '\n') end += 1;
        return .{ .start = start, .end = end };
    }
}

/// Find line boundaries around a byte offset (for triple-click selection).
fn lineBoundaryAt(doc: *const Document, offset: usize) struct { start: usize, end: usize } {
    const pos = doc.buffer.offsetToPos(offset);
    const line_start = doc.buffer.posToOffset(pos.line, 0);
    const line_end = if (pos.line + 1 < doc.buffer.lineCount())
        doc.buffer.posToOffset(pos.line + 1, 0) // include the newline
    else
        doc.buffer.byteLen();
    return .{ .start = line_start, .end = line_end };
}

/// Convert a screen position (physical pixels) to a byte offset in the buffer.
/// `do_wrap` must match the rendering mode — mapping clicks through wrapped
/// rows while rendering unwrapped (or vice versa) lands on the wrong line.
fn screenToOffset(doc: *Document, area: dvui.Rect.Physical, font: dvui.Font, line_height: f32, scale: f32, p: dvui.Point.Physical, tab_width: usize, do_wrap: bool) usize {
    const rel_y = p.y - area.y;
    const clicked_visual_row: usize = if (rel_y >= 0) @intFromFloat(@floor(rel_y / line_height)) else 0;

    const line_count = doc.buffer.lineCount();
    const char_width = font.textSize("M").w * scale;
    const scroll_x_px: f32 = @as(f32, @floatFromInt(doc.scroll_left)) * char_width;

    const text_area_w = area.w / scale;

    // Walk through logical lines from scroll_top, counting visual rows
    var visual_rows_consumed: usize = 0;
    var line_idx: usize = doc.scroll_top;

    while (line_idx < line_count) {
        const orig_line = doc.buffer.lineContent(line_idx);
        var exp_buf: [16384]u8 = undefined;
        const line_text = displayLine(orig_line, tab_width, &exp_buf);
        const needs_wrap = do_wrap and line_text.len > 0 and @as(f32, @floatFromInt(line_text.len)) * (char_width / scale) > text_area_w;

        var byte_pos: usize = 0;
        while (true) {
            const row_start = byte_pos;
            const row_end = if (needs_wrap)
                guiWrapAdvanceRow(line_text, font, text_area_w, byte_pos)
            else
                line_text.len;

            if (visual_rows_consumed == clicked_visual_row) {
                // This is the row that was clicked
                const segment = line_text[row_start..row_end];
                const rel_x = p.x - area.x + scroll_x_px;
                if (rel_x <= 0 or segment.len == 0) {
                    const buf_col = expColToBufCol(orig_line, row_start, tab_width);
                    return cursor_mod.lineOffset(&doc.buffer, line_idx, buf_col);
                }

                const target_x = rel_x / scale;
                var end_idx: usize = 0;
                _ = font.textSizeEx(segment, .{ .max_width = target_x, .end_idx = &end_idx, .end_metric = .nearest });
                // Convert expanded position back to buffer position
                const buf_col = expColToBufCol(orig_line, row_start + end_idx, tab_width);
                return cursor_mod.lineOffset(&doc.buffer, line_idx, buf_col);
            }

            visual_rows_consumed += 1;
            byte_pos = row_end;
            if (!needs_wrap or byte_pos >= line_text.len) break;
        }
        line_idx += 1;
    }

    // Clicked past end of file
    return doc.buffer.byteLen();
}

/// Handle keyboard events for the GUI, routing through our core command system.
fn handleGuiKeyEvents(editor: *Editor, wd: *dvui.WidgetData) bool {
    editor.validateSnippetState();
    defer editor.validateSnippetState();
    const is_focused = if (dvui.focusedWidgetId()) |fid| fid == wd.id else false;
    var handled_any = false;

    // --- Modal input handling ---
    if (guiMode(editor) != .normal) {
        // Settings and the snippet form are real DVUI floating dialogs
        // whose widgets already consumed their events (declared before the
        // panes). Only catch a leftover Escape to close them — swallowing
        // everything here would break Tab navigation and text entry inside
        // the dialog. (The snippet form takes Escape itself first: a
        // focused entry would swallow it before it got here.)
        if (editor.mode == .settings or editor.mode == .snippet_form) {
            for (dvui.events()) |*e| {
                if (e.handled) continue;
                if (e.evt != .key) continue;
                const key = e.evt.key;
                if (key.action != .down and key.action != .repeat) continue;
                if (key.code == .escape) {
                    e.handle(@src(), wd);
                    handled_any = true;
                    if (editor.mode == .snippet_form) editor.cancelSnippetForm() else editor.setMode(.normal);
                    // The dialog subwindow disappears next frame — refocus
                    // the base window so editor keys work immediately.
                    dvui.focusSubwindow(null, null);
                }
            }
            return handled_any;
        }

        const mode = editor.mode;
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            // A key that closed or switched the prompt ends its input: the
            // rest never reaches the next prompt (a second `s` staging
            // after "save and stage", say).
            if (editor.mode != mode) break;
            switch (e.evt) {
                .key => |key| {
                    if (key.action != .down and key.action != .repeat) continue;
                    e.handle(@src(), wd);
                    handled_any = true;
                    handleModalKey(editor, key);
                },
                .text => |te| {
                    switch (te.action) {
                        .value => |val| {
                            // `selected` = uncommitted IME composition.
                            if (val.txt.len > 0 and !val.selected) {
                                e.handle(@src(), wd);
                                handled_any = true;
                                handleModalText(editor, val.txt);
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        return handled_any;
    }

    for (dvui.events()) |*e| {
        if (e.handled) continue;

        switch (e.evt) {
            .key => |key| {
                if (key.action != .down and key.action != .repeat) continue;

                // Skip modifier-only keys
                if (key.code == .left_shift or key.code == .right_shift or
                    key.code == .left_control or key.code == .right_control or
                    key.code == .left_alt or key.code == .right_alt or
                    key.code == .left_command or key.code == .right_command)
                    continue;

                // Any real key press un-pins scroll (cursor tracking resumes)
                // and drops the previous transient status message (a new
                // one keeps its time on the bar: dismissStatus)
                win_ui.scroll_pinned = false;
                editor.dismissStatus();

                // Ctrl/Alt shortcuts handled by the early event loop in frame()
                if (key.mod.control() or key.mod.alt()) continue;

                // Movement and special keys — only when focused
                if (!is_focused) continue;
                if (handleGuiSnippetOrCompletionKey(editor, key)) {
                    e.handle(@src(), wd);
                    handled_any = true;
                    continue;
                }
                const shift = key.mod.shift();
                switch (key.code) {
                    .up => {
                        e.handle(@src(), wd);
                        if (editor.wordWrapFor(editor.activeDoc())) {
                            guiMoveVisualVertical(editor, .up, shift);
                        } else {
                            _ = editor.execCommand(if (shift) "cursor_up_select" else "cursor_up", null);
                        }
                    },
                    .down => {
                        e.handle(@src(), wd);
                        if (editor.wordWrapFor(editor.activeDoc())) {
                            guiMoveVisualVertical(editor, .down, shift);
                        } else {
                            _ = editor.execCommand(if (shift) "cursor_down_select" else "cursor_down", null);
                        }
                    },
                    .left => {
                        e.handle(@src(), wd);
                        _ = editor.execCommand(if (shift) "cursor_left_select" else "cursor_left", null);
                    },
                    .right => {
                        e.handle(@src(), wd);
                        _ = editor.execCommand(if (shift) "cursor_right_select" else "cursor_right", null);
                    },
                    .home => {
                        e.handle(@src(), wd);
                        _ = editor.execCommand(if (shift) "smart_home_select" else "smart_home", null);
                    },
                    .end => {
                        e.handle(@src(), wd);
                        _ = editor.execCommand(if (shift) "cursor_end_select" else "cursor_end", null);
                    },
                    .page_up => {
                        e.handle(@src(), wd);
                        _ = editor.execCommand("page_up", null);
                    },
                    .page_down => {
                        e.handle(@src(), wd);
                        _ = editor.execCommand("page_down", null);
                    },
                    .backspace => {
                        e.handle(@src(), wd);
                        _ = editor.execCommand("delete_backward", null);
                    },
                    .delete => {
                        e.handle(@src(), wd);
                        _ = editor.execCommand("delete_forward", null);
                    },
                    .enter => {
                        e.handle(@src(), wd);
                        _ = editor.execCommand("insert_newline_auto", null);
                    },
                    .tab => {
                        e.handle(@src(), wd);
                        if (shift) {
                            _ = editor.execCommand("dedent", null);
                        } else {
                            _ = editor.execCommand("indent", null);
                        }
                    },
                    .escape => {
                        _ = editor.execCommand("escape_multicursor", null);
                        e.handle(@src(), wd);
                    },
                    else => {},
                }
                if (e.handled) handled_any = true;
            },
            .text => |te| {
                // Text input from SDL — only when focused
                if (!is_focused) continue;
                switch (te.action) {
                    .value => |val| {
                        // Filter control chars (Tab, Enter, etc.) — handled
                        // as key events — and uncommitted IME composition
                        // (`selected`): only the committed text is typed.
                        if (val.txt.len > 0 and val.txt[0] >= 32 and !val.selected) {
                            e.handle(@src(), wd);
                            handled_any = true;
                            // Windows types a " " for Ctrl+Space; the chord already ran.
                            if (win_ui.swallow_space and std.mem.eql(u8, val.txt, " ")) {
                                win_ui.swallow_space = false;
                                continue;
                            }
                            _ = editor.execCommand("insert_char", val.txt);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    return handled_any;
}

/// Called in event order, only by the editor widget which owns keyboard focus.
fn handleGuiSnippetOrCompletionKey(editor: *Editor, key: dvui.Event.Key) bool {
    if (!editor.editorOwnsInput() or key.mod.control() or key.mod.alt() or key.mod.command()) return false;
    const snippet_key: ?Editor.SnippetKey = switch (key.code) {
        .tab => if (key.mod.shift()) .shift_tab else .tab,
        .escape => .escape,
        else => null,
    };
    if (snippet_key) |k| if (editor.handleSnippetKey(k)) return true;
    if (!editor.completion_active) return false;
    const count = editor.completion_items.items.len;
    switch (key.code) {
        .escape => editor.clearCompletionItems(),
        .enter => editor.acceptCompletion(),
        .up => editor.completion_selected = if (editor.completion_selected > 0) editor.completion_selected - 1 else count -| 1,
        .down => if (count > 0) {
            editor.completion_selected = (editor.completion_selected + 1) % count;
        },
        else => {
            // Letters, digits, `_` and the server's trigger characters keep
            // the popup: their text event refilters or re-requests it.
            if (!completionKeepsOnKey(editor, key)) editor.clearCompletionItems();
            return false;
        },
    }
    return true;
}

/// A key-down that will type an identifier byte or a completion trigger
/// character (its text event follows). Chords never count.
fn completionKeepsOnKey(editor: *Editor, key: dvui.Event.Key) bool {
    if (hasCommandMod(key.mod)) return false;
    return switch (key.code) {
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z, .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine => true,
        .minus => key.mod.shift(), // '_'
        .period => editor.completionKeepsOnByte('.'),
        else => false,
    };
}

/// Execute an action with GUI-specific overrides (native file dialogs).
fn execGuiAction(editor: *Editor, action: []const u8) void {
    // New action — drop the previous transient status message
    editor.dismissStatus();
    // The file tree, Snippets and search panels live in the primary
    // window: bring it forward when their actions run from a secondary one.
    if (editor.active_window != 0 and isPrimaryPanelAction(action)) {
        editor.focusWindow(0);
        raisePrimaryWindow();
    }
    if (std.mem.eql(u8, action, "save")) {
        save(editor);
        return;
    }
    if (std.mem.eql(u8, action, "save_as")) {
        saveAs(editor);
        return;
    }
    if (std.mem.eql(u8, action, "file_open")) {
        openFileDialog(editor);
        return;
    }
    if (std.mem.eql(u8, action, "open_folder")) {
        openFolderDialog(editor);
        return;
    }
    // Visual-row-aware multi-cursor add when word wrap is on
    if (editor.wordWrapFor(editor.activeDoc())) {
        if (std.mem.eql(u8, action, "add_cursor_above")) {
            guiAddCursorVisual(editor, .up);
            return;
        }
        if (std.mem.eql(u8, action, "add_cursor_below")) {
            guiAddCursorVisual(editor, .down);
            return;
        }
    }
    // Everything else goes through the core editor
    _ = editor.execAction(action);
}

/// Keybind key name (contract 6 vocabulary: a-z, 0-9, f1-f12, the named
/// keys and `[ ] ; ' , . / - =` and backtick) for each dvui key tag.
/// Plain strings, so the core test build — which has no dvui — can check
/// the table; the comptime block below checks every tag against dvui's
/// enum in GUI builds.
const key_name_pairs = .{
    .{ "a", "a" },            .{ "b", "b" },             .{ "c", "c" },                 .{ "d", "d" },
    .{ "e", "e" },            .{ "f", "f" },             .{ "g", "g" },                 .{ "h", "h" },
    .{ "i", "i" },            .{ "j", "j" },             .{ "k", "k" },                 .{ "l", "l" },
    .{ "m", "m" },            .{ "n", "n" },             .{ "o", "o" },                 .{ "p", "p" },
    .{ "q", "q" },            .{ "r", "r" },             .{ "s", "s" },                 .{ "t", "t" },
    .{ "u", "u" },            .{ "v", "v" },             .{ "w", "w" },                 .{ "x", "x" },
    .{ "y", "y" },            .{ "z", "z" },             .{ "zero", "0" },              .{ "one", "1" },
    .{ "two", "2" },          .{ "three", "3" },         .{ "four", "4" },              .{ "five", "5" },
    .{ "six", "6" },          .{ "seven", "7" },         .{ "eight", "8" },             .{ "nine", "9" },
    .{ "f1", "f1" },          .{ "f2", "f2" },           .{ "f3", "f3" },               .{ "f4", "f4" },
    .{ "f5", "f5" },          .{ "f6", "f6" },           .{ "f7", "f7" },               .{ "f8", "f8" },
    .{ "f9", "f9" },          .{ "f10", "f10" },         .{ "f11", "f11" },             .{ "f12", "f12" },
    .{ "up", "up" },          .{ "down", "down" },       .{ "left", "left" },           .{ "right", "right" },
    .{ "home", "home" },      .{ "end", "end" },         .{ "page_up", "page_up" },     .{ "page_down", "page_down" },
    .{ "insert", "insert" },  .{ "delete", "delete" },   .{ "backspace", "backspace" }, .{ "tab", "tab" },
    .{ "enter", "enter" },    .{ "escape", "escape" },   .{ "space", "space" },         .{ "backslash", "backslash" },
    .{ "left_bracket", "[" }, .{ "right_bracket", "]" }, .{ "semicolon", ";" },         .{ "apostrophe", "'" },
    .{ "comma", "," },        .{ "period", "." },        .{ "slash", "/" },             .{ "minus", "-" },
    .{ "equal", "=" },        .{ "grave", "`" },
};
const key_name_map = std.StaticStringMap([]const u8).initComptime(key_name_pairs);

comptime {
    if (build_options.has_gui) {
        for (key_name_pairs) |pair| {
            if (!@hasField(dvui.enums.Key, pair[0])) @compileError("no dvui key named " ++ pair[0]);
        }
    }
}

/// Convert a DVUI key event to a keybind map string (e.g. "ctrl+s",
/// "alt+up", "ctrl+1"); empty for a key with no keybind name.
fn dvuiKeyToStr(key: dvui.Event.Key, buf: *[64]u8) []const u8 {
    return comboString(key.mod.control(), key.mod.alt(), key.mod.shift(), @tagName(key.code), buf);
}

/// Same as dvuiKeyToStr but without the shift modifier.
fn dvuiKeyToStrNoShift(key: dvui.Event.Key, buf: *[64]u8) []const u8 {
    return comboString(key.mod.control(), key.mod.alt(), false, @tagName(key.code), buf);
}

/// `ctrl+alt+shift+` (the canonical order) plus the key name of dvui key
/// tag `tag`, or "" when the key has no name.
fn comboString(ctrl: bool, alt: bool, shift: bool, tag: []const u8, buf: *[64]u8) []const u8 {
    const name = key_name_map.get(tag) orelse return buf[0..0];
    var w: std.Io.Writer = .fixed(buf);
    if (ctrl) w.writeAll("ctrl+") catch return buf[0..0];
    if (alt) w.writeAll("alt+") catch return buf[0..0];
    if (shift) w.writeAll("shift+") catch return buf[0..0];
    w.writeAll(name) catch return buf[0..0];
    return w.buffered();
}

/// Open a native OS file dialog and open the selected file.
fn openFileDialog(editor: *Editor) void {
    if (!build_options.has_gui) return;

    const path = dvui.dialogNativeFileOpen(editor.allocator, .{
        .title = "Open File",
    }) catch return;

    if (path) |p| {
        defer editor.allocator.free(p);
        editor.recordNavPoint();
        _ = editor.openFile(p) catch |err| {
            if (err == error.EncodingRequired) return;
            if (err == error.BinaryFile) {
                guiNotify(editor, "Not opened: binary or unsupported text encoding", .{});
            } else {
                guiNotify(editor, "Open failed: {s}", .{@errorName(err)});
            }
        };
    }
}

/// Native folder picker for `open_folder`: the choice becomes the project.
fn openFolderDialog(editor: *Editor) void {
    if (!build_options.has_gui) return;
    const path = dvui.dialogNativeFolderSelect(editor.allocator, .{ .title = "Open Folder" }) catch return;
    if (path) |p| {
        defer editor.allocator.free(p);
        // The reason is already in the status bar, and it lives in
        // status_buf: toast it as it is (guiNotify would format the buffer
        // into itself).
        if (!editor.openProject(p)) dvui.toast(@src(), .{ .message = editor.status_message });
    }
}

fn handleRecentProjectsKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (hasCommandMod(key.mod)) return;
    const count = editor.recent_projects.items.len;
    switch (key.code) {
        .escape => editor.cancelRecentProjects(),
        .up => editor.recent_selected -|= 1,
        .down, .tab => if (count > 0) {
            editor.recent_selected = (editor.recent_selected + 1) % count;
        },
        .enter => editor.chooseRecentProject(editor.recent_selected),
        else => {},
    }
}

/// The `recent_projects` picker: one button per remembered folder.
fn recentProjectsDialog(editor: *Editor) void {
    var open = true;
    var dialog = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{ .min_size_content = .{ .w = 480 } });
    defer {
        dialog.deinit();
        if (!open) editor.cancelRecentProjects();
        if (editor.mode != .recent_projects or !open) dvui.focusSubwindow(null, null);
    }
    dialog.dragAreaSet(dvui.windowHeader("Recent projects", "", &open));
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(10) });
    defer box.deinit();
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .key or e.evt.key.action == .up) continue;
        handleRecentProjectsKeyGui(editor, e.evt.key);
        e.handle(@src(), box.data());
        if (editor.mode != .recent_projects) return;
    }
    for (editor.recent_projects.items, 0..) |path, idx| {
        if (dvui.button(@src(), path, .{}, .{
            .id_extra = idx,
            .expand = .horizontal,
            .style = if (idx == editor.recent_selected) .highlight else .control,
        })) {
            editor.chooseRecentProject(idx);
            return;
        }
    }
    if (dvui.button(@src(), "Cancel", .{}, .{})) editor.cancelRecentProjects();
}

/// Save the current document (or prompt Save As if no path).
fn save(editor: *Editor) void {
    switch (editor.saveDocument(editor.activeDoc().id, .{})) {
        .needs_path => saveAs(editor),
        else => {},
    }
}

/// Open a native OS save dialog and save the document to the selected path.
fn saveAs(editor: *Editor) void {
    if (!build_options.has_gui) return;
    if (editor.save_as_id == null) editor.startSaveAs(editor.activeDoc().id, null);
    const path = dvui.dialogNativeFileSave(editor.allocator, .{ .title = "Save As" }) catch {
        editor.cancelSaveAs();
        return;
    };
    if (path) |p| {
        defer editor.allocator.free(p);
        _ = editor.finishSaveAs(p);
    } else editor.cancelSaveAs();
}

/// Advance through `line` starting at `start_pos`, consuming up to `max_width`
/// logical (unscaled) pixels. Uses word-boundary wrapping: prefers breaking
/// after spaces. Returns the byte end position for this visual row.
fn guiWrapAdvanceRow(line: []const u8, font: dvui.Font, max_width: f32, start_pos: usize) usize {
    if (max_width <= 0) return line.len;
    const segment = line[start_pos..];
    if (segment.len == 0) return line.len;

    // Use textSizeEx to find where the text exceeds max_width in one call
    var end_idx: usize = 0;
    _ = font.textSizeEx(segment, .{ .max_width = max_width, .end_idx = &end_idx, .end_metric = .before });

    if (end_idx >= segment.len) {
        // Entire segment fits
        return line.len;
    }
    if (end_idx == 0) {
        // At least one character must advance to avoid infinite loop
        end_idx = 1;
        // Skip UTF-8 continuation bytes
        while (start_pos + end_idx < line.len and (line[start_pos + end_idx] & 0xC0) == 0x80) {
            end_idx += 1;
        }
        return start_pos + end_idx;
    }

    // Try to break at a word boundary (last space within the fitting portion)
    var last_space: ?usize = null;
    for (segment[0..end_idx], 0..) |byte, i| {
        if (byte == ' ') last_space = i + 1;
    }
    if (last_space) |sp| {
        if (sp > 0) return start_pos + sp;
    }
    return start_pos + end_idx;
}

/// Sticky column for Up/Down with word wrap on (Design 7): the pixel x each
/// cursor aims for, remembered with the offset it was placed at. While a
/// cursor still sits where the last vertical move (or add-cursor) put it
/// and the text is unchanged, the next move reuses that x, through short
/// lines and wrapped rows, instead of re-measuring from the caret. Any
/// other move, an edit or another document starts over from the caret.
const VerticalMotion = struct {
    const max_cursors = 64;

    doc_id: u64 = 0,
    version: u64 = 0,
    count: usize = 0,
    offsets: [max_cursors]usize = undefined,
    targets: [max_cursors]f32 = undefined,

    /// The remembered x for cursor `index` sitting at `offset`, if valid.
    fn target(self: *const VerticalMotion, doc_id: u64, version: u64, index: usize, offset: usize) ?f32 {
        if (self.doc_id != doc_id or self.version != version) return null;
        if (index >= self.count or self.offsets[index] != offset) return null;
        return self.targets[index];
    }

    /// Forget everything; later records are for `doc_id` at `version`.
    fn reset(self: *VerticalMotion, doc_id: u64, version: u64) void {
        self.* = .{ .doc_id = doc_id, .version = version };
    }

    /// Remember that cursor `index` was placed at `offset` aiming for `x`.
    fn remember(self: *VerticalMotion, index: usize, offset: usize, x: f32) void {
        if (index >= max_cursors) return;
        // Skipped indices get an offset no cursor can have.
        while (self.count <= index) : (self.count += 1) self.offsets[self.count] = std.math.maxInt(usize);
        self.offsets[index] = offset;
        self.targets[index] = x;
    }
};
var vertical_motion: VerticalMotion = .{};

/// offsetAtVisual row argument: the line's last visual row.
const last_visual_row = std.math.maxInt(usize);

/// Visual row of the caret at (`line`, byte `col`) within its wrapped line,
/// its pixel x (logical units) in that row, and the line's row count.
fn caretVisual(buf: *Buffer, line: usize, col: usize, font: dvui.Font, text_w: f32, tw: usize) struct { row: usize, x: f32, rows: usize } {
    const orig = buf.lineContent(line);
    var eb: [16384]u8 = undefined;
    const shown = displayLine(orig, tw, &eb);
    const v = guiWrapColToVisual(shown, font, text_w, displayCol(orig, shown, col, tw));
    return .{ .row = v.row, .x = v.px, .rows = guiWrapLineRows(shown, font, text_w) };
}

/// Buffer offset of the caret stop nearest pixel x on visual `row` of
/// `line` (last_visual_row = its last row), on a character boundary.
fn offsetAtVisual(buf: *Buffer, line: usize, row: usize, x: f32, font: dvui.Font, text_w: f32, tw: usize) usize {
    const orig = buf.lineContent(line);
    var eb: [16384]u8 = undefined;
    const shown = displayLine(orig, tw, &eb);
    const r = if (row == last_visual_row) guiWrapLineRows(shown, font, text_w) - 1 else row;
    const exp_col = guiWrapVisualToCol(shown, font, text_w, r, x);
    return cursor_mod.lineOffset(buf, line, expColToBufCol(orig, exp_col, tw));
}

/// Move every cursor up or down by one visual (wrapped) row. Each keeps
/// its sticky pixel x (VerticalMotion): Down through a short line comes
/// back out at the column it went in at.
fn guiMoveVisualVertical(editor: *Editor, direction: enum { up, down }, extend_selection: bool) void {
    if (!build_options.has_gui) return;

    const doc = editor.activeDoc();
    const buf = &doc.buffer;
    const font = dvui.Font.theme(.mono);
    const total_lines = buf.lineCount();
    const tw = editor.tabWidthFor(doc);
    const text_w: f32 = @floatFromInt(editor.text_width);

    // Where each cursor landed and the x it aims for, by pre-merge index.
    const Placed = struct { offset: usize, x: f32 };
    var placed: [VerticalMotion.max_cursors]Placed = undefined;
    var placed_n: usize = 0;
    for (doc.cursors.cursors.items, 0..) |*c, ci| {
        const pos = buf.offsetToPos(c.offset);
        const here = caretVisual(buf, pos.line, pos.col, font, text_w, tw);
        const x = vertical_motion.target(doc.id, buf.version, ci, c.offset) orelse here.x;

        if (extend_selection) {
            if (c.anchor == null) c.anchor = c.offset;
        } else {
            c.clearSelection();
        }

        switch (direction) {
            .up => if (here.row > 0) {
                c.offset = offsetAtVisual(buf, pos.line, here.row - 1, x, font, text_w, tw);
            } else if (pos.line > 0) {
                c.offset = offsetAtVisual(buf, pos.line - 1, last_visual_row, x, font, text_w, tw);
            },
            .down => if (here.row + 1 < here.rows) {
                c.offset = offsetAtVisual(buf, pos.line, here.row + 1, x, font, text_w, tw);
            } else if (pos.line + 1 < total_lines) {
                c.offset = offsetAtVisual(buf, pos.line + 1, 0, x, font, text_w, tw);
            },
        }
        if (ci < placed.len) {
            placed[ci] = .{ .offset = c.offset, .x = x };
            placed_n = ci + 1;
        }
    }
    doc.cursors.mergeCursors();
    // Merging sorts and dedups the secondaries: re-key by landing offset.
    vertical_motion.reset(doc.id, buf.version);
    for (doc.cursors.cursors.items, 0..) |c, ci| {
        for (placed[0..placed_n]) |p| {
            if (p.offset == c.offset) {
                vertical_motion.remember(ci, c.offset, p.x);
                break;
            }
        }
    }
}

/// Add a cursor one visual (wrapped) row above or below the outermost
/// cursor, at that cursor's sticky x (so repeated adds keep their column
/// through short lines), on a character boundary.
fn guiAddCursorVisual(editor: *Editor, direction: enum { up, down }) void {
    if (!build_options.has_gui) return;

    const doc = editor.activeDoc();
    const buf = &doc.buffer;
    const font = dvui.Font.theme(.mono);
    const total_lines = buf.lineCount();
    const tw = editor.tabWidthFor(doc);
    const text_w: f32 = @floatFromInt(editor.text_width);

    // Find the outermost cursor in the given direction
    var edge_idx: usize = 0;
    var edge_line: usize = 0;
    var edge_row: usize = 0;
    for (doc.cursors.cursors.items, 0..) |c, i| {
        const pos = buf.offsetToPos(c.offset);
        const row = caretVisual(buf, pos.line, pos.col, font, text_w, tw).row;
        const outer = i == 0 or switch (direction) {
            .up => pos.line < edge_line or (pos.line == edge_line and row < edge_row),
            .down => pos.line > edge_line or (pos.line == edge_line and row > edge_row),
        };
        if (outer) {
            edge_idx = i;
            edge_line = pos.line;
            edge_row = row;
        }
    }

    const ref = doc.cursors.cursors.items[edge_idx];
    const ref_pos = buf.offsetToPos(ref.offset);
    const here = caretVisual(buf, ref_pos.line, ref_pos.col, font, text_w, tw);
    const x = vertical_motion.target(doc.id, buf.version, edge_idx, ref.offset) orelse here.x;
    const new_offset = switch (direction) {
        .up => if (here.row > 0)
            offsetAtVisual(buf, ref_pos.line, here.row - 1, x, font, text_w, tw)
        else if (ref_pos.line > 0)
            offsetAtVisual(buf, ref_pos.line - 1, last_visual_row, x, font, text_w, tw)
        else
            return,
        .down => if (here.row + 1 < here.rows)
            offsetAtVisual(buf, ref_pos.line, here.row + 1, x, font, text_w, tw)
        else if (ref_pos.line + 1 < total_lines)
            offsetAtVisual(buf, ref_pos.line + 1, 0, x, font, text_w, tw)
        else
            return,
    };
    const before = doc.cursors.count();
    addCursorAt(doc, new_offset);
    if (doc.cursors.count() == before) return;
    // The new cursor is the next add's edge: it aims for the same x.
    if (vertical_motion.doc_id != doc.id or vertical_motion.version != buf.version) vertical_motion.reset(doc.id, buf.version);
    vertical_motion.remember(edge_idx, ref.offset, x);
    vertical_motion.remember(doc.cursors.count() - 1, new_offset, x);
}

/// CursorSet.addCursor plus the new cursor's sticky byte column (addCursor
/// leaves it at 0, so the next Up/Down with wrap off snapped it to column 0).
fn addCursorAt(doc: *Document, offset: usize) void {
    const before = doc.cursors.count();
    doc.cursors.addCursor(offset) catch return;
    if (doc.cursors.count() > before) {
        doc.cursors.cursors.items[doc.cursors.count() - 1].preferred_col = doc.buffer.offsetToPos(offset).col;
    }
}

/// Which visual wrap row byte column `byte_col` of display line `line`
/// falls on, and its pixel x (logical units, measured) within that row.
fn guiWrapColToVisual(line: []const u8, font: dvui.Font, max_width: f32, byte_col: usize) struct { row: usize, px: f32 } {
    const col = text_input.floor(line, byte_col);
    var row_start: usize = 0;
    var row: usize = 0;
    if (max_width > 0) {
        while (row_start < line.len) {
            const row_end = guiWrapAdvanceRow(line, font, max_width, row_start);
            // A column at a wrap point starts the next row (the line's
            // end stays on the last one).
            if (col < row_end or row_end >= line.len) break;
            row_start = row_end;
            row += 1;
        }
    }
    return .{ .row = row, .px = font.textSize(line[row_start..@max(row_start, col)]).w };
}

/// Byte column of display line `line` nearest pixel x `px` on visual row
/// `target_row` (the last row if the line has fewer), measured with the
/// font, on a character boundary. A wrapped row never returns its end,
/// which is the next row's start.
fn guiWrapVisualToCol(line: []const u8, font: dvui.Font, max_width: f32, target_row: usize, px: f32) usize {
    if (line.len == 0) return 0;
    var row_start: usize = 0;
    var row_end = if (max_width > 0) guiWrapAdvanceRow(line, font, max_width, 0) else line.len;
    var row: usize = 0;
    while (row < target_row and row_end < line.len) : (row += 1) {
        row_start = row_end;
        row_end = guiWrapAdvanceRow(line, font, max_width, row_start);
    }
    var end_idx: usize = 0;
    _ = font.textSizeEx(line[row_start..row_end], .{ .max_width = @max(px, 0), .end_idx = &end_idx, .end_metric = .nearest });
    const col = row_start + end_idx;
    if (col >= row_end and row_end < line.len and col > row_start) return text_input.floor(line, col - 1);
    return col;
}

/// Count how many visual rows a line occupies with pixel-based wrapping.
fn guiWrapLineRows(line: []const u8, font: dvui.Font, max_width: f32) usize {
    if (line.len == 0 or max_width <= 0) return 1;
    var rows: usize = 0;
    var pos: usize = 0;
    while (pos < line.len) {
        pos = guiWrapAdvanceRow(line, font, max_width, pos);
        rows += 1;
    }
    return if (rows == 0) 1 else rows;
}

/// Ensure the cursor is visible when word wrapping is active in the GUI.
/// Accounts for variable visual row heights per logical line using pixel-based wrapping.
fn guiEnsureCursorVisibleWrapped(doc: *Document, font: dvui.Font, text_area_w_logical: f32, visible_lines: usize, tab_width: usize) void {
    if (visible_lines == 0) return;
    const total_lines = doc.buffer.lineCount();
    const cursor_pos = doc.cursorPos();

    // If cursor line is above scroll_top, scroll up to it
    if (cursor_pos.line < doc.scroll_top) {
        doc.scroll_top = cursor_pos.line;
        return;
    }

    // Compute visual rows from scroll_top to cursor (with tab expansion)
    var visual_rows: usize = 0;
    var line_idx: usize = doc.scroll_top;
    while (line_idx < cursor_pos.line and line_idx < total_lines) : (line_idx += 1) {
        var eb: [16384]u8 = undefined;
        const shown = displayLine(doc.buffer.lineContent(line_idx), tab_width, &eb);
        visual_rows += guiWrapLineRows(shown, font, text_area_w_logical);
    }
    // Add cursor's row within its wrapped line
    const orig_cur = doc.buffer.lineContent(cursor_pos.line);
    var eb2: [16384]u8 = undefined;
    const cur_line = displayLine(orig_cur, tab_width, &eb2);
    const wrap_pos = guiWrapColToVisual(cur_line, font, text_area_w_logical, displayCol(orig_cur, cur_line, cursor_pos.col, tab_width));
    const cursor_visual_row = visual_rows + wrap_pos.row;

    // If cursor is visible, done
    if (cursor_visual_row < visible_lines) return;

    // Cursor is below viewport — scroll down.
    const target_row: usize = visible_lines * 2 / 3;
    var rows_needed: usize = wrap_pos.row;
    var new_top: usize = cursor_pos.line;
    while (new_top > 0 and rows_needed < target_row) {
        new_top -= 1;
        var eb3: [16384]u8 = undefined;
        const shown = displayLine(doc.buffer.lineContent(new_top), tab_width, &eb3);
        rows_needed += guiWrapLineRows(shown, font, text_area_w_logical);
    }
    doc.scroll_top = new_top;
}

/// Keep the caret visible with word wrap off: vertically by whole lines,
/// horizontally inside the TEXT area (the gutter covers the pane's left
/// part) by the caret's measured x on the drawn line. scroll_left counts
/// 'M' cells as the renderer draws it; byte columns drift from those over
/// tabs and multi-byte characters.
fn guiEnsureCursorVisibleNoWrap(doc: *Document, font: dvui.Font, text_area_w_logical: f32, visible_lines: usize, tab_width: usize) void {
    const pos = doc.cursorPos();
    if (pos.line < doc.scroll_top) {
        doc.scroll_top = pos.line;
    } else if (visible_lines > 0 and pos.line >= doc.scroll_top + visible_lines) {
        doc.scroll_top = pos.line - visible_lines + 1;
    }

    const cell_w = font.textSize("M").w;
    if (cell_w <= 0) return;
    const orig = doc.buffer.lineContent(pos.line);
    var eb: [16384]u8 = undefined;
    const shown = displayLine(orig, tab_width, &eb);
    const caret_x = font.textSize(shown[0..displayCol(orig, shown, pos.col, tab_width)]).w;
    const caret_cell: usize = @intFromFloat(@floor(caret_x / cell_w));
    const visible_cells: usize = @max(1, @as(usize, @intFromFloat(@floor(@max(0, text_area_w_logical) / cell_w))));
    if (caret_cell < doc.scroll_left) {
        doc.scroll_left = caret_cell;
    } else if (caret_cell >= doc.scroll_left + visible_cells) {
        doc.scroll_left = caret_cell - visible_cells + 1;
    }
}

// ===========================================================================
// Tab expansion helpers
// ===========================================================================

/// Expand tab characters to spaces for display.  Returns input unchanged if
/// there are no tabs (zero-copy fast path). A line that doesn't fit `buf`
/// is cut at a character boundary: a cut inside a UTF-8 sequence made the
/// line undrawable.
fn expandTabs(input: []const u8, tab_width: usize, buf: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '\t') == null) return input;
    const tw = if (tab_width == 0) 4 else tab_width;
    var out: usize = 0;
    for (input) |ch| {
        if (ch == '\t') {
            const spaces = tw - (out % tw);
            for (0..spaces) |_| {
                if (out >= buf.len) return dropPartialTail(buf[0..out]);
                buf[out] = ' ';
                out += 1;
            }
        } else {
            if (out >= buf.len) return dropPartialTail(buf[0..out]);
            buf[out] = ch;
            out += 1;
        }
    }
    return buf[0..out];
}

/// `text` without a trailing incomplete UTF-8 sequence (a copy cut short).
fn dropPartialTail(text: []const u8) []const u8 {
    var i = text.len;
    var seen: usize = 0;
    while (i > 0 and seen < 4) : (seen += 1) {
        i -= 1;
        if (text[i] & 0xC0 == 0x80) continue; // continuation: find its lead
        const need = std.unicode.utf8ByteSequenceLength(text[i]) catch return text;
        return if (i + need > text.len) text[0..i] else text;
    }
    return text;
}

/// A buffer line as the editor pane draws and measures it: tabs expanded
/// (expandTabs) and every byte that is not valid UTF-8 shown as '?' — one
/// byte for one byte, so all column math still lines up. dvui decodes text
/// with `catch unreachable`: nothing invalid may reach it.
fn displayLine(orig: []const u8, tab_width: usize, buf: []u8) []const u8 {
    const line = expandTabs(orig, tab_width, buf);
    if (std.unicode.utf8ValidateSlice(line)) return line;
    const n = @min(line.len, buf.len);
    if (line.ptr != buf.ptr) @memcpy(buf[0..n], line[0..n]);
    sanitizeUtf8(buf[0..n]);
    return buf[0..n];
}

/// Byte column `col` of buffer line `orig` as a column of its drawn text
/// `shown` (displayLine): tabs expanded, clamped to the drawn text and
/// floored to a character boundary, so it can slice text for dvui.
fn displayCol(orig: []const u8, shown: []const u8, col: usize, tab_width: usize) usize {
    return text_input.floor(shown, bufColToExpCol(orig, col, tab_width));
}

/// Replace, in place, every byte that doesn't belong to a valid UTF-8
/// sequence with '?'.
fn sanitizeUtf8(bytes: []u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n: usize = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (n == 0 or i + n > bytes.len or !decodes(bytes[i..][0..n])) {
            bytes[i] = '?';
            i += 1;
            continue;
        }
        i += n;
    }
}

/// Whether `seq` (one lead byte's worth) decodes as dvui will decode it.
fn decodes(seq: []const u8) bool {
    _ = std.unicode.utf8Decode(seq) catch return false;
    return true;
}

/// Convert a byte column in the original (tab-containing) text to the
/// corresponding column in tab-expanded text.
fn bufColToExpCol(orig: []const u8, buf_col: usize, tab_width: usize) usize {
    const tw = if (tab_width == 0) 4 else tab_width;
    var exp_col: usize = 0;
    const end = @min(buf_col, orig.len);
    for (orig[0..end]) |ch| {
        if (ch == '\t') {
            exp_col += tw - (exp_col % tw);
        } else {
            exp_col += 1;
        }
    }
    return exp_col;
}

/// Convert a column in tab-expanded text back to a byte column in the original.
fn expColToBufCol(orig: []const u8, exp_col: usize, tab_width: usize) usize {
    const tw = if (tab_width == 0) 4 else tab_width;
    var dcol: usize = 0;
    for (orig, 0..) |ch, i| {
        if (dcol >= exp_col) return i;
        if (ch == '\t') {
            dcol += tw - (dcol % tw);
        } else {
            dcol += 1;
        }
    }
    return orig.len;
}

/// Calculate number of digits needed for line numbers.
fn guiLineNumberDigits(total_lines: usize, min_digits: usize) usize {
    var digits: usize = 1;
    var n = total_lines;
    while (n >= 10) {
        n /= 10;
        digits += 1;
    }
    return @max(digits, min_digits);
}

// ===========================================================================
// Modal key/text handlers
// ===========================================================================

/// Route a key press to the appropriate modal handler.
fn handleModalKey(editor: *Editor, key: dvui.Event.Key) void {
    switch (editor.mode) {
        .goto_line => handleGotoLineKey(editor, key),
        .find_replace => handleFindReplaceKeyGui(editor, key),
        .command_palette => handlePaletteKeyGui(editor, key),
        .picker => handlePickerKeyGui(editor, key),
        .file_finder => handleFinderKeyGui(editor, key),
        .confirm_quit => handleConfirmQuitKeyGui(editor, key),
        .confirm_close => handleConfirmCloseKeyGui(editor, key),
        .confirm_overwrite => handleConfirmOverwriteKeyGui(editor, key),
        .encoding_picker, .confirm_reopen, .confirm_encoding => handleEncodingKeyGui(editor, key),
        .recent_projects => handleRecentProjectsKeyGui(editor, key),
        .recovery_picker => handleRecoveryKeyGui(editor, key),
        .lsp_panel, .symbol_rename, .workspace_preview => handleLspKeyGui(editor, key),
        .tool_panel, .task_save_prompt, .git_stage_prompt => handleToolKeyGui(editor, key),
        .settings => {}, // DVUI dialog handles its own input (settingsDialog)
        .snippet_form => {}, // DVUI dialog handles its own input (snippetFormDialog)
        .snippet_delete_confirm => handleSnippetDeleteKeyGui(editor, key),
        .file_open, .folder_open, .save_as => {}, // handled by native dialogs in GUI
        .filetree_prompt => handleFiletreePromptKeyGui(editor, key),
        .normal => {},
    }
}

/// Route text input to the appropriate modal handler.
fn handleModalText(editor: *Editor, txt: []const u8) void {
    switch (editor.mode) {
        .goto_line => {
            for (txt) |ch| {
                if (ch >= '0' and ch <= '9') {
                    if (editor.goto_buf_len < editor.goto_buf.len) {
                        editor.goto_buf[editor.goto_buf_len] = ch;
                        editor.goto_buf_len += 1;
                    }
                }
            }
        },
        .filetree_prompt => {
            if (editor.filetree_prompt_kind != .delete_confirm) {
                text_input.append(&editor.open_buf, &editor.open_buf_len, txt);
            }
        },
        .find_replace => {
            editor.status_message = "";
            if (editor.replace_field_active) {
                text_input.append(&editor.replace_buf, &editor.replace_buf_len, txt);
            } else {
                text_input.append(&editor.find_buf, &editor.find_buf_len, txt);
                editor.findIncremental();
            }
        },
        .command_palette => {
            text_input.append(&editor.palette_buf, &editor.palette_buf_len, txt);
            editor.palette_selected = 0;
        },
        .picker => editor.pickerTyped(txt),
        .file_finder => {
            text_input.append(&editor.finder_buf, &editor.finder_buf_len, txt);
            editor.finderRefresh();
        },
        else => {},
    }
}

fn handleGotoLineKey(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .escape => editor.setMode(.normal),
        .enter => {
            if (editor.goto_buf_len > 0) {
                const num_str = editor.goto_buf[0..editor.goto_buf_len];
                const line_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
                if (line_num > 0) {
                    editor.jumpToLine(line_num);
                }
            }
            editor.setMode(.normal);
        },
        .backspace => {
            if (editor.goto_buf_len > 0) editor.goto_buf_len -= 1;
        },
        else => {},
    }
}

fn handleFindReplaceKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (key.mod.control() and (key.code == .enter or key.code == .a)) {
        editor.replaceAll();
        return;
    }
    switch (key.code) {
        .escape => {
            editor.setMode(.normal);
            editor.status_message = "";
        },
        .tab => {
            editor.replace_field_active = !editor.replace_field_active;
        },
        .enter => {
            if (!editor.replace_field_active) {
                if (editor.find_buf_len > 0) editor.findNext();
            } else {
                editor.replaceOne();
            }
        },
        .backspace => {
            if (editor.replace_field_active) {
                if (editor.replace_buf_len > 0) text_input.backspace(&editor.replace_buf, &editor.replace_buf_len);
            } else {
                if (editor.find_buf_len > 0) {
                    text_input.backspace(&editor.find_buf, &editor.find_buf_len);
                    editor.findIncremental();
                }
            }
        },
        else => {
            // Ctrl+A in find_replace = replace all
            if (key.mod.control() and key.code == .a) {
                editor.replaceAll();
            }
        },
    }
}

/// Fuzzy File Finder mode (quick_open); typed characters arrive via
/// handleModalText.
fn handleFinderKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .escape => editor.finderCancel(),
        .enter => editor.finderCommit(),
        .down, .tab => editor.finderMove(true),
        .up => editor.finderMove(false),
        .page_down => {
            // Keyboard parity with the wheel: scroll the preview behind
            // the panel (pin so ensureCursorVisible doesn't yank it back).
            win_ui.scroll_pinned = true;
            editor.finderScrollPage(true);
        },
        .page_up => {
            win_ui.scroll_pinned = true;
            editor.finderScrollPage(false);
        },
        .backspace => {
            if (editor.finder_buf_len > 0) {
                text_input.backspace(&editor.finder_buf, &editor.finder_buf_len);
                editor.finderRefresh();
            }
        },
        else => {},
    }
}

fn handlePaletteKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .escape => {
            editor.setMode(.normal);
            editor.palette_selected = 0;
        },
        .enter => {
            const name = editor.paletteSelectedName();
            editor.setMode(.normal);
            editor.palette_selected = 0;
            // Inside the focused pane EVERY command waits until the panes
            // finished rendering: any of them — a Lua one through zide.exec
            // — can split or close panes. Theme commands bump
            // editor.theme_revision themselves.
            if (name) |n| {
                if (rendering_panes) {
                    deferRun(editor, .command, n);
                } else {
                    _ = editor.execCommand(n, null);
                }
            }
        },
        .tab => editor.paletteComplete(),
        .down => {
            editor.palette_selected += 1;
        },
        .up => {
            editor.palette_selected -|= 1;
        },
        .backspace => {
            if (editor.palette_buf_len > 0) {
                text_input.backspace(&editor.palette_buf, &editor.palette_buf_len);
                editor.palette_selected = 0;
            }
        },
        else => {},
    }
}

/// Keys in picker mode (printable input arrives via handleModalText).
fn handlePickerKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .escape => editor.pickerCancel(),
        .enter => editor.pickerConfirm(),
        .tab, .down => editor.picker.move(1),
        .up => editor.picker.move(-1),
        .page_down => editor.picker.move(10),
        .page_up => editor.picker.move(-10),
        .backspace => editor.pickerBackspace(),
        else => {},
    }
}

/// Keys for the file-tree prompt (create / rename / delete confirm).
/// Printable input arrives via handleModalText; this handles the rest.
fn handleFiletreePromptKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (editor.filetree_prompt_kind == .delete_confirm) {
        // Deleting is recursive and permanent: only a fresh, unmodified
        // `y` (not a held key's repeat, not Enter typed for something
        // else) confirms; any other key cancels. A chord (Ctrl+Y, ...) or
        // a modifier on its own does neither.
        if (hasCommandMod(key.mod) or isModifierKey(key.code)) return;
        if (key.code == .y and key.action == .down and !key.mod.shift()) {
            editor.applyFiletreePrompt();
        } else {
            editor.cancelFiletreePrompt();
        }
        return;
    }
    switch (key.code) {
        .escape => editor.cancelFiletreePrompt(),
        .enter => editor.applyFiletreePrompt(),
        .backspace => {
            if (editor.open_buf_len > 0) text_input.backspace(&editor.open_buf, &editor.open_buf_len);
        },
        else => {},
    }
}

/// "Delete snippet … from my-snippets.lua?" (snippetDeleteDialog draws it):
/// the tree's delete rule, as the TUI's handleSnippetDeleteKey — only a
/// fresh, plain `y` (Shift+Y too) deletes; a chord (Ctrl+Y, ...), a
/// modifier on its own or a held key's repeat (the Delete that asked,
/// still down) answers nothing; any other key cancels, n, Enter and
/// Escape among them.
fn handleSnippetDeleteKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (hasCommandMod(key.mod) or isModifierKey(key.code) or key.action != .down) return;
    if (key.code == .y) editor.applySnippetDelete() else editor.cancelSnippetDelete();
    // The dialog goes with the question: the base window takes the
    // keyboard back now rather than a frame later. (Called from the pane
    // or the window-level prompt: the current subwindow is the base.)
    dvui.focusSubwindow(null, null);
}

/// Confirm Overwrite mode (disk changed under a save).
fn handleConfirmOverwriteKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (hasCommandMod(key.mod)) return; // only plain letters answer (Ctrl+R is not "reload")
    switch (key.code) {
        .o => editor.resolveOverwrite(.overwrite),
        .r => editor.resolveOverwrite(.reload),
        .c, .escape => editor.resolveOverwrite(.cancel),
        else => {},
    }
}

/// Close-tab prompt ([S]ave [D]iscard [C]ancel for one document). Save on
/// an untitled document runs the native Save As dialog and closes the tab
/// only if that wrote the file.
fn handleConfirmCloseKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (hasCommandMod(key.mod)) return; // only plain letters answer
    switch (key.code) {
        .s => {
            if (editor.resolveCloseDoc(.save) != .needs_path) return;
            const id = editor.activeDoc().id;
            editor.startSaveAs(id, null);
            saveAs(editor);
            if (editor.docIndexForId(id)) |idx| {
                if (!editor.documents.items[idx].dirty and editor.documents.items[idx].file_path != null) _ = editor.closeDocAt(idx);
            }
        },
        .d => {
            _ = editor.resolveCloseDoc(.discard);
        },
        .c, .escape => {
            _ = editor.resolveCloseDoc(.cancel);
        },
        else => {},
    }
}

fn handleConfirmQuitKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (hasCommandMod(key.mod)) return; // Ctrl+D is not "discard"
    switch (key.code) {
        .s => editor.saveAllAndQuit(),
        .d => editor.discardAndQuit(),
        .c, .escape => editor.setMode(.normal),
        else => {},
    }
}

/// Settings definitions: name, type, description.
/// min/max only apply to .number settings and must stay in sync with the
/// validation ranges in applySettingNumber (which the TUI panel relies on).
const SettingDef = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { boolean, number, enum_choice, text },
    desc: []const u8,
    choices: []const []const u8 = &.{},
    min: i64 = 0,
    max: i64 = 0,
};

const settings_defs = [_]SettingDef{
    .{ .key = "format_on_save", .label = "Format on Save", .kind = .boolean, .desc = "Use language-server formatting before saving; failures abort that save" },
    .{ .key = "recovery", .label = "Recovery", .kind = .boolean, .desc = "Keep recovery snapshots of unsaved buffers" },
    .{ .key = "editorconfig", .label = "EditorConfig", .kind = .boolean, .desc = "Use project indentation, line-ending and whitespace rules" },
    .{ .key = "tab_width", .label = "Tab Width", .kind = .number, .desc = "Number of spaces per tab (1-16)", .min = 1, .max = 16 },
    .{ .key = "use_tabs", .label = "Use Tabs", .kind = .boolean, .desc = "Insert tabs instead of spaces" },
    .{ .key = "word_wrap", .label = "Word Wrap", .kind = .boolean, .desc = "Soft-wrap long lines in display" },
    .{ .key = "auto_close_brackets", .label = "Auto Close Brackets", .kind = .boolean, .desc = "Auto-close brackets and quotes" },
    .{ .key = "completion_auto", .label = "Auto Completion Popup", .kind = .boolean, .desc = "Open completions while typing (off = Ctrl+Space only)" },
    .{ .key = "signature_help_auto", .label = "Auto Signature Help", .kind = .boolean, .desc = "Show the call signature after ( and , (off = Ctrl+Shift+Space only)" },
    .{ .key = "review_stage_on_approve", .label = "Review: Approve Stages", .kind = .boolean, .desc = "Approving a changed file in the Review view also stages it (git add)" },
    .{ .key = "auto_save", .label = "Auto Save", .kind = .boolean, .desc = "Auto-save dirty documents periodically" },
    .{ .key = "auto_save_interval_ms", .label = "Auto Save Interval (ms)", .kind = .number, .desc = "Delay before auto-save (500-300000)", .min = 500, .max = 300000 },
    .{ .key = "status_message_seconds", .label = "Message Highlight (s)", .kind = .number, .desc = "Seconds a new status-bar message stays highlighted, 0 = off (0-30)", .min = 0, .max = 30 },
    .{ .key = "find_match_case", .label = "Find: Match Case", .kind = .boolean, .desc = "How the find bar's Aa button starts out: upper and lower case must match" },
    .{ .key = "find_whole_word", .label = "Find: Whole Word", .kind = .boolean, .desc = "How the find bar's W button starts out: match whole words only" },
    .{ .key = "find_highlight_all", .label = "Find: Highlight All Matches", .kind = .boolean, .desc = "The find bar's All button: tint every match and mark them on the scroll bar" },
    .{ .key = "gutter_min_digits", .label = "Gutter Min Digits", .kind = .number, .desc = "Minimum width of line number gutter (1-10)", .min = 1, .max = 10 },
    .{ .key = "completion_min_chars", .label = "Completion Min Chars", .kind = .number, .desc = "Identifier characters typed before the popup opens by itself (1-8)", .min = 1, .max = 8 },
    .{ .key = "page_size", .label = "Page Size", .kind = .number, .desc = "Lines to scroll on Page Up/Down (5-200)", .min = 5, .max = 200 },
    .{ .key = "click_clears_cursors", .label = "Click Clears Cursors", .kind = .boolean, .desc = "Left-click clears secondary cursors" },
    .{ .key = "session_persistence", .label = "Session Persistence", .kind = .boolean, .desc = "Reopen last session's files when launched bare" },
    .{ .key = "secondary_window_chrome", .label = "Extra Window Chrome (GUI)", .kind = .boolean, .desc = "Menu and status bars in extra windows (file tree and search stay in the main window)" },
    .{ .key = "lsp_enabled", .label = "LSP Support", .kind = .boolean, .desc = "Run language servers for open files (off stops them immediately)" },
    .{ .key = "syntax_highlighting", .label = "Syntax Highlighting", .kind = .boolean, .desc = "Color code by language — off = plain text editor" },
    .{ .key = "filetree_git_colors", .label = "File Tree Git Colors", .kind = .boolean, .desc = "Color file tree rows by git status" },
    .{ .key = "filetree_auto_reveal", .label = "File Tree Auto Reveal", .kind = .boolean, .desc = "Select the active file in the tree when switching tabs" },
    .{ .key = "max_undo_history", .label = "Undo History Limit", .kind = .number, .desc = "Max undo operations per document, 0 = unlimited (0-100000)", .min = 0, .max = 100000 },
    .{ .key = "theme", .label = "Theme", .kind = .enum_choice, .desc = "Editor color theme", .choices = &.{ "dark", "light", "high_contrast" } },
    .{ .key = "filetree_visible", .label = "File Tree Visible", .kind = .boolean, .desc = "Show the file tree side panel (Ctrl+B)" },
    .{ .key = "filetree_side", .label = "File Tree Side", .kind = .enum_choice, .desc = "Dock the file tree on the left or right", .choices = &.{ "left", "right" } },
    .{ .key = "filetree_width", .label = "File Tree Width (GUI)", .kind = .number, .desc = "Panel width in pixels (120-600)", .min = 120, .max = 600 },
    .{ .key = "tui_filetree_width", .label = "File Tree Width (TUI)", .kind = .number, .desc = "Panel width in columns (16-80)", .min = 16, .max = 80 },
    .{ .key = "tui_filetree_icons", .label = "File Tree Icons (TUI)", .kind = .boolean, .desc = "Nerdfont file icons in the TUI tree (terminal font must be a Nerd Font)" },
    .{ .key = "filetree_font_size", .label = "File Tree Font Size (GUI)", .kind = .number, .desc = "Row text size in points — rows and icons scale together; 0 = theme default (0-32)", .min = 0, .max = 32 },
    .{ .key = "filetree_icon_scale", .label = "File Tree Icon Scale (GUI)", .kind = .number, .desc = "Icon size as a percentage of the row font (50-200)", .min = 50, .max = 200 },
    .{ .key = "snippets_visible", .label = "Snippets Panel Visible", .kind = .boolean, .desc = "Show the Snippets side panel (Ctrl+Alt+B)" },
    .{ .key = "snippets_side", .label = "Snippets Panel Side", .kind = .enum_choice, .desc = "Dock the Snippets panel left or right; auto = opposite the file tree", .choices = &.{ "auto", "left", "right" } },
    .{ .key = "snippets_width", .label = "Snippets Panel Width (GUI)", .kind = .number, .desc = "Panel width in pixels (120-600)", .min = 120, .max = 600 },
    .{ .key = "tui_snippets_width", .label = "Snippets Panel Width (TUI)", .kind = .number, .desc = "Panel width in columns (16-80)", .min = 16, .max = 80 },
    .{ .key = "snippets_double_click", .label = "Snippets Insert on Double-Click", .kind = .boolean, .desc = "A click only selects a snippet and keeps its preview; a double-click (or Enter) inserts it" },
    .{ .key = "terminal_panel_side", .label = "Terminal Panel Side", .kind = .enum_choice, .desc = "Dock the terminal panel (Ctrl+Shift+`) at the left, right or bottom", .choices = &.{ "bottom", "left", "right" } },
    .{ .key = "terminal_panel_width", .label = "Terminal Panel Width (GUI)", .kind = .number, .desc = "Width in pixels when docked at a side (160-1600)", .min = 160, .max = 1600 },
    .{ .key = "terminal_panel_height", .label = "Terminal Panel Height (GUI)", .kind = .number, .desc = "Height in pixels when docked at the bottom (80-1200)", .min = 80, .max = 1200 },
    .{ .key = "tui_terminal_panel_width", .label = "Terminal Panel Width (TUI)", .kind = .number, .desc = "Width in columns when docked at a side (20-200)", .min = 20, .max = 200 },
    .{ .key = "tui_terminal_panel_height", .label = "Terminal Panel Height (TUI)", .kind = .number, .desc = "Height in rows when docked at the bottom (3-60)", .min = 3, .max = 60 },
    .{ .key = "filetree_root", .label = "File Tree Root", .kind = .text, .desc = "Starting directory — empty = current dir (Enter applies)" },
};

/// Backing buffer for the dialog's single .text setting (filetree_root).
/// TextEntryWidget .buffer mode re-derives its length from the first NUL
/// every frame, so pre-filling = copy + zero-fill on dialog open.
var settings_text_buf: [512]u8 = undefined;
var settings_text_prefill: bool = true;

/// Modal settings dialog built from native DVUI widgets (floating window
/// with header, checkboxes, numeric entries, and a theme dropdown). Shown
/// while editor.mode == .settings; the header X button or Escape closes it.
/// Changes apply live and persist to init.lua immediately.
///
/// The TUI keeps its own custom-rendered panel; both share settings_defs
/// and the get/apply helpers below.
fn settingsDialog(editor: *Editor) void {
    if (!build_options.has_gui) return;

    var open = true;
    var float = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{
        .min_size_content = .{ .w = 480 },
    });
    defer {
        float.deinit();
        if (!open) {
            editor.setMode(.normal);
            // Return keyboard focus to the base window so the editor pane
            // regains key handling without requiring a click.
            dvui.focusSubwindow(null, null);
        }
    }

    float.dragAreaSet(dvui.windowHeader("Settings", "", &open));

    // The settings list outgrew short windows — scroll inside a capped
    // viewport instead of clipping at the screen edge.
    const view_h = @min(560.0, @max(300.0, dvui.windowRect().h * 0.8));
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 480, .h = view_h },
    });
    defer scroll.deinit();

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = dvui.Rect.all(8),
    });
    defer vbox.deinit();

    const desc_color = toDvui(editor.theme.overlay_hint);

    const renderer_settings = @import("../core/renderer_settings.zig");
    dvui.labelNoFmt(@src(), "Renderer (applies after restarting ZIDE)", .{}, .{});
    dvui.labelNoFmt(@src(), if (editor.renderer_is_software) "Current: Software" else "Current: Hardware accelerated", .{}, .{ .color_text = desc_color });
    if (@import("builtin").os.tag == .linux and !build_options.has_gpu)
        dvui.labelNoFmt(@src(), "Software uses CPU drawing; native Wayland still needs a graphics driver for presentation.", .{}, .{ .color_text = desc_color });
    if (build_options.has_gpu) {
        dvui.labelNoFmt(@src(), "Experimental GPU build: software mode requires the normal build.", .{}, .{ .color_text = desc_color });
    } else {
        var renderer_choice: usize = @intFromEnum(editor.renderer_preference);
        if (dvui.dropdown(@src(), &renderer_settings.labels, .{ .choice = &renderer_choice }, .{}, .{ .min_size_content = .{ .w = 240 } })) {
            const mode: renderer_settings.Mode = @enumFromInt(renderer_choice);
            const path = renderer_settings.configPath(editor.allocator) catch null;
            if (path) |p| {
                defer editor.allocator.free(p);
                if (renderer_settings.save(editor.allocator, editor.io, p, mode)) |_| {
                    editor.renderer_preference = mode;
                    editor.status_message = "Renderer preference saved; restart ZIDE to apply";
                } else |_| editor.setStatus(.err, "Could not save renderer preference");
            } else editor.setStatus(.err, "Could not find renderer configuration path");
        }
        if (editor.renderer_preference != editor.renderer_active) {
            dvui.labelNoFmt(@src(), "Restart required. Existing and new windows keep the current renderer.", .{}, .{ .color_text = desc_color });
        }
    }

    for (settings_defs, 0..) |def, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = i,
            .padding = .{ .x = 0, .y = 3, .w = 0, .h = 3 },
        });
        defer row.deinit();

        // Left: setting name with description underneath
        {
            var labels = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
            });
            defer labels.deinit();
            dvui.labelNoFmt(@src(), def.label, .{}, .{
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
            });
            dvui.labelNoFmt(@src(), def.desc, .{}, .{
                .color_text = desc_color,
                .padding = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            });
        }

        // Right: the control for this setting's type
        switch (def.kind) {
            .boolean => {
                var val = getSettingBool(editor, def.key);
                if (dvui.checkbox(@src(), &val, null, .{
                    .id_extra = i,
                    .gravity_x = 1.0,
                    .gravity_y = 0.5,
                })) {
                    applySettingBool(editor, def.key, val);
                    const val_str: []const u8 = if (val) "true" else "false";
                    lua_settings.writeSettingToFile(def.key, val_str) catch {};
                }
            },
            .number => {
                var val = getSettingNumber(editor, def.key);
                const res = dvui.textEntryNumber(@src(), i64, .{
                    .min = def.min,
                    .max = def.max,
                    .value = &val,
                }, .{
                    .id_extra = i,
                    .gravity_x = 1.0,
                    .gravity_y = 0.5,
                    // 8 M-widths wide, full text line tall — overriding
                    // min_size_content replaces the widget default, so the
                    // height must be supplied too or the box collapses.
                    .min_size_content = dvui.Font.theme(.body).sizeM(8, 1),
                });
                if (res.changed) {
                    applySettingNumber(editor, def.key, val);
                    var num_buf: [32]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch "";
                    if (num_str.len > 0) {
                        lua_settings.writeSettingToFile(def.key, num_str) catch {};
                    }
                }
            },
            .enum_choice => {
                var choice: usize = 0;
                const current = getSettingEnum(editor, def.key);
                for (def.choices, 0..) |c, ci| {
                    if (std.mem.eql(u8, c, current)) choice = ci;
                }
                if (dvui.dropdown(@src(), def.choices, .{ .choice = &choice }, .{}, .{
                    .id_extra = i,
                    .gravity_x = 1.0,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 130 },
                })) {
                    if (std.mem.eql(u8, def.key, "theme")) {
                        // switchTheme persists to init.lua itself
                        switchTheme(editor, def.choices[choice]);
                    } else if (std.mem.eql(u8, def.key, "filetree_side")) {
                        editor.filetree_side = if (std.mem.eql(u8, def.choices[choice], "right")) .right else .left;
                        lua_settings.writeStringSettingToFile(def.key, def.choices[choice]) catch {};
                    } else if (std.mem.eql(u8, def.key, "snippets_side")) {
                        const pick = def.choices[choice];
                        editor.snippets_side = if (std.mem.eql(u8, pick, "auto")) null else if (std.mem.eql(u8, pick, "right")) Editor.FiletreeSide.right else Editor.FiletreeSide.left;
                        lua_settings.writeStringSettingToFile(def.key, pick) catch {};
                    } else if (std.mem.eql(u8, def.key, "terminal_panel_side")) {
                        // movePanel persists to init.lua itself
                        if (std.meta.stringToEnum(Editor.DockEdge, def.choices[choice])) |edge| editor.movePanel(.terminal, edge);
                    }
                }
            },
            .text => {
                if (settings_text_prefill) {
                    settings_text_prefill = false;
                    const cur = getSettingText(editor, def.key);
                    const n = @min(cur.len, settings_text_buf.len - 1);
                    @memcpy(settings_text_buf[0..n], cur[0..n]);
                    @memset(settings_text_buf[n..], 0);
                }
                const te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &settings_text_buf } }, .{
                    .id_extra = i,
                    .gravity_x = 1.0,
                    .gravity_y = 0.5,
                    .min_size_content = dvui.Font.theme(.body).sizeM(18, 1),
                });
                const entered = te.enter_pressed;
                const entry_text = te.textGet();
                te.deinit();
                if (entered) {
                    applySettingText(editor, def.key, entry_text);
                }
            },
        }
    }
}

fn getSettingText(editor: *const Editor, key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "filetree_root")) return editor.filetree_root orelse "";
    return "";
}

fn applySettingText(editor: *Editor, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "filetree_root")) {
        if (editor.setFiletreeRoot(val)) {
            // Written as a quoted Lua string literal: a Windows path spliced
            // in raw ("C:\Users\...", where \U is an invalid escape) kept
            // init.lua from loading at all on the next launch.
            lua_settings.writeStringSettingToFile(key, std.mem.trim(u8, val, " \t")) catch |err| {
                guiNotify(editor, "File tree root not saved to init.lua: {s}", .{@errorName(err)});
            };
        }
    }
}

fn getSettingBool(editor: *const Editor, key: []const u8) bool {
    if (std.mem.eql(u8, key, "format_on_save")) return editor.lsp_tools.format_on_save;
    if (std.mem.eql(u8, key, "recovery")) return editor.recovery_enabled;
    if (std.mem.eql(u8, key, "editorconfig")) return editor.editorconfig_enabled;
    if (std.mem.eql(u8, key, "use_tabs")) return editor.use_tabs;
    if (std.mem.eql(u8, key, "word_wrap")) return editor.word_wrap;
    if (std.mem.eql(u8, key, "auto_close_brackets")) return editor.auto_close_brackets;
    if (std.mem.eql(u8, key, "completion_auto")) return editor.completion_auto;
    if (std.mem.eql(u8, key, "signature_help_auto")) return editor.signature_help_auto;
    if (std.mem.eql(u8, key, "review_stage_on_approve")) return editor.review.stage_on_approve;
    if (std.mem.eql(u8, key, "auto_save")) return editor.auto_save;
    if (std.mem.eql(u8, key, "click_clears_cursors")) return editor.click_clears_cursors;
    if (std.mem.eql(u8, key, "session_persistence")) return editor.session_persistence;
    if (std.mem.eql(u8, key, "secondary_window_chrome")) return editor.secondary_window_chrome;
    if (std.mem.eql(u8, key, "lsp_enabled")) return editor.lsp_enabled;
    if (std.mem.eql(u8, key, "syntax_highlighting")) return editor.syntax_highlighting;
    if (std.mem.eql(u8, key, "filetree_git_colors")) return editor.filetree_git_colors;
    if (std.mem.eql(u8, key, "filetree_auto_reveal")) return editor.filetree_auto_reveal;
    if (std.mem.eql(u8, key, "filetree_visible")) return editor.filetree_visible;
    if (std.mem.eql(u8, key, "tui_filetree_icons")) return editor.tui_filetree_icons;
    if (std.mem.eql(u8, key, "snippets_visible")) return editor.snippets_visible;
    if (std.mem.eql(u8, key, "snippets_double_click")) return editor.snippets_double_click;
    if (std.mem.eql(u8, key, "find_match_case")) return editor.find_bar.options.match_case;
    if (std.mem.eql(u8, key, "find_whole_word")) return editor.find_bar.options.whole_word;
    if (std.mem.eql(u8, key, "find_highlight_all")) return editor.find_bar.highlight_all;
    return false;
}

fn applySettingBool(editor: *Editor, key: []const u8, val: bool) void {
    if (std.mem.eql(u8, key, "format_on_save")) editor.lsp_tools.format_on_save = val;
    if (std.mem.eql(u8, key, "recovery")) editor.recovery_enabled = val;
    if (std.mem.eql(u8, key, "editorconfig")) editor.editorconfig_enabled = val;
    if (std.mem.eql(u8, key, "use_tabs")) editor.use_tabs = val;
    if (std.mem.eql(u8, key, "word_wrap")) editor.word_wrap = val;
    if (std.mem.eql(u8, key, "auto_close_brackets")) editor.auto_close_brackets = val;
    if (std.mem.eql(u8, key, "completion_auto")) editor.completion_auto = val;
    if (std.mem.eql(u8, key, "signature_help_auto")) editor.signature_help_auto = val;
    if (std.mem.eql(u8, key, "review_stage_on_approve")) editor.review.stage_on_approve = val;
    if (std.mem.eql(u8, key, "auto_save")) editor.auto_save = val;
    if (std.mem.eql(u8, key, "click_clears_cursors")) editor.click_clears_cursors = val;
    if (std.mem.eql(u8, key, "session_persistence")) editor.session_persistence = val;
    if (std.mem.eql(u8, key, "secondary_window_chrome")) editor.secondary_window_chrome = val;
    if (std.mem.eql(u8, key, "lsp_enabled")) editor.lsp_enabled = val; // lspTick stops/starts servers next frame
    if (std.mem.eql(u8, key, "syntax_highlighting")) editor.syntax_highlighting = val;
    if (std.mem.eql(u8, key, "filetree_git_colors")) {
        editor.filetree_git_colors = val;
        if (editor.filetree) |*ft| {
            ft.git_enabled = val;
            ft.gitRefresh();
        }
    }
    if (std.mem.eql(u8, key, "filetree_auto_reveal")) editor.filetree_auto_reveal = val;
    if (std.mem.eql(u8, key, "tui_filetree_icons")) editor.tui_filetree_icons = val;
    if (std.mem.eql(u8, key, "filetree_visible")) {
        editor.filetree_visible = val;
        if (!val) editor.filetree_focused = false;
    }
    if (std.mem.eql(u8, key, "snippets_visible")) {
        editor.snippets_visible = val;
        if (!val) editor.snippets_focused = false;
    }
    if (std.mem.eql(u8, key, "snippets_double_click")) editor.snippets_double_click = val;
    if (std.mem.eql(u8, key, "find_match_case")) editor.find_bar.options.match_case = val;
    if (std.mem.eql(u8, key, "find_whole_word")) editor.find_bar.options.whole_word = val;
    if (std.mem.eql(u8, key, "find_highlight_all")) editor.find_bar.highlight_all = val;
}

fn getSettingNumber(editor: *const Editor, key: []const u8) i64 {
    if (std.mem.eql(u8, key, "tab_width")) return @intCast(editor.tab_width);
    if (std.mem.eql(u8, key, "auto_save_interval_ms")) return @intCast(editor.auto_save_interval_ms);
    if (std.mem.eql(u8, key, "status_message_seconds")) return @intCast(editor.status_message_seconds);
    if (std.mem.eql(u8, key, "gutter_min_digits")) return @intCast(editor.gutter_min_digits);
    if (std.mem.eql(u8, key, "completion_min_chars")) return @intCast(editor.completion_min_chars);
    if (std.mem.eql(u8, key, "page_size")) return @intCast(editor.page_size);
    if (std.mem.eql(u8, key, "max_undo_history")) return @intCast(editor.max_undo_history);
    if (std.mem.eql(u8, key, "filetree_width")) return @intFromFloat(editor.filetree_width);
    if (std.mem.eql(u8, key, "tui_filetree_width")) return @intCast(editor.tui_filetree_width);
    if (std.mem.eql(u8, key, "filetree_font_size")) return @intFromFloat(editor.filetree_font_size);
    if (std.mem.eql(u8, key, "filetree_icon_scale")) return @intCast(editor.filetree_icon_scale);
    if (std.mem.eql(u8, key, "snippets_width")) return @intFromFloat(editor.snippets_width);
    if (std.mem.eql(u8, key, "tui_snippets_width")) return @intCast(editor.tui_snippets_width);
    if (std.mem.eql(u8, key, "terminal_panel_width")) return @intFromFloat(editor.terminal_panel_width);
    if (std.mem.eql(u8, key, "terminal_panel_height")) return @intFromFloat(editor.terminal_panel_height);
    if (std.mem.eql(u8, key, "tui_terminal_panel_width")) return @intCast(editor.tui_terminal_panel_width);
    if (std.mem.eql(u8, key, "tui_terminal_panel_height")) return @intCast(editor.tui_terminal_panel_height);
    return 0;
}

fn applySettingNumber(editor: *Editor, key: []const u8, val: i64) void {
    if (std.mem.eql(u8, key, "tab_width")) {
        if (val >= 1 and val <= 16) editor.tab_width = @intCast(val);
    }
    if (std.mem.eql(u8, key, "auto_save_interval_ms")) {
        if (val >= 500 and val <= 300000) editor.auto_save_interval_ms = @intCast(val);
    }
    if (std.mem.eql(u8, key, "status_message_seconds")) {
        if (val >= 0 and val <= 30) editor.status_message_seconds = @intCast(val);
    }
    if (std.mem.eql(u8, key, "gutter_min_digits")) {
        if (val >= 1 and val <= 10) editor.gutter_min_digits = @intCast(val);
    }
    if (std.mem.eql(u8, key, "completion_min_chars")) {
        if (val >= 1 and val <= 8) editor.completion_min_chars = @intCast(val);
    }
    if (std.mem.eql(u8, key, "page_size")) {
        if (val >= 5 and val <= 200) editor.page_size = @intCast(val);
    }
    if (std.mem.eql(u8, key, "max_undo_history")) {
        if (val >= 0 and val <= 100000) {
            editor.max_undo_history = @intCast(val);
            for (editor.documents.items) |*doc| {
                doc.history.max_size = editor.max_undo_history;
            }
        }
    }
    if (std.mem.eql(u8, key, "filetree_width")) {
        if (val >= 120 and val <= 600) editor.filetree_width = @floatFromInt(val);
    }
    if (std.mem.eql(u8, key, "filetree_font_size")) {
        if (val >= 0 and val <= 32) editor.filetree_font_size = @floatFromInt(val);
    }
    if (std.mem.eql(u8, key, "filetree_icon_scale")) {
        if (val >= 50 and val <= 200) editor.filetree_icon_scale = @intCast(val);
    }
    if (std.mem.eql(u8, key, "tui_filetree_width")) {
        if (val >= 16 and val <= 80) editor.tui_filetree_width = @intCast(val);
    }
    if (std.mem.eql(u8, key, "snippets_width")) {
        if (val >= 120 and val <= 600) editor.snippets_width = @floatFromInt(val);
    }
    if (std.mem.eql(u8, key, "terminal_panel_width")) {
        const lim = Editor.terminal_panel_limits;
        if (val >= @as(i64, @intFromFloat(lim.min_width)) and val <= @as(i64, @intFromFloat(lim.max_width))) editor.terminal_panel_width = @floatFromInt(val);
    }
    if (std.mem.eql(u8, key, "terminal_panel_height")) {
        const lim = Editor.terminal_panel_limits;
        if (val >= @as(i64, @intFromFloat(lim.min_height)) and val <= @as(i64, @intFromFloat(lim.max_height))) editor.terminal_panel_height = @floatFromInt(val);
    }
    if (std.mem.eql(u8, key, "tui_terminal_panel_width")) {
        const lim = Editor.terminal_panel_limits;
        if (val >= lim.tui_min_width and val <= lim.tui_max_width) editor.tui_terminal_panel_width = @intCast(val);
    }
    if (std.mem.eql(u8, key, "tui_terminal_panel_height")) {
        const lim = Editor.terminal_panel_limits;
        if (val >= lim.tui_min_height and val <= lim.tui_max_height) editor.tui_terminal_panel_height = @intCast(val);
    }
    if (std.mem.eql(u8, key, "tui_snippets_width")) {
        if (val >= 16 and val <= 80) editor.tui_snippets_width = @intCast(val);
    }
}

fn getSettingEnum(editor: *const Editor, key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "theme")) return editor.theme_name;
    if (std.mem.eql(u8, key, "filetree_side")) return @tagName(editor.filetree_side);
    if (std.mem.eql(u8, key, "snippets_side")) return if (editor.snippets_side) |side| @tagName(side) else "auto";
    if (std.mem.eql(u8, key, "terminal_panel_side")) return @tagName(editor.terminal_panel_side);
    return "";
}

/// Open init.lua in the editor as a document.
fn openSettingsFile(editor: *Editor) void {
    const config_path = lua_settings.getConfigPathAlways() orelse return;

    // Ensure directory and file exist
    if (lua_settings.getConfigDir()) |dir| {
        std.Io.Dir.cwd().createDirPath(editor.io, dir) catch {};
    }
    // Create file if it doesn't exist
    if (std.Io.Dir.cwd().access(editor.io, config_path, .{})) |_| {} else |_| {
        if (std.Io.Dir.cwd().createFile(editor.io, config_path, .{})) |f| {
            f.writeStreamingAll(editor.io, "-- ZIDE settings\n-- See docs/Documentation.md for available settings\n") catch {};
            f.close(editor.io);
        } else |_| {}
    }
    _ = editor.openFile(config_path) catch {};
}

/// Switch the GUI theme (Preferences menu, Settings dialog) through the
/// `gui_theme_<name>` command: editor colors, dvui chrome in every window
/// (theme_revision → applyThemeIfStale), init.lua, and a re-run of
/// syntax-theme.lua and the syn_theme_<lang>.lua files, whose colors a
/// bare preset switch dropped (C9).
fn switchTheme(editor: *Editor, name: []const u8) void {
    var buf: [48]u8 = undefined;
    const command = std.fmt.bufPrint(&buf, "gui_theme_{s}", .{name}) catch return;
    _ = editor.execCommand(command, null);
}

/// Open the GUI theme override file in the editor. Creates a commented template if it doesn't exist.
fn openThemeFile(editor: *Editor) void {
    const dir = lua_settings.getConfigDir() orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/themes/gui-theme.lua", .{dir}) catch return;
    if (path.len >= path_buf.len) return;
    path_buf[path.len] = 0;
    const z_path: [:0]const u8 = path_buf[0..path.len :0];

    // Template is auto-created by loadThemeFiles on startup; just open it
    _ = editor.openFile(z_path) catch {};
}

/// Open the ZIDE config folder in the OS file explorer.
fn openThemeFolder(io: std.Io) void {
    const config_dir = lua_settings.getConfigDir() orelse return;

    // Build themes/ subdirectory path
    var dir_buf: [512]u8 = undefined;
    const dir_slice = std.fmt.bufPrint(&dir_buf, "{s}/themes", .{config_dir}) catch return;
    if (dir_slice.len >= dir_buf.len) return;

    // Ensure directory exists
    std.Io.Dir.cwd().createDirPath(io, dir_slice) catch {};

    const builtin = @import("builtin");
    // Windows explorer needs backslashes — the config path mixes \ and /
    if (builtin.os.tag == .windows) {
        for (dir_buf[0..dir_slice.len]) |*c| {
            if (c.* == '/') c.* = '\\';
        }
    }
    dir_buf[dir_slice.len] = 0;
    const dir_z: [:0]const u8 = dir_buf[0..dir_slice.len :0];

    const opener: [:0]const u8 = if (builtin.os.tag == .windows) "explorer" else if (builtin.os.tag == .macos) "open" else "xdg-open";

    const argv = [_][]const u8{ opener, dir_z };
    // Under the process-wide spawn lock: Windows children inherit every
    // inheritable pipe end that exists while one is created.
    _ = jobs.spawnLocked(io, .{ .argv = &argv }) catch return;
}

// ===========================================================================
// Snippet form: "Save as snippet" (Ctrl+Alt+S)
// ===========================================================================

/// The snippet form's Name entry has yet to take the keyboard: set while
/// the form is closed and on the frame its dialog first shows in a window,
/// cleared once dvui reports the entry focused.
var snippet_form_focus_pending: bool = true;
/// Hash of the error message the dialog showed last frame: when one
/// appears, changes or goes, the dialog re-fits itself around it.
var snippet_form_error_hash: ?u64 = null;

/// The "Save as snippet" dialog (mode .snippet_form; its title already
/// covers Edit and Copy): a modal floating window whose text entries edit
/// the form's buffers in place. Enter in a one-line field, or Save,
/// submits — a failure keeps it open with the reason in the warn color;
/// Escape, Cancel or the header's X leaves without saving. In Notes and
/// Body Enter types a line break. Tab / Shift+Tab move between the entries
/// (dvui's own focus order). modalDialogs draws it only in its window.
fn snippetFormDialog(editor: *Editor) void {
    if (!build_options.has_gui) return;
    const form = &editor.snippet_form;
    var open = true;
    var submit = false;
    var float = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{
        .min_size_content = .{ .w = 540 },
    });
    defer {
        float.deinit();
        if (!open) editor.cancelSnippetForm();
        if (editor.mode != .snippet_form) {
            // Saved or cancelled (the setMode hook has reset the form): the
            // next open starts in Name, and the base window takes the
            // keyboard back so the editor pane works without a click. Only
            // after deinit: inside the dialog, "the current subwindow" is
            // the dialog itself.
            snippet_form_focus_pending = true;
            snippet_form_error_hash = null;
            dvui.focusSubwindow(null, null);
        }
    }
    const title: []const u8 = switch (form.kind) {
        .save => "Save as snippet",
        .edit => "Edit snippet",
        .copy => "Copy to my snippets",
    };
    float.dragAreaSet(dvui.windowHeader(title, "", &open));
    // Its first frame in this window (just opened, or taken over by the
    // primary when its own window closed): the caret goes to Name.
    if (dvui.firstFrame(float.data().id)) snippet_form_focus_pending = true;

    // Escape, before any entry sees it: a focused text entry swallows every
    // key it does not use, so handleGuiKeyEvents' leftover-Escape catch
    // would never get it while the caret is in a field.
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .key) continue;
        if (e.evt.key.action == .down and e.evt.key.code == .escape) {
            e.handle(@src(), float.data());
            open = false;
        }
    }

    const font = dvui.Font.theme(.body);
    const dim = toDvui(editor.theme.overlay_hint);
    // The field names' column, as wide as the widest of them.
    const label_w = font.textSize("Language").w;
    {
        // A short window scrolls the fields; the buttons stay in view.
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .max_size_content = .height(@max(160, dvui.windowRect().h - 110)),
        });
        defer scroll.deinit();
        var fields = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 6, .w = 8, .h = 2 },
        });
        defer fields.deinit();

        const name_id = snippetFormLine(form, .name, "Name", "snippet_form_name", null, "required — the name the panel shows", label_w, dim, &submit);
        if (snippet_form_focus_pending) {
            // dvui focuses a dialog's subwindow on its first frame only; a
            // reopen right after a close is not one, so focus it here too.
            // Retried every frame until the entry really holds the focus.
            dvui.focusSubwindow(float.data().id, null);
            dvui.focusWidget(name_id, null, null);
            if (dvui.focusedWidgetId() == name_id) snippet_form_focus_pending = false;
        }
        _ = snippetFormLine(form, .folder, "Folder", "snippet_form_folder", "the panel group — empty means Mine", null, label_w, dim, &submit);
        _ = snippetFormLine(form, .trigger, "Trigger", "snippet_form_trigger", "optional — type it and press Tab to insert", null, label_w, dim, &submit);
        _ = snippetFormLine(form, .language, "Language", "snippet_form_language", "a language name, or * for every file", null, label_w, dim, &submit);
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            const label_id = snippetFormLabel("Notes", label_w);
            const te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = &form.notes },
                .multiline = true,
                .break_lines = true,
                .scroll_horizontal = false,
                .placeholder = "optional — what it does, in plain words",
            }, .{
                .expand = .horizontal,
                .min_size_content = font.sizeM(1, 3),
                .tag = "snippet_form_notes",
                .label = .{ .by_id = label_id },
            });
            form.notes_len = te.textGet().len;
            te.deinit();
        }
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            const label_id = snippetFormLabel("Body", label_w);
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
            defer col.deinit();
            // Code: the editor's font, no wrapping.
            const te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &form.body }, .multiline = true }, .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 1, .h = 160 },
                .font = dvui.Font.theme(.mono),
                .tag = "snippet_form_body",
                .label = .{ .by_id = label_id },
            });
            form.body_len = te.textGet().len;
            te.deinit();
            dvui.labelNoFmt(@src(), "Blanks: ${1:text} is a blank with a default,\n$0 is where the caret ends up, a leading tab is one indent.", .{}, .{ .color_text = dim });
        }
    }

    // Beside the buttons: why the last save failed, else how to save.
    const err_hash = std.hash.Wyhash.hash(0, form.error_message);
    if (snippet_form_error_hash != err_hash) {
        snippet_form_error_hash = err_hash;
        float.autoSize();
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 8 },
        });
        defer row.deinit();
        if (form.error_message.len > 0) {
            var tl = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .background = false,
                // It wraps in what the buttons leave: its unbroken width
                // must never widen the dialog.
                .max_size_content = .width(120),
                .tag = "snippet_form_error",
            });
            tl.addText(form.error_message, .{ .color_text = toDvui(editor.theme.overlay_warn) });
            tl.deinit();
        } else {
            dvui.labelNoFmt(@src(), "Enter in a one-line field saves; Esc cancels", .{}, .{
                .expand = .horizontal,
                .gravity_y = 0.5,
                .color_text = dim,
            });
        }
        if (dvui.button(@src(), "Save", .{}, .{ .gravity_y = 0.5, .tag = "snippet_form_save" })) submit = true;
        if (dvui.button(@src(), "Cancel", .{}, .{ .gravity_y = 0.5, .tag = "snippet_form_cancel" })) open = false;
    }
    // Last: every entry has copied its length back, and nothing after this
    // touches the form, which a save resets.
    if (submit and open) _ = editor.submitSnippetForm();
}

/// One row of the snippet form: the field's name, then a one-line entry
/// editing `field`'s buffer in place (dvui keeps it NUL-terminated; the
/// length is copied back every frame) — across the row, or short with the
/// dim `desc` beside it. Enter in it sets `submit`. Returns the entry's id.
fn snippetFormLine(
    form: *snippet_form_mod.State,
    field: snippet_form_mod.Field,
    label: []const u8,
    tag: []const u8,
    desc: ?[]const u8,
    placeholder: ?[]const u8,
    label_w: f32,
    dim: dvui.Color,
    submit: *bool,
) dvui.Id {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = @intFromEnum(field) });
    defer row.deinit();
    const label_id = snippetFormLabel(label, label_w);
    const slot = form.slot(field);
    var opts: dvui.Options = .{ .tag = tag, .label = .{ .by_id = label_id } };
    if (desc == null) {
        opts.expand = .horizontal;
    } else {
        opts.min_size_content = dvui.Font.theme(.body).sizeM(12, 1);
    }
    const te = dvui.textEntry(@src(), .{ .text = .{ .buffer = slot.buf }, .placeholder = placeholder }, opts);
    slot.len.* = te.textGet().len;
    if (te.enter_pressed) submit.* = true;
    const id = te.data().id;
    te.deinit();
    if (desc) |d| dvui.labelNoFmt(@src(), d, .{}, .{ .gravity_y = 0.5, .color_text = dim });
    return id;
}

/// A snippet-form field name, level with the first text line of the entry
/// beside it (an entry's margin, border and padding: 4 + 1 + 6). Returns
/// its id: the entry's accessibility label.
fn snippetFormLabel(text: []const u8, width: f32) dvui.Id {
    var wd: dvui.WidgetData = undefined;
    dvui.labelNoFmt(@src(), text, .{}, .{
        .min_size_content = .{ .w = width },
        .padding = .{ .x = 0, .y = 11, .w = 10, .h = 0 },
        .data_out = &wd,
    });
    return wd.id;
}

/// Memoized find match count. The overlay queries this every frame while
/// Find is open — without the cache that was a full O(buffer) scan (plus a
/// full scratch copy when the gap was interior) per rendered frame.
var match_cache_count: usize = 0;
var match_cache_version: u64 = 0;
/// Document id, not address: after a close, another document can sit at
/// the same address with the same buffer version.
var match_cache_doc: ?u64 = null;
var match_cache_needle: [256]u8 = undefined;
var match_cache_needle_len: usize = 0;

/// Count total occurrences of needle in the document buffer.
fn guiCountMatches(editor: *Editor, needle: []const u8) usize {
    const doc = editor.activeDoc();
    const doc_key = doc.id;
    if (match_cache_doc == doc_key and
        doc.buffer.version == match_cache_version and
        needle.len == match_cache_needle_len and
        std.mem.eql(u8, match_cache_needle[0..match_cache_needle_len], needle))
    {
        return match_cache_count;
    }

    const buf_len = doc.buffer.byteLen();
    const content = doc.buffer.slice(0, buf_len);
    var count: usize = 0;
    var pos: usize = 0;
    while (pos <= content.len -| needle.len) {
        if (std.mem.indexOf(u8, content[pos..], needle)) |idx| {
            count += 1;
            pos = pos + idx + needle.len;
        } else break;
    }

    if (needle.len <= match_cache_needle.len) {
        match_cache_doc = doc_key;
        match_cache_version = doc.buffer.version;
        match_cache_needle_len = needle.len;
        @memcpy(match_cache_needle[0..needle.len], needle);
        match_cache_count = count;
    }
    return count;
}

// ===========================================================================
// Overlay rendering for modal modes
// ===========================================================================

/// Draw modal overlays inside the editor pane using renderText (no DVUI widgets).
/// Draw the LSP completion popup near the cursor position.
fn drawCompletionPopupGui(editor: *Editor, render_area: dvui.Rect.Physical, font: dvui.Font, line_height: f32, scale: f32) void {
    if (!build_options.has_gui) return;

    const items = editor.completion_items.items;
    if (items.len == 0) return;

    const max_visible: usize = @min(items.len, 10);
    const pad: f32 = 4 * scale;
    const row_h = line_height;

    // Calculate popup dimensions
    var max_label_w: f32 = 0;
    for (items) |item| {
        const w = font.textSize(item.label).w * scale;
        if (w > max_label_w) max_label_w = w;
    }
    const popup_w = @min(max_label_w + pad * 4, render_area.w * 0.6);
    const popup_h = @as(f32, @floatFromInt(max_visible)) * row_h + pad;

    // Position near cursor
    const doc = editor.activeDoc();
    const cursor = doc.cursors.primaryConst();
    const cursor_pos = doc.buffer.offsetToPos(cursor.offset);
    const tab_width = editor.tabWidthFor(doc);

    // Gutter width
    const line_count = doc.lineCount();
    const min_digits = editor.gutter_min_digits;
    const gutter_digits = guiLineNumberDigits(line_count, min_digits);
    const gutter_padding: f32 = 8 * scale;
    const char_w = font.textSize("0").w * scale;
    const gutter_w = @as(f32, @floatFromInt(gutter_digits + 1)) * char_w + gutter_padding;

    // Cursor X position (approximate: use col with tab expansion)
    const col = cursor_pos.col;
    // Get line content to count tabs before cursor for width calculation
    const line_text = doc.lineContent(cursor_pos.line);
    var visual_col: usize = 0;
    var byte_col: usize = 0;
    while (byte_col < col and byte_col < line_text.len) : (byte_col += 1) {
        if (line_text[byte_col] == '\t') {
            visual_col = (visual_col / tab_width + 1) * tab_width;
        } else {
            visual_col += 1;
        }
    }
    const cursor_x = render_area.x + gutter_w + @as(f32, @floatFromInt(visual_col)) * char_w;

    // Cursor Y — approximate from scroll offset
    const cursor_line = cursor_pos.line;
    const scroll_top = doc.scroll_top;
    const cursor_y_rel: f32 = if (cursor_line >= scroll_top)
        @as(f32, @floatFromInt(cursor_line - scroll_top)) * line_height
    else
        0;
    const cursor_y = render_area.y + cursor_y_rel + line_height;

    // Position popup below cursor, shift up if near bottom
    var popup_x = @min(cursor_x, render_area.x + render_area.w - popup_w);
    _ = &popup_x;
    var popup_y = cursor_y;
    if (popup_y + popup_h > render_area.y + render_area.h) {
        // Show above cursor
        popup_y = render_area.y + cursor_y_rel - popup_h;
    }

    // Background
    const bg = toDvui(editor.theme.overlay_bg);
    const fg = toDvui(editor.theme.overlay_fg);
    const sel_bg = toDvui(editor.theme.overlay_selection);
    const dim = toDvui(editor.theme.overlay_dim);

    const bg_rect: dvui.Rect.Physical = .{
        .x = popup_x,
        .y = popup_y,
        .w = popup_w,
        .h = popup_h,
    };
    bg_rect.fill(.{}, .{ .color = bg, .fade = 1.0 });

    // RectScale for text rendering
    const rs: dvui.RectScale = .{
        .r = .{ .x = popup_x, .y = popup_y, .w = popup_w, .h = popup_h },
        .s = scale,
    };

    // Scroll offset for visible window
    const scroll_off: usize = if (editor.completion_selected >= max_visible)
        editor.completion_selected - max_visible + 1
    else
        0;

    var row: usize = 0;
    while (row < max_visible) : (row += 1) {
        const idx = scroll_off + row;
        if (idx >= items.len) break;
        const item = items[idx];
        const is_selected = idx == editor.completion_selected;

        const row_y = popup_y + @as(f32, @floatFromInt(row)) * row_h;

        // Selection highlight
        if (is_selected) {
            const sel_rect: dvui.Rect.Physical = .{
                .x = popup_x,
                .y = row_y,
                .w = popup_w,
                .h = row_h,
            };
            sel_rect.fill(.{}, .{ .color = sel_bg, .fade = 1.0 });
        }

        // Label text
        renderOverlayText(font, item.label, popup_x + pad, row_y, rs, fg);

        // Detail text (dimmed, after label)
        if (item.detail) |detail| {
            if (detail.len > 0) {
                const label_w = font.textSize(item.label).w * scale;
                renderOverlayText(font, detail, popup_x + pad + label_w + pad * 2, row_y, rs, dim);
            }
        }
    }
}

fn drawModalOverlay(editor: *Editor, render_area: dvui.Rect.Physical, render_rs: dvui.RectScale, scale: f32) void {
    if (!build_options.has_gui) return;

    const font = dvui.Font.theme(.mono);
    const lh = font.lineHeight() * scale;
    const pad: f32 = 8 * scale;
    const fg = toDvui(editor.theme.overlay_fg);
    const bg = toDvui(editor.theme.overlay_bg);
    const dim = toDvui(editor.theme.overlay_dim);
    const warn_color = toDvui(editor.theme.overlay_warn);

    switch (editor.mode) {
        .filetree_prompt => {
            // Create/rename draw inline in the tree panel (with this bar
            // as the fallback when the panel is hidden mid-prompt);
            // delete confirm is a clickable dialog (filetreeDeleteDialog).
            if (editor.filetree_prompt_kind != .delete_confirm and !editor.filetree_visible) {
                const h = lh + pad * 2;
                fillBar(render_area, 0, h, bg);
                var buf: [600]u8 = undefined;
                const txt = switch (editor.filetree_prompt_kind) {
                    .create => std.fmt.bufPrint(&buf, "New (end with / for folder): {s}_", .{editor.open_buf[0..editor.open_buf_len]}) catch "New: ",
                    .rename => std.fmt.bufPrint(&buf, "Rename: {s}_", .{editor.open_buf[0..editor.open_buf_len]}) catch "Rename: ",
                    .delete_confirm => unreachable,
                };
                renderOverlayText(font, txt, render_area.x + pad, render_area.y + pad, render_rs, fg);
            }
        },
        .goto_line => {
            const h = lh + pad * 2;
            fillBar(render_area, 0, h, bg);
            var buf: [64]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "Go to line: {s}_", .{editor.goto_buf[0..editor.goto_buf_len]}) catch "Go to line: ";
            renderOverlayText(font, txt, render_area.x + pad, render_area.y + pad, render_rs, fg);
        },
        .find_replace => {
            const h = lh * 2 + pad * 3;
            fillBar(render_area, 0, h, bg);
            // Find line
            const find_color = if (!editor.replace_field_active) fg else dim;
            var find_buf: [300]u8 = undefined;
            const find_txt = std.fmt.bufPrint(&find_buf, "Find:    {s}{s}", .{
                editor.find_buf[0..editor.find_buf_len],
                @as([]const u8, if (!editor.replace_field_active) "_" else ""),
            }) catch "Find:    ";
            renderOverlayText(font, find_txt, render_area.x + pad, render_area.y + pad, render_rs, find_color);
            // Match count on right of find line
            const fr_needle = editor.find_buf[0..editor.find_buf_len];
            if (fr_needle.len > 0) {
                const fr_count = guiCountMatches(editor, fr_needle);
                var fr_count_buf: [64]u8 = undefined;
                const fr_count_str = std.fmt.bufPrint(&fr_count_buf, "{d} match{s}", .{
                    fr_count, @as([]const u8, if (fr_count == 1) "" else "es"),
                }) catch "";
                if (fr_count_str.len > 0) {
                    const fr_count_w = font.textSize(fr_count_str).w * scale;
                    const fr_count_color = if (fr_count == 0) warn_color else dim;
                    renderOverlayText(font, fr_count_str, render_area.x + render_area.w - fr_count_w - pad, render_area.y + pad, render_rs, fr_count_color);
                }
            } else if (editor.status_message.len > 0) {
                const msg_w = font.textSize(editor.status_message).w * scale;
                renderOverlayText(font, editor.status_message, render_area.x + render_area.w - msg_w - pad, render_area.y + pad, render_rs, warn_color);
            }
            // Replace line
            const repl_color = if (editor.replace_field_active) fg else dim;
            var repl_buf: [300]u8 = undefined;
            const repl_txt = std.fmt.bufPrint(&repl_buf, "Replace: {s}{s}", .{
                editor.replace_buf[0..editor.replace_buf_len],
                @as([]const u8, if (editor.replace_field_active) "_" else ""),
            }) catch "Replace: ";
            renderOverlayText(font, repl_txt, render_area.x + pad, render_area.y + pad + lh + pad, render_rs, repl_color);
        },
        .command_palette => {
            const filter = editor.palette_buf[0..editor.palette_buf_len];
            const max_items: usize = 10;
            // Count matching items for height
            var match_count: usize = 0;
            const names = editor.commands.allNames() catch &[_][]const u8{};
            for (names) |name| {
                if (filter.len == 0 or Editor.paletteMatch(name, filter)) {
                    match_count += 1;
                    if (match_count >= max_items) break;
                }
            }
            // Clamp selection to valid range
            if (match_count > 0) {
                if (editor.palette_selected >= match_count) editor.palette_selected = match_count - 1;
            } else {
                editor.palette_selected = 0;
            }
            const h = lh * @as(f32, @floatFromInt(1 + match_count)) + pad * @as(f32, @floatFromInt(2 + match_count));
            fillBar(render_area, 0, h, bg);
            // Input line
            var input_buf: [300]u8 = undefined;
            const input_txt = std.fmt.bufPrint(&input_buf, "> {s}_", .{filter}) catch "> ";
            renderOverlayText(font, input_txt, render_area.x + pad, render_area.y + pad, render_rs, fg);
            // Highlight color for selected item
            const sel_highlight = toDvui(editor.theme.overlay_selection);
            // List items
            var item_y: f32 = render_area.y + pad + lh + pad;
            var shown: usize = 0;
            for (names) |name| {
                if (shown >= max_items) break;
                if (filter.len > 0 and !Editor.paletteMatch(name, filter)) continue;
                if (shown == editor.palette_selected) {
                    // Highlight bar behind selected item
                    const bar: dvui.Rect.Physical = .{ .x = render_area.x, .y = item_y, .w = render_area.w, .h = lh + pad };
                    bar.fill(.{}, .{ .color = sel_highlight, .fade = 1.0 });
                    renderOverlayText(font, name, render_area.x + pad + pad, item_y, render_rs, fg);
                } else {
                    renderOverlayText(font, name, render_area.x + pad + pad, item_y, render_rs, dim);
                }
                item_y += lh + pad;
                shown += 1;
            }
        },
        .picker => {
            const p = &editor.picker;
            const max_items: usize = 10;
            const rows = @min(p.count(), max_items);
            const shown_rows = @max(rows, 1); // one row for the hint / "(no matches)"
            const h = lh * @as(f32, @floatFromInt(2 + shown_rows)) + pad * @as(f32, @floatFromInt(3 + shown_rows));
            fillBar(render_area, 0, h, bg);
            renderOverlayText(font, p.title(), render_area.x + pad, render_area.y + pad, render_rs, dim);
            var input_buf: [300]u8 = undefined;
            const input_txt = std.fmt.bufPrint(&input_buf, "> {s}_", .{p.filter()}) catch "> ";
            renderOverlayText(font, input_txt, render_area.x + pad, render_area.y + pad + lh + pad, render_rs, fg);
            const sel_highlight = toDvui(editor.theme.overlay_selection);
            var item_y: f32 = render_area.y + (pad + lh) * 2 + pad;
            if (rows == 0) {
                renderOverlayText(font, if (p.items.items.len == 0) p.empty_hint else "(no matches)", render_area.x + pad + pad, item_y, render_rs, dim);
            }
            const first = p.firstVisible(max_items);
            var i: usize = first;
            while (i < p.count() and i < first + max_items) : (i += 1) {
                const item = p.itemAt(i);
                var row_buf: [512]u8 = undefined;
                const full_txt = if (item.detail.len > 0) std.fmt.bufPrint(&row_buf, "{s}   {s}", .{ item.label, item.detail }) catch item.label else item.label;
                const row_txt = fitOverlayText(font, full_txt, render_area.w - pad * 4, scale);
                if (i == p.selected) {
                    const bar: dvui.Rect.Physical = .{ .x = render_area.x, .y = item_y, .w = render_area.w, .h = lh + pad };
                    bar.fill(.{}, .{ .color = sel_highlight, .fade = 1.0 });
                    renderOverlayText(font, row_txt, render_area.x + pad + pad, item_y, render_rs, fg);
                } else {
                    renderOverlayText(font, row_txt, render_area.x + pad + pad, item_y, render_rs, dim);
                }
                item_y += lh + pad;
            }
        },
        .file_finder => {
            const filter = editor.finder_buf[0..editor.finder_buf_len];
            // The rows scrolled so the selection shows; drawing never moves
            // the selection (the core keeps it in range).
            const range = editor.finderVisibleRange(8);
            const match_count = range.end - range.start;
            // Compact top-centered dropdown with an OPAQUE background — the
            // whole point is reading the live preview around and below it,
            // so no full-width bar and no translucent overlay_bg here.
            const row_h = lh + pad;
            const rows: f32 = @floatFromInt(@max(match_count, 1)); // one row for "(no matches)"
            const panel_w = @min(render_area.w * 0.9, 640 * scale);
            const panel_h = row_h * (rows + 1) + pad * 2;
            // Bottom-anchored: the preview's opening lines stay visible at
            // the top, and the wheel can scroll the preview for more.
            const panel: dvui.Rect.Physical = .{
                .x = render_area.x + (render_area.w - panel_w) / 2,
                .y = render_area.y + @max(0, render_area.h - panel_h - 8 * scale),
                .w = panel_w,
                .h = panel_h,
            };
            var border = dim;
            border.a = 255;
            panel.fill(.{}, .{ .color = border, .fade = 1.0 });
            var solid_bg = bg;
            solid_bg.a = 255;
            const inset = @max(1.0, 1 * scale);
            const inner: dvui.Rect.Physical = .{
                .x = panel.x + inset,
                .y = panel.y + inset,
                .w = panel.w - inset * 2,
                .h = panel.h - inset * 2,
            };
            inner.fill(.{}, .{ .color = solid_bg, .fade = 1.0 });

            const prev_clip = dvui.clip(panel);
            defer dvui.clipSet(prev_clip);

            var input_buf: [300]u8 = undefined;
            const input_txt = std.fmt.bufPrint(&input_buf, "> {s}_", .{filter}) catch "> ";
            renderOverlayText(font, input_txt, panel.x + pad, panel.y + pad, render_rs, fg);
            const sel_highlight = toDvui(editor.theme.overlay_selection);
            var item_y: f32 = panel.y + pad + row_h;
            for (editor.finder_matches.items[range.start..range.end], range.start..) |fi, row| {
                const path = editor.finder_files.items[fi];
                if (row == editor.finder_selected) {
                    const bar: dvui.Rect.Physical = .{ .x = inner.x, .y = item_y, .w = inner.w, .h = row_h };
                    bar.fill(.{}, .{ .color = sel_highlight, .fade = 1.0 });
                    renderOverlayText(font, path, panel.x + pad + pad, item_y, render_rs, fg);
                } else {
                    renderOverlayText(font, path, panel.x + pad + pad, item_y, render_rs, dim);
                }
                item_y += row_h;
            }
            if (editor.finder_matches.items.len == 0) {
                renderOverlayText(font, "(no matching files)", panel.x + pad + pad, item_y, render_rs, dim);
            }
        },
        .confirm_quit => {
            const h = lh + pad * 2;
            fillBar(render_area, 0, h, bg);
            renderOverlayText(font, "Unsaved changes! [S]ave [D]iscard [C]ancel", render_area.x + pad, render_area.y + pad, render_rs, fg);
        },
        .confirm_close => {
            const h = lh + pad * 2;
            fillBar(render_area, 0, h, bg);
            var msg_buf: [320]u8 = undefined;
            renderOverlayText(font, editor.confirmClosePrompt(&msg_buf), render_area.x + pad, render_area.y + pad, render_rs, fg);
        },
        .confirm_overwrite => {
            const h = lh + pad * 2;
            fillBar(render_area, 0, h, bg);
            renderOverlayText(font, editor.overwritePrompt(), render_area.x + pad, render_area.y + pad, render_rs, fg);
        },
        // .settings is a real DVUI floating dialog now (settingsDialog),
        // not a custom-rendered overlay.
        else => {},
    }
}

fn fillBar(area: dvui.Rect.Physical, y_offset: f32, height: f32, color: dvui.Color) void {
    const rect: dvui.Rect.Physical = .{
        .x = area.x,
        .y = area.y + y_offset,
        .w = area.w,
        .h = height,
    };
    rect.fill(.{}, .{ .color = color, .fade = 1.0 });
}

/// The longest prefix of `text` (on a character boundary) that fits in
/// `max_w` physical pixels — overlay rows must not run off the window.
fn fitOverlayText(font: dvui.Font, text: []const u8, max_w: f32, scale: f32) []const u8 {
    var end = text.len;
    while (end > 0 and font.textSize(text[0..end]).w * scale > max_w) {
        end -= 1;
        while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    }
    return text[0..end];
}

fn renderOverlayText(font: dvui.Font, text: []const u8, x: f32, y: f32, rs: dvui.RectScale, color: dvui.Color) void {
    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = rs,
        .p = .{ .x = x, .y = y },
        .color = color,
    }) catch {};
}

fn handleEncodingKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (hasCommandMod(key.mod)) return; // only plain keys answer (Ctrl+S is not "save")
    switch (editor.mode) {
        .encoding_picker => switch (key.code) {
            .escape => editor.cancelEncoding(),
            .up => editor.encoding_selected -|= 1,
            .down, .tab => editor.encoding_selected = (editor.encoding_selected + 1) % editor.encodingCount(),
            .enter => editor.chooseEncoding(editor.encoding_selected),
            else => {},
        },
        .confirm_reopen => switch (key.code) {
            .s => editor.resolveReopen(.save),
            .d => editor.resolveReopen(.discard),
            .c, .escape => editor.resolveReopen(.cancel),
            else => {},
        },
        .confirm_encoding => switch (key.code) {
            .s => editor.resolveEncodingSave(true),
            .c, .escape => editor.resolveEncodingSave(false),
            else => {},
        },
        else => {},
    }
}

fn handleToolKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    // Plain keys only: Ctrl+S must not stage, Ctrl+R rerun, Ctrl+U unstage.
    if (hasCommandMod(key.mod)) return;
    if (editor.mode == .git_stage_prompt) {
        switch (key.code) {
            .s => editor.git.resolveStage(editor, true),
            .c, .escape => editor.git.resolveStage(editor, false),
            else => {},
        }
        return;
    }
    if (editor.mode == .task_save_prompt) {
        switch (key.code) {
            .s => editor.tasks.resolveSave(editor, .save),
            .r => editor.tasks.resolveSave(editor, .run),
            .c, .escape => editor.tasks.resolveSave(editor, .cancel),
            else => {},
        }
        return;
    }
    switch (key.code) {
        .escape => editor.setMode(.normal),
        // Space too, so the left hand reaches it next to A / W / D / R.
        .enter, .space => editor.tool_panel.activate(editor),
        .up => editor.tool_panel.move(editor, false),
        .down => editor.tool_panel.move(editor, true),
        .page_up => editor.tool_panel.page(editor, false, 40),
        .page_down => editor.tool_panel.page(editor, true, 40),
        .f => editor.tool_panel.action(editor, 'f'),
        .s => editor.tool_panel.action(editor, 's'),
        .r => editor.tool_panel.action(editor, 'r'),
        .d => editor.tool_panel.action(editor, 'd'),
        .u => editor.tool_panel.action(editor, 'u'),
        .o => editor.tool_panel.action(editor, 'o'),
        .a => editor.tool_panel.action(editor, 'a'),
        .w => editor.tool_panel.action(editor, 'w'),
        .p => editor.tool_panel.action(editor, 'p'),
        else => {},
    }
}

/// Rows the tool dialog's table renders at once (a window around the
/// selection when the list is longer).
const tool_grid_max_rows: usize = 400;
/// The table's fixed height. The dialog sizes itself to its content once and
/// then keeps that size, so the table must not grow with the list (its
/// scroll area would otherwise ask for every row's height): extra rows
/// scroll inside it.
const tool_grid_height: f32 = 360;

/// Padding inside a table cell.
const tool_cell_pad: dvui.Rect = .{ .x = 6, .y = 2, .w = 6, .h = 2 };

/// A fixed table column: wide enough for its heading plus the cell padding.
fn toolColumnWidth(heading: []const u8) f32 {
    return dvui.themeGet().font_body.textSize(heading).w + tool_cell_pad.x + tool_cell_pad.w + 10;
}
/// The width of a column that holds one icon.
const tool_icon_col_w: f32 = 36;

/// The Debug view's overview rows carry the debugger's icons; its other
/// lists (threads, frames, ...) have none.
fn debugRowIcon(editor: *const Editor, index: usize) ?icons.Icon {
    if (editor.dap.view != .overview) return null;
    return switch (index) {
        0 => .gear,
        1 => .list,
        2 => .lines,
        3 => .equal,
        4 => .breakpoint,
        5 => .terminal,
        6 => .continue_run,
        7 => .pause,
        8 => .step_over,
        9 => .step_into,
        10 => .step_out,
        11 => .stop,
        else => null,
    };
}

/// The tool dialog's rows as a table. The Review view has two checkbox
/// columns (Approved, Needs work — ticking one gives that verdict, ticking
/// it again takes it back), the change letter and the file; the Changes
/// view has its status letters and the file; every other view one text
/// column. The last column takes the rest of the table's width, odd rows
/// are banded and every cell has a border. A left click anywhere on a row
/// selects it (the path-tracking views remember its path, so a refresh
/// cannot retarget A / W / S / U; the other views open it at once); the
/// click is hit-tested against full-width bands taken from the laid-out
/// cells rather than the grid's remembered row height. The table scrolls to
/// keep the keyboard's row in view.
fn toolGrid(editor: *Editor, state: *@import("../core/tool_panel.zig").State, total: usize) void {
    const cols: usize = switch (state.kind) {
        .review => 5,
        .changes, .debug => 2,
        else => 1,
    };
    if (win_ui.tool_grid_kind != state.kind) {
        win_ui.tool_grid_kind = state.kind;
        win_ui.tool_grid_si = .{};
        win_ui.tool_grid_followed = null;
    }
    // Column widths: fixed ones sized by their heading, a negative ratio for
    // the column that takes the remaining width.
    const ratios: [5]f32 = switch (state.kind) {
        .review => .{ toolColumnWidth("Verdict"), toolColumnWidth("Approved"), toolColumnWidth("Needs work"), toolColumnWidth("Change"), -1 },
        .changes => .{ toolColumnWidth("Index / tree"), -1, 0, 0, 0 },
        .debug => .{ tool_icon_col_w, -1, 0, 0, 0 },
        else => .{ -1, 0, 0, 0, 0 },
    };
    var widths: [5]f32 = @splat(0);
    var grid = dvui.grid(@src(), .colWidths(widths[0..cols]), .{ .scroll_opts = .{ .scroll_info = &win_ui.tool_grid_si, .horizontal_bar = .auto } }, .{ .expand = .horizontal, .background = true, .border = dvui.Rect.all(1), .min_size_content = .{ .h = tool_grid_height }, .max_size_content = .{ .w = 1100, .h = tool_grid_height }, .tag = "tool_grid" });
    defer grid.deinit();
    dvui.columnLayoutProportional(ratios[0..cols], widths[0..cols], grid.data().contentRect().w);
    // The window's first, hidden frame has no width yet.
    for (widths[0..cols]) |*w| w.* = @max(w.*, 0);
    // The frame's unhandled left press inside the table and the pointer's
    // position inside it, if any; the rows they fall in are found while the
    // rows are laid out below. Found before the headings: a mouse event only
    // matches inside the current clip, and the header row's scroll clip
    // stays active until the first body cell.
    var press: ?*dvui.Event = null;
    var pointer: ?dvui.Point.Physical = null;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse or !dvui.eventMatchSimple(e, grid.data())) continue;
        const me = e.evt.mouse;
        if (me.action == .press and me.button == .left) {
            if (press == null) press = e;
        } else if (me.action == .position) pointer = me.p;
    }
    const head_borders: dvui.GridWidget.CellStyle.Borders = .initBox(cols, 1, 1, 1);
    switch (state.kind) {
        .review => {
            dvui.gridHeading(@src(), grid, 0, "Verdict", .fixed, head_borders);
            dvui.gridHeading(@src(), grid, 1, "Approved", .fixed, head_borders);
            dvui.gridHeading(@src(), grid, 2, "Needs work", .fixed, head_borders);
            dvui.gridHeading(@src(), grid, 3, "Change", .fixed, head_borders);
            dvui.gridHeading(@src(), grid, 4, "File", .fixed, head_borders);
        },
        .changes => {
            dvui.gridHeading(@src(), grid, 0, "Index / tree", .fixed, head_borders);
            dvui.gridHeading(@src(), grid, 1, "File", .fixed, head_borders);
        },
        .debug => {
            dvui.gridHeading(@src(), grid, 0, "", .fixed, head_borders);
            dvui.gridHeading(@src(), grid, 1, "Debugger", .fixed, head_borders);
        },
        else => {},
    }
    // The window of rows drawn: everything when it fits, else rows around
    // the selection. `first` maps table rows back to list indices.
    const first: usize = if (total <= tool_grid_max_rows) 0 else @min(state.selected -| tool_grid_max_rows / 2, total - tool_grid_max_rows);
    const shown = @min(total - first, tool_grid_max_rows);
    var clicked: ?usize = null;
    var clicked_widget = false; // the cell's own widget (a checkbox) took the click
    // The chosen row wears the editor's selection color; the hovered row
    // and the bands are the table's background nudged toward the text
    // color (mixed here, so no translucency is involved), so the three read
    // apart on any theme.
    const sel_color = toDvui(editor.theme.selection);
    const table_bg = dvui.themeGet().color(.content, .fill);
    const text_color = toDvui(editor.theme.text);
    const hover_color = table_bg.lerp(text_color, 0.16);
    const band_color = table_bg.lerp(text_color, 0.07);
    // The hovered table row: the grid maps the pointer through last frame's
    // row height, and the columns span the width, so it covers whole rows.
    const hovered_row: ?usize = blk: {
        const p = pointer orelse break :blk null;
        const cell = grid.pointToCell(p) orelse break :blk null;
        break :blk cell.row_num;
    };
    const borders: dvui.GridWidget.CellStyle.Borders = .initBox(cols, @max(shown, 1), 1, 1);
    // The click bands span the table's width.
    const body = grid.data().contentRectScale().r;
    const pad = tool_cell_pad;
    for (0..shown) |row| {
        const index = first + row;
        // Selected beats hovered beats the banding of odd rows; even rows
        // keep the table's own background.
        const fill: ?dvui.Color = if (index == state.selected) sel_color else if (hovered_row == row) hover_color else if (row % 2 == 1) band_color else null;
        var buf: [4096]u8 = undefined;
        var letters: [2]u8 = .{ ' ', ' ' };
        var texts: [5][]const u8 = .{ "", "", "", "", "" };
        const Col = enum { text, icon, verdict, approve, needs_work };
        var kinds: [5]Col = .{ .text, .text, .text, .text, .text };
        var count: usize = 1;
        var status: review.Status = .unreviewed;
        var row_icon: ?icons.Icon = null;
        switch (state.kind) {
            .review => {
                const file = editor.review.files.items[index];
                status = editor.review.statusOf(file.path);
                letters[0] = file.change;
                kinds = .{ .verdict, .approve, .needs_work, .text, .text };
                texts[3] = letters[0..1];
                texts[4] = std.fmt.bufPrint(&buf, "{s}{s}{s}{s}", .{ file.path, if (file.old_path != null) " <- " else "", file.old_path orelse "", if (file.change == 'U') " (conflict)" else "" }) catch file.path;
                count = 5;
            },
            .changes => {
                const change = editor.git.changes.items[index];
                letters = .{ change.x, change.y };
                texts[0] = &letters;
                texts[1] = std.fmt.bufPrint(&buf, "{s}{s}{s}{s}", .{ change.path, if (change.old_path != null) " <- " else "", change.old_path orelse "", if (change.conflict()) " (conflict)" else "" }) catch change.path;
                count = 2;
            },
            .debug => {
                kinds = .{ .icon, .text, .text, .text, .text };
                row_icon = debugRowIcon(editor, index);
                texts[1] = state.row(editor, index, &buf);
                count = 2;
            },
            else => texts[0] = state.row(editor, index, &buf),
        }
        for (0..count) |col| {
            const cell: dvui.GridWidget.Cell = .colRow(col, row);
            var cell_opts = borders.cellOptions(cell);
            cell_opts.color_fill = fill;
            var box = grid.bodyCell(@src(), cell, cell_opts);
            defer box.deinit();
            const cell_rect = box.data().borderRectScale().r;
            if (col == 0) {
                // The row's click target: one band across the table.
                const band: dvui.Rect.Physical = .{ .x = body.x, .y = cell_rect.y, .w = body.w, .h = cell_rect.h };
                if (press) |e| if (band.contains(e.evt.mouse.p)) {
                    clicked = index;
                };
            }
            switch (kinds[col]) {
                .icon => if (row_icon) |row_ic| {
                    icons.draw(@src(), row_ic, .{ .gravity_x = 0.5, .gravity_y = 0.5, .min_size_content = .{ .h = 15 }, .padding = pad });
                },
                .verdict => if (status != .unreviewed) {
                    // The verdict as an icon: a check, or an exclamation mark.
                    const approved = status == .approved;
                    icons.draw(@src(), if (approved) .check else .warning, .{
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .min_size_content = .{ .h = 15 },
                        .padding = pad,
                        .color_text = toDvui(if (approved) editor.theme.git_added else editor.theme.overlay_warn),
                    });
                },
                .approve, .needs_work => {
                    // A press inside a checkbox cell is the checkbox's: it
                    // selects the row itself when it toggles.
                    if (press) |e| if (cell_rect.contains(e.evt.mouse.p)) {
                        clicked_widget = true;
                    };
                    const verdict: review.Status = if (kinds[col] == .approve) .approved else .needs_work;
                    var ticked = status == verdict;
                    if (dvui.checkbox(@src(), &ticked, null, .{ .gravity_x = 0.5, .padding = pad })) {
                        state.select(editor, index);
                        editor.review.verdict(editor, index, verdict);
                    }
                },
                .text => dvui.labelNoFmt(@src(), texts[col], .{}, .{ .padding = pad }),
            }
        }
    }
    if (total == 0) {
        var box = grid.bodyCell(@src(), .colRow(0, 0), .{});
        defer box.deinit();
        dvui.labelNoFmt(@src(), "No entries.", .{}, .{ .padding = pad });
    }
    // Keep the keyboard's row in view.
    if (total > 0 and grid.row_height > 0 and win_ui.tool_grid_followed != state.selected) {
        win_ui.tool_grid_followed = state.selected;
        const row_y = @as(f32, @floatFromInt(state.selected - first)) * grid.row_height;
        const vp = win_ui.tool_grid_si.viewport;
        if (row_y < vp.y) {
            win_ui.tool_grid_si.scrollToOffset(.vertical, row_y);
        } else if (vp.h > 0 and row_y + grid.row_height > vp.y + vp.h) {
            win_ui.tool_grid_si.scrollToOffset(.vertical, row_y + grid.row_height - vp.h);
        }
    }
    if (clicked) |index| if (index < total and !clicked_widget) {
        if (press) |e| if (!e.handled) e.handle(@src(), grid.data());
        state.select(editor, index);
        if (!state.tracksPath()) state.activate(editor);
    };
}

fn toolDialog(editor: *Editor) void {
    const mode = editor.mode;
    var open = true;
    var dialog = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{ .min_size_content = .{ .w = 900 } });
    defer {
        dialog.deinit();
        if (!open and editor.mode == mode) {
            if (mode == .task_save_prompt) editor.tasks.resolveSave(editor, .cancel) else if (mode == .git_stage_prompt) editor.git.resolveStage(editor, false) else editor.setMode(.normal);
            dvui.focusSubwindow(null, null);
        }
    }
    // The window sizes itself to its content once, then keeps that size.
    // Content that has outgrown it since (another view's wider button row
    // took over while it was open) is fitted again on the next frame, so
    // the bottom row of buttons never leaves the window.
    if (dvui.minSizeGet(dialog.data().id)) |needed| {
        const have = dialog.data().rect;
        // A window never grows past the screen, so content wider than the
        // screen must not ask for a refit every frame.
        const screen = dvui.windowRect().size();
        if (@min(needed.w, screen.w) > have.w + 0.5 or @min(needed.h, screen.h) > have.h + 0.5) {
            dialog.autoSize();
            dvui.refresh(null, @src(), dialog.data().id);
        }
    }
    var title: [1024]u8 = undefined;
    dialog.dragAreaSet(dvui.windowHeader(if (mode == .task_save_prompt) "Save before running task" else if (mode == .git_stage_prompt) "Save before staging" else editor.tool_panel.title(editor, &title), "", &open));
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(10) });
    defer box.deinit();
    if (mode == .git_stage_prompt) {
        dvui.labelNoFmt(@src(), "Staging uses saved file contents. Save the dirty buffer first?", .{}, .{});
        if (dvui.button(@src(), "Save and stage (S)", .{}, .{})) editor.git.resolveStage(editor, true);
        if (dvui.button(@src(), "Cancel (Esc)", .{}, .{})) editor.git.resolveStage(editor, false);
    } else if (mode == .task_save_prompt) {
        dvui.labelNoFmt(@src(), "The task reads files on disk. Save dirty workspace documents first?", .{}, .{});
        if (dvui.button(@src(), "Save and run (S)", .{}, .{})) editor.tasks.resolveSave(editor, .save);
        if (dvui.button(@src(), "Run saved files (R)", .{}, .{})) editor.tasks.resolveSave(editor, .run);
        if (dvui.button(@src(), "Cancel (Esc)", .{}, .{})) editor.tasks.resolveSave(editor, .cancel);
    } else {
        const state = &editor.tool_panel;
        const total = state.count(editor);
        // The status bar is behind this modal window: show its message here
        // too, so a refused verdict or a refresh is not silent. The line is
        // always there (empty text keeps its height), so a message arriving
        // does not change the window's size.
        dvui.labelNoFmt(@src(), editor.status_message, .{}, .{ .expand = .horizontal });
        {
            // The view's actions: a row that wraps when the window is narrow,
            // so no button leaves the window.
            var actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
            defer actions.deinit();
            switch (state.kind) {
                .problems => {
                    if (icons.button(@src(), .filter, "Severity (F)", .{})) state.filterSeverity();
                    if (icons.button(@src(), .filter, "Source (S)", .{})) state.filterSource(editor);
                },
                .task_output => {
                    if (icons.button(@src(), .play, "Rerun (R)", .{})) state.action(editor, 'r');
                    if (icons.button(@src(), .stop, "Stop (S)", .{})) state.action(editor, 's');
                },
                .tasks, .references => {},
                .changes => {
                    if (icons.button(@src(), .diff, "Working tree diff (Enter / Space)", .{})) state.activate(editor);
                    if (icons.button(@src(), .diff, "Staged diff (D)", .{})) state.action(editor, 'd');
                    if (icons.button(@src(), .add, "Stage (S)", .{})) state.action(editor, 's');
                    if (icons.button(@src(), .remove, "Unstage (U)", .{})) state.action(editor, 'u');
                    if (icons.button(@src(), .go_to_file, "Open file (O)", .{})) state.action(editor, 'o');
                    if (icons.button(@src(), .refresh, "Refresh (R)", .{})) state.action(editor, 'r');
                },
                .review => {
                    if (icons.button(@src(), .book, "Read (Enter / Space)", .{})) state.activate(editor);
                    if (icons.button(@src(), .check, "Approve (A)", .{})) state.action(editor, 'a');
                    if (icons.button(@src(), .warning, "Needs work (W)", .{})) state.action(editor, 'w');
                    if (icons.button(@src(), .diff, "Classic diff (D)", .{})) state.action(editor, 'd');
                    if (icons.button(@src(), .go_to_file, "Open file (O)", .{})) state.action(editor, 'o');
                    if (icons.button(@src(), .refresh, "Refresh (R)", .{})) state.action(editor, 'r');
                    if (icons.button(@src(), .pin, "Pin baseline (P)", .{})) state.action(editor, 'p');
                    if (icons.button(@src(), .pin_off, "Unpin (U)", .{})) state.action(editor, 'u');
                },
                .git_diff => {},
                .debug => {
                    if (icons.button(@src(), .list, "Debug controls (R)", .{})) editor.dap.show(editor, .overview);
                    if (icons.button(@src(), .stop, "Stop / detach (S)", .{})) editor.dap.stop(editor, false);
                },
            }
        }
        if (editor.mode != mode) return;
        toolGrid(editor, state, total);
        if (editor.mode != mode) return;
        {
            var nav = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer nav.deinit();
            if (icons.button(@src(), .chevron_up, "Previous page (PgUp)", .{})) state.page(editor, false, 40);
            if (icons.button(@src(), .chevron_down, "Next page (PgDn)", .{})) state.page(editor, true, 40);
            if (icons.button(@src(), .close, "Close (Esc)", .{})) open = false;
        }
    }
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if (key.action == .up) continue;
        // Tab stays dvui's focus navigation between the dialog's buttons,
        // and a chord is not a dialog key.
        if (key.code == .tab or hasCommandMod(key.mod)) continue;
        handleToolKeyGui(editor, key);
        event.handle(@src(), box.data());
        // A key that closed or switched the dialog ends its input (a
        // second `s` after "save and stage" must not stage again).
        if (editor.mode != mode) break;
    }
}

fn handleLspKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (key.code == .escape) {
        if (editor.mode == .workspace_preview) editor.lsp_tools.resolvePreview(editor, false) else editor.setMode(.normal);
    } else if (editor.mode == .workspace_preview and key.code == .enter) editor.lsp_tools.resolvePreview(editor, true);
}

fn lspDialog(editor: *Editor) void {
    const mode = editor.mode;
    var open = true;
    var dialog = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{ .min_size_content = .{ .w = 500 } });
    defer {
        dialog.deinit();
        if (!open) {
            if (mode == .workspace_preview) editor.lsp_tools.resolvePreview(editor, false) else editor.setMode(.normal);
        }
        if (editor.mode != mode) dvui.focusSubwindow(null, null);
    }
    dialog.dragAreaSet(dvui.windowHeader(if (mode == .symbol_rename) "Rename symbol" else if (mode == .workspace_preview) "Workspace edit preview" else "Hover information", "", &open));
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(10) });
    defer box.deinit();
    if (mode == .symbol_rename) {
        const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &editor.lsp_tools.name } }, .{ .expand = .horizontal });
        editor.lsp_tools.name_len = entry.textGet().len;
        const entered = entry.enter_pressed;
        entry.deinit();
        if (entered or dvui.button(@src(), "Preview rename", .{}, .{})) editor.lsp_tools.submitRename(editor);
    } else {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .{ .w = 900, .h = 420 } });
        defer scroll.deinit();
        if (mode == .workspace_preview) {
            if (editor.lsp_tools.preview) |*plan| for (plan.files.items, 0..) |file, i| {
                var buf: [1200]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{s} ({d} edits)", .{ file.path, file.ranges.items.len }) catch file.path;
                dvui.labelNoFmt(@src(), label, .{}, .{ .id_extra = i });
            };
        } else {
            var lines = std.mem.splitScalar(u8, editor.lsp_tools.hover orelse "", '\n');
            var i: usize = 0;
            while (lines.next()) |line| : (i += 1) dvui.labelNoFmt(@src(), line, .{}, .{ .id_extra = i });
        }
    }
    if (mode == .workspace_preview and dvui.button(@src(), "Apply edits (Enter)", .{}, .{})) editor.lsp_tools.resolvePreview(editor, true);
    if (dvui.button(@src(), if (mode == .lsp_panel) "Close (Esc)" else "Cancel (Esc)", .{}, .{})) {
        if (mode == .workspace_preview) editor.lsp_tools.resolvePreview(editor, false) else editor.setMode(.normal);
    }
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key or event.evt.key.action == .up) continue;
        handleLspKeyGui(editor, event.evt.key);
        event.handle(@src(), box.data());
        if (editor.mode != mode) break;
    }
}

fn handleRecoveryKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (hasCommandMod(key.mod)) return; // Ctrl+D is not "discard all"
    switch (key.code) {
        .r => editor.resolveRecovery(.recover),
        .d => editor.resolveRecovery(.discard),
        .l, .escape => editor.resolveRecovery(.later),
        else => {},
    }
}

fn recoveryDialog(editor: *Editor) void {
    var open = true;
    var dialog = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{ .min_size_content = .{ .w = 440 } });
    defer {
        dialog.deinit();
        if (!open) editor.resolveRecovery(.later);
        if (editor.mode != .recovery_picker) dvui.focusSubwindow(null, null);
    }
    dialog.dragAreaSet(dvui.windowHeader("Recover unsaved documents", "", &open));
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(10) });
    defer box.deinit();
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key or event.evt.key.action == .up) continue;
        handleRecoveryKeyGui(editor, event.evt.key);
        event.handle(@src(), box.data());
        if (editor.mode != .recovery_picker) return;
    }
    dvui.labelNoFmt(@src(), "Snapshots from a previous instance of this workspace:", .{}, .{});
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .max_size_content = .{ .w = 900, .h = 250 } });
        defer scroll.deinit();
        if (editor.recovery) |*recovery| for (recovery.candidates.items, 0..) |candidate, index| {
            dvui.labelNoFmt(@src(), candidate.name(), .{}, .{ .id_extra = index });
        };
    }
    if (dvui.button(@src(), "Recover all (R)", .{}, .{})) editor.resolveRecovery(.recover);
    if (dvui.button(@src(), "Discard all (D)", .{}, .{})) editor.resolveRecovery(.discard);
    if (dvui.button(@src(), "Later (Esc)", .{}, .{})) editor.resolveRecovery(.later);
}

fn encodingDialog(editor: *Editor) void {
    var open = true;
    const mode = editor.mode;
    var dialog = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{ .min_size_content = .{ .w = 370 } });
    defer {
        dialog.deinit();
        if (!open) editor.cancelEncoding();
        if (editor.mode != mode or !open) dvui.focusSubwindow(null, null);
    }
    const title = if (mode == .encoding_picker) editor.encodingTitle() else if (mode == .confirm_reopen) "Save changes before reopening?" else "Save as UTF-8?";
    dialog.dragAreaSet(dvui.windowHeader(title, "", &open));
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = dvui.Rect.all(10) });
    defer box.deinit();
    const action = editor.encoding_action;
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .key or e.evt.key.action == .up) continue;
        handleEncodingKeyGui(editor, e.evt.key);
        e.handle(@src(), box.data());
        if (editor.mode != mode or editor.encoding_action != action) return;
    }
    if (mode == .encoding_picker) {
        const count = editor.encodingCount();
        for (0..count) |idx| {
            if (dvui.button(@src(), editor.encodingLabel(idx), .{}, .{
                .id_extra = idx,
                .expand = .horizontal,
                .style = if (idx == editor.encoding_selected) .highlight else .control,
            })) {
                editor.chooseEncoding(idx);
                break;
            }
        }
    } else if (mode == .confirm_reopen) {
        dvui.labelNoFmt(@src(), "The selected document has unsaved changes.", .{}, .{});
        if (dvui.button(@src(), "Save", .{}, .{})) editor.resolveReopen(.save);
        if (dvui.button(@src(), "Discard", .{}, .{})) editor.resolveReopen(.discard);
    } else {
        dvui.labelNoFmt(@src(), "Windows-1252 cannot represent this text.", .{}, .{});
        if (dvui.button(@src(), "Save as UTF-8", .{}, .{})) editor.resolveEncodingSave(true);
    }
    if (dvui.button(@src(), "Cancel", .{}, .{})) {
        if (mode == .confirm_encoding) editor.resolveEncodingSave(false) else editor.cancelEncoding();
    }
    if (editor.status_message.len > 0) dvui.labelNoFmt(@src(), editor.status_message, .{}, .{});
}

test "GUI snippets: hidden window dispatches Tab text Shift-Tab and Escape in order" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var window_state: WinUi = .{ .win_id = 0 };
    win_ui = &window_state;
    defer win_ui = undefined;
    cur_win = 0;
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer box.deinit();
    dvui.focusWidget(box.data().id, null, null);
    _ = try editor.registerSnippet(.{ .language = "*", .prefix = "demo", .description = "Demo", .body = "${1:first} ${2:tail}$0" });
    const doc = editor.activeDoc();
    try doc.loadText("demo");
    doc.cursors.primary().moveToEnd(&doc.buffer);
    try dvui.testing.pressKey(.tab, .none);
    try dvui.testing.writeText("😀");
    try dvui.testing.pressKey(.tab, .none);
    try t.expect(handleGuiKeyEvents(&editor, box.data()));
    try t.expectEqualStrings("😀 tail", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualStrings("tail", doc.selectedText().?);
    try dvui.testing.pressKey(.tab, .lshift);
    try t.expect(handleGuiKeyEvents(&editor, box.data()));
    try t.expectEqualStrings("😀", doc.selectedText().?);
    try dvui.testing.pressKey(.escape, .none);
    try t.expect(handleGuiKeyEvents(&editor, box.data()));
    try t.expect(doc.snippet_session == null);
    try t.expectEqualStrings("😀 tail", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = editor.takeKeyboardFocus(.search);
    try t.expect(!handleGuiSnippetOrCompletionKey(&editor, .{ .code = .tab, .action = .down, .mod = .none }));
}

test "GUI encoding smoke: hidden window renders picker and handles Unicode find replacement" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.filetree_visible = false;
    cur_win = 0;
    try editor.activeDoc().loadText("éé😀");
    statusBar(&editor);
    editor.startEncoding(.choose);
    encodingDialog(&editor);
    handleEncodingKeyGui(&editor, .{ .code = .down, .action = .down, .mod = .none });
    handleEncodingKeyGui(&editor, .{ .code = .enter, .action = .down, .mod = .none });
    try t.expectEqual(Editor.EncodingAction.save, editor.encoding_action);
    _ = try ui.window.end(.{});
    try ui.window.begin(100 * std.time.ns_per_ms);
    encodingDialog(&editor);
    handleEncodingKeyGui(&editor, .{ .code = .escape, .action = .down, .mod = .none });
    _ = editor.execAction("find_replace");
    handleModalText(&editor, "é");
    handleFindReplaceKeyGui(&editor, .{ .code = .enter, .action = .down, .mod = .none });
    try t.expectEqual(@as(usize, 4), editor.activeDoc().cursors.primary().offset);
    handleFindReplaceKeyGui(&editor, .{ .code = .tab, .action = .down, .mod = .none });
    handleFindReplaceKeyGui(&editor, .{ .code = .enter, .action = .down, .mod = .none });
    try t.expectEqualStrings("é😀", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    handleModalText(&editor, "界😀");
    handleFindReplaceKeyGui(&editor, .{ .code = .backspace, .action = .down, .mod = .none });
    try t.expectEqualStrings("界", editor.replace_buf[0..editor.replace_buf_len]);
    _ = try ui.window.end(.{});
    try ui.window.begin(200 * std.time.ns_per_ms);
    const area: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 900, .h = 600 };
    drawModalOverlay(&editor, area, .{ .r = area, .s = 1 }, 1);
}

test "GUI tools smoke: hover, rename, workspace preview and recovery dialogs" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var window_state: WinUi = .{ .win_id = 0 };
    win_ui = &window_state;
    defer win_ui = undefined;
    cur_win = 0;
    editor.lsp_tools.hover = try t.allocator.dupe(u8, "café: i32\nUnicode documentation 😀");
    editor.setMode(.lsp_panel);
    lspDialog(&editor);
    _ = try ui.window.end(.{});
    try ui.window.begin(100 * std.time.ns_per_ms);
    editor.setMode(.symbol_rename);
    @memcpy(editor.lsp_tools.name[0..5], "value");
    lspDialog(&editor);
    _ = try ui.window.end(.{});
    try ui.window.begin(200 * std.time.ns_per_ms);
    editor.setMode(.workspace_preview);
    editor.lsp_tools.preview = .{ .allocator = t.allocator };
    lspDialog(&editor);
    handleLspKeyGui(&editor, .{ .code = .escape, .action = .down, .mod = .none });
    try t.expect(editor.lsp_tools.preview == null);
    _ = try ui.window.end(.{});
    try ui.window.begin(300 * std.time.ns_per_ms);
    editor.setMode(.recovery_picker);
    recoveryDialog(&editor);
    handleRecoveryKeyGui(&editor, .{ .code = .escape, .action = .down, .mod = .none });
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    for ([_]@import("../core/tool_panel.zig").Kind{ .tasks, .task_output, .problems, .changes, .git_diff, .debug, .references, .review }, 0..) |kind, index| {
        _ = try ui.window.end(.{});
        try ui.window.begin(@intCast((400 + index * 100) * std.time.ns_per_ms));
        editor.tool_panel.show(&editor, kind);
        // Asynchronous list replacement must clamp a selection from a longer list.
        editor.tool_panel.selected = 1000;
        toolDialog(&editor);
        handleToolKeyGui(&editor, .{ .code = .escape, .action = .down, .mod = .none });
        try t.expectEqual(Editor.Mode.normal, editor.mode);
    }
}

test "GUI tool table: a click selects the row under the pointer" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 700 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var window_state: WinUi = .{ .win_id = 0 };
    win_ui = &window_state;
    defer win_ui = undefined;
    cur_win = 0;
    editor.lsp_enabled = false;
    editor.review.stage_on_approve = false;
    editor.git.root = try t.allocator.dupe(u8, root);
    const names = [_][]const u8{ "a.txt", "b.txt", "src/core/c.zig", "d.txt", "e.txt", "src/frontend/f.zig", "g.txt", "h.txt" };
    try tmp.dir.createDirPath(t.io, "src/core");
    try tmp.dir.createDirPath(t.io, "src/frontend");
    for (names, 0..) |name, index| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = "x\n" });
        try editor.git.changes.insert(editor.allocator, index, .{ .path = try editor.allocator.dupe(u8, name), .x = ' ', .y = 'M' });
    }
    editor.review.tick(&editor, 0);
    editor.tool_panel.show(&editor, .review);
    try t.expectEqual(names.len, editor.review.files.items.len);
    // Two verdicts, so the Verdict column has something to show.
    editor.review.verdict(&editor, 0, .approved);
    editor.review.verdict(&editor, 2, .needs_work);
    try t.expectEqual(review.Status.approved, editor.review.statusOf("a.txt"));
    // Frames until the table's row height and the window's size settle.
    var frame_ms: u64 = 100;
    for (0..4) |_| {
        toolDialog(&editor);
        _ = try ui.window.end(.{});
        frame_ms += 100;
        try ui.window.begin(@intCast(frame_ms * std.time.ns_per_ms));
    }
    const grid_rect = (dvui.tagGet("tool_grid") orelse return error.TagNotFound).rect;
    // Press down the table, a few pixels at a time, to the right of the
    // columns' text: every row must come up, top to bottom.
    var seen = [_]bool{false} ** names.len;
    var last: usize = 0;
    var y = grid_rect.y + 1;
    while (y < grid_rect.y + grid_rect.h) : (y += 5) {
        _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = grid_rect.x + grid_rect.w * 0.8, .y = y } });
        _ = try ui.window.addEventMouseButton(.left, .press);
        _ = try ui.window.addEventMouseButton(.left, .release);
        toolDialog(&editor);
        _ = try ui.window.end(.{});
        frame_ms += 100;
        try ui.window.begin(@intCast(frame_ms * std.time.ns_per_ms));
        const selected = editor.tool_panel.selected;
        try t.expect(selected >= last);
        last = selected;
        seen[selected] = true;
    }
    for (seen) |row_seen| try t.expect(row_seen);
    try t.expectEqual(Editor.Mode.tool_panel, editor.mode);
    // ZIDE_CAPTURE_DIR=<dir>: also save a picture of the dialog there
    // (tool_table.png), to look at the table without launching ZIDE.
    const Backend = @import("sdl-backend");
    const capture_dir = Backend.c.SDL_getenv("ZIDE_CAPTURE_DIR");
    if (capture_dir != null) {
        const path = try std.fs.path.join(t.allocator, &.{ std.mem.span(@as([*:0]const u8, capture_dir)), "tool_table.png" });
        defer t.allocator.free(path);
        // Row 1 selected, the pointer over row 3: both highlights in view.
        editor.tool_panel.select(&editor, 1);
        _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = grid_rect.x + grid_rect.w * 0.5, .y = grid_rect.y + 32 + 3.5 * 26 } });
        capture_editor = &editor;
        const file = try std.Io.Dir.cwd().createFile(dvui.io, path, .{});
        defer file.close(dvui.io);
        var wbuf: [4096]u8 = undefined;
        var writer = file.writer(dvui.io, &wbuf);
        try dvui.testing.capturePng(captureDialogFrame, null, &writer.interface);
        try writer.end();
    }
}

/// The editor whose tool dialog `captureDialogFrame` renders (tests only).
var capture_editor: *Editor = undefined;
fn captureDialogFrame() anyerror!dvui.App.Result {
    toolDialog(capture_editor);
    return .ok;
}

/// The GUI state `captureWindowFrame` renders `capture_editor` with (tests only).
var capture_gui: *GuiState = undefined;
fn captureWindowFrame() anyerror!dvui.App.Result {
    _ = frame(capture_editor, capture_gui);
    return .ok;
}

/// Tests only: three Zig snippets in two groups — rows Start here, Print,
/// Constant, Functions (closed) — the untitled document in Zig, LSP and
/// the file tree off, and the per-process GUI state a test before left.
fn snippetsTestSetup(editor: *Editor) !void {
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    _ = try editor.registerSnippet(.{ .language = "zig", .description = "Print", .group = "Start here", .notes = "Writes text to the terminal. Each {} in the text is filled by one value from the .{} list, in order.", .body = "std.debug.print(\"${1:text}\n\", .{${2:values}});" });
    _ = try editor.registerSnippet(.{ .language = "zig", .description = "Constant", .group = "Start here", .notes = "A value that never changes after it is set.\nThe type can be left out when Zig can tell it from the value.", .body = "const ${1:name}: ${2:i32} = ${3:0};" });
    _ = try editor.registerSnippet(.{ .language = "zig", .prefix = "fn", .description = "Function", .group = "Functions", .notes = "A named block of code you call with name(). Parameters go in the parentheses as name: type; void means it gives nothing back.", .body = "fn ${1:name}($2) ${3:void} {\n\t$0\n}" });
    editor.activeDoc().language = editor.findLanguage("zig");
    owner_seen = null;
    filetree_release_focus = false;
    filetree_band = .{};
    snippets_band = .{};
    snippets_hover_row = null;
    snippets_hover_pt = null;
    snippets_sb_drag = false;
    snippets_last_click_row = std.math.maxInt(usize);
    snippets_last_click_inserted = false;
    snippets_preview_def = null;
    snippets_preview_scroll = 0;
    snippets_preview_overflow = 0;
    snippets_pv_sb_drag = false;
    snippet_form_focus_pending = true;
    snippet_form_error_hash = null;
}

/// Tests only: draw one GUI frame, then begin the next (`ms` is the
/// test clock, 100 ms a frame).
fn snippetsTestFrame(window: *dvui.Window, editor: *Editor, g: *GuiState, ms: *u64) !void {
    _ = frame(editor, g);
    _ = try window.end(.{});
    ms.* += 100;
    try window.begin(@intCast(ms.* * std.time.ns_per_ms));
}

/// Tests only: the Snippets panel's geometry as last drawn.
fn snippetsTestMetrics(editor: *const Editor) !SnippetsMetrics {
    const area = snippets_band.rect orelse return error.TestUnexpectedResult;
    const scale = snippets_band.scale;
    return snippetsMetrics(area, scale, dvui.Font.theme(.body).lineHeight() * scale, editor.snippet_panel.rows.items.len);
}

/// Tests only: the middle of drawn row `row`, left of the scrollbar.
fn snippetsTestRowPoint(m: SnippetsMetrics, row: usize) dvui.Point.Physical {
    return .{ .x = m.area.x + m.area.w * 0.4, .y = m.rows_y + (@as(f32, @floatFromInt(row)) + 0.5) * m.line_height };
}

/// Tests only: a left click on drawn row `row`.
fn snippetsTestClick(window: *dvui.Window, m: SnippetsMetrics, row: usize) !void {
    _ = try window.addEventMouseMotion(.{ .pt = snippetsTestRowPoint(m, row) });
    _ = try window.addEventMouseButton(.left, .press);
    _ = try window.addEventMouseButton(.left, .release);
}

/// Tests only: the registry index of the snippet named `description`.
fn snippetsTestDef(editor: *const Editor, description: []const u8) !u32 {
    for (editor.snippets.items.items, 0..) |def, i| {
        if (std.mem.eql(u8, def.description, description)) return @intCast(i);
    }
    return error.TestUnexpectedResult;
}

test "GUI snippets panel: a click on a group opens it and the keys drive the list" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    editor.snippets_visible = true;
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const panel = &editor.snippet_panel;
    const doc = editor.activeDoc();
    try t.expectEqual(@as(usize, 4), panel.rows.items.len);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    // A click on the closed group opens and selects it, and the panel
    // takes the keyboard.
    try snippetsTestClick(ui.window, try snippetsTestMetrics(&editor), 3);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 5), panel.rows.items.len);
    try t.expectEqual(@as(usize, 3), panel.selected);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    // The second press of a double-click leaves it open.
    try snippetsTestClick(ui.window, try snippetsTestMetrics(&editor), 3);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 5), panel.rows.items.len);
    // Down onto its item; Left back to the group, Left again closes it.
    try dvui.testing.pressKey(.down, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 4), panel.selected);
    try dvui.testing.pressKey(.left, .none);
    try dvui.testing.pressKey(.left, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 4), panel.rows.items.len);
    try t.expectEqual(@as(usize, 3), panel.selected);
    // Typing filters the rows and never reaches the document: "con" leaves
    // Constant under its group, selected for Enter. Tab still does nothing.
    try dvui.testing.writeText("con");
    try dvui.testing.pressKey(.tab, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("con", panel.filterText());
    try t.expectEqual(@as(usize, 2), panel.rows.items.len);
    try t.expectEqual(snippet_panel.RowKind.group, panel.rows.items[0].kind);
    try t.expectEqual(try snippetsTestDef(&editor, "Constant"), panel.rows.items[1].def);
    try t.expectEqual(@as(usize, 1), panel.selected);
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    // Escape clears the filter and the panel keeps the keyboard: the rows
    // are back, Constant still selected. A second Escape hands the
    // keyboard back as before, and Ctrl+Alt+B gives it to the panel again.
    try dvui.testing.pressKey(.escape, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!panel.filterActive());
    try t.expectEqual(@as(usize, 4), panel.rows.items.len);
    try t.expectEqual(@as(usize, 2), panel.selected);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try dvui.testing.pressKey(.escape, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    const ctrl_alt: dvui.enums.Mod = @enumFromInt(@intFromEnum(dvui.enums.Mod.lcontrol) | @intFromEnum(dvui.enums.Mod.lalt));
    try dvui.testing.pressKey(.b, ctrl_alt);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    // Up (from Constant), Enter: Print goes in at the caret, its first
    // blank selected, and the editor has the keyboard.
    try dvui.testing.pressKey(.up, .none);
    try dvui.testing.pressKey(.enter, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("std.debug.print(\"text\n\", .{values});", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualStrings("text", doc.selectedText().?);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    // Ctrl+Alt+B focuses the shown panel, Escape hands the keyboard back,
    // and twice more hides it.
    try dvui.testing.pressKey(.b, ctrl_alt);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try dvui.testing.pressKey(.escape, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(editor.snippets_visible);
    try dvui.testing.pressKey(.b, ctrl_alt);
    try dvui.testing.pressKey(.b, ctrl_alt);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!editor.snippets_visible);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(snippets_band.rect == null);
}

test "GUI snippets panel: a click on an item inserts it and Tab walks its blanks" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    editor.snippets_visible = true;
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const doc = editor.activeDoc();
    // Right of the panes (opposite the tree): the pane takes dvui focus
    // back on the next frame.
    try t.expectEqual(Editor.FiletreeSide.right, editor.snippetsSide());
    try snippetsTestClick(ui.window, try snippetsTestMetrics(&editor), 1);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("std.debug.print(\"text\n\", .{values});", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualStrings("text", doc.selectedText().?);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(filetree_release_focus);
    try t.expectEqual(@as(usize, 1), editor.snippet_panel.selected);
    // The second press of a double-click (a frame later) inserts nothing
    // more, and the pane takes dvui focus back: Tab moves to the next blank.
    const before = doc.buffer.byteLen();
    try snippetsTestClick(ui.window, try snippetsTestMetrics(&editor), 1);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(before, doc.buffer.byteLen());
    try t.expect(!filetree_release_focus);
    try dvui.testing.pressKey(.tab, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("values", doc.selectedText().?);
    // Left of the panes the pane takes focus back in the click's own
    // frame, and must keep it past the end of that frame.
    try dvui.testing.pressKey(.escape, .none);
    editor.snippets_side = .left;
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(doc.snippet_session == null);
    try snippetsTestClick(ui.window, try snippetsTestMetrics(&editor), 2);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!filetree_release_focus);
    try t.expectEqualStrings("name", doc.selectedText().?);
    try dvui.testing.pressKey(.tab, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("i32", doc.selectedText().?);
}

test "GUI snippets panel: the preview follows the hovered item, then the keyboard" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    editor.snippets_visible = true;
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const print = try snippetsTestDef(&editor, "Print");
    const constant = try snippetsTestDef(&editor, "Constant");
    const m = try snippetsTestMetrics(&editor);
    try t.expect(m.preview.h > 0);
    // The selection is on a group and nothing is hovered: no preview.
    try t.expectEqual(@as(?u32, null), snippets_preview_def);
    _ = try ui.window.addEventMouseMotion(.{ .pt = snippetsTestRowPoint(m, 2) });
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(?usize, 2), snippets_hover_row);
    try t.expectEqual(@as(?u32, constant), snippets_preview_def);
    _ = try ui.window.addEventMouseMotion(.{ .pt = snippetsTestRowPoint(m, 1) });
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(?u32, print), snippets_preview_def);
    // Keyboard navigation clears the hover: the pointer stays over Print,
    // yet the selection (Constant) drives the preview.
    _ = editor.takeKeyboardFocus(.snippets);
    try dvui.testing.pressKey(.down, .none);
    try dvui.testing.pressKey(.down, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(?usize, null), snippets_hover_row);
    try t.expectEqual(@as(?u32, constant), snippets_preview_def);
    // A pointer that moves hovers again; one that leaves the panel does not.
    var p = snippetsTestRowPoint(m, 1);
    p.y += 1;
    _ = try ui.window.addEventMouseMotion(.{ .pt = p });
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(?u32, print), snippets_preview_def);
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = m.area.x - 50, .y = p.y } });
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(?usize, null), snippets_hover_row);
    try t.expectEqual(@as(?u32, constant), snippets_preview_def);

    // ZIDE_CAPTURE_DIR=<dir>: also save a picture of the window there
    // (snippets_panel.png): the Functions group open, the pointer on its
    // item, so the preview shows a multi-line skeleton and a trigger.
    const Backend = @import("sdl-backend");
    const capture_dir = Backend.c.SDL_getenv("ZIDE_CAPTURE_DIR");
    if (capture_dir != null) {
        try snippetsTestClick(ui.window, m, 3);
        try snippetsTestFrame(ui.window, &editor, &g, &ms);
        _ = try ui.window.addEventMouseMotion(.{ .pt = snippetsTestRowPoint(m, 4) });
        try snippetsTestFrame(ui.window, &editor, &g, &ms);
        try t.expectEqual(@as(?u32, try snippetsTestDef(&editor, "Function")), snippets_preview_def);
        const path = try std.fs.path.join(t.allocator, &.{ std.mem.span(@as([*:0]const u8, capture_dir)), "snippets_panel.png" });
        defer t.allocator.free(path);
        capture_editor = &editor;
        capture_gui = &g;
        const file = try std.Io.Dir.cwd().createFile(dvui.io, path, .{});
        defer file.close(dvui.io);
        var wbuf: [4096]u8 = undefined;
        var writer = file.writer(dvui.io, &wbuf);
        try dvui.testing.capturePng(captureWindowFrame, null, &writer.interface);
        try writer.end();
    }
}

test "GUI snippets panel: dragging the band edge resizes it, and a shared side keeps the tree outermost" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    editor.snippets_visible = true;
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    // Docked right, the editor-facing edge is the left one: drag it 60 px
    // further left (the init.lua write fails harmlessly in tests).
    var rect = snippets_band.rect orelse return error.TestUnexpectedResult;
    const scale = snippets_band.scale;
    const mid_y = rect.y + rect.h / 2;
    try t.expectApproxEqAbs(@as(f32, 260), rect.w / scale, 1);
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x, .y = mid_y } });
    _ = try ui.window.addEventMouseButton(.left, .press);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(snippets_band.resizing);
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x - 60 * scale, .y = mid_y } });
    _ = try ui.window.addEventMouseButton(.left, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!snippets_band.resizing);
    try t.expectApproxEqAbs(@as(f32, 320), editor.snippets_width, 1);
    rect = snippets_band.rect orelse return error.TestUnexpectedResult;
    try t.expectApproxEqAbs(@as(f32, 320), rect.w / scale, 1);
    // Docked left, it is the right edge: 40 px wider.
    editor.snippets_side = .left;
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    rect = snippets_band.rect orelse return error.TestUnexpectedResult;
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x + rect.w, .y = mid_y } });
    _ = try ui.window.addEventMouseButton(.left, .press);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x + rect.w + 40 * scale, .y = mid_y } });
    _ = try ui.window.addEventMouseButton(.left, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectApproxEqAbs(@as(f32, 360), editor.snippets_width, 1);
    // With the file tree on the same side, the tree is the outer band.
    editor.filetree_git_colors = false;
    try t.expect(editor.setFiletreeRoot(root));
    editor.filetree_auto_reveal = false;
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    var tree = filetree_band.rect orelse return error.TestUnexpectedResult;
    rect = snippets_band.rect orelse return error.TestUnexpectedResult;
    try t.expect(tree.x + tree.w <= rect.x + 1);
    editor.filetree_side = .right;
    editor.snippets_side = .right;
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    tree = filetree_band.rect orelse return error.TestUnexpectedResult;
    rect = snippets_band.rect orelse return error.TestUnexpectedResult;
    try t.expect(rect.x + rect.w <= tree.x + 1);
    // Too narrow for both bands and 240 px of editor: the Snippets panel
    // hides itself, says so, and its keyboard goes back to the pane.
    editor.filetree_width = 600;
    _ = editor.takeKeyboardFocus(.snippets);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(snippets_band.rect == null);
    try t.expect(!editor.snippets_visible and !editor.snippets_focused);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "no room") != null);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
}

test "GUI terminal panel: a strip at the bottom or a column at a side, a click focuses it, its edge resizes and hides it" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.keybinds.loadDefaults();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    terminal_panel_band = .{};
    var ms: u64 = 0;
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(terminal_panel_band.rect == null);

    // A docked slot (fake: no shell) at the default edge, the bottom:
    // terminal_panel_height tall, the full width of the pane area.
    try editor.terminals.append(t.allocator, null);
    editor.terminal_panel = 0;
    try t.expect(editor.takeKeyboardFocus(.terminal_panel));
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    var rect = terminal_panel_band.rect orelse return error.TestUnexpectedResult;
    const scale = terminal_panel_band.scale;
    try t.expectApproxEqAbs(@as(f32, 240), rect.h / scale, 1);
    try t.expect(rect.w / scale > 800);
    try t.expect(rect.y / scale > 200);
    try t.expectEqual(Editor.KeyboardOwner.terminal_panel, editor.keyboardOwner());

    // Ctrl+` goes back to the editor (the panel stays); a click on the
    // band gives it the keyboard again.
    try dvui.testing.pressKey(.grave, .lcontrol);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(editor.terminal_panel_visible);
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 } });
    _ = try ui.window.addEventMouseButton(.left, .press);
    _ = try ui.window.addEventMouseButton(.left, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.terminal_panel, editor.keyboardOwner());

    // Dragging its top edge 20 px up makes it 260 tall (the init.lua
    // write fails harmlessly in tests; the band never takes more than
    // half the pane area, so a bigger drag would be capped on screen).
    const mid_x = rect.x + rect.w / 2;
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = mid_x, .y = rect.y } });
    _ = try ui.window.addEventMouseButton(.left, .press);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(terminal_panel_band.resizing);
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = mid_x, .y = rect.y - 20 * scale } });
    _ = try ui.window.addEventMouseButton(.left, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!terminal_panel_band.resizing);
    try t.expectApproxEqAbs(@as(f32, 260), editor.terminal_panel_height, 1);
    rect = terminal_panel_band.rect orelse return error.TestUnexpectedResult;
    try t.expectApproxEqAbs(@as(f32, 260), rect.h / scale, 1);

    // On the right: terminal_panel_width wide at the window's right edge,
    // full height; on the left, at the left edge.
    try t.expect(editor.execAction("move_terminal_panel_right"));
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    rect = terminal_panel_band.rect orelse return error.TestUnexpectedResult;
    try t.expectApproxEqAbs(@as(f32, 420), rect.w / scale, 1);
    try t.expect(rect.h / scale > 400);
    try t.expectApproxEqAbs(@as(f32, 900), (rect.x + rect.w) / scale, 2);
    try t.expect(editor.execAction("move_terminal_panel_left"));
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    rect = terminal_panel_band.rect orelse return error.TestUnexpectedResult;
    try t.expectApproxEqAbs(@as(f32, 0), rect.x / scale, 2);
    // Beside the tree on the same side, the tree stays outermost.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    editor.filetree_git_colors = false;
    try t.expect(editor.setFiletreeRoot(root));
    editor.filetree_auto_reveal = false;
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const tree = filetree_band.rect orelse return error.TestUnexpectedResult;
    rect = terminal_panel_band.rect orelse return error.TestUnexpectedResult;
    try t.expect(tree.x + tree.w <= rect.x + 1);
    editor.filetree_visible = false;

    // Back at the bottom, dragging the edge well past the minimum hides
    // the panel on release: the height is kept, the shell stays docked,
    // the keyboard goes back to the pane, and the toggle shows it again.
    try t.expect(editor.execAction("move_terminal_panel_bottom"));
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    rect = terminal_panel_band.rect orelse return error.TestUnexpectedResult;
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = mid_x, .y = rect.y } });
    _ = try ui.window.addEventMouseButton(.left, .press);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = mid_x, .y = rect.y + rect.h - 10 * scale } });
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(terminal_panel_band.hide_pending);
    try t.expectEqualStrings("Release to hide the terminal panel", editor.status_message);
    _ = try ui.window.addEventMouseButton(.left, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!editor.terminal_panel_visible);
    try t.expect(terminal_panel_band.rect == null);
    try t.expectApproxEqAbs(@as(f32, 260), editor.terminal_panel_height, 1);
    try t.expectEqual(@as(?usize, 0), editor.terminal_panel);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(std.mem.indexOf(u8, editor.status_message, "Ctrl+Shift+`") != null);
    const ctrl_shift: dvui.enums.Mod = @enumFromInt(@intFromEnum(dvui.enums.Mod.lcontrol) | @intFromEnum(dvui.enums.Mod.lshift));
    try dvui.testing.pressKey(.grave, ctrl_shift);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(editor.terminal_panel_visible);
    try t.expect(terminal_panel_band.rect != null);
    try t.expectEqual(Editor.KeyboardOwner.terminal_panel, editor.keyboardOwner());
    try t.expectEqual(@as(usize, 1), editor.terminals.items.len);
}

test "GUI snippets panel: snippets_double_click — a click selects, a double-click inserts once" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    editor.snippets_visible = true;
    editor.snippets_double_click = true;
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const doc = editor.activeDoc();
    const print = try snippetsTestDef(&editor, "Print");
    const inserted = "std.debug.print(\"text\n\", .{values});";
    // One click: Print is selected and previewed, nothing is inserted,
    // and the panel has the keyboard, so the arrows work right away.
    try snippetsTestClick(ui.window, try snippetsTestMetrics(&editor), 1);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    try t.expectEqual(@as(usize, 1), editor.snippet_panel.selected);
    try t.expectEqual(@as(?u32, print), snippets_preview_def);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    // The second press of a double-click inserts it and the editor gets
    // the keyboard; a third press right after inserts nothing more and
    // leaves the keyboard there.
    try snippetsTestClick(ui.window, try snippetsTestMetrics(&editor), 1);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings(inserted, doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualStrings("text", doc.selectedText().?);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try snippetsTestClick(ui.window, try snippetsTestMetrics(&editor), 1);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings(inserted, doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    // Well after the double-click a click is a plain select again (the
    // frame after the clock jump is when the window sees the new time).
    ms += 1000;
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try snippetsTestClick(ui.window, try snippetsTestMetrics(&editor), 2);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings(inserted, doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqual(@as(usize, 2), editor.snippet_panel.selected);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    // Enter still inserts from the keyboard.
    try dvui.testing.pressKey(.enter, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(std.mem.indexOf(u8, doc.buffer.slice(0, doc.buffer.byteLen()), "const name: i32 = 0;") != null);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
}

test "GUI snippets panel: a short list leaves the preview its free space, and long notes scroll" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    // A fourth Start-here item whose notes run far past the block.
    _ = try editor.registerSnippet(.{ .language = "zig", .description = "Long", .group = "Start here", .notes = "Long notes, longer than the preview block can show at once. " ** 40, .body = "const value = some_function(argument_one, argument_two, argument_three, argument_four, ${1:argument_five});\nx" });
    editor.snippets_visible = true;
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const print = try snippetsTestDef(&editor, "Print");
    const long = try snippetsTestDef(&editor, "Long");
    const m = try snippetsTestMetrics(&editor);
    // Five rows: every row fits, and the preview gets more than its 40%.
    try t.expectEqual(@as(usize, 5), editor.snippet_panel.rows.items.len);
    try t.expect(m.rows_h >= 5 * m.line_height);
    try t.expect(m.preview.h > m.area.h * 0.5);
    // Long selected from the keyboard, the pointer resting over the
    // preview (nothing hovered): its notes do not fit.
    _ = editor.takeKeyboardFocus(.snippets);
    editor.snippet_panel.selected = 3;
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = m.preview.x + m.preview.w * 0.4, .y = m.preview.y + m.preview.h / 2 } });
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(?usize, null), snippets_hover_row);
    try t.expectEqual(@as(?u32, long), snippets_preview_def);
    try t.expect(snippets_preview_overflow > 0);
    try t.expectEqual(@as(f32, 0), snippets_preview_scroll);
    // Its 100-column line soft-wraps to several rows, like the notes.
    try t.expect(snippets_preview_code_rows >= 3);
    // ZIDE_CAPTURE_DIR=<dir>: save a picture of the wrapped code in its
    // box, the overflowing notes and the preview's scrollbar there
    // (snippets_preview.png).
    const Backend = @import("sdl-backend");
    const capture_dir = Backend.c.SDL_getenv("ZIDE_CAPTURE_DIR");
    if (capture_dir != null) {
        const path = try std.fs.path.join(t.allocator, &.{ std.mem.span(@as([*:0]const u8, capture_dir)), "snippets_preview.png" });
        defer t.allocator.free(path);
        capture_editor = &editor;
        capture_gui = &g;
        const file = try std.Io.Dir.cwd().createFile(dvui.io, path, .{});
        defer file.close(dvui.io);
        var wbuf: [4096]u8 = undefined;
        var writer = file.writer(dvui.io, &wbuf);
        try dvui.testing.capturePng(captureWindowFrame, null, &writer.interface);
        try writer.end();
    }
    // Three wheel notches down over the preview scroll it, not the list;
    // far past the end it stops at the end.
    _ = try ui.window.addEventMouseWheel(-3 * dvui.scroll_speed, .vertical, null);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectApproxEqAbs(9 * m.line_height, snippets_preview_scroll, 0.5);
    try t.expectEqual(@as(usize, 0), editor.snippet_panel.scroll);
    _ = try ui.window.addEventMouseWheel(-100 * dvui.scroll_speed, .vertical, null);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectApproxEqAbs(snippets_preview_overflow, snippets_preview_scroll, 0.5);
    try t.expect(snippets_preview_scroll > 9 * m.line_height);
    // Another item previewed starts at its top.
    _ = try ui.window.addEventMouseMotion(.{ .pt = snippetsTestRowPoint(m, 1) });
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(?u32, print), snippets_preview_def);
    try t.expectEqual(@as(f32, 0), snippets_preview_scroll);
}

test "GUI snippets panel: dragging a band's edge far past its minimum hides it and keeps its width" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    editor.snippets_visible = true;
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    // Docked right: its left edge dragged to 30 px from its right edge.
    // The band stays at its minimum, and the status bar says what the
    // release will do.
    var rect = snippets_band.rect orelse return error.TestUnexpectedResult;
    const scale = snippets_band.scale;
    const mid_y = rect.y + rect.h / 2;
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x, .y = mid_y } });
    _ = try ui.window.addEventMouseButton(.left, .press);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x + rect.w - 30 * scale, .y = mid_y } });
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(snippets_band.resizing and snippets_band.hide_pending);
    try t.expectApproxEqAbs(@as(f32, 120), editor.snippets_width, 1);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "Release to hide") != null);
    _ = try ui.window.addEventMouseButton(.left, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!editor.snippets_visible);
    try t.expect(snippets_band.rect == null);
    try t.expectApproxEqAbs(@as(f32, 260), editor.snippets_width, 1);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "Snippets panel hidden") != null);
    // Ctrl+Alt+B brings it back at its old width.
    const ctrl_alt: dvui.enums.Mod = @enumFromInt(@intFromEnum(dvui.enums.Mod.lcontrol) | @intFromEnum(dvui.enums.Mod.lalt));
    try dvui.testing.pressKey(.b, ctrl_alt);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    rect = snippets_band.rect orelse return error.TestUnexpectedResult;
    try t.expectApproxEqAbs(@as(f32, 260), rect.w / scale, 1);
    // The file tree (docked left) hides the same way, by its right edge,
    // and keeps its width too.
    editor.filetree_git_colors = false;
    editor.filetree_auto_reveal = false;
    try t.expect(editor.setFiletreeRoot(root));
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const tree = filetree_band.rect orelse return error.TestUnexpectedResult;
    const tree_w = editor.filetree_width;
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = tree.x + tree.w, .y = mid_y } });
    _ = try ui.window.addEventMouseButton(.left, .press);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(filetree_band.resizing);
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = tree.x + 10 * scale, .y = mid_y } });
    _ = try ui.window.addEventMouseButton(.left, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!editor.filetree_visible);
    try t.expect(filetree_band.rect == null);
    try t.expectEqual(tree_w, editor.filetree_width);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "File tree hidden") != null);
    try t.expect(editor.snippets_visible);
}

/// Tests only: with ZIDE_CAPTURE_DIR set, save the next frame of the
/// window there as `name` (that frame runs like snippetsTestFrame's).
fn snippetFormTestCapture(editor: *Editor, g: *GuiState, ms: *u64, name: []const u8) !void {
    const Backend = @import("sdl-backend");
    const capture_dir = Backend.c.SDL_getenv("ZIDE_CAPTURE_DIR");
    if (capture_dir == null) return;
    const path = try std.fs.path.join(std.testing.allocator, &.{ std.mem.span(@as([*:0]const u8, capture_dir)), name });
    defer std.testing.allocator.free(path);
    capture_editor = editor;
    capture_gui = g;
    const file = try std.Io.Dir.cwd().createFile(dvui.io, path, .{});
    defer file.close(dvui.io);
    var wbuf: [4096]u8 = undefined;
    var writer = file.writer(dvui.io, &wbuf);
    try dvui.testing.capturePng(captureWindowFrame, null, &writer.interface);
    try writer.end();
    ms.* += 100; // the capture's frame moved the window clock on
}

test "GUI snippet form: Ctrl+Alt+S opens the dialog prefilled from the selection, Enter in Name saves, the panel shows the new snippet" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    lua_settings.test_config_dir = root;
    defer lua_settings.test_config_dir = null;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    editor.snippets_visible = true;
    const doc = editor.activeDoc();
    const source = "    for (items) |item| {\n        use(item);\n    }\n";
    try doc.loadText(source);
    _ = editor.execCommand("select_all", null);
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    // Ctrl+Alt+S: the dialog opens prefilled — the selection dedented, the
    // document's language, the default folder — with the caret in Name.
    const ctrl_alt: dvui.enums.Mod = @enumFromInt(@intFromEnum(dvui.enums.Mod.lcontrol) | @intFromEnum(dvui.enums.Mod.lalt));
    try dvui.testing.pressKey(.s, ctrl_alt);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    const form = &editor.snippet_form;
    try t.expectEqualStrings("for (items) |item| {\n    use(item);\n}", form.text(.body));
    try t.expectEqualStrings("zig", form.text(.language));
    try t.expectEqualStrings("Mine", form.text(.folder));
    try dvui.testing.expectVisible("snippet_form_body");
    try dvui.testing.expectVisible("snippet_form_save");
    try dvui.testing.expectFocused("snippet_form_name");
    // Typing goes into Name, never into the document behind the dialog.
    try dvui.testing.writeText("My loop");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("My loop", form.text(.name));
    try t.expectEqualStrings(source, doc.buffer.slice(0, doc.buffer.byteLen()));
    // Tab moves on to Folder and Shift+Tab back: dvui's own focus order,
    // which the pane behind the dialog leaves alone.
    try dvui.testing.pressKey(.tab, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try dvui.testing.expectFocused("snippet_form_folder");
    try dvui.testing.pressKey(.tab, .lshift);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try dvui.testing.expectFocused("snippet_form_name");
    try t.expectEqualStrings(source, doc.buffer.slice(0, doc.buffer.byteLen()));
    // ZIDE_CAPTURE_DIR=<dir>: a picture of the open dialog there
    // (snippet_form.png), to look at it without launching ZIDE.
    try snippetFormTestCapture(&editor, &g, &ms, "snippet_form.png");
    // Enter in Name saves: the file, the registry and the status bar ...
    try dvui.testing.pressKey(.enter, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.startsWith(u8, editor.status_message, "Saved to my-snippets.lua"));
    const def = editor.snippets.command("snippet.zig.~my-loop") orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("Mine", def.group);
    try t.expectEqualStrings("for (items) |item| {\n    use(item);\n}", def.body);
    const text = try tmp.dir.readFileAlloc(t.io, "extensions/" ++ snippet_file.file_name, t.allocator, .limited(1 << 20));
    defer t.allocator.free(text);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, snippet_file.marker_prefix ++ "snippet.zig.~my-loop"));
    // Reopened on the very next frame (no first frame for dvui, so no
    // focus of its own): empty again, the folder remembered, and the caret
    // in Name. Escape closes it.
    try dvui.testing.pressKey(.s, ctrl_alt);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    try t.expectEqualStrings("", form.text(.name));
    try t.expectEqualStrings("Mine", form.text(.folder));
    try dvui.testing.expectFocused("snippet_form_name");
    try dvui.testing.pressKey(.escape, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    // ... and the panel selects and previews the new snippet.
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(?u32, try snippetsTestDef(&editor, "My loop")), snippets_preview_def);
    // The dialog is gone and the editor pane has the keyboard back: Right
    // ends the selection, the typing lands in the document.
    try t.expect(dvui.tagGet("snippet_form_name") == null);
    try dvui.testing.pressKey(.right, .none);
    try dvui.testing.writeText("x");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings(source ++ "x", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "GUI snippet form: refusals without a selection or in a terminal pane, Escape cancels without writing, the dialog stays in its window" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    lua_settings.test_config_dir = root;
    defer lua_settings.test_config_dir = null;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    const source = "const answer = 42;\n";
    try editor.activeDoc().loadText(source);
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const ctrl_alt: dvui.enums.Mod = @enumFromInt(@intFromEnum(dvui.enums.Mod.lcontrol) | @intFromEnum(dvui.enums.Mod.lalt));
    const my_snippets = "extensions/" ++ snippet_file.file_name;
    // Nothing selected: refused in the status bar, and no dialog.
    try dvui.testing.pressKey(.s, ctrl_alt);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "select the code") != null);
    try t.expect(dvui.tagGet("snippet_form_name") == null);
    // A terminal pane: its chords go to the shell, so the way there is the
    // Edit menu's item (the command) — refused too.
    _ = editor.execCommand("select_all", null);
    try editor.terminals.append(t.allocator, null); // fake slot: no shell
    editor.windows.items[0].layout.panes.items[0].content = .{ .terminal = 0 };
    _ = editor.execCommand("snippet_save_selection", null);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "editor pane") != null);
    editor.windows.items[0].layout.panes.items[0].content = .{ .editor = 0 };

    // With the selection the dialog opens. Enter with no name: the save
    // fails, the dialog stays and says why, its buttons still in view.
    try dvui.testing.pressKey(.s, ctrl_alt);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    try dvui.testing.expectFocused("snippet_form_name");
    try dvui.testing.pressKey(.enter, .none);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    try t.expect(editor.snippet_form.error_message.len > 0);
    try dvui.testing.expectVisible("snippet_form_error");
    try dvui.testing.expectVisible("snippet_form_save");
    try dvui.testing.expectFocused("snippet_form_name");
    // ZIDE_CAPTURE_DIR=<dir>: the dialog with its error (snippet_form_error.png).
    try snippetFormTestCapture(&editor, &g, &ms, "snippet_form_error.png");
    // A long message wraps beside the buttons instead of widening the
    // dialog: Save stays where it was.
    const save_x = (try dvui.testing.tagGet("snippet_form_save")).rect.x;
    editor.snippet_form.error_message = "my-snippets.lua has a damaged block for this snippet (no `-- zide:end` line): fix the file by hand";
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(save_x, (try dvui.testing.tagGet("snippet_form_save")).rect.x);
    const line_h = dvui.Font.theme(.body).lineHeight() * dvui.windowNaturalScale();
    try t.expect((try dvui.testing.tagGet("snippet_form_error")).rect.h >= 2 * line_h);
    try dvui.testing.expectVisible("snippet_form_save");
    // Escape from inside Name: back to normal, nothing written, the form
    // empty again, and the editor pane has the keyboard back.
    try dvui.testing.writeText("Never saved");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("Never saved", editor.snippet_form.text(.name));
    try dvui.testing.pressKey(.escape, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqualStrings("", editor.snippet_form.text(.name));
    try t.expectEqualStrings("", editor.snippet_form.error_message);
    try t.expect(editor.snippets.command("snippet.zig.~never-saved") == null);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, my_snippets, .{}));
    try dvui.testing.pressKey(.right, .none);
    try dvui.testing.writeText("y");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings(source ++ "y", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    // The Cancel button leaves it the same way.
    _ = editor.execCommand("select_all", null);
    try dvui.testing.pressKey(.s, ctrl_alt);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    try dvui.testing.moveTo("snippet_form_cancel");
    try dvui.testing.click(.left);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);

    // Pinned to its window: other windows read the mode as normal. (No
    // frame runs while there are two: that would open a real OS window.)
    _ = editor.execCommand("select_all", null);
    try dvui.testing.pressKey(.s, ctrl_alt);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try dvui.testing.writeText("Kept");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    editor.multi_window_supported = true;
    const second = try editor.newWindow(.{ .editor = editor.active_doc_idx });
    defer cur_win = 0;
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    cur_win = second;
    try t.expectEqual(Editor.Mode.normal, guiMode(&editor));
    cur_win = 0;
    try t.expectEqual(Editor.Mode.snippet_form, guiMode(&editor));
    // Opened from the second window, it is that window's; when that window
    // closes, the primary takes the dialog over with what was typed.
    editor.snippet_form.window_id = editor.windows.items[second].id;
    try t.expectEqual(Editor.Mode.normal, guiMode(&editor));
    cur_win = second;
    try t.expectEqual(Editor.Mode.snippet_form, guiMode(&editor));
    cur_win = 0;
    try t.expect(editor.closeWindow(second));
    try t.expectEqual(Editor.Mode.snippet_form, guiMode(&editor));
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try dvui.testing.expectVisible("snippet_form_name");
    try t.expectEqualStrings("Kept", editor.snippet_form.text(.name));
    try dvui.testing.pressKey(.escape, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, my_snippets, .{}));
}

test "GUI snippets panel: typing filters the rows, Backspace edits the filter, Escape clears it before releasing the keyboard" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    editor.snippets_visible = true;
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const panel = &editor.snippet_panel;
    const doc = editor.activeDoc();
    const function = try snippetsTestDef(&editor, "Function");
    // The filter box has its own row, between the header and the rows.
    const m = try snippetsTestMetrics(&editor);
    try t.expect(m.filter.w > 0 and m.filter.h > 0);
    try t.expect(m.filter.y >= m.area.y + m.header_h);
    try t.expect(m.filter.y + m.filter.h <= m.rows_y);
    try t.expectEqual(@as(usize, 4), panel.rows.items.len);
    // Ctrl+Alt+B gives the panel the keyboard; "fun" leaves the Functions
    // group, open, on its item, which is selected and previewed.
    const ctrl_alt: dvui.enums.Mod = @enumFromInt(@intFromEnum(dvui.enums.Mod.lcontrol) | @intFromEnum(dvui.enums.Mod.lalt));
    try dvui.testing.pressKey(.b, ctrl_alt);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try dvui.testing.writeText("fun");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("fun", panel.filterText());
    try t.expectEqual(@as(usize, 2), panel.rows.items.len);
    try t.expectEqual(snippet_panel.RowKind.group, panel.rows.items[0].kind);
    try t.expectEqualStrings("Functions", panel.groups.items[panel.rows.items[0].group].name);
    try t.expectEqual(function, panel.rows.items[1].def);
    try t.expectEqual(@as(usize, 1), panel.selected);
    try t.expectEqual(@as(?u32, function), snippets_preview_def);
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    // ZIDE_CAPTURE_DIR=<dir>: a picture of the filtered panel there
    // (snippets_filter.png).
    try snippetFormTestCapture(&editor, &g, &ms, "snippets_filter.png");
    // Three Backspaces edit the filter away: every row is back, the
    // Functions group closed again.
    for (0..3) |_| try dvui.testing.pressKey(.backspace, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!panel.filterActive());
    try t.expectEqual(@as(usize, 4), panel.rows.items.len);
    // Nothing matches "zzz": no rows, and the hint says what brings them back.
    try dvui.testing.writeText("zzz");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 0), panel.rows.items.len);
    try t.expect(std.mem.indexOf(u8, panel.emptyHint(), "Backspace") != null);
    try t.expectEqual(@as(?u32, null), snippets_preview_def);
    // Escape clears the filter and the panel keeps the keyboard; a second
    // Escape hands it back to the editor, whose typing then goes to the
    // document, not to the filter.
    try dvui.testing.pressKey(.escape, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!panel.filterActive());
    try t.expectEqual(@as(usize, 4), panel.rows.items.len);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try dvui.testing.pressKey(.escape, .none);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try dvui.testing.writeText("x");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("x", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(!panel.filterActive());
    try t.expectEqual(@as(usize, 4), panel.rows.items.len);
}

test "GUI snippets panel: a right-click selects the row, F2 edits a mine snippet, Delete asks first" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    lua_settings.test_config_dir = root;
    defer lua_settings.test_config_dir = null;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    // One snippet of my own beside the three bundled-style ones, registered
    // as loading my-snippets.lua registers it, with its block in the file.
    const spec: snippets_mod.Spec = .{ .language = "zig", .description = "My loop", .group = "Start here", .notes = "Mine.", .body = "for (${1:items}) |item| {\n\t$0\n}" };
    editor.loading_extensions = true;
    editor.loading_extension_name = snippet_file.file_name;
    const registered = editor.registerSnippet(spec);
    editor.loading_extensions = false;
    editor.loading_extension_name = null;
    // A copy: the registry frees its own with the snippet.
    const command = try t.allocator.dupe(u8, try registered);
    defer t.allocator.free(command);
    {
        const block = try snippet_file.renderBlock(t.allocator, command, spec);
        defer t.allocator.free(block);
        const text = try snippet_file.upsert(t.allocator, "", command, block);
        defer t.allocator.free(text);
        var path_buf: [512]u8 = undefined;
        const path = Editor.mySnippetsPath(&path_buf) orelse return error.TestUnexpectedResult;
        try snippet_file.write(t.allocator, t.io, path, text);
    }
    editor.snippets_visible = true;
    var ms: u64 = 0;
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    const panel = &editor.snippet_panel;
    const doc = editor.activeDoc();
    // Rows: Start here, Print, Constant, My loop, Functions.
    const mine = try snippetsTestDef(&editor, "My loop");
    try t.expectEqual(@as(usize, 5), panel.rows.items.len);
    try t.expectEqual(mine, panel.rows.items[3].def);
    try t.expect(snippet_file.isMine(&editor.snippets.items.items[mine]));
    try t.expect(!snippet_file.isMine(&editor.snippets.items.items[try snippetsTestDef(&editor, "Constant")]));
    const m = try snippetsTestMetrics(&editor);

    // A right-click on My loop selects it (inserting nothing) and gives the
    // panel the keyboard; its menu offers Edit and Delete, not Copy.
    _ = try ui.window.addEventMouseMotion(.{ .pt = snippetsTestRowPoint(m, 3) });
    _ = try ui.window.addEventMouseButton(.right, .press);
    _ = try ui.window.addEventMouseButton(.right, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 3), panel.selected);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    try dvui.testing.expectVisible("snippets_menu_edit");
    try dvui.testing.expectVisible("snippets_menu_delete");
    try t.expect(dvui.tagGet("snippets_menu_copy") == null);
    // F2 opens it for editing, prefilled (the menu closes under the
    // dialog); Escape, which the dialog catches, leaves it.
    try dvui.testing.pressKey(.f2, .none);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    try t.expectEqual(snippet_form_mod.Kind.edit, editor.snippet_form.kind);
    try t.expectEqualStrings("My loop", editor.snippet_form.text(.name));
    try t.expect(dvui.tagGet("snippets_menu_edit") == null);
    try dvui.testing.pressKey(.escape, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    // F2 on a bundled snippet offers to copy it to my snippets.
    try dvui.testing.pressKey(.up, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 2), panel.selected);
    try dvui.testing.pressKey(.f2, .none);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    try t.expectEqual(snippet_form_mod.Kind.copy, editor.snippet_form.kind);
    try t.expectEqualStrings("Constant", editor.snippet_form.text(.name));
    try dvui.testing.pressKey(.escape, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);

    // Delete on My loop asks first. n cancels, with its text event (a real
    // key types one), and that letter must not land in the filter: the
    // panel keeps the keyboard throughout.
    try dvui.testing.pressKey(.down, .none);
    try dvui.testing.pressKey(.delete, .none);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_delete_confirm, editor.mode);
    try dvui.testing.expectVisible("snippet_delete_button");
    // ZIDE_CAPTURE_DIR=<dir>: the question there (snippet_delete.png).
    try snippetFormTestCapture(&editor, &g, &ms, "snippet_delete.png");
    try dvui.testing.pressKey(.n, .none);
    try dvui.testing.writeText("n");
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.snippets.command(command) != null);
    try t.expect(!panel.filterActive());
    try t.expect(dvui.tagGet("snippet_delete_button") == null);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    // The dialog's Cancel button cancels too, and the snippet stays.
    try dvui.testing.pressKey(.delete, .none);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_delete_confirm, editor.mode);
    try dvui.testing.moveTo("snippet_delete_cancel");
    try dvui.testing.click(.left);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.snippets.command(command) != null);
    // From the menu this time, and y deletes it: the block leaves the file,
    // the snippet the registry, and its row the panel.
    _ = try ui.window.addEventMouseMotion(.{ .pt = snippetsTestRowPoint(m, 3) });
    _ = try ui.window.addEventMouseButton(.right, .press);
    _ = try ui.window.addEventMouseButton(.right, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 3), panel.selected);
    try dvui.testing.moveTo("snippets_menu_delete");
    try dvui.testing.click(.left);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.snippet_delete_confirm, editor.mode);
    try dvui.testing.expectVisible("snippet_delete_button");
    try dvui.testing.pressKey(.y, .none);
    try dvui.testing.writeText("y");
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.snippets.command(command) == null);
    try t.expectEqualStrings("Deleted from my-snippets.lua: My loop", editor.status_message);
    try t.expectEqual(@as(usize, 4), panel.rows.items.len);
    try t.expect(!panel.filterActive());
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    {
        const text = try tmp.dir.readFileAlloc(t.io, "extensions/" ++ snippet_file.file_name, t.allocator, .limited(1 << 20));
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, command) == null);
    }
    // Delete on a bundled snippet is refused in the status bar: no question.
    try dvui.testing.pressKey(.up, .none);
    try dvui.testing.pressKey(.delete, .none);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 2), panel.selected);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "Only snippets in my-snippets.lua") != null);
    try t.expect(dvui.tagGet("snippet_delete_button") == null);
}

const SheetIcon = struct { name: []const u8, tvg: []const u8 };
/// The icons `iconSheetFrame` lays out (tests only).
var sheet_icons: []const SheetIcon = &.{};
fn iconSheetFrame() anyerror!dvui.App.Result {
    const cols: usize = 9;
    const cell_w: f32 = 108;
    const cell_h: f32 = 54;
    const small = dvui.themeGet().font_body.withSize(10);
    for (sheet_icons, 0..) |ic, i| {
        const x = 8 + @as(f32, @floatFromInt(i % cols)) * cell_w;
        const y = 8 + @as(f32, @floatFromInt(i / cols)) * cell_h;
        dvui.icon(@src(), ic.name, ic.tvg, .{}, .{ .id_extra = i, .rect = .{ .x = x + 42, .y = y, .w = 24, .h = 24 }, .min_size_content = .{ .w = 24, .h = 24 }, .color_text = .{ .r = 0, .g = 0, .b = 0, .a = 255 } });
        dvui.labelNoFmt(@src(), ic.name, .{}, .{ .id_extra = i, .rect = .{ .x = x, .y = y + 26, .w = cell_w, .h = 18 }, .font = small, .padding = .{}, .color_text = .{ .r = 0, .g = 0, .b = 0, .a = 255 } });
    }
    return .ok;
}

/// Converts every SVG in `folder` (tests only), skipping and reporting the
/// ones that do not convert: a pack icon ZIDE never uses may not, and the
/// icons ZIDE uses are checked by the icons module's own test.
fn loadSheetIcons(io: std.Io, arena: std.mem.Allocator, folder: []const u8, out: *std.ArrayList(SheetIcon)) !void {
    // A folder that is not there (a pack that was tried and removed) is
    // simply an empty sheet.
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".svg")) continue;
        const svg = try dir.readFileAlloc(io, entry.name, arena, .limited(64 * 1024));
        const tvg = dvui.svgToTvg(arena, svg) catch |err| {
            std.debug.print("icon {s}/{s} does not convert: {s}\n", .{ folder, entry.name, @errorName(err) });
            continue;
        };
        const stem = entry.name[0 .. entry.name.len - ".svg".len];
        try out.append(arena, .{ .name = try arena.dupe(u8, stem), .tvg = tvg });
    }
    std.mem.sort(SheetIcon, out.items, {}, struct {
        fn lessThan(_: void, a: SheetIcon, b: SheetIcon) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
}

/// Saves `list` as contact sheets `<prefix>_<page>.png` in `capture_dir`
/// (tests only; one page holds what `iconSheetFrame` lays out).
fn captureSheets(allocator: std.mem.Allocator, capture_dir: []const u8, list: []const SheetIcon, prefix: []const u8) !void {
    const per_page: usize = 9 * 19;
    var start: usize = 0;
    var page: usize = 1;
    while (start < list.len) : (page += 1) {
        const end = @min(start + per_page, list.len);
        sheet_icons = list[start..end];
        var name_buf: [64]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&name_buf, "{s}_{d}.png", .{ prefix, page });
        const path = try std.fs.path.join(allocator, &.{ capture_dir, file_name });
        defer allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(dvui.io, path, .{});
        defer file.close(dvui.io);
        var wbuf: [4096]u8 = undefined;
        var writer = file.writer(dvui.io, &wbuf);
        try dvui.testing.capturePng(iconSheetFrame, null, &writer.interface);
        try writer.end();
        start = end;
    }
    sheet_icons = &.{};
}

test "GUI icon sheet: every pack icon converts; ZIDE_CAPTURE_DIR saves contact sheets" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    const Backend = @import("sdl-backend");
    const capture_dir = Backend.c.SDL_getenv("ZIDE_CAPTURE_DIR");
    if (capture_dir == null) return error.SkipZigTest;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 1060 } });
    defer ui.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfpb: std.ArrayList(SheetIcon) = .empty;
    try loadSheetIcons(t.io, arena, "src/icons/svg", &cfpb);
    var own: std.ArrayList(SheetIcon) = .empty;
    try loadSheetIcons(t.io, arena, "src/icons/svg/zide", &own);
    var codicons: std.ArrayList(SheetIcon) = .empty;
    try loadSheetIcons(t.io, arena, "src/icons/svg/codicons", &codicons);
    try t.expect(cfpb.items.len > 0);
    try t.expect(own.items.len > 0);
    const dir = std.mem.span(@as([*:0]const u8, capture_dir));
    try captureSheets(t.allocator, dir, cfpb.items, "icons_cfpb");
    try captureSheets(t.allocator, dir, own.items, "icons_zide");
    try captureSheets(t.allocator, dir, codicons.items, "icons_codicons");
}

comptime {
    if (build_options.has_gui) {
        _ = @import("software_render_tests.zig");
        _ = @import("icons.zig");
    }
}

test "GUI software profile: editor and settings at desktop resolution" {
    if (!build_options.has_gui or build_options.has_gpu) return error.SkipZigTest;
    const Backend = @import("sdl-backend");
    if (Backend.c.SDL_getenv("ZIDE_SOFTWARE_PROFILE") == null) return error.SkipZigTest;
    const t = std.testing;
    var backend = try Backend.initWindow(.{
        .io = t.io,
        .size = .{ .w = 2048, .h = 1119 },
        .title = "ZIDE software profile",
        .hidden = true,
        .vsync = false,
        .renderer_driver = "software",
    });
    defer backend.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    var window = try dvui.Window.init(@src(), t.allocator, backend.backend(), .{});
    defer window.deinit();
    applyWindowFonts(&window, &g, &editor);
    editor.renderer_is_software = true;
    try std.Io.Dir.cwd().createDirPath(t.io, ".zig-cache");
    const profiles = [_]struct { name: []const u8, mode: Editor.Mode, capture: [:0]const u8 }{
        .{ .name = "Settings / empty buffer", .mode = .settings, .capture = ".zig-cache/software-settings.png" },
        .{ .name = "Editor / text", .mode = .normal, .capture = ".zig-cache/software-editor.png" },
        .{ .name = "Settings / text", .mode = .settings, .capture = ".zig-cache/software-settings-text.png" },
    };
    for (profiles, 0..) |profile, profile_index| {
        if (profile_index == 1) try editor.activeDoc().loadText("const result = try renderer.drawText(\"Software: café 界\");\n" ** 80);
        editor.setMode(profile.mode);
        var samples: [60]u64 = undefined;
        var submission: [60]u64 = undefined;
        var presentation: [60]u64 = undefined;
        // Ten warmup frames, sixty measured frames, then an untimed capture.
        for (0..samples.len + 11) |index| {
            const start = Backend.c.SDL_GetPerformanceCounter();
            try window.begin(@intCast((profile_index * (samples.len + 11) + index) * 16 * std.time.ns_per_ms));
            _ = frame(&editor, &g);
            window.endRendering(.{});
            const submitted = Backend.c.SDL_GetPerformanceCounter();
            if (index == samples.len + 10) {
                const surface = Backend.c.SDL_RenderReadPixels(backend.renderer, null) orelse return error.ReadPixels;
                defer Backend.c.SDL_DestroySurface(surface);
                try t.expect(Backend.c.SDL_SavePNG(surface, profile.capture));
            }
            _ = try window.end(.{});
            const ended = Backend.c.SDL_GetPerformanceCounter();
            if (index >= 10 and index < samples.len + 10) {
                samples[index - 10] = ended - start;
                submission[index - 10] = submitted - start;
                presentation[index - 10] = ended - submitted;
            }
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        std.mem.sort(u64, &submission, {}, std.sort.asc(u64));
        std.mem.sort(u64, &presentation, {}, std.sort.asc(u64));
        const ticks_per_ms = @as(f64, @floatFromInt(Backend.c.SDL_GetPerformanceFrequency())) / 1000;
        std.debug.print("software 2048x1119, {s}, 60 frames: median {d:.2} ms, p95 {d:.2} ms\n", .{
            profile.name,
            @as(f64, @floatFromInt(samples[30])) / ticks_per_ms,
            @as(f64, @floatFromInt(samples[57])) / ticks_per_ms,
        });
        std.debug.print("median submission {d:.2} ms, raster/present {d:.2} ms\n", .{
            @as(f64, @floatFromInt(submission[30])) / ticks_per_ms,
            @as(f64, @floatFromInt(presentation[30])) / ticks_per_ms,
        });
    }
}

test "GUI renderer smoke: software draws text and secondary windows inherit its driver" {
    if (!build_options.has_gui or build_options.has_gpu) return error.SkipZigTest;
    const Backend = @import("sdl-backend");
    const t = std.testing;
    var backend = try Backend.initWindow(.{
        .io = t.io,
        .size = .{ .w = 320, .h = 240 },
        .title = "ZIDE renderer test",
        .hidden = true,
        .vsync = true,
        .renderer_driver = "software",
    });
    defer backend.deinit();
    try t.expectEqualStrings("software", std.mem.span(Backend.c.SDL_GetRendererName(backend.renderer)));
    var window = try dvui.Window.init(@src(), t.allocator, backend.backend(), .{});
    defer window.deinit();
    try window.begin(0);
    dvui.labelNoFmt(@src(), "ZIDE software: café 界", .{}, .{});
    _ = try window.end(.{});
    // A later global hint must not change the backend chosen for new windows.
    _ = Backend.c.SDL_SetHint("SDL_RENDER_DRIVER", "invalid-driver");
    defer _ = Backend.c.SDL_ResetHint("SDL_RENDER_DRIVER");
    var child = try Backend.initWindowSecondary(&backend, .{ .hidden = true });
    defer child.deinit();
    try t.expectEqualStrings("software", std.mem.span(Backend.c.SDL_GetRendererName(child.renderer)));
}

test "GUI GPU smoke: native backend initializes and draws a text frame" {
    if (!build_options.has_gui or !build_options.has_gpu) return error.SkipZigTest;
    // dvui.testing skips this backend, so exercise its actual initialization.
    const Backend = @import("sdl-backend");
    const t = std.testing;
    var backend = try Backend.initWindow(.{
        .allocator = t.allocator,
        .io = t.io,
        .size = .{ .w = 320, .h = 240 },
        .title = "ZIDE GPU test",
        .hidden = true,
        .vsync = true,
    });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), t.allocator, backend.backend(), .{});
    defer window.deinit();
    try window.begin(0);
    dvui.labelNoFmt(@src(), "ZIDE GPU: café 界", .{}, .{});
    _ = try window.end(.{});
}

// ---------------------------------------------------------------------------
// Pure helpers (no window: these run in `zig build test`, whose build has no
// dvui; the "GUI " tests above need `zig build test-gui`).
// ---------------------------------------------------------------------------

test "gui keybind names: digits, punctuation and insert reach the keymap" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("ctrl+1", comboString(true, false, false, "one", &buf));
    try t.expectEqualStrings("ctrl+[", comboString(true, false, false, "left_bracket", &buf));
    try t.expectEqualStrings("ctrl+alt+shift+;", comboString(true, true, true, "semicolon", &buf));
    try t.expectEqualStrings("alt+.", comboString(false, true, false, "period", &buf));
    try t.expectEqualStrings("ctrl+'", comboString(true, false, false, "apostrophe", &buf));
    try t.expectEqualStrings("insert", comboString(false, false, false, "insert", &buf));
    try t.expectEqualStrings("shift+f6", comboString(false, false, true, "f6", &buf));
    // Keys without a keybind name produce nothing (the dispatcher skips them).
    try t.expectEqualStrings("", comboString(true, false, false, "left_shift", &buf));
    try t.expectEqualStrings("", comboString(false, false, false, "kp_enter", &buf));
    // Every name the GUI sends is one the keymap accepts ...
    for (key_name_map.values()) |name| try t.expect(keybind.isKnownKey(name));
    // ... and the whole shared vocabulary can be sent.
    const vocabulary = [_][]const u8{
        "0",         "1",     "2",     "3",      "4",       "5",         "6",      "7",
        "8",         "9",     "f1",    "f2",     "f3",      "f4",        "f5",     "f6",
        "f7",        "f8",    "f9",    "f10",    "f11",     "f12",       "up",     "down",
        "left",      "right", "home",  "end",    "page_up", "page_down", "insert", "delete",
        "backspace", "tab",   "enter", "escape", "space",   "backslash", "[",      "]",
        ";",         "'",     ",",     ".",      "/",       "-",         "=",      "`",
    };
    for (vocabulary) |name| {
        var found = false;
        for (key_name_map.values()) |v| found = found or std.mem.eql(u8, v, name);
        try t.expect(found);
    }
    for ('a'..'z' + 1) |c| {
        const letter = [_]u8{@intCast(c)};
        try t.expectEqualStrings(&letter, key_name_map.get(&letter).?);
    }
}

test "gui deferred queue: runs in order, owns its names, refuses overflow" {
    const t = std.testing;
    var q: DeferredQueue = .{};
    var name_buf = "split_vertical".*;
    try t.expect(q.push(.command, &name_buf));
    // The queue copied the name: the source may be freed or reused.
    @memcpy(name_buf[0..5], "XXXXX");
    try t.expect(q.push(.action, "toggle_terminal"));
    try t.expect(q.push(.command, "a"));
    try t.expect(q.push(.command, "b"));
    try t.expect(!q.push(.command, "one too many"));
    const long = [_]u8{'x'} ** (DeferredQueue.max_name + 1);
    var q2: DeferredQueue = .{};
    try t.expect(!q2.push(.command, &long));
    try t.expect(q2.pop() == null);

    const first = q.pop().?;
    try t.expectEqual(DeferredQueue.Kind.command, first.kind);
    try t.expectEqualStrings("split_vertical", first.name());
    const second = q.pop().?;
    try t.expectEqual(DeferredQueue.Kind.action, second.kind);
    try t.expectEqualStrings("toggle_terminal", second.name());
    try t.expectEqualStrings("a", q.pop().?.name());
    try t.expectEqualStrings("b", q.pop().?.name());
    try t.expect(q.pop() == null);
    try t.expect(q.push(.command, "again"));
}

test "gui display lines: snapped columns, tab expansion cut on a boundary, invalid bytes as '?'" {
    const t = std.testing;
    var buf: [64]u8 = undefined;

    // A char-literal span that ends inside `é` (C1) or past the line (`'\`
    // at the end of a line) is snapped before it can slice text for dvui.
    const lit = "c = 'é';";
    const shown = displayLine(lit, 4, &buf);
    try t.expect(shown.ptr == lit.ptr); // valid, no tabs: drawn as is
    try t.expectEqual(@as(usize, 5), displayCol(lit, shown, 6, 4)); // inside é → its start
    try t.expectEqual(@as(usize, 7), displayCol(lit, shown, 7, 4));
    try t.expectEqual(lit.len, displayCol(lit, shown, 99, 4));

    // Tabs expand; byte columns map onto the expanded text.
    const tabbed = "\tx\té";
    const exp = displayLine(tabbed, 4, &buf);
    try t.expectEqualStrings("    x   é", exp);
    try t.expectEqual(@as(usize, 4), displayCol(tabbed, exp, 1, 4));
    try t.expectEqual(@as(usize, 8), displayCol(tabbed, exp, 3, 4));
    try t.expectEqual(@as(usize, 8), displayCol(tabbed, exp, 4, 4)); // inside é

    // A line too long for the buffer is cut before a character it can't
    // hold whole (D18): 6 bytes of room, and the emoji would need 5 to 8.
    var small: [6]u8 = undefined;
    const cut = expandTabs("\tx😀", 4, &small);
    try t.expectEqualStrings("    x", cut);
    try t.expect(std.unicode.utf8ValidateSlice(cut));
    try t.expectEqualStrings("ab", dropPartialTail("ab\xe2\x82"));
    try t.expectEqualStrings("ab\xe2\x82\xac", dropPartialTail("ab\xe2\x82\xac"));

    // Bytes that aren't UTF-8 draw as '?', one for one, so columns hold.
    const bad = "a\xffb\xe2\x82c\xed\xa0\x80d";
    const safe = displayLine(bad, 4, &buf);
    try t.expectEqual(bad.len, safe.len);
    try t.expect(std.unicode.utf8ValidateSlice(safe));
    try t.expectEqualStrings("a?b??c???d", safe);
    const bad_tab = "\t\xc3";
    try t.expectEqualStrings("    ?", displayLine(bad_tab, 4, &buf));
}

test "gui terminal keys: printable keys type through text, chords from the key" {
    const t = std.testing;
    // Plain and Shift keys: the layout's text event types the character.
    try t.expectEqual(TermKeyRoute.text, terminalKeyRoute(false, false, true));
    try t.expectEqual(TermKeyRoute.text, terminalKeyRoute(false, false, false));
    // AltGr (and Ctrl+Alt on Windows) typed a character: the text wins.
    try t.expectEqual(TermKeyRoute.text, terminalKeyRoute(false, true, true));
    try t.expectEqual(TermKeyRoute.text, terminalKeyRoute(true, true, true));
    // Alt+b, Ctrl+Alt+a with no character: encoded from the key.
    try t.expectEqual(TermKeyRoute.chord, terminalKeyRoute(false, true, false));
    try t.expectEqual(TermKeyRoute.chord, terminalKeyRoute(true, true, false));
    // Ctrl+C sends ETX; Ctrl+Space's stray ' ' must not follow its NUL.
    try t.expectEqual(TermKeyRoute.chord, terminalKeyRoute(true, false, false));
    try t.expectEqual(TermKeyRoute.chord_drop_text, terminalKeyRoute(true, false, true));

    try t.expect(isTypedText("a"));
    try t.expect(isTypedText("€ ö ß"));
    try t.expect(!isTypedText(""));
    try t.expect(!isTypedText("\r"));
    try t.expect(!isTypedText("a\x1b"));
    try t.expect(!isTypedText("\x7f"));
}

test "gui vertical motion: the sticky x holds only where the last move left the cursor" {
    const t = std.testing;
    var vm: VerticalMotion = .{};
    try t.expect(vm.target(1, 7, 0, 10) == null);
    vm.reset(1, 7);
    vm.remember(0, 10, 42.5);
    vm.remember(2, 30, 8); // index 1 skipped: never matches
    try t.expectEqual(@as(?f32, 42.5), vm.target(1, 7, 0, 10));
    try t.expectEqual(@as(?f32, 8), vm.target(1, 7, 2, 30));
    try t.expect(vm.target(1, 7, 1, std.math.maxInt(usize) - 1) == null);
    try t.expect(vm.target(1, 7, 0, 11) == null); // the cursor moved since
    try t.expect(vm.target(1, 8, 0, 10) == null); // the text changed
    try t.expect(vm.target(2, 7, 0, 10) == null); // another document
    try t.expect(vm.target(1, 7, 3, 10) == null); // no record for that cursor
    vm.remember(VerticalMotion.max_cursors, 5, 1); // past the table: ignored
    try t.expect(vm.target(1, 7, VerticalMotion.max_cursors, 5) == null);
}

test "GUI status messages: a new one is a filled block in its level's colors, moved left when the text needs the room" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    var ms: u64 = 0;

    // Where the block goes. With room: its text starts in the message slot,
    // where the plain text is drawn once the highlight is over.
    const font = dvui.Font.theme(.body);
    const text = "Save failed: AccessDenied";
    const text_w = font.textSize(text).w;
    const block_w = text_w + status_block_pad * 2;
    var bar: dvui.Rect.Physical = .{ .x = 10, .y = 100, .w = block_w + 400, .h = 20 };
    var block = statusBlockRect(font, 1, bar, 110, text);
    try t.expectApproxEqAbs(110 - status_block_pad, block.x, 0.01);
    try t.expectApproxEqAbs(block_w, block.w, 0.01);
    try t.expectApproxEqAbs(@as(f32, 99), block.y, 0.01);
    try t.expectApproxEqAbs(@as(f32, 22), block.h, 0.01);
    // Not enough room right of the slot: it moves left and ends with the bar.
    bar.w = block_w + 50;
    block = statusBlockRect(font, 1, bar, 110, text);
    try t.expectApproxEqAbs(bar.x + 50, block.x, 0.01);
    try t.expectApproxEqAbs(block_w, block.w, 0.01);
    // Wider than the bar: the whole bar (the text is cut with an ellipsis).
    bar.w = block_w - 30;
    block = statusBlockRect(font, 1, bar, 110, text);
    try t.expectApproxEqAbs(bar.x, block.x, 0.01);
    try t.expectApproxEqAbs(bar.w, block.w, 0.01);
    // Padding and height follow the scale.
    bar.w = block_w * 2 + 400;
    block = statusBlockRect(font, 2, bar, 110, text);
    try t.expectApproxEqAbs(110 - status_block_pad * 2, block.x, 0.01);
    try t.expectApproxEqAbs(block_w * 2, block.w, 0.01);
    try t.expectApproxEqAbs(@as(f32, 98), block.y, 0.01);

    // Drawn in the window: the frame loop is told when the highlight ends.
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    editor.setStatus(.err, text);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(editor.status_flash.active);
    try t.expectEqual(status_mod.Level.err, editor.status_flash.level);
    try t.expect(editor.deadlines.next_status != null);
    try t.expectEqualStrings(text, editor.status_message);
    try snippetFormTestCapture(&editor, &g, &ms, "status_message_error.png");

    // A command through its key (Ctrl+Alt+B, the Snippets panel) dismisses
    // the message; the block keeps its time.
    const ctrl_alt: dvui.enums.Mod = @enumFromInt(@intFromEnum(dvui.enums.Mod.lcontrol) | @intFromEnum(dvui.enums.Mod.lalt));
    try dvui.testing.pressKey(.b, ctrl_alt);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(editor.snippets_visible);
    try t.expectEqualStrings("", editor.status_message);
    try t.expect(editor.status_flash.active);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(editor.status_flash.active);
    try t.expect(editor.deadlines.next_status != null);
    // Its time is up (aged by hand): the next frame drops it.
    editor.status_flash.shown_ns.? -= 5 * std.time.ns_per_s;
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!editor.status_flash.active);
    try t.expectEqual(@as(?i128, null), editor.deadlines.next_status);

    // ZIDE_CAPTURE_DIR=<dir>: pictures of the other levels and of a
    // message longer than the bar (status_message_*.png).
    editor.setStatus(.warning, "Read-only document");
    try snippetFormTestCapture(&editor, &g, &ms, "status_message_warning.png");
    editor.status_message = "Saved untitled";
    try snippetFormTestCapture(&editor, &g, &ms, "status_message_note.png");
    editor.setStatus(.warning, "Moved 3 items — 2 skipped (last a-rather-long-file-name-for-a-status-bar.zig: name already exists in the target)");
    try snippetFormTestCapture(&editor, &g, &ms, "status_message_long.png");
    editor.status_message = "Saved untitled";
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    editor.status_flash.shown_ns.? -= 5 * std.time.ns_per_s;
    try snippetFormTestCapture(&editor, &g, &ms, "status_message_settled.png");
}

/// Tests only: a left click in the middle of `rect`.
fn findBarTestClick(window: *dvui.Window, rect: dvui.Rect.Physical) !void {
    _ = try window.addEventMouseMotion(.{ .pt = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 } });
    _ = try window.addEventMouseButton(.left, .press);
    _ = try window.addEventMouseButton(.left, .release);
}

/// Tests only: the primary cursor's selection is exactly [start, end).
fn findBarTestSelection(doc: *Document, start: usize, end: usize) !void {
    const r = doc.cursors.primaryConst().selectionRange() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(start, r.start);
    try std.testing.expectEqual(end, r.end);
}

test "GUI find bar: Ctrl+F opens a row under the panes; typing, Enter, F3, the buttons and clicks drive it; Escape closes it" {
    if (!build_options.has_gui) return error.SkipZigTest;
    const t = std.testing;
    var ui = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 600 } });
    defer ui.deinit();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    var g = try GuiState.init(t.allocator);
    defer g.deinit();
    defer win_ui = undefined;
    applyWindowFonts(ui.window, &g, &editor);
    try snippetsTestSetup(&editor);
    find_bar_geom = null;
    find_bar_drag = false;
    find_bar_click_count = 0;
    var ms: u64 = 0;
    const doc = editor.activeDoc();
    const body = "const alpha = 1;\nconst Alpha = alpha + 2;\nvar alphabet = alpha;\n";
    try doc.loadText(body);
    const fb = &editor.find_bar;
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(find_bar_geom == null);

    // Ctrl+F: the row is there in the same frame, its box has the keyboard,
    // and the mode stays normal — the text is live behind it.
    try dvui.testing.pressKey(.f, .lcontrol);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(fb.visible);
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    var geom = find_bar_geom orelse return error.TestUnexpectedResult;
    try t.expect(geom.area.w > 600 and geom.area.h > 0);
    try t.expect(geom.box.w >= 80 * geom.scale);
    try t.expect(geom.text.x > geom.box.x and geom.text.w > 0);
    try t.expect(geom.toggles[0].x > geom.text.x and geom.toggles[1].x > geom.toggles[0].x);
    try t.expect(geom.toggles[2].x > geom.box.x + geom.box.w);
    try t.expect(geom.next.x > geom.prev.x and geom.close.x > geom.next.x);
    try snippetFormTestCapture(&editor, &g, &ms, "find_bar_empty.png");

    // Typing goes to the box, never into the document; the first match from
    // the caret is selected, upper and lower case alike.
    try dvui.testing.writeText("alpha");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("alpha", fb.needle.text());
    try t.expectEqualStrings(body, doc.buffer.slice(0, doc.buffer.byteLen()));
    try findBarTestSelection(doc, 6, 11);
    try t.expectEqual(find_bar_mod.Count{ .total = 5, .current = 0 }, fb.count(&editor));

    // Enter / Shift+Enter, F3 / Shift+F3
    try dvui.testing.pressKey(.enter, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try findBarTestSelection(doc, 23, 28);
    try dvui.testing.pressKey(.f3, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try findBarTestSelection(doc, 31, 36);
    try dvui.testing.pressKey(.f3, .lshift);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try findBarTestSelection(doc, 23, 28);
    try dvui.testing.pressKey(.enter, .lshift);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try findBarTestSelection(doc, 6, 11);
    try snippetFormTestCapture(&editor, &g, &ms, "find_bar_match.png");

    // The buttons: W, then Aa — each a click, each narrowing the matches
    geom = find_bar_geom.?;
    try findBarTestClick(ui.window, geom.toggles[1]);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(fb.options.whole_word);
    try t.expectEqual(@as(usize, 4), fb.count(&editor).total);
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    try findBarTestClick(ui.window, geom.toggles[0]);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(fb.options.match_case);
    try t.expectEqual(find_bar_mod.Count{ .total = 3, .current = 0 }, fb.count(&editor));
    // Alt+C / Alt+W are the same two buttons
    try dvui.testing.pressKey(.c, .lalt);
    try dvui.testing.pressKey(.w, .lalt);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!fb.options.match_case and !fb.options.whole_word);
    try t.expectEqual(@as(usize, 5), fb.count(&editor).total);

    // All: every match tinted, marks where the scroll bar runs
    try findBarTestClick(ui.window, geom.toggles[2]);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(fb.highlight_all);
    try t.expectEqual(@as(usize, 5), fb.paint(&editor, doc).all.?.items.items.len);
    try snippetFormTestCapture(&editor, &g, &ms, "find_bar_all.png");

    // The arrows
    try findBarTestClick(ui.window, geom.next);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try findBarTestSelection(doc, 23, 28);
    try findBarTestClick(ui.window, geom.prev);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try findBarTestSelection(doc, 6, 11);

    // The box is a text box: a click places the caret, a double-click takes
    // the word, the editing chords stay in it.
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = geom.text.x + 1, .y = geom.text.y + geom.text.h / 2 } });
    _ = try ui.window.addEventMouseButton(.left, .press);
    _ = try ui.window.addEventMouseButton(.left, .release);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(@as(usize, 0), fb.needle.caret);
    try t.expect(fb.needle.selection() == null);
    _ = try ui.window.addEventMouseButton(.left, .press);
    _ = try ui.window.addEventMouseButton(.left, .release);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("alpha", fb.needle.selectedText());
    try dvui.testing.pressKey(.end, .none);
    try dvui.testing.writeText("zz");
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("alphazz", fb.needle.text());
    try t.expectEqual(find_bar_mod.Count{}, fb.count(&editor));
    try snippetFormTestCapture(&editor, &g, &ms, "find_bar_none.png");
    try dvui.testing.pressKey(.backspace, .lcontrol);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("", fb.needle.text());
    try dvui.testing.pressKey(.z, .lcontrol);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("alphazz", fb.needle.text());
    try dvui.testing.pressKey(.backspace, .none);
    try dvui.testing.pressKey(.backspace, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqualStrings("alpha", fb.needle.text());
    try t.expectEqualStrings(body, doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(!doc.dirty);

    // A hint shows while the pointer rests on a button
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = geom.toggles[0].x + geom.toggles[0].w / 2, .y = geom.toggles[0].y + geom.toggles[0].h / 2 } });
    for (0..8) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try snippetFormTestCapture(&editor, &g, &ms, "find_bar_hint.png");
    var hint_buf: [96]u8 = undefined;
    try t.expectEqualStrings("Match case (Alt+C)", findBarHintText(&editor, "Match case", "", "find_toggle_case", &hint_buf));
    try t.expectEqualStrings("Next match (Enter, F3)", findBarHintText(&editor, "Next match", "Enter", "find_next", &hint_buf));
    editor.keybinds.remove("f3");
    try t.expectEqualStrings("Next match (Enter)", findBarHintText(&editor, "Next match", "Enter", "find_next", &hint_buf));
    try t.expectEqualStrings("Plain", findBarHintText(&editor, "Plain", "", "no_such_action", &hint_buf));
    try editor.keybinds.set("f3", "find_next");

    // A click in the text gives the pane the keyboard; the bar stays up and
    // F3 keeps walking. Escape there closes the bar.
    _ = try ui.window.addEventMouseMotion(.{ .pt = .{ .x = geom.area.x + geom.area.w / 2, .y = geom.area.y - 200 } });
    _ = try ui.window.addEventMouseButton(.left, .press);
    _ = try ui.window.addEventMouseButton(.left, .release);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(fb.visible);
    try t.expect(find_bar_geom != null);
    doc.cursors.primary().* = .{ .offset = 0 };
    try dvui.testing.pressKey(.f3, .none);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try findBarTestSelection(doc, 6, 11);
    try dvui.testing.pressKey(.escape, .none);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!fb.visible);
    try t.expect(find_bar_geom == null);
    try findBarTestSelection(doc, 6, 11);

    // The close button, and Escape in the box
    try dvui.testing.pressKey(.f, .lcontrol);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    try t.expectEqualStrings("alpha", fb.needle.selectedText()); // seeded from the selection
    try findBarTestClick(ui.window, find_bar_geom.?.close);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!fb.visible);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try dvui.testing.pressKey(.f, .lcontrol);
    try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try dvui.testing.pressKey(.escape, .none);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(!fb.visible);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    // Typing lands in the document again
    try dvui.testing.writeText("X");
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try t.expect(doc.dirty);

    // ZIDE_CAPTURE_DIR=<dir>: the light theme, All on, the box with the keyboard
    switchTheme(&editor, "light");
    try doc.loadText(body);
    try dvui.testing.pressKey(.f, .lcontrol);
    for (0..3) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try dvui.testing.pressKey(.enter, .none);
    for (0..2) |_| try snippetsTestFrame(ui.window, &editor, &g, &ms);
    try snippetFormTestCapture(&editor, &g, &ms, "find_bar_light.png");
}
