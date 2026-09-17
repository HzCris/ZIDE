const std = @import("std");
const t = std.testing;
const Editor = @import("editor.zig").Editor;
const lua_settings = @import("lua_settings.zig");
const lua_api = @import("lua_api.zig");
const Lua = @import("zlua").Lua;

test "snippets integration: bundled Lua definitions reload and installation preserves customization" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try lua_settings.ensureSnippetExtension(tmp.dir, t.io);
    const installed = try tmp.dir.readFileAlloc(t.io, "snippets-zig.lua", t.allocator, .limited(16 * 1024));
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
        try t.expectEqual(@as(usize, 10), editor.snippets.items.items.len);
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

test "snippets integration: Unicode fields track edits navigation cancellation and undo" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const command = try editor.registerSnippet("*", "demo", "Demo", "${1:é} ${2:tail}$0");
    const doc = editor.activeDoc();
    try doc.loadText("before OLD after");
    doc.cursors.primary().* = .{ .anchor = 7, .offset = 10 };
    try t.expect(editor.execCommand(command, null));
    try t.expectEqualStrings("é", doc.selectedText().?);
    try doc.insertAtCursor("😀");
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expectEqualStrings("tail", doc.selectedText().?);
    try t.expect(editor.handleSnippetKey(.shift_tab));
    try t.expectEqualStrings("😀", doc.selectedText().?);
    try t.expect(editor.handleSnippetKey(.escape));
    try t.expect(doc.snippet_session == null);
    try t.expectEqualStrings("before 😀 tail after", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(try doc.undoAction());
    try t.expectEqualStrings("before é tail after", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(try doc.undoAction());
    try t.expectEqualStrings("before OLD after", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqualStrings("OLD", doc.selectedText().?);
    try t.expect(try doc.redoAction());
    try t.expect(doc.snippet_session == null);
    try t.expectEqualStrings("before é tail after", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "snippets integration: document indentation and CRLF survive expansion and final stop" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    _ = try editor.registerSnippet("*", "demo", "Demo", "${1:é} {\n\t${2:body}\n}$0");
    const doc = editor.activeDoc();
    doc.format_rules = .{ .use_tabs = false, .indent_size = 2 };
    try doc.loadText("  demo\r\n");
    doc.cursors.primary().offset = 6;
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expectEqualStrings("  é {\r\n    body\r\n  }\r\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expectEqualStrings("body", doc.selectedText().?);
    try doc.insertAtCursor("界");
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expect(doc.snippet_session == null);
    try t.expectEqual(doc.buffer.byteLen() - 2, doc.cursors.primary().offset);
    try t.expectEqualStrings("  é {\r\n    界\r\n  }\r\n", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "snippets integration: language and field priority precede completion and indentation" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    _ = try editor.registerSnippet("*", "demo", "Global", "${1:global}$0");
    _ = try editor.registerSnippet("zig", "demo", "Zig", "${1:specific} ${2:next}$0");
    const doc = editor.activeDoc();
    doc.language = editor.findLanguage("zig");
    try doc.loadText("demo");
    doc.cursors.primary().moveToEnd(&doc.buffer);
    try editor.addCompletionItem(try t.allocator.dupe(u8, "completion"), null, null);
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expectEqualStrings("specific", doc.selectedText().?);
    try t.expect(!editor.completion_active);
    try editor.addCompletionItem(try t.allocator.dupe(u8, "completion"), null, null);
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expectEqualStrings("next", doc.selectedText().?);
    try t.expect(!editor.completion_active);
    try t.expect(editor.handleSnippetKey(.escape));
    doc.language = null;
    try doc.loadText("demo");
    doc.cursors.primary().moveToEnd(&doc.buffer);
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expectEqualStrings("global", doc.selectedText().?);
    try t.expect(editor.handleSnippetKey(.escape));
    try doc.loadText("");
    try editor.addCompletionItem(try t.allocator.dupe(u8, "completion"), null, null);
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expectEqualStrings("completion", doc.buffer.slice(0, doc.buffer.byteLen()));
    try doc.loadText("");
    doc.format_rules = .{ .use_tabs = false, .indent_size = 2 };
    try t.expect(editor.handleSnippetKey(.tab));
    try t.expectEqualStrings("  ", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(editor.handleSnippetKey(.shift_tab));
    try t.expectEqualStrings("", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "snippets integration: focus changes and multiple cursors end navigation" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.multi_window_supported = true;
    _ = try editor.registerSnippet("*", "demo", "Demo", "${1:field}$0");
    for (0..6) |change| {
        const doc = editor.activeDoc();
        const id = doc.id;
        try doc.loadText("demo");
        doc.cursors.primary().moveToEnd(&doc.buffer);
        try t.expect(editor.expandSnippet(true));
        switch (change) {
            0 => editor.search_focused = true,
            1 => editor.filetree_focused = true,
            2 => {
                _ = try editor.newDocument();
            },
            3 => try doc.cursors.addCursor(0),
            4 => editor.splitActive(.horizontal),
            5 => editor.focusWindow(try editor.newWindow(.{ .editor = editor.docIndexForId(id).? })),
            else => unreachable,
        }
        editor.validateSnippetState();
        try t.expect(editor.documents.items[editor.docIndexForId(id).?].snippet_session == null);
        try t.expect(editor.snippet_owner == null);
        editor.search_focused = false;
        editor.filetree_focused = false;
        editor.activeDoc().cursors.clearSecondary();
    }
    const doc = editor.activeDoc();
    try doc.loadText("demo");
    doc.cursors.primary().moveToEnd(&doc.buffer);
    try doc.cursors.addCursor(0);
    try t.expect(!editor.expandSnippet(true));
    try t.expect(doc.snippet_session == null);
    try t.expectEqualStrings("demo", doc.buffer.slice(0, doc.buffer.byteLen()));
}
