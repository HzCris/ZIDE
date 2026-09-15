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
pub const Store = struct {
    sources: std.ArrayList(Source) = .empty,
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
        if (self.sources.items.len >= 256) return error.TooManyBreakpointSources;
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
        if (file.points.items.len >= 1024) return error.TooManyBreakpoints;
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
    pub fn configure(self: *Store, a: Allocator, io: std.Io, base: []const u8, workspace: []const u8) !void {
        const key = try identity.key(a, io, workspace);
        errdefer a.free(key);
        if (self.workspace) |current| if (identity.equalKeys(current, key)) {
            a.free(key);
            return;
        };
        if (@import("builtin").os.tag == .windows) for (key) |*byte| {
            byte.* = if (byte.* == '\\') '/' else std.ascii.toLower(byte.*);
        };
        const name = try std.fmt.allocPrint(a, "{x:0>16}.json", .{std.hash.Wyhash.hash(0, key)});
        defer a.free(name);
        const path = try std.fs.path.join(a, &.{ base, "debug", name });
        errdefer a.free(path);
        var loaded: Store = .{};
        errdefer loaded.deinit(a);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (bytes) |text| {
            defer a.free(text);
            const Saved = struct { schema: u32, sources: []const struct { path: []const u8, lines: []const u32 } };
            const parsed = try std.json.parseFromSlice(Saved, a, text, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (parsed.value.schema != 1 or parsed.value.sources.len > 256) return error.UnsupportedBreakpointFile;
            for (parsed.value.sources) |file| {
                if (!std.fs.path.isAbsolute(file.path) or file.lines.len > 1024) return error.InvalidBreakpointFile;
                const index = try loaded.ensureSource(a, io, file.path);
                for (file.lines) |line| {
                    if (line == 0) return error.InvalidBreakpointLine;
                    var duplicate = false;
                    for (loaded.sources.items[index].points.items) |point| if (point.line == line) {
                        duplicate = true;
                        break;
                    };
                    if (!duplicate) try loaded.sources.items[index].points.append(a, .{ .line = line });
                }
            }
        }
        self.deinit(a);
        self.* = loaded;
        self.storage = path;
        self.workspace = key;
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
            try bytes.appendSlice(a, "{\"path\":");
            try @import("lsp.zig").writeJsonString(&bytes, a, file.path);
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
    try first.configure(t.allocator, t.io, base, base);
    const index = try first.toggle(t.allocator, t.io, path, 7);
    first.sources.items[index].points.items[0].adapter_id = 900;
    first.sources.items[index].points.items[0].verified = true;
    try first.save(t.allocator, t.io);
    var second: Store = .{};
    defer second.deinit(t.allocator);
    try second.configure(t.allocator, t.io, base, base);
    try t.expectEqual(@as(u32, 7), second.sources.items[0].points.items[0].line);
    try t.expect(second.sources.items[0].points.items[0].adapter_id == null);
    try t.expect(!second.sources.items[0].points.items[0].verified);
}
