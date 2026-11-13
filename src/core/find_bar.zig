//! The find bar: one row along the bottom of a window's editor area that
//! stays open while you edit (Ctrl+F shows it, Escape closes it). This file
//! holds its state and everything it does to a document; the frontends
//! paint it and hand it keys and clicks.
//!
//! The bar belongs to one window (`window_id`) and searches the document in
//! that window's focused pane. Its text box owns the keyboard like a docked
//! panel does (`Editor.keyboardOwner() == .find_bar`); with the keyboard in
//! the text the bar stays up, so F3 / Shift+F3 keep walking the matches.
//! Every match of the box's text in the document is listed once per
//! document version (`MatchList`): the count, the tints and the GUI's
//! scroll-bar marks all read that list.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("editor.zig").Editor;
const Document = @import("document.zig").Document;
const cursor = @import("cursor.zig");
const line_edit = @import("line_edit.zig");
const search = @import("search.zig");
const text_input = @import("text_input.zig");
const lua_settings = @import("lua_settings.zig");

pub const needle_capacity = 256;
pub const Needle = line_edit.LineEdit(needle_capacity);
pub const NeedleHistory = line_edit.History(needle_capacity, 20);

/// Matches listed per search. Past it the count reads "100000+", the tints
/// stop there, and next / previous scan the text instead of the list.
pub const max_matches: usize = 100_000;

pub const Match = struct { start: usize, end: usize };

/// What counts as a match. Case folding is ASCII-only (`search.findInText`).
pub const Options = struct {
    match_case: bool = false,
    whole_word: bool = false,
};

/// The bar's toggle buttons.
pub const Toggle = enum {
    match_case,
    whole_word,
    highlight_all,

    /// Its name in status messages and hover hints.
    pub fn label(self: Toggle) []const u8 {
        return switch (self) {
            .match_case => "Match case",
            .whole_word => "Whole word",
            .highlight_all => "Highlight all matches",
        };
    }

    /// Its `zide.set` key.
    pub fn setting(self: Toggle) []const u8 {
        return switch (self) {
            .match_case => "find_match_case",
            .whole_word => "find_whole_word",
            .highlight_all => "find_highlight_all",
        };
    }
};

/// Every match of one text in one version of one document: in order, never
/// overlapping (a match starts at or after the end of the one before).
pub const MatchList = struct {
    items: std.ArrayList(Match) = .empty,
    /// False when the scan stopped at `max_matches` (or ran out of memory).
    complete: bool = true,
    doc_id: ?u64 = null,
    version: u64 = 0,
    needle: [needle_capacity]u8 = undefined,
    needle_len: usize = 0,
    options: Options = .{},

    pub fn deinit(self: *MatchList, allocator: Allocator) void {
        self.items.deinit(allocator);
        self.* = .{};
    }

    fn isFor(self: *const MatchList, doc_id: u64, version: u64, needle: []const u8, options: Options) bool {
        return self.doc_id == doc_id and self.version == version and std.meta.eql(self.options, options) and
            std.mem.eql(u8, self.needle[0..self.needle_len], needle);
    }

    /// List the matches of `needle` in `content` (the whole text of
    /// document `doc_id` at `version`).
    pub fn rebuild(self: *MatchList, allocator: Allocator, content: []const u8, doc_id: u64, version: u64, needle: []const u8, options: Options) void {
        self.items.clearRetainingCapacity();
        self.complete = true;
        self.doc_id = doc_id;
        self.version = version;
        self.options = options;
        self.needle_len = @min(needle.len, needle_capacity);
        @memcpy(self.needle[0..self.needle_len], needle[0..self.needle_len]);
        var from: usize = 0;
        while (search.findInText(content, needle, options.match_case, options.whole_word, from)) |at| {
            if (self.items.items.len == max_matches) {
                self.complete = false;
                break;
            }
            self.items.append(allocator, .{ .start = at, .end = at + needle.len }) catch {
                self.complete = false;
                break;
            };
            from = at + needle.len;
        }
        // A one-letter search can list a megabyte of matches: hand it back
        // once the list is small again.
        if (self.items.capacity > 4096 and self.items.items.len < self.items.capacity / 8) {
            self.items.shrinkAndFree(allocator, self.items.items.len);
        }
    }

    /// Index of the first match that starts at or after `offset`.
    pub fn lowerBound(self: *const MatchList, offset: usize) usize {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.items.items[mid].start < offset) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Index of the match that is exactly [start, end).
    pub fn indexOf(self: *const MatchList, start: usize, end: usize) ?usize {
        const i = self.lowerBound(start);
        if (i == self.items.items.len) return null;
        const m = self.items.items[i];
        return if (m.start == start and m.end == end) i else null;
    }

    /// The matches that touch [start, end): what a painter needs for the
    /// lines it draws.
    pub fn within(self: *const MatchList, start: usize, end: usize) []const Match {
        var lo = self.lowerBound(start);
        if (lo > 0 and self.items.items[lo - 1].end > start) lo -= 1;
        const hi = @max(lo, self.lowerBound(end));
        return self.items.items[lo..hi];
    }
};

/// A match next / previous arrived at; `wrapped` when it went around an end
/// of the document to get there.
pub const Hit = struct { match: Match, wrapped: bool };

/// The first match at or after `from`; none there: the first of the document.
pub fn nextHit(list: *const MatchList, doc: *Document, from: usize) ?Hit {
    const items = list.items.items;
    if (list.complete) {
        if (items.len == 0) return null;
        const i = list.lowerBound(from);
        return if (i < items.len) .{ .match = items[i], .wrapped = false } else .{ .match = items[0], .wrapped = true };
    }
    // More matches than the list holds: ask the text.
    const needle = list.needle[0..list.needle_len];
    const content = doc.buffer.slice(0, doc.buffer.byteLen());
    if (search.findInText(content, needle, list.options.match_case, list.options.whole_word, from)) |at| {
        return .{ .match = .{ .start = at, .end = at + needle.len }, .wrapped = false };
    }
    if (items.len > 0) return .{ .match = items[0], .wrapped = true };
    return null;
}

/// The last match that starts before `before`; none there: the last of the
/// document.
pub fn prevHit(list: *const MatchList, doc: *Document, before: usize) ?Hit {
    const items = list.items.items;
    if (list.complete) {
        if (items.len == 0) return null;
        const i = list.lowerBound(before);
        return if (i > 0) .{ .match = items[i - 1], .wrapped = false } else .{ .match = items[items.len - 1], .wrapped = true };
    }
    const needle = list.needle[0..list.needle_len];
    const content = doc.buffer.slice(0, doc.buffer.byteLen());
    var last_before: ?usize = null;
    var last: ?usize = null;
    var from: usize = 0;
    while (search.findInText(content, needle, list.options.match_case, list.options.whole_word, from)) |at| {
        if (at < before) last_before = at;
        last = at;
        from = at + needle.len;
    }
    if (last_before) |at| return .{ .match = .{ .start = at, .end = at + needle.len }, .wrapped = false };
    if (last) |at| return .{ .match = .{ .start = at, .end = at + needle.len }, .wrapped = true };
    return null;
}

/// The numbers beside the box: how many matches, and which one is selected
/// (null when the selection is not exactly a match).
pub const Count = struct {
    total: usize = 0,
    current: ?usize = null,
    complete: bool = true,
};

/// "3 of 17", "17 found", "No results" — nothing for an empty box.
pub fn countLabel(count: Count, has_needle: bool, buf: []u8) []const u8 {
    if (!has_needle) return "";
    if (count.total == 0) return "No results";
    const more: []const u8 = if (count.complete) "" else "+";
    if (count.current) |i| return std.fmt.bufPrint(buf, "{d} of {d}{s}", .{ i + 1, count.total, more }) catch "";
    return std.fmt.bufPrint(buf, "{d}{s} found", .{ count.total, more }) catch "";
}

pub const State = struct {
    visible: bool = false,
    /// The text box has the keyboard. Set only by Editor.takeKeyboardFocus
    /// (through `focus`); read it as `Editor.keyboardOwner() == .find_bar`.
    focused: bool = false,
    /// `EditorWindow.id` of the window that shows the bar.
    window_id: u32 = 0,
    needle: Needle = .{},
    options: Options = .{},
    /// The `All` button: tint every match, and mark them on the GUI's
    /// scroll bar (off: only the selected one shows, as the selection).
    highlight_all: bool = false,
    /// Where typing searches from: the caret when the box took the
    /// keyboard, then every match Enter / F3 went to.
    origin: usize = 0,
    /// Where the bar last left the document's caret. `origin` goes with
    /// it: when something else moved the caret since (a go-to-line prompt
    /// or a jump run from the box), typing searches from the new place.
    placed: Placed = .{},
    history: NeedleHistory = .{},
    /// Up / Down in the box: the earlier search it shows. Null: the text
    /// being typed (kept in `draft` while an earlier one is shown).
    history_pos: ?usize = null,
    draft: [needle_capacity]u8 = undefined,
    draft_len: usize = 0,
    matches: MatchList = .{},

    const Placed = struct { doc_id: ?u64 = null, anchor: ?usize = null, offset: usize = 0 };

    pub fn deinit(self: *State, allocator: Allocator) void {
        self.matches.deinit(allocator);
    }

    /// Remember where the caret of `doc` is now: the bar put it there.
    fn notePlaced(self: *State, doc: *const Document) void {
        const c = doc.cursors.primaryConst();
        self.placed = .{ .doc_id = doc.id, .anchor = c.anchor, .offset = c.offset };
    }

    /// The caret of `doc` is where the bar left it.
    fn stillPlaced(self: *const State, doc: *const Document) bool {
        const c = doc.cursors.primaryConst();
        return self.placed.doc_id == doc.id and self.placed.anchor == c.anchor and self.placed.offset == c.offset;
    }

    /// Whether toggle button `which` is switched on.
    pub fn isOn(self: *const State, which: Toggle) bool {
        return switch (which) {
            .match_case => self.options.match_case,
            .whole_word => self.options.whole_word,
            .highlight_all => self.highlight_all,
        };
    }

    /// The document the bar searches — the one in the focused pane of its
    /// window. Null once that window is gone.
    pub fn document(self: *const State, editor: *Editor) ?*Document {
        const win_idx = editor.windowIndexForId(self.window_id) orelse return null;
        const doc_idx = editor.windowDocIdx(win_idx);
        if (doc_idx >= editor.documents.items.len) return null;
        return &editor.documents.items[doc_idx];
    }

    /// Every match of the box's text in `doc`, scanned again only when the
    /// text, an option or the document changed.
    pub fn matchesIn(self: *State, editor: *Editor, doc: *Document) *const MatchList {
        const needle = self.needle.text();
        if (!self.matches.isFor(doc.id, doc.buffer.version, needle, self.options)) {
            const content: []const u8 = if (needle.len == 0) "" else doc.buffer.slice(0, doc.buffer.byteLen());
            self.matches.rebuild(editor.allocator, content, doc.id, doc.buffer.version, needle, self.options);
        }
        return &self.matches;
    }

    /// The numbers beside the box, for the bar's document.
    pub fn count(self: *State, editor: *Editor) Count {
        const doc = self.document(editor) orelse return .{};
        const list = self.matchesIn(editor, doc);
        var result: Count = .{ .total = list.items.items.len, .complete = list.complete };
        if (doc.cursors.primaryConst().selectionRange()) |r| result.current = list.indexOf(r.start, r.end);
        return result;
    }

    /// What a pane showing `doc` paints for the bar: `all`, every match
    /// (the All button), and `current`, the match the bar is on — the
    /// selection, when it is exactly a match.
    pub const Paint = struct {
        all: ?*const MatchList = null,
        current: ?Match = null,
    };

    /// Nothing unless the bar is up, has text, and `doc` is the document it
    /// searches. Call it before reading lines of `doc`: listing the matches
    /// reads the whole buffer through its shared scratch slice.
    pub fn paint(self: *State, editor: *Editor, doc: *Document) Paint {
        if (!self.visible or self.needle.len == 0) return .{};
        const target = self.document(editor) orelse return .{};
        if (target != doc) return .{};
        const list = self.matchesIn(editor, doc);
        var result: Paint = .{ .all = if (self.highlight_all) list else null };
        if (doc.cursors.primaryConst().selectionRange()) |r| {
            if (list.indexOf(r.start, r.end) != null) result.current = .{ .start = r.start, .end = r.end };
        }
        return result;
    }

    /// A text pane to search in: the focused pane, or — from a terminal
    /// pane — the window's first text pane, which gets the focus. False
    /// (and a message) when the window has none.
    fn textPane(editor: *Editor) bool {
        if (!editor.activePaneIsTerminal()) return true;
        const pane = editor.firstEditorPaneIn(editor.activeWindow()) orelse {
            editor.setStatus(.warning, "Find: this window has no text pane to search");
            return false;
        };
        editor.focusPane(pane);
        return true;
    }

    /// Give the box the keyboard, in the focused window (a click on the
    /// bar, Ctrl+F). Coming from the text, the search starts where the
    /// selection (or the caret) is; coming from a terminal pane, the
    /// window's first text pane gets the focus first — the box stays
    /// without the keyboard when there is none.
    pub fn focus(self: *State, editor: *Editor) void {
        if (editor.keyboardOwner() == .find_bar) return;
        if (!textPane(editor)) return;
        const doc = editor.activeDoc();
        const c = doc.cursors.primaryConst();
        self.origin = if (c.selectionRange()) |r| r.start else c.offset;
        self.notePlaced(doc);
        _ = editor.takeKeyboardFocus(.find_bar);
    }

    /// Ctrl+F: show the bar in the focused window with the keyboard in its
    /// box. A selection inside one line becomes the text to find; without
    /// one the last search stays. Either way the text is selected, so
    /// typing replaces it. The caret in the document does not move.
    pub fn open(self: *State, editor: *Editor) void {
        if (!textPane(editor)) return;
        if (editor.keyboardOwner() != .find_bar) {
            const doc = editor.activeDoc();
            if (doc.cursors.primaryConst().selectionRange()) |r| {
                if (r.end > r.start and r.end - r.start <= needle_capacity) {
                    const picked = doc.buffer.slice(r.start, r.end);
                    if (isOneLine(picked)) _ = self.needle.setText(picked);
                }
            }
            self.focus(editor);
        }
        self.needle.selectAll();
        self.history_pos = null;
    }

    /// Escape: hide the bar. The match it stopped at stays selected, the
    /// text joins the earlier searches, and the keyboard goes back to the
    /// pane if the box had it.
    pub fn close(self: *State, editor: *Editor) void {
        const had_keyboard = editor.keyboardOwner() == .find_bar;
        self.history.add(self.needle.text());
        self.history_pos = null;
        self.visible = false;
        self.focused = false;
        self.matches.deinit(editor.allocator);
        if (had_keyboard) _ = editor.takeKeyboardFocus(.pane);
    }

    /// The box's text changed (typing, a paste, undo): look again.
    pub fn edited(self: *State, editor: *Editor) void {
        self.history_pos = null;
        self.research(editor);
    }

    /// Select the first match from where this search began; without one
    /// the caret goes back there, selecting nothing.
    fn research(self: *State, editor: *Editor) void {
        const doc = editor.activeDoc();
        if (!self.stillPlaced(doc)) {
            const moved = doc.cursors.primaryConst();
            self.origin = if (moved.selectionRange()) |r| r.start else moved.offset;
        }
        const origin = cursor.floorBoundary(&doc.buffer, @min(self.origin, doc.buffer.byteLen()));
        const list = self.matchesIn(editor, doc);
        if (nextHit(list, doc, origin)) |hit| {
            select(editor, doc, hit.match);
        } else {
            doc.cursors.clearSecondary();
            const c = doc.cursors.primary();
            c.offset = origin;
            c.clearSelection();
            c.preferred_col = doc.buffer.offsetToPos(origin).col;
        }
        self.notePlaced(doc);
    }

    /// Enter / F3 (`forward`) and Shift+Enter / Shift+F3: the match after
    /// the selection or the one before it, around the ends of the
    /// document. Works in the focused document, with the bar hidden too;
    /// an empty box opens the bar instead.
    pub fn step(self: *State, editor: *Editor, forward: bool) void {
        if (self.needle.len == 0) return self.open(editor);
        if (!textPane(editor)) return;
        self.history.add(self.needle.text());
        self.history_pos = null;
        const doc = editor.activeDoc();
        const c = doc.cursors.primaryConst();
        const sel = c.selectionRange();
        const list = self.matchesIn(editor, doc);
        const hit = if (forward)
            nextHit(list, doc, if (sel) |r| r.end else c.offset)
        else
            prevHit(list, doc, if (sel) |r| r.start else c.offset);
        if (hit) |h| {
            select(editor, doc, h.match);
            self.origin = h.match.start;
            self.notePlaced(doc);
            if (h.wrapped) editor.setStatus(.quiet, if (forward) "Find: back at the first match" else "Find: on to the last match");
        } else if (!self.visible) {
            // The bar would say "No results"; hidden, the status bar has to.
            const needle = self.needle.text();
            const shown = needle[0..text_input.floor(needle, 100)];
            editor.setStatus(.warning, std.fmt.bufPrint(&editor.status_buf, "Not found: {s}", .{shown}) catch "Not found");
        }
    }

    /// Flip a toggle button and say so. All is how the view looks: it is
    /// kept for the next start (init.lua, like the theme and the panel
    /// sizes). Aa and W change what is found: they last while ZIDE runs
    /// and start from their settings again, so a search never quietly finds
    /// less than expected. When the box has the keyboard and the rule
    /// changed what matches, look again.
    pub fn toggle(self: *State, editor: *Editor, which: Toggle) void {
        const flag: *bool = switch (which) {
            .match_case => &self.options.match_case,
            .whole_word => &self.options.whole_word,
            .highlight_all => &self.highlight_all,
        };
        flag.* = !flag.*;
        const msg = std.fmt.bufPrint(&editor.status_buf, "{s}: {s}", .{ which.label(), if (flag.*) "on" else "off" }) catch which.label();
        editor.setStatus(.quiet, msg);
        if (which == .highlight_all) lua_settings.writeSettingToFile(which.setting(), if (flag.*) "true" else "false") catch {};
        if (which != .highlight_all and self.needle.len > 0 and editor.keyboardOwner() == .find_bar) self.research(editor);
    }

    /// Up (`older`) / Down in the box: walk the earlier searches. Below the
    /// newest one the text that was being typed comes back.
    pub fn historyStep(self: *State, editor: *Editor, older: bool) void {
        if (older) {
            var index: usize = 0;
            if (self.history_pos) |pos| {
                index = pos + 1;
            } else {
                self.draft_len = self.needle.len;
                @memcpy(self.draft[0..self.draft_len], self.needle.text());
                // The newest entry is often what the box already shows.
                if (self.history.count > 0 and std.mem.eql(u8, self.history.get(0), self.needle.text())) index = 1;
            }
            if (index >= self.history.count) return;
            self.history_pos = index;
            _ = self.needle.setText(self.history.get(index));
        } else {
            const pos = self.history_pos orelse return;
            if (pos == 0) {
                self.history_pos = null;
                _ = self.needle.setText(self.draft[0..self.draft_len]);
            } else {
                self.history_pos = pos - 1;
                _ = self.needle.setText(self.history.get(pos - 1));
            }
        }
        self.research(editor);
    }

    /// The editing chords the box takes while it has the keyboard — the
    /// bound action names, so a rebound key keeps working.
    const Chord = enum {
        copy,
        cut,
        paste,
        select_all,
        delete_word_backward,
        delete_word_forward,
        cursor_word_left,
        cursor_word_right,
        cursor_word_left_select,
        cursor_word_right_select,
        cursor_file_start,
        cursor_file_end,
        cursor_file_start_select,
        cursor_file_end_select,
        undo,
        redo,
    };

    /// Bound actions that change the document or its cursors. A chord
    /// pressed in the box is not meant for the text behind it: these are
    /// swallowed while the box has the keyboard.
    const text_actions = [_][]const u8{
        "delete_line",           "duplicate_line",   "toggle_comment",      "move_line_up",   "move_line_down",
        "add_cursor_above",      "add_cursor_below", "add_next_occurrence", "lsp_completion", "lsp_signature_help",
        "goto_matching_bracket",
    };

    /// An action while the box has the keyboard: the clipboard, word and
    /// undo chords edit the box instead of the document behind it (Ctrl+Home
    /// / Ctrl+End are the box's Home / End), and the ones that would edit
    /// the document do nothing. False: neither — the caller runs the action
    /// as usual (find next, save, the palette, a pane or window command).
    pub fn chord(self: *State, editor: *Editor, action: []const u8) bool {
        const which = std.meta.stringToEnum(Chord, action) orelse {
            for (text_actions) |name| {
                if (std.mem.eql(u8, action, name)) return true;
            }
            return false;
        };
        const box = &self.needle;
        var changed = false;
        switch (which) {
            .copy => if (box.selection() != null) editor.setClipboard(box.selectedText()),
            .cut => if (box.selection() != null) {
                editor.setClipboard(box.selectedText());
                changed = box.deleteSelection();
            },
            .paste => {
                const clip = editor.getClipboard();
                changed = box.insert(clip[0 .. std.mem.indexOfAny(u8, clip, "\r\n") orelse clip.len]);
            },
            .select_all => box.selectAll(),
            .delete_word_backward => changed = box.deleteWordBackward(),
            .delete_word_forward => changed = box.deleteWordForward(),
            .cursor_word_left => box.moveWordLeft(false),
            .cursor_word_right => box.moveWordRight(false),
            .cursor_word_left_select => box.moveWordLeft(true),
            .cursor_word_right_select => box.moveWordRight(true),
            .cursor_file_start => box.moveHome(false),
            .cursor_file_end => box.moveEnd(false),
            .cursor_file_start_select => box.moveHome(true),
            .cursor_file_end_select => box.moveEnd(true),
            .undo => changed = box.undo(),
            .redo => changed = box.redo(),
        }
        if (changed) self.edited(editor);
        return true;
    }
};

/// Text a selection may hand to the box: one line, no control characters
/// (the box would drop them, and the selection would no longer match).
fn isOneLine(text: []const u8) bool {
    for (text) |b| {
        if (b < 0x20 or b == 0x7f) return false;
    }
    return std.unicode.utf8ValidateSlice(text);
}

/// Select `m` as the primary cursor's selection (the only cursor left) and
/// bring it into view.
fn select(editor: *const Editor, doc: *Document, m: Match) void {
    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
    c.anchor = m.start;
    c.offset = m.end;
    c.preferred_col = doc.buffer.offsetToPos(m.end).col;
    reveal(editor, doc, m.start);
}

/// A match outside the view lands a third of the way down it; the frontends
/// then make sure the caret itself is in view (wrapped rows, long lines).
fn reveal(editor: *const Editor, doc: *Document, offset: usize) void {
    const line = doc.buffer.offsetToPos(offset).line;
    const rows = @max(editor.page_size, 1);
    if (line < doc.scroll_top or line >= doc.scroll_top + rows) doc.scroll_top = line -| rows / 3;
}

// ---- Tests ----

const t = std.testing;
const StatusLevel = @import("status_message.zig").Level;

fn testEditor() !Editor {
    var editor = try Editor.init(t.allocator, t.io);
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    return editor;
}

fn expectSelection(doc: *Document, start: usize, end: usize) !void {
    const r = doc.cursors.primaryConst().selectionRange() orelse return error.TestUnexpectedResult;
    try t.expectEqual(start, r.start);
    try t.expectEqual(end, r.end);
}

test "find bar: the match list is ordered and never overlaps; lookups by offset" {
    var list: MatchList = .{};
    defer list.deinit(t.allocator);
    list.rebuild(t.allocator, "aaaa Aa a", 7, 3, "aa", .{});
    try t.expect(list.complete);
    try t.expectEqual(@as(usize, 3), list.items.items.len); // 0, 2 and the "Aa" at 5
    try t.expectEqual(Match{ .start = 2, .end = 4 }, list.items.items[1]);
    try t.expectEqual(Match{ .start = 5, .end = 7 }, list.items.items[2]);
    try t.expect(list.isFor(7, 3, "aa", .{}));
    try t.expect(!list.isFor(7, 4, "aa", .{}));
    try t.expect(!list.isFor(7, 3, "aa", .{ .match_case = true }));
    try t.expect(!list.isFor(8, 3, "aa", .{}));
    try t.expect(!list.isFor(7, 3, "a", .{}));

    try t.expectEqual(@as(usize, 0), list.lowerBound(0));
    try t.expectEqual(@as(usize, 1), list.lowerBound(1));
    try t.expectEqual(@as(usize, 2), list.lowerBound(3));
    try t.expectEqual(@as(usize, 3), list.lowerBound(6));
    try t.expectEqual(@as(?usize, 1), list.indexOf(2, 4));
    try t.expectEqual(@as(?usize, null), list.indexOf(2, 3));
    try t.expectEqual(@as(?usize, null), list.indexOf(1, 3));
    try t.expectEqual(@as(?usize, null), list.indexOf(9, 11));

    // A painter's lines: the matches that reach into [start, end)
    try t.expectEqual(@as(usize, 3), list.within(0, 9).len);
    try t.expectEqual(@as(usize, 2), list.within(3, 9).len); // the one ending at 4 reaches in
    try t.expectEqual(@as(usize, 1), list.within(4, 6).len);
    try t.expectEqual(@as(usize, 0), list.within(4, 5).len);
    try t.expectEqual(@as(usize, 0), list.within(7, 9).len);

    // Options: case, whole word
    list.rebuild(t.allocator, "aaaa Aa a", 7, 3, "aa", .{ .match_case = true });
    try t.expectEqual(@as(usize, 2), list.items.items.len);
    list.rebuild(t.allocator, "aaaa Aa a", 7, 3, "aa", .{ .whole_word = true });
    try t.expectEqual(@as(usize, 1), list.items.items.len);
    try t.expectEqual(@as(usize, 5), list.items.items[0].start);
    list.rebuild(t.allocator, "aaaa Aa a", 7, 3, "", .{});
    try t.expectEqual(@as(usize, 0), list.items.items.len);

    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("", countLabel(.{ .total = 4 }, false, &buf));
    try t.expectEqualStrings("No results", countLabel(.{}, true, &buf));
    try t.expectEqualStrings("3 of 17", countLabel(.{ .total = 17, .current = 2 }, true, &buf));
    try t.expectEqualStrings("17 found", countLabel(.{ .total = 17 }, true, &buf));
    try t.expectEqualStrings("3 of 100000+", countLabel(.{ .total = 100000, .current = 2, .complete = false }, true, &buf));
    try t.expectEqualStrings("100000+ found", countLabel(.{ .total = 100000, .complete = false }, true, &buf));
}

test "find bar: Ctrl+F shows it with the keyboard, typing selects the first match from the caret, Enter and Shift+Enter walk around the document" {
    var editor = try testEditor();
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("one two\nTwo three\ntwo");
    doc.cursors.primary().offset = 5; // inside the first "two"
    const fb = &editor.find_bar;

    try t.expect(editor.execAction("find"));
    try t.expectEqual(Editor.Mode.normal, editor.mode); // not a prompt: the text stays live
    try t.expect(fb.visible);
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    try t.expectEqual(@as(usize, 5), doc.cursors.primaryConst().offset); // opening moves nothing
    try t.expectEqual(Count{}, fb.count(&editor));

    // Typing: case is ignored, the search starts at the caret
    _ = fb.needle.insert("t");
    fb.edited(&editor);
    try expectSelection(doc, 8, 9); // the T of "Two" — the next "t" from offset 5
    _ = fb.needle.insert("w");
    fb.edited(&editor);
    try expectSelection(doc, 8, 10);
    _ = fb.needle.insert("o");
    fb.edited(&editor);
    try expectSelection(doc, 8, 11);
    try t.expectEqual(Count{ .total = 3, .current = 1 }, fb.count(&editor));

    // Enter: on, then around to the first
    fb.step(&editor, true);
    try expectSelection(doc, 18, 21);
    try t.expectEqualStrings("", editor.status_message);
    fb.step(&editor, true);
    try expectSelection(doc, 4, 7);
    try t.expectEqualStrings("Find: back at the first match", editor.status_message);
    try t.expectEqual(Count{ .total = 3, .current = 0 }, fb.count(&editor));
    // Shift+Enter: back around to the last, then the one before it
    fb.step(&editor, false);
    try expectSelection(doc, 18, 21);
    try t.expectEqualStrings("Find: on to the last match", editor.status_message);
    fb.step(&editor, false);
    try expectSelection(doc, 8, 11);

    // More typing searches on from the match Enter went to; a text that
    // is nowhere puts the caret back there with nothing selected
    _ = fb.needle.insert(" ");
    fb.edited(&editor);
    try expectSelection(doc, 8, 12); // "Two "
    _ = fb.needle.insert("x");
    fb.edited(&editor);
    try t.expectEqual(@as(?usize, null), doc.cursors.primaryConst().anchor);
    try t.expectEqual(@as(usize, 8), doc.cursors.primaryConst().offset);
    try t.expectEqual(Count{}, fb.count(&editor));
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("No results", countLabel(fb.count(&editor), fb.needle.len > 0, &buf));
    // …and nothing is said in the status bar: the bar itself shows it
    try t.expect(!std.mem.startsWith(u8, editor.status_message, "Not found"));

    // The document changes under the bar: the list follows its version
    _ = fb.needle.backspace();
    _ = fb.needle.backspace();
    fb.edited(&editor);
    try t.expectEqual(@as(usize, 3), fb.count(&editor).total);
    try doc.replaceRange(doc.buffer.byteLen(), doc.buffer.byteLen(), " two");
    doc.cursors.primary().* = .{ .offset = 11, .anchor = 8 };
    try t.expectEqual(Count{ .total = 4, .current = 1 }, fb.count(&editor));

    // Escape: the bar goes, the match stays selected, the text is remembered
    fb.close(&editor);
    try t.expect(!fb.visible);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try expectSelection(doc, 8, 11);
    try t.expectEqualStrings("two", fb.history.get(0));
    try t.expectEqual(@as(usize, 0), fb.matches.items.capacity);
}

test "find bar: F3 works with the bar hidden, a selection seeds the box, an empty box opens the bar" {
    var editor = try testEditor();
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("alpha beta\nalpha gamma\nbeta");
    const fb = &editor.find_bar;

    // Nothing to look for yet: F3 asks
    try t.expect(editor.execCommand("find_next", null));
    try t.expect(fb.visible);
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    fb.close(&editor);

    // A one-line selection becomes the text, selected so typing replaces it
    const c = doc.cursors.primary();
    c.anchor = 11;
    c.offset = 16; // the second "alpha"
    try t.expect(editor.execAction("find"));
    try t.expectEqualStrings("alpha", fb.needle.text());
    try t.expectEqualStrings("alpha", fb.needle.selectedText());
    try expectSelection(doc, 11, 16);
    try t.expectEqual(Count{ .total = 2, .current = 1 }, fb.count(&editor));
    fb.close(&editor);

    // Hidden: F3 / Shift+F3 still walk, and say when nothing matches
    try t.expect(editor.execCommand("find_next", null));
    try t.expect(!fb.visible);
    try expectSelection(doc, 0, 5);
    try t.expect(editor.execCommand("find_previous", null));
    try expectSelection(doc, 11, 16);
    _ = fb.needle.setText("nowhere");
    editor.status_message = "";
    try t.expect(editor.execCommand("find_next", null));
    try t.expectEqualStrings("Not found: nowhere", editor.status_message);
    try t.expectEqual(StatusLevel.warning, editor.status_flash.marked_level);
    try expectSelection(doc, 11, 16);

    // A selection over a line break, or with a tab in it, seeds nothing
    c.anchor = 6;
    c.offset = 16;
    try t.expect(editor.execAction("find"));
    try t.expectEqualStrings("nowhere", fb.needle.text());
    fb.close(&editor);

    // Ctrl+F again while the box has the keyboard: the text is selected
    try t.expect(editor.execAction("find"));
    fb.needle.moveEnd(false);
    try t.expect(fb.needle.selection() == null);
    try t.expect(editor.execAction("find"));
    try t.expectEqualStrings("nowhere", fb.needle.selectedText());
}

test "find bar: a jump made from the box moves where typing searches from" {
    var editor = try testEditor();
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("two one\ntwo one\ntwo one");
    const fb = &editor.find_bar;
    try t.expect(editor.execAction("find"));
    _ = fb.needle.insert("o");
    fb.edited(&editor);
    try expectSelection(doc, 2, 3); // from the top of the document

    // Ctrl+G is not the box's: the prompt runs, and when it is done the box
    // has the keyboard again — with the caret on the third line.
    try t.expect(!editor.panelAction("goto_line"));
    try t.expect(editor.execAction("goto_line"));
    try t.expectEqual(Editor.Mode.goto_line, editor.mode);
    doc.cursors.primary().* = .{ .offset = 16 };
    editor.setMode(.normal);
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());

    // The next letter looks on from there, not from where Ctrl+F was pressed
    _ = fb.needle.insert("n");
    fb.edited(&editor);
    try expectSelection(doc, 20, 22);
    // …and the letters after it stay with that match
    _ = fb.needle.insert("e");
    fb.edited(&editor);
    try expectSelection(doc, 20, 23);
    try t.expectEqual(Count{ .total = 3, .current = 2 }, fb.count(&editor));
}

test "find bar: the toggles change what matches and name themselves; whole word and match case" {
    var editor = try testEditor();
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("cat Cat catalog CAT");
    const fb = &editor.find_bar;
    try t.expect(editor.execAction("find"));
    _ = fb.needle.insert("cat");
    fb.edited(&editor);
    try t.expectEqual(@as(usize, 4), fb.count(&editor).total);

    try t.expect(editor.execCommand("find_toggle_whole_word", null));
    try t.expect(fb.options.whole_word);
    try t.expectEqualStrings("Whole word: on", editor.status_message);
    try t.expectEqual(StatusLevel.quiet, editor.status_flash.marked_level);
    try t.expectEqual(@as(usize, 3), fb.count(&editor).total);

    try t.expect(editor.execCommand("find_toggle_case", null));
    try t.expect(fb.options.match_case);
    try t.expectEqualStrings("Match case: on", editor.status_message);
    try t.expectEqual(Count{ .total = 1, .current = 0 }, fb.count(&editor));
    try expectSelection(doc, 0, 3);

    // All is paint only: the selection and the count stay. Without it a
    // pane still learns which match the bar is on.
    try t.expect(fb.paint(&editor, doc).all == null);
    try t.expectEqual(@as(?Match, .{ .start = 0, .end = 3 }), fb.paint(&editor, doc).current);
    try t.expect(editor.execCommand("find_toggle_highlight_all", null));
    try t.expect(fb.highlight_all);
    try t.expectEqualStrings("Highlight all matches: on", editor.status_message);
    try t.expectEqual(@as(usize, 1), fb.paint(&editor, doc).all.?.items.items.len);
    try expectSelection(doc, 0, 3);
    // A selection that is not a match is not "the current one"
    doc.cursors.primary().* = .{ .offset = 2, .anchor = 0 };
    try t.expectEqual(@as(?Match, null), fb.paint(&editor, doc).current);
    doc.cursors.primary().* = .{ .offset = 3, .anchor = 0 };
    // Nothing to paint once the bar is closed
    fb.close(&editor);
    try t.expectEqual(State.Paint{}, fb.paint(&editor, doc));

    try t.expect(editor.execCommand("find_toggle_case", null));
    try t.expectEqualStrings("Match case: off", editor.status_message);
}

test "find bar: Up and Down walk the earlier searches and bring the typed text back" {
    var editor = try testEditor();
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("red green blue");
    const fb = &editor.find_bar;
    try t.expect(editor.execAction("find"));
    for ([_][]const u8{ "red", "green" }) |word| {
        _ = fb.needle.setText(word);
        fb.edited(&editor);
        fb.step(&editor, true); // Enter remembers the text
    }
    _ = fb.needle.setText("bl");
    fb.edited(&editor);
    try expectSelection(doc, 10, 12);

    fb.historyStep(&editor, true);
    try t.expectEqualStrings("green", fb.needle.text());
    try expectSelection(doc, 4, 9);
    fb.historyStep(&editor, true);
    try t.expectEqualStrings("red", fb.needle.text());
    fb.historyStep(&editor, true); // no older one: stays
    try t.expectEqualStrings("red", fb.needle.text());
    fb.historyStep(&editor, false);
    try t.expectEqualStrings("green", fb.needle.text());
    fb.historyStep(&editor, false);
    try t.expectEqualStrings("bl", fb.needle.text()); // what was being typed
    fb.historyStep(&editor, false);
    try t.expectEqualStrings("bl", fb.needle.text());

    // The newest entry is skipped when the box already shows it
    _ = fb.needle.setText("green");
    fb.edited(&editor);
    fb.historyStep(&editor, true);
    try t.expectEqualStrings("red", fb.needle.text());
}

test "find bar: the box takes the editing chords, and the document behind it is never edited" {
    var editor = try testEditor();
    defer editor.deinit();
    editor.clipboard_set_fn = struct {
        fn set(_: []const u8) void {}
    }.set;
    editor.clipboard_get_fn = struct {
        fn get() []const u8 {
            return "";
        }
    }.get;
    const doc = editor.activeDoc();
    try doc.loadText("foo bar baz");
    const fb = &editor.find_bar;

    // Not the box's while the text has the keyboard
    try t.expect(!editor.panelAction("paste"));
    try t.expect(editor.execAction("find"));
    _ = fb.needle.insert("foo bar");
    fb.edited(&editor);
    try expectSelection(doc, 0, 7);

    try t.expect(editor.panelAction("delete_word_backward"));
    try t.expectEqualStrings("foo ", fb.needle.text());
    try expectSelection(doc, 0, 4);
    try t.expect(editor.panelAction("undo"));
    try t.expectEqualStrings("foo bar", fb.needle.text());
    try t.expect(editor.panelAction("redo"));
    try t.expectEqualStrings("foo ", fb.needle.text());
    try t.expect(editor.panelAction("cursor_word_left_select"));
    try t.expectEqualStrings("foo ", fb.needle.selectedText());
    try t.expect(editor.panelAction("copy"));
    try t.expectEqualStrings("foo ", editor.clipboard);
    try t.expect(editor.panelAction("cut"));
    try t.expectEqualStrings("", fb.needle.text());
    editor.setClipboard("baz\nsecond line");
    try t.expect(editor.panelAction("paste"));
    try t.expectEqualStrings("baz", fb.needle.text());
    try expectSelection(doc, 8, 11);
    try t.expect(editor.panelAction("select_all"));
    try t.expectEqualStrings("baz", fb.needle.selectedText());
    try t.expect(editor.panelAction("cursor_file_start"));
    try t.expectEqual(@as(usize, 0), fb.needle.caret);
    try t.expect(editor.panelAction("cursor_file_end_select"));
    try t.expectEqualStrings("baz", fb.needle.selectedText());
    // What would edit the document does nothing from the box
    try t.expect(editor.panelAction("delete_line"));
    try t.expect(editor.panelAction("toggle_comment"));
    try t.expect(editor.panelAction("add_next_occurrence"));
    try t.expectEqual(@as(usize, 1), doc.cursors.count());
    // Anything else is not the box's: the caller runs it
    try t.expect(!editor.panelAction("save"));
    try t.expect(!editor.panelAction("find_next"));
    try t.expectEqualStrings("foo bar baz", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(!doc.dirty);
}

test "find bar: a list past its limit still counts, and next / previous read the text" {
    var editor = try testEditor();
    defer editor.deinit();
    const doc = editor.activeDoc();
    const text = try t.allocator.alloc(u8, max_matches + 3);
    defer t.allocator.free(text);
    @memset(text, 'x');
    try doc.loadText(text);
    const fb = &editor.find_bar;
    try t.expect(editor.execAction("find"));
    _ = fb.needle.insert("x");
    fb.edited(&editor);
    const count = fb.count(&editor);
    try t.expectEqual(max_matches, count.total);
    try t.expect(!count.complete);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("1 of 100000+", countLabel(count, true, &buf));

    // Past the listed part, in both directions and around the ends
    doc.cursors.primary().* = .{ .offset = max_matches + 1 };
    fb.step(&editor, true);
    try expectSelection(doc, max_matches + 1, max_matches + 2);
    fb.step(&editor, true);
    try expectSelection(doc, max_matches + 2, max_matches + 3);
    fb.step(&editor, true);
    try expectSelection(doc, 0, 1);
    fb.step(&editor, false);
    try expectSelection(doc, max_matches + 2, max_matches + 3);
    fb.step(&editor, false);
    try expectSelection(doc, max_matches + 1, max_matches + 2);
}

test "find bar: it belongs to the window it was opened in, moves with Ctrl+F, lets panels and panes take the keyboard, and goes with its window" {
    var editor = try testEditor();
    defer editor.deinit();
    editor.multi_window_supported = true;
    try editor.activeDoc().loadText("first window");
    _ = try editor.newDocument();
    try editor.activeDoc().loadText("second window, second text");
    _ = try editor.newWindow(.{ .editor = 1 });
    const second_id = editor.windows.items[1].id;
    const fb = &editor.find_bar;

    // Opened in the second window: shown there, searching its document
    try t.expectEqual(@as(usize, 1), editor.active_window);
    try t.expect(editor.execAction("find"));
    try t.expectEqual(second_id, fb.window_id);
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    _ = fb.needle.insert("second");
    fb.edited(&editor);
    try t.expectEqual(@as(usize, 2), fb.count(&editor).total);
    try t.expect(fb.document(&editor).? == &editor.documents.items[editor.windowDocIdx(1)]);

    // Another window takes the keyboard: the bar stays where it is, its box
    // lets go, and the other window's panes paint nothing for it
    editor.focusWindow(0);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(fb.visible and !fb.focused);
    try t.expectEqual(State.Paint{}, fb.paint(&editor, editor.activeDoc()));
    try t.expectEqual(@as(usize, 2), fb.count(&editor).total); // still the second window's
    // A flag left set by hand is repaired on the next tick
    fb.focused = true;
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    editor.normalizeKeyboardFocus();
    try t.expect(!fb.focused);

    // Ctrl+F here moves the bar to this window, with the same text
    try t.expect(editor.execAction("find"));
    try t.expectEqual(editor.windows.items[0].id, fb.window_id);
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    try t.expectEqualStrings("second", fb.needle.text());
    try t.expectEqual(@as(usize, 0), fb.count(&editor).total);

    // A panel takes the keyboard from the box and gives it back to the pane
    try t.expect(editor.takeKeyboardFocus(.search));
    try t.expectEqual(Editor.KeyboardOwner.search, editor.keyboardOwner());
    try t.expect(fb.visible and !fb.focused);
    try t.expect(editor.takeKeyboardFocus(.pane));
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    // Escape in the text closes a bar shown in this window…
    try t.expect(editor.execCommand("escape_multicursor", null));
    try t.expect(!fb.visible);

    // …and not one shown in another window; that one goes with its window
    editor.focusWindow(1);
    try t.expect(editor.execAction("find"));
    editor.focusWindow(0);
    try t.expect(editor.execCommand("escape_multicursor", null));
    try t.expect(fb.visible);
    try t.expect(editor.closeWindow(1));
    try t.expect(!fb.visible);
    try t.expect(fb.document(&editor) == null);

    // Ctrl+H is the old two-row prompt until it joins the bar: one find row at a time
    try t.expect(editor.execAction("find"));
    try t.expect(editor.execAction("find_replace"));
    try t.expect(!fb.visible);
    try t.expectEqual(Editor.Mode.find_replace, editor.mode);
    editor.setMode(.normal);
}

test "find bar: from a terminal pane it searches the window's text pane, and says so when there is none" {
    var editor = try testEditor();
    defer editor.deinit();
    try editor.activeDoc().loadText("needle in the text pane");
    // A second pane holding a fake terminal slot (Terminal.init would start a shell)
    try editor.terminals.append(t.allocator, null);
    editor.splitActive(.horizontal);
    const win = editor.activeWindow();
    const term_pane = win.active_pane;
    win.layout.panes.items[term_pane].content = .{ .terminal = 0 };
    try t.expectEqual(Editor.KeyboardOwner.terminal, editor.keyboardOwner());
    const fb = &editor.find_bar;

    try t.expect(editor.execAction("find"));
    try t.expect(fb.visible);
    try t.expect(win.active_pane != term_pane); // the text pane has the focus now
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    _ = fb.needle.insert("needle");
    fb.edited(&editor);
    try expectSelection(editor.activeDoc(), 0, 6);

    // The bar stays up while the shell has the keyboard; a click on the bar
    // (the frontends call focus) goes back to the text pane the same way
    editor.focusPane(term_pane);
    try t.expectEqual(Editor.KeyboardOwner.terminal, editor.keyboardOwner());
    try t.expect(fb.visible and !fb.focused);
    fb.focus(&editor);
    try t.expect(win.active_pane != term_pane);
    try t.expectEqual(Editor.KeyboardOwner.find_bar, editor.keyboardOwner());
    // A pane that turns into a terminal under the box takes the keyboard
    // from it on the next tick
    const text_pane = win.active_pane;
    const text_content = win.layout.panes.items[text_pane].content;
    win.layout.panes.items[text_pane].content = .{ .terminal = 0 };
    editor.normalizeKeyboardFocus();
    try t.expectEqual(Editor.KeyboardOwner.terminal, editor.keyboardOwner());
    try t.expect(fb.visible and !fb.focused);

    // No text pane at all: a click on the bar leaves the keyboard with the
    // shell and says why…
    fb.focus(&editor);
    try t.expectEqual(Editor.KeyboardOwner.terminal, editor.keyboardOwner());
    try t.expectEqualStrings("Find: this window has no text pane to search", editor.status_message);
    try t.expectEqual(StatusLevel.warning, editor.status_flash.marked_level);
    // …and with the bar closed nothing opens
    fb.close(&editor);
    editor.status_message = "";
    try t.expect(editor.execAction("find"));
    try t.expect(!fb.visible);
    try t.expectEqualStrings("Find: this window has no text pane to search", editor.status_message);
    try t.expectEqual(StatusLevel.warning, editor.status_flash.marked_level);
    try t.expect(editor.execCommand("find_next", null));
    try t.expect(!fb.visible);
    win.layout.panes.items[text_pane].content = text_content;
}

test "find bar: its three buttons are settings, and only All is written back" {
    const zlua = @import("zlua");
    // The Lua state outlives the editor (Editor.deinit releases refs into it).
    var lua = try zlua.Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try testEditor();
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("assert(zide.get('find_match_case') == false and zide.get('find_whole_word') == false and zide.get('find_highlight_all') == false)");
    try lua.doString("zide.set('find_match_case', true) zide.set('find_whole_word', true) zide.set('find_highlight_all', true)");
    try t.expect(editor.find_bar.options.match_case and editor.find_bar.options.whole_word and editor.find_bar.highlight_all);
    try lua.doString("assert(zide.get('find_match_case') and zide.get('find_whole_word') and zide.get('find_highlight_all'))");
    // The commands are there for a keybind or an extension
    try lua.doString("zide.exec('find_toggle_case') zide.exec('find_toggle_whole_word') zide.exec('find_toggle_highlight_all')");
    try t.expect(!editor.find_bar.options.match_case and !editor.find_bar.options.whole_word and !editor.find_bar.highlight_all);
    try t.expectEqualStrings("find_highlight_all", Toggle.highlight_all.setting());
}
