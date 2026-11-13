//! A single-line text box shared by the frontends: its bytes, a caret, a
//! selection and a short undo list, plus a list of earlier entries. The find
//! bar is the first user. Painting, keyboard focus and the clipboard stay
//! with the callers. Offsets are bytes and always sit on code-point
//! boundaries (the caret moves by code point, like the document's).
const std = @import("std");
const text_input = @import("text_input.zig");
const isWordByte = @import("cursor.zig").isWordByte;

pub const Range = struct { start: usize, end: usize };

/// A text box holding at most `capacity` bytes.
pub fn LineEdit(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const max_len = capacity;
        const undo_depth = 16;
        const Snapshot = struct { buf: [capacity]u8, len: usize, caret: usize };
        /// What the last edit was: a run of typed characters is one undo
        /// step, and so is a run of Backspace / Delete presses.
        const Run = enum { none, typing, erasing };

        buf: [capacity]u8 = undefined,
        len: usize = 0,
        /// Where typing goes.
        caret: usize = 0,
        /// The other end of the selection; null or equal to the caret: none.
        anchor: ?usize = null,
        /// First byte the box shows. The painters own it (`scrollToCaret`).
        scroll: usize = 0,
        /// Undo steps in `states[0..undo_len]`, oldest first; the redo steps
        /// follow them, next one first.
        states: [undo_depth]Snapshot = undefined,
        undo_len: usize = 0,
        redo_len: usize = 0,
        run: Run = .none,

        pub fn text(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn selection(self: *const Self) ?Range {
            const a = self.anchor orelse return null;
            if (a == self.caret) return null;
            return .{ .start = @min(a, self.caret), .end = @max(a, self.caret) };
        }

        pub fn selectedText(self: *const Self) []const u8 {
            const r = self.selection() orelse return "";
            return self.buf[r.start..r.end];
        }

        // ---- Moving ----

        /// The boundary before `at` (0 at the start).
        pub fn prev(self: *const Self, at: usize) usize {
            if (at == 0) return 0;
            return text_input.floor(self.text(), @min(at, self.len) - 1);
        }

        /// The boundary after `at` (the length at the end).
        pub fn next(self: *const Self, at: usize) usize {
            if (at >= self.len) return self.len;
            var n = at + 1;
            while (n < self.len and self.buf[n] & 0xc0 == 0x80) n += 1;
            return n;
        }

        /// Start of the word before `from`, as Ctrl+Left moves in a document.
        fn wordLeft(self: *const Self, from: usize) usize {
            var n = from;
            while (n > 0 and !isWordByte(self.buf[n - 1])) n -= 1;
            while (n > 0 and isWordByte(self.buf[n - 1])) n -= 1;
            return n;
        }

        /// Start of the word after `from`, as Ctrl+Right moves in a document.
        fn wordRight(self: *const Self, from: usize) usize {
            var n = from;
            while (n < self.len and isWordByte(self.buf[n])) n += 1;
            while (n < self.len and !isWordByte(self.buf[n])) n += 1;
            return n;
        }

        fn moveTo(self: *Self, to: usize, select: bool) void {
            if (select) {
                if (self.anchor == null) self.anchor = self.caret;
            } else {
                self.anchor = null;
            }
            self.caret = to;
            self.run = .none;
        }

        /// Left: without `select` a selection collapses to its start.
        pub fn moveLeft(self: *Self, select: bool) void {
            if (!select) if (self.selection()) |r| return self.moveTo(r.start, false);
            self.moveTo(self.prev(self.caret), select);
        }

        /// Right: without `select` a selection collapses to its end.
        pub fn moveRight(self: *Self, select: bool) void {
            if (!select) if (self.selection()) |r| return self.moveTo(r.end, false);
            self.moveTo(self.next(self.caret), select);
        }

        pub fn moveWordLeft(self: *Self, select: bool) void {
            self.moveTo(self.wordLeft(self.caret), select);
        }

        pub fn moveWordRight(self: *Self, select: bool) void {
            self.moveTo(self.wordRight(self.caret), select);
        }

        pub fn moveHome(self: *Self, select: bool) void {
            self.moveTo(0, select);
        }

        pub fn moveEnd(self: *Self, select: bool) void {
            self.moveTo(self.len, select);
        }

        pub fn selectAll(self: *Self) void {
            self.anchor = 0;
            self.caret = self.len;
            self.run = .none;
        }

        /// Put the caret at `offset` (a click), or extend the selection to
        /// it (a drag, Shift+click). Snapped back to a character.
        pub fn setCaret(self: *Self, offset: usize, select: bool) void {
            self.moveTo(text_input.floor(self.text(), @min(offset, self.len)), select);
        }

        /// Select the word that touches `offset` (a double-click); away from
        /// any word the caret just goes there.
        pub fn selectWordAt(self: *Self, offset: usize) void {
            const at = text_input.floor(self.text(), @min(offset, self.len));
            var start = at;
            var end = at;
            while (start > 0 and isWordByte(self.buf[start - 1])) start -= 1;
            while (end < self.len and isWordByte(self.buf[end])) end += 1;
            self.anchor = start;
            self.caret = end;
            self.run = .none;
        }

        // ---- Editing ----

        fn snapshot(self: *const Self) Snapshot {
            var s: Snapshot = .{ .buf = undefined, .len = self.len, .caret = self.caret };
            @memcpy(s.buf[0..self.len], self.buf[0..self.len]);
            return s;
        }

        fn restore(self: *Self, s: *const Snapshot) void {
            @memcpy(self.buf[0..s.len], s.buf[0..s.len]);
            self.len = s.len;
            self.caret = s.caret;
            self.anchor = null;
            self.run = .none;
        }

        /// Keep the text as it is now as an undo step (the oldest goes when
        /// the list is full). Whatever could be redone is gone.
        fn pushUndo(self: *Self) void {
            self.redo_len = 0;
            if (self.undo_len == undo_depth) {
                std.mem.copyForwards(Snapshot, self.states[0 .. undo_depth - 1], self.states[1..undo_depth]);
                self.undo_len -= 1;
            }
            self.states[self.undo_len] = self.snapshot();
            self.undo_len += 1;
        }

        fn removeRange(self: *Self, start: usize, end: usize) void {
            std.mem.copyForwards(u8, self.buf[start .. self.len - (end - start)], self.buf[end..self.len]);
            self.len -= end - start;
            self.caret = start;
            self.anchor = null;
        }

        /// Type or paste `txt` at the caret, over the selection. Control
        /// characters are dropped, malformed UTF-8 adds nothing, and what
        /// does not fit is cut on a character. True when the text changed.
        pub fn insert(self: *Self, txt: []const u8) bool {
            var clean: [capacity]u8 = undefined;
            var clean_len: usize = 0;
            text_input.append(&clean, &clean_len, txt);
            const sel = self.selection();
            const sel_len = if (sel) |r| r.end - r.start else 0;
            const room = capacity - (self.len - sel_len);
            const take = text_input.floor(clean[0..clean_len], @min(clean_len, room));
            if (take == 0) return false;
            // One typed character after another is a single undo step.
            const single = sel == null and take == utf8Len(clean[0]);
            if (!(single and self.run == .typing)) self.pushUndo();
            if (sel) |r| self.removeRange(r.start, r.end);
            std.mem.copyBackwards(u8, self.buf[self.caret + take .. self.len + take], self.buf[self.caret..self.len]);
            @memcpy(self.buf[self.caret..][0..take], clean[0..take]);
            self.len += take;
            self.caret += take;
            self.anchor = null;
            self.run = if (single) .typing else .none;
            return true;
        }

        /// Remove the selection (Cut, after the caller copied it).
        pub fn deleteSelection(self: *Self) bool {
            const r = self.selection() orelse return false;
            self.pushUndo();
            self.removeRange(r.start, r.end);
            self.run = .none;
            return true;
        }

        fn erase(self: *Self, start: usize, end: usize, run: Run) bool {
            if (start == end) {
                self.anchor = null;
                return false;
            }
            if (run == .none or self.run != run) self.pushUndo();
            self.removeRange(start, end);
            self.run = run;
            return true;
        }

        /// Backspace: the selection, else the character before the caret.
        pub fn backspace(self: *Self) bool {
            if (self.selection() != null) return self.deleteSelection();
            return self.erase(self.prev(self.caret), self.caret, .erasing);
        }

        /// Delete: the selection, else the character after the caret.
        pub fn deleteForward(self: *Self) bool {
            if (self.selection() != null) return self.deleteSelection();
            return self.erase(self.caret, self.next(self.caret), .erasing);
        }

        /// Ctrl+Backspace: the selection, else back to the word's start.
        pub fn deleteWordBackward(self: *Self) bool {
            if (self.selection() != null) return self.deleteSelection();
            return self.erase(self.wordLeft(self.caret), self.caret, .none);
        }

        /// Ctrl+Delete: the selection, else up to the next word's start.
        pub fn deleteWordForward(self: *Self) bool {
            if (self.selection() != null) return self.deleteSelection();
            return self.erase(self.caret, self.wordRight(self.caret), .none);
        }

        /// Replace the whole text (a prefill, an earlier entry): the caret
        /// goes to the end. One undo step; the same text changes nothing.
        /// True when the text changed.
        pub fn setText(self: *Self, txt: []const u8) bool {
            var clean: [capacity]u8 = undefined;
            var clean_len: usize = 0;
            text_input.append(&clean, &clean_len, txt);
            const same = std.mem.eql(u8, clean[0..clean_len], self.text());
            if (!same) {
                self.pushUndo();
                @memcpy(self.buf[0..clean_len], clean[0..clean_len]);
                self.len = clean_len;
            }
            self.caret = self.len;
            self.anchor = null;
            self.run = .none;
            return !same;
        }

        /// Ctrl+Z: back to the text before the last step. False: none left.
        pub fn undo(self: *Self) bool {
            if (self.undo_len == 0) return false;
            const now = self.snapshot();
            self.restore(&self.states[self.undo_len - 1]);
            self.states[self.undo_len - 1] = now;
            self.undo_len -= 1;
            self.redo_len += 1;
            return true;
        }

        /// Ctrl+Y: the step the last undo took back. False: none left.
        pub fn redo(self: *Self) bool {
            if (self.redo_len == 0) return false;
            const now = self.snapshot();
            self.restore(&self.states[self.undo_len]);
            self.states[self.undo_len] = now;
            self.undo_len += 1;
            self.redo_len -= 1;
            return true;
        }

        // ---- Painting ----

        /// Keep the caret in view of a box that shows the text from
        /// `scroll` on: `fits(ctx, piece)` says whether `piece` fits the
        /// box. Scrolls right until the text before the caret fits, and back
        /// left while the whole rest still fits (a box that has room never
        /// hides the start of its text).
        pub fn scrollToCaret(self: *Self, ctx: anytype, comptime fits: fn (@TypeOf(ctx), []const u8) bool) void {
            self.scroll = text_input.floor(self.text(), @min(self.scroll, self.len));
            if (self.caret < self.scroll) self.scroll = self.caret;
            while (self.scroll < self.caret and !fits(ctx, self.buf[self.scroll..self.caret])) {
                self.scroll = self.next(self.scroll);
            }
            while (self.scroll > 0) {
                const back = self.prev(self.scroll);
                if (!fits(ctx, self.buf[back..self.len])) break;
                self.scroll = back;
            }
        }
    };
}

/// Bytes of the UTF-8 sequence `first` starts (1 for a stray byte).
fn utf8Len(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

/// Earlier entries of a text box, newest first (Up / Down in the box).
pub fn History(comptime capacity: usize, comptime depth: usize) type {
    return struct {
        const Self = @This();

        entries: [depth][capacity]u8 = undefined,
        lens: [depth]usize = @splat(0),
        count: usize = 0,

        pub fn get(self: *const Self, index: usize) []const u8 {
            return self.entries[index][0..self.lens[index]];
        }

        /// Put `txt` first. One that is already listed moves up instead of
        /// showing twice; the oldest goes when the list is full; an empty or
        /// oversized text is ignored.
        pub fn add(self: *Self, txt: []const u8) void {
            if (txt.len == 0 or txt.len > capacity) return;
            var at: usize = self.count;
            for (0..self.count) |i| {
                if (std.mem.eql(u8, self.get(i), txt)) {
                    at = i;
                    break;
                }
            }
            if (at == self.count) {
                if (self.count < depth) self.count += 1 else at = depth - 1;
            }
            // `txt` may be a listed entry itself: copy it out before the shift.
            var keep: [capacity]u8 = undefined;
            @memcpy(keep[0..txt.len], txt);
            const keep_len = txt.len;
            var i = at;
            while (i > 0) : (i -= 1) {
                self.entries[i] = self.entries[i - 1];
                self.lens[i] = self.lens[i - 1];
            }
            @memcpy(self.entries[0][0..keep_len], keep[0..keep_len]);
            self.lens[0] = keep_len;
        }
    };
}

// ---- Tests ----

const t = std.testing;
const Box = LineEdit(16);

test "line edit: typing lands at the caret, replaces the selection and stops at the capacity on a character" {
    var box: Box = .{};
    try t.expect(box.insert("hello"));
    try t.expectEqualStrings("hello", box.text());
    try t.expectEqual(@as(usize, 5), box.caret);

    // In the middle
    box.setCaret(2, false);
    try t.expect(box.insert("XY"));
    try t.expectEqualStrings("heXYllo", box.text());
    try t.expectEqual(@as(usize, 4), box.caret);

    // Over a selection
    box.setCaret(0, false);
    box.setCaret(2, true);
    try t.expectEqualStrings("he", box.selectedText());
    try t.expect(box.insert("J"));
    try t.expectEqualStrings("JXYllo", box.text());
    try t.expectEqual(@as(usize, 1), box.caret);
    try t.expect(box.selection() == null);

    // Control characters and line breaks are dropped; malformed UTF-8 adds nothing
    box.moveEnd(false);
    try t.expect(box.insert("\ta\r\nb\x1b"));
    try t.expectEqualStrings("JXYlloab", box.text());
    try t.expect(!box.insert("z\xff"));
    try t.expect(!box.insert("\n"));
    try t.expectEqualStrings("JXYlloab", box.text());

    // 8 of 16 bytes used: "ééééé" is 10 bytes, only four characters fit
    try t.expect(box.insert("ééééé"));
    try t.expectEqualStrings("JXYlloabéééé", box.text());
    try t.expectEqual(@as(usize, 16), box.len);
    try t.expect(!box.insert("x"));
    // Full, but a selection makes room for what replaces it
    box.setCaret(14, false);
    box.setCaret(16, true);
    try t.expect(box.insert("ab"));
    try t.expectEqualStrings("JXYlloabéééab", box.text());
}

test "line edit: Backspace and Delete take whole characters, the word forms take words, a selection goes first" {
    var box: Box = .{};
    _ = box.insert("día uno");
    try t.expect(box.backspace());
    try t.expectEqualStrings("día un", box.text());
    box.setCaret(1, false);
    try t.expect(box.deleteForward()); // the two bytes of í
    try t.expectEqualStrings("da un", box.text());
    try t.expectEqual(@as(usize, 1), box.caret);
    try t.expect(box.backspace());
    try t.expectEqualStrings("a un", box.text());
    try t.expect(!box.backspace()); // at the start: nothing
    box.moveEnd(false);
    try t.expect(!box.deleteForward()); // at the end: nothing

    _ = box.setText("foo bar_baz  qux");
    try t.expect(box.deleteWordBackward());
    try t.expectEqualStrings("foo bar_baz  ", box.text());
    try t.expect(box.deleteWordBackward()); // the blanks and the word before them
    try t.expectEqualStrings("foo ", box.text());
    box.moveHome(false);
    try t.expect(box.deleteWordForward()); // the word and the blank after it
    try t.expectEqualStrings("", box.text());
    try t.expect(!box.deleteWordForward());
    try t.expect(!box.deleteWordBackward());

    // Any of the four removes just the selection when there is one
    _ = box.setText("abcdef");
    box.setCaret(1, false);
    box.setCaret(3, true);
    try t.expect(box.deleteWordBackward());
    try t.expectEqualStrings("adef", box.text());
    try t.expectEqual(@as(usize, 1), box.caret);
    box.selectAll();
    try t.expect(box.deleteSelection());
    try t.expectEqualStrings("", box.text());
    try t.expect(!box.deleteSelection());
}

test "line edit: the caret moves by character and by word, Shift extends, a plain arrow collapses the selection" {
    var box: Box = .{};
    _ = box.insert("aé b_c, d");
    box.moveHome(false);
    box.moveRight(false);
    box.moveRight(false);
    try t.expectEqual(@as(usize, 3), box.caret); // past the two bytes of é
    box.moveLeft(false);
    try t.expectEqual(@as(usize, 1), box.caret);

    // Words: non-ASCII letters and `_` are word characters
    box.moveHome(false);
    box.moveWordRight(false);
    try t.expectEqual(@as(usize, 4), box.caret); // start of "b_c"
    box.moveWordRight(false);
    try t.expectEqual(@as(usize, 9), box.caret); // start of "d"
    box.moveWordRight(false);
    try t.expectEqual(box.len, box.caret);
    box.moveWordLeft(false);
    try t.expectEqual(@as(usize, 9), box.caret);
    box.moveWordLeft(false);
    try t.expectEqual(@as(usize, 4), box.caret);

    // Shift extends from where the caret was
    box.moveWordRight(true);
    try t.expectEqualStrings("b_c, ", box.selectedText());
    box.moveLeft(true);
    try t.expectEqualStrings("b_c,", box.selectedText());
    // A plain arrow goes to that end of the selection
    box.moveLeft(false);
    try t.expectEqual(@as(usize, 4), box.caret);
    try t.expect(box.selection() == null);
    box.moveEnd(true);
    box.moveRight(false);
    try t.expectEqual(box.len, box.caret);
    try t.expect(box.selection() == null);
    box.moveHome(true);
    try t.expectEqualStrings("aé b_c, d", box.selectedText());

    // Clicks: snapped back to a character; a double-click takes the word
    box.setCaret(2, false); // inside é
    try t.expectEqual(@as(usize, 1), box.caret);
    box.setCaret(99, false);
    try t.expectEqual(box.len, box.caret);
    box.selectWordAt(5);
    try t.expectEqualStrings("b_c", box.selectedText());
    box.selectWordAt(2); // inside é: the word "aé"
    try t.expectEqualStrings("aé", box.selectedText());
    box.selectWordAt(7); // right after "b_c": that word
    try t.expectEqualStrings("b_c", box.selectedText());
    box.selectWordAt(8); // between the comma and the blank: no word
    try t.expect(box.selection() == null);
    try t.expectEqual(@as(usize, 8), box.caret);
    box.selectWordAt(box.len); // after the last word
    try t.expectEqualStrings("d", box.selectedText());
    box.selectAll();
    try t.expectEqualStrings("aé b_c, d", box.selectedText());
}

test "line edit: undo takes back a run of typing, a run of erasing or one other change; redo brings it back" {
    var box: Box = .{};
    try t.expect(!box.undo());
    for ("abc") |ch| _ = box.insert(&.{ch});
    _ = box.backspace();
    _ = box.backspace();
    try t.expectEqualStrings("a", box.text());
    try t.expect(box.undo()); // both Backspace presses
    try t.expectEqualStrings("abc", box.text());
    try t.expect(box.undo()); // the three typed letters
    try t.expectEqualStrings("", box.text());
    try t.expect(!box.undo());
    try t.expect(box.redo());
    try t.expectEqualStrings("abc", box.text());
    try t.expectEqual(@as(usize, 3), box.caret);
    try t.expect(box.redo());
    try t.expectEqualStrings("a", box.text());
    try t.expect(!box.redo());

    // Moving the caret ends a typing run; a paste is a step of its own
    _ = box.insert("b");
    box.moveLeft(false);
    box.moveRight(false);
    _ = box.insert("c");
    _ = box.insert("XY");
    _ = box.insert("d");
    try t.expectEqualStrings("abcXYd", box.text());
    try t.expect(box.undo());
    try t.expectEqualStrings("abcXY", box.text());
    try t.expect(box.undo());
    try t.expectEqualStrings("abc", box.text());
    try t.expect(box.undo());
    try t.expectEqualStrings("ab", box.text());
    // A new edit drops what could be redone
    _ = box.insert("!");
    try t.expect(!box.redo());
    try t.expectEqualStrings("ab!", box.text());

    // setText is one step, and the same text is none
    try t.expect(box.setText("other"));
    try t.expect(!box.setText("other"));
    try t.expect(box.undo());
    try t.expectEqualStrings("ab!", box.text());

    // Only the newest steps are kept
    var many: Box = .{};
    for (0..40) |i| {
        _ = many.setText(if (i % 2 == 0) "even" else "odd");
    }
    var steps: usize = 0;
    while (many.undo()) steps += 1;
    try t.expectEqual(@as(usize, 16), steps);
}

/// Tests: a box that shows `width` code points.
fn fitsChars(width: usize, piece: []const u8) bool {
    return (std.unicode.utf8CountCodepoints(piece) catch piece.len) <= width;
}

test "line edit: the view follows the caret and never hides text a box has room for" {
    var box: Box = .{};
    _ = box.insert("0123456789ab");
    box.scrollToCaret(@as(usize, 5), fitsChars);
    try t.expectEqual(@as(usize, 7), box.scroll); // "789ab" before the caret
    box.moveHome(false);
    box.scrollToCaret(@as(usize, 5), fitsChars);
    try t.expectEqual(@as(usize, 0), box.scroll);
    box.setCaret(8, false);
    box.scrollToCaret(@as(usize, 5), fitsChars);
    try t.expectEqual(@as(usize, 3), box.scroll);
    // Deleting at the end pulls the text back in instead of leaving a gap
    box.moveEnd(false);
    box.scrollToCaret(@as(usize, 5), fitsChars);
    try t.expectEqual(@as(usize, 7), box.scroll);
    for (0..4) |_| _ = box.backspace();
    box.scrollToCaret(@as(usize, 5), fitsChars);
    try t.expectEqual(@as(usize, 3), box.scroll);
    // A wider box shows everything
    box.scrollToCaret(@as(usize, 40), fitsChars);
    try t.expectEqual(@as(usize, 0), box.scroll);
    // Never inside a character
    _ = box.setText("ééééé");
    box.scroll = 3;
    box.scrollToCaret(@as(usize, 2), fitsChars);
    try t.expectEqual(@as(usize, 6), box.scroll);
}

test "line history: newest first, a repeated entry moves up, the oldest drops off" {
    var h: History(8, 3) = .{};
    h.add("");
    h.add("too long for it");
    try t.expectEqual(@as(usize, 0), h.count);
    h.add("one");
    h.add("two");
    h.add("three");
    try t.expectEqualStrings("three", h.get(0));
    try t.expectEqualStrings("one", h.get(2));
    h.add("one"); // listed: moves to the front, nothing is lost
    try t.expectEqual(@as(usize, 3), h.count);
    try t.expectEqualStrings("one", h.get(0));
    try t.expectEqualStrings("three", h.get(1));
    try t.expectEqualStrings("two", h.get(2));
    h.add(h.get(2)); // an entry handed back as it is
    try t.expectEqualStrings("two", h.get(0));
    try t.expectEqualStrings("one", h.get(1));
    h.add("four"); // full: "three" is the oldest
    try t.expectEqual(@as(usize, 3), h.count);
    try t.expectEqualStrings("four", h.get(0));
    try t.expectEqualStrings("two", h.get(1));
    try t.expectEqualStrings("one", h.get(2));
}
