# Release validation

The implemented features and completed checks are tracked in [ImplementationProgress.md](../ImplementationProgress.md). This checklist distinguishes automated coverage from the display and hardware checks still required before declaring the complete release gate passed.

## Automated checks

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

Hidden-window tests cover initialization, text submission, dialogs, forced software rendering and secondary-window inheritance. They do not establish visual correctness, input-method behavior or responsiveness on a physical display.

The tested SDL Wayland backend has no native software window framebuffer. ZIDE keeps CPU drawing but enables graphics-based presentation on Wayland; a working EGL/OpenGL ES or other supported graphics driver is required. X11/XWayland offers SDL's native software framebuffer path. This is a correction to the original plan's blanket disabling of framebuffer acceleration, based on the Wayland startup failure and SDL's implementation.

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
