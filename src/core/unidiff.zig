//! Parser for git's unified diff output as the review reader consumes it:
//! `git diff -U999999 … -- <file>` yields one hunk holding the whole file,
//! every line prefixed ' ' (unchanged), '-' (removed) or '+' (added). The
//! parsed lines are slices into the diff bytes, which the caller keeps alive.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { context, removed, added };
pub const Line = struct { kind: Kind, text: []const u8 };

pub const Parsed = struct {
    lines: []Line,
    /// git said `Binary files … differ`: there is nothing to read.
    binary: bool = false,
    old_count: u32 = 0,
    new_count: u32 = 0,
    /// The new file does not end with a newline (`\ No newline at end of
    /// file` followed an unchanged or added line).
    new_missing_newline: bool = false,

    pub fn deinit(self: *Parsed, a: Allocator) void {
        a.free(self.lines);
        self.lines = &.{};
    }
};

const header_prefixes = [_][]const u8{
    "diff ",            "index ",              "old mode",    "new mode",  "deleted file mode", "new file mode",
    "similarity index", "dissimilarity index", "rename from", "rename to", "copy from",         "copy to",
    "--- ",             "+++ ",
};

fn isHeader(line: []const u8) bool {
    for (header_prefixes) |prefix| if (std.mem.startsWith(u8, line, prefix)) return true;
    return false;
}

/// Parse one file's diff. Several hunks are accepted and concatenated;
/// anything that is neither a header, a hunk line nor git's binary notice
/// is `error.UnexpectedDiffOutput`.
pub fn parse(a: Allocator, stdout: []const u8) !Parsed {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(a);
    var result: Parsed = .{ .lines = &.{} };
    var in_hunk = false;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (!in_hunk) {
            if (std.mem.startsWith(u8, line, "@@")) {
                in_hunk = true;
                continue;
            }
            if (std.mem.startsWith(u8, line, "Binary files ")) {
                result.binary = true;
                continue;
            }
            if (line.len == 0 or isHeader(line)) continue;
            return error.UnexpectedDiffOutput;
        }
        // Inside a hunk an empty token is only the split's tail after the
        // final newline; git prefixes every real line, an empty one included.
        if (line.len == 0) continue;
        switch (line[0]) {
            ' ' => {
                try lines.append(a, .{ .kind = .context, .text = line[1..] });
                result.old_count += 1;
                result.new_count += 1;
            },
            '-' => {
                try lines.append(a, .{ .kind = .removed, .text = line[1..] });
                result.old_count += 1;
            },
            '+' => {
                try lines.append(a, .{ .kind = .added, .text = line[1..] });
                result.new_count += 1;
            },
            '\\' => {
                // "\ No newline at end of file" qualifies the previous line.
                if (lines.items.len > 0 and lines.items[lines.items.len - 1].kind != .removed) result.new_missing_newline = true;
            },
            '@' => {}, // another hunk header: its lines follow
            else => return error.UnexpectedDiffOutput,
        }
    }
    result.lines = try lines.toOwnedSlice(a);
    return result;
}

test "a replace, headers and the missing-newline marker" {
    const t = std.testing;
    const diff =
        "diff --git a/x.zig b/x.zig\n" ++
        "index 90cf3b3..adc34a8 100644\n" ++
        "--- a/x.zig\n" ++
        "+++ b/x.zig\n" ++
        "@@ -1,3 +1,3 @@\n" ++
        " const a = 1;\n" ++
        "-const b = 2;\n" ++
        "+const b = 3;\n" ++
        " const c = 4;\n" ++
        "\\ No newline at end of file\n";
    var parsed = try parse(t.allocator, diff);
    defer parsed.deinit(t.allocator);
    try t.expect(!parsed.binary);
    try t.expectEqual(@as(usize, 4), parsed.lines.len);
    try t.expectEqual(Kind.context, parsed.lines[0].kind);
    try t.expectEqualStrings("const a = 1;", parsed.lines[0].text);
    try t.expectEqual(Kind.removed, parsed.lines[1].kind);
    try t.expectEqualStrings("const b = 2;", parsed.lines[1].text);
    try t.expectEqual(Kind.added, parsed.lines[2].kind);
    try t.expectEqualStrings("const b = 3;", parsed.lines[2].text);
    try t.expectEqual(@as(u32, 3), parsed.old_count);
    try t.expectEqual(@as(u32, 3), parsed.new_count);
    try t.expect(parsed.new_missing_newline);
}

test "an untracked file diffed against the null device, CRLF content, renames and binaries" {
    const t = std.testing;
    const untracked =
        "diff --git a/dev/null b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..ce01362\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,2 @@\n" ++
        "+hello\r\n" ++
        "+\r\n";
    var added = try parse(t.allocator, untracked);
    defer added.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), added.lines.len);
    try t.expectEqual(Kind.added, added.lines[0].kind);
    try t.expectEqualStrings("hello", added.lines[0].text);
    try t.expectEqualStrings("", added.lines[1].text);
    try t.expectEqual(@as(u32, 0), added.old_count);
    try t.expectEqual(@as(u32, 2), added.new_count);
    try t.expect(!added.new_missing_newline);

    const renamed =
        "diff --git a/old.zig b/new.zig\n" ++
        "similarity index 90%\n" ++
        "rename from old.zig\n" ++
        "rename to new.zig\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/old.zig\n" ++
        "+++ b/new.zig\n" ++
        "@@ -1,2 +1,2 @@\n" ++
        " keep\n" ++
        "-gone\n" ++
        "+here\n";
    var moved = try parse(t.allocator, renamed);
    defer moved.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), moved.lines.len);
    try t.expectEqual(Kind.removed, moved.lines[1].kind);

    var binary = try parse(t.allocator, "diff --git a/a.png b/a.png\nindex 1..2 100644\nBinary files a/a.png and b/a.png differ\n");
    defer binary.deinit(t.allocator);
    try t.expect(binary.binary);
    try t.expectEqual(@as(usize, 0), binary.lines.len);

    var deleted = try parse(t.allocator, "diff --git a/g.txt b/g.txt\ndeleted file mode 100644\n--- a/g.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-one\n-two\n\\ No newline at end of file\n");
    defer deleted.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), deleted.lines.len);
    try t.expectEqual(@as(u32, 0), deleted.new_count);
    try t.expect(!deleted.new_missing_newline); // the marker followed a removed line: the OLD file lacked it

    var empty = try parse(t.allocator, "");
    defer empty.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), empty.lines.len);
    try t.expectError(error.UnexpectedDiffOutput, parse(t.allocator, "fatal: bad revision 'HEAD'\n"));
}
