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

Nothing else needs bundling: SDL3, freetype and Lua are linked statically,
and SDL loads X11/Wayland at runtime.

## Configuration

`~/.config/zide/init.lua` (settings, keybindings, language servers) and
`~/.config/zide/extensions/*.lua` (languages, commands, hooks). ZIDE creates
commented example extensions there on first launch, including
`example-lsp-servers.lua` with ready-to-uncomment server registrations.
