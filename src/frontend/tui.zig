const std = @import("std");
const vaxis = @import("vaxis");
const Editor = @import("../core/editor.zig").Editor;
const Document = @import("../core/document.zig").Document;
const TuiColor = @import("../core/theme.zig").TuiColor;
const syntax = @import("../core/syntax.zig");
const lsp = @import("../core/lsp.zig");
const terminal_mod = @import("../core/terminal.zig");
const filetree_mod = @import("../core/filetree.zig");
const FileTree = filetree_mod.FileTree;

const Key = vaxis.Key;
const Cell = vaxis.Cell;
const Style = vaxis.Style;
const Color = vaxis.Color;
const Window = vaxis.Window;
const Segment = vaxis.Segment;

/// Convert a TuiColor to a vaxis Color.
fn toVaxis(c: TuiColor) Color {
    return switch (c) {
        .default => .default,
        .ansi => |idx| .{ .index = idx },
        .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    };
}

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

/// Per-frame storage for multi-byte grapheme strings referenced by vaxis
/// cells (see header comment — cell text must outlive vx.render). Reset at
/// the top of each frame in `run`.
var grapheme_arena: [128 * 1024]u8 = undefined;
var grapheme_arena_len: usize = 0;

fn frameArenaReset() void {
    grapheme_arena_len = 0;
}

/// Copy `bytes` into the frame arena, returning a slice that stays valid
/// until the next frameArenaReset. Falls back to "?" if the arena is full.
fn frameArenaDupe(bytes: []const u8) []const u8 {
    if (bytes.len == 1) return ByteLut.grapheme(bytes[0]);
    if (grapheme_arena_len + bytes.len > grapheme_arena.len) return "?";
    const dst = grapheme_arena[grapheme_arena_len..][0..bytes.len];
    @memcpy(dst, bytes);
    grapheme_arena_len += bytes.len;
    return dst;
}

/// Write a UTF-8 string to the window, one cell per codepoint (previously
/// byte-per-cell, which rendered non-ASCII text as mojibake). Multi-byte
/// codepoints are copied into the frame arena so the cell references stay
/// valid through render. Returns the column after the last cell written.
fn writeStr(win: Window, col: u16, row: u16, text: []const u8, style: Style) u16 {
    var x = col;
    var i: usize = 0;
    while (i < text.len) {
        if (x >= win.width) break;
        const b = text[i];
        if (b < 0x80) {
            // ASCII fast path — static lookup, no arena
            win.writeCell(x, row, .{
                .char = .{ .grapheme = ByteLut.grapheme(b), .width = 1 },
                .style = style,
            });
            i += 1;
            x += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 0;
        if (seq_len == 0 or i + seq_len > text.len or !std.unicode.utf8ValidateSlice(text[i .. i + seq_len])) {
            // Invalid byte — render replacement char, advance one byte to resync
            win.writeCell(x, row, .{
                .char = .{ .grapheme = "\u{FFFD}", .width = 1 },
                .style = style,
            });
            i += 1;
            x += 1;
            continue;
        }
        win.writeCell(x, row, .{
            .char = .{ .grapheme = frameArenaDupe(text[i .. i + seq_len]), .width = 1 },
            .style = style,
        });
        i += seq_len;
        x += 1;
    }
    return x;
}

// 0.16 removed these console types/functions from std.os.windows — declare
// the minimal surface ourselves.
const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: std.os.windows.COORD,
    dwCursorPosition: std.os.windows.COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: std.os.windows.COORD,
};
extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: std.os.windows.HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) c_int;

/// Get terminal size on Windows using the console API.
fn getWinsizeWindows() ?vaxis.Winsize {
    const stdout: std.Io.File = .stdout();
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (GetConsoleScreenBufferInfo(stdout.handle, &info) != 0) {
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
    lsp_data,
    terminal_data,
};

/// Module-level loop pointer for reader-thread wake callbacks (LSP +
/// terminal). Nulled before the loop dies so a late wake can't post to a
/// dangling pointer (a reader preempted mid-call is a theoretical residual
/// race; both threads are joined moments later in the deinit path).
var global_loop: ?*vaxis.Loop(Event) = null;

/// Wake function called from LSP reader thread to unblock nextEvent.
fn lspWakeFn() void {
    if (global_loop) |loop_ptr| {
        // Queue full or canceled: drop the wake — pending events already
        // guarantee the main loop runs again.
        loop_ptr.postEvent(.lsp_data) catch {};
    }
}

/// Wake function called from terminal reader threads when new PTY output
/// landed in a grid — unblocks nextEvent so the pane repaints.
fn terminalWakeFn() void {
    if (global_loop) |loop_ptr| {
        loop_ptr.postEvent(.terminal_data) catch {};
    }
}

/// When true, the user explicitly scrolled (wheel) so ensureCursorVisible is skipped.
/// Cleared when the cursor moves (key press, click, etc.).
var scroll_pinned: bool = false;

/// Block (column) selection drag state — armed on Alt+press, engaged once
/// the drag leaves the press cell.
var block_drag: bool = false;
var block_engaged: bool = false;
var block_anchor_line: usize = 0;
var block_anchor_col: usize = 0;

/// Run the TUI editor.
pub fn run(allocator: std.mem.Allocator, editor: *Editor) !void {
    // Initialize TTY
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(editor.io, &tty_buf);
    defer tty.deinit();

    // Initialize Vaxis (0.16 API wants the Io instance + mutable env map;
    // main() stashed the process env map in lua_settings for module-level use)
    const lua_settings = @import("../core/lua_settings.zig");
    const env_map = lua_settings.process_environ orelse return error.NoEnvironMap;
    var vx = try vaxis.init(editor.io, allocator, env_map, .{});
    defer vx.deinit(allocator, tty.writer());

    // Event loop (threaded input reader). 0.16 vaxis: init(io, ...) is the
    // constructor; installResizeHandler replaces the old init()'s SIGWINCH
    // registration (no-op on Windows — resize arrives via console events).
    var loop: vaxis.Loop(Event) = .init(editor.io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();

    // Set up reader-thread wakes (LSP + terminal panes)
    global_loop = &loop;
    defer global_loop = null; // runs before loop.stop()'s defer — no dangling wakes
    if (editor.lsp) |lsp_client| {
        lsp_client.tui_wake_fn = &lspWakeFn;
    }
    editor.terminal_wake_fn = &terminalWakeFn;

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
            const event = try loop.nextEvent();
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
    var last_auto_save_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;

    // Main loop
    while (editor.running) {
        // Drain all pending events
        while (loop.tryEvent() catch null) |event| {
            switch (event) {
                .key_press => |key| dispatchKey(editor, key),
                .mouse => |mouse| handleMouse(editor, mouse),
                .winsize => |ws| {
                    try vx.resize(allocator, tty.writer(), ws);
                    vx.refresh = true;
                },
                else => {},
            }
        }

        // Poll LSP messages and sync documents
        if (editor.lsp) |lsp_client| lsp_client.pollMessages(editor);
        editor.syncLspDocuments();

        // Auto-save check
        if (editor.auto_save and editor.hasUnsavedChanges()) {
            const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
            const elapsed_ms: u64 = @intCast(@divFloor(now_ns - last_auto_save_ns, std.time.ns_per_ms));
            if (elapsed_ms >= editor.auto_save_interval_ms) {
                _ = editor.autoSaveAll();
                last_auto_save_ns = now_ns;
            }
        }

        // File tree: pick up files created/removed outside ZIDE — cheap
        // dir-mtime probe at most every ~1.5s, full rescan only on change.
        if (editor.filetree_visible) {
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

        // Update page_size based on terminal height
        const win = vx.window();
        const width = win.width;
        const height = win.height;
        if (height > 3) {
            editor.page_size = height - 3;
        }

        win.clear();
        // New frame: previous frame's grapheme references are now dead
        frameArenaReset();

        if (height < 3 or width < 10) {
            try vx.render(tty.writer());
            const event = try loop.nextEvent();
            switch (event) {
                .key_press => |key| dispatchKey(editor, key),
                .mouse => |mouse| handleMouse(editor, mouse),
                .winsize => |ws| {
                    try vx.resize(allocator, tty.writer(), ws);
                    vx.refresh = true;
                },
                else => {},
            }
            continue;
        }

        // Draw the editor UI
        drawEditor(win, editor, width, height);

        // Draw overlay if in a special mode (replaces status bar)
        switch (editor.mode) {
            .find => {
                drawOverlay(win, editor, "Find: ", editor.find_buf[0..editor.find_buf_len], width, height);
                // Show search status message (e.g. "No matches found") right-aligned
                if (editor.status_message.len > 0) {
                    const msg_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_warn) };
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
                drawOverlay(win, editor, "Open: ", editor.open_buf[0..editor.open_buf_len], width, height);
            },
            .save_as => {
                drawOverlay(win, editor, "Save As: ", editor.open_buf[0..editor.open_buf_len], width, height);
            },
            .command_palette => {
                drawCommandPalette(win, editor, width, height);
            },
            .goto_line => {
                drawOverlay(win, editor, "Go to line: ", editor.goto_buf[0..editor.goto_buf_len], width, height);
            },
            .confirm_quit => {
                drawOverlay(win, editor, "Unsaved changes! [S]ave [D]iscard [C]ancel: ", "", width, height);
            },
            .settings => {
                // Settings panel is GUI-only; in TUI just show a hint
                drawOverlay(win, editor, "Settings: edit ~/.config/zide/init.lua (Esc to close)", "", width, height);
            },
            .filetree_prompt => {
                switch (editor.filetree_prompt_kind) {
                    .create => drawOverlay(win, editor, "New (end with / for folder): ", editor.open_buf[0..editor.open_buf_len], width, height),
                    .rename => drawOverlay(win, editor, "Rename: ", editor.open_buf[0..editor.open_buf_len], width, height),
                    .delete_confirm => {
                        var buf: [160]u8 = undefined;
                        const target = editor.filetree_prompt_target orelse "";
                        const title = std.fmt.bufPrint(&buf, "Delete {s}? [Y]es [N]o: ", .{target}) catch "Delete? [Y]es [N]o: ";
                        drawOverlay(win, editor, title, "", width, height);
                    },
                }
            },
            // No terminal cursor while the file tree owns the keyboard —
            // the tree shows its own selection bar instead.
            .normal => if (!editor.filetree_focused) positionCursor(win, editor, width, height),
        }

        // Draw completion popup on top of everything (when active)
        if (editor.completion_active) {
            drawCompletionPopup(win, editor, width, height);
        }

        try vx.render(tty.writer());

        // Block until next event
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| dispatchKey(editor, key),
            .mouse => |mouse| handleMouse(editor, mouse),
            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
                vx.refresh = true;
            },
            else => {},
        }
    }
}

/// Dispatch key based on current editor mode.
fn dispatchKey(editor: *Editor, key: Key) void {
    // Terminal pane: route keys to PTY (except ctrl+backtick for toggle)
    if (editor.activePaneIsTerminal()) {
        handleTerminalKey(editor, key);
        return;
    }
    // Completion popup intercepts keys when active (regardless of mode)
    if (editor.completion_active) {
        handleCompletionKey(editor, key);
        return;
    }
    switch (editor.mode) {
        .normal => if (editor.filetree_focused) handleFiletreeKey(editor, key) else handleKey(editor, key),
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
        .filetree_prompt => handleFiletreePromptKey(editor, key),
    }
}

/// Handle key events when focused on a terminal pane.
fn handleTerminalKey(editor: *Editor, key: Key) void {
    // ctrl+backtick (`) toggles back to editor
    if (key.codepoint == '`' and key.mods.ctrl) {
        editor.toggleTerminal();
        return;
    }

    // Get the active terminal
    const term_idx = editor.activePaneTerminalIdx() orelse return;
    if (term_idx >= editor.terminals.items.len) return;
    const term = editor.terminals.items[term_idx] orelse return;

    // Map vaxis key to terminal key encoding
    var out: [16]u8 = undefined;
    const cp: u21 = mapVaxisKey(key);
    if (cp == 0) return;

    const n = terminal_mod.Terminal.encodeKey(
        cp,
        key.mods.ctrl,
        key.mods.alt,
        key.mods.shift,
        &out,
    );
    if (n > 0) {
        term.writeInput(out[0..n]);
    }
}

/// Map a vaxis Key to a codepoint for terminal key encoding.
fn mapVaxisKey(key: Key) u21 {
    // If there's a codepoint, use it directly
    if (key.codepoint > 0 and key.codepoint < 0xF700) {
        return key.codepoint;
    }

    // Special keys
    return switch (key.codepoint) {
        Key.enter => 0x0D,
        Key.tab => 0x09,
        Key.backspace => 0x08,
        Key.escape => 0x1B,
        Key.up => 0xF700,
        Key.down => 0xF701,
        Key.left => 0xF702,
        Key.right => 0xF703,
        Key.home => 0xF704,
        Key.end => 0xF705,
        Key.page_up => 0xF706,
        Key.page_down => 0xF707,
        Key.insert => 0xF708,
        Key.delete => 0xF709,
        else => 0,
    };
}

/// Rectangle in screen space. Used to route mouse clicks to panes.
const PaneRect = struct {
    pane_id: u8,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

/// Cached pane rectangles after last draw. Used by screenToOffset/resolvePaneAt.
var pane_rects: [64]PaneRect = undefined;
var pane_rect_count: usize = 0;

fn pushPaneRect(pane_id: u8, x: u16, y: u16, w: u16, h: u16) void {
    if (pane_rect_count >= pane_rects.len) return;
    pane_rects[pane_rect_count] = .{ .pane_id = pane_id, .x = x, .y = y, .w = w, .h = h };
    pane_rect_count += 1;
}

/// Find which pane contains screen coordinates (col, row). Returns pane_id and
/// the local (pane-relative) coordinates.
fn resolvePaneAt(editor: *Editor, col: i16, row: i16) ?struct { pane_id: u8, local_x: u16, local_y: u16 } {
    _ = editor;
    if (col < 0 or row < 0) return null;
    const cx: u16 = @intCast(col);
    const ry: u16 = @intCast(row);
    for (pane_rects[0..pane_rect_count]) |pr| {
        if (cx >= pr.x and cx < pr.x + pr.w and ry >= pr.y and ry < pr.y + pr.h) {
            return .{ .pane_id = pr.pane_id, .local_x = cx - pr.x, .local_y = ry - pr.y };
        }
    }
    return null;
}

/// File tree band geometry from the last draw (absolute screen coords),
/// used for mouse hit-testing. Null when the panel isn't shown.
const FiletreeBand = struct { x: u16, y: u16, w: u16, h: u16 };
var filetree_band: ?FiletreeBand = null;

/// Double-click state for tree rows: single click on a row NAME only
/// selects; a second click on the same row within the threshold toggles
/// a folder or opens a file. (The +/- glyph stays single-click.)
const filetree_double_click_ms: i128 = 400;
var filetree_last_click_ns: i128 = 0;
var filetree_last_click_row: usize = std.math.maxInt(usize);
/// Last external-change mtime probe (run-loop poll; the TUI loop is
/// event-driven, so the check fires when input arrives).
var filetree_poll_ns: i128 = 0;

/// Draw the full editor screen.
fn drawEditor(win: Window, editor: *Editor, width: u16, height: u16) void {
    pane_rect_count = 0;
    filetree_band = null;

    const tab_bar_height: u16 = if (editor.docCount() > 1) 1 else 0;
    const status_height: u16 = 1;
    const content_height = height -| tab_bar_height -| status_height;

    // Tab bar (global, spans full width)
    if (tab_bar_height > 0) {
        const tab_win = win.child(.{ .y_off = 0, .height = 1, .width = width });
        drawTabBar(tab_win, editor, width);
    }

    // File tree band — docks left or right of the pane area, below the
    // tab bar. Skipped (focus released) when the terminal is too narrow.
    var tree_w: u16 = 0;
    if (editor.filetree_visible) {
        if (width < 40) {
            editor.filetree_focused = false;
        } else if (editor.ensureFiletree() != null) {
            tree_w = @min(editor.tui_filetree_width, width / 2);
            if (tree_w < 16) tree_w = 16;
            const band_x: u16 = if (editor.filetree_side == .left) 0 else width - tree_w;
            const band_win = win.child(.{
                .x_off = @intCast(band_x),
                .y_off = @intCast(tab_bar_height),
                .width = tree_w,
                .height = content_height,
            });
            drawFileTree(band_win, editor, tree_w, content_height);
            filetree_band = .{ .x = band_x, .y = tab_bar_height, .w = tree_w, .h = content_height };
        }
    }
    const content_x: u16 = if (tree_w > 0 and editor.filetree_side == .left) tree_w else 0;
    const content_width = width - tree_w;

    // Render pane tree into the content area
    const content_win = win.child(.{
        .x_off = @intCast(content_x),
        .y_off = @intCast(tab_bar_height),
        .height = content_height,
        .width = content_width,
    });
    // NOTE: screen_x comes before screen_y — the tab bar offsets Y only.
    // (These were swapped once: with 2+ tabs open every pane rect shifted
    // one row up / one col right, drawing the cursor next to the wrong line
    // and skewing mouse hit-testing.)
    renderPaneLayout(content_win, editor, 0, content_x, tab_bar_height, content_width, content_height);

    // Status bar
    const status_win = win.child(.{
        .y_off = @intCast(height - 1),
        .height = 1,
        .width = width,
    });
    drawStatusBar(status_win, editor, width);
}

/// Truncate to at most `max_cols` display columns (codepoint-based; wide
/// glyph handling is deferred with the rest of the CJK width work).
fn truncToWidth(text: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (cols + 1 > max_cols) break;
        cols += 1;
        i += @min(cp_len, text.len - i);
    }
    return text[0..i];
}

/// Draw the file tree band: header row with the root name, then one row
/// per entry of the core model's flattened visible list.
fn drawFileTree(win: Window, editor: *Editor, w: u16, h: u16) void {
    const ft = if (editor.filetree) |*f| f else return;
    if (w < 2 or h < 2) return;
    const theme = editor.tui_theme;
    const bg_style: Style = .{ .fg = toVaxis(theme.text_fg), .bg = toVaxis(theme.text_bg) };
    win.fill(.{ .style = bg_style });

    // Separator column on the edge facing the editor.
    const sep_style: Style = .{ .fg = toVaxis(theme.gutter_separator), .bg = toVaxis(theme.text_bg) };
    const sep_x: u16 = if (editor.filetree_side == .left) w - 1 else 0;
    for (0..h) |r| {
        win.writeCell(sep_x, @intCast(r), .{
            .char = .{ .grapheme = "\u{2502}", .width = 1 }, // │
            .style = sep_style,
        });
    }
    const text_x: u16 = if (editor.filetree_side == .left) 0 else 1;
    const text_w: u16 = w - 1;

    // Header: clickable ^ up-button + root path, truncated from the left
    // so the tail (the part you care about) stays readable.
    const header_style: Style = .{
        .fg = toVaxis(if (editor.filetree_focused) theme.overlay_accent else theme.gutter_text),
        .bg = toVaxis(theme.text_bg),
        .bold = editor.filetree_focused,
    };
    var hx = writeStr(win, text_x, 0, "^ ", header_style);
    const path_cols: usize = text_w -| 2;
    const tail = filetree_mod.pathTail(ft.root_path, path_cols);
    if (tail.len == ft.root_path.len) {
        _ = writeStr(win, hx, 0, tail, header_style);
    } else {
        hx = writeStr(win, hx, 0, "...", header_style);
        _ = writeStr(win, hx, 0, filetree_mod.pathTail(ft.root_path, path_cols -| 3), header_style);
    }

    // Keep the selection in view (reveal/create/keyboard nav set the flag),
    // then clamp the scroll when rows disappeared (collapse/refresh).
    const visible_rows: usize = h - 1;
    const row_count = ft.visible.items.len;
    if (ft.scroll_to_selected) {
        ft.scroll_to_selected = false;
        if (ft.selected < editor.tui_filetree_scroll) {
            editor.tui_filetree_scroll = ft.selected;
        } else if (visible_rows > 0 and ft.selected >= editor.tui_filetree_scroll + visible_rows) {
            editor.tui_filetree_scroll = ft.selected - visible_rows + 1;
        }
    }
    if (editor.tui_filetree_scroll > 0 and editor.tui_filetree_scroll + visible_rows > row_count) {
        editor.tui_filetree_scroll = row_count -| visible_rows;
    }

    const sel_style: Style = .{ .fg = toVaxis(theme.selection_fg), .bg = toVaxis(theme.selection_bg) };
    var screen_row: u16 = 1;
    var row = editor.tui_filetree_scroll;
    while (row < row_count and screen_row < h) : ({
        row += 1;
        screen_row += 1;
    }) {
        const idx = ft.visible.items[row];
        const node = ft.nodes.items[idx];
        // Git status drives the foreground; selection drives the background
        const status_fg: ?Color = if (ft.statusFor(idx)) |st| toVaxis(switch (st) {
            .added => theme.git_added,
            .modified => theme.git_modified,
            .deleted => theme.git_deleted,
            .untracked => theme.git_untracked,
        }) else null;
        var style = if (row == ft.selected) sel_style else bg_style;
        if (status_fg) |fg| style.fg = fg;
        if (row == ft.selected) {
            // Fill the whole row so the selection reads as a bar
            for (0..text_w) |ci| {
                win.writeCell(@intCast(text_x + ci), screen_row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = style,
                });
            }
        }
        const depth: usize = node.depth -| 1;
        const indent: u16 = @intCast(@min(depth * 2, text_w / 2));
        // Indent guides: │ per ancestor level (same clamp as the indent)
        const guide_style: Style = .{ .fg = toVaxis(theme.gutter_separator), .bg = style.bg };
        var lvl: u16 = 0;
        while (lvl * 2 < indent) : (lvl += 1) {
            win.writeCell(text_x + lvl * 2, screen_row, .{
                .char = .{ .grapheme = "\u{2502}", .width = 1 }, // │
                .style = guide_style,
            });
        }
        var x: u16 = text_x + indent;
        const glyph: []const u8 = switch (node.kind) {
            .dir => if (node.expanded) "- " else "+ ",
            .file => "  ",
        };
        x = writeStr(win, x, screen_row, glyph, style);
        const name_cols: usize = if (x < text_x + text_w) text_x + text_w - x else 0;
        _ = writeStr(win, x, screen_row, truncToWidth(node.name, name_cols), style);
    }
}

/// True when the mouse position is inside the file tree band.
fn mouseOverFiletree(mouse: vaxis.Mouse) bool {
    const band = filetree_band orelse return false;
    const mc: i32 = @intCast(mouse.col);
    const mr: i32 = @intCast(mouse.row);
    return mc >= band.x and mc < @as(i32, band.x) + band.w and
        mr >= band.y and mr < @as(i32, band.y) + band.h;
}

/// Left click inside the file tree band: focus the tree and select the
/// row. A single click on the +/- glyph toggles a folder; row names need
/// a double click (toggle dir / open file) so a stray click never opens
/// or collapses anything.
fn handleFiletreeClick(editor: *Editor, band: FiletreeBand, col_abs: u16, row_abs: u16) void {
    const ft = editor.ensureFiletree() orelse return;
    editor.filetree_focused = true;
    if (row_abs <= band.y) {
        // Header: the ^ button re-roots at the parent folder
        const hdr_text_x: u16 = if (editor.filetree_side == .left) 0 else 1;
        const hdr_col = col_abs -| band.x;
        if (hdr_col >= hdr_text_x and hdr_col < hdr_text_x + 2) {
            editor.filetreeRootUp();
        }
        return;
    }
    const rel: usize = row_abs - band.y - 1;
    const r = editor.tui_filetree_scroll + rel;
    if (r >= ft.visible.items.len) return;
    ft.selected = r;
    const idx = ft.visible.items[r];
    const node = ft.nodes.items[idx];

    const now_ns: i128 = std.Io.Clock.now(.awake, editor.io).nanoseconds;
    const is_double = r == filetree_last_click_row and
        now_ns - filetree_last_click_ns < filetree_double_click_ms * std.time.ns_per_ms;

    // Glyph zone — must reuse drawFileTree's indent clamp or deep rows
    // would mis-target.
    const text_x: u16 = if (editor.filetree_side == .left) 0 else 1;
    const text_w: u16 = band.w - 1;
    const depth: usize = node.depth -| 1;
    const indent: u16 = @intCast(@min(depth * 2, text_w / 2));
    const local_col = col_abs -| band.x;
    const in_glyph = node.kind == .dir and
        local_col >= text_x + indent and local_col < text_x + indent + 2;

    if (in_glyph) {
        ft.toggle(idx) catch {};
        filetree_last_click_ns = 0; // action fired — no chain
    } else if (is_double) {
        if (node.kind == .dir) {
            ft.toggle(idx) catch {};
        } else {
            openFiletreeFileTui(editor, ft, idx);
        }
        filetree_last_click_ns = 0;
    } else {
        filetree_last_click_ns = now_ns;
        filetree_last_click_row = r;
    }
}

/// Open the file behind a tree node (deduped against open tabs).
fn openFiletreeFileTui(editor: *Editor, ft: *FileTree, idx: u32) void {
    const abs = ft.absPathAlloc(editor.allocator, idx) catch return;
    defer editor.allocator.free(abs);
    _ = editor.openOrFocus(abs) catch |err| {
        editor.status_message = if (err == error.BinaryFile)
            "Cannot open: binary file"
        else
            "Open failed";
    };
}

/// Recursively render the layout tree into the given window.
/// screen_x / screen_y give the window's absolute top-left on the terminal,
/// used to record pane rects for mouse hit-testing.
fn renderPaneLayout(
    win: Window,
    editor: *Editor,
    node_idx: u8,
    screen_x: u16,
    screen_y: u16,
    width: u16,
    height: u16,
) void {
    if (node_idx >= editor.layout.nodes.items.len) return;
    if (width == 0 or height == 0) return;

    switch (editor.layout.nodes.items[node_idx]) {
        .leaf => |pane_id| {
            pushPaneRect(pane_id, screen_x, screen_y, width, height);
            drawPane(win, editor, pane_id, width, height);
        },
        .split => |s| {
            const sep_style: Style = .{
                .fg = toVaxis(editor.tui_theme.gutter_separator),
                .bg = toVaxis(editor.tui_theme.text_bg),
            };
            switch (s.direction) {
                .horizontal => {
                    // side-by-side with 1-col separator
                    if (width < 3) {
                        // Too narrow to split — just render the first child
                        renderPaneLayout(win, editor, s.first, screen_x, screen_y, width, height);
                        return;
                    }
                    const avail: u16 = width - 1;
                    var first_w: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(avail)) * s.ratio));
                    if (first_w == 0) first_w = 1;
                    if (first_w >= avail) first_w = avail - 1;
                    const second_w: u16 = avail - first_w;

                    const first_win = win.child(.{ .x_off = 0, .y_off = 0, .width = first_w, .height = height });
                    renderPaneLayout(first_win, editor, s.first, screen_x, screen_y, first_w, height);

                    // Vertical separator at column first_w
                    for (0..height) |r| {
                        win.writeCell(@intCast(first_w), @intCast(r), .{
                            .char = .{ .grapheme = "\u{2502}", .width = 1 }, // │
                            .style = sep_style,
                        });
                    }

                    const second_win = win.child(.{
                        .x_off = @intCast(first_w + 1),
                        .y_off = 0,
                        .width = second_w,
                        .height = height,
                    });
                    renderPaneLayout(second_win, editor, s.second, screen_x + first_w + 1, screen_y, second_w, height);
                },
                .vertical => {
                    // top/bottom with 1-row separator
                    if (height < 3) {
                        renderPaneLayout(win, editor, s.first, screen_x, screen_y, width, height);
                        return;
                    }
                    const avail: u16 = height - 1;
                    var first_h: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(avail)) * s.ratio));
                    if (first_h == 0) first_h = 1;
                    if (first_h >= avail) first_h = avail - 1;
                    const second_h: u16 = avail - first_h;

                    const first_win = win.child(.{ .x_off = 0, .y_off = 0, .width = width, .height = first_h });
                    renderPaneLayout(first_win, editor, s.first, screen_x, screen_y, width, first_h);

                    // Horizontal separator at row first_h
                    for (0..width) |c| {
                        win.writeCell(@intCast(c), @intCast(first_h), .{
                            .char = .{ .grapheme = "\u{2500}", .width = 1 }, // ─
                            .style = sep_style,
                        });
                    }

                    const second_win = win.child(.{
                        .x_off = 0,
                        .y_off = @intCast(first_h + 1),
                        .width = width,
                        .height = second_h,
                    });
                    renderPaneLayout(second_win, editor, s.second, screen_x, screen_y + first_h + 1, width, second_h);
                },
            }
        },
    }
}

/// Draw a single pane (editor or terminal) into the given window.
fn drawPane(win: Window, editor: *Editor, pane_id: u8, width: u16, height: u16) void {
    const pane = editor.layout.panes.items[pane_id];
    switch (pane.content) {
        .editor => |doc_idx| {
            if (doc_idx >= editor.documents.items.len) return;
            const doc = &editor.documents.items[doc_idx];
            const is_active = pane_id == editor.active_pane;

            // Only the active pane's doc drives editor.text_width and cursor-visible logic
            if (is_active) {
                const total_lines = doc.lineCount();
                const gutter_w = lineNumberWidth(total_lines, editor.gutter_min_digits);
                const tw: u16 = if (width > gutter_w + 1) width - gutter_w - 1 else 1;
                editor.text_width = tw;

                if (!scroll_pinned) {
                    if (editor.word_wrap) {
                        doc.scroll_left = 0;
                        ensureCursorVisibleWrapped(doc, height, width, editor.gutter_min_digits);
                    } else {
                        doc.ensureCursorVisible(height, width -| 5);
                    }
                }
            }

            drawContent(win, doc, editor, width, height, editor.word_wrap);
            if (is_active and doc.cursors.count() > 1) {
                drawSecondaryCursors(win, doc, editor, width, height, editor.word_wrap);
            }
        },
        .terminal => |term_idx| {
            if (term_idx < editor.terminals.items.len) {
                if (editor.terminals.items[term_idx]) |t| {
                    drawTerminalInPane(win, editor, t, width, height);
                }
            }
        },
    }
}

/// Draw a terminal into a pane-sized window (no status bar, caller owns layout).
fn drawTerminalInPane(win: Window, editor: *Editor, term: *terminal_mod.Terminal, width: u16, height: u16) void {
    _ = editor;
    // Resize terminal grid if needed
    if (width != term.cols or height != term.rows) {
        term.resizeGrid(width, height);
    }

    term.mutex.lockUncancelable(term.io);
    defer term.mutex.unlock(term.io);

    const t_cols = term.cols;
    const t_rows = term.rows;

    for (0..@min(t_rows, height)) |r| {
        for (0..@min(t_cols, width)) |c| {
            const cell = term.cellAtUnsafe(@intCast(r), @intCast(c));
            const fg_tc = if (cell.reverse) cell.bg else cell.fg;
            const bg_tc = if (cell.reverse) cell.fg else cell.bg;
            const fg: Color = .{ .rgb = .{ fg_tc.r, fg_tc.g, fg_tc.b } };
            const bg: Color = .{ .rgb = .{ bg_tc.r, bg_tc.g, bg_tc.b } };

            // vaxis stores grapheme slices by reference — a stack buffer here
            // dangles before render. ASCII uses the static LUT; multi-byte
            // goes through the frame arena.
            var enc_buf: [4]u8 = undefined;
            const glyph_len = std.unicode.utf8Encode(cell.codepoint, &enc_buf) catch 0;
            const grapheme: []const u8 = if (glyph_len == 0)
                " "
            else
                frameArenaDupe(enc_buf[0..glyph_len]);
            const style: Style = .{
                .fg = fg,
                .bg = bg,
                .bold = cell.bold,
                .ul_style = if (cell.underline) .single else .off,
            };
            win.writeCell(@intCast(c), @intCast(r), .{
                .char = .{ .grapheme = grapheme, .width = 1 },
                .style = style,
            });
        }
    }
}

/// Compute the width of tab `i` in the tab bar. Matches the format in drawTabBar:
/// " " + display_name + (dirty ? "*" : "") + " " + "|".
fn tabWidth(doc: *const Document) u16 {
    const dirty_w: u16 = if (doc.dirty) 1 else 0;
    return @intCast(3 + doc.display_name.len + dirty_w);
}

/// Given a click x on the tab bar, return the doc index of the clicked tab,
/// or null if the click is past the last tab.
fn tabAtX(editor: *Editor, click_x: u16) ?usize {
    var x: u16 = 0;
    for (editor.documents.items, 0..) |*doc, i| {
        const w = tabWidth(doc);
        if (click_x >= x and click_x < x + w) return i;
        x += w;
    }
    return null;
}

/// Draw the tab bar.
fn drawTabBar(win: Window, editor: *Editor, width: u16) void {
    const bg_style: Style = .{ .bg = toVaxis(editor.tui_theme.tab_bg), .fg = toVaxis(editor.tui_theme.tab_fg) };
    const active_style: Style = .{ .bg = toVaxis(editor.tui_theme.tab_active_bg), .fg = toVaxis(editor.tui_theme.tab_active_fg), .bold = true };

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
        // Target column is the DISPLAY column within the current visual row —
        // preferred_col is a byte column within the whole logical line, which
        // made vertical movement in wrapped lines snap to row ends.
        const target_dcol: usize = wrap_pos.col;

        if (!extend_selection) {
            c.clearSelection();
        } else if (!c.hasSelection()) {
            c.startSelection();
        }

        switch (direction) {
            .up => {
                if (wrap_pos.row > 0) {
                    const target_col = wrapVisualToCol(cur_line, text_width, wrap_pos.row - 1, target_dcol);
                    c.offset = buf.posToOffset(pos.line, target_col);
                } else if (pos.line > 0) {
                    const prev_line = doc.lineContent(pos.line - 1);
                    const prev_rows = wrapLineRows(prev_line, text_width);
                    const target_col = wrapVisualToCol(prev_line, text_width, prev_rows - 1, target_dcol);
                    c.offset = buf.posToOffset(pos.line - 1, target_col);
                }
            },
            .down => {
                const cur_rows = wrapLineRows(cur_line, text_width);
                if (wrap_pos.row + 1 < cur_rows) {
                    const target_col = wrapVisualToCol(cur_line, text_width, wrap_pos.row + 1, target_dcol);
                    c.offset = buf.posToOffset(pos.line, target_col);
                } else if (pos.line + 1 < total_lines) {
                    const next_line = doc.lineContent(pos.line + 1);
                    const target_col = wrapVisualToCol(next_line, text_width, 0, target_dcol);
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
    // Use the edge cursor's display column within its visual row (see
    // moveVisualVertical — preferred_col is the wrong unit here).
    const ref_pos = buf.offsetToPos(ref_cursor.offset);
    const ref_dcol: usize = wrapColToVisual(cur_line, text_width, ref_pos.col).col;

    switch (direction) {
        .up => {
            if (edge_wrap_row > 0) {
                const target_col = wrapVisualToCol(cur_line, text_width, edge_wrap_row - 1, ref_dcol);
                doc.cursors.addCursor(buf.posToOffset(edge_line, target_col)) catch {};
            } else if (edge_line > 0) {
                const prev_line = doc.lineContent(edge_line - 1);
                const prev_rows = wrapLineRows(prev_line, text_width);
                const target_col = wrapVisualToCol(prev_line, text_width, prev_rows - 1, ref_dcol);
                doc.cursors.addCursor(buf.posToOffset(edge_line - 1, target_col)) catch {};
            }
        },
        .down => {
            const cur_rows = wrapLineRows(cur_line, text_width);
            if (edge_wrap_row + 1 < cur_rows) {
                const target_col = wrapVisualToCol(cur_line, text_width, edge_wrap_row + 1, ref_dcol);
                doc.cursors.addCursor(buf.posToOffset(edge_line, target_col)) catch {};
            } else if (edge_line + 1 < total_lines) {
                const next_line = doc.lineContent(edge_line + 1);
                const target_col = wrapVisualToCol(next_line, text_width, 0, ref_dcol);
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
fn ensureCursorVisibleWrapped(doc: *Document, editor_height: u16, width: u16, min_digits: usize) void {
    if (editor_height == 0) return;
    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines, min_digits);
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
fn drawContent(win: Window, doc: *Document, editor: *Editor, width: u16, height: u16, wrap: bool) void {
    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines, editor.gutter_min_digits);
    const text_start_x = gutter_width + 1; // +1 for separator
    const text_width: u16 = if (width > text_start_x) width - text_start_x else 1;

    const cursor_pos = doc.cursorPos();

    const bg = toVaxis(editor.tui_theme.text_bg);
    const line_num_style: Style = .{ .fg = toVaxis(editor.tui_theme.gutter_text), .bg = bg };
    const line_num_active_style: Style = .{ .fg = toVaxis(editor.tui_theme.gutter_text_active), .bg = bg };
    const gutter_sep_style: Style = .{ .fg = toVaxis(editor.tui_theme.gutter_separator), .bg = bg };
    const text_style: Style = .{ .fg = toVaxis(editor.tui_theme.text_fg), .bg = bg };
    const sel_style: Style = .{ .bg = toVaxis(editor.tui_theme.selection_bg), .fg = toVaxis(editor.tui_theme.selection_fg) };
    const tilde_style: Style = .{ .fg = toVaxis(editor.tui_theme.tilde), .bg = bg };
    const wrap_marker_style: Style = .{ .fg = toVaxis(editor.tui_theme.wrap_marker), .bg = bg };

    // Fill entire content area with theme background
    win.fill(.{ .style = .{ .bg = bg } });

    // Get selection range if any
    const sel = doc.cursors.primaryConst().selectionRange();

    var y: u16 = 0;
    var line_idx: usize = doc.scroll_top;

    while (y < height and line_idx < total_lines) {
        const line = doc.lineContent(line_idx);
        const is_current = (line_idx == cursor_pos.line);
        const num_style = if (is_current) line_num_active_style else line_num_style;

        // Tokenize line for syntax highlighting
        var span_buf: [syntax.MAX_SPANS]syntax.HighlightSpan = undefined;
        var span_count: usize = 0;
        if (doc.language) |lang| {
            const state = doc.ensureLineState(line_idx);
            const result = syntax.tokenizeLine(line, lang, state, &span_buf);
            span_count = result.count;
        }

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

            // Gutter separator (or diagnostic marker)
            if (wrap_row == 0) {
                const has_diag = for (doc.diagnostics.items) |*d| {
                    if (d.start_line <= line_idx and d.end_line >= line_idx) break d;
                } else null;
                if (has_diag) |diag| {
                    const diag_fg: Color = switch (diag.severity) {
                        .err => .{ .rgb = .{ 0xE0, 0x40, 0x40 } },
                        .warning => .{ .rgb = .{ 0xE0, 0xC0, 0x40 } },
                        .information => .{ .rgb = .{ 0x40, 0xA0, 0xE0 } },
                        .hint => .{ .rgb = .{ 0x80, 0x80, 0xA0 } },
                    };
                    _ = writeStr(win, gutter_width, y, "!", .{ .fg = diag_fg, .bg = bg });
                } else {
                    _ = writeStr(win, gutter_width, y, " ", gutter_sep_style);
                }
            } else {
                _ = writeStr(win, gutter_width, y, " ", gutter_sep_style);
            }

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

                    // Compute selection range for this segment (if any)
                    var sel_begin: usize = 0;
                    var sel_end_local: usize = 0;
                    var has_sel = false;
                    if (sel) |s| {
                        const line_start_offset = doc.buffer.posToOffset(line_idx, 0);
                        const abs_seg_start = line_start_offset + segment_start;
                        const abs_seg_end = line_start_offset + segment_end;
                        if (s.start < abs_seg_end and s.end > abs_seg_start) {
                            sel_begin = if (s.start > abs_seg_start) s.start - abs_seg_start else 0;
                            sel_end_local = if (s.end < abs_seg_end) s.end - abs_seg_start else segment.len;
                            has_sel = true;
                        }
                    }

                    if (span_count > 0) {
                        // Syntax-highlighted rendering with selection support
                        const syn_theme = editor.tuiSyntaxThemeFor(if (doc.language) |l| l.name else null);
                        var col: u16 = 0;
                        var seg_pos: usize = 0;

                        for (0..span_count) |si| {
                            const sp_start: usize = span_buf[si].start;
                            const sp_end: usize = span_buf[si].end;
                            // Map span to segment-local offsets
                            if (sp_end <= segment_start or sp_start >= segment_end) continue;
                            const vis_start = if (sp_start > segment_start) sp_start - segment_start else 0;
                            const vis_end = if (sp_end < segment_end) sp_end - segment_start else segment.len;

                            // Gap before span → default style (or selection)
                            if (vis_start > seg_pos) {
                                const gap = segment[seg_pos..vis_start];
                                const gap_style = if (has_sel and seg_pos < sel_end_local and vis_start > sel_begin)
                                    sel_style
                                else
                                    text_style;
                                col = writeStr(text_win, col, 0, gap, gap_style);
                            }

                            // Span → syntax color (selection overrides)
                            if (vis_end > vis_start) {
                                const span_text = segment[vis_start..vis_end];
                                // If fully inside selection, use sel_style; otherwise syntax color
                                if (has_sel and vis_start >= sel_begin and vis_end <= sel_end_local) {
                                    col = writeStr(text_win, col, 0, span_text, sel_style);
                                } else if (has_sel and vis_start < sel_end_local and vis_end > sel_begin) {
                                    // Partial overlap — split into pre-sel, sel, post-sel
                                    const pre_end = @max(vis_start, sel_begin);
                                    const post_start = @min(vis_end, sel_end_local);
                                    const token_fg = syn_theme.colorForToken(span_buf[si].token);
                                    const syn_style: Style = .{ .fg = if (token_fg) |tc| toVaxis(tc) else text_style.fg, .bg = bg };
                                    if (pre_end > vis_start) col = writeStr(text_win, col, 0, span_text[0 .. pre_end - vis_start], syn_style);
                                    if (post_start > pre_end) col = writeStr(text_win, col, 0, span_text[pre_end - vis_start .. post_start - vis_start], sel_style);
                                    if (vis_end > post_start) col = writeStr(text_win, col, 0, span_text[post_start - vis_start ..], syn_style);
                                } else {
                                    const token_fg = syn_theme.colorForToken(span_buf[si].token);
                                    const syn_style: Style = .{ .fg = if (token_fg) |tc| toVaxis(tc) else text_style.fg, .bg = bg };
                                    col = writeStr(text_win, col, 0, span_text, syn_style);
                                }
                            }
                            if (vis_end > seg_pos) seg_pos = vis_end;
                        }

                        // Trailing text after last span
                        if (seg_pos < segment.len) {
                            const trail = segment[seg_pos..];
                            const trail_style = if (has_sel and seg_pos < sel_end_local) sel_style else text_style;
                            _ = writeStr(text_win, col, 0, trail, trail_style);
                        }
                    } else if (has_sel) {
                        // No syntax highlighting, but has selection
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
                }
            }

            // Secondary cursors' selections (block selection) — the segment
            // renderer above only knows the primary's range, so restyle the
            // covered cells post-hoc, same as the diagnostic underlines below.
            if (doc.cursors.count() > 1 and text_start_x < width) {
                const line_start_offset = doc.buffer.posToOffset(line_idx, 0);
                const visible_start: usize = if (do_wrap) row_start else doc.scroll_left;
                const seg_start = @min(visible_start, line.len);
                const seg_end = if (do_wrap) row_end else @min(line.len, visible_start + text_width);
                const seg = line[seg_start..seg_end];
                const abs_seg_start = line_start_offset + seg_start;
                const abs_seg_end = line_start_offset + seg_end;
                for (doc.cursors.cursors.items[1..]) |sc| {
                    const r = sc.selectionRange() orelse continue;
                    if (!(r.start < abs_seg_end and r.end > abs_seg_start)) continue;
                    const lo = if (r.start > abs_seg_start) r.start - abs_seg_start else 0;
                    const hi = if (r.end < abs_seg_end) r.end - abs_seg_start else seg.len;
                    const cx_start = displayWidth(seg[0..@min(lo, seg.len)]);
                    const cx_end = displayWidth(seg[0..@min(hi, seg.len)]);
                    var cx: u16 = @intCast(@min(cx_start, text_width));
                    const cx_lim: u16 = @intCast(@min(cx_end, text_width));
                    while (cx < cx_lim) : (cx += 1) {
                        if (win.readCell(text_start_x + cx, y)) |cell| {
                            var new_cell = cell;
                            new_cell.style.bg = sel_style.bg;
                            new_cell.style.fg = sel_style.fg;
                            win.writeCell(text_start_x + cx, y, new_cell);
                        }
                    }
                }
            }

            // Apply diagnostic underlines to rendered text cells
            for (doc.diagnostics.items) |*diag| {
                if (diag.start_line == line_idx and wrap_row == 0) {
                    const visible_start_offset: usize = if (do_wrap) row_start else doc.scroll_left;
                    const ul_start = if (diag.start_col >= visible_start_offset) diag.start_col - @as(u32, @intCast(visible_start_offset)) else 0;
                    const ul_end_col = if (diag.end_line == line_idx) diag.end_col else @as(u32, @intCast(line.len));
                    const ul_end = if (ul_end_col >= visible_start_offset) ul_end_col - @as(u32, @intCast(visible_start_offset)) else 0;
                    const diag_fg: Color = switch (diag.severity) {
                        .err => .{ .rgb = .{ 0xE0, 0x40, 0x40 } },
                        .warning => .{ .rgb = .{ 0xE0, 0xC0, 0x40 } },
                        .information => .{ .rgb = .{ 0x40, 0xA0, 0xE0 } },
                        .hint => .{ .rgb = .{ 0x80, 0x80, 0xA0 } },
                    };
                    var cx: u16 = @intCast(@min(ul_start, text_width));
                    while (cx < @min(ul_end, text_width)) : (cx += 1) {
                        if (win.readCell(text_start_x + cx, y)) |cell| {
                            var new_cell = cell;
                            new_cell.style.ul = diag_fg;
                            new_cell.style.ul_style = .single;
                            win.writeCell(text_start_x + cx, y, new_cell);
                        }
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
fn drawSecondaryCursors(win: Window, doc: *Document, editor: *Editor, width: u16, height: u16, wrap: bool) void {
    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines, editor.gutter_min_digits);
    const text_start_x = gutter_width + 1;
    const text_width: u16 = if (width > text_start_x) width - text_start_x else 1;
    const cursor_style: Style = .{ .bg = toVaxis(editor.tui_theme.cursor_bg), .fg = toVaxis(editor.tui_theme.cursor_fg) };

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
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.status_bg), .fg = toVaxis(editor.tui_theme.status_fg), .bold = true };

    // Fill background
    win.fill(.{ .style = style });

    // Terminal pane: show simple label instead of doc info
    if (editor.activePaneIsTerminal()) {
        const label = blk: {
            if (editor.activePaneTerminalIdx()) |ti| {
                if (ti < editor.terminals.items.len) {
                    if (editor.terminals.items[ti]) |t| {
                        if (t.exited) break :blk " [TERMINAL - exited]";
                    }
                }
            }
            break :blk " [TERMINAL]";
        };
        _ = writeStr(win, 0, 0, label, style);
        return;
    }

    const doc = editor.activeDoc();
    const pos = doc.cursorPos();

    // Left side: " filename [+]" — use writeStr for formatted parts
    var x: u16 = writeStr(win, 0, 0, " ", style);
    // display_name is heap-allocated and persistent, safe for printSegment
    _ = win.printSegment(.{ .text = doc.display_name, .style = style }, .{ .col_offset = x, .wrap = .none });
    x +|= @intCast(@min(doc.display_name.len, width -| x));
    if (doc.dirty) {
        _ = writeStr(win, x, 0, " [+]", style);
    }

    // Center: transient status message ("Saved", "Cannot open: ...",
    // file-tree results) takes priority over the line diagnostic —
    // previously these were never rendered in normal mode at all.
    if (editor.status_message.len > 0) {
        const max_len = width / 2;
        const msg_len: u16 = @intCast(@min(editor.status_message.len, max_len));
        const center_x = (width -| msg_len) / 2;
        _ = writeStr(win, center_x, 0, editor.status_message[0..msg_len], style);
        // Right side still drawn below; skip the diagnostic this frame
    } else for (doc.diagnostics.items) |*diag| {
        if (diag.start_line <= pos.line and diag.end_line >= pos.line) {
            const diag_fg: Color = switch (diag.severity) {
                .err => .{ .rgb = .{ 0xE0, 0x40, 0x40 } },
                .warning => .{ .rgb = .{ 0xE0, 0xC0, 0x40 } },
                .information => .{ .rgb = .{ 0x40, 0xA0, 0xE0 } },
                .hint => .{ .rgb = .{ 0x80, 0x80, 0xA0 } },
            };
            const diag_style: Style = .{ .fg = diag_fg, .bg = style.bg };
            const max_len = width / 2;
            const msg_len: u16 = @intCast(@min(diag.message.len, max_len));
            const center_x = (width -| msg_len) / 2;
            _ = writeStr(win, center_x, 0, diag.message[0..msg_len], diag_style);
            break;
        }
    }

    // Right side: cursor position — use writeStr (stack buffer)
    var right_buf: [96]u8 = undefined;
    const cursor_count = doc.cursors.count();
    // Show the detected language so it's obvious what syntax/LSP applies.
    const lang_name: []const u8 = if (doc.language) |l| l.name else "plain text";
    const right = if (cursor_count > 1)
        std.fmt.bufPrint(&right_buf, "{d} cursors | Ln {d}, Col {d} | {s} ", .{ cursor_count, pos.line + 1, pos.col + 1, lang_name }) catch ""
    else
        std.fmt.bufPrint(&right_buf, "Ln {d}, Col {d} | {s} ", .{ pos.line + 1, pos.col + 1, lang_name }) catch "";
    const right_len: u16 = @intCast(@min(right.len, width));
    const right_x = width -| right_len;
    _ = writeStr(win, right_x, 0, right, style);
}

/// Calculate gutter width needed for line numbers.
/// Honors the user's gutter_min_digits setting (GUI already did).
fn lineNumberWidth(total_lines: usize, min_digits: usize) u16 {
    var digits: u16 = 1;
    var n = total_lines;
    while (n >= 10) {
        n /= 10;
        digits += 1;
    }
    const min: u16 = @intCast(@min(min_digits, 10));
    return @max(digits, @max(min, 1));
}

/// Position the real terminal cursor at the editor cursor location.
fn positionCursor(win: Window, editor: *Editor, width: u16, height: u16) void {
    _ = width;
    _ = height;
    var active_rect: ?PaneRect = null;
    for (pane_rects[0..pane_rect_count]) |pr| {
        if (pr.pane_id == editor.active_pane) {
            active_rect = pr;
            break;
        }
    }
    const rect = active_rect orelse {
        win.hideCursor();
        return;
    };

    // Terminal pane: mirror the embedded terminal's own cursor.
    if (editor.activePaneIsTerminal()) {
        const term: ?*terminal_mod.Terminal = blk: {
            const idx = editor.activePaneTerminalIdx() orelse break :blk null;
            if (idx >= editor.terminals.items.len) break :blk null;
            break :blk editor.terminals.items[idx];
        };
        const t = term orelse {
            win.hideCursor();
            return;
        };
        t.mutex.lockUncancelable(t.io);
        const trow = t.cursor_row;
        const tcol = t.cursor_col;
        const visible = t.cursor_visible and !t.exited;
        t.mutex.unlock(t.io);
        if (visible and trow < rect.h and tcol < rect.w) {
            win.showCursor(rect.x +| tcol, rect.y +| trow);
            win.setCursorShape(.block);
        } else {
            win.hideCursor();
        }
        return;
    }

    const doc = editor.activeDoc();
    const pos = doc.cursorPos();

    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines, editor.gutter_min_digits);
    const text_start_x = gutter_width + 1;
    const text_width: u16 = if (rect.w > text_start_x) rect.w - text_start_x else 1;

    if (editor.word_wrap) {
        // With wrapping: compute visual row by summing wrapped heights of preceding lines
        var visual_row: u16 = 0;
        var line_idx: usize = doc.scroll_top;
        while (line_idx < pos.line and line_idx < total_lines) : (line_idx += 1) {
            visual_row += wrapLineRows(doc.lineContent(line_idx), text_width);
        }
        const cur_line = doc.lineContent(pos.line);
        const wrap_pos = wrapColToVisual(cur_line, text_width, pos.col);
        visual_row += wrap_pos.row;

        const screen_y = rect.y +| visual_row;
        const screen_x = rect.x +| text_start_x +| wrap_pos.col;

        if (visual_row < rect.h and (text_start_x + wrap_pos.col) < rect.w) {
            win.showCursor(screen_x, screen_y);
            win.setCursorShape(.beam_blink);
        } else {
            win.hideCursor();
        }
    } else {
        const visible_line = pos.line -| doc.scroll_top;
        const visible_col = pos.col -| doc.scroll_left;

        const screen_y: u16 = rect.y +| @as(u16, @intCast(@min(visible_line, rect.h -| 1)));
        const screen_x: u16 = rect.x +| text_start_x +| @as(u16, @intCast(@min(visible_col, rect.w -| text_start_x)));

        if (visible_line < rect.h and (text_start_x + visible_col) < rect.w) {
            win.showCursor(screen_x, screen_y);
            win.setCursorShape(.beam_blink);
        } else {
            win.hideCursor();
        }
    }
}

/// Convert a screen position (x, y) in the editor area to a buffer offset.
/// Returns null if the position is outside the editor content area.
fn screenToOffset(editor: *Editor, screen_x: i16, screen_y: i16) ?usize {
    const hit = resolvePaneAt(editor, screen_x, screen_y) orelse return null;
    const pane = editor.layout.panes.items[hit.pane_id];
    const doc_idx = switch (pane.content) {
        .editor => |idx| idx,
        .terminal => return null,
    };
    if (doc_idx >= editor.documents.items.len) return null;
    const doc = &editor.documents.items[doc_idx];

    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines, editor.gutter_min_digits);
    const text_start_x: u16 = gutter_width + 1;

    // Must be in the text area of the pane
    if (hit.local_x < text_start_x) return null;
    const text_col: usize = hit.local_x - text_start_x;
    const content_row: usize = hit.local_y;

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
                // Click: position cursor — un-pin scroll, drop old status
                scroll_pinned = false;
                editor.status_message = "";

                // Tab bar click: switch document in active pane
                const tab_bar_height: i16 = if (editor.docCount() > 1) 1 else 0;
                if (tab_bar_height > 0 and mouse.row == 0) {
                    if (tabAtX(editor, @intCast(mouse.col))) |doc_idx| {
                        editor.switchToDoc(doc_idx);
                    }
                    return;
                }

                // File tree band: clicks focus/select/toggle/open in the tree
                if (filetree_band) |band| {
                    if (mouseOverFiletree(mouse)) {
                        handleFiletreeClick(editor, band, @intCast(mouse.col), @intCast(mouse.row));
                        return;
                    }
                }

                // Route click to the pane it landed in (takes focus back
                // from the file tree)
                if (resolvePaneAt(editor, mouse.col, mouse.row)) |hit| {
                    editor.active_pane = hit.pane_id;
                    editor.filetree_focused = false;
                    const pane = editor.layout.panes.items[hit.pane_id];
                    if (pane.content == .editor) {
                        editor.active_doc_idx = pane.content.editor;
                    }
                }

                block_drag = false;
                block_engaged = false;
                if (screenToOffset(editor, mouse.col, mouse.row)) |offset| {
                    const doc = editor.activeDoc();
                    if (mouse.mods.alt) {
                        // Alt+click adds a cursor; if a drag follows and leaves
                        // the press cell, it promotes to a block (column)
                        // selection. Plain Alt (not Shift+Alt) must arm it too:
                        // Windows Terminal swallows Shift+drag for its own
                        // selection and never forwards it.
                        const p = doc.buffer.offsetToPos(offset);
                        block_drag = true;
                        block_anchor_line = p.line;
                        block_anchor_col = p.col;
                        if (mouse.mods.shift) {
                            doc.cursors.clearSecondary();
                            const c = doc.cursors.primary();
                            c.clearSelection();
                            c.offset = offset;
                            c.preferred_col = p.col;
                        } else {
                            doc.cursors.addCursor(offset) catch {};
                        }
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
                if (screenToOffset(editor, mouse.col, mouse.row)) |offset| {
                    const doc = editor.activeDoc();
                    if (block_drag) {
                        // Block (column) selection: cursor per line, same col
                        // span. Only engage once the drag leaves the press
                        // cell, so a steady Alt+click never disturbs other
                        // alt-clicked cursors.
                        const p = doc.buffer.offsetToPos(offset);
                        if (block_engaged or p.line != block_anchor_line or p.col != block_anchor_col) {
                            block_engaged = true;
                            doc.cursors.setBlockSelection(
                                &doc.buffer,
                                block_anchor_line,
                                block_anchor_col,
                                p.line,
                                p.col,
                            ) catch {};
                        }
                    } else {
                        // Drag: extend selection
                        const c = doc.cursors.primary();
                        if (!c.hasSelection()) c.startSelection();
                        c.offset = offset;
                        c.preferred_col = doc.buffer.offsetToPos(offset).col;
                    }
                }
            } else if (mouse.type == .release) {
                block_drag = false;
                block_engaged = false;
            }
        },
        .wheel_up => {
            if (mouseOverFiletree(mouse)) {
                editor.tui_filetree_scroll -|= 3;
            } else {
                const doc = editor.activeDoc();
                doc.scroll_top -|= 5;
                scroll_pinned = true;
            }
        },
        .wheel_down => {
            if (mouseOverFiletree(mouse)) {
                editor.tui_filetree_scroll +|= 3; // clamped at draw time
            } else {
                const doc = editor.activeDoc();
                const max_top = doc.lineCount() -| 1;
                doc.scroll_top = @min(doc.scroll_top + 5, max_top);
                scroll_pinned = true;
            }
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
        Key.f1 => "f1",
        Key.f2 => "f2",
        Key.f3 => "f3",
        Key.f4 => "f4",
        Key.f5 => "f5",
        Key.f6 => "f6",
        Key.f7 => "f7",
        Key.f8 => "f8",
        Key.f9 => "f9",
        Key.f10 => "f10",
        Key.f11 => "f11",
        Key.f12 => "f12",
        // The keybind map spells this out ("alt+backslash"), and the GUI
        // converter agrees — the raw '\' character would never match.
        '\\' => "backslash",
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

/// Try the data-driven keybind map for ctrl/alt/F-key chords. Returns true
/// if the event was a chord (whether or not a binding ran) — chords never
/// fall through to text insertion. F-keys are never text input, so they go
/// through the map even unmodified (f12 = goto definition, f6 = focus pane).
fn tryKeybindCommand(editor: *Editor, key: Key) bool {
    const is_fkey = key.codepoint >= Key.f1 and key.codepoint <= Key.f12;
    if (!(key.mods.ctrl or key.mods.alt or is_fkey)) return false;

    var kbuf: [64]u8 = undefined;
    const key_str = keyToStr(key, &kbuf);
    if (key_str.len > 0) {
        if (editor.keybinds.get(key_str)) |action| {
            execTuiAction(editor, action);
            return true;
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
                    return true;
                }
            }
        }
    }
    return true;
}

/// Keys while the file tree owns the keyboard (filetree_focused, normal
/// mode). Global ctrl/alt chords still hit the keybind map first.
fn handleFiletreeKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;
    // Keep the "press p" hint visible while a move is pending
    if (editor.filetree_move_src == null) editor.status_message = "";
    if (tryKeybindCommand(editor, key)) return;
    const ft = editor.ensureFiletree() orelse {
        editor.filetree_focused = false;
        return;
    };
    switch (key.codepoint) {
        Key.escape => {
            // A pending move mark cancels first; second Esc leaves the tree
            if (editor.filetree_move_src != null) {
                editor.cancelFiletreeMove();
                editor.status_message = "Move cancelled";
            } else {
                editor.filetree_focused = false;
            }
        },
        Key.up, 'k' => {
            ft.moveSelection(-1);
            ft.scroll_to_selected = true;
        },
        Key.down, 'j' => {
            ft.moveSelection(1);
            ft.scroll_to_selected = true;
        },
        Key.home => {
            ft.selected = 0;
            ft.scroll_to_selected = true;
        },
        Key.end => {
            ft.selected = ft.visible.items.len -| 1;
            ft.scroll_to_selected = true;
        },
        Key.enter, Key.right => {
            const idx = ft.selectedNodeIdx() orelse return;
            if (ft.nodes.items[idx].kind == .dir) {
                if (key.codepoint == Key.right) {
                    ft.expand(idx) catch {};
                } else {
                    ft.toggle(idx) catch {};
                }
            } else {
                openFiletreeFileTui(editor, ft, idx);
                editor.filetree_focused = false;
            }
        },
        Key.left => {
            const idx = ft.selectedNodeIdx() orelse return;
            const node = ft.nodes.items[idx];
            if (node.kind == .dir and node.expanded) {
                ft.collapse(idx) catch {};
            } else if (idx != 0 and node.parent != 0) {
                if (ft.rowOf(node.parent)) |prow| {
                    ft.selected = prow;
                    ft.scroll_to_selected = true;
                }
            }
        },
        'a' => editor.startFiletreePrompt(.create),
        'd' => editor.startFiletreePrompt(.delete_confirm),
        'x' => editor.startFiletreeMove(),
        'p' => editor.applyFiletreeMove(),
        Key.backspace, 'u' => editor.filetreeRootUp(),
        'r', 'R' => {
            if (key.codepoint == 'R' or key.mods.shift) {
                _ = editor.execCommand("filetree_refresh", null);
            } else {
                editor.startFiletreePrompt(.rename);
            }
        },
        else => {},
    }
}

/// Handle a keyboard event from libvaxis.
fn handleKey(editor: *Editor, key_in: Key) void {
    var key = key_in;
    // Ignore modifier-only keys
    if (key.isModifier()) return;

    // Terminals without the kitty keyboard protocol send Ctrl+/ as the bare
    // C0 byte 0x1F with no mods (vaxis's legacy map stops at 0x1A) —
    // normalize so the "ctrl+/" keybind works everywhere.
    if (key.codepoint == 0x1f) {
        key.codepoint = '/';
        key.mods.ctrl = true;
        key.text = null;
    }

    // Any key press un-pins scroll (cursor tracking resumes) and drops
    // the previous transient status message
    scroll_pinned = false;
    editor.status_message = "";

    // Ctrl/Alt+key shortcuts — look up in keybind map.
    if (tryKeybindCommand(editor, key)) return;

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
fn drawOverlay(win: Window, editor: *Editor, label: []const u8, input: []const u8, width: u16, height: u16) void {
    const overlay_y: u16 = height -| 1;
    const overlay_win = win.child(.{
        .y_off = @intCast(overlay_y),
        .width = width,
        .height = 1,
    });
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_accent), .bold = true };
    const input_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
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

    const border_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_border) };
    const input_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg), .bold = true };
    const item_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    const selected_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_selection_bg), .fg = toVaxis(editor.tui_theme.overlay_selection_fg), .bold = true, .reverse = true };

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
    const names = editor.commands.allNames() catch return;

    // Count matches to clamp selection
    var match_count: usize = 0;
    for (names) |name| {
        if (filter.len > 0 and !fuzzyMatch(name, filter)) continue;
        match_count += 1;
    }
    const visible_count = @min(match_count, max_items);
    if (visible_count > 0) {
        if (editor.palette_selected >= visible_count) editor.palette_selected = visible_count - 1;
    } else {
        editor.palette_selected = 0;
    }

    var shown: usize = 0;
    for (names) |name| {
        if (item_y > max_items) break;
        if (filter.len > 0 and !fuzzyMatch(name, filter)) continue;

        const is_selected = shown == editor.palette_selected;
        const style = if (is_selected) selected_style else item_style;

        const row_win = win.child(.{
            .x_off = @intCast(palette_x),
            .y_off = @intCast(input_y + item_y),
            .width = palette_width,
            .height = 1,
        });
        row_win.fill(.{ .style = style });
        _ = row_win.printSegment(.{ .text = " ", .style = style }, .{ .wrap = .none });
        const name_win = row_win.child(.{ .x_off = 1, .width = palette_width -| 1 });
        _ = name_win.printSegment(.{ .text = name, .style = style }, .{ .wrap = .none });
        item_y += 1;
        shown += 1;
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

/// Draw the completion popup near the cursor position.
fn drawCompletionPopup(win: Window, editor: *Editor, width: u16, height: u16) void {
    if (!editor.completion_active) return;
    const items = editor.completion_items.items;
    if (items.len == 0) return;

    const max_visible: u16 = @min(@as(u16, @intCast(items.len)), @min(height / 3, 10));
    if (max_visible == 0) return;

    // Calculate popup position relative to cursor
    const doc = editor.activeDoc();
    const cursor = doc.cursors.primaryConst();
    const cursor_pos = doc.buffer.offsetToPos(cursor.offset);

    // Gutter width
    const line_count = doc.lineCount();
    var digits: u16 = 1;
    {
        var n = line_count;
        while (n >= 10) : (digits += 1) n /= 10;
    }
    const gutter_w: u16 = digits + 2;

    // Cursor screen position (approximate — does not account for scroll offset perfectly)
    const cursor_screen_col: u16 = gutter_w + @as(u16, @intCast(@min(cursor_pos.col, width -| gutter_w -| 1)));
    const cursor_screen_row: u16 = blk: {
        const cl = cursor_pos.line;
        const sv = doc.scroll_top;
        if (cl < sv) break :blk 1; // tab bar row
        const row = @as(u16, @intCast(@min(cl - sv, height -| 3)));
        break :blk row + 1; // +1 for tab bar
    };

    // Position popup below cursor, or above if near bottom
    const popup_width: u16 = @min(width -| 2, 40);
    var popup_x: u16 = @min(cursor_screen_col, width -| popup_width);
    _ = &popup_x;
    var popup_y: u16 = cursor_screen_row + 1;
    if (popup_y + max_visible >= height -| 1) {
        // Not enough space below — show above cursor
        popup_y = cursor_screen_row -| max_visible;
    }

    const item_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    const selected_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_selection_bg), .fg = toVaxis(editor.tui_theme.overlay_selection_fg), .bold = true, .reverse = true };

    // Scroll the completion list if selected item is past visible range
    const scroll_off: usize = if (editor.completion_selected >= max_visible)
        editor.completion_selected - max_visible + 1
    else
        0;

    var row: u16 = 0;
    while (row < max_visible) : (row += 1) {
        const idx = scroll_off + row;
        if (idx >= items.len) break;
        const item = items[idx];
        const is_selected = idx == editor.completion_selected;
        const style = if (is_selected) selected_style else item_style;

        const row_win = win.child(.{
            .x_off = popup_x,
            .y_off = popup_y + row,
            .width = popup_width,
            .height = 1,
        });
        row_win.fill(.{ .style = style });
        _ = row_win.printSegment(.{ .text = " ", .style = style }, .{ .wrap = .none });
        const label_win = row_win.child(.{ .x_off = 1, .width = popup_width -| 1 });
        _ = label_win.printSegment(.{ .text = item.label, .style = style }, .{ .wrap = .none });

        // Show detail if present (right-aligned or after label)
        if (item.detail) |detail| {
            if (detail.len > 0 and detail.len + item.label.len + 3 < popup_width) {
                const detail_x: u16 = @intCast(item.label.len + 2);
                const dim_style: Style = .{
                    .bg = style.bg,
                    .fg = toVaxis(editor.tui_theme.overlay_dim),
                };
                const detail_win = row_win.child(.{ .x_off = detail_x + 1, .width = popup_width -| detail_x -| 1 });
                _ = detail_win.printSegment(.{ .text = detail, .style = dim_style }, .{ .wrap = .none });
            }
        }
    }
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
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_accent), .bold = true };
    const input_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    const inactive_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_dim) };

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
        const msg_style2: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_warn) };
        const msg_len: u16 = @intCast(@min(editor.status_message.len, width));
        const msg_x: u16 = width -| msg_len -| 1;
        const msg_win = win.child(.{ .y_off = @intCast(find_y), .width = width, .height = 1 });
        _ = writeStr(msg_win, msg_x, 0, editor.status_message, msg_style2);
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
            // insertAtCursor replaces the active selection as one undo step
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

    // The whole replace-all is one undo step.
    doc.history.beginGroup();
    defer doc.history.endGroup();

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
            // Save all dirty documents, then quit — but only if every save
            // succeeded (silently discarding on failure loses work).
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
        // Empty query — restore cursor to origin (no empty selection)
        doc.cursors.primary().offset = editor.find_origin;
        doc.cursors.primary().clearSelection();
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
    // No match — keep cursor at origin (no empty selection)
    doc.cursors.primary().offset = editor.find_origin;
    doc.cursors.primary().clearSelection();
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
            editor.activeDoc().saveAs(editor.io, path) catch {
                editor.status_message = "Save failed";
            };
            editor.activeDoc().detectLanguage(editor);
            editor.noteFileSaved(true, editor.activeDoc());
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

/// Handle keys in file-tree prompt mode (create / rename / delete confirm).
fn handleFiletreePromptKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        editor.cancelFiletreePrompt();
        return;
    }
    if (editor.filetree_prompt_kind == .delete_confirm) {
        if (key.codepoint == 'y' or key.codepoint == 'Y' or key.codepoint == Key.enter) {
            editor.applyFiletreePrompt();
        } else if (key.codepoint == 'n' or key.codepoint == 'N') {
            editor.cancelFiletreePrompt();
        }
        return;
    }
    if (key.codepoint == Key.enter) {
        editor.applyFiletreePrompt();
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
        editor.palette_selected = 0;
        return;
    }
    if (key.codepoint == Key.enter) {
        // Execute the selected matching command
        const filter = editor.palette_buf[0..editor.palette_buf_len];
        const names = editor.commands.allNames() catch {
            editor.mode = .normal;
            editor.palette_selected = 0;
            return;
        };
        var idx: usize = 0;
        for (names) |name| {
            if (filter.len > 0 and !fuzzyMatch(name, filter)) continue;
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
        return;
    }
    if (key.codepoint == Key.tab or key.codepoint == Key.down) {
        editor.palette_selected += 1;
        return;
    }
    if (key.codepoint == Key.up) {
        editor.palette_selected -|= 1;
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.palette_buf_len > 0) {
            editor.palette_buf_len -= 1;
            editor.palette_selected = 0;
        }
        return;
    }
    editor.palette_selected = 0;
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

/// Handle keys when the completion popup is active.
fn handleCompletionKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    const item_count = editor.completion_items.items.len;
    switch (key.codepoint) {
        Key.escape => {
            editor.clearCompletionItems();
        },
        Key.enter, Key.tab => {
            editor.acceptCompletion();
        },
        Key.up => {
            if (editor.completion_selected > 0) {
                editor.completion_selected -= 1;
            } else if (item_count > 0) {
                editor.completion_selected = item_count - 1;
            }
        },
        Key.down => {
            if (item_count > 0) {
                editor.completion_selected = (editor.completion_selected + 1) % item_count;
            }
        },
        else => {
            // Any other key dismisses completion and passes through to normal handler
            editor.clearCompletionItems();
            handleKey(editor, key);
        },
    }
}
