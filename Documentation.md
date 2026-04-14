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
| Alt+Shift+Up/Down | Add cursor above/below (TUI fallback) |
| Ctrl+Space | LSP completion |
| F12 | LSP go-to-definition |
| Alt+Click | Add cursor at click position |
| Ctrl+K | Delete line |
| Escape / Left-click | Remove secondary cursors |
| Ctrl+Left/Right | Word movement |
| Ctrl+Shift+Left/Right | Word selection |
| Ctrl+Backspace | Delete word backward |
| Ctrl+Delete | Delete word forward |
| Ctrl+Home/End | Jump to file start/end |
| Ctrl+Shift+Home/End | Select to file start/end |
| Ctrl+W | Close tab |
| Ctrl+Shift+W | Close pane |
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

### TUI — Implemented Features

**Editing:**
- Insert, delete, backspace, newline with auto-indent
- Undo/redo history
- Word movement and word delete (Ctrl+Left/Right, Ctrl+Backspace/Delete)
- Line operations: delete (Ctrl+K), duplicate (Ctrl+D), move up/down (Alt+Up/Down)
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
- Left drag to select text
- Scroll wheel to scroll viewport (independent of cursor position)

**Documents / File I/O:**
- Multi-document tabs (Ctrl+N new, Ctrl+W close, open by path)
- Open file by path (Ctrl+O)
- Save (Ctrl+S), Save As (Ctrl+Shift+S)
- Line ending detection (LF / CRLF)
- Dirty tracking
- Unsaved changes prompt on quit (Save/Discard/Cancel)

**Configuration:**
- Config folder hierarchy: `~/.config/zide/` with `themes/` and `extensions/` subfolders
- Lua settings file (`~/.config/zide/init.lua`)
  - `zide.set(key, value)` — tab_width, use_tabs, word_wrap, auto_close_brackets, page_size, auto_save, auto_save_interval_ms, click_clears_cursors, max_undo_history
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
- Auto-save (saves dirty documents with file paths after configurable interval, default 5s)
- Application icon embedded in exe
- Multiple cursor editing (Ctrl+Shift or Alt+Shift+Up/Down, Ctrl+D, Alt+click, Escape/click to clear)
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
- Word wrap (word-boundary aware, configurable, wrap continuation markers)
- Save / Save As (native OS file dialog)
- Open file (native OS file dialog)
- Multi-document tabs (tab bar with close buttons)
- New document (Ctrl+N)
- Tab switching (Ctrl+Tab / Ctrl+Shift+Tab via menu)
- Status bar (filename, dirty marker, Ln/Col)
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
- Mouse selection: double-click selects word, triple-click selects line, drag extends by word/line accordingly, Shift+click extends selection, Alt+click adds cursor

- Settings panel (Preferences menu — visual editor for all settings including theme, mouse-clickable, writes to init.lua)
- Open Settings File (Preferences menu — opens init.lua directly in the editor for power users)
- Tab character display (expands `\t` to spaces for rendering, cursor, selection, and wrapping)
- Blinking caret (530ms cycle, resets on cursor movement)
- Multiple cursor editing (Ctrl+Shift or Alt+Shift+Up/Down, Ctrl+D, Alt+click, Escape/click to clear)
- Split panes: vertical (Alt+\) and horizontal (Alt+Shift+\) splits with draggable dividers
  - Binary layout tree — nested splits supported (split a split)
  - Click to focus pane, focused pane highlighted with border
  - Close pane (Ctrl+Shift+W), navigate via command palette (`focus_next_pane`, `focus_prev_pane`)
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
- Theme setting in Settings panel: cycleable enum (Enter/Space/Click cycles through dark/light/high_contrast)
- Open Theme File: opens `~/.config/zide/themes/gui-theme.lua` in editor (creates commented template with per-field descriptions if missing)
- Open Theme Folder: opens `~/.config/zide/themes/` in OS file explorer
- Help > Documentation: opens Documentation.md in the editor
- Tab bar styling: inactive tabs have visible borders and control-style background

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

#### Extension Directory

```
~/.config/zide/
├── init.lua                          # Main settings
├── extensions/                       # Language extensions
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

ZIDE includes a built-in LSP (Language Server Protocol) client that communicates with language servers over stdio JSON-RPC. ZLS (Zig Language Server) is started automatically when ZIDE launches, if `zls` is found in PATH.

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

Register additional language servers via `~/.config/zide/init.lua`:

```lua
zide.register_lsp({
    language = "Python",
    command = "pyright-langserver",
})
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `language` | string | yes | Language name (must match a registered language's name) |
| `command` | string | yes | LSP server executable (must be in PATH) |

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

### Command System

All editing actions go through named commands in `CommandRegistry`. Commands can be invoked by:
- Keyboard shortcuts (via data-driven keybind map, remappable through Lua)
- Command palette (fuzzy search)
- Lua scripting: `zide.bind("ctrl+d", "delete_line")`

50+ registered commands covering cursor movement, editing, selection, clipboard, line operations, and theme switching. Theme commands: `theme_dark`, `theme_light`, `theme_high_contrast`, `theme_terminal` (set both frontends); `gui_theme_dark/light/high_contrast` (GUI only); `tui_theme_dark/light/high_contrast` (TUI only). Additional "actions" (quit, save, find, find_replace, file_open, save_as, command_palette, goto_line, new_document, close_tab) are handled by the frontend but bindable via the keybind map.

### Performance
- **Gap buffer** text storage — inserts/deletes at cursor are O(1) amortized instead of O(n) memmove
- Undo history capped at 100 operations per document (configurable via `zide.set("max_undo_history", N)`, 0 = unlimited)
- Command palette names cached (no per-frame allocation)
- Delete operations record history before modifying buffer (single allocation instead of double-copy)
- GUI: monospace font optimization (char_width multiplication replaces font API calls)
- GUI: cursor blink uses animation timer instead of continuous refresh
- GUI: tab expansion columns pre-computed once per line, not per wrap row
- TUI: vaxis cell-level diffing (only changed cells sent to terminal)
