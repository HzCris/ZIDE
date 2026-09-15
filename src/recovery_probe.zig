//! Test-only child used to prove recovery survives abrupt process termination.
const std = @import("std");
const Document = @import("core/document.zig").Document;
const recovery = @import("core/recovery.zig");
const Editor = @import("core/editor.zig").Editor;
const workspace = @import("core/workspace_edit.zig");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) return error.InvalidProbeArguments;
    var manager = try recovery.Manager.init(a, init.io, args[1], args[1]);
    var editor = try Editor.init(a, init.io);
    editor.lsp_enabled = false;
    try editor.openIntoActive(args[2]);
    try editor.activeDoc().insertAtCursor("recovered café 😀\n");
    _ = try editor.openOrFocus(args[3]);
    try editor.activeDoc().insertAtCursor("second dirty\n");
    // Apply the same multi-file text-edit transaction used by symbol rename,
    // with both documents already dirty, then crash after capturing the result.
    const Change = struct { textDocument: struct { uri: []const u8, version: ?i32 = null }, edits: []const workspace.TextEdit };
    const edits: []const workspace.TextEdit = &.{.{ .range = .{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 1, .character = 8 },
    }, .newText = "renamed" }};
    const encoded = try std.json.Stringify.valueAlloc(a, .{ .documentChanges = [_]Change{
        .{ .textDocument = .{ .uri = try @import("core/lsp.zig").pathToUri(a, args[2]) }, .edits = edits },
        .{ .textDocument = .{ .uri = try @import("core/lsp.zig").pathToUri(a, args[3]) }, .edits = edits },
    } }, .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
    var plan = try workspace.Plan.parse(&editor, parsed.value, .utf16);
    try plan.apply(&editor);
    for (editor.documents.items) |*doc| try manager.captureSync(doc);
    var untitled = try Document.init(a);
    try untitled.insertAtCursor("untitled recovery\n");
    try manager.captureSync(&untitled);
    try @import("core/text_file.zig").atomicWrite(a, init.io, args[4], "ready");
    // The parent kills this process. No deinit or graceful recovery flush runs.
    while (true) try std.Io.sleep(init.io, .fromMilliseconds(1000), .awake);
}
