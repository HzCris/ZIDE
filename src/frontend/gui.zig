const std = @import("std");
const build_options = @import("build_options");
const dvui = if (build_options.has_gui) @import("dvui") else struct {};
const Editor = @import("../core/editor.zig").Editor;
const Document = @import("../core/document.zig").Document;

/// Persistent state across frames for mouse drag tracking.
var drag_active: bool = false;
var drag_anchor_offset: usize = 0;

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
/// Selection mode for drag after multi-click (extends by word/line).
const DragMode = enum { char, word, line };
var drag_mode: DragMode = .char;
/// Word/line boundaries anchored by double/triple-click for drag extension.
var drag_word_start: usize = 0;
var drag_word_end: usize = 0;

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

        if (key.mod.control() or key.mod.alt()) {
            // Tab switching always works (even during modals)
            if (key.mod.control() and key.code == .tab) {
                e.handled = true;
                if (key.mod.shift()) editor.prevDoc() else editor.nextDoc();
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

    // Auto-save check
    if (editor.auto_save and editor.hasUnsavedChanges()) {
        const now_ns = std.time.nanoTimestamp();
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

        if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();

            if (dvui.menuItemLabel(@src(), "New           Ctrl+N", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.newDocument() catch {};
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Open File     Ctrl+O", .{}, .{ .expand = .horizontal }) != null) {
                openFileDialog(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Save          Ctrl+S", .{}, .{ .expand = .horizontal }) != null) {
                save(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Save As       Ctrl+Shift+S", .{}, .{ .expand = .horizontal }) != null) {
                saveAs(editor);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Close Tab     Ctrl+W", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.closeActiveDoc();
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Exit          Ctrl+Q", .{}, .{ .expand = .horizontal }) != null) {
                return false;
            }
        }

        if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Undo          Ctrl+Z", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("undo", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Redo          Ctrl+Y", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("redo", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Cut           Ctrl+X", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("cut", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Copy          Ctrl+C", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("copy", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Paste         Ctrl+V", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("paste", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Select All    Ctrl+A", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execCommand("select_all", null);
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Go to Line    Ctrl+G", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("goto_line");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Find          Ctrl+F", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("find");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Replace       Ctrl+H", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("find_replace");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Command       Ctrl+P", .{}, .{ .expand = .horizontal }) != null) {
                _ = editor.execAction("command_palette");
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Settings", .{}, .{ .expand = .horizontal }) != null) {
                editor.mode = .settings;
                editor.settings_selected = 0;
                editor.settings_editing = null;
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Open Settings File", .{}, .{ .expand = .horizontal }) != null) {
                openSettingsFile(editor);
                m.close();
            }
        }

        if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Next Tab      Ctrl+Tab", .{}, .{ .expand = .horizontal }) != null) {
                editor.nextDoc();
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Prev Tab      Ctrl+Shift+Tab", .{}, .{ .expand = .horizontal }) != null) {
                editor.prevDoc();
                m.close();
            }
        }

        if (dvui.menuItemLabel(@src(), "Help", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            _ = dvui.menuItemLabel(@src(), "About ZIDE v0.0.1", .{}, .{ .expand = .horizontal });
        }
    }

    // --- Tab bar (if multiple documents) ---
    if (editor.docCount() > 1) {
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
            if (dvui.button(@src(), label, .{}, .{
                .id_extra = @intCast(i),
                .background = is_active,
                .style = if (is_active) .highlight else .content,
                .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
            })) {
                editor.switchToDoc(i);
            }
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

        const doc = editor.activeDocConst();
        const pos = doc.cursorPos();

        const swd = status_box.data();
        const srs = swd.contentRectScale();
        const sarea = srs.r;
        const sscale = srs.s;
        const status_text_color = dvui.themeGet().color(.content, .text);

        // Left: Ln/Col (+ cursor count if multi-cursor)
        var pos_buf: [64]u8 = undefined;
        const cursor_count = doc.cursors.count();
        const pos_str = if (cursor_count > 1)
            std.fmt.bufPrint(&pos_buf, "{d} cursors | Ln {d}, Col {d}", .{ cursor_count, pos.line + 1, pos.col + 1 }) catch "?"
        else
            std.fmt.bufPrint(&pos_buf, "Ln {d}, Col {d}", .{ pos.line + 1, pos.col + 1 }) catch "?";
        dvui.renderText(.{
            .font = status_font,
            .text = pos_str,
            .rs = srs,
            .p = .{ .x = sarea.x, .y = sarea.y },
            .color = status_text_color,
        }) catch {};

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
    editorPane(editor);

    // --- Handle window close / quit events ---
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt == .window and e.evt.window.action == .close) return false;
        if (e.evt == .app and e.evt.app.action == .quit) return false;
    }

    return true;
}

/// The main editor text editing pane — custom line-by-line rendering.
/// No TextLayoutWidget or ScrollArea; we own rendering, scrolling, and input.
fn editorPane(editor: *Editor) void {
    if (!build_options.has_gui) return;

    // NOTE: doc must be re-fetched after key events since close_tab can
    // deinit the active document, invalidating any earlier pointer.
    var doc = editor.activeDoc();

    // --- Container box for the editor area ---
    var ebox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .style = .window,
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .name = "editor_pane",
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

    // Estimate visible columns for horizontal scroll (approximate with 'M' width)
    const m_width = font.textSize("M").w * scale;
    const visible_cols: usize = if (m_width > 0) @intFromFloat(@floor(area.w / m_width)) else 80;

    // --- Line number gutter width (needed for mouse + rendering) ---
    const line_count_for_gutter = doc.buffer.lineCount();
    const gutter_digits_early = guiLineNumberDigits(line_count_for_gutter, editor.gutter_min_digits);
    const digit_width_early = font.textSize("0").w * scale;
    const gutter_padding_early: f32 = 8 * scale;
    const gutter_total_width = @as(f32, @floatFromInt(gutter_digits_early)) * digit_width_early + gutter_padding_early * 2 + 1 * scale;

    // Store logical text area width for visual-row movement calculations
    // (in unscaled font units, matching what guiWrapAdvanceRow uses)
    const text_area_w_logical = (area.w - gutter_total_width) / scale;
    editor.text_width = if (text_area_w_logical > 0) @intFromFloat(text_area_w_logical) else 80;
    const do_wrap = editor.word_wrap;

    // --- Handle keyboard events (before rendering) ---
    _ = handleGuiKeyEvents(editor, wd);

    // Re-fetch doc after key events — close_tab may have changed/freed the active document
    doc = editor.activeDoc();

    // --- Handle mouse events ---
    // Block mouse clicks/drags when a modal is active so they don't go to editor text.
    // Allow focus events through so keyboard input keeps working.
    if (editor.mode != .normal) {
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if (e.evt != .mouse) continue;
            switch (e.evt.mouse.action) {
                .press => {
                    e.handle(@src(), wd);
                    // Handle clicks in settings panel
                    if (editor.mode == .settings) {
                        handleSettingsClick(editor, e.evt.mouse.p, area, font, lh, scale);
                    }
                },
                .release, .motion => e.handle(@src(), wd),
                else => {},
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
        handleMouseEvents(editor, wd, drag_area, font, line_height, scale);
    }

    // --- Ensure cursor visible (unless user is scrolling with wheel or dragging) ---
    if (!scroll_pinned and !drag_active) {
        if (do_wrap) {
            guiEnsureCursorVisibleWrapped(doc, font, text_area_w_logical, visible_lines, editor.tab_width);
        } else {
            doc.ensureCursorVisible(visible_lines, visible_cols);
        }
    }

    // --- Request text input from SDL ---
    // Always request when a modal needs text (menu clicks steal focus from editor widget).
    const focused = if (dvui.focusedWidgetId()) |fid| fid == wd.id else false;
    const needs_text = focused or editor.mode != .normal;
    if (needs_text) {
        dvui.wantTextInput(area.toNatural());
        if (!focused) dvui.focusWidget(wd.id, null, 0);
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
    const sel_range = doc.cursors.primaryConst().selectionRange();
    const cursor_pos = doc.cursorPos();
    const text_color = dvui.themeGet().color(.window, .text);
    const sel_color = dvui.themeGet().focus;
    const gutter_text_color = dvui.Color{ .r = 130, .g = 130, .b = 130, .a = 200 };
    const gutter_active_color = dvui.themeGet().color(.window, .text);
    const gutter_bg_color = dvui.Color{ .r = 40, .g = 40, .b = 40, .a = 60 };
    const gutter_sep_color = dvui.Color{ .r = 80, .g = 80, .b = 80, .a = 100 };

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
    const text_area_w = text_clip_rect.w;
    // Text area width in approximate columns (for ensureCursorVisible fallback)
    const text_cols: usize = if (char_width > 0) @intFromFloat(@floor(text_area_w / char_width)) else 80;

    // Wrap continuation marker style
    const wrap_marker_color = dvui.Color{ .r = 100, .g = 100, .b = 100, .a = 150 };

    // --- Render lines (gutter + text in two clips) ---
    var line_idx: usize = doc.scroll_top;
    var y: f32 = render_area.y;

    while (line_idx < line_count and y < render_area.y + render_area.h) {
        const orig_line = doc.buffer.lineContent(line_idx);
        const line_start_offset = doc.buffer.line_starts.items[line_idx];
        var tab_exp_buf: [16384]u8 = undefined;
        const line_text = expandTabs(orig_line, editor.tab_width, &tab_exp_buf);
        const needs_wrap = do_wrap and line_text.len > 0 and font.textSize(line_text).w * scale > text_area_w;

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
                    const num_text_w = font.textSize(num_str).w * scale;
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
                    const dot_w = font.textSize(".").w * scale;
                    const dot_x = render_area.x + gutter_width - gutter_padding - dot_w;
                    dvui.renderText(.{
                        .font = font,
                        .text = ".",
                        .rs = render_rs,
                        .p = .{ .x = dot_x, .y = y },
                        .color = wrap_marker_color,
                    }) catch {};
                }
            }

            // --- Text content (clipped to text area) ---
            {
                const prev_clip = dvui.clip(text_clip_rect);
                defer dvui.clipSet(prev_clip);

                const base_x = text_area_x - eff_scroll_x;
                // For wrapped rows, x is always text_area_x (no scroll)
                const row_x = if (needs_wrap) text_area_x else base_x;

                // Selection highlight (convert buffer offsets to expanded coordinates)
                if (sel_range) |sel| {
                    const sel_start_in_line: usize = if (sel.start > line_start_offset)
                        @min(sel.start - line_start_offset, orig_line.len)
                    else
                        0;
                    const sel_end_in_line: usize = if (sel.end > line_start_offset)
                        @min(sel.end - line_start_offset, orig_line.len)
                    else
                        0;
                    const sel_start_exp = bufColToExpCol(orig_line, sel_start_in_line, editor.tab_width);
                    const sel_end_exp = if (sel.end > line_start_offset + orig_line.len)
                        line_text.len + 1
                    else
                        bufColToExpCol(orig_line, sel_end_in_line, editor.tab_width);

                    if (sel_start_exp < row_end and sel_end_exp > row_start) {
                        const sel_byte_start = if (sel_start_exp > row_start) sel_start_exp - row_start else 0;
                        const sel_byte_end = if (sel_end_exp < row_end) sel_end_exp - row_start else segment.len;

                        const sx_start = if (sel_byte_start > 0 and sel_byte_start <= segment.len)
                            font.textSize(segment[0..sel_byte_start]).w * scale
                        else
                            0;
                        const sx_end = if (sel_byte_end > 0 and sel_byte_end <= segment.len)
                            font.textSize(segment[0..sel_byte_end]).w * scale
                        else if (sel_byte_end == 0)
                            0
                        else
                            font.textSize(segment).w * scale;

                        const sw = if (sel.end > line_start_offset + orig_line.len and row_end >= line_text.len)
                            text_area_w - sx_start
                        else
                            sx_end - sx_start;

                        if (sw > 0) {
                            const sr: dvui.Rect.Physical = .{ .x = row_x + sx_start, .y = y, .w = sw, .h = line_height };
                            sr.fill(.{}, .{ .color = sel_color, .fade = 0.3 });
                        }
                    }
                }

                // Text
                if (segment.len > 0) {
                    dvui.renderText(.{
                        .font = font,
                        .text = segment,
                        .rs = render_rs,
                        .p = .{ .x = row_x, .y = y },
                        .color = text_color,
                    }) catch {};
                }

                // Cursor (convert buffer col to expanded col, with blink)
                if (focused and cursor_pos.line == line_idx) {
                    const cc = bufColToExpCol(orig_line, cursor_pos.col, editor.tab_width);
                    const on_last_seg = row_end >= line_text.len;
                    if (cc >= row_start and (cc < row_end or (on_last_seg and cc == row_end))) {
                        // Blink: reset timer when cursor moves, then toggle visibility
                        const now_ns = std.time.nanoTimestamp();
                        const cur_offset = doc.cursors.primary().offset;
                        if (cur_offset != blink_last_offset) {
                            blink_time_ns = now_ns;
                            blink_last_offset = cur_offset;
                        }
                        const elapsed: i128 = now_ns - blink_time_ns;
                        const cycle = @mod(@divFloor(elapsed, std.time.ns_per_ms), blink_interval_ms * 2);
                        const blink_on = cycle < blink_interval_ms;

                        if (blink_on) {
                            const col_in_seg = cc - row_start;
                            const clamped = @min(col_in_seg, segment.len);
                            const cx = if (clamped > 0)
                                font.textSize(segment[0..clamped]).w * scale
                            else
                                0;
                            const cr: dvui.Rect.Physical = .{ .x = row_x + cx - 1, .y = y, .w = 3, .h = line_height };
                            cr.fill(.{}, .{ .color = sel_color, .fade = 1.0 });
                        }
                        // Request redraw so blink animation continues
                        dvui.refresh(null, @src(), null);
                    }
                }

                // Secondary cursors (no blink, always visible)
                if (focused and doc.cursors.count() > 1) {
                    for (doc.cursors.cursors.items[1..]) |sc| {
                        const sc_pos = doc.buffer.offsetToPos(sc.offset);
                        if (sc_pos.line != line_idx) continue;
                        const sc_col = bufColToExpCol(orig_line, sc_pos.col, editor.tab_width);
                        const sc_on_last = row_end >= line_text.len;
                        if (sc_col >= row_start and (sc_col < row_end or (sc_on_last and sc_col == row_end))) {
                            const sc_in_seg = sc_col - row_start;
                            const sc_clamped = @min(sc_in_seg, segment.len);
                            const sc_cx = if (sc_clamped > 0)
                                font.textSize(segment[0..sc_clamped]).w * scale
                            else
                                0;
                            const sc_r: dvui.Rect.Physical = .{ .x = row_x + sc_cx - 1, .y = y, .w = 3, .h = line_height };
                            sc_r.fill(.{}, .{ .color = sel_color, .fade = 0.7 });
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
        const tilde_color = dvui.Color{ .r = 100, .g = 100, .b = 100, .a = 128 };
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

    // --- Modal overlays (find, find_replace, command_palette, goto_line, confirm_quit) ---
    if (editor.mode != .normal) {
        drawModalOverlay(editor, render_area, render_rs, scale);
    }
}

/// Handle mouse events for the custom editor pane.
fn handleMouseEvents(editor: *Editor, wd: *dvui.WidgetData, area: dvui.Rect.Physical, font: dvui.Font, line_height: f32, scale: f32) void {
    const doc = editor.activeDoc();
    const tab_width = editor.tab_width;
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
                e.handle(@src(), wd);
                dvui.focusWidget(wd.id, null, e.num);
                scroll_pinned = false;
                const offset = screenToOffset(doc, area, font, line_height, scale, me.p, tab_width);

                // Alt+click: add a cursor at click position
                if (me.mod.alt()) {
                    doc.cursors.addCursor(offset) catch {};
                    continue;
                }

                const c = doc.cursors.primary();

                // Regular click clears secondary cursors
                if (editor.click_clears_cursors and doc.cursors.count() > 1) {
                    doc.cursors.clearSecondary();
                }

                // Detect multi-click (double/triple)
                const now_ns = std.time.nanoTimestamp();
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
                    drag_mode = .line;
                    drag_word_start = ls.start;
                    drag_word_end = ls.end;
                } else {
                    // Single click: place cursor
                    c.offset = offset;
                    c.preferred_col = doc.buffer.offsetToPos(offset).col;
                    c.clearSelection();
                    drag_active = true;
                    drag_mode = .char;
                    drag_anchor_offset = offset;
                }
            },
            .release => {
                if (drag_active) {
                    e.handle(@src(), wd);
                    drag_active = false;
                }
            },
            .motion => {
                if (drag_active) {
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
                    const offset = screenToOffset(doc, area, font, line_height, scale, me.p, tab_width);
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
fn wordBoundaryAt(doc: *const Document, offset: usize) struct { start: usize, end: usize } {
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
/// When word_wrap is true, walks through wrapped visual rows to find the correct position.
fn screenToOffset(doc: *const Document, area: dvui.Rect.Physical, font: dvui.Font, line_height: f32, scale: f32, p: dvui.Point.Physical, tab_width: usize) usize {
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
        const needs_wrap = line_text.len > 0 and font.textSize(line_text).w > text_area_w;

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
                scroll_pinned = false;

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
        .minus => "-",
        .equal => "=",
        .space => "space",
        .comma => ",",
        .a => "a", .b => "b", .c => "c", .d => "d", .e => "e", .f => "f",
        .g => "g", .h => "h", .i => "i", .j => "j", .k => "k", .l => "l",
        .m => "m", .n => "n", .o => "o", .p => "p", .q => "q", .r => "r",
        .s => "s", .t => "t", .u => "u", .v => "v", .w => "w", .x => "x",
        .y => "y", .z => "z",
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
        .minus => "-",
        .equal => "=",
        .space => "space",
        .comma => ",",
        .a => "a", .b => "b", .c => "c", .d => "d", .e => "e", .f => "f",
        .g => "g", .h => "h", .i => "i", .j => "j", .k => "k", .l => "l",
        .m => "m", .n => "n", .o => "o", .p => "p", .q => "q", .r => "r",
        .s => "s", .t => "t", .u => "u", .v => "v", .w => "w", .x => "x",
        .y => "y", .z => "z",
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
            editor.status_message = @errorName(err);
        };
    }
}

/// Save the current document (or prompt Save As if no path).
fn save(editor: *Editor) void {
    const doc = editor.activeDoc();
    if (doc.file_path != null) {
        doc.save() catch |err| {
            editor.status_message = @errorName(err);
            return;
        };
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
        editor.activeDoc().saveAs(p) catch |err| {
            editor.status_message = @errorName(err);
            return;
        };
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
            const px = if (clamped > effective_start) font.textSize(line[effective_start..clamped]).w else 0;
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

    var end_idx: usize = 0;
    _ = font.textSizeEx(segment, .{
        .max_width = @floatFromInt(preferred_px),
        .end_idx = &end_idx,
        .end_metric = .nearest,
    });

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
        .settings => handleSettingsKeyGui(editor, key),
        .file_open, .save_as => {}, // handled by native dialogs in GUI
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
        .settings => {
            if (editor.settings_editing != null) {
                for (txt) |ch| {
                    if (ch >= '0' and ch <= '9') {
                        if (editor.settings_num_len < editor.settings_num_buf.len) {
                            editor.settings_num_buf[editor.settings_num_len] = ch;
                            editor.settings_num_len += 1;
                        }
                    }
                }
            }
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
            const names = editor.commands.allNames(editor.allocator) catch {
                editor.mode = .normal;
                return;
            };
            defer editor.allocator.free(names);
            // Find the Nth matching item (palette_selected)
            var idx: usize = 0;
            for (names) |name| {
                if (filter.len > 0 and !guiFuzzyMatch(name, filter)) continue;
                if (idx == editor.palette_selected) {
                    editor.mode = .normal;
                    editor.palette_selected = 0;
                    _ = editor.execCommand(name, null);
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

fn handleConfirmQuitKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    switch (key.code) {
        .s => {
            for (editor.documents.items) |*doc| {
                if (doc.dirty) doc.save() catch {};
            }
            editor.running = false;
        },
        .d => editor.running = false,
        .c, .escape => editor.mode = .normal,
        else => {},
    }
}

/// Settings definitions: name, type, description
const SettingDef = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { boolean, number },
    desc: []const u8,
};

const settings_defs = [_]SettingDef{
    .{ .key = "tab_width", .label = "Tab Width", .kind = .number, .desc = "Number of spaces per tab (1-16)" },
    .{ .key = "use_tabs", .label = "Use Tabs", .kind = .boolean, .desc = "Insert tabs instead of spaces" },
    .{ .key = "word_wrap", .label = "Word Wrap", .kind = .boolean, .desc = "Soft-wrap long lines in display" },
    .{ .key = "auto_close_brackets", .label = "Auto Close Brackets", .kind = .boolean, .desc = "Auto-close brackets and quotes" },
    .{ .key = "auto_save", .label = "Auto Save", .kind = .boolean, .desc = "Auto-save dirty documents periodically" },
    .{ .key = "auto_save_interval_ms", .label = "Auto Save Interval (ms)", .kind = .number, .desc = "Delay before auto-save (500-300000)" },
    .{ .key = "gutter_min_digits", .label = "Gutter Min Digits", .kind = .number, .desc = "Minimum width of line number gutter (1-10)" },
    .{ .key = "page_size", .label = "Page Size", .kind = .number, .desc = "Lines to scroll on Page Up/Down (5-200)" },
    .{ .key = "click_clears_cursors", .label = "Click Clears Cursors", .kind = .boolean, .desc = "Left-click clears secondary cursors" },
};

/// Handle mouse clicks in the settings panel overlay.
fn handleSettingsClick(editor: *Editor, p: dvui.Point.Physical, render_area: dvui.Rect.Physical, _: dvui.Font, lh: f32, scale: f32) void {
    const lua_settings = @import("../core/lua_settings.zig");
    const pad: f32 = 8 * scale;
    const total = settings_defs.len;
    const row_h = lh + pad;

    // Recalculate panel geometry (must match drawModalOverlay .settings)
    const panel_h = pad + row_h + @as(f32, @floatFromInt(total)) * row_h + row_h + pad;
    const panel_w = @min(render_area.w * 0.8, 600 * scale);
    const panel_x = render_area.x + (render_area.w - panel_w) / 2;
    const panel_y = render_area.y + (render_area.h - panel_h) / 3;

    // Check if click is outside the panel → close settings
    if (p.x < panel_x or p.x > panel_x + panel_w or
        p.y < panel_y or p.y > panel_y + panel_h)
    {
        editor.mode = .normal;
        editor.settings_editing = null;
        return;
    }

    // First row after title starts at panel_y + pad + row_h
    const rows_start_y = panel_y + pad + row_h;

    // Which setting row was clicked?
    if (p.y < rows_start_y) return; // clicked on title
    const row_offset = p.y - rows_start_y;
    const clicked_row: usize = @intFromFloat(@floor(row_offset / row_h));
    if (clicked_row >= total) return; // clicked on hint bar or below

    // Select the clicked row
    editor.settings_selected = clicked_row;

    // If we're in numeric edit mode for a different row, cancel it
    if (editor.settings_editing) |edit_idx| {
        if (edit_idx != clicked_row) {
            editor.settings_editing = null;
        } else {
            return; // already editing this row, don't re-toggle
        }
    }

    // Toggle/edit the clicked setting (same logic as Enter/Space)
    const def = settings_defs[clicked_row];
    if (def.kind == .boolean) {
        const new_val = !getSettingBool(editor, def.key);
        applySettingBool(editor, def.key, new_val);
        const val_str: []const u8 = if (new_val) "true" else "false";
        lua_settings.writeSettingToFile(def.key, val_str) catch {};
    } else {
        editor.settings_editing = clicked_row;
        const cur_val = getSettingNumber(editor, def.key);
        const written = std.fmt.bufPrint(&editor.settings_num_buf, "{d}", .{cur_val}) catch "";
        editor.settings_num_len = written.len;
    }
}

fn handleSettingsKeyGui(editor: *Editor, key: dvui.Event.Key) void {
    const lua_settings = @import("../core/lua_settings.zig");
    const total = settings_defs.len;

    // If editing a numeric field
    if (editor.settings_editing) |edit_idx| {
        switch (key.code) {
            .escape => {
                editor.settings_editing = null;
            },
            .enter => {
                // Apply the numeric value
                if (editor.settings_num_len > 0) {
                    const num_str = editor.settings_num_buf[0..editor.settings_num_len];
                    const val = std.fmt.parseInt(i64, num_str, 10) catch 0;
                    const def = settings_defs[edit_idx];
                    applySettingNumber(editor, def.key, val);
                    // Write to init.lua
                    lua_settings.writeSettingToFile(def.key, num_str) catch {};
                }
                editor.settings_editing = null;
            },
            .backspace => {
                if (editor.settings_num_len > 0) editor.settings_num_len -= 1;
            },
            else => {},
        }
        return;
    }

    switch (key.code) {
        .escape => {
            editor.mode = .normal;
        },
        .up => {
            editor.settings_selected -|= 1;
        },
        .down => {
            if (editor.settings_selected + 1 < total)
                editor.settings_selected += 1;
        },
        .enter, .space => {
            const def = settings_defs[editor.settings_selected];
            if (def.kind == .boolean) {
                // Toggle boolean
                const new_val = !getSettingBool(editor, def.key);
                applySettingBool(editor, def.key, new_val);
                const val_str: []const u8 = if (new_val) "true" else "false";
                lua_settings.writeSettingToFile(def.key, val_str) catch {};
            } else {
                // Enter numeric edit mode
                editor.settings_editing = editor.settings_selected;
                // Pre-fill with current value
                const cur_val = getSettingNumber(editor, def.key);
                const written = std.fmt.bufPrint(&editor.settings_num_buf, "{d}", .{cur_val}) catch "";
                editor.settings_num_len = written.len;
            }
        },
        else => {},
    }
}

fn getSettingBool(editor: *const Editor, key: []const u8) bool {
    if (std.mem.eql(u8, key, "use_tabs")) return editor.use_tabs;
    if (std.mem.eql(u8, key, "word_wrap")) return editor.word_wrap;
    if (std.mem.eql(u8, key, "auto_close_brackets")) return editor.auto_close_brackets;
    if (std.mem.eql(u8, key, "auto_save")) return editor.auto_save;
    if (std.mem.eql(u8, key, "click_clears_cursors")) return editor.click_clears_cursors;
    return false;
}

fn applySettingBool(editor: *Editor, key: []const u8, val: bool) void {
    if (std.mem.eql(u8, key, "use_tabs")) editor.use_tabs = val;
    if (std.mem.eql(u8, key, "word_wrap")) editor.word_wrap = val;
    if (std.mem.eql(u8, key, "auto_close_brackets")) editor.auto_close_brackets = val;
    if (std.mem.eql(u8, key, "auto_save")) editor.auto_save = val;
    if (std.mem.eql(u8, key, "click_clears_cursors")) editor.click_clears_cursors = val;
}

fn getSettingNumber(editor: *const Editor, key: []const u8) i64 {
    if (std.mem.eql(u8, key, "tab_width")) return @intCast(editor.tab_width);
    if (std.mem.eql(u8, key, "auto_save_interval_ms")) return @intCast(editor.auto_save_interval_ms);
    if (std.mem.eql(u8, key, "gutter_min_digits")) return @intCast(editor.gutter_min_digits);
    if (std.mem.eql(u8, key, "page_size")) return @intCast(editor.page_size);
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
}

/// Open init.lua in the editor as a document.
fn openSettingsFile(editor: *Editor) void {
    const lua_settings = @import("../core/lua_settings.zig");
    const config_path = lua_settings.getConfigPathAlways() orelse return;

    // Ensure directory and file exist
    if (lua_settings.getConfigDir()) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    // Create file if it doesn't exist
    if (std.fs.cwd().access(config_path, .{})) |_| {} else |_| {
        if (std.fs.cwd().createFile(config_path, .{})) |f| {
            f.writeAll("-- ZIDE settings\n-- See Documentation.md for available settings\n") catch {};
            f.close();
        } else |_| {}
    }
    _ = editor.openFile(config_path) catch {};
}

// ===========================================================================
// Search logic (mirrors TUI — operates on Editor state only)
// ===========================================================================

fn guiFindIncremental(editor: *Editor) void {
    const doc = editor.activeDoc();
    const needle = editor.find_buf[0..editor.find_buf_len];
    if (needle.len == 0) {
        doc.cursors.primary().offset = editor.find_origin;
        doc.cursors.primary().anchor = editor.find_origin;
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
    doc.cursors.primary().anchor = editor.find_origin;
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
            doc.deleteSelection() catch {};
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

/// Count total occurrences of needle in the document buffer.
fn guiCountMatches(editor: *Editor, needle: []const u8) usize {
    const doc = editor.activeDoc();
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
fn drawModalOverlay(editor: *Editor, render_area: dvui.Rect.Physical, render_rs: dvui.RectScale, scale: f32) void {
    if (!build_options.has_gui) return;

    const font = dvui.Font.theme(.mono);
    const lh = font.lineHeight() * scale;
    const pad: f32 = 8 * scale;
    const fg = dvui.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const bg = dvui.Color{ .r = 50, .g = 50, .b = 60, .a = 230 };
    const dim = dvui.Color{ .r = 150, .g = 150, .b = 150, .a = 200 };
    const warn_color = dvui.Color{ .r = 255, .g = 100, .b = 100, .a = 255 };

    switch (editor.mode) {
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
            const names = editor.commands.allNames(editor.allocator) catch &[_][]const u8{};
            const names_owned = names.len > 0;
            defer if (names_owned) editor.allocator.free(names);
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
            const sel_highlight = dvui.Color{ .r = 80, .g = 80, .b = 120, .a = 200 };
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
        .settings => {
            const total = settings_defs.len;
            const row_h = lh + pad;
            // Title + settings rows + hint row
            const panel_h = pad + row_h + @as(f32, @floatFromInt(total)) * row_h + row_h + pad;
            // Center the panel
            const panel_w = @min(render_area.w * 0.8, 600 * scale);
            const panel_x = render_area.x + (render_area.w - panel_w) / 2;
            const panel_y = render_area.y + (render_area.h - panel_h) / 3;
            const panel_rect: dvui.Rect.Physical = .{ .x = panel_x, .y = panel_y, .w = panel_w, .h = panel_h };

            // Dim background
            render_area.fill(.{}, .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 140 }, .fade = 1.0 });
            // Panel background
            panel_rect.fill(.{}, .{ .color = bg, .fade = 1.0 });

            var y = panel_y + pad;
            const sel_highlight = dvui.Color{ .r = 80, .g = 80, .b = 120, .a = 200 };

            // Title
            renderOverlayText(font, "Settings", panel_x + pad, y, render_rs, fg);
            y += row_h;

            // Setting rows
            for (settings_defs, 0..) |def, i| {
                const is_selected = i == editor.settings_selected;

                // Highlight bar
                if (is_selected) {
                    const bar: dvui.Rect.Physical = .{ .x = panel_x, .y = y, .w = panel_w, .h = row_h };
                    bar.fill(.{}, .{ .color = sel_highlight, .fade = 1.0 });
                }

                const label_color = if (is_selected) fg else dim;

                // Label
                renderOverlayText(font, def.label, panel_x + pad, y, render_rs, label_color);

                // Value (right-aligned)
                var val_buf: [64]u8 = undefined;
                const val_str = blk: {
                    if (editor.settings_editing != null and editor.settings_editing.? == i) {
                        // Show editable numeric field
                        break :blk std.fmt.bufPrint(&val_buf, "[{s}_]", .{editor.settings_num_buf[0..editor.settings_num_len]}) catch "?";
                    }
                    if (def.kind == .boolean) {
                        const bval = getSettingBool(editor, def.key);
                        break :blk if (bval) "ON" else "OFF";
                    } else {
                        const nval = getSettingNumber(editor, def.key);
                        break :blk std.fmt.bufPrint(&val_buf, "{d}", .{nval}) catch "?";
                    }
                };
                const val_w = font.textSize(val_str).w * scale;
                const val_color = blk: {
                    if (editor.settings_editing != null and editor.settings_editing.? == i) break :blk fg;
                    if (def.kind == .boolean) {
                        break :blk if (getSettingBool(editor, def.key))
                            dvui.Color{ .r = 100, .g = 220, .b = 100, .a = 255 }
                        else
                            dvui.Color{ .r = 180, .g = 80, .b = 80, .a = 255 };
                    }
                    break :blk label_color;
                };
                renderOverlayText(font, val_str, panel_x + panel_w - val_w - pad, y, render_rs, val_color);

                // Description (between label and value, dimmer)
                if (is_selected) {
                    const desc_x = panel_x + pad + font.textSize(def.label).w * scale + pad * 2;
                    const desc_color = dvui.Color{ .r = 120, .g = 120, .b = 140, .a = 200 };
                    renderOverlayText(font, def.desc, desc_x, y, render_rs, desc_color);
                }

                y += row_h;
            }

            // Hint bar
            const hint = if (editor.settings_editing != null)
                "Type value, Enter: apply, Esc: cancel"
            else
                "Click/Up/Down: navigate | Enter/Space/Click: toggle/edit | Esc: close";
            const hint_color = dvui.Color{ .r = 100, .g = 100, .b = 120, .a = 180 };
            renderOverlayText(font, hint, panel_x + pad, y, render_rs, hint_color);
        },
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
