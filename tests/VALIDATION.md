# Release validation

The implemented features and completed checks are tracked in [ImplementationProgress.md](../ImplementationProgress.md). This checklist distinguishes automated coverage from the display and hardware checks still required before declaring the complete release gate passed.

## Automated checks

Run the complete local Debug/ReleaseSafe matrix from any working directory:

```powershell
./scripts/check.ps1
# Optional toolchain selection:
./scripts/check.ps1 -ZigPath C:/tools/zig/zig.exe
```

If Windows PowerShell blocks local scripts through its execution policy, run
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./scripts/check.ps1`.
This selects the policy for that process without changing the system policy.

```sh
bash scripts/check.sh
# Optional toolchain selection:
ZIG=/opt/zig/zig bash scripts/check.sh
```

Both scripts require Zig 0.16.0, build both frontends, run the core suite and
hidden-window GUI suite, and stop with a nonzero exit code on failure. They
preserve command output, including skipped-test counts, under
`zig-out/validation/windows/` or `zig-out/validation/linux/`. Initial builds
may need network access for pinned dependencies. The Linux script uses X11;
without `DISPLAY`, it requires `xvfb-run`, Xvfb and xauth. It does not install
packages or change system configuration. Use a native Linux filesystem for
the checkout and caches, including when running in WSL.

Hosted CI is deferred. External-tool and GPU suites remain separate opt-in
checks; the scripts exercise the standard SDL renderer. Individual commands:

```sh
zig build
zig build test
zig build test-gui
zig build test -Dtest-tools=true
zig build -Dgpu=true
zig build test-gui -Dgpu=true
```

The regular core suite needs no language server or debugger. The tool suite requires ZLS, Git and a working `lldb-dap` on PATH; it compiles its own Zig fixtures with the build toolchain. An installed adapter with a missing runtime dependency is not a successful debugger test. The GPU smoke test directly creates the native backend because DVUI's generic test helper skips it; a compatible device is required for that test.

`-Dtest-filter` selects tests by a substring. For example, a machine with Git and Zig but no debugger can run these two checks:

```sh
zig build test -Dtest-tools=true '-Dtest-filter=Git integration'
zig build test -Dtest-tools=true '-Dtest-filter=Zig task integration'
```

Use a native Linux filesystem for the Linux test workspace and caches. In the tested WSL environment, `/mnt/c` did not preserve POSIX mode bits or support the non-overwriting rename operation. ZIDE reports unsupported tree rename/move operations there while preserving files. This is distinct from normal ext4 operation. Linux documents the filesystem requirement for `RENAME_NOREPLACE` in [rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html).

To exercise each Linux display path explicitly:

```sh
SDL_VIDEO_DRIVER=x11 zig build test-gui
SDL_VIDEO_DRIVER=wayland zig build test-gui
```

Hidden-window tests cover initialization, dialogs, forced software rendering and secondary-window inheritance. Software pixel readback checks cover premultiplied atlas blending, solid fills, triangles, transparent glyphs, clipping, 100%/125%/200% scale and rotated text. Physical display appearance, input-method behavior and input-to-display latency still require interactive checks.

### Reliability and extension regressions — 2026-09-17

The local validation scripts passed with Zig 0.16.0. Both frontends built in
both optimization modes. Debian ran from a native Linux filesystem using
WSLg's X11 display.

| Platform | Modes | Core suite | GUI suite |
| --- | --- | --- | --- |
| Windows | Debug, ReleaseSafe | 342 passed, 12 skipped | 10 passed, 2 skipped |
| Debian WSL / X11 | Debug, ReleaseSafe | 340 passed, 14 skipped | 10 passed, 2 skipped |

Twenty additional regression and integration tests cover document identity
during close/Save As/delayed formatting; same-mtime disk conflicts; stale
Unicode search results, filters and streaming limits; LF/CRLF word commands;
Lua override restoration and allocation failure; and snippet registration,
reload, undo, completion priority and focus changes. Snippet input is also
tested through TUI key dispatch and GUI events in a hidden window.

A Windows PowerShell failure probe verified that native command errors stop
the script before subsequent checks. Linux's no-display preflight correctly
reported the missing X11/Xvfb prerequisite. Optional tool, benchmark and GPU
checks account for some skips; platform-specific tests account for others.

Raw logs are under `zig-out/validation/windows/` and
`zig-out/validation/linux/`. The scripts do not replace the interactive and
physical hardware checks below.

The tested SDL Wayland backend has no native software window framebuffer. ZIDE keeps CPU drawing but enables graphics-based presentation on Wayland; a working EGL/OpenGL ES or other supported graphics driver is required. X11/XWayland offers SDL's native software framebuffer path. This is a correction to the original plan's blanket disabling of framebuffer acceleration, based on the Wayland startup failure and SDL's implementation.

## Software rendering regression and timing

The bundled SDL source is patched in [sdl_software_patch.zig](../libs/dvui/tools/sdl_software_patch.zig). The fixes correct UV stride and texel rounding, preserve premultiplied blending for both rectangles and triangles, and avoid temporary surfaces for opaque triangle fills. The build generates private source copies and checks each replacement against the pinned dependency. Review the patches when upgrading SDL; a system SDL library does not receive these fixes.

Debug builds use optimized SDL C code by default. `-Dsdl-optimize=Debug` restores an unoptimized SDL build for library debugging. This setting does not change the selected runtime renderer.

Run the opt-in benchmark in PowerShell:

```powershell
$env:ZIDE_SOFTWARE_PROFILE = '1'
zig build test-gui
Remove-Item Env:ZIDE_SOFTWARE_PROFILE
```

On Linux, use `ZIDE_SOFTWARE_PROFILE=1 SDL_VIDEO_DRIVER=x11 zig build test-gui`.
The benchmark uses a hidden 2048×1119 software window with VSync disabled, ten warmup frames and sixty measured frames per scene. It reports median/p95 frame time and separates UI submission from rasterization/presentation. Scenes cover Settings over an empty buffer, a populated editor, and Settings over that text. Untimed PNG captures are saved as `.zig-cache/software-settings.png`, `software-editor.png` and `software-settings-text.png`. Timing is diagnostic, not a test pass/fail threshold.

On Windows 10 / Ryzen 9 5900X, the original Debug Settings/empty-buffer reproduction took 576.73 ms median and 592.99 ms p95. Correct blending alone took 573.86 ms; optimizing SDL reduced this to 50.42 ms, and bypassing blending for opaque fills reduced it to 21.92 ms (22.36 ms p95). These are hidden-window CPU measurements on this machine, not physical Linux or input-latency results.

The final three-scene run on 2026-09-15 measured:

| Scene | Debug median / p95 (ms) | ReleaseSafe median / p95 (ms) |
| --- | --- | --- |
| Settings / empty buffer | 23.95 / 26.02 | 27.18 / 28.54 |
| Editor / 80 lines of text | 9.95 / 10.17 | 10.37 / 10.59 |
| Settings / populated editor | 28.68 / 30.20 | 29.65 / 30.59 |

Debug uses ReleaseFast SDL; ReleaseSafe uses ReleaseSafe SDL. The two columns therefore include different C runtime-check costs. Windows core tests passed (319 passed, 11 optional tests skipped). GUI regressions passed on Windows Debug/ReleaseSafe and Debian WSL X11/Wayland (7 passed, 2 skipped per run); enabling the benchmark adds one passing test. The separate GPU suite passed its native initialization/draw test (3 passed, 6 unsupported or inapplicable tests skipped overall).

The follow-up spacing fix addresses floating-point atlas coordinates that decode just below an integer, causing SDL to drop or shift a glyph column. It recovers near-integer source origins and extents before truncation, including the triangle path, while preserving intentional fractional crops. Additional regressions compare odd-sized atlas samples and actual S/P combinations and welcome-screen lines with direct integer-coordinate blits. The bundled font matches pixel-for-pixel at sizes 10, 12, 14, 16 and 20. With `ZIDE_SOFTWARE_PROFILE=1`, `.zig-cache/software-font-spacing.png` shows the rendered line above the reference line. These two extra tests increase the regular GUI suite to nine passing tests and two skips, verified on Windows Debug/ReleaseSafe and Debian WSL X11/Wayland.

## Interactive checks still required

Use an isolated configuration directory and disposable project for each display system. Do not overwrite an existing user configuration to test the first-launch picker.

- First launch: choose each renderer, restart, and verify persistence. Cancel must exit startup. Corrupt the isolated `renderer.json`, then verify the explanatory message and picker. Test an unwritable configuration directory and CLI overrides.
- Settings: change the saved renderer, open a secondary window, and verify both windows retain the active driver. Restart and verify the new preference. The experimental GPU build must explain an unsupported software preference.
- X11 and Wayland: check 100% and fractional/high-DPI scaling, resize, clipped/transparent text, scrolling, IME composition, split panes, secondary windows and embedded-terminal output.
- Save workflows: format through an encoding conflict, cancel a task while closing a terminal, and quit with both a debug session and dirty named/untitled buffers. Cancelled or failed saves must leave the application open and documents dirty.

Automated cross-feature regressions additionally cover multi-file text rename followed by abrupt process termination and recovery, external changes after a snapshot, undoable EditorConfig normalization after an encoding failure, Save As during staging, task save/cancel behavior, late debugger replies during an unsaved quit prompt, and attach/detach with the target remaining alive.

## Physical Linux renderer comparison: pending

Run on both an older Linux machine and an iGPU machine. WSL results do not substitute for these measurements. Record OS/kernel, CPU, GPU/driver, RAM, display protocol/compositor, scale, resolution/refresh rate, power source and build optimization. Use the same source revision, project, font, window size and workload in every run. Run each renderer three times after a warm-up; avoid changing system power policy between runs.

| Workload | Reproduce for each renderer |
| --- | --- |
| Idle | Leave the same project open for 60 seconds with LSP, Git and recovery enabled, with no running task. |
| Editing | Type and navigate the same document in two split panes for 60 seconds. |
| Scrolling | Scroll the same large source file through the same range for 60 seconds. |
| Terminal/task output | Run the same bounded output fixture for 60 seconds. |
| Secondary window | Repeat scrolling with the same second window open. |

Record median/p95 frame duration from a frame/presentation trace, input-to-display latency with a stated measurement method, idle/active process CPU, peak resident memory, and power draw when a reliable meter is available. Keep the raw captures and note missing metrics. A software-rendered window may still be composited by the GPU. Compare actual driver names and measured behavior; integrated graphics alone is not a performance result.

| Machine | Automatic | Hardware | Software |
| --- | --- | --- | --- |
| Older Linux hardware | Pending | Pending | Pending |
| Linux iGPU hardware | Pending | Pending | Pending |
