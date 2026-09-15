const std = @import("std");
const text_file = @import("text_file.zig");

pub const Mode = enum { auto, hardware, software };
pub const labels = [_][]const u8{ "Automatic", "Hardware accelerated", "Software" };
const Preference = struct { version: u32 = 1, mode: Mode };

pub fn parse(value: []const u8) !Mode {
    return std.meta.stringToEnum(Mode, value) orelse error.InvalidRenderer;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?Mode {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Preference, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value.version != 1) return error.UnsupportedRendererPreference;
    return parsed.value.mode;
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, path: []const u8, mode: Mode) !void {
    const bytes = try std.fmt.allocPrint(allocator, "{{\"version\":1,\"mode\":\"{s}\"}}\n", .{@tagName(mode)});
    defer allocator.free(bytes);
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try text_file.atomicWrite(allocator, io, path, bytes);
}

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = @import("lua_settings.zig").getConfigDir() orelse return error.NoConfigPath;
    return std.fs.path.join(allocator, &.{ dir, "renderer.json" });
}

test "renderer preference is explicit, persistent, and validated" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "renderer.json" });
    defer t.allocator.free(path);
    try t.expectEqual(@as(?Mode, null), try load(t.allocator, t.io, path));
    for ([_]Mode{ .auto, .hardware, .software }) |mode| {
        try save(t.allocator, t.io, path, mode);
        try t.expectEqual(mode, (try load(t.allocator, t.io, path)).?);
    }
    try text_file.atomicWrite(t.allocator, t.io, path, "{\"version\":2,\"mode\":\"auto\"}");
    try t.expectError(error.UnsupportedRendererPreference, load(t.allocator, t.io, path));
    try t.expectError(error.InvalidRenderer, parse("invalid"));
}
