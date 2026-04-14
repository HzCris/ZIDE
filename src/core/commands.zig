const std = @import("std");
const Allocator = std.mem.Allocator;
const theme_mod = @import("theme.zig");
const lua_settings = @import("lua_settings.zig");

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
};

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
        cmd.execute(editor, args);
        return true;
    }

    /// Get a sorted list of all command names (for command palette).
    /// Returns a cached slice — caller must NOT free it.
    pub fn allNames(self: *CommandRegistry) ![][]const u8 {
        if (self.cached_names) |names| return names;
        var names = try std.ArrayList([]const u8).initCapacity(self.allocator, self.commands.count());
        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            names.appendAssumeCapacity(entry.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        self.cached_names = names.items;
        return names.items;
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
    const needle = doc.buffer.slice(range.start, range.end);
    if (needle.len == 0) return;

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

fn setGuiTheme(editor: *Editor, name: []const u8, preset: theme_mod.EditorTheme) void {
    editor.theme = preset;
    editor.theme_name = name;
    var val_buf: [32]u8 = undefined;
    const quoted = std.fmt.bufPrint(&val_buf, "\"{s}\"", .{name}) catch return;
    lua_settings.writeSettingToFile("theme", quoted) catch {};
}

fn setTuiTheme(editor: *Editor, name: []const u8, preset: theme_mod.TuiTheme) void {
    editor.tui_theme = preset;
    editor.tui_theme_name = name;
    var val_buf: [32]u8 = undefined;
    const quoted = std.fmt.bufPrint(&val_buf, "\"{s}\"", .{name}) catch return;
    lua_settings.writeSettingToFile("tui_theme", quoted) catch {};
}

fn cmdThemeDark(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "dark", theme_mod.gui_dark);
    setTuiTheme(editor, "dark", theme_mod.tui_dark);
}

fn cmdThemeLight(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "light", theme_mod.gui_light);
    setTuiTheme(editor, "light", theme_mod.tui_light);
}

fn cmdThemeHighContrast(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "high_contrast", theme_mod.gui_high_contrast);
    setTuiTheme(editor, "high_contrast", theme_mod.tui_high_contrast);
}

fn cmdThemeTerminal(editor: *Editor, _: ?[]const u8) void {
    setTuiTheme(editor, "terminal", theme_mod.tui_terminal);
}

// GUI-only theme commands (don't touch TUI theme)
fn cmdGuiThemeDark(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "dark", theme_mod.gui_dark);
}
fn cmdGuiThemeLight(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "light", theme_mod.gui_light);
}
fn cmdGuiThemeHighContrast(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "high_contrast", theme_mod.gui_high_contrast);
}

// TUI-only theme commands (don't touch GUI theme)
fn cmdTuiThemeDark(editor: *Editor, _: ?[]const u8) void {
    setTuiTheme(editor, "dark", theme_mod.tui_dark);
}
fn cmdTuiThemeLight(editor: *Editor, _: ?[]const u8) void {
    setTuiTheme(editor, "light", theme_mod.tui_light);
}
fn cmdTuiThemeHighContrast(editor: *Editor, _: ?[]const u8) void {
    setTuiTheme(editor, "high_contrast", theme_mod.tui_high_contrast);
}

// ---- Tests ----

test "add_next_occurrence selects word then finds next" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator);
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
