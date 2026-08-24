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
    /// TODO/FIXME-style marker inside a comment.
    todo,
    /// Markdown heading line (`# ...`).
    heading,
    /// Markdown bold (`**...**`).
    strong,
    /// Markdown italic (`*...*`).
    emphasis,
    /// Markdown link/image text or autolink.
    link,
};

/// Markers highlighted inside comments (word-boundary matched, case-sensitive).
pub const todo_markers = [_][]const u8{ "TODO", "FIXME", "XXX", "HACK", "BUG", "NOTE" };

pub const HighlightSpan = struct {
    start: u16,
    end: u16,
    token: TokenType,
};

pub const LineState = enum(u8) {
    normal = 0,
    in_block_comment = 1,
    in_string = 2,
    /// Markdown: inside a ``` / ~~~ fenced code block.
    in_code_fence = 3,
    /// Markdown: inside a multi-line HTML comment (`<!-- ... -->`).
    in_html_comment = 4,
};

// ---------------------------------------------------------------------------
// Language definition
// ---------------------------------------------------------------------------

pub const TokenizerKind = enum {
    /// Keyword/comment/string tokenizer driven by the LanguageDef tables.
    generic,
    /// Dedicated Markdown tokenizer (the LanguageDef tables are unused).
    markdown,
};

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
    /// Which tokenizer processes this language's lines.
    tokenizer: TokenizerKind = .generic,
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
        // Every string in a Lua-registered language is arena-allocated —
        // tearing down the arena frees them all.
        if (self.arena) |*a| a.deinit();
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
// Built-in Markdown language definition
// ---------------------------------------------------------------------------

/// Markdown is structural, not keyword-based — the tables stay empty and
/// `tokenizer = .markdown` routes lines to the dedicated tokenizer.
pub const lang_markdown = LanguageDef{
    .name = "markdown",
    .extensions = &.{ "md", "markdown" },
    .keywords = &.{},
    .types = &.{},
    .constants = &.{},
    .builtins = &.{},
    .line_comment = null,
    .block_comment_start = null,
    .block_comment_end = null,
    .string_delimiters = "",
    .has_char_literals = false,
    .builtin_prefix = null,
    .preproc_prefix = null,
    .tokenizer = .markdown,
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
    if (lang.tokenizer == .markdown) return tokenizeMarkdownLine(line, state_in, spans_buf);

    var i: usize = 0;
    var count: usize = 0;
    var state = state_in;

    // --- Continuation: block comment ---
    if (state == .in_block_comment) {
        if (lang.block_comment_end) |bce| {
            if (std.mem.indexOf(u8, line, bce)) |end_pos| {
                const end = end_pos + bce.len;
                addCommentSpans(&count, spans_buf, line, 0, end);
                i = end;
                state = .normal;
            } else {
                addCommentSpans(&count, spans_buf, line, 0, line.len);
                return .{ .count = count, .state = .in_block_comment };
            }
        } else {
            state = .normal;
        }
    }

    // Any other carried state is foreign here: .in_string is unreachable (no
    // tokenizer path emits it) and the fence/HTML-comment states belong to the
    // markdown tokenizer. Normalize defensively if a stale cache hands one in.
    if (state != .normal) state = .normal;

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
                addCommentSpans(&count, spans_buf, line, i, line.len);
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
                        addCommentSpans(&count, spans_buf, line, start, i);
                        continue;
                    }
                }
                // Block comment extends past this line
                addCommentSpans(&count, spans_buf, line, start, line.len);
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

/// Emit a comment region split into .comment / .todo spans so TODO-style
/// markers inside it stand out.
fn addCommentSpans(count: *usize, buf: []HighlightSpan, line: []const u8, start: usize, end: usize) void {
    var plain_from = start;
    var i = start;
    while (i < end) {
        if (todoMarkerEnd(line, i, end)) |marker_end| {
            if (i > plain_from) addSpan(count, buf, plain_from, i, .comment);
            addSpan(count, buf, i, marker_end, .todo);
            plain_from = marker_end;
            i = marker_end;
        } else {
            i += 1;
        }
    }
    if (plain_from < end) addSpan(count, buf, plain_from, end, .comment);
}

/// If a TODO-style marker starts at `pos` on a word boundary, return its end.
fn todoMarkerEnd(line: []const u8, pos: usize, end: usize) ?usize {
    if (pos > 0 and isIdentChar(line[pos - 1])) return null;
    for (todo_markers) |m| {
        if (pos + m.len > end) continue;
        if (!std.mem.eql(u8, line[pos .. pos + m.len], m)) continue;
        // Word boundary after the marker
        if (pos + m.len < end and isIdentChar(line[pos + m.len])) continue;
        return pos + m.len;
    }
    return null;
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
// Markdown tokenizer
//
// Line-oriented approximation of CommonMark + GFM, matched to the per-line
// span/state architecture above. Deliberate cuts: setext (`===`) headings,
// indented code blocks (false-positives on nested lists), and embedded
// highlighting inside fences (per-line u8 state can't carry a language).
// ---------------------------------------------------------------------------

fn tokenizeMarkdownLine(line: []const u8, state_in: LineState, spans_buf: []HighlightSpan) TokenizeResult {
    var count: usize = 0;

    // --- Continuation: fenced code block ---
    if (state_in == .in_code_fence) {
        const first = skipMdSpace(line, 0);
        if (fenceEnd(line, first)) |run_end| {
            if (skipMdSpace(line, run_end) >= line.len) {
                // Closing fence
                addSpan(&count, spans_buf, first, run_end, .operator);
                return .{ .count = count, .state = .normal };
            }
        }
        addSpan(&count, spans_buf, 0, line.len, .string);
        return .{ .count = count, .state = .in_code_fence };
    }

    // --- Continuation: multi-line HTML comment ---
    if (state_in == .in_html_comment) {
        if (std.mem.indexOf(u8, line, "-->")) |close| {
            addCommentSpans(&count, spans_buf, line, 0, close + 3);
            const state = scanMdInline(line, close + 3, &count, spans_buf);
            return .{ .count = count, .state = state };
        }
        addCommentSpans(&count, spans_buf, line, 0, line.len);
        return .{ .count = count, .state = .in_html_comment };
    }

    // --- Containers: blockquote markers and list bullets ---
    var pos = skipMdSpace(line, 0);
    if (pos >= line.len) return .{ .count = count, .state = .normal };

    var saw_list = false;
    while (pos < line.len) {
        // Thematic break wins over list markers ("- - -" vs "- item")
        if (hrEnd(line, pos)) |end| {
            addSpan(&count, spans_buf, pos, end, .operator);
            return .{ .count = count, .state = .normal };
        }
        if (line[pos] == '>') {
            addSpan(&count, spans_buf, pos, pos + 1, .operator);
            pos = skipMdSpace(line, pos + 1);
            continue;
        }
        if (!saw_list) {
            if (listMarkerEnd(line, pos)) |end| {
                addSpan(&count, spans_buf, pos, end, .operator);
                saw_list = true;
                pos = skipMdSpace(line, end);
                // GFM task checkbox directly after the bullet
                if (taskBoxEnd(line, pos)) |box_end| {
                    addSpan(&count, spans_buf, pos, box_end, .constant);
                    pos = skipMdSpace(line, box_end);
                }
                continue;
            }
        }
        break;
    }
    if (pos >= line.len) return .{ .count = count, .state = .normal };

    // --- Leaf blocks ---
    // Fence open (``` or ~~~, optional info string)
    if (fenceEnd(line, pos)) |run_end| {
        addSpan(&count, spans_buf, pos, run_end, .operator);
        const info_start = skipMdSpace(line, run_end);
        const info_end = trimMdEnd(line);
        if (info_end > info_start) addSpan(&count, spans_buf, info_start, info_end, .type_name);
        return .{ .count = count, .state = .in_code_fence };
    }
    // ATX heading: 1-6 '#' then space or end-of-line
    if (line[pos] == '#') {
        var h = pos;
        while (h < line.len and line[h] == '#') h += 1;
        if (h - pos <= 6 and (h >= line.len or line[h] == ' ' or line[h] == '\t')) {
            addSpan(&count, spans_buf, pos, line.len, .heading);
            return .{ .count = count, .state = .normal };
        }
    }
    // Table delimiter row ("| --- | :---: |") — all structural, one span
    if (tableDelimEnd(line, pos)) |end| {
        addSpan(&count, spans_buf, pos, end, .operator);
        return .{ .count = count, .state = .normal };
    }

    // --- Inline content ---
    const state = scanMdInline(line, pos, &count, spans_buf);
    return .{ .count = count, .state = state };
}

/// Inline markdown scanner from `start` to end of line, emitting spans in
/// left-to-right order. Returns .in_html_comment if an HTML comment opened
/// without closing on this line, else .normal.
fn scanMdInline(line: []const u8, start: usize, count: *usize, spans_buf: []HighlightSpan) LineState {
    var i = start;
    while (i < line.len) {
        switch (line[i]) {
            '\\' => i = @min(i + 2, line.len),
            '`' => {
                var run = i;
                while (run < line.len and line[run] == '`') run += 1;
                if (codeSpanClose(line, run, run - i)) |close_end| {
                    addSpan(count, spans_buf, i, close_end, .string);
                    i = close_end;
                } else {
                    // Unmatched backticks are literal
                    i = run;
                }
            },
            '*' => i = emphasisSpan(line, i, '*', count, spans_buf),
            '_' => i = emphasisSpan(line, i, '_', count, spans_buf),
            '~' => {
                if (i + 1 < line.len and line[i + 1] == '~') {
                    if (delimClose(line, i + 2, "~~")) |close| {
                        addSpan(count, spans_buf, i, close + 2, .comment);
                        i = close + 2;
                    } else {
                        i += 2;
                    }
                } else {
                    i += 1;
                }
            },
            '!', '[' => {
                const bracket = if (line[i] == '!') i + 1 else i;
                if (bracket < line.len and line[bracket] == '[') {
                    if (linkSpan(line, i, bracket, count, spans_buf)) |next| {
                        i = next;
                        continue;
                    }
                }
                i += 1;
            },
            '<' => {
                if (prefixAt(line, i, "<!--")) {
                    if (std.mem.indexOfPos(u8, line, i + 4, "-->")) |close| {
                        addCommentSpans(count, spans_buf, line, i, close + 3);
                        i = close + 3;
                    } else {
                        addCommentSpans(count, spans_buf, line, i, line.len);
                        return .in_html_comment;
                    }
                } else if (autolinkEnd(line, i)) |end| {
                    addSpan(count, spans_buf, i, end, .link);
                    i = end;
                } else {
                    i += 1;
                }
            },
            '|' => {
                // Table cell separator
                addSpan(count, spans_buf, i, i + 1, .operator);
                i += 1;
            },
            else => i += 1,
        }
    }
    return .normal;
}

/// Emphasis / strong at `i` with marker `ch` ('*' or '_'). Emits a span when a
/// valid closer exists on the line; returns the position to resume scanning.
fn emphasisSpan(line: []const u8, i: usize, ch: u8, count: *usize, spans_buf: []HighlightSpan) usize {
    var run = i;
    while (run < line.len and line[run] == ch) run += 1;
    const open_len = run - i;

    // Opener must be followed by a non-space; '_' additionally must not sit
    // inside a word (snake_case stays plain).
    if (run >= line.len or line[run] == ' ' or line[run] == '\t') return run;
    if (ch == '_' and i > 0 and isIdentChar(line[i - 1])) return run;

    const want: usize = @min(open_len, 2);
    var j = run;
    while (j < line.len) {
        if (line[j] != ch) {
            j += 1;
            continue;
        }
        var close_run = j;
        while (close_run < line.len and line[close_run] == ch) close_run += 1;
        const prev = line[j - 1];
        const prev_ok = prev != ' ' and prev != '\t' and prev != ch;
        const word_ok = ch != '_' or close_run >= line.len or !isIdentChar(line[close_run]);
        if (close_run - j >= want and prev_ok and word_ok) {
            addSpan(count, spans_buf, i, close_run, if (want == 2) .strong else .emphasis);
            return close_run;
        }
        j = close_run;
    }
    return run;
}

/// Link or image at `i` (`bracket` = index of '['). Emits `[text]` as .link
/// and an inline `(url)` destination as .comment (dim). Returns the resume
/// position, or null when there is no closing ']' on the line.
fn linkSpan(line: []const u8, i: usize, bracket: usize, count: *usize, spans_buf: []HighlightSpan) ?usize {
    var depth: usize = 0;
    var j = bracket;
    const close_bracket = while (j < line.len) : (j += 1) {
        switch (line[j]) {
            '\\' => j += 1, // skip escaped char
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) break j;
            },
            else => {},
        }
    } else return null;

    addSpan(count, spans_buf, i, close_bracket + 1, .link);
    if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
        var pdepth: usize = 0;
        var k = close_bracket + 1;
        while (k < line.len) : (k += 1) {
            switch (line[k]) {
                '\\' => k += 1,
                '(' => pdepth += 1,
                ')' => {
                    pdepth -= 1;
                    if (pdepth == 0) {
                        addSpan(count, spans_buf, close_bracket + 1, k + 1, .comment);
                        return k + 1;
                    }
                },
                else => {},
            }
        }
    }
    return close_bracket + 1;
}

/// Find a closing backtick run of exactly `n` backticks at or after `from`.
/// Returns the index just past the closing run.
fn codeSpanClose(line: []const u8, from: usize, n: usize) ?usize {
    var i = from;
    while (i < line.len) {
        if (line[i] == '`') {
            var run = i;
            while (run < line.len and line[run] == '`') run += 1;
            if (run - i == n) return run;
            i = run;
        } else {
            i += 1;
        }
    }
    return null;
}

/// Find closing delimiter `delim` at or after `from` preceded by a non-space
/// character. Returns its start index.
fn delimClose(line: []const u8, from: usize, delim: []const u8) ?usize {
    var i = from;
    while (i + delim.len <= line.len) : (i += 1) {
        if (std.mem.startsWith(u8, line[i..], delim)) {
            if (i > 0 and line[i - 1] != ' ' and line[i - 1] != '\t') return i;
        }
    }
    return null;
}

/// Autolink `<scheme://...>` with no spaces inside. Returns index past '>'.
fn autolinkEnd(line: []const u8, i: usize) ?usize {
    var j = i + 1;
    var has_scheme = false;
    while (j < line.len) : (j += 1) {
        switch (line[j]) {
            '>' => return if (has_scheme) j + 1 else null,
            ' ', '\t', '<' => return null,
            ':' => {
                if (prefixAt(line, j, "://")) has_scheme = true;
            },
            else => {},
        }
    }
    return null;
}

/// If a code-fence delimiter run (3+ backticks or tildes) starts at `pos`,
/// return the index just past the run.
fn fenceEnd(line: []const u8, pos: usize) ?usize {
    if (pos >= line.len) return null;
    const ch = line[pos];
    if (ch != '`' and ch != '~') return null;
    var i = pos;
    while (i < line.len and line[i] == ch) i += 1;
    if (i - pos < 3) return null;
    return i;
}

/// Thematic break: 3+ of the same '-' / '*' / '_' with only spaces between
/// and nothing else on the line. Returns the trimmed end.
fn hrEnd(line: []const u8, pos: usize) ?usize {
    if (pos >= line.len) return null;
    const ch = line[pos];
    if (ch != '-' and ch != '*' and ch != '_') return null;
    var n: usize = 0;
    var i = pos;
    while (i < line.len) : (i += 1) {
        if (line[i] == ch) {
            n += 1;
        } else if (line[i] != ' ' and line[i] != '\t' and line[i] != '\r') {
            return null;
        }
    }
    if (n < 3) return null;
    return trimMdEnd(line);
}

/// List marker at `pos`: "- " / "* " / "+ " bullet or "12." / "12)" ordered.
/// Returns the index just past the marker (excluding the following space).
/// A bare marker at end-of-line also counts (empty list item).
fn listMarkerEnd(line: []const u8, pos: usize) ?usize {
    const ch = line[pos];
    if (ch == '-' or ch == '*' or ch == '+') {
        const after = pos + 1;
        if (after >= line.len or line[after] == ' ' or line[after] == '\t') return after;
        return null;
    }
    if (std.ascii.isDigit(ch)) {
        var i = pos;
        while (i < line.len and std.ascii.isDigit(line[i]) and i - pos < 9) i += 1;
        if (i < line.len and (line[i] == '.' or line[i] == ')')) {
            const after = i + 1;
            if (after >= line.len or line[after] == ' ' or line[after] == '\t') return after;
        }
        return null;
    }
    return null;
}

/// GFM task checkbox "[ ]" / "[x]" / "[X]" at `pos` followed by a space or
/// end-of-line. Returns the index just past the ']'.
fn taskBoxEnd(line: []const u8, pos: usize) ?usize {
    if (pos + 3 > line.len) return null;
    if (line[pos] != '[') return null;
    const c = line[pos + 1];
    if (c != ' ' and c != 'x' and c != 'X') return null;
    if (line[pos + 2] != ']') return null;
    if (pos + 3 < line.len and line[pos + 3] != ' ' and line[pos + 3] != '\t') return null;
    return pos + 3;
}

/// Table delimiter row: only '|', '-', ':' and spaces, with at least one pipe
/// and three dashes. Returns the trimmed end.
fn tableDelimEnd(line: []const u8, pos: usize) ?usize {
    var pipes: usize = 0;
    var dashes: usize = 0;
    var i = pos;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '|' => pipes += 1,
            '-' => dashes += 1,
            ':', ' ', '\t', '\r' => {},
            else => return null,
        }
    }
    if (pipes == 0 or dashes < 3) return null;
    return trimMdEnd(line);
}

fn skipMdSpace(line: []const u8, from: usize) usize {
    var i = from;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\r')) i += 1;
    return i;
}

fn trimMdEnd(line: []const u8) usize {
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) end -= 1;
    return end;
}

// ---------------------------------------------------------------------------
// Markdown editing support (Enter-continuation of lists/quotes)
// ---------------------------------------------------------------------------

pub const MdListInfo = struct {
    /// Column where the marker chain (indent, quotes, bullet, checkbox) ends
    /// and content would begin.
    content_start: usize,
    /// Number of '>' blockquote levels.
    quote_levels: u8,
    list: ?ListKind,
    /// Whether a task checkbox follows the bullet.
    task: bool,
    /// Whether any non-whitespace content follows the markers.
    has_content: bool,

    pub const ListKind = union(enum) {
        /// Bullet char: '-', '*', or '+'.
        bullet: u8,
        /// Ordered item number and its delimiter ('.' or ')').
        ordered: struct { number: u64, delim: u8 },
    };
};

/// Parse blockquote/list markers at the start of a markdown line, for
/// Enter-continuation. Returns null when the line has no markers (or is a
/// thematic break, which only looks like a bullet).
pub fn mdListInfo(line: []const u8) ?MdListInfo {
    var info = MdListInfo{
        .content_start = 0,
        .quote_levels = 0,
        .list = null,
        .task = false,
        .has_content = false,
    };
    var pos = skipMdSpace(line, 0);
    while (pos < line.len) {
        if (hrEnd(line, pos) != null) return null;
        if (line[pos] == '>') {
            info.quote_levels +|= 1;
            pos = skipMdSpace(line, pos + 1);
            continue;
        }
        if (info.list == null) {
            if (listMarkerEnd(line, pos)) |end| {
                const ch = line[pos];
                info.list = if (std.ascii.isDigit(ch)) .{ .ordered = .{
                    .number = std.fmt.parseInt(u64, line[pos .. end - 1], 10) catch 0,
                    .delim = line[end - 1],
                } } else .{ .bullet = ch };
                pos = skipMdSpace(line, end);
                if (taskBoxEnd(line, pos)) |box_end| {
                    info.task = true;
                    pos = skipMdSpace(line, box_end);
                }
                continue;
            }
        }
        break;
    }
    if (info.quote_levels == 0 and info.list == null) return null;
    info.content_start = pos;
    info.has_content = pos < line.len;
    return info;
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

test "TODO markers inside comments get their own spans" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("// TODO: fix this", &lang_zig, .normal, &buf);
    // "// " comment, "TODO" todo, ": fix this" comment
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqual(TokenType.comment, buf[0].token);
    try std.testing.expectEqual(TokenType.todo, buf[1].token);
    try std.testing.expectEqual(@as(u16, 3), buf[1].start);
    try std.testing.expectEqual(@as(u16, 7), buf[1].end);
    try std.testing.expectEqual(TokenType.comment, buf[2].token);
}

test "TODO marker needs word boundaries" {
    var buf: [64]HighlightSpan = undefined;
    // TODOS and myTODO must NOT match; plain comment span only
    const r1 = tokenizeLine("// TODOS are plural", &lang_zig, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r1.count);
    try std.testing.expectEqual(TokenType.comment, buf[0].token);

    const r2 = tokenizeLine("// myTODO marker", &lang_zig, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r2.count);
    try std.testing.expectEqual(TokenType.comment, buf[0].token);
}

test "FIXME in block comment continuation" {
    const c_like = LanguageDef{
        .name = "c",
        .extensions = &.{"c"},
        .keywords = &.{},
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
    const result = tokenizeLine("FIXME later */", &c_like, .in_block_comment, &buf);
    try std.testing.expectEqual(TokenType.todo, buf[0].token);
    try std.testing.expectEqual(@as(u16, 0), buf[0].start);
    try std.testing.expectEqual(@as(u16, 5), buf[0].end);
    try std.testing.expectEqual(LineState.normal, result.state);
}

test "TODO outside comments is not highlighted" {
    var buf: [64]HighlightSpan = undefined;
    const result = tokenizeLine("const TODO = 1;", &lang_zig, .normal, &buf);
    for (buf[0..result.count]) |span| {
        try std.testing.expect(span.token != .todo);
    }
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
    try std.testing.expect(lang_markdown.matchesExtension("md"));
    try std.testing.expect(lang_markdown.matchesExtension("markdown"));
}

test "markdown heading" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("## Title", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(TokenType.heading, buf[0].token);
    try std.testing.expectEqual(@as(u16, 0), buf[0].start);
    try std.testing.expectEqual(@as(u16, 8), buf[0].end);
    // Missing space after '#' → not a heading
    const r2 = tokenizeLine("#nospace", &lang_markdown, .normal, &buf);
    for (buf[0..r2.count]) |s| try std.testing.expect(s.token != .heading);
}

test "markdown bold and italic" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("mix **bold** and *ital*", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectEqual(TokenType.strong, buf[0].token);
    try std.testing.expectEqual(@as(u16, 4), buf[0].start);
    try std.testing.expectEqual(@as(u16, 12), buf[0].end);
    try std.testing.expectEqual(TokenType.emphasis, buf[1].token);
    // Bold-italic run covered as one strong span
    const r2 = tokenizeLine("***both***", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r2.count);
    try std.testing.expectEqual(TokenType.strong, buf[0].token);
    try std.testing.expectEqual(@as(u16, 10), buf[0].end);
}

test "markdown snake_case is not emphasis" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("use foo_bar_baz here", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 0), r.count);
    // Unclosed '*' and space-flanked '*' stay plain
    const r2 = tokenizeLine("a * b * c", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 0), r2.count);
}

test "markdown inline code" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("run `zig build` now", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(TokenType.string, buf[0].token);
    try std.testing.expectEqual(@as(u16, 4), buf[0].start);
    try std.testing.expectEqual(@as(u16, 15), buf[0].end);
    // Unmatched backtick stays plain, emphasis inside code is swallowed
    const r2 = tokenizeLine("a ` b", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 0), r2.count);
    const r3 = tokenizeLine("`a *b* c`", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r3.count);
    try std.testing.expectEqual(TokenType.string, buf[0].token);
}

test "markdown fenced code block state" {
    var buf: [64]HighlightSpan = undefined;
    const r1 = tokenizeLine("```zig", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(LineState.in_code_fence, r1.state);
    try std.testing.expectEqual(TokenType.operator, buf[0].token);
    try std.testing.expectEqual(TokenType.type_name, buf[1].token); // info string
    const r2 = tokenizeLine("const x = 1;", &lang_markdown, .in_code_fence, &buf);
    try std.testing.expectEqual(LineState.in_code_fence, r2.state);
    try std.testing.expectEqual(TokenType.string, buf[0].token);
    // A heading inside a fence is code, not a heading
    const r3 = tokenizeLine("# not a heading", &lang_markdown, .in_code_fence, &buf);
    try std.testing.expectEqual(TokenType.string, buf[0].token);
    try std.testing.expectEqual(LineState.in_code_fence, r3.state);
    const r4 = tokenizeLine("```", &lang_markdown, .in_code_fence, &buf);
    try std.testing.expectEqual(LineState.normal, r4.state);
}

test "markdown link and image" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("see [docs](http://x.io) ok", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectEqual(TokenType.link, buf[0].token); // [docs]
    try std.testing.expectEqual(@as(u16, 4), buf[0].start);
    try std.testing.expectEqual(@as(u16, 10), buf[0].end);
    try std.testing.expectEqual(TokenType.comment, buf[1].token); // (url) dim
    const r2 = tokenizeLine("![img](a.png)", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 2), r2.count);
    try std.testing.expectEqual(TokenType.link, buf[0].token);
    try std.testing.expectEqual(@as(u16, 0), buf[0].start); // includes '!'
    // Reference-style link: text part only
    const r3 = tokenizeLine("see [docs][ref]", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 2), r3.count);
    try std.testing.expectEqual(TokenType.link, buf[0].token);
    try std.testing.expectEqual(TokenType.link, buf[1].token);
}

test "markdown list bullets and task boxes" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("- [x] done **now**", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqual(TokenType.operator, buf[0].token); // -
    try std.testing.expectEqual(TokenType.constant, buf[1].token); // [x]
    try std.testing.expectEqual(TokenType.strong, buf[2].token);
    const r2 = tokenizeLine("3. item", &lang_markdown, .normal, &buf);
    try std.testing.expect(r2.count >= 1);
    try std.testing.expectEqual(TokenType.operator, buf[0].token); // "3."
    try std.testing.expectEqual(@as(u16, 0), buf[0].start);
    try std.testing.expectEqual(@as(u16, 2), buf[0].end);
}

test "markdown blockquote and nested markers" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("> - item", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectEqual(TokenType.operator, buf[0].token); // >
    try std.testing.expectEqual(TokenType.operator, buf[1].token); // -
    const r2 = tokenizeLine("> # Quoted title", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 2), r2.count);
    try std.testing.expectEqual(TokenType.heading, buf[1].token);
}

test "markdown thematic break vs bullet" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("---", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(TokenType.operator, buf[0].token);
    try std.testing.expectEqual(@as(u16, 3), buf[0].end);
    const r2 = tokenizeLine("- - -", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r2.count); // one rule span, not bullets
}

test "markdown table rows" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("| a | b |", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 3), r.count); // three pipes
    for (buf[0..r.count]) |s| try std.testing.expectEqual(TokenType.operator, s.token);
    const r2 = tokenizeLine("| --- | :---: |", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r2.count); // whole delimiter row
    try std.testing.expectEqual(TokenType.operator, buf[0].token);
}

test "markdown strikethrough" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("a ~~gone~~ b", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(TokenType.comment, buf[0].token);
    try std.testing.expectEqual(@as(u16, 2), buf[0].start);
    try std.testing.expectEqual(@as(u16, 10), buf[0].end);
}

test "markdown html comment with TODO" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("<!-- TODO: write -->", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(LineState.normal, r.state);
    try std.testing.expectEqual(TokenType.comment, buf[0].token);
    try std.testing.expectEqual(TokenType.todo, buf[1].token);
    // Unclosed comment carries state to the next line
    const r2 = tokenizeLine("text <!-- open", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(LineState.in_html_comment, r2.state);
    const r3 = tokenizeLine("still hidden -->", &lang_markdown, .in_html_comment, &buf);
    try std.testing.expectEqual(LineState.normal, r3.state);
    try std.testing.expectEqual(TokenType.comment, buf[0].token);
}

test "markdown autolink" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("go <https://ziglang.org> now", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(TokenType.link, buf[0].token);
    // Plain html tag is not an autolink
    const r2 = tokenizeLine("a <b> c", &lang_markdown, .normal, &buf);
    try std.testing.expectEqual(@as(usize, 0), r2.count);
}

test "generic tokenizer normalizes foreign markdown states" {
    var buf: [64]HighlightSpan = undefined;
    const r = tokenizeLine("const x = 1;", &lang_zig, .in_code_fence, &buf);
    try std.testing.expectEqual(LineState.normal, r.state);
    const r2 = tokenizeLine("const y = 2;", &lang_zig, .in_html_comment, &buf);
    try std.testing.expectEqual(LineState.normal, r2.state);
}

test "mdListInfo continuation parsing" {
    // Bullet with content
    const b = mdListInfo("  - item").?;
    try std.testing.expectEqual(@as(u8, 0), b.quote_levels);
    try std.testing.expect(b.list.? == .bullet);
    try std.testing.expect(b.has_content);
    try std.testing.expectEqual(@as(usize, 4), b.content_start);
    // Empty items (bare marker, marker + trailing space)
    try std.testing.expect(!mdListInfo("- ").?.has_content);
    try std.testing.expect(!mdListInfo("-").?.has_content);
    // Ordered
    const o = mdListInfo("12. ").?;
    try std.testing.expectEqual(@as(u64, 12), o.list.?.ordered.number);
    try std.testing.expectEqual(@as(u8, '.'), o.list.?.ordered.delim);
    try std.testing.expect(!o.has_content);
    // Task item
    const t = mdListInfo("- [x] done").?;
    try std.testing.expect(t.task);
    try std.testing.expect(t.has_content);
    // Quote, nested quote + bullet
    try std.testing.expectEqual(@as(u8, 1), mdListInfo("> text").?.quote_levels);
    const n = mdListInfo("> > - x").?;
    try std.testing.expectEqual(@as(u8, 2), n.quote_levels);
    try std.testing.expect(n.list != null);
    // No markers / thematic break
    try std.testing.expect(mdListInfo("plain text") == null);
    try std.testing.expect(mdListInfo("- - -") == null);
}
