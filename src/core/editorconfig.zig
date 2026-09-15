//! Project formatting rules. Disk settings are cached and checked by the editor's idle deadlines.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text_file = @import("text_file.zig");
pub const Eol = enum { lf, crlf };
pub const Properties = struct {
    use_tabs: ?bool = null,
    indent_size: ?u16 = null,
    indent_is_tab: bool = false,
    tab_width: ?u16 = null,
    eol: ?Eol = null,
    trim: ?bool = null,
    final_newline: ?bool = null,

    fn apply(self: *Properties, key: []const u8, value: []const u8) void {
        const unset = eq(value, "unset");
        if (eq(key, "indent_style")) {
            if (unset) self.use_tabs = null else if (eq(value, "tab")) self.use_tabs = true else if (eq(value, "space")) self.use_tabs = false;
        } else if (eq(key, "indent_size")) {
            if (unset) {
                self.indent_size = null;
                self.indent_is_tab = false;
            } else if (eq(value, "tab")) {
                self.indent_size = null;
                self.indent_is_tab = true;
            } else if (width(value)) |n| {
                self.indent_size = n;
                self.indent_is_tab = false;
            }
        } else if (eq(key, "tab_width")) {
            if (unset) self.tab_width = null else if (width(value)) |n| self.tab_width = n;
        } else if (eq(key, "end_of_line")) {
            if (unset) self.eol = null else if (eq(value, "lf")) self.eol = .lf else if (eq(value, "crlf")) self.eol = .crlf;
        } else if (eq(key, "trim_trailing_whitespace")) {
            if (unset) self.trim = null else if (boolean(value)) |b| self.trim = b;
        } else if (eq(key, "insert_final_newline")) {
            if (unset) self.final_newline = null else if (boolean(value)) |b| self.final_newline = b;
        }
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn width(value: []const u8) ?u16 {
    const n = std.fmt.parseInt(u16, value, 10) catch return null;
    return if (n > 0 and n <= 256) n else null;
}
fn boolean(value: []const u8) ?bool {
    if (eq(value, "true")) return true;
    if (eq(value, "false")) return false;
    return null;
}

const Continuation = struct { pattern: []const u8, next: ?*const Continuation };
fn cpLen(text: []const u8) usize {
    if (text.len == 0) return 0;
    return @min(text.len, std.unicode.utf8ByteSequenceLength(text[0]) catch 1);
}

fn closeBracket(pattern: []const u8) ?usize {
    var i: usize = 1;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1;
            continue;
        }
        if (pattern[i] == ']') return i;
    }
    return null;
}

fn hasSeparator(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '[') if (closeBracket(pattern[i..])) |end| {
            i += end;
            continue;
        };
        if (pattern[i] == '/') return true;
        if (pattern[i] == '\\' and i + 1 < pattern.len) i += 1;
    }
    return false;
}

pub fn matchesSection(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0 or pattern.len > 1024) return false;
    if (hasSeparator(pattern)) return glob(if (pattern[0] == '/') pattern[1..] else pattern, path);
    if (glob(pattern, path)) return true;
    for (path, 0..) |c, i| if (c == '/' and glob(pattern, path[i + 1 ..])) return true;
    return false;
}

/// Recursive glob matcher with a work bound, including nested alternatives
/// and numeric ranges without expanding a potentially enormous range.
pub fn glob(pattern: []const u8, path: []const u8) bool {
    var budget: usize = 200_000;
    return match(pattern, path, null, &budget);
}

fn match(pattern: []const u8, path: []const u8, next: ?*const Continuation, budget: *usize) bool {
    if (budget.* == 0) return false;
    budget.* -= 1;
    if (pattern.len == 0) return if (next) |tail| match(tail.pattern, path, tail.next, budget) else path.len == 0;
    switch (pattern[0]) {
        '*' => {
            var count: usize = 1;
            while (count < pattern.len and pattern[count] == '*') : (count += 1) {}
            const cross = count > 1;
            if (cross and count < pattern.len and pattern[count] == '/' and match(pattern[count + 1 ..], path, next, budget)) return true;
            var offset: usize = 0;
            while (true) {
                if (match(pattern[count..], path[offset..], next, budget)) return true;
                if (offset == path.len or (!cross and path[offset] == '/')) return false;
                offset += cpLen(path[offset..]);
            }
        },
        '?' => return path.len != 0 and path[0] != '/' and match(pattern[1..], path[cpLen(path)..], next, budget),
        '\\' => return pattern.len > 1 and path.len > 0 and pattern[1] == path[0] and match(pattern[2..], path[1..], next, budget),
        '[' => {
            if (closeBracket(pattern)) |end| {
                if (path.len == 0) return false;
                const negate = end > 1 and pattern[1] == '!';
                const chars = pattern[if (negate) @as(usize, 2) else 1..end];
                const n = cpLen(path);
                var contained = false;
                var i: usize = 0;
                while (i < chars.len) {
                    if (chars[i] == '\\' and i + 1 < chars.len) i += 1;
                    const len = cpLen(chars[i..]);
                    if (std.mem.eql(u8, chars[i..][0..len], path[0..n])) contained = true;
                    i += len;
                }
                return contained != negate and match(pattern[end + 1 ..], path[n..], next, budget);
            }
        },
        '{' => {
            var depth: usize = 1;
            var end: usize = 1;
            while (end < pattern.len) : (end += 1) {
                if (pattern[end] == '[') if (closeBracket(pattern[end..])) |close| {
                    end += close;
                    continue;
                };
                if (pattern[end] == '\\' and end + 1 < pattern.len) {
                    end += 1;
                    continue;
                }
                if (pattern[end] == '{') depth += 1;
                if (pattern[end] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (end < pattern.len) {
                const inside = pattern[1..end];
                const tail: Continuation = .{ .pattern = pattern[end + 1 ..], .next = next };
                if (std.mem.indexOf(u8, inside, "..")) |dots| {
                    const low = std.fmt.parseInt(i64, inside[0..dots], 10) catch null;
                    const high = std.fmt.parseInt(i64, inside[dots + 2 ..], 10) catch null;
                    if (low != null and high != null and low.? < high.?) {
                        var n: usize = if (path.len > 0 and path[0] == '-') 1 else 0;
                        const digits = n;
                        while (n < path.len and std.ascii.isDigit(path[n])) {
                            n += 1;
                            if (n - digits > 1 and path[digits] == '0') break;
                            const number = std.fmt.parseInt(i64, path[0..n], 10) catch continue;
                            if (number >= low.? and number <= high.? and match("", path[n..], &tail, budget)) return true;
                        }
                        return false;
                    }
                }
                var start: usize = 0;
                var alternatives = false;
                depth = 0;
                var i: usize = 0;
                while (i < inside.len) : (i += 1) {
                    if (inside[i] == '[') if (closeBracket(inside[i..])) |close| {
                        i += close;
                        continue;
                    };
                    if (inside[i] == '\\' and i + 1 < inside.len) {
                        i += 1;
                        continue;
                    }
                    if (inside[i] == '{') depth += 1;
                    if (inside[i] == '}') depth -|= 1;
                    if (inside[i] == ',' and depth == 0) {
                        alternatives = true;
                        if (match(inside[start..i], path, &tail, budget)) return true;
                        start = i + 1;
                    }
                }
                if (alternatives) return match(inside[start..], path, &tail, budget);
            }
        },
        else => {},
    }
    return path.len > 0 and pattern[0] == path[0] and match(pattern[1..], path[1..], next, budget);
}

fn isRoot(bytes: []const u8) bool {
    var result = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') break;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (eq(std.mem.trim(u8, line[0..equal], " \t"), "root")) result = eq(std.mem.trim(u8, line[equal + 1 ..], " \t"), "true");
    }
    return result;
}

pub const Pairs = struct {
    bytes: []const u8,
    path: []const u8,
    active: bool = false,
    pub fn next(self: *Pairs) ?struct { key: []const u8, value: []const u8 } {
        while (self.bytes.len > 0) {
            const end = std.mem.indexOfScalar(u8, self.bytes, '\n') orelse self.bytes.len;
            const line = std.mem.trim(u8, self.bytes[0..end], " \t\r");
            self.bytes = self.bytes[@min(end + 1, self.bytes.len)..];
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            if (line[0] == '[' and line[line.len - 1] == ']') {
                self.active = matchesSection(line[1 .. line.len - 1], self.path);
                continue;
            }
            if (!self.active) continue;
            const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            return .{ .key = std.mem.trim(u8, line[0..equal], " \t"), .value = std.mem.trim(u8, line[equal + 1 ..], " \t") };
        }
        return null;
    }
};

pub fn applyFile(properties: *Properties, bytes: []const u8, relative_path: []const u8) void {
    var pairs: Pairs = .{ .bytes = bytes, .path = relative_path };
    while (pairs.next()) |pair| properties.apply(pair.key, pair.value);
}

const File = struct { bytes: []u8, stamp: ?text_file.Stamp };
pub const Cache = struct {
    allocator: Allocator,
    io: std.Io,
    files: std.StringHashMapUnmanaged(File) = .empty,

    pub fn deinit(self: *Cache) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.bytes);
        }
        self.files.deinit(self.allocator);
    }

    fn read(self: *Cache, path: []const u8) !File {
        const stamp = try text_file.Stamp.read(self.io, path);
        const bytes = if (stamp != null) try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) else try self.allocator.dupe(u8, "");
        return .{ .bytes = bytes, .stamp = stamp };
    }

    fn get(self: *Cache, path: []const u8) ![]const u8 {
        if (self.files.get(path)) |file| return file.bytes;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const file = try self.read(path);
        errdefer self.allocator.free(file.bytes);
        try self.files.put(self.allocator, owned_path, file);
        return file.bytes;
    }

    pub fn refresh(self: *Cache) !bool {
        var changed = false;
        var it = self.files.iterator();
        while (it.next()) |entry| {
            const stamp = try text_file.Stamp.read(self.io, entry.key_ptr.*);
            if (!std.meta.eql(stamp, entry.value_ptr.stamp)) {
                const replacement = try self.read(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.bytes);
                entry.value_ptr.* = replacement;
                changed = true;
            }
        }
        return changed;
    }

    pub fn resolve(self: *Cache, path: []const u8) !Properties {
        const full = try @import("file_identity.zig").absolute(self.allocator, self.io, path);
        defer self.allocator.free(full);
        var chain: std.ArrayList(struct { dir: []const u8, bytes: []const u8 }) = .empty;
        defer chain.deinit(self.allocator);
        var dir = std.fs.path.dirname(full) orelse return .{};
        while (true) {
            const config = try std.fs.path.join(self.allocator, &.{ dir, ".editorconfig" });
            defer self.allocator.free(config);
            const bytes = try self.get(config);
            try chain.append(self.allocator, .{ .dir = dir, .bytes = bytes });
            if (isRoot(bytes)) break;
            const parent = std.fs.path.dirname(dir) orelse break;
            if (parent.len == dir.len) break;
            dir = parent;
        }
        var result: Properties = .{};
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const item = chain.items[i];
            const start = item.dir.len + @as(usize, if (std.fs.path.isSep(item.dir[item.dir.len - 1])) 0 else 1);
            const relative = try self.allocator.dupe(u8, full[start..]);
            defer self.allocator.free(relative);
            if (@import("builtin").os.tag == .windows) for (relative) |*c| {
                if (c.* == '\\') c.* = '/';
            };
            applyFile(&result, item.bytes, relative);
        }
        return result;
    }
};

/// Produce normalized text; callers apply per-line suffix edits to retain cursors.
pub fn normalize(allocator: Allocator, text: []const u8, properties: Properties, crlf: bool) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var offset: usize = 0;
    while (offset < text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, offset, '\n');
        const end = newline orelse text.len;
        var content_end = end;
        const had_cr = newline != null and end > offset and text[end - 1] == '\r';
        if (had_cr) content_end -= 1;
        if (properties.trim orelse false) while (content_end > offset and (text[content_end - 1] == ' ' or text[content_end - 1] == '\t')) {
            content_end -= 1;
        };
        try output.appendSlice(allocator, text[offset..content_end]);
        if (newline != null) try output.appendSlice(allocator, if ((properties.eol orelse (if (had_cr) Eol.crlf else Eol.lf)) == .crlf) "\r\n" else "\n");
        offset = if (newline != null) end + 1 else end;
    }
    if (properties.final_newline) |insert| {
        if (insert) {
            if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.appendSlice(allocator, if ((properties.eol orelse (if (crlf) Eol.crlf else Eol.lf)) == .crlf) "\r\n" else "\n");
        } else while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
            output.items.len -= 1;
            if (output.items.len > 0 and output.items[output.items.len - 1] == '\r') output.items.len -= 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

test "EditorConfig matching, precedence, unset, and whitespace properties" {
    const t = std.testing;
    try t.expect(glob("**/*.{zig,{h,hpp}}", "src/test.hpp"));
    try t.expect(glob("**/*.zig", "main.zig"));
    try t.expect(glob("part{-2..4}.zig", "part-1.zig"));
    try t.expect(!glob("*.zig", "src/main.zig"));
    try t.expect(glob("[!ab]?.zig", "cé.zig"));
    var props: Properties = .{};
    applyFile(&props, "root=true\n[*]\nindent_style=space\nindent_size=4\n[*.zig]\nindent_size=2\ntrim_trailing_whitespace=true\nend_of_line=lf\ninsert_final_newline=true\n", "src/main.zig");
    try t.expectEqual(@as(?u16, 2), props.indent_size);
    const text = try normalize(t.allocator, "one \r\ntwo\t", props, true);
    defer t.allocator.free(text);
    try t.expectEqualStrings("one\ntwo\n", text);
    applyFile(&props, "[*]\nindent_size=unset\n", "main.zig");
    try t.expectEqual(@as(?u16, null), props.indent_size);
    const empty = try normalize(t.allocator, "", props, false);
    defer t.allocator.free(empty);
    try t.expectEqualStrings("", empty);
}

test "EditorConfig upstream core glob fixtures with explicit 0.17.2 bracket updates" {
    const t = std.testing;
    const Case = struct { name: []const u8, fixture: []const u8, path: []const u8, expected: std.json.Value };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, "tests/editorconfig/cases.json", t.allocator, .limited(1024 * 1024));
    defer t.allocator.free(bytes);
    const cases = try std.json.parseFromSlice([]Case, t.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer cases.deinit();
    var failures: usize = 0;
    for (cases.value) |case| {
        const path = try std.fs.path.join(t.allocator, &.{ "tests", "editorconfig", case.fixture });
        defer t.allocator.free(path);
        const config = try std.Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(1024 * 1024));
        defer t.allocator.free(config);
        var actual: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer actual.deinit(t.allocator);
        var pairs: Pairs = .{ .bytes = config, .path = case.path };
        while (pairs.next()) |pair| try actual.put(t.allocator, pair.key, pair.value);
        var ok = actual.count() == case.expected.object.count();
        var expected = case.expected.object.iterator();
        while (expected.next()) |pair| if (!std.mem.eql(u8, actual.get(pair.key_ptr.*) orelse "", pair.value_ptr.string)) {
            ok = false;
        };
        if (!ok) {
            std.debug.print("EditorConfig fixture failed: {s} ({s})\n", .{ case.name, case.path });
            failures += 1;
        }
    }
    try t.expectEqual(@as(usize, 0), failures);
}
