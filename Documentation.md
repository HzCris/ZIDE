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
- Indent/Dedent (Tab/Shift+Tab, respects tab_width and use_tabs settings)
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
- Ctrl+Home/End for file start/end
- Page Up/Down

**Display:**
- Syntax highlighting (Zig built-in, extensible via Lua — see Syntax Highlighting section)
- TODO comment highlighting: `TODO`/`FIXME`/`XXX`/`HACK`/`BUG`/`NOTE` inside comments get the `todo` syntax color; `next_todo` command (palette) jumps to the next marker with wrap-around
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
- Dirty tracking
- Unsaved changes prompt on quit (Save/Discard/Cancel)
- Session persistence (opt-in: `zide.set("session_persistence", true)` or the Settings dialog): on quit the open files, cursor positions, scroll offsets and active tab are written to `~/.config/zide/session`; launching ZIDE without file arguments restores them (missing files are skipped, untitled buffers are not recorded). Applies to both frontends.

**Configuration:**
- Config folder hierarchy: `~/.config/zide/` with `themes/` and `extensions/` subfolders
- Lua settings file (`~/.config/zide/init.lua`)
  - `zide.set(key, value)` — tab_width, use_tabs, word_wrap, auto_close_brackets, page_size, auto_save, auto_save_interval_ms, click_clears_cursors, max_undo_history, session_persistence, filetree_visible, filetree_side ("left"/"right"), filetree_width (GUI px), tui_filetree_width (columns), filetree_root (starting directory, "" = cwd)
  - `zide.set("mono_font_path", "/path/to/font.ttf")` — use a custom monospace font (e.g. a Nerd Font for box-drawing and powerline glyphs in the embedded terminal)
  - `zide.set("mono_font_size", 14)` — override the default monospace font size
  - `zide.set("tui_theme", name)` — switch TUI theme ("terminal", "dark", "light", "high_contrast")
  - `zide.set("tui_color_*", "#hex")` — override individual TUI color (e.g. `tui_color_text_fg`)
  - `zide.set("syn_*", "#hex")` — override syntax highlight color (e.g. `syn_keyword`, `syn_comment`)
  - `zide.set("tui_syn_*", "#hex")` — override TUI-only syntax color
  - `zide.register_language({...})` — register a language for syntax highlighting (see Syntax Highlighting section)
  - `zide.register_lsp({...})` — register an LSP server for a language (see LSP Support section)
  - `zide.get(key)` — read current settings
  - `zide.bind(key_combo, command)` — remap keybindings
  - `zide.unbind(key_combo)` — remove a keybinding
- Data-driven keybinding map (all Ctrl/Alt shortcuts remappable)
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
- Word wrap (word-boundary aware, configurable, wrap continuation markers)
- Save / Save As (native OS file dialog)
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
- Keybinding remapping (Lua integration — `zide.bind`/`zide.unbind` via init.lua)
- Auto-save (saves dirty documents with file paths after configurable interval, default 5s)
- Application icon embedded in exe
- SDL3GPU backend (GPU-accelerated rendering, opt-in via `zig build -Dgpu=true`, default SDL3 for lower memory)
- Find/Replace match count display (shows "N matches" in overlay bar)
- Command palette Tab/arrow cycling with highlighted selection (Enter executes selected)
- Configurable line number gutter width (`zide.set("gutter_min_digits", N)` in init.lua, default 3)
- Mouse selection: double-click selects word, triple-click selects line, drag extends by word/line accordingly, Shift+click extends selection, Alt+click adds cursor, Shift+Alt+drag for block (column) selection (one cursor per line over the dragged column span)

- File tree side panel (Ctrl+B) — dockable left/right, click + keyboard browsing, create/rename/delete with prompts, right-click context menu, reveal-current-file (see File Tree section)
- Settings dialog (Preferences menu — modal DVUI floating window with native widgets: checkboxes for booleans, validated numeric entries with min/max, dropdown for theme; draggable by header, auto-centered, dims the background; changes apply live and write to init.lua immediately; close via header X or Escape; Tab/Shift+Tab cycles controls)
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
- Theme setting in Settings dialog: dropdown (dark/light/high_contrast) — TUI settings panel keeps the cycleable enum (Enter/Space cycles)
- Open Theme File: opens `~/.config/zide/themes/gui-theme.lua` in editor (creates commented template with per-field descriptions if missing)
- Open Theme Folder: opens `~/.config/zide/themes/` in OS file explorer
- Help > Documentation: opens Documentation.md in the editor
- Tab bar styling: inactive tabs have visible borders and control-style background
- Right-click context menu in editor panes: Cut, Copy, Paste, Select All, Go to Definition
  - Right-click outside the selection moves the cursor to the click point first; inside the selection it keeps the selection (so Cut/Copy act on it)

### GUI — Not Yet Implemented
- (none currently)

---

## Syntax Highlighting

### Overview

ZIDE uses an **extension-first** architecture for syntax highlighting. Language definitions are data — loaded from Lua files at startup — not hardcoded into the binary. Only **Zig** is built-in (it's a Zig IDE). Users install extensions for other languages by placing Lua files in `~/.config/zide/extensions/`.

### How It Works

1. **Startup**: ZIDE scans `~/.config/zide/extensions/*.lua` and executes each file. Extensions call `zide.register_language({...})` to register language definitions.
2. **File open**: Language is detected from the file extension (e.g., `.zig` → Zig, `.py` → Python if registered).
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

-- React to editor events. The handler gets the file path (nil = untitled).
zide.on("save", function(path)
    zide.status("Saved: " .. (path or "untitled"))
end)
```

| Call | Description |
|------|-------------|
| `zide.command(name, desc, fn)` | Register a command — listed in the palette, runnable via `zide.bind`/`zide.exec`. Re-registering a name replaces it; shadowing a built-in is allowed (logged). `fn` receives the optional args string (usually nil). |
| `zide.on(event, fn)` | Hook an event. Events: `"open"` (file opened into a tab), `"save"` (file written — fires per document on auto-save too). `fn(path)` gets the file path or nil. |
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

The `reload_extensions` command (palette) drops all Lua-registered commands
and event handlers and re-runs every `extensions/*.lua` — edit-extension,
reload, retry without restarting ZIDE. (Lua globals your scripts set persist
across reloads; top-level state is re-initialized by your script itself.)

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

ZIDE includes a built-in LSP (Language Server Protocol) client that communicates with language servers over stdio JSON-RPC. ZLS (Zig Language Server) is started automatically when ZIDE launches — by default `zls` from PATH, overridable from `init.lua` (see *Lua LSP API* below). The user config is loaded **before** the server starts so the override can take effect.

Startup feedback appears in the status bar: "LSP ready" once the handshake completes, or "LSP server not found — completions disabled" if it couldn't be started. Details (including the exact command tried) land in the log file (see Logging under Shared / Core). The server's own stderr is discarded, and on Windows the server is spawned with `CREATE_NO_WINDOW` so no console window appears.

Documents are only synced to the server when their detected language matches the server's language (`zig` for the built-in zls client) — a `.txt` or `.md` buffer never reaches zls, so it can't get bogus Zig diagnostics. The status bar shows each document's detected language (e.g. `Ln 1, Col 1 | zig`, or `plain text` when nothing matched), so it's always visible what syntax/LSP applies.

### Architecture

- **Background reader thread** reads JSON-RPC messages from the language server's stdout and pushes them onto a thread-safe ring buffer queue
- **Main thread** polls the queue each frame (GUI) or event loop iteration (TUI) — no blocking
- **Full-text document sync** with version coalescing: rapid keystrokes are batched into a single `didChange` notification per frame
- In the TUI, the reader thread wakes the blocking event loop via `loop.postEvent(.lsp_data)`

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

**Both GUI and TUI** render the popup near the cursor position with scrolling for long lists. Detail information (type signatures etc.) is shown dimmed next to labels.

### Go-to-Definition (Sprint 3 — Implemented)

Press **F12** to jump to the definition of the symbol under the cursor. If the definition is in the same file, the cursor jumps to that line. If it's in a different file, the file is opened in a new tab and the cursor moves to the definition.

### Lua LSP API (Sprint 3 — Implemented)

Configure the language server via `~/.config/zide/init.lua`:

```lua
-- Point the built-in Zig server at a specific zls binary
-- (e.g. the one matching your 0.16 toolchain instead of the PATH zls):
zide.register_lsp({
    language = "zig",
    command = "C:/Users/you/tools/zig-0.16.0/ZLS/zls.exe",
})
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `language` | string | yes | Language name, case-insensitive (must match a registered language's name) |
| `command` | string | yes | LSP server executable — a name resolved via PATH or a full path |

At startup ZIDE starts **one** server: the one registered for the active LSP
language (`zig` by default; first matching entry wins), falling back to plain
`zls` from PATH when nothing matches. Entries for other languages are stored
but not yet started — multi-server support is future work.

### Document Lifecycle

| Event | LSP Notification |
|-------|-----------------|
| File opened | `textDocument/didOpen` |
| Text edited | `textDocument/didChange` (full text, coalesced per frame) |
| File saved | `textDocument/didSave` |
| Tab closed | `textDocument/didClose` |

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
| `src/core/lsp.zig` | LSP client (JSON-RPC over stdio, background reader thread) |
| `src/core/lua_settings.zig` | Lua settings bridge (zide.set/get/bind/unbind) |
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
- Keyboard shortcuts (via data-driven keybind map, remappable through Lua)
- Command palette (fuzzy search)
- Lua scripting: `zide.bind("ctrl+d", "delete_line")`

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
- Root = current directory by default. Change it in the Settings dialog ("File Tree Root" — type a path, Enter applies; a bad path keeps the previous root and shows why) or `zide.set("filetree_root", "/path")`; "" resets to cwd. **Backspace / u** (or `filetree_root_up`) re-roots at the parent directory to climb the hierarchy.
- The panel header shows a clickable **`^` up-button** plus the full root path, truncated from the left (`...\Zig\ZIDE`) so the tail stays readable — click the `^` to go up one folder.
- Files created, deleted, or renamed **outside ZIDE** (Explorer, a terminal) appear automatically: a cheap directory-mtime probe runs every ~1.5s and triggers the full rescan + git recolor only when something actually changed. (The TUI checks when input arrives, since its loop sleeps between events.)
- Directories sort first, names case-insensitive; children scan lazily on first expand; everything is listed, dotfiles and `.git` included.
- Indent guide lines mark each ancestor level (thin rules in the GUI, `│` columns in the TUI) so deep nesting stays readable.
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
| d | Delete (y/n confirm; directories delete recursively) |
| Backspace or u | Re-root the tree at the parent directory |
| x then p | Move: x marks the selected entry, p drops it into the selected folder (or a selected file's folder); no-clobber, open tabs follow |
| Escape | Cancel a pending x move first; otherwise return focus to the editor |

Ctrl/Alt chords (Ctrl+P, Ctrl+B, ...) still work while the tree is focused.

### Mouse
- Single click: selects the row only — except on a folder's `+`/`-` glyph, which toggles immediately; clicking the header's `^` goes up one folder
- Double click (400ms, same row): expands/collapses a folder or opens a file — a stray single click never opens or collapses anything
- Wheel over the panel: scrolls the tree independently of the editor
- Drag & drop (GUI): drag a row ~5px to start a move — the drop target highlights (a folder, a file's folder, or the header/empty space = root) with a live "Move X -> Y" status; release performs it. Dropping into the same place or into the moved folder itself is rejected. No drag ghost or edge auto-scroll yet
- Drag the panel's editor-facing edge (GUI, ⇄ cursor): resize the panel — the width persists to init.lua on release; a separator line marks the edge
- Right-click (GUI): context menu (New / Rename / Delete / Up One Folder / Move Tree to Left-Right / Refresh / Reveal Current File); the side choice persists to init.lua

### TUI specifics
- Rendered as a column band with a `│` separator; the terminal cursor hides while the tree is focused (the selection bar takes its place) and the panel header brightens
- Panel is skipped (and focus released) below 40 terminal columns; width is capped at half the terminal
- Create/rename/delete prompts appear on the status line, same as Save As

### Commands (palette)
| Command | Description |
|---------|-------------|
| `toggle_filetree` | Show/hide the panel (Ctrl+B) |
| `filetree_reveal` | Expand to and select the current file (also View menu) |
| `filetree_refresh` | Rescan from disk |

### Git status colors
Tree rows are colored from `git status --porcelain` (a one-shot `git` shell-out — no libgit2): **untracked** and **added** files green/teal, **modified** amber, and any directory containing changes rolls up as modified; children of an untracked folder inherit untracked. Refreshed on panel load, manual refresh (Shift+R / `filetree_refresh`), after create/rename/delete, and after saves (including auto-save). Outside a git repo (or without git installed) rows simply stay uncolored. Colors are theme fields overridable via `zide.set("color_git_added" | "color_git_modified" | "color_git_deleted" | "color_git_untracked", "#hex")` and the `tui_color_git_*` equivalents.

### Settings
Settings dialog (GUI) or `zide.set` in init.lua: `filetree_visible` (bool, default true), `filetree_side` ("left"/"right"), `filetree_width` (120–600 px), `tui_filetree_width` (16–80 cols), `filetree_root` (path text field in the dialog — Enter applies and persists).

## Performance
- **Gap buffer** text storage — inserts/deletes at cursor are O(1) amortized instead of O(n) memmove
- Undo history capped at 100 operations per document (configurable via `zide.set("max_undo_history", N)`, 0 = unlimited)
- Command palette names cached (no per-frame allocation)
- Delete operations record history before modifying buffer (single allocation instead of double-copy)
- GUI: monospace font optimization (char_width multiplication replaces font API calls)
- GUI: cursor blink uses animation timer instead of continuous refresh
- GUI: tab expansion columns pre-computed once per line, not per wrap row
- TUI: vaxis cell-level diffing (only changed cells sent to terminal)

