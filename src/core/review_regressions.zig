//! Regression tests from code reviews. Each one pins down a bug that was found
//! and fixed: documents closing or saving at the wrong moment, files changed
//! on disk, search results gone stale, word commands, Lua settings, snippets.
const std = @import("std");
const t = std.testing;
const Editor = @import("editor.zig").Editor;
const lsp = @import("lsp.zig");
const terminal = @import("terminal.zig");

test "regression: pending close follows its document after earlier tabs close" {
    for ([_]Editor.CloseChoice{ .cancel, .discard, .save }) |choice| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
        defer t.allocator.free(root);
        const path = try std.fs.path.join(t.allocator, &.{ root, "saved.txt" });
        defer t.allocator.free(path);
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        editor.lsp_enabled = false;
        const target = try editor.newDocument();
        const target_id = target.id;
        try target.insertAtCursor("target draft");
        const other = try editor.newDocument();
        const other_id = other.id;
        try other.insertAtCursor("other draft");
        try t.expect(!editor.requestCloseDoc(1));
        _ = editor.closeDocAt(0);
        const outcome = editor.resolveCloseDoc(choice);
        try t.expect(editor.confirm_close_doc == null);
        switch (choice) {
            .cancel => {
                try t.expectEqual(Editor.CloseOutcome.kept, outcome);
                try t.expect(editor.documents.items[editor.docIndexForId(target_id).?].dirty);
            },
            .discard => {
                try t.expectEqual(Editor.CloseOutcome.closed, outcome);
                try t.expect(editor.docIndexForId(target_id) == null);
            },
            .save => {
                try t.expectEqual(Editor.CloseOutcome.needs_path, outcome);
                editor.startSaveAs(target_id, null);
                editor.switchToDoc(editor.docIndexForId(other_id).?);
                try t.expectEqual(Editor.SaveOutcome.saved, editor.finishSaveAs(path));
                try t.expect(editor.docIndexForId(target_id) == null);
                const disk = try tmp.dir.readFileAlloc(t.io, "saved.txt", t.allocator, .limited(100));
                defer t.allocator.free(disk);
                try t.expectEqualStrings("target draft", disk);
            },
        }
        const surviving = &editor.documents.items[editor.docIndexForId(other_id).?];
        try t.expect(surviving.dirty);
        try t.expectEqualStrings("other draft", surviving.buffer.slice(0, surviving.buffer.byteLen()));
    }
}

test "regression: closing a pending target cannot close its replacement" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try editor.activeDoc().insertAtCursor("target");
    try t.expect(!editor.requestCloseDoc(0));
    _ = editor.closeDocAt(0);
    const replacement_id = editor.activeDoc().id;
    try editor.activeDoc().insertAtCursor("replacement");
    try t.expectEqual(Editor.CloseOutcome.kept, editor.resolveCloseDoc(.discard));
    try t.expectEqual(replacement_id, editor.activeDoc().id);
    try t.expect(editor.activeDoc().dirty);
}

test "regression: a delayed formatting save closes only the confirmed document" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "target.zig", "original");
    const path = try tmp.dir.realPathFileAlloc(t.io, "target.zig", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    const target = try editor.openFile(path);
    const id = target.id;
    try target.insertAtCursor("edited ");
    const request: lsp.Request = .{ .method = .format_document, .doc_id = id, .version = target.buffer.version, .serial = 1 };
    const other = try editor.newDocument();
    const other_id = other.id;
    try other.insertAtCursor("other draft");
    // Model an already pending format operation, with no external process.
    const client = try t.allocator.create(lsp.LspClient);
    client.* = lsp.LspClient.init(t.allocator, t.io);
    editor.lsp_clients.append(t.allocator, client) catch |err| {
        client.deinit();
        t.allocator.destroy(client);
        return err;
    };
    client.config = try lsp.ServerConfig.fromArgv(t.allocator, &.{"zig"}, &.{"test-server"});
    // Documents route to the newest registration for their language, so the
    // fake server must be registered, not just running.
    var registration = try client.config.?.clone(t.allocator);
    editor.lsp_configs.append(t.allocator, registration) catch |err| {
        registration.deinit(t.allocator);
        return err;
    };
    client.capabilities.format_document = true;
    var pending = request;
    pending.generation = client.generation;
    editor.lsp_tools.format_on_save = true;
    editor.lsp_tools.formatting = pending;
    editor.lsp_tools.save = .{ .id = id, .options = .{}, .owned_path = null };
    try t.expect(!editor.requestCloseDoc(editor.docIndexForId(id).?));
    _ = editor.closeDocAt(0);
    try t.expectEqual(Editor.CloseOutcome.kept, editor.resolveCloseDoc(.save));
    try t.expectEqual(@as(?u64, id), editor.close_after_save_id);
    editor.switchToDoc(editor.docIndexForId(other_id).?);
    editor.lsp_tools.response(&editor, client, pending, "{\"result\":[]}");
    // The formatted save runs on the next tick, not inside the reply.
    try t.expect(editor.docIndexForId(id) != null);
    editor.lsp_tools.tick(&editor);
    try t.expect(editor.docIndexForId(id) == null);
    const surviving = &editor.documents.items[editor.docIndexForId(other_id).?];
    try t.expect(surviving.dirty);
    try t.expectEqualStrings("other draft", surviving.buffer.slice(0, surviving.buffer.byteLen()));
    const disk = try tmp.dir.readFileAlloc(t.io, "target.zig", t.allocator, .limited(100));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("edited original", disk);
}

test "regression: same-mtime changes in size or identity protect local edits" {
    const text_file = @import("text_file.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "file.txt", "original");
    const path = try tmp.dir.realPathFileAlloc(t.io, "file.txt", t.allocator);
    defer t.allocator.free(path);
    for ([_]bool{ false, true }) |replace_identity| {
        for ([_]bool{ false, true }) |dirty| {
            try writeFile(tmp.dir, "file.txt", "original");
            var editor = try Editor.init(t.allocator, t.io);
            defer editor.deinit();
            editor.lsp_enabled = false;
            try editor.openIntoActive(path);
            const doc = editor.activeDoc();
            const original = doc.disk_stamp.?;
            if (dirty) try doc.insertAtCursor("local ");
            const external = if (replace_identity) "external" else "external with different size";
            if (replace_identity) {
                try text_file.atomicWrite(t.allocator, t.io, path, external);
            } else try writeFile(tmp.dir, "file.txt", external);
            {
                const file = try tmp.dir.openFile(t.io, "file.txt", .{ .mode = .read_write });
                defer file.close(t.io);
                try file.setTimestamps(t.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = original.mtime } } });
            }
            const current = (try text_file.Stamp.read(t.io, path)).?;
            try t.expectEqual(original.mtime, current.mtime);
            try t.expect(!std.meta.eql(original, current));
            try t.expect(doc.checkExternalChange(t.io));
            if (dirty) {
                try t.expectEqual(Editor.SaveOutcome.conflict, editor.saveDocument(doc.id, .{ .interactive = false, .skip_format = true }));
                try t.expectEqualStrings("local original", doc.buffer.slice(0, doc.buffer.byteLen()));
                const disk = try tmp.dir.readFileAlloc(t.io, "file.txt", t.allocator, .limited(100));
                defer t.allocator.free(disk);
                try t.expectEqualStrings(external, disk);
                try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(doc.id, .{ .overwrite = true, .skip_format = true }));
                try t.expect(!doc.checkExternalChange(t.io));
            } else {
                editor.pollExternalChanges();
                try t.expectEqualStrings(external, doc.buffer.slice(0, doc.buffer.byteLen()));
                try t.expect(!doc.dirty and !doc.checkExternalChange(t.io));
            }
        }
    }
}

test "regression: word commands cross complete newlines and preserve undo" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const doc = editor.activeDoc();
    for ([_][]const u8{ "\n", "\r\n" }) |eol| {
        const original = try std.mem.concat(t.allocator, u8, &.{ "é", eol, eol, "word" });
        defer t.allocator.free(original);
        try doc.loadText(original);
        _ = editor.execAction("cursor_word_right");
        try t.expectEqual(@as(usize, 2), doc.cursors.primary().offset);
        _ = editor.execAction("cursor_word_right_select");
        try t.expectEqualStrings(eol, doc.selectedText().?);
        _ = editor.execAction("cursor_right");
        doc.cursors.primary().* = .{ .offset = 2 };
        _ = editor.execAction("delete_word_forward");
        const joined = try std.mem.concat(t.allocator, u8, &.{ "é", eol, "word" });
        defer t.allocator.free(joined);
        try t.expectEqualStrings(joined, doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expect(try doc.undoAction());
        try t.expectEqualStrings(original, doc.buffer.slice(0, doc.buffer.byteLen()));
        doc.cursors.primary().* = .{ .offset = 2 + eol.len };
        _ = editor.execAction("cursor_word_right");
        try t.expectEqual(2 + 2 * eol.len, doc.cursors.primary().offset);
        doc.cursors.primary().moveToEnd(&doc.buffer);
        _ = editor.execAction("delete_word_forward");
        try t.expectEqualStrings(original, doc.buffer.slice(0, doc.buffer.byteLen()));

        // Backward, the mirror rule: from a line start exactly one complete
        // line break is crossed (CRLF as a whole); inside a line the word
        // before the caret is taken, never more than the line.
        _ = editor.execAction("cursor_word_left");
        try t.expectEqual(2 + 2 * eol.len, doc.cursors.primary().offset);
        _ = editor.execAction("cursor_word_left");
        try t.expectEqual(2 + eol.len, doc.cursors.primary().offset);
        _ = editor.execAction("cursor_word_left");
        try t.expectEqual(@as(usize, 2), doc.cursors.primary().offset);
        _ = editor.execAction("cursor_word_left"); // é is a word character
        try t.expectEqual(@as(usize, 0), doc.cursors.primary().offset);
        doc.cursors.primary().* = .{ .offset = 2 + 2 * eol.len };
        _ = editor.execAction("cursor_word_left_select");
        try t.expectEqualStrings(eol, doc.selectedText().?);
        // Ctrl+Backspace at a line start joins it with the line above only.
        doc.cursors.primary().* = .{ .offset = 2 + 2 * eol.len };
        _ = editor.execAction("delete_word_backward");
        try t.expectEqualStrings(joined, doc.buffer.slice(0, doc.buffer.byteLen()));
        try t.expectEqual(2 + eol.len, doc.cursors.primary().offset);
        try t.expect(try doc.undoAction());
        try t.expectEqualStrings(original, doc.buffer.slice(0, doc.buffer.byteLen()));
        doc.cursors.primary().* = .{ .offset = 0 };
        _ = editor.execAction("delete_word_backward");
        try t.expectEqualStrings(original, doc.buffer.slice(0, doc.buffer.byteLen()));
    }
}

fn writeFile(dir: std.Io.Dir, path: []const u8, text: []const u8) !void {
    const f = try dir.createFile(t.io, path, .{});
    defer f.close(t.io);
    try f.writeStreamingAll(t.io, text);
}

fn finishSearch(editor: *Editor) !void {
    var tries: usize = 0;
    while (editor.search.searching and tries < 500) : (tries += 1) {
        _ = editor.search.drain();
        if (editor.search.searching) try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    try t.expect(!editor.search.searching);
}

test "regression: stale search refresh preserves Unicode and the original query" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "file.txt", "aaX\r\n");
    const path = try tmp.dir.realPathFileAlloc(t.io, "file.txt", t.allocator);
    defer t.allocator.free(path);
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try t.expect(editor.setFiletreeRoot(root));
    try editor.openIntoActive(path);
    editor.search.appendText("X");
    editor.searchStart();
    const doc = editor.activeDoc();
    try doc.replaceRange(1, 2, "é");
    @memcpy(editor.search.query_buf[0..4], "long");
    editor.search.query_len = 4;
    editor.searchOpenSelected();
    try t.expectEqualStrings("X", doc.selectedText().?);
    try t.expectEqual(@as(u32, 3), editor.search.matches.items[0].col);
    _ = editor.execAction("delete_forward");
    try t.expectEqualStrings("aé\r\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(std.unicode.utf8ValidateSlice(doc.buffer.slice(0, doc.buffer.byteLen())));
    try t.expect(try doc.undoAction());
    try t.expectEqualStrings("aéX\r\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    editor.searchArmReplace();
    try t.expect(!editor.search.confirm_armed);
    try finishSearch(&editor);
    try doc.loadText("aé\r\n");
    doc.cursors.primary().* = .{ .anchor = 0, .offset = 1 };
    editor.searchCycleResult(true);
    try t.expectEqualStrings("a", doc.selectedText().?);
    try t.expectEqual(@as(usize, 0), editor.search.matches.items.len);
    try t.expectEqual(@as(usize, 0), editor.search.resultFileCount());
    try t.expect(std.mem.indexOf(u8, editor.status_message, "no longer exists") != null);
}

test "regression: search filters protect excluded open buffers in both replacement scopes" {
    const search = @import("search.zig");
    for ([_]search.ReplaceScope{ .open_only, .all }) |scope| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(t.io, "src", .default_dir);
        for ([_][]const u8{ "src/keep.txt", "src/excluded.txt", "src/other.zig", "src/closed.txt" }) |p| try writeFile(tmp.dir, p, "needle");
        const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
        defer t.allocator.free(root);
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        editor.lsp_enabled = false;
        try t.expect(editor.setFiletreeRoot(root));
        for ([_][]const u8{ "src/keep.txt", "src/excluded.txt", "src/other.zig" }) |p| {
            const path = try std.fs.path.join(t.allocator, &.{ root, p });
            defer t.allocator.free(path);
            const doc = try editor.openFile(path);
            try doc.insertAtCursor("dirty ");
        }
        const sp = &editor.search;
        sp.appendText("needle");
        sp.field = .filter;
        sp.appendText("*.txt");
        sp.field = .exclude;
        sp.appendText("src\\excluded");
        sp.field = .replace;
        sp.appendText("changed");
        editor.searchStart();
        try finishSearch(&editor);
        try t.expectEqual(@as(usize, 2), sp.matches.items.len);
        const targets = sp.replaceTargets(&editor);
        try t.expectEqual(@as(usize, 1), targets.open);
        try t.expectEqual(@as(usize, 1), targets.disk);
        const result = sp.executeReplace(&editor, scope);
        try t.expectEqual(@as(usize, if (scope == .all) 2 else 1), result.count);
        for (editor.documents.items) |*doc| {
            const path = doc.file_path orelse continue;
            const expected = if (std.mem.endsWith(u8, path, "keep.txt")) "dirty changed" else "dirty needle";
            try t.expectEqualStrings(expected, doc.buffer.slice(0, doc.buffer.byteLen()));
        }
        for ([_][]const u8{ "src/keep.txt", "src/excluded.txt", "src/other.zig", "src/closed.txt" }) |p| {
            const disk = try tmp.dir.readFileAlloc(t.io, p, t.allocator, .limited(100));
            defer t.allocator.free(disk);
            try t.expectEqualStrings(if (scope == .all and std.mem.endsWith(u8, p, "closed.txt")) "changed" else "needle", disk);
        }
        sp.field = .filter;
        sp.appendText("x");
        try t.expect(!sp.criteriaCurrent());
        try t.expectEqual(@as(usize, 0), sp.executeReplace(&editor, .all).count);
        try t.expectEqual(@as(usize, 0), sp.replaceTargets(&editor).open);
    }
}

test "regression: disk search refresh selects its document across Lua open hooks" {
    const zlua = @import("zlua");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "file.txt", "aaX");
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var lua = try zlua.Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    @import("lua_settings.zig").registerApi(lua, &editor);
    try lua.doString("zide.on('open', function() hook_runs = (hook_runs or 0) + 1; zide.exec('prev_doc') end)");
    try t.expect(editor.setFiletreeRoot(root));
    editor.search.appendText("X");
    editor.searchStart();
    try finishSearch(&editor);
    try t.expectEqual(@as(usize, 1), editor.search.matches.items.len);
    try writeFile(tmp.dir, "file.txt", "a😀X");
    editor.searchOpenSelected();
    // The hook really ran (and switched away) while the result opened.
    _ = lua.getGlobal("hook_runs");
    defer lua.pop(1);
    try t.expectEqual(@as(zlua.Integer, 1), try lua.toInteger(-1));
    try t.expect(editor.activeDoc().file_path != null);
    try t.expectEqualStrings("X", editor.activeDoc().selectedText().?);
    try t.expectEqual(@as(u32, 5), editor.search.matches.items[0].col);
}

test "regression: search refresh prefers the following equidistant match outside the workspace" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "project", .default_dir);
    try writeFile(tmp.dir, "outside.txt", "--X--");
    const root = try tmp.dir.realPathFileAlloc(t.io, "project", t.allocator);
    defer t.allocator.free(root);
    const path = try tmp.dir.realPathFileAlloc(t.io, "outside.txt", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try t.expect(editor.setFiletreeRoot(root));
    try editor.openIntoActive(path);
    editor.search.appendText("X");
    editor.search.field = .filter;
    editor.search.appendText("*.txt");
    editor.searchStart();
    try finishSearch(&editor);
    try t.expectEqual(@as(usize, 1), editor.search.matches.items.len);
    try editor.activeDoc().loadText("X---X");
    editor.searchOpenSelected();
    try t.expectEqual(@as(usize, 4), editor.activeDoc().cursors.primary().anchor.?);
    try t.expectEqualStrings("X", editor.activeDoc().selectedText().?);
    editor.search.field = .exclude;
    editor.search.appendText("outside.txt");
    editor.searchStart();
    try finishSearch(&editor);
    try t.expectEqual(@as(usize, 0), editor.search.matches.items.len);
}

test "regression: refreshing search during streaming preserves path IDs and the cap" {
    const search = @import("search.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "open.txt", "X");
    try writeFile(tmp.dir, "closed.txt", "X X X X");
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try tmp.dir.realPathFileAlloc(t.io, "open.txt", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try t.expect(editor.setFiletreeRoot(root));
    try editor.openIntoActive(path);
    editor.search.appendText("X");
    editor.searchStart();
    const many = try t.allocator.alloc(u8, search.max_matches * 2 + 2);
    defer t.allocator.free(many);
    for (many, 0..) |*ch, i| ch.* = if (i % 2 == 0) 'X' else '\n';
    try editor.activeDoc().loadText(many);
    editor.searchOpenSelected();
    try finishSearch(&editor);
    try t.expectEqual(@as(usize, search.max_matches), editor.search.matches.items.len);
    try t.expect(editor.search.capped);
    for (editor.search.matches.items) |m| try t.expect(m.path_idx < editor.search.paths.items.len);
    try t.expectEqual(@as(usize, 1), editor.search.resultFileCount());
}

test "EditorConfig nested roots, invalidation and Save As transformations remain undoable" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "nested");
    try writeFile(tmp.dir, ".editorconfig", "root=true\n[*]\nindent_style=space\nindent_size=8\ntrim_trailing_whitespace=true\nend_of_line=lf\ninsert_final_newline=true\n");
    try writeFile(tmp.dir, "nested/.editorconfig", "[*.txt]\nindent_size=3\n");
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const path = try std.fs.path.join(t.allocator, &.{ base, "nested", "café.txt" });
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    const doc = editor.activeDoc();
    try doc.insertAtCursor("é text  \r\nnext\t");
    doc.cursors.primary().offset = 4;
    const id = doc.id;
    try t.expectEqual(Editor.SaveOutcome.saved, editor.saveDocument(id, .{ .path = path }));
    try t.expectEqualStrings("é text\nnext\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expectEqual(@as(usize, 4), doc.cursors.primary().offset);
    try t.expectEqual(@as(usize, 3), editor.indentWidthFor(doc));
    _ = editor.execAction("undo");
    try t.expectEqualStrings("é text  \r\nnext\t", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(doc.dirty);
    _ = editor.execAction("redo");
    try t.expect(!doc.dirty);
    try writeFile(tmp.dir, "nested/.editorconfig", "root=true\n[*.txt]\nindent_size=5\n");
    editor.pollExternalChanges();
    try t.expectEqual(@as(usize, 5), editor.indentWidthFor(doc));
    try t.expect(doc.format_rules.trim == null);
}

test "EditorConfig failed encoding save keeps visible normalization and the original disk file" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, ".editorconfig", "root=true\n[*]\ntrim_trailing_whitespace=true\ninsert_final_newline=true\n");
    try writeFile(tmp.dir, "file.txt", "disk");
    const path = try tmp.dir.realPathFileAlloc(t.io, "file.txt", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try editor.openIntoActive(path);
    const doc = editor.activeDoc();
    try doc.insertAtCursor("😀  \n");
    try t.expectEqual(Editor.SaveOutcome.unrepresentable, editor.saveDocument(doc.id, .{ .format = .{ .encoding = .windows1252 } }));
    try t.expectEqualStrings("😀\ndisk\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(doc.dirty);
    const disk = try tmp.dir.readFileAlloc(t.io, "file.txt", t.allocator, .limited(100));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("disk", disk);
    _ = editor.execAction("undo");
    try t.expectEqualStrings("😀  \ndisk", doc.buffer.slice(0, doc.buffer.byteLen()));
}

test "recovery retains named and untitled edits and uses the external-change save prompt" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "file.txt", "original");
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const path = try tmp.dir.realPathFileAlloc(t.io, "file.txt", t.allocator);
    defer t.allocator.free(path);
    {
        var editor = try Editor.init(t.allocator, t.io);
        defer editor.deinit();
        editor.lsp_enabled = false;
        try editor.startRecoveryAt(base, base);
        try editor.openIntoActive(path);
        try editor.activeDoc().insertAtCursor("unsaved ");
        const untitled = try editor.newDocument();
        try untitled.insertAtCursor("untitled 😀");
        // Shutdown flushes dirty data without changing either source file.
    }
    try writeFile(tmp.dir, "file.txt", "external edit after snapshot");
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try editor.startRecoveryAt(base, base);
    editor.serviceTick(0);
    try t.expectEqual(Editor.Mode.recovery_picker, editor.mode);
    editor.resolveRecovery(.recover);
    try t.expectEqual(@as(usize, 0), editor.recovery.?.candidates.items.len);
    // The untitled buffer comes back as an untitled, unsaved document.
    var untitled_recovered: usize = 0;
    for (editor.documents.items) |*doc| {
        if (doc.file_path != null) continue;
        if (!std.mem.eql(u8, doc.buffer.slice(0, doc.buffer.byteLen()), "untitled 😀")) continue;
        try t.expect(doc.dirty);
        untitled_recovered += 1;
    }
    try t.expectEqual(@as(usize, 1), untitled_recovered);
    const named = &editor.documents.items[(try editor.findDocument(path)).?];
    try t.expectEqualStrings("unsaved original", named.buffer.slice(0, named.buffer.byteLen()));
    try t.expect(named.external_changed and named.dirty);
    try t.expectEqual(Editor.SaveOutcome.conflict, editor.saveDocument(named.id, .{}));
    const disk = try tmp.dir.readFileAlloc(t.io, "file.txt", t.allocator, .limited(100));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("external edit after snapshot", disk);
    editor.discardAndQuit();
}

test "regression: Save As protects an existing destination" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "existing.txt", "ORIGINAL DESTINATION");
    const path = try tmp.dir.realPathFileAlloc(t.io, "existing.txt", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try editor.activeDoc().insertAtCursor("UNSAVED SOURCE");
    editor.startSaveAs(editor.activeDoc().id, null);
    try t.expectEqual(Editor.SaveOutcome.destination_exists, editor.finishSaveAs(path));
    const disk = try tmp.dir.readFileAlloc(t.io, "existing.txt", t.allocator, .limited(100));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("ORIGINAL DESTINATION", disk);
}

test "workspace edits validate all files, reject stale previews, and preserve disk and undo" {
    const workspace = @import("workspace_edit.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.txt", "😀name\n");
    try writeFile(tmp.dir, "b.txt", "name\n");
    const a = try tmp.dir.realPathFileAlloc(t.io, "a.txt", t.allocator);
    defer t.allocator.free(a);
    const b = try tmp.dir.realPathFileAlloc(t.io, "b.txt", t.allocator);
    defer t.allocator.free(b);
    const uri_a = try lsp.pathToUri(t.allocator, a);
    defer t.allocator.free(uri_a);
    const uri_b = try lsp.pathToUri(t.allocator, b);
    defer t.allocator.free(uri_b);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try editor.openIntoActive(a);
    const id = editor.activeDoc().id;
    const EditDoc = struct { textDocument: struct { uri: []const u8, version: ?i32 = null }, edits: []const workspace.TextEdit };
    for ([_]bool{ true, false }) |invalid| {
        const encoded = try std.json.Stringify.valueAlloc(t.allocator, .{ .documentChanges = [_]EditDoc{
            .{ .textDocument = .{ .uri = uri_a }, .edits = &.{.{ .range = .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 6 } }, .newText = "renamed" }} },
            .{ .textDocument = .{ .uri = uri_b }, .edits = &.{.{ .range = .{ .start = .{ .line = if (invalid) 99 else 0, .character = 0 }, .end = .{ .line = 0, .character = 4 } }, .newText = "renamed" }} },
        } }, .{});
        defer t.allocator.free(encoded);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, encoded, .{});
        defer parsed.deinit();
        if (invalid) {
            try t.expectError(error.InvalidRange, workspace.Plan.parse(&editor, parsed.value, .utf16));
            try t.expectEqualStrings("😀name\n", editor.activeDoc().buffer.slice(0, editor.activeDoc().buffer.byteLen()));
            try t.expectEqual(@as(usize, 1), editor.documents.items.len);
        } else {
            var plan = try workspace.Plan.parse(&editor, parsed.value, .utf16);
            defer plan.deinit();
            try plan.apply(&editor);
            const first = &editor.documents.items[editor.docIndexForId(id).?];
            try t.expectEqualStrings("😀renamed\n", first.buffer.slice(0, first.buffer.byteLen()));
            const second = &editor.documents.items[(try editor.findDocument(b)).?];
            try t.expectEqualStrings("renamed\n", second.buffer.slice(0, second.buffer.byteLen()));
            try t.expect(first.dirty and second.dirty);
            try t.expect(try first.undoAction());
            try t.expectEqualStrings("😀name\n", first.buffer.slice(0, first.buffer.byteLen()));
            var stale = try workspace.Plan.parse(&editor, parsed.value, .utf16);
            defer stale.deinit();
            try first.insertAtCursor("edit");
            try t.expectError(error.StaleDocument, stale.apply(&editor));
        }
    }
    const disk = try tmp.dir.readFileAlloc(t.io, "b.txt", t.allocator, .limited(100));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("name\n", disk);
}

test "regression: relative and absolute file paths focus one document" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "file.txt", "hello");
    const absolute = try tmp.dir.realPathFileAlloc(t.io, "file.txt", t.allocator);
    defer t.allocator.free(absolute);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(cwd);
    const relative = absolute[cwd.len + 1 ..];
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try editor.openIntoActive(relative);
    const original_id = editor.activeDoc().id;
    _ = try editor.openOrFocus(absolute);
    try t.expectEqual(original_id, editor.activeDoc().id);
}

test "Save As rechecks its destination and retains the original document across focus changes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "target.txt", "old");
    const path = try tmp.dir.realPathFileAlloc(t.io, "target.txt", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    const id = editor.activeDoc().id;
    try editor.activeDoc().insertAtCursor("new");
    editor.startSaveAs(id, null);
    try t.expectEqual(Editor.SaveOutcome.destination_exists, editor.finishSaveAs(path));
    // The source cannot be reloaded when this is a destination prompt.
    editor.resolveOverwrite(.reload);
    try t.expectEqual(Editor.Mode.confirm_overwrite, editor.mode);
    _ = try editor.newDocument();
    try writeFile(tmp.dir, "target.txt", "changed after confirmation");
    editor.resolveOverwrite(.overwrite);
    try t.expectEqual(Editor.Mode.confirm_overwrite, editor.mode);
    {
        const content = try tmp.dir.readFileAlloc(t.io, "target.txt", t.allocator, .limited(100));
        defer t.allocator.free(content);
        try t.expectEqualStrings("changed after confirmation", content);
    }
    editor.resolveOverwrite(.overwrite);
    const content = try tmp.dir.readFileAlloc(t.io, "target.txt", t.allocator, .limited(100));
    defer t.allocator.free(content);
    try t.expectEqualStrings("new", content);
    try t.expect(!editor.documents.items[editor.docIndexForId(id).?].dirty);
}

test "Save As refuses a destination owned by another dirty document" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "target.txt", "disk");
    const path = try tmp.dir.realPathFileAlloc(t.io, "target.txt", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    const source = editor.activeDoc().id;
    try editor.activeDoc().insertAtCursor("source");
    const target = try editor.openFile(path);
    const target_id = target.id;
    try target.insertAtCursor("dirty");
    const outcome = editor.saveDocument(source, .{ .path = path });
    try t.expect(outcome == .failed and outcome.failed == error.DestinationOpen);
    try t.expectEqual(target_id, editor.activeDoc().id);
    const content = try tmp.dir.readFileAlloc(t.io, "target.txt", t.allocator, .limited(100));
    defer t.allocator.free(content);
    try t.expectEqualStrings("disk", content);
}

test "closing an untitled document survives the destination confirmation" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "target.txt", "disk");
    const path = try tmp.dir.realPathFileAlloc(t.io, "target.txt", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    _ = try editor.newDocument();
    const id = editor.activeDoc().id;
    try editor.activeDoc().insertAtCursor("source");
    try t.expect(!editor.requestCloseDoc(editor.active_doc_idx));
    try t.expectEqual(Editor.CloseOutcome.needs_path, editor.resolveCloseDoc(.save));
    editor.startSaveAs(id, null);
    try t.expectEqual(Editor.SaveOutcome.destination_exists, editor.finishSaveAs(path));
    editor.resolveOverwrite(.overwrite);
    try t.expect(editor.docIndexForId(id) == null);
    // Closed only after its text reached the confirmed destination.
    const disk = try tmp.dir.readFileAlloc(t.io, "target.txt", t.allocator, .limited(100));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("source", disk);
}

test "window quit action keeps dirty documents until a decision" {
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    try editor.activeDoc().insertAtCursor("unsaved");
    try t.expect(editor.execAction("quit"));
    try t.expect(editor.running);
    try t.expectEqual(Editor.Mode.confirm_quit, editor.mode);
}

test "regression: invalid terminal scroll region must be ignored" {
    const cells = try t.allocator.alloc(terminal.Cell, 20 * 8);
    defer t.allocator.free(cells);
    @memset(cells, terminal.Cell{});
    var term: terminal.Terminal = .{
        .allocator = t.allocator,
        .io = t.io,
        .pty = .{ .allocator = t.allocator },
        .cells = cells,
        .cols = 20,
        .rows = 8,
        .scroll_bottom = 7,
    };
    term.processOutput("\x1b[999;1000r\x1b[T");
    // The region is unchanged — a clamped one (7..7) is in bounds too, and
    // would still break scrolling.
    try t.expectEqual(@as(u16, 0), term.scroll_top);
    try t.expectEqual(@as(u16, 7), term.scroll_bottom);
}

test "regression: workspace replacement keeps an open alias off disk" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "file.txt", "needle on disk");
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const absolute = try tmp.dir.realPathFileAlloc(t.io, "file.txt", t.allocator);
    defer t.allocator.free(absolute);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(cwd);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    try t.expect(editor.setFiletreeRoot(root));
    try editor.openIntoActive(absolute[cwd.len + 1 ..]);
    try editor.activeDoc().insertAtCursor("dirty ");
    editor.search.appendText("needle");
    editor.search.field = .replace;
    editor.search.appendText("replacement");
    editor.searchStart();
    var tries: usize = 0;
    while (editor.search.searching and tries < 500) : (tries += 1) {
        _ = editor.search.drain();
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    try t.expect(!editor.search.searching);
    const outcome = editor.search.executeReplace(&editor, .all);
    try t.expectEqual(@as(usize, 1), outcome.files);
    const disk = try tmp.dir.readFileAlloc(t.io, "file.txt", t.allocator, .limited(100));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("needle on disk", disk);
}

test "worker-regression: closing the editor before a Lua job completes" {
    const zlua = @import("zlua");
    var lua = try zlua.Lua.init(t.allocator);
    defer lua.deinit();
    lua.openLibs();
    var poison: PoisonAllocator = .{ .child = t.allocator };
    var editor = try Editor.init(poison.allocator(), t.io);
    @import("lua_settings.zig").registerApi(lua, &editor);
    if (@import("builtin").os.tag == .windows) try lua.doString("zide.spawn({'powershell', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', 'Start-Sleep -Milliseconds 200'}, function() error('stale callback') end)") else try lua.doString("zide.spawn({'sh', '-c', 'sleep 0.1'}, function() error('stale callback') end)");
    editor.deinit();
}

const PoisonAllocator = struct {
    child: std.mem.Allocator,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        @memset(memory, 0xdd);
        self.child.rawFree(memory, alignment, ra);
    }
};
