//! Explicit build/test tasks, managed output and source-specific diagnostics.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("editor.zig").Editor;
const lsp = @import("lsp.zig");
const zlua = @import("zlua");
const tool_output = @import("tool_output.zig");
pub const Env = struct { name: []const u8, value: []const u8 };
pub const Options = struct { name: []const u8, argv: []const []const u8, cwd: ?[]const u8 = null, env: []const Env = &.{}, zig_matcher: bool = false };
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    options: Options,
    matcher_ref: ?i32 = null,
    from_extension: bool = false,

    pub fn create(allocator: Allocator, options: Options) !*Config {
        if (options.name.len == 0 or options.argv.len == 0 or options.argv[0].len == 0) return error.InvalidTask;
        const self = try allocator.create(Config);
        errdefer allocator.destroy(self);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .options = options };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.options.name = try a.dupe(u8, options.name);
        const argv = try a.alloc([]const u8, options.argv.len);
        for (options.argv, argv) |arg, *owned| owned.* = try a.dupe(u8, arg);
        self.options.argv = argv;
        if (options.cwd) |cwd| self.options.cwd = try a.dupe(u8, cwd);
        const env = try a.alloc(Env, options.env.len);
        for (options.env, env) |item, *owned| owned.* = .{ .name = try a.dupe(u8, item.name), .value = try a.dupe(u8, item.value) };
        self.options.env = env;
        return self;
    }
    pub fn destroy(self: *Config, editor: *Editor) void {
        if (self.matcher_ref) |ref| if (editor.lua) |lua| lua.unref(zlua.registry_index, ref);
        self.arena.deinit();
        editor.allocator.destroy(self);
    }
};
pub const Status = enum { waiting, running, succeeded, failed, cancelled };
const Finding = struct { path: []u8, diagnostic: lsp.Diagnostic };
pub const Run = struct {
    id: u64,
    config: *Config,
    cwd: []u8,
    producer: []u8,
    status: Status = .waiting,
    job: ?u64 = null,
    exit_code: ?u8 = null,
    error_name: ?[]const u8 = null,
    /// The first problem-matcher failure of this run (a Lua matcher's error
    /// message, or the name of what was wrong with its result). Matching
    /// continues with the next line; later failures are not recorded.
    matcher_error: ?[]u8 = null,
    output: tool_output.Output = .{},
    filters: [2]tool_output.Sanitizer = .{ .{}, .{} },
    partial: [2]std.ArrayList(u8) = .{ .empty, .empty },
    line_truncated: [2]bool = .{ false, false },
    findings: std.ArrayList(Finding) = .empty,
    versions: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    truncated: bool = false,
    revision: u64 = 0,

    fn destroy(self: *Run, editor: *Editor) void {
        if (self.job) |job| editor.jobs.remove(job);
        self.config.destroy(editor);
        editor.allocator.free(self.cwd);
        editor.allocator.free(self.producer);
        if (self.matcher_error) |text| editor.allocator.free(text);
        self.output.deinit(editor.allocator);
        for (&self.partial) |*partial| partial.deinit(editor.allocator);
        for (self.findings.items) |finding| {
            editor.allocator.free(finding.path);
            finding.diagnostic.deinit(editor.allocator);
        }
        self.findings.deinit(editor.allocator);
        self.versions.deinit(editor.allocator);
        editor.allocator.destroy(self);
    }
};

pub const State = struct {
    configs: std.ArrayList(*Config) = .empty,
    runs: std.ArrayList(*Run) = .empty,
    next_id: u64 = 1,
    selected_run: ?u64 = null,
    pending: ?u64 = null,
    save_ids: std.ArrayList(u64) = .empty,
    save_index: usize = 0,
    waiting_save: bool = false,
    pumping: bool = false,

    pub fn deinit(self: *State, editor: *Editor) void {
        for (self.runs.items) |run| run.destroy(editor);
        self.runs.deinit(editor.allocator);
        for (self.configs.items) |config| config.destroy(editor);
        self.configs.deinit(editor.allocator);
        self.save_ids.deinit(editor.allocator);
    }

    pub fn register(self: *State, editor: *Editor, config: *Config) !void {
        for (self.configs.items) |*old| if (std.mem.eql(u8, old.*.options.name, config.options.name)) {
            self.cancelNamed(editor, config.options.name);
            old.*.destroy(editor);
            old.* = config;
            return;
        };
        if (self.configs.items.len >= 256) return error.TooManyTasks;
        try self.configs.append(editor.allocator, config);
    }

    pub fn get(self: *State, id: u64) ?*Run {
        for (self.runs.items) |run| if (run.id == id) return run;
        return null;
    }

    pub fn dropExtensions(self: *State, editor: *Editor) void {
        var i: usize = 0;
        while (i < self.configs.items.len) {
            const config = self.configs.items[i];
            if (!config.from_extension) {
                i += 1;
                continue;
            }
            self.cancelNamed(editor, config.options.name);
            config.destroy(editor);
            _ = self.configs.orderedRemove(i);
        }
    }

    fn cancelNamed(self: *State, editor: *Editor, name: []const u8) void {
        for (self.runs.items) |run| if (std.mem.eql(u8, run.config.options.name, name) and (run.status == .running or run.status == .waiting)) self.cancel(editor, run.id);
    }

    pub fn cancel(self: *State, editor: *Editor, id: u64) void {
        const run = self.get(id) orelse return;
        if (run.status != .running and run.status != .waiting) return;
        if (run.job) |job| editor.jobs.remove(job);
        run.job = null;
        run.status = .cancelled;
        run.revision +%= 1;
        if (self.pending == id) {
            self.pending = null;
            self.waiting_save = false;
            self.save_ids.clearRetainingCapacity();
            if (editor.mode == .task_save_prompt) editor.mode = .normal;
        }
    }

    /// Returns a stable task ID even when launch is waiting for the save prompt.
    pub fn request(self: *State, editor: *Editor, name: []const u8) !u64 {
        if (editor.mode != .normal and editor.mode != .tool_panel) return error.EditorBusy;
        if (self.pending != null) return error.TaskAlreadyWaitingForSave;
        var registration: ?*Config = null;
        for (self.configs.items) |config| if (std.mem.eql(u8, config.options.name, name)) {
            registration = config;
            break;
        };
        const source = registration orelse return error.TaskNotFound;
        if (self.runs.items.len >= 64 and !self.pumping) {
            for (self.runs.items, 0..) |old, index| {
                if (old.status == .running or old.status == .waiting) continue;
                _ = self.runs.orderedRemove(index);
                old.destroy(editor);
                break;
            }
        }
        if (self.runs.items.len >= 64) return error.TaskHistoryFull;
        const config = try Config.create(editor.allocator, source.options);
        errdefer config.destroy(editor);
        if (source.matcher_ref) |ref| if (editor.lua) |lua| {
            _ = lua.getIndexRaw(zlua.registry_index, ref);
            config.matcher_ref = lua.ref(zlua.registry_index);
        };
        const cwd = try std.fs.path.resolve(editor.allocator, &.{ editor.filetree_root orelse ".", source.options.cwd orelse "." });
        errdefer editor.allocator.free(cwd);
        const producer = try std.fmt.allocPrint(editor.allocator, "task:{s}", .{name});
        errdefer editor.allocator.free(producer);
        const run = try editor.allocator.create(Run);
        errdefer editor.allocator.destroy(run);
        run.* = .{ .id = self.next_id, .config = config, .cwd = cwd, .producer = producer };
        self.save_ids.clearRetainingCapacity();
        for (editor.documents.items) |doc| if (doc.dirty and !doc.preview) {
            // Untitled buffers belong to the active workspace too.
            if (doc.file_path) |path| {
                const root = editor.filetree_root orelse ".";
                const base = try @import("file_identity.zig").key(editor.allocator, editor.io, root);
                defer editor.allocator.free(base);
                const full = try @import("file_identity.zig").key(editor.allocator, editor.io, path);
                defer editor.allocator.free(full);
                if (full.len < base.len or !@import("file_identity.zig").equalKeys(full[0..base.len], base) or
                    (full.len > base.len and !std.fs.path.isSep(base[base.len - 1]) and !std.fs.path.isSep(full[base.len]))) continue;
            }
            try self.save_ids.append(editor.allocator, doc.id);
        };
        try self.runs.ensureUnusedCapacity(editor.allocator, 1);
        self.cancelNamed(editor, name);
        self.runs.appendAssumeCapacity(run);
        self.next_id += 1;
        self.selected_run = run.id;
        if (self.save_ids.items.len > 0) {
            self.pending = run.id;
            self.save_index = 0;
            self.waiting_save = false;
            editor.setMode(.task_save_prompt);
        } else self.launch(editor, run);
        return run.id;
    }

    fn launch(self: *State, editor: *Editor, run: *Run) void {
        self.pending = null;
        self.waiting_save = false;
        self.save_ids.clearRetainingCapacity();
        self.startJob(editor, run) catch |err| {
            run.status = .failed;
            run.error_name = @errorName(err);
            editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Task failed: {s}", .{@errorName(err)}) catch "Task failed";
        };
    }
    fn startJob(_: *State, editor: *Editor, run: *Run) !void {
        var env: ?std.process.Environ.Map = null;
        defer if (env) |*map| map.deinit();
        if (run.config.options.env.len > 0) {
            env = if (@import("lua_settings.zig").process_environ) |map| try map.clone(editor.allocator) else std.process.Environ.Map.init(editor.allocator);
            for (run.config.options.env) |item| try env.?.put(item.name, item.value);
        }
        for (editor.documents.items) |doc| try run.versions.put(editor.allocator, doc.id, doc.buffer.version);
        run.job = try editor.jobs.start(.{ .argv = run.config.options.argv, .cwd = run.cwd, .environ = if (env) |*map| map else null });
        run.status = .running;
        editor.problems.clear(.task, run.producer);
        for (editor.documents.items) |*doc| editor.problems.project(doc, .task) catch {};
        editor.status_message = "Task started";
    }

    /// Answer the task save prompt. Also Editor.setMode's leave hook for
    /// .task_save_prompt (as .cancel), so it leaves that mode with a guarded
    /// direct write and never calls setMode.
    pub fn resolveSave(self: *State, editor: *Editor, choice: enum { save, run, cancel }) void {
        if (editor.mode == .task_save_prompt) editor.mode = .normal;
        const id = self.pending orelse return;
        const run = self.get(id) orelse {
            // The run is gone: release the prompt state, or every later
            // request fails with TaskAlreadyWaitingForSave.
            self.pending = null;
            self.waiting_save = false;
            self.save_ids.clearRetainingCapacity();
            return;
        };
        switch (choice) {
            .cancel => self.cancel(editor, id),
            .run => self.launch(editor, run),
            .save => self.advanceSave(editor),
        }
    }

    fn advanceSave(self: *State, editor: *Editor) void {
        const id = self.pending orelse return;
        const run = self.get(id) orelse return;
        while (self.save_index < self.save_ids.items.len) {
            const doc_id = self.save_ids.items[self.save_index];
            const index = editor.docIndexForId(doc_id) orelse {
                self.save_index += 1;
                continue;
            };
            if (!editor.documents.items[index].dirty) {
                self.save_index += 1;
                continue;
            }
            self.waiting_save = true;
            const outcome = editor.saveDocument(doc_id, .{});
            switch (outcome) {
                .saved => {
                    if (editor.docIndexForId(doc_id)) |saved| if (editor.documents.items[saved].dirty) {
                        self.cancel(editor, id);
                        editor.status_message = "Task cancelled: a save hook changed the document";
                        return;
                    };
                    self.waiting_save = false;
                    self.save_index += 1;
                },
                .needs_path => {
                    editor.startSaveAs(doc_id, null);
                    return;
                },
                .formatting, .conflict, .destination_exists, .unrepresentable => return,
                .failed => {
                    self.cancel(editor, id);
                    return;
                },
            }
        }
        self.launch(editor, run);
    }

    pub fn tick(self: *State, editor: *Editor) void {
        if (self.pumping) return;
        self.pumping = true;
        defer self.pumping = false;
        if (self.waiting_save and self.pending != null and editor.mode == .normal and editor.lsp_tools.formatting == null) {
            const id = self.save_ids.items[self.save_index];
            const index = editor.docIndexForId(id);
            if (index != null and editor.documents.items[index.?].dirty) self.cancel(editor, self.pending.?) else {
                self.waiting_save = false;
                self.save_index += 1;
                self.advanceSave(editor);
            }
        }
        // Runs are heap allocated and retained, including across reentrant Lua matchers.
        var i: usize = 0;
        while (i < self.runs.items.len) : (i += 1) {
            const run = self.runs.items[i];
            if (run.status != .running) continue;
            const job = editor.jobs.get(run.job orelse continue) orelse continue;
            const snapshot = job.snapshot(editor.allocator, true) catch continue;
            defer snapshot.deinit(editor.allocator);
            const old_count = run.findings.items.len;
            for ([_][]const u8{ snapshot.stdout, snapshot.stderr }, 0..) |bytes, stream| {
                var clean: std.ArrayList(u8) = .empty;
                defer clean.deinit(editor.allocator);
                run.filters[stream].feed(editor.allocator, &clean, bytes, snapshot.done) catch {
                    run.truncated = true;
                };
                run.output.append(editor.allocator, clean.items) catch {
                    run.truncated = true;
                };
                consume(editor, run, stream, clean.items, snapshot.done) catch |err| {
                    run.error_name = @errorName(err);
                };
                if (run.status != .running) break;
            }
            if (run.status != .running) continue;
            run.truncated = run.truncated or snapshot.truncated or run.output.truncated;
            run.revision = snapshot.revision;
            if (run.findings.items.len != old_count) publish(editor, run) catch |err| {
                run.error_name = @errorName(err);
            };
            if (snapshot.done) {
                run.exit_code = snapshot.code;
                if (snapshot.failure) |err| run.error_name = @errorName(err);
                run.status = if (snapshot.cancelled) .cancelled else if (snapshot.failure != null or snapshot.code != 0) .failed else .succeeded;
                editor.jobs.remove(run.job.?);
                run.job = null;
                editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Task {s}: {s}", .{ run.config.options.name, @tagName(run.status) }) catch "Task finished";
            }
        }
    }
};

fn consume(editor: *Editor, run: *Run, stream: usize, bytes: []const u8, done: bool) !void {
    const partial = &run.partial[stream];
    for (bytes) |byte| {
        if (byte == '\n') {
            // matchLine never fails: a matcher error must neither skip the
            // rest of the chunk nor glue this line onto the next one (G3).
            if (!run.line_truncated[stream]) matchLine(editor, run, std.mem.trimEnd(u8, partial.items, "\r"));
            partial.clearRetainingCapacity();
            run.line_truncated[stream] = false;
            if (run.status != .running) return;
        } else if (partial.items.len < 64 * 1024) {
            try partial.append(editor.allocator, byte);
        } else {
            run.line_truncated[stream] = true;
            run.truncated = true;
        }
    }
    if (done and partial.items.len > 0) {
        if (!run.line_truncated[stream]) matchLine(editor, run, std.mem.trimEnd(u8, partial.items, "\r"));
        partial.clearRetainingCapacity();
    }
}

/// Record the first problem-matcher failure of `run` (see Run.matcher_error)
/// and say so once in the status bar.
pub fn noteMatcherError(editor: *Editor, run: *Run, message: []const u8) void {
    if (run.matcher_error != null) return;
    const text = message[0..@import("text_input.zig").floor(message, 256)];
    run.matcher_error = editor.allocator.dupe(u8, text) catch return;
    editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Task {s}: problem matcher failed (see Task Output)", .{run.config.options.name}) catch "Task problem matcher failed (see Task Output)";
}

pub const Location = struct { path: []const u8, line: u32, col: u32, severity: lsp.DiagnosticSeverity, message: []const u8 };
pub fn zigLocation(line: []const u8) ?Location {
    const markers = [_][]const u8{ ": error: ", ": warning: ", ": note: " };
    for (markers, 0..) |marker, severity| if (std.mem.indexOf(u8, line, marker)) |end| {
        const col_at = std.mem.lastIndexOfScalar(u8, line[0..end], ':') orelse return null;
        const row_at = std.mem.lastIndexOfScalar(u8, line[0..col_at], ':') orelse return null;
        const row = std.fmt.parseInt(u32, line[row_at + 1 .. col_at], 10) catch return null;
        const col = std.fmt.parseInt(u32, line[col_at + 1 .. end], 10) catch return null;
        if (row == 0 or col == 0 or row_at == 0) return null;
        return .{ .path = line[0..row_at], .line = row - 1, .col = col - 1, .severity = switch (severity) {
            0 => .err,
            1 => .warning,
            else => .information,
        }, .message = line[end + marker.len ..] };
    };
    return null;
}

fn matchLine(editor: *Editor, run: *Run, line: []const u8) void {
    if (run.findings.items.len >= 10_000) {
        run.truncated = true;
        return;
    }
    const result = if (run.config.options.zig_matcher)
        addFinding(editor, run, zigLocation(line) orelse return)
    else if (run.config.matcher_ref) |ref|
        @import("task_lua.zig").match(editor, run, ref, line)
    else
        return;
    result catch |err| noteMatcherError(editor, run, @errorName(err));
}

/// A file location on one Task Output line, found by the run's own problem
/// matcher (Lua or zig; zig syntax for runs without one). `path` is resolved
/// against the run's cwd and owned by the caller.
pub const Found = struct { path: []u8, line: u32, col: u32 };
pub fn locate(editor: *Editor, run: *Run, line: []const u8) ?Found {
    if (run.config.matcher_ref) |ref| {
        const state = &editor.tasks;
        if (state.pumping) return null;
        // Keeps `run` alive across the Lua call (request() trims history
        // only while not pumping) and holds off tick().
        state.pumping = true;
        defer state.pumping = false;
        return @import("task_lua.zig").locate(editor, ref, run.cwd, line);
    }
    const location = zigLocation(line) orelse return null;
    const path = std.fs.path.resolve(editor.allocator, &.{ run.cwd, location.path }) catch return null;
    return .{ .path = path, .line = location.line, .col = location.col };
}

pub fn addFinding(editor: *Editor, run: *Run, location: Location) !void {
    if (run.status != .running) return;
    const absolute = try std.fs.path.resolve(editor.allocator, &.{ run.cwd, location.path });
    defer editor.allocator.free(absolute);
    const path = try @import("file_identity.zig").key(editor.allocator, editor.io, absolute);
    errdefer editor.allocator.free(path);
    const message = try editor.allocator.dupe(u8, location.message);
    errdefer editor.allocator.free(message);
    try run.findings.append(editor.allocator, .{ .path = path, .diagnostic = .{
        .start_line = location.line,
        .end_line = location.line,
        .start_col = location.col,
        .end_col = location.col +| 1,
        .severity = location.severity,
        .message = message,
    } });
}

fn publish(editor: *Editor, run: *Run) !void {
    var groups: std.StringHashMapUnmanaged(std.ArrayList(lsp.Diagnostic)) = .empty;
    defer {
        var values = groups.valueIterator();
        while (values.next()) |value| value.deinit(editor.allocator);
        groups.deinit(editor.allocator);
    }
    for (run.findings.items) |finding| {
        const group = try groups.getOrPut(editor.allocator, finding.path);
        if (!group.found_existing) group.value_ptr.* = .empty;
        try group.value_ptr.append(editor.allocator, finding.diagnostic);
    }
    var iterator = groups.iterator();
    while (iterator.next()) |group| try editor.problems.replace(group.key_ptr.*, run.producer, .task, null, .bytes, group.value_ptr.items);
    for (editor.problems.entries.items) |*entry| {
        if (entry.kind != .task or !std.mem.eql(u8, entry.producer, run.producer)) continue;
        if (try editor.findDocument(entry.path)) |index| {
            const doc = &editor.documents.items[index];
            entry.task_doc_id = doc.id;
            entry.task_buffer_version = run.versions.get(doc.id);
        }
    }
    for (editor.documents.items) |*doc| try editor.problems.project(doc, .task);
}

test "Zig task matcher accepts drive paths, spaces and Unicode with one-based columns" {
    const t = std.testing;
    const loc = zigLocation("C:\\project files\\café.zig:12:7: error: expected type 'u8'").?;
    try t.expectEqualStrings("C:\\project files\\café.zig", loc.path);
    try t.expectEqual(@as(u32, 11), loc.line);
    try t.expectEqual(@as(u32, 6), loc.col);
    try t.expect(zigLocation("not a diagnostic") == null);
}

fn waitForTest(editor: *Editor, id: u64) !*Run {
    for (0..6000) |_| {
        editor.tasks.tick(editor);
        const run = editor.tasks.get(id).?;
        if (run.status != .waiting and run.status != .running) return run;
        try std.Io.sleep(editor.io, .fromMilliseconds(10), .awake);
    }
    return error.TaskTestTimeout;
}

test "tasks stream both pipes, isolate producers, navigate closed files and reject cancelled saves" {
    const t = std.testing;
    const windows = @import("builtin").os.tag == .windows;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(t.io, "sample file.txt", .{});
    try file.writeStreamingAll(t.io, "zero\nnext\n");
    file.close(t.io);
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const path = try std.fs.path.join(t.allocator, &.{ base, "sample file.txt" });
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, base);
    const config = try Config.create(t.allocator, .{ .name = "check", .zig_matcher = true, .argv = if (windows)
        &.{ "cmd", "/d", "/c", "echo sample file.txt:2:2: error: test diagnostic & echo stderr-line 1>&2 & exit /b 3" }
    else
        &.{ "sh", "-c", "printf 'sample file.txt:2:2: error: test diagnostic\n'; printf 'stderr-line\n' >&2; exit 3" } });
    try editor.tasks.register(&editor, config);
    const diagnostic: lsp.Diagnostic = .{ .start_line = 0, .end_line = 0, .start_col = 0, .end_col = 1, .severity = .warning, .message = "other tool" };
    try editor.problems.replace(path, "linter", .lua, null, .bytes, &.{diagnostic});
    const id = try editor.tasks.request(&editor, "check");
    const run = try waitForTest(&editor, id);
    try t.expectEqual(Status.failed, run.status);
    try t.expectEqual(@as(?u8, 3), run.exit_code);
    try t.expect(std.mem.indexOf(u8, run.output.text.items, "stderr-line") != null);
    try t.expectEqual(@as(usize, 2), editor.problems.entries.items.len);
    editor.tool_panel.show(&editor, .problems);
    editor.tool_panel.severity = .err;
    try t.expectEqual(@as(usize, 1), editor.tool_panel.count(&editor));
    editor.tool_panel.activate(&editor);
    try t.expectEqual(@as(usize, 6), editor.activeDoc().cursors.primary().offset);
    try editor.activeDoc().insertAtCursor("dirty");
    const waiting = try editor.tasks.request(&editor, "check");
    try t.expectEqual(Editor.Mode.task_save_prompt, editor.mode);
    try t.expect(editor.tasks.get(waiting).?.job == null);
    editor.tasks.resolveSave(&editor, .cancel);
    try t.expectEqual(Status.cancelled, editor.tasks.get(waiting).?.status);
    const rerun = try editor.tasks.request(&editor, "check");
    editor.tasks.resolveSave(&editor, .save);
    _ = try waitForTest(&editor, rerun);
    try t.expect(!editor.activeDoc().dirty);
    try t.expectEqual(@as(usize, 2), editor.problems.entries.items.len);
    const absent = try Config.create(t.allocator, .{ .name = "missing", .argv = &.{"zide-test-no-such-task-executable"} });
    try editor.tasks.register(&editor, absent);
    const missing = try waitForTest(&editor, try editor.tasks.request(&editor, "missing"));
    try t.expectEqual(Status.failed, missing.status);
    try t.expect(missing.error_name != null);
}

test "task Lua matchers own registrations, cancel old runs on reload and retain Unicode diagnostics" {
    const t = std.testing;
    var lua = try zlua.Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    @import("lua_settings.zig").registerApi(lua, &editor);
    editor.loading_extensions = true;
    try lua.doString(
        \\assert(zide.register_task({name='lua-check', argv={'unused'}, problem_matcher=function(line)
        \\  return {file='café file.txt',line=2,col=3,severity='warning',message=line}
        \\end}))
    );
    editor.loading_extensions = false;
    const config = try Config.create(t.allocator, editor.tasks.configs.items[0].options);
    defer config.destroy(&editor);
    var run: Run = .{ .id = 999, .config = config, .cwd = @constCast("."), .producer = @constCast("test"), .status = .running };
    defer {
        for (run.findings.items) |finding| {
            t.allocator.free(finding.path);
            finding.diagnostic.deinit(t.allocator);
        }
        run.findings.deinit(t.allocator);
    }
    try @import("task_lua.zig").match(&editor, &run, editor.tasks.configs.items[0].matcher_ref.?, "message");
    try t.expect(std.mem.endsWith(u8, run.findings.items[0].path, "café file.txt"));
    try t.expectEqual(@as(u32, 2), run.findings.items[0].diagnostic.start_col);
    editor.tasks.dropExtensions(&editor);
    try t.expectEqual(@as(usize, 0), editor.tasks.configs.items.len);
}

test "a failing Lua matcher line never drops the rest of the chunk or glues onto the next one" {
    const t = std.testing;
    var lua = try zlua.Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    @import("lua_settings.zig").registerApi(lua, &editor);
    try lua.doString(
        \\assert(zide.register_task({name='flaky', argv={'unused'}, problem_matcher=function(line)
        \\  if line:sub(1, 3) == 'bad' then error('matcher exploded on ' .. line) end
        \\  if line:sub(1, 4) == 'trap' then
        \\    return setmetatable({}, {__index = function() error('index trap') end})
        \\  end
        \\  return {file='out.txt', line=1, col=1, message=line}
        \\end}))
    );
    const config = try Config.create(t.allocator, editor.tasks.configs.items[0].options);
    defer config.destroy(&editor);
    var run: Run = .{ .id = 998, .config = config, .cwd = @constCast("."), .producer = @constCast("test"), .status = .running };
    defer {
        for (run.findings.items) |finding| {
            t.allocator.free(finding.path);
            finding.diagnostic.deinit(t.allocator);
        }
        run.findings.deinit(t.allocator);
        for (&run.partial) |*partial| partial.deinit(t.allocator);
        if (run.matcher_error) |text| t.allocator.free(text);
    }
    run.config.matcher_ref = editor.tasks.configs.items[0].matcher_ref; // borrowed: cleared below
    defer run.config.matcher_ref = null;
    try consume(&editor, &run, 0, "ok1\nbad1\nok2\n", false);
    try t.expectEqual(@as(usize, 0), run.partial[0].items.len);
    try t.expectEqual(@as(usize, 2), run.findings.items.len);
    try consume(&editor, &run, 0, "trap1\nok3\nbad2\nok4", true);
    try t.expectEqual(@as(usize, 0), run.partial[0].items.len);
    try t.expectEqual(@as(usize, 4), run.findings.items.len);
    for (run.findings.items, [_][]const u8{ "ok1", "ok2", "ok3", "ok4" }) |finding, text| try t.expectEqualStrings(text, finding.diagnostic.message);
    // The first failure is kept, with the Lua message.
    try t.expect(std.mem.indexOf(u8, run.matcher_error.?, "matcher exploded on bad1") != null);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "flaky") != null);
    try t.expectEqual(@as(c_int, 0), lua.getTop());
}

test "resolving the save prompt of a vanished run still releases the prompt state" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.tasks.pending = 424242; // no such run
    try editor.tasks.save_ids.append(t.allocator, 1);
    editor.tasks.waiting_save = true;
    editor.mode = .task_save_prompt;
    editor.tasks.resolveSave(&editor, .cancel);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.tasks.pending == null);
    try t.expect(!editor.tasks.waiting_save);
    try t.expectEqual(@as(usize, 0), editor.tasks.save_ids.items.len);
    // The same through the mode change that leaves the prompt.
    editor.tasks.pending = 424243;
    try editor.tasks.save_ids.append(t.allocator, 2);
    editor.mode = .task_save_prompt;
    editor.setMode(.tool_panel);
    try t.expectEqual(Editor.Mode.tool_panel, editor.mode);
    try t.expect(editor.tasks.pending == null);
    try t.expectEqual(@as(usize, 0), editor.tasks.save_ids.items.len);
}

test "Zig task integration succeeds, reports a Unicode source failure and cancels a replaced run" {
    if (!@import("build_options").test_tools) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const path = try std.fs.path.join(t.allocator, &.{ base, "café test.zig" });
    defer t.allocator.free(path);
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, path, "test \"works\" {}\n");
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.filetree_root = try t.allocator.dupe(u8, base);
    try editor.tasks.register(&editor, try Config.create(t.allocator, .{ .name = "Zig test", .argv = &.{ @import("build_options").zig_exe, "test", path, "--color", "off" }, .zig_matcher = true }));
    const first = try waitForTest(&editor, try editor.tasks.request(&editor, "Zig test"));
    try t.expectEqual(Status.succeeded, first.status);
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, path, "test \"broken\" { const bad: u8 = \"string\"; _ = bad; }\n");
    const failed = try waitForTest(&editor, try editor.tasks.request(&editor, "Zig test"));
    try t.expectEqual(Status.failed, failed.status);
    try t.expect(failed.findings.items.len > 0);
    try t.expect(std.mem.endsWith(u8, failed.findings.items[0].path, "café test.zig"));
    const old = try editor.tasks.request(&editor, "Zig test");
    const newer = try editor.tasks.request(&editor, "Zig test");
    try t.expectEqual(Status.cancelled, editor.tasks.get(old).?.status);
    editor.tasks.cancel(&editor, newer);
    try t.expectEqual(Status.cancelled, editor.tasks.get(newer).?.status);
}
