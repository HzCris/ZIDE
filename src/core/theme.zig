const std = @import("std");
const syntax = @import("syntax.zig");

// ---------------------------------------------------------------------------
// ThemeColor — frontend-agnostic RGBA color
// ---------------------------------------------------------------------------

pub const ThemeColor = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// Parse "#RRGGBB" or "#RRGGBBAA" hex string. Returns null on bad input.
    pub fn fromHex(hex: []const u8) ?ThemeColor {
        const s = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
        if (s.len == 6) {
            return .{
                .r = parseHexPair(s[0..2]) orelse return null,
                .g = parseHexPair(s[2..4]) orelse return null,
                .b = parseHexPair(s[4..6]) orelse return null,
                .a = 255,
            };
        } else if (s.len == 8) {
            return .{
                .r = parseHexPair(s[0..2]) orelse return null,
                .g = parseHexPair(s[2..4]) orelse return null,
                .b = parseHexPair(s[4..6]) orelse return null,
                .a = parseHexPair(s[6..8]) orelse return null,
            };
        }
        return null;
    }

    fn parseHexPair(pair: *const [2]u8) ?u8 {
        return std.fmt.parseInt(u8, pair, 16) catch null;
    }
};

// ---------------------------------------------------------------------------
// EditorTheme — GUI editor colors (ThemeColor values)
// ---------------------------------------------------------------------------

pub const EditorTheme = struct {
    // Editor area
    text: ThemeColor,
    selection: ThemeColor,
    cursor: ThemeColor,

    // Gutter
    gutter_bg: ThemeColor,
    gutter_text: ThemeColor,
    gutter_text_active: ThemeColor,
    gutter_separator: ThemeColor,

    // Decorations
    wrap_marker: ThemeColor,
    tilde: ThemeColor,

    // Overlay panels (find, palette, settings)
    overlay_bg: ThemeColor,
    overlay_fg: ThemeColor,
    overlay_dim: ThemeColor,
    overlay_warn: ThemeColor,
    overlay_selection: ThemeColor,
    overlay_hint: ThemeColor,

    // Indicators
    bool_true: ThemeColor,
    bool_false: ThemeColor,

    // File tree git status row colors
    git_added: ThemeColor,
    git_modified: ThemeColor,
    git_deleted: ThemeColor,
    git_untracked: ThemeColor,

    // Status bar
    status_bg: ThemeColor,
    status_fg: ThemeColor,
};

// ---------------------------------------------------------------------------
// TuiColor — ANSI index or RGB for TUI flexibility
// ---------------------------------------------------------------------------

pub const TuiColor = union(enum) {
    /// Terminal default color — inherits from terminal theme.
    default,
    /// ANSI color index (0-255). Respects terminal theme.
    ansi: u8,
    /// Direct RGB color.
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn fromThemeColor(tc: ThemeColor) TuiColor {
        return .{ .rgb = .{ .r = tc.r, .g = tc.g, .b = tc.b } };
    }
};

// ---------------------------------------------------------------------------
// TuiTheme — TUI editor colors
// ---------------------------------------------------------------------------

pub const TuiTheme = struct {
    // Editor area
    text_fg: TuiColor,
    text_bg: TuiColor,
    selection_fg: TuiColor,
    selection_bg: TuiColor,
    cursor_fg: TuiColor,
    cursor_bg: TuiColor,

    // Gutter
    gutter_text: TuiColor,
    gutter_text_active: TuiColor,
    gutter_separator: TuiColor,

    // Decorations
    tilde: TuiColor,
    wrap_marker: TuiColor,

    // Tab bar
    tab_bg: TuiColor,
    tab_fg: TuiColor,
    tab_active_bg: TuiColor,
    tab_active_fg: TuiColor,

    // File tree git status row colors
    git_added: TuiColor,
    git_modified: TuiColor,
    git_deleted: TuiColor,
    git_untracked: TuiColor,

    // Status bar
    status_bg: TuiColor,
    status_fg: TuiColor,

    // Overlays (find, palette, goto)
    overlay_bg: TuiColor,
    overlay_fg: TuiColor,
    overlay_accent: TuiColor,
    overlay_dim: TuiColor,
    overlay_selection_bg: TuiColor,
    overlay_selection_fg: TuiColor,
    overlay_warn: TuiColor,
    overlay_border: TuiColor,
};

// ---------------------------------------------------------------------------
// Built-in GUI theme presets
// ---------------------------------------------------------------------------

/// Dark theme — matches the current hardcoded GUI colors.
pub const gui_dark = EditorTheme{
    .text = .{ .r = 225, .g = 225, .b = 230 },
    .selection = .{ .r = 50, .g = 96, .b = 152, .a = 255 },
    .cursor = .{ .r = 147, .g = 221, .b = 250 },

    .gutter_bg = .{ .r = 40, .g = 40, .b = 60, .a = 60 },
    .gutter_text = .{ .r = 130, .g = 130, .b = 130, .a = 200 },
    .gutter_text_active = .{ .r = 225, .g = 225, .b = 230 },
    .gutter_separator = .{ .r = 80, .g = 80, .b = 80, .a = 100 },

    .wrap_marker = .{ .r = 100, .g = 100, .b = 100, .a = 150 },
    .tilde = .{ .r = 100, .g = 100, .b = 100, .a = 128 },

    .overlay_bg = .{ .r = 50, .g = 50, .b = 60, .a = 230 },
    .overlay_fg = .{ .r = 255, .g = 255, .b = 255 },
    .overlay_dim = .{ .r = 150, .g = 150, .b = 150, .a = 200 },
    .overlay_warn = .{ .r = 255, .g = 100, .b = 100 },
    .overlay_selection = .{ .r = 80, .g = 80, .b = 120, .a = 200 },
    .overlay_hint = .{ .r = 100, .g = 100, .b = 120, .a = 180 },

    .bool_true = .{ .r = 100, .g = 220, .b = 100 },
    .bool_false = .{ .r = 180, .g = 80, .b = 80 },

    .git_added = .{ .r = 115, .g = 191, .b = 105 },
    .git_modified = .{ .r = 229, .g = 192, .b = 123 },
    .git_deleted = .{ .r = 224, .g = 108, .b = 117 },
    .git_untracked = .{ .r = 105, .g = 200, .b = 175 },

    .status_bg = .{ .r = 30, .g = 30, .b = 30 },
    .status_fg = .{ .r = 225, .g = 225, .b = 230 },
};

/// Light theme.
pub const gui_light = EditorTheme{
    .text = .{ .r = 30, .g = 30, .b = 30 },
    .selection = .{ .r = 145, .g = 188, .b = 240 },
    .cursor = .{ .r = 0, .g = 100, .b = 200 },

    .gutter_bg = .{ .r = 235, .g = 235, .b = 235, .a = 60 },
    .gutter_text = .{ .r = 140, .g = 140, .b = 140, .a = 200 },
    .gutter_text_active = .{ .r = 30, .g = 30, .b = 30 },
    .gutter_separator = .{ .r = 180, .g = 180, .b = 180, .a = 100 },

    .wrap_marker = .{ .r = 180, .g = 180, .b = 180, .a = 150 },
    .tilde = .{ .r = 180, .g = 180, .b = 180, .a = 128 },

    .overlay_bg = .{ .r = 245, .g = 245, .b = 248, .a = 240 },
    .overlay_fg = .{ .r = 30, .g = 30, .b = 30 },
    .overlay_dim = .{ .r = 120, .g = 120, .b = 120, .a = 200 },
    .overlay_warn = .{ .r = 200, .g = 40, .b = 40 },
    .overlay_selection = .{ .r = 200, .g = 215, .b = 240, .a = 200 },
    .overlay_hint = .{ .r = 140, .g = 140, .b = 160, .a = 180 },

    .bool_true = .{ .r = 40, .g = 160, .b = 40 },
    .bool_false = .{ .r = 200, .g = 60, .b = 60 },

    .git_added = .{ .r = 30, .g = 130, .b = 30 },
    .git_modified = .{ .r = 154, .g = 103, .b = 0 },
    .git_deleted = .{ .r = 200, .g = 40, .b = 40 },
    .git_untracked = .{ .r = 0, .g = 130, .b = 130 },

    .status_bg = .{ .r = 230, .g = 230, .b = 230 },
    .status_fg = .{ .r = 30, .g = 30, .b = 30 },
};

/// High-contrast theme.
pub const gui_high_contrast = EditorTheme{
    .text = .{ .r = 255, .g = 255, .b = 255 },
    .selection = .{ .r = 0, .g = 90, .b = 200 },
    .cursor = .{ .r = 255, .g = 255, .b = 0 },

    .gutter_bg = .{ .r = 0, .g = 0, .b = 0, .a = 60 },
    .gutter_text = .{ .r = 160, .g = 160, .b = 160 },
    .gutter_text_active = .{ .r = 255, .g = 255, .b = 255 },
    .gutter_separator = .{ .r = 128, .g = 128, .b = 128 },

    .wrap_marker = .{ .r = 128, .g = 128, .b = 128 },
    .tilde = .{ .r = 128, .g = 128, .b = 128 },

    .overlay_bg = .{ .r = 0, .g = 0, .b = 0, .a = 245 },
    .overlay_fg = .{ .r = 255, .g = 255, .b = 255 },
    .overlay_dim = .{ .r = 180, .g = 180, .b = 180 },
    .overlay_warn = .{ .r = 255, .g = 80, .b = 80 },
    .overlay_selection = .{ .r = 0, .g = 70, .b = 160, .a = 220 },
    .overlay_hint = .{ .r = 180, .g = 180, .b = 200 },

    .bool_true = .{ .r = 0, .g = 255, .b = 0 },
    .bool_false = .{ .r = 255, .g = 0, .b = 0 },

    .git_added = .{ .r = 0, .g = 255, .b = 0 },
    .git_modified = .{ .r = 255, .g = 255, .b = 0 },
    .git_deleted = .{ .r = 255, .g = 80, .b = 80 },
    .git_untracked = .{ .r = 0, .g = 255, .b = 255 },

    .status_bg = .{ .r = 0, .g = 0, .b = 40 },
    .status_fg = .{ .r = 255, .g = 255, .b = 255 },
};

// ---------------------------------------------------------------------------
// Built-in TUI theme presets
// ---------------------------------------------------------------------------

/// Terminal theme — uses ANSI indices so colors follow the user's terminal theme.
pub const tui_terminal = TuiTheme{
    .text_fg = .default, // inherit terminal foreground
    .text_bg = .default, // inherit terminal background
    .selection_fg = .{ .ansi = 15 }, // bright white
    .selection_bg = .{ .ansi = 4 }, // blue
    .cursor_fg = .{ .ansi = 0 }, // black
    .cursor_bg = .{ .ansi = 15 }, // white (reverse video)

    .gutter_text = .{ .ansi = 8 }, // bright black (gray)
    .gutter_text_active = .{ .ansi = 15 }, // bright white
    .gutter_separator = .{ .ansi = 8 }, // bright black

    .tilde = .{ .ansi = 8 }, // bright black
    .wrap_marker = .{ .ansi = 8 }, // bright black

    .tab_bg = .{ .ansi = 8 }, // bright black
    .tab_fg = .{ .ansi = 15 }, // white
    .tab_active_bg = .{ .ansi = 4 }, // blue
    .tab_active_fg = .{ .ansi = 15 }, // bright white

    .git_added = .{ .ansi = 2 }, // green
    .git_modified = .{ .ansi = 3 }, // yellow
    .git_deleted = .{ .ansi = 1 }, // red
    .git_untracked = .{ .ansi = 6 }, // cyan

    .status_bg = .{ .ansi = 4 }, // blue
    .status_fg = .{ .ansi = 15 }, // bright white

    .overlay_bg = .{ .ansi = 0 }, // black
    .overlay_fg = .{ .ansi = 14 }, // bright cyan
    .overlay_accent = .{ .ansi = 14 }, // bright cyan
    .overlay_dim = .{ .ansi = 8 }, // gray
    .overlay_selection_bg = .{ .ansi = 12 }, // bright blue
    .overlay_selection_fg = .{ .ansi = 15 }, // bright white
    .overlay_warn = .{ .ansi = 9 }, // bright red
    .overlay_border = .{ .ansi = 6 }, // cyan
};

/// Dark TUI theme — ANSI-256 backgrounds (ConPTY compat), RGB foregrounds.
pub const tui_dark = TuiTheme{
    .text_fg = .{ .rgb = .{ .r = 225, .g = 225, .b = 230 } },
    .text_bg = .{ .ansi = 234 }, // #1c1c1c
    .selection_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
    .selection_bg = .{ .ansi = 24 }, // #005f87
    .cursor_fg = .{ .rgb = .{ .r = 30, .g = 30, .b = 30 } },
    .cursor_bg = .{ .rgb = .{ .r = 147, .g = 221, .b = 250 } },

    .gutter_text = .{ .rgb = .{ .r = 100, .g = 100, .b = 100 } },
    .gutter_text_active = .{ .rgb = .{ .r = 225, .g = 225, .b = 230 } },
    .gutter_separator = .{ .rgb = .{ .r = 80, .g = 80, .b = 80 } },

    .tilde = .{ .rgb = .{ .r = 80, .g = 80, .b = 80 } },
    .wrap_marker = .{ .rgb = .{ .r = 80, .g = 80, .b = 80 } },

    .tab_bg = .{ .ansi = 237 }, // #3a3a3a
    .tab_fg = .{ .rgb = .{ .r = 180, .g = 180, .b = 180 } },
    .tab_active_bg = .{ .ansi = 24 }, // #005f87
    .tab_active_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },

    .git_added = .{ .rgb = .{ .r = 115, .g = 191, .b = 105 } },
    .git_modified = .{ .rgb = .{ .r = 229, .g = 192, .b = 123 } },
    .git_deleted = .{ .rgb = .{ .r = 224, .g = 108, .b = 117 } },
    .git_untracked = .{ .rgb = .{ .r = 105, .g = 200, .b = 175 } },

    .status_bg = .{ .ansi = 24 }, // #005f87
    .status_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },

    .overlay_bg = .{ .ansi = 235 }, // #262626
    .overlay_fg = .{ .rgb = .{ .r = 225, .g = 225, .b = 230 } },
    .overlay_accent = .{ .rgb = .{ .r = 147, .g = 221, .b = 250 } },
    .overlay_dim = .{ .rgb = .{ .r = 120, .g = 120, .b = 120 } },
    .overlay_selection_bg = .{ .ansi = 60 }, // #5f5f87
    .overlay_selection_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
    .overlay_warn = .{ .rgb = .{ .r = 255, .g = 100, .b = 100 } },
    .overlay_border = .{ .rgb = .{ .r = 80, .g = 160, .b = 200 } },
};

/// Light TUI theme — all ANSI-256 for ConPTY compatibility.
pub const tui_light = TuiTheme{
    .text_fg = .{ .ansi = 16 }, // #000000 (black)
    .text_bg = .{ .ansi = 231 }, // #ffffff
    .selection_fg = .{ .ansi = 16 }, // #000000
    .selection_bg = .{ .ansi = 153 }, // #afd7ff
    .cursor_fg = .{ .ansi = 231 }, // #ffffff
    .cursor_bg = .{ .ansi = 33 }, // #0087ff

    .gutter_text = .{ .ansi = 244 }, // #808080
    .gutter_text_active = .{ .ansi = 16 }, // #000000
    .gutter_separator = .{ .ansi = 250 }, // #bcbcbc

    .tilde = .{ .ansi = 249 }, // #b2b2b2
    .wrap_marker = .{ .ansi = 249 }, // #b2b2b2

    .tab_bg = .{ .ansi = 253 }, // #dadada
    .tab_fg = .{ .ansi = 239 }, // #4e4e4e
    .tab_active_bg = .{ .ansi = 33 }, // #0087ff
    .tab_active_fg = .{ .ansi = 231 }, // #ffffff

    .git_added = .{ .ansi = 28 }, // #008700
    .git_modified = .{ .ansi = 130 }, // #af5f00
    .git_deleted = .{ .ansi = 160 }, // #d70000
    .git_untracked = .{ .ansi = 30 }, // #008787

    .status_bg = .{ .ansi = 33 }, // #0087ff
    .status_fg = .{ .ansi = 231 }, // #ffffff

    .overlay_bg = .{ .ansi = 255 }, // #eeeeee
    .overlay_fg = .{ .ansi = 16 }, // #000000
    .overlay_accent = .{ .ansi = 33 }, // #0087ff
    .overlay_dim = .{ .ansi = 244 }, // #808080
    .overlay_selection_bg = .{ .ansi = 189 }, // #d7d7ff
    .overlay_selection_fg = .{ .ansi = 16 }, // #000000
    .overlay_warn = .{ .ansi = 160 }, // #d70000
    .overlay_border = .{ .ansi = 33 }, // #0087ff
};

/// High-contrast TUI theme — ANSI-256 backgrounds (ConPTY compat), RGB foregrounds.
pub const tui_high_contrast = TuiTheme{
    .text_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
    .text_bg = .{ .ansi = 16 }, // #000000
    .selection_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
    .selection_bg = .{ .ansi = 25 }, // #005faf
    .cursor_fg = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
    .cursor_bg = .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } },

    .gutter_text = .{ .rgb = .{ .r = 160, .g = 160, .b = 160 } },
    .gutter_text_active = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
    .gutter_separator = .{ .rgb = .{ .r = 128, .g = 128, .b = 128 } },

    .tilde = .{ .rgb = .{ .r = 128, .g = 128, .b = 128 } },
    .wrap_marker = .{ .rgb = .{ .r = 128, .g = 128, .b = 128 } },

    .tab_bg = .{ .ansi = 236 }, // #303030
    .tab_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
    .tab_active_bg = .{ .ansi = 25 }, // #005faf
    .tab_active_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },

    .git_added = .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } },
    .git_modified = .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } },
    .git_deleted = .{ .rgb = .{ .r = 255, .g = 80, .b = 80 } },
    .git_untracked = .{ .rgb = .{ .r = 0, .g = 255, .b = 255 } },

    .status_bg = .{ .ansi = 17 }, // #00005f
    .status_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },

    .overlay_bg = .{ .ansi = 16 }, // #000000
    .overlay_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
    .overlay_accent = .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } },
    .overlay_dim = .{ .rgb = .{ .r = 180, .g = 180, .b = 180 } },
    .overlay_selection_bg = .{ .ansi = 25 }, // #005faf
    .overlay_selection_fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
    .overlay_warn = .{ .rgb = .{ .r = 255, .g = 80, .b = 80 } },
    .overlay_border = .{ .rgb = .{ .r = 255, .g = 255, .b = 0 } },
};

// ---------------------------------------------------------------------------
// Preset name lookup helpers
// ---------------------------------------------------------------------------

pub const ThemePreset = enum {
    dark,
    light,
    high_contrast,
};

pub fn guiPreset(preset: ThemePreset) EditorTheme {
    return switch (preset) {
        .dark => gui_dark,
        .light => gui_light,
        .high_contrast => gui_high_contrast,
    };
}

pub const TuiPreset = enum {
    terminal,
    dark,
    light,
    high_contrast,
};

pub fn tuiPreset(preset: TuiPreset) TuiTheme {
    return switch (preset) {
        .terminal => tui_terminal,
        .dark => tui_dark,
        .light => tui_light,
        .high_contrast => tui_high_contrast,
    };
}

// ---------------------------------------------------------------------------
// Runtime field-by-name setters (used by Lua integration)
// ---------------------------------------------------------------------------

/// Set an EditorTheme color field by name. Returns true if field was found.
pub fn setEditorColor(et: *EditorTheme, field_name: []const u8, color: ThemeColor) bool {
    inline for (std.meta.fields(EditorTheme)) |f| {
        if (std.mem.eql(u8, field_name, f.name)) {
            @field(et, f.name) = color;
            return true;
        }
    }
    return false;
}

/// Set a TuiTheme color field by name (always stores as RGB). Returns true if field was found.
pub fn setTuiColor(tt: *TuiTheme, field_name: []const u8, color: ThemeColor) bool {
    inline for (std.meta.fields(TuiTheme)) |f| {
        if (std.mem.eql(u8, field_name, f.name)) {
            @field(tt, f.name) = TuiColor.fromThemeColor(color);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// SyntaxTheme — GUI syntax highlight colors (separate from EditorTheme)
// ---------------------------------------------------------------------------

pub const SyntaxTheme = struct {
    keyword: ThemeColor,
    type_name: ThemeColor,
    string: ThemeColor,
    char_literal: ThemeColor,
    number: ThemeColor,
    comment: ThemeColor,
    function: ThemeColor,
    builtin: ThemeColor,
    constant: ThemeColor,
    operator: ThemeColor,
    punctuation: ThemeColor,
    preprocessor: ThemeColor,
    attribute: ThemeColor,
    todo: ThemeColor,
    heading: ThemeColor,
    strong: ThemeColor,
    emphasis: ThemeColor,
    link: ThemeColor,

    /// Returns the color for a token type, or null for plain text (use default).
    pub fn colorForToken(self: *const SyntaxTheme, token: syntax.TokenType) ?ThemeColor {
        return switch (token) {
            .text => null,
            .keyword => self.keyword,
            .type_name => self.type_name,
            .string => self.string,
            .char_literal => self.char_literal,
            .number => self.number,
            .comment => self.comment,
            .function => self.function,
            .builtin => self.builtin,
            .constant => self.constant,
            .operator => self.operator,
            .punctuation => self.punctuation,
            .preprocessor => self.preprocessor,
            .attribute => self.attribute,
            .todo => self.todo,
            .heading => self.heading,
            .strong => self.strong,
            .emphasis => self.emphasis,
            .link => self.link,
        };
    }
};

// ---------------------------------------------------------------------------
// TuiSyntaxTheme — TUI syntax highlight colors
// ---------------------------------------------------------------------------

pub const TuiSyntaxTheme = struct {
    keyword: TuiColor,
    type_name: TuiColor,
    string: TuiColor,
    char_literal: TuiColor,
    number: TuiColor,
    comment: TuiColor,
    function: TuiColor,
    builtin: TuiColor,
    constant: TuiColor,
    operator: TuiColor,
    punctuation: TuiColor,
    preprocessor: TuiColor,
    attribute: TuiColor,
    todo: TuiColor,
    heading: TuiColor,
    strong: TuiColor,
    emphasis: TuiColor,
    link: TuiColor,

    /// Returns the color for a token type, or null for plain text (use default).
    pub fn colorForToken(self: *const TuiSyntaxTheme, token: syntax.TokenType) ?TuiColor {
        return switch (token) {
            .text => null,
            .keyword => self.keyword,
            .type_name => self.type_name,
            .string => self.string,
            .char_literal => self.char_literal,
            .number => self.number,
            .comment => self.comment,
            .function => self.function,
            .builtin => self.builtin,
            .constant => self.constant,
            .operator => self.operator,
            .punctuation => self.punctuation,
            .preprocessor => self.preprocessor,
            .attribute => self.attribute,
            .todo => self.todo,
            .heading => self.heading,
            .strong => self.strong,
            .emphasis => self.emphasis,
            .link => self.link,
        };
    }
};

// ---------------------------------------------------------------------------
// Built-in syntax theme presets — GUI
// ---------------------------------------------------------------------------

/// Dark syntax theme (One Dark inspired).
pub const syn_gui_dark = SyntaxTheme{
    .keyword = .{ .r = 198, .g = 120, .b = 221 }, // #c678dd purple
    .type_name = .{ .r = 86, .g = 182, .b = 194 }, // #56b6c2 teal
    .string = .{ .r = 152, .g = 195, .b = 121 }, // #98c379 green
    .char_literal = .{ .r = 152, .g = 195, .b = 121 }, // #98c379 green
    .number = .{ .r = 209, .g = 154, .b = 102 }, // #d19a66 orange
    .comment = .{ .r = 92, .g = 99, .b = 112 }, // #5c6370 gray
    .function = .{ .r = 97, .g = 175, .b = 239 }, // #61afef blue
    .builtin = .{ .r = 229, .g = 192, .b = 123 }, // #e5c07b gold
    .constant = .{ .r = 209, .g = 154, .b = 102 }, // #d19a66 orange
    .operator = .{ .r = 225, .g = 225, .b = 230 }, // text color
    .punctuation = .{ .r = 171, .g = 178, .b = 191 }, // #abb2bf light gray
    .preprocessor = .{ .r = 190, .g = 132, .b = 210 }, // #be84d2 light purple
    .attribute = .{ .r = 229, .g = 192, .b = 123 }, // #e5c07b gold
    .todo = .{ .r = 229, .g = 192, .b = 123 }, // #e5c07b gold — pops against gray comments
    .heading = .{ .r = 224, .g = 108, .b = 117 }, // #e06c75 soft red
    .strong = .{ .r = 209, .g = 154, .b = 102 }, // #d19a66 orange
    .emphasis = .{ .r = 198, .g = 120, .b = 221 }, // #c678dd purple
    .link = .{ .r = 97, .g = 175, .b = 239 }, // #61afef blue
};

/// Light syntax theme (One Light inspired).
pub const syn_gui_light = SyntaxTheme{
    .keyword = .{ .r = 166, .g = 38, .b = 164 }, // #a626a4 purple
    .type_name = .{ .r = 1, .g = 132, .b = 188 }, // #0184bc teal
    .string = .{ .r = 80, .g = 161, .b = 79 }, // #50a14f green
    .char_literal = .{ .r = 80, .g = 161, .b = 79 }, // #50a14f green
    .number = .{ .r = 152, .g = 104, .b = 1 }, // #986801 dark orange
    .comment = .{ .r = 160, .g = 161, .b = 167 }, // #a0a1a7 gray
    .function = .{ .r = 64, .g = 120, .b = 242 }, // #4078f2 blue
    .builtin = .{ .r = 152, .g = 104, .b = 1 }, // #986801 dark orange
    .constant = .{ .r = 152, .g = 104, .b = 1 }, // #986801 dark orange
    .operator = .{ .r = 30, .g = 30, .b = 30 }, // text color
    .punctuation = .{ .r = 56, .g = 58, .b = 66 }, // #383a42 dark gray
    .preprocessor = .{ .r = 166, .g = 38, .b = 164 }, // #a626a4 purple
    .attribute = .{ .r = 152, .g = 104, .b = 1 }, // #986801 dark orange
    .todo = .{ .r = 193, .g = 132, .b = 1 }, // #c18401 amber — pops against gray comments
    .heading = .{ .r = 228, .g = 86, .b = 73 }, // #e45649 red
    .strong = .{ .r = 152, .g = 104, .b = 1 }, // #986801 dark orange
    .emphasis = .{ .r = 166, .g = 38, .b = 164 }, // #a626a4 purple
    .link = .{ .r = 64, .g = 120, .b = 242 }, // #4078f2 blue
};

/// High-contrast syntax theme.
pub const syn_gui_high_contrast = SyntaxTheme{
    .keyword = .{ .r = 255, .g = 100, .b = 255 }, // bright magenta
    .type_name = .{ .r = 100, .g = 255, .b = 255 }, // bright cyan
    .string = .{ .r = 100, .g = 255, .b = 100 }, // bright green
    .char_literal = .{ .r = 100, .g = 255, .b = 100 }, // bright green
    .number = .{ .r = 255, .g = 200, .b = 100 }, // bright orange
    .comment = .{ .r = 150, .g = 150, .b = 150 }, // gray
    .function = .{ .r = 100, .g = 180, .b = 255 }, // bright blue
    .builtin = .{ .r = 255, .g = 255, .b = 100 }, // bright yellow
    .constant = .{ .r = 255, .g = 200, .b = 100 }, // bright orange
    .operator = .{ .r = 255, .g = 255, .b = 255 }, // white
    .punctuation = .{ .r = 200, .g = 200, .b = 200 }, // light gray
    .preprocessor = .{ .r = 255, .g = 100, .b = 255 }, // bright magenta
    .attribute = .{ .r = 255, .g = 255, .b = 100 }, // bright yellow
    .todo = .{ .r = 255, .g = 255, .b = 100 }, // bright yellow
    .heading = .{ .r = 255, .g = 100, .b = 100 }, // bright red
    .strong = .{ .r = 255, .g = 200, .b = 100 }, // bright orange
    .emphasis = .{ .r = 255, .g = 100, .b = 255 }, // bright magenta
    .link = .{ .r = 100, .g = 180, .b = 255 }, // bright blue
};

// ---------------------------------------------------------------------------
// Built-in syntax theme presets — TUI
// ---------------------------------------------------------------------------

/// Terminal syntax theme — ANSI indices, respects terminal palette.
pub const syn_tui_terminal = TuiSyntaxTheme{
    .keyword = .{ .ansi = 5 }, // magenta
    .type_name = .{ .ansi = 6 }, // cyan
    .string = .{ .ansi = 2 }, // green
    .char_literal = .{ .ansi = 2 }, // green
    .number = .{ .ansi = 3 }, // yellow
    .comment = .{ .ansi = 8 }, // bright black
    .function = .{ .ansi = 4 }, // blue
    .builtin = .{ .ansi = 3 }, // yellow
    .constant = .{ .ansi = 3 }, // yellow
    .operator = .default,
    .punctuation = .default,
    .preprocessor = .{ .ansi = 5 }, // magenta
    .attribute = .{ .ansi = 3 }, // yellow
    .todo = .{ .ansi = 11 }, // bright yellow — pops against bright-black comments
    .heading = .{ .ansi = 1 }, // red
    .strong = .{ .ansi = 3 }, // yellow
    .emphasis = .{ .ansi = 5 }, // magenta
    .link = .{ .ansi = 4 }, // blue
};

/// Dark TUI syntax theme — RGB colors.
pub const syn_tui_dark = TuiSyntaxTheme{
    .keyword = .{ .rgb = .{ .r = 198, .g = 120, .b = 221 } },
    .type_name = .{ .rgb = .{ .r = 86, .g = 182, .b = 194 } },
    .string = .{ .rgb = .{ .r = 152, .g = 195, .b = 121 } },
    .char_literal = .{ .rgb = .{ .r = 152, .g = 195, .b = 121 } },
    .number = .{ .rgb = .{ .r = 209, .g = 154, .b = 102 } },
    .comment = .{ .rgb = .{ .r = 92, .g = 99, .b = 112 } },
    .function = .{ .rgb = .{ .r = 97, .g = 175, .b = 239 } },
    .builtin = .{ .rgb = .{ .r = 229, .g = 192, .b = 123 } },
    .constant = .{ .rgb = .{ .r = 209, .g = 154, .b = 102 } },
    .operator = .{ .rgb = .{ .r = 225, .g = 225, .b = 230 } },
    .punctuation = .{ .rgb = .{ .r = 171, .g = 178, .b = 191 } },
    .preprocessor = .{ .rgb = .{ .r = 190, .g = 132, .b = 210 } },
    .attribute = .{ .rgb = .{ .r = 229, .g = 192, .b = 123 } },
    .todo = .{ .rgb = .{ .r = 229, .g = 192, .b = 123 } },
    .heading = .{ .rgb = .{ .r = 224, .g = 108, .b = 117 } },
    .strong = .{ .rgb = .{ .r = 209, .g = 154, .b = 102 } },
    .emphasis = .{ .rgb = .{ .r = 198, .g = 120, .b = 221 } },
    .link = .{ .rgb = .{ .r = 97, .g = 175, .b = 239 } },
};

/// Light TUI syntax theme — ANSI-256 colors.
pub const syn_tui_light = TuiSyntaxTheme{
    .keyword = .{ .ansi = 128 }, // dark magenta
    .type_name = .{ .ansi = 30 }, // dark cyan
    .string = .{ .ansi = 28 }, // dark green
    .char_literal = .{ .ansi = 28 }, // dark green
    .number = .{ .ansi = 130 }, // dark orange
    .comment = .{ .ansi = 246 }, // gray
    .function = .{ .ansi = 33 }, // blue
    .builtin = .{ .ansi = 130 }, // dark orange
    .constant = .{ .ansi = 130 }, // dark orange
    .operator = .{ .ansi = 16 }, // black
    .punctuation = .{ .ansi = 238 }, // dark gray
    .preprocessor = .{ .ansi = 128 }, // dark magenta
    .attribute = .{ .ansi = 130 }, // dark orange
    .todo = .{ .ansi = 136 }, // dark goldenrod
    .heading = .{ .ansi = 124 }, // dark red
    .strong = .{ .ansi = 130 }, // dark orange
    .emphasis = .{ .ansi = 128 }, // dark magenta
    .link = .{ .ansi = 33 }, // blue
};

/// High-contrast TUI syntax theme — RGB colors.
pub const syn_tui_high_contrast = TuiSyntaxTheme{
    .keyword = .{ .rgb = .{ .r = 255, .g = 100, .b = 255 } },
    .type_name = .{ .rgb = .{ .r = 100, .g = 255, .b = 255 } },
    .string = .{ .rgb = .{ .r = 100, .g = 255, .b = 100 } },
    .char_literal = .{ .rgb = .{ .r = 100, .g = 255, .b = 100 } },
    .number = .{ .rgb = .{ .r = 255, .g = 200, .b = 100 } },
    .comment = .{ .rgb = .{ .r = 150, .g = 150, .b = 150 } },
    .function = .{ .rgb = .{ .r = 100, .g = 180, .b = 255 } },
    .builtin = .{ .rgb = .{ .r = 255, .g = 255, .b = 100 } },
    .constant = .{ .rgb = .{ .r = 255, .g = 200, .b = 100 } },
    .operator = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
    .punctuation = .{ .rgb = .{ .r = 200, .g = 200, .b = 200 } },
    .preprocessor = .{ .rgb = .{ .r = 255, .g = 100, .b = 255 } },
    .attribute = .{ .rgb = .{ .r = 255, .g = 255, .b = 100 } },
    .todo = .{ .rgb = .{ .r = 255, .g = 255, .b = 100 } },
    .heading = .{ .rgb = .{ .r = 255, .g = 100, .b = 100 } },
    .strong = .{ .rgb = .{ .r = 255, .g = 200, .b = 100 } },
    .emphasis = .{ .rgb = .{ .r = 255, .g = 100, .b = 255 } },
    .link = .{ .rgb = .{ .r = 100, .g = 180, .b = 255 } },
};

// ---------------------------------------------------------------------------
// Syntax theme preset lookups
// ---------------------------------------------------------------------------

pub fn synGuiPreset(preset: ThemePreset) SyntaxTheme {
    return switch (preset) {
        .dark => syn_gui_dark,
        .light => syn_gui_light,
        .high_contrast => syn_gui_high_contrast,
    };
}

pub fn synTuiPreset(preset: TuiPreset) TuiSyntaxTheme {
    return switch (preset) {
        .terminal => syn_tui_terminal,
        .dark => syn_tui_dark,
        .light => syn_tui_light,
        .high_contrast => syn_tui_high_contrast,
    };
}

// ---------------------------------------------------------------------------
// Runtime field-by-name setters for syntax themes
// ---------------------------------------------------------------------------

/// Set a SyntaxTheme color field by name. Returns true if field was found.
pub fn setSyntaxColor(st: *SyntaxTheme, field_name: []const u8, color: ThemeColor) bool {
    inline for (std.meta.fields(SyntaxTheme)) |f| {
        if (std.mem.eql(u8, field_name, f.name)) {
            @field(st, f.name) = color;
            return true;
        }
    }
    return false;
}

/// Set a TuiSyntaxTheme color field by name (stores as RGB). Returns true if field was found.
pub fn setTuiSyntaxColor(st: *TuiSyntaxTheme, field_name: []const u8, color: ThemeColor) bool {
    inline for (std.meta.fields(TuiSyntaxTheme)) |f| {
        if (std.mem.eql(u8, field_name, f.name)) {
            @field(st, f.name) = TuiColor.fromThemeColor(color);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ThemeColor fromHex" {
    const c1 = ThemeColor.fromHex("#ff8040").?;
    try std.testing.expectEqual(@as(u8, 0xff), c1.r);
    try std.testing.expectEqual(@as(u8, 0x80), c1.g);
    try std.testing.expectEqual(@as(u8, 0x40), c1.b);
    try std.testing.expectEqual(@as(u8, 255), c1.a);

    const c2 = ThemeColor.fromHex("#aabbcc80").?;
    try std.testing.expectEqual(@as(u8, 0xaa), c2.r);
    try std.testing.expectEqual(@as(u8, 0xbb), c2.g);
    try std.testing.expectEqual(@as(u8, 0xcc), c2.b);
    try std.testing.expectEqual(@as(u8, 0x80), c2.a);

    // No # prefix
    const c3 = ThemeColor.fromHex("102030").?;
    try std.testing.expectEqual(@as(u8, 0x10), c3.r);

    // Bad input
    try std.testing.expect(ThemeColor.fromHex("nope") == null);
    try std.testing.expect(ThemeColor.fromHex("#12") == null);
}

test "gui presets exist" {
    const dark = guiPreset(.dark);
    try std.testing.expectEqual(@as(u8, 225), dark.text.r);
    const light = guiPreset(.light);
    try std.testing.expectEqual(@as(u8, 30), light.text.r);
    const hc = guiPreset(.high_contrast);
    try std.testing.expectEqual(@as(u8, 255), hc.text.r);
}

test "tui presets exist" {
    const term = tuiPreset(.terminal);
    try std.testing.expect(term.text_fg == .default);
    const dark = tuiPreset(.dark);
    try std.testing.expectEqual(@as(u8, 225), dark.text_fg.rgb.r);
    const light = tuiPreset(.light);
    try std.testing.expectEqual(@as(u8, 16), light.text_fg.ansi);
}

test "syntax theme colorForToken" {
    const st = syn_gui_dark;
    // keyword should return purple
    const kw = st.colorForToken(.keyword).?;
    try std.testing.expectEqual(@as(u8, 198), kw.r);
    // text should return null
    try std.testing.expect(st.colorForToken(.text) == null);
}

test "syntax theme preset lookups" {
    const dark = synGuiPreset(.dark);
    try std.testing.expectEqual(@as(u8, 198), dark.keyword.r);
    const light = synGuiPreset(.light);
    try std.testing.expectEqual(@as(u8, 166), light.keyword.r);
    const term = synTuiPreset(.terminal);
    try std.testing.expectEqual(@as(u8, 5), term.keyword.ansi);
}
