const std = @import("std");
const t = std.testing;
const dap = @import("dap.zig");
const Editor = @import("editor.zig").Editor;
const source =
    \\const std = @import("std");
    \\noinline fn increment(value: i32) i32 {
    \\    var local = value + 1;
    \\    local += 2;
    \\    return local;
    \\}
    \\pub fn main(init: std.process.Init) !void {
    \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
    \\    if (args.len > 1) {
    \\        while (true) {
    \\            try std.Io.sleep(init.io, .fromMilliseconds(100), .awake);
    \\            const file = try std.Io.Dir.cwd().createFile(init.io, args[1], .{});
    \\            try file.writeStreamingAll(init.io, "alive");
    \\            file.close(init.io);
    \\        }
    \\    }
    \\    const result = increment(39);
    \\    std.debug.print("result={d}\n", .{result});
    \\}
;

fn pump(editor: *Editor) !void {
    editor.dap.tick(editor, std.Io.Clock.now(.awake, editor.io).nanoseconds);
    const session = editor.dap.session.?;
    if (session.phase == .failed) {
        std.debug.print("LLDB failure: {s}\n{s}\n", .{ session.reason[0..session.reason_len], session.output.text.items });
        return error.LldbIntegrationFailed;
    }
    try std.Io.sleep(editor.io, .fromMilliseconds(10), .awake);
}
fn stopped(editor: *Editor) !void {
    for (0..3000) |_| {
        try pump(editor);
        const session = editor.dap.session.?;
        if (session.phase == .stopped and session.nodes.items.len > 0) return;
    }
    const session = editor.dap.session.?;
    std.debug.print("LLDB stopped timeout ({s}): {s}\n{s}\n", .{ @tagName(session.phase), session.reason[0..session.reason_len], session.output.text.items });
    return error.LldbStopTimeout;
}
fn finished(editor: *Editor) !void {
    for (0..2000) |_| {
        try pump(editor);
        if (editor.dap.session.?.phase == .terminated) return;
    }
    return error.LldbFinishTimeout;
}

test "LLDB integration: Zig breakpoint, local variable, step, finish, attach and surviving detach" {
    if (!@import("build_options").test_tools) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const source_path = try std.fs.path.join(t.allocator, &.{ base, "debuggee.zig" });
    defer t.allocator.free(source_path);
    const exe = try std.fs.path.join(t.allocator, &.{ base, if (@import("builtin").os.tag == .windows) "debuggee.exe" else "debuggee" });
    defer t.allocator.free(exe);
    try @import("text_file.zig").atomicWrite(t.allocator, t.io, source_path, source);
    const emit = try std.fmt.allocPrint(t.allocator, "-femit-bin={s}", .{exe});
    defer t.allocator.free(emit);
    const compile = try std.process.run(t.allocator, t.io, .{ .argv = &.{ @import("build_options").zig_exe, "build-exe", "-fllvm", "-ODebug", source_path, emit } });
    defer t.allocator.free(compile.stdout);
    defer t.allocator.free(compile.stderr);
    if (compile.term != .exited or compile.term.exited != 0) {
        std.debug.print("Debug fixture compilation: {s}\n", .{compile.stderr});
        return error.DebugFixtureCompileFailed;
    }
    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    editor.filetree_root = try t.allocator.dupe(u8, base);
    try editor.openIntoActive(source_path);
    const adapter = try dap.Adapter.create(t.allocator, "LLDB", &.{"lldb-dap"}, false);
    try editor.dap.registerAdapter(&editor, adapter);
    const arguments = try std.json.Stringify.valueAlloc(t.allocator, .{ .program = exe, .cwd = base, .stopOnEntry = false, .disableASLR = false }, .{});
    defer t.allocator.free(arguments);
    try editor.dap.registerConfig(&editor, try dap.Config.create(t.allocator, "launch", "LLDB", .launch, arguments, false));
    _ = try editor.dap.breakpoints.toggle(t.allocator, t.io, source_path, 4);
    try editor.dap.start(&editor, "launch");
    try stopped(&editor);
    try t.expect(editor.dap.breakpoints.sources.items[0].points.items[0].verified);
    var session = editor.dap.session.?;
    const locals = for (session.nodes.items, 0..) |node, index| {
        if (std.mem.indexOf(u8, node.name, "Local") != null) break index;
    } else return error.MissingLocalScope;
    try session.expand(locals);
    var found_local = false;
    for (0..1000) |_| {
        try pump(&editor);
        for (session.nodes.items) |node| if (std.mem.eql(u8, node.name, "local") and std.mem.indexOf(u8, node.value, "40") != null) {
            found_local = true;
            break;
        };
        if (found_local) break;
    }
    if (!found_local) for (session.nodes.items) |node| std.debug.print("LLDB variable: {s} = {s}\n", .{ node.name, node.value });
    try t.expect(found_local);
    const old_line = session.execution_line;
    try session.control(.next);
    try t.expectEqual(@as(usize, 0), session.nodes.items.len);
    try stopped(&editor);
    try t.expect(session.execution_line != old_line);
    try session.control(.@"continue");
    try finished(&editor);
    try t.expect(std.mem.indexOf(u8, session.output.text.items, "result=42") != null);

    const heartbeat = try std.fs.path.join(t.allocator, &.{ base, "heartbeat" });
    defer t.allocator.free(heartbeat);
    var child = try std.process.spawn(t.io, .{ .argv = &.{ exe, heartbeat }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = @import("builtin").os.tag == .windows });
    defer child.kill(t.io);
    const pid: i64 = if (@import("builtin").os.tag == .windows) @intCast(GetProcessId(child.id.?)) else @intCast(child.id.?);
    const attach_args = try std.json.Stringify.valueAlloc(t.allocator, .{ .pid = pid }, .{});
    defer t.allocator.free(attach_args);
    try editor.dap.registerConfig(&editor, try dap.Config.create(t.allocator, "attach", "LLDB", .attach, attach_args, false));
    try editor.dap.start(&editor, "attach");
    session = editor.dap.session.?;
    for (0..3000) |_| {
        try pump(&editor);
        if (session.configured and session.launch_response) break;
    }
    try t.expect(session.configured and session.launch_response);
    try session.stop(false);
    try finished(&editor);
    const first = try @import("text_file.zig").Stamp.read(t.io, heartbeat);
    var alive = false;
    for (0..100) |_| {
        try std.Io.sleep(t.io, .fromMilliseconds(20), .awake);
        const after = try @import("text_file.zig").Stamp.read(t.io, heartbeat);
        if (after != null and !std.meta.eql(first, after)) {
            alive = true;
            break;
        }
    }
    try t.expect(alive);
}

extern "kernel32" fn GetProcessId(std.os.windows.HANDLE) callconv(.winapi) u32;
