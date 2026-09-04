# Extensions that every IDE has over a text editor.

ZIDE now has a real Lua extension runtime — `zide.command` / `zide.on` /
`zide.exec` / `zide.status`, a buffer API, `zide.run` / `zide.spawn`, and
`zide.set_diagnostics` (see Documentation.md → "Extension Runtime API").
Checked items are tagged: **(native)** = built into the Zig core,
**(extension)** = implemented in Lua on the public API.

## TUI
- [] LLM support using OpenAI API for various cloud providers and local LLMs (And claude if allowed)
- [] Git integration (gutter signs)
- [] Terminal Splitting
- [] Extension fetching (Think like how neovim pulls from github/codeberg)
- [] Debug Support
- [x] Nerdfont/Custom Icon integration (native + extension hook, 2026-07-26: `tui_filetree_icons` renders nerdfont glyphs + truecolor accents from the shared `fileicons.zig` kinds — off by default, needs a Nerd Font terminal font; `zide.set_icon(key, kind, "#hex")` overrides any assignment in both frontends)
- [x] Linting (extension — `extensions/example-lint-zig.lua` ships as a commented template: on-save `zig ast-check` → gutter/underline/status diagnostics via zide.on + zide.spawn + zide.set_diagnostics; copy it for any other linter)
- [x] Block/column selection (native; Alt+drag; Ctrl+Shift+Up/Down and Alt+click already stacked cursors)
- [x] Ctrl+/ to comment highlighted text (native; uses register_language's line_comment/block_comment fields — upkeep lives in Lua configs)
- [x] Session Persistance Option (native; `zide.set("session_persistence", true)` — restores files/cursors/active tab on bare launch)
- [x] TODO comment integration (native; TODO/FIXME/XXX/HACK/BUG/NOTE highlighted in comments, `next_todo` palette command, `syn_todo` color override)
- [x] Markdown editing (native structural tokenizer for `.md` — headings/bold/italic/code/fences/links/lists/task boxes/quotes/tables, real bold/italic/underline cells in the TUI; Enter continues `- `/`1. `/`> `/`- [ ] ` markers and ends lists on empty items; `extensions/markdown.lua` ships active with a `toggle_checkbox` palette command; `syn_heading`/`syn_strong`/`syn_emphasis`/`syn_link` overrides, 2026-08-24)
- [x] Syntax highlighting (native engine; languages are Lua-declared via zide.register_language)
- [x] LSP support (native multi-server client — any server is Lua-declared via zide.register_lsp with argv/settings/init_options, one process per registration, started lazily per language; zls for Zig is the only built-in registration, 2026-09-03)
- [x] File tree / project browser (native; Ctrl+B toggle, dockable left/right via `filetree_side`, starting directory via `zide.set("filetree_root", path)`, a/r/d file ops, Shift+R refresh, reveal-current-file, git status row colors)

## GUI
- [] Extension fetching (Think like how neovim pulls from github/codeberg)
- [] LLM support using OpenAI API for various cloud providers and local LLMs (And claude if allowed)
- [] Git integration (gutter signs)
- [] Debug Support
- [x] Custom Icon integration (native; file tree rows render dvui's bundled entypo TinyVG glyphs with fixed accent colors — classification in `src/core/fileicons.zig`, VS Code-style chevrons/hover/scrollbar/git badges shipped 2026-07-26; a `zide.set_icons` Lua override can layer on later)
- [x] Linting (extension — same `example-lint-zig.lua`; the runtime is frontend-agnostic so one extension covers both UIs)
- [x] Ctrl+/ to comment highlighted text (native; uses register_language's line_comment/block_comment fields — upkeep lives in Lua configs)
- [x] LSP support (native multi-server client — any server is Lua-declared via zide.register_lsp with argv/settings/init_options, one process per registration, started lazily per language; zls for Zig is the only built-in registration, 2026-09-03)
- [x] Embedded Terminal (native)
- [x] Syntax highlighting (native engine; languages are Lua-declared via zide.register_language)
- [x] Block/column selection (native)
- [x] File tree / project browser (native; Ctrl+B toggle, dockable left/right, starting directory via `filetree_root`, click + keyboard browsing, right-click menu, a/r/d file ops, git status row colors)
- [x] Session Persistance Option (native; `zide.set("session_persistence", true)` or Settings dialog — restores files/cursors/active tab on bare launch)
- [x] TODO comment integration (native; TODO/FIXME/XXX/HACK/BUG/NOTE highlighted in comments, `next_todo` palette command, `syn_todo` color override)
- [x] Markdown editing (native structural tokenizer for `.md` — headings/bold/italic/code/fences/links/lists/task boxes/quotes/tables; Enter continues `- `/`1. `/`> `/`- [ ] ` markers and ends lists on empty items; same `extensions/markdown.lua` `toggle_checkbox` command — runtime is frontend-agnostic; `syn_heading`/`syn_strong`/`syn_emphasis`/`syn_link` overrides, 2026-08-24)


### File tree follow-ups (queued 2026-06-10, shipped same day)
- [x] Indent guide lines showing parent/child folder structure
- [x] Starting-directory setting in the Settings dialog ("File Tree Root" text field, Enter applies, bad paths keep the old root)
- [x] Context-menu "Move tree to left/right side" (persists)
- [x] Single click selects, double click opens (the +/- glyph still toggles on single click)
- [x] Drag & drop to move files/folders (GUI) + x/p move keys in both frontends

### Extension runtime (shipped 2026-06-12)
- [x] zide.command / zide.on("open"|"save", fn(path, language) [, { language = "zig" }]) / zide.exec / zide.status
- [x] Per-language keybind overlays (2026-09-03): `zide.bind(key, cmd, { language = "zig" })` / scoped `zide.unbind` — consulted before the global map while editing a file of that language
- [x] Buffer API (line_count/get_line/get_text/cursor/set_cursor/file_path/language/selection/insert/set_line)
- [x] zide.run (sync) + zide.spawn (worker thread + main-loop callback)
- [x] zide.set_diagnostics (extension findings render like LSP diagnostics)
- [x] reload_extensions command (restartless extension development)
- [x] Dogfood: example-lint-zig.lua template
- [x] Per-language settings (2026-09-03): `zide.set_language(name, { tab_width, use_tabs, word_wrap, auto_close_brackets })` / `zide.get_language`, same keys accepted by register_language — neovim ftplugin-style overrides of the global defaults
- Remaining unchecked items above stay native-engine work by nature (gutter signs, terminal splitting, icons, DAP); LLM support and extension fetching should build on this runtime when they happen.
