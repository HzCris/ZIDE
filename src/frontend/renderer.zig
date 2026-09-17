//! GUI bootstrap runs before editor documents, extensions, and GPU resources.
const std = @import("std");
const Backend = @import("sdl-backend");
const c = Backend.c;
const settings = @import("../core/renderer_settings.zig");
const gpu = @import("build_options").has_gpu;
const Mode = settings.Mode;
pub const Started = struct { backend: Backend, preference: Mode, active: Mode };

fn notice(message: [:0]const u8) void {
    if (!c.SDL_ShowSimpleMessageBox(c.SDL_MESSAGEBOX_WARNING, "ZIDE renderer", message, null))
        std.log.warn("{s}", .{message});
}

fn softwareFailureNotice() void {
    notice(if (@import("builtin").os.tag == .linux)
        "ZIDE could not start software rendering. Native Wayland needs graphics-driver libraries for presentation. To use X11 software rendering, try: SDL_VIDEO_DRIVER=x11 zide --gui --renderer=software. See zide.log for details."
    else
        "ZIDE could not start software rendering. See zide.log for details.");
}

fn choose() !?Mode {
    const buttons = [_]c.SDL_MessageBoxButtonData{
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, .buttonID = 0, .text = "Automatic" },
        .{ .flags = 0, .buttonID = 1, .text = "Hardware(GPU)" },
        .{ .flags = if (gpu) c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT else 0, .buttonID = if (gpu) 3 else 2, .text = if (gpu) "Cancel" else "Software" },
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, .buttonID = 3, .text = "Cancel" },
    };
    const data: c.SDL_MessageBoxData = .{
        .flags = c.SDL_MESSAGEBOX_INFORMATION,
        .window = null,
        .title = "Choose ZIDE's renderer",
        .message = if (gpu) "This experimental GPU build requires hardware acceleration. Software rendering requires the normal ZIDE build." else if (@import("builtin").os.tag == .linux) "Choose how ZIDE draws its interface. Changes in Settings take effect after restarting. Software draws on the CPU; native Wayland still needs a graphics driver to present the window. X11 supports software framebuffer presentation." else "Choose how ZIDE draws its interface. You can change this in Settings later; changes take effect after restarting ZIDE.",
        .numbuttons = if (gpu) 3 else buttons.len,
        .buttons = &buttons,
        .colorScheme = null,
    };
    var selected: c_int = -1;
    if (!c.SDL_ShowMessageBox(&data, &selected)) {
        std.log.warn("Renderer picker unavailable. Start with --renderer=software or --renderer=auto: {s}", .{c.SDL_GetError()});
        return error.RendererPickerUnavailable;
    }
    return switch (selected) {
        0 => .auto,
        1 => .hardware,
        2 => .software,
        else => null,
    };
}

fn retrySoftware() bool {
    const buttons = [_]c.SDL_MessageBoxButtonData{
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, .buttonID = 0, .text = "Start in software mode" },
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, .buttonID = 1, .text = "Cancel" },
    };
    const data: c.SDL_MessageBoxData = .{
        .flags = c.SDL_MESSAGEBOX_WARNING,
        .window = null,
        .title = "ZIDE could not start hardware rendering",
        .message = "Try software rendering for this launch? Your saved preference will be kept. You can also start ZIDE with --renderer=software.",
        .numbuttons = buttons.len,
        .buttons = &buttons,
        .colorScheme = null,
    };
    var selected: c_int = -1;
    return c.SDL_ShowMessageBox(&data, &selected) and selected == 0;
}

fn create(allocator: std.mem.Allocator, io: std.Io, mode: Mode) !Backend {
    if (gpu) return Backend.initWindow(.{
        .io = io,
        .allocator = allocator,
        .size = .{ .w = 1024, .h = 768 },
        .min_size = .{ .w = 400, .h = 300 },
        .vsync = true,
        .title = "ZIDE",
    });
    var opts: Backend.InitOptions = .{
        .io = io,
        .size = .{ .w = 1024, .h = 768 },
        .min_size = .{ .w = 400, .h = 300 },
        .vsync = true,
        .title = "ZIDE",
    };
    switch (mode) {
        .auto => {},
        .software => opts.renderer_driver = "software",
        .hardware => {
            const count = c.SDL_GetNumRenderDrivers();
            var i: c_int = 0;
            while (i < count) : (i += 1) {
                const name = c.SDL_GetRenderDriver(i);
                if (name == null or std.mem.eql(u8, std.mem.span(name), "software")) continue;
                opts.renderer_driver = std.mem.span(name);
                if (Backend.initWindow(opts)) |backend| return backend else |err| std.log.warn("Renderer {s} failed: {s}", .{ name, @errorName(err) });
            }
            return error.NoHardwareRenderer;
        },
    }
    return Backend.initWindow(opts);
}

pub fn start(allocator: std.mem.Allocator, io: std.Io, override: ?Mode) !?Started {
    var selected = override;
    const path = settings.configPath(allocator) catch null;
    defer if (path) |p| allocator.free(p);
    if (selected == null) if (path) |p| {
        selected = settings.load(allocator, io, p) catch |err| blk: {
            std.log.warn("Renderer preference could not be read: {s}", .{@errorName(err)});
            notice("ZIDE could not read the saved renderer preference. Please choose a renderer again.");
            break :blk null;
        };
    };
    if (selected == null) {
        selected = try choose();
        const mode = selected orelse return null;
        if (path) |p| settings.save(allocator, io, p, mode) catch {
            notice("ZIDE could not save the renderer preference. This choice applies to this launch; the next launch will ask again.");
        } else notice("ZIDE could not find its configuration directory. This renderer choice applies to this launch only.");
    }
    const preference = selected.?;
    if (gpu and preference == .software) {
        notice("Software rendering requires the normal ZIDE build (zig build without -Dgpu=true). This build uses the SDL GPU API.");
        return error.SoftwareRendererUnavailable;
    }
    const backend = create(allocator, io, preference) catch |err| {
        std.log.warn("Requested renderer {s} failed: {s}", .{ @tagName(preference), @errorName(err) });
        if (gpu) return err;
        if (preference == .software) {
            softwareFailureNotice();
            return err;
        }
        if (preference == .hardware and !retrySoftware()) return null;
        const fallback = create(allocator, io, .software) catch |fallback_err| {
            softwareFailureNotice();
            return fallback_err;
        };
        std.log.info("Started SDL software fallback", .{});
        return .{ .backend = fallback, .preference = preference, .active = .software };
    };
    if (!gpu) std.log.info("SDL renderer: {s}", .{c.SDL_GetRendererName(backend.renderer)});
    return .{ .backend = backend, .preference = preference, .active = preference };
}
