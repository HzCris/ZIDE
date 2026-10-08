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

- **Dockable terminal — move it to the sides like the file tree** (N, M). Motivation (user,
  2026-10-08): run Claude Code or any LLM CLI in a full-height side terminal as a chat column
  while a bottom terminal stays free for commands — commands run inside Claude Code render in
  a tiny collapsible box and feed their output back to the model for nothing. Today a terminal
  lives inside the split-pane tree: `toggle_terminal` makes a bottom split, `open_terminal_right`
  a side-by-side split, `detach_terminal` its own window — so its position is whatever split you
  built, and nothing about it persists. The ask: dock the terminal left/right/bottom the way the
  file tree docks, with a remembered side and size. Design question to settle first: keep
  terminals as splits and add placement commands plus remembered geometry (cheaper), or promote
  the terminal to a real docked band like the file tree with `terminal_side` / `terminal_size`
  settings (matches the file-tree precedent, but a second home for terminals outside the split
  tree).
- **Multiple terminals** (N, S–M). The core already stores a list of terminals, so the model
  allows it; what's missing is the front door. Add a `new_terminal` command that always creates
  another shell (today's commands reuse/focus the existing one), a way to cycle or pick them
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
  in that pass — e.g. navigate_back/forward on Ctrl+Alt+Left/Right + F7/Shift+F7.

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
   extension-fetching wishlist items into pure Lua.
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
  in and is easy to miss. Make it a modal floating window like the encoding and recovery
  dialogs (buttons + the same S/D/C keys), and audit the other in-editor banners
  (overwrite/reload, Git stage, task save-before-run) for the same treatment.

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
  backtracking engine (fun sub-project) or a vendored one. The same engine unlocks
  comma-separated include/exclude lists in the search panel.

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

---

## Already exists or deliberately skipped — don't re-add

Checked 2026-09-30: multi-cursor + block selection, auto-closing brackets/quotes, word wrap,
split panes (nested), multiple OS windows with per-window tabs, command palette, quick open
with live preview, workspace search/replace with `.gitignore` pruning, external-change guard,
auto-save, crash-recovery snapshots, EditorConfig, format-on-save via the language server,
hover/rename/format, tasks + problem matchers, Git Changes panel + buffer-vs-index gutter
marks, full DAP debugger, snippets engine (needs docs, not code), encodings, themes incl.
high-contrast, welcome screen, comment toggle, duplicate/move/delete line, TODO highlighting.

Deliberately skipped (user decisions — don't re-pitch): native `zig fmt` integration (CLI
habit; LSP format-on-save exists anyway), minimap, marketplace infrastructure, modal editing.
