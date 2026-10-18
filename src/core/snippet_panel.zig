//! The Snippets side panel's rows: the registry's definitions for one
//! document, filed in collapsible groups. Pure data — the Editor feeds it
//! the definitions and a View (see `Editor.syncSnippetPanel`), both
//! frontends draw `rows` and hand back the row the user activated. Rows
//! hold indices into the registry and are rebuilt whenever its revision
//! changes, so nothing here outlives a reload; the group names and
//! languages are borrowed from the definitions for the same reason.
const std = @import("std");
const Allocator = std.mem.Allocator;
const snippets = @import("snippets.zig");
const Definition = snippets.Definition;

pub const RowKind = enum { group, item };

pub const Row = struct {
    kind: RowKind,
    /// Index into `State.groups`.
    group: u16,
    /// Items: index into the registry's definitions. Unused (0) on groups.
    def: u32,
};

pub const Group = struct {
    /// Borrowed from the registry (valid until the next rebuild).
    language: []const u8,
    name: []const u8,
    count: u32,
    expanded: bool,
    /// Index of the group's header row.
    row: usize,
};

/// What the panel shows snippets for.
pub const View = struct {
    /// The registry revision the rows must reflect.
    revision: u64,
    /// The document's language name; null when it has none.
    language: ?[]const u8 = null,
    /// An untitled document with no language: every language the editor
    /// knows is offered, and inserting a snippet makes the document adopt
    /// its language.
    any_language: bool = false,
    /// How many languages the editor knows — a language registered later
    /// can make more snippets eligible in any-language mode.
    languages_known: usize = 0,
    /// Text every shown item must contain (ASCII case-insensitively) in
    /// its name, trigger or group; "" shows everything. While it is set,
    /// every group with a match is open and the rest are hidden.
    filter: []const u8 = "",
};

/// Longest language name the change detection compares in full.
const max_lang = 64;
/// Longest filter text (the Editor's buffer is this big).
pub const max_filter = 64;

/// What the rows were last built for; a change rebuilds them.
const Key = struct {
    revision: u64,
    any_language: bool,
    languages_known: usize,
    has_lang: bool,
    lang_len: u8,
    lang: [max_lang]u8,
    filter_len: u8,
    filter: [max_filter]u8,

    fn init(view: View) Key {
        var key: Key = .{ .revision = view.revision, .any_language = view.any_language, .languages_known = view.languages_known, .has_lang = view.language != null, .lang_len = 0, .lang = undefined, .filter_len = 0, .filter = undefined };
        if (view.language) |name| {
            const n = @min(name.len, max_lang);
            @memcpy(key.lang[0..n], name[0..n]);
            key.lang_len = @intCast(n);
        }
        const f = @min(view.filter.len, max_filter);
        @memcpy(key.filter[0..f], view.filter[0..f]);
        key.filter_len = @intCast(f);
        return key;
    }
    fn language(self: *const Key) ?[]const u8 {
        return if (self.has_lang) self.lang[0..self.lang_len] else null;
    }
    fn filterText(self: *const Key) []const u8 {
        return self.filter[0..self.filter_len];
    }
    fn sameLanguage(self: *const Key, other: *const Key) bool {
        if (self.has_lang != other.has_lang or self.any_language != other.any_language) return false;
        const mine = self.language() orelse return true;
        return std.ascii.eqlIgnoreCase(mine, other.language().?);
    }
    fn sameFilter(self: *const Key, other: *const Key) bool {
        return std.mem.eql(u8, self.filterText(), other.filterText());
    }
    fn eql(self: *const Key, other: *const Key) bool {
        return self.revision == other.revision and self.languages_known == other.languages_known and self.sameLanguage(other) and self.sameFilter(other);
    }
};

/// Whether `haystack` contains `needle`, ASCII letters compared without
/// case (std.ascii has no indexOfIgnoreCase).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

/// Whether the filter lets `def` through: its name, trigger or group
/// contains the text.
fn matchesFilter(def: *const Definition, filter: []const u8) bool {
    return filter.len == 0 or containsIgnoreCase(def.description, filter) or
        containsIgnoreCase(def.prefix, filter) or containsIgnoreCase(def.group, filter);
}

/// A toggled group, remembered by content (the registry's slices are
/// borrowed, so the set owns copies).
const ToggleKey = struct { language: []const u8, name: []const u8 };
const ToggleContext = struct {
    pub fn hash(_: ToggleContext, key: ToggleKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.language);
        h.update(&[_]u8{0x1f});
        h.update(key.name);
        return h.final();
    }
    pub fn eql(_: ToggleContext, a: ToggleKey, b: ToggleKey) bool {
        return std.mem.eql(u8, a.language, b.language) and std.mem.eql(u8, a.name, b.name);
    }
};

pub const State = struct {
    groups: std.ArrayList(Group) = .empty,
    rows: std.ArrayList(Row) = .empty,
    /// Groups the user toggled away from their default: the first group
    /// starts open, the rest closed. Owned keys.
    toggled: std.HashMapUnmanaged(ToggleKey, void, ToggleContext, std.hash_map.default_max_load_percentage) = .empty,
    selected: usize = 0,
    /// First visible row; the frontend that scrolls owns the clamping.
    scroll: usize = 0,
    /// Set by keyboard navigation; the frontend consumes it.
    scroll_to_selected: bool = false,
    key: ?Key = null,
    /// A toggle happened: rebuild on the next sync even when the key is the same.
    dirty: bool = false,

    pub fn deinit(self: *State, a: Allocator) void {
        self.groups.deinit(a);
        self.rows.deinit(a);
        var it = self.toggled.keyIterator();
        while (it.next()) |key| {
            a.free(key.language);
            a.free(key.name);
        }
        self.toggled.deinit(a);
    }

    /// Rebuild the rows when the view, the registry or a toggle changed.
    /// `languages.isKnown(name)` says whether the editor has a language
    /// definition by that name (any-language mode lists only those, since
    /// inserting one of their snippets must be able to set the language).
    /// A language change resets the selection; otherwise it is kept and
    /// clamped. Out of memory shows an empty panel.
    pub fn sync(self: *State, a: Allocator, defs: []const Definition, view: View, languages: anytype) void {
        const key = Key.init(view);
        const language_changed = if (self.key) |*old| !old.sameLanguage(&key) else true;
        const filter_changed = if (self.key) |*old| !old.sameFilter(&key) else false;
        if (!self.dirty and !language_changed and !filter_changed) if (self.key) |*old| if (old.eql(&key)) return;
        // The item selected before, to keep it selected through a filter
        // change when it is still shown.
        const kept: ?u32 = if (self.rowAt(self.selected)) |row| (if (row.kind == .item) row.def else null) else null;
        self.rebuild(a, defs, view, languages) catch {
            self.groups.clearRetainingCapacity();
            self.rows.clearRetainingCapacity();
        };
        self.key = key;
        self.dirty = false;
        if (language_changed) {
            self.selected = 0;
            self.scroll = 0;
        } else if (filter_changed) {
            // The same item when it is still there, else the first match:
            // Enter inserts it right away.
            self.selected = 0;
            for (self.rows.items, 0..) |row, i| {
                if (row.kind != .item) continue;
                if (kept != null and row.def == kept.?) {
                    self.selected = i;
                    break;
                }
                if (self.selected == 0) self.selected = i;
            }
            self.scroll = 0;
            self.scroll_to_selected = true;
        } else {
            self.selected = @min(self.selected, self.rows.items.len -| 1);
        }
    }

    fn included(def: *const Definition, view: View, languages: anytype) bool {
        if (!matchesFilter(def, view.filter)) return false;
        if (view.any_language) return std.mem.eql(u8, def.language, "*") or languages.isKnown(def.language);
        return def.matchesLanguage(view.language);
    }

    /// Whether a filter is narrowing the rows (every shown group is open).
    pub fn filterActive(self: *const State) bool {
        return if (self.key) |key| key.filter_len > 0 else false;
    }

    /// The filter the rows were built for (what the frontends draw).
    pub fn filterText(self: *const State) []const u8 {
        return if (self.key) |*key| key.filterText() else "";
    }

    fn findGroup(self: *const State, language: []const u8, name: []const u8) ?usize {
        for (self.groups.items, 0..) |group, i| {
            if (std.mem.eql(u8, group.language, language) and std.mem.eql(u8, group.name, name)) return i;
        }
        return null;
    }

    fn rebuild(self: *State, a: Allocator, defs: []const Definition, view: View, languages: anytype) !void {
        self.groups.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        // Groups in first-registration order, items in registration order.
        for (defs) |*def| {
            if (!included(def, view, languages)) continue;
            if (self.findGroup(def.language, def.group)) |gi| {
                self.groups.items[gi].count += 1;
            } else {
                if (self.groups.items.len == std.math.maxInt(u16)) continue;
                try self.groups.append(a, .{ .language = def.language, .name = def.group, .count = 1, .expanded = false, .row = 0 });
            }
        }
        for (self.groups.items, 0..) |*group, gi| {
            // A filter shows every match: its groups stay open (the
            // toggles are kept for when it clears).
            group.expanded = view.filter.len > 0 or ((gi == 0) != self.toggled.contains(.{ .language = group.language, .name = group.name }));
            group.row = self.rows.items.len;
            try self.rows.append(a, .{ .kind = .group, .group = @intCast(gi), .def = 0 });
            if (!group.expanded) continue;
            for (defs, 0..) |*def, di| {
                if (!included(def, view, languages)) continue;
                if (!std.mem.eql(u8, def.language, group.language) or !std.mem.eql(u8, def.group, group.name)) continue;
                try self.rows.append(a, .{ .kind = .item, .group = @intCast(gi), .def = @intCast(di) });
            }
        }
    }

    /// Open or close group `gi`; the selection lands on its header. Takes
    /// effect at the next sync (the Editor syncs right after).
    pub fn toggle(self: *State, a: Allocator, gi: usize) void {
        if (gi >= self.groups.items.len) return;
        // While a filter narrows the rows every group stays open.
        if (self.filterActive()) return;
        const group = self.groups.items[gi];
        if (self.toggled.fetchRemove(.{ .language = group.language, .name = group.name })) |kv| {
            a.free(kv.key.language);
            a.free(kv.key.name);
        } else {
            const language = a.dupe(u8, group.language) catch return;
            const name = a.dupe(u8, group.name) catch {
                a.free(language);
                return;
            };
            self.toggled.put(a, .{ .language = language, .name = name }, {}) catch {
                a.free(language);
                a.free(name);
                return;
            };
        }
        self.dirty = true;
        self.selected = group.row;
        self.scroll_to_selected = true;
    }

    pub fn rowAt(self: *const State, index: usize) ?Row {
        return if (index < self.rows.items.len) self.rows.items[index] else null;
    }

    pub fn move(self: *State, delta: isize) void {
        const total = self.rows.items.len;
        if (total == 0) {
            self.selected = 0;
            return;
        }
        const current: isize = @intCast(@min(self.selected, total - 1));
        self.selected = @intCast(std.math.clamp(current + delta, 0, @as(isize, @intCast(total - 1))));
        self.scroll_to_selected = true;
    }
    pub fn home(self: *State) void {
        self.selected = 0;
        self.scroll_to_selected = true;
    }
    pub fn end(self: *State) void {
        self.selected = self.rows.items.len -| 1;
        self.scroll_to_selected = true;
    }
    /// Left: close an open group, or jump from an item to its group.
    pub fn left(self: *State, a: Allocator) void {
        const row = self.rowAt(self.selected) orelse return;
        switch (row.kind) {
            .group => if (self.groups.items[row.group].expanded) self.toggle(a, row.group),
            .item => {
                self.selected = self.groups.items[row.group].row;
                self.scroll_to_selected = true;
            },
        }
    }
    /// Right: open a closed group, or step into an open one.
    pub fn right(self: *State, a: Allocator) void {
        const row = self.rowAt(self.selected) orelse return;
        if (row.kind != .group) return;
        if (self.groups.items[row.group].expanded) self.move(1) else self.toggle(a, row.group);
    }

    /// The definition the preview shows: the hovered row when it is an
    /// item, else the selected row when it is one.
    pub fn previewDef(self: *const State, hover: ?usize) ?u32 {
        if (hover) |h| if (self.rowAt(h)) |row| if (row.kind == .item) return row.def;
        if (self.rowAt(self.selected)) |row| if (row.kind == .item) return row.def;
        return null;
    }

    /// Whether the rows were built for an untitled document without a
    /// language (several languages' groups; each says whose).
    pub fn anyLanguage(self: *const State) bool {
        return if (self.key) |key| key.any_language else false;
    }

    /// What the header names: the language, or the mode.
    pub fn languageLabel(self: *const State) []const u8 {
        const key = &(self.key orelse return "");
        if (key.any_language) return "any language";
        return key.language() orelse "no language";
    }

    /// The message for a panel with no rows.
    pub fn emptyHint(self: *const State) []const u8 {
        const key = &(self.key orelse return "");
        if (key.filter_len > 0) return "No snippets match — Backspace edits the filter, Escape clears it";
        if (key.any_language) return "No snippets registered yet";
        if (key.language() == null) return "Only * snippets apply to a file without a language";
        return "No snippets for this language — see Documentation.md, Snippets";
    }
};

// ---- Tests ----

const AllKnown = struct {
    pub fn isKnown(_: AllKnown, _: []const u8) bool {
        return true;
    }
};
const Known = struct {
    names: []const []const u8,
    pub fn isKnown(self: Known, name: []const u8) bool {
        for (self.names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
        return false;
    }
};

fn testDefs(a: Allocator) ![]Definition {
    var list: std.ArrayList(Definition) = .empty;
    errdefer {
        for (list.items) |*d| d.deinit(a);
        list.deinit(a);
    }
    const specs = [_]snippets.Spec{
        .{ .language = "zig", .prefix = "fn", .description = "Function", .group = "Functions", .body = "fn" },
        .{ .language = "zig", .description = "Print", .group = "Start here", .body = "p" },
        .{ .language = "*", .description = "Date", .group = "Any", .body = "d" },
        .{ .language = "zig", .description = "Main", .group = "Start here", .body = "m" },
        .{ .language = "lua", .description = "Local", .group = "Values", .body = "l" },
        .{ .language = "c", .description = "Printf", .group = "Start here", .body = "pf" },
    };
    for (specs) |spec| try list.append(a, try Definition.init(a, spec, false));
    return try list.toOwnedSlice(a);
}

fn freeDefs(a: Allocator, defs: []Definition) void {
    for (defs) |*d| d.deinit(a);
    a.free(defs);
}

fn expectRows(state: *const State, defs: []const Definition, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, state.rows.items.len);
    for (state.rows.items, expected) |row, want| {
        const got = switch (row.kind) {
            .group => state.groups.items[row.group].name,
            .item => defs[row.def].description,
        };
        try std.testing.expectEqualStrings(want, got);
    }
}

test "snippet panel filter: case-insensitive over name, trigger and group, matching groups open, others hidden, the selection follows, toggles come back" {
    const a = std.testing.allocator;
    const defs = try testDefs(a);
    defer freeDefs(a, defs);
    var state: State = .{};
    defer state.deinit(a);
    state.sync(a, defs, .{ .revision = 1, .language = "zig" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Functions", "Function", "Start here", "Any" });
    // "PRI" matches a name: only its group, open, and the item selected.
    state.sync(a, defs, .{ .revision = 1, .language = "zig", .filter = "PRI" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Start here", "Print" });
    try std.testing.expectEqual(@as(usize, 1), state.selected);
    try std.testing.expect(state.filterActive());
    try std.testing.expectEqualStrings("PRI", state.filterText());
    // A trigger ("fn") and a group name ("start") match too.
    state.sync(a, defs, .{ .revision = 1, .language = "zig", .filter = "fn" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Functions", "Function" });
    state.sync(a, defs, .{ .revision = 1, .language = "zig", .filter = "start" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Start here", "Print", "Main" });
    // The selected item stays selected while it still matches.
    state.selected = 2; // Main
    state.sync(a, defs, .{ .revision = 1, .language = "zig", .filter = "ma" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Start here", "Main" });
    try std.testing.expectEqual(@as(usize, 1), state.selected);
    // Toggles are ignored while filtering; no match says what to do.
    state.toggle(a, 0);
    state.sync(a, defs, .{ .revision = 1, .language = "zig", .filter = "ma" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Start here", "Main" });
    state.sync(a, defs, .{ .revision = 1, .language = "zig", .filter = "zzz" }, AllKnown{});
    try expectRows(&state, defs, &.{});
    try std.testing.expect(std.mem.indexOf(u8, state.emptyHint(), "Backspace") != null);
    // Cleared: the rows as before, the first group open as before.
    state.sync(a, defs, .{ .revision = 1, .language = "zig" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Functions", "Function", "Start here", "Any" });
    try std.testing.expect(!state.filterActive());
    try std.testing.expectEqualStrings("", state.filterText());
}

test "snippet panel lists one language plus * snippets, groups in first-registration order, first group open" {
    const a = std.testing.allocator;
    const defs = try testDefs(a);
    defer freeDefs(a, defs);
    var state: State = .{};
    defer state.deinit(a);
    state.sync(a, defs, .{ .revision = 1, .language = "Zig" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Functions", "Function", "Start here", "Any" });
    try std.testing.expectEqual(@as(u32, 2), state.groups.items[1].count);
    try std.testing.expectEqualStrings("Zig", state.languageLabel());
    // Opening the second group shows its items in registration order and
    // selects its header; the first group closes on request.
    state.toggle(a, 1);
    state.sync(a, defs, .{ .revision = 1, .language = "Zig" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Functions", "Function", "Start here", "Print", "Main", "Any" });
    try std.testing.expectEqual(@as(usize, 2), state.selected);
    state.selected = 0;
    state.left(a);
    state.sync(a, defs, .{ .revision = 1, .language = "Zig" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Functions", "Start here", "Print", "Main", "Any" });
    // The same key without a toggle is a no-op; the toggles survive a reload.
    state.selected = 3;
    state.sync(a, defs, .{ .revision = 1, .language = "Zig" }, AllKnown{});
    try std.testing.expectEqual(@as(usize, 3), state.selected);
    state.sync(a, defs, .{ .revision = 2, .language = "zig" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Functions", "Start here", "Print", "Main", "Any" });
    try std.testing.expectEqual(@as(usize, 3), state.selected);
}

test "snippet panel any-language mode offers only known languages and a language change resets the selection" {
    const a = std.testing.allocator;
    const defs = try testDefs(a);
    defer freeDefs(a, defs);
    var state: State = .{};
    defer state.deinit(a);
    state.sync(a, defs, .{ .revision = 1, .any_language = true, .languages_known = 2 }, Known{ .names = &.{ "zig", "c" } });
    try expectRows(&state, defs, &.{ "Functions", "Function", "Start here", "Any", "Start here" });
    try std.testing.expectEqualStrings("zig", state.groups.items[1].language);
    try std.testing.expectEqualStrings("c", state.groups.items[3].language);
    try std.testing.expectEqualStrings("any language", state.languageLabel());
    state.end();
    try std.testing.expectEqual(@as(usize, 4), state.selected);
    // Lua becomes known: the key changes and the rows grow.
    state.sync(a, defs, .{ .revision = 1, .any_language = true, .languages_known = 3 }, Known{ .names = &.{ "zig", "c", "lua" } });
    try expectRows(&state, defs, &.{ "Functions", "Function", "Start here", "Any", "Values", "Start here" });
    try std.testing.expectEqual(@as(usize, 4), state.selected);
    // A language appears (the file was saved as .lua): selection and scroll reset.
    state.scroll = 2;
    state.sync(a, defs, .{ .revision = 1, .language = "lua" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Any", "Date", "Values" }); // * registered first
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expectEqual(@as(usize, 0), state.scroll);
    try std.testing.expectEqualStrings("lua", state.languageLabel());
    // A saved file with no language sees * snippets only.
    state.sync(a, defs, .{ .revision = 1 }, AllKnown{});
    try expectRows(&state, defs, &.{ "Any", "Date" });
    state.sync(a, defs, .{ .revision = 1, .language = "rust" }, AllKnown{});
    try expectRows(&state, defs, &.{ "Any", "Date" });
    try std.testing.expect(std.mem.indexOf(u8, state.emptyHint(), "No snippets") != null);
}

test "snippet panel navigation: move clamps, left and right open, close and step, preview follows hover then selection" {
    const a = std.testing.allocator;
    const defs = try testDefs(a);
    defer freeDefs(a, defs);
    var state: State = .{};
    defer state.deinit(a);
    const view: View = .{ .revision = 1, .language = "zig" };
    state.sync(a, defs, view, AllKnown{});
    // rows: Functions, Function, Start here, Any
    state.move(-5);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    state.move(99);
    try std.testing.expectEqual(@as(usize, 3), state.selected);
    try std.testing.expect(state.scroll_to_selected);
    state.home();
    state.right(a); // open group: steps to its first item
    try std.testing.expectEqual(@as(usize, 1), state.selected);
    try std.testing.expectEqual(@as(?u32, 0), state.previewDef(null));
    try std.testing.expectEqual(@as(?u32, 0), state.previewDef(2)); // hovering a group keeps the selected item
    state.left(a); // item → its group header
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expectEqual(@as(?u32, null), state.previewDef(null));
    state.selected = 2;
    state.right(a); // closed group: opens it
    state.sync(a, defs, view, AllKnown{});
    try expectRows(&state, defs, &.{ "Functions", "Function", "Start here", "Print", "Main", "Any" });
    try std.testing.expectEqual(@as(?u32, 1), state.previewDef(3)); // hover wins
    state.left(a); // open group header: closes it
    state.sync(a, defs, view, AllKnown{});
    try expectRows(&state, defs, &.{ "Functions", "Function", "Start here", "Any" });
    // A shrinking list clamps the selection.
    state.selected = 3;
    state.toggle(a, 0);
    state.sync(a, defs, view, AllKnown{});
    try std.testing.expectEqual(@as(usize, 0), state.selected); // toggle selected the header
    state.selected = 7;
    state.dirty = true;
    state.sync(a, defs, view, AllKnown{});
    try std.testing.expectEqual(@as(usize, 2), state.selected);
}
