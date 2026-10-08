//! Names the workspace walkers (quick-open finder, workspace search) prune:
//! the built-in `zig-out` plus plain names from the workspace root's
//! `.gitignore`. Callers skip dot-entries themselves.
//!
//! Parsing is deliberately minimal: only `name`, `name/`, `/name` and
//! `/name/` lines count. Comments, globs (`*`, `?`, `[`), escapes (`\`),
//! path patterns (`src/gen/`) and nested `.gitignore` files are ignored.
//! A trailing `/` means "directories only" in git; here the name prunes
//! files too. A leading `/` anchors the name to the workspace root;
//! otherwise it matches at any depth. A negation of the same shapes
//! (`!name`, `!/name`) drops that name from both lists, so git's
//! `logs` + `!/logs` no longer hides the root `logs/` (nested `logs/`
//! directories then show as well: pruning too little only costs time,
//! pruning too much hides files git shows). Later lines win, as in git.

const std = @import("std");

pub const WalkIgnore = struct {
    /// Names skipped at any depth.
    anywhere: std.ArrayList([]u8) = .empty,
    /// Names skipped only directly under the workspace root (`/name`).
    root_only: std.ArrayList([]u8) = .empty,

    /// Never fails: a missing or unreadable `.gitignore` yields the built-ins.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) WalkIgnore {
        const text = root.readFileAlloc(io, ".gitignore", allocator, .limited(64 * 1024)) catch return .{};
        defer allocator.free(text);
        return parse(allocator, text);
    }

    fn parse(allocator: std.mem.Allocator, text: []const u8) WalkIgnore {
        var self: WalkIgnore = .{};
        const body = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            var name = std.mem.trim(u8, line, " \t\r");
            if (name.len == 0 or name[0] == '#') continue;
            const negated = name[0] == '!';
            if (negated) name = name[1..];
            if (name.len == 0 or std.mem.findAny(u8, name, "*?[\\") != null) continue;
            const anchored = name[0] == '/';
            if (anchored) name = name[1..];
            if (std.mem.endsWith(u8, name, "/")) name = name[0 .. name.len - 1];
            if (name.len == 0 or std.mem.findScalar(u8, name, '/') != null) continue;
            if (negated) {
                remove(allocator, &self.anywhere, name);
                remove(allocator, &self.root_only, name);
                continue;
            }
            const owned = allocator.dupe(u8, name) catch continue;
            const list = if (anchored) &self.root_only else &self.anywhere;
            list.append(allocator, owned) catch allocator.free(owned);
        }
        return self;
    }

    pub fn deinit(self: *WalkIgnore, allocator: std.mem.Allocator) void {
        for (self.anywhere.items) |name| allocator.free(name);
        self.anywhere.deinit(allocator);
        for (self.root_only.items) |name| allocator.free(name);
        self.root_only.deinit(allocator);
        self.* = undefined;
    }

    /// `name` is a single directory-entry name; `at_root` is true while
    /// walking the workspace root itself.
    pub fn skips(self: *const WalkIgnore, name: []const u8, at_root: bool) bool {
        if (std.mem.eql(u8, name, "zig-out")) return true;
        if (at_root and contains(self.root_only.items, name)) return true;
        return contains(self.anywhere.items, name);
    }
};

fn contains(names: []const []u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Drop every stored copy of `name` (a name can be listed twice).
fn remove(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), name: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i], name)) {
            allocator.free(list.orderedRemove(i));
        } else i += 1;
    }
}

test "plain names skip at any depth, /names only at the root" {
    const a = std.testing.allocator;
    var ig = WalkIgnore.parse(a, "zig-pkg/\n/build\nreferences\n");
    defer ig.deinit(a);
    try std.testing.expect(ig.skips("zig-pkg", true) and ig.skips("zig-pkg", false));
    try std.testing.expect(ig.skips("references", false));
    try std.testing.expect(ig.skips("build", true) and !ig.skips("build", false));
    try std.testing.expect(!ig.skips("src", true));
}

test "comments, blanks, negations, globs and path patterns are ignored" {
    const a = std.testing.allocator;
    var ig = WalkIgnore.parse(a, "# comment\n\n  \n!keep\n!\n!/\n*.o\nbuild_?.txt\n[ab]\nsrc/gen/\n/a/b\n/\n");
    defer ig.deinit(a);
    try std.testing.expectEqual(0, ig.anywhere.items.len + ig.root_only.items.len);
}

test "a later !name or !/name re-includes a stored plain name" {
    const a = std.testing.allocator;
    const t = std.testing;
    // `logs` then `!/logs`: git shows the root logs/, so the walkers must too.
    var ig = WalkIgnore.parse(a, "logs\n!/logs\n/build\n!build/\ntmp/\ntmp\n!tmp\nkeep\n!*.log\n!src/keep\n");
    defer ig.deinit(a);
    try t.expect(!ig.skips("logs", true));
    try t.expect(!ig.skips("build", true));
    try t.expect(!ig.skips("tmp", true) and !ig.skips("tmp", false));
    try t.expect(ig.skips("keep", true) and ig.skips("keep", false));
    // A later plain line wins again.
    var again = WalkIgnore.parse(a, "logs\n!logs\n/logs\n");
    defer again.deinit(a);
    try t.expect(again.skips("logs", true) and !again.skips("logs", false));
}

test "CRLF and BOM input; built-in zig-out when .gitignore is empty or missing" {
    const a = std.testing.allocator;
    var ig = WalkIgnore.parse(a, "\xEF\xBB\xBFzig-pkg/\r\n/build \r\n");
    defer ig.deinit(a);
    try std.testing.expect(ig.skips("zig-pkg", false) and ig.skips("build", true));
    var empty = WalkIgnore.parse(a, "");
    defer empty.deinit(a);
    try std.testing.expect(empty.skips("zig-out", true) and empty.skips("zig-out", false));
    try std.testing.expect(!empty.skips("src", true));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var missing = WalkIgnore.load(a, std.testing.io, tmp.dir);
    defer missing.deinit(a);
    try std.testing.expect(missing.skips("zig-out", false) and !missing.skips("src", true));
}
