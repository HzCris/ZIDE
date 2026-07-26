const std = @import("std");
const zlua = @import("zlua");
const Editor = @import("editor.zig").Editor;
const theme_mod = @import("theme.zig");
const ThemeColor = theme_mod.ThemeColor;
const syntax = @import("syntax.zig");
const lua_api = @import("lua_api.zig");

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

/// Load optional theme override files after init.lua.
/// Looks for ~/.config/zide/themes/gui-theme.lua and ~/.config/zide/themes/tui-theme.lua.
/// Also ensures the folder hierarchy exists (themes/, extensions/).
pub fn loadThemeFiles(lua: *Lua) void {
    const dir = getConfigDir() orelse return;
    const io = global_io orelse return;

    // Ensure subdirectory hierarchy exists
    var sub_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&sub_buf, "{s}/themes", .{dir})) |p| {
        std.Io.Dir.cwd().createDirPath(io, p) catch {};
    } else |_| {}
    if (std.fmt.bufPrint(&sub_buf, "{s}/extensions", .{dir})) |p| {
        std.Io.Dir.cwd().createDirPath(io, p) catch {};
    } else |_| {}

    // gui-theme.lua — create template if missing, then load
    var gui_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&gui_buf, "{s}/themes/gui-theme.lua", .{dir})) |path| {
        if (path.len < gui_buf.len) {
            gui_buf[path.len] = 0;
            const z_path: [:0]const u8 = gui_buf[0..path.len :0];
            createGuiThemeTemplate(z_path);
            if (std.Io.Dir.cwd().access(io, z_path, .{})) |_| {
                lua.doFile(z_path) catch |err| {
                    std.log.err("Error loading gui-theme.lua: {}", .{err});
                };
            } else |_| {}
        }
    } else |_| {}

    // tui-theme.lua — create template if missing, then load
    var tui_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&tui_buf, "{s}/themes/tui-theme.lua", .{dir})) |path| {
        if (path.len < tui_buf.len) {
            tui_buf[path.len] = 0;
            const z_path: [:0]const u8 = tui_buf[0..path.len :0];
            createTuiThemeTemplate(z_path);
            if (std.Io.Dir.cwd().access(io, z_path, .{})) |_| {
                lua.doFile(z_path) catch |err| {
                    std.log.err("Error loading tui-theme.lua: {}", .{err});
                };
            } else |_| {}
        }
    } else |_| {}
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
        \\-- === Status bar ===
        \\-- zide.set("color_status_bg", "#1e1e1e")       -- Status bar background
        \\-- zide.set("color_status_fg", "#e1e1e6")       -- Status bar text
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
        \\-- === Status bar ===
        \\-- zide.set("tui_color_status_bg", "#326098")      -- Status bar background
        \\-- zide.set("tui_color_status_fg", "#ffffff")      -- Status bar text
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

/// Get the path to init.lua (only if it exists).
/// All platforms: ~/.config/zide/init.lua
/// (Windows: %USERPROFILE%/.config/zide/init.lua)
fn getConfigPath() ?[:0]const u8 {
    const p = getConfigPathAlways() orelse return null;
    const io = global_io orelse return null;
    std.Io.Dir.cwd().access(io, p, .{}) catch return null;
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
pub fn writeSettingToFile(key: []const u8, value: []const u8) !void {
    const config_path = getConfigPathAlways() orelse return error.NoConfigPath;
    const io = global_io orelse return error.NoConfigPath;

    // Ensure config directory exists
    const config_dir = getConfigDir() orelse return error.NoConfigPath;
    std.Io.Dir.cwd().createDirPath(io, config_dir) catch {};

    // Read existing file content (or empty if doesn't exist / oversized)
    var existing: []u8 = &.{};
    var file_existed = false;
    if (std.Io.Dir.cwd().readFileAlloc(io, config_path, std.heap.page_allocator, .limited(1024 * 1024))) |contents| {
        if (contents.len > 0) {
            existing = contents;
            file_existed = true;
        } else {
            std.heap.page_allocator.free(contents);
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
    const out_file = std.Io.Dir.cwd().createFile(io, config_path, .{}) catch return error.WriteFailed;
    defer out_file.close(io);

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
                out_file.writeStreamingAll(io, new_line) catch return error.WriteFailed;
                replaced = true;
            } else {
                out_file.writeStreamingAll(io, cur_line) catch return error.WriteFailed;
            }

            if (line_end) |_| {
                out_file.writeStreamingAll(io, "\n") catch return error.WriteFailed;
                start = end + 1;
            } else {
                break;
            }
        }
        if (!replaced) {
            // Append new setting
            if (existing.len > 0 and existing[existing.len - 1] != '\n') {
                out_file.writeStreamingAll(io, "\n") catch return error.WriteFailed;
            }
            out_file.writeStreamingAll(io, new_line) catch return error.WriteFailed;
            out_file.writeStreamingAll(io, "\n") catch return error.WriteFailed;
        }
    } else {
        // New file — write header + setting
        out_file.writeStreamingAll(io, "-- ZIDE settings\n") catch return error.WriteFailed;
        out_file.writeStreamingAll(io, new_line) catch return error.WriteFailed;
        out_file.writeStreamingAll(io, "\n") catch return error.WriteFailed;
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
    } else if (std.mem.eql(u8, key_str, "session_persistence")) {
        editor.session_persistence = lua.toBoolean(2);
    } else if (std.mem.eql(u8, key_str, "lsp_enabled")) {
        // Read before the LSP starts; runtime changes take effect next launch.
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
    } else if (std.mem.eql(u8, key_str, "filetree_root")) {
        // zide.set("filetree_root", "C:/path/to/project") — "" = cwd
        const val = lua.toString(2) catch return 0;
        const val_str: []const u8 = val;
        if (editor.filetree_root) |old| editor.allocator.free(old);
        editor.filetree_root = if (val_str.len == 0)
            null
        else
            editor.allocator.dupe(u8, val_str) catch null;
        // Drop any existing tree so the next use re-opens the new root
        if (editor.filetree) |*ft| {
            ft.deinit();
            editor.filetree = null;
        }
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
    } else if (std.mem.eql(u8, key_str, "session_persistence")) {
        lua.pushBoolean(editor.session_persistence);
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

// ---------------------------------------------------------------------------
// zide.register_language(table) — register a language from Lua
// ---------------------------------------------------------------------------

/// zide.register_language({ name="python", extensions={"py","pyw"}, keywords={...}, ... })
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

    const lang = syntax.LanguageDef{
        .name = name,
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

    std.log.info("Registered language: {s}", .{name});
    return 0;
}

/// Register an LSP server for a language.
/// Usage: zide.register_lsp({ language = "Python", command = "pyright-langserver" })
fn luaRegisterLsp(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = getEditor(state) orelse return 0;

    // Argument must be a table at stack position 1
    if (lua.typeOf(1) != .table) {
        std.log.err("zide.register_lsp: argument must be a table", .{});
        return 0;
    }

    const language = blk: {
        _ = lua.getField(1, "language");
        defer lua.pop(1);
        const s = lua.toString(-1) catch {
            std.log.err("zide.register_lsp: 'language' field required", .{});
            return 0;
        };
        break :blk editor.allocator.dupe(u8, s) catch return 0;
    };

    const command = blk: {
        _ = lua.getField(1, "command");
        defer lua.pop(1);
        const s = lua.toString(-1) catch {
            std.log.err("zide.register_lsp: 'command' field required", .{});
            editor.allocator.free(language);
            return 0;
        };
        break :blk editor.allocator.dupe(u8, s) catch {
            editor.allocator.free(language);
            return 0;
        };
    };

    editor.lsp_configs.append(editor.allocator, .{
        .language = language,
        .command = command,
    }) catch {
        editor.allocator.free(language);
        editor.allocator.free(command);
        return 0;
    };

    std.log.info("Registered LSP: {s} -> {s}", .{ language, command });
    return 0;
}

/// Read a string field from the Lua table at stack position 1.
fn readTableString(lua: *Lua, alloc: std.mem.Allocator, field: [:0]const u8) ?[]const u8 {
    _ = lua.getField(1, field);
    defer lua.pop(1);
    const s = lua.toString(-1) catch return null;
    const str: []const u8 = s;
    if (str.len == 0) return null;
    return alloc.dupe(u8, str) catch null;
}

/// Read a string array field from the Lua table at stack position 1.
fn readTableStringArray(lua: *Lua, alloc: std.mem.Allocator, field: [:0]const u8) []const []const u8 {
    _ = lua.getField(1, field);
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
    _ = lua.getField(1, field);
    defer lua.pop(1);
    return lua.toBoolean(-1);
}

/// Read a single-character field from the Lua table at stack position 1.
fn readTableChar(lua: *Lua, field: [:0]const u8) ?u8 {
    _ = lua.getField(1, field);
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
    const io = global_io orelse return;
    var ext_buf: [512]u8 = undefined;
    const ext_path = std.fmt.bufPrint(&ext_buf, "{s}/extensions", .{dir}) catch return;
    std.Io.Dir.cwd().createDirPath(io, ext_path) catch {};
    createLintExampleTemplate();

    var iter_dir = std.Io.Dir.cwd().openDir(io, ext_path, .{ .iterate = true }) catch return;
    defer iter_dir.close(io);

    var iter = iter_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".lua")) continue;

        var path_buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/extensions/{s}", .{ dir, entry.name }) catch continue;
        if (full_path.len < path_buf.len) {
            path_buf[full_path.len] = 0;
            const z_path: [:0]const u8 = path_buf[0..full_path.len :0];
            lua.doFile(z_path) catch |err| {
                std.log.err("Error loading extension {s}: {}", .{ entry.name, err });
                continue;
            };
            std.log.info("Loaded extension: {s}", .{entry.name});
        }
    }
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
        \\--       zide.status("lint-zig: " .. r.error)
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
        \\--       zide.status(string.format("zig ast-check: %d problem(s)", #diags))
        \\--     end
        \\--   end)
        \\-- end)
        \\
    ) catch {};
}

/// Load the global syntax theme from ~/.config/zide/themes/syntax-theme.lua.
/// Creates a commented template on first run.
pub fn loadSyntaxTheme(lua: *Lua) void {
    const dir = getConfigDir() orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/themes/syntax-theme.lua", .{dir}) catch return;
    if (path.len >= path_buf.len) return;
    path_buf[path.len] = 0;
    const z_path: [:0]const u8 = path_buf[0..path.len :0];

    createSyntaxThemeTemplate(z_path);

    const io = global_io orelse return;
    if (std.Io.Dir.cwd().access(io, z_path, .{})) |_| {
        lua.doFile(z_path) catch |err| {
            std.log.err("Error loading syntax-theme.lua: {}", .{err});
        };
    } else |_| {}
}

/// Load per-language syntax theme files from ~/.config/zide/themes/syn_theme_*.lua.
pub fn loadLangSyntaxThemes(lua: *Lua) void {
    const dir = getConfigDir() orelse return;
    const io = global_io orelse return;
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
        if (full_path.len < path_buf.len) {
            path_buf[full_path.len] = 0;
            const z_path: [:0]const u8 = path_buf[0..full_path.len :0];

            // Extract language name: syn_theme_<name>.lua → <name>
            const prefix_len = "syn_theme_".len;
            const suffix_len = ".lua".len;
            if (entry.name.len <= prefix_len + suffix_len) continue;
            const lang_name = entry.name[prefix_len .. entry.name.len - suffix_len];

            // Set a temporary global so zide.set("syn_*") routes to per-language override
            _ = lua.pushString(lang_name);
            lua.setField(zlua.registry_index, "_zide_syn_lang");

            lua.doFile(z_path) catch |err| {
                std.log.err("Error loading {s}: {}", .{ entry.name, err });
            };

            // Clear the temporary lang context
            lua.pushNil();
            lua.setField(zlua.registry_index, "_zide_syn_lang");

            std.log.info("Loaded syntax theme: {s}", .{entry.name});
        }
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
        \\
    ) catch {};
}
