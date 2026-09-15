//! DAP lifecycle and request state, independent of frontend widgets.
const std = @import("std");
const Editor = @import("editor.zig").Editor;
const protocol = @import("protocol.zig");
const output = @import("tool_output.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
pub const Mode = enum { launch, attach };
pub const Phase = enum { initializing, launching, configuring, running, stopped, disconnecting, terminated, failed };
pub const Command = enum { initialize, launch, attach, setBreakpoints, setExceptionBreakpoints, configurationDone, threads, stackTrace, scopes, variables, @"continue", pause, next, stepIn, stepOut, disconnect };
pub const Request = struct {
    command: Command = .initialize,
    deadline: i128 = 0,
    epoch: u64 = 0,
    source: usize = 0,
    revision: u64 = 0,
    handle: i64 = 0,
    node: u64 = 0,
    configuration: bool = false,
};
pub const Thread = struct { id: i64, name: []u8 };
pub const Frame = struct { id: i64, name: []u8, path: ?[]u8, line: u32, column: u32 };
pub const Node = struct {
    id: u64,
    parent: ?u64,
    name: []u8,
    value: []u8,
    reference: i64,
    depth: u8,
    expanded: bool = false,
    loaded: bool = false,
    loading: bool = false,
};
pub const Session = struct {
    allocator: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    root: []const u8,
    args_json: []const u8,
    mode: Mode,
    generation: u64,
    from_extension: bool,
    peer: ?*protocol.Peer = null,
    phase: Phase = .initializing,
    sequence: i32 = 1,
    epoch: u64 = 1,
    pending: std.AutoHashMapUnmanaged(i32, Request) = .empty,
    initialized_event: bool = false,
    init_response: bool = false,
    launch_response: bool = false,
    configuring: bool = false,
    configured: bool = false,
    config_cursor: usize = 0,
    config_exceptions: bool = false,
    supports_config_done: bool = false,
    supports_terminate_debuggee: bool = false,
    supports_exceptions: bool = false,
    supports_stack_paging: bool = false,
    threads: std.ArrayList(Thread) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    node_bytes: usize = 0,
    next_node: u64 = 1,
    tree_revision: u64 = 1,
    selected_thread: ?i64 = null,
    selected_frame: ?i64 = null,
    pending_pause: bool = false,
    execution_doc: ?u64 = null,
    execution_line: u32 = 0,
    output: output.Output = .{},
    filter: output.Sanitizer = .{},
    reason: [512]u8 = undefined,
    reason_len: usize = 0,
    test_outgoing: std.ArrayList([]u8) = .empty,

    pub fn create(editor: *Editor, name: []const u8, root: []const u8, args: []const u8, mode: Mode, generation: u64, from_extension: bool) !*Session {
        const self = try editor.allocator.create(Session);
        errdefer editor.allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(editor.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        self.* = .{ .allocator = editor.allocator, .io = editor.io, .arena = arena, .name = try a.dupe(u8, name), .root = try a.dupe(u8, root), .args_json = try a.dupe(u8, args), .mode = mode, .generation = generation, .from_extension = from_extension };
        // Copy the arena after its allocations have updated its state.
        self.arena = arena;
        return self;
    }
    pub fn destroy(self: *Session) void {
        if (self.peer) |peer| peer.deinit();
        self.clearHandles();
        self.threads.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.output.deinit(self.allocator);
        for (self.test_outgoing.items) |bytes| self.allocator.free(bytes);
        self.test_outgoing.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    pub fn active(self: *const Session) bool {
        return self.phase != .terminated and self.phase != .failed;
    }
    pub fn note(self: *Session, text: []const u8) void {
        const length = @min(text.len, self.reason.len);
        @memcpy(self.reason[0..length], text[0..length]);
        self.reason_len = length;
    }
    fn log(self: *Session, bytes: []const u8) !void {
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.allocator);
        try self.filter.feed(self.allocator, &clean, bytes, false);
        try self.output.append(self.allocator, clean.items);
    }
    pub fn fail(self: *Session, editor: *Editor, reason: []const u8) void {
        self.note(reason);
        self.phase = .failed;
        self.clearHandles();
        self.pending.clearRetainingCapacity();
        if (self.peer) |peer| {
            if (peer.stderrAlloc(self.allocator)) |stderr| {
                defer self.allocator.free(stderr);
                self.log(stderr) catch {};
            } else |_| {}
            peer.deinit();
        }
        self.peer = null;
        editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Debugger: {s}", .{reason}) catch "Debugger failed";
    }
    fn send(self: *Session, bytes: []const u8) !void {
        if (self.peer) |peer| return peer.send(bytes);
        if (@import("builtin").is_test) {
            const owned = try self.allocator.dupe(u8, bytes);
            errdefer self.allocator.free(owned);
            try self.test_outgoing.append(self.allocator, owned);
            return;
        }
        return error.DebugAdapterDisconnected;
    }
    pub fn request(self: *Session, command: Command, args: anytype, details: Request) !i32 {
        if (self.pending.count() >= 256 or self.sequence == std.math.maxInt(i32)) return error.TooManyDebugRequests;
        const seq = self.sequence;
        const json = try std.json.Stringify.valueAlloc(self.allocator, .{ .seq = seq, .type = "request", .command = @tagName(command), .arguments = args }, .{});
        defer self.allocator.free(json);
        var pending = details;
        pending.command = command;
        pending.epoch = self.epoch;
        pending.deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + @as(i128, if (command == .launch or command == .attach) 30 else 10) * std.time.ns_per_s;
        try self.pending.put(self.allocator, seq, pending);
        errdefer _ = self.pending.remove(seq);
        try self.send(json);
        self.sequence += 1;
        return seq;
    }
    pub fn initialize(self: *Session) !void {
        _ = try self.request(.initialize, .{ .clientID = "zide", .clientName = "ZIDE", .adapterID = "zide", .pathFormat = "path", .linesStartAt1 = true, .columnsStartAt1 = true, .supportsRunInTerminalRequest = false, .supportsStartDebuggingRequest = false, .supportsVariableType = true, .supportsVariablePaging = false, .supportsMemoryReferences = false, .locale = "en-US" }, .{});
    }
    pub fn clearHandles(self: *Session) void {
        self.epoch +%= 1;
        for (self.threads.items) |thread| self.allocator.free(thread.name);
        self.threads.clearRetainingCapacity();
        self.clearFrames();
        self.execution_doc = null;
    }
    fn clearFrames(self: *Session) void {
        for (self.frames.items) |frame| {
            self.allocator.free(frame.name);
            if (frame.path) |path| self.allocator.free(path);
        }
        self.frames.clearRetainingCapacity();
        self.selected_frame = null;
        self.clearNodes();
    }
    fn clearNodes(self: *Session) void {
        self.tree_revision +%= 1;
        for (self.nodes.items) |node| {
            self.allocator.free(node.name);
            self.allocator.free(node.value);
        }
        self.nodes.clearRetainingCapacity();
        self.node_bytes = 0;
    }
    pub fn poll(self: *Session, editor: *Editor, now: i128) void {
        if (self.peer) |peer| {
            var count: usize = 0;
            while (peer.take()) |message| {
                defer self.allocator.free(message);
                self.receive(editor, message) catch |err| {
                    self.fail(editor, @errorName(err));
                    return;
                };
                if (self.peer == null) return;
                count += 1;
                if (count >= 256) break;
            }
            if (peer.stopped()) {
                if (self.phase == .terminated) {
                    peer.deinit();
                    self.peer = null;
                } else self.fail(editor, if (peer.errorState()) |err| @errorName(err) else "Debug adapter exited");
                return;
            }
        }
        var expired: [256]i32 = undefined;
        var length: usize = 0;
        var iterator = self.pending.iterator();
        while (iterator.next()) |item| if (now >= item.value_ptr.deadline) {
            expired[length] = item.key_ptr.*;
            length += 1;
        };
        for (expired[0..length]) |id| {
            const request_info = self.pending.fetchRemove(id) orelse continue;
            if (self.phase == .disconnecting and request_info.value.command != .disconnect) continue;
            if (request_info.value.epoch != self.epoch and transient(request_info.value.command)) continue;
            self.requestFailed(editor, request_info.value, "Debug request timed out");
        }
    }
    pub fn receive(self: *Session, editor: *Editor, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        const value = parsed.value;
        const kind = string(value, "type") orelse return error.InvalidDebugMessage;
        if (std.mem.eql(u8, kind, "event")) {
            try self.event(editor, string(value, "event") orelse return error.InvalidDebugMessage, field(value, "body"));
        } else if (std.mem.eql(u8, kind, "response")) {
            const id = std.math.cast(i32, integer(value, "request_seq") orelse return error.InvalidDebugMessage) orelse return error.InvalidDebugMessage;
            const removed = self.pending.fetchRemove(id) orelse return; // Late replies never obtain new handles.
            const info = removed.value;
            if (self.phase == .disconnecting and info.command != .disconnect) return;
            if (info.epoch != self.epoch and transient(info.command)) return;
            if (!std.mem.eql(u8, string(value, "command") orelse return error.InvalidDebugMessage, @tagName(info.command))) return error.MismatchedDebugResponse;
            if (!boolean(value, "success")) {
                self.requestFailed(editor, info, string(value, "message") orelse "Adapter rejected request");
                return;
            }
            try self.response(editor, info, field(value, "body"));
        } else if (std.mem.eql(u8, kind, "request")) {
            const command = string(value, "command") orelse return error.InvalidDebugMessage;
            const request_seq = integer(value, "seq") orelse return error.InvalidDebugMessage;
            const json = try std.json.Stringify.valueAlloc(self.allocator, .{ .seq = self.sequence, .type = "response", .request_seq = request_seq, .command = command, .success = false, .message = "ZIDE does not support this adapter request (including terminal launch)" }, .{});
            defer self.allocator.free(json);
            self.sequence += 1;
            try self.send(json);
        } else return error.InvalidDebugMessage;
    }
    fn requestFailed(self: *Session, editor: *Editor, info: Request, reason: []const u8) void {
        self.note(reason);
        editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Debug {s}: {s}", .{ @tagName(info.command), reason }) catch "Debug request failed";
        if (info.command == .initialize or info.command == .launch or info.command == .attach or info.command == .configurationDone or info.command == .disconnect) {
            self.fail(editor, reason);
        } else if (info.command == .variables) {
            for (self.nodes.items) |*node| if (node.id == info.node) {
                node.loading = false;
            };
        } else if (info.command == .setBreakpoints) {
            const source = &editor.dap.breakpoints.sources.items[info.source];
            if (source.revision == info.revision) for (source.points.items) |*point| {
                point.clear(self.allocator);
                point.message = self.allocator.dupe(u8, reason) catch null;
            };
            if (info.configuration) self.configureNext(editor) catch |err| self.fail(editor, @errorName(err));
        } else if (info.command == .setExceptionBreakpoints and info.configuration) {
            self.configureNext(editor) catch |err| self.fail(editor, @errorName(err));
        } else if (info.command == .@"continue" or info.command == .next or info.command == .stepIn or info.command == .stepOut) {
            self.phase = .stopped;
            _ = self.request(.threads, .{}, .{}) catch {};
        }
    }
    fn response(self: *Session, editor: *Editor, info: Request, body: Value) !void {
        switch (info.command) {
            .initialize => {
                self.init_response = true;
                self.supports_config_done = boolean(body, "supportsConfigurationDoneRequest");
                self.supports_terminate_debuggee = boolean(body, "supportTerminateDebuggee");
                self.supports_exceptions = field(body, "exceptionBreakpointFilters") != .null;
                self.supports_stack_paging = boolean(body, "supportsDelayedStackTraceLoading");
                const args = try std.json.parseFromSlice(Value, self.allocator, self.args_json, .{});
                defer args.deinit();
                _ = try self.request(if (self.mode == .launch) .launch else .attach, args.value, .{});
                self.phase = .launching;
                try self.maybeConfigure(editor);
            },
            .launch, .attach => {
                self.launch_response = true;
                self.maybeRunning();
            },
            .setBreakpoints => {
                const source = &editor.dap.breakpoints.sources.items[info.source];
                if (source.revision == info.revision) {
                    const points = array(body, "breakpoints");
                    if (points.len != source.points.items.len) return error.InvalidBreakpointResponse;
                    for (source.points.items, points) |*point, value| try updatePoint(self.allocator, point, value);
                }
                if (info.configuration) try self.configureNext(editor);
            },
            .setExceptionBreakpoints => if (info.configuration) try self.configureNext(editor),
            .configurationDone => {
                self.configured = true;
                self.configuring = false;
                self.maybeRunning();
            },
            .threads => {
                for (self.threads.items) |thread| self.allocator.free(thread.name);
                self.threads.clearRetainingCapacity();
                const items = array(body, "threads");
                if (items.len > 4096) return error.TooManyDebugThreads;
                for (items) |thread| {
                    const id = integer(thread, "id") orelse return error.InvalidDebugThread;
                    const name = try self.allocator.dupe(u8, string(thread, "name") orelse "thread");
                    errdefer self.allocator.free(name);
                    try self.threads.append(self.allocator, .{ .id = id, .name = name });
                }
                var found = false;
                for (self.threads.items) |thread| if (self.selected_thread == thread.id) {
                    found = true;
                    break;
                };
                if (!found) self.selected_thread = if (items.len > 0) self.threads.items[0].id else null;
                if (self.phase == .stopped and self.selected_thread != null) {
                    try self.selectThread(self.selected_thread.?);
                } else if (self.pending_pause and self.selected_thread != null) {
                    self.pending_pause = false;
                    try self.control(.pause);
                }
            },
            .stackTrace => {
                if (self.phase != .stopped or self.selected_thread != info.handle) return;
                self.clearFrames();
                const items = array(body, "stackFrames");
                if (items.len > 4096) return error.TooManyDebugFrames;
                for (items) |frame| {
                    const name = try self.allocator.dupe(u8, string(frame, "name") orelse "frame");
                    errdefer self.allocator.free(name);
                    const source = field(frame, "source");
                    const path = if (string(source, "path")) |p| try std.fs.path.resolve(self.allocator, &.{ self.root, p }) else null;
                    errdefer if (path) |p| self.allocator.free(p);
                    try self.frames.append(self.allocator, .{ .id = integer(frame, "id") orelse return error.InvalidStackFrame, .name = name, .path = path, .line = std.math.cast(u32, integer(frame, "line") orelse 0) orelse 0, .column = std.math.cast(u32, integer(frame, "column") orelse 0) orelse 0 });
                }
                if (self.frames.items.len > 0) try self.selectFrame(editor, 0, editor.mode == .normal);
            },
            .scopes => {
                if (self.phase != .stopped or self.selected_frame != info.handle) return;
                self.clearNodes();
                const scopes = array(body, "scopes");
                if (scopes.len > 256) return error.TooManyScopes;
                for (scopes) |scope| try self.appendNode(null, 0, scope, true);
            },
            .variables => {
                if (self.phase != .stopped) return;
                var parent: ?Node = null;
                for (self.nodes.items) |*node| if (node.id == info.node) {
                    node.loading = false;
                    node.loaded = true;
                    parent = node.*;
                    break;
                };
                const node = parent orelse return;
                if (node.depth >= 32) return error.VariableDepthLimit;
                for (array(body, "variables")) |variable| try self.appendNode(node.id, node.depth + 1, variable, false);
            },
            .disconnect => {
                self.phase = .terminated;
                self.pending.clearRetainingCapacity();
                self.clearHandles();
                self.note(if (self.mode == .attach) "Disconnected from target" else "Debug session stopped");
                if (self.peer) |peer| peer.deinit();
                self.peer = null;
            },
            .@"continue", .next, .stepIn, .stepOut, .pause => {},
        }
    }
    fn appendNode(self: *Session, parent: ?u64, depth: u8, value: Value, scope: bool) !void {
        if (self.nodes.items.len >= 4096 or self.node_bytes >= 4 * 1024 * 1024) {
            self.note("Variable display truncated at its size limit");
            return;
        }
        const name = try labelAlloc(self.allocator, string(value, "name") orelse "?");
        errdefer self.allocator.free(name);
        const text = try labelAlloc(self.allocator, if (scope) "scope" else string(value, "value") orelse "");
        errdefer self.allocator.free(text);
        try self.nodes.append(self.allocator, .{ .id = self.next_node, .parent = parent, .depth = depth, .name = name, .value = text, .reference = integer(value, "variablesReference") orelse 0 });
        self.next_node += 1;
        self.node_bytes += name.len + text.len;
        self.tree_revision +%= 1;
    }
    pub fn expand(self: *Session, index: usize) !void {
        if (self.phase != .stopped or index >= self.nodes.items.len) return;
        const node = &self.nodes.items[index];
        if (node.reference <= 0) return;
        node.expanded = !node.expanded;
        self.tree_revision +%= 1;
        if (node.expanded and !node.loaded and !node.loading) {
            _ = try self.request(.variables, .{ .variablesReference = node.reference }, .{ .node = node.id });
            node.loading = true;
        }
    }
    pub fn nodeVisible(self: *Session, index: usize) bool {
        var parent = self.nodes.items[index].parent;
        var depth: usize = 0;
        while (parent) |id| {
            if (depth >= 32) return false;
            const node = for (self.nodes.items) |item| {
                if (item.id == id) break item;
            } else return false;
            if (!node.expanded) return false;
            parent = node.parent;
            depth += 1;
        }
        return true;
    }
    fn event(self: *Session, editor: *Editor, name: []const u8, body: Value) !void {
        if (std.mem.eql(u8, name, "output")) {
            try self.log(string(body, "output") orelse "");
            return;
        }
        if (self.phase == .terminated or self.phase == .failed) return;
        if (std.mem.eql(u8, name, "initialized")) {
            self.initialized_event = true;
            try self.maybeConfigure(editor);
        } else if (std.mem.eql(u8, name, "stopped")) {
            if (self.phase == .disconnecting) return;
            self.clearHandles();
            self.phase = .stopped;
            self.selected_thread = integer(body, "threadId");
            self.note(string(body, "description") orelse string(body, "reason") orelse "Stopped");
            _ = try self.request(.threads, .{}, .{});
        } else if (std.mem.eql(u8, name, "continued")) {
            if (self.phase == .disconnecting) return;
            self.clearHandles();
            self.phase = .running;
        } else if (std.mem.eql(u8, name, "terminated")) {
            self.clearHandles();
            if (self.phase != .disconnecting) try self.stop(false);
        } else if (std.mem.eql(u8, name, "exited")) {
            const code = integer(body, "exitCode") orelse 0;
            var buf: [64]u8 = undefined;
            try self.log(try std.fmt.bufPrint(&buf, "\nProcess exited with code {d}\n", .{code}));
        } else if (std.mem.eql(u8, name, "breakpoint")) {
            const value = field(body, "breakpoint");
            const id = integer(value, "id") orelse return;
            for (editor.dap.breakpoints.sources.items) |*source| for (source.points.items) |*point| if (point.adapter_id == id) {
                try updatePoint(self.allocator, point, value);
            };
        } else if (std.mem.eql(u8, name, "thread") and self.phase == .stopped) {
            _ = try self.request(.threads, .{}, .{});
        }
    }
    fn maybeConfigure(self: *Session, editor: *Editor) !void {
        if (!self.initialized_event or !self.init_response or self.configuring or self.configured or self.phase == .disconnecting) return;
        self.configuring = true;
        if (self.phase != .stopped) self.phase = .configuring;
        try self.configureNext(editor);
    }
    fn configureNext(self: *Session, editor: *Editor) !void {
        if (self.phase == .disconnecting or !self.active()) return;
        while (self.config_cursor < editor.dap.breakpoints.sources.items.len) {
            const index = self.config_cursor;
            self.config_cursor += 1;
            if (editor.dap.breakpoints.sources.items[index].points.items.len == 0) continue;
            try self.setBreakpoints(editor, index, true);
            return;
        }
        if (self.supports_exceptions and !self.config_exceptions) {
            self.config_exceptions = true;
            _ = try self.request(.setExceptionBreakpoints, .{ .filters = @as([]const []const u8, &.{}) }, .{ .configuration = true });
        } else if (self.supports_config_done) {
            _ = try self.request(.configurationDone, .{}, .{});
        } else {
            self.configured = true;
            self.configuring = false;
            self.maybeRunning();
        }
    }
    fn maybeRunning(self: *Session) void {
        if (self.configured and self.launch_response and self.phase != .stopped and self.phase != .disconnecting and self.active()) self.phase = .running;
    }
    pub fn setBreakpoints(self: *Session, editor: *Editor, index: usize, configuration: bool) !void {
        if (!self.initialized_event or !self.active() or self.phase == .disconnecting) return;
        const source = &editor.dap.breakpoints.sources.items[index];
        var points: std.ArrayList(struct { line: u32 }) = .empty;
        defer points.deinit(self.allocator);
        for (source.points.items) |*point| {
            point.clear(self.allocator);
            try points.append(self.allocator, .{ .line = point.line });
        }
        const doc_index = try editor.findDocument(source.path);
        _ = try self.request(.setBreakpoints, .{ .source = .{ .path = source.path }, .breakpoints = points.items, .sourceModified = if (doc_index) |idx| editor.documents.items[idx].dirty else false }, .{ .source = index, .revision = source.revision, .configuration = configuration });
    }
    pub fn selectThread(self: *Session, thread: i64) !void {
        if (self.phase != .stopped) return;
        self.selected_thread = thread;
        self.clearFrames();
        _ = if (self.supports_stack_paging) try self.request(.stackTrace, .{ .threadId = thread, .startFrame = 0, .levels = 256 }, .{ .handle = thread }) else try self.request(.stackTrace, .{ .threadId = thread }, .{ .handle = thread });
    }
    pub fn selectFrame(self: *Session, editor: *Editor, index: usize, open: bool) !void {
        if (self.phase != .stopped or index >= self.frames.items.len) return;
        const frame = self.frames.items[index];
        self.selected_frame = frame.id;
        self.clearNodes();
        _ = try self.request(.scopes, .{ .frameId = frame.id }, .{ .handle = frame.id });
        self.execution_doc = null;
        if (frame.path) |path| {
            if (try editor.findDocument(path)) |doc_index| self.execution_doc = editor.documents.items[doc_index].id;
            self.execution_line = frame.line;
            if (open and frame.line > 0) {
                const owned = try self.allocator.dupe(u8, path);
                defer self.allocator.free(owned);
                // No borrowed frame fields are used after extension callbacks can run.
                const doc = try editor.openOrFocus(owned);
                doc.gotoLine(frame.line);
                doc.cursors.primary().gotoPos(&doc.buffer, frame.line - 1, frame.column -| 1);
                self.execution_doc = doc.id;
            }
        }
    }
    pub fn control(self: *Session, command: Command) !void {
        if (command == .pause) {
            if (self.phase != .running) return error.DebuggeeNotRunning;
            if (self.selected_thread == null) {
                self.pending_pause = true;
                _ = try self.request(.threads, .{}, .{});
                return;
            }
        } else if (self.phase != .stopped) return error.DebuggeeNotStopped;
        const thread = self.selected_thread orelse return error.NoDebugThread;
        _ = try self.request(command, .{ .threadId = thread }, .{});
        if (command != .pause) {
            self.clearHandles();
            self.phase = .running;
        }
    }
    pub fn stop(self: *Session, terminate: bool) !void {
        if (!self.active() or self.phase == .disconnecting) return;
        if (terminate and self.mode == .attach and !self.supports_terminate_debuggee) return error.AdapterCannotTerminateAttachedTarget;
        if (self.supports_terminate_debuggee) {
            _ = try self.request(.disconnect, .{ .restart = false, .terminateDebuggee = terminate or self.mode == .launch }, .{});
        } else {
            _ = try self.request(.disconnect, .{ .restart = false }, .{});
        }
        self.clearHandles();
        self.phase = .disconnecting;
    }
};

fn transient(command: Command) bool {
    return command == .threads or command == .stackTrace or command == .scopes or command == .variables;
}
fn labelAlloc(a: Allocator, text: []const u8) ![]u8 {
    var len = @min(text.len, 16 * 1024);
    while (len < text.len and len > 0 and text[len] & 0xc0 == 0x80) len -= 1;
    const copy = if (len < text.len) try std.fmt.allocPrint(a, "{s}…", .{text[0..len]}) else try a.dupe(u8, text[0..len]);
    for (copy) |*byte| if (byte.* < 32 or byte.* == 127) {
        byte.* = ' ';
    };
    return copy;
}
pub fn field(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
pub fn string(value: Value, key: []const u8) ?[]const u8 {
    const item = field(value, key);
    return if (item == .string) item.string else null;
}
pub fn integer(value: Value, key: []const u8) ?i64 {
    const item = field(value, key);
    return if (item == .integer) item.integer else null;
}
pub fn boolean(value: Value, key: []const u8) bool {
    const item = field(value, key);
    return item == .bool and item.bool;
}
pub fn array(value: Value, key: []const u8) []const Value {
    const item = field(value, key);
    return if (item == .array) item.array.items else &.{};
}
fn updatePoint(a: Allocator, point: *@import("breakpoints.zig").Point, value: Value) !void {
    const message = if (string(value, "message")) |text| try a.dupe(u8, text) else null;
    point.clear(a);
    point.message = message;
    point.verified = boolean(value, "verified");
    point.adapter_id = integer(value, "id");
    point.actual_line = if (integer(value, "line")) |line| std.math.cast(u32, line) else null;
}

fn testReply(self: *Session, editor: *Editor, command: Command, body: []const u8) !void {
    var iterator = self.pending.iterator();
    const id = while (iterator.next()) |entry| {
        if (entry.value_ptr.command == command) break entry.key_ptr.*;
    } else return error.MissingTestRequest;
    const bytes = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"response\",\"request_seq\":{d},\"command\":\"{s}\",\"success\":true,\"body\":{s}}}", .{ id, @tagName(command), body });
    defer self.allocator.free(bytes);
    try self.receive(editor, bytes);
}

test "DAP ordering, breakpoint verification, resume invalidation and unsupported reverse requests" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.mode = .confirm_quit;
    _ = try editor.dap.breakpoints.toggle(t.allocator, t.io, "fake-debug-source.zig", 3);
    const session = try Session.create(&editor, "fake", ".", "{}", .launch, 1, false);
    editor.dap.session = session;
    try session.initialize();
    try session.receive(&editor, "{\"type\":\"event\",\"event\":\"initialized\"}");
    try t.expectEqual(@as(usize, 1), session.pending.count());
    try testReply(session, &editor, .initialize, "{\"supportsConfigurationDoneRequest\":true,\"supportTerminateDebuggee\":true}");
    try testReply(session, &editor, .setBreakpoints, "{\"breakpoints\":[{\"id\":42,\"verified\":false,\"line\":3,\"message\":\"not executable\"}]}");
    try t.expect(!editor.dap.breakpoints.sources.items[0].points.items[0].verified);
    try testReply(session, &editor, .configurationDone, "{}");
    try session.receive(&editor, "{\"type\":\"event\",\"event\":\"stopped\",\"body\":{\"reason\":\"breakpoint\",\"threadId\":9}}");
    try testReply(session, &editor, .launch, "{}");
    try t.expectEqual(Phase.stopped, session.phase);
    try testReply(session, &editor, .threads, "{\"threads\":[{\"id\":9,\"name\":\"main\"}]}");
    try testReply(session, &editor, .stackTrace, "{\"stackFrames\":[{\"id\":10,\"name\":\"main\",\"line\":3,\"column\":1}]}");
    try testReply(session, &editor, .scopes, "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":100}]}");
    try session.expand(0);
    try session.control(.next);
    try t.expectEqual(@as(usize, 0), session.nodes.items.len);
    try testReply(session, &editor, .variables, "{\"variables\":[{\"name\":\"stale\",\"value\":\"42\",\"variablesReference\":0}]}");
    try t.expectEqual(@as(usize, 0), session.nodes.items.len);
    try session.receive(&editor, "{\"type\":\"request\",\"seq\":500,\"command\":\"runInTerminal\",\"arguments\":{}}");
    const response = try std.json.parseFromSlice(Value, t.allocator, session.test_outgoing.items[session.test_outgoing.items.len - 1], .{});
    defer response.deinit();
    try t.expect(!boolean(response.value, "success"));
    try t.expectEqual(Editor.Mode.confirm_quit, editor.mode);
    try session.stop(false);
    const stop = try std.json.parseFromSlice(Value, t.allocator, session.test_outgoing.items[session.test_outgoing.items.len - 1], .{});
    defer stop.deinit();
    try t.expect(boolean(field(stop.value, "arguments"), "terminateDebuggee"));
    try testReply(session, &editor, .disconnect, "{}");
    try t.expectEqual(Phase.terminated, session.phase);
}

test "DAP attach detaches by default, late initialize cannot launch, and timeouts are explicit" {
    const t = std.testing;
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    const session = try Session.create(&editor, "attach", ".", "{}", .attach, 1, false);
    editor.dap.session = session;
    session.supports_terminate_debuggee = true;
    try session.initialize();
    try session.stop(false);
    const stop = try std.json.parseFromSlice(Value, t.allocator, session.test_outgoing.items[session.test_outgoing.items.len - 1], .{});
    defer stop.deinit();
    try t.expect(!boolean(field(stop.value, "arguments"), "terminateDebuggee"));
    try testReply(session, &editor, .initialize, "{}");
    try t.expectEqual(Phase.disconnecting, session.phase);
    try t.expectEqual(@as(usize, 2), session.test_outgoing.items.len);
    session.poll(&editor, std.math.maxInt(i128));
    try t.expectEqual(Phase.failed, session.phase);
    try t.expect(std.mem.indexOf(u8, session.reason[0..session.reason_len], "timed out") != null);
}
