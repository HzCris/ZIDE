const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Frontend selection: gui, tui, or both
    const Frontend = enum { gui, tui, both };
    const frontend = b.option(Frontend, "frontend", "Which frontend to build (default: both)") orelse .both;

    const build_gui = frontend == .gui or frontend == .both;
    const build_tui = frontend == .tui or frontend == .both;

    // --- Dependencies ---

    // ZigLua (Lua 5.4)
    const ziglua_dep = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });

    // zit TUI library
    const zit_dep = b.dependency("zit", .{
        .target = target,
        .optimize = optimize,
    });

    // libvaxis TUI rendering
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    // GPU backend toggle: -Dgpu=true for SDL3GPU, default SDL3 (lighter memory footprint)
    const use_gpu = b.option(bool, "gpu", "Use SDL3GPU backend (default: false, uses SDL3 renderer)") orelse false;

    // --- GUI executable ---
    if (build_gui) {
        // Build options for GUI
        const gui_options = b.addOptions();
        gui_options.addOption(bool, "has_gui", true);
        gui_options.addOption(bool, "has_gpu", use_gpu);

        const gui_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        gui_mod.addOptions("build_options", gui_options);

        // Backend-specific DVUI imports (enum literals can't be selected at runtime)
        if (use_gpu) {
            const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3gpu });
            gui_mod.addImport("dvui", dvui_dep.module("dvui_sdl3gpu"));
            gui_mod.addImport("sdl-backend", dvui_dep.module("sdl3"));
        } else {
            const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
            gui_mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
            gui_mod.addImport("sdl-backend", dvui_dep.module("sdl3"));
        }
        gui_mod.addImport("zlua", ziglua_dep.module("zlua"));
        gui_mod.addImport("zit", zit_dep.module("zit"));
        gui_mod.addImport("vaxis", vaxis_dep.module("vaxis"));

        // Windows application icon
        gui_mod.addWin32ResourceFile(.{ .file = b.path("src/icons/zide.rc") });

        const gui_exe = b.addExecutable(.{
            .name = "zide",
            .root_module = gui_mod,
        });

        b.installArtifact(gui_exe);

        const run_gui = b.addRunArtifact(gui_exe);
        run_gui.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_gui.addArgs(args);

        const run_step = b.step("run", "Run ZIDE (GUI mode)");
        run_step.dependOn(&run_gui.step);

        const run_gui_step = b.step("run-gui", "Run ZIDE (GUI mode)");
        run_gui_step.dependOn(&run_gui.step);
    }

    // --- TUI executable ---
    if (build_tui) {
        // Build options for TUI
        const tui_options = b.addOptions();
        tui_options.addOption(bool, "has_gui", false);
        tui_options.addOption(bool, "has_gpu", false);

        const tui_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        tui_mod.addOptions("build_options", tui_options);
        tui_mod.addImport("zlua", ziglua_dep.module("zlua"));
        tui_mod.addImport("zit", zit_dep.module("zit"));
        tui_mod.addImport("vaxis", vaxis_dep.module("vaxis"));

        // Windows application icon
        tui_mod.addWin32ResourceFile(.{ .file = b.path("src/icons/zide.rc") });

        const tui_exe = b.addExecutable(.{
            .name = "zide-tui",
            .root_module = tui_mod,
        });

        b.installArtifact(tui_exe);

        const run_tui = b.addRunArtifact(tui_exe);
        run_tui.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_tui.addArgs(args);

        const run_tui_step = b.step("run-tui", "Run ZIDE (TUI mode)");
        run_tui_step.dependOn(&run_tui.step);
    }

    // --- Tests ---
    const test_options = b.addOptions();
    test_options.addOption(bool, "has_gui", false);
    test_options.addOption(bool, "has_gpu", false);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_mod.addOptions("build_options", test_options);
    test_mod.addImport("zlua", ziglua_dep.module("zlua"));
    test_mod.addImport("zit", zit_dep.module("zit"));
    test_mod.addImport("vaxis", vaxis_dep.module("vaxis"));

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
