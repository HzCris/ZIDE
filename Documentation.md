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
- Syntax highlighting themes

---

## GUI Frontend

### GUI — Implemented Features

- DVUI + SDL3 window with editor pane
- Text editing via DVUI TextEntryWidget (undo/redo/clipboard handled by widget)
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
- Syntax highlighting themes

---

## Shared / Core

### Architecture

| File | Purpose |
|------|---------|
| `src/main.zig` | Entry point, CLI parsing, mode detection |
| `src/core/buffer.zig` | Text storage (ArrayList-based) |
| `src/core/document.zig` | Document model (buffer + cursors + undo + metadata) |
| `src/core/cursor.zig` | Cursor and CursorSet (multi-cursor data model) |
| `src/core/undo.zig` | Undo/redo history |
| `src/core/commands.zig` | Command registry and all built-in commands |
| `src/core/editor.zig` | Editor state (documents, mode, settings) |
| `src/core/keybind.zig` | Data-driven keybinding map |
| `src/core/theme.zig` | Theme system (ThemeColor, EditorTheme, TuiTheme, presets) |
| `src/core/layout.zig` | Split pane layout tree (binary tree of panes + splits) |
| `src/core/clipboard.zig` | System clipboard (Win32 API, Linux wl-copy/xclip/xsel) |
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
- Undo history capped at 100 operations per document (configurable via `zide.set("max_undo_history", N)`, 0 = unlimited)
- Command palette names cached (no per-frame allocation)
- Delete operations record history before modifying buffer (single allocation instead of double-copy)
