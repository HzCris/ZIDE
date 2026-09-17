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

pub const Definition = struct {
    language: []u8,
    prefix: []u8,
    description: []u8,
    command: []u8,
    template: Template,
    from_extension: bool,

    pub fn init(a: Allocator, language: []const u8, prefix: []const u8, description: []const u8, body: []const u8, from_extension: bool) !Definition {
        if (language.len == 0 or std.mem.indexOfAny(u8, language, " \t\r\n\x00") != null) return error.InvalidLanguage;
        if (prefix.len == 0 or std.ascii.isDigit(prefix[0]) or !std.unicode.utf8ValidateSlice(prefix)) return error.InvalidPrefix;
        for (prefix) |c| if (!isIdentifier(c) or c == '@') return error.InvalidPrefix;
        var template = try Template.parse(a, body);
        errdefer template.deinit(a);
        const lang = try std.ascii.allocLowerString(a, language);
        errdefer a.free(lang);
        const trigger = try a.dupe(u8, prefix);
        errdefer a.free(trigger);
        const desc = try a.dupe(u8, description);
        errdefer a.free(desc);
        return .{ .language = lang, .prefix = trigger, .description = desc, .command = try std.fmt.allocPrint(a, "snippet.{s}.{s}", .{ lang, trigger }), .template = template, .from_extension = from_extension };
    }
    pub fn deinit(self: *Definition, a: Allocator) void {
        a.free(self.language);
        a.free(self.prefix);
        a.free(self.description);
        a.free(self.command);
        self.template.deinit(a);
    }
    pub fn matchesLanguage(self: *const Definition, language: ?[]const u8) bool {
        return std.mem.eql(u8, self.language, "*") or
            (language != null and std.ascii.eqlIgnoreCase(self.language, language.?));
    }
};

pub const Registry = struct {
    items: std.ArrayList(Definition) = .empty,
    pub fn deinit(self: *Registry, a: Allocator) void {
        for (self.items.items) |*def| def.deinit(a);
        self.items.deinit(a);
    }
    pub fn find(self: *const Registry, language: ?[]const u8, prefix: []const u8) ?*const Definition {
        var global: ?*const Definition = null;
        for (self.items.items) |*def| {
            if (!std.mem.eql(u8, def.prefix, prefix)) continue;
            if (std.mem.eql(u8, def.language, "*")) global = def else if (def.matchesLanguage(language)) return def;
        }
        return global;
    }
    pub fn command(self: *const Registry, name: []const u8) ?*const Definition {
        for (self.items.items) |*def| if (std.mem.eql(u8, def.command, name)) return def;
        return null;
    }
};

fn isIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '@' or c >= 0x80;
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
