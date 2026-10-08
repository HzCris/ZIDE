//! A generic pick-list overlay: a title, a fuzzy filter the user types,
//! rows with a label and a dim detail, and a callback that receives the
//! chosen row's payload. Go-to-symbol uses it; Lua extensions will reuse it.
//! The editor owns one (`Editor.picker`) and shows it in `Mode.picker`;
//! the frontends draw it and route keys through the `Editor.picker*` calls.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text_input = @import("text_input.zig");
const Editor = @import("editor.zig").Editor;

pub const Item = struct { label: []u8, detail: []u8, payload: u64 };
pub const OnPick = *const fn (editor: *Editor, payload: u64) void;
pub const OnQuery = *const fn (editor: *Editor, query: []const u8) void;

pub const Picker = struct {
    allocator: Allocator,
    title_buf: [96]u8 = undefined,
    title_len: usize = 0,
    items: std.ArrayList(Item) = .empty,
    /// Indices into `items` that match the filter, best first.
    visible: std.ArrayList(u32) = .empty,
    filter_buf: [256]u8 = undefined,
    filter_len: usize = 0,
    selected: usize = 0,
    on_pick: ?OnPick = null,
    /// Called with the filter after each edit (workspace symbol search
    /// asks the server for the typed query).
    on_query: ?OnQuery = null,
    /// Shown in place of rows while there are no items at all.
    empty_hint: []const u8 = "",

    pub fn init(allocator: Allocator) Picker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Picker) void {
        self.clearItems();
        self.items.deinit(self.allocator);
        self.visible.deinit(self.allocator);
    }

    /// Start a new list: items and the filter are cleared.
    pub fn begin(self: *Picker, title_text: []const u8, on_pick: OnPick, on_query: ?OnQuery, empty_hint: []const u8) void {
        self.clearItems();
        self.title_len = @min(title_text.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], title_text[0..self.title_len]);
        self.filter_len = 0;
        self.selected = 0;
        self.on_pick = on_pick;
        self.on_query = on_query;
        self.empty_hint = empty_hint;
    }

    pub fn title(self: *const Picker) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn filter(self: *const Picker) []const u8 {
        return self.filter_buf[0..self.filter_len];
    }

    pub fn clearItems(self: *Picker) void {
        for (self.items.items) |item| {
            self.allocator.free(item.label);
            self.allocator.free(item.detail);
        }
        self.items.clearRetainingCapacity();
        self.visible.clearRetainingCapacity();
        self.selected = 0;
    }

    pub fn add(self: *Picker, label: []const u8, detail: []const u8, payload: u64) !void {
        const l = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(l);
        const d = try self.allocator.dupe(u8, detail);
        errdefer self.allocator.free(d);
        try self.items.append(self.allocator, .{ .label = l, .detail = d, .payload = payload });
    }

    /// Rebuild `visible` for the filter: labels starting with it rank
    /// first, then labels containing its characters in order (both
    /// case-insensitive); each group keeps the list's order.
    pub fn refilter(self: *Picker) void {
        self.visible.clearRetainingCapacity();
        const needle = self.filter();
        var pass: u8 = 0;
        while (pass < 2) : (pass += 1) {
            for (self.items.items, 0..) |item, i| {
                const prefix = std.ascii.startsWithIgnoreCase(item.label, needle);
                const hit = if (pass == 0) prefix else (!prefix and subsequenceIgnoreCase(item.label, needle));
                if (hit) self.visible.append(self.allocator, @intCast(i)) catch return;
            }
            if (needle.len == 0) break; // everything was a prefix match
        }
        if (self.selected >= self.visible.items.len) self.selected = 0;
    }

    pub fn count(self: *const Picker) usize {
        return self.visible.items.len;
    }

    pub fn itemAt(self: *const Picker, index: usize) *const Item {
        return &self.items.items[self.visible.items[index]];
    }

    pub fn selectedPayload(self: *const Picker) ?u64 {
        if (self.selected >= self.visible.items.len) return null;
        return self.itemAt(self.selected).payload;
    }

    pub fn move(self: *Picker, delta: isize) void {
        const n = self.visible.items.len;
        if (n == 0) {
            self.selected = 0;
            return;
        }
        if (delta < 0) {
            self.selected -|= @intCast(-delta);
        } else {
            self.selected = @min(n - 1, self.selected + @as(usize, @intCast(delta)));
        }
    }

    pub fn typeText(self: *Picker, text: []const u8) void {
        text_input.append(&self.filter_buf, &self.filter_len, text);
        self.selected = 0;
        self.refilter();
    }

    pub fn backspace(self: *Picker) void {
        if (self.filter_len == 0) return;
        text_input.backspace(&self.filter_buf, &self.filter_len);
        self.selected = 0;
        self.refilter();
    }

    /// The first row to draw so the selection fits in `rows` rows.
    pub fn firstVisible(self: *const Picker, rows: usize) usize {
        return (self.selected + 1) -| rows;
    }
};

fn subsequenceIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var hi: usize = 0;
    for (needle) |ch| {
        const c = std.ascii.toLower(ch);
        while (hi < haystack.len) : (hi += 1) {
            if (std.ascii.toLower(haystack[hi]) == c) {
                hi += 1;
                break;
            }
        } else return false;
    }
    return true;
}

fn noPick(_: *Editor, _: u64) void {}

test "picker: prefix matches rank before subsequence matches; selection stays in range" {
    const t = std.testing;
    var p = Picker.init(t.allocator);
    defer p.deinit();
    p.begin("Symbols", noPick, null, "");
    try p.add("main", "fn", 1);
    try p.add("Editor", "struct", 2);
    try p.add("newDocument", "fn", 3);
    try p.add("deinit", "fn", 4);
    p.refilter();
    try t.expectEqual(@as(usize, 4), p.count());
    p.typeText("de");
    try t.expectEqual(@as(usize, 2), p.count());
    try t.expectEqualStrings("deinit", p.itemAt(0).label);
    try t.expectEqualStrings("newDocument", p.itemAt(1).label);
    p.move(5);
    try t.expectEqual(@as(usize, 1), p.selected);
    try t.expectEqual(@as(?u64, 3), p.selectedPayload());
    p.typeText("x");
    try t.expectEqual(@as(usize, 0), p.count());
    try t.expectEqual(@as(?u64, null), p.selectedPayload());
    p.backspace();
    try t.expectEqual(@as(usize, 2), p.count());
    try t.expectEqualStrings("de", p.filter());
}
