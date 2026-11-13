//! Shared keyboard model for task selection/output and workspace Problems.
const std = @import("std");
const Editor = @import("editor.zig").Editor;
const lsp = @import("lsp.zig");
const diagnostics = @import("diagnostics.zig");
const tasks = @import("tasks.zig");
const git = @import("git.zig");
const review = @import("review.zig");
pub const Kind = enum { tasks, task_output, problems, changes, git_diff, debug, references, review };

/// A row of one of the two path-tracked views (Changes, Review).
const PathRow = struct { path: []const u8, old_path: ?[]const u8 };

/// `path` relative to the file tree root when it lies inside it (servers
/// spell the drive letter and separators their own way), else its last two
/// components — the row says "…/" when it elided.
const DisplayPath = struct { text: []const u8, elided: bool };

fn displayPath(editor: *Editor, path: []const u8) DisplayPath {
    if (editor.filetree) |*ft| {
        const root = ft.root_path;
        if (path.len > root.len + 1 and samePathPrefix(path[0..root.len], root) and (path[root.len] == '/' or path[root.len] == '\\')) return .{ .text = path[root.len + 1 ..], .elided = false };
    }
    var seps: usize = 0;
    var i = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '/' or c == '\\') {
            seps += 1;
            if (seps == 2) return .{ .text = path[i..], .elided = true };
        }
    }
    return .{ .text = path, .elided = false };
}

fn samePathPrefix(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xs: u8 = if (x == '\\') '/' else x;
        const ys: u8 = if (y == '\\') '/' else y;
        if (std.ascii.toLower(xs) != std.ascii.toLower(ys)) return false;
    }
    return true;
}
pub const State = struct {
    kind: Kind = .tasks,
    selected: usize = 0,
    scroll: usize = 0,
    severity: ?lsp.DiagnosticSeverity = null,
    source: ?[]u8 = null,
    problem_indices: std.ArrayList(usize) = .empty,
    revision: ?u64 = null,
    problem_opened: bool = false,
    /// Changes and Review views: the row the user selected, by path (H5). A
    /// refresh can insert or remove rows above it between selecting and
    /// pressing a key, so the highlight follows the path and actions re-find
    /// it by path instead of trusting `selected`. `change_row` is where it was
    /// last seen; `selected` moving away from it means the user picked another row.
    change_path: ?[]u8 = null,
    change_old_path: ?[]u8 = null,
    change_row: usize = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.source) |source| allocator.free(source);
        self.problem_indices.deinit(allocator);
        self.forgetChange(allocator);
    }
    pub fn show(self: *State, editor: *Editor, kind: Kind) void {
        self.kind = kind;
        self.selected = 0;
        self.scroll = 0;
        self.revision = null;
        self.problem_opened = false;
        self.forgetChange(editor.allocator);
        if (self.tracksPath()) self.captureChange(editor);
        editor.setMode(.tool_panel);
    }
    /// Select row `index` (frontend clicks): the path-tracked views remember
    /// the row under it right away.
    pub fn select(self: *State, editor: *Editor, index: usize) void {
        self.selected = index;
        if (self.tracksPath()) self.captureChange(editor);
    }
    /// Whether the current view follows its selection by path (Changes, Review).
    pub fn tracksPath(self: *const State) bool {
        return self.kind == .changes or self.kind == .review;
    }
    fn rowCount(self: *const State, editor: *Editor) usize {
        return switch (self.kind) {
            .changes => editor.git.changes.items.len,
            .review => editor.review.files.items.len,
            else => 0,
        };
    }
    fn pathAt(self: *const State, editor: *Editor, index: usize) ?PathRow {
        switch (self.kind) {
            .changes => {
                const items = editor.git.changes.items;
                if (index >= items.len) return null;
                return .{ .path = items[index].path, .old_path = items[index].old_path };
            },
            .review => {
                const items = editor.review.files.items;
                if (index >= items.len) return null;
                return .{ .path = items[index].path, .old_path = items[index].old_path };
            },
            else => return null,
        }
    }
    fn viewName(self: *const State) []const u8 {
        return if (self.kind == .review) "Review" else "Changes";
    }
    pub fn title(self: *State, editor: *Editor, buf: []u8) []const u8 {
        return switch (self.kind) {
            .tasks => "Tasks — Enter runs / Esc closes",
            .debug => editor.dap.title(buf),
            .changes => if (editor.git.status().len > 0) editor.git.status() else "Changes: index / working tree | Enter diff / D staged diff / S stage / U unstage / R refresh",
            .git_diff => blk: {
                var mode_buf: [64]u8 = undefined;
                break :blk std.fmt.bufPrint(buf, "{s}: {s}{s}{s}", .{ editor.git.preview_path orelse "Diff", editor.git.previewModeText(&mode_buf), if (editor.git.preview_job != null) " (loading)" else "", if (editor.git.preview.truncated) " (truncated)" else "" }) catch "Git diff";
            },
            .task_output => blk: {
                const run = editor.tasks.get(editor.tasks.selected_run orelse break :blk "Task output") orelse break :blk "Task output";
                break :blk std.fmt.bufPrint(buf, "{s}: {s} (exit {any}){s} {s}{s}{s} | R reruns / S stops / Enter opens location", .{ run.config.options.name, @tagName(run.status), run.exit_code, if (run.truncated) " (output truncated)" else "", run.error_name orelse "", if (run.matcher_error != null) " problem matcher failed: " else "", run.matcher_error orelse "" }) catch run.config.options.name;
            },
            .problems => std.fmt.bufPrint(buf, "Problems: {s}, {s} | F severity / S source / Enter opens", .{ if (self.severity) |severity| @tagName(severity) else "all severities", self.source orelse "all sources" }) catch "Problems",
            .references => std.fmt.bufPrint(buf, "References to {s}: {d} | Enter opens / Esc closes", .{ editor.lsp_tools.referencesSymbol(), editor.lsp_tools.references.items.len }) catch "References",
            .review => blk: {
                if (editor.git.root == null) break :blk "Review: not a Git repository";
                const counts = editor.review.counts();
                var base_buf: [96]u8 = undefined;
                break :blk std.fmt.bufPrint(buf, "Review: {d}/{d} reviewed, {d} needs work | {s}{s} | A approve / W needs work / D diff / O open / R refresh / P pin baseline / U unpin", .{
                    counts.approved + counts.needs_work,   counts.total,                                             counts.needs_work,
                    editor.review.baselineText(&base_buf), if (editor.review.list_job != null) " (loading)" else "",
                }) catch "Review";
            },
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
            .changes, .review => blk: {
                self.syncChange(editor);
                break :blk self.rowCount(editor);
            },
            .git_diff => editor.git.preview.count(),
            .references => editor.lsp_tools.references.items.len,
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
            .references => blk: {
                const r = editor.lsp_tools.references.items[index];
                const shown = displayPath(editor, r.path);
                break :blk std.fmt.bufPrint(buf, "{s}{s}:{d}:{d}  {s}", .{ if (shown.elided) "…/" else "", shown.text, r.line + 1, r.col + 1, r.excerpt }) catch r.path;
            },
            .review => blk: {
                const file = editor.review.files.items[index];
                break :blk std.fmt.bufPrint(buf, "{s} {c} {s}{s}{s}{s}", .{ review.glyph(editor.review.statusOf(file.path)), file.change, file.path, if (file.old_path != null) " <- " else "", file.old_path orelse "", if (file.change == 'U') " (conflict)" else "" }) catch file.path;
            },
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
        if (self.tracksPath()) self.captureChange(editor);
    }

    fn forgetChange(self: *State, allocator: std.mem.Allocator) void {
        if (self.change_path) |path| allocator.free(path);
        if (self.change_old_path) |path| allocator.free(path);
        self.change_path = null;
        self.change_old_path = null;
    }
    /// Remember the row now at `selected` as the user's choice.
    fn captureChange(self: *State, editor: *Editor) void {
        self.forgetChange(editor.allocator);
        self.change_row = self.selected;
        const pr = self.pathAt(editor, self.selected) orelse return;
        const path = editor.allocator.dupe(u8, pr.path) catch return;
        const old = if (pr.old_path) |old| editor.allocator.dupe(u8, old) catch {
            editor.allocator.free(path);
            return;
        } else null;
        self.change_path = path;
        self.change_old_path = old;
    }
    fn sameChange(self: *const State, pr: PathRow) bool {
        const path = self.change_path orelse return false;
        if (!std.mem.eql(u8, pr.path, path)) return false;
        const old = pr.old_path orelse return self.change_old_path == null;
        return self.change_old_path != null and std.mem.eql(u8, old, self.change_old_path.?);
    }
    /// Keep `selected` on the remembered row when the list changed under it
    /// (exact match first, then the same path with another rename source).
    /// A row that is gone stays remembered, so the next action reports it.
    fn syncChange(self: *State, editor: *Editor) void {
        const total = self.rowCount(editor);
        if (self.change_path == null or self.selected != self.change_row) return self.captureChange(editor);
        if (self.change_row < total and self.sameChange(self.pathAt(editor, self.change_row).?)) return;
        var same_path: ?usize = null;
        var found: ?usize = null;
        var index: usize = 0;
        while (index < total) : (index += 1) {
            const pr = self.pathAt(editor, index).?;
            if (self.sameChange(pr)) {
                found = index;
                break;
            }
            if (same_path == null and std.mem.eql(u8, pr.path, self.change_path.?)) same_path = index;
        }
        const pick = if (found) |f| f else same_path;
        if (pick) |i| {
            self.selected = i;
            self.captureChange(editor);
        } else {
            // Pin the clamped row so count()'s clamp is not taken for a user move.
            self.selected = @min(self.selected, total -| 1);
            self.change_row = self.selected;
        }
    }
    /// The Changes/Review row the user selected, re-found by path at keypress
    /// time (H5); null, with a status message, when that file is no longer
    /// listed. The row now highlighted is then remembered, so pressing again
    /// acts on it.
    pub fn selectedChange(self: *State, editor: *Editor) ?usize {
        self.syncChange(editor);
        const total = self.rowCount(editor);
        const path = self.change_path orelse return if (self.selected < total) self.selected else null;
        if (self.change_row < total and self.sameChange(self.pathAt(editor, self.change_row).?)) return self.change_row;
        editor.setStatus(.warning, std.fmt.bufPrint(&editor.status_buf, "{s}: {s} is no longer listed; nothing done", .{ self.viewName(), std.fs.path.basename(path) }) catch "The selected file is no longer listed; nothing done");
        self.captureChange(editor);
        return null;
    }
    /// Review view: open the real file of the selected row.
    fn openReviewFile(self: *State, editor: *Editor, index: usize) void {
        const file = editor.review.files.items[index];
        if (file.change == 'D') {
            editor.setStatus(.warning, "Review: deleted file — D shows the diff");
            return;
        }
        const root = editor.review.root orelse return;
        const path = std.fs.path.join(editor.allocator, &.{ root, file.path }) catch return;
        defer editor.allocator.free(path);
        self.openLocation(editor, path, 0, 0, .bytes);
    }

    pub fn activate(self: *State, editor: *Editor) void {
        if (self.selected >= self.count(editor)) return;
        switch (self.kind) {
            .debug => editor.dap.activate(editor, self.selected),
            .changes => {
                const index = self.selectedChange(editor) orelse return;
                editor.git.previewChange(editor, index, !editor.git.changes.items[index].working());
            },
            .git_diff => {},
            .references => {
                const r = editor.lsp_tools.references.items[self.selected];
                self.openLocation(editor, r.path, r.line, r.col, r.columns);
            },
            .review => {
                const index = self.selectedChange(editor) orelse return;
                editor.review.openReader(editor, index, null);
            },
            .tasks => {
                editor.setMode(.normal);
                _ = editor.tasks.request(editor, editor.tasks.configs.items[self.selected].options.name) catch |err| {
                    editor.setStatus(.err, std.fmt.bufPrint(&editor.status_buf, "Task: {s}", .{@errorName(err)}) catch "Task failed");
                    return;
                };
                if (editor.mode == .normal) self.show(editor, .task_output);
            },
            .task_output => {
                const run = editor.tasks.get(editor.tasks.selected_run orelse return) orelse return;
                var buf: [1]u8 = undefined;
                // The run's own matcher (Lua or zig) finds the location.
                const found = tasks.locate(editor, run, self.row(editor, self.selected, &buf)) orelse {
                    editor.setStatus(.warning, "No file location on this line");
                    return;
                };
                defer editor.allocator.free(found.path);
                self.openLocation(editor, found.path, found.line, found.col, .bytes);
            },
            .problems => {
                const entry = editor.problems.entries.items[self.problem_indices.items[self.selected]];
                self.problem_opened = true;
                self.openLocation(editor, entry.path, entry.diagnostic.start_line, entry.diagnostic.start_col, entry.columns);
            },
        }
    }
    fn openLocation(_: *State, editor: *Editor, path: []const u8, line: u32, col: u32, columns: diagnostics.Columns) void {
        editor.jumpToLocation(path, line, col, columns);
    }

    pub fn nextProblem(self: *State, editor: *Editor, next: bool) void {
        self.kind = .problems;
        self.refresh(editor);
        const total = self.problem_indices.items.len;
        if (total == 0) {
            editor.setStatus(.warning, "No matching problems");
            return;
        }
        self.selected = if (!self.problem_opened) (if (next) 0 else total - 1) else if (next) (self.selected + 1) % total else (self.selected + total - 1) % total;
        self.activate(editor);
    }

    pub fn page(self: *State, editor: *Editor, down: bool, amount: usize) void {
        const total = self.count(editor);
        self.selected = if (down) @min(total -| 1, self.selected +| amount) else self.selected -| amount;
        if (self.tracksPath()) self.captureChange(editor);
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
                'd', 's', 'u', 'o' => {
                    const index = self.selectedChange(editor) orelse return;
                    switch (key) {
                        'd' => editor.git.previewChange(editor, index, true),
                        's' => editor.git.stage(editor, index, false),
                        'u' => editor.git.stage(editor, index, true),
                        else => {
                            const path = std.fs.path.join(editor.allocator, &.{ editor.git.root orelse return, editor.git.changes.items[index].path }) catch return;
                            defer editor.allocator.free(path);
                            self.openLocation(editor, path, 0, 0, .bytes);
                        },
                    }
                },
                'r' => editor.git.requestRefresh(),
                else => {},
            },
            .review => switch (key) {
                'a', 'w', 'd', 'o' => {
                    const index = self.selectedChange(editor) orelse return;
                    switch (key) {
                        'a' => editor.review.verdict(editor, index, .approved),
                        'w' => editor.review.verdict(editor, index, .needs_work),
                        'd' => editor.review.openClassicRow(editor, index),
                        else => self.openReviewFile(editor, index),
                    }
                },
                'r' => {
                    editor.git.requestRefresh();
                    editor.review.requestRefreshAnnounced();
                },
                'p' => editor.review.pinHead(editor),
                'u' => editor.review.followHead(editor),
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
            .tasks, .references => {},
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

fn testChange(editor: *Editor, index: usize, name: []const u8) !void {
    try editor.git.changes.insert(editor.allocator, index, .{ .path = try editor.allocator.dupe(u8, name), .x = ' ', .y = 'M' });
}

test "Changes actions follow the selected file when a refresh inserts or removes rows above it" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.git.root = try t.allocator.dupe(u8, root);
    try testChange(&editor, 0, "a.txt");
    try testChange(&editor, 1, "z.txt");
    // A dirty buffer for every candidate keeps stage() at its save prompt
    // (it records the mutation without starting a git process).
    for ([_][]const u8{ "a.txt", "m.txt", "z.txt" }) |name| {
        const doc = try editor.newDocument();
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        try doc.setFilePath(path);
        try doc.insertAtCursor("x");
    }
    const panel = &editor.tool_panel;
    panel.show(&editor, .changes);
    panel.move(&editor, true);
    try t.expectEqual(@as(usize, 1), panel.selected); // z.txt
    // A refresh lists m.txt above the selection before S is pressed.
    try testChange(&editor, 1, "m.txt");
    panel.action(&editor, 's');
    try t.expectEqualStrings("z.txt", editor.git.mutation.?.path);
    try t.expectEqual(@as(usize, 2), panel.selected); // the highlight followed it
    editor.git.resolveStage(&editor, false);
    try t.expect(editor.git.mutation == null);

    // The selected file leaves the list: nothing happens, and the user is told.
    panel.show(&editor, .changes);
    panel.move(&editor, true);
    try t.expectEqualStrings("m.txt", panel.change_path.?);
    var gone = editor.git.changes.orderedRemove(1);
    t.allocator.free(gone.path);
    gone.path = &.{};
    editor.status_message = "";
    panel.action(&editor, 'u');
    try t.expect(editor.git.mutation == null);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "m.txt") != null);
    // The row now highlighted is remembered for the next press.
    try t.expectEqualStrings(editor.git.changes.items[panel.selected].path, panel.change_path.?);
    // A click (select) remembers its row immediately.
    panel.select(&editor, 0);
    try testChange(&editor, 0, "b.txt");
    panel.action(&editor, 's');
    try t.expectEqualStrings("a.txt", editor.git.mutation.?.path);
    editor.git.resolveStage(&editor, false);
}

test "Review rows show the verdict glyph and follow the selected file across refreshes" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    for ([_][]const u8{ "a.txt", "m.txt", "z.txt" }) |name| try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = "x\n" });
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.review.stage_on_approve = false;
    editor.git.root = try t.allocator.dupe(u8, root);
    try testChange(&editor, 0, "a.txt");
    try testChange(&editor, 1, "z.txt");
    editor.review.tick(&editor, 0);
    const panel = &editor.tool_panel;
    panel.show(&editor, .review);
    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("[ ] M a.txt", panel.row(&editor, 0, &buf));
    try t.expect(std.mem.indexOf(u8, panel.title(&editor, &buf), "0/2 reviewed, 0 needs work | baseline: last commit") != null);
    panel.move(&editor, true);
    try t.expectEqual(@as(usize, 1), panel.selected); // z.txt
    // A refresh lists m.txt above the selection before W is pressed.
    try testChange(&editor, 1, "m.txt");
    editor.git.revision += 1;
    editor.review.tick(&editor, 0);
    panel.action(&editor, 'w');
    try t.expectEqual(@import("review.zig").Status.needs_work, editor.review.statusOf("z.txt"));
    try t.expectEqual(@as(usize, 2), panel.selected); // the highlight followed it
    try t.expectEqualStrings("[!] M z.txt", panel.row(&editor, 2, &buf));
    try t.expect(std.mem.indexOf(u8, panel.title(&editor, &buf), "1/3 reviewed, 1 needs work") != null);
    panel.action(&editor, 'a');
    try t.expectEqualStrings("[x] M z.txt", panel.row(&editor, 2, &buf));
    // U follows the last commit again (P needs git; pinning is tested in
    // review.zig).
    editor.review.mode = .checkpoint;
    panel.action(&editor, 'u');
    try t.expectEqual(review.BaselineMode.head, editor.review.mode);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "last commit") != null);
    // Enter asks for the row's reader (the diff job is only recorded here);
    // O opens the real file.
    review.test_no_spawn = true;
    defer review.test_no_spawn = false;
    panel.activate(&editor);
    try t.expectEqualStrings("z.txt", editor.review.fetch.?.path);
    panel.action(&editor, 'o');
    try t.expect(std.mem.endsWith(u8, editor.activeDoc().file_path.?, "z.txt"));
}

test "Enter on a Task Output line uses the run's own Lua problem matcher" {
    const t = std.testing;
    const zlua = @import("zlua");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const target = try std.fs.path.join(t.allocator, &.{ base, "target.txt" });
    defer t.allocator.free(target);
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, target, "one\ntwo\nthree\n");
    var lua = try zlua.Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    @import("lua_settings.zig").registerApi(lua, &editor);
    try lua.doString(
        \\assert(zide.register_task({name='custom', argv={'unused'}, problem_matcher=function(line)
        \\  local file, row = line:match('^problem in (%S+) at (%d+)$')
        \\  if file then return {file=file, line=tonumber(row), col=2, message='m'} end
        \\end}))
    );
    // A finished run of that task, as request() would have made it.
    const source = editor.tasks.configs.items[0];
    const config = try tasks.Config.create(t.allocator, source.options);
    _ = lua.getIndexRaw(zlua.registry_index, source.matcher_ref.?);
    config.matcher_ref = lua.ref(zlua.registry_index);
    const run = t.allocator.create(tasks.Run) catch |err| {
        config.destroy(&editor);
        return err;
    };
    run.* = .{ .id = 77, .config = config, .cwd = try t.allocator.dupe(u8, base), .producer = try t.allocator.dupe(u8, "task:custom"), .status = .succeeded };
    try editor.tasks.runs.append(t.allocator, run);
    editor.tasks.selected_run = run.id;
    try run.output.append(t.allocator, "noise\nproblem in target.txt at 2\n");
    const panel = &editor.tool_panel;
    panel.show(&editor, .task_output);
    panel.activate(&editor); // "noise": no location
    try t.expectEqual(Editor.Mode.tool_panel, editor.mode);
    try t.expectEqualStrings("No file location on this line", editor.status_message);
    panel.move(&editor, true);
    panel.activate(&editor);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    const doc = editor.activeDoc();
    try t.expect(std.mem.endsWith(u8, doc.file_path.?, "target.txt"));
    try t.expectEqual(@as(usize, 5), doc.cursors.primary().offset); // line 2, column 2
    try t.expect(!editor.tasks.pumping);
}
