const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// LSP message types (static structs for std.json.parseFromSlice)
// ---------------------------------------------------------------------------

/// Minimal envelope — just enough to dispatch by method/id.
const RpcEnvelope = struct {
    id: ?i64 = null,
    method: ?[]const u8 = null,
};

/// publishDiagnostics notification params.
const DiagnosticParams = struct {
    uri: []const u8,
    diagnostics: []const LspDiagnostic,
};

const LspDiagnostic = struct {
    range: LspRange,
    severity: ?u32 = null,
    message: []const u8,
    source: ?[]const u8 = null,
};

const LspRange = struct {
    start: LspPosition,
    end: LspPosition,
};

const LspPosition = struct {
    line: u32,
    character: u32,
};

const CompletionItem = struct {
    label: []const u8,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    kind: ?u32 = null,
};

/// Definition response.
const DefinitionLocation = struct {
    uri: []const u8,
    range: LspRange,
};

// ---------------------------------------------------------------------------
// Diagnostic type (stored on Document)
// ---------------------------------------------------------------------------

pub const DiagnosticSeverity = enum(u8) {
    err = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

pub const Diagnostic = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    severity: DiagnosticSeverity,
    message: []const u8, // heap-allocated, owned

    pub fn deinit(self: *const Diagnostic, allocator: Allocator) void {
        allocator.free(self.message);
    }
};

// ---------------------------------------------------------------------------
// Thread-safe message queue (ring buffer)
// ---------------------------------------------------------------------------

const QUEUE_CAP = 256;

const IncomingMessage = struct {
    json_bytes: []const u8, // heap-allocated, owned by consumer
};

const MessageQueue = struct {
    buf: [QUEUE_CAP]IncomingMessage = undefined,
    read_idx: usize = 0,
    write_idx: usize = 0,
    mutex: std.Thread.Mutex = .{},

    fn push(self: *MessageQueue, msg: IncomingMessage, allocator: Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // If full, drop (and free) the oldest unread message — previously the
        // overwritten slot's heap buffer leaked.
        if (self.write_idx -% self.read_idx >= QUEUE_CAP) {
            allocator.free(self.buf[self.read_idx % QUEUE_CAP].json_bytes);
            self.read_idx +%= 1;
        }
        self.buf[self.write_idx % QUEUE_CAP] = msg;
        self.write_idx +%= 1;
    }

    fn tryPop(self: *MessageQueue) ?IncomingMessage {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.read_idx == self.write_idx) return null;
        const msg = self.buf[self.read_idx % QUEUE_CAP];
        self.read_idx +%= 1;
        return msg;
    }
};

// ---------------------------------------------------------------------------
// LspClient
// ---------------------------------------------------------------------------

pub const LspClient = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    reader_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    incoming: MessageQueue = .{},
    next_id: i64 = 1,
    initialized: bool = false,

    // Optional TUI loop wake function
    tui_wake_fn: ?*const fn () void = null,

    // Pending request tracking
    pending: std.AutoHashMap(i64, RequestMethod) = undefined,

    const RequestMethod = enum {
        initialize,
        completion,
        goto_definition,
        shutdown,
    };

    pub fn init(allocator: Allocator) LspClient {
        return .{
            .allocator = allocator,
            .pending = std.AutoHashMap(i64, RequestMethod).init(allocator),
        };
    }

    pub fn deinit(self: *LspClient) void {
        self.stop();
        self.pending.deinit();
    }

    // ----- Process lifecycle -----

    pub fn start(self: *LspClient, command: []const u8) !void {
        if (self.process != null) return;

        const argv: []const []const u8 = &.{command};
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        // Nobody drains stderr — a .Pipe would fill up (~4KB) and block the
        // server mid-write, freezing the whole LSP session. Discard it.
        child.stderr_behavior = .Ignore;
        // Windows: the GUI runs without a console (FreeConsole on desktop
        // launch), so a console-subsystem server like zls.exe would otherwise
        // get a brand-new visible console window.
        child.create_no_window = true;

        try child.spawn();
        self.process = child;
        self.running.store(true, .release);

        // Start reader thread
        self.reader_thread = try std.Thread.spawn(.{}, readerThreadFn, .{self});

        // Send initialize request
        try self.sendInitialize();
    }

    pub fn stop(self: *LspClient) void {
        if (self.process == null) return;

        // Send shutdown request then exit notification
        if (self.initialized) {
            _ = self.sendRequest("shutdown", "null") catch {};
            self.sendNotification("exit", "null") catch {};
        }

        self.running.store(false, .release);

        // Close stdin to signal EOF to the process
        if (self.process) |*proc| {
            if (proc.stdin) |stdin| {
                stdin.close();
                proc.stdin = null;
            }
        }

        // Join reader thread
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }

        // Wait for process and clean up
        if (self.process) |*proc| {
            _ = proc.wait() catch {};
        }
        self.process = null;
        self.initialized = false;

        // Drain remaining messages
        while (self.incoming.tryPop()) |msg| {
            self.allocator.free(msg.json_bytes);
        }
    }

    pub fn isReady(self: *const LspClient) bool {
        return self.process != null and self.initialized;
    }

    // ----- Sending messages -----

    pub fn sendRequest(self: *LspClient, method: []const u8, params_json: []const u8) !i64 {
        const id = self.next_id;
        self.next_id += 1;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator,"{\"jsonrpc\":\"2.0\",\"id\":");
        try std.fmt.format(body.writer(self.allocator), "{d}", .{id});
        try body.appendSlice(self.allocator,",\"method\":\"");
        try body.appendSlice(self.allocator,method);
        try body.appendSlice(self.allocator,"\",\"params\":");
        try body.appendSlice(self.allocator,params_json);
        try body.append(self.allocator,'}');

        try self.writeMessage(body.items);
        return id;
    }

    pub fn sendNotification(self: *LspClient, method: []const u8, params_json: []const u8) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator,"{\"jsonrpc\":\"2.0\",\"method\":\"");
        try body.appendSlice(self.allocator,method);
        try body.appendSlice(self.allocator,"\",\"params\":");
        try body.appendSlice(self.allocator,params_json);
        try body.append(self.allocator,'}');

        try self.writeMessage(body.items);
    }

    fn writeMessage(self: *LspClient, body: []const u8) !void {
        const proc = &(self.process orelse return error.NotRunning);
        const stdin = proc.stdin orelse return error.NotRunning;

        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return error.NotRunning;

        stdin.writeAll(header) catch return error.NotRunning;
        stdin.writeAll(body) catch return error.NotRunning;
    }

    // ----- Initialize handshake -----

    fn sendInitialize(self: *LspClient) !void {
        // Build root URI from cwd
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.process.getCwd(&cwd_buf) catch ".";
        const root_uri = try pathToUri(self.allocator, cwd);
        defer self.allocator.free(root_uri);

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator, "{\"processId\":null,\"rootUri\":\"");
        try params.appendSlice(self.allocator,root_uri);
        try params.appendSlice(self.allocator,"\",\"capabilities\":{");
        try params.appendSlice(self.allocator,"\"textDocument\":{");
        try params.appendSlice(self.allocator,"\"synchronization\":{\"didSave\":true,\"didOpen\":true,\"didClose\":true},");
        try params.appendSlice(self.allocator,"\"completion\":{\"completionItem\":{}},");
        try params.appendSlice(self.allocator,"\"publishDiagnostics\":{},");
        try params.appendSlice(self.allocator,"\"definition\":{}");
        try params.appendSlice(self.allocator,"}}}");

        const id = try self.sendRequest("initialize", params.items);
        self.pending.put(id, .initialize) catch {};
    }

    // ----- Document sync helpers -----

    pub fn sendDidOpen(self: *LspClient, uri: []const u8, language_id: []const u8, version: i32, text: []const u8) !void {
        if (!self.initialized) return;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator,"{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator,uri);
        try params.appendSlice(self.allocator,"\",\"languageId\":\"");
        try params.appendSlice(self.allocator,language_id);
        try params.appendSlice(self.allocator,"\",\"version\":");
        try std.fmt.format(params.writer(self.allocator), "{d}", .{version});
        try params.appendSlice(self.allocator,",\"text\":");
        // JSON-escape the text
        try writeJsonString(params.writer(self.allocator), text);
        try params.appendSlice(self.allocator,"}}");

        try self.sendNotification("textDocument/didOpen", params.items);
    }

    pub fn sendDidChange(self: *LspClient, uri: []const u8, version: i32, text: []const u8) !void {
        if (!self.initialized) return;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator,"{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator,uri);
        try params.appendSlice(self.allocator,"\",\"version\":");
        try std.fmt.format(params.writer(self.allocator), "{d}", .{version});
        try params.appendSlice(self.allocator,"},\"contentChanges\":[{\"text\":");
        try writeJsonString(params.writer(self.allocator), text);
        try params.appendSlice(self.allocator,"}]}");

        try self.sendNotification("textDocument/didChange", params.items);
    }

    pub fn sendDidClose(self: *LspClient, uri: []const u8) !void {
        if (!self.initialized) return;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator,"{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator,uri);
        try params.appendSlice(self.allocator,"\"}}");

        try self.sendNotification("textDocument/didClose", params.items);
    }

    pub fn sendDidSave(self: *LspClient, uri: []const u8) !void {
        if (!self.initialized) return;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator,"{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator,uri);
        try params.appendSlice(self.allocator,"\"}}");

        try self.sendNotification("textDocument/didSave", params.items);
    }

    pub fn sendCompletion(self: *LspClient, uri: []const u8, line: u32, col: u32) !i64 {
        if (!self.initialized) return error.NotReady;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator,"{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator,uri);
        try params.appendSlice(self.allocator,"\"},\"position\":{\"line\":");
        try std.fmt.format(params.writer(self.allocator), "{d}", .{line});
        try params.appendSlice(self.allocator,",\"character\":");
        try std.fmt.format(params.writer(self.allocator), "{d}", .{col});
        try params.appendSlice(self.allocator,"}}");

        const id = try self.sendRequest("textDocument/completion", params.items);
        self.pending.put(id, .completion) catch {};
        return id;
    }

    pub fn sendGotoDefinition(self: *LspClient, uri: []const u8, line: u32, col: u32) !i64 {
        if (!self.initialized) return error.NotReady;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator,"{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator,uri);
        try params.appendSlice(self.allocator,"\"},\"position\":{\"line\":");
        try std.fmt.format(params.writer(self.allocator), "{d}", .{line});
        try params.appendSlice(self.allocator,",\"character\":");
        try std.fmt.format(params.writer(self.allocator), "{d}", .{col});
        try params.appendSlice(self.allocator,"}}");

        const id = try self.sendRequest("textDocument/definition", params.items);
        self.pending.put(id, .goto_definition) catch {};
        return id;
    }

    // ----- Message polling (called from main thread) -----

    pub fn pollMessages(self: *LspClient, editor: anytype) void {
        var count: usize = 0;
        while (self.incoming.tryPop()) |msg| {
            defer self.allocator.free(msg.json_bytes);
            self.dispatchMessage(msg.json_bytes, editor);
            count += 1;
            if (count > 64) break; // Limit per frame to avoid stalls
        }
    }

    fn dispatchMessage(self: *LspClient, json_bytes: []const u8, editor: anytype) void {
        // Parse envelope to get method/id
        const envelope = std.json.parseFromSlice(RpcEnvelope, self.allocator, json_bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer envelope.deinit();

        if (envelope.value.id) |id| {
            // It's a response
            self.handleResponse(id, json_bytes, editor);
        } else if (envelope.value.method) |method| {
            // It's a notification
            self.handleNotification(method, json_bytes, editor);
        }
    }

    fn handleResponse(self: *LspClient, id: i64, json_bytes: []const u8, editor: anytype) void {
        const method = self.pending.get(id) orelse return;
        _ = self.pending.remove(id);

        switch (method) {
            .initialize => {
                self.initialized = true;
                // Send initialized notification
                self.sendNotification("initialized", "{}") catch {};
                std.log.info("LSP initialized (handshake complete)", .{});
                editor.status_message = "LSP ready";
            },
            .completion => {
                self.handleCompletionResponse(json_bytes, editor);
            },
            .goto_definition => {
                self.handleDefinitionResponse(json_bytes, editor);
            },
            .shutdown => {},
        }
    }

    fn handleNotification(self: *LspClient, method: []const u8, json_bytes: []const u8, editor: anytype) void {
        if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            self.handleDiagnostics(json_bytes, editor);
        }
        // Other notifications (window/logMessage, etc.) are ignored for now
    }

    fn handleDiagnostics(self: *LspClient, json_bytes: []const u8, editor: anytype) void {
        // Parse the notification with params.uri and params.diagnostics
        const Notif = struct {
            params: DiagnosticParams,
        };
        const parsed = std.json.parseFromSlice(Notif, self.allocator, json_bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        const params = parsed.value.params;

        // Find matching document by URI
        const file_path = uriToPath(self.allocator, params.uri) catch return;
        defer self.allocator.free(file_path);

        for (editor.documents.items) |*doc| {
            const doc_path = doc.file_path orelse continue;
            if (pathsEqual(doc_path, file_path)) {
                // Clear old diagnostics
                for (doc.diagnostics.items) |*d| {
                    d.deinit(doc.allocator);
                }
                doc.diagnostics.clearRetainingCapacity();

                // Add new diagnostics (server columns are UTF-16 code units;
                // convert to byte columns, which is what rendering uses)
                for (params.diagnostics) |lsp_diag| {
                    const msg = self.allocator.dupe(u8, lsp_diag.message) catch continue;
                    const start_line_text = doc.buffer.lineContent(lsp_diag.range.start.line);
                    const start_col: u32 = @intCast(utf16ColToByte(start_line_text, lsp_diag.range.start.character));
                    const end_line_text = doc.buffer.lineContent(lsp_diag.range.end.line);
                    const end_col: u32 = @intCast(utf16ColToByte(end_line_text, lsp_diag.range.end.character));
                    doc.diagnostics.append(doc.allocator, .{
                        .start_line = lsp_diag.range.start.line,
                        .start_col = start_col,
                        .end_line = lsp_diag.range.end.line,
                        .end_col = end_col,
                        .severity = if (lsp_diag.severity) |s| switch (s) {
                            1 => .err,
                            2 => .warning,
                            3 => .information,
                            else => .hint,
                        } else .err,
                        .message = msg,
                    }) catch {
                        self.allocator.free(msg);
                    };
                }
                break;
            }
        }
    }

    fn handleCompletionResponse(self: *LspClient, json_bytes: []const u8, editor: anytype) void {
        // Completion response can be CompletionItem[] or CompletionList { items: [] }
        // Try both forms
        const ListForm = struct {
            result: ?struct {
                items: ?[]const CompletionItem = null,
            } = null,
        };

        const parsed = std.json.parseFromSlice(ListForm, self.allocator, json_bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        const items = if (parsed.value.result) |r| (r.items orelse &.{}) else &.{};

        // Store in editor completion state
        editor.clearCompletionItems();
        for (items) |item| {
            const label = self.allocator.dupe(u8, item.label) catch continue;
            const detail = if (item.detail) |d| (self.allocator.dupe(u8, d) catch null) else null;
            const insert_text = if (item.insertText) |t| (self.allocator.dupe(u8, t) catch null) else null;
            editor.addCompletionItem(label, detail, insert_text) catch {
                self.allocator.free(label);
                if (detail) |d| self.allocator.free(d);
                if (insert_text) |t| self.allocator.free(t);
            };
        }
    }

    fn handleDefinitionResponse(self: *LspClient, json_bytes: []const u8, editor: anytype) void {
        // Response can be Location, Location[], or null
        // Try single location first
        const SingleLoc = struct {
            result: ?DefinitionLocation = null,
        };
        if (std.json.parseFromSlice(SingleLoc, self.allocator, json_bytes, .{
            .ignore_unknown_fields = true,
        })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.result) |loc| {
                self.jumpToLocation(loc, editor);
                return;
            }
        } else |_| {}

        // Try array of locations
        const ArrayLoc = struct {
            result: ?[]const DefinitionLocation = null,
        };
        if (std.json.parseFromSlice(ArrayLoc, self.allocator, json_bytes, .{
            .ignore_unknown_fields = true,
        })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.result) |locs| {
                if (locs.len > 0) {
                    self.jumpToLocation(locs[0], editor);
                }
            }
        } else |_| {}
    }

    fn jumpToLocation(self: *LspClient, loc: DefinitionLocation, editor: anytype) void {
        const file_path = uriToPath(self.allocator, loc.uri) catch return;
        defer self.allocator.free(file_path);

        // Check if the file is already open
        var found = false;
        for (editor.documents.items, 0..) |*doc, i| {
            const dp = doc.file_path orelse continue;
            if (pathsEqual(dp, file_path)) {
                editor.switchToDoc(i);
                doc.gotoLine(loc.range.start.line + 1); // gotoLine is 1-indexed
                found = true;
                break;
            }
        }

        if (!found) {
            // Open the file
            _ = editor.openFile(file_path) catch return;
            const doc = editor.activeDoc();
            doc.gotoLine(loc.range.start.line + 1);
        }
    }

    // ----- Reader thread -----

    fn readerThreadFn(self: *LspClient) void {
        const stdout_file = if (self.process) |*proc| (proc.stdout orelse return) else return;

        // Manual read buffer — File.reader() uses pread (positional reads) which
        // panics on Windows pipes. We use File.read() (streaming) instead.
        var buf: [8192]u8 = undefined;
        var buf_start: usize = 0;
        var buf_end: usize = 0;

        while (self.running.load(.acquire)) {
            // Read Content-Length header
            const content_len = pipeReadContentLength(stdout_file, &buf, &buf_start, &buf_end) catch break;
            if (content_len == 0) continue;

            // Read the JSON body
            const json_buf = self.allocator.alloc(u8, content_len) catch break;
            pipeReadExact(stdout_file, &buf, &buf_start, &buf_end, json_buf) catch {
                self.allocator.free(json_buf);
                break;
            };

            // Push to queue
            self.incoming.push(.{ .json_bytes = json_buf }, self.allocator);

            // Wake TUI if needed
            if (self.tui_wake_fn) |wake| {
                wake();
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Pipe-safe reading helpers (use File.read instead of File.reader/pread)
// ---------------------------------------------------------------------------

/// Read a single byte from the pipe, using the manual buffer for efficiency.
fn pipeReadByte(
    file: std.fs.File,
    buf: *[8192]u8,
    buf_start: *usize,
    buf_end: *usize,
) !u8 {
    if (buf_start.* < buf_end.*) {
        const b = buf[buf_start.*];
        buf_start.* += 1;
        return b;
    }
    // Buffer empty — refill
    const n = file.read(buf) catch |err| switch (err) {
        error.BrokenPipe => return error.EndOfStream,
        else => return error.EndOfStream,
    };
    if (n == 0) return error.EndOfStream;
    buf_start.* = 1;
    buf_end.* = n;
    return buf[0];
}

/// Read exactly `dest.len` bytes from the pipe into `dest`.
fn pipeReadExact(
    file: std.fs.File,
    buf: *[8192]u8,
    buf_start: *usize,
    buf_end: *usize,
    dest: []u8,
) !void {
    var written: usize = 0;
    while (written < dest.len) {
        // Drain what we can from the buffer
        const buffered = buf_end.* - buf_start.*;
        if (buffered > 0) {
            const needed = dest.len - written;
            const take = @min(buffered, needed);
            @memcpy(dest[written..][0..take], buf[buf_start.*..][0..take]);
            buf_start.* += take;
            written += take;
        } else {
            // Buffer empty — read directly if remaining is large, else refill buffer
            const remaining = dest.len - written;
            if (remaining >= buf.len) {
                const n = file.read(dest[written..]) catch return error.EndOfStream;
                if (n == 0) return error.EndOfStream;
                written += n;
            } else {
                const n = file.read(buf) catch return error.EndOfStream;
                if (n == 0) return error.EndOfStream;
                buf_start.* = 0;
                buf_end.* = n;
            }
        }
    }
}

/// Parse Content-Length from LSP JSON-RPC headers using pipe-safe reads.
fn pipeReadContentLength(
    file: std.fs.File,
    buf: *[8192]u8,
    buf_start: *usize,
    buf_end: *usize,
) !usize {
    var content_length: usize = 0;

    // Read headers line by line until empty line (\r\n\r\n)
    while (true) {
        var line_buf: [256]u8 = undefined;
        var line_len: usize = 0;

        // Read until \n
        while (line_len < line_buf.len) {
            const byte = pipeReadByte(file, buf, buf_start, buf_end) catch return error.EndOfStream;
            if (byte == '\n') break;
            line_buf[line_len] = byte;
            line_len += 1;
        }

        // Strip trailing \r
        const line = std.mem.trimRight(u8, line_buf[0..line_len], "\r");

        // Empty line = end of headers
        if (line.len == 0) break;

        // Parse Content-Length
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val_str = std.mem.trimLeft(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, val_str, 10) catch 0;
        }
    }

    return content_length;
}

// ---------------------------------------------------------------------------
// URI <-> Path conversion
// ---------------------------------------------------------------------------

pub fn pathToUri(allocator: Allocator, path: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator,"file:///");

    for (path) |ch| {
        if (ch == '\\') {
            try result.append(allocator,'/');
        } else if (ch == ' ') {
            try result.appendSlice(allocator,"%20");
        } else {
            try result.append(allocator,ch);
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn uriToPath(allocator: Allocator, uri: []const u8) ![]const u8 {
    var path_part = uri;
    if (std.mem.startsWith(u8, uri, "file:///")) {
        path_part = uri["file:///".len..];
    } else if (std.mem.startsWith(u8, uri, "file://")) {
        path_part = uri["file://".len..];
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < path_part.len) {
        if (path_part[i] == '%' and i + 2 < path_part.len) {
            const high = std.fmt.charToDigit(path_part[i + 1], 16) catch {
                try result.append(allocator,path_part[i]);
                i += 1;
                continue;
            };
            const low = std.fmt.charToDigit(path_part[i + 2], 16) catch {
                try result.append(allocator,path_part[i]);
                i += 1;
                continue;
            };
            try result.append(allocator,@as(u8, high) * 16 + low);
            i += 3;
        } else if (builtin.os.tag == .windows and path_part[i] == '/') {
            try result.append(allocator,'\\');
            i += 1;
        } else {
            try result.append(allocator,path_part[i]);
            i += 1;
        }
    }

    // On Windows, strip leading backslash from \C:\...
    if (builtin.os.tag == .windows and result.items.len >= 3) {
        if (result.items[0] == '\\' and result.items[2] == ':') {
            const slice = result.items[1..];
            const owned = try allocator.dupe(u8, slice);
            result.deinit(allocator);
            return owned;
        }
    }

    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// LSP position encoding (UTF-16 code units <-> byte columns)
// ---------------------------------------------------------------------------

/// Convert a byte column within `line` to a UTF-16 code-unit column.
/// LSP positions default to UTF-16; sending byte columns misplaces
/// completions/definitions on any line with non-ASCII text.
pub fn byteColToUtf16(line: []const u8, byte_col: usize) u32 {
    var units: u32 = 0;
    var i: usize = 0;
    const end = @min(byte_col, line.len);
    while (i < end) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch {
            units += 1;
            i += 1;
            continue;
        };
        if (i + len > line.len) break;
        const cp = std.unicode.utf8Decode(line[i .. i + len]) catch {
            units += 1;
            i += 1;
            continue;
        };
        units += if (cp >= 0x10000) 2 else 1;
        i += len;
    }
    return units;
}

/// Convert a UTF-16 code-unit column to a byte column within `line`.
pub fn utf16ColToByte(line: []const u8, utf16_col: u32) usize {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line.len and units < utf16_col) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch {
            units += 1;
            i += 1;
            continue;
        };
        if (i + len > line.len) break;
        const cp = std.unicode.utf8Decode(line[i .. i + len]) catch {
            units += 1;
            i += 1;
            continue;
        };
        units += if (cp >= 0x10000) 2 else 1;
        i += len;
    }
    return i;
}

// ---------------------------------------------------------------------------
// JSON string escaping
// ---------------------------------------------------------------------------

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try std.fmt.format(writer, "\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

// ---------------------------------------------------------------------------
// Path comparison
// ---------------------------------------------------------------------------

fn pathsEqual(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag == .windows) {
        // Case-insensitive, normalize slashes
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const na = if (ca == '/') @as(u8, '\\') else std.ascii.toLower(ca);
            const nb = if (cb == '/') @as(u8, '\\') else std.ascii.toLower(cb);
            if (na != nb) return false;
        }
        return true;
    }
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "pathToUri basic" {
    const alloc = std.testing.allocator;
    const uri = try pathToUri(alloc, "C:\\Users\\test\\main.zig");
    defer alloc.free(uri);
    try std.testing.expectEqualStrings("file:///C:/Users/test/main.zig", uri);
}

test "uriToPath basic" {
    const alloc = std.testing.allocator;
    const path = try uriToPath(alloc, "file:///C:/Users/test/main.zig");
    defer alloc.free(path);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("C:\\Users\\test\\main.zig", path);
    } else {
        try std.testing.expectEqualStrings("C:/Users/test/main.zig", path);
    }
}

test "uriToPath percent decode" {
    const alloc = std.testing.allocator;
    const path = try uriToPath(alloc, "file:///path/to%20my/file.zig");
    defer alloc.free(path);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("path\\to my\\file.zig", path);
    } else {
        try std.testing.expectEqualStrings("path/to my/file.zig", path);
    }
}

test "writeJsonString escaping" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try writeJsonString(buf.writer(alloc), "hello\n\"world\"\t\\end");
    try std.testing.expectEqualStrings("\"hello\\n\\\"world\\\"\\t\\\\end\"", buf.items);
}

test "pathsEqual" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(pathsEqual("C:\\foo\\bar.zig", "c:\\foo\\bar.zig"));
        try std.testing.expect(pathsEqual("C:/foo/bar.zig", "C:\\foo\\bar.zig"));
    } else {
        try std.testing.expect(pathsEqual("/foo/bar.zig", "/foo/bar.zig"));
        try std.testing.expect(!pathsEqual("/foo/Bar.zig", "/foo/bar.zig"));
    }
}

test "utf16 column conversion" {
    // ASCII: byte col == utf16 col
    try std.testing.expectEqual(@as(u32, 5), byteColToUtf16("hello", 5));
    try std.testing.expectEqual(@as(usize, 5), utf16ColToByte("hello", 5));

    // 2-byte é (1 UTF-16 unit, 2 bytes): "héllo"
    const accented = "h\u{e9}llo";
    try std.testing.expectEqual(@as(u32, 2), byteColToUtf16(accented, 3)); // after é
    try std.testing.expectEqual(@as(usize, 3), utf16ColToByte(accented, 2));

    // Emoji 😀 (surrogate pair: 2 UTF-16 units, 4 bytes): "a😀b"
    const emoji = "a\u{1F600}b";
    try std.testing.expectEqual(@as(u32, 3), byteColToUtf16(emoji, 5)); // after emoji
    try std.testing.expectEqual(@as(usize, 5), utf16ColToByte(emoji, 3));
    try std.testing.expectEqual(@as(usize, 6), utf16ColToByte(emoji, 4)); // after b

    // Clamping: past end of line
    try std.testing.expectEqual(@as(u32, 2), byteColToUtf16("ab", 99));
    try std.testing.expectEqual(@as(usize, 2), utf16ColToByte("ab", 99));
}

test "MessageQueue push pop" {
    var q = MessageQueue{};
    const alloc = std.testing.allocator;
    const msg1 = try alloc.dupe(u8, "hello");
    q.push(.{ .json_bytes = msg1 }, alloc);
    const popped = q.tryPop().?;
    try std.testing.expectEqualStrings("hello", popped.json_bytes);
    alloc.free(popped.json_bytes);
    try std.testing.expect(q.tryPop() == null);
}

test "MessageQueue overflow frees dropped messages" {
    var q = MessageQueue{};
    const alloc = std.testing.allocator;
    // Push past capacity — the overwritten oldest messages must be freed
    // (std.testing.allocator fails the test on any leak).
    var i: usize = 0;
    while (i < QUEUE_CAP + 16) : (i += 1) {
        const msg = try alloc.dupe(u8, "x");
        q.push(.{ .json_bytes = msg }, alloc);
    }
    var popped: usize = 0;
    while (q.tryPop()) |msg| {
        alloc.free(msg.json_bytes);
        popped += 1;
    }
    try std.testing.expectEqual(@as(usize, QUEUE_CAP), popped);
}
