const std = @import("std");

/// Frontend-agnostic file-type classification for tree rows (and later
/// tabs). The GUI maps kinds to TinyVG glyphs; the TUI can map the same
/// kinds to nerdfont glyphs when custom icon integration lands. Kept as
/// plain tables so a future `zide.set_icons` Lua hook can override them.
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
const ext_map = std.StaticStringMap(FileIcon).initComptime(.{
    .{ "zig", FileIcon{ .kind = .code, .color = zig_orange } },
    .{ "zon", FileIcon{ .kind = .config, .color = zig_orange } },
    .{ "lua", FileIcon{ .kind = .code, .color = lua_blue } },
    .{ "c", FileIcon{ .kind = .code, .color = c_blue } },
    .{ "h", FileIcon{ .kind = .code, .color = c_blue } },
    .{ "cpp", FileIcon{ .kind = .code, .color = cpp_blue } },
    .{ "cc", FileIcon{ .kind = .code, .color = cpp_blue } },
    .{ "cxx", FileIcon{ .kind = .code, .color = cpp_blue } },
    .{ "hpp", FileIcon{ .kind = .code, .color = cpp_blue } },
    .{ "rs", FileIcon{ .kind = .code, .color = rust_tan } },
    .{ "go", FileIcon{ .kind = .code, .color = go_cyan } },
    .{ "js", FileIcon{ .kind = .code, .color = js_yellow } },
    .{ "mjs", FileIcon{ .kind = .code, .color = js_yellow } },
    .{ "cjs", FileIcon{ .kind = .code, .color = js_yellow } },
    .{ "ts", FileIcon{ .kind = .code, .color = ts_blue } },
    .{ "tsx", FileIcon{ .kind = .code, .color = ts_blue } },
    .{ "jsx", FileIcon{ .kind = .code, .color = js_yellow } },
    .{ "py", FileIcon{ .kind = .code, .color = py_blue } },
    .{ "java", FileIcon{ .kind = .code, .color = .{ .r = 0xB0, .g = 0x72, .b = 0x19 } } },
    .{ "cs", FileIcon{ .kind = .code, .color = .{ .r = 0x9A, .g = 0x5B, .b = 0xA5 } } },
    .{ "html", FileIcon{ .kind = .code, .color = web_orange } },
    .{ "htm", FileIcon{ .kind = .code, .color = web_orange } },
    .{ "css", FileIcon{ .kind = .code, .color = css_violet } },
    .{ "sh", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "bash", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "zsh", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "ps1", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "psm1", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "bat", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "cmd", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "exe", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "com", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "msi", FileIcon{ .kind = .executable, .color = exec_green } },
    .{ "md", FileIcon{ .kind = .text, .color = doc_blue } },
    .{ "markdown", FileIcon{ .kind = .text, .color = doc_blue } },
    .{ "rst", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "org", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "adoc", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "txt", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "log", FileIcon{ .kind = .text, .color = plain_gray } },
    .{ "pdf", FileIcon{ .kind = .book, .color = .{ .r = 0xD0, .g = 0x60, .b = 0x5E } } },
    .{ "json", FileIcon{ .kind = .config, .color = js_yellow } },
    .{ "jsonc", FileIcon{ .kind = .config, .color = js_yellow } },
    .{ "toml", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "yaml", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "yml", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "ini", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "cfg", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "conf", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "rc", FileIcon{ .kind = .config, .color = cfg_gray } },
    .{ "svg", FileIcon{ .kind = .image, .color = img_purple } },
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
    .{ "db", FileIcon{ .kind = .data, .color = data_amber } },
    .{ "sqlite", FileIcon{ .kind = .data, .color = data_amber } },
    .{ "sql", FileIcon{ .kind = .data, .color = data_amber } },
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
