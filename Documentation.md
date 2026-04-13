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
| Ctrl+D | Add next occurrence (multi-cursor) |
| Ctrl+Shift+D | Duplicate line |
| Ctrl+Shift+Up/Down | Add cursor above/below |
| Ctrl+K | Delete line |
| Escape | Remove secondary cursors |
| Ctrl+Left/Right | Word movement |
| Ctrl+Shift+Left/Right | Word selection |
| Ctrl+Backspace | Delete word backward |
| Ctrl+Delete | Delete word forward |
| Ctrl+Home/End | Jump to file start/end |
| Ctrl+Shift+Home/End | Select to file start/end |
| Ctrl+W | Close tab |
| Ctrl+Shift+S | Save As |
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
- Copy/Cut/Paste with system clipboard (Windows Win32 API)

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
- Left click to position cursor
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
- Lua settings file (`~/.config/zide/init.lua`)
  - `zide.set(key, value)` — tab_width, use_tabs, word_wrap, auto_close_brackets, page_size, auto_save, auto_save_interval_ms
  - `zide.get(key)` — read current settings
  - `zide.bind(key_combo, command)` — remap keybindings
  - `zide.unbind(key_combo)` — remove a keybinding
- Data-driven keybinding map (all Ctrl/Alt shortcuts remappable)
- Auto-save (saves dirty documents with file paths after configurable interval, default 5s)
- Application icon embedded in exe
- Multiple cursor editing (Ctrl+Shift+Up/Down to add cursors, Ctrl+D for next occurrence, Escape to clear)

### TUI — Not Yet Implemented
- Theme system (Lua and however Windows wants to fight)

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
- Mouse selection: double-click selects word, triple-click selects line, drag extends by word/line accordingly, Shift+click extends selection

- Settings panel (Edit menu — visual editor for all settings, mouse-clickable, writes to init.lua)
- Open Settings File (Edit menu — opens init.lua directly in the editor for power users)
- Tab character display (expands `\t` to spaces for rendering, cursor, selection, and wrapping)
- Blinking caret (530ms cycle, resets on cursor movement)
- Multiple cursor editing (Ctrl+Shift+Up/Down to add cursors, Ctrl+D for next occurrence, Escape to clear)

### GUI — Not Yet Implemented
- GUI block adjusting (Think how you can move the editor/terminal/filetree around in neovim/vs code)
- Theme system (DVUI theme integration or Lua)

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
| `src/core/clipboard.zig` | System clipboard (Win32 API) |
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

40+ registered commands covering cursor movement, editing, selection, clipboard, and line operations. Additional "actions" (quit, save, find, find_replace, file_open, save_as, command_palette, goto_line, new_document, close_tab) are handled by the frontend but bindable via the keybind map.
