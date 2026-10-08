//! Matching-bracket lookup for the editor highlight, `goto_matching_bracket`
//! and smart Enter. A plain nesting-aware byte scan: brackets inside strings
//! and comments count too (syntax-aware matching is a later refinement).
//! `text` is anything with `byteAt(i) ?u8` and `byteLen()` — the gap buffer
//! directly, so no frame ever moves the gap just to look around the caret.
const std = @import("std");

pub const Pair = struct { open: usize, close: usize };

/// Bytes scanned per lookup before giving up, so a huge unbalanced file
/// never stalls a frame.
pub const scan_limit: usize = 200_000;

const Partner = struct { other: u8, opening: bool };

fn partner(c: u8) ?Partner {
    return switch (c) {
        '(' => .{ .other = ')', .opening = true },
        '[' => .{ .other = ']', .opening = true },
        '{' => .{ .other = '}', .opening = true },
        ')' => .{ .other = '(', .opening = false },
        ']' => .{ .other = '[', .opening = false },
        '}' => .{ .other = '{', .opening = false },
        else => null,
    };
}

/// True when `open` and `close` form a bracket pair, e.g. '{' and '}'.
pub fn closes(open: u8, close: u8) bool {
    const p = partner(open) orelse return false;
    return p.opening and p.other == close;
}

/// The bracket the caret is "on": the byte just before the caret (the one
/// just typed) wins over the byte at the caret.
pub fn bracketAt(text: anytype, caret: usize) ?usize {
    if (caret > 0) if (text.byteAt(caret - 1)) |c| if (partner(c) != null) return caret - 1;
    if (text.byteAt(caret)) |c| if (partner(c) != null) return caret;
    return null;
}

/// The pair the bracket at `idx` belongs to, or null when it is unmatched
/// (or its partner lies beyond the scan budget).
pub fn matchFor(text: anytype, idx: usize) ?Pair {
    const c = text.byteAt(idx) orelse return null;
    const p = partner(c) orelse return null;
    var depth: usize = 0;
    var steps: usize = 0;
    if (p.opening) {
        var i = idx + 1;
        const len = text.byteLen();
        while (i < len and steps < scan_limit) : ({
            i += 1;
            steps += 1;
        }) {
            const b = text.byteAt(i) orelse break;
            if (b == c) {
                depth += 1;
            } else if (b == p.other) {
                if (depth == 0) return .{ .open = idx, .close = i };
                depth -= 1;
            }
        }
    } else {
        var i = idx;
        while (i > 0 and steps < scan_limit) : (steps += 1) {
            i -= 1;
            const b = text.byteAt(i) orelse break;
            if (b == c) {
                depth += 1;
            } else if (b == p.other) {
                if (depth == 0) return .{ .open = i, .close = idx };
                depth -= 1;
            }
        }
    }
    return null;
}

/// The pair for the bracket under the caret (see `bracketAt`).
pub fn matchAtCaret(text: anytype, caret: usize) ?Pair {
    const idx = bracketAt(text, caret) orelse return null;
    return matchFor(text, idx);
}

const Slice = struct {
    s: []const u8,
    fn byteAt(self: Slice, i: usize) ?u8 {
        return if (i < self.s.len) self.s[i] else null;
    }
    fn byteLen(self: Slice) usize {
        return self.s.len;
    }
};

test "brackets: nesting-aware matching in both directions" {
    const t = std.testing;
    const s = Slice{ .s = "fn f(a: [2]u8) { if (x) { y(); } }" };
    // Caret right after the first '(' matches its ')'.
    const p = matchAtCaret(s, 5).?;
    try t.expectEqual(@as(usize, 4), p.open);
    try t.expectEqual(@as(usize, 13), p.close);
    // On the outer '}' (last byte): the outer '{'.
    const q = matchAtCaret(s, s.s.len - 1).?;
    try t.expectEqual(@as(usize, 15), q.open);
    try t.expectEqual(@as(usize, s.s.len - 1), q.close);
    // The inner block, skipping the nested "()" pair.
    const inner = matchFor(s, 24).?;
    try t.expectEqual(@as(usize, 24), inner.open);
    try t.expectEqual(@as(usize, 31), inner.close);
}

test "brackets: the byte before the caret wins, unmatched brackets give null" {
    const t = std.testing;
    const s = Slice{ .s = "(a)(b)" };
    const p = matchAtCaret(s, 3).?; // between ')' and '(': the ')' just typed
    try t.expectEqual(@as(usize, 0), p.open);
    try t.expectEqual(@as(usize, 2), p.close);
    try t.expect(matchAtCaret(Slice{ .s = "if (x { y }" }, 4) == null);
    try t.expect(matchAtCaret(Slice{ .s = "plain" }, 2) == null);
    try t.expect(closes('{', '}'));
    try t.expect(closes('(', ')'));
    try t.expect(!closes('}', '{'));
    try t.expect(!closes('(', ']'));
}
