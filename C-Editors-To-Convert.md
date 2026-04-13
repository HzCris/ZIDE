### Terminal-Based Editors (Easiest to Port)

**1. Kilo** — The canonical starting point
- Under 1,000 lines of pure C
- Zero dependencies (not even ncurses—uses VT100 escape sequences directly)
- Features: syntax highlighting, search, basic editing
- License: BSD-2
- Why it ports well: The code is extremely minimal and uses straightforward C that maps excellently to Zig's C interop capabilities
- GitHub: github.com/antirez/kilo

**2. dte** — Feature-rich but still lightweight
- Multiple buffers, unlimited undo/redo, regex search/replace
- Syntax highlighting, customizable key bindings, keyboard macros
- Fast startup (~10ms), portable POSIX
- License: GPL-2.0
- GitHub: github.com/craigbarnes/dte

**3. ptext** — Actively maintained kilo derivative
- Nano-like editor in pure C
- No ncurses dependency
- Last commit: December 2024 (207 stars)
- License: BSD-2-Clause
- GitHub: github.com/proh14/ptext

**4. OpusEdit** — Modern feature set
- Syntax highlighting, undo/redo, multi-cursor, multi-buffer
- Visual selection, incremental search, find/replace, line numbers
- Auto-indent, git gutter
- License: MIT
- GitHub: github.com/Ayanprogrammer11/opus-edit

**5. Cedit** — Embedded-friendly
- Zero dependencies, single-file program
- Syntax highlighting for 20+ languages
- VT100 compliant, runs on embedded devices
- License: Apache 2.0
- GitHub: github.com/chaitanyarahalkar/Cedit

### Line Editing Libraries (For REPL/CLI Input)

**6. Linenoise** — Battle-tested line editor
- Used in Redis, MongoDB, Android
- ~850-1100 lines, UTF-8 support, history, completion
- License: BSD-2

**7. Bestline** — Enhanced linenoise fork
- Kill ring, better Emacs shortcuts, Ctrl-R search
- Still very small (~38KB binary statically linked)
- License: BSD-2
- GitHub: github.com/jart/bestline

### GUI-Based Options

**8. Lite XL** — Hybrid C+Lua architecture
- Under 5MB bundle, runs on low-resource hardware
- Multiline editing, autocomplete, pane splitting
- Cross-platform (Linux, Windows, macOS, Android)
- Interesting for Zig: demonstrates mixing C (system integration) with scripting (functionality)
- GitHub: github.com/lite-xl/lite-xl

**9. Light** — Minimalist with plugin system
- Sub-10KB binary footprint, zero runtime overhead
- Asynchronous console I/O, keyboard-driven
- Plugin architecture using C functions
- Could translate well to Zig's module system
- GitHub: github.com/thisismars-x/light

**10. lightwrite** — SDL2-based GUI editor
- Plain C with SDL2
- Shows GUI implementation approach in C
- License: MIT
- GitHub: github.com/tim-tm/lightwrite

**11. GtkWrite/GtkEdit** — Pure C GUI option
- Uses GtkTextView (not Scintilla)
- ~130KB stripped binary, well-commented
- Features: syntax highlighting, undo/redo, find/replace, line numbers
- Dependencies: GTK+2, optionally GtkSourceView2
- License: GPL-2.0
- GitHub: github.com/drankinatty/gtkwrite

### Industry-Standard Component

**12. Scintilla** — Worth knowing about
- Used in Notepad++, SciTE, and many others
- Most feature-complete: syntax styling, folding, code completion, call tips
- Note: Written in C++ (not pure C), requires C++17
- Makes direct Zig conversion more challenging

### Licensing Implications
If commercial IDE development is your goal, pay attention to licenses:
- **BSD-2** (Kilo, Linenoise, Bestline, kg): Permissive, allows commercial use with minimal restrictions
- **MIT** (OpusEdit, lightwrite): Very permissive
- **GPL-2.0** (dte, GtkWrite): Copyleft—requires your project to be GPL-compatible
- **Apache 2.0** (Cedit): Permissive, allows commercial use

