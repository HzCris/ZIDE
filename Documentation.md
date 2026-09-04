# ZIDE Feature Documentation

## TUI Frontend

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Ctrl+Q | Quit (prompts if unsaved) |
| Ctrl+S | Save |
| Ctrl+N | New document |
| Ctrl+O | Open file (path input) |
| Ctrl+Z | Undo |
| Ctrl+Y | Redo |
| Ctrl+C | Copy |
| Ctrl+X | Cut |
| Ctrl+V | Paste |
| Ctrl+A | Select all |
| Ctrl+F | Find |
| Ctrl+H | Find and Replace |
| Ctrl+G | Go to line |
| Ctrl+P | Command palette |
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
| Ctrl+` | Toggle terminal (bottom split) |
| Ctrl+Shift+` | Open terminal (side-by-side split) |
| Ctrl+B | Toggle file tree side panel |
| Alt+Click | Add cursor at click position |
| Shift+Alt+Drag (GUI) / Alt+Drag (TUI) | Block (column) selection — one cursor per line over the dragged column span |
| Ctrl+K | Delete line |
| Ctrl+/ | Toggle comment on selected lines (uses the language's line comment; wraps in block comments for languages without one, e.g. CSS) |
| Escape / Left-click | Remove secondary cursors |
| Ctrl+Left/Right | Word movement |
| Ctrl+Shift+Left/Right | Word selection |
| Ctrl+Backspace | Delete word backward |
| Ctrl+Delete | Delete word forward |
| Ctrl+Home/End | Jump to file start/end |
| Ctrl+Shift+Home/End | Select to file start/end |
| Ctrl+W | Close tab |
| Ctrl+Alt+Q | Close pane (also closes the focused terminal pane) |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous document tab |
| Ctrl+PageDown / Ctrl+PageUp | Next / previous document tab |
| Alt+Right / Alt+Left | Focus next / previous split pane |
| Ctrl+Shift+S | Save As |
| Alt+\ | Split pane vertically (side by side) |
| Alt+Shift+\ | Split pane horizontally (top/bottom) |
| Alt+Up/Down | Move line up/down |
| Home | Smart home (first non-ws / col 0) |
| End | End of line |
| Shift+Home/End | Extend selection to home/end |
| Shift+Arrow keys | Extend selection |
| Page Up/Down | Page scroll |
| Tab | Indent (spaces or tab) |
| Shift+Tab | Dedent |
| Enter | Newline with auto-indent |
| Mouse left click | Position cursor |
| Mouse left drag | Select text |
| Mouse scroll wheel | Scroll viewport (5 lines per tick) |

All Ctrl/Alt shortcuts are remappable via `~/.config/zide/init.lua`.

Windows terminals commonly intercept Alt combos (Windows Terminal binds Alt+arrows for its own panes; Ctrl+Alt doubles as AltGr), so every Alt-based default has an Alt-free twin (see table). F1–F12 are bindable in both frontends.

### TUI — Implemented Features

**Editing:**
- Insert, delete, backspace, newline with auto-indent
- Undo/redo history
- Word movement and word delete (Ctrl+Left/Right, Ctrl+Backspace/Delete)
- Line operations: delete (Ctrl+K), duplicate (Ctrl+D), move up/down (Alt+Up/Down)
- Comment toggle (Ctrl+/): comments/uncomments all selected lines as one undo step, aligned at the block's minimum indent, skipping blank lines; uses `line_comment` from the language definition, falling back to per-line `block_comment_start/end` wrapping (CSS/HTML); works in legacy terminals too (Ctrl+/ arrives as byte 0x1F and is normalized)
- Smart Home (first non-whitespace or column 0)
- Indent/Dedent (Tab/Shift+Tab, respects tab_width and use_tabs — the global defaults or the file's language override, see *Per-language settings*)
- Auto-closing brackets and quotes (skip-over, smart quote detection)
- UTF-8 aware cursor movement
- Selection (Shift+arrows, Shift+Home/End, Ctrl+A select all)
- Copy/Cut/Paste with system clipboard (Windows Win32 API, Linux wl-copy/xclip/xsel)

**Navigation:**
- Incremental/live search (jumps to matches as you type, Escape restores cursor)
- Find with wrap-around search and "No matches found" / "Search wrapped" feedback
- Find and Replace (Ctrl+H, Tab to switch fields, Enter for next, Ctrl+A replace all, shows count)
- Go to line (Ctrl+G)
- Command palette with fuzzy matching (Ctrl+P)
- Quick open (Ctrl+E, `quick_open` in the palette): fuzzy-find any workspace file by name — basename matches rank first; arrowing through results **live-previews** each file in the pane behind the bottom-anchored panel (no tab is created — nothing like VS Code's italic preview tabs); PageUp/PageDown scroll the preview; Enter opens it as a normal tab, Escape restores exactly where you were. Walks the file tree root (dot-folders and `zig-out` skipped)
- Workspace search & replace (Ctrl+Shift+F, `find_in_files`): **docked bottom panel** with search / replace / files-to-include / files-to-exclude fields (Tab cycles, click focuses; include and exclude take `*.ext` or a path substring and apply to the disk walk — open documents are always searched), case (Alt+C) and whole-word (Alt+W) toggles. A background worker streams `path:line: excerpt` results in live — open documents are searched **in-buffer** (dirty edits included) and skipped on disk; dot-folders, `zig-out`, binaries, and files > 8 MB are skipped; results cap at 2000 with an explicit "(capped)" note. Enter (or double-click) opens a result with the match selected; Escape hides the panel but results persist — **F4 / Shift+F4** cycle through them while editing. Replace All (Enter on the Replace field) asks per operation: `[A]ll` (open docs get one undoable edit group each and stay unsaved; closed files are rewritten on disk — **not undoable**) or `[O]pen docs only`. Matching is literal (no regex yet); the filter takes `*.ext` or a path substring
- Ctrl+Home/End for file start/end
- Page Up/Down

**Display:**
- Syntax highlighting (Zig built-in, extensible via Lua — see Syntax Highlighting section)
- TODO comment highlighting: `TODO`/`FIXME`/`XXX`/`HACK`/`BUG`/`NOTE` inside comments get the `todo` syntax color; `next_todo` command (palette) jumps to the next marker with wrap-around
- Markdown highlighting (built-in for `.md`/`.markdown`): headings, bold/italic, inline code and ``` fences, links/images/autolinks, list bullets + task checkboxes, blockquotes, tables, strikethrough, HTML comments (TODO markers inside get the `todo` color). The TUI additionally renders headings/bold in real bold, italics in italic, links underlined
- Markdown editing: Enter continues list/quote markers (`- `, `1. ` with auto-increment, `> `, `- [ ] `); Enter on an empty item ends the list; `toggle_checkbox` palette command flips `[ ]`/`[x]` (bundled `extensions/markdown.lua`)
- Line numbers with active line highlight
- Visual-row cursor movement with word wrap (Up/Down navigate wrapped rows, not logical lines)
- Status bar: filename, dirty marker (`*`), `Ln X, Col Y`
- Tab bar when multiple documents open
- Selection highlighting
- Word wrap (word-boundary aware, configurable)
- Tilde `~` markers for lines past end of file
- Wrap continuation markers (`.`)

**Mouse:**
- Left click to position cursor (clears secondary cursors, configurable)
- Alt+click to add cursor at position
- Alt+drag for block (column) selection: one cursor per line over the dragged column span; short lines get a zero-width cursor at their end. Shift+Alt+drag also works in terminals that forward Shift+drag (Windows Terminal keeps it for its own selection, hence plain Alt+drag)
- Left drag to select text
- Scroll wheel to scroll viewport (independent of cursor position)
- Click a tab in the tab bar to switch to it
- Click in a split pane to focus it

**Split Panes:**
- Vertical split (Alt+\\) and horizontal split (Alt+Shift+\\)
- Nested splits supported (binary layout tree)
- Pane separators rendered with box-drawing characters
- Close pane (Ctrl+Alt+Q), focus next/prev (Alt+Right/Alt+Left)

**Documents / File I/O:**
- Multi-document tabs (Ctrl+N new, Ctrl+W close, open by path)
- Tab switching: Ctrl+Tab / Ctrl+Shift+Tab, Ctrl+PageDown / Ctrl+PageUp
- Open file by path (Ctrl+O)
- Save (Ctrl+S), Save As (Ctrl+Shift+S)
- Line ending detection (LF / CRLF)
- External change detection: open files are polled (~1.5s, same cadence as the file tree probe) — clean buffers reload in place with the cursor preserved; dirty buffers are flagged and saving asks `[O]verwrite [R]eload [C]ancel` instead of silently clobbering; auto-save skips flagged files; a file deleted on disk marks its buffer dirty so the content survives and can be re-saved
- Dirty tracking
- Unsaved changes prompt on quit (Save/Discard/Cancel)
- Session persistence (opt-in: `zide.set("session_persistence", true)` or the Settings dialog): on quit the open files, cursor positions, scroll offsets and active tab are written to `~/.config/zide/session`; launching ZIDE without file arguments restores them (missing files are skipped, untitled buffers are not recorded). Applies to both frontends.

**Configuration:**
- Config folder hierarchy: `~/.config/zide/` with `themes/` and `extensions/` subfolders
- Lua settings file (`~/.config/zide/init.lua`)
  - `zide.set_language(name, { tab_width = 2, use_tabs = false, word_wrap = true, auto_close_brackets = false })` — per-language overrides of those four settings for files of that language (merge: only the keys given change; name matched case-insensitively; works for built-ins and for languages registered later); `zide.get_language(name)` reads the overrides back (nil when none)
  - `zide.set(key, value)` — tab_width, use_tabs, word_wrap, auto_close_brackets (global defaults — see `zide.set_language`), page_size, auto_save, auto_save_interval_ms, click_clears_cursors, max_undo_history, session_persistence, filetree_visible, filetree_side ("left"/"right"), filetree_width (GUI px), tui_filetree_width (columns), filetree_root (starting directory, "" = cwd), lsp_enabled (off = no language servers; running ones stop on the next frame), syntax_highlighting (off = plain-text look), filetree_git_colors (off = no git status colors/subprocesses)
  - `zide.set("mono_font_path", "/path/to/font.ttf")` — use a custom monospace font (e.g. a Nerd Font for box-drawing and powerline glyphs in the embedded terminal)
  - `zide.set("mono_font_size", 14)` — override the default monospace font size
  - `zide.set("tui_theme", name)` — switch TUI theme ("terminal", "dark", "light", "high_contrast")
  - `zide.set("tui_color_*", "#hex")` — override individual TUI color (e.g. `tui_color_text_fg`)
  - `zide.set("syn_*", "#hex")` — override syntax highlight color (e.g. `syn_keyword`, `syn_comment`)
  - `zide.set("tui_syn_*", "#hex")` — override TUI-only syntax color
  - `zide.register_language({...})` — register a language for syntax highlighting (see Syntax Highlighting section)
  - `zide.register_lsp({...})` — register an LSP server for a language (see LSP Support section)
  - `zide.get(key)` — read current settings
  - `zide.bind(key_combo, command [, { language = "zig" }])` — remap keybindings; with the `language` option the binding lives in that language's overlay and applies only while editing a file of that language (see *Command System*)
  - `zide.unbind(key_combo [, { language = "zig" }])` — remove a keybinding (global, or from a language overlay)
- Data-driven keybinding map (all Ctrl/Alt shortcuts remappable, globally or per language)
- File tree side panel (Ctrl+B) — dockable left/right column band with mouse + keyboard browsing, create/rename/delete prompts, reveal-current-file (see File Tree section)
- Auto-save (saves dirty documents with file paths after configurable interval, default 5s)
- Application icon embedded in exe
- Multiple cursor editing (Ctrl+Shift or Ctrl+Alt+Up/Down, Ctrl+D, Alt+click, Escape/click to clear)
- Theme system: 3 built-in themes (dark, light, high-contrast)
  - "terminal" mode (default): uses ANSI indices, respects terminal color scheme
  - Named themes use direct RGB colors for a consistent look
  - Custom overrides via `~/.config/zide/themes/tui-theme.lua` (auto-created with commented defaults on first run)
  - 24 named TUI color fields across editor, gutter, tab bar, status bar, and overlay panels

### TUI — Not Yet Implemented
- (none currently)

---

## GUI Frontend

### GUI — Implemented Features

- DVUI + SDL3 window with editor pane
- Text editing via DVUI TextEntryWidget (undo/redo/clipboard handled by widget)
- Syntax highlighting (Zig built-in, extensible via Lua — see Syntax Highlighting section)
- TODO comment highlighting: `TODO`/`FIXME`/`XXX`/`HACK`/`BUG`/`NOTE` inside comments get the `todo` syntax color; `next_todo` command (palette) jumps to the next marker with wrap-around
- Markdown highlighting (built-in for `.md`/`.markdown`): headings, bold/italic, inline code and ``` fences, links/images/autolinks, list bullets + task checkboxes, blockquotes, tables, strikethrough, HTML comments (TODO markers inside get the `todo` color)
- Markdown editing: Enter continues list/quote markers (`- `, `1. ` with auto-increment, `> `, `- [ ] `); Enter on an empty item ends the list; `toggle_checkbox` palette command flips `[ ]`/`[x]` (bundled `extensions/markdown.lua`)
- Word wrap (word-boundary aware, configurable, wrap continuation markers)
- Save / Save As (native OS file dialog)
- External change detection (same behavior as the TUI): clean buffers auto-reload when the file changes on disk; dirty buffers get a `[O]verwrite [R]eload [C]ancel` prompt on save; auto-save never clobbers an external change
- Open file (native OS file dialog)
- Multi-document tabs (tab bar with close buttons)
- New document (Ctrl+N)
- Tab switching (Ctrl+Tab / Ctrl+Shift+Tab via menu)
- Status bar (filename, dirty marker, Ln/Col, detected language)
- Line numbers with active line highlight in gutter
- Go to line (Ctrl+G, overlay input)
- Find with incremental search, wrap-around, and status feedback (Ctrl+F)
- Find and Replace (Ctrl+H, Tab to switch fields, Enter for next, Ctrl+A replace all, shows count)
- Command palette with fuzzy matching (Ctrl+P)
- Quick open (Ctrl+E): fuzzy file finder with live preview behind a bottom-anchored panel — same behavior as the TUI (Enter opens a normal tab, Escape restores; previews never appear in the tab bar); PageUp/PageDown and the mouse wheel scroll the preview
- Workspace search & replace (Ctrl+Shift+F): same engine and behavior as the TUI, with a VS Code-style panel — bordered input boxes with placeholders, clickable `Aa`/`W` toggle chips inside the search box (toggling re-runs the search), results **grouped under file headers** (collapse chevron + type icon + name + directory + match count — click a header to fold/unfold its file; the current file's header stays **pinned at the top** while its matches scroll, VS Code-style) with the match **highlighted inside each excerpt** and long excerpts ellipsis-windowed around the match; click fields to focus, double-click a result to open it, wheel scrolls, F4/Shift+F4 cycle results while editing
- Keybinding remapping (Lua integration — `zide.bind`/`zide.unbind` via init.lua, global or per-language with `{ language = "zig" }`)
- Auto-save (saves dirty documents with file paths after configurable interval, default 5s)
- Application icon embedded in exe
- SDL3GPU backend (GPU-accelerated rendering, opt-in via `zig build -Dgpu=true`, default SDL3 for lower memory)
- Find/Replace match count display (shows "N matches" in overlay bar)
- Command palette Tab/arrow cycling with highlighted selection (Enter executes selected)
- Configurable line number gutter width (`zide.set("gutter_min_digits", N)` in init.lua, default 3)
- Mouse selection: double-click selects word, triple-click selects line, drag extends by word/line accordingly, Shift+click extends selection, Alt+click adds cursor, Shift+Alt+drag for block (column) selection (one cursor per line over the dragged column span)

- File tree side panel (Ctrl+B) — dockable left/right, VS Code-style rows (type icons, chevrons, hover, scrollbar, git badges), inline create/rename, `/` search, auto-reveal, multi-select with bulk delete/move, file cut/copy/paste, Explorer drag-in, clickable delete dialog, header buttons, context menu incl. copy path + reveal in Explorer (see File Tree section)
- Settings dialog (Preferences menu — modal DVUI floating window with native widgets: checkboxes for booleans, validated numeric entries with min/max, dropdown for theme; draggable by header, auto-centered, dims the background; changes apply live and write to init.lua immediately; close via header X or Escape; Tab/Shift+Tab cycles controls; it edits the global defaults — per-language overrides live in init.lua via `zide.set_language`)
- Open Settings File (Preferences menu — opens init.lua directly in the editor for power users)
- Tab character display (expands `\t` to spaces for rendering, cursor, selection, and wrapping)
- Blinking caret (530ms cycle, resets on cursor movement) — drawn in the theme's `cursor` color (override via `zide.set("color_cursor", "#hex")`) so it stands out from selection highlights; secondary multi-cursor carets use the same color dimmed
- Multiple cursor editing (Ctrl+Shift or Ctrl+Alt+Up/Down, Ctrl+D, Alt+click, Escape/click to clear)
- Split panes: vertical (Alt+\) and horizontal (Alt+Shift+\) splits with draggable dividers
  - Binary layout tree — nested splits supported (split a split)
  - Click to focus pane, focused pane highlighted with border
  - Close pane (Ctrl+Alt+Q), navigate via command palette (`focus_next_pane`, `focus_prev_pane`)
  - Each pane shows its own document independently, keyboard input goes to focused pane only
  - Modal overlays (find/replace, palette, etc.) render in focused pane
  - Split/close/focus commands available in View menu and command palette
- Theme system: 3 built-in themes (dark, light, high-contrast) with custom DVUI themes
  - `zide.set("theme", "dark")` / `"light"` / `"high_contrast"` — switch preset
  - `zide.set("color_*", "#RRGGBB")` or `"#RRGGBBAA"` — override individual colors
  - Custom overrides via `~/.config/zide/themes/gui-theme.lua`
  - 18 named editor color fields: text, selection, cursor, gutter_bg, gutter_text, gutter_text_active, gutter_separator, wrap_marker, tilde, overlay_bg, overlay_fg, overlay_dim, overlay_warn, overlay_selection, overlay_hint, bool_true, bool_false, status_bg, status_fg
- Menu bar reorganized:
  - File: New, Open File, Save, Save As, Close Tab, Exit
  - Edit: Undo, Redo, Cut, Copy, Paste, Select All, Find, Replace, Go to Line
  - View: Command Palette, Next Tab, Prev Tab, Split Vertical, Split Horizontal, Close Pane
  - Preferences: Settings, Open Settings File, Theme > (Dark / Light / High Contrast), Open Theme File, Open Theme Folder
  - Help: Documentation, About ZIDE
- Theme switcher: Preferences > Theme submenu switches themes live (updates editor + DVUI chrome, persists to init.lua)
- Theme setting in Settings dialog: dropdown (dark/light/high_contrast)
- Open Theme File: opens `~/.config/zide/themes/gui-theme.lua` in editor (creates commented template with per-field descriptions if missing)
- Open Theme Folder: opens `~/.config/zide/themes/` in OS file explorer
- Help > Documentation: opens Documentation.md in the editor (searches the exe's directory and its ancestors — works from `zig-out/bin` and desktop launches; also available as the `open_documentation` palette command in both frontends)
- Editor pane scrollbar: slim pill overlay on the right edge (same style as the file tree) — drag the thumb, click the band to page up/down, hover brightens; per split pane
- Tab bar styling: inactive tabs have visible borders and control-style background
- Right-click context menu in editor panes: Cut, Copy, Paste, Select All, Go to Definition
  - Right-click outside the selection moves the cursor to the click point first; inside the selection it keeps the selection (so Cut/Copy act on it)

### GUI — Not Yet Implemented
- (none currently)

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
zide.set("syn_operator", "#abb2bf")
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
language; everything else keeps the global syntax theme. `tui_syn_*` keys
work here too for TUI-only per-language overrides.

#### Built-in Presets

Syntax theme presets automatically match when you switch editor themes:

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
| `name` | string | yes | Language display name |
| `extensions` | string[] | yes | File extensions (without dot) |
| `keywords` | string[] | yes | Language keywords |
| `types` | string[] | no | Type names (default: empty) |
| `constants` | string[] | no | Named constants (default: empty) |
| `builtins` | string[] | no | Built-in functions (default: empty) |
| `line_comment` | string | no | Line comment prefix (e.g., `"//"`) |
| `block_comment_start` | string | no | Block comment start (e.g., `"/*"`) |
| `block_comment_end` | string | no | Block comment end (e.g., `"*/"`) |
| `string_delimiters` | string | no | Characters that start strings (default: `"\""`) |
| `has_char_literals` | bool | no | Whether `'x'` is a char literal (default: false) |
| `builtin_prefix` | string | no | Single character prefix for builtins (e.g., `"@"` for Zig) |
| `preproc_prefix` | string | no | Single character prefix for preprocessor (e.g., `"#"` for C) |
| `tokenizer` | string | no | `"generic"` (default: the table-driven tokenizer above) or `"markdown"` (the structural native tokenizer; the tables are then unused). Needed when re-registering `markdown` — a replacement without it degrades to generic (logged as a warning) |

| `tab_width` / `use_tabs` / `word_wrap` / `auto_close_brackets` | number / bool | no | Per-language overrides of the editor settings for files of this language — sugar for `zide.set_language(name, {...})` below |

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

#### Extension Runtime API

Extensions are not limited to language definitions — any `.lua` file in
`~/.config/zide/extensions/` can register commands and react to editor
events. Every callback runs in a protected call: a broken extension shows
`Extension error: …` in the status bar (details in the log) and the editor
keeps running.

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
| `zide.command(name, desc, fn)` | Register a command — listed in the palette, runnable via `zide.bind`/`zide.exec`. Re-registering a name replaces it; shadowing a built-in is allowed (logged). `fn` receives the optional args string (usually nil). |
| `zide.on(event, fn [, opts])` | Hook an event. Events: `"open"` (file opened into a tab), `"save"` (file written — fires per document on auto-save too). `fn(path, language)` gets the file path (or nil) and the document's language name (or nil for plain text); handlers that only declare `path` keep working. `opts.language = "zig"` fires the handler only for documents of that language (case-insensitive). |
| `zide.exec(name)` → bool | Run any action or command by name — the same names keybinds use (`"save"`, `"undo"`, `"toggle_filetree"`, other Lua commands, …). Returns whether the name was recognized. |
| `zide.status(msg)` | Show a transient message in the status bar (both frontends). |

**Buffer API** — all calls act on the active document; lines and columns are
**1-based**. Mutations go through the editor's normal document operations, so
undo (Ctrl+Z) and LSP sync behave exactly as if typed.

| Call | Description |
|------|-------------|
| `zide.line_count()` → int | Number of lines. |
| `zide.get_line(n)` → string\|nil | Line `n` without its newline; nil out of range. |
| `zide.get_text()` → string | The whole buffer. |
| `zide.cursor()` → line, col | Primary cursor position (two return values). |
| `zide.set_cursor(line, col)` | Move the primary cursor (clamped to valid positions); drops secondary cursors and selection. |
| `zide.file_path()` → string\|nil | The document's path on disk (nil = untitled). |
| `zide.language()` → string\|nil | Detected language name (e.g. `"Zig"`). |
| `zide.selection()` → string\|nil | Selected text of the primary cursor. |
| `zide.insert(text)` | Insert at the primary cursor; an active selection is replaced (one undo step) — this doubles as "replace selection". |
| `zide.set_line(n, text)` | Replace line `n`'s content (one undo step); out-of-range is ignored. |

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
run itself failed — tool not found, timeout, …). Output is capped at 4 MiB
stdout / 256 KiB stderr.

| Call | Description |
|------|-------------|
| `zide.run(argv [, timeout_ms])` → table\|nil, err | Run a tool and **block until it exits** (the UI freezes meanwhile — fast tools only). `argv` is a list, e.g. `{"git", "status"}`. On timeout the child is killed and `nil, "Timeout"` returns. |
| `zide.spawn(argv, fn(result))` | Run on a background thread; the callback fires on the editor loop when the tool finishes. Use this for linters, builds, anything slow. |

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
| `zide.set_diagnostics(path, list)` | Replace the extension diagnostics of the **open** document at `path` (separator/case-insensitive match; non-open paths ignored). Pass `{}` to clear. Each entry: `{ line = N, col = N, end_col = N, severity = "error"\|"warning"\|"info"\|"hint", message = "…" }` — 1-based positions; only `line` is required (severity defaults to `"error"`). Positions go stale as the user edits, exactly like LSP — the next run replaces them. |

Lint diagnostics are cleared by `reload_extensions` (a removed linter's
stale squiggles don't survive).

### File Tree Icons

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

The `reload_extensions` command (palette) drops all Lua-registered commands
and event handlers and re-runs every `extensions/*.lua` — edit-extension,
reload, retry without restarting ZIDE. (Lua globals your scripts set persist
across reloads; top-level state is re-initialized by your script itself.)
Languages re-registered by the reload are replaced in place, and every open
document's language is re-detected afterwards, so a new extension→language
mapping applies to files that are already open.

#### Extension Directory

```
~/.config/zide/
├── init.lua                          # Main settings
├── extensions/                       # Language + runtime extensions
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

Documents are routed by **language name**: a document is synced to the server whose registration serves its detected language (the `name` from `zide.register_language`), so a `.txt` or `.md` buffer never reaches zls. The status bar shows each document's language and, once its server is up, the server's name: `Ln 1, Col 1 | c (clangd)` (or `plain text` when nothing matched).

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

Registration is not checked against the language registry — `init.lua` runs before extensions register their languages; resolution happens by name when a document opens. When several registrations serve the same language the **most recent wins**, so a `register_lsp` for `zig` in your config replaces the built-in `zls` entry (e.g. to pin a toolchain-matched binary).

### Lifecycle

- **Lazy start**: a server is spawned the first time a document of a language it serves is opened (or gains that language through a rename / Save As). Nothing runs for languages without an open file.
- **Workspace root**: the file tree root (`filetree_root`, canonicalized) is sent as `rootUri` / `rootPath` / `workspaceFolders`. rust-analyzer needs this to be the Cargo project. Re-rooting the tree later does not move running servers — run `lsp_restart`.
- **Status bar**: `LSP ready: clangd (c, cpp)` on handshake; `LSP for c: cannot start clangd (FileNotFound) — see zide.log` when the program is missing; `LSP clangd exited — run lsp_restart` when a server dies or rejects `initialize`. A failed registration is **not retried every frame** — it stays marked failed until `lsp_restart` or until `reload_extensions` replaces it.
- **`lsp_restart`** (palette): stops every server, forgets failures, and lets the lazy start bring servers back for the open documents.
- **`reload_extensions`**: registrations made by `extensions/*.lua` are dropped and re-created; a server whose registration is unchanged keeps running, changed or removed ones are stopped.
- **`lsp_enabled`** (`zide.set("lsp_enabled", false)` or the Settings dialog): no servers start and running ones stop on the next frame — takes effect immediately.
- **Quit**: every server gets `shutdown` + `exit`, up to a second to leave on its own, then is killed.
- Server→client requests are answered: `workspace/configuration` from `settings`, `workspace/workspaceFolders`, capability registrations and progress tokens with `null`, anything else with a JSON-RPC MethodNotFound. `window/logMessage` / `window/showMessage` go to `zide.log` (server errors also to the status bar). Every server's stderr is discarded, and on Windows servers are spawned with `CREATE_NO_WINDOW` so no console window appears.

### Architecture

- **One background reader thread per server** reads JSON-RPC messages from the server's stdout and pushes them onto a thread-safe ring buffer queue
- **Main thread** (`Editor.lspTick`) sweeps dead servers, polls every queue each frame (GUI) or event loop iteration (TUI) — no blocking — then syncs documents
- **Full-text document sync** with version coalescing: rapid keystrokes are batched into a single `didChange` notification per frame
- In the TUI, reader threads wake the blocking event loop via `loop.postEvent(.lsp_data)`; a server's stdout closing wakes it too, so a crash is noticed without a keypress
- Each client owns a deep copy of its registration (`lsp.ServerConfig`); documents route to "the running client whose registration serves the document's language" — nothing is cached on documents or language definitions

### Diagnostics (Sprint 1 — Implemented)

The LSP client receives `textDocument/publishDiagnostics` notifications and displays them in both frontends:

**GUI:**
- Colored dot in the gutter (red = error, yellow = warning, blue = info/hint)
- Colored underlines under diagnostic text ranges
- Diagnostic message in the status bar for the current cursor line

**TUI:**
- Colored `!` marker in the gutter
- Underline style applied to cells in diagnostic ranges
- Diagnostic message in the status bar for the current cursor line

### Completion (Sprint 2 — Implemented)

Trigger with **Ctrl+Space**. A popup appears near the cursor showing LSP completion suggestions.

**Navigation:**
- Up/Down arrows to select
- Enter or Tab to accept (replaces word prefix at cursor)
- Escape to dismiss
- Any other key dismisses and passes through

**Both GUI and TUI** render the popup near the cursor position with scrolling for long lists. Detail information (type signatures etc.) is shown dimmed next to labels. Both response shapes are accepted (`CompletionList` and a bare item array); when a server omits `insertText` the `textEdit.newText` is used.

### Go-to-Definition (Sprint 3 — Implemented)

Press **F12** to jump to the definition of the symbol under the cursor. If the definition is in the same file, the cursor jumps to that line. If it's in a different file, the file is opened in a new tab and the cursor moves to the definition.

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
| `src/core/editor.zig` | Editor state (documents, mode, settings) |
| `src/core/keybind.zig` | Data-driven keybinding map |
| `src/core/syntax.zig` | Syntax highlighting engine (tokenizer, LanguageDef, built-in Zig) |
| `src/core/theme.zig` | Theme system (ThemeColor, EditorTheme, TuiTheme, SyntaxTheme, presets) |
| `src/core/layout.zig` | Split pane layout tree (binary tree of panes + splits) |
| `src/core/clipboard.zig` | System clipboard (Win32 API, Linux wl-copy/xclip/xsel) |
| `src/core/lsp.zig` | LSP client (JSON-RPC over stdio, one reader thread per server) + `ServerConfig` registrations |
| `src/core/lua_json.zig` | Lua table → JSON (register_lsp `settings` / `init_options`) |
| `src/core/lua_settings.zig` | Lua settings bridge (zide.set/get/bind/unbind, register_language, register_lsp) |
| `src/core/lua_api.zig` | Extension runtime API (zide.command/on/exec/status, buffer API, run/spawn, set_diagnostics) |
| `src/frontend/tui.zig` | TUI frontend (libvaxis) |
| `src/frontend/gui.zig` | GUI frontend (DVUI + SDL3) |

### Build Targets

- `zig build` — Both frontends (zide + zide-tui)
- `zig build -Dfrontend=tui` — TUI only
- `zig build -Dfrontend=gui` — GUI only
- `zig build run-tui` — Build and run TUI
- `zig build run-gui` — Build and run GUI (alias: `run`)
- `zig build test` — Run unit tests

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

### Hybrid Launch (Frontend Auto-Detection)

The `zide` binary contains **both** frontends and picks one at launch:

- **Typed in a terminal** (`zide`, `zide file.zig`) → opens the **TUI** in that terminal
- **Launched from the desktop** (Explorer double-click, Start menu, `start zide`) → opens the **GUI** window
- **Piped/redirected** (`zide file.zig | ...`) → GUI (a TUI would fight the redirection)
- `--gui` / `--tui` always override detection; `zide-tui` is TUI-only
- **`zide <folder>`** (either frontend) opens that folder as the **project**: it becomes the file tree root and the workspace sent to language servers for this launch, overriding `filetree_root` from init.lua. Files may follow: `zide . src/main.zig`. A project launch shows the welcome text instead of restoring the previous session (which may belong to another project). Only one folder is accepted; extra ones are reported and ignored.

On Windows the check uses `GetConsoleProcessList`: a console shared with a
parent shell means a real terminal launch, while a freshly allocated console
means a desktop launch (the stray console window is released). On Linux/macOS
both stdin and stdout must be a TTY.

### Saving

- `Ctrl+S` on a buffer **with** a file path saves it; failures show in the status bar
- `Ctrl+S` on an **untitled** buffer opens Save As (native dialog in the GUI, path prompt in the TUI)
- Quit-with-unsaved-changes (`[S]ave`) only quits if **every** dirty document saved; otherwise it cancels and reports how many failed

### Welcome Screen

Starting ZIDE without file arguments opens a scratch buffer containing the full
default hotkey reference (file, edit, find, multi-cursor, panes, terminal, LSP),
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
terminal directly.

### Command System

All editing actions go through named commands in `CommandRegistry`. Commands can be invoked by:
- Keyboard shortcuts (via data-driven keybind map, remappable through Lua). Lookup order: the active file's **language overlay** (`zide.bind(key, cmd, { language = "zig" })`) first, then the global map — for shift chords the exact combo is tried in both before the shift-stripped fallback, so a global exact binding always beats an overlay's fallback. Overlays are skipped while the file tree or search panel own the keyboard and in terminal panes
- Command palette (fuzzy search)
- Lua scripting: `zide.bind("ctrl+d", "delete_line")`, or per language: `zide.bind("ctrl+alt+j", "toggle_comment", { language = "zig" })`

50+ registered commands covering cursor movement, editing, selection, clipboard, line operations, and theme switching. Theme commands: `theme_dark`, `theme_light`, `theme_high_contrast`, `theme_terminal` (set both frontends); `gui_theme_dark/light/high_contrast` (GUI only); `tui_theme_dark/light/high_contrast` (TUI only). Additional "actions" (quit, save, find, find_replace, file_open, save_as, command_palette, goto_line, new_document, close_tab) are handled by the frontend but bindable via the keybind map.

## Embedded Terminal

ZIDE includes a built-in terminal emulator that integrates with the split pane system — in both frontends (in the TUI, the shell's grid renders as cells and the reader thread wakes the event loop via `terminal_wake_fn`, the same pattern the LSP uses).

### Opening a Terminal
- **Ctrl+`** (backtick): Toggle terminal — opens a terminal in a bottom split if none exists, focuses an existing terminal, or returns to the editor pane
- Shell: PowerShell on Windows, `$SHELL` (or `/bin/bash`) on Linux

### Terminal Features
- Full ANSI/VT escape sequence support (colors, cursor movement, erase, scroll regions, alternate screen buffer)
- 16-color, 256-color, and 24-bit RGB color support
- Bold, underline, and reverse video attributes
- Automatic resize when the pane dimensions change
- Process exit detection with `[Process exited]` message

### Terminal Commands
| Command | Keybind | Description |
|---------|---------|-------------|
| `toggle_terminal` | `Ctrl+\`` | Open/focus/unfocus terminal |
| `close_terminal` | — | Close the active terminal pane |

### Architecture
- **`src/core/pty.zig`** — Cross-platform PTY abstraction (ConPTY on Windows, posix on Linux)
  - Windows gotcha: the shell must be spawned with `STARTF_USESTDHANDLES` + NULL std handles, or CreateProcess's std-handle duplication overrides the pseudoconsole attachment and the terminal stays blank (bit us when the GUI started releasing its console)
- **`src/core/ansi.zig`** — VT/ANSI escape sequence state machine parser
- **`src/core/terminal.zig`** — Terminal emulator (cell grid, reader thread, key encoding)
- Terminal panes use the same split pane layout system as editor panes — they can be placed anywhere (horizontal or vertical splits)
- Background reader thread reads PTY output and updates a mutex-protected cell grid; the main thread reads the grid each frame for rendering

## File Tree

A toggleable side panel for browsing and managing the project directory, backed by a frontend-agnostic core model (`src/core/filetree.zig`) — both frontends render the same flattened row list, so expansion state, selection, file operations, and prompts behave identically in the GUI and the TUI.

### Basics
- **Ctrl+B** (`toggle_filetree`) cycles: hidden → shown + focused → (from the editor) focus the tree → (from the tree) hidden. Together with Escape this gives a full keyboard round-trip between editor and tree.
- Docks **left or right** (`filetree_side` setting, default left); width via `filetree_width` (GUI px) / `tui_filetree_width` (TUI columns).
- Starts **visible** by default — to launch with it closed, uncheck "File Tree Visible" in the settings dialog (persists to init.lua) or `zide.set("filetree_visible", false)`; Ctrl+B at runtime never writes settings.
- Root = current directory by default, or the folder given on the command line (`zide path/to/project` — see *Hybrid Launch*). Change it in the Settings dialog ("File Tree Root" — type a path, Enter applies; a bad path keeps the previous root and shows why) or `zide.set("filetree_root", "/path")`; "" resets to cwd. **Backspace / u** (or `filetree_root_up`) re-roots at the parent directory to climb the hierarchy.
- The panel header shows a clickable **up-button** (level-up icon in the GUI, `^` in the TUI) plus the full root path, truncated from the left (`...\Zig\ZIDE`) so the tail stays readable — click it to go up one folder.
- Files created, deleted, or renamed **outside ZIDE** (Explorer, a terminal) appear automatically: a cheap directory-mtime probe runs every ~1.5s and triggers the full rescan + git recolor only when something actually changed. (The TUI checks when input arrives, since its loop sleeps between events.)
- Directories sort first, names case-insensitive; children scan lazily on first expand; everything is listed, dotfiles and `.git` included.
- Indent guide lines mark each ancestor level (thin rules in the GUI, `│` columns in the TUI) so deep nesting stays readable.
- **GUI rows render VS Code-style**: chevron expanders on folders, per-type file icons in fixed accent colors (Zig orange, Lua blue, Markdown blue, images purple, executables green, folders steel blue, unknown types a dimmed generic document), the UI font instead of mono, a hover highlight under the pointer, and a selection bar that dims while the tree doesn't own the keyboard. Classification lives in `src/core/fileicons.zig` (frontend-agnostic — both frontends draw the same nerdfont glyphs, **per-language logos included**: the Zig zero, Lua moon, Rust gear, ...); special basenames beat extensions (README → book, LICENSE → shield, `.gitignore` → git, Makefile/Dockerfile/dotfiles → gear). The GUI renders the glyphs as text from the bundled Fira Code Nerd Font Mono, so they're always present — but if you point `mono_font_path` at a non-Nerd font, tree icons will show as boxes (pick any "NF" font to keep them). Entypo TinyVG icons remain for panel chrome (chevrons, header buttons). Extensions can override any assignment with `zide.set_icon` (see Extension Runtime API).
- **TUI icons** (opt-in): the `toggle_tui_icons` palette command (Ctrl+P — works live in the TUI and persists), `zide.set("tui_filetree_icons", true)`, or the GUI Settings dialog swaps the `+`/`-` glyphs for ▸/▾ chevrons plus nerdfont glyphs in truecolor accents — **per-language logos** where Nerd Fonts have them (the Zig zero, Lua moon, Rust gear, Python snakes, PowerShell badge, ... — codepoints follow nvim-web-devicons), category glyphs otherwise. The terminal font must be a patched Nerd Font or the glyphs render as boxes; off (the default) keeps the classic look. `zide.set_icon` overrides render the chosen kind's category glyph.
- **GUI scrollbar**: a slim pill appears over the rows' right edge when they overflow — drag it, or click the empty track above/below to page; the wheel still scrolls. (TUI rows are unchanged: `+`/`-` glyphs, terminal colors.)
- **GUI create/rename are inline**: `a`/`r` (or the menu) open an input box in the tree itself — rename replaces the entry's row (keeping its icon), create appears as a new row under the target folder whose icon flips to a folder the moment the input ends with `/`. Enter applies, Escape cancels, same validation as before. Delete keeps its y/n confirm bar, and the TUI keeps its status-line prompts.
- **Auto-reveal** (GUI): switching tabs (or opening a file any way) expands and selects that file in the tree without stealing keyboard focus — VS Code behavior, on by default; off via the Settings dialog or `zide.set("filetree_auto_reveal", false)`.
- **`/` search** (GUI): with the tree focused, press `/` and type — the selection jumps live to the next visible row whose name contains the query (case-insensitive, wraps past the end). The header shows `/query` while typing, in the warn color when nothing matches. Enter keeps the selection, Escape backs out, arrows exit search and navigate. (`/` is needed because plain letters are the j/k/a/r/d/x/p bindings.)
- **GUI header buttons** (right side): new file (+) starts an inline create under the selected folder; collapse-all (⊟) folds every directory back to the top level.
- **Multi-select**: Ctrl+click (GUI) toggles rows in and out of the selection, Shift+click (GUI) or Shift+Up/Down (both frontends) selects a visible range from the last plain selection, plain clicks/nav collapse back to one row (Escape also clears it, after cancelling a pending move). Delete, x/p moves, drag & drop, and copy-path all operate on the whole selection — dragging any selected row moves the group (including dragging straight out of the Ctrl/Shift+click itself; the drag carries the selection as it was when the press started), and a selected folder covers its selected children automatically.
- **The root is targetable** (GUI): click the empty space below the rows and the header highlights — create (`a`/+), paste, and x/p moves then land at the top level instead of inside a subfolder. Any row click clears it. (Drag & drop always had this: dropping on the header or empty space moves to the root.)
- **File clipboard** (GUI keys, commands in both frontends): with the tree focused, **Ctrl+C / Ctrl+X / Ctrl+V** copy, cut, and paste the selected entries as files — paste targets the selected folder (or a file's parent). Copy duplicates recursively, cut moves; both are no-clobber per entry and cut rows render dimmed until pasted. The clipboard is ZIDE-internal (not the OS file clipboard) and clears when the tree root changes.
- **Drag in from Explorer** (GUI): drop files or folders from the OS onto the tree to copy them into the folder under the cursor; drop a file onto the editor area to open it, or a folder to re-root the tree there.
- **Delete confirms in a clickable dialog** (GUI): Delete/Cancel buttons, with y/n/Enter/Escape still working; multi-selections show the item count. And a click anywhere off an inline create/rename entry cancels it — no Escape hunt after a mis-click.
- Opening a file that's already open switches to its existing tab instead of duplicating it.
- Binary files (NUL byte in the first 8 KiB — executables, images, ...) are refused instead of being loaded; this applies to every open path (tree, Ctrl+O, CLI, session restore). The GUI shows a toast ("Not opened: binary or unsupported text encoding") plus the status-bar message; the TUI uses the status bar.

### Keys (while the tree is focused)
| Key | Action |
|-----|--------|
| Up/Down or k/j | Move selection |
| Home/End | First / last row |
| Enter | Expand/collapse dir, or open file (focus moves to editor) |
| Right / Left | Expand dir / collapse dir (or jump to parent) |
| a | New file — end with `/` for a folder; nested paths like `sub/file.txt` create intermediate folders |
| r | Rename (no-clobber; renaming updates open tabs, including files inside a renamed folder) |
| Shift+R | Refresh from disk (expansion and selection preserved) |
| d | Delete — clickable Delete/Cancel dialog in the GUI (y/n/Enter/Esc too), y/n prompt in the TUI; directories delete recursively; deletes the whole multi-selection |
| Backspace or u | Re-root the tree at the parent directory |
| x then p | Move: x marks the selected entry (or the whole multi-selection), p drops into the selected folder (or a selected file's folder); no-clobber, open tabs follow |
| Shift+Up/Down | Extend a range selection row by row (both frontends) |
| Ctrl+C / X / V | (GUI) File clipboard: copy / cut the selection, paste into the selected folder |
| / | (GUI) Incremental name search — type to jump, Enter/Escape ends, arrows exit and navigate |
| Escape | Cancel a pending x move first, then clear a multi-selection; otherwise return focus to the editor |

Ctrl/Alt chords (Ctrl+P, Ctrl+B, ...) still work while the tree is focused.

### Mouse
- Single click: selects the row only — except on a folder's chevron (`+`/`-` in the TUI), which toggles immediately; clicking the header's up-button goes up one folder. Ctrl+click toggles multi-selection, Shift+click range-selects; while an inline create/rename is open, clicking anywhere else cancels it
- Double click (400ms, same row): expands/collapses a folder or opens a file — a stray single click never opens or collapses anything
- Wheel over the panel: scrolls the tree independently of the editor
- Drag & drop (GUI): drag a row ~5px to start a move — the drop target highlights (a folder, a file's folder, or the header/empty space = root) with a live "Move X -> Y" status; release performs it. Dropping into the same place or into the moved folder itself is rejected. No drag ghost or edge auto-scroll yet
- Drag the panel's editor-facing edge (GUI, ⇄ cursor): resize the panel — the width persists to init.lua on release; a separator line marks the edge
- Right-click (GUI): context menu (New / Rename / Delete / Copy Path / Copy Relative Path / Reveal in Explorer / Up One Folder / Move Tree to Left-Right / Refresh / Reveal Current File); the side choice persists to init.lua
- Header buttons (GUI): new file and collapse-all on the right, up-one-folder on the left

### TUI specifics
- Rendered as a column band with a `│` separator; the terminal cursor hides while the tree is focused (the selection bar takes its place) and the panel header brightens
- Panel is skipped (and focus released) below 40 terminal columns; width is capped at half the terminal
- Create/rename/delete prompts appear on the status line, same as Save As (the delete prompt shows the count for a multi-selection)
- Multi-select is keyboard-driven: Shift+Up/Down extends, Escape clears, and d/x/p operate on the whole selection through the same core as the GUI
- Nerdfont icons via `tui_filetree_icons` (see the icons bullet in Basics)

### Commands (palette)
| Command | Description |
|---------|-------------|
| `toggle_filetree` | Show/hide the panel (Ctrl+B) |
| `filetree_reveal` | Expand to and select the current file (also View menu) |
| `filetree_refresh` | Rescan from disk |
| `filetree_collapse_all` | Fold every directory back to the top level |
| `filetree_copy_path` | Copy the selected entry's absolute path to the clipboard |
| `filetree_copy_relative_path` | Copy the selected entry's root-relative path (native separators) |
| `filetree_reveal_explorer` | Show the selected entry in the system file manager (Explorer `/select` on Windows, `open -R` on macOS, `xdg-open` of the parent elsewhere) |
| `toggle_tui_icons` | Toggle the TUI tree's nerdfont icons live (the TUI has no settings panel); persists to init.lua |
| `filetree_copy` / `filetree_cut` | Fill the file clipboard from the selection (Ctrl+C/X while the tree is focused) |
| `filetree_paste` | Paste the file clipboard into the selected folder (Ctrl+V) — cut moves, copy copies recursively |

### Git status colors
Tree rows are colored from `git status --porcelain` (a one-shot `git` shell-out — no libgit2): **untracked** and **added** files green/teal, **modified** amber, and any directory containing changes rolls up as modified; children of an untracked folder inherit untracked. In the GUI each changed row also gets a right-edge **badge**: an A/M/D/U letter on files, a `•` dot on directories rolling up changes (long names clip before the badge instead of running under it). Refreshed on panel load, manual refresh (Shift+R / `filetree_refresh`), after create/rename/delete, and after saves (including auto-save). Outside a git repo (or without git installed) rows simply stay uncolored. Colors are theme fields overridable via `zide.set("color_git_added" | "color_git_modified" | "color_git_deleted" | "color_git_untracked", "#hex")` and the `tui_color_git_*` equivalents.

### Settings
Settings dialog (GUI) or `zide.set` in init.lua: `filetree_visible` (bool, default true), `filetree_side` ("left"/"right"), `filetree_width` (120–600 px), `tui_filetree_width` (16–80 cols), `filetree_root` (path text field in the dialog — Enter applies and persists), `filetree_git_colors` (bool, default true — off stops the git status coloring and its `git status` subprocess calls entirely), `filetree_auto_reveal` (bool, default true — select the active file in the tree on tab switch), `tui_filetree_icons` (bool, default false — nerdfont icons in the TUI tree; needs a Nerd Font terminal font), `filetree_font_size` (GUI, points, 0 = theme default — row height, text, and icons all scale together), `filetree_icon_scale` (GUI, 50–200 — icon size as a percentage of the row font, default 90). The TUI's sizes are the terminal's font size — nothing to configure there.

## Performance
- **Gap buffer** text storage — inserts/deletes at cursor are O(1) amortized instead of O(n) memmove
- Undo history capped at 100 operations per document (configurable via `zide.set("max_undo_history", N)`, 0 = unlimited)
- Command palette names cached (no per-frame allocation)
- Delete operations record history before modifying buffer (single allocation instead of double-copy)
- GUI: monospace font optimization (char_width multiplication replaces font API calls)
- GUI: cursor blink uses animation timer instead of continuous refresh
- GUI: tab expansion columns pre-computed once per line, not per wrap row
- TUI: vaxis cell-level diffing (only changed cells sent to terminal)

