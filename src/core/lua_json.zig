//! Lua table → JSON text. Used by zide.register_lsp to forward `settings`
//! and `init_options` tables to language servers verbatim.
//!
//! Rules:
//! - nil → null; booleans; numbers (Lua integers as integers, floats as
//!   floats, NaN/inf → null); strings (JSON-escaped)
//! - a table is a JSON array when its keys are exactly 1..n with n = #t > 0,
//!   otherwise an object (string keys as-is, numeric keys stringified)
//! - an EMPTY table is `{}` — an empty JSON array cannot be expressed
//! - functions / userdata / threads are skipped in objects and become
//!   `null` in arrays (with a warning)
//! - nesting deeper than `max_depth` → error.TooDeep

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const lsp = @import("lsp.zig");

pub const max_depth: u8 = 32;
pub const Error = error{ OutOfMemory, TooDeep };

/// Serialize the Lua value at stack `index` as JSON into `out`.
pub fn stackValueToJson(lua: *Lua, gpa: std.mem.Allocator, index: i32, out: *std.ArrayList(u8), depth: u8) Error!void {
    const idx = lua.absIndex(index);
    switch (lua.typeOf(idx)) {
        .nil, .none => try out.appendSlice(gpa, "null"),
        .boolean => try out.appendSlice(gpa, if (lua.toBoolean(idx)) "true" else "false"),
        .number => try writeNumber(lua, gpa, idx, out),
        .string => {
            const s: []const u8 = lua.toString(idx) catch "";
            try lsp.writeJsonString(out, gpa, s);
        },
        .table => try writeTable(lua, gpa, idx, out, depth),
        else => {
            std.log.warn("lua→json: unsupported value of type {s} written as null", .{lua.typeName(lua.typeOf(idx))});
            try out.appendSlice(gpa, "null");
        },
    }
}

/// JSON text for `field` of the table at `table_index`, or null when the
/// field is nil/absent. Non-table values are rejected with a warning.
/// Caller frees.
pub fn tableFieldToJsonAlloc(lua: *Lua, gpa: std.mem.Allocator, table_index: i32, field: [:0]const u8) ?[]u8 {
    const tidx = lua.absIndex(table_index);
    const top = lua.getTop();
    defer lua.setTop(top); // also discards traversal leftovers after an error
    _ = lua.getField(tidx, field);
    switch (lua.typeOf(-1)) {
        .nil, .none => return null,
        .table => {},
        else => {
            std.log.warn("zide.register_lsp: '{s}' must be a table (ignored)", .{field});
            return null;
        },
    }
    var out: std.ArrayList(u8) = .empty;
    stackValueToJson(lua, gpa, -1, &out, 0) catch |err| {
        std.log.warn("zide.register_lsp: could not serialize '{s}' ({s}) — ignored", .{ field, @errorName(err) });
        out.deinit(gpa);
        return null;
    };
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

fn writeNumber(lua: *Lua, gpa: std.mem.Allocator, idx: i32, out: *std.ArrayList(u8)) Error!void {
    if (lua.isInteger(idx)) {
        const n = lua.toInteger(idx) catch 0;
        try out.print(gpa, "{d}", .{n});
        return;
    }
    const f = lua.toNumber(idx) catch 0;
    if (std.math.isNan(f) or std.math.isInf(f)) {
        try out.appendSlice(gpa, "null");
        return;
    }
    try out.print(gpa, "{d}", .{f});
}

fn isUnsupported(t: zlua.LuaType) bool {
    return t == .function or t == .userdata or t == .light_userdata or t == .thread;
}

fn writeTable(lua: *Lua, gpa: std.mem.Allocator, idx: i32, out: *std.ArrayList(u8), depth: u8) Error!void {
    if (depth >= max_depth) return error.TooDeep;
    // Each nesting level keeps a key + value on the Lua stack; a C call
    // only guarantees LUA_MINSTACK slots, so grow it explicitly.
    lua.checkStack(4) catch return error.TooDeep;

    // Array iff every key is an integer and there are exactly #t (> 0)
    // of them. Never call toString on a number key — lua_tolstring
    // converts the key in place and corrupts the traversal.
    const raw_len = lua.lenRaw(idx);
    var pairs: usize = 0;
    var all_int = true;
    lua.pushNil();
    while (lua.next(idx)) {
        if (lua.typeOf(-2) != .number or !lua.isInteger(-2)) all_int = false;
        pairs += 1;
        lua.pop(1); // value; the key stays for the next step
    }

    if (pairs > 0 and all_int and pairs == raw_len) {
        try out.append(gpa, '[');
        var i: usize = 1;
        while (i <= raw_len) : (i += 1) {
            if (i > 1) try out.append(gpa, ',');
            _ = lua.getIndexRaw(idx, @intCast(i));
            defer lua.pop(1);
            try stackValueToJson(lua, gpa, -1, out, depth + 1);
        }
        try out.append(gpa, ']');
        return;
    }

    try out.append(gpa, '{');
    var first = true;
    lua.pushNil();
    while (lua.next(idx)) {
        defer lua.pop(1); // value
        if (isUnsupported(lua.typeOf(-1))) {
            std.log.warn("lua→json: skipping {s} value in table", .{lua.typeName(lua.typeOf(-1))});
            continue;
        }
        var key_buf: [32]u8 = undefined;
        const key: []const u8 = switch (lua.typeOf(-2)) {
            .string => lua.toString(-2) catch continue,
            .number => if (lua.isInteger(-2))
                std.fmt.bufPrint(&key_buf, "{d}", .{lua.toInteger(-2) catch 0}) catch continue
            else
                std.fmt.bufPrint(&key_buf, "{d}", .{lua.toNumber(-2) catch 0}) catch continue,
            else => continue,
        };
        if (!first) try out.append(gpa, ',');
        first = false;
        try lsp.writeJsonString(out, gpa, key);
        try out.append(gpa, ':');
        try stackValueToJson(lua, gpa, -1, out, depth + 1);
    }
    try out.append(gpa, '}');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn jsonOfGlobal(lua: *Lua, gpa: std.mem.Allocator, code: [:0]const u8) ![]u8 {
    try lua.doString(code); // defines global `v`
    _ = lua.getGlobal("v");
    defer lua.pop(1);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try stackValueToJson(lua, gpa, -1, &out, 0);
    return out.toOwnedSlice(gpa);
}

test "lua→json: objects, arrays, scalars, escaping" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();

    const cases = [_]struct { code: [:0]const u8, want: []const u8 }{
        .{ .code = "v = { Lua = { diagnostics = { globals = {'zide'} } } }", .want = "{\"Lua\":{\"diagnostics\":{\"globals\":[\"zide\"]}}}" },
        .{ .code = "v = {1, 2.5, 'x', true, false}", .want = "[1,2.5,\"x\",true,false]" },
        .{ .code = "v = {}", .want = "{}" },
        .{ .code = "v = { s = 'q\"\\n' }", .want = "{\"s\":\"q\\\"\\n\"}" },
        .{ .code = "v = { nested = { {1}, {2} } }", .want = "{\"nested\":[[1],[2]]}" },
        .{ .code = "v = 'str'", .want = "\"str\"" },
        .{ .code = "v = 42", .want = "42" },
        .{ .code = "v = -7", .want = "-7" },
        .{ .code = "v = 1e400", .want = "null" }, // inf
        .{ .code = "v = true", .want = "true" },
        .{ .code = "v = nil", .want = "null" },
    };
    for (cases) |c| {
        const got = try jsonOfGlobal(lua, testing.allocator, c.code);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "lua→json: mixed keys become an object, functions are skipped" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    testing.log_level = .err;
    defer testing.log_level = .warn;

    const got = try jsonOfGlobal(lua, testing.allocator, "v = { a = 1, 'first', f = function() end, [1.5] = 'x' }");
    defer testing.allocator.free(got);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("a").?.integer);
    try testing.expectEqualStrings("first", parsed.value.object.get("1").?.string);
    try testing.expectEqualStrings("x", parsed.value.object.get("1.5").?.string);
    try testing.expect(parsed.value.object.get("f") == null);
}

test "lua→json: tableFieldToJsonAlloc" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();

    try lua.doString("cfg = { settings = { x = { y = 2 } }, bad = 5 }");
    _ = lua.getGlobal("cfg");
    defer lua.pop(1);
    const top = lua.getTop();

    const s = tableFieldToJsonAlloc(lua, testing.allocator, -1, "settings").?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"x\":{\"y\":2}}", s);
    try testing.expect(tableFieldToJsonAlloc(lua, testing.allocator, -1, "missing") == null);

    testing.log_level = .err;
    defer testing.log_level = .warn;
    try testing.expect(tableFieldToJsonAlloc(lua, testing.allocator, -1, "bad") == null);
    try testing.expectEqual(top, lua.getTop()); // stack balanced
}

test "lua→json: depth cap" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();

    try lua.doString("v = {} local t = v for i = 1, 40 do t.n = {} t = t.n end");
    _ = lua.getGlobal("v");
    defer lua.pop(1);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.TooDeep, stackValueToJson(lua, testing.allocator, -1, &out, 0));
}
