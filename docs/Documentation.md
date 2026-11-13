# ZIDE Feature Documentation

## Recovery, formatting, and language-server edits

Recovery snapshots are enabled by default, independently of autosave and session persistence. Dirty named and untitled buffers are captured after two seconds without edits or at most ten seconds during continuous editing. Each workspace and instance has a separate recovery directory and an OS lock; snapshots are encoded off the main thread. A clean exit removes the instance's recovery directory, and directories of dead instances that hold no snapshots are deleted at the next start. On restart, both frontends offer Recover, Discard, or Later; `recover_documents` opens the prompt again. Recovered documents stay dirty and use the normal save/conflict checks; cursors, scroll position and the file's encoding are restored, and a file that changed on disk since the snapshot comes back flagged as externally changed. A document already open **clean** at the same path is replaced in place; a dirty one is preserved and the recovered version opens as an untitled copy. Recover and Discard act on every snapshot at once — there is no per-file choice — and choosing Discard in the quit prompt deletes the instance's snapshots and stops snapshotting for the rest of the session. The workspace is the file-tree root at startup (`zide <folder>`, else `filetree_root`, else the current directory); re-rooting the tree later does not move recovery. Snapshots live under `~/.config/zide/recovery/`; a document over 32 MiB or with more than 4096 cursors is skipped (`Recovery: SnapshotTooLarge; earlier snapshots retained`) and retried every 10 seconds, and at most 4096 snapshots are offered. Damaged snapshots remain on disk and errors are reported. `zide.set("recovery", false)` disables new snapshots.

EditorConfig resolves ancestor files, `root=true`, section precedence and `unset`; files saved with a UTF-8 BOM work. Supported properties are `indent_style`, `indent_size`, `tab_width`, `end_of_line=lf|crlf`, `trim_trailing_whitespace` and `insert_final_newline`. Save As uses destination rules; failed writes retain visible dirty edits, and an empty file stays empty. Save-time normalization is its own undo step (never merged into the typing before it) and keeps every caret on its line: a trim deletes only whitespace before the line break, and a final newline goes in after a caret at the end of the file. Once a save has applied an explicit `end_of_line` rule, Enter inserts that line ending. An ancestor `.editorconfig` that cannot be re-read (replaced by a directory, a share gone offline) keeps its last rules and is retried later. EditorConfig trouble never fails a save: when the rules cannot be resolved the file is saved without them and the status bar says `Saved X without .editorconfig rules (<error>)`. `charset`, lone-CR output and spelling are unsupported. Use `zide.set("editorconfig", false)` to disable project formatting. Matching fixtures and specification differences are documented in `tests/editorconfig/README.md`.

Both frontends expose these language-server commands through the command palette:

| Command | Behavior |
| --- | --- |
| `hover` | Opens a scrollable text view of documentation at the cursor; Escape closes it. |
| `rename_symbol` | Uses `prepareRename` when supported, asks for a name, then previews affected files. Enter applies; Escape cancels. |
| `format_document` | Formats the document when the server supports it. |
| `format_selection` | Formats the selection when the server supports range formatting. |
| `lsp_references` | Lists every reference to the symbol at the cursor in the tool panel's References view (Shift+F12): `path:line:col` plus the line's text (paths relative to the project, files outside it shortened to `…/dir/file`; open documents reflect unsaved edits; up to 2000). Enter opens the location — a recorded jump, so navigate_back returns; Esc closes; `references` reopens the last list. What counts is the server's call: the declaration itself is included, and zls resolves uses of declarations it can analyze but has no references for `@import` bindings. |
| `lsp_document_symbols` | Go to a symbol in the current file (Ctrl+F12): a picker lists the server's document symbols — name, with the kind and the enclosing symbol as a dim detail — filtered as you type (names starting with the text first, then names containing its letters in order, case-insensitive). Up/Down, PgUp/PgDn, Enter jumps (a recorded jump), Esc closes. |
| `lsp_workspace_symbols` | Search symbols across the workspace (Ctrl+T): the picker opens empty and asks the server for the typed query after every keystroke (`workspace/symbol`); rows show the kind, the container and `file:line`. Up to 5000 rows. |
| `lsp_signature_help` | Shows the signature of the call at the caret in a small popup above the caret line — the active parameter highlighted, plus the parameter's (or the signature's) first documentation line. Ctrl+Shift+Space on demand, and automatically after one of the server's trigger characters (`(` and `,` for zls) while `signature_help_auto` is on; the automatic request never touches the status bar. It closes on `)`, on Escape, and when the caret leaves the line. |

These commands need a saved file and a ready server that supports the feature — otherwise the status bar explains (`LSP: NoLanguageServer`, `FeatureNotSupported`, `UntitledDocument`, `ServerNotReady`, `FormattingInProgress`, `NoSelection`). Every request times out after 10 seconds (`LSP request failed: Request timed out`; `initialize` gets 60, for slow starters), and a reply that arrives after the document changed is dropped (`Document changed; request cancelled`). `lsp_stderr` (palette) opens a read-only tab with what every running server has written to stderr so far (the last 64 KiB each), and `open_log` opens `zide.log` itself — the external-change guard reloads it as it grows. Hover asks for plain text, joins multiple sections with blank lines, caps the result at 64 KiB and drops a reply when the caret has moved meanwhile; no result shows `No hover information`. Formatting sends the document's effective tab width and tabs-or-spaces setting, and only one format runs at a time. The rename field is pre-filled only when the server's `prepareRename` returns a placeholder (range-only replies, zls included, start it empty) and holds up to 255 bytes. Quitting with Save waits for a pending format-on-save, then quits.

Text workspace edits run in memory and produce one undo group per document. Closed files open dirty. Versions, aliases, ranges and allocation requirements are checked before any buffer changes; stale previews fail without partial application. Server `workspace/applyEdit` requests use the same preview. Positions follow LSP 3.17: a `character` past the end of its line means the line end, `{line: lineCount, character: 0}` is the end of the document, edits may share a start position (inserts land in array order), and `documentChanges` wins over `changes` when a server sends both. File creation, deletion and rename operations are unsupported. Edits are capped at 1024 files and 100,000 text edits, and are refused for read-only files, quick-open previews, documents mid-edit, the same file under two aliases, and overlapping edits; a closed file that changed on disk between preview and apply fails as stale. Files an edit opens become tabs in the active window, with the encoding remembered for that path.

`zide.set("format_on_save", true)` enables optional language-server formatting before saving (default false). It applies to documents served by a formatter. Stale responses, failures and timeouts abort that save. Successful formatting then uses the regular EditorConfig, encoding, external-change and destination-overwrite checks. The save runs after the formatting reply has been handled (outside LSP message dispatch), so `save` hooks may restart language servers; hover and rename requests in flight survive it. A document the server does not have open — too large for one LSP message (16 MiB), or not synced yet — saves unformatted with the reason in the status bar (`Saved X unformatted (too large for the language server)`). Auto-save retries a document whose format-on-save waits behind another format in flight; it never switches tabs, closes prompts or reports a failure for it. These settings are also available in GUI Settings.

Protocol processes (language servers and debug adapters) use managed reader/writer workers and bounded queues. A full outgoing queue fails the session instead of dropping a message; a full incoming queue pauses the reader (back-pressure) until the editor catches up, and only an editor that stops taking messages for 30 seconds ends the session. UTF-8 and UTF-16 positions are negotiated. `zig build test -Dtest-tools=true` adds installed-tool integration tests; the regular test suite does not require ZLS.

## Tasks, Problems, Git and debugging

All of these features share their commands, state and keyboard navigation between GUI and TUI. Open a view from the command palette, use arrows or Page Up/Down to select rows, Enter (or Space) to activate, and Escape to return to editing. GUI views are tables (the Changes and Review views with columns, the others one column) with buttons above them and a fixed height, so a long list scrolls inside the table and the window keeps its size; a click anywhere on a row selects it in the Changes and Review views and opens it in the others. These views and the dialogs (encoding picker, recovery, confirm prompts) ignore keys pressed with Ctrl or Alt (also Cmd in the GUI, Super in the TUI): Ctrl+S in Git Changes does not stage. In the GUI tool dialogs, Tab moves between the buttons.

| Feature | Commands | Current scope |
| --- | --- | --- |
| Tasks | `run_task`, `rerun_task`, `stop_task`, `task_output` | Explicit build/check commands, save-before-run prompts, streaming stdout/stderr, exit status and cancellation. In Task Output, R reruns and S stops; the save-before-run prompt takes S (save and run), R (run without saving), C or Escape (cancel). |
| Problems | `problems`, `next_problem`, `previous_problem` | Findings from language servers, Lua linters and tasks, sorted by file and position. F cycles severity (all → error → warning → information → hint); S cycles sources alphabetically. `next_problem` / `previous_problem` follow those filters, wrap around, and report `No matching problems` when nothing matches. Closed files open at the location. |
| Git | `git_changes`, `git_stage`, `git_unstage`, `git_refresh` | Staged/working changes, read-only previews, whole-file stage/unstage and buffer-versus-index gutter marks. |
| Review | `review`, `review_approve`, `review_needs_work`, `review_next_file`, `review_prev_file`, `review_set_baseline`, `review_follow_head`, `review_open_reader`, `review_next_change`, `review_prev_change`, `review_toggle_view`, `review_expand_all`, `review_collapse_all` | The changed-file list with your verdicts (approved / needs work), a reviewed count, a baseline that is the last commit or a commit you pinned, and the reader: the whole file with changed lines tinted and deleted lines kept as ghost rows. See *Reviewing changes* and *Reading a change* below. |
| References | `lsp_references`, `references` | Every reference to the symbol at the cursor, from the language server (see *Recovery, formatting, and language-server edits*). |
| Debugger | `debug_start`, `debug`, `toggle_breakpoint`, `debug_continue`, `debug_pause`, `debug_step_over`, `debug_step_in`, `debug_step_out`, `debug_stop`, `debug_terminate` | One local source session, launch/attach, breakpoint verification, threads, stack frames, expandable scopes/variables, execution location and output. |

Register tasks in `init.lua` or an extension with `zide.register_task({name, argv, cwd, env, problem_matcher})`. `name` and the argv array are required. The workspace is the default cwd; relative cwd values resolve against it. `env` is a table of string overrides. Arguments are passed directly to the executable; shell syntax requires an explicit shell in argv. Registration returns true or nil plus an error and never starts a command (a failure also shows `register_task: <Error>` in the status bar); env keys must be non-empty and contain no `=`, with string values. Re-registering a name replaces the task and cancels its running or waiting run; at most 256 tasks can be registered. `zide.run_task(name)` returns a task ID or nil plus an error (`EditorBusy` while a prompt is open, `TaskAlreadyWaitingForSave`, `TaskNotFound`, `TaskHistoryFull`), and starting a task cancels a still-running earlier run of the same task; the save-before-run prompt covers dirty files inside the workspace root plus untitled buffers. `zide.cancel_task(id)` cancels that run and its owned processes. `rerun_task` while a save-before-run prompt is open cancels that prompt and asks again.

`problem_matcher = "zig"` parses Zig diagnostics. A Lua matcher receives an output line and returns nil or `{file, line, col, severity, message}` (`path` is accepted in place of `file`; `message` is required; `line` and `col` default to 1 and 0 is rejected; an unknown severity counts as `error`); a matcher that raises an error loses only that line, and the first error with its Lua message appears in the Task Output title and once in the status bar. Enter on a Task Output line finds its location with the matcher of the run that produced it. Lines and UTF-8 byte columns are one-based; filenames resolve against the task cwd. Severity accepts `error`, `warning`, `info`, or `hint`. [examples/tasks.lua](../examples/tasks.lua) contains commented registrations. Each run replaces only its own producer's findings; locations from an edited buffer are marked possibly stale. Output is bounded at 4 MiB, individual matcher lines at 64 KiB, and findings at 10,000 per run; truncation is shown. Finished run history retains up to 64 runs.

The Changes panel uses the Git CLI on PATH. Enter previews saved working-tree changes against the index; D previews the index against HEAD; S stages; U unstages; O opens the file; R refreshes. The `git_stage` / `git_unstage` commands do what S / U do. Actions follow the highlighted file by path across refreshes; if it has left the list, nothing happens and the status bar says so. Dirty files offer Save and stage or Cancel. Save As during that prompt cancels staging and asks for a refreshed selection. Renames retain both paths and repositories without a first commit are supported. Conflicts have an explanatory read-only preview. Gutters compare the in-memory buffer, including unsaved edits, with the index, ignoring CRLF/LF differences (a `core.autocrlf` working copy shows only real changes); previews use saved disk contents. The marks render as `+` added / `~` modified / `-` deleted in the TUI and as a colored edge bar (short for deletions) in the GUI, in the `color_git_added/modified/deleted` theme colors; buffers over 4 MiB, comparisons past 200,000 combined lines and overly complex diffs silently show no marks, and there is no setting to turn the gutter marks off (disabling tree colors keeps them). Every Git command runs with `-c core.fsmonitor=false`, so a repository's own config cannot start an fsmonitor hook; clean/smudge filters still run. Status and index checks run on deadlines, and background results are discarded when their inputs change. Commits, network operations, hunk staging and a merge editor are deferred.

**Reviewing changes.** `review` (Ctrl+F8) opens the Review view: one row per changed file — a verdict glyph (`[x]` approved, `[!]` needs work, `[ ]` not yet), a change letter (A added, M modified, D deleted, R renamed, C copied, U conflict, ? untracked), the path and ` <- old` for renames. The title reads `n/N reviewed, k needs work` plus the baseline. Keys: A approves (press again to take it back), W marks needs-work (likewise), D opens the classic diff tab (below), Enter or Space reads the file in the reader (below; when that reader is already open and current it simply comes to the front), O opens the real file, R refreshes and reports how many files the refreshed list holds, P pins the baseline at the current commit and U unpins it (back to the last commit) — the same as `review_set_baseline` / `review_follow_head`. In the GUI the view is a bordered table with banded rows: a verdict icon (a green check, an orange exclamation mark, nothing yet), an Approved checkbox, a Needs-work checkbox (ticking one gives that verdict, ticking it again takes it back), the change letter and the file (that column takes the rest of the width; a longer path is cut at the table's edge); a click anywhere else on a row selects it, the selected row stays highlighted as the arrow keys move it, and the window shows the status bar's message, so a refused verdict is never silent. From anywhere, F8 / Shift+F8 read the next / previous changed file, and `review_approve` / `review_needs_work` judge the Review view's selected row while the view is open, else the active document (the reader's own file counts). While changed files are listed, the status bar shows `Review 2/9 [x]`: reviewed/total and the active file's verdict.

Verdicts are ZIDE's own record, one file per repository under `~/.config/zide/review/<hash>.json` (hashed from the git root, so subfolders of one repository share it). A verdict stores git's blob id of the content you judged plus the file's size and modification time; every 1.5 s the stamps are checked and a changed file is re-hashed (files over 4 MiB count as changed on a stamp change alone). Different content means the file is unreviewed again — so an edit by anything, you or an AI tool, resets the verdict, and nothing but your keypress can set one. Approving also stages the file (`git add`) when git lists a working-tree change, untracked files included; `review_stage_on_approve` (default true) turns that off. Verdicts are refused for conflicts (staging one would mark it resolved) and for files with unsaved edits (save first). A deleted file can be approved; the verdict then covers the deletion.

The baseline decides what "changed" means. By default it is the last commit (the same files as the Changes panel). `review_set_baseline` pins the current commit: the list then shows everything that changed since it, across later commits (`git diff --name-status` plus untracked files), so committing mid-review in lazygit hides nothing; pinning drops verdicts for files the new list no longer shows. `review_follow_head` goes back to the last commit. Mode and commit are remembered per repository; if the pinned commit disappears (rebase, history rewrite) the list falls back to the last commit and the title says so. Outside a Git repository the view says `Review: not a Git repository`. Limits: 50,000 rows and verdicts; a record file that cannot be read is reported once and never overwritten (verdicts then live in memory only).

**Reading a change.** Enter on a Review row, F8 / Shift+F8 from anywhere, or `review_open_reader` opens the reader: a read-only `Review: <file>` tab showing the whole current file, with added and replaced lines softly tinted and deleted lines kept in place as dimmed ghost rows — removed code never silently disappears — and the real file's line numbers in the gutter (blank on ghost rows). Unchanged stretches longer than six lines fold into one `··· N unchanged lines ···` row; Enter on it unfolds it, and `review_expand_all` / `review_collapse_all` do them all. F9 / Shift+F9 jump between changes (at the ends the status bar points at F8); Enter on any other row opens the real file at that line (a recorded jump, so F7 returns). Ctrl+F9 opens the classic view of the same file: a read-only `Diff: <file>` tab with git's own hunks (three lines of context), `+` rows tinted as added, `-` rows as ghosts, hunk headers dim and the new file's line numbers in the gutter; Enter there opens the real file as well, F9 walks its changes, and Ctrl+F9 goes back to the reader on the same line. The diff tab is a snapshot (never rebuilt by itself), and one `Diff:` tab is reused like the reader's. The reader is built from `git diff -U999999` against the baseline (untracked files against nothing), rebuilt in place within about 1.5 s when the file changes on disk or when the baseline or the last commit moves — the caret and the unfolded stretches stay where they were — and one reader tab is reused for every file. Typing, pasting, undo and Save are refused with `Read-only review view — Enter opens the real file` (the same guard now covers `lsp_stderr` tabs). Binary files are listed only, a file whose only change is its mode says so, and a diff over 12 MiB falls back to the classic view. Colors: `color_review_added_bg`, `color_review_modified_bg`, `color_review_ghost_bg`, `color_review_ghost_fg`, `color_review_marker_fg` in the GUI (the alpha is how soft the tint is) and the `tui_color_review_*` twins in the TUI, where ghost rows are also drawn dim.

Register a debug adapter with `zide.register_debug_adapter({name, argv})`, then `zide.register_debug_config({name, adapter, request, arguments})`. `request` is `launch` (default) or `attach`; `arguments` is required (an empty `{}` is fine) and is the adapter's JSON-compatible argument table — a configuration that asks for an interactive terminal (`runInTerminal = true`, or `console` of `integratedTerminal`/`externalTerminal`) is refused at registration. Re-registering a name replaces it (limits: 64 adapters, 256 configurations), `cwd` defaults to the workspace root when `arguments` has none, and the adapter's program is only checked when debugging starts (`start_debug` errors: `DebuggerBusy`, `DebugSessionAlreadyActive`, `DebugConfigurationNotFound`, `DebugAdapterNotFound`). `${workspaceFolder}` expands in string values. Empty tables under list-typed options (`args`, `argv`, and keys ending in `Args` or `Commands`, at any depth) are sent as `[]`; other empty tables stay `{}`. `zide.start_debug(name)` starts a configuration; `zide.stop_debug()` applies normal Stop behavior. `zide.stop_debug(true)` requests attached-target termination when supported. Registrations and start return true or nil plus an error. See [examples/debug.lua](../examples/debug.lua) for LLDB configurations and optional bindings.

The `debug` command opens a 12-item overview — configurations, threads, stack, variables, breakpoints, output, and the continue/pause/step/stop controls; Enter activates (a thread shows its stack, a frame jumps to its source, a variable expands, a breakpoint opens its location), R returns to the overview, S stops, O shows output. Build the executable with debug information before starting. Source breakpoints persist per workspace in `debug/` under the configuration directory (paths that are not UTF-8 are stored as `path_hex`) and follow the file tree root — re-checked every 1.5 s while no session runs, unlike recovery; limits are 256 files, 1024 breakpoints per file and a 2 MiB file read, and a file must be saved before a breakpoint can be set in it. The gutter shows `●` verified, `○` unverified and `>` on the execution line (in the TUI's single gutter column the debugger marker beats a diagnostic `!`, which beats a Git mark); the adapter reports verification, relocated lines and failures. An unusable breakpoint file is reported once and never overwritten; invalid entries are skipped with a count. Breakpoint markers also show in files opened through quick open. Save and rebuild after source changes so executable locations correspond to the source. Resume discards stale stack/variable handles. Stop terminates a launched target and detaches from an attached target; explicit `debug_terminate` requires adapter support. Closing ZIDE also disconnects the session. A stop whose source cannot be opened (libc frames, a moved toolchain) keeps the session running: the frame shows `Source unavailable`, with no execution marker and no encoding picker. Replies are capped at 4096 threads, 4096 stack frames and 256 scopes, and variables expand at most 32 levels deep; a note says what was cut. Adapter errors (with the adapter's formatted message), timeouts and stderr are reported in debug output; telemetry output is hidden. Interactive terminal input/launch, watches, conditional/log breakpoints, memory/disassembly and multiple sessions are deferred.

Reloading extensions cancels their tasks, disconnects their active debug session and replaces their registrations. Core tests use deterministic fixtures; `zig build test -Dtest-tools=true` additionally requires working ZLS, Git and LLDB installations on PATH. The release checklist — the validation runs completed so far and the display and hardware checks still outstanding — is [tests/VALIDATION.md](../tests/VALIDATION.md).

## TUI Frontend

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Ctrl+Q | Quit (prompts if unsaved) |
| Ctrl+S | Save |
| Ctrl+N | New document |
| Ctrl+O | Open file (path input) |
| Ctrl+Z | Undo |
| Ctrl+Y / Ctrl+Shift+Z | Redo |
| Ctrl+C | Copy |
| Ctrl+X | Cut |
| Ctrl+V | Paste |
| Ctrl+A | Select all |
| Ctrl+F | Find |
| Ctrl+H | Find and Replace |
| Ctrl+G | Go to line |
| Ctrl+P | Command palette |
| Ctrl+E | Quick open (fuzzy file finder with live preview) |
| Ctrl+Shift+F | Workspace search & replace panel |
| F4 / Shift+F4 | Next / previous workspace search result |
| Ctrl+Alt+Left / Ctrl+Alt+Right | Go back / go forward through the jump history |
| F7 / Shift+F7 | Go back / go forward (Alt-free alternates) |
| Ctrl+D | Add next occurrence (multi-cursor); selects word first if no selection |
| Ctrl+Shift+D | Duplicate line |
| Ctrl+Shift+Up/Down | Add cursor above/below |
| Ctrl+Alt+Up/Down | Add cursor above/below (fallback for terminals that eat Ctrl+Shift) |
| Ctrl+\ / Ctrl+Shift+\ | Split vertical / horizontal (Alt-free alternates) |
| F6 / Shift+F6 | Focus next / previous pane (Alt-free alternates) |
| Ctrl+F4 | Close split pane (Alt-free alternate) |
| Ctrl+Shift+PgUp/PgDn | Move line up/down (Alt-free alternates) |
| Ctrl+Space | LSP completion |
| F12 | LSP go-to-definition |
| Shift+F12 | Find references (tool panel) |
| Ctrl+F12 | Go to a symbol in this file (picker) |
| Ctrl+T | Search symbols across the workspace (picker) |
| Ctrl+Shift+Space | Signature help for the call at the caret |
| Ctrl+` | Open a new terminal in a bottom split; from a terminal pane (or the terminal panel), back to the editor |
| Ctrl+Shift+` | The terminal panel: a shell docked at the bottom, left or right edge (remembered side and size); focus it, or from it back to the editor — see *Embedded Terminal* |
| Ctrl+Alt+` | Detach the focused terminal — a terminal pane, or the terminal panel's shell — into its own OS window (GUI; TUI: second terminal at the side) |
| Ctrl+B | Toggle file tree side panel |
| Ctrl+Alt+B | Toggle the Snippets side panel — syntax skeletons by plain name; click a row to select it, click the highlighted one to insert it — see *Snippets* |
| Ctrl+Alt+S | Save the selection as a snippet — a small form (name, folder, trigger, language, notes) writes it to `extensions/my-snippets.lua` and the panel shows it — see *Snippets* |
| Ctrl+Shift+O | Open a folder as the project (GUI: native dialog; TUI: path prompt) |
| Ctrl+F8 | Review changed files (verdicts, progress, baseline) |
| F8 / Shift+F8 | Read the next / previous changed file in the review reader |
| F9 / Shift+F9 | Next / previous change inside the review reader |
| Ctrl+F9 | Review reader ↔ classic diff of the same file |
| Alt+Click | Add cursor at click position |
| Shift+Alt+Drag (GUI) / Alt+Drag (TUI) | Block (column) selection — one cursor per line over the dragged column span |
| Ctrl+K | Delete line |
| Ctrl+/ | Toggle comment on selected lines (uses the language's line comment; wraps in block comments for languages without one, e.g. CSS) |
| Alt+M | Jump to the bracket matching the one at the caret |
| Escape / Left-click | End snippet field navigation, remove secondary cursors |
| Ctrl+Left/Right | Word movement |
| Ctrl+Shift+Left/Right | Word selection |
| Ctrl+Backspace | Delete word backward |
| Ctrl+Delete | Delete word forward |
| Ctrl+Home/End | Jump to file start/end |
| Ctrl+Shift+Home/End | Select to file start/end |
| Ctrl+W | Close tab (prompts if unsaved) |
| Ctrl+Shift+T | Reopen the most recently closed file |
| Ctrl+Alt+Q | Close pane (also closes the focused terminal pane; in the terminal panel it closes the panel's shell and leaves the panes alone) |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous document tab |
| Ctrl+PageDown / Ctrl+PageUp | Next / previous document tab |
| Alt+Right / Alt+Left | Focus next / previous split pane |
| Ctrl+Shift+N | Open the current document in a new OS window (GUI; also Ctrl+Alt+N — the TUI splits instead) |
| Ctrl+Shift+S | Save As |
| Alt+\ | Split pane vertically (side by side) |
| Alt+Shift+\ | Split pane horizontally (top/bottom) |
| Alt+Up/Down | Move line up/down |
| Home | Smart home (first non-ws / col 0) |
| End | End of line |
| Shift+Home/End | Extend selection to home/end |
| Shift+Arrow keys | Extend selection |
| Page Up/Down | Page scroll |
| Tab | Next snippet field → expand a snippet trigger → accept open completion → indent (a selection across lines indents every covered line; see *Snippets*) |
| Shift+Tab | Previous snippet field, else dedent every line a caret or selection covers |
| Enter | Newline with auto-indent |
| Mouse left click | Position cursor |
| Mouse left drag | Select text |
| Mouse scroll wheel | Scroll the pane under the mouse (5 lines per tick) |

All Ctrl/Alt shortcuts are remappable via `~/.config/zide/init.lua` — except Ctrl+Tab / Ctrl+Shift+Tab in the GUI and Ctrl+` inside a focused TUI terminal pane, which are hard-wired.

Windows terminals commonly intercept Alt combos (Windows Terminal binds Alt+arrows for its own panes; Ctrl+Alt doubles as AltGr), so every Alt-based default except Ctrl+Alt+` (detach_terminal — use the palette there) has an Alt-free twin (see table). F1–F12 are bindable in both frontends.

### TUI — Implemented Features

**Editing:**
- Insert, delete, backspace, newline with auto-indent — Enter copies only the indentation left of the caret, so Enter at column 0 or inside the indentation never doubles it (Enter at column 0 of a Markdown `  - item` does not nest the item)
- Undo/redo history (Ctrl+Z; Ctrl+Y or Ctrl+Shift+Z): consecutive typed or deleted characters, non-ASCII ones included, form one undo step
- Word movement and word delete (Ctrl+Left/Right, Ctrl+Backspace/Delete): words are runs of ASCII letters, digits, `_` and non-ASCII characters (`héllo`, `привет`), the same rule Ctrl+D uses to pick a word. Motion stops at the line start or end first, then crosses (or deletes) exactly one line break, never splitting a CRLF; inside a line Ctrl+Left and Ctrl+Backspace stop at the indentation and the line start instead of running into the line above
- Line operations: delete (Ctrl+K), duplicate (Ctrl+Shift+D), move up/down (Alt+Up/Down)
- Comment toggle (Ctrl+/): comments/uncomments all selected lines as one undo step, aligned at the block's minimum indent, skipping blank lines; uses `line_comment` from the language definition, falling back to per-line `block_comment_start/end` wrapping (CSS/HTML); works in legacy terminals too (Ctrl+/ arrives as byte 0x1F and is normalized)
- Smart Home (first non-whitespace or column 0)
- Indent/Dedent (Tab/Shift+Tab — Tab first serves snippet fields, a snippet trigger and an open completion popup, see *Snippets*; respects tab_width and use_tabs — the global defaults or the file's language override, see *Per-language settings*). With a selection that crosses a line break (or covers a whole line), Tab indents every covered line as one undo step — empty lines are skipped unless all are empty — and the selection stays over the same text; otherwise Tab types the indentation at each caret. Shift+Tab dedents every line a selection covers, and every caret's line with several cursors, as one undo step
- Auto-closing brackets and quotes (skip-over, smart quote detection)
- Matching-bracket highlight: the bracket under the caret (the one just typed wins over the one at the caret) and its partner are marked — reverse video in the TUI, an outline in the caret color in the GUI — for `()`, `[]` and `{}`. It is a plain nesting-aware byte scan, so brackets inside strings and comments count too, and it gives up after 200,000 bytes. `goto_matching_bracket` (Alt+M) jumps to the partner (a recorded jump, so navigate_back returns)
- Enter between a bracket pair (`{|}`, `(|)`, `[|]`) opens it: the caret lands on its own line one indent level deeper and the closer moves to the line below at the original indentation — one undo step
- UTF-8 aware cursor movement
- Selection (Shift+arrows, Shift+Home/End, Ctrl+A select all)
- Copy/Cut/Paste with system clipboard (Windows Win32 API, Linux wl-copy/xclip/xsel; the Linux readers `wl-paste`/`xclip`/`xsel` get 2 seconds, a timeout is logged). With several cursors, copy and cut join every selection in document order with the document's line ending (a bare caret contributes an empty line) and cut removes them all as one undo step; pasting N lines with N cursors gives each cursor its own line, any other count pastes the whole text at every cursor. Paste converts line breaks to the document's line ending. The Windows clipboard's CRLF reads as LF, and broken UTF-16 (unpaired surrogates) pastes as U+FFFD instead of silently falling back to the stale internal clipboard
- Paste from the terminal (bracketed paste; Linux/macOS): lands as one undoable edit at every cursor — no auto-indent, no auto-closed brackets, line breaks converted to the document's, other control characters dropped. A paste into a prompt or the search panel types its first line; pickers, confirmation prompts and the file tree ignore pastes; a terminal pane passes the paste to its program. The Windows TUI gets no paste markers (see *Not Yet Implemented*)

**Navigation:**
- Incremental/live search (jumps to matches as you type; emptying the query or a query with no match returns the caret to the start point — Escape closes the bar at the current match)
- Find with wrap-around search and "No matches found" / "Search wrapped" feedback
- Find and Replace (Ctrl+H, Tab to switch fields, Enter for next — in the Replace field it replaces the current match and then finds the next; Ctrl+A or Ctrl+Enter replace all, shows count)
- Go to line (Ctrl+G; drops secondary cursors and the selection)
- Command palette (Ctrl+P): the typed letters match a command name in order, case does not matter and a space stands for an underscore (`set baseline` finds `review_set_baseline`); Tab spells the highlighted command out in the input, arrows move the highlight, Enter runs it; the list scrolls past its visible rows
- Quick open (Ctrl+E, `quick_open` in the palette): fuzzy-find any workspace file by name — basename matches rank first; arrowing through results **live-previews** each file in the pane behind the bottom-anchored panel (no tab is created — nothing like VS Code's italic preview tabs); PageUp/PageDown scroll the preview; Enter opens it as a normal tab (EditorConfig rules and stored Problems apply, as for any open), Escape restores exactly where you were — the pre-finder document is found by identity, even if tabs closed meanwhile. Previews never show diagnostics; a preview that was edited meanwhile (e.g. by a Lua timer) is kept as a tab instead of being discarded. The result list scrolls, so all 200 matches are reachable. Lua `zide.exec`, New document, Save and every file open (goto-definition, debugger stops) end quick open first, so nothing acts on, or lands behind, a preview; while it is up the TUI ignores other clicks and chords, and in the GUI a click on the menu bar or tab bar closes it first. Walks the file tree root (caps: 20,000 files, 12 directory levels), skipping dot-entries, `zig-out`, and plain (non-glob) entries from the workspace's top-level `.gitignore` (`name`, `name/`, root-anchored `/name`; `!name` and `!/name` re-include such a name, also un-pruning nested folders of that name; globs, glob or path negations and paths like `src/gen/` are ignored — the file tree still shows these folders; matching is case-sensitive, `name/` also matches files with that name, later lines win, lines with backslash escapes are skipped, and a `.gitignore` over 64 KiB is ignored entirely)
- Workspace search & replace (Ctrl+Shift+F, `find_in_files`): **docked bottom panel** with search / replace / files-to-include / files-to-exclude fields (Tab cycles, click focuses; include and exclude take `*.ext` or a path substring and apply to both open buffers and the disk walk), case (Alt+C) and whole-word (Alt+W) toggles. While the panel owns the keyboard, Ctrl+C copies the focused field, Ctrl+X cuts it, Ctrl+V pastes the clipboard's first line and Ctrl+Backspace deletes the previous word; Ctrl+A and Ctrl+Delete leave the document alone (see *Keyboard focus* under Command System). A background worker streams `path:line: excerpt` results in live — open documents are searched **in-buffer** (dirty edits included) and skipped on disk — an open document whose path cannot be resolved (a reserved name, an unreachable share) is left out and counted as skipped, and the disk walk still runs; dot-entries, `zig-out`, plain (non-glob) entries from the workspace's top-level `.gitignore` (same rules as quick open), binaries, and files > 8 MB are skipped; results cap at 2000 with an explicit "(capped)" note. Up/Down move the result selection and PgUp/PgDn jump eight rows (the GUI skips collapsed file groups). Enter opens a result with the match selected (the GUI also opens on double-click), refreshing that file when needed; the nearest surviving match is selected, or the caret and selection stay intact if none remains. Results retain their original query. Finish the search and rerun it after changing criteria before replacing. Filters use workspace-relative paths for files inside the workspace and absolute paths for named open files outside it; Escape hides the panel but results persist — **F4 / Shift+F4** cycle through them while editing. Replace All (Enter on the Replace field) asks per operation: `[A]ll` (open docs get one undoable edit group each and stay unsaved; closed files are rewritten on disk — **not undoable**) or `[O]pen docs only` — only unmodified letters answer, so Ctrl+A does not mean All. Matching is literal (no regex yet); the filter takes `*.ext` or a path substring
- Navigation history (`navigate_back` / `navigate_forward` — Ctrl+Alt+Left / Ctrl+Alt+Right, Alt-free F7 / Shift+F7): every jump records the caret it leaves — go to definition, go to line, next TODO, quick open, search results (Enter and F4), Problems / Task Output / Changes / Debug locations, file-tree opens, Open File, and debugger stops — so back returns there and forward re-jumps. Points on the same line collapse into one, a new jump forgets the forward entries, 100 entries are kept, closed files are reopened on the way back, entries for a closed untitled buffer are skipped, and the status bar says `Nothing to go back to` / `Nothing to go forward to` when the history is exhausted
- Ctrl+Home/End for file start/end
- Page Up/Down

**Display:**
- Syntax highlighting (Zig built-in, extensible via Lua — see Syntax Highlighting section)
- TODO comment highlighting: `TODO`/`FIXME`/`XXX`/`HACK`/`BUG`/`NOTE` inside comments get the `todo` syntax color; `next_todo` command (palette) jumps to the next marker with wrap-around
- Markdown highlighting (built-in for `.md`/`.markdown`): headings, bold/italic, inline code and ``` fences, links/images/autolinks, list bullets + task checkboxes, blockquotes, tables, strikethrough, HTML comments (TODO markers inside get the `todo` color). The TUI additionally renders headings/bold in real bold, italics in italic, links underlined
- Markdown editing: Enter continues list/quote markers (`- `, `1. ` with auto-increment, `> `, `- [ ] `); Enter on an empty item ends the list; `toggle_checkbox` palette command flips `[ ]`/`[x]` (bundled `extensions/markdown.lua`)
- Line numbers with active line highlight
- Visual-row cursor movement with word wrap (Up/Down navigate wrapped rows, not logical lines, and keep their column through shorter lines)
- Status bar: filename with ` [+]` when dirty (`*` marks dirty tabs in the tab bar), `Ln X, Col Y | language | encoding`, an `N cursors |` prefix with several cursors, ` [TERMINAL]` for terminal panes
- Tab bar when multiple documents open
- Selection highlighting
- Word wrap (word-boundary aware, configurable)
- Tilde `~` markers for lines past end of file
- Wrap continuation markers (`.`)
- Tabs are drawn to their tab stops (counted from the start of each wrapped row); caret, selection, clicks and wrapping measure tabs and wide characters in the same cells, a click lands on the nearer edge of a tab or wide character, and diagnostic underlines follow cell columns
- The caret is hidden while it is scrolled out of view

**Mouse:**
- Linux/macOS terminals: ZIDE switches on mouse reporting and bracketed paste (a Windows console delivers mouse events on its own)
- Left click to position cursor (clears secondary cursors, configurable)
- Alt+click to add cursor at position
- Alt+drag for block (column) selection: one cursor per line over the dragged column span; short lines get a zero-width cursor at their end. Shift+Alt+drag also works in terminals that forward Shift+drag (Windows Terminal keeps it for its own selection, hence plain Alt+drag)
- Left drag to select text (a drag stays in the pane it started in)
- Scroll wheel scrolls the pane under the mouse, independent of the cursor (nothing over a terminal pane, which has no scrollback); over the file tree it scrolls the tree and over the search panel it moves the result selection (3 rows per tick there)
- Click a tab in the tab bar to switch to it
- Click in a split pane to focus it

**Split Panes:**
- Vertical split (Alt+\\) and horizontal split (Alt+Shift+\\)
- Nested splits supported (binary layout tree)
- Pane separators rendered with box-drawing characters
- Close pane (Ctrl+Alt+Q) — focus moves to its neighbour, the first pane of the sibling split, not the next pane in cycle order; focus next/prev (Alt+Right/Alt+Left)
- One window only: `open_in_new_window` / Ctrl+Shift+N and `move_pane_to_new_window` split instead (a terminal pane gets a second terminal at the side); `close_window` quits via the unsaved-changes prompt

**Documents / File I/O:**
- Multi-document tabs (Ctrl+N new, Ctrl+W close, open by path)
- Reopen closed tab (Ctrl+Shift+T, `reopen_closed_tab`, File menu in the GUI): brings back the most recently closed file at the caret it was closed with. The last 20 closed files are remembered, one entry per file; a file that is open again is skipped, untitled buffers are not remembered, and an empty list says `No closed tabs to reopen`
- Tab switching: Ctrl+Tab / Ctrl+Shift+Tab, Ctrl+PageDown / Ctrl+PageUp
- Open file by path (Ctrl+O; a failed open is reported in the status bar)
- Open folder (Ctrl+Shift+O, `open_folder`): the folder becomes the project — file tree root and language-server workspace (servers restart; recovery snapshots keep the startup workspace) — and joins the recent list. GUI: a native folder dialog, also File > Open Folder; TUI: a path prompt. `recent_projects` (palette; GUI also File > Recent Projects) picks from the last nine project folders, newest first, stored in `~/.config/zide/recent_projects`; `zide <folder>` launches count too, and a folder that can no longer be opened drops off the list. In the tree, `o` (`filetree_set_root`; GUI context menu *Open as Root*) makes the selected folder — or a selected file's folder — the project root
- Save (Ctrl+S), Save As (Ctrl+Shift+S)
- Line ending detection (LF / CRLF): the first line break within the first 8 KiB decides, and none there means LF; undo and redo re-detect it, and once a save has applied an explicit EditorConfig `end_of_line` rule, Enter inserts that ending
- External change detection: file identity, size and modification time are checked before saving and polled for open files (~1.5s, same cadence as the file tree probe) — clean buffers reload in place with the cursor preserved; dirty buffers are flagged and saving asks `[O]verwrite [R]eload [C]ancel` instead of silently clobbering; auto-save skips flagged files; a file deleted on disk marks its buffer dirty so the content survives and can be re-saved
- Dirty tracking
- Unsaved changes prompts (Save/Discard/Cancel): on quit for every document, and when closing a dirty tab — Ctrl+W, File > Close Tab, a tab's × and its right-click Close Tab all ask about that one document. Save on an untitled tab goes through Save As and closes the tab once the file is written; a file that changed on disk meanwhile gets the overwrite prompt instead and the tab stays open
- Session persistence (opt-in: `zide.set("session_persistence", true)` or the Settings dialog): on quit the open files, cursor positions, scroll offsets and active tab are written to `~/.config/zide/session`; launching ZIDE without file or folder arguments restores them (missing files are skipped, untitled buffers are not recorded; restored files get EditorConfig rules and stored Problems like any open). Applies to both frontends. Windows and split layouts are not part of the session — everything reopens in the main window.

**Configuration:**
- Config folder hierarchy: `~/.config/zide/` with `themes/` and `extensions/` subfolders
- Lua settings file (`~/.config/zide/init.lua`)
  - `zide.set_language(name, { tab_width = 2, use_tabs = false, word_wrap = true, auto_close_brackets = false })` — per-language overrides of those four settings for files of that language (merge: only the keys given change; name matched case-insensitively; works for built-ins and for languages registered later); `zide.get_language(name)` reads the overrides back (nil when none)
  - `zide.set(key, value)` — accepted keys, defaults in parentheses. Out-of-range or wrong-typed values are ignored silently; booleans use Lua truthiness, so any value except `false`/`nil` turns one on; an unknown key logs `zide.set: unknown key`, and invalid theme/side/color values log a warning and keep the old value:
    - Editing: `tab_width` (4, range 1–16), `use_tabs` (false), `word_wrap` (true), `auto_close_brackets` (true) — the global defaults, see `zide.set_language`; `max_undo_history` (100, 0–100000, 0 = unlimited), `click_clears_cursors` (true)
    - Saving: `auto_save` (false), `auto_save_interval_ms` (5000, 500–300000), `format_on_save` (false), `editorconfig` (true), `recovery` (true), `session_persistence` (false)
    - Languages: `lsp_enabled` (true; off = no language servers, running ones stop on the next frame), `syntax_highlighting` (true; off = plain-text look), `completion_auto` (true; off = the completion popup only opens on Ctrl+Space), `completion_min_chars` (1, 1–8; identifier characters typed before the popup opens by itself), `signature_help_auto` (true; off = signature help only on Ctrl+Shift+Space)
    - Review: `review_stage_on_approve` (true; approving a changed file also stages it — off = verdicts never touch git)
    - Appearance: `theme` ("dark"), `tui_theme` ("terminal"), `gutter_min_digits` (3, 1–10, both frontends), `secondary_window_chrome` (true; GUI: menu bar + status bar in extra windows, false = bare pane containers), `page_size` (accepted but overwritten by the viewport height every frame, so it has no lasting effect)
    - File tree: `filetree_visible` (true), `filetree_side` ("left"/"right"), `filetree_width` (240 GUI px, 120–600), `tui_filetree_width` (30 columns, 16–80), `filetree_root` (starting directory, "" = cwd; stored unvalidated from Lua — the Settings dialog checks it), `filetree_git_colors` (true; off = no tree Git colors, Changes and gutters remain available), `filetree_auto_reveal` (true, read by the GUI), `tui_filetree_icons` (false), `filetree_font_size` (0 = theme font, 0–32), `filetree_icon_scale` (90, 50–200)
    - Snippets panel: `snippets_visible` (false; at runtime hiding it also returns the keyboard to the pane), `snippets_side` ("auto"/"left"/"right"; auto docks opposite the file tree), `snippets_width` (260 GUI px, 120–600), `tui_snippets_width` (32 columns, 16–80), `snippets_double_click` (false; GUI: true makes a click only select a snippet and keep its preview — a double-click or Enter inserts it). All five have rows in the Settings dialog
    - Terminal panel: `terminal_panel_side` ("bottom"/"left"/"right"), `terminal_panel_width` (420 GUI px, 160–1600; used at a side), `terminal_panel_height` (240 GUI px, 80–1200; used at the bottom), `tui_terminal_panel_width` (60 columns, 20–200), `tui_terminal_panel_height` (12 rows, 3–60). All five have rows in the Settings dialog
  - `zide.set("mono_font_path", "/path/to/font.ttf")` — use a custom monospace font (GUI only; read once at startup, so a change needs a restart, and a bad path falls back to the bundled font with a logged warning; pick a Nerd Font to keep box-drawing/powerline glyphs and tree icons)
  - `zide.set("mono_font_size", 14)` — override the default monospace font size (GUI only, applies live)
  - `zide.set("tui_theme", name)` — switch TUI theme ("terminal", "dark", "light", "high_contrast")
  - `zide.set("tui_color_*", "#hex")` — override individual TUI color (e.g. `tui_color_text_fg`)
  - `zide.set("syn_*", "#hex")` — override syntax highlight color (e.g. `syn_keyword`, `syn_comment`)
  - `zide.set("tui_syn_*", "#hex")` — override TUI-only syntax color
  - `zide.register_language({...})` — register a language for syntax highlighting (see Syntax Highlighting section)
  - `zide.register_lsp({...})` — register an LSP server for a language (see LSP Support section)
  - `zide.get(key)` — read current settings (the color families and `mono_font_*` return nil; `theme`/`tui_theme` return `"custom"` after any color override)
  - `zide.bind(key_combo, command [, { language = "zig" }])` — remap keybindings; with the `language` option the binding lives in that language's overlay and applies only while editing a file of that language (see *Command System*)
  - `zide.unbind(key_combo [, { language = "zig" }])` — remove a keybinding (global, or from a language overlay)
  - Settings ZIDE writes back to init.lua (Settings dialog, theme switches, tree width and side, `toggle_tui_icons`) update or append one `zide.set("key", value)` line: string values are quoted and escaped (Windows paths survive), a line that would not compile is refused, and keys must be identifiers
  - Config load order: init.lua → themes/gui-theme.lua → themes/tui-theme.lua → themes/syntax-theme.lua → extensions/*.lua → themes/syn_theme_<lang>.lua — a later file's `zide.set` overrides an earlier one's, and extension files load in directory order (not sorted)
- Data-driven keybinding map (all Ctrl/Alt shortcuts remappable, globally or per language)
- File tree side panel (Ctrl+B) — dockable left/right column band with mouse + keyboard browsing, create/rename/delete prompts, reveal-current-file (see File Tree section)
- Snippets side panel (Ctrl+Alt+B) — the document language's snippets in collapsible groups by plain name with a preview (the code with its blanks, the notes) under them; click a row to select it, click the highlighted item or press Enter to insert it at the caret with Tab walking the blanks; docks like the tree (`tui_snippets_width` columns), Shift+Up/Down scroll long notes; typing filters the list, F2 edits your snippet or copies a bundled one into your file, Delete asks before removing yours (see *Snippets*)
- Save as snippet (Ctrl+Alt+S) — a bottom panel with Name, Folder, Trigger, Language and Notes rows (Tab moves between them, Enter saves, Escape cancels) saves the selection to `extensions/my-snippets.lua` and registers it at once (see *Snippets*)
- Auto-save (off by default — `zide.set("auto_save", true)` or the Settings dialog; saves dirty documents with file paths after a configurable interval, default 5s; continues while the TUI is idle)
- Application icon embedded in exe
- Multiple cursor editing (Ctrl+Shift or Ctrl+Alt+Up/Down, Ctrl+D, Alt+click, Escape/click to clear; an added cursor keeps its column for the next Up/Down)
- Theme system: 3 built-in themes (dark, light, high-contrast)
  - "terminal" mode (default): uses ANSI indices, respects terminal color scheme
  - Named themes use direct RGB colors for a consistent look
  - Custom overrides via `~/.config/zide/themes/tui-theme.lua` (auto-created with commented defaults on first run)
  - 34 named TUI color fields across editor, gutter and wrap/tilde markers, tab bar, status bar, Git status, review reader rows (`tui_color_review_added_bg`, `tui_color_review_modified_bg`, `tui_color_review_ghost_bg`, `tui_color_review_ghost_fg`, `tui_color_review_marker_fg`), and overlay panels — the auto-created tui-theme.lua template lists them (the four `tui_color_git_*` fields are described under *File Tree → Git status colors*)

### TUI — Not Yet Implemented
- Bracketed paste on Windows: vaxis's Windows reader forwards no paste markers, so a paste made by the terminal arrives as typed keys
- Terminal scrollback (the emulator keeps no scrolled-off rows — the GUI shares this gap)

Cross-frontend gaps are tracked in [TODO.md](TODO.md) (verified backlog: navigation back/forward, code folding, matching-bracket highlight, LSP references/signature help/symbols, regex search, Open Folder dialog and recent projects, dockable/multiple terminals, and more).

---

## GUI Frontend

### GUI — Implemented Features

- DVUI + SDL3 window with editor pane
- Text editing through the shared editor commands — undo/redo, clipboard, word motion, indentation and auto-indent behave as described under *TUI — Implemented Features*
- Keyboard focus follows the core rule (see *Keyboard focus* under Command System): clicking an editor or terminal pane takes the keyboard back from the file tree, the Snippets panel, the search panel or the terminal panel, and an editor pane that becomes the owner (Escape out of a panel, Ctrl+backtick, F6, a split, startup) takes input focus by itself — no click needed before typing
- Terminal panel (Ctrl+Shift+`, View > Terminal Panel): one shell docked at the bottom, left or right edge of the main window, inward of the file tree and Snippets bands; a header that turns bold while it has the keyboard, the shell's grid under it; drag its editor-facing edge to resize or hide it; right-click for Move to Left / Right / Bottom, Undock into a Split, Hide Panel and Close Terminal; View > Dock Terminal in Panel moves the focused terminal pane into it — see *The terminal panel* under Embedded Terminal
- Syntax highlighting (Zig built-in, extensible via Lua — see Syntax Highlighting section)
- Matching-bracket highlight (an outline in the caret color around the bracket at the caret and its partner) and smart Enter between bracket pairs — as described under *TUI — Implemented Features*
- TODO comment highlighting: `TODO`/`FIXME`/`XXX`/`HACK`/`BUG`/`NOTE` inside comments get the `todo` syntax color; `next_todo` command (palette) jumps to the next marker with wrap-around
- Markdown highlighting (built-in for `.md`/`.markdown`): headings, bold/italic, inline code and ``` fences, links/images/autolinks, list bullets + task checkboxes, blockquotes, tables, strikethrough, HTML comments (TODO markers inside get the `todo` color)
- Markdown editing: Enter continues list/quote markers (`- `, `1. ` with auto-increment, `> `, `- [ ] `); Enter on an empty item ends the list; `toggle_checkbox` palette command flips `[ ]`/`[x]` (bundled `extensions/markdown.lua`)
- Word wrap (word-boundary aware, configurable, wrap continuation markers); Up/Down move by visual rows and keep their column through shorter lines
- Save / Save As (native OS file dialog)
- External change detection (same behavior as the TUI): clean buffers auto-reload when the file changes on disk; dirty buffers get a `[O]verwrite [R]eload [C]ancel` prompt on save; auto-save never clobbers an external change
- Open file (native OS file dialog — also from the `file_open` palette entry or `zide.exec("file_open")`)
- Multi-document tabs (tab bar with close buttons)
- New document (Ctrl+N)
- Tab switching: Ctrl+Tab / Ctrl+Shift+Tab (hard-wired — active even during prompts, not remappable in the GUI), Ctrl+PageDown / Ctrl+PageUp, and View > Next/Prev Tab
- Status bar (filename, dirty marker, Ln/Col, detected language)
- Line numbers with active line highlight in gutter
- Go to line (Ctrl+G, overlay input; drops secondary cursors and the selection)
- Find with incremental search, wrap-around, and status feedback (Ctrl+F)
- Find and Replace (Ctrl+H, Tab to switch fields, Enter for next — in the Replace field it replaces the current match and then finds the next; Ctrl+A or Ctrl+Enter replace all, shows count)
- Command palette (Ctrl+P): letters match in order, case does not matter, a space stands for an underscore; Tab completes the highlighted command, arrows move the highlight, Enter runs it
- Navigation history: Ctrl+Alt+Left / Ctrl+Alt+Right (or F7 / Shift+F7) go back / forward through jumps — same behavior as the TUI (see its Navigation list)
- Quick open (Ctrl+E): fuzzy file finder with live preview behind a bottom-anchored panel — same behavior as the TUI (Enter opens a normal tab, Escape restores; previews never appear in the tab bar; clicking the menu bar or the tab bar closes quick open first); PageUp/PageDown and the mouse wheel scroll the preview
- Workspace search & replace (Ctrl+Shift+F): same engine and behavior as the TUI, with a VS Code-style panel — bordered input boxes with placeholders, clickable `Aa`/`W` toggle chips inside the search box (toggling re-runs the search), results **grouped under file headers** (collapse chevron + type icon + name + directory + match count — click a header to fold/unfold its file; the current file's header stays **pinned at the top** while its matches scroll, VS Code-style) with the match **highlighted inside each excerpt** and long excerpts ellipsis-windowed around the match; click fields to focus, double-click a result to open it, wheel scrolls, F4/Shift+F4 cycle results while editing
- Keybinding remapping (Lua integration — `zide.bind`/`zide.unbind` via init.lua, global or per-language with `{ language = "zig" }`)
- Snippets side panel (Ctrl+Alt+B, View > Snippets): the document language's snippets in collapsible groups by plain name, a preview with notes at the bottom (it takes the room a short list leaves free; notes that still do not fit scroll with the wheel or its scrollbar), click or Enter inserts at the caret and hands the keyboard back so Tab walks the blanks (with `snippets_double_click` a click selects and a double-click inserts); its own side (default: opposite the file tree) and drag-resizable width — drag the edge well past the minimum to hide it; right-click moves it, or edits, deletes or copies the snippet under the pointer (also F2 / Delete), and typing into the box under the header filters the list — see *Snippets*
- Save as snippet (Ctrl+Alt+S, Edit > Save Selection as Snippet…, the editor's right-click menu): a dialog with Name, Folder, Trigger, Language, Notes and an editable Body (add blanks like `${1:text}` right there) saves the selection to `extensions/my-snippets.lua` and registers it at once — see *Snippets*
- Auto-save (off by default; saves dirty documents with file paths after a configurable interval, default 5s)
- Application icon embedded in exe
- SDL3GPU backend (GPU-accelerated rendering, opt-in via `zig build -Dgpu=true`, default SDL3 for lower memory)
- Find/Replace match count display (shows "N matches" for the active document in overlay bar)
- Command palette arrow cycling with highlighted selection and Tab completion (Enter executes the highlighted command; the GUI shows and cycles only the first 10 matches, without wrapping — type to narrow; the TUI list scrolls); the chosen command runs at the end of the frame, after every pane has drawn, so a Lua command that splits or closes panes is safe from the palette
- Configurable line number gutter width (`zide.set("gutter_min_digits", N)` in init.lua, default 3 — the TUI honors it too)
- Mouse selection: double-click selects word (non-ASCII words like `café` included), triple-click selects line, drag extends by word/line accordingly, Shift+click extends selection, Alt+click adds cursor, Shift+Alt+drag for block (column) selection (one cursor per line over the dragged column span)

- File tree side panel (Ctrl+B) — dockable left/right, VS Code-style rows (type icons, chevrons, hover, scrollbar, git badges), inline create/rename, `/` search, auto-reveal, multi-select with bulk delete/move, file cut/copy/paste, Explorer drag-in, clickable delete dialog, header buttons, context menu incl. copy path + reveal in Explorer (see File Tree section)
- Settings dialog (Preferences menu — modal DVUI floating window with native widgets: checkboxes for booleans, validated numeric entries with min/max, dropdowns for theme, file tree side and renderer — the Renderer choice (Automatic / Hardware accelerated / Software) applies after a restart, is stored in `renderer.json` beside init.lua rather than as a `zide.set` key, is hidden in the `-Dgpu` build, and can be overridden for one launch with `--renderer=auto|hardware|software`; draggable by header, auto-centered, dims the background; changes apply live and write to init.lua immediately (File Tree Root as an escaped Lua string, so Windows backslash paths round-trip; a value that cannot be saved is reported in the status bar instead of breaking init.lua); close via header X or Escape; Tab/Shift+Tab cycles controls; it edits the global defaults — per-language overrides live in init.lua via `zide.set_language`)
- Open Settings File (Preferences menu — opens init.lua directly in the editor for power users)
- Tab character display (expands `\t` to spaces for rendering, cursor, selection, and wrapping)
- A selection that continues past a line end is highlighted to the edge of the text area, blank lines included
- Text that is not valid UTF-8 (a malformed buffer, odd bytes or columns from an extension) is drawn with `?` placeholders, one per byte, instead of crashing
- Blinking caret (530ms on / 530ms off, resets on cursor movement) — drawn in the theme's `cursor` color (override via `zide.set("color_cursor", "#hex")`) so it stands out from selection highlights; secondary multi-cursor carets use the same color and do not blink
- Multiple cursor editing (Ctrl+Shift or Ctrl+Alt+Up/Down, Ctrl+D, Alt+click, Escape/click to clear; an added cursor keeps its column for the next Up/Down and always lands on a character boundary)
- Split panes: vertical (Alt+\) and horizontal (Alt+Shift+\) splits with draggable dividers
  - Binary layout tree — nested splits supported (split a split)
  - Click to focus pane, focused pane highlighted with border
  - Close pane (Ctrl+Alt+Q), navigate via Alt+Left/Right, F6/Shift+F6 or the palette (`focus_next_pane`, `focus_prev_pane`). Closing a pane — a terminal pane too, or moving a pane to a new window — focuses its neighbour, the first pane of the sibling split
  - Each pane shows its own document independently, keyboard input goes to focused pane only
  - Modal overlays (find/replace, palette, etc.) render in focused pane (with a terminal pane focused they render over the whole editor area instead)
  - Split/close commands in the View menu and palette; focus-next/prev only via keys or the palette
- Multiple OS windows (View menu, command palette, Ctrl+Shift+N)
  - `open_in_new_window` moves the current document into a new window — its tab goes with it and the source pane switches to the neighbouring tab (the main window gets a fresh untitled document when that was its last tab); `move_pane_to_new_window` moves the focused pane there the same way — a terminal is never shown twice, so a lone terminal pane leaves a fresh untitled document behind in the main window, and an extra window that loses its only pane closes; `detach_terminal` (Ctrl+Alt+`) is the terminal-pane shortcut for that move
  - Every window has its own split tree and focused pane; the window with OS keyboard focus is the active one (clicking a window's title bar is enough). Keys, IME and modal prompts follow the active pane; switching windows cancels transient input (finder, palette, find bar) and prompts that would otherwise be left stuck — a rename preview (the server gets `applied: false`), a Git stage prompt, a task save-before-run prompt; pending save and encoding decisions follow focus while retaining their original document; the Settings dialog instead stays in the window it was opened from while the other windows keep working
  - Each window owns its tabs: a document is listed in exactly one window. Files you open or create join the window you are working in, Ctrl+Tab / Ctrl+Shift+Tab cycle that window's tabs, and showing a document in another window (tab drop, Open in New Window, a file-tree double-click while that window is active) moves its tab there. Closing the last tab of an extra window closes the window; the main window gets a fresh untitled document instead. The status bar shows that window's document (`Terminal` for a terminal pane)
  - Drag a tab out of the tab bar to move that document into a new window under the pointer; drop it on another ZIDE window to move it there; release anywhere on the same window or press Escape to cancel. Right-click a tab → Move to New Window / Close Tab (a tab with unsaved changes asks first). The main window hides its tab bar with a single document — use Ctrl+Shift+N there; extra windows always show the bar so a tab can be dragged back. Wayland has no global pointer position: the drop always opens a new window where the compositor puts it
  - The file tree and the search panel live in the main window only — Ctrl+B and Ctrl+Shift+F bring the main window forward (Reveal in Tree run from an extra window's View menu or the palette currently does not raise it)
  - `secondary_window_chrome` (Settings dialog / init.lua, default true): menu bar + status bar in extra windows; false = bare pane containers
  - Closing an extra window (OS close button, `close_window`, closing its last pane or tab) closes only its views — its tabs return to the main window and the documents stay open; a terminal shown only there is stopped. Closing the main window, File > Exit and Ctrl+Q all go through the unsaved-changes prompt
  - Up to 4 extra windows (dvui's SDL window limit); a 5th is refused with a status message
  - Needs the SDL3 renderer backend (the default build) — the `-Dgpu` build has no child windows and the commands split instead, as in the TUI. The vendored dvui carries ZIDE patches — the multi-window set (drop hook window id, child teardown order, cursor ownership, per-window modifier state synced from SDL each frame, the focus-click-through hint, a window-count leak fix) plus unrelated fixes (MinGW fortify, IME length, format logging); grep `ZIDE patch` in `libs/dvui` (11 markers at last count) and re-apply all of them after refreshing the snapshot
- Theme system: 3 built-in themes (dark, light, high-contrast) with custom DVUI themes
  - `zide.set("theme", "dark")` / `"light"` / `"high_contrast"` — switch preset
  - `zide.set("color_*", "#RRGGBB")` or `"#RRGGBBAA"` — override individual colors
  - Custom overrides via `~/.config/zide/themes/gui-theme.lua`
  - 28 named editor color fields: text, selection, cursor, gutter_bg, gutter_text, gutter_text_active, gutter_separator, wrap_marker, tilde, overlay_bg, overlay_fg, overlay_dim, overlay_warn, overlay_selection, overlay_hint, bool_true, bool_false (both currently unused by any renderer), status_bg, status_fg, plus git_added, git_modified, git_deleted, git_untracked (see *File Tree → Git status colors*) and review_added_bg, review_modified_bg, review_ghost_bg, review_ghost_fg, review_marker_fg (see *Reading a change*)
  - Any `color_*` override makes the active theme `"custom"`: `zide.get("theme")` reports that, the Settings dropdown shows "dark", and the GUI chrome (menus, tabs) falls back to the dark style. Theme switches re-apply only the syntax override files — `gui-theme.lua` / `tui-theme.lua` overrides return at the next launch
- Menu bar reorganized:
  - File: New, Open File, Open Folder, Recent Projects (submenu), Save, Save As, Close Tab, Reopen Closed Tab, Exit
  - Edit: Undo, Redo, Cut, Copy, Paste, Select All, Toggle Comment, Find, Replace, Go to Line
  - View: Command Palette, File Tree, Reveal in Tree, Next Tab, Prev Tab, Split Vertical, Split Horizontal, Close Pane, Open in New Window, Move Pane to New Window, Close Window, Detach Terminal
  - Preferences: Settings, Open Settings File, Theme > (Dark / Light / High Contrast), Open Theme File, Open Theme Folder
  - Help: Documentation, About ZIDE
- Theme switcher: Preferences > Theme submenu switches themes live (updates editor + DVUI chrome, persists to init.lua)
- Theme setting in Settings dialog: dropdown (dark/light/high_contrast)
- Open Theme File: opens `~/.config/zide/themes/gui-theme.lua` in the editor (the commented template with per-field descriptions is created at startup when missing — the menu action itself only opens the file)
- Open Theme Folder: opens `~/.config/zide/themes/` in OS file explorer
- Help > Documentation: opens `docs/Documentation.md` in the editor (looks for `docs/Documentation.md`, then a root-level `Documentation.md` from older checkouts, in the exe's directory and its ancestors — works from `zig-out/bin` and desktop launches — and finally in the current directory; also available as the `open_documentation` palette command in both frontends)
- Editor pane scrollbar: slim pill overlay on the right edge (same style as the file tree) — drag the thumb, click the band to page up/down, hover brightens; per split pane
- Mouse wheel scrolls 3 lines per notch (editor panes, the quick-open preview and the search panel; the TUI scrolls 5)
- Tab bar styling: inactive tabs have visible borders and control-style background
- Right-click context menu in editor panes: Cut, Copy, Paste, Select All, Go to Definition
  - Right-click outside the selection moves the cursor to the click point first; inside the selection it keeps the selection (so Cut/Copy act on it)

### GUI — Not Yet Implemented
- Terminal scrollback (the emulator keeps no scrolled-off rows; the TUI shares this)
- Terminal selection and copy/paste (Ctrl+Shift+C / Ctrl+Shift+V currently reach the shell as ^C/^V)

Cross-frontend gaps are tracked in [TODO.md](TODO.md).

---

## Syntax Highlighting

### Overview

ZIDE uses an **extension-first** architecture for syntax highlighting. Language definitions are data — loaded from Lua files at startup — not hardcoded into the binary. Only **Zig** and **Markdown** are built-in (it's a Zig IDE, and its docs are markdown). Users install extensions for other languages by placing Lua files in `~/.config/zide/extensions/`.

Markdown is the one exception to the data-driven model: its grammar is structural (headings, fences, emphasis), not keyword-based, so it has a dedicated native tokenizer (`tokenizer = .markdown` on the language def) instead of a `zide.register_language` table. It still uses the same span/color pipeline and theme overrides as every other language.

### How It Works

1. **Startup**: ZIDE scans `~/.config/zide/extensions/*.lua` and executes each file. Extensions call `zide.register_language({...})` to register language definitions. Registering a **name that already exists** (case-insensitive, including the built-in `zig` and `markdown`) **replaces** that definition in place — it is a full replacement, so restate every field you want to keep (and `tokenizer = "markdown"` when tweaking markdown); open files pick up the new tables immediately.
2. **File open**: Language is detected from the file extension (e.g., `.zig` → Zig, `.py` → Python if registered). When two definitions claim the same extension the **most recently registered wins**, so an extension can take over `.zig` or `.md` from the built-ins. The language is re-detected after a rename in the file tree, after Save As, and after `reload_extensions`.
3. **Rendering**: Each visible line is tokenized into spans (keyword, string, comment, etc.), and each span is rendered with its color from the active syntax theme.

### Token Types

The tokenizer produces spans with one of these token types:

| Token | Description | Default Color (Dark) |
|-------|-------------|---------------------|
| `keyword` | Language keywords (`fn`, `if`, `while`, etc.) | Purple `#c678dd` |
| `type_name` | Type identifiers (`u8`, `bool`, etc.) | Teal `#56b6c2` |
| `string` | String literals | Green `#98c379` |
| `char_literal` | Character literals | Green `#98c379` |
| `number` | Numeric literals | Orange `#d19a66` |
| `comment` | Line and block comments | Gray `#5c6370` |
| `function` | Function names (identifier before `(`) | Blue `#61afef` |
| `builtin` | Built-in functions (`@import`, etc.) | Gold `#e5c07b` |
| `constant` | Named constants (`null`, `true`, etc.) | Orange `#d19a66` |
| `operator` | Operators (`+`, `=`, `>>`, etc.) | Text color |
| `punctuation` | Brackets, braces, semicolons | Light gray `#abb2bf` |
| `preprocessor` | Preprocessor directives (`#include`, etc.) | Light purple `#be84d2` |
| `attribute` | Attributes/decorators | Gold `#e5c07b` |
| `todo` | `TODO`/`FIXME`/`XXX`/`HACK`/`BUG`/`NOTE` markers inside comments (word-boundary matched) | Gold `#e5c07b` |
| `heading` | Markdown heading lines (`# ...`) — bold in the TUI | Soft red `#e06c75` |
| `strong` | Markdown bold (`**...**`) — bold in the TUI | Orange `#d19a66` |
| `emphasis` | Markdown italic (`*...*`) — italic in the TUI | Purple `#c678dd` |
| `link` | Markdown link/image text and autolinks — underlined in the TUI (the `(url)` part renders dim as `comment`) | Blue `#61afef` |
| `text` | Plain text / identifiers | Default text color |

### Syntax Themes

Syntax colors are **separate from the editor theme** — they have their own files and presets.

**Resolution order** (later overrides earlier):
1. **Built-in preset** — matches the active editor theme (dark, light, high-contrast)
2. **Global syntax theme** — `~/.config/zide/themes/syntax-theme.lua`
3. **Per-language syntax theme** — `~/.config/zide/themes/syn_theme_<lang>.lua`

#### Global Syntax Theme

File: `~/.config/zide/themes/syntax-theme.lua` (auto-created with commented template on first run)

```lua
-- Override syntax colors for all languages
zide.set("syn_keyword", "#c678dd")
zide.set("syn_comment", "#5c6370")
zide.set("syn_string", "#98c379")
zide.set("syn_number", "#d19a66")
zide.set("syn_function", "#61afef")
zide.set("syn_type_name", "#56b6c2")
zide.set("syn_builtin", "#e5c07b")
zide.set("syn_constant", "#d19a66")
zide.set("syn_operator", "#e1e1e6")
zide.set("syn_punctuation", "#abb2bf")
zide.set("syn_preprocessor", "#be84d2")
zide.set("syn_attribute", "#e5c07b")
zide.set("syn_char_literal", "#98c379")
zide.set("syn_todo", "#e5c07b")
zide.set("syn_heading", "#e06c75")
zide.set("syn_strong", "#d19a66")
zide.set("syn_emphasis", "#c678dd")
zide.set("syn_link", "#61afef")
```

For TUI-only overrides, use the `tui_syn_*` prefix (e.g., `tui_syn_keyword`).

#### Per-Language Syntax Theme

File: `~/.config/zide/themes/syn_theme_<lang>.lua` (e.g., `syn_theme_zig.lua`)

```lua
-- Override specific colors for Zig only
zide.set("syn_builtin", "#e5c07b")    -- @builtins in gold
zide.set("syn_attribute", "#d19a66")  -- comptime attrs in orange
```

`<lang>` is matched against the registered language `name`
**case-insensitively** — `syn_theme_python.lua` applies to a language
registered as `"Python"`. Colors set inside these files only affect that
language, and each file overrides only the colors it sets — everything else
follows the global syntax theme, also after a theme switch. `tui_syn_*` keys
work here too for TUI-only per-language overrides.

#### Built-in Presets

Syntax theme presets automatically match when you switch editor themes; the `theme_*`, `gui_theme_*` and `tui_theme_*` commands then re-apply `syntax-theme.lua` and every `syn_theme_<lang>.lua` on top of the new preset:

| Editor Theme | GUI Syntax Preset | TUI Syntax Preset |
|-------------|-------------------|-------------------|
| dark | One Dark inspired | ANSI terminal colors |
| light | One Light inspired | ANSI-256 colors |
| high_contrast | High contrast | Direct RGB |
| terminal | — | ANSI terminal colors |

### Extension System

#### Writing a Language Extension

Create a `.lua` file in `~/.config/zide/extensions/` (e.g., `python.lua`):

```lua
zide.register_language({
    name = "Python",
    extensions = { "py", "pyw" },
    keywords = {
        "def", "class", "if", "elif", "else", "for", "while",
        "return", "import", "from", "as", "try", "except",
        "finally", "with", "yield", "lambda", "pass", "break",
        "continue", "raise", "in", "not", "and", "or", "is",
        "global", "nonlocal", "assert", "del", "async", "await",
    },
    types = { "int", "float", "str", "bool", "list", "dict", "tuple", "set", "None" },
    constants = { "True", "False", "None" },
    builtins = { "print", "len", "range", "type", "isinstance", "open" },
    line_comment = "#",
    -- block_comment_start = nil,  -- Python has no block comments
    -- block_comment_end = nil,
    string_delimiters = "\"'",
    has_char_literals = false,
    -- builtin_prefix = nil,       -- no @ prefix for builtins
    -- preproc_prefix = nil,       -- no preprocessor
})
```

#### `zide.register_language()` Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Language display name (valid UTF-8) |
| `extensions` | string[] | no | File extensions (without dot; default empty — the language is then never auto-detected) |
| `keywords` | string[] | no | Language keywords (default: empty) |
| `types` | string[] | no | Type names (default: empty) |
| `constants` | string[] | no | Named constants (default: empty) |
| `builtins` | string[] | no | Built-in functions (default: empty) |
| `line_comment` | string | no | Line comment prefix (e.g., `"//"`) |
| `block_comment_start` | string | no | Block comment start (e.g., `"/*"`). May begin with `line_comment` — Lua `--[[`, Julia `#=`, Nim `#[` — and then wins over it |
| `block_comment_end` | string | no | Block comment end (e.g., `"*/"`) |
| `string_delimiters` | string | no | Characters that start strings (default: `"\""`) |
| `has_char_literals` | bool | no | Whether `'x'` is a char literal (default: false) |
| `builtin_prefix` | string | no | Single character prefix for builtins (e.g., `"@"` for Zig) |
| `preproc_prefix` | string | no | Single character prefix for preprocessor (e.g., `"#"` for C) |
| `tokenizer` | string | no | `"generic"` (default: the table-driven tokenizer above) or `"markdown"` (the structural native tokenizer; the tables are then unused). Needed when re-registering `markdown` — a replacement without it degrades to generic (logged as a warning) |

The per-language keys `tab_width`, `use_tabs`, `word_wrap` and `auto_close_brackets` (number / bool) may also be passed inline — sugar for `zide.set_language(name, {...})` below. Only `name` is truly required: it must be non-empty valid UTF-8, and registration returns nothing — errors go to zide.log only. An empty-string field counts as absent, and an unknown `tokenizer` falls back to generic with a warning.

Re-registering a `name` replaces the existing definition in place (see *How It Works*); ZIDE
logs `Re-registered language: <name>`. Definitions are never removed at runtime — a language
whose extension file was deleted lingers until the next launch.

#### Per-language settings

`tab_width`, `use_tabs`, `word_wrap` and `auto_close_brackets` are global defaults; any
language can override them, neovim `ftplugin`-style, without touching the others:

```lua
zide.set("tab_width", 4)                                          -- the default
zide.set_language("javascript", { tab_width = 2 })                -- JS files indent by 2
zide.set_language("markdown", { auto_close_brackets = false, word_wrap = true })
zide.register_language({ name = "yaml", extensions = {"yml", "yaml"}, keywords = {}, tab_width = 2 })  -- same keys inline
print(zide.get_language("markdown").word_wrap)                    -- true; nil when nothing is overridden
```

Overrides merge (only the keys you pass change), match the language name case-insensitively,
and may be set before the language is registered — or for a built-in. `zide.language()` tells
an extension which language the active file has. The Settings dialog edits the global
defaults only.

Precedence for indentation is EditorConfig (when enabled) → the per-language override → the
global default; `word_wrap` and `auto_close_brackets` have no EditorConfig layer. A
`tab_width` outside 1–16 or a wrongly-typed value (`use_tabs = 1`) is ignored with a warning,
language names over 64 bytes get no profile, and overrides are never cleared by
`reload_extensions` — they live until shutdown.

#### Extension Runtime API

Extensions are not limited to language definitions — any `.lua` file in
`~/.config/zide/extensions/` can register commands and react to editor
events. Every callback runs in a protected call: a broken extension shows
`Extension error: …` in the status bar (details in the log) and the editor
keeps running. A file that fails to load — `init.lua`, a theme file or an
extension — shows its Lua error in the status bar (`init.lua:3: <message>`)
at startup and after `reload_extensions`, not only in the log. Config files
load from non-ASCII profile paths on Windows; `io.open` and `require` inside
a script still go through the C runtime, which cannot open such paths (that
would need an app manifest). Option tables passed to `register_language`,
`register_lsp`, `set_language`, `register_task`, `register_debug_adapter` /
`register_debug_config`, `register_snippet`, `set_diagnostics`, `on`, `bind` and `unbind` are read raw:
metatables and `__index` are ignored.

```lua
-- A command: appears in the command palette (Ctrl+P) and is bindable.
zide.command("insert_date", "Insert today's date", function()
    zide.status("It is " .. os.date("%Y-%m-%d"))
end)

-- Bind it like any built-in (init.lua or here):
zide.bind("ctrl+shift+d", "insert_date")

-- React to editor events. The handler gets the file path (nil = untitled)
-- and the document's language name (nil = plain text).
zide.on("save", function(path, language)
    zide.status("Saved: " .. (path or "untitled") .. " [" .. (language or "text") .. "]")
end)

-- Only for one language (neovim ftplugin-style):
zide.on("save", function(path) zide.status("zig file saved") end, { language = "zig" })
```

| Call | Description |
|------|-------------|
| `zide.command(name, desc, fn)` | Register a command — listed in the palette, runnable via `zide.bind`/`zide.exec`. `name` must be valid UTF-8. Re-registering a name replaces it; shadowing a built-in is allowed (logged). `fn` receives the optional args string (usually nil). |
| `zide.register_snippet{...}` | Register a snippet for the Snippets panel and the palette, Tab-expandable when it has a `prefix` — see the *Snippets* section. Returns the command name (`snippet.<language>.<prefix>`, or `snippet.<language>.~<slug>` for one without a prefix), or `nil, message`; it never raises. |
| `zide.on(event, fn [, opts])` | Hook an event. Events: `"open"` (file opened into a tab), `"save"` (file written — fires per document on auto-save too). `fn(path, language)` gets the file path (or nil) and the document's language name (or nil for plain text); handlers that only declare `path` keep working. `opts.language = "zig"` fires the handler only for documents of that language (case-insensitive). Nested event firing is capped at 8 levels. |
| `zide.exec(name)` → bool | Run any action or command by name — the same names keybinds use (`"save"`, `"undo"`, `"toggle_filetree"`, other Lua commands, …). Returns whether the name was recognized. |
| `zide.status(msg)` | Show a transient message in the status bar (both frontends): at most 128 bytes, cut at a character boundary; malformed bytes show as U+FFFD, control characters as spaces. |

In the GUI, a command chosen in the palette (like a terminal pane's pass-through chord) runs at the end of the frame, after every pane has drawn, so a Lua command that splits or closes panes is safe there. `open` and `save` handlers that fire from inside a pane — a quick-open commit, Save in the close-tab prompt — must still not split or close panes.

**Buffer API** — all calls act on the active document; lines are **1-based**
and columns are **1-based byte columns** (`é` spans two), and a column inside
a character snaps to that character's start. Mutations go through the editor's
normal document operations, so undo (Ctrl+Z) and LSP sync behave exactly as if
typed.

| Call | Description |
|------|-------------|
| `zide.line_count()` → int | Number of lines. |
| `zide.get_line(n)` → string\|nil | Line `n` without its newline; nil out of range. |
| `zide.get_text()` → string | The whole buffer. |
| `zide.cursor()` → line, col | Primary cursor position (two return values). |
| `zide.set_cursor(line [, col])` | Move the primary cursor (`col` defaults to 1; clamped to valid positions, snapped to a character start); drops secondary cursors and selection. |
| `zide.file_path()` → string\|nil | The document's path on disk (nil = untitled). |
| `zide.language()` → string\|nil | Detected language name (e.g. `"Zig"`). |
| `zide.selection()` → string\|nil | Selected text of the primary cursor. |
| `zide.insert(text)` → true\|nil, err | Insert at the primary cursor; an active selection is replaced (one undo step) — this doubles as "replace selection". Returns `true`, or `nil, err` (`"invalid UTF-8"`, …) without changing anything. |
| `zide.set_line(n, text)` → true\|nil, err | Replace line `n`'s content (one undo step). Carets and selection ends on that line keep their byte column (clamped to the new text); secondary cursors stay. Returns `true`, or `nil, err` (`"line out of range"`, `"invalid UTF-8"`, …) without changing anything. |

```lua
-- Example: a "duplicate line upper-cased" command
zide.command("dup_line_upper", "Duplicate line in caps", function()
    local line = zide.cursor()
    local text = zide.get_line(line)
    if text then zide.set_line(line, text .. "\n" .. text:upper()) end
end)
```

**Running external tools** — both calls produce a result table
`{ code = exit_code, stdout = "...", stderr = "...", error = "ErrName" }`
(`code` is absent if the tool didn't exit normally; `error` is set when the
run itself failed — tool not found, timeout, …). Both run the tool in its own
process group (a job object on Windows) without a console window. Output is
capped at 4 MiB + 256 KiB, stdout and stderr together: `zide.run` drops the
excess, while a `zide.spawn` run that exceeds it fails with `error` set.

| Call | Description |
|------|-------------|
| `zide.run(argv [, timeout_ms])` → table\|nil, err | Run a tool and **block until it exits** (the UI freezes meanwhile — fast tools only). `argv` is a list, e.g. `{"git", "status"}`. `timeout_ms` is a total deadline in milliseconds (clamped to 0 … 2^40, fractions floored; nil = none): when it passes, the tool and every process it started are killed and `nil, "Timeout"` returns. |
| `zide.spawn(argv, fn(result))` | Run on a background thread; the callback fires on the editor loop when the tool finishes. Use this for linters, builds, anything slow. A tool that cannot start still calls back immediately, with `error` set. |

```lua
-- Example: branch name in the status bar on every save
zide.on("save", function()
    zide.spawn({"git", "rev-parse", "--abbrev-ref", "HEAD"}, function(r)
        if r.code == 0 then zide.status("saved on " .. r.stdout:gsub("%s+$", "")) end
    end)
end)
```

**Diagnostics** — extensions can put their own findings in the gutter,
underline the text, and show messages in the status bar, rendered exactly
like LSP diagnostics (and kept separately, so LSP updates never wipe them):

| Call | Description |
|------|-------------|
| `zide.set_diagnostics(path, list [, source])` | Replace the diagnostics carrying the given `source` for the file at `path` (separator/case-insensitive match) — `source` defaults to `"lint"`, so two linters with different sources never wipe each other, and the source shows in Problems rows (where the S key cycles it); findings for a file that isn't open are kept and shown when it opens. Pass `{}` to clear. Each entry: `{ line = N, col = N, end_col = N, severity = "error"\|"warning"\|"info"\|"hint", message = "…" }` — `line` is 1-based and the only required field; `col`/`end_col` are 1-based byte columns (default `col` 1; the default end covers one character), snapped to character starts. An entry whose `line` is outside 1 … 2^32 − 1 is dropped, huge columns saturate, and at most 10,000 entries per call are kept (a warning is logged), and the shared Problems store caps at 50,000 findings — a call that would exceed it is dropped silently and the old findings stay. Severity defaults to `"error"`. Positions go stale as the user edits, exactly like LSP — the next run replaces them. |

Lint diagnostics are cleared by `reload_extensions` (a removed linter's
stale squiggles don't survive).

#### File Tree Icons

| Call | Description |
|------|-------------|
| `zide.set_icon(key, kind [, color])` | Override a file tree icon. `key` is an extension (`"zig"`) or an exact basename (`"Makefile"`, `"src"` — works for folders), matched case-insensitively; basename beats extension. `kind` is one of: `folder`, `code`, `text`, `book`, `license`, `config`, `data`, `image`, `audio`, `video`, `archive`, `binary`, `executable`, `git`, `lock`, `font_file`, `generic` (picks the glyph in both frontends). `color` is `"#rrggbb"`; omit it to use the theme's text color. Overrides replace on re-registration, so `reload_extensions` picks up edits. |

#### The Shipped Example: example-lint-zig.lua

On first launch ZIDE creates `~/.config/zide/extensions/example-lint-zig.lua`
— a complete on-save linter for Zig (`zig ast-check`), **fully commented out**
so nothing runs subprocesses without your consent. Uncomment its body, run
`reload_extensions` from the palette, then save a `.zig` file containing a
mistake: the findings land in the gutter and status bar exactly like LSP
diagnostics, in both frontends. It's the recommended copy-paste starting
point for wiring up any other linter or tool: hook `"save"`, run the tool
with `zide.spawn`, parse its output, call `zide.set_diagnostics`.

#### The Shipped Extension: markdown.lua

On first launch ZIDE also creates `~/.config/zide/extensions/markdown.lua` —
**active** out of the box (unlike the lint example it's a pure buffer edit
with no side effects). It registers the `toggle_checkbox` palette command:
flip the first GFM task box on the cursor line between `[ ]` and `[x]`, one
undo step, cursor stays put. It's the smallest working demo of the buffer
API (`zide.cursor` / `zide.get_line` / `zide.set_line`) — copy it to build
your own line-editing commands. Edit it freely; it's only recreated if the
file is deleted.

#### The Shipped Extension: snippets-zig.lua

Also created on first launch — and, unlike the other two, re-created whenever it is
**missing**, at startup and on every `reload_extensions`: 54 Zig syntax skeletons for the
Snippets panel, filed in groups (Start here, Values, Functions, If & switch, Loops, Types,
Errors, Memory, Tests), each with plain-language notes, and seventeen of them with a Tab
trigger (`hello`, `fn`, `pfn`, `fnerr`, `if`, `ifelse`, `elif`, `switch`, `while`, `whilei`,
`for`, `fori`, `forr`, `struct`, `enum`, `errset`, `test`). Every body is compiled by the
real Zig compiler in the test suite (`zig build test -Dtest-tools`).

**Upgrades.** ZIDE replaces the installed file with the newest bundled set as long as it is
unchanged from a version ZIDE shipped (line endings do not count as a change); the moment you
edit it, it is yours and is never touched again — delete it to get the newest set back.
Deleting the file does not remove the snippets (it comes back); to disable them, empty the
file or comment out its contents instead. Edit it freely to tweak the bodies — the *Snippets*
section documents the template syntax and expansion rules. Because init.lua runs before
extensions, a snippet registered there with the same language and name is replaced by the
bundled one at the next load — change `snippets-zig.lua` itself instead.

The `reload_extensions` command (palette) drops all Lua-registered commands
and event handlers and re-runs every `extensions/*.lua` — edit-extension,
reload, retry without restarting ZIDE. (Lua globals your scripts set persist
across reloads; top-level state is re-initialized by your script itself.)
Lua commands can override built-in and snippet commands. Removing an override
reveals the underlying command again; the palette lists each name once.
Languages re-registered by the reload are replaced in place, and every open
document's language is re-detected afterwards, so a new extension→language
mapping applies to files that are already open.

#### Your snippets: my-snippets.lua

`~/.config/zide/extensions/my-snippets.lua` is created the first time you save a snippet from
the editor (Ctrl+Alt+S — see *Making your own* under Snippets). It is ordinary Lua: one
`zide.register_snippet({...})` call per snippet, each between a `-- zide:snippet <command>`
line and a `-- zide:end` line:

```lua
-- zide:snippet snippet.zig.~for-each-item
zide.register_snippet({
    language = "zig",
    description = "For each item",
    group = "Mine",
    prefix = "",
    notes = "Runs the body once per item.",
    body = [[
for (items) |item| {
    $0
}]],
})
-- zide:end
```

The panel rewrites only the text between a block's two marker lines (new blocks go at the
end); everything else in the file is left byte for byte, so you can add your own Lua above or
below the blocks or edit a block by hand (then run `reload_extensions`). Keep the marker lines
as they are — when Edit or Delete in the panel cannot find a block any more (its marker line
changed, or the file has two blocks for the same name), the panel says so and opens the file
instead of touching it. F2 on a bundled snippet copies it here, so you never edit the bundled
file itself.
Bodies are written as Lua long strings (`[[...]]`, or `[=[...]=]` when the body contains
`]]`), so nothing inside them needs escaping. The file runs **after every other extension
file**, whatever order the operating system lists them in, so a snippet saved here replaces a
bundled one with the same language and name, and a bundled-file upgrade cannot undo that.

#### Extension Directory

```
~/.config/zide/
├── init.lua                          # Main settings
├── extensions/                       # Language + runtime extensions
│   ├── example-lint-zig.lua          # Bundled on-save linter demo (commented out)
│   ├── markdown.lua                  # Bundled toggle_checkbox command
│   ├── snippets-zig.lua              # Bundled Zig snippets (updated until you edit it)
│   ├── my-snippets.lua               # Your saved snippets (the panel rewrites only its marked blocks)
│   ├── python.lua
│   ├── c.lua
│   └── ...
└── themes/
    ├── gui-theme.lua                 # GUI editor theme
    ├── tui-theme.lua                 # TUI editor theme
    ├── syntax-theme.lua              # Global syntax theme
    ├── syn_theme_zig.lua             # Zig-specific syntax overrides
    └── syn_theme_python.lua          # Python-specific syntax overrides
```

---

## LSP Support

### Overview

ZIDE has a built-in LSP (Language Server Protocol) client that talks to language servers over stdio JSON-RPC. It is **server-agnostic**: any language server you can install is wired up from Lua, neovim-style, and any number of them run at once — one process per registration, started **lazily** the first time a file of a language it serves is opened, stopped when ZIDE quits.

Out of the box exactly one registration exists: `zls` from PATH for Zig. Everything else is a `zide.register_lsp` call in `init.lua` or an extension. The shipped, fully commented `~/.config/zide/extensions/example-lsp-servers.lua` has copy-paste blocks for clangd (C/C++), rust-analyzer, typescript-language-server, the vscode JSON server, pyright and lua-language-server.

Documents are routed by **language name**: a document is synced to the server whose registration serves its detected language (the `name` from `zide.register_language`), so a `.txt` or `.md` buffer never reaches zls. The status bar shows each document's language and, once its server is up, the server's name: `Ln 1, Col 1 | c (clangd)` (or `plain text` when nothing matched). Beyond the lifecycle features below (diagnostics, completion, go-to-definition), the client also provides hover, rename with preview, document/selection formatting and format-on-save — see *Recovery, formatting, and language-server edits* at the top of this file.

### Registering a server

```lua
zide.register_lsp({
    language = "c",                                  -- or languages = {"c", "cpp"}: one server serves all of them
    command = {"clangd", "--background-index"},      -- table = argv; a plain string is the program only (never split on spaces)
    language_id = "c",                               -- optional; default = language name lowercased
    settings = { Lua = { diagnostics = { globals = {"zide"} } } },  -- optional; Lua table → JSON
    init_options = { check = { command = "clippy" } },              -- optional; → initializationOptions
})
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `language` / `languages` | string / string[] | one of them | Language name(s) as given to `zide.register_language` (case-insensitive). One registration can serve several languages with one process (clangd for `c` and `cpp`). |
| `command` | string or string[] | yes | The server program. A **string is argv[0] only** — paths with spaces work, nothing is split. A **table is the full argv**: `{"pyright-langserver", "--stdio"}`. Resolved on PATH; Windows npm `.cmd` shims work as-is (PowerShell-only `.ps1` shims don't). |
| `language_id` | string or table | no | The LSP `languageId` sent in `didOpen`. Default: the language name lowercased. A string is accepted only for a single-language registration; otherwise use `{ ["C++"] = "cpp" }`. |
| `settings` | table | no | Converted to JSON. Answers the server's `workspace/configuration` requests (dotted `section` lookup, e.g. `Lua.diagnostics`) and is pushed once via `workspace/didChangeConfiguration` after the handshake. |
| `init_options` | table | no | Converted to JSON and sent as `initializationOptions` (rust-analyzer and friends). |

JSON conversion: Lua arrays (keys 1..n) become JSON arrays, other tables become objects, integers stay integers, and an **empty table is `{}`** (an empty JSON array can't be expressed). Functions inside the table are skipped with a warning in the log.

Registration is not checked against the language registry — `init.lua` runs before extensions register their languages; resolution happens by name when a document opens. When several registrations serve the same language the **most recent wins**, so a `register_lsp` for `zig` in your config replaces the built-in `zls` entry (e.g. to pin a toolchain-matched binary). That holds even while an older server is running: documents opened afterwards go to the newest registration, while a document that is already open stays on the server that opened it until it is closed, that server restarts, or `reload_extensions` moves it.

### Lifecycle

- **Lazy start**: a server is spawned the first time a document of a language it serves is opened (or gains that language through a rename / Save As). Nothing runs for languages without an open file.
- **Workspace root**: the file tree root (`filetree_root`, canonicalized) is sent as `rootUri` / `rootPath` / `workspaceFolders`. rust-analyzer needs this to be the Cargo project. Re-rooting the tree later does not move running servers — run `lsp_restart`.
- **Status bar**: `LSP ready: clangd (c, cpp)` on handshake; `LSP for c: cannot start clangd (FileNotFound) — see zide.log` when the program is missing; `LSP clangd exited — run lsp_restart` when a server dies or rejects `initialize`. A failed registration is **not retried every frame** — it stays marked failed until `lsp_restart` or until `reload_extensions` replaces it.
- **`lsp_restart`** (palette): stops every server, forgets failures, and lets the lazy start bring servers back for the open documents.
- **`reload_extensions`**: registrations made by `extensions/*.lua` are dropped and re-created; a server whose registration is unchanged keeps running, changed or removed ones are stopped. A server outranked for only some of its languages keeps running, and its open documents of those languages move to the newer registration.
- **`lsp_enabled`** (`zide.set("lsp_enabled", false)` or the Settings dialog): no servers start and running ones stop on the next frame — takes effect immediately.
- **Quit**: every server gets `shutdown` + `exit`, up to a second to leave on its own, then is killed.
- Server→client requests are answered: `workspace/configuration` from `settings`, `workspace/workspaceFolders`, capability registrations and progress tokens with `null`, and `workspace/applyEdit` through the shared preview. Unsupported requests receive JSON-RPC MethodNotFound. `window/logMessage` / `window/showMessage` go to `zide.log` (server errors also to the status bar). The transport drains and bounds stderr; Windows servers start without a console window.

### Architecture

- **Managed protocol workers per server** read framed JSON-RPC messages, queue writes and drain adapter stderr off the editor thread. Both queues are bounded: a full outgoing queue fails the session, a full incoming queue pauses the reader until the editor catches up (back-pressure), and only an editor that stops taking messages for 30 seconds ends the session.
- **Main thread** (`Editor.lspTick`) sweeps dead servers, polls every queue each frame (GUI) or event loop iteration (TUI) — no blocking — then syncs documents. It handles up to 64 messages per client per tick; a bigger burst makes the loop run again immediately instead of sleeping. Work that must not run inside message dispatch — the goto-definition jump, the save after format-on-save — runs after polling
- **Full-text document sync** with version coalescing: rapid keystrokes are batched into a single `didChange` notification per frame. A document too large for one message (16 MiB) is not sent — the status bar says so once — and is measured again after the next edit
- In the TUI, reader threads wake the blocking event loop via `loop.postEvent(.lsp_data)`; a server's stdout closing wakes it too, so a crash is noticed without a keypress
- Each client owns a deep copy of its registration (`lsp.ServerConfig`). A document opens on the client of the newest registration serving its language, and `Editor.lsp_doc_owner` keeps it on that client until it closes, the server stops, or `reload_extensions` moves it; nothing is cached on language definitions
- Server URIs are decoded like VS Code's: `file:///c%3A/…` (a percent-encoded drive colon) works for diagnostics, goto-definition into closed files and renames across closed files

### Diagnostics

The LSP client receives `textDocument/publishDiagnostics` notifications and displays them in both frontends:

**GUI:**
- Colored dot in the gutter (red = error, yellow = warning, blue = info/hint)
- Colored underlines under diagnostic text ranges
- Diagnostic message in the status bar for the current cursor line

**TUI:**
- Colored `!` marker in the gutter
- Underline style applied to cells in diagnostic ranges
- Diagnostic message in the status bar for the current cursor line

Closing a document forgets its versioned LSP diagnostics, so a reopened file shows the server's findings immediately.

### Completion

The popup opens by itself while you type — after one of the server's trigger characters (`.` for zls) or an identifier character — and **Ctrl+Space** opens it on demand. It is filtered by the identifier typed so far (case-insensitive prefix on the label): typing more letters narrows the list without closing it and refreshes it from the server (the previous list stays visible until the reply, and cannot be accepted in that moment), a space or punctuation dismisses it, Escape closes it. `zide.set("completion_auto", false)` (or the Settings dialog) keeps it to Ctrl+Space only, and `completion_min_chars` (default 1, up to 8) is how many identifier characters you type before it opens by itself — raise it for languages with huge standard libraries; trigger characters open it regardless. Every reply is logged to zide.log as `completion: N items, M match the typed prefix`, which shows what the server offered versus what the filter kept.

**Navigation:**
- Up/Down arrows to select
- Enter or Tab to accept (replaces word prefix at cursor; Tab first serves an active snippet — field navigation or an exact trigger — see *Snippets*)
- Escape to dismiss
- Other keys dismiss the popup and pass through (identifier and trigger characters keep it, see above)

**Both GUI and TUI** render the popup next to the focused pane's caret with scrolling for long lists. Detail information (type signatures etc.) is shown dimmed next to labels. Both response shapes are accepted (`CompletionList` and a bare item array); when a server omits `insertText` the `textEdit.newText` is used.

### Go-to-Definition

Press **F12** to jump to the definition of the symbol under the cursor. If the definition is in the same file, the cursor jumps to that line. If it's in a different file, the file is opened in a new tab and the cursor moves to the definition. The target opens after the reply has been handled (outside message dispatch); one that fails to open shows `Go to definition: <error>` in the status bar.

### Document Lifecycle

| Event | LSP Notification |
|-------|-----------------|
| File opened | `textDocument/didOpen` (starts the server first if needed) |
| Text edited | `textDocument/didChange` (full text, coalesced per frame) |
| File saved | `textDocument/didSave` |
| Tab closed | `textDocument/didClose` |
| Renamed in the tree / Save As | `didClose` on the old uri, then `didOpen` on the new one (possibly on a different server when the language changed) |

---

## Shared / Core

### Architecture

| File | Purpose |
|------|---------|
| `src/main.zig` | Entry point, CLI parsing, mode detection |
| `src/core/buffer.zig` | Text storage (gap buffer) |
| `src/core/document.zig` | Document model (buffer + cursors + undo + metadata) |
| `src/core/cursor.zig` | Cursor and CursorSet (multi-cursor data model) |
| `src/core/undo.zig` | Undo/redo history |
| `src/core/commands.zig` | Command registry and all built-in commands |
| `src/core/editor.zig` | Editor state (documents, windows — each a split layout + focused pane, mode, settings) |
| `src/core/keybind.zig` | Data-driven keybinding map |
| `src/core/syntax.zig` | Syntax highlighting engine (tokenizer, LanguageDef, built-in Zig) |
| `src/core/theme.zig` | Theme system (ThemeColor, EditorTheme, TuiTheme, SyntaxTheme, presets) |
| `src/core/layout.zig` | Split pane layout tree (binary tree of panes + splits) |
| `src/core/clipboard.zig` | System clipboard (Win32 API, Linux wl-copy/xclip/xsel) |
| `src/core/lsp.zig` | LSP client, capability negotiation, versioned requests and `ServerConfig` registrations |
| `src/core/protocol.zig` | Managed framed stdio transport shared by LSP and DAP |
| `src/core/jobs.zig` | Owned process groups, bounded streaming output, cancellation and wakeups |
| `src/core/tasks.zig` | Explicit task registrations, save-before-run and diagnostic matching |
| `src/core/diagnostics.zig` | Workspace Problems store, isolated producers and closed-file findings |
| `src/core/git.zig` | Asynchronous Git status, previews, saved-file staging and gutter caches |
| `src/core/review.zig` | Review record: verdicts keyed to git blob ids, the baseline (last commit or checkpoint), the changed-file list behind the Review view, the reader's diff job and refresh |
| `src/core/unidiff.zig` | Parser for git's unified diff output (whole-file hunks for the reader) |
| `src/core/review_reader.zig` | The review reader: a read-only document synthesized from a diff (tints, ghost rows, folded stretches, real-line map) |
| `src/core/dap.zig` | Debugger registrations, workspace breakpoints and shared views |
| `src/core/dap_session.zig` | DAP lifecycle, request deadlines, threads, frames, variables and controls |
| `src/core/dap_lua.zig` | zide debug registration/start/stop bridge |
| `src/core/breakpoints.zig` | Per-workspace source-breakpoint persistence |
| `src/core/task_lua.zig` | zide.register_task / run_task / cancel_task bridge |
| `src/core/tool_panel.zig` | Shared Tasks / Problems / Changes / Review / References / Debug views (rows, selection, keys) |
| `src/core/lsp_tools.zig` | Hover, rename, formatting and format-on-save request flows |
| `src/core/workspace_edit.zig` | Workspace-edit preview/apply (rename and server `applyEdit`) |
| `src/core/line_diff.zig` | Buffer-vs-index line diff behind the Git gutter marks |
| `src/core/search.zig` | Workspace search/replace engine (background walk, streaming results) |
| `src/core/walk_ignore.zig` | Top-level `.gitignore` pruning for quick open and workspace search |
| `src/core/snippets.zig` | Snippet templates: parsing, indentation-aware insertion, field tracking |
| `src/core/snippet_panel.zig` | Snippets side panel model: the registry's definitions for one document as collapsible group rows, selection and preview |
| `src/core/recovery.zig` | Crash-recovery snapshots (per-workspace/instance dirs, off-thread encode) |
| `src/core/editorconfig.zig` | EditorConfig resolution and save-time normalization |
| `src/core/text_file.zig` | File read/write: encoding detection and conversion, atomic saves |
| `src/core/file_uri.zig` | file:// URI encoding/decoding (VS Code-compatible) |
| `src/core/deadlines.zig` | Background deadlines (auto-save, external-change and tree polls, Git refresh) |
| `src/core/filetree.zig` | File tree model (rows, expansion, file operations, git roll-up) |
| `src/core/fileicons.zig` | File/folder icon classification shared by both frontends |
| `src/core/pty.zig` | Cross-platform PTY (ConPTY on Windows, posix elsewhere) |
| `src/core/ansi.zig` | VT/ANSI escape sequence parser |
| `src/core/terminal.zig` | Terminal emulator (cell grid, reader thread, key encoding) |
| `src/core/lua_json.zig` | Lua table → JSON (register_lsp `settings` / `init_options`, debug arguments) |
| `src/core/lua_settings.zig` | Lua settings bridge (zide.set/get/bind/unbind, set_language/get_language, register_language, register_lsp, config/theme/extension loading) |
| `src/core/lua_api.zig` | Extension runtime API (zide.command/on/exec/status, register_snippet, buffer API, run/spawn, set_diagnostics, set_icon) |
| `src/frontend/tui.zig` | TUI frontend (libvaxis) |
| `src/frontend/gui.zig` | GUI frontend (DVUI + SDL3) |
| `src/frontend/icons.zig` | The GUI's icon set: public-domain CFPB Design System SVGs in `src/icons/svg` plus ZIDE's own shapes in `src/icons/svg/zide` (no attribution needed for either), converted to TinyVG on first use, with icon-button helpers |

### Build Targets

- `zig build` — Both frontends (zide + zide-tui)
- `zig build -Dfrontend=tui` — TUI only
- `zig build -Dfrontend=gui` — GUI only
- `zig build run-tui` — Build and run TUI
- `zig build run-gui` — Build and run GUI (alias: `run`)
- `zig build test` — Run unit tests, including the TUI encoding/input smoke test
- `zig build test-gui -Dfrontend=gui` — Run the GUI encoding/input smoke test in a hidden SDL window

### Toolchain & Dependencies (Zig 0.16)

ZIDE builds with **Zig 0.16.0** (pinned in `build.zig.zon`'s
`minimum_zig_version` — anyzig dispatches this exact version). Vendored deps
in `libs/` are upstream-main snapshots that target 0.16: **dvui** (GUI,
exposes `dvui_sdl3`/`dvui_sdl3gpu`), **ziglua** (upstream now calls itself
*zlua*; the module name we import was already `zlua`), and **libvaxis**
(TUI). The old `zit` dependency was removed entirely (imported nowhere).
Their transitive deps (SDL3, freetype, Lua 5.4, zigimg, uucode, translate-c,
…) are fetched by the build into the project-local `zig-pkg/` directory
(gitignored; the global cache keeps the compressed tarballs).

Migration conventions from the 0.16 `std.Io` era, for anyone touching core:

- **`Editor.io: std.Io`** is threaded through like an Allocator: file I/O
  (`Document.open/save`, `Buffer.loadFile/saveFile`), process spawning
  (LSP, "open folder"), and timestamps (`std.Io.Clock.now(.awake, io)`)
  all take or use it. Tests use `std.testing.io`.
- **Mutexes** are `std.Io.Mutex` locked with `lockUncancelable(io)` /
  `unlock(io)` — `Terminal` and the LSP message queue store the io they
  lock with.
- **`lua_settings.process_environ` / `global_io`** are module-level
  context set first thing in `main()` (env vars and Io are no longer
  global in std; the file logger needs config paths before an Editor
  exists). `std.Options.debug_io` powers the logger itself.
- **Juicy Main**: `pub fn main(init: std.process.Init)` supplies the gpa
  (leak-checked in Debug), io, args, and environ map.
- **Child processes** are spawned through `jobs.spawnLocked`, a
  process-wide spawn lock: on Windows two concurrent spawns inherit each
  other's pipe handles, and one child's output then never reaches EOF
  while the other lives. Cancelling a job kills its whole process tree
  immediately, and worker wake callbacks are called only after unlocking
  (a wake may block).

### Hybrid Launch (Frontend Auto-Detection)

The `zide` binary contains **both** frontends and picks one at launch:

- **Typed in a terminal** (`zide`, `zide file.zig`) → opens the **TUI** in that terminal
- **Launched from the desktop** (Explorer double-click, Start menu, `start zide`) → opens the **GUI** window
- **Piped/redirected** (`zide file.zig | ...`) → GUI (a TUI would fight the redirection)
- `--gui` / `--tui` always override detection; `zide-tui` is TUI-only. `--renderer=auto|hardware|software` (GUI) overrides the saved renderer choice for one launch
- **`zide <file>`** for a path that does not exist yet opens an empty document bound to it — Ctrl+S creates the file; other open failures show in the status bar
- **`zide <folder>`** (either frontend) opens that folder as the **project**: it becomes the file tree root and the workspace sent to language servers for this launch, overriding `filetree_root` from init.lua. Files may follow: `zide . src/main.zig`. A project launch shows the welcome text instead of restoring the previous session (which may belong to another project). Only one folder is accepted; extra ones are reported and ignored. The folder joins the recent-projects list (see *Open folder*).

On Windows the check uses `GetConsoleProcessList`: a console shared with a
parent shell means a real terminal launch, while a freshly allocated console
means a desktop launch (the stray console window is released). On Linux/macOS
both stdin and stdout must be a TTY.

### Saving

- `Ctrl+S` on a buffer **with** a file path saves it; failures show in the status bar
- `Ctrl+S` on an **untitled** buffer opens Save As (native dialog in the GUI, path prompt in the TUI)
- Quit-with-unsaved-changes (`[S]ave`) only quits if **every** dirty document saved; otherwise it cancels and reports how many failed
- Closing a dirty tab (Ctrl+W, the tab's ×, Close Tab in the File or tab menu) asks `[S]ave [D]iscard [C]ancel` for that document. `[S]ave` on an untitled buffer opens Save As (native dialog in the GUI, path prompt in the TUI) and closes the tab once the file is written — cancelling Save As keeps the tab. A file that changed on disk meanwhile gets the `[O]verwrite [R]eload [C]ancel` prompt instead and the tab stays open

### File encodings

Both frontends show the focused document's encoding at the bottom-right of the status bar. Click it to choose **Reopen with Encoding** or **Save with Encoding**. The command palette exposes the same controls as `file_encoding`, `reopen_with_encoding`, and `save_with_encoding`. Terminal panes hide the encoding label. In the TUI, use Up/Down and Enter, click a picker row, or press its number; Escape cancels.

| Format | Opening and saving |
|--------|-------------------|
| UTF-8 | Default for new files, without a BOM. UTF-8 with BOM is also offered. |
| UTF-16 LE / UTF-16 BE | BOMs are detected automatically. Explicit reopening also supports files without a BOM. Conversions write a BOM. |
| Windows-1252 | Choose explicitly for legacy text, including accented characters and typographic punctuation. Ordinary saves retain Windows-1252. |

Buffers, Lua buffer APIs, and language-server text stay in UTF-8. Ordinary saves preserve the file's encoding, BOM presence, and line endings. Files without a BOM are first tried as UTF-8; an explicit open offers an encoding picker when that does not produce supported text. Malformed encodings and binary content (text containing a NUL byte) are rejected without inserting replacement characters; other control characters — ANSI escapes in a log file, VT, BEL, C1 code points — open normally. Saving requires only valid UTF-8, so a pasted control character saves. Failed opens and reloads keep the current document, cursor positions, undo history, and scroll position.

**Reopen with Encoding** reads and reinterprets the disk contents. A dirty document first asks Save / Discard / Cancel. A failed decode keeps its current buffer. **Save with Encoding** converts the current buffer and follows the normal save/conflict workflow; an untitled document proceeds to Save As. The format changes only after a successful save. Pending choices stay attached to the original document across tab and window changes.

If Windows-1252 cannot represent edited text (C1 control characters included), saving offers **Save as UTF-8** or **Cancel** and leaves the destination intact until conversion succeeds. Autosave reports failures in the status bar without opening a dialog. Saves, Save As, autosave, closed-file replacements, and session persistence write a complete temporary sibling, synchronize it, then atomically replace the destination. Existing file permissions (including Windows DACLs and attributes) are preserved, and symlinks retain their link while the target is saved.

Explicit encoding choices are remembered by file path for the current session. With `session_persistence` enabled, those choices are also saved and restored; older session files remain supported. Quick-open previews and workspace searches reuse known choices and otherwise skip files whose encoding is unresolved, malformed, binary, or unreadable. Their skipped counts are shown without interrupting with dialogs. Deliberately opening an unresolved file offers the picker. Search positions refer to decoded UTF-8 buffer bytes; closed-file replacements preserve source formats and report failed files separately from successful replacements.

Find/replace, workspace search, quick open, command palette, and filename prompts accept Unicode text and remove complete code points on Backspace; keys that carry no text (arrows, Home/End, F-keys) are never typed into a prompt. Matching is literal; existing case-insensitive matching folds ASCII letters, and whole-word matching treats ASCII letters, digits, underscores and every non-ASCII character as word characters. Replace One accepts an empty replacement to delete a match. Replace All is one undoable transaction per open document and preserves every cursor and selection in undo/redo.

### Welcome Screen

Starting ZIDE without file arguments opens a scratch buffer containing the full
default hotkey reference (file, edit, find, multi-cursor, panes, terminal, LSP, code review),
plus a pointer to `init.lua` rebinding and the Ctrl+P command palette. Defined
once as `welcome_text` in `main.zig` and shared by both frontends; keep it in
sync with `keybind.zig`'s `loadDefaults()`.

### Logging

`std.log` output is written to **`~/.config/zide/zide.log`** (truncated on each
run) — never to stderr. Reasons: in TUI mode vaxis owns the terminal, and a
stray log line would be painted over the editor and stick there (vaxis diffs
cells and never repaints what it didn't draw); in GUI desktop launches the
console has been released. Check this file when diagnosing LSP/startup issues.
CLI usage errors (bad flags, `--gui` on a TUI-only build) still print to the
terminal directly. The `open_log` palette command opens the log in a tab (it
reloads as the file grows), and `lsp_stderr` shows what language servers
printed to their stderr.

### Command System

All editing actions go through named commands in `CommandRegistry`. Commands can be invoked by:
- Keyboard shortcuts (via data-driven keybind map, remappable through Lua). Lookup order: the active file's **language overlay** (`zide.bind(key, cmd, { language = "zig" })`) first, then the global map — for shift chords the exact combo is tried in both before the shift-stripped fallback, so a global exact binding always beats an overlay's fallback. The fallback covers punctuation and special keys only, never letters: Ctrl+Shift+K does not run Ctrl+K's binding. Overlays are skipped while the file tree or search panel own the keyboard and in terminal panes
- Command palette (fuzzy search)
- Lua scripting: `zide.bind("ctrl+d", "delete_line")`, or per language: `zide.bind("ctrl+alt+j", "toggle_comment", { language = "zig" })`

Key combos for `zide.bind` / `zide.unbind` accept any case and modifier order (`Ctrl+Shift+K` = `shift+ctrl+k`; `control` works for `ctrl`). Key name aliases: `pageup`/`pgup` → `page_up`, `pagedown`/`pgdn` → `page_down`, `esc` → `escape`, `return` → `enter`, `del` → `delete`, `ins` → `insert`, `\` → `backslash`, plus `space` and the dvui-style punctuation names `slash`, `period`, `semicolon`, `comma`, `minus`, `equal`, `grave`, `apostrophe`, `left_bracket`, `right_bracket`. Both frontends deliver letters, digits, F1–F12, the named keys (arrows, `home`, `end`, `page_up`, `page_down`, `insert`, `delete`, `tab`, `enter`, `escape`, `backspace`, `space`, `backslash`) and the punctuation `[ ] ; ' , . / - =` plus backtick (`grave`), so `ctrl+1` or `ctrl+insert` work in the GUI and the TUI alike; Ctrl+Space (`ctrl+space`) works in the TUI too. `zide.bind` logs one warning for a key or modifier that can never fire and one when the command is not registered (yet); the binding still stands, so an extension may register the command later.

**Keyboard focus.** In normal mode exactly one of the focused editor pane, the focused terminal pane, the file tree, the Snippets panel, the search panel and the terminal panel owns the keyboard (when flags disagree, the tree wins, then the Snippets panel, then the search panel). The docked panels live in the main window and can own the keyboard only while that window is focused. Clicking any pane, clicking a tab, splitting, F6 / Shift+F6, switching windows and `toggle_terminal` (Ctrl+backtick) give the keyboard back to the pane; `toggle_terminal` with a panel focused over a terminal pane focuses that terminal instead of opening another, and from the terminal panel it goes back to the editor. While a panel owns the keyboard, clipboard, select-all and word-delete chords never touch the document behind it: in the search panel the keys bound to copy and cut take the whole focused field, paste appends the clipboard's first line and Ctrl+Backspace deletes the previous word, while Ctrl+A and Ctrl+Delete do nothing; in the file tree the keys bound to copy, cut and paste drive the file clipboard; the Snippets panel swallows them all; the terminal panel's shell gets them as bytes like a terminal pane (Ctrl+C is the interrupt). The Edit menu's Cut/Copy/Paste/Select All follow the same rule.

About 179 registered commands; every one is listed in the command palette and bindable with `zide.bind`. The tables below are the complete set (names as the code registers them, 2026-11-12). "Default key" is the shipped binding; **hard-wired** means the frontends dispatch that plain key themselves, so it is not in the keybind map — the command can still be bound to a chord of your own. `theme_*`, `gui_theme_*` and `tui_theme_*` re-apply `themes/syntax-theme.lua` and the `syn_theme_<lang>.lua` files on top of the new palette (the editor-color override files `gui-theme.lua` / `tui-theme.lua` are not re-run until the next launch).

**Files, tabs and projects**

| Command | Default key | What it does |
| --- | --- | --- |
| `new_document` | Ctrl+N | Open a new untitled document |
| `file_open` | Ctrl+O | Open a file by path |
| `save` | Ctrl+S | Save the current document |
| `save_as` | Ctrl+Shift+S | Save the current document under a new name |
| `save_with_encoding` / `reopen_with_encoding` / `file_encoding` | — | Save or reopen with a chosen encoding; choose the file encoding |
| `close_tab` | Ctrl+W | Close the current tab (asks about unsaved changes) |
| `reopen_closed_tab` | Ctrl+Shift+T | Reopen the most recently closed file |
| `next_doc` / `prev_doc` | Ctrl+Tab / Ctrl+Shift+Tab, also Ctrl+PgDn / Ctrl+PgUp | Switch to the next / previous tab |
| `quick_open` | Ctrl+E | Fuzzy-find a file in the workspace (live preview) |
| `open_folder` | Ctrl+Shift+O | Open a folder as the project (file tree root and language-server workspace) |
| `recent_projects` | — | Pick a recently opened project folder |
| `recover_documents` | — | Recover unsaved documents from a previous instance |
| `quit` | Ctrl+Q | Quit ZIDE (asks about unsaved changes) |
| `close_window` | — | Close this window (main window: quit) |
| `open_in_new_window` | Ctrl+Shift+N, also Ctrl+Alt+N | Show the current document in a new window (TUI: split) |
| `move_pane_to_new_window` | — | Move the focused pane into a new window (TUI: split) |
| `settings` | — | Open the settings dialog (GUI) |
| `command_palette` | Ctrl+P | Open the command palette |
| `open_documentation` | — | Open `docs/Documentation.md` |
| `open_log` | — | Open `zide.log` (reloads as it grows) |

**Cursor, selection and navigation**

| Command | Default key | What it does |
| --- | --- | --- |
| `cursor_left` / `cursor_right` / `cursor_up` / `cursor_down` | arrows (hard-wired) | Move the caret |
| `cursor_left_select` / `cursor_right_select` / `cursor_up_select` / `cursor_down_select` | Shift+arrows (hard-wired) | Extend the selection |
| `cursor_word_left` / `cursor_word_right` | Ctrl+Left / Ctrl+Right | Move by word |
| `cursor_word_left_select` / `cursor_word_right_select` | Ctrl+Shift+Left / Ctrl+Shift+Right | Select by word |
| `smart_home` / `smart_home_select` | Home / Shift+Home (hard-wired) | First non-whitespace column, then column 0 |
| `cursor_home` / `cursor_home_select` | — (Home runs `smart_home`) | Column 0 / select to column 0 |
| `cursor_end` / `cursor_end_select` | End / Shift+End (hard-wired) | End of line / select to end of line |
| `cursor_file_start` / `cursor_file_end` | Ctrl+Home / Ctrl+End | Jump to the start / end of the file |
| `cursor_file_start_select` / `cursor_file_end_select` | Ctrl+Shift+Home / Ctrl+Shift+End | Select to the start / end of the file |
| `page_up` / `page_down` | PgUp / PgDn (hard-wired) | Move one page |
| `select_all` | Ctrl+A | Select all text |
| `add_cursor_above` / `add_cursor_below` | Ctrl+Shift+Up / Down, also Ctrl+Alt+Up / Down | Add a cursor on the line above / below |
| `add_next_occurrence` | Ctrl+D | Add a cursor at the next occurrence (selects the word first) |
| `escape_multicursor` | Escape (hard-wired) | Remove secondary cursors |
| `goto_line` | Ctrl+G | Go to a line number |
| `goto_matching_bracket` | Alt+M | Jump to the bracket matching the one at the caret |
| `navigate_back` / `navigate_forward` | Ctrl+Alt+Left / Right, also F7 / Shift+F7 | Move through the jump history |
| `next_todo` | — | Jump to the next TODO/FIXME/XXX/HACK/BUG/NOTE marker |

**Editing**

| Command | Default key | What it does |
| --- | --- | --- |
| `undo` / `redo` | Ctrl+Z / Ctrl+Y (also Ctrl+Shift+Z) | Undo / redo |
| `copy` / `cut` / `paste` | Ctrl+C / Ctrl+X / Ctrl+V | Clipboard |
| `insert_char` / `insert_newline` / `insert_newline_auto` | typing / Enter (hard-wired) | Insert text; Enter inserts a newline with auto-indent |
| `delete_backward` / `delete_forward` | Backspace / Delete (hard-wired) | Delete one character |
| `delete_word_backward` / `delete_word_forward` | Ctrl+Backspace / Ctrl+Delete | Delete one word |
| `delete_line` | Ctrl+K | Delete the current line |
| `duplicate_line` | Ctrl+Shift+D | Duplicate the current line |
| `move_line_up` / `move_line_down` | Alt+Up / Alt+Down, also Ctrl+Shift+PgUp / PgDn | Move the line |
| `indent` / `dedent` | Tab / Shift+Tab (hard-wired, after snippets and completion) | Indent / dedent the caret line or every selected line |
| `toggle_comment` | Ctrl+/ | Toggle comments on the selected lines |

**Find**

| Command | Default key | What it does |
| --- | --- | --- |
| `find` | Ctrl+F | Find in the current document |
| `find_replace` | Ctrl+H | Find and replace in the current document |
| `find_in_files` | Ctrl+Shift+F | Search and replace across the workspace (results panel) |
| `next_result` / `prev_result` | F4 / Shift+F4 | Step through the workspace search results |

**Panes, windows and terminals**

| Command | Default key | What it does |
| --- | --- | --- |
| `split_vertical` / `split_horizontal` | Alt+\ / Alt+Shift+\, also Ctrl+\ / Ctrl+Shift+\ | Split the pane side by side / top-bottom |
| `close_pane` | Ctrl+Alt+Q, also Ctrl+F4 | Close the current pane (also a terminal pane); while the terminal panel has the keyboard, close the panel's shell instead |
| `focus_next_pane` / `focus_prev_pane` | Alt+Right / Alt+Left, also F6 / Shift+F6 | Move focus between panes |
| `toggle_terminal` | Ctrl+` | Open a terminal below, or go back from a terminal (pane or panel) to the editor |
| `open_terminal_right` | — | Open a terminal in a split to the right |
| `close_terminal` | — | Close the focused terminal: a pane, or the terminal panel's shell while the panel has the keyboard |
| `detach_terminal` | Ctrl+Alt+` | Move the focused terminal (a pane, or the terminal panel's shell) into its own window (TUI: side split) |
| `toggle_terminal_panel` | Ctrl+Shift+` | The terminal panel: open a shell docked at the side or bottom and focus it, focus it, or go back to the editor |
| `hide_terminal_panel` / `close_terminal_panel` | — | Hide the terminal panel (its shell keeps running) / end its shell and hide it |
| `dock_terminal` / `undock_terminal` | — | Move the focused terminal pane into the panel / the panel's shell into a split pane |
| `move_terminal_panel_left` / `_right` / `_bottom` | — | Dock the terminal panel at that edge (persisted) |
| `move_filetree_left` / `_right`, `move_snippets_left` / `_right` | — | Dock the file tree / the Snippets panel at that side (persisted; the TUI's way to move them) |

**File tree**

| Command | Default key | What it does |
| --- | --- | --- |
| `toggle_filetree` | Ctrl+B | Toggle the file tree side panel |
| `filetree_reveal` | — | Reveal the current file in the tree |
| `filetree_refresh` | — | Refresh the tree from disk |
| `filetree_collapse_all` | — | Collapse every folder |
| `filetree_root_up` | — | Re-root the tree at the parent directory |
| `filetree_set_root` | `o` in the tree | Open the selected folder as the project root |
| `filetree_copy` / `filetree_cut` / `filetree_paste` | — | The file clipboard for the selected entries |
| `filetree_copy_path` / `filetree_copy_relative_path` | — | Copy the selected entry's absolute / root-relative path |
| `filetree_reveal_explorer` | — | Show the selected entry in the system file manager |
| `toggle_tui_icons` | — | Toggle nerdfont icons in the TUI tree (persists to init.lua) |

**Language servers**

| Command | Default key | What it does |
| --- | --- | --- |
| `lsp_completion` | Ctrl+Space | Show completions at the caret |
| `lsp_goto_definition` | F12 | Go to the definition of the symbol at the caret |
| `hover` | — | Show documentation for the symbol at the caret |
| `rename_symbol` | — | Rename a symbol with a workspace-edit preview |
| `format_document` / `format_selection` | — | Format the document / the selection |
| `lsp_references` / `references` | Shift+F12 / — | Find every reference (References view) / reopen the last list |
| `lsp_document_symbols` | Ctrl+F12 | Go to a symbol in this file (picker) |
| `lsp_workspace_symbols` | Ctrl+T | Search symbols across the workspace (picker) |
| `lsp_signature_help` | Ctrl+Shift+Space | Show the signature of the call at the caret |
| `lsp_restart` | — | Restart language servers (re-reads registrations, clears failures) |
| `lsp_stderr` | — | Show what the servers wrote to stderr (read-only tab) |

**Snippets**

| Command | Default key | What it does |
| --- | --- | --- |
| `snippet_expand` | Tab (hard-wired) | Expand the exact trigger before the caret |
| `snippet_next` / `snippet_previous` | Tab / Shift+Tab (hard-wired) | Visit the next / previous placeholder |
| `snippet_cancel` | Escape (hard-wired) | End snippet navigation |
| `toggle_snippets` | Ctrl+Alt+B | Show, focus or hide the Snippets side panel (the same three-step cycle as `toggle_filetree`) |
| `snippet_save_selection` | Ctrl+Alt+S | Save the selection as a snippet through a form (name, folder, trigger, language, notes) into `my-snippets.lua` — see *Making your own* |

**Tasks, problems, Git and debugging**

| Command | Default key | What it does |
| --- | --- | --- |
| `run_task` / `rerun_task` / `stop_task` / `task_output` | — | Run, rerun or cancel a task; show the latest output |
| `problems` / `next_problem` / `previous_problem` | — | The Problems view and stepping through it |
| `git_changes` / `git_refresh` / `git_stage` / `git_unstage` | — | The Changes panel and its actions |
| `review` | Ctrl+F8 | The Review view: changed files with verdicts, progress and baseline |
| `review_approve` / `review_needs_work` | — (A / W inside the view) | Give or take back a verdict on the selected row, else on the active file |
| `review_next_file` / `review_prev_file` | F8 / Shift+F8 | Read the next / previous changed file in the review reader |
| `review_set_baseline` / `review_follow_head` | — (P / U in the Review view) | Pin the current commit as the baseline / compare with the last commit again |
| `review_open_reader` | Enter in the Review view | Read the selected changed file in the reader (else the active file's) |
| `review_next_change` / `review_prev_change` | F9 / Shift+F9 | Move between changes inside the reader (on a listed real file: open its reader) |
| `review_toggle_view` | Ctrl+F9 | Reader ↔ classic diff of the same file |
| `review_expand_all` / `review_collapse_all` | — | Unfold / fold every collapsed unchanged stretch in the reader |
| `debug` / `debug_start` / `debug_stop` / `debug_terminate` | — | Debugger views; start a configuration; stop or detach; terminate an attached target |
| `debug_continue` / `debug_pause` / `debug_step_in` / `debug_step_over` / `debug_step_out` | — | Execution control |
| `toggle_breakpoint` | — | Toggle a source breakpoint at the caret |

**Themes and extensions**

| Command | Default key | What it does |
| --- | --- | --- |
| `theme_dark` / `theme_light` / `theme_high_contrast` / `theme_terminal` | — | Switch the theme in both frontends (`theme_terminal`: TUI only, ANSI colors) |
| `gui_theme_dark` / `gui_theme_light` / `gui_theme_high_contrast` | — | GUI only |
| `tui_theme_dark` / `tui_theme_light` / `tui_theme_high_contrast` | — | TUI only |
| `reload_extensions` | — | Reload Lua extensions (re-runs `extensions/*.lua`) |

## Snippets

Templates with placeholder fields, registered from Lua: skeletons of syntax you reach by plain
name from the **Snippets panel** or the palette, and — when they have a trigger — by typing
it and pressing Tab. 54 Zig skeletons ship active by default, filed in groups with notes —
see *The Shipped Extension: snippets-zig.lua* under the Extension System.

### The Snippets panel

- **Ctrl+Alt+B** (`toggle_snippets`, View > Snippets) cycles like Ctrl+B does for the file
  tree: hidden → shown + focused → (from the editor) focus the panel → (from the panel)
  hidden. Escape gives the keyboard back and leaves the panel open. Both frontends have the
  panel; the terminal's differences are listed at the end of this section.
- It lists the snippets of the main window's document language plus every `"*"` snippet, in
  collapsible groups in the order they were registered; the first group starts open. Click a
  group (or Enter, Left, Right) to open or close it. In an **untitled file without a
  language** it offers every language ZIDE knows, with the language in front of each group,
  and inserting a snippet makes the file that language (a Zig snippet turns a new file into a
  Zig file). A saved file ZIDE has no language for sees only `"*"` snippets.
- **Click an item or press Enter** on it: the snippet lands at the caret, the keyboard goes
  back to the editor and the first blank is selected, so Tab walks the blanks right away. It
  refuses — with a status-bar message, keeping the panel focused — when the focused pane is a
  terminal, the document is read-only or several cursors are active. Prefer Kate's way? With
  `snippets_double_click` (Settings dialog: "Snippets Insert on Double-Click") a click only
  selects the item and gives the panel the keyboard — its preview stays put while you read
  it — and a double-click inserts. Either way, to drive the list from the keyboard press
  Ctrl+Alt+B once more (it focuses the open panel) or click its header, a group or the empty
  space below the rows.
- The **preview** at the bottom shows the highlighted item (the hovered one in the GUI, else
  the selected one): the code as it will be inserted with its blanks tinted (soft-wrapped to
  the panel's width like the notes, a continued row indented two columns), the Tab trigger
  if it has one, and the snippet's notes. It takes the room a short list leaves free (at
  least 40% of the panel); when the notes still do not fit, the wheel over the preview, or
  its scrollbar, scrolls them. The panel's edge, its dividers, the code box and the guide
  lines under open groups use the `color_panel_border` theme color.
- Keys while it owns the keyboard: Up/Down, PageUp/PageDown, Home/End, Left (close the group
  or jump to it), Right (open the group or step into it), Enter, Escape. **Type to filter**:
  letters and other plain keys go into a filter (the box under the header in the GUI, `/text`
  after the language in the TUI header) that keeps only snippets whose name, trigger or folder
  contains the text, case-insensitively, with every matching folder open; Backspace edits it,
  Escape clears it first and releases the keyboard only when it is already empty. **F2** edits
  the selected snippet when it is one of yours, or copies any other into your file (see
  *Making your own*); **Delete** asks before removing one of yours. Clipboard chords are
  swallowed; global chords (Ctrl+B, Ctrl+P, …) keep working (a global `f2` binding would win
  over the panel's F2 in the GUI).
- It docks **left or right** with the same rules as the file tree: `snippets_side` (default
  `"auto"` = opposite the tree; on a shared side the tree sits outside) and `snippets_width`;
  right-click the panel to move it (or `move_snippets_left` / `move_snippets_right` in the
  palette, the TUI's way), drag its edge to resize — both persist to init.lua — and
  drag the edge well past the minimum width to hide it (the status bar says so before you
  let go; the width is kept, and Ctrl+Alt+B brings the panel back). `zide.set("snippets_visible",
  true)` opens it on every launch; Ctrl+Alt+B never writes settings. When the window has no
  room for it beside the editor (the panes keep 240 px next to the bands) it hides itself and
  says so in the status bar — widen the window and press Ctrl+Alt+B. A double-click on a row
  counts once. The Settings dialog (Preferences) has rows for all of these settings.
- **In the terminal** the band docks the same way, `tui_snippets_width` columns wide (16–80);
  it keeps 40 columns for the panes beside both bands and hides itself with a message when
  fewer than 16 columns are left for it. There is no hover (`snippets_double_click` is
  GUI-only): a click on a row selects it and shows its preview, a click on the highlighted
  item inserts it, a click on a group opens or closes it. The arrow keys move; typing filters
  (there are no letter commands). Shift+Up/Down and Shift+PageUp/PageDown scroll the preview
  (the wheel over it too); when
  notes are cut off, the preview's last row says `▼ Shift+Down for more`. Code wraps to the
  band with a two-column continuation indent, blanks are drawn in the selection colors, and a
  `│` guide sits under each open group, all in the TUI theme's `gutter_separator` color.

### Making your own

- **Ctrl+Alt+S** (`snippet_save_selection`; Edit > Save Selection as Snippet…, also in the
  editor's right-click menu; on keyboard layouts where Ctrl+Alt is AltGr, use the palette or
  the menu) turns the selection into a snippet. It refuses, with a status-bar message, when
  nothing is selected (or only blanks), the focused pane is a terminal, several cursors are
  active, the selection is not valid UTF-8, or it is longer than 8 KiB.
- A small form opens. In the GUI it is a dialog window: Tab / Shift+Tab move between the
  boxes, Enter in a one-line box saves (in Notes and Body it starts a new line; the Save
  button always saves), Escape cancels; in the Body box Tab moves on rather than typing a
  tab, so the selection's indentation stays as it was. In the TUI it is a panel above the
  status bar: Tab / Shift+Tab or Down / Up move between its rows, Enter saves, Escape
  cancels. The fields:
  - **Name** (required): what the panel and the palette show.
  - **Folder**: the panel group; empty means "Mine". The last folder you used is prefilled.
  - **Trigger**: optional — letters, digits, `_` or non-ASCII, no leading digit. Leave it
    empty for most skeletons (see *Using them with Tab* for why).
  - **Language**: the document's language, or `*` for every file.
  - **Notes**: the plain-language explanation the preview shows.
  - **Body**: the selection, with its line endings normalized and the indentation every line
    shares removed (a first line that started mid-line does not count). A `$` in the
    selection gets a backslash in front (`\$`), and so does a backslash right before `$`, `}`
    or another backslash, so the snippet inserts exactly what you selected instead of
    reading `$1` or `${name}` in your code as a blank. In the GUI you can edit it right
    there — add blanks like `${1:text}` and `$0`; a hint under the box repeats the syntax.
    The TUI saves the selection as it is (open my-snippets.lua to add blanks).
- Save checks the same rules as `zide.register_snippet` (the message appears in the form),
  writes the snippet into `~/.config/zide/extensions/my-snippets.lua` and registers it at
  once: the status bar says "Saved to my-snippets.lua: <name>" and, when the panel is open,
  selects the new row. The same name saved again replaces the earlier block. A
  `my-snippets.lua` open in a tab with unsaved changes blocks the save (save or close it
  first); a clean tab reloads to show the new block.
- That file is yours: *Your snippets: my-snippets.lua* under the Extension System describes
  its format and the rules the panel follows when rewriting it.
- **Editing and deleting.** In the panel, **F2** (or the GUI's right-click menu, "Edit
  Snippet…") on one of your snippets opens the same form filled in; Save rewrites its block in
  place, and a new name moves the block to the new name. **Delete** (or "Delete Snippet" in the
  menu) asks "Delete snippet … from my-snippets.lua?" — `y` deletes, anything else cancels —
  then removes the block and the snippet. Both work only for snippets in your file; on a
  bundled snippet F2 (or "Copy to My Snippets…") opens the form filled with its code and
  notes and saves a copy into your file: keep the name and your copy replaces the bundled one
  in the panel, since your file loads last. Delete that copy (or give it another name) and
  the bundled snippet is back in its row at once — the status bar says "(the one from
  snippets-zig.lua is back)", so the row that stays is not a failed delete. If a block was
  edited by hand so that the panel can no longer find its marker lines, Edit opens the file
  for you instead of guessing.

### Using them with Tab

- Type a trigger and press **Tab**: when the whole identifier just before the caret exactly
  matches a snippet prefix for the document's language, it expands (case-sensitive; `obj.fn`
  expands `fn`, but `myfn` — or a caret inside the word — does not). Expansion ignores syntax,
  so it fires in comments and strings too. It needs a single cursor with no selection, the
  editor pane owning the keyboard, and no Ctrl/Alt/Super held.
- **Tab's full priority order**: next snippet field → expand a trigger → accept an open
  completion → indent. **Shift+Tab**: previous snippet field (the first field reselects
  itself) → dedent. **Escape** ends field navigation and keeps the text. Past the last
  numbered field, Tab moves the caret to the `$0` position and navigation ends.
- Navigation also ends when the caret or selection leaves the active field (mouse, arrows),
  when an edit crosses the field's edge (Backspace at its start), on undo/redo, when a second
  cursor appears, on tab/pane/split/window switches, when the search panel, file tree or any
  prompt takes the keyboard, and on `reload_extensions`.
- Every snippet is also a **palette command** named `snippet.<language>.<prefix>` — or, for
  one without a trigger, `snippet.<language>.~<slug>` where the slug is the description
  lowercased with runs of punctuation and spaces folded to `-` (`Hello world program` →
  `snippet.zig.~hello-world-program`; the `~` keeps the two kinds apart) — bindable with
  `zide.bind` and callable via `zide.exec`. It inserts at the caret (replacing a
  selection) with no trigger typed; running one for another language reports
  `Snippet language does not match this document`. The commands `snippet_expand`,
  `snippet_next`, `snippet_previous` and `snippet_cancel` exist for chords (`snippet_expand`
  explains its failures in the status bar; from the palette the navigation ones are no-ops,
  since opening the palette already ends navigation). Plain Tab / Shift+Tab / Escape are not
  remappable — the keybind map only sees Ctrl, Alt and F-key chords.
- The whole insertion is one undo step; typing inside fields is a separate step. Expanding
  closes the completion popup, snippets never appear in that popup, and there is no setting
  to turn Tab expansion off (empty the snippet files instead).

### Registering

```lua
zide.register_snippet({
    language = "zig",          -- a language name (case-insensitive), or "*" for every document
    prefix = "fn",             -- optional Tab trigger: letters, digits, _ or non-ASCII; no leading digit, no @
    body = "fn ${1:name}($2) $3 {\n\t$0\n}",
    description = "Function",  -- the name in the panel and the palette; defaults to the prefix
    group = "Functions",       -- optional panel folder; defaults to "Other"
    notes = "A named block of code you call with name().",  -- optional; shown in the preview, never inserted
})
```

A snippet needs a `prefix` or a `description`. Most of the bundled skeletons have no trigger:
Tab expands an exact trigger *before* it accepts an open completion, and also after a dot, so
a trigger named like everyday code (`print`) would fire while you complete `std.debug.print`.
`description` and `group` must be one line of valid UTF-8; `notes` may contain line breaks
but no other control characters (both frontends draw them).

Returns the command name (`"snippet.zig.fn"`), or `nil, message` on failure — it never raises.
Re-registering the same language + prefix (or, without a prefix, the same language +
description) replaces the snippet; a name already owned by a `zide.command` is refused. A
language-specific snippet beats a `"*"` snippet with the same prefix. Snippets from `extensions/*.lua` are dropped and re-created by `reload_extensions`,
while ones registered from init.lua survive reloads — but init.lua runs before extensions, so
a bundled snippet with the same language and prefix replaces it at every load (edit
`snippets-zig.lua` itself instead). Your own `my-snippets.lua` runs after every other
extension file, so a snippet saved from the panel wins over a bundled one with the same name.

### Template syntax

- Fields are `$1`, `${1}` or `${1:default}`; `$0` is the final caret position (without it the
  caret ends after the inserted text). Digits are read greedily (`$10` is field 10), each
  number may appear only once (no mirrored fields), fields are visited in numeric order and
  gaps are fine. A first field with default text comes up selected.
- Escapes are `\$`, `\}` and `\\`; any other backslash is literal, and a literal `$` must
  always be written `\$`. In a quoted Lua string that means `"\\$"` (Lua 5.4 rejects `"\$"`);
  `[[...]]` avoids the double escape but needs real newlines and tabs. A `}` outside a field
  is literal; inside a default value write `\}`.
- Not supported: nested fields, choices (`${1|a,b|}`), variables (`$NAME`), transforms.
- Indentation: every body line starts with the trigger line's leading whitespace; leading
  `\t` characters in a body line are one indent level each (spaces when the document indents
  with spaces, EditorConfig and per-language settings included; a tab after text stays a
  tab), and line breaks become the document's line ending.

## Embedded Terminal

ZIDE includes a built-in terminal emulator that integrates with the split pane system — in both frontends (in the TUI, the shell's grid renders as cells and the reader thread wakes the event loop via `terminal_wake_fn`, the same pattern the LSP uses).

### Two kinds of terminal

A shell can sit in two places. Both run the same shell and take keys the same way; they differ in where they live and in how you move them — which is why the panel's right-click menu does nothing on a Ctrl+` terminal.

| | Terminal **pane** | Terminal **panel** |
|---|---|---|
| Key | Ctrl+` | Ctrl+Shift+` |
| Command | `toggle_terminal` — or `open_terminal_right` from the palette, for one at the side | `toggle_terminal_panel` (View > Terminal Panel) |
| Where it is | One of the split panes, like a document pane, in any window | Docked at an edge of the main window — bottom, left or right — outside the panes |
| How many | As many as you open: every Ctrl+` pressed in the editor opens another one | One |
| How to recognise it | No title row. Status bar: *Terminal* (TUI: `[TERMINAL]`) | A title row that starts with "Terminal —". Status bar: *Terminal panel* (TUI: `[TERMINAL PANEL]`) |
| Right-click (GUI) | No menu | Move Terminal to Left / Right / Bottom, Undock into a Split, Hide Panel, Close Terminal |
| Moving it | It follows the splits. View > Dock Terminal in Panel (`dock_terminal`) makes it the panel's shell, unless the panel already has one; Ctrl+Alt+` gives it its own window | The menu above, or `move_terminal_panel_left` / `_right` / `_bottom` in the palette; `undock_terminal` turns it into a pane |
| Size (GUI) | Drag the divider between the panes | Drag the panel's editor-facing edge |
| Out of the way | Only by closing it | `hide_terminal_panel`, or drag its edge well past the minimum — the shell keeps running |
| Back to the editor | Ctrl+` | The same key, or Ctrl+Shift+` |
| Back into it | Click it, or F6 / Shift+F6 (next / previous pane) — Ctrl+` opens another terminal instead | Ctrl+Shift+`, or click it |

**Why there are two.** The pane came first: a terminal for a few commands, placed among the code like any other split. The panel was added for one long-running program — a chat-style CLI such as Claude Code — that keeps its place at the side of the window whatever the splits do, and can be hidden without ending. To put a Ctrl+` terminal at the left or right edge: focus it, choose View > Dock Terminal in Panel, then right-click it and pick the edge.

Two rough edges are on the list in `docs/TODO.md` (*Two kinds of terminal*, 2026-11-12): Ctrl+` should go back to the terminal you just left instead of opening another, and a terminal pane should get a right-click menu of its own.

### Opening and closing a terminal
- **Ctrl+`** (backtick): from an editor pane opens a **new** terminal in a bottom split (even when one already exists); from a terminal pane (or the terminal panel) it returns to the editor; with the file tree or search panel focused over a terminal pane it focuses that terminal instead
- **Closing**: Ctrl+Alt+Q or Ctrl+F4 (`close_pane`) closes the focused terminal — also when it is the window's only pane, which then shows your document again; `close_terminal` in the palette (and View > Close Terminal in the GUI) does the same; and once the shell has ended (`exit`), the next key you press in the pane closes it
- Shell: PowerShell on Windows; on Linux/macOS `$SHELL` when it names an executable, else `/bin/bash`, else `/bin/sh`, started with `TERM=xterm-256color` (and `COLORTERM=truecolor` unless already set)

### The terminal panel (Ctrl+Shift+`)

A second home for a shell, beside the split panes: one terminal **docked at an edge of the main window** like the file tree — the bottom (default), or the left or right as a full-height column. The point is a chat-style CLI (Claude Code, any LLM CLI) that stays put at the side while Ctrl+` terminals come and go below your code. Built 2026-10-18 as step 1 of the rearrangeable-panels item in `docs/TODO.md`.

- **Ctrl+Shift+`** (`toggle_terminal_panel`, View > Terminal Panel) cycles like Ctrl+B does for the file tree: hidden or empty → shown with a shell (a new one when the panel has none) and focused → (from the editor) focus the panel → (from the panel) back to the editor, the panel staying open. Ctrl+` from the panel goes back to the editor too. A click on the panel focuses it; the header says which of the two keys goes back
- **Where it docks**: `terminal_panel_side` (`"bottom"`, `"left"`, `"right"`). Change it with `move_terminal_panel_left` / `_right` / `_bottom` in the palette (both frontends), the panel's right-click menu (GUI), or the Settings dialog; every way persists to init.lua and the status bar says where it went. At a side the panel sits inward of the file tree and the Snippets panel and is `terminal_panel_width` px wide (TUI: `tui_terminal_panel_width` columns); at the bottom it is a strip between the side bands, `terminal_panel_height` px tall (TUI: `tui_terminal_panel_height` rows)
- **Resizing (GUI)**: drag its editor-facing edge (the top edge at the bottom); the size persists on release. Drag well past the minimum to hide it — the status bar says so before you let go; the size is kept and the shell keeps running (Ctrl+Shift+` brings it back). The panel never takes more than half the pane area at the bottom, and at a side it keeps the panes 240 px (TUI: 40 columns) beside all the bands; with no room it hides itself and says so
- **Moving a shell in and out**: `dock_terminal` (View > Dock Terminal in Panel) moves the **focused terminal pane** into the panel — start Claude Code with Ctrl+`, then dock it; the split closes behind it (a lone terminal pane in the main window leaves a fresh document; in a secondary window the window closes). `undock_terminal` (the panel menu's *Undock into a Split*) moves the panel's shell into a split beside the active pane (below it from the bottom). The panel holds one shell: dock refuses while it has one (close or undock first). Ctrl+Alt+` (`detach_terminal`) pressed in the panel moves its shell into its own OS window instead (GUI; the panel is empty afterwards and hides — in the TUI a second terminal opens at the side and the panel keeps its shell)
- **Hiding and closing**: `hide_terminal_panel` (the menu's *Hide Panel*) hides it with the shell running; `close_terminal_panel` (the menu's *Close Terminal*), or `close_terminal` / `close_pane` (Ctrl+Alt+Q, Ctrl+F4) while the panel has the keyboard, ends the shell, and the panel hides — the split panes, and a terminal pane behind the panel, are left alone. Once the shell has ended (`exit`), the next key closes it as in a pane
- **Typing** goes to the shell exactly as in a terminal pane: the management chords (Ctrl+`, Ctrl+Shift+`, Ctrl+Alt+Q, F6, …) stay with ZIDE, everything else — Ctrl+C included — reaches the program; a paste goes to it too. The status bar says *Terminal panel* (TUI: `[TERMINAL PANEL]`) while it has the keyboard, and the GUI header turns bold
- The panel is not restored across runs (a shell cannot be), only its side and size are. Not yet: several shells in the panel (tabs), docking the file tree / Snippets / search panels at the bottom, and dragging a panel header to another edge — see the TODO entry

### Terminal Features
- Full ANSI/VT escape sequence support (colors, cursor movement, erase, scroll regions, alternate screen buffer). DCS/SOS/PM/APC payloads (neovim's terminfo queries, kitty graphics), private-marker sequences such as `CSI > 4;2 m` and colon sub-parameters (undercurl `4:3`) never garble the screen, and an ESC inside an unfinished sequence starts a new one. RI/IND/NEL and cursor moves respect the scroll region; shrinking the pane keeps the cursor line visible
- 16-color, 256-color, and 24-bit RGB color support
- Bold, underline, and reverse video attributes
- Automatic resize when the pane dimensions change
- Process exit detection with a `[Process exited — press any key to close]` message, on Windows too; the pane keeps the program's last screen until a key closes it
- Modified keys reach the shell xterm-style: Shift/Ctrl/Alt with arrows, Home/End, PgUp/PgDn, Ins/Del send a modifier parameter (Ctrl+Right = `ESC[1;5C`, so shell word-jumps work), Shift+Tab sends `ESC[Z`, Ctrl+Space sends NUL
- Keys reach the program in both frontends: arrows, Home/End, PgUp/PgDn, Ins/Del and F1–F12 as VT sequences (unmodified arrows, Home and End in SS3 form while the program has application cursor keys on — vim, less), Ctrl+letter and Ctrl+`[ \ ] ^ _ /` as control bytes (Ctrl+[ is ESC), Alt as an ESC prefix, emoji, CJK and multi-code-point keys whole. F-keys bound to pane or window actions (F6 focuses the next pane) stay with ZIDE. A paste goes to the program, in bracketed-paste markers when it asked for them
- GUI: typing follows the OS keyboard layout (AltGr, dead keys, IME commit); IME composition is sent only once committed and is not drawn while composing

### Terminal Commands
| Command | Keybind | Description |
|---------|---------|-------------|
| `toggle_terminal` | `Ctrl+\`` | New bottom terminal; from a terminal (pane or panel), back to the editor |
| `open_terminal_right` | — | Open a terminal in a side-by-side split (its old key, Ctrl+Shift+`, is the terminal panel's now) |
| `close_terminal` | — | Close the focused terminal pane, or the terminal panel's shell while the panel has the keyboard (View > Close Terminal in the GUI; `close_pane`, Ctrl+Alt+Q / Ctrl+F4, closes a focused terminal too) |
| `detach_terminal` | `Ctrl+Alt+\`` | Move the focused terminal — a pane, or the panel's shell while the panel has the keyboard — into its own OS window (GUI; TUI: a second terminal at the side) |
| `toggle_terminal_panel` | `Ctrl+Shift+\`` | The terminal panel: open / focus / back to the editor (see above) |
| `hide_terminal_panel`, `close_terminal_panel` | — | Hide the panel (shell keeps running) / end its shell |
| `dock_terminal`, `undock_terminal` | — | Focused terminal pane → panel / panel's shell → split pane |
| `move_terminal_panel_left` / `_right` / `_bottom` | — | Dock the panel at that edge (persisted) |

While a terminal pane (or the terminal panel) is focused, typing goes to the shell — only the pane / window / terminal management chords are let through (toggle, close, detach, focus next/prev pane, close window, open terminal right, the terminal panel toggle), in both frontends. In a TUI terminal pane Ctrl+Tab reaches the shell — switch tabs from an editor pane there; the GUI's hard-wired Ctrl+Tab switches tabs even over a terminal. A detached terminal window shows just the shell (plus menu/status bar per `secondary_window_chrome`); closing that window ends the shell, and `toggle_terminal` inside it reports "No editor pane in this window" instead of jumping to another window. On Linux, closing a terminal gives the shell ~500 ms after SIGHUP before it is killed, so a stubborn child cannot hang the editor.

### Architecture
- **`src/core/pty.zig`** — Cross-platform PTY abstraction (ConPTY on Windows, posix on Linux). The POSIX PTY descriptors are close-on-exec, so language servers, git and tasks never inherit them, and closing a terminal always returns, even while another process (a disowned job, `setsid`) still holds the PTY; on Windows a thread-pool wait on the shell process detects its exit
  - Windows gotcha: the shell must be spawned with `STARTF_USESTDHANDLES` + NULL std handles, or CreateProcess's std-handle duplication overrides the pseudoconsole attachment and the terminal stays blank (bit us when the GUI started releasing its console)
- **`src/core/ansi.zig`** — VT/ANSI escape sequence state machine parser
- **`src/core/terminal.zig`** — Terminal emulator (cell grid, reader thread, key encoding)
- Terminal panes use the same split pane layout system as editor panes — they can be placed anywhere (horizontal or vertical splits); the terminal panel is the one place a shell lives outside the split tree (`Editor.terminal_panel` indexes `terminals`; invariant I6: a terminal is shown by one pane or by the panel, never both)
- Background reader thread reads PTY output and updates a mutex-protected cell grid; the main thread reads the grid each frame for rendering

## File Tree

A toggleable side panel for browsing and managing the project directory, backed by a frontend-agnostic core model (`src/core/filetree.zig`) — both frontends render the same flattened row list, so expansion state, selection, file operations, and prompts behave identically in the GUI and the TUI.

### Basics
- **Ctrl+B** (`toggle_filetree`) cycles: hidden → shown + focused → (from the editor) focus the tree → (from the tree) hidden. Together with Escape this gives a full keyboard round-trip between editor and tree.
- Docks **left or right** (`filetree_side` setting, default left; `move_filetree_left` / `move_filetree_right` in the palette change it from either frontend, the GUI context menu too — all persist); width via `filetree_width` (GUI px) / `tui_filetree_width` (TUI columns) — in the GUI drag its editor-facing edge to resize it, or drag the edge well past the minimum width to hide it (the status bar says so before you let go; the width is kept, and Ctrl+B brings the tree back). The Snippets panel docks the same way (default: the other side; on a shared side the tree sits outside) — see *Snippets*; the terminal panel sits inward of both — see *Embedded Terminal*.
- Starts **visible** by default — to launch with it closed, uncheck "File Tree Visible" in the settings dialog (persists to init.lua) or `zide.set("filetree_visible", false)` (at runtime that also returns the keyboard to the pane); Ctrl+B at runtime never writes settings.
- Root = current directory by default, or the folder given on the command line (`zide path/to/project` — see *Hybrid Launch*). Change it in the Settings dialog ("File Tree Root" — type a path, Enter applies; a bad path keeps the previous root and shows why) or `zide.set("filetree_root", "/path")`; "" resets to cwd. At runtime `zide.set("filetree_root", …)` clears the file clipboard and a pending move and rebuilds the tree on the next frame. **Backspace / u** (or `filetree_root_up`) re-roots at the parent directory to climb the hierarchy.
- The panel header shows a clickable **up-button** (level-up icon in the GUI, `^` in the TUI) plus the full root path, truncated from the left (`...\Zig\ZIDE`) so the tail stays readable — click it to go up one folder.
- Files created, deleted, or renamed **outside ZIDE** (Explorer, a terminal) appear automatically: a cheap directory-mtime probe runs every ~1.5s and triggers a rescan when something changes (the multi-selection survives it, as with Shift+R). Both frontends wake for these deadlines even without input.
- Directories sort first, names case-insensitive; children scan lazily on first expand; everything is listed, dotfiles and `.git` included.
- Indent guide lines mark each ancestor level (thin rules in the GUI, `│` columns in the TUI) so deep nesting stays readable. The GUI draws them, the panel's editor-facing edge and the Snippets panel's dividers in the `color_panel_border` theme color (`zide.set("color_panel_border", "#5a5a62")` to change it; the TUI keeps `tui_color_gutter_separator` for its `│` columns).
- **GUI rows render VS Code-style**: chevron expanders on folders, per-type file icons in fixed accent colors (Zig orange, Lua blue, Markdown blue, images purple, executables green, folders steel blue, unknown types a dimmed generic document), the UI font instead of mono, a hover highlight under the pointer, and a selection bar that dims while the tree doesn't own the keyboard. Classification lives in `src/core/fileicons.zig` (frontend-agnostic — both frontends draw the same nerdfont glyphs, **per-language logos included**: the Zig zero, Lua moon, Rust gear, ...); special basenames beat extensions (README → book, LICENSE → shield, `.gitignore` → git, Makefile/Dockerfile/dotfiles → gear). The GUI renders the glyphs as text from the bundled Fira Code Nerd Font Mono, so they're always present — but if you point `mono_font_path` at a non-Nerd font, tree icons will show as boxes (pick any "NF" font to keep them). The panel chrome (chevrons, header buttons) and the tool dialogs' buttons draw the CFPB Design System icons (`src/icons/svg`, a US government work in the public domain under CC0) plus ZIDE's own drawings for the shapes that pack lacks (`src/icons/svg/zide`: pin, diff, stop, pause, the debugger steps, breakpoint, terminal, refresh) — nothing to credit; `src/frontend/icons.zig` converts them to TinyVG on first use, and DVUI's Entypo icons are only the fallback for an icon that fails to convert. The Debug view's overview rows carry the debugger's icons (continue, pause, step over / into / out, stop). Extensions can override any assignment with `zide.set_icon` (see Extension Runtime API).
- **TUI icons** (opt-in): the `toggle_tui_icons` palette command (Ctrl+P — works live in the TUI and persists), `zide.set("tui_filetree_icons", true)`, or the GUI Settings dialog swaps the `+`/`-` glyphs for ▸/▾ chevrons plus nerdfont glyphs in truecolor accents — **per-language logos** where Nerd Fonts have them (the Zig zero, Lua moon, Rust gear, Python snakes, PowerShell badge, ... — codepoints follow nvim-web-devicons), category glyphs otherwise. The terminal font must be a patched Nerd Font or the glyphs render as boxes; off (the default) keeps the classic look. `zide.set_icon` overrides render the chosen kind's category glyph.
- **GUI scrollbar**: a slim pill appears over the rows' right edge when they overflow — drag it, or click the empty track above/below to page; the wheel still scrolls. (TUI rows are unchanged: `+`/`-` glyphs, terminal colors.)
- **GUI create/rename are inline**: `a`/`r` (or the menu) open an input box in the tree itself — rename replaces the entry's row (keeping its icon), create appears as a new row under the target folder whose icon flips to a folder the moment the input ends with `/`. Enter applies, Escape cancels, same validation as before. Delete keeps its confirm bar, and the TUI keeps its status-line prompts.
- **Name validation** (both frontends): create and rename refuse absolute or drive input (`/x`, `C:/x`, `C:x`) and `.`/`..` segments; on Windows they also refuse `<>:"|?*`, control characters, a trailing dot or space, and reserved device names (`nul`, `con.txt`, `COM1`, `CONIN$`).
- **Auto-reveal** (GUI): switching tabs (or opening a file any way) expands and selects that file in the tree without stealing keyboard focus — VS Code behavior, on by default; off via the Settings dialog or `zide.set("filetree_auto_reveal", false)`.
- **`/` search** (GUI): with the tree focused, press `/` and type — the selection jumps live to the next visible row whose name contains the query (case-insensitive, wraps past the end). The header shows `/query` while typing, in the warn color when nothing matches. Enter keeps the selection, Escape backs out, arrows exit search and navigate. (`/` is needed because plain letters are the j/k/a/r/d/x/p bindings.)
- **GUI header buttons** (right side): new file (+) starts an inline create under the selected folder; collapse-all (⊟) folds every directory back to the top level.
- **Multi-select**: Ctrl+click (GUI) toggles rows in and out of the selection, Shift+click (GUI) or Shift+Up/Down (both frontends) selects a visible range from the last plain selection, plain clicks/nav collapse back to one row (Escape also clears it, after cancelling a pending move). Delete, x/p moves, drag & drop, and copy-path all operate on the whole selection — dragging any selected row moves the group (including dragging straight out of the Ctrl/Shift+click itself; the drag carries the selection as it was when the press started), and a selected folder covers its selected children automatically.
- **The root is targetable** (GUI): click the empty space below the rows and the header highlights — create (`a`/+), paste, and x/p moves then land at the top level instead of inside a subfolder. Any row click clears it. (Drag & drop always had this: dropping on the header or empty space moves to the root.)
- **File clipboard**: with the tree focused, the keys bound to copy, cut and paste (**Ctrl+C / Ctrl+X / Ctrl+V** by default, both frontends) copy, cut, and paste the selected entries as files — paste targets the selected folder (or a file's parent). Copy duplicates recursively, cut moves; both are no-clobber per entry and cut rows render dimmed until pasted. The clipboard is ZIDE-internal (not the OS file clipboard) and clears when the tree root changes.
- **Drag in from Explorer** (GUI): drop files or folders from the OS onto the tree to copy them into the folder under the pointer (at any display scaling, 125%/150% included); drop a file onto the editor area to open it, or a folder to re-root the tree there.
- **Delete confirms in a clickable dialog** (GUI): only a fresh, unmodified `y` press (not a held key's repeat) or the Delete button deletes; Enter, `n`, Escape, Cancel and any other key cancel, as the dialog's label says (chords such as Ctrl+Y do neither); multi-selections show the item count. And a click anywhere off an inline create/rename entry cancels it — no Escape hunt after a mis-click.
- Opening a file that's already open switches to its existing tab instead of duplicating it.
- File decoding validates the entire text. Binary or malformed data is refused; explicit opens can choose a supported encoding, while session restoration and background previews/search skip unresolved files. See **File encodings** above.

### Keys (while the tree is focused)
| Key | Action |
|-----|--------|
| Up/Down or k/j | Move selection |
| Home/End | First / last row |
| Enter | Expand/collapse dir, or open file (focus moves to editor) |
| Right / Left | Expand dir / collapse dir (or jump to parent) |
| a | New file — end with `/` for a folder; nested paths like `sub/file.txt` create intermediate folders |
| r | Rename (no-clobber; renaming updates open tabs, including files inside a renamed folder) |
| Shift+R | Refresh from disk (expansion and selection, multi-selection included, preserved) |
| d | Delete — clickable Delete/Cancel dialog in the GUI, status-line prompt in the TUI; only `y` (or clicking Delete) confirms, any other key cancels; directories delete recursively; deletes the whole multi-selection |
| Backspace or u | Re-root the tree at the parent directory |
| o | Open the selected folder (or a selected file's folder) as the project root — see *Open folder* under Documents / File I/O |
| x then p | Move: x marks the selected entry (or the whole multi-selection), p drops into the selected folder (or a selected file's folder); no-clobber, open tabs follow |
| Shift+Up/Down | Extend a range selection row by row (both frontends) |
| Ctrl+C / X / V | File clipboard (whichever keys are bound to copy / cut / paste): copy / cut the selection, paste into the selected folder |
| / | (GUI) Incremental name search — type to jump, Enter/Escape ends, arrows exit and navigate |
| Escape | Cancel a pending x move first, then clear a multi-selection; otherwise return focus to the editor |

Ctrl/Alt chords (Ctrl+P, Ctrl+B, ...) still work while the tree is focused; select-all and word delete do nothing there, so the document behind the tree is never edited (see *Keyboard focus* under Command System).

### Mouse
- Single click: selects the row only — except on a folder's chevron (`+`/`-` in the TUI), which toggles immediately; clicking the header's up-button goes up one folder. Ctrl+click toggles multi-selection, Shift+click range-selects; while an inline create/rename is open, clicking anywhere else cancels it
- Double click (400ms, same row): expands/collapses a folder or opens a file — a stray single click never opens or collapses anything
- Wheel over the panel: scrolls the tree independently of the editor
- Drag & drop (GUI): drag a row ~5px to start a move — the drop target highlights (a folder, a file's folder, or the header/empty space = root) with a live "Move X -> Y" status; release performs it. Dropping into the same place or into the moved folder itself is rejected. No drag ghost or edge auto-scroll yet
- Drag the panel's editor-facing edge (GUI, ⇄ cursor): resize the panel — the width persists to init.lua on release; a separator line marks the edge
- Right-click (GUI): context menu (New / Rename / Delete / Copy Path / Copy Relative Path / Reveal in Explorer / Open as Root / Up One Folder / Move Tree to Left-Right / Refresh / Reveal Current File); the side choice persists to init.lua
- Header buttons (GUI): new file and collapse-all on the right, up-one-folder on the left

### TUI specifics
- Rendered as a column band with a `│` separator; the terminal cursor hides while the tree is focused (the selection bar takes its place) and the panel header brightens
- Panel is skipped (and focus released) below 40 terminal columns; width is capped at half the terminal
- Create/rename/delete prompts appear on the status line, same as Save As (the delete prompt — `[Y]es / any other key cancels` — shows the count for a multi-selection; only `y`/`Y` deletes, Enter cancels, and Ctrl/Alt/Super chords are ignored)
- Multi-select is keyboard-driven: Shift+Up/Down extends, Escape clears, and d/x/p operate on the whole selection through the same core as the GUI
- Nerdfont icons via `tui_filetree_icons` (see the icons bullet in Basics)

### Commands (palette)
| Command | Description |
|---------|-------------|
| `toggle_filetree` | Show/hide the panel (Ctrl+B) |
| `filetree_reveal` | Expand to and select the current file and give the tree the keyboard — from an extra window it focuses the main window (also View menu). Works when the root is a drive root or `/` |
| `filetree_refresh` | Rescan from disk |
| `filetree_collapse_all` | Fold every directory back to the top level |
| `filetree_set_root` | Make the selected folder the project root (the tree's `o`) |
| `filetree_copy_path` | Copy the selected entry's absolute path to the clipboard |
| `filetree_copy_relative_path` | Copy the selected entry's root-relative path (native separators) |
| `filetree_reveal_explorer` | Show the selected entry in the system file manager (Explorer `/select` on Windows, `open -R` on macOS, `xdg-open` of the parent elsewhere); a launcher that fails is reported in the status bar |
| `toggle_tui_icons` | Toggle the TUI tree's nerdfont icons live (the TUI has no settings panel); persists to init.lua |
| `filetree_copy` / `filetree_cut` | Fill the file clipboard from the selection (the copy/cut keys while the tree is focused) |
| `filetree_paste` | Paste the file clipboard into the selected folder (the paste key) — cut moves, copy copies recursively |

### Git status colors
Tree rows use the shared asynchronous Git status service: **untracked** and **added** files green/teal, **modified** amber, and any directory containing changes rolls up as modified; children of an untracked folder inherit untracked. In the GUI each changed row also gets a right-edge **badge**: an A/M/D/U letter on files, a `•` dot on directories rolling up changes. Refresh runs on panel load, manual refresh (Shift+R / `filetree_refresh`), after create/rename/delete, after saves, and on background deadlines. Outside a repository (or without Git installed) rows stay uncolored. Colors are theme fields overridable via `zide.set("color_git_added" | "color_git_modified" | "color_git_deleted" | "color_git_untracked", "#hex")` and the `tui_color_git_*` equivalents. Disabling tree colors leaves the shared Git service available for Changes and gutter comparisons, and the same four color fields also paint the editor gutter's change marks (see *Tasks, Problems, Git and debugging*).

### Settings
Settings dialog (GUI) or `zide.set` in init.lua: `filetree_visible` (bool, default true), `filetree_side` ("left"/"right"), `filetree_width` (120–600 px), `tui_filetree_width` (16–80 cols), `filetree_root` (path text field in the dialog — Enter applies and persists), `filetree_git_colors` (bool, default true — controls tree coloring; shared Git work continues for Changes and gutters), `filetree_auto_reveal` (bool, default true — select the active file in the tree on tab switch), `tui_filetree_icons` (bool, default false — nerdfont icons in the TUI tree; needs a Nerd Font terminal font), `filetree_font_size` (GUI, points, 0 = theme default — row height, text, and icons all scale together), `filetree_icon_scale` (GUI, 50–200 — icon size as a percentage of the row font, default 90). The TUI's sizes are the terminal's font size — nothing to configure there.

## Performance
- **Gap buffer** text storage — inserts/deletes at cursor are O(1) amortized instead of O(n) memmove
- Undo history capped at 100 operations per document (configurable via `zide.set("max_undo_history", N)`, 0 = unlimited)
- Command palette names cached (no per-frame allocation)
- Workspace search: the Replace confirmation row counts its targets from cached path keys instead of probing the disk every frame
- Delete operations record history before modifying buffer (single allocation instead of double-copy)
- GUI: monospace font optimization (char_width multiplication replaces font API calls)
- GUI: cursor blink uses animation timer instead of continuous refresh
- GUI: tab expansion columns pre-computed once per line, not per wrap row
- TUI: vaxis cell-level diffing (only changed cells sent to terminal)

