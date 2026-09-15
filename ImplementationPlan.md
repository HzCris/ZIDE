ZIDE implementation plan, September 12, 2026.

Implement all seven findings from the code review and all six recommended IDE additions in small, reviewable changes. Keep document behavior, protocols, and feature state in the shared Zig core; provide commands and views in both GUI and TUI. Continue using Lua to declare languages, tools, tasks, and debug adapters. Each milestone below includes its own validation and documentation before the next milestone begins.

The selected renderer policy is a choice on the first GUI launch, with later changes in Settings taking effect after restarting the IDE. The IDE features should ship as practical first versions with the boundaries described below.

The review baseline was a successful Windows build, a successful GUI smoke test, and 277 passing unit tests with one skipped. Five assertion failures plus separate terminal and worker crash probes reproduced five of the seven underlying bugs. GPU close handling and idle TUI autosave were established by source inspection. Reproduction files currently live in the ignored `.zig-cache/code-review-20260912/` directory; migrate useful cases into maintained tests before that cache is cleaned. No application fixes have been implemented by this plan.

The renderer answer needs a distinction between two builds:

| Build | Current behavior | Software support |
| --- | --- | --- |
| Normal `zig build` | DVUI uses SDL3's renderer API and leaves driver selection to SDL. It can use hardware acceleration. | SDL's software driver is already available through `SDL_RENDER_DRIVER=software`; ZIDE does not yet expose a first-launch choice or renderer setting. |
| `zig build -Dgpu=true` | Uses the separate SDL3 GPU API backend. | This compiled backend has no software mode. Supporting both choices in the normal build does not require adopting it. |
| `zide-tui` | Draws through the host terminal. | The GUI renderer preference does not apply; the terminal controls its own rendering. |

SDL documents driver selection, including the software driver, in [SDL_HINT_RENDER_DRIVER](https://wiki.libsdl.org/SDL3/SDL_HINT_RENDER_DRIVER). The existing hidden GUI smoke test passed on Windows with software forced, and also passed with SDL surface acceleration disabled. These checks establish basic compatibility; they do not establish Linux performance or full GUI coverage.

For the existing normal build, this is the Linux command to try CPU rendering now:

```sh
SDL_RENDER_DRIVER=software SDL_FRAMEBUFFER_ACCELERATION=0 ./zig-out/bin/zide --gui .
```

The second variable disables SDL's use of 3D acceleration to present its screen surface, as described in [SDL_HINT_FRAMEBUFFER_ACCELERATION](https://wiki.libsdl.org/SDL3/SDL_HINT_FRAMEBUFFER_ACCELERATION). The desktop compositor can still use the GPU. An integrated GPU is not, by itself, a reason to expect software rendering to perform better: compare CPU load, responsiveness, and power use on the intended Linux systems. Software is a useful explicit compatibility choice when accelerated rendering performs poorly or fails.

Implementation order and release gates:

| Milestone | Deliverable | Depends on |
| --- | --- | --- |
| 1 | All seven bug fixes and maintained regressions | Existing code review |
| 2 | First-launch renderer choice, restart-only settings, startup recovery | 1 |
| 3 | Managed background processes and shared diagnostics | 1 |
| 4 | Dirty-buffer recovery and EditorConfig | 1, 3 |
| 5 | LSP hover, symbol rename, and formatting | 1, 3, 4 |
| 6 | Build/test tasks and a Problems panel | 3, 5 |
| 7 | Git change previews, gutter markers, and file staging | 1, 3 |
| 8 | DAP debugging | 1, 3, 6 |
| 9 | Linux renderer comparison and full release validation | 2 through 8 |

1. **Fix the seven reviewed bugs first.** Use separate focused changes, starting with path identity and save safety. The other fixes can follow without waiting for new IDE features.

   | Finding | Implementation | Required regression |
   | --- | --- | --- |
   | Save As overwrites an existing destination | Add a distinct existing-destination outcome to `Editor.saveDocument`. Hold the source document ID, an owned destination path, format, and destination stamp across the prompt. Offer Overwrite/Cancel for the destination; keep the current Overwrite/Reload/Cancel workflow for an externally changed source. Recheck the destination before writing. If another open document owns it, focus that document and decline Save As to it. | Existing target survives Cancel; confirmed overwrite succeeds; a destination that changes or appears while prompting requires renewed confirmation. Test focus changes, encoding conversion, and Save As during close/quit. |
   | Path aliases bypass open-buffer protection | Introduce a shared file identity module, extending the normalization already used by `text_file.pathKey`. Normalize relative paths against a defined base, resolve existing symlink aliases where possible, and handle missing destinations through their resolved parent. Keep the user-facing/open path separately so atomic saves preserve current symlink behavior. Use identity for open/focus, search/replace, Save As, tree renames, LSP, diagnostics, and recovery. Respect filesystem case behavior; do not lowercase POSIX paths. | Relative/absolute, dot-segment, separator, and supported symlink aliases share one document. Workspace replacement edits its dirty buffer and leaves disk untouched. Tree rename updates every matching document. Include Windows drive/UNC and POSIX fixtures. |
   | Malformed terminal scroll regions crash | Validate the entire DECSTBM region before storing it; reject out-of-range or reversed regions and preserve the previous valid region. Keep scrolling and resize operations within the grid even after malformed input. | Replay `ESC[999;1000r ESC[T` against the small grid from the audit. Add boundary cases, resize cases, and bounded randomized CSI input checking grid invariants. |
   | Lua worker cleanup uses freed state | Make worker ownership cover argument/payload cleanup and wake delivery. Release the final worker reference only after those operations finish. Shutdown disables callbacks, coordinates outstanding workers, and retains their allocator, I/O, and wake targets until they cannot be used. Join workers before destroying referenced infrastructure. | Poisoned-allocator regression with one and several workers finishing during editor shutdown; also test extension reload, queued completion, allocation failure, and a wake racing teardown. |
   | GPU backend window close bypasses unsaved prompts | Convert the GPU backend's quit return into the same shared quit action used by the normal GUI path. Only the completed save/discard workflow changes the final running state. | Dirty named and untitled documents get Save/Discard/Cancel from an OS close event; Cancel keeps the editor open and failed saves prevent exit. Cover both GUI backends and retain secondary-window close behavior. |
   | LSP file URI conversion corrupts paths | Replace string-prefix concatenation/removal with a tested file-URI codec. Handle POSIX roots, Windows drives and UNC authority, UTF-8 byte escaping, percent signs, spaces, and fragment/query delimiters. Reject malformed escapes and unsupported URI schemes/authorities explicitly. | Round trips for `%20` as literal filename text, `#`, Unicode, spaces, POSIX absolute paths, drives, and UNC paths; malformed and non-file URI tests. Follow [RFC 8089](https://www.rfc-editor.org/rfc/rfc8089.txt). |
   | Idle TUI stops autosave and polling | Give the shared editor service work explicit deadlines. Wake the TUI at the next deadline and cap the GUI event wait accordingly. Run state changes on the main thread, coalesce wakeups, and repaint only when needed. Stop/join timer producers before destroying either frontend's event loop. | A dirty buffer autosaves with no keyboard, mouse, or subprocess events. External-change detection also progresses. Test with a controllable clock and confirm idle loops do not busy-poll. |

   Main locations: `src/core/editor.zig`, `document.zig`, `text_file.zig`, `search.zig`, `terminal.zig`, `lua_api.zig`, `lsp.zig`, `src/main.zig`, and `src/frontend/{gui,tui}.zig`. Retain strict encoding, atomic writes, and existing undo semantics. Destination rechecks reduce stale confirmations; do not claim that arbitrary concurrent external writers are locked out by an atomic rename.

2. **Expose renderer choice without changing a running renderer.** Keep the normal SDL renderer backend as the shipping default.

   On the first GUI launch, show Automatic (recommended), Hardware accelerated, and Software before creating the editor's rendering context or opening documents. Use an OS message box through SDL so the picker does not depend on a working accelerated renderer. SDL permits [SDL_ShowMessageBox before SDL initialization](https://wiki.libsdl.org/SDL3/SDL_ShowMessageBox). Cancel exits startup. If no dialog can be shown, report the failure and the command-line recovery option.

   Store a versioned renderer preference in an atomic `renderer.json` file in ZIDE's existing user configuration directory. This allows bootstrap selection before loading editor extensions and avoids rewriting arbitrary Lua to save this preference. Missing preference triggers the picker; a malformed preference reports the problem and offers selection again. An explicit `--renderer=auto|hardware|software` overrides the saved value for that launch and skips the picker without persisting the override. TUI startup never prompts for a GUI renderer.

   Automatic follows SDL driver selection and can retry software after acceleration fails to initialize. Hardware accelerated tries available accelerated drivers and offers a one-time software retry on failure. Software explicitly requests SDL's software driver and disables SDL screen-surface acceleration. Preserve `SDL_RENDER_DRIVER` as an expert override in Automatic mode; log both an unsuccessful requested driver and any fallback. Unsupported VSync must not prevent software startup.

   Keep the active renderer separate from the saved next-launch preference. Settings displays both when they differ and says Restart required. Saving a preference never tears down a context, texture, font cache, or existing window. New secondary windows inherit the current renderer selection. Failed startup retries happen before the editor UI opens and do not silently rewrite the preference. Log the actual SDL driver for troubleshooting; `--renderer=software` remains the escape route when initialization hangs rather than returning an error.

   Keep `-Dgpu=true` explicitly experimental and hardware-only. If that build receives a software preference, explain that the normal build is required; do not pretend the preference was honored or overwrite it. Its picker/settings must show the restriction. Full runtime switching between the two compiled DVUI backends is outside this implementation.

   Add startup policy in a small module used by `main.zig`, a Settings control in `src/frontend/gui.zig`, and narrowly scoped renderer options in `libs/dvui/src/backends/sdl.zig`. Pass the resolved driver into primary and secondary window creation. Also harden the existing `lua_settings.writeSettingToFile` to construct complete output before atomic replacement and propagate read failures, so later feature settings do not inherit its current truncation risk.

   Acceptance: first launch, persistence failure, corrupt preference, command-line precedence, initialization failure/fallback, software rendering, and restart-only changes. Verify that opening a secondary window after changing Settings still uses the active choice. Use isolated configuration directories in tests.

3. **Provide shared background work and diagnostics.** Build on the lifetime and deadline fixes instead of adding detached process handling independently to every feature.

   Add a managed process service with owned argv/cwd/environment, job IDs, streaming stdout/stderr, bounded queues/output, cancellation, and completion/error events. Workers enqueue data; only the main thread calls Lua or changes editor state. Cancellation terminates the owned process group on POSIX or job object on Windows, drains/joins workers, and cannot kill unrelated processes. Stop accepting work during shutdown. Tag results with an owner generation so extension reloads, closed documents, and replaced requests cannot receive stale callbacks.

   Preserve the existing `zide.spawn(argv, callback)` callback shape and its current lack of return values. New task APIs can return IDs. Keep long-lived protocol processes under managed ownership while giving LSP and DAP their own framing/state machines. Bound output without silently losing protocol responses; overflow produces an explicit error and controlled teardown. Shared wakeups must work for GUI and TUI without a continuous redraw loop.

   Add a diagnostic store keyed by file identity, producer, and document version or task run. LSP, Lua linters, and tasks replace only their own findings. Retain findings for closed files and project the same entries into document gutters and the future Problems view. Keep the current Lua diagnostics entry point compatible.

   Acceptance: missing executables, large output, cancellation, rapid completion, stale results, and shutdown during a running tool. Verify independent diagnostic producers cannot erase each other. Use small deterministic helper processes and fake protocol peers.

4. **Add crash recovery and project formatting rules.** These ship as two independent changes within the milestone.

   Recovery is enabled by default and is independent of autosave and path/cursor session persistence. Snapshot dirty named and untitled buffers after two seconds without edits, with a ten-second maximum delay during continuous editing. Store UTF-8 content plus original path/identity, file format, disk stamp, document version, and cursor/selection metadata. Use atomic files under the user configuration directory's `recovery/` subdirectory, separated by workspace and instance. An OS lock distinguishes a live instance from stale recovery data.

   On startup, both frontends offer Recover/Discard for stale snapshots. Recovered text opens dirty and requires the normal save/conflict workflow; recovery never overwrites the source file automatically. Remove a snapshot after a successful save of the corresponding version or explicit discard. Closing a newer dirty version must not delete its only recoverable content. Report snapshot failures, retain earlier valid snapshots after partial writes, and preserve backward compatibility with existing session files.

   EditorConfig gets a shared native parser/resolver with ancestor traversal, `root=true`, section/glob precedence, and `unset`. Resolve properties per document and invalidate cached results after a relevant file changes or a document is renamed. Apply indentation properties ahead of language/global defaults; untitled documents use those defaults until a destination exists. Implement `indent_style`, `indent_size`, `tab_width`, `end_of_line=lf|crlf`, `trim_trailing_whitespace`, and `insert_final_newline`. Follow the [EditorConfig specification and its conformance fixtures](https://spec.editorconfig.org/), including empty-file behavior. Initially leave `charset`, lone-CR output, and spelling configuration unsupported; preserve current encoding selection and never substitute Windows-1252 for Latin-1.

   Treat save-time whitespace and newline edits as one undoable document transaction. Resolve Save As rules against the destination. Use the shared save pipeline for manual save and autosave, preserve representability/conflict checks, and retain visible dirty changes when a write fails. Opening a file or detecting an updated `.editorconfig` must not immediately rewrite its contents.

   Acceptance: abrupt process termination, dirty untitled files, external disk changes, simultaneous instances, damaged snapshots, and failed writes. Run EditorConfig core matching fixtures plus document-level indentation, nested override, Save As, empty-file, Unicode, and undo/redo tests in both frontends.

5. **Extend LSP with hover, symbol rename, and formatting.** Keep the existing Lua server registration model.

   Extend pending requests with document ID/version, server generation, and request purpose; negotiate server capabilities and position encoding. Cancel or reject stale responses, keep message framing bounded, and retain protocol responses rather than dropping them as ordinary output. Add a shared workspace-edit service that resolves file identities, validates versions/ranges, checks for overlapping edits, and preallocates every document transaction before changing any buffer.

   Hover displays server-provided plaintext or supported Markdown in a GUI popup or keyboard-accessible TUI panel. Rename uses `prepareRename` when available, asks for the new name, and previews affected files before applying. Formatting exposes Format Document and capability-gated Format Selection, using the document's effective indentation settings. Format on save is optional and off by default; when enabled, stale/failed/timed-out formatting aborts that save with a clear message and leaves the buffer dirty.

   Apply rename/format edits in memory, with one undo group per affected document. Load closed text documents for editing and leave them dirty for normal saving. A failed preflight applies no edits. Advertise text-edit workspace support only; creation/deletion/rename resource operations and broader refactoring/code actions are deferred. Handle incoming `workspace/applyEdit` through the same validation and preview flow rather than a separate disk-write path.

   Acceptance: fake-server tests for capability absence, UTF-16/UTF-8 positions, surrogate pairs, stale versions, out-of-order responses, duplicate file aliases, and a malformed edit among valid edits. Verify no partial multi-file mutation and no automatic disk write. Exercise the three commands with ZLS in GUI and TUI. Formatting saves must compose with the EditorConfig transaction from milestone 4.

6. **Ship build/test tasks and Problems.** Add Lua `zide.register_task({ name, argv, cwd, env, problem_matcher })`, `zide.run_task(name)`, and `zide.cancel_task(id)`. Default task cwd is the workspace. Pass arguments directly to the process service; shell syntax requires an explicitly configured shell command.

   Provide a task picker, Run/Rerun/Stop commands, streamed output with an explicit truncation indicator, exit status, and clickable file/line references. Ship commented Zig build/test registrations and a Zig diagnostic matcher; allow Lua matchers for other tools. Convert tool line/column conventions at the matcher boundary. Starting a task is explicit; registration or opening a project does not execute it. Offer saving dirty project documents before a task using the established save/conflict workflow.

   Problems combines LSP, Lua linter, and task findings, grouped by file with severity/source filters, keyboard navigation, and next/previous problem commands. It opens closed files at the reported location. Each rerun clears/replaces only its own producer's findings; edits mark unversioned task locations as potentially stale until rerun. GUI and TUI use the same model.

   Acceptance: successful and failing Zig tasks, cancellation, missing tool, filenames with spaces/Unicode, mixed stdout/stderr, and stale results from an older run. Confirm source-specific clearing and navigation into closed files.

7. **Add Git diff and file staging.** Move the existing synchronous Git status subprocesses in `src/core/filetree.zig` behind an asynchronous workspace Git service using the managed process runner. Continue using the Git CLI, with argv arrays, repository-relative paths, NUL-delimited machine-readable output, and `--` where supported. Avoid repeatedly running Git during idle frames.

   Add a Changes panel listing staged, unstaged, untracked, deleted, renamed, and conflicted files. Show read-only staged-versus-HEAD and working-tree-versus-index change previews in both frontends. Gutter markers compare the current buffer with the index, including unsaved edits; label the comparison consistently. Cache results by repository/index state and document version, and discard stale diff jobs.

   Stage and unstage whole files, including both paths of a rename. Stage uses saved disk contents: a dirty open buffer offers Save and stage or Cancel, and a failed/cancelled save prevents staging. Support repositories without an initial commit. Conflicts get an explanatory read-only preview; a merge editor, hunk staging, commits, push, and pull are later work.

   Acceptance: temporary repositories covering initial commit absence, tracked/untracked files, renames, deletes, spaces/Unicode, staged-plus-unstaged changes, dirty buffers, and Git errors. Index mutations must match the selected files, and cancellation must not imply that a completed index write was rolled back.

8. **Implement a practical DAP debugger.** Add a shared DAP client using managed stdio transport and explicit session states. Lua registers adapter argv and named launch/attach configurations. Support one active debug session and begin integration with `lldb-dap` for a small Zig executable. Use the [DAP lifecycle and capability model](https://microsoft.github.io/debug-adapter-protocol/overview.html) and [LLDB's adapter documentation](https://lldb.llvm.org/use/lldbdap.html).

   Implement initialization/configuration sequencing, launch/attach, source breakpoints with verification feedback, continue/pause, step in/over/out, stop/disconnect, thread selection, stack frames, expandable scopes/variables, current execution location, and debug output. Keep breakpoint state per workspace and map locations through shared file identity. Both GUI and TUI expose commands and views over the same session. Clear stale frame/variable handles when execution resumes.

   Default Stop terminates a program launched by ZIDE; for an attached target, disconnect detaches and leaves it running unless the user explicitly chooses termination. Respect adapter capabilities and report adapter exit, timeouts, and protocol errors without blocking editing. First-version debugging targets noninteractive programs and adapter-provided output; advertise terminal-launch requests as unsupported until a proper PTY bridge is implemented. Watches, conditional/log breakpoints, interactive debuggee input, memory/disassembly views, and concurrent sessions are deferred.

   Acceptance: fake-adapter tests for launch event ordering, unverified breakpoints, unknown/unsupported requests, late replies, adapter death, resume invalidation, and stop versus detach. Integrate with a real debug Zig program: hit a breakpoint, inspect a local, step, and finish. Run an attach/detach test that verifies the target survives. Confirm unsaved-document prompts still work while debugging.

9. **Validate the complete implementation on its target systems.** Each earlier milestone runs focused tests as it lands; this gate covers cross-feature behavior and hardware assumptions.

   Keep `zig build`, `zig build test`, and `zig build test-gui` passing on Windows and Linux. Add explicit auto/software GUI smoke cases and exercise the experimental GPU build where a compatible device is available. Use actual GUI sessions on Linux X11 and Wayland to check scaling, resize, text/alpha/clipping, input methods, scrolling, secondary windows, and the embedded terminal. A hidden-window smoke test alone is insufficient.

   Compare hardware and software on an older Linux machine and an iGPU machine using identical window dimensions, source files, split panes, typing/scrolling, and terminal output. Record median/p95 frame time, input responsiveness, idle and active CPU, memory use, and power draw when available. Also measure idle behavior with tasks, LSP, Git, and recovery enabled. Use the measurements to document tradeoffs; do not select a default based solely on the GPU being integrated.

   Finish with cross-feature scenarios: rename several dirty files then recover after a crash; format and save through an encoding conflict; stage a dirty file after Save As; cancel a task while closing a terminal; close the IDE with a debug session and dirty buffers; change the renderer preference, open another window, then restart. Update `README.md`, `Documentation.md`, Lua examples, and the feature checklist as capabilities actually ship. Documentation must distinguish verified support, optional tools, and the explicitly deferred first-version features.
