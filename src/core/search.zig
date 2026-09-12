//! Workspace-wide find & replace engine behind the search panel.
//!
//! A background worker walks the workspace (same skips as quick-open:
//! dot-entries, zig-out, binaries, oversized files) and streams matches
//! into `pending_*` under the mutex; frontends call `drain()` each
//! frame/wake to move them into the display lists. Open documents are
//! searched on the MAIN thread before the worker starts (their buffers
//! may be dirty and must not be touched cross-thread) and their paths are
//! excluded from the disk walk. Restarting a search cancels and joins the
//! previous worker (cancel is checked per file, so the join is bounded by
//! one file read).

const std = @import("std");
const text_file = @import("text_file.zig");
const input = @import("text_input.zig");
const Document = @import("document.zig").Document;
const filetree_mod = @import("filetree.zig");

pub const max_matches = 2000;
const max_file_bytes = 8 * 1024 * 1024;
const max_depth = 12;
const excerpt_max = 200;

pub const Match = struct {
    /// Index into SearchPanel.paths.
    path_idx: u32,
    /// 0-based line number.
    line: u32,
    /// Byte column of the match start within the (raw) line.
    col: u32,
    /// Owned trimmed display line.
    excerpt: []u8,
    /// Byte offset of excerpt[0] within the raw line (leading trim) — lets
    /// views highlight THIS occurrence, not just the first on the line.
    excerpt_off: u32,
};

pub const Field = enum { query, replace, filter, exclude, results };

pub const ReplaceScope = enum { all, open_only };

pub const SearchPanel = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    // --- Inputs ---
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    replace_buf: [256]u8 = undefined,
    replace_len: usize = 0,
    /// Path filter: "*.ext" = extension match, otherwise substring.
    filter_buf: [128]u8 = undefined,
    filter_len: usize = 0,
    /// Path exclude (same pattern rules; empty = exclude nothing).
    exclude_buf: [128]u8 = undefined,
    exclude_len: usize = 0,
    case_sensitive: bool = false,
    whole_word: bool = false,
    field: Field = .query,
    /// Replace confirmation armed ("[A]ll / [O]pen only / [C]ancel" row).
    confirm_armed: bool = false,

    // --- Results (main-thread owned) ---
    /// Owned root-joined paths, one entry per file with matches.
    paths: std.ArrayList([]u8) = .empty,
    matches: std.ArrayList(Match) = .empty,
    selected: usize = 0,
    /// First visible result row (frontends clamp during draw).
    scroll: usize = 0,
    capped: bool = false,
    files_searched: usize = 0,
    files_skipped: usize = 0,
    pending_skipped: usize = 0,
    /// Open-doc portion of files_searched (worker counts disk files).
    files_searched_open: usize = 0,
    /// Worker in flight (display "searching…").
    searching: bool = false,
    /// Bumped by every start() — lets views reset per-search state
    /// (e.g. the GUI's collapsed-file set).
    generation: u64 = 0,

    // --- Worker plumbing (guarded by mutex unless noted) ---
    mutex: std.Io.Mutex = .init,
    pending_paths: std.ArrayList([]u8) = .empty,
    pending_matches: std.ArrayList(Match) = .empty,
    pending_files: usize = 0,
    pending_capped: bool = false,
    worker_done: bool = false,
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Wakes the TUI's blocking event loop when new results land
    /// (same convention as SpawnState.wake_fn; null in the GUI).
    wake_fn: ?*const fn () void = null,

    pub fn deinit(self: *SearchPanel) void {
        self.cancelJoin();
        self.clearResults();
        self.paths.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.pending_paths.deinit(self.allocator);
        self.pending_matches.deinit(self.allocator);
    }

    pub fn query(self: *const SearchPanel) []const u8 {
        return self.query_buf[0..self.query_len];
    }
    pub fn replacement(self: *const SearchPanel) []const u8 {
        return self.replace_buf[0..self.replace_len];
    }
    pub fn filter(self: *const SearchPanel) []const u8 {
        return self.filter_buf[0..self.filter_len];
    }
    pub fn exclude(self: *const SearchPanel) []const u8 {
        return self.exclude_buf[0..self.exclude_len];
    }

    /// Append typed text to the focused input field.
    pub fn appendText(self: *SearchPanel, txt: []const u8) void {
        const dest: struct { buf: []u8, len: *usize } = switch (self.field) {
            .query => .{ .buf = &self.query_buf, .len = &self.query_len },
            .replace => .{ .buf = &self.replace_buf, .len = &self.replace_len },
            .filter => .{ .buf = &self.filter_buf, .len = &self.filter_len },
            .exclude => .{ .buf = &self.exclude_buf, .len = &self.exclude_len },
            .results => return,
        };
        input.append(dest.buf, dest.len, txt);
        self.confirm_armed = false;
    }

    /// Backspace in the focused input field.
    pub fn backspace(self: *SearchPanel) void {
        const len: *usize = switch (self.field) {
            .query => &self.query_len,
            .replace => &self.replace_len,
            .filter => &self.filter_len,
            .exclude => &self.exclude_len,
            .results => return,
        };
        const buf: []const u8 = switch (self.field) {
            .query => &self.query_buf,
            .replace => &self.replace_buf,
            .filter => &self.filter_buf,
            .exclude => &self.exclude_buf,
            .results => return,
        };
        input.backspace(buf, len);
        self.confirm_armed = false;
    }

    /// Tab: cycle query → replace → filter → exclude → results → query.
    pub fn cycleField(self: *SearchPanel) void {
        self.field = switch (self.field) {
            .query => .replace,
            .replace => .filter,
            .filter => .exclude,
            .exclude => .results,
            .results => .query,
        };
    }

    /// Move the result selection (frontends fix scroll at draw time).
    pub fn moveSelection(self: *SearchPanel, delta_down: bool, step: usize) void {
        const count = self.matches.items.len;
        if (count == 0) return;
        if (delta_down) {
            self.selected = @min(self.selected + step, count - 1);
        } else {
            self.selected -|= step;
        }
    }

    /// Start (or restart) a search with the current inputs. Open documents
    /// are searched immediately; a worker covers the rest of the workspace.
    pub fn start(self: *SearchPanel, editor: anytype) void {
        self.cancelJoin();
        self.clearResults();
        self.confirm_armed = false;
        self.generation +%= 1;
        const needle = self.query();
        if (needle.len == 0) return;

        const ctx = self.allocator.create(WorkerCtx) catch return;
        ctx.* = .{
            .sp = self,
            .allocator = self.allocator,
            .io = self.io,
            .root = &.{},
            .needle = &.{},
            .filter = &.{},
            .exclude = &.{},
            .case_sensitive = self.case_sensitive,
            .whole_word = self.whole_word,
        };
        var ok = true;
        ctx.needle = self.allocator.dupe(u8, needle) catch blk: {
            ok = false;
            break :blk &.{};
        };
        const root: []const u8 = editor.filetree_root orelse "";
        ctx.root = self.allocator.dupe(u8, root) catch blk: {
            ok = false;
            break :blk &.{};
        };
        ctx.filter = self.allocator.dupe(u8, self.filter()) catch blk: {
            ok = false;
            break :blk &.{};
        };
        ctx.exclude = self.allocator.dupe(u8, self.exclude()) catch blk: {
            ok = false;
            break :blk &.{};
        };
        // The path filters use '/' separators internally.
        for (@constCast(ctx.filter)) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
        for (@constCast(ctx.exclude)) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }

        for (editor.encoding_choices.items) |choice| {
            const path = self.allocator.dupe(u8, choice.path) catch {
                ok = false;
                break;
            };
            ctx.encodings.append(self.allocator, .{ .path = path, .encoding = choice.encoding }) catch {
                self.allocator.free(path);
                ok = false;
                break;
            };
        }
        // Open documents: search buffers on the main thread, and have the
        // worker skip their paths so they aren't double-counted from disk.
        for (editor.documents.items) |*doc| {
            if (doc.preview) continue;
            const p = doc.file_path orelse continue;
            if (self.allocator.dupe(u8, p)) |dup| {
                ctx.open_paths.append(self.allocator, dup) catch self.allocator.free(dup);
            } else |_| {}
            const text = doc.buffer.slice(0, doc.buffer.byteLen());
            self.searchOpenDoc(p, text, needle);
            self.files_searched_open += 1;
            self.files_searched = self.files_searched_open;
        }

        if (!ok) {
            ctx.destroy();
            return;
        }
        ctx.base_matches = self.matches.items.len;
        ctx.base_path_idx = @intCast(self.paths.items.len);
        self.cancel.store(false, .release);
        self.worker_done = false;
        self.pending_capped = false;
        self.pending_files = 0;
        self.searching = true;
        self.thread = std.Thread.spawn(.{}, workerMain, .{ctx}) catch null;
        if (self.thread == null) {
            ctx.destroy();
            self.searching = false;
        }
    }

    /// Cancel and reap the worker (bounded: cancel is checked per file).
    pub fn cancelJoin(self: *SearchPanel) void {
        self.cancel.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.searching = false;
    }

    /// Move worker results into the display lists. Returns true when
    /// anything changed (frontends redraw / TUI wakes call this).
    pub fn drain(self: *SearchPanel) bool {
        if (!self.searching) return false;
        var changed = false;
        self.mutex.lockUncancelable(self.io);
        if (self.pending_paths.items.len > 0 or self.pending_matches.items.len > 0) changed = true;
        for (self.pending_paths.items) |p| {
            self.paths.append(self.allocator, p) catch self.allocator.free(p);
        }
        self.pending_paths.clearRetainingCapacity();
        for (self.pending_matches.items) |m| {
            self.matches.append(self.allocator, m) catch self.allocator.free(m.excerpt);
        }
        self.pending_matches.clearRetainingCapacity();
        if (self.files_skipped != self.pending_skipped) {
            self.files_skipped = self.pending_skipped;
            changed = true;
        }
        const total_files = self.files_searched_open + self.pending_files;
        if (total_files != self.files_searched) {
            self.files_searched = total_files;
            changed = true;
        }
        if (self.pending_capped and !self.capped) {
            self.capped = true;
            changed = true;
        }
        const done = self.worker_done;
        self.mutex.unlock(self.io);
        if (done) {
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            self.searching = false;
            changed = true;
        }
        return changed;
    }

    /// Free all result state (not the input fields).
    pub fn clearResults(self: *SearchPanel) void {
        for (self.paths.items) |p| self.allocator.free(p);
        self.paths.clearRetainingCapacity();
        for (self.matches.items) |m| self.allocator.free(m.excerpt);
        self.matches.clearRetainingCapacity();
        for (self.pending_paths.items) |p| self.allocator.free(p);
        self.pending_paths.clearRetainingCapacity();
        for (self.pending_matches.items) |m| self.allocator.free(m.excerpt);
        self.pending_matches.clearRetainingCapacity();
        self.selected = 0;
        self.scroll = 0;
        self.capped = false;
        self.files_searched = 0;
        self.files_skipped = 0;
        self.pending_skipped = 0;
        self.files_searched_open = 0;
        self.pending_files = 0;
        self.pending_capped = false;
    }

    /// Main-thread search of one open document's buffer text.
    fn searchOpenDoc(self: *SearchPanel, path: []const u8, text: []const u8, needle: []const u8) void {
        var emitted_path = false;
        var line_no: u32 = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| : (line_no += 1) {
            var from: usize = 0;
            while (findInText(line, needle, self.case_sensitive, self.whole_word, from)) |at| {
                if (self.matches.items.len >= max_matches) {
                    self.capped = true;
                    return;
                }
                if (!emitted_path) {
                    const dup = self.allocator.dupe(u8, path) catch return;
                    self.paths.append(self.allocator, dup) catch {
                        self.allocator.free(dup);
                        return;
                    };
                    emitted_path = true;
                }
                const excerpt = makeExcerpt(self.allocator, line, at, needle.len) catch return;
                self.matches.append(self.allocator, .{
                    .path_idx = @intCast(self.paths.items.len - 1),
                    .line = line_no,
                    .col = @intCast(at),
                    .excerpt = excerpt.text,
                    .excerpt_off = excerpt.off,
                }) catch {
                    self.allocator.free(excerpt.text);
                    return;
                };
                from = at + needle.len;
            }
        }
    }

    /// Execute Replace All over the current result set. Open documents get
    /// one undoable edit group each (buffers stay dirty, user saves);
    /// closed files are rewritten on disk when scope == .all.
    pub fn executeReplace(self: *SearchPanel, editor: anytype, scope: ReplaceScope) struct { files: usize, count: usize, failed: usize } {
        self.confirm_armed = false;
        const needle = self.query();
        const repl = self.replacement();
        var files: usize = 0;
        var total: usize = 0;
        var failed: usize = 0;
        if (needle.len == 0) return .{ .files = 0, .count = 0, .failed = 0 };
        for (self.paths.items) |p| {
            var open_doc: ?*Document = null;
            for (editor.documents.items) |*doc| {
                if (doc.preview) continue;
                const dp = doc.file_path orelse continue;
                if (filetree_mod.normPathEql(dp, p)) {
                    open_doc = doc;
                    break;
                }
            }
            var n: usize = 0;
            if (open_doc) |doc| {
                n = replaceAllInDoc(doc, needle, repl, self.case_sensitive, self.whole_word) catch {
                    failed += 1;
                    continue;
                };
            } else if (scope == .all) {
                n = replaceAllInFile(self.allocator, self.io, p, needle, repl, self.case_sensitive, self.whole_word, editor.knownEncoding(p)) catch {
                    failed += 1;
                    continue;
                };
            }
            if (n > 0) {
                files += 1;
                total += n;
            }
        }
        return .{ .files = files, .count = total, .failed = failed };
    }

    /// How many result files are open docs vs on disk (for the confirm row).
    pub fn replaceTargets(self: *SearchPanel, editor: anytype) struct { open: usize, disk: usize } {
        var open: usize = 0;
        var disk: usize = 0;
        for (self.paths.items) |p| {
            var is_open = false;
            for (editor.documents.items) |*doc| {
                if (doc.preview) continue;
                const dp = doc.file_path orelse continue;
                if (filetree_mod.normPathEql(dp, p)) {
                    is_open = true;
                    break;
                }
            }
            if (is_open) open += 1 else disk += 1;
        }
        return .{ .open = open, .disk = disk };
    }
};

// ---------------------------------------------------------------------------
// Matching / replacing primitives (pure, testable)
// ---------------------------------------------------------------------------

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Find `needle` in `text` at or after `from`, honoring case sensitivity
/// and whole-word boundaries. Returns the match start.
pub fn findInText(text: []const u8, needle: []const u8, case_sensitive: bool, whole_word: bool, from: usize) ?usize {
    if (needle.len == 0 or from + needle.len > text.len) return null;
    var i = from;
    outer: while (i + needle.len <= text.len) : (i += 1) {
        for (needle, 0..) |nc, j| {
            const hc = text[i + j];
            const eq = if (case_sensitive)
                hc == nc
            else
                std.ascii.toLower(hc) == std.ascii.toLower(nc);
            if (!eq) continue :outer;
        }
        if (whole_word) {
            if (i > 0 and isWordChar(text[i - 1])) continue;
            if (i + needle.len < text.len and isWordChar(text[i + needle.len])) continue;
        }
        return i;
    }
    return null;
}

/// Replace every (non-overlapping) occurrence; returns the new text and count.
pub fn replaceInText(allocator: std.mem.Allocator, text: []const u8, needle: []const u8, repl: []const u8, case_sensitive: bool, whole_word: bool) !struct { out: []u8, count: usize } {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var count: usize = 0;
    var i: usize = 0;
    while (findInText(text, needle, case_sensitive, whole_word, i)) |at| {
        try out.appendSlice(allocator, text[i..at]);
        try out.appendSlice(allocator, repl);
        count += 1;
        i = at + needle.len;
    }
    try out.appendSlice(allocator, text[i..]);
    return .{ .out = try out.toOwnedSlice(allocator), .count = count };
}

/// Path filter: empty = everything; "*.ext" = case-insensitive extension;
/// otherwise case-insensitive substring over the '/'-separated rel path.
pub fn filterMatch(rel: []const u8, filt: []const u8) bool {
    if (filt.len == 0) return true;
    if (filt.len > 1 and filt[0] == '*' and filt[1] == '.') {
        const suffix = filt[1..];
        if (rel.len < suffix.len) return false;
        return std.ascii.eqlIgnoreCase(rel[rel.len - suffix.len ..], suffix);
    }
    if (filt.len > rel.len) return false;
    var i: usize = 0;
    while (i + filt.len <= rel.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(rel[i .. i + filt.len], filt)) return true;
    }
    return false;
}

/// Undoable replace-all inside an open document (one undo group).
/// Mirrors the per-buffer Ctrl+H replace-all mechanics.
pub fn replaceAllInDoc(doc: *Document, needle: []const u8, repl: []const u8, case_sensitive: bool, whole_word: bool) !usize {
    const content = try doc.buffer.textAlloc(doc.allocator);
    defer doc.allocator.free(content);
    var ranges: std.ArrayList(Document.RangeEdit) = .empty;
    defer ranges.deinit(doc.allocator);
    var from: usize = 0;
    while (findInText(content, needle, case_sensitive, whole_word, from)) |at| {
        try ranges.append(doc.allocator, .{ .start = at, .end = at + needle.len, .text = repl });
        from = at + needle.len;
    }
    std.mem.reverse(Document.RangeEdit, ranges.items);
    try doc.applyRanges(ranges.items);
    return ranges.items.len;
}

/// Closed-file edits retain the source encoding and commit atomically.
pub fn replaceAllInFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, needle: []const u8, repl: []const u8, case_sensitive: bool, whole_word: bool, encoding: ?text_file.TextEncoding) !usize {
    const decoded = try text_file.read(allocator, io, path, encoding, max_file_bytes);
    defer allocator.free(decoded.text);
    const res = try replaceInText(allocator, decoded.text, needle, repl, case_sensitive, whole_word);
    defer allocator.free(res.out);
    if (res.count == 0) return 0;
    try text_file.write(allocator, io, path, res.out, decoded.format);
    return res.count;
}

const Excerpt = struct { text: []u8, off: u32 };

/// Capture the display excerpt for ONE occurrence: whitespace-trimmed and,
/// when the line exceeds the cap, windowed so THIS match sits inside it
/// (about a third in) — a from-the-start cap left far-right matches with
/// no highlightable text at all.
fn makeExcerpt(allocator: std.mem.Allocator, line: []const u8, col: usize, needle_len: usize) !Excerpt {
    const left_ws = line.len - std.mem.trimStart(u8, line, " \t\r").len;
    const trimmed_end = std.mem.trimEnd(u8, line, " \t\r").len;
    var start: usize = @min(left_ws, trimmed_end);
    var end: usize = trimmed_end;
    if (end - start > excerpt_max) {
        const hit_end = @min(col + needle_len, end);
        if (hit_end > start + excerpt_max) {
            start = @max(start, @min(col -| (excerpt_max / 3), end - excerpt_max));
        }
        end = @min(end, start + excerpt_max);
        start = utf8FloorIdx(line, start);
        end = utf8FloorIdx(line, end);
        if (start > end) start = end;
    }
    return .{ .text = try allocator.dupe(u8, line[start..end]), .off = @intCast(start) };
}

/// Move a byte index back to the start of its UTF-8 sequence.
fn utf8FloorIdx(s: []const u8, idx: usize) usize {
    var i = @min(idx, s.len);
    while (i > 0 and i < s.len and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

const WorkerCtx = struct {
    sp: *SearchPanel,
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    needle: []const u8,
    filter: []const u8,
    exclude: []const u8,
    case_sensitive: bool,
    whole_word: bool,
    open_paths: std.ArrayList([]u8) = .empty,
    encodings: std.ArrayList(struct { path: []u8, encoding: text_file.TextEncoding }) = .empty,
    /// Matches already in the display lists when the worker started
    /// (open-doc hits) — the cap covers the combined total.
    base_matches: usize = 0,
    /// Next path index continues after the open-doc paths.
    base_path_idx: u32 = 0,
    emitted_matches: usize = 0,
    emitted_paths: u32 = 0,
    stopped: bool = false,

    fn destroy(self: *WorkerCtx) void {
        const a = self.allocator;
        a.free(self.root);
        a.free(self.needle);
        a.free(self.filter);
        a.free(self.exclude);
        for (self.open_paths.items) |p| a.free(p);
        self.open_paths.deinit(a);
        for (self.encodings.items) |entry| a.free(entry.path);
        self.encodings.deinit(a);
        a.destroy(self);
    }
};

/// Public for tests: the worker body, runnable synchronously.
pub fn workerMain(ctx: *WorkerCtx) void {
    defer ctx.destroy();
    const sp = ctx.sp;
    const open_root: []const u8 = if (ctx.root.len == 0) "." else ctx.root;
    if (std.Io.Dir.cwd().openDir(ctx.io, open_root, .{ .iterate = true })) |dir| {
        var d = dir;
        defer d.close(ctx.io);
        walkDir(ctx, d, "", 0);
    } else |_| {}

    sp.mutex.lockUncancelable(sp.io);
    sp.worker_done = true;
    const wake = sp.wake_fn;
    sp.mutex.unlock(sp.io);
    if (wake) |w| w();
}

fn walkDir(ctx: *WorkerCtx, dir: std.Io.Dir, prefix: []const u8, depth: usize) void {
    if (depth > max_depth or ctx.stopped) return;
    const sp = ctx.sp;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (ctx.stopped or sp.cancel.load(.acquire)) {
            ctx.stopped = true;
            return;
        }
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .file => searchDiskFile(ctx, dir, prefix, entry.name),
            .directory => {
                if (std.mem.eql(u8, entry.name, "zig-out")) continue;
                var sub = dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(ctx.io);
                const sub_prefix = std.fmt.allocPrint(ctx.allocator, "{s}{s}/", .{ prefix, entry.name }) catch continue;
                defer ctx.allocator.free(sub_prefix);
                walkDir(ctx, sub, sub_prefix, depth + 1);
            },
            else => {},
        }
    }
}

fn searchDiskFile(ctx: *WorkerCtx, dir: std.Io.Dir, prefix: []const u8, name: []const u8) void {
    const sp = ctx.sp;
    var rel_buf: [1024]u8 = undefined;
    const rel = std.fmt.bufPrint(&rel_buf, "{s}{s}", .{ prefix, name }) catch return;
    if (!filterMatch(rel, ctx.filter)) return;
    if (ctx.exclude.len > 0 and filterMatch(rel, ctx.exclude)) return;

    // Full (root-joined) path — what results store and openOrFocus uses.
    var full_buf: [1200]u8 = undefined;
    const full = if (ctx.root.len == 0)
        rel
    else
        std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ ctx.root, rel }) catch return;

    // Open documents were already searched on the main thread.
    for (ctx.open_paths.items) |op| {
        if (filetree_mod.normPathEql(op, full)) return;
    }

    _ = dir;
    const key = text_file.pathKey(ctx.allocator, ctx.io, full) catch return;
    defer ctx.allocator.free(key);
    var encoding: ?text_file.TextEncoding = null;
    for (ctx.encodings.items) |entry| {
        if (filetree_mod.normPathEql(key, entry.path)) {
            encoding = entry.encoding;
            break;
        }
    }
    const decoded = text_file.read(ctx.allocator, ctx.io, full, encoding, max_file_bytes) catch {
        sp.mutex.lockUncancelable(sp.io);
        sp.pending_skipped += 1;
        sp.pending_files += 1;
        sp.mutex.unlock(sp.io);
        return;
    };
    defer ctx.allocator.free(decoded.text);
    const bytes = decoded.text;

    var file_matches: std.ArrayList(Match) = .empty;
    defer file_matches.deinit(ctx.allocator);
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    scan: while (it.next()) |line| : (line_no += 1) {
        var from: usize = 0;
        while (findInText(line, ctx.needle, ctx.case_sensitive, ctx.whole_word, from)) |at| {
            if (ctx.base_matches + ctx.emitted_matches + file_matches.items.len >= max_matches) {
                ctx.stopped = true;
                break :scan;
            }
            const excerpt = makeExcerpt(ctx.allocator, line, at, ctx.needle.len) catch break :scan;
            file_matches.append(ctx.allocator, .{
                .path_idx = ctx.base_path_idx + ctx.emitted_paths,
                .line = line_no,
                .col = @intCast(at),
                .excerpt = excerpt.text,
                .excerpt_off = excerpt.off,
            }) catch {
                ctx.allocator.free(excerpt.text);
                break :scan;
            };
            from = at + ctx.needle.len;
        }
    }

    const had_matches = file_matches.items.len > 0;
    var path_dup: ?[]u8 = null;
    if (had_matches) {
        path_dup = ctx.allocator.dupe(u8, full) catch null;
        if (path_dup == null) {
            for (file_matches.items) |m| ctx.allocator.free(m.excerpt);
            bumpFiles(sp);
            return;
        }
    }

    sp.mutex.lockUncancelable(sp.io);
    sp.pending_files += 1;
    if (had_matches) {
        var appended_path = false;
        if (sp.pending_paths.append(ctx.allocator, path_dup.?)) |_| {
            appended_path = true;
        } else |_| {
            ctx.allocator.free(path_dup.?);
        }
        if (appended_path) {
            for (file_matches.items) |m| {
                sp.pending_matches.append(ctx.allocator, m) catch {
                    ctx.allocator.free(m.excerpt);
                };
            }
            ctx.emitted_paths += 1;
            ctx.emitted_matches += file_matches.items.len;
            file_matches.clearRetainingCapacity();
        } else {
            for (file_matches.items) |m| ctx.allocator.free(m.excerpt);
            file_matches.clearRetainingCapacity();
        }
    }
    if (ctx.stopped) sp.pending_capped = true;
    const wake = if (had_matches) sp.wake_fn else null;
    sp.mutex.unlock(sp.io);
    if (wake) |w| w();
}

fn bumpFiles(sp: *SearchPanel) void {
    sp.mutex.lockUncancelable(sp.io);
    sp.pending_files += 1;
    sp.mutex.unlock(sp.io);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "findInText: case and whole-word rules" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 6), findInText("hello World", "world", false, false, 0));
    try t.expectEqual(@as(?usize, null), findInText("hello World", "world", true, false, 0));
    try t.expectEqual(@as(?usize, 6), findInText("hello World", "World", true, false, 0));
    // Whole word: "cat" not inside "concatenate"
    try t.expectEqual(@as(?usize, null), findInText("concatenate", "cat", false, true, 0));
    try t.expectEqual(@as(?usize, 4), findInText("the cat sat", "cat", false, true, 0));
    // from offset advances past earlier hits
    try t.expectEqual(@as(?usize, 8), findInText("cat and cat", "cat", false, false, 1));
    // snake_case counts as one word
    try t.expectEqual(@as(?usize, null), findInText("foo_bar", "foo", false, true, 0));
}

test "replaceInText counts and rewrites" {
    const t = std.testing;
    const r = try replaceInText(t.allocator, "a cat and a cat", "cat", "dog", false, false);
    defer t.allocator.free(r.out);
    try t.expectEqual(@as(usize, 2), r.count);
    try t.expectEqualStrings("a dog and a dog", r.out);
    // Replacement containing the needle must not loop
    const r2 = try replaceInText(t.allocator, "x x", "x", "xx", false, false);
    defer t.allocator.free(r2.out);
    try t.expectEqual(@as(usize, 2), r2.count);
    try t.expectEqualStrings("xx xx", r2.out);
    // Whole-word replace leaves substrings alone
    const r3 = try replaceInText(t.allocator, "cat concatenate", "cat", "dog", false, true);
    defer t.allocator.free(r3.out);
    try t.expectEqual(@as(usize, 1), r3.count);
    try t.expectEqualStrings("dog concatenate", r3.out);
}

test "filterMatch extension and substring" {
    const t = std.testing;
    try t.expect(filterMatch("src/core/editor.zig", ""));
    try t.expect(filterMatch("src/core/editor.zig", "*.zig"));
    try t.expect(!filterMatch("src/core/editor.zig", "*.md"));
    try t.expect(filterMatch("src/core/editor.zig", "core"));
    try t.expect(filterMatch("SRC/Core/Editor.ZIG", "*.zig"));
    try t.expect(!filterMatch("docs/readme.md", "src/"));
}

test "replace all is one transaction and restores every cursor snapshot" {
    const t = std.testing;
    const Cursor = @import("cursor.zig").Cursor;
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.loadText("éé é");
    doc.cursors.primary().offset = 2;
    doc.cursors.primary().anchor = 0;
    try doc.cursors.addCursor(7);
    doc.cursors.cursors.items[1].anchor = 5;
    const before = try t.allocator.dupe(Cursor, doc.cursors.cursors.items);
    defer t.allocator.free(before);
    try t.expectEqual(@as(usize, 3), try replaceAllInDoc(&doc, "é", "😀", true, false));
    const after = try t.allocator.dupe(Cursor, doc.cursors.cursors.items);
    defer t.allocator.free(after);
    try t.expectEqualStrings("😀😀 😀", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = try doc.undoAction();
    try t.expectEqualStrings("éé é", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualSlices(Cursor, before, doc.cursors.cursors.items);
    _ = try doc.redoAction();
    try t.expectEqualSlices(Cursor, after, doc.cursors.cursors.items);
    try t.expectEqual(@as(usize, 3), try replaceAllInDoc(&doc, "😀", "", true, false));
    try t.expectEqualStrings(" ", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "every replace-all allocation failure leaves content cursors and history unchanged" {
    const t = std.testing;
    const Cursor = @import("cursor.zig").Cursor;
    for (0..64) |fail_index| {
        var doc = try Document.init(t.allocator);
        defer doc.deinit();
        try doc.loadText("catcat\ncat");
        try doc.cursors.addCursor(10);
        const before = try t.allocator.dupe(Cursor, doc.cursors.cursors.items);
        defer t.allocator.free(before);
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        doc.allocator = a;
        doc.buffer.allocator = a;
        doc.history.allocator = a;
        doc.cursors.allocator = a;
        const result = replaceAllInDoc(&doc, "cat", "😀\n", true, false);
        doc.allocator = t.allocator;
        doc.buffer.allocator = t.allocator;
        doc.history.allocator = t.allocator;
        doc.cursors.allocator = t.allocator;
        if (result) |count| {
            try t.expectEqual(@as(usize, 3), count);
            try t.expect(!failing.has_induced_failure);
            return;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expectEqualStrings("catcat\ncat", doc.buffer.slice(0, doc.buffer.byteLen()));
            try t.expectEqualSlices(Cursor, before, doc.cursors.cursors.items);
            try t.expect(!doc.dirty and !doc.history.canUndo());
        }
    }
    return error.ExpectedSuccess;
}
