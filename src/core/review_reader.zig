//! The review reader: a read-only document synthesized from git's diff of
//! one changed file — the new file's lines in order, deleted lines kept
//! inline as ghost rows, optionally with long unchanged stretches collapsed
//! into one marker row. It is a normal Document (syntax colors, search,
//! selection and copy all work); `Document.readonly` refuses edits, and the
//! painters read `Document.reader` for the per-row kinds.
const std = @import("std");
const Editor = @import("editor.zig").Editor;
const Document = @import("document.zig").Document;
const unidiff = @import("unidiff.zig");
const text_file = @import("text_file.zig");
const Allocator = std.mem.Allocator;

pub const LineKind = enum(u3) { context, added, modified, ghost, marker };
/// A maximal run of changed rows (ghost, added, modified): next/previous change.
pub const Hunk = struct { first_row: u32, last_row: u32 };
/// An unchanged stretch collapsed into one marker row and what it hides.
pub const Run = struct {
    marker_row: u32,
    /// Old-file line the stretch starts at: stable while the baseline is
    /// fixed, so an expanded run stays open across rebuilds.
    old_start: u32,
    /// First hidden new-file line and how many follow it.
    hidden_new_start: u32,
    hidden: u32,
};
pub const Options = struct {
    /// Context rows kept on each side of a change; null = never collapse.
    context: ?u32 = null,
    /// `old_start` of the runs the user expanded.
    expanded: []const u32 = &.{},
    ascii: bool = false,
};
pub const Synth = struct {
    text: []u8,
    kinds: []LineKind,
    real_line: []?u32,
    hunks: []Hunk,
    runs: []Run,
    pub fn deinit(self: *Synth, a: Allocator) void {
        a.free(self.text);
        a.free(self.kinds);
        a.free(self.real_line);
        a.free(self.hunks);
        a.free(self.runs);
    }
};

/// Unchanged stretches longer than twice this collapse into one marker row
/// (Enter on it, or `review_expand_all`, shows them).
pub const context_rows: ?u32 = 3;

/// Build the reader's text and side arrays from a parsed diff. Every row
/// of `text` has one entry in `kinds` and `real_line` (the new-file line it
/// shows, null for ghost and marker rows) — the painters index them by the
/// document's line number.
pub fn synthesize(a: Allocator, parsed: unidiff.Parsed, opts: Options) !Synth {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    var kinds: std.ArrayList(LineKind) = .empty;
    errdefer kinds.deinit(a);
    var real: std.ArrayList(?u32) = .empty;
    errdefer real.deinit(a);
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(a);
    var runs: std.ArrayList(Run) = .empty;
    errdefer runs.deinit(a);
    const lines = parsed.lines;
    var i: usize = 0;
    var old_line: u32 = 0;
    var new_line: u32 = 0;
    while (i < lines.len) {
        if (lines[i].kind == .context) {
            var j = i;
            while (j < lines.len and lines[j].kind == .context) j += 1;
            const count: u32 = @intCast(j - i);
            const at_start = i == 0;
            const at_end = j == lines.len;
            var lead: u32 = if (at_start) 0 else (opts.context orelse count);
            var trail: u32 = if (at_end) 0 else (opts.context orelse count);
            var collapse = opts.context != null and lead + trail + 2 <= count and !contains(opts.expanded, old_line);
            if (!collapse) {
                lead = count;
                trail = 0;
                collapse = false;
            }
            for (0..lead) |k| try appendRow(a, &text, &kinds, &real, lines[i + k].text, .context, new_line + @as(u32, @intCast(k)));
            if (collapse) {
                const hidden = count - lead - trail;
                try runs.append(a, .{ .marker_row = @intCast(kinds.items.len), .old_start = old_line, .hidden_new_start = new_line + lead, .hidden = hidden });
                var marker_buf: [64]u8 = undefined;
                const marker: []const u8 = if (opts.ascii)
                    std.fmt.bufPrint(&marker_buf, "... {d} unchanged lines ...", .{hidden}) catch "..."
                else
                    std.fmt.bufPrint(&marker_buf, "··· {d} unchanged lines ···", .{hidden}) catch "···";
                try appendRow(a, &text, &kinds, &real, marker, .marker, null);
                for (count - trail..count) |k| try appendRow(a, &text, &kinds, &real, lines[i + k].text, .context, new_line + @as(u32, @intCast(k)));
            }
            old_line += count;
            new_line += count;
            i = j;
        } else {
            var j = i;
            var has_removed = false;
            while (j < lines.len and lines[j].kind != .context) : (j += 1) {
                if (lines[j].kind == .removed) has_removed = true;
            }
            const first_row: u32 = @intCast(kinds.items.len);
            for (i..j) |k| {
                const line = lines[k];
                switch (line.kind) {
                    .removed => {
                        try appendRow(a, &text, &kinds, &real, line.text, .ghost, null);
                        old_line += 1;
                    },
                    .added => {
                        try appendRow(a, &text, &kinds, &real, line.text, if (has_removed) .modified else .added, new_line);
                        new_line += 1;
                    },
                    .context => unreachable,
                }
            }
            try hunks.append(a, .{ .first_row = first_row, .last_row = @intCast(kinds.items.len - 1) });
            i = j;
        }
    }
    if (kinds.items.len == 0) try appendRow(a, &text, &kinds, &real, "", .context, 0);
    // A new file that ends with a newline has a final empty line, like
    // any document; keep the row arrays as long as the document.
    if (parsed.new_count > 0 and !parsed.new_missing_newline) {
        try text.append(a, '\n');
        try kinds.append(a, .context);
        try real.append(a, new_line);
    }
    return .{
        .text = try text.toOwnedSlice(a),
        .kinds = try kinds.toOwnedSlice(a),
        .real_line = try real.toOwnedSlice(a),
        .hunks = try hunks.toOwnedSlice(a),
        .runs = try runs.toOwnedSlice(a),
    };
}

fn appendRow(a: Allocator, text: *std.ArrayList(u8), kinds: *std.ArrayList(LineKind), real: *std.ArrayList(?u32), line: []const u8, kind: LineKind, real_line: ?u32) !void {
    if (kinds.items.len > 0) try text.append(a, '\n');
    try text.appendSlice(a, line);
    try kinds.append(a, kind);
    try real.append(a, real_line);
}

fn contains(values: []const u32, value: u32) bool {
    for (values) |v| if (v == value) return true;
    return false;
}

/// The new-file line a row stands for: the row's own, else the next real
/// row's (a ghost or marker maps forward), else the previous one's.
pub fn realLineAt(real_line: []const ?u32, row: usize) ?u32 {
    if (real_line.len == 0) return null;
    var i = @min(row, real_line.len - 1);
    while (i < real_line.len) : (i += 1) if (real_line[i]) |line| return line;
    i = @min(row, real_line.len - 1);
    while (true) {
        if (real_line[i]) |line| return line;
        if (i == 0) return null;
        i -= 1;
    }
}

/// The row showing new-file line `target`: its own row, else the marker
/// row hiding it, else the last row at or before it.
pub fn rowForReal(real_line: []const ?u32, runs: []const Run, target: u32) u32 {
    var best: ?u32 = null;
    for (real_line, 0..) |maybe, row| if (maybe) |line| {
        if (line == target) return @intCast(row);
        if (line < target) best = @intCast(row);
    };
    for (runs) |run| if (target >= run.hidden_new_start and target < run.hidden_new_start + run.hidden) return run.marker_row;
    return best orelse 0;
}

/// Everything the painters and the commands need about a reader document.
pub const Info = struct {
    /// Absolute path of the real file (opened on Enter), and git's spelling.
    source_path: []u8,
    rel_path: []u8,
    old_path: ?[]u8,
    change: u8,
    kinds: []LineKind,
    real_line: []?u32,
    hunks: []Hunk,
    runs: []Run,
    expanded: std.ArrayList(u32) = .empty,
    /// The real file's stamp when the view was built; the review tick
    /// rebuilds when it moves.
    disk_stamp: ?text_file.Stamp = null,
    /// The last rebuild failed (binary, too large): the view is old.
    stale: bool = false,
    /// A `Diff: <file>` tab (git's own unified diff, a snapshot) rather
    /// than the reader; never rebuilt in the background.
    classic: bool = false,

    pub fn destroy(self: *Info, a: Allocator) void {
        a.free(self.source_path);
        a.free(self.rel_path);
        if (self.old_path) |p| a.free(p);
        a.free(self.kinds);
        a.free(self.real_line);
        a.free(self.hunks);
        a.free(self.runs);
        self.expanded.deinit(a);
        a.destroy(self);
    }
    pub fn kindAt(self: *const Info, row: usize) LineKind {
        return if (row < self.kinds.len) self.kinds[row] else .context;
    }
};

pub const Source = struct { root: []const u8, path: []const u8, old_path: ?[]const u8 = null, change: u8 };

/// Show `parsed` as the reader tab for `source`: the one reader document
/// is reused in place (its caret and scroll stay on the same real lines
/// when it is the same file), else a new tab opens. `target_line` is a
/// new-file line to put the caret on. `focus` = the user asked for it:
/// switch to the tab and leave any panel. A background rebuild passes
/// false and changes nothing but the reader's own text — never the active
/// tab, the mode or the focus — and does nothing when the tab is gone.
pub fn show(editor: *Editor, source: Source, parsed: unidiff.Parsed, target_line: ?u32, focus: bool) !void {
    const a = editor.allocator;
    const existing: ?usize = if (editor.review.reader_doc_id) |id| editor.docIndexForId(id) else null;
    if (!focus and existing == null) return;
    var caret_anchor: ?u32 = null;
    var scroll_anchor: ?u32 = null;
    var expanded: std.ArrayList(u32) = .empty;
    errdefer expanded.deinit(a);
    if (existing) |idx| {
        const doc = &editor.documents.items[idx];
        if (doc.reader) |info| if (std.mem.eql(u8, info.rel_path, source.path)) {
            caret_anchor = realLineAt(info.real_line, doc.cursorPos().line);
            scroll_anchor = realLineAt(info.real_line, doc.scroll_top);
            try expanded.appendSlice(a, info.expanded.items);
        };
    }
    var synth = try synthesize(a, parsed, .{ .context = context_rows, .expanded = expanded.items, .ascii = false });
    errdefer synth.deinit(a);
    const info = try a.create(Info);
    errdefer a.destroy(info);
    const source_path = try std.fs.path.join(a, &.{ source.root, source.path });
    errdefer a.free(source_path);
    const rel_path = try a.dupe(u8, source.path);
    errdefer a.free(rel_path);
    const old_path = if (source.old_path) |p| try a.dupe(u8, p) else null;
    errdefer if (old_path) |p| a.free(p);
    const name = try std.fmt.allocPrint(a, "Review: {s}", .{std.fs.path.basename(source.path)});
    errdefer a.free(name);

    const doc: *Document = if (existing) |idx| blk: {
        if (focus) editor.switchToDoc(idx);
        break :blk &editor.documents.items[idx];
    } else try editor.newDocument();
    try doc.loadText(synth.text);
    a.free(synth.text);
    info.* = .{
        .source_path = source_path,
        .rel_path = rel_path,
        .old_path = old_path,
        .change = source.change,
        .kinds = synth.kinds,
        .real_line = synth.real_line,
        .hunks = synth.hunks,
        .runs = synth.runs,
        .expanded = expanded,
        .disk_stamp = text_file.Stamp.read(editor.io, source_path) catch null,
    };
    if (doc.reader) |old| old.destroy(a);
    doc.reader = info;
    doc.readonly = true;
    // The previous reader name was ours (heap); a fresh document's is the
    // shared default, which Document.deinit never frees.
    if (existing != null) a.free(doc.display_name);
    doc.display_name = name;
    const ext = std.fs.path.extension(source.path);
    doc.language = if (ext.len > 1) editor.findLanguage(ext[1..]) else null;
    doc.invalidateLineStates(0);
    const row: u32 = if (target_line) |line|
        rowForReal(info.real_line, info.runs, line)
    else if (caret_anchor) |line|
        rowForReal(info.real_line, info.runs, line)
    else if (info.hunks.len > 0) info.hunks[0].first_row else 0;
    doc.gotoLine(row + 1);
    if (scroll_anchor) |line| doc.scroll_top = rowForReal(info.real_line, info.runs, line);
    editor.review.reader_doc_id = doc.id;
    if (focus) editor.setMode(.normal);
}

/// Switch to an existing reader or diff tab without rebuilding it; the
/// caret goes to `target_line` (a new-file line) when given.
pub fn focusDoc(editor: *Editor, doc_id: u64, target_line: ?u32) bool {
    const idx = editor.docIndexForId(doc_id) orelse return false;
    editor.switchToDoc(idx);
    const doc = &editor.documents.items[idx];
    if (target_line) |line| if (doc.reader) |info| doc.gotoLine(rowForReal(info.real_line, info.runs, line) + 1);
    editor.setMode(.normal);
    return true;
}

/// The classic view: git's own unified diff (a few lines of context per
/// hunk) as a read-only `Diff: <file>` tab painted like the reader — `+`
/// rows tinted as added, `-` rows as ghosts, hunk headers dim, the new
/// file's line numbers in the gutter. A snapshot: never rebuilt by itself.
pub fn showClassic(editor: *Editor, source: Source, diff_text: []const u8, focus: bool) !void {
    const a = editor.allocator;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    var kinds: std.ArrayList(LineKind) = .empty;
    errdefer kinds.deinit(a);
    var real: std.ArrayList(?u32) = .empty;
    errdefer real.deinit(a);
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(a);
    var in_hunk = false;
    var new_line: u32 = 0;
    var change_start: ?u32 = null;
    var it = std.mem.splitScalar(u8, diff_text, '\n');
    while (it.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            new_line = hunkNewStart(line);
            try closeChange(a, &hunks, &change_start, kinds.items.len);
            try appendRow(a, &text, &kinds, &real, line, .marker, null);
            continue;
        }
        if (!in_hunk) {
            // File headers are noise here; git's binary notice is the whole story.
            if (std.mem.startsWith(u8, line, "Binary files ")) try appendRow(a, &text, &kinds, &real, line, .marker, null);
            continue;
        }
        if (line.len == 0) continue;
        switch (line[0]) {
            '+' => {
                if (change_start == null) change_start = @intCast(kinds.items.len);
                try appendRow(a, &text, &kinds, &real, line, .added, new_line);
                new_line += 1;
            },
            '-' => {
                if (change_start == null) change_start = @intCast(kinds.items.len);
                try appendRow(a, &text, &kinds, &real, line, .ghost, null);
            },
            ' ' => {
                try closeChange(a, &hunks, &change_start, kinds.items.len);
                try appendRow(a, &text, &kinds, &real, line, .context, new_line);
                new_line += 1;
            },
            else => try appendRow(a, &text, &kinds, &real, line, .marker, null),
        }
    }
    try closeChange(a, &hunks, &change_start, kinds.items.len);
    if (kinds.items.len == 0) try appendRow(a, &text, &kinds, &real, "(no differences)", .marker, null);

    const existing: ?usize = if (editor.review.classic_doc_id) |id| editor.docIndexForId(id) else null;
    if (!focus and existing == null) return;
    const info = try a.create(Info);
    errdefer a.destroy(info);
    const source_path = try std.fs.path.join(a, &.{ source.root, source.path });
    errdefer a.free(source_path);
    const rel_path = try a.dupe(u8, source.path);
    errdefer a.free(rel_path);
    const old_path = if (source.old_path) |p| try a.dupe(u8, p) else null;
    errdefer if (old_path) |p| a.free(p);
    const name = try std.fmt.allocPrint(a, "Diff: {s}", .{std.fs.path.basename(source.path)});
    errdefer a.free(name);
    const runs = try a.alloc(Run, 0);
    errdefer a.free(runs);
    const doc: *Document = if (existing) |idx| blk: {
        if (focus) editor.switchToDoc(idx);
        break :blk &editor.documents.items[idx];
    } else try editor.newDocument();
    try doc.loadText(text.items);
    text.deinit(a);
    info.* = .{
        .source_path = source_path,
        .rel_path = rel_path,
        .old_path = old_path,
        .change = source.change,
        .kinds = try kinds.toOwnedSlice(a),
        .real_line = try real.toOwnedSlice(a),
        .hunks = try hunks.toOwnedSlice(a),
        .runs = runs,
        .classic = true,
    };
    if (doc.reader) |old| old.destroy(a);
    doc.reader = info;
    doc.readonly = true;
    if (existing != null) a.free(doc.display_name);
    doc.display_name = name;
    const ext = std.fs.path.extension(source.path);
    doc.language = if (ext.len > 1) editor.findLanguage(ext[1..]) else null;
    doc.invalidateLineStates(0);
    doc.gotoLine(if (info.hunks.len > 0) info.hunks[0].first_row + 1 else 1);
    editor.review.classic_doc_id = doc.id;
    if (focus) editor.setMode(.normal);
}

/// `@@ -a,b +c,d @@` → the new file's first line of the hunk, 0-based.
fn hunkNewStart(hunk_line: []const u8) u32 {
    const plus = std.mem.indexOfScalar(u8, hunk_line, '+') orelse return 0;
    var end = plus + 1;
    while (end < hunk_line.len and std.ascii.isDigit(hunk_line[end])) end += 1;
    const start = std.fmt.parseInt(u32, hunk_line[plus + 1 .. end], 10) catch return 0;
    return start -| 1;
}

fn closeChange(a: Allocator, hunks: *std.ArrayList(Hunk), start: *?u32, rows: usize) !void {
    const first = start.* orelse return;
    start.* = null;
    if (rows == 0) return;
    try hunks.append(a, .{ .first_row = first, .last_row = @intCast(rows - 1) });
}

/// A rebuild failed (binary now, too large, git error): keep the old
/// text, say so in the tab name, and remember the file's current stamp
/// so the next check does not start the same failing job again.
pub fn markStale(editor: *Editor, doc: *Document) void {
    const info = doc.reader orelse return;
    info.disk_stamp = text_file.Stamp.read(editor.io, info.source_path) catch null;
    if (info.stale) return;
    info.stale = true;
    const name = std.fmt.allocPrint(editor.allocator, "{s} (stale)", .{doc.display_name}) catch return;
    editor.allocator.free(doc.display_name);
    doc.display_name = name;
}

/// Enter inside the reader: a marker row expands its stretch; any other
/// row opens the real file at the line it stands for (a recorded jump).
pub fn activateRow(editor: *Editor, doc: *Document) void {
    const info = doc.reader orelse return;
    const pos = doc.cursorPos();
    if (info.kindAt(pos.line) == .marker) {
        for (info.runs) |run| if (run.marker_row == pos.line) {
            info.expanded.append(editor.allocator, run.old_start) catch return;
            editor.review.refetchReader(editor, realLineAt(info.real_line, pos.line));
            return;
        };
        return;
    }
    const line = realLineAt(info.real_line, pos.line) orelse 0;
    const col: u32 = if (info.kindAt(pos.line) == .ghost) 0 else @intCast(pos.col);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}", .{info.source_path}) catch return;
    editor.jumpToLocation(path, line, col, .bytes);
}

/// `review_expand_all` / `review_collapse_all`: open every collapsed
/// stretch, or fold them all again, and rebuild with the caret in place.
pub fn setAllExpanded(editor: *Editor, doc: *Document, expand: bool) void {
    const info = doc.reader orelse return;
    info.expanded.clearRetainingCapacity();
    if (expand) {
        for (info.runs) |run| info.expanded.append(editor.allocator, run.old_start) catch return;
    }
    editor.review.refetchReader(editor, realLineAt(info.real_line, doc.cursorPos().line));
}

/// Move the caret to the next (or previous) change block; false at the ends.
pub fn stepChange(doc: *Document, forward: bool) bool {
    const info = doc.reader orelse return false;
    const row = doc.cursorPos().line;
    var target: ?u32 = null;
    if (forward) {
        for (info.hunks) |hunk| if (hunk.first_row > row) {
            target = hunk.first_row;
            break;
        };
    } else {
        var i = info.hunks.len;
        while (i > 0) {
            i -= 1;
            if (info.hunks[i].first_row < row) {
                target = info.hunks[i].first_row;
                break;
            }
        }
    }
    const hit = target orelse return false;
    doc.gotoLine(hit + 1);
    return true;
}

// --- Tests ---

fn parsedFrom(a: Allocator, diff: []const u8) !unidiff.Parsed {
    return unidiff.parse(a, diff);
}

const header = "diff --git a/x.zig b/x.zig\n--- a/x.zig\n+++ b/x.zig\n@@ -1,1 +1,1 @@\n";

test "insert, delete and replace rows carry their kinds and real lines" {
    const t = std.testing;
    var inserted = try parsedFrom(t.allocator, header ++ " a\n+x\n b\n");
    defer inserted.deinit(t.allocator);
    var s1 = try synthesize(t.allocator, inserted, .{});
    defer s1.deinit(t.allocator);
    try t.expectEqualStrings("a\nx\nb\n", s1.text);
    try t.expectEqualSlices(LineKind, &.{ .context, .added, .context, .context }, s1.kinds);
    try t.expectEqualSlices(?u32, &.{ 0, 1, 2, 3 }, s1.real_line);
    try t.expectEqual(@as(usize, 1), s1.hunks.len);
    try t.expectEqual(@as(u32, 1), s1.hunks[0].first_row);

    var deleted = try parsedFrom(t.allocator, header ++ " a\n-x\n b\n");
    defer deleted.deinit(t.allocator);
    var s2 = try synthesize(t.allocator, deleted, .{});
    defer s2.deinit(t.allocator);
    try t.expectEqualStrings("a\nx\nb\n", s2.text);
    try t.expectEqualSlices(LineKind, &.{ .context, .ghost, .context, .context }, s2.kinds);
    try t.expectEqualSlices(?u32, &.{ 0, null, 1, 2 }, s2.real_line);
    try t.expectEqual(@as(?u32, 1), realLineAt(s2.real_line, 1)); // a ghost maps forward
    try t.expectEqual(@as(u32, 2), rowForReal(s2.real_line, s2.runs, 1));

    var replaced = try parsedFrom(t.allocator, header ++ " a\n-x\n-y\n+z\n b\n\\ No newline at end of file\n");
    defer replaced.deinit(t.allocator);
    var s3 = try synthesize(t.allocator, replaced, .{});
    defer s3.deinit(t.allocator);
    try t.expectEqualStrings("a\nx\ny\nz\nb", s3.text);
    try t.expectEqualSlices(LineKind, &.{ .context, .ghost, .ghost, .modified, .context }, s3.kinds);
    try t.expectEqualSlices(?u32, &.{ 0, null, null, 1, 2 }, s3.real_line);
    try t.expectEqual(@as(u32, 1), s3.hunks[0].first_row);
    try t.expectEqual(@as(u32, 3), s3.hunks[0].last_row);
}

test "a deleted file is all ghosts, an untracked file all added, an empty diff one empty row" {
    const t = std.testing;
    var gone = try parsedFrom(t.allocator, "diff --git a/g b/g\n--- a/g\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-one\n-two\n");
    defer gone.deinit(t.allocator);
    var s1 = try synthesize(t.allocator, gone, .{});
    defer s1.deinit(t.allocator);
    try t.expectEqualStrings("one\ntwo", s1.text);
    try t.expectEqualSlices(LineKind, &.{ .ghost, .ghost }, s1.kinds);
    try t.expectEqual(@as(?u32, null), realLineAt(s1.real_line, 1));

    var fresh = try parsedFrom(t.allocator, "diff --git a/n b/n\n--- /dev/null\n+++ b/n\n@@ -0,0 +1,2 @@\n+one\n+two\n");
    defer fresh.deinit(t.allocator);
    var s2 = try synthesize(t.allocator, fresh, .{});
    defer s2.deinit(t.allocator);
    try t.expectEqualSlices(LineKind, &.{ .added, .added, .context }, s2.kinds);
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, s2.text, "\n") + 1);

    var empty = try parsedFrom(t.allocator, "");
    defer empty.deinit(t.allocator);
    var s3 = try synthesize(t.allocator, empty, .{});
    defer s3.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), s3.kinds.len);
}

test "collapsing keeps context around changes, respects expansions and maps hidden lines to the marker" {
    const t = std.testing;
    var diff: std.ArrayList(u8) = .empty;
    defer diff.deinit(t.allocator);
    try diff.appendSlice(t.allocator, "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,22 +1,22 @@\n");
    try diff.appendSlice(t.allocator, "-first\n+FIRST\n");
    for (0..20) |n| try diff.print(t.allocator, " line {d}\n", .{n});
    try diff.appendSlice(t.allocator, "-last\n+LAST\n");
    var parsed = try parsedFrom(t.allocator, diff.items);
    defer parsed.deinit(t.allocator);
    var collapsed = try synthesize(t.allocator, parsed, .{ .context = 3, .ascii = true });
    defer collapsed.deinit(t.allocator);
    // ghost FIRST, 3 context, marker, 3 context, ghost LAST, trailing empty
    try t.expectEqual(@as(usize, 1), collapsed.runs.len);
    try t.expectEqual(@as(u32, 14), collapsed.runs[0].hidden);
    try t.expectEqual(@as(u32, 5), collapsed.runs[0].marker_row);
    try t.expectEqual(LineKind.marker, collapsed.kinds[5]);
    try t.expectEqual(@as(usize, 2 + 3 + 1 + 3 + 2 + 1), collapsed.kinds.len);
    try t.expectEqual(@as(usize, std.mem.count(u8, collapsed.text, "\n") + 1), collapsed.kinds.len);
    try t.expect(std.mem.indexOf(u8, collapsed.text, "... 14 unchanged lines ...") != null);
    // Hidden line 10 of the new file maps to the marker; shown line 2 to its row.
    try t.expectEqual(@as(u32, 5), rowForReal(collapsed.real_line, collapsed.runs, 10));
    try t.expectEqual(@as(u32, 3), rowForReal(collapsed.real_line, collapsed.runs, 2));
    try t.expectEqual(@as(?u32, 18), realLineAt(collapsed.real_line, 5)); // the marker maps forward to the next shown line
    try t.expectEqual(@as(usize, 2), collapsed.hunks.len);

    var expanded = try synthesize(t.allocator, parsed, .{ .context = 3, .expanded = &.{collapsed.runs[0].old_start} });
    defer expanded.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), expanded.runs.len);
    try t.expectEqual(@as(usize, 2 + 20 + 2 + 1), expanded.kinds.len);
    var whole = try synthesize(t.allocator, parsed, .{ .context = null });
    defer whole.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), whole.runs.len);
}

test "the reader tab is read-only, pathless, named and reused in place" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "x.zig", .data = "a\nx\nb\n" });
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    var parsed = try parsedFrom(t.allocator, header ++ " a\n+x\n b\n");
    defer parsed.deinit(t.allocator);
    try show(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, parsed, null, true);
    const doc = editor.activeDoc();
    try t.expect(doc.readonly);
    try t.expect(doc.file_path == null);
    try t.expect(doc.reader != null);
    try t.expectEqualStrings("Review: x.zig", doc.display_name);
    try t.expect(doc.language != null and std.ascii.eqlIgnoreCase(doc.language.?.name, "zig"));
    try t.expectEqual(@as(usize, 1), doc.cursorPos().line); // the first change
    const x_path = try std.fs.path.join(t.allocator, &.{ root, "x.zig" });
    defer t.allocator.free(x_path);
    try t.expect((try editor.findDocument(x_path)) == null);
    const reader_id = doc.id;
    const count = editor.documents.items.len;
    // Edits are refused with one message; the text is untouched.
    try t.expect(editor.execCommand("insert_char", "q"));
    try t.expectEqualStrings("Read-only review view — Enter opens the real file", editor.status_message);
    editor.status_message = "";
    try t.expect(editor.execCommand("delete_backward", null));
    try t.expectEqualStrings("Read-only review view — Enter opens the real file", editor.status_message);
    try t.expect(editor.execCommand("delete_line", null));
    try t.expect(editor.execCommand("undo", null));
    try t.expectEqualStrings("a\nx\nb\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(!doc.dirty);
    try t.expectEqual(reader_id, editor.activeDoc().id);
    try t.expect(editor.saveDocument(doc.id, .{}) == .failed);
    // Next/previous change move between hunks and stop at the ends.
    try t.expect(!stepChange(doc, true));
    try t.expect(!stepChange(doc, false));
    // The same file again rebuilds in place: no second tab.
    var again = try parsedFrom(t.allocator, header ++ " a\n+x\n+y\n b\n");
    defer again.deinit(t.allocator);
    try show(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, again, 2, true);
    try t.expectEqual(count, editor.documents.items.len);
    try t.expectEqual(reader_id, editor.activeDoc().id);
    try t.expectEqual(@as(usize, 2), editor.activeDoc().cursorPos().line);
    // Enter opens the real file at the row's line; the reader tab stays.
    activateRow(&editor, editor.activeDoc());
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, "x.zig"));
    try t.expectEqual(@as(usize, 2), editor.activeDoc().cursorPos().line);
    try t.expectEqual(count + 1, editor.documents.items.len);
    // Sessions never record the reader (no path), and closing it leaks nothing.
    const session = try editor.sessionTextAlloc();
    defer t.allocator.free(session);
    try t.expect(std.mem.indexOf(u8, session, "Review:") == null);
    const idx = editor.docIndexForId(reader_id).?;
    _ = editor.closeDocAt(idx);
    try t.expect(editor.docIndexForId(reader_id) == null);
}

test "a background rebuild changes the reader's text only, never the active tab or the mode" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.git.root = try t.allocator.dupe(u8, root);
    editor.review.tick(&editor, 0);
    var parsed = try parsedFrom(t.allocator, header ++ " a\n+x\n b\n");
    defer parsed.deinit(t.allocator);
    try show(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, parsed, null, true);
    const reader_id = editor.activeDoc().id;
    // The user moves on: another tab, and the Review view open over it.
    const other = try editor.newDocument();
    const other_id = other.id;
    editor.tool_panel.show(&editor, .review);
    try t.expectEqual(Editor.Mode.tool_panel, editor.mode);
    var again = try parsedFrom(t.allocator, header ++ " a\n+x\n+y\n b\n");
    defer again.deinit(t.allocator);
    try show(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, again, null, false);
    try t.expectEqual(Editor.Mode.tool_panel, editor.mode);
    try t.expectEqual(other_id, editor.activeDoc().id);
    const reader = &editor.documents.items[editor.docIndexForId(reader_id).?];
    try t.expectEqualStrings("a\nx\ny\nb\n", reader.buffer.slice(0, reader.buffer.byteLen()));
    // A rebuild for a closed reader is a no-op.
    editor.setMode(.normal);
    _ = editor.closeDocAt(editor.docIndexForId(reader_id).?);
    const count = editor.documents.items.len;
    try show(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, again, null, false);
    try t.expectEqual(count, editor.documents.items.len);
}

test "the classic diff tab keeps git's hunks with tints, new-file numbers and change blocks" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    const diff =
        "diff --git a/x.zig b/x.zig\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/x.zig\n" ++
        "+++ b/x.zig\n" ++
        "@@ -1,3 +1,3 @@\n" ++
        " a\n" ++
        "-b\n" ++
        "+B\n" ++
        " c\n" ++
        "@@ -10,2 +10,3 @@\n" ++
        " j\n" ++
        "+k\n" ++
        " l\n";
    try showClassic(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, diff, true);
    const doc = editor.activeDoc();
    const info = doc.reader.?;
    try t.expect(info.classic and doc.readonly);
    try t.expectEqualStrings("Diff: x.zig", doc.display_name);
    try t.expectEqualSlices(LineKind, &.{ .marker, .context, .ghost, .added, .context, .marker, .context, .added, .context }, info.kinds);
    try t.expectEqualSlices(?u32, &.{ null, 0, null, 1, 2, null, 9, 10, 11 }, info.real_line);
    try t.expectEqual(@as(usize, 2), info.hunks.len);
    try t.expectEqual(@as(u32, 2), info.hunks[0].first_row);
    try t.expectEqual(@as(u32, 7), info.hunks[1].first_row);
    try t.expectEqual(@as(usize, 2), doc.cursorPos().line); // the first change
    try t.expect(std.mem.startsWith(u8, doc.buffer.lineContent(3), "+B"));
    try t.expect(stepChange(doc, true));
    try t.expectEqual(@as(usize, 7), doc.cursorPos().line);
    // The same tab is reused for the next file.
    const count = editor.documents.items.len;
    try showClassic(&editor, .{ .root = root, .path = "y.zig", .change = 'A' }, "Binary files /dev/null and b/y.zig differ\n", true);
    try t.expectEqual(count, editor.documents.items.len);
    try t.expectEqualStrings("Diff: y.zig", editor.activeDoc().display_name);
    try t.expectEqual(LineKind.marker, editor.activeDoc().reader.?.kindAt(0));
}

test "Enter on a marker row expands that stretch and the rebuild keeps it open" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    const review = @import("review.zig");
    review.test_no_spawn = true;
    defer review.test_no_spawn = false;
    editor.git.root = try t.allocator.dupe(u8, root);
    editor.review.tick(&editor, 0);
    var diff: std.ArrayList(u8) = .empty;
    defer diff.deinit(t.allocator);
    try diff.appendSlice(t.allocator, "diff --git a/x.zig b/x.zig\n--- a/x.zig\n+++ b/x.zig\n@@ -1,22 +1,22 @@\n-first\n+FIRST\n");
    for (0..20) |n| try diff.print(t.allocator, " line {d}\n", .{n});
    try diff.appendSlice(t.allocator, "-last\n+LAST\n");
    var parsed = try parsedFrom(t.allocator, diff.items);
    defer parsed.deinit(t.allocator);
    try show(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, parsed, null, true);
    const doc = editor.activeDoc();
    const info = doc.reader.?;
    try t.expectEqual(@as(usize, 1), info.runs.len);
    try t.expectEqual(LineKind.marker, info.kindAt(5));
    // The gutter shows real line numbers and blanks for ghost/marker rows.
    try t.expectEqual(@as(?u32, null), info.real_line[0]); // ghost "first"
    try t.expectEqual(@as(?u32, 0), info.real_line[1]); // FIRST is line 1 of the new file
    try t.expectEqual(@as(?u32, null), info.real_line[5]); // the marker
    // Enter on the marker remembers the stretch and asks for a rebuild.
    doc.gotoLine(6);
    activateRow(&editor, doc);
    try t.expectEqualStrings("x.zig", editor.review.fetch.?.path);
    try t.expectEqual(@as(usize, 1), editor.activeDoc().reader.?.expanded.items.len);
    try t.expectEqual(editor.activeDoc().id, doc.id);
    // The rebuild (the fetch's result) keeps the stretch open: no marker left.
    try show(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, parsed, null, true);
    try t.expectEqual(@as(usize, 0), editor.activeDoc().reader.?.runs.len);
    try t.expectEqual(@as(usize, 2 + 20 + 2 + 1), editor.activeDoc().reader.?.kinds.len);
    // Collapse all folds it again; expand all opens it.
    setAllExpanded(&editor, editor.activeDoc(), false);
    try show(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, parsed, null, true);
    try t.expectEqual(@as(usize, 1), editor.activeDoc().reader.?.runs.len);
    setAllExpanded(&editor, editor.activeDoc(), true);
    try show(&editor, .{ .root = root, .path = "x.zig", .change = 'M' }, parsed, null, true);
    try t.expectEqual(@as(usize, 0), editor.activeDoc().reader.?.runs.len);
}
