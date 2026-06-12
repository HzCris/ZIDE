const std = @import("std");
const build_options = @import("build_options");
const dvui = if (build_options.has_gui) @import("dvui") else struct {};
const Editor = @import("../core/editor.zig").Editor;
const Document = @import("../core/document.zig").Document;
const LayoutNode = @import("../core/layout.zig").LayoutNode;
const ThemeColor = @import("../core/theme.zig").ThemeColor;
const theme_mod = @import("../core/theme.zig");
const syntax = @import("../core/syntax.zig");
const lsp = @import("../core/lsp.zig");
const terminal_mod = @import("../core/terminal.zig");
const filetree_mod = @import("../core/filetree.zig");
const FileTree = filetree_mod.FileTree;

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
    for (doc.diagnostics.items) |*d| {
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

/// Persistent state across frames for mouse drag tracking.
var drag_active: bool = false;
var drag_anchor_offset: usize = 0;
/// Pane that owns the active drag. Every editor pane iterates the global
/// event list; without ownership the first-rendered pane consumed drags
/// that started in another pane and moved the wrong document's cursor.
var drag_pane: u8 = 0;

/// Cached editor area for stable mouse mapping during drag.
/// Without this, subpixel layout shifts cause the mouse-to-offset mapping
/// to oscillate, producing visible gyration.
var drag_area: dvui.Rect.Physical = .{};

/// When true, the user explicitly scrolled (wheel) so ensureCursorVisible is skipped.
/// Cleared when the cursor moves (key press, click, etc.).
var scroll_pinned: bool = false;

/// Multi-click detection state (double-click = word, triple-click = line).
var last_click_time_ns: i128 = 0;
var last_click_offset: usize = 0;
var click_count: u8 = 1;
/// Selection mode for drag after multi-click (extends by word/line) or
/// Shift+Alt+drag (block/column selection).
const DragMode = enum { char, word, line, block };
var drag_mode: DragMode = .char;
/// Word/line boundaries anchored by double/triple-click for drag extension.
var drag_word_start: usize = 0;
var drag_word_end: usize = 0;
/// Anchor (line, col) for block-selection drags.
var block_anchor_line: usize = 0;
var block_anchor_col: usize = 0;

/// Auto-save timer (nanosecond timestamp of last auto-save check).
var last_auto_save_ns: i128 = 0;

/// Cursor blink state.
var blink_time_ns: i128 = 0;
var blink_last_offset: usize = 0;
const blink_interval_ms: i128 = 530;

/// Render a single frame of the GUI. Returns false to quit.
pub fn frame(editor: *Editor) bool {
    if (!build_options.has_gui) return false;

    // --- Global keyboard shortcuts (before widgets consume events) ---
    // Process keybinds here so DVUI widgets (menus, etc.) cannot consume them first.
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .key) continue;
        const key = e.evt.key;
        if (key.action != .down and key.action != .repeat) continue;

        // F-keys are never text input, so they go through the keybind map
        // even unmodified (f12 = goto definition, f6 = focus pane, ...).
        const is_fkey = switch (key.code) {
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => true,
            else => false,
        };

        if (key.mod.control() or key.mod.alt() or is_fkey) {
            // Tab switching always works (even during modals)
            if (key.mod.control() and key.code == .tab) {
                e.handled = true;
                if (key.mod.shift()) editor.prevDoc() else editor.nextDoc();
                continue;
            }

            // When terminal pane is focused, only handle ctrl+backtick here;
            // all other keys are routed to the terminal by handleTerminalKeyEvents.
            if (editor.activePaneIsTerminal()) {
                continue;
            }

            // Keybinds only in normal mode (not during find/replace/palette)
            if (editor.mode == .normal) {
                // Skip modifier-only keys
                if (key.code == .left_shift or key.code == .right_shift or
                    key.code == .left_control or key.code == .right_control or
                    key.code == .left_alt or key.code == .right_alt or
                    key.code == .left_command or key.code == .right_command) continue;

                var kbuf: [64]u8 = undefined;
                const key_str = dvuiKeyToStr(key, &kbuf);
                if (key_str.len > 0) {
                    if (editor.keybinds.get(key_str)) |action| {
                        e.handled = true;
                        scroll_pinned = false;
                        execGuiAction(editor, action);
                        continue;
                    }
                    // Fallback without shift
                    if (key.mod.shift()) {
                        var kbuf2: [64]u8 = undefined;
                        const fallback_str = dvuiKeyToStrNoShift(key, &kbuf2);
                        if (fallback_str.len > 0) {
                            if (editor.keybinds.get(fallback_str)) |action| {
                                e.handled = true;
                                scroll_pinned = false;
                                execGuiAction(editor, action);
                                continue;
                            }
                        }
                    }
                }
            }
        }
    }

    // Check if quit was requested via keybind/command
    if (!editor.running) return false;

    // Keyboard focus left the file tree (Esc/Enter/Ctrl+B/...) — hand
    // dvui focus back to the active editor pane this frame.
    if (filetree_was_focused and !editor.filetree_focused) {
        filetree_release_focus = true;
    }
    filetree_was_focused = editor.filetree_focused;

    // File tree edge-drag resize (uses last frame's panel rect).
    if (editor.filetree_visible and editor.filetree != null) {
        if (filetree_panel_rect) |prect| handleFiletreeResize(editor, prect, filetree_panel_scale);
    } else {
        filetree_resizing = false;
        filetree_panel_rect = null;
    }

    // Auto-save check
    if (editor.auto_save and editor.hasUnsavedChanges()) {
        const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
        if (last_auto_save_ns == 0) {
            last_auto_save_ns = now_ns;
        }
        const elapsed_ms: u64 = @intCast(@divFloor(now_ns - last_auto_save_ns, std.time.ns_per_ms));
        if (elapsed_ms >= editor.auto_save_interval_ms) {
            _ = editor.autoSaveAll();
            last_auto_save_ns = now_ns;
        }
    }

    // --- Menu bar ---
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .style = .window,
            .background = true,
            .expand = .horizontal,
            .name = "menubar",
        });
        defer hbox.deinit();

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
            if (dvui.menuItemLabel(@src(), "Save             Ctrl+S", .{}, .{ .expand = .horizontal }) != null) {
                save(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Save As          Ctrl+Shift+S", .{}, .{ .expand = .horizontal }) != null) {
                saveAs(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Close Tab        Ctrl+W", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.closeActiveDoc();
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Exit             Ctrl+Q", .{}, .{ .expand = .horizontal }) != null) {
                return false;
            }
        }

        // ---- Edit ----
        if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Undo             Ctrl+Z", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("undo", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Redo             Ctrl+Y", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("redo", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Cut              Ctrl+X", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("cut", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Copy             Ctrl+C", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("copy", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Paste            Ctrl+V", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("paste", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Select All       Ctrl+A", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("select_all", null);
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
                editor.toggleFiletree();
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Reveal in Tree", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("filetree_reveal", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Next Tab         Ctrl+Tab", .{}, .{ .expand = .horizontal }) != null) {
                editor.nextDoc();
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Prev Tab         Ctrl+Shift+Tab", .{}, .{ .expand = .horizontal }) != null) {
                editor.prevDoc();
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
        }

        // ---- Preferences ----
        if (dvui.menuItemLabel(@src(), "Preferences", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Settings", .{}, .{ .expand = .horizontal }) != null) {
                editor.mode = .settings;
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
                openDocumentation(editor);
                m.close();
            }
            _ = dvui.menuItemLabel(@src(), "About ZIDE v0.0.1", .{}, .{ .expand = .horizontal });
        }
    }

    // --- Settings dialog (modal floating window) ---
    // Declared before the panes so its widgets consume their events first;
    // the panes' raw event loops only see what the dialog left unhandled.
    if (editor.mode == .settings) {
        settingsDialog(editor);
    } else {
        // Re-arm the text-setting pre-fill for the next dialog open
        settings_text_prefill = true;
    }

    // --- Tab bar (if multiple documents) ---
    if (editor.docCount() > 1) {
        var close_tab_idx: ?usize = null;

        var tab_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .style = .content,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        });
        defer tab_box.deinit();

        for (editor.documents.items, 0..) |doc, i| {
            const is_active = (i == editor.active_doc_idx);
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

            // Tab label button (switches to this doc)
            if (dvui.button(@src(), label, .{}, .{
                .id_extra = @intCast(i),
                .background = false,
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            })) {
                editor.switchToDoc(i);
            }

            // Close button (x)
            if (dvui.button(@src(), "\xc3\x97", .{}, .{ // × (multiplication sign)
                .id_extra = @intCast(i),
                .background = false,
                .border = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
                .padding = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
            })) {
                close_tab_idx = i;
            }
        }

        // Handle deferred tab close (after iteration is complete).
        // closeDocAt closes by index — switching first would hijack a
        // focused terminal pane's content.
        if (close_tab_idx) |idx| {
            _ = editor.closeDocAt(idx);
        }
    }

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

        const doc = editor.activeDoc();
        const pos = doc.cursorPos();

        const swd = status_box.data();
        const srs = swd.contentRectScale();
        const sarea = srs.r;
        const sscale = srs.s;
        const status_text_color = toDvui(editor.theme.status_fg);

        // Left: Ln/Col (+ cursor count if multi-cursor)
        var pos_buf: [96]u8 = undefined;
        const cursor_count = doc.cursors.count();
        // Show the detected language so it's obvious what syntax/LSP applies.
        const lang_name: []const u8 = if (doc.language) |l| l.name else "plain text";
        const pos_str = if (cursor_count > 1)
            std.fmt.bufPrint(&pos_buf, "{d} cursors | Ln {d}, Col {d} | {s}", .{ cursor_count, pos.line + 1, pos.col + 1, lang_name }) catch "?"
        else
            std.fmt.bufPrint(&pos_buf, "Ln {d}, Col {d} | {s}", .{ pos.line + 1, pos.col + 1, lang_name }) catch "?";
        dvui.renderText(.{
            .font = status_font,
            .text = pos_str,
            .rs = srs,
            .p = .{ .x = sarea.x, .y = sarea.y },
            .color = status_text_color,
        }) catch {};

        // Center: transient status message ("Saved", "Cannot open: ...",
        // file-tree results) takes priority over the line diagnostic —
        // previously these were never rendered in normal mode at all.
        if (editor.status_message.len > 0) {
            const pos_w = status_font.textSize(pos_str).w * sscale;
            dvui.renderText(.{
                .font = status_font,
                .text = editor.status_message,
                .rs = srs,
                .p = .{ .x = sarea.x + pos_w + 20 * sscale, .y = sarea.y },
                .color = status_text_color,
            }) catch {};
        } else if (worstDiagnosticOnLine(doc, pos.line)) |diag| {
            const diag_color = diagnosticColor(diag.severity);
            const prefix: []const u8 = switch (diag.severity) {
                .err => "Error: ",
                .warning => "Warning: ",
                .information => "Info: ",
                .hint => "Hint: ",
            };
            var diag_buf: [256]u8 = undefined;
            const max_msg = @min(diag.message.len, diag_buf.len - prefix.len);
            @memcpy(diag_buf[0..prefix.len], prefix);
            @memcpy(diag_buf[prefix.len..][0..max_msg], diag.message[0..max_msg]);
            const diag_str = diag_buf[0 .. prefix.len + max_msg];
            // Position after cursor info with some padding
            const pos_w = status_font.textSize(pos_str).w * sscale;
            dvui.renderText(.{
                .font = status_font,
                .text = diag_str,
                .rs = srs,
                .p = .{ .x = sarea.x + pos_w + 20 * sscale, .y = sarea.y },
                .color = diag_color,
            }) catch {};
        }

        // Right: filename + dirty marker
        const dirty_str: []const u8 = if (doc.dirty) " [Modified]" else "";
        var name_buf: [256]u8 = undefined;
        const name_str = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ doc.display_name, dirty_str }) catch doc.display_name;
        const name_w = status_font.textSize(name_str).w * sscale;
        dvui.renderText(.{
            .font = status_font,
            .text = name_str,
            .rs = srs,
            .p = .{ .x = sarea.x + sarea.w - name_w, .y = sarea.y },
            .color = status_text_color,
        }) catch {};
    }

    // --- Editor area (expand=.both, LAST child) ---
    // The file tree docks left or right of the split tree as a fixed-width
    // sibling in an hbox; the splits expand into the rest.
    if (editor.filetree_visible and editor.ensureFiletree() != null) {
        var area_box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer area_box.deinit();
        if (editor.filetree_side == .left) {
            filetreePanel(editor);
            renderLayout(editor, 0);
        } else {
            renderLayout(editor, 0);
            filetreePanel(editor);
        }
    } else {
        renderLayout(editor, 0);
    }

    // --- Handle window close / quit events ---
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt == .window and e.evt.window.action == .close) return false;
        if (e.evt == .app and e.evt.app.action == .quit) return false;
    }

    return true;
}

/// Recursively render the layout tree. Split nodes use dvui.paned() for
/// draggable dividers; leaf nodes render an editor pane.
fn renderLayout(editor: *Editor, node_idx: u8) void {
    if (!build_options.has_gui) return;
    if (node_idx >= editor.layout.nodes.items.len) return;

    switch (editor.layout.nodes.items[node_idx]) {
        .leaf => |pane_id| {
            if (pane_id < editor.layout.panes.items.len) {
                const pane = editor.layout.panes.items[pane_id];
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
                .split_ratio = editor.layout.ratioPtr(node_idx),
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

/// One-frame flag: keyboard focus just left the file tree, so the active
/// editor pane must take dvui focus back — its movement/typing handlers
/// are gated on holding dvui widget focus, which the panel grabbed on
/// click. Without this, Escape "worked" but the editor stayed deaf.
var filetree_release_focus: bool = false;
/// Previous-frame filetree_focused, to catch command-driven transitions
/// (Ctrl+B hide, etc.) as well as the tree's own Esc/Enter.
var filetree_was_focused: bool = false;
/// Panel content rect + scale from the last draw — the resize drag runs
/// at the top of frame() (before any pane consumes events), so it works
/// the same whichever side the panel docks on.
var filetree_panel_rect: ?dvui.Rect.Physical = null;
var filetree_panel_scale: f32 = 1;
/// True while the user is dragging the panel's editor-facing edge.
var filetree_resizing: bool = false;
/// Double-click state for tree rows: single click on a row NAME only
/// selects; a second click on the same row within the threshold toggles
/// a folder or opens a file. (The +/- glyph stays single-click.)
const filetree_double_click_ms: i128 = 400;
var filetree_last_click_ns: i128 = 0;
var filetree_last_click_row: usize = std.math.maxInt(usize);

/// File tree side panel — custom row rendering in the editorPane style
/// (no per-row widgets; we own scrolling, selection, and input). Renders
/// the core model's flattened visible list, which the TUI draws identically.
fn filetreePanel(editor: *Editor) void {
    if (!build_options.has_gui) return;
    const ft = if (editor.filetree) |*f| f else return;

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
    filetree_panel_rect = area;
    filetree_panel_scale = scale;

    const font = dvui.Font.theme(.mono);
    const line_height = font.lineHeight() * scale;
    if (line_height <= 0 or area.h <= 0 or area.w <= 0) return;

    // Header row (root directory name), tree rows below.
    const header_h = line_height + 4 * scale;
    const rows_y = area.y + header_h;
    const rows_h = area.h - header_h;
    const visible_rows: usize = if (rows_h > line_height) @intFromFloat(@floor(rows_h / line_height)) else 1;

    // Input first — clicks/keys can expand or collapse rows, so every
    // count and clamp below must see the post-input state (a stale
    // row_count here was an index-out-of-bounds panic on collapse).
    const glyph_w = font.textSize("+ ").w * scale;
    handleFiletreeMouse(editor, ft, wd, area, rows_y, line_height, visible_rows, scale, glyph_w);
    if (editor.filetree_focused and editor.mode == .normal and !editor.completion_active) {
        handleFiletreeKeys(editor, ft, wd, visible_rows);
    }

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

    // --- Header ---
    const header_fg = toDvui(editor.theme.overlay_fg);
    const dim = toDvui(editor.theme.overlay_dim);
    fillBar(area, 0, header_h, toDvui(editor.theme.gutter_bg));
    const root_name = std.fs.path.basename(ft.root_path);
    const header_txt = if (root_name.len > 0) root_name else ft.root_path;
    renderOverlayText(font, header_txt, area.x + 6 * scale, area.y + 2 * scale, rs, if (editor.filetree_focused) header_fg else dim);

    // --- Rows ---
    const text_color = toDvui(editor.theme.text);
    const sel_bg = toDvui(editor.theme.selection);
    const guide_color = toDvui(editor.theme.gutter_separator);
    const indent_w = 12 * scale;
    var row = filetree_scroll;
    var y = rows_y;
    while (row < row_count and y + line_height <= area.y + area.h + 0.5) : (row += 1) {
        const idx = ft.visible.items[row];
        const node = ft.nodes.items[idx];
        if (row == ft.selected) {
            fillBar(area, y - area.y, line_height, sel_bg);
        }
        const depth_f: f32 = @floatFromInt(node.depth -| 1);
        const x = area.x + 6 * scale + depth_f * indent_w;
        // Indent guides: one vertical line per ancestor level, under that
        // level's glyph column, so deep nesting stays readable.
        var lvl: usize = 0;
        while (lvl < node.depth -| 1) : (lvl += 1) {
            const gx = area.x + 6 * scale + @as(f32, @floatFromInt(lvl)) * indent_w + 3 * scale;
            const guide: dvui.Rect.Physical = .{ .x = gx, .y = y, .w = @max(1.0, 1 * scale), .h = line_height };
            guide.fill(.{}, .{ .color = guide_color, .fade = 1.0 });
        }
        const glyph: []const u8 = switch (node.kind) {
            .dir => if (node.expanded) "- " else "+ ",
            .file => "  ",
        };
        // Git status drives the row color (dirs roll up contained changes)
        const row_color = if (ft.statusFor(idx)) |st| toDvui(switch (st) {
            .added => editor.theme.git_added,
            .modified => editor.theme.git_modified,
            .deleted => editor.theme.git_deleted,
            .untracked => editor.theme.git_untracked,
        }) else text_color;
        var name_buf: [300]u8 = undefined;
        const row_txt = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ glyph, node.name }) catch node.name;
        renderOverlayText(font, row_txt, x, y, rs, row_color);
        y += line_height;
    }

    // Separator line on the editor-facing edge — without it the panel
    // blends straight into the line-number gutter.
    const sep_w = @max(1.0, 1 * scale);
    const sep_x = if (editor.filetree_side == .left) area.x + area.w - sep_w else area.x;
    const sep_rect: dvui.Rect.Physical = .{ .x = sep_x, .y = area.y, .w = sep_w, .h = area.h };
    sep_rect.fill(.{}, .{ .color = toDvui(editor.theme.gutter_separator), .fade = 1.0 });

    // Right-click context menu over the panel.
    filetreeContextMenu(editor, area);
}

/// Drag the panel's editor-facing edge to resize, VS Code style. The
/// chosen width persists to init.lua on release. Runs from frame() with
/// the previous frame's rect so it always sees events before the panes.
fn handleFiletreeResize(editor: *Editor, prect: dvui.Rect.Physical, scale: f32) void {
    if (!build_options.has_gui) return;
    if (scale <= 0) return;
    const edge_x = if (editor.filetree_side == .left) prect.x + prect.w else prect.x;
    const grab: f32 = 4 * scale;

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        const near_edge = me.p.x >= edge_x - grab and me.p.x <= edge_x + grab and
            me.p.y >= prect.y and me.p.y <= prect.y + prect.h;

        switch (me.action) {
            .position => {
                if (near_edge or filetree_resizing) dvui.cursorSet(.arrow_w_e);
            },
            .press => {
                if (me.button == .left and near_edge) {
                    e.handled = true;
                    filetree_resizing = true;
                }
            },
            .motion => {
                if (filetree_resizing) {
                    e.handled = true;
                    const w_phys = if (editor.filetree_side == .left)
                        me.p.x - prect.x
                    else
                        (prect.x + prect.w) - me.p.x;
                    editor.filetree_width = std.math.clamp(w_phys / scale, 120, 600);
                }
            },
            .release => {
                if (filetree_resizing) {
                    e.handled = true;
                    filetree_resizing = false;
                    // Persist the chosen width
                    const lua_settings = @import("../core/lua_settings.zig");
                    var buf: [32]u8 = undefined;
                    const num = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(editor.filetree_width))}) catch "";
                    if (num.len > 0) lua_settings.writeSettingToFile("filetree_width", num) catch {};
                }
            },
            else => {},
        }
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

/// Visible row index under a physical y position, or null.
fn filetreeRowAt(ft: *const FileTree, rows_y: f32, line_height: f32, my: f32) ?usize {
    if (my < rows_y or line_height <= 0) return null;
    const rel: usize = @intFromFloat(@floor((my - rows_y) / line_height));
    const row = filetree_scroll + rel;
    if (row >= ft.visible.items.len) return null;
    return row;
}

fn handleFiletreeMouse(editor: *Editor, ft: *FileTree, wd: *dvui.WidgetData, area: dvui.Rect.Physical, rows_y: f32, line_height: f32, visible_rows: usize, scale: f32, glyph_w: f32) void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.p.x < area.x or me.p.x > area.x + area.w or
            me.p.y < area.y or me.p.y > area.y + area.h) continue;

        switch (me.action) {
            .press => {
                editor.status_message = "";
                const row = filetreeRowAt(ft, rows_y, line_height, me.p.y);
                if (me.button == .right) {
                    // Select the row under the cursor but leave the press
                    // unhandled — the panel's ContextWidget consumes it.
                    if (row) |r| ft.selected = r;
                    editor.filetree_focused = true;
                    continue;
                }
                e.handle(@src(), wd);
                dvui.focusWidget(wd.id, null, e.num);
                editor.filetree_focused = true;
                if (editor.mode != .normal) continue;
                if (row) |r| {
                    ft.selected = r;
                    const idx = ft.visible.items[r];
                    const node = ft.nodes.items[idx];

                    const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
                    const is_double = r == filetree_last_click_row and
                        now_ns - filetree_last_click_ns < filetree_double_click_ms * std.time.ns_per_ms;

                    // Single click on the +/- glyph toggles a folder; row
                    // names need a double click (toggle dir / open file) so
                    // a stray click never opens or collapses anything.
                    const depth_f: f32 = @floatFromInt(node.depth -| 1);
                    const gx = area.x + 6 * scale + depth_f * 12 * scale;
                    const in_glyph = node.kind == .dir and me.p.x >= gx and me.p.x < gx + glyph_w;

                    if (in_glyph) {
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
            },
            .position => {
                dvui.cursorSet(.arrow);
            },
            else => {},
        }
    }
}

/// Keys while the tree owns the keyboard (filetree_focused, normal mode).
/// Ctrl/Alt chords are left for the global keybind map.
fn handleFiletreeKeys(editor: *Editor, ft: *FileTree, wd: *dvui.WidgetData, visible_rows: usize) void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .key => |key| {
                if (key.action != .down and key.action != .repeat) continue;
                editor.status_message = "";
                if (key.mod.control() or key.mod.alt()) continue;
                switch (key.code) {
                    .up, .k => {
                        e.handle(@src(), wd);
                        ft.moveSelection(-1);
                        filetreeEnsureSelectedVisible(ft, visible_rows);
                    },
                    .down, .j => {
                        e.handle(@src(), wd);
                        ft.moveSelection(1);
                        filetreeEnsureSelectedVisible(ft, visible_rows);
                    },
                    .home => {
                        e.handle(@src(), wd);
                        ft.selected = 0;
                        filetreeEnsureSelectedVisible(ft, visible_rows);
                    },
                    .end => {
                        e.handle(@src(), wd);
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
                            editor.filetree_focused = false;
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
                    .backspace, .u => {
                        e.handle(@src(), wd);
                        editor.filetreeRootUp();
                    },
                    .escape => {
                        e.handle(@src(), wd);
                        editor.filetree_focused = false;
                        filetree_release_focus = true;
                    },
                    else => {},
                }
            },
            .text => |te| {
                // Swallow stray text while the tree owns the keyboard so
                // letters never insert into the document behind it.
                switch (te.action) {
                    .value => e.handle(@src(), wd),
                    else => {},
                }
            },
            else => {},
        }
    }
}

/// Status message + dvui toast — for errors the user must actually see
/// (the status bar alone was easy to miss in the first smoke test).
fn guiNotify(editor: *Editor, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&editor.status_buf, fmt, args) catch return;
    editor.status_message = msg;
    dvui.toast(@src(), .{ .message = msg });
}

/// Open the file behind a tree node (deduped against open tabs).
fn openFiletreeFile(editor: *Editor, ft: *FileTree, idx: u32) void {
    const abs = ft.absPathAlloc(editor.allocator, idx) catch return;
    defer editor.allocator.free(abs);
    _ = editor.openOrFocus(abs) catch |err| {
        if (err == error.BinaryFile) {
            guiNotify(editor, "Not opened: binary or unsupported text encoding", .{});
        } else {
            guiNotify(editor, "Open failed: {s}", .{@errorName(err)});
        }
    };
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
            const lua_settings = @import("../core/lua_settings.zig");
            const quoted: []const u8 = if (editor.filetree_side == .right) "\"right\"" else "\"left\"";
            lua_settings.writeSettingToFile("filetree_side", quoted) catch {};
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

/// The main editor text editing pane — custom line-by-line rendering.
/// No TextLayoutWidget or ScrollArea; we own rendering, scrolling, and input.
fn editorPane(editor: *Editor, pane_id: u8) void {
    if (!build_options.has_gui) return;

    const is_active_pane = pane_id == editor.active_pane;

    // Get the document for THIS pane (not necessarily the active doc).
    var pane_doc_idx = switch (editor.layout.panes.items[pane_id].content) {
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

    // Estimate visible columns for horizontal scroll (approximate with 'M' width)
    const m_width = font.textSize("M").w * scale;
    const visible_cols: usize = if (m_width > 0 and area.w > 0) @intFromFloat(@floor(area.w / m_width)) else 80;

    // --- Line number gutter width (needed for mouse + rendering) ---
    const line_count_for_gutter = doc.buffer.lineCount();
    const gutter_digits_early = guiLineNumberDigits(line_count_for_gutter, editor.gutter_min_digits);
    const digit_width_early = font.textSize("0").w * scale;
    const gutter_padding_early: f32 = 8 * scale;
    const gutter_total_width = @as(f32, @floatFromInt(gutter_digits_early)) * digit_width_early + gutter_padding_early * 2 + 1 * scale;

    // Store logical text area width for visual-row movement calculations
    // (in unscaled font units, matching what guiWrapAdvanceRow uses)
    const text_area_w_logical = @max(0.0, area.w - gutter_total_width) / scale;
    editor.text_width = if (text_area_w_logical > 0) @intFromFloat(text_area_w_logical) else 80;
    const do_wrap = editor.word_wrap;

    // Take dvui focus back from the file tree panel when keyboard focus
    // returned to the editor (movement/typing below is is_focused-gated).
    if (is_active_pane and filetree_release_focus) {
        filetree_release_focus = false;
        dvui.focusWidget(wd.id, null, null);
    }

    // --- Handle keyboard events (before rendering) — only for the focused
    // pane, and not while the file tree owns the keyboard. Modal prompts
    // (mode != .normal) still route through here. ---
    if (is_active_pane and !(editor.filetree_focused and editor.mode == .normal)) {
        _ = handleGuiKeyEvents(editor, wd);

        // Re-fetch doc after key events — close_tab may have changed/freed the active document
        pane_doc_idx = switch (editor.layout.panes.items[pane_id].content) {
            .editor => |idx| idx,
            .terminal => return,
        };
        doc = &editor.documents.items[pane_doc_idx];
    }

    // --- Handle mouse events ---
    // Block mouse clicks/drags when a modal is active so they don't go to
    // editor text. The settings dialog's widgets run before the panes, so
    // anything still unhandled here is a click outside the dialog.
    if (editor.mode != .normal) {
        if (is_active_pane) {
            for (dvui.events()) |*e| {
                if (e.handled) continue;
                if (e.evt != .mouse) continue;
                switch (e.evt.mouse.action) {
                    .press, .release, .motion => e.handle(@src(), wd),
                    else => {},
                }
            }
        }
    } else {
        // Cache text area (excluding gutter) when not dragging to prevent subpixel
        // layout shifts from causing mouse-to-offset oscillation (gyration fix).
        if (!drag_active) {
            drag_area = .{
                .x = area.x + gutter_total_width,
                .y = area.y,
                .w = area.w - gutter_total_width,
                .h = area.h,
            };
        }
        handleMouseEvents(editor, pane_id, wd, drag_area, font, line_height, scale);

        // Right-click context menu — watches the whole pane content area;
        // handleMouseEvents leaves right presses unhandled (after placing
        // the cursor) so the ContextWidget can consume them here.
        paneContextMenu(editor, pane_id, area);
    }

    // --- Ensure cursor visible (unless user is scrolling with wheel or dragging) ---
    if (!scroll_pinned and !drag_active) {
        if (do_wrap) {
            guiEnsureCursorVisibleWrapped(doc, font, text_area_w_logical, visible_lines, editor.tab_width);
        } else {
            doc.ensureCursorVisible(visible_lines, visible_cols);
        }
    }

    // --- Request text input from SDL — only for the focused pane ---
    // Settings is excluded: the DVUI dialog's own text entries request
    // input and focus; grabbing it here would steal their focus each frame.
    const focused = if (dvui.focusedWidgetId()) |fid| fid == wd.id else false;
    if (is_active_pane) {
        const needs_text = focused or (editor.mode != .normal and editor.mode != .settings);
        if (needs_text) {
            dvui.wantTextInput(area.toNatural());
            if (!focused) dvui.focusWidget(wd.id, null, 0);
        }
    }

    // Full editor area for rendering (includes gutter).
    // drag_area is the text-only area (for mouse mapping), but we render
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
    // Text area width in approximate columns (for ensureCursorVisible fallback)
    const text_cols: usize = if (char_width > 0 and text_area_w > 0) @intFromFloat(@floor(text_area_w / char_width)) else 80;

    // Wrap continuation marker style
    const wrap_marker_color = toDvui(editor.theme.wrap_marker);

    // --- Render lines (gutter + text in two clips) ---
    var line_idx: usize = doc.scroll_top;
    var y: f32 = render_area.y;

    while (line_idx < line_count and y < render_area.y + render_area.h) {
        const orig_line = doc.buffer.lineContent(line_idx);
        const line_start_offset = doc.buffer.line_starts.items[line_idx];
        var tab_exp_buf: [16384]u8 = undefined;
        const line_text = expandTabs(orig_line, editor.tab_width, &tab_exp_buf);
        const has_tabs = line_text.ptr != orig_line.ptr;
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
            const s_exp = if (has_tabs) bufColToExpCol(orig_line, s_in, editor.tab_width) else s_in;
            const e_exp = if (past_eol)
                line_text.len + 1
            else if (has_tabs)
                bufColToExpCol(orig_line, e_in, editor.tab_width)
            else
                e_in;
            line_sels[line_sel_count] = .{ .start = s_exp, .end = e_exp, .to_eol = past_eol };
            line_sel_count += 1;
        }

        // Pre-compute expanded column for primary cursor on this line
        const cursor_on_line = focused and cursor_pos.line == line_idx;
        const cursor_exp: usize = if (cursor_on_line)
            (if (has_tabs) bufColToExpCol(orig_line, cursor_pos.col, editor.tab_width) else cursor_pos.col)
        else
            0;

        // Pre-compute expanded columns for secondary cursors on this line
        var sc_exp_cols: [64]usize = undefined;
        var sc_count: usize = 0;
        if (focused and doc.cursors.count() > 1) {
            for (doc.cursors.cursors.items[1..]) |sc| {
                const sc_pos = doc.buffer.offsetToPos(sc.offset);
                if (sc_pos.line != line_idx) continue;
                if (sc_count >= 64) break;
                sc_exp_cols[sc_count] = if (has_tabs) bufColToExpCol(orig_line, sc_pos.col, editor.tab_width) else sc_pos.col;
                sc_count += 1;
            }
        }

        // Tokenize line for syntax highlighting
        var span_buf: [syntax.MAX_SPANS]syntax.HighlightSpan = undefined;
        var span_count: usize = 0;
        var exp_starts: [syntax.MAX_SPANS]usize = undefined;
        var exp_ends: [syntax.MAX_SPANS]usize = undefined;
        const lang_name: ?[]const u8 = if (doc.language) |l| l.name else null;
        if (doc.language) |lang| {
            const state = doc.ensureLineState(line_idx);
            const result = syntax.tokenizeLine(orig_line, lang, state, &span_buf);
            span_count = result.count;
            for (0..span_count) |si| {
                exp_starts[si] = if (has_tabs) bufColToExpCol(orig_line, span_buf[si].start, editor.tab_width) else span_buf[si].start;
                exp_ends[si] = if (has_tabs) bufColToExpCol(orig_line, span_buf[si].end, editor.tab_width) else span_buf[si].end;
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
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_idx + 1}) catch "";
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
                    if (worstDiagnosticOnLine(doc, line_idx)) |diag| {
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

                // Selection highlights (every cursor's, pre-computed above)
                for (line_sels[0..line_sel_count]) |ls| {
                    if (ls.start < row_end and ls.end > row_start) {
                        const sel_byte_start = if (ls.start > row_start) ls.start - row_start else 0;
                        const sel_byte_end = if (ls.end < row_end) ls.end - row_start else segment.len;

                        const sx_start = font.textSize(segment[0..sel_byte_start]).w * scale;
                        const sx_end = font.textSize(segment[0..@min(sel_byte_end, segment.len)]).w * scale;

                        // Selection continuing past this line fills to the edge
                        const sw = if (ls.to_eol and row_end >= line_text.len)
                            text_area_w - sx_start
                        else
                            sx_end - sx_start;

                        if (sw > 0) {
                            const sr: dvui.Rect.Physical = .{ .x = row_x + sx_start, .y = y, .w = sw, .h = line_height };
                            sr.fill(.{}, .{ .color = sel_color, .fade = 0.3 });
                        }
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
                            const vis_start = if (exp_starts[si] > row_start) exp_starts[si] - row_start else 0;
                            const vis_end = if (exp_ends[si] < row_end) exp_ends[si] - row_start else segment.len;
                            // Gap before span → default text color
                            if (vis_start > seg_pos) {
                                const gap = segment[seg_pos..vis_start];
                                dvui.renderText(.{
                                    .font = font,
                                    .text = gap,
                                    .rs = render_rs,
                                    .p = .{ .x = draw_x, .y = y },
                                    .color = text_color,
                                }) catch {};
                                draw_x += font.textSize(gap).w * scale;
                            }
                            // Span → syntax color
                            if (vis_end > vis_start) {
                                const span_text = segment[vis_start..vis_end];
                                const token_color = if (syn_theme.colorForToken(span_buf[si].token)) |tc| toDvui(tc) else text_color;
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
                                .color = text_color,
                            }) catch {};
                        }
                    } else {
                        dvui.renderText(.{
                            .font = font,
                            .text = segment,
                            .rs = render_rs,
                            .p = .{ .x = row_x, .y = y },
                            .color = text_color,
                        }) catch {};
                    }
                }

                // Diagnostic underlines
                for (doc.diagnostics.items) |*diag| {
                    if (diag.start_line == line_idx) {
                        // Compute underline range within this row
                        const ul_start = if (diag.start_col > row_start) diag.start_col - @as(u32, @intCast(row_start)) else 0;
                        const ul_end_col = if (diag.end_line == line_idx) diag.end_col else @as(u32, @intCast(segment.len));
                        const ul_end = if (ul_end_col > row_start) ul_end_col - @as(u32, @intCast(row_start)) else 0;
                        const clamped_start = @min(ul_start, segment.len);
                        const clamped_end = @min(ul_end, segment.len);
                        if (clamped_end > clamped_start) {
                            const ux_start = font.textSize(segment[0..clamped_start]).w * scale;
                            const ux_end = font.textSize(segment[0..clamped_end]).w * scale;
                            const ul_rect: dvui.Rect.Physical = .{
                                .x = row_x + ux_start,
                                .y = y + line_height - 2 * scale,
                                .w = ux_end - ux_start,
                                .h = 2 * scale,
                            };
                            ul_rect.fill(.{}, .{ .color = diagnosticColor(diag.severity), .fade = 0.8 });
                        }
                    }
                }

                // Cursor (using pre-computed expanded col, with blink)
                if (cursor_on_line) {
                    const on_last_seg = row_end >= line_text.len;
                    if (cursor_exp >= row_start and (cursor_exp < row_end or (on_last_seg and cursor_exp == row_end))) {
                        // Blink: reset timer when cursor moves, then toggle visibility
                        const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
                        const cur_offset = doc.cursors.primary().offset;
                        if (cur_offset != blink_last_offset) {
                            blink_time_ns = now_ns;
                            blink_last_offset = cur_offset;
                        }
                        const elapsed: i128 = now_ns - blink_time_ns;
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

    _ = text_cols; // used for future scroll adjustment

    // --- Focused pane indicator (subtle border highlight) ---
    if (is_active_pane and editor.layout.paneCount() > 1) {
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

    // --- Modal overlays (find, find_replace, command_palette, goto_line, confirm_quit) ---
    // Only render modals in the focused pane.
    if (is_active_pane and editor.mode != .normal) {
        drawModalOverlay(editor, render_area, render_rs, scale);
    }

    // --- Completion popup (renders on top, only in active pane) ---
    if (is_active_pane and editor.completion_active and editor.completion_items.items.len > 0) {
        drawCompletionPopupGui(editor, render_area, font, line_height, scale);
    }
}

/// Render a terminal pane in the GUI using the cell grid.
fn terminalPane(editor: *Editor, pane_id: u8, term_idx: usize) void {
    if (!build_options.has_gui) return;
    if (term_idx >= editor.terminals.items.len) return;

    const term = editor.terminals.items[term_idx] orelse return;
    const is_active_pane = pane_id == editor.active_pane;

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
    const font = dvui.Font.theme(.mono);
    const lh = font.lineHeight();
    const line_height: f32 = lh * scale;
    if (line_height <= 0) return;
    const cell_w = font.textSize("M").w * scale;
    if (cell_w <= 0) return;

    // Calculate visible cols/rows and resize terminal if needed
    const visible_cols: u16 = @intFromFloat(@max(1.0, area.w / cell_w));
    const visible_rows: u16 = @intFromFloat(@max(1.0, area.h / line_height));

    if (visible_cols != term.cols or visible_rows != term.rows) {
        term.resizeGrid(visible_cols, visible_rows);
    }

    // Handle mouse clicks — focus this pane when clicked.
    // Gated to normal mode so clicks meant for a modal (settings dialog,
    // find bar, ...) don't refocus the terminal behind it.
    if (editor.mode == .normal) {
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
                    editor.focusPane(pane_id);
                },
                else => {},
            }
        }
    }

    // Handle keyboard input for terminal — not while a modal is open,
    // otherwise unconsumed keys would be typed into the shell.
    if (is_active_pane and editor.mode == .normal) {
        if (handleTerminalKeyEvents(editor, term, wd)) return; // terminal was freed
    }

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

    // Draw cursor — measure text prefix up to cursor column for accurate positioning
    if (is_active_pane and t_cursor_visible and !t_exited) {
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
        const msg = "[Process exited]";
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

    // Active pane indicator (same as editor)
    if (is_active_pane and editor.layout.paneCount() > 1) {
        const focus_color: dvui.Color = .{ .r = 0x35, .g = 0x84, .b = 0xe4, .a = 0xFF };
        const border_w: f32 = 2 * scale;
        (dvui.Rect.Physical{ .x = area.x, .y = area.y, .w = border_w, .h = area.h }).fill(.{}, .{ .color = focus_color, .fade = 0.6 });
    }
}

/// Handle keyboard events when a terminal pane is focused.
/// Returns true if the terminal was closed and caller should stop using `term`.
fn handleTerminalKeyEvents(editor: *Editor, term: *terminal_mod.Terminal, wd: *dvui.WidgetData) bool {
    if (!build_options.has_gui) return false;

    for (dvui.events()) |*e| {
        if (e.handled) continue;

        switch (e.evt) {
            .key => |key| {
                if (key.action != .down and key.action != .repeat) continue;

                // Skip modifier-only keys
                if (key.code == .left_shift or key.code == .right_shift or
                    key.code == .left_control or key.code == .right_control or
                    key.code == .left_alt or key.code == .right_alt or
                    key.code == .left_command or key.code == .right_command) continue;

                // ctrl+alt+q → close terminal pane
                if (key.mod.control() and key.mod.alt() and key.code == .q) {
                    e.handle(@src(), wd);
                    editor.closeActiveTerminal();
                    return true; // terminal is freed, caller must stop
                }

                // ctrl+backtick → toggle terminal
                if (key.mod.control() and key.code == .grave) {
                    e.handle(@src(), wd);
                    editor.toggleTerminal();
                    continue;
                }

                // Special keys (arrows, enter, backspace, etc.)
                const special_cp: u21 = mapDvuiKey(key.code);
                if (special_cp != 0) {
                    e.handle(@src(), wd);
                    var out: [16]u8 = undefined;
                    const n = terminal_mod.Terminal.encodeKey(
                        special_cp,
                        key.mod.control(),
                        key.mod.alt(),
                        key.mod.shift(),
                        &out,
                    );
                    if (n > 0) {
                        term.writeInput(out[0..n]);
                    }
                    continue;
                }

                // Printable character keys (letters, digits, punctuation)
                if (dvuiKeyToChar(key.code, key.mod.shift())) |cp| {
                    e.handle(@src(), wd);
                    var out: [16]u8 = undefined;
                    // For ctrl+letter, use the base (lowercase) char
                    const base_cp: u21 = if (key.mod.control())
                        (dvuiKeyToChar(key.code, false) orelse cp)
                    else
                        cp;
                    const n = terminal_mod.Terminal.encodeKey(
                        base_cp,
                        key.mod.control(),
                        key.mod.alt(),
                        false,
                        &out,
                    );
                    if (n > 0) {
                        term.writeInput(out[0..n]);
                    }
                    continue;
                }
            },
            .text => |te| {
                // Fallback for characters not covered by dvuiKeyToChar
                // (e.g. international input methods)
                switch (te.action) {
                    .value => |val| {
                        if (val.txt.len > 0) {
                            e.handle(@src(), wd);
                            term.writeInput(val.txt);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    return false;
}

/// Map DVUI key enum to a codepoint for terminal key encoding.
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
        .space => ' ',
        else => 0,
    };
}

/// Map DVUI key code to a printable character, handling shift for US keyboard layout.
fn dvuiKeyToChar(key: dvui.enums.Key, shift: bool) ?u21 {
    return switch (key) {
        .a => if (shift) @as(u21, 'A') else 'a',
        .b => if (shift) @as(u21, 'B') else 'b',
        .c => if (shift) @as(u21, 'C') else 'c',
        .d => if (shift) @as(u21, 'D') else 'd',
        .e => if (shift) @as(u21, 'E') else 'e',
        .f => if (shift) @as(u21, 'F') else 'f',
        .g => if (shift) @as(u21, 'G') else 'g',
        .h => if (shift) @as(u21, 'H') else 'h',
        .i => if (shift) @as(u21, 'I') else 'i',
        .j => if (shift) @as(u21, 'J') else 'j',
        .k => if (shift) @as(u21, 'K') else 'k',
        .l => if (shift) @as(u21, 'L') else 'l',
        .m => if (shift) @as(u21, 'M') else 'm',
        .n => if (shift) @as(u21, 'N') else 'n',
        .o => if (shift) @as(u21, 'O') else 'o',
        .p => if (shift) @as(u21, 'P') else 'p',
        .q => if (shift) @as(u21, 'Q') else 'q',
        .r => if (shift) @as(u21, 'R') else 'r',
        .s => if (shift) @as(u21, 'S') else 's',
        .t => if (shift) @as(u21, 'T') else 't',
        .u => if (shift) @as(u21, 'U') else 'u',
        .v => if (shift) @as(u21, 'V') else 'v',
        .w => if (shift) @as(u21, 'W') else 'w',
        .x => if (shift) @as(u21, 'X') else 'x',
        .y => if (shift) @as(u21, 'Y') else 'y',
        .z => if (shift) @as(u21, 'Z') else 'z',
        .zero => if (shift) @as(u21, ')') else '0',
        .one => if (shift) @as(u21, '!') else '1',
        .two => if (shift) @as(u21, '@') else '2',
        .three => if (shift) @as(u21, '#') else '3',
        .four => if (shift) @as(u21, '$') else '4',
        .five => if (shift) @as(u21, '%') else '5',
        .six => if (shift) @as(u21, '^') else '6',
        .seven => if (shift) @as(u21, '&') else '7',
        .eight => if (shift) @as(u21, '*') else '8',
        .nine => if (shift) @as(u21, '(') else '9',
        .minus => if (shift) @as(u21, '_') else '-',
        .equal => if (shift) @as(u21, '+') else '=',
        .left_bracket => if (shift) @as(u21, '{') else '[',
        .right_bracket => if (shift) @as(u21, '}') else ']',
        .backslash => if (shift) @as(u21, '|') else '\\',
        .semicolon => if (shift) @as(u21, ':') else ';',
        .apostrophe => if (shift) @as(u21, '"') else '\'',
        .comma => if (shift) @as(u21, '<') else ',',
        .period => if (shift) @as(u21, '>') else '.',
        .slash => if (shift) @as(u21, '?') else '/',
        .grave => if (shift) @as(u21, '~') else '`',
        else => null,
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
        if (dvui.menuItemLabel(@src(), "Go to Definition F12", .{}, .{ .expand = .horizontal }) != null) {
            _ = editor.execAction("lsp_goto_definition");
            fw.close();
        }
    }
}

/// Handle mouse events for the custom editor pane.
fn handleMouseEvents(editor: *Editor, pane_id: u8, wd: *dvui.WidgetData, area: dvui.Rect.Physical, font: dvui.Font, line_height: f32, scale: f32) void {
    const pane_doc_idx = switch (editor.layout.panes.items[pane_id].content) {
        .editor => |idx| idx,
        .terminal => return,
    };
    const doc = &editor.documents.items[pane_doc_idx];
    const tab_width = editor.tab_width;
    const do_wrap = editor.word_wrap;
    const double_click_threshold_ms: u64 = 400;
    const double_click_distance: f32 = 5; // pixels

    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;

        const me = e.evt.mouse;

        // Only match events inside our area (or drag continuation)
        if (!drag_active) {
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
                editor.status_message = "";
                if (me.button == .right) {
                    // Right-click: focus the pane and move the cursor to the
                    // click point — unless it lands inside the current
                    // selection (standard context-menu behavior, so Cut/Copy
                    // act on the selection). Deliberately left unhandled: the
                    // pane's ContextWidget (created after this) consumes the
                    // press and opens the context menu.
                    editor.focusPane(pane_id);
                    editor.filetree_focused = false;
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
                scroll_pinned = false;

                // Focus this pane on click (and take focus back from the tree)
                editor.focusPane(pane_id);
                editor.filetree_focused = false;

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
                        drag_active = true;
                        drag_pane = pane_id;
                        drag_mode = .block;
                        block_anchor_line = p.line;
                        block_anchor_col = p.col;
                    } else {
                        doc.cursors.addCursor(offset) catch {};
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
                const elapsed_ms: u64 = if (now_ns > last_click_time_ns)
                    @intCast(@divFloor(now_ns - last_click_time_ns, std.time.ns_per_ms))
                else
                    double_click_threshold_ms + 1;

                // Check if click is close in time and position to previous
                const pos_close = blk: {
                    const click_pos = doc.buffer.offsetToPos(offset);
                    const last_pos = doc.buffer.offsetToPos(last_click_offset);
                    _ = double_click_distance;
                    break :blk click_pos.line == last_pos.line and
                        (if (click_pos.col > last_pos.col) click_pos.col - last_pos.col else last_pos.col - click_pos.col) < 10;
                };

                if (elapsed_ms < double_click_threshold_ms and pos_close) {
                    click_count = if (click_count >= 3) 1 else click_count + 1;
                } else {
                    click_count = 1;
                }
                last_click_time_ns = now_ns;
                last_click_offset = offset;

                if (me.mod.shift()) {
                    // Shift+click extends selection
                    if (c.anchor == null) c.anchor = c.offset;
                    c.offset = offset;
                    c.preferred_col = doc.buffer.offsetToPos(offset).col;
                } else if (click_count == 2) {
                    // Double-click: select word
                    const ws = wordBoundaryAt(doc, offset);
                    c.anchor = ws.start;
                    c.offset = ws.end;
                    c.preferred_col = doc.buffer.offsetToPos(ws.end).col;
                    drag_active = true;
                    drag_pane = pane_id;
                    drag_mode = .word;
                    drag_word_start = ws.start;
                    drag_word_end = ws.end;
                } else if (click_count == 3) {
                    // Triple-click: select entire line
                    const ls = lineBoundaryAt(doc, offset);
                    c.anchor = ls.start;
                    c.offset = ls.end;
                    c.preferred_col = doc.buffer.offsetToPos(ls.end).col;
                    drag_active = true;
                    drag_pane = pane_id;
                    drag_mode = .line;
                    drag_word_start = ls.start;
                    drag_word_end = ls.end;
                } else {
                    // Single click: place cursor
                    c.offset = offset;
                    c.preferred_col = doc.buffer.offsetToPos(offset).col;
                    c.clearSelection();
                    drag_active = true;
                    drag_pane = pane_id;
                    drag_mode = .char;
                    drag_anchor_offset = offset;
                }
            },
            .release => {
                if (drag_active and drag_pane == pane_id) {
                    e.handle(@src(), wd);
                    drag_active = false;
                }
            },
            .motion => {
                if (drag_active and drag_pane == pane_id) {
                    e.handle(@src(), wd);
                    // Auto-scroll when dragging past edges
                    const live_area = wd.contentRectScale().r;
                    if (me.p.y < live_area.y and doc.scroll_top > 0) {
                        doc.scroll_top -|= 1;
                    } else if (me.p.y > live_area.y + live_area.h) {
                        const visible = live_area.h / line_height;
                        const vis_lines: usize = if (visible > 0) @intFromFloat(@floor(visible)) else 1;
                        if (doc.scroll_top + vis_lines < doc.buffer.lineCount()) {
                            doc.scroll_top += 1;
                        }
                    }
                    const offset = screenToOffset(doc, area, font, line_height, scale, me.p, tab_width, do_wrap);
                    const c = doc.cursors.primary();

                    switch (drag_mode) {
                        .char => {
                            c.offset = offset;
                            c.preferred_col = doc.buffer.offsetToPos(offset).col;
                            c.anchor = drag_anchor_offset;
                        },
                        .word => {
                            // Extend selection by word boundaries, always keeping original word selected
                            const ws = wordBoundaryAt(doc, offset);
                            if (offset < drag_word_start) {
                                // Dragging above original word
                                c.anchor = drag_word_end;
                                c.offset = @min(ws.start, drag_word_start);
                            } else if (offset >= drag_word_end) {
                                // Dragging below original word
                                c.anchor = drag_word_start;
                                c.offset = @max(ws.end, drag_word_end);
                            } else {
                                // Still within original word
                                c.anchor = drag_word_start;
                                c.offset = drag_word_end;
                            }
                            c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
                        },
                        .line => {
                            // Extend selection by line boundaries, always keeping original line selected
                            const ls = lineBoundaryAt(doc, offset);
                            if (offset < drag_word_start) {
                                c.anchor = drag_word_end;
                                c.offset = @min(ls.start, drag_word_start);
                            } else if (offset >= drag_word_end) {
                                c.anchor = drag_word_start;
                                c.offset = @max(ls.end, drag_word_end);
                            } else {
                                c.anchor = drag_word_start;
                                c.offset = drag_word_end;
                            }
                            c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
                        },
                        .block => {
                            // Block (column) selection: cursor per line, same col span
                            const p = doc.buffer.offsetToPos(offset);
                            doc.cursors.setBlockSelection(
                                &doc.buffer,
                                block_anchor_line,
                                block_anchor_col,
                                p.line,
                                p.col,
                            ) catch {};
                        },
                    }
                }
            },
            .wheel_y => |delta| {
                e.handle(@src(), wd);
                scroll_pinned = true;
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
                    dvui.cursorSet(.ibeam);
                }
            },
            else => {},
        }
    }
}

/// Find word boundaries around a byte offset (for double-click selection).
fn wordBoundaryAt(doc: *Document, offset: usize) struct { start: usize, end: usize } {
    const buf_len = doc.buffer.byteLen();
    const content = doc.buffer.slice(0, buf_len);
    if (content.len == 0) return .{ .start = 0, .end = 0 };

    const pos = @min(offset, content.len -| 1);

    if (isWordCharGui(content[pos])) {
        // Inside a word — expand both directions
        var start = pos;
        while (start > 0 and isWordCharGui(content[start - 1])) start -= 1;
        var end = pos;
        while (end < content.len and isWordCharGui(content[end])) end += 1;
        return .{ .start = start, .end = end };
    } else {
        // On whitespace/punctuation — select the run of non-word chars
        var start = pos;
        while (start > 0 and !isWordCharGui(content[start - 1]) and content[start - 1] != '\n') start -= 1;
        var end = pos;
        while (end < content.len and !isWordCharGui(content[end]) and content[end] != '\n') end += 1;
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

fn isWordCharGui(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
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
        const line_text = expandTabs(orig_line, tab_width, &exp_buf);
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
                    return doc.buffer.posToOffset(line_idx, buf_col);
                }

                const target_x = rel_x / scale;
                var end_idx: usize = 0;
                _ = font.textSizeEx(segment, .{ .max_width = target_x, .end_idx = &end_idx, .end_metric = .nearest });
                // Convert expanded position back to buffer position
                const buf_col = expColToBufCol(orig_line, row_start + end_idx, tab_width);
                return doc.buffer.posToOffset(line_idx, buf_col);
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
    const is_focused = if (dvui.focusedWidgetId()) |fid| fid == wd.id else false;
    var handled_any = false;

    // --- Modal input handling ---
    if (editor.mode != .normal) {
        // Settings uses a real DVUI floating dialog whose widgets already
        // consumed their events (it is declared before the panes). Only
        // catch a leftover Escape to close it — swallowing everything here
        // would break Tab navigation and text entry inside the dialog.
        if (editor.mode == .settings) {
            for (dvui.events()) |*e| {
                if (e.handled) continue;
                if (e.evt != .key) continue;
                const key = e.evt.key;
                if (key.action != .down and key.action != .repeat) continue;
                if (key.code == .escape) {
                    e.handle(@src(), wd);
                    handled_any = true;
                    editor.mode = .normal;
                    // The dialog subwindow disappears next frame — refocus
                    // the base window so editor keys work immediately.
                    dvui.focusSubwindow(null, null);
                }
            }
            return handled_any;
        }

        for (dvui.events()) |*e| {
            if (e.handled) continue;
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
                            if (val.txt.len > 0) {
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

    // --- Completion popup input handling ---
    if (editor.completion_active) {
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if (e.evt != .key) continue;
            const key = e.evt.key;
            if (key.action != .down and key.action != .repeat) continue;

            const item_count = editor.completion_items.items.len;
            switch (key.code) {
                .escape => {
                    e.handle(@src(), wd);
                    handled_any = true;
                    editor.clearCompletionItems();
                },
                .enter, .tab => {
                    e.handle(@src(), wd);
                    handled_any = true;
                    editor.acceptCompletion();
                },
                .up => {
                    e.handle(@src(), wd);
                    handled_any = true;
                    if (editor.completion_selected > 0) {
                        editor.completion_selected -= 1;
                    } else if (item_count > 0) {
                        editor.completion_selected = item_count - 1;
                    }
                },
                .down => {
                    e.handle(@src(), wd);
                    handled_any = true;
                    if (item_count > 0) {
                        editor.completion_selected = (editor.completion_selected + 1) % item_count;
                    }
                },
                else => {
                    // Any other key dismisses completion (don't consume the event)
                    editor.clearCompletionItems();
                },
            }
        }
        if (handled_any) return handled_any;
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
                // and drops the previous transient status message
                scroll_pinned = false;
                editor.status_message = "";

                // Ctrl/Alt shortcuts handled by the early event loop in frame()
                if (key.mod.control() or key.mod.alt()) continue;

                // Movement and special keys — only when focused
                if (!is_focused) continue;
                const shift = key.mod.shift();
                switch (key.code) {
                    .up => {
                        e.handle(@src(), wd);
                        if (editor.word_wrap) {
                            guiMoveVisualVertical(editor, .up, shift);
                        } else {
                            _ = editor.execCommand(if (shift) "cursor_up_select" else "cursor_up", null);
                        }
                    },
                    .down => {
                        e.handle(@src(), wd);
                        if (editor.word_wrap) {
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
                        // Filter control chars (Tab, Enter, etc.) — handled as key events
                        if (val.txt.len > 0 and val.txt[0] >= 32) {
                            e.handle(@src(), wd);
                            handled_any = true;
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

/// Execute an action with GUI-specific overrides (native file dialogs).
fn execGuiAction(editor: *Editor, action: []const u8) void {
    // New action — drop the previous transient status message
    editor.status_message = "";
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
    // Visual-row-aware multi-cursor add when word wrap is on
    if (editor.word_wrap) {
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

/// Convert a DVUI key event to a keybind map string (e.g. "ctrl+s", "alt+up").
fn dvuiKeyToStr(key: dvui.Event.Key, buf: *[64]u8) []const u8 {
    var pos: usize = 0;

    if (key.mod.control()) {
        @memcpy(buf[pos .. pos + 5], "ctrl+");
        pos += 5;
    }
    if (key.mod.alt()) {
        @memcpy(buf[pos .. pos + 4], "alt+");
        pos += 4;
    }
    if (key.mod.shift()) {
        @memcpy(buf[pos .. pos + 6], "shift+");
        pos += 6;
    }

    const name: ?[]const u8 = switch (key.code) {
        .up => "up",
        .down => "down",
        .left => "left",
        .right => "right",
        .home => "home",
        .end => "end",
        .page_up => "page_up",
        .page_down => "page_down",
        .backspace => "backspace",
        .delete => "delete",
        .tab => "tab",
        .enter => "enter",
        .escape => "escape",
        .slash => "/",
        .backslash => "backslash",
        .minus => "-",
        .equal => "=",
        .space => "space",
        .comma => ",",
        .grave => "`",
        .a => "a", .b => "b", .c => "c", .d => "d", .e => "e", .f => "f",
        .g => "g", .h => "h", .i => "i", .j => "j", .k => "k", .l => "l",
        .m => "m", .n => "n", .o => "o", .p => "p", .q => "q", .r => "r",
        .s => "s", .t => "t", .u => "u", .v => "v", .w => "w", .x => "x",
        .y => "y", .z => "z",
        .f1 => "f1", .f2 => "f2", .f3 => "f3", .f4 => "f4",
        .f5 => "f5", .f6 => "f6", .f7 => "f7", .f8 => "f8",
        .f9 => "f9", .f10 => "f10", .f11 => "f11", .f12 => "f12",
        else => null,
    };

    if (name) |n| {
        if (pos + n.len <= 64) {
            @memcpy(buf[pos .. pos + n.len], n);
            pos += n.len;
        }
        return buf[0..pos];
    }

    return buf[0..0];
}

/// Same as dvuiKeyToStr but without the shift modifier.
fn dvuiKeyToStrNoShift(key: dvui.Event.Key, buf: *[64]u8) []const u8 {
    var pos: usize = 0;

    if (key.mod.control()) {
        @memcpy(buf[pos .. pos + 5], "ctrl+");
        pos += 5;
    }
    if (key.mod.alt()) {
        @memcpy(buf[pos .. pos + 4], "alt+");
        pos += 4;
    }
    // Skip shift

    const name: ?[]const u8 = switch (key.code) {
        .up => "up",
        .down => "down",
        .left => "left",
        .right => "right",
        .home => "home",
        .end => "end",
        .page_up => "page_up",
        .page_down => "page_down",
        .backspace => "backspace",
        .delete => "delete",
        .tab => "tab",
        .enter => "enter",
        .escape => "escape",
        .slash => "/",
        .backslash => "backslash",
        .minus => "-",
        .equal => "=",
        .space => "space",
        .comma => ",",
        .grave => "`",
        .a => "a", .b => "b", .c => "c", .d => "d", .e => "e", .f => "f",
        .g => "g", .h => "h", .i => "i", .j => "j", .k => "k", .l => "l",
        .m => "m", .n => "n", .o => "o", .p => "p", .q => "q", .r => "r",
        .s => "s", .t => "t", .u => "u", .v => "v", .w => "w", .x => "x",
        .y => "y", .z => "z",
        .f1 => "f1", .f2 => "f2", .f3 => "f3", .f4 => "f4",
        .f5 => "f5", .f6 => "f6", .f7 => "f7", .f8 => "f8",
        .f9 => "f9", .f10 => "f10", .f11 => "f11", .f12 => "f12",
        else => null,
    };

    if (name) |n| {
        if (pos + n.len <= 64) {
            @memcpy(buf[pos .. pos + n.len], n);
            pos += n.len;
        }
        return buf[0..pos];
    }

    return buf[0..0];
}

/// Open a native OS file dialog and open the selected file.
fn openFileDialog(editor: *Editor) void {
    if (!build_options.has_gui) return;

    const path = dvui.dialogNativeFileOpen(editor.allocator, .{
        .title = "Open File",
    }) catch return;

    if (path) |p| {
        defer editor.allocator.free(p);
        _ = editor.openFile(p) catch |err| {
            if (err == error.BinaryFile) {
                guiNotify(editor, "Not opened: binary or unsupported text encoding", .{});
            } else {
                guiNotify(editor, "Open failed: {s}", .{@errorName(err)});
            }
        };
    }
}

/// Save the current document (or prompt Save As if no path).
fn save(editor: *Editor) void {
    const doc = editor.activeDoc();
    if (doc.file_path != null) {
        doc.save(editor.io) catch |err| {
            editor.status_message = @errorName(err);
            return;
        };
        editor.noteFileSaved(false);
        editor.status_message = "Saved";
    } else {
        saveAs(editor);
    }
}

/// Open a native OS save dialog and save the document to the selected path.
fn saveAs(editor: *Editor) void {
    if (!build_options.has_gui) return;

    const path = dvui.dialogNativeFileSave(editor.allocator, .{
        .title = "Save As",
    }) catch return;

    if (path) |p| {
        defer editor.allocator.free(p);
        editor.activeDoc().saveAs(editor.io, p) catch |err| {
            editor.status_message = @errorName(err);
            return;
        };
        editor.activeDoc().detectLanguage(editor);
        editor.noteFileSaved(true);
        editor.status_message = "Saved";
    }
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

/// Move cursor up or down by one visual (wrapped) row in the GUI.
/// Uses `preferred_col` to store the pixel x position for stable vertical movement.
fn guiMoveVisualVertical(editor: *Editor, direction: enum { up, down }, extend_selection: bool) void {
    if (!build_options.has_gui) return;

    const doc = editor.activeDoc();
    const buf = &doc.buffer;
    const font = dvui.Font.theme(.mono);
    const total_lines = buf.lineCount();
    const tw = editor.tab_width;
    const text_w: f32 = @floatFromInt(editor.text_width);

    for (doc.cursors.cursors.items) |*c| {
        const pos = buf.offsetToPos(c.offset);
        const orig_cur = buf.lineContent(pos.line);
        var exp_buf1: [16384]u8 = undefined;
        const cur_line = expandTabs(orig_cur, tw, &exp_buf1);
        const exp_col = bufColToExpCol(orig_cur, pos.col, tw);

        const wrap_info = guiWrapColToVisual(cur_line, font, text_w, exp_col);
        const cur_rows = guiWrapLineRows(cur_line, font, text_w);
        // Use the cursor's actual pixel X within its visual row, not the
        // byte column from line start which is a different unit entirely.
        const preferred_px: usize = @intFromFloat(wrap_info.px);

        if (extend_selection) {
            if (c.anchor == null) c.anchor = c.offset;
        } else {
            c.clearSelection();
        }

        switch (direction) {
            .up => {
                if (wrap_info.row > 0) {
                    const target_exp = guiWrapVisualToCol(cur_line, font, text_w, wrap_info.row - 1, preferred_px);
                    c.offset = buf.posToOffset(pos.line, expColToBufCol(orig_cur, target_exp, tw));
                } else if (pos.line > 0) {
                    const orig_prev = buf.lineContent(pos.line - 1);
                    var exp_buf2: [16384]u8 = undefined;
                    const prev_line = expandTabs(orig_prev, tw, &exp_buf2);
                    const prev_rows = guiWrapLineRows(prev_line, font, text_w);
                    const target_exp = guiWrapVisualToCol(prev_line, font, text_w, prev_rows - 1, preferred_px);
                    c.offset = buf.posToOffset(pos.line - 1, expColToBufCol(orig_prev, target_exp, tw));
                }
            },
            .down => {
                if (wrap_info.row + 1 < cur_rows) {
                    const target_exp = guiWrapVisualToCol(cur_line, font, text_w, wrap_info.row + 1, preferred_px);
                    c.offset = buf.posToOffset(pos.line, expColToBufCol(orig_cur, target_exp, tw));
                } else if (pos.line + 1 < total_lines) {
                    const orig_next = buf.lineContent(pos.line + 1);
                    var exp_buf2: [16384]u8 = undefined;
                    const next_line = expandTabs(orig_next, tw, &exp_buf2);
                    const target_exp = guiWrapVisualToCol(next_line, font, text_w, 0, preferred_px);
                    c.offset = buf.posToOffset(pos.line + 1, expColToBufCol(orig_next, target_exp, tw));
                }
            },
        }
    }
    doc.cursors.mergeCursors();
}

/// Add a new cursor one visual (wrapped) row above or below the outermost cursor.
fn guiAddCursorVisual(editor: *Editor, direction: enum { up, down }) void {
    if (!build_options.has_gui) return;

    const doc = editor.activeDoc();
    const buf = &doc.buffer;
    const font = dvui.Font.theme(.mono);
    const total_lines = buf.lineCount();
    const tw = editor.tab_width;
    const text_w: f32 = @floatFromInt(editor.text_width);

    // Find the outermost cursor in the given direction
    var edge_idx: usize = 0;
    var edge_line: usize = if (direction == .up) std.math.maxInt(usize) else 0;
    var edge_wrap_row: usize = 0;
    for (doc.cursors.cursors.items, 0..) |c, i| {
        const pos = buf.offsetToPos(c.offset);
        const orig_line = buf.lineContent(pos.line);
        var exp_buf: [16384]u8 = undefined;
        const exp_line = expandTabs(orig_line, tw, &exp_buf);
        const wrap_info = guiWrapColToVisual(exp_line, font, text_w, bufColToExpCol(orig_line, pos.col, tw));
        switch (direction) {
            .up => if (pos.line < edge_line or (pos.line == edge_line and wrap_info.row < edge_wrap_row)) {
                edge_line = pos.line;
                edge_wrap_row = wrap_info.row;
                edge_idx = i;
            },
            .down => if (pos.line > edge_line or (pos.line == edge_line and wrap_info.row > edge_wrap_row)) {
                edge_line = pos.line;
                edge_wrap_row = wrap_info.row;
                edge_idx = i;
            },
        }
    }

    const ref_cursor = doc.cursors.cursors.items[edge_idx];
    const orig_line = buf.lineContent(edge_line);
    var exp_buf1: [16384]u8 = undefined;
    const cur_line = expandTabs(orig_line, tw, &exp_buf1);
    const ref_pos = buf.offsetToPos(ref_cursor.offset);
    const ref_exp_col = bufColToExpCol(orig_line, ref_pos.col, tw);
    const ref_wrap = guiWrapColToVisual(cur_line, font, text_w, ref_exp_col);
    const preferred_px: usize = @intFromFloat(ref_wrap.px);

    switch (direction) {
        .up => {
            if (edge_wrap_row > 0) {
                const target_exp = guiWrapVisualToCol(cur_line, font, text_w, edge_wrap_row - 1, preferred_px);
                const new_offset = buf.posToOffset(edge_line, expColToBufCol(orig_line, target_exp, tw));
                doc.cursors.addCursor(new_offset) catch {};
            } else if (edge_line > 0) {
                const orig_prev = buf.lineContent(edge_line - 1);
                var exp_buf2: [16384]u8 = undefined;
                const prev_line = expandTabs(orig_prev, tw, &exp_buf2);
                const prev_rows = guiWrapLineRows(prev_line, font, text_w);
                const target_exp = guiWrapVisualToCol(prev_line, font, text_w, prev_rows - 1, preferred_px);
                const new_offset = buf.posToOffset(edge_line - 1, expColToBufCol(orig_prev, target_exp, tw));
                doc.cursors.addCursor(new_offset) catch {};
            }
        },
        .down => {
            const cur_rows = guiWrapLineRows(cur_line, font, text_w);
            if (edge_wrap_row + 1 < cur_rows) {
                const target_exp = guiWrapVisualToCol(cur_line, font, text_w, edge_wrap_row + 1, preferred_px);
                const new_offset = buf.posToOffset(edge_line, expColToBufCol(orig_line, target_exp, tw));
                doc.cursors.addCursor(new_offset) catch {};
            } else if (edge_line + 1 < total_lines) {
                const orig_next = buf.lineContent(edge_line + 1);
                var exp_buf2: [16384]u8 = undefined;
                const next_line = expandTabs(orig_next, tw, &exp_buf2);
                const target_exp = guiWrapVisualToCol(next_line, font, text_w, 0, preferred_px);
                const new_offset = buf.posToOffset(edge_line + 1, expColToBufCol(orig_next, target_exp, tw));
                doc.cursors.addCursor(new_offset) catch {};
            }
        },
    }
}

/// Find which visual wrap row a byte column falls on, and its pixel x offset within that row.
fn guiWrapColToVisual(line: []const u8, font: dvui.Font, max_width: f32, byte_col: usize) struct { row: usize, px: f32 } {
    if (line.len == 0 or max_width <= 0) return .{ .row = 0, .px = 0 };

    var visual_row: usize = 0;
    var pos: usize = 0;

    while (pos < line.len) {
        const row_start = pos;
        pos = guiWrapAdvanceRow(line, font, max_width, pos);

        if (byte_col < pos or pos >= line.len) {
            const clamped = @min(byte_col, pos);
            const effective_start = @min(row_start, clamped);
            const char_w = font.textSize("M").w;
            const px: f32 = @as(f32, @floatFromInt(clamped - effective_start)) * char_w;
            return .{ .row = visual_row, .px = px };
        }
        visual_row += 1;
    }
    return .{ .row = visual_row, .px = 0 };
}

/// Convert a visual wrap row and preferred pixel x to a byte column.
fn guiWrapVisualToCol(line: []const u8, font: dvui.Font, max_width: f32, target_row: usize, preferred_px: usize) usize {
    if (line.len == 0 or max_width <= 0) return 0;

    var pos: usize = 0;
    var row: usize = 0;

    // Advance to the target row
    while (row < target_row and pos < line.len) {
        pos = guiWrapAdvanceRow(line, font, max_width, pos);
        row += 1;
    }

    // Now find the byte offset within this row that's closest to preferred_px
    const row_start = pos;
    const row_end = guiWrapAdvanceRow(line, font, max_width, pos);
    const segment = line[row_start..row_end];
    if (segment.len == 0) return row_start;

    // Monospace: convert pixel x to column via division
    const char_w = font.textSize("M").w;
    const end_idx: usize = if (char_w > 0)
        @min(@as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(preferred_px)) / char_w))), segment.len)
    else
        segment.len;

    const result = row_start + end_idx;
    // For non-final rows, ensure we don't return the start of the next row
    // so that guiWrapColToVisual maps back to this row, not the next.
    if (result >= row_end and row_end < line.len and end_idx > 0) {
        var adj = end_idx - 1;
        while (adj > 0 and (segment[adj] & 0xC0) == 0x80) adj -= 1;
        return row_start + adj;
    }
    return result;
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
        const exp = expandTabs(doc.buffer.lineContent(line_idx), tab_width, &eb);
        visual_rows += guiWrapLineRows(exp, font, text_area_w_logical);
    }
    // Add cursor's row within its wrapped line
    const orig_cur = doc.buffer.lineContent(cursor_pos.line);
    var eb2: [16384]u8 = undefined;
    const cur_line = expandTabs(orig_cur, tab_width, &eb2);
    const exp_col = bufColToExpCol(orig_cur, cursor_pos.col, tab_width);
    const wrap_pos = guiWrapColToVisual(cur_line, font, text_area_w_logical, exp_col);
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
        const exp = expandTabs(doc.buffer.lineContent(new_top), tab_width, &eb3);
        rows_needed += guiWrapLineRows(exp, font, text_area_w_logical);
    }
    doc.scroll_top = new_top;
}

// ===========================================================================
// Tab expansion helpers
// ===========================================================================

/// Expand tab characters to spaces for display.  Returns input unchanged if
/// there are no tabs (zero-copy fast path).
fn expandTabs(input: []const u8, tab_width: usize, buf: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '\t') == null) return input;
    const tw = if (tab_width == 0) 4 else tab_width;
    var out: usize = 0;
    for (input) |ch| {
        if (ch == '\t') {
            const spaces = tw - (out % tw);
            for (0..spaces) |_| {
                if (out >= buf.len) return buf[0..out];
                buf[out] = ' ';
                out += 1;
            }
        } else {
            if (out >= buf.len) return buf[0..out];
            buf[out] = ch;
            out += 1;
        }
    }
    return buf[0..out];
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
        .find => handleFindKeyGui(editor, key),
        .find_replace => handleFindReplaceKeyGui(editor, key),
        .command_palette => handlePaletteKeyGui(editor, key),
        .confirm_quit => handleConfirmQuitKeyGui(editor, key),
        .settings => {}, // DVUI dialog handles its own input (settingsDialog)
        .file_open, .save_as => {}, // handled by native dialogs in GUI
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
                guiAppendText(&editor.open_buf, &editor.open_buf_len, txt);
            }
        },
        .find => {
            editor.status_message = "";
            guiAppendText(&editor.find_buf, &editor.find_buf_len, txt);
            guiFindIncremental(editor);
        },
        .find_replace => {
            editor.status_message = "";
            if (editor.replace_field_active) {
                guiAppendText(&editor.replace_buf, &editor.replace_buf_len, txt);
            } else {
                guiAppendText(&editor.find_buf, &editor.find_buf_len, txt);
                guiFindIncremental(editor);
            }
        },
        .command_palette => {
            guiAppendText(&editor.palette_buf, &editor.palette_buf_len, txt);
            editor.palette_selected = 0;
        },
        else => {},
    }
}

fn guiAppendText(buf: []u8, buf_len: *usize, txt: []const u8) void {
    for (txt) |ch| {
        if (ch >= 32 and ch < 127) {
            if (buf_len.* < buf.len) {
                buf[buf_len.*] = ch;
                buf_len.* += 1;
            }
        }
    }
}

fn handleGotoLineKey(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .escape => editor.mode = .normal,
        .enter => {
            if (editor.goto_buf_len > 0) {
                const num_str = editor.goto_buf[0..editor.goto_buf_len];
                const line_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
                if (line_num > 0) {
                    editor.activeDoc().gotoLine(line_num);
                }
            }
            editor.mode = .normal;
        },
        .backspace => {
            if (editor.goto_buf_len > 0) editor.goto_buf_len -= 1;
        },
        else => {},
    }
}

fn handleFindKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .escape => {
            editor.mode = .normal;
            editor.status_message = "";
        },
        .enter => {
            if (editor.find_buf_len > 0) guiFindNext(editor);
        },
        .backspace => {
            if (editor.find_buf_len > 0) {
                editor.find_buf_len -= 1;
                guiFindIncremental(editor);
            }
        },
        else => {},
    }
}

fn handleFindReplaceKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .escape => {
            editor.mode = .normal;
            editor.status_message = "";
        },
        .tab => {
            editor.replace_field_active = !editor.replace_field_active;
        },
        .enter => {
            if (!editor.replace_field_active) {
                if (editor.find_buf_len > 0) guiFindNext(editor);
            } else {
                guiReplaceOne(editor);
            }
        },
        .backspace => {
            if (editor.replace_field_active) {
                if (editor.replace_buf_len > 0) editor.replace_buf_len -= 1;
            } else {
                if (editor.find_buf_len > 0) {
                    editor.find_buf_len -= 1;
                    guiFindIncremental(editor);
                }
            }
        },
        else => {
            // Ctrl+A in find_replace = replace all
            if (key.mod.control() and key.code == .a) {
                guiReplaceAll(editor);
            }
        },
    }
}

fn handlePaletteKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .escape => {
            editor.mode = .normal;
            editor.palette_selected = 0;
        },
        .enter => {
            const filter = editor.palette_buf[0..editor.palette_buf_len];
            const names = editor.commands.allNames() catch {
                editor.mode = .normal;
                return;
            };
            // Find the Nth matching item (palette_selected)
            var idx: usize = 0;
            for (names) |name| {
                if (filter.len > 0 and !guiFuzzyMatch(name, filter)) continue;
                if (idx == editor.palette_selected) {
                    editor.mode = .normal;
                    editor.palette_selected = 0;
                    const prev_theme = editor.theme_name;
                    _ = editor.execCommand(name, null);
                    // If a theme command changed the preset, update DVUI chrome
                    if (editor.theme_name.ptr != prev_theme.ptr) {
                        dvui.themeSet(dvuiThemeForPreset(editor.theme_name, true, editor.mono_font_size));
                    }
                    return;
                }
                idx += 1;
            }
            editor.mode = .normal;
            editor.palette_selected = 0;
        },
        .tab, .down => {
            editor.palette_selected += 1;
        },
        .up => {
            editor.palette_selected -|= 1;
        },
        .backspace => {
            if (editor.palette_buf_len > 0) {
                editor.palette_buf_len -= 1;
                editor.palette_selected = 0;
            }
        },
        else => {},
    }
}

/// Keys for the file-tree prompt (create / rename / delete confirm).
/// Printable input arrives via handleModalText; this handles the rest.
fn handleFiletreePromptKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    if (editor.filetree_prompt_kind == .delete_confirm) {
        switch (key.code) {
            .y, .enter => editor.applyFiletreePrompt(),
            .n, .escape => editor.cancelFiletreePrompt(),
            else => {},
        }
        return;
    }
    switch (key.code) {
        .escape => editor.cancelFiletreePrompt(),
        .enter => editor.applyFiletreePrompt(),
        .backspace => {
            if (editor.open_buf_len > 0) editor.open_buf_len -= 1;
        },
        else => {},
    }
}

fn handleConfirmQuitKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .s => {
            // Only quit when every dirty document actually saved — silently
            // discarding on save failure (e.g. untitled buffers) loses work.
            var failures: usize = 0;
            for (editor.documents.items) |*doc| {
                if (doc.dirty) {
                    doc.save(editor.io) catch {
                        failures += 1;
                        continue;
                    };
                }
            }
            if (failures == 0) {
                editor.running = false;
            } else {
                editor.mode = .normal;
                const msg = std.fmt.bufPrint(&editor.status_buf, "{d} file(s) not saved — use Save As for untitled buffers", .{failures}) catch "Save failed";
                editor.status_message = msg;
            }
        },
        .d => editor.running = false,
        .c, .escape => editor.mode = .normal,
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
    .{ .key = "tab_width", .label = "Tab Width", .kind = .number, .desc = "Number of spaces per tab (1-16)", .min = 1, .max = 16 },
    .{ .key = "use_tabs", .label = "Use Tabs", .kind = .boolean, .desc = "Insert tabs instead of spaces" },
    .{ .key = "word_wrap", .label = "Word Wrap", .kind = .boolean, .desc = "Soft-wrap long lines in display" },
    .{ .key = "auto_close_brackets", .label = "Auto Close Brackets", .kind = .boolean, .desc = "Auto-close brackets and quotes" },
    .{ .key = "auto_save", .label = "Auto Save", .kind = .boolean, .desc = "Auto-save dirty documents periodically" },
    .{ .key = "auto_save_interval_ms", .label = "Auto Save Interval (ms)", .kind = .number, .desc = "Delay before auto-save (500-300000)", .min = 500, .max = 300000 },
    .{ .key = "gutter_min_digits", .label = "Gutter Min Digits", .kind = .number, .desc = "Minimum width of line number gutter (1-10)", .min = 1, .max = 10 },
    .{ .key = "page_size", .label = "Page Size", .kind = .number, .desc = "Lines to scroll on Page Up/Down (5-200)", .min = 5, .max = 200 },
    .{ .key = "click_clears_cursors", .label = "Click Clears Cursors", .kind = .boolean, .desc = "Left-click clears secondary cursors" },
    .{ .key = "session_persistence", .label = "Session Persistence", .kind = .boolean, .desc = "Reopen last session's files when launched bare" },
    .{ .key = "max_undo_history", .label = "Undo History Limit", .kind = .number, .desc = "Max undo operations per document, 0 = unlimited (0-100000)", .min = 0, .max = 100000 },
    .{ .key = "theme", .label = "Theme", .kind = .enum_choice, .desc = "Editor color theme", .choices = &.{ "dark", "light", "high_contrast" } },
    .{ .key = "filetree_visible", .label = "File Tree Visible", .kind = .boolean, .desc = "Show the file tree side panel (Ctrl+B)" },
    .{ .key = "filetree_side", .label = "File Tree Side", .kind = .enum_choice, .desc = "Dock the file tree on the left or right", .choices = &.{ "left", "right" } },
    .{ .key = "filetree_width", .label = "File Tree Width (GUI)", .kind = .number, .desc = "Panel width in pixels (120-600)", .min = 120, .max = 600 },
    .{ .key = "tui_filetree_width", .label = "File Tree Width (TUI)", .kind = .number, .desc = "Panel width in columns (16-80)", .min = 16, .max = 80 },
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
    const lua_settings = @import("../core/lua_settings.zig");

    var open = true;
    var float = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open }, .{
        .min_size_content = .{ .w = 480 },
    });
    defer {
        float.deinit();
        if (!open) {
            editor.mode = .normal;
            // Return keyboard focus to the base window so the editor pane
            // regains key handling without requiring a click.
            dvui.focusSubwindow(null, null);
        }
    }

    float.dragAreaSet(dvui.windowHeader("Settings", "", &open));

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = dvui.Rect.all(8),
    });
    defer vbox.deinit();

    const desc_color = toDvui(editor.theme.overlay_hint);

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
                        var val_buf: [16]u8 = undefined;
                        const quoted = std.fmt.bufPrint(&val_buf, "\"{s}\"", .{def.choices[choice]}) catch "";
                        if (quoted.len > 0) lua_settings.writeSettingToFile(def.key, quoted) catch {};
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
            const lua_settings = @import("../core/lua_settings.zig");
            var buf: [600]u8 = undefined;
            const quoted = std.fmt.bufPrint(&buf, "\"{s}\"", .{std.mem.trim(u8, val, " \t")}) catch return;
            lua_settings.writeSettingToFile(key, quoted) catch {};
        }
    }
}

fn getSettingBool(editor: *const Editor, key: []const u8) bool {
    if (std.mem.eql(u8, key, "use_tabs")) return editor.use_tabs;
    if (std.mem.eql(u8, key, "word_wrap")) return editor.word_wrap;
    if (std.mem.eql(u8, key, "auto_close_brackets")) return editor.auto_close_brackets;
    if (std.mem.eql(u8, key, "auto_save")) return editor.auto_save;
    if (std.mem.eql(u8, key, "click_clears_cursors")) return editor.click_clears_cursors;
    if (std.mem.eql(u8, key, "session_persistence")) return editor.session_persistence;
    if (std.mem.eql(u8, key, "filetree_visible")) return editor.filetree_visible;
    return false;
}

fn applySettingBool(editor: *Editor, key: []const u8, val: bool) void {
    if (std.mem.eql(u8, key, "use_tabs")) editor.use_tabs = val;
    if (std.mem.eql(u8, key, "word_wrap")) editor.word_wrap = val;
    if (std.mem.eql(u8, key, "auto_close_brackets")) editor.auto_close_brackets = val;
    if (std.mem.eql(u8, key, "auto_save")) editor.auto_save = val;
    if (std.mem.eql(u8, key, "click_clears_cursors")) editor.click_clears_cursors = val;
    if (std.mem.eql(u8, key, "session_persistence")) editor.session_persistence = val;
    if (std.mem.eql(u8, key, "filetree_visible")) {
        editor.filetree_visible = val;
        if (!val) editor.filetree_focused = false;
    }
}

fn getSettingNumber(editor: *const Editor, key: []const u8) i64 {
    if (std.mem.eql(u8, key, "tab_width")) return @intCast(editor.tab_width);
    if (std.mem.eql(u8, key, "auto_save_interval_ms")) return @intCast(editor.auto_save_interval_ms);
    if (std.mem.eql(u8, key, "gutter_min_digits")) return @intCast(editor.gutter_min_digits);
    if (std.mem.eql(u8, key, "page_size")) return @intCast(editor.page_size);
    if (std.mem.eql(u8, key, "max_undo_history")) return @intCast(editor.max_undo_history);
    if (std.mem.eql(u8, key, "filetree_width")) return @intFromFloat(editor.filetree_width);
    if (std.mem.eql(u8, key, "tui_filetree_width")) return @intCast(editor.tui_filetree_width);
    return 0;
}

fn applySettingNumber(editor: *Editor, key: []const u8, val: i64) void {
    if (std.mem.eql(u8, key, "tab_width")) {
        if (val >= 1 and val <= 16) editor.tab_width = @intCast(val);
    }
    if (std.mem.eql(u8, key, "auto_save_interval_ms")) {
        if (val >= 500 and val <= 300000) editor.auto_save_interval_ms = @intCast(val);
    }
    if (std.mem.eql(u8, key, "gutter_min_digits")) {
        if (val >= 1 and val <= 10) editor.gutter_min_digits = @intCast(val);
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
    if (std.mem.eql(u8, key, "tui_filetree_width")) {
        if (val >= 16 and val <= 80) editor.tui_filetree_width = @intCast(val);
    }
}

fn getSettingEnum(editor: *const Editor, key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "theme")) return editor.theme_name;
    if (std.mem.eql(u8, key, "filetree_side")) return @tagName(editor.filetree_side);
    return "";
}

/// Open init.lua in the editor as a document.
fn openSettingsFile(editor: *Editor) void {
    const lua_settings = @import("../core/lua_settings.zig");
    const config_path = lua_settings.getConfigPathAlways() orelse return;

    // Ensure directory and file exist
    if (lua_settings.getConfigDir()) |dir| {
        std.Io.Dir.cwd().createDirPath(editor.io, dir) catch {};
    }
    // Create file if it doesn't exist
    if (std.Io.Dir.cwd().access(editor.io, config_path, .{})) |_| {} else |_| {
        if (std.Io.Dir.cwd().createFile(editor.io, config_path, .{})) |f| {
            f.writeStreamingAll(editor.io, "-- ZIDE settings\n-- See Documentation.md for available settings\n") catch {};
            f.close(editor.io);
        } else |_| {}
    }
    _ = editor.openFile(config_path) catch {};
}

/// Switch the active GUI theme. Updates editor colors, DVUI chrome, and persists to init.lua.
fn switchTheme(editor: *Editor, name: []const u8) void {
    const lua_settings = @import("../core/lua_settings.zig");
    if (std.mem.eql(u8, name, "dark")) {
        editor.theme = theme_mod.gui_dark;
        editor.syntax_theme = theme_mod.syn_gui_dark;
        editor.theme_name = "dark";
    } else if (std.mem.eql(u8, name, "light")) {
        editor.theme = theme_mod.gui_light;
        editor.syntax_theme = theme_mod.syn_gui_light;
        editor.theme_name = "light";
    } else if (std.mem.eql(u8, name, "high_contrast")) {
        editor.theme = theme_mod.gui_high_contrast;
        editor.syntax_theme = theme_mod.syn_gui_high_contrast;
        editor.theme_name = "high_contrast";
    } else return;

    // Update DVUI chrome (menus, scrollbars, etc.) live
    dvui.themeSet(dvuiThemeForPreset(editor.theme_name, true, editor.mono_font_size));

    // Persist choice to init.lua
    var val_buf: [32]u8 = undefined;
    const quoted = std.fmt.bufPrint(&val_buf, "\"{s}\"", .{name}) catch return;
    lua_settings.writeSettingToFile("theme", quoted) catch {};
}

/// Open the GUI theme override file in the editor. Creates a commented template if it doesn't exist.
fn openThemeFile(editor: *Editor) void {
    const lua_settings = @import("../core/lua_settings.zig");
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
    const lua_settings = @import("../core/lua_settings.zig");
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
    _ = std.process.spawn(io, .{ .argv = &argv }) catch return;
}

/// Open Documentation.md in the editor.
fn openDocumentation(editor: *Editor) void {
    // Try to find Documentation.md relative to the executable
    var exe_dir_buf: [512]u8 = undefined;
    if (std.process.executableDirPath(editor.io, &exe_dir_buf)) |exe_dir_len| {
        const exe_dir = exe_dir_buf[0..exe_dir_len];
        var doc_buf: [600]u8 = undefined;
        const doc_path = std.fmt.bufPrint(&doc_buf, "{s}/Documentation.md", .{exe_dir}) catch return;
        if (doc_path.len >= doc_buf.len) return;
        doc_buf[doc_path.len] = 0;
        const z_path: [:0]const u8 = doc_buf[0..doc_path.len :0];
        if (std.Io.Dir.cwd().access(editor.io, z_path, .{})) |_| {
            _ = editor.openFile(z_path) catch {};
            return;
        } else |_| {}
    } else |_| {}

    // Fallback: try current working directory
    if (std.Io.Dir.cwd().access(editor.io, "Documentation.md", .{})) |_| {
        _ = editor.openFile("Documentation.md") catch {};
    } else |_| {}
}

// ===========================================================================
// Search logic (mirrors TUI — operates on Editor state only)
// ===========================================================================

fn guiFindIncremental(editor: *Editor) void {
    const doc = editor.activeDoc();
    const needle = editor.find_buf[0..editor.find_buf_len];
    if (needle.len == 0) {
        doc.cursors.primary().offset = editor.find_origin;
        doc.cursors.primary().clearSelection();
        editor.status_message = "";
        return;
    }
    const buf_len = doc.buffer.byteLen();
    const content = doc.buffer.slice(0, buf_len);
    const origin = @min(editor.find_origin, buf_len);

    if (std.mem.indexOf(u8, content[origin..], needle)) |idx| {
        const abs = origin + idx;
        doc.cursors.primary().anchor = abs;
        doc.cursors.primary().offset = abs + needle.len;
        doc.cursors.primary().preferred_col = doc.buffer.offsetToPos(doc.cursors.primary().offset).col;
        editor.status_message = "";
        return;
    }
    if (std.mem.indexOf(u8, content[0..origin], needle)) |idx| {
        doc.cursors.primary().anchor = idx;
        doc.cursors.primary().offset = idx + needle.len;
        doc.cursors.primary().preferred_col = doc.buffer.offsetToPos(doc.cursors.primary().offset).col;
        editor.status_message = "Search wrapped";
        return;
    }
    doc.cursors.primary().offset = editor.find_origin;
    doc.cursors.primary().clearSelection();
    editor.status_message = "No matches found";
}

fn guiFindNext(editor: *Editor) void {
    const doc = editor.activeDoc();
    const needle = editor.find_buf[0..editor.find_buf_len];
    if (needle.len == 0) return;
    const cursor_offset = doc.cursors.primary().offset;
    const buf_len = doc.buffer.byteLen();
    const content = doc.buffer.slice(0, buf_len);
    const search_start = @min(cursor_offset + 1, buf_len);

    if (std.mem.indexOf(u8, content[search_start..], needle)) |idx| {
        const abs = search_start + idx;
        doc.cursors.primary().anchor = abs;
        doc.cursors.primary().offset = abs + needle.len;
        doc.cursors.primary().preferred_col = doc.buffer.offsetToPos(doc.cursors.primary().offset).col;
        editor.status_message = "";
        return;
    }
    if (std.mem.indexOf(u8, content[0..search_start], needle)) |idx| {
        doc.cursors.primary().anchor = idx;
        doc.cursors.primary().offset = idx + needle.len;
        doc.cursors.primary().preferred_col = doc.buffer.offsetToPos(doc.cursors.primary().offset).col;
        editor.status_message = "Search wrapped";
        return;
    }
    editor.status_message = "No matches found";
}

fn guiReplaceOne(editor: *Editor) void {
    const doc = editor.activeDoc();
    const needle = editor.find_buf[0..editor.find_buf_len];
    const replacement = editor.replace_buf[0..editor.replace_buf_len];
    if (needle.len == 0) return;
    if (doc.selectedText()) |sel| {
        if (std.mem.eql(u8, sel, needle)) {
            // insertAtCursor replaces the active selection as one undo step
            doc.insertAtCursor(replacement) catch {};
        }
    }
    guiFindNext(editor);
}

fn guiReplaceAll(editor: *Editor) void {
    const doc = editor.activeDoc();
    const needle = editor.find_buf[0..editor.find_buf_len];
    const replacement = editor.replace_buf[0..editor.replace_buf_len];
    if (needle.len == 0) return;
    doc.cursors.primary().offset = 0;
    doc.cursors.primary().clearSelection();

    // The whole replace-all is one undo step.
    doc.history.beginGroup();
    defer doc.history.endGroup();

    var count: usize = 0;
    while (count < 100_000) {
        const content = doc.buffer.slice(0, doc.buffer.byteLen());
        const start = doc.cursors.primary().offset;
        if (std.mem.indexOf(u8, content[start..], needle)) |idx| {
            const abs = start + idx;
            doc.cursors.primary().offset = abs;
            doc.cursors.primary().anchor = abs;
            doc.cursors.primary().offset = abs + needle.len;
            doc.deleteSelection() catch break;
            doc.insertAtCursor(replacement) catch break;
            count += 1;
        } else break;
    }
    if (count == 0) {
        editor.status_message = "No matches found";
    } else {
        const msg = std.fmt.bufPrint(&editor.status_buf, "Replaced {d} occurrence{s}", .{
            count, @as([]const u8, if (count == 1) "" else "s"),
        }) catch "Replaced all";
        editor.status_message = msg;
    }
}

/// Memoized find match count. The overlay queries this every frame while
/// Find is open — without the cache that was a full O(buffer) scan (plus a
/// full scratch copy when the gap was interior) per rendered frame.
var match_cache_count: usize = 0;
var match_cache_version: u64 = 0;
var match_cache_doc: usize = 0;
var match_cache_needle: [256]u8 = undefined;
var match_cache_needle_len: usize = 0;

/// Count total occurrences of needle in the document buffer.
fn guiCountMatches(editor: *Editor, needle: []const u8) usize {
    const doc = editor.activeDoc();
    const doc_key = @intFromPtr(doc);
    if (doc_key == match_cache_doc and
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

fn guiFuzzyMatch(haystack: []const u8, needle: []const u8) bool {
    var hi: usize = 0;
    for (needle) |ch| {
        while (hi < haystack.len) : (hi += 1) {
            if (haystack[hi] == ch) {
                hi += 1;
                break;
            }
        } else return false;
    }
    return true;
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
    const tab_width = editor.tab_width;

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
            const h = lh + pad * 2;
            fillBar(render_area, 0, h, bg);
            var buf: [600]u8 = undefined;
            const txt = switch (editor.filetree_prompt_kind) {
                .create => std.fmt.bufPrint(&buf, "New (end with / for folder): {s}_", .{editor.open_buf[0..editor.open_buf_len]}) catch "New: ",
                .rename => std.fmt.bufPrint(&buf, "Rename: {s}_", .{editor.open_buf[0..editor.open_buf_len]}) catch "Rename: ",
                .delete_confirm => std.fmt.bufPrint(&buf, "Delete {s}? [Y]es [N]o", .{editor.filetree_prompt_target orelse ""}) catch "Delete? [Y]es [N]o",
            };
            renderOverlayText(font, txt, render_area.x + pad, render_area.y + pad, render_rs, fg);
        },
        .goto_line => {
            const h = lh + pad * 2;
            fillBar(render_area, 0, h, bg);
            var buf: [64]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "Go to line: {s}_", .{editor.goto_buf[0..editor.goto_buf_len]}) catch "Go to line: ";
            renderOverlayText(font, txt, render_area.x + pad, render_area.y + pad, render_rs, fg);
        },
        .find => {
            const h = lh + pad * 2;
            fillBar(render_area, 0, h, bg);
            var buf: [300]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "Find: {s}_", .{editor.find_buf[0..editor.find_buf_len]}) catch "Find: ";
            renderOverlayText(font, txt, render_area.x + pad, render_area.y + pad, render_rs, fg);
            // Show match count on the right
            const needle = editor.find_buf[0..editor.find_buf_len];
            if (needle.len > 0) {
                const match_count = guiCountMatches(editor, needle);
                var count_buf: [64]u8 = undefined;
                const count_str = std.fmt.bufPrint(&count_buf, "{d} match{s}", .{
                    match_count, @as([]const u8, if (match_count == 1) "" else "es"),
                }) catch "";
                if (count_str.len > 0) {
                    const count_w = font.textSize(count_str).w * scale;
                    const count_color = if (match_count == 0) warn_color else dim;
                    renderOverlayText(font, count_str, render_area.x + render_area.w - count_w - pad, render_area.y + pad, render_rs, count_color);
                }
            } else if (editor.status_message.len > 0) {
                const msg_w = font.textSize(editor.status_message).w * scale;
                renderOverlayText(font, editor.status_message, render_area.x + render_area.w - msg_w - pad, render_area.y + pad, render_rs, warn_color);
            }
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
                if (filter.len == 0 or guiFuzzyMatch(name, filter)) {
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
                if (filter.len > 0 and !guiFuzzyMatch(name, filter)) continue;
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
        .confirm_quit => {
            const h = lh + pad * 2;
            fillBar(render_area, 0, h, bg);
            renderOverlayText(font, "Unsaved changes! [S]ave [D]iscard [C]ancel", render_area.x + pad, render_area.y + pad, render_rs, fg);
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

fn renderOverlayText(font: dvui.Font, text: []const u8, x: f32, y: f32, rs: dvui.RectScale, color: dvui.Color) void {
    dvui.renderText(.{
        .font = font,
        .text = text,
        .rs = rs,
        .p = .{ .x = x, .y = y },
        .color = color,
    }) catch {};
}
