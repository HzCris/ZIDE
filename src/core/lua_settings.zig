const std = @import("std");
const zlua = @import("zlua");
const Editor = @import("editor.zig").Editor;

const Lua = zlua.Lua;

/// Registry key for the editor pointer.
const EDITOR_KEY = "_zide_editor";

/// Initialize the Lua API surface for ZIDE settings.
/// Registers a `zide` global table with:
///   zide.set(key, value)  — set an editor setting
///   zide.get(key)         — get an editor setting
///   zide.bind(key, cmd)   — bind a key combo to a command/action
///   zide.unbind(key)      — remove a keybinding
pub fn registerApi(lua: *Lua, editor: *Editor) void {
    // Store editor pointer in Lua registry
    lua.pushLightUserdata(@ptrCast(editor));
    lua.setField(zlua.registry_index, EDITOR_KEY);

    // Create zide table
    lua.newTable();

    // zide.set
    lua.pushFunction(&luaSet);
    lua.setField(-2, "set");

    // zide.get
    lua.pushFunction(&luaGet);
    lua.setField(-2, "get");

    // zide.bind
    lua.pushFunction(&luaBind);
    lua.setField(-2, "bind");

    // zide.unbind
    lua.pushFunction(&luaUnbind);
    lua.setField(-2, "unbind");

    // Set as global
    lua.setGlobal("zide");
}

/// Load the user's init.lua from the config directory.
/// Returns true if a config file was found and loaded successfully.
pub fn loadConfig(lua: *Lua) bool {
    const config_path = getConfigPath() orelse return false;
    lua.doFile(config_path) catch |err| {
        std.log.err("Error loading init.lua: {}", .{err});
        return false;
    };
    return true;
}

/// Get the path to init.lua (only if it exists).
/// All platforms: ~/.config/zide/init.lua
/// (Windows: %USERPROFILE%/.config/zide/init.lua)
fn getConfigPath() ?[:0]const u8 {
    const p = getConfigPathAlways() orelse return null;
    std.fs.cwd().access(p, .{}) catch return null;
    return p;
}

/// Get the path to init.lua (even if it doesn't exist yet).
pub fn getConfigPathAlways() ?[:0]const u8 {
    const S = struct {
        var buf: [512]u8 = undefined;
        var result: ?[:0]const u8 = null;
        var computed: bool = false;
    };

    if (S.computed) return S.result;
    S.computed = true;

    const home_var = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, home_var) catch return null;
    defer std.heap.page_allocator.free(home);
    const path = std.fmt.bufPrint(&S.buf, "{s}/.config/zide/init.lua", .{home}) catch return null;
    if (path.len < S.buf.len) {
        S.buf[path.len] = 0;
        S.result = S.buf[0..path.len :0];
    }

    return S.result;
}

/// Write a single setting to init.lua. Updates existing `zide.set("key"` line or appends.
/// Creates the config directory and file if they don't exist.
pub fn writeSettingToFile(key: []const u8, value: []const u8) !void {
    const config_path = getConfigPathAlways() orelse return error.NoConfigPath;

    // Ensure config directory exists
    const config_dir = getConfigDir() orelse return error.NoConfigPath;
    std.fs.cwd().makePath(config_dir) catch {};

    // Read existing file content (or empty if doesn't exist)
    var existing: []u8 = &.{};
    var file_existed = false;
    if (std.fs.cwd().openFile(config_path, .{})) |f| {
        defer f.close();
        const stat = f.stat() catch return error.ReadFailed;
        if (stat.size > 0 and stat.size < 1024 * 1024) {
            existing = std.heap.page_allocator.alloc(u8, stat.size) catch return error.OutOfMemory;
            const read = f.readAll(existing) catch {
                std.heap.page_allocator.free(existing);
                return error.ReadFailed;
            };
            existing = existing[0..read];
            file_existed = true;
        }
    } else |_| {}
    defer if (file_existed) std.heap.page_allocator.free(existing);

    // Build the target line
    var line_buf: [256]u8 = undefined;
    const new_line = std.fmt.bufPrint(&line_buf, "zide.set(\"{s}\", {s})", .{ key, value }) catch return error.FormatFailed;

    // Build search pattern: zide.set("key"
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "zide.set(\"{s}\"", .{key}) catch return error.FormatFailed;

    // Write output file
    const out_file = std.fs.cwd().createFile(config_path, .{}) catch return error.WriteFailed;
    defer out_file.close();

    if (existing.len > 0) {
        var replaced = false;
        var start: usize = 0;
        while (start < existing.len) {
            // Find end of current line
            const line_end = std.mem.indexOfScalar(u8, existing[start..], '\n');
            const end = if (line_end) |le| start + le else existing.len;
            const cur_line = existing[start..end];

            if (!replaced and std.mem.indexOf(u8, cur_line, pattern) != null) {
                // Replace this line
                out_file.writeAll(new_line) catch return error.WriteFailed;
                replaced = true;
            } else {
                out_file.writeAll(cur_line) catch return error.WriteFailed;
            }

            if (line_end) |_| {
                out_file.writeAll("\n") catch return error.WriteFailed;
                start = end + 1;
            } else {
                break;
            }
        }
        if (!replaced) {
            // Append new setting
            if (existing.len > 0 and existing[existing.len - 1] != '\n') {
                out_file.writeAll("\n") catch return error.WriteFailed;
            }
            out_file.writeAll(new_line) catch return error.WriteFailed;
            out_file.writeAll("\n") catch return error.WriteFailed;
        }
    } else {
        // New file — write header + setting
        out_file.writeAll("-- ZIDE settings\n") catch return error.WriteFailed;
        out_file.writeAll(new_line) catch return error.WriteFailed;
        out_file.writeAll("\n") catch return error.WriteFailed;
    }
}

/// Get the config directory path (~/.config/zide/).
pub fn getConfigDir() ?[]const u8 {
    const full_path = getConfigPathAlways() orelse return null;
    const path: []const u8 = full_path;
    // Find last '/' to get directory
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        return path[0..idx];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Lua callback implementations
// ---------------------------------------------------------------------------

fn getEditor(state: ?*zlua.LuaState) ?*Editor {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return null));
    _ = lua.getField(zlua.registry_index, EDITOR_KEY);
    const editor = lua.toUserdata(Editor, -1) catch {
        lua.pop(1);
        return null;
    };
    lua.pop(1);
    return editor;
}

/// zide.set(key, value)
/// Supported keys: "tab_width", "use_tabs", "word_wrap", "auto_close_brackets", "page_size"
fn luaSet(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;

    const key = lua.toString(1) catch return 0;
    const key_str: []const u8 = key;

    if (std.mem.eql(u8, key_str, "tab_width")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 1 and val <= 16) {
            editor.tab_width = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "use_tabs")) {
        editor.use_tabs = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "word_wrap")) {
        editor.word_wrap = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "auto_close_brackets")) {
        editor.auto_close_brackets = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "page_size")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 5 and val <= 200) {
            editor.page_size = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "auto_save")) {
        editor.auto_save = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "auto_save_interval_ms")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 500 and val <= 300000) {
            editor.auto_save_interval_ms = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "gutter_min_digits")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 1 and val <= 10) {
            editor.gutter_min_digits = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "click_clears_cursors")) {
        editor.click_clears_cursors = lua.toBoolean(2);
    } else {
        std.log.warn("zide.set: unknown key '{s}'", .{key_str});
    }

    return 0;
}

/// zide.get(key) -> value
fn luaGet(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;

    const key = lua.toString(1) catch return 0;
    const key_str: []const u8 = key;

    if (std.mem.eql(u8, key_str, "tab_width")) {
        lua.pushInteger(@intCast(editor.tab_width));
        return 1;
    } else if (std.mem.eql(u8, key_str, "use_tabs")) {
        lua.pushBoolean(editor.use_tabs);
        return 1;
    } else if (std.mem.eql(u8, key_str, "word_wrap")) {
        lua.pushBoolean(editor.word_wrap);
        return 1;
    } else if (std.mem.eql(u8, key_str, "auto_close_brackets")) {
        lua.pushBoolean(editor.auto_close_brackets);
        return 1;
    } else if (std.mem.eql(u8, key_str, "page_size")) {
        lua.pushInteger(@intCast(editor.page_size));
        return 1;
    } else if (std.mem.eql(u8, key_str, "auto_save")) {
        lua.pushBoolean(editor.auto_save);
        return 1;
    } else if (std.mem.eql(u8, key_str, "auto_save_interval_ms")) {
        lua.pushInteger(@intCast(editor.auto_save_interval_ms));
        return 1;
    } else if (std.mem.eql(u8, key_str, "gutter_min_digits")) {
        lua.pushInteger(@intCast(editor.gutter_min_digits));
        return 1;
    } else if (std.mem.eql(u8, key_str, "click_clears_cursors")) {
        lua.pushBoolean(editor.click_clears_cursors);
        return 1;
    }

    lua.pushNil();
    return 1;
}

/// zide.bind(key_combo, command_name)
/// e.g. zide.bind("ctrl+s", "save")
fn luaBind(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;

    const key_z = lua.toString(1) catch return 0;
    const cmd_z = lua.toString(2) catch return 0;
    const key_str: []const u8 = key_z;
    const cmd_str: []const u8 = cmd_z;

    editor.keybinds.set(key_str, cmd_str) catch {
        std.log.err("zide.bind: failed to set keybinding", .{});
    };

    return 0;
}

/// zide.unbind(key_combo)
/// e.g. zide.unbind("ctrl+k")
fn luaUnbind(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;

    const key_z = lua.toString(1) catch return 0;
    const key_str: []const u8 = key_z;

    editor.keybinds.remove(key_str);

    return 0;
}
