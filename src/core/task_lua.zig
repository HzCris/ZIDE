//! Lua registrations and main-thread problem matchers for managed tasks.
const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const Editor = @import("editor.zig").Editor;
const tasks = @import("tasks.zig");
const settings = @import("lua_settings.zig");

pub fn registerInto(lua: *Lua) void {
    lua.pushFunction(&registerTask);
    lua.setField(-2, "register_task");
    lua.pushFunction(&runTask);
    lua.setField(-2, "run_task");
    lua.pushFunction(&cancelTask);
    lua.setField(-2, "cancel_task");
}

fn stringField(lua: *Lua, table: i32, key: [:0]const u8) ?[]const u8 {
    _ = lua.getField(table, key);
    defer lua.pop(1);
    return if (lua.typeOf(-1) == .string) lua.toString(-1) catch null else null;
}
fn integerField(lua: *Lua, table: i32, key: [:0]const u8) ?i64 {
    _ = lua.getField(table, key);
    defer lua.pop(1);
    return lua.toInteger(-1) catch null;
}

fn registerTask(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = settings.getEditor(state) orelse return 0;
    register(lua, editor) catch |err| {
        editor.status_message = std.fmt.bufPrint(&editor.status_buf, "register_task: {s}", .{@errorName(err)}) catch "Invalid task registration";
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    lua.pushBoolean(true);
    return 1;
}

fn register(lua: *Lua, editor: *Editor) !void {
    if (lua.typeOf(1) != .table) return error.ExpectedTaskTable;
    const name = stringField(lua, 1, "name") orelse return error.MissingTaskName;
    const cwd = stringField(lua, 1, "cwd");
    _ = lua.getField(1, "argv");
    const argv = @import("lua_api.zig").readArgvAlloc(lua, editor.allocator, -1) orelse {
        lua.pop(1);
        return error.InvalidArgv;
    };
    lua.pop(1);
    defer {
        for (argv) |arg| editor.allocator.free(arg);
        editor.allocator.free(argv);
    }
    const env_json = @import("lua_json.zig").tableFieldToJsonAlloc(lua, editor.allocator, 1, "env");
    defer if (env_json) |json| editor.allocator.free(json);
    const env_parsed = if (env_json) |json| try std.json.parseFromSlice(std.json.Value, editor.allocator, json, .{}) else null;
    defer if (env_parsed) |parsed| parsed.deinit();
    var env: std.ArrayList(tasks.Env) = .empty;
    defer env.deinit(editor.allocator);
    if (env_parsed) |parsed| {
        if (parsed.value != .object) return error.InvalidEnvironment;
        var iterator = parsed.value.object.iterator();
        while (iterator.next()) |item| {
            if (item.value_ptr.* != .string or item.key_ptr.len == 0 or std.mem.indexOfScalar(u8, item.key_ptr.*, '=') != null) return error.InvalidEnvironment;
            try env.append(editor.allocator, .{ .name = item.key_ptr.*, .value = item.value_ptr.string });
        }
    }
    const config = try tasks.Config.create(editor.allocator, .{ .name = name, .argv = argv, .cwd = cwd, .env = env.items });
    errdefer config.destroy(editor);
    config.from_extension = editor.loading_extensions;
    _ = lua.getField(1, "problem_matcher");
    if (lua.isFunction(-1)) {
        config.matcher_ref = lua.ref(zlua.registry_index);
    } else {
        defer lua.pop(1);
        if (!lua.isNil(-1)) {
            const matcher = lua.toString(-1) catch return error.InvalidProblemMatcher;
            if (!std.mem.eql(u8, matcher, "zig")) return error.UnknownProblemMatcher;
            config.options.zig_matcher = true;
        }
    }
    try editor.tasks.register(editor, config);
}

fn runTask(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = settings.getEditor(state) orelse return 0;
    const name = lua.toString(1) catch return 0;
    const id = editor.tasks.request(editor, name) catch |err| {
        lua.pushNil();
        _ = lua.pushString(@errorName(err));
        return 2;
    };
    lua.pushInteger(@intCast(id));
    return 1;
}
fn cancelTask(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = settings.getEditor(state) orelse return 0;
    const id = std.math.cast(u64, lua.toInteger(1) catch return 0) orelse return 0;
    editor.tasks.cancel(editor, id);
    return 0;
}

/// A matcher returns nil or {file, line, col, severity, message}; locations are one-based byte columns.
pub fn match(editor: *Editor, run: *tasks.Run, ref: i32, line: []const u8) !void {
    const lua = editor.lua orelse return;
    const top = lua.getTop();
    defer lua.setTop(top);
    _ = lua.getIndexRaw(zlua.registry_index, ref);
    _ = lua.pushString(line);
    lua.protectedCall(.{ .args = 1, .results = 1 }) catch return error.TaskMatcherFailed;
    if (run.status != .running or lua.isNil(-1)) return;
    if (lua.typeOf(-1) != .table) return error.InvalidMatcherResult;
    const table = lua.absIndex(-1);
    const path = stringField(lua, table, "file") orelse stringField(lua, table, "path") orelse return error.MissingDiagnosticFile;
    const message = stringField(lua, table, "message") orelse return error.MissingDiagnosticMessage;
    const row = std.math.cast(u32, integerField(lua, table, "line") orelse 1) orelse return error.InvalidDiagnosticRange;
    const col = std.math.cast(u32, integerField(lua, table, "col") orelse 1) orelse return error.InvalidDiagnosticRange;
    if (row == 0 or col == 0) return error.InvalidDiagnosticRange;
    const severity = stringField(lua, table, "severity") orelse "error";
    try tasks.addFinding(editor, run, .{
        .path = path,
        .line = row - 1,
        .col = col - 1,
        .message = message,
        .severity = if (std.mem.eql(u8, severity, "warning")) .warning else if (std.mem.eql(u8, severity, "info")) .information else if (std.mem.eql(u8, severity, "hint")) .hint else .err,
    });
}
