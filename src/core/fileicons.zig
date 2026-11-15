//! File-type classification for the file tree's rows: which kind of icon a
//! name gets, by extension or by exact name. The GUI turns a kind into a
//! vector icon and the TUI into a Nerd Font glyph; overrides from Lua's
//! `zide.set_icon` are applied by the editor.
const std = @import("std");

/// The kinds of icon a tree row can have. The GUI draws a kind as a vector
/// icon, the TUI as a Nerd Font glyph (with `tui_filetree_icons` on).
pub const IconKind = enum {
    folder,
    code,
    text,
    book,
    license,
    config,
    data,
    image,
    audio,
    video,
    archive,
    binary,
    executable,
    git,
    lock,
    font_file,
    generic,
};

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const FileIcon = struct {
    kind: IconKind,
    /// Fixed accent color chosen to read on both dark and light themes;
    /// null means "use the theme's text color".
    color: ?Rgb,
    /// Per-language nerdfont logo (TUI) — the Zig zero, Rust gear, Lua
    /// moon, ... Codepoints come from nvim-web-devicons (the de-facto
    /// standard mapping). Null = fall back to the kind's category glyph.
    nerd: ?[]const u8 = null,
};

// Accent palette (brand-ish, mid-lightness so both theme families work).
const zig_orange: Rgb = .{ .r = 0xF7, .g = 0xA4, .b = 0x1D };
const lua_blue: Rgb = .{ .r = 0x4F, .g = 0x9F, .b = 0xCF };
const c_blue: Rgb = .{ .r = 0x51, .g = 0x9A, .b = 0xBA };
const cpp_blue: Rgb = .{ .r = 0x62, .g = 0x95, .b = 0xCB };
const rust_tan: Rgb = .{ .r = 0xC9, .g = 0x8A, .b = 0x6B };
const go_cyan: Rgb = .{ .r = 0x35, .g = 0xB5, .b = 0xD6 };
const js_yellow: Rgb = .{ .r = 0xD4, .g = 0xC6, .b = 0x4A };
const ts_blue: Rgb = .{ .r = 0x4A, .g = 0x9C, .b = 0xD6 };
const py_blue: Rgb = .{ .r = 0x4B, .g = 0x8B, .b = 0xBE };
const web_orange: Rgb = .{ .r = 0xE4, .g = 0x70, .b = 0x3A };
const css_violet: Rgb = .{ .r = 0x7C, .g = 0x6B, .b = 0xB0 };
const doc_blue: Rgb = .{ .r = 0x4F, .g = 0xA6, .b = 0xE8 };
const plain_gray: Rgb = .{ .r = 0x9A, .g = 0xA5, .b = 0xB1 };
const cfg_gray: Rgb = .{ .r = 0xA5, .g = 0xAE, .b = 0xB8 };
const img_purple: Rgb = .{ .r = 0xA0, .g = 0x74, .b = 0xC4 };
const audio_pink: Rgb = .{ .r = 0xD6, .g = 0x6A, .b = 0x9C };
const video_orange: Rgb = .{ .r = 0xE8, .g = 0x83, .b = 0x4A };
const archive_tan: Rgb = .{ .r = 0xB8, .g = 0xA2, .b = 0x54 };
const bin_slate: Rgb = .{ .r = 0x8A, .g = 0x94, .b = 0xA6 };
const exec_green: Rgb = .{ .r = 0x6F, .g = 0xBF, .b = 0x50 };
const data_amber: Rgb = .{ .r = 0xC4, .g = 0xA1, .b = 0x5A };
const git_red: Rgb = .{ .r = 0xF0, .g = 0x55, .b = 0x3D };
const lock_gold: Rgb = .{ .r = 0xC9, .g = 0xB4, .b = 0x58 };
const folder_blue: Rgb = .{ .r = 0x7F, .g = 0xA0, .b = 0xC4 };

/// Extension (lowercased, no dot) -> icon. Kept sorted-ish by family.
/// `.nerd` glyphs are the per-language logos (nvim-web-devicons
/// codepoints); entries without one use the kind's category glyph.
const ext_map = std.StaticStringMap(FileIcon).initComptime(.{
    .{ "zig", FileIcon{ .kind = .code, .color = zig_orange, .nerd = "\u{e6a9}" } },
    .{ "zon", FileIcon{ .kind = .config, .color = zig_orange, .nerd = "\u{e6a9}" } },
    .{ "lua", FileIcon{ .kind = .code, .color = lua_blue, .nerd = "\u{e620}" } },
    .{ "c", FileIcon{ .kind = .code, .color = c_blue, .nerd = "\u{e61e}" } },
    .{ "h", FileIcon{ .kind = .code, .color = c_blue, .nerd = "\u{f0fd}" } },
    .{ "cpp", FileIcon{ .kind = .code, .color = cpp_blue, .nerd = "\u{e61d}" } },
    .{ "cc", FileIcon{ .kind = .code, .color = cpp_blue, .nerd = "\u{e61d}" } },
    .{ "cxx", FileIcon{ .kind = .code, .color = cpp_blue, .nerd = "\u{e61d}" } },
    .{ "hpp", FileIcon{ .kind = .code, .color = cpp_blue, .nerd = "\u{f0fd}" } },
    .{ "rs", FileIcon{ .kind = .code, .color = rust_tan, .nerd = "\u{e68b}" } },
    .{ "go", FileIcon{ .kind = .code, .color = go_cyan, .nerd = "\u{e627}" } },
    .{ "js", FileIcon{ .kind = .code, .color = js_yellow, .nerd = "\u{e60c}" } },
    .{ "mjs", FileIcon{ .kind = .code, .color = js_yellow, .nerd = "\u{e60c}" } },
    .{ "cjs", FileIcon{ .kind = .code, .color = js_yellow, .nerd = "\u{e60c}" } },
    .{ "ts", FileIcon{ .kind = .code, .color = ts_blue, .nerd = "\u{e628}" } },
    .{ "tsx", FileIcon{ .kind = .code, .color = ts_blue, .nerd = "\u{e7ba}" } },
    .{ "jsx", FileIcon{ .kind = .code, .color = js_yellow, .nerd = "\u{e625}" } },
    .{ "py", FileIcon{ .kind = .code, .color = py_blue, .nerd = "\u{e606}" } },
    .{ "java", FileIcon{ .kind = .code, .color = .{ .r = 0xB0, .g = 0x72, .b = 0x19 }, .nerd = "\u{e738}" } },
    .{ "cs", FileIcon{ .kind = .code, .color = .{ .r = 0x9A, .g = 0x5B, .b = 0xA5 }, .nerd = "\u{f031b}" } },
    .{ "html", FileIcon{ .kind = .code, .color = web_orange, .nerd = "\u{e736}" } },
    .{ "htm", FileIcon{ .kind = .code, .color = web_orange, .nerd = "\u{e736}" } },
    .{ "css", FileIcon{ .kind = .code, .color = css_violet, .nerd = "\u{e6b8}" } },
    .{ "sh", FileIcon{ .kind = .executable, .color = exec_green, .nerd = "\u{e795}" } },
    .{ "bash", FileIcon{ .kind = .executable, .color = exec_green, .nerd = "\u{e760}" } },
    .{ "zsh", FileIcon{ .kind = .executable, .color = exec_green, .nerd = "\u{e795}" } },
    .{ "ps1", FileIcon{ .kind = .executable, .color = exec_green, .nerd = "\u{f0a0a}" } },
    .{ "psm1", FileIcon{ .kind = .executable, .color = exec_green, .nerd = "\u{f0a0a}" } },
    .{ "bat", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "cmd", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "exe", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "com", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "msi", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "md", FileIcon{ .kind = .text, .color = doc_blue, .nerd = "\u{f48a}" } },
    .{ "markdown", FileIcon{ .kind = .text, .color = doc_blue, .nerd = "\u{f48a}" } },
    .{ "rst", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "org", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "adoc", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "txt", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "log", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "pdf", FileIcon{ .kind = .book, .color = .{ .r = 0xD0, .g = 0x60, .b = 0x5E }, .nerd = "\u{eaeb}" } },
    .{ "json", FileIcon{ .kind = .config, .color = js_yellow, .nerd = "\u{e60b}" } },
    .{ "jsonc", FileIcon{ .kind = .config, .color = js_yellow, .nerd = "\u{e60b}" } },
    .{ "toml", FileIcon{ .kind = .config, .color = cfg_gray, .nerd = "\u{e6b2}" } },
    .{ "yaml", FileIcon{ .kind = .config, .color = cfg_gray, .nerd = "\u{e8eb}" } },
    .{ "yml", FileIcon{ .kind = .config, .color = cfg_gray, .nerd = "\u{e8eb}" } },
    .{ "ini", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "cfg", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "conf", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "rc", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "svg", FileIcon{ .kind = .image, .color = img_purple, .nerd = "\u{f0721}" } },
    .{ "png", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "jpg", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "jpeg", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "gif", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "bmp", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "webp", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "ico", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "tga", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "qoi", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "tif", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "tiff", FileIcon{ .kind = .image, .color = img_purple } },
    .{ "mp3", FileIcon{ .kind = .audio, .color = audio_pink } },
    .{ "wav", FileIcon{ .kind = .audio, .color = audio_pink } },
    .{ "ogg", FileIcon{ .kind = .audio, .color = audio_pink } },
    .{ "flac", FileIcon{ .kind = .audio, .color = audio_pink } },
    .{ "m4a", FileIcon{ .kind = .audio, .color = audio_pink } },
    .{ "mp4", FileIcon{ .kind = .video, .color = video_orange } },
    .{ "mkv", FileIcon{ .kind = .video, .color = video_orange } },
    .{ "avi", FileIcon{ .kind = .video, .color = video_orange } },
    .{ "webm", FileIcon{ .kind = .video, .color = video_orange } },
    .{ "mov", FileIcon{ .kind = .video, .color = video_orange } },
    .{ "zip", FileIcon{ .kind = .archive, .color = archive_tan } },
    .{ "tar", FileIcon{ .kind = .archive, .color = archive_tan } },
    .{ "gz", FileIcon{ .kind = .archive, .color = archive_tan } },
    .{ "xz", FileIcon{ .kind = .archive, .color = archive_tan } },
    .{ "zst", FileIcon{ .kind = .archive, .color = archive_tan } },
    .{ "7z", FileIcon{ .kind = .archive, .color = archive_tan } },
    .{ "rar", FileIcon{ .kind = .archive, .color = archive_tan } },
    .{ "bz2", FileIcon{ .kind = .archive, .color = archive_tan } },
    .{ "dll", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "so", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "dylib", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "a", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "lib", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "o", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "obj", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "pdb", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "bin", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "dat", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "wasm", FileIcon{ .kind = .binary, .color = bin_slate } },
    .{ "db", FileIcon{ .kind = .data, .color = data_amber, .nerd = "\u{e706}" } },
    .{ "sqlite", FileIcon{ .kind = .data, .color = data_amber, .nerd = "\u{e706}" } },
    .{ "sql", FileIcon{ .kind = .data, .color = data_amber, .nerd = "\u{e706}" } },
    .{ "lock", FileIcon{ .kind = .lock, .color = lock_gold } },
    .{ "ttf", FileIcon{ .kind = .font_file, .color = plain_gray } },
    .{ "otf", FileIcon{ .kind = .font_file, .color = plain_gray } },
    .{ "woff", FileIcon{ .kind = .font_file, .color = plain_gray } },
    .{ "woff2", FileIcon{ .kind = .font_file, .color = plain_gray } },
});

/// Special basenames (matched case-insensitively) that beat the extension.
const name_map = std.StaticStringMap(FileIcon).initComptime(.{
    .{ ".gitignore", FileIcon{ .kind = .git, .color = git_red } },
    .{ ".gitattributes", FileIcon{ .kind = .git, .color = git_red } },
    .{ ".gitmodules", FileIcon{ .kind = .git, .color = git_red } },
    .{ "makefile", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "justfile", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "dockerfile", FileIcon{ .kind = .config, .color = cfg_gray } },
});

const generic_icon: FileIcon = .{ .kind = .generic, .color = null };

/// Extension after the last '.', empty for none. A leading dot alone
/// (".gitignore") is a hidden-file marker, not an extension.
fn extOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    return name[dot + 1 ..];
}

/// Classify a directory entry by basename. `is_dir` wins over any name
/// pattern — directories always get the folder icon.
pub fn iconFor(name: []const u8, is_dir: bool) FileIcon {
    if (is_dir) return .{ .kind = .folder, .color = folder_blue };

    var lower_buf: [32]u8 = undefined;
    if (lowerInto(&lower_buf, name)) |lower| {
        if (name_map.get(lower)) |fi| return fi;
        if (std.mem.startsWith(u8, lower, "readme")) return .{ .kind = .book, .color = doc_blue };
        if (std.mem.startsWith(u8, lower, "license") or std.mem.eql(u8, lower, "copying")) {
            return .{ .kind = .license, .color = lock_gold };
        }
    }

    const ext = extOf(name);
    if (lowerInto(&lower_buf, ext)) |lower_ext| {
        if (ext_map.get(lower_ext)) |fi| return fi;
    }

    // Remaining dotfiles (.env, .clang-format, ...) read as configuration.
    if (name.len > 1 and name[0] == '.') return .{ .kind = .config, .color = cfg_gray };
    return generic_icon;
}

/// Lowercase `s` into `buf`, or null when it doesn't fit (long names
/// can't match any table entry anyway).
fn lowerInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..s.len];
}

// ---- Runtime overrides (zide.set_icon) ----

pub const Override = struct { kind: IconKind, color: ?Rgb };

/// Keys are owned lowercase strings: an exact basename ("makefile",
/// "src") or an extension ("zig"). The editor owns one of these; both
/// frontends consult it through iconForWithOverrides.
pub const OverrideMap = std.StringHashMapUnmanaged(Override);

/// `iconFor` with the Lua override layer on top: exact basename match
/// first (works for directories too), then extension, then built-ins.
pub fn iconForWithOverrides(map: *const OverrideMap, name: []const u8, is_dir: bool) FileIcon {
    if (map.count() > 0) {
        var buf: [64]u8 = undefined;
        if (lowerInto(&buf, name)) |lname| {
            if (map.get(lname)) |ov| return .{ .kind = ov.kind, .color = ov.color };
        }
        if (!is_dir) {
            const ext = extOf(name);
            if (ext.len > 0) {
                if (lowerInto(&buf, ext)) |lext| {
                    if (map.get(lext)) |ov| return .{ .kind = ov.kind, .color = ov.color };
                }
            }
        }
    }
    return iconFor(name, is_dir);
}

/// Parse a kind name ("code", "image", ...) — the Lua-facing spelling
/// is exactly the enum tag.
pub fn kindFromName(s: []const u8) ?IconKind {
    return std.meta.stringToEnum(IconKind, s);
}

/// Nerdfont glyph per kind for the TUI (requires a Nerd Font terminal
/// font — gated behind the tui_filetree_icons setting).
pub fn nerdGlyph(kind: IconKind) []const u8 {
    return switch (kind) {
        .folder => "\u{f07b}",
        .code => "\u{f121}",
        .text => "\u{f15c}",
        .book => "\u{f02d}",
        .license => "\u{f132}",
        .config => "\u{f013}",
        .data => "\u{f1c0}",
        .image => "\u{f1c5}",
        .audio => "\u{f001}",
        .video => "\u{f008}",
        .archive => "\u{f1c6}",
        .binary => "\u{f471}",
        .executable => "\u{f0e7}",
        .git => "\u{f1d3}",
        .lock => "\u{f023}",
        .font_file => "\u{f031}",
        .generic => "\u{f15b}",
    };
}

// ---- Tests ----

const t = std.testing;

test "fileicons: directories are folders regardless of name" {
    try t.expectEqual(IconKind.folder, iconFor("src", true).kind);
    try t.expectEqual(IconKind.folder, iconFor("README.md", true).kind);
}

test "fileicons: extension mapping with case-insensitivity" {
    const zig_fi = iconFor("main.zig", false);
    try t.expectEqual(IconKind.code, zig_fi.kind);
    try t.expectEqual(zig_orange.r, zig_fi.color.?.r);
    try t.expectEqual(IconKind.image, iconFor("photo.PNG", false).kind);
    try t.expectEqual(IconKind.binary, iconFor("zide.pdb", false).kind);
    try t.expectEqual(IconKind.executable, iconFor("zide.exe", false).kind);
}

test "fileicons: special names beat extensions" {
    try t.expectEqual(IconKind.book, iconFor("README.md", false).kind);
    try t.expectEqual(IconKind.book, iconFor("readme", false).kind);
    try t.expectEqual(IconKind.license, iconFor("LICENSE", false).kind);
    try t.expectEqual(IconKind.git, iconFor(".gitignore", false).kind);
}

test "fileicons: dotfile fallback and generic default" {
    try t.expectEqual(IconKind.config, iconFor(".env", false).kind);
    try t.expectEqual(IconKind.generic, iconFor("mystery.xyz", false).kind);
    try t.expectEqual(@as(?Rgb, null), iconFor("mystery.xyz", false).color);
    try t.expectEqual(IconKind.generic, iconFor("noext", false).kind);
}

test "fileicons: extOf edge cases" {
    try t.expectEqualStrings("gz", extOf("file.tar.gz"));
    try t.expectEqualStrings("", extOf(".gitignore"));
    try t.expectEqualStrings("", extOf("noext"));
}

test "fileicons: per-language nerd logos with category fallback" {
    // The Zig logo, not the generic </>
    try t.expectEqualStrings("\u{e6a9}", iconFor("main.zig", false).nerd.?);
    try t.expectEqualStrings("\u{e620}", iconFor("init.lua", false).nerd.?);
    // No logo entry -> null -> caller falls back to nerdGlyph(kind)
    try t.expectEqual(@as(?[]const u8, null), iconFor("photo.png", false).nerd);
    try t.expectEqual(@as(?[]const u8, null), iconFor("src", true).nerd);
    // Overrides come back logo-less (they pick a category kind)
    var map: OverrideMap = .empty;
    defer map.deinit(t.allocator);
    try map.put(t.allocator, "zig", .{ .kind = .image, .color = null });
    try t.expectEqual(@as(?[]const u8, null), iconForWithOverrides(&map, "main.zig", false).nerd);
}

test "fileicons: kindFromName parses enum tags" {
    try t.expectEqual(IconKind.code, kindFromName("code").?);
    try t.expectEqual(IconKind.font_file, kindFromName("font_file").?);
    try t.expectEqual(@as(?IconKind, null), kindFromName("no_such_kind"));
}

test "fileicons: overrides beat built-ins, basename beats extension" {
    var map: OverrideMap = .empty;
    defer map.deinit(t.allocator);
    const red: Rgb = .{ .r = 0xFF, .g = 0, .b = 0 };
    try map.put(t.allocator, "zig", .{ .kind = .image, .color = red });
    try map.put(t.allocator, "build.zig", .{ .kind = .lock, .color = null });
    try map.put(t.allocator, "src", .{ .kind = .git, .color = null });

    // Extension override (case-insensitive input)
    try t.expectEqual(IconKind.image, iconForWithOverrides(&map, "MAIN.ZIG", false).kind);
    try t.expectEqual(@as(u8, 0xFF), iconForWithOverrides(&map, "main.zig", false).color.?.r);
    // Exact basename beats the extension entry
    try t.expectEqual(IconKind.lock, iconForWithOverrides(&map, "build.zig", false).kind);
    // Directory overrides by name
    try t.expectEqual(IconKind.git, iconForWithOverrides(&map, "src", true).kind);
    // Unmatched falls through to built-ins
    try t.expectEqual(IconKind.text, iconForWithOverrides(&map, "notes.md", false).kind);
}
