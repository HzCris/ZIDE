//! Asynchronous workspace Git status, read-only previews and explicit file staging.
const std = @import("std");
const Editor = @import("editor.zig").Editor;
const Document = @import("document.zig").Document;
const identity = @import("file_identity.zig");
const text_file = @import("text_file.zig");
const output = @import("tool_output.zig");
const diff = @import("line_diff.zig");
const Allocator = std.mem.Allocator;
pub const Change = struct {
    path: []u8,
    old_path: ?[]u8 = null,
    x: u8,
    y: u8,
    pub fn staged(self: Change) bool {
        return self.x != ' ' and self.x != '?';
    }
    pub fn working(self: Change) bool {
        return self.y != ' ';
    }
    pub fn conflict(self: Change) bool {
        return self.x == 'U' or self.y == 'U' or (self.x == 'A' and self.y == 'A') or (self.x == 'D' and self.y == 'D');
    }
    fn deinit(self: Change, a: Allocator) void {
        a.free(self.path);
        if (self.old_path) |path| a.free(path);
    }
};
pub fn parseStatus(a: Allocator, bytes: []const u8) !std.ArrayList(Change) {
    if (bytes.len > 0 and bytes[bytes.len - 1] != 0) return error.TruncatedGitStatus;
    var result: std.ArrayList(Change) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(a);
        result.deinit(a);
    }
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        if (record.len < 4 or record[2] != ' ') return error.InvalidGitStatus;
        if (result.items.len >= 50_000) return error.TooManyGitChanges;
        const path = try a.dupe(u8, record[3..]);
        errdefer a.free(path);
        try validPath(path);
        const renamed = record[0] == 'R' or record[0] == 'C' or record[1] == 'R' or record[1] == 'C';
        const old = if (renamed) try a.dupe(u8, records.next() orelse return error.TruncatedGitStatus) else null;
        errdefer if (old) |p| a.free(p);
        if (old) |p| try validPath(p);
        try result.append(a, .{ .path = path, .old_path = old, .x = record[0], .y = record[1] });
    }
    return result;
}
fn validPath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidGitPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidGitPath;
}

const Worker = struct {
    allocator: Allocator,
    io: std.Io,
    before: []u8,
    after: []u8,
    version: u64,
    epoch: u64,
    future: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    marks: ?[]diff.Mark = null,
    failure: ?anyerror = null,
    mutex: std.Io.Mutex = .init,
    wake: ?*const fn () void = null,
    fn run(self: *Worker) void {
        self.marks = diff.compare(self.allocator, self.before, self.after) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.done.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.wake) |wake| wake();
    }
    fn setWake(self: *Worker, wake: ?*const fn () void) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.wake = wake;
    }
    fn destroy(self: *Worker) void {
        self.setWake(null);
        if (self.future) |*future| future.cancel(self.io);
        if (self.marks) |marks| self.allocator.free(marks);
        self.allocator.free(self.before);
        self.allocator.free(self.after);
        self.allocator.destroy(self);
    }
};
const Cache = struct {
    doc_id: u64,
    path: []u8,
    relative: ?[]u8,
    base: ?[]u8 = null,
    epoch: u64 = 0,
    version: ?u64 = null,
    marks: ?[]diff.Mark = null,
    worker: ?*Worker = null,
    failure: ?anyerror = null,
    fn deinit(self: *Cache, a: Allocator) void {
        a.free(self.path);
        if (self.relative) |rel| a.free(rel);
        if (self.base) |base| a.free(base);
        if (self.marks) |marks| a.free(marks);
        if (self.worker) |worker| worker.destroy();
    }
};
const Mutation = struct {
    path: []u8,
    old_path: ?[]u8,
    unstage: bool,
    include_old: bool = true,
    save_ids: [2]u64 = .{ 0, 0 },
    save_count: usize = 0,
    save_index: usize = 0,
    waiting: bool = false,
    fn deinit(self: Mutation, a: Allocator) void {
        a.free(self.path);
        if (self.old_path) |path| a.free(path);
    }
};
pub const State = struct {
    enabled: bool = !@import("builtin").is_test,
    workspace_raw: ?[]u8 = null,
    workspace: ?[]u8 = null,
    root: ?[]u8 = null,
    index_path: ?[]u8 = null,
    index_stamp: ?text_file.Stamp = null,
    index_epoch: u64 = 1,
    next_check: i128 = 0,
    next_status: i128 = 0,
    discovered: bool = false,
    refresh_requested: bool = true,
    meta_job: ?u64 = null,
    meta_kind: enum { root, index, status } = .root,
    changes: std.ArrayList(Change) = .empty,
    status_bytes: std.ArrayList(u8) = .empty,
    revision: u64 = 0,
    message: [512]u8 = undefined,
    message_len: usize = 0,
    preview: output.Output = .{},
    preview_job: ?u64 = null,
    preview_path: ?[]u8 = null,
    preview_staged: bool = false,
    preview_conflict: bool = false,
    preview_untracked: bool = false,
    preview_epoch: u64 = 0,
    preview_stamp: ?text_file.Stamp = null,
    mutation: ?Mutation = null,
    mutation_job: ?u64 = null,
    caches: std.ArrayList(Cache) = .empty,
    base_job: ?struct { id: u64, doc_id: u64, epoch: u64 } = null,

    pub fn deinit(self: *State, editor: *Editor) void {
        for ([_]?u64{ self.meta_job, self.preview_job, self.mutation_job, if (self.base_job) |job| job.id else null }) |id| if (id) |job| editor.jobs.remove(job);
        for (self.caches.items) |*cache| cache.deinit(editor.allocator);
        self.caches.deinit(editor.allocator);
        for (self.changes.items) |change| change.deinit(editor.allocator);
        self.changes.deinit(editor.allocator);
        self.status_bytes.deinit(editor.allocator);
        self.preview.deinit(editor.allocator);
        for ([_]?[]u8{ self.workspace_raw, self.workspace, self.root, self.index_path, self.preview_path }) |path| if (path) |p| editor.allocator.free(p);
        if (self.mutation) |mutation| mutation.deinit(editor.allocator);
    }
    pub fn setWake(self: *State, wake: ?*const fn () void) void {
        for (self.caches.items) |cache| if (cache.worker) |worker| worker.setWake(wake);
    }
    pub fn requestRefresh(self: *State) void {
        self.enabled = true;
        self.refresh_requested = true;
        if (self.root == null) self.discovered = false;
    }
    pub fn status(self: *State) []const u8 {
        return self.message[0..self.message_len];
    }
    fn report(self: *State, editor: *Editor, message: []const u8) void {
        const rendered = std.fmt.bufPrint(&self.message, "Git: {s}", .{message}) catch "Git error";
        self.message_len = rendered.len;
        if (rendered.ptr != &self.message) @memcpy(self.message[0..rendered.len], rendered);
        editor.status_message = self.status();
    }
    fn command(self: *State, editor: *Editor, cwd: []const u8, args: []const []const u8) !u64 {
        _ = self;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(editor.allocator);
        try argv.appendSlice(editor.allocator, &.{ "git", "--no-pager", "--literal-pathspecs", "--no-optional-locks", "-c", "color.ui=false", "-c", "core.quotepath=false", "-C", cwd });
        try argv.appendSlice(editor.allocator, args);
        return editor.jobs.start(.{ .argv = argv.items, .strict_output = true });
    }
    pub fn tick(self: *State, editor: *Editor, now: i128) void {
        if (!self.enabled) return;
        self.service(editor, now) catch |err| self.report(editor, @errorName(err));
    }
    fn service(self: *State, editor: *Editor, now: i128) !void {
        const raw: []const u8 = if (editor.filetree) |ft| ft.root_path else editor.filetree_root orelse ".";
        if (self.workspace_raw == null or !std.mem.eql(u8, self.workspace_raw.?, raw)) {
            const owned = try editor.allocator.dupe(u8, raw);
            errdefer editor.allocator.free(owned);
            const absolute = try identity.absolute(editor.allocator, editor.io, raw);
            self.deinit(editor);
            self.* = .{ .enabled = true, .workspace_raw = owned, .workspace = absolute };
        }
        if (editor.filetree) |*ft| if (ft.git_refresh_requested) {
            ft.git_refresh_requested = false;
            self.refresh_requested = true;
        };
        if (self.meta_job) |id| {
            const job = editor.jobs.get(id).?;
            if (job.isDone()) {
                const result = try job.snapshot(editor.allocator, false);
                defer result.deinit(editor.allocator);
                editor.jobs.remove(id);
                self.meta_job = null;
                try self.metaResult(editor, result, now);
            }
        }
        if (now >= self.next_check) {
            self.next_check = now + 1500 * std.time.ns_per_ms;
            if (self.index_path) |path| {
                const stamp = try text_file.Stamp.read(editor.io, path);
                if (!std.meta.eql(stamp, self.index_stamp)) {
                    self.index_stamp = stamp;
                    self.index_epoch +%= 1;
                    self.refresh_requested = true;
                }
            }
            if (now >= self.next_status and self.root != null) self.refresh_requested = true;
        }
        if (self.meta_job == null) {
            if (!self.discovered) {
                self.discovered = true;
                self.meta_kind = .root;
                self.meta_job = try self.command(editor, self.workspace.?, &.{ "rev-parse", "--show-toplevel" });
            } else if (self.root != null and self.index_path == null) {
                self.meta_kind = .index;
                self.meta_job = try self.command(editor, self.root.?, &.{ "rev-parse", "--path-format=absolute", "--git-path", "index" });
            } else if (self.root != null and self.refresh_requested) {
                self.refresh_requested = false;
                self.meta_kind = .status;
                self.next_status = now + 10 * std.time.ns_per_s;
                self.meta_job = try self.command(editor, self.root.?, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all" });
            }
        }
        try self.pollPreview(editor);
        try self.pollMutation(editor);
        if (self.mutation) |mutation| if (mutation.waiting and editor.mode == .normal and editor.lsp_tools.formatting == null) {
            const id = mutation.save_ids[mutation.save_index];
            const index = editor.docIndexForId(id);
            if (index == null or editor.documents.items[index.?].dirty) self.cancelMutation(editor) else {
                self.mutation.?.waiting = false;
                self.mutation.?.save_index += 1;
                self.saveAndStage(editor);
            }
        };
        if (self.root != null and self.index_path != null) try self.gutters(editor);
    }
    fn metaResult(self: *State, editor: *Editor, result: @import("jobs.zig").Snapshot, now: i128) !void {
        // Failed or malformed index discovery waits for an explicit refresh.
        // Keeping a root with no index path would retry on every editor tick.
        errdefer if (self.meta_kind == .index) {
            if (self.root) |root| editor.allocator.free(root);
            self.root = null;
        };
        if (result.failure) |err| return err;
        if (result.code != 0) {
            self.report(editor, if (self.meta_kind == .root) "Workspace is not a repository, or Git is unavailable" else "Status lookup failed; refresh to retry");
            // A failed index lookup must not restart a subprocess each frame.
            if (self.meta_kind == .index) {
                editor.allocator.free(self.root.?);
                self.root = null;
            }
            return;
        }
        const path = std.mem.trimEnd(u8, result.stdout, "\r\n");
        switch (self.meta_kind) {
            .root => {
                if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\n') != null) return error.UnsupportedRepositoryPath;
                self.root = try identity.key(editor.allocator, editor.io, path);
            },
            .index => {
                if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\n') != null) return error.UnsupportedRepositoryPath;
                self.index_path = try editor.allocator.dupe(u8, path);
                self.index_stamp = try text_file.Stamp.read(editor.io, path);
            },
            .status => {
                var changes = try parseStatus(editor.allocator, result.stdout);
                defer {
                    for (changes.items) |change| change.deinit(editor.allocator);
                    changes.deinit(editor.allocator);
                }
                if (!std.mem.eql(u8, self.status_bytes.items, result.stdout)) {
                    try self.status_bytes.ensureTotalCapacity(editor.allocator, result.stdout.len);
                    self.status_bytes.clearRetainingCapacity();
                    self.status_bytes.appendSliceAssumeCapacity(result.stdout);
                    for (self.changes.items) |change| change.deinit(editor.allocator);
                    self.changes.deinit(editor.allocator);
                    self.changes = changes;
                    changes = .empty;
                    self.revision +%= 1;
                    self.index_epoch +%= 1;
                }
                if (editor.filetree) |*ft| {
                    const prefix = try relative(editor.allocator, editor.io, self.root.?, ft.root_path, true);
                    defer editor.allocator.free(prefix);
                    ft.clearGitMaps();
                    if (ft.git_enabled) try ft.parseGitPorcelain(prefix, result.stdout);
                }
                self.message_len = 0;
                self.next_status = now + 10 * std.time.ns_per_s;
            },
        }
    }

    pub fn previewChange(self: *State, editor: *Editor, selected: usize, staged: bool) void {
        self.startPreview(editor, selected, staged) catch |err| self.report(editor, @errorName(err));
    }
    fn startPreview(self: *State, editor: *Editor, selected: usize, staged: bool) !void {
        if (selected >= self.changes.items.len) return;
        const change = self.changes.items[selected];
        const path = try editor.allocator.dupe(u8, change.path);
        errdefer editor.allocator.free(path);
        const absolute = try std.fs.path.join(editor.allocator, &.{ self.root orelse return error.NoRepository, path });
        defer editor.allocator.free(absolute);
        const stamp = text_file.Stamp.read(editor.io, absolute) catch null;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(editor.allocator);
        const untracked = change.x == '?';
        try args.appendSlice(editor.allocator, &.{ "diff", "--no-ext-diff", "--no-textconv", "--no-color" });
        if (staged) try args.append(editor.allocator, "--cached");
        if (untracked and !staged) try args.appendSlice(editor.allocator, &.{ "--no-index", "--", "/dev/null", change.path }) else {
            try args.appendSlice(editor.allocator, &.{ "--", change.path });
            if (change.old_path) |old| try args.append(editor.allocator, old);
        }
        const job = try self.command(editor, self.root orelse return error.NoRepository, args.items);
        if (self.preview_job) |old| editor.jobs.remove(old);
        self.preview_job = job;
        if (self.preview_path) |old| editor.allocator.free(old);
        self.preview_path = path;
        self.preview.deinit(editor.allocator);
        self.preview = .{};
        self.preview_staged = staged;
        self.preview_untracked = untracked;
        self.preview_conflict = change.conflict();
        self.preview_epoch = self.index_epoch;
        self.preview_stamp = stamp;
        editor.tool_panel.show(editor, .git_diff);
    }
    fn pollPreview(self: *State, editor: *Editor) !void {
        const id = self.preview_job orelse return;
        const job = editor.jobs.get(id).?;
        if (!job.isDone()) return;
        const result = try job.snapshot(editor.allocator, false);
        defer result.deinit(editor.allocator);
        editor.jobs.remove(id);
        self.preview_job = null;
        const absolute = try std.fs.path.join(editor.allocator, &.{ self.root.?, self.preview_path.? });
        defer editor.allocator.free(absolute);
        const stamp = text_file.Stamp.read(editor.io, absolute) catch null;
        if (self.preview_epoch != self.index_epoch or !std.meta.eql(stamp, self.preview_stamp)) {
            try self.preview.append(editor.allocator, "File or index changed while loading. Reopen the preview to refresh.");
            return;
        }
        if (self.preview_conflict) try self.preview.append(editor.allocator, "Unresolved conflict. This preview is read-only; edit the source file to resolve it.\n\n");
        if (result.failure) |err| {
            try self.preview.append(editor.allocator, @errorName(err));
        } else if (result.code != 0 and !(self.preview_untracked and result.code == 1)) {
            try self.preview.append(editor.allocator, "Git diff failed:\n");
        }
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(editor.allocator);
        var filter: output.Sanitizer = .{};
        try filter.feed(editor.allocator, &clean, result.stdout, true);
        try self.preview.append(editor.allocator, clean.items);
        clean.clearRetainingCapacity();
        try filter.feed(editor.allocator, &clean, result.stderr, true);
        try self.preview.append(editor.allocator, clean.items);
        self.preview.truncated = self.preview.truncated or result.truncated;
        if (self.preview.text.items.len == 0) try self.preview.append(editor.allocator, "No changes in this comparison.");
    }

    pub fn stage(self: *State, editor: *Editor, index: usize, unstage: bool) void {
        self.beginMutation(editor, index, unstage) catch |err| self.report(editor, @errorName(err));
    }
    fn beginMutation(self: *State, editor: *Editor, index: usize, unstage: bool) !void {
        if (self.mutation != null) return error.GitOperationInProgress;
        if (index >= self.changes.items.len) return;
        const change = self.changes.items[index];
        var pending: Mutation = .{ .path = try editor.allocator.dupe(u8, change.path), .old_path = null, .unstage = unstage, .include_old = unstage or (change.x != 'R' and change.x != 'C') };
        errdefer pending.deinit(editor.allocator);
        if (change.old_path) |old| pending.old_path = try editor.allocator.dupe(u8, old);
        if (!unstage) for ([_]?[]const u8{ pending.path, if (pending.include_old) pending.old_path else null }) |item| if (item) |path| {
            const absolute = try std.fs.path.join(editor.allocator, &.{ self.root.?, path });
            defer editor.allocator.free(absolute);
            if (try editor.findDocument(absolute)) |doc_index| {
                const doc = &editor.documents.items[doc_index];
                if (doc.dirty and (pending.save_count == 0 or pending.save_ids[0] != doc.id)) {
                    pending.save_ids[pending.save_count] = doc.id;
                    pending.save_count += 1;
                }
            }
        };
        self.mutation = pending;
        if (pending.save_count > 0) editor.mode = .git_stage_prompt else self.startMutation(editor) catch |err| {
            self.cancelMutation(editor);
            self.report(editor, @errorName(err));
        };
    }
    pub fn resolveStage(self: *State, editor: *Editor, save: bool) void {
        editor.mode = .normal;
        if (save) self.saveAndStage(editor) else self.cancelMutation(editor);
    }
    fn saveAndStage(self: *State, editor: *Editor) void {
        while (self.mutation != null and self.mutation.?.save_index < self.mutation.?.save_count) {
            const pending = &self.mutation.?;
            const id = pending.save_ids[pending.save_index];
            const index = editor.docIndexForId(id) orelse {
                self.cancelMutation(editor);
                return;
            };
            const doc = &editor.documents.items[index];
            const rel = relative(editor.allocator, editor.io, self.root.?, doc.file_path orelse {
                self.cancelMutation(editor);
                return;
            }, false) catch {
                self.cancelMutation(editor);
                return;
            };
            defer editor.allocator.free(rel);
            if (!identity.equalKeys(rel, pending.path) and !(pending.old_path != null and identity.equalKeys(rel, pending.old_path.?))) {
                self.cancelMutation(editor);
                self.report(editor, "File moved during save; refresh Changes and select it again");
                return;
            }
            if (!doc.dirty) {
                pending.save_index += 1;
                continue;
            }
            pending.waiting = true;
            switch (editor.saveDocument(id, .{})) {
                .saved => {
                    const saved = editor.docIndexForId(id) orelse {
                        self.cancelMutation(editor);
                        return;
                    };
                    if (editor.documents.items[saved].dirty) {
                        self.cancelMutation(editor);
                        self.report(editor, "Save hook changed the buffer; staging cancelled");
                        return;
                    }
                    pending.waiting = false;
                    pending.save_index += 1;
                },
                .formatting, .conflict, .destination_exists, .unrepresentable => return,
                .needs_path, .failed => {
                    self.cancelMutation(editor);
                    return;
                },
            }
        }
        if (self.mutation != null) self.startMutation(editor) catch |err| {
            self.cancelMutation(editor);
            self.report(editor, @errorName(err));
        };
    }
    fn startMutation(self: *State, editor: *Editor) !void {
        const pending = self.mutation orelse return;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(editor.allocator);
        // Path reset supports an unborn HEAD and changes only the selected index entries.
        try args.appendSlice(editor.allocator, if (pending.unstage) &.{ "reset", "-q", "--" } else &.{ "add", "-A", "--" });
        try args.append(editor.allocator, pending.path);
        if (pending.include_old) if (pending.old_path) |old| try args.append(editor.allocator, old);
        self.mutation_job = try self.command(editor, self.root.?, args.items);
        self.report(editor, if (pending.unstage) "Unstaging selected files…" else "Staging saved files…");
    }
    fn pollMutation(self: *State, editor: *Editor) !void {
        const id = self.mutation_job orelse return;
        const job = editor.jobs.get(id).?;
        if (!job.isDone()) return;
        const result = try job.snapshot(editor.allocator, false);
        defer result.deinit(editor.allocator);
        editor.jobs.remove(id);
        self.mutation_job = null;
        defer {
            self.mutation.?.deinit(editor.allocator);
            self.mutation = null;
        }
        if (result.failure) |err| self.report(editor, @errorName(err)) else if (result.code == 0) {
            self.report(editor, if (self.mutation.?.unstage) "Selected files unstaged" else "Selected saved files staged");
        } else {
            var clean: std.ArrayList(u8) = .empty;
            defer clean.deinit(editor.allocator);
            var filter: output.Sanitizer = .{};
            try filter.feed(editor.allocator, &clean, result.stderr, true);
            self.report(editor, if (clean.items.len > 0) clean.items[0..@min(clean.items.len, 480)] else "Index operation failed");
        }
        self.index_epoch +%= 1;
        self.refresh_requested = true;
        self.next_check = 0;
    }
    fn cancelMutation(self: *State, editor: *Editor) void {
        if (self.mutation_job != null) return; // A started index write is not represented as rolled back.
        if (self.mutation) |mutation| mutation.deinit(editor.allocator);
        self.mutation = null;
        if (editor.mode == .git_stage_prompt) editor.mode = .normal;
    }

    fn cacheFor(self: *State, doc_id: u64) ?*Cache {
        for (self.caches.items) |*cache| if (cache.doc_id == doc_id) return cache;
        return null;
    }
    pub fn marker(self: *State, doc: *const Document, line: usize) diff.Mark {
        const cache = self.cacheFor(doc.id) orelse return .none;
        if (cache.version != doc.buffer.version or cache.epoch != self.index_epoch) return .none;
        const marks = cache.marks orelse return .none;
        return if (line < marks.len) marks[line] else .none;
    }
    fn gutters(self: *State, editor: *Editor) !void {
        var index: usize = 0;
        while (index < self.caches.items.len) {
            const cache = &self.caches.items[index];
            const doc_index = editor.docIndexForId(cache.doc_id);
            if (doc_index == null or !std.mem.eql(u8, editor.documents.items[doc_index.?].file_path orelse "", cache.path)) {
                cache.deinit(editor.allocator);
                _ = self.caches.orderedRemove(index);
            } else index += 1;
        }
        for (editor.documents.items) |doc| {
            if (doc.preview or self.cacheFor(doc.id) != null) continue;
            const path = doc.file_path orelse continue;
            const owned = try editor.allocator.dupe(u8, path);
            errdefer editor.allocator.free(owned);
            const rel = relative(editor.allocator, editor.io, self.root.?, path, false) catch null;
            errdefer if (rel) |r| editor.allocator.free(r);
            try self.caches.append(editor.allocator, .{ .doc_id = doc.id, .path = owned, .relative = rel });
        }
        if (self.base_job) |pending| {
            const job = editor.jobs.get(pending.id).?;
            if (job.isDone()) {
                const result = try job.snapshot(editor.allocator, false);
                defer result.deinit(editor.allocator);
                editor.jobs.remove(pending.id);
                self.base_job = null;
                if (self.cacheFor(pending.doc_id)) |cache| if (pending.epoch == self.index_epoch) {
                    cache.epoch = pending.epoch;
                    cache.failure = result.failure;
                    if (cache.base) |base| editor.allocator.free(base);
                    cache.base = null;
                    cache.version = null;
                    if (result.failure == null) {
                        if (result.code == 0) {
                            const doc_index = editor.docIndexForId(cache.doc_id).?;
                            const decoded = text_file.decode(editor.allocator, result.stdout, editor.documents.items[doc_index].format.encoding) catch |err| {
                                cache.failure = err;
                                return;
                            };
                            cache.base = decoded.text;
                        } else {
                            var untracked = false;
                            for (self.changes.items) |change| if (change.x == '?' and std.mem.eql(u8, change.path, cache.relative.?)) {
                                untracked = true;
                                break;
                            };
                            if (untracked) cache.base = try editor.allocator.dupe(u8, "") else cache.failure = error.IndexContentUnavailable;
                        }
                    }
                };
            }
        }
        var worker_running = false;
        for (self.caches.items) |*cache| if (cache.worker) |worker| {
            if (!worker.done.load(.acquire)) {
                worker_running = true;
                continue;
            }
            if (worker.future) |*future| future.await(editor.io);
            if (cache.epoch == worker.epoch) {
                if (cache.marks) |marks| editor.allocator.free(marks);
                cache.marks = worker.marks;
                worker.marks = null;
                cache.version = worker.version;
                cache.failure = worker.failure;
            }
            worker.destroy();
            cache.worker = null;
        };
        for (self.caches.items) |*cache| {
            const rel = cache.relative orelse continue;
            if (cache.epoch != self.index_epoch and self.base_job == null) {
                const object = try std.fmt.allocPrint(editor.allocator, ":{s}", .{rel});
                defer editor.allocator.free(object);
                self.base_job = .{ .id = try self.command(editor, self.root.?, &.{ "show", object }), .doc_id = cache.doc_id, .epoch = self.index_epoch };
            }
            if (cache.epoch != self.index_epoch or cache.base == null or cache.worker != null or worker_running) continue;
            const doc = &editor.documents.items[editor.docIndexForId(cache.doc_id).?];
            if (cache.version == doc.buffer.version) continue;
            if (doc.buffer.byteLen() > 4 * 1024 * 1024) {
                cache.failure = error.DiffTooLarge;
                cache.version = doc.buffer.version;
                continue;
            }
            const before = try editor.allocator.dupe(u8, cache.base.?);
            errdefer editor.allocator.free(before);
            const after = try editor.allocator.dupe(u8, doc.buffer.slice(0, doc.buffer.byteLen()));
            errdefer editor.allocator.free(after);
            const worker = try editor.allocator.create(Worker);
            errdefer editor.allocator.destroy(worker);
            worker.* = .{ .allocator = editor.allocator, .io = editor.io, .before = before, .after = after, .version = doc.buffer.version, .epoch = cache.epoch, .wake = editor.jobs.wake_fn };
            worker.future = try editor.io.concurrent(Worker.run, .{worker});
            cache.worker = worker;
            worker_running = true;
        }
    }
};

fn relative(a: Allocator, io: std.Io, root: []const u8, path: []const u8, directory: bool) ![]u8 {
    const full = try identity.key(a, io, path);
    defer a.free(full);
    if (full.len < root.len or !identity.equalKeys(full[0..root.len], root)) return error.OutsideRepository;
    if (full.len > root.len and !std.fs.path.isSep(root[root.len - 1]) and !std.fs.path.isSep(full[root.len])) return error.OutsideRepository;
    const suffix = std.mem.trimStart(u8, full[root.len..], if (@import("builtin").os.tag == .windows) "/\\" else "/");
    const result = if (directory and suffix.len > 0) try std.fmt.allocPrint(a, "{s}/", .{suffix}) else try a.dupe(u8, suffix);
    if (@import("builtin").os.tag == .windows) std.mem.replaceScalar(u8, result, '\\', '/');
    if (!directory) validPath(result) catch |err| {
        a.free(result);
        return err;
    };
    return result;
}

test "Git index discovery failures wait for refresh instead of spawning on every tick" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.git.discovered = true;
    editor.git.meta_kind = .index;
    const snapshot: @import("jobs.zig").Snapshot = .{
        .stdout = @constCast("invalid relative path"),
        .stderr = @constCast(""),
        .code = 0,
        .failure = null,
        .cancelled = false,
        .truncated = false,
        .done = true,
        .revision = 0,
    };
    editor.git.root = try t.allocator.dupe(u8, "/repository");
    try t.expectError(error.UnsupportedRepositoryPath, editor.git.metaResult(&editor, snapshot, 0));
    try t.expect(editor.git.root == null and editor.git.discovered);
    var failed = snapshot;
    failed.failure = error.OutputLimit;
    editor.git.root = try t.allocator.dupe(u8, "/repository");
    try t.expectError(error.OutputLimit, editor.git.metaResult(&editor, failed, 0));
    try t.expect(editor.git.root == null and editor.git.discovered);
    editor.git.requestRefresh();
    try t.expect(!editor.git.discovered);
}

test "Git porcelain keeps both rename paths and literal unusual filenames" {
    const t = std.testing;
    var changes = try parseStatus(t.allocator, "R  café new.txt\x00old name.txt\x00MM both.zig\x00?? :(glob)*.txt\x00UU conflict.txt\x00");
    defer {
        for (changes.items) |change| change.deinit(t.allocator);
        changes.deinit(t.allocator);
    }
    try t.expectEqualStrings("old name.txt", changes.items[0].old_path.?);
    try t.expect(changes.items[1].staged() and changes.items[1].working());
    try t.expect(changes.items[3].conflict());
    try t.expectError(error.TruncatedGitStatus, parseStatus(t.allocator, " M bad"));
}

fn fixtureGit(base: []const u8, args: []const []const u8) ![]u8 {
    const t = std.testing;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.appendSlice(t.allocator, &.{ "git", "--literal-pathspecs", "-C", base, "-c", "user.name=ZIDE Test", "-c", "user.email=zide-test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" });
    try argv.appendSlice(t.allocator, args);
    const result = try std.process.run(t.allocator, t.io, .{ .argv = argv.items });
    defer t.allocator.free(result.stderr);
    errdefer t.allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("Git fixture: {s}\n", .{result.stderr});
        return error.GitFixtureFailed;
    }
    return result.stdout;
}
fn fixtureCommand(base: []const u8, args: []const []const u8) !void {
    std.testing.allocator.free(try fixtureGit(base, args));
}
fn settle(editor: *Editor) !void {
    for (0..1500) |_| {
        editor.git.tick(editor, std.Io.Clock.now(.awake, editor.io).nanoseconds);
        if (editor.git.meta_kind == .status and editor.git.meta_job == null and !editor.git.refresh_requested and editor.git.preview_job == null and editor.git.mutation_job == null) return;
        try std.Io.sleep(editor.io, .fromMilliseconds(10), .awake);
    }
    return error.GitTestTimeout;
}
fn changeIndex(self: *State, path: []const u8) !usize {
    for (self.changes.items, 0..) |change, i| if (std.mem.eql(u8, change.path, path)) return i;
    return error.GitChangeMissing;
}

test "Git integration: Save As during a dirty-stage prompt preserves the index until a fresh selection" {
    if (!@import("build_options").test_tools) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const original = try std.fs.path.join(t.allocator, &.{ base, "original.txt" });
    defer t.allocator.free(original);
    const destination = try std.fs.path.join(t.allocator, &.{ base, "saved as.txt" });
    defer t.allocator.free(destination);
    try fixtureCommand(base, &.{ "init", "-q" });
    try text_file.atomicWrite(t.allocator, t.io, original, "disk\n");
    try fixtureCommand(base, &.{ "add", "--", "original.txt" });
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, base);
    editor.git.requestRefresh();
    try settle(&editor);
    try editor.openIntoActive(original);
    try editor.activeDoc().insertAtCursor("dirty\n");
    editor.git.stage(&editor, try changeIndex(&editor.git, "original.txt"), false);
    try t.expectEqual(Editor.Mode.git_stage_prompt, editor.mode);
    try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(editor.activeDoc().id, .{ .path = destination }));
    editor.git.resolveStage(&editor, true);
    try t.expect(editor.git.mutation == null and editor.git.mutation_job == null);
    const index = try fixtureGit(base, &.{ "show", ":original.txt" });
    defer t.allocator.free(index);
    try t.expectEqualStrings("disk\n", index);
    editor.git.requestRefresh();
    try settle(&editor);
    editor.git.stage(&editor, try changeIndex(&editor.git, "saved as.txt"), false);
    try settle(&editor);
    const saved = try fixtureGit(base, &.{ "show", ":saved as.txt" });
    defer t.allocator.free(saved);
    try t.expectEqualStrings("dirty\ndisk\n", saved);
}

test "Git integration: unborn HEAD, literal staging, dirty saves, previews, rename and buffer gutters" {
    if (!@import("build_options").test_tools) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    try fixtureCommand(base, &.{ "init", "-q" });
    const name = "café [1].txt";
    const path = try std.fs.path.join(t.allocator, &.{ base, name });
    defer t.allocator.free(path);
    const other = try std.fs.path.join(t.allocator, &.{ base, "other.txt" });
    defer t.allocator.free(other);
    try text_file.atomicWrite(t.allocator, t.io, path, "disk\n");
    try text_file.atomicWrite(t.allocator, t.io, other, "other\n");
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, base);
    editor.git.requestRefresh();
    try settle(&editor);
    try t.expectEqual(@as(usize, 2), editor.git.changes.items.len);
    editor.git.previewChange(&editor, try changeIndex(&editor.git, name), false);
    try settle(&editor);
    try t.expect(std.mem.indexOf(u8, editor.git.preview.text.items, "+disk") != null);
    editor.mode = .normal;
    editor.git.stage(&editor, try changeIndex(&editor.git, name), false);
    try settle(&editor);
    try t.expectEqual(@as(u8, 'A'), editor.git.changes.items[try changeIndex(&editor.git, name)].x);
    editor.git.previewChange(&editor, try changeIndex(&editor.git, name), true);
    try settle(&editor);
    try t.expect(std.mem.indexOf(u8, editor.git.preview.text.items, "+disk") != null);
    editor.mode = .normal;
    editor.git.stage(&editor, try changeIndex(&editor.git, name), true);
    try settle(&editor);
    try t.expectEqual(@as(u8, '?'), editor.git.changes.items[try changeIndex(&editor.git, name)].x);
    editor.git.stage(&editor, try changeIndex(&editor.git, name), false);
    try settle(&editor);
    try editor.openIntoActive(path);
    try editor.activeDoc().insertAtCursor("unsaved\n");
    for (0..1000) |_| {
        editor.git.tick(&editor, std.Io.Clock.now(.awake, t.io).nanoseconds);
        if (editor.git.marker(editor.activeDoc(), 0) == .added) break;
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    try t.expectEqual(diff.Mark.added, editor.git.marker(editor.activeDoc(), 0));
    editor.git.stage(&editor, try changeIndex(&editor.git, name), false);
    try t.expectEqual(Editor.Mode.git_stage_prompt, editor.mode);
    editor.git.resolveStage(&editor, false);
    try t.expect(editor.activeDoc().dirty);
    const initial_index = try fixtureGit(base, &.{ "show", ":café [1].txt" });
    defer t.allocator.free(initial_index);
    try t.expectEqualStrings("disk\n", initial_index);
    editor.git.stage(&editor, try changeIndex(&editor.git, name), false);
    editor.git.resolveStage(&editor, true);
    try settle(&editor);
    try t.expect(!editor.activeDoc().dirty);
    const saved_index = try fixtureGit(base, &.{ "show", ":café [1].txt" });
    defer t.allocator.free(saved_index);
    try t.expectEqualStrings("unsaved\ndisk\n", saved_index);
    try t.expectEqual(@as(u8, '?'), editor.git.changes.items[try changeIndex(&editor.git, "other.txt")].x);
    try fixtureCommand(base, &.{ "commit", "-qm", "fixture" });
    try text_file.atomicWrite(t.allocator, t.io, path, "staged\n");
    try fixtureCommand(base, &.{ "add", "--", name });
    try text_file.atomicWrite(t.allocator, t.io, path, "working\n");
    editor.git.requestRefresh();
    try settle(&editor);
    const mixed = editor.git.changes.items[try changeIndex(&editor.git, name)];
    try t.expect(mixed.x == 'M' and mixed.y == 'M');
    try fixtureCommand(base, &.{ "reset", "--hard", "HEAD" });
    try fixtureCommand(base, &.{ "mv", "--", name, "renamed é.txt" });
    editor.git.requestRefresh();
    try settle(&editor);
    const rename = try changeIndex(&editor.git, "renamed é.txt");
    try t.expectEqualStrings(name, editor.git.changes.items[rename].old_path.?);
    editor.git.stage(&editor, rename, false);
    try settle(&editor);
    editor.git.stage(&editor, try changeIndex(&editor.git, "renamed é.txt"), true);
    try settle(&editor);
    const index_files = try fixtureGit(base, &.{ "ls-files", "-z" });
    defer t.allocator.free(index_files);
    try t.expect(std.mem.indexOf(u8, index_files, name) != null);
    try t.expect(std.mem.indexOf(u8, index_files, "renamed é.txt") == null);
}
