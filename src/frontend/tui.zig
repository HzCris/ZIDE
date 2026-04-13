const std = @import("std");
const vaxis = @import("vaxis");
const Editor = @import("../core/editor.zig").Editor;
const Document = @import("../core/document.zig").Document;

const Key = vaxis.Key;
const Cell = vaxis.Cell;
const Style = vaxis.Style;
const Color = vaxis.Color;
const Window = vaxis.Window;
const Segment = vaxis.Segment;

// ===========================================================================
// Safe text rendering helpers
//
// vaxis printSegment stores *references* into the text slice. If the text
// lives in a stack-local buffer (e.g. bufPrint), the reference becomes
// dangling before vx.render() is called, causing garbage on screen.
//
// These helpers write cell-by-cell using a static lookup table, so every
// grapheme pointer is valid for the program's lifetime.
// ===========================================================================

/// Static lookup: maps each byte value to a persistent 1-byte string.
const ByteLut = struct {
    const data: [256][1]u8 = blk: {
        var d: [256][1]u8 = undefined;
        for (0..256) |i| {
            d[i] = .{@as(u8, @intCast(i))};
        }
        break :blk d;
    };

    fn grapheme(byte: u8) []const u8 {
        return &data[byte];
    }
};

/// Write an ASCII string to the window cell-by-cell (safe for stack buffers).
/// Returns the column after the last character written.
fn writeStr(win: Window, col: u16, row: u16, text: []const u8, style: Style) u16 {
    var x = col;
    for (text) |byte| {
        if (x >= win.width) break;
        win.writeCell(x, row, .{
            .char = .{ .grapheme = ByteLut.grapheme(byte), .width = 1 },
            .style = style,
        });
        x += 1;
    }
    return x;
}

/// Get terminal size on Windows using the console API.
fn getWinsizeWindows() ?vaxis.Winsize {
    const stdout: std.fs.File = .stdout();
    var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(stdout.handle, &info) != 0) {
        const cols: u16 = @intCast(info.srWindow.Right - info.srWindow.Left + 1);
        const rows: u16 = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1);
        return .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 };
    }
    return null;
}

/// Custom event type for our application
const Event = union(enum) {
    key_press: Key,
    key_release: Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

/// When true, the user explicitly scrolled (wheel) so ensureCursorVisible is skipped.
/// Cleared when the cursor moves (key press, click, etc.).
var scroll_pinned: bool = false;

/// Run the TUI editor.
pub fn run(allocator: std.mem.Allocator, editor: *Editor) !void {
    // Initialize TTY
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    // Initialize Vaxis
    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    // Event loop (threaded input reader)
    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    // Enter alternate screen
    try vx.enterAltScreen(tty.writer());

    // On Windows, we can get the initial size directly instead of waiting
    // for a winsize event (which may not arrive on all terminals)
    if (@import("builtin").os.tag == .windows) {
        const winsize = getWinsizeWindows() orelse vaxis.Winsize{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
        try vx.resize(allocator, tty.writer(), winsize);
    } else {
        // Wait for initial resize to get terminal dimensions
        while (true) {
            const event = loop.nextEvent();
            switch (event) {
                .winsize => |ws| {
                    try vx.resize(allocator, tty.writer(), ws);
                    break;
                },
                .key_press => |key| {
                    if (key.matches('q', .{ .ctrl = true })) {
                        editor.running = false;
                        return;
                    }
                },
                else => {},
            }
        }
    }

    // Auto-save timer
    var last_auto_save_ns: i128 = std.time.nanoTimestamp();

    // Main loop
    while (editor.running) {
        // Drain all pending events
        while (loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| dispatchKey(editor, key),
                .mouse => |mouse| handleMouse(editor, mouse),
                .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
                else => {},
            }
        }

        // Auto-save check
        if (editor.auto_save and editor.hasUnsavedChanges()) {
            const now_ns = std.time.nanoTimestamp();
            const elapsed_ms: u64 = @intCast(@divFloor(now_ns - last_auto_save_ns, std.time.ns_per_ms));
            if (elapsed_ms >= editor.auto_save_interval_ms) {
                _ = editor.autoSaveAll();
                last_auto_save_ns = now_ns;
            }
        }

        // Update page_size based on terminal height
        const win = vx.window();
        const width = win.width;
        const height = win.height;
        if (height > 3) {
            editor.page_size = height - 3;
        }

        win.clear();
        vx.refresh = true; // Force full redraw every frame on Windows

        if (height < 3 or width < 10) {
            try vx.render(tty.writer());
            const event = loop.nextEvent();
            switch (event) {
                .key_press => |key| dispatchKey(editor, key),
                .mouse => |mouse| handleMouse(editor, mouse),
                .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
                else => {},
            }
            continue;
        }

        // Draw the editor UI
        drawEditor(win, editor, width, height);

        // Draw overlay if in a special mode (replaces status bar)
        switch (editor.mode) {
            .find => {
                drawOverlay(win, "Find: ", editor.find_buf[0..editor.find_buf_len], width, height);
                // Show search status message (e.g. "No matches found") right-aligned
                if (editor.status_message.len > 0) {
                    const msg_style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 9 } };
                    const overlay_y: u16 = height -| 1;
                    const msg_win = win.child(.{ .y_off = @intCast(overlay_y), .width = width, .height = 1 });
                    const msg_len: u16 = @intCast(@min(editor.status_message.len, width));
                    const msg_x: u16 = width -| msg_len -| 1;
                    _ = writeStr(msg_win, msg_x, 0, editor.status_message, msg_style);
                }
            },
            .find_replace => {
                drawFindReplaceOverlay(win, editor, width, height);
            },
            .file_open => {
                drawOverlay(win, "Open: ", editor.open_buf[0..editor.open_buf_len], width, height);
            },
            .save_as => {
                drawOverlay(win, "Save As: ", editor.open_buf[0..editor.open_buf_len], width, height);
            },
            .command_palette => {
                drawCommandPalette(win, editor, width, height);
            },
            .goto_line => {
                drawOverlay(win, "Go to line: ", editor.goto_buf[0..editor.goto_buf_len], width, height);
            },
            .confirm_quit => {
                drawOverlay(win, "Unsaved changes! [S]ave [D]iscard [C]ancel: ", "", width, height);
            },
            .settings => {
                // Settings panel is GUI-only; in TUI just show a hint
                drawOverlay(win, "Settings: edit ~/.config/zide/init.lua (Esc to close)", "", width, height);
            },
            .normal => positionCursor(win, editor, width, height),
        }

        try vx.render(tty.writer());

        // Block until next event
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| dispatchKey(editor, key),
            .mouse => |mouse| handleMouse(editor, mouse),
            .winsize => |ws| try vx.resize(allocator, tty.writer(), ws),
            else => {},
        }
    }
}

/// Dispatch key based on current editor mode.
fn dispatchKey(editor: *Editor, key: Key) void {
    switch (editor.mode) {
        .normal => handleKey(editor, key),
        .find => handleFindKey(editor, key),
        .find_replace => handleFindReplaceKey(editor, key),
        .file_open => handleFileOpenKey(editor, key),
        .save_as => handleSaveAsKey(editor, key),
        .command_palette => handlePaletteKey(editor, key),
        .goto_line => handleGotoLineKey(editor, key),
        .confirm_quit => handleConfirmQuitKey(editor, key),
        .settings => {
            // Settings panel is GUI-only; Escape returns to normal
            if (key.codepoint == 0x1b) editor.mode = .normal; // Escape
        },
    }
}

/// Draw the full editor screen.
fn drawEditor(win: Window, editor: *Editor, width: u16, height: u16) void {
    const doc = editor.activeDoc();
    const tab_bar_height: u16 = if (editor.docCount() > 1) 1 else 0;
    const status_height: u16 = 1;
    const editor_height = height -| tab_bar_height -| status_height;

    // Update text_width for visual-row movement
    const total_lines = doc.lineCount();
    const gutter_w = lineNumberWidth(total_lines);
    const tw: u16 = if (width > gutter_w + 1) width - gutter_w - 1 else 1;
    editor.text_width = tw;

    // Ensure cursor is visible (unless user is scrolling with wheel)
    if (!scroll_pinned) {
        if (editor.word_wrap) {
            doc.scroll_left = 0;
            ensureCursorVisibleWrapped(doc, editor_height, width);
        } else {
            doc.ensureCursorVisible(editor_height, width -| 5);
        }
    }

    // Tab bar
    if (tab_bar_height > 0) {
        const tab_win = win.child(.{ .y_off = 0, .height = 1, .width = width });
        drawTabBar(tab_win, editor, width);
    }

    // Editor content
    const content_win = win.child(.{
        .y_off = @intCast(tab_bar_height),
        .height = editor_height,
        .width = width,
    });
    drawContent(content_win, doc, width, editor_height, editor.word_wrap);

    // Draw secondary cursors as reverse-video cells
    if (doc.cursors.count() > 1) {
        drawSecondaryCursors(content_win, doc, width, editor_height, editor.word_wrap);
    }

    // Status bar
    const status_win = win.child(.{
        .y_off = @intCast(height - 1),
        .height = 1,
        .width = width,
    });
    drawStatusBar(status_win, editor, width);
}

/// Draw the tab bar.
fn drawTabBar(win: Window, editor: *Editor, width: u16) void {
    const bg_style: Style = .{ .bg = .{ .index = 8 }, .fg = .{ .index = 15 } }; // bright_black bg, white fg
    const active_style: Style = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 }, .bold = true }; // blue bg, bright_white fg

    // Fill background
    win.fill(.{ .style = bg_style });

    var x: u16 = 0;
    for (editor.documents.items, 0..) |doc, i| {
        const is_active = (i == editor.active_doc_idx);
        const style = if (is_active) active_style else bg_style;

        // Draw " name(*) |"
        x = writeStr(win, x, 0, " ", style);
        // display_name is heap-allocated, persistent — safe for printSegment
        if (x < width) {
            _ = win.printSegment(.{ .text = doc.display_name, .style = style }, .{ .col_offset = x, .wrap = .none });
            x +|= @intCast(@min(doc.display_name.len, width -| x));
        }
        if (doc.dirty) x = writeStr(win, x, 0, "*", style);
        x = writeStr(win, x, 0, " ", style);
        x = writeStr(win, x, 0, "|", bg_style);
    }
}

// ===========================================================================
// Word-wrap helpers (display-width aware, UTF-8 safe)
// ===========================================================================

/// Count the display width of a text slice.
/// Each non-continuation byte counts as 1 column (ASCII and UTF-8 lead bytes).
/// Continuation bytes (10xxxxxx) are skipped.
fn displayWidth(text: []const u8) usize {
    var w: usize = 0;
    for (text) |byte| {
        if ((byte & 0xC0) != 0x80) w += 1;
    }
    return w;
}

/// Advance through `line` starting at `start_pos`, consuming up to `text_width`
/// display columns. Returns the byte end position for this visual row.
/// Uses word-boundary wrapping: prefers breaking after spaces.
fn wrapAdvanceRow(line: []const u8, text_width: usize, start_pos: usize) usize {
    if (text_width == 0) return line.len;
    var pos = start_pos;
    var col: usize = 0;
    var last_space: ?usize = null;

    while (pos < line.len) {
        const byte = line[pos];
        if ((byte & 0xC0) != 0x80) { // character start
            if (col >= text_width) break; // this char would exceed width
            if (byte == ' ') last_space = pos + 1; // break after space
            col += 1;
        }
        pos += 1;
    }

    // If we hit the width limit and there's more text, try word break
    if (pos < line.len) {
        if (last_space) |sp| {
            if (sp > start_pos) return sp;
        }
    }
    return pos;
}

/// Count how many visual rows a line occupies with word wrapping.
fn wrapLineRows(line: []const u8, text_width: u16) u16 {
    if (text_width == 0 or line.len == 0) return 1;
    const tw: usize = text_width;
    var rows: u16 = 0;
    var pos: usize = 0;
    while (pos < line.len) {
        pos = wrapAdvanceRow(line, tw, pos);
        rows += 1;
    }
    return if (rows == 0) 1 else rows;
}

/// Given a byte column within a line, find which visual wrap row it falls on
/// and what display column within that row.
fn wrapColToVisual(line: []const u8, text_width: u16, byte_col: usize) struct { row: u16, col: u16 } {
    if (text_width == 0) return .{ .row = 0, .col = @intCast(@min(byte_col, 65535)) };
    const tw: usize = text_width;
    var visual_row: u16 = 0;
    var pos: usize = 0;

    while (pos < line.len) {
        const row_start = pos;
        pos = wrapAdvanceRow(line, tw, pos);
        const row_end = pos;

        if (byte_col < row_end or pos >= line.len) {
            const clamped = @min(byte_col, row_end);
            const effective_start = @min(row_start, clamped);
            const dcol = displayWidth(line[effective_start..clamped]);
            return .{ .row = visual_row, .col = @intCast(@min(dcol, 65535)) };
        }
        visual_row += 1;
    }
    // Cursor at end of empty line
    return .{ .row = visual_row, .col = 0 };
}

/// Move cursor up or down by one visual (wrapped) row.
/// When word wrap is on, this moves through screen rows rather than logical lines.
fn moveVisualVertical(editor: *Editor, direction: enum { up, down }, extend_selection: bool) void {
    const doc = editor.activeDoc();
    const buf = &doc.buffer;
    const total_lines = doc.lineCount();
    const text_width: u16 = editor.text_width;

    if (text_width == 0) return;

    for (doc.cursors.cursors.items) |*c| {
        const pos = buf.offsetToPos(c.offset);
        const cur_line = doc.lineContent(pos.line);
        const wrap_pos = wrapColToVisual(cur_line, text_width, pos.col);

        if (!extend_selection) {
            c.clearSelection();
        } else if (!c.hasSelection()) {
            c.startSelection();
        }

        switch (direction) {
            .up => {
                if (wrap_pos.row > 0) {
                    const target_col = wrapVisualToCol(cur_line, text_width, wrap_pos.row - 1, c.preferred_col);
                    c.offset = buf.posToOffset(pos.line, target_col);
                } else if (pos.line > 0) {
                    const prev_line = doc.lineContent(pos.line - 1);
                    const prev_rows = wrapLineRows(prev_line, text_width);
                    const target_col = wrapVisualToCol(prev_line, text_width, prev_rows - 1, c.preferred_col);
                    c.offset = buf.posToOffset(pos.line - 1, target_col);
                }
            },
            .down => {
                const cur_rows = wrapLineRows(cur_line, text_width);
                if (wrap_pos.row + 1 < cur_rows) {
                    const target_col = wrapVisualToCol(cur_line, text_width, wrap_pos.row + 1, c.preferred_col);
                    c.offset = buf.posToOffset(pos.line, target_col);
                } else if (pos.line + 1 < total_lines) {
                    const next_line = doc.lineContent(pos.line + 1);
                    const target_col = wrapVisualToCol(next_line, text_width, 0, c.preferred_col);
                    c.offset = buf.posToOffset(pos.line + 1, target_col);
                }
            },
        }
    }
    doc.cursors.mergeCursors();
}

/// Dispatch a keybind action with TUI-specific overrides (visual-row multi-cursor).
fn execTuiAction(editor: *Editor, action: []const u8) void {
    if (editor.word_wrap) {
        if (std.mem.eql(u8, action, "add_cursor_above")) {
            tuiAddCursorVisual(editor, .up);
            return;
        }
        if (std.mem.eql(u8, action, "add_cursor_below")) {
            tuiAddCursorVisual(editor, .down);
            return;
        }
    }
    _ = editor.execAction(action);
}

/// Add a new cursor one visual (wrapped) row above or below the outermost cursor.
fn tuiAddCursorVisual(editor: *Editor, direction: enum { up, down }) void {
    const doc = editor.activeDoc();
    const buf = &doc.buffer;
    const total_lines = doc.lineCount();
    const text_width: u16 = editor.text_width;

    if (text_width == 0) return;

    // Find the outermost cursor in the given direction
    var edge_idx: usize = 0;
    var edge_line: usize = if (direction == .up) std.math.maxInt(usize) else 0;
    var edge_wrap_row: u16 = 0;
    for (doc.cursors.cursors.items, 0..) |c, i| {
        const pos = buf.offsetToPos(c.offset);
        const wrap_pos = wrapColToVisual(doc.lineContent(pos.line), text_width, pos.col);
        switch (direction) {
            .up => if (pos.line < edge_line or (pos.line == edge_line and wrap_pos.row < edge_wrap_row)) {
                edge_line = pos.line;
                edge_wrap_row = wrap_pos.row;
                edge_idx = i;
            },
            .down => if (pos.line > edge_line or (pos.line == edge_line and wrap_pos.row > edge_wrap_row)) {
                edge_line = pos.line;
                edge_wrap_row = wrap_pos.row;
                edge_idx = i;
            },
        }
    }

    const ref_cursor = doc.cursors.cursors.items[edge_idx];
    const cur_line = doc.lineContent(edge_line);

    switch (direction) {
        .up => {
            if (edge_wrap_row > 0) {
                const target_col = wrapVisualToCol(cur_line, text_width, edge_wrap_row - 1, ref_cursor.preferred_col);
                doc.cursors.addCursor(buf.posToOffset(edge_line, target_col)) catch {};
            } else if (edge_line > 0) {
                const prev_line = doc.lineContent(edge_line - 1);
                const prev_rows = wrapLineRows(prev_line, text_width);
                const target_col = wrapVisualToCol(prev_line, text_width, prev_rows - 1, ref_cursor.preferred_col);
                doc.cursors.addCursor(buf.posToOffset(edge_line - 1, target_col)) catch {};
            }
        },
        .down => {
            const cur_rows = wrapLineRows(cur_line, text_width);
            if (edge_wrap_row + 1 < cur_rows) {
                const target_col = wrapVisualToCol(cur_line, text_width, edge_wrap_row + 1, ref_cursor.preferred_col);
                doc.cursors.addCursor(buf.posToOffset(edge_line, target_col)) catch {};
            } else if (edge_line + 1 < total_lines) {
                const next_line = doc.lineContent(edge_line + 1);
                const target_col = wrapVisualToCol(next_line, text_width, 0, ref_cursor.preferred_col);
                doc.cursors.addCursor(buf.posToOffset(edge_line + 1, target_col)) catch {};
            }
        },
    }
}

/// Convert a visual row and preferred display column to a byte column within a line.
/// Finds the byte offset at the given visual wrap row that corresponds to the
/// desired display column.
fn wrapVisualToCol(line: []const u8, text_width: u16, target_row: u16, preferred_dcol: usize) usize {
    if (text_width == 0) return 0;
    const tw: usize = text_width;
    var row: u16 = 0;
    var pos: usize = 0;

    while (pos < line.len) {
        const row_start = pos;
        pos = wrapAdvanceRow(line, tw, pos);

        if (row == target_row) {
            // Walk through this row's bytes to find the byte at preferred_dcol
            var dcol: usize = 0;
            var byte_pos = row_start;
            while (byte_pos < pos) {
                if (dcol >= preferred_dcol) return byte_pos;
                if ((line[byte_pos] & 0xC0) != 0x80) dcol += 1;
                byte_pos += 1;
            }
            // For non-final rows, clamp to the last character start within
            // the row so wrapColToVisual maps it to this row, not the next.
            if (pos < line.len and byte_pos > row_start) {
                byte_pos -= 1;
                while (byte_pos > row_start and (line[byte_pos] & 0xC0) == 0x80) {
                    byte_pos -= 1;
                }
                return byte_pos;
            }
            return @min(byte_pos, line.len);
        }
        row += 1;
    }
    return line.len;
}

/// Ensure the cursor is visible when word wrapping is active.
/// Accounts for variable visual row heights per logical line.
fn ensureCursorVisibleWrapped(doc: *Document, editor_height: u16, width: u16) void {
    if (editor_height == 0) return;
    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines);
    const text_start_x = gutter_width + 1;
    const text_width: u16 = if (width > text_start_x) width - text_start_x else 1;
    const cursor_pos = doc.cursorPos();

    // If cursor line is above scroll_top, scroll up to it
    if (cursor_pos.line < doc.scroll_top) {
        doc.scroll_top = cursor_pos.line;
        return;
    }

    // Compute visual rows from scroll_top to cursor
    var visual_rows: u16 = 0;
    var line_idx: usize = doc.scroll_top;
    while (line_idx < cursor_pos.line and line_idx < total_lines) : (line_idx += 1) {
        visual_rows +|= wrapLineRows(doc.lineContent(line_idx), text_width);
    }
    // Add cursor's row within its wrapped line
    const cur_line = doc.lineContent(cursor_pos.line);
    const wrap_pos = wrapColToVisual(cur_line, text_width, cursor_pos.col);
    const cursor_visual_row = visual_rows +| wrap_pos.row;

    // If cursor is visible, done
    if (cursor_visual_row < editor_height) return;

    // Cursor is below viewport — scroll down.
    // Strategy: set scroll_top so cursor ends up ~1/3 from bottom.
    const target_row: u16 = editor_height *| 2 / 3;
    // Walk backward from cursor line to find scroll_top
    var rows_needed: u16 = wrap_pos.row; // rows within cursor's own line above cursor
    var new_top: usize = cursor_pos.line;
    while (new_top > 0 and rows_needed < target_row) {
        new_top -= 1;
        rows_needed +|= wrapLineRows(doc.lineContent(new_top), text_width);
    }
    // If we overshot, new_top is the right starting line
    doc.scroll_top = new_top;
}

/// Draw the editor content area with line numbers and optional word wrap.
fn drawContent(win: Window, doc: *Document, width: u16, height: u16, wrap: bool) void {
    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines);
    const text_start_x = gutter_width + 1; // +1 for separator
    const text_width: u16 = if (width > text_start_x) width - text_start_x else 1;

    const cursor_pos = doc.cursorPos();

    const line_num_style: Style = .{ .fg = .{ .index = 8 } }; // bright_black
    const line_num_active_style: Style = .{ .fg = .{ .index = 15 } }; // bright_white
    const gutter_sep_style: Style = .{ .fg = .{ .index = 8 } }; // bright_black
    const text_style: Style = .{ .fg = .{ .index = 15 } }; // white
    const sel_style: Style = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 } }; // blue bg for selection
    const tilde_style: Style = .{ .fg = .{ .index = 8 } }; // bright_black
    const wrap_marker_style: Style = .{ .fg = .{ .index = 8 } }; // dim for wrap continuation

    // Get selection range if any
    const sel = doc.cursors.primaryConst().selectionRange();

    var y: u16 = 0;
    var line_idx: usize = doc.scroll_top;

    while (y < height and line_idx < total_lines) {
        const line = doc.lineContent(line_idx);
        const is_current = (line_idx == cursor_pos.line);
        const num_style = if (is_current) line_num_active_style else line_num_style;

        // Iterate visual rows for this logical line
        var wrap_row: u16 = 0;
        var byte_pos: usize = 0;
        const do_wrap = wrap and displayWidth(line) > text_width;

        while (y < height) {
            const row_start = byte_pos;
            const row_end = if (do_wrap)
                wrapAdvanceRow(line, text_width, byte_pos)
            else
                line.len;

            // Line number: only on first row of a logical line
            if (wrap_row == 0) {
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_idx + 1}) catch "";
                const num_len: u16 = @intCast(num_str.len);
                const padding = gutter_width -| @min(num_len, gutter_width);
                _ = writeStr(win, padding, y, num_str, num_style);
            } else {
                // Wrap continuation marker
                _ = writeStr(win, gutter_width -| 1, y, ".", wrap_marker_style);
            }

            // Gutter separator
            _ = writeStr(win, gutter_width, y, " ", gutter_sep_style);

            // Text content for this row
            if (text_start_x < width) {
                const visible_start: usize = if (do_wrap) row_start else doc.scroll_left;
                const segment_start = @min(visible_start, line.len);
                const segment_end = if (do_wrap) row_end else @min(line.len, visible_start + text_width);
                const segment = line[segment_start..segment_end];

                if (segment.len > 0) {
                    const text_win = win.child(.{
                        .x_off = @intCast(text_start_x),
                        .y_off = @intCast(y),
                        .width = text_width,
                        .height = 1,
                    });

                    // Check if any part of this segment is selected
                    if (sel) |s| {
                        const line_start_offset = doc.buffer.posToOffset(line_idx, 0);
                        const abs_seg_start = line_start_offset + segment_start;
                        const abs_seg_end = line_start_offset + segment_end;

                        if (s.start < abs_seg_end and s.end > abs_seg_start) {
                            // Map selection to segment-local byte offsets
                            const sel_begin = if (s.start > abs_seg_start) s.start - abs_seg_start else 0;
                            const sel_end_local = if (s.end < abs_seg_end) s.end - abs_seg_start else segment.len;

                            var col: u16 = 0;
                            if (sel_begin > 0) {
                                col = @intCast(@min(displayWidth(segment[0..sel_begin]), text_width));
                                _ = writeStr(text_win, 0, 0, segment[0..sel_begin], text_style);
                            }
                            if (sel_end_local > sel_begin) {
                                const sel_w: u16 = @intCast(@min(displayWidth(segment[sel_begin..sel_end_local]), text_width -| col));
                                _ = writeStr(text_win, col, 0, segment[sel_begin..sel_end_local], sel_style);
                                col +|= sel_w;
                            }
                            if (sel_end_local < segment.len) {
                                _ = writeStr(text_win, col, 0, segment[sel_end_local..], text_style);
                            }
                        } else {
                            _ = writeStr(text_win, 0, 0, segment, text_style);
                        }
                    } else {
                        _ = writeStr(text_win, 0, 0, segment, text_style);
                    }
                }
            }

            y += 1;
            wrap_row += 1;
            byte_pos = row_end;

            // If not wrapping or reached end of line, move to next logical line
            if (!do_wrap or byte_pos >= line.len) break;
        }

        line_idx += 1;
    }

    // Fill remaining rows with tildes
    while (y < height) : (y += 1) {
        _ = writeStr(win, 0, y, "~", tilde_style);
    }
}

/// Draw secondary cursors as reverse-video cells.
fn drawSecondaryCursors(win: Window, doc: *Document, width: u16, height: u16, wrap: bool) void {
    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines);
    const text_start_x = gutter_width + 1;
    const text_width: u16 = if (width > text_start_x) width - text_start_x else 1;
    const cursor_style: Style = .{ .bg = .{ .index = 15 }, .fg = .{ .index = 0 } }; // reverse video

    // Skip primary cursor (index 0), render the rest
    for (doc.cursors.cursors.items[1..]) |c| {
        const pos = doc.buffer.offsetToPos(c.offset);
        if (pos.line < doc.scroll_top) continue;

        // Calculate screen position
        var screen_y: u16 = undefined;
        var screen_x: u16 = undefined;

        if (wrap) {
            // Sum visual rows of lines before this one
            var visual_row: u16 = 0;
            var li: usize = doc.scroll_top;
            while (li < pos.line and li < total_lines) : (li += 1) {
                visual_row += wrapLineRows(doc.lineContent(li), text_width);
                if (visual_row >= height) break;
            }
            if (visual_row >= height) continue;
            const cur_line = doc.lineContent(pos.line);
            const wp = wrapColToVisual(cur_line, text_width, pos.col);
            screen_y = visual_row + wp.row;
            screen_x = text_start_x +| wp.col;
        } else {
            const visible_line = pos.line -| doc.scroll_top;
            if (visible_line >= height) continue;
            screen_y = @intCast(visible_line);
            const visible_col = pos.col -| doc.scroll_left;
            screen_x = text_start_x +| @as(u16, @intCast(@min(visible_col, width -| text_start_x)));
        }

        if (screen_y < height and screen_x < width) {
            // Draw a reverse-video block at the cursor position
            const line = doc.lineContent(pos.line);
            if (pos.col < line.len and line[pos.col] >= 32) {
                // Show the actual character in reverse video
                _ = writeStr(win, screen_x, screen_y, line[pos.col .. pos.col + 1], cursor_style);
            } else {
                // At end of line or control char — draw a space in reverse
                _ = writeStr(win, screen_x, screen_y, " ", cursor_style);
            }
        }
    }
}

/// Draw the status bar.
fn drawStatusBar(win: Window, editor: *Editor, width: u16) void {
    const style: Style = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 }, .bold = true }; // blue bg, bright white fg

    // Fill background
    win.fill(.{ .style = style });

    const doc = editor.activeDocConst();
    const pos = doc.cursorPos();

    // Left side: " filename [+]" — use writeStr for formatted parts
    var x: u16 = writeStr(win, 0, 0, " ", style);
    // display_name is heap-allocated and persistent, safe for printSegment
    _ = win.printSegment(.{ .text = doc.display_name, .style = style }, .{ .col_offset = x, .wrap = .none });
    x +|= @intCast(@min(doc.display_name.len, width -| x));
    if (doc.dirty) {
        _ = writeStr(win, x, 0, " [+]", style);
    }

    // Right side: cursor position — use writeStr (stack buffer)
    var right_buf: [64]u8 = undefined;
    const cursor_count = doc.cursors.count();
    const right = if (cursor_count > 1)
        std.fmt.bufPrint(&right_buf, "{d} cursors | Ln {d}, Col {d} ", .{ cursor_count, pos.line + 1, pos.col + 1 }) catch ""
    else
        std.fmt.bufPrint(&right_buf, "Ln {d}, Col {d} ", .{ pos.line + 1, pos.col + 1 }) catch "";
    const right_len: u16 = @intCast(@min(right.len, width));
    const right_x = width -| right_len;
    _ = writeStr(win, right_x, 0, right, style);
}

/// Calculate gutter width needed for line numbers.
fn lineNumberWidth(total_lines: usize) u16 {
    var digits: u16 = 1;
    var n = total_lines;
    while (n >= 10) {
        n /= 10;
        digits += 1;
    }
    return @max(digits, 3); // minimum 3 chars
}

/// Position the real terminal cursor at the editor cursor location.
fn positionCursor(win: Window, editor: *Editor, width: u16, height: u16) void {
    const doc = editor.activeDocConst();
    const pos = doc.cursorPos();

    const tab_bar_height: u16 = if (editor.docCount() > 1) 1 else 0;
    const status_height: u16 = 1;
    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines);
    const text_start_x = gutter_width + 1;
    const text_width: u16 = if (width > text_start_x) width - text_start_x else 1;

    if (editor.word_wrap) {
        // With wrapping: compute visual row by summing wrapped heights of preceding lines
        var visual_row: u16 = 0;
        var line_idx: usize = doc.scroll_top;
        while (line_idx < pos.line and line_idx < total_lines) : (line_idx += 1) {
            visual_row += wrapLineRows(doc.lineContent(line_idx), text_width);
        }
        // Add the cursor's position within its wrapped line
        const cur_line = doc.lineContent(pos.line);
        const wrap_pos = wrapColToVisual(cur_line, text_width, pos.col);
        visual_row += wrap_pos.row;

        const screen_y = tab_bar_height +| visual_row;
        const screen_x = text_start_x +| wrap_pos.col;

        if (screen_y < height -| status_height and screen_x < width) {
            win.showCursor(screen_x, screen_y);
            win.setCursorShape(.beam_blink);
        } else {
            win.hideCursor();
        }
    } else {
        const visible_line = pos.line -| doc.scroll_top;
        const visible_col = pos.col -| doc.scroll_left;

        const screen_y: u16 = @intCast(@min(visible_line + tab_bar_height, height -| status_height -| 1));
        const screen_x: u16 = text_start_x +| @as(u16, @intCast(@min(visible_col, width -| text_start_x)));

        if (screen_y < height -| status_height and screen_x < width) {
            win.showCursor(screen_x, screen_y);
            win.setCursorShape(.beam_blink);
        } else {
            win.hideCursor();
        }
    }
}

/// Convert a screen position (x, y) in the editor area to a buffer offset.
/// Returns null if the position is outside the editor content area.
fn screenToOffset(editor: *const Editor, screen_x: i16, screen_y: i16) ?usize {
    const doc = editor.activeDocConst();
    const total_lines = doc.lineCount();
    const tab_bar_height: i16 = if (editor.docCount() > 1) 1 else 0;
    const gutter_width = lineNumberWidth(total_lines);
    const text_start_x: i16 = @intCast(gutter_width + 1);

    // Must be in the text area
    if (screen_x < text_start_x or screen_y < tab_bar_height) return null;
    const text_col: usize = @intCast(screen_x - text_start_x);
    const content_row: usize = @intCast(screen_y - tab_bar_height);

    if (editor.word_wrap) {
        const text_width = editor.text_width;
        // Walk through visible lines, counting visual rows
        var visual_row: usize = 0;
        var line_idx: usize = doc.scroll_top;
        while (line_idx < total_lines) : (line_idx += 1) {
            const line = doc.lineContent(line_idx);
            const rows = wrapLineRows(line, text_width);
            if (content_row < visual_row + rows) {
                // Click is on this logical line, in visual row (content_row - visual_row)
                const wrap_row: u16 = @intCast(content_row - visual_row);
                const byte_col = wrapVisualToCol(line, text_width, wrap_row, text_col);
                return doc.buffer.posToOffset(line_idx, byte_col);
            }
            visual_row += rows;
        }
        // Click below last line — go to end
        return doc.buffer.byteLen();
    } else {
        const target_line = doc.scroll_top + content_row;
        if (target_line >= total_lines) return doc.buffer.byteLen();
        const col = doc.scroll_left + text_col;
        const line_len = doc.lineContent(target_line).len;
        return doc.buffer.posToOffset(target_line, @min(col, line_len));
    }
}

/// Handle mouse events.
fn handleMouse(editor: *Editor, mouse: vaxis.Mouse) void {
    if (editor.mode != .normal) return; // ignore mouse in overlay modes

    switch (mouse.button) {
        .left => {
            if (mouse.type == .press) {
                // Click: position cursor — also un-pin scroll
                scroll_pinned = false;
                if (screenToOffset(editor, mouse.col, mouse.row)) |offset| {
                    const doc = editor.activeDoc();
                    if (mouse.mods.alt) {
                        // Alt+click: add cursor at click position
                        doc.cursors.addCursor(offset) catch {};
                    } else {
                        // Regular click: clear secondary cursors if enabled
                        if (editor.click_clears_cursors and doc.cursors.count() > 1) {
                            doc.cursors.clearSecondary();
                        }
                        const c = doc.cursors.primary();
                        c.clearSelection();
                        c.offset = offset;
                        c.preferred_col = doc.buffer.offsetToPos(offset).col;
                    }
                }
            } else if (mouse.type == .drag) {
                // Drag: extend selection
                if (screenToOffset(editor, mouse.col, mouse.row)) |offset| {
                    const c = editor.activeDoc().cursors.primary();
                    if (!c.hasSelection()) c.startSelection();
                    c.offset = offset;
                    c.preferred_col = editor.activeDoc().buffer.offsetToPos(offset).col;
                }
            }
        },
        .wheel_up => {
            const doc = editor.activeDoc();
            doc.scroll_top -|= 5;
            scroll_pinned = true;
        },
        .wheel_down => {
            const doc = editor.activeDoc();
            const max_top = doc.lineCount() -| 1;
            doc.scroll_top = @min(doc.scroll_top + 5, max_top);
            scroll_pinned = true;
        },
        else => {},
    }
}

/// Convert a vaxis Key to a keybind lookup string.
/// Format: [ctrl+][alt+][shift+]<keyname>
/// Shift is only included for non-letter keys (arrows, home, etc.)
fn keyToStr(key: Key, buf: *[64]u8) []const u8 {
    var pos: usize = 0;

    if (key.mods.ctrl) {
        @memcpy(buf[pos .. pos + 5], "ctrl+");
        pos += 5;
    }
    if (key.mods.alt) {
        @memcpy(buf[pos .. pos + 4], "alt+");
        pos += 4;
    }

    if (key.mods.shift) {
        @memcpy(buf[pos .. pos + 6], "shift+");
        pos += 6;
    }

    // Map codepoint to key name
    const name: ?[]const u8 = switch (key.codepoint) {
        Key.up => "up",
        Key.down => "down",
        Key.left => "left",
        Key.right => "right",
        Key.home => "home",
        Key.end => "end",
        Key.page_up => "page_up",
        Key.page_down => "page_down",
        Key.backspace => "backspace",
        Key.delete => "delete",
        Key.tab => "tab",
        Key.enter => "enter",
        Key.escape => "escape",
        else => null,
    };

    if (name) |n| {
        if (pos + n.len <= 64) {
            @memcpy(buf[pos .. pos + n.len], n);
            pos += n.len;
        }
        return buf[0..pos];
    }

    // Letters — use lowercase
    if (key.codepoint >= 'A' and key.codepoint <= 'Z') {
        buf[pos] = @intCast(key.codepoint + 32);
        return buf[0 .. pos + 1];
    }
    if (key.codepoint >= 'a' and key.codepoint <= 'z') {
        buf[pos] = @intCast(key.codepoint);
        return buf[0 .. pos + 1];
    }
    // Other printable ASCII
    if (key.codepoint >= 32 and key.codepoint < 127) {
        buf[pos] = @intCast(key.codepoint);
        return buf[0 .. pos + 1];
    }

    return buf[0..0];
}

/// Handle a keyboard event from libvaxis.
fn handleKey(editor: *Editor, key: Key) void {
    // Ignore modifier-only keys
    if (key.isModifier()) return;

    // Any key press un-pins scroll (cursor tracking resumes)
    scroll_pinned = false;

    // Ctrl/Alt+key shortcuts — look up in keybind map
    if (key.mods.ctrl or key.mods.alt) {
        var kbuf: [64]u8 = undefined;
        const key_str = keyToStr(key, &kbuf);
        if (key_str.len > 0) {
            if (editor.keybinds.get(key_str)) |action| {
                execTuiAction(editor, action);
                return;
            }
            // Fallback: if shift was held, try without shift
            // (e.g. Ctrl+Shift+K falls back to Ctrl+K binding)
            if (key.mods.shift) {
                var kbuf2: [64]u8 = undefined;
                var fallback_key = key;
                fallback_key.mods.shift = false;
                const fallback_str = keyToStr(fallback_key, &kbuf2);
                if (fallback_str.len > 0) {
                    if (editor.keybinds.get(fallback_str)) |action| {
                        execTuiAction(editor, action);
                        return;
                    }
                }
            }
        }
        return;
    }

    // Movement keys — check shift for selection-extending variants
    const shift = key.mods.shift;
    switch (key.codepoint) {
        Key.up => {
            if (editor.word_wrap) {
                moveVisualVertical(editor, .up, shift);
            } else {
                _ = editor.execCommand(if (shift) "cursor_up_select" else "cursor_up", null);
            }
            return;
        },
        Key.down => {
            if (editor.word_wrap) {
                moveVisualVertical(editor, .down, shift);
            } else {
                _ = editor.execCommand(if (shift) "cursor_down_select" else "cursor_down", null);
            }
            return;
        },
        Key.left => {
            _ = editor.execCommand(if (shift) "cursor_left_select" else "cursor_left", null);
            return;
        },
        Key.right => {
            _ = editor.execCommand(if (shift) "cursor_right_select" else "cursor_right", null);
            return;
        },
        Key.home => {
            _ = editor.execCommand(if (shift) "smart_home_select" else "smart_home", null);
            return;
        },
        Key.end => {
            _ = editor.execCommand(if (shift) "cursor_end_select" else "cursor_end", null);
            return;
        },
        Key.page_up => {
            _ = editor.execCommand("page_up", null);
            return;
        },
        Key.page_down => {
            _ = editor.execCommand("page_down", null);
            return;
        },
        Key.backspace => {
            _ = editor.execCommand("delete_backward", null);
            return;
        },
        Key.delete => {
            _ = editor.execCommand("delete_forward", null);
            return;
        },
        Key.enter => {
            _ = editor.execCommand("insert_newline_auto", null);
            return;
        },
        Key.tab => {
            if (shift or key.matches(Key.tab, .{ .shift = true })) {
                _ = editor.execCommand("dedent", null);
            } else {
                _ = editor.execCommand("indent", null);
            }
            return;
        },
        Key.escape => {
            _ = editor.execCommand("escape_multicursor", null);
            return;
        },
        else => {},
    }

    // Regular character input — use text if available, otherwise encode codepoint
    if (key.text) |text| {
        if (text.len > 0) {
            _ = editor.execCommand("insert_char", text);
        }
    } else if (key.codepoint >= 32 and key.codepoint < 127) {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(key.codepoint), &buf) catch return;
        _ = editor.execCommand("insert_char", buf[0..len]);
    }
}

// ===========================================================================
// Overlay drawing
// ===========================================================================

/// Draw a single-line input overlay on the status bar line.
fn drawOverlay(win: Window, label: []const u8, input: []const u8, width: u16, height: u16) void {
    const overlay_y: u16 = height -| 1;
    const overlay_win = win.child(.{
        .y_off = @intCast(overlay_y),
        .width = width,
        .height = 1,
    });
    const style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 14 }, .bold = true }; // cyan on black
    const input_style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 15 } }; // white on black
    overlay_win.fill(.{ .style = style });

    _ = overlay_win.printSegment(.{ .text = label, .style = style }, .{ .wrap = .none });
    const label_len: u16 = @intCast(@min(label.len, width));
    if (label_len < width and input.len > 0) {
        const input_win = overlay_win.child(.{ .x_off = @intCast(label_len), .width = width -| label_len });
        _ = input_win.printSegment(.{ .text = input, .style = input_style }, .{ .wrap = .none });
    }

    // Show cursor in the overlay
    const cursor_col = label_len +| @as(u16, @intCast(@min(input.len, width -| label_len)));
    if (cursor_col < width) {
        win.showCursor(cursor_col, overlay_y);
        win.setCursorShape(.beam_blink);
    }
}

/// Draw the command palette overlay.
fn drawCommandPalette(win: Window, editor: *Editor, width: u16, height: u16) void {
    const filter = editor.palette_buf[0..editor.palette_buf_len];

    // Draw the input line
    const input_y: u16 = height / 3;
    const palette_width: u16 = @min(width -| 4, 60);
    const palette_x: u16 = (width -| palette_width) / 2;

    const border_style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 6 } }; // cyan border
    const input_style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 15 }, .bold = true };
    const item_style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 15 } };
    const match_style: Style = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 }, .bold = true };
    _ = match_style;

    // Header
    const header_win = win.child(.{ .x_off = @intCast(palette_x), .y_off = @intCast(input_y), .width = palette_width, .height = 1 });
    header_win.fill(.{ .style = border_style });
    _ = header_win.printSegment(.{ .text = "> ", .style = border_style }, .{ .wrap = .none });
    if (filter.len > 0) {
        const filter_win = header_win.child(.{ .x_off = 2, .width = palette_width -| 2 });
        _ = filter_win.printSegment(.{ .text = filter, .style = input_style }, .{ .wrap = .none });
    }

    // Show cursor
    const cursor_col = palette_x + 2 + @as(u16, @intCast(@min(filter.len, palette_width -| 2)));
    win.showCursor(cursor_col, input_y);
    win.setCursorShape(.beam_blink);

    // List matching commands
    const max_items: u16 = @min(height -| input_y -| 2, 10);
    var item_y: u16 = 1;

    // Get all command names and filter
    const names = editor.commands.allNames(editor.allocator) catch return;
    defer editor.allocator.free(names);

    for (names) |name| {
        if (item_y > max_items) break;
        // Fuzzy filter: all filter chars must appear in order in the name
        if (filter.len > 0 and !fuzzyMatch(name, filter)) continue;

        const row_win = win.child(.{
            .x_off = @intCast(palette_x),
            .y_off = @intCast(input_y + item_y),
            .width = palette_width,
            .height = 1,
        });
        row_win.fill(.{ .style = item_style });
        _ = row_win.printSegment(.{ .text = " ", .style = item_style }, .{ .wrap = .none });
        const name_win = row_win.child(.{ .x_off = 1, .width = palette_width -| 1 });
        _ = name_win.printSegment(.{ .text = name, .style = item_style }, .{ .wrap = .none });
        item_y += 1;
    }
}

/// Simple fuzzy match: all chars in needle appear in haystack in order.
fn fuzzyMatch(haystack: []const u8, needle: []const u8) bool {
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
// Overlay key handlers
// ===========================================================================

/// Append a character to a fixed buffer, returns new length.
fn appendToInputBuf(buf: []u8, buf_len: *usize, key: Key) void {
    if (key.text) |text| {
        for (text) |ch| {
            if (buf_len.* < buf.len) {
                buf[buf_len.*] = ch;
                buf_len.* += 1;
            }
        }
    } else if (key.codepoint >= 32 and key.codepoint < 127) {
        if (buf_len.* < buf.len) {
            buf[buf_len.*] = @intCast(key.codepoint);
            buf_len.* += 1;
        }
    }
}

/// Handle keys in Find mode.
fn handleFindKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        // Close find, keep cursor at current match
        editor.mode = .normal;
        editor.status_message = "";
        return;
    }
    if (key.codepoint == Key.enter) {
        // Find next match from current position
        if (editor.find_buf_len > 0) {
            findNext(editor);
        }
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.find_buf_len > 0) {
            editor.find_buf_len -= 1;
            findIncremental(editor);
        }
        return;
    }
    editor.status_message = "";
    appendToInputBuf(&editor.find_buf, &editor.find_buf_len, key);
    findIncremental(editor);
}

/// Draw the Find & Replace two-line overlay.
fn drawFindReplaceOverlay(win: Window, editor: *Editor, width: u16, height: u16) void {
    const style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 14 }, .bold = true };
    const input_style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 15 } };
    const inactive_style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 8 } };

    const find_label = "Find:    ";
    const repl_label = "Replace: ";
    const find_y: u16 = height -| 2;
    const repl_y: u16 = height -| 1;

    // Find line
    {
        const row_win = win.child(.{ .y_off = @intCast(find_y), .width = width, .height = 1 });
        const row_style = if (!editor.replace_field_active) style else inactive_style;
        row_win.fill(.{ .style = row_style });
        _ = writeStr(row_win, 0, 0, find_label, row_style);
        const label_len: u16 = @intCast(find_label.len);
        if (editor.find_buf_len > 0) {
            _ = writeStr(row_win, label_len, 0, editor.find_buf[0..editor.find_buf_len], input_style);
        }
    }
    // Replace line
    {
        const row_win = win.child(.{ .y_off = @intCast(repl_y), .width = width, .height = 1 });
        const row_style = if (editor.replace_field_active) style else inactive_style;
        row_win.fill(.{ .style = row_style });
        _ = writeStr(row_win, 0, 0, repl_label, row_style);
        const label_len: u16 = @intCast(repl_label.len);
        if (editor.replace_buf_len > 0) {
            _ = writeStr(row_win, label_len, 0, editor.replace_buf[0..editor.replace_buf_len], input_style);
        }
    }
    // Show status message (e.g. "No matches found") on the find line, right-aligned
    if (editor.status_message.len > 0) {
        const msg_style: Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 9 } }; // red on black
        const msg_len: u16 = @intCast(@min(editor.status_message.len, width));
        const msg_x: u16 = width -| msg_len -| 1;
        const msg_win = win.child(.{ .y_off = @intCast(find_y), .width = width, .height = 1 });
        _ = writeStr(msg_win, msg_x, 0, editor.status_message, msg_style);
    }

    // Cursor on active field
    const active_y = if (editor.replace_field_active) repl_y else find_y;
    const active_len: u16 = if (editor.replace_field_active)
        @intCast(editor.replace_buf_len)
    else
        @intCast(editor.find_buf_len);
    const cursor_col: u16 = @as(u16, @intCast(find_label.len)) +| active_len;
    if (cursor_col < width) {
        win.showCursor(cursor_col, active_y);
        win.setCursorShape(.beam_blink);
    }
}

/// Handle keys in Find & Replace mode.
fn handleFindReplaceKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        editor.mode = .normal;
        return;
    }
    if (key.codepoint == Key.tab) {
        // Toggle between find and replace fields
        editor.replace_field_active = !editor.replace_field_active;
        return;
    }
    if (key.codepoint == Key.enter) {
        if (!editor.replace_field_active) {
            // In find field: find next
            if (editor.find_buf_len > 0) findNext(editor);
        } else {
            // In replace field: replace current match and find next
            replaceOne(editor);
        }
        return;
    }
    // Ctrl+Enter or Ctrl+A in replace mode = replace all
    if (key.mods.ctrl and (key.codepoint == Key.enter or key.matches('a', .{ .ctrl = true }))) {
        replaceAll(editor);
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.replace_field_active) {
            if (editor.replace_buf_len > 0) editor.replace_buf_len -= 1;
        } else {
            if (editor.find_buf_len > 0) {
                editor.find_buf_len -= 1;
                findIncremental(editor);
            }
        }
        return;
    }
    // Type into active field
    editor.status_message = "";
    if (editor.replace_field_active) {
        appendToInputBuf(&editor.replace_buf, &editor.replace_buf_len, key);
    } else {
        appendToInputBuf(&editor.find_buf, &editor.find_buf_len, key);
        findIncremental(editor);
    }
}

/// Replace the current selection (if it matches the find text) and find next.
fn replaceOne(editor: *Editor) void {
    const doc = editor.activeDoc();
    const needle = editor.find_buf[0..editor.find_buf_len];
    const replacement = editor.replace_buf[0..editor.replace_buf_len];
    if (needle.len == 0) return;

    // Check if current selection matches the needle
    if (doc.selectedText()) |sel| {
        if (std.mem.eql(u8, sel, needle)) {
            doc.deleteSelection() catch {};
            doc.insertAtCursor(replacement) catch {};
        }
    }
    findNext(editor);
}

/// Replace all occurrences of find text with replace text.
fn replaceAll(editor: *Editor) void {
    const doc = editor.activeDoc();
    const needle = editor.find_buf[0..editor.find_buf_len];
    const replacement = editor.replace_buf[0..editor.replace_buf_len];
    if (needle.len == 0) return;

    // Start from beginning
    doc.cursors.primary().offset = 0;
    doc.cursors.primary().clearSelection();

    var count: usize = 0;
    while (count < 100_000) { // safety limit
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
            count,
            @as([]const u8, if (count == 1) "" else "s"),
        }) catch "Replaced all";
        editor.status_message = msg;
    }
}

/// Handle keys in Confirm Quit mode.
fn handleConfirmQuitKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    switch (key.codepoint) {
        's', 'S' => {
            // Save all dirty documents, then quit
            for (editor.documents.items) |*doc| {
                if (doc.dirty) {
                    doc.save() catch {};
                }
            }
            editor.running = false;
        },
        'd', 'D' => {
            // Discard and quit
            editor.running = false;
        },
        'c', 'C', Key.escape => {
            // Cancel — go back to normal mode
            editor.mode = .normal;
        },
        else => {},
    }
}

/// Incremental search: find first match from the saved origin position.
/// Called after each keystroke in find mode to jump to matches as user types.
fn findIncremental(editor: *Editor) void {
    const doc = editor.activeDoc();
    const needle = editor.find_buf[0..editor.find_buf_len];
    if (needle.len == 0) {
        // Empty query — restore cursor to origin
        doc.cursors.primary().offset = editor.find_origin;
        doc.cursors.primary().anchor = editor.find_origin;
        editor.status_message = "";
        return;
    }

    const buf_len = doc.buffer.byteLen();
    const content = doc.buffer.slice(0, buf_len);
    const origin = @min(editor.find_origin, buf_len);

    // Search from origin forward
    if (std.mem.indexOf(u8, content[origin..], needle)) |idx| {
        const abs_pos = origin + idx;
        doc.cursors.primary().anchor = abs_pos;
        doc.cursors.primary().offset = abs_pos + needle.len;
        doc.cursors.primary().preferred_col = doc.buffer.offsetToPos(doc.cursors.primary().offset).col;
        editor.status_message = "";
        return;
    }
    // Wrap around from beginning to origin
    if (std.mem.indexOf(u8, content[0..origin], needle)) |idx| {
        doc.cursors.primary().anchor = idx;
        doc.cursors.primary().offset = idx + needle.len;
        doc.cursors.primary().preferred_col = doc.buffer.offsetToPos(doc.cursors.primary().offset).col;
        editor.status_message = "Search wrapped";
        return;
    }
    // No match — keep cursor at origin
    doc.cursors.primary().offset = editor.find_origin;
    doc.cursors.primary().anchor = editor.find_origin;
    editor.status_message = "No matches found";
}

/// Find next occurrence of search text from cursor.
fn findNext(editor: *Editor) void {
    const doc = editor.activeDoc();
    const needle = editor.find_buf[0..editor.find_buf_len];
    if (needle.len == 0) return;

    const cursor_offset = doc.cursors.primary().offset;
    const buf_len = doc.buffer.byteLen();
    const content = doc.buffer.slice(0, buf_len);

    // Search from cursor+1 to end, then wrap around
    const search_start = @min(cursor_offset + 1, buf_len);
    if (std.mem.indexOf(u8, content[search_start..], needle)) |idx| {
        const abs_pos = search_start + idx;
        doc.cursors.primary().anchor = abs_pos;
        doc.cursors.primary().offset = abs_pos + needle.len;
        doc.cursors.primary().preferred_col = doc.buffer.offsetToPos(doc.cursors.primary().offset).col;
        editor.status_message = "";
        return;
    }
    // Wrap around
    if (std.mem.indexOf(u8, content[0..search_start], needle)) |idx| {
        doc.cursors.primary().anchor = idx;
        doc.cursors.primary().offset = idx + needle.len;
        doc.cursors.primary().preferred_col = doc.buffer.offsetToPos(doc.cursors.primary().offset).col;
        editor.status_message = "Search wrapped";
        return;
    }
    // No match at all
    editor.status_message = "No matches found";
}

/// Handle keys in File Open mode.
fn handleFileOpenKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        editor.mode = .normal;
        return;
    }
    if (key.codepoint == Key.enter) {
        if (editor.open_buf_len > 0) {
            const path = editor.open_buf[0..editor.open_buf_len];
            _ = editor.openFile(path) catch {};
        }
        editor.mode = .normal;
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.open_buf_len > 0) editor.open_buf_len -= 1;
        return;
    }
    appendToInputBuf(&editor.open_buf, &editor.open_buf_len, key);
}

/// Handle keys in Save As mode.
fn handleSaveAsKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        editor.mode = .normal;
        return;
    }
    if (key.codepoint == Key.enter) {
        if (editor.open_buf_len > 0) {
            const path = editor.open_buf[0..editor.open_buf_len];
            editor.activeDoc().saveAs(path) catch {
                editor.status_message = "Save failed";
            };
        }
        editor.mode = .normal;
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.open_buf_len > 0) editor.open_buf_len -= 1;
        return;
    }
    appendToInputBuf(&editor.open_buf, &editor.open_buf_len, key);
}

/// Handle keys in Command Palette mode.
fn handlePaletteKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        editor.mode = .normal;
        return;
    }
    if (key.codepoint == Key.enter) {
        // Execute first matching command
        if (editor.palette_buf_len > 0) {
            const filter = editor.palette_buf[0..editor.palette_buf_len];
            const names = editor.commands.allNames(editor.allocator) catch {
                editor.mode = .normal;
                return;
            };
            defer editor.allocator.free(names);
            for (names) |name| {
                if (fuzzyMatch(name, filter)) {
                    editor.mode = .normal;
                    _ = editor.execCommand(name, null);
                    return;
                }
            }
        }
        editor.mode = .normal;
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.palette_buf_len > 0) editor.palette_buf_len -= 1;
        return;
    }
    appendToInputBuf(&editor.palette_buf, &editor.palette_buf_len, key);
}

/// Handle keys in Go to Line mode.
fn handleGotoLineKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        editor.mode = .normal;
        return;
    }
    if (key.codepoint == Key.enter) {
        if (editor.goto_buf_len > 0) {
            const num_str = editor.goto_buf[0..editor.goto_buf_len];
            const line_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
            if (line_num > 0) {
                editor.activeDoc().gotoLine(line_num);
            }
        }
        editor.mode = .normal;
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.goto_buf_len > 0) editor.goto_buf_len -= 1;
        return;
    }
    // Only accept digits
    if (key.codepoint >= '0' and key.codepoint <= '9') {
        if (editor.goto_buf_len < editor.goto_buf.len) {
            editor.goto_buf[editor.goto_buf_len] = @intCast(key.codepoint);
            editor.goto_buf_len += 1;
        }
    }
}
