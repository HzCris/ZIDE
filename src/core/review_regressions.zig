const std = @import("std");
const t = std.testing;
const Editor = @import("editor.zig").Editor;
const lsp = @import("lsp.zig");
const terminal = @import("terminal.zig");

fn writeFile(dir: std.Io.Dir, path: []const u8, text: []const u8) !void {
    const f = try dir.createFile(t.io, path, .{});
    defer f.close(t.io);
    try f.writeStreamingAll(t.io, text);
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
    try t.expect(term.scroll_top < term.rows);
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
