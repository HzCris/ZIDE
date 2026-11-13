const std = @import("std");
const zlua = @import("zlua");
const Editor = @import("editor.zig").Editor;
const snippet_file = @import("snippet_file.zig");
const theme_mod = @import("theme.zig");
const ThemeColor = theme_mod.ThemeColor;
const syntax = @import("syntax.zig");
const lua_api = @import("lua_api.zig");
const lua_json = @import("lua_json.zig");
const lsp_mod = @import("lsp.zig");

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

    // zide.set_language / zide.get_language (per-language setting overrides)
    lua.pushFunction(&luaSetLanguage);
    lua.setField(-2, "set_language");
    lua.pushFunction(&luaGetLanguage);
    lua.setField(-2, "get_language");

    // zide.register_language
    lua.pushFunction(&luaRegisterLanguage);
    lua.setField(-2, "register_language");

    // zide.register_lsp
    lua.pushFunction(&luaRegisterLsp);
    lua.setField(-2, "register_lsp");

    // Extension runtime API (zide.command / on / exec / status, …)
    lua_api.registerInto(lua, editor);

    // Set as global
    lua.setGlobal("zide");
}

// ---------------------------------------------------------------------------
// Process-wide context (Zig 0.16): env vars and Io are no longer global in
// std — main() hands them to us before any config helper runs. The file
// logger in main.zig calls getConfigDir() before an Editor exists, so these
// can't live on the Editor.
// ---------------------------------------------------------------------------

/// Environment map from std.process.Init; set once in main().
/// (Mutable pointer: libvaxis wants `*Environ.Map` for terminfo lookups.)
pub var process_environ: ?*std.process.Environ.Map = null;
/// Io instance from std.process.Init; set once in main().
pub var global_io: ?std.Io = null;

/// Load the user's init.lua from the config directory. True when it exists
/// and ran without error; a failure is logged and shown in the status bar
/// ("init.lua:3: unexpected symbol near 'x'").
pub fn loadConfig(lua: *Lua) bool {
    const config_path = getConfigPathAlways() orelse return false;
    return runLuaFile(lua, config_path, "init.lua") == .loaded;
}

/// Outcome of running one Lua file from the config directory.
pub const LoadOutcome = enum { loaded, missing, failed };

/// Largest Lua file the loaders read (init.lua, theme files, extensions).
const max_lua_file_bytes = 16 * 1024 * 1024;

/// Load failures since startup and the status line of the latest one.
/// main() compares the count around its startup loads so it can show the
/// message again after the later startup steps (project folder, CLI files)
/// wrote their own status; reload_extensions compares it to choose between
/// "Extensions reloaded" and the error. Main thread only, like the state.
var load_failures: usize = 0;
var last_load_error_buf: [128]u8 = undefined;
var last_load_error_len: usize = 0;

pub fn loadFailureCount() usize {
    return load_failures;
}

/// Status line of the most recent load failure ("init.lua:3: ..."), or "".
pub fn lastLoadError() []const u8 {
    return last_load_error_buf[0..last_load_error_len];
}

/// Run one Lua file (init.lua, a theme file or an extension) in `lua`.
///
/// The bytes are read through Zig and compiled with loadBuffer:
/// luaL_loadfile's CRT fopen reads the UTF-8 path in the ANSI code page on
/// Windows, so a non-ASCII profile folder broke every config file. The
/// chunk is named "@<path>", so Lua positions read ".../init.lua:3:". The
/// Lua stack is restored whatever happens (results and error objects used
/// to pile up on it with every reload). A failure is logged with the path
/// and shown in the status bar; a missing file is not an error.
fn runLuaFile(lua: *Lua, path: []const u8, label: []const u8) LoadOutcome {
    const io = loaderIo(lua) orelse return .missing;
    const allocator = lua.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_lua_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => {
            noteLoadFailure(lua, path, label, @errorName(err));
            return .failed;
        },
    };
    defer allocator.free(bytes);
    const chunk_name = std.fmt.allocPrintSentinel(allocator, "@{s}", .{path}, 0) catch {
        noteLoadFailure(lua, path, label, "OutOfMemory");
        return .failed;
    };
    defer allocator.free(chunk_name);

    const top = lua.getTop();
    defer lua.setTop(top);
    lua.loadBuffer(chunkSource(bytes), chunk_name, .binary_text) catch {
        noteLoadFailure(lua, path, label, luaErrorText(lua));
        return .failed;
    };
    lua.protectedCall(.{}) catch {
        noteLoadFailure(lua, path, label, luaErrorText(lua));
        return .failed;
    };
    return .loaded;
}

/// The part of a file luaL_loadfile would compile: a UTF-8 BOM and a first
/// line starting with '#' are skipped (keeping that line's newline, so line
/// numbers still match the file).
fn chunkSource(bytes: []const u8) []const u8 {
    var text = bytes;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    if (std.mem.startsWith(u8, text, "#")) text = text[std.mem.indexOfScalar(u8, text, '\n') orelse text.len ..];
    return text;
}

/// The error object at the top of the stack as text.
fn luaErrorText(lua: *Lua) []const u8 {
    return lua.toString(-1) catch "(non-string error)";
}

/// Io for the loaders: the registered editor's, else main()'s.
fn loaderIo(lua: *Lua) ?std.Io {
    if (getEditor(@ptrCast(lua))) |editor| return editor.io;
    return global_io;
}

fn noteLoadFailure(lua: *Lua, path: []const u8, label: []const u8, msg: []const u8) void {
    load_failures +%= 1;
    // warn, not err: a broken config file is a user-script problem the
    // editor survives (and err-level logs fail `zig build test`).
    std.log.warn("Error loading {s}: {s}", .{ path, msg });
    var line_buf: [256]u8 = undefined;
    last_load_error_len = lua_api.statusText(&last_load_error_buf, loadErrorLine(&line_buf, label, msg)).len;
    if (getEditor(@ptrCast(lua))) |editor| lua_api.setStatusError(editor, "", lastLoadError());
}

/// Status line for a load error: the first line of `msg`, starting at the
/// file name when Lua's position prefix names this file ("init.lua:3: ..."
/// out of "C:/Users/.../.config/zide/init.lua:3: ..."), else "<label>: <msg>".
fn loadErrorLine(buf: []u8, label: []const u8, msg: []const u8) []const u8 {
    const first = msg[0 .. std.mem.indexOfAny(u8, msg, "\r\n") orelse msg.len];
    if (std.mem.indexOf(u8, first, label)) |at| {
        const after = at + label.len;
        const starts_name = at == 0 or first[at - 1] == '/' or first[at - 1] == '\\' or first[at - 1] == '.';
        if (starts_name and after < first.len and first[after] == ':') return first[at..];
    }
    const room = buf.len -| (label.len + 2);
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ label, first[0..@min(first.len, room)] }) catch first;
}

/// Load optional theme override files after init.lua.
/// Looks for ~/.config/zide/themes/gui-theme.lua and ~/.config/zide/themes/tui-theme.lua.
/// Also ensures the folder hierarchy exists (themes/, extensions/).
pub fn loadThemeFiles(lua: *Lua) void {
    const dir = getConfigDir() orelse return;
    const io = loaderIo(lua) orelse return;

    // Ensure subdirectory hierarchy exists
    var sub_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&sub_buf, "{s}/themes", .{dir})) |p| {
        std.Io.Dir.cwd().createDirPath(io, p) catch {};
    } else |_| {}
    if (std.fmt.bufPrint(&sub_buf, "{s}/extensions", .{dir})) |p| {
        std.Io.Dir.cwd().createDirPath(io, p) catch {};
    } else |_| {}

    // Create each template if missing, then load it.
    loadThemeFile(lua, dir, "gui-theme.lua", &createGuiThemeTemplate);
    loadThemeFile(lua, dir, "tui-theme.lua", &createTuiThemeTemplate);
}

fn loadThemeFile(lua: *Lua, dir: []const u8, name: []const u8, create_template: *const fn ([:0]const u8) void) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/themes/{s}", .{ dir, name }) catch return;
    create_template(path);
    _ = runLuaFile(lua, path, name);
}

/// Create gui-theme.lua template with commented defaults if the file doesn't exist.
fn createGuiThemeTemplate(path: [:0]const u8) void {
    const io = global_io orelse return;
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return else |_| {}
    const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    f.writeStreamingAll(io,
        \\-- ZIDE GUI Theme Overrides
        \\-- Colors use #RRGGBB or #RRGGBBAA format.
        \\-- Uncomment and edit the colors you want to change.
        \\-- These are applied AFTER the base theme selected in Settings.
        \\--
        \\-- Default values shown are from the "dark" theme.
        \\
        \\-- === Editor text area ===
        \\-- zide.set("color_text", "#e1e1e6")           -- Main editor text color
        \\-- zide.set("color_selection", "#326098")       -- Selected text highlight
        \\-- zide.set("color_cursor", "#93DDFA")          -- Cursor / caret color
        \\
        \\-- === Gutter (line numbers) ===
        \\-- zide.set("color_gutter_bg", "#28283c")       -- Gutter background
        \\-- zide.set("color_gutter_text", "#828282c8")   -- Inactive line numbers
        \\-- zide.set("color_gutter_text_active", "#e1e1e6") -- Active line number
        \\-- zide.set("color_gutter_separator", "#50505064") -- Gutter/editor border line
        \\-- zide.set("color_panel_border", "#5a5a62")   -- Side panel edges, dividers, indent guides
        \\
        \\-- === Decorations ===
        \\-- zide.set("color_wrap_marker", "#64646496")   -- Soft-wrap continuation dot
        \\-- zide.set("color_tilde", "#64646480")         -- Tilde (~) past end of file
        \\
        \\-- === Overlay panels (find, palette, settings) ===
        \\-- zide.set("color_overlay_bg", "#32323ce6")    -- Panel background
        \\-- zide.set("color_overlay_fg", "#ffffff")      -- Panel primary text
        \\-- zide.set("color_overlay_dim", "#969696c8")   -- Panel secondary / dimmed text
        \\-- zide.set("color_overlay_warn", "#ff6464")    -- Warning text (e.g. "No matches")
        \\-- zide.set("color_overlay_selection", "#505078c8") -- Highlighted row in panel
        \\-- zide.set("color_overlay_hint", "#646478b4")  -- Hint bar / descriptions
        \\
        \\-- === Settings panel indicators ===
        \\-- zide.set("color_bool_true", "#64dc64")       -- Boolean ON indicator
        \\-- zide.set("color_bool_false", "#b45050")      -- Boolean OFF indicator
        \\
        \\-- === Review reader rows (alpha = how soft the tint is) ===
        \\-- zide.set("color_review_added_bg", "#73bf6926")    -- Added lines
        \\-- zide.set("color_review_modified_bg", "#e5c07b26") -- Replaced lines
        \\-- zide.set("color_review_ghost_bg", "#e06c751a")    -- Deleted lines, kept as ghosts
        \\-- zide.set("color_review_ghost_fg", "#e1e1e678")    -- Ghost line text (dimmed)
        \\-- zide.set("color_review_marker_fg", "#828282c8")   -- "N unchanged lines" rows
        \\
        \\-- === Status bar ===
        \\-- zide.set("color_status_bg", "#1e1e1e")       -- Status bar background
        \\-- zide.set("color_status_fg", "#e1e1e6")       -- Status bar text
        \\
        \\-- === A new status message (highlighted for a few seconds) ===
        \\-- zide.set("color_status_note_bg", "#61afef")    -- Note: the block
        \\-- zide.set("color_status_note_fg", "#10141a")    -- Note: its text
        \\-- zide.set("color_status_warning_bg", "#e5c07b") -- Warning (refused, nothing to do): the block
        \\-- zide.set("color_status_warning_fg", "#1e180a") -- Warning: its text
        \\-- zide.set("color_status_error_bg", "#e06c75")   -- Error (something failed): the block
        \\-- zide.set("color_status_error_fg", "#210c0e")   -- Error: its text
        \\
    ) catch {};
}

/// Create tui-theme.lua template with commented defaults if the file doesn't exist.
fn createTuiThemeTemplate(path: [:0]const u8) void {
    const io = global_io orelse return;
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return else |_| {}
    const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    f.writeStreamingAll(io,
        \\-- ZIDE TUI Theme Overrides
        \\-- Colors use #RRGGBB format (no alpha — terminals don't support it).
        \\-- Uncomment and edit the colors you want to change.
        \\-- These are applied AFTER the base theme selected via zide.set("tui_theme", name).
        \\--
        \\-- Default values shown are from the "dark" theme.
        \\-- The default "terminal" theme uses ANSI indices instead (respects your terminal colors).
        \\
        \\-- === Editor text area ===
        \\-- zide.set("tui_color_text_fg", "#e1e1e6")        -- Main text foreground
        \\-- zide.set("tui_color_text_bg", "#1e1e1e")        -- Main text background
        \\-- zide.set("tui_color_selection_fg", "#ffffff")    -- Selected text foreground
        \\-- zide.set("tui_color_selection_bg", "#326098")    -- Selected text background
        \\-- zide.set("tui_color_cursor_fg", "#1e1e1e")      -- Cursor foreground (char under cursor)
        \\-- zide.set("tui_color_cursor_bg", "#93DDFA")      -- Cursor background (block color)
        \\
        \\-- === Gutter (line numbers) ===
        \\-- zide.set("tui_color_gutter_text", "#646464")    -- Inactive line numbers
        \\-- zide.set("tui_color_gutter_text_active", "#e1e1e6") -- Active line number
        \\-- zide.set("tui_color_gutter_separator", "#505050")   -- Gutter/editor border
        \\
        \\-- === Decorations ===
        \\-- zide.set("tui_color_tilde", "#505050")          -- Tilde (~) past end of file
        \\-- zide.set("tui_color_wrap_marker", "#505050")    -- Soft-wrap continuation dot
        \\
        \\-- === Tab bar ===
        \\-- zide.set("tui_color_tab_bg", "#323237")         -- Inactive tab background
        \\-- zide.set("tui_color_tab_fg", "#b4b4b4")         -- Inactive tab text
        \\-- zide.set("tui_color_tab_active_bg", "#326098")  -- Active tab background
        \\-- zide.set("tui_color_tab_active_fg", "#ffffff")  -- Active tab text
        \\
        \\-- === Review reader rows ===
        \\-- zide.set("tui_color_review_added_bg", "#005f00")    -- Added lines
        \\-- zide.set("tui_color_review_modified_bg", "#5f5f00") -- Replaced lines
        \\-- zide.set("tui_color_review_ghost_bg", "#5f0000")    -- Deleted lines, kept as ghosts
        \\-- zide.set("tui_color_review_ghost_fg", "#8a8a8a")    -- Ghost line text (also dimmed)
        \\-- zide.set("tui_color_review_marker_fg", "#767676")   -- "N unchanged lines" rows
        \\
        \\-- === Status bar ===
        \\-- zide.set("tui_color_status_bg", "#326098")      -- Status bar background
        \\-- zide.set("tui_color_status_fg", "#ffffff")      -- Status bar text
        \\
        \\-- === A new status message (highlighted for a few seconds) ===
        \\-- zide.set("tui_color_status_note_bg", "#87d7ff")    -- Note: the block
        \\-- zide.set("tui_color_status_note_fg", "#000000")    -- Note: its text
        \\-- zide.set("tui_color_status_warning_bg", "#ffaf00") -- Warning (refused, nothing to do): the block
        \\-- zide.set("tui_color_status_warning_fg", "#000000") -- Warning: its text
        \\-- zide.set("tui_color_status_error_bg", "#ff5f5f")   -- Error (something failed): the block
        \\-- zide.set("tui_color_status_error_fg", "#000000")   -- Error: its text
        \\
        \\-- === Overlay panels (find, palette, go-to-line) ===
        \\-- zide.set("tui_color_overlay_bg", "#282830")     -- Panel background
        \\-- zide.set("tui_color_overlay_fg", "#e1e1e6")     -- Panel primary text
        \\-- zide.set("tui_color_overlay_accent", "#93DDFA") -- Accent color (labels, borders)
        \\-- zide.set("tui_color_overlay_dim", "#787878")    -- Dimmed / secondary text
        \\-- zide.set("tui_color_overlay_selection_bg", "#3c3c5a") -- Highlighted row background
        \\-- zide.set("tui_color_overlay_selection_fg", "#ffffff") -- Highlighted row text
        \\-- zide.set("tui_color_overlay_warn", "#ff6464")   -- Warning text (e.g. "No matches")
        \\-- zide.set("tui_color_overlay_border", "#50A0C8") -- Panel border color
        \\
    ) catch {};
}

/// Get the path to init.lua (even if it doesn't exist yet).
/// All platforms: ~/.config/zide/init.lua
/// (Windows: %USERPROFILE%/.config/zide/init.lua)
pub fn getConfigPathAlways() ?[:0]const u8 {
    const S = struct {
        var buf: [512]u8 = undefined;
        var result: ?[:0]const u8 = null;
        var computed: bool = false;
    };

    if (S.computed) return S.result;
    S.computed = true;

    const home_var = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
    const env = process_environ orelse return null;
    const home = env.get(home_var) orelse return null;
    const path = std.fmt.bufPrint(&S.buf, "{s}/.config/zide/init.lua", .{home}) catch return null;
    if (path.len < S.buf.len) {
        S.buf[path.len] = 0;
        S.result = S.buf[0..path.len :0];
    }

    return S.result;
}

/// Write a single setting to init.lua. Updates existing `zide.set("key"` line or appends.
/// Creates the config directory and file if they don't exist.
/// `value` is Lua source (`true`, `4`, a string literal): build string
/// literals with quoteLuaString (or call writeStringSettingToFile). A value
/// that doesn't compile is refused (error.InvalidSettingValue) instead of
/// written, so init.lua keeps loading.
pub fn writeSettingToFile(key: []const u8, value: []const u8) !void {
    const config_path = getConfigPathAlways() orelse return error.NoConfigPath;
    const io = global_io orelse return error.NoConfigPath;
    const config_dir = getConfigDir() orelse return error.NoConfigPath;
    try std.Io.Dir.cwd().createDirPath(io, config_dir);
    try writeSettingAt(std.heap.page_allocator, io, config_path, key, value);
}

/// Persist a string setting: `zide.set("key", "<value>")` with `value`
/// quoted by quoteLuaString, so Windows paths, quotes and control bytes
/// read back exactly.
pub fn writeStringSettingToFile(key: []const u8, value: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const buf = try allocator.alloc(u8, quotedLenMax(value.len));
    defer allocator.free(buf);
    const quoted = quoteLuaString(buf, value) orelse return error.OutOfMemory; // sized for the worst case
    try writeSettingToFile(key, quoted);
}

/// Longest literal quoteLuaString can produce for `len` input bytes.
fn quotedLenMax(len: usize) usize {
    return 2 + 4 * len; // quotes + one `\ddd` per byte
}

/// `s` as a double-quoted Lua string literal written into `buf`, or null
/// when it doesn't fit. `\\`, `\"`, `\n`, `\r` and `\t` get their short
/// escapes and every other control byte (and DEL) a three-digit `\ddd`, so
/// the literal is one line and reads back byte-for-byte: Windows paths
/// such as `C:\Users\x\t` included (spliced raw between quotes, `\U` is a
/// syntax error that stops the whole init.lua from loading). Valid UTF-8
/// passes through as-is; malformed text has every byte >= 0x80 escaped.
pub fn quoteLuaString(buf: []u8, s: []const u8) ?[]const u8 {
    const escape_high = !std.unicode.utf8ValidateSlice(s);
    var w: std.Io.Writer = .fixed(buf);
    w.writeByte('"') catch return null;
    for (s) |c| {
        const written = switch (c) {
            '\\' => w.writeAll("\\\\"),
            '"' => w.writeAll("\\\""),
            '\n' => w.writeAll("\\n"),
            '\r' => w.writeAll("\\r"),
            '\t' => w.writeAll("\\t"),
            0...8, 11, 12, 14...31, 127 => w.print("\\{d:0>3}", .{c}),
            else => if (c >= 0x80 and escape_high) w.print("\\{d:0>3}", .{c}) else w.writeByte(c),
        };
        written catch return null;
    }
    w.writeByte('"') catch return null;
    return w.buffered();
}

/// Setting keys are plain identifiers; anything else would be spliced into
/// Lua source unquoted.
fn isSettingKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// A setting line must compile on its own: a malformed value (a Windows
/// path spliced between quotes without escaping) would stop the whole
/// init.lua from loading on the next launch. Compiles only; nothing runs.
fn checkSettingLine(allocator: std.mem.Allocator, line: []const u8) !void {
    const probe = try Lua.init(allocator);
    defer probe.deinit();
    probe.loadBuffer(line, "=setting", .text) catch |err| return switch (err) {
        error.LuaSyntax => error.InvalidSettingValue,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn writeSettingAt(allocator: std.mem.Allocator, io: std.Io, path: []const u8, key: []const u8, value: []const u8) !void {
    if (!isSettingKey(key)) return error.InvalidSettingKey;
    const line = try std.fmt.allocPrint(allocator, "zide.set(\"{s}\", {s})", .{ key, value });
    defer allocator.free(line);
    try checkSettingLine(allocator, line);
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "-- ZIDE settings\n"),
        else => return err,
    };
    defer allocator.free(existing);
    const pattern = try std.fmt.allocPrint(allocator, "zide.set(\"{s}\",", .{key});
    defer allocator.free(pattern);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var replaced = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |current| {
        // Match a statement, never an inline example or a commented setting.
        const trimmed = std.mem.trim(u8, current, " \t\r");
        if (!replaced and std.mem.startsWith(u8, trimmed, pattern)) {
            try output.appendSlice(allocator, line);
            replaced = true;
        } else try output.appendSlice(allocator, current);
        if (lines.index != null) try output.append(allocator, '\n');
    }
    if (!replaced) {
        if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.append(allocator, '\n');
        try output.appendSlice(allocator, line);
        try output.append(allocator, '\n');
    }
    // Prepare all bytes before opening the destination for replacement.
    try @import("text_file.zig").atomicWrite(allocator, io, path, output.items);
}

test "settings persistence preserves comments and propagates read failures" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "init.lua" });
    defer t.allocator.free(path);
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, path, "-- zide.set(\"tab_width\", 8)\nzide.set(\"tab_width\", 2)\n");
    try writeSettingAt(t.allocator, t.io, path, "tab_width", "4");
    const bytes = try tmp.dir.readFileAlloc(t.io, "init.lua", t.allocator, .limited(4096));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("-- zide.set(\"tab_width\", 8)\nzide.set(\"tab_width\", 4)\n", bytes);
    // Oversized input must be preserved, rather than treated as an empty config.
    const huge = try t.allocator.alloc(u8, 1024 * 1024 + 1);
    defer t.allocator.free(huge);
    @memset(huge, ' ');
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, path, huge);
    try t.expectError(error.StreamTooLong, writeSettingAt(t.allocator, t.io, path, "tab_width", "4"));
    const st = try tmp.dir.statFile(t.io, "init.lua", .{});
    try t.expectEqual(@as(u64, huge.len), st.size);
}

test "quoteLuaString reads back byte-for-byte through the Lua parser" {
    const t = std.testing;
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    const cases = [_][]const u8{
        "",
        "plain",
        "C:\\Users\\x\\t", // `\U` unescaped is a syntax error; `\t` a tab
        "quote \" and backslash \\",
        "tab\tnl\ncr\rend",
        "\x00\x01\x1f\x7f",
        "\x01" ++ "2", // a digit after a \ddd escape stays a digit
        "\u{e9}\u{1F600}\u{754C}",
        "bad \xff\xfe utf-8",
    };
    for (cases) |s| {
        var buf: [256]u8 = undefined;
        const quoted = quoteLuaString(&buf, s).?;
        try t.expect(std.mem.indexOfAny(u8, quoted, "\r\n") == null); // one line
        const code = try std.fmt.allocPrintSentinel(t.allocator, "v = {s}", .{quoted}, 0);
        defer t.allocator.free(code);
        try lua.doString(code);
        _ = lua.getGlobal("v");
        defer lua.pop(1);
        try t.expectEqualSlices(u8, s, try lua.toString(-1));
    }
    var small: [4]u8 = undefined;
    try t.expect(quoteLuaString(&small, "abc") == null);
    try t.expectEqualStrings("\"ab\"", quoteLuaString(&small, "ab").?);
}

test "a quoted Windows path survives init.lua; an unquoted one is refused" {
    const t = std.testing;
    t.log_level = .err;
    defer t.log_level = .warn;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "init.lua" });
    defer t.allocator.free(path);
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, path, "zide.set(\"tab_width\", 2)\n");

    // What the settings dialog writes for "C:\Users\x\t" once it quotes.
    var buf: [64]u8 = undefined;
    try writeSettingAt(t.allocator, t.io, path, "filetree_root", quoteLuaString(&buf, "C:\\Users\\x\\t").?);
    // The old splice ("\"" ++ path ++ "\"") no longer reaches the file...
    try t.expectError(error.InvalidSettingValue, writeSettingAt(t.allocator, t.io, path, "filetree_root", "\"C:\\Users\\GHz\\proj\""));
    // ...nor do keys that aren't identifiers.
    try t.expectError(error.InvalidSettingKey, writeSettingAt(t.allocator, t.io, path, "x\", 1) os.exit() --", "1"));

    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    registerApi(lua, &editor);
    try t.expectEqual(LoadOutcome.loaded, runLuaFile(lua, path, "init.lua"));
    try t.expectEqualStrings("C:\\Users\\x\\t", editor.filetree_root.?);
    try t.expectEqual(@as(usize, 2), editor.tab_width);
}

test "Lua files load from a non-ASCII directory, with a BOM and a #! line" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // luaL_loadfile's CRT fopen read this UTF-8 path in the ANSI code page.
    try tmp.dir.createDirPath(t.io, "Jos\u{e9}/\u{754C}");
    {
        const f = try tmp.dir.createFile(t.io, "Jos\u{e9}/\u{754C}/init.lua", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "\xEF\xBB\xBF#!/usr/bin/env lua\nloaded_ok = true\nreturn 'result'\n");
    }
    const dir = try tmp.dir.realPathFileAlloc(t.io, "Jos\u{e9}/\u{754C}", t.allocator);
    defer t.allocator.free(dir);
    const path = try std.fs.path.join(t.allocator, &.{ dir, "init.lua" });
    defer t.allocator.free(path);

    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    const saved_io = global_io;
    global_io = t.io; // no editor registered: the loader falls back to main()'s Io
    defer global_io = saved_io;
    const top = lua.getTop();
    try t.expectEqual(LoadOutcome.loaded, runLuaFile(lua, path, "init.lua"));
    try t.expectEqual(top, lua.getTop()); // the chunk's result is dropped
    _ = lua.getGlobal("loaded_ok");
    defer lua.pop(1);
    try t.expect(lua.toBoolean(-1));
    const missing = try std.fs.path.join(t.allocator, &.{ dir, "absent.lua" });
    defer t.allocator.free(missing);
    try t.expectEqual(LoadOutcome.missing, runLuaFile(lua, missing, "absent.lua"));
}

test "init.lua errors reach the status bar with the Lua message; the stack stays level" {
    const t = std.testing;
    t.log_level = .err; // the load errors warn
    defer t.log_level = .warn;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "init.lua" });
    defer t.allocator.free(path);

    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    registerApi(lua, &editor);
    const top = lua.getTop();

    // Syntax error: the message names the file and line, directory dropped.
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, path, "zide.set(\"tab_width\", 2)\nzide.set(\"theme\" \"dark\")\n");
    const failures = loadFailureCount();
    try t.expectEqual(LoadOutcome.failed, runLuaFile(lua, path, "init.lua"));
    try t.expectEqual(failures + 1, loadFailureCount());
    try t.expect(std.mem.startsWith(u8, editor.status_message, "init.lua:2: "));
    try t.expect(std.mem.indexOf(u8, editor.status_message, "expected") != null);
    try t.expectEqualStrings(editor.status_message, lastLoadError());
    try t.expectEqual(top, lua.getTop());
    try t.expectEqual(@as(usize, 4), editor.tab_width); // nothing ran

    // Runtime error: the lines before it ran; a multi-line message keeps
    // its first line only.
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, path, "zide.set(\"tab_width\", 2)\nerror('first line\\nsecond line')\n");
    try t.expectEqual(LoadOutcome.failed, runLuaFile(lua, path, "init.lua"));
    try t.expectEqualStrings("init.lua:2: first line", editor.status_message);
    try t.expectEqual(@as(usize, 2), editor.tab_width);
    // An error object without a position gets the file name as its prefix.
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, path, "error('no position', 0)\n");
    try t.expectEqual(LoadOutcome.failed, runLuaFile(lua, path, "init.lua"));
    try t.expectEqualStrings("init.lua: no position", editor.status_message);
    try t.expectEqual(top, lua.getTop());
}

test "zide.bind warns about unknown commands in the global map and in language overlays" {
    const t = std.testing;
    const old_level = t.log_level;
    t.log_level = .err; // the warnings themselves
    defer t.log_level = old_level;
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    registerApi(lua, &editor);

    try lua.doString("zide.bind('ctrl+alt+k', 'save'); zide.bind('ctrl+alt+j', 'save', { language = 'zig' })");
    try t.expectEqual(@as(u32, 0), editor.commands.unknown_action_warnings);
    try lua.doString("zide.bind('ctrl+alt+k', 'no_such_command')");
    try t.expectEqual(@as(u32, 1), editor.commands.unknown_action_warnings);
    try lua.doString("zide.bind('ctrl+alt+j', 'no_such_command', { language = 'zig' })");
    try t.expectEqual(@as(u32, 2), editor.commands.unknown_action_warnings);
    // The binds stand: a command registered later makes them work.
    try t.expectEqualStrings("no_such_command", editor.keybinds.get("ctrl+alt+k").?);
    try t.expectEqualStrings("no_such_command", (try editor.langProfile("zig")).keybinds.get("ctrl+alt+j").?);
    try lua.doString("zide.command('no_such_command', '', function() end); zide.bind('ctrl+alt+l', 'no_such_command')");
    try t.expectEqual(@as(u32, 2), editor.commands.unknown_action_warnings);
}

test "zide.set filetree_visible false takes the keyboard from the hidden tree only" {
    const t = std.testing;
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    registerApi(lua, &editor);

    editor.filetree_visible = true;
    editor.filetree_focused = true;
    try lua.doString("zide.set('filetree_visible', false)");
    try t.expect(!editor.filetree_visible);
    try t.expect(!editor.filetree_focused);
    try t.expect(editor.keyboardOwner() == .editor);

    // Hiding the tree leaves a focused search panel alone.
    editor.search_visible = true;
    editor.search_focused = true;
    try lua.doString("zide.set('filetree_visible', false)");
    try t.expect(editor.keyboardOwner() == .search);
    // Showing the tree doesn't steal the keyboard either.
    try lua.doString("zide.set('filetree_visible', true)");
    try t.expect(editor.filetree_visible);
    try t.expect(editor.keyboardOwner() == .search);
}

test "zide.set filetree_root drops the root-relative clipboard and move" {
    const t = std.testing;
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    registerApi(lua, &editor);

    try editor.filetree_clip_paths.append(t.allocator, try t.allocator.dupe(u8, "src/main.zig"));
    editor.filetree_clip_cut = true;
    editor.filetree_move_src = try t.allocator.dupe(u8, "src/lib.zig");
    try lua.doString("zide.set('filetree_root', 'C:/some/other/project')");
    try t.expectEqual(@as(usize, 0), editor.filetree_clip_paths.items.len);
    try t.expect(!editor.filetree_clip_cut);
    try t.expect(editor.filetree_move_src == null);
    try t.expectEqualStrings("C:/some/other/project", editor.filetree_root.?);
}

test "zide.set filetree_root from an open hook leaves the clicked tree usable until the next pump" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "a");
    try tmp.dir.createDirPath(t.io, "b");
    {
        const f = try tmp.dir.createFile(t.io, "a/f.txt", .{});
        f.close(t.io);
    }
    const root_a = try tmp.dir.realPathFileAlloc(t.io, "a", t.allocator);
    defer t.allocator.free(root_a);
    const root_b = try tmp.dir.realPathFileAlloc(t.io, "b", t.allocator);
    defer t.allocator.free(root_b);

    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_git_colors = false;
    registerApi(lua, &editor);
    try t.expect(editor.setFiletreeRoot(root_a));
    const ft = editor.ensureFiletree().?;
    const idx = ft.findByPath("f.txt").?;
    ft.selected = ft.rowOf(idx).?;

    // What a tree click does (gui.zig openFiletreeFile, then drag arming):
    // open the file — the hook re-roots — then keep using `ft`.
    const script = try std.fmt.allocPrintSentinel(t.allocator, "zide.on('open', function() zide.set('filetree_root', [[{s}]]) end)", .{root_b}, 0);
    defer t.allocator.free(script);
    try lua.doString(script);
    const abs = try ft.absPathAlloc(t.allocator, idx);
    defer t.allocator.free(abs);
    _ = try editor.openOrFocus(abs);
    try t.expectEqualStrings(root_b, editor.filetree_root.?);
    const paths = try ft.selectionRelPaths(t.allocator); // freed tree before the fix
    defer {
        for (paths) |p| t.allocator.free(p);
        t.allocator.free(paths);
    }
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expectEqualStrings("f.txt", paths[0]);

    // The next main-loop pump drops it; the next use opens the new root.
    editor.pumpLuaJobs();
    try t.expect(editor.filetree == null);
    try t.expect(editor.pathsEqual(editor.ensureFiletree().?.root_path, root_b));
}

/// Tests point the config directory at a temporary folder (the extension
/// loader tests); never set outside tests.
pub var test_config_dir: ?[]const u8 = null;

/// Get the config directory path (~/.config/zide/).
pub fn getConfigDir() ?[]const u8 {
    if (@import("builtin").is_test) if (test_config_dir) |dir| return dir;
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

/// While loadLangSyntaxThemes runs a syn_theme_<lang>.lua file it stores the
/// language name under `_zide_syn_lang`; syntax color sets are then routed
/// into that language's override instead of the global theme. Creates the
/// override (seeded from the current global themes) on first use.
/// Returns null outside per-language theme loading.
fn currentLangOverride(lua: *Lua, editor: *Editor) ?*Editor.LangSyntaxOverride {
    _ = lua.getField(zlua.registry_index, "_zide_syn_lang");
    defer lua.pop(1);
    if (lua.typeOf(-1) != .string) return null;
    const lang_z = lua.toString(-1) catch return null;
    const lang_name: []const u8 = lang_z;
    if (lang_name.len == 0) return null;

    for (editor.lang_syntax_overrides.items) |*ov| {
        if (std.ascii.eqlIgnoreCase(ov.name, lang_name)) return ov;
    }

    const owned = editor.allocator.dupe(u8, lang_name) catch return null;
    editor.lang_syntax_overrides.append(editor.allocator, .{
        .name = owned,
        .gui_theme = editor.syntax_theme,
        .tui_theme = editor.tui_syntax_theme,
    }) catch {
        editor.allocator.free(owned);
        return null;
    };
    return &editor.lang_syntax_overrides.items[editor.lang_syntax_overrides.items.len - 1];
}

/// The editor registered on this state, or null (none yet, or detached by
/// Editor.deinit: the state outlives the editor, and `__gc` finalizers run
/// during lua.deinit() must not reach a dead one).
pub fn getEditor(state: ?*zlua.LuaState) ?*Editor {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return null));
    _ = lua.getField(zlua.registry_index, EDITOR_KEY);
    const editor = lua.toUserdata(Editor, -1) catch {
        lua.pop(1);
        return null;
    };
    lua.pop(1);
    return editor;
}

/// Forget `editor` on this state (Editor.deinit via lua_api.deinitLua):
/// every zide.* call afterwards is a no-op. Leaves a different editor
/// registered later on the same state alone.
pub fn detachEditor(lua: *Lua, editor: *const Editor) void {
    const current = getEditor(@ptrCast(lua)) orelse return;
    if (current != editor) return;
    lua.pushNil();
    lua.setField(zlua.registry_index, EDITOR_KEY);
}

/// Push t[key] for the table at `index` without metamethods (lua_rawget).
/// Option tables come from user scripts; a raising `__index` would
/// longjmp through the Zig frames reading them, skipping their cleanup.
pub fn getFieldRaw(lua: *Lua, index: i32, key: [:0]const u8) zlua.LuaType {
    const table = lua.absIndex(index);
    _ = lua.pushString(key);
    return lua.getTableRaw(table);
}

/// zide.set(key, value)
/// Supported keys: "tab_width", "use_tabs", "word_wrap", "auto_close_brackets", "completion_auto", "completion_min_chars", "signature_help_auto", "review_stage_on_approve", "page_size", "status_message_seconds"
fn luaSet(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;

    const key = lua.toString(1) catch return 0;
    const key_str: []const u8 = key;

    // Theme, colors and the mono font feed dvui's per-window theme — every
    // GUI window re-applies its theme when this revision moves.
    if (std.mem.eql(u8, key_str, "theme") or std.mem.eql(u8, key_str, "mono_font_size") or
        std.mem.eql(u8, key_str, "mono_font_path") or std.mem.startsWith(u8, key_str, "color_"))
    {
        editor.theme_revision +%= 1;
    }

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
    } else if (std.mem.eql(u8, key_str, "completion_auto")) {
        editor.completion_auto = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "signature_help_auto")) {
        editor.signature_help_auto = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "review_stage_on_approve")) {
        editor.review.stage_on_approve = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "page_size")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 5 and val <= 200) {
            editor.page_size = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "editorconfig")) {
        editor.editorconfig_enabled = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "recovery")) {
        editor.recovery_enabled = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "format_on_save")) {
        editor.lsp_tools.format_on_save = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "auto_save")) {
        editor.auto_save = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "auto_save_interval_ms")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 500 and val <= 300000) {
            editor.auto_save_interval_ms = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "status_message_seconds")) {
        // Seconds a new status-bar message stays highlighted; 0 = never.
        const val = lua.toInteger(2) catch return 0;
        if (val >= 0 and val <= 30) {
            editor.status_message_seconds = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "gutter_min_digits")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 1 and val <= 10) {
            editor.gutter_min_digits = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "completion_min_chars")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 1 and val <= 8) {
            editor.completion_min_chars = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "click_clears_cursors")) {
        editor.click_clears_cursors = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "session_persistence")) {
        editor.session_persistence = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "secondary_window_chrome")) {
        // GUI: menu + status bar in extra windows (false = bare pane containers)
        editor.secondary_window_chrome = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "lsp_enabled")) {
        // Takes effect on the next frame: servers stop, or may start lazily.
        editor.lsp_enabled = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "syntax_highlighting")) {
        editor.syntax_highlighting = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "filetree_git_colors")) {
        editor.filetree_git_colors = lua.toBoolean(2);
        if (editor.filetree) |*ft| {
            ft.git_enabled = editor.filetree_git_colors;
            ft.gitRefresh();
        }
    } else if (std.mem.eql(u8, key_str, "filetree_visible")) {
        editor.filetree_visible = lua.toBoolean(2);
        // A hidden tree can't keep the keyboard; the focused pane gets it
        // back (a focused search panel keeps it).
        if (!editor.filetree_visible) editor.filetree_focused = false;
    } else if (std.mem.eql(u8, key_str, "filetree_auto_reveal")) {
        editor.filetree_auto_reveal = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "tui_filetree_icons")) {
        editor.tui_filetree_icons = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "filetree_side")) {
        // zide.set("filetree_side", "left") / "right"
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        if (std.mem.eql(u8, val_str, "left")) {
            editor.filetree_side = .left;
        } else if (std.mem.eql(u8, val_str, "right")) {
            editor.filetree_side = .right;
        } else {
            std.log.warn("zide.set: filetree_side must be \"left\" or \"right\", got '{s}'", .{val_str});
        }
    } else if (std.mem.eql(u8, key_str, "filetree_width")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 120 and val <= 600) {
            editor.filetree_width = @floatFromInt(val);
        }
    } else if (std.mem.eql(u8, key_str, "tui_filetree_width")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 16 and val <= 80) {
            editor.tui_filetree_width = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "snippets_visible")) {
        editor.snippets_visible = lua.toBoolean(2);
        if (!editor.snippets_visible) editor.snippets_focused = false;
    } else if (std.mem.eql(u8, key_str, "snippets_side")) {
        // zide.set("snippets_side", "auto") / "left" / "right"; auto docks
        // opposite the file tree.
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        if (std.mem.eql(u8, val_str, "auto")) {
            editor.snippets_side = null;
        } else if (std.mem.eql(u8, val_str, "left")) {
            editor.snippets_side = .left;
        } else if (std.mem.eql(u8, val_str, "right")) {
            editor.snippets_side = .right;
        } else {
            std.log.warn("zide.set: snippets_side must be \"auto\", \"left\" or \"right\", got '{s}'", .{val_str});
        }
    } else if (std.mem.eql(u8, key_str, "snippets_width")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 120 and val <= 600) {
            editor.snippets_width = @floatFromInt(val);
        }
    } else if (std.mem.eql(u8, key_str, "tui_snippets_width")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 16 and val <= 80) {
            editor.tui_snippets_width = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "snippets_double_click")) {
        // GUI: true = a click only selects a snippet (its preview stays
        // put); a double-click or Enter inserts it.
        editor.snippets_double_click = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "terminal_panel_side")) {
        // zide.set("terminal_panel_side", "left") / "right" / "bottom"
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        if (std.meta.stringToEnum(Editor.DockEdge, val_str)) |edge| {
            editor.terminal_panel_side = edge;
        } else {
            std.log.warn("zide.set: terminal_panel_side must be \"left\", \"right\" or \"bottom\", got '{s}'", .{val_str});
        }
    } else if (std.mem.eql(u8, key_str, "terminal_panel_width")) {
        const val = lua.toInteger(2) catch return 0;
        const lim = Editor.terminal_panel_limits;
        if (val >= @as(i64, @intFromFloat(lim.min_width)) and val <= @as(i64, @intFromFloat(lim.max_width))) {
            editor.terminal_panel_width = @floatFromInt(val);
        }
    } else if (std.mem.eql(u8, key_str, "terminal_panel_height")) {
        const val = lua.toInteger(2) catch return 0;
        const lim = Editor.terminal_panel_limits;
        if (val >= @as(i64, @intFromFloat(lim.min_height)) and val <= @as(i64, @intFromFloat(lim.max_height))) {
            editor.terminal_panel_height = @floatFromInt(val);
        }
    } else if (std.mem.eql(u8, key_str, "tui_terminal_panel_width")) {
        const val = lua.toInteger(2) catch return 0;
        const lim = Editor.terminal_panel_limits;
        if (val >= lim.tui_min_width and val <= lim.tui_max_width) {
            editor.tui_terminal_panel_width = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "tui_terminal_panel_height")) {
        const val = lua.toInteger(2) catch return 0;
        const lim = Editor.terminal_panel_limits;
        if (val >= lim.tui_min_height and val <= lim.tui_max_height) {
            editor.tui_terminal_panel_height = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "filetree_font_size")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 0 and val <= 32) {
            editor.filetree_font_size = @floatFromInt(val);
        }
    } else if (std.mem.eql(u8, key_str, "filetree_icon_scale")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 50 and val <= 200) {
            editor.filetree_icon_scale = @intCast(val);
        }
    } else if (std.mem.eql(u8, key_str, "filetree_root")) {
        // zide.set("filetree_root", "C:/path/to/project") — "" = cwd
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        // Root-relative state can't survive a root swap (as in
        // Editor.setFiletreeRoot): a cut taken under the old root would
        // otherwise paste/move same-named files under the new one.
        editor.filetreeClipClear();
        editor.cancelFiletreeMove();
        if (editor.filetree_root) |old| editor.allocator.free(old);
        editor.filetree_root = if (val_str.len == 0)
            null
        else
            editor.allocator.dupe(u8, val_str) catch null;
        // Drop the existing tree so the next use re-opens the new root — at
        // the next main-loop pump, not now: this can run inside a
        // frontend's tree handler (an "open" hook fired by a tree click)
        // that keeps using the tree after the hook returns. The tree owns
        // its root_path, so it stays valid until then.
        if (editor.filetree != null) lua_api.deferTreeReset(editor);
    } else if (std.mem.eql(u8, key_str, "max_undo_history")) {
        const val = lua.toInteger(2) catch return 0;
        if (val >= 0 and val <= 100000) {
            editor.max_undo_history = @intCast(val);
            // Update all open documents
            for (editor.documents.items) |*doc| {
                doc.history.max_size = editor.max_undo_history;
            }
        }
    } else if (std.mem.eql(u8, key_str, "theme")) {
        // zide.set("theme", "dark") / "light" / "high_contrast"
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        if (std.mem.eql(u8, val_str, "dark")) {
            editor.theme = theme_mod.gui_dark;
            editor.syntax_theme = theme_mod.syn_gui_dark;
            editor.theme_name = "dark";
        } else if (std.mem.eql(u8, val_str, "light")) {
            editor.theme = theme_mod.gui_light;
            editor.syntax_theme = theme_mod.syn_gui_light;
            editor.theme_name = "light";
        } else if (std.mem.eql(u8, val_str, "high_contrast")) {
            editor.theme = theme_mod.gui_high_contrast;
            editor.syntax_theme = theme_mod.syn_gui_high_contrast;
            editor.theme_name = "high_contrast";
        } else {
            std.log.warn("zide.set: unknown theme '{s}'", .{val_str});
        }
    } else if (std.mem.eql(u8, key_str, "tui_theme")) {
        // zide.set("tui_theme", "terminal") / "dark" / "light" / "high_contrast"
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        if (std.mem.eql(u8, val_str, "terminal")) {
            editor.tui_theme = theme_mod.tui_terminal;
            editor.tui_syntax_theme = theme_mod.syn_tui_terminal;
            editor.tui_theme_name = "terminal";
        } else if (std.mem.eql(u8, val_str, "dark")) {
            editor.tui_theme = theme_mod.tui_dark;
            editor.tui_syntax_theme = theme_mod.syn_tui_dark;
            editor.tui_theme_name = "dark";
        } else if (std.mem.eql(u8, val_str, "light")) {
            editor.tui_theme = theme_mod.tui_light;
            editor.tui_syntax_theme = theme_mod.syn_tui_light;
            editor.tui_theme_name = "light";
        } else if (std.mem.eql(u8, val_str, "high_contrast")) {
            editor.tui_theme = theme_mod.tui_high_contrast;
            editor.tui_syntax_theme = theme_mod.syn_tui_high_contrast;
            editor.tui_theme_name = "high_contrast";
        } else {
            std.log.warn("zide.set: unknown tui_theme '{s}'", .{val_str});
        }
    } else if (std.mem.eql(u8, key_str, "mono_font_path")) {
        // zide.set("mono_font_path", "C:/path/to/font.ttf")
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        if (editor.mono_font_path.len > 0) editor.allocator.free(editor.mono_font_path);
        editor.mono_font_path = editor.allocator.dupe(u8, val_str) catch {
            editor.mono_font_path = "";
            return 0;
        };
    } else if (std.mem.eql(u8, key_str, "mono_font_size")) {
        // zide.set("mono_font_size", 14)
        const val = lua.toNumber(2) catch return 0;
        editor.mono_font_size = @floatCast(val);
    } else if (std.mem.startsWith(u8, key_str, "color_")) {
        // zide.set("color_text", "#ff8040") — override individual GUI theme color
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        const field_name = key_str["color_".len..];
        if (ThemeColor.fromHex(val_str)) |color| {
            if (!theme_mod.setEditorColor(&editor.theme, field_name, color)) {
                std.log.warn("zide.set: unknown color field '{s}'", .{field_name});
            } else {
                editor.theme_name = "custom";
            }
        } else {
            std.log.warn("zide.set: invalid hex color '{s}'", .{val_str});
        }
    } else if (std.mem.startsWith(u8, key_str, "tui_color_")) {
        // zide.set("tui_color_text_fg", "#ff8040") — override individual TUI theme color
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        const field_name = key_str["tui_color_".len..];
        if (ThemeColor.fromHex(val_str)) |color| {
            if (!theme_mod.setTuiColor(&editor.tui_theme, field_name, color)) {
                std.log.warn("zide.set: unknown tui color field '{s}'", .{field_name});
            } else {
                editor.tui_theme_name = "custom";
            }
        } else {
            std.log.warn("zide.set: invalid hex color '{s}'", .{val_str});
        }
    } else if (std.mem.startsWith(u8, key_str, "tui_syn_")) {
        // zide.set("tui_syn_keyword", "#c678dd") — override TUI syntax color only.
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        const field_name = key_str["tui_syn_".len..];
        if (ThemeColor.fromHex(val_str)) |color| {
            if (currentLangOverride(lua, editor)) |ov| {
                _ = theme_mod.setTuiSyntaxColor(&ov.tui_theme, field_name, color);
            } else {
                _ = theme_mod.setTuiSyntaxColor(&editor.tui_syntax_theme, field_name, color);
            }
        } else {
            std.log.warn("zide.set: invalid hex color '{s}'", .{val_str});
        }
    } else if (std.mem.startsWith(u8, key_str, "syn_")) {
        // zide.set("syn_keyword", "#c678dd") — override syntax theme color (GUI + TUI).
        // Inside a syn_theme_<lang>.lua file this targets that language's
        // override instead of the global theme.
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        const field_name = key_str["syn_".len..];
        if (ThemeColor.fromHex(val_str)) |color| {
            if (currentLangOverride(lua, editor)) |ov| {
                _ = theme_mod.setSyntaxColor(&ov.gui_theme, field_name, color);
                _ = theme_mod.setTuiSyntaxColor(&ov.tui_theme, field_name, color);
            } else {
                _ = theme_mod.setSyntaxColor(&editor.syntax_theme, field_name, color);
                _ = theme_mod.setTuiSyntaxColor(&editor.tui_syntax_theme, field_name, color);
            }
        } else {
            std.log.warn("zide.set: invalid hex color '{s}'", .{val_str});
        }
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
    } else if (std.mem.eql(u8, key_str, "completion_auto")) {
        lua.pushBoolean(editor.completion_auto);
        return 1;
    } else if (std.mem.eql(u8, key_str, "signature_help_auto")) {
        lua.pushBoolean(editor.signature_help_auto);
        return 1;
    } else if (std.mem.eql(u8, key_str, "review_stage_on_approve")) {
        lua.pushBoolean(editor.review.stage_on_approve);
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
    } else if (std.mem.eql(u8, key_str, "status_message_seconds")) {
        lua.pushInteger(@intCast(editor.status_message_seconds));
        return 1;
    } else if (std.mem.eql(u8, key_str, "gutter_min_digits")) {
        lua.pushInteger(@intCast(editor.gutter_min_digits));
        return 1;
    } else if (std.mem.eql(u8, key_str, "completion_min_chars")) {
        lua.pushInteger(@intCast(editor.completion_min_chars));
        return 1;
    } else if (std.mem.eql(u8, key_str, "click_clears_cursors")) {
        lua.pushBoolean(editor.click_clears_cursors);
        return 1;
    } else if (std.mem.eql(u8, key_str, "editorconfig")) {
        lua.pushBoolean(editor.editorconfig_enabled);
        return 1;
    } else if (std.mem.eql(u8, key_str, "recovery")) {
        lua.pushBoolean(editor.recovery_enabled);
        return 1;
    } else if (std.mem.eql(u8, key_str, "format_on_save")) {
        lua.pushBoolean(editor.lsp_tools.format_on_save);
        return 1;
    } else if (std.mem.eql(u8, key_str, "session_persistence")) {
        lua.pushBoolean(editor.session_persistence);
        return 1;
    } else if (std.mem.eql(u8, key_str, "secondary_window_chrome")) {
        lua.pushBoolean(editor.secondary_window_chrome);
        return 1;
    } else if (std.mem.eql(u8, key_str, "lsp_enabled")) {
        lua.pushBoolean(editor.lsp_enabled);
        return 1;
    } else if (std.mem.eql(u8, key_str, "syntax_highlighting")) {
        lua.pushBoolean(editor.syntax_highlighting);
        return 1;
    } else if (std.mem.eql(u8, key_str, "filetree_git_colors")) {
        lua.pushBoolean(editor.filetree_git_colors);
        return 1;
    } else if (std.mem.eql(u8, key_str, "filetree_visible")) {
        lua.pushBoolean(editor.filetree_visible);
        return 1;
    } else if (std.mem.eql(u8, key_str, "filetree_auto_reveal")) {
        lua.pushBoolean(editor.filetree_auto_reveal);
        return 1;
    } else if (std.mem.eql(u8, key_str, "tui_filetree_icons")) {
        lua.pushBoolean(editor.tui_filetree_icons);
        return 1;
    } else if (std.mem.eql(u8, key_str, "filetree_side")) {
        _ = lua.pushString(@tagName(editor.filetree_side));
        return 1;
    } else if (std.mem.eql(u8, key_str, "filetree_width")) {
        lua.pushInteger(@intFromFloat(editor.filetree_width));
        return 1;
    } else if (std.mem.eql(u8, key_str, "tui_filetree_width")) {
        lua.pushInteger(@intCast(editor.tui_filetree_width));
        return 1;
    } else if (std.mem.eql(u8, key_str, "snippets_visible")) {
        lua.pushBoolean(editor.snippets_visible);
        return 1;
    } else if (std.mem.eql(u8, key_str, "snippets_side")) {
        _ = lua.pushString(if (editor.snippets_side) |side| @tagName(side) else "auto");
        return 1;
    } else if (std.mem.eql(u8, key_str, "snippets_width")) {
        lua.pushInteger(@intFromFloat(editor.snippets_width));
        return 1;
    } else if (std.mem.eql(u8, key_str, "tui_snippets_width")) {
        lua.pushInteger(@intCast(editor.tui_snippets_width));
        return 1;
    } else if (std.mem.eql(u8, key_str, "snippets_double_click")) {
        lua.pushBoolean(editor.snippets_double_click);
        return 1;
    } else if (std.mem.eql(u8, key_str, "terminal_panel_side")) {
        _ = lua.pushString(@tagName(editor.terminal_panel_side));
        return 1;
    } else if (std.mem.eql(u8, key_str, "terminal_panel_width")) {
        lua.pushInteger(@intFromFloat(editor.terminal_panel_width));
        return 1;
    } else if (std.mem.eql(u8, key_str, "terminal_panel_height")) {
        lua.pushInteger(@intFromFloat(editor.terminal_panel_height));
        return 1;
    } else if (std.mem.eql(u8, key_str, "tui_terminal_panel_width")) {
        lua.pushInteger(@intCast(editor.tui_terminal_panel_width));
        return 1;
    } else if (std.mem.eql(u8, key_str, "tui_terminal_panel_height")) {
        lua.pushInteger(@intCast(editor.tui_terminal_panel_height));
        return 1;
    } else if (std.mem.eql(u8, key_str, "filetree_font_size")) {
        lua.pushInteger(@intFromFloat(editor.filetree_font_size));
        return 1;
    } else if (std.mem.eql(u8, key_str, "filetree_icon_scale")) {
        lua.pushInteger(@intCast(editor.filetree_icon_scale));
        return 1;
    } else if (std.mem.eql(u8, key_str, "filetree_root")) {
        _ = lua.pushString(editor.filetree_root orelse "");
        return 1;
    } else if (std.mem.eql(u8, key_str, "max_undo_history")) {
        lua.pushInteger(@intCast(editor.max_undo_history));
        return 1;
    } else if (std.mem.eql(u8, key_str, "theme")) {
        _ = lua.pushString(editor.theme_name);
        return 1;
    } else if (std.mem.eql(u8, key_str, "tui_theme")) {
        _ = lua.pushString(editor.tui_theme_name);
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

    // zide.bind(key, cmd, { language = "zig" }) → that language's overlay,
    // consulted before the global map while editing such a file.
    if (bindLanguageOpt(lua, 3)) |lang| {
        const prof = editor.langProfile(lang) catch {
            std.log.warn("zide.bind: no profile for language '{s}' (name too long?)", .{lang});
            return 0;
        };
        prof.keybinds.set(key_str, cmd_str) catch {
            std.log.err("zide.bind: failed to set keybinding", .{});
            return 0;
        };
        // A typo'd command name no longer fails silently (the bind stands:
        // an extension may register the command later).
        editor.commands.warnIfUnknownAction(key_str, cmd_str);
        return 0;
    }

    editor.keybinds.set(key_str, cmd_str) catch {
        std.log.err("zide.bind: failed to set keybinding", .{});
        return 0;
    };
    editor.commands.warnIfUnknownAction(key_str, cmd_str);

    return 0;
}

/// zide.unbind(key_combo [, { language = "zig" }])
/// e.g. zide.unbind("ctrl+k")
fn luaUnbind(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;

    const key_z = lua.toString(1) catch return 0;
    const key_str: []const u8 = key_z;

    if (bindLanguageOpt(lua, 2)) |lang| {
        // Never creates a profile: nothing registered means nothing to remove.
        var buf: [Editor.max_lang_name]u8 = undefined;
        if (lang.len <= buf.len) {
            const key = std.ascii.lowerString(&buf, lang);
            if (editor.lang_profiles.getPtr(key)) |p| p.keybinds.remove(key_str);
        }
        return 0;
    }

    editor.keybinds.remove(key_str);

    return 0;
}

/// The `language` string of an options table at `index`, if any. The
/// slice is Lua-owned (kept alive by the table for the duration of the
/// call) — copy it before the next collection point if it must persist.
fn bindLanguageOpt(lua: *Lua, index: i32) ?[]const u8 {
    if (lua.typeOf(index) != .table) return null;
    _ = getFieldRaw(lua, index, "language");
    defer lua.pop(1);
    if (lua.typeOf(-1) != .string) return null;
    const s: []const u8 = lua.toString(-1) catch return null;
    return s;
}

// ---------------------------------------------------------------------------
// zide.register_language(table) — register a language from Lua
// ---------------------------------------------------------------------------

/// zide.set_language(name, { tab_width = 2, use_tabs = false, word_wrap = true, auto_close_brackets = false })
/// Per-language overrides of the global settings (merge: only the keys
/// given change). Works for built-in languages and for names that are
/// registered later — or never. Kept separate from zide.set because the
/// settings dialog rewrites `zide.set("tab_width"` lines in init.lua.
fn luaSetLanguage(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;
    if (lua.typeOf(1) != .string) {
        std.log.warn("zide.set_language: first argument must be the language name", .{});
        return 0;
    }
    const name: []const u8 = lua.toString(1) catch return 0;
    if (lua.typeOf(2) != .table) {
        std.log.warn("zide.set_language('{s}'): second argument must be a table of settings", .{name});
        return 0;
    }
    applyLanguageSettingsTable(lua, editor, 2, name);
    return 0;
}

/// zide.get_language(name) → table with only the overridden keys, or nil.
fn luaGetLanguage(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;
    if (lua.typeOf(1) != .string) {
        lua.pushNil();
        return 1;
    }
    const name: []const u8 = lua.toString(1) catch return 0;
    const prof = editor.langProfileNamed(name) orelse {
        lua.pushNil();
        return 1;
    };
    const s = prof.settings;
    if (s.tab_width == null and s.use_tabs == null and s.word_wrap == null and s.auto_close_brackets == null) {
        lua.pushNil();
        return 1;
    }
    lua.newTable();
    if (s.tab_width) |v| {
        lua.pushInteger(@intCast(v));
        lua.setField(-2, "tab_width");
    }
    if (s.use_tabs) |v| {
        lua.pushBoolean(v);
        lua.setField(-2, "use_tabs");
    }
    if (s.word_wrap) |v| {
        lua.pushBoolean(v);
        lua.setField(-2, "word_wrap");
    }
    if (s.auto_close_brackets) |v| {
        lua.pushBoolean(v);
        lua.setField(-2, "auto_close_brackets");
    }
    return 1;
}

/// Read the per-language setting keys from the table at `tbl` into the
/// language's profile (created on demand). Absent keys are left alone and
/// no profile is created when none is present.
fn applyLanguageSettingsTable(lua: *Lua, editor: *Editor, tbl: i32, name: []const u8) void {
    const t = lua.absIndex(tbl);
    const tab_width = readOptInteger(lua, t, "tab_width");
    const use_tabs = readOptBool(lua, t, "use_tabs");
    const word_wrap = readOptBool(lua, t, "word_wrap");
    const auto_close = readOptBool(lua, t, "auto_close_brackets");
    if (tab_width == null and use_tabs == null and word_wrap == null and auto_close == null) return;
    const prof = editor.langProfile(name) catch {
        std.log.warn("zide.set_language: no profile for '{s}' (name too long or out of memory)", .{name});
        return;
    };
    if (tab_width) |v| {
        if (v >= 1 and v <= 16) {
            prof.settings.tab_width = @intCast(v);
        } else {
            std.log.warn("zide.set_language('{s}'): tab_width must be 1..16 (got {d}) — ignored", .{ name, v });
        }
    }
    if (use_tabs) |v| prof.settings.use_tabs = v;
    if (word_wrap) |v| prof.settings.word_wrap = v;
    if (auto_close) |v| prof.settings.auto_close_brackets = v;
}

fn readOptBool(lua: *Lua, tbl: i32, field: [:0]const u8) ?bool {
    _ = getFieldRaw(lua, tbl, field);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .boolean) return null;
    return lua.toBoolean(-1);
}

fn readOptInteger(lua: *Lua, tbl: i32, field: [:0]const u8) ?i64 {
    _ = getFieldRaw(lua, tbl, field);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .number) return null;
    return lua.toInteger(-1) catch null;
}

/// zide.register_language({ name="python", extensions={"py","pyw"}, keywords={...}, ... })
/// The per-language setting keys (tab_width, use_tabs, word_wrap,
/// auto_close_brackets) are accepted here too, as sugar for set_language.
fn luaRegisterLanguage(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;

    // Argument must be a table at stack position 1
    if (lua.typeOf(1) != .table) {
        std.log.err("zide.register_language: argument must be a table", .{});
        return 0;
    }

    var arena = std.heap.ArenaAllocator.init(editor.allocator);
    const alloc = arena.allocator();

    // Read fields from the Lua table
    const name = readTableString(lua, alloc, "name") orelse {
        std.log.err("zide.register_language: 'name' field required", .{});
        arena.deinit();
        return 0;
    };
    // The name is drawn in the status bar; the GUI can't draw malformed UTF-8.
    if (!std.unicode.utf8ValidateSlice(name)) {
        std.log.warn("zide.register_language: 'name' must be valid UTF-8", .{});
        arena.deinit();
        return 0;
    }

    // Optional tokenizer selection: "generic" (default, table-driven) or
    // "markdown" (the structural native tokenizer). Read without allocating.
    var tokenizer_given = false;
    const tokenizer: syntax.TokenizerKind = blk: {
        _ = getFieldRaw(lua, 1, "tokenizer");
        defer lua.pop(1);
        if (lua.typeOf(-1) != .string) break :blk .generic;
        tokenizer_given = true;
        const s: []const u8 = lua.toString(-1) catch break :blk .generic;
        break :blk std.meta.stringToEnum(syntax.TokenizerKind, s) orelse {
            std.log.warn("zide.register_language: unknown tokenizer '{s}' for '{s}' (using generic)", .{ s, name });
            break :blk .generic;
        };
    };

    const lang = syntax.LanguageDef{
        .name = name,
        .tokenizer = tokenizer,
        .extensions = readTableStringArray(lua, alloc, "extensions"),
        .keywords = readTableStringArray(lua, alloc, "keywords"),
        .types = readTableStringArray(lua, alloc, "types"),
        .constants = readTableStringArray(lua, alloc, "constants"),
        .builtins = readTableStringArray(lua, alloc, "builtins"),
        .line_comment = readTableString(lua, alloc, "line_comment"),
        .block_comment_start = readTableString(lua, alloc, "block_comment_start"),
        .block_comment_end = readTableString(lua, alloc, "block_comment_end"),
        .string_delimiters = readTableString(lua, alloc, "string_delimiters") orelse "\"",
        .has_char_literals = readTableBool(lua, "has_char_literals"),
        .builtin_prefix = readTableChar(lua, "builtin_prefix"),
        .preproc_prefix = readTableChar(lua, "preproc_prefix"),
        .arena = arena,
    };

    // Re-registering a name replaces the definition IN PLACE: documents keep
    // pointing at the same heap slot and simply see the new tables. Their
    // highlight cache is dropped so the new definition takes effect at once.
    // This is a full replacement — a table that tweaks the built-in markdown
    // must restate `tokenizer = "markdown"` or it degrades to generic.
    if (editor.findLanguageByName(name)) |old| {
        if (old.tokenizer == .markdown and !tokenizer_given) {
            std.log.warn("zide.register_language: '{s}' replaces the markdown definition without tokenizer = \"markdown\" — structural markdown highlighting is now off", .{name});
        }
        old.deinit();
        old.* = lang;
        for (editor.documents.items) |*doc| {
            if (doc.language == @as(?*const syntax.LanguageDef, old)) doc.invalidateLineStates(0);
        }
        applyLanguageSettingsTable(lua, editor, 1, name);
        std.log.info("Re-registered language: {s}", .{name});
        return 0;
    }

    // Heap-allocate so the pointer documents hold stays stable (the editor's
    // languages list stores *LanguageDef — see Editor.languages).
    const lang_ptr = editor.allocator.create(syntax.LanguageDef) catch {
        std.log.err("zide.register_language: failed to register '{s}'", .{name});
        var failed = lang;
        failed.deinit(); // frees the arena (previously leaked on this path)
        return 0;
    };
    lang_ptr.* = lang;
    editor.languages.append(editor.allocator, lang_ptr) catch {
        std.log.err("zide.register_language: failed to register '{s}'", .{name});
        lang_ptr.deinit(); // frees the arena (previously leaked on this path)
        editor.allocator.destroy(lang_ptr);
        return 0;
    };

    applyLanguageSettingsTable(lua, editor, 1, name);
    std.log.info("Registered language: {s}", .{name});
    return 0;
}

/// Register a language server for one or more languages.
///
///   zide.register_lsp({
///     language = "c",                          -- or languages = {"c", "cpp"}: one server serves all
///     command = {"clangd", "--background-index"}, -- table = argv; a string is argv[0] ONLY (never split)
///     language_id = "c",                       -- optional; string (single language) or { [language] = id }
///     settings = { ... },                      -- optional table → JSON (workspace/configuration + didChangeConfiguration)
///     init_options = { ... },                  -- optional table → initializationOptions
///   })
///
/// Nothing is validated against the language registry (init.lua runs
/// before extensions register languages); resolution happens by name when
/// a document opens. A later registration for the same language wins.
fn luaRegisterLsp(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;
    const gpa = editor.allocator;

    // Argument must be a table at stack position 1
    if (lua.typeOf(1) != .table) {
        std.log.warn("zide.register_lsp: argument must be a table", .{});
        return 0;
    }

    // languages = {...} wins over language = "..."
    const langs: []const []const u8 = readTableStringArrayAlloc(lua, gpa, 1, "languages") orelse blk: {
        _ = getFieldRaw(lua, 1, "language");
        defer lua.pop(1);
        const s: []const u8 = lua.toString(-1) catch {
            std.log.warn("zide.register_lsp: 'language' (or 'languages') field required", .{});
            return 0;
        };
        const one = gpa.alloc([]const u8, 1) catch return 0;
        one[0] = gpa.dupe(u8, s) catch {
            gpa.free(one);
            return 0;
        };
        break :blk one;
    };
    defer {
        for (langs) |l| gpa.free(l);
        gpa.free(langs);
    }

    // command: string = argv[0] only (paths with spaces work); table = argv
    const argv: []const []const u8 = blk: {
        _ = getFieldRaw(lua, 1, "command");
        defer lua.pop(1);
        switch (lua.typeOf(-1)) {
            .string => {
                const s: []const u8 = lua.toString(-1) catch "";
                const one = gpa.alloc([]const u8, 1) catch return 0;
                one[0] = gpa.dupe(u8, s) catch {
                    gpa.free(one);
                    return 0;
                };
                break :blk one;
            },
            .table => break :blk lua_api.readArgvAlloc(lua, gpa, -1) orelse {
                std.log.warn("zide.register_lsp: 'command' table must be a non-empty list of strings", .{});
                return 0;
            },
            else => {
                std.log.warn("zide.register_lsp: 'command' field required (string or argv table)", .{});
                return 0;
            },
        }
    };
    defer {
        for (argv) |a| gpa.free(a);
        gpa.free(argv);
    }

    var cfg = lsp_mod.ServerConfig.fromArgv(gpa, langs, argv) catch return 0;

    // language_id: string (exactly one language) or { [language] = id }
    _ = getFieldRaw(lua, 1, "language_id");
    switch (lua.typeOf(-1)) {
        .string => {
            if (langs.len == 1) {
                const id: []const u8 = lua.toString(-1) catch "";
                cfg.setLanguageId(gpa, 0, id) catch {};
            } else {
                std.log.warn("zide.register_lsp: language_id as a string needs exactly one language — use a table {{ [language] = id }} (ignored)", .{});
            }
        },
        .table => {
            lua.pushNil();
            while (lua.next(-2)) {
                defer lua.pop(1);
                if (lua.typeOf(-2) != .string or lua.typeOf(-1) != .string) continue;
                const k: []const u8 = lua.toString(-2) catch continue;
                const v: []const u8 = lua.toString(-1) catch continue;
                for (cfg.languages, 0..) |lang, i| {
                    if (std.ascii.eqlIgnoreCase(lang, k)) cfg.setLanguageId(gpa, i, v) catch {};
                }
            }
        },
        else => {},
    }
    lua.pop(1);

    cfg.settings_json = lua_json.tableFieldToJsonAllocFor(lua, gpa, 1, "settings", "zide.register_lsp");
    cfg.init_options_json = lua_json.tableFieldToJsonAllocFor(lua, gpa, 1, "init_options", "zide.register_lsp");
    cfg.from_extension = editor.loading_extensions;

    editor.lsp_configs.append(gpa, cfg) catch {
        cfg.deinit(gpa);
        return 0;
    };
    std.log.info("Registered LSP: {s}{s} -> {s} ({d} arg(s){s}{s})", .{
        langs[0],
        if (langs.len > 1) " (+more)" else "",
        argv[0],
        argv.len - 1,
        if (cfg.settings_json != null) ", settings" else "",
        if (cfg.init_options_json != null) ", init_options" else "",
    });
    return 0;
}

/// Read an array-of-strings field of the table at `table_index` into
/// `gpa`-owned memory. Null when the field is absent, not a table, or
/// empty (callers fall back to their single-value form).
fn readTableStringArrayAlloc(lua: *Lua, gpa: std.mem.Allocator, table_index: i32, field: [:0]const u8) ?[]const []const u8 {
    const tidx = lua.absIndex(table_index);
    _ = getFieldRaw(lua, tidx, field);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .table) return null;
    return lua_api.readArgvAlloc(lua, gpa, -1);
}

/// Read a string field from the Lua table at stack position 1.
fn readTableString(lua: *Lua, alloc: std.mem.Allocator, field: [:0]const u8) ?[]const u8 {
    _ = getFieldRaw(lua, 1, field);
    defer lua.pop(1);
    const s = lua.toString(-1) catch return null;
    const str: []const u8 = s;
    if (str.len == 0) return null;
    return alloc.dupe(u8, str) catch null;
}

/// Read a string array field from the Lua table at stack position 1.
fn readTableStringArray(lua: *Lua, alloc: std.mem.Allocator, field: [:0]const u8) []const []const u8 {
    _ = getFieldRaw(lua, 1, field);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .table) return &.{};

    const len = lua.lenRaw(-1);
    if (len == 0) return &.{};

    var list = std.ArrayList([]const u8).initCapacity(alloc, len) catch return &.{};
    var i: usize = 1;
    while (i <= len) : (i += 1) {
        _ = lua.getIndexRaw(-1, @intCast(i));
        const s = lua.toString(-1) catch {
            lua.pop(1);
            continue;
        };
        const str: []const u8 = s;
        if (alloc.dupe(u8, str)) |duped| {
            list.append(alloc, duped) catch {};
        } else |_| {}
        lua.pop(1);
    }
    return list.items;
}

/// Read a boolean field from the Lua table at stack position 1.
fn readTableBool(lua: *Lua, field: [:0]const u8) bool {
    _ = getFieldRaw(lua, 1, field);
    defer lua.pop(1);
    return lua.toBoolean(-1);
}

/// Read a single-character field from the Lua table at stack position 1.
fn readTableChar(lua: *Lua, field: [:0]const u8) ?u8 {
    _ = getFieldRaw(lua, 1, field);
    defer lua.pop(1);
    const s = lua.toString(-1) catch return null;
    const str: []const u8 = s;
    if (str.len == 1) return str[0];
    return null;
}

// ---------------------------------------------------------------------------
// Extension and syntax theme loading
// ---------------------------------------------------------------------------

/// Load extension files from ~/.config/zide/extensions/*.lua — language
/// definitions (zide.register_language) and runtime extensions
/// (zide.command / zide.on / …) alike.
pub fn loadExtensions(lua: *Lua) void {
    const dir = getConfigDir() orelse return;
    const io = loaderIo(lua) orelse return;
    var ext_buf: [512]u8 = undefined;
    const ext_path = std.fmt.bufPrint(&ext_buf, "{s}/extensions", .{dir}) catch return;
    std.Io.Dir.cwd().createDirPath(io, ext_path) catch {};
    createLintExampleTemplate();
    createMarkdownExtensionTemplate();
    createLspExampleTemplate();

    var iter_dir = std.Io.Dir.cwd().openDir(io, ext_path, .{ .iterate = true }) catch return;
    defer iter_dir.close(io);
    ensureSnippetExtension(iter_dir, io) catch |err| std.log.warn("Cannot create snippets-zig.lua: {s}", .{@errorName(err)});

    // Tag what the extension files register (register_lsp reads this) so
    // reload_extensions can drop and re-add exactly those configs; each
    // snippet also records the file that registered it.
    const maybe_editor = getEditor(@ptrCast(lua));
    if (maybe_editor) |ed| ed.loading_extensions = true;
    defer if (maybe_editor) |ed| {
        ed.loading_extensions = false;
        ed.loading_extension_name = null;
    };

    var iter = iter_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".lua")) continue;
        // The user's own snippets file runs last (below).
        if (std.mem.eql(u8, entry.name, snippet_file.file_name)) continue;
        runExtensionFile(lua, maybe_editor, entry.name);
    }
    // After every other file, so a snippet saved from the panel replaces a
    // bundled one with the same name whatever order the OS lists files in.
    runExtensionFile(lua, maybe_editor, snippet_file.file_name);
}

/// Run `extensions/<name>` with the editor's loading context naming the
/// file; a missing file is nothing (the user's snippets file only exists
/// once something was saved to it).
fn runExtensionFile(lua: *Lua, maybe_editor: ?*Editor, name: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const full_path = extensionFilePath(&path_buf, name) orelse return;
    if (maybe_editor) |ed| ed.loading_extension_name = name;
    defer if (maybe_editor) |ed| {
        ed.loading_extension_name = null;
    };
    if (runLuaFile(lua, full_path, name) == .loaded) std.log.info("Loaded extension: {s}", .{name});
}

/// `<config dir>/extensions/<name>`, or null without a config directory
/// (or a name that does not fit).
pub fn extensionFilePath(buf: []u8, name: []const u8) ?[]const u8 {
    const dir = getConfigDir() orelse return null;
    return std.fmt.bufPrint(buf, "{s}/extensions/{s}", .{ dir, name }) catch null;
}

pub const zig_snippets = @embedFile("../extensions/snippets-zig.lua");

/// Every snippets-zig.lua ZIDE has shipped, as snippetFileHash values. An
/// installed copy matching one of them is pristine and is replaced by the
/// current file; anything else was edited by the user and is kept. The
/// current file must be listed too (a test checks), so the next version
/// can recognise it.
const shipped_snippet_hashes = [_]u64{
    0xfdc1db773038343c, // v1 (2026-09-22): nine triggers, no groups or notes
    0xf43f4a6d0749008d, // v2 (2026-10-15): 54 skeletons in groups with notes, for the Snippets panel
    0xdd96a42084a1bb3a, // v3 (2026-11-12): "Make a struct value" names the type Point, as "Struct with fields" does
};

/// Wyhash of `text` with CRLF read as LF, so a checkout or an editor that
/// converted the line endings still counts as pristine.
pub fn snippetFileHash(text: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') {
            h.update(text[start..i]);
            start = i + 1;
        }
    }
    h.update(text[start..]);
    return h.final();
}

/// Install the bundled snippets file when it is missing, or upgrade a
/// pristine older copy. Exclusive creation also preserves edits if
/// another instance starts concurrently.
pub fn ensureSnippetExtension(dir: std.Io.Dir, io: std.Io) !void {
    return ensureSnippetExtensionWith(dir, io, &shipped_snippet_hashes);
}

/// `old_hashes` are the shipped versions an installed copy may be upgraded from.
pub fn ensureSnippetExtensionWith(dir: std.Io.Dir, io: std.Io, old_hashes: []const u64) !void {
    const file = dir.createFile(io, "snippets-zig.lua", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return upgradeSnippetExtension(dir, io, old_hashes),
        else => return err,
    };
    defer file.close(io);
    try file.writeStreamingAll(io, zig_snippets);
}

/// Replace a pristine older copy with the current file, atomically; an
/// edited copy is the user's and stays.
fn upgradeSnippetExtension(dir: std.Io.Dir, io: std.Io, old_hashes: []const u64) !void {
    const allocator = std.heap.page_allocator;
    const installed = try dir.readFileAlloc(io, "snippets-zig.lua", allocator, .limited(1 << 20));
    defer allocator.free(installed);
    const hash = snippetFileHash(installed);
    if (hash == snippetFileHash(zig_snippets)) return;
    for (old_hashes) |old| {
        if (hash == old) break;
    } else return;
    var atomic = try dir.createFileAtomic(io, "snippets-zig.lua", .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, zig_snippets);
    try atomic.file.sync(io);
    try atomic.replace(io);
    std.log.info("Upgraded extensions/snippets-zig.lua to the current bundled set", .{});
}

test "snippets-zig.lua: the bundled file is a listed shipped version" {
    const hash = snippetFileHash(zig_snippets);
    for (shipped_snippet_hashes) |shipped| if (shipped == hash) return;
    std.debug.print("snippets-zig.lua changed: add 0x{x} to shipped_snippet_hashes in lua_settings.zig\n", .{hash});
    return error.UnlistedSnippetFile;
}

test "snippets-zig.lua: hashing folds CRLF to LF" {
    try std.testing.expectEqual(snippetFileHash("a\nb\n"), snippetFileHash("a\r\nb\r\n"));
    try std.testing.expect(snippetFileHash("a\nb\n") != snippetFileHash("a\nb"));
}

/// Create extensions/example-lint-zig.lua (fully commented out) if it
/// doesn't exist — a complete, working save-hook linter demonstrating the
/// extension runtime API end to end. Inert until the user uncomments it.
fn createLintExampleTemplate() void {
    const dir = getConfigDir() orelse return;
    const io = global_io orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/extensions/example-lint-zig.lua", .{dir}) catch return;
    if (path.len >= path_buf.len) return;
    path_buf[path.len] = 0;
    const z_path: [:0]const u8 = path_buf[0..path.len :0];
    if (std.Io.Dir.cwd().access(io, z_path, .{})) |_| return else |_| {}
    const f = std.Io.Dir.cwd().createFile(io, z_path, .{}) catch return;
    defer f.close(io);
    f.writeStreamingAll(io,
        \\-- ZIDE example extension: lint Zig files on save with `zig ast-check`.
        \\--
        \\-- To enable: uncomment everything below this header (and set `cmd` to a
        \\-- full zig path if zig isn't on PATH), then run the `reload_extensions`
        \\-- command from the palette (Ctrl+P) — no restart needed.
        \\--
        \\-- It's a plain extension file: copy it to build linters for other tools.
        \\-- The recipe is always the same — hook "save", run the tool with
        \\-- zide.spawn (background thread, UI never blocks), parse its output,
        \\-- hand the findings to zide.set_diagnostics. They render like LSP
        \\-- diagnostics: gutter marker, underline, message in the status bar.
        \\
        \\-- local cmd = "zig"
        \\--
        \\-- zide.on("save", function(path)
        \\--   if path == nil or not path:match("%.zig$") then return end
        \\--   zide.spawn({ cmd, "ast-check", path }, function(r)
        \\--     if r.error then
        \\--       zide.status("lint-zig: " .. r.error, "error")
        \\--       return
        \\--     end
        \\--     -- ast-check reports on stderr: file:line:col: error: message
        \\--     local diags = {}
        \\--     for line, col, kind, msg in r.stderr:gmatch("[^\r\n]-:(%d+):(%d+): (%w+): ([^\r\n]+)") do
        \\--       diags[#diags + 1] = {
        \\--         line = tonumber(line),
        \\--         col = tonumber(col),
        \\--         severity = (kind == "error") and "error" or "warning",
        \\--         message = msg,
        \\--       }
        \\--     end
        \\--     zide.set_diagnostics(path, diags) -- empty table clears old findings
        \\--     if #diags > 0 then
        \\--       zide.status(string.format("zig ast-check: %d problem(s)", #diags), "warning")
        \\--     end
        \\--   end)
        \\-- end)
        \\
    ) catch {};
}

/// Create extensions/example-lsp-servers.lua (fully commented out) if it
/// doesn't exist — copy-paste language + server registrations for the
/// common servers. Inert until the user uncomments a block.
fn createLspExampleTemplate() void {
    const dir = getConfigDir() orelse return;
    const io = global_io orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/extensions/example-lsp-servers.lua", .{dir}) catch return;
    if (path.len >= path_buf.len) return;
    path_buf[path.len] = 0;
    const z_path: [:0]const u8 = path_buf[0..path.len :0];
    if (std.Io.Dir.cwd().access(io, z_path, .{})) |_| return else |_| {}
    const f = std.Io.Dir.cwd().createFile(io, z_path, .{}) catch return;
    defer f.close(io);
    f.writeStreamingAll(io,
        \\-- ZIDE example extension: language servers for other languages.
        \\--
        \\-- ZIDE ships one server registration: `zls` from PATH for Zig. Every
        \\-- other language is yours to wire up, neovim-style — register the
        \\-- language (syntax) and point ZIDE at a server. Copy the blocks you
        \\-- want into this file or init.lua, uncomment them, then run the
        \\-- `reload_extensions` palette command (Ctrl+P) or restart ZIDE.
        \\-- Servers start lazily: the first time a file of that language opens.
        \\--
        \\-- zide.register_lsp fields:
        \\--   language / languages  the language name(s) from zide.register_language
        \\--   command               a string (the program only — never split on spaces)
        \\--                         or an argv table {"program", "--flag", ...}
        \\--   language_id           optional LSP languageId (default: the name lowercased);
        \\--                         a string for one language, or { [language] = id }
        \\--   settings              optional table → answers workspace/configuration and is
        \\--                         pushed with workspace/didChangeConfiguration
        \\--   init_options          optional table → initializationOptions
        \\-- Windows: npm shims (.cmd) work as-is; PowerShell-only (.ps1) shims do not.
        \\-- The workspace root sent to servers is the file tree root.
        \\
        \\-- C / C++ — clangd (one server, two languages)
        \\-- zide.register_language({ name = "c", extensions = {"c", "h"},
        \\--   keywords = {"auto","break","case","char","const","continue","default","do","double","else","enum","extern","float","for","goto","if","inline","int","long","register","return","short","signed","sizeof","static","struct","switch","typedef","union","unsigned","void","volatile","while"},
        \\--   types = {"size_t","uint8_t","uint16_t","uint32_t","uint64_t","int8_t","int16_t","int32_t","int64_t","bool"},
        \\--   constants = {"NULL","true","false"},
        \\--   line_comment = "//", block_comment_start = "/*", block_comment_end = "*/",
        \\--   has_char_literals = true, preproc_prefix = "#" })
        \\-- zide.register_language({ name = "cpp", extensions = {"cpp", "cc", "cxx", "hpp", "hh"},
        \\--   keywords = {"auto","break","case","catch","class","const","constexpr","continue","default","delete","do","else","enum","explicit","export","extern","for","friend","goto","if","inline","namespace","new","noexcept","operator","private","protected","public","return","static","struct","switch","template","this","throw","try","typedef","typename","union","using","virtual","volatile","while"},
        \\--   types = {"int","char","bool","void","float","double","long","short","unsigned","signed","size_t","string"},
        \\--   constants = {"nullptr","true","false","NULL"},
        \\--   line_comment = "//", block_comment_start = "/*", block_comment_end = "*/",
        \\--   has_char_literals = true, preproc_prefix = "#" })
        \\-- zide.register_lsp({ languages = {"c", "cpp"}, command = {"clangd", "--background-index"} })
        \\
        \\-- Rust — rust-analyzer (the file tree root must be the Cargo project)
        \\-- zide.register_language({ name = "rust", extensions = {"rs"},
        \\--   keywords = {"as","async","await","break","const","continue","crate","dyn","else","enum","extern","fn","for","if","impl","in","let","loop","match","mod","move","mut","pub","ref","return","self","Self","static","struct","super","trait","type","unsafe","use","where","while"},
        \\--   types = {"i8","i16","i32","i64","i128","isize","u8","u16","u32","u64","u128","usize","f32","f64","bool","char","str","String","Vec","Option","Result","Box"},
        \\--   constants = {"true","false","None","Some","Ok","Err"},
        \\--   line_comment = "//", block_comment_start = "/*", block_comment_end = "*/", has_char_literals = true })
        \\-- zide.register_lsp({ language = "rust", command = {"rust-analyzer"},
        \\--   init_options = { check = { command = "clippy" } } })
        \\
        \\-- JavaScript / TypeScript — typescript-language-server (npm i -g typescript typescript-language-server)
        \\-- zide.register_language({ name = "javascript", extensions = {"js", "mjs", "cjs"},
        \\--   keywords = {"async","await","break","case","catch","class","const","continue","default","delete","do","else","export","extends","finally","for","function","if","import","in","instanceof","let","new","of","return","static","super","switch","this","throw","try","typeof","var","void","while","with","yield"},
        \\--   constants = {"true","false","null","undefined","NaN","Infinity"},
        \\--   line_comment = "//", block_comment_start = "/*", block_comment_end = "*/", string_delimiters = "\"'`" })
        \\-- zide.register_language({ name = "typescript", extensions = {"ts", "tsx"},
        \\--   keywords = {"abstract","as","async","await","break","case","catch","class","const","continue","declare","default","delete","do","else","enum","export","extends","finally","for","function","if","implements","import","in","instanceof","interface","let","namespace","new","of","private","protected","public","readonly","return","static","super","switch","this","throw","try","type","typeof","var","void","while","yield"},
        \\--   types = {"string","number","boolean","any","unknown","never","void","object"},
        \\--   constants = {"true","false","null","undefined"},
        \\--   line_comment = "//", block_comment_start = "/*", block_comment_end = "*/", string_delimiters = "\"'`" })
        \\-- zide.register_lsp({ languages = {"javascript", "typescript"},
        \\--   command = {"typescript-language-server", "--stdio"} })
        \\
        \\-- JSON — vscode-json-language-server (npm i -g vscode-langservers-extracted)
        \\-- zide.register_language({ name = "json", extensions = {"json", "jsonc"},
        \\--   keywords = {}, constants = {"true","false","null"}, line_comment = "//",
        \\--   block_comment_start = "/*", block_comment_end = "*/" })
        \\-- zide.register_lsp({ language = "json", command = {"vscode-json-language-server", "--stdio"} })
        \\
        \\-- Python — pyright (pip install pyright  /  npm i -g pyright)
        \\-- zide.register_language({ name = "python", extensions = {"py", "pyw"},
        \\--   keywords = {"and","as","assert","async","await","break","class","continue","def","del","elif","else","except","finally","for","from","global","if","import","in","is","lambda","nonlocal","not","or","pass","raise","return","try","while","with","yield"},
        \\--   constants = {"True","False","None"},
        \\--   builtins = {"print","len","range","str","int","float","list","dict","set","tuple","open","isinstance","type","super"},
        \\--   line_comment = "#", string_delimiters = "\"'" })
        \\-- zide.register_lsp({ language = "python", command = {"pyright-langserver", "--stdio"},
        \\--   settings = { python = { analysis = { typeCheckingMode = "basic" } } } })
        \\
        \\-- Lua — lua-language-server. The `settings` teach it about ZIDE's `zide`
        \\-- global so editing init.lua / extensions shows no "undefined global".
        \\-- zide.register_language({ name = "lua", extensions = {"lua"},
        \\--   keywords = {"and","break","do","else","elseif","end","for","function","goto","if","in","local","not","or","repeat","return","then","until","while"},
        \\--   constants = {"true","false","nil"},
        \\--   builtins = {"print","pairs","ipairs","type","tostring","tonumber","require","pcall","error","assert","select","string","table","math","os","io"},
        \\--   line_comment = "--", block_comment_start = "--[[", block_comment_end = "]]", string_delimiters = "\"'" })
        \\-- zide.register_lsp({ language = "lua", command = {"lua-language-server"},
        \\--   settings = { Lua = { diagnostics = { globals = {"zide"} } } } })
        \\
        \\-- Zig — replace the built-in `zls` (from PATH) with a specific binary:
        \\-- zide.register_lsp({ language = "zig", command = {"C:/path/to/zls.exe"} })
        \\
    ) catch {};
}

/// Create extensions/markdown.lua if it doesn't exist — a small, active
/// extension dogfooding the buffer API: a palette command that toggles the
/// GFM task checkbox on the cursor line. Unlike the lint example it ships
/// enabled (pure buffer edit, no side effects); users can edit or gut it.
fn createMarkdownExtensionTemplate() void {
    const dir = getConfigDir() orelse return;
    const io = global_io orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/extensions/markdown.lua", .{dir}) catch return;
    if (path.len >= path_buf.len) return;
    path_buf[path.len] = 0;
    const z_path: [:0]const u8 = path_buf[0..path.len :0];
    if (std.Io.Dir.cwd().access(io, z_path, .{})) |_| return else |_| {}
    const f = std.Io.Dir.cwd().createFile(io, z_path, .{}) catch return;
    defer f.close(io);
    f.writeStreamingAll(io,
        \\-- ZIDE bundled extension: markdown helpers.
        \\--
        \\-- `toggle_checkbox` (palette, Ctrl+P) flips the first GFM task box on
        \\-- the cursor line between "[ ]" and "[x]". One undo step, same-length
        \\-- edit so the cursor stays put.
        \\--
        \\-- This file is a working example of the buffer API (zide.cursor /
        \\-- get_line / set_line) — copy it to build your own line-editing
        \\-- commands. Edit freely; it is only recreated if deleted.
        \\
        \\zide.command("toggle_checkbox", "Toggle markdown task checkbox on cursor line", function()
        \\  local line = zide.cursor()
        \\  local text = zide.get_line(line)
        \\  if text == nil then return end
        \\  local s, n = text:gsub("%[ %]", "[x]", 1)
        \\  if n == 0 then
        \\    s, n = text:gsub("%[[xX]%]", "[ ]", 1)
        \\  end
        \\  if n > 0 then
        \\    zide.set_line(line, s)
        \\  else
        \\    zide.status("No checkbox on this line", "warning")
        \\  end
        \\end)
        \\
    ) catch {};
}

/// Load the global syntax theme from ~/.config/zide/themes/syntax-theme.lua.
/// Creates a commented template on first run.
pub fn loadSyntaxTheme(lua: *Lua) void {
    const dir = getConfigDir() orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/themes/syntax-theme.lua", .{dir}) catch return;
    createSyntaxThemeTemplate(path);
    _ = runLuaFile(lua, path, "syntax-theme.lua");
}

/// Load per-language syntax theme files from ~/.config/zide/themes/syn_theme_*.lua.
/// Safe to re-run after a theme switch (commands.zig theme_*, the GUI theme
/// menu) once loadSyntaxTheme has rebuilt the global palette: a language's
/// palette is a full copy of the globals taken when its file first ran
/// (currentLangOverride), so every existing one is re-seeded from the
/// current globals first and the file then puts back only its own colors.
/// Re-seeded in place — the frontends hold syntaxThemeFor pointers.
pub fn loadLangSyntaxThemes(lua: *Lua) void {
    if (getEditor(@ptrCast(lua))) |editor| {
        for (editor.lang_syntax_overrides.items) |*ov| {
            ov.gui_theme = editor.syntax_theme;
            ov.tui_theme = editor.tui_syntax_theme;
        }
    }
    const dir = getConfigDir() orelse return;
    const io = loaderIo(lua) orelse return;
    var themes_buf: [512]u8 = undefined;
    const themes_path = std.fmt.bufPrint(&themes_buf, "{s}/themes", .{dir}) catch return;

    var iter_dir = std.Io.Dir.cwd().openDir(io, themes_path, .{ .iterate = true }) catch return;
    defer iter_dir.close(io);

    var iter = iter_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "syn_theme_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".lua")) continue;

        var path_buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/themes/{s}", .{ dir, entry.name }) catch continue;

        // Extract language name: syn_theme_<name>.lua → <name>
        const prefix_len = "syn_theme_".len;
        const suffix_len = ".lua".len;
        if (entry.name.len <= prefix_len + suffix_len) continue;
        const lang_name = entry.name[prefix_len .. entry.name.len - suffix_len];

        // Set a temporary global so zide.set("syn_*") routes to per-language override
        _ = lua.pushString(lang_name);
        lua.setField(zlua.registry_index, "_zide_syn_lang");

        const outcome = runLuaFile(lua, full_path, entry.name);

        // Clear the temporary lang context
        lua.pushNil();
        lua.setField(zlua.registry_index, "_zide_syn_lang");

        if (outcome == .loaded) std.log.info("Loaded syntax theme: {s}", .{entry.name});
    }
}

/// Create syntax-theme.lua template with commented defaults if the file doesn't exist.
fn createSyntaxThemeTemplate(path: [:0]const u8) void {
    const io = global_io orelse return;
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return else |_| {}
    const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    f.writeStreamingAll(io,
        \\-- ZIDE Syntax Theme
        \\-- Colors use #RRGGBB format.
        \\-- Uncomment and edit the colors you want to change.
        \\-- These apply to ALL languages (use syn_theme_<lang>.lua for per-language overrides).
        \\--
        \\-- Default values shown are from the "dark" syntax theme.
        \\
        \\-- zide.set("syn_keyword", "#c678dd")       -- Keywords (pub, fn, const, if, etc.)
        \\-- zide.set("syn_type_name", "#56b6c2")     -- Type names (u32, bool, void, etc.)
        \\-- zide.set("syn_string", "#98c379")         -- String literals ("...")
        \\-- zide.set("syn_char_literal", "#98c379")   -- Character literals ('a')
        \\-- zide.set("syn_number", "#d19a66")         -- Number literals (42, 0xff)
        \\-- zide.set("syn_comment", "#5c6370")        -- Comments (// ...)
        \\-- zide.set("syn_function", "#61afef")       -- Function calls (foo(...))
        \\-- zide.set("syn_builtin", "#e5c07b")        -- Builtins (@import, etc.)
        \\-- zide.set("syn_constant", "#d19a66")       -- Constants (true, false, null)
        \\-- zide.set("syn_operator", "#e1e1e6")       -- Operators (+, -, =, etc.)
        \\-- zide.set("syn_punctuation", "#abb2bf")    -- Punctuation ({, }, ;, etc.)
        \\-- zide.set("syn_preprocessor", "#be84d2")   -- Preprocessor (#include, etc.)
        \\-- zide.set("syn_attribute", "#e5c07b")      -- Attributes / decorators
        \\-- zide.set("syn_todo", "#e5c07b")           -- TODO/FIXME markers in comments
        \\-- zide.set("syn_heading", "#e06c75")        -- Markdown headings
        \\-- zide.set("syn_strong", "#d19a66")         -- Markdown bold
        \\-- zide.set("syn_emphasis", "#c678dd")       -- Markdown italic
        \\-- zide.set("syn_link", "#61afef")           -- Markdown links
        \\
    ) catch {};
}
