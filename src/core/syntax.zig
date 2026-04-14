const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Token types and spans
// ---------------------------------------------------------------------------

pub const TokenType = enum {
    text,
    keyword,
    type_name,
    string,
    char_literal,
    number,
    comment,
    operator,
    punctuation,
    builtin,
    attribute,
    function,
    constant,
    preprocessor,
};

pub const HighlightSpan = struct {
    start: u16,
    end: u16,
    token: TokenType,
};

pub const LineState = enum(u8) {
    normal = 0,
    in_block_comment = 1,
    in_string = 2,
};

// ---------------------------------------------------------------------------
// Language definition
// ---------------------------------------------------------------------------

pub const LanguageDef = struct {
    name: []const u8,
    extensions: []const []const u8,
    keywords: []const []const u8,
    types: []const []const u8,
    constants: []const []const u8,
    builtins: []const []const u8,
    line_comment: ?[]const u8,
    block_comment_start: ?[]const u8,
    block_comment_end: ?[]const u8,
    string_delimiters: []const u8,
    has_char_literals: bool,
    builtin_prefix: ?u8,
    preproc_prefix: ?u8,
    /// Arena for Lua-allocated language defs. null for built-in (Zig).
    arena: ?std.heap.ArenaAllocator,

    pub fn matchesExtension(self: *const LanguageDef, ext: []const u8) bool {
        for (self.extensions) |e| {
            if (std.mem.eql(u8, e, ext)) return true;
        }
        return false;
    }

    pub fn isKeyword(self: *const LanguageDef, word: []const u8) bool {
        for (self.keywords) |kw| {
            if (std.mem.eql(u8, kw, word)) return true;
        }
        return false;
    }

    pub fn isType(self: *const LanguageDef, word: []const u8) bool {
        for (self.types) |t| {
            if (std.mem.eql(u8, t, word)) return true;
        }
        return false;
    }

    pub fn isConstant(self: *const LanguageDef, word: []const u8) bool {
        for (self.constants) |c| {
            if (std.mem.eql(u8, c, word)) return true;
        }
        return false;
    }

    pub fn isBuiltinWord(self: *const LanguageDef, word: []const u8) bool {
        for (self.builtins) |b| {
            if (std.mem.eql(u8, b, word)) return true;
        }
        return false;
    }

    pub fn deinit(self: *LanguageDef) void {
        if (self.arena) |*a| {
            const alloc = a.allocator();
            // Free heap-allocated string slices
            if (self.line_comment) |lc| {
                if (lc.len > 0) alloc.free(lc);
            }
            if (self.block_comment_start) |bcs| {
                if (bcs.len > 0) alloc.free(bcs);
            }
            if (self.block_comment_end) |bce| {
                if (bce.len > 0) alloc.free(bce);
            }
            a.deinit();
        }
    }
};

// ---------------------------------------------------------------------------
// Built-in Zig language definition
// ---------------------------------------------------------------------------

pub const lang_zig = LanguageDef{
    .name = "zig",
    .extensions = &.{ "zig", "zon" },
    .keywords = &.{
        "addrspace",  "align",       "allowzero",   "and",        "anyframe",
        "anytype",    "asm",         "async",        "await",      "break",
        "callconv",   "catch",       "comptime",     "const",      "continue",
        "defer",      "else",        "enum",         "errdefer",   "error",
        "export",     "extern",      "fn",           "for",        "if",
        "inline",     "linksection", "noalias",      "nosuspend",  "opaque",
        "or",         "orelse",      "packed",       "pub",        "resume",
        "return",     "struct",      "suspend",      "switch",     "test",
        "threadlocal", "try",        "union",        "unreachable", "var",
        "volatile",   "while",
    },
    .types = &.{
        "void",          "bool",          "noreturn",    "type",
        "anyerror",      "anyopaque",     "comptime_int", "comptime_float",
        "u8",            "u16",           "u32",          "u64",
        "u128",          "usize",         "i8",           "i16",
        "i32",           "i64",           "i128",         "isize",
        "f16",           "f32",           "f64",          "f80",
        "f128",          "c_char",        "c_short",      "c_ushort",
        "c_int",         "c_uint",        "c_long",       "c_ulong",
        "c_longlong",    "c_ulonglong",   "c_longdouble",
    },
    .constants = &.{ "true", "false", "null", "undefined" },
    .builtins = &.{}, // Zig builtins use @ prefix, detected automatically
    .line_comment = "//",
    .block_comment_start = null,
    .block_comment_end = null,
    .string_delimiters = "\"",
    .has_char_literals = true,
    .builtin_prefix = '@',
    .preproc_prefix = null,
    .arena = null,
};

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

pub const TokenizeResult = struct {
    count: usize,
    state: LineState,
};

/// Maximum spans per line (stack-allocated buffer size for callers).
pub const MAX_SPANS: usize = 512;

pub fn tokenizeLine(
    line: []const u8,
    lang: *const LanguageDef,
    state_in: LineState,
    spans_buf: []HighlightSpan,
) TokenizeResult {
    var i: usize = 0;
    var count: usize = 0;
    var state = state_in;

    // --- Continuation: block comment ---
    if (state == .in_block_comment) {
        if (lang.block_comment_end) |bce| {
            if (std.mem.indexOf(u8, line, bce)) |end_pos| {
                const end = end_pos + bce.len;
                addSpan(&count, spans_buf, 0, end, .comment);
                i = end;
                state = .normal;
            } else {
                addSpan(&count, spans_buf, 0, line.len, .comment);
                return .{ .count = count, .state = .in_block_comment };
            }
        } else {
            state = .normal;
        }
    }

    // --- Continuation: multi-line string ---
    if (state == .in_string) {
        const delim: u8 = if (lang.string_delimiters.len > 0) lang.string_delimiters[0] else '"';
        var found_end = false;
        while (i < line.len) : (i += 1) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (line[i] == delim) {
                i += 1;
                addSpan(&count, spans_buf, 0, i, .string);
                state = .normal;
                found_end = true;
                break;
            }
        }
        if (!found_end) {
            addSpan(&count, spans_buf, 0, line.len, .string);
            return .{ .count = count, .state = .in_string };
        }
    }

    // --- Main tokenization loop ---
    while (i < line.len and count < spans_buf.len) {
        const ch = line[i];

        // Skip whitespace
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            i += 1;
            continue;
        }

        // Line comment — consumes rest of line
        if (lang.line_comment) |lc| {
            if (prefixAt(line, i, lc)) {
                addSpan(&count, spans_buf, i, line.len, .comment);
                return .{ .count = count, .state = .normal };
            }
        }

        // Block comment start
        if (lang.block_comment_start) |bcs| {
            if (prefixAt(line, i, bcs)) {
                const start = i;
                i += bcs.len;
                if (lang.block_comment_end) |bce| {
                    if (std.mem.indexOf(u8, line[i..], bce)) |end_offset| {
                        i += end_offset + bce.len;
                        addSpan(&count, spans_buf, start, i, .comment);
                        continue;
                    }
                }
                // Block comment extends past this line
                addSpan(&count, spans_buf, start, line.len, .comment);
                return .{ .count = count, .state = .in_block_comment };
            }
        }

        // Zig-style multiline string prefix (\\)
        if (ch == '\\' and i + 1 < line.len and line[i + 1] == '\\') {
            addSpan(&count, spans_buf, i, line.len, .string);
            return .{ .count = count, .state = .normal };
        }

        // String literal
        if (std.mem.indexOfScalar(u8, lang.string_delimiters, ch) != null) {
            const start = i;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    continue;
                }
                if (line[i] == ch) {
                    i += 1;
                    break;
                }
            }
            addSpan(&count, spans_buf, start, i, .string);
            continue;
        }

        // Char literal
        if (lang.has_char_literals and ch == '\'') {
            const start = i;
            i += 1;
            if (i < line.len and line[i] == '\\') {
                i += 2; // skip escape sequence
            } else if (i < line.len) {
                i += 1; // skip char content
            }
            if (i < line.len and line[i] == '\'') i += 1; // closing '
            addSpan(&count, spans_buf, start, i, .char_literal);
            continue;
        }

        // Builtin prefix (e.g., @ for Zig)
        if (lang.builtin_prefix) |prefix| {
            if (ch == prefix and i + 1 < line.len and isIdentChar(line[i + 1])) {
                const start = i;
                i += 1;
                while (i < line.len and isIdentChar(line[i])) : (i += 1) {}
                addSpan(&count, spans_buf, start, i, .builtin);
                continue;
            }
        }

        // Preprocessor prefix (e.g., # for C/C++)
        if (lang.preproc_prefix) |prefix| {
            if (ch == prefix) {
                const start = i;
                i += 1;
                while (i < line.len and isIdentChar(line[i])) : (i += 1) {}
                addSpan(&count, spans_buf, start, i, .preprocessor);
                continue;
            }
        }

        // Number literal
        if (std.ascii.isDigit(ch)) {
            const start = i;
            if (ch == '0' and i + 1 < line.len) {
                const next = line[i + 1];
                if (next == 'x' or next == 'X' or next == 'b' or next == 'B' or next == 'o' or next == 'O') {
                    i += 2;
                }
            }
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_' or line[i] == '.')) : (i += 1) {}
            addSpan(&count, spans_buf, start, i, .number);
            continue;
        }

        // Identifier → classify as keyword / type / constant / builtin / function / text
        if (isIdentStart(ch)) {
            const start = i;
            while (i < line.len and isIdentChar(line[i])) : (i += 1) {}
            const word = line[start..i];

            const token_type: TokenType = if (lang.isKeyword(word))
                .keyword
            else if (lang.isType(word))
                .type_name
            else if (lang.isConstant(word))
                .constant
            else if (lang.isBuiltinWord(word))
                .builtin
            else if (i < line.len and line[i] == '(')
                .function
            else
                .text;

            if (token_type != .text) {
                addSpan(&count, spans_buf, start, i, token_type);
            }
            continue;
        }

        // Operators (merge consecutive)
        if (isOperator(ch)) {
            const start = i;
            while (i < line.len and isOperator(line[i])) : (i += 1) {}
            addSpan(&count, spans_buf, start, i, .operator);
            continue;
        }

        // Punctuation (single char)
        if (isPunctuation(ch)) {
            addSpan(&count, spans_buf, i, i + 1, .punctuation);
            i += 1;
            continue;
        }

        // Unknown character — skip
        i += 1;
    }

    return .{ .count = count, .state = state };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn addSpan(count: *usize, buf: []HighlightSpan, start: usize, end: usize, token: TokenType) void {
    if (count.* < buf.len and end > start) {
        buf[count.*] = .{
            .start = @intCast(@min(start, std.math.maxInt(u16))),
            .end = @intCast(@min(end, std.math.maxInt(u16))),
            .token = token,
        };
        count.* += 1;
    }
}

fn prefixAt(line: []const u8, pos: usize, prefix: []const u8) bool {
    if (pos + prefix.len > line.len) return false;
    return std.mem.eql(u8, line[pos .. pos + prefix.len], prefix);
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isOperator(ch: u8) bool {
    return switch (ch) {
        '+', '-', '*', '/', '%', '=', '!', '<', '>', '&', '|', '^', '~', '?' => true,
        else => false,
    };
}

fn isPunctuation(ch: u8) bool {
    return switch (ch) {
        '(', ')', '[', ']', '{', '}', ',', ';', ':', '.', '#' => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "tokenize Zig keywords" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("pub fn main() void {", &lang_zig, .normal, &buf);
    try std.testing.expect(result.count >= 4); // pub, fn, main (function), void
    try std.testing.expectEqual(LineState.normal, result.state);
    // First span should be "pub" keyword
    try std.testing.expectEqual(TokenType.keyword, buf[0].token);
    try std.testing.expectEqual(@as(u16, 0), buf[0].start);
    try std.testing.expectEqual(@as(u16, 3), buf[0].end);
}

test "tokenize Zig string" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("const s = \"hello world\";", &lang_zig, .normal, &buf);
    try std.testing.expect(result.count >= 2);
    // Find the string span
    var found_string = false;
    for (buf[0..result.count]) |span| {
        if (span.token == .string) {
            found_string = true;
            break;
        }
    }
    try std.testing.expect(found_string);
}

test "tokenize Zig comment" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("// this is a comment", &lang_zig, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(TokenType.comment, buf[0].token);
    try std.testing.expectEqual(@as(u16, 0), buf[0].start);
    try std.testing.expectEqual(@as(u16, 20), buf[0].end);
}

test "tokenize Zig number" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("const x = 42;", &lang_zig, .normal, &buf);
    var found_number = false;
    for (buf[0..result.count]) |span| {
        if (span.token == .number) {
            found_number = true;
            break;
        }
    }
    try std.testing.expect(found_number);
}

test "tokenize Zig builtin" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("const T = @import(\"std\");", &lang_zig, .normal, &buf);
    var found_builtin = false;
    for (buf[0..result.count]) |span| {
        if (span.token == .builtin) {
            found_builtin = true;
            break;
        }
    }
    try std.testing.expect(found_builtin);
}

test "tokenize Zig types" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("var x: u32 = 0;", &lang_zig, .normal, &buf);
    var found_type = false;
    for (buf[0..result.count]) |span| {
        if (span.token == .type_name) {
            found_type = true;
            break;
        }
    }
    try std.testing.expect(found_type);
}

test "tokenize Zig multiline string prefix" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("    \\\\hello world", &lang_zig, .normal, &buf);
    try std.testing.expect(result.count >= 1);
    try std.testing.expectEqual(TokenType.string, buf[0].token);
    try std.testing.expectEqual(LineState.normal, result.state);
}

test "block comment state tracking" {
    // Simulate a C-like language with block comments
    const c_like = LanguageDef{
        .name = "c",
        .extensions = &.{ "c", "h" },
        .keywords = &.{ "int", "return", "if", "else", "void" },
        .types = &.{},
        .constants = &.{},
        .builtins = &.{},
        .line_comment = "//",
        .block_comment_start = "/*",
        .block_comment_end = "*/",
        .string_delimiters = "\"",
        .has_char_literals = true,
        .builtin_prefix = null,
        .preproc_prefix = '#',
        .arena = null,
    };

    var buf: [64]HighlightSpan = undefined;

    // Line 1: start block comment
    const r1 = tokenizeLine("int x; /* comment", &c_like, .normal, &buf);
    try std.testing.expectEqual(LineState.in_block_comment, r1.state);

    // Line 2: continue block comment
    const r2 = tokenizeLine("still in comment */", &c_like, .in_block_comment, &buf);
    try std.testing.expectEqual(LineState.normal, r2.state);
    try std.testing.expectEqual(TokenType.comment, buf[0].token);
}

test "empty line" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("", &lang_zig, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expectEqual(LineState.normal, result.state);
}

test "function detection" {
    var buf: [64]HighlightSpan = undefined;
    _ = tokenizeLine("foo(bar)", &lang_zig, .normal, &buf);
    try std.testing.expectEqual(TokenType.function, buf[0].token);
}

test "language extension matching" {
    try std.testing.expect(lang_zig.matchesExtension("zig"));
    try std.testing.expect(lang_zig.matchesExtension("zon"));
    try std.testing.expect(!lang_zig.matchesExtension("py"));
}
