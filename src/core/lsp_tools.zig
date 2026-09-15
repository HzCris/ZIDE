//! Frontend-independent hover, rename preview, and formatting workflows.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("editor.zig").Editor;
const Document = @import("document.zig").Document;
const lsp = @import("lsp.zig");
const workspace = @import("workspace_edit.zig");

pub const State = struct {
    serial: u64 = 0,
    hover: ?[]u8 = null,
    scroll: usize = 0,
    name: [256]u8 = @splat(0),
    name_len: usize = 0,
    rename_context: ?lsp.Request = null,
    formatting: ?lsp.Request = null,
    preview: ?workspace.Plan = null,
    preview_server: ?u64 = null,
    preview_request: ?[]u8 = null,
    format_on_save: bool = false,
    save: ?struct { id: u64, options: Editor.SaveOptions, owned_path: ?[]u8 } = null,
    quit_after_format: bool = false,

    pub fn deinit(self: *State, allocator: Allocator) void {
        if (self.hover) |text| allocator.free(text);
        if (self.preview) |*plan| plan.deinit();
        if (self.preview_request) |id| allocator.free(id);
        self.clearSave(allocator);
    }

    fn clearSave(self: *State, allocator: Allocator) void {
        if (self.save) |save| if (save.owned_path) |path| allocator.free(path);
        self.save = null;
        self.quit_after_format = false;
    }

    fn clientFor(editor: *Editor, generation: u64) ?*lsp.LspClient {
        for (editor.lsp_clients.items) |client| if (client.generation == generation) return client;
        return null;
    }

    fn context(self: *State, doc: *Document, method: lsp.RequestMethod) lsp.Request {
        self.serial +%= 1;
        return .{ .method = method, .doc_id = doc.id, .version = doc.buffer.version, .cursor = doc.cursors.primary().offset, .serial = self.serial };
    }

    fn sync(editor: *Editor, client: *lsp.LspClient, doc: *Document, uri: []const u8) !void {
        _ = editor;
        if (!client.isReady() or !doc.lsp_opened) return error.ServerNotReady;
        if (doc.lsp_version != doc.lsp_last_synced) {
            try client.sendDidChange(uri, doc.lsp_version, doc.buffer.slice(0, doc.buffer.byteLen()));
            doc.lsp_last_synced = doc.lsp_version;
        }
    }

    pub fn start(self: *State, editor: *Editor, method: lsp.RequestMethod) void {
        self.startForDoc(editor, editor.activeDoc(), method) catch |err| {
            editor.status_message = std.fmt.bufPrint(&editor.status_buf, "LSP: {s}", .{@errorName(err)}) catch "LSP request failed";
        };
    }

    fn startForDoc(self: *State, editor: *Editor, doc: *Document, method: lsp.RequestMethod) !void {
        const client = editor.lspClientForDoc(doc) orelse return error.NoLanguageServer;
        const supported = switch (method) {
            .hover => client.capabilities.hover,
            .prepare_rename => client.capabilities.rename,
            .format_document => client.capabilities.format_document,
            .format_selection => client.capabilities.format_selection,
            else => false,
        };
        if (!supported) return error.FeatureNotSupported;
        if ((method == .format_document or method == .format_selection) and self.formatting != null) return error.FormattingInProgress;
        const path = doc.file_path orelse return error.UntitledDocument;
        const uri = try lsp.pathToUri(editor.allocator, path);
        defer editor.allocator.free(uri);
        try sync(editor, client, doc, uri);
        var request = self.context(doc, method);
        request.generation = client.generation;
        if (method == .prepare_rename and !client.capabilities.prepare_rename) {
            self.beginRename(editor, request, "");
            return;
        }
        const position = workspace.positionAt(doc, doc.cursors.primary().offset, client.position_encoding);
        const params = if (method == .format_document or method == .format_selection) blk: {
            const options = .{ .tabSize = editor.indentWidthFor(doc), .insertSpaces = !editor.useTabsFor(doc) };
            if (method == .format_document) break :blk try std.json.Stringify.valueAlloc(editor.allocator, .{ .textDocument = .{ .uri = uri }, .options = options }, .{});
            const selection = doc.cursors.primary().selectionRange() orelse return error.NoSelection;
            break :blk try std.json.Stringify.valueAlloc(editor.allocator, .{ .textDocument = .{ .uri = uri }, .options = options, .range = lsp.LspRange{
                .start = workspace.positionAt(doc, selection.start, client.position_encoding),
                .end = workspace.positionAt(doc, selection.end, client.position_encoding),
            } }, .{});
        } else try std.json.Stringify.valueAlloc(editor.allocator, .{ .textDocument = .{ .uri = uri }, .position = position }, .{});
        defer editor.allocator.free(params);
        const name = switch (method) {
            .hover => "textDocument/hover",
            .prepare_rename => "textDocument/prepareRename",
            .format_document => "textDocument/formatting",
            .format_selection => "textDocument/rangeFormatting",
            else => unreachable,
        };
        _ = try client.request(name, params, request);
        if (method == .format_document or method == .format_selection) self.formatting = request;
        editor.status_message = "Waiting for language server";
    }

    pub fn maybeFormatSave(self: *State, editor: *Editor, doc: *Document, options: Editor.SaveOptions) !bool {
        if (!self.format_on_save or options.skip_format) return false;
        const client = editor.lspClientForDoc(doc) orelse return false;
        if (!client.capabilities.format_document) return false;
        if (self.save) |save| if (save.id == doc.id) return true;
        if (self.formatting != null) return error.FormattingInProgress;
        const path = if (options.path) |p| try editor.allocator.dupe(u8, p) else null;
        errdefer if (path) |p| editor.allocator.free(p);
        var held = options;
        held.path = path;
        try self.startForDoc(editor, doc, .format_document);
        self.save = .{ .id = doc.id, .options = held, .owned_path = path };
        return true;
    }

    fn beginRename(self: *State, editor: *Editor, request: lsp.Request, placeholder: []const u8) void {
        self.rename_context = request;
        self.name_len = @min(placeholder.len, self.name.len - 1);
        while (self.name_len > 0 and !std.unicode.utf8ValidateSlice(placeholder[0..self.name_len])) self.name_len -= 1;
        @memcpy(self.name[0..self.name_len], placeholder[0..self.name_len]);
        @memset(self.name[self.name_len..], 0);
        editor.mode = .symbol_rename;
    }

    pub fn submitRename(self: *State, editor: *Editor) void {
        self.sendRename(editor) catch |err| {
            editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Rename: {s}", .{@errorName(err)}) catch "Rename failed";
        };
    }
    fn sendRename(self: *State, editor: *Editor) !void {
        const context_before = self.rename_context orelse return error.NoRenameRequest;
        const index = editor.docIndexForId(context_before.doc_id.?) orelse return error.DocumentClosed;
        const doc = &editor.documents.items[index];
        if (doc.buffer.version != context_before.version) return error.StaleDocument;
        if (self.name_len == 0) return error.EmptyName;
        const client = clientFor(editor, context_before.generation) orelse return error.ServerStopped;
        const uri = try lsp.pathToUri(editor.allocator, doc.file_path orelse return error.UntitledDocument);
        defer editor.allocator.free(uri);
        var request = self.context(doc, .rename);
        request.cursor = context_before.cursor;
        const params = try std.json.Stringify.valueAlloc(editor.allocator, .{
            .textDocument = .{ .uri = uri },
            .newName = self.name[0..self.name_len],
            .position = workspace.positionAt(doc, context_before.cursor.?, client.position_encoding),
        }, .{});
        defer editor.allocator.free(params);
        _ = try client.request("textDocument/rename", params, request);
        self.rename_context = null;
        editor.mode = .normal;
        editor.status_message = "Preparing rename preview";
    }

    pub fn response(self: *State, editor: *Editor, client: *lsp.LspClient, request: lsp.Request, json: []const u8) void {
        self.handleResponse(editor, client, request, json) catch |err| self.failed(editor, client, request, @errorName(err));
    }

    fn handleResponse(self: *State, editor: *Editor, client: *lsp.LspClient, request: lsp.Request, json: []const u8) !void {
        if (request.method == .hover or request.method == .prepare_rename or request.method == .rename) {
            if (request.serial != self.serial or editor.mode != .normal) return;
        } else if (self.formatting == null or self.formatting.?.serial != request.serial or self.formatting.?.generation != client.generation) return;
        const parsed = try std.json.parseFromSlice(std.json.Value, editor.allocator, json, .{});
        defer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
        const index = editor.docIndexForId(request.doc_id.?) orelse return error.DocumentClosed;
        const doc = &editor.documents.items[index];
        switch (request.method) {
            .hover => {
                if (result == .null) {
                    editor.status_message = "No hover information";
                    return;
                }
                if (doc.id != editor.activeDoc().id or doc.cursors.primary().offset != request.cursor.?) return;
                if (result != .object) return error.InvalidResponse;
                var text: std.ArrayList(u8) = .empty;
                errdefer text.deinit(editor.allocator);
                try hoverText(editor.allocator, &text, result.object.get("contents") orelse return error.InvalidResponse);
                if (self.hover) |old| editor.allocator.free(old);
                self.hover = try text.toOwnedSlice(editor.allocator);
                self.scroll = 0;
                editor.mode = .lsp_panel;
            },
            .prepare_rename => {
                if (doc.id != editor.activeDoc().id or doc.cursors.primary().offset != request.cursor.?) return;
                if (result == .null) return error.CannotRenameHere;
                if (result != .object) return error.InvalidResponse;
                if (result.object.get("range")) |range| {
                    const parsed_range = try std.json.parseFromValue(lsp.LspRange, editor.allocator, range, .{});
                    defer parsed_range.deinit();
                    _ = try workspace.offset(doc, parsed_range.value.start, client.position_encoding);
                    _ = try workspace.offset(doc, parsed_range.value.end, client.position_encoding);
                } else if (result.object.contains("start")) {
                    const range = try std.json.parseFromValue(lsp.LspRange, editor.allocator, result, .{});
                    defer range.deinit();
                    _ = try workspace.offset(doc, range.value.start, client.position_encoding);
                    _ = try workspace.offset(doc, range.value.end, client.position_encoding);
                } else {
                    const default_behavior = result.object.get("defaultBehavior") orelse return error.InvalidResponse;
                    if (default_behavior != .bool or !default_behavior.bool) return error.CannotRenameHere;
                }
                const placeholder = result.object.get("placeholder");
                self.beginRename(editor, request, if (placeholder != null and placeholder.? == .string) placeholder.?.string else "");
            },
            .rename => {
                if (result == .null) {
                    editor.status_message = "No rename edits";
                    return;
                }
                try self.makePreview(editor, result, client.position_encoding);
            },
            .format_document, .format_selection => {
                var group: ?u64 = null;
                if (result != .null) {
                    const uri = try lsp.pathToUri(editor.allocator, doc.file_path.?);
                    defer editor.allocator.free(uri);
                    var changes: std.json.ObjectMap = .empty;
                    defer changes.deinit(editor.allocator);
                    try changes.put(editor.allocator, uri, result);
                    var object: std.json.ObjectMap = .empty;
                    defer object.deinit(editor.allocator);
                    try object.put(editor.allocator, "changes", .{ .object = changes });
                    var plan = try workspace.Plan.parse(editor, .{ .object = object }, client.position_encoding);
                    defer plan.deinit();
                    try plan.apply(editor);
                    if (plan.edit_count > 0 and doc.history.undo_stack.items.len > 0) group = doc.history.undo_stack.items[doc.history.undo_stack.items.len - 1].group_id;
                }
                self.formatting = null;
                editor.status_message = "Formatting applied";
                if (self.save) |save| {
                    var options = save.options;
                    options.skip_format = true;
                    options.format_group = group;
                    const quit = self.quit_after_format;
                    // Clear ownership before hooks can start another operation.
                    self.save = null;
                    self.quit_after_format = false;
                    defer if (save.owned_path) |path| editor.allocator.free(path);
                    const outcome = editor.saveDocument(save.id, options);
                    if (quit and outcome == .saved) {
                        const saved_index = editor.docIndexForId(save.id);
                        if (saved_index == null or !editor.documents.items[saved_index.?].dirty) editor.saveAllAndQuit();
                    }
                }
            },
            else => {},
        }
    }

    pub fn failed(self: *State, editor: *Editor, client: *lsp.LspClient, request: lsp.Request, reason: []const u8) void {
        var saving = false;
        if (self.formatting) |format| if (format.serial == request.serial and format.generation == client.generation) {
            saving = self.save != null;
            if (saving and editor.close_after_save_id == request.doc_id) editor.close_after_save_id = null;
            self.formatting = null;
            self.clearSave(editor.allocator);
        };
        if (saving or request.method == .hover or request.method == .prepare_rename or request.method == .rename or request.method == .format_document or request.method == .format_selection)
            editor.status_message = std.fmt.bufPrint(&editor.status_buf, "{s}: {s}", .{ if (saving) "Save aborted" else "LSP request failed", reason }) catch "LSP request failed";
    }

    fn makePreview(self: *State, editor: *Editor, value: std.json.Value, encoding: workspace.Encoding) !void {
        if (self.preview != null or editor.mode != .normal) return error.EditorBusy;
        self.preview = try workspace.Plan.parse(editor, value, encoding);
        self.scroll = 0;
        editor.mode = .workspace_preview;
    }

    pub fn serverEdit(self: *State, editor: *Editor, client: *lsp.LspClient, id: std.json.Value, json: []const u8) void {
        self.receiveServerEdit(editor, client, id, json) catch |err| {
            const result = std.json.Stringify.valueAlloc(editor.allocator, .{ .applied = false, .failureReason = @errorName(err) }, .{}) catch return;
            defer editor.allocator.free(result);
            client.respond(id, result);
        };
    }
    fn receiveServerEdit(self: *State, editor: *Editor, client: *lsp.LspClient, id: std.json.Value, json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, editor.allocator, json, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params") orelse return error.InvalidRequest;
        if (params != .object) return error.InvalidRequest;
        const request_id = try std.json.Stringify.valueAlloc(editor.allocator, id, .{});
        errdefer editor.allocator.free(request_id);
        try self.makePreview(editor, params.object.get("edit") orelse return error.InvalidRequest, client.position_encoding);
        self.preview_server = client.generation;
        self.preview_request = request_id;
    }

    pub fn resolvePreview(self: *State, editor: *Editor, apply: bool) void {
        var applied = false;
        var reason: []const u8 = "Cancelled by user";
        if (self.preview) |*plan| {
            if (apply) {
                if (plan.apply(editor)) |_| {
                    applied = true;
                } else |err| reason = @errorName(err);
            }
            plan.deinit();
            self.preview = null;
        }
        if (self.preview_request) |json| {
            defer editor.allocator.free(json);
            if (self.preview_server) |generation| if (clientFor(editor, generation)) |client| {
                const id = std.json.parseFromSlice(std.json.Value, editor.allocator, json, .{}) catch null;
                if (id) |parsed| {
                    defer parsed.deinit();
                    const response_json = std.json.Stringify.valueAlloc(editor.allocator, .{ .applied = applied, .failureReason = if (applied) "" else reason }, .{}) catch null;
                    if (response_json) |result| {
                        defer editor.allocator.free(result);
                        client.respond(parsed.value, result);
                    }
                }
            };
        }
        self.preview_request = null;
        self.preview_server = null;
        editor.mode = .normal;
        editor.status_message = if (applied) "Workspace edits applied; review and save the dirty files" else std.fmt.bufPrint(&editor.status_buf, "Workspace edit: {s}", .{reason}) catch "Workspace edit cancelled";
    }

    pub fn clientStopped(self: *State, editor: *Editor, client: *lsp.LspClient) void {
        if (self.formatting) |request| if (request.generation == client.generation) self.failed(editor, client, request, "Language server stopped");
        if (self.rename_context) |request| if (request.generation == client.generation) {
            self.rename_context = null;
            if (editor.mode == .symbol_rename) editor.mode = .normal;
        };
        if (self.preview_server == client.generation) self.resolvePreview(editor, false);
    }
};

fn hoverText(allocator: Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .string => |text| {
            if (out.items.len + text.len > 64 * 1024) return error.HoverTooLarge;
            for (text) |byte| try out.append(allocator, if (byte < 32 and byte != '\n' and byte != '\t') ' ' else byte);
        },
        .object => try hoverText(allocator, out, value.object.get("value") orelse return error.InvalidHover),
        .array => |items| for (items.items, 0..) |item, i| {
            if (i > 0) try out.appendSlice(allocator, "\n\n");
            try hoverText(allocator, out, item);
        },
        else => return error.InvalidHover,
    }
}
