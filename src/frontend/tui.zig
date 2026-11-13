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
const theme_mod = @import("../core/theme.zig");
const TuiColor = theme_mod.TuiColor;
const status_mod = @import("../core/status_message.zig");
const syntax = @import("../core/syntax.zig");
const brackets = @import("../core/brackets.zig");
const review_reader = @import("../core/review_reader.zig");
const lsp = @import("../core/lsp.zig");
const terminal_mod = @import("../core/terminal.zig");
const filetree_mod = @import("../core/filetree.zig");
const fileicons = @import("../core/fileicons.zig");
const FileTree = filetree_mod.FileTree;
const snippets_mod = @import("../core/snippets.zig");
const snippet_form_mod = @import("../core/snippet_form.zig");
const find_bar_mod = @import("../core/find_bar.zig");

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
/// asked for that), the document as one edit, the search field, the find
/// bar's box, the snippet form's active field or a single-line prompt as
/// typed text (its first line). Pickers and confirmation prompts never take
/// a paste — a pasted letter must not answer them.
fn applyPaste(editor: *Editor, text: []const u8) void {
    if (text.len == 0) return;
    editor.validateSnippetState();
    defer editor.validateSnippetState();
    switch (editor.mode) {
        .normal => switch (editor.keyboardOwner()) {
            .terminal => if (activeTerminal(editor)) |term| term.paste(text),
            .terminal_panel => if (editor.terminalPanelTerminal()) |term| term.paste(text),
            .editor => pasteIntoDocument(editor, text),
            .search => typeLine(editor, firstLine(text)),
            .find_bar => findBarInsert(editor, firstLine(text)),
            .filetree, .snippets => {},
        },
        .find_replace, .file_open, .folder_open, .save_as, .command_palette, .picker, .goto_line, .file_finder, .symbol_rename, .snippet_form => typeLine(editor, firstLine(text)),
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
    // A read-only tab (the review reader) refuses the edit: say that, not
    // "out of memory".
    if (doc.readonly) {
        editor.setStatus(.warning, if (doc.reader != null) "Read-only review view — Enter opens the real file" else "Read-only document");
        return;
    }
    const eol = doc.lineEnding();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(editor.allocator);
    out.ensureTotalCapacity(editor.allocator, text.len) catch {
        editor.setStatus(.err, "Paste failed: out of memory");
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
            editor.setStatus(.err, "Paste failed: out of memory");
            return;
        };
    }
    doc.insertAtAllCursors(out.items) catch {
        editor.setStatus(.err, "Paste failed: out of memory");
        return;
    };
    scroll_pinned = false;
    editor.dismissStatus();
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
            // The snippet form is a band inside drawEditor, which puts the
            // caret at the end of its active field; with no room for the
            // band there is no caret either.
            .snippet_form => if (snippet_form_band == null) win.hideCursor(),
            .snippet_delete_confirm => {
                // vaxis keeps the slice until the render: frame storage,
                // not this block's buffer.
                var prompt_buf: [256]u8 = undefined;
                drawOverlay(win, editor, frameArenaDupe(editor.snippetDeletePrompt(&prompt_buf)), "", width, height);
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
            // cursor, the find bar's box, none while a side panel owns the
            // keys (the tree and the search panel draw their own selection /
            // field marker).
            .normal => switch (editor.keyboardOwner()) {
                .editor, .terminal => positionCursor(win, editor, width, height),
                .terminal_panel => positionTerminalPanelCursor(win, editor),
                .find_bar => positionFindBarCursor(win, editor),
                .filetree, .snippets, .search => win.hideCursor(),
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
            .terminal_panel => return handleTerminalPanelKey(editor, key),
            .filetree => return handleFiletreeKey(editor, key),
            .snippets => return handleSnippetsKey(editor, key),
            .search => return handleSearchKey(editor, key),
            .find_bar => return handleFindBarKey(editor, key),
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
        .snippet_form => handleSnippetFormKey(editor, key),
        .snippet_delete_confirm => handleSnippetDeleteKey(editor, key),
        .filetree_prompt => handleFiletreePromptKey(editor, key),
    }
}

/// "Delete snippet … ? [Y]es / any other key cancels": only a plain y
/// deletes (a chord is never an answer), anything else cancels — the
/// tree's delete prompt's rule.
fn handleSnippetDeleteKey(editor: *Editor, key: Key) void {
    if (key.isModifier() or hasCommandMod(key)) return;
    switch (key.codepoint) {
        'y', 'Y' => editor.applySnippetDelete(),
        else => editor.cancelSnippetDelete(),
    }
}

/// Keys while the snippet form band is up (Save / Edit / Copy a snippet):
/// Escape cancels, Enter saves, Tab / Shift+Tab and Down / Up move between
/// the fields, Backspace edits, anything typed lands in the active field.
/// The band is drawn by drawSnippetForm; a click on a field row picks it.
fn handleSnippetFormKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;
    const form = &editor.snippet_form;
    switch (key.codepoint) {
        Key.escape => editor.cancelSnippetForm(),
        Key.enter => _ = editor.submitSnippetForm(),
        Key.tab, Key.down => form.cycle(!(key.mods.shift and key.codepoint == Key.tab), false),
        Key.up => form.cycle(false, false),
        Key.backspace => form.backspace(),
        else => {
            if (hasCommandMod(key)) return;
            if (key.text) |text| {
                form.append(text);
            } else if (isTextCodepoint(key.codepoint)) {
                var bytes: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(key.codepoint, &bytes) catch return;
                form.append(bytes[0..n]);
            }
        },
    }
}

/// A chord modifier (Ctrl, Alt, Super) is held: such a key is never a
/// letter answering a prompt.
fn hasCommandMod(key: Key) bool {
    return key.mods.ctrl or key.mods.alt or key.mods.super;
}

/// Handle key events when focused on a terminal pane.
fn handleTerminalKey(editor: *Editor, key: Key) void {
    handleTerminalKeyFor(editor, key, activeTerminal(editor));
}

/// A key for `term` — the focused terminal pane's shell or the terminal
/// panel's: the management chords stay with ZIDE, the rest is typed in.
fn handleTerminalKeyFor(editor: *Editor, key: Key, maybe_term: ?*terminal_mod.Terminal) void {
    // Modifier keys alone send nothing (their private-use codes used to be
    // dropped by accident; now explicitly).
    if (key.isModifier()) return;
    // ctrl+backtick (`) toggles back to editor (Ctrl+Shift+` is the
    // terminal panel's chord, let through below)
    if (key.codepoint == '`' and key.mods.ctrl and !key.mods.alt and !key.mods.shift) {
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

    const term = maybe_term orelse return;
    // The shell has ended: the next key closes the pane instead of being
    // typed into nothing (the status bar says so).
    if (term.exited) {
        _ = editor.execAction("close_terminal");
        return;
    }
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

/// The find bar's row from the last draw (absolute screen cells): where its
/// box and buttons are — clicks and the caret are placed through it. Null
/// when the bar is not drawn.
const FindBarBand = struct {
    const Span = struct {
        x: u16 = 0,
        w: u16 = 0,

        fn has(self: Span, col: u16) bool {
            return col >= self.x and col < self.x + self.w;
        }
    };

    x: u16,
    y: u16,
    w: u16,
    box: Span = .{},
    /// In `find_bar_toggles` order.
    toggles: [find_bar_toggles.len]Span = @splat(.{}),
    prev: Span = .{},
    next: Span = .{},
    close: Span = .{},
};
var find_bar_band: ?FindBarBand = null;
/// A left press landed in the find bar's box: the drag after it selects there.
var find_bar_drag: bool = false;
/// The snippet form band (full width, above the search panel and the
/// status bar) with the rows it showed, from the last draw; null when
/// hidden. Clicks pick a field through it.
const SnippetFormBand = struct { y: u16, h: u16, rows: SnippetFormRows };
var snippet_form_band: ?SnippetFormBand = null;
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

/// Snippets band geometry from the last draw (absolute screen coords):
/// `preview_y` is the band row its preview starts on (`h` when there is
/// none). Null when the panel isn't shown.
const SnippetsBand = struct { x: u16, y: u16, w: u16, h: u16, preview_y: u16 };
var snippets_band: ?SnippetsBand = null;
/// Rows the Snippets list showed last frame (the PageUp/PageDown step).
var snippets_rows_visible: usize = 1;
/// The Snippets preview: rows scrolled off its top, how many more it
/// could not show (the scroll's limit), its row count (the Shift+PageUp/
/// PageDown step) and the definition it showed (a new one starts at its
/// top).
var snippets_preview_scroll: usize = 0;
var snippets_preview_overflow: usize = 0;
var snippets_preview_rows: usize = 1;
var snippets_preview_def: ?u32 = null;

/// The terminal panel band from the last draw (absolute screen coords)
/// and where its shell's grid starts inside it (`grid_x`/`grid_y`, past
/// the header row and the separator column). Null when hidden.
const TerminalPanelBand = struct { x: u16, y: u16, w: u16, h: u16, grid_x: u16, grid_y: u16, grid_w: u16, grid_h: u16 };
var terminal_panel_band: ?TerminalPanelBand = null;

/// Draw the full editor screen.
fn drawEditor(win: Window, editor: *Editor, width: u16, height: u16) void {
    pane_rect_count = 0;
    filetree_band = null;
    snippets_band = null;
    terminal_panel_band = null;
    search_band = null;
    find_bar_band = null;
    snippet_form_band = null;
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
    // The snippet form band, above the search panel and the status bar:
    // eight rows, never more than half of what is left for the panes (one
    // at least: the form takes the typing, which must not land unseen).
    const form_room = height -| tab_bar_height -| status_height -| search_h;
    const form_h: u16 = if (editor.mode == .snippet_form) @min(8, @max(1, form_room / 2), form_room) else 0;
    const content_height = form_room -| form_h;

    // Tab bar (global, spans full width)
    if (tab_bar_height > 0) {
        const tab_win = win.child(.{ .y_off = 0, .height = 1, .width = width });
        drawTabBar(tab_win, editor, width);
    }

    // Side bands — the file tree and the Snippets panel — dock left or
    // right of the pane area, below the tab bar; on a shared side the
    // tree is the outer one. The tree is skipped (focus released) when
    // the terminal is too narrow for it.
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
    const tree_left: u16 = if (tree_w > 0 and editor.filetree_side == .left) tree_w else 0;
    // The Snippets band leaves the panes 40 columns beside both bands;
    // with fewer than 16 columns for it, it hides itself and says so
    // (Ctrl+Alt+B must not cycle a panel nobody can see).
    var snip_w: u16 = 0;
    if (editor.snippets_visible) {
        snip_w = @min(editor.tui_snippets_width, (width -| tree_w) -| 40);
        if (snip_w < 16) {
            snip_w = 0;
            if (editor.keyboardOwner() == .snippets) _ = editor.takeKeyboardFocus(.pane);
            editor.snippets_visible = false;
            editor.snippets_focused = false;
            editor.setStatus(.warning, "Snippets panel: no room beside the editor \u{2014} widen the terminal, then Ctrl+Alt+B");
        } else {
            const side = editor.snippetsSide();
            const band_x: u16 = if (side == .left) tree_left else width - (tree_w - tree_left) - snip_w;
            const band_win = win.child(.{
                .x_off = @intCast(band_x),
                .y_off = @intCast(tab_bar_height),
                .width = snip_w,
                .height = content_height,
            });
            const preview_y = drawSnippetsPanel(band_win, editor, snip_w, content_height, side);
            snippets_band = .{ .x = band_x, .y = tab_bar_height, .w = snip_w, .h = content_height, .preview_y = preview_y };
        }
    }
    const snip_left: u16 = if (snip_w > 0 and editor.snippetsSide() == .left) snip_w else 0;
    var content_x: u16 = tree_left + snip_left;
    var content_width = (width -| tree_w) -| snip_w;
    var panes_height = content_height;

    // The terminal panel: a third band inward of the tree and the Snippets
    // panel on a side (full height, like a chat column), or a strip at the
    // bottom of the pane area between the side bands. A side band keeps
    // the panes 40 columns, the bottom strip keeps them half the rows; with
    // less than its minimum it hides itself and says so.
    if (editor.terminal_panel_visible and editor.terminal_panel != null) {
        const lim = Editor.terminal_panel_limits;
        const side = editor.terminal_panel_side;
        if (side == .bottom) {
            const tp_h: u16 = @min(editor.tui_terminal_panel_height, content_height / 2);
            if (tp_h < lim.tui_min_height) {
                terminalPanelNoRoom(editor);
            } else {
                const band_y = tab_bar_height + content_height - tp_h;
                const band_win = win.child(.{
                    .x_off = @intCast(content_x),
                    .y_off = @intCast(band_y),
                    .width = content_width,
                    .height = tp_h,
                });
                terminal_panel_band = drawTerminalPanel(band_win, editor, content_x, band_y, content_width, tp_h, .bottom);
                panes_height = content_height - tp_h;
            }
        } else {
            const tp_w: u16 = @min(editor.tui_terminal_panel_width, content_width -| 40);
            if (tp_w < lim.tui_min_width) {
                terminalPanelNoRoom(editor);
            } else {
                const band_x: u16 = if (side == .left) content_x else content_x + content_width - tp_w;
                const band_win = win.child(.{
                    .x_off = @intCast(band_x),
                    .y_off = @intCast(tab_bar_height),
                    .width = tp_w,
                    .height = content_height,
                });
                terminal_panel_band = drawTerminalPanel(band_win, editor, band_x, tab_bar_height, tp_w, content_height, side);
                if (side == .left) content_x += tp_w;
                content_width -= tp_w;
            }
        }
    }

    // The find bar: one row under the panes, as wide as they are (a bottom
    // terminal panel sits below it). Without a row and twelve columns to
    // spare it is not drawn, and its box lets go of the keyboard — typing
    // must not land unseen.
    const find_h: u16 = if (editor.find_bar.visible and panes_height >= 2 and content_width >= find_bar_min_width) 1 else 0;
    if (find_h == 0 and editor.keyboardOwner() == .find_bar) _ = editor.takeKeyboardFocus(.pane);
    panes_height -= find_h;

    // Render pane tree into the content area
    const content_win = win.child(.{
        .x_off = @intCast(content_x),
        .y_off = @intCast(tab_bar_height),
        .height = panes_height,
        .width = content_width,
    });
    // NOTE: screen_x comes before screen_y — the tab bar offsets Y only.
    // (These were swapped once: with 2+ tabs open every pane rect shifted
    // one row up / one col right, drawing the cursor next to the wrong line
    // and skewing mouse hit-testing.)
    renderPaneLayout(content_win, editor, 0, content_x, tab_bar_height, content_width, panes_height);

    // Find bar (after the panes: its count reads the selection they showed)
    if (find_h > 0) {
        const bar_y = tab_bar_height + panes_height;
        const bar_win = win.child(.{
            .x_off = @intCast(content_x),
            .y_off = @intCast(bar_y),
            .height = 1,
            .width = content_width,
        });
        find_bar_band = drawFindBar(bar_win, editor, content_x, bar_y, content_width);
    }

    // Snippet form band (full width, above the search panel)
    if (form_h > 0) {
        const form_y = tab_bar_height + content_height;
        const fw = win.child(.{
            .y_off = @intCast(form_y),
            .height = form_h,
            .width = width,
        });
        const rows = drawSnippetForm(fw, editor, width, form_h);
        snippet_form_band = .{ .y = form_y, .h = form_h, .rows = rows };
    }

    // Docked search panel (full width, above the status bar)
    if (search_h > 0) {
        const search_y = tab_bar_height + content_height + form_h;
        const sw = win.child(.{
            .y_off = @intCast(search_y),
            .height = search_h,
            .width = width,
        });
        drawSearchPanel(sw, editor, width, search_h);
        search_band = .{ .y = search_y, .h = search_h };
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
        editor.setStatus(.err, if (err == error.BinaryFile)
            "Cannot open: binary file"
        else
            "Open failed");
    };
}

/// Draw the Snippets band, the GUI panel's terminal twin: a header (with
/// the filter typed into the panel), one row per group or item of the
/// core model's rows (snippet_panel.zig; an empty list shows its hint)
/// with a │ guide under each open group, then the preview of the
/// selected item — its code wrapped to the band with the blanks
/// highlighted, how to fill it in, and its notes word-wrapped. What the
/// preview cannot show scrolls (Shift+Up/Down, the wheel). Returns the
/// band row the preview starts on (`h` when the band is too short for
/// one).
fn drawSnippetsPanel(win: Window, editor: *Editor, w: u16, h: u16, side: Editor.FiletreeSide) u16 {
    if (w < 2 or h < 2) return h;
    const theme = editor.tui_theme;
    const bg = toVaxis(theme.text_bg);
    const bg_style: Style = .{ .fg = toVaxis(theme.text_fg), .bg = bg };
    const dim_style: Style = .{ .fg = toVaxis(theme.gutter_text), .bg = bg };
    const line_style: Style = .{ .fg = toVaxis(theme.gutter_separator), .bg = bg };
    win.fill(.{ .style = bg_style });
    const focused = editor.keyboardOwner() == .snippets;

    // Separator column on the edge facing the editor.
    const sep_x: u16 = if (side == .left) w - 1 else 0;
    for (0..h) |r| {
        win.writeCell(sep_x, @intCast(r), .{
            .char = .{ .grapheme = "\u{2502}", .width = 1 }, // │
            .style = line_style,
        });
    }
    const text_x: u16 = if (side == .left) 0 else 1;
    const text_w: u16 = w - 1;

    const panel = editor.syncSnippetPanel();
    const rows = panel.rows.items;
    const defs = editor.snippets.items.items;

    // Header: "Snippets — <language>", bright while the panel has the
    // keys; a filter follows as "  /<text>" (cut at the band's edge too).
    const header_style: Style = .{
        .fg = toVaxis(if (focused) theme.overlay_accent else theme.gutter_text),
        .bg = bg,
        .bold = focused,
    };
    // Room for the longest language label and filter (64 bytes each).
    var title_buf: [160]u8 = undefined;
    const title = (if (panel.filterActive())
        std.fmt.bufPrint(&title_buf, "Snippets \u{2014} {s}  /{s}", .{ panel.languageLabel(), panel.filterText() })
    else
        std.fmt.bufPrint(&title_buf, "Snippets \u{2014} {s}", .{panel.languageLabel()})) catch "Snippets";
    _ = writeStr(win, text_x, 0, truncToWidth(title, text_w), header_style);

    // The rows and the preview share the band under the header: the
    // preview keeps at least 40% of it and takes what a short list leaves
    // free (as the GUI; an empty list shows a hint, so keep it a few rows).
    const body_h: usize = h - 1;
    const list_rows: usize = (if (rows.len == 0) 6 else rows.len) + 1;
    var preview_h: usize = @max(body_h * 2 / 5, body_h -| list_rows);
    if (body_h - preview_h < 3) preview_h = body_h -| 3;
    if (preview_h < 4) preview_h = 0;
    const rows_h: usize = body_h - preview_h;
    snippets_rows_visible = @max(1, rows_h);

    // Keep the selection in view (keyboard moves set the flag), then clamp
    // the scroll when rows disappeared (a group closed, a reload).
    if (panel.scroll_to_selected) {
        panel.scroll_to_selected = false;
        if (panel.selected < panel.scroll) {
            panel.scroll = panel.selected;
        } else if (rows_h > 0 and panel.selected >= panel.scroll + rows_h) {
            panel.scroll = panel.selected + 1 - rows_h;
        }
    }
    if (panel.scroll > 0 and panel.scroll + rows_h > rows.len) panel.scroll = rows.len -| rows_h;

    // --- Rows: groups (▾/▸, name, count) and their items (│ guide, name,
    //     Tab trigger right-aligned) ---
    const sel_style: Style = .{ .fg = toVaxis(theme.selection_fg), .bg = toVaxis(theme.selection_bg) };
    var sel_dim_style = bg_style;
    sel_dim_style.bg = toVaxis(theme.overlay_selection_bg);
    const any_language = panel.anyLanguage();
    if (rows.len == 0) {
        var hint: RowSink = .{ .win = win, .x = text_x, .y = 1, .capacity = rows_h };
        drawWrappedRows(&hint, text_w, panel.emptyHint(), dim_style);
    }
    var screen_row: u16 = 1;
    var r = panel.scroll;
    while (r < rows.len and screen_row < 1 + rows_h) : ({
        r += 1;
        screen_row += 1;
    }) {
        const row = rows[r];
        const selected = r == panel.selected;
        // A dimmed bar when the panel doesn't own the keyboard.
        const style = if (!selected) bg_style else if (focused) sel_style else sel_dim_style;
        if (selected) {
            for (0..text_w) |ci| {
                win.writeCell(@intCast(text_x + ci), screen_row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = style,
                });
            }
        }
        // Dim text (counts, triggers, a group's language) keeps the row's
        // background and, on the selection bar, its colors.
        var row_dim = if (selected) style else dim_style;
        row_dim.bg = style.bg;
        switch (row.kind) {
            .group => {
                const group = panel.groups.items[row.group];
                var count_buf: [16]u8 = undefined;
                const count = std.fmt.bufPrint(&count_buf, "{d}", .{group.count}) catch "";
                const count_x: u16 = (text_x + text_w) -| @as(u16, @intCast(count.len));
                _ = writeStr(win, count_x, screen_row, count, row_dim);
                var x = writeStr(win, text_x, screen_row, if (group.expanded) "\u{25be} " else "\u{25b8} ", style); // ▾ ▸
                if (any_language) {
                    x = writeStr(win, x, screen_row, truncToWidth(group.language, (count_x -| 1) -| x), row_dim);
                    x = writeStr(win, x, screen_row, " ", style);
                }
                _ = writeStr(win, x, screen_row, truncToWidth(group.name, (count_x -| 1) -| x), style);
            },
            .item => {
                // Guide under the group's chevron, as the tree's folders have.
                var guide_style = line_style;
                guide_style.bg = style.bg;
                win.writeCell(text_x, screen_row, .{
                    .char = .{ .grapheme = "\u{2502}", .width = 1 }, // │
                    .style = guide_style,
                });
                if (row.def >= defs.len) continue;
                const def = &defs[row.def];
                const name_x: u16 = text_x + 3;
                var name_right: u16 = text_x + text_w;
                if (def.hasTrigger()) {
                    // Only beside a name that keeps a few letters.
                    const trigger_cols: u16 = @intCast(@min(advanceCols(def.prefix, 0, 1), 64));
                    const trigger_x = (text_x + text_w) -| trigger_cols;
                    if (trigger_x > name_x + 5) {
                        _ = writeStr(win, trigger_x, screen_row, def.prefix, row_dim);
                        name_right = trigger_x - 1;
                    }
                }
                _ = writeStr(win, name_x, screen_row, truncToWidth(def.description, name_right -| name_x), style);
            },
        }
    }

    // --- Preview of the selected item, under a divider ---
    if (preview_h == 0) {
        snippets_preview_overflow = 0;
        snippets_preview_rows = 1;
        return h;
    }
    const pv_y: u16 = @intCast(1 + rows_h);
    for (0..text_w) |ci| {
        win.writeCell(@intCast(text_x + ci), pv_y, .{
            .char = .{ .grapheme = "\u{2500}", .width = 1 }, // ─
            .style = line_style,
        });
    }
    const content_y = pv_y + 1;
    const capacity: usize = preview_h - 1;
    snippets_preview_rows = capacity;
    const preview_def = panel.previewDef(null);
    if (!std.meta.eql(preview_def, snippets_preview_def)) snippets_preview_scroll = 0;
    snippets_preview_def = preview_def;
    const def: ?*const snippets_mod.Definition = if (preview_def) |di| (if (di < defs.len) &defs[di] else null) else null;
    const d = def orelse {
        snippets_preview_overflow = 0;
        var sink: RowSink = .{ .win = win, .x = text_x, .y = content_y, .capacity = capacity };
        drawWrappedRows(&sink, text_w, "Select a snippet to see the code it inserts", dim_style);
        return pv_y;
    };
    const doc = &editor.documents.items[editor.windowDocIdx(0)];
    const styles: PreviewStyles = .{
        .text = bg_style,
        .dim = dim_style,
        .code = .{ .fg = toVaxis(theme.text_fg), .bg = toVaxis(theme.overlay_bg) },
        .blank = sel_style,
        .tab = tabStop(editor, doc),
    };
    // Measure (a sink that draws nothing), clamp the scroll, then draw;
    // when rows are left over, the last row says how to reach them.
    var measure: RowSink = .{ .win = win, .x = text_x, .y = content_y, .capacity = 0 };
    drawSnippetPreview(&measure, d, text_w, styles);
    const total = measure.index;
    const content_cap = if (total <= capacity) capacity else capacity - 1;
    snippets_preview_overflow = total -| content_cap;
    if (snippets_preview_scroll > snippets_preview_overflow) snippets_preview_scroll = snippets_preview_overflow;
    var sink: RowSink = .{ .win = win, .x = text_x, .y = content_y, .capacity = content_cap, .skip = snippets_preview_scroll };
    drawSnippetPreview(&sink, d, text_w, styles);
    if (snippets_preview_scroll < snippets_preview_overflow) {
        const marker_y: u16 = content_y + @as(u16, @intCast(capacity - 1));
        _ = writeStr(win, text_x, marker_y, truncToWidth("\u{25bc} Shift+Down for more", text_w), dim_style); // ▼
    }
    return pv_y;
}

/// The rows of a wrapped block, drawn from `y` on, `capacity` of them at
/// most: the first `skip` rows (scrolled off) and any past the block are
/// counted — `index` ends as the block's row count — but not drawn. A
/// capacity of 0 only measures.
const RowSink = struct {
    win: Window,
    x: u16,
    y: u16,
    capacity: usize,
    skip: usize = 0,
    index: usize = 0,

    /// The screen row for the next row, or null when it is not drawn.
    fn next(self: *RowSink) ?u16 {
        const i = self.index;
        self.index += 1;
        if (i < self.skip or i - self.skip >= self.capacity) return null;
        return self.y + @as(u16, @intCast(i - self.skip));
    }
};

const PreviewStyles = struct {
    text: Style,
    dim: Style,
    code: Style,
    blank: Style,
    /// Tab stop for the code (the document's).
    tab: usize,
};

/// `text` word-wrapped to `width` cells through `sink`; its newlines
/// break rows too (an empty paragraph is a blank row).
fn drawWrappedRows(sink: *RowSink, width: u16, text: []const u8, style: Style) void {
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |par| {
        var pos: usize = 0;
        while (true) {
            const end = if (par.len == 0) 0 else wrapAdvanceRow(par, width, pos, 1);
            if (sink.next()) |y| {
                _ = writeStr(sink.win, sink.x, y, std.mem.trimEnd(u8, par[pos..end], " "), style);
            }
            if (end >= par.len) break;
            pos = end;
        }
    }
}

/// The preview's rows through `sink`: the code (each line wrapped to
/// `width` cells, a continued row two cells in, on the code background
/// with the blanks highlighted), a blank row, how to fill it in, then
/// the notes.
fn drawSnippetPreview(sink: *RowSink, d: *const snippets_mod.Definition, width: u16, styles: PreviewStyles) void {
    const text = d.template.text;
    const stops = d.template.stops;
    const has_blanks = for (stops) |stop| {
        if (stop.number != 0) break true;
    } else false;
    var start: usize = 0;
    while (start <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[start..end], "\r");
        var pos: usize = 0;
        var first = true;
        while (true) {
            const indent: u16 = if (first) 0 else 2;
            const row_end = if (line.len == 0) 0 else wrapAdvanceRow(line, width -| indent, pos, styles.tab);
            const last = row_end >= line.len;
            if (sink.next()) |y| {
                // The code box: the whole row on its background.
                for (0..width) |ci| {
                    sink.win.writeCell(@intCast(sink.x + ci), y, .{
                        .char = .{ .grapheme = " ", .width = 1 },
                        .style = styles.code,
                    });
                }
                drawPreviewCodeRow(sink.win, sink.x + indent, y, line, start, pos, row_end, last, stops, styles);
            }
            if (last) break;
            pos = row_end;
            first = false;
        }
        if (end >= text.len) break;
        start = end + 1;
    }
    const follows = has_blanks or d.hasTrigger() or d.notes.len > 0;
    if (!follows) return;
    _ = sink.next();
    if (has_blanks) drawWrappedRows(sink, width, "Tab jumps between the highlighted blanks", styles.dim);
    if (d.hasTrigger()) {
        var trigger_buf: [256]u8 = undefined;
        const trigger = std.fmt.bufPrint(&trigger_buf, "trigger: {s} + Tab", .{d.prefix}) catch "Type its trigger, then Tab";
        drawWrappedRows(sink, width, trigger, styles.dim);
    }
    if (d.notes.len > 0) {
        if (has_blanks or d.hasTrigger()) _ = sink.next();
        drawWrappedRows(sink, width, d.notes, styles.text);
    }
}

/// One visual row of a code line in the preview: `line[pos..row_end]`
/// from cell `x`, tabs expanded (the row's own cell columns), the
/// characters inside a blank in the blank style; an empty blank marks the
/// character at its offset, or one cell after the text at the line's end
/// (on its last row). `line_off` is the line's offset in the template.
fn drawPreviewCodeRow(win: Window, x: u16, y: u16, line: []const u8, line_off: usize, pos: usize, row_end: usize, last_row: bool, stops: anytype, styles: PreviewStyles) void {
    var cx = x;
    var col: usize = 0;
    var i = pos;
    var run_start = pos;
    var run_blank = blankAt(stops, line_off + pos);
    while (i < row_end) {
        const blank = blankAt(stops, line_off + i);
        if (blank != run_blank) {
            cx = drawCodeRun(win, cx, y, line[run_start..i], &col, styles.tab, if (run_blank) styles.blank else styles.code);
            run_start = i;
            run_blank = blank;
        }
        i += charAt(line, i).len;
    }
    cx = drawCodeRun(win, cx, y, line[run_start..row_end], &col, styles.tab, if (run_blank) styles.blank else styles.code);
    if (last_row and emptyBlankAt(stops, line_off + line.len)) _ = writeStr(win, cx, y, " ", styles.blank);
}

/// `text` from cell `x`, its tabs expanded to spaces from cell column
/// `col` (advanced past the text). Returns the cell after it.
fn drawCodeRun(win: Window, x: u16, y: u16, text: []const u8, col: *usize, tab: usize, style: Style) u16 {
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = charAt(text, i);
        const w = cellWidth(ch.cp, col.*, tab);
        if (ch.cp == '\t') {
            var k: usize = 0;
            while (k < w and n < buf.len) : (k += 1) {
                buf[n] = ' ';
                n += 1;
            }
        } else if (n + ch.len <= buf.len) {
            @memcpy(buf[n..][0..ch.len], text[i..][0..ch.len]);
            n += ch.len;
        }
        col.* += w;
        i += ch.len;
    }
    return writeStr(win, x, y, buf[0..n], style);
}

/// Whether template offset `off` is inside a blank — or is an empty
/// blank's spot, which marks the character there.
fn blankAt(stops: anytype, off: usize) bool {
    for (stops) |stop| {
        if (stop.number == 0) continue;
        if (stop.start == stop.end) {
            if (off == stop.start) return true;
        } else if (off >= stop.start and off < stop.end) return true;
    }
    return false;
}

/// Whether an empty blank sits at template offset `off`.
fn emptyBlankAt(stops: anytype, off: usize) bool {
    for (stops) |stop| {
        if (stop.number != 0 and stop.start == stop.end and stop.start == off) return true;
    }
    return false;
}

/// True when the mouse position is inside the Snippets band.
fn mouseOverSnippets(mouse: vaxis.Mouse) bool {
    const band = snippets_band orelse return false;
    const mc: i32 = @intCast(mouse.col);
    const mr: i32 = @intCast(mouse.row);
    return mc >= band.x and mc < @as(i32, band.x) + band.w and
        mr >= band.y and mr < @as(i32, band.y) + band.h;
}

/// Whether the mouse is over the terminal panel band (last draw).
fn mouseOverTerminalPanel(mouse: vaxis.Mouse) bool {
    const band = terminal_panel_band orelse return false;
    const mc: i32 = @intCast(mouse.col);
    const mr: i32 = @intCast(mouse.row);
    return mc >= band.x and mc < @as(i32, band.x) + band.w and
        mr >= band.y and mr < @as(i32, band.y) + band.h;
}

/// Left click inside the Snippets band: the panel takes the keyboard; a
/// group row opens or closes, an item row is selected (its preview shows)
/// and, when it was the highlighted row already, inserted — there is no
/// hover in a terminal. The header and the preview only focus the panel.
fn handleSnippetsClick(editor: *Editor, band: SnippetsBand, row_abs: u16) void {
    if (!editor.takeKeyboardFocus(.snippets)) return;
    if (row_abs <= band.y or row_abs >= band.y + band.preview_y) return;
    const panel = &editor.snippet_panel;
    const r = panel.scroll + (row_abs - band.y - 1);
    const row = panel.rowAt(r) orelse return;
    if (row.kind == .item and r != panel.selected) {
        panel.selected = r;
        return;
    }
    panel.selected = r;
    editor.activateSnippetRow(r);
}

/// Keys while the Snippets panel owns the keyboard (normal mode). Typed
/// text — letters, digits, Space — filters the rows and never reaches the
/// document (no letter is a command either: the panel is not modal);
/// Backspace edits the filter and Escape clears it, or with no filter
/// hands the keys back. F2 opens the selected snippet in the form — to
/// edit it when it is one of my-snippets.lua, else to copy it there — and
/// Delete asks before removing one of my-snippets.lua. Ctrl/Alt chords
/// and the other F-keys hit the keybind map and never reach the panel,
/// so the filter takes plain keys only. Shift+Up/Down and Shift+PageUp/
/// PageDown scroll the preview; the rest drives the list as in the GUI.
fn handleSnippetsKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;
    editor.dismissStatus();
    // Fresh rows first: the run loop handles every queued key before it
    // draws (and syncs) again, and a delete or a reload in between shifts
    // the registry — a stale row would point F2 or Delete at a neighbor.
    _ = editor.syncSnippetPanel();
    // F2 is the panel's before the keybind map, which takes every F-key,
    // bound or not.
    if (key.codepoint == Key.f2 and !hasCommandMod(key)) {
        editor.snippetPanelEdit();
        return;
    }
    if (tryKeybindCommand(editor, key)) return;
    // Super+letter is a desktop/OS chord, never a panel command
    if (key.mods.super) return;
    const panel = &editor.snippet_panel;
    const page: isize = @intCast(@max(1, snippets_rows_visible));
    const shift = key.mods.shift;
    switch (key.codepoint) {
        Key.escape => if (editor.snippetsFilterClear()) {
            _ = editor.syncSnippetPanel();
        } else {
            _ = editor.takeKeyboardFocus(.pane);
        },
        Key.up => if (shift) {
            snippets_preview_scroll -|= 1;
        } else panel.move(-1),
        Key.down => if (shift) {
            snippets_preview_scroll +|= 1;
        } else panel.move(1),
        Key.page_up => if (shift) {
            snippets_preview_scroll -|= snippets_preview_rows;
        } else panel.move(-page),
        Key.page_down => if (shift) {
            snippets_preview_scroll +|= snippets_preview_rows;
        } else panel.move(page),
        Key.home => panel.home(),
        Key.end => panel.end(),
        // Left and Right can close or open a group: the next key moves
        // over the rebuilt rows.
        Key.left => {
            panel.left(editor.allocator);
            _ = editor.syncSnippetPanel();
        },
        Key.right => {
            panel.right(editor.allocator);
            _ = editor.syncSnippetPanel();
        },
        // An item goes in at the caret and the editor gets the keys back,
        // so Tab walks the blanks; a group opens or closes.
        Key.enter => editor.activateSnippetRow(panel.selected),
        // Only a snippet of my-snippets.lua, after a [Y]es on the status
        // line (handleSnippetDeleteKey); others say so there.
        Key.delete => editor.snippetPanelDelete(),
        Key.backspace => {
            editor.snippetsFilterBackspace();
            _ = editor.syncSnippetPanel();
        },
        // Typed text narrows the rows; the selection follows the first
        // match, so Enter inserts it.
        else => {
            if (hasCommandMod(key)) return;
            if (key.text) |text| {
                editor.snippetsFilterAppend(text);
            } else if (isTextCodepoint(key.codepoint)) {
                var bytes: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(key.codepoint, &bytes) catch return;
                editor.snippetsFilterAppend(bytes[0..n]);
            } else return;
            _ = editor.syncSnippetPanel();
        },
    }
}

/// The terminal panel ran out of room: it hides itself (the shell keeps
/// running), lets go of the keyboard and says what to do.
fn terminalPanelNoRoom(editor: *Editor) void {
    if (editor.keyboardOwner() == .terminal_panel) _ = editor.takeKeyboardFocus(.pane);
    editor.terminal_panel_visible = false;
    editor.terminal_panel_focused = false;
    editor.setStatus(.warning, "Terminal panel: no room beside the editor — enlarge the window, then Ctrl+Shift+`");
}

/// Draw the terminal panel band: a header row ("Terminal", bright while
/// the panel has the keys, with the way out), a separator on the edge
/// facing the panes (a column for a side band; the header row itself at
/// the bottom), and the shell's grid in the rest, sized to fit. `x`/`y`
/// are the band's absolute screen position (for the mouse and the caret).
fn drawTerminalPanel(win: Window, editor: *Editor, x: u16, y: u16, w: u16, h: u16, side: Editor.DockEdge) ?TerminalPanelBand {
    if (w < 2 or h < 2) return null;
    const theme = editor.tui_theme;
    const bg = toVaxis(theme.text_bg);
    const bg_style: Style = .{ .fg = toVaxis(theme.text_fg), .bg = bg };
    const line_style: Style = .{ .fg = toVaxis(theme.gutter_separator), .bg = bg };
    win.fill(.{ .style = bg_style });
    const focused = editor.keyboardOwner() == .terminal_panel;

    // Separator column on the edge facing the panes (side bands only).
    var grid_x: u16 = 0;
    var grid_w: u16 = w;
    if (side != .bottom) {
        const sep_x: u16 = if (side == .left) w - 1 else 0;
        for (0..h) |r| {
            win.writeCell(sep_x, @intCast(r), .{
                .char = .{ .grapheme = "\u{2502}", .width = 1 }, // │
                .style = line_style,
            });
        }
        grid_x = if (side == .left) 0 else 1;
        grid_w = w - 1;
    } else {
        // The header row doubles as the separator under the panes.
        for (0..w) |c| {
            win.writeCell(@intCast(c), 0, .{
                .char = .{ .grapheme = "\u{2500}", .width = 1 }, // ─
                .style = line_style,
            });
        }
    }

    const header_style: Style = .{
        .fg = toVaxis(if (focused) theme.overlay_accent else theme.gutter_text),
        .bg = bg,
        .bold = focused,
    };
    const title: []const u8 = if (focused)
        " Terminal — Ctrl+` back to the editor "
    else
        " Terminal — Ctrl+Shift+` focuses ";
    _ = writeStr(win, grid_x, 0, truncToWidth(title, grid_w), header_style);

    const grid_y: u16 = 1;
    const grid_h: u16 = h - 1;
    if (editor.terminalPanelTerminal()) |term| {
        const grid_win = win.child(.{
            .x_off = @intCast(grid_x),
            .y_off = @intCast(grid_y),
            .width = grid_w,
            .height = grid_h,
        });
        drawTerminalInPane(grid_win, editor, term, grid_w, grid_h);
        term.mutex.lockUncancelable(term.io);
        const exited = term.exited;
        term.mutex.unlock(term.io);
        if (exited) {
            const msg = "[Process exited — press any key to close]";
            _ = writeStr(win, grid_x, grid_y + grid_h / 2, truncToWidth(msg, grid_w), .{ .fg = toVaxis(theme.gutter_text), .bg = bg });
        }
    }
    return .{ .x = x, .y = y, .w = w, .h = h, .grid_x = x + grid_x, .grid_y = y + grid_y, .grid_w = grid_w, .grid_h = grid_h };
}

/// Keys while the terminal panel owns the keyboard: the same as a terminal
/// pane's (handleTerminalKey), typed into the panel's shell.
fn handleTerminalPanelKey(editor: *Editor, key: Key) void {
    handleTerminalKeyFor(editor, key, editor.terminalPanelTerminal());
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
    // The find bar's matches, when its All button is on and this is the
    // document it searches. (Asked before any line is read: listing the
    // matches reads the whole buffer through its shared scratch slice.)
    const find_tints = editor.find_bar.paint(editor, doc).all;

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
        // Review reader rows: a background per kind, ghost and marker rows
        // in their own (dim) color and never tokenized.
        const row_kind: ?review_reader.LineKind = if (doc.reader) |info| info.kindAt(line_idx) else null;
        const row_plain = if (row_kind) |k| (k == .ghost or k == .marker) else false;
        const row_bg: Color = reviewTuiBg(editor, row_kind) orelse bg;
        const row_text_style: Style = .{
            .fg = if (row_kind) |k| switch (k) {
                .ghost => toVaxis(editor.tui_theme.review_ghost_fg),
                .marker => toVaxis(editor.tui_theme.review_marker_fg),
                else => text_style.fg,
            } else text_style.fg,
            .bg = row_bg,
            .dim = if (row_kind) |k| k == .ghost else false,
        };

        // Tokenize line for syntax highlighting
        var span_buf: [syntax.MAX_SPANS]syntax.HighlightSpan = undefined;
        var span_count: usize = 0;
        // syntax_highlighting=false: skip tokenizing → plain text render
        if (if (editor.syntax_highlighting and !row_plain) doc.language else null) |lang| {
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

            // Review reader: the row's background across the text area.
            if (row_kind != null and text_start_x < width and reviewTuiBg(editor, row_kind) != null) {
                win.child(.{ .x_off = @intCast(text_start_x), .y_off = @intCast(y), .width = text_width, .height = 1 }).fill(.{ .style = .{ .bg = row_bg } });
            }

            // Line number: only on first row of a logical line
            if (wrap_row == 0) {
                var num_buf: [16]u8 = undefined;
                const num_str = tuiGutterNumber(doc, line_idx, &num_buf);
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
                                    row_text_style;
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
                                    const syn_style = synTokenStyle(syn_theme, span_buf[si].token, row_text_style.fg, row_bg);
                                    if (pre_end > vis_start) col = writeText(text_win, col, span_text[0 .. pre_end - vis_start], syn_style, tab, seg.col0);
                                    if (post_start > pre_end) col = writeText(text_win, col, span_text[pre_end - vis_start .. post_start - vis_start], sel_style, tab, seg.col0);
                                    if (vis_end > post_start) col = writeText(text_win, col, span_text[post_start - vis_start ..], syn_style, tab, seg.col0);
                                } else {
                                    const syn_style = synTokenStyle(syn_theme, span_buf[si].token, row_text_style.fg, row_bg);
                                    col = writeText(text_win, col, span_text, syn_style, tab, seg.col0);
                                }
                            }
                            if (vis_end > seg_pos) seg_pos = vis_end;
                        }

                        // Trailing text after last span
                        if (seg_pos < segment.len) {
                            const trail = segment[seg_pos..];
                            const trail_style = if (has_sel and seg_pos < sel_end_local) sel_style else row_text_style;
                            _ = writeText(text_win, col, trail, trail_style, tab, seg.col0);
                        }
                    } else if (has_sel) {
                        // No syntax highlighting, but has selection
                        var col = writeText(text_win, 0, segment[0..sel_begin], row_text_style, tab, seg.col0);
                        col = writeText(text_win, col, segment[sel_begin..sel_end_local], sel_style, tab, seg.col0);
                        _ = writeText(text_win, col, segment[sel_end_local..], row_text_style, tab, seg.col0);
                    } else {
                        _ = writeText(text_win, 0, segment, row_text_style, tab, seg.col0);
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

            // Find matches: tinted cells, restyled post-hoc like the
            // secondary selections. The match the bar is on is the selection
            // and keeps its colors.
            if (find_tints) |list| {
                if (text_start_x < width) {
                    const line_start_offset = doc.buffer.posToOffset(line_idx, 0);
                    const seg_text = line[seg.start..seg.end];
                    const abs_seg_start = line_start_offset + seg.start;
                    const abs_seg_end = line_start_offset + seg.end;
                    for (list.within(abs_seg_start, abs_seg_end)) |m| {
                        if (sel) |cur| {
                            if (cur.start == m.start and cur.end == m.end) continue;
                        }
                        const lo = m.start -| abs_seg_start;
                        const hi = @min(m.end, abs_seg_end) - abs_seg_start;
                        const cx_start = advanceCols(seg_text[0..@min(lo, seg_text.len)], seg.col0, tab) - seg.col0;
                        const cx_end = advanceCols(seg_text[0..@min(hi, seg_text.len)], seg.col0, tab) - seg.col0;
                        var cx: u16 = @intCast(@min(cx_start, text_width));
                        const cx_lim: u16 = @intCast(@min(cx_end, text_width));
                        while (cx < cx_lim) : (cx += 1) {
                            if (win.readCell(text_start_x + cx, y)) |cell| {
                                var new_cell = cell;
                                new_cell.style.bg = toVaxis(editor.tui_theme.find_match_bg);
                                new_cell.style.fg = toVaxis(editor.tui_theme.find_match_fg);
                                win.writeCell(text_start_x + cx, y, new_cell);
                            }
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

/// A new status message: a filled block in its level's colors, centered
/// and free to cover the rest of the bar — it is there for a few seconds.
/// One blank cell either side; a message wider than the bar ends in "…".
fn drawStatusMessageBlock(win: Window, editor: *Editor, view: status_mod.View, width: u16) void {
    if (width < 4) return;
    const pair = theme_mod.statusBlock(&editor.tui_theme, view.level);
    const style: Style = .{ .bg = toVaxis(pair.bg), .fg = toVaxis(pair.fg), .bold = true };
    const room: usize = width - 2;
    var text = view.text;
    const cut = advanceCols(text, 0, 1) > room;
    if (cut) text = text[0..fitEnd(text, 0, room - 1, 1)];
    const block_w = advanceCols(text, 0, 1) + @intFromBool(cut) + 2;
    var x: u16 = @intCast((width - block_w) / 2);
    x = writeStr(win, x, 0, " ", style);
    x = writeStr(win, x, 0, text, style);
    if (cut) x = writeStr(win, x, 0, "…", style);
    _ = writeStr(win, x, 0, " ", style);
}

/// Draw the status bar.
fn drawStatusBar(win: Window, editor: *Editor, width: u16) void {
    const style: Style = .{ .bg = toVaxis(editor.tui_theme.status_bg), .fg = toVaxis(editor.tui_theme.status_fg), .bold = true };

    // Fill background
    win.fill(.{ .style = style });

    // The message slot: a new message is a highlighted block for a few
    // seconds (drawn last, over everything), then plain text like the rest.
    const message = editor.statusView(std.Io.Clock.now(.awake, editor.io).nanoseconds);
    defer if (message.fresh) drawStatusMessageBlock(win, editor, message, width);

    // The terminal panel has the keys: say so (the document behind it is
    // not what typing reaches).
    if (editor.keyboardOwner() == .terminal_panel) {
        const label: []const u8 = blk: {
            if (editor.terminalPanelTerminal()) |t| {
                t.mutex.lockUncancelable(t.io);
                defer t.mutex.unlock(t.io);
                if (t.exited) break :blk " [TERMINAL PANEL - exited: press a key to close]";
            }
            break :blk " [TERMINAL PANEL]";
        };
        _ = writeStr(win, 0, 0, label, style);
        return;
    }

    // Terminal pane: show simple label instead of doc info
    if (editor.activePaneIsTerminal()) {
        const label = blk: {
            if (editor.activePaneTerminalIdx()) |ti| {
                if (ti < editor.terminals.items.len) {
                    if (editor.terminals.items[ti]) |t| {
                        if (t.exited) break :blk " [TERMINAL - exited: press a key to close]";
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
    if (message.text.len > 0) {
        // Past its highlight: plain, in half the bar (whole characters).
        if (!message.fresh) {
            const shown = message.text[0..fitEnd(message.text, 0, width / 2, 1)];
            const center_x: u16 = @intCast((width - advanceCols(shown, 0, 1)) / 2);
            _ = writeStr(win, center_x, 0, shown, style);
        }
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

/// The terminal caret while the terminal panel has the keys: the shell's
/// own cursor inside the band's grid (hidden with the band, or while the
/// shell hides it / has exited).
fn positionTerminalPanelCursor(win: Window, editor: *Editor) void {
    const band = terminal_panel_band orelse {
        win.hideCursor();
        return;
    };
    const t = editor.terminalPanelTerminal() orelse {
        win.hideCursor();
        return;
    };
    t.mutex.lockUncancelable(t.io);
    const trow = t.cursor_row;
    const tcol = t.cursor_col;
    const visible = t.cursor_visible and !t.exited;
    t.mutex.unlock(t.io);
    if (visible and trow < band.grid_h and tcol < band.grid_w) {
        win.showCursor(band.grid_x +| tcol, band.grid_y +| trow);
        win.setCursorShape(.block);
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
        // The snippet form: a click on a field row moves the typing there
        if (editor.mode == .snippet_form) {
            if (snippet_form_band) |b| {
                if (mouse.row >= b.y and mouse.row < b.y + b.h) handleSnippetFormClick(editor, b, @intCast(mouse.row));
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
                find_bar_drag = false;
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
    editor.dismissStatus();
    press_pane = null;
    block_drag = false;
    block_engaged = false;
    find_bar_drag = false;

    // Tab bar click: show the document in the focused pane, which also takes
    // the keyboard back from a focused side panel (Editor.showDocIn)
    const tab_bar_height: i16 = if (editor.docCount() > 1) 1 else 0;
    if (tab_bar_height > 0 and mouse.row == 0) {
        if (mouse.col >= 0) {
            if (tabAtX(editor, @intCast(mouse.col))) |doc_idx| editor.showDocIn(0, doc_idx);
        }
        return;
    }

    // Find bar row: its box takes the keyboard, its buttons act
    if (find_bar_band) |band| {
        if (mouse.row == band.y and mouse.col >= band.x and mouse.col < @as(i32, band.x) + band.w) {
            handleFindBarClick(editor, band, @intCast(mouse.col), mouse.mods.shift);
            return;
        }
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

    // Snippets band: a click focuses the panel and selects a row; the
    // highlighted item inserts on its next click
    if (snippets_band) |band| {
        if (mouseOverSnippets(mouse)) {
            handleSnippetsClick(editor, band, @intCast(mouse.row));
            return;
        }
    }

    // Terminal panel band: a click gives its shell the keyboard
    if (mouseOverTerminalPanel(mouse)) {
        _ = editor.takeKeyboardFocus(.terminal_panel);
        return;
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
    // A drag that began in the find bar's box selects in it.
    if (find_bar_drag) {
        const band = find_bar_band orelse return;
        const cell = clampLocal(mouse.col, band.box.x, @max(band.box.w, 1));
        const box = &editor.find_bar.needle;
        box.setCaret(findBarOffsetAt(box, cell), true);
        return;
    }
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
    if (snippets_band) |band| {
        if (mouseOverSnippets(mouse)) {
            // Over the preview its notes scroll, else the list (both
            // clamped at draw time)
            if (mouse.row >= @as(i32, band.y) + band.preview_y) {
                if (down) snippets_preview_scroll +|= 3 else snippets_preview_scroll -|= 3;
            } else {
                const panel = &editor.snippet_panel;
                if (down) panel.scroll +|= 3 else panel.scroll -|= 3;
            }
            return;
        }
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
    if (editor.filetree_move_src == null) editor.dismissStatus();
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
    // the previous transient status message (a new one keeps its time on
    // the bar: dismissStatus)
    scroll_pinned = false;
    editor.dismissStatus();

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

    // Its field looks active only while the panel gets the keys (not
    // under the snippet form or a prompt).
    const focused = editor.search_focused and editor.mode == .normal;
    _ = drawSearchInputRow(win, 0, width, "Search ", sp.query(), focused and sp.field == .query, bg_style, label_active);
    _ = drawSearchInputRow(win, 1, width, "Replace", sp.replacement(), focused and sp.field == .replace, bg_style, label_active);
    _ = drawSearchInputRow(win, 2, width, "Include", sp.filter(), focused and sp.field == .filter, bg_style, label_active);
    _ = drawSearchInputRow(win, 3, width, "Exclude", sp.exclude(), focused and sp.field == .exclude, bg_style, label_active);

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

/// One labelled input row of a docked band (the search panel, the snippet
/// form): an active row's label in reverse video and a `_` after its
/// value. Returns the column after the value, where that `_` goes.
fn drawSearchInputRow(win: Window, y: u16, width: u16, label: []const u8, value: []const u8, active: bool, base: Style, active_label: Style) u16 {
    const row = win.child(.{ .y_off = @intCast(y), .height = 1, .width = width });
    row.fill(.{ .style = base });
    var x = writeStr(row, 0, 0, label, if (active) active_label else base);
    x = writeStr(row, x, 0, " ", base);
    x = writeStr(row, x, 0, value, base);
    if (active) _ = writeStr(row, x, 0, "_", base);
    return x;
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
    // Global chords still work from the panel (Ctrl+Shift+F cycle, F4, …).
    // Alt+C / Alt+W are two of them: find_toggle_case and
    // find_toggle_whole_word flip the panel's buttons while it has the keys.
    if (tryKeybindCommand(editor, key)) return;
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

/// The snippet form's field labels, padded to one width (the Body row
/// lines up with them).
const snippet_form_labels = [_][]const u8{ "Name    ", "Folder  ", "Trigger ", "Language", "Notes   " };

/// The rows a snippet form band `h` rows tall shows, by band row: the
/// title, the five fields Name to Notes, the body summary, then the keys
/// (or the form's error). A shorter band drops the keys row, then the body
/// row — an error keeps the one spare row, or else shows on the title row
/// — and below six rows the field rows scroll to keep the active field in
/// view (one row: the active field alone).
const SnippetFormRows = struct {
    title: bool = true,
    /// The band row of the first field row; it shows `first_field`.
    fields_y: u16 = 1,
    first_field: u8 = 0,
    field_rows: u8 = snippet_form_labels.len,
    body_y: ?u16 = null,
    message_y: ?u16 = null,
};

fn snippetFormRows(h: u16, active: snippet_form_mod.Field, has_error: bool) SnippetFormRows {
    var rows: SnippetFormRows = .{};
    if (h < 2) {
        rows.title = false;
        rows.fields_y = 0;
    }
    const room = h -| rows.fields_y;
    rows.field_rows = @intCast(@min(snippet_form_labels.len, room));
    const idx: u8 = @min(@intFromEnum(active), snippet_form_labels.len - 1);
    if (rows.field_rows > 0 and idx >= rows.field_rows) rows.first_field = idx + 1 - rows.field_rows;
    const after = rows.fields_y + rows.field_rows;
    switch (room -| snippet_form_labels.len) {
        0 => {},
        1 => if (has_error) {
            rows.message_y = after;
        } else {
            rows.body_y = after;
        },
        else => {
            rows.body_y = after;
            rows.message_y = after + 1;
        },
    }
    return rows;
}

/// Draw the snippet form band (Save / Edit / Copy a snippet), the GUI
/// dialog's terminal twin: the title, one row per field — the active one
/// marked as the search panel marks its field, with the terminal caret at
/// its end — the body's size and where to add blanks, then the keys, or
/// the form's error after a refused Enter. Returns the rows it showed
/// (for snippet_form_band).
fn drawSnippetForm(win: Window, editor: *Editor, width: u16, h: u16) SnippetFormRows {
    const form = &editor.snippet_form;
    const th = &editor.tui_theme;
    const base: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_fg) };
    const dim: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_dim) };
    const warn: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_warn) };
    const title_style: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_accent), .bold = true };
    const label_active: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_fg), .bold = true, .reverse = true };
    win.fill(.{ .style = base });
    // The active field's row shows the caret again below: none stays
    // where the last frame left it.
    win.hideCursor();

    const err = form.error_message;
    const rows = snippetFormRows(h, form.field, err.len > 0);
    if (rows.title) {
        const title: []const u8 = switch (form.kind) {
            .save => "Save as snippet \u{2014} my-snippets.lua",
            .edit => "Edit snippet",
            .copy => "Copy to my snippets",
        };
        _ = writeStr(win, 0, 0, title, title_style);
        // An error with no row of its own goes to the end of this one
        if (err.len > 0 and rows.message_y == null) {
            const cols = @min(win.gwidth(err), width);
            _ = writeStr(win, width -| cols -| 1, 0, err, warn);
        }
    }
    const value_x: u16 = @intCast(snippet_form_labels[0].len + 1);
    for (0..rows.field_rows) |i| {
        const idx = rows.first_field + i;
        const field: snippet_form_mod.Field = @enumFromInt(idx);
        const y = rows.fields_y + @as(u16, @intCast(i));
        const active = field == form.field;
        var shown_buf: [snippet_field_shown_max]u8 = undefined;
        const keep_end: ?u16 = if (active) width -| value_x -| 1 else null;
        const shown = snippetFieldShown(win, &shown_buf, form.text(field), keep_end);
        const caret_x = drawSearchInputRow(win, y, width, snippet_form_labels[idx], shown, active, base, label_active);
        if (active and caret_x < width) {
            win.showCursor(caret_x, y);
            win.setCursorShape(.beam_blink);
        }
    }
    if (rows.body_y) |y| {
        const body = form.text(.body);
        const lines: usize = if (body.len == 0) 0 else std.mem.count(u8, body, "\n") + 1;
        var count_buf: [32]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d} {s}", .{ lines, if (lines == 1) "line" else "lines" }) catch "";
        const row = win.child(.{ .y_off = @intCast(y), .height = 1, .width = width });
        var x = writeStr(row, 0, 0, "Body     ", base);
        x = writeStr(row, x, 0, count, base);
        _ = writeStr(row, x, 0, " \u{2014} add blanks like ${1:text} and $0 by editing my-snippets.lua", dim);
    }
    if (rows.message_y) |y| {
        const row = win.child(.{ .y_off = @intCast(y), .height = 1, .width = width });
        if (err.len > 0) {
            _ = writeStr(row, 0, 0, err, warn);
        } else {
            _ = writeStr(row, 0, 0, "Enter saves \u{00b7} Tab/Shift+Tab fields \u{00b7} Esc cancels", dim);
        }
    }
    return rows;
}

/// Bytes a form field's row may need: Notes, the longest field, with
/// every byte a line break drawn as a 3-byte ↵, plus the … cut marker.
const snippet_field_shown_max = 3 * @sizeOf(@FieldType(snippet_form_mod.State, "notes")) + 3;

/// A field's value as one row: line breaks (an edited snippet's notes)
/// show as ↵, and with `keep_end` set (the active field) a value wider
/// than that many columns shows its end, where typing lands, after a ….
fn snippetFieldShown(win: Window, buf: []u8, value: []const u8, keep_end: ?u16) []const u8 {
    const marker = "\u{2026}";
    // The value goes after room for the marker
    var n: usize = marker.len;
    for (value) |b| {
        if (b == '\n') {
            if (n + 3 > buf.len) break;
            @memcpy(buf[n..][0..3], "\u{21b5}");
            n += 3;
        } else {
            if (n >= buf.len) break;
            buf[n] = b;
            n += 1;
        }
    }
    const text = buf[marker.len..n];
    const cols = keep_end orelse return text;
    if (win.gwidth(text) <= cols) return text;
    if (cols == 0) return text[text.len..];
    // Its last cols - 1 columns, starting on a character, behind the marker
    var start = text.len - filetree_mod.pathTail(text, cols - 1).len;
    while (start < text.len and win.gwidth(text[start..]) > cols - 1) {
        start += std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
    }
    start = @min(start, text.len);
    @memcpy(buf[start..][0..marker.len], marker);
    return buf[start..n];
}

/// Click inside the snippet form band: the field on that row takes the
/// typing (the title, body and keys rows do nothing).
fn handleSnippetFormClick(editor: *Editor, band: SnippetFormBand, row: u16) void {
    const rows = band.rows;
    const rel = row - band.y;
    if (rel < rows.fields_y or rel - rows.fields_y >= rows.field_rows) return;
    editor.snippet_form.field = @enumFromInt(rows.first_field + (rel - rows.fields_y));
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
        if (filter.len > 0 and !Editor.paletteMatch(name, filter)) continue;
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

// ===========================================================================
// The find bar (Ctrl+F): one row under the panes that stays open
// ===========================================================================

/// The bar's toggle buttons, in the order they are drawn. No hover in a
/// terminal: flipping one names it in the status bar.
const find_bar_toggles = [_]struct { which: find_bar_mod.Toggle, label: []const u8 }{
    .{ .which = .match_case, .label = " Aa " },
    .{ .which = .whole_word, .label = " W " },
    .{ .which = .highlight_all, .label = " All " },
};

/// Narrowest pane area the bar is drawn in, and the fewest cells its box
/// keeps before a part of the bar is left out.
const find_bar_min_width: u16 = 12;

/// `piece` takes at most `width` cells.
fn fitsCells(width: usize, piece: []const u8) bool {
    return advanceCols(piece, 0, 1) <= width;
}

/// Draw the find bar into `win` (one row of `width` cells whose first cell
/// is screen cell x0, y0): ` Find `, the text box, the toggle buttons, the
/// count, previous / next and close. A narrow row leaves out what it has
/// no room for, the label first.
fn drawFindBar(win: Window, editor: *Editor, x0: u16, y0: u16, width: u16) FindBarBand {
    const fb = &editor.find_bar;
    const th = &editor.tui_theme;
    const focused = editor.mode == .normal and editor.keyboardOwner() == .find_bar;
    const base: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_fg) };
    const dim: Style = .{ .bg = toVaxis(th.overlay_bg), .fg = toVaxis(th.overlay_dim) };
    const lit: Style = .{ .bg = toVaxis(th.overlay_selection_bg), .fg = toVaxis(th.overlay_selection_fg), .bold = true };
    win.fill(.{ .style = base });

    const count = fb.count(editor);
    var count_buf: [32]u8 = undefined;
    const count_txt = find_bar_mod.countLabel(count, fb.needle.len > 0, &count_buf);
    const none = fb.needle.len > 0 and count.total == 0;

    // What fits beside a box of at least find_bar_min_width cells.
    const label = " Find ";
    const toggles_w: u16 = comptime blk: {
        var w: u16 = 0;
        for (find_bar_toggles) |tg| w += tg.label.len + 1;
        break :blk w;
    };
    const count_w: u16 = 14; // "100000+ found" and a blank
    const nav_w: u16 = 7;
    const close_w: u16 = 3;
    var room: u16 = width;
    const Parts = struct { toggles: bool = false, count: bool = false, close: bool = false, nav: bool = false, label: bool = false };
    var show: Parts = .{};
    if (room >= toggles_w + find_bar_min_width) {
        room -= toggles_w;
        show.toggles = true;
    }
    if (room >= count_w + find_bar_min_width) {
        room -= count_w;
        show.count = true;
    }
    if (room >= close_w + find_bar_min_width) {
        room -= close_w;
        show.close = true;
    }
    if (room >= nav_w + find_bar_min_width) {
        room -= nav_w;
        show.nav = true;
    }
    if (room >= label.len + find_bar_min_width) {
        room -= label.len;
        show.label = true;
    }

    var band: FindBarBand = .{ .x = x0, .y = y0, .w = width };
    var x: u16 = 0;
    if (show.label) {
        const label_style: Style = if (focused) .{ .bg = base.bg, .fg = toVaxis(th.overlay_accent), .bold = true } else dim;
        x = writeStr(win, 0, 0, label, label_style);
    }

    // The box: `room` cells, the last one a blank before the buttons.
    // Underlined so its extent shows; tinted when the text matches nothing.
    const box_w: u16 = room - 1;
    band.box = .{ .x = x0 + x, .w = box_w };
    const box = &fb.needle;
    // One cell stays free for the caret after the last character.
    box.scrollToCaret(@as(usize, box_w - 1), fitsCells);
    const field: Style = if (none)
        .{ .bg = toVaxis(th.status_error_bg), .fg = toVaxis(th.status_error_fg) }
    else
        .{ .bg = toVaxis(th.text_bg), .fg = toVaxis(th.text_fg), .ul_style = .single };
    const box_win = win.child(.{ .x_off = @intCast(x), .y_off = 0, .width = box_w, .height = 1 });
    box_win.fill(.{ .style = field });
    const text = box.text();
    const first = @min(box.scroll, text.len);
    const last = first + fitEnd(text[first..], 0, box_w, 1);
    if (if (focused) box.selection() else null) |r| {
        const a = std.math.clamp(r.start, first, last);
        const b = std.math.clamp(r.end, first, last);
        const picked: Style = .{ .bg = toVaxis(th.selection_bg), .fg = toVaxis(th.selection_fg) };
        var bx: u16 = 0;
        if (a > first) bx = writeStr(box_win, bx, 0, text[first..a], field);
        if (b > a) bx = writeStr(box_win, bx, 0, text[a..b], picked);
        if (last > b) _ = writeStr(box_win, bx, 0, text[b..last], field);
    } else if (last > first) {
        _ = writeStr(box_win, 0, 0, text[first..last], field);
    }
    x += room;

    if (show.toggles) {
        for (find_bar_toggles, 0..) |tg, i| {
            band.toggles[i] = .{ .x = x0 + x, .w = @intCast(tg.label.len) };
            x = writeStr(win, x, 0, tg.label, if (fb.isOn(tg.which)) lit else dim) + 1;
        }
    }
    if (show.count) {
        const shown: u16 = @intCast(@min(count_txt.len, count_w - 1));
        const count_style: Style = if (none) .{ .bg = base.bg, .fg = toVaxis(th.overlay_warn), .bold = true } else dim;
        if (shown > 0) _ = writeStr(win, x + (count_w - 1 - shown), 0, count_txt[0..shown], count_style);
        x += count_w;
    }
    if (show.nav) {
        band.prev = .{ .x = x0 + x, .w = 3 };
        _ = writeStr(win, x, 0, " \u{2191} ", base);
        band.next = .{ .x = x0 + x + 3, .w = 3 };
        _ = writeStr(win, x + 3, 0, " \u{2193} ", base);
        x += nav_w;
    }
    if (show.close) {
        band.close = .{ .x = x0 + x, .w = close_w };
        _ = writeStr(win, x, 0, " \u{00d7} ", base);
    }
    return band;
}

/// The terminal caret in the find bar's box (hidden when the bar is not
/// drawn, or the caret is outside what the box shows).
fn positionFindBarCursor(win: Window, editor: *Editor) void {
    const band = find_bar_band orelse return win.hideCursor();
    const box = &editor.find_bar.needle;
    if (box.scroll > box.caret) return win.hideCursor();
    const col = advanceCols(box.text()[box.scroll..box.caret], 0, 1);
    if (col >= band.box.w) return win.hideCursor();
    win.showCursor(band.box.x + @as(u16, @intCast(col)), band.y);
    win.setCursorShape(.beam_blink);
}

/// Byte offset in the box's text for cell `cell` of the box as drawn.
fn findBarOffsetAt(box: *const find_bar_mod.Needle, cell: usize) usize {
    const text = box.text();
    const first = @min(box.scroll, text.len);
    return first + byteAtCol(text[first..], 0, cell, 1, true);
}

/// A left press on the find bar's row: the box takes the keyboard (the
/// search starts where the caret in the text is), and the press acts on
/// what it hit — a toggle, previous / next, close, or a place in the box.
fn handleFindBarClick(editor: *Editor, band: FindBarBand, col: u16, shift: bool) void {
    const fb = &editor.find_bar;
    fb.focus(editor);
    if (band.close.has(col)) return fb.close(editor);
    if (band.prev.has(col)) return fb.step(editor, false);
    if (band.next.has(col)) return fb.step(editor, true);
    for (find_bar_toggles, band.toggles) |tg, span| {
        if (span.has(col)) return fb.toggle(editor, tg.which);
    }
    if (band.box.has(col)) {
        fb.needle.setCaret(findBarOffsetAt(&fb.needle, col - band.box.x), shift);
        find_bar_drag = true;
    }
}

/// Typed or pasted text for the find bar's box.
fn findBarInsert(editor: *Editor, text: []const u8) void {
    scroll_pinned = false;
    if (editor.find_bar.needle.insert(text)) editor.find_bar.edited(editor);
}

/// Keys while the find bar's box owns the keyboard: Enter / Shift+Enter go
/// to the next / previous match, Escape closes the bar, Up / Down walk the
/// earlier searches, the arrows, Home / End, Backspace and Delete edit the
/// box (Shift selects). The Ctrl / Alt / F-key chords go through the
/// keybind map first — the clipboard, word and undo ones edit the box
/// (Editor.panelAction), F3 and the toggles are commands.
fn handleFindBarKey(editor: *Editor, key: Key) void {
    if (key.isModifier()) return;
    scroll_pinned = false;
    editor.dismissStatus();
    if (tryKeybindCommand(editor, key)) return;
    if (key.mods.super) return;
    const fb = &editor.find_bar;
    const box = &fb.needle;
    const shift = key.mods.shift;
    switch (key.codepoint) {
        Key.escape => fb.close(editor),
        Key.enter => fb.step(editor, !shift),
        Key.up => fb.historyStep(editor, true),
        Key.down => fb.historyStep(editor, false),
        Key.left => box.moveLeft(shift),
        Key.right => box.moveRight(shift),
        Key.home => box.moveHome(shift),
        Key.end => box.moveEnd(shift),
        Key.backspace => if (box.backspace()) fb.edited(editor),
        Key.delete => if (box.deleteForward()) fb.edited(editor),
        // One box for now: Tab stays in it.
        Key.tab => {},
        else => {
            if (key.text) |text| {
                findBarInsert(editor, text);
            } else if (isTextCodepoint(key.codepoint)) {
                var bytes: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(key.codepoint, &bytes) catch return;
                findBarInsert(editor, bytes[0..n]);
            }
        },
    }
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
        error.BinaryFile => editor.setStatus(.err, "Not opened: binary or unsupported text encoding"),
        else => {
            var prefix_buf: [96]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buf, "Open failed ({s}): ", .{@errorName(err)}) catch "Open failed: ";
            lua_api.setStatusError(editor, prefix, path);
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
        if (filter.len > 0 and !Editor.paletteMatch(name, filter)) continue;
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
        // Execute the highlighted command (the drawn selection: a selection
        // past the last match means the last match, as drawn).
        const name = editor.paletteSelectedName();
        editor.setMode(.normal);
        editor.palette_selected = 0;
        if (name) |n| _ = editor.execCommand(n, null);
        return;
    }
    if (key.codepoint == Key.tab) {
        editor.paletteComplete();
        return;
    }
    if (key.codepoint == Key.down) {
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

/// The review reader's row background for a row kind, if it has one.
fn reviewTuiBg(editor: *const Editor, kind: ?review_reader.LineKind) ?Color {
    const k = kind orelse return null;
    return switch (k) {
        .added => toVaxis(editor.tui_theme.review_added_bg),
        .modified => toVaxis(editor.tui_theme.review_modified_bg),
        .ghost => toVaxis(editor.tui_theme.review_ghost_bg),
        .marker, .context => null,
    };
}

/// The gutter number of a row: in the review reader the real file's line
/// (blank for ghost and marker rows), else the row's own.
fn tuiGutterNumber(doc: *const Document, line_idx: usize, buf: []u8) []const u8 {
    if (doc.reader) |info| {
        if (line_idx >= info.real_line.len) return "";
        const real = info.real_line[line_idx] orelse return "";
        return std.fmt.bufPrint(buf, "{d}", .{real + 1}) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}", .{line_idx + 1}) catch "";
}

fn handleToolKey(editor: *Editor, key: Key) void {
    if (key.isModifier() or hasCommandMod(key)) return;
    switch (key.codepoint) {
        Key.escape => editor.setMode(.normal),
        // Space too, so the left hand reaches it next to A / W / D / R.
        Key.enter, ' ' => editor.tool_panel.activate(editor),
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
        'p', 'P' => editor.tool_panel.action(editor, 'p'),
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
    _ = writeStr(panel, 0, rows -| 1, "Up/Down select • PgUp/PgDn scroll • Enter/Space activates • Esc closes", style);
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
    _ = try editor.registerSnippet(.{ .language = "*", .prefix = "demo", .description = "Demo", .body = "${1:first} ${2:tail}$0" });
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

/// Tests only: ZIDE_CAPTURE_DIR when it is set — screen dumps go there.
fn testCaptureDir(allocator: std.mem.Allocator) ?[]u8 {
    var env = std.testing.environ.createMap(allocator) catch return null;
    defer env.deinit();
    const dir = env.get("ZIDE_CAPTURE_DIR") orelse return null;
    return allocator.dupe(u8, dir) catch null;
}

/// Tests only: the screen as text, one line per row (an empty cell is a
/// space), saved as `name` in ZIDE_CAPTURE_DIR; nothing without it.
fn testCaptureScreen(screen: *vaxis.Screen, name: []const u8) !void {
    const t = std.testing;
    const dir = testCaptureDir(t.allocator) orelse return;
    defer t.allocator.free(dir);
    const path = try std.fs.path.join(t.allocator, &.{ dir, name });
    defer t.allocator.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    for (0..screen.height) |y| {
        for (0..screen.width) |x| {
            const g = screen.readCell(@intCast(x), @intCast(y)).?.char.grapheme;
            try out.appendSlice(t.allocator, if (g.len == 0) " " else g);
        }
        try out.append(t.allocator, '\n');
    }
    const file = try std.Io.Dir.cwd().createFile(t.io, path, .{});
    defer file.close(t.io);
    try file.writeStreamingAll(t.io, out.items);
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

    // A read-only tab refuses the paste and says why (was "out of memory",
    // with the real reason showing one command late)
    doc.readonly = true;
    handleInputEvent(&editor, .paste_start, null);
    handleInputEvent(&editor, .{ .key_press = .{ .codepoint = 'x', .text = "x" } }, null);
    handleInputEvent(&editor, .paste_end, null);
    try t.expectEqualStrings("Read-only document", editor.status_message);
    try t.expect(!doc.edit_refused);
    try t.expectEqualStrings("", doc.buffer.slice(0, doc.buffer.byteLen()));
    doc.readonly = false;

    // The find bar's box and a single-line prompt take the first line
    for ([_][]const u8{ "find", "find_replace" }) |action| {
        _ = editor.execAction(action);
        handleInputEvent(&editor, .paste_start, null);
        for ("needle") |c| handleInputEvent(&editor, .{ .key_press = .{ .codepoint = c, .text = &[_]u8{c} } }, null);
        handleInputEvent(&editor, .{ .key_press = .{ .codepoint = Key.enter } }, null);
        handleInputEvent(&editor, .{ .key_press = .{ .codepoint = 'x', .text = "x" } }, null);
        handleInputEvent(&editor, .paste_end, null);
    }
    try t.expectEqualStrings("needle", editor.find_bar.needle.text());
    try t.expect(!editor.find_bar.visible); // Ctrl+H closed it: one find row at a time
    try t.expectEqual(Editor.Mode.find_replace, editor.mode);
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

test "TUI status messages: a new one is a filled block that outlasts key presses, then plain text; a long one takes the whole bar" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    var buf: [512]u8 = undefined;
    const bar_y: u16 = 29;
    const bar_bg = toVaxis(editor.tui_theme.status_bg);
    const note = theme_mod.statusBlock(&editor.tui_theme, .note);
    const failure = theme_mod.statusBlock(&editor.tui_theme, .err);

    // 11 letters and a blank either side, centered in 100 columns.
    editor.status_message = "Saved a.zig";
    testFrame(win, &editor);
    try t.expectEqualStrings(" Saved a.zig ", testCells(&screen, 43, bar_y, 13, &buf));
    try t.expectEqual(toVaxis(note.bg), screen.readCell(43, bar_y).?.style.bg);
    try t.expectEqual(toVaxis(note.fg), screen.readCell(44, bar_y).?.style.fg);
    try t.expectEqual(toVaxis(note.bg), screen.readCell(55, bar_y).?.style.bg);
    try t.expectEqual(bar_bg, screen.readCell(42, bar_y).?.style.bg);
    try t.expectEqual(bar_bg, screen.readCell(56, bar_y).?.style.bg);

    // Typing on: the letter lands in the document, the block stays.
    testType(&editor, "x");
    try t.expectEqualStrings("", editor.status_message);
    try t.expectEqualStrings("x", editor.activeDoc().buffer.slice(0, 1));
    testFrame(win, &editor);
    try t.expectEqualStrings(" Saved a.zig ", testCells(&screen, 43, bar_y, 13, &buf));
    try t.expectEqual(toVaxis(note.bg), screen.readCell(43, bar_y).?.style.bg);
    try t.expect(editor.deadlines.next_status != null);

    // Its time is up (aged by hand): gone, since the key press dismissed it.
    editor.status_flash.shown_ns.? -= 5 * std.time.ns_per_s;
    testFrame(win, &editor);
    try t.expectEqual(bar_bg, screen.readCell(43, bar_y).?.style.bg);
    try t.expect(std.mem.indexOf(u8, testCells(&screen, 0, bar_y, 100, &buf), "Saved") == null);
    try t.expectEqual(@as(?i128, null), editor.deadlines.next_status);

    // An error has its own colors; left alone it settles into plain text
    // at the same column and stays until the next key press.
    editor.setStatus(.err, "Save failed: AccessDenied");
    testFrame(win, &editor);
    try t.expectEqualStrings(" Save failed: AccessDenied ", testCells(&screen, 36, bar_y, 27, &buf));
    try t.expectEqual(toVaxis(failure.bg), screen.readCell(36, bar_y).?.style.bg);
    try t.expectEqual(toVaxis(failure.fg), screen.readCell(37, bar_y).?.style.fg);
    editor.status_flash.shown_ns.? -= 5 * std.time.ns_per_s;
    testFrame(win, &editor);
    try t.expectEqualStrings("Save failed: AccessDenied", testCells(&screen, 37, bar_y, 25, &buf));
    try t.expectEqual(bar_bg, screen.readCell(37, bar_y).?.style.bg);
    try t.expectEqualStrings("Save failed: AccessDenied", editor.status_message);
    testType(&editor, "y");
    testFrame(win, &editor);
    try t.expect(std.mem.indexOf(u8, testCells(&screen, 0, bar_y, 100, &buf), "Save failed") == null);

    // Wider than the bar: the block is the whole row and ends in "…".
    editor.status_message = "y" ** 120;
    testFrame(win, &editor);
    try t.expectEqual(toVaxis(note.bg), screen.readCell(0, bar_y).?.style.bg);
    try t.expectEqual(toVaxis(note.bg), screen.readCell(99, bar_y).?.style.bg);
    try t.expectEqualStrings(" ", screen.readCell(0, bar_y).?.char.grapheme);
    try t.expectEqualStrings("y", screen.readCell(97, bar_y).?.char.grapheme);
    try t.expectEqualStrings("…", screen.readCell(98, bar_y).?.char.grapheme);
    try t.expectEqualStrings(" ", screen.readCell(99, bar_y).?.char.grapheme);

    // Cells, not bytes: "é界" is three cells wide (1 + 2).
    editor.status_message = "é界";
    testFrame(win, &editor);
    try t.expectEqual(bar_bg, screen.readCell(46, bar_y).?.style.bg);
    try t.expectEqual(toVaxis(note.bg), screen.readCell(47, bar_y).?.style.bg);
    try t.expectEqualStrings("é", screen.readCell(48, bar_y).?.char.grapheme);
    try t.expectEqualStrings("界", screen.readCell(49, bar_y).?.char.grapheme);
    try t.expectEqual(toVaxis(note.bg), screen.readCell(51, bar_y).?.style.bg);
    try t.expectEqual(bar_bg, screen.readCell(52, bar_y).?.style.bg);

    // `= ""` (a hint that stopped being true) removes the block at once.
    editor.status_message = "Release to hide the file tree";
    testFrame(win, &editor);
    try t.expectEqual(toVaxis(note.bg), screen.readCell(40, bar_y).?.style.bg);
    try testCaptureScreen(&screen, "status_message_tui.txt");
    editor.status_message = "";
    testFrame(win, &editor);
    try t.expectEqual(bar_bg, screen.readCell(40, bar_y).?.style.bg);

    // status_message_seconds = 0: plain text from the first frame.
    editor.status_message_seconds = 0;
    editor.status_message = "Saved a.zig";
    testFrame(win, &editor);
    try t.expectEqualStrings("Saved a.zig", testCells(&screen, 44, bar_y, 11, &buf));
    try t.expectEqual(bar_bg, screen.readCell(44, bar_y).?.style.bg);
}

/// Tests only: the primary cursor's selection is exactly [start, end).
fn testExpectSelection(doc: *Document, start: usize, end: usize) !void {
    const r = doc.cursors.primaryConst().selectionRange() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(start, r.start);
    try std.testing.expectEqual(end, r.end);
}

test "TUI find bar: a row under the panes with the caret in its box; typing, Enter, F3, the toggles and clicks work; Escape closes it" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    editor.clipboard_set_fn = TestClipboard.set;
    editor.clipboard_get_fn = TestClipboard.get;
    const doc = editor.activeDoc();
    const body = "alpha beta\nAlpha gamma\nalphabet\n";
    try doc.loadText(body);
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    testFrame(win, &editor);
    try t.expect(find_bar_band == null);
    const full_h = pane_rects[0].h;
    var buf: [400]u8 = undefined;
    const fb = &editor.find_bar;

    // Ctrl+F: one row right under the panes, above the status bar. Not a
    // prompt — the box has the keyboard, the text stays live.
    testKey(&editor, 'f', .{ .ctrl = true });
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    testFrame(win, &editor);
    var band = find_bar_band.?;
    try t.expectEqual(@as(u16, 28), band.y);
    try t.expectEqual(full_h - 1, pane_rects[0].h);
    try t.expectEqual(pane_rects[0].y + pane_rects[0].h, band.y);
    try t.expectEqualStrings(" Find ", testCells(&screen, 0, band.y, 6, &buf));
    try t.expectEqual(@as(u16, 6), band.box.x);
    try t.expectEqual(@as(u16, 3), band.close.w);

    // Typing goes to the box, never into the document. The first match
    // from the caret is selected, upper and lower case alike.
    testType(&editor, "alpha");
    try t.expectEqualStrings(body, doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualStrings("alpha", fb.needle.text());
    try testExpectSelection(doc, 0, 5);
    testFrame(win, &editor);
    var row = testCells(&screen, 0, band.y, 100, &buf);
    try t.expect(std.mem.indexOf(u8, row, " Find alpha") != null);
    try t.expect(std.mem.indexOf(u8, row, "1 of 3") != null);
    try t.expect(std.mem.indexOf(u8, row, " Aa   W   All ") != null);

    // Enter / Shift+Enter and F3 / Shift+F3 walk the matches, around the ends
    testKey(&editor, Key.enter, .{});
    try testExpectSelection(doc, 11, 16);
    testKey(&editor, Key.f3, .{});
    try testExpectSelection(doc, 23, 28);
    testKey(&editor, Key.f3, .{ .shift = true });
    try testExpectSelection(doc, 11, 16);
    testKey(&editor, Key.enter, .{ .shift = true });
    try testExpectSelection(doc, 0, 5);
    testKey(&editor, Key.enter, .{ .shift = true });
    try testExpectSelection(doc, 23, 28);
    try t.expectEqualStrings("Find: on to the last match", editor.status_message);
    testKey(&editor, Key.enter, .{});
    try testExpectSelection(doc, 0, 5);

    // Alt+W: whole words only. No hover in a terminal — the status bar
    // names the button.
    testKey(&editor, 'w', .{ .alt = true });
    try t.expect(fb.options.whole_word);
    try t.expectEqualStrings("Whole word: on", editor.status_message);
    testFrame(win, &editor);
    row = testCells(&screen, 0, band.y, 100, &buf);
    try t.expect(std.mem.indexOf(u8, row, "1 of 2") != null);
    // A click on Aa: upper and lower case must match too
    testClick(&editor, band.toggles[0].x + 1, band.y);
    try t.expect(fb.options.match_case);
    try t.expectEqualStrings("Match case: on", editor.status_message);
    testFrame(win, &editor);
    row = testCells(&screen, 0, band.y, 100, &buf);
    try t.expect(std.mem.indexOf(u8, row, "1 of 1") != null);
    testKey(&editor, 'c', .{ .alt = true });
    testKey(&editor, 'w', .{ .alt = true });
    try t.expect(!fb.options.match_case and !fb.options.whole_word);

    // All (Alt+A): the other matches are tinted; the one the bar is on
    // keeps the selection's colors.
    testFrame(win, &editor);
    const text_x = pane_rects[0].x + lineNumberWidth(doc.lineCount(), editor.gutter_min_digits) + 1;
    const top = pane_rects[0].y;
    const tint = toVaxis(editor.tui_theme.find_match_bg);
    try t.expect(!std.meta.eql(screen.readCell(text_x, top + 1).?.style.bg, tint));
    testKey(&editor, 'a', .{ .alt = true });
    try t.expect(fb.highlight_all);
    testFrame(win, &editor);
    try t.expect(std.meta.eql(screen.readCell(text_x, top).?.style.bg, toVaxis(editor.tui_theme.selection_bg)));
    try t.expect(std.meta.eql(screen.readCell(text_x, top + 1).?.style.bg, tint));
    try t.expect(std.meta.eql(screen.readCell(text_x + 4, top + 1).?.style.bg, tint));
    try t.expect(!std.meta.eql(screen.readCell(text_x + 5, top + 1).?.style.bg, tint));
    try t.expect(std.meta.eql(screen.readCell(text_x + 4, top + 2).?.style.bg, tint));
    try t.expect(!std.meta.eql(screen.readCell(text_x + 5, top + 2).?.style.bg, tint));
    try testCaptureScreen(&screen, "find_bar_tui.txt");

    // The box edits like a text box: the caret moves, text lands at it,
    // Ctrl+Z takes it back, Shift selects, Ctrl+A is the box's own.
    testKey(&editor, Key.left, .{});
    try t.expectEqual(@as(usize, 4), fb.needle.caret);
    testType(&editor, "X");
    try t.expectEqualStrings("alphXa", fb.needle.text());
    try t.expectEqual(@as(?usize, null), doc.cursors.primaryConst().anchor);
    testFrame(win, &editor);
    row = testCells(&screen, 0, band.y, 100, &buf);
    try t.expect(std.mem.indexOf(u8, row, "No results") != null);
    try testCaptureScreen(&screen, "find_bar_tui_none.txt");
    testKey(&editor, 'z', .{ .ctrl = true });
    try t.expectEqualStrings("alpha", fb.needle.text());
    try testExpectSelection(doc, 0, 5);
    testKey(&editor, Key.home, .{ .shift = true });
    try t.expectEqualStrings("alph", fb.needle.selectedText());
    testKey(&editor, Key.backspace, .{});
    try t.expectEqualStrings("a", fb.needle.text());
    testKey(&editor, 'a', .{ .ctrl = true });
    testType(&editor, "beta");
    try t.expectEqualStrings("beta", fb.needle.text());
    try testExpectSelection(doc, 6, 10);
    try t.expectEqualStrings(body, doc.buffer.slice(0, doc.buffer.byteLen()));

    // A click in the box places the caret; Up brings back the earlier search
    testFrame(win, &editor);
    band = find_bar_band.?;
    testClick(&editor, band.box.x + 2, band.y);
    try t.expectEqual(@as(usize, 2), fb.needle.caret);
    try t.expect(fb.needle.selection() == null);
    testKey(&editor, Key.up, .{});
    try t.expectEqualStrings("alpha", fb.needle.text());
    testKey(&editor, Key.down, .{});
    try t.expectEqualStrings("beta", fb.needle.text());
    testKey(&editor, Key.up, .{});

    // A click in the text gives it the keyboard; the bar stays up and F3
    // keeps walking. Typing edits the document again.
    testFrame(win, &editor);
    const rect = pane_rects[0];
    testClick(&editor, rect.x + rect.w - 2, rect.y);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(fb.visible);
    testKey(&editor, Key.f3, .{});
    try testExpectSelection(doc, 11, 16);
    // Escape in the text closes the bar; the match stays selected
    testKey(&editor, Key.escape, .{});
    try t.expect(!fb.visible);
    try testExpectSelection(doc, 11, 16);
    testFrame(win, &editor);
    try t.expect(find_bar_band == null);
    try t.expectEqual(full_h, pane_rects[0].h);
    // F3 still works without the bar
    testKey(&editor, Key.f3, .{});
    try testExpectSelection(doc, 23, 28);

    // Escape in the box closes it too and hands the keyboard back
    testKey(&editor, 'f', .{ .ctrl = true });
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    testKey(&editor, Key.escape, .{});
    try t.expect(!fb.visible);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());

    // A narrow pane area keeps the box and leaves parts of the bar out
    testKey(&editor, 'f', .{ .ctrl = true });
    frameArenaReset();
    drawEditor(win, &editor, 30, 30);
    band = find_bar_band.?;
    try t.expectEqual(@as(u16, 30), band.w);
    try t.expectEqual(@as(u16, 0), band.prev.w);
    try t.expectEqual(@as(u16, 3), band.close.w);
    try t.expectEqual(@as(u16, 11), band.box.w);
    // No row to spare: not drawn, and the box lets go of the keyboard
    frameArenaReset();
    drawEditor(win, &editor, 100, 2);
    try t.expect(find_bar_band == null);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
}

test "TUI search panel: Alt+C and Alt+W flip its own two buttons while it has the keyboard" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    try t.expect(editor.takeKeyboardFocus(.search));
    testKey(&editor, 'c', .{ .alt = true });
    try t.expect(editor.search.case_sensitive);
    try t.expect(!editor.find_bar.options.match_case);
    testKey(&editor, 'w', .{ .alt = true });
    try t.expect(editor.search.whole_word);
    try t.expect(!editor.find_bar.options.whole_word);
    // Back in the text they are the find bar's
    try t.expect(editor.takeKeyboardFocus(.pane));
    testKey(&editor, 'c', .{ .alt = true });
    try t.expect(editor.find_bar.options.match_case);
    try t.expect(editor.search.case_sensitive);
}

test "TUI snippets panel: docks beside the tree, a click selects then inserts, keys drive the list" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    _ = try editor.registerSnippet(.{ .language = "zig", .description = "Print", .group = "Start here", .notes = "Writes text to the terminal.", .body = "std.debug.print(\"${1:text}\n\", .{${2:values}});" });
    _ = try editor.registerSnippet(.{ .language = "zig", .description = "Constant", .group = "Start here", .notes = "A value that never changes.", .body = "const ${1:name}: ${2:i32} = ${3:0};" });
    _ = try editor.registerSnippet(.{ .language = "zig", .prefix = "fn", .description = "Function", .group = "Functions", .notes = "A named block of code.", .body = "fn ${1:name}($2) ${3:void} {\n\t$0\n}" });
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("zig");
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    var buf: [256]u8 = undefined;

    // Hidden: no band. Ctrl+Alt+B shows it focused, opposite the (hidden)
    // tree: right of the panes, tui_snippets_width columns wide.
    testFrame(win, &editor);
    try t.expect(snippets_band == null);
    testKey(&editor, 'b', .{ .ctrl = true, .alt = true });
    try t.expect(editor.snippets_visible);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    testFrame(win, &editor);
    var band = snippets_band.?;
    try t.expectEqual(@as(u16, 68), band.x);
    try t.expectEqual(@as(u16, 32), band.w);
    try t.expectEqual(@as(u16, 29), band.h);
    const tx = band.x + 1; // the separator column faces the editor
    try t.expectEqualStrings("Snippets \u{2014} zig", testCells(&screen, tx, 0, 14, &buf));
    try t.expectEqualStrings("\u{25be} Start here", testCells(&screen, tx, 1, 12, &buf));
    try t.expectEqualStrings("\u{2502}  Print", testCells(&screen, tx, 2, 8, &buf));
    try t.expectEqualStrings("\u{2502}  Constant", testCells(&screen, tx, 3, 11, &buf));
    try t.expectEqualStrings("\u{25b8} Functions", testCells(&screen, tx, 4, 11, &buf));
    // Four rows: the preview starts right under them, with a divider.
    try t.expectEqual(@as(u16, 6), band.preview_y);
    try t.expectEqualStrings("\u{2500}", testCells(&screen, tx, band.preview_y, 1, &buf));

    // Click Print: selected and previewed, not inserted, the keyboard
    // stays with the panel. Click it again: inserted, its first blank
    // selected, the editor has the keys, so Tab walks to the next blank.
    testClick(&editor, tx + 4, 2);
    try t.expectEqual(@as(usize, 1), editor.snippet_panel.selected);
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    testFrame(win, &editor);
    try t.expectEqual(@as(?u32, 0), snippets_preview_def);
    try t.expectEqualStrings("std.debug.print(\"text", testCells(&screen, tx, band.preview_y + 1, 21, &buf));
    try testCaptureScreen(&screen, "snippets_tui_list.txt");
    testClick(&editor, tx + 4, 2);
    try t.expectEqualStrings("std.debug.print(\"text\n\", .{values});", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualStrings("text", doc.selectedText().?);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    testKey(&editor, Key.tab, .{});
    try t.expectEqualStrings("values", doc.selectedText().?);

    // Ctrl+Alt+B focuses the open panel. Letters filter the rows, never
    // the document behind (the panel is not modal): "con" leaves Constant,
    // selected, under its open group, and the header shows the text.
    // Escape clears the filter — the panel keeps the keys, the selection
    // stays on Constant — and Up, Down, Enter insert it. Escape then hands
    // the keys back and leaves the panel open; the next Ctrl+Alt+B pair
    // hides it.
    testKey(&editor, Key.escape, .{});
    testKey(&editor, 'b', .{ .ctrl = true, .alt = true });
    try t.expect(editor.snippets_visible);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    testType(&editor, "con");
    try t.expectEqual(@as(usize, 2), editor.snippet_panel.rows.items.len);
    try t.expectEqual(@as(usize, 1), editor.snippet_panel.selected);
    try t.expectEqualStrings("std.debug.print(\"text\n\", .{values});", doc.buffer.slice(0, doc.buffer.byteLen()));
    testFrame(win, &editor);
    try t.expectEqualStrings("Snippets \u{2014} zig  /con ", testCells(&screen, tx, 0, 21, &buf));
    try t.expectEqualStrings("\u{25be} Start here", testCells(&screen, tx, 1, 12, &buf));
    try t.expectEqualStrings("\u{2502}  Constant", testCells(&screen, tx, 2, 11, &buf));
    try t.expectEqualStrings(" " ** 11, testCells(&screen, tx, 3, 11, &buf));
    testKey(&editor, Key.escape, .{});
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try t.expect(!editor.snippet_panel.filterActive());
    try t.expectEqual(@as(usize, 4), editor.snippet_panel.rows.items.len);
    try t.expectEqual(@as(usize, 2), editor.snippet_panel.selected);
    testKey(&editor, Key.up, .{});
    try t.expectEqual(@as(usize, 1), editor.snippet_panel.selected);
    testKey(&editor, Key.down, .{});
    try t.expectEqual(@as(usize, 2), editor.snippet_panel.selected);
    testKey(&editor, Key.enter, .{});
    try t.expect(std.mem.indexOf(u8, doc.buffer.slice(0, doc.buffer.byteLen()), "const name: i32 = 0;") != null);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    testKey(&editor, 'b', .{ .ctrl = true, .alt = true });
    testKey(&editor, Key.escape, .{});
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(editor.snippets_visible);
    testKey(&editor, 'b', .{ .ctrl = true, .alt = true });
    testKey(&editor, 'b', .{ .ctrl = true, .alt = true });
    try t.expect(!editor.snippets_visible);
    testFrame(win, &editor);
    try t.expect(snippets_band == null);

    // With the tree (left, 30 columns) the panel keeps the panes 40
    // columns: 30 wide at the right edge. On the tree's side the tree
    // stays outermost, left and right alike.
    editor.filetree_root = try t.allocator.dupe(u8, root);
    editor.filetree_visible = true;
    editor.snippets_visible = true;
    testFrame(win, &editor);
    band = snippets_band.?;
    try t.expectEqual(@as(u16, 0), filetree_band.?.x);
    try t.expectEqual(@as(u16, 70), band.x);
    try t.expectEqual(@as(u16, 30), band.w);
    try t.expectEqual(@as(u16, 40), pane_rects[0].w);
    editor.snippets_side = .left;
    testFrame(win, &editor);
    band = snippets_band.?;
    try t.expectEqual(@as(u16, 0), filetree_band.?.x);
    try t.expectEqual(@as(u16, 30), band.x);
    try t.expectEqual(@as(u16, 60), pane_rects[0].x);
    editor.filetree_side = .right;
    editor.snippets_side = .right;
    testFrame(win, &editor);
    band = snippets_band.?;
    try t.expectEqual(@as(u16, 70), filetree_band.?.x);
    try t.expectEqual(@as(u16, 40), band.x);
    try t.expectEqual(@as(u16, 0), pane_rects[0].x);
    try t.expectEqual(@as(u16, 40), pane_rects[0].w);

    // Too narrow for both bands and 40 columns of panes: the panel hides
    // itself, says so, and its keyboard goes back to the pane.
    _ = editor.takeKeyboardFocus(.snippets);
    frameArenaReset();
    drawEditor(win, &editor, 70, 30);
    try t.expect(snippets_band == null);
    try t.expect(!editor.snippets_visible and !editor.snippets_focused);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(std.mem.indexOf(u8, editor.status_message, "no room") != null);
}

test "TUI terminal panel: a strip at the bottom or a column inward of the tree, the keys go to its shell, no room hides it" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.keybinds.loadDefaults();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    const doc = editor.activeDoc();
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    var buf: [256]u8 = undefined;

    // Hidden: no band. A docked slot (fake: no shell) at the default edge,
    // the bottom: tui_terminal_panel_height rows under the panes, the
    // full width between the (hidden) side bands, its header row on top;
    // the status bar says where the keys go.
    testFrame(win, &editor);
    try t.expect(terminal_panel_band == null);
    try editor.terminals.append(t.allocator, null);
    editor.terminal_panel = 0;
    try t.expect(editor.takeKeyboardFocus(.terminal_panel));
    testFrame(win, &editor);
    var band = terminal_panel_band.?;
    try t.expectEqual(@as(u16, 0), band.x);
    try t.expectEqual(@as(u16, 17), band.y);
    try t.expectEqual(@as(u16, 100), band.w);
    try t.expectEqual(@as(u16, 12), band.h);
    try t.expectEqual(@as(u16, 0), band.grid_x);
    try t.expectEqual(@as(u16, 18), band.grid_y);
    try t.expectEqual(@as(u16, 11), band.grid_h);
    try t.expectEqual(@as(u16, 17), pane_rects[0].h);
    try t.expectEqual(@as(u16, 100), pane_rects[0].w);
    try t.expectEqualStrings(" Terminal \u{2014} Ctrl+` back to the editor ", testCells(&screen, 0, 17, 38, &buf));
    try t.expectEqualStrings(" [TERMINAL PANEL]", testCells(&screen, 0, 29, 17, &buf));
    try testCaptureScreen(&screen, "terminal_panel_tui_bottom.txt");

    // Typing reaches the shell, never the document behind the panel;
    // Ctrl+` goes back to the editor (the panel stays), Ctrl+Shift+`
    // focuses it again without opening another shell, and a click on the
    // band does the same.
    testType(&editor, "ls");
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    testKey(&editor, '`', .{ .ctrl = true });
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(editor.terminal_panel_visible);
    testFrame(win, &editor);
    try t.expectEqualStrings(" Terminal \u{2014} Ctrl+Shift+` focuses ", testCells(&screen, 0, 17, 33, &buf));
    testKey(&editor, '`', .{ .ctrl = true, .shift = true });
    try t.expectEqual(Editor.KeyboardOwner.terminal_panel, editor.keyboardOwner());
    try t.expectEqual(@as(usize, 1), editor.terminals.items.len);
    testKey(&editor, '`', .{ .ctrl = true });
    testClick(&editor, 50, 20);
    try t.expectEqual(Editor.KeyboardOwner.terminal_panel, editor.keyboardOwner());
    testClick(&editor, 50, 5);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());

    // On the right: a full-height column, tui_terminal_panel_width wide,
    // its separator column facing the panes; on the left the mirror image.
    try t.expect(editor.execAction("move_terminal_panel_right"));
    testFrame(win, &editor);
    band = terminal_panel_band.?;
    try t.expectEqual(@as(u16, 40), band.x);
    try t.expectEqual(@as(u16, 0), band.y);
    try t.expectEqual(@as(u16, 60), band.w);
    try t.expectEqual(@as(u16, 29), band.h);
    try t.expectEqual(@as(u16, 41), band.grid_x);
    try t.expectEqual(@as(u16, 59), band.grid_w);
    try t.expectEqual(@as(u16, 1), band.grid_y);
    try t.expectEqual(@as(u16, 28), band.grid_h);
    try t.expectEqual(@as(u16, 40), pane_rects[0].w);
    try t.expectEqual(@as(u16, 29), pane_rects[0].h);
    try t.expectEqualStrings("\u{2502}", testCells(&screen, 40, 10, 1, &buf));
    try t.expect(editor.execAction("move_terminal_panel_left"));
    testFrame(win, &editor);
    band = terminal_panel_band.?;
    try t.expectEqual(@as(u16, 0), band.x);
    try t.expectEqual(@as(u16, 0), band.grid_x);
    try t.expectEqual(@as(u16, 60), pane_rects[0].x);
    try t.expectEqualStrings("\u{2502}", testCells(&screen, 59, 10, 1, &buf));

    // Beside the tree (left, 30 columns) the panel sits inward of it and
    // keeps the panes 40 columns: 30 wide.
    editor.filetree_root = try t.allocator.dupe(u8, root);
    editor.filetree_visible = true;
    testFrame(win, &editor);
    band = terminal_panel_band.?;
    try t.expectEqual(@as(u16, 0), filetree_band.?.x);
    try t.expectEqual(@as(u16, 30), band.x);
    try t.expectEqual(@as(u16, 30), band.w);
    try t.expectEqual(@as(u16, 60), pane_rects[0].x);
    try t.expectEqual(@as(u16, 40), pane_rects[0].w);
    try testCaptureScreen(&screen, "terminal_panel_tui_left.txt");

    // Too narrow for the tree, the panel and 40 columns of panes: the
    // panel hides itself, says so, and its keyboard goes back to the pane.
    try t.expect(editor.takeKeyboardFocus(.terminal_panel));
    frameArenaReset();
    drawEditor(win, &editor, 70, 30);
    try t.expect(terminal_panel_band == null);
    try t.expect(!editor.terminal_panel_visible and !editor.terminal_panel_focused);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(std.mem.indexOf(u8, editor.status_message, "no room") != null);
    // The shell is still docked: the toggle shows the panel again.
    try t.expect(editor.execAction("toggle_terminal_panel"));
    try t.expect(editor.terminal_panel_visible);
    try t.expectEqual(@as(?usize, 0), editor.terminal_panel);
}

test "TUI snippets panel: the preview wraps long code, highlights the blanks and scrolls long notes" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    _ = try editor.registerSnippet(.{ .language = "zig", .description = "Long", .group = "Start here", .notes = "Long notes, longer than the preview can show at once. " ** 30, .body = "const value = some_function(argument_one, ${1:argument_two});" });
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("zig");
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    var buf: [256]u8 = undefined;
    _ = editor.takeKeyboardFocus(.snippets);
    testFrame(win, &editor);
    editor.snippet_panel.selected = 1;
    testFrame(win, &editor);
    const band = snippets_band.?;
    const tx = band.x + 1;
    const code_y = band.preview_y + 1;

    // The 57-column line wraps to the 31-column band at its spaces: the
    // continued rows sit two cells in, on the code background, and the
    // blank is highlighted where it lands.
    try t.expectEqualStrings("const value =", testCells(&screen, tx, code_y, 13, &buf));
    try t.expectEqualStrings("  some_function(", testCells(&screen, tx, code_y + 1, 16, &buf));
    try t.expectEqualStrings("  argument_two);", testCells(&screen, tx, code_y + 2, 16, &buf));
    try t.expect(std.meta.eql(toVaxis(editor.tui_theme.selection_bg), screen.readCell(tx + 2, code_y + 2).?.style.bg));
    try t.expect(std.meta.eql(toVaxis(editor.tui_theme.overlay_bg), screen.readCell(tx, code_y + 2).?.style.bg));
    try testCaptureScreen(&screen, "snippets_tui_preview.txt");

    // The notes overflow: the last row says how to see more. Shift+Down
    // scrolls one row, Shift+PageDown a page, the wheel over the preview
    // three; far past the end it stops at the end and the marker goes.
    try t.expect(snippets_preview_overflow > 0);
    const last_y = band.y + band.h - 1;
    try t.expectEqualStrings("\u{25bc}", testCells(&screen, tx, last_y, 1, &buf));
    testKey(&editor, Key.down, .{ .shift = true });
    try t.expectEqual(@as(usize, 1), snippets_preview_scroll);
    testKey(&editor, Key.page_down, .{ .shift = true });
    try t.expectEqual(1 + snippets_preview_rows, snippets_preview_scroll);
    handleMouse(&editor, .{ .row = @intCast(last_y), .col = @intCast(tx + 3), .button = .wheel_down, .type = .press, .mods = .{} });
    try t.expectEqual(4 + snippets_preview_rows, snippets_preview_scroll);
    testFrame(win, &editor);
    try t.expect(snippets_preview_scroll <= snippets_preview_overflow);
    for (0..100) |_| testKey(&editor, Key.down, .{ .shift = true });
    testFrame(win, &editor);
    try t.expectEqual(snippets_preview_overflow, snippets_preview_scroll);
    try t.expect(!std.mem.eql(u8, "\u{25bc}", testCells(&screen, tx, last_y, 1, &buf)));
    // The wheel over the rows scrolls the list, not the preview (two rows:
    // it stays at the top).
    handleMouse(&editor, .{ .row = 2, .col = @intCast(tx + 3), .button = .wheel_down, .type = .press, .mods = .{} });
    testFrame(win, &editor);
    try t.expectEqual(@as(usize, 0), editor.snippet_panel.scroll);
    try t.expectEqual(snippets_preview_overflow, snippets_preview_scroll);
    // Another selection starts the preview at its top: Up onto the group
    // shows no preview at all.
    testKey(&editor, Key.up, .{});
    testFrame(win, &editor);
    try t.expectEqual(@as(usize, 0), snippets_preview_scroll);
    try t.expectEqual(@as(?u32, null), snippets_preview_def);
    try t.expectEqualStrings("Select a snippet", testCells(&screen, tx, code_y, 16, &buf));
}

test "TUI snippets panel: typing filters and the header shows it, F2 opens the edit form, Delete asks [Y]es" {
    const t = std.testing;
    const lua_settings = @import("../core/lua_settings.zig");
    const snippet_file = @import("../core/snippet_file.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    lua_settings.test_config_dir = root;
    defer lua_settings.test_config_dir = null;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    _ = try editor.registerSnippet(.{ .language = "zig", .description = "Print", .group = "Start here", .notes = "Writes text to the terminal.", .body = "std.debug.print(\"${1:text}\n\", .{${2:values}});" });
    _ = try editor.registerSnippet(.{ .language = "zig", .description = "Constant", .group = "Start here", .notes = "A value that never changes.", .body = "const ${1:name}: ${2:i32} = ${3:0};" });
    _ = try editor.registerSnippet(.{ .language = "zig", .prefix = "fn", .description = "Function", .group = "Functions", .notes = "A named block of code.", .body = "fn ${1:name}($2) ${3:void} {\n\t$0\n}" });
    // One of my own, registered as my-snippets.lua registers it, with its
    // block in that file for the delete to remove.
    const mine = "snippet.zig.~loop";
    const mine_spec: snippets_mod.Spec = .{ .language = "zig", .description = "Loop", .group = "Mine", .notes = "Runs once per item.", .body = "for (${1:items}) |${2:item}| {\n\t$0\n}" };
    editor.loading_extensions = true;
    editor.loading_extension_name = snippet_file.file_name;
    _ = try editor.registerSnippet(mine_spec);
    editor.loading_extensions = false;
    editor.loading_extension_name = null;
    try t.expect(snippet_file.isMine(editor.snippets.command(mine).?));
    const path = try std.fs.path.join(t.allocator, &.{ root, "extensions", snippet_file.file_name });
    defer t.allocator.free(path);
    {
        const block = try snippet_file.renderBlock(t.allocator, mine, mine_spec);
        defer t.allocator.free(block);
        const text = try snippet_file.upsert(t.allocator, "", mine, block);
        defer t.allocator.free(text);
        try snippet_file.write(t.allocator, t.io, path, text);
    }
    const marker = snippet_file.marker_prefix ++ mine;
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("zig");
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    var buf: [512]u8 = undefined;
    const panel = &editor.snippet_panel;

    // Typing filters: only the matches show, under their open groups, the
    // first one selected; the header shows the text after a slash, and
    // the document behind is never touched.
    try t.expect(editor.takeKeyboardFocus(.snippets));
    testFrame(win, &editor);
    const tx = snippets_band.?.x + 1;
    try t.expectEqualStrings("Snippets \u{2014} zig ", testCells(&screen, tx, 0, 15, &buf));
    try t.expectEqual(@as(usize, 5), panel.rows.items.len);
    testType(&editor, "fun");
    try t.expectEqualStrings("fun", panel.filterText());
    try t.expectEqual(@as(usize, 2), panel.rows.items.len);
    try t.expectEqual(@as(usize, 1), panel.selected);
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    testFrame(win, &editor);
    try t.expectEqualStrings("Snippets \u{2014} zig  /fun ", testCells(&screen, tx, 0, 21, &buf));
    try t.expectEqualStrings("\u{25be} Functions", testCells(&screen, tx, 1, 11, &buf));
    try t.expectEqualStrings("\u{2502}  Function", testCells(&screen, tx, 2, 11, &buf));
    try testCaptureScreen(&screen, "snippets_tui_filter.txt");

    // Backspace edits the filter: three take it away, every row is back.
    for (0..3) |_| testKey(&editor, Key.backspace, .{});
    try t.expect(!panel.filterActive());
    try t.expectEqual(@as(usize, 5), panel.rows.items.len);

    // No match: no rows, and the hint says how to get out of it.
    testType(&editor, "zzz");
    try t.expectEqual(@as(usize, 0), panel.rows.items.len);
    testFrame(win, &editor);
    try t.expectEqualStrings("Snippets \u{2014} zig  /zzz", testCells(&screen, tx, 0, 20, &buf));
    try t.expect(std.mem.indexOf(u8, testCells(&screen, tx, 1, 31, &buf), "Backspace") != null);

    // Escape clears the filter; the panel keeps the keys.
    testKey(&editor, Key.escape, .{});
    try t.expect(!panel.filterActive());
    try t.expectEqual(@as(usize, 5), panel.rows.items.len);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());

    // The filter takes plain keys only: a key that arrives without text
    // types its character, a functional key types nothing, and a bound
    // chord still runs from the panel (Ctrl+Alt+B hides it) without
    // typing; the filter is still there when the panel comes back.
    testKey(&editor, 'c', .{});
    testKey(&editor, Key.insert, .{});
    testKey(&editor, Key.tab, .{});
    testType(&editor, "on");
    testKey(&editor, 'b', .{ .ctrl = true, .alt = true });
    try t.expect(!editor.snippets_visible);
    try t.expectEqualStrings("con", editor.snippets_filter[0..editor.snippets_filter_len]);
    testKey(&editor, 'b', .{ .ctrl = true, .alt = true });
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    testFrame(win, &editor);
    try t.expectEqualStrings("Snippets \u{2014} zig  /con", testCells(&screen, tx, 0, 20, &buf));
    testKey(&editor, Key.escape, .{});
    try t.expect(!panel.filterActive());

    // F2 on a snippet of my-snippets.lua opens the edit form, on any other
    // the copy form; Escape leaves either, the panel keeping the keys.
    // End and Right open the Mine group, Down selects Loop.
    testKey(&editor, Key.end, .{});
    testKey(&editor, Key.right, .{});
    testKey(&editor, Key.down, .{});
    try t.expectEqual(@as(usize, 5), panel.selected);
    testKey(&editor, Key.f2, .{});
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    try t.expectEqual(snippet_form_mod.Kind.edit, editor.snippet_form.kind);
    try t.expectEqualStrings("Loop", editor.snippet_form.text(.name));
    testFrame(win, &editor);
    try t.expectEqualStrings("Edit snippet", testCells(&screen, 0, snippet_form_band.?.y, 12, &buf));
    testKey(&editor, Key.escape, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    panel.selected = 1;
    testKey(&editor, Key.f2, .{});
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    try t.expectEqual(snippet_form_mod.Kind.copy, editor.snippet_form.kind);
    try t.expectEqualStrings("Print", editor.snippet_form.text(.name));
    testKey(&editor, Key.escape, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);

    // Delete on mine asks on the status line (the run loop draws the
    // prompt over the status bar after drawEditor; the same call here).
    // Any key but y cancels.
    panel.selected = 5;
    testKey(&editor, Key.delete, .{});
    try t.expectEqual(Editor.Mode.snippet_delete_confirm, editor.mode);
    testFrame(win, &editor);
    var prompt_buf: [256]u8 = undefined;
    drawOverlay(win, &editor, editor.snippetDeletePrompt(&prompt_buf), "", 100, 30);
    try t.expect(std.mem.indexOf(u8, testCells(&screen, 0, 29, 100, &buf), "Delete snippet \"Loop\"") != null);
    testKey(&editor, 'n', .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.snippets.command(mine) != null);
    {
        const kept = try snippet_file.read(t.allocator, t.io, path);
        defer t.allocator.free(kept);
        try t.expect(std.mem.indexOf(u8, kept, marker) != null);
    }

    // y deletes: the block leaves the file and the snippet the panel.
    testKey(&editor, Key.delete, .{});
    try t.expectEqual(Editor.Mode.snippet_delete_confirm, editor.mode);
    testKey(&editor, 'y', .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.snippets.command(mine) == null);
    try t.expectEqualStrings("Deleted from my-snippets.lua: Loop", editor.status_message);
    {
        const left = try snippet_file.read(t.allocator, t.io, path);
        defer t.allocator.free(left);
        try t.expect(std.mem.indexOf(u8, left, marker) == null);
    }
    testFrame(win, &editor);
    try t.expectEqual(@as(usize, 4), panel.rows.items.len);

    // Only mine can be deleted here: Delete on another says so on the
    // status line. F2 on a group asks for a snippet.
    panel.selected = 1;
    testKey(&editor, Key.delete, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.startsWith(u8, editor.status_message, "Only snippets in my-snippets.lua"));
    try t.expect(editor.snippets.command("snippet.zig.~print") != null);
    panel.selected = 0;
    testKey(&editor, Key.f2, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqualStrings("Select a snippet first", editor.status_message);
}

test "TUI snippet form: Ctrl+Alt+S shows the bottom form prefilled, Tab cycles the fields, Backspace edits, Enter saves and Escape cancels" {
    const t = std.testing;
    const lua_settings = @import("../core/lua_settings.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    lua_settings.test_config_dir = root;
    defer lua_settings.test_config_dir = null;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("zig");
    const code = "    for (items) |item| {\n        use(item);\n    }\n";
    try doc.loadText(code);
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    var buf: [256]u8 = undefined;
    const form = &editor.snippet_form;
    const Field = snippet_form_mod.Field;

    // Nothing selected: refused on the status line, and no band.
    testKey(&editor, 's', .{ .ctrl = true, .alt = true });
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqualStrings("Save as snippet: select the code first", editor.status_message);
    testFrame(win, &editor);
    try t.expect(snippet_form_band == null);

    // A selection: eight rows right above the status bar, the panes above
    // them. Name is active, the caret at its end; Folder and Language are
    // prefilled; then the body's size and the keys.
    _ = editor.execCommand("select_all", null);
    testKey(&editor, 's', .{ .ctrl = true, .alt = true });
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    testFrame(win, &editor);
    const band = snippet_form_band.?;
    try t.expectEqual(@as(u16, 8), band.h);
    try t.expectEqual(@as(u16, 29), band.y + band.h);
    try t.expectEqual(band.y, pane_rects[0].h);
    try t.expectEqualStrings("Save as snippet \u{2014} my-snippets.lua", testCells(&screen, 0, band.y, 33, &buf));
    try t.expectEqualStrings("Name     _", testCells(&screen, 0, band.y + 1, 10, &buf));
    try t.expect(screen.readCell(0, band.y + 1).?.style.reverse);
    try t.expectEqualStrings("Folder   Mine ", testCells(&screen, 0, band.y + 2, 14, &buf));
    try t.expect(!screen.readCell(0, band.y + 2).?.style.reverse);
    try t.expectEqualStrings("Trigger   ", testCells(&screen, 0, band.y + 3, 10, &buf));
    try t.expectEqualStrings("Language zig ", testCells(&screen, 0, band.y + 4, 13, &buf));
    try t.expectEqualStrings("Notes     ", testCells(&screen, 0, band.y + 5, 10, &buf));
    try t.expectEqualStrings("Body     3 lines \u{2014} add blanks like ${1:text} and $0 by editing my-snippets.lua", testCells(&screen, 0, band.y + 6, 78, &buf));
    try t.expectEqualStrings("Enter saves \u{00b7} Tab/Shift+Tab fields \u{00b7} Esc cancels", testCells(&screen, 0, band.y + 7, 48, &buf));
    try t.expect(screen.cursor_vis);
    try t.expectEqual(@as(u16, 9), screen.cursor.col);
    try t.expectEqual(band.y + 1, screen.cursor.row);

    // Enter with no name: the form stays, its error on the keys' row.
    testKey(&editor, Key.enter, .{});
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    try t.expect(form.error_message.len > 0);
    testFrame(win, &editor);
    try t.expectEqualStrings(form.error_message, testCells(&screen, 0, band.y + 7, @intCast(form.error_message.len), &buf));
    try t.expect(std.meta.eql(toVaxis(editor.tui_theme.overlay_warn), screen.readCell(0, band.y + 7).?.style.fg));

    // Typing fills Name; Tab / Shift+Tab (and Down / Up, wrapping around)
    // move between the fields; Backspace edits the active one. The
    // document behind the form is never touched.
    testType(&editor, "My loop");
    try t.expectEqualStrings("My loop", form.text(.name));
    testKey(&editor, Key.tab, .{});
    try t.expectEqual(Field.folder, form.field);
    testKey(&editor, Key.tab, .{ .shift = true });
    try t.expectEqual(Field.name, form.field);
    testKey(&editor, Key.up, .{});
    try t.expectEqual(Field.notes, form.field);
    testKey(&editor, Key.down, .{});
    try t.expectEqual(Field.name, form.field);
    testKey(&editor, Key.backspace, .{});
    try t.expectEqualStrings("My loo", form.text(.name));
    testType(&editor, "p");
    try t.expectEqualStrings("My loop", form.text(.name));
    try t.expectEqualStrings(code, doc.buffer.slice(0, doc.buffer.byteLen()));

    // A click on a field row moves the typing there; a paste types its
    // first line into the active field.
    testClick(&editor, 20, band.y + 5);
    try t.expectEqual(Field.notes, form.field);
    applyPaste(&editor, "Runs the body once per item.\nNot this line.");
    try t.expectEqualStrings("Runs the body once per item.", form.text(.notes));
    testFrame(win, &editor);
    try t.expectEqualStrings("Name     My loop ", testCells(&screen, 0, band.y + 1, 17, &buf));
    try t.expectEqualStrings("Notes    Runs the body once per item._", testCells(&screen, 0, band.y + 5, 38, &buf));
    try t.expectEqual(@as(u16, 37), screen.cursor.col);
    try t.expectEqual(band.y + 5, screen.cursor.row);
    try testCaptureScreen(&screen, "snippet_form_tui.txt");

    // Enter saves: the band goes, the status line says where, and the
    // block is in <config>/extensions/my-snippets.lua.
    testKey(&editor, Key.enter, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.startsWith(u8, editor.status_message, "Saved to my-snippets.lua"));
    try t.expect(editor.snippets.command("snippet.zig.~my-loop") != null);
    const path = try std.fs.path.join(t.allocator, &.{ root, "extensions", "my-snippets.lua" });
    defer t.allocator.free(path);
    const saved = try std.Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(1 << 20));
    defer t.allocator.free(saved);
    try t.expect(std.mem.indexOf(u8, saved, "-- zide:snippet snippet.zig.~my-loop") != null);
    try t.expect(std.mem.indexOf(u8, saved, "Runs the body once per item.") != null);
    testFrame(win, &editor);
    try t.expect(snippet_form_band == null);
    try t.expectEqual(@as(u16, 29), pane_rects[0].h);

    // Open it again and Escape: the band goes and nothing is written.
    _ = editor.execCommand("select_all", null);
    testKey(&editor, 's', .{ .ctrl = true, .alt = true });
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    testType(&editor, "Never saved");
    testKey(&editor, Key.escape, .{});
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqualStrings("", form.text(.name));
    try t.expect(editor.snippets.command("snippet.zig.~never-saved") == null);
    const after = try std.Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(1 << 20));
    defer t.allocator.free(after);
    try t.expectEqualStrings(saved, after);
    testFrame(win, &editor);
    try t.expect(snippet_form_band == null);
}

test "TUI snippet form: a short band drops the keys row, then the body row, keeps the error in view and scrolls to the active field" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    try t.expect(editor.takeKeyboardFocus(.search));
    try editor.activeDoc().loadText("x = 1;\n");
    _ = editor.execCommand("select_all", null);
    editor.startSnippetSave();
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    const form = &editor.snippet_form;
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    var buf: [256]u8 = undefined;

    // Beside the search panel 30 rows leave the band seven, right above
    // the panel (whose field no longer looks focused: the form has the
    // keys). The keys row goes first, and an error takes the body's.
    testFrame(win, &editor);
    var band = snippet_form_band.?;
    try t.expectEqual(@as(u16, 7), band.h);
    try t.expectEqual(search_band.?.y, band.y + band.h);
    try t.expect(!screen.readCell(0, search_band.?.y).?.style.reverse);
    try t.expectEqualStrings("Body     1 line ", testCells(&screen, 0, band.y + 6, 16, &buf));
    form.error_message = "Snippet needs a name";
    testFrame(win, &editor);
    try t.expectEqualStrings("Snippet needs a name", testCells(&screen, 0, band.y + 6, 20, &buf));

    // Six rows: no body row; the error goes to the end of the title row.
    frameArenaReset();
    drawEditor(win, &editor, 100, 25);
    band = snippet_form_band.?;
    try t.expectEqual(@as(u16, 6), band.h);
    try t.expectEqualStrings("Snippet needs a name", testCells(&screen, 79, band.y, 20, &buf));
    try t.expectEqualStrings("Notes    ", testCells(&screen, 0, band.y + 5, 9, &buf));

    // Four rows: the three field rows follow the active field, and a click
    // picks the field drawn on its row (the title row picks none).
    form.field = .notes;
    frameArenaReset();
    drawEditor(win, &editor, 100, 19);
    band = snippet_form_band.?;
    try t.expectEqual(@as(u16, 4), band.h);
    try t.expectEqualStrings("Trigger  ", testCells(&screen, 0, band.y + 1, 9, &buf));
    try t.expectEqualStrings("Notes    _", testCells(&screen, 0, band.y + 3, 10, &buf));
    try t.expectEqual(band.y + 3, screen.cursor.row);
    testClick(&editor, 4, band.y + 1);
    try t.expectEqual(snippet_form_mod.Field.trigger, form.field);
    testClick(&editor, 4, band.y);
    try t.expectEqual(snippet_form_mod.Field.trigger, form.field);

    // A value wider than its row keeps its end, where typing lands, in view.
    form.field = .notes;
    form.set(.notes, "word " ** 40);
    testFrame(win, &editor);
    band = snippet_form_band.?;
    const notes_y = band.y + 5;
    try t.expectEqualStrings("Notes    \u{2026}ord ", testCells(&screen, 0, notes_y, 14, &buf));
    try t.expectEqualStrings("word _", testCells(&screen, 94, notes_y, 6, &buf));
    try t.expect(screen.cursor_vis);
    try t.expectEqual(@as(u16, 99), screen.cursor.col);
    try t.expectEqual(notes_y, screen.cursor.row);
}

test "TUI terminal: after the shell exits, the next key closes the pane" {
    const cmd = switch (builtin.os.tag) {
        .windows => "cmd.exe /c exit",
        .linux => "true",
        else => return error.SkipZigTest,
    };
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    const term = try terminal_mod.Terminal.init(t.allocator, t.io, 40, 5, cmd);
    try editor.terminals.append(t.allocator, term);
    editor.windows.items[0].layout.panes.items[0].content = .{ .terminal = 0 };
    try t.expect(editor.activePaneIsTerminal());
    // Wait for the shell to end (the exit watcher sets `exited`).
    var exited = false;
    var waited: usize = 0;
    while (!exited and waited < 10_000) : (waited += 20) {
        try std.Io.sleep(t.io, .fromMilliseconds(20), .awake);
        term.mutex.lockUncancelable(term.io);
        exited = term.exited;
        term.mutex.unlock(term.io);
    }
    try t.expect(exited);
    var screen = try testScreen(t.allocator);
    defer screen.deinit(t.allocator);
    const win = testWin(&screen);
    testFrame(win, &editor);
    // The status bar says what the next key does; then a plain key closes
    // the pane, which shows the document again, and frees the slot.
    var buf: [512]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, testCells(&screen, 0, 29, 100, &buf), "press a key to close") != null);
    testKey(&editor, 'a', .{});
    try t.expect(!editor.activePaneIsTerminal());
    try t.expect(editor.terminals.items[0] == null);
    testFrame(win, &editor);
    try t.expect(std.mem.indexOf(u8, testCells(&screen, 0, 29, 100, &buf), "TERMINAL") == null);
}
