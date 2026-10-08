//! Back/forward navigation history: the caret positions that jumps leave
//! behind. Jumping commands (go to definition, quick open, search results,
//! Problems, go to line, …) record where the caret was before moving it;
//! `navigate_back` returns there and `navigate_forward` re-jumps. An entry
//! names its document by id (untitled buffers work while they live) and by
//! path (a closed file is reopened); the editor resolves entries and drops
//! the ones it can no longer reach.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A caret position as the editor sees it; `path` is borrowed.
pub const Pos = struct {
    doc_id: u64,
    path: ?[]const u8,
    line: usize,
    col: usize,
};

/// A stored position; owns its path copy.
pub const Entry = struct {
    doc_id: u64,
    path: ?[]u8,
    line: usize,
    col: usize,

    pub fn deinit(self: *Entry, a: Allocator) void {
        if (self.path) |p| a.free(p);
        self.path = null;
    }

    /// Same document and line — close enough to count as "here".
    pub fn sameLine(self: Entry, pos: Pos) bool {
        return self.doc_id == pos.doc_id and self.line == pos.line;
    }
};

pub const Direction = enum {
    back,
    forward,

    fn opposite(self: Direction) Direction {
        return if (self == .back) .forward else .back;
    }
};

pub const History = struct {
    allocator: Allocator,
    back: std.ArrayList(Entry) = .empty,
    forward: std.ArrayList(Entry) = .empty,

    /// Oldest entries beyond this many are dropped from either stack.
    pub const capacity: usize = 100;

    pub fn init(a: Allocator) History {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *History) void {
        self.clear(&self.back);
        self.clear(&self.forward);
        self.back.deinit(self.allocator);
        self.forward.deinit(self.allocator);
    }

    /// Remember the position a jump is about to leave. A point on the line
    /// of the newest entry replaces it, so repeated jumps from one spot don't
    /// pile up; like a browser, a new jump forgets the forward stack.
    pub fn record(self: *History, pos: Pos) !void {
        self.clear(&self.forward);
        try self.push(&self.back, pos);
    }

    /// Pop the newest entry of `dir`'s stack that is not on `current`'s
    /// line (those are "here" already and are discarded). The caller owns
    /// the result.
    pub fn take(self: *History, dir: Direction, current: Pos) ?Entry {
        const list = self.stack(dir);
        while (list.pop()) |popped| {
            var e = popped;
            if (e.sameLine(current)) {
                e.deinit(self.allocator);
                continue;
            }
            return e;
        }
        return null;
    }

    /// After a successful move in `dir`, keep the position it came from on
    /// the opposite stack so the other direction can return to it.
    pub fn leave(self: *History, dir: Direction, from: Pos) !void {
        try self.push(self.stack(dir.opposite()), from);
    }

    pub fn len(self: *const History, dir: Direction) usize {
        return if (dir == .back) self.back.items.len else self.forward.items.len;
    }

    fn stack(self: *History, dir: Direction) *std.ArrayList(Entry) {
        return if (dir == .back) &self.back else &self.forward;
    }

    fn push(self: *History, list: *std.ArrayList(Entry), pos: Pos) !void {
        if (list.items.len > 0) {
            const top = &list.items[list.items.len - 1];
            if (top.sameLine(pos)) {
                top.col = pos.col;
                return;
            }
        }
        const path = if (pos.path) |p| try self.allocator.dupe(u8, p) else null;
        errdefer if (path) |p| self.allocator.free(p);
        try list.append(self.allocator, .{ .doc_id = pos.doc_id, .path = path, .line = pos.line, .col = pos.col });
        if (list.items.len > capacity) {
            var oldest = list.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
    }

    fn clear(self: *History, list: *std.ArrayList(Entry)) void {
        for (list.items) |*e| e.deinit(self.allocator);
        list.clearRetainingCapacity();
    }
};

const testing = std.testing;

fn at(id: u64, line: usize) Pos {
    return .{ .doc_id = id, .path = null, .line = line, .col = 0 };
}

test "nav history: back pops the newest point that is not the current line" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.record(.{ .doc_id = 1, .path = "a.zig", .line = 4, .col = 2 });
    try h.record(at(2, 9));
    // Already on document 2 line 9: that entry is "here" and is skipped.
    var e = h.take(.back, at(2, 9)).?;
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), e.doc_id);
    try testing.expectEqualStrings("a.zig", e.path.?);
    try testing.expectEqual(@as(usize, 2), e.col);
    try testing.expect(h.take(.back, at(1, 4)) == null);
}

test "nav history: same-line points collapse, a new jump forgets forward, capacity trims the oldest" {
    var h = History.init(testing.allocator);
    defer h.deinit();
    try h.record(.{ .doc_id = 1, .path = null, .line = 3, .col = 1 });
    try h.record(.{ .doc_id = 1, .path = null, .line = 3, .col = 7 });
    try testing.expectEqual(@as(usize, 1), h.len(.back));
    try testing.expectEqual(@as(usize, 7), h.back.items[0].col);
    try h.leave(.back, at(5, 0));
    try testing.expectEqual(@as(usize, 1), h.len(.forward));
    try h.record(at(6, 0));
    try testing.expectEqual(@as(usize, 0), h.len(.forward));
    var i: usize = 0;
    while (i < History.capacity + 10) : (i += 1) try h.record(at(7, 100 + i));
    try testing.expectEqual(History.capacity, h.len(.back));
    try testing.expectEqual(@as(usize, 110), h.back.items[0].line);
}
