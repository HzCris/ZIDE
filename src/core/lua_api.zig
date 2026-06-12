//! Lua extension runtime — the API surface extensions call beyond plain
//! configuration (lua_settings.zig owns set/get/bind and file loading).
//!
//! Single Lua state, main thread only: callbacks fire from the frontends'
//! main loops, and worker threads must never touch the state. Every
//! callback runs under protectedCall — a broken extension reports to the
//! status bar and the log; it can never crash the editor.

const std = @import("std");
const zlua = @import("zlua");
const Editor = @import("editor.zig").Editor;
const Document = @import("document.zig").Document;
const lua_settings = @import("lua_settings.zig");
const lsp_mod = @import("lsp.zig");
const filetree_mod = @import("filetree.zig");

const Lua = zlua.Lua;

/// Events extensions can hook via zide.on(name, fn). The Lua-side names
/// are the enum tag names ("open", "save").
pub const LuaEvent = enum { open, save };

/// Per-event lists of Lua registry refs (the registered handlers).
pub const EventRefs = std.EnumArray(LuaEvent, std.ArrayList(i32));

/// Cap on nested event firing (e.g. a save handler that saves again).
const max_event_depth = 8;

/// Register the extension API onto the `zide` table at the top of the
/// stack and point the editor at the Lua state so core code can fire
/// events. Called from lua_settings.registerApi while the table is open.
pub fn registerInto(lua: *Lua, editor: *Editor) void {
    editor.lua = lua;

    lua.pushFunction(&luaCommand);
    lua.setField(-2, "command");
    lua.pushFunction(&luaOn);
    lua.setField(-2, "on");
    lua.pushFunction(&luaExec);
    lua.setField(-2, "exec");
    lua.pushFunction(&luaStatus);
    lua.setField(-2, "status");

    // Buffer API (active document)
    lua.pushFunction(&luaLineCount);
    lua.setField(-2, "line_count");
    lua.pushFunction(&luaGetLine);
    lua.setField(-2, "get_line");
    lua.pushFunction(&luaGetText);
    lua.setField(-2, "get_text");
    lua.pushFunction(&luaCursor);
    lua.setField(-2, "cursor");
    lua.pushFunction(&luaSetCursor);
    lua.setField(-2, "set_cursor");
    lua.pushFunction(&luaFilePath);
    lua.setField(-2, "file_path");
    lua.pushFunction(&luaLanguage);
    lua.setField(-2, "language");
    lua.pushFunction(&luaSelection);
    lua.setField(-2, "selection");
    lua.pushFunction(&luaInsert);
    lua.setField(-2, "insert");
    lua.pushFunction(&luaSetLine);
    lua.setField(-2, "set_line");

    // Process running
    lua.pushFunction(&luaRun);
    lua.setField(-2, "run");
    lua.pushFunction(&luaSpawn);
    lua.setField(-2, "spawn");

    // Diagnostics
    lua.pushFunction(&luaSetDiagnostics);
    lua.setField(-2, "set_diagnostics");
}

// ---------------------------------------------------------------------------
// Firing into Lua (called from core / frontends)
// ---------------------------------------------------------------------------

/// Report the error object at the top of the Lua stack and pop it.
fn reportLuaError(editor: *Editor, lua: *Lua, what: []const u8) void {
    const err_z: [:0]const u8 = lua.toString(-1) catch "(non-string error)";
    const err_msg: []const u8 = err_z;
    // warn, not err: extension bugs are user-script problems the editor
    // survives (and err-level logs fail `zig build test`).
    std.log.warn("Lua {s} failed: {s}", .{ what, err_msg });
    const shown = err_msg[0..@min(err_msg.len, 100)];
    editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Extension error: {s}", .{shown}) catch "Extension error (see zide.log)";
    lua.pop(1);
}

/// Fire an event to all registered Lua handlers. `path` becomes the
/// handler's single argument (nil when null). Safe with no Lua state.
pub fn fireEvent(editor: *Editor, event: LuaEvent, path: ?[]const u8) void {
    const lua = editor.lua orelse return;
    if (editor.lua_event_depth >= max_event_depth) {
        std.log.warn("zide.on({s}): event recursion too deep, handlers skipped", .{@tagName(event)});
        return;
    }
    editor.lua_event_depth += 1;
    defer editor.lua_event_depth -= 1;
    // Index-based walk: a handler may register more handlers mid-fire,
    // which can reallocate the list under a held slice.
    var i: usize = 0;
    while (i < editor.lua_event_refs.getPtr(event).items.len) : (i += 1) {
        const r = editor.lua_event_refs.getPtr(event).items[i];
        _ = lua.getIndexRaw(zlua.registry_index, @intCast(r));
        if (path) |p| {
            _ = lua.pushString(p);
        } else {
            lua.pushNil();
        }
        lua.protectedCall(.{ .args = 1 }) catch reportLuaError(editor, lua, "event handler");
    }
}

/// Invoke a Lua-registered command (CommandRegistry.execute routes here).
pub fn callLuaCommand(editor: *Editor, ref: i32, args: ?[]const u8) void {
    const lua = editor.lua orelse return;
    _ = lua.getIndexRaw(zlua.registry_index, @intCast(ref));
    if (args) |a| {
        _ = lua.pushString(a);
    } else {
        lua.pushNil();
    }
    lua.protectedCall(.{ .args = 1 }) catch reportLuaError(editor, lua, "command");
}

/// Drop every Lua-registered command and event handler (reload/shutdown).
/// Registry refs are released while the state is still alive.
pub fn cleanupLuaRefs(editor: *Editor) void {
    var refs: std.ArrayList(i32) = .empty;
    defer refs.deinit(editor.allocator);
    editor.commands.removeLuaCommands(&refs);
    if (editor.lua) |lua| {
        for (refs.items) |r| lua.unref(zlua.registry_index, r);
    }
    inline for (comptime std.meta.tags(LuaEvent)) |ev| {
        const list = editor.lua_event_refs.getPtr(ev);
        if (editor.lua) |lua| {
            for (list.items) |r| lua.unref(zlua.registry_index, r);
        }
        list.clearRetainingCapacity();
    }
    // A removed lint extension's stale squiggles shouldn't survive reload.
    for (editor.documents.items) |*doc| doc.clearLintDiagnostics();
}

/// Full teardown for Editor.deinit (also frees the ref lists). Must run
/// before the command registry deinits and while the Lua state is alive.
pub fn deinitLua(editor: *Editor) void {
    cleanupLuaRefs(editor);
    inline for (comptime std.meta.tags(LuaEvent)) |ev| {
        editor.lua_event_refs.getPtr(ev).deinit(editor.allocator);
    }
    // Detach from spawn workers: queued results are dropped (their Lua
    // refs die with the state); in-flight workers free the state when the
    // last one finishes.
    if (editor.lua_spawn) |state| {
        state.mutex.lockUncancelable(editor.io);
        state.alive = false;
        for (state.jobs.items) |job| freeJob(state.allocator, job);
        state.jobs.clearRetainingCapacity();
        const workers_in_flight = state.active != 0;
        state.mutex.unlock(editor.io);
        if (!workers_in_flight) state.destroy();
        editor.lua_spawn = null;
    }
}

/// Re-run every extensions/*.lua after dropping prior Lua commands and
/// handlers. Lua-side globals persist across reloads (harmless).
pub fn reloadExtensions(editor: *Editor) void {
    const lua = editor.lua orelse {
        editor.status_message = "Extensions: no Lua state available";
        return;
    };
    cleanupLuaRefs(editor);
    lua_settings.loadExtensions(lua);
    editor.status_message = "Extensions reloaded";
}

// ---------------------------------------------------------------------------
// zide.* callback implementations
// ---------------------------------------------------------------------------

/// zide.command(name, description, fn) — register a command that shows up
/// in the palette and can be bound via zide.bind.
fn luaCommand(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;

    const name_z = lua.toString(1) catch {
        std.log.warn("zide.command: name (string) required", .{});
        return 0;
    };
    const name: []const u8 = name_z;
    if (name.len == 0) {
        std.log.warn("zide.command: name must not be empty", .{});
        return 0;
    }
    const desc: []const u8 = if (lua.typeOf(2) == .string) (lua.toString(2) catch "") else "";
    if (!lua.isFunction(3)) {
        std.log.warn("zide.command: third argument must be a function", .{});
        return 0;
    }

    lua.pushValue(3);
    const ref = lua.ref(zlua.registry_index);

    const a = editor.allocator;
    const owned_name = a.dupe(u8, name) catch {
        lua.unref(zlua.registry_index, ref);
        return 0;
    };
    const owned_desc = a.dupe(u8, desc) catch {
        a.free(owned_name);
        lua.unref(zlua.registry_index, ref);
        return 0;
    };
    const prev = editor.commands.registerLua(owned_name, owned_desc, ref) catch {
        a.free(owned_name);
        a.free(owned_desc);
        lua.unref(zlua.registry_index, ref);
        std.log.err("zide.command: failed to register '{s}'", .{name});
        return 0;
    };
    if (prev) |old_ref| lua.unref(zlua.registry_index, old_ref);
    return 0;
}

/// zide.on(event, fn) — hook an editor event ("open", "save"). The
/// handler receives the file path (nil for untitled buffers).
fn luaOn(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;

    const ev_z = lua.toString(1) catch {
        std.log.warn("zide.on: event name (string) required", .{});
        return 0;
    };
    const event = std.meta.stringToEnum(LuaEvent, ev_z) orelse {
        std.log.warn("zide.on: unknown event '{s}' (have: open, save)", .{ev_z});
        return 0;
    };
    if (!lua.isFunction(2)) {
        std.log.warn("zide.on: second argument must be a function", .{});
        return 0;
    }
    lua.pushValue(2);
    const ref = lua.ref(zlua.registry_index);
    editor.lua_event_refs.getPtr(event).append(editor.allocator, ref) catch {
        lua.unref(zlua.registry_index, ref);
        std.log.err("zide.on: failed to register handler", .{});
    };
    return 0;
}

/// zide.exec(name) -> bool — run any editor action or command by name
/// (same names zide.bind accepts: "save", "undo", Lua commands, …).
fn luaExec(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const name_z = lua.toString(1) catch {
        std.log.warn("zide.exec: command name (string) required", .{});
        lua.pushBoolean(false);
        return 1;
    };
    lua.pushBoolean(editor.execAction(name_z));
    return 1;
}

/// zide.status(msg) — show a transient message in the status bar.
fn luaStatus(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const msg_z = lua.toString(1) catch return 0;
    const msg: []const u8 = msg_z;
    // Copy: the Lua string is GC-owned and dies with the callback.
    const n = @min(msg.len, editor.status_buf.len);
    @memcpy(editor.status_buf[0..n], msg[0..n]);
    editor.status_message = editor.status_buf[0..n];
    return 0;
}

// ---------------------------------------------------------------------------
// Buffer API — all calls act on the active document. Lines and columns
// are 1-based on the Lua side. Mutations go through Document ops only,
// so undo history and LSP sync stay correct.
// ---------------------------------------------------------------------------

/// zide.line_count() -> integer
fn luaLineCount(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    lua.pushInteger(@intCast(editor.activeDoc().lineCount()));
    return 1;
}

/// zide.get_line(n) -> string | nil — line content without the newline.
fn luaGetLine(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const doc = editor.activeDoc();
    const n = lua.toInteger(1) catch {
        lua.pushNil();
        return 1;
    };
    if (n < 1 or @as(usize, @intCast(n)) > doc.lineCount()) {
        lua.pushNil();
        return 1;
    }
    _ = lua.pushString(doc.lineContent(@intCast(n - 1)));
    return 1;
}

/// zide.get_text() -> string — the whole buffer.
fn luaGetText(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const doc = editor.activeDoc();
    // slice() may return the buffer's shared scratch; pushString copies
    // into the Lua heap immediately, so that's fine.
    _ = lua.pushString(doc.buffer.slice(0, doc.buffer.byteLen()));
    return 1;
}

/// zide.cursor() -> line, col (primary cursor, both 1-based).
fn luaCursor(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const pos = editor.activeDoc().cursorPos();
    lua.pushInteger(@intCast(pos.line + 1));
    lua.pushInteger(@intCast(pos.col + 1));
    return 2;
}

/// zide.set_cursor(line, col) — move the primary cursor (clamped); drops
/// secondary cursors and any selection.
fn luaSetCursor(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const doc = editor.activeDoc();
    const line_arg = lua.toInteger(1) catch return 0;
    const col_arg = lua.toInteger(2) catch 1;

    const line: usize = @intCast(std.math.clamp(line_arg, 1, @as(i64, @intCast(doc.lineCount()))) - 1);
    const line_len = doc.lineContent(line).len;
    const col: usize = @intCast(std.math.clamp(col_arg - 1, 0, @as(i64, @intCast(line_len))));

    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
    c.clearSelection();
    c.offset = doc.buffer.posToOffset(line, col);
    c.preferred_col = col;
    return 0;
}

/// zide.file_path() -> string | nil
fn luaFilePath(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    if (editor.activeDoc().file_path) |p| {
        _ = lua.pushString(p);
    } else {
        lua.pushNil();
    }
    return 1;
}

/// zide.language() -> string | nil — detected language name.
fn luaLanguage(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    if (editor.activeDoc().language) |lang| {
        _ = lua.pushString(lang.name);
    } else {
        lua.pushNil();
    }
    return 1;
}

/// zide.selection() -> string | nil — primary cursor's selected text.
fn luaSelection(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    if (editor.activeDoc().selectedText()) |text| {
        _ = lua.pushString(text);
    } else {
        lua.pushNil();
    }
    return 1;
}

/// zide.insert(text) — insert at the primary cursor; an active selection
/// is replaced (single undo step). This is also the "replace selection".
fn luaInsert(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const text_z = lua.toString(1) catch {
        std.log.warn("zide.insert: text (string) required", .{});
        return 0;
    };
    editor.activeDoc().insertAtCursor(text_z) catch |err| {
        std.log.warn("zide.insert failed: {s}", .{@errorName(err)});
    };
    return 0;
}

/// zide.set_line(n, text) — replace line n's content (one undo step).
/// Out-of-range lines are ignored.
fn luaSetLine(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const doc = editor.activeDoc();
    const n = lua.toInteger(1) catch return 0;
    const text_z = lua.toString(2) catch {
        std.log.warn("zide.set_line: text (string) required", .{});
        return 0;
    };
    if (n < 1 or @as(usize, @intCast(n)) > doc.lineCount()) {
        std.log.warn("zide.set_line: line {d} out of range", .{n});
        return 0;
    }
    const line: usize = @intCast(n - 1);
    const start = doc.buffer.posToOffset(line, 0);
    const old_len = doc.lineContent(line).len;

    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
    doc.history.beginGroup();
    defer doc.history.endGroup();
    if (old_len > 0) {
        c.anchor = start;
        c.offset = start + old_len;
        doc.deleteSelection() catch |err| {
            std.log.warn("zide.set_line failed: {s}", .{@errorName(err)});
            return 0;
        };
    } else {
        c.clearSelection();
        c.offset = start;
    }
    doc.insertAtCursor(text_z) catch |err| {
        std.log.warn("zide.set_line failed: {s}", .{@errorName(err)});
    };
    return 0;
}

// ---------------------------------------------------------------------------
// Process running — zide.run (synchronous) and zide.spawn (worker thread).
// Workers never touch the Lua state: results travel through a mutex'd
// queue and the main loop's pumpLuaJobs delivers them to the callbacks.
// ---------------------------------------------------------------------------

const spawn_stdout_limit = 4 * 1024 * 1024;
const spawn_stderr_limit = 256 * 1024;

/// A finished zide.spawn job traveling from a worker to the main thread.
pub const LuaJob = struct {
    /// Lua registry ref of the callback (released by the deliverer).
    ref: i32,
    /// Exit code, or null when the tool didn't exit normally.
    code: ?i64,
    stdout: []u8,
    stderr: []u8,
    /// Static error name when the run itself failed (spawn error, timeout,
    /// signal, …).
    err_name: ?[]const u8,
};

/// Shared between the editor and detached worker threads. Heap-allocated;
/// freed by whichever side lets go last (`alive` flag + `active` count).
pub const SpawnState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Editor still consuming results (cleared in deinitLua).
    alive: bool = true,
    /// Worker threads in flight.
    active: usize = 0,
    jobs: std.ArrayList(LuaJob) = .empty,
    wake_fn: ?*const fn () void = null,

    fn destroy(self: *SpawnState) void {
        const a = self.allocator;
        self.jobs.deinit(a);
        a.destroy(self);
    }
};

fn freeJob(allocator: std.mem.Allocator, job: LuaJob) void {
    allocator.free(job.stdout);
    allocator.free(job.stderr);
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

/// Read a positional table of strings at `index` into owned slices.
fn readArgvAlloc(lua: *Lua, allocator: std.mem.Allocator, index: i32) ?[]const []const u8 {
    if (lua.typeOf(index) != .table) return null;
    const len = lua.lenRaw(index);
    if (len == 0) return null;
    var list = std.ArrayList([]const u8).initCapacity(allocator, len) catch return null;
    // Error paths free elements + deinit the list — list.items can't be
    // handed to free() directly (capacity may exceed len; see allNames).
    var i: usize = 1;
    while (i <= len) : (i += 1) {
        _ = lua.getIndexRaw(index, @intCast(i));
        defer lua.pop(1);
        const ok: ?[]const u8 = blk: {
            const s = lua.toString(-1) catch break :blk null;
            break :blk allocator.dupe(u8, s) catch null;
        };
        const duped = ok orelse {
            for (list.items) |it| allocator.free(it);
            list.deinit(allocator);
            return null;
        };
        list.appendAssumeCapacity(duped);
    }
    return list.toOwnedSlice(allocator) catch {
        for (list.items) |it| allocator.free(it);
        list.deinit(allocator);
        return null;
    };
}

fn ensureSpawnState(editor: *Editor) ?*SpawnState {
    if (editor.lua_spawn) |s| return s;
    const s = editor.allocator.create(SpawnState) catch return null;
    s.* = .{
        .allocator = editor.allocator,
        .io = editor.io,
        .wake_fn = editor.lua_wake_fn,
    };
    editor.lua_spawn = s;
    return s;
}

/// Point spawn-result wakes at the frontend's loop (TUI). Also updates an
/// already-created SpawnState.
pub fn setLuaWake(editor: *Editor, wake: ?*const fn () void) void {
    editor.lua_wake_fn = wake;
    if (editor.lua_spawn) |s| {
        s.mutex.lockUncancelable(editor.io);
        s.wake_fn = wake;
        s.mutex.unlock(editor.io);
    }
}

/// Worker thread body: run the tool, hand the result to the queue. When
/// the editor is already gone, free everything (last worker frees state).
fn spawnWorker(state: *SpawnState, argv: []const []const u8, ref: i32) void {
    defer freeArgv(state.allocator, argv);

    var job: LuaJob = .{ .ref = ref, .code = null, .stdout = &.{}, .stderr = &.{}, .err_name = null };
    if (std.process.run(state.allocator, state.io, .{
        .argv = argv,
        .stdout_limit = .limited(spawn_stdout_limit),
        .stderr_limit = .limited(spawn_stderr_limit),
    })) |res| {
        job.stdout = res.stdout;
        job.stderr = res.stderr;
        switch (res.term) {
            .exited => |c| job.code = c,
            else => job.err_name = "AbnormalExit",
        }
    } else |err| {
        job.err_name = @errorName(err);
    }

    state.mutex.lockUncancelable(state.io);
    state.active -= 1;
    if (state.alive) {
        state.jobs.append(state.allocator, job) catch {
            state.mutex.unlock(state.io);
            freeJob(state.allocator, job);
            return; // ref stays in the registry until cleanup — OOM path
        };
        const wake = state.wake_fn;
        state.mutex.unlock(state.io);
        if (wake) |w| w();
        return;
    }
    const last = state.active == 0;
    state.mutex.unlock(state.io);
    // Editor is gone: nobody will deliver this. The ref died (or will die)
    // with the Lua state; only the payload needs freeing.
    freeJob(state.allocator, job);
    if (last) state.destroy();
}

/// Deliver finished spawn results to their Lua callbacks (main thread).
pub fn pumpLuaJobs(editor: *Editor) void {
    const state = editor.lua_spawn orelse return;
    while (true) {
        state.mutex.lockUncancelable(editor.io);
        const job: ?LuaJob = if (state.jobs.items.len > 0) state.jobs.orderedRemove(0) else null;
        state.mutex.unlock(editor.io);
        deliverJobToLua(editor, job orelse break);
    }
}

fn deliverJobToLua(editor: *Editor, job: LuaJob) void {
    defer freeJob(editor.allocator, job);
    const lua = editor.lua orelse return;
    defer lua.unref(zlua.registry_index, job.ref);
    _ = lua.getIndexRaw(zlua.registry_index, @intCast(job.ref));
    pushRunResult(lua, job.code, job.stdout, job.stderr, job.err_name);
    lua.protectedCall(.{ .args = 1 }) catch reportLuaError(editor, lua, "spawn callback");
}

/// Push the { code, stdout, stderr, error } result table.
fn pushRunResult(lua: *Lua, code: ?i64, stdout_text: []const u8, stderr_text: []const u8, err_name: ?[]const u8) void {
    lua.newTable();
    if (code) |c| {
        lua.pushInteger(c);
        lua.setField(-2, "code");
    }
    _ = lua.pushString(stdout_text);
    lua.setField(-2, "stdout");
    _ = lua.pushString(stderr_text);
    lua.setField(-2, "stderr");
    if (err_name) |e| {
        _ = lua.pushString(e);
        lua.setField(-2, "error");
    }
}

/// zide.run(argv [, timeout_ms]) -> table | nil, err — run a tool and
/// block until it exits (UI freezes meanwhile: fast tools only; use
/// zide.spawn for anything slow). On timeout the child is killed.
fn luaRun(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;

    const argv = readArgvAlloc(lua, editor.allocator, 1) orelse {
        lua.pushNil();
        _ = lua.pushString("zide.run: argv table of strings required");
        return 2;
    };
    defer freeArgv(editor.allocator, argv);

    const timeout_ms: ?i64 = if (lua.typeOf(2) == .number) (lua.toInteger(2) catch null) else null;

    const res = std.process.run(editor.allocator, editor.io, .{
        .argv = argv,
        .stdout_limit = .limited(spawn_stdout_limit),
        .stderr_limit = .limited(spawn_stderr_limit),
        .timeout = if (timeout_ms) |ms| .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } } else .none,
    }) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    defer editor.allocator.free(res.stdout);
    defer editor.allocator.free(res.stderr);
    const code: ?i64 = switch (res.term) {
        .exited => |c| c,
        else => null,
    };
    pushRunResult(lua, code, res.stdout, res.stderr, if (code == null) "AbnormalExit" else null);
    return 1;
}

/// zide.spawn(argv, fn(result)) — run a tool on a worker thread; the
/// callback fires later on the main loop with { code, stdout, stderr,
/// error }.
fn luaSpawn(state_arg: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state_arg orelse return 0));
    const editor = lua_settings.getEditor(state_arg) orelse return 0;

    const argv = readArgvAlloc(lua, editor.allocator, 1) orelse {
        std.log.warn("zide.spawn: argv table of strings required", .{});
        return 0;
    };
    if (!lua.isFunction(2)) {
        freeArgv(editor.allocator, argv);
        std.log.warn("zide.spawn: second argument must be a function", .{});
        return 0;
    }
    const spawn_state = ensureSpawnState(editor) orelse {
        freeArgv(editor.allocator, argv);
        return 0;
    };

    lua.pushValue(2);
    const ref = lua.ref(zlua.registry_index);

    spawn_state.mutex.lockUncancelable(editor.io);
    spawn_state.active += 1;
    spawn_state.mutex.unlock(editor.io);

    const thread = std.Thread.spawn(.{}, spawnWorker, .{ spawn_state, argv, ref }) catch {
        spawn_state.mutex.lockUncancelable(editor.io);
        spawn_state.active -= 1;
        spawn_state.mutex.unlock(editor.io);
        lua.unref(zlua.registry_index, ref);
        freeArgv(editor.allocator, argv);
        std.log.warn("zide.spawn: failed to start worker thread", .{});
        return 0;
    };
    thread.detach();
    return 0;
}

// ---------------------------------------------------------------------------
// Diagnostics — zide.set_diagnostics(path, list) fills the document's
// lint_diagnostics, which render exactly like LSP diagnostics (gutter
// marker, underline, status bar) via Document.diagIter.
// ---------------------------------------------------------------------------

/// Integer field of the diagnostic table at the top of the stack.
fn diagFieldInt(lua: *Lua, field: [:0]const u8) ?i64 {
    _ = lua.getField(-1, field);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .number) return null;
    return lua.toInteger(-1) catch null;
}

/// String field of the diagnostic table at the top of the stack.
fn diagFieldString(lua: *Lua, field: [:0]const u8) ?[:0]const u8 {
    _ = lua.getField(-1, field);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .string) return null;
    return lua.toString(-1) catch null;
}

fn severityFromName(name: []const u8) lsp_mod.DiagnosticSeverity {
    if (std.mem.eql(u8, name, "warning")) return .warning;
    if (std.mem.eql(u8, name, "info")) return .information;
    if (std.mem.eql(u8, name, "hint")) return .hint;
    return .err; // "error" and anything else — linters mostly report errors
}

/// zide.set_diagnostics(path, {{line, col, end_col, severity, message}, …})
/// Replaces the extension diagnostics of the open document at `path`
/// (1-based positions; severity: "error"/"warning"/"info"/"hint", default
/// "error"). Pass an empty table to clear. Paths that aren't open are
/// ignored. Positions go stale as the user edits — same as LSP, the next
/// lint run replaces them.
fn luaSetDiagnostics(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;

    const path_z = lua.toString(1) catch {
        std.log.warn("zide.set_diagnostics: path (string) required", .{});
        return 0;
    };
    if (lua.typeOf(2) != .table) {
        std.log.warn("zide.set_diagnostics: second argument must be a table", .{});
        return 0;
    }
    const doc: *Document = blk: {
        for (editor.documents.items) |*d| {
            const dp = d.file_path orelse continue;
            if (filetree_mod.normPathEql(dp, path_z)) break :blk d;
        }
        return 0; // not open — nothing to annotate
    };

    doc.clearLintDiagnostics();
    const len = lua.lenRaw(2);
    var i: usize = 1;
    while (i <= len) : (i += 1) {
        _ = lua.getIndexRaw(2, @intCast(i));
        defer lua.pop(1);
        if (lua.typeOf(-1) != .table) continue;

        const line = diagFieldInt(lua, "line") orelse continue;
        if (line < 1) continue;
        const col = @max(diagFieldInt(lua, "col") orelse 1, 1);
        const end_col = @max(diagFieldInt(lua, "end_col") orelse (col + 1), col);
        const severity = severityFromName(diagFieldString(lua, "severity") orelse "error");
        const message = diagFieldString(lua, "message") orelse "";

        const owned_msg = doc.allocator.dupe(u8, message) catch continue;
        doc.lint_diagnostics.append(doc.allocator, .{
            .start_line = @intCast(line - 1),
            .start_col = @intCast(col - 1),
            .end_line = @intCast(line - 1),
            .end_col = @intCast(end_col - 1),
            .severity = severity,
            .message = owned_msg,
        }) catch {
            doc.allocator.free(owned_msg);
        };
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Tests — drive the real API through a real Lua state.
// NOTE: declare the Lua state BEFORE the editor in every test so the
// LIFO defers run editor.deinit (which unrefs) while the state is alive.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "zide.command registers, lists in the palette, and dispatches" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.command('greet', 'Say hi', function() zide.status('hi from lua') end)");
    try testing.expect(editor.commands.get("greet") != null);

    const names = try editor.commands.allNames();
    var found = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "greet")) found = true;
    }
    try testing.expect(found);

    try testing.expect(editor.execCommand("greet", null));
    try testing.expectEqualStrings("hi from lua", editor.status_message);
}

test "zide.command re-registration replaces the previous callback" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.command('x2', '', function() zide.status('one') end)");
    try lua.doString("zide.command('x2', '', function() zide.status('two') end)");
    _ = editor.execCommand("x2", null);
    try testing.expectEqualStrings("two", editor.status_message);
}

test "Lua command may shadow a built-in" {
    // The override warn is expected — keep it out of the runner's stderr.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.command('undo', '', function() zide.status('custom undo') end)");
    _ = editor.execCommand("undo", null);
    try testing.expectEqualStrings("custom undo", editor.status_message);
}

test "broken Lua command reports an error instead of crashing" {
    // The reported Lua error warn is expected — keep stderr clean.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.command('boom', '', function() error('kaput') end)");
    try testing.expect(editor.execCommand("boom", null));
    try testing.expect(std.mem.startsWith(u8, editor.status_message, "Extension error:"));
    // Editor still fully functional afterwards
    try testing.expect(editor.execCommand("cursor_right", null));
}

test "zide.on('save') fires via noteFileSaved with nil path for untitled" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString(
        \\zide.on('save', function(p)
        \\  if p == nil then zide.status('saved untitled')
        \\  else zide.status('saved ' .. p) end
        \\end)
    );
    editor.noteFileSaved(false, editor.activeDoc());
    try testing.expectEqualStrings("saved untitled", editor.status_message);
}

test "zide.on('open') fires when a file opens" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.on('open', function(p) zide.status(p and 'opened with path' or 'opened nil') end)");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile(testing.io, "a.txt", .{});
        f.close(testing.io);
    }
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "a.txt", testing.allocator);
    defer testing.allocator.free(abs);

    _ = try editor.openFile(abs);
    try testing.expectEqualStrings("opened with path", editor.status_message);
}

test "zide.on rejects unknown event names" {
    // The unknown-event warn is expected — keep stderr clean.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.on('resize', function() end)");
    const total = editor.lua_event_refs.get(.open).items.len + editor.lua_event_refs.get(.save).items.len;
    try testing.expectEqual(@as(usize, 0), total);
}

test "zide.exec runs built-in commands from Lua" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try editor.activeDoc().loadText("ab");
    try lua.doString("zide.exec('cursor_right')");
    try testing.expectEqual(@as(usize, 1), editor.activeDoc().cursors.primary().offset);
}

test "buffer API: reads, cursor round-trip, clamping" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try editor.activeDoc().loadText("alpha\nbeta");
    try lua.doString(
        \\assert(zide.line_count() == 2)
        \\assert(zide.get_line(1) == 'alpha')
        \\assert(zide.get_line(2) == 'beta')
        \\assert(zide.get_line(3) == nil)
        \\assert(zide.get_text() == 'alpha\nbeta')
        \\assert(zide.file_path() == nil)
        \\zide.set_cursor(2, 3)
        \\local l, c = zide.cursor()
        \\assert(l == 2 and c == 3)
        \\zide.set_cursor(99, 99) -- clamps to end of last line
        \\l, c = zide.cursor()
        \\assert(l == 2 and c == 5)
    );
}

test "buffer API: insert replaces an active selection in one undo step" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.loadText("hello world");
    // Select "hello" from the Zig side
    const c = doc.cursors.primary();
    c.anchor = 0;
    c.offset = 5;
    try lua.doString(
        \\assert(zide.selection() == 'hello')
        \\zide.insert('goodbye')
    );
    try testing.expectEqualStrings("goodbye world", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = try doc.undoAction();
    try testing.expectEqualStrings("hello world", doc.buffer.slice(0, doc.buffer.byteLen()));
    try lua.doString("assert(zide.selection() == nil)");
}

test "buffer API: set_line swap via a Lua command, undo restores" {
    // The out-of-range warn at the end is expected — keep stderr clean.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.loadText("bb\na\n");
    try lua.doString(
        \\zide.command('swap12', 'Swap first two lines', function()
        \\  local l1, l2 = zide.get_line(1), zide.get_line(2)
        \\  zide.set_line(1, l2)
        \\  zide.set_line(2, l1)
        \\end)
    );
    try testing.expect(editor.execCommand("swap12", null));
    try testing.expectEqualStrings("a\nbb\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    // Two set_line calls = two undo groups
    _ = try doc.undoAction();
    _ = try doc.undoAction();
    try testing.expectEqualStrings("bb\na\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    // Out-of-range set_line is a no-op
    try lua.doString("zide.set_line(99, 'nope')");
    try testing.expectEqualStrings("bb\na\n", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "buffer API: set_line on an empty line and language()" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.loadText("a\n\nc");
    try lua.doString("zide.set_line(2, 'b')");
    try testing.expectEqualStrings("a\nb\nc", doc.buffer.slice(0, doc.buffer.byteLen()));

    try lua.doString("assert(zide.language() == nil)");
    doc.language = editor.languages.items[0]; // built-in Zig
    try lua.doString("zide.status(zide.language() or 'none')");
    try testing.expectEqualStrings(editor.languages.items[0].name, editor.status_message);
}

test "zide.run executes a tool and returns code/stdout" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString(
        \\local r = zide.run({'cmd', '/c', 'echo lua-run-works'})
        \\assert(r ~= nil)
        \\assert(r.code == 0)
        \\assert(r.stdout:find('lua%-run%-works') ~= nil)
        \\assert(r.error == nil)
    );
}

test "zide.run reports a missing tool as nil, err" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString(
        \\local r, err = zide.run({'zide-definitely-not-a-real-tool'})
        \\assert(r == nil)
        \\assert(type(err) == 'string')
    );
}

test "zide.spawn delivers the result through pumpLuaJobs" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString(
        \\zide.spawn({'cmd', '/c', 'echo spawned-ok'}, function(r)
        \\  if r.code == 0 and r.stdout:find('spawned%-ok') then
        \\    zide.status('spawn delivered')
        \\  else
        \\    zide.status('spawn wrong: ' .. (r.error or tostring(r.code)))
        \\  end
        \\end)
    );

    // Pump until the worker delivers (10s deadline).
    const start_ns = std.Io.Clock.now(.awake, testing.io).nanoseconds;
    while (std.Io.Clock.now(.awake, testing.io).nanoseconds - start_ns < 10 * std.time.ns_per_s) {
        editor.pumpLuaJobs();
        if (editor.status_message.len != 0) break;
    }
    try testing.expectEqualStrings("spawn delivered", editor.status_message);

    // Let the worker fully retire before deinit so the leak checker sees
    // the SpawnState freed on the editor side.
    while (std.Io.Clock.now(.awake, testing.io).nanoseconds - start_ns < 10 * std.time.ns_per_s) {
        const state = editor.lua_spawn orelse break;
        state.mutex.lockUncancelable(testing.io);
        const in_flight = state.active;
        state.mutex.unlock(testing.io);
        if (in_flight == 0) break;
    }
}

test "zide.set_diagnostics fills, replaces, merges, and clears" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.loadText("line one\nline two\n");
    try doc.setFilePath("C:/fake/lint_target.zig");

    try lua.doString(
        \\zide.set_diagnostics('C:/fake/lint_target.zig', {
        \\  { line = 1, col = 2, end_col = 5, severity = 'error', message = 'bad thing' },
        \\  { line = 2, severity = 'warning', message = 'meh thing' },
        \\})
    );
    try testing.expectEqual(@as(usize, 2), doc.lint_diagnostics.items.len);
    const d0 = doc.lint_diagnostics.items[0];
    try testing.expectEqual(@as(u32, 0), d0.start_line);
    try testing.expectEqual(@as(u32, 1), d0.start_col);
    try testing.expectEqual(@as(u32, 4), d0.end_col);
    try testing.expectEqual(lsp_mod.DiagnosticSeverity.err, d0.severity);
    try testing.expectEqualStrings("bad thing", d0.message);
    try testing.expectEqual(lsp_mod.DiagnosticSeverity.warning, doc.lint_diagnostics.items[1].severity);

    // diagIter merges LSP + lint lists
    try doc.diagnostics.append(doc.allocator, .{
        .start_line = 0,
        .start_col = 0,
        .end_line = 0,
        .end_col = 1,
        .severity = .information,
        .message = try doc.allocator.dupe(u8, "from lsp"),
    });
    var it = doc.diagIter();
    var seen: usize = 0;
    while (it.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 3), seen);

    // Separator-normalized path matching (backslashes vs forward slashes)
    try lua.doString(
        \\zide.set_diagnostics('C:\\fake\\lint_target.zig', {
        \\  { line = 1, message = 'replaced' },
        \\})
    );
    try testing.expectEqual(@as(usize, 1), doc.lint_diagnostics.items.len);
    try testing.expectEqualStrings("replaced", doc.lint_diagnostics.items[0].message);
    // LSP list untouched by the lint replace
    try testing.expectEqual(@as(usize, 1), doc.diagnostics.items.len);

    // Unknown path is ignored
    try lua.doString("zide.set_diagnostics('C:/other/file.zig', { { line = 1, message = 'x' } })");
    try testing.expectEqual(@as(usize, 1), doc.lint_diagnostics.items.len);

    // Empty table clears
    try lua.doString("zide.set_diagnostics('C:/fake/lint_target.zig', {})");
    try testing.expectEqual(@as(usize, 0), doc.lint_diagnostics.items.len);
}

test "lint-zig template pattern parses ast-check output (drive-letter paths)" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.setFilePath("C:/fake/lint.zig");
    // The exact gmatch pattern shipped in example-lint-zig.lua — keep in sync.
    try lua.doString(
        \\local stderr = "C:\\fake\\lint.zig:12:5: error: expected ';' after statement\nC:\\fake\\lint.zig:3:1: note: while parsing this\n"
        \\local diags = {}
        \\for line, col, kind, msg in stderr:gmatch("[^\r\n]-:(%d+):(%d+): (%w+): ([^\r\n]+)") do
        \\  diags[#diags + 1] = { line = tonumber(line), col = tonumber(col),
        \\    severity = (kind == "error") and "error" or "warning", message = msg }
        \\end
        \\zide.set_diagnostics("C:/fake/lint.zig", diags)
    );
    try testing.expectEqual(@as(usize, 2), doc.lint_diagnostics.items.len);
    const d0 = doc.lint_diagnostics.items[0];
    try testing.expectEqual(@as(u32, 11), d0.start_line);
    try testing.expectEqual(@as(u32, 4), d0.start_col);
    try testing.expectEqual(lsp_mod.DiagnosticSeverity.err, d0.severity);
    try testing.expectEqualStrings("expected ';' after statement", d0.message);
    try testing.expectEqual(lsp_mod.DiagnosticSeverity.warning, doc.lint_diagnostics.items[1].severity);
}

test "reload_extensions clears lint diagnostics" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.setFilePath("C:/fake/reload_lint.zig");
    try lua.doString("zide.set_diagnostics('C:/fake/reload_lint.zig', { { line = 1, message = 'stale' } })");
    try testing.expectEqual(@as(usize, 1), doc.lint_diagnostics.items.len);
    try testing.expect(editor.execCommand("reload_extensions", null));
    try testing.expectEqual(@as(usize, 0), doc.lint_diagnostics.items.len);
}

test "reload_extensions drops Lua commands and handlers" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.command('temp', '', function() end)");
    try lua.doString("zide.on('save', function() zide.status('handler ran') end)");
    try testing.expect(editor.commands.get("temp") != null);

    // No config dir in tests (process_environ unset) — loadExtensions no-ops.
    try testing.expect(editor.execCommand("reload_extensions", null));
    try testing.expect(editor.commands.get("temp") == null);
    try testing.expectEqualStrings("Extensions reloaded", editor.status_message);

    editor.noteFileSaved(false, editor.activeDoc());
    // Handler is gone — the reload message survives the (non-)event.
    try testing.expectEqualStrings("Extensions reloaded", editor.status_message);
}
