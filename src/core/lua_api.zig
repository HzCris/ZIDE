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
}

/// Full teardown for Editor.deinit (also frees the ref lists). Must run
/// before the command registry deinits and while the Lua state is alive.
pub fn deinitLua(editor: *Editor) void {
    cleanupLuaRefs(editor);
    inline for (comptime std.meta.tags(LuaEvent)) |ev| {
        editor.lua_event_refs.getPtr(ev).deinit(editor.allocator);
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
