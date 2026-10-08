//! Frontend-independent hover, rename preview, and formatting workflows.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("editor.zig").Editor;
const Document = @import("document.zig").Document;
const lsp = @import("lsp.zig");
const workspace = @import("workspace_edit.zig");
const diagnostics = @import("diagnostics.zig");

pub const State = struct {
    /// Latest hover / prepare-rename / rename request; older replies are stale.
    serial: u64 = 0,
    /// Formatting's own counter: a format-on-save must not make an in-flight
    /// hover or rename reply look stale.
    format_serial: u64 = 0,
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
    /// The formatting reply for `save` arrived (edits applied, `save.options`
    /// updated): `tick` performs the save after the poll loop. Saving from
    /// inside message dispatch ran Lua save hooks that could stop the client
    /// still being polled.
    pending_post_format_save: ?u64 = null,
    quit_after_format: bool = false,
    /// Where a goto-definition reply points; `tick` opens it after the poll
    /// loop. Opening fires Lua `open` hooks, which may restart language
    /// servers — freeing the client whose reply was being dispatched.
    pending_definition: ?Jump = null,
    /// The last `textDocument/references` reply, shown by the tool panel's
    /// References view. Owned.
    references: std.ArrayList(Reference) = .empty,
    references_symbol: [128]u8 = undefined,
    references_symbol_len: usize = 0,
    /// Locations behind the symbol pickers' rows (payload = index). Owned.
    symbols: std.ArrayList(SymbolLoc) = .empty,
    symbol_query: [256]u8 = undefined,
    symbol_query_len: usize = 0,
    /// Set by `startQuiet`: automatic requests leave the status bar alone.
    quiet: bool = false,

    pub const Reference = struct {
        path: []const u8,
        line: u32,
        col: u32,
        columns: diagnostics.Columns,
        excerpt: []u8,
    };
    pub const max_references: usize = 2000;
    pub const SymbolLoc = struct { path: []const u8, line: u32, col: u32, columns: diagnostics.Columns };
    pub const max_symbols: usize = 5000;

    pub const Jump = struct {
        /// Owned (the editor's allocator).
        path: []u8,
        position: lsp.LspPosition,
        encoding: workspace.Encoding,
    };

    pub fn deinit(self: *State, allocator: Allocator) void {
        self.clearReferences(allocator);
        self.references.deinit(allocator);
        self.clearSymbols(allocator);
        self.symbols.deinit(allocator);
        if (self.hover) |text| allocator.free(text);
        if (self.preview) |*plan| plan.deinit();
        if (self.preview_request) |id| allocator.free(id);
        self.clearSave(allocator);
        if (self.pending_definition) |jump| allocator.free(jump.path);
        self.pending_definition = null;
    }

    /// Remember a goto-definition target for `tick` (message dispatch must
    /// not open files). A newer reply replaces an older unhandled one.
    pub fn queueDefinition(self: *State, editor: *Editor, path: []const u8, position: lsp.LspPosition, encoding: workspace.Encoding) void {
        const owned = editor.allocator.dupe(u8, path) catch return;
        if (self.pending_definition) |old| editor.allocator.free(old.path);
        self.pending_definition = .{ .path = owned, .position = position, .encoding = encoding };
    }

    fn jumpToDefinition(self: *State, editor: *Editor) void {
        const jump = self.pending_definition orelse return;
        self.pending_definition = null;
        defer editor.allocator.free(jump.path);
        const doc = editor.navOpen(jump.path) catch |err| {
            // The encoding picker the open raised says what to do next.
            if (err != error.EncodingRequired and err != error.BinaryFile) {
                editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Go to definition: {s}", .{@errorName(err)}) catch "Go to definition failed";
            }
            return;
        };
        const byte = workspace.offset(doc, jump.position, jump.encoding) catch return;
        doc.gotoLine(jump.position.line +| 1);
        doc.cursors.primary().offset = byte;
        doc.cursors.primary().preferred_col = doc.buffer.offsetToPos(byte).col;
    }

    pub fn clearReferences(self: *State, allocator: Allocator) void {
        for (self.references.items) |r| {
            allocator.free(r.path);
            allocator.free(r.excerpt);
        }
        self.references.clearRetainingCapacity();
    }

    pub fn referencesSymbol(self: *const State) []const u8 {
        return self.references_symbol[0..self.references_symbol_len];
    }

    // ----- Symbol pickers -----

    pub fn clearSymbols(self: *State, allocator: Allocator) void {
        for (self.symbols.items) |s| allocator.free(s.path);
        self.symbols.clearRetainingCapacity();
    }

    /// `lsp_workspace_symbols`: open the picker at once; every edit of its
    /// filter asks the server for that query.
    pub fn beginWorkspaceSymbols(self: *State, editor: *Editor) void {
        self.clearSymbols(editor.allocator);
        editor.picker.begin("Workspace symbols", pickSymbol, workspaceQuery, "Type to search the workspace");
        editor.openPicker();
    }

    fn isWorkspacePicker(editor: *Editor) bool {
        const cb = editor.picker.on_query orelse return false;
        return cb == workspaceQuery;
    }

    fn workspaceQuery(editor: *Editor, query: []const u8) void {
        const self = &editor.lsp_tools;
        if (query.len == 0) {
            self.clearSymbols(editor.allocator);
            editor.picker.clearItems();
            return;
        }
        self.symbol_query_len = @min(query.len, self.symbol_query.len);
        @memcpy(self.symbol_query[0..self.symbol_query_len], query[0..self.symbol_query_len]);
        self.startForDoc(editor, editor.activeDoc(), .workspace_symbol) catch |err| {
            editor.status_message = std.fmt.bufPrint(&editor.status_buf, "LSP: {s}", .{@errorName(err)}) catch "LSP request failed";
        };
    }

    fn pickSymbol(editor: *Editor, payload: u64) void {
        const self = &editor.lsp_tools;
        if (payload >= self.symbols.items.len) return;
        const s = self.symbols.items[payload];
        editor.jumpToLocation(s.path, s.line, s.col, s.columns);
    }

    fn symbolKindName(kind: ?std.json.Value) []const u8 {
        const k = kind orelse return "";
        if (k != .integer) return "";
        return switch (k.integer) {
            1 => "file",
            2 => "module",
            3 => "namespace",
            4 => "package",
            5 => "class",
            6 => "method",
            7 => "property",
            8 => "field",
            9 => "constructor",
            10 => "enum",
            11 => "interface",
            12 => "function",
            13 => "variable",
            14 => "constant",
            15 => "string",
            16 => "number",
            17 => "boolean",
            18 => "array",
            19 => "object",
            20 => "key",
            21 => "null",
            22 => "enum member",
            23 => "struct",
            24 => "event",
            25 => "operator",
            26 => "type parameter",
            else => "",
        };
    }

    fn clampIndex(value: ?std.json.Value, len: usize) usize {
        const v = value orelse return 0;
        if (v != .integer or v.integer < 0) return 0;
        const i: usize = @intCast(v.integer);
        return if (i < len) i else 0;
    }

    /// `documentation` is a string or a MarkupContent `{kind, value}`.
    fn documentationText(value: ?std.json.Value) []const u8 {
        const v = value orelse return "";
        return switch (v) {
            .string => |s| s,
            .object => |o| if (o.get("value")) |inner| (if (inner == .string) inner.string else "") else "",
            else => "",
        };
    }

    fn firstLine(text: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
        return std.mem.trimEnd(u8, trimmed[0..end], " \t\r");
    }

    fn rangeStart(allocator: Allocator, value: std.json.Value) ?lsp.LspPosition {
        const parsed = std.json.parseFromValue(lsp.LspRange, allocator, value, .{}) catch return null;
        defer parsed.deinit();
        return parsed.value.start;
    }

    fn rememberSymbol(self: *State, editor: *Editor, client: *lsp.LspClient, path: []const u8, pos: lsp.LspPosition) !u64 {
        if (self.symbols.items.len >= max_symbols) return error.TooManySymbols;
        const owned = try editor.allocator.dupe(u8, path);
        errdefer editor.allocator.free(owned);
        try self.symbols.append(editor.allocator, .{ .path = owned, .line = pos.line, .col = pos.character, .columns = if (client.position_encoding == .utf16) .utf16 else .bytes });
        return self.symbols.items.len - 1;
    }

    /// One `DocumentSymbol` (with its children) or `SymbolInformation`
    /// from a documentSymbol reply, as picker rows.
    fn addDocumentSymbol(self: *State, editor: *Editor, client: *lsp.LspClient, path: []const u8, value: std.json.Value, parent: []const u8) !void {
        if (value != .object) return;
        const name = value.object.get("name") orelse return;
        if (name != .string) return;
        const kind = symbolKindName(value.object.get("kind"));
        var pos: ?lsp.LspPosition = null;
        if (value.object.get("selectionRange") orelse value.object.get("range")) |r| {
            pos = rangeStart(editor.allocator, r);
        } else if (value.object.get("location")) |loc| {
            if (loc == .object) if (loc.object.get("range")) |r| {
                pos = rangeStart(editor.allocator, r);
            };
        }
        const at = pos orelse return;
        const payload = self.rememberSymbol(editor, client, path, at) catch |err| switch (err) {
            error.TooManySymbols => return,
            else => return err,
        };
        var detail_buf: [160]u8 = undefined;
        const detail = if (parent.len > 0) std.fmt.bufPrint(&detail_buf, "{s} in {s}", .{ kind, parent }) catch kind else kind;
        try editor.picker.add(name.string, detail, payload);
        if (value.object.get("children")) |children| {
            if (children == .array) {
                for (children.array.items) |child| try self.addDocumentSymbol(editor, client, path, child, name.string);
            }
        }
    }

    /// One `SymbolInformation` from a workspace/symbol reply, as a picker row.
    fn addSymbolInformation(self: *State, editor: *Editor, client: *lsp.LspClient, value: std.json.Value) !void {
        if (value != .object) return;
        const name = value.object.get("name") orelse return;
        if (name != .string) return;
        const loc = value.object.get("location") orelse return;
        if (loc != .object) return;
        const uri = loc.object.get("uri") orelse return;
        if (uri != .string) return;
        const range = loc.object.get("range") orelse return;
        const at = rangeStart(editor.allocator, range) orelse return;
        const path = lsp.uriToPath(editor.allocator, uri.string) catch return;
        defer editor.allocator.free(path);
        const payload = self.rememberSymbol(editor, client, path, at) catch |err| switch (err) {
            error.TooManySymbols => return,
            else => return err,
        };
        const kind = symbolKindName(value.object.get("kind"));
        const container = value.object.get("containerName");
        var detail_buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{s}{s}{s} · {s}:{d}", .{
            kind,
            if (container != null and container.? == .string and container.?.string.len > 0) " in " else "",
            if (container != null and container.? == .string) container.?.string else "",
            std.fs.path.basename(path),
            at.line + 1,
        }) catch kind;
        try editor.picker.add(name.string, detail, payload);
    }

    fn identByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
    }

    /// The identifier around the caret, for the References view's title.
    fn captureSymbol(self: *State, doc: *Document) void {
        const caret = doc.cursors.primary().offset;
        var lo = caret;
        while (lo > 0 and identByte(doc.buffer.byteAt(lo - 1) orelse 0)) lo -= 1;
        var hi = caret;
        while (identByte(doc.buffer.byteAt(hi) orelse 0)) hi += 1;
        const n = @min(hi - lo, self.references_symbol.len);
        var i: usize = 0;
        while (i < n) : (i += 1) self.references_symbol[i] = doc.buffer.byteAt(lo + i) orelse 0;
        self.references_symbol_len = n;
    }

    const ExcerptCache = struct {
        path: ?[]u8 = null,
        text: ?[]u8 = null,

        fn deinit(self: *ExcerptCache, allocator: Allocator) void {
            if (self.path) |p| allocator.free(p);
            if (self.text) |t| allocator.free(t);
            self.* = .{};
        }
    };

    /// The trimmed text of `line` in `path`: from the open document
    /// (unsaved edits included), else from disk — one read per file.
    fn excerptFor(editor: *Editor, path: []const u8, line: u32, cache: *ExcerptCache) ![]u8 {
        if (editor.findDocument(path) catch null) |index| {
            const doc = &editor.documents.items[index];
            return trimmedExcerpt(editor.allocator, if (line < doc.lineCount()) doc.lineContent(line) else "");
        }
        if (cache.path == null or !std.mem.eql(u8, cache.path.?, path)) {
            cache.deinit(editor.allocator);
            cache.path = try editor.allocator.dupe(u8, path);
            cache.text = std.Io.Dir.cwd().readFileAlloc(editor.io, path, editor.allocator, .limited(4 * 1024 * 1024)) catch null;
        }
        const text = cache.text orelse return trimmedExcerpt(editor.allocator, "");
        var lines = std.mem.splitScalar(u8, text, '\n');
        var i: u32 = 0;
        while (lines.next()) |l| : (i += 1) {
            if (i == line) return trimmedExcerpt(editor.allocator, l);
        }
        return trimmedExcerpt(editor.allocator, "");
    }

    fn trimmedExcerpt(allocator: Allocator, line: []const u8) ![]u8 {
        var text = std.mem.trim(u8, line, " \t\r");
        if (text.len > 120) {
            var cut: usize = 120;
            while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
            text = text[0..cut];
        }
        return allocator.dupe(u8, text);
    }

    fn clearSave(self: *State, allocator: Allocator) void {
        if (self.save) |save| if (save.owned_path) |path| allocator.free(path);
        self.save = null;
        self.pending_post_format_save = null;
        self.quit_after_format = false;
    }

    /// Run work deferred out of message dispatch (the goto-definition jump,
    /// the post-format save). Called by `Editor.lspTick` after polling
    /// every client.
    pub fn tick(self: *State, editor: *Editor) void {
        self.jumpToDefinition(editor);
        const id = self.pending_post_format_save orelse return;
        self.pending_post_format_save = null;
        const save = self.save orelse return;
        if (save.id != id) return;
        const quit = self.quit_after_format;
        // Clear ownership before hooks can start another operation.
        self.save = null;
        self.quit_after_format = false;
        defer if (save.owned_path) |path| editor.allocator.free(path);
        const outcome = editor.saveDocument(save.id, save.options);
        if (quit and outcome == .saved) {
            const saved_index = editor.docIndexForId(save.id);
            if (saved_index == null or !editor.documents.items[saved_index.?].dirty) editor.saveAllAndQuit();
        }
    }

    fn clientFor(editor: *Editor, generation: u64) ?*lsp.LspClient {
        for (editor.lsp_clients.items) |client| if (client.generation == generation) return client;
        return null;
    }

    fn isFormatting(method: lsp.RequestMethod) bool {
        return method == .format_document or method == .format_selection;
    }

    fn context(self: *State, doc: *Document, method: lsp.RequestMethod) lsp.Request {
        const counter = if (isFormatting(method)) &self.format_serial else &self.serial;
        counter.* +%= 1;
        return .{ .method = method, .doc_id = doc.id, .version = doc.buffer.version, .cursor = doc.cursors.primary().offset, .serial = counter.* };
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

    /// `start` for automatic requests (typing a trigger character): no
    /// status-bar chatter on the way out, and failures stay silent.
    pub fn startQuiet(self: *State, editor: *Editor, method: lsp.RequestMethod) void {
        self.quiet = true;
        defer self.quiet = false;
        self.startForDoc(editor, editor.activeDoc(), method) catch {};
    }

    fn startForDoc(self: *State, editor: *Editor, doc: *Document, method: lsp.RequestMethod) !void {
        const client = editor.lspClientForDoc(doc) orelse return error.NoLanguageServer;
        const supported = switch (method) {
            .hover => client.capabilities.hover,
            .prepare_rename => client.capabilities.rename,
            .format_document => client.capabilities.format_document,
            .format_selection => client.capabilities.format_selection,
            .references => client.capabilities.references,
            .document_symbol => client.capabilities.document_symbol,
            .workspace_symbol => client.capabilities.workspace_symbol,
            .signature_help => client.capabilities.signature_help,
            else => false,
        };
        if (!supported) return error.FeatureNotSupported;
        if (isFormatting(method) and self.formatting != null) return error.FormattingInProgress;
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
        const params = if (isFormatting(method)) blk: {
            const options = .{ .tabSize = editor.indentWidthFor(doc), .insertSpaces = !editor.useTabsFor(doc) };
            if (method == .format_document) break :blk try std.json.Stringify.valueAlloc(editor.allocator, .{ .textDocument = .{ .uri = uri }, .options = options }, .{});
            const selection = doc.cursors.primary().selectionRange() orelse return error.NoSelection;
            break :blk try std.json.Stringify.valueAlloc(editor.allocator, .{ .textDocument = .{ .uri = uri }, .options = options, .range = lsp.LspRange{
                .start = workspace.positionAt(doc, selection.start, client.position_encoding),
                .end = workspace.positionAt(doc, selection.end, client.position_encoding),
            } }, .{});
        } else if (method == .references) try std.json.Stringify.valueAlloc(editor.allocator, .{ .textDocument = .{ .uri = uri }, .position = position, .context = .{ .includeDeclaration = true } }, .{}) else if (method == .document_symbol) try std.json.Stringify.valueAlloc(editor.allocator, .{ .textDocument = .{ .uri = uri } }, .{}) else if (method == .workspace_symbol) try std.json.Stringify.valueAlloc(editor.allocator, .{ .query = self.symbol_query[0..self.symbol_query_len] }, .{}) else try std.json.Stringify.valueAlloc(editor.allocator, .{ .textDocument = .{ .uri = uri }, .position = position }, .{});
        defer editor.allocator.free(params);
        if (method == .references) self.captureSymbol(doc);
        const name = switch (method) {
            .hover => "textDocument/hover",
            .references => "textDocument/references",
            .document_symbol => "textDocument/documentSymbol",
            .workspace_symbol => "workspace/symbol",
            .signature_help => "textDocument/signatureHelp",
            .prepare_rename => "textDocument/prepareRename",
            .format_document => "textDocument/formatting",
            .format_selection => "textDocument/rangeFormatting",
            else => unreachable,
        };
        _ = try client.request(name, params, request);
        if (isFormatting(method)) self.formatting = request;
        if (!self.quiet) editor.status_message = "Waiting for language server";
    }

    pub fn maybeFormatSave(self: *State, editor: *Editor, doc: *Document, options: Editor.SaveOptions) !bool {
        if (!self.format_on_save or options.skip_format) return false;
        const client = editor.lspClientForDoc(doc) orelse return false;
        if (!client.capabilities.format_document) return false;
        if (self.save) |save| if (save.id == doc.id) return true;
        // `save` outlives `formatting` until `tick` runs the post-format save.
        if (self.formatting != null or self.save != null) return error.FormattingInProgress;
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
        editor.setMode(.symbol_rename);
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
        editor.setMode(.normal);
        editor.status_message = "Preparing rename preview";
    }

    pub fn response(self: *State, editor: *Editor, client: *lsp.LspClient, request: lsp.Request, json: []const u8) void {
        self.handleResponse(editor, client, request, json) catch |err| self.failed(editor, client, request, @errorName(err));
    }

    fn handleResponse(self: *State, editor: *Editor, client: *lsp.LspClient, request: lsp.Request, json: []const u8) !void {
        if (request.method == .hover or request.method == .prepare_rename or request.method == .rename or request.method == .references or request.method == .document_symbol or request.method == .workspace_symbol or request.method == .signature_help) {
            if (request.serial != self.serial) return;
            // Workspace symbol replies land while the picker is open.
            const mode_ok = editor.mode == .normal or (request.method == .workspace_symbol and editor.mode == .picker);
            if (!mode_ok) return;
        } else if (!self.isCurrentFormatting(client, request)) return;
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
                editor.setMode(.lsp_panel);
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
            .references => {
                self.clearReferences(editor.allocator);
                if (result == .null) {
                    editor.status_message = "No references found";
                    return;
                }
                if (result != .array) return error.InvalidResponse;
                var cache: ExcerptCache = .{};
                defer cache.deinit(editor.allocator);
                for (result.array.items) |item| {
                    if (self.references.items.len >= max_references) break;
                    if (item != .object) continue;
                    const uri = item.object.get("uri") orelse continue;
                    if (uri != .string) continue;
                    const range_value = item.object.get("range") orelse continue;
                    const range = std.json.parseFromValue(lsp.LspRange, editor.allocator, range_value, .{}) catch continue;
                    defer range.deinit();
                    const path = lsp.uriToPath(editor.allocator, uri.string) catch continue;
                    const excerpt = excerptFor(editor, path, range.value.start.line, &cache) catch {
                        editor.allocator.free(path);
                        continue;
                    };
                    self.references.append(editor.allocator, .{
                        .path = path,
                        .line = range.value.start.line,
                        .col = range.value.start.character,
                        .columns = if (client.position_encoding == .utf16) .utf16 else .bytes,
                        .excerpt = excerpt,
                    }) catch {
                        editor.allocator.free(path);
                        editor.allocator.free(excerpt);
                        break;
                    };
                }
                if (self.references.items.len == 0) {
                    editor.status_message = "No references found";
                    return;
                }
                editor.status_message = std.fmt.bufPrint(&editor.status_buf, "References to {s}: {d}", .{ self.referencesSymbol(), self.references.items.len }) catch "References found";
                editor.tool_panel.show(editor, .references);
            },
            .document_symbol => {
                self.clearSymbols(editor.allocator);
                if (result == .null) {
                    editor.status_message = "No symbols";
                    return;
                }
                if (result != .array) return error.InvalidResponse;
                const path = doc.file_path orelse return error.UntitledDocument;
                var title_buf: [96]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "Symbols in {s}", .{std.fs.path.basename(path)}) catch "Symbols";
                editor.picker.begin(title, pickSymbol, null, "No symbols");
                for (result.array.items) |item| try self.addDocumentSymbol(editor, client, path, item, "");
                if (self.symbols.items.len == 0) {
                    editor.status_message = "No symbols";
                    return;
                }
                editor.status_message = "";
                editor.openPicker();
            },
            .signature_help => {
                if (doc.id != editor.activeDoc().id) return;
                if (result == .null) {
                    editor.clearSignature();
                    if (!self.quiet) editor.status_message = "No signature help here";
                    return;
                }
                if (result != .object) return error.InvalidResponse;
                const sigs = result.object.get("signatures") orelse return error.InvalidResponse;
                if (sigs != .array or sigs.array.items.len == 0) {
                    editor.clearSignature();
                    return;
                }
                const sig = sigs.array.items[clampIndex(result.object.get("activeSignature"), sigs.array.items.len)];
                if (sig != .object) return error.InvalidResponse;
                const label_v = sig.object.get("label") orelse return error.InvalidResponse;
                if (label_v != .string) return error.InvalidResponse;
                const label = label_v.string;
                var p_start: usize = 0;
                var p_end: usize = 0;
                var doc_text = documentationText(sig.object.get("documentation"));
                if (sig.object.get("parameters")) |params_v| {
                    if (params_v == .array and params_v.array.items.len > 0) {
                        const active = clampIndex(sig.object.get("activeParameter") orelse result.object.get("activeParameter"), params_v.array.items.len);
                        const param = params_v.array.items[active];
                        if (param == .object) {
                            if (param.object.get("label")) |pl| {
                                if (pl == .string) {
                                    // A string label names the parameter; find it after the opening paren.
                                    const open = std.mem.indexOfScalar(u8, label, '(') orelse 0;
                                    if (std.mem.indexOfPos(u8, label, open, pl.string)) |at| {
                                        p_start = at;
                                        p_end = at + pl.string.len;
                                    }
                                } else if (pl == .array and pl.array.items.len == 2 and pl.array.items[0] == .integer and pl.array.items[1] == .integer) {
                                    p_start = @intCast(@max(0, pl.array.items[0].integer));
                                    p_end = @intCast(@max(0, pl.array.items[1].integer));
                                }
                            }
                            const pd = documentationText(param.object.get("documentation"));
                            if (pd.len > 0) doc_text = pd;
                        }
                    }
                }
                try editor.setSignature(label, p_start, p_end, firstLine(doc_text));
                if (!self.quiet) editor.status_message = "";
            },
            .workspace_symbol => {
                // Only while the workspace picker is still the one open.
                if (editor.mode != .picker or !isWorkspacePicker(editor)) return;
                self.clearSymbols(editor.allocator);
                editor.picker.clearItems();
                if (result == .array) {
                    for (result.array.items) |item| try self.addSymbolInformation(editor, client, item);
                }
                editor.picker.refilter();
            },
            .format_document, .format_selection => {
                var group: ?u64 = null;
                if (result != .null) {
                    const uri = try lsp.pathToUri(editor.allocator, doc.file_path orelse return error.UntitledDocument);
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
                // The save runs from `tick`, after polling: it fires Lua save
                // hooks, which may stop the client this reply came from.
                if (self.save) |*save| {
                    save.options.skip_format = true;
                    save.options.format_group = group;
                    self.pending_post_format_save = save.id;
                }
            },
            else => {},
        }
    }

    fn isCurrentFormatting(self: *const State, client: *const lsp.LspClient, request: lsp.Request) bool {
        const format = self.formatting orelse return false;
        return isFormatting(request.method) and format.serial == request.serial and format.generation == client.generation;
    }

    pub fn failed(self: *State, editor: *Editor, client: *lsp.LspClient, request: lsp.Request, reason: []const u8) void {
        var saving = false;
        if (self.isCurrentFormatting(client, request)) {
            saving = self.save != null;
            if (saving and editor.close_after_save_id == request.doc_id) editor.close_after_save_id = null;
            self.formatting = null;
            self.clearSave(editor.allocator);
        }
        if (saving or request.method == .hover or request.method == .prepare_rename or request.method == .rename or request.method == .references or request.method == .document_symbol or isFormatting(request.method))
            editor.status_message = std.fmt.bufPrint(&editor.status_buf, "{s}: {s}", .{ if (saving) "Save aborted" else "LSP request failed", reason }) catch "LSP request failed";
    }

    fn makePreview(self: *State, editor: *Editor, value: std.json.Value, encoding: workspace.Encoding) !void {
        if (self.preview != null or editor.mode != .normal) return error.EditorBusy;
        self.preview = try workspace.Plan.parse(editor, value, encoding);
        self.scroll = 0;
        editor.setMode(.workspace_preview);
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
        // This is the `.workspace_preview` leave hook (Editor.setMode calls
        // it), and clientStopped calls it in any mode: never setMode here.
        if (editor.mode == .workspace_preview) editor.mode = .normal;
        editor.status_message = if (applied) "Workspace edits applied; review and save the dirty files" else std.fmt.bufPrint(&editor.status_buf, "Workspace edit: {s}", .{reason}) catch "Workspace edit cancelled";
    }

    pub fn clientStopped(self: *State, editor: *Editor, client: *lsp.LspClient) void {
        if (self.formatting) |request| if (request.generation == client.generation) self.failed(editor, client, request, "Language server stopped");
        if (self.rename_context) |request| if (request.generation == client.generation) {
            self.rename_context = null;
            if (editor.mode == .symbol_rename) editor.setMode(.normal);
        };
        if (self.preview_server == client.generation) self.resolvePreview(editor, false);
    }
};

/// A registered client past its handshake with no process behind it:
/// requests queue in its detached peer; replies go in through `response`.
fn testClient(editor: *Editor) !*lsp.LspClient {
    const t = std.testing;
    const client = try t.allocator.create(lsp.LspClient);
    client.* = lsp.LspClient.init(t.allocator, t.io);
    editor.lsp_clients.append(t.allocator, client) catch |err| {
        client.deinit();
        t.allocator.destroy(client);
        return err;
    };
    client.peer = try @import("protocol.zig").Peer.detached(t.allocator, t.io);
    client.config = try lsp.ServerConfig.fromArgv(t.allocator, &.{"zig"}, &.{"test-server"});
    // Also the newest registration for the language, however clients are routed.
    var registration = try client.config.?.clone(t.allocator);
    editor.lsp_configs.append(t.allocator, registration) catch |err| {
        registration.deinit(t.allocator);
        return err;
    };
    client.initialized = true;
    client.capabilities = .{ .hover = true, .rename = true, .format_document = true };
    return client;
}

fn pendingRequest(client: *lsp.LspClient, method: lsp.RequestMethod) ?lsp.Request {
    var requests = client.pending.valueIterator();
    while (requests.next()) |request| if (request.method == method) return request.*;
    return null;
}

test "format-on-save saves from tick, not from the reply, and keeps an in-flight hover" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const  x = 1;\n" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "main.zig", t.allocator);
    defer t.allocator.free(path);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.editorconfig_enabled = false;
    const doc = try editor.openFile(path);
    const id = doc.id;
    const client = try testClient(&editor);
    defer client.initialized = false; // no shutdown handshake with a fake peer
    doc.lsp_opened = true;
    try doc.insertAtCursor("// edited\n");

    // A hover is in flight when an auto-save starts formatting.
    editor.lsp_tools.start(&editor, .hover);
    const hover = pendingRequest(client, .hover).?;
    editor.lsp_tools.format_on_save = true;
    try t.expectEqual(Editor.SaveOutcome.formatting, editor.saveDocument(id, .{}));
    const format = pendingRequest(client, .format_document).?;
    try t.expectEqual(hover.serial, editor.lsp_tools.serial);
    editor.lsp_tools.response(&editor, client, hover, "{\"result\":{\"contents\":\"x: comptime_int\"}}");
    try t.expectEqualStrings("x: comptime_int", editor.lsp_tools.hover.?);
    try t.expectEqual(Editor.Mode.lsp_panel, editor.mode);
    editor.mode = .normal;

    // The reply applies the edit; nothing is written from inside dispatch.
    editor.lsp_tools.response(&editor, client, format, "{\"result\":[{\"range\":{\"start\":{\"line\":1,\"character\":5},\"end\":{\"line\":1,\"character\":7}},\"newText\":\" \"}]}");
    try t.expectEqualStrings("// edited\nconst x = 1;\n", doc.buffer.slice(0, doc.buffer.byteLen()));
    try t.expect(editor.lsp_tools.formatting == null and doc.dirty);
    try t.expectEqual(@as(?u64, id), editor.lsp_tools.pending_post_format_save);
    const before = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1024));
    defer t.allocator.free(before);
    try t.expectEqualStrings("const  x = 1;\n", before);
    // Another save of the same document joins the pending one.
    const requests = client.pending.count();
    try t.expect(try editor.lsp_tools.maybeFormatSave(&editor, doc, .{}));
    try t.expect(editor.lsp_tools.formatting == null and client.pending.count() == requests);
    try t.expectEqual(@as(?u64, id), editor.lsp_tools.pending_post_format_save);

    editor.lsp_tools.tick(&editor);
    const doc_after = &editor.documents.items[editor.docIndexForId(id).?];
    try t.expect(!doc_after.dirty);
    try t.expect(editor.lsp_tools.pending_post_format_save == null and editor.lsp_tools.save == null);
    const saved = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1024));
    defer t.allocator.free(saved);
    try t.expectEqualStrings("// edited\nconst x = 1;\n", saved);

    // The preview resolver is also the `.workspace_preview` leave hook and
    // runs from clientStopped in any mode: it leaves other modes alone.
    editor.mode = .lsp_panel;
    editor.lsp_tools.resolvePreview(&editor, false);
    try t.expectEqual(Editor.Mode.lsp_panel, editor.mode);
    editor.mode = .normal;
}

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
