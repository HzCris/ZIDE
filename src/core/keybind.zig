const std = @import("std");
const Allocator = std.mem.Allocator;

/// Longest canonical key combo. Longer strings are never stored or matched
/// (real combos are under 30 bytes: "ctrl+alt+shift+page_down").
pub const max_combo_len = 64;

/// A key combo in canonical form: lowercase, modifiers in the order
/// `ctrl+alt+shift+` (duplicates dropped), then the key name. Aliases map
/// onto the frontends' vocabulary (`pageup` → `page_up`, `esc` → `escape`,
/// `return` → `enter`, `del` → `delete`, `ins` → `insert`, `\` →
/// `backslash`, a literal space → `space`, dvui-style punctuation names
/// such as `slash` → `/`). The key is everything after the last `+`; a
/// trailing `+` is the plus key itself (`ctrl++`).
pub const Combo = struct {
    /// Canonical spelling (a slice of the caller's buffer).
    text: []const u8,
    /// The key part of `text`.
    key: []const u8,
    ctrl: bool,
    alt: bool,
    shift: bool,
    /// Whether `key` is a name the frontends send (`isKnownKey`).
    known_key: bool,
    /// First modifier that is not ctrl/control, alt or shift (a slice of the
    /// input). Such modifiers stay in `text`, after the known ones, so a
    /// binding that uses one can never collapse onto a plainer chord.
    unknown_modifier: ?[]const u8,
};

/// Key names both frontends emit besides single letters, digits and the
/// punctuation in `key_punctuation`.
const key_names = [_][]const u8{
    "up",     "down",   "left", "right", "home",   "end",       "page_up",   "page_down",
    "insert", "delete", "tab",  "enter", "escape", "backspace", "backslash", "space",
    "f1",     "f2",     "f3",   "f4",    "f5",     "f6",        "f7",        "f8",
    "f9",     "f10",    "f11",  "f12",
};
const key_punctuation = "[];',./-=`";

const key_aliases = [_]struct { []const u8, []const u8 }{
    .{ "pageup", "page_up" },  .{ "pagedown", "page_down" }, .{ "pgup", "page_up" },
    .{ "pgdn", "page_down" },  .{ "esc", "escape" },         .{ "return", "enter" },
    .{ "del", "delete" },      .{ "ins", "insert" },         .{ "\\", "backslash" },
    .{ "slash", "/" },         .{ "minus", "-" },            .{ "equal", "=" },
    .{ "comma", "," },         .{ "period", "." },           .{ "semicolon", ";" },
    .{ "apostrophe", "'" },    .{ "grave", "`" },            .{ "left_bracket", "[" },
    .{ "right_bracket", "]" },
};

/// Whether `key` (canonical, lowercase) is a key name the frontends send.
pub fn isKnownKey(key: []const u8) bool {
    if (key.len == 1) {
        const c = key[0];
        return std.ascii.isLower(c) or std.ascii.isDigit(c) or std.mem.indexOfScalar(u8, key_punctuation, c) != null;
    }
    for (key_names) |name| {
        if (std.mem.eql(u8, name, key)) return true;
    }
    return false;
}

/// Canonical form of `combo` (see `Combo`) written into `buf`, or null when
/// it does not fit.
pub fn canonicalize(buf: *[max_combo_len]u8, combo: []const u8) ?Combo {
    var key_raw: []const u8 = combo;
    var mods_raw: []const u8 = "";
    if (combo.len > 0 and combo[combo.len - 1] == '+') {
        key_raw = "+";
        mods_raw = combo[0 .. combo.len - 1];
    } else if (std.mem.lastIndexOfScalar(u8, combo, '+')) |p| {
        key_raw = combo[p + 1 ..];
        mods_raw = combo[0..p];
    }

    var ctrl = false;
    var alt = false;
    var shift = false;
    var unknown_modifier: ?[]const u8 = null;
    var others: [max_combo_len]u8 = undefined;
    var others_len: usize = 0;
    var mods = std.mem.splitScalar(u8, mods_raw, '+');
    while (mods.next()) |raw| {
        const mod = std.mem.trim(u8, raw, " \t");
        if (mod.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(mod, "ctrl") or std.ascii.eqlIgnoreCase(mod, "control")) {
            ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(mod, "alt")) {
            alt = true;
        } else if (std.ascii.eqlIgnoreCase(mod, "shift")) {
            shift = true;
        } else {
            if (unknown_modifier == null) unknown_modifier = mod;
            if (others_len + mod.len + 1 > others.len) return null;
            _ = std.ascii.lowerString(others[others_len..][0..mod.len], mod);
            others[others_len + mod.len] = '+';
            others_len += mod.len + 1;
        }
    }

    // A key of nothing but spaces is the space bar ("ctrl+ " is what a
    // terminal reports for Ctrl+Space); otherwise surrounding blanks go.
    var lower: [max_combo_len]u8 = undefined;
    const key: []const u8 = key: {
        if (key_raw.len > 0 and std.mem.trim(u8, key_raw, " ").len == 0) break :key "space";
        const trimmed = std.mem.trim(u8, key_raw, " \t");
        if (trimmed.len > lower.len) return null;
        const lowered = std.ascii.lowerString(lower[0..trimmed.len], trimmed);
        for (key_aliases) |alias| {
            if (std.mem.eql(u8, alias[0], lowered)) break :key alias[1];
        }
        break :key lowered;
    };

    var len: usize = 0;
    const parts = [_][]const u8{
        if (ctrl) "ctrl+" else "",
        if (alt) "alt+" else "",
        if (shift) "shift+" else "",
        others[0..others_len],
        key,
    };
    for (parts) |part| {
        if (len + part.len > buf.len) return null;
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
    }
    return .{
        .text = buf[0..len],
        .key = buf[len - key.len .. len],
        .ctrl = ctrl,
        .alt = alt,
        .shift = shift,
        .known_key = isKnownKey(key),
        .unknown_modifier = unknown_modifier,
    };
}

/// Whether a frontend may retry an unbound shift chord without `shift+`.
/// Never for letters — Ctrl+Shift+K is its own chord, and falling back ran
/// Ctrl+K's delete_line (Ctrl+Shift+Z ran undo) — but yes for keys such as
/// punctuation or F-keys whose shifted form rarely has a binding of its own.
pub fn allowsShiftFallback(combo: []const u8) bool {
    var buf: [max_combo_len]u8 = undefined;
    const c = canonicalize(&buf, combo) orelse return false;
    return c.shift and !(c.key.len == 1 and std.ascii.isLower(c.key[0]));
}

/// Data-driven keybinding map.
/// Maps key combo strings (e.g. "ctrl+s") to action names. Combos are
/// stored and looked up in canonical form (`canonicalize`), so "Shift+Ctrl+K"
/// binds the same chord the frontends report as "ctrl+shift+k".
///
/// Every default action is a command-registry name (the palette lists them
/// all); the frontends and `Editor.execAction` handle some specially:
///   "quit", "save", "save_as", "find", "find_replace", "file_open",
///   "command_palette", "goto_line", "new_document", …
pub const KeybindMap = struct {
    map: std.StringHashMapUnmanaged([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) KeybindMap {
        return .{ .map = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *KeybindMap) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    /// Set or override a keybinding. Dupes both key and action strings.
    /// The combo is canonicalized; one warning is logged when it cannot fire
    /// (unknown modifier or key name) and a combo with no key or longer than
    /// `max_combo_len` is ignored. Whether `action` names a command is the
    /// caller's check (`CommandRegistry.warnIfUnknownAction`).
    pub fn set(self: *KeybindMap, key_str: []const u8, action: []const u8) !void {
        var buf: [max_combo_len]u8 = undefined;
        const combo = canonicalize(&buf, key_str) orelse {
            std.log.warn("keybind '{s}' is too long to be a key combo; ignored", .{key_str});
            return;
        };
        if (combo.key.len == 0) {
            std.log.warn("keybind '{s}' names no key; ignored", .{key_str});
            return;
        }
        if (combo.unknown_modifier) |mod| {
            std.log.warn("keybind '{s}': unknown modifier '{s}' (use ctrl, alt, shift) — it will never fire", .{ key_str, mod });
        } else if (!combo.known_key) {
            std.log.warn("keybind '{s}': unknown key name '{s}' — it will never fire", .{ key_str, combo.key });
        }
        if (self.map.fetchRemove(combo.text)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        const k = try self.allocator.dupe(u8, combo.text);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(v);
        try self.map.put(self.allocator, k, v);
    }

    /// Remove a keybinding (any spelling of the combo).
    pub fn remove(self: *KeybindMap, key_str: []const u8) void {
        var buf: [max_combo_len]u8 = undefined;
        const combo = canonicalize(&buf, key_str) orelse return;
        if (self.map.fetchRemove(combo.text)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Look up the action for a key combo (any spelling of it).
    pub fn get(self: *const KeybindMap, key_str: []const u8) ?[]const u8 {
        var buf: [max_combo_len]u8 = undefined;
        const combo = canonicalize(&buf, key_str) orelse return null;
        return self.map.get(combo.text);
    }

    /// Populate with CUA defaults.
    /// Keep main.zig's `welcome_text` hotkey reference in sync with this list.
    pub fn loadDefaults(self: *KeybindMap) !void {
        // Ctrl+letter shortcuts
        try self.set("ctrl+q", "quit");
        try self.set("ctrl+s", "save");
        try self.set("ctrl+shift+s", "save_as");
        try self.set("ctrl+z", "undo");
        try self.set("ctrl+y", "redo");
        // Exact match beats the frontends' shift-stripped fallback, which
        // would otherwise turn Ctrl+Shift+Z into undo.
        try self.set("ctrl+shift+z", "redo");
        try self.set("ctrl+n", "new_document");
        try self.set("ctrl+c", "copy");
        try self.set("ctrl+x", "cut");
        try self.set("ctrl+v", "paste");
        try self.set("ctrl+a", "select_all");
        try self.set("ctrl+f", "find");
        try self.set("ctrl+h", "find_replace");
        try self.set("ctrl+o", "file_open");
        try self.set("ctrl+p", "command_palette");
        try self.set("ctrl+e", "quick_open");
        try self.set("ctrl+shift+f", "find_in_files");
        try self.set("f4", "next_result");
        try self.set("shift+f4", "prev_result");
        try self.set("ctrl+g", "goto_line");
        try self.set("ctrl+shift+d", "duplicate_line");
        try self.set("ctrl+k", "delete_line");
        try self.set("ctrl+/", "toggle_comment");
        try self.set("ctrl+w", "close_tab");
        // Ctrl+navigation
        try self.set("ctrl+backspace", "delete_word_backward");
        try self.set("ctrl+delete", "delete_word_forward");
        try self.set("ctrl+left", "cursor_word_left");
        try self.set("ctrl+right", "cursor_word_right");
        try self.set("ctrl+shift+left", "cursor_word_left_select");
        try self.set("ctrl+shift+right", "cursor_word_right_select");
        try self.set("ctrl+home", "cursor_file_start");
        try self.set("ctrl+end", "cursor_file_end");
        try self.set("ctrl+shift+home", "cursor_file_start_select");
        try self.set("ctrl+shift+end", "cursor_file_end_select");
        // Alt shortcuts
        try self.set("alt+up", "move_line_up");
        try self.set("alt+down", "move_line_down");
        // Multi-cursor (ctrl+shift may be eaten by some terminals, ctrl+alt as fallback)
        try self.set("ctrl+shift+up", "add_cursor_above");
        try self.set("ctrl+shift+down", "add_cursor_below");
        try self.set("ctrl+alt+up", "add_cursor_above");
        try self.set("ctrl+alt+down", "add_cursor_below");
        try self.set("ctrl+d", "add_next_occurrence");
        // Split pane shortcuts
        try self.set("alt+backslash", "split_vertical");
        try self.set("alt+shift+backslash", "split_horizontal");
        try self.set("ctrl+alt+q", "close_pane");
        // Windows (GUI); ctrl+shift+n is the cross-editor convention, the
        // Alt twin is for terminals that eat Shift chords.
        try self.set("ctrl+shift+n", "open_in_new_window");
        try self.set("ctrl+alt+n", "open_in_new_window");
        try self.set("ctrl+page_down", "next_doc");
        try self.set("ctrl+page_up", "prev_doc");
        try self.set("ctrl+tab", "next_doc");
        try self.set("ctrl+shift+tab", "prev_doc");
        try self.set("alt+right", "focus_next_pane");
        try self.set("alt+left", "focus_prev_pane");
        // Alt-free alternates — Windows terminals commonly eat Alt+keys
        // (Windows Terminal binds Alt+arrows itself; Ctrl+Alt doubles as
        // AltGr), so every Alt binding has a Ctrl/F-key twin.
        try self.set("ctrl+backslash", "split_vertical");
        try self.set("ctrl+shift+backslash", "split_horizontal");
        try self.set("f6", "focus_next_pane");
        try self.set("shift+f6", "focus_prev_pane");
        try self.set("ctrl+f4", "close_pane");
        try self.set("ctrl+shift+page_up", "move_line_up");
        try self.set("ctrl+shift+page_down", "move_line_down");
        // LSP shortcuts
        try self.set("ctrl+space", "lsp_completion");
        try self.set("f12", "lsp_goto_definition");
        // Navigation history (F7 twins for terminals that eat Ctrl+Alt+arrows)
        try self.set("ctrl+alt+left", "navigate_back");
        try self.set("ctrl+alt+right", "navigate_forward");
        try self.set("f7", "navigate_back");
        try self.set("shift+f7", "navigate_forward");
        try self.set("ctrl+shift+t", "reopen_closed_tab");
        try self.set("alt+m", "goto_matching_bracket");
        try self.set("ctrl+shift+o", "open_folder");
        try self.set("shift+f12", "lsp_references");
        try self.set("ctrl+f12", "lsp_document_symbols");
        try self.set("ctrl+t", "lsp_workspace_symbols");
        try self.set("ctrl+shift+space", "lsp_signature_help");
        // Code review (temporary homes until the hotkey pass; Shift+F8 is
        // explicit because an unbound Shift+F-key falls back to the plain one)
        try self.set("f8", "review_next_file");
        try self.set("shift+f8", "review_prev_file");
        try self.set("ctrl+f8", "review");
        try self.set("f9", "review_next_change");
        try self.set("shift+f9", "review_prev_change");
        try self.set("ctrl+f9", "review_toggle_view");
        // Terminal. Ctrl+Shift+` is the docked terminal panel (full height
        // at a side, or a strip at the bottom); the side-by-side split it
        // used to make stays in the palette as open_terminal_right.
        try self.set("ctrl+`", "toggle_terminal");
        try self.set("ctrl+shift+`", "toggle_terminal_panel");
        try self.set("ctrl+alt+`", "detach_terminal");
        // Side panels
        try self.set("ctrl+b", "toggle_filetree");
        try self.set("ctrl+alt+b", "toggle_snippets");
        try self.set("ctrl+alt+s", "snippet_save_selection");
    }
};

// ---- Tests ----

test "keybind map" {
    const allocator = std.testing.allocator;
    var kb = KeybindMap.init(allocator);
    defer kb.deinit();

    try kb.set("ctrl+s", "save");
    try std.testing.expectEqualStrings("save", kb.get("ctrl+s").?);

    // Override
    try kb.set("ctrl+s", "save_as");
    try std.testing.expectEqualStrings("save_as", kb.get("ctrl+s").?);

    // Remove
    kb.remove("ctrl+s");
    try std.testing.expect(kb.get("ctrl+s") == null);
}

test "keybind defaults" {
    const allocator = std.testing.allocator;
    var kb = KeybindMap.init(allocator);
    defer kb.deinit();

    try kb.loadDefaults();
    try std.testing.expectEqualStrings("save", kb.get("ctrl+s").?);
    try std.testing.expectEqualStrings("undo", kb.get("ctrl+z").?);
    try std.testing.expectEqualStrings("delete_line", kb.get("ctrl+k").?);
    try std.testing.expectEqualStrings("toggle_comment", kb.get("ctrl+/").?);
    try std.testing.expectEqualStrings("move_line_up", kb.get("alt+up").?);
    try std.testing.expectEqualStrings("add_next_occurrence", kb.get("ctrl+d").?);
    try std.testing.expectEqualStrings("duplicate_line", kb.get("ctrl+shift+d").?);
    try std.testing.expectEqualStrings("add_cursor_above", kb.get("ctrl+shift+up").?);
    try std.testing.expectEqualStrings("add_cursor_below", kb.get("ctrl+alt+down").?);
    // Alt-free alternates
    try std.testing.expectEqualStrings("split_vertical", kb.get("ctrl+backslash").?);
    try std.testing.expectEqualStrings("focus_next_pane", kb.get("f6").?);
    try std.testing.expectEqualStrings("close_pane", kb.get("ctrl+f4").?);
    try std.testing.expectEqualStrings("move_line_up", kb.get("ctrl+shift+page_up").?);
    try std.testing.expectEqualStrings("lsp_goto_definition", kb.get("f12").?);
    try std.testing.expectEqualStrings("navigate_back", kb.get("ctrl+alt+left").?);
    try std.testing.expectEqualStrings("navigate_forward", kb.get("shift+f7").?);
    try std.testing.expectEqualStrings("reopen_closed_tab", kb.get("ctrl+shift+t").?);
    try std.testing.expectEqualStrings("goto_matching_bracket", kb.get("alt+m").?);
    try std.testing.expectEqualStrings("open_folder", kb.get("ctrl+shift+o").?);
    try std.testing.expectEqualStrings("lsp_references", kb.get("shift+f12").?);
    try std.testing.expectEqualStrings("lsp_document_symbols", kb.get("ctrl+f12").?);
    try std.testing.expectEqualStrings("lsp_workspace_symbols", kb.get("ctrl+t").?);
    try std.testing.expectEqualStrings("lsp_signature_help", kb.get("ctrl+shift+space").?);
    try std.testing.expectEqualStrings("toggle_filetree", kb.get("ctrl+b").?);
    try std.testing.expectEqualStrings("toggle_snippets", kb.get("ctrl+alt+b").?);
    try std.testing.expectEqualStrings("snippet_save_selection", kb.get("ctrl+alt+s").?);
    // Windows
    try std.testing.expectEqualStrings("open_in_new_window", kb.get("ctrl+shift+n").?);
    try std.testing.expectEqualStrings("open_in_new_window", kb.get("ctrl+alt+n").?);
    try std.testing.expectEqualStrings("detach_terminal", kb.get("ctrl+alt+`").?);
    try std.testing.expectEqualStrings("toggle_terminal_panel", kb.get("ctrl+shift+`").?);
    // Ctrl+Shift+Z is redo, not the shift-stripped Ctrl+Z fallback
    try std.testing.expectEqualStrings("redo", kb.get("ctrl+shift+z").?);
    // The completion chord as either frontend spells it (a terminal may
    // report the key as a literal space)
    try std.testing.expectEqualStrings("lsp_completion", kb.get("ctrl+space").?);
    try std.testing.expectEqualStrings("lsp_completion", kb.get("ctrl+ ").?);
    try std.testing.expectEqualStrings("lsp_completion", kb.get("Ctrl+Space").?);

    // Every default is stored canonically with a key the frontends send.
    var it = kb.map.iterator();
    while (it.next()) |entry| {
        var buf: [max_combo_len]u8 = undefined;
        const combo = canonicalize(&buf, entry.key_ptr.*).?;
        try std.testing.expectEqualStrings(entry.key_ptr.*, combo.text);
        try std.testing.expect(combo.known_key);
        try std.testing.expect(combo.unknown_modifier == null);
    }
}

test "keybind combos are canonical: case, modifier order, aliases" {
    const t = std.testing;
    var kb = KeybindMap.init(t.allocator);
    defer kb.deinit();

    try kb.set("Ctrl+Shift+K", "kill");
    try t.expectEqualStrings("kill", kb.get("ctrl+shift+k").?);
    try t.expectEqualStrings("kill", kb.get("shift+ctrl+k").?);
    try t.expectEqualStrings("kill", kb.get("SHIFT+CONTROL+K").?);
    try t.expect(kb.get("ctrl+k") == null);
    // Re-binding another spelling replaces the same entry.
    try kb.set("shift+ctrl+k", "kill2");
    try t.expectEqual(@as(u32, 1), kb.map.count());
    try t.expectEqualStrings("kill2", kb.get("ctrl+shift+k").?);

    try kb.set("ctrl+pageup", "prev");
    try t.expectEqualStrings("prev", kb.get("ctrl+page_up").?);
    try t.expectEqualStrings("prev", kb.get("Ctrl+PageUp").?);
    kb.remove("CTRL+Page_Up");
    try t.expect(kb.get("ctrl+page_up") == null);

    try kb.set("alt+\\", "split");
    try t.expectEqualStrings("split", kb.get("alt+backslash").?);

    var buf: [max_combo_len]u8 = undefined;
    const Case = struct { in: []const u8, out: []const u8 };
    for ([_]Case{
        .{ .in = "shift+alt+ctrl+x", .out = "ctrl+alt+shift+x" },
        .{ .in = "ctrl+ctrl+s", .out = "ctrl+s" },
        .{ .in = "Control+Esc", .out = "ctrl+escape" },
        .{ .in = "alt+Return", .out = "alt+enter" },
        .{ .in = "shift+del", .out = "shift+delete" },
        .{ .in = "ctrl+ins", .out = "ctrl+insert" },
        .{ .in = "ctrl+pagedown", .out = "ctrl+page_down" },
        .{ .in = "ctrl+slash", .out = "ctrl+/" },
        .{ .in = "ctrl + shift + f", .out = "ctrl+shift+f" },
        .{ .in = "F5", .out = "f5" },
        .{ .in = "ctrl+`", .out = "ctrl+`" },
        .{ .in = "ctrl+1", .out = "ctrl+1" },
    }) |c| {
        const combo = canonicalize(&buf, c.in).?;
        try t.expectEqualStrings(c.out, combo.text);
        try t.expect(combo.known_key);
        try t.expect(combo.unknown_modifier == null);
    }

    // Combos that can never fire: flagged, and kept apart from plainer chords.
    const plus = canonicalize(&buf, "ctrl++").?;
    try t.expectEqualStrings("ctrl++", plus.text);
    try t.expect(!plus.known_key);
    try t.expect(!canonicalize(&buf, "ctrl+numpad5").?.known_key);
    const cmd = canonicalize(&buf, "Shift+Cmd+S").?;
    try t.expectEqualStrings("shift+cmd+s", cmd.text);
    try t.expectEqualStrings("Cmd", cmd.unknown_modifier.?);
    try t.expect(canonicalize(&buf, "ctrl+" ++ "x" ** max_combo_len) == null);

    // Such binds are stored (after one warning) but never shadow real chords;
    // an empty key or an over-long combo is ignored.
    const old_level = t.log_level;
    t.log_level = .err;
    defer t.log_level = old_level;
    try kb.set("cmd+s", "nope");
    try t.expect(kb.get("s") == null);
    try t.expectEqualStrings("nope", kb.get("CMD+S").?);
    const before = kb.map.count();
    try kb.set("", "nothing");
    try kb.set("ctrl+" ++ "x" ** max_combo_len, "nothing");
    try t.expectEqual(before, kb.map.count());
}

test "shift fallback is for punctuation and special keys, never letters" {
    const t = std.testing;
    try t.expect(!allowsShiftFallback("ctrl+shift+z"));
    try t.expect(!allowsShiftFallback("Shift+Ctrl+K"));
    try t.expect(!allowsShiftFallback("ctrl+/")); // no shift to strip
    try t.expect(allowsShiftFallback("ctrl+shift+/"));
    try t.expect(allowsShiftFallback("ctrl+shift+backslash"));
    try t.expect(allowsShiftFallback("shift+f12"));
}
