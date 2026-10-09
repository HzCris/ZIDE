const std = @import("std");
const builtin = @import("builtin");
const text_input = @import("../core/text_input.zig");
const vaxis = @import("vaxis");
const keybind = @import("../core/keybind.zig");
const cursor_mod = @import("../core/cursor.zig");
const lua_api = @import("../core/lua_api.zig");
const Editor = @import("../core/editor.zig").Editor;
const Document = @import("../core/document.zig").Document;
const Layout = @import("../core/layout.zig").Layout;
const TuiColor = @import("../core/theme.zig").TuiColor;
const syntax = @import("../core/syntax.zig");
const brackets = @import("../core/brackets.zig");
const lsp = @import("../core/lsp.zig");
const terminal_mod = @import("../core/terminal.zig");
const filetree_mod = @import("../core/filetree.zig");
const fileicons = @import("../core/fileicons.zig");
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

/// Style for a syntax token: theme color plus markdown text attributes
/// (headings/bold render bold, italics italic, links underlined).
fn synTokenStyle(syn_theme: anytype, token: syntax.TokenType, default_fg: Color, bg: Color) Style {
    var st: Style = .{
        .fg = if (syn_theme.colorForToken(token)) |tc| toVaxis(tc) else default_fg,
        .bg = bg,
    };
    switch (token) {
        .heading, .strong => st.bold = true,
        .emphasis => st.italic = true,
        .link => st.ul_style = .single,
        else => {},
    }
    return st;
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
/// the top of each frame in `run`. Sized for a large screen of non-ASCII
/// terminal cells (btop, lazygit) plus the editor panes: 128 KB ran out and
/// cells rendered as "?".
var grapheme_arena: [256 * 1024]u8 = undefined;
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

/// Copy temporary strings into frame storage, then let vaxis measure and
/// render graphemes (including combining marks and double-width characters).
fn writeStr(win: Window, col: u16, row: u16, text: []const u8, style: Style) u16 {
    return win.printSegment(.{ .text = frameArenaDupe(text), .style = style }, .{
        .col_offset = col,
        .row_offset = row,
        .wrap = .none,
    }).col;
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
        const r = info.srWindow;
        const cols: u16 = @intCast(std.math.clamp(@as(i32, r.Right) - r.Left + 1, 1, std.math.maxInt(u16)));
        const rows: u16 = @intCast(std.math.clamp(@as(i32, r.Bottom) - r.Top + 1, 1, std.math.maxInt(u16)));
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
    /// Bracketed paste (POSIX terminals — vaxis's Windows reader forwards
    /// no paste markers): the key presses between these two are the pasted
    /// text, collected and applied as one edit (`pasteKey`).
    paste_start,
    paste_end,
    /// OSC 52 clipboard reply (only ever sent after a request); freed with
    /// the loop's paste allocator.
    paste: []const u8,
    lsp_data,
    terminal_data,
    lua_job_data,
};

/// Module-level loop pointer for reader-thread wake callbacks (LSP +
/// terminal). Nulled before the loop dies so a late wake can't post to a
/// dangling pointer (a reader preempted mid-call is a theoretical residual
/// race; both threads are joined moments later in the deinit path).
var global_loop: ?*vaxis.Loop(Event) = null;

// The wakes never block: `tryPostEvent` drops the wake when the queue is
// full — the queued events already guarantee the main loop runs again. (A
// blocking post parked worker threads on a full queue; with a wake called
// under a job/peer mutex, the UI then froze waiting on that mutex.)

/// Wake function called from LSP reader thread to unblock nextEvent.
fn lspWakeFn() void {
    if (global_loop) |loop_ptr| {
        _ = loop_ptr.tryPostEvent(.lsp_data) catch false;
    }
}

/// Wake function called from terminal reader threads when new PTY output
/// landed in a grid — unblocks nextEvent so the pane repaints.
fn terminalWakeFn() void {
    if (global_loop) |loop_ptr| {
        _ = loop_ptr.tryPostEvent(.terminal_data) catch false;
    }
}

/// Wake function called from zide.spawn worker threads when a result is
/// queued — unblocks nextEvent so pumpLuaJobs runs promptly.
fn luaJobWakeFn() void {
    if (global_loop) |loop_ptr| {
        _ = loop_ptr.tryPostEvent(.lua_job_data) catch false;
    }
}

/// One loop event. Window resizes need the tty; everything else is input.
fn processEvent(editor: *Editor, vx: *vaxis.Vaxis, allocator: std.mem.Allocator, writer: *std.Io.Writer, event: Event) !void {
    switch (event) {
        .winsize => |ws| {
            try vx.resize(allocator, writer, ws);
            vx.refresh = true;
        },
        else => handleInputEvent(editor, event, vx.opts.system_clipboard_allocator),
    }
}

/// Keyboard, mouse and paste events. `paste_alloc` frees `.paste` payloads.
fn handleInputEvent(editor: *Editor, event: Event, paste_alloc: ?std.mem.Allocator) void {
    switch (event) {
        .key_press => |key| if (paste_active) pasteKey(editor, key) else dispatchKey(editor, key),
        .mouse => |mouse| {
            // A paste never contains clicks: one arriving mid-paste means the
            // end marker was lost — apply what came and stop collecting keys.
            if (paste_active) finishPaste(editor);
            handleMouse(editor, mouse);
        },
        .paste_start => {
            paste_active = true;
            paste_buf.clearRetainingCapacity();
        },
        .paste_end => if (paste_active) finishPaste(editor),
        .paste => |text| {
            applyPaste(editor, text);
            if (paste_alloc) |a| a.free(text);
        },
        else => {},
    }
}

fn finishPaste(editor: *Editor) void {
    paste_active = false;
    applyPaste(editor, paste_buf.items);
    paste_buf.clearRetainingCapacity();
    // Don't keep a huge paste's buffer around
    if (paste_buf.capacity > 1 << 20) paste_buf.clearAndFree(editor.allocator);
}

// ===========================================================================
// Paste
// ===========================================================================

/// Bracketed-paste collector. Between paste_start and paste_end the pasted
/// text arrives as ordinary key presses; typed one by one they ran Enter's
/// auto-indent and the auto-closing brackets (staircase indentation,
/// doubled brackets), so they are gathered here and applied once.
var paste_active: bool = false;
var paste_buf: std.ArrayList(u8) = .empty;
/// A runaway paste stops collecting here (the rest is dropped).
const paste_limit: usize = 64 * 1024 * 1024;

/// Collect one pasted key. Raw line breaks are kept (CR from Enter, LF
/// from a legacy Ctrl+J) and normalized when the paste is applied.
fn pasteKey(editor: *Editor, key: Key) void {
    var cp_buf: [4]u8 = undefined;
    const bytes: []const u8 = switch (key.codepoint) {
        Key.enter => "\r",
        Key.tab => "\t",
        else => blk: {
            if (key.mods.ctrl and key.codepoint == 'j' and key.text == null) break :blk "\n";
            if (key.mods.ctrl or key.mods.alt) break :blk ""; // other control bytes
            if (key.text) |text| break :blk text;
            if (key.codepoint < 0x20 or (key.codepoint >= 0xE000 and key.codepoint <= 0xF8FF)) break :blk "";
            const n = std.unicode.utf8Encode(key.codepoint, &cp_buf) catch break :blk "";
            break :blk cp_buf[0..n];
        },
    };
    if (paste_buf.items.len + bytes.len > paste_limit) return;
    paste_buf.appendSlice(editor.allocator, bytes) catch {};
}

/// First line of `text` (up to the first CR or LF).
fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfAny(u8, text, "\r\n") orelse text.len];
}

/// Where a paste goes: the focused terminal's program (bracketed when it
/// asked for that), the document as one edit, the search field or a
/// single-line prompt as typed text (its first line). Pickers and
/// confirmation prompts never take a paste — a pasted letter must not
/// answer them.
fn applyPaste(editor: *Editor, text: []const u8) void {
    if (text.len == 0) return;
    editor.validateSnippetState();
    defer editor.validateSnippetState();
    switch (editor.mode) {
        .normal => switch (editor.keyboardOwner()) {
            .terminal => if (activeTerminal(editor)) |term| term.paste(text),
            .editor => pasteIntoDocument(editor, text),
            .search => typeLine(editor, firstLine(text)),
            .filetree => {},
        },
        .find, .find_replace, .file_open, .folder_open, .save_as, .command_palette, .picker, .goto_line, .file_finder, .symbol_rename => typeLine(editor, firstLine(text)),
        .filetree_prompt => if (editor.filetree_prompt_kind != .delete_confirm) typeLine(editor, firstLine(text)),
        else => {},
    }
}

/// Insert pasted text at every cursor as ONE edit: no auto-indent, no
/// auto-closed brackets. Line breaks become the document's; other control
/// characters are dropped.
fn pasteIntoDocument(editor: *Editor, text: []const u8) void {
    editor.clearCompletionItems();
    const doc = editor.activeDoc();
    const eol = doc.lineEnding();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(editor.allocator);
    out.ensureTotalCapacity(editor.allocator, text.len) catch {
        editor.status_message = "Paste failed: out of memory";
        return;
    };
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const b = text[i];
        const ok = switch (b) {
            '\r', '\n' => blk: {
                if (b == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
                break :blk out.appendSlice(editor.allocator, eol);
            },
            '\t' => out.append(editor.allocator, '\t'),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => {},
            else => out.append(editor.allocator, b),
        };
        ok catch {
            editor.status_message = "Paste failed: out of memory";
            return;
        };
    }
    doc.insertAtAllCursors(out.items) catch {
        editor.status_message = "Paste failed: out of memory";
        return;
    };
    scroll_pinned = false;
    editor.status_message = "";
}

/// Type `line` into the focused input as key presses (control characters
/// skipped): the search field and the single-line prompts.
fn typeLine(editor: *Editor, line: []const u8) void {
    var i: usize = 0;
    while (i < line.len) {
        const ch = charAt(line, i);
        const bytes = line[i..][0..ch.len];
        i += ch.len;
        if (ch.cp < 0x20 or ch.cp == 0x7F or (ch.cp == 0xFFFD and bytes.len == 1)) continue;
        dispatchKey(editor, .{ .codepoint = ch.cp, .text = bytes });
    }
}

/// The terminal shown in the focused pane, if any.
fn activeTerminal(editor: *Editor) ?*terminal_mod.Terminal {
    const idx = editor.activePaneTerminalIdx() orelse return null;
    if (idx >= editor.terminals.items.len) return null;
    return editor.terminals.items[idx];
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
    // Language servers start lazily (per opened language) — the editor
    // copies this into each client before its reader thread exists.
    editor.lsp_wake_fn = &lspWakeFn;
    editor.terminal_wake_fn = &terminalWakeFn;
    // Search worker results wake the blocking loop the same way.
    editor.search.wake_fn = &terminalWakeFn;
    @import("../core/lua_api.zig").setLuaWake(editor, &luaJobWakeFn);
    defer @import("../core/lua_api.zig").setLuaWake(editor, null);

    // Enter alternate screen
    try vx.enterAltScreen(tty.writer());
    // Mouse reporting and bracketed paste (vx.deinit turns both off again).
    // POSIX only: a Windows console already delivers mouse events (vaxis
    // sets MOUSE_INPUT) and vaxis's Windows reader forwards no paste
    // markers. Without these, Linux/macOS terminals had no mouse at all and
    // pastes arrived as typed keys.
    if (builtin.os.tag != .windows) {
        try vx.setMouseMode(tty.writer(), true);
        try vx.setBracketedPaste(tty.writer(), true);
    }
    defer paste_buf.clearAndFree(editor.allocator);

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

    // Main loop
    while (editor.running) {
        // Drain all pending events
        while (loop.tryEvent() catch null) |event| {
            try processEvent(editor, &vx, allocator, tty.writer(), event);
        }

        // Language servers: sweep dead ones, drain messages, sync documents
        // (starts servers lazily for newly opened languages)
        editor.lspTick();

        // Deliver finished zide.spawn results to their Lua callbacks
        editor.pumpLuaJobs();

        editor.serviceTick(std.Io.Clock.now(.awake, editor.io).nanoseconds);

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

        // Pull in workspace-search results (worker wakes the loop on new hits)
        _ = editor.search.drain();

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
            // Same deadline wait as a normal frame: auto-save, file polls and
            // queued LSP work keep running while the window is tiny.
            const tiny_micros = editor.deadlines.waitMicros(std.Io.Clock.now(.awake, editor.io).nanoseconds);
            const event = try loop.nextEventTimeout(.{ .duration = .{ .raw = .fromMicroseconds(tiny_micros), .clock = .awake } }) orelse continue;
            try processEvent(editor, &vx, allocator, tty.writer(), event);
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
            .folder_open => {
                drawOverlay(win, editor, "Open folder: ", editor.open_buf[0..editor.open_buf_len], width, height);
            },
            .recent_projects => drawRecentProjects(win, editor, width, height),
            .save_as => {
                drawOverlay(win, editor, "Save As: ", editor.open_buf[0..editor.open_buf_len], width, height);
            },
            .command_palette => {
                drawCommandPalette(win, editor, width, height);
            },
            .picker => drawPicker(win, editor, width, height),
            .goto_line => {
                drawOverlay(win, editor, "Go to line: ", editor.goto_buf[0..editor.goto_buf_len], width, height);
            },
            .file_finder => {
                drawFileFinder(win, editor, width, height);
            },
            .confirm_quit => {
                drawOverlay(win, editor, "Unsaved changes! [S]ave [D]iscard [C]ancel: ", "", width, height);
            },
            .confirm_close => {
                var msg_buf: [320]u8 = undefined;
                drawOverlay(win, editor, editor.confirmClosePrompt(&msg_buf), "", width, height);
            },
            .encoding_picker => drawEncodingPicker(win, editor, width, height),
            .recovery_picker => drawRecoveryPicker(win, editor, width, height),
            .lsp_panel, .workspace_preview => drawLspPanel(win, editor, width, height),
            .symbol_rename => drawOverlay(win, editor, "Rename symbol (Enter previews): ", editor.lsp_tools.name[0..editor.lsp_tools.name_len], width, height),
            .tool_panel => drawToolPanel(win, editor, width, height),
            .task_save_prompt => drawOverlay(win, editor, "Before running: [S]ave and run / [R]un saved files / [C]ancel", "", width, height),
            .git_stage_prompt => drawOverlay(win, editor, "Stage saved contents: [S]ave and stage / [C]ancel", "", width, height),
            .confirm_reopen => drawOverlay(win, editor, "Reopen: [S]ave changes / [D]iscard / [C]ancel", "", width, height),
            .confirm_encoding => drawOverlay(win, editor, "Cannot encode text: [S]ave as UTF-8 / [C]ancel", "", width, height),
            .confirm_overwrite => {
                drawOverlay(win, editor, editor.overwritePrompt(), "", width, height);
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
                        const del_count = if (editor.filetree) |*t| t.selectionCount() else 1;
                        const title = if (del_count > 1)
                            std.fmt.bufPrint(&buf, "Delete {d} selected items? [Y]es / any other key cancels: ", .{del_count}) catch "Delete? [Y]es / any other key cancels: "
                        else
                            std.fmt.bufPrint(&buf, "Delete {s}? [Y]es / any other key cancels: ", .{target}) catch "Delete? [Y]es / any other key cancels: ";
                        drawOverlay(win, editor, title, "", width, height);
                    },
                }
            },
            // The caret follows the keyboard: the editor's or the terminal's
            // cursor, none while a side panel owns the keys (the tree and the
            // search panel draw their own selection / field marker).
            .normal => switch (editor.keyboardOwner()) {
                .editor, .terminal => positionCursor(win, editor, width, height),
                .filetree, .search => win.hideCursor(),
            },
        }

        // Signature help above the caret, then the completion popup on top
        if (editor.signatureVisible()) drawSignatureHelp(win, editor, width, height);
        // Draw completion popup on top of everything (when active)
        if (editor.completion_active) {
            drawCompletionPopup(win, editor, width, height);
        }

        try vx.render(tty.writer());

        // Sleep until input/background work or the next shared deadline.
        const micros = editor.deadlines.waitMicros(std.Io.Clock.now(.awake, editor.io).nanoseconds);
        const event = try loop.nextEventTimeout(.{ .duration = .{ .raw = .fromMicroseconds(micros), .clock = .awake } }) orelse continue;
        try processEvent(editor, &vx, allocator, tty.writer(), event);
    }
}

/// Dispatch key based on current editor mode.
fn dispatchKey(editor: *Editor, key: Key) void {
    editor.validateSnippetState();
    defer editor.validateSnippetState();
    // The close-after-Save-As hand-off only spans one Save As prompt.
    if (editor.mode != .save_as) close_tab_after_save_as = false;
    // Normal mode: exactly one owner gets the keys. A focused side panel
    // outranks the focused pane — a terminal pane used to swallow keys
    // meant for the tree or the search field shown focused beside it.
    if (editor.mode == .normal) {
        switch (editor.keyboardOwner()) {
            .terminal => return handleTerminalKey(editor, key),
            .filetree => return handleFiletreeKey(editor, key),
            .search => return handleSearchKey(editor, key),
            .editor => {},
        }
    }
    if (editor.editorOwnsInput() and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
        const snippet_key: ?Editor.SnippetKey = switch (key.codepoint) {
            Key.tab => if (key.mods.shift) .shift_tab else .tab,
            Key.escape => .escape,
            else => null,
        };
        if (snippet_key) |k| if (editor.handleSnippetKey(k)) {
            scroll_pinned = false;
            return;
        };
    }
    // Only the editor can consume completion and snippet keys.
    if (editor.editorOwnsInput() and editor.completion_active) {
        handleCompletionKey(editor, key);
        return;
    }
    // The inline prompts below answer only unmodified letters: Ctrl+S or
    // Ctrl+D pressed out of habit must not stage, save or discard.
    const plain = !hasCommandMod(key);
    switch (editor.mode) {
        .normal => handleKey(editor, key),
        .find => handleFindKey(editor, key),
        .find_replace => handleFindReplaceKey(editor, key),
        .file_open => handleFileOpenKey(editor, key),
        .folder_open => handleFolderOpenKey(editor, key),
        .recent_projects => handleRecentProjectsKey(editor, key),
        .save_as => handleSaveAsKey(editor, key),
        .command_palette => handlePaletteKey(editor, key),
        .picker => handlePickerKey(editor, key),
        .file_finder => handleFinderKey(editor, key),
        .goto_line => handleGotoLineKey(editor, key),
        .confirm_quit => handleConfirmQuitKey(editor, key),
        .confirm_close => handleConfirmCloseKey(editor, key),
        .confirm_overwrite => handleConfirmOverwriteKey(editor, key),
        .encoding_picker, .confirm_reopen, .confirm_encoding => handleEncodingKey(editor, key),
        .lsp_panel, .symbol_rename, .workspace_preview => handleLspKey(editor, key),
        .tool_panel => handleToolKey(editor, key),
        .git_stage_prompt => if (plain) switch (key.codepoint) {
            's', 'S' => editor.git.resolveStage(editor, true),
            'c', 'C', Key.escape => editor.git.resolveStage(editor, false),
            else => {},
        },
        .task_save_prompt => if (plain) switch (key.codepoint) {
            's', 'S' => editor.tasks.resolveSave(editor, .save),
            'r', 'R' => editor.tasks.resolveSave(editor, .run),
            'c', 'C', Key.escape => editor.tasks.resolveSave(editor, .cancel),
            else => {},
        },
        .recovery_picker => if (plain) switch (key.codepoint) {
            'r', 'R' => editor.resolveRecovery(.recover),
            'd', 'D' => editor.resolveRecovery(.discard),
            'l', 'L', Key.escape => editor.resolveRecovery(.later),
            else => {},
        },
        .settings => {
            // Settings panel is GUI-only; Escape returns to normal
            if (key.codepoint == Key.escape) editor.setMode(.normal);
        },
        .filetree_prompt => handleFiletreePromptKey(editor, key),
    }
}

/// A chord modifier (Ctrl, Alt, Super) is held: such a key is never a
/// letter answering a prompt.
fn hasCommandMod(key: Key) bool {
    return key.mods.ctrl or key.mods.alt or key.mods.super;
}

/// Handle key events when focused on a terminal pane.
fn handleTerminalKey(editor: *Editor, key: Key) void {
    // Modifier keys alone send nothing (their private-use codes used to be
    // dropped by accident; now explicitly).
    if (key.isModifier()) return;
    // ctrl+backtick (`) toggles back to editor
    if (key.codepoint == '`' and key.mods.ctrl and !key.mods.alt) {
        editor.toggleTerminal();
        return;
    }
    // Pane / window / terminal management chords (ctrl+alt+q close,
    // ctrl+alt+` detach, F6 focus, ...) are not typed into the shell.
    var kbuf: [64]u8 = undefined;
    const combo = keyToStr(key, &kbuf);
    if (combo.len > 0) {
        if (editor.terminalPassthroughAction(combo)) |action| {
            _ = editor.execAction(action);
            return;
        }
    }

    const term = activeTerminal(editor) orelse return;
    var out: [64]u8 = undefined;
    const bytes = terminalKeyBytes(key, term.appCursorKeys(), &out);
    if (bytes.len > 0) term.writeInput(bytes);
}

/// ZIDE's terminal key code (terminal.zig `key_*`) for a vaxis special key,
/// or null. vaxis reports the specials as kitty private-use code points
/// (Up = 57352) — sent as text they reached the shell as UTF-8 junk.
fn mapVaxisKey(codepoint: u21) ?u21 {
    return switch (codepoint) {
        Key.enter, Key.kp_enter => 0x0D,
        Key.tab => 0x09,
        Key.backspace => 0x7F,
        Key.escape => 0x1B,
        Key.up, Key.kp_up => terminal_mod.key_up,
        Key.down, Key.kp_down => terminal_mod.key_down,
        Key.left, Key.kp_left => terminal_mod.key_left,
        Key.right, Key.kp_right => terminal_mod.key_right,
        Key.home, Key.kp_home => terminal_mod.key_home,
        Key.end, Key.kp_end => terminal_mod.key_end,
        Key.page_up, Key.kp_page_up => terminal_mod.key_page_up,
        Key.page_down, Key.kp_page_down => terminal_mod.key_page_down,
        Key.insert, Key.kp_insert => terminal_mod.key_insert,
        Key.delete, Key.kp_delete => terminal_mod.key_delete,
        Key.f1...Key.f12 => terminal_mod.key_f1 + (codepoint - Key.f1),
        else => null,
    };
}

/// The bytes a key press sends to a terminal pane's program: VT sequences
/// for the special keys (xterm modifier parameters; SS3 arrows when the
/// program switched on application cursor keys), C0 bytes for Ctrl chords
/// (Ctrl+[ is ESC), and otherwise the key's text — every byte of it, so
/// emoji, CJK and multi-code-point graphemes arrive whole. Empty when the
/// key sends nothing (modifier-only and media keys).
fn terminalKeyBytes(key: Key, app_cursor: bool, out: *[64]u8) []const u8 {
    const ctrl = key.mods.ctrl;
    const alt = key.mods.alt;
    var enc: [16]u8 = undefined;
    if (mapVaxisKey(key.codepoint)) |code| {
        const n = terminal_mod.Terminal.encodeKeyMode(code, ctrl, alt, key.mods.shift, app_cursor, &enc);
        @memcpy(out[0..n], enc[0..n]);
        return out[0..n];
    }
    // Typed text (Alt = ESC prefix). A Ctrl chord's text is the plain
    // character on some consoles, so those take encodeKey's C0 table.
    if (!ctrl) if (key.text) |text| if (text.len > 0 and text.len < out.len) {
        const n: usize = if (alt) 1 else 0;
        out[0] = 0x1B;
        @memcpy(out[n..][0..text.len], text);
        return out[0 .. n + text.len];
    };
    // Private-use codes without text (modifier and media keys) and
    // multi-code-point keys whose text was lost send nothing.
    if (key.codepoint >= 0xE000 and key.codepoint <= 0xF8FF) return out[0..0];
    if (key.codepoint > 0x10FFFF) return out[0..0];
    const n = terminal_mod.Terminal.encodeKey(key.codepoint, ctrl, alt, key.mods.shift, &enc);
    @memcpy(out[0..n], enc[0..n]);
    return out[0..n];
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

/// Find which pane contains screen coordinates (col, row). Returns pane_id,
/// the local (pane-relative) coordinates and the pane's rect.
fn resolvePaneAt(editor: *Editor, col: i16, row: i16) ?struct { pane_id: u8, local_x: u16, local_y: u16, rect: PaneRect } {
    _ = editor;
    if (col < 0 or row < 0) return null;
    const cx: u16 = @intCast(col);
    const ry: u16 = @intCast(row);
    for (pane_rects[0..pane_rect_count]) |pr| {
        if (cx >= pr.x and cx < pr.x + pr.w and ry >= pr.y and ry < pr.y + pr.h) {
            return .{ .pane_id = pr.pane_id, .local_x = cx - pr.x, .local_y = ry - pr.y, .rect = pr };
        }
    }
    return null;
}

/// File tree band geometry from the last draw (absolute screen coords),
/// used for mouse hit-testing. Null when the panel isn't shown.
const FiletreeBand = struct { x: u16, y: u16, w: u16, h: u16 };
var filetree_band: ?FiletreeBand = null;

/// Docked search panel rows (full width above the status bar); null when
/// hidden. Used for mouse hit-testing like filetree_band.
const SearchBand = struct { y: u16, h: u16 };
var search_band: ?SearchBand = null;
var encoding_band: ?FiletreeBand = null;
var encoding_picker_band: ?FiletreeBand = null;
var recent_projects_band: ?FiletreeBand = null;

/// Double-click state for tree rows: single click on a row NAME only
/// selects; a second click on the same row within the threshold toggles
/// a folder or opens a file. (The +/- glyph stays single-click.)
const filetree_double_click_ms: i128 = 400;
var filetree_last_click_ns: i128 = 0;
var filetree_last_click_row: usize = std.math.maxInt(usize);
/// Last external-change mtime probe (run-loop poll; the TUI loop is
/// event-driven, so the check fires when input arrives).
var filetree_poll_ns: i128 = 0;
/// Last open-document external-change probe (same event-driven cadence).
var doc_poll_ns: i128 = 0;

/// Draw the full editor screen.
fn drawEditor(win: Window, editor: *Editor, width: u16, height: u16) void {
    pane_rect_count = 0;
    filetree_band = null;
    search_band = null;
    encoding_band = null;
    encoding_picker_band = null;
    recent_projects_band = null;
    if (!editor.activePaneIsTerminal()) {
        const w: u16 = @intCast(@min(editor.activeDoc().format.label().len + 2, width));
        encoding_band = .{ .x = width -| w, .y = height -| 1, .w = w, .h = 1 };
    }

    const tab_bar_height: u16 = if (editor.docCount() > 1) 1 else 0;
    const status_height: u16 = 1;
    const search_h: u16 = if (editor.search_visible)
        @min(14, (height -| tab_bar_height -| status_height) / 2)
    else
        0;
    const content_height = height -| tab_bar_height -| status_height -| search_h;

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
            // Not drawn: a hidden tree must not keep the keyboard
            if (editor.filetree_focused) _ = editor.takeKeyboardFocus(.pane);
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

    // Docked search panel (full width, above the status bar)
    if (search_h > 0) {
        const sw = win.child(.{
            .y_off = @intCast(tab_bar_height + content_height),
            .height = search_h,
            .width = width,
        });
        drawSearchPanel(sw, editor, width, search_h);
        search_band = .{ .y = tab_bar_height + content_height, .h = search_h };
    }

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
        const is_multi = row != ft.selected and ft.isMultiSelected(idx);
        var style = if (row == ft.selected) sel_style else bg_style;
        if (is_multi) style.bg = toVaxis(theme.overlay_selection_bg);
        if (status_fg) |fg| style.fg = fg;
        if (row == ft.selected or is_multi) {
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
        if (editor.tui_filetree_icons) {
            // Nerdfont mode: chevron column + accent-colored type glyph.
            const chev: []const u8 = switch (node.kind) {
                .dir => if (node.expanded) "\u{25be} " else "\u{25b8} ", // ▾ ▸
                .file => "  ",
            };
            x = writeStr(win, x, screen_row, chev, style);
            const fi = editor.filetreeIconFor(node.name, node.kind == .dir);
            var icon_style = style;
            if (row != ft.selected) {
                if (fi.color) |c| icon_style.fg = .{ .rgb = .{ c.r, c.g, c.b } };
            }
            x = writeStr(win, x, screen_row, fi.nerd orelse fileicons.nerdGlyph(fi.kind), icon_style);
            x = writeStr(win, x, screen_row, " ", style);
        } else {
            const glyph: []const u8 = switch (node.kind) {
                .dir => if (node.expanded) "- " else "+ ",
                .file => "  ",
            };
            x = writeStr(win, x, screen_row, glyph, style);
        }
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

fn mouseOverSearch(mouse: vaxis.Mouse) bool {
    const band = search_band orelse return false;
    const mr: i32 = @intCast(mouse.row);
    return mr >= band.y and mr < @as(i32, band.y) + band.h;
}

/// Left click inside the file tree band: focus the tree and select the
/// row. A single click on the +/- glyph toggles a folder; row names need
/// a double click (toggle dir / open file) so a stray click never opens
/// or collapses anything.
fn handleFiletreeClick(editor: *Editor, band: FiletreeBand, col_abs: u16, row_abs: u16) void {
    if (!editor.takeKeyboardFocus(.filetree)) return;
    const ft = editor.ensureFiletree() orelse return;
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
    _ = editor.navOpen(abs) catch |err| {
        editor.status_message = if (err == error.BinaryFile)
            "Cannot open: binary file"
        else
            "Open failed";
    };
}

/// Recursively render the layout tree into the given window.
/// screen_x / screen_y give the window's absolute top-left on the terminal,
/// used to record pane rects for mouse hit-testing.
/// The TUI renders the primary window only — there are no OS windows in a
/// terminal, `multi_window_supported` stays false, so window 0 is always the
/// focused one and the window commands fall back to splits.
fn tuiLayout(editor: *Editor) *Layout {
    return &editor.windows.items[0].layout;
}

fn renderPaneLayout(
    win: Window,
    editor: *Editor,
    node_idx: u8,
    screen_x: u16,
    screen_y: u16,
    width: u16,
    height: u16,
) void {
    if (node_idx >= tuiLayout(editor).nodes.items.len) return;
    if (width == 0 or height == 0) return;

    switch (tuiLayout(editor).nodes.items[node_idx]) {
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
    const pane = tuiLayout(editor).panes.items[pane_id];
    switch (pane.content) {
        .editor => |doc_idx| {
            if (doc_idx >= editor.documents.items.len) return;
            const doc = &editor.documents.items[doc_idx];
            const is_active = editor.isActivePane(0, pane_id);

            // Only the active pane's doc drives editor.text_width and cursor-visible logic
            if (is_active) {
                const total_lines = doc.lineCount();
                const gutter_w = lineNumberWidth(total_lines, editor.gutter_min_digits);
                const tw: u16 = if (width > gutter_w + 1) width - gutter_w - 1 else 1;
                editor.text_width = tw;

                if (!scroll_pinned) {
                    const tab = tabStop(editor, doc);
                    if (editor.wordWrapFor(doc)) {
                        doc.scroll_left = 0;
                        ensureCursorVisibleWrapped(doc, height, width, editor.gutter_min_digits, tab);
                    } else {
                        ensureCursorVisibleNoWrap(doc, height, tw, tab);
                    }
                }
            }

            const wrap = editor.wordWrapFor(doc);
            drawContent(win, doc, editor, width, height, wrap);
            if (is_active and doc.cursors.count() > 1) {
                drawSecondaryCursors(win, doc, editor, width, height);
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
        if (doc.preview) continue; // hidden from the tab bar
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
        if (doc.preview) continue; // hidden from the tab bar
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
// Cell math (display-width aware, UTF-8 safe)
//
// One rule maps text to screen cells for everything — drawing, the caret,
// clicks, selections and wrapping: `cellWidth`. A tab reaches the next tab
// stop; zero-width code points (combining marks, ZWJ, variation selectors,
// control characters) take no cell; wide characters take two — the
// per-code-point widths vaxis lays text out with (its `.wcwidth` method,
// the one ZIDE's screen uses; drawn text never contains a tab, see
// `writeText`). Tab stops count from the start of the visual row: the line
// start without wrapping, each wrapped row's start with it.
// ===========================================================================

/// One code point at a byte offset: its value and byte length. A stray
/// continuation byte reads as zero-width code point 0 (so a position inside
/// a character snaps forward to the next one); other invalid bytes are
/// U+FFFD, one byte each.
const Char = struct { cp: u21, len: usize };

fn charAt(text: []const u8, i: usize) Char {
    const b = text[i];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    if (b & 0xC0 == 0x80) return .{ .cp = 0, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + n > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[i..][0..n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Cells code point `cp` takes when it starts at cell column `col` (tab
/// stops every `tab` columns, tab >= 1).
fn cellWidth(cp: u21, col: usize, tab: usize) usize {
    if (cp == '\t') return tab - col % tab;
    if (cp < 0x80) return @intFromBool(cp >= 0x20 and cp != 0x7f);
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return 1;
    return vaxis.gwidth.gwidth(buf[0..n], .wcwidth);
}

/// Tab stop width for `doc` (never 0).
fn tabStop(editor: *const Editor, doc: *const Document) usize {
    return @max(1, editor.tabWidthFor(doc));
}

/// Cell column after `text` drawn from column `col`.
fn advanceCols(text: []const u8, col: usize, tab: usize) usize {
    var c = col;
    var i: usize = 0;
    while (i < text.len) {
        const ch = charAt(text, i);
        c += cellWidth(ch.cp, c, tab);
        i += ch.len;
    }
    return c;
}

/// Cell column of byte `byte` of `line` (tab stops from the line start). A
/// byte inside a character counts that whole character: it snaps forward.
fn colOfByte(line: []const u8, byte: usize, tab: usize) usize {
    const end = @min(byte, line.len);
    var c: usize = 0;
    var i: usize = 0;
    while (i < end) {
        const ch = charAt(line, i);
        c += cellWidth(ch.cp, c, tab);
        i += ch.len;
    }
    return c;
}

/// Byte offset in `text` (which starts at cell column `col0`) for cell
/// column `target`: the first character starting at or after it — or, with
/// `nearest`, the nearer edge of a tab or wide character that covers it.
/// Zero-width code points at the target are stepped over, so a position
/// never lands between a character and its combining marks.
fn byteAtCol(text: []const u8, col0: usize, target: usize, tab: usize, nearest: bool) usize {
    var c = col0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = charAt(text, i);
        const w = cellWidth(ch.cp, c, tab);
        if (w > 0) {
            if (c >= target) return i;
            if (nearest and target < c + w and target - c < (w + 1) / 2) return i;
        }
        c += w;
        i += ch.len;
    }
    return text.len;
}

/// End of the characters of `text` (starting at column `col0`) that fit
/// before column `limit`; zero-width marks at the edge included, a wide
/// character straddling it left out.
fn fitEnd(text: []const u8, col0: usize, limit: usize, tab: usize) usize {
    var c = col0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = charAt(text, i);
        const w = cellWidth(ch.cp, c, tab);
        if (c + w > limit) break;
        c += w;
        i += ch.len;
    }
    return i;
}

/// End byte of the visual row starting at `start_pos` of a wrapped line:
/// the characters that fit in `text_width` cells, broken after the last
/// space when a word would be cut. Always advances — a character wider
/// than the whole row gets a row of its own.
fn wrapAdvanceRow(line: []const u8, text_width: usize, start_pos: usize, tab: usize) usize {
    if (text_width == 0) return line.len;
    var pos = start_pos;
    var col: usize = 0;
    var last_space: ?usize = null;

    while (pos < line.len) {
        const ch = charAt(line, pos);
        const w = cellWidth(ch.cp, col, tab);
        if (col > 0 and col + w > text_width) break; // this char would exceed width
        if (ch.cp == ' ') last_space = pos + 1; // break after space
        col += w;
        pos += ch.len;
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
fn wrapLineRows(line: []const u8, text_width: u16, tab: usize) u16 {
    if (text_width == 0 or line.len == 0) return 1;
    var rows: u16 = 0;
    var pos: usize = 0;
    while (pos < line.len) {
        pos = wrapAdvanceRow(line, text_width, pos, tab);
        rows +|= 1;
    }
    return if (rows == 0) 1 else rows;
}

/// Given a byte column within a line, find which visual wrap row it falls on
/// and what cell column within that row.
fn wrapColToVisual(line: []const u8, text_width: u16, byte_col: usize, tab: usize) struct { row: u16, col: u16 } {
    if (text_width == 0) return .{ .row = 0, .col = @intCast(@min(colOfByte(line, byte_col, tab), 65535)) };
    var visual_row: u16 = 0;
    var pos: usize = 0;

    while (pos < line.len) {
        const row_start = pos;
        pos = wrapAdvanceRow(line, text_width, pos, tab);
        const row_end = pos;

        if (byte_col < row_end or pos >= line.len) {
            const clamped = @min(byte_col, row_end);
            const effective_start = @min(row_start, clamped);
            const dcol = advanceCols(line[effective_start..clamped], 0, tab);
            return .{ .row = visual_row, .col = @intCast(@min(dcol, 65535)) };
        }
        visual_row +|= 1;
    }
    // Cursor at end of empty line
    return .{ .row = visual_row, .col = 0 };
}

/// Byte column for cell column `preferred_col` on visual row `target_row`
/// of a wrapped line (the nearer edge of a tab or wide character there). On
/// a row that continues, the result stays on that row.
fn wrapVisualToCol(line: []const u8, text_width: u16, target_row: u16, preferred_col: usize, tab: usize) usize {
    if (text_width == 0) return 0;
    var row: u16 = 0;
    var pos: usize = 0;

    while (pos < line.len) {
        const row_start = pos;
        pos = wrapAdvanceRow(line, text_width, pos, tab);

        if (row == target_row) {
            const b = row_start + byteAtCol(line[row_start..pos], 0, preferred_col, tab, true);
            // For non-final rows, clamp to the last character start within
            // the row so wrapColToVisual maps it to this row, not the next.
            if (b >= pos and pos < line.len and pos > row_start) {
                var last = pos - 1;
                while (last > row_start and (line[last] & 0xC0) == 0x80) last -= 1;
                return last;
            }
            return b;
        }
        row +|= 1;
    }
    return line.len;
}

/// Sticky visual column for Up/Down with word wrap (Design 7): the cell
/// column a run of vertical moves aims for, so moving down through a short
/// line comes back out at the column it started from. A cursor keeps its
/// target while it sits where the last vertical move put it; any other
/// motion or edit that moves it starts a new run. Entries are keyed by that
/// placed offset, so each cursor of a multi-cursor set keeps its own.
const VerticalMotion = struct {
    const capacity = 64;
    doc_id: u64 = 0,
    count: usize = 0,
    placed: [capacity]usize = undefined,
    target: [capacity]usize = undefined,

    fn lookup(self: *const VerticalMotion, doc_id: u64, offset: usize) ?usize {
        if (self.doc_id != doc_id) return null;
        for (self.placed[0..self.count], self.target[0..self.count]) |placed, target| {
            if (placed == offset) return target;
        }
        return null;
    }

    fn record(self: *VerticalMotion, offset: usize, target: usize) void {
        if (self.count == capacity) return;
        self.placed[self.count] = offset;
        self.target[self.count] = target;
        self.count += 1;
    }
};
var vertical_motion: VerticalMotion = .{};

/// Move cursor up or down by one visual (wrapped) row.
/// When word wrap is on, this moves through screen rows rather than logical lines.
fn moveVisualVertical(editor: *Editor, direction: enum { up, down }, extend_selection: bool) void {
    const doc = editor.activeDoc();
    const buf = &doc.buffer;
    const total_lines = doc.lineCount();
    const text_width: u16 = editor.text_width;
    const tab = tabStop(editor, doc);

    if (text_width == 0) return;

    var next: VerticalMotion = .{ .doc_id = doc.id };
    for (doc.cursors.cursors.items) |*c| {
        const pos = buf.offsetToPos(c.offset);
        const cur_line = doc.lineContent(pos.line);
        const wrap_pos = wrapColToVisual(cur_line, text_width, pos.col, tab);
        // The target is a CELL column on the visual row (preferred_col is a
        // byte column of the whole logical line, which snapped to row ends);
        // a run of vertical moves keeps the column it started with.
        const target_col: usize = vertical_motion.lookup(doc.id, c.offset) orelse wrap_pos.col;

        if (!extend_selection) {
            c.clearSelection();
        } else if (!c.hasSelection()) {
            c.startSelection();
        }

        switch (direction) {
            .up => {
                if (wrap_pos.row > 0) {
                    const byte_col = wrapVisualToCol(cur_line, text_width, wrap_pos.row - 1, target_col, tab);
                    c.offset = cursor_mod.lineOffset(buf, pos.line, byte_col);
                } else if (pos.line > 0) {
                    const prev_line = doc.lineContent(pos.line - 1);
                    const prev_rows = wrapLineRows(prev_line, text_width, tab);
                    const byte_col = wrapVisualToCol(prev_line, text_width, prev_rows - 1, target_col, tab);
                    c.offset = cursor_mod.lineOffset(buf, pos.line - 1, byte_col);
                }
            },
            .down => {
                const cur_rows = wrapLineRows(cur_line, text_width, tab);
                if (wrap_pos.row + 1 < cur_rows) {
                    const byte_col = wrapVisualToCol(cur_line, text_width, wrap_pos.row + 1, target_col, tab);
                    c.offset = cursor_mod.lineOffset(buf, pos.line, byte_col);
                } else if (pos.line + 1 < total_lines) {
                    const next_line = doc.lineContent(pos.line + 1);
                    const byte_col = wrapVisualToCol(next_line, text_width, 0, target_col, tab);
                    c.offset = cursor_mod.lineOffset(buf, pos.line + 1, byte_col);
                }
            },
        }
        next.record(c.offset, target_col);
    }
    doc.cursors.mergeCursors();
    vertical_motion = next;
}

/// Dispatch a keybind action with TUI-specific overrides (visual-row multi-cursor).
fn execTuiAction(editor: *Editor, action: []const u8) void {
    if (editor.wordWrapFor(editor.activeDoc())) {
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

/// Add a cursor at `offset` with its own preferred column: a bare
/// addCursor leaves it 0, so the next Up/Down (or the next add-cursor,
/// which starts from the outermost cursor) snapped to column 0.
fn addCursorAt(doc: *Document, offset: usize) void {
    doc.cursors.addCursor(offset) catch return;
    const col = doc.buffer.offsetToPos(offset).col;
    for (doc.cursors.cursors.items) |*c| {
        if (c.offset == offset) c.preferred_col = col;
    }
}

/// Add a new cursor one visual (wrapped) row above or below the outermost cursor.
fn tuiAddCursorVisual(editor: *Editor, direction: enum { up, down }) void {
    const doc = editor.activeDoc();
    const buf = &doc.buffer;
    const total_lines = doc.lineCount();
    const text_width: u16 = editor.text_width;
    const tab = tabStop(editor, doc);

    if (text_width == 0) return;

    // Find the outermost cursor in the given direction
    var edge_idx: usize = 0;
    var edge_line: usize = if (direction == .up) std.math.maxInt(usize) else 0;
    var edge_wrap_row: u16 = 0;
    for (doc.cursors.cursors.items, 0..) |c, i| {
        const pos = buf.offsetToPos(c.offset);
        const wrap_pos = wrapColToVisual(doc.lineContent(pos.line), text_width, pos.col, tab);
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
    // Use the edge cursor's cell column within its visual row (see
    // moveVisualVertical — preferred_col is the wrong unit here).
    const ref_pos = buf.offsetToPos(ref_cursor.offset);
    const ref_dcol: usize = wrapColToVisual(cur_line, text_width, ref_pos.col, tab).col;

    switch (direction) {
        .up => {
            if (edge_wrap_row > 0) {
                const target_col = wrapVisualToCol(cur_line, text_width, edge_wrap_row - 1, ref_dcol, tab);
                addCursorAt(doc, buf.posToOffset(edge_line, target_col));
            } else if (edge_line > 0) {
                const prev_line = doc.lineContent(edge_line - 1);
                const prev_rows = wrapLineRows(prev_line, text_width, tab);
                const target_col = wrapVisualToCol(prev_line, text_width, prev_rows - 1, ref_dcol, tab);
                addCursorAt(doc, buf.posToOffset(edge_line - 1, target_col));
            }
        },
        .down => {
            const cur_rows = wrapLineRows(cur_line, text_width, tab);
            if (edge_wrap_row + 1 < cur_rows) {
                const target_col = wrapVisualToCol(cur_line, text_width, edge_wrap_row + 1, ref_dcol, tab);
                addCursorAt(doc, buf.posToOffset(edge_line, target_col));
            } else if (edge_line + 1 < total_lines) {
                const next_line = doc.lineContent(edge_line + 1);
                const target_col = wrapVisualToCol(next_line, text_width, 0, ref_dcol, tab);
                addCursorAt(doc, buf.posToOffset(edge_line + 1, target_col));
            }
        },
    }
}

/// Ensure the cursor is visible when word wrapping is active.
/// Accounts for variable visual row heights per logical line.
fn ensureCursorVisibleWrapped(doc: *Document, editor_height: u16, width: u16, min_digits: usize, tab: usize) void {
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
        visual_rows +|= wrapLineRows(doc.lineContent(line_idx), text_width, tab);
        if (visual_rows >= editor_height) break;
    }
    // Add cursor's row within its wrapped line
    const cur_line = doc.lineContent(cursor_pos.line);
    const wrap_pos = wrapColToVisual(cur_line, text_width, cursor_pos.col, tab);
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
        rows_needed +|= wrapLineRows(doc.lineContent(new_top), text_width, tab);
    }
    // If we overshot, new_top is the right starting line
    doc.scroll_top = new_top;
}

/// No-wrap scrolling: the core's vertical rule, and a horizontal one in
/// CELLS against the pane's real text width, so the caret's column (tabs
/// and wide characters counted) stays inside the text area. It used to
/// assume a 4-column gutter and compare bytes with cells. `scroll_left`
/// stays a byte offset on a character boundary.
fn ensureCursorVisibleNoWrap(doc: *Document, height: u16, text_width: u16, tab: usize) void {
    // Vertical, and back to a caret left of the view (visible_cols 0 skips
    // the core's byte-based right edge)
    doc.ensureCursorVisible(height, 0);
    if (text_width == 0) return;
    const pos = doc.cursorPos();
    const line = doc.lineContent(pos.line);
    const caret = colOfByte(line, pos.col, tab);
    const left = colOfByte(line, doc.scroll_left, tab);
    if (caret >= left + text_width) {
        // The first character whose column puts the caret on the last cell
        doc.scroll_left = byteAtCol(line, 0, caret + 1 - text_width, tab, false);
    }
}

/// The bytes one screen row of a line shows — [start, end) — and the
/// tab-grid column of its first cell. A wrapped row restarts the grid at its
/// first byte; an unwrapped line is scrolled sideways by `h_scroll` (a byte
/// offset, snapped forward to a character).
const RowSegment = struct { start: usize, end: usize, col0: usize };

fn rowSegment(line: []const u8, do_wrap: bool, row_start: usize, row_end: usize, h_scroll: usize, text_width: u16, tab: usize) RowSegment {
    if (do_wrap) return .{ .start = row_start, .end = row_end, .col0 = 0 };
    const left = colOfByte(line, h_scroll, tab);
    const start = byteAtCol(line, 0, left, tab, false);
    return .{ .start = start, .end = start + fitEnd(line[start..], left, left + text_width, tab), .col0 = left };
}

/// Spaces for tab expansion.
const tab_spaces = " " ** 64;

/// `text` with every tab replaced by the spaces up to its tab stop (`text`
/// starts at cell column `col`), copied into the frame arena. A full arena
/// cuts the copy short; the cells after it stay blank.
fn frameArenaExpandTabs(text: []const u8, col: usize, tab: usize) []const u8 {
    const start = grapheme_arena_len;
    var c = col;
    var i: usize = 0;
    while (i < text.len) {
        const ch = charAt(text, i);
        const w = cellWidth(ch.cp, c, tab);
        const bytes: []const u8 = if (ch.cp == '\t') tab_spaces[0..@min(w, tab_spaces.len)] else text[i..][0..ch.len];
        if (grapheme_arena_len + bytes.len > grapheme_arena.len) break;
        @memcpy(grapheme_arena[grapheme_arena_len..][0..bytes.len], bytes);
        grapheme_arena_len += bytes.len;
        c += w;
        i += ch.len;
    }
    return grapheme_arena[start..grapheme_arena_len];
}

/// Draw document text on row 0 of `win` from window column `col`, tabs
/// expanded to their tab stops; `grid` is the tab-grid column of window
/// column 0. vaxis measures a tab as zero cells and skips it, so tab
/// indentation used to vanish while the caret math counted it. Returns the
/// column after the text by `cellWidth`'s count — where the caret and
/// clicks put it.
fn writeText(win: Window, col: u16, text: []const u8, style: Style, tab: usize, grid: usize) u16 {
    if (text.len == 0) return col;
    const start = grid + col;
    const end = advanceCols(text, start, tab);
    const shown = if (std.mem.indexOfScalar(u8, text, '\t') == null) frameArenaDupe(text) else frameArenaExpandTabs(text, start, tab);
    _ = win.printSegment(.{ .text = shown, .style = style }, .{ .col_offset = col, .wrap = .none });
    return @intCast(@min(@as(usize, col) + (end - start), std.math.maxInt(u16)));
}

/// Draw the editor content area with line numbers and optional word wrap.
fn drawContent(win: Window, doc: *Document, editor: *Editor, width: u16, height: u16, wrap: bool) void {
    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines, editor.gutter_min_digits);
    const text_start_x = gutter_width + 1; // +1 for separator
    const text_width: u16 = if (width > text_start_x) width - text_start_x else 1;
    const tab = tabStop(editor, doc);
    // Wrapped views never scroll sideways
    const h_scroll: usize = if (wrap) 0 else doc.scroll_left;
    // The bracket under the caret and its partner, highlighted in the pane
    // that shows the active document.
    const bracket_pair: ?brackets.Pair = if (doc == editor.activeDoc()) brackets.matchAtCaret(&doc.buffer, doc.cursors.primaryConst().offset) else null;

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
        // syntax_highlighting=false: skip tokenizing → plain text render
        if (if (editor.syntax_highlighting) doc.language else null) |lang| {
            const state = doc.ensureLineState(line_idx);
            const result = syntax.tokenizeLine(line, lang, state, &span_buf);
            span_count = result.count;
        }

        // Iterate visual rows for this logical line
        var wrap_row: u16 = 0;
        var byte_pos: usize = 0;
        const do_wrap = wrap and advanceCols(line, 0, tab) > text_width;

        while (y < height) {
            const row_start = byte_pos;
            const row_end = if (do_wrap)
                wrapAdvanceRow(line, text_width, byte_pos, tab)
            else
                line.len;
            // The bytes this row shows and the tab-grid column of its
            // first cell: every piece below is measured from it.
            const seg = rowSegment(line, do_wrap, row_start, row_end, h_scroll, text_width, tab);

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
                var diag_it = doc.diagIter();
                const has_diag = while (diag_it.next()) |d| {
                    if (d.start_line <= line_idx and d.end_line >= line_idx) break d;
                } else null;
                const debug_mark = editor.dap.marker(doc.id, line_idx);
                if (debug_mark != .none) {
                    _ = writeStr(win, gutter_width, y, switch (debug_mark) {
                        .execution => ">",
                        .breakpoint => "●",
                        .unverified => "○",
                        .none => " ",
                    }, gutter_sep_style);
                } else if (has_diag) |diag| {
                    const diag_fg: Color = switch (diag.severity) {
                        .err => .{ .rgb = .{ 0xE0, 0x40, 0x40 } },
                        .warning => .{ .rgb = .{ 0xE0, 0xC0, 0x40 } },
                        .information => .{ .rgb = .{ 0x40, 0xA0, 0xE0 } },
                        .hint => .{ .rgb = .{ 0x80, 0x80, 0xA0 } },
                    };
                    _ = writeStr(win, gutter_width, y, "!", .{ .fg = diag_fg, .bg = bg });
                } else {
                    const mark = editor.git.marker(doc, line_idx);
                    _ = writeStr(win, gutter_width, y, switch (mark) {
                        .none => " ",
                        .added => "+",
                        .modified => "~",
                        .deleted => "-",
                    }, gutter_sep_style);
                }
            } else {
                _ = writeStr(win, gutter_width, y, " ", gutter_sep_style);
            }

            // Text content for this row
            if (text_start_x < width) {
                const segment_start = seg.start;
                const segment_end = seg.end;
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
                                col = writeText(text_win, col, gap, gap_style, tab, seg.col0);
                            }

                            // Span → syntax color (selection overrides)
                            if (vis_end > vis_start) {
                                const span_text = segment[vis_start..vis_end];
                                // If fully inside selection, use sel_style; otherwise syntax color
                                if (has_sel and vis_start >= sel_begin and vis_end <= sel_end_local) {
                                    col = writeText(text_win, col, span_text, sel_style, tab, seg.col0);
                                } else if (has_sel and vis_start < sel_end_local and vis_end > sel_begin) {
                                    // Partial overlap — split into pre-sel, sel, post-sel
                                    const pre_end = @max(vis_start, sel_begin);
                                    const post_start = @min(vis_end, sel_end_local);
                                    const syn_style = synTokenStyle(syn_theme, span_buf[si].token, text_style.fg, bg);
                                    if (pre_end > vis_start) col = writeText(text_win, col, span_text[0 .. pre_end - vis_start], syn_style, tab, seg.col0);
                                    if (post_start > pre_end) col = writeText(text_win, col, span_text[pre_end - vis_start .. post_start - vis_start], sel_style, tab, seg.col0);
                                    if (vis_end > post_start) col = writeText(text_win, col, span_text[post_start - vis_start ..], syn_style, tab, seg.col0);
                                } else {
                                    const syn_style = synTokenStyle(syn_theme, span_buf[si].token, text_style.fg, bg);
                                    col = writeText(text_win, col, span_text, syn_style, tab, seg.col0);
                                }
                            }
                            if (vis_end > seg_pos) seg_pos = vis_end;
                        }

                        // Trailing text after last span
                        if (seg_pos < segment.len) {
                            const trail = segment[seg_pos..];
                            const trail_style = if (has_sel and seg_pos < sel_end_local) sel_style else text_style;
                            _ = writeText(text_win, col, trail, trail_style, tab, seg.col0);
                        }
                    } else if (has_sel) {
                        // No syntax highlighting, but has selection
                        var col = writeText(text_win, 0, segment[0..sel_begin], text_style, tab, seg.col0);
                        col = writeText(text_win, col, segment[sel_begin..sel_end_local], sel_style, tab, seg.col0);
                        _ = writeText(text_win, col, segment[sel_end_local..], text_style, tab, seg.col0);
                    } else {
                        _ = writeText(text_win, 0, segment, text_style, tab, seg.col0);
                    }
                }
            }

            // Secondary cursors' selections (block selection) — the segment
            // renderer above only knows the primary's range, so restyle the
            // covered cells post-hoc, same as the diagnostic underlines below.
            if (doc.cursors.count() > 1 and text_start_x < width) {
                const line_start_offset = doc.buffer.posToOffset(line_idx, 0);
                const seg_text = line[seg.start..seg.end];
                const abs_seg_start = line_start_offset + seg.start;
                const abs_seg_end = line_start_offset + seg.end;
                for (doc.cursors.cursors.items[1..]) |sc| {
                    const r = sc.selectionRange() orelse continue;
                    if (!(r.start < abs_seg_end and r.end > abs_seg_start)) continue;
                    const lo = if (r.start > abs_seg_start) r.start - abs_seg_start else 0;
                    const hi = if (r.end < abs_seg_end) r.end - abs_seg_start else seg_text.len;
                    const cx_start = advanceCols(seg_text[0..@min(lo, seg_text.len)], seg.col0, tab) - seg.col0;
                    const cx_end = advanceCols(seg_text[0..@min(hi, seg_text.len)], seg.col0, tab) - seg.col0;
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

            // Matching-bracket highlight: the bracket under the caret and its
            // partner, restyled post-hoc like the secondary selections.
            if (bracket_pair) |pair| {
                if (text_start_x < width) {
                    const line_start_offset = doc.buffer.posToOffset(line_idx, 0);
                    const seg_text = line[seg.start..seg.end];
                    const abs_seg_start = line_start_offset + seg.start;
                    const abs_seg_end = line_start_offset + seg.end;
                    for ([_]usize{ pair.open, pair.close }) |off| {
                        if (off < abs_seg_start or off >= abs_seg_end) continue;
                        const cx = advanceCols(seg_text[0 .. off - abs_seg_start], seg.col0, tab) - seg.col0;
                        if (cx >= text_width) continue;
                        const x: u16 = text_start_x + @as(u16, @intCast(cx));
                        if (win.readCell(x, y)) |cell| {
                            var new_cell = cell;
                            new_cell.style.reverse = true;
                            new_cell.style.bold = true;
                            win.writeCell(x, y, new_cell);
                        }
                    }
                }
            }

            // Diagnostic underlines on their start line: byte columns
            // converted to this row's cells (they used to be used as cell
            // positions directly, drifting on tabs and non-ASCII text)
            if (text_start_x < width) {
                var ul_diag_it = doc.diagIter();
                while (ul_diag_it.next()) |diag| {
                    if (diag.start_line != line_idx) continue;
                    const lo: usize = @min(diag.start_col, line.len);
                    const hi: usize = if (diag.end_line == line_idx) @min(diag.end_col, line.len) else line.len;
                    const a = @max(lo, seg.start);
                    const b = @min(hi, seg.end);
                    if (a >= b) continue;
                    const diag_fg: Color = switch (diag.severity) {
                        .err => .{ .rgb = .{ 0xE0, 0x40, 0x40 } },
                        .warning => .{ .rgb = .{ 0xE0, 0xC0, 0x40 } },
                        .information => .{ .rgb = .{ 0x40, 0xA0, 0xE0 } },
                        .hint => .{ .rgb = .{ 0x80, 0x80, 0xA0 } },
                    };
                    const ul_start = advanceCols(line[seg.start..a], seg.col0, tab) - seg.col0;
                    const ul_end = advanceCols(line[seg.start..b], seg.col0, tab) - seg.col0;
                    var cx: u16 = @intCast(@min(ul_start, text_width));
                    const cx_lim: u16 = @intCast(@min(ul_end, text_width));
                    while (cx < cx_lim) : (cx += 1) {
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
fn drawSecondaryCursors(win: Window, doc: *Document, editor: *Editor, width: u16, height: u16) void {
    const cursor_style: Style = .{ .bg = toVaxis(editor.tui_theme.cursor_bg), .fg = toVaxis(editor.tui_theme.cursor_fg) };

    // Skip primary cursor (index 0), render the rest
    for (doc.cursors.cursors.items[1..]) |c| {
        const cell = caretCell(editor, doc, c.offset, width, height) orelse continue;
        // Fetched after caretCell's own lineContent calls: a line spanning
        // the buffer gap is served from the shared scratch slice.
        const pos = doc.buffer.offsetToPos(c.offset);
        const line = doc.lineContent(pos.line);
        // Draw a reverse-video block at the cursor position
        if (pos.col < line.len and line[pos.col] >= 32) {
            // Show the actual character in reverse video
            const cp_len = std.unicode.utf8ByteSequenceLength(line[pos.col]) catch 1;
            _ = writeStr(win, cell.x, cell.y, line[pos.col..@min(line.len, pos.col + cp_len)], cursor_style);
        } else {
            // At end of line, on a tab or a control char — a space in reverse
            _ = writeStr(win, cell.x, cell.y, " ", cursor_style);
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
    if (doc.dirty) x = writeStr(win, x, 0, " [+]", style);
    // Review progress and this file's verdict, while changed files are listed.
    var review_buf: [48]u8 = undefined;
    const review_segment = editor.review.statusSegment(editor, &review_buf);
    if (review_segment.len > 0) {
        x = writeStr(win, x, 0, "  ", style);
        _ = writeStr(win, x, 0, review_segment, style);
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
    } else {
        var diag_it = doc.diagIter();
        while (diag_it.next()) |diag| {
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
    }

    // Right side: cursor position — use writeStr (stack buffer)
    var right_buf: [160]u8 = undefined;
    const cursor_count = doc.cursors.count();
    // Show the detected language (and its server once up) so it's obvious
    // what syntax/LSP applies.
    var lang_buf: [64]u8 = undefined;
    const lang_name = editor.languageStatusText(doc, &lang_buf);
    const right = if (cursor_count > 1)
        std.fmt.bufPrint(&right_buf, "{d} cursors | Ln {d}, Col {d} | {s} | {s} ", .{ cursor_count, pos.line + 1, pos.col + 1, lang_name, doc.format.label() }) catch ""
    else
        std.fmt.bufPrint(&right_buf, "Ln {d}, Col {d} | {s} | {s} ", .{ pos.line + 1, pos.col + 1, lang_name, doc.format.label() }) catch "";
    const right_len: u16 = @intCast(@min(right.len, width));
    const right_x = width -| right_len;
    _ = writeStr(win, right_x, 0, right, style);
    const enc = doc.format.label();
    const enc_w: u16 = @intCast(@min(enc.len + 1, width));
    _ = writeStr(win, width -| enc_w, 0, enc, style);
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

/// Rect of the focused pane from the last draw.
fn activePaneRect(editor: *Editor) ?PaneRect {
    return paneRectFor(editor.activePaneId());
}

/// Rect of pane `pane_id` from the last draw.
fn paneRectFor(pane_id: u8) ?PaneRect {
    for (pane_rects[0..pane_rect_count]) |pr| {
        if (pr.pane_id == pane_id) return pr;
    }
    return null;
}

/// Pane-local cell of the caret at `offset` of `doc` shown in a pane
/// `pane_w` x `pane_h` cells (gutter included); null when it is off
/// screen — above or below the view (a wheel-pinned view used to draw it
/// on row 0) or beside it.
fn caretCell(editor: *Editor, doc: *Document, offset: usize, pane_w: u16, pane_h: u16) ?struct { x: u16, y: u16 } {
    const pos = doc.buffer.offsetToPos(offset);
    if (pos.line < doc.scroll_top) return null;
    const tab = tabStop(editor, doc);
    const total_lines = doc.lineCount();
    const text_start_x = lineNumberWidth(total_lines, editor.gutter_min_digits) + 1;
    if (pane_w <= text_start_x) return null;
    const text_width: u16 = pane_w - text_start_x;

    var row: usize = 0;
    var col: usize = 0;
    if (editor.wordWrapFor(doc)) {
        // Rows of the lines above, stopping at the pane's height (a caret
        // 65 536 rows below the view overflowed this sum)
        var line_idx: usize = doc.scroll_top;
        while (line_idx < pos.line and line_idx < total_lines) : (line_idx += 1) {
            row += wrapLineRows(doc.lineContent(line_idx), text_width, tab);
            if (row >= pane_h) return null;
        }
        const vis = wrapColToVisual(doc.lineContent(pos.line), text_width, pos.col, tab);
        row += vis.row;
        col = vis.col;
    } else {
        row = pos.line - doc.scroll_top;
        if (row >= pane_h) return null;
        const line = doc.lineContent(pos.line);
        const caret = colOfByte(line, pos.col, tab);
        const left = colOfByte(line, doc.scroll_left, tab);
        if (caret < left) return null;
        col = caret - left;
    }
    if (row >= pane_h or col >= text_width) return null;
    return .{ .x = text_start_x + @as(u16, @intCast(col)), .y = @intCast(row) };
}

/// Position the real terminal cursor at the editor cursor location.
fn positionCursor(win: Window, editor: *Editor, width: u16, height: u16) void {
    _ = width;
    _ = height;
    const rect = activePaneRect(editor) orelse {
        win.hideCursor();
        return;
    };

    // Terminal pane: mirror the embedded terminal's own cursor.
    if (editor.activePaneIsTerminal()) {
        const t = activeTerminal(editor) orelse {
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
    if (caretCell(editor, doc, doc.cursors.primaryConst().offset, rect.w, rect.h)) |cell| {
        win.showCursor(rect.x +| cell.x, rect.y +| cell.y);
        win.setCursorShape(.beam_blink);
    } else {
        win.hideCursor();
    }
}

/// Buffer offset under pane-local cell (local_x, local_y) of editor pane
/// `pane_id`, drawn `pane_w` cells wide. Null for a terminal pane, and for
/// the gutter unless `clamp_gutter` (a drag) treats it as text column 0.
fn paneOffsetAt(editor: *Editor, pane_id: u8, pane_w: u16, local_x: u16, local_y: u16, clamp_gutter: bool) ?usize {
    const layout = tuiLayout(editor);
    if (pane_id >= layout.panes.items.len) return null;
    const doc_idx = switch (layout.panes.items[pane_id].content) {
        .editor => |idx| idx,
        .terminal => return null,
    };
    if (doc_idx >= editor.documents.items.len) return null;
    const doc = &editor.documents.items[doc_idx];
    const tab = tabStop(editor, doc);

    const total_lines = doc.lineCount();
    const gutter_width = lineNumberWidth(total_lines, editor.gutter_min_digits);
    const text_start_x: u16 = gutter_width + 1;

    // Must be in the text area of the pane
    if (local_x < text_start_x and !clamp_gutter) return null;
    const text_col: usize = local_x -| text_start_x;
    const content_row: usize = local_y;

    if (editor.wordWrapFor(doc)) {
        // This pane's own text width: editor.text_width belongs to the
        // focused pane, and a click in another split was measured with it.
        const text_width: u16 = if (pane_w > text_start_x) pane_w - text_start_x else 1;
        // Walk through visible lines, counting visual rows
        var visual_row: usize = 0;
        var line_idx: usize = doc.scroll_top;
        while (line_idx < total_lines) : (line_idx += 1) {
            const line = doc.lineContent(line_idx);
            const rows = wrapLineRows(line, text_width, tab);
            if (content_row < visual_row + rows) {
                // Click is on this logical line, in visual row (content_row - visual_row)
                const wrap_row: u16 = @intCast(content_row - visual_row);
                const byte_col = wrapVisualToCol(line, text_width, wrap_row, text_col, tab);
                return cursor_mod.lineOffset(&doc.buffer, line_idx, byte_col);
            }
            visual_row += rows;
        }
        // Click below last line — go to end
        return doc.buffer.byteLen();
    } else {
        const target_line = doc.scroll_top + content_row;
        if (target_line >= total_lines) return doc.buffer.byteLen();
        const line = doc.lineContent(target_line);
        const left = colOfByte(line, doc.scroll_left, tab);
        const col = byteAtCol(line, 0, left + text_col, tab, true);
        return cursor_mod.lineOffset(&doc.buffer, target_line, col);
    }
}

/// The editor pane a left press landed in: drags stay in it. Null when the
/// press went elsewhere (tab bar, panels, a terminal, a gutter).
var press_pane: ?u8 = null;

/// Handle mouse events.
fn handleMouse(editor: *Editor, mouse: vaxis.Mouse) void {
    defer editor.validateSnippetState();
    if (mouse.button == .left and mouse.type == .press) {
        if (editor.mode == .encoding_picker) {
            if (encoding_picker_band) |b| {
                if (mouse.row >= b.y and mouse.row < b.y + b.h) editor.chooseEncoding(@as(usize, @intCast(mouse.row)) - b.y);
            }
            return;
        }
        if (editor.mode == .recent_projects) {
            if (recent_projects_band) |b| {
                if (mouse.row >= b.y and mouse.row < b.y + b.h) editor.chooseRecentProject(@as(usize, @intCast(mouse.row)) - b.y);
            }
            return;
        }
        if (editor.mode == .normal) if (encoding_band) |b| {
            if (mouse.row == b.y and mouse.col >= b.x) {
                editor.startEncoding(.choose);
                return;
            }
        };
    }
    if (editor.mode != .normal) return;

    switch (mouse.button) {
        .left => switch (mouse.type) {
            .press => mousePress(editor, mouse),
            .drag => mouseDrag(editor, mouse),
            .release => {
                press_pane = null;
                block_drag = false;
                block_engaged = false;
            },
            .motion => {},
        },
        .wheel_up => mouseWheel(editor, mouse, false),
        .wheel_down => mouseWheel(editor, mouse, true),
        else => {},
    }
}

fn mousePress(editor: *Editor, mouse: vaxis.Mouse) void {
    // Click: position cursor — un-pin scroll, drop old status
    scroll_pinned = false;
    editor.status_message = "";
    press_pane = null;
    block_drag = false;
    block_engaged = false;

    // Tab bar click: show the document in the focused pane, which also takes
    // the keyboard back from a focused side panel (Editor.showDocIn)
    const tab_bar_height: i16 = if (editor.docCount() > 1) 1 else 0;
    if (tab_bar_height > 0 and mouse.row == 0) {
        if (mouse.col >= 0) {
            if (tabAtX(editor, @intCast(mouse.col))) |doc_idx| editor.showDocIn(0, doc_idx);
        }
        return;
    }

    // Search panel band: clicks focus the panel / pick a row
    if (search_band) |band| {
        if (mouse.row >= band.y and mouse.row < band.y + band.h) {
            handleSearchClick(editor, band, @intCast(mouse.row));
            return;
        }
    }

    // File tree band: clicks focus/select/toggle/open in the tree
    if (filetree_band) |band| {
        if (mouseOverFiletree(mouse)) {
            handleFiletreeClick(editor, band, @intCast(mouse.col), @intCast(mouse.row));
            return;
        }
    }

    // A pane click focuses that pane, which takes the keyboard back from the
    // tree and the search panel alike (Editor.focusPane)
    const hit = resolvePaneAt(editor, mouse.col, mouse.row) orelse return;
    editor.focusPane(hit.pane_id); // also syncs active_doc_idx
    const offset = paneOffsetAt(editor, hit.pane_id, hit.rect.w, hit.local_x, hit.local_y, false) orelse return;
    press_pane = hit.pane_id;
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
            addCursorAt(doc, offset);
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

/// Cell `v` of the screen relative to `origin`, clamped into [0, size).
fn clampLocal(v: i16, origin: u16, size: u16) u16 {
    const rel: i32 = @as(i32, v) - origin;
    return @intCast(std.math.clamp(rel, 0, @as(i32, size) - 1));
}

fn mouseDrag(editor: *Editor, mouse: vaxis.Mouse) void {
    // A drag stays in the pane its press landed in, clamped to that pane's
    // text: resolved against the pane under the mouse, it wrote another
    // document's offset into this one (an offset past its end).
    const pane_id = press_pane orelse return;
    if (pane_id != editor.activePaneId()) return;
    const rect = paneRectFor(pane_id) orelse return;
    const local_x = clampLocal(mouse.col, rect.x, rect.w);
    const local_y = clampLocal(mouse.row, rect.y, rect.h);
    const offset = paneOffsetAt(editor, pane_id, rect.w, local_x, local_y, true) orelse return;
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

fn mouseWheel(editor: *Editor, mouse: vaxis.Mouse, down: bool) void {
    if (mouseOverSearch(mouse)) {
        editor.search.moveSelection(down, 3);
        return;
    }
    if (mouseOverFiletree(mouse)) {
        // Clamped at draw time
        if (down) editor.tui_filetree_scroll +|= 3 else editor.tui_filetree_scroll -|= 3;
        return;
    }
    // The document under the mouse scrolls — not the focused one — and
    // nothing does over a terminal pane (no scrollback) or outside the panes.
    const hit = resolvePaneAt(editor, mouse.col, mouse.row) orelse return;
    const doc_idx = switch (tuiLayout(editor).panes.items[hit.pane_id].content) {
        .editor => |idx| idx,
        .terminal => return,
    };
    if (doc_idx >= editor.documents.items.len) return;
    const doc = &editor.documents.items[doc_idx];
    if (down) {
        doc.scroll_top = @min(doc.scroll_top + 5, doc.lineCount() -| 1);
    } else {
        doc.scroll_top -|= 5;
    }
    // The focused pane follows its caret every frame: pin it while the
    // wheel moves its document (shown in this pane or another one).
    if (!editor.activePaneIsTerminal() and doc_idx == editor.active_doc_idx) scroll_pinned = true;
}

/// Convert a vaxis Key to a keybind lookup string in the canonical
/// vocabulary (keybind.zig): [ctrl+][alt+][shift+]<keyname>. Shift is
/// included whenever the terminal reports it — Ctrl+Shift+K is
/// "ctrl+shift+k", exactly what the GUI sends (a legacy terminal reports a
/// shifted letter as its capital without the modifier, which lowercases to
/// the plain key).
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
        Key.insert => "insert",
        Key.tab => "tab",
        Key.enter => "enter",
        Key.escape => "escape",
        // Ctrl+Space: legacy terminals send NUL, which vaxis reports as
        // Ctrl+'@' (it used to become "ctrl+@" / "ctrl+ " and never match)
        Key.space => "space",
        '@' => if (key.mods.ctrl) "space" else null,
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
        if (editor.lookupKeybind(key_str)) |action| {
            runKeybindAction(editor, action);
            return true;
        }
        // An unbound Shift chord falls back to its unshifted binding — for
        // punctuation and special keys only, never letters (Ctrl+Shift+K
        // fell back to Ctrl+K's delete_line, Ctrl+Shift+Z to undo)
        if (key.mods.shift and keybind.allowsShiftFallback(key_str)) {
            var kbuf2: [64]u8 = undefined;
            var fallback_key = key;
            fallback_key.mods.shift = false;
            const fallback_str = keyToStr(fallback_key, &kbuf2);
            if (fallback_str.len > 0) {
                if (editor.lookupKeybind(fallback_str)) |action| {
                    runKeybindAction(editor, action);
                    return true;
                }
            }
        }
    }
    return true;
}

/// Run a bound action — unless a focused side panel takes it over: the
/// tree's copy/cut/paste act on files, the search panel's clipboard and
/// word-delete chords edit its field, and neither ever edits the document
/// behind the panel.
fn runKeybindAction(editor: *Editor, action: []const u8) void {
    if (!editor.panelAction(action)) execTuiAction(editor, action);
}

/// Keys while the file tree owns the keyboard (filetree_focused, normal
/// mode). Global ctrl/alt chords still hit the keybind map first.
fn handleFiletreeKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;
    // Keep the "press p" hint visible while a move is pending
    if (editor.filetree_move_src == null) editor.status_message = "";
    if (tryKeybindCommand(editor, key)) return;
    // Super+letter is a desktop/OS chord, never a tree command
    if (key.mods.super) return;
    const ft = editor.ensureFiletree() orelse {
        _ = editor.takeKeyboardFocus(.pane);
        return;
    };
    switch (key.codepoint) {
        Key.escape => {
            // A pending move mark cancels first, then a multi selection;
            // only then does focus leave the tree.
            if (editor.filetree_move_src != null) {
                editor.cancelFiletreeMove();
                editor.status_message = "Move cancelled";
            } else if (ft.multi.count() > 0) {
                ft.clearMulti();
            } else {
                _ = editor.takeKeyboardFocus(.pane);
            }
        },
        Key.up, 'k' => {
            if (key.mods.shift and key.codepoint == Key.up) {
                ft.selectRangeTo(ft.selected -| 1) catch {};
            } else {
                ft.clearMulti();
                ft.moveSelection(-1);
            }
            ft.scroll_to_selected = true;
        },
        Key.down, 'j' => {
            if (key.mods.shift and key.codepoint == Key.down) {
                ft.selectRangeTo(ft.selected + 1) catch {};
            } else {
                ft.clearMulti();
                ft.moveSelection(1);
            }
            ft.scroll_to_selected = true;
        },
        Key.home => {
            ft.clearMulti();
            ft.selected = 0;
            ft.scroll_to_selected = true;
        },
        Key.end => {
            ft.clearMulti();
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
                _ = editor.takeKeyboardFocus(.pane);
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
        'o' => editor.filetreeOpenSelectedAsRoot(),
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

    // Terminals without the kitty keyboard protocol send Ctrl+/, Ctrl+\ and
    // Ctrl+] as bare C0 bytes with no mods (vaxis's legacy map stops at
    // 0x1A) — normalize so those keybinds work everywhere.
    switch (key.codepoint) {
        0x1c, 0x1d, 0x1f => {
            key.codepoint = switch (key.codepoint) {
                0x1c => '\\',
                0x1d => ']',
                else => '/',
            };
            key.mods.ctrl = true;
            key.text = null;
        },
        else => {},
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
            if (editor.wordWrapFor(editor.activeDoc())) {
                moveVisualVertical(editor, .up, shift);
            } else {
                _ = editor.execCommand(if (shift) "cursor_up_select" else "cursor_up", null);
            }
            return;
        },
        Key.down => {
            if (editor.wordWrapFor(editor.activeDoc())) {
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

    // Regular character input — use text if available, otherwise encode
    // codepoint. A lone control byte (a legacy chord with no binding) is
    // never typed into the document.
    if (key.text) |text| {
        if (text.len > 0 and !(text.len == 1 and (text[0] < 0x20 or text[0] == 0x7f))) {
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
    const cursor_col = label_len +| @as(u16, @intCast(@min(win.gwidth(input), width -| label_len)));
    if (cursor_col < width) {
        win.showCursor(cursor_col, overlay_y);
        win.setCursorShape(.beam_blink);
    }
}

/// Draw the command palette overlay.
/// Draw the docked workspace search panel: three input rows, a status /
/// confirm row, then result rows.
fn drawSearchPanel(win: Window, editor: *Editor, width: u16, panel_h: u16) void {
    const sp = &editor.search;
    const th = &editor.tui_theme;
    const bg_style: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_fg) };
    const dim_style: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_dim) };
    const sel_style: Style = .{ .bg = toVaxis(th.overlay_selection_bg), .fg = toVaxis(th.overlay_selection_fg), .bold = true };
    const label_active: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_fg), .bold = true, .reverse = true };
    win.fill(.{ .style = bg_style });

    const focused = editor.search_focused;
    drawSearchInputRow(win, 0, width, "Search ", sp.query(), focused and sp.field == .query, bg_style, label_active);
    drawSearchInputRow(win, 1, width, "Replace", sp.replacement(), focused and sp.field == .replace, bg_style, label_active);
    drawSearchInputRow(win, 2, width, "Include", sp.filter(), focused and sp.field == .filter, bg_style, label_active);
    drawSearchInputRow(win, 3, width, "Exclude", sp.exclude(), focused and sp.field == .exclude, bg_style, label_active);

    // Status / confirm row
    var sbuf: [300]u8 = undefined;
    var status_style = dim_style;
    const status_txt = blk: {
        if (sp.confirm_armed) {
            status_style = bg_style;
            const tgt = sp.replaceTargets(editor);
            break :blk std.fmt.bufPrint(&sbuf, "Replace {d} match(es)? [A]ll ({d} open + {d} on disk — disk is NOT undoable) / [O]pen docs only / [C]ancel", .{ sp.matches.items.len, tgt.open, tgt.disk }) catch "Replace? [A]ll / [O]pen only / [C]ancel";
        }
        const case_s: []const u8 = if (sp.case_sensitive) "[Aa]" else " aa ";
        const word_s: []const u8 = if (sp.whole_word) "[W]" else " w ";
        const busy: []const u8 = if (sp.searching) "  searching…" else "";
        const cap: []const u8 = if (sp.capped) "  (capped)" else "";
        break :blk std.fmt.bufPrint(&sbuf, "{s}{s}  {d} match(es) in {d} file(s), {d} scanned, {d} skipped{s}{s}   Alt+C case · Alt+W word · Tab fields · Enter on Replace = replace all", .{ case_s, word_s, sp.matches.items.len, sp.resultFileCount(), sp.files_searched, sp.files_skipped, busy, cap }) catch "";
    };
    const srow = win.child(.{ .y_off = 4, .height = 1, .width = width });
    srow.fill(.{ .style = status_style });
    _ = writeStr(srow, 0, 0, status_txt, status_style);

    // Result rows
    const rows: usize = panel_h -| 5;
    if (rows == 0 or sp.matches.items.len == 0) return;
    if (sp.selected < sp.scroll) sp.scroll = sp.selected;
    if (sp.selected >= sp.scroll + rows) sp.scroll = sp.selected - rows + 1;
    if (sp.scroll >= sp.matches.items.len) sp.scroll = sp.matches.items.len - 1;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const idx = sp.scroll + r;
        if (idx >= sp.matches.items.len) break;
        const m = sp.matches.items[idx];
        var rbuf: [512]u8 = undefined;
        const txt = std.fmt.bufPrint(&rbuf, " {s}:{d}: {s}", .{ sp.paths.items[m.path_idx], m.line + 1, m.excerpt }) catch " ?";
        const is_sel = idx == sp.selected;
        const row_win = win.child(.{ .y_off = @intCast(5 + r), .height = 1, .width = width });
        if (is_sel) row_win.fill(.{ .style = sel_style });
        _ = writeStr(row_win, 0, 0, txt, if (is_sel) sel_style else bg_style);
    }
}

fn drawSearchInputRow(win: Window, y: u16, width: u16, label: []const u8, value: []const u8, active: bool, base: Style, active_label: Style) void {
    const row = win.child(.{ .y_off = @intCast(y), .height = 1, .width = width });
    row.fill(.{ .style = base });
    var x = writeStr(row, 0, 0, label, if (active) active_label else base);
    x = writeStr(row, x, 0, " ", base);
    x = writeStr(row, x, 0, value, base);
    if (active) _ = writeStr(row, x, 0, "_", base);
}

/// Keys while the search panel owns the keyboard.
fn handleSearchKey(editor: *Editor, key: Key) void {
    const sp = &editor.search;
    if (key.isModifier()) return;

    if (sp.confirm_armed) {
        // Only unmodified letters answer (Ctrl+A is select-all, not "All")
        if (!hasCommandMod(key)) switch (key.codepoint) {
            'a', 'A' => editor.searchExecuteReplace(.all),
            'o', 'O' => editor.searchExecuteReplace(.open_only),
            'c', 'C', Key.escape => sp.confirm_armed = false,
            else => {},
        };
        return;
    }
    if (key.codepoint == Key.escape) {
        editor.searchHide();
        return;
    }
    // Global chords still work from the panel (Ctrl+Shift+F cycle, F4, …)
    if (tryKeybindCommand(editor, key)) return;
    if (key.mods.alt) {
        switch (key.codepoint) {
            'c' => {
                sp.case_sensitive = !sp.case_sensitive;
                if (sp.query_len > 0) editor.searchStart();
            },
            'w' => {
                sp.whole_word = !sp.whole_word;
                if (sp.query_len > 0) editor.searchStart();
            },
            else => {},
        }
        return;
    }
    if (key.codepoint == Key.tab) {
        sp.cycleField();
        return;
    }
    if (key.codepoint == Key.enter) {
        switch (sp.field) {
            .query, .filter, .exclude => editor.searchStart(),
            .replace => {
                editor.searchArmReplace();
            },
            .results => editor.searchOpenSelected(),
        }
        return;
    }
    if (key.codepoint == Key.up) {
        sp.moveSelection(false, 1);
        return;
    }
    if (key.codepoint == Key.down) {
        sp.moveSelection(true, 1);
        return;
    }
    if (key.codepoint == Key.page_up) {
        sp.moveSelection(false, 8);
        return;
    }
    if (key.codepoint == Key.page_down) {
        sp.moveSelection(true, 8);
        return;
    }
    if (key.codepoint == Key.backspace) {
        sp.backspace();
        return;
    }
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return;
    if (key.text) |text| {
        sp.appendText(text);
    } else {
        var bytes: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(key.codepoint, &bytes) catch return;
        sp.appendText(bytes[0..n]);
    }
}

/// Click inside the search band: focus the panel, pick a field or result.
fn handleSearchClick(editor: *Editor, band: SearchBand, row: u16) void {
    const sp = &editor.search;
    _ = editor.takeKeyboardFocus(.search);
    const rel = row - band.y;
    switch (rel) {
        0 => sp.field = .query,
        1 => sp.field = .replace,
        2 => sp.field = .filter,
        3 => sp.field = .exclude,
        4 => {},
        else => {
            const idx = sp.scroll + (rel - 5);
            if (idx < sp.matches.items.len) {
                sp.field = .results;
                sp.selected = idx;
            }
        },
    }
}

/// Draw the fuzzy file finder overlay (same layout as the palette; the
/// previewed file renders in the pane behind it).
fn drawFileFinder(win: Window, editor: *Editor, width: u16, height: u16) void {
    const filter = editor.finder_buf[0..editor.finder_buf_len];

    // Bottom-anchored (above the status bar) so the preview's opening
    // lines stay visible — unlike the palette's centered box.
    const list_rows: u16 = @min(8, height -| 4);
    const input_y: u16 = height -| (list_rows + 3);
    const finder_width: u16 = @min(width -| 4, 70);
    const finder_x: u16 = (width -| finder_width) / 2;

    const border_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_border) };
    const input_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg), .bold = true };
    const item_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    const selected_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_selection_bg), .fg = toVaxis(editor.tui_theme.overlay_selection_fg), .bold = true, .reverse = true };

    // Header / input line
    const header_win = win.child(.{ .x_off = @intCast(finder_x), .y_off = @intCast(input_y), .width = finder_width, .height = 1 });
    header_win.fill(.{ .style = border_style });
    _ = header_win.printSegment(.{ .text = "> ", .style = border_style }, .{ .wrap = .none });
    if (filter.len > 0) {
        const filter_win = header_win.child(.{ .x_off = 2, .width = finder_width -| 2 });
        _ = filter_win.printSegment(.{ .text = filter, .style = input_style }, .{ .wrap = .none });
    }
    const cursor_col = finder_x + 2 + @as(u16, @intCast(@min(win.gwidth(filter), finder_width -| 2)));
    win.showCursor(cursor_col, input_y);
    win.setCursorShape(.beam_blink);

    // Matches (paths are heap-allocated in finder_files — safe to reference).
    // The core scrolls the window so the selection is always drawn; the
    // draw never writes finder_selected (clamping it here made Down on the
    // last row preview one match while Enter opened another).
    const max_items: u16 = @min(height -| input_y -| 2, 8);
    const count = editor.finder_matches.items.len;
    const range = editor.finderVisibleRange(max_items);

    var item_y: u16 = 1;
    for (editor.finder_matches.items[range.start..range.end], range.start..) |fi, row| {
        const path = editor.finder_files.items[fi];
        const is_selected = row == editor.finder_selected;
        const style = if (is_selected) selected_style else item_style;
        const row_win = win.child(.{
            .x_off = @intCast(finder_x),
            .y_off = @intCast(input_y + item_y),
            .width = finder_width,
            .height = 1,
        });
        row_win.fill(.{ .style = style });
        _ = row_win.printSegment(.{ .text = " ", .style = style }, .{ .wrap = .none });
        const text_win = row_win.child(.{ .x_off = 1, .width = finder_width -| 1 });
        _ = text_win.printSegment(.{ .text = path, .style = style }, .{ .wrap = .none });
        item_y += 1;
    }
    if (count == 0) {
        const row_win = win.child(.{ .x_off = @intCast(finder_x), .y_off = @intCast(input_y + 1), .width = finder_width, .height = 1 });
        row_win.fill(.{ .style = item_style });
        _ = row_win.printSegment(.{ .text = " (no matching files)", .style = item_style }, .{ .wrap = .none });
    }
}

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
    const cursor_col = palette_x + 2 + @as(u16, @intCast(@min(win.gwidth(filter), palette_width -| 2)));
    win.showCursor(cursor_col, input_y);
    win.setCursorShape(.beam_blink);

    // List matching commands
    const max_items: u16 = @min(height -| input_y -| 2, 10);
    var item_y: u16 = 1;

    // Get all command names and filter
    const names = editor.commands.allNames() catch return;

    // The visible window scrolls with the selection (the finder's rule, see
    // Editor.finderVisibleRange); drawing never writes palette_selected.
    const match_count = paletteMatchCount(editor);
    const selected = @min(editor.palette_selected, match_count -| 1);
    const first = (selected + 1) -| @as(usize, max_items);

    var shown: usize = 0;
    for (names) |name| {
        if (item_y > max_items) break;
        if (filter.len > 0 and !fuzzyMatch(name, filter)) continue;
        defer shown += 1;
        if (shown < first) continue;

        const is_selected = shown == selected;
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
    }
}

/// The generic pick-list (Editor.picker): title, filter line, rows with a
/// dim detail; the window scrolls with the selection like the palette.
fn drawPicker(win: Window, editor: *Editor, width: u16, height: u16) void {
    const p = &editor.picker;
    const top: u16 = height / 3;
    const box_w: u16 = @min(width -| 4, 70);
    const box_x: u16 = (width -| box_w) / 2;
    const border_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_border) };
    const input_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg), .bold = true };
    const item_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    const dim_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_dim) };
    const selected_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_selection_bg), .fg = toVaxis(editor.tui_theme.overlay_selection_fg), .bold = true, .reverse = true };

    const title_win = win.child(.{ .x_off = @intCast(box_x), .y_off = @intCast(top), .width = box_w, .height = 1 });
    title_win.fill(.{ .style = border_style });
    _ = title_win.printSegment(.{ .text = p.title(), .style = border_style }, .{ .wrap = .none });

    const input_win = win.child(.{ .x_off = @intCast(box_x), .y_off = @intCast(top + 1), .width = box_w, .height = 1 });
    input_win.fill(.{ .style = border_style });
    _ = input_win.printSegment(.{ .text = "> ", .style = border_style }, .{ .wrap = .none });
    const filter = p.filter();
    if (filter.len > 0) {
        const f_win = input_win.child(.{ .x_off = 2, .width = box_w -| 2 });
        _ = f_win.printSegment(.{ .text = filter, .style = input_style }, .{ .wrap = .none });
    }
    const cursor_col = box_x + 2 + @as(u16, @intCast(@min(win.gwidth(filter), box_w -| 2)));
    win.showCursor(cursor_col, top + 1);
    win.setCursorShape(.beam_blink);

    const max_items: usize = @min(@as(usize, height -| top -| 3), 12);
    if (p.count() == 0) {
        const row_win = win.child(.{ .x_off = @intCast(box_x), .y_off = @intCast(top + 2), .width = box_w, .height = 1 });
        row_win.fill(.{ .style = dim_style });
        _ = row_win.printSegment(.{ .text = if (p.items.items.len == 0) p.empty_hint else "(no matches)", .style = dim_style }, .{ .wrap = .none });
        return;
    }
    const first = p.firstVisible(max_items);
    var row: usize = 0;
    while (row < max_items and first + row < p.count()) : (row += 1) {
        const item = p.itemAt(first + row);
        const is_selected = first + row == p.selected;
        const style = if (is_selected) selected_style else item_style;
        const row_win = win.child(.{ .x_off = @intCast(box_x), .y_off = @intCast(top + 2 + row), .width = box_w, .height = 1 });
        row_win.fill(.{ .style = style });
        _ = row_win.printSegment(.{ .text = " ", .style = style }, .{ .wrap = .none });
        const label_win = row_win.child(.{ .x_off = 1, .width = box_w -| 1 });
        _ = label_win.printSegment(.{ .text = item.label, .style = style }, .{ .wrap = .none });
        if (item.detail.len > 0) {
            const lw = win.gwidth(item.label);
            if (lw + 3 < box_w) {
                const d_off: u16 = @intCast(lw + 3);
                const d_win = row_win.child(.{ .x_off = d_off, .width = box_w -| d_off });
                _ = d_win.printSegment(.{ .text = item.detail, .style = if (is_selected) style else dim_style }, .{ .wrap = .none });
            }
        }
    }
}

/// Keys in picker mode: the list, the filter, Enter and Escape.
fn handlePickerKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;
    switch (key.codepoint) {
        Key.escape => editor.pickerCancel(),
        Key.enter => editor.pickerConfirm(),
        Key.tab, Key.down => editor.picker.move(1),
        Key.up => editor.picker.move(-1),
        Key.page_down => editor.picker.move(10),
        Key.page_up => editor.picker.move(-10),
        Key.backspace => editor.pickerBackspace(),
        else => {
            var tmp: [64]u8 = undefined;
            var n: usize = 0;
            appendToInputBuf(&tmp, &n, key);
            if (n > 0) editor.pickerTyped(tmp[0..n]);
        },
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

/// Signature help: the call's signature on the row above the caret with
/// the active parameter in bold reverse, and a documentation row under it
/// when there is one.
fn drawSignatureHelp(win: Window, editor: *Editor, width: u16, height: u16) void {
    const sig = editor.signature orelse return;
    const rect = activePaneRect(editor) orelse return;
    const doc = editor.activeDoc();
    const caret = caretCell(editor, doc, doc.cursors.primaryConst().offset, rect.w, rect.h) orelse return;
    const caret_row: u16 = rect.y +| caret.y;
    const rows: u16 = if (sig.doc.len > 0) 2 else 1;
    const want: usize = @max(sig.label.len, sig.doc.len) + 2;
    const box_w: u16 = @intCast(@min(@as(usize, width -| 2), want));
    if (box_w == 0) return;
    const box_x: u16 = @min(rect.x +| caret.x, width -| box_w);
    const box_y: u16 = if (caret_row >= rows) caret_row - rows else caret_row + 1;
    if (box_y + rows > height) return;
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    const param_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg), .bold = true, .reverse = true };
    const dim_style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_dim) };
    const row = win.child(.{ .x_off = @intCast(box_x), .y_off = @intCast(box_y), .width = box_w, .height = 1 });
    row.fill(.{ .style = style });
    const segments = [_]struct { text: []const u8, style: Style }{
        .{ .text = sig.label[0..sig.param_start], .style = style },
        .{ .text = sig.label[sig.param_start..sig.param_end], .style = param_style },
        .{ .text = sig.label[sig.param_end..], .style = style },
    };
    var x: u16 = 1;
    for (segments) |seg| {
        if (seg.text.len == 0 or x >= box_w) continue;
        const seg_win = row.child(.{ .x_off = @intCast(x), .width = box_w - x });
        _ = seg_win.printSegment(.{ .text = seg.text, .style = seg.style }, .{ .wrap = .none });
        x +|= @intCast(@min(win.gwidth(seg.text), @as(usize, box_w)));
    }
    if (sig.doc.len > 0) {
        const doc_row = win.child(.{ .x_off = @intCast(box_x), .y_off = @intCast(box_y + 1), .width = box_w, .height = 1 });
        doc_row.fill(.{ .style = dim_style });
        const doc_win = doc_row.child(.{ .x_off = 1, .width = box_w -| 1 });
        _ = doc_win.printSegment(.{ .text = sig.doc, .style = dim_style }, .{ .wrap = .none });
    }
}

/// Draw the completion popup near the cursor position.
fn drawCompletionPopup(win: Window, editor: *Editor, width: u16, height: u16) void {
    if (!editor.completion_active) return;
    const items = editor.completion_items.items;
    if (items.len == 0) return;

    // (@min before the cast: a server can return more than 65 535 items)
    const max_visible: u16 = @intCast(@min(items.len, @min(height / 3, 10)));
    if (max_visible == 0) return;

    // Anchored at the caret of the focused pane, by positionCursor's math.
    // The old estimate ignored the pane's origin (tree, splits, no tab
    // bar), scrolling, wrapping and wide text.
    const rect = activePaneRect(editor) orelse return;
    const doc = editor.activeDoc();
    const caret = caretCell(editor, doc, doc.cursors.primaryConst().offset, rect.w, rect.h) orelse return;
    const cursor_screen_col: u16 = rect.x +| caret.x;
    const cursor_screen_row: u16 = rect.y +| caret.y;

    // Position popup below cursor, or above if near bottom
    const popup_width: u16 = @min(width -| 2, 40);
    const popup_x: u16 = @min(cursor_screen_col, width -| popup_width);
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

/// Append a character to a fixed buffer, returns new length. Keys that
/// arrive without text (arrows, Home/End, F-keys) are not typed text and
/// never land in a prompt.
fn appendToInputBuf(buf: []u8, buf_len: *usize, key: Key) void {
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return;
    if (key.text) |text| {
        text_input.append(buf, buf_len, text);
    } else if (isTextCodepoint(key.codepoint)) {
        text_input.appendCodepoint(buf, buf_len, key.codepoint);
    }
}

/// A bare codepoint that stands for a typed character: not a C0/DEL
/// control, and not a kitty-protocol functional key — vaxis reports those
/// in the private-use block U+E000–U+F8FF (Key.left … Key.right_meta),
/// which a Nerd Font happily draws as random icons.
fn isTextCodepoint(cp: u21) bool {
    if (cp < 0x20 or cp == 0x7F) return false;
    if (cp >= 0xE000 and cp <= 0xF8FF) return false;
    return true;
}

test "prompt input ignores functional keys that arrive without text" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    appendToInputBuf(&buf, &len, .{ .codepoint = Key.left });
    appendToInputBuf(&buf, &len, .{ .codepoint = Key.right });
    appendToInputBuf(&buf, &len, .{ .codepoint = Key.f7 });
    appendToInputBuf(&buf, &len, .{ .codepoint = Key.home });
    appendToInputBuf(&buf, &len, .{ .codepoint = Key.escape });
    try std.testing.expectEqual(@as(usize, 0), len);
    appendToInputBuf(&buf, &len, .{ .codepoint = 'a' });
    appendToInputBuf(&buf, &len, .{ .codepoint = Key.space });
    appendToInputBuf(&buf, &len, .{ .codepoint = 0xE9, .text = "é" });
    try std.testing.expectEqualStrings("a é", buf[0..len]);
}

/// Handle keys in Find mode.
fn handleFindKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        // Close find, keep cursor at current match
        editor.setMode(.normal);
        editor.status_message = "";
        return;
    }
    if (key.codepoint == Key.enter) {
        // Find next match from current position
        if (editor.find_buf_len > 0) {
            editor.findNext();
        }
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.find_buf_len > 0) {
            text_input.backspace(&editor.find_buf, &editor.find_buf_len);
            editor.findIncremental();
        }
        return;
    }
    editor.status_message = "";
    appendToInputBuf(&editor.find_buf, &editor.find_buf_len, key);
    editor.findIncremental();
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
        @intCast(win.gwidth(editor.replace_buf[0..editor.replace_buf_len]))
    else
        @intCast(win.gwidth(editor.find_buf[0..editor.find_buf_len]));
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
        editor.setMode(.normal);
        return;
    }
    if (key.codepoint == Key.tab) {
        // Toggle between find and replace fields
        editor.replace_field_active = !editor.replace_field_active;
        return;
    }
    // Ctrl+Enter or Ctrl+A in replace mode = replace all
    if (key.mods.ctrl and (key.codepoint == Key.enter or key.matches('a', .{ .ctrl = true }))) {
        editor.replaceAll();
        return;
    }
    if (key.codepoint == Key.enter) {
        if (!editor.replace_field_active) {
            // In find field: find next
            if (editor.find_buf_len > 0) editor.findNext();
        } else {
            // In replace field: replace current match and find next
            editor.replaceOne();
        }
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.replace_field_active) {
            if (editor.replace_buf_len > 0) text_input.backspace(&editor.replace_buf, &editor.replace_buf_len);
        } else {
            if (editor.find_buf_len > 0) {
                text_input.backspace(&editor.find_buf, &editor.find_buf_len);
                editor.findIncremental();
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
        editor.findIncremental();
    }
}

/// Handle keys in Confirm Overwrite mode (disk changed under a save).
fn handleConfirmOverwriteKey(editor: *Editor, key: Key) void {
    if (key.isModifier() or hasCommandMod(key)) return;
    switch (key.codepoint) {
        'o', 'O' => editor.resolveOverwrite(.overwrite),
        'r', 'R' => editor.resolveOverwrite(.reload),
        'c', 'C', 0x1b => editor.resolveOverwrite(.cancel), // 0x1b = Escape
        else => {},
    }
}

/// Set when [S]ave in the close-tab prompt met an untitled document: the
/// Save As prompt that follows closes the tab once the file is written.
var close_tab_after_save_as = false;

/// Close-tab prompt ([S]ave [D]iscard [C]ancel for one document).
fn handleConfirmCloseKey(editor: *Editor, key: Key) void {
    if (key.isModifier() or hasCommandMod(key)) return;
    switch (key.codepoint) {
        's', 'S' => {
            if (editor.resolveCloseDoc(.save) == .needs_path) {
                // Untitled: ask for a name first; handleSaveAsKey closes it.
                _ = editor.execAction("save_as");
                close_tab_after_save_as = true;
            }
        },
        'd', 'D' => {
            _ = editor.resolveCloseDoc(.discard);
        },
        'c', 'C', Key.escape => {
            _ = editor.resolveCloseDoc(.cancel);
        },
        else => {},
    }
}

/// Handle keys in Confirm Quit mode.
fn handleConfirmQuitKey(editor: *Editor, key: Key) void {
    if (key.isModifier() or hasCommandMod(key)) return;

    switch (key.codepoint) {
        's', 'S' => editor.saveAllAndQuit(),
        'd', 'D' => {
            // Discard and quit
            editor.discardAndQuit();
        },
        'c', 'C', Key.escape => {
            // Cancel — go back to normal mode
            editor.setMode(.normal);
        },
        else => {},
    }
}

/// Handle keys in File Open mode.
fn handleFileOpenKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        editor.setMode(.normal);
        return;
    }
    if (key.codepoint == Key.enter) {
        editor.setMode(.normal);
        if (editor.open_buf_len > 0) {
            const path = editor.open_buf[0..editor.open_buf_len];
            editor.recordNavPoint();
            _ = editor.openFile(path) catch |err| reportOpenError(editor, path, err);
        }
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.open_buf_len > 0) text_input.backspace(&editor.open_buf, &editor.open_buf_len);
        return;
    }
    appendToInputBuf(&editor.open_buf, &editor.open_buf_len, key);
}

/// `open_folder` prompt: Enter makes the typed folder the project.
fn handleFolderOpenKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;
    if (key.codepoint == Key.escape) {
        editor.setMode(.normal);
        return;
    }
    if (key.codepoint == Key.enter) {
        editor.setMode(.normal);
        if (editor.open_buf_len > 0) {
            var pbuf: [512]u8 = undefined;
            const n = editor.open_buf_len;
            @memcpy(pbuf[0..n], editor.open_buf[0..n]);
            _ = editor.openProject(pbuf[0..n]);
        }
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.open_buf_len > 0) text_input.backspace(&editor.open_buf, &editor.open_buf_len);
        return;
    }
    appendToInputBuf(&editor.open_buf, &editor.open_buf_len, key);
}

/// Recent-projects picker: Up/Down, Enter, a row's digit, Escape.
fn handleRecentProjectsKey(editor: *Editor, key: Key) void {
    if (key.isModifier() or hasCommandMod(key)) return;
    const count = editor.recent_projects.items.len;
    switch (key.codepoint) {
        Key.escape => editor.cancelRecentProjects(),
        Key.up => editor.recent_selected -|= 1,
        Key.down, Key.tab => if (count > 0) {
            editor.recent_selected = (editor.recent_selected + 1) % count;
        },
        Key.enter => editor.chooseRecentProject(editor.recent_selected),
        '1'...'9' => editor.chooseRecentProject(key.codepoint - '1'),
        else => {},
    }
}

fn drawRecentProjects(win: Window, editor: *Editor, width: u16, height: u16) void {
    const count: u16 = @intCast(@min(editor.recent_projects.items.len, Editor.recent_projects_max));
    const top = height -| (count + 2);
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    const panel = win.child(.{ .y_off = @intCast(top), .width = width, .height = count + 2 });
    panel.fill(.{ .style = style });
    _ = writeStr(panel, 1, 0, "Recent projects", style);
    recent_projects_band = .{ .x = 0, .y = top + 1, .w = width, .h = count };
    for (0..count) |idx| {
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, " {d}. {s}", .{ idx + 1, editor.recent_projects.items[idx] }) catch "";
        var row_style = style;
        row_style.reverse = idx == editor.recent_selected;
        _ = writeStr(panel, 0, @intCast(idx + 1), label, row_style);
    }
    _ = writeStr(panel, 1, count + 1, "Enter opens / Esc cancels", style);
}

/// Status line for a failed Open prompt (the prompt used to swallow errors).
fn reportOpenError(editor: *Editor, path: []const u8, err: anyerror) void {
    switch (err) {
        // The encoding picker took over; it names the file itself
        error.EncodingRequired => {},
        error.BinaryFile => editor.status_message = "Not opened: binary or unsupported text encoding",
        else => {
            var prefix_buf: [96]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buf, "Open failed ({s}): ", .{@errorName(err)}) catch "Open failed: ";
            lua_api.setStatusText(editor, prefix, path);
        },
    }
}

/// Handle keys in Save As mode.
fn handleSaveAsKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;
    if (key.codepoint == Key.escape) {
        editor.cancelSaveAs();
        close_tab_after_save_as = false;
        return;
    }
    if (key.codepoint == Key.enter) {
        if (editor.open_buf_len == 0) return;
        const id = editor.save_as_id orelse editor.activeDoc().id;
        const saved = editor.finishSaveAs(editor.open_buf[0..editor.open_buf_len]) == .saved;
        if (close_tab_after_save_as) {
            close_tab_after_save_as = false;
            if (saved) if (editor.docIndexForId(id)) |idx| {
                _ = editor.closeDocAt(idx);
            };
        }
        return;
    }
    if (key.codepoint == Key.backspace) {
        text_input.backspace(&editor.open_buf, &editor.open_buf_len);
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
        // Deleting is permanent: only an unmodified y confirms. Enter no
        // longer does (it was one stray keypress away from a delete), and
        // any other key cancels; chords (Ctrl+Y, ...) are ignored.
        if (hasCommandMod(key)) return;
        if (key.codepoint == 'y' or key.codepoint == 'Y') {
            editor.applyFiletreePrompt();
        } else {
            editor.cancelFiletreePrompt();
        }
        return;
    }
    if (key.codepoint == Key.enter) {
        editor.applyFiletreePrompt();
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.open_buf_len > 0) text_input.backspace(&editor.open_buf, &editor.open_buf_len);
        return;
    }
    appendToInputBuf(&editor.open_buf, &editor.open_buf_len, key);
}

/// Handle keys in Command Palette mode.
/// Handle keys in Fuzzy File Finder mode (quick_open).
fn handleFinderKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        editor.finderCancel();
        return;
    }
    if (key.codepoint == Key.enter) {
        editor.finderCommit();
        return;
    }
    if (key.codepoint == Key.down or key.codepoint == Key.tab) {
        editor.finderMove(true);
        return;
    }
    if (key.codepoint == Key.up) {
        editor.finderMove(false);
        return;
    }
    if (key.codepoint == Key.page_down) {
        editor.finderScrollPage(true);
        return;
    }
    if (key.codepoint == Key.page_up) {
        editor.finderScrollPage(false);
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.finder_buf_len > 0) {
            text_input.backspace(&editor.finder_buf, &editor.finder_buf_len);
            editor.finderRefresh();
        }
        return;
    }
    const before = editor.finder_buf_len;
    appendToInputBuf(&editor.finder_buf, &editor.finder_buf_len, key);
    if (editor.finder_buf_len != before) editor.finderRefresh();
}

/// Number of palette commands matching the current filter.
fn paletteMatchCount(editor: *Editor) usize {
    const filter = editor.palette_buf[0..editor.palette_buf_len];
    const names = editor.commands.allNames() catch return 0;
    var count: usize = 0;
    for (names) |name| {
        if (filter.len > 0 and !fuzzyMatch(name, filter)) continue;
        count += 1;
    }
    return count;
}

fn handlePaletteKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;

    if (key.codepoint == Key.escape) {
        editor.setMode(.normal);
        editor.palette_selected = 0;
        return;
    }
    if (key.codepoint == Key.enter) {
        // Execute the selected matching command (the drawn selection: the
        // index is clamped the same way drawCommandPalette clamps it)
        const filter = editor.palette_buf[0..editor.palette_buf_len];
        const names = editor.commands.allNames() catch {
            editor.setMode(.normal);
            editor.palette_selected = 0;
            return;
        };
        const selected = @min(editor.palette_selected, paletteMatchCount(editor) -| 1);
        var idx: usize = 0;
        for (names) |name| {
            if (filter.len > 0 and !fuzzyMatch(name, filter)) continue;
            if (idx == selected) {
                editor.setMode(.normal);
                editor.palette_selected = 0;
                _ = editor.execCommand(name, null);
                return;
            }
            idx += 1;
        }
        editor.setMode(.normal);
        editor.palette_selected = 0;
        return;
    }
    if (key.codepoint == Key.tab or key.codepoint == Key.down) {
        // Every match is reachable: the list scrolls (it used to stop at
        // the 10 visible rows)
        if (editor.palette_selected + 1 < paletteMatchCount(editor)) editor.palette_selected += 1;
        return;
    }
    if (key.codepoint == Key.up) {
        editor.palette_selected -|= 1;
        return;
    }
    if (key.codepoint == Key.backspace) {
        if (editor.palette_buf_len > 0) {
            text_input.backspace(&editor.palette_buf, &editor.palette_buf_len);
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
        editor.setMode(.normal);
        return;
    }
    if (key.codepoint == Key.enter) {
        if (editor.goto_buf_len > 0) {
            const num_str = editor.goto_buf[0..editor.goto_buf_len];
            const line_num = std.fmt.parseInt(usize, num_str, 10) catch 0;
            if (line_num > 0) {
                editor.jumpToLine(line_num);
            }
        }
        editor.setMode(.normal);
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
            // Typed identifier and trigger characters keep the popup (the
            // insert refilters or re-requests it); anything else dismisses
            // it. Either way the key goes on to the normal handler.
            const keeps = if (key.text) |text| !hasCommandMod(key) and text.len > 0 and (text.len > 1 or editor.completionKeepsOnByte(text[0])) else false;
            if (!keeps) editor.clearCompletionItems();
            handleKey(editor, key);
        },
    }
}

fn handleEncodingKey(editor: *Editor, key: Key) void {
    if (key.isModifier() or hasCommandMod(key)) return;
    switch (editor.mode) {
        .encoding_picker => switch (key.codepoint) {
            Key.escape => editor.cancelEncoding(),
            Key.up => editor.encoding_selected -|= 1,
            Key.down, Key.tab => editor.encoding_selected = (editor.encoding_selected + 1) % editor.encodingCount(),
            Key.enter => editor.chooseEncoding(editor.encoding_selected),
            '1'...'5' => editor.chooseEncoding(key.codepoint - '1'),
            else => {},
        },
        .confirm_reopen => switch (key.codepoint) {
            's', 'S' => editor.resolveReopen(.save),
            'd', 'D' => editor.resolveReopen(.discard),
            'c', 'C', Key.escape => editor.resolveReopen(.cancel),
            else => {},
        },
        .confirm_encoding => switch (key.codepoint) {
            's', 'S' => editor.resolveEncodingSave(true),
            'c', 'C', Key.escape => editor.resolveEncodingSave(false),
            else => {},
        },
        else => {},
    }
}

fn handleLspKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;
    if (key.codepoint == Key.escape) {
        if (editor.mode == .workspace_preview) editor.lsp_tools.resolvePreview(editor, false) else editor.setMode(.normal);
    } else if (editor.mode == .symbol_rename) {
        switch (key.codepoint) {
            Key.enter => editor.lsp_tools.submitRename(editor),
            Key.backspace => text_input.backspace(&editor.lsp_tools.name, &editor.lsp_tools.name_len),
            else => appendToInputBuf(&editor.lsp_tools.name, &editor.lsp_tools.name_len, key),
        }
    } else switch (key.codepoint) {
        Key.enter => if (editor.mode == .workspace_preview) {
            editor.lsp_tools.resolvePreview(editor, true);
        },
        Key.up => editor.lsp_tools.scroll -|= 1,
        Key.down => editor.lsp_tools.scroll +|= 1,
        else => {},
    }
}

fn drawLspPanel(win: Window, editor: *Editor, width: u16, height: u16) void {
    const rows = @min(height, @max(5, height / 2));
    const panel = win.child(.{ .y_off = @intCast(height -| rows), .width = width, .height = rows });
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    panel.fill(.{ .style = style });
    const preview = editor.mode == .workspace_preview;
    _ = writeStr(panel, 0, 0, if (preview) "Workspace edit preview: Enter applies / Esc cancels" else "Hover: Up/Down scroll / Esc closes", style);
    if (preview) {
        if (editor.lsp_tools.preview) |*plan| {
            editor.lsp_tools.scroll = @min(editor.lsp_tools.scroll, plan.files.items.len -| 1);
            for (plan.files.items[editor.lsp_tools.scroll..], 0..) |file, i| {
                if (i >= rows -| 1) break;
                var buf: [1200]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "{s} ({d} edits)", .{ file.path, file.ranges.items.len }) catch file.path;
                _ = writeStr(panel, 0, @intCast(i + 1), label, style);
            }
        }
    } else {
        const content = editor.lsp_tools.hover orelse "";
        editor.lsp_tools.scroll = @min(editor.lsp_tools.scroll, std.mem.count(u8, content, "\n"));
        var lines = std.mem.splitScalar(u8, content, '\n');
        for (0..editor.lsp_tools.scroll) |_| _ = lines.next();
        var i: u16 = 1;
        while (lines.next()) |line| : (i += 1) {
            if (i >= rows) break;
            _ = writeStr(panel, 0, i, line, style);
        }
    }
}

fn handleToolKey(editor: *Editor, key: Key) void {
    if (key.isModifier() or hasCommandMod(key)) return;
    switch (key.codepoint) {
        Key.escape => editor.setMode(.normal),
        Key.enter => editor.tool_panel.activate(editor),
        Key.up => editor.tool_panel.move(editor, false),
        Key.down => editor.tool_panel.move(editor, true),
        Key.page_up => editor.tool_panel.page(editor, false, 20),
        Key.page_down => editor.tool_panel.page(editor, true, 20),
        'f', 'F' => editor.tool_panel.action(editor, 'f'),
        's', 'S' => editor.tool_panel.action(editor, 's'),
        'r', 'R' => editor.tool_panel.action(editor, 'r'),
        'd', 'D' => editor.tool_panel.action(editor, 'd'),
        'u', 'U' => editor.tool_panel.action(editor, 'u'),
        'o', 'O' => editor.tool_panel.action(editor, 'o'),
        'a', 'A' => editor.tool_panel.action(editor, 'a'),
        'w', 'W' => editor.tool_panel.action(editor, 'w'),
        else => {},
    }
}

fn drawToolPanel(win: Window, editor: *Editor, width: u16, height: u16) void {
    const rows = @min(height, @max(6, height * 2 / 3));
    const panel = win.child(.{ .y_off = @intCast(height -| rows), .width = width, .height = rows });
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    panel.fill(.{ .style = style });
    var buf: [4096]u8 = undefined;
    const state = &editor.tool_panel;
    const total = state.count(editor);
    _ = writeStr(panel, 0, 0, state.title(editor, &buf), style);
    const visible = rows -| 2;
    if (state.selected < state.scroll) state.scroll = state.selected;
    if (state.selected >= state.scroll + visible) state.scroll = state.selected -| (visible -| 1);
    if (total == 0) _ = writeStr(panel, 0, 1, "No entries. Tasks can be registered in init.lua.", style);
    for (0..@min(visible, total -| state.scroll)) |i| {
        const index = state.scroll + i;
        var row_style = style;
        row_style.reverse = index == state.selected;
        _ = writeStr(panel, 0, @intCast(i + 1), state.row(editor, index, &buf), row_style);
    }
    _ = writeStr(panel, 0, rows -| 1, "Up/Down select • PgUp/PgDn scroll • Enter activates • Esc closes", style);
}

fn drawRecoveryPicker(win: Window, editor: *Editor, width: u16, height: u16) void {
    const recovery = if (editor.recovery) |*r| r else return;
    const count: u16 = @intCast(@min(recovery.candidates.items.len, height -| 4));
    const panel = win.child(.{ .y_off = @intCast(height -| (count + 3)), .width = width, .height = @min(height, count + 3) });
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    panel.fill(.{ .style = style });
    _ = writeStr(panel, 0, 0, "Recover unsaved documents from a previous instance:", style);
    for (recovery.candidates.items[0..count], 0..) |candidate, index| {
        _ = writeStr(panel, 1, @intCast(index + 1), candidate.name(), style);
    }
    _ = writeStr(panel, 0, count + 1, "[R]ecover all / [D]iscard all / [L]ater (Esc)", style);
}

fn drawEncodingPicker(win: Window, editor: *Editor, width: u16, height: u16) void {
    const count: u16 = @intCast(editor.encodingCount());
    const top = height -| (count + 2);
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.overlay_bg), .fg = toVaxis(editor.tui_theme.overlay_fg) };
    const panel = win.child(.{ .y_off = @intCast(top), .width = width, .height = count + 2 });
    panel.fill(.{ .style = style });
    _ = writeStr(panel, 1, 0, editor.encodingTitle(), style);
    encoding_picker_band = .{ .x = 0, .y = top + 1, .w = width, .h = count };
    for (0..count) |idx| {
        var buf: [80]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, " {d}. {s}", .{ idx + 1, editor.encodingLabel(idx) }) catch "";
        var row_style = style;
        row_style.reverse = idx == editor.encoding_selected;
        _ = writeStr(panel, 0, @intCast(idx + 1), label, row_style);
    }
    _ = writeStr(panel, 1, count + 1, "Enter selects / Esc cancels", style);
}

test "TUI snippets: dispatched keys edit fields and respect search focus" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    _ = try editor.registerSnippet("*", "demo", "Demo", "${1:first} ${2:tail}$0");
    const doc = editor.activeDoc();
    try doc.loadText("demo");
    doc.cursors.primary().moveToEnd(&doc.buffer);
    dispatchKey(&editor, .{ .codepoint = Key.tab });
    try t.expectEqualStrings("first", doc.selectedText().?);
    dispatchKey(&editor, .{ .codepoint = 0x1f600, .text = "😀" });
    dispatchKey(&editor, .{ .codepoint = Key.tab });
    try t.expectEqualStrings("tail", doc.selectedText().?);
    dispatchKey(&editor, .{ .codepoint = Key.tab, .mods = .{ .shift = true } });
    try t.expectEqualStrings("😀", doc.selectedText().?);
    dispatchKey(&editor, .{ .codepoint = Key.escape });
    try t.expect(doc.snippet_session == null);
    try t.expectEqualStrings("😀 tail", doc.buffer.slice(0, doc.buffer.byteLen()));
    try doc.loadText("demo");
    doc.cursors.primary().moveToEnd(&doc.buffer);
    dispatchKey(&editor, .{ .codepoint = Key.tab });
    editor.search_focused = true;
    editor.search.field = .query;
    dispatchKey(&editor, .{ .codepoint = Key.tab });
    try t.expectEqual(@import("../core/search.zig").Field.replace, editor.search.field);
    try t.expect(doc.snippet_session == null);
    try t.expectEqualStrings("first tail", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "TUI encoding smoke: status click picker Unicode fields and caret width" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.filetree_visible = false;
    var screen = try vaxis.Screen.init(t.allocator, .{ .cols = 100, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(t.allocator);
    const win: Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 30, .screen = &screen };
    frameArenaReset();
    drawEditor(win, &editor, 100, 30);
    try t.expect(encoding_band != null);
    try t.expectEqualStrings("U", screen.readCell(94, 29).?.char.grapheme);
    handleMouse(&editor, .{ .row = 29, .col = 98, .button = .left, .type = .press, .mods = .{} });
    try t.expectEqual(Editor.Mode.encoding_picker, editor.mode);
    drawEncodingPicker(win, &editor, 100, 30);
    handleEncodingKey(&editor, .{ .codepoint = Key.down });
    handleEncodingKey(&editor, .{ .codepoint = Key.enter });
    try t.expectEqual(Editor.EncodingAction.save, editor.encoding_action);
    handleEncodingKey(&editor, .{ .codepoint = Key.escape });
    try editor.activeDoc().loadText("éé😀");
    _ = editor.execAction("find_replace");
    handleFindReplaceKey(&editor, .{ .codepoint = 'é', .text = "é" });
    try t.expectEqualStrings("é", editor.find_buf[0..editor.find_buf_len]);
    handleFindReplaceKey(&editor, .{ .codepoint = Key.enter });
    try t.expectEqual(@as(usize, 4), editor.activeDoc().cursors.primary().offset);
    handleFindReplaceKey(&editor, .{ .codepoint = Key.tab });
    handleFindReplaceKey(&editor, .{ .codepoint = Key.enter });
    try t.expectEqualStrings("é😀", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    handleFindReplaceKey(&editor, .{ .codepoint = 0x754c });
    handleFindReplaceKey(&editor, .{ .codepoint = Key.backspace });
    try t.expectEqual(@as(usize, 0), editor.replace_buf_len);
    drawOverlay(win, &editor, "Open: ", "é界😀", 100, 30);
    try t.expectEqual(@as(u16, 11), screen.cursor.col);
    editor.search.field = .query;
    handleSearchKey(&editor, .{ .codepoint = 0x754c });
    try t.expectEqualStrings("界", editor.search.query());
}

test "TUI cell math: tabs, wide and zero-width characters, mid-character starts" {
    const t = std.testing;
    // Cells to bytes, clamped; a start inside a character snaps forward
    try t.expectEqual(@as(usize, 3), byteAtCol("héllo", 0, 2, 4, false));
    try t.expectEqual(@as(usize, 6), byteAtCol("héllo", 0, 99, 4, false));
    try t.expectEqual(@as(usize, 2), colOfByte("héllo", 2, 4));
    try t.expectEqual(@as(usize, 3), byteAtCol("héllo", 0, colOfByte("héllo", 2, 4), 4, false));
    try t.expectEqual(@as(usize, 6), byteAtCol("héllo", 0, colOfByte("héllo", 9, 4), 4, false));
    // A tab reaches the next tab stop
    try t.expectEqual(@as(usize, 4), colOfByte("\tx", 1, 4));
    try t.expectEqual(@as(usize, 8), colOfByte("ab\tcd\t", 6, 4));
    try t.expectEqual(@as(usize, 3), colOfByte("ab\tcd\t", 3, 3));
    try t.expectEqual(@as(usize, 5), advanceCols("\tx", 0, 4));
    // Wide characters take two cells; combining marks and ZWJ none
    try t.expectEqual(@as(usize, 2), advanceCols("界", 0, 4));
    try t.expectEqual(@as(usize, 1), advanceCols("e\u{301}", 0, 4));
    try t.expectEqual(@as(usize, 2), advanceCols("a\u{200d}b", 0, 4));
    // A click lands on the nearer edge of a tab or wide character
    try t.expectEqual(@as(usize, 0), byteAtCol("\tx", 0, 1, 4, true));
    try t.expectEqual(@as(usize, 1), byteAtCol("\tx", 0, 2, 4, true));
    try t.expectEqual(@as(usize, 1), byteAtCol("\tx", 0, 4, 4, true));
    try t.expectEqual(@as(usize, 3), byteAtCol("界x", 0, 1, 4, true));
    // ... and never between a character and its combining mark
    try t.expectEqual(@as(usize, 3), byteAtCol("e\u{301}x", 0, 1, 4, false));
    // A wide character straddling the right edge is left out
    try t.expectEqual(@as(usize, 1), fitEnd("a界", 0, 2, 4));
    // Wrapping counts cells: "a" + a 3-cell tab fill a 4-cell row
    try t.expectEqual(@as(u16, 2), wrapLineRows("a\tb", 4, 4));
    try t.expectEqual(@as(u16, 0), wrapColToVisual("a\tb", 4, 1, 4).row);
    try t.expectEqual(@as(u16, 1), wrapColToVisual("a\tb", 4, 1, 4).col);
    try t.expectEqual(@as(u16, 1), wrapColToVisual("a\tb", 4, 2, 4).row);
    try t.expectEqual(@as(u16, 0), wrapColToVisual("a\tb", 4, 2, 4).col);
    // A wide character that does not fit moves to the next row
    try t.expectEqual(@as(u16, 2), wrapLineRows("abc界", 4, 4));
    try t.expectEqual(@as(usize, 3), wrapVisualToCol("abc界", 4, 1, 0, 4));
}

test "TUI no-wrap: cursors, clicks, and row text count display cells, not bytes" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.filetree_visible = false;
    editor.word_wrap = false;
    var screen = try vaxis.Screen.init(t.allocator, .{ .cols = 100, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(t.allocator);
    const win: Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 30, .screen = &screen };
    const doc = editor.activeDoc();
    try doc.loadText("héllo wörld\n" ++ "é" ** 60);
    doc.cursors.primary().offset = 4; // second "l": 4 bytes but 3 cells in
    try doc.cursors.addCursor(8); // "ö": 7 cells in
    frameArenaReset();
    drawEditor(win, &editor, 100, 30);
    positionCursor(win, &editor, 100, 30);
    const rect = pane_rects[0];
    const x0 = rect.x + lineNumberWidth(doc.lineCount(), editor.gutter_min_digits) + 1;
    try t.expectEqual(x0 + 3, screen.cursor.col);
    const sec = screen.readCell(x0 + 7, rect.y).?;
    try t.expectEqualStrings("ö", sec.char.grapheme);
    try t.expectEqual(toVaxis(editor.tui_theme.cursor_bg), sec.style.bg);
    try t.expectEqualStrings("é", screen.readCell(x0 + 59, rect.y + 1).?.char.grapheme);
    handleMouse(&editor, .{ .row = @intCast(rect.y), .col = @intCast(x0 + 8), .button = .left, .type = .press, .mods = .{} });
    try t.expectEqual(@as(usize, 10), doc.cursors.primary().offset);

    // scroll_left inside "é": row text, cursor, and clicks all snap to the next char
    doc.scroll_left = 2;
    doc.cursors.primary().offset = 4;
    frameArenaReset();
    drawEditor(win, &editor, 100, 30);
    positionCursor(win, &editor, 100, 30);
    try t.expectEqualStrings("l", screen.readCell(x0, rect.y).?.char.grapheme);
    try t.expectEqual(x0 + 1, screen.cursor.col);
    handleMouse(&editor, .{ .row = @intCast(rect.y), .col = @intCast(x0), .button = .left, .type = .press, .mods = .{} });
    try t.expectEqual(@as(usize, 3), doc.cursors.primary().offset);
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn testScreen(allocator: std.mem.Allocator) !vaxis.Screen {
    return vaxis.Screen.init(allocator, .{ .cols = 100, .rows = 30, .x_pixel = 0, .y_pixel = 0 });
}

fn testWin(screen: *vaxis.Screen) Window {
    return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 100, .height = 30, .screen = screen };
}

/// A fresh frame, as `run` draws it.
fn testFrame(win: Window, editor: *Editor) void {
    frameArenaReset();
    drawEditor(win, editor, 100, 30);
}

fn testClick(editor: *Editor, col: u16, row: u16) void {
    handleMouse(editor, .{ .row = @intCast(row), .col = @intCast(col), .button = .left, .type = .press, .mods = .{} });
    handleMouse(editor, .{ .row = @intCast(row), .col = @intCast(col), .button = .left, .type = .release, .mods = .{} });
}

fn testKey(editor: *Editor, codepoint: u21, mods: Key.Modifiers) void {
    dispatchKey(editor, .{ .codepoint = codepoint, .mods = mods });
}

fn testType(editor: *Editor, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const ch = charAt(text, i);
        dispatchKey(editor, .{ .codepoint = ch.cp, .text = text[i..][0..ch.len] });
        i += ch.len;
    }
}

/// Text of `len` screen cells starting at (x, y).
fn testCells(screen: *vaxis.Screen, x: u16, y: u16, len: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    for (0..len) |i| {
        const g = screen.readCell(x + @as(u16, @intCast(i)), y).?.char.grapheme;
        @memcpy(buf[n..][0..g.len], g);
        n += g.len;
    }
    return buf[0..n];
}

const TestClipboard = struct {
    // Nothing reaches the system clipboard; getClipboard reads editor.clipboard.
    fn set(_: []const u8) void {}
    fn get() []const u8 {
        return "";
    }
};

// ---------------------------------------------------------------------------
// E1 terminal keys, E3 wakes, E2 paste
// ---------------------------------------------------------------------------

test "TUI terminal keys: specials, whole text and Ctrl chords reach the shell encoded" {
    const t = std.testing;
    var out: [64]u8 = undefined;
    try t.expectEqualStrings("\x1b[A", terminalKeyBytes(.{ .codepoint = Key.up }, false, &out));
    try t.expectEqualStrings("\x1b[1;2A", terminalKeyBytes(.{ .codepoint = Key.up, .mods = .{ .shift = true } }, false, &out));
    try t.expectEqualStrings("\x1bOA", terminalKeyBytes(.{ .codepoint = Key.up }, true, &out));
    try t.expectEqualStrings("\x1b[1;5C", terminalKeyBytes(.{ .codepoint = Key.right, .mods = .{ .ctrl = true } }, true, &out));
    try t.expectEqualStrings("\x1b[H", terminalKeyBytes(.{ .codepoint = Key.home }, false, &out));
    try t.expectEqualStrings("\x1b[6~", terminalKeyBytes(.{ .codepoint = Key.page_down }, false, &out));
    try t.expectEqualStrings("\x1b[3~", terminalKeyBytes(.{ .codepoint = Key.delete }, false, &out));
    try t.expectEqualStrings("\x1bOP", terminalKeyBytes(.{ .codepoint = Key.f1 }, false, &out));
    try t.expectEqualStrings("\x1b[18~", terminalKeyBytes(.{ .codepoint = Key.f7 }, false, &out));
    try t.expectEqualStrings("\r", terminalKeyBytes(.{ .codepoint = Key.enter }, false, &out));
    try t.expectEqualStrings("\x7f", terminalKeyBytes(.{ .codepoint = Key.backspace }, false, &out));
    try t.expectEqualStrings("\x1b", terminalKeyBytes(.{ .codepoint = Key.escape }, false, &out));
    // Text keys send every byte: emoji, CJK, multi-code-point graphemes
    try t.expectEqualStrings("😀", terminalKeyBytes(.{ .codepoint = 0x1F600, .text = "😀" }, false, &out));
    try t.expectEqualStrings("界", terminalKeyBytes(.{ .codepoint = 0x754C, .text = "界" }, false, &out));
    try t.expectEqualStrings("👩‍🚀", terminalKeyBytes(.{ .codepoint = Key.multicodepoint, .text = "👩‍🚀" }, false, &out));
    try t.expectEqualStrings("\x1bx", terminalKeyBytes(.{ .codepoint = 'x', .text = "x", .mods = .{ .alt = true } }, false, &out));
    // Ctrl chords are C0 bytes — Windows consoles report the character
    try t.expectEqualStrings("\x1b", terminalKeyBytes(.{ .codepoint = '[', .mods = .{ .ctrl = true } }, false, &out));
    try t.expectEqualStrings("\x1c", terminalKeyBytes(.{ .codepoint = '\\', .mods = .{ .ctrl = true } }, false, &out));
    try t.expectEqualStrings("\x1f", terminalKeyBytes(.{ .codepoint = '/', .mods = .{ .ctrl = true } }, false, &out));
    try t.expectEqualStrings("\x03", terminalKeyBytes(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }, false, &out));
    // ... and a legacy terminal's raw C0 text passes through as-is
    try t.expectEqualStrings("\x1d", terminalKeyBytes(.{ .codepoint = 0x1d, .text = "\x1d" }, false, &out));
    // Modifier and media keys send nothing
    try t.expectEqualStrings("", terminalKeyBytes(.{ .codepoint = Key.left_shift, .mods = .{ .shift = true } }, false, &out));
    try t.expectEqualStrings("", terminalKeyBytes(.{ .codepoint = Key.media_play }, false, &out));
}

var test_wakes_returned = std.atomic.Value(bool).init(false);
fn testWakeThread() void {
    lspWakeFn();
    terminalWakeFn();
    luaJobWakeFn();
    test_wakes_returned.store(true, .release);
}

test "TUI wakes never block on a full event queue" {
    const t = std.testing;
    var loop: vaxis.Loop(Event) = .{ .io = t.io, .tty = undefined, .vaxis = undefined, .queue = .init(t.io) };
    global_loop = &loop;
    defer global_loop = null;
    while (try loop.tryPostEvent(.lsp_data)) {}
    test_wakes_returned.store(false, .release);
    const th = try std.Thread.spawn(.{}, testWakeThread, .{});
    var waited: usize = 0;
    while (!test_wakes_returned.load(.acquire) and waited < 100) : (waited += 1) {
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    const returned = test_wakes_returned.load(.acquire);
    // Free the queue so a parked (unfixed) wake could finish
    while (try loop.tryEvent()) |_| {}
    th.join();
    try t.expect(returned);
}

test "TUI paste: a bracketed paste is one verbatim edit; prompts take its first line" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    defer paste_buf.clearAndFree(t.allocator);
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    const doc = editor.activeDoc();

    // Typed, Enter auto-indents and "(" / "{" auto-close; pasted, neither
    handleInputEvent(&editor, .paste_start, null);
    for ("if (x) {") |c| handleInputEvent(&editor, .{ .key_press = .{ .codepoint = c, .text = &[_]u8{c} } }, null);
    handleInputEvent(&editor, .{ .key_press = .{ .codepoint = Key.enter } }, null);
    handleInputEvent(&editor, .{ .key_press = .{ .codepoint = 'j', .mods = .{ .ctrl = true } } }, null); // CR LF = one break
    for ("  y;") |c| handleInputEvent(&editor, .{ .key_press = .{ .codepoint = c, .text = &[_]u8{c} } }, null);
    handleInputEvent(&editor, .{ .key_press = .{ .codepoint = 'j', .mods = .{ .ctrl = true } } }, null);
    handleInputEvent(&editor, .{ .key_press = .{ .codepoint = '}', .text = "}" } }, null);
    try t.expectEqualStrings("", doc.buffer.slice(0, doc.buffer.byteLen()));
    handleInputEvent(&editor, .paste_end, null);
    try t.expectEqualStrings("if (x) {\n  y;\n}", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(!paste_active);
    // One undo step removes all of it
    try t.expect(try doc.undoAction());
    try t.expectEqualStrings("", doc.buffer.slice(0, doc.buffer.byteLen()));

    // A single-line prompt takes the first line, as if typed
    _ = editor.execAction("find");
    handleInputEvent(&editor, .paste_start, null);
    for ("needle") |c| handleInputEvent(&editor, .{ .key_press = .{ .codepoint = c, .text = &[_]u8{c} } }, null);
    handleInputEvent(&editor, .{ .key_press = .{ .codepoint = Key.enter } }, null);
    handleInputEvent(&editor, .{ .key_press = .{ .codepoint = 'x', .text = "x" } }, null);
    handleInputEvent(&editor, .paste_end, null);
    try t.expectEqual(Editor.Mode.find, editor.mode);
    try t.expectEqualStrings("needle", editor.find_buf[0..editor.find_buf_len]);
    editor.setMode(.normal);

    // A pasted letter never answers a confirmation
    editor.setMode(.confirm_quit);
    handleInputEvent(&editor, .paste_start, null);
    handleInputEvent(&editor, .{ .key_press = .{ .codepoint = 'd', .text = "d" } }, null);
    handleInputEvent(&editor, .paste_end, null);
    try t.expectEqual(Editor.Mode.confirm_quit, editor.mode);
    try t.expect(editor.running);
}

// ---------------------------------------------------------------------------
// E4 tabs and cell widths
// ---------------------------------------------------------------------------

test "TUI tabs: indentation is drawn, and caret, clicks and cursors agree with it" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    const doc = editor.activeDoc();
    try doc.loadText("\tx = 1;\n\t\t界z\n");
    for ([_]bool{ false, true }) |wrap| {
        editor.word_wrap = wrap;
        doc.cursors.primary().offset = 1; // on 'x', right after the tab
        testFrame(win, &editor);
        positionCursor(win, &editor, 100, 30);
        const rect = pane_rects[0];
        const x0 = rect.x + lineNumberWidth(doc.lineCount(), editor.gutter_min_digits) + 1;
        // The tab is 4 cells wide (was 0 drawn, 1 counted): 'x' sits at the
        // tab stop and so does the caret
        try t.expectEqualStrings(" ", screen.readCell(x0, rect.y).?.char.grapheme);
        try t.expectEqualStrings("x", screen.readCell(x0 + 4, rect.y).?.char.grapheme);
        try t.expectEqual(x0 + 4, screen.cursor.col);
        try t.expectEqualStrings("界", screen.readCell(x0 + 8, rect.y + 1).?.char.grapheme);
        try t.expectEqualStrings("z", screen.readCell(x0 + 10, rect.y + 1).?.char.grapheme);
        // Clicks: the right half of the tab is after it, the left before it
        testClick(&editor, x0 + 3, rect.y);
        try t.expectEqual(@as(usize, 1), doc.cursors.primary().offset);
        testClick(&editor, x0 + 1, rect.y);
        try t.expectEqual(@as(usize, 0), doc.cursors.primary().offset);
        testClick(&editor, x0 + 10, rect.y + 1);
        try t.expectEqualStrings("z", doc.buffer.slice(doc.cursors.primary().offset, doc.cursors.primary().offset + 1));
        // A secondary cursor after the tabs is drawn on the wide character
        doc.cursors.primary().offset = 0;
        try doc.cursors.addCursor(doc.buffer.posToOffset(1, 2));
        testFrame(win, &editor);
        const sec = screen.readCell(x0 + 8, rect.y + 1).?;
        try t.expectEqualStrings("界", sec.char.grapheme);
        try t.expectEqual(toVaxis(editor.tui_theme.cursor_bg), sec.style.bg);
        doc.cursors.clearSecondary();
    }
}

test "TUI diagnostic underlines land on the cells of their byte columns" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    const doc = editor.activeDoc();
    try doc.loadText("\tfoo bar");
    // "bar" = bytes 5..8, drawn at cells 8..10 (the tab spans 0..3)
    try doc.diagnostics.append(doc.allocator, .{
        .start_line = 0,
        .start_col = 5,
        .end_line = 0,
        .end_col = 8,
        .severity = .err,
        .message = try doc.allocator.dupe(u8, "bad"),
    });
    testFrame(win, &editor);
    const rect = pane_rects[0];
    const x0 = rect.x + lineNumberWidth(doc.lineCount(), editor.gutter_min_digits) + 1;
    try t.expectEqualStrings("b", screen.readCell(x0 + 8, rect.y).?.char.grapheme);
    for (8..11) |cx| try t.expectEqual(vaxis.Style.Underline.single, screen.readCell(x0 + @as(u16, @intCast(cx)), rect.y).?.style.ul_style);
    for (4..8) |cx| try t.expectEqual(vaxis.Style.Underline.off, screen.readCell(x0 + @as(u16, @intCast(cx)), rect.y).?.style.ul_style);
}

test "TUI no-wrap: the view scrolls sideways by cells, against the real text width" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    editor.word_wrap = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    const doc = editor.activeDoc();
    // 30 tabs = 120 cells but only 30 bytes: a byte count never scrolled
    try doc.loadText("\t" ** 30 ++ "end");
    doc.cursors.primary().offset = 30;
    testFrame(win, &editor);
    positionCursor(win, &editor, 100, 30);
    try t.expect(screen.cursor_vis);
    const rect = pane_rects[0];
    const x0 = rect.x + lineNumberWidth(doc.lineCount(), editor.gutter_min_digits) + 1;
    try t.expectEqualStrings("e", screen.readCell(screen.cursor.col, rect.y).?.char.grapheme);
    try t.expect(screen.cursor.col < rect.x + rect.w);
    try t.expect(doc.scroll_left > 0);
    // Back to the start scrolls back
    doc.cursors.primary().offset = 0;
    testFrame(win, &editor);
    positionCursor(win, &editor, 100, 30);
    try t.expectEqual(@as(usize, 0), doc.scroll_left);
    try t.expectEqual(x0, screen.cursor.col);
}

// ---------------------------------------------------------------------------
// E5 drags, wrapped clicks and the wheel; E6 caret; E9 completion popup
// ---------------------------------------------------------------------------

test "TUI mouse: drags stay in their pane; wrapped clicks measure the pane hit" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    editor.word_wrap = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    const doc0 = editor.activeDoc();
    try doc0.loadText("a\nb\nc\n");
    const d1 = try editor.newDocument();
    try d1.loadText("0123456789\n" ** 50);
    const w = editor.activeWindow();
    _ = try w.layout.splitPane(0, .horizontal, .{ .editor = 1 });
    w.layout.panes.items[0].content = .{ .editor = 0 };
    editor.focusPane(0);
    testFrame(win, &editor);
    const left = paneRectFor(0).?;
    const right = paneRectFor(1).?;

    // Press in the left pane, drag deep into the right one: the selection
    // stays in the left document (it used to take the right pane's offset)
    handleMouse(&editor, .{ .row = @intCast(left.y), .col = @intCast(left.x + 5), .button = .left, .type = .press, .mods = .{} });
    handleMouse(&editor, .{ .row = @intCast(right.y + 20), .col = @intCast(right.x + 8), .button = .left, .type = .drag, .mods = .{} });
    const d0 = &editor.documents.items[0];
    try t.expectEqual(@as(usize, 6), d0.cursors.primary().offset);
    try t.expectEqual(@as(usize, 0), editor.documents.items[1].cursors.primary().offset);
    handleMouse(&editor, .{ .row = @intCast(right.y + 20), .col = @intCast(right.x + 8), .button = .left, .type = .release, .mods = .{} });
    // Typing replaces the selection in the left document
    testType(&editor, "z");
    try t.expectEqualStrings("az", d0.buffer.slice(0, d0.buffer.byteLen()));
    try t.expectEqualStrings("", editor.status_message);
    // A drag outside the window clamps instead of failing
    handleMouse(&editor, .{ .row = @intCast(left.y), .col = @intCast(left.x + 5), .button = .left, .type = .press, .mods = .{} });
    handleMouse(&editor, .{ .row = -3, .col = -7, .button = .left, .type = .drag, .mods = .{} });
    try t.expectEqual(@as(usize, 0), d0.cursors.primary().offset);

    // Wrapped click in a narrower split: measured with THAT pane's width
    // (editor.text_width is the focused left pane's)
    editor.word_wrap = true;
    try editor.documents.items[1].loadText("0123456789" ** 8);
    _ = try w.layout.splitPane(1, .horizontal, .{ .editor = 1 });
    editor.focusPane(0);
    testFrame(win, &editor);
    const narrow = paneRectFor(2).?;
    try t.expect(narrow.w < left.w);
    const gutter = lineNumberWidth(1, editor.gutter_min_digits) + 1;
    testClick(&editor, narrow.x + gutter, narrow.y + 1);
    try t.expectEqual(@as(u8, 2), editor.activePaneId());
    try t.expectEqual(@as(usize, narrow.w - gutter), editor.activeDoc().cursors.primary().offset);
}

test "TUI mouse: the wheel scrolls the document under it, never a terminal" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    editor.word_wrap = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    try editor.activeDoc().loadText("x\n" ** 100);
    const d1 = try editor.newDocument();
    try d1.loadText("y\n" ** 100);
    try editor.terminals.append(t.allocator, null); // fake slot: no shell
    const w = editor.activeWindow();
    _ = try w.layout.splitPane(0, .horizontal, .{ .editor = 1 });
    _ = try w.layout.splitPane(1, .vertical, .{ .terminal = 0 });
    w.layout.panes.items[0].content = .{ .editor = 0 };
    editor.focusPane(0);
    testFrame(win, &editor);
    const right = paneRectFor(1).?;
    const term = paneRectFor(2).?;
    scroll_pinned = false;
    handleMouse(&editor, .{ .row = @intCast(right.y + 1), .col = @intCast(right.x + 3), .button = .wheel_down, .type = .press, .mods = .{} });
    try t.expectEqual(@as(usize, 5), editor.documents.items[1].scroll_top);
    try t.expectEqual(@as(usize, 0), editor.documents.items[0].scroll_top);
    try t.expect(!scroll_pinned); // the focused pane still follows its caret
    handleMouse(&editor, .{ .row = @intCast(term.y + 1), .col = @intCast(term.x + 3), .button = .wheel_down, .type = .press, .mods = .{} });
    try t.expectEqual(@as(usize, 5), editor.documents.items[1].scroll_top);
    try t.expectEqual(@as(usize, 0), editor.documents.items[0].scroll_top);
}

test "TUI caret: hidden above a wheel-scrolled view; a far caret never overflows" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    const doc = editor.activeDoc();
    defer scroll_pinned = false;
    try doc.loadText("x\n" ** 100);
    for ([_]bool{ false, true }) |wrap| {
        editor.word_wrap = wrap;
        doc.cursors.primary().offset = 0;
        doc.scroll_top = 50;
        scroll_pinned = true; // what a wheel scroll sets
        testFrame(win, &editor);
        positionCursor(win, &editor, 100, 30);
        try t.expect(!screen.cursor_vis);
    }
    // Wrapped, pinned at the top, caret 70 000 lines down: the row sum used
    // to overflow a u16
    try doc.loadText("x\n" ** 70000);
    editor.word_wrap = true;
    doc.cursors.primary().offset = doc.buffer.posToOffset(69990, 0);
    doc.scroll_top = 0;
    scroll_pinned = true;
    testFrame(win, &editor);
    positionCursor(win, &editor, 100, 30);
    try t.expect(!screen.cursor_vis);
}

test "TUI completion popup opens at the caret of the focused pane" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    editor.word_wrap = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    const d1 = try editor.newDocument();
    try d1.loadText("ab");
    d1.cursors.primary().offset = 2;
    const w = editor.activeWindow();
    const right_id = try w.layout.splitPane(w.active_pane, .horizontal, .{ .editor = 1 });
    editor.focusPane(right_id);
    try editor.addCompletionItem(try t.allocator.dupe(u8, "abcompl"), null, null);
    testFrame(win, &editor);
    drawCompletionPopup(win, &editor, 100, 30);
    const rect = paneRectFor(right_id).?;
    const caret_x = rect.x + lineNumberWidth(d1.lineCount(), editor.gutter_min_digits) + 1 + 2;
    var buf: [16]u8 = undefined;
    // Popup row: one cell of padding, then the label, just below the caret
    // (the old estimate put it at column 5, in the left pane)
    try t.expectEqualStrings("abcompl", testCells(&screen, caret_x + 1, rect.y + 1, 7, &buf));
}

// ---------------------------------------------------------------------------
// E7 keyboard focus, prompts and the delete confirmation
// ---------------------------------------------------------------------------

test "TUI focus: the tree over a terminal pane owns the keys until the pane is clicked" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "b\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, root);
    editor.filetree_visible = true;
    try editor.terminals.append(t.allocator, null); // fake slot: no shell
    editor.activeLayout().panes.items[0].content = .{ .terminal = 0 };
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    testFrame(win, &editor);
    const band = filetree_band.?;

    // Click the first tree row: the tree owns the keyboard, not the shell
    testClick(&editor, band.x + 4, band.y + 1);
    try t.expectEqual(Editor.KeyboardOwner.filetree, editor.keyboardOwner());
    testKey(&editor, 'j', .{});
    try t.expectEqual(@as(usize, 1), editor.filetree.?.selected);
    // The bound copy chord copies the selected file
    testKey(&editor, 'c', .{ .ctrl = true });
    try t.expectEqual(@as(usize, 1), editor.filetree_clip_paths.items.len);
    try t.expectEqualStrings("b.txt", editor.filetree_clip_paths.items[0]);
    testFrame(win, &editor);

    // Clicking the terminal hands it the keyboard: 'd' is typed, it no
    // longer opens the tree's delete prompt
    const term = pane_rects[0];
    testClick(&editor, term.x + 2, term.y + 1);
    try t.expectEqual(Editor.KeyboardOwner.terminal, editor.keyboardOwner());
    testKey(&editor, 'd', .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
}

test "TUI focus: the search field takes clipboard and word-delete chords" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    editor.clipboard_set_fn = TestClipboard.set;
    editor.clipboard_get_fn = TestClipboard.get;
    editor.search_visible = true;
    const doc = editor.activeDoc();
    try doc.loadText("document text");
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    testFrame(win, &editor);

    // Click the query row, type, paste, delete a word: all in the field
    testClick(&editor, 10, search_band.?.y);
    try t.expectEqual(Editor.KeyboardOwner.search, editor.keyboardOwner());
    testType(&editor, "foo ");
    editor.setClipboard("bar\nbaz");
    testKey(&editor, 'v', .{ .ctrl = true });
    try t.expectEqualStrings("foo bar", editor.search.query());
    testKey(&editor, Key.backspace, .{ .ctrl = true });
    try t.expectEqualStrings("foo ", editor.search.query());
    // Replace confirmation: Ctrl+A is not "All"
    editor.search.confirm_armed = true;
    testKey(&editor, 'a', .{ .ctrl = true });
    try t.expect(editor.search.confirm_armed);
    testKey(&editor, 'c', .{});
    try t.expect(!editor.search.confirm_armed);
    try t.expectEqualStrings("document text", doc.buffer.slice(0, doc.buffer.byteLen()));

    // Clicking the code gives the keyboard back to the editor
    testFrame(win, &editor);
    const rect = pane_rects[0];
    testClick(&editor, rect.x + rect.w - 2, rect.y);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    testType(&editor, "!");
    try t.expectEqualStrings("document text!", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "TUI prompts ignore Ctrl/Alt chords; letters still answer them" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    const doc = editor.activeDoc();
    try doc.loadText("x");
    doc.dirty = true;

    editor.setMode(.confirm_quit);
    testKey(&editor, 'd', .{ .ctrl = true });
    testKey(&editor, 's', .{ .alt = true });
    try t.expectEqual(Editor.Mode.confirm_quit, editor.mode);
    try t.expect(editor.running);
    testKey(&editor, 'c', .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);

    try t.expect(!editor.requestCloseDoc(0));
    try t.expectEqual(Editor.Mode.confirm_close, editor.mode);
    testKey(&editor, 's', .{ .ctrl = true });
    testKey(&editor, 'd', .{ .ctrl = true });
    try t.expectEqual(Editor.Mode.confirm_close, editor.mode);
    try t.expectEqual(@as(usize, 1), editor.documents.items.len);
    testKey(&editor, Key.escape, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);

    editor.setMode(.tool_panel);
    testKey(&editor, 'd', .{ .ctrl = true });
    try t.expectEqual(Editor.Mode.tool_panel, editor.mode);
    testKey(&editor, Key.escape, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
}

test "TUI delete prompt: only y deletes; Enter cancels; Ctrl+Y is ignored" {
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
    try t.expect(editor.takeKeyboardFocus(.filetree));

    testKey(&editor, 'd', .{});
    try t.expectEqual(Editor.Mode.filetree_prompt, editor.mode);
    testKey(&editor, Key.enter, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    _ = try tmp.dir.statFile(t.io, "a.txt", .{});

    testKey(&editor, 'd', .{});
    testKey(&editor, 'y', .{ .ctrl = true });
    try t.expectEqual(Editor.Mode.filetree_prompt, editor.mode);
    testKey(&editor, 'n', .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    _ = try tmp.dir.statFile(t.io, "a.txt", .{});

    testKey(&editor, 'd', .{});
    testKey(&editor, 'y', .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "a.txt", .{}));
}

// ---------------------------------------------------------------------------
// Key names (C5), sticky column (B2), added cursors (C7)
// ---------------------------------------------------------------------------

test "TUI key names: Ctrl+Space, Insert, digits and Shift chords use the keybind vocabulary" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("ctrl+space", keyToStr(.{ .codepoint = ' ', .text = " ", .mods = .{ .ctrl = true } }, &buf));
    try t.expectEqualStrings("ctrl+space", keyToStr(.{ .codepoint = '@', .mods = .{ .ctrl = true } }, &buf));
    try t.expectEqualStrings("shift+insert", keyToStr(.{ .codepoint = Key.insert, .mods = .{ .shift = true } }, &buf));
    try t.expectEqualStrings("ctrl+shift+k", keyToStr(.{ .codepoint = 'K', .mods = .{ .ctrl = true, .shift = true } }, &buf));
    try t.expectEqualStrings("ctrl+1", keyToStr(.{ .codepoint = '1', .mods = .{ .ctrl = true } }, &buf));
    try t.expectEqualStrings("alt+backslash", keyToStr(.{ .codepoint = '\\', .mods = .{ .alt = true } }, &buf));

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    try t.expectEqualStrings("lsp_completion", editor.lookupKeybind(keyToStr(.{ .codepoint = '@', .mods = .{ .ctrl = true } }, &buf)).?);
    const doc = editor.activeDoc();
    try doc.loadText("one\ntwo");
    // Ctrl+Shift+K is its own chord: no fallback to Ctrl+K's delete_line
    testKey(&editor, 'k', .{ .ctrl = true, .shift = true });
    try t.expectEqualStrings("one\ntwo", doc.buffer.slice(0, doc.buffer.byteLen()));
    // Ctrl+Shift+Z redoes (the fallback used to undo)
    testType(&editor, "!");
    testKey(&editor, 'z', .{ .ctrl = true });
    try t.expectEqualStrings("one\ntwo", doc.buffer.slice(0, doc.buffer.byteLen()));
    testKey(&editor, 'z', .{ .ctrl = true, .shift = true });
    try t.expectEqualStrings("!one\ntwo", doc.buffer.slice(0, doc.buffer.byteLen()));
    // A legacy terminal's bare Ctrl+\ byte is a chord, never typed text
    dispatchKey(&editor, .{ .codepoint = 0x1c, .text = "\x1c" });
    try t.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, doc.buffer.slice(0, doc.buffer.byteLen()), 0x1c));
}

test "TUI sticky column: Up/Down keep their cell column through short wrapped lines" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    editor.word_wrap = true;
    editor.text_width = 40;
    vertical_motion = .{};
    const doc = editor.activeDoc();
    try doc.loadText("abcdef\nx\n\tabc\nabcdefgh");
    doc.cursors.primary().offset = 5; // column 5 of "abcdef"
    testKey(&editor, Key.down, .{});
    try t.expectEqual(doc.buffer.posToOffset(1, 1), doc.cursors.primary().offset); // end of "x"
    testKey(&editor, Key.down, .{});
    // "\tabc": cell 5 is 'b' (the tab spans cells 0-3)
    try t.expectEqual(doc.buffer.posToOffset(2, 2), doc.cursors.primary().offset);
    testKey(&editor, Key.down, .{});
    try t.expectEqual(doc.buffer.posToOffset(3, 5), doc.cursors.primary().offset);
    testKey(&editor, Key.up, .{});
    testKey(&editor, Key.up, .{});
    testKey(&editor, Key.up, .{});
    try t.expectEqual(@as(usize, 5), doc.cursors.primary().offset);
    // A horizontal move starts a new run from the new column
    testKey(&editor, Key.left, .{});
    testKey(&editor, Key.down, .{});
    testKey(&editor, Key.down, .{});
    try t.expectEqual(doc.buffer.posToOffset(2, 1), doc.cursors.primary().offset); // cell 4: after the tab
}

test "TUI added cursors carry their own preferred column" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    editor.word_wrap = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    const doc = editor.activeDoc();
    try doc.loadText("abcdef\nabcdef\nabcdef");
    testFrame(win, &editor);
    const rect = pane_rects[0];
    const x0 = rect.x + lineNumberWidth(doc.lineCount(), editor.gutter_min_digits) + 1;
    handleMouse(&editor, .{ .row = @intCast(rect.y + 1), .col = @intCast(x0 + 4), .button = .left, .type = .press, .mods = .{ .alt = true } });
    handleMouse(&editor, .{ .row = @intCast(rect.y + 1), .col = @intCast(x0 + 4), .button = .left, .type = .release, .mods = .{ .alt = true } });
    try t.expectEqual(@as(usize, 2), doc.cursors.count());
    try t.expectEqual(@as(usize, 4), doc.cursors.cursors.items[1].preferred_col);
    // Wrap-mode add-cursor below keeps the column too
    editor.word_wrap = true;
    doc.cursors.clearSecondary();
    doc.cursors.primary().offset = 3;
    tuiAddCursorVisual(&editor, .down);
    try t.expectEqual(@as(usize, 2), doc.cursors.count());
    try t.expectEqual(@as(usize, 3), doc.cursors.cursors.items[1].preferred_col);
    try t.expectEqual(doc.buffer.posToOffset(1, 3), doc.cursors.cursors.items[1].offset);
}

// ---------------------------------------------------------------------------
// Quick open, palette, Open prompt (Design 2, E13)
// ---------------------------------------------------------------------------

test "TUI quick open draws the scrolled window and never writes the selection" {
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
    editor.filetree_visible = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);

    editor.finderOpen();
    for (0..9) |_| testKey(&editor, Key.down, .{});
    try t.expectEqual(@as(usize, 9), editor.finder_selected);
    testFrame(win, &editor);
    drawFileFinder(win, &editor, 100, 30);
    try t.expectEqual(@as(usize, 9), editor.finder_selected);
    // 8 rows from match 2; the selection is the last one drawn
    const finder_x: u16 = (100 - 70) / 2;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("f02.txt", testCells(&screen, finder_x + 1, 30 - 11 + 1, 7, &buf));
    try t.expectEqualStrings("f09.txt", testCells(&screen, finder_x + 1, 30 - 11 + 8, 7, &buf));
    try t.expect(screen.readCell(finder_x + 1, 30 - 11 + 8).?.style.reverse);
    testKey(&editor, Key.enter, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().display_name, "f09.txt"));
}

test "TUI palette scrolls past its visible rows" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    _ = editor.execAction("command_palette");
    try t.expectEqual(Editor.Mode.command_palette, editor.mode);
    const count = paletteMatchCount(&editor);
    try t.expect(count > 12);
    for (0..12) |_| testKey(&editor, Key.down, .{});
    try t.expectEqual(@as(usize, 12), editor.palette_selected);
    testFrame(win, &editor);
    drawCommandPalette(win, &editor, 100, 30);
    try t.expectEqual(@as(usize, 12), editor.palette_selected);
    // The last drawn row is the selection
    const names = try editor.commands.allNames();
    const palette_x: u16 = (100 - 60) / 2;
    var buf: [64]u8 = undefined;
    const want = names[12][0..@min(names[12].len, 20)];
    try t.expectEqualStrings(want, testCells(&screen, palette_x + 1, 10 + 10, @intCast(want.len), &buf));
    // Down stops at the last match
    for (0..count + 5) |_| testKey(&editor, Key.down, .{});
    try t.expectEqual(count - 1, editor.palette_selected);
    testKey(&editor, Key.escape, .{});
}

test "TUI Open prompt reports why a file did not open" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    _ = editor.execAction("file_open");
    try t.expectEqual(Editor.Mode.file_open, editor.mode);
    testType(&editor, "zide-no-such-dir/missing.txt");
    testKey(&editor, Key.enter, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.startsWith(u8, editor.status_message, "Open failed ("));
    try t.expect(std.mem.endsWith(u8, editor.status_message, "zide-no-such-dir/missing.txt"));
}
