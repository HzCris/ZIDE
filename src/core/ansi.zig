const std = @import("std");

/// Parameters parsed from a CSI sequence (e.g., \e[1;31m).
pub const CsiParams = struct {
    params: [16]u16 = .{0} ** 16,
    param_count: u8 = 0,
    intermediates: [2]u8 = .{0} ** 2,
    intermediate_count: u8 = 0,
    final_byte: u8 = 0,
    /// Whether the sequence has a '?' private marker (e.g., \e[?25h).
    private_marker: bool = false,

    /// Get parameter at index with a default value.
    pub fn get(self: *const CsiParams, idx: usize, default: u16) u16 {
        if (idx < self.param_count) {
            const v = self.params[idx];
            return if (v == 0) default else v;
        }
        return default;
    }
};

/// Actions emitted by the parser.
pub const Action = union(enum) {
    /// Printable codepoint (decoded from UTF-8).
    print: u21,
    /// C0 control character (BEL, BS, HT, LF, CR, etc.).
    execute: u8,
    /// CSI escape sequence.
    csi: CsiParams,
    /// OSC string content.
    osc: void, // We ignore OSC content for now
};

/// VT/ANSI escape sequence state machine parser.
/// Feed bytes one at a time via `feed()`, which returns an optional `Action`.
pub const Parser = struct {
    state: State = .ground,
    params: [16]u16 = .{0} ** 16,
    param_count: u8 = 0,
    intermediates: [2]u8 = .{0} ** 2,
    intermediate_count: u8 = 0,
    private_marker: bool = false,

    // UTF-8 decoding state
    utf8_buf: [4]u8 = .{0} ** 4,
    utf8_len: u8 = 0,
    utf8_expected: u8 = 0,

    const State = enum {
        ground,
        escape,
        escape_intermediate,
        csi_entry,
        csi_param,
        csi_intermediate,
        osc_string,
    };

    /// Feed a single byte. Returns an action if one is complete, else null.
    pub fn feed(self: *Parser, byte: u8) ?Action {
        return switch (self.state) {
            .ground => self.handleGround(byte),
            .escape => self.handleEscape(byte),
            .escape_intermediate => self.handleEscapeIntermediate(byte),
            .csi_entry => self.handleCsiEntry(byte),
            .csi_param => self.handleCsiParam(byte),
            .csi_intermediate => self.handleCsiIntermediate(byte),
            .osc_string => self.handleOscString(byte),
        };
    }

    fn handleGround(self: *Parser, byte: u8) ?Action {
        // C0 controls
        if (byte < 0x20 or byte == 0x7f) {
            if (byte == 0x1b) {
                self.state = .escape;
                return null;
            }
            // Actionable C0 controls
            return switch (byte) {
                0x07, // BEL
                0x08, // BS
                0x09, // HT
                0x0A, // LF
                0x0B, // VT (treat as LF)
                0x0C, // FF (treat as LF)
                0x0D, // CR
                => .{ .execute = byte },
                else => null,
            };
        }

        // UTF-8 multi-byte handling
        if (byte >= 0x80) {
            return self.handleUtf8(byte);
        }

        // Printable ASCII
        return .{ .print = @intCast(byte) };
    }

    fn handleUtf8(self: *Parser, byte: u8) ?Action {
        if (self.utf8_expected == 0) {
            // Start of a new multi-byte sequence
            if (byte & 0xE0 == 0xC0) {
                self.utf8_expected = 2;
            } else if (byte & 0xF0 == 0xE0) {
                self.utf8_expected = 3;
            } else if (byte & 0xF8 == 0xF0) {
                self.utf8_expected = 4;
            } else {
                // Invalid start byte or continuation byte without start
                return .{ .print = 0xFFFD }; // replacement char
            }
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            return null;
        }

        // Continuation byte
        if (byte & 0xC0 != 0x80) {
            // Invalid continuation — emit replacement and reprocess
            self.utf8_expected = 0;
            self.utf8_len = 0;
            return .{ .print = 0xFFFD };
        }

        self.utf8_buf[self.utf8_len] = byte;
        self.utf8_len += 1;

        if (self.utf8_len == self.utf8_expected) {
            const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch 0xFFFD;
            self.utf8_expected = 0;
            self.utf8_len = 0;
            return .{ .print = cp };
        }
        return null;
    }

    fn handleEscape(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '[' => {
                // CSI sequence
                self.state = .csi_entry;
                self.resetCsiState();
                return null;
            },
            ']' => {
                // OSC sequence
                self.state = .osc_string;
                return null;
            },
            '(' , ')' , '*' , '+' => {
                // Designate character set — ignore the next byte
                self.state = .escape_intermediate;
                return null;
            },
            '7' => {
                // Save cursor (DECSC) — treat as no-op for now
                self.state = .ground;
                return null;
            },
            '8' => {
                // Restore cursor (DECRC) — treat as no-op for now
                self.state = .ground;
                return null;
            },
            'M' => {
                // Reverse index — scroll down. Emit as CSI 'T' with param 1
                self.state = .ground;
                var csi = CsiParams{};
                csi.params[0] = 1;
                csi.param_count = 1;
                csi.final_byte = 'T';
                return .{ .csi = csi };
            },
            'c' => {
                // Full reset (RIS) — ignore
                self.state = .ground;
                return null;
            },
            else => {
                // Unknown escape, back to ground
                self.state = .ground;
                return null;
            },
        }
    }

    fn handleEscapeIntermediate(self: *Parser, byte: u8) ?Action {
        _ = byte;
        // Absorb single byte after ESC ( / ) / * / + (charset designation)
        self.state = .ground;
        return null;
    }

    fn handleCsiEntry(self: *Parser, byte: u8) ?Action {
        if (byte == '?') {
            self.private_marker = true;
            self.state = .csi_param;
            return null;
        }
        if (byte == '>') {
            // DA2 response marker — just absorb
            self.state = .csi_param;
            return null;
        }
        // Fall through to param handling
        self.state = .csi_param;
        return self.handleCsiParam(byte);
    }

    fn handleCsiParam(self: *Parser, byte: u8) ?Action {
        if (byte >= '0' and byte <= '9') {
            // Accumulate digit
            if (self.param_count == 0) self.param_count = 1;
            const idx = self.param_count - 1;
            if (idx < self.params.len) {
                self.params[idx] = self.params[idx] *% 10 +% @as(u16, byte - '0');
            }
            return null;
        }
        if (byte == ';') {
            // Next parameter
            if (self.param_count == 0) self.param_count = 1;
            if (self.param_count < self.params.len) {
                self.param_count += 1;
            }
            return null;
        }
        if (byte >= 0x20 and byte <= 0x2F) {
            // Intermediate byte
            if (self.intermediate_count < self.intermediates.len) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            self.state = .csi_intermediate;
            return null;
        }
        if (byte >= 0x40 and byte <= 0x7E) {
            // Final byte — dispatch
            return self.dispatchCsi(byte);
        }
        // Ignore other bytes in CSI
        return null;
    }

    fn handleCsiIntermediate(self: *Parser, byte: u8) ?Action {
        if (byte >= 0x20 and byte <= 0x2F) {
            // More intermediates
            if (self.intermediate_count < self.intermediates.len) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            return null;
        }
        if (byte >= 0x40 and byte <= 0x7E) {
            return self.dispatchCsi(byte);
        }
        // Invalid, abort
        self.state = .ground;
        return null;
    }

    fn handleOscString(self: *Parser, byte: u8) ?Action {
        // OSC terminated by BEL (0x07) or ST (ESC \)
        if (byte == 0x07) {
            self.state = .ground;
            return .{ .osc = {} };
        }
        if (byte == 0x1B) {
            // Could be ESC \ (ST) — for simplicity, just go to ground
            self.state = .ground;
            return .{ .osc = {} };
        }
        // Absorb OSC content (we don't use it)
        return null;
    }

    fn dispatchCsi(self: *Parser, final: u8) ?Action {
        self.state = .ground;
        var csi = CsiParams{
            .params = self.params,
            .param_count = self.param_count,
            .intermediates = self.intermediates,
            .intermediate_count = self.intermediate_count,
            .final_byte = final,
            .private_marker = self.private_marker,
        };
        _ = &csi;
        return .{ .csi = csi };
    }

    fn resetCsiState(self: *Parser) void {
        self.params = .{0} ** 16;
        self.param_count = 0;
        self.intermediates = .{0} ** 2;
        self.intermediate_count = 0;
        self.private_marker = false;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "parse printable ascii" {
    var p = Parser{};
    const action = p.feed('A');
    try std.testing.expect(action != null);
    try std.testing.expectEqual(Action{ .print = 'A' }, action.?);
}

test "parse C0 controls" {
    var p = Parser{};

    const lf = p.feed(0x0A);
    try std.testing.expect(lf != null);
    try std.testing.expectEqual(Action{ .execute = 0x0A }, lf.?);

    const cr = p.feed(0x0D);
    try std.testing.expect(cr != null);
    try std.testing.expectEqual(Action{ .execute = 0x0D }, cr.?);
}

test "parse simple CSI" {
    var p = Parser{};

    // \e[2J — erase entire display
    try std.testing.expect(p.feed(0x1B) == null); // ESC
    try std.testing.expect(p.feed('[') == null); // CSI
    try std.testing.expect(p.feed('2') == null); // param
    const action = p.feed('J'); // final
    try std.testing.expect(action != null);
    switch (action.?) {
        .csi => |csi| {
            try std.testing.expectEqual(@as(u8, 'J'), csi.final_byte);
            try std.testing.expectEqual(@as(u16, 2), csi.params[0]);
        },
        else => return error.UnexpectedAction,
    }
}

test "parse CSI with multiple params" {
    var p = Parser{};

    // \e[10;20H — cursor position
    try std.testing.expect(p.feed(0x1B) == null);
    try std.testing.expect(p.feed('[') == null);
    try std.testing.expect(p.feed('1') == null);
    try std.testing.expect(p.feed('0') == null);
    try std.testing.expect(p.feed(';') == null);
    try std.testing.expect(p.feed('2') == null);
    try std.testing.expect(p.feed('0') == null);
    const action = p.feed('H');
    try std.testing.expect(action != null);
    switch (action.?) {
        .csi => |csi| {
            try std.testing.expectEqual(@as(u8, 'H'), csi.final_byte);
            try std.testing.expectEqual(@as(u8, 2), csi.param_count);
            try std.testing.expectEqual(@as(u16, 10), csi.params[0]);
            try std.testing.expectEqual(@as(u16, 20), csi.params[1]);
        },
        else => return error.UnexpectedAction,
    }
}

test "parse private mode CSI" {
    var p = Parser{};

    // \e[?25l — hide cursor
    try std.testing.expect(p.feed(0x1B) == null);
    try std.testing.expect(p.feed('[') == null);
    try std.testing.expect(p.feed('?') == null);
    try std.testing.expect(p.feed('2') == null);
    try std.testing.expect(p.feed('5') == null);
    const action = p.feed('l');
    try std.testing.expect(action != null);
    switch (action.?) {
        .csi => |csi| {
            try std.testing.expectEqual(@as(u8, 'l'), csi.final_byte);
            try std.testing.expect(csi.private_marker);
            try std.testing.expectEqual(@as(u16, 25), csi.params[0]);
        },
        else => return error.UnexpectedAction,
    }
}

test "parse SGR" {
    var p = Parser{};

    // \e[1;31m — bold + red foreground
    try std.testing.expect(p.feed(0x1B) == null);
    try std.testing.expect(p.feed('[') == null);
    try std.testing.expect(p.feed('1') == null);
    try std.testing.expect(p.feed(';') == null);
    try std.testing.expect(p.feed('3') == null);
    try std.testing.expect(p.feed('1') == null);
    const action = p.feed('m');
    try std.testing.expect(action != null);
    switch (action.?) {
        .csi => |csi| {
            try std.testing.expectEqual(@as(u8, 'm'), csi.final_byte);
            try std.testing.expectEqual(@as(u8, 2), csi.param_count);
            try std.testing.expectEqual(@as(u16, 1), csi.params[0]);
            try std.testing.expectEqual(@as(u16, 31), csi.params[1]);
        },
        else => return error.UnexpectedAction,
    }
}

test "parse UTF-8 two byte" {
    var p = Parser{};

    // é = U+00E9 = 0xC3 0xA9
    try std.testing.expect(p.feed(0xC3) == null);
    const action = p.feed(0xA9);
    try std.testing.expect(action != null);
    try std.testing.expectEqual(Action{ .print = 0x00E9 }, action.?);
}
