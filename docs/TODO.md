# ZIDE TODO — the feature backlog

The one place where not-yet-built features live, so nothing survives only in a chat log. Add new
ideas here with a date; mark an item **DONE** (with the date) when it ships. Started 2026-09-30 as
a consolidated suggestions list from three sources: that day's feature review (every "missing"
claim checked against the code), the user-requested terminal items from the same conversation,
and the feature list at the end of the 2026-09-28 bug scan (that report has since been deleted;
every finding in it was fixed on 2026-09-29). Anything not marked DONE is not started.

One honesty note: the bug-scan list was written before the 2026-09-29 fix round, so sub-items
that referenced scan bug IDs (selection indent, multi-cursor copy/cut distribution, GUI terminal
layout input, IME commit) are already fixed and have been removed or trimmed here.

Legend: **N** = native Zig, **L** = buildable as a Lua extension on the public API; size **S/M/L**.

---

## User-requested (2026-09-30)

- **Rearrangeable panels, Zed / VS Code style** (N, L) — user, 2026-10-18. Every docked
  panel — the file tree, the Snippets panel, the search panel, and terminals (the item right
  below) — should move between the left, right and bottom edges, by dragging its header to
  another edge (a drop zone lights up while dragging) and from a right-click menu ("Move to
  Left / Right / Bottom"), with the arrangement remembered in init.lua. Before this: only the
  tree and the Snippets panel moved, left ↔ right, by GUI menu. Pieces: a shared "dock" model
  in the core (side + order + size per panel, the bands laid out from it instead of each
  frontend's hand-written rules), drag-and-drop between edges in the GUI (the file tree's
  drag-in code is the precedent), menu/command moves in the TUI (no mouse on Windows), panels
  stacking on one edge (tabs or a split, decide), and the terminal becoming a dockable panel
  too. Supersedes the two-sided `filetree_side` / `snippets_side` settings once done (keep
  them working).
  - **Step 1 DONE 2026-10-18 (built in Zed with the API, not Claude Code; smoke test
    pending):** the terminal panel — the item below — plus palette moves for every panel.
    As built: `Editor.terminal_panel` (index into `terminals`, one shell), `terminal_panel_*`
    fields/settings (`side` bottom|left|right, GUI width/height, TUI twins), a new
    `KeyboardOwner.terminal_panel` / `FocusTarget.terminal_panel` (lowest panel precedence),
    `Editor.movePanel(DockPanel, DockEdge)` behind `move_filetree_left/right`,
    `move_snippets_left/right`, `move_terminal_panel_left/right/bottom`; actions
    `toggle_terminal_panel` (now on Ctrl+Shift+` — `open_terminal_right` lost its key),
    `hide_/close_terminal_panel`, `dock_terminal`, `undock_terminal`; `spawnShell` split out
    of `openTerminalSplit`. GUI: `terminalPanel` band in `editorArea` (a `center_col` box
    wraps the panes so the bottom strip sits between the side bands), `handleBandResizeAt`
    generalizes the edge drag to a bottom edge, the terminal grid drawing is shared with
    `terminalPane` (`terminalCellMetrics` / `fitTerminalGrid` / `drawTerminalGrid`),
    `handleTerminalKeyEvents` takes the owner. TUI: `drawTerminalPanel`, `handleTerminalKeyFor`
    shared with panes, `positionTerminalPanelCursor`, `[TERMINAL PANEL]` status. Tests: core
    ("terminal panel: …" ×2), TUI, GUI (`zig build test-gui`). Docs: *The terminal panel*
    under Embedded Terminal.
  - **Next steps, in order:** (2) a shared dock model in the core so the tree / Snippets /
    search panels can take the bottom too, with a user-chosen order on a shared edge;
    (3) drag a panel header to another edge in the GUI (drop zones); (4) several panels on
    one edge as tabs, and several shells in the terminal panel (tabs + `next_terminal`).
- **Dockable terminal — move it to the sides like the file tree** (N, M). **DONE 2026-10-18**
  as the terminal panel (step 1 above): a real docked band with `terminal_panel_side` /
  `terminal_panel_width` / `terminal_panel_height` settings (the file-tree precedent won over
  placement commands for splits), `dock_terminal` moves a Ctrl+` pane into it. Original
  motivation (user, 2026-10-08): run Claude Code or any LLM CLI in a full-height side terminal
  as a chat column while a bottom terminal stays free for commands — commands run inside
  Claude Code render in a tiny collapsible box and feed their output back to the model for
  nothing. Still open from the ask: nothing restores the panel's shell across runs (a shell
  cannot be restored; the side and size are).
- **Multiple terminals** (N, S–M). The core already stores a list of terminals, so the model
  allows it; what's missing is the front door. Add a `new_terminal` command that always creates
  another shell (Ctrl+` already opens another one each time), a way to cycle or pick them
  (`next_terminal`, or a picker listing Terminal 1..N with their running programs), and a
  status-bar hint for which one is focused. Pairs with "start the shell in the workspace root"
  under Terminal gaps below.

- **Hotkey convention overhaul + a way to edit hotkeys** (N, M) — user, 2026-10-08. Windows
  eats or repurposes many chords (terminals intercept Alt combos, Ctrl+Alt doubles as AltGr,
  Ctrl+Alt+arrows are the Intel display-rotation hotkeys, Ctrl+- is byte 0x1F in legacy
  terminals), so the defaults have grown Alt-free twins ad hoc. Plan: the user compiles every
  current binding, we agree conventions (which chords are safe on Windows / in terminals, what
  the twins pattern is) and decide what may break; then build a keybinding editor (Settings
  page or a `keybindings` palette view) with per-binding notes explaining the Windows
  shenanigans to end users. Until then new features get bindings "somewhere" and get sorted
  in that pass — e.g. navigate_back/forward on Ctrl+Alt+Left/Right + F7/Shift+F7, and the
  review keys F8 / Shift+F8 / Ctrl+F8 (F9 family in phase 2 sits on the conventional debugger key).

## Top picks from the 2026-09-30 review

1. **Go back / go forward** (N, S) — **DONE 2026-10-08**: `navigate_back` / `navigate_forward`
   on Ctrl+Alt+Left / Ctrl+Alt+Right with F7 / Shift+F7 as Alt-free twins (Alt+Left/Right stayed
   on pane focus — swap them in init.lua if browser-style muscle memory wins). Every jump
   records the caret it leaves (`src/core/nav_history.zig`); see Documentation.md → Navigation.
2. **Language-server round-out** (N, M). Hover, rename and formatting exist, so each remaining
   piece is mechanical: find references — **DONE 2026-10-08** (tool-panel References view with
   excerpts, Shift+F12) — signature help while typing a call — **DONE 2026-10-08** (popup above
   the caret, auto on `(`/`,`, Ctrl+Shift+Space, `signature_help_auto`) — document outline / go-to-symbol picker and
   workspace-wide symbol search — **DONE 2026-10-08** (Ctrl+F12 / Ctrl+T on a generic pick-list,
   `src/core/picker.zig`, that the Lua runtime can reuse) — and auto-triggered completion — **DONE
   2026-10-08**: the popup opens on trigger characters and identifiers, filters by the typed
   prefix, refreshes as you type; `completion_auto` turns it off. Bug-scan extras also **DONE
   2026-10-08**: `initialize` gets a 60 s timeout, `lsp_stderr` / `open_log` surface server
   output; honoring `textDocumentSync` is still open (ZIDE always sends full text). Remaining
   here: a **peek popup** (user, 2026-10-08): the small
   floating preview of the symbol under the cursor that other IDEs show — the definition's
   first lines in a toast-sized window, without leaving the file (hover already fetches the
   documentation text; peek would reuse goto-definition's reply and the hover view's
   popup). From the bug scan, same area: honor the server's declared
   sync capabilities, surface server stderr somewhere visible, and give `initialize` a longer
   timeout so slow starters aren't declared dead.
3. **Extension runtime v2** (N, M) — the remaining original-vision debt. Document handles so a
   `zide.spawn` callback edits the document it started from (today edits land in whatever tab is
   focused), range get/replace/delete, one undo group per Lua batch, `cwd`/`env`/stdin and a
   cancel handle for run/spawn, events beyond `open`/`save` (change, close, cursor, focus,
   quit), and UI primitives (prompt, pick-list, panel). This is what turns the LLM and
   extension-fetching wishlist items into pure Lua. Design references (user, 2026-10-08): Lite XL's
   plugin API (source kept locally in `references/lite-xl-master`) and Neovim's Lua API — its modal
   editing is irrelevant, but the shape to borrow is there: `nvim_buf_*` buffer handles, the
   autocmd event list (BufEnter / TextChanged / CursorMoved / BufWritePre / VimLeavePre map onto
   our focus / change / cursor / save / quit), `vim.ui.select` / `vim.ui.input` as the pick-list
   and prompt primitives, and lazy.nvim-style `github:user/repo` fetching. Read those at
   neovim.io/doc (`lua-guide`, `api`, `vim.ui`); no Neovim checkout needed.
4. **Open Folder + recent projects** (N, M) — **DONE 2026-10-08** except the session part:
   `open_folder` (Ctrl+Shift+O; GUI native dialog + File > Open Folder, TUI path prompt),
   `recent_projects` picker (last nine, persisted in `~/.config/zide/recent_projects`; GUI
   also File > Recent Projects), tree `o` / `filetree_set_root` / context-menu *Open as Root*
   to re-root into the selected folder, and `zide <folder>` launches feed the list. Opening a
   project restarts language servers; recovery snapshots keep the startup workspace (documented).
   Still open: sessions that remember splits/windows (today a session records documents only),
   and a recent-projects list rendered on the Welcome screen (it currently points at the
   palette command). Polish (user, 2026-10-08): a mouse way to re-root into a folder from the
   tree — Ctrl+click is already multi-select in the GUI tree, so it would be Ctrl+double-click
   or Alt+click on a folder.
5. **Folding + bracket polish** (N, S+M). Bracket half **DONE 2026-10-08**: matching-bracket
   highlight (TUI reverse video, GUI outline in the caret color), `goto_matching_bracket` on
   Alt+M, and smart Enter between `{}` / `()` / `[]` — `src/core/brackets.zig`, a plain
   nesting-aware scan (syntax-aware matching that ignores strings/comments is a later
   refinement). Still open: code folding (functions, markdown headings — the medium-sized one,
   since it has to cooperate with the word-wrap row math). Note: auto-closing brackets/quotes
   already exist — the 09-30 chat review wrongly listed them as missing.

## TUI path prompts (user, 2026-10-08)

- **Tab completion in the TUI's path prompts** (N, S–M). The Open Folder and Open File prompts
  are bare text fields; Tab should complete the current path segment and cycle through the
  matching folders/files on repeated presses (Shift+Tab backwards), with the candidates shown
  on the line above. Same input helper as the other prompts, so it lands in one place.
- **Modern Windows pickers** (N, S–M). dvui's native dialogs go through tinyfiledialogs, which
  on Windows uses the legacy `SHBrowseForFolder` tree ("Browse For Folder", no address bar or
  search) and the old `GetOpenFileName` file dialog. The modern Explorer-style ones are the
  Common Item Dialog (`IFileOpenDialog`, with `FOS_PICKFOLDERS` for folders): a small COM call
  in the GUI's Windows branch (CoInitialize → CoCreateInstance → SetOptions → Show → GetResult →
  `IShellItem.GetDisplayName`), roughly a hundred lines of vtable plumbing in Zig.

## Quick open on big trees (user, 2026-10-08)

- **Make the file list faster to get through when the root is huge** (N, S–M). Opened from
  the top of the whole Zig folder, quick open lists everything and the 200-match cap fills with
  noise. Ideas, cheapest first: rank recently opened / open files first and show them before
  typing; match against the full relative path so `core/ed` narrows by folder; let a trailing
  `/` or a `dir/` prefix scope to a folder; show the directory dimmed after the name; raise or
  page the match cap. (The Left/Right ghost-glyph bug found in the same test was fixed
  2026-10-08 — TUI prompts no longer type functional keys.)

## Terminal gaps (belongs with the user-requested items)

- **GUI terminal selection, copy/paste, scrollback** (N, M). The GUI terminal has none of the
  three today (Ctrl+Shift+C/V just send ^C/^V to the shell). Scrollback is also the one real
  item on the TUI not-yet list.
- **Emulator gaps that bite on Linux** (N, M). Terminal-identity and cursor-position replies
  (fish 4, nushell and neovim stall probing for them today), DEC line-drawing charset (ncurses
  borders show as `lqqqk`), wide-glyph cells, bracketed-paste and mouse-mode passthrough to the
  child program, full-reset handling, and starting the shell in the workspace root instead of
  wherever ZIDE was launched from.
- **IME preedit in terminal panes** (N, S–M). Composition is sent once committed but not drawn
  while composing — draw the uncommitted text at the caret.

## Two kinds of terminal (user, 2026-11-12 — the terminal panel's first on-screen run)

Both notes came out of that run; neither is started. How the two kinds differ today is written
up in Documentation.md (*Embedded Terminal → Two kinds of terminal*). **Decided the same evening
(user): both wait for the hotkey listing remake** (*Hotkey convention overhaul* under
User-requested) — the keys are being redone anyway, so nothing here is built before that pass.

- **The terminal key as a real toggle** (N, S). "Kind of weird having two different commands
  to swap back and forth": Ctrl+` leaves a terminal (pane or panel) for the editor, but pressed
  again in the editor it opens **another** terminal instead of going back to the one just left —
  `Editor.toggleTerminal` ends in `self.openTerminal()` for every editor pane. So the way back
  into the panel is the other key (Ctrl+Shift+`), the way back into a pane is a click or F6,
  and a double tap leaves a stray shell behind. Proposed: from the editor, Ctrl+` focuses the
  terminal this window used last — the panel (shown again when hidden) or a terminal pane —
  and opens a new bottom terminal only when the window has none; further ones come from a
  `new_terminal` command (palette + View menu — *Multiple terminals* above already asks for
  it, and the View menu has no entry for a plain terminal at all today). Ctrl+Shift+` stays
  the panel's own key. VS Code's defaults are the same idea: Ctrl+` toggles the terminal,
  Ctrl+Shift+` makes a new one. To decide: a key for `new_terminal` now, or in the hotkey pass.
- **A right-click menu for terminal panes, and a way to see which kind you are in** (N, S).
  The panel's *Move Terminal to Left / Right / Bottom* does nothing on a Ctrl+` terminal,
  because that one is a split pane — and little on screen says so: a terminal pane has no
  title row and no right-click menu (GUI `terminalPane` only takes the press to focus), the one
  hint is the status bar (*Terminal* vs *Terminal panel*). Proposed: a right-click menu on
  terminal panes — *Dock in Panel* (it can then go left / right / bottom; greyed out, with the
  reason, while the panel already holds a shell), *Move to New Window*, *Close Terminal*, and
  *Copy* / *Paste* once the selection item under *Terminal gaps* exists. To decide: also give
  panes the panel's one-line title row ("Terminal — Ctrl+` back to the editor"), which costs
  a row per terminal. The TUI has no mouse menus; its status row already tells the two apart.
  Longer term, step 4 of *Rearrangeable panels* (several shells in the panel, as tabs) makes
  the pane kind optional.

## Overlay look and default themes (user, 2026-10-08)

- **Opaque overlay panels** (N, S–M). The palette, picker, find bar and prompts draw a
  translucent bar over the code, so the text behind bleeds through and long rows ran off the
  window (rows are clipped now). Quick open already draws an opaque, bordered, top-centered
  panel — move the palette and picker (and the other overlays) to that style, with a width cap.
- **Revisit the default themes** (N, M). The user finds the overlay/banner colors hard on the
  eyes; pair with the configurable caret/bracket colors item: review the three presets' overlay
  and selection colors for contrast, and consider shipping one more calm preset.

## Tool panel polish (user, 2026-10-08)

- **Selection marker as an icon** (N, S). The GUI tool views mark the selected row with a text
  `>`; an SVG/TinyVG arrow (the panel chrome already uses Entypo icons) would be easier to spot.
  Also audit the panel's width: rows should truncate inside the window rather than widen it.

## Prompts (user, 2026-10-08)

- **GUI unsaved-changes prompts as real dialogs** (N, S). The close-tab / quit `[S]ave [D]iscard
  [C]ancel` banner is drawn inside the editor in the theme's own colors and font, so it blends
  in and is easy to miss — and in a very small window it is practically invisible (user,
  2026-10-15: shrinking the window to make the Snippets panel hide itself left the prompt
  nowhere to be seen). Make it a modal floating window like the encoding and recovery
  dialogs (buttons + the same S/D/C keys), and audit the other in-editor banners
  (overwrite/reload, Git stage, task save-before-run) for the same treatment.

## Status messages (user, 2026-11-12)

- **Messages that are easy to see** (N, S–M). "Make pop up text have more visibility, like
  maybe a contrasting color, so when something happens you can easily see it." Today a status
  message — "Saved", every refusal, every error — is drawn in the status bar's own text color
  between the line / column block and the file name (GUI; the TUI centers it), looks the same
  whether it is a note or a failure, and is gone at the next key press or click: no minimum
  time on screen. A long one is cut off — the GUI clips it before the file name, the TUI at
  half the screen width: on 2026-11-12 "Deleted from my-snippets.lua: Hello world (the one
  from snippets-zig.lua is back)" lost its ending in a window about 1000 px wide.
  `Editor.status_message` is one slice assigned in about 290 places, so the change belongs in
  the two painters and one small core helper, not at the call sites. Proposed: (1) a **fresh**
  message (the text changed) is drawn as a filled block in a contrasting color pair — new
  theme fields, GUI and TUI — for a few seconds, then settles into today's look; (2) while
  fresh it may cover the rest of the bar instead of being cut, and the long delete message
  gets shorter; (3) levels — note / warning / error — through a helper, failures in the error
  color, the existing sites staying "note" until moved over; (4) maybe a `show_messages`
  command listing the last few, for the one that was replaced before it was read. To decide:
  whether a fresh message stays its few seconds even while you keep typing. Alternative to
  (1): a small box in a corner of the editor that fades out, like VS Code's notifications.
  Relatives: *GUI unsaved-changes prompts as real dialogs* (Prompts, above) and *Revisit the
  default themes* (Overlay look).
  **User, the same evening:** likes the proposal — taken as (1)–(3), the block in the status
  bar rather than the corner box — and wants it "sooner than later".
  **DONE 2026-11-13 — (1), (2) and (3)** (go given that morning; as built in Documentation.md
  → *Status messages*): a new message is a filled block for `status_message_seconds` (4;
  0 = off; Settings dialog row), keeps that time through key presses and clicks, then settles
  into the old plain text; the block may cover the rest of the bar, so nothing is cut; three
  levels with their own colors in every preset (6 new theme fields per frontend) — about 190
  of the 290 messages now say whether they are a warning or an error, through
  `Editor.setStatus`; `zide.status(msg, "warning" | "error")` from Lua; the long delete
  message is "Deleted <name> — the one from snippets-zig.lua is back". Decided on the way: a
  message keeps its time while typing; a direct `status_message = ""` (a hint that stopped
  being true) still removes it at once; progress and background chatter ("Auto-saved 2
  file(s)", "Waiting for language server") is a fourth, `quiet` level that is never
  highlighted. **Still open:** (4) a `show_messages` list of the last few; the corner box
  was not built.

## Safety and trust

- **Workspace trust prompt** (N, S). One "Trust this folder?" gate on first open, remembered
  per path. Groundwork for extension fetching and any future project-local init.lua / tasks /
  debug configs, and it de-fangs repository-local hooks and filters.
- **Local history** (N, M). Recovery snapshots delete themselves on a clean exit; local history
  would keep a per-file trail of past saves (timestamped copies under the config dir, pruned by
  age/size) with a diff view — the Git preview UI already renders diffs. A safety net between
  lazygit checkpoints. v1 needs no file watcher: capture ZIDE's own saves via the existing save
  hook. The vetted libuv wrapper is available if watching external edits ever becomes wanted.
- **Read-only and external-change polish** (N, S). Mark read-only files from the file mode
  instead of failing at save time; keep undo history across an external reload (cleared today);
  re-poll files that vanished and came back (they stay flagged forever today).

## Editing

- **Multi-cursor / block commands still missing** (N, S). Join lines, sort lines, upper/lower
  case, duplicate or move a selected block as a unit, and copy/cut taking the whole line when
  nothing is selected.
- **Reopen closed tab** (N, S) — **DONE 2026-10-08**: `reopen_closed_tab` on Ctrl+Shift+T and
  in the GUI File menu; last 20 closed files with their caret, open-again files skipped.
- **Regex in find/replace and workspace search** (N, M). No regex engine in std — a small
  backtracking engine (fun sub-project) or a vendored one. Comma-separated include / exclude
  lists in the search panel do not need it (corrected 2026-11-12: `glob` in `editorconfig.zig`
  already matches such patterns). Both are steps in the proposal under *Find and replace
  round-out*.

## Snippets panel (user, 2026-10-14; plan in ~/.claude/plans/playful-herding-wave.md)

A Kate-style Snippets side panel: syntax skeletons by plain name ("Print", "For each item")
in collapsible groups, click to insert, a preview with plain-language notes — so a learner
does not need to know the syntax before completion can finish it.

- **Step 1, checkpoint 1: engine + GUI panel + starter set** (N, L) — **DONE 2026-10-15**:
  `snippet_panel.zig` model, `.snippets` keyboard owner, `toggle_snippets` on Ctrl+Alt+B,
  `group`/`notes`/optional `prefix` on `register_snippet` (`~slug` command names), the four
  `snippets_*` settings, 54 compiler-checked Zig skeletons in `snippets-zig.lua`, and the
  self-upgrading bundled file (pristine copies replaced, edited ones kept). Smoke-test round
  (user, 2026-10-15): `snippets_double_click` (a click selects and keeps the preview, a
  double-click inserts), the preview takes a short list's free space and scrolls long notes
  (wheel or scrollbar), dragging either band's edge far past its minimum hides it (width
  kept), and the five `snippets_*` rows in the Settings dialog (pulled up from checkpoint 2).
- **Step 1, checkpoint 2: TUI band** (N, M) — **DONE 2026-10-15**: `drawSnippetsPanel`,
  `snippets_band` hit-testing, `handleSnippetsKey`, both bands' width math (tree outermost,
  saturating, the panes keep 40 columns), click-selects-then-click-inserts (no hover in the
  TUI), the preview scrolling long notes (Shift+Up/Down, Shift+PgUp/PgDn, the wheel; a `▼`
  marker row) and wrapping long code as the GUI does, `│` guides under open groups.
- **Step 2, checkpoint 1: save as snippet** (N, M) — **DONE 2026-10-17**: `snippet_file.zig`
  (the marked-block format of `extensions/my-snippets.lua`, atomic rewrites),
  `snippet_form.zig` (the form state both frontends share), `Definition.body`/`source` and
  `removeSnippet`, `my-snippets.lua` loads last, `snippet_save_selection` on Ctrl+Alt+S, the
  GUI dialog and the TUI bottom band.
- **Step 2, checkpoint 2: edit, delete, copy to mine, filter** (N, M) — **DONE 2026-10-17**:
  right-click / F2 / Delete on panel rows (mine: edit and delete, with a rename moving the
  block; bundled: copy to my snippets), `Mode.snippet_delete_confirm` (GUI dialog, TUI status
  line), a hand-edited block opens the file instead, and type-to-filter in the panel
  (`snippet_panel.View.filter`; GUI box under the header, TUI `/text` in the header).
- **Step 3 (maybe): mirrored blanks** (N, M). The same field number in two places (`list` in
  the ArrayList skeleton) updating together; the bundled bodies hard-code repeats today and
  the notes say so.

## Debugging and tasks

- **Breakpoints that follow edits** (N, S). Shift line markers when text is inserted/deleted
  above them, carry them across rename/delete, reclaim unused source slots (the per-workspace
  source cap can be exhausted by toggling once in many files). Then: watches and conditional
  breakpoints (both on the debugger's own deferred list).
- **Task/Problems quality of life** (N, S). Auto-open Problems when a task fails; clickable
  Task Output locations for Lua matchers (Enter works today, clicking doesn't).

## Git area (you commit via lazygit — nothing here replaces that)

- Branch name in the status bar, and staging individual hunks from the Changes panel (N, M).
  The bug scan also suggested a commit box in the panel — treat as low priority given the
  lazygit workflow; it would be for other users of ZIDE someday.
- Make status handling survive huge untracked trees — today it gives up entirely past the size
  cap and retries every 10 s (N, S).

## Code review reader (user, 2026-10-08; brief + plan notes in CodeDiffViewerIdea.md)

- **Phase 1 — foundation: DONE 2026-10-08.** `review` view (Ctrl+F8) with verdict glyphs
  `[x]` / `[!]` / `[ ]`, `n/N reviewed`, A / W toggles, D classic diff, O / Enter open,
  F8 / Shift+F8 next / previous changed file from anywhere, a `Review 2/9 [x]` status-bar
  segment. Verdicts live per repository in `~/.config/zide/review/<hash>.json`, keyed to git
  blob ids, so any edit (yours or an AI's) resets them; approving also stages
  (`review_stage_on_approve`). Baseline = last commit, or a checkpoint pinned with
  `review_set_baseline` (`review_follow_head` goes back), remembered per repository.
- **Phase 2 — the reader: DONE 2026-10-08.** A read-only `Review: <file>` tab built from
  `git diff -U999999` (`src/core/unidiff.zig` → `src/core/review_reader.zig`): soft tints on
  added / replaced lines, deleted lines kept as dimmed ghost rows, real line numbers in the
  gutter, unchanged stretches over six lines folded into a `··· N unchanged lines ···` row
  (Enter unfolds; `review_expand_all` / `review_collapse_all`), Enter elsewhere opens the real
  file at that line, F9 / Shift+F9 walk the changes, Ctrl+F9 the classic diff (now against the
  baseline), rebuilt in place when the file or the baseline changes. `Document.readonly` is now
  enforced (`prepareRanges` + undo/redo, one status message from the command dispatcher) — the
  `lsp_stderr` tab got that for free. Five new theme colors per frontend.
- **Deferred:** word-level highlights (`--word-diff=porcelain`), scrollbar change markers (GUI;
  needs its own track geometry), `-w` / `--ignore-cr-at-eol` toggle, refresh on window focus (no
  focus hook in either frontend), a `review_checkpoint_default` setting, `review_clear_all`,
  hunk-level verdicts, AI intent notes (sidecar file, display-only, never affecting verdicts),
  LSP hover / go-to-definition from the reader, several reader tabs, GUI double-click on a
  folded `··· N unchanged lines ···` row (Enter works), a setting for the number of context lines
  kept around a change (3 today), tokenizer state across ghost rows in block-comment languages
  (a folded stretch can hide a `/* … */` pair; harmless in Zig), and the docs' wrong claim that
  TUI git gutter glyphs use the git colors (they use the gutter separator color).
- **QoL asked for on 2026-10-08 (phase 1 smoke test):** GUI icons (SVG / TinyVG, like the
  panel chrome) for the `[x]` / `[!]` / `[ ]` verdict glyphs — **DONE 2026-10-09** (the
  public-domain CFPB pack in `src/icons/svg` plus ZIDE's own shapes in `src/icons/svg/zide`,
  generated by a small script — rounded rects, four-arc circles, ring arcs — so nothing needs
  a credits file; drawn through `src/frontend/icons.zig`: verdict column, dialog buttons, tree
  chrome, debugger rows); still text-only: tab close / modified marks, the status bar, the
  search panel's toggles, diagnostics in the gutter; a side-by-side comparison window
  (old and new as two read-only documents in a split with locked scrolling) as an alternative
  to the inline reader; and the Changes panel's own `git_diff` preview — plain uncolored rows
  in the modal dialog's table — rendered as colored text in a wider window (the review's D /
  Ctrl+F9 already open a tinted read-only `Diff:` tab instead, 2026-10-09; the Changes panel
  could reuse it). The GUI tool dialogs became DVUI grid tables on 2026-10-09 (columns for
  Changes and Review, click anywhere on a row to select, selection follows the keyboard);
  sortable headers and resizable columns are available in the widget if wanted; the last
  column takes the remaining width, so a path wider than it is cut at the table's edge (a
  horizontal scrollbar would need the column sized to the longest path). The table has
  a fixed height (360 px) so the dialog never outgrows its window; a height that follows the
  row count would need the dialog to re-fit itself each time the list changes (it does so
  today only when the content outgrows the window). Phase 2's reader is the answer for
  reading; these are the extras.

## Appearance and accessibility

- **Screen-reader support via AccessKit** (N, L). The vendored dvui ships an `accesskit` build
  option that ZIDE never enables; the custom-drawn editor pane would additionally need manual
  node pushes (document text, caret, line numbers, tab list). A stated project value, nothing
  exists yet, and essentially no small IDE has it — a real differentiator. Pairs with the
  existing high-contrast theme.
- **GUI zoom + system font by name** (N, S). Ctrl+= / Ctrl+- / Ctrl+0 driving `mono_font_size`,
  and a `mono_font_family` lookup (Windows Fonts folder + registry, Linux `fc-match`) so fonts
  aren't limited to a file path. Keep the Nerd Font caveat for tree icons.
- **Theme shorthand** (N, S). `#rgb` three-digit colors and ANSI-index TUI colors.
- **Configurable caret / bracket-highlight colors** (N, S) — user, 2026-10-08. The bracket
  outline reuses the `cursor` color, so anyone who themes around blue loses both the caret and
  the match marker. Add `color_bracket_match` / `tui_color_bracket_match` theme fields (plus
  template entries and the docs' field counts), and consider a separate caret-outline color.
- **Colored folder guides, Kate-style** (N, S) — user, 2026-10-15. Each open folder's indent
  guide (and, to match, its folder icon) gets its own color from a small cycling palette, so a
  deep hierarchy in a big code base reads at a glance (`zig-out` one color, `bin` inside it a
  second, `fug` a third). Needs: per-depth (or per-folder) palette fields in both themes
  (`color_guide_1..n` / `tui_color_guide_*`), the file tree and the Snippets list drawing
  their guides from it, the TUI's `│` columns too, and tinted folder icons — the GUI's TinyVG
  folder icons are already tinted at draw time (`renderIconTinted`), so matching colors may
  need no new art; the user can draw variants in Inkscape otherwise. One color = today's
  `panel_border` look, which stays the default.

## Built on the runtime (the v2 dogfoods)

- **LLM commands via zllm** (L once runtime v2 lands). Explain/rewrite the selection through
  the sibling zllm CLI with `zide.spawn`, results into a panel or pick-list. Off by default,
  zero native code — and it exercises exactly the v2 APIs (document handles, range edits, UI
  primitives) that need designing.
- **Zig test runner** (N+L, M). Run the test under the cursor or the file's tests
  (`zig test --test-filter` / `zig build test`), parse failures into Problems (the zig problem
  matcher already exists), per-test pass/fail in the gutter or status bar. The other flagship
  v2 dogfood.
- **Extension fetching** (N+L, M). `zide.install("github:user/repo")` into
  `~/.config/zide/extensions/<name>`, gated behind the workspace-trust prompt, then
  `reload_extensions` does the rest. Verify reload consistency first (the scan flagged
  init.lua-registered commands vs reload; part of that was fixed on 09-29).
- **Word-based completion fallback** (N, S). For languages without a server.

## Documents

- **Markdown preview pane** (N, M). Parser already chosen (md4c; zigmark's license and zmd's
  HTML-only output ruled them out). Render md4c's block tree straight to dvui widgets in a
  split pane rather than going through HTML; the TUI already has styled-cell rendering to
  build on.

## Community on-ramp (when it feels right)

- README with screenshots, a release zip, and CI that runs `zig build test` plus the
  Linux cross-compile — the cross-build is the proven rot detector for platform branches
  (N, S–M). macOS clipboard/pty branches are still absent.

## Larger design projects already on the backlog

- **Per-view scroll/cursor state** — two panes showing one document currently share a viewport
  and fight over ensure-cursor-visible; real fix is a per-pane View struct. Design project.
- **Sessions that record window/split layout** (folded into Open Folder item above).

## Common IDE features still missing (2026-11-12 review)

Asked for directly: "is there anything an IDE commonly has that ZIDE doesn't?" Every item below
was checked against the code that day (a search for the request name, command, setting or theme
field came back empty, or the code was read), and none of it repeats a section above. Grouped
by area, most useful first inside each group. Almost all of it is native work, because it lives
in the painters, the language-server client or input handling; the few Lua-sized pieces say so.

**The order picked on 2026-11-12** (the user's, after reading the list). Nothing below is
started; each pick is talked through before any code is written.

1. **Find and replace in a document**, modeled on Kate's and VS Code's (*Find and replace in a
   document*).
2. **Code actions / quick fixes** and **mouse reach for language features** (*Language
   server*).
3. **Menus for what already exists** and **command palette rows that explain themselves**
   (*Desktop behavior*).
4. **Delete to the Recycle Bin** and **remember the window** (*Desktop behavior*).

**On hold: *Build, run and debug*.** The user's reason: Zig's debugger situation is still in
development and its Windows support is odd, so it gets a closer look (what debugs a Zig
program on Windows today, and how well) before anything is planned. Known already: on this
machine LLDB's adapter does not start at all — `lldb-dap.exe` needs a `python311.dll` that is
not installed. *Zig tasks out of the box* needs no debugger and can go ahead whenever wanted.

### Language server

- **Code actions / quick fixes** (N, M). `textDocument/codeAction` is never requested, so the
  server's fixes ("remove unused variable", "add missing import", "organize imports") cannot be
  reached. Needs: a request for the caret or selection with that line's diagnostics, the titles
  in the generic pick-list (Ctrl+. elsewhere), then applying the reply — a workspace edit (the
  rename path already applies those, and `workspace/applyEdit` is answered) or a
  `workspace/executeCommand` call. A dim marker in the gutter when the caret's line has fixes.
- **Mouse reach for language features (GUI)** (N, S–M). `hover` is a palette command with no
  key, and nothing shows when the pointer rests. Add: a popup after the pointer rests on a
  symbol (the hover text) or on an underlined problem (its message — today that takes putting
  the caret on the line and reading the status bar, or opening Problems); Ctrl+click = go to
  definition (the editor pane reads only Alt and Shift on a click); and References / Rename /
  Hover / Format in the right-click menu, which has Go to Definition alone. Optional twin for
  both frontends: the problem's message dimmed at the end of its line.
- **Highlight the symbol under the caret** (N, S–M). `textDocument/documentHighlight` is never
  requested; without a server, tinting the other occurrences of the selected word is a plain
  text scan of the visible lines. One theme color per frontend.
- **Inlay hints** (N, M). `textDocument/inlayHint` is never requested: inferred types after
  `const x =` and parameter names at call sites (zls offers both). Needs text that is drawn but
  is not in the buffer, in both painters (the review reader's ghost rows are the whole-row
  precedent; hints are the inside-a-line version), and a setting to turn them off.
- **Completion round-out** (N, S–M). ZIDE announces only `insertReplaceSupport` and keeps four
  fields of each item (label, detail, insert text, edit). Missing: the item's kind (function /
  variable / type marker), its documentation beside the list (`documentation`,
  `completionItem/resolve`), the server's own ordering and matching text (`sortText`,
  `filterText`), snippet-style items (`snippetSupport` — a completed call would arrive with its
  arguments as tab stops, and the snippet engine is already there to walk them), and
  `additionalTextEdits` (the import a completion wants to add).
- **Go to type definition / implementation / declaration** (N, S). Not requested; each is the
  go-to-definition path with another method name.
- **Server progress in the status bar** (N, S). `$/progress` is dropped (`handleNotification`
  in `lsp.zig`), so a server indexing a large project looks idle. Show `zls: indexing 40%`.
- **Tell servers about files changed outside the editor** (N, S–M).
  `workspace/didChangeWatchedFiles` is never sent (`client/registerCapability` is acknowledged
  and then ignored), so a server's picture of files that are not open goes stale after a
  lazygit checkout or an AI tool's edits, until `lsp_restart`.
- **Semantic highlighting from the server** (N, L). `textDocument/semanticTokens` is never
  requested. Matters most for the Lua-defined languages, whose table tokenizers cannot tell a
  type from a function. Large (token legend → theme fields, delta updates, both painters); a
  later tier.

### Find and replace in a document

- **Find and replace round-out** (N, M; first pick of 2026-11-12 — the models are Kate's and
  VS Code's bars). Today, read from the code:
  - *Find* (Ctrl+F) is one row: typing searches forward from the caret, Enter goes to the next
    match and wraps, Escape closes. *Replace* (Ctrl+H) adds a second row: Tab switches rows,
    Enter in the replace row replaces the current match and moves on, Ctrl+Enter or Ctrl+A
    replaces all (already one undo step).
  - Always case-sensitive, no whole-word option: `find_case_sensitive` / `find_whole_word` in
    `editor.zig` are never assigned. The workspace search panel has both toggles and ignores
    case by default, so the two searches disagree about the same word.
  - Forward only (`findNext`), and nothing works once the bar is closed (no `find_next`
    command, F3 is unbound).
  - The rows are painted text, not text boxes: characters go on at the end and Backspace takes
    the last one — no caret inside the row, no selecting, no buttons, no mouse. In the GUI
    Ctrl+V does nothing there, and both rows open empty every time with no history, so a
    copied or selected word has to be retyped. 256 bytes per row.
  - Only the current match is marked. The GUI shows `N matches` but not which one the caret is
    on; the TUI shows no count.
  - No regular expressions (their own entry under *Editing*: there is no engine yet), no `\n`
    or `\t` in either row, no replace limited to the selection, no keep-the-case replace.

  The target, from what Kate and VS Code share: rows that are real text boxes (caret,
  selection, paste, Up / Down through earlier searches); toggles for match case and whole word
  (Alt+C / Alt+W in VS Code and already in ZIDE's search panel) and, once an engine exists,
  regular expressions (Alt+R); previous as well as next (Shift+Enter / Enter in the bar,
  Shift+F3 / F3 anywhere, also after the bar is closed); Ctrl+F starting from the selection or
  the word at the caret; `3 of 17` in place of a bare count; every match tinted in the text
  (one theme color per frontend), and the box tinted when nothing matches (Kate); search and
  replace limited to the selection (Alt+L in VS Code, "Selection only" in Kate); Replace /
  Replace All as buttons beside the replace box; every match turned into a cursor (Alt+Enter
  in VS Code — multi-cursor is already there); and from Kate's power bar, escape sequences in
  both rows and `\1` capture groups in the replacement.

  To decide before building (**all answered 2026-11-12 — see the plan below**): regular
  expressions in the first round or later; one bar (VS Code: the replace row unfolds under
  the find row) or Kate's two (a quick bar and a power bar); where it sits (top right over
  the text like VS Code; along the bottom like Kate and today's TUI); and whether the
  workspace search panel's boxes get the same text box and toggles at the same time, so the
  two stop disagreeing.

  **The user's walk-through of both editors (2026-11-12, four screenshots)** — what they
  pointed at:
  - *VS Code's box* (top right of the editor, current file only): an arrow unfolds the replace
    row under the find row; `Aa` match case, whole word and `.*` regular expression sit in the
    find box; *Preserve Case* (`AB`) in the replace box, then *Replace* and *Replace All*.
  - *VS Code's Search tab* — ZIDE's Ctrl+Shift+F panel is its twin and already has search /
    replace / files to include / files to exclude / `Aa` / whole word. What the tab has more:
    *Search only in Open Editors* on the include box, *Use Exclude Settings and Ignore Files*
    on the exclude box, comma lists in both (`libs/*, .py, .html`), regular expressions,
    *Preserve Case*, and Up / Down for earlier searches.
  - *Kate*: the bar runs along the bottom of the editor; a quick "incremental search bar"
    switches to the "power search and replace bar". Named as what Kate has over VS Code:
    **Find All** — every match in the file highlighted, so a long file can be scrolled and
    stopped at any highlight — and **search in selection only**. Its modes: plain text, whole
    words, escape sequences, regular expression, with a match-case toggle beside them.
    (Common ground, for the record: VS Code tints the other matches too while its box is
    open, only faintly, and its icon beside the arrows is *Find in Selection*.)

  **The plan — agreed 2026-11-12 with the user's picks (marked below); not started, waits
  for the go.**
  - *Where*: one bar along the bottom of the editor area in both frontends — **the user's
    pick**, Kate's place (Zed has the same bar at the top). The TUI's bar is there today; the
    GUI's is a see-through strip across the top.
  - *It stays open while you edit.* Today's bar is a mode that takes every key until Escape;
    this one is a small panel with its own keyboard focus, like the search panel.
  - *One bar.* Ctrl+F shows the find row; the replace row unfolds under it from Ctrl+H or
    from a toggle on the bar named for what it does (`R`, hint "Replace row"). **The user's
    point**: Kate's switch to its power bar and Zed's "Replace" toggle are the same unfolding
    as VS Code's arrow, so one bar or two is only presentation — "just call it replace or
    [R]". The short `R` keeps it apart from the *Replace* button inside that row.
  - *Options are compact toggle buttons with hover hints* that say what they are — **the
    user's pick**: `Aa` match case, `W` whole word, `.*`, `Sel` in selection only, `\n`
    escapes, `AB` keep-case beside Replace. The GUI has no hover hints anywhere yet; dvui's
    tooltip takes a plain rectangle, so painted buttons can have them. The TUI has no hover:
    flipping a toggle names it in the status bar.
  - *Highlighting every match is a toggle too* (`All`; off to start, stays as you left it) —
    **the user's pick** over always-on. On: every match is tinted, the current one stronger,
    with marks on the GUI scroll bar (Kate's Find All). Replace changes the current match
    only, on or off. `3 of 17` and the tinted box when nothing matches show either way.
  - Case is ignored unless `Aa` is on, as in VS Code, Kate and the search panel (Ctrl+F is
    case-sensitive today).

  Build order, each step checked on screen before the next:
  1. *The find row*: real text boxes — one shared line editor in the core (caret, selection,
     paste, Up / Down history) that the search panel, the palette and the prompts can move
     onto later; opens with the selection or the last search; `Aa`, `W` and `All` with their
     hints; previous / next (Shift+Enter / Enter, Shift+F3 / F3 from the text too); the count
     and the tints. Ctrl+H keeps today's two-row bar until step 2.
  2. *The replace row*: the `R` toggle and Ctrl+H unfold it; Replace / Replace All buttons,
     `Sel`, `AB`, `\n`.
  3. *Regular expressions* (**the user's pick**: third, not first): a small engine of ZIDE's
     own (no new dependency) behind `.*`, with `$1` groups in the replacement.
  4. *The search panel catches up*: the same boxes and buttons; comma lists and globs in
     include / exclude; open files only; a switch to search ignored files too.

  Keys follow VS Code as placeholders (Alt+C / Alt+W / Alt+R / Alt+L; Ctrl+Alt+Enter for
  Replace All, because Ctrl+A turns into "select all" inside a real text box) and get their
  final place in the hotkey pass; every button is also a command, so key maps and Lua can
  drive it.

### Selection and editing

- **Select all occurrences; expand / shrink selection** (N, S). Ctrl+D adds the next
  occurrence, nothing takes them all at once; and nothing grows the selection step by step
  (word → string → bracket pair → block). `brackets.zig` is enough for a first version; the
  server's `selectionRange` can refine it later.
- **A typed bracket or quote wraps the selection** (N, S). Today typing `(` `[` `{` `"` `'` or
  a backtick over selected text replaces it with an empty pair (`cmdInsertChar`); the usual
  behavior is to put the pair around the selection.
- **Small commands that are not among the 179** (N, S each). `select_line`; open a line above /
  below without splitting the current one; scroll the view a line without moving the caret
  (Ctrl+Up / Ctrl+Down); Backspace inside leading spaces removing one indent level instead of
  one space; a typed `}` on a blank indented line stepping back one level; and
  `toggle_word_wrap` — that one is Lua-sized already (`zide.get("word_wrap")` and `zide.set`
  both exist; untested). Join / sort / case are under *Editing* above.
- **Bookmarks** (N, S–M). Mark a line, next / previous mark, the list in the pick-list, kept
  per workspace. The breakpoint store is the pattern (marks need the same "follow edits" work
  listed under *Debugging and tasks*); a bookmark icon already ships in `src/icons/svg`.
- **Macros: record and replay** (N, M). Every action already runs through a named command, so
  a recording is a list of (command, argument) pairs; replay once or N times, and offer to save
  one as a Lua command.
- **Clipboard history** (N, S). Keep the last twenty copies; a pick-list (Ctrl+Shift+V
  elsewhere) pastes an older one.

### What the editor shows

- **Editor display aids** (N, S each; one theme field and both painters per aid). None exist
  (`theme.zig` has no field for any of them): indent guides in the text (the file tree has
  guides, the editor does not), visible whitespace (all / trailing only / inside the
  selection), a column ruler, a background for the caret's line (only its line number changes
  color today), and the selection's size in the status bar (`3 lines, 120 chars`).
- **Sticky scroll and breadcrumbs** (N, M). Keep the enclosing `fn` / `struct` header lines
  pinned at the top of the pane while scrolling, and a `folder › file › symbol` strip. Both can
  be fed by the document symbols Ctrl+F12 already fetches; sticky scroll also works from
  brackets and indentation alone.
- **Outline panel** (N, M). Document symbols exist only as a pick-list. A docked tree of the
  file's symbols that follows the caret is a natural second user of the dock model (step 2 of
  *Rearrangeable panels*).
- **Color swatches** (N, S). A small filled square beside `#rrggbb` text — ZIDE's own theme
  files are made of them.

### Tabs and files

- **Tab management** (N, S). The tab menu has two entries (Move to New Window, Close Tab): add
  Close Others / Close to the Right / Close All / Close Saved, Copy Path and Reveal in Tree.
  Middle-click does not close a tab (no middle-button handling anywhere). Ctrl+Tab walks the
  tabs in bar order (`nextDoc` / `prevDoc`), not most-recently-used. And nothing handles more
  tabs than fit: the GUI bar is a plain row with no scrolling and the TUI bar stops at the
  terminal's edge, so the active tab can be out of sight — scroll the bar to keep it visible
  and add an "open files" pick-list.
- **File commands that are missing** (N, S each). `save_all` (only save-all-and-quit exists);
  `revert_file` — drop unsaved edits and reload from disk (`reloadFromDisk` is there for the
  external-change guard; `reopen_with_encoding` is today's workaround); choosing the language
  of the current document (an untitled or extension-less file cannot be given one); line
  endings — show LF / CRLF in the status bar beside the encoding, and a command to convert
  (today only an `.editorconfig` changes them, at save); indentation — detect tabs or spaces
  and the width when a file opens, and convert between them; and trimming trailing spaces /
  ending with a newline as plain settings (they need an `.editorconfig` file today).
- **Open at a line from the command line** (N, S). `zide src/main.zig:120` (or `:120:8`) is
  taken as a file with that literal name. Read a trailing `:line[:col]` when the path as typed
  does not exist — it is how compilers and search tools name a place.
- **Images and binary files** (N, M). A binary file lands in the encoding picker. A read-only
  image preview tab and a simple hex view would answer "what is this file" without leaving
  ZIDE. Low priority.

### Desktop behavior

- **Delete to the Recycle Bin** (N, S). The file tree's Delete is permanent (`deleteFile` /
  `deleteTree` in `filetree.zig`) — the one loss with no way back. Windows: `SHFileOperationW`
  with `FOF_ALLOWUNDO`; Linux: the XDG trash folder. Keep a permanent Shift+Delete, and have
  the confirm text say which of the two is about to happen.
- **Remember the window** (N, S). The GUI always opens at 900×600; save the size, position and
  maximized state on exit, for the extra windows too.
- **Command palette rows that explain themselves** (N, S). Both frontends list bare command
  names. Every command already registers a description, and the keybind map knows its key (it
  needs a command → key lookup; `keybind.zig` only has key → command): show
  `name — description   key`, match on the description as well, recently used first.
- **Menus for what already exists** (N, S). The GUI menu bar is File / Edit / View /
  Preferences / Help. Quick open, workspace search, symbols, references, rename, format, back /
  forward, Problems, tasks, Git Changes, Review and the whole debugger are reachable only from
  the palette. **Go**, **Run** (tasks and debugger) and **Tools** menus that call the existing
  commands and show their keys are the cheapest discoverability win.
- **One running ZIDE** (N, M). A second `zide file.zig` (a double-click in Explorer, another
  tool's "open in editor") always starts another instance. Hand the path to the running window
  (a named pipe on Windows, a socket elsewhere), with `--new-window` to opt out — what makes
  ZIDE usable as the system's default editor for a file type.
- **Fullscreen and a distraction-free view** (N, S). F11 fullscreen (one SDL call) and a toggle
  hiding the tree, tabs and status bar.

### Build, run and debug

On hold since 2026-11-12, except *Zig tasks out of the box* — see the note at the top of this
section.

- **Zig tasks out of the box** (L, S). No task ships: `examples/tasks.lua` is commented text to
  copy. A bundled extension (like `snippets-zig.lua`) registering "Zig build", "Zig build test"
  and "Zig build run" with the `zig` problem matcher when the workspace root has a `build.zig`.
  Keys for build / run belong to the hotkey pass (`run_task`, the debugger and `rename_symbol`
  have no default key at all today).
- **Debugger reach** (N, S–M). Click the gutter to set or clear a breakpoint (the frontends
  never call `toggle_breakpoint`); run to the caret; `evaluate` — rest the pointer on a
  variable while stopped to see its value, and a console line for expressions (the request is
  not in `dap_session.zig`'s command list; watches, on the debugger's deferred list, need it
  too); and a build step before launch (`register_debug_config{ …, pre_task = "Zig build" }`)
  so a session never starts on a stale executable.
- **Project settings file** (N, M; after the trust prompt under *Safety and trust*). Tasks,
  debug configurations and language settings live only in the global `init.lua`. A
  `.zide/init.lua` in the workspace root, run after the global one once the folder is trusted,
  gives each project its own build / run / debug setup.
- **Clickable locations in terminal output** (N, M). Ctrl+click on `src/main.zig:120:8` in a
  terminal pane or the terminal panel opens that place — compile errors land in a terminal as
  often as in Task Output. Goes with the GUI terminal selection work under *Terminal gaps*.

### Git (low priority — lazygit covers it)

- **Blame for the caret's line, and undoing one change** (N, S–M). Author · date · summary of
  the line's last commit in the status bar (`git blame --porcelain -L`); and from a gutter
  mark, show the old text or put it back (the buffer-versus-index comparison behind the marks
  already has the old lines).

---

## Already exists or deliberately skipped — don't re-add

Checked 2026-09-30: multi-cursor + block selection, auto-closing brackets/quotes, word wrap,
split panes (nested), multiple OS windows with per-window tabs, command palette, quick open
with live preview, workspace search/replace with `.gitignore` pruning, external-change guard,
auto-save, crash-recovery snapshots, EditorConfig, format-on-save via the language server,
hover/rename/format, tasks + problem matchers, Git Changes panel + buffer-vs-index gutter
marks, full DAP debugger, snippets engine + Snippets panel (GUI), encodings, themes incl.
high-contrast, welcome screen, comment toggle, duplicate/move/delete line, TODO highlighting.

Deliberately skipped (user decisions — don't re-pitch): native `zig fmt` integration (CLI
habit; LSP format-on-save exists anyway), minimap, marketplace infrastructure, modal editing.
