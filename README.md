# ZIDE

Zimplified Integrated Development Environment — a lightweight hybrid GUI/TUI
editor written in Zig that you turn into an IDE with Lua (languages, language
servers, settings, keys, extensions). See `Documentation.md` for everything
the editor does; this file is about building and installing it.

## Build

Needs Zig 0.16.0. One command builds both frontends:

```
git pull && zig build          # should just work
./zig-out/bin/zide-tui         # TUI smoke test in the terminal
./zig-out/bin/zide             # GUI smoke test
```

`zide` is the hybrid binary: typed in a terminal it opens the TUI there,
launched from the desktop it opens the GUI. `zide-tui` is TUI-only.
Add `-Doptimize=ReleaseSafe` for a release build.

## Opening a project

```
zide .                      # this folder is the project
zide ~/code/app             # that folder
zide . src/main.zig         # project plus a file
```

The folder becomes the file tree root and the workspace every language
server sees. Without a folder argument the project is wherever you launched
ZIDE from — starting it from `zig-out/bin` makes that the project, which is
rarely what you want.

## Install on Windows (manual)

There is no installer yet; installing is a build into a folder on your PATH
plus one shortcut.

1. Build straight into a personal bin folder (PowerShell):

   ```
   zig build -Doptimize=ReleaseSafe -p "$env:USERPROFILE\.local"
   ```

   That creates `%USERPROFILE%\.local\bin\zide.exe` and `zide-tui.exe`.
   Re-run the same command after a `git pull` to update.

2. Put that folder on your PATH once: Start menu → "Edit environment
   variables for your account" → `Path` → New → `%USERPROFILE%\.local\bin`.
   New terminals can then run `zide` (TUI) or `zide .` from anywhere.

3. For the Start menu / desktop: right-click `zide.exe` → Create shortcut,
   move it into `%APPDATA%\Microsoft\Windows\Start Menu\Programs`. Set the
   shortcut's "Start in" field to your project folder, or put the folder on
   the Target line (`zide.exe C:\code\app`). Launched this way it opens the GUI.

4. Uninstall = delete the folder, remove the PATH entry, delete the shortcut.
   Your settings live separately in `%USERPROFILE%\.config\zide`.

What a proper installer (Inno Setup script or a Scoop manifest) would add on
top, for later: an `App Paths` registry key so Start/Run find `zide` without
PATH, a `.zig` file association and "Open with ZIDE" on folders (ProgID keys
under `HKCU\Software\Classes` plus a Default Apps registration), and an entry
under `...\CurrentVersion\Uninstall` so it shows in Add or Remove Programs.

## Install on Linux

**Plain copy** (the same idea as Windows):

```
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/zide zig-out/bin/zide-tui ~/.local/bin/
cp packaging/zide.desktop ~/.local/share/applications/
mkdir -p ~/.local/share/icons/hicolor/scalable/apps
cp src/icons/zide-red.svg ~/.local/share/icons/hicolor/scalable/apps/zide.svg
```

`~/.local/bin` is on PATH on most distros once the folder exists (log out and
in again the first time). `zide` in a terminal opens the TUI; the app menu
entry opens the GUI.

**AppImage** (single file, no install):

1. Get `appimagetool` (a single-file download from the appimagetool GitHub
   releases), `chmod +x` it and drop it in `~/.local/bin`.
2. From the repo: `./packaging/make-appimage.sh`. It builds ReleaseSafe,
   assembles the AppDir with both binaries, the icon and the desktop entry,
   and writes `zig-out/ZIDE-x86_64.AppImage`.
3. Move the AppImage anywhere, `chmod +x` it, run it. For terminal use,
   symlink it: `ln -s /path/to/ZIDE-x86_64.AppImage ~/.local/bin/zide`.

SDL3, freetype and Lua are linked statically. SDL loads desktop libraries at
runtime; native Wayland presentation also requires working graphics-driver
libraries (for example EGL/OpenGL ES). X11 software rendering can run without
those graphics APIs.

## Configuration

The first GUI launch asks for Automatic, Hardware accelerated, or Software
rendering. Change this later in Settings; the new preference takes effect
after restarting ZIDE. Existing and newly opened windows keep the active
renderer until that restart. The choice is saved in `~/.config/zide/renderer.json`.

For a single launch, including recovery from a renderer that cannot start:

```sh
zide --gui --renderer=software .
```

`--renderer=auto` and `--renderer=hardware` are also available. The override
does not change the saved preference. The normal build supports all three
choices. The experimental `-Dgpu=true` build uses the SDL GPU API and requires
hardware acceleration. GUI renderer choices do not affect `zide-tui`.

Software draws the interface on the CPU. SDL's native Wayland backend still
needs a graphics driver (such as EGL/OpenGL ES) to present that software image.
For SDL's native software framebuffer path on Linux, use X11/XWayland:

```sh
SDL_VIDEO_DRIVER=x11 zide --gui --renderer=software .
```

This Wayland distinction was found during implementation testing; disabling
`SDL_FRAMEBUFFER_ACCELERATION` on native Wayland prevents SDL software startup.
ZIDE disables it on X11 and permits the required presentation path on Wayland.

`~/.config/zide/init.lua` (settings, keybindings, language servers) and
`~/.config/zide/extensions/*.lua` (languages, commands, hooks). ZIDE creates
commented example extensions there on first launch, including
`example-lsp-servers.lua` with ready-to-uncomment server registrations.
## Recovery and project formatting

ZIDE keeps recovery snapshots of dirty named and untitled buffers by default, independently of autosave and session persistence. On the next launch of the same workspace, choose Recover, Discard, or Later. `recover_documents` reopens that prompt. Recovery restores unsaved buffers for review; saving still checks external file changes. Snapshots live under `~/.config/zide/recovery/`, with locks separating active instances. Set `zide.set("recovery", false)` to disable new snapshots.

EditorConfig controls indentation, tab width, LF/CRLF output, trailing whitespace, and final newlines. Save-time changes are undoable and Save As uses the destination's rules. Encoding remains an explicit document choice; `charset`, lone-CR output, and spelling properties are unsupported. Set `zide.set("editorconfig", false)` to use language/global defaults. Both settings are also available in GUI Settings.
## Tasks, Problems and Git changes

Use the command palette to run `run_task`, `task_output`, `rerun_task`, `stop_task`,
`problems`, `next_problem`, or `previous_problem`. Tasks are explicit Lua registrations;
[examples/tasks.lua](examples/tasks.lua) contains commented Zig build/test examples and
a custom matcher. Registration never starts a process. Tasks offer to save dirty
workspace files, retain exit status and bounded output, and replace only their own
Problems entries. Problems filters by severity and source and opens closed files.
Task locations are marked possibly stale when the corresponding buffer changes.

`git_changes` opens the shared Changes panel. The two status columns describe the
index and working tree, following [Git's porcelain format](https://git-scm.com/docs/git-status).
Enter previews working tree changes; D previews staged changes; S stages saved
contents; U unstages; O opens a file; R refreshes. GUI buttons provide the same actions.
Dirty buffers require Save and stage or Cancel. Gutter marks compare the current
buffer, including unsaved edits, with the index. Previews compare saved files and are
read-only. Status, previews and index reads use background jobs; line comparisons run
on a worker. Large or complex gutter comparisons are bounded. Commits, network Git
operations, hunk staging and a merge editor are not included in this version.

## Debugging

Register an adapter and launch/attach configurations using
[examples/debug.lua](examples/debug.lua). `debug_start` chooses a configuration;
`debug` opens controls, threads, stack frames, expandable scopes/variables, breakpoint
verification and output. `toggle_breakpoint` toggles the cursor's source line.
Breakpoints persist per workspace under the configuration directory's `debug/` folder.
Continue, pause and step commands also work from the command palette in either frontend.

Stop terminates programs launched by ZIDE and detaches from attached programs.
`debug_terminate` explicitly requests termination of an attached target when the adapter
supports it. These rules follow the [DAP disconnect protocol](https://microsoft.github.io/debug-adapter-protocol/overview.html).
This version supports local source debugging of noninteractive programs and adapter
output. Terminal launch requests, watches, conditional/log breakpoints and concurrent
sessions remain deferred. Compile Zig executables in Debug mode before debugging.

The optional tool integration suite is `zig build test -Dtest-tools=true`. It requires
ZLS, Git and a working `lldb-dap` on PATH. Validate `lldb-dap --version` first; some
Windows LLVM packages require a matching Python runtime DLL. The validated LLVM
22.1.8 package required `python311.dll`. Normal builds and core unit tests do not need
an installed debug adapter. See [ImplementationProgress.md](ImplementationProgress.md)
for the environments and checks completed so far.

The remaining physical Linux display and renderer comparison checks are listed in
[tests/VALIDATION.md](tests/VALIDATION.md). Software rendering is an explicit option;
the faster choice on older or integrated graphics still needs measurement on the
target machine.
