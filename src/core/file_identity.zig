//! File identity is distinct from the path used for display and saving.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub fn absolute(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    return std.fs.path.resolve(allocator, &.{ root, path });
}

/// Resolve existing aliases, including the parent of a not-yet-created file.
/// Do not use this key as the save path: saving through a symlink must retain it.
pub fn key(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const full = try absolute(allocator, io, path);
    defer allocator.free(full);
    return resolve(allocator, io, full);
}

fn resolve(allocator: Allocator, io: std.Io, full: []const u8) ![]u8 {
    const found = std.Io.Dir.cwd().realPathFileAlloc(io, full, allocator) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => blk: {
            const parent = std.fs.path.dirname(full) orelse break :blk try allocator.dupe(u8, full);
            if (parent.len == full.len) break :blk try allocator.dupe(u8, full);
            const resolved_parent = try resolve(allocator, io, parent);
            defer allocator.free(resolved_parent);
            break :blk try std.fs.path.join(allocator, &.{ resolved_parent, std.fs.path.basename(full) });
        },
        else => err,
    };
    defer allocator.free(found);
    return allocator.dupe(u8, found);
}

pub fn equalKeys(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const x = if (builtin.os.tag == .windows and ac == '/') '\\' else ac;
        const y = if (builtin.os.tag == .windows and bc == '/') '\\' else bc;
        if (builtin.os.tag == .windows) {
            if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
        } else if (x != y) return false;
    }
    return true;
}

pub fn same(allocator: Allocator, io: std.Io, a: []const u8, b: []const u8) !bool {
    if (equalKeys(a, b)) return true;
    const ka = try key(allocator, io, a);
    defer allocator.free(ka);
    const kb = try key(allocator, io, b);
    defer allocator.free(kb);
    return equalKeys(ka, kb);
}

test "existing and missing file aliases share an identity" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const a = try std.fs.path.join(t.allocator, &.{ root, "missing.txt" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, ".", "missing.txt" });
    defer t.allocator.free(b);
    try t.expect(try same(t.allocator, t.io, a, b));
}

test "POSIX identities preserve case and literal backslashes while resolving symlink parents" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "real", .default_dir);
    try tmp.dir.symLink(t.io, "real", "alias", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const real = try std.fs.path.join(t.allocator, &.{ root, "real", "source" });
    defer t.allocator.free(real);
    const alias = try std.fs.path.join(t.allocator, &.{ root, "alias", "source" });
    defer t.allocator.free(alias);
    try t.expect(try same(t.allocator, t.io, real, alias)); // Missing file through a symlink parent.
    const file = try tmp.dir.createFile(t.io, "real/source", .{});
    file.close(t.io);
    try t.expect(try same(t.allocator, t.io, real, alias));
    try t.expect(!equalKeys("/project/source", "/project/Source"));
    try t.expect(!equalKeys("/project/a/b", "/project/a\\b"));
}
