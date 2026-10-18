//! The "Save as snippet" form (also Edit and Copy): its fields as fixed,
//! NUL-terminated buffers that the GUI's text entries edit in place and the
//! TUI edits through text_input, plus the body — the selection prepared for
//! a template. Both frontends draw it; the Editor owns one (`snippet_form`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const text_input = @import("text_input.zig");
const snippets = @import("snippets.zig");

pub const Field = enum { name, folder, trigger, language, notes, body };
pub const Kind = enum { save, edit, copy };
/// Bytes of body the form holds (the selection is refused beyond it).
pub const max_body = 8192;
/// The folder a snippet goes to when the field is left empty.
pub const default_folder = "Mine";

/// A field's buffer and its length (the bytes before the first NUL).
pub const Slot = struct { buf: []u8, len: *usize };

pub const State = struct {
    kind: Kind = .save,
    field: Field = .name,
    name: [128]u8 = @splat(0),
    name_len: usize = 0,
    folder: [64]u8 = @splat(0),
    folder_len: usize = 0,
    trigger: [64]u8 = @splat(0),
    trigger_len: usize = 0,
    language: [64]u8 = @splat(0),
    language_len: usize = 0,
    notes: [512]u8 = @splat(0),
    notes_len: usize = 0,
    body: [max_body]u8 = @splat(0),
    body_len: usize = 0,
    /// Edit: the command of the definition being edited (owned); null for
    /// a save or a copy.
    editing: ?[]u8 = null,
    /// GUI: the EditorWindow.id the dialog is pinned to (settings_window_id's twin).
    window_id: u32 = 0,
    /// The folder of the last save, prefilled next time (kept across resets).
    last_folder: [64]u8 = @splat(0),
    last_folder_len: usize = 0,
    /// A validation or write failure shown inside the form; "" when none.
    error_message: []const u8 = "",
    error_buf: [160]u8 = undefined,

    pub const fields = [_]Field{ .name, .folder, .trigger, .language, .notes, .body };

    /// A formatted failure message that lives as long as the form.
    pub fn fail(self: *State, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(&self.error_buf, fmt, args) catch fmt;
    }

    pub fn slot(self: *State, field: Field) Slot {
        return switch (field) {
            .name => .{ .buf = &self.name, .len = &self.name_len },
            .folder => .{ .buf = &self.folder, .len = &self.folder_len },
            .trigger => .{ .buf = &self.trigger, .len = &self.trigger_len },
            .language => .{ .buf = &self.language, .len = &self.language_len },
            .notes => .{ .buf = &self.notes, .len = &self.notes_len },
            .body => .{ .buf = &self.body, .len = &self.body_len },
        };
    }

    pub fn text(self: *const State, field: Field) []const u8 {
        return switch (field) {
            .name => self.name[0..self.name_len],
            .folder => self.folder[0..self.folder_len],
            .trigger => self.trigger[0..self.trigger_len],
            .language => self.language[0..self.language_len],
            .notes => self.notes[0..self.notes_len],
            .body => self.body[0..self.body_len],
        };
    }

    /// Set a field: the body raw (its newlines kept), cut at a character
    /// boundary; the others through text_input (control characters
    /// dropped, so the notes keep `\n` only through `setRaw`). The tail is
    /// zero-filled so a dvui entry finds the end.
    pub fn set(self: *State, field: Field, value: []const u8) void {
        if (field == .body) return self.setRaw(field, value);
        const s = self.slot(field);
        s.len.* = 0;
        text_input.append(s.buf[0 .. s.buf.len - 1], s.len, value);
        @memset(s.buf[s.len.*..], 0);
    }

    /// Set a field byte for byte (valid UTF-8 expected), keeping one NUL.
    pub fn setRaw(self: *State, field: Field, value: []const u8) void {
        const s = self.slot(field);
        const n = text_input.floor(value, @min(value.len, s.buf.len - 1));
        @memcpy(s.buf[0..n], value[0..n]);
        s.len.* = n;
        @memset(s.buf[n..], 0);
    }

    /// Type into the active field (the TUI): one line, no control characters.
    pub fn append(self: *State, value: []const u8) void {
        const s = self.slot(self.field);
        text_input.append(s.buf[0 .. s.buf.len - 1], s.len, value);
        @memset(s.buf[s.len.*..], 0);
    }

    pub fn backspace(self: *State) void {
        const s = self.slot(self.field);
        text_input.backspace(s.buf, s.len);
        @memset(s.buf[s.len.*..], 0);
    }

    /// The GUI's entries edited the buffers in place: lengths from the
    /// first NUL.
    pub fn syncLens(self: *State) void {
        for (fields) |f| {
            const s = self.slot(f);
            s.len.* = std.mem.indexOfScalar(u8, s.buf, 0) orelse s.buf.len;
        }
    }

    /// What the fields describe: the name is the description, the folder
    /// the group (`default_folder` when empty), the trigger the prefix.
    pub fn spec(self: *const State) snippets.Spec {
        const folder = self.text(.folder);
        return .{
            .language = self.text(.language),
            .body = self.text(.body),
            .prefix = self.text(.trigger),
            .description = self.text(.name),
            .group = if (folder.len > 0) folder else default_folder,
            .notes = self.text(.notes),
        };
    }

    /// Tab / Shift+Tab: the next or previous field, wrapping around. The
    /// TUI cannot edit the body and skips it.
    pub fn cycle(self: *State, forward: bool, include_body: bool) void {
        const last: Field = if (include_body) .body else .notes;
        const n: usize = @intFromEnum(last) + 1;
        const cur: usize = @min(@intFromEnum(self.field), n - 1);
        self.field = @enumFromInt(if (forward) (cur + 1) % n else (cur + n - 1) % n);
    }

    pub fn lastFolder(self: *const State) []const u8 {
        return if (self.last_folder_len > 0) self.last_folder[0..self.last_folder_len] else default_folder;
    }

    pub fn rememberFolder(self: *State, folder: []const u8) void {
        self.last_folder_len = 0;
        text_input.append(&self.last_folder, &self.last_folder_len, folder);
    }

    /// Clear every field and the edit target; the remembered folder stays.
    pub fn reset(self: *State, a: Allocator) void {
        if (self.editing) |e| a.free(e);
        self.editing = null;
        self.error_message = "";
        self.kind = .save;
        self.field = .name;
        for (fields) |f| self.setRaw(f, "");
    }

    pub fn deinit(self: *State, a: Allocator) void {
        if (self.editing) |e| a.free(e);
        self.editing = null;
    }
};

/// The registry's refusal in the form's own words (Name, Folder, Trigger,
/// Language, Notes); anything else as snippets.errorMessage says it.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingName => "Give the snippet a name (or a trigger)",
        error.InvalidDescription => "The name must be one line with a letter or digit in it",
        error.InvalidPrefix => "The trigger may use letters, digits, _ or non-ASCII, and must not start with a digit",
        error.InvalidGroup => "The folder must be one line",
        error.InvalidLanguage => "Language: a name without spaces, or * for every file",
        error.InvalidNotes => "Notes may contain line breaks but no other control characters",
        else => snippets.errorMessage(err),
    };
}

/// The selection as a snippet body: CRLF becomes LF, the indentation every
/// line shares is removed (a first line that starts flush left — the
/// selection began mid-line — is left out of that measure), and trailing
/// line breaks go.
pub fn prepareBody(a: Allocator, selection: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    var i: usize = 0;
    while (i < selection.len) : (i += 1) {
        if (selection[i] == '\r' and i + 1 < selection.len and selection[i + 1] == '\n') continue;
        try text.append(a, selection[i]);
    }
    while (text.items.len > 0 and text.items[text.items.len - 1] == '\n') _ = text.pop();

    // The indentation shared by the lines that have any content.
    var common: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    var first = true;
    while (lines.next()) |line| {
        defer first = false;
        const ws = leadingBlank(line);
        if (ws.len == line.len) continue; // blank line
        if (first and ws.len == 0) continue; // began mid-line
        common = if (common) |c| c[0..commonPrefixLen(c, ws)] else ws;
    }
    const strip = if (common) |c| c else "";
    if (strip.len == 0) return text.toOwnedSlice(a);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var rest = std.mem.splitScalar(u8, text.items, '\n');
    var first_out = true;
    while (rest.next()) |line| {
        if (!first_out) try out.append(a, '\n');
        first_out = false;
        const ws = leadingBlank(line);
        const cut = if (ws.len == line.len) line.len else @min(strip.len, commonPrefixLen(line, strip));
        try out.appendSlice(a, line[cut..]);
    }
    text.deinit(a);
    return out.toOwnedSlice(a);
}

fn leadingBlank(line: []const u8) []const u8 {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return line[0..n];
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    var n: usize = 0;
    while (n < a.len and n < b.len and a[n] == b[n]) n += 1;
    return n;
}

// ---- Tests ----

const t = std.testing;

test "snippet form body: CRLF becomes LF, shared indentation goes, trailing line breaks go" {
    const flush = try prepareBody(t.allocator, "    for (items) |item| {\r\n        use(item);\r\n    }\r\n\r\n");
    defer t.allocator.free(flush);
    try t.expectEqualStrings("for (items) |item| {\n    use(item);\n}", flush);
    // A selection that began mid-line: the first line has no say.
    const mid = try prepareBody(t.allocator, "foo();\n    bar();\n    baz();");
    defer t.allocator.free(mid);
    try t.expectEqualStrings("foo();\nbar();\nbaz();", mid);
    // Blank lines inside keep nothing to strip; tabs count like spaces.
    const tabs = try prepareBody(t.allocator, "\t\tx\n\n\t\t\ty\n");
    defer t.allocator.free(tabs);
    try t.expectEqualStrings("x\n\n\ty", tabs);
    const one = try prepareBody(t.allocator, "  single  ");
    defer t.allocator.free(one);
    try t.expectEqualStrings("single  ", one);
}

test "snippet form: fields set, type and backspace, cycle, and the spec defaults the folder to Mine" {
    var form: State = .{};
    defer form.deinit(t.allocator);
    form.set(.name, "Print\tline");
    try t.expectEqualStrings("Printline", form.text(.name));
    try t.expectEqual(@as(u8, 0), form.name[form.name_len]);
    form.setRaw(.body, "a\n\tb");
    try t.expectEqualStrings("a\n\tb", form.text(.body));
    form.field = .folder;
    form.append("Mi");
    form.append("ne!");
    form.backspace();
    try t.expectEqualStrings("Mine", form.text(.folder));
    // The GUI wrote straight into a buffer: the length catches up.
    @memcpy(form.trigger[0..3], "pri");
    form.syncLens();
    try t.expectEqualStrings("pri", form.text(.trigger));
    // Tab order with and without the body; wrapping both ways.
    form.field = .notes;
    form.cycle(true, false);
    try t.expectEqual(Field.name, form.field);
    form.cycle(false, false);
    try t.expectEqual(Field.notes, form.field);
    form.cycle(true, true);
    try t.expectEqual(Field.body, form.field);
    form.cycle(true, true);
    try t.expectEqual(Field.name, form.field);
    // The spec: empty folder → Mine; the trigger is the prefix.
    form.set(.folder, "");
    form.set(.language, "zig");
    const spec = form.spec();
    try t.expectEqualStrings("Mine", spec.group);
    try t.expectEqualStrings("pri", spec.prefix);
    try t.expectEqualStrings("Printline", spec.description);
    try t.expectEqualStrings("a\n\tb", spec.body);
    // A long body is cut at a character boundary, never mid-character.
    const long = "é" ** (max_body / 2);
    form.setRaw(.body, long);
    try t.expect(form.body_len < max_body);
    try t.expect(std.unicode.utf8ValidateSlice(form.text(.body)));
    // Reset keeps the remembered folder only.
    form.rememberFolder("Loops");
    form.editing = try t.allocator.dupe(u8, "snippet.zig.~x");
    form.reset(t.allocator);
    try t.expectEqualStrings("", form.text(.name));
    try t.expectEqualStrings("", form.text(.body));
    try t.expect(form.editing == null);
    try t.expectEqualStrings("Loops", form.lastFolder());
    try t.expectEqual(Field.name, form.field);
}
