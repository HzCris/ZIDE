const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const zlua = @import("zlua");

/// Suppress DVUI debug-level log spam (layout warnings etc.)
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .dvui, .level = .warn },
    },
};

// DVUI + SDL backend only available in the GUI build
const dvui = if (build_options.has_gui) @import("dvui") else struct {};
const SDLBackend = if (build_options.has_gui) @import("sdl-backend") else struct {};

const Editor = @import("core/editor.zig").Editor;
const LspClient = @import("core/editor.zig").lsp_mod.LspClient;
const lua_settings = @import("core/lua_settings.zig");
const gui = @import("frontend/gui.zig");
const tui = @import("frontend/tui.zig");

const FrontendMode = enum {
    gui,
    tui,
};

pub fn main() !void {
    var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    var buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_w.interface;
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_w.interface;

    // Parse CLI arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var mode: ?FrontendMode = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);

    // Skip executable name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--gui")) {
            mode = .gui;
        } else if (std.mem.eql(u8, arg, "--tui")) {
            mode = .tui;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(stdout);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try stdout.print("ZIDE v0.0.1\n", .{});
            try stdout.flush();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try files.append(allocator, arg);
        } else {
            try stderr.print("Unknown option: {s}\n", .{arg});
            try stderr.flush();
            printUsage(stdout);
            std.process.exit(1);
        }
    }

    // Detect frontend mode if not explicitly set
    // GUI build defaults to GUI, TUI-only build defaults to TUI
    const frontend = mode orelse if (build_options.has_gui) FrontendMode.gui else FrontendMode.tui;

    std.log.info("ZIDE starting in {s} mode", .{@tagName(frontend)});
    if (files.items.len > 0) {
        std.log.info("Files to open: {d}", .{files.items.len});
    }

    // Initialize Lua state
    var lua = try zlua.Lua.init(allocator);
    defer lua.deinit();
    lua.openLibs();
    std.log.info("Lua 5.4 initialized", .{});

    switch (frontend) {
        .gui => {
            if (build_options.has_gui) {
                try runGui(allocator, lua, files.items);
            } else {
                std.log.err("GUI not available in this build. Use zide (not zide-tui) for GUI mode.", .{});
            }
        },
        .tui => try runTui(allocator, lua, files.items),
    }
}

fn detectFrontend() FrontendMode {
    const out: std.fs.File = .stdout();
    if (builtin.os.tag == .windows) {
        var console_mode: u32 = 0;
        if (std.os.windows.kernel32.GetConsoleMode(out.handle, &console_mode) != 0) {
            return .tui;
        }
        return .gui;
    } else {
        if (std.posix.isatty(out.handle)) {
            return .tui;
        }
        return .gui;
    }
}

fn runGui(allocator: std.mem.Allocator, lua: *zlua.Lua, cli_files: []const []const u8) !void {
    if (!build_options.has_gui) return;

    if (builtin.os.tag == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    // Init editor state
    var editor = try Editor.init(allocator);
    defer editor.deinit();
    editor.gui_available = true;

    // Start LSP client (ZLS)
    var lsp_client = LspClient.init(allocator);
    defer lsp_client.deinit();
    lsp_client.start("zls") catch |err| {
        std.log.warn("Failed to start ZLS: {}", .{err});
    };
    editor.lsp = &lsp_client;

    // Register Lua API and load user config
    lua_settings.registerApi(lua, &editor);
    if (lua_settings.loadConfig(lua)) {
        std.log.info("Loaded user config (init.lua)", .{});
    }
    lua_settings.loadThemeFiles(lua);
    lua_settings.loadSyntaxTheme(lua);
    lua_settings.loadExtensions(lua);
    lua_settings.loadLangSyntaxThemes(lua);

    // Open CLI files, or show welcome text
    if (cli_files.len > 0) {
        // Replace the default empty document with the first file
        editor.activeDoc().open(cli_files[0]) catch |err| {
            std.log.err("Failed to open {s}: {}", .{ cli_files[0], err });
        };
        editor.activeDoc().detectLanguage(&editor);
        // Notify LSP about the first file
        editor.lspNotifyOpen(editor.activeDoc());
        // Open additional files as new tabs
        for (cli_files[1..]) |path| {
            _ = editor.openFile(path) catch |err| {
                std.log.err("Failed to open {s}: {}", .{ path, err });
                continue;
            };
        }
    } else {
        try editor.activeDoc().loadText(
            \\// Welcome to ZIDE!
            \\// Start typing to edit, or open a file from the command line.
            \\//
            \\// Keyboard shortcuts:
            \\//   Ctrl+Z  Undo
            \\//   Ctrl+Y  Redo
            \\//   Ctrl+S  Save
            \\
            \\fn main() void {
            \\    // Your code here
            \\}
            \\
        );
    }

    // Init SDL backend (creates OS window)
    var backend = try SDLBackend.initWindow(.{
        .allocator = allocator,
        .size = .{ .w = 1024.0, .h = 768.0 },
        .min_size = .{ .w = 400.0, .h = 300.0 },
        .vsync = true,
        .title = "ZIDE",
    });
    defer backend.deinit();

    // Init DVUI window with custom theme matching editor theme preset
    var win = try dvui.Window.init(@src(), allocator, backend.backend(), .{
        .theme = gui.dvuiThemeForPreset(editor.theme_name, false, editor.mono_font_size),
    });
    defer win.deinit();

    // Register the mono font under `custom_mono_family`. Prefer the user's path
    // if set; otherwise fall back to the bundled Fira Code Nerd Font.
    var mono_loaded = false;
    if (editor.mono_font_path.len > 0) blk: {
        const f = std.fs.cwd().openFile(editor.mono_font_path, .{}) catch |err| {
            std.log.warn("Failed to open mono font {s}: {} — falling back to bundled font", .{ editor.mono_font_path, err });
            break :blk;
        };
        defer f.close();
        const bytes = f.readToEndAlloc(allocator, 64 * 1024 * 1024) catch |err| {
            std.log.warn("Failed to read mono font {s}: {} — falling back to bundled font", .{ editor.mono_font_path, err });
            break :blk;
        };
        win.addFont(gui.custom_mono_family, bytes, allocator) catch |err| {
            std.log.warn("Failed to register mono font: {} — falling back to bundled font", .{err});
            allocator.free(bytes);
            break :blk;
        };
        mono_loaded = true;
    }
    if (!mono_loaded) {
        // Bundled font bytes are static (embedded in the executable) — pass null
        // allocator so DVUI doesn't try to free them.
        win.addFont(gui.custom_mono_family, gui.bundled_mono_ttf, null) catch |err| {
            std.log.warn("Failed to register bundled mono font: {}", .{err});
        };
    }
    // Reapply theme so font_mono resolves to the registered family.
    win.theme = gui.dvuiThemeForPreset(editor.theme_name, true, editor.mono_font_size);

    // Use SDL3/DVUI native clipboard (works on Wayland where wl-paste subprocess may not).
    editor.clipboard_get_fn = &dvui.clipboardText;
    editor.clipboard_set_fn = &dvui.clipboardTextSet;

    var interrupted = false;

    main_loop: while (editor.running) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        _ = try backend.addAllEvents(&win);

        if (!build_options.has_gpu) {
            // SDL3 software renderer needs manual clear
            _ = SDLBackend.c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 0);
            _ = SDLBackend.c.SDL_RenderClear(backend.renderer);
        }
        // SDL3GPU handles clearing via render pass (LOAD_OP_CLEAR)

        // Poll LSP messages and sync documents
        if (editor.lsp) |l| l.pollMessages(&editor);
        editor.syncLspDocuments();

        if (!gui.frame(&editor)) break :main_loop;

        const end_micros = try win.end(.{});
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

fn runTui(allocator: std.mem.Allocator, lua: *zlua.Lua, cli_files: []const []const u8) !void {
    var editor = try Editor.init(allocator);
    defer editor.deinit();

    // Start LSP client (ZLS)
    var lsp_client = LspClient.init(allocator);
    defer lsp_client.deinit();
    lsp_client.start("zls") catch |err| {
        std.log.warn("Failed to start ZLS: {}", .{err});
    };
    editor.lsp = &lsp_client;

    // Register Lua API and load user config
    lua_settings.registerApi(lua, &editor);
    if (lua_settings.loadConfig(lua)) {
        std.log.info("Loaded user config (init.lua)", .{});
    }
    lua_settings.loadThemeFiles(lua);
    lua_settings.loadSyntaxTheme(lua);
    lua_settings.loadExtensions(lua);
    lua_settings.loadLangSyntaxThemes(lua);

    // Open CLI files, or show welcome text
    if (cli_files.len > 0) {
        editor.activeDoc().open(cli_files[0]) catch |err| {
            std.log.err("Failed to open {s}: {}", .{ cli_files[0], err });
        };
        editor.activeDoc().detectLanguage(&editor);
        // Notify LSP about the first file
        editor.lspNotifyOpen(editor.activeDoc());
        for (cli_files[1..]) |path| {
            _ = editor.openFile(path) catch |err| {
                std.log.err("Failed to open {s}: {}", .{ path, err });
                continue;
            };
        }
    } else {
        try editor.activeDoc().loadText(
            \\// Welcome to ZIDE (TUI mode)
            \\// Start typing to edit.
            \\//
            \\// Shortcuts:
            \\//   Ctrl+Q  Quit
            \\//   Ctrl+S  Save
            \\//   Ctrl+Z  Undo
            \\//   Ctrl+Y  Redo
            \\//   Ctrl+N  New buffer
            \\
            \\fn main() void {
            \\    // Your code here
            \\}
            \\
        );
    }

    try tui.run(allocator, &editor);
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.print(
        \\ZIDE - A lightweight hybrid IDE
        \\
        \\Usage: zide [options] [files...]
        \\
        \\Options:
        \\  --gui          Force GUI mode
        \\  --tui          Force TUI mode
        \\  -h, --help     Show this help
        \\  -v, --version  Show version
        \\
        \\When no mode is specified, ZIDE auto-detects:
        \\  Terminal -> TUI mode
        \\  Desktop  -> GUI mode
        \\
    , .{}) catch {};
    stdout.flush() catch {};
}

test "detect frontend does not crash" {
    const result = detectFrontend();
    _ = result;
}

// Pull in core module tests
comptime {
    _ = @import("core/buffer.zig");
    _ = @import("core/cursor.zig");
    _ = @import("core/document.zig");
    _ = @import("core/undo.zig");
    _ = @import("core/commands.zig");
    _ = @import("core/editor.zig");
    _ = @import("core/keybind.zig");
    _ = @import("core/syntax.zig");
    _ = @import("core/theme.zig");
    _ = @import("core/lsp.zig");
    _ = @import("core/ansi.zig");
    _ = @import("core/terminal.zig");
    _ = @import("core/pty.zig");
    _ = @import("frontend/gui.zig");
    _ = @import("frontend/tui.zig");
}
