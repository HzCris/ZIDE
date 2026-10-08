//! Bounded Myers line diff for the buffer-versus-index gutter.
const std = @import("std");
pub const Mark = enum(u2) { none, added, modified, deleted };
/// A line's content without its terminator, so "\r\n" and "\n" compare
/// equal: the index blob is LF while a core.autocrlf working copy (the
/// buffer) is CRLF. A lone '\r' (not before '\n') stays part of the text.
const Line = struct {
    text: []const u8,
    terminated: bool,

    fn eql(a: Line, b: Line) bool {
        return a.terminated == b.terminated and std.mem.eql(u8, a.text, b.text);
    }
};
fn lines(a: std.mem.Allocator, text: []const u8) ![]Line {
    var result: std.ArrayList(Line) = .empty;
    errdefer result.deinit(a);
    var start: usize = 0;
    for (text, 0..) |byte, i| if (byte == '\n') {
        const end = if (i > start and text[i - 1] == '\r') i - 1 else i;
        try result.append(a, .{ .text = text[start..end], .terminated = true });
        start = i + 1;
    };
    if (start < text.len) try result.append(a, .{ .text = text[start..], .terminated = false });
    return result.toOwnedSlice(a);
}

pub fn compare(a: std.mem.Allocator, before: []const u8, after: []const u8) ![]Mark {
    const old = try lines(a, before);
    defer a.free(old);
    const new = try lines(a, after);
    defer a.free(new);
    if (old.len + new.len > 200_000) return error.DiffTooLarge;
    const marks = try a.alloc(Mark, std.mem.count(u8, after, "\n") + 1);
    errdefer a.free(marks);
    @memset(marks, .none);
    var prefix: usize = 0;
    while (prefix < @min(old.len, new.len) and old[prefix].eql(new[prefix])) prefix += 1;
    var old_end = old.len;
    var new_end = new.len;
    while (old_end > prefix and new_end > prefix and old[old_end - 1].eql(new[new_end - 1])) {
        old_end -= 1;
        new_end -= 1;
    }
    const n: i32 = @intCast(old_end - prefix);
    const m: i32 = @intCast(new_end - prefix);
    if (n == 0) {
        @memset(marks[prefix..new_end], .added);
        return marks;
    }
    if (m == 0) {
        marks[@min(prefix, marks.len - 1)] = .deleted;
        return marks;
    }
    const max_d: usize = @intCast(n + m);
    const width = max_d * 2 + 3;
    const offset: i32 = @intCast(max_d + 1);
    const v = try a.alloc(i32, width);
    defer a.free(v);
    @memset(v, 0);
    var trace: std.ArrayList([]i32) = .empty;
    defer {
        for (trace.items) |row| a.free(row);
        trace.deinit(a);
    }
    var work: usize = 0;
    var distance: usize = 0;
    outer: for (0..max_d + 1) |d| {
        if ((trace.items.len + 1) * width > 4 * 1024 * 1024) return error.DiffTooComplex;
        const snapshot = try a.dupe(i32, v);
        trace.append(a, snapshot) catch |err| {
            a.free(snapshot);
            return err;
        };
        const signed: i32 = @intCast(d);
        var k = -signed;
        while (k <= signed) : (k += 2) {
            const idx: usize = @intCast(offset + k);
            var x = if (k == -signed or (k != signed and v[idx - 1] < v[idx + 1])) v[idx + 1] else v[idx - 1] + 1;
            var y = x - k;
            while (x < n and y < m and old[prefix + @as(usize, @intCast(x))].eql(new[prefix + @as(usize, @intCast(y))])) {
                x += 1;
                y += 1;
            }
            v[idx] = x;
            work += 1;
            if (work > 4_000_000) return error.DiffTooComplex;
            if (x >= n and y >= m) {
                distance = d;
                break :outer;
            }
        }
    }
    var x = n;
    var y = m;
    var d = distance;
    var deleted = false;
    var group_start: usize = new_end;
    var group_end: usize = new_end;
    while (d > 0) : (d -= 1) {
        const previous = trace.items[d];
        const k = x - y;
        const signed: i32 = @intCast(d);
        const idx: usize = @intCast(offset + k);
        const prev_k = if (k == -signed or (k != signed and previous[idx - 1] < previous[idx + 1])) k + 1 else k - 1;
        const prev_x = previous[@intCast(offset + prev_k)];
        const prev_y = prev_x - prev_k;
        if (x > prev_x and y > prev_y) {
            finishGroup(marks, group_start, group_end, deleted);
            deleted = false;
            while (x > prev_x and y > prev_y) {
                x -= 1;
                y -= 1;
            }
            group_start = prefix + @as(usize, @intCast(y));
            group_end = group_start;
        }
        if (x == prev_x) {
            y -= 1;
            group_start = prefix + @as(usize, @intCast(y));
            marks[group_start] = .added;
        } else {
            x -= 1;
            deleted = true;
        }
    }
    finishGroup(marks, group_start, group_end, deleted);
    return marks;
}
fn finishGroup(marks: []Mark, start: usize, end: usize, deleted: bool) void {
    if (!deleted) return;
    if (start < end) @memset(marks[start..end], .modified) else marks[@min(start, marks.len - 1)] = .deleted;
}

test "gutter diff distinguishes insertions deletions replacements and distant changes" {
    const t = std.testing;
    const marks = try compare(t.allocator, "first\nold\nmiddle\nlast\n", "first\nnew\nmiddle\nadded\nlast\n");
    defer t.allocator.free(marks);
    try t.expectEqualSlices(Mark, &.{ .none, .modified, .none, .added, .none, .none }, marks);
    const deleted = try compare(t.allocator, "a\nb\n", "a\n");
    defer t.allocator.free(deleted);
    try t.expectEqualSlices(Mark, &.{ .none, .deleted }, deleted);
    const empty = try compare(t.allocator, "", "x");
    defer t.allocator.free(empty);
    try t.expectEqualSlices(Mark, &.{.added}, empty);
}

test "gutter diff ignores CRLF against an LF index blob (core.autocrlf)" {
    const t = std.testing;
    const same = try compare(t.allocator, "a\nb\nc\n", "a\r\nb\r\nc\r\n");
    defer t.allocator.free(same);
    try t.expectEqualSlices(Mark, &.{ .none, .none, .none, .none }, same);
    const mixed = try compare(t.allocator, "a\r\nb\n", "a\nb\r\n");
    defer t.allocator.free(mixed);
    try t.expectEqualSlices(Mark, &.{ .none, .none, .none }, mixed);
    // Real edits still show, in CRLF documents too.
    const edited = try compare(t.allocator, "a\nb\nc\n", "a\r\nX\r\nc\r\nd\r\n");
    defer t.allocator.free(edited);
    try t.expectEqualSlices(Mark, &.{ .none, .modified, .none, .added, .none }, edited);
    // A lone '\r' and a missing final newline are content changes.
    const cr = try compare(t.allocator, "a\nb", "a\r\nb\r");
    defer t.allocator.free(cr);
    try t.expectEqualSlices(Mark, &.{ .none, .modified }, cr);
    const eof = try compare(t.allocator, "a\nb\n", "a\r\nb");
    defer t.allocator.free(eof);
    try t.expectEqualSlices(Mark, &.{ .none, .modified }, eof);
    // Large CRLF files no longer hit DiffTooComplex (every line differed).
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(t.allocator);
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(t.allocator);
    for (0..800) |i| {
        try before.print(t.allocator, "line {d}\n", .{i});
        try after.print(t.allocator, "line {d}\r\n", .{i});
    }
    const big = try compare(t.allocator, before.items, after.items);
    defer t.allocator.free(big);
    for (big) |mark| try t.expectEqual(Mark.none, mark);
}
