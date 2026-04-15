const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
const Pty = @import("pty.zig").Pty;

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

    // Thread safety
    mutex: std.Thread.Mutex = .{},
    reader_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    // Whether the shell process has exited
    exited: bool = false,

    pub fn init(allocator: Allocator, cols: u16, rows: u16, command: []const u8) !*Terminal {
        const total = @as(usize, cols) * @as(usize, rows);
        const cells = try allocator.alloc(Cell, total);
        @memset(cells, Cell{});

        const pty = try Pty.spawn(allocator, command, cols, rows);

        const term = try allocator.create(Terminal);
        term.* = .{
            .allocator = allocator,
            .pty = pty,
            .cells = cells,
            .cols = cols,
            .rows = rows,
            .scroll_bottom = rows -| 1,
        };

        // Start reader thread
        term.reader_thread = std.Thread.spawn(.{}, readerThreadFn, .{term}) catch null;

        return term;
    }

    pub fn deinit(self: *Terminal) void {
        // Signal thread to stop
        self.running.store(false, .release);
        // Close PTY (unblocks reader thread)
        self.pty.deinit();
        // Join reader thread
        if (self.reader_thread) |t| t.join();
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

    /// Resize terminal grid and PTY.
    pub fn resizeGrid(self: *Terminal, new_cols: u16, new_rows: u16) void {
        if (new_cols == self.cols and new_rows == self.rows) return;
        if (new_cols == 0 or new_rows == 0) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const new_total = @as(usize, new_cols) * @as(usize, new_rows);
        const new_cells = self.allocator.alloc(Cell, new_total) catch return;
        @memset(new_cells, Cell{});

        // Copy existing content
        const copy_rows = @min(self.rows, new_rows);
        const copy_cols = @min(self.cols, new_cols);
        for (0..copy_rows) |r| {
            const src_start = r * @as(usize, self.cols);
            const dst_start = r * @as(usize, new_cols);
            @memcpy(new_cells[dst_start..][0..copy_cols], self.cells[src_start..][0..copy_cols]);
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.cols = new_cols;
        self.rows = new_rows;
        self.scroll_bottom = new_rows -| 1;
        if (self.cursor_row >= new_rows) self.cursor_row = new_rows -| 1;
        if (self.cursor_col >= new_cols) self.cursor_col = new_cols -| 1;

        // Resize PTY
        self.pty.resize(new_cols, new_rows);
    }

    /// Get cell at position (for rendering). Locks mutex.
    pub fn cellAt(self: *Terminal, row: u16, col: u16) Cell {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cellAtUnsafe(row, col);
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
        if (csi.private_marker) {
            self.handlePrivateCsi(csi);
            return;
        }

        switch (csi.final_byte) {
            'A' => { // Cursor Up
                const n = csi.get(0, 1);
                self.cursor_row -|= @intCast(n);
                if (self.cursor_row < self.scroll_top) self.cursor_row = self.scroll_top;
            },
            'B' => { // Cursor Down
                const n = csi.get(0, 1);
                self.cursor_row = @min(self.scroll_bottom, self.cursor_row +| @as(u16, @intCast(n)));
            },
            'C' => { // Cursor Forward
                const n = csi.get(0, 1);
                self.cursor_col = @min(self.cols -| 1, self.cursor_col +| @as(u16, @intCast(n)));
            },
            'D' => { // Cursor Backward
                const n = csi.get(0, 1);
                self.cursor_col -|= @intCast(n);
            },
            'E' => { // Cursor Next Line
                const n = csi.get(0, 1);
                self.cursor_col = 0;
                self.cursor_row = @min(self.scroll_bottom, self.cursor_row +| @as(u16, @intCast(n)));
            },
            'F' => { // Cursor Previous Line
                const n = csi.get(0, 1);
                self.cursor_col = 0;
                self.cursor_row -|= @intCast(n);
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
            'S' => { // Scroll Up
                const n = csi.get(0, 1);
                for (0..n) |_| self.scrollUp();
            },
            'T' => { // Scroll Down
                const n = csi.get(0, 1);
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
                self.scroll_top = @as(u16, @intCast(top)) -| 1;
                self.scroll_bottom = @min(self.rows -| 1, @as(u16, @intCast(bottom)) -| 1);
                self.cursor_row = 0;
                self.cursor_col = 0;
            },
            '@' => self.handleInsertChars(csi),
            else => {}, // Unhandled CSI
        }
    }

    fn handlePrivateCsi(self: *Terminal, csi: ansi.CsiParams) void {
        const param = csi.get(0, 0);
        switch (csi.final_byte) {
            'h' => { // Set mode
                switch (param) {
                    25 => self.cursor_visible = true,
                    1049 => self.enterAltScreen(),
                    else => {},
                }
            },
            'l' => { // Reset mode
                switch (param) {
                    25 => self.cursor_visible = false,
                    1049 => self.leaveAltScreen(),
                    else => {},
                }
            },
            else => {},
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
        const n = @min(csi.get(0, 1), self.scroll_bottom - self.cursor_row + 1);
        // Shift lines down
        var r = self.scroll_bottom;
        while (r >= self.cursor_row + n) : (r -= 1) {
            const src_row = r - n;
            for (0..self.cols) |c| {
                const cell = self.cellAtUnsafe(src_row, @intCast(c));
                self.setCellAt(r, @intCast(c), cell);
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
        const n = @min(csi.get(0, 1), self.scroll_bottom - self.cursor_row + 1);
        // Shift lines up
        for (self.cursor_row..(self.scroll_bottom + 1 - n)) |r| {
            const src_row: u16 = @intCast(r + n);
            for (0..self.cols) |c| {
                const cell = self.cellAtUnsafe(src_row, @intCast(c));
                self.setCellAt(@intCast(r), @intCast(c), cell);
            }
        }
        // Clear bottom lines
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        for ((self.scroll_bottom + 1 - n)..(self.scroll_bottom + 1)) |r| {
            for (0..self.cols) |c| {
                self.setCellAt(@intCast(r), @intCast(c), blank);
            }
        }
    }

    fn handleDeleteChars(self: *Terminal, csi: ansi.CsiParams) void {
        const n = csi.get(0, 1);
        const row = self.cursor_row;
        // Shift chars left
        var c = self.cursor_col;
        while (c + n < self.cols) : (c += 1) {
            const cell = self.cellAtUnsafe(row, c + n);
            self.setCellAt(row, c, cell);
        }
        // Clear end
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        while (c < self.cols) : (c += 1) {
            self.setCellAt(row, c, blank);
        }
    }

    fn handleInsertChars(self: *Terminal, csi: ansi.CsiParams) void {
        const n = csi.get(0, 1);
        const row = self.cursor_row;
        // Shift chars right
        var c: u16 = self.cols -| 1;
        while (c >= self.cursor_col + n) : (c -= 1) {
            const cell = self.cellAtUnsafe(row, c - n);
            self.setCellAt(row, c, cell);
            if (c == 0) break;
        }
        // Clear inserted positions
        const blank = Cell{ .fg = self.current_fg, .bg = self.current_bg };
        for (self.cursor_col..@min(self.cursor_col + n, self.cols)) |cc| {
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
                38 => { // Extended foreground
                    if (i + 1 < csi.param_count and csi.params[i + 1] == 5) {
                        // 256-color
                        if (i + 2 < csi.param_count) {
                            self.current_fg = color256(csi.params[i + 2]);
                            i += 2;
                        }
                    } else if (i + 1 < csi.param_count and csi.params[i + 1] == 2) {
                        // 24-bit RGB
                        if (i + 4 < csi.param_count) {
                            self.current_fg = .{
                                .r = @intCast(csi.params[i + 2]),
                                .g = @intCast(csi.params[i + 3]),
                                .b = @intCast(csi.params[i + 4]),
                            };
                            i += 4;
                        }
                    }
                },
                48 => { // Extended background
                    if (i + 1 < csi.param_count and csi.params[i + 1] == 5) {
                        if (i + 2 < csi.param_count) {
                            self.current_bg = color256(csi.params[i + 2]);
                            i += 2;
                        }
                    } else if (i + 1 < csi.param_count and csi.params[i + 1] == 2) {
                        if (i + 4 < csi.param_count) {
                            self.current_bg = .{
                                .r = @intCast(csi.params[i + 2]),
                                .g = @intCast(csi.params[i + 3]),
                                .b = @intCast(csi.params[i + 4]),
                            };
                            i += 4;
                        }
                    }
                },
                39 => self.current_fg = Color.default_fg, // Default fg
                49 => self.current_bg = Color.default_bg, // Default bg
                else => {},
            }
        }
    }

    fn resetSgr(self: *Terminal) void {
        self.current_fg = Color.default_fg;
        self.current_bg = Color.default_bg;
        self.current_bold = false;
        self.current_underline = false;
        self.current_reverse = false;
    }

    fn cursorDown(self: *Terminal) void {
        if (self.cursor_row >= self.scroll_bottom) {
            self.scrollUp();
        } else {
            self.cursor_row += 1;
        }
    }

    fn scrollUp(self: *Terminal) void {
        // Move lines up within scroll region
        for (self.scroll_top..self.scroll_bottom) |r| {
            const src_start = (r + 1) * @as(usize, self.cols);
            const dst_start = r * @as(usize, self.cols);
            @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
        }
        // Clear bottom line of scroll region
        const bottom_start = @as(usize, self.scroll_bottom) * @as(usize, self.cols);
        @memset(self.cells[bottom_start..][0..self.cols], Cell{});
    }

    fn scrollDown(self: *Terminal) void {
        // Move lines down within scroll region
        var r = self.scroll_bottom;
        while (r > self.scroll_top) : (r -= 1) {
            const src_start = (r - 1) * @as(usize, self.cols);
            const dst_start = r * @as(usize, self.cols);
            @memcpy(self.cells[dst_start..][0..self.cols], self.cells[src_start..][0..self.cols]);
        }
        // Clear top line of scroll region
        const top_start = @as(usize, self.scroll_top) * @as(usize, self.cols);
        @memset(self.cells[top_start..][0..self.cols], Cell{});
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

    fn readerThreadFn(self: *Terminal) void {
        var buf: [4096]u8 = undefined;
        while (self.running.load(.acquire)) {
            const n = self.pty.read(&buf) catch break;
            if (n == 0) break;

            self.mutex.lock();
            self.processOutput(buf[0..n]);
            self.mutex.unlock();
        }
        // Mark as exited
        self.mutex.lock();
        self.exited = true;
        self.mutex.unlock();
    }

    // =========================================================================
    // Key encoding: convert editor key events to VT sequences
    // =========================================================================

    /// Encode a key event as a VT sequence to send to the PTY.
    /// Returns the number of bytes written to `out`.
    pub fn encodeKey(key: u21, ctrl: bool, alt: bool, shift: bool, out: *[16]u8) u8 {
        _ = shift;

        // Ctrl+letter
        if (ctrl and key >= 'a' and key <= 'z') {
            if (alt) {
                out[0] = 0x1B;
                out[1] = @intCast(key - 'a' + 1);
                return 2;
            }
            out[0] = @intCast(key - 'a' + 1);
            return 1;
        }

        // Special keys
        const seq: ?[]const u8 = switch (key) {
            0xF700 => "\x1b[A", // Up    (using ZIDE internal key codes)
            0xF701 => "\x1b[B", // Down
            0xF702 => "\x1b[D", // Left
            0xF703 => "\x1b[C", // Right
            0xF704 => "\x1b[H", // Home
            0xF705 => "\x1b[F", // End
            0xF706 => "\x1b[5~", // Page Up
            0xF707 => "\x1b[6~", // Page Down
            0xF708 => "\x1b[2~", // Insert
            0xF709 => "\x1b[3~", // Delete
            0x0D => "\r", // Enter
            0x09 => "\t", // Tab
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

/// Convert 256-color index to RGB.
fn color256(idx: u16) Color {
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

// =============================================================================
// Tests
// =============================================================================

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
