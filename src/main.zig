const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const zlua = @import("zlua");

pub const std_options: std.Options = .{
    // Suppress DVUI debug-level log spam (layout warnings etc.)
    .log_scope_levels = &.{
        .{ .scope = .dvui, .level = .warn },
    },
    .logFn = logToFile,
};

pub const panic = std.debug.FullPanic(zidePanic);

/// Set at startup so the panic handler can write a crash file — panics in
/// a GUI launch are otherwise invisible (stderr goes nowhere).
var panic_io: ?std.Io = null;

/// Leave a breadcrumb in ~/.config/zide/zide-crash.log (latest crash only:
/// message + raw return addresses), then chain to the default panic.
fn zidePanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    crash_note: {
        const io = panic_io orelse break :crash_note;
        const dir = lua_settings.getConfigDir() orelse break :crash_note;
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/zide-crash.log", .{dir}) catch break :crash_note;
        const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch break :crash_note;
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "panic: {s}\nfirst return address: 0x{x}\n(run zide from a terminal to get a full symbolized stack trace)\n", .{ msg, first_trace_addr orelse 0 }) catch {
            f.writeStreamingAll(io, "panic (message too long to format)\n") catch {};
            break :crash_note;
        };
        f.writeStreamingAll(io, body) catch {};
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

// ---------------------------------------------------------------------------
// Logging
//
// std.log must never touch stderr here: in TUI mode vaxis owns the terminal,
// and a stray log line (e.g. "LSP initialized" arriving seconds after startup)
// gets painted over the alt screen and *sticks*, because vaxis diffs cells and
// never repaints what it didn't draw. In GUI mode the console is freed or
// hidden anyway. So everything goes to ~/.config/zide/zide.log instead
// (truncated each run).
// ---------------------------------------------------------------------------

var log_mutex: std.Io.Mutex = .init;
var log_file: ?std.Io.File = null;
var log_open_failed = false;

fn logToFile(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // std.Options.debug_io is the statically-initialized Io singleton that
    // std itself logs through — always available, independent of the app Io.
    const io = std.Options.debug_io;

    // Mutex: the LSP reader thread and the main thread both log.
    log_mutex.lockUncancelable(io);
    defer log_mutex.unlock(io);

    const file = openLogFile(io) orelse return;
    const prefix = comptime level.asText() ++ (if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ");
    var line_buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    w.print(prefix ++ format ++ "\n", args) catch {}; // overflow: keep what fit
    file.writeStreamingAll(io, w.buffered()) catch {};
}

fn openLogFile(io: std.Io) ?std.Io.File {
    if (log_file) |f| return f;
    if (log_open_failed) return null;
    log_open_failed = true; // assume the worst; cleared on success
    const dir = lua_settings.getConfigDir() orelse return null;
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/zide.log", .{dir}) catch return null;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    log_file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return null;
    log_open_failed = false;
    return log_file;
}

// DVUI + SDL backend only available in the GUI build
const dvui = if (build_options.has_gui) @import("dvui") else struct {};
const SDLBackend = if (build_options.has_gui) @import("sdl-backend") else struct {};

const Editor = @import("core/editor.zig").Editor;
const lua_settings = @import("core/lua_settings.zig");
const lua_api = @import("core/lua_api.zig");
const file_identity = @import("core/file_identity.zig");
const gui = @import("frontend/gui.zig");
const tui = @import("frontend/tui.zig");

const FrontendMode = enum {
    gui,
    tui,
};

/// Scratch-buffer contents shown when ZIDE starts without files — doubles as
/// the hotkey reference. Keep in sync with keybind.zig loadDefaults().
const welcome_text =
    \\// Welcome to ZIDE!
    \\//
    \\// This is a scratch buffer — start typing, open a file with Ctrl+O,
    \\// or press Ctrl+P to browse every command by name.
    \\// Shortcuts below are the defaults; rebind any of them in
    \\// ~/.config/zide/init.lua with  zide.bind("ctrl+s", "save")
    \\// (add { language = "zig" } as a third argument for one language only)
    \\//
    \\// File
    \\//   Ctrl+N            new file           Ctrl+O           open file
    \\//   Ctrl+S            save               Ctrl+Shift+S     save as
    \\//   Ctrl+Q            quit
    \\//
    \\// Edit
    \\//   Ctrl+Z / Ctrl+Y   undo / redo        Ctrl+Shift+Z     redo
    \\//   Ctrl+X / C / V    cut / copy / paste
    \\//   Ctrl+A            select all
    \\//   Ctrl+Shift+D      duplicate line     Ctrl+K           delete line
    \\//   Alt+Up / Down     move line          Ctrl+Bksp / Del  delete word
    \\//   Ctrl+/            toggle comment on selected lines
    \\//
    \\// Find & go
    \\//   Ctrl+F            find               Ctrl+H           find & replace
    \\//   Ctrl+G            go to line         Ctrl+P           command palette
    \\//   Ctrl+E            open file by fuzzy name (arrows live-preview, Esc restores)
    \\//   Ctrl+Shift+F      workspace search & replace   F4/Shift+F4  cycle results
    \\//   Ctrl+Alt+Left/Rt  go back / forward  F7 / Shift+F7    go back / forward
    \\//   Alt+M             jump to matching bracket
    \\//   Ctrl+Left/Right   jump by word       Ctrl+Home/End    file start / end
    \\//   (add Shift to the two above to select while moving)
    \\//
    \\// Multi-cursor
    \\//   Ctrl+D            select next occurrence of selection
    \\//   Ctrl+Shift+Up/Dn  add cursor above / below  (also Ctrl+Alt+Up/Dn)
    \\//   Alt+Click         add cursor at mouse
    \\//   Shift+Alt+Drag    block / column selection  (TUI: plain Alt+Drag)
    \\//
    \\// Tabs & panes (a pane is a split, a tab is a document)
    \\//   Ctrl+W            close tab          Ctrl+Tab         next tab
    \\//   Ctrl+Shift+Tab    previous tab       (also Ctrl+PgDn / Ctrl+PgUp)
    \\//   Ctrl+Shift+T      reopen closed tab
    \\//   Alt+\             split vertical     Alt+Shift+\      split horizontal
    \\//   Alt+Left/Right    focus pane         Ctrl+Alt+Q       close split pane
    \\//   Ctrl+Shift+N      open in new window (GUI; also Ctrl+Alt+N; TUI: split)
    \\//
    \\// Terminal eats Alt+...? These always work:
    \\//   Ctrl+\            split vertical     Ctrl+Shift+\     split horizontal
    \\//   F6 / Shift+F6     focus pane         Ctrl+F4          close split pane
    \\//   Ctrl+Shift+PgUp/PgDn                 move line
    \\//
    \\// Terminal & code intelligence
    \\//   Ctrl+`            toggle terminal    Ctrl+Shift+`     terminal in split
    \\//   Ctrl+Alt+`        detach terminal to its own window (GUI)
    \\//   Ctrl+B            toggle file tree   Ctrl+Space       completion (LSP)
    \\//   Ctrl+Shift+O      open folder as project   (palette: recent_projects; tree: o)
    \\//   F12               go to definition   Shift+F12        find references
    \\//   Ctrl+F12          symbols in file    Ctrl+T           workspace symbols
    \\//   Ctrl+Shift+Space  signature help (also after "(" and ",")
    \\//
    \\// Code review (what changed since the last commit, or since a pinned checkpoint)
    \\//   Ctrl+F8           review changed files   F8 / Shift+F8   read next / previous changed file
    \\//   F9 / Shift+F9     next / previous change in the reader   Ctrl+F9   classic diff
    \\//   (reader: Enter opens the real file at that line, or expands a folded stretch;
    \\//    Review view: A approve, W needs work, D classic diff, O open, R refresh;
    \\//    palette: review_set_baseline pins a checkpoint, review_follow_head goes back)
    \\
;

pub fn main(init: std.process.Init) !void {
    // Juicy Main: gpa (leak-checked in Debug) and the Io instance come from
    // std.process.Init instead of hand-rolled globals.
    const allocator = init.gpa;
    const io = init.io;

    // Config-path helpers (and through them the file logger) need the
    // environment + an Io before any Editor exists.
    lua_settings.process_environ = init.environ_map;
    lua_settings.global_io = io;
    panic_io = io;

    var buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &buf);
    const stdout = &stdout_w.interface;
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_w.interface;

    // Parse CLI arguments (arena-backed; freed automatically on exit)
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var mode: ?FrontendMode = null;
    var renderer_override: ?@import("core/renderer_settings.zig").Mode = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);
    // `zide path/to/project`: a folder argument is the workspace for this
    // launch (file tree root + language-server workspace), not a file.
    var project_dir: ?[]const u8 = null;

    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--gui")) {
            mode = .gui;
        } else if (std.mem.startsWith(u8, arg, "--renderer=")) {
            renderer_override = @import("core/renderer_settings.zig").parse(arg["--renderer=".len..]) catch {
                try stderr.print("Renderer must be auto, hardware, or software.\n", .{});
                try stderr.flush();
                return error.InvalidRenderer;
            };
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
            if (isDirectory(io, arg)) {
                if (project_dir != null) {
                    try stderr.print("Only one project folder can be opened; ignoring {s}\n", .{arg});
                    try stderr.flush();
                } else {
                    project_dir = arg;
                }
            } else {
                try files.append(allocator, arg);
            }
        } else {
            try stderr.print("Unknown option: {s}\n", .{arg});
            try stderr.flush();
            printUsage(stdout);
            std.process.exit(1);
        }
    }

    // Detect frontend mode if not explicitly set: launched from an
    // interactive terminal -> TUI in that terminal; desktop launch -> GUI.
    // (TUI-only builds always run the TUI.)
    const frontend = mode orelse if (build_options.has_gui) detectFrontend(io) else FrontendMode.tui;

    if (builtin.os.tag == .windows and frontend == .gui) {
        // Console-subsystem exe launched from the desktop gets a freshly
        // allocated console (the "flash" window). If ours isn't shared with a
        // parent shell, release it so it doesn't linger behind the GUI.
        var pids: [4]u32 = undefined;
        if (GetConsoleProcessList(&pids, pids.len) <= 1) _ = FreeConsole();
    }

    std.log.info("ZIDE starting in {s} mode", .{@tagName(frontend)});
    if (project_dir) |dir| {
        std.log.info("Project folder: {s}", .{dir});
    }
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
                try runGui(allocator, io, lua, files.items, project_dir, renderer_override);
            } else {
                // CLI usage error — must reach the terminal (logs go to a file).
                try stderr.print("GUI not available in this build. Use zide (not zide-tui) for GUI mode.\n", .{});
                try stderr.flush();
            }
        },
        .tui => try runTui(allocator, io, lua, files.items, project_dir),
    }
}

/// True when `path` (absolute or cwd-relative) names a directory — the
/// command line treats such arguments as the project folder, not a file.
fn isDirectory(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// `zide <folder>`: make the folder this launch's workspace — file tree
/// root and language-server workspace — overriding init.lua's
/// `filetree_root`. Must run after the Lua config is loaded.
fn applyProjectDir(editor: *Editor, project_dir: ?[]const u8) void {
    const dir = project_dir orelse return;
    if (!editor.setFiletreeRoot(dir)) {
        std.log.warn("Cannot open project folder {s}: {s}", .{ dir, editor.status_message });
        return;
    }
    editor.rememberProject();
}

/// Run init.lua, then the theme files and extensions. Returns the status
/// line of a load failure copied into `buf` (init.lua's when it failed,
/// else the latest one; "" when everything loaded). The loaders already
/// show it, but the startup steps after them (project folder, CLI files)
/// write their own status — startup shows it again once they are done.
fn loadUserConfig(lua: *zlua.Lua, buf: []u8) []const u8 {
    const failures = lua_settings.loadFailureCount();
    if (lua_settings.loadConfig(lua)) {
        std.log.info("Loaded user config (init.lua)", .{});
    }
    var kept = keepLoadError(failures, buf);
    lua_settings.loadThemeFiles(lua);
    lua_settings.loadSyntaxTheme(lua);
    lua_settings.loadExtensions(lua);
    lua_settings.loadLangSyntaxThemes(lua);
    if (kept.len == 0) kept = keepLoadError(failures, buf);
    return kept;
}

fn keepLoadError(failures_before: usize, buf: []u8) []const u8 {
    if (lua_settings.loadFailureCount() == failures_before) return buf[0..0];
    const msg = lua_settings.lastLoadError();
    const n = @min(msg.len, buf.len); // both 128 bytes; msg is valid UTF-8
    @memcpy(buf[0..n], msg[0..n]);
    return buf[0..n];
}

/// Open the command-line files: the first replaces the startup document,
/// the rest open as tabs. A path that doesn't exist becomes an empty
/// document bound to it (`zide newfile.zig`, then Ctrl+S creates the
/// file); any other failure is logged and shown in the status bar. Files
/// that need an encoding choice get the editor's encoding picker instead.
fn openCliFiles(editor: *Editor, cli_files: []const []const u8) void {
    for (cli_files, 0..) |path, i| {
        openCliFile(editor, path, i == 0) catch |err| {
            if (err == error.EncodingRequired or err == error.BinaryFile) continue;
            if (err == error.FileNotFound) {
                bindNewFile(editor, path, i == 0) catch |bind_err| reportOpenFailure(editor, path, bind_err);
            } else reportOpenFailure(editor, path, err);
        };
    }
}

fn openCliFile(editor: *Editor, path: []const u8, into_active: bool) anyerror!void {
    // openIntoActive: language detect + LSP notify + extension event
    if (into_active) return editor.openIntoActive(path);
    _ = try editor.openFile(path);
}

/// An empty document bound to `path`, which doesn't exist yet: the startup
/// document for the first argument, a new tab otherwise.
fn bindNewFile(editor: *Editor, path: []const u8, into_active: bool) !void {
    const abs = try file_identity.absolute(editor.allocator, editor.io, path);
    defer editor.allocator.free(abs);
    const doc = if (into_active) editor.activeDoc() else try editor.newDocument();
    try editor.setDocPath(doc, abs); // language, EditorConfig; LSP opens it on the next tick
    lua_api.setStatusText(editor, "New file: ", std.fs.path.basename(abs));
}

fn reportOpenFailure(editor: *Editor, path: []const u8, err: anyerror) void {
    std.log.warn("Failed to open {s}: {s}", .{ path, @errorName(err) });
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Cannot open {s}: {s}", .{ path, @errorName(err) }) catch
        std.fmt.bufPrint(&buf, "Cannot open {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) }) catch
        "Cannot open a command-line file";
    lua_api.setStatusText(editor, "", msg);
}

extern "kernel32" fn GetConsoleProcessList(lpdwProcessList: [*]u32, dwProcessCount: u32) callconv(.winapi) u32;
extern "kernel32" fn FreeConsole() callconv(.winapi) c_int;
// 0.16 removed this from std.os.windows.kernel32 — declare it ourselves.
extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *u32) callconv(.winapi) c_int;

/// Hybrid launch detection: `zide` typed in a terminal opens the TUI there;
/// launching the binary from the desktop opens the GUI.
fn detectFrontend(io: std.Io) FrontendMode {
    if (builtin.os.tag == .windows) {
        // The exe is console-subsystem, so a naive "do we have a console"
        // check is wrong: Explorer double-click ALLOCATES a fresh console.
        // A real terminal launch SHARES the parent shell's console, which
        // shows up as more than one process attached to it.
        var pids: [4]u32 = undefined;
        const shared = GetConsoleProcessList(&pids, pids.len) > 1;
        const in_tty = isConsoleHandle(std.Io.File.stdin().handle);
        const out_tty = isConsoleHandle(std.Io.File.stdout().handle);
        return if (shared and in_tty and out_tty) .tui else .gui;
    } else {
        // Both ends must be a terminal — piped stdin/stdout means scripts or
        // redirection, where popping a TUI would be wrong.
        const in_tty = std.Io.File.stdin().isTty(io) catch false;
        const out_tty = std.Io.File.stdout().isTty(io) catch false;
        return if (in_tty and out_tty) .tui else .gui;
    }
}

fn isConsoleHandle(handle: std.Io.File.Handle) bool {
    var console_mode: u32 = 0;
    return GetConsoleMode(handle, &console_mode) != 0;
}

fn runGui(allocator: std.mem.Allocator, io: std.Io, lua: *zlua.Lua, cli_files: []const []const u8, project_dir: ?[]const u8, renderer_override: ?@import("core/renderer_settings.zig").Mode) !void {
    if (!build_options.has_gui) return;

    if (builtin.os.tag == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    const started = (try @import("frontend/renderer.zig").start(allocator, io, renderer_override)) orelse return;
    var backend = started.backend;
    defer backend.deinit();

    // Init editor state
    var editor = try Editor.init(allocator, io);
    defer editor.deinit();
    editor.renderer_active = started.active;
    editor.renderer_preference = started.preference;
    if (!build_options.has_gpu) editor.renderer_is_software = std.mem.eql(u8, std.mem.span(SDLBackend.c.SDL_GetRendererName(backend.renderer)), "software");

    // Register Lua API and load user config BEFORE starting the LSP —
    // init.lua may override the server command via zide.register_lsp
    // (e.g. a full path to a toolchain-matched zls).
    lua_settings.registerApi(lua, &editor);
    var load_error_buf: [128]u8 = undefined;
    const load_error = loadUserConfig(lua, &load_error_buf);

    // Language servers start lazily when a document of a registered
    // language opens (Editor.lspNotifyOpen / lspTick) and are stopped by
    // editor.deinit — nothing to set up here.

    applyProjectDir(&editor, project_dir);

    // Open CLI files, or show welcome text
    if (cli_files.len > 0) {
        // The first file replaces the default empty document; the rest
        // open as tabs.
        openCliFiles(&editor, cli_files);
    } else if (project_dir == null) {
        // Opt-in session restore (session_persistence); welcome text otherwise
        if (editor.restoreSession() == 0) {
            try editor.activeDoc().loadText(welcome_text);
        }
    } else {
        // A project launch never drags another project's session along.
        try editor.activeDoc().loadText(welcome_text);
    }

    editor.startRecovery();
    editor.startDebugWorkspace();
    editor.startReviewWorkspace();
    // A broken init.lua / extension outranks the startup chatter above.
    if (load_error.len > 0) lua_api.setStatusText(&editor, "", load_error);

    // Per-window GUI state (mono font bytes, per-window pane/drop state).
    // Declared before the dvui window so it outlives every window's font
    // database (which references the font bytes).
    var g = try gui.GuiState.init(allocator);
    defer g.deinit();
    gui.active_state = &g;
    defer gui.active_state = null;

    // OS file drops (Explorer drag-in) flow through the vendored renderer
    // backend's ZIDE patch into the GUI's per-window staging buffer. The
    // sdl3gpu backend (-Dgpu) has no drop hook.
    if (@hasDecl(SDLBackend, "drop_file_fn")) SDLBackend.drop_file_fn = &gui.onSdlDropFile;

    // The click that activates one of our windows is a real click. SDL's
    // default swallows it, which with several ZIDE windows ate the first
    // click of every double-click in the file tree after using another one.
    _ = SDLBackend.c.SDL_SetHint("SDL_MOUSE_FOCUS_CLICKTHROUGH", "1");

    // Init DVUI window with custom theme matching editor theme preset
    var win = try dvui.Window.init(@src(), allocator, backend.backend(), .{
        .theme = gui.dvuiThemeForPreset(editor.theme_name, false, editor.mono_font_size),
    });
    defer win.deinit();
    g.primary().sdl_window_id = SDLBackend.c.SDL_GetWindowID(backend.window);

    // Register the mono font under `custom_mono_family` (the user's file if
    // set, else the bundled Fira Code Nerd Font) and reapply the theme so
    // font_mono resolves to the registered family. Child windows repeat
    // applyWindowFonts on creation — every dvui.Window has its own font database.
    gui.loadMonoFont(&g, &editor, io);
    gui.applyWindowFonts(&win, &g, &editor);
    g.primary().theme_gen_applied = editor.theme_revision;

    // Extra OS windows need the SDL3 renderer backend (the -Dgpu build has
    // none — the window commands split instead).
    editor.multi_window_supported = dvui.Backend.support_child_os_wins;

    // Use SDL3/DVUI native clipboard (works on Wayland where wl-paste subprocess may not).
    editor.clipboard_get_fn = &dvui.clipboardText;
    editor.clipboard_set_fn = &dvui.clipboardTextSet;

    // Terminal output arrives on reader threads while the loop sleeps in
    // waitEventTimeout — wake it so the grid repaints promptly (the TUI does
    // the same through vaxis).
    editor.terminal_wake_fn = &guiWake;
    lua_api.setLuaWake(&editor, &guiWake);
    defer lua_api.setLuaWake(&editor, null);

    var interrupted = false;

    main_loop: while (editor.running) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        const events_result = try backend.addAllEvents(&win);
        // The sdl3gpu backend reports an OS close/quit through its return
        // value; the renderer backend adds .window/.app events instead,
        // which gui.frame handles.
        if (@TypeOf(events_result) == bool) {
            if (events_result) _ = editor.execAction("quit");
        }

        // Language servers: sweep dead ones, drain messages, sync documents
        // (starts servers lazily for newly opened languages)
        editor.lspTick();

        // Deliver finished zide.spawn results to their Lua callbacks
        editor.pumpLuaJobs();

        const keep_running = gui.frame(&editor, &g);

        // New dvui (0.16 snapshot): win.end(.{}) manages the backend by
        // default — it clears (on begin), renders, PRESENTS, and applies the
        // requested cursor + text-input rect. Repeating any of that here
        // double-presents and alternates UI/black frames (flicker). begin()
        // is always balanced by end(), even on the last frame.
        const end_micros = try win.end(.{});
        if (!keep_running) break :main_loop;

        const wait_event_micros = @min(win.waitTime(end_micros), editor.deadlines.waitMicros(std.Io.Clock.now(.awake, io).nanoseconds));
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }

    // Record the session for the next bare launch (no-op unless enabled).
    editor.saveSession();
}

/// Wake the GUI event loop from another thread (terminal reader threads):
/// SDL_PushEvent is thread-safe and a user event ends waitEventTimeout.
fn guiWake() void {
    if (!build_options.has_gui) return;
    var ue = std.mem.zeroes(SDLBackend.c.SDL_Event);
    ue.type = SDLBackend.c.SDL_EVENT_USER;
    _ = SDLBackend.c.SDL_PushEvent(&ue);
}

fn runTui(allocator: std.mem.Allocator, io: std.Io, lua: *zlua.Lua, cli_files: []const []const u8, project_dir: ?[]const u8) !void {
    var editor = try Editor.init(allocator, io);
    defer editor.deinit();

    // Register Lua API and load user config BEFORE starting the LSP —
    // init.lua may override the server command via zide.register_lsp.
    lua_settings.registerApi(lua, &editor);
    var load_error_buf: [128]u8 = undefined;
    const load_error = loadUserConfig(lua, &load_error_buf);

    // Language servers start lazily (see runGui) — nothing to set up here.

    applyProjectDir(&editor, project_dir);

    // Open CLI files, or show welcome text
    if (cli_files.len > 0) {
        openCliFiles(&editor, cli_files);
    } else if (project_dir == null) {
        // Opt-in session restore (session_persistence); welcome text otherwise
        if (editor.restoreSession() == 0) {
            try editor.activeDoc().loadText(welcome_text);
        }
    } else {
        // A project launch never drags another project's session along.
        try editor.activeDoc().loadText(welcome_text);
    }

    editor.startRecovery();
    editor.startDebugWorkspace();
    editor.startReviewWorkspace();
    // A broken init.lua / extension outranks the startup chatter above.
    if (load_error.len > 0) lua_api.setStatusText(&editor, "", load_error);
    try tui.run(allocator, &editor);

    // Record the session for the next bare launch (no-op unless enabled).
    editor.saveSession();
}

fn printUsage(stdout: *std.Io.Writer) void {
    stdout.print(
        \\ZIDE - A lightweight hybrid IDE
        \\
        \\Usage: zide [options] [folder] [files...]
        \\
        \\Options:
        \\  --renderer=auto|hardware|software  GUI renderer for this launch
        \\  --gui          Force GUI mode
        \\  --tui          Force TUI mode
        \\  -h, --help     Show this help
        \\  -v, --version  Show version
        \\
        \\A folder argument opens it as the project: it becomes the file tree
        \\root and the language servers' workspace for this launch.
        \\  zide .                 this directory
        \\  zide ~/code/app        that project
        \\  zide . src/main.zig    project plus a file
        \\
        \\When no mode is specified, ZIDE auto-detects:
        \\  Terminal -> TUI mode
        \\  Desktop  -> GUI mode
        \\
    , .{}) catch {};
    stdout.flush() catch {};
}

test "detect frontend does not crash" {
    const result = detectFrontend(std.testing.io);
    _ = result;
}

test "isDirectory tells project folders from files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj");
    const f = try tmp.dir.createFile(io, "notes.txt", .{});
    f.close(io);

    const dir_path = try tmp.dir.realPathFileAlloc(io, "proj", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const file_path = try tmp.dir.realPathFileAlloc(io, "notes.txt", std.testing.allocator);
    defer std.testing.allocator.free(file_path);

    try std.testing.expect(isDirectory(io, dir_path));
    try std.testing.expect(!isDirectory(io, file_path));
    try std.testing.expect(!isDirectory(io, "definitely/not/a/real/path"));
}

test "CLI files: a missing path becomes a new document bound to it; other failures show" {
    const t = std.testing;
    t.log_level = .err; // the open failure warns
    defer t.log_level = .warn;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "adir");
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const fresh = try std.fs.path.join(t.allocator, &.{ root, "newfile.zig" });
    defer t.allocator.free(fresh);
    const other = try std.fs.path.join(t.allocator, &.{ root, "notes.txt" });
    defer t.allocator.free(other);
    const dir_path = try std.fs.path.join(t.allocator, &.{ root, "adir" });
    defer t.allocator.free(dir_path);

    var editor = try Editor.init(t.allocator, t.io);
    defer editor.deinit();
    editor.lsp_enabled = false;
    openCliFiles(&editor, &.{ fresh, other, dir_path });

    // The first bound the startup document, the second a new tab; the
    // directory failed with a status message instead of only a log line.
    try t.expectEqual(@as(usize, 2), editor.documents.items.len);
    const first = &editor.documents.items[0];
    try t.expect(editor.pathsEqual(first.file_path.?, fresh));
    try t.expectEqualStrings("newfile.zig", first.display_name);
    try t.expectEqualStrings("zig", first.language.?.name);
    try t.expect(!first.dirty);
    try t.expect(editor.pathsEqual(editor.documents.items[1].file_path.?, other));
    try t.expect(std.mem.startsWith(u8, editor.status_message, "Cannot open "));
    try t.expect(std.mem.indexOf(u8, editor.status_message, "adir") != null);

    // Ctrl+S creates the file.
    try editor.documents.items[0].insertAtCursor("const x = 1;\n");
    const saved = editor.saveDocument(editor.documents.items[0].id, .{ .interactive = false });
    try t.expect(saved == .saved);
    const bytes = try tmp.dir.readFileAlloc(t.io, "newfile.zig", t.allocator, .limited(64));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("const x = 1;\n", bytes);
}

// Pull in core module tests
comptime {
    _ = @import("core/buffer.zig");
    _ = @import("core/cursor.zig");
    _ = @import("core/document.zig");
    _ = @import("core/undo.zig");
    _ = @import("core/commands.zig");
    _ = @import("core/editor.zig");
    _ = @import("core/snippets.zig");
    _ = @import("core/snippet_integration_tests.zig");
    _ = @import("core/keybind.zig");
    _ = @import("core/syntax.zig");
    _ = @import("core/theme.zig");
    _ = @import("core/fileicons.zig");
    _ = @import("core/lsp.zig");
    _ = @import("core/lua_json.zig");
    _ = @import("core/lua_settings.zig");
    _ = @import("core/lua_api.zig");
    _ = @import("core/ansi.zig");
    _ = @import("core/terminal.zig");
    _ = @import("core/pty.zig");
    // Import test-bearing services directly so filtered runs discover them even
    // when Editor.init and the other editor tests are not being analyzed.
    _ = @import("core/file_identity.zig");
    _ = @import("core/file_operations.zig");
    _ = @import("core/file_uri.zig");
    _ = @import("core/deadlines.zig");
    _ = @import("core/renderer_settings.zig");
    _ = @import("core/jobs.zig");
    _ = @import("core/protocol.zig");
    _ = @import("core/diagnostics.zig");
    _ = @import("core/editorconfig.zig");
    _ = @import("core/recovery.zig");
    _ = @import("core/workspace_edit.zig");
    _ = @import("core/tasks.zig");
    _ = @import("core/tool_output.zig");
    _ = @import("core/git.zig");
    _ = @import("core/review.zig");
    _ = @import("core/review_reader.zig");
    _ = @import("core/unidiff.zig");
    _ = @import("core/line_diff.zig");
    _ = @import("core/breakpoints.zig");
    _ = @import("core/dap_session.zig");
    _ = @import("core/dap_lua.zig");
    _ = @import("core/dap_integration.zig");
    _ = @import("core/walk_ignore.zig");
    _ = @import("core/text_file.zig");
    _ = @import("core/text_input.zig");
    // Every core file with tests must be listed: tests in files that are
    // only imported by other files are never discovered by the test runner.
    _ = @import("core/clipboard.zig");
    _ = @import("core/dap.zig");
    _ = @import("core/filetree.zig");
    _ = @import("core/layout.zig");
    _ = @import("core/lsp_tools.zig");
    _ = @import("core/search.zig");
    _ = @import("core/task_lua.zig");
    _ = @import("core/tool_panel.zig");
    _ = @import("frontend/gui.zig");
    _ = @import("frontend/tui.zig");
}

test {
    _ = @import("core/review_regressions.zig");
}
