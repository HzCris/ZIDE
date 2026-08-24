# ZIDE

Zimplified Integrated Development Environment

Your laptop workflow

git pull && zig build          # should just work now
./zig-out/bin/zide-tui         # TUI smoke test in the terminal
./zig-out/bin/zide             # GUI smoke test

For install: copy into ~/.local/bin (that's the PATH answer — same idea as Windows, plus a .desktop file for the app menu). And for the AppImage, it's now one command — I added packaging/make-appimage.sh and packaging/zide.desktop to the repo: it builds ReleaseSafe, assembles the AppDir (GUI binary + TUI binary + your red SVG icon + desktop entry), and runs appimagetool (single-file download, drop in ~/.local/bin). No library bundling needed — SDL dlopens X11/Wayland at runtime.

Two small notes: run git update-index --chmod=+x packaging/make-appimage.sh when committing so the script is executable on Linux, and when you get to hybrid launch there, terminal-vs-desktop detection is just isatty — far simpler than the Windows plan.
