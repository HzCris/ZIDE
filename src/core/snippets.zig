//! Lua supplies definitions; templates and live byte ranges are owned by the core.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;

pub const Range = struct {
    number: u32,
    start: usize,
    end: usize,
    /// Textual order disambiguates adjacent empty fields (including $0).
    order: usize,
};

pub const Template = struct {
    text: []u8,
    stops: []Range,
    final: Range,

    pub fn deinit(self: *Template, a: Allocator) void {
        a.free(self.text);
        a.free(self.stops);
    }

    pub fn parse(a: Allocator, body: []const u8) !Template {
        if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        var stops: std.ArrayList(Range) = .empty;
        defer stops.deinit(a);
        var final: ?Range = null;
        var i: usize = 0;
        var order: usize = 0;
        while (i < body.len) {
            if (body[i] != '$') {
                try literal(a, &text, body, &i);
                continue;
            }
            i += 1;
            const braced = i < body.len and body[i] == '{';
            if (braced) i += 1;
            const begin = i;
            while (i < body.len and std.ascii.isDigit(body[i])) : (i += 1) {}
            if (begin == i) return error.UnsupportedPlaceholder;
            const number = std.fmt.parseInt(u32, body[begin..i], 10) catch return error.InvalidPlaceholderNumber;
            if (number == 0 and final != null) return error.RepeatedPlaceholder;
            for (stops.items) |stop| if (stop.number == number) return error.RepeatedPlaceholder;
            const start = text.items.len;
            if (braced) {
                if (i == body.len) return error.UnclosedPlaceholder;
                if (body[i] == ':') {
                    i += 1;
                    while (i < body.len and body[i] != '}') {
                        if (body[i] == '$') return error.NestedPlaceholder;
                        try literal(a, &text, body, &i);
                    }
                }
                if (i == body.len) return error.UnclosedPlaceholder;
                if (body[i] != '}') return error.UnsupportedPlaceholder;
                i += 1;
            }
            const stop: Range = .{ .number = number, .start = start, .end = text.items.len, .order = order };
            order += 1;
            if (number == 0) final = stop else try stops.append(a, stop);
        }
        std.mem.sort(Range, stops.items, {}, struct {
            fn less(_: void, x: Range, y: Range) bool {
                return x.number < y.number;
            }
        }.less);
        const owned_text = try text.toOwnedSlice(a);
        errdefer a.free(owned_text);
        return .{
            .text = owned_text,
            .stops = try stops.toOwnedSlice(a),
            .final = final orelse .{ .number = 0, .start = owned_text.len, .end = owned_text.len, .order = order },
        };
    }

    fn literal(a: Allocator, out: *std.ArrayList(u8), body: []const u8, i: *usize) !void {
        if (body[i.*] == '\\' and i.* + 1 < body.len and
            (body[i.* + 1] == '$' or body[i.* + 1] == '}' or body[i.* + 1] == '\\')) i.* += 1;
        try out.append(a, body[i.*]);
        i.* += 1;
    }

    /// Convert indentation and line endings, mapping every field into the result.
    pub fn expand(self: *const Template, a: Allocator, base: []const u8, use_tabs: bool, indent_width: usize, eol: []const u8) !Expansion {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        const offsets = try a.alloc(usize, self.text.len + 1);
        defer a.free(offsets);
        var leading = true;
        var i: usize = 0;
        while (i < self.text.len) : (i += 1) {
            offsets[i] = out.items.len;
            const c = self.text[i];
            if (c == '\n' or c == '\r') {
                if (c == '\r' and i + 1 < self.text.len and self.text[i + 1] == '\n') {
                    i += 1;
                    offsets[i] = out.items.len;
                }
                try out.appendSlice(a, eol);
                try out.appendSlice(a, base);
                leading = true;
            } else if (c == '\t' and leading and !use_tabs) {
                try out.appendNTimes(a, ' ', @max(1, indent_width));
            } else {
                try out.append(a, c);
                if (c != ' ' and c != '\t') leading = false;
            }
        }
        offsets[i] = out.items.len;
        const stops = try a.dupe(Range, self.stops);
        errdefer a.free(stops);
        for (stops) |*r| {
            r.start = offsets[r.start];
            r.end = offsets[r.end];
        }
        var final = self.final;
        final.start = offsets[final.start];
        final.end = offsets[final.end];
        return .{ .text = try out.toOwnedSlice(a), .session = .{ .stops = stops, .final = final } };
    }
};

pub const Expansion = struct {
    text: []u8,
    session: Session,
    pub fn deinit(self: *Expansion, a: Allocator) void {
        a.free(self.text);
        self.session.deinit(a);
    }
};

pub const Session = struct {
    stops: []Range,
    final: Range,
    current: usize = 0,

    pub fn deinit(self: *Session, a: Allocator) void {
        a.free(self.stops);
        self.stops = &.{};
    }
    pub fn active(self: *const Session) Range {
        return self.stops[self.current];
    }
    pub fn contains(self: *const Session, offset: usize, anchor: ?usize) bool {
        const r = self.active();
        return offset >= r.start and offset <= r.end and
            (anchor == null or (anchor.? >= r.start and anchor.? <= r.end));
    }
    pub fn relocate(self: *Session, start: usize) void {
        for (self.stops) |*r| {
            r.start += start;
            r.end += start;
        }
        self.final.start += start;
        self.final.end += start;
    }
    /// Called only for committed primitives. False ends navigation at a boundary-crossing edit.
    pub fn edit(self: *Session, start: usize, removed: usize, added: usize) bool {
        const r = self.active();
        if (start < r.start or start > r.end or removed > r.end - start) return false;
        for (self.stops, 0..) |*other, index| {
            if (index == self.current) {
                other.end = other.end - removed + added;
            } else if (other.start > start or (other.start == start and other.order > r.order)) {
                other.start = other.start - removed + added;
                other.end = other.end - removed + added;
            }
        }
        if (self.final.start > start or (self.final.start == start and self.final.order > r.order)) {
            self.final.start = self.final.start - removed + added;
            self.final.end = self.final.end - removed + added;
        }
        return true;
    }
};

/// What `zide.register_snippet` hands over. Only `language` and `body`
/// are required: a snippet needs a `prefix` (its Tab trigger) or a
/// `description` (its name in the Snippets panel and the palette), and
/// the description defaults to the prefix.
pub const Spec = struct {
    language: []const u8,
    body: []const u8,
    prefix: []const u8 = "",
    description: []const u8 = "",
    /// The folder the Snippets panel files it under.
    group: []const u8 = "",
    /// Plain-language explanation shown beside the preview, never inserted.
    notes: []const u8 = "",
};

pub const default_group = "Other";

/// Longest slug a trigger-less snippet's command name carries.
pub const max_slug = 64;

pub const Definition = struct {
    language: []u8,
    /// The Tab trigger; empty when the snippet has none (panel and
    /// palette only).
    prefix: []u8,
    /// The name shown in the Snippets panel.
    description: []u8,
    group: []u8,
    notes: []u8,
    command: []u8,
    template: Template,
    /// The body as registered, blanks and all (the template has parsed
    /// them away): what the panel's Edit and Copy write back out.
    body: []u8,
    from_extension: bool,
    /// The extension file that registered it (`my-snippets.lua`), or ""
    /// for init.lua and the Lua runtime.
    source: []u8 = &.{},

    pub fn init(a: Allocator, spec: Spec, from_extension: bool) !Definition {
        // The language is part of the command name the palette draws.
        if (spec.language.len == 0 or std.mem.indexOfAny(u8, spec.language, " \t\r\n\x00") != null or !std.unicode.utf8ValidateSlice(spec.language)) return error.InvalidLanguage;
        if (spec.prefix.len > 0) {
            if (std.ascii.isDigit(spec.prefix[0]) or !std.unicode.utf8ValidateSlice(spec.prefix)) return error.InvalidPrefix;
            for (spec.prefix) |c| if (!isIdentifier(c) or c == '@') return error.InvalidPrefix;
        }
        // Description, group and notes are drawn by both frontends: dvui
        // refuses malformed UTF-8 and a terminal cell cannot hold a newline.
        const description = if (spec.description.len > 0) spec.description else spec.prefix;
        if (description.len == 0) return error.MissingName;
        if (!oneLine(description)) return error.InvalidDescription;
        const group = if (spec.group.len > 0) spec.group else default_group;
        if (!oneLine(group)) return error.InvalidGroup;
        if (!notesText(spec.notes)) return error.InvalidNotes;
        var slug_buf: [max_slug]u8 = undefined;
        const name_slug = if (spec.prefix.len == 0) slug(&slug_buf, description) else "";
        if (spec.prefix.len == 0 and name_slug.len == 0) return error.InvalidDescription;
        var template = try Template.parse(a, spec.body);
        errdefer template.deinit(a);
        const lang = try std.ascii.allocLowerString(a, spec.language);
        errdefer a.free(lang);
        const trigger = try a.dupe(u8, spec.prefix);
        errdefer a.free(trigger);
        const desc = try a.dupe(u8, description);
        errdefer a.free(desc);
        const group_name = try a.dupe(u8, group);
        errdefer a.free(group_name);
        const notes = try a.dupe(u8, spec.notes);
        errdefer a.free(notes);
        const body = try a.dupe(u8, spec.body);
        errdefer a.free(body);
        // A trigger-less snippet is named by its description behind a `~`,
        // which no trigger can contain, so the two kinds never collide.
        const command = if (trigger.len > 0)
            try std.fmt.allocPrint(a, "snippet.{s}.{s}", .{ lang, trigger })
        else
            try std.fmt.allocPrint(a, "snippet.{s}.~{s}", .{ lang, name_slug });
        return .{ .language = lang, .prefix = trigger, .description = desc, .group = group_name, .notes = notes, .command = command, .template = template, .body = body, .from_extension = from_extension };
    }
    pub fn deinit(self: *Definition, a: Allocator) void {
        a.free(self.language);
        a.free(self.prefix);
        a.free(self.description);
        a.free(self.group);
        a.free(self.notes);
        a.free(self.command);
        a.free(self.body);
        a.free(self.source);
        self.template.deinit(a);
    }
    pub fn matchesLanguage(self: *const Definition, language: ?[]const u8) bool {
        return std.mem.eql(u8, self.language, "*") or
            (language != null and std.ascii.eqlIgnoreCase(self.language, language.?));
    }
    /// Whether Tab can expand it.
    pub fn hasTrigger(self: *const Definition) bool {
        return self.prefix.len > 0;
    }
};

pub const Registry = struct {
    items: std.ArrayList(Definition) = .empty,
    /// Bumped on every registration, replacement and drop: anything that
    /// holds indices into `items` (the Snippets panel) rebuilds on a change.
    revision: u64 = 0,
    pub fn deinit(self: *Registry, a: Allocator) void {
        for (self.items.items) |*def| def.deinit(a);
        self.items.deinit(a);
    }
    pub fn command(self: *const Registry, name: []const u8) ?*const Definition {
        for (self.items.items) |*def| if (std.mem.eql(u8, def.command, name)) return def;
        return null;
    }
};

fn isIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '@' or c >= 0x80;
}

/// Valid UTF-8 with no control bytes: fits one panel row.
fn oneLine(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Valid UTF-8 where a newline is the only control byte (notes wrap and
/// break on it; a tab would need a width the TUI cell can't give it).
fn notesText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if ((c < 0x20 and c != '\n') or c == 0x7f) return false;
    return true;
}

/// The command-name slug of a trigger-less snippet: the description with
/// ASCII lowercased, every run of other ASCII folded to one `-`, no `-` at
/// either end, cut to `max_slug` bytes on a UTF-8 boundary. Non-ASCII
/// bytes pass through, as triggers allow them too. Empty when nothing
/// survives (a description of punctuation only).
pub fn slug(out: *[max_slug]u8, description: []const u8) []const u8 {
    var n: usize = 0;
    var dash_pending = false;
    for (description) |c| {
        const keep = std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
        if (!keep) {
            dash_pending = n > 0;
            continue;
        }
        if (dash_pending and n < max_slug) {
            out[n] = '-';
            n += 1;
        }
        dash_pending = false;
        if (n < max_slug) {
            out[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    if (n == max_slug) {
        // Drop a multi-byte sequence the cap cut in two.
        var lead = n;
        while (lead > 0 and (out[lead - 1] & 0xC0) == 0x80) lead -= 1;
        if (lead > 0 and out[lead - 1] >= 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(out[lead - 1]) catch 1;
            if (lead - 1 + len > n) n = lead - 1;
        }
    }
    while (n > 0 and out[n - 1] == '-') n -= 1;
    return out[0..n];
}

/// A complete identifier ending at the caret, never a prefix inside a word.
pub fn triggerStart(buffer: *const Buffer, caret: usize) ?usize {
    if (caret > buffer.byteLen()) return null;
    if (buffer.byteAt(caret)) |c| if (isIdentifier(c)) return null;
    var start = caret;
    while (start > 0 and isIdentifier(buffer.byteAt(start - 1).?)) start -= 1;
    return if (start == caret) null else start;
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidLanguage => "Snippet language must be a nonempty name or *",
        error.InvalidPrefix => "Snippet prefix must be an identifier",
        error.MissingName => "Snippet needs a prefix or a description",
        error.InvalidDescription => "Snippet description must be one line of valid UTF-8 with a letter or digit in it",
        error.InvalidGroup => "Snippet group must be one line of valid UTF-8",
        error.InvalidNotes => "Snippet notes must be valid UTF-8; newlines are the only control characters allowed",
        error.InvalidUtf8 => "Snippet body must be valid UTF-8",
        error.RepeatedPlaceholder => "Repeated snippet placeholder numbers are unsupported",
        error.NestedPlaceholder => "Nested snippet placeholders are unsupported; escape literal dollars with \\$",
        error.UnsupportedPlaceholder => "Unsupported snippet placeholder: use $1, ${1}, ${1:default}, or $0",
        error.UnclosedPlaceholder => "Unclosed snippet placeholder",
        error.InvalidPlaceholderNumber => "Snippet placeholder number is too large",
        error.CommandConflict => "Snippet command name is already registered by another command",
        error.OutOfMemory => "Snippet failed: out of memory",
        else => "Snippet expansion failed",
    };
}

test "snippets parse defaults, ordering, empty fields, Unicode, escapes and final positions" {
    const a = std.testing.allocator;
    var t = try Template.parse(a, "${3:界} $1 ${2} ${4:a\\}b\\$c\\\\d}$0!");
    defer t.deinit(a);
    try std.testing.expectEqualStrings("界   a}b$c\\d!", t.text);
    try std.testing.expectEqual(@as(u32, 1), t.stops[0].number);
    try std.testing.expectEqual(@as(usize, 4), t.stops[0].start);
    try std.testing.expectEqual(t.stops[0].start, t.stops[0].end);
    try std.testing.expectEqual(t.text.len - 1, t.final.start);
    var plain = try Template.parse(a, "hello");
    defer plain.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), plain.final.start);
    try std.testing.expectEqual(@as(usize, 0), plain.stops.len);
}

test "snippets reject malformed and unsupported syntax" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "$1${1:x}", "$0${0}", "${1", "${1:x", "${1:${2:x}}", "${1|a,b|}", "$NAME", "${VAR}", "${1/x/y/}", "$999999999999", "$" }) |body| {
        if (Template.parse(a, body)) |parsed| {
            var t = parsed;
            t.deinit(a);
            return error.ExpectedInvalidSnippet;
        } else |_| {}
    }
}

test "snippet definitions reject malformed UTF-8 in the language (it names a palette command)" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidLanguage, Definition.init(a, .{ .language = "zi\xffg", .prefix = "fn", .body = "x" }, false));
    try std.testing.expectError(error.InvalidLanguage, Definition.init(a, .{ .language = "\xC3", .prefix = "fn", .body = "x" }, false));
    var ok = try Definition.init(a, .{ .language = "Ünïcode", .prefix = "fn", .body = "x" }, false);
    defer ok.deinit(a);
    try std.testing.expectEqualStrings("snippet.Ünïcode.fn", ok.command);
}

test "snippet definitions default the description to the prefix and the group to Other" {
    const a = std.testing.allocator;
    var def = try Definition.init(a, .{ .language = "Zig", .prefix = "fn", .body = "x" }, true);
    defer def.deinit(a);
    try std.testing.expectEqualStrings("fn", def.description);
    try std.testing.expectEqualStrings(default_group, def.group);
    try std.testing.expectEqualStrings("", def.notes);
    try std.testing.expect(def.hasTrigger() and def.from_extension);
    var full = try Definition.init(a, .{ .language = "zig", .prefix = "fn", .description = "Function", .group = "Functions", .notes = "Line one.\nLine two.", .body = "x" }, false);
    defer full.deinit(a);
    try std.testing.expectEqualStrings("Function", full.description);
    try std.testing.expectEqualStrings("Functions", full.group);
    try std.testing.expectEqualStrings("Line one.\nLine two.", full.notes);
    try std.testing.expectEqualStrings("snippet.zig.fn", full.command);
}

test "snippet definitions without a trigger are named by their description behind a tilde" {
    const a = std.testing.allocator;
    var def = try Definition.init(a, .{ .language = "zig", .description = "Hello, World! (program)", .body = "x" }, false);
    defer def.deinit(a);
    try std.testing.expect(!def.hasTrigger());
    try std.testing.expectEqualStrings("", def.prefix);
    try std.testing.expectEqualStrings("snippet.zig.~hello-world-program", def.command);
    // A single word still can't collide with the trigger of the same name.
    var word = try Definition.init(a, .{ .language = "zig", .description = "Print", .body = "x" }, false);
    defer word.deinit(a);
    try std.testing.expectEqualStrings("snippet.zig.~print", word.command);
    var uni = try Definition.init(a, .{ .language = "zig", .description = "Ünïcode 界", .body = "x" }, false);
    defer uni.deinit(a);
    try std.testing.expectEqualStrings("snippet.zig.~Ünïcode-界", uni.command);
    // Neither a prefix nor a description names it; punctuation alone is no name.
    try std.testing.expectError(error.MissingName, Definition.init(a, .{ .language = "zig", .body = "x" }, false));
    try std.testing.expectError(error.InvalidDescription, Definition.init(a, .{ .language = "zig", .description = "!!!", .body = "x" }, false));
    // The slug stops at 64 bytes on a UTF-8 boundary and never ends in a dash.
    var long: [200]u8 = undefined;
    @memset(&long, 'a');
    var buf: [max_slug]u8 = undefined;
    try std.testing.expectEqual(@as(usize, max_slug), slug(&buf, &long).len);
    const near_cap = "a" ** 63 ++ "界";
    try std.testing.expectEqualStrings("a" ** 63, slug(&buf, near_cap));
    try std.testing.expectEqualStrings("a-b", slug(&buf, "--a---b--"));
}

test "snippet definitions refuse text the panel cannot draw" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidDescription, Definition.init(a, .{ .language = "zig", .prefix = "fn", .description = "two\nlines", .body = "x" }, false));
    try std.testing.expectError(error.InvalidDescription, Definition.init(a, .{ .language = "zig", .prefix = "fn", .description = "bad\xff", .body = "x" }, false));
    try std.testing.expectError(error.InvalidGroup, Definition.init(a, .{ .language = "zig", .prefix = "fn", .group = "tab\there", .body = "x" }, false));
    try std.testing.expectError(error.InvalidNotes, Definition.init(a, .{ .language = "zig", .prefix = "fn", .notes = "tab\there", .body = "x" }, false));
    try std.testing.expectError(error.InvalidNotes, Definition.init(a, .{ .language = "zig", .prefix = "fn", .notes = "bad\xff", .body = "x" }, false));
    try std.testing.expectError(error.InvalidPrefix, Definition.init(a, .{ .language = "zig", .prefix = "1st", .body = "x" }, false));
}

test "snippets expansion maps indentation, CRLF, and literal spaces" {
    const a = std.testing.allocator;
    var t = try Template.parse(a, "fn ${1:名}() {\n\t $0\n}");
    defer t.deinit(a);
    var e = try t.expand(a, "\t", false, 2, "\r\n");
    defer e.deinit(a);
    try std.testing.expectEqualStrings("fn 名() {\r\n\t   \r\n\t}", e.text);
    try std.testing.expectEqualStrings("名", e.text[e.session.stops[0].start..e.session.stops[0].end]);
    try std.testing.expectEqualStrings("\r\n\t}", e.text[e.session.final.start..]);
    var tabs = try t.expand(a, "  ", true, 8, "\n");
    defer tabs.deinit(a);
    try std.testing.expectEqualStrings("fn 名() {\n  \t \n  }", tabs.text);
}

test "snippets adjacent stops have stable insertion affinity" {
    const a = std.testing.allocator;
    var t = try Template.parse(a, "$2$1$0$3");
    defer t.deinit(a);
    var e = try t.expand(a, "", false, 4, "\n");
    defer e.deinit(a);
    try std.testing.expect(e.session.edit(0, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), e.session.stops[1].start);
    try std.testing.expectEqual(@as(usize, 3), e.session.stops[0].end);
    try std.testing.expectEqual(@as(usize, 3), e.session.stops[2].start);
    try std.testing.expectEqual(@as(usize, 3), e.session.final.start);
    try std.testing.expect(!e.session.edit(0, 4, 0));
}
