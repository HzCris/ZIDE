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
fn field(lua: *Lua, key: [:0]const u8) ?[]const u8 {
    _ = lua.getField(1, key);
    defer lua.pop(1);
    return if (lua.typeOf(-1) == .string) lua.toString(-1) catch null else null;
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
    _ = lua.getField(1, "argv");
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
    const json = @import("lua_json.zig").tableFieldToJsonAlloc(lua, editor.allocator, 1, "arguments") orelse return error.ExpectedDebugArguments;
    defer editor.allocator.free(json);
    const config = try dap.Config.create(editor.allocator, name, adapter_name, mode, json, editor.loading_extensions);
    errdefer config.deinit(editor.allocator);
    try editor.dap.registerConfig(editor, config);
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
