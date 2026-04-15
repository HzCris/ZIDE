const std = @import("std");
const Allocator = std.mem.Allocator;

/// Data-driven keybinding map.
/// Maps key combo strings (e.g. "ctrl+s") to action names (command names or special actions).
///
/// Special action names (not in command registry, handled by frontend):
///   "quit", "save", "find", "find_replace", "file_open",
///   "command_palette", "goto_line", "new_document"
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
    pub fn set(self: *KeybindMap, key_str: []const u8, action: []const u8) !void {
        if (self.map.fetchRemove(key_str)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        const k = try self.allocator.dupe(u8, key_str);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(v);
        try self.map.put(self.allocator, k, v);
    }

    /// Remove a keybinding.
    pub fn remove(self: *KeybindMap, key_str: []const u8) void {
        if (self.map.fetchRemove(key_str)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Look up the action for a key combo.
    pub fn get(self: *const KeybindMap, key_str: []const u8) ?[]const u8 {
        return self.map.get(key_str);
    }

    /// Populate with CUA defaults.
    pub fn loadDefaults(self: *KeybindMap) !void {
        // Ctrl+letter shortcuts
        try self.set("ctrl+q", "quit");
        try self.set("ctrl+s", "save");
        try self.set("ctrl+shift+s", "save_as");
        try self.set("ctrl+z", "undo");
        try self.set("ctrl+y", "redo");
        try self.set("ctrl+n", "new_document");
        try self.set("ctrl+c", "copy");
        try self.set("ctrl+x", "cut");
        try self.set("ctrl+v", "paste");
        try self.set("ctrl+a", "select_all");
        try self.set("ctrl+f", "find");
        try self.set("ctrl+h", "find_replace");
        try self.set("ctrl+o", "file_open");
        try self.set("ctrl+p", "command_palette");
        try self.set("ctrl+g", "goto_line");
        try self.set("ctrl+shift+d", "duplicate_line");
        try self.set("ctrl+k", "delete_line");
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
        try self.set("ctrl+shift+w", "close_pane");
        // LSP shortcuts
        try self.set("ctrl+space", "lsp_completion");
        try self.set("f12", "lsp_goto_definition");
        // Terminal
        try self.set("ctrl+`", "toggle_terminal");
        try self.set("ctrl+shift+`", "open_terminal_right");
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
    try std.testing.expectEqualStrings("move_line_up", kb.get("alt+up").?);
    try std.testing.expectEqualStrings("add_next_occurrence", kb.get("ctrl+d").?);
    try std.testing.expectEqualStrings("duplicate_line", kb.get("ctrl+shift+d").?);
    try std.testing.expectEqualStrings("add_cursor_above", kb.get("ctrl+shift+up").?);
    try std.testing.expectEqualStrings("add_cursor_below", kb.get("ctrl+alt+down").?);
}
