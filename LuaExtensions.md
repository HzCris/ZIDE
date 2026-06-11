# Extensions that every IDE has over a text editor.

## TUI
- [x] Syntax highlighting
- [x] LSP support
- [x] File tree / project browser (Ctrl+B toggle, dockable left/right via `filetree_side`, starting directory via `zide.set("filetree_root", path)`, a/r/d file ops, Shift+R refresh, reveal-current-file, git status row colors)
- [] LLM support using OpenAI API for various cloud providers and local LLMs (And claude if allowed)
- [] Git integration (gutter signs)
- [] Terminal Splitting
- [x] Block/column selection (Alt+drag; Ctrl+Shift+Up/Down and Alt+click already stacked cursors)
- [x] Ctrl+/ to comment highlighted text (uses register_language's line_comment/block_comment fields — upkeep lives in Lua configs)
- [] Debug Support
- [] Nerdfont/Custom Icon integration
- [x] Session Persistance Option (`zide.set("session_persistence", true)` — restores files/cursors/active tab on bare launch)
- [x] TODO comment integration (TODO/FIXME/XXX/HACK/BUG/NOTE highlighted in comments, `next_todo` palette command, `syn_todo` color override)
- [] Linting
- [] Extension fetching (Think like how neovim pulls from github/codeberg)

## GUI
- [x] LSP support
- [x] Embedded Terminal
- [x] Syntax highlighting
- [x] Block/column selection
- [x] File tree / project browser (Ctrl+B toggle, dockable left/right, starting directory via `filetree_root`, click + keyboard browsing, right-click menu, a/r/d file ops, git status row colors)
- [] LLM support using OpenAI API for various cloud providers and local LLMs (And claude if allowed)
- [] Git integration (gutter signs)
- [x] Ctrl+/ to comment highlighted text (uses register_language's line_comment/block_comment fields — upkeep lives in Lua configs)
- [] Debug Support
- [] Nerdfont/Custom Icon integration
- [x] Session Persistance Option (`zide.set("session_persistence", true)` or Settings dialog — restores files/cursors/active tab on bare launch)
- [x] TODO comment integration (TODO/FIXME/XXX/HACK/BUG/NOTE highlighted in comments, `next_todo` palette command, `syn_todo` color override)
- [] Linting
- [] Extension fetching (Think like how neovim pulls from github/codeberg)
