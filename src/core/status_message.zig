//! The status bar's message slot: how long a new message stays highlighted,
//! and whether it is a note, a warning or an error.
//!
//! `Editor.status_message` is a plain slice assigned in a few hundred places,
//! so nothing here needs a call from those sites. The status-bar painters ask
//! `Flash.view` every frame; a message it has not seen yet is copied into
//! `buf` and `status_message` is re-pointed at that copy (same text). From
//! then on any assignment — even of the same text — arrives as a foreign
//! slice, i.e. as a new message, and the two ways of clearing can be told
//! apart:
//!   - `Flash.dismiss` (the user moved on: a key, a click, the next action)
//!     leaves an empty slice of `buf` behind — the highlight keeps its time;
//!   - a direct `status_message = ""` (the message stopped being true: a
//!     drag hint, "Waiting for language server") takes the highlight along.
const std = @import("std");
const text_input = @import("text_input.zig");

pub const Level = enum {
    /// It worked, or it is only information.
    note,
    /// Refused or nothing to do: the request did not happen.
    warning,
    /// Something failed.
    err,
    /// Progress and background chatter ("Waiting for language server",
    /// "Auto-saved 2 file(s)"): plain text from the start, never highlighted
    /// — it comes by itself or is replaced within a moment.
    quiet,

    /// The level names scripts use (zide.status's second argument).
    pub fn parse(name: []const u8) ?Level {
        if (std.mem.eql(u8, name, "note") or std.mem.eql(u8, name, "info")) return .note;
        if (std.mem.eql(u8, name, "warning") or std.mem.eql(u8, name, "warn")) return .warning;
        if (std.mem.eql(u8, name, "error")) return .err;
        if (std.mem.eql(u8, name, "quiet")) return .quiet;
        return null;
    }
};

/// What the message slot shows this frame.
pub const View = struct {
    /// "" = nothing: the highlighted message while it is fresh, the current
    /// one (if any) after that.
    text: []const u8 = "",
    level: Level = .note,
    /// Draw it as the filled block; false = the plain look.
    fresh: bool = false,
    /// Time left on the highlight; null when nothing is highlighted.
    remaining_ns: ?i128 = null,
};

pub const Flash = struct {
    pub const capacity = 256;

    /// The painters' copy of the message (see the file comment).
    buf: [capacity]u8 = undefined,
    len: usize = 0,
    level: Level = .note,
    /// When a painter first drew it (awake clock); null = not drawn yet, its
    /// time starts with the first frame that shows it.
    shown_ns: ?i128 = null,
    /// A highlight is running or waiting for its first frame.
    active: bool = false,
    /// The level given through `mark`, for the message with this text.
    marked_hash: u64 = 0,
    marked_len: usize = 0,
    marked_level: Level = .note,

    /// `text` is a warning or an error (a note needs no call). Looked up by
    /// content when the message is first seen, so a later plain assignment of
    /// another text is a note again.
    pub fn mark(self: *Flash, level: Level, text: []const u8) void {
        self.marked_hash = std.hash.Wyhash.hash(0, text);
        self.marked_len = text.len;
        self.marked_level = level;
        // Already on screen (the current message given a level afterwards).
        if (text.len > 0 and self.owns(text)) self.level = level;
    }

    /// The message slot for this frame. `msg` is `Editor.status_message`;
    /// `hold_ns` is how long a new message stays highlighted (0 = never).
    pub fn view(self: *Flash, msg: *[]const u8, now: i128, hold_ns: i128) View {
        if (!self.owns(msg.*)) {
            if (msg.len > 0) {
                self.adopt(msg.*);
                msg.* = self.buf[0..self.len];
            } else {
                // Cleared outright: the highlight goes with it.
                self.active = false;
            }
        }
        if (self.active) {
            if (hold_ns > 0 and self.level != .quiet) {
                const start = self.shown_ns orelse now;
                self.shown_ns = start;
                const age = @max(0, now - start);
                if (age < hold_ns) return .{
                    .text = self.buf[0..self.len],
                    .level = self.level,
                    .fresh = true,
                    .remaining_ns = hold_ns - age,
                };
            }
            self.active = false;
        }
        // Past its time (or never highlighted): the plain look for as long
        // as the message is still the current one.
        return .{ .text = msg.*, .level = self.level };
    }

    /// The user moved on: the message goes, but a highlight that is running
    /// — or has not had a frame yet — finishes its time first.
    pub fn dismiss(self: *Flash, msg: *[]const u8) void {
        if (msg.len == 0) {
            // Already cleared; a direct clear also ends the highlight.
            if (!self.owns(msg.*)) self.active = false;
            return;
        }
        if (!self.owns(msg.*)) self.adopt(msg.*);
        msg.* = self.buf[0..0];
    }

    /// `text` is the painters' copy — whole, or emptied by `dismiss` — and
    /// not a message from outside.
    fn owns(self: *const Flash, text: []const u8) bool {
        return text.ptr == @as([*]const u8, &self.buf) and (text.len == 0 or text.len == self.len);
    }

    fn adopt(self: *Flash, text: []const u8) void {
        const n = text_input.floor(text, capacity);
        self.level = if (self.marked_len == text.len and self.marked_len > 0 and self.marked_hash == std.hash.Wyhash.hash(0, text))
            self.marked_level
        else
            .note;
        // `text` may be a piece of `buf` itself (a message cut from the old
        // one): a front piece is already in place, a later one moves down.
        if (text.ptr != @as([*]const u8, &self.buf)) std.mem.copyForwards(u8, self.buf[0..n], text[0..n]);
        self.len = n;
        self.shown_ns = null;
        self.active = true;
    }
};

const second = std.time.ns_per_s;

test "a new message is highlighted for its time, then settles and stays until dismissed" {
    const t = std.testing;
    var flash: Flash = .{};
    var msg: []const u8 = "";
    try t.expectEqualStrings("", flash.view(&msg, 0, 4 * second).text);

    msg = "Saved";
    var v = flash.view(&msg, 10 * second, 4 * second);
    try t.expect(v.fresh);
    try t.expectEqualStrings("Saved", v.text);
    try t.expectEqual(Level.note, v.level);
    try t.expectEqual(@as(?i128, 4 * second), v.remaining_ns);
    // The slice now points at the copy, with the same text.
    try t.expectEqualStrings("Saved", msg);
    try t.expect(flash.owns(msg));

    v = flash.view(&msg, 13 * second, 4 * second);
    try t.expect(v.fresh);
    try t.expectEqual(@as(?i128, 1 * second), v.remaining_ns);

    // Time is up: the plain look, for as long as nothing dismisses it.
    v = flash.view(&msg, 14 * second, 4 * second);
    try t.expect(!v.fresh);
    try t.expectEqualStrings("Saved", v.text);
    try t.expectEqual(@as(?i128, null), v.remaining_ns);
    v = flash.view(&msg, 500 * second, 4 * second);
    try t.expect(!v.fresh);
    try t.expectEqualStrings("Saved", v.text);

    flash.dismiss(&msg);
    try t.expectEqualStrings("", msg);
    try t.expectEqualStrings("", flash.view(&msg, 501 * second, 4 * second).text);
}

test "a dismissed message keeps its time; a direct clear takes it away at once" {
    const t = std.testing;
    var flash: Flash = .{};
    var msg: []const u8 = "Saved";
    _ = flash.view(&msg, 0, 4 * second);

    // A key press one second in: the message is gone for everyone else...
    flash.dismiss(&msg);
    try t.expectEqual(@as(usize, 0), msg.len);
    // ...but the bar still shows it until its four seconds are over.
    var v = flash.view(&msg, 1 * second, 4 * second);
    try t.expect(v.fresh);
    try t.expectEqualStrings("Saved", v.text);
    flash.dismiss(&msg); // more typing changes nothing
    v = flash.view(&msg, 3 * second, 4 * second);
    try t.expect(v.fresh);
    v = flash.view(&msg, 4 * second, 4 * second);
    try t.expect(!v.fresh);
    try t.expectEqualStrings("", v.text);

    // `status_message = ""` means "no longer true": nothing lingers.
    msg = "Release to hide the file tree";
    try t.expect(flash.view(&msg, 10 * second, 4 * second).fresh);
    msg = "";
    v = flash.view(&msg, 11 * second, 4 * second);
    try t.expect(!v.fresh);
    try t.expectEqualStrings("", v.text);
    // The same holds when a dismissal follows the clear in the same frame.
    msg = "Release to hide the file tree";
    _ = flash.view(&msg, 20 * second, 4 * second);
    msg = "";
    flash.dismiss(&msg);
    try t.expectEqualStrings("", flash.view(&msg, 21 * second, 4 * second).text);
    // ...and when the clear follows the dismissal.
    msg = "Drop outside the tab bar";
    _ = flash.view(&msg, 30 * second, 4 * second);
    flash.dismiss(&msg);
    msg = "";
    try t.expectEqualStrings("", flash.view(&msg, 31 * second, 4 * second).text);
}

test "the same text assigned again is a new message; one dismissed before it was drawn still gets its time" {
    const t = std.testing;
    var flash: Flash = .{};
    const saved = "Saved";
    var msg: []const u8 = saved;
    _ = flash.view(&msg, 0, 4 * second);
    // Settled for a minute, then Ctrl+S again: dismissed and set in one frame.
    _ = flash.view(&msg, 60 * second, 4 * second);
    flash.dismiss(&msg);
    msg = saved;
    var v = flash.view(&msg, 61 * second, 4 * second);
    try t.expect(v.fresh);
    try t.expectEqual(@as(?i128, 4 * second), v.remaining_ns);

    // Two keys in one frame: the first sets a message, the second dismisses
    // it before any frame showed it. Its time starts at the first frame.
    msg = "No matches found";
    flash.dismiss(&msg);
    try t.expectEqual(@as(usize, 0), msg.len);
    v = flash.view(&msg, 200 * second, 4 * second);
    try t.expect(v.fresh);
    try t.expectEqualStrings("No matches found", v.text);
    try t.expectEqual(@as(?i128, 4 * second), v.remaining_ns);
    try t.expect(!flash.view(&msg, 204 * second, 4 * second).fresh);

    // A newer message always replaces the one on screen.
    msg = "First";
    _ = flash.view(&msg, 300 * second, 4 * second);
    msg = "Second";
    v = flash.view(&msg, 301 * second, 4 * second);
    try t.expectEqualStrings("Second", v.text);
    try t.expectEqual(@as(?i128, 4 * second), v.remaining_ns);
}

test "levels follow the text they were given for; hold 0 never highlights" {
    const t = std.testing;
    var flash: Flash = .{};
    var msg: []const u8 = "Save failed: AccessDenied";
    flash.mark(.err, msg);
    try t.expectEqual(Level.err, flash.view(&msg, 0, 4 * second).level);
    // Another text assigned directly is a note again.
    msg = "Saved";
    try t.expectEqual(Level.note, flash.view(&msg, 1 * second, 4 * second).level);
    // The marked text again (copied elsewhere in between) keeps its level.
    var copy: [64]u8 = undefined;
    const again = std.fmt.bufPrint(&copy, "Save failed: {s}", .{"AccessDenied"}) catch unreachable;
    msg = again;
    try t.expectEqual(Level.err, flash.view(&msg, 2 * second, 4 * second).level);
    // The message on screen given a level afterwards.
    msg = "Read-only document";
    _ = flash.view(&msg, 3 * second, 4 * second);
    flash.mark(.warning, msg);
    try t.expectEqual(Level.warning, flash.view(&msg, 3 * second, 4 * second).level);

    // Highlighting switched off: plain text until dismissed, as before.
    var off: Flash = .{};
    var plain: []const u8 = "Saved";
    var v = off.view(&plain, 0, 0);
    try t.expect(!v.fresh);
    try t.expectEqualStrings("Saved", v.text);
    try t.expectEqual(@as(?i128, null), v.remaining_ns);
    off.dismiss(&plain);
    v = off.view(&plain, 1, 0);
    try t.expectEqualStrings("", v.text);

    try t.expectEqual(@as(?Level, .err), Level.parse("error"));
    try t.expectEqual(@as(?Level, .warning), Level.parse("warn"));
    try t.expectEqual(@as(?Level, .note), Level.parse("info"));
    try t.expectEqual(@as(?Level, .quiet), Level.parse("quiet"));
    try t.expectEqual(@as(?Level, null), Level.parse("loud"));
}

test "a quiet message is plain from the start and goes with the next dismissal" {
    const t = std.testing;
    var flash: Flash = .{};
    var msg: []const u8 = "Waiting for language server";
    flash.mark(.quiet, msg);
    var v = flash.view(&msg, 0, 4 * second);
    try t.expect(!v.fresh);
    try t.expectEqualStrings("Waiting for language server", v.text);
    try t.expectEqual(@as(?i128, null), v.remaining_ns);
    // Nothing to wait out: a key press removes it at once.
    flash.dismiss(&msg);
    try t.expectEqualStrings("", flash.view(&msg, 1, 4 * second).text);
    // The answer that replaces it is highlighted as usual.
    msg = "Waiting for language server";
    _ = flash.view(&msg, 2 * second, 4 * second);
    msg = "No hover information";
    flash.mark(.warning, msg);
    v = flash.view(&msg, 2 * second, 4 * second);
    try t.expect(v.fresh);
    try t.expectEqual(Level.warning, v.level);
}

test "a long message is cut on a character boundary, and a message cut from the copy is taken in place" {
    const t = std.testing;
    var flash: Flash = .{};
    const long = "é" ** 200; // 400 bytes
    var msg: []const u8 = long;
    const v = flash.view(&msg, 0, 4 * second);
    try t.expectEqual(@as(usize, Flash.capacity), v.text.len);
    try t.expect(std.unicode.utf8ValidateSlice(v.text));
    try t.expectEqual(v.text.len, msg.len);

    // A piece of the copy assigned back is a new message: a tail moves to
    // the front, a front piece is already there.
    var cut: Flash = .{};
    var piece: []const u8 = "Deleted: Hello world";
    _ = cut.view(&piece, 0, 4 * second);
    piece = piece[9..];
    var pv = cut.view(&piece, 1 * second, 4 * second);
    try t.expectEqualStrings("Hello world", pv.text);
    try t.expectEqualStrings("Hello world", piece);
    try t.expectEqual(@as(?i128, 4 * second), pv.remaining_ns);
    piece = piece[0..5];
    pv = cut.view(&piece, 2 * second, 4 * second);
    try t.expectEqualStrings("Hello", pv.text);
    try t.expectEqual(@as(?i128, 4 * second), pv.remaining_ns);
}
