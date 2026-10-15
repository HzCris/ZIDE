//! Lua extension runtime — the API surface extensions call beyond plain
//! configuration (lua_settings.zig owns set/get/bind and file loading).
//!
//! Single Lua state, main thread only: callbacks fire from the frontends'
//! main loops, and worker threads must never touch the state. Every
//! callback runs under protectedCall — a broken extension reports to the
//! status bar and the log; it can never crash the editor.
//!
//! Positions are 1-based lines and 1-based BYTE columns (not characters):
//! "é" occupies columns 1-2. Columns that land inside a UTF-8 sequence are
//! snapped back to the character's start, and text entering the buffer or
//! the status bar must be valid UTF-8 — the GUI measures and draws these
//! slices directly, and dvui panics on a split or malformed sequence.

const std = @import("std");
const zlua = @import("zlua");
const Editor = @import("editor.zig").Editor;
const Document = @import("document.zig").Document;
const Buffer = @import("buffer.zig").Buffer;
const cursor_mod = @import("cursor.zig");
const text_input = @import("text_input.zig");
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
    lua.pushFunction(&luaRegisterSnippet);
    lua.setField(-2, "register_snippet");
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
    setStatusText(editor, "Extension error: ", err_msg);
    lua.pop(1);
}

/// Show `prefix` + `text` in the status bar, copied into the editor's
/// status buffer by statusText (valid one-line UTF-8, cut on a code-point
/// boundary). `prefix` must be ASCII and `text` must not alias
/// `editor.status_buf`.
pub fn setStatusText(editor: *Editor, prefix: []const u8, text: []const u8) void {
    const buf = &editor.status_buf;
    const p = @min(prefix.len, buf.len);
    @memcpy(buf[0..p], prefix[0..p]);
    const body = statusText(buf[p..], text);
    editor.status_message = buf[0 .. p + body.len];
}

/// Copy `text` into `out` as one line of valid UTF-8 and return the filled
/// prefix of `out`: malformed bytes become U+FFFD, control characters
/// spaces, and the copy ends at the last whole code point that fits. The
/// GUI measures and draws status text directly; a split or malformed
/// sequence panics dvui.
pub fn statusText(out: []u8, text: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(text) and !hasControlByte(text)) {
        const n = text_input.floor(text, out.len);
        @memcpy(out[0..n], text[0..n]);
        return out[0..n];
    }
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        var step: usize = 1;
        var piece: []const u8 = &std.unicode.replacement_character_utf8;
        if (std.unicode.utf8ByteSequenceLength(text[i])) |seq_len| {
            if (seq_len <= text.len - i) {
                if (std.unicode.utf8Decode(text[i..][0..seq_len])) |cp| {
                    step = seq_len;
                    piece = if (cp < 0x20 or cp == 0x7f) " " else text[i..][0..seq_len];
                } else |_| {}
            }
        } else |_| {}
        if (piece.len > out.len - len) break;
        @memcpy(out[len..][0..piece.len], piece);
        len += piece.len;
        i += step;
    }
    return out[0..len];
}

fn hasControlByte(text: []const u8) bool {
    for (text) |b| if (b < 0x20 or b == 0x7f) return true;
    return false;
}

/// Owned copy of `text` with malformed UTF-8 replaced by U+FFFD (for Lua
/// strings the GUI draws later: diagnostic messages, command descriptions).
fn dupeUtf8(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(text)) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(text)});
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
    editor.commands.removeLuaCommands(editor.lua, struct {
        fn release(lua: ?*Lua, ref: i32) void {
            if (lua) |state| state.unref(zlua.registry_index, ref);
        }
    }.release);
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
/// Ends by detaching the editor from the state: main.zig's state outlives
/// the editor, and `__gc` finalizers run by lua.deinit() (or any callback
/// after this) must find no editor rather than a dangling pointer. Refs
/// released later in Editor.deinit (task matchers) are then skipped; the
/// state frees them when it closes.
pub fn deinitLua(editor: *Editor) void {
    cleanupLuaRefs(editor);
    inline for (comptime std.meta.tags(LuaEvent)) |ev| {
        editor.lua_event_handlers.getPtr(ev).deinit(editor.allocator);
    }
    editor.lua_jobs.deinit(editor.allocator);
    if (tree_reset_for) |target| if (target == editor) {
        tree_reset_for = null; // Editor.deinit frees the tree itself
    };
    if (editor.lua) |lua| lua_settings.detachEditor(lua, editor);
    editor.lua = null;
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
    editor.dropExtensionSnippets();
    editor.tasks.dropExtensions(editor);
    editor.dap.dropExtensions(editor);
    const failures = lua_settings.loadFailureCount();
    lua_settings.loadExtensions(lua);
    editor.reconcileLspClients();
    // Extensions may have (re)registered languages: re-detect every open
    // document so new extension→language mappings apply. In-place
    // re-registration keeps existing pointers valid, so documents whose
    // language is unchanged are left alone (no LSP close/open churn).
    for (editor.documents.items) |*doc| editor.relanguageDoc(doc);
    // A file that failed to load already put its error in the status bar
    // ("broken.lua:3: ..."); keep it there.
    if (lua_settings.loadFailureCount() == failures) editor.status_message = "Extensions reloaded";
}

// ---------------------------------------------------------------------------
// zide.* callback implementations
// ---------------------------------------------------------------------------

/// String field of the option table at stack index 1 (raw access: see
/// lua_settings.getFieldRaw). The slice stays valid while the table does.
fn snippetStringField(lua: *Lua, key: [:0]const u8) ?[]const u8 {
    _ = lua_settings.getFieldRaw(lua, 1, key);
    defer lua.pop(1);
    return if (lua.typeOf(-1) == .string) lua.toString(-1) catch null else null;
}

/// Optional string field of the option table: absent reads as "", and a
/// value of another type is refused (raw access, like snippetStringField).
fn snippetOptionalField(lua: *Lua, key: [:0]const u8) error{NotAString}![]const u8 {
    const kind = lua_settings.getFieldRaw(lua, 1, key);
    defer lua.pop(1);
    return switch (kind) {
        .nil, .none => "",
        .string => lua.toString(-1) catch "",
        else => error.NotAString,
    };
}

fn snippetError(lua: *Lua, message: []const u8) c_int {
    lua.pushNil();
    _ = lua.pushString(message);
    return 2;
}

fn luaRegisterSnippet(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    if (lua.typeOf(1) != .table) return snippetError(lua, "register_snippet expects a table");
    const language = snippetStringField(lua, "language") orelse return snippetError(lua, "Snippet language (string) is required");
    const body = snippetStringField(lua, "body") orelse return snippetError(lua, "Snippet body (string) is required");
    const prefix = snippetOptionalField(lua, "prefix") catch return snippetError(lua, "Snippet prefix must be a string");
    const description = snippetOptionalField(lua, "description") catch return snippetError(lua, "Snippet description must be a string");
    const group = snippetOptionalField(lua, "group") catch return snippetError(lua, "Snippet group must be a string");
    const notes = snippetOptionalField(lua, "notes") catch return snippetError(lua, "Snippet notes must be a string");
    const command = editor.registerSnippet(.{ .language = language, .body = body, .prefix = prefix, .description = description, .group = group, .notes = notes }) catch |err|
        return snippetError(lua, @import("snippets.zig").errorMessage(err));
    _ = lua.pushString(command);
    return 1;
}

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
    // The palette draws command names; the GUI can't draw malformed UTF-8.
    if (!std.unicode.utf8ValidateSlice(name)) {
        std.log.warn("zide.command: name must be valid UTF-8", .{});
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
    const owned_desc = dupeUtf8(a, desc) catch {
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
        _ = lua_settings.getFieldRaw(lua, 3, "language");
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

/// zide.status(msg) — show a transient message in the status bar. Long
/// messages are cut at a character boundary (the bar holds 128 bytes);
/// malformed UTF-8 shows as U+FFFD and control characters as spaces.
fn luaStatus(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const msg_z = lua.toString(1) catch return 0;
    // Copied: the Lua string is GC-owned and dies with the callback.
    setStatusText(editor, "", msg_z);
    return 0;
}

// ---------------------------------------------------------------------------
// Buffer API — all calls act on the active document. Lines and columns
// are 1-based on the Lua side; columns count BYTES (see the module doc).
// Mutations go through Document ops only, so undo history and LSP sync
// stay correct. Mutators return true, or nil plus a message.
// ---------------------------------------------------------------------------

/// `nil, message` for a buffer call that changed nothing.
fn editFailure(lua: *Lua, comptime api: []const u8, message: []const u8) c_int {
    std.log.warn(api ++ ": {s}", .{message});
    lua.pushNil();
    _ = lua.pushString(message);
    return 2;
}

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

/// zide.cursor() -> line, col (primary cursor; 1-based line and 1-based
/// byte column).
fn luaCursor(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const pos = editor.activeDoc().cursorPos();
    lua.pushInteger(@intCast(pos.line + 1));
    lua.pushInteger(@intCast(pos.col + 1));
    return 2;
}

/// zide.set_cursor(line, col) — move the primary cursor; drops secondary
/// cursors and any selection. 1-based line and byte column, clamped to the
/// document and the line end; a column inside a multi-byte character lands
/// at that character's start.
fn luaSetCursor(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const doc = editor.activeDoc();
    const line_arg = lua.toInteger(1) catch return 0;
    const col_arg = lua.toInteger(2) catch 1;

    const line: usize = @intCast(std.math.clamp(line_arg, 1, @as(i64, @intCast(doc.lineCount()))) - 1);
    const col: usize = if (col_arg < 1) 0 else std.math.cast(usize, col_arg - 1) orelse std.math.maxInt(usize);
    const offset = cursor_mod.lineOffset(&doc.buffer, line, col);

    doc.cursors.clearSecondary();
    const c = doc.cursors.primary();
    c.clearSelection();
    c.offset = offset;
    c.preferred_col = offset - doc.buffer.line_starts.items[line];
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

/// zide.insert(text) -> true | nil, err — insert at the primary cursor; an
/// active selection is replaced (single undo step). This is also the
/// "replace selection". Text that isn't valid UTF-8 is refused.
fn luaInsert(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const text: []const u8 = lua.toString(1) catch return editFailure(lua, "zide.insert", "text (string) required");
    if (!std.unicode.utf8ValidateSlice(text)) return editFailure(lua, "zide.insert", "invalid UTF-8");
    const doc = editor.activeDoc();
    // Carets only sit between characters; snap one that arrived inside a
    // sequence so the insert can't split it.
    const c = doc.cursors.primary();
    c.offset = cursor_mod.floorBoundary(&doc.buffer, c.offset);
    if (c.anchor) |a| c.anchor = cursor_mod.floorBoundary(&doc.buffer, a);
    doc.insertAtCursor(text) catch |err| return editFailure(lua, "zide.insert", @errorName(err));
    lua.pushBoolean(true);
    return 1;
}

/// zide.set_line(n, text) -> true | nil, err — replace line n's content
/// (one undo step). Every caret and selection end on that line keeps its
/// byte column (clamped to the new line, snapped to a character start);
/// secondary cursors stay. Out-of-range lines and text that isn't valid
/// UTF-8 change nothing.
fn luaSetLine(state: ?*zlua.LuaState) callconv(.c) c_int {
    var lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;
    const doc = editor.activeDoc();
    const n = lua.toInteger(1) catch return editFailure(lua, "zide.set_line", "line number (integer) required");
    const text: []const u8 = lua.toString(2) catch return editFailure(lua, "zide.set_line", "text (string) required");
    if (n < 1 or n > doc.lineCount()) return editFailure(lua, "zide.set_line", "line out of range");
    if (!std.unicode.utf8ValidateSlice(text)) return editFailure(lua, "zide.set_line", "invalid UTF-8");
    const line: usize = @intCast(n - 1);
    const start = doc.buffer.line_starts.items[line];
    const old_len = doc.lineContent(line).len;

    // Byte column of every caret / anchor on the line, restored after the
    // edit (Document.commit moves carets at the replaced range to its end).
    const Saved = struct { offset: ?usize, anchor: ?usize };
    const saved = editor.allocator.alloc(Saved, doc.cursors.count()) catch return editFailure(lua, "zide.set_line", "OutOfMemory");
    defer editor.allocator.free(saved);
    for (doc.cursors.cursors.items, saved) |c, *s| s.* = .{
        .offset = columnOnLine(c.offset, start, old_len),
        .anchor = if (c.anchor) |a| columnOnLine(a, start, old_len) else null,
    };

    // One explicit edit so the undo entry records the restored carets.
    doc.beginEdit() catch |err| return editFailure(lua, "zide.set_line", @errorName(err));
    defer doc.endEdit();
    doc.applyRanges(&.{.{ .start = start, .end = start + old_len, .text = text }}) catch |err| return editFailure(lua, "zide.set_line", @errorName(err));
    const kept = @min(doc.cursors.cursors.items.len, saved.len); // the edit adds or drops no cursor
    for (doc.cursors.cursors.items[0..kept], saved[0..kept]) |*c, s| {
        if (s.offset) |col| {
            c.offset = cursor_mod.lineOffset(&doc.buffer, line, col);
            c.preferred_col = c.offset - start;
        }
        if (s.anchor) |col| c.anchor = cursor_mod.lineOffset(&doc.buffer, line, col);
    }
    doc.cursors.mergeCursors();
    lua.pushBoolean(true);
    return 1;
}

/// Column of `offset` on the line spanning [start, start + len] (its end
/// included: a caret at the line end), or null when it lies elsewhere.
fn columnOnLine(offset: usize, start: usize, len: usize) ?usize {
    return if (offset >= start and offset <= start + len) offset - start else null;
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

/// Editor whose file tree is rebuilt at its next pumpLuaJobs (a runtime
/// zide.set("filetree_root"); see deferTreeReset). Main thread only.
var tree_reset_for: ?*Editor = null;

/// Drop `editor`'s file tree at the next main-loop pump instead of now.
/// zide.set can run inside a frontend's tree handler (an "open" hook fired
/// by a tree click), which keeps using the tree after the hook returns;
/// both frontends pump after input handling and before drawing.
pub fn deferTreeReset(editor: *Editor) void {
    tree_reset_for = editor;
}

fn applyTreeReset(editor: *Editor) void {
    const target = tree_reset_for orelse return;
    if (target != editor) return;
    tree_reset_for = null;
    if (editor.filetree) |*ft| {
        ft.deinit();
        editor.filetree = null; // recreated from filetree_root on next use
    }
}

pub fn pumpLuaJobs(editor: *Editor) void {
    applyTreeReset(editor);
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

/// Longest zide.run timeout: 2^40 ms (~35 years). Far inside the i96
/// nanosecond range of Io timestamps, so the deadline math can't overflow.
const max_run_timeout_ms: i64 = 1 << 40;

/// zide.run's timeout argument in milliseconds, or null for no deadline
/// (absent, nil or not a number). Clamped to [0, max_run_timeout_ms]; a
/// fractional value is floored (2.5 → 2 ms) and NaN counts as 0.
fn runTimeoutMs(lua: *Lua, index: i32) ?i64 {
    if (lua.typeOf(index) != .number) return null;
    if (lua.isInteger(index)) {
        const ms = lua.toInteger(index) catch return null;
        return std.math.clamp(ms, 0, max_run_timeout_ms);
    }
    const f = lua.toNumber(index) catch return null;
    if (!(f > 0)) return 0; // negative, zero or NaN
    if (f >= @as(f64, @floatFromInt(max_run_timeout_ms))) return max_run_timeout_ms;
    return @intFromFloat(@floor(f));
}

/// `nil, message` from zide.run.
fn runFailure(lua: *Lua, message: []const u8) c_int {
    lua.pushNil();
    _ = lua.pushString(message);
    return 2;
}

/// zide.run(argv [, timeout_ms]) -> table | nil, err — run a tool and
/// block until it exits (UI freezes meanwhile: fast tools only; use
/// zide.spawn for anything slow).
///
/// Runs through the job manager like zide.spawn: the tool and everything
/// it starts share one process group (a job object on Windows), and the
/// timeout is a total deadline. When it passes the whole group is killed
/// and `nil, "Timeout"` returns — a tool that keeps printing (ping -t, a
/// watcher) can't hold the UI past it. Output beyond the cap (4 MiB +
/// 256 KiB, stdout and stderr together) is dropped; the tool runs on.
fn luaRun(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(@alignCast(state orelse return 0));
    const editor = lua_settings.getEditor(state) orelse return 0;

    const argv = readArgvAlloc(lua, editor.allocator, 1) orelse return runFailure(lua, "zide.run: argv table of strings required");
    defer freeArgv(editor.allocator, argv);
    const timeout_ms = runTimeoutMs(lua, 2);

    const id = editor.jobs.start(.{
        .argv = argv,
        .output_limit = spawn_stdout_limit + spawn_stderr_limit,
        .strict_output = false,
    }) catch |err| return runFailure(lua, @errorName(err));
    defer editor.jobs.remove(id);
    const job = editor.jobs.get(id) orelse return runFailure(lua, "JobVanished");

    // A total deadline (what Io.Timeout.toDeadline computes), checked
    // between polls; std.process.run's timeout restarted on every read.
    const deadline: ?std.Io.Clock.Timestamp = if (timeout_ms) |ms|
        .fromNow(editor.io, .{ .raw = .fromMilliseconds(ms), .clock = .awake })
    else
        null;
    // Poll with a short backoff: fast tools return within a millisecond or
    // two of exiting; long ones cost ~100 wakeups a second.
    var nap_ms: i64 = 1;
    while (!job.isDone()) {
        if (deadline) |d| {
            if (std.Io.Clock.Timestamp.now(editor.io, .awake).compare(.gte, d)) {
                editor.jobs.cancel(id); // kills the process group; returns once the worker finished
                break;
            }
        }
        editor.io.sleep(.fromMilliseconds(nap_ms), .awake) catch {
            editor.jobs.cancel(id);
            break;
        };
        nap_ms = @min(nap_ms * 2, 10);
    }

    const result = job.snapshot(editor.allocator, true) catch |err| return runFailure(lua, @errorName(err));
    defer result.deinit(editor.allocator);
    // `cancelled` is only set when the cancel beat the tool's exit.
    if (result.cancelled) return runFailure(lua, "Timeout");
    if (result.failure) |err| if (err != error.AbnormalExit) return runFailure(lua, @errorName(err));
    pushRunResult(lua, if (result.code) |code| @as(i64, code) else null, result.stdout, result.stderr, if (result.failure) |err| @errorName(err) else null);
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

/// Integer field of the diagnostic table at the top of the stack (raw
/// access: see lua_settings.getFieldRaw). Floats with no integer value
/// read as absent.
fn diagFieldInt(lua: *Lua, field: [:0]const u8) ?i64 {
    _ = lua_settings.getFieldRaw(lua, -1, field);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .number) return null;
    return lua.toInteger(-1) catch null;
}

/// String field of the diagnostic table at the top of the stack (raw
/// access). The slice stays valid while the table does.
fn diagFieldString(lua: *Lua, field: [:0]const u8) ?[:0]const u8 {
    _ = lua_settings.getFieldRaw(lua, -1, field);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .string) return null;
    return lua.toString(-1) catch null;
}

/// diagnostics.Store.replace refuses more per call; later entries are
/// dropped (with a warning) instead of losing the whole list.
const max_lint_diagnostics = 10_000;

/// A 1-based column from Lua as a 1-based u32 (garbled linter numbers
/// saturate instead of overflowing; snapping then clamps to the line).
fn clampColumn(col: i64) u32 {
    return @intCast(std.math.clamp(col, 1, std.math.maxInt(u32)));
}

/// 0-based byte span of one diagnostic on `line`. With the document open,
/// both ends are snapped to character starts within the line — the GUI
/// slices the line text at these columns — and a missing end covers the
/// character at `start` (one byte used to split "é", CJK and emoji).
/// Otherwise the columns are kept (the GUI clamps them when the file opens).
fn diagnosticSpan(doc: ?*const Document, line: u32, start: u32, end: ?u32) struct { start: u32, end: u32 } {
    const d = doc orelse return .{ .start = start, .end = @max(end orelse start +| 1, start) };
    if (line >= d.buffer.lineCount()) return .{ .start = start, .end = @max(end orelse start +| 1, start) };
    const buf: *const Buffer = &d.buffer;
    const line_start = buf.line_starts.items[line];
    const line_end = cursor_mod.lineOffset(buf, line, std.math.maxInt(usize));
    const s = cursor_mod.lineOffset(buf, line, start);
    const e = if (end) |col|
        @max(cursor_mod.lineOffset(buf, line, col), s)
    else if (s < line_end)
        @min(cursor_mod.nextBoundary(buf, s), line_end)
    else
        s;
    return .{ .start = std.math.lossyCast(u32, s - line_start), .end = std.math.lossyCast(u32, e - line_start) };
}

/// The open document for `path` (separator/case-insensitive match), if any.
fn openDocument(editor: *Editor, path: []const u8) ?*Document {
    for (editor.documents.items) |*doc| {
        if (doc.file_path) |p| if (editor.pathsEqual(p, path)) return doc;
    }
    return null;
}

fn severityFromName(name: []const u8) lsp_mod.DiagnosticSeverity {
    if (std.mem.eql(u8, name, "warning")) return .warning;
    if (std.mem.eql(u8, name, "info")) return .information;
    if (std.mem.eql(u8, name, "hint")) return .hint;
    return .err; // "error" and anything else — linters mostly report errors
}

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

/// zide.set_diagnostics(path, {{line, col, end_col, severity, message}, …})
/// Replaces the extension diagnostics of the open document at `path`
/// (severity: "error"/"warning"/"info"/"hint", default "error"). Pass an
/// empty table to clear. Findings for paths that aren't open are kept for
/// when they open. Positions go stale as the user edits — same as LSP, the
/// next lint run replaces them.
///
/// `line` is 1-based; `col`/`end_col` are 1-based BYTE columns (default
/// col 1; default end: one character past col). A line that isn't a
/// positive 32-bit number drops that entry; huge columns saturate, and
/// columns are snapped to character starts of the open document's line.
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
    const source: []const u8 = blk: {
        const s: []const u8 = lua.toString(3) catch break :blk "lint";
        break :blk if (std.unicode.utf8ValidateSlice(s)) s else "lint";
    };
    const target = openDocument(editor, path_z);
    var diagnostics: std.ArrayList(lsp_mod.Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |diagnostic| diagnostic.deinit(editor.allocator);
        diagnostics.deinit(editor.allocator);
    }
    const len = lua.lenRaw(2);
    if (len > max_lint_diagnostics) std.log.warn("zide.set_diagnostics: {d} entries; keeping the first {d}", .{ len, max_lint_diagnostics });
    var i: usize = 1;
    while (i <= @min(len, max_lint_diagnostics)) : (i += 1) {
        _ = lua.getIndexRaw(2, @intCast(i));
        defer lua.pop(1);
        if (lua.typeOf(-1) != .table) continue;

        const line = std.math.cast(u32, diagFieldInt(lua, "line") orelse continue) orelse continue;
        if (line < 1) continue;
        const col = clampColumn(diagFieldInt(lua, "col") orelse 1);
        const end_col: ?u32 = if (diagFieldInt(lua, "end_col")) |e| clampColumn(e) else null;
        const severity = severityFromName(diagFieldString(lua, "severity") orelse "error");
        const message = diagFieldString(lua, "message") orelse "";
        const span = diagnosticSpan(target, line - 1, col - 1, if (end_col) |e| e - 1 else null);

        const owned_msg = dupeUtf8(editor.allocator, message) catch continue;
        diagnostics.append(editor.allocator, .{
            .start_line = line - 1,
            .start_col = span.start,
            .end_line = line - 1,
            .end_col = span.end,
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

test "Lua reload restores overridden built-ins and keeps palette names unique" {
    const old_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_level;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);
    const count = editor.commands.count();
    for (0..3) |_| {
        try editor.activeDoc().insertAtCursor("text");
        try lua.doString("zide.command('undo', '', function() zide.status('first') end)");
        try lua.doString("zide.command('undo', '', function() zide.status('second') end)");
        _ = editor.execCommand("undo", null);
        try testing.expectEqualStrings("second", editor.status_message);
        try testing.expectEqual(count, editor.commands.count());
        var found: usize = 0;
        for (try editor.commands.allNames()) |name| if (std.mem.eql(u8, name, "undo")) {
            found += 1;
        };
        try testing.expectEqual(@as(usize, 1), found);
        reloadExtensions(&editor);
        try testing.expect(editor.commands.get("undo").?.lua_ref == null);
        _ = editor.execCommand("undo", null);
        try testing.expectEqualStrings("", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
        try testing.expectEqual(count, (try editor.commands.allNames()).len);
    }
}

test "Lua overrides reveal updated snippets and cannot resurrect removed snippets" {
    const old_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_level;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);
    try lua.doString("assert(zide.register_snippet{language='*', prefix='demo', body='old'})");
    try lua.doString("zide.command('snippet.*.demo', '', function() end)");
    try lua.doString("assert(zide.register_snippet{language='*', prefix='demo', body='new'})");
    _ = try editor.commands.allNames();
    cleanupLuaRefs(&editor);
    try testing.expect(editor.commands.get("snippet.*.demo").?.snippet);
    _ = editor.execCommand("snippet.*.demo", null);
    try testing.expectEqualStrings("new", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
    editor.loading_extensions = true;
    try lua.doString("assert(zide.register_snippet{language='*', prefix='demo', body='extension'})");
    editor.loading_extensions = false;
    try lua.doString("zide.command('snippet.*.demo', '', function() end)");
    editor.dropExtensionSnippets();
    try testing.expect(editor.commands.get("snippet.*.demo").?.lua_ref != null);
    cleanupLuaRefs(&editor);
    try testing.expect(editor.commands.get("snippet.*.demo") == null);
    for (try editor.commands.allNames()) |name| try testing.expect(!std.mem.eql(u8, name, "snippet.*.demo"));
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
        \\zide.set_cursor(math.mininteger, math.mininteger) -- clamps without i64 overflow
        \\l, c = zide.cursor()
        \\assert(l == 1 and c == 1)
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

test "buffer API: byte columns inside a character snap to its start" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.loadText("\u{e9}a\n\u{1F600}z");
    // Column 2 is the second byte of "é": the caret lands before "é".
    try lua.doString(
        \\zide.set_cursor(1, 2)
        \\local l, c = zide.cursor()
        \\assert(l == 1 and c == 1, l .. ':' .. c)
        \\zide.set_cursor(1, 3) -- "a" starts at byte 3
        \\l, c = zide.cursor()
        \\assert(c == 3)
        \\zide.set_cursor(2, 4) -- inside the 4-byte emoji
        \\l, c = zide.cursor()
        \\assert(l == 2 and c == 1)
    );
    try testing.expectEqual(@as(usize, 4), doc.cursors.primary().offset);
    // Inserting there keeps the text valid (it used to split the emoji).
    try lua.doString("assert(zide.insert('x') == true)");
    try testing.expectEqualStrings("\u{e9}a\nx\u{1F600}z", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "buffer API: insert and set_line refuse invalid UTF-8" {
    testing.log_level = .err; // the refusals warn
    defer testing.log_level = .warn;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.loadText("keep");
    try lua.doString(
        \\local ok, err = zide.insert('\xC3\x28')
        \\assert(ok == nil and err == 'invalid UTF-8', tostring(err))
        \\ok, err = zide.set_line(1, 'bad\xFF')
        \\assert(ok == nil and err == 'invalid UTF-8', tostring(err))
        \\ok, err = zide.set_line(9, 'x')
        \\assert(ok == nil and err == 'line out of range', tostring(err))
        \\assert(zide.set_line(1, 'kept \u{E9}') == true)
    );
    try testing.expectEqualStrings("kept \u{e9}", doc.buffer.slice(0, doc.buffer.byteLen()));
    _ = try doc.undoAction();
    try testing.expectEqualStrings("keep", doc.buffer.slice(0, doc.buffer.byteLen()));
    try testing.expect(!try doc.undoAction()); // the refused calls left no history
}

test "buffer API: set_line keeps caret columns and secondary cursors" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.loadText("- [ ] task one\nsecond line");
    doc.cursors.primary().offset = 3; // inside the checkbox
    try doc.cursors.addCursor(20); // on line 2
    // The shipped markdown.lua toggle_checkbox body, verbatim.
    try lua.doString(
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
        \\    zide.status("No checkbox on this line")
        \\  end
        \\end)
    );
    try testing.expect(editor.execCommand("toggle_checkbox", null));
    try testing.expectEqualStrings("- [x] task one\nsecond line", doc.buffer.slice(0, doc.buffer.byteLen()));
    try testing.expectEqual(@as(usize, 3), doc.cursors.primary().offset);
    try testing.expectEqual(@as(usize, 2), doc.cursors.count());
    try testing.expectEqual(@as(usize, 20), doc.cursors.cursors.items[1].offset);

    // A shorter line clamps the caret to its end, a line with the caret in
    // a multi-byte character snaps it to that character's start, and later
    // lines shift with the edit.
    doc.cursors.primary().offset = 10;
    try lua.doString("assert(zide.set_line(1, 'ab') == true)");
    try testing.expectEqualStrings("ab\nsecond line", doc.buffer.slice(0, doc.buffer.byteLen()));
    try testing.expectEqual(@as(usize, 2), doc.cursors.primary().offset);
    try testing.expectEqual(@as(usize, 8), doc.cursors.cursors.items[1].offset);
    doc.cursors.primary().offset = 2;
    try lua.doString("assert(zide.set_line(1, '\u{E9}\u{E9}') == true)");
    try testing.expectEqual(@as(usize, 2), doc.cursors.primary().offset);
    try lua.doString("zide.set_line(1, 'x\u{E9}')"); // byte 2 is inside the new "é"
    try testing.expectEqual(@as(usize, 1), doc.cursors.primary().offset);
    // Undo restores the text and the caret the edit started from.
    _ = try doc.undoAction();
    try testing.expectEqualStrings("\u{e9}\u{e9}\nsecond line", doc.buffer.slice(0, doc.buffer.byteLen()));
    try testing.expectEqual(@as(usize, 2), doc.cursors.primary().offset);
}

test "zide.status and extension errors are cut on a character boundary" {
    testing.log_level = .err; // the reported Lua error warns
    defer testing.log_level = .warn;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    // 201 bytes: the 128-byte bar would end mid-"é" at 128; it stops at 127.
    try lua.doString("zide.status('a' .. string.rep('\u{E9}', 100))");
    try testing.expectEqual(@as(usize, 127), editor.status_message.len);
    try testing.expect(std.unicode.utf8ValidateSlice(editor.status_message));
    // Malformed bytes show as U+FFFD, control characters as spaces.
    try lua.doString("zide.status('bad\\xFF\\nline')");
    try testing.expectEqualStrings("bad\u{FFFD} line", editor.status_message);
    try lua.doString("zide.command('boom', '', function() error(string.rep('\u{1F600}', 60)) end)");
    try testing.expect(editor.execCommand("boom", null));
    try testing.expect(std.mem.startsWith(u8, editor.status_message, "Extension error: "));
    try testing.expect(std.unicode.utf8ValidateSlice(editor.status_message));
    try testing.expect(editor.status_message.len <= editor.status_buf.len);
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

/// Milliseconds on the awake clock, for timing zide.run.
fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.awake, testing.io).nanoseconds, std.time.ns_per_ms));
}

test "zide.run timeout is a total deadline, even for a tool that keeps printing" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    // Output never pauses, so the old per-read timeout never fired (and on
    // Windows the loop would run for minutes). The whole group is killed.
    try lua.doString(if (@import("builtin").os.tag == .windows)
        \\ticker = { 'cmd', '/c', 'for /L %i in (1,1,100000000) do @echo tick' }
    else
        \\ticker = { 'sh', '-c', 'while :; do echo tick; sleep 0.2; done' }
    );
    const t0 = nowMs();
    try lua.doString(
        \\local r, err = zide.run(ticker, 1000)
        \\assert(r == nil and err == 'Timeout', tostring(err))
    );
    const elapsed = nowMs() - t0;
    try testing.expect(elapsed >= 1000);
    try testing.expect(elapsed < 4000); // generous for a loaded machine
    try testing.expectEqual(@as(usize, 0), editor.jobs.jobs.items.len);
}

test "zide.run clamps huge, negative and fractional timeouts" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    try lua.doString(if (@import("builtin").os.tag == .windows)
        \\quick = { 'cmd', '/c', 'echo quick' }
        \\slow = { 'ping', '-n', '3', '127.0.0.1' }
    else
        \\quick = { 'sh', '-c', 'echo quick' }
        \\slow = { 'sh', '-c', 'sleep 2' }
    );
    try lua.doString(
        \\-- math.maxinteger used to panic inside std; now it's ~35 years.
        \\local r, err = zide.run(quick, math.maxinteger)
        \\assert(r and r.code == 0 and r.stdout:find('quick'), tostring(err))
        \\r, err = zide.run(quick, math.huge)
        \\assert(r and r.code == 0, tostring(err))
        \\-- Negative clamps to 0: the deadline has passed before the tool ends.
        \\r, err = zide.run(slow, -5)
        \\assert(r == nil and err == 'Timeout', tostring(err))
        \\-- 2.5 is floored to 2 ms (it used to mean "no timeout").
        \\r, err = zide.run(slow, 2.5)
        \\assert(r == nil and err == 'Timeout', tostring(err))
        \\-- nil and non-numbers mean no deadline.
        \\r, err = zide.run(quick, nil)
        \\assert(r and r.code == 0, tostring(err))
    );
    try testing.expectEqual(@as(usize, 0), editor.jobs.jobs.items.len);
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

test "zide.set_diagnostics snaps columns to character starts" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.loadText("\u{e9}lan \u{1F600}!\r\n\u{754C}");
    try doc.setFilePath("C:/fake/utf8_lint.zig");
    try lua.doString(
        \\zide.set_diagnostics('C:/fake/utf8_lint.zig', {
        \\  { line = 1, message = 'default end covers the whole é' },
        \\  { line = 1, col = 2, end_col = 9, message = 'both ends inside characters' },
        \\  { line = 1, col = 99, message = 'past the end of a CRLF line' },
        \\  { line = 2, col = 2, message = 'inside a CJK character' },
        \\  { line = 7, col = 3, message = 'no such line: kept as given' },
        \\})
    );
    const d = doc.lint_diagnostics.items;
    try testing.expectEqual(@as(usize, 5), d.len);
    const expected = [_][2]u32{ .{ 0, 2 }, .{ 0, 6 }, .{ 11, 11 }, .{ 0, 3 }, .{ 2, 3 } };
    for (d, expected) |diag, want| {
        try testing.expectEqual(want[0], diag.start_col);
        try testing.expectEqual(want[1], diag.end_col);
    }
    // Every snapped end is a character boundary of its line.
    for (d[0..4]) |diag| {
        const text = doc.lineContent(diag.start_line);
        for ([_]u32{ diag.start_col, diag.end_col }) |col| {
            try testing.expect(col <= text.len);
            if (col < text.len) try testing.expect(text[col] & 0xC0 != 0x80);
        }
    }
}

test "zide.set_diagnostics survives out-of-range numbers" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    const doc = editor.activeDoc();
    try doc.loadText("short\n");
    try doc.setFilePath("C:/fake/huge_numbers.zig");
    // These used to panic: @intCast of 5e9 to u32, and col + 1 overflowing.
    try lua.doString(
        \\zide.set_diagnostics('C:/fake/huge_numbers.zig', {
        \\  { line = 5000000000, message = 'dropped: no 32-bit line' },
        \\  { line = math.mininteger, message = 'dropped' },
        \\  { line = 1, col = math.maxinteger, message = 'kept at the line end' },
        \\  { line = 1, col = math.mininteger, end_col = math.maxinteger, message = 'whole line' },
        \\  { line = 1, col = 2.5, message = 'non-integer col reads as absent' },
        \\})
    );
    const d = doc.lint_diagnostics.items;
    try testing.expectEqual(@as(usize, 3), d.len);
    try testing.expectEqual(@as(u32, 5), d[0].start_col);
    try testing.expectEqual(@as(u32, 5), d[0].end_col);
    try testing.expectEqual(@as(u32, 0), d[1].start_col);
    try testing.expectEqual(@as(u32, 5), d[1].end_col);
    try testing.expectEqual(@as(u32, 0), d[2].start_col);
    // A file that isn't open keeps saturated columns without overflow.
    try lua.doString("zide.set_diagnostics('C:/fake/not_open.zig', { { line = 1, col = math.maxinteger, message = 'x' } })");
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

test "reload_extensions: a broken file reaches the status bar and the Lua stack stays level" {
    testing.log_level = .err; // the load error warns
    defer testing.log_level = .warn;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "extensions");
    for ([_][2][]const u8{
        .{ "extensions/broken.lua", "zide.command('x', '', function() end\n" },
        // Chunk results used to stay on the host stack with every load.
        .{ "extensions/module.lua", "zide.command('from_module', '', function() end)\nreturn {}, 'extra'\n" },
    }) |file| {
        const f = try tmp.dir.createFile(testing.io, file[0], .{});
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, file[1]);
    }
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    lua_settings.test_config_dir = root;
    defer lua_settings.test_config_dir = null;

    const top = lua.getTop();
    for (0..2) |_| {
        reloadExtensions(&editor);
        try testing.expectEqual(top, lua.getTop());
        // "broken.lua:2: ')' expected near <eof>" (the directory is dropped)
        try testing.expect(std.mem.startsWith(u8, editor.status_message, "broken.lua:"));
        try testing.expect(std.mem.indexOf(u8, editor.status_message, "expected") != null);
        try testing.expect(editor.commands.get("from_module") != null);
    }
    // Once the file is fixed the reload reports success again.
    {
        const f = try tmp.dir.createFile(testing.io, "extensions/broken.lua", .{});
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, "zide.command('x', '', function() end)\n");
    }
    reloadExtensions(&editor);
    try testing.expectEqualStrings("Extensions reloaded", editor.status_message);
    try testing.expect(editor.commands.get("x") != null);
    try testing.expectEqual(top, lua.getTop());
}

test "zide.* calls after the editor is gone are no-ops (finalizers run by lua.deinit)" {
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit(); // runs `late`'s finalizer with no editor: must not crash
    lua.openLibs();
    {
        var editor = try Editor.init(testing.allocator, testing.io);
        defer editor.deinit();
        lua_settings.registerApi(lua, &editor);
        try lua.doString(
            \\probe = setmetatable({}, { __gc = function()
            \\  gc_saw = (zide.get_text() == nil) and 'no editor' or 'editor'
            \\  zide.status('bye'); zide.set_line(1, 'x'); zide.insert('y')
            \\end })
            \\late = setmetatable({}, { __gc = function() zide.status(zide.get_text() or 'none') end })
        );
    }
    try testing.expect(lua_settings.getEditor(@ptrCast(lua)) == null);
    try lua.doString("probe = nil; collectgarbage(); collectgarbage()");
    _ = lua.getGlobal("gc_saw");
    defer lua.pop(1);
    try testing.expectEqualStrings("no editor", try lua.toString(-1));
}

test "option tables are read raw: a raising __index can't unwind through Zig" {
    testing.log_level = .err;
    defer testing.log_level = .warn;
    var lua = try Lua.init(testing.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);
    const doc = editor.activeDoc();
    try doc.loadText("one\n");
    try doc.setFilePath("C:/fake/raw_access.zig");

    // Every field these APIs read is absent from the table itself, so a
    // non-raw read would call the raising __index — outside any pcall of
    // ours, i.e. a longjmp past the arena/list the reader owns (leaked).
    try lua.doString(
        \\local mt = { __index = function(_, k) error('boom: ' .. tostring(k)) end }
        \\local function hostile(t) return setmetatable(t, mt) end
        \\assert(pcall(zide.register_language, hostile({ name = 'leaky' })))
        \\assert(pcall(zide.register_lsp, hostile({ language = 'leaky', command = 'srv' })))
        \\assert(pcall(zide.set_language, 'leaky', hostile({ tab_width = 3 })))
        \\assert(pcall(zide.set_diagnostics, 'C:/fake/raw_access.zig', { hostile({ line = 1 }) }))
        \\assert(pcall(zide.on, 'save', function() end, hostile({})))
        \\assert(pcall(zide.bind, 'ctrl+alt+k', 'x', hostile({})))
        \\assert(pcall(zide.register_snippet, hostile({ language = '*', prefix = 'rw', body = 'b' })))
    );
    try testing.expect(editor.findLanguageByName("leaky") != null);
    try testing.expect(editor.lspConfigFor("leaky") != null);
    try testing.expectEqual(@as(usize, 1), doc.lint_diagnostics.items.len);
    try testing.expect(editor.commands.get("snippet.*.rw") != null);
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
