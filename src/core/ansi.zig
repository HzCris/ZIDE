//! Parser for the VT / ANSI escape sequences a shell writes: CSI, OSC and DCS
//! sequences, colors and attributes, cursor movement, erasing. The terminal
//! applies the actions it yields to its cell grid.
const std = @import("std");

/// Parameters parsed from a CSI sequence (e.g., \e[1;31m).
pub const CsiParams = struct {
    params: [16]u16 = .{0} ** 16,
    param_count: u8 = 0,
    /// Bit i set: params[i] is a colon sub-parameter of the parameter
    /// before it (`CSI 4:3 m` is SGR 4 with sub-parameter 3, not SGR 43).
    sub_mask: u16 = 0,
    intermediates: [2]u8 = .{0} ** 2,
    intermediate_count: u8 = 0,
    final_byte: u8 = 0,
    /// Private marker right after the CSI (`?`, `>`, `=` or `<`), 0 if none.
    /// Only `?` sequences are private modes; the others (vim's
    /// modifyOtherKeys `CSI > 4;2 m`, DA2 queries, ...) must never be read
    /// as their unmarked namesakes.
    marker: u8 = 0,
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

    /// Whether params[idx] was introduced by ':' (a sub-parameter of the
    /// parameter before it).
    pub fn isSub(self: *const CsiParams, idx: usize) bool {
        if (idx >= self.param_count or idx >= self.params.len) return false;
        return (self.sub_mask >> @intCast(idx)) & 1 != 0;
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
    /// Plain escape sequence final byte: '7' DECSC, '8' DECRC, 'M' RI
    /// (reverse index), 'D' IND (index), 'E' NEL (next line).
    esc: u8,
};

/// VT/ANSI escape sequence state machine parser.
/// Feed bytes one at a time via `feed()`, which returns an optional `Action`.
/// Framing follows DEC/xterm: ESC always starts a new sequence (abandoning
/// an unfinished one), CAN/SUB cancel, the other C0 controls execute inside
/// a sequence without ending it, and DCS/SOS/PM/APC payloads are swallowed
/// up to their string terminator (they are never text).
pub const Parser = struct {
    state: State = .ground,
    params: [16]u16 = .{0} ** 16,
    param_count: u8 = 0,
    sub_mask: u16 = 0,
    intermediates: [2]u8 = .{0} ** 2,
    intermediate_count: u8 = 0,
    marker: u8 = 0,

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
        /// A malformed CSI (a marker after the parameters, parameters after
        /// an intermediate): consumed up to its final byte, never dispatched.
        csi_ignore,
        osc_string,
        osc_esc,
        /// DCS / SOS / PM / APC payload (neovim's XTGETTCAP, kitty
        /// graphics, ...): swallowed up to ST (ESC \) or BEL.
        string,
        string_esc,
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
            .csi_ignore => self.handleCsiIgnore(byte),
            .osc_string => self.handleOscString(byte),
            .osc_esc => self.handleOscEsc(byte),
            .string => self.handleString(byte),
            .string_esc => self.handleStringEsc(byte),
        };
    }

    /// The C0 controls the terminal acts on; the others are ignored.
    fn executeC0(byte: u8) ?Action {
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

    const Control = union(enum) {
        /// Not a control byte: the state handles it.
        none,
        /// Consumed (with this action, if any).
        handled: ?Action,
    };

    /// Bytes every escape and control-sequence state treats alike: ESC
    /// restarts a sequence, CAN/SUB cancel it, and the other C0 controls
    /// execute in place.
    fn sequenceControl(self: *Parser, byte: u8) Control {
        switch (byte) {
            0x1B => {
                self.state = .escape;
                return .{ .handled = null };
            },
            0x18, 0x1A => {
                self.state = .ground;
                return .{ .handled = null };
            },
            0x00...0x17, 0x19, 0x1C...0x1F => return .{ .handled = executeC0(byte) },
            else => return .none,
        }
    }

    fn handleGround(self: *Parser, byte: u8) ?Action {
        // UTF-8 multi-byte handling
        if (byte >= 0x80) {
            return self.handleUtf8(byte);
        }
        // Any ASCII byte ends an unfinished UTF-8 sequence (dropped): it
        // must not be completed by continuation bytes that come later.
        self.utf8_expected = 0;
        self.utf8_len = 0;

        // C0 controls
        if (byte < 0x20 or byte == 0x7f) {
            if (byte == 0x1b) {
                self.state = .escape;
                return null;
            }
            return executeC0(byte);
        }

        // Printable ASCII
        return .{ .print = @intCast(byte) };
    }

    fn handleUtf8(self: *Parser, byte: u8) ?Action {
        if (self.utf8_expected != 0) {
            if (byte & 0xC0 == 0x80) {
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
            // A new lead byte cut the sequence short: U+FFFD for the broken
            // one, and this byte starts the next (it used to be dropped,
            // taking the character it began with it).
            self.utf8_expected = 0;
            self.utf8_len = 0;
            _ = self.startUtf8(byte);
            return .{ .print = 0xFFFD };
        }
        return self.startUtf8(byte);
    }

    /// Begin a multi-byte sequence at a lead byte; U+FFFD for a byte that
    /// cannot start one (a stray continuation byte, 0xF8..0xFF).
    fn startUtf8(self: *Parser, byte: u8) ?Action {
        const len: u8 = if (byte & 0xE0 == 0xC0) 2 else if (byte & 0xF0 == 0xE0) 3 else if (byte & 0xF8 == 0xF0) 4 else 0;
        if (len == 0) return .{ .print = 0xFFFD };
        self.utf8_buf[0] = byte;
        self.utf8_len = 1;
        self.utf8_expected = len;
        return null;
    }

    fn handleEscape(self: *Parser, byte: u8) ?Action {
        // ESC ESC restarts (the first one is abandoned), CAN/SUB cancel,
        // other C0 controls execute and the escape continues.
        switch (self.sequenceControl(byte)) {
            .handled => |action| return action,
            .none => {},
        }
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
            'P', 'X', '^', '_' => {
                // DCS / SOS / PM / APC: the payload is not text
                self.state = .string;
                return null;
            },
            0x20...0x2F => {
                // Intermediates (charset designation ESC ( B, DECALN ESC # 8,
                // ESC % G, ...): absorbed up to the final byte
                self.state = .escape_intermediate;
                return null;
            },
            '7', '8', 'M', 'D', 'E' => {
                // DECSC / DECRC / RI / IND / NEL
                self.state = .ground;
                return .{ .esc = byte };
            },
            else => {
                // Full reset (RIS, 'c') and unknown escapes are ignored
                self.state = .ground;
                return null;
            },
        }
    }

    fn handleEscapeIntermediate(self: *Parser, byte: u8) ?Action {
        switch (self.sequenceControl(byte)) {
            .handled => |action| return action,
            .none => {},
        }
        // More intermediates stay here; a final byte ends the (ignored)
        // sequence.
        if (byte >= 0x30 and byte <= 0x7E) self.state = .ground;
        return null;
    }

    fn handleCsiEntry(self: *Parser, byte: u8) ?Action {
        if (byte >= 0x3C and byte <= 0x3F) {
            // Private marker: '<' '=' '>' '?'
            self.marker = byte;
            self.state = .csi_param;
            return null;
        }
        // Fall through to param handling
        self.state = .csi_param;
        return self.handleCsiParam(byte);
    }

    fn handleCsiParam(self: *Parser, byte: u8) ?Action {
        switch (self.sequenceControl(byte)) {
            .handled => |action| return action,
            .none => {},
        }
        switch (byte) {
            '0'...'9' => {
                // Accumulate digit
                if (self.param_count == 0) self.param_count = 1;
                const idx = self.param_count - 1;
                if (idx < self.params.len) {
                    self.params[idx] = self.params[idx] *% 10 +% @as(u16, byte - '0');
                }
            },
            ';', ':' => {
                // Next parameter; ':' makes it a sub-parameter of the one
                // before it
                if (self.param_count == 0) self.param_count = 1;
                if (self.param_count < self.params.len) {
                    self.param_count += 1;
                    if (byte == ':') self.sub_mask |= @as(u16, 1) << @intCast(self.param_count - 1);
                }
            },
            0x3C...0x3F => {
                // A marker after the parameters: malformed, never dispatched
                self.state = .csi_ignore;
            },
            0x20...0x2F => {
                // Intermediate byte
                self.pushIntermediate(byte);
                self.state = .csi_intermediate;
            },
            0x40...0x7E => {
                // Final byte — dispatch
                return self.dispatchCsi(byte);
            },
            else => {}, // DEL and bytes >= 0x80 are ignored inside a CSI
        }
        return null;
    }

    fn handleCsiIntermediate(self: *Parser, byte: u8) ?Action {
        switch (self.sequenceControl(byte)) {
            .handled => |action| return action,
            .none => {},
        }
        switch (byte) {
            // More intermediates
            0x20...0x2F => self.pushIntermediate(byte),
            // Parameters after an intermediate: malformed
            0x30...0x3F => self.state = .csi_ignore,
            0x40...0x7E => return self.dispatchCsi(byte),
            else => {},
        }
        return null;
    }

    fn handleCsiIgnore(self: *Parser, byte: u8) ?Action {
        switch (self.sequenceControl(byte)) {
            .handled => |action| return action,
            .none => {},
        }
        if (byte >= 0x40 and byte <= 0x7E) self.state = .ground;
        return null;
    }

    fn pushIntermediate(self: *Parser, byte: u8) void {
        if (self.intermediate_count < self.intermediates.len) {
            self.intermediates[self.intermediate_count] = byte;
            self.intermediate_count += 1;
        }
    }

    fn handleOscString(self: *Parser, byte: u8) ?Action {
        // OSC terminated by BEL (0x07) or ST (ESC \)
        if (byte == 0x07) {
            self.state = .ground;
            return .{ .osc = {} };
        }
        if (byte == 0x1B) {
            // Likely ST (ESC \) — consume the next byte instead of letting
            // the '\' print into the terminal.
            self.state = .osc_esc;
            return null;
        }
        if (byte == 0x18 or byte == 0x1A) {
            // CAN / SUB cancel the string
            self.state = .ground;
            return null;
        }
        // Absorb OSC content (we don't use it)
        return null;
    }

    fn handleOscEsc(self: *Parser, byte: u8) ?Action {
        if (byte == '\\') {
            // ST — OSC complete
            self.state = .ground;
            return .{ .osc = {} };
        }
        // ESC followed by something else: abandon the OSC and process the
        // byte as the start of a fresh escape sequence.
        self.state = .escape;
        return self.handleEscape(byte);
    }

    fn handleString(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x07, 0x18, 0x1A => self.state = .ground, // BEL ends it, CAN/SUB cancel
            0x1B => self.state = .string_esc,
            else => {}, // payload
        }
        return null;
    }

    fn handleStringEsc(self: *Parser, byte: u8) ?Action {
        if (byte == '\\') {
            // ST — payload complete
            self.state = .ground;
            return null;
        }
        // ESC + anything else: the string ended without ST; the byte
        // starts a fresh escape sequence.
        self.state = .escape;
        return self.handleEscape(byte);
    }

    fn dispatchCsi(self: *Parser, final: u8) ?Action {
        self.state = .ground;
        return .{ .csi = .{
            .params = self.params,
            .param_count = self.param_count,
            .sub_mask = self.sub_mask,
            .intermediates = self.intermediates,
            .intermediate_count = self.intermediate_count,
            .final_byte = final,
            .marker = self.marker,
            .private_marker = self.marker == '?',
        } };
    }

    fn resetCsiState(self: *Parser) void {
        self.params = .{0} ** 16;
        self.param_count = 0;
        self.sub_mask = 0;
        self.intermediates = .{0} ** 2;
        self.intermediate_count = 0;
        self.marker = 0;
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

/// Test helper: feed `bytes` and collect the printed text (UTF-8) and the
/// last CSI seen.
const Replay = struct {
    text: [64]u8 = undefined,
    len: usize = 0,
    last_csi: ?CsiParams = null,
    csi_count: usize = 0,

    fn run(bytes: []const u8) Replay {
        var p = Parser{};
        var r: Replay = .{};
        for (bytes) |b| {
            const action = p.feed(b) orelse continue;
            switch (action) {
                .print => |cp| r.len += std.unicode.utf8Encode(cp, r.text[r.len..]) catch 0,
                .csi => |csi| {
                    r.last_csi = csi;
                    r.csi_count += 1;
                },
                else => {},
            }
        }
        return r;
    }

    fn printed(self: *const Replay) []const u8 {
        return self.text[0..self.len];
    }
};

test "DCS, SOS, PM and APC payloads never print" {
    // neovim's XTGETTCAP query, a kitty graphics APC, then text
    var r = Replay.run("\x1bP+q544e\x1b\\\x1b_Gf=100;AAAA\x1b\\A");
    try std.testing.expectEqualStrings("A", r.printed());
    // BEL also ends the string; SOS and PM are swallowed the same way
    r = Replay.run("\x1bXsos\x07\x1b^pm\x1b\\B");
    try std.testing.expectEqualStrings("B", r.printed());
}

test "ESC inside an unfinished CSI starts a new sequence" {
    const r = Replay.run("\x1b[12\x1b[HX");
    try std.testing.expectEqualStrings("X", r.printed());
    try std.testing.expectEqual(@as(usize, 1), r.csi_count);
    try std.testing.expectEqual(@as(u8, 'H'), r.last_csi.?.final_byte);
    try std.testing.expectEqual(@as(u8, 0), r.last_csi.?.param_count);
}

test "ESC ESC [ 31m is one SGR, nothing printed" {
    const r = Replay.run("\x1b\x1b[31mA");
    try std.testing.expectEqualStrings("A", r.printed());
    try std.testing.expectEqual(@as(u8, 'm'), r.last_csi.?.final_byte);
    try std.testing.expectEqual(@as(u16, 31), r.last_csi.?.params[0]);
}

test "private markers are recorded, not dropped" {
    // vim's modifyOtherKeys: CSI > 4;2 m is not SGR 4 (underline)
    var r = Replay.run("\x1b[>4;2mA");
    try std.testing.expectEqual(@as(u8, '>'), r.last_csi.?.marker);
    try std.testing.expect(!r.last_csi.?.private_marker);
    try std.testing.expectEqualStrings("A", r.printed());
    r = Replay.run("\x1b[?1049h");
    try std.testing.expectEqual(@as(u8, '?'), r.last_csi.?.marker);
    try std.testing.expect(r.last_csi.?.private_marker);
    // A marker after the parameters is malformed: consumed, not dispatched
    r = Replay.run("\x1b[4?mA");
    try std.testing.expectEqual(@as(usize, 0), r.csi_count);
    try std.testing.expectEqualStrings("A", r.printed());
}

test "colon sub-parameters stay attached to their parameter" {
    // Undercurl: SGR 4 with sub-parameter 3 — not SGR 43 (yellow background)
    const r = Replay.run("\x1b[4:3;1mA");
    const csi = r.last_csi.?;
    try std.testing.expectEqual(@as(u8, 3), csi.param_count);
    try std.testing.expectEqual(@as(u16, 4), csi.params[0]);
    try std.testing.expectEqual(@as(u16, 3), csi.params[1]);
    try std.testing.expectEqual(@as(u16, 1), csi.params[2]);
    try std.testing.expect(!csi.isSub(0) and csi.isSub(1) and !csi.isSub(2));
}

test "C0 controls inside a sequence execute; CAN cancels" {
    var p = Parser{};
    try std.testing.expect(p.feed(0x1B) == null);
    try std.testing.expect(p.feed('[') == null);
    try std.testing.expect(p.feed('2') == null);
    try std.testing.expectEqual(Action{ .execute = 0x0D }, p.feed(0x0D).?);
    const action = p.feed('A').?;
    try std.testing.expectEqual(@as(u8, 'A'), action.csi.final_byte);
    try std.testing.expectEqual(@as(u16, 2), action.csi.params[0]);
    const r = Replay.run("\x1b[3\x18B");
    try std.testing.expectEqualStrings("B", r.printed());
    try std.testing.expectEqual(@as(usize, 0), r.csi_count);
}

test "a broken UTF-8 sequence does not swallow the next character" {
    // Stray lead byte, then ASCII, then a valid two-byte character
    var r = Replay.run("\xE2A\xC3\xA9");
    try std.testing.expectEqualStrings("A\u{e9}", r.printed());
    // A lead byte cutting a sequence short: U+FFFD, then the new character
    r = Replay.run("\xE2\x82\xC3\xA9");
    try std.testing.expectEqualStrings("\u{fffd}\u{e9}", r.printed());
}

test "ESC intermediates and RI/IND/NEL" {
    var r = Replay.run("\x1b(B\x1b#8\x1b%GA");
    try std.testing.expectEqualStrings("A", r.printed());
    var p = Parser{};
    _ = p.feed(0x1B);
    try std.testing.expectEqual(Action{ .esc = 'M' }, p.feed('M').?);
    _ = p.feed(0x1B);
    try std.testing.expectEqual(Action{ .esc = 'D' }, p.feed('D').?);
    _ = p.feed(0x1B);
    try std.testing.expectEqual(Action{ .esc = 'E' }, p.feed('E').?);
    r = Replay.run("\x1bcZ");
    try std.testing.expectEqualStrings("Z", r.printed());
}
