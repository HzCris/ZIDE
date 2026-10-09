//! The review record: which changed files the user has checked, pinned to
//! the content they checked (git's blob id), plus the baseline the list of
//! changed files is taken against — the last commit, or a checkpoint commit
//! the user moves on purpose. The Review tool-panel view, the status bar
//! and the `review_*` commands read this state; nothing here draws.
const std = @import("std");
const Editor = @import("editor.zig").Editor;
const git = @import("git.zig");
const identity = @import("file_identity.zig");
const text_file = @import("text_file.zig");
const unidiff = @import("unidiff.zig");
const review_reader = @import("review_reader.zig");
const Allocator = std.mem.Allocator;

pub const Status = enum { unreviewed, approved, needs_work };
pub const BaselineMode = enum { head, checkpoint };
/// Files larger than this are tracked by stamp only (never hashed).
pub const max_hash_bytes = 4 * 1024 * 1024;
pub const max_entries = 50_000;
/// Re-hashes per validation pass, so a mass change cannot stall a frame.
const hash_budget = 16;
const validate_interval = 1500 * std.time.ns_per_ms;
/// A whole-file diff is about twice the file plus headers; files over
/// `max_hash_bytes` are listed only, so this is the one git job that may
/// exceed the 4 MiB default.
const reader_output_limit = 12 * 1024 * 1024;

/// Tests: record a reader fetch without starting git (job id 0 is never
/// issued, so the next tick simply drops it).
pub var test_no_spawn: bool = false;

/// Why a diff runs: the user asked to read the file (switch to the tab,
/// leave any panel, say so), the open reader is being rebuilt in the
/// background (change nothing but its text, and keep quiet), or the user
/// asked for the classic diff tab.
const FetchReason = enum { open, refresh, classic };

/// The diff job feeding the reader, and what it is for.
const Fetch = struct {
    job: u64,
    path: []u8,
    old_path: ?[]u8,
    change: u8,
    target_line: ?u32,
    reason: FetchReason,
    fn deinit(self: Fetch, a: Allocator) void {
        a.free(self.path);
        if (self.old_path) |p| a.free(p);
    }
};

/// A remembered verdict; a path without one is unreviewed.
pub const Entry = struct {
    /// Repository-relative, '/' separators (git's own spelling).
    path: []u8,
    status: Status,
    /// git's blob id of the content the verdict was given for; null for a
    /// deleted file or one over `max_hash_bytes` (stamp only).
    blob: ?[40]u8,
    /// Size/mtime at verdict time; null = the verdict covers a deleted file.
    stamp: ?text_file.Stamp,
    fn deinit(self: Entry, a: Allocator) void {
        a.free(self.path);
    }
};
/// One row of the Review view, rebuilt from git and never persisted.
pub const File = struct {
    path: []u8,
    old_path: ?[]u8 = null,
    /// A added, M modified, D deleted, R renamed, C copied, U conflict,
    /// ? untracked (git's own letters otherwise, e.g. T).
    change: u8,
    fn deinit(self: File, a: Allocator) void {
        a.free(self.path);
        if (self.old_path) |p| a.free(p);
    }
};
pub const Counts = struct { approved: usize = 0, needs_work: usize = 0, total: usize = 0 };

// The on-disk shape (typed std.json, the recovery.zig pattern).
const Record = struct { path: []const u8, status: Status, blob: ?[]const u8 = null, stamp: ?text_file.Stamp = null };
const Baseline = struct { mode: BaselineMode = .head, commit: ?[]const u8 = null };
const StoreFile = struct { schema: u32 = 1, baseline: Baseline = .{}, files: []const Record = &.{} };

pub const State = struct {
    /// Setting `review_stage_on_approve`: approving also stages the file.
    stage_on_approve: bool = true,
    /// The config directory; null = in-memory only (tests, no config dir).
    storage_base: ?[]u8 = null,
    /// The git root the record belongs to (an identity key, like git.State.root).
    root: ?[]u8 = null,
    /// `<base>/review/<hash>.json`; null = unusable file, never overwritten.
    storage: ?[]u8 = null,
    mode: BaselineMode = .head,
    /// The pinned checkpoint commit (40 or 64 hex), kept while in head mode too.
    commit: ?[]u8 = null,
    /// The checkpoint diff failed (commit gone): derive from HEAD for now.
    commit_missing: bool = false,
    entries: std.ArrayList(Entry) = .empty,
    files: std.ArrayList(File) = .empty,
    files_revision: u64 = 0,
    seen_git_revision: ?u64 = null,
    refresh_wanted: bool = true,
    announce_refresh: bool = false,
    /// Set by pinning: entries for files the new list no longer shows are
    /// dropped once, so a finished review does not haunt the next one.
    prune_on_next_list: bool = false,
    list_job: ?u64 = null,
    list_job_restart: bool = false,
    pin_job: ?u64 = null,
    next_validate: i128 = 0,
    reported_error: ?anyerror = null,
    /// The one reader tab, reused in place; stale once the user closes it.
    reader_doc_id: ?u64 = null,
    /// The one classic `Diff:` tab, likewise.
    classic_doc_id: ?u64 = null,
    fetch: ?Fetch = null,
    next_reader_check: i128 = 0,
    /// The reader's old side moved (baseline pinned/followed, HEAD moved):
    /// rebuild it on the next check.
    reader_refetch: bool = false,
    /// `activeFileIndex` cache: one realpath per document switch or list change.
    active_cached: bool = false,
    active_doc_id: u64 = 0,
    active_path_ptr: usize = 0,
    active_files_revision: u64 = 0,
    active_index: ?usize = null,

    pub fn deinit(self: *State, editor: *Editor) void {
        self.resetMemory(editor);
        if (self.storage_base) |base| editor.allocator.free(base);
        self.storage_base = null;
    }
    /// Forget everything about the current repository (jobs, verdicts,
    /// rows, baseline) but keep the settings and the config directory.
    fn resetMemory(self: *State, editor: *Editor) void {
        const a = editor.allocator;
        for ([_]?u64{ self.list_job, self.pin_job }) |id| if (id) |job| editor.jobs.remove(job);
        self.list_job = null;
        self.pin_job = null;
        self.list_job_restart = false;
        self.clearFetch(editor);
        self.reader_refetch = false;
        for (self.entries.items) |entry| entry.deinit(a);
        self.entries.deinit(a);
        self.entries = .empty;
        self.clearFiles(editor);
        for ([_]?[]u8{ self.root, self.storage, self.commit }) |owned| if (owned) |p| a.free(p);
        self.root = null;
        self.storage = null;
        self.commit = null;
        self.mode = .head;
        self.commit_missing = false;
        self.seen_git_revision = null;
        self.refresh_wanted = true;
        self.prune_on_next_list = false;
        self.active_cached = false;
    }
    fn clearFiles(self: *State, editor: *Editor) void {
        for (self.files.items) |file| file.deinit(editor.allocator);
        self.files.deinit(editor.allocator);
        self.files = .empty;
    }
    /// Remember the config directory; the record itself loads once the git
    /// root is known (in `tick`), and reloads when the root changes.
    pub fn configureStorage(self: *State, editor: *Editor, base: []const u8) void {
        if (self.storage_base != null) return;
        self.storage_base = editor.allocator.dupe(u8, base) catch null;
    }
    pub fn requestRefresh(self: *State) void {
        self.refresh_wanted = true;
    }
    /// The user pressed R: say what the refreshed list holds once it lands.
    pub fn requestRefreshAnnounced(self: *State) void {
        self.refresh_wanted = true;
        self.announce_refresh = true;
    }

    pub fn tick(self: *State, editor: *Editor, now: i128) void {
        self.service(editor, now) catch |err| self.reportOnce(editor, err);
    }
    fn service(self: *State, editor: *Editor, now: i128) !void {
        const root = editor.git.root orelse {
            if (self.root != null) self.resetMemory(editor);
            return;
        };
        if (self.root == null or !identity.equalKeys(self.root.?, root)) try self.switchRoot(editor, root);
        try self.pollPin(editor);
        try self.pollList(editor);
        try self.pollFetch(editor);
        const revision = editor.git.revision;
        const stale = self.refresh_wanted or self.seen_git_revision == null or self.seen_git_revision.? != revision;
        if (stale) {
            // Git's status moved (a commit, an edit the list shows): the
            // reader's old side may have too. A plain refresh request
            // (opening the Review view, R) changes nothing in it.
            if (self.seen_git_revision != null and self.seen_git_revision.? != revision) self.reader_refetch = true;
            if (self.mode == .checkpoint and !self.commit_missing and self.commit != null) {
                if (self.list_job == null) {
                    try self.startList(editor);
                    self.seen_git_revision = revision;
                    self.refresh_wanted = false;
                } else self.list_job_restart = true;
            } else {
                try self.rebuildHead(editor);
                self.seen_git_revision = revision;
                self.refresh_wanted = false;
            }
        }
        if (now >= self.next_validate) {
            self.next_validate = now + validate_interval;
            self.validate(editor);
        }
        if (now >= self.next_reader_check) {
            self.next_reader_check = now + validate_interval;
            self.checkReader(editor);
        }
    }

    // --- The reader ---

    /// The ref the reader's old side comes from.
    pub fn baseRef(self: *const State) []const u8 {
        if (self.mode == .checkpoint and !self.commit_missing) if (self.commit) |commit| return commit;
        return "HEAD";
    }
    /// Open (or rebuild in place) the reader for row `index`; `target_line`
    /// is a new-file line for the caret, else the first change.
    pub fn openReader(self: *State, editor: *Editor, index: usize, target_line: ?u32) void {
        if (index >= self.files.items.len) return;
        const file = self.files.items[index];
        // The reader of this very file is open and current: just show it.
        if (self.fetch == null and !self.reader_refetch) if (self.readerInfo(editor)) |info| if (!info.stale and std.mem.eql(u8, info.rel_path, file.path)) {
            if (review_reader.focusDoc(editor, self.reader_doc_id.?, target_line)) return;
        };
        self.startFetch(editor, file.path, file.old_path, file.change, target_line, .open) catch |err| report(editor, "{s}: {s}", .{ std.fs.path.basename(file.path), @errorName(err) });
    }
    /// The classic diff tab for row `index` of the list.
    pub fn openClassicRow(self: *State, editor: *Editor, index: usize) void {
        if (index >= self.files.items.len) return;
        const file = self.files.items[index];
        self.openClassic(editor, file.path, file.old_path, file.change);
    }
    /// The classic diff tab for a file (`git diff` with three context
    /// lines, painted like the reader).
    pub fn openClassic(self: *State, editor: *Editor, path: []const u8, old_path: ?[]const u8, change: u8) void {
        self.startFetch(editor, path, old_path, change, null, .classic) catch |err| report(editor, "{s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
    }
    /// Rebuild the open reader in place (a marker was expanded, the file
    /// or the baseline changed): the user stays where they are.
    pub fn refetchReader(self: *State, editor: *Editor, target_line: ?u32) void {
        const info = self.readerInfo(editor) orelse return;
        self.startFetch(editor, info.rel_path, info.old_path, info.change, target_line, .refresh) catch |err| report(editor, "{s}", .{@errorName(err)});
    }
    fn readerInfo(self: *State, editor: *Editor) ?*review_reader.Info {
        const id = self.reader_doc_id orelse return null;
        const idx = editor.docIndexForId(id) orelse {
            self.reader_doc_id = null;
            return null;
        };
        return editor.documents.items[idx].reader;
    }
    fn startFetch(self: *State, editor: *Editor, path: []const u8, old_path: ?[]const u8, change: u8, target_line: ?u32, reason: FetchReason) !void {
        const root = self.root orelse return error.NoRepository;
        const a = editor.allocator;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(a);
        try args.appendSlice(a, &.{ "diff", "--no-ext-diff", "--no-textconv", "--no-color", if (reason == .classic) "-U3" else "-U999999" });
        if (change == '?') {
            try args.appendSlice(a, &.{ "--no-index", "--", "/dev/null", path });
        } else {
            try args.appendSlice(a, &.{ "-M", self.baseRef(), "--", path });
            if (old_path) |old| try args.append(a, old);
        }
        const argv = try git.commandArgv(a, root, args.items);
        defer a.free(argv);
        const owned_path = try a.dupe(u8, path);
        errdefer a.free(owned_path);
        const owned_old = if (old_path) |p| try a.dupe(u8, p) else null;
        errdefer if (owned_old) |p| a.free(p);
        const job: u64 = if (@import("builtin").is_test and test_no_spawn) 0 else try editor.jobs.start(.{ .argv = argv, .strict_output = true, .output_limit = reader_output_limit });
        self.clearFetch(editor);
        self.fetch = .{ .job = job, .path = owned_path, .old_path = owned_old, .change = change, .target_line = target_line, .reason = reason };
        if (reason != .refresh) report(editor, "reading {s}…", .{std.fs.path.basename(path)});
    }
    /// The open reader document, if any.
    fn readerDoc(self: *State, editor: *Editor) ?*@import("document.zig").Document {
        const id = self.reader_doc_id orelse return null;
        const idx = editor.docIndexForId(id) orelse return null;
        return &editor.documents.items[idx];
    }
    fn clearFetch(self: *State, editor: *Editor) void {
        const fetch = self.fetch orelse return;
        editor.jobs.remove(fetch.job);
        fetch.deinit(editor.allocator);
        self.fetch = null;
    }
    fn pollFetch(self: *State, editor: *Editor) !void {
        const fetch = self.fetch orelse return;
        const job = editor.jobs.get(fetch.job) orelse {
            self.clearFetch(editor);
            return;
        };
        if (!job.isDone()) return;
        const a = editor.allocator;
        const result = try job.snapshot(a, false);
        defer result.deinit(a);
        defer self.clearFetch(editor);
        const name = std.fs.path.basename(fetch.path);
        const open = fetch.reason != .refresh;
        // A failed background rebuild keeps the old view, marked stale, and
        // stops retrying; only a user-initiated read reports and falls back.
        if (result.failure) |err| {
            if (!open) return self.staleReader(editor);
            if (err == error.StreamTooLong and fetch.reason == .open) {
                report(editor, "{s} is too large to read here; showing the classic diff", .{name});
                self.openClassic(editor, fetch.path, fetch.old_path, fetch.change);
            } else report(editor, "{s}: {s}", .{ name, @errorName(err) });
            return;
        }
        if (!(result.code == 0 or (fetch.change == '?' and result.code == 1))) {
            if (!open) return self.staleReader(editor);
            const line = std.mem.trim(u8, firstLine(result.stderr), " \r\n\t");
            return report(editor, "{s}: {s}", .{ name, if (line.len > 0) line[0..@min(line.len, 200)] else "git diff failed" });
        }
        if (fetch.reason == .classic) {
            try review_reader.showClassic(editor, .{ .root = self.root.?, .path = fetch.path, .old_path = fetch.old_path, .change = fetch.change }, result.stdout, true);
            report(editor, "Diff: {s} — Enter opens the file at that line, Ctrl+F9 back to the reader", .{name});
            return;
        }
        var parsed = unidiff.parse(a, result.stdout) catch |err| {
            if (!open) return self.staleReader(editor);
            return report(editor, "{s}: {s}", .{ name, @errorName(err) });
        };
        defer parsed.deinit(a);
        if (parsed.binary) {
            if (!open) return self.staleReader(editor);
            return report(editor, "{s} is binary; listed only", .{name});
        }
        if (parsed.lines.len == 0) {
            if (!open) return self.staleReader(editor);
            report(editor, "{s} has no text changes against {s}", .{ name, self.baseRef()[0..@min(self.baseRef().len, 7)] });
            return;
        }
        try review_reader.show(editor, .{ .root = self.root.?, .path = fetch.path, .old_path = fetch.old_path, .change = fetch.change }, parsed, fetch.target_line, open);
        if (open) report(editor, "{s} — F9 next change, Enter opens the file, Ctrl+F9 classic diff", .{name});
    }
    fn staleReader(self: *State, editor: *Editor) void {
        const doc = self.readerDoc(editor) orelse return;
        review_reader.markStale(editor, doc);
    }
    /// Rebuild the open reader when its file changed on disk or its old
    /// side moved; one check every 1.5 s, never while a fetch runs.
    fn checkReader(self: *State, editor: *Editor) void {
        const id = self.reader_doc_id orelse return;
        const idx = editor.docIndexForId(id) orelse {
            self.reader_doc_id = null;
            return;
        };
        const doc = &editor.documents.items[idx];
        const info = doc.reader orelse return;
        if (self.fetch != null) return;
        const stamp = text_file.Stamp.read(editor.io, info.source_path) catch null;
        if (!self.reader_refetch and std.meta.eql(stamp, info.disk_stamp)) return;
        self.reader_refetch = false;
        const target = review_reader.realLineAt(info.real_line, doc.cursorPos().line);
        self.startFetch(editor, info.rel_path, info.old_path, info.change, target, .refresh) catch {};
    }

    // --- The record file ---

    fn switchRoot(self: *State, editor: *Editor, root: []const u8) !void {
        const a = editor.allocator;
        self.resetMemory(editor);
        self.root = try a.dupe(u8, root);
        const base = self.storage_base orelse return;
        const path = try storagePath(a, base, root);
        self.load(editor, path) catch |err| switch (err) {
            error.OutOfMemory => {
                a.free(path);
                return err;
            },
            else => {
                std.log.warn("Review record {s}: {s}; verdicts of this repository are not saved", .{ std.fs.path.basename(path), @errorName(err) });
                report(editor, "record file {s} is unusable ({s}); verdicts are not saved", .{ std.fs.path.basename(path), @errorName(err) });
                self.clearEntries(editor);
                a.free(path);
                return;
            },
        };
        self.storage = path;
    }
    fn clearEntries(self: *State, editor: *Editor) void {
        for (self.entries.items) |entry| entry.deinit(editor.allocator);
        self.entries.clearRetainingCapacity();
    }
    /// `<base>/review/<16 hex>.json`, hashed from the git root the way
    /// breakpoints hash their workspace (Windows: '/' and lowercase).
    fn storagePath(a: Allocator, base: []const u8, root: []const u8) ![]u8 {
        const key = try a.dupe(u8, root);
        defer a.free(key);
        if (@import("builtin").os.tag == .windows) for (key) |*byte| {
            byte.* = if (byte.* == '\\') '/' else std.ascii.toLower(byte.*);
        };
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{x:0>16}.json", .{std.hash.Wyhash.hash(0, key)}) catch unreachable;
        return std.fs.path.join(a, &.{ base, "review", name });
    }
    fn load(self: *State, editor: *Editor, path: []const u8) !void {
        const a = editor.allocator;
        const text = std.Io.Dir.cwd().readFileAlloc(editor.io, path, a, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer a.free(text);
        const parsed = try std.json.parseFromSlice(StoreFile, a, text, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        defer parsed.deinit();
        const file = parsed.value;
        if (file.schema != 1) return error.UnsupportedReviewFile;
        if (file.baseline.commit) |commit| if (validCommit(commit)) {
            self.commit = try a.dupe(u8, commit);
        };
        self.mode = if (file.baseline.mode == .checkpoint and self.commit != null) .checkpoint else .head;
        for (file.files) |saved| {
            if (saved.status == .unreviewed) continue;
            git.validPath(saved.path) catch continue;
            if (self.entries.items.len >= max_entries) break;
            var blob: ?[40]u8 = null;
            if (saved.blob) |hex| if (hex.len == 40) {
                var id: [40]u8 = undefined;
                @memcpy(&id, hex);
                blob = id;
            };
            const owned = try a.dupe(u8, saved.path);
            errdefer a.free(owned);
            try self.entries.append(a, .{ .path = owned, .status = saved.status, .blob = blob, .stamp = saved.stamp });
        }
    }
    fn save(self: *State, editor: *Editor) void {
        self.write(editor) catch |err| self.reportOnce(editor, err);
    }
    fn write(self: *State, editor: *Editor) !void {
        const path = self.storage orelse return;
        const a = editor.allocator;
        const records = try a.alloc(Record, self.entries.items.len);
        defer a.free(records);
        for (self.entries.items, records) |*entry, *out| {
            out.* = .{ .path = entry.path, .status = entry.status, .blob = if (entry.blob) |*blob| blob[0..] else null, .stamp = entry.stamp };
        }
        const bytes = try std.json.Stringify.valueAlloc(a, StoreFile{ .baseline = .{ .mode = self.mode, .commit = self.commit }, .files = records }, .{});
        defer a.free(bytes);
        try std.Io.Dir.cwd().createDirPath(editor.io, std.fs.path.dirname(path).?);
        try text_file.atomicWrite(a, editor.io, path, bytes);
    }

    // --- The list of changed files ---

    /// Head mode: one row per `git status` entry, one letter each.
    fn rebuildHead(self: *State, editor: *Editor) !void {
        const a = editor.allocator;
        var list: std.ArrayList(File) = .empty;
        errdefer {
            for (list.items) |file| file.deinit(a);
            list.deinit(a);
        }
        for (editor.git.changes.items) |change| {
            if (list.items.len >= max_entries) break;
            const path = try a.dupe(u8, change.path);
            errdefer a.free(path);
            const old = if (change.old_path) |old| try a.dupe(u8, old) else null;
            errdefer if (old) |p| a.free(p);
            try list.append(a, .{ .path = path, .old_path = old, .change = changeLetter(change) });
        }
        self.replaceFiles(editor, &list);
    }
    fn changeLetter(change: git.Change) u8 {
        if (change.conflict()) return 'U';
        if (change.x == '?') return '?';
        if (change.x == 'R' or change.y == 'R') return 'R';
        if (change.x == 'C' or change.y == 'C') return 'C';
        if (change.y == 'D' or (change.x == 'D' and change.y == ' ')) return 'D';
        if (change.x == 'A' or change.y == 'A') return 'A';
        return 'M';
    }
    /// Checkpoint mode: `git diff --name-status` rows plus the untracked
    /// files, which a commit-to-worktree diff never lists.
    fn applyNameStatus(self: *State, editor: *Editor, bytes: []const u8) !void {
        const a = editor.allocator;
        var list = try parseNameStatus(a, bytes);
        errdefer {
            for (list.items) |file| file.deinit(a);
            list.deinit(a);
        }
        for (editor.git.changes.items) |change| {
            if (change.x != '?' or containsPath(list.items, change.path)) continue;
            if (list.items.len >= max_entries) break;
            const path = try a.dupe(u8, change.path);
            errdefer a.free(path);
            try list.append(a, .{ .path = path, .change = '?' });
        }
        self.replaceFiles(editor, &list);
    }
    fn replaceFiles(self: *State, editor: *Editor, list: *std.ArrayList(File)) void {
        std.mem.sort(File, list.items, {}, lessPath);
        self.clearFiles(editor);
        self.files = list.*;
        list.* = .empty;
        self.files_revision +%= 1;
        if (self.announce_refresh) {
            self.announce_refresh = false;
            report(editor, "list refreshed: {d} changed file{s}", .{ self.files.items.len, if (self.files.items.len == 1) "" else "s" });
        }
        if (self.prune_on_next_list) {
            self.prune_on_next_list = false;
            var i: usize = 0;
            var dropped = false;
            while (i < self.entries.items.len) {
                if (containsPath(self.files.items, self.entries.items[i].path)) {
                    i += 1;
                } else {
                    self.entries.orderedRemove(i).deinit(editor.allocator);
                    dropped = true;
                }
            }
            if (dropped) self.save(editor);
        }
        self.validate(editor);
    }
    fn lessPath(_: void, x: File, y: File) bool {
        return std.mem.order(u8, x.path, y.path) == .lt;
    }
    fn containsPath(files: []const File, path: []const u8) bool {
        for (files) |file| if (std.mem.eql(u8, file.path, path)) return true;
        return false;
    }
    fn startList(self: *State, editor: *Editor) !void {
        self.list_job = try editor.git.command(editor, self.root.?, &.{ "diff", "--name-status", "-z", "-M", "--no-ext-diff", "--no-textconv", self.commit.?, "--", "." });
    }
    fn pollList(self: *State, editor: *Editor) !void {
        const id = self.list_job orelse return;
        const job = editor.jobs.get(id) orelse {
            self.list_job = null;
            return;
        };
        if (!job.isDone()) return;
        const result = try job.snapshot(editor.allocator, false);
        defer result.deinit(editor.allocator);
        editor.jobs.remove(id);
        self.list_job = null;
        if (result.failure != null or result.code != 0) {
            self.commit_missing = true;
            report(editor, "checkpoint {s} is not in this repository any more; comparing with the last commit", .{self.shortCommit()});
            try self.rebuildHead(editor);
        } else try self.applyNameStatus(editor, result.stdout);
        if (self.list_job_restart) {
            self.list_job_restart = false;
            self.refresh_wanted = true;
        }
    }

    // --- Baseline ---

    /// `review_set_baseline`: pin the current commit; the list then shows
    /// what changed since it, across later commits.
    pub fn pinHead(self: *State, editor: *Editor) void {
        const root = self.root orelse return report(editor, "not a Git repository", .{});
        if (self.pin_job != null) return;
        self.pin_job = editor.git.command(editor, root, &.{ "rev-parse", "--verify", "HEAD" }) catch |err| return report(editor, "{s}", .{@errorName(err)});
        report(editor, "pinning the baseline…", .{});
    }
    fn pollPin(self: *State, editor: *Editor) !void {
        const id = self.pin_job orelse return;
        const job = editor.jobs.get(id) orelse {
            self.pin_job = null;
            return;
        };
        if (!job.isDone()) return;
        const result = try job.snapshot(editor.allocator, false);
        defer result.deinit(editor.allocator);
        editor.jobs.remove(id);
        self.pin_job = null;
        const hash = std.mem.trimEnd(u8, result.stdout, "\r\n");
        if (result.failure != null or result.code != 0 or !validCommit(hash)) return report(editor, "no commit to pin (unborn HEAD?)", .{});
        try self.pinCommit(editor, hash);
    }
    /// Make `hash` the checkpoint (also used by tests, which run no git).
    pub fn pinCommit(self: *State, editor: *Editor, hash: []const u8) !void {
        const owned = try editor.allocator.dupe(u8, hash);
        if (self.commit) |old| editor.allocator.free(old);
        self.commit = owned;
        self.mode = .checkpoint;
        self.commit_missing = false;
        self.prune_on_next_list = true;
        self.refresh_wanted = true;
        self.reader_refetch = true;
        self.save(editor);
        report(editor, "baseline pinned at {s}; the list shows what changed since then", .{self.shortCommit()});
    }
    /// `review_follow_head`: back to comparing with the last commit.
    pub fn followHead(self: *State, editor: *Editor) void {
        if (self.root == null) return report(editor, "not a Git repository", .{});
        self.mode = .head;
        self.commit_missing = false;
        self.refresh_wanted = true;
        self.reader_refetch = true;
        self.save(editor);
        report(editor, "comparing with the last commit", .{});
    }
    pub fn shortCommit(self: *const State) []const u8 {
        const commit = self.commit orelse return "";
        return commit[0..@min(commit.len, 7)];
    }
    /// What the list is compared against right now.
    pub fn baselineText(self: *const State, buf: []u8) []const u8 {
        if (self.mode == .head or self.commit == null) return "baseline: last commit";
        if (self.commit_missing) return std.fmt.bufPrint(buf, "baseline: {s} missing, using the last commit", .{self.shortCommit()}) catch "baseline: checkpoint missing";
        return std.fmt.bufPrint(buf, "baseline: {s} (checkpoint)", .{self.shortCommit()}) catch "baseline: checkpoint";
    }

    // --- Verdicts ---

    pub fn statusOf(self: *const State, path: []const u8) Status {
        const index = self.entryIndex(path) orelse return .unreviewed;
        return self.entries.items[index].status;
    }
    fn entryIndex(self: *const State, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| if (std.mem.eql(u8, entry.path, path)) return i;
        return null;
    }
    pub fn counts(self: *const State) Counts {
        var result: Counts = .{ .total = self.files.items.len };
        for (self.files.items) |file| switch (self.statusOf(file.path)) {
            .approved => result.approved += 1,
            .needs_work => result.needs_work += 1,
            .unreviewed => {},
        };
        return result;
    }
    pub fn fileIndexFor(self: *const State, path: []const u8) ?usize {
        for (self.files.items, 0..) |file, i| if (std.mem.eql(u8, file.path, path)) return i;
        return null;
    }
    /// The row of the active document, if it is a listed changed file.
    /// Cached per (document, path, list revision): resolving the path is a
    /// realpath call, and the status bar asks every frame.
    pub fn activeFileIndex(self: *State, editor: *Editor) ?usize {
        const root = self.root orelse return null;
        const doc = editor.activeDoc();
        const path = doc.file_path orelse return null;
        if (self.active_cached and self.active_doc_id == doc.id and self.active_path_ptr == @intFromPtr(path.ptr) and self.active_files_revision == self.files_revision) return self.active_index;
        self.active_cached = true;
        self.active_doc_id = doc.id;
        self.active_path_ptr = @intFromPtr(path.ptr);
        self.active_files_revision = self.files_revision;
        self.active_index = null;
        const rel = git.relative(editor.allocator, editor.io, root, path, false) catch return null;
        defer editor.allocator.free(rel);
        self.active_index = self.fileIndexFor(rel);
        return self.active_index;
    }
    /// The status-bar segment, `Review 2/9 [x]`: reviewed/total plus the
    /// active file's glyph when it is listed; empty when nothing is listed.
    pub fn statusSegment(self: *State, editor: *Editor, buf: []u8) []const u8 {
        if (self.files.items.len == 0) return "";
        const c = self.counts();
        if (self.activeFileIndex(editor)) |i| {
            return std.fmt.bufPrint(buf, "Review {d}/{d} {s}", .{ c.approved + c.needs_work, c.total, glyph(self.statusOf(self.files.items[i].path)) }) catch "";
        }
        return std.fmt.bufPrint(buf, "Review {d}/{d}", .{ c.approved + c.needs_work, c.total }) catch "";
    }
    /// Give (or, pressed again, take back) a verdict on row `index`. Refused
    /// for conflicts and for files with unsaved edits: verdicts are about
    /// what is on disk, and staging a conflict would mark it resolved.
    pub fn verdict(self: *State, editor: *Editor, index: usize, status: Status) void {
        const root = self.root orelse return report(editor, "not a Git repository", .{});
        if (index >= self.files.items.len) return;
        const file = self.files.items[index];
        const name = std.fs.path.basename(file.path);
        if (file.change == 'U') return report(editor, "resolve the conflict in {s} first", .{name});
        for ([_]?[]const u8{ file.path, file.old_path }) |maybe| if (maybe) |rel| {
            const absolute = std.fs.path.join(editor.allocator, &.{ root, rel }) catch return;
            defer editor.allocator.free(absolute);
            if (editor.findDocument(absolute) catch null) |doc_index| if (editor.documents.items[doc_index].dirty) {
                return report(editor, "save {s} first", .{std.fs.path.basename(rel)});
            };
        };
        if (self.statusOf(file.path) == status) {
            if (self.entryIndex(file.path)) |i| self.entries.orderedRemove(i).deinit(editor.allocator);
            self.save(editor);
            return report(editor, "{s} is unreviewed again", .{name});
        }
        self.record(editor, index, status) catch |err| return report(editor, "{s}: {s}", .{ name, @errorName(err) });
        self.save(editor);
        switch (status) {
            .approved => if (self.stage_on_approve) self.stageApproved(editor, file) else report(editor, "{s} approved", .{name}),
            .needs_work => report(editor, "{s} needs work", .{name}),
            .unreviewed => {},
        }
    }
    /// Store the verdict with the disk content's blob id and stamp.
    fn record(self: *State, editor: *Editor, index: usize, status: Status) !void {
        const a = editor.allocator;
        const file = self.files.items[index];
        const absolute = try std.fs.path.join(a, &.{ self.root.?, file.path });
        defer a.free(absolute);
        const stamp = try text_file.Stamp.read(editor.io, absolute);
        var blob: ?[40]u8 = null;
        if (stamp) |s| if (s.size <= max_hash_bytes) {
            blob = try blobId(a, editor.io, absolute);
        };
        if (self.entryIndex(file.path)) |i| {
            const entry = &self.entries.items[i];
            entry.status = status;
            entry.blob = blob;
            entry.stamp = stamp;
            return;
        }
        if (self.entries.items.len >= max_entries) return error.TooManyVerdicts;
        const path = try a.dupe(u8, file.path);
        errdefer a.free(path);
        try self.entries.append(a, .{ .path = path, .status = status, .blob = blob, .stamp = stamp });
    }
    /// Approving also stages — only a working-tree change that git lists
    /// (untracked included); an already-staged or checkpoint-only file has
    /// nothing to stage. `git.stage` reports its own failures; the verdict
    /// stands either way.
    fn stageApproved(self: *State, editor: *Editor, file: File) void {
        _ = self;
        const name = std.fs.path.basename(file.path);
        for (editor.git.changes.items, 0..) |change, i| {
            if (!std.mem.eql(u8, change.path, file.path)) continue;
            if (!change.working()) return report(editor, "{s} approved (already staged)", .{name});
            editor.git.stage(editor, i, false);
            return;
        }
        report(editor, "{s} approved; nothing to stage", .{name});
    }
    /// `review_next_file` / `review_prev_file`: open the reader of the next
    /// listed file, wrapping around, from the row of the active document
    /// (the reader's own file counts).
    pub fn step(self: *State, editor: *Editor, forward: bool) void {
        if (self.root == null) return report(editor, "not a Git repository", .{});
        const total = self.files.items.len;
        if (total == 0) return report(editor, "no changed files", .{});
        const current: ?usize = if (editor.activeDoc().reader) |info| self.fileIndexFor(info.rel_path) else self.activeFileIndex(editor);
        const start: usize = current orelse (if (forward) total - 1 else 0);
        const next = if (forward) (start + 1) % total else (start + total - 1) % total;
        self.openReader(editor, next, null);
    }

    // --- Keeping verdicts honest ---

    /// Drop every verdict whose file no longer has the content it was given
    /// for: a cheap stamp check per entry, a re-hash only when the stamp
    /// moved (so a no-op re-save keeps its verdict), at most `hash_budget`
    /// re-hashes per pass — the rest wait for the next pass.
    fn validate(self: *State, editor: *Editor) void {
        const root = self.root orelse return;
        const a = editor.allocator;
        var hashes: usize = 0;
        var changed = false;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            const absolute = std.fs.path.join(a, &.{ root, entry.path }) catch return;
            defer a.free(absolute);
            const stamp = text_file.Stamp.read(editor.io, absolute) catch {
                i += 1; // unreadable right now: decide next pass
                continue;
            };
            var keep = true;
            if (entry.stamp == null) {
                keep = stamp == null; // approved as deleted: it must stay gone
            } else if (stamp == null or entry.blob == null or stamp.?.size > max_hash_bytes) {
                keep = stamp != null and std.meta.eql(stamp.?, entry.stamp.?);
            } else if (!std.meta.eql(stamp.?, entry.stamp.?)) {
                if (hashes >= hash_budget) {
                    i += 1;
                    continue;
                }
                hashes += 1;
                const id = blobId(a, editor.io, absolute) catch null;
                keep = id != null and std.mem.eql(u8, &id.?, &entry.blob.?);
                if (keep) {
                    entry.stamp = stamp;
                    changed = true;
                }
            }
            if (keep) {
                i += 1;
            } else {
                self.entries.orderedRemove(i).deinit(a);
                changed = true;
            }
        }
        if (changed) self.save(editor);
    }

    fn reportOnce(self: *State, editor: *Editor, err: anyerror) void {
        if (self.reported_error != null and self.reported_error.? == err) return;
        self.reported_error = err;
        std.log.warn("Review: {s}", .{@errorName(err)});
        report(editor, "{s}", .{@errorName(err)});
    }
};

/// The status glyph of a Review row — ASCII, so the Windows console and
/// the GUI font agree.
pub fn glyph(status: Status) []const u8 {
    return switch (status) {
        .approved => "[x]",
        .needs_work => "[!]",
        .unreviewed => "[ ]",
    };
}

fn report(editor: *Editor, comptime fmt: []const u8, args: anytype) void {
    editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Review: " ++ fmt, args) catch "Review: message too long";
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

fn validCommit(hash: []const u8) bool {
    if (hash.len != 40 and hash.len != 64) return false;
    for (hash) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// `git diff --name-status -z` output: a status letter (renames and
/// copies carry a score, `R096`), then the NUL-separated path(s) — the
/// SOURCE path first for renames, the reverse of porcelain status.
pub fn parseNameStatus(a: Allocator, bytes: []const u8) !std.ArrayList(File) {
    if (bytes.len > 0 and bytes[bytes.len - 1] != 0) return error.TruncatedGitStatus;
    var result: std.ArrayList(File) = .empty;
    errdefer {
        for (result.items) |file| file.deinit(a);
        result.deinit(a);
    }
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |token| {
        if (token.len == 0) continue;
        if (result.items.len >= max_entries) return error.TooManyGitChanges;
        const letter = token[0];
        if (!std.ascii.isUpper(letter)) return error.InvalidGitStatus;
        for (token[1..]) |c| if (!std.ascii.isDigit(c)) return error.InvalidGitStatus;
        const first = records.next() orelse return error.TruncatedGitStatus;
        try git.validPath(first);
        if (letter == 'R' or letter == 'C') {
            const second = records.next() orelse return error.TruncatedGitStatus;
            try git.validPath(second);
            const path = try a.dupe(u8, second);
            errdefer a.free(path);
            const old = try a.dupe(u8, first);
            errdefer a.free(old);
            try result.append(a, .{ .path = path, .old_path = old, .change = letter });
        } else {
            const path = try a.dupe(u8, first);
            errdefer a.free(path);
            try result.append(a, .{ .path = path, .change = letter });
        }
    }
    return result;
}

/// git's blob id of a file's bytes: SHA-1 over `blob <len>\0` + content.
pub fn blobId(a: Allocator, io: std.Io, path: []const u8) ![40]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_hash_bytes));
    defer a.free(bytes);
    return blobIdOf(bytes);
}
pub fn blobIdOf(bytes: []const u8) [40]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var header: [32]u8 = undefined;
    hasher.update(std.fmt.bufPrint(&header, "blob {d}\x00", .{bytes.len}) catch unreachable);
    hasher.update(bytes);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

// --- Tests (no git process is ever started) ---

fn testChange(editor: *Editor, x: u8, y: u8, path: []const u8, old: ?[]const u8) !void {
    const a = editor.allocator;
    const owned = try a.dupe(u8, path);
    errdefer a.free(owned);
    const old_owned = if (old) |p| try a.dupe(u8, p) else null;
    try editor.git.changes.append(a, .{ .path = owned, .old_path = old_owned, .x = x, .y = y });
}

fn testWrite(dir: std.Io.Dir, io: std.Io, name: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

test "name-status parser keeps rename pairs source-first and rejects truncated or escaping paths" {
    const t = std.testing;
    var files = try parseNameStatus(t.allocator, "M\x00a.zig\x00R096\x00old.zig\x00new.zig\x00A\x00b.txt\x00D\x00gone.zig\x00");
    defer {
        for (files.items) |file| file.deinit(t.allocator);
        files.deinit(t.allocator);
    }
    try t.expectEqual(@as(usize, 4), files.items.len);
    try t.expectEqual(@as(u8, 'M'), files.items[0].change);
    try t.expectEqualStrings("a.zig", files.items[0].path);
    try t.expectEqual(@as(u8, 'R'), files.items[1].change);
    try t.expectEqualStrings("new.zig", files.items[1].path);
    try t.expectEqualStrings("old.zig", files.items[1].old_path.?);
    try t.expectEqual(@as(u8, 'D'), files.items[3].change);
    try t.expectEqualStrings("gone.zig", files.items[3].path);
    try t.expectError(error.TruncatedGitStatus, parseNameStatus(t.allocator, "M\x00a.zig"));
    try t.expectError(error.InvalidGitPath, parseNameStatus(t.allocator, "M\x00../x\x00"));
    try t.expectError(error.InvalidGitStatus, parseNameStatus(t.allocator, "?? x\x00"));
}

test "blob ids are git's" {
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", &blobIdOf("hello\n"));
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &blobIdOf(""));
}

test "head mode derives one change letter per status row, sorted by path" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.git.root = try t.allocator.dupe(u8, "/repository");
    try testChange(&editor, '?', '?', "n.txt", null);
    try testChange(&editor, 'R', ' ', "new.zig", "old.zig");
    try testChange(&editor, ' ', 'M', "m.zig", null);
    try testChange(&editor, 'M', 'M', "b.zig", null);
    try testChange(&editor, 'D', ' ', "gone.zig", null);
    try testChange(&editor, 'U', 'U', "c.txt", null);
    try testChange(&editor, 'A', ' ', "add.zig", null);
    editor.review.tick(&editor, 0);
    var letters: [7]u8 = undefined;
    for (editor.review.files.items, 0..) |file, i| letters[i] = file.change;
    try t.expectEqualStrings("AMUDM?R", &letters);
    try t.expectEqualStrings("add.zig", editor.review.files.items[0].path);
    try t.expectEqualStrings("old.zig", editor.review.files.items[6].old_path.?);
    try t.expectEqual(@as(usize, 7), editor.review.counts().total);
    // The same status output again changes nothing; a new revision rebuilds.
    const revision = editor.review.files_revision;
    editor.review.tick(&editor, 0);
    try t.expectEqual(revision, editor.review.files_revision);
    editor.git.revision += 1;
    editor.review.tick(&editor, 0);
    try t.expectEqual(revision + 1, editor.review.files_revision);
}

test "checkpoint lists union the diff rows with untracked files, no duplicates" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.git.root = try t.allocator.dupe(u8, "/repository");
    editor.review.tick(&editor, 0);
    try editor.review.pinCommit(&editor, "0123456789abcdef0123456789abcdef01234567");
    try testChange(&editor, '?', '?', "extra.txt", null);
    try testChange(&editor, '?', '?', "a.zig", null);
    try testChange(&editor, ' ', 'M', "tracked.zig", null);
    try editor.review.applyNameStatus(&editor, "M\x00a.zig\x00D\x00gone.zig\x00");
    const files = editor.review.files.items;
    try t.expectEqual(@as(usize, 3), files.len);
    try t.expectEqualStrings("a.zig", files[0].path);
    try t.expectEqual(@as(u8, 'M'), files[0].change);
    try t.expectEqualStrings("extra.txt", files[1].path);
    try t.expectEqual(@as(u8, '?'), files[1].change);
    try t.expectEqualStrings("gone.zig", files[2].path);
    var buf: [96]u8 = undefined;
    try t.expectEqualStrings("baseline: 0123456 (checkpoint)", editor.review.baselineText(&buf));
    editor.review.followHead(&editor);
    try t.expectEqualStrings("baseline: last commit", editor.review.baselineText(&buf));
}

test "verdicts follow the file's content and survive a restart" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try testWrite(tmp.dir, t.io, "a.txt", "one\n");
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.review.stage_on_approve = false;
    editor.review.configureStorage(&editor, root);
    editor.git.root = try t.allocator.dupe(u8, root);
    try testChange(&editor, ' ', 'M', "a.txt", null);
    try testChange(&editor, ' ', 'M', "b.txt", null);
    editor.review.tick(&editor, 0);
    try t.expect(editor.review.storage != null);

    editor.review.verdict(&editor, 0, .approved);
    try t.expectEqual(Status.approved, editor.review.statusOf("a.txt"));
    try t.expectEqualStrings(&blobIdOf("one\n"), &editor.review.entries.items[0].blob.?);
    try t.expectEqual(@as(usize, 1), editor.review.counts().approved);
    // Pressing approve again takes the verdict back; needs-work is a verdict too.
    editor.review.verdict(&editor, 0, .approved);
    try t.expectEqual(Status.unreviewed, editor.review.statusOf("a.txt"));
    editor.review.verdict(&editor, 0, .needs_work);
    editor.review.verdict(&editor, 0, .approved);
    try t.expectEqual(Status.approved, editor.review.statusOf("a.txt"));
    // A re-save with the same bytes keeps the verdict (new stamp, same blob).
    const a_path = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a_path);
    try text_file.atomicWrite(t.allocator, t.io, a_path, "one\n");
    editor.review.validate(&editor);
    try t.expectEqual(Status.approved, editor.review.statusOf("a.txt"));
    // Different bytes drop it back to unreviewed.
    try text_file.atomicWrite(t.allocator, t.io, a_path, "two!\n");
    editor.review.validate(&editor);
    try t.expectEqual(Status.unreviewed, editor.review.statusOf("a.txt"));
    // A verdict on a file that then disappears is dropped as well.
    editor.review.verdict(&editor, 0, .approved);
    try tmp.dir.deleteFile(t.io, "a.txt");
    editor.review.validate(&editor);
    try t.expectEqual(Status.unreviewed, editor.review.statusOf("a.txt"));

    // Persisted: a fresh state for the same root loads the record.
    try testWrite(tmp.dir, t.io, "a.txt", "three\n");
    editor.review.verdict(&editor, 0, .approved);
    editor.review.verdict(&editor, 1, .needs_work);
    try editor.review.pinCommit(&editor, "0123456789abcdef0123456789abcdef01234567");
    var fresh: State = .{};
    defer fresh.deinit(&editor);
    fresh.configureStorage(&editor, root);
    try fresh.switchRoot(&editor, root);
    try t.expect(fresh.storage != null);
    try t.expectEqual(BaselineMode.checkpoint, fresh.mode);
    try t.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", fresh.commit.?);
    try t.expectEqual(Status.approved, fresh.statusOf("a.txt"));
    try t.expectEqual(Status.needs_work, fresh.statusOf("b.txt"));
    try t.expectEqualStrings(&blobIdOf("three\n"), &fresh.entries.items[0].blob.?);
    try t.expect(std.meta.eql(editor.review.entries.items[0].stamp, fresh.entries.items[0].stamp));

    // An unknown schema leaves the file alone and keeps verdicts in memory only.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, editor.review.storage.?, t.allocator, .limited(1 << 20));
    defer t.allocator.free(bytes);
    try text_file.atomicWrite(t.allocator, t.io, editor.review.storage.?, "{\"schema\":2}");
    var other: State = .{};
    defer other.deinit(&editor);
    other.configureStorage(&editor, root);
    try other.switchRoot(&editor, root);
    try t.expect(other.storage == null);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "unusable") != null);
    const after = try std.Io.Dir.cwd().readFileAlloc(t.io, editor.review.storage.?, t.allocator, .limited(1 << 20));
    defer t.allocator.free(after);
    try t.expectEqualStrings("{\"schema\":2}", after);
}

test "verdicts are refused for conflicts and unsaved edits, and stand when staging is skipped or busy" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try testWrite(tmp.dir, t.io, "a.txt", "a\n");
    try testWrite(tmp.dir, t.io, "c.txt", "c\n");
    try testWrite(tmp.dir, t.io, "s.txt", "s\n");
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.git.root = try t.allocator.dupe(u8, root);
    try testChange(&editor, ' ', 'M', "a.txt", null);
    try testChange(&editor, 'U', 'U', "c.txt", null);
    try testChange(&editor, 'M', ' ', "s.txt", null);
    editor.review.tick(&editor, 0);
    // Conflict rows take no verdict.
    editor.review.verdict(&editor, 1, .approved);
    try t.expectEqual(Status.unreviewed, editor.review.statusOf("c.txt"));
    try t.expect(std.mem.indexOf(u8, editor.status_message, "conflict") != null);
    // Unsaved edits in the file's buffer: save first.
    const doc = try editor.newDocument();
    const a_path = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a_path);
    try doc.setFilePath(a_path);
    try doc.insertAtCursor("x");
    editor.review.verdict(&editor, 0, .approved);
    try t.expectEqual(Status.unreviewed, editor.review.statusOf("a.txt"));
    try t.expect(std.mem.indexOf(u8, editor.status_message, "save") != null);
    doc.dirty = false;
    // Already staged: approved, nothing to stage, no git process.
    editor.review.verdict(&editor, 2, .approved);
    try t.expectEqual(Status.approved, editor.review.statusOf("s.txt"));
    try t.expect(editor.git.mutation == null);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "already staged") != null);
    // Staging busy: git refuses, the verdict stands.
    editor.git.mutation = .{ .path = try t.allocator.dupe(u8, "busy.txt"), .old_path = null, .unstage = false };
    editor.review.verdict(&editor, 0, .approved);
    try t.expectEqual(Status.approved, editor.review.statusOf("a.txt"));
    try t.expectEqualStrings("busy.txt", editor.git.mutation.?.path);
    t.allocator.free(editor.git.mutation.?.path);
    editor.git.mutation = null;
    // With staging off, approving never touches git.
    editor.review.stage_on_approve = false;
    editor.review.verdict(&editor, 0, .approved); // back to unreviewed
    editor.review.verdict(&editor, 0, .approved);
    try t.expect(editor.git.mutation == null);
    try t.expectEqual(@as(usize, 2), editor.review.counts().approved);
    // The active document's row is found by its repository-relative path.
    try t.expectEqual(@as(?usize, 0), editor.review.activeFileIndex(&editor));
}
