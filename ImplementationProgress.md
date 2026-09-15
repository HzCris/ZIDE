The approved feature implementation is complete through milestones 1–8. Updated September 15, 2026. Milestone 9's automated checks pass; physical Linux measurements and manual display workflows remain open.

| Milestone | Result |
| --- | --- |
| 1. Seven reviewed bugs | Implemented with maintained regressions for Save As protection, file identity, malformed terminal regions, worker teardown, shared quit handling, file URIs and idle deadlines. Windows and native Linux core tests pass. Linux testing also found and fixed an abort when a filesystem rejects non-overwriting rename. |
| 2. Renderer selection | First-launch selection, CLI override, saved restart-only preference and startup fallback implemented. Software and secondary-window tests pass on Windows and Linux X11/Wayland. The experimental GPU build compiles on both platforms; direct Windows GPU initialization and a text-frame test pass. See the Wayland correction below. |
| 3. Background processes and diagnostics | Managed processes, cancellation, bounded output/protocol queues and synchronized wakeups are shared by Lua, LSP, tasks, Git and DAP. Diagnostics retain closed files and isolate producers. |
| 4. Recovery and EditorConfig | Implemented in both frontends. Abrupt termination after a multi-file text rename recovers dirty named and untitled buffers without source writes. Locks, external changes, damaged snapshots and failed captures have coverage. EditorConfig runs 130 upstream glob fixtures with six documented specification updates; save normalization remains undoable. |
| 5. LSP hover, rename, formatting | Shared commands and GUI/TUI views implemented. Real Windows ZLS tests pass for hover, prepare/rename, applying edits, formatting and format-on-save. Multi-file preflight rejects stale/invalid edits before mutation and never writes source files directly. |
| 6. Tasks and Problems | Lua registrations, explicit run/rerun/cancel, guarded save-before-run, bounded output, matchers, filters and closed-file navigation implemented. Real Zig task success/failure and cancellation pass on Windows and Linux. |
| 7. Git diff/staging | Background status, previews, file stage/unstage and buffer-versus-index gutters implemented. Windows/Linux temporary repositories cover unborn HEAD, literal/Unicode paths, dirty saves, renames, mixed staged/working changes and Save As during staging. Failed index discovery waits for refresh instead of retrying every frame. |
| 8. DAP debugging | Shared launch/attach, breakpoints, controls, threads, stack, scopes/variables and output implemented. Real Windows LLDB integration hits a Zig breakpoint, inspects a local, steps, finishes, and verifies that an attached target survives detach. Fake-adapter tests cover ordering, stale replies, timeouts and quit prompts. |
| 9. Release validation | Automated Windows and Debian WSL checks pass. Physical older/iGPU Linux performance measurements, interactive first-launch/error flows, and manual display/input checks remain pending. [tests/VALIDATION.md](tests/VALIDATION.md) records the remaining steps. |

All changes are an uncommitted workspace diff. The user's renderer preference and configuration were not changed by tests. Both frontends expose the new commands through the command palette; [examples/tasks.lua](examples/tasks.lua) and [examples/debug.lua](examples/debug.lua) contain commented configurations.

## Final automated results

| Environment/check | Result | Log under `.zig-cache/` |
| --- | --- | --- |
| Windows: both builds, core plus real tools, normal GUI | 58/58 build steps; core 324 pass / 5 skip, GUI 5 pass / 1 skip | `implementation-windows-final.log` |
| Windows experimental GPU build and smoke | 52/52 build steps; 3 pass / 3 skip, including direct GPU initialization/text frame | `implementation-gpu-final.log` |
| Debian WSL: both builds, core, normal GUI | 58/58 build steps; core 317 pass / 12 skip, GUI 5 pass / 1 skip | `implementation-linux-native-final.log` |
| Explicit Linux X11 and Wayland | Each: 5 pass / 1 skip; software rendering and secondary windows included | `implementation-linux-x11.log`, `implementation-linux-wayland.log` |
| Real Linux Git integrations | 4/4 selected tests pass, including both repository scenarios | `implementation-linux-git.log` |
| Real Linux Zig task integration | 3/3 selected tests pass, including success/failure and cancellation | `implementation-linux-tasks.log` |
| Linux experimental GPU compilation | 49/49 build steps | `implementation-linux-gpu-build.log` |

Skipped cases are platform/frontend/optional-tool dependent. The full real ZLS/LLDB suite was run on Windows; Linux real-tool checks cover Git and Zig tasks. DVUI's generic GPU test helper skips that backend, so a separate test directly creates the GPU backend. The core suite's unknown-icon warning is expected. Test discovery explicitly imports the new services so focused runs cannot silently omit lazily loaded modules.

## Wayland correction to the original plan

SDL's native Wayland backend has no native software window framebuffer. Disabling framebuffer acceleration there caused software startup to fail. ZIDE now rasterizes the interface with SDL's software renderer while permitting graphics-based presentation on Wayland. It still disables framebuffer acceleration on X11 and Windows. The Linux picker, Settings and README explain the distinction; startup failures suggest:

```sh
SDL_VIDEO_DRIVER=x11 zide --gui --renderer=software .
```

This corrects the original plan's blanket framebuffer-acceleration rule based on observed failure and SDL's implementation. It does not establish that software is faster on integrated graphics. Physical performance and power measurements are still required.

## Validation environments

- Windows: Zig 0.16.0, installed ZLS, Git, LLVM 22.1.8 `lldb-dap`, and hidden SDL windows. The adapter required `python311.dll`; tests used the official Python 3.11.9 embeddable runtime in `.zig-cache/validation-python311`, added only to the test process PATH. Download SHA-256: `009d6bf7e3b2ddca3d784fa09f90fe54336d5b60f0e0f305c37f400bf83cfd3b`.
- Linux: Debian 13 under WSL2/WSLg, Zig 0.16.0, and a native filesystem copy under `/var/tmp/zide-validation-20260914/workspace`. The official Linux Zig archive was verified against SHA-256 `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`.
- Debian initially lacked EGL/OpenGL graphics libraries. Wayland checks used Debian packages extracted into `/var/tmp/zide-validation-20260914/graphics/runtime`, including Mesa `25.0.7-2+deb13u1`, with process-local library/driver paths. Package metadata was refreshed in an isolated temporary APT directory; no system packages or APT configuration were changed.
- The Windows-mounted WSL workspace did not preserve POSIX permissions or support `RENAME_NOREPLACE`; Linux filesystem assertions were run on the native filesystem. Unsupported tree rename/move now returns an error rather than aborting. No claim is made that the mounted filesystem supports those operations.

Hidden-window checks do not establish physical display correctness, input-method behavior or interactive performance. The release gate remains open until the manual and physical-hardware checklist is completed.
