#!/usr/bin/env bash
# Run from any directory. Set ZIG to select a Zig 0.16.0 executable.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
zig_bin=${ZIG:-zig}
if ! command -v "$zig_bin" >/dev/null 2>&1; then
    printf 'Zig not found. Set ZIG to the Zig 0.16.0 executable.\n' >&2
    exit 1
fi
# Resolve before changing directory, so a relative ZIG path remains valid.
zig_bin=$(realpath -- "$(command -v "$zig_bin")")
if [[ $("$zig_bin" version) != 0.16.0 ]]; then
    printf 'Validation requires Zig 0.16.0. Set ZIG to its executable.\n' >&2
    exit 1
fi

gui_prefix=(env SDL_VIDEO_DRIVER=x11)
if [[ -z ${DISPLAY:-} ]]; then
    if ! command -v xvfb-run >/dev/null 2>&1; then
        printf 'GUI checks need an X11 display or xvfb-run (with Xvfb and xauth).\n' >&2
        exit 1
    fi
    gui_prefix=(xvfb-run -a env SDL_VIDEO_DRIVER=x11)
fi

cd -- "$repo_root"
log_root="$repo_root/zig-out/validation/linux"
mkdir -p -- "$log_root"
run_check() {
    local name=$1
    shift
    printf 'Running %s\n' "$name"
    "$@" 2>&1 | tee "$log_root/$name.log"
}

for mode in Debug ReleaseSafe; do
    run_check "$mode-build" "$zig_bin" build -Dfrontend=both "-Doptimize=$mode" --summary all
    run_check "$mode-core" "$zig_bin" build test "-Doptimize=$mode" --summary all
    run_check "$mode-gui" "${gui_prefix[@]}" "$zig_bin" build test-gui "-Doptimize=$mode" --summary all
done
printf 'Validation passed. Logs: %s\n' "$log_root"
