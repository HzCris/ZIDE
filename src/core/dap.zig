//! Debug registrations, workspace state and shared GUI/TUI commands.
const std = @import("std");
const Editor = @import("editor.zig").Editor;
const Allocator = std.mem.Allocator;
pub const session_mod = @import("dap_session.zig");
pub const Session = session_mod.Session;
pub const Mode = session_mod.Mode;
pub const Adapter = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    argv: []const []const u8,
    from_extension: bool = false,
    pub fn create(a: Allocator, name: []const u8, argv: []const []const u8, extension: bool) !*Adapter {
        if (name.len == 0 or argv.len == 0 or argv[0].len == 0) return error.InvalidDebugAdapter;
        const self = try a.create(Adapter);
        errdefer a.destroy(self);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(a), .name = undefined, .argv = undefined, .from_extension = extension };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.name = try arena.dupe(u8, name);
        const args = try arena.alloc([]const u8, argv.len);
        for (argv, args) |arg, *owned| owned.* = try arena.dupe(u8, arg);
        self.argv = args;
        return self;
    }
    pub fn destroy(self: *Adapter, a: Allocator) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const Config = struct {
    name: []u8,
    adapter: []u8,
    arguments: []u8,
    request: Mode,
    from_extension: bool,
    pub fn create(a: Allocator, name: []const u8, adapter: []const u8, request: Mode, arguments: []const u8, extension: bool) !Config {
        if (name.len == 0 or adapter.len == 0) return error.InvalidDebugConfiguration;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, arguments, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidDebugArguments;
        if (session_mod.boolean(parsed.value, "runInTerminal")) return error.InteractiveDebuggingUnsupported;
        if (session_mod.string(parsed.value, "console")) |console| if (std.mem.eql(u8, console, "integratedTerminal") or std.mem.eql(u8, console, "externalTerminal")) return error.InteractiveDebuggingUnsupported;
        const owned_name = try a.dupe(u8, name);
        errdefer a.free(owned_name);
        const owned_adapter = try a.dupe(u8, adapter);
        errdefer a.free(owned_adapter);
        return .{ .name = owned_name, .adapter = owned_adapter, .arguments = try a.dupe(u8, arguments), .request = request, .from_extension = extension };
    }
    pub fn deinit(self: Config, a: Allocator) void {
        a.free(self.name);
        a.free(self.adapter);
        a.free(self.arguments);
    }
};
pub const View = enum { overview, configurations, threads, stack, variables, breakpoints, output };
const overview = [_][]const u8{ "Choose launch / attach configuration", "Threads", "Stack frames", "Scopes and variables", "Source breakpoints", "Debug output", "Continue", "Pause", "Step over", "Step in", "Step out", "Stop (launch: terminate; attach: detach)" };
test {
    _ = @import("dap_integration.zig");
}
pub const State = struct {
    adapters: std.ArrayList(*Adapter) = .empty,
    configs: std.ArrayList(Config) = .empty,
    breakpoints: @import("breakpoints.zig").Store = .{},
    session: ?*Session = null,
    next_generation: u64 = 1,
    pumping: bool = false,
    view: View = .overview,
    variable_indices: std.ArrayList(usize) = .empty,
    variable_revision: u64 = 0,
    variable_generation: u64 = 0,
    bindings: std.ArrayList(struct { doc: u64, source: usize }) = .empty,
    binding_hash: ?u64 = null,
    storage_base: ?[]u8 = null,
    next_workspace_check: i128 = 0,

    pub fn deinit(self: *State, editor: *Editor) void {
        self.shutdown(editor);
        if (self.session) |session| session.destroy();
        for (self.adapters.items) |adapter| adapter.destroy(editor.allocator);
        self.adapters.deinit(editor.allocator);
        for (self.configs.items) |config| config.deinit(editor.allocator);
        self.configs.deinit(editor.allocator);
        self.breakpoints.deinit(editor.allocator);
        self.variable_indices.deinit(editor.allocator);
        self.bindings.deinit(editor.allocator);
        if (self.storage_base) |base| editor.allocator.free(base);
    }
    fn shutdown(self: *State, editor: *Editor) void {
        const session = self.session orelse return;
        if (session.peer == null) return;
        if (session.peer) |peer| peer.setWake(null);
        session.stop(false) catch |err| {
            session.note(@errorName(err));
            return;
        };
        // Give the adapter a bounded chance to detach before releasing its process group.
        for (0..200) |_| {
            if (!session.active()) break;
            session.poll(editor, std.Io.Clock.now(.awake, editor.io).nanoseconds);
            std.Io.sleep(editor.io, .fromMilliseconds(10), .awake) catch break;
        }
        if (session.active()) std.log.warn("Debugger disconnect did not finish before shutdown: {s}", .{session.name});
    }
    pub fn setWake(self: *State, wake: ?*const fn () void) void {
        if (self.session) |session| if (session.peer) |peer| peer.setWake(wake);
    }
    pub fn configureStorage(self: *State, editor: *Editor, base: []const u8, workspace: []const u8) void {
        if (self.storage_base == null) self.storage_base = editor.allocator.dupe(u8, base) catch null;
        self.breakpoints.configure(editor.allocator, editor.io, base, workspace) catch |err| report(editor, @errorName(err));
        self.binding_hash = null;
    }
    pub fn registerAdapter(self: *State, editor: *Editor, adapter: *Adapter) !void {
        for (self.adapters.items) |*old| if (std.mem.eql(u8, old.*.name, adapter.name)) {
            old.*.destroy(editor.allocator);
            old.* = adapter;
            return;
        };
        if (self.adapters.items.len >= 64) return error.TooManyDebugAdapters;
        try self.adapters.append(editor.allocator, adapter);
    }
    pub fn registerConfig(self: *State, editor: *Editor, config: Config) !void {
        for (self.configs.items) |*old| if (std.mem.eql(u8, old.name, config.name)) {
            old.deinit(editor.allocator);
            old.* = config;
            return;
        };
        if (self.configs.items.len >= 256) return error.TooManyDebugConfigurations;
        try self.configs.append(editor.allocator, config);
    }
    pub fn dropExtensions(self: *State, editor: *Editor) void {
        if (self.session) |session| if (session.from_extension) session.stop(false) catch |err| report(editor, @errorName(err));
        var index: usize = 0;
        while (index < self.configs.items.len) {
            if (self.configs.items[index].from_extension) self.configs.orderedRemove(index).deinit(editor.allocator) else index += 1;
        }
        index = 0;
        while (index < self.adapters.items.len) {
            if (self.adapters.items[index].from_extension) self.adapters.orderedRemove(index).destroy(editor.allocator) else index += 1;
        }
    }
    pub fn start(self: *State, editor: *Editor, name: []const u8) !void {
        if (self.pumping) return error.DebuggerBusy;
        if (self.session) |session| if (session.active()) return error.DebugSessionAlreadyActive;
        const config = for (self.configs.items) |item| {
            if (std.mem.eql(u8, item.name, name)) break item;
        } else return error.DebugConfigurationNotFound;
        const adapter = for (self.adapters.items) |item| {
            if (std.mem.eql(u8, item.name, config.adapter)) break item;
        } else return error.DebugAdapterNotFound;
        const root = try editor.lspRootPathAlloc();
        defer editor.allocator.free(root);
        var arena = std.heap.ArenaAllocator.init(editor.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var args = try std.json.parseFromSlice(std.json.Value, a, config.arguments, .{ .allocate = .alloc_always });
        defer args.deinit();
        try expandWorkspace(a, &args.value, root);
        if (!args.value.object.contains("cwd")) try args.value.object.put(a, "cwd", .{ .string = root });
        const json = try std.json.Stringify.valueAlloc(a, args.value, .{});
        const session = try Session.create(editor, config.name, root, json, config.request, self.next_generation, config.from_extension or adapter.from_extension);
        errdefer session.destroy();
        session.peer = try @import("protocol.zig").Peer.start(editor.allocator, editor.io, adapter.argv, root, editor.lua_wake_fn);
        try session.initialize();
        if (self.session) |old| old.destroy();
        self.session = session;
        self.next_generation += 1;
        self.breakpoints.resetVerification(editor.allocator);
        self.view = .overview;
        editor.status_message = "Debugger starting";
    }
    pub fn tick(self: *State, editor: *Editor, now: i128) void {
        if (self.pumping) return;
        self.pumping = true;
        defer self.pumping = false;
        if (self.session) |session| session.poll(editor, now);
        if (now >= self.next_workspace_check) {
            self.next_workspace_check = now + 1500 * std.time.ns_per_ms;
            if (self.storage_base) |base| if (self.session == null or !self.session.?.active()) {
                const workspace: []const u8 = if (editor.filetree) |ft| ft.root_path else editor.filetree_root orelse ".";
                const key = @import("file_identity.zig").key(editor.allocator, editor.io, workspace) catch null;
                if (key) |path| {
                    defer editor.allocator.free(path);
                    if (self.breakpoints.workspace == null or !@import("file_identity.zig").equalKeys(path, self.breakpoints.workspace.?)) self.configureStorage(editor, base, workspace);
                }
            };
        }
        self.bind(editor) catch {};
    }
    pub fn toggleBreakpoint(self: *State, editor: *Editor) void {
        const doc = editor.activeDoc();
        const path = doc.file_path orelse {
            report(editor, "Save the file before setting a source breakpoint");
            return;
        };
        const line: u32 = @intCast(doc.buffer.offsetToPos(doc.cursors.primary().offset).line + 1);
        const index = self.breakpoints.toggle(editor.allocator, editor.io, path, line) catch |err| {
            report(editor, @errorName(err));
            return;
        };
        if (self.session) |session| session.setBreakpoints(editor, index, false) catch |err| report(editor, @errorName(err));
        self.breakpoints.save(editor.allocator, editor.io) catch |err| report(editor, @errorName(err));
        self.binding_hash = null;
        self.bind(editor) catch {};
    }
    fn bind(self: *State, editor: *Editor) !void {
        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&self.breakpoints.sources.items.len));
        for (editor.documents.items) |doc| {
            hash.update(std.mem.asBytes(&doc.id));
            hash.update(doc.file_path orelse "");
        }
        const fingerprint = hash.final();
        if (self.binding_hash == fingerprint) return;
        self.bindings.clearRetainingCapacity();
        for (self.breakpoints.sources.items, 0..) |source, index| if (try editor.findDocument(source.path)) |doc| try self.bindings.append(editor.allocator, .{ .doc = editor.documents.items[doc].id, .source = index });
        self.binding_hash = fingerprint;
    }
    pub fn marker(self: *State, doc_id: u64, line: usize) enum { none, breakpoint, unverified, execution } {
        if (self.session) |session| if (session.phase == .stopped and session.execution_doc == doc_id and session.execution_line == line + 1) return .execution;
        for (self.bindings.items) |binding| if (binding.doc == doc_id) {
            for (self.breakpoints.sources.items[binding.source].points.items) |point| if ((point.actual_line orelse point.line) == line + 1) return if (point.verified) .breakpoint else .unverified;
        };
        return .none;
    }
    pub fn control(self: *State, editor: *Editor, command: session_mod.Command) void {
        const session = self.session orelse {
            report(editor, "No debug session");
            return;
        };
        session.control(command) catch |err| report(editor, @errorName(err));
    }
    pub fn stop(self: *State, editor: *Editor, terminate: bool) void {
        if (self.session) |session| session.stop(terminate) catch |err| report(editor, @errorName(err));
    }
    pub fn show(self: *State, editor: *Editor, view: View) void {
        self.view = view;
        editor.tool_panel.show(editor, .debug);
    }
    pub fn title(self: *State, buf: []u8) []const u8 {
        const session = self.session orelse return "Debug: choose a configuration or set a source breakpoint";
        return std.fmt.bufPrint(buf, "Debug {s} / {s}: {s} • {s}{s}", .{ session.name, @tagName(self.view), @tagName(session.phase), session.reason[0..session.reason_len], if (session.output.truncated) " (output truncated)" else "" }) catch "Debug";
    }
    fn variables(self: *State, editor: *Editor) void {
        const session = self.session orelse return;
        if (self.variable_generation == session.generation and self.variable_revision == session.tree_revision) return;
        self.variable_indices.clearRetainingCapacity();
        self.walkNodes(editor, null);
        self.variable_generation = session.generation;
        self.variable_revision = session.tree_revision;
    }
    fn walkNodes(self: *State, editor: *Editor, parent: ?u64) void {
        const session = self.session.?;
        for (session.nodes.items, 0..) |node, index| if (node.parent == parent) {
            self.variable_indices.append(editor.allocator, index) catch return;
            if (node.expanded and node.depth < 32) self.walkNodes(editor, node.id);
        };
    }
    pub fn count(self: *State, editor: *Editor) usize {
        return switch (self.view) {
            .overview => overview.len,
            .configurations => self.configs.items.len,
            .breakpoints => blk: {
                var count_points: usize = 0;
                for (self.breakpoints.sources.items) |source| count_points += source.points.items.len;
                break :blk count_points;
            },
            .threads => if (self.session) |session| session.threads.items.len else 0,
            .stack => if (self.session) |session| session.frames.items.len else 0,
            .variables => blk: {
                if (self.session == null) break :blk 0;
                self.variables(editor);
                break :blk self.variable_indices.items.len;
            },
            .output => if (self.session) |session| session.output.count() else 0,
        };
    }
    pub fn row(self: *State, editor: *Editor, index: usize, buf: []u8) []const u8 {
        if (index >= self.count(editor)) return "";
        switch (self.view) {
            .overview => return overview[index],
            .configurations => return self.configs.items[index].name,
            .output => return self.session.?.output.line(index),
            .threads => {
                const thread = self.session.?.threads.items[index];
                return std.fmt.bufPrint(buf, "Thread {d}: {s}", .{ thread.id, thread.name }) catch thread.name;
            },
            .stack => {
                const frame = self.session.?.frames.items[index];
                return std.fmt.bufPrint(buf, "{s} — {s}:{d}", .{ frame.name, frame.path orelse "Source unavailable", frame.line }) catch frame.name;
            },
            .variables => {
                const node = self.session.?.nodes.items[self.variable_indices.items[index]];
                const spaces = "                                                                ";
                return std.fmt.bufPrint(buf, "{s}{s} {s} = {s}{s}", .{ spaces[0..@min(spaces.len, @as(usize, node.depth) * 2)], if (node.reference <= 0) " " else if (node.expanded) "-" else "+", node.name, node.value, if (node.loading) " (loading)" else "" }) catch node.name;
            },
            .breakpoints => {
                var offset = index;
                for (self.breakpoints.sources.items) |source| {
                    if (offset >= source.points.items.len) {
                        offset -= source.points.items.len;
                        continue;
                    }
                    const point = source.points.items[offset];
                    return std.fmt.bufPrint(buf, "{s}:{d} {s} {s}", .{ source.path, point.actual_line orelse point.line, if (point.verified) "verified" else "unverified", point.message orelse "" }) catch source.path;
                }
                return "";
            },
        }
    }
    pub fn activate(self: *State, editor: *Editor, index: usize) void {
        self.activateInner(editor, index) catch |err| report(editor, @errorName(err));
    }
    fn activateInner(self: *State, editor: *Editor, index: usize) !void {
        if (index >= self.count(editor)) return;
        switch (self.view) {
            .overview => switch (index) {
                0 => self.show(editor, .configurations),
                1 => self.show(editor, .threads),
                2 => self.show(editor, .stack),
                3 => self.show(editor, .variables),
                4 => self.show(editor, .breakpoints),
                5 => self.show(editor, .output),
                6 => self.control(editor, .@"continue"),
                7 => self.control(editor, .pause),
                8 => self.control(editor, .next),
                9 => self.control(editor, .stepIn),
                10 => self.control(editor, .stepOut),
                11 => self.stop(editor, false),
                else => {},
            },
            .configurations => {
                try self.start(editor, self.configs.items[index].name);
                self.show(editor, .overview);
            },
            .threads => {
                try self.session.?.selectThread(self.session.?.threads.items[index].id);
                self.show(editor, .stack);
            },
            .stack => {
                if (self.pumping) return;
                self.pumping = true;
                defer self.pumping = false;
                try self.session.?.selectFrame(editor, index, true);
                editor.mode = .normal;
            },
            .variables => try self.session.?.expand(self.variable_indices.items[index]),
            .breakpoints => {
                var offset = index;
                for (self.breakpoints.sources.items) |source| {
                    if (offset >= source.points.items.len) {
                        offset -= source.points.items.len;
                        continue;
                    }
                    const point = source.points.items[offset];
                    const path = try editor.allocator.dupe(u8, source.path);
                    defer editor.allocator.free(path);
                    const doc = try editor.openOrFocus(path);
                    doc.gotoLine(point.actual_line orelse point.line);
                    editor.mode = .normal;
                    break;
                }
            },
            .output => {},
        }
    }
};
fn report(editor: *Editor, message: []const u8) void {
    editor.status_message = std.fmt.bufPrint(&editor.status_buf, "Debug: {s}", .{message}) catch "Debugger error";
}
fn expandWorkspace(a: Allocator, value: *std.json.Value, root: []const u8) !void {
    switch (value.*) {
        .string => |text| {
            var bytes: std.ArrayList(u8) = .empty;
            var parts = std.mem.splitSequence(u8, text, "${workspaceFolder}");
            var first = true;
            while (parts.next()) |part| {
                if (!first) try bytes.appendSlice(a, root);
                first = false;
                try bytes.appendSlice(a, part);
            }
            value.* = .{ .string = try bytes.toOwnedSlice(a) };
        },
        .array => |*items| for (items.items) |*item| try expandWorkspace(a, item, root),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |item| try expandWorkspace(a, item.value_ptr, root);
        },
        else => {},
    }
}
