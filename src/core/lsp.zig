const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// LSP message types (static structs for std.json.parseFromSlice)
// ---------------------------------------------------------------------------

/// Minimal envelope — just enough to classify and dispatch. `id` is a
/// dynamic value: JSON-RPC allows string ids and servers use them for their
/// own requests (an `?i64` made such messages fail to parse and vanish,
/// leaving the server waiting on an answer forever).
const RpcEnvelope = struct {
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
};

/// `error` member of a failed response.
const RpcError = struct {
    code: i64 = 0,
    message: []const u8 = "",
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

pub const LspRange = struct {
    start: LspPosition,
    end: LspPosition,
};

pub const LspPosition = struct {
    line: u32,
    character: u32,
};

const CompletionItem = struct {
    label: []const u8,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    kind: ?u32 = null,
    textEdit: ?struct {
        newText: []const u8,
        range: ?LspRange = null,
        insert: ?LspRange = null,
        replace: ?LspRange = null,
    } = null,
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
// Server configuration (from zide.register_lsp)
// ---------------------------------------------------------------------------

/// One language server: the languages it serves, how to launch it, and what
/// to hand it at initialize time. Every slice is owned by the config — they
/// are duplicated on creation and never alias Lua memory or LanguageDef
/// names (those die when a language is re-registered).
pub const ServerConfig = struct {
    /// Language names as given to zide.register_language (matched case-insensitively).
    languages: []const []const u8,
    /// LSP `languageId` per language, parallel to `languages`; defaults to
    /// the lowercased name (mutable slice so setLanguageId can swap one).
    language_ids: [][]const u8,
    /// argv[0] = program (resolved on PATH by the spawner), rest = arguments.
    argv: []const []const u8,
    /// JSON text answered to `workspace/configuration` requests and pushed
    /// via `workspace/didChangeConfiguration` after the handshake.
    settings_json: ?[]const u8 = null,
    /// JSON text spliced into `initializationOptions`.
    init_options_json: ?[]const u8 = null,
    /// Registered while extensions/*.lua were loading — such configs are
    /// dropped and re-added by reload_extensions (init.lua ones persist).
    from_extension: bool = false,
    /// Spawn failed / server died / initialize rejected. Stops the per-frame
    /// lazy start from retrying a broken server every frame. Cleared by
    /// lsp_restart or by re-registration.
    failed: bool = false,

    /// Build a config with default language ids (lowercased names).
    pub fn fromArgv(gpa: Allocator, languages: []const []const u8, argv: []const []const u8) !ServerConfig {
        const langs = try dupeStrings(gpa, languages);
        errdefer freeStrings(gpa, langs);
        const ids = try gpa.alloc([]const u8, languages.len);
        var filled: usize = 0;
        errdefer {
            for (ids[0..filled]) |s| gpa.free(s);
            gpa.free(ids);
        }
        for (languages, 0..) |lang, i| {
            const id = try gpa.alloc(u8, lang.len);
            _ = std.ascii.lowerString(id, lang);
            ids[i] = id;
            filled += 1;
        }
        const args = try dupeStrings(gpa, argv);
        return .{ .languages = langs, .language_ids = ids, .argv = args };
    }

    pub fn clone(self: *const ServerConfig, gpa: Allocator) !ServerConfig {
        const langs = try dupeStrings(gpa, self.languages);
        errdefer freeStrings(gpa, langs);
        const ids = try dupeStrings(gpa, self.language_ids);
        errdefer freeStrings(gpa, ids);
        const args = try dupeStrings(gpa, self.argv);
        errdefer freeStrings(gpa, args);
        const settings: ?[]const u8 = if (self.settings_json) |s| try gpa.dupe(u8, s) else null;
        errdefer if (settings) |s| gpa.free(s);
        const init_opts: ?[]const u8 = if (self.init_options_json) |s| try gpa.dupe(u8, s) else null;
        return .{
            .languages = langs,
            .language_ids = ids,
            .argv = args,
            .settings_json = settings,
            .init_options_json = init_opts,
            .from_extension = self.from_extension,
            .failed = self.failed,
        };
    }

    /// Override the `languageId` sent for `languages[index]`.
    pub fn setLanguageId(self: *ServerConfig, gpa: Allocator, index: usize, id: []const u8) !void {
        const duped = try gpa.dupe(u8, id);
        gpa.free(self.language_ids[index]);
        self.language_ids[index] = duped;
    }

    pub fn deinit(self: *ServerConfig, gpa: Allocator) void {
        freeStrings(gpa, self.languages);
        freeStrings(gpa, self.language_ids);
        freeStrings(gpa, self.argv);
        if (self.settings_json) |s| gpa.free(s);
        if (self.init_options_json) |s| gpa.free(s);
        self.* = undefined;
    }

    pub fn servesLanguage(self: *const ServerConfig, lang_name: []const u8) bool {
        for (self.languages) |l| {
            if (std.ascii.eqlIgnoreCase(l, lang_name)) return true;
        }
        return false;
    }

    /// The `languageId` to send for a language (the name itself when the
    /// config does not serve it — callers only ask for served languages).
    pub fn languageIdFor(self: *const ServerConfig, lang_name: []const u8) []const u8 {
        for (self.languages, self.language_ids) |l, id| {
            if (std.ascii.eqlIgnoreCase(l, lang_name)) return id;
        }
        return lang_name;
    }

    /// Short human name for logs and the status bar: basename of argv[0]
    /// without a .exe/.cmd/.bat suffix.
    pub fn displayName(self: *const ServerConfig) []const u8 {
        if (self.argv.len == 0) return "?";
        return programDisplayName(self.argv[0]);
    }

    /// Same server in every way that matters to a running process.
    pub fn eql(a: *const ServerConfig, b: *const ServerConfig) bool {
        return stringsEql(a.languages, b.languages) and
            stringsEql(a.language_ids, b.language_ids) and
            stringsEql(a.argv, b.argv) and
            optStrEql(a.settings_json, b.settings_json) and
            optStrEql(a.init_options_json, b.init_options_json);
    }
};

/// Basename of a program path (either separator) minus .exe/.cmd/.bat.
pub fn programDisplayName(program: []const u8) []const u8 {
    var start: usize = 0;
    for (program, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    var base = program[start..];
    inline for (.{ ".exe", ".cmd", ".bat" }) |ext| {
        if (base.len > ext.len and std.ascii.endsWithIgnoreCase(base, ext)) {
            base = base[0 .. base.len - ext.len];
        }
    }
    return base;
}

fn dupeStrings(gpa: Allocator, items: []const []const u8) ![][]const u8 {
    const out = try gpa.alloc([]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (items, 0..) |s, i| {
        out[i] = try gpa.dupe(u8, s);
        filled += 1;
    }
    return out;
}

fn freeStrings(gpa: Allocator, items: []const []const u8) void {
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

fn stringsEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

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
    mutex: std.Io.Mutex = .init,

    fn push(self: *MessageQueue, io: std.Io, msg: IncomingMessage, allocator: Allocator) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // If full, drop (and free) the oldest unread message — previously the
        // overwritten slot's heap buffer leaked.
        if (self.write_idx -% self.read_idx >= QUEUE_CAP) {
            allocator.free(self.buf[self.read_idx % QUEUE_CAP].json_bytes);
            self.read_idx +%= 1;
        }
        self.buf[self.write_idx % QUEUE_CAP] = msg;
        self.write_idx +%= 1;
    }

    fn tryPop(self: *MessageQueue, io: std.Io) ?IncomingMessage {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
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
    io: std.Io,
    process: ?std.process.Child = null,
    reader_thread: ?std.Thread = null,
    /// "Keep reading" — cleared by stop() before the reader is joined.
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by the reader thread when it exits (EOF = the server closed its
    /// stdout, i.e. it exited or crashed). `process != null and reader_done`
    /// is how the editor detects a server that died on its own.
    reader_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    incoming: MessageQueue = .{},
    next_id: i64 = 1,
    initialized: bool = false,
    /// The server rejected `initialize` (or the handshake could not be
    /// written): treated like a dead server by the editor's sweep.
    dead: bool = false,

    // Optional TUI loop wake function
    tui_wake_fn: ?*const fn () void = null,

    // Pending request tracking
    pending: std.AutoHashMap(i64, RequestMethod) = undefined,

    /// Deep copy of the registration this server was started from — the
    /// editor's config list can be rewritten (reload_extensions) while the
    /// server keeps running. Null until start().
    config: ?ServerConfig = null,
    /// Absolute workspace root handed to the server at initialize. Owned.
    root_path: []const u8 = "",

    const RequestMethod = enum {
        initialize,
        completion,
        goto_definition,
        shutdown,
    };

    pub fn init(allocator: Allocator, io: std.Io) LspClient {
        return .{
            .allocator = allocator,
            .io = io,
            .pending = std.AutoHashMap(i64, RequestMethod).init(allocator),
        };
    }

    pub fn deinit(self: *LspClient) void {
        self.stop();
        self.pending.deinit();
    }

    /// Human name for logs and the status bar: basename of argv[0].
    pub fn name(self: *const LspClient) []const u8 {
        if (self.config) |*cfg| return cfg.displayName();
        return "lsp";
    }

    /// The languages this server serves, comma-joined into `buf`.
    pub fn languagesText(self: *const LspClient, buf: []u8) []const u8 {
        const cfg = if (self.config) |*c| c else return "?";
        var len: usize = 0;
        for (cfg.languages, 0..) |lang, i| {
            const sep: []const u8 = if (i == 0) "" else ", ";
            if (len + sep.len + lang.len > buf.len) break;
            @memcpy(buf[len..][0..sep.len], sep);
            len += sep.len;
            @memcpy(buf[len..][0..lang.len], lang);
            len += lang.len;
        }
        return buf[0..len];
    }

    // ----- Process lifecycle -----

    /// Launch `config.argv` with the workspace rooted at `root_path` and
    /// send `initialize`. The config and root are deep-copied. On error the
    /// client is left stopped (nothing to clean up beyond `deinit`), except
    /// that a failed handshake write leaves it `dead` for the sweep.
    pub fn start(self: *LspClient, config: *const ServerConfig, root_path: []const u8) !void {
        if (self.process != null) return error.AlreadyStarted;
        if (config.argv.len == 0) return error.NoCommand;

        var cfg = try config.clone(self.allocator);
        var cfg_moved = false;
        errdefer if (!cfg_moved) cfg.deinit(self.allocator);
        const root = try self.allocator.dupe(u8, root_path);
        errdefer if (!cfg_moved) self.allocator.free(root);

        const child = try std.process.spawn(self.io, .{
            .argv = cfg.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            // Nobody drains stderr — a pipe would fill up (~4KB) and block the
            // server mid-write, freezing the whole LSP session. Discard it.
            .stderr = .ignore,
            // Windows: the GUI runs without a console (FreeConsole on desktop
            // launch), so a console-subsystem server like zls.exe would
            // otherwise get a brand-new visible console window.
            .create_no_window = true,
        });
        self.process = child;
        self.initialized = false;
        self.dead = false;
        self.reader_done.store(false, .release);
        self.running.store(true, .release);

        // Start reader thread (it reads self.process.stdout)
        self.reader_thread = std.Thread.spawn(.{}, readerThreadFn, .{self}) catch |err| {
            self.running.store(false, .release);
            if (self.process) |*proc| proc.kill(self.io);
            self.process = null;
            return err;
        };

        self.config = cfg;
        self.root_path = root;
        cfg_moved = true;

        // A write failure here means the server is already gone.
        self.sendInitialize() catch |err| {
            self.dead = true;
            return err;
        };
    }

    /// Shut the server down: polite shutdown/exit, close stdin, give it up
    /// to ~1s to leave on its own, kill it otherwise, join the reader, free
    /// everything. Safe on a never-started or already-dead client.
    pub fn stop(self: *LspClient) void {
        if (self.process != null) {
            if (self.initialized and !self.dead and !self.reader_done.load(.acquire)) {
                _ = self.sendRequest("shutdown", "null") catch {};
                self.sendNotification("exit", "null") catch {};
            }
            self.running.store(false, .release);

            // Close stdin to signal EOF to the process
            if (self.process) |*proc| {
                if (proc.stdin) |stdin| {
                    stdin.close(self.io);
                    proc.stdin = null;
                }
            }

            // Grace period: a well-behaved server exits after `exit`, which
            // closes its stdout and lets the reader thread finish. A hung
            // server would block join() forever — kill it instead.
            var waited_ms: u32 = 0;
            while (!self.reader_done.load(.acquire) and waited_ms < 1000) : (waited_ms += 10) {
                std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
            }
            var killed = false;
            if (!self.reader_done.load(.acquire)) {
                if (self.process) |*proc| proc.kill(self.io); // blocks + reaps
                killed = true;
            }

            // Join reader thread (the server's stdout is closed either way)
            if (self.reader_thread) |thread| {
                thread.join();
                self.reader_thread = null;
            }

            // Reap — kill() already did when it ran (wait() asserts otherwise)
            if (!killed) {
                if (self.process) |*proc| _ = proc.wait(self.io) catch {};
            }
            self.process = null;
        }
        self.initialized = false;
        self.dead = false;
        self.pending.clearRetainingCapacity();

        // Drain remaining messages
        while (self.incoming.tryPop(self.io)) |msg| {
            self.allocator.free(msg.json_bytes);
        }
        if (self.config) |*cfg| {
            cfg.deinit(self.allocator);
            self.config = null;
        }
        if (self.root_path.len > 0) {
            self.allocator.free(self.root_path);
            self.root_path = "";
        }
    }

    /// Handshake done and the server is still alive.
    pub fn isReady(self: *const LspClient) bool {
        return self.process != null and self.initialized and !self.dead and !self.reader_done.load(.acquire);
    }

    /// The server went away on its own (crash/exit) or rejected initialize.
    /// The editor sweeps such clients (stop + destroy) and marks their
    /// config failed so the lazy start doesn't respawn a crashing server.
    pub fn isDead(self: *const LspClient) bool {
        return self.process != null and (self.dead or self.reader_done.load(.acquire));
    }

    // ----- Sending messages -----

    pub fn sendRequest(self: *LspClient, method: []const u8, params_json: []const u8) !i64 {
        const id = self.next_id;
        self.next_id += 1;

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try body.print(self.allocator, "{d}", .{id});
        try body.appendSlice(self.allocator, ",\"method\":\"");
        try body.appendSlice(self.allocator, method);
        try body.appendSlice(self.allocator, "\",\"params\":");
        try body.appendSlice(self.allocator, params_json);
        try body.append(self.allocator, '}');

        try self.writeMessage(body.items);
        return id;
    }

    pub fn sendNotification(self: *LspClient, method: []const u8, params_json: []const u8) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"");
        try body.appendSlice(self.allocator, method);
        try body.appendSlice(self.allocator, "\",\"params\":");
        try body.appendSlice(self.allocator, params_json);
        try body.append(self.allocator, '}');

        try self.writeMessage(body.items);
    }

    fn writeMessage(self: *LspClient, body: []const u8) !void {
        const proc = &(self.process orelse return error.NotRunning);
        const stdin = proc.stdin orelse return error.NotRunning;

        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return error.NotRunning;

        stdin.writeStreamingAll(self.io, header) catch return error.NotRunning;
        stdin.writeStreamingAll(self.io, body) catch return error.NotRunning;
    }

    // ----- Initialize handshake -----

    fn sendInitialize(self: *LspClient) !void {
        const cfg = if (self.config) |*c| c else return error.NotRunning;
        const params = try buildInitializeParams(self.allocator, self.root_path, cfg.init_options_json);
        defer self.allocator.free(params);

        const id = try self.sendRequest("initialize", params);
        self.pending.put(id, .initialize) catch {};
    }

    /// Push the registration's `settings` table after the handshake — the
    /// same JSON answers `workspace/configuration` pulls, so servers of
    /// either persuasion see it.
    fn sendDidChangeConfiguration(self: *LspClient) !void {
        const cfg = if (self.config) |*c| c else return;
        const settings = cfg.settings_json orelse return;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);
        try params.appendSlice(self.allocator, "{\"settings\":");
        try params.appendSlice(self.allocator, settings);
        try params.append(self.allocator, '}');

        try self.sendNotification("workspace/didChangeConfiguration", params.items);
    }

    // ----- Document sync helpers -----

    pub fn sendDidOpen(self: *LspClient, uri: []const u8, language_id: []const u8, version: i32, text: []const u8) !void {
        if (!self.initialized) return;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator, uri);
        try params.appendSlice(self.allocator, "\",\"languageId\":\"");
        try params.appendSlice(self.allocator, language_id);
        try params.appendSlice(self.allocator, "\",\"version\":");
        try params.print(self.allocator, "{d}", .{version});
        try params.appendSlice(self.allocator, ",\"text\":");
        // JSON-escape the text
        try writeJsonString(&params, self.allocator, text);
        try params.appendSlice(self.allocator, "}}");

        try self.sendNotification("textDocument/didOpen", params.items);
    }

    pub fn sendDidChange(self: *LspClient, uri: []const u8, version: i32, text: []const u8) !void {
        if (!self.initialized) return;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator, uri);
        try params.appendSlice(self.allocator, "\",\"version\":");
        try params.print(self.allocator, "{d}", .{version});
        try params.appendSlice(self.allocator, "},\"contentChanges\":[{\"text\":");
        try writeJsonString(&params, self.allocator, text);
        try params.appendSlice(self.allocator, "}]}");

        try self.sendNotification("textDocument/didChange", params.items);
    }

    pub fn sendDidClose(self: *LspClient, uri: []const u8) !void {
        if (!self.initialized) return;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator, uri);
        try params.appendSlice(self.allocator, "\"}}");

        try self.sendNotification("textDocument/didClose", params.items);
    }

    pub fn sendDidSave(self: *LspClient, uri: []const u8) !void {
        if (!self.initialized) return;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator, uri);
        try params.appendSlice(self.allocator, "\"}}");

        try self.sendNotification("textDocument/didSave", params.items);
    }

    pub fn sendCompletion(self: *LspClient, uri: []const u8, line: u32, col: u32) !i64 {
        if (!self.initialized) return error.NotReady;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator, uri);
        try params.appendSlice(self.allocator, "\"},\"position\":{\"line\":");
        try params.print(self.allocator, "{d}", .{line});
        try params.appendSlice(self.allocator, ",\"character\":");
        try params.print(self.allocator, "{d}", .{col});
        try params.appendSlice(self.allocator, "}}");

        const id = try self.sendRequest("textDocument/completion", params.items);
        self.pending.put(id, .completion) catch {};
        return id;
    }

    pub fn sendGotoDefinition(self: *LspClient, uri: []const u8, line: u32, col: u32) !i64 {
        if (!self.initialized) return error.NotReady;

        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.allocator);

        try params.appendSlice(self.allocator, "{\"textDocument\":{\"uri\":\"");
        try params.appendSlice(self.allocator, uri);
        try params.appendSlice(self.allocator, "\"},\"position\":{\"line\":");
        try params.print(self.allocator, "{d}", .{line});
        try params.appendSlice(self.allocator, ",\"character\":");
        try params.print(self.allocator, "{d}", .{col});
        try params.appendSlice(self.allocator, "}}");

        const id = try self.sendRequest("textDocument/definition", params.items);
        self.pending.put(id, .goto_definition) catch {};
        return id;
    }

    // ----- Message polling (called from main thread) -----

    pub fn pollMessages(self: *LspClient, editor: anytype) void {
        var count: usize = 0;
        while (self.incoming.tryPop(self.io)) |msg| {
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

        switch (classifyMessage(envelope.value.id, envelope.value.method)) {
            .request => self.handleServerRequest(envelope.value.id.?, envelope.value.method.?, json_bytes, editor),
            .response => switch (envelope.value.id.?) {
                .integer => |id| self.handleResponse(id, json_bytes, editor),
                else => {}, // we only ever send integer ids
            },
            .notification => self.handleNotification(envelope.value.method.?, json_bytes, editor),
            .invalid => {},
        }
    }

    fn handleResponse(self: *LspClient, id: i64, json_bytes: []const u8, editor: anytype) void {
        const method = self.pending.get(id) orelse return;
        _ = self.pending.remove(id);

        // A failed request carries `error` instead of `result`.
        const ErrForm = struct { @"error": ?RpcError = null };
        if (std.json.parseFromSlice(ErrForm, self.allocator, json_bytes, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.@"error") |e| {
                std.log.warn("LSP[{s}] {s} failed: {d} {s}", .{ self.name(), @tagName(method), e.code, e.message });
                if (method == .initialize) {
                    // Nothing else will ever work — the sweep retires the client.
                    self.dead = true;
                    editor.status_message = std.fmt.bufPrint(&editor.status_buf, "LSP {s} rejected initialize — see zide.log", .{self.name()}) catch "LSP initialize failed — see zide.log";
                }
                return;
            }
        } else |_| {}

        switch (method) {
            .initialize => {
                self.initialized = true;
                // Send initialized notification, then the settings
                self.sendNotification("initialized", "{}") catch {};
                self.sendDidChangeConfiguration() catch {};
                var langs_buf: [64]u8 = undefined;
                const langs = self.languagesText(&langs_buf);
                std.log.info("LSP[{s}] initialized (handshake complete) for {s}", .{ self.name(), langs });
                editor.status_message = std.fmt.bufPrint(&editor.status_buf, "LSP ready: {s} ({s})", .{ self.name(), langs }) catch "LSP ready";
            },
            .completion => {
                if (editor.completionResponseCurrent(self, id)) self.handleCompletionResponse(json_bytes, editor);
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
        } else if (std.mem.eql(u8, method, "window/logMessage") or std.mem.eql(u8, method, "window/showMessage")) {
            const Msg = struct { params: struct { type: u32 = 4, message: []const u8 = "" } };
            const parsed = std.json.parseFromSlice(Msg, self.allocator, json_bytes, .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            const p = parsed.value.params;
            if (p.type <= 2) {
                std.log.warn("LSP[{s}] {s}", .{ self.name(), p.message });
            } else {
                std.log.info("LSP[{s}] {s}", .{ self.name(), p.message });
            }
            // showMessage errors are meant for the user's eyes
            if (p.type == 1 and std.mem.eql(u8, method, "window/showMessage")) {
                editor.status_message = std.fmt.bufPrint(&editor.status_buf, "LSP {s}: {s}", .{ self.name(), p.message }) catch "LSP error — see zide.log";
            }
        }
        // $/progress and anything else: ignored
    }

    /// Server→client requests must be answered or the server may wait
    /// forever (lua-language-server blocks on workspace/configuration).
    fn handleServerRequest(self: *LspClient, id: std.json.Value, method: []const u8, json_bytes: []const u8, editor: anytype) void {
        _ = editor;
        if (std.mem.eql(u8, method, "workspace/configuration")) {
            self.answerConfiguration(id, json_bytes);
        } else if (std.mem.eql(u8, method, "workspace/workspaceFolders")) {
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(self.allocator);
            const uri = pathToUri(self.allocator, self.root_path) catch return;
            defer self.allocator.free(uri);
            result.appendSlice(self.allocator, "[{\"uri\":") catch return;
            writeJsonString(&result, self.allocator, uri) catch return;
            result.appendSlice(self.allocator, ",\"name\":") catch return;
            writeJsonString(&result, self.allocator, std.fs.path.basename(self.root_path)) catch return;
            result.appendSlice(self.allocator, "}]") catch return;
            self.respond(id, result.items);
        } else if (std.mem.eql(u8, method, "client/registerCapability") or
            std.mem.eql(u8, method, "client/unregisterCapability") or
            std.mem.eql(u8, method, "window/workDoneProgress/create") or
            std.mem.eql(u8, method, "window/showMessageRequest"))
        {
            self.respond(id, "null");
        } else {
            std.log.info("LSP[{s}] unsupported request {s} — answered MethodNotFound", .{ self.name(), method });
            self.respondError(id, -32601, "method not found");
        }
    }

    fn respond(self: *LspClient, id: std.json.Value, result_json: []const u8) void {
        const body = buildResponse(self.allocator, id, result_json) catch return;
        defer self.allocator.free(body);
        self.writeMessage(body) catch {};
    }

    fn respondError(self: *LspClient, id: std.json.Value, code: i64, message: []const u8) void {
        const body = buildErrorResponse(self.allocator, id, code, message) catch return;
        defer self.allocator.free(body);
        self.writeMessage(body) catch {};
    }

    /// Answer `workspace/configuration`: one entry per requested item, the
    /// dotted `section` looked up in the registration's `settings` table
    /// (null when unset or missing). The JSON is parsed per request — it
    /// arrives once or a handful of times, not worth caching a tree.
    fn answerConfiguration(self: *LspClient, id: std.json.Value, json_bytes: []const u8) void {
        const Req = struct { params: struct { items: []const struct { section: ?[]const u8 = null } = &.{} } };
        const parsed = std.json.parseFromSlice(Req, self.allocator, json_bytes, .{ .ignore_unknown_fields = true }) catch {
            self.respond(id, "[]");
            return;
        };
        defer parsed.deinit();
        const items = parsed.value.params.items;

        var settings: ?std.json.Parsed(std.json.Value) = null;
        defer if (settings) |*s| s.deinit();
        if (self.config) |*cfg| {
            if (cfg.settings_json) |text| {
                settings = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch null;
            }
        }

        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.allocator);
        result.append(self.allocator, '[') catch return;
        for (items, 0..) |item, i| {
            if (i > 0) result.append(self.allocator, ',') catch return;
            const value: ?std.json.Value = if (settings) |s| settingsSection(s.value, item.section orelse "") else null;
            if (value) |v| {
                const text = std.json.Stringify.valueAlloc(self.allocator, v, .{}) catch return;
                defer self.allocator.free(text);
                result.appendSlice(self.allocator, text) catch return;
            } else {
                result.appendSlice(self.allocator, "null") catch return;
            }
        }
        result.append(self.allocator, ']') catch return;
        self.respond(id, result.items);
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
        const items = parseCompletionItems(self.allocator, json_bytes) catch return;
        defer self.allocator.free(items);

        // Store in editor completion state (the editor owns the strings now)
        const context = editor.completion_context;
        editor.clearCompletionItems();
        editor.completion_context = context;
        if (editor.completion_context) |*ctx| ctx.generation = editor.completion_generation;
        for (items) |item| {
            editor.addCompletionEntry(item) catch {
                freeCompletionEntry(self.allocator, item);
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
        const io = self.io;

        // Manual read buffer — readStreaming is the pipe-safe primitive
        // (positional reads are invalid on pipes).
        var buf: [8192]u8 = undefined;
        var buf_start: usize = 0;
        var buf_end: usize = 0;

        while (self.running.load(.acquire)) {
            // Read Content-Length header
            const content_len = pipeReadContentLength(io, stdout_file, &buf, &buf_start, &buf_end) catch break;
            if (content_len == 0) continue;

            // Read the JSON body
            const json_buf = self.allocator.alloc(u8, content_len) catch break;
            pipeReadExact(io, stdout_file, &buf, &buf_start, &buf_end, json_buf) catch {
                self.allocator.free(json_buf);
                break;
            };

            // Push to queue
            self.incoming.push(io, .{ .json_bytes = json_buf }, self.allocator);

            // Wake TUI if needed
            if (self.tui_wake_fn) |wake| {
                wake();
            }
        }
        // EOF / read error / stop(): tell the main thread the server's
        // stdout is gone (death detection + stop()'s grace loop) and wake
        // the TUI so it notices without waiting for a keypress.
        self.reader_done.store(true, .release);
        if (self.tui_wake_fn) |wake| wake();
    }
};

// ---------------------------------------------------------------------------
// Pipe-safe reading helpers (readStreaming only — never positional reads)
// ---------------------------------------------------------------------------

/// Read a single byte from the pipe, using the manual buffer for efficiency.
fn pipeReadByte(
    io: std.Io,
    file: std.Io.File,
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
    const n = file.readStreaming(io, &.{buf}) catch return error.EndOfStream;
    if (n == 0) return error.EndOfStream;
    buf_start.* = 1;
    buf_end.* = n;
    return buf[0];
}

/// Read exactly `dest.len` bytes from the pipe into `dest`.
fn pipeReadExact(
    io: std.Io,
    file: std.Io.File,
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
                const n = file.readStreaming(io, &.{dest[written..]}) catch return error.EndOfStream;
                if (n == 0) return error.EndOfStream;
                written += n;
            } else {
                const n = file.readStreaming(io, &.{buf}) catch return error.EndOfStream;
                if (n == 0) return error.EndOfStream;
                buf_start.* = 0;
                buf_end.* = n;
            }
        }
    }
}

/// Parse Content-Length from LSP JSON-RPC headers using pipe-safe reads.
fn pipeReadContentLength(
    io: std.Io,
    file: std.Io.File,
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
            const byte = pipeReadByte(io, file, buf, buf_start, buf_end) catch return error.EndOfStream;
            if (byte == '\n') break;
            line_buf[line_len] = byte;
            line_len += 1;
        }

        // Strip trailing \r
        const line = std.mem.trimEnd(u8, line_buf[0..line_len], "\r");

        // Empty line = end of headers
        if (line.len == 0) break;

        // Parse Content-Length
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val_str = std.mem.trimStart(u8, line["content-length:".len..], " ");
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

    try result.appendSlice(allocator, "file:///");

    for (path) |ch| {
        if (ch == '\\') {
            try result.append(allocator, '/');
        } else if (ch == ' ') {
            try result.appendSlice(allocator, "%20");
        } else {
            try result.append(allocator, ch);
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
                try result.append(allocator, path_part[i]);
                i += 1;
                continue;
            };
            const low = std.fmt.charToDigit(path_part[i + 2], 16) catch {
                try result.append(allocator, path_part[i]);
                i += 1;
                continue;
            };
            try result.append(allocator, @as(u8, high) * 16 + low);
            i += 3;
        } else if (builtin.os.tag == .windows and path_part[i] == '/') {
            try result.append(allocator, '\\');
            i += 1;
        } else {
            try result.append(allocator, path_part[i]);
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

/// Checked conversion for edits: never clamp an invalid server position.
pub fn checkedUtf16ColToByte(line: []const u8, column: u32) !usize {
    var units: u32 = 0;
    var off: usize = 0;
    while (units < column) {
        if (off >= line.len) return error.InvalidCompletionEdit;
        const len = std.unicode.utf8ByteSequenceLength(line[off]) catch return error.InvalidCompletionEdit;
        if (len > line.len - off) return error.InvalidCompletionEdit;
        const cp = std.unicode.utf8Decode(line[off..][0..len]) catch return error.InvalidCompletionEdit;
        const width: u32 = if (cp >= 0x10000) 2 else 1;
        if (width > column - units) return error.InvalidCompletionEdit;
        units += width;
        off += len;
    }
    return off;
}

// ---------------------------------------------------------------------------
// JSON string escaping
// ---------------------------------------------------------------------------

pub fn writeJsonString(list: *std.ArrayList(u8), gpa: Allocator, text: []const u8) !void {
    try list.append(gpa, '"');
    for (text) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(gpa, "\\\""),
            '\\' => try list.appendSlice(gpa, "\\\\"),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            '\t' => try list.appendSlice(gpa, "\\t"),
            else => {
                if (ch < 0x20) {
                    try list.print(gpa, "\\u{x:0>4}", .{ch});
                } else {
                    try list.append(gpa, ch);
                }
            },
        }
    }
    try list.append(gpa, '"');
}

// ---------------------------------------------------------------------------
// JSON-RPC classification, envelope builders, initialize params
// ---------------------------------------------------------------------------

pub const MessageKind = enum { response, request, notification, invalid };

/// A message with both id and method is a server→client REQUEST (it wants
/// an answer); id alone is a response to one of ours; method alone is a
/// notification. A JSON `null` id counts as absent.
pub fn classifyMessage(id: ?std.json.Value, method: ?[]const u8) MessageKind {
    const has_id = if (id) |v| v != .null else false;
    if (has_id and method != null) return .request;
    if (has_id) return .response;
    if (method != null) return .notification;
    return .invalid;
}

/// Write a JSON-RPC id back out (integer or string; anything else → null).
pub fn writeJsonId(list: *std.ArrayList(u8), gpa: Allocator, id: std.json.Value) !void {
    switch (id) {
        .integer => |n| try list.print(gpa, "{d}", .{n}),
        .string => |s| try writeJsonString(list, gpa, s),
        else => try list.appendSlice(gpa, "null"),
    }
}

/// `{"jsonrpc":"2.0","id":<id>,"result":<result_json>}`
pub fn buildResponse(gpa: Allocator, id: std.json.Value, result_json: []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonId(&body, gpa, id);
    try body.appendSlice(gpa, ",\"result\":");
    try body.appendSlice(gpa, result_json);
    try body.append(gpa, '}');
    return body.toOwnedSlice(gpa);
}

/// `{"jsonrpc":"2.0","id":<id>,"error":{"code":<code>,"message":<message>}}`
pub fn buildErrorResponse(gpa: Allocator, id: std.json.Value, code: i64, message: []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonId(&body, gpa, id);
    try body.appendSlice(gpa, ",\"error\":{\"code\":");
    try body.print(gpa, "{d}", .{code});
    try body.appendSlice(gpa, ",\"message\":");
    try writeJsonString(&body, gpa, message);
    try body.appendSlice(gpa, "}}");
    return body.toOwnedSlice(gpa);
}

/// Look up a dotted `section` ("Lua.diagnostics") inside a parsed settings
/// tree. Empty section = the whole tree; a missing step = null.
pub fn settingsSection(root: std.json.Value, section: []const u8) ?std.json.Value {
    if (section.len == 0) return root;
    var cur = root;
    var it = std.mem.splitScalar(u8, section, '.');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        switch (cur) {
            .object => |obj| cur = obj.get(part) orelse return null,
            else => return null,
        }
    }
    return cur;
}

/// The `initialize` request params for a workspace rooted at `root_path`
/// (absolute). Declares the client capabilities ZIDE actually implements
/// plus the workspace ones needed for settings passthrough.
pub fn buildInitializeParams(gpa: Allocator, root_path: []const u8, init_options_json: ?[]const u8) ![]u8 {
    const root_uri = try pathToUri(gpa, root_path);
    defer gpa.free(root_uri);
    const folder_name = std.fs.path.basename(root_path);

    var p: std.ArrayList(u8) = .empty;
    errdefer p.deinit(gpa);
    try p.appendSlice(gpa, "{\"processId\":null,\"rootUri\":");
    try writeJsonString(&p, gpa, root_uri);
    try p.appendSlice(gpa, ",\"rootPath\":");
    try writeJsonString(&p, gpa, root_path);
    try p.appendSlice(gpa, ",\"workspaceFolders\":[{\"uri\":");
    try writeJsonString(&p, gpa, root_uri);
    try p.appendSlice(gpa, ",\"name\":");
    try writeJsonString(&p, gpa, if (folder_name.len > 0) folder_name else root_path);
    try p.appendSlice(gpa, "}],\"capabilities\":{");
    try p.appendSlice(gpa, "\"textDocument\":{");
    try p.appendSlice(gpa, "\"synchronization\":{\"didSave\":true,\"didOpen\":true,\"didClose\":true},");
    try p.appendSlice(gpa, "\"completion\":{\"completionItem\":{\"insertReplaceSupport\":true}},");
    try p.appendSlice(gpa, "\"publishDiagnostics\":{},");
    try p.appendSlice(gpa, "\"definition\":{}},");
    try p.appendSlice(gpa, "\"workspace\":{\"workspaceFolders\":true,\"configuration\":true,\"didChangeConfiguration\":{\"dynamicRegistration\":false}}");
    try p.append(gpa, '}');
    if (init_options_json) |opts| {
        try p.appendSlice(gpa, ",\"initializationOptions\":");
        try p.appendSlice(gpa, opts);
    }
    try p.append(gpa, '}');
    return p.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Completion response parsing
// ---------------------------------------------------------------------------

pub const CompletionEdit = union(enum) {
    replace: LspRange,
    insert_replace: struct { insert: LspRange, replace: LspRange },
};

pub const CompletionEntry = struct {
    label: []const u8,
    detail: ?[]const u8 = null,
    insert_text: ?[]const u8 = null,
    edit: ?CompletionEdit = null,
};

/// Parse a completion response in either shape — `CompletionList{items}`
/// (zls, clangd, lua-language-server) or a bare `CompletionItem[]` (the
/// vscode servers). Strings are duplicated with `gpa`; the caller owns
/// them and the returned slice.
pub fn parseCompletionItems(gpa: Allocator, json_bytes: []const u8) ![]CompletionEntry {
    var out: std.ArrayList(CompletionEntry) = .empty;
    errdefer {
        for (out.items) |e| freeCompletionEntry(gpa, e);
        out.deinit(gpa);
    }

    const ListForm = struct {
        result: ?struct { items: ?[]const CompletionItem = null } = null,
    };
    if (std.json.parseFromSlice(ListForm, gpa, json_bytes, .{ .ignore_unknown_fields = true })) |parsed| {
        defer parsed.deinit();
        const items = if (parsed.value.result) |r| (r.items orelse &.{}) else &.{};
        for (items) |item| try appendCompletionEntry(gpa, &out, item);
        return out.toOwnedSlice(gpa);
    } else |_| {}

    const ArrayForm = struct { result: ?[]const CompletionItem = null };
    const parsed = try std.json.parseFromSlice(ArrayForm, gpa, json_bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.result orelse &.{}) |item| try appendCompletionEntry(gpa, &out, item);
    return out.toOwnedSlice(gpa);
}

fn appendCompletionEntry(gpa: Allocator, out: *std.ArrayList(CompletionEntry), item: CompletionItem) !void {
    const label = try gpa.dupe(u8, item.label);
    errdefer gpa.free(label);
    const detail: ?[]const u8 = if (item.detail) |d| try gpa.dupe(u8, d) else null;
    errdefer if (detail) |d| gpa.free(d);
    var edit: ?CompletionEdit = null;
    if (item.textEdit) |te| {
        if (te.range) |range| {
            if (te.insert != null or te.replace != null) return error.InvalidCompletionEdit;
            edit = .{ .replace = range };
        } else {
            edit = .{ .insert_replace = .{
                .insert = te.insert orelse return error.InvalidCompletionEdit,
                .replace = te.replace orelse return error.InvalidCompletionEdit,
            } };
        }
    }
    const insert_src: ?[]const u8 = if (item.textEdit) |te| te.newText else item.insertText;
    const insert_text: ?[]const u8 = if (insert_src) |t| try gpa.dupe(u8, t) else null;
    errdefer if (insert_text) |t| gpa.free(t);
    try out.append(gpa, .{ .label = label, .detail = detail, .insert_text = insert_text, .edit = edit });
}

pub fn freeCompletionEntry(gpa: Allocator, e: CompletionEntry) void {
    gpa.free(e.label);
    if (e.detail) |d| gpa.free(d);
    if (e.insert_text) |t| gpa.free(t);
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
    try writeJsonString(&buf, alloc, "hello\n\"world\"\t\\end");
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
    const io = std.testing.io;
    const msg1 = try alloc.dupe(u8, "hello");
    q.push(io, .{ .json_bytes = msg1 }, alloc);
    const popped = q.tryPop(io).?;
    try std.testing.expectEqualStrings("hello", popped.json_bytes);
    alloc.free(popped.json_bytes);
    try std.testing.expect(q.tryPop(io) == null);
}

test "ServerConfig defaults, lookup, equality, display name" {
    const alloc = std.testing.allocator;
    var cfg = try ServerConfig.fromArgv(alloc, &.{ "C", "Cpp" }, &.{ "C:/x/clangd.exe", "--background-index" });
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("c", cfg.languageIdFor("c"));
    try std.testing.expectEqualStrings("cpp", cfg.languageIdFor("CPP"));
    try std.testing.expectEqualStrings("other", cfg.languageIdFor("other")); // unknown → passthrough
    try std.testing.expect(cfg.servesLanguage("cpp"));
    try std.testing.expect(!cfg.servesLanguage("zig"));
    try std.testing.expectEqualStrings("clangd", cfg.displayName());
    try std.testing.expectEqualStrings("pyright-langserver", programDisplayName("pyright-langserver.cmd"));
    try std.testing.expectEqualStrings("zls", programDisplayName("/usr/bin/zls"));

    var same = try cfg.clone(alloc);
    defer same.deinit(alloc);
    try std.testing.expect(cfg.eql(&same));
    try std.testing.expectEqualStrings("cpp", same.languageIdFor("cpp"));
    same.settings_json = try alloc.dupe(u8, "{}");
    try std.testing.expect(!cfg.eql(&same));
}

test "classifyMessage" {
    const int_id: std.json.Value = .{ .integer = 3 };
    const str_id: std.json.Value = .{ .string = "abc" };
    const null_id: std.json.Value = .null;
    try std.testing.expectEqual(MessageKind.response, classifyMessage(int_id, null));
    try std.testing.expectEqual(MessageKind.request, classifyMessage(str_id, "workspace/configuration"));
    try std.testing.expectEqual(MessageKind.request, classifyMessage(int_id, "client/registerCapability"));
    try std.testing.expectEqual(MessageKind.notification, classifyMessage(null, "$/progress"));
    try std.testing.expectEqual(MessageKind.notification, classifyMessage(null_id, "$/progress"));
    try std.testing.expectEqual(MessageKind.invalid, classifyMessage(null, null));
}

test "response envelopes echo integer and string ids" {
    const alloc = std.testing.allocator;
    const a = try buildResponse(alloc, .{ .integer = 7 }, "null");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":null}", a);
    const b = try buildErrorResponse(alloc, .{ .string = "x\"y" }, -32601, "method not found");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"x\\\"y\",\"error\":{\"code\":-32601,\"message\":\"method not found\"}}", b);
}

test "settingsSection walks dotted paths" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"Lua\":{\"diagnostics\":{\"globals\":[\"zide\"]}}}", .{});
    defer parsed.deinit();
    const hit = settingsSection(parsed.value, "Lua.diagnostics").?;
    try std.testing.expect(hit == .object);
    try std.testing.expect(hit.object.get("globals") != null);
    try std.testing.expect(settingsSection(parsed.value, "Lua.nope") == null);
    try std.testing.expect(settingsSection(parsed.value, "").? == .object);
    const text = try std.json.Stringify.valueAlloc(alloc, settingsSection(parsed.value, "Lua.diagnostics.globals").?, .{});
    defer alloc.free(text);
    try std.testing.expectEqualStrings("[\"zide\"]", text);
}

test "buildInitializeParams carries root, folders and init options" {
    const alloc = std.testing.allocator;
    const root = if (builtin.os.tag == .windows) "C:\\proj\\demo" else "/proj/demo";
    const params = try buildInitializeParams(alloc, root, "{\"a\":1}");
    defer alloc.free(params);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"rootUri\":\"file:///") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"workspaceFolders\":[{\"uri\":\"file:///") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"name\":\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"initializationOptions\":{\"a\":1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"configuration\":true") != null);
    if (builtin.os.tag == .windows) {
        // backslashes in rootPath must be JSON-escaped
        try std.testing.expect(std.mem.indexOf(u8, params, "\"rootPath\":\"C:\\\\proj\\\\demo\"") != null);
    }
    // Must be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, params, .{});
    defer parsed.deinit();

    const plain = try buildInitializeParams(alloc, root, null);
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "initializationOptions") == null);
}

test "parseCompletionItems handles list and array forms" {
    const alloc = std.testing.allocator;
    const list = try parseCompletionItems(alloc, "{\"id\":1,\"result\":{\"isIncomplete\":false,\"items\":[{\"label\":\"foo\",\"detail\":\"fn\"},{\"label\":\"bar\",\"textEdit\":{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}},\"newText\":\"bar()\"}}]}}");
    defer {
        for (list) |e| freeCompletionEntry(alloc, e);
        alloc.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("foo", list[0].label);
    try std.testing.expectEqualStrings("fn", list[0].detail.?);
    try std.testing.expect(list[0].insert_text == null);
    try std.testing.expectEqualStrings("bar()", list[1].insert_text.?);

    const arr = try parseCompletionItems(alloc, "{\"id\":2,\"result\":[{\"label\":\"baz\",\"insertText\":\"baz\"}]}");
    defer {
        for (arr) |e| freeCompletionEntry(alloc, e);
        alloc.free(arr);
    }
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    try std.testing.expectEqualStrings("baz", arr[0].insert_text.?);

    const none = try parseCompletionItems(alloc, "{\"id\":3,\"result\":null}");
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "MessageQueue overflow frees dropped messages" {
    var q = MessageQueue{};
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    // Push past capacity — the overwritten oldest messages must be freed
    // (std.testing.allocator fails the test on any leak).
    var i: usize = 0;
    while (i < QUEUE_CAP + 16) : (i += 1) {
        const msg = try alloc.dupe(u8, "x");
        q.push(io, .{ .json_bytes = msg }, alloc);
    }
    var popped: usize = 0;
    while (q.tryPop(io)) |msg| {
        alloc.free(msg.json_bytes);
        popped += 1;
    }
    try std.testing.expectEqual(@as(usize, QUEUE_CAP), popped);
}

test "completion parser rejects an edit with no usable range" {
    try std.testing.expectError(error.InvalidCompletionEdit, parseCompletionItems(std.testing.allocator,
        \\{"result":[{"label":"bad","textEdit":{"newText":"bad"}}]}
    ));
}
