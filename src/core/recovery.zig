//! Dirty-buffer snapshots. Instance locks prevent stealing recovery from a live editor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const Cursor = @import("cursor.zig").Cursor;
const text_file = @import("text_file.zig");
const identity = @import("file_identity.zig");
const second = std.time.ns_per_s;
const max_text = 32 * 1024 * 1024;

pub const Snapshot = struct {
    schema: u32 = 1,
    document_id: u64,
    version: u64,
    path: ?[]const u8,
    identity: ?[]const u8,
    format: text_file.TextFormat,
    disk_stamp: ?text_file.Stamp,
    external_changed: bool,
    cursors: []const Cursor,
    scroll_top: usize,
    scroll_left: usize,
    text: []const u8,
};

pub const Candidate = struct {
    path: []u8,
    parsed: std.json.Parsed(Snapshot),
    restored: bool = false,
    pub fn name(self: Candidate) []const u8 {
        return self.parsed.value.path orelse "untitled";
    }
    fn deinit(self: Candidate, allocator: Allocator) void {
        allocator.free(self.path);
        self.parsed.deinit();
    }
};

const Write = struct {
    allocator: Allocator,
    io: std.Io,
    path: []u8,
    bytes: []u8,
    version: u64,
    future: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    mutex: std.Io.Mutex = .init,
    wake: ?*const fn () void,

    fn run(self: *Write) void {
        text_file.atomicWrite(self.allocator, self.io, self.path, self.bytes) catch |err| {
            self.failure = err;
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.done.store(true, .release);
        if (self.wake) |wake| wake();
    }
    fn deinit(self: *Write, cancel: bool) void {
        if (self.future) |*future| {
            if (cancel) future.cancel(self.io) else future.await(self.io);
        }
        self.allocator.free(self.path);
        self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }
};

const Track = struct {
    observed: u64,
    captured: ?u64 = null,
    changed_at: i128,
    first_change: i128,
    retry_at: i128 = 0,
    pending: ?*Write = null,
};

pub const Manager = struct {
    allocator: Allocator,
    io: std.Io,
    root: []u8,
    instance: []u8,
    lock: std.Io.File,
    claims: std.ArrayList(std.Io.File) = .empty,
    candidates: std.ArrayList(Candidate) = .empty,
    tracks: std.AutoHashMapUnmanaged(u64, Track) = .empty,
    wake: ?*const fn () void = null,
    next_deadline: ?i128 = null,
    failure: ?anyerror = null,
    discarded: bool = false,

    /// Tests pass an isolated base; normal startup supplies the config directory.
    pub fn init(allocator: Allocator, io: std.Io, base: []const u8, workspace: []const u8) !Manager {
        const workspace_key = try identity.key(allocator, io, workspace);
        defer allocator.free(workspace_key);
        // Match the same workspace key used for Windows path aliases.
        if (@import("builtin").os.tag == .windows) for (workspace_key) |*byte| {
            byte.* = if (byte.* == '\\') '/' else std.ascii.toLower(byte.*);
        };
        var hash_buf: [16]u8 = undefined;
        const hash = try std.fmt.bufPrint(&hash_buf, "{x:0>16}", .{std.hash.Wyhash.hash(0, workspace_key)});
        const root = try std.fs.path.join(allocator, &.{ base, "recovery", hash });
        errdefer allocator.free(root);
        var random: [16]u8 = undefined;
        std.Io.random(io, &random);
        const instance_name = std.fmt.bytesToHex(random, .lower);
        const instance = try std.fs.path.join(allocator, &.{ root, &instance_name });
        errdefer allocator.free(instance);
        try std.Io.Dir.cwd().createDirPath(io, instance);
        const lock_path = try std.fs.path.join(allocator, &.{ instance, "lock" });
        defer allocator.free(lock_path);
        const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .exclusive = true });
        errdefer lock.close(io);
        if (!try lock.tryLock(io, .exclusive)) return error.InstanceLocked;
        var self: Manager = .{ .allocator = allocator, .io = io, .root = root, .instance = instance, .lock = lock };
        self.scan() catch |err| {
            self.failure = err;
        };
        return self;
    }

    pub fn deinit(self: *Manager) void {
        var tracks = self.tracks.valueIterator();
        while (tracks.next()) |track| if (track.pending) |pending| pending.deinit(false);
        self.tracks.deinit(self.allocator);
        for (self.candidates.items) |candidate| candidate.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        for (self.claims.items) |file| file.close(self.io);
        self.claims.deinit(self.allocator);
        self.lock.close(self.io);
        self.allocator.free(self.instance);
        self.allocator.free(self.root);
    }

    pub fn setWake(self: *Manager, wake: ?*const fn () void) void {
        self.wake = wake;
        var tracks = self.tracks.valueIterator();
        while (tracks.next()) |track| if (track.pending) |pending| {
            pending.mutex.lockUncancelable(self.io);
            pending.wake = wake;
            pending.mutex.unlock(self.io);
        };
    }

    fn scan(self: *Manager) !void {
        var root_dir = try std.Io.Dir.cwd().openDir(self.io, self.root, .{ .iterate = true });
        defer root_dir.close(self.io);
        var instances = root_dir.iterate();
        while (try instances.next(self.io)) |entry| {
            if (entry.kind != .directory or entry.name.len != 32 or !hexName(entry.name)) continue;
            if (std.mem.eql(u8, entry.name, std.fs.path.basename(self.instance))) continue;
            var dir = try root_dir.openDir(self.io, entry.name, .{ .iterate = true });
            defer dir.close(self.io);
            const lock = dir.openFile(self.io, "lock", .{ .mode = .read_write }) catch |err| {
                self.failure = err;
                continue;
            };
            const claimed = lock.tryLock(self.io, .exclusive) catch |err| {
                lock.close(self.io);
                self.failure = err;
                continue;
            };
            if (!claimed) {
                lock.close(self.io);
                continue;
            }
            self.claims.append(self.allocator, lock) catch |err| {
                lock.close(self.io);
                return err;
            };
            var files = dir.iterate();
            while (try files.next(self.io)) |file| {
                if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".json")) continue;
                self.readCandidate(dir, entry.name, file.name) catch |err| {
                    // Keep damaged snapshots for inspection instead of deleting them.
                    self.failure = err;
                };
            }
        }
    }

    fn readCandidate(self: *Manager, dir: std.Io.Dir, instance_name: []const u8, file_name: []const u8) !void {
        if (self.candidates.items.len >= 4096) return error.TooManySnapshots;
        const bytes = try dir.readFileAlloc(self.io, file_name, self.allocator, .limited(max_text * 4));
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Snapshot, self.allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        errdefer parsed.deinit();
        const snapshot = parsed.value;
        if (snapshot.schema != 1 or snapshot.text.len > max_text or snapshot.cursors.len > 4096 or !std.unicode.utf8ValidateSlice(snapshot.text)) return error.InvalidSnapshot;
        if (snapshot.path) |path| if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSnapshot;
        const path = try std.fs.path.join(self.allocator, &.{ self.root, instance_name, file_name });
        errdefer self.allocator.free(path);
        try self.candidates.append(self.allocator, .{ .path = path, .parsed = parsed });
    }

    fn hexName(name: []const u8) bool {
        for (name) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }

    fn snapshotPath(self: *Manager, id: u64) ![]u8 {
        var buf: [32]u8 = undefined;
        return std.fs.path.join(self.allocator, &.{ self.instance, try std.fmt.bufPrint(&buf, "{d}.json", .{id}) });
    }

    fn serialize(self: *Manager, doc: *const Document) ![]u8 {
        if (doc.buffer.byteLen() > max_text or doc.cursors.cursors.items.len > 4096) return error.SnapshotTooLarge;
        const text = try doc.buffer.textAlloc(self.allocator);
        defer self.allocator.free(text);
        const path = if (doc.file_path) |p| try identity.absolute(self.allocator, self.io, p) else null;
        defer if (path) |p| self.allocator.free(p);
        const key = if (path) |p| try identity.key(self.allocator, self.io, p) else null;
        defer if (key) |p| self.allocator.free(p);
        return std.json.Stringify.valueAlloc(self.allocator, Snapshot{
            .document_id = doc.id,
            .version = doc.buffer.version,
            .path = path,
            .identity = key,
            .format = doc.format,
            .disk_stamp = doc.disk_stamp,
            .external_changed = doc.external_changed,
            .cursors = doc.cursors.cursors.items,
            .scroll_top = doc.scroll_top,
            .scroll_left = doc.scroll_left,
            .text = text,
        }, .{});
    }

    fn trackFor(self: *Manager, doc: *const Document, now: i128) !*Track {
        const entry = try self.tracks.getOrPut(self.allocator, doc.id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .observed = doc.buffer.version, .changed_at = now, .first_change = now };
        return entry.value_ptr;
    }

    fn startWrite(self: *Manager, doc: *const Document, track: *Track) !void {
        const path = try self.snapshotPath(doc.id);
        errdefer self.allocator.free(path);
        const bytes = try self.serialize(doc);
        errdefer self.allocator.free(bytes);
        const pending = try self.allocator.create(Write);
        errdefer self.allocator.destroy(pending);
        pending.* = .{ .allocator = self.allocator, .io = self.io, .path = path, .bytes = bytes, .version = doc.buffer.version, .wake = self.wake };
        pending.future = try self.io.concurrent(Write.run, .{pending});
        track.pending = pending;
    }

    pub fn tick(self: *Manager, docs: []const Document, now: i128, enabled: bool) void {
        self.next_deadline = null;
        if (self.discarded) return;
        for (docs) |*doc| {
            if (!doc.dirty) {
                self.forget(doc.id) catch |err| {
                    self.failure = err;
                };
                continue;
            }
            if (!enabled) continue;
            const track = self.trackFor(doc, now) catch |err| {
                self.failure = err;
                continue;
            };
            if (track.pending) |pending| if (pending.done.load(.acquire)) {
                if (pending.failure) |err| {
                    self.failure = err;
                    track.retry_at = now + 10 * second;
                } else {
                    track.captured = pending.version;
                    track.retry_at = 0;
                }
                pending.deinit(false);
                track.pending = null;
            };
            if (doc.buffer.version != track.observed) {
                if (track.captured == track.observed) track.first_change = now;
                track.observed = doc.buffer.version;
                track.changed_at = now;
            }
            if (track.captured == doc.buffer.version or track.pending != null) continue;
            var due = @max(track.retry_at, @min(track.changed_at + 2 * second, track.first_change + 10 * second));
            if (now >= due) {
                self.startWrite(doc, track) catch |err| {
                    self.failure = err;
                    track.retry_at = now + 10 * second;
                };
                due = track.retry_at;
            }
            if (track.pending == null) self.next_deadline = if (self.next_deadline) |next| @min(next, due) else due;
        }
    }

    /// Ensure the latest version exists before releasing a stale instance's copy.
    pub fn captureSync(self: *Manager, doc: *const Document) !void {
        const track = try self.trackFor(doc, 0);
        if (track.pending) |pending| {
            pending.deinit(false);
            track.pending = null;
        }
        const bytes = try self.serialize(doc);
        defer self.allocator.free(bytes);
        const path = try self.snapshotPath(doc.id);
        defer self.allocator.free(path);
        try text_file.atomicWrite(self.allocator, self.io, path, bytes);
        track.captured = doc.buffer.version;
        track.observed = doc.buffer.version;
    }

    pub fn forget(self: *Manager, id: u64) !void {
        const track = self.tracks.getPtr(id) orelse return;
        if (track.pending) |pending| {
            pending.deinit(true);
            track.pending = null;
        }
        const path = try self.snapshotPath(id);
        defer self.allocator.free(path);
        try deleteSnapshot(self.io, path);
        _ = self.tracks.remove(id);
    }

    pub fn removeCandidate(self: *Manager, index: usize) !void {
        try deleteSnapshot(self.io, self.candidates.items[index].path);
        const candidate = self.candidates.orderedRemove(index);
        candidate.deinit(self.allocator);
    }

    pub fn flush(self: *Manager, docs: []const Document, enabled: bool) void {
        if (self.discarded) return;
        for (docs) |*doc| {
            if (doc.dirty) {
                if (enabled) self.captureSync(doc) catch |err| {
                    self.failure = err;
                };
            } else self.forget(doc.id) catch |err| {
                self.failure = err;
            };
        }
    }

    pub fn discard(self: *Manager, docs: []const Document) void {
        for (docs) |doc| self.forget(doc.id) catch |err| {
            self.failure = err;
        };
        self.discarded = true;
    }
};

fn deleteSnapshot(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Build a replacement before touching a live document. The caller resolves ownership.
pub fn restore(allocator: Allocator, io: std.Io, snapshot: Snapshot, keep_path: bool) !Document {
    var doc = try Document.init(allocator);
    errdefer doc.deinit();
    try doc.loadText(snapshot.text);
    if (keep_path) if (snapshot.path) |path| {
        try doc.setFilePath(path);
        doc.disk_stamp = snapshot.disk_stamp;
        doc.disk_mtime = if (snapshot.disk_stamp) |stamp| stamp.mtime else null;
        const current = text_file.Stamp.read(io, path) catch null;
        doc.external_changed = snapshot.external_changed or !std.meta.eql(current, snapshot.disk_stamp);
    };
    doc.format = snapshot.format;
    try doc.cursors.cursors.ensureTotalCapacity(allocator, @max(1, snapshot.cursors.len));
    if (snapshot.cursors.len > 0) {
        doc.cursors.cursors.clearRetainingCapacity();
        for (snapshot.cursors) |cursor| {
            var clamped = cursor;
            clamped.offset = @import("cursor.zig").floorBoundary(&doc.buffer, cursor.offset);
            if (cursor.anchor) |anchor| clamped.anchor = @import("cursor.zig").floorBoundary(&doc.buffer, anchor);
            doc.cursors.cursors.appendAssumeCapacity(clamped);
        }
    }
    doc.scroll_top = @min(snapshot.scroll_top, doc.buffer.lineCount() -| 1);
    doc.scroll_left = @min(snapshot.scroll_left, doc.buffer.byteLen());
    doc.dirty = true;
    doc.history.saved_revision = null;
    doc.lsp_version = 1;
    return doc;
}

test "recovery locks distinguish live instances and retain UTF-8, cursors and format" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.insertAtCursor("é😀 unsaved");
    doc.cursors.primary().offset = 3; // Deliberately stale, inside the emoji.
    doc.cursors.primary().anchor = 999;
    doc.format = .{ .encoding = .utf16_be, .bom = true };
    var live = try Manager.init(t.allocator, t.io, base, base);
    try live.captureSync(&doc);
    var other = try Manager.init(t.allocator, t.io, base, base);
    defer other.deinit();
    try t.expectEqual(@as(usize, 0), other.candidates.items.len);
    live.deinit();
    var next = try Manager.init(t.allocator, t.io, base, base);
    defer next.deinit();
    try t.expectEqual(@as(usize, 1), next.candidates.items.len);
    var recovered = try restore(t.allocator, t.io, next.candidates.items[0].parsed.value, true);
    defer recovered.deinit();
    try t.expectEqualStrings("é😀 unsaved", recovered.buffer.slice(0, recovered.buffer.byteLen()));
    try t.expect(recovered.dirty and recovered.history.saved_revision == null);
    try t.expectEqualDeep(doc.format, recovered.format);
    try t.expectEqual(@as(usize, 2), recovered.cursors.primary().offset);
    try t.expectEqual(@as(?usize, recovered.buffer.byteLen()), recovered.cursors.primary().anchor);
    // A third reader cannot simultaneously offer the snapshots claimed by next.
    var third = try Manager.init(t.allocator, t.io, base, base);
    defer third.deinit();
    try t.expectEqual(@as(usize, 0), third.candidates.items.len);
}

test "recovery deadlines capture idle and continuous edits and forgetting joins writers" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    var manager = try Manager.init(t.allocator, t.io, base, base);
    defer manager.deinit();
    var docs = [_]Document{try Document.init(t.allocator)};
    defer docs[0].deinit();
    try docs[0].insertAtCursor("initial");
    manager.tick(&docs, 0, true);
    try t.expectEqual(@as(?i128, 2 * second), manager.next_deadline);
    for (1..10) |n| {
        try docs[0].insertAtCursor(".");
        manager.tick(&docs, @as(i128, n) * second, true);
        try t.expect(manager.tracks.get(docs[0].id).?.pending == null);
    }
    manager.tick(&docs, 10 * second, true);
    const pending = manager.tracks.get(docs[0].id).?.pending.?;
    pending.future.?.await(t.io);
    manager.tick(&docs, 10 * second, true);
    try t.expectEqual(@as(?u64, docs[0].buffer.version), manager.tracks.get(docs[0].id).?.captured);
    try docs[0].insertAtCursor("new");
    manager.tick(&docs, 11 * second, true);
    try t.expectEqual(@as(?i128, 13 * second), manager.next_deadline);
    manager.tick(&docs, 13 * second, true);
    try manager.forget(docs[0].id); // Cancels or joins the write before deleting.
    const path = try manager.snapshotPath(docs[0].id);
    defer t.allocator.free(path);
    try t.expectEqual(@as(?text_file.Stamp, null), try text_file.Stamp.read(t.io, path));
}

test "recovery preserves the previous snapshot after a failed capture and retains damaged files" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.insertAtCursor("keep me");
    var first = try Manager.init(t.allocator, t.io, base, base);
    try first.captureSync(&doc);
    const damaged = try std.fs.path.join(t.allocator, &.{ first.instance, "damaged.json" });
    defer t.allocator.free(damaged);
    try text_file.atomicWrite(t.allocator, t.io, damaged, "{broken");
    try doc.cursors.cursors.resize(t.allocator, 4097);
    for (doc.cursors.cursors.items) |*cursor| cursor.* = .{};
    try t.expectError(error.SnapshotTooLarge, first.captureSync(&doc));
    first.deinit();
    var next = try Manager.init(t.allocator, t.io, base, base);
    defer next.deinit();
    try t.expect(next.failure != null);
    try t.expectEqual(@as(usize, 1), next.candidates.items.len);
    try t.expectEqualStrings("keep me", next.candidates.items[0].parsed.value.text);
    try t.expect((try text_file.Stamp.read(t.io, damaged)) != null);
}

test "abrupt exit after multi-file rename recovers dirty named and untitled buffers without source writes" {
    if (!@hasDecl(@import("build_options"), "recovery_probe")) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const path = try std.fs.path.join(t.allocator, &.{ base, "café source.txt" });
    defer t.allocator.free(path);
    const partner = try std.fs.path.join(t.allocator, &.{ base, "partner.txt" });
    defer t.allocator.free(partner);
    const ready = try std.fs.path.join(t.allocator, &.{ base, "ready" });
    defer t.allocator.free(ready);
    try text_file.atomicWrite(t.allocator, t.io, path, "original disk text\n");
    try text_file.atomicWrite(t.allocator, t.io, partner, "original partner text\n");
    var child = try std.process.spawn(t.io, .{
        .argv = &.{ @import("build_options").recovery_probe, base, path, partner, ready },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
        .create_no_window = @import("builtin").os.tag == .windows,
    });
    defer child.kill(t.io);
    for (0..1000) |_| {
        if ((try text_file.Stamp.read(t.io, ready)) != null) break;
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    try t.expect((try text_file.Stamp.read(t.io, ready)) != null);
    {
        var other = try Manager.init(t.allocator, t.io, base, base);
        defer other.deinit();
        try t.expectEqual(@as(usize, 0), other.candidates.items.len);
    }
    child.kill(t.io); // Abrupt termination, with no child cleanup or final save.
    var next = try Manager.init(t.allocator, t.io, base, base);
    defer next.deinit();
    try t.expectEqual(@as(usize, 3), next.candidates.items.len);
    const source = try tmp.dir.readFileAlloc(t.io, "café source.txt", t.allocator, .limited(1024));
    defer t.allocator.free(source);
    try t.expectEqualStrings("original disk text\n", source);
    const partner_source = try tmp.dir.readFileAlloc(t.io, "partner.txt", t.allocator, .limited(1024));
    defer t.allocator.free(partner_source);
    try t.expectEqualStrings("original partner text\n", partner_source);
    try text_file.atomicWrite(t.allocator, t.io, path, "external disk change\n");
    var found_named = false;
    var found_partner = false;
    var found_untitled = false;
    for (next.candidates.items) |candidate| {
        var doc = try restore(t.allocator, t.io, candidate.parsed.value, true);
        defer doc.deinit();
        try t.expect(doc.dirty);
        if (doc.file_path) |doc_path| {
            if (try identity.same(t.allocator, t.io, path, doc_path)) {
                found_named = true;
                try t.expect(doc.external_changed);
                try t.expectEqualStrings("recovered café 😀\nrenamed disk text\n", doc.buffer.slice(0, doc.buffer.byteLen()));
            } else {
                found_partner = true;
                try t.expect(!doc.external_changed);
                try t.expectEqualStrings("second dirty\nrenamed partner text\n", doc.buffer.slice(0, doc.buffer.byteLen()));
            }
        } else {
            found_untitled = true;
            try t.expectEqualStrings("untitled recovery\n", doc.buffer.slice(0, doc.buffer.byteLen()));
        }
    }
    try t.expect(found_named and found_partner and found_untitled);
}
