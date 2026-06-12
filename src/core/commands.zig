const std = @import("std");
const Allocator = std.mem.Allocator;
const theme_mod = @import("theme.zig");
const lua_settings = @import("lua_settings.zig");
const lua_api = @import("lua_api.zig");
const syntax = @import("syntax.zig");
const filetree_mod = @import("filetree.zig");

/// Forward declaration — Editor will be defined in editor.zig.
/// Commands receive a pointer to the editor state.
pub const Editor = @import("editor.zig").Editor;

/// A command function signature.
/// Takes the editor state and optional string arguments.
pub const CommandFn = *const fn (editor: *Editor, args: ?[]const u8) void;

/// A registered command.
pub const Command = struct {
    name: []const u8,
    description: []const u8,
    execute: CommandFn,
    /// Lua registry ref of the callback when this command was registered
    /// from Lua via zide.command — dispatch routes through lua_api instead
    /// of `execute`, and name/description are owned by the registry.
    lua_ref: ?i32 = null,
};

/// Placeholder for Lua-backed commands; never invoked (execute() routes
/// lua_ref entries through lua_api before reaching the fn pointer).
fn cmdLuaStub(_: *Editor, _: ?[]const u8) void {}

/// Registry of named commands. All editor actions go through this.
pub const CommandRegistry = struct {
    commands: std.StringHashMapUnmanaged(Command),
    allocator: Allocator,
    /// Cached sorted command names (invalidated on register).
    cached_names: ?[][]const u8 = null,

    pub fn init(allocator: Allocator) CommandRegistry {
        return .{
            .commands = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.invalidateCache();
        self.commands.deinit(self.allocator);
    }

    /// Register a new command. Overwrites if name already exists.
    pub fn register(self: *CommandRegistry, name: []const u8, description: []const u8, func: CommandFn) !void {
        try self.commands.put(self.allocator, name, .{
            .name = name,
            .description = description,
            .execute = func,
        });
        self.invalidateCache();
    }

    /// Look up a command by name.
    pub fn get(self: *const CommandRegistry, name: []const u8) ?*const Command {
        return self.commands.getPtr(name);
    }

    /// Execute a command by name. Returns false if command not found.
    pub fn execute(self: *const CommandRegistry, editor: *Editor, name: []const u8, args: ?[]const u8) bool {
        const cmd = self.commands.getPtr(name) orelse return false;
        if (cmd.lua_ref) |r| {
            lua_api.callLuaCommand(editor, r, args);
            return true;
        }
        cmd.execute(editor, args);
        return true;
    }

    /// Register a Lua-backed command. Takes ownership of `name` and
    /// `description` (allocated with this registry's allocator) on
    /// success; on error the caller still owns them. Returns the previous
    /// Lua ref when replacing a Lua command — the caller must unref it.
    /// Replacing a built-in is allowed (Lite XL style) and logged.
    pub fn registerLua(self: *CommandRegistry, name: []const u8, description: []const u8, lua_ref: i32) !?i32 {
        var prev_ref: ?i32 = null;
        if (self.commands.fetchRemove(name)) |kv| {
            if (kv.value.lua_ref) |r| {
                prev_ref = r;
                self.allocator.free(kv.value.name);
                self.allocator.free(kv.value.description);
            } else {
                std.log.warn("zide.command: '{s}' overrides a built-in command", .{name});
            }
        }
        try self.commands.put(self.allocator, name, .{
            .name = name,
            .description = description,
            .execute = cmdLuaStub,
            .lua_ref = lua_ref,
        });
        self.invalidateCache();
        return prev_ref;
    }

    /// Remove all Lua-backed commands, freeing their owned strings.
    /// Appends their registry refs to `refs_out`; the caller unrefs them
    /// (the registry has no Lua state of its own).
    pub fn removeLuaCommands(self: *CommandRegistry, refs_out: *std.ArrayList(i32)) void {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.allocator);
        var it = self.commands.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.lua_ref != null) {
                keys.append(self.allocator, entry.key_ptr.*) catch return;
            }
        }
        for (keys.items) |key| {
            const kv = self.commands.fetchRemove(key) orelse continue;
            if (kv.value.lua_ref) |r| refs_out.append(self.allocator, r) catch {};
            self.allocator.free(kv.value.name);
            self.allocator.free(kv.value.description);
        }
        if (keys.items.len > 0) self.invalidateCache();
    }

    /// Get a sorted list of all command names (for command palette).
    /// Returns a cached slice — caller must NOT free it.
    pub fn allNames(self: *CommandRegistry) ![][]const u8 {
        if (self.cached_names) |names| return names;
        var names = try std.ArrayList([]const u8).initCapacity(self.allocator, self.commands.count());
        errdefer names.deinit(self.allocator);
        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            names.appendAssumeCapacity(entry.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        // toOwnedSlice: invalidateCache frees this with allocator.free, which
        // requires an exactly-sized allocation (items.len == capacity is not
        // guaranteed by ArrayList in general).
        const owned = try names.toOwnedSlice(self.allocator);
        self.cached_names = owned;
        return owned;
    }

    fn invalidateCache(self: *CommandRegistry) void {
        if (self.cached_names) |names| {
            // Free the ArrayList's backing allocation
            self.allocator.free(names);
            self.cached_names = null;
        }
    }

    /// Number of registered commands.
    pub fn count(self: *const CommandRegistry) usize {
        return self.commands.count();
    }
};

/// Register all built-in editor commands.
pub fn registerBuiltins(registry: *CommandRegistry) !void {
    try registry.register("cursor_right", "Move cursor right", cmdCursorRight);
    try registry.register("cursor_left", "Move cursor left", cmdCursorLeft);
    try registry.register("cursor_up", "Move cursor up", cmdCursorUp);
    try registry.register("cursor_down", "Move cursor down", cmdCursorDown);
    try registry.register("cursor_home", "Move to beginning of line", cmdCursorHome);
    try registry.register("cursor_end", "Move to end of line", cmdCursorEnd);
    try registry.register("insert_char", "Insert character at cursor", cmdInsertChar);
    try registry.register("delete_forward", "Delete character forward", cmdDeleteForward);
    try registry.register("delete_backward", "Delete character backward (backspace)", cmdDeleteBackward);
    try registry.register("insert_newline", "Insert newline at cursor", cmdInsertNewline);
    try registry.register("undo", "Undo last edit", cmdUndo);
    try registry.register("redo", "Redo last undone edit", cmdRedo);
    try registry.register("select_all", "Select all text", cmdSelectAll);
    try registry.register("page_up", "Move cursor up one page", cmdPageUp);
    try registry.register("page_down", "Move cursor down one page", cmdPageDown);
    try registry.register("cursor_right_select", "Extend selection right", cmdCursorRightSelect);
    try registry.register("cursor_left_select", "Extend selection left", cmdCursorLeftSelect);
    try registry.register("cursor_up_select", "Extend selection up", cmdCursorUpSelect);
    try registry.register("cursor_down_select", "Extend selection down", cmdCursorDownSelect);
    try registry.register("cursor_home_select", "Extend selection to line start", cmdCursorHomeSelect);
    try registry.register("cursor_end_select", "Extend selection to line end", cmdCursorEndSelect);
    try registry.register("copy", "Copy selection to clipboard", cmdCopy);
    try registry.register("cut", "Cut selection to clipboard", cmdCut);
    try registry.register("paste", "Paste from clipboard", cmdPaste);
    try registry.register("insert_newline_auto", "Insert newline with auto-indent", cmdInsertNewlineAuto);
    try registry.register("cursor_word_right", "Move cursor right by word", cmdCursorWordRight);
    try registry.register("cursor_word_left", "Move cursor left by word", cmdCursorWordLeft);
    try registry.register("cursor_word_right_select", "Extend selection right by word", cmdCursorWordRightSelect);
    try registry.register("cursor_word_left_select", "Extend selection left by word", cmdCursorWordLeftSelect);
    try registry.register("delete_word_forward", "Delete word forward", cmdDeleteWordForward);
    try registry.register("delete_word_backward", "Delete word backward", cmdDeleteWordBackward);
    try registry.register("delete_line", "Delete current line", cmdDeleteLine);
    try registry.register("duplicate_line", "Duplicate current line", cmdDuplicateLine);
    try registry.register("move_line_up", "Move line up", cmdMoveLineUp);
    try registry.register("move_line_down", "Move line down", cmdMoveLineDown);
    try registry.register("smart_home", "Smart Home (first non-whitespace or col 0)", cmdSmartHome);
    try registry.register("smart_home_select", "Extend selection to smart home", cmdSmartHomeSelect);
    try registry.register("indent", "Indent (insert tab/spaces)", cmdIndent);
    try registry.register("dedent", "Dedent (remove leading whitespace)", cmdDedent);
    try registry.register("toggle_comment", "Toggle comment on selected lines", cmdToggleComment);
    try registry.register("next_todo", "Jump to next TODO/FIXME/XXX/HACK/BUG/NOTE marker", cmdNextTodo);
    try registry.register("reload_extensions", "Reload Lua extensions (re-runs extensions/*.lua)", cmdReloadExtensions);
    // File tree commands
    try registry.register("toggle_filetree", "Toggle the file tree side panel", cmdToggleFiletree);
    try registry.register("filetree_reveal", "Reveal the current file in the file tree", cmdFiletreeReveal);
    try registry.register("filetree_refresh", "Refresh the file tree from disk", cmdFiletreeRefresh);
    try registry.register("filetree_root_up", "Re-root the file tree at the parent directory", cmdFiletreeRootUp);
    try registry.register("cursor_file_start", "Move to start of file", cmdCursorFileStart);
    try registry.register("cursor_file_end", "Move to end of file", cmdCursorFileEnd);
    try registry.register("cursor_file_start_select", "Select to start of file", cmdCursorFileStartSelect);
    try registry.register("cursor_file_end_select", "Select to end of file", cmdCursorFileEndSelect);
    try registry.register("add_cursor_below", "Add cursor below", cmdAddCursorBelow);
    try registry.register("add_cursor_above", "Add cursor above", cmdAddCursorAbove);
    try registry.register("add_next_occurrence", "Add cursor at next occurrence", cmdAddNextOccurrence);
    try registry.register("escape_multicursor", "Remove secondary cursors", cmdEscapeMulticursor);
    // Split pane commands
    try registry.register("split_vertical", "Split pane vertically (side by side)", cmdSplitVertical);
    try registry.register("split_horizontal", "Split pane horizontally (top/bottom)", cmdSplitHorizontal);
    try registry.register("close_pane", "Close current pane", cmdClosePane);
    try registry.register("focus_next_pane", "Focus next pane", cmdFocusNextPane);
    try registry.register("focus_prev_pane", "Focus previous pane", cmdFocusPrevPane);
    // Theme commands (set both frontends)
    try registry.register("theme_dark", "Switch to dark theme (both frontends)", cmdThemeDark);
    try registry.register("theme_light", "Switch to light theme (both frontends)", cmdThemeLight);
    try registry.register("theme_high_contrast", "Switch to high contrast theme (both frontends)", cmdThemeHighContrast);
    try registry.register("theme_terminal", "Switch to terminal theme (TUI only, uses ANSI colors)", cmdThemeTerminal);
    // GUI-only theme commands
    try registry.register("gui_theme_dark", "Switch GUI to dark theme", cmdGuiThemeDark);
    try registry.register("gui_theme_light", "Switch GUI to light theme", cmdGuiThemeLight);
    try registry.register("gui_theme_high_contrast", "Switch GUI to high contrast theme", cmdGuiThemeHighContrast);
    // TUI-only theme commands
    try registry.register("tui_theme_dark", "Switch TUI to dark theme", cmdTuiThemeDark);
    try registry.register("tui_theme_light", "Switch TUI to light theme", cmdTuiThemeLight);
    try registry.register("tui_theme_high_contrast", "Switch TUI to high contrast theme", cmdTuiThemeHighContrast);
}

// --- Built-in command implementations ---

fn cmdCursorRight(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveRight(&doc.buffer);
    }
    doc.cursors.mergeCursors();
}

fn cmdCursorLeft(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveLeft(&doc.buffer);
    }
    doc.cursors.mergeCursors();
}

fn cmdCursorUp(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveUp(&doc.buffer);
    }
    doc.cursors.mergeCursors();
}

fn cmdCursorDown(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveDown(&doc.buffer);
    }
    doc.cursors.mergeCursors();
}

fn cmdCursorHome(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveHome(&doc.buffer);
    }
    doc.cursors.mergeCursors();
}

fn cmdCursorEnd(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveEnd(&doc.buffer);
    }
    doc.cursors.mergeCursors();
}

fn cmdInsertChar(editor: *Editor, args: ?[]const u8) void {
    const text = args orelse return;
    const doc = editor.activeDoc();

    // Multi-cursor: simple insert at all cursors, skip auto-close complexity
    if (doc.cursors.count() > 1) {
        doc.insertAtAllCursors(text) catch {};
        return;
    }

    if (doc.cursors.primary().hasSelection()) {
        doc.deleteSelection() catch {};
    }

    // Skip-over: if typing a closing bracket and cursor is on that same char, just move right
    if (editor.auto_close_brackets and text.len == 1) {
        const ch = text[0];
        if (ch == ')' or ch == ']' or ch == '}' or ch == '\'' or ch == '"' or ch == '`') {
            const offset = doc.cursors.primary().offset;
            if (offset < doc.buffer.byteLen()) {
                const next = doc.buffer.slice(offset, offset + 1);
                if (next.len > 0 and next[0] == ch) {
                    doc.cursors.primary().moveRight(&doc.buffer);
                    return;
                }
            }
        }
    }

    doc.insertAtCursor(text) catch {};

    // Auto-close brackets/quotes
    if (editor.auto_close_brackets and text.len == 1) {
        const closing: ?[]const u8 = switch (text[0]) {
            '(' => ")",
            '[' => "]",
            '{' => "}",
            '\'' => "'",
            '"' => "\"",
            '`' => "`",
            else => null,
        };
        if (closing) |close| {
            // For quotes, don't auto-close if char before cursor is alphanumeric
            // (likely a contraction like "don't" or end of a word)
            if (text[0] == '\'' or text[0] == '"' or text[0] == '`') {
                const offset = doc.cursors.primary().offset;
                if (offset >= 2) {
                    const before = doc.buffer.slice(offset - 2, offset - 1);
                    if (before.len > 0 and (std.ascii.isAlphanumeric(before[0]) or before[0] == '_')) {
                        return;
                    }
                }
            }
            doc.insertAtCursor(close) catch return;
            // Move cursor back between the pair
            doc.cursors.primary().moveLeft(&doc.buffer);
        }
    }
}

fn cmdDeleteForward(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().deleteForwardAll(1) catch {};
}

fn cmdDeleteBackward(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().deleteBackwardAll(1) catch {};
}

fn cmdInsertNewline(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().insertAtAllCursors("\n") catch {};
}

fn cmdUndo(editor: *Editor, _: ?[]const u8) void {
    _ = editor.activeDoc().undoAction() catch {};
}

fn cmdRedo(editor: *Editor, _: ?[]const u8) void {
    _ = editor.activeDoc().redoAction() catch {};
}

fn cmdSelectAll(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
    c.anchor = 0;
    c.offset = doc.buffer.byteLen();
}

fn cmdPageUp(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveUpN(&doc.buffer, editor.page_size);
    }
    doc.cursors.mergeCursors();
}

fn cmdPageDown(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveDownN(&doc.buffer, editor.page_size);
    }
    doc.cursors.mergeCursors();
}

// --- Selection-extending movement commands ---

fn cmdCursorRightSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        if (!c.hasSelection()) c.startSelection();
        c.moveRight(&doc.buffer);
    }
}

fn cmdCursorLeftSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        if (!c.hasSelection()) c.startSelection();
        c.moveLeft(&doc.buffer);
    }
}

fn cmdCursorUpSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        if (!c.hasSelection()) c.startSelection();
        c.moveUp(&doc.buffer);
    }
}

fn cmdCursorDownSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        if (!c.hasSelection()) c.startSelection();
        c.moveDown(&doc.buffer);
    }
}

fn cmdCursorHomeSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        if (!c.hasSelection()) c.startSelection();
        c.moveHome(&doc.buffer);
    }
}

fn cmdCursorEndSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        if (!c.hasSelection()) c.startSelection();
        c.moveEnd(&doc.buffer);
    }
}

// --- Clipboard commands ---

fn cmdCopy(editor: *Editor, _: ?[]const u8) void {
    const text = editor.activeDoc().selectedText() orelse return;
    if (text.len == 0) return;
    editor.setClipboard(text);
}

fn cmdCut(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    const text = doc.selectedText() orelse return;
    if (text.len == 0) return;
    editor.setClipboard(text);
    doc.deleteSelection() catch {};
}

fn cmdPaste(editor: *Editor, _: ?[]const u8) void {
    const text = editor.getClipboard();
    if (text.len == 0) return;
    editor.activeDoc().insertAtAllCursors(text) catch {};
}

// --- Word movement ---

fn cmdCursorWordRight(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveWordRight(&doc.buffer);
    }
    doc.cursors.mergeCursors();
}

fn cmdCursorWordLeft(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveWordLeft(&doc.buffer);
    }
    doc.cursors.mergeCursors();
}

fn cmdCursorWordRightSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        if (!c.hasSelection()) c.startSelection();
        c.moveWordRight(&doc.buffer);
    }
}

fn cmdCursorWordLeftSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        if (!c.hasSelection()) c.startSelection();
        c.moveWordLeft(&doc.buffer);
    }
}

// --- Word delete ---

fn cmdDeleteWordForward(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().deleteWordForward() catch {};
}

fn cmdDeleteWordBackward(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().deleteWordBackward() catch {};
}

// --- Line operations ---

fn cmdDeleteLine(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().deleteLine() catch {};
}

fn cmdDuplicateLine(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().duplicateLine() catch {};
}

fn cmdMoveLineUp(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().moveLineUp() catch {};
}

fn cmdMoveLineDown(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().moveLineDown() catch {};
}

// --- Smart Home ---

fn cmdSmartHome(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.moveSmartHome(&doc.buffer);
    }
    doc.cursors.mergeCursors();
}

fn cmdSmartHomeSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    for (doc.cursors.cursors.items) |*c| {
        if (!c.hasSelection()) c.startSelection();
        c.moveSmartHome(&doc.buffer);
    }
}

// --- Indent / Dedent ---

fn cmdIndent(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    if (editor.use_tabs) {
        doc.insertAtAllCursors("\t") catch {};
    } else {
        const spaces = "                "; // 16 spaces max
        const width = @min(editor.tab_width, 16);
        doc.insertAtAllCursors(spaces[0..width]) catch {};
    }
}

fn cmdDedent(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().dedentLine(editor.tab_width) catch {};
}

// --- Comment toggle ---

fn cmdToggleComment(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    const lang = doc.language orelse {
        editor.status_message = "Comment toggle: no language detected for this file";
        return;
    };
    // Prefer line comments; fall back to wrapping each line in block
    // markers for languages without them (CSS, HTML).
    if (lang.line_comment) |lc| {
        doc.toggleComment(lc, null) catch {};
    } else if (lang.block_comment_start) |bs| {
        if (lang.block_comment_end) |be| {
            doc.toggleComment(bs, be) catch {};
        } else {
            editor.status_message = "Comment toggle: language has no comment syntax";
        }
    } else {
        editor.status_message = "Comment toggle: language has no comment syntax";
    }
}

// --- Extensions ---

fn cmdReloadExtensions(editor: *Editor, _: ?[]const u8) void {
    lua_api.reloadExtensions(editor);
}

// --- File tree ---

fn cmdToggleFiletree(editor: *Editor, _: ?[]const u8) void {
    editor.toggleFiletree();
}

fn cmdFiletreeRefresh(editor: *Editor, _: ?[]const u8) void {
    const ft = editor.ensureFiletree() orelse return;
    ft.refresh() catch |err| {
        const msg = std.fmt.bufPrint(&editor.status_buf, "File tree refresh failed: {s}", .{@errorName(err)}) catch "Refresh failed";
        editor.status_message = msg;
        return;
    };
    ft.gitRefresh();
    editor.status_message = "File tree refreshed";
}

fn cmdFiletreeRootUp(editor: *Editor, _: ?[]const u8) void {
    editor.filetreeRootUp();
}

fn cmdFiletreeReveal(editor: *Editor, _: ?[]const u8) void {
    const ft = editor.ensureFiletree() orelse return;
    const doc = editor.activeDoc();
    const path = doc.file_path orelse {
        editor.status_message = "Reveal: current tab has no file on disk";
        return;
    };
    // Absolute paths map through the root; relative ones (CLI-opened) are
    // tried as-is since the default root is the same cwd.
    var rel_owned: ?[]u8 = ft.relFromAbs(editor.allocator, path) catch null;
    if (rel_owned == null and !std.fs.path.isAbsolute(path)) {
        const r = editor.allocator.dupe(u8, path) catch return;
        filetree_mod.normalizeSeps(r);
        rel_owned = r;
    }
    const rel = rel_owned orelse {
        editor.status_message = "Reveal: file is outside the tree root";
        return;
    };
    defer editor.allocator.free(rel);
    editor.filetree_visible = true;
    const found = ft.expandToPath(rel) catch null;
    if (found != null) {
        editor.filetree_focused = true;
    } else {
        editor.status_message = "Reveal: file not found under the tree root";
    }
}

// --- TODO navigation ---

fn cmdNextTodo(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    const content = doc.buffer.slice(0, doc.buffer.byteLen());
    if (content.len == 0) {
        editor.status_message = "No TODO markers found";
        return;
    }
    const c = doc.cursors.primary();
    const from = @min(c.offset + 1, content.len);
    var wrapped = false;
    var found = findTodoMarker(content, from);
    if (found == null and from > 0) {
        found = findTodoMarker(content, 0);
        wrapped = true;
    }
    if (found) |pos| {
        doc.cursors.clearSecondary();
        c.clearSelection();
        c.offset = pos;
        c.preferred_col = doc.buffer.offsetToPos(pos).col;
        editor.status_message = if (wrapped) "TODO search wrapped" else "";
    } else {
        editor.status_message = "No TODO markers found";
    }
}

/// Earliest word-boundary occurrence of any TODO-style marker at or after `from`.
fn findTodoMarker(content: []const u8, from: usize) ?usize {
    if (from >= content.len) return null;
    var best: ?usize = null;
    for (syntax.todo_markers) |m| {
        var search_from = from;
        while (std.mem.indexOf(u8, content[search_from..], m)) |rel| {
            const pos = search_from + rel;
            const before_ok = pos == 0 or !isWordCharByte(content[pos - 1]);
            const after_ok = pos + m.len >= content.len or !isWordCharByte(content[pos + m.len]);
            if (before_ok and after_ok) {
                if (best == null or pos < best.?) best = pos;
                break;
            }
            search_from = pos + 1;
        }
    }
    return best;
}

// --- File start/end ---

fn cmdCursorFileStart(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
    c.clearSelection();
    c.moveToStart();
}

fn cmdCursorFileEnd(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
    c.clearSelection();
    c.moveToEnd(&doc.buffer);
}

fn cmdCursorFileStartSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
    if (!c.hasSelection()) c.startSelection();
    c.moveToStart();
}

fn cmdCursorFileEndSelect(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
    if (!c.hasSelection()) c.startSelection();
    c.moveToEnd(&doc.buffer);
}

// --- Auto-indent newline ---

fn cmdInsertNewlineAuto(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();

    // Multi-cursor: just insert plain newline (auto-indent per cursor is complex)
    if (doc.cursors.count() > 1) {
        doc.insertAtAllCursors("\n") catch {};
        return;
    }

    const pos = doc.cursorPos();
    const line = doc.lineContent(pos.line);

    // Count leading whitespace on current line
    var indent_len: usize = 0;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') {
            indent_len += 1;
        } else break;
    }

    // Build newline + indent string
    var buf: [256]u8 = undefined;
    buf[0] = '\n';
    const copy_len = @min(indent_len, buf.len - 1);
    if (copy_len > 0) {
        @memcpy(buf[1 .. 1 + copy_len], line[0..copy_len]);
    }
    doc.insertAtCursor(buf[0 .. 1 + copy_len]) catch {};
}

// --- Multi-cursor commands ---

fn cmdAddCursorBelow(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    // Find the cursor on the lowest (highest line number) line
    var max_line: usize = 0;
    var ref_col: usize = doc.cursors.primary().preferred_col;
    for (doc.cursors.cursors.items) |c| {
        const p = doc.buffer.offsetToPos(c.offset);
        if (p.line > max_line) {
            max_line = p.line;
            ref_col = c.preferred_col;
        }
    }
    if (max_line + 1 >= doc.buffer.lineCount()) return;
    const target_line_len = doc.buffer.lineContent(max_line + 1).len;
    const col = @min(ref_col, target_line_len);
    const new_offset = doc.buffer.posToOffset(max_line + 1, col);
    doc.cursors.addCursor(new_offset) catch {};
}

fn cmdAddCursorAbove(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    // Find the cursor on the highest (lowest line number) line
    var min_line: usize = std.math.maxInt(usize);
    var ref_col: usize = doc.cursors.primary().preferred_col;
    for (doc.cursors.cursors.items) |c| {
        const p = doc.buffer.offsetToPos(c.offset);
        if (p.line < min_line) {
            min_line = p.line;
            ref_col = c.preferred_col;
        }
    }
    if (min_line == 0) return;
    const target_line_len = doc.buffer.lineContent(min_line - 1).len;
    const col = @min(ref_col, target_line_len);
    const new_offset = doc.buffer.posToOffset(min_line - 1, col);
    doc.cursors.addCursor(new_offset) catch {};
}

fn cmdAddNextOccurrence(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    const c = doc.cursors.primary();

    // If no selection, select the word under cursor first
    if (!c.hasSelection()) {
        const content = doc.buffer.slice(0, doc.buffer.byteLen());
        if (c.offset >= content.len) return;
        if (!isWordCharByte(content[c.offset])) return;
        // Find word boundaries
        var word_start = c.offset;
        while (word_start > 0 and isWordCharByte(content[word_start - 1])) word_start -= 1;
        var word_end = c.offset;
        while (word_end < content.len and isWordCharByte(content[word_end])) word_end += 1;
        if (word_end == word_start) return;
        c.anchor = word_start;
        c.offset = word_end;
        return;
    }

    const range = c.selectionRange() orelse return;
    // Dupe the needle: slice() may return the buffer's shared scratch, which
    // the full-content slice() below would overwrite/invalidate.
    const needle_ref = doc.buffer.slice(range.start, range.end);
    if (needle_ref.len == 0) return;
    const needle = editor.allocator.dupe(u8, needle_ref) catch return;
    defer editor.allocator.free(needle);

    // Find the furthest selection end among all cursors to search from there
    var search_start: usize = range.end;
    for (doc.cursors.cursors.items) |sc| {
        if (sc.selectionRange()) |sr| {
            if (sr.end > search_start) search_start = sr.end;
        }
    }

    // Search forward from furthest selection end, then wrap around
    const content = doc.buffer.slice(0, doc.buffer.byteLen());
    var found: ?usize = null;
    if (search_start < content.len) {
        if (std.mem.indexOf(u8, content[search_start..], needle)) |idx| {
            found = search_start + idx;
        }
    }
    // Wrap around
    if (found == null) {
        if (std.mem.indexOf(u8, content[0..range.start], needle)) |idx| {
            found = idx;
        }
    }

    if (found) |match_start| {
        // Add cursor at end of match, with selection covering the match
        const match_end = match_start + needle.len;
        // Check no cursor already exists at this position
        for (doc.cursors.cursors.items) |existing| {
            if (existing.offset == match_end) return;
        }
        doc.cursors.addCursor(match_end) catch return;
        // Set the new cursor's anchor to select the match
        const new_cursor = &doc.cursors.cursors.items[doc.cursors.count() - 1];
        new_cursor.anchor = match_start;
    }
}

fn cmdEscapeMulticursor(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().cursors.clearSecondary();
}

fn cmdSplitVertical(editor: *Editor, _: ?[]const u8) void {
    _ = editor.execAction("split_vertical");
}

fn cmdSplitHorizontal(editor: *Editor, _: ?[]const u8) void {
    _ = editor.execAction("split_horizontal");
}

fn cmdClosePane(editor: *Editor, _: ?[]const u8) void {
    _ = editor.execAction("close_pane");
}

fn cmdFocusNextPane(editor: *Editor, _: ?[]const u8) void {
    _ = editor.execAction("focus_next_pane");
}

fn cmdFocusPrevPane(editor: *Editor, _: ?[]const u8) void {
    _ = editor.execAction("focus_prev_pane");
}

fn isWordCharByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

// ---- Theme commands ----

fn setGuiTheme(editor: *Editor, name: []const u8, preset: theme_mod.EditorTheme, syn: theme_mod.SyntaxTheme) void {
    editor.theme = preset;
    // Keep syntax colors in step — previously only the Lua config path set
    // them, so live theme switches left a stale syntax palette.
    editor.syntax_theme = syn;
    editor.theme_name = name;
    var val_buf: [32]u8 = undefined;
    const quoted = std.fmt.bufPrint(&val_buf, "\"{s}\"", .{name}) catch return;
    lua_settings.writeSettingToFile("theme", quoted) catch {};
}

fn setTuiTheme(editor: *Editor, name: []const u8, preset: theme_mod.TuiTheme, syn: theme_mod.TuiSyntaxTheme) void {
    editor.tui_theme = preset;
    editor.tui_syntax_theme = syn;
    editor.tui_theme_name = name;
    var val_buf: [32]u8 = undefined;
    const quoted = std.fmt.bufPrint(&val_buf, "\"{s}\"", .{name}) catch return;
    lua_settings.writeSettingToFile("tui_theme", quoted) catch {};
}

fn cmdThemeDark(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "dark", theme_mod.gui_dark, theme_mod.syn_gui_dark);
    setTuiTheme(editor, "dark", theme_mod.tui_dark, theme_mod.syn_tui_dark);
}

fn cmdThemeLight(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "light", theme_mod.gui_light, theme_mod.syn_gui_light);
    setTuiTheme(editor, "light", theme_mod.tui_light, theme_mod.syn_tui_light);
}

fn cmdThemeHighContrast(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "high_contrast", theme_mod.gui_high_contrast, theme_mod.syn_gui_high_contrast);
    setTuiTheme(editor, "high_contrast", theme_mod.tui_high_contrast, theme_mod.syn_tui_high_contrast);
}

fn cmdThemeTerminal(editor: *Editor, _: ?[]const u8) void {
    setTuiTheme(editor, "terminal", theme_mod.tui_terminal, theme_mod.syn_tui_terminal);
}

// GUI-only theme commands (don't touch TUI theme)
fn cmdGuiThemeDark(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "dark", theme_mod.gui_dark, theme_mod.syn_gui_dark);
}
fn cmdGuiThemeLight(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "light", theme_mod.gui_light, theme_mod.syn_gui_light);
}
fn cmdGuiThemeHighContrast(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "high_contrast", theme_mod.gui_high_contrast, theme_mod.syn_gui_high_contrast);
}

// TUI-only theme commands (don't touch GUI theme)
fn cmdTuiThemeDark(editor: *Editor, _: ?[]const u8) void {
    setTuiTheme(editor, "dark", theme_mod.tui_dark, theme_mod.syn_tui_dark);
}
fn cmdTuiThemeLight(editor: *Editor, _: ?[]const u8) void {
    setTuiTheme(editor, "light", theme_mod.tui_light, theme_mod.syn_tui_light);
}
fn cmdTuiThemeHighContrast(editor: *Editor, _: ?[]const u8) void {
    setTuiTheme(editor, "high_contrast", theme_mod.tui_high_contrast, theme_mod.syn_tui_high_contrast);
}

// ---- Tests ----

test "add_next_occurrence with selection spanning the gap" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("xx ab ab ab");

    // Park the gap at offset 5 (inside the upcoming selection) by editing there
    doc.cursors.primary().offset = 5;
    try doc.insertAtCursor("X");
    _ = try doc.undoAction();
    try std.testing.expectEqualStrings("xx ab ab ab", doc.buffer.slice(0, doc.buffer.byteLen()));

    // Select "b a" (4..7) — spans the gap, so slice() returns the scratch buffer
    const c = doc.cursors.primary();
    c.offset = 4;
    c.startSelection();
    c.offset = 7;

    cmdAddNextOccurrence(&editor, null);
    try std.testing.expectEqual(@as(usize, 2), editor.activeDoc().cursors.count());
    const new_c = editor.activeDoc().cursors.cursors.items[1];
    try std.testing.expectEqual(@as(usize, 10), new_c.offset);
    try std.testing.expectEqual(@as(usize, 7), new_c.anchor.?);
}

test "add_next_occurrence selects word then finds next" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();
    try editor.activeDoc().loadText("hello world hello there");

    // Place cursor on "hello" (offset 0)
    editor.activeDoc().cursors.primary().offset = 0;
    editor.activeDoc().cursors.primary().clearSelection();

    // First Ctrl+D: should select the word "hello"
    cmdAddNextOccurrence(&editor, null);
    try std.testing.expect(editor.activeDoc().cursors.primary().hasSelection());
    const r1 = editor.activeDoc().cursors.primary().selectionRange().?;
    try std.testing.expectEqual(@as(usize, 0), r1.start);
    try std.testing.expectEqual(@as(usize, 5), r1.end);

    // Second Ctrl+D: should add cursor at second "hello"
    cmdAddNextOccurrence(&editor, null);
    try std.testing.expectEqual(@as(usize, 2), editor.activeDoc().cursors.count());
    // New cursor should be at end of second "hello" (offset 17) with selection
    const new_c = &editor.activeDoc().cursors.cursors.items[1];
    try std.testing.expectEqual(@as(usize, 17), new_c.offset);
    try std.testing.expectEqual(@as(usize, 12), new_c.anchor.?);
}
