//! The user's own snippets file, `extensions/my-snippets.lua`. The Snippets
//! panel's "Save as snippet" writes one marked block per snippet into it,
//! and Edit / Delete rewrite or remove that block, leaving everything else
//! in the file byte for byte: the user may add their own Lua around the
//! blocks or edit a block by hand. Pure text functions plus two I/O
//! helpers; no Lua, no Editor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const snippets = @import("snippets.zig");
const text_file = @import("text_file.zig");
const lua_settings = @import("lua_settings.zig");

pub const file_name = "my-snippets.lua";
/// A block starts with this plus the snippet's command name, on a line of
/// its own.
pub const marker_prefix = "-- zide:snippet ";
pub const end_marker = "-- zide:end";
/// Files bigger than this are not read (runLuaFile's cap).
pub const max_file_bytes = 16 * 1024 * 1024;

/// Written once, when the file is created; never rewritten.
pub const header =
    \\-- ZIDE: my snippets — written by the Snippets panel.
    \\--
    \\-- "Save Selection as Snippet" (Ctrl+Alt+S) adds a block below; Edit and
    \\-- Delete in the panel rewrite or remove it. Each block sits between a
    \\-- `-- zide:snippet <command>` line and the next `-- zide:end` line, and
    \\-- the panel touches nothing outside those two lines: add your own Lua
    \\-- above or below them, or edit a block by hand and run reload_extensions
    \\-- (Ctrl+P). Keep the two marker lines as they are, or the panel can no
    \\-- longer find the block (it offers to open this file instead).
    \\--
    \\-- In a body, ${1:text} is a blank with a default, $0 is where the caret
    \\-- ends up, and a leading tab is one indentation level in the document's
    \\-- own style — see docs/Documentation.md, Snippets.
    \\--
    \\-- This file loads after the other extension files, so a snippet here
    \\-- replaces a bundled one with the same language and name.
    \\
;

/// A block's byte range: from its start marker to just past its end
/// marker's line break (or the end of the text).
pub const Block = struct { start: usize, end: usize };
pub const FindError = error{ Duplicate, Unterminated };

/// Whether `def` was registered by this file.
pub fn isMine(def: *const snippets.Definition) bool {
    return std.mem.eql(u8, def.source, file_name);
}

/// The block registered under `command`, or null when the text has none.
/// A second block for the same command is `Duplicate`; a start marker
/// with no end marker before the next block or the end is `Unterminated`.
pub fn findBlock(text: []const u8, command: []const u8) FindError!?Block {
    var found: ?Block = null;
    var pos: usize = 0;
    while (pos < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const next = if (line_end < text.len) line_end + 1 else text.len;
        if (markerCommand(text[pos..line_end])) |name| {
            if (std.mem.eql(u8, name, command)) {
                if (found != null) return error.Duplicate;
                const end = blockEnd(text, next) orelse return error.Unterminated;
                found = .{ .start = pos, .end = end };
                pos = end;
                continue;
            }
        }
        pos = next;
    }
    return found;
}

/// The command a start-marker line names, or null for any other line.
/// Markers count only at the start of a line (after blanks), so one
/// quoted in the middle of a line never matches.
fn markerCommand(raw_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (!std.mem.startsWith(u8, line, marker_prefix)) return null;
    const name = std.mem.trim(u8, line[marker_prefix.len..], " \t");
    return if (name.len > 0) name else null;
}

fn isEndMarker(raw_line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, raw_line, " \t\r"), end_marker);
}

/// From `from` (the line after a start marker): the offset just past the
/// end marker's line, or null when another block starts or the text ends
/// first.
fn blockEnd(text: []const u8, from: usize) ?usize {
    var pos = from;
    while (pos < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const next = if (line_end < text.len) line_end + 1 else text.len;
        const line = text[pos..line_end];
        if (isEndMarker(line)) return next;
        if (markerCommand(line) != null) return null;
        pos = next;
    }
    return null;
}

/// Whether any line of `body` would read as a marker line.
fn hasMarkerLine(body: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (isEndMarker(line) or markerCommand(line) != null) return true;
    }
    return false;
}

/// The smallest long-bracket level 0..=16 whose closer (`]`, that many
/// `=`, `]`) the body neither contains nor completes at its end, or null
/// when no level is free. A body ending in `]` and that many `=` would
/// close the string one character early, with the closer's own first `]`
/// (`list[i]` at level 0 reads `[[list[i]]]`).
pub fn bracketLevel(body: []const u8) ?u8 {
    var level: u8 = 0;
    while (level <= 16) : (level += 1) {
        var buf: [18]u8 = undefined;
        const closer = bracket(&buf, level, ']');
        if (std.mem.indexOf(u8, body, closer) != null) continue;
        if (std.mem.endsWith(u8, body, closer[0 .. closer.len - 1])) continue;
        return level;
    }
    return null;
}

/// `[==[` or `]==]` at `level`.
fn bracket(buf: *[18]u8, level: u8, edge: u8) []const u8 {
    buf[0] = edge;
    @memset(buf[1 .. 1 + @as(usize, level)], '=');
    buf[1 + @as(usize, level)] = edge;
    return buf[0 .. @as(usize, level) + 2];
}

fn appendQuoted(a: Allocator, out: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    const buf = try a.alloc(u8, 2 + 4 * s.len);
    defer a.free(buf);
    // The buffer holds the longest possible escaping (`\ddd` per byte).
    try out.appendSlice(a, lua_settings.quoteLuaString(buf, s) orelse unreachable);
}

fn appendField(a: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) error{OutOfMemory}!void {
    try out.appendSlice(a, "    ");
    try out.appendSlice(a, key);
    try out.appendSlice(a, " = ");
    try appendQuoted(a, out, value);
    try out.appendSlice(a, ",\n");
}

/// One block for `command`, trailing line break included: the marker
/// lines around a `zide.register_snippet({...})` call whose body is a Lua
/// long string (a newline right after the opener, which Lua drops).
/// `MarkerInBody` when a body line is itself a marker line — the scanner
/// is line-based and must never see one inside a block.
pub fn renderBlock(a: Allocator, command: []const u8, spec: snippets.Spec) error{ OutOfMemory, MarkerInBody }![]u8 {
    if (hasMarkerLine(spec.body)) return error.MarkerInBody;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, marker_prefix);
    try out.appendSlice(a, command);
    try out.appendSlice(a, "\nzide.register_snippet({\n");
    try appendField(a, &out, "language", spec.language);
    try appendField(a, &out, "description", spec.description);
    try appendField(a, &out, "group", spec.group);
    try appendField(a, &out, "prefix", spec.prefix);
    try appendField(a, &out, "notes", spec.notes);
    try out.appendSlice(a, "    body = ");
    if (bracketLevel(spec.body)) |level| {
        var buf: [18]u8 = undefined;
        try out.appendSlice(a, bracket(&buf, level, '['));
        try out.append(a, '\n');
        try out.appendSlice(a, spec.body);
        try out.appendSlice(a, bracket(&buf, level, ']'));
    } else {
        try appendQuoted(a, &out, spec.body);
    }
    try out.appendSlice(a, ",\n})\n");
    try out.appendSlice(a, end_marker);
    try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

/// `text` with the block for `lookup_command` replaced by `block`, or with
/// `block` appended after a blank line when there is none (an empty text
/// gets the header first).
pub fn upsert(a: Allocator, text: []const u8, lookup_command: []const u8, block: []const u8) (FindError || error{OutOfMemory})![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (try findBlock(text, lookup_command)) |b| {
        try out.appendSlice(a, text[0..b.start]);
        try out.appendSlice(a, block);
        try out.appendSlice(a, text[b.end..]);
        return out.toOwnedSlice(a);
    }
    if (text.len == 0) {
        try out.appendSlice(a, header);
        try out.append(a, '\n');
    } else {
        try out.appendSlice(a, text);
        if (text[text.len - 1] != '\n') try out.append(a, '\n');
        if (!std.mem.endsWith(u8, out.items, "\n\n")) try out.append(a, '\n');
    }
    try out.appendSlice(a, block);
    return out.toOwnedSlice(a);
}

pub const Removal = struct { text: []u8, removed: usize };

/// `text` without every block registered under `command` (a doubled block
/// goes too), one blank line at most where each stood.
pub fn remove(a: Allocator, text: []const u8, command: []const u8) error{OutOfMemory}!Removal {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var removed: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const next = if (line_end < text.len) line_end + 1 else text.len;
        if (markerCommand(text[pos..line_end])) |name| {
            if (std.mem.eql(u8, name, command)) {
                if (blockEnd(text, next)) |end| {
                    removed += 1;
                    pos = end;
                    // The blank line before the block already separates
                    // what surrounded it: skip the ones after it.
                    if (std.mem.endsWith(u8, out.items, "\n\n")) {
                        while (pos < text.len and text[pos] == '\n') pos += 1;
                    }
                    continue;
                }
            }
        }
        try out.appendSlice(a, text[pos..next]);
        pos = next;
    }
    // A removed last block leaves no trailing blank line behind.
    while (std.mem.endsWith(u8, out.items, "\n\n")) _ = out.pop();
    return .{ .text = try out.toOwnedSlice(a), .removed = removed };
}

/// The file's text, or "" when it does not exist yet.
pub fn read(a: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => try a.dupe(u8, ""),
        else => err,
    };
}

/// Write the whole file atomically (temp file, then replace), creating the
/// extensions folder when needed.
pub fn write(a: Allocator, io: std.Io, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try text_file.atomicWrite(a, io, path, text);
}

// ---- Tests ----

const t = std.testing;

fn testSpec(body: []const u8) snippets.Spec {
    return .{ .language = "zig", .description = "For each item", .group = "Mine", .notes = "Runs the body once per item.", .body = body };
}

test "my-snippets.lua: a new file is the header plus one block, and a second block follows a blank line" {
    const block = try renderBlock(t.allocator, "snippet.zig.~for-each-item", testSpec("for (items) |item| {\n    $0\n}"));
    defer t.allocator.free(block);
    try t.expectEqualStrings(
        \\-- zide:snippet snippet.zig.~for-each-item
        \\zide.register_snippet({
        \\    language = "zig",
        \\    description = "For each item",
        \\    group = "Mine",
        \\    prefix = "",
        \\    notes = "Runs the body once per item.",
        \\    body = [[
        \\for (items) |item| {
        \\    $0
        \\}]],
        \\})
        \\-- zide:end
        \\
    , block);
    const file = try upsert(t.allocator, "", "snippet.zig.~for-each-item", block);
    defer t.allocator.free(file);
    try t.expect(std.mem.startsWith(u8, file, header));
    try t.expect(std.mem.endsWith(u8, file, block));
    try t.expect(std.mem.indexOf(u8, file, "\n\n-- zide:snippet") != null);
    // Found again by its marker, spanning exactly the block.
    const b = (try findBlock(file, "snippet.zig.~for-each-item")).?;
    try t.expectEqualStrings(block, file[b.start..b.end]);
    try t.expect((try findBlock(file, "snippet.zig.~other")) == null);
    // A second snippet lands after one blank line.
    const block2 = try renderBlock(t.allocator, "snippet.zig.~print", testSpec("print($0)"));
    defer t.allocator.free(block2);
    const file2 = try upsert(t.allocator, file, "snippet.zig.~print", block2);
    defer t.allocator.free(file2);
    try t.expectEqualStrings(file2[0..file.len], file);
    try t.expectEqualStrings("\n", file2[file.len .. file.len + 1]);
    try t.expectEqualStrings(block2, file2[file.len + 1 ..]);
}

test "my-snippets.lua: the long bracket level avoids the body's closers, and falls back to a quoted string" {
    try t.expectEqual(@as(?u8, 0), bracketLevel("a[b[i]]"[0..0]));
    try t.expectEqual(@as(?u8, 1), bracketLevel("a[b[i]]"));
    try t.expectEqual(@as(?u8, 2), bracketLevel("x ]] y ]=] z"));
    const block = try renderBlock(t.allocator, "snippet.zig.~index", testSpec("a[b[i]]"));
    defer t.allocator.free(block);
    try t.expect(std.mem.indexOf(u8, block, "body = [=[\na[b[i]]]=],") != null);
    // A body ending in `]` (and that level's `=`s) would close the string
    // one character early there: the next free level is taken.
    try t.expectEqual(@as(?u8, 1), bracketLevel("list[i]"));
    try t.expectEqual(@as(?u8, 1), bracketLevel("]"));
    try t.expectEqual(@as(?u8, 0), bracketLevel("x ]="));
    try t.expectEqual(@as(?u8, 2), bracketLevel("x ]] y ]="));
    const ends = try renderBlock(t.allocator, "snippet.zig.~index", testSpec("#[derive(Debug)]"));
    defer t.allocator.free(ends);
    try t.expect(std.mem.indexOf(u8, ends, "body = [=[\n#[derive(Debug)]]=],") != null);
    // Every level taken: a plain quoted string instead.
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(t.allocator);
    var level: u8 = 0;
    while (level <= 16) : (level += 1) {
        var buf: [18]u8 = undefined;
        try all.appendSlice(t.allocator, bracket(&buf, level, ']'));
        try all.append(t.allocator, ' ');
    }
    try t.expect(bracketLevel(all.items) == null);
    const quoted = try renderBlock(t.allocator, "snippet.zig.~closers", testSpec(all.items));
    defer t.allocator.free(quoted);
    try t.expect(std.mem.indexOf(u8, quoted, "body = \"]] ]=] ") != null);
    // Special characters in the one-line fields are escaped.
    const tricky = try renderBlock(t.allocator, "snippet.zig.~q", .{ .language = "zig", .description = "Say \"hi\"\\", .group = "Mine", .notes = "line one\nline two", .body = "x" });
    defer t.allocator.free(tricky);
    try t.expect(std.mem.indexOf(u8, tricky, "description = \"Say \\\"hi\\\"\\\\\",") != null);
    try t.expect(std.mem.indexOf(u8, tricky, "notes = \"line one\\nline two\",") != null);
}

test "my-snippets.lua: upsert replaces a block in place and keeps everything else byte for byte" {
    const before =
        \\-- my own comment
        \\zide.set("tab_width", 4)
        \\
        \\-- zide:snippet snippet.zig.~a
        \\zide.register_snippet({ language = "zig", description = "A", body = "old" })
        \\-- zide:end
        \\
        \\local keep = true
        \\
        \\-- zide:snippet snippet.zig.~b
        \\zide.register_snippet({ language = "zig", description = "B", body = "b" })
        \\-- zide:end
        \\
    ;
    const block = try renderBlock(t.allocator, "snippet.zig.~a", testSpec("new"));
    defer t.allocator.free(block);
    const after = try upsert(t.allocator, before, "snippet.zig.~a", block);
    defer t.allocator.free(after);
    const a_start = std.mem.indexOf(u8, before, "-- zide:snippet snippet.zig.~a").?;
    const a_end = std.mem.indexOf(u8, before, "local keep").? - 1;
    try t.expectEqualStrings(before[0..a_start], after[0..a_start]);
    try t.expectEqualStrings(block, after[a_start .. a_start + block.len]);
    try t.expectEqualStrings(before[a_end..], after[a_start + block.len ..]);
    // Indented markers and CRLF line ends still match; the block includes
    // the whole end-marker line.
    const crlf = "  -- zide:snippet snippet.zig.~c \r\nzide.register_snippet({})\r\n  -- zide:end\r\nrest\r\n";
    const c = (try findBlock(crlf, "snippet.zig.~c")).?;
    try t.expectEqual(@as(usize, 0), c.start);
    try t.expectEqualStrings("rest\r\n", crlf[c.end..]);
}

test "my-snippets.lua: remove drops every block of a command and leaves one blank line" {
    const text =
        \\-- head
        \\
        \\-- zide:snippet snippet.zig.~a
        \\zide.register_snippet({})
        \\-- zide:end
        \\
        \\-- zide:snippet snippet.zig.~b
        \\zide.register_snippet({})
        \\-- zide:end
        \\
        \\-- zide:snippet snippet.zig.~a
        \\zide.register_snippet({})
        \\-- zide:end
        \\
    ;
    const r = try remove(t.allocator, text, "snippet.zig.~a");
    defer t.allocator.free(r.text);
    try t.expectEqual(@as(usize, 2), r.removed);
    try t.expectEqualStrings(
        \\-- head
        \\
        \\-- zide:snippet snippet.zig.~b
        \\zide.register_snippet({})
        \\-- zide:end
        \\
    , r.text);
    const none = try remove(t.allocator, r.text, "snippet.zig.~a");
    defer t.allocator.free(none.text);
    try t.expectEqual(@as(usize, 0), none.removed);
    try t.expectEqualStrings(r.text, none.text);
}

test "my-snippets.lua: a missing end marker is Unterminated, a doubled block is Duplicate, a marker inside a body is refused" {
    const unterminated = "-- zide:snippet snippet.zig.~a\nzide.register_snippet({})\n\n-- zide:snippet snippet.zig.~b\n-- zide:end\n";
    try t.expectError(error.Unterminated, findBlock(unterminated, "snippet.zig.~a"));
    try t.expect((try findBlock(unterminated, "snippet.zig.~b")) != null);
    const doubled = "-- zide:snippet snippet.zig.~a\n-- zide:end\n-- zide:snippet snippet.zig.~a\n-- zide:end\n";
    try t.expectError(error.Duplicate, findBlock(doubled, "snippet.zig.~a"));
    try t.expectError(error.MarkerInBody, renderBlock(t.allocator, "snippet.zig.~a", testSpec("x\n-- zide:end\ny")));
    try t.expectError(error.MarkerInBody, renderBlock(t.allocator, "snippet.zig.~a", testSpec("  -- zide:snippet snippet.zig.~b")));
    // A marker mentioned mid-line is just text.
    const ok = try renderBlock(t.allocator, "snippet.zig.~a", testSpec("see -- zide:end here"));
    defer t.allocator.free(ok);
}

test "my-snippets.lua: read gives an empty text for a missing file and write creates the folder" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "extensions", file_name });
    defer t.allocator.free(path);
    const missing = try read(t.allocator, t.io, path);
    defer t.allocator.free(missing);
    try t.expectEqualStrings("", missing);
    try write(t.allocator, t.io, path, "-- hello\n");
    const back = try read(t.allocator, t.io, path);
    defer t.allocator.free(back);
    try t.expectEqualStrings("-- hello\n", back);
}
