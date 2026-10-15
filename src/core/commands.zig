const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const theme_mod = @import("theme.zig");
const lua_settings = @import("lua_settings.zig");
const lua_api = @import("lua_api.zig");
const syntax = @import("syntax.zig");
const brackets = @import("brackets.zig");
const filetree_mod = @import("filetree.zig");
const cursor_mod = @import("cursor.zig");
const review_reader = @import("review_reader.zig");
const Document = @import("document.zig").Document;

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
    /// Name and description are borrowed from the snippet registry.
    snippet: bool = false,
};

/// Placeholder for Lua-backed commands; never invoked (execute() routes
/// lua_ref entries through lua_api before reaching the fn pointer).
fn cmdLuaStub(_: *Editor, _: ?[]const u8) void {}

/// Registry of named commands. All editor actions go through this.
pub const CommandRegistry = struct {
    commands: std.StringHashMapUnmanaged(Command),
    /// Owned Lua overrides; the underlying built-in/snippet stays registered.
    lua_commands: std.StringHashMapUnmanaged(Command) = .empty,
    allocator: Allocator,
    /// Cached sorted command names (invalidated on register).
    cached_names: ?[][]const u8 = null,
    /// Binds warnIfUnknownAction has warned about (tests read it).
    unknown_action_warnings: u32 = 0,

    pub fn init(allocator: Allocator) CommandRegistry {
        return .{
            .commands = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.invalidateCache();
        var iter = self.lua_commands.valueIterator();
        while (iter.next()) |cmd| {
            self.allocator.free(cmd.name);
            self.allocator.free(cmd.description);
        }
        self.lua_commands.deinit(self.allocator);
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
        return self.lua_commands.getPtr(name) orelse self.commands.getPtr(name);
    }

    /// Whether a keybinding to `name` can run something: any registered
    /// command — built-in, snippet or Lua. `Editor.execAction`'s own
    /// actions (save, quit, find, …) are registered too (see
    /// `exec_action_commands`), so they count.
    pub fn isKnownAction(self: *const CommandRegistry, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// Log a warning when `key` is being bound to an action no command
    /// answers to. The binding still stands — a Lua command registered later
    /// (an extension loads after init.lua) makes it work — but a typo no
    /// longer fails silently. For `zide.bind` and other user-facing binders.
    pub fn warnIfUnknownAction(self: *CommandRegistry, key: []const u8, action: []const u8) void {
        if (self.isKnownAction(action)) return;
        self.unknown_action_warnings +|= 1;
        std.log.warn("keybind '{s}': no command named '{s}' is registered (yet) — the key does nothing until one is", .{ key, action });
    }

    /// Execute a command by name. Returns false if command not found.
    pub fn execute(self: *const CommandRegistry, editor: *Editor, name: []const u8, args: ?[]const u8) bool {
        editor.validateSnippetState();
        defer editor.validateSnippetState();
        defer reportRefusedEdit(editor);
        const cmd = self.get(name) orelse return false;
        if (cmd.snippet) {
            editor.insertSnippetCommand(name);
            return true;
        }
        if (cmd.lua_ref) |r| {
            lua_api.callLuaCommand(editor, r, args);
            return true;
        }
        cmd.execute(editor, args);
        return true;
    }

    /// One status message for an edit the document refused (read-only),
    /// whatever command tried it; the edit sites' own `catch` messages are
    /// overwritten here, after the command ran.
    fn reportRefusedEdit(editor: *Editor) void {
        const doc = editor.activeDoc();
        if (!doc.edit_refused) return;
        doc.edit_refused = false;
        editor.status_message = if (doc.reader != null) "Read-only review view — Enter opens the real file" else "Read-only document";
    }

    pub fn registerSnippet(self: *CommandRegistry, name: []const u8, description: []const u8) !void {
        if (self.commands.get(name)) |old| {
            if (!old.snippet) return error.CommandConflict;
        } else if (self.lua_commands.contains(name)) return error.CommandConflict;
        try self.commands.ensureUnusedCapacity(self.allocator, 1);
        _ = self.commands.remove(name);
        self.commands.putAssumeCapacity(name, .{ .name = name, .description = description, .execute = cmdLuaStub, .snippet = true });
        self.invalidateCache();
    }

    pub fn removeSnippet(self: *CommandRegistry, name: []const u8) void {
        if (self.commands.get(name)) |cmd| if (cmd.snippet) {
            _ = self.commands.remove(name);
            self.invalidateCache();
        };
    }

    /// Register a Lua-backed command. Takes ownership of `name` and
    /// `description` (allocated with this registry's allocator) on
    /// success; on error the caller still owns them. Returns the previous
    /// Lua ref when replacing a Lua command — the caller must unref it.
    /// Replacing a built-in is allowed (Lite XL style) and logged.
    pub fn registerLua(self: *CommandRegistry, name: []const u8, description: []const u8, lua_ref: i32) !?i32 {
        // Complete the only fallible step before releasing the old entry.
        try self.lua_commands.ensureUnusedCapacity(self.allocator, 1);
        self.invalidateCache();
        var prev_ref: ?i32 = null;
        if (self.lua_commands.fetchRemove(name)) |kv| {
            prev_ref = kv.value.lua_ref;
            self.allocator.free(kv.value.name);
            self.allocator.free(kv.value.description);
        } else if (self.commands.contains(name)) {
            std.log.warn("zide.command: '{s}' overrides an existing command", .{name});
        }
        self.lua_commands.putAssumeCapacity(name, .{
            .name = name,
            .description = description,
            .execute = cmdLuaStub,
            .lua_ref = lua_ref,
        });
        self.invalidateCache();
        return prev_ref;
    }

    /// Remove all Lua-backed commands, freeing their owned strings.
    /// Release references synchronously without allocating during cleanup.
    /// The callback must not mutate this registry.
    pub fn removeLuaCommands(self: *CommandRegistry, context: anytype, comptime release_ref: fn (@TypeOf(context), i32) void) void {
        self.invalidateCache();
        var it = self.lua_commands.valueIterator();
        while (it.next()) |cmd| {
            release_ref(context, cmd.lua_ref.?);
            self.allocator.free(cmd.name);
            self.allocator.free(cmd.description);
        }
        self.lua_commands.clearRetainingCapacity();
    }

    /// Get a sorted list of all command names (for command palette).
    /// Returns a cached slice — caller must NOT free it.
    pub fn allNames(self: *CommandRegistry) ![][]const u8 {
        if (self.cached_names) |names| return names;
        var names = try std.ArrayList([]const u8).initCapacity(self.allocator, self.count());
        errdefer names.deinit(self.allocator);
        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            if (!self.lua_commands.contains(entry.key_ptr.*)) names.appendAssumeCapacity(entry.key_ptr.*);
        }
        var overrides = self.lua_commands.keyIterator();
        while (overrides.next()) |name| names.appendAssumeCapacity(name.*);
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
        var total = self.commands.count();
        var iter = self.lua_commands.keyIterator();
        while (iter.next()) |name| if (!self.commands.contains(name.*)) {
            total += 1;
        };
        return total;
    }
};

test "command override allocation failures preserve the existing command and palette" {
    const old_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = old_level;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn probe(a: Allocator) !void {
            var registry = CommandRegistry.init(a);
            defer registry.deinit();
            try registry.register("base", "Built-in", cmdLuaStub);
            _ = try registry.allNames();
            const name = try a.dupe(u8, "base");
            const description = a.dupe(u8, "Override") catch |err| {
                a.free(name);
                return err;
            };
            _ = registry.registerLua(name, description, 42) catch |err| {
                a.free(name);
                a.free(description);
                try std.testing.expect(registry.get("base").?.lua_ref == null);
                try std.testing.expectEqual(@as(usize, 1), registry.count());
                try std.testing.expectEqualStrings("base", registry.cached_names.?[0]);
                return err;
            };
            try std.testing.expectEqual(@as(?i32, 42), registry.get("base").?.lua_ref);
            var released: usize = 0;
            registry.removeLuaCommands(&released, struct {
                fn release(count: *usize, ref: i32) void {
                    std.debug.assert(ref == 42);
                    count.* += 1;
                }
            }.release);
            try std.testing.expectEqual(@as(usize, 1), released);
            try std.testing.expect(registry.get("base").?.lua_ref == null);
            try std.testing.expectEqualStrings("Built-in", registry.get("base").?.description);
        }
    }.probe, .{});
}

/// Actions `Editor.execAction` implements itself, registered as commands so
/// the palette (and `isKnownAction`) sees them. (The pane and window
/// actions it also handles have their own `cmd*` entries below.)
const exec_action_commands = [_]struct { name: []const u8, description: []const u8 }{
    .{ .name = "new_document", .description = "Open a new untitled document" },
    .{ .name = "file_open", .description = "Open a file by path" },
    .{ .name = "save", .description = "Save the current document" },
    .{ .name = "save_as", .description = "Save the current document under a new name" },
    .{ .name = "close_tab", .description = "Close the current tab (asks about unsaved changes)" },
    .{ .name = "next_doc", .description = "Switch to the next tab" },
    .{ .name = "prev_doc", .description = "Switch to the previous tab" },
    .{ .name = "quit", .description = "Quit ZIDE (asks about unsaved changes)" },
    .{ .name = "find", .description = "Find in the current document" },
    .{ .name = "find_replace", .description = "Find and replace in the current document" },
    .{ .name = "goto_line", .description = "Go to a line number" },
    .{ .name = "command_palette", .description = "Open the command palette" },
    .{ .name = "settings", .description = "Open the settings dialog (GUI)" },
    .{ .name = "toggle_terminal", .description = "Open a terminal below, or go back from a terminal to the editor" },
    .{ .name = "open_terminal_right", .description = "Open a terminal in a split to the right" },
    .{ .name = "close_terminal", .description = "Close the focused terminal pane" },
    .{ .name = "lsp_completion", .description = "Show language-server completions at the cursor" },
    .{ .name = "lsp_goto_definition", .description = "Go to the definition of the symbol at the cursor" },
    .{ .name = "navigate_back", .description = "Go back to where the caret was before the last jump" },
    .{ .name = "navigate_forward", .description = "Go forward again after navigate_back" },
    .{ .name = "reopen_closed_tab", .description = "Reopen the most recently closed file" },
    .{ .name = "open_folder", .description = "Open a folder as the project (file tree root and language-server workspace)" },
    .{ .name = "recent_projects", .description = "Pick a recently opened project folder" },
};

/// A command that runs `Editor.execAction(name)`. execAction handles its own
/// action names before it falls back to the registry, so this never
/// recurses — keep it that way when changing execAction.
fn execActionCommand(comptime name: []const u8) CommandFn {
    return struct {
        fn run(editor: *Editor, _: ?[]const u8) void {
            _ = editor.execAction(name);
        }
    }.run;
}

/// Register all built-in editor commands.
pub fn registerBuiltins(registry: *CommandRegistry) !void {
    inline for (exec_action_commands) |c| {
        try registry.register(c.name, c.description, execActionCommand(c.name));
    }
    try registry.register("snippet_expand", "Expand the exact snippet trigger before the cursor", cmdSnippetExpand);
    try registry.register("snippet_next", "Visit the next snippet placeholder", cmdSnippetNext);
    try registry.register("snippet_previous", "Visit the previous snippet placeholder", cmdSnippetPrevious);
    try registry.register("snippet_cancel", "End snippet navigation", cmdSnippetCancel);
    try registry.register("recover_documents", "Recover unsaved documents from a previous instance", cmdRecover);
    try registry.register("run_task", "Choose and run a registered task", cmdRunTask);
    try registry.register("task_output", "Show the latest task output", cmdTaskOutput);
    try registry.register("rerun_task", "Rerun the latest task", cmdRerunTask);
    try registry.register("stop_task", "Cancel the latest task and its child processes", cmdStopTask);
    try registry.register("problems", "Show workspace problems", cmdProblems);
    try registry.register("git_changes", "Show staged and working tree changes", cmdGitChanges);
    try registry.register("debug", "Show debugger controls and views", cmdDebug);
    try registry.register("debug_start", "Choose a launch or attach configuration", cmdDebugStart);
    try registry.register("toggle_breakpoint", "Toggle a source breakpoint at the cursor", cmdBreakpoint);
    try registry.register("debug_continue", "Continue the stopped debuggee", cmdDebugContinue);
    try registry.register("debug_pause", "Pause the running debuggee", cmdDebugPause);
    try registry.register("debug_step_over", "Step over the current statement", cmdDebugNext);
    try registry.register("debug_step_in", "Step into the current call", cmdDebugIn);
    try registry.register("debug_step_out", "Step out of the current frame", cmdDebugOut);
    try registry.register("debug_stop", "Stop a launched program or detach from an attached target", cmdDebugStop);
    try registry.register("debug_terminate", "Explicitly terminate the debug target when supported", cmdDebugTerminate);
    try registry.register("git_refresh", "Refresh workspace Git status", cmdGitRefresh);
    try registry.register("git_stage", "Stage the selected file's saved contents", cmdGitStage);
    try registry.register("git_unstage", "Unstage the selected file", cmdGitUnstage);
    try registry.register("review", "Review changed files: verdicts, progress and baseline (Review view)", cmdReview);
    try registry.register("review_approve", "Approve the selected changed file (also stages it); press again to clear", cmdReviewApprove);
    try registry.register("review_needs_work", "Mark the selected changed file as needing work; press again to clear", cmdReviewNeedsWork);
    try registry.register("review_next_file", "Open the next changed file", cmdReviewNextFile);
    try registry.register("review_prev_file", "Open the previous changed file", cmdReviewPrevFile);
    try registry.register("review_set_baseline", "Pin the current commit as the review baseline (checkpoint)", cmdReviewSetBaseline);
    try registry.register("review_follow_head", "Compare changed files with the last commit again", cmdReviewFollowHead);
    try registry.register("review_open_reader", "Read the selected changed file: tints, ghost lines, real line numbers", cmdReviewOpenReader);
    try registry.register("review_next_change", "Move to the next change in the review reader", cmdReviewNextChange);
    try registry.register("review_prev_change", "Move to the previous change in the review reader", cmdReviewPrevChange);
    try registry.register("review_toggle_view", "Switch between the review reader and the classic diff", cmdReviewToggleView);
    try registry.register("review_expand_all", "Review reader: show every collapsed unchanged stretch", cmdReviewExpandAll);
    try registry.register("review_collapse_all", "Review reader: fold the unchanged stretches again", cmdReviewCollapseAll);
    try registry.register("next_problem", "Open the next problem", cmdNextProblem);
    try registry.register("previous_problem", "Open the previous problem", cmdPreviousProblem);
    try registry.register("hover", "Show language-server information at the cursor", cmdHover);
    try registry.register("rename_symbol", "Rename a symbol with a workspace edit preview", cmdRenameSymbol);
    try registry.register("lsp_references", "Find every reference to the symbol at the cursor (References view)", cmdLspReferences);
    try registry.register("references", "Show the last References view", cmdReferences);
    try registry.register("lsp_document_symbols", "Go to a symbol in this file (picker)", cmdLspDocumentSymbols);
    try registry.register("lsp_workspace_symbols", "Search symbols across the workspace (picker)", cmdLspWorkspaceSymbols);
    try registry.register("lsp_signature_help", "Show the signature of the call at the cursor", cmdLspSignatureHelp);
    try registry.register("lsp_stderr", "Show what the language servers wrote to stderr (read-only tab)", cmdLspStderr);
    try registry.register("open_log", "Open zide.log (reloads as it grows)", cmdOpenLog);
    try registry.register("format_document", "Format the current document with its language server", cmdFormatDocument);
    try registry.register("format_selection", "Format the selected range when supported", cmdFormatSelection);
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
    try registry.register("goto_matching_bracket", "Jump to the bracket matching the one at the cursor", cmdGotoMatchingBracket);
    try registry.register("open_documentation", "Open ZIDE documentation (docs/Documentation.md)", cmdOpenDocumentation);
    try registry.register("file_encoding", "Choose file encoding", cmdFileEncoding);
    try registry.register("reopen_with_encoding", "Reopen with Encoding", cmdReopenEncoding);
    try registry.register("save_with_encoding", "Save with Encoding", cmdSaveEncoding);
    try registry.register("quick_open", "Fuzzy-find a file in the workspace (live preview)", cmdQuickOpen);
    try registry.register("find_in_files", "Search & replace across the workspace (results panel)", cmdFindInFiles);
    try registry.register("next_result", "Jump to the next workspace search result", cmdNextResult);
    try registry.register("prev_result", "Jump to the previous workspace search result", cmdPrevResult);
    try registry.register("reload_extensions", "Reload Lua extensions (re-runs extensions/*.lua)", cmdReloadExtensions);
    try registry.register("lsp_restart", "Restart language servers (re-reads registrations, clears failures)", cmdLspRestart);
    // File tree commands
    try registry.register("toggle_filetree", "Toggle the file tree side panel", cmdToggleFiletree);
    try registry.register("toggle_snippets", "Toggle the Snippets side panel (syntax skeletons by plain name)", cmdToggleSnippets);
    try registry.register("filetree_reveal", "Reveal the current file in the file tree", cmdFiletreeReveal);
    try registry.register("filetree_refresh", "Refresh the file tree from disk", cmdFiletreeRefresh);
    try registry.register("filetree_root_up", "Re-root the file tree at the parent directory", cmdFiletreeRootUp);
    try registry.register("filetree_set_root", "Open the selected folder as the project root", cmdFiletreeSetRoot);
    try registry.register("filetree_collapse_all", "Collapse all file tree folders", cmdFiletreeCollapseAll);
    try registry.register("filetree_copy_path", "Copy the selected file tree entry's absolute path", cmdFiletreeCopyPath);
    try registry.register("filetree_copy_relative_path", "Copy the selected file tree entry's root-relative path", cmdFiletreeCopyRelPath);
    try registry.register("filetree_reveal_explorer", "Show the selected file tree entry in the system file manager", cmdFiletreeRevealExplorer);
    try registry.register("toggle_tui_icons", "Toggle nerdfont icons in the TUI file tree (persists to init.lua)", cmdToggleTuiIcons);
    try registry.register("filetree_copy", "Copy the selected file tree entries to the file clipboard", cmdFiletreeClipCopy);
    try registry.register("filetree_cut", "Cut the selected file tree entries to the file clipboard", cmdFiletreeClipCut);
    try registry.register("filetree_paste", "Paste the file clipboard into the selected folder", cmdFiletreeClipPaste);
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
    // Window commands (GUI; the TUI splits instead)
    try registry.register("open_in_new_window", "Show the current document in a new window (TUI: split)", cmdOpenInNewWindow);
    try registry.register("move_pane_to_new_window", "Move the focused pane into a new window (TUI: split)", cmdMovePaneToNewWindow);
    try registry.register("close_window", "Close this window (main window: quit)", cmdCloseWindow);
    try registry.register("detach_terminal", "Move the focused terminal into its own window (TUI: side split)", cmdDetachTerminal);
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

fn cmdSnippetExpand(editor: *Editor, _: ?[]const u8) void {
    _ = editor.expandSnippet(true);
}
fn cmdSnippetNext(editor: *Editor, _: ?[]const u8) void {
    _ = editor.navigateSnippet(false);
}
fn cmdSnippetPrevious(editor: *Editor, _: ?[]const u8) void {
    _ = editor.navigateSnippet(true);
}
fn cmdSnippetCancel(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().cancelSnippet(true);
    editor.clearCompletionItems();
}

fn cmdInsertChar(editor: *Editor, args: ?[]const u8) void {
    const text = args orelse return;
    if (text.len == 0) return;
    // Whatever the insertion did, the completion popup reacts to the text.
    defer editor.afterTypedText(text);
    const doc = editor.activeDoc();
    const auto_close = editor.autoCloseBracketsFor(doc);

    // Multi-cursor: simple insert at all cursors, skip auto-close complexity
    if (doc.cursors.count() > 1) {
        doc.insertAtAllCursors(text) catch {
            editor.status_message = "Edit failed: out of memory";
        };
        return;
    }

    // Skip-over: if typing a closing bracket and cursor is on that same char, just move right
    if (auto_close and text.len == 1 and !doc.cursors.primary().hasSelection()) {
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

    const closing: ?u8 = if (auto_close and text.len == 1) switch (text[0]) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '\'' => '\'',
        '"' => '"',
        '`' => '`',
        else => null,
    } else null;
    if (closing) |close| pair: {
        if (text[0] == '\'' or text[0] == '"' or text[0] == '`') {
            const c = doc.cursors.primaryConst();
            const start = if (c.selectionRange()) |r| r.start else c.offset;
            if (start > 0) {
                const before = doc.buffer.byteAt(start - 1).?;
                if (std.ascii.isAlphanumeric(before) or before == '_') break :pair;
            }
        }
        doc.beginEdit() catch {
            editor.status_message = "Edit failed: out of memory";
            return;
        };
        defer doc.endEdit();
        doc.insertAtCursor(&.{ text[0], close }) catch {
            editor.status_message = "Edit failed: out of memory";
            return;
        };
        doc.cursors.primary().moveLeft(&doc.buffer);
        return;
    }
    doc.insertAtCursor(text) catch {
        editor.status_message = "Edit failed: out of memory";
    };
}

fn cmdDeleteForward(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().deleteCharacterAll(false) catch {
        editor.status_message = "Edit failed: out of memory";
    };
}

fn cmdDeleteBackward(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().deleteCharacterAll(true) catch {
        editor.status_message = "Edit failed: out of memory";
    };
}

fn cmdInsertNewline(editor: *Editor, _: ?[]const u8) void {
    if (editor.activeDoc().reader != null) return review_reader.activateRow(editor, editor.activeDoc());
    editor.activeDoc().insertAtAllCursors(editor.activeDoc().lineEnding()) catch {
        editor.status_message = "Edit failed: out of memory";
    };
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

const Span = struct { start: usize, end: usize };

fn cursorSpan(c: cursor_mod.Cursor) Span {
    const r = c.selectionRange() orelse return .{ .start = c.offset, .end = c.offset };
    return .{ .start = r.start, .end = r.end };
}

fn spanLess(_: void, a: Span, b: Span) bool {
    return a.start < b.start or (a.start == b.start and a.end < b.end);
}

/// Every cursor's selection in document order (a bare caret is an empty
/// span), overlapping selections merged.
fn selectionSpans(allocator: Allocator, doc: *const Document) !std.ArrayList(Span) {
    var spans = try std.ArrayList(Span).initCapacity(allocator, doc.cursors.count());
    for (doc.cursors.cursors.items) |c| spans.appendAssumeCapacity(cursorSpan(c));
    std.mem.sort(Span, spans.items, {}, spanLess);
    var n: usize = 0;
    for (spans.items) |s| {
        if (n > 0 and s.start < spans.items[n - 1].end) {
            spans.items[n - 1].end = @max(spans.items[n - 1].end, s.end);
        } else {
            spans.items[n] = s;
            n += 1;
        }
    }
    spans.items.len = n;
    return spans;
}

/// Clipboard text of the selections: every cursor's selection in document
/// order joined by the document's line ending. A bare caret among several
/// cursors adds an empty line, so a block selection copies one line per
/// cursor and pastes back one per cursor. Null when nothing is selected.
fn copiedTextAlloc(allocator: Allocator, doc: *Document) !?[]u8 {
    var spans = try selectionSpans(allocator, doc);
    defer spans.deinit(allocator);
    for (spans.items) |s| {
        if (s.end > s.start) break;
    } else return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (spans.items, 0..) |s, i| {
        if (i > 0) try out.appendSlice(allocator, doc.lineEnding());
        // slice() may hand out the buffer's one shared scratch: copy it
        // before the next call.
        try out.appendSlice(allocator, doc.buffer.slice(s.start, s.end));
    }
    return try out.toOwnedSlice(allocator);
}

/// Delete every cursor's selection as one undo step; each cursor ends where
/// its selection started.
fn deleteSelections(allocator: Allocator, doc: *Document) !void {
    var spans = try selectionSpans(allocator, doc);
    defer spans.deinit(allocator);
    var ranges = try std.ArrayList(Document.RangeEdit).initCapacity(allocator, spans.items.len);
    defer ranges.deinit(allocator);
    var i = spans.items.len;
    while (i > 0) {
        i -= 1;
        const s = spans.items[i];
        if (s.end > s.start) ranges.appendAssumeCapacity(.{ .start = s.start, .end = s.end, .text = "" });
    }
    try doc.beginEdit();
    defer doc.endEdit();
    try doc.applyRanges(ranges.items);
    for (doc.cursors.cursors.items) |*c| {
        c.clearSelection();
        c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
    }
    doc.cursors.mergeCursors();
}

fn cmdCopy(editor: *Editor, _: ?[]const u8) void {
    const text = (copiedTextAlloc(editor.allocator, editor.activeDoc()) catch {
        editor.status_message = "Copy failed: out of memory";
        return;
    }) orelse return;
    defer editor.allocator.free(text);
    editor.setClipboard(text);
}

fn cmdCut(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    const text = (copiedTextAlloc(editor.allocator, doc) catch {
        editor.status_message = "Cut failed: out of memory";
        return;
    }) orelse return;
    defer editor.allocator.free(text);
    editor.setClipboard(text);
    deleteSelections(editor.allocator, doc) catch {
        editor.status_message = "Edit failed: out of memory";
    };
}

fn cmdPaste(editor: *Editor, _: ?[]const u8) void {
    const clip = editor.getClipboard();
    if (clip.len == 0) return;
    const doc = editor.activeDoc();
    // Line breaks follow the document: CRLF text from Windows programs
    // landed verbatim in LF files (mixed endings on save), and LF text in
    // CRLF files.
    const converted = withLineEnding(editor.allocator, clip, doc.lineEnding()) catch {
        editor.status_message = "Edit failed: out of memory";
        return;
    };
    defer if (converted) |owned| editor.allocator.free(owned);
    const text = converted orelse clip;
    if (doc.cursors.count() > 1) {
        const distributed = pasteDistributed(editor.allocator, doc, text) catch {
            editor.status_message = "Edit failed: out of memory";
            return;
        };
        if (distributed) return;
    }
    doc.insertAtAllCursors(text) catch {
        editor.status_message = "Edit failed: out of memory";
    };
}

/// `text` with every line break (`\r\n` or `\n`) written as `eol`, or null
/// when it already is (no copy made). A lone `\r` is left alone.
fn withLineEnding(allocator: Allocator, text: []const u8, eol: []const u8) Allocator.Error!?[]u8 {
    const crlf = std.mem.count(u8, text, "\r\n");
    const bare_lf = std.mem.count(u8, text, "\n") - crlf;
    const want_crlf = std.mem.eql(u8, eol, "\r\n");
    if (if (want_crlf) bare_lf == 0 else crlf == 0) return null;
    const out = try allocator.alloc(u8, if (want_crlf) text.len + bare_lf else text.len - crlf);
    var o: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue; // the `\n` writes the break
        if (c == '\n') {
            @memcpy(out[o..][0..eol.len], eol);
            o += eol.len;
        } else {
            out[o] = c;
            o += 1;
        }
    }
    std.debug.assert(o == out.len);
    return out;
}

/// Multi-cursor paste of text holding exactly one line per cursor (what a
/// multi-cursor copy produces; one trailing line break is ignored): the
/// n-th cursor in document order gets the n-th line, as one undo step.
/// Returns false without changing anything when the counts differ or
/// selections overlap — the caller then pastes all of it at every cursor.
fn pasteDistributed(allocator: Allocator, doc: *Document, text: []const u8) !bool {
    var body = text;
    if (std.mem.endsWith(u8, body, "\n")) {
        body = body[0 .. body.len - 1];
        if (std.mem.endsWith(u8, body, "\r")) body = body[0 .. body.len - 1];
    }
    const n = doc.cursors.count();
    if (std.mem.count(u8, body, "\n") + 1 != n) return false;

    // Cursor indices in document order; their spans must not overlap.
    const order = try allocator.alloc(usize, n);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, @as([]const cursor_mod.Cursor, doc.cursors.cursors.items), struct {
        fn less(cursors: []const cursor_mod.Cursor, a: usize, b: usize) bool {
            return spanLess({}, cursorSpan(cursors[a]), cursorSpan(cursors[b]));
        }
    }.less);
    for (order[0 .. n - 1], order[1..]) |a, b| {
        if (cursorSpan(doc.cursors.cursors.items[a]).end > cursorSpan(doc.cursors.cursors.items[b]).start) return false;
    }

    const pieces = try allocator.alloc([]const u8, n);
    defer allocator.free(pieces);
    var lines = std.mem.splitScalar(u8, body, '\n');
    for (pieces) |*p| {
        const line = lines.next().?;
        p.* = if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
    }
    const ranges = try allocator.alloc(Document.RangeEdit, n);
    defer allocator.free(ranges);
    const ends = try allocator.alloc(usize, n);
    defer allocator.free(ends);
    // Where each insertion ends once every earlier (lower) one is applied.
    var shift: isize = 0;
    for (order, pieces, 0..) |ci, piece, k| {
        const s = cursorSpan(doc.cursors.cursors.items[ci]);
        ranges[n - 1 - k] = .{ .start = s.start, .end = s.end, .text = piece };
        const start: usize = @intCast(@as(isize, @intCast(s.start)) + shift);
        ends[k] = start + piece.len;
        shift += @as(isize, @intCast(piece.len)) - @as(isize, @intCast(s.end - s.start));
    }

    try doc.beginEdit();
    defer doc.endEdit();
    try doc.applyRanges(ranges);
    for (order, ends) |ci, end| {
        const c = &doc.cursors.cursors.items[ci];
        c.anchor = null;
        c.offset = end;
        c.preferred_col = doc.buffer.offsetToPos(end).col;
    }
    doc.cursors.mergeCursors();
    return true;
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
    editor.activeDoc().moveLineUp() catch {
        editor.status_message = "Edit failed: out of memory";
    };
}

fn cmdMoveLineDown(editor: *Editor, _: ?[]const u8) void {
    editor.activeDoc().moveLineDown() catch {
        editor.status_message = "Edit failed: out of memory";
    };
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

fn cmdRecover(editor: *Editor, _: ?[]const u8) void {
    editor.showRecovery();
}
fn cmdRunTask(editor: *Editor, args: ?[]const u8) void {
    if (args) |name| {
        _ = editor.tasks.request(editor, name) catch |err| {
            editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Task: {s}", .{@errorName(err)}) catch "Task failed";
            return;
        };
        if (editor.mode == .normal) editor.tool_panel.show(editor, .task_output);
    } else editor.tool_panel.show(editor, .tasks);
}
fn cmdTaskOutput(editor: *Editor, _: ?[]const u8) void {
    editor.tool_panel.show(editor, .task_output);
}
fn cmdRerunTask(editor: *Editor, _: ?[]const u8) void {
    const run = editor.tasks.get(editor.tasks.selected_run orelse return) orelse return;
    // Request may evict old history, so retain the name independently.
    const name = editor.allocator.dupe(u8, run.config.options.name) catch return;
    defer editor.allocator.free(name);
    // setMode runs the leave hook: a pending save prompt is cancelled
    // instead of blocking the rerun (TaskAlreadyWaitingForSave).
    editor.setMode(.normal);
    cmdRunTask(editor, name);
}
fn cmdStopTask(editor: *Editor, _: ?[]const u8) void {
    editor.tasks.cancel(editor, editor.tasks.selected_run orelse return);
}
fn cmdProblems(editor: *Editor, _: ?[]const u8) void {
    editor.tool_panel.show(editor, .problems);
}
fn cmdGitChanges(editor: *Editor, _: ?[]const u8) void {
    editor.git.requestRefresh();
    editor.tool_panel.show(editor, .changes);
}
fn cmdGitRefresh(editor: *Editor, _: ?[]const u8) void {
    editor.git.requestRefresh();
}
fn cmdDebug(editor: *Editor, _: ?[]const u8) void {
    editor.dap.show(editor, .overview);
}
fn cmdDebugStart(editor: *Editor, args: ?[]const u8) void {
    if (args) |name| editor.dap.start(editor, name) catch |err| {
        editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Debug: {s}", .{@errorName(err)}) catch "Debug launch failed";
    } else editor.dap.show(editor, .configurations);
}
fn cmdBreakpoint(editor: *Editor, _: ?[]const u8) void {
    editor.dap.toggleBreakpoint(editor);
}
fn cmdDebugContinue(editor: *Editor, _: ?[]const u8) void {
    editor.dap.control(editor, .@"continue");
}
fn cmdDebugPause(editor: *Editor, _: ?[]const u8) void {
    editor.dap.control(editor, .pause);
}
fn cmdDebugNext(editor: *Editor, _: ?[]const u8) void {
    editor.dap.control(editor, .next);
}
fn cmdDebugIn(editor: *Editor, _: ?[]const u8) void {
    editor.dap.control(editor, .stepIn);
}
fn cmdDebugOut(editor: *Editor, _: ?[]const u8) void {
    editor.dap.control(editor, .stepOut);
}
fn cmdDebugStop(editor: *Editor, _: ?[]const u8) void {
    editor.dap.stop(editor, false);
}
fn cmdDebugTerminate(editor: *Editor, _: ?[]const u8) void {
    editor.dap.stop(editor, true);
}
/// Stage/unstage the Changes row the user selected — re-found by path
/// (tool_panel.selectedChange), since a refresh may have shifted the rows
/// since the selection; the panel's own S/U keys do the same.
fn cmdGitStage(editor: *Editor, _: ?[]const u8) void {
    if (editor.tool_panel.kind == .changes) editor.tool_panel.action(editor, 's') else cmdGitChanges(editor, null);
}
fn cmdGitUnstage(editor: *Editor, _: ?[]const u8) void {
    if (editor.tool_panel.kind == .changes) editor.tool_panel.action(editor, 'u') else cmdGitChanges(editor, null);
}
fn cmdReview(editor: *Editor, _: ?[]const u8) void {
    editor.git.requestRefresh();
    editor.review.requestRefresh();
    editor.tool_panel.show(editor, .review);
}
/// A verdict goes to the Review view's selected row while the view is open,
/// else to the active document's row in the changed-file list.
fn reviewVerdict(editor: *Editor, status: @import("review.zig").Status) void {
    if (editor.mode == .tool_panel and editor.tool_panel.kind == .review) {
        editor.tool_panel.action(editor, if (status == .approved) 'a' else 'w');
        return;
    }
    const index = editor.review.activeFileIndex(editor) orelse {
        editor.status_message = if (editor.activeDoc().file_path == null) "Review: save the file first" else "Review: not a changed file";
        return;
    };
    editor.review.verdict(editor, index, status);
}
fn cmdReviewApprove(editor: *Editor, _: ?[]const u8) void {
    reviewVerdict(editor, .approved);
}
fn cmdReviewNeedsWork(editor: *Editor, _: ?[]const u8) void {
    reviewVerdict(editor, .needs_work);
}
fn cmdReviewNextFile(editor: *Editor, _: ?[]const u8) void {
    editor.review.step(editor, true);
}
fn cmdReviewPrevFile(editor: *Editor, _: ?[]const u8) void {
    editor.review.step(editor, false);
}
fn cmdReviewSetBaseline(editor: *Editor, _: ?[]const u8) void {
    editor.review.pinHead(editor);
}
fn cmdReviewFollowHead(editor: *Editor, _: ?[]const u8) void {
    editor.review.followHead(editor);
}
/// The row to read: the Review view's selection while it is open, else
/// the active document (the reader's own file, or a listed real file).
fn reviewRowForReader(editor: *Editor) ?usize {
    if (editor.mode == .tool_panel and editor.tool_panel.kind == .review) return editor.tool_panel.selectedChange(editor);
    if (editor.activeDoc().reader) |info| return editor.review.fileIndexFor(info.rel_path);
    return editor.review.activeFileIndex(editor);
}
fn cmdReviewOpenReader(editor: *Editor, _: ?[]const u8) void {
    const index = reviewRowForReader(editor) orelse {
        editor.status_message = "Review: not a changed file — Ctrl+F8 lists them";
        return;
    };
    editor.review.openReader(editor, index, null);
}
fn reviewStepChange(editor: *Editor, forward: bool) void {
    const doc = editor.activeDoc();
    if (doc.reader != null) {
        if (!review_reader.stepChange(doc, forward)) editor.status_message = if (forward) "No more changes here — F8 opens the next file" else "No earlier changes here — Shift+F8 opens the previous file";
        return;
    }
    cmdReviewOpenReader(editor, null);
}
fn cmdReviewNextChange(editor: *Editor, _: ?[]const u8) void {
    reviewStepChange(editor, true);
}
fn cmdReviewPrevChange(editor: *Editor, _: ?[]const u8) void {
    reviewStepChange(editor, false);
}
fn cmdReviewExpandAll(editor: *Editor, _: ?[]const u8) void {
    if (editor.activeDoc().reader == null) {
        editor.status_message = "Review: not a review reader tab";
        return;
    }
    review_reader.setAllExpanded(editor, editor.activeDoc(), true);
}
fn cmdReviewCollapseAll(editor: *Editor, _: ?[]const u8) void {
    if (editor.activeDoc().reader == null) {
        editor.status_message = "Review: not a review reader tab";
        return;
    }
    review_reader.setAllExpanded(editor, editor.activeDoc(), false);
}
/// Reader → classic diff tab; classic diff → reader (caret on the same
/// real line); a listed real file → its reader.
fn cmdReviewToggleView(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    if (doc.reader) |info| {
        if (info.classic) {
            const index = editor.review.fileIndexFor(info.rel_path) orelse {
                editor.status_message = "Review: that file is no longer listed";
                return;
            };
            editor.review.openReader(editor, index, review_reader.realLineAt(info.real_line, doc.cursorPos().line));
        } else editor.review.openClassic(editor, info.rel_path, info.old_path, info.change);
        return;
    }
    cmdReviewOpenReader(editor, null);
}
fn cmdNextProblem(editor: *Editor, _: ?[]const u8) void {
    editor.tool_panel.nextProblem(editor, true);
}
fn cmdPreviousProblem(editor: *Editor, _: ?[]const u8) void {
    editor.tool_panel.nextProblem(editor, false);
}
fn cmdLspReferences(editor: *Editor, _: ?[]const u8) void {
    editor.lsp_tools.start(editor, .references);
}

fn cmdLspDocumentSymbols(editor: *Editor, _: ?[]const u8) void {
    editor.lsp_tools.start(editor, .document_symbol);
}

fn cmdLspWorkspaceSymbols(editor: *Editor, _: ?[]const u8) void {
    editor.lsp_tools.beginWorkspaceSymbols(editor);
}

fn cmdLspSignatureHelp(editor: *Editor, _: ?[]const u8) void {
    editor.lsp_tools.start(editor, .signature_help);
}

/// A snapshot of every running server's stderr in a fresh read-only tab.
fn cmdLspStderr(editor: *Editor, _: ?[]const u8) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(editor.allocator);
    var any = false;
    for (editor.lsp_clients.items) |client| {
        const peer = client.peer orelse continue;
        const captured = peer.stderrAlloc(editor.allocator) catch continue;
        defer editor.allocator.free(captured);
        any = true;
        text.print(editor.allocator, "== {s} ==\n{s}\n", .{ client.name(), if (captured.len > 0) captured else "(nothing on stderr)" }) catch return;
    }
    if (!any) {
        editor.status_message = "No language server is running";
        return;
    }
    const doc = editor.newDocument() catch return;
    doc.loadText(text.items) catch return;
    doc.readonly = true;
    editor.status_message = "Language-server stderr (snapshot, read-only)";
}

fn cmdOpenLog(editor: *Editor, _: ?[]const u8) void {
    const dir = lua_settings.getConfigDir() orelse {
        editor.status_message = "No config directory";
        return;
    };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/zide.log", .{dir}) catch return;
    editor.recordNavPoint();
    _ = editor.openFile(path) catch |err| {
        editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Cannot open zide.log: {s}", .{@errorName(err)}) catch "Cannot open zide.log";
    };
}

test "open_log opens the log file from the config directory" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "zide.log", .data = "info: hello\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    lua_settings.test_config_dir = root;
    defer lua_settings.test_config_dir = null;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try t.expect(editor.execCommand("open_log", null));
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, "zide.log"));
    try t.expectEqualStrings("info: hello\n", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    // Without a server, the stderr tab has nothing to show.
    try t.expect(editor.execCommand("lsp_stderr", null));
    try t.expectEqualStrings("No language server is running", editor.status_message);
}

test "review commands act on the Review view's selected row, else on the active document" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    for ([_][]const u8{ "a.txt", "z.txt" }) |name| try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = "x\n" });
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.review.stage_on_approve = false;
    editor.git.root = try t.allocator.dupe(u8, root);
    for ([_][]const u8{ "a.txt", "z.txt" }) |name| {
        try editor.git.changes.append(t.allocator, .{ .path = try t.allocator.dupe(u8, name), .x = ' ', .y = 'M' });
    }
    editor.review.tick(&editor, 0);
    const Status = @import("review.zig").Status;
    // No file → nothing to judge.
    try t.expect(editor.execCommand("review_approve", null));
    try t.expectEqualStrings("Review: save the file first", editor.status_message);
    // The active document is a listed file: the verdict lands on it.
    const a_path = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(a_path);
    const doc = try editor.newDocument();
    try doc.setFilePath(a_path);
    try t.expect(editor.execCommand("review_approve", null));
    try t.expectEqual(Status.approved, editor.review.statusOf("a.txt"));
    // With the Review view open, the selected row takes the verdict.
    try t.expect(editor.execCommand("review", null));
    try t.expectEqual(Editor.Mode.tool_panel, editor.mode);
    editor.tool_panel.move(&editor, true); // z.txt
    try t.expect(editor.execCommand("review_needs_work", null));
    try t.expectEqual(Status.needs_work, editor.review.statusOf("z.txt"));
    try t.expectEqual(Status.approved, editor.review.statusOf("a.txt"));
    editor.setMode(.normal);
    // Next / previous changed file open the neighbouring row's reader (the
    // diff job is only recorded here), wrapping around the list.
    const review = @import("review.zig");
    review.test_no_spawn = true;
    defer review.test_no_spawn = false;
    try t.expect(editor.execCommand("review_next_file", null));
    try t.expectEqualStrings("z.txt", editor.review.fetch.?.path);
    const z_path = try std.fs.path.join(t.allocator, &.{ root, "z.txt" });
    defer t.allocator.free(z_path);
    _ = try editor.openFile(z_path);
    try t.expect(editor.execCommand("review_next_file", null));
    try t.expectEqualStrings("a.txt", editor.review.fetch.?.path);
    try t.expect(editor.execCommand("review_prev_file", null));
    try t.expectEqualStrings("a.txt", editor.review.fetch.?.path);
    var seg_buf: [48]u8 = undefined;
    try t.expectEqualStrings("Review 2/2 [!]", editor.review.statusSegment(&editor, &seg_buf));
}

test "open_documentation prefers docs/Documentation.md and still finds a root-level copy" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var buf: [600]u8 = undefined;
    try t.expect(documentationIn(t.io, root, &buf) == null);
    // An older checkout keeps the file at the root.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Documentation.md", .data = "# old home\n" });
    const at_root = documentationIn(t.io, root, &buf).?;
    try t.expect(std.mem.startsWith(u8, at_root, root));
    try t.expect(std.mem.endsWith(u8, at_root, "/Documentation.md"));
    try t.expect(!std.mem.endsWith(u8, at_root, "docs/Documentation.md"));
    // docs/ wins once it exists.
    try tmp.dir.createDirPath(t.io, "docs");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "docs/Documentation.md", .data = "# ZIDE Feature Documentation\n" });
    const in_docs = documentationIn(t.io, root, &buf).?;
    try t.expect(std.mem.startsWith(u8, in_docs, root));
    try t.expect(std.mem.endsWith(u8, in_docs, "/docs/Documentation.md"));
}

fn cmdReferences(editor: *Editor, _: ?[]const u8) void {
    if (editor.lsp_tools.references.items.len == 0) {
        editor.status_message = "No references yet: run lsp_references on a symbol";
        return;
    }
    editor.tool_panel.show(editor, .references);
}

fn cmdHover(editor: *Editor, _: ?[]const u8) void {
    editor.lsp_tools.start(editor, .hover);
}
fn cmdRenameSymbol(editor: *Editor, _: ?[]const u8) void {
    editor.lsp_tools.start(editor, .prepare_rename);
}
fn cmdFormatDocument(editor: *Editor, _: ?[]const u8) void {
    editor.lsp_tools.start(editor, .format_document);
}
fn cmdFormatSelection(editor: *Editor, _: ?[]const u8) void {
    editor.lsp_tools.start(editor, .format_selection);
}

/// Tab: with a selection across lines (or covering one whole line) every
/// covered line is indented as one undo step; otherwise the indentation is
/// typed at each cursor (replacing a selection inside one line).
fn cmdIndent(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    var buf: [256]u8 = undefined;
    const unit = indentUnit(editor, doc, &buf);
    if (selectionIsLineWise(doc)) {
        indentLines(editor.allocator, doc, unit) catch {
            editor.status_message = "Edit failed: out of memory";
        };
        return;
    }
    doc.insertAtAllCursors(unit) catch {
        editor.status_message = "Edit failed: out of memory";
    };
}

/// Shift+Tab: dedents every line the cursors cover (one undo step) — the
/// caret line alone for a single cursor without a multi-line selection.
fn cmdDedent(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    const width = editor.indentWidthFor(doc);
    if (doc.cursors.count() > 1 or selectionIsLineWise(doc)) {
        dedentLines(editor.allocator, doc, width) catch {
            editor.status_message = "Edit failed: out of memory";
        };
        return;
    }
    doc.dedentLine(width) catch {};
}

/// One indentation step for `doc`: tabs and/or spaces per its settings.
fn indentUnit(editor: *const Editor, doc: *const Document, buf: *[256]u8) []const u8 {
    const width = @min(editor.indentWidthFor(doc), buf.len);
    const tab_width = @max(1, editor.tabWidthFor(doc));
    const tabs = if (editor.useTabsFor(doc)) width / tab_width else 0;
    const spaces = width - tabs * tab_width;
    @memset(buf[0..tabs], '\t');
    @memset(buf[tabs..][0..spaces], ' ');
    return buf[0 .. tabs + spaces];
}

/// Whether Tab/Shift+Tab work on whole lines: some cursor's selection
/// crosses a line break or covers one whole, non-empty line.
fn selectionIsLineWise(doc: *Document) bool {
    for (doc.cursors.cursors.items) |c| {
        const r = c.selectionRange() orelse continue;
        if (r.end <= r.start) continue;
        const a = doc.buffer.offsetToPos(r.start);
        const b = doc.buffer.offsetToPos(r.end);
        if (a.line != b.line) return true;
        if (a.col == 0 and b.col >= doc.buffer.lineContent(a.line).len) return true;
    }
    return false;
}

const LineSpan = struct { first: usize, last: usize };

/// Lines the cursors cover for a line-wise Tab/Shift+Tab — each selection's
/// lines (one that ends at column 0 stops at the line above) or a bare
/// caret's line — sorted, overlaps merged.
fn coveredLines(allocator: Allocator, doc: *Document) !std.ArrayList(LineSpan) {
    var spans = try std.ArrayList(LineSpan).initCapacity(allocator, doc.cursors.count());
    for (doc.cursors.cursors.items) |c| {
        const s = cursorSpan(c);
        const a = doc.buffer.offsetToPos(s.start);
        const b = doc.buffer.offsetToPos(s.end);
        const last = if (b.line > a.line and b.col == 0) b.line - 1 else b.line;
        spans.appendAssumeCapacity(.{ .first = a.line, .last = last });
    }
    std.mem.sort(LineSpan, spans.items, {}, struct {
        fn less(_: void, x: LineSpan, y: LineSpan) bool {
            return x.first < y.first;
        }
    }.less);
    var n: usize = 0;
    for (spans.items) |s| {
        if (n > 0 and s.first <= spans.items[n - 1].last) {
            spans.items[n - 1].last = @max(spans.items[n - 1].last, s.last);
        } else {
            spans.items[n] = s;
            n += 1;
        }
    }
    spans.items.len = n;
    return spans;
}

/// Indent every covered line by `unit` as one undo step. Empty lines stay
/// empty unless every covered line is empty. A selection that starts at
/// column 0 of an indented line keeps that edge in front of the new
/// indentation, so whole selected lines stay selected; every other cursor
/// position moves with its text.
fn indentLines(allocator: Allocator, doc: *Document, unit: []const u8) !void {
    var spans = try coveredLines(allocator, doc);
    defer spans.deinit(allocator);
    var all_empty = true;
    scan: for (spans.items) |s| {
        var ln = s.first;
        while (ln <= s.last) : (ln += 1) {
            if (doc.buffer.lineContent(ln).len > 0) {
                all_empty = false;
                break :scan;
            }
        }
    }

    var edits: std.ArrayList(Document.RangeEdit) = .empty;
    defer edits.deinit(allocator);
    var k = spans.items.len;
    while (k > 0) {
        k -= 1;
        var ln = spans.items[k].last + 1;
        while (ln > spans.items[k].first) {
            ln -= 1;
            if (!all_empty and doc.buffer.lineContent(ln).len == 0) continue;
            const at = doc.buffer.line_starts.items[ln];
            try edits.append(allocator, .{ .start = at, .end = at, .text = unit });
        }
    }

    // Which selection edges stay put (see above): recorded before the edit.
    const StayPut = enum { none, anchor, offset };
    const stays = try allocator.alloc(StayPut, doc.cursors.count());
    defer allocator.free(stays);
    for (doc.cursors.cursors.items, stays) |c, *stay| {
        stay.* = .none;
        const a = c.anchor orelse continue;
        if (a == c.offset) continue;
        const start = @min(a, c.offset);
        const pos = doc.buffer.offsetToPos(start);
        if (pos.col != 0) continue;
        if (!all_empty and doc.buffer.lineContent(pos.line).len == 0) continue;
        stay.* = if (a < c.offset) .anchor else .offset;
    }

    try doc.beginEdit();
    defer doc.endEdit();
    try doc.applyRanges(edits.items);
    for (doc.cursors.cursors.items, stays) |*c, stay| {
        switch (stay) {
            .none => {},
            .anchor => if (c.anchor) |*a| {
                a.* -= unit.len;
            },
            .offset => c.offset -= unit.len,
        }
        c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
    }
}

/// Leading whitespace one dedent removes from `line`: a tab, or up to
/// `width` spaces (the rule of `Document.dedentLine`).
fn dedentAmount(line: []const u8, width: usize) usize {
    if (line.len > 0 and line[0] == '\t') return 1;
    var n: usize = 0;
    while (n < line.len and n < @max(width, 1) and line[n] == ' ') n += 1;
    return n;
}

/// Dedent every covered line by one step as one undo step; cursors inside
/// removed indentation land at the line start.
fn dedentLines(allocator: Allocator, doc: *Document, width: usize) !void {
    var spans = try coveredLines(allocator, doc);
    defer spans.deinit(allocator);
    var edits: std.ArrayList(Document.RangeEdit) = .empty;
    defer edits.deinit(allocator);
    var k = spans.items.len;
    while (k > 0) {
        k -= 1;
        var ln = spans.items[k].last + 1;
        while (ln > spans.items[k].first) {
            ln -= 1;
            const remove = dedentAmount(doc.buffer.lineContent(ln), width);
            if (remove == 0) continue;
            const at = doc.buffer.line_starts.items[ln];
            try edits.append(allocator, .{ .start = at, .end = at + remove, .text = "" });
        }
    }
    try doc.beginEdit();
    defer doc.endEdit();
    try doc.applyRanges(edits.items);
    for (doc.cursors.cursors.items) |*c| c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
    doc.cursors.mergeCursors();
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

// --- Language servers ---

fn cmdLspRestart(editor: *Editor, _: ?[]const u8) void {
    editor.restartLsp();
}

// --- File tree ---

fn cmdToggleFiletree(editor: *Editor, _: ?[]const u8) void {
    editor.toggleFiletree();
}

fn cmdToggleSnippets(editor: *Editor, _: ?[]const u8) void {
    editor.toggleSnippets();
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

fn cmdFiletreeSetRoot(editor: *Editor, _: ?[]const u8) void {
    editor.filetreeOpenSelectedAsRoot();
}

fn cmdFiletreeReveal(editor: *Editor, _: ?[]const u8) void {
    _ = editor.ensureFiletree() orelse return;
    const doc = editor.activeDoc();
    const path = doc.file_path orelse {
        editor.status_message = "Reveal: current tab has no file on disk";
        return;
    };
    editor.filetree_visible = true;
    if (editor.filetreeRevealPath(path)) {
        // The tree takes the keyboard the one sanctioned way (from the
        // search panel too, and in the primary window).
        _ = editor.takeKeyboardFocus(.filetree);
    } else {
        editor.status_message = "Reveal: file not found under the tree root";
    }
}

fn cmdFiletreeCollapseAll(editor: *Editor, _: ?[]const u8) void {
    const ft = editor.ensureFiletree() orelse return;
    ft.collapseAll() catch {};
}

/// The TUI has no settings panel — this palette command is its switch
/// for the nerdfont tree icons (and persists like the GUI dialog would).
fn cmdToggleTuiIcons(editor: *Editor, _: ?[]const u8) void {
    editor.tui_filetree_icons = !editor.tui_filetree_icons;
    lua_settings.writeSettingToFile("tui_filetree_icons", if (editor.tui_filetree_icons) "true" else "false") catch {};
    editor.status_message = if (editor.tui_filetree_icons)
        "TUI file tree icons ON (glyphs need a Nerd Font terminal font)"
    else
        "TUI file tree icons OFF";
}

/// Selected tree entry as an owned absolute path, or null (with a status
/// message) when there's no tree or nothing selected.
fn filetreeSelectedAbs(editor: *Editor) ?[]u8 {
    const ft = editor.ensureFiletree() orelse return null;
    const idx = ft.selectedNodeIdx() orelse {
        editor.status_message = "File tree: nothing selected";
        return null;
    };
    return ft.absPathAlloc(editor.allocator, idx) catch null;
}

/// Newline-joined clipboard text for the selection: absolute paths, or
/// root-relative in native separators. Sets a status message.
fn filetreeCopyPathsToClipboard(editor: *Editor, absolute: bool) void {
    const ft = editor.ensureFiletree() orelse return;
    const paths = ft.selectionRelPaths(editor.allocator) catch return;
    defer {
        for (paths) |p| editor.allocator.free(p);
        editor.allocator.free(paths);
    }
    if (paths.len == 0) {
        editor.status_message = "File tree: nothing selected";
        return;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(editor.allocator);
    for (paths, 0..) |p, i| {
        if (i > 0) out.append(editor.allocator, '\n') catch return;
        if (absolute) {
            const idx = ft.findByPath(p) orelse continue;
            const abs = ft.absPathAlloc(editor.allocator, idx) catch return;
            defer editor.allocator.free(abs);
            out.appendSlice(editor.allocator, abs) catch return;
        } else {
            const start = out.items.len;
            out.appendSlice(editor.allocator, p) catch return;
            if (builtin.os.tag == .windows) {
                for (out.items[start..]) |*c| {
                    if (c.* == '/') c.* = '\\';
                }
            }
        }
    }
    editor.setClipboard(out.items);
    const msg = if (paths.len == 1)
        std.fmt.bufPrint(&editor.status_buf, "Copied {s}", .{out.items}) catch "Copied path"
    else
        std.fmt.bufPrint(&editor.status_buf, "Copied {d} paths", .{paths.len}) catch "Copied paths";
    editor.status_message = msg;
}

fn cmdFiletreeCopyPath(editor: *Editor, _: ?[]const u8) void {
    filetreeCopyPathsToClipboard(editor, true);
}

fn cmdFiletreeCopyRelPath(editor: *Editor, _: ?[]const u8) void {
    filetreeCopyPathsToClipboard(editor, false);
}

fn cmdFiletreeClipCopy(editor: *Editor, _: ?[]const u8) void {
    editor.filetreeClipCapture(false);
}

fn cmdFiletreeClipCut(editor: *Editor, _: ?[]const u8) void {
    editor.filetreeClipCapture(true);
}

fn cmdFiletreeClipPaste(editor: *Editor, _: ?[]const u8) void {
    editor.filetreePaste();
}

/// Open the OS file manager with the selected entry highlighted.
///
/// Windows goes through ShellExecuteW because explorer's `/select,`
/// switch needs the exact parameter string `/select,"C:\path"` —
/// argv-based spawning would quote the whole argument (or none of it),
/// which explorer answers by opening "This PC" instead.
fn cmdFiletreeRevealExplorer(editor: *Editor, _: ?[]const u8) void {
    const abs = filetreeSelectedAbs(editor) orelse return;
    defer editor.allocator.free(abs);
    if (builtin.os.tag == .windows) {
        const params = std.fmt.allocPrint(editor.allocator, "/select,\"{s}\"", .{abs}) catch return;
        defer editor.allocator.free(params);
        const params_w = std.unicode.utf8ToUtf16LeAllocZ(editor.allocator, params) catch return;
        defer editor.allocator.free(params_w);
        const file_w = std.unicode.utf8ToUtf16LeAllocZ(editor.allocator, "explorer.exe") catch return;
        defer editor.allocator.free(file_w);
        // Returns an HINSTANCE-shaped value > 32 on success.
        const rc = ShellExecuteW(null, null, file_w.ptr, params_w.ptr, null, 1);
        if (@intFromPtr(rc) > 32) {
            editor.status_message = "Opened in Explorer";
        } else {
            editor.status_message = "Could not open Explorer";
        }
        return;
    }
    var argv_buf: [3][]const u8 = undefined;
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => blk: {
            argv_buf = .{ "open", "-R", abs };
            break :blk argv_buf[0..3];
        },
        else => blk: {
            argv_buf[0] = "xdg-open";
            argv_buf[1] = std.fs.path.dirname(abs) orelse abs;
            break :blk argv_buf[0..2];
        },
    };
    // Through the editor-wide spawn lock (jobs.zig), with no pipes: a file
    // manager the launcher leaves running inherits them, and reading them
    // to EOF (std.process.run did) waited for that window to close.
    var child = @import("jobs.zig").spawnLocked(editor.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        editor.status_message = "Could not open the system file manager";
        return;
    };
    const term = child.wait(editor.io) catch {
        editor.status_message = "Could not open the system file manager";
        return;
    };
    editor.status_message = if (term == .exited and term.exited == 0) "Opened in file manager" else "The system file manager reported an error";
}

extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: i32,
) callconv(.winapi) ?*anyopaque;

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
        editor.recordNavPoint();
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

// --- Fuzzy file finder ---

fn cmdQuickOpen(editor: *Editor, _: ?[]const u8) void {
    editor.finderOpen();
}

// --- Workspace search & replace ---

fn cmdFindInFiles(editor: *Editor, _: ?[]const u8) void {
    editor.searchToggle();
}

fn cmdNextResult(editor: *Editor, _: ?[]const u8) void {
    editor.searchCycleResult(true);
}

fn cmdPrevResult(editor: *Editor, _: ?[]const u8) void {
    editor.searchCycleResult(false);
}

// --- Documentation ---

/// Where the documentation file may sit, relative to a checkout or install
/// directory: `docs/` since 2026-10-08, the root in older checkouts.
const documentation_names = [_][]const u8{ "docs/Documentation.md", "Documentation.md" };

/// The documentation file under `dir` (`""` = the current working
/// directory), as a NUL-terminated slice of `buf`, or null when neither
/// location has it.
fn documentationIn(io: std.Io, dir: []const u8, buf: *[600]u8) ?[:0]const u8 {
    const sep: []const u8 = if (dir.len == 0) "" else "/";
    for (documentation_names) |name| {
        const path = std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir, sep, name }) catch continue;
        if (path.len + 1 >= buf.len) continue;
        buf[path.len] = 0;
        const z_path: [:0]const u8 = buf[0..path.len :0];
        if (std.Io.Dir.cwd().access(io, z_path, .{})) |_| {
            return z_path;
        } else |_| {}
    }
    return null;
}

/// Open docs/Documentation.md: search the exe's directory and its ancestors
/// (zig-out/bin/zide.exe → repo root), then the current working directory.
fn cmdOpenDocumentation(editor: *Editor, _: ?[]const u8) void {
    var doc_buf: [600]u8 = undefined;
    var exe_dir_buf: [512]u8 = undefined;
    if (std.process.executableDirPath(editor.io, &exe_dir_buf)) |exe_dir_len| {
        var dir: []const u8 = exe_dir_buf[0..exe_dir_len];
        var level: usize = 0;
        while (level < 4) : (level += 1) {
            if (documentationIn(editor.io, dir, &doc_buf)) |path| {
                _ = editor.openFile(path) catch {};
                return;
            }
            dir = std.fs.path.dirname(dir) orelse break;
        }
    } else |_| {}
    // Fallback: current working directory
    if (documentationIn(editor.io, "", &doc_buf)) |path| {
        _ = editor.openFile(path) catch {};
        return;
    }
    editor.status_message = "Documentation.md not found";
}

// --- Auto-indent newline ---

fn cmdInsertNewlineAuto(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    // In the review reader, Enter opens the real file at this row.
    if (doc.reader != null) return review_reader.activateRow(editor, doc);

    // Multi-cursor: just insert plain newline (auto-indent per cursor is complex)
    if (doc.cursors.count() > 1) {
        doc.insertAtAllCursors(doc.lineEnding()) catch {
            editor.status_message = "Edit failed: out of memory";
        };
        return;
    }

    const pos = doc.cursorPos();
    const line = doc.lineContent(pos.line);

    // Count leading whitespace on current line — only up to the caret: what
    // lies right of it moves to the new line with its own indentation, so
    // Enter at column 0 (or inside the indentation) must not add it twice.
    var indent_len: usize = 0;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') {
            indent_len += 1;
        } else break;
    }
    indent_len = @min(indent_len, pos.col);

    // Markdown: continue list/quote markers ("- ", "3. ", "> ", "- [ ] ").
    if (doc.language) |lang| md: {
        if (lang.tokenizer != .markdown) break :md;
        const info = syntax.mdListInfo(line) orelse break :md;
        // Enter inside/before the markers behaves like a plain newline
        if (pos.col < info.content_start) break :md;
        if (!info.has_content and pos.col >= line.len and !doc.cursors.primaryConst().hasSelection()) {
            // Enter on an empty item terminates the list: clear the line.
            // Marker chains are pure ASCII, so byte count == column count.
            doc.deleteBackward(line.len) catch {};
            return;
        }
        var mbuf: [256]u8 = undefined;
        var w: usize = 0;
        const term = doc.lineEnding();
        @memcpy(mbuf[0..term.len], term);
        w += term.len;
        const ind = @min(indent_len, 128);
        @memcpy(mbuf[w .. w + ind], line[0..ind]);
        w += ind;
        var q: usize = 0;
        while (q < info.quote_levels and w + 2 <= mbuf.len) : (q += 1) {
            mbuf[w] = '>';
            mbuf[w + 1] = ' ';
            w += 2;
        }
        if (info.list) |list| switch (list) {
            .bullet => |ch| {
                if (w + 2 > mbuf.len) break :md;
                mbuf[w] = ch;
                mbuf[w + 1] = ' ';
                w += 2;
            },
            .ordered => |o| {
                const s = std.fmt.bufPrint(mbuf[w..], "{d}{c} ", .{ o.number + 1, o.delim }) catch break :md;
                w += s.len;
            },
        };
        if (info.task) {
            if (w + 4 > mbuf.len) break :md;
            @memcpy(mbuf[w .. w + 4], "[ ] ");
            w += 4;
        }
        doc.insertAtCursor(mbuf[0..w]) catch {};
        return;
    }

    // Enter between a bracket pair ("{|}") opens it: the caret lands on its
    // own line one level deeper and the closer moves to the line below at
    // the original indentation — one undo step.
    if (pos.col > 0 and pos.col < line.len and !doc.cursors.primaryConst().hasSelection() and brackets.closes(line[pos.col - 1], line[pos.col])) {
        var sbuf: [512]u8 = undefined;
        var w: usize = 0;
        const term = doc.lineEnding();
        const ind = @min(indent_len, 128);
        @memcpy(sbuf[w .. w + term.len], term);
        w += term.len;
        @memcpy(sbuf[w .. w + ind], line[0..ind]);
        w += ind;
        if (editor.useTabsFor(doc)) {
            sbuf[w] = '\t';
            w += 1;
        } else {
            const unit = @min(editor.indentWidthFor(doc), 16);
            @memset(sbuf[w .. w + unit], ' ');
            w += unit;
        }
        const caret_at = w;
        @memcpy(sbuf[w .. w + term.len], term);
        w += term.len;
        @memcpy(sbuf[w .. w + ind], line[0..ind]);
        w += ind;
        doc.insertAtCursor(sbuf[0..w]) catch return;
        const c = doc.cursors.primary();
        c.offset -= w - caret_at;
        c.preferred_col = doc.buffer.offsetToPos(c.offset).col;
        return;
    }

    // Build newline + indent string
    var buf: [256]u8 = undefined;
    const term = doc.lineEnding();
    @memcpy(buf[0..term.len], term);
    const copy_len = @min(indent_len, buf.len - term.len);
    if (copy_len > 0) {
        @memcpy(buf[term.len .. term.len + copy_len], line[0..copy_len]);
    }
    doc.insertAtCursor(buf[0 .. term.len + copy_len]) catch {};
}

/// Jump between a bracket and its partner (a recorded jump, so
/// navigate_back returns).
fn cmdGotoMatchingBracket(editor: *Editor, _: ?[]const u8) void {
    const doc = editor.activeDoc();
    const caret = doc.cursors.primary().offset;
    const here = brackets.bracketAt(&doc.buffer, caret) orelse {
        editor.status_message = "No bracket at the cursor";
        return;
    };
    const pair = brackets.matchFor(&doc.buffer, here) orelse {
        editor.status_message = "No matching bracket";
        return;
    };
    const target = if (here == pair.open) pair.close else pair.open;
    editor.recordNavPoint();
    const c = doc.cursors.primary();
    c.clearSelection();
    c.offset = target;
    c.preferred_col = doc.buffer.offsetToPos(target).col;
}

test "Enter between a bracket pair opens it on an indented line; goto_matching_bracket jumps both ways" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.insertAtCursor("    fn f() {}");
    doc.cursors.primary().offset = "    fn f() {".len; // between { and }
    try t.expect(editor.execCommand("insert_newline_auto", null));
    try t.expectEqualStrings("    fn f() {\n        \n    }", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqual("    fn f() {\n        ".len, doc.cursors.primary().offset);
    // From just after the opener to the closer, then back onto the opener.
    doc.cursors.primary().offset = "    fn f() {".len;
    try t.expect(editor.execCommand("goto_matching_bracket", null));
    try t.expectEqual("    fn f() {\n        \n    ".len, doc.cursors.primary().offset);
    try t.expect(editor.execCommand("goto_matching_bracket", null));
    try t.expectEqual("    fn f() ".len, doc.cursors.primary().offset);
    // Enter elsewhere still only copies the indentation.
    doc.cursors.primary().offset = "    fn f() {\n        ".len;
    try t.expect(editor.execCommand("insert_newline_auto", null));
    try t.expectEqualStrings("    fn f() {\n        \n        \n    }", doc.buffer.slice(0, doc.buffer.byteLen()));
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
    const new_offset = cursor_mod.lineOffset(&doc.buffer, max_line + 1, col);
    addCursorWithColumn(doc, new_offset, ref_col);
}

/// Add a cursor at `offset` that remembers `preferred_col` for vertical
/// motion (`CursorSet.addCursor` leaves it 0, so the next add or Up/Down
/// snapped to column 0). No-op when a cursor is already there.
fn addCursorWithColumn(doc: *Document, offset: usize, preferred_col: usize) void {
    const before = doc.cursors.count();
    doc.cursors.addCursor(offset) catch return;
    if (doc.cursors.count() > before) doc.cursors.cursors.items[before].preferred_col = preferred_col;
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
    const new_offset = cursor_mod.lineOffset(&doc.buffer, min_line - 1, col);
    addCursorWithColumn(doc, new_offset, ref_col);
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
        c.preferred_col = doc.buffer.offsetToPos(word_end).col;
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
        new_cursor.preferred_col = doc.buffer.offsetToPos(match_end).col;
    }
}

fn cmdEscapeMulticursor(editor: *Editor, _: ?[]const u8) void {
    // Escape closes the signature popup first, then thins the cursors.
    if (editor.signature != null) {
        editor.clearSignature();
        return;
    }
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

fn cmdOpenInNewWindow(editor: *Editor, _: ?[]const u8) void {
    _ = editor.execAction("open_in_new_window");
}

fn cmdMovePaneToNewWindow(editor: *Editor, _: ?[]const u8) void {
    _ = editor.execAction("move_pane_to_new_window");
}

fn cmdCloseWindow(editor: *Editor, _: ?[]const u8) void {
    _ = editor.execAction("close_window");
}

fn cmdDetachTerminal(editor: *Editor, _: ?[]const u8) void {
    _ = editor.execAction("detach_terminal");
}

/// Word bytes: ASCII letters, digits, `_`, and every byte of a non-ASCII
/// character (the rule of `cursor.isWordByte`), so words like `héllo` or
/// `привет` are whole words.
fn isWordCharByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

// ---- Theme commands ----

fn setGuiTheme(editor: *Editor, name: []const u8, preset: theme_mod.EditorTheme, syn: theme_mod.SyntaxTheme) void {
    editor.theme = preset;
    // Keep syntax colors in step — previously only the Lua config path set
    // them, so live theme switches left a stale syntax palette.
    editor.syntax_theme = syn;
    editor.theme_name = name;
    // Every GUI window re-applies its dvui chrome theme on the next frame.
    editor.theme_revision +%= 1;
    var val_buf: [32]u8 = undefined;
    const quoted = std.fmt.bufPrint(&val_buf, "\"{s}\"", .{name}) catch return;
    lua_settings.writeSettingToFile("theme", quoted) catch {};
}

fn setTuiTheme(editor: *Editor, name: []const u8, preset: theme_mod.TuiTheme, syn: theme_mod.TuiSyntaxTheme) void {
    editor.tui_theme = preset;
    editor.tui_syntax_theme = syn;
    editor.tui_theme_name = name;
    // The theme files (`tui_syn_*` overrides) apply on top of the new palette.
    reapplySyntaxThemes(editor);
    var val_buf: [32]u8 = undefined;
    const quoted = std.fmt.bufPrint(&val_buf, "\"{s}\"", .{name}) catch return;
    lua_settings.writeSettingToFile("tui_theme", quoted) catch {};
}

/// True while reapplySyntaxThemes runs the theme files, so a file that runs
/// a theme command itself (`zide.exec("theme_dark")`) can't recurse.
var reapplying_syntax_themes = false;

/// Re-run the syntax theme files after a preset switch. A preset replaces
/// the whole syntax palette, which dropped syntax-theme.lua's colors and
/// left every syn_theme_<lang>.lua palette (a copy of the old globals) on
/// the old theme. Global file first: the language files re-seed from it.
fn reapplySyntaxThemes(editor: *Editor) void {
    const lua = editor.lua orelse return;
    if (reapplying_syntax_themes) return;
    reapplying_syntax_themes = true;
    defer reapplying_syntax_themes = false;
    lua_settings.loadSyntaxTheme(lua);
    lua_settings.loadLangSyntaxThemes(lua);
}

fn cmdThemeDark(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "dark", theme_mod.gui_dark, theme_mod.syn_gui_dark);
    setTuiTheme(editor, "dark", theme_mod.tui_dark, theme_mod.syn_tui_dark);
    reapplySyntaxThemes(editor);
}

fn cmdThemeLight(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "light", theme_mod.gui_light, theme_mod.syn_gui_light);
    setTuiTheme(editor, "light", theme_mod.tui_light, theme_mod.syn_tui_light);
    reapplySyntaxThemes(editor);
}

fn cmdThemeHighContrast(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "high_contrast", theme_mod.gui_high_contrast, theme_mod.syn_gui_high_contrast);
    setTuiTheme(editor, "high_contrast", theme_mod.tui_high_contrast, theme_mod.syn_tui_high_contrast);
    reapplySyntaxThemes(editor);
}

fn cmdThemeTerminal(editor: *Editor, _: ?[]const u8) void {
    setTuiTheme(editor, "terminal", theme_mod.tui_terminal, theme_mod.syn_tui_terminal);
    reapplySyntaxThemes(editor);
}

// GUI-only theme commands (don't touch TUI theme)
fn cmdGuiThemeDark(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "dark", theme_mod.gui_dark, theme_mod.syn_gui_dark);
    reapplySyntaxThemes(editor);
}
fn cmdGuiThemeLight(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "light", theme_mod.gui_light, theme_mod.syn_gui_light);
    reapplySyntaxThemes(editor);
}
fn cmdGuiThemeHighContrast(editor: *Editor, _: ?[]const u8) void {
    setGuiTheme(editor, "high_contrast", theme_mod.gui_high_contrast, theme_mod.syn_gui_high_contrast);
    reapplySyntaxThemes(editor);
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

test "markdown Enter continues list markers" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("md");
    try std.testing.expect(doc.language != null);

    // Bullet
    try doc.loadText("- item");
    doc.cursors.primary().offset = 6;
    cmdInsertNewlineAuto(&editor, null);
    try std.testing.expectEqualStrings("- item\n- ", doc.buffer.slice(0, doc.buffer.byteLen()));

    // Ordered list increments
    try doc.loadText("3. x");
    doc.cursors.primary().offset = 4;
    cmdInsertNewlineAuto(&editor, null);
    try std.testing.expectEqualStrings("3. x\n4. ", doc.buffer.slice(0, doc.buffer.byteLen()));

    // Task checkbox continues unchecked; indent preserved
    try doc.loadText("  - [x] done");
    doc.cursors.primary().offset = 12;
    cmdInsertNewlineAuto(&editor, null);
    try std.testing.expectEqualStrings("  - [x] done\n  - [ ] ", doc.buffer.slice(0, doc.buffer.byteLen()));

    // Blockquote
    try doc.loadText("> hi");
    doc.cursors.primary().offset = 4;
    cmdInsertNewlineAuto(&editor, null);
    try std.testing.expectEqualStrings("> hi\n> ", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "markdown Enter on empty item terminates the list" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("md");

    try doc.loadText("- a\n- ");
    doc.cursors.primary().offset = 6; // end of the empty "- " item
    cmdInsertNewlineAuto(&editor, null);
    try std.testing.expectEqualStrings("- a\n", doc.buffer.slice(0, doc.buffer.byteLen()));

    // Enter before the marker does not duplicate it
    try doc.loadText("- item");
    doc.cursors.primary().offset = 1;
    cmdInsertNewlineAuto(&editor, null);
    try std.testing.expectEqualStrings("-\n item", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "non-markdown Enter keeps plain auto-indent" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, std.testing.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("zig");

    try doc.loadText("- item");
    doc.cursors.primary().offset = 6;
    cmdInsertNewlineAuto(&editor, null);
    try std.testing.expectEqualStrings("- item\n", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "typing over a selection including paired brackets is one undo step" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    for ([_][]const u8{ "x", "(", "\"", ")" }) |text| {
        try doc.loadText("hello");
        doc.cursors.primary().* = .{ .anchor = 0, .offset = 5 };
        cmdInsertChar(&editor, text);
        try t.expect(try doc.undoAction());
        try t.expectEqualStrings("hello", doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expectEqual(@as(?usize, 0), doc.cursors.primary().anchor);
        try t.expect(!doc.history.canUndo());
        _ = try doc.redoAction();
        try t.expect(doc.cursors.primary().anchor == null);
    }
    try doc.loadText("");
    cmdInsertChar(&editor, "a");
    cmdInsertChar(&editor, "b");
    _ = try doc.undoAction();
    try t.expectEqualStrings("", doc.buffer.slice(0, doc.buffer.byteLen()));
    try doc.loadText("hello");
    doc.cursors.primary().* = .{ .anchor = 0, .offset = 5 };
    cmdInsertChar(&editor, "");
    try t.expectEqualStrings("hello", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "all Enter commands preserve document line endings" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    for ([_][]const u8{ "\n", "\r\n" }) |term| {
        const original = try std.mem.concat(t.allocator, u8, &.{ "a", term, "  b" });
        defer t.allocator.free(original);
        try doc.loadText(original);
        doc.cursors.primary().moveToEnd(&doc.buffer);
        cmdInsertNewlineAuto(&editor, null);
        const expected = try std.mem.concat(t.allocator, u8, &.{ original, term, "  " });
        defer t.allocator.free(expected);
        try t.expectEqualStrings(expected, doc.buffer.slice(0, doc.buffer.byteLen()));
        _ = try doc.undoAction();
        cmdInsertNewline(&editor, null);
        try t.expect(std.mem.endsWith(u8, doc.buffer.slice(0, doc.buffer.byteLen()), term));
        _ = try doc.undoAction();
        try doc.cursors.addCursor(0);
        cmdInsertNewlineAuto(&editor, null);
        try t.expectEqual(@as(usize, 3), std.mem.count(u8, doc.buffer.slice(0, doc.buffer.byteLen()), term));
        _ = try doc.undoAction();
        doc.cursors.clearSecondary();
        const markdown = try std.mem.concat(t.allocator, u8, &.{ "a", term, "- item" });
        defer t.allocator.free(markdown);
        try doc.loadText(markdown);
        doc.language = editor.findLanguage("md");
        doc.cursors.primary().moveToEnd(&doc.buffer);
        cmdInsertNewlineAuto(&editor, null);
        const md_expected = try std.mem.concat(t.allocator, u8, &.{ markdown, term, "- " });
        defer t.allocator.free(md_expected);
        try t.expectEqualStrings(md_expected, doc.buffer.slice(0, doc.buffer.byteLen()));
    }
}

fn testText(doc: *Document) []const u8 {
    return doc.buffer.slice(0, doc.buffer.byteLen());
}

fn expectSelection(doc: *Document, anchor: usize, offset: usize) !void {
    try std.testing.expectEqual(@as(?usize, anchor), doc.cursors.primary().anchor);
    try std.testing.expectEqual(offset, doc.cursors.primary().offset);
}

test "Tab and Shift+Tab with a multi-line selection work on every covered line" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();

    try doc.loadText("alpha\nbeta\ngamma");
    doc.cursors.primary().* = .{ .anchor = 0, .offset = 10 };
    cmdIndent(&editor, null);
    try t.expectEqualStrings("    alpha\n    beta\ngamma", testText(doc));
    try expectSelection(doc, 0, 18); // still both whole lines
    cmdIndent(&editor, null);
    try t.expectEqualStrings("        alpha\n        beta\ngamma", testText(doc));
    cmdDedent(&editor, null);
    cmdDedent(&editor, null);
    try t.expectEqualStrings("alpha\nbeta\ngamma", testText(doc));
    try expectSelection(doc, 0, 10);
    // Each press was one undo step that restores text and selection.
    _ = try doc.undoAction();
    try t.expectEqualStrings("    alpha\n    beta\ngamma", testText(doc));
    for (0..3) |_| _ = try doc.undoAction();
    try t.expectEqualStrings("alpha\nbeta\ngamma", testText(doc));
    try expectSelection(doc, 0, 10);
    try t.expect(!doc.history.canUndo());

    // Ctrl+A then Tab indents every line instead of replacing the text.
    cmdSelectAll(&editor, null);
    cmdIndent(&editor, null);
    try t.expectEqualStrings("    alpha\n    beta\n    gamma", testText(doc));
    try expectSelection(doc, 0, 28);

    // A backward selection keeps its caret at column 0; a selection ending
    // at column 0 leaves that line alone; empty lines stay empty.
    try doc.loadText("a\n\nb\nc");
    doc.cursors.primary().* = .{ .anchor = 5, .offset = 0 };
    cmdIndent(&editor, null);
    try t.expectEqualStrings("    a\n\n    b\nc", testText(doc));
    try expectSelection(doc, 13, 0);

    // One whole line selected works line-wise; a part of one line is replaced
    // by the indentation as before.
    try doc.loadText("alpha\nbeta");
    doc.cursors.primary().* = .{ .anchor = 0, .offset = 5 };
    cmdIndent(&editor, null);
    try t.expectEqualStrings("    alpha\nbeta", testText(doc));
    try expectSelection(doc, 0, 9);
    try doc.loadText("alpha");
    doc.cursors.primary().* = .{ .anchor = 1, .offset = 3 };
    cmdIndent(&editor, null);
    try t.expectEqualStrings("a    ha", testText(doc));

    // CRLF lines and tab indentation.
    editor.use_tabs = true;
    try doc.loadText("a\r\nb");
    cmdSelectAll(&editor, null);
    cmdIndent(&editor, null);
    try t.expectEqualStrings("\ta\r\n\tb", testText(doc));
    cmdDedent(&editor, null);
    try t.expectEqualStrings("a\r\nb", testText(doc));
}

test "Shift+Tab with several cursors dedents every caret line" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("    a\n    b\n    c");
    doc.cursors.primary().offset = 4; // line 0, col 4
    try doc.cursors.addCursor(16); // line 2, col 4
    cmdDedent(&editor, null);
    try t.expectEqualStrings("a\n    b\nc", testText(doc));
    try t.expectEqual(@as(usize, 0), doc.cursors.cursors.items[0].offset);
    try t.expectEqual(@as(usize, 8), doc.cursors.cursors.items[1].offset);
    _ = try doc.undoAction();
    try t.expectEqualStrings("    a\n    b\n    c", testText(doc));
    try t.expect(!doc.history.canUndo());
}

test "Enter at column 0 or inside the indentation does not double it" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("zig");

    try doc.loadText("    foo");
    doc.cursors.primary().offset = 0;
    cmdInsertNewlineAuto(&editor, null);
    try t.expectEqualStrings("\n    foo", testText(doc));
    try t.expectEqual(@as(usize, 1), doc.cursors.primary().offset);

    try doc.loadText("    foo");
    doc.cursors.primary().offset = 2;
    cmdInsertNewlineAuto(&editor, null);
    try t.expectEqualStrings("  \n    foo", testText(doc));

    // Markdown: Enter at column 0 of an indented item must not nest it.
    doc.language = editor.findLanguage("md");
    try doc.loadText("  - item");
    doc.cursors.primary().offset = 0;
    cmdInsertNewlineAuto(&editor, null);
    try t.expectEqualStrings("\n  - item", testText(doc));
}

const TestClipboard = struct {
    // Nothing reaches the system clipboard; paste reads editor.clipboard.
    fn set(_: []const u8) void {}
    fn get() []const u8 {
        return "";
    }
};

test "cut and copy take every selection; paste gives each cursor its line" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.clipboard_set_fn = TestClipboard.set;
    editor.clipboard_get_fn = TestClipboard.get;
    const doc = editor.activeDoc();

    try doc.loadText("abcdef\nabcdef\nabcdef");
    try doc.cursors.setBlockSelection(&doc.buffer, 0, 1, 2, 3);
    cmdCopy(&editor, null);
    try t.expectEqualStrings("bc\nbc\nbc", editor.clipboard);
    cmdCut(&editor, null);
    try t.expectEqualStrings("adef\nadef\nadef", testText(doc));
    try t.expectEqual(@as(usize, 3), doc.cursors.count());
    for (doc.cursors.cursors.items) |c| try t.expect(!c.hasSelection());
    // One undo step brings all three spans back.
    _ = try doc.undoAction();
    try t.expectEqualStrings("abcdef\nabcdef\nabcdef", testText(doc));
    try t.expect(!doc.history.canUndo());
    _ = try doc.redoAction();
    try t.expectEqualStrings("adef\nadef\nadef", testText(doc));

    // Three lines, three cursors: one line each, carets after their text.
    cmdPaste(&editor, null);
    try t.expectEqualStrings("abcdef\nabcdef\nabcdef", testText(doc));
    for (doc.cursors.cursors.items) |c| try t.expectEqual(@as(usize, 3), doc.buffer.offsetToPos(c.offset).col);
    _ = try doc.undoAction();
    try t.expectEqualStrings("adef\nadef\nadef", testText(doc));

    // Any other line count is pasted whole at every cursor, as before.
    editor.setClipboard("X");
    cmdPaste(&editor, null);
    try t.expectEqualStrings("aXdef\naXdef\naXdef", testText(doc));

    // Copy joins with the document's line ending; a short line in a block
    // selection contributes an empty line.
    try doc.loadText("abc\r\na\r\nabc");
    try doc.cursors.setBlockSelection(&doc.buffer, 0, 1, 2, 3);
    cmdCopy(&editor, null);
    try t.expectEqualStrings("bc\r\n\r\nbc", editor.clipboard);

    // A single selection copies as before; nothing selected copies nothing.
    try doc.loadText("hello world");
    doc.cursors.primary().* = .{ .anchor = 6, .offset = 11 };
    cmdCut(&editor, null);
    try t.expectEqualStrings("world", editor.clipboard);
    try t.expectEqualStrings("hello ", testText(doc));
    cmdCopy(&editor, null);
    try t.expectEqualStrings("world", editor.clipboard);
}

test "paste writes line breaks in the document's line ending" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.clipboard_set_fn = TestClipboard.set;
    editor.clipboard_get_fn = TestClipboard.get;
    const doc = editor.activeDoc();

    // CRLF text from a Windows program into an LF document.
    try doc.loadText("x\n");
    editor.setClipboard("a\r\nb\r\n");
    cmdPaste(&editor, null);
    try t.expectEqualStrings("a\nb\nx\n", testText(doc));
    // LF or mixed text into a CRLF document.
    try doc.loadText("x\r\n");
    try t.expect(doc.crlf);
    editor.setClipboard("a\nb\r\nc");
    cmdPaste(&editor, null);
    try t.expectEqualStrings("a\r\nb\r\ncx\r\n", testText(doc));
    // The clipboard itself keeps what was copied.
    try t.expectEqualStrings("a\nb\r\nc", editor.clipboard);
    // A lone CR is not a line break; matching text is pasted as it is.
    try doc.loadText("\n");
    editor.setClipboard("p\rq\n");
    cmdPaste(&editor, null);
    try t.expectEqualStrings("p\rq\n\n", testText(doc));

    // One CRLF line per cursor still distributes in an LF document.
    try doc.loadText("1\n2\n");
    doc.cursors.primary().moveToEnd(&doc.buffer);
    try doc.cursors.addCursor(doc.buffer.posToOffset(0, 1));
    editor.setClipboard("A\r\nB\r\n");
    cmdPaste(&editor, null);
    try t.expectEqualStrings("1A\n2\nB", testText(doc));
}

test "withLineEnding converts only when needed" {
    const t = std.testing;
    try t.expect((try withLineEnding(t.allocator, "a\nb", "\n")) == null);
    try t.expect((try withLineEnding(t.allocator, "a\r\nb", "\r\n")) == null);
    try t.expect((try withLineEnding(t.allocator, "a\rb", "\r\n")) == null);
    const lf = (try withLineEnding(t.allocator, "\r\n\r\na\r\n", "\n")).?;
    defer t.allocator.free(lf);
    try t.expectEqualStrings("\n\na\n", lf);
    const crlf = (try withLineEnding(t.allocator, "\n\r\n\n", "\r\n")).?;
    defer t.allocator.free(crlf);
    try t.expectEqualStrings("\r\n\r\n\r\n", crlf);
}

test "added cursors keep their column for the next add" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();

    try doc.loadText("abcdefgh\nabcdefgh\nabcdefgh\nabcdefgh");
    doc.cursors.primary().gotoPos(&doc.buffer, 0, 5);
    for (0..3) |_| cmdAddCursorBelow(&editor, null);
    try t.expectEqual(@as(usize, 4), doc.cursors.count());
    for (doc.cursors.cursors.items, 0..) |c, line| {
        try t.expectEqual(line, doc.buffer.offsetToPos(c.offset).line);
        try t.expectEqual(@as(usize, 5), doc.buffer.offsetToPos(c.offset).col);
        try t.expectEqual(@as(usize, 5), c.preferred_col);
    }

    // Through a short line the column survives, above and below.
    try doc.loadText("abcdefgh\nab\nabcdefgh");
    doc.cursors.primary().gotoPos(&doc.buffer, 0, 5);
    cmdAddCursorBelow(&editor, null);
    cmdAddCursorBelow(&editor, null);
    try t.expectEqual(@as(usize, 2), doc.buffer.offsetToPos(doc.cursors.cursors.items[1].offset).col);
    try t.expectEqual(@as(usize, 5), doc.buffer.offsetToPos(doc.cursors.cursors.items[2].offset).col);
    doc.cursors.clearSecondary();
    doc.cursors.primary().gotoPos(&doc.buffer, 2, 6);
    cmdAddCursorAbove(&editor, null);
    cmdAddCursorAbove(&editor, null);
    try t.expectEqual(@as(usize, 6), doc.buffer.offsetToPos(doc.cursors.cursors.items[2].offset).col);
}

test "add_next_occurrence treats non-ASCII letters as word characters" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("h\xc3\xa9llo w\xc3\xb6rld h\xc3\xa9llo");
    doc.cursors.primary().offset = 0;
    cmdAddNextOccurrence(&editor, null);
    try t.expectEqual(@as(?usize, 0), doc.cursors.primary().anchor);
    try t.expectEqual(@as(usize, 6), doc.cursors.primary().offset);
    cmdAddNextOccurrence(&editor, null);
    try t.expectEqual(@as(usize, 2), doc.cursors.count());
    try t.expectEqual(@as(?usize, 14), doc.cursors.cursors.items[1].anchor);
    try t.expectEqual(@as(usize, 20), doc.cursors.cursors.items[1].offset);
    try t.expectEqual(@as(usize, 20), doc.cursors.cursors.items[1].preferred_col);
}

test "execAction's own actions are palette commands; every default binding is known" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    for (exec_action_commands) |c| try t.expect(editor.commands.get(c.name) != null);
    var it = editor.keybinds.map.iterator();
    while (it.next()) |entry| {
        if (!editor.commands.isKnownAction(entry.value_ptr.*)) {
            std.debug.print("default binding {s} -> {s} names no command\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            return error.TestUnexpectedResult;
        }
    }
    try t.expect(!editor.commands.isKnownAction("no_such_command"));
    const old_level = t.log_level;
    t.log_level = .err;
    defer t.log_level = old_level;
    editor.commands.warnIfUnknownAction("ctrl+k", "no_such_command");

    // The registry entries run the action itself (no recursion).
    try t.expect(editor.execCommand("goto_line", null));
    try t.expect(editor.mode == .goto_line);
}

test "keyboard delete commands remove complete characters" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    try doc.loadText("\xc3\xa9");
    doc.cursors.primary().moveToEnd(&doc.buffer);
    cmdDeleteBackward(&editor, null);
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    _ = try doc.undoAction();
    doc.cursors.primary().moveToStart();
    cmdDeleteForward(&editor, null);
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
}

test "git_stage and git_unstage act on the selected file after a refresh shifted the rows" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.git.root = try t.allocator.dupe(u8, root);
    for ([_][]const u8{ "a.txt", "z.txt" }, 0..) |name, i| {
        try editor.git.changes.insert(t.allocator, i, .{ .path = try t.allocator.dupe(u8, name), .x = 'M', .y = 'M' });
    }
    // A dirty buffer per file keeps stage() at its save prompt (the
    // mutation is recorded, no git process starts).
    for ([_][]const u8{ "a.txt", "m.txt", "z.txt" }) |name| {
        const doc = try editor.newDocument();
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        try doc.setFilePath(path);
        try doc.insertAtCursor("x");
    }
    editor.tool_panel.show(&editor, .changes);
    editor.tool_panel.move(&editor, true); // z.txt
    // A refresh lists m.txt above the selection before the command runs.
    try editor.git.changes.insert(t.allocator, 1, .{ .path = try t.allocator.dupe(u8, "m.txt"), .x = 'M', .y = 'M' });
    cmdGitStage(&editor, null);
    try t.expectEqualStrings("z.txt", editor.git.mutation.?.path);
    editor.git.resolveStage(&editor, false);
    try t.expect(editor.git.mutation == null);
    // Unstage (it would start git at once): the selected m.txt leaves the
    // list, so nothing happens to the row that took its place.
    editor.tool_panel.show(&editor, .changes);
    editor.tool_panel.move(&editor, true); // m.txt
    const gone = editor.git.changes.orderedRemove(1);
    t.allocator.free(gone.path);
    editor.status_message = "";
    cmdGitUnstage(&editor, null);
    try t.expect(editor.git.mutation == null);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "m.txt") != null);
}

test "rerun_task from the task save prompt cancels that prompt and asks again" {
    const t = std.testing;
    const tasks_mod = @import("tasks.zig");
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    // A dirty untitled buffer puts every request behind the save prompt,
    // so nothing is spawned.
    editor.activeDoc().dirty = true;
    try editor.tasks.register(&editor, try tasks_mod.Config.create(t.allocator, .{ .name = "t", .argv = &.{"zide-test-no-such-task-executable"} }));
    const first = try editor.tasks.request(&editor, "t");
    try t.expectEqual(Editor.Mode.task_save_prompt, editor.mode);
    try t.expectEqual(@as(?u64, first), editor.tasks.pending);

    cmdRerunTask(&editor, null);
    try t.expectEqual(tasks_mod.Status.cancelled, editor.tasks.get(first).?.status);
    try t.expectEqual(Editor.Mode.task_save_prompt, editor.mode);
    const second = editor.tasks.pending orelse return error.TestUnexpectedResult;
    try t.expect(second != first);
    editor.setMode(.normal); // cancels the second prompt the same way
    try t.expect(editor.tasks.pending == null);
}

test "filetree_reveal hands the keyboard to the tree, from the search panel and other windows" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile(t.io, "a.txt", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "a\n");
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const file = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(file);

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_git_colors = false;
    editor.filetree_root = try t.allocator.dupe(u8, root);
    _ = try editor.openOrFocus(file);

    // The search panel had the keyboard: reveal takes it for the tree.
    editor.search_visible = true;
    editor.search_focused = true;
    cmdFiletreeReveal(&editor, null);
    try t.expect(editor.keyboardOwner() == .filetree);
    try t.expect(!editor.search_focused);

    // From a secondary window the primary is focused, where the tree lives.
    _ = editor.takeKeyboardFocus(.pane);
    editor.multi_window_supported = true;
    _ = try editor.newWindow(.{ .editor = editor.active_doc_idx });
    try t.expect(editor.active_window != 0);
    cmdFiletreeReveal(&editor, null);
    try t.expectEqual(@as(usize, 0), editor.active_window);
    try t.expect(editor.keyboardOwner() == .filetree);
}

test "a live theme switch keeps syntax-theme.lua and per-language colors on the new palette" {
    const t = std.testing;
    var lua = try @import("zlua").Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "themes");
    for ([_][2][]const u8{
        .{ "themes/syntax-theme.lua", "zide.set('syn_comment', '#0a0b0c')\n" },
        .{ "themes/syn_theme_zig.lua", "zide.set('syn_keyword', '#010203')\n" },
    }) |file| {
        const f = try tmp.dir.createFile(t.io, file[0], .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, file[1]);
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    lua_settings.test_config_dir = root;
    defer lua_settings.test_config_dir = null;

    // Startup order (main.zig): the global file, then the language files.
    lua_settings.loadSyntaxTheme(lua);
    lua_settings.loadLangSyntaxThemes(lua);
    const own: theme_mod.ThemeColor = .{ .r = 1, .g = 2, .b = 3 };
    try t.expectEqual(own, editor.syntaxThemeFor("zig").keyword);
    try t.expectEqual(@as(u8, 0x0a), editor.syntaxThemeFor("zig").comment.r);
    try t.expectEqual(theme_mod.syn_gui_dark.string, editor.syntaxThemeFor("zig").string);

    cmdThemeLight(&editor, null);
    const light = theme_mod.syn_gui_light;
    const zig_gui = editor.syntaxThemeFor("zig");
    // The language keeps its own color; the rest follows the light palette…
    try t.expectEqual(own, zig_gui.keyword);
    try t.expectEqual(light.string, zig_gui.string);
    try t.expectEqual(light.number, zig_gui.number);
    try t.expectEqual(light.function, zig_gui.function);
    // …with syntax-theme.lua's color re-applied on top (global and per language).
    try t.expectEqual(@as(u8, 0x0a), zig_gui.comment.r);
    try t.expectEqual(@as(u8, 0x0a), editor.syntax_theme.comment.r);
    try t.expectEqual(light.keyword, editor.syntaxThemeFor("python").keyword);
    // The TUI palette of the language follows as well.
    const zig_tui = editor.tuiSyntaxThemeFor("zig");
    try t.expectEqual(theme_mod.TuiColor{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, zig_tui.keyword);
    try t.expectEqual(theme_mod.syn_tui_light.string, zig_tui.string);
    // Re-running kept one override per language (re-seeded in place).
    try t.expectEqual(@as(usize, 1), editor.lang_syntax_overrides.items.len);
}

fn cmdFileEncoding(editor: *Editor, _: ?[]const u8) void {
    editor.startEncoding(.choose);
}
fn cmdReopenEncoding(editor: *Editor, _: ?[]const u8) void {
    editor.startEncoding(.reopen);
}
fn cmdSaveEncoding(editor: *Editor, _: ?[]const u8) void {
    editor.startEncoding(.save);
}
