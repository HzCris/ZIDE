//! Workspace source breakpoints; persisted requests are distinct from adapter verification.
const std = @import("std");
const identity = @import("file_identity.zig");
const Allocator = std.mem.Allocator;
pub const Point = struct {
    line: u32,
    verified: bool = false,
    actual_line: ?u32 = null,
    adapter_id: ?i64 = null,
    message: ?[]u8 = null,
    pub fn clear(self: *Point, a: Allocator) void {
        if (self.message) |m| a.free(m);
        self.* = .{ .line = self.line };
    }
};
pub const Source = struct {
    path: []u8,
    points: std.ArrayList(Point) = .empty,
    revision: u64 = 1,
    fn deinit(self: *Source, a: Allocator) void {
        a.free(self.path);
        for (self.points.items) |*point| point.clear(a);
        self.points.deinit(a);
    }
};
const max_sources = 256;
const max_points = 1024;
/// What `configure` found in a workspace's breakpoint file.
pub const Loaded = struct {
    name_buf: [32]u8 = undefined,
    name_len: usize = 0,
    /// Entries (sources or lines) that were invalid and were skipped.
    skipped: usize = 0,
    /// Why the file could not be used at all. It is then left untouched and
    /// the workspace's breakpoints are not saved (Store.storage is null).
    failure: ?anyerror = null,
    /// Basename of the workspace's breakpoint file (for messages).
    pub fn name(self: *const Loaded) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};
pub const Store = struct {
    sources: std.ArrayList(Source) = .empty,
    /// The breakpoint file saves go to; null when there is none (no workspace
    /// yet, or its file could not be loaded — see `configure`).
    storage: ?[]u8 = null,
    workspace: ?[]u8 = null,
    pub fn deinit(self: *Store, a: Allocator) void {
        for (self.sources.items) |*source| source.deinit(a);
        self.sources.deinit(a);
        if (self.storage) |path| a.free(path);
        if (self.workspace) |path| a.free(path);
    }
    pub fn ensureSource(self: *Store, a: Allocator, io: std.Io, path: []const u8) !usize {
        const key = try identity.key(a, io, path);
        errdefer a.free(key);
        for (self.sources.items, 0..) |item, index| if (identity.equalKeys(item.path, key)) {
            a.free(key);
            return index;
        };
        if (self.sources.items.len >= max_sources) return error.TooManyBreakpointSources;
        try self.sources.append(a, .{ .path = key });
        return self.sources.items.len - 1;
    }
    pub fn toggle(self: *Store, a: Allocator, io: std.Io, path: []const u8, line: u32) !usize {
        if (line == 0) return error.InvalidBreakpointLine;
        const index = try self.ensureSource(a, io, path);
        const file = &self.sources.items[index];
        for (file.points.items, 0..) |*point, i| if (point.line == line or point.actual_line == line) {
            point.clear(a);
            _ = file.points.orderedRemove(i);
            file.revision +%= 1;
            return index;
        };
        if (file.points.items.len >= max_points) return error.TooManyBreakpoints;
        try file.points.append(a, .{ .line = line });
        std.mem.sort(Point, file.points.items, {}, struct {
            fn less(_: void, x: Point, y: Point) bool {
                return x.line < y.line;
            }
        }.less);
        file.revision +%= 1;
        return index;
    }
    pub fn resetVerification(self: *Store, a: Allocator) void {
        for (self.sources.items) |*file| for (file.points.items) |*point| point.clear(a);
    }
    /// Switch to `workspace`'s breakpoint file under `base` (a no-op for the
    /// current workspace). A missing file is an empty list; invalid entries
    /// of a readable file are skipped and counted. A file that cannot be used
    /// at all (unreadable, not JSON, unknown schema) still switches the store
    /// to the workspace — callers report it once instead of retrying — with
    /// `storage` null, so toggles never overwrite that file or land in the
    /// previous workspace's. Only allocation and identity errors fail.
    pub fn configure(self: *Store, a: Allocator, io: std.Io, base: []const u8, workspace: []const u8) !Loaded {
        const key = try identity.key(a, io, workspace);
        errdefer a.free(key);
        var result: Loaded = .{};
        if (self.workspace) |current| if (identity.equalKeys(current, key)) {
            a.free(key);
            return result;
        };
        if (@import("builtin").os.tag == .windows) for (key) |*byte| {
            byte.* = if (byte.* == '\\') '/' else std.ascii.toLower(byte.*);
        };
        const name = std.fmt.bufPrint(&result.name_buf, "{x:0>16}.json", .{std.hash.Wyhash.hash(0, key)}) catch unreachable;
        result.name_len = name.len;
        const path = try std.fs.path.join(a, &.{ base, "debug", name });
        errdefer a.free(path);
        var loaded: Store = .{};
        errdefer loaded.deinit(a);
        readSaved(&loaded, a, io, path, &result.skipped) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                result.failure = err;
                loaded.deinit(a);
                loaded = .{};
            },
        };
        self.deinit(a);
        self.* = loaded;
        if (result.failure == null) self.storage = path else a.free(path);
        self.workspace = key;
        return result;
    }
    fn readSaved(self: *Store, a: Allocator, io: std.Io, path: []const u8, skipped: *usize) !void {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer a.free(text);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidBreakpointFile;
        const schema = parsed.value.object.get("schema") orelse return error.UnsupportedBreakpointFile;
        if (schema != .integer or schema.integer != 1) return error.UnsupportedBreakpointFile;
        const sources = parsed.value.object.get("sources") orelse return error.InvalidBreakpointFile;
        if (sources != .array) return error.InvalidBreakpointFile;
        for (sources.array.items) |entry| {
            const file = savedPath(a, entry) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    skipped.* += 1;
                    continue;
                },
            };
            defer a.free(file);
            const lines = entry.object.get("lines") orelse .null;
            if (lines != .array or !std.fs.path.isAbsolute(file)) {
                skipped.* += 1;
                continue;
            }
            const index = self.ensureSource(a, io, file) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    skipped.* += 1;
                    continue;
                },
            };
            const points = &self.sources.items[index].points;
            for (lines.array.items) |value| {
                const line: u32 = if (value == .integer) std.math.cast(u32, value.integer) orelse 0 else 0;
                if (line == 0 or points.items.len >= max_points) {
                    skipped.* += 1;
                    continue;
                }
                for (points.items) |point| {
                    if (point.line == line) break;
                } else try points.append(a, .{ .line = line });
            }
            std.mem.sort(Point, points.items, {}, struct {
                fn less(_: void, x: Point, y: Point) bool {
                    return x.line < y.line;
                }
            }.less);
        }
    }
    pub fn save(self: *Store, a: Allocator, io: std.Io) !void {
        const path = self.storage orelse return;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(a);
        try bytes.appendSlice(a, "{\"schema\":1,\"sources\":[");
        var count: usize = 0;
        for (self.sources.items) |file| {
            if (file.points.items.len == 0) continue;
            if (count > 0) try bytes.append(a, ',');
            count += 1;
            // JSON strings are Unicode, file names need not be (POSIX bytes,
            // Windows unpaired surrogates): such paths are saved as hex bytes.
            if (std.unicode.utf8ValidateSlice(file.path)) {
                try bytes.appendSlice(a, "{\"path\":");
                try @import("lsp.zig").writeJsonString(&bytes, a, file.path);
            } else try bytes.print(a, "{{\"path_hex\":\"{x}\"", .{file.path});
            try bytes.appendSlice(a, ",\"lines\":[");
            for (file.points.items, 0..) |point, i| {
                if (i > 0) try bytes.append(a, ',');
                try bytes.print(a, "{d}", .{point.line});
            }
            try bytes.appendSlice(a, "]}");
        }
        try bytes.appendSlice(a, "]}");
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        try @import("text_file.zig").atomicWrite(a, io, path, bytes.items);
    }
};
/// A saved source's path: `path` (UTF-8 text) or `path_hex` (the raw bytes).
fn savedPath(a: Allocator, entry: std.json.Value) ![]u8 {
    if (entry != .object) return error.InvalidBreakpointFile;
    if (entry.object.get("path")) |path| {
        if (path != .string) return error.InvalidBreakpointFile;
        return a.dupe(u8, path.string);
    }
    const hex = entry.object.get("path_hex") orelse return error.InvalidBreakpointFile;
    if (hex != .string or hex.string.len % 2 != 0) return error.InvalidBreakpointFile;
    const bytes = try a.alloc(u8, hex.string.len / 2);
    errdefer a.free(bytes);
    _ = std.fmt.hexToBytes(bytes, hex.string) catch return error.InvalidBreakpointFile;
    return bytes;
}

test "workspace breakpoints persist requested lines without transient adapter IDs" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const path = try std.fs.path.join(t.allocator, &.{ base, "café.zig" });
    defer t.allocator.free(path);
    var first: Store = .{};
    defer first.deinit(t.allocator);
    _ = try first.configure(t.allocator, t.io, base, base);
    const index = try first.toggle(t.allocator, t.io, path, 7);
    first.sources.items[index].points.items[0].adapter_id = 900;
    first.sources.items[index].points.items[0].verified = true;
    try first.save(t.allocator, t.io);
    var second: Store = .{};
    defer second.deinit(t.allocator);
    _ = try second.configure(t.allocator, t.io, base, base);
    try t.expectEqual(@as(u32, 7), second.sources.items[0].points.items[0].line);
    try t.expect(second.sources.items[0].points.items[0].adapter_id == null);
    try t.expect(!second.sources.items[0].points.items[0].verified);
}

test "breakpoint files: unusable files switch without storage, bad entries are skipped, non-UTF-8 names round-trip" {
    const t = std.testing;
    const text_file = @import("text_file.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    // The workspace's file name, before anything exists on disk.
    var probe: Store = .{};
    defer probe.deinit(t.allocator);
    const fresh = try probe.configure(t.allocator, t.io, base, base);
    try t.expect(fresh.failure == null and fresh.skipped == 0);
    const file = try t.allocator.dupe(u8, probe.storage.?);
    defer t.allocator.free(file);
    try t.expect(std.mem.endsWith(u8, file, fresh.name()));
    try std.Io.Dir.cwd().createDirPath(t.io, std.fs.path.dirname(file).?);

    // Unknown schema: the store switches (so callers report once instead of
    // retrying) but has no storage, and the file is never overwritten.
    const unsupported_text = "{\"schema\":2,\"sources\":[]}";
    try text_file.atomicWrite(t.allocator, t.io, file, unsupported_text);
    var bad: Store = .{};
    defer bad.deinit(t.allocator);
    const unsupported = try bad.configure(t.allocator, t.io, base, base);
    try t.expectEqual(@as(?anyerror, error.UnsupportedBreakpointFile), unsupported.failure);
    try t.expectEqualStrings(fresh.name(), unsupported.name());
    try t.expect(bad.storage == null and bad.workspace != null);
    try t.expect((try bad.configure(t.allocator, t.io, base, base)).failure == null);
    const toggled = try std.fs.path.join(t.allocator, &.{ base, "toggled.zig" });
    defer t.allocator.free(toggled);
    _ = try bad.toggle(t.allocator, t.io, toggled, 3);
    try bad.save(t.allocator, t.io);
    const untouched = try std.Io.Dir.cwd().readFileAlloc(t.io, file, t.allocator, .limited(4096));
    defer t.allocator.free(untouched);
    try t.expectEqualStrings(unsupported_text, untouched);

    // A readable file keeps its good entries and skips the bad ones.
    const good = try std.fs.path.join(t.allocator, &.{ base, "good.zig" });
    defer t.allocator.free(good);
    var mixed_text: std.ArrayList(u8) = .empty;
    defer mixed_text.deinit(t.allocator);
    try mixed_text.appendSlice(t.allocator, "{\"schema\":1,\"sources\":[{\"path\":\"relative.zig\",\"lines\":[1]},{\"lines\":[2]},{\"path\":");
    try @import("lsp.zig").writeJsonString(&mixed_text, t.allocator, good);
    try mixed_text.appendSlice(t.allocator, ",\"lines\":[0,4,\"x\",4,-1]}]}");
    try text_file.atomicWrite(t.allocator, t.io, file, mixed_text.items);
    var mixed: Store = .{};
    defer mixed.deinit(t.allocator);
    const partial = try mixed.configure(t.allocator, t.io, base, base);
    try t.expect(partial.failure == null and mixed.storage != null);
    try t.expectEqual(@as(usize, 5), partial.skipped); // relative, no path, 0, "x", -1
    try t.expectEqual(@as(usize, 1), mixed.sources.items.len);
    try t.expectEqual(@as(usize, 1), mixed.sources.items[0].points.items.len);
    try t.expectEqual(@as(u32, 4), mixed.sources.items[0].points.items[0].line);

    // A name that is not UTF-8 (an unpaired surrogate as WTF-8) is saved as
    // hex bytes, which std.json accepts, and reloads to the same path.
    const odd = try std.fs.path.join(t.allocator, &.{ base, "odd\xed\xa0\x80.zig" });
    defer t.allocator.free(odd);
    const odd_index = try mixed.toggle(t.allocator, t.io, odd, 9);
    const odd_key = try t.allocator.dupe(u8, mixed.sources.items[odd_index].path);
    defer t.allocator.free(odd_key);
    try mixed.save(t.allocator, t.io);
    var reloaded: Store = .{};
    defer reloaded.deinit(t.allocator);
    const back = try reloaded.configure(t.allocator, t.io, base, base);
    try t.expect(back.failure == null and back.skipped == 0);
    try t.expectEqual(@as(usize, 2), reloaded.sources.items.len);
    var found = false;
    for (reloaded.sources.items) |source| if (std.mem.eql(u8, source.path, odd_key)) {
        found = true;
        try t.expectEqual(@as(u32, 9), source.points.items[0].line);
    };
    try t.expect(found);
}
