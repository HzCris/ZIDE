//! The embedded terminal: a grid of cells fed by a reader thread that parses
//! what the shell writes (`ansi.zig`) to a pseudo-terminal (`pty.zig`), and
//! the encoding of the keys sent back to it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
const Pty = @import("pty.zig").Pty;

const is_windows = builtin.os.tag == .windows;

/// ZIDE's key codes for `Terminal.encodeKey` (the frontends map their own
/// key enums onto these). Printable keys are plain code points.
pub const key_up: u21 = 0xF700;
pub const key_down: u21 = 0xF701;
pub const key_left: u21 = 0xF702;
pub const key_right: u21 = 0xF703;
pub const key_home: u21 = 0xF704;
pub const key_end: u21 = 0xF705;
pub const key_page_up: u21 = 0xF706;
pub const key_page_down: u21 = 0xF707;
pub const key_insert: u21 = 0xF708;
pub const key_delete: u21 = 0xF709;
/// F1..F12 are `key_f1 + 0` .. `key_f1 + 11`.
pub const key_f1: u21 = 0xF710;
pub const key_f12: u21 = key_f1 + 11;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const default_fg = Color{ .r = 0xCC, .g = 0xCC, .b = 0xCC };
    pub const default_bg = Color{ .r = 0x1E, .g = 0x1E, .b = 0x24 };
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    fg: Color = Color.default_fg,
    bg: Color = Color.default_bg,
    bold: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

/// Standard 8 ANSI colors + bright variants.
const ansi_colors = [16]Color{
    .{ .r = 0x00, .g = 0x00, .b = 0x00 }, // 0 black
    .{ .r = 0xAA, .g = 0x00, .b = 0x00 }, // 1 red
    .{ .r = 0x00, .g = 0xAA, .b = 0x00 }, // 2 green
    .{ .r = 0xAA, .g = 0xAA, .b = 0x00 }, // 3 yellow
    .{ .r = 0x00, .g = 0x00, .b = 0xAA }, // 4 blue
    .{ .r = 0xAA, .g = 0x00, .b = 0xAA }, // 5 magenta
    .{ .r = 0x00, .g = 0xAA, .b = 0xAA }, // 6 cyan
    .{ .r = 0xAA, .g = 0xAA, .b = 0xAA }, // 7 white
    .{ .r = 0x55, .g = 0x55, .b = 0x55 }, // 8 bright black
    .{ .r = 0xFF, .g = 0x55, .b = 0x55 }, // 9 bright red
    .{ .r = 0x55, .g = 0xFF, .b = 0x55 }, // 10 bright green
    .{ .r = 0xFF, .g = 0xFF, .b = 0x55 }, // 11 bright yellow
    .{ .r = 0x55, .g = 0x55, .b = 0xFF }, // 12 bright blue
    .{ .r = 0xFF, .g = 0x55, .b = 0xFF }, // 13 bright magenta
    .{ .r = 0x55, .g = 0xFF, .b = 0xFF }, // 14 bright cyan
    .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, // 15 bright white
};

pub const Terminal = struct {
    allocator: Allocator,
    pty: Pty,
    parser: ansi.Parser = .{},
    cells: []Cell,
    cols: u16,
    rows: u16,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_visible: bool = true,
    scroll_top: u16 = 0,
    scroll_bottom: u16,

    // Current SGR attributes
    current_fg: Color = Color.default_fg,
    current_bg: Color = Color.default_bg,
    current_bold: bool = false,
    current_underline: bool = false,
    current_reverse: bool = false,

    // Alternate screen buffer
    alt_cells: ?[]Cell = null,
    alt_cursor_row: u16 = 0,
    alt_cursor_col: u16 = 0,
    in_alt_screen: bool = false,

    // Saved cursor (DECSC/DECRC)
    saved_cursor_row: u16 = 0,
    saved_cursor_col: u16 = 0,

    // Input modes the program in the terminal switched on. Written by the
    // reader thread under `mutex`; frontends read them through
    // `appCursorKeys` / `paste` when they encode input.
    /// DECCKM (CSI ? 1 h): unmodified cursor keys send SS3 (ESC O A) —
    /// what ncurses programs expect after smkx with TERM=xterm-256color.
    app_cursor_keys: bool = false,
    /// CSI ? 2004 h: pastes are wrapped in ESC [200~ ... ESC [201~.
    bracketed_paste: bool = false,

    // Thread safety. The mutex is std.Io-based (0.16): lock/unlock take the
    // Io instance stored below; lockUncancelable keeps call sites infallible.
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    reader_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    // Whether the shell process has exited
    exited: bool = false,

    /// Windows: thread-pool wait that fires when the shell process exits.
    /// ConPTY keeps the output pipe open after its client is gone, so the
    /// reader would never see EOF on its own (see `onChildExit`).
    exit_wait: if (is_windows) ?std.os.windows.HANDLE else void = if (is_windows) null else {},

    /// Optional wake callback, fired from the reader thread after new output
    /// lands in the grid. The TUI uses it to unblock its blocking event loop
    /// (same pattern as LspClient.tui_wake_fn); the GUI repaints on its own
    /// cadence and leaves it null.
    wake_fn: ?*const fn () void = null,

    /// GUI measurement debounce (terminalPane): a pane size seen once is
    /// remembered here and applied only when the next frame repeats it — a
    /// window's or split's first frame reports a zero-height layout.
    pending_cols: u16 = 0,
    pending_rows: u16 = 0,

    pub fn init(allocator: Allocator, io: std.Io, cols: u16, rows: u16, command: []const u8) !*Terminal {
        const total = @as(usize, cols) * @as(usize, rows);
        const cells = try allocator.alloc(Cell, total);
        errdefer allocator.free(cells);
        @memset(cells, Cell{});

        const term = try allocator.create(Terminal);
        errdefer allocator.destroy(term);

        // Last fallible step: nothing after the spawn can fail, so a
        // started shell is never leaked.
        const pty = try Pty.spawn(allocator, command, cols, rows);
        term.* = .{
            .allocator = allocator,
            .io = io,
            .pty = pty,
            .cells = cells,
            .cols = cols,
            .rows = rows,
            .scroll_bottom = rows -| 1,
        };

        // Windows: learn when the shell exits (no exit detection when the
        // wait cannot be registered — the pane then stays as before).
        if (is_windows) {
            if (term.pty.process_handle) |process| {
                var wait: ?std.os.windows.HANDLE = null;
                if (RegisterWaitForSingleObject(&wait, process, onChildExit, term, win_infinite, wt_execute_only_once) != 0) {
                    term.exit_wait = wait;
                }
            }
        }

        // Start reader thread
        term.reader_thread = std.Thread.spawn(.{}, readerThreadFn, .{term}) catch null;

        return term;
    }

    pub fn deinit(self: *Terminal) void {
        self.running.store(false, .release);
        // Windows: retire the exit watcher first — this waits for a callback
        // in flight, so none can run against the freed terminal.
        if (is_windows) {
            if (self.exit_wait) |wait| _ = UnregisterWaitEx(wait, std.os.windows.INVALID_HANDLE_VALUE);
        }
        // Unblock the reader (Windows: close the pseudo console → EOF;
        // Linux: its shutdown pipe) and join it BEFORE the PTY handles close,
        // so it never reads from a closed (or reused) handle and always
        // returns — even when another process still holds the PTY slave.
        self.pty.shutdown();
        if (self.reader_thread) |t| t.join();
        // Stop the child and release the PTY
        self.pty.deinit();
        // Free cells
        self.allocator.free(self.cells);
        if (self.alt_cells) |ac| self.allocator.free(ac);
        self.allocator.destroy(self);
    }

    /// Process raw output bytes from the PTY (parses ANSI and updates grid).
    /// Caller must hold mutex.
    pub fn processOutput(self: *Terminal, data: []const u8) void {
        for (data) |byte| {
            if (self.parser.feed(byte)) |action| {
                self.handleAction(action);
            }
        }
    }

    /// Send input data to the PTY.
    pub fn writeInput(self: *Terminal, data: []const u8) void {
        self.pty.write(data) catch {};
    }

    /// Whether the program asked for application cursor keys (DECCKM) —
    /// pass it to `encodeKeyMode`.
    pub fn appCursorKeys(self: *Terminal) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.app_cursor_keys;
    }

    /// Paste `text` into the program: line breaks become CR (what a typed
    /// Enter sends), and when the program enabled bracketed paste the text
    /// is wrapped in ESC [200~ ... ESC [201~ with any ESC inside dropped, so
    /// pasted bytes can never end the paste early and run as keystrokes.
    pub fn paste(self: *Terminal, text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        const bracketed = self.bracketed_paste;
        self.mutex.unlock(self.io);
        writePaste(text, bracketed, self, writeInput);
    }

    /// Resize terminal grid and PTY. Also resizes the saved screen when the
    /// alternate screen is active — otherwise leaving the alt screen would
    /// restore an old-sized buffer under the new cols/rows (out-of-bounds).
    pub fn resizeGrid(self: *Terminal, new_cols: u16, new_rows: u16) void {
        if (new_cols == self.cols and new_rows == self.rows) return;
        if (new_cols == 0 or new_rows == 0) return;
        std.log.info("terminal grid {d}x{d} -> {d}x{d}", .{ self.cols, self.rows, new_cols, new_rows });

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const new_total = @as(usize, new_cols) * @as(usize, new_rows);
        const new_cells = self.allocator.alloc(Cell, new_total) catch return;

        // Allocate the saved-screen replacement up front so we never end up
        // with the two buffers at different sizes.
        var new_saved: ?[]Cell = null;
        if (self.alt_cells != null) {
            new_saved = self.allocator.alloc(Cell, new_total) catch {
                self.allocator.free(new_cells);
                return;
            };
        }

        // Shrinking keeps the cursor line on screen: rows drop off the top
        // (as if scrolled away), not from under the prompt.
        const shift = rowsToDrop(self.cursor_row, new_rows);
        copyGrid(new_cells, new_cols, new_rows, self.cells, self.cols, self.rows, shift);
        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.cursor_row -|= shift;
        self.saved_cursor_row -|= shift;

        // Copy saved screen content (same old dimensions as the active one)
        if (new_saved) |saved| {
            const old_saved = self.alt_cells.?;
            const saved_shift = rowsToDrop(self.alt_cursor_row, new_rows);
            copyGrid(saved, new_cols, new_rows, old_saved, self.cols, self.rows, saved_shift);
            self.allocator.free(old_saved);
            self.alt_cells = saved;
            self.alt_cursor_row -|= saved_shift;
        }

        self.cols = new_cols;
        self.rows = new_rows;
        // A new size resets the scrolling region (both margins), as xterm does
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;
        if (self.cursor_row >= new_rows) self.cursor_row = new_rows -| 1;
        if (self.cursor_col >= new_cols) self.cursor_col = new_cols -| 1;
        if (self.alt_cursor_row >= new_rows) self.alt_cursor_row = new_rows -| 1;
        if (self.alt_cursor_col >= new_cols) self.alt_cursor_col = new_cols -| 1;
        if (self.saved_cursor_row >= new_rows) self.saved_cursor_row = new_rows -| 1;
        if (self.saved_cursor_col >= new_cols) self.saved_cursor_col = new_cols -| 1;

        // Resize PTY
        self.pty.resize(new_cols, new_rows);
    }

    /// Get cell without locking (caller must hold mutex).
    pub fn cellAtUnsafe(self: *const Terminal, row: u16, col: u16) Cell {
        if (row >= self.rows or col >= self.cols) return Cell{};
        return self.cells[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
    }

    /// Set cell at position (caller must hold mutex).
    fn setCellAt(self: *Terminal, row: u16, col: u16, cell: Cell) void {
        if (row >= self.rows or col >= self.cols) return;
        self.cells[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)] = cell;
    }

    // =========================================================================
    // Action handlers
    // =========================================================================

    fn handleAction(self: *Terminal, action: ansi.Action) void {
        switch (action) {
            .print => |cp| self.handlePrint(cp),
            .execute => |byte| self.handleExecute(byte),
            .csi => |csi| self.handleCsi(csi),
            .osc => {}, // Ignore OSC sequences (window title etc.)
            .esc => |final| switch (final) {
                '7' => { // DECSC — save cursor
                    self.saved_cursor_row = self.cursor_row;
                    self.saved_cursor_col = self.cursor_col;
                },
                '8' => { // DECRC — restore cursor
                    self.cursor_row = @min(self.saved_cursor_row, self.rows -| 1);
                    self.cursor_col = @min(self.saved_cursor_col, self.cols -| 1);
                },
                'M' => self.reverseIndex(), // RI
                'D' => self.cursorDown(), // IND
                'E' => { // NEL
                    self.cursor_col = 0;
                    self.cursorDown();
                },
                else => {},
            },
        }
    }

    fn handlePrint(self: *Terminal, cp: u21) void {
        if (self.cursor_col >= self.cols) {
            // Wrap to next line
            self.cursor_col = 0;
            self.cursorDown();
        }
        self.setCellAt(self.cursor_row, self.cursor_col, .{
            .codepoint = cp,
            .fg = self.current_fg,
            .bg = self.current_bg,
            .bold = self.current_bold,
            .underline = self.current_underline,
            .reverse = self.current_reverse,
        });
        self.cursor_col += 1;
    }

    fn handleExecute(self: *Terminal, byte: u8) void {
        switch (byte) {
            0x07 => {}, // BEL — ignore
            0x08 => { // BS — backspace
                if (self.cursor_col > 0) self.cursor_col -= 1;
            },
            0x09 => { // HT — tab
                self.cursor_col = @min(self.cols -| 1, (self.cursor_col + 8) & ~@as(u16, 7));
            },
            0x0A, 0x0B, 0x0C => { // LF, VT, FF
                self.cursorDown();
            },
            0x0D => { // CR
                self.cursor_col = 0;
            },
            else => {},
        }
    }

    fn handleCsi(self: *Terminal, csi: ansi.CsiParams) void {
        switch (csi.marker) {
            0 => {},
            '?' => return self.handlePrivateCsi(csi),
            // '>' '=' '<' sequences (modifyOtherKeys, DA2/DA3 queries, ...)
            // are not their unmarked namesakes — `CSI > 4;2 m` is not SGR 4.
            else => return,
        }

        switch (csi.final_byte) {
            'A' => self.cursorUpBy(csi.get(0, 1)), // Cursor Up
            'B' => self.cursorDownBy(csi.get(0, 1)), // Cursor Down
            'C' => { // Cursor Forward
                const n = csi.get(0, 1);
                self.cursor_col = @min(self.cols -| 1, self.cursor_col +| @as(u16, @intCast(n)));
            },
            'D' => { // Cursor Backward
                const n = csi.get(0, 1);
                self.cursor_col -|= @intCast(n);
            },
            'E' => { // Cursor Next Line
                self.cursor_col = 0;
                self.cursorDownBy(csi.get(0, 1));
            },
            'F' => { // Cursor Previous Line
                self.cursor_col = 0;
                self.cursorUpBy(csi.get(0, 1));
            },
            'G' => { // Cursor Horizontal Absolute
                const n = csi.get(0, 1);
                self.cursor_col = @min(self.cols -| 1, @as(u16, @intCast(n)) -| 1);
            },
            'H', 'f' => { // Cursor Position
                const row = csi.get(0, 1);
                const col = csi.get(1, 1);
                self.cursor_row = @min(self.rows -| 1, @as(u16, @intCast(row)) -| 1);
                self.cursor_col = @min(self.cols -| 1, @as(u16, @intCast(col)) -| 1);
            },
            'J' => self.handleEraseDisplay(csi),
            'K' => self.handleEraseLine(csi),
            'L' => self.handleInsertLines(csi),
            'M' => self.handleDeleteLines(csi),
            'P' => self.handleDeleteChars(csi),
            'S' => { // Scroll Up (clamp: > rows scrolls everything out anyway)
                const n = @min(csi.get(0, 1), self.rows);
                for (0..n) |_| self.scrollUp();
            },
            'T' => { // Scroll Down
                const n = @min(csi.get(0, 1), self.rows);
                for (0..n) |_| self.scrollDown();
            },
            'X' => { // Erase Characters
                const n = csi.get(0, 1);
                const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
                for (0..n) |i| {
                    const col = self.cursor_col +| @as(u16, @intCast(i));
                    if (col >= self.cols) break;
                    self.setCellAt(self.cursor_row, col, blank);
                }
            },
            'd' => { // Line Position Absolute (VPA)
                const n = csi.get(0, 1);
                self.cursor_row = @min(self.rows -| 1, @as(u16, @intCast(n)) -| 1);
            },
            'm' => self.handleSgr(csi),
            'r' => { // Set Scrolling Region (DECSTBM)
                const top = csi.get(0, 1);
                const bottom = csi.get(1, self.rows);
                if (top < 1 or bottom < 1 or top >= bottom or bottom > self.rows) return;
                self.scroll_top = @intCast(top - 1);
                self.scroll_bottom = @intCast(bottom - 1);
                self.cursor_row = 0;
                self.cursor_col = 0;
            },
            '@' => self.handleInsertChars(csi),
            else => {}, // Unhandled CSI
        }
    }

    fn handlePrivateCsi(self: *Terminal, csi: ansi.CsiParams) void {
        const set = switch (csi.final_byte) {
            'h' => true, // Set mode
            'l' => false, // Reset mode
            else => return,
        };
        // DECSET/DECRST take a list of modes (CSI ? 1049;1 h)
        var i: usize = 0;
        while (i < @max(csi.param_count, 1)) : (i += 1) {
            switch (csi.get(i, 0)) {
                1 => self.app_cursor_keys = set, // DECCKM
                25 => self.cursor_visible = set,
                1049 => if (set) self.enterAltScreen() else self.leaveAltScreen(),
                2004 => self.bracketed_paste = set,
                else => {},
            }
        }
    }

    fn handleEraseDisplay(self: *Terminal, csi: ansi.CsiParams) void {
        const mode = csi.get(0, 0);
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        switch (mode) {
            0 => { // Erase below (from cursor to end)
                // Clear rest of current line
                for (self.cursor_col..self.cols) |c| {
                    self.setCellAt(self.cursor_row, @intCast(c), blank);
                }
                // Clear all lines below
                for ((self.cursor_row + 1)..self.rows) |r| {
                    for (0..self.cols) |c| {
                        self.setCellAt(@intCast(r), @intCast(c), blank);
                    }
                }
            },
            1 => { // Erase above (from start to cursor)
                for (0..(self.cursor_row)) |r| {
                    for (0..self.cols) |c| {
                        self.setCellAt(@intCast(r), @intCast(c), blank);
                    }
                }
                for (0..(self.cursor_col + 1)) |c| {
                    self.setCellAt(self.cursor_row, @intCast(c), blank);
                }
            },
            2, 3 => { // Erase entire display
                @memset(self.cells, blank);
            },
            else => {},
        }
    }

    fn handleEraseLine(self: *Terminal, csi: ansi.CsiParams) void {
        const mode = csi.get(0, 0);
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        switch (mode) {
            0 => { // Erase right (from cursor to end of line)
                for (self.cursor_col..self.cols) |c| {
                    self.setCellAt(self.cursor_row, @intCast(c), blank);
                }
            },
            1 => { // Erase left (from start to cursor)
                for (0..(self.cursor_col + 1)) |c| {
                    self.setCellAt(self.cursor_row, @intCast(c), blank);
                }
            },
            2 => { // Erase entire line
                for (0..self.cols) |c| {
                    self.setCellAt(self.cursor_row, @intCast(c), blank);
                }
            },
            else => {},
        }
    }

    fn handleInsertLines(self: *Terminal, csi: ansi.CsiParams) void {
        // IL only acts when the cursor is inside the scroll region (per spec);
        // a cursor below the region would also underflow the count below.
        if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bottom) return;
        const max_n: usize = @as(usize, self.scroll_bottom - self.cursor_row) + 1;
        const n: usize = @min(@as(usize, csi.get(0, 1)), max_n);
        // Shift lines down (usize math — params are untrusted u16)
        var r: usize = self.scroll_bottom;
        while (r >= @as(usize, self.cursor_row) + n) : (r -= 1) {
            const src_row: u16 = @intCast(r - n);
            for (0..self.cols) |c| {
                const cell = self.cellAtUnsafe(src_row, @intCast(c));
                self.setCellAt(@intCast(r), @intCast(c), cell);
            }
            if (r == 0) break;
        }
        // Clear inserted lines
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        for (self.cursor_row..(self.cursor_row + n)) |row| {
            for (0..self.cols) |c| {
                self.setCellAt(@intCast(row), @intCast(c), blank);
            }
        }
    }

    fn handleDeleteLines(self: *Terminal, csi: ansi.CsiParams) void {
        // DL only acts when the cursor is inside the scroll region (per spec).
        if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bottom) return;
        const max_n: usize = @as(usize, self.scroll_bottom - self.cursor_row) + 1;
        const n: usize = @min(@as(usize, csi.get(0, 1)), max_n);
        // Shift lines up
        for (self.cursor_row..(@as(usize, self.scroll_bottom) + 1 - n)) |r| {
            const src_row: u16 = @intCast(r + n);
            for (0..self.cols) |c| {
                const cell = self.cellAtUnsafe(src_row, @intCast(c));
                self.setCellAt(@intCast(r), @intCast(c), cell);
            }
        }
        // Clear bottom lines
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        for ((@as(usize, self.scroll_bottom) + 1 - n)..(@as(usize, self.scroll_bottom) + 1)) |r| {
            for (0..self.cols) |c| {
                self.setCellAt(@intCast(r), @intCast(c), blank);
            }
        }
    }

    fn handleDeleteChars(self: *Terminal, csi: ansi.CsiParams) void {
        // usize math: c + n on u16 overflows for hostile params (e.g. \e[65535P)
        const n: usize = csi.get(0, 1);
        const row = self.cursor_row;
        // Shift chars left
        var c: usize = self.cursor_col;
        while (c + n < self.cols) : (c += 1) {
            const cell = self.cellAtUnsafe(row, @intCast(c + n));
            self.setCellAt(row, @intCast(c), cell);
        }
        // Clear end
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        while (c < self.cols) : (c += 1) {
            self.setCellAt(row, @intCast(c), blank);
        }
    }

    fn handleInsertChars(self: *Terminal, csi: ansi.CsiParams) void {
        if (self.cols == 0) return;
        // usize math: cursor_col + n on u16 overflows for hostile params
        const n: usize = csi.get(0, 1);
        const row = self.cursor_row;
        const limit = @as(usize, self.cursor_col) + n;
        // Shift chars right
        var c: usize = self.cols - 1;
        while (c >= limit) : (c -= 1) {
            const cell = self.cellAtUnsafe(row, @intCast(c - n));
            self.setCellAt(row, @intCast(c), cell);
            if (c == 0) break;
        }
        // Clear inserted positions
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        for (self.cursor_col..@min(limit, self.cols)) |cc| {
            self.setCellAt(row, @intCast(cc), blank);
        }
    }

    fn handleSgr(self: *Terminal, csi: ansi.CsiParams) void {
        // If no params, treat as reset
        if (csi.param_count == 0) {
            self.resetSgr();
            return;
        }

        var i: u8 = 0;
        while (i < csi.param_count) : (i += 1) {
            const p = csi.params[i];
            // Colon sub-parameters belong to `p`: `4:3` is an undercurl, not
            // SGR 4 + SGR 3 (and before sub-parameters were parsed it read
            // as SGR 43, a yellow background).
            var subs: u8 = 0;
            while (csi.isSub(i + 1 + subs)) subs += 1;
            if (subs > 0) {
                const sub = csi.params[i + 1 ..][0..subs];
                switch (p) {
                    4 => self.current_underline = sub[0] != 0, // 4:0 off, 4:1..5 styles
                    38 => if (extendedColor(sub)) |c| {
                        self.current_fg = c;
                    },
                    48 => if (extendedColor(sub)) |c| {
                        self.current_bg = c;
                    },
                    else => self.applySgr(p),
                }
                i += subs;
                continue;
            }
            switch (p) {
                38, 48 => { // Extended color, semicolon form
                    const color: ?Color = blk: {
                        if (i + 2 < csi.param_count and csi.params[i + 1] == 5) {
                            // 256-color
                            const c = color256(csi.params[i + 2]);
                            i += 2;
                            break :blk c;
                        }
                        if (i + 4 < csi.param_count and csi.params[i + 1] == 2) {
                            // 24-bit RGB — clamp: params are u16 and a hostile
                            // program can send values > 255 (would panic @intCast)
                            const c = rgbColor(csi.params[i + 2 ..][0..3]);
                            i += 4;
                            break :blk c;
                        }
                        break :blk null;
                    };
                    if (color) |c| {
                        if (p == 38) self.current_fg = c else self.current_bg = c;
                    }
                },
                else => self.applySgr(p),
            }
        }
    }

    /// One plain SGR attribute (no parameters of its own).
    fn applySgr(self: *Terminal, p: u16) void {
        switch (p) {
            0 => self.resetSgr(),
            1 => self.current_bold = true,
            3 => {}, // italic — no field yet
            4 => self.current_underline = true,
            7 => self.current_reverse = true,
            22 => self.current_bold = false,
            23 => {}, // not italic
            24 => self.current_underline = false,
            27 => self.current_reverse = false,
            // Foreground colors (30-37)
            30...37 => self.current_fg = ansi_colors[p - 30],
            // Bright foreground (90-97)
            90...97 => self.current_fg = ansi_colors[p - 90 + 8],
            // Background colors (40-47)
            40...47 => self.current_bg = ansi_colors[p - 40],
            // Bright background (100-107)
            100...107 => self.current_bg = ansi_colors[p - 100 + 8],
            39 => self.current_fg = Color.default_fg, // Default fg
            49 => self.current_bg = Color.default_bg, // Default bg
            else => {},
        }
    }

    fn resetSgr(self: *Terminal) void {
        self.current_fg = Color.default_fg;
        self.current_bg = Color.default_bg;
        self.current_bold = false;
        self.current_underline = false;
        self.current_reverse = false;
    }

    /// LF / IND: down one row; at the bottom margin the scrolling region
    /// scrolls. Below a partial region the cursor just moves (stopping at
    /// the last row) — it used to scroll the region from out there.
    fn cursorDown(self: *Terminal) void {
        if (self.cursor_row == self.scroll_bottom) {
            self.scrollUp();
        } else if (self.cursor_row + 1 < self.rows) {
            self.cursor_row += 1;
        }
    }

    /// RI: up one row; only at the top margin does the region scroll down
    /// (it used to scroll wherever the cursor was, without moving it).
    fn reverseIndex(self: *Terminal) void {
        if (self.cursor_row == self.scroll_top) {
            self.scrollDown();
        } else if (self.cursor_row > 0) {
            self.cursor_row -= 1;
        }
    }

    /// CUU / CPL: up `n` rows, stopping at the top margin when the cursor
    /// starts inside the scrolling region, at row 0 when above it.
    fn cursorUpBy(self: *Terminal, n: u16) void {
        const limit: u16 = if (self.cursor_row >= self.scroll_top) self.scroll_top else 0;
        self.cursor_row = @max(limit, self.cursor_row -| n);
    }

    /// CUD / CNL: down `n` rows, stopping at the bottom margin when the
    /// cursor starts inside the scrolling region, at the last row below it.
    fn cursorDownBy(self: *Terminal, n: u16) void {
        const limit: u16 = if (self.cursor_row <= self.scroll_bottom) self.scroll_bottom else self.rows -| 1;
        self.cursor_row = @min(limit, self.cursor_row +| n);
    }

    fn scrollUp(self: *Terminal) void {
        if (self.rows == 0 or self.scroll_top > self.scroll_bottom or self.scroll_bottom >= self.rows) return;
        // Move lines up within scroll region
        for (self.scroll_top..self.scroll_bottom) |r| {
            const src_start = (r + 1) * @as(usize, self.cols);
            const dst_start = r * @as(usize, self.cols);
            @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
        }
        // Clear bottom line of scroll region (BCE: use current background)
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        const bottom_start = @as(usize, self.scroll_bottom) * @as(usize, self.cols);
        @memset(self.cells[bottom_start..][0..self.cols], blank);
    }

    fn scrollDown(self: *Terminal) void {
        if (self.rows == 0 or self.scroll_top > self.scroll_bottom or self.scroll_bottom >= self.rows) return;
        // Move lines down within scroll region
        var r = self.scroll_bottom;
        while (r > self.scroll_top) : (r -= 1) {
            const src_start = (r - 1) * @as(usize, self.cols);
            const dst_start = r * @as(usize, self.cols);
            @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
        }
        // Clear top line of scroll region (BCE: use current background)
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        const top_start = @as(usize, self.scroll_top) * @as(usize, self.cols);
        @memset(self.cells[top_start..][0..self.cols], blank);
    }

    fn enterAltScreen(self: *Terminal) void {
        if (self.in_alt_screen) return;
        const total = @as(usize, self.cols) * @as(usize, self.rows);
        const alt = self.allocator.alloc(Cell, total) catch return;
        @memset(alt, Cell{});
        // Save main screen
        self.alt_cells = self.cells;
        self.alt_cursor_row = self.cursor_row;
        self.alt_cursor_col = self.cursor_col;
        self.cells = alt;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.in_alt_screen = true;
    }

    fn leaveAltScreen(self: *Terminal) void {
        if (!self.in_alt_screen) return;
        // Free alt screen, restore main
        self.allocator.free(self.cells);
        self.cells = self.alt_cells orelse return;
        self.alt_cells = null;
        self.cursor_row = self.alt_cursor_row;
        self.cursor_col = self.alt_cursor_col;
        self.in_alt_screen = false;
    }

    // =========================================================================
    // Reader thread
    // =========================================================================

    /// Reads until the PTY reports EOF or an error — never stops early on
    /// `running`: deinit ends it through `Pty.shutdown`, and on older
    /// Windows ClosePseudoConsole waits for its output to be drained.
    fn readerThreadFn(self: *Terminal) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.pty.read(&buf) catch break;
            if (n == 0) break;

            self.mutex.lockUncancelable(self.io);
            self.processOutput(buf[0..n]);
            self.mutex.unlock(self.io);
            if (self.wake_fn) |f| f();
        }
        // Mark as exited
        self.mutex.lockUncancelable(self.io);
        self.exited = true;
        self.mutex.unlock(self.io);
        if (self.wake_fn) |f| f();
    }

    /// Windows thread-pool callback: the shell process exited. ConPTY keeps
    /// the output pipe open until the pseudo console is closed, so close it
    /// here — the reader then drains the last output, sees EOF and ends.
    /// The grid keeps its last screen; frontends show "[Process exited]".
    fn onChildExit(context: ?*anyopaque, timed_out: u8) callconv(.winapi) void {
        _ = timed_out;
        const self: *Terminal = @ptrCast(@alignCast(context orelse return));
        self.mutex.lockUncancelable(self.io);
        self.exited = true;
        // Taken under the mutex: resizeGrid resizes the console under it.
        const console = self.pty.takeConsole();
        self.mutex.unlock(self.io);
        // Outside the mutex: closing can wait for the reader to drain.
        Pty.closeConsole(console);
        if (self.wake_fn) |f| f();
    }

    // =========================================================================
    // Key encoding: convert editor key events to VT sequences
    // =========================================================================

    /// Encode a key event as a VT sequence to send to the PTY.
    /// Returns the number of bytes written to `out`. `shift` only affects
    /// special keys: printable codepoints arrive already shifted. Special
    /// keys use ZIDE's key codes (`key_up` ... `key_f12`).
    pub fn encodeKey(key: u21, ctrl: bool, alt: bool, shift: bool, out: *[16]u8) u8 {
        return encodeKeyMode(key, ctrl, alt, shift, false, out);
    }

    /// `encodeKey` for a terminal whose program may have switched on
    /// application cursor keys (`appCursorKeys()`): unmodified arrows,
    /// Home and End then send SS3 (ESC O A) instead of CSI (ESC [ A).
    pub fn encodeKeyMode(key: u21, ctrl: bool, alt: bool, shift: bool, app_cursor: bool, out: *[16]u8) u8 {
        // Ctrl chords that are C0 bytes: Ctrl+letter, Ctrl+Space (vaxis
        // reports a legacy terminal's Ctrl+Space NUL as Ctrl+'@'), and
        // Ctrl+[ \ ] ^ _ / (Ctrl+[ is ESC) — consoles that report those
        // chords as the plain character would otherwise type the character.
        const c0: ?u8 = if (!ctrl) null else switch (key) {
            'a'...'z', 'A'...'Z' => @intCast(key & 0x1F),
            ' ', '@' => 0x00,
            '[' => 0x1B,
            '\\' => 0x1C,
            ']' => 0x1D,
            '^' => 0x1E,
            '_', '/' => 0x1F,
            else => null,
        };
        if (c0) |byte| {
            if (alt) {
                out[0] = 0x1B;
                out[1] = byte;
                return 2;
            }
            out[0] = byte;
            return 1;
        }

        // Modifiers travel xterm-style as a parameter (CSI 1;5C =
        // Ctrl+Right), which is what readline and TUI apps bind.
        var mod: u8 = 1;
        if (shift) mod += 1;
        if (alt) mod += 2;
        if (ctrl) mod += 4;

        // F1-F4: SS3 P..S (CSI 1;mod P..S when modified); F5-F12: CSI n ~
        if (key >= key_f1 and key <= key_f12) {
            const n: u8 = @intCast(key - key_f1);
            const s = if (n < 4) blk: {
                const final: u8 = 'P' + n;
                break :blk if (mod > 1)
                    std.fmt.bufPrint(out, "\x1b[1;{d}{c}", .{ mod, final })
                else
                    std.fmt.bufPrint(out, "\x1bO{c}", .{final});
            } else blk: {
                const codes = [_]u8{ 15, 17, 18, 19, 20, 21, 23, 24 };
                const code = codes[n - 4];
                break :blk if (mod > 1)
                    std.fmt.bufPrint(out, "\x1b[{d};{d}~", .{ code, mod })
                else
                    std.fmt.bufPrint(out, "\x1b[{d}~", .{code});
            };
            return @intCast((s catch unreachable).len);
        }

        // Cursor/editing keys
        const csi: ?struct { u8, u8 } = switch (key) {
            key_up => .{ 1, 'A' },
            key_down => .{ 1, 'B' },
            key_left => .{ 1, 'D' },
            key_right => .{ 1, 'C' },
            key_home => .{ 1, 'H' },
            key_end => .{ 1, 'F' },
            key_page_up => .{ 5, '~' },
            key_page_down => .{ 6, '~' },
            key_insert => .{ 2, '~' },
            key_delete => .{ 3, '~' },
            else => null,
        };
        if (csi) |c| {
            const param, const final = c;
            const s = if (mod > 1)
                std.fmt.bufPrint(out, "\x1b[{d};{d}{c}", .{ param, mod, final })
            else if (final == '~')
                std.fmt.bufPrint(out, "\x1b[{d}~", .{param})
            else if (app_cursor)
                std.fmt.bufPrint(out, "\x1bO{c}", .{final})
            else
                std.fmt.bufPrint(out, "\x1b[{c}", .{final});
            return @intCast((s catch unreachable).len);
        }

        // Special keys
        const seq: ?[]const u8 = switch (key) {
            0x0D => "\r", // Enter
            0x09 => if (shift) "\x1b[Z" else "\t", // Tab / Shift+Tab
            0x08, 0x7F => "\x7f", // Backspace
            0x1B => "\x1b", // Escape
            else => null,
        };

        if (seq) |s| {
            if (alt) {
                out[0] = 0x1B;
                @memcpy(out[1..][0..s.len], s);
                return @intCast(1 + s.len);
            }
            @memcpy(out[0..s.len], s);
            return @intCast(s.len);
        }

        // Regular printable character — encode as UTF-8
        if (key < 0x80) {
            if (alt) {
                out[0] = 0x1B;
                out[1] = @intCast(key);
                return 2;
            }
            out[0] = @intCast(key);
            return 1;
        }

        // UTF-8 encode
        const len = std.unicode.utf8Encode(key, out) catch return 0;
        return @intCast(len);
    }
};

/// Convert 256-color index to RGB. Out-of-range indices are clamped
/// (params come straight from untrusted CSI sequences).
fn color256(raw_idx: u16) Color {
    const idx = @min(raw_idx, 255);
    if (idx < 16) return ansi_colors[idx];
    if (idx < 232) {
        // 216 color cube (6x6x6)
        const ci = idx - 16;
        const b_idx = ci % 6;
        const g_idx = (ci / 6) % 6;
        const r_idx = ci / 36;
        return .{
            .r = if (r_idx == 0) 0 else @intCast(r_idx * 40 + 55),
            .g = if (g_idx == 0) 0 else @intCast(g_idx * 40 + 55),
            .b = if (b_idx == 0) 0 else @intCast(b_idx * 40 + 55),
        };
    }
    // Grayscale ramp (232-255)
    const v: u8 = @intCast((idx - 232) * 10 + 8);
    return .{ .r = v, .g = v, .b = v };
}

/// Truecolor from three untrusted u16 parameters (clamped to 255).
fn rgbColor(rgb: *const [3]u16) Color {
    return .{
        .r = @intCast(@min(rgb[0], 255)),
        .g = @intCast(@min(rgb[1], 255)),
        .b = @intCast(@min(rgb[2], 255)),
    };
}

/// Color from the colon form of SGR 38/48 (`sub` = the sub-parameters):
/// `5:n` (palette), `2:r:g:b` or `2:colorspace:r:g:b` (truecolor).
fn extendedColor(sub: []const u16) ?Color {
    if (sub.len >= 2 and sub[0] == 5) return color256(sub[1]);
    if (sub[0] == 2) {
        if (sub.len >= 5) return rgbColor(sub[2..5]);
        if (sub.len == 4) return rgbColor(sub[1..4]);
    }
    return null;
}

/// The bytes `Terminal.paste` sends, handed to `sink` in chunks.
fn writePaste(text: []const u8, bracketed: bool, ctx: anytype, comptime sink: fn (@TypeOf(ctx), []const u8) void) void {
    if (bracketed) sink(ctx, "\x1b[200~");
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const out: ?u8 = switch (text[i]) {
            '\r' => blk: {
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
                break :blk '\r';
            },
            '\n' => '\r',
            0x1B => if (bracketed) null else 0x1B,
            else => |b| b,
        };
        if (out) |o| {
            buf[n] = o;
            n += 1;
            if (n == buf.len) {
                sink(ctx, buf[0..n]);
                n = 0;
            }
        }
    }
    if (n > 0) sink(ctx, buf[0..n]);
    if (bracketed) sink(ctx, "\x1b[201~");
}

/// Rows that must leave the top of a grid shrinking to `new_rows` so the
/// cursor row stays on screen.
fn rowsToDrop(cursor_row: u16, new_rows: u16) u16 {
    return if (cursor_row >= new_rows) cursor_row - new_rows + 1 else 0;
}

/// Blank `dst` (dst_cols x dst_rows), then copy `src` (src_cols x src_rows)
/// into it, starting at source row `skip`.
fn copyGrid(dst: []Cell, dst_cols: u16, dst_rows: u16, src: []const Cell, src_cols: u16, src_rows: u16, skip: u16) void {
    @memset(dst, Cell{});
    const cols = @min(src_cols, dst_cols);
    const rows = @min(src_rows -| skip, dst_rows);
    for (0..rows) |r| {
        const s = (r + skip) * @as(usize, src_cols);
        const d = r * @as(usize, dst_cols);
        @memcpy(dst[d..][0..cols], src[s..][0..cols]);
    }
}

// Windows thread-pool wait (shell exit detection, `Terminal.onChildExit`)
const WaitCallback = *const fn (?*anyopaque, u8) callconv(.winapi) void;
extern "kernel32" fn RegisterWaitForSingleObject(
    phNewWaitObject: *?std.os.windows.HANDLE,
    hObject: std.os.windows.HANDLE,
    Callback: WaitCallback,
    Context: ?*anyopaque,
    dwMilliseconds: u32,
    dwFlags: u32,
) callconv(.winapi) i32;
extern "kernel32" fn UnregisterWaitEx(WaitHandle: std.os.windows.HANDLE, CompletionEvent: ?std.os.windows.HANDLE) callconv(.winapi) i32;
const win_infinite: u32 = 0xFFFFFFFF;
const wt_execute_only_once: u32 = 0x00000008;

// =============================================================================
// Tests
// =============================================================================

/// Build a PTY-less terminal for parser/grid tests (no process spawned).
fn makeTestTerminal(allocator: Allocator, cols: u16, rows: u16) !Terminal {
    const total = @as(usize, cols) * @as(usize, rows);
    const cells = try allocator.alloc(Cell, total);
    @memset(cells, Cell{});
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .pty = .{ .allocator = allocator },
        .cells = cells,
        .cols = cols,
        .rows = rows,
        .scroll_bottom = rows -| 1,
    };
}

fn freeTestTerminal(allocator: Allocator, term: *Terminal) void {
    allocator.free(term.cells);
    if (term.alt_cells) |ac| allocator.free(ac);
}

test "bounded randomized CSI and resizing preserve terminal grid invariants" {
    const t = std.testing;
    var term = try makeTestTerminal(t.allocator, 20, 8);
    defer freeTestTerminal(t.allocator, &term);
    var generator = std.Random.DefaultPrng.init(0x5a1de);
    const random = generator.random();
    const commands = "rHfSTLMJKP@ABCD";
    for (0..1000) |iteration| {
        var bytes: [64]u8 = undefined;
        const sequence = try std.fmt.bufPrint(&bytes, "\x1b[{d};{d}{c}", .{ random.int(u16), random.int(u16), commands[random.uintLessThan(usize, commands.len)] });
        term.processOutput(sequence);
        if (iteration % 13 == 0) term.resizeGrid(1 + random.uintLessThan(u16, 30), 1 + random.uintLessThan(u16, 12));
        try t.expectEqual(@as(usize, term.cols) * term.rows, term.cells.len);
        try t.expect(term.scroll_top <= term.scroll_bottom and term.scroll_bottom < term.rows);
        try t.expect(term.cursor_row < term.rows and term.cursor_col < term.cols);
    }
}

test "hostile SGR truecolor params are clamped" {
    const alloc = std.testing.allocator;
    var term = try makeTestTerminal(alloc, 20, 4);
    defer freeTestTerminal(alloc, &term);
    // RGB components > 255 and a 256-color index > 255 — previously @intCast panics
    term.processOutput("\x1b[38;2;300;999;65535m\x1b[48;5;9999mA");
    const cell = term.cellAtUnsafe(0, 0);
    try std.testing.expectEqual(@as(u21, 'A'), cell.codepoint);
    try std.testing.expectEqual(@as(u8, 255), cell.fg.r);
    try std.testing.expectEqual(@as(u8, 255), cell.fg.g);
    try std.testing.expectEqual(@as(u8, 255), cell.fg.b);
}

test "hostile CSI repeat and region params don't crash" {
    const alloc = std.testing.allocator;
    var term = try makeTestTerminal(alloc, 20, 8);
    defer freeTestTerminal(alloc, &term);
    // Huge delete/insert-chars counts (u16 add previously overflowed)
    term.processOutput("hello\x1b[65535P\x1b[65535@");
    // Scroll region rows 2..4, cursor below it, then IL/DL (previously underflowed)
    term.processOutput("\x1b[2;4r\x1b[6;1H\x1b[5L\x1b[5M");
    // Huge scroll counts (now clamped to grid height)
    term.processOutput("\x1b[65535S\x1b[65535T");
}

test "alt screen survives resize" {
    const alloc = std.testing.allocator;
    var term = try makeTestTerminal(alloc, 10, 4);
    defer freeTestTerminal(alloc, &term);
    term.processOutput("main");
    term.processOutput("\x1b[?1049h"); // enter alt screen
    term.processOutput("alt!");
    term.resizeGrid(20, 8); // resize while in alt screen
    term.processOutput("\x1b[?1049l"); // leave alt screen
    try std.testing.expectEqual(@as(u16, 20), term.cols);
    try std.testing.expectEqual(@as(u16, 8), term.rows);
    // Saved main screen was resized along: content intact, far corner in bounds
    try std.testing.expectEqual(@as(u21, 'm'), term.cellAtUnsafe(0, 0).codepoint);
    _ = term.cellAtUnsafe(7, 19);
}

test "DECSC/DECRC save and restore cursor" {
    const alloc = std.testing.allocator;
    var term = try makeTestTerminal(alloc, 20, 6);
    defer freeTestTerminal(alloc, &term);
    term.processOutput("\x1b[3;5H\x1b7"); // move to (2,4), save
    term.processOutput("\x1b[1;1H"); // move home
    try std.testing.expectEqual(@as(u16, 0), term.cursor_row);
    term.processOutput("\x1b8"); // restore
    try std.testing.expectEqual(@as(u16, 2), term.cursor_row);
    try std.testing.expectEqual(@as(u16, 4), term.cursor_col);
}

test "OSC terminated by ST doesn't print a backslash" {
    const alloc = std.testing.allocator;
    var term = try makeTestTerminal(alloc, 20, 4);
    defer freeTestTerminal(alloc, &term);
    term.processOutput("\x1b]0;title\x1b\\A");
    try std.testing.expectEqual(@as(u21, 'A'), term.cellAtUnsafe(0, 0).codepoint);
}

test "color256 basic" {
    // Color 0 = black
    const c0 = color256(0);
    try std.testing.expectEqual(@as(u8, 0), c0.r);
    try std.testing.expectEqual(@as(u8, 0), c0.g);
    try std.testing.expectEqual(@as(u8, 0), c0.b);

    // Color 15 = bright white
    const c15 = color256(15);
    try std.testing.expectEqual(@as(u8, 0xFF), c15.r);
    try std.testing.expectEqual(@as(u8, 0xFF), c15.g);
    try std.testing.expectEqual(@as(u8, 0xFF), c15.b);

    // Color 232 = darkest grayscale
    const c232 = color256(232);
    try std.testing.expectEqual(@as(u8, 8), c232.r);
}

test "encodeKey printable" {
    var buf: [16]u8 = undefined;
    const n = Terminal.encodeKey('A', false, false, false, &buf);
    try std.testing.expectEqual(@as(u8, 1), n);
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
}

test "encodeKey ctrl+c" {
    var buf: [16]u8 = undefined;
    const n = Terminal.encodeKey('c', true, false, false, &buf);
    try std.testing.expectEqual(@as(u8, 1), n);
    try std.testing.expectEqual(@as(u8, 3), buf[0]); // ETX
}

test "encodeKey enter" {
    var buf: [16]u8 = undefined;
    const n = Terminal.encodeKey(0x0D, false, false, false, &buf);
    try std.testing.expectEqual(@as(u8, 1), n);
    try std.testing.expectEqual(@as(u8, '\r'), buf[0]);
}

fn expectEncodedKey(expected: []const u8, key: u21, ctrl: bool, alt: bool, shift: bool) !void {
    var buf: [16]u8 = undefined;
    const n = Terminal.encodeKey(key, ctrl, alt, shift, &buf);
    try std.testing.expectEqualStrings(expected, buf[0..n]);
}

test "encodeKey modified cursor keys use xterm parameters" {
    try expectEncodedKey("\x1b[A", 0xF700, false, false, false); // Up
    try expectEncodedKey("\x1b[1;2A", 0xF700, false, false, true); // Shift+Up
    try expectEncodedKey("\x1b[1;3A", 0xF700, false, true, false); // Alt+Up
    try expectEncodedKey("\x1b[1;5C", 0xF703, true, false, false); // Ctrl+Right
    try expectEncodedKey("\x1b[1;6D", 0xF702, true, false, true); // Ctrl+Shift+Left
    try expectEncodedKey("\x1b[1;5F", 0xF705, true, false, false); // Ctrl+End
    try expectEncodedKey("\x1b[5~", 0xF706, false, false, false); // PgUp
    try expectEncodedKey("\x1b[5;2~", 0xF706, false, false, true); // Shift+PgUp
    try expectEncodedKey("\x1b[3;5~", 0xF709, true, false, false); // Ctrl+Delete
}

test "encodeKey shift+tab, ctrl+space, alt prefix" {
    try expectEncodedKey("\t", 0x09, false, false, false); // Tab
    try expectEncodedKey("\x1b[Z", 0x09, false, false, true); // Shift+Tab
    try expectEncodedKey("\x00", ' ', true, false, false); // Ctrl+Space
    try expectEncodedKey("\x1b\x00", ' ', true, true, false); // Ctrl+Alt+Space
    try expectEncodedKey("\x00", '@', true, false, false); // Ctrl+Space via vaxis
    try expectEncodedKey(" ", ' ', false, false, true); // Shift+Space (GUI passes shift)
    try expectEncodedKey("\x1bx", 'x', false, true, false); // Alt+x
    try expectEncodedKey("\x1b\r", 0x0D, false, true, false); // Alt+Enter
}

test "encodeKey F-keys, Ctrl punctuation and application cursor keys" {
    try expectEncodedKey("\x1bOP", key_f1, false, false, false);
    try expectEncodedKey("\x1bOS", key_f1 + 3, false, false, false); // F4
    try expectEncodedKey("\x1b[1;2P", key_f1, false, false, true); // Shift+F1
    try expectEncodedKey("\x1b[15~", key_f1 + 4, false, false, false); // F5
    try expectEncodedKey("\x1b[18~", key_f1 + 6, false, false, false); // F7
    try expectEncodedKey("\x1b[21~", key_f1 + 9, false, false, false); // F10
    try expectEncodedKey("\x1b[24;5~", key_f12, true, false, false); // Ctrl+F12
    // Ctrl chords that are C0 bytes (Windows consoles report the character)
    try expectEncodedKey("\x1b", '[', true, false, false);
    try expectEncodedKey("\x1c", '\\', true, false, false);
    try expectEncodedKey("\x1d", ']', true, false, false);
    try expectEncodedKey("\x1e", '^', true, false, false);
    try expectEncodedKey("\x1f", '_', true, false, false);
    try expectEncodedKey("\x1f", '/', true, false, false);
    try expectEncodedKey("\x1b\x1d", ']', true, true, false); // Ctrl+Alt+]
    try expectEncodedKey("\x01", 'A', true, false, false);
    // DECCKM: unmodified arrows/Home/End switch to SS3; modified ones keep CSI
    var buf: [16]u8 = undefined;
    var n = Terminal.encodeKeyMode(key_up, false, false, false, true, &buf);
    try std.testing.expectEqualStrings("\x1bOA", buf[0..n]);
    n = Terminal.encodeKeyMode(key_home, false, false, false, true, &buf);
    try std.testing.expectEqualStrings("\x1bOH", buf[0..n]);
    n = Terminal.encodeKeyMode(key_up, true, false, false, true, &buf);
    try std.testing.expectEqualStrings("\x1b[1;5A", buf[0..n]);
    n = Terminal.encodeKeyMode(key_page_up, false, false, false, true, &buf);
    try std.testing.expectEqualStrings("\x1b[5~", buf[0..n]);
}

/// Test helper: the printable text of row `row`, trailing blanks trimmed.
fn testRowText(term: *const Terminal, row: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    for (0..term.cols) |c| {
        const cp = term.cellAtUnsafe(row, @intCast(c)).codepoint;
        n += std.unicode.utf8Encode(cp, buf[n..]) catch 0;
    }
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

test "VT framing: strings, restarted sequences and markers never garble the grid" {
    const t = std.testing;
    var term = try makeTestTerminal(t.allocator, 20, 4);
    defer freeTestTerminal(t.allocator, &term);
    var buf: [128]u8 = undefined;
    // neovim's XTGETTCAP query (DCS) and a kitty graphics APC print nothing
    term.processOutput("\x1bP+q544e\x1b\\\x1b_Gf=100;AAAA\x1b\\A");
    try t.expectEqualStrings("A", testRowText(&term, 0, &buf));
    // ESC inside an unfinished CSI starts a new sequence (was "HX")
    term.processOutput("\x1b[2J\x1b[12\x1b[HX");
    try t.expectEqualStrings("X", testRowText(&term, 0, &buf));
    try t.expectEqual(@as(u16, 1), term.cursor_col);
    // ESC ESC [31m is one SGR (was "[31m" printed)
    term.processOutput("\x1b[2J\x1b[H\x1b\x1b[31mB");
    try t.expectEqualStrings("B", testRowText(&term, 0, &buf));
    try t.expectEqual(ansi_colors[1], term.cellAtUnsafe(0, 0).fg);
    // vim's modifyOtherKeys (CSI > 4;2 m) is not SGR 4
    term.processOutput("\x1b[0m\x1b[>4;2mC");
    try t.expect(!term.cellAtUnsafe(0, 1).underline);
    // Undercurl 4:3 underlines; it is not SGR 43 (yellow background)
    term.processOutput("\x1b[4:3mD\x1b[4:0mE");
    try t.expect(term.cellAtUnsafe(0, 2).underline);
    try t.expectEqual(Color.default_bg, term.cellAtUnsafe(0, 2).bg);
    try t.expect(!term.cellAtUnsafe(0, 3).underline);
    // Colon truecolor, with and without the colorspace slot
    term.processOutput("\x1b[38:2::10:20:30mF\x1b[48:2:40:50:60mG\x1b[38:5:1mH");
    try t.expectEqual(Color{ .r = 10, .g = 20, .b = 30 }, term.cellAtUnsafe(0, 4).fg);
    try t.expectEqual(Color{ .r = 40, .g = 50, .b = 60 }, term.cellAtUnsafe(0, 5).bg);
    try t.expectEqual(ansi_colors[1], term.cellAtUnsafe(0, 6).fg);
    try t.expectEqualStrings("BCDEFGH", testRowText(&term, 0, &buf));
}

test "RI moves the cursor up and scrolls only at the top margin" {
    const t = std.testing;
    var term = try makeTestTerminal(t.allocator, 10, 5);
    defer freeTestTerminal(t.allocator, &term);
    var buf: [64]u8 = undefined;
    term.processOutput("L0\r\nL1\r\nL2\r\nL3");
    term.processOutput("\x1bM");
    try t.expectEqual(@as(u16, 2), term.cursor_row);
    try t.expectEqualStrings("L0", testRowText(&term, 0, &buf));
    // At the top margin RI inserts a blank line at the top of the region
    term.processOutput("\x1b[H\x1bM");
    try t.expectEqual(@as(u16, 0), term.cursor_row);
    try t.expectEqualStrings("", testRowText(&term, 0, &buf));
    try t.expectEqualStrings("L0", testRowText(&term, 1, &buf));
    // IND / NEL move down; NEL also returns to column 0
    term.processOutput("\x1b[3;4H\x1bD");
    try t.expectEqual(@as(u16, 3), term.cursor_row);
    try t.expectEqual(@as(u16, 3), term.cursor_col);
    term.processOutput("\x1bE");
    try t.expectEqual(@as(u16, 4), term.cursor_row);
    try t.expectEqual(@as(u16, 0), term.cursor_col);
}

test "CUU/CUD and LF respect a partial scroll region only from inside it" {
    const t = std.testing;
    var term = try makeTestTerminal(t.allocator, 20, 10);
    defer freeTestTerminal(t.allocator, &term);
    // Above the region CUU moves up (it used to jump down to the margin)
    term.processOutput("\x1b[5;9r\x1b[2;1H\x1b[A");
    try t.expectEqual(@as(u16, 0), term.cursor_row);
    // Inside, CUU stops at the top margin and CUD at the bottom margin
    term.processOutput("\x1b[7;1H\x1b[10A");
    try t.expectEqual(@as(u16, 4), term.cursor_row);
    term.processOutput("\x1b[10B");
    try t.expectEqual(@as(u16, 8), term.cursor_row);
    // Below a region CUD moves down to the last row (it used to jump up)
    term.processOutput("\x1b[1;5r\x1b[9;1H\x1b[B");
    try t.expectEqual(@as(u16, 9), term.cursor_row);
    // LF below the region moves without scrolling it
    var buf: [64]u8 = undefined;
    term.processOutput("\x1b[2J\x1b[1;1Htop\x1b[8;1H\n");
    try t.expectEqual(@as(u16, 8), term.cursor_row);
    try t.expectEqualStrings("top", testRowText(&term, 0, &buf));
    term.processOutput("\n\n");
    try t.expectEqual(@as(u16, 9), term.cursor_row);
    try t.expectEqualStrings("top", testRowText(&term, 0, &buf));
}

test "shrinking keeps the cursor line; a resize resets both margins" {
    const t = std.testing;
    var term = try makeTestTerminal(t.allocator, 10, 6);
    defer freeTestTerminal(t.allocator, &term);
    var buf: [64]u8 = undefined;
    term.processOutput("l0\r\nl1\r\nl2\r\nl3\r\nl4\r\n$ ");
    term.resizeGrid(10, 3);
    try t.expectEqualStrings("l3", testRowText(&term, 0, &buf));
    try t.expectEqualStrings("l4", testRowText(&term, 1, &buf));
    try t.expectEqualStrings("$", testRowText(&term, 2, &buf));
    try t.expectEqual(@as(u16, 2), term.cursor_row);
    try t.expectEqual(@as(u16, 2), term.cursor_col);
    // Cursor near the top: the top rows stay
    term.processOutput("\x1b[2J\x1b[Htop");
    term.resizeGrid(10, 2);
    try t.expectEqualStrings("top", testRowText(&term, 0, &buf));
    // Margins: both reset, whatever the old region was
    term.resizeGrid(10, 8);
    term.processOutput("\x1b[3;6r");
    term.resizeGrid(12, 9);
    try t.expectEqual(@as(u16, 0), term.scroll_top);
    try t.expectEqual(@as(u16, 8), term.scroll_bottom);
    // The saved main screen keeps its own cursor line while in the alt screen
    term.processOutput("\x1b[2J\x1b[9;1Hmain\x1b[?1049h");
    term.resizeGrid(12, 4);
    term.processOutput("\x1b[?1049l");
    try t.expectEqualStrings("main", testRowText(&term, 3, &buf));
    try t.expectEqual(@as(u16, 3), term.cursor_row);
}

test "input modes: DECCKM and bracketed paste; paste converts line breaks" {
    const t = std.testing;
    var term = try makeTestTerminal(t.allocator, 10, 4);
    defer freeTestTerminal(t.allocator, &term);
    try t.expect(!term.appCursorKeys());
    term.processOutput("\x1b[?1h\x1b[?2004h");
    try t.expect(term.appCursorKeys() and term.bracketed_paste);
    term.processOutput("\x1b[?1;2004l");
    try t.expect(!term.appCursorKeys() and !term.bracketed_paste);

    const Sink = struct {
        buf: [128]u8 = undefined,
        len: usize = 0,
        fn write(self: *@This(), bytes: []const u8) void {
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
    };
    var plain: Sink = .{};
    writePaste("a\r\nb\nc\rd", false, &plain, Sink.write);
    try t.expectEqualStrings("a\rb\rc\rd", plain.buf[0..plain.len]);
    // Bracketed: wrapped, and an ESC inside can never end the paste early
    var wrapped: Sink = .{};
    writePaste("x\x1b[201~y\n", true, &wrapped, Sink.write);
    try t.expectEqualStrings("\x1b[200~x[201~y\r\x1b[201~", wrapped.buf[0..wrapped.len]);
}

test "Terminal.init frees its grid when the shell cannot start" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // std.testing.allocator fails the test on a leak
    try std.testing.expectError(
        error.ProcessCreationFailed,
        Terminal.init(std.testing.allocator, std.testing.io, 20, 5, "zide-test-no-such-program.exe"),
    );
}

test "shell exit is detected and the last screen stays" {
    const cmd = switch (builtin.os.tag) {
        .windows => "cmd.exe /c echo zide-exit-probe",
        .linux => "true",
        else => return error.SkipZigTest,
    };
    const t = std.testing;
    const term = try Terminal.init(t.allocator, t.io, 40, 5, cmd);
    defer term.deinit();
    // ConPTY keeps the output pipe open after its client exits: before the
    // exit watcher the pane never learned (reproduced: no EOF within 4 s).
    var exited = false;
    var waited: usize = 0;
    while (!exited and waited < 10_000) : (waited += 20) {
        try std.Io.sleep(t.io, .fromMilliseconds(20), .awake);
        term.mutex.lockUncancelable(term.io);
        exited = term.exited;
        term.mutex.unlock(term.io);
    }
    try t.expect(exited);
    if (builtin.os.tag == .windows) {
        // The reader drains the last output after the close: the echoed
        // line is still on the grid (nothing clears it)
        try std.Io.sleep(t.io, .fromMilliseconds(300), .awake);
        term.mutex.lockUncancelable(term.io);
        defer term.mutex.unlock(term.io);
        var found = false;
        var buf: [256]u8 = undefined;
        for (0..term.rows) |r| {
            if (std.mem.indexOf(u8, testRowText(term, @intCast(r), &buf), "zide-exit-probe") != null) found = true;
        }
        try t.expect(found);
    }
    // A late resize after the console is gone is harmless
    term.resizeGrid(30, 4);
}
