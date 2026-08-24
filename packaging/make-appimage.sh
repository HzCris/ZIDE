#!/usr/bin/env bash
# Build a ZIDE AppImage — run ON LINUX from anywhere in the repo:
#   ./packaging/make-appimage.sh
#
# Needs: zig 0.16 and appimagetool on PATH
#   (appimagetool: https://github.com/AppImage/appimagetool/releases —
#    it's itself a single-file AppImage; chmod +x and drop in ~/.local/bin)
#
# The AppImage wraps the GUI binary and also carries the TUI binary at
# usr/bin/zide-tui. SDL3 / freetype / Lua / tree-sitter are statically
# linked, and SDL dlopens X11/Wayland/audio at runtime, so no shared
# libraries need bundling. For terminal use, symlink the AppImage into
# ~/.local/bin as `zide`.
set -euo pipefail
cd "$(dirname "$0")/.."

zig build -Doptimize=ReleaseSafe

APPDIR=zig-out/ZIDE.AppDir
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
cp zig-out/bin/zide "$APPDIR/usr/bin/zide"
cp zig-out/bin/zide-tui "$APPDIR/usr/bin/zide-tui"
cp packaging/zide.desktop "$APPDIR/zide.desktop"
cp src/icons/zide-red.svg "$APPDIR/zide.svg"
ln -s usr/bin/zide "$APPDIR/AppRun"

appimagetool "$APPDIR" "zig-out/ZIDE-$(uname -m).AppImage"
echo "Built zig-out/ZIDE-$(uname -m).AppImage"
