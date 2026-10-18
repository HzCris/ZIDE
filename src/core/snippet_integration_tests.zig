const std = @import("std");
const t = std.testing;
const Editor = @import("editor.zig").Editor;
const lua_settings = @import("lua_settings.zig");
const lua_api = @import("lua_api.zig");
const snippets = @import("snippets.zig");
const snippet_file = @import("snippet_file.zig");
const Lua = @import("zlua").Lua;

test "snippets integration: bundled Lua definitions reload and installation preserves customization" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try lua_settings.ensureSnippetExtension(tmp.dir, t.io);
    const installed = try tmp.dir.readFileAlloc(t.io, "snippets-zig.lua", t.allocator, .limited(64 * 1024));
    defer t.allocator.free(installed);
    try t.expectEqualStrings(lua_settings.zig_snippets, installed);
    {
        const file = try tmp.dir.createFile(t.io, "snippets-zig.lua", .{});
        defer file.close(t.io);
        try file.writeStreamingAll(t.io, "-- customized\n");
    }
    try lua_settings.ensureSnippetExtension(tmp.dir, t.io);
    const customized = try tmp.dir.readFileAlloc(t.io, "snippets-zig.lua", t.allocator, .limited(100));
    defer t.allocator.free(customized);
    try t.expectEqualStrings("-- customized\n", customized);

    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);
    try lua.doString("assert(zide.register_snippet{language='*', prefix='personal', body='kept'})");
    for (0..2) |_| {
        editor.loading_extensions = true;
        try lua.doString(lua_settings.zig_snippets);
        editor.loading_extensions = false;
        try t.expect(editor.snippets.items.items.len > 10);
        editor.activeDoc().language = editor.findLanguage("zig");
        try editor.activeDoc().loadText("fn");
        editor.activeDoc().cursors.primary().moveToEnd(&editor.activeDoc().buffer);
        try t.expect(editor.handleSnippetKey(.tab));
        try t.expectEqualStrings("name", editor.activeDoc().selectedText().?);
        lua_api.reloadExtensions(&editor);
        try t.expect(editor.activeDoc().snippet_session == null);
        try t.expectEqual(@as(usize, 1), editor.snippets.items.items.len);
        try t.expect(editor.commands.get("snippet.zig.fn") == null);
        try t.expect(editor.commands.get("snippet.*.personal") != null);
    }
    try lua.doString("local command, err = zide.register_snippet{language='zig', prefix='bad', body='${1:a} $1'}; assert(command == nil and type(err) == 'string')");
}

test "snippets integration: a pristine older bundled file is upgraded, an edited one is kept" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // "v0" with CRLF endings, as a checkout on Windows might have left it.
    const old = "-- old bundled set\r\nreturn 1\r\n";
    const old_hashes = [_]u64{lua_settings.snippetFileHash("-- old bundled set\nreturn 1\n")};
    try tmp.dir.writeFile(t.io, .{ .sub_path = "snippets-zig.lua", .data = old });
    try lua_settings.ensureSnippetExtensionWith(tmp.dir, t.io, &old_hashes);
    const upgraded = try tmp.dir.readFileAlloc(t.io, "snippets-zig.lua", t.allocator, .limited(64 * 1024));
    defer t.allocator.free(upgraded);
    try t.expectEqualStrings(lua_settings.zig_snippets, upgraded);
    // The current file is left alone, and so is anything unrecognised.
    try lua_settings.ensureSnippetExtensionWith(tmp.dir, t.io, &old_hashes);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "snippets-zig.lua", .data = "-- mine\n" });
    try lua_settings.ensureSnippetExtensionWith(tmp.dir, t.io, &old_hashes);
    const mine = try tmp.dir.readFileAlloc(t.io, "snippets-zig.lua", t.allocator, .limited(100));
    defer t.allocator.free(mine);
    try t.expectEqualStrings("-- mine\n", mine);
}

test "snippets integration: the bundled Zig set has 40+ skeletons, each filed in a named group with notes" {
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);
    editor.loading_extensions = true;
    try lua.doString(lua_settings.zig_snippets);
    editor.loading_extensions = false;
    try t.expect(editor.snippets.items.items.len >= 40);
    for (editor.snippets.items.items) |def| {
        try t.expectEqualStrings("zig", def.language);
        try t.expect(def.from_extension);
        try t.expect(!std.mem.eql(u8, def.group, snippets.default_group));
        try t.expect(def.notes.len > 0);
        try t.expect(def.description.len > 0 and !std.mem.eql(u8, def.description, def.prefix));
    }
    try t.expect(editor.commands.get("snippet.zig.fn") != null);
}

test "my-snippets.lua: a rendered block loads in Lua and registers the same snippet" {
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);
    const body = "const s = \"q\\\"]]\";\n\tvar list = a[b[i]];\n$0";
    const spec: snippets.Spec = .{ .language = "zig", .description = "Tricky \"one\"", .group = "Mine", .prefix = "trk", .notes = "line one\nline two", .body = body };
    const block = try snippet_file.renderBlock(t.allocator, "snippet.zig.trk", spec);
    defer t.allocator.free(block);
    const blockz = try t.allocator.dupeZ(u8, block);
    defer t.allocator.free(blockz);
    try lua.doString(blockz);
    const def = editor.snippets.command("snippet.zig.trk").?;
    try t.expectEqualStrings("Tricky \"one\"", def.description);
    try t.expectEqualStrings("Mine", def.group);
    try t.expectEqualStrings("trk", def.prefix);
    try t.expectEqualStrings("line one\nline two", def.notes);
    try t.expectEqualStrings(body, def.body);
    try t.expectEqualStrings("", def.source); // registered at runtime, not by a file
    // The block round-trips through the file API too.
    const file = try snippet_file.upsert(t.allocator, "", "snippet.zig.trk", block);
    defer t.allocator.free(file);
    const found = (try snippet_file.findBlock(file, "snippet.zig.trk")).?;
    try t.expectEqualStrings(block, file[found.start..found.end]);
}

test "save selection as snippet: refusals, prefill, the file and the registry" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    lua_settings.test_config_dir = root;
    defer lua_settings.test_config_dir = null;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("zig");
    try doc.loadText("    for (items) |item| {\r\n        use(item);\r\n    }\r\n");
    // Nothing selected: refused.
    editor.startSnippetSave();
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "select the code") != null);
    // Two cursors: refused.
    _ = editor.execCommand("select_all", null);
    try doc.cursors.addCursor(0);
    editor.startSnippetSave();
    try t.expect(std.mem.indexOf(u8, editor.status_message, "single cursor") != null);
    doc.cursors.clearSecondary();
    // A terminal pane: refused.
    try editor.terminals.append(t.allocator, null); // fake slot: no shell
    editor.windows.items[0].layout.panes.items[0].content = .{ .terminal = 0 };
    editor.startSnippetSave();
    try t.expect(std.mem.indexOf(u8, editor.status_message, "editor pane") != null);
    editor.windows.items[0].layout.panes.items[0].content = .{ .editor = 0 };
    // The selection: the form opens prefilled with the dedented body, the
    // document's language and the default folder.
    _ = editor.execCommand("select_all", null);
    editor.startSnippetSave();
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    const form = &editor.snippet_form;
    try t.expectEqualStrings("for (items) |item| {\n    use(item);\n}", form.text(.body));
    try t.expectEqualStrings("zig", form.text(.language));
    try t.expectEqualStrings("Mine", form.text(.folder));
    try t.expectEqualStrings("", form.text(.name));
    // No name: the form stays and says why.
    try t.expect(!editor.submitSnippetForm());
    try t.expect(form.error_message.len > 0);
    try t.expectEqual(Editor.Mode.snippet_form, editor.mode);
    form.set(.name, "My loop");
    form.set(.notes, "Runs the body once per item.");
    try t.expect(editor.submitSnippetForm());
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqualStrings("Saved to my-snippets.lua: My loop", editor.status_message);
    // Registered as the file's own, with the body and the folder.
    const def = editor.snippets.command("snippet.zig.~my-loop").?;
    try t.expect(snippet_file.isMine(def));
    try t.expect(def.from_extension);
    try t.expectEqualStrings("Mine", def.group);
    try t.expectEqualStrings("for (items) |item| {\n    use(item);\n}", def.body);
    try t.expectEqualStrings("Mine", form.lastFolder());
    // The file holds the header and the block; saving the same name again
    // replaces the block instead of adding one.
    const path = try std.fs.path.join(t.allocator, &.{ root, "extensions", snippet_file.file_name });
    defer t.allocator.free(path);
    const text = try snippet_file.read(t.allocator, t.io, path);
    defer t.allocator.free(text);
    try t.expect(std.mem.startsWith(u8, text, snippet_file.header));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, "-- zide:snippet snippet.zig.~my-loop"));
    _ = editor.execCommand("select_all", null);
    editor.startSnippetSave();
    form.set(.name, "My loop");
    form.set(.folder, "Loops");
    try t.expect(editor.submitSnippetForm());
    const text2 = try snippet_file.read(t.allocator, t.io, path);
    defer t.allocator.free(text2);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, text2, "-- zide:snippet snippet.zig.~my-loop"));
    try t.expect(std.mem.indexOf(u8, text2, "group = \"Loops\"") != null);
    try t.expectEqualStrings("Loops", editor.snippets.command("snippet.zig.~my-loop").?.group);
    try t.expectEqualStrings("Loops", form.lastFolder());
    // Cancelling leaves the form without writing, and clears it.
    _ = editor.execCommand("select_all", null);
    editor.startSnippetSave();
    form.set(.name, "Never saved");
    editor.cancelSnippetForm();
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.snippets.command("snippet.zig.~never-saved") == null);
    try t.expectEqualStrings("", form.text(.name));
    // removeSnippet drops the definition and its palette command.
    try t.expect(editor.removeSnippet("snippet.zig.~my-loop"));
    try t.expect(editor.snippets.command("snippet.zig.~my-loop") == null);
    try t.expect(editor.commands.get("snippet.zig.~my-loop") == null);
    try t.expect(!editor.removeSnippet("snippet.zig.~my-loop"));
}

test "snippets integration: Lua reads group, notes and an optional prefix raw and reports type errors" {
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);
    try lua.doString(
        \\local name = assert(zide.register_snippet{language='zig', description='Hello world', group='Start here', notes='Prints a line.', body='x'})
        \\assert(name == 'snippet.zig.~hello-world', name)
        \\local c, err = zide.register_snippet{language='zig', body='x'}
        \\assert(c == nil and err:find('prefix or a description'), err)
        \\c, err = zide.register_snippet{language='zig', prefix='fn', group=7, body='x'}
        \\assert(c == nil and err == 'Snippet group must be a string', err)
        \\c, err = zide.register_snippet{language='zig', prefix='fn', notes={}, body='x'}
        \\assert(c == nil and err == 'Snippet notes must be a string', err)
        \\c, err = zide.register_snippet{language='zig', prefix=true, body='x'}
        \\assert(c == nil and err == 'Snippet prefix must be a string', err)
        \\c, err = zide.register_snippet{language='zig', prefix='fn', notes='tab\there', body='x'}
        \\assert(c == nil and err:find('newlines'), err)
    );
    const def = editor.snippets.command("snippet.zig.~hello-world").?;
    try t.expectEqualStrings("Start here", def.group);
    try t.expectEqualStrings("Prints a line.", def.notes);
    try t.expect(!def.hasTrigger());
    // Settings round-trip, including "auto" and out-of-range widths.
    try lua.doString(
        \\assert(zide.get('snippets_visible') == false and zide.get('snippets_side') == 'auto')
        \\assert(zide.get('snippets_width') == 260 and zide.get('tui_snippets_width') == 32)
        \\zide.set('snippets_visible', true); zide.set('snippets_side', 'left')
        \\zide.set('snippets_width', 300); zide.set('tui_snippets_width', 40)
        \\assert(zide.get('snippets_visible') == true and zide.get('snippets_side') == 'left')
        \\assert(zide.get('snippets_width') == 300 and zide.get('tui_snippets_width') == 40)
        \\zide.set('snippets_width', 5000); zide.set('tui_snippets_width', 1)
        \\assert(zide.get('snippets_width') == 300 and zide.get('tui_snippets_width') == 40)
        \\zide.set('snippets_side', 'auto'); assert(zide.get('snippets_side') == 'auto')
        \\assert(zide.get('snippets_double_click') == false)
        \\zide.set('snippets_double_click', true); assert(zide.get('snippets_double_click') == true)
    );
    try t.expect(editor.snippets_side == null);
    try t.expect(editor.snippets_double_click);
    editor.filetree_side = .right;
    try t.expectEqual(Editor.FiletreeSide.left, editor.snippetsSide());
    editor.filetree_side = .left;
    try t.expectEqual(Editor.FiletreeSide.right, editor.snippetsSide());
    // Hiding through the setting releases the keyboard.
    try t.expect(editor.takeKeyboardFocus(.snippets));
    try lua.doString("zide.set('snippets_visible', false)");
    try t.expect(!editor.snippets_focused);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
}

test "snippets panel: inserting into an untitled document adopts the language, selects the first field and hands the keyboard back" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    const doc = editor.activeDoc();
    try t.expect(doc.file_path == null and doc.language == null);
    _ = try editor.registerSnippet(.{ .language = "zig", .description = "Main function", .group = "Start here", .notes = "Where a program starts.", .body = "pub fn main() void {\n\t${1:body}\n}$0" });
    _ = try editor.registerSnippet(.{ .language = "zig", .prefix = "fn", .description = "Function", .group = "Functions", .body = "fn ${1:name}() void {}" });
    try t.expect(editor.takeKeyboardFocus(.snippets));
    var panel = editor.syncSnippetPanel();
    try t.expectEqualStrings("any language", panel.languageLabel());
    // Groups: "Start here" (open) with Main function, "Functions" (closed).
    try t.expectEqual(@as(usize, 3), panel.rows.items.len);
    try t.expectEqual(@as(?u32, null), panel.previewDef(null)); // a group row is selected
    try t.expectEqual(@as(?u32, 0), panel.previewDef(1)); // hovering the item previews it
    editor.activateSnippetRow(1);
    try t.expect(std.ascii.eqlIgnoreCase("zig", doc.language.?.name));
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    try t.expect(editor.editorOwnsInput());
    try t.expectEqualStrings("body", doc.selectedText().?);
    try t.expectEqualStrings("pub fn main() void {\n    body\n}", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(editor.snippets_visible); // the panel stays open behind the editor
    // Tab leaves the last field; the panel now follows the document's language.
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expect(doc.snippet_session == null);
    panel = editor.syncSnippetPanel();
    try t.expect(std.ascii.eqlIgnoreCase("zig", panel.languageLabel()));
    try t.expectEqual(@as(usize, 0), panel.selected); // a language change resets the selection
    // Keyboard navigation: Right opens the closed group, Enter on its item inserts.
    panel.selected = 2;
    panel.right(editor.allocator);
    editor.activateSnippetRow(3);
    try t.expectEqualStrings("name", doc.selectedText().?);
    try t.expect(std.mem.endsWith(u8, doc.buffer.slice(0, doc.buffer.byteLen()), "fn name() void {}"));
}

test "snippets panel: read-only documents and unregistered languages are refused with a message, keeping the panel focused" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    _ = try editor.registerSnippet(.{ .language = "cobol", .description = "Paragraph", .body = "x" });
    _ = try editor.registerSnippet(.{ .language = "*", .description = "Date", .body = "2026" });
    try t.expect(editor.takeKeyboardFocus(.snippets));
    const doc = editor.activeDoc();
    // cobol has snippets but no language definition: any-language mode skips it.
    const panel = editor.syncSnippetPanel();
    try t.expectEqual(@as(usize, 2), panel.rows.items.len);
    editor.insertSnippetFromPanel(0);
    try t.expect(std.mem.indexOf(u8, editor.status_message, "cobol") != null);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try t.expect(doc.language == null);
    // Read-only: refused before anything changes.
    doc.readonly = true;
    editor.activateSnippetRow(1);
    try t.expectEqualStrings("Read-only document", editor.status_message);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try t.expectEqual(@as(usize, 0), doc.buffer.byteLen());
    doc.readonly = false;
    editor.activateSnippetRow(1);
    try t.expectEqualStrings("2026", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(doc.language == null); // a * snippet sets no language
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    // Several cursors: refused.
    try t.expect(editor.takeKeyboardFocus(.snippets));
    try doc.cursors.addCursor(0);
    editor.activateSnippetRow(1);
    try t.expectEqualStrings("Snippets require a single cursor", editor.status_message);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
}

test "snippets panel: reload_extensions rebuilds the rows and the group toggles survive" {
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    lua_settings.registerApi(lua, &editor);
    editor.activeDoc().language = editor.findLanguage("zig");
    editor.loading_extensions = true;
    try lua.doString(lua_settings.zig_snippets);
    editor.loading_extensions = false;
    var panel = editor.syncSnippetPanel();
    const before = panel.rows.items.len;
    try t.expect(panel.groups.items.len > 2 and before > 2);
    // Open the second group.
    editor.activateSnippetRow(panel.groups.items[1].row);
    panel = editor.syncSnippetPanel();
    try t.expect(panel.groups.items[1].expanded);
    const opened = panel.rows.items.len;
    try t.expect(opened > before);
    panel.selected = opened - 1;
    // A reload drops the bundled set: no rows, no stale indices.
    lua_api.reloadExtensions(&editor);
    panel = editor.syncSnippetPanel();
    try t.expectEqual(@as(usize, 0), panel.rows.items.len);
    try t.expectEqual(@as(usize, 0), panel.selected);
    try t.expect(panel.rowAt(0) == null);
    // The set comes back with the same toggle.
    editor.loading_extensions = true;
    try lua.doString(lua_settings.zig_snippets);
    editor.loading_extensions = false;
    panel = editor.syncSnippetPanel();
    try t.expectEqual(opened, panel.rows.items.len);
    try t.expect(panel.groups.items[1].expanded);
}

test "snippets panel focus: the toggle cycle, precedence over the search panel, hidden panels and swallowed chords" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_visible = false;
    try t.expect(!editor.snippets_visible);
    try editor.addCompletionItem(try t.allocator.dupe(u8, "foo"), null, null);
    editor.toggleSnippets(); // hidden → shown + focused, popup closed
    try t.expect(editor.snippets_visible and !editor.completion_active);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try t.expect(!editor.editorOwnsInput());
    try t.expect(editor.takeKeyboardFocus(.search));
    try t.expectEqual(Editor.KeyboardOwner.search, editor.keyboardOwner());
    try t.expect(editor.snippets_visible and !editor.snippets_focused);
    editor.snippet_panel.scroll_to_selected = false;
    editor.toggleSnippets(); // shown behind another owner → focused, scrolled to its selection
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    try t.expect(editor.snippet_panel.scroll_to_selected and editor.search_visible);
    editor.toggleSnippets(); // focused → hidden, the pane gets the keys
    try t.expect(!editor.snippets_visible and !editor.snippets_focused);
    try t.expectEqual(Editor.KeyboardOwner.editor, editor.keyboardOwner());
    // Direct flag writes: a hidden panel never owns the keyboard, and the
    // Snippets panel outranks the search panel.
    editor.snippets_focused = true;
    editor.normalizeKeyboardFocus();
    try t.expect(!editor.snippets_focused);
    editor.snippets_visible = true;
    editor.snippets_focused = true;
    editor.search_focused = true;
    editor.normalizeKeyboardFocus();
    try t.expect(editor.snippets_focused and !editor.search_focused);
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
    // Clipboard and word-delete chords are swallowed; other actions pass.
    try t.expect(editor.panelAction("paste"));
    try t.expect(editor.panelAction("select_all"));
    try t.expect(!editor.panelAction("save"));
    try t.expect(editor.takeKeyboardFocus(.pane));
    try t.expect(editor.snippets_visible and !editor.snippets_focused);
    // The command behind Ctrl+Alt+B.
    try t.expect(editor.execCommand("toggle_snippets", null));
    try t.expectEqual(Editor.KeyboardOwner.snippets, editor.keyboardOwner());
}

/// How the compile check wraps a bundled skeleton: a statement goes into
/// a function, a declaration into a namespace, a whole program into its
/// own file. `fixup` is spliced in at the caret position ($0) to use the
/// names a learner would use next, since Zig refuses unused locals and
/// captures; `prelude` declares what a namespaced skeleton refers to.
const Check = struct {
    name: []const u8,
    kind: enum { stmt, top, program, skip } = .stmt,
    fixup: []const u8 = "",
    prelude: []const u8 = "",
};
const checks = [_]Check{
    .{ .name = "Hello world program", .kind = .program },
    .{ .name = "Main function", .kind = .top },
    .{ .name = "Main that can fail", .kind = .top },
    .{ .name = "Main with allocator and I/O", .kind = .program, .fixup = "_ = .{ gpa, io };" },
    .{ .name = "Import std", .kind = .skip },
    .{ .name = "Import a file", .kind = .skip },
    .{ .name = "Constant", .kind = .top },
    .{ .name = "Variable", .kind = .top },
    .{ .name = "String", .kind = .top },
    .{ .name = "Array", .kind = .top },
    .{ .name = "Slice of an array", .kind = .top, .prelude = "const numbers = [_]i32{ 4, 5, 6 };\n" },
    .{ .name = "Optional", .kind = .top },
    .{ .name = "Function", .kind = .top },
    .{ .name = "Public function", .kind = .top },
    .{ .name = "Function that can fail", .kind = .top },
    .{ .name = "Function that returns a value", .kind = .top },
    .{ .name = "Function with a parameter", .kind = .top, .fixup = "_ = number;" },
    .{ .name = "Method", .kind = .top, .fixup = "_ = self;" },
    .{ .name = "If as a value", .fixup = "_ = result;" },
    .{ .name = "If with an optional", .fixup = "_ = found;" },
    .{ .name = "If with an error", .fixup = "_ = found;" },
    .{ .name = "For each item", .fixup = "_ = item;" },
    .{ .name = "For with index", .fixup = "_ = .{ item, i };" },
    .{ .name = "For over a range", .fixup = "_ = i;" },
    .{ .name = "Struct", .kind = .top },
    .{ .name = "Struct with fields", .kind = .top },
    .{ .name = "Make a struct value", .fixup = "_ = point;" },
    .{ .name = "Enum", .kind = .top },
    .{ .name = "Tagged union", .kind = .top },
    .{ .name = "Error set", .kind = .top },
    .{ .name = "catch with a fallback", .fixup = "_ = result;" },
    .{ .name = "Arena allocator", .fixup = "_ = scratch;" },
    .{ .name = "Test block", .kind = .top },
};

/// The names the statement skeletons' defaults refer to, as a learner's
/// surrounding code would declare them.
const check_globals =
    \\const std = @import("std");
    \\const gpa = std.heap.page_allocator;
    \\const items = [_]i32{ 1, 2, 3 };
    \\const numbers = [_]i32{ 4, 5, 6 };
    \\const value: i32 = 7;
    \\const count: usize = 3;
    \\const condition = true;
    \\const other = false;
    \\const skip_this = false;
    \\const done = true;
    \\const maybe: ?i32 = null;
    \\const text: []const u8 = "hi";
    \\const Pair = struct { x: i32, y: i32 };
    \\const Color = enum { red, green };
    \\const color: Color = .red;
    \\fn doSomething() anyerror!void {}
    \\fn canFail() anyerror!i32 {
    \\    return 1;
    \\}
    \\fn cleanup() void {}
    \\
;

fn checkFor(name: []const u8) Check {
    for (checks) |check| if (std.mem.eql(u8, check.name, name)) return check;
    return .{ .name = name };
}

/// The skeleton as inserted with every default kept, plus `fixup` at $0.
fn filledBody(a: std.mem.Allocator, def: *const snippets.Definition, fixup: []const u8) ![]u8 {
    const text = def.template.text;
    const at = def.template.final.start;
    return std.mem.concat(a, u8, &.{ text[0..at], fixup, text[at..] });
}

fn compileCheck(base: []const u8, argv_head: []const []const u8, name: []const u8, what: []const u8) !void {
    const path = try std.fs.path.join(t.allocator, &.{ base, name });
    defer t.allocator.free(path);
    const exe = try std.fmt.allocPrint(t.allocator, "-femit-bin={s}.out", .{path});
    defer t.allocator.free(exe);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.append(t.allocator, @import("build_options").zig_exe);
    try argv.appendSlice(t.allocator, argv_head);
    try argv.appendSlice(t.allocator, &.{ exe, path });
    const result = try std.process.run(t.allocator, t.io, .{ .argv = argv.items });
    defer t.allocator.free(result.stdout);
    defer t.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("\n{s} does not compile:\n{s}\n", .{ what, result.stderr });
        return error.SnippetDoesNotCompile;
    }
}

test "snippets integration: every bundled skeleton compiles with the real compiler (needs -Dtest-tools)" {
    if (!@import("build_options").test_tools) return error.SkipZigTest;
    var lua = try Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    lua_settings.registerApi(lua, &editor);
    try lua.doString(lua_settings.zig_snippets);
    const defs = editor.snippets.items.items;
    for (checks) |check| {
        for (defs) |def| {
            if (std.mem.eql(u8, def.description, check.name)) break;
        } else {
            std.debug.print("\ncheck table names a snippet that no longer exists: {s}\n", .{check.name});
            return error.StaleCheckTable;
        }
    }
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    var stmt: std.Io.Writer.Allocating = .init(t.allocator);
    defer stmt.deinit();
    var top: std.Io.Writer.Allocating = .init(t.allocator);
    defer top.deinit();
    var top_refs: std.Io.Writer.Allocating = .init(t.allocator);
    defer top_refs.deinit();
    try stmt.writer.writeAll(check_globals);
    try top.writer.writeAll("const std = @import(\"std\");\n");
    for (defs, 0..) |*def, index| {
        const check = checkFor(def.description);
        const body = try filledBody(t.allocator, def, check.fixup);
        defer t.allocator.free(body);
        switch (check.kind) {
            .skip => {},
            .stmt => try stmt.writer.print("// {s}\nfn snippet_{d}() !void {{\n{s}\n}}\n", .{ def.description, index, body }),
            .top => {
                try top.writer.print("// {s}\nconst snippet_{d} = struct {{\n{s}{s}\n}};\n", .{ def.description, index, check.prelude, body });
                try top_refs.writer.print("    std.testing.refAllDecls(snippet_{d});\n", .{index});
            },
            .program => {
                const import = if (std.mem.startsWith(u8, body, "const std = @import")) "" else "const std = @import(\"std\");\n";
                const source = try std.mem.concat(t.allocator, u8, &.{ import, body, "\n" });
                defer t.allocator.free(source);
                const name = try std.fmt.allocPrint(t.allocator, "program_{d}.zig", .{index});
                defer t.allocator.free(name);
                try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = source });
                try compileCheck(base, &.{"build-exe"}, name, def.description);
            },
        }
    }
    try stmt.writer.writeAll("comptime {\n    std.testing.refAllDecls(@This());\n}\n");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "statements.zig", .data = stmt.written() });
    try compileCheck(base, &.{ "test", "--test-no-exec" }, "statements.zig", "a statement skeleton (see the fn snippet_N comment)");
    try top.writer.print("comptime {{\n{s}}}\n", .{top_refs.written()});
    try tmp.dir.writeFile(t.io, .{ .sub_path = "declarations.zig", .data = top.written() });
    try compileCheck(base, &.{ "test", "--test-no-exec" }, "declarations.zig", "a declaration skeleton (see the snippet_N comment)");
}
