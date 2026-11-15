//! Lua bridge for debugging: `zide.register_debug_adapter`,
//! `zide.register_debug_config`, `zide.start_debug` and `zide.stop_debug`.
const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const Editor = @import("editor.zig").Editor;
const dap = @import("dap.zig");
const settings = @import("lua_settings.zig");
pub fn registerInto(lua: *Lua) void {
    lua.pushFunction(&registerAdapter);
    lua.setField(-2, "register_debug_adapter");
    lua.pushFunction(&registerConfig);
    lua.setField(-2, "register_debug_config");
    lua.pushFunction(&startDebug);
    lua.setField(-2, "start_debug");
    lua.pushFunction(&stopDebug);
    lua.setField(-2, "stop_debug");
}
/// Push t[key] of the option table (argument 1) without metamethods: a
/// raising `__index` must not longjmp through the Zig frames reading it.
fn rawField(lua: *Lua, key: [:0]const u8) zlua.LuaType {
    _ = lua.pushString(key);
    return lua.getTableRaw(1);
}
/// The slice stays valid while the option table holds it.
fn field(lua: *Lua, key: [:0]const u8) ?[]const u8 {
    defer lua.pop(1);
    return if (rawField(lua, key) == .string) lua.toString(-1) catch null else null;
}
fn failure(lua: *Lua, err: anyerror) c_int {
    lua.pushNil();
    _ = lua.pushString(@errorName(err));
    return 2;
}
fn registerAdapter(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = settings.getEditor(state) orelse return 0;
    adapter(lua, editor) catch |err| return failure(lua, err);
    lua.pushBoolean(true);
    return 1;
}
fn adapter(lua: *Lua, editor: *Editor) !void {
    if (lua.typeOf(1) != .table) return error.ExpectedAdapterTable;
    const name = field(lua, "name") orelse return error.MissingAdapterName;
    _ = rawField(lua, "argv");
    const argv = @import("lua_api.zig").readArgvAlloc(lua, editor.allocator, -1) orelse {
        lua.pop(1);
        return error.InvalidAdapterArgv;
    };
    lua.pop(1);
    defer {
        for (argv) |arg| editor.allocator.free(arg);
        editor.allocator.free(argv);
    }
    const config = try dap.Adapter.create(editor.allocator, name, argv, editor.loading_extensions);
    errdefer config.destroy(editor.allocator);
    try editor.dap.registerAdapter(editor, config);
}
fn registerConfig(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = settings.getEditor(state) orelse return 0;
    configuration(lua, editor) catch |err| return failure(lua, err);
    lua.pushBoolean(true);
    return 1;
}
fn configuration(lua: *Lua, editor: *Editor) !void {
    if (lua.typeOf(1) != .table) return error.ExpectedDebugConfiguration;
    const name = field(lua, "name") orelse return error.MissingConfigurationName;
    const adapter_name = field(lua, "adapter") orelse return error.MissingAdapterName;
    const mode = std.meta.stringToEnum(dap.Mode, field(lua, "request") orelse "launch") orelse return error.InvalidDebugRequest;
    const lua_json = @import("lua_json.zig");
    const raw = lua_json.tableFieldToJsonAllocFor(lua, editor.allocator, 1, "arguments", "zide.register_debug_config") orelse return error.ExpectedDebugArguments;
    defer editor.allocator.free(raw);
    const json = try listsFromEmptyTablesAlloc(editor.allocator, raw);
    defer editor.allocator.free(json);
    const config = try dap.Config.create(editor.allocator, name, adapter_name, mode, json, editor.loading_extensions);
    errdefer config.deinit(editor.allocator);
    try editor.dap.registerConfig(editor, config);
}
/// lua_json writes an empty Lua table as `{}` (Lua cannot tell `{}` the list
/// from `{}` the map), but adapters validate list-typed launch options
/// strictly: `args = {}` must reach them as `[]`. Converted keys: `args`,
/// `argv`, and names ending in `Args` or `Commands` (runtimeArgs,
/// initCommands, …), at any depth. Anything else keeps `{}` (`env = {}`).
fn listsFromEmptyTablesAlloc(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    listsFromEmptyTables(arena.allocator(), &value);
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}
fn listsFromEmptyTables(arena: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const item = entry.value_ptr;
                if (item.* == .object and item.object.count() == 0 and listKey(entry.key_ptr.*)) {
                    item.* = .{ .array = std.json.Array.init(arena) };
                } else listsFromEmptyTables(arena, item);
            }
        },
        .array => |*items| for (items.items) |*item| listsFromEmptyTables(arena, item),
        else => {},
    }
}
fn listKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "args") or std.mem.eql(u8, key, "argv") or std.mem.endsWith(u8, key, "Args") or std.mem.endsWith(u8, key, "Commands");
}
fn startDebug(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = settings.getEditor(state) orelse return 0;
    const name = lua.toString(1) catch return failure(lua, error.MissingConfigurationName);
    editor.dap.start(editor, name) catch |err| return failure(lua, err);
    lua.pushBoolean(true);
    return 1;
}
fn stopDebug(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = settings.getEditor(state) orelse return 0;
    editor.dap.stop(editor, lua.getTop() > 0 and lua.toBoolean(1));
    return 0;
}

test "Lua debug registrations are explicit, validate interactive launch and survive extension replacement" {
    const t = std.testing;
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    settings.registerApi(lua, &editor);
    editor.loading_extensions = true;
    try lua.doString(
        \\assert(zide.register_debug_adapter({name='LLDB', argv={'lldb-dap'}}))
        \\assert(zide.register_debug_config({name='app', adapter='LLDB', arguments={program='${workspaceFolder}/app'}}))
        \\local ok, err = zide.register_debug_config({name='terminal',adapter='LLDB',arguments={runInTerminal=true}})
        \\assert(ok == nil and err == 'InteractiveDebuggingUnsupported')
    );
    editor.loading_extensions = false;
    try t.expect(editor.dap.session == null);
    try t.expectEqual(@as(usize, 1), editor.dap.configs.items.len);
    editor.dap.dropExtensions(&editor);
    try t.expectEqual(@as(usize, 0), editor.dap.configs.items.len);
    try t.expectEqual(@as(usize, 0), editor.dap.adapters.items.len);
}

test "Lua debug configurations send empty list options as [] and read option tables raw" {
    const t = std.testing;
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    settings.registerApi(lua, &editor);
    try lua.doString(
        \\assert(zide.register_debug_config({name='empty', adapter='LLDB', arguments={
        \\  program='app', args={}, initCommands={}, env={}, nested={runtimeArgs={}, keep={}}}}))
        \\local trap = setmetatable({name='trap', adapter='LLDB', arguments={}}, {__index=function() error('index trap') end})
        \\assert(zide.register_debug_config(trap))
        \\local ok, err = zide.register_debug_adapter(setmetatable({}, {__index=function() error('index trap') end}))
        \\assert(ok == nil and err == 'MissingAdapterName')
    );
    try t.expectEqual(@as(usize, 2), editor.dap.configs.items.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, editor.dap.configs.items[0].arguments, .{});
    defer parsed.deinit();
    const arguments = parsed.value.object;
    try t.expect(arguments.get("args").? == .array);
    try t.expect(arguments.get("initCommands").? == .array);
    try t.expect(arguments.get("env").? == .object);
    try t.expect(arguments.get("nested").?.object.get("runtimeArgs").? == .array);
    try t.expect(arguments.get("nested").?.object.get("keep").? == .object);
    try t.expectEqualStrings("app", arguments.get("program").?.string);
}
