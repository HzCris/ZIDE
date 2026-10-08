const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const protocol = @import("protocol.zig");

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
    version: ?i32 = null,
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
// Client request context and capability negotiation
// ---------------------------------------------------------------------------

var next_generation = std.atomic.Value(u64).init(1);

pub const RequestMethod = enum { initialize, completion, goto_definition, hover, references, document_symbol, workspace_symbol, signature_help, prepare_rename, rename, format_document, format_selection, shutdown };
pub const Request = struct {
    method: RequestMethod,
    doc_id: ?u64 = null,
    version: u64 = 0,
    generation: u64 = 0,
    deadline: i128 = 0,
    serial: u64 = 0,
    cursor: ?usize = null,
};
pub const Capabilities = struct {
    hover: bool = false,
    rename: bool = false,
    prepare_rename: bool = false,
    format_document: bool = false,
    format_selection: bool = false,
    completion: bool = false,
    references: bool = false,
    document_symbol: bool = false,
    workspace_symbol: bool = false,
    signature_help: bool = false,
    /// `completionProvider.triggerCharacters` (single-byte ones, up to 16).
    completion_triggers: [16]u8 = undefined,
    completion_trigger_len: u8 = 0,
    /// `signatureHelpProvider.triggerCharacters` + `retriggerCharacters`.
    signature_triggers: [8]u8 = undefined,
    signature_trigger_len: u8 = 0,

    pub fn isCompletionTrigger(self: *const Capabilities, b: u8) bool {
        return std.mem.indexOfScalar(u8, self.completion_triggers[0..self.completion_trigger_len], b) != null;
    }

    pub fn isSignatureTrigger(self: *const Capabilities, b: u8) bool {
        return std.mem.indexOfScalar(u8, self.signature_triggers[0..self.signature_trigger_len], b) != null;
    }
};

/// Collect the single-byte strings of a `triggerCharacters`-style array.
fn collectTriggerChars(value: ?std.json.Value, out: []u8, len: *u8) void {
    const array = value orelse return;
    if (array != .array) return;
    for (array.array.items) |item| {
        if (item != .string or item.string.len != 1) continue;
        if (len.* >= out.len) return;
        out[len.*] = item.string[0];
        len.* += 1;
    }
}
fn capability(value: std.json.Value, name: []const u8) bool {
    if (value != .object) return false;
    const property = value.object.get(name) orelse return false;
    return property == .object or (property == .bool and property.bool);
}

pub const LspClient = struct {
    allocator: Allocator,
    io: std.Io,
    peer: ?*protocol.Peer = null,
    generation: u64,
    capabilities: Capabilities = .{},
    position_encoding: @import("workspace_edit.zig").Encoding = .utf16,
    next_id: i64 = 1,
    initialized: bool = false,
    /// The server rejected `initialize` (or the handshake could not be
    /// written): treated like a dead server by the editor's sweep.
    dead: bool = false,

    // Optional TUI loop wake function
    tui_wake_fn: ?*const fn () void = null,

    // Pending request tracking
    pending: std.AutoHashMap(i64, Request) = undefined,

    /// Deep copy of the registration this server was started from — the
    /// editor's config list can be rewritten (reload_extensions) while the
    /// server keeps running. Null until start().
    config: ?ServerConfig = null,
    /// Absolute workspace root handed to the server at initialize. Owned.
    root_path: []const u8 = "",

    pub fn init(allocator: Allocator, io: std.Io) LspClient {
        return .{
            .allocator = allocator,
            .io = io,
            .generation = next_generation.fetchAdd(1, .monotonic),
            .pending = std.AutoHashMap(i64, Request).init(allocator),
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
        if (self.peer != null) return error.AlreadyStarted;
        if (config.argv.len == 0) return error.NoCommand;

        var cfg = try config.clone(self.allocator);
        var cfg_moved = false;
        errdefer if (!cfg_moved) cfg.deinit(self.allocator);
        const root = try self.allocator.dupe(u8, root_path);
        errdefer if (!cfg_moved) self.allocator.free(root);

        self.peer = try protocol.Peer.start(self.allocator, self.io, cfg.argv, root_path, self.tui_wake_fn);
        self.initialized = false;
        self.dead = false;

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
        if (self.peer) |peer| {
            if (self.initialized and !self.dead and !peer.stopped()) {
                _ = self.sendRequest("shutdown", "null") catch {};
                self.sendNotification("exit", "null") catch {};
                var elapsed: u32 = 0;
                while (!peer.stopped() and elapsed < 200) : (elapsed += 10) {
                    std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
                }
            }
            peer.deinit();
            self.peer = null;
        }
        self.initialized = false;
        self.dead = false;
        self.pending.clearRetainingCapacity();

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
        return self.peer != null and self.initialized and !self.dead and !self.peer.?.stopped();
    }

    /// The server went away on its own (crash/exit) or rejected initialize.
    /// The editor sweeps such clients (stop + destroy) and marks their
    /// config failed so the lazy start doesn't respawn a crashing server.
    pub fn isDead(self: *const LspClient) bool {
        return self.peer != null and (self.dead or self.peer.?.stopped());
    }

    pub fn diagnosticSource(self: *const LspClient, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}#{d}", .{ self.name(), self.generation }) catch std.fmt.bufPrint(buf, "LSP#{d}", .{self.generation}) catch "LSP";
    }

    pub fn setWake(self: *LspClient, wake: ?*const fn () void) void {
        self.tui_wake_fn = wake;
        if (self.peer) |peer| peer.setWake(wake);
    }

    pub fn request(self: *LspClient, method: []const u8, params: []const u8, context: Request) !i64 {
        if (self.pending.count() >= 256) return error.TooManyRequests;
        try self.pending.ensureUnusedCapacity(1);
        const id = try self.sendRequest(method, params);
        var tracked = context;
        tracked.generation = self.generation;
        // Slow starters (jdtls, rust-analyzer on a cold cache) need longer
        // than a feature request to answer `initialize`.
        const seconds: i128 = if (context.method == .initialize) 60 else 10;
        tracked.deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + seconds * std.time.ns_per_s;
        self.pending.putAssumeCapacity(id, tracked);
        return id;
    }

    pub fn cancelRequest(self: *LspClient, id: i64) void {
        if (!self.pending.remove(id)) return;
        var buf: [48]u8 = undefined;
        const params = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch return;
        self.sendNotification("$/cancelRequest", params) catch {};
    }

    pub fn expireRequests(self: *LspClient, editor: anytype, now: i128) void {
        while (true) {
            var expired: ?struct { id: i64, context: Request } = null;
            var iterator = self.pending.iterator();
            while (iterator.next()) |entry| if (entry.value_ptr.deadline <= now) {
                expired = .{ .id = entry.key_ptr.*, .context = entry.value_ptr.* };
                break;
            };
            const item = expired orelse return;
            self.cancelRequest(item.id);
            if (item.context.method == .initialize) self.dead = true;
            editor.lsp_tools.failed(editor, self, item.context, "Request timed out");
        }
    }

    pub fn negotiate(self: *LspClient, json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidCapabilities;
        const result = parsed.value.object.get("result") orelse return error.InvalidCapabilities;
        if (result != .object) return error.InvalidCapabilities;
        const caps = result.object.get("capabilities") orelse return error.InvalidCapabilities;
        if (caps != .object) return error.InvalidCapabilities;
        self.capabilities = .{
            .hover = capability(caps, "hoverProvider"),
            .rename = capability(caps, "renameProvider"),
            .format_document = capability(caps, "documentFormattingProvider"),
            .format_selection = capability(caps, "documentRangeFormattingProvider"),
        };
        if (caps.object.get("renameProvider")) |rename| {
            if (rename == .object) self.capabilities.prepare_rename = capability(rename, "prepareProvider");
        }
        self.capabilities.completion = capability(caps, "completionProvider");
        self.capabilities.references = capability(caps, "referencesProvider");
        self.capabilities.document_symbol = capability(caps, "documentSymbolProvider");
        self.capabilities.workspace_symbol = capability(caps, "workspaceSymbolProvider");
        self.capabilities.signature_help = capability(caps, "signatureHelpProvider");
        if (caps.object.get("signatureHelpProvider")) |provider| {
            if (provider == .object) {
                collectTriggerChars(provider.object.get("triggerCharacters"), &self.capabilities.signature_triggers, &self.capabilities.signature_trigger_len);
                collectTriggerChars(provider.object.get("retriggerCharacters"), &self.capabilities.signature_triggers, &self.capabilities.signature_trigger_len);
            }
        }
        if (caps.object.get("completionProvider")) |provider| {
            if (provider == .object) {
                if (provider.object.get("triggerCharacters")) |triggers| {
                    if (triggers == .array) {
                        for (triggers.array.items) |item| {
                            if (item != .string or item.string.len != 1) continue;
                            const n = self.capabilities.completion_trigger_len;
                            if (n >= self.capabilities.completion_triggers.len) break;
                            self.capabilities.completion_triggers[n] = item.string[0];
                            self.capabilities.completion_trigger_len = n + 1;
                        }
                    }
                }
            }
        }
        self.position_encoding = .utf16;
        if (caps.object.get("positionEncoding")) |encoding| {
            if (encoding != .string) return error.InvalidCapabilities;
            if (std.mem.eql(u8, encoding.string, "utf-8")) self.position_encoding = .utf8 else if (!std.mem.eql(u8, encoding.string, "utf-16")) return error.UnsupportedPositionEncoding;
        }
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
        try (self.peer orelse return error.NotRunning).send(body);
    }

    // ----- Initialize handshake -----

    fn sendInitialize(self: *LspClient) !void {
        const cfg = if (self.config) |*c| c else return error.NotRunning;
        const params = try buildInitializeParams(self.allocator, self.root_path, cfg.init_options_json);
        defer self.allocator.free(params);

        _ = try self.request("initialize", params, .{ .method = .initialize });
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

        return self.request("textDocument/completion", params.items, .{ .method = .completion });
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

        return self.request("textDocument/definition", params.items, .{ .method = .goto_definition });
    }

    // ----- Message polling (called from main thread) -----

    /// Messages handled per tick, so a burst can't stall a frame.
    pub const max_messages_per_poll = 64;

    pub fn pollMessages(self: *LspClient, editor: anytype) void {
        const peer = self.peer orelse return;
        for (0..max_messages_per_poll) |_| {
            const message = peer.take() orelse return;
            defer self.allocator.free(message);
            self.dispatchMessage(message, editor);
        }
        // Cap hit. The reader only wakes the loop for NEW messages, so the
        // rest would wait for the next input event or the 1.5 s poll: skip
        // the frontend's next sleep instead and let the next tick continue.
        if (peer.hasIncoming()) editor.deadlines.run_again = true;
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
        const context = self.pending.get(id) orelse return;
        const method = context.method;
        _ = self.pending.remove(id);
        if (context.generation != self.generation) return;
        if (context.doc_id) |doc_id| {
            const index = editor.docIndexForId(doc_id);
            if (index == null or editor.documents.items[index.?].buffer.version != context.version) {
                editor.lsp_tools.failed(editor, self, context, "Document changed; request cancelled");
                return;
            }
        }

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
                editor.lsp_tools.failed(editor, self, context, e.message);
                return;
            }
        } else |_| {}

        switch (method) {
            .initialize => {
                self.negotiate(json_bytes) catch {
                    self.dead = true;
                    editor.status_message = "LSP capability or position encoding negotiation failed";
                    return;
                };
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
                if (context.doc_id == null or (editor.activeDoc().id == context.doc_id.? and (context.cursor == null or editor.activeDoc().cursors.primary().offset == context.cursor.?))) self.handleDefinitionResponse(json_bytes, editor);
            },
            .hover, .references, .document_symbol, .workspace_symbol, .signature_help, .prepare_rename, .rename, .format_document, .format_selection => editor.lsp_tools.response(editor, self, context, json_bytes),
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
        if (std.mem.eql(u8, method, "workspace/applyEdit")) {
            editor.lsp_tools.serverEdit(editor, self, id, json_bytes);
        } else if (std.mem.eql(u8, method, "workspace/configuration")) {
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

    pub fn respond(self: *LspClient, id: std.json.Value, result_json: []const u8) void {
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

        if (params.version) |version| for (editor.documents.items) |*doc| {
            if (doc.file_path) |path| if (editor.pathsEqual(path, file_path) and version != doc.lsp_version) return;
        };

        var items: std.ArrayList(Diagnostic) = .empty;
        defer items.deinit(self.allocator);
        for (params.diagnostics) |diagnostic| {
            items.append(self.allocator, .{
                .start_line = diagnostic.range.start.line,
                .start_col = diagnostic.range.start.character,
                .end_line = diagnostic.range.end.line,
                .end_col = diagnostic.range.end.character,
                .severity = switch (diagnostic.severity orelse 1) {
                    1 => .err,
                    2 => .warning,
                    3 => .information,
                    else => .hint,
                },
                .message = diagnostic.message,
            }) catch return;
        }
        var producer_buf: [256]u8 = undefined;
        editor.problems.replace(file_path, self.diagnosticSource(&producer_buf), .lsp, params.version, if (self.position_encoding == .utf16) .utf16 else .bytes, items.items) catch return;
        for (editor.documents.items) |*doc| {
            if (doc.file_path) |path| if (editor.pathsEqual(path, file_path)) editor.problems.project(doc, .lsp) catch {};
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
        editor.completion_stale = false;
        std.log.info("LSP[{s}] completion: {d} items, {d} match the typed prefix", .{ self.name(), items.len, editor.completion_items.items.len });
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
        // Opened by lsp_tools.tick after the poll loop: an `open` hook may
        // restart servers and free this client mid-dispatch.
        editor.lsp_tools.queueDefinition(editor, file_path, loc.range.start, self.position_encoding);
    }
};

// ---------------------------------------------------------------------------
// URI <-> Path conversion
// ---------------------------------------------------------------------------

pub fn pathToUri(allocator: Allocator, path: []const u8) ![]const u8 {
    return @import("file_uri.zig").encode(allocator, path);
}

pub fn uriToPath(allocator: Allocator, uri: []const u8) ![]const u8 {
    return @import("file_uri.zig").decode(allocator, uri, builtin.os.tag == .windows);
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

/// Server position → byte column for edits and locations. A column past the
/// end of the line means the end of the line (LSP 3.17); a column inside a
/// surrogate pair, or text that is not UTF-8, is rejected, never guessed.
pub fn checkedUtf16ColToByte(line: []const u8, column: u32) !usize {
    var units: u32 = 0;
    var off: usize = 0;
    while (units < column) {
        if (off >= line.len) return line.len;
        const len = std.unicode.utf8ByteSequenceLength(line[off]) catch return error.InvalidRange;
        if (len > line.len - off) return error.InvalidRange;
        const cp = std.unicode.utf8Decode(line[off..][0..len]) catch return error.InvalidRange;
        const width: u32 = if (cp >= 0x10000) 2 else 1;
        if (width > column - units) return error.InvalidRange;
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
    try p.appendSlice(gpa, "\"general\":{\"positionEncodings\":[\"utf-8\",\"utf-16\"]},");
    try p.appendSlice(gpa, "\"textDocument\":{");
    try p.appendSlice(gpa, "\"synchronization\":{\"didSave\":true,\"didOpen\":true,\"didClose\":true},");
    try p.appendSlice(gpa, "\"completion\":{\"completionItem\":{\"insertReplaceSupport\":true}},");
    try p.appendSlice(gpa, "\"publishDiagnostics\":{},");
    try p.appendSlice(gpa, "\"hover\":{\"contentFormat\":[\"plaintext\"]},\"rename\":{\"prepareSupport\":true},\"formatting\":{},\"rangeFormatting\":{},\"definition\":{}},");
    try p.appendSlice(gpa, "\"workspace\":{\"applyEdit\":true,\"workspaceEdit\":{\"documentChanges\":true,\"resourceOperations\":[],\"failureHandling\":\"transactional\"},\"workspaceFolders\":true,\"configuration\":true,\"didChangeConfiguration\":{\"dynamicRegistration\":false}}");
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
        try std.testing.expectEqualStrings("\\path\\to my\\file.zig", path);
    } else {
        try std.testing.expectEqualStrings("/path/to my/file.zig", path);
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

    // Server positions: past the end means the line end (LSP 3.17); a column
    // inside a surrogate pair is rejected.
    try std.testing.expectEqual(@as(usize, 2), try checkedUtf16ColToByte("ab", 99));
    try std.testing.expectEqual(@as(usize, 5), try checkedUtf16ColToByte(emoji, 3));
    try std.testing.expectError(error.InvalidRange, checkedUtf16ColToByte(emoji, 2));
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

test "completion parser rejects an edit with no usable range" {
    try std.testing.expectError(error.InvalidCompletionEdit, parseCompletionItems(std.testing.allocator,
        \\{"result":[{"label":"bad","textEdit":{"newText":"bad"}}]}
    ));
}

test "LSP negotiates capabilities and rejects unsupported position encodings" {
    const t = std.testing;
    var client = LspClient.init(t.allocator, t.io);
    defer client.deinit();
    try client.negotiate("{\"result\":{\"capabilities\":{\"positionEncoding\":\"utf-8\",\"hoverProvider\":true,\"renameProvider\":{\"prepareProvider\":true},\"documentFormattingProvider\":{}}}}");
    try t.expect(client.capabilities.hover and client.capabilities.rename and client.capabilities.prepare_rename and client.capabilities.format_document);
    try t.expectEqual(@import("workspace_edit.zig").Encoding.utf8, client.position_encoding);
    try t.expect(!client.capabilities.format_selection);
    try client.negotiate("{\"result\":{\"capabilities\":{}}}");
    try t.expectEqual(@import("workspace_edit.zig").Encoding.utf16, client.position_encoding);
    try t.expect(!client.capabilities.hover);
    try t.expectError(error.UnsupportedPositionEncoding, client.negotiate("{\"result\":{\"capabilities\":{\"positionEncoding\":\"utf-32\"}}}"));
}

test "a references reply fills the References view with excerpts and opens on Enter" {
    const t = std.testing;
    const Editor = @import("editor.zig").Editor;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile(t.io, "target.zig", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "const a = 1;\n    const b = a;\nconst c = a;\n");
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const target = try std.fs.path.join(t.allocator, &.{ root, "target.zig" });
    defer t.allocator.free(target);
    const uri = try pathToUri(t.allocator, target);
    defer t.allocator.free(uri);

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    var client = LspClient.init(t.allocator, t.io);
    defer client.deinit();
    const doc = editor.activeDoc();
    try doc.insertAtCursor("a");
    editor.lsp_tools.references_symbol[0] = 'a';
    editor.lsp_tools.references_symbol_len = 1;
    try client.pending.put(1, .{ .method = .references, .generation = client.generation, .doc_id = doc.id, .version = doc.buffer.version, .cursor = doc.cursors.primary().offset, .serial = editor.lsp_tools.serial });
    const reply = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":1,\"character\":14}},\"end\":{{\"line\":1,\"character\":15}}}}}},{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":2,\"character\":10}},\"end\":{{\"line\":2,\"character\":11}}}}}}]}}", .{ uri, uri });
    defer t.allocator.free(reply);
    client.dispatchMessage(reply, &editor);
    try t.expectEqual(@as(usize, 2), editor.lsp_tools.references.items.len);
    try t.expectEqual(Editor.Mode.tool_panel, editor.mode);
    try t.expectEqual(@import("tool_panel.zig").Kind.references, editor.tool_panel.kind);
    try t.expectEqualStrings("const b = a;", editor.lsp_tools.references.items[0].excerpt);
    var row_buf: [512]u8 = undefined;
    const row = editor.tool_panel.row(&editor, 0, &row_buf);
    try t.expect(std.mem.indexOf(u8, row, "target.zig:2:15") != null);
    try t.expect(std.mem.indexOf(u8, row, "const b = a;") != null);
    var title_buf: [256]u8 = undefined;
    try t.expect(std.mem.startsWith(u8, editor.tool_panel.title(&editor, &title_buf), "References to a: 2"));
    // Enter opens the location (a recorded jump).
    editor.tool_panel.activate(&editor);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expect(editor.pathsEqual(editor.activeDoc().file_path.?, target));
    try t.expectEqual(@as(usize, 1), editor.activeDoc().buffer.offsetToPos(editor.activeDoc().cursors.primary().offset).line);
    // An empty reply reports and leaves the editor alone.
    try client.pending.put(2, .{ .method = .references, .generation = client.generation, .doc_id = editor.activeDoc().id, .version = editor.activeDoc().buffer.version, .cursor = editor.activeDoc().cursors.primary().offset, .serial = editor.lsp_tools.serial });
    client.dispatchMessage("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[]}", &editor);
    try t.expectEqualStrings("No references found", editor.status_message);
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqual(@as(usize, 0), editor.lsp_tools.references.items.len);
}

test "document and workspace symbol replies fill the picker; Enter jumps" {
    const t = std.testing;
    const Editor = @import("editor.zig").Editor;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile(t.io, "target.zig", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "pub fn main() void {\n    var inner = 1;\n}\nconst Editor = struct {};\n");
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const target = try std.fs.path.join(t.allocator, &.{ root, "target.zig" });
    defer t.allocator.free(target);
    const uri = try pathToUri(t.allocator, target);
    defer t.allocator.free(uri);

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    var client = LspClient.init(t.allocator, t.io);
    defer client.deinit();
    const doc = try editor.openFile(target);
    // Document symbols: a hierarchical reply becomes rows with the parent in the detail.
    try client.pending.put(1, .{ .method = .document_symbol, .generation = client.generation, .doc_id = doc.id, .version = doc.buffer.version, .serial = editor.lsp_tools.serial });
    client.dispatchMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"name\":\"main\",\"kind\":12,\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":2,\"character\":1}},\"selectionRange\":{\"start\":{\"line\":0,\"character\":7},\"end\":{\"line\":0,\"character\":11}},\"children\":[{\"name\":\"inner\",\"kind\":13,\"range\":{\"start\":{\"line\":1,\"character\":4},\"end\":{\"line\":1,\"character\":18}},\"selectionRange\":{\"start\":{\"line\":1,\"character\":8},\"end\":{\"line\":1,\"character\":13}}}]},{\"name\":\"Editor\",\"kind\":23,\"range\":{\"start\":{\"line\":3,\"character\":0},\"end\":{\"line\":3,\"character\":25}},\"selectionRange\":{\"start\":{\"line\":3,\"character\":6},\"end\":{\"line\":3,\"character\":12}}}]}", &editor);
    try t.expectEqual(Editor.Mode.picker, editor.mode);
    try t.expectEqual(@as(usize, 3), editor.picker.count());
    try t.expectEqualStrings("main", editor.picker.itemAt(0).label);
    try t.expectEqualStrings("function", editor.picker.itemAt(0).detail);
    try t.expectEqualStrings("inner", editor.picker.itemAt(1).label);
    try t.expectEqualStrings("variable in main", editor.picker.itemAt(1).detail);
    editor.pickerTyped("in"); // "inner" by prefix, "main" by subsequence
    try t.expectEqual(@as(usize, 2), editor.picker.count());
    try t.expectEqualStrings("inner", editor.picker.itemAt(0).label);
    editor.pickerTyped("n");
    try t.expectEqual(@as(usize, 1), editor.picker.count());
    editor.pickerConfirm();
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    const after = editor.activeDoc().buffer.offsetToPos(editor.activeDoc().cursors.primary().offset);
    try t.expectEqual(@as(usize, 1), after.line);
    try t.expectEqual(@as(usize, 8), after.col);
    // Workspace symbols: the picker opens empty; a reply for the typed query fills it.
    editor.lsp_tools.beginWorkspaceSymbols(&editor);
    try t.expectEqual(Editor.Mode.picker, editor.mode);
    try t.expectEqual(@as(usize, 0), editor.picker.count());
    editor.picker.typeText("Ed"); // the filter alone: no server to ask here
    try client.pending.put(2, .{ .method = .workspace_symbol, .generation = client.generation, .doc_id = editor.activeDoc().id, .version = editor.activeDoc().buffer.version, .serial = editor.lsp_tools.serial });
    const reply = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{{\"name\":\"Editor\",\"kind\":23,\"location\":{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":3,\"character\":6}},\"end\":{{\"line\":3,\"character\":12}}}}}},\"containerName\":\"target.zig\"}}]}}", .{uri});
    defer t.allocator.free(reply);
    client.dispatchMessage(reply, &editor);
    try t.expectEqual(@as(usize, 1), editor.picker.count());
    try t.expectEqualStrings("Editor", editor.picker.itemAt(0).label);
    try t.expect(std.mem.indexOf(u8, editor.picker.itemAt(0).detail, "struct") != null);
    editor.pickerConfirm();
    try t.expectEqual(Editor.Mode.normal, editor.mode);
    try t.expectEqual(@as(usize, 3), editor.activeDoc().buffer.offsetToPos(editor.activeDoc().cursors.primary().offset).line);
}

test "LSP negotiation keeps the completion trigger characters" {
    const t = std.testing;
    var client = LspClient.init(t.allocator, t.io);
    defer client.deinit();
    try client.negotiate("{\"result\":{\"capabilities\":{\"completionProvider\":{\"triggerCharacters\":[\".\",\"@\",\"->\"]}}}}");
    try t.expect(client.capabilities.completion);
    try t.expect(client.capabilities.isCompletionTrigger('.'));
    try t.expect(client.capabilities.isCompletionTrigger('@'));
    try t.expect(!client.capabilities.isCompletionTrigger('-')); // multi-byte triggers are skipped
    try t.expect(!client.capabilities.isCompletionTrigger('x'));
    try client.negotiate("{\"result\":{\"capabilities\":{\"completionProvider\":true}}}");
    try t.expect(client.capabilities.completion);
    try t.expect(!client.capabilities.isCompletionTrigger('.'));
    try client.negotiate("{\"result\":{\"capabilities\":{\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\"],\"retriggerCharacters\":[\",\"]}}}}");
    try t.expect(client.capabilities.signature_help);
    try t.expect(client.capabilities.isSignatureTrigger('('));
    try t.expect(client.capabilities.isSignatureTrigger(','));
    try t.expect(!client.capabilities.isSignatureTrigger(')'));
}

test "a signature help reply shows the active parameter; ')' and leaving the line hide it" {
    const t = std.testing;
    const Editor = @import("editor.zig").Editor;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    var client = LspClient.init(t.allocator, t.io);
    defer client.deinit();
    const doc = editor.activeDoc();
    try doc.insertAtCursor("one\nfoo(a, ");
    try client.pending.put(1, .{ .method = .signature_help, .generation = client.generation, .doc_id = doc.id, .version = doc.buffer.version, .cursor = doc.cursors.primary().offset, .serial = editor.lsp_tools.serial });
    client.dispatchMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"signatures\":[{\"label\":\"fn foo(a: u8, b: []const u8) void\",\"documentation\":{\"kind\":\"markdown\",\"value\":\"Does foo.\\nMore.\"},\"parameters\":[{\"label\":\"a: u8\"},{\"label\":[14,27],\"documentation\":\"the b parameter\"}]}],\"activeSignature\":0,\"activeParameter\":1}}", &editor);
    const sig = editor.signature.?;
    try t.expectEqualStrings("fn foo(a: u8, b: []const u8) void", sig.label);
    try t.expectEqual(@as(usize, 14), sig.param_start);
    try t.expectEqual(@as(usize, 27), sig.param_end);
    try t.expectEqualStrings("the b parameter", sig.doc);
    try t.expect(editor.signatureVisible());
    // Typing ')' closes it.
    _ = editor.execCommand("insert_char", ")");
    try t.expect(editor.signature == null);
    // A string parameter label is located in the signature; the
    // signature's own documentation stands in; another line drops it.
    try client.pending.put(2, .{ .method = .signature_help, .generation = client.generation, .doc_id = doc.id, .version = doc.buffer.version, .cursor = doc.cursors.primary().offset, .serial = editor.lsp_tools.serial });
    client.dispatchMessage("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"signatures\":[{\"label\":\"fn bar(x: i32) void\",\"documentation\":\"Bar it.\",\"parameters\":[{\"label\":\"x: i32\"}]}]}}", &editor);
    try t.expectEqualStrings("fn bar(x: i32) void", editor.signature.?.label);
    try t.expectEqual(@as(usize, 7), editor.signature.?.param_start);
    try t.expectEqual(@as(usize, 13), editor.signature.?.param_end);
    try t.expectEqualStrings("Bar it.", editor.signature.?.doc);
    doc.gotoLine(1);
    try t.expect(!editor.signatureVisible());
    try t.expect(editor.signature == null);
}

test "LSP drops stale and out-of-order feature replies; timeout aborts formatting save" {
    const t = std.testing;
    const Editor = @import("editor.zig").Editor;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    var client = LspClient.init(t.allocator, t.io);
    defer client.deinit();
    const doc = editor.activeDoc();
    try doc.insertAtCursor("😀 name");
    var request: Request = .{ .method = .hover, .generation = client.generation, .doc_id = doc.id, .version = doc.buffer.version, .serial = 1, .cursor = doc.cursors.primary().offset };
    editor.lsp_tools.serial = 2;
    try client.pending.put(1, request);
    client.dispatchMessage("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"contents\":\"old hover\"}}", &editor);
    try t.expect(editor.lsp_tools.hover == null);
    request.serial = 2;
    try client.pending.put(2, request);
    client.dispatchMessage("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"contents\":{\"kind\":\"plaintext\",\"value\":\"name: i32\"}}}", &editor);
    try t.expectEqualStrings("name: i32", editor.lsp_tools.hover.?);
    editor.mode = .normal;
    request.method = .format_document;
    editor.lsp_tools.formatting = request;
    editor.lsp_tools.save = .{ .id = doc.id, .options = .{}, .owned_path = null };
    try client.pending.put(3, request);
    try doc.insertAtCursor("new edit");
    client.dispatchMessage("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":[]}", &editor);
    try t.expect(editor.lsp_tools.save == null and editor.lsp_tools.formatting == null);
    try t.expect(std.mem.startsWith(u8, editor.status_message, "Save aborted"));
    try t.expect(doc.dirty);
    request.version = doc.buffer.version;
    editor.lsp_tools.formatting = request;
    editor.lsp_tools.save = .{ .id = doc.id, .options = .{}, .owned_path = null };
    try client.pending.put(4, request);
    client.expireRequests(&editor, 1);
    try t.expectEqual(@as(usize, 0), client.pending.count());
    try t.expect(editor.lsp_tools.save == null and doc.dirty);

    // Formatting numbers its requests on its own counter: a hover that
    // expires with the same serial leaves the formatting save alone.
    const format_request: Request = .{ .method = .format_document, .generation = client.generation, .doc_id = doc.id, .version = doc.buffer.version, .serial = 7 };
    editor.lsp_tools.formatting = format_request;
    editor.lsp_tools.save = .{ .id = doc.id, .options = .{ .interactive = false }, .owned_path = null };
    var expiring = format_request;
    expiring.method = .hover;
    try client.pending.put(5, expiring);
    client.expireRequests(&editor, 1);
    try t.expect(editor.lsp_tools.formatting != null and editor.lsp_tools.save != null);
    // The formatting reply applies its edits but saves only from `tick`,
    // after polling: a save runs Lua hooks that may stop this very client.
    try client.pending.put(6, format_request);
    client.dispatchMessage("{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":null}", &editor);
    try t.expect(editor.lsp_tools.formatting == null and editor.lsp_tools.save != null);
    try t.expectEqual(@as(?u64, doc.id), editor.lsp_tools.pending_post_format_save);
    try t.expect(doc.dirty);
    editor.lsp_tools.tick(&editor); // untitled: the quiet save needs a path
    try t.expect(editor.lsp_tools.pending_post_format_save == null and editor.lsp_tools.save == null);
    try t.expect(doc.dirty);
}

test "a goto-definition reply jumps from lsp_tools.tick, never inside message dispatch" {
    const t = std.testing;
    const Editor = @import("editor.zig").Editor;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile(t.io, "target.zig", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "const a = 1;\nconst é = 2;\n");
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const target = try std.fs.path.join(t.allocator, &.{ root, "target.zig" });
    defer t.allocator.free(target);
    const uri = try pathToUri(t.allocator, target);
    defer t.allocator.free(uri);

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    var client = LspClient.init(t.allocator, t.io);
    defer client.deinit();
    const doc = editor.activeDoc();
    try doc.insertAtCursor("use(a)");
    try client.pending.put(1, .{ .method = .goto_definition, .generation = client.generation, .doc_id = doc.id, .version = doc.buffer.version, .cursor = doc.cursors.primary().offset });
    // Line 1, UTF-16 column 8: after "const é " (é is one unit, two bytes).
    const reply = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":1,\"character\":8}},\"end\":{{\"line\":1,\"character\":9}}}}}}]}}", .{uri});
    defer t.allocator.free(reply);
    client.dispatchMessage(reply, &editor);
    // Nothing opened inside dispatch: an `open` hook could restart servers
    // and free this very client.
    try t.expectEqual(@as(usize, 1), editor.documents.items.len);
    try t.expect(editor.lsp_tools.pending_definition != null);

    editor.lsp_tools.tick(&editor);
    try t.expect(editor.lsp_tools.pending_definition == null);
    const opened = editor.activeDoc();
    try t.expect(editor.pathsEqual(opened.file_path.?, target));
    try t.expectEqual(@as(usize, "const a = 1;\n".len + "const é ".len), opened.cursors.primary().offset);

    // A reply still queued when the editor goes away is freed with it.
    try client.pending.put(2, .{ .method = .goto_definition, .generation = client.generation, .doc_id = opened.id, .version = opened.buffer.version, .cursor = opened.cursors.primary().offset });
    const again = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":1}}}}}}}}", .{uri});
    defer t.allocator.free(again);
    client.dispatchMessage(again, &editor);
    try t.expect(editor.lsp_tools.pending_definition != null);
}

test "navigate_back returns from a goto-definition jump into another file" {
    const t = std.testing;
    const Editor = @import("editor.zig").Editor;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile(t.io, "target.zig", .{});
        defer f.close(t.io);
        try f.writeStreamingAll(t.io, "const a = 1;\nconst b = 2;\n");
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const target = try std.fs.path.join(t.allocator, &.{ root, "target.zig" });
    defer t.allocator.free(target);
    const uri = try pathToUri(t.allocator, target);
    defer t.allocator.free(uri);

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    var client = LspClient.init(t.allocator, t.io);
    defer client.deinit();
    const doc = editor.activeDoc();
    const origin_id = doc.id;
    try doc.insertAtCursor("first\nuse(a)\n");
    doc.gotoLine(2);
    try client.pending.put(1, .{ .method = .goto_definition, .generation = client.generation, .doc_id = doc.id, .version = doc.buffer.version, .cursor = doc.cursors.primary().offset });
    const reply = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":1,\"character\":6}},\"end\":{{\"line\":1,\"character\":7}}}}}}]}}", .{uri});
    defer t.allocator.free(reply);
    client.dispatchMessage(reply, &editor);
    editor.lsp_tools.tick(&editor);
    const opened = editor.activeDoc();
    try t.expect(editor.pathsEqual(opened.file_path.?, target));
    try t.expectEqual(@as(usize, 1), opened.buffer.offsetToPos(opened.cursors.primary().offset).line);
    const target_id = opened.id;

    // Back lands on the line the jump left; forward re-jumps.
    try t.expect(editor.execAction("navigate_back"));
    try t.expectEqual(origin_id, editor.activeDoc().id);
    try t.expectEqual(@as(usize, 1), editor.activeDoc().buffer.offsetToPos(editor.activeDoc().cursors.primary().offset).line);
    try t.expect(editor.execAction("navigate_forward"));
    try t.expectEqual(target_id, editor.activeDoc().id);
    try t.expectEqual(@as(usize, 1), editor.activeDoc().buffer.offsetToPos(editor.activeDoc().cursors.primary().offset).line);
}

test "LSP message bursts past the per-tick cap skip the next sleep" {
    const t = std.testing;
    const Editor = @import("editor.zig").Editor;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    var client = LspClient.init(t.allocator, t.io);
    defer client.deinit();
    client.peer = try protocol.Peer.detached(t.allocator, t.io);
    const peer = client.peer.?;
    for (0..LspClient.max_messages_per_poll + 36) |_| {
        const message = try t.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{}}");
        peer.incoming.push(t.allocator, message) catch |err| {
            t.allocator.free(message);
            return err;
        };
    }
    client.pollMessages(&editor);
    try t.expectEqual(@as(usize, 36), peer.incoming.messages.items.len);
    try t.expect(editor.deadlines.run_again);
    try t.expectEqual(@as(u32, 0), editor.deadlines.waitMicros(std.Io.Clock.now(.awake, t.io).nanoseconds));
    try t.expect(!editor.deadlines.run_again);
    client.pollMessages(&editor);
    try t.expect(!peer.hasIncoming() and !editor.deadlines.run_again);
}

test "LSP integration: ZLS hover, prepare rename, multi-location edit and formatting" {
    if (!@import("build_options").test_tools) return error.SkipZigTest;
    const t = std.testing;
    const Editor = @import("editor.zig").Editor;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const path = try std.fs.path.join(t.allocator, &.{ base, "main.zig" });
    defer t.allocator.free(path);
    const source = "pub fn main() void {const value:i32=1;_ = value;}\n";
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, path, source);
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.editorconfig_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, base);
    try editor.openIntoActive(path);
    var ready = false;
    for (0..2000) |_| {
        editor.lspTick();
        if (editor.activeDoc().lsp_opened) {
            ready = true;
            break;
        }
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    if (!ready) std.debug.print("ZLS startup: {s}\n", .{editor.status_message});
    try t.expect(ready);
    editor.activeDoc().cursors.primary().offset = std.mem.indexOf(u8, source, "value").?;
    editor.lsp_tools.start(&editor, .hover);
    try waitLspMode(&editor, .lsp_panel);
    try t.expect(editor.lsp_tools.hover.?.len > 0);
    editor.mode = .normal;
    editor.lsp_tools.start(&editor, .prepare_rename);
    try waitLspMode(&editor, .symbol_rename);
    const name = "renamed_value";
    @memcpy(editor.lsp_tools.name[0..name.len], name);
    editor.lsp_tools.name_len = name.len;
    editor.lsp_tools.submitRename(&editor);
    try waitLspMode(&editor, .workspace_preview);
    try t.expect(editor.lsp_tools.preview.?.edit_count >= 2);
    editor.lsp_tools.resolvePreview(&editor, true);
    editor.lsp_tools.start(&editor, .format_document);
    try t.expect(editor.lsp_tools.formatting != null);
    for (0..2000) |_| {
        editor.lspTick();
        if (editor.lsp_tools.formatting == null) break;
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    try t.expect(editor.lsp_tools.formatting == null);
    const doc = editor.activeDoc();
    try t.expect(std.mem.indexOf(u8, doc.buffer.slice(0, doc.buffer.byteLen()), "const renamed_value: i32 = 1;") != null);
    try t.expect(doc.dirty);
    const disk = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1024));
    defer t.allocator.free(disk);
    try t.expectEqualStrings(source, disk);
    editor.lsp_tools.format_on_save = true;
    try t.expectEqual(Editor.SaveOutcome.formatting, editor.saveDocument(doc.id, .{}));
    for (0..2000) |_| {
        editor.lspTick();
        if (editor.lsp_tools.formatting == null) break;
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    try t.expect(editor.lsp_tools.formatting == null and !doc.dirty);
    const saved = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1024));
    defer t.allocator.free(saved);
    try t.expect(std.mem.indexOf(u8, saved, "const renamed_value: i32 = 1;") != null);
}

fn waitLspMode(editor: *@import("editor.zig").Editor, mode: @import("editor.zig").Editor.Mode) !void {
    for (0..2000) |_| {
        editor.lspTick();
        if (editor.mode == mode) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    std.debug.print("LSP expected {s}: {s}\n", .{ @tagName(mode), editor.status_message });
    return error.LspTimedOut;
}
