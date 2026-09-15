//! Shared keyboard model for task selection/output and workspace Problems.
const std = @import("std");
const Editor = @import("editor.zig").Editor;
const lsp = @import("lsp.zig");
const diagnostics = @import("diagnostics.zig");
const tasks = @import("tasks.zig");
pub const Kind = enum { tasks, task_output, problems, changes, git_diff, debug };
pub const State = struct {
    kind: Kind = .tasks,
    selected: usize = 0,
    scroll: usize = 0,
    severity: ?lsp.DiagnosticSeverity = null,
    source: ?[]u8 = null,
    problem_indices: std.ArrayList(usize) = .empty,
    revision: ?u64 = null,
    problem_opened: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.source) |source| allocator.free(source);
        self.problem_indices.deinit(allocator);
    }
    pub fn show(self: *State, editor: *Editor, kind: Kind) void {
        self.kind = kind;
        self.selected = 0;
        self.scroll = 0;
        self.revision = null;
        self.problem_opened = false;
        editor.mode = .tool_panel;
    }
    pub fn title(self: *State, editor: *Editor, buf: []u8) []const u8 {
        return switch (self.kind) {
            .tasks => "Tasks — Enter runs / Esc closes",
            .debug => editor.dap.title(buf),
            .changes => if (editor.git.status().len > 0) editor.git.status() else "Changes: index / working tree | Enter diff / D staged diff / S stage / U unstage / R refresh",
            .git_diff => std.fmt.bufPrint(buf, "{s}: {s}{s}{s}", .{ editor.git.preview_path orelse "Diff", if (editor.git.preview_staged) "index versus HEAD" else "saved working tree versus index", if (editor.git.preview_job != null) " (loading)" else "", if (editor.git.preview.truncated) " (truncated)" else "" }) catch "Git diff",
            .task_output => blk: {
                const run = editor.tasks.get(editor.tasks.selected_run orelse break :blk "Task output") orelse break :blk "Task output";
                break :blk std.fmt.bufPrint(buf, "{s}: {s} (exit {any}){s} {s} | R reruns / S stops / Enter opens location", .{ run.config.options.name, @tagName(run.status), run.exit_code, if (run.truncated) " (output truncated)" else "", run.error_name orelse "" }) catch run.config.options.name;
            },
            .problems => std.fmt.bufPrint(buf, "Problems: {s}, {s} | F severity / S source / Enter opens", .{ if (self.severity) |severity| @tagName(severity) else "all severities", self.source orelse "all sources" }) catch "Problems",
        };
    }

    fn refresh(self: *State, editor: *Editor) void {
        if (self.revision == editor.problems.revision) return;
        self.problem_indices.clearRetainingCapacity();
        for (editor.problems.entries.items, 0..) |entry, i| {
            if (self.severity != null and self.severity.? != entry.diagnostic.severity) continue;
            if (self.source) |source| if (!std.mem.eql(u8, source, entry.producer)) continue;
            self.problem_indices.append(editor.allocator, i) catch break;
        }
        std.mem.sort(usize, self.problem_indices.items, editor.problems.entries.items, struct {
            fn less(entries: []diagnostics.Entry, a: usize, b: usize) bool {
                const x = entries[a];
                const y = entries[b];
                const order = std.mem.order(u8, x.path, y.path);
                if (order != .eq) return order == .lt;
                if (x.diagnostic.start_line != y.diagnostic.start_line) return x.diagnostic.start_line < y.diagnostic.start_line;
                return x.diagnostic.start_col < y.diagnostic.start_col;
            }
        }.less);
        self.revision = editor.problems.revision;
        self.selected = @min(self.selected, self.problem_indices.items.len -| 1);
    }

    pub fn count(self: *State, editor: *Editor) usize {
        const total = switch (self.kind) {
            .tasks => editor.tasks.configs.items.len,
            .debug => editor.dap.count(editor),
            .changes => editor.git.changes.items.len,
            .git_diff => editor.git.preview.count(),
            .problems => blk: {
                self.refresh(editor);
                break :blk self.problem_indices.items.len;
            },
            .task_output => blk: {
                const run = editor.tasks.get(editor.tasks.selected_run orelse break :blk 0) orelse break :blk 0;
                break :blk run.output.count();
            },
        };
        self.selected = @min(self.selected, total -| 1);
        return total;
    }

    pub fn row(self: *State, editor: *Editor, index: usize, buf: []u8) []const u8 {
        if (index >= self.count(editor)) return "";
        return switch (self.kind) {
            .tasks => editor.tasks.configs.items[index].options.name,
            .debug => editor.dap.row(editor, index, buf),
            .changes => blk: {
                const change = editor.git.changes.items[index];
                break :blk std.fmt.bufPrint(buf, "{c}{c} {s}{s}{s}{s}", .{ change.x, change.y, change.path, if (change.old_path != null) " <- " else "", change.old_path orelse "", if (change.conflict()) " (conflict)" else "" }) catch change.path;
            },
            .git_diff => editor.git.preview.line(index),
            .task_output => blk: {
                const run = editor.tasks.get(editor.tasks.selected_run.?).?;
                const line = run.output.line(index);
                if (line.len == 0 and index == 0) break :blk run.error_name orelse "No output yet";
                break :blk line;
            },
            .problems => blk: {
                const entry = editor.problems.entries.items[self.problem_indices.items[index]];
                var stale = false;
                if (editor.findDocument(entry.path) catch null) |doc_index| {
                    const doc = &editor.documents.items[doc_index];
                    if (entry.version) |version| stale = version != doc.lsp_version else if (entry.kind == .task) {
                        stale = if (entry.task_doc_id == doc.id and entry.task_buffer_version != null) entry.task_buffer_version.? != doc.buffer.version else doc.dirty;
                    }
                }
                break :blk std.fmt.bufPrint(buf, "{s}:{d}:{d} {s} [{s}]{s} {s}", .{
                    entry.path,                          entry.diagnostic.start_line +| 1, entry.diagnostic.start_col +| 1,
                    @tagName(entry.diagnostic.severity), entry.producer,                   if (stale) " (possibly stale)" else "",
                    entry.diagnostic.message,
                }) catch entry.diagnostic.message;
            },
        };
    }

    pub fn move(self: *State, editor: *Editor, down: bool) void {
        const total = self.count(editor);
        if (total == 0) return;
        self.selected = if (down) @min(total - 1, self.selected +| 1) else self.selected -| 1;
    }

    pub fn activate(self: *State, editor: *Editor) void {
        if (self.selected >= self.count(editor)) return;
        switch (self.kind) {
            .debug => editor.dap.activate(editor, self.selected),
            .changes => editor.git.previewChange(editor, self.selected, !editor.git.changes.items[self.selected].working()),
            .git_diff => {},
            .tasks => {
                editor.mode = .normal;
                _ = editor.tasks.request(editor, editor.tasks.configs.items[self.selected].options.name) catch |err| {
                    editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Task: {s}", .{@errorName(err)}) catch "Task failed";
                    return;
                };
                if (editor.mode == .normal) self.show(editor, .task_output);
            },
            .task_output => {
                const run = editor.tasks.get(editor.tasks.selected_run.?).?;
                var buf: [1]u8 = undefined;
                const location = tasks.zigLocation(self.row(editor, self.selected, &buf)) orelse return;
                const path = std.fs.path.resolve(editor.allocator, &.{ run.cwd, location.path }) catch return;
                defer editor.allocator.free(path);
                self.openLocation(editor, path, location.line, location.col, .bytes);
            },
            .problems => {
                const entry = editor.problems.entries.items[self.problem_indices.items[self.selected]];
                self.problem_opened = true;
                self.openLocation(editor, entry.path, entry.diagnostic.start_line, entry.diagnostic.start_col, entry.columns);
            },
        }
    }
    fn openLocation(_: *State, editor: *Editor, path: []const u8, line: u32, col: u32, columns: diagnostics.Columns) void {
        // Opening can call extensions which replace the diagnostic store.
        const owned = editor.allocator.dupe(u8, path) catch return;
        defer editor.allocator.free(owned);
        const doc = editor.openOrFocus(owned) catch |err| {
            editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Cannot open problem: {s}", .{@errorName(err)}) catch "Cannot open problem";
            return;
        };
        doc.gotoLine(line +| 1);
        const byte_col = if (columns == .utf16) lsp.utf16ColToByte(doc.lineContent(line), col) else col;
        doc.cursors.primary().gotoPos(&doc.buffer, line, byte_col);
        editor.mode = .normal;
    }

    pub fn nextProblem(self: *State, editor: *Editor, next: bool) void {
        self.kind = .problems;
        self.refresh(editor);
        const total = self.problem_indices.items.len;
        if (total == 0) {
            editor.status_message = "No matching problems";
            return;
        }
        self.selected = if (!self.problem_opened) (if (next) 0 else total - 1) else if (next) (self.selected + 1) % total else (self.selected + total - 1) % total;
        self.activate(editor);
    }

    pub fn page(self: *State, editor: *Editor, down: bool, amount: usize) void {
        const total = self.count(editor);
        self.selected = if (down) @min(total -| 1, self.selected +| amount) else self.selected -| amount;
    }
    pub fn action(self: *State, editor: *Editor, key: u8) void {
        switch (self.kind) {
            .debug => switch (key) {
                'r' => editor.dap.show(editor, .overview),
                's' => editor.dap.stop(editor, false),
                'o' => editor.dap.show(editor, .output),
                else => {},
            },
            .changes => switch (key) {
                'd' => editor.git.previewChange(editor, self.selected, true),
                's' => editor.git.stage(editor, self.selected, false),
                'u' => editor.git.stage(editor, self.selected, true),
                'r' => editor.git.requestRefresh(),
                'o' => {
                    if (self.selected >= editor.git.changes.items.len) return;
                    const path = std.fs.path.join(editor.allocator, &.{ editor.git.root orelse return, editor.git.changes.items[self.selected].path }) catch return;
                    defer editor.allocator.free(path);
                    self.openLocation(editor, path, 0, 0, .bytes);
                },
                else => {},
            },
            .git_diff => {},
            .problems => switch (key) {
                'f' => self.filterSeverity(),
                's' => self.filterSource(editor),
                else => {},
            },
            .task_output => switch (key) {
                'r' => {
                    _ = editor.execAction("rerun_task");
                },
                's' => {
                    _ = editor.execAction("stop_task");
                },
                else => {},
            },
            .tasks => {},
        }
    }

    pub fn filterSeverity(self: *State) void {
        self.severity = if (self.severity) |severity| (if (severity == .hint) null else @enumFromInt(@intFromEnum(severity) + 1)) else .err;
        self.revision = null;
    }
    pub fn filterSource(self: *State, editor: *Editor) void {
        var next: ?[]const u8 = null;
        for (editor.problems.entries.items) |entry| {
            if (self.source) |current| if (std.mem.order(u8, entry.producer, current) != .gt) continue;
            if (next == null or std.mem.order(u8, entry.producer, next.?) == .lt) next = entry.producer;
        }
        const owned = if (next) |source| editor.allocator.dupe(u8, source) catch return else null;
        if (self.source) |source| editor.allocator.free(source);
        self.source = owned;
        self.revision = null;
    }
};
