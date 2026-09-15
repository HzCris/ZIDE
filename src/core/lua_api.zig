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
const fileicons = @import("fileicons.zig");
const syntax = @import("syntax.zig");
const ThemeColor = @import("theme.zig").ThemeColor;

const Lua = zlua.Lua;

/// Events extensions can hook via zide.on(name, fn). The Lua-side names
/// are the enum tag names ("open", "save").
pub const LuaEvent = enum { open, save };

/// A registered handler: its Lua registry ref plus an optional language
/// filter (owned, from `zide.on(ev, fn, { language = "zig" })`).
pub const EventHandler = struct {
    ref: i32,
    language: ?[]const u8 = null,
};

/// Per-event lists of registered handlers.
pub const EventHandlers = std.EnumArray(LuaEvent, std.ArrayList(EventHandler));

/// Cap on nested event firing (e.g. a save handler that saves again).
const max_event_depth = 8;

/// Register the extension API onto the `zide` table at the top of the
/// stack and point the editor at the Lua state so core code can fire
/// events. Called from lua_settings.registerApi while the table is open.
pub fn registerInto(lua: *Lua, editor: *Editor) void {
    editor.lua = lua;
    @import("task_lua.zig").registerInto(lua);
    @import("dap_lua.zig").registerInto(lua);

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

    // File tree icon overrides
    lua.pushFunction(&luaSetIcon);
    lua.setField(-2, "set_icon");
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

/// Fire an event for `doc` to every registered handler whose language
/// filter matches (or has none). Handlers receive `(path, language)` —
/// nil for untitled / plain-text documents. Safe with no Lua state.
///
/// Path and language are snapshotted BEFORE the loop: a handler may open
/// or close documents (reallocating the list `doc` lives in, or freeing
/// its path) or re-register the language (freeing the arena its name
/// lives in).
pub fn fireEvent(editor: *Editor, event: LuaEvent, doc: *const Document) void {
    const lua = editor.lua orelse return;
    if (editor.lua_event_depth >= max_event_depth) {
        std.log.warn("zide.on({s}): event recursion too deep, handlers skipped", .{@tagName(event)});
        return;
    }
    editor.lua_event_depth += 1;
    defer editor.lua_event_depth -= 1;

    const path_copy: ?[]const u8 = if (doc.file_path) |p| (editor.allocator.dupe(u8, p) catch null) else null;
    defer if (path_copy) |p| editor.allocator.free(p);
    var lang_buf: [Editor.max_lang_name]u8 = undefined;
    const lang: ?[]const u8 = if (doc.language) |l| blk: {
        if (l.name.len > lang_buf.len) break :blk null;
        @memcpy(lang_buf[0..l.name.len], l.name);
        break :blk lang_buf[0..l.name.len];
    } else null;

    // Index-based walk: a handler may register more handlers mid-fire,
    // which can reallocate the list under a held slice. `h` is a copy —
    // its filter is read before the call, never after.
    var i: usize = 0;
    while (i < editor.lua_event_handlers.getPtr(event).items.len) : (i += 1) {
        const h = editor.lua_event_handlers.getPtr(event).items[i];
        if (h.language) |want| {
            const have = lang orelse continue;
            if (!std.ascii.eqlIgnoreCase(want, have)) continue;
        }
        _ = lua.getIndexRaw(zlua.registry_index, @intCast(h.ref));
        if (path_copy) |p| {
            _ = lua.pushString(p);
        } else {
            lua.pushNil();
        }
        if (lang) |l| {
            _ = lua.pushString(l);
        } else {
            lua.pushNil();
        }
        lua.protectedCall(.{ .args = 2 }) catch reportLuaError(editor, lua, "event handler");
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
    // Reload cancels the old generation before its callbacks can be delivered.
    for (editor.lua_jobs.items) |pending| {
        editor.jobs.remove(pending.id);
        if (editor.lua) |lua| lua.unref(zlua.registry_index, pending.ref);
    }
    editor.lua_jobs.clearRetainingCapacity();
    var refs: std.ArrayList(i32) = .empty;
    defer refs.deinit(editor.allocator);
    editor.commands.removeLuaCommands(&refs);
    if (editor.lua) |lua| {
        for (refs.items) |r| lua.unref(zlua.registry_index, r);
    }
    inline for (comptime std.meta.tags(LuaEvent)) |ev| {
        const list = editor.lua_event_handlers.getPtr(ev);
        for (list.items) |h| {
            if (editor.lua) |lua| lua.unref(zlua.registry_index, h.ref);
            if (h.language) |l| editor.allocator.free(l);
        }
        list.clearRetainingCapacity();
    }
    // A removed lint extension's stale squiggles shouldn't survive reload.
    editor.problems.clear(.lua, null);
    for (editor.documents.items) |*doc| editor.problems.project(doc, .lua) catch {};
}

/// Full teardown for Editor.deinit (also frees the ref lists). Must run
/// before the command registry deinits and while the Lua state is alive.
pub fn deinitLua(editor: *Editor) void {
    cleanupLuaRefs(editor);
    inline for (comptime std.meta.tags(LuaEvent)) |ev| {
        editor.lua_event_handlers.getPtr(ev).deinit(editor.allocator);
    }
    editor.lua_jobs.deinit(editor.allocator);
}

/// Re-run every extensions/*.lua after dropping prior Lua commands and
/// handlers. Lua-side globals persist across reloads (harmless).
pub fn reloadExtensions(editor: *Editor) void {
    const lua = editor.lua orelse {
        editor.status_message = "Extensions: no Lua state available";
        return;
    };
    cleanupLuaRefs(editor);
    // Server registrations made by extension files are re-created by the
    // reload; drop the old ones first (init.lua's are kept), then stop any
    // server whose registration changed or vanished (unchanged ones keep
    // running — no clangd restart on every reload).
    editor.dropExtensionLspConfigs();
    editor.tasks.dropExtensions(editor);
    editor.dap.dropExtensions(editor);
    lua_settings.loadExtensions(lua);
    editor.reconcileLspClients();
    // Extensions may have (re)registered languages: re-detect every open
    // document so new extension→language mappings apply. In-place
    // re-registration keeps existing pointers valid, so documents whose
    // language is unchanged are left alone (no LSP close/open churn).
    for (editor.documents.items) |*doc| editor.relanguageDoc(doc);
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
    // Optional third argument: { language = "zig" } fires the handler
    // only for documents of that language.
    var language: ?[]const u8 = null;
    if (lua.typeOf(3) == .table) {
        _ = lua.getField(3, "language");
        if (lua.typeOf(-1) == .string) {
            const s: []const u8 = lua.toString(-1) catch "";
            language = editor.allocator.dupe(u8, s) catch null;
        }
        lua.pop(1);
    }
    lua.pushValue(2);
    const ref = lua.ref(zlua.registry_index);
    editor.lua_event_handlers.getPtr(event).append(editor.allocator, .{ .ref = ref, .language = language }) catch {
        lua.unref(zlua.registry_index, ref);
        if (language) |l| editor.allocator.free(l);
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

    doc.beginEdit() catch return 0;
    defer doc.endEdit();
    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
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

pub const BackgroundJob = struct { id: u64, ref: i32 };

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

/// Read a positional table of strings at `index` into owned slices.
pub fn readArgvAlloc(lua: *Lua, allocator: std.mem.Allocator, index: i32) ?[]const []const u8 {
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

/// Synchronizes with in-flight wakes before the frontend is destroyed.
pub fn setLuaWake(editor: *Editor, wake: ?*const fn () void) void {
    editor.git.setWake(wake);
    editor.dap.setWake(wake);
    editor.lua_wake_fn = wake;
    editor.jobs.setWake(wake);
    if (editor.recovery) |*recovery| recovery.setWake(wake);
    editor.lsp_wake_fn = wake;
    for (editor.lsp_clients.items) |client| client.setWake(wake);
}

pub fn pumpLuaJobs(editor: *Editor) void {
    var index: usize = 0;
    while (index < editor.lua_jobs.items.len) {
        const pending = editor.lua_jobs.items[index];
        const job = editor.jobs.get(pending.id) orelse {
            _ = editor.lua_jobs.orderedRemove(index);
            continue;
        };
        if (!job.isDone()) {
            index += 1;
            continue;
        }
        const result = job.snapshot(editor.allocator, false) catch {
            index += 1;
            continue;
        };
        defer result.deinit(editor.allocator);
        // Retire the job before calling Lua: a callback may reload extensions
        // or start more work, invalidating every list index and worker handle.
        _ = editor.lua_jobs.orderedRemove(index);
        editor.jobs.remove(pending.id);
        const lua = editor.lua orelse continue;
        defer lua.unref(zlua.registry_index, pending.ref);
        _ = lua.getIndexRaw(zlua.registry_index, @intCast(pending.ref));
        pushRunResult(lua, if (result.code) |code| @as(i64, code) else null, result.stdout, result.stderr, if (result.failure) |err| @errorName(err) else null);
        lua.protectedCall(.{ .args = 1 }) catch reportLuaError(editor, lua, "spawn callback");
    }
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
    defer freeArgv(editor.allocator, argv);
    editor.lua_jobs.ensureUnusedCapacity(editor.allocator, 1) catch return 0;
    const id = editor.jobs.start(.{ .argv = argv, .strict_output = true, .output_limit = spawn_stdout_limit + spawn_stderr_limit }) catch |err| {
        lua.pushValue(2);
        pushRunResult(lua, null, "", "", @errorName(err));
        lua.protectedCall(.{ .args = 1 }) catch reportLuaError(editor, lua, "spawn callback");
        return 0;
    };
    lua.pushValue(2);
    editor.lua_jobs.appendAssumeCapacity(.{ .id = id, .ref = lua.ref(zlua.registry_index) });
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
/// zide.set_icon(key, kind [, "#rrggbb"]) — override a file tree icon.
/// `key` is an extension ("zig") or exact basename ("Makefile", "src");
/// `kind` is one of the fileicons.IconKind tag names ("code", "image",
/// "folder", ...). Omitting the color keeps the theme's text color.
fn luaSetIcon(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;

    const key = lua.toString(1) catch {
        std.log.warn("zide.set_icon: key (string) required", .{});
        return 0;
    };
    const kind_str = lua.toString(2) catch {
        std.log.warn("zide.set_icon: kind (string) required", .{});
        return 0;
    };
    const kind = fileicons.kindFromName(kind_str) orelse {
        std.log.warn("zide.set_icon: unknown kind '{s}'", .{kind_str});
        return 0;
    };
    var color: ?fileicons.Rgb = null;
    if (lua.getTop() >= 3 and !lua.isNil(3)) {
        const hex = lua.toString(3) catch {
            std.log.warn("zide.set_icon: color must be a '#rrggbb' string", .{});
            return 0;
        };
        const tc = ThemeColor.fromHex(hex) orelse {
            std.log.warn("zide.set_icon: bad color '{s}'", .{hex});
            return 0;
        };
        color = .{ .r = tc.r, .g = tc.g, .b = tc.b };
    }
    editor.setIconOverride(key, kind, color) catch {
        std.log.warn("zide.set_icon: could not register '{s}'", .{key});
    };
    return 0;
}

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
    const source = lua.toString(3) catch "lint";
    var diagnostics: std.ArrayList(@import("lsp.zig").Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |diagnostic| diagnostic.deinit(editor.allocator);
        diagnostics.deinit(editor.allocator);
    }
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

        const owned_msg = editor.allocator.dupe(u8, message) catch continue;
        diagnostics.append(editor.allocator, .{
            .start_line = @intCast(line - 1),
            .start_col = @intCast(col - 1),
            .end_line = @intCast(line - 1),
            .end_col = @intCast(end_col - 1),
            .severity = severity,
            .message = owned_msg,
        }) catch {
            editor.allocator.free(owned_msg);
        };
    }
    editor.problems.replace(path_z, source, .lua, null, .bytes, diagnostics.items) catch return 0;
    for (editor.documents.items) |*doc| {
        if (doc.file_path) |path| if (editor.pathsEqual(path, path_z)) editor.problems.project(doc, .lua) catch {};
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
    const total = editor.lua_event_handlers.get(.open).items.len + editor.lua_event_handlers.get(.save).items.len;
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
    try lua.doString("assert(zide.selection() == 'hello')");
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

    try testing.expectEqual(@as(usize, 0), editor.lua_jobs.items.len);
    try testing.expectEqual(@as(usize, 0), editor.jobs.jobs.items.len);
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

    // Backslashes are separators only on Windows; POSIX treats them literally.
    try lua.doString(if (@import("builtin").os.tag == .windows)
        \\zide.set_diagnostics('C:\\fake\\lint_target.zig', {
        \\  { line = 1, message = 'replaced' },
        \\})
    else
        \\zide.set_diagnostics('C:/fake/./lint_target.zig', {
        \\  { line = 1, message = 'replaced' },
        \\})
    );
    try testing.expectEqual(@as(usize, 1), doc.lint_diagnostics.items.len);
    try testing.expectEqualStrings("replaced", doc.lint_diagnostics.items[0].message);
    // LSP list untouched by the lint replace
    try testing.expectEqual(@as(usize, 1), doc.diagnostics.items.len);

    // A closed-file finding is retained without changing this document.
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

test "off-switch settings round-trip through zide.set/get" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString(
        \\assert(zide.get('lsp_enabled') == true)
        \\assert(zide.get('syntax_highlighting') == true)
        \\assert(zide.get('filetree_git_colors') == true)
        \\zide.set('lsp_enabled', false)
        \\zide.set('syntax_highlighting', false)
        \\zide.set('filetree_git_colors', false)
        \\assert(zide.get('lsp_enabled') == false)
        \\assert(zide.get('syntax_highlighting') == false)
        \\assert(zide.get('filetree_git_colors') == false)
    );
    try testing.expect(!editor.lsp_enabled);
    try testing.expect(!editor.syntax_highlighting);
    try testing.expect(!editor.filetree_git_colors);
}

test "zide.set_icon overrides tree icons by ext and basename" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString(
        \\zide.set_icon('zig', 'image', '#ff0000')
        \\zide.set_icon('SRC', 'git')
    );
    const zig_icon = editor.filetreeIconFor("main.zig", false);
    try testing.expectEqual(fileicons.IconKind.image, zig_icon.kind);
    try testing.expectEqual(@as(u8, 0xFF), zig_icon.color.?.r);
    // Basename match, case-insensitive both directions, works for dirs
    try testing.expectEqual(fileicons.IconKind.git, editor.filetreeIconFor("src", true).kind);
    // Unknown kind is rejected without registering
    try lua.doString("zide.set_icon('md', 'nonsense')");
    try testing.expectEqual(fileicons.IconKind.text, editor.filetreeIconFor("notes.md", false).kind);
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

test "register_language re-registration replaces the definition in place" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const before = editor.languages.items.len;
    try lua.doString("zide.register_language({ name = 'foo', extensions = {'foo'}, keywords = {'alpha'} })");
    try testing.expectEqual(before + 1, editor.languages.items.len);
    const ptr = editor.findLanguage("foo").?;
    try testing.expect(ptr.isKeyword("alpha"));

    // A document using the language has a populated highlight cache
    const doc = editor.activeDoc();
    try doc.loadText("alpha beta");
    doc.language = ptr;
    _ = doc.ensureLineState(0);
    try testing.expect(doc.line_states.items.len > 0);

    // Same name (different case), new tables and extensions: same slot,
    // no growth, cache dropped, new extension resolves to the same def.
    try lua.doString("zide.register_language({ name = 'FOO', extensions = {'foo', 'bar'}, keywords = {'beta'} })");
    try testing.expectEqual(before + 1, editor.languages.items.len);
    try testing.expectEqual(@as(?*const syntax.LanguageDef, ptr), doc.language);
    try testing.expect(ptr.isKeyword("beta"));
    try testing.expect(!ptr.isKeyword("alpha"));
    try testing.expectEqual(@as(usize, 0), doc.line_states.items.len);
    try testing.expectEqual(@as(?*const syntax.LanguageDef, ptr), editor.findLanguage("bar"));
    // Still tokenizes fine through the replaced definition
    _ = doc.ensureLineState(0);
}

test "findLanguage prefers the latest registration; by-name lookup is case-insensitive" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try testing.expectEqualStrings("zig", editor.findLanguage("zig").?.name);
    // A user extension claims .zig: it wins over the built-in
    try lua.doString("zide.register_language({ name = 'myzig', extensions = {'zig'}, keywords = {'fn'} })");
    try testing.expectEqualStrings("myzig", editor.findLanguage("zig").?.name);
    // The built-in is still there and reachable by name, any case
    try testing.expectEqualStrings("zig", editor.findLanguageByName("ZIG").?.name);
    try testing.expectEqualStrings("myzig", editor.findLanguageByName("MyZig").?.name);
    try testing.expect(editor.findLanguageByName("nope") == null);
}

test "re-registering markdown keeps the structural tokenizer only when asked" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const count = editor.languages.items.len;
    try lua.doString("zide.register_language({ name = 'markdown', extensions = {'md', 'mdx'}, tokenizer = 'markdown' })");
    const md = editor.findLanguageByName("markdown").?;
    try testing.expectEqual(syntax.TokenizerKind.markdown, md.tokenizer);
    try testing.expectEqual(@as(?*const syntax.LanguageDef, md), editor.findLanguage("mdx"));
    try testing.expectEqual(count, editor.languages.items.len);

    // Omitting `tokenizer` is a full replacement: degrades to generic (warns)
    testing.log_level = .err;
    defer testing.log_level = .warn;
    try lua.doString("zide.register_language({ name = 'Markdown', extensions = {'md'} })");
    try testing.expectEqual(syntax.TokenizerKind.generic, md.tokenizer);
    try testing.expectEqual(count, editor.languages.items.len);
    // Unknown tokenizer names also fall back to generic
    try lua.doString("zide.register_language({ name = 'weird', extensions = {'wd'}, tokenizer = 'bogus' })");
    try testing.expectEqual(syntax.TokenizerKind.generic, editor.findLanguageByName("weird").?.tokenizer);
}

test "reload_extensions keeps open documents on valid definitions" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.register_language({ name = 'foo', extensions = {'foo'}, keywords = {'alpha'} })");
    const ptr = editor.findLanguage("foo").?;
    const doc = editor.activeDoc();
    try doc.loadText("alpha\nbeta\n");
    doc.language = ptr;
    const langs_before = editor.languages.items.len;

    // No config dir in tests — loadExtensions no-ops, but the reload path
    // still walks every document. Untitled docs keep their language.
    try testing.expect(editor.execCommand("reload_extensions", null));
    try testing.expectEqual(langs_before, editor.languages.items.len);
    try testing.expectEqual(@as(?*const syntax.LanguageDef, ptr), doc.language);
    _ = doc.ensureLineState(1);
}

test "zide.bind/unbind with a language option use the overlay" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.bind('ctrl+k', 'overlay_cmd', { language = 'zig' })");
    try lua.doString("zide.bind('ctrl+shift+d', 'global_cmd')");
    const doc = editor.activeDoc();
    try testing.expectEqualStrings("delete_line", editor.keybinds.get("ctrl+k").?); // global untouched
    try testing.expectEqualStrings("global_cmd", editor.keybinds.get("ctrl+shift+d").?);
    doc.language = editor.findLanguage("zig");
    try testing.expectEqualStrings("overlay_cmd", editor.lookupKeybind("ctrl+k").?);

    // Scoped unbind removes only the overlay entry (any case)
    try lua.doString("zide.unbind('ctrl+k', { language = 'ZIG' })");
    try testing.expectEqualStrings("delete_line", editor.lookupKeybind("ctrl+k").?);
    // Unbind for a language without a profile is a no-op and creates none
    try lua.doString("zide.unbind('ctrl+k', { language = 'nope' })");
    try testing.expect(editor.langProfileNamed("nope") == null);
    // Plain unbind still hits the global map
    try lua.doString("zide.unbind('ctrl+shift+d')");
    try testing.expect(editor.keybinds.get("ctrl+shift+d") == null);
}

test "zide.on language filter and (path, language) handler arguments" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString(
        \\hits = {}
        \\zide.on("save", function(p, l) hits[#hits + 1] = "any:" .. tostring(l) end)
        \\zide.on("save", function(p, l) hits[#hits + 1] = "zig:" .. tostring(l) end, { language = "zig" })
    );
    const doc = editor.activeDoc();
    // Plain-text document: only the unfiltered handler, language nil
    editor.noteFileSaved(false, doc);
    try lua.doString("assert(#hits == 1 and hits[1] == 'any:nil', table.concat(hits, ','))");
    // Zig document: both fire; the language arrives as the second argument
    doc.language = editor.findLanguage("zig");
    editor.noteFileSaved(false, doc);
    try lua.doString("assert(#hits == 3 and hits[2] == 'any:zig' and hits[3] == 'zig:zig', table.concat(hits, ','))");
    // A markdown document skips the zig-only handler
    doc.language = editor.findLanguage("md");
    editor.noteFileSaved(false, doc);
    try lua.doString("assert(#hits == 4 and hits[4] == 'any:markdown', table.concat(hits, ','))");
    // reload drops handlers (and frees their filters — leak-checked)
    try testing.expect(editor.execCommand("reload_extensions", null));
    editor.noteFileSaved(false, doc);
    try lua.doString("assert(#hits == 4)");
}

test "zide.set_language merges and validates; get_language reads back" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.set_language('zig', { tab_width = 2, use_tabs = true })");
    try lua.doString("zide.set_language('ZIG', { word_wrap = false })"); // merge, any case
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("zig");
    try testing.expectEqual(@as(usize, 2), editor.tabWidthFor(doc));
    try testing.expect(editor.useTabsFor(doc));
    try testing.expect(!editor.wordWrapFor(doc));
    try testing.expectEqual(editor.auto_close_brackets, editor.autoCloseBracketsFor(doc));
    // Globals untouched
    try testing.expectEqual(@as(usize, 4), editor.tab_width);
    // Read back from Lua
    try lua.doString("assert(zide.get_language('zig').tab_width == 2)");
    try lua.doString("assert(zide.get_language('Zig').use_tabs == true)");
    try lua.doString("assert(zide.get_language('zig').auto_close_brackets == nil)");
    try lua.doString("assert(zide.get_language('nope') == nil)");

    // Out-of-range tab_width is ignored (warns); the rest still applies
    testing.log_level = .err;
    defer testing.log_level = .warn;
    try lua.doString("zide.set_language('zig', { tab_width = 99, auto_close_brackets = false })");
    try testing.expectEqual(@as(usize, 2), editor.tabWidthFor(doc));
    try testing.expect(!editor.autoCloseBracketsFor(doc));
    // Bad arguments and empty tables create nothing
    try lua.doString("zide.set_language({}, 'x')");
    try lua.doString("zide.set_language('markdown', 'x')");
    try lua.doString("zide.set_language('markdown', {})");
    try testing.expect(editor.langProfileNamed("markdown") == null);
}

test "register_language settings sugar; indent uses the language tab width" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString("zide.register_language({ name = 'yaml', extensions = {'yml'}, keywords = {}, tab_width = 2, use_tabs = false })");
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("yml");
    try testing.expectEqual(@as(usize, 2), editor.tabWidthFor(doc));
    try doc.loadText("");
    try testing.expect(editor.execCommand("indent", null));
    try testing.expectEqualStrings("  ", doc.lineContent(0));

    // A language without overrides keeps the global default (4)
    doc.language = editor.findLanguage("zig");
    try doc.loadText("");
    try testing.expect(editor.execCommand("indent", null));
    try testing.expectEqualStrings("    ", doc.lineContent(0));
}

test "zide.register_lsp: argv forms, languages, ids, settings" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const base = editor.lsp_configs.items.len; // the built-in zls seed

    // Old form: language + command string (argv[0] only — never split)
    try lua.doString("zide.register_lsp({ language = 'Zig', command = 'C:/tools with space/zls.exe' })");
    const zig_cfg = editor.lspConfigFor("zig").?;
    try testing.expectEqual(@as(usize, 1), zig_cfg.argv.len);
    try testing.expectEqualStrings("C:/tools with space/zls.exe", zig_cfg.argv[0]);
    try testing.expectEqualStrings("zig", zig_cfg.languageIdFor("Zig"));
    try testing.expect(!zig_cfg.from_extension);
    try testing.expect(zig_cfg.settings_json == null);

    // argv table, several languages, per-language ids, settings + init_options
    try lua.doString(
        \\zide.register_lsp({
        \\  languages = {"c", "C++"},
        \\  command = {"clangd", "--background-index"},
        \\  language_id = { ["C++"] = "cpp" },
        \\  settings = { Lua = { diagnostics = { globals = {"zide"} } } },
        \\  init_options = { check = { command = "clippy" } },
        \\})
    );
    const c_cfg = editor.lspConfigFor("c++").?;
    try testing.expectEqual(@as(usize, 2), c_cfg.argv.len);
    try testing.expectEqualStrings("--background-index", c_cfg.argv[1]);
    try testing.expectEqualStrings("c", c_cfg.languageIdFor("C"));
    try testing.expectEqualStrings("cpp", c_cfg.languageIdFor("c++"));
    try testing.expectEqualStrings("{\"Lua\":{\"diagnostics\":{\"globals\":[\"zide\"]}}}", c_cfg.settings_json.?);
    try testing.expectEqualStrings("{\"check\":{\"command\":\"clippy\"}}", c_cfg.init_options_json.?);
    try testing.expectEqualStrings("clangd", c_cfg.displayName());

    // Single language + string language_id
    try lua.doString("zide.register_lsp({ language = 'JavaScript', command = {'typescript-language-server', '--stdio'}, language_id = 'javascript' })");
    try testing.expectEqualStrings("javascript", editor.lspConfigFor("javascript").?.languageIdFor("JavaScript"));

    try testing.expectEqual(base + 3, editor.lsp_configs.items.len);
}

test "zide.register_lsp: rejects bad input, tags extension registrations" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);
    testing.log_level = .err;
    defer testing.log_level = .warn;

    const before = editor.lsp_configs.items.len;
    try lua.doString("zide.register_lsp({ command = 'x' })"); // no language
    try lua.doString("zide.register_lsp({ language = 'x' })"); // no command
    try lua.doString("zide.register_lsp({ language = 'x', command = {} })"); // empty argv
    try lua.doString("zide.register_lsp('nope')"); // not a table
    try testing.expectEqual(before, editor.lsp_configs.items.len);

    // A string language_id with two languages is ignored (warn); the
    // registration itself still lands with default ids.
    try lua.doString("zide.register_lsp({ languages = {'a', 'b'}, command = 'srv', language_id = 'wrong' })");
    try testing.expectEqualStrings("b", editor.lspConfigFor("b").?.languageIdFor("b"));

    // Extension tagging follows editor.loading_extensions
    editor.loading_extensions = true;
    try lua.doString("zide.register_lsp({ language = 'lua', command = 'lua-language-server' })");
    editor.loading_extensions = false;
    try testing.expect(editor.lspConfigFor("lua").?.from_extension);
    try testing.expect(!editor.lspConfigFor("b").?.from_extension);
    editor.dropExtensionLspConfigs();
    try testing.expect(editor.lspConfigFor("lua") == null);
    try testing.expect(editor.lspConfigFor("b") != null);
}

test "save batches tolerate hooks creating dirty tabs and closing the saved tab" {
    const t = std.testing;
    for ([_]bool{ false, true }) |close_saved| {
        var lua = try Lua.init(t.allocator);
        defer lua.deinit();
        lua.openLibs();
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        lua_settings.registerApi(lua, &editor);
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, t.io, ".", t.allocator);
        defer t.allocator.free(root);
        const path = try std.fs.path.join(t.allocator, &.{ root, "saved.txt" });
        defer t.allocator.free(path);
        try editor.activeDoc().saveAs(t.io, path);
        try editor.activeDoc().insertAtCursor("saved text");
        if (close_saved) {
            try lua.doString("zide.on('save', function() zide.exec('close_tab'); zide.insert('new work') end)");
        } else {
            try lua.doString("zide.on('save', function() for i=1,20 do zide.exec('new_document') end; zide.insert('new work') end)");
        }
        editor.saveAllAndQuit();
        try t.expect(editor.running);
        try t.expect(editor.hasUnsavedChanges());
        try t.expectEqualStrings("new work", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
        const saved = try tmp.dir.readFileAlloc(t.io, "saved.txt", t.allocator, .limited(100));
        defer t.allocator.free(saved);
        try t.expectEqualStrings("saved text", saved);
    }
}
