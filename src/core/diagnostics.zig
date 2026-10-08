//! Workspace diagnostics survive closed tabs and remain isolated by producer.
const std = @import("std");
const lsp = @import("lsp.zig");
const identity = @import("file_identity.zig");
const Document = @import("document.zig").Document;
pub const Kind = enum { lsp, lua, task };
pub const Columns = enum { bytes, utf16 };
pub const Entry = struct {
    path: []u8,
    producer: []u8,
    kind: Kind,
    version: ?i32,
    columns: Columns,
    diagnostic: lsp.Diagnostic,
    task_doc_id: ?u64 = null,
    task_buffer_version: ?u64 = null,
    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.producer);
        self.diagnostic.deinit(allocator);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(Entry) = .empty,
    revision: u64 = 0,

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn replace(self: *Store, path: []const u8, producer: []const u8, kind: Kind, version: ?i32, columns: Columns, diagnostics: []const lsp.Diagnostic) !void {
        if (diagnostics.len > 10_000) return error.TooManyDiagnostics;
        const key = try identity.key(self.allocator, self.io, path);
        defer self.allocator.free(key);
        var replacing: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.kind != kind or !std.mem.eql(u8, entry.producer, producer) or !identity.equalKeys(entry.path, key)) continue;
            replacing += 1;
            if (version) |incoming| if (entry.version) |existing| if (incoming < existing) return;
        }
        if (self.entries.items.len - replacing + diagnostics.len > 50_000) return error.TooManyDiagnostics;
        var prepared: std.ArrayList(Entry) = .empty;
        defer prepared.deinit(self.allocator);
        errdefer for (prepared.items) |entry| entry.deinit(self.allocator);
        try prepared.ensureTotalCapacity(self.allocator, diagnostics.len);
        for (diagnostics) |diagnostic| {
            const p = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(p);
            const source = try self.allocator.dupe(u8, producer);
            errdefer self.allocator.free(source);
            var copy = diagnostic;
            copy.message = try self.allocator.dupe(u8, diagnostic.message);
            prepared.appendAssumeCapacity(.{ .path = p, .producer = source, .kind = kind, .version = version, .columns = columns, .diagnostic = copy });
        }
        try self.entries.ensureUnusedCapacity(self.allocator, prepared.items.len);
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (entry.kind == kind and std.mem.eql(u8, entry.producer, producer) and identity.equalKeys(entry.path, key)) {
                entry.deinit(self.allocator);
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
        self.entries.appendSliceAssumeCapacity(prepared.items);
        self.revision +%= 1;
    }

    pub fn clear(self: *Store, kind: Kind, producer: ?[]const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (entry.kind == kind and (producer == null or std.mem.eql(u8, producer.?, entry.producer))) {
                entry.deinit(self.allocator);
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
        self.revision +%= 1;
    }

    /// Drop the versioned LSP entries for `path` when its document stops
    /// being open there (close, rename, re-language). Their versions belong
    /// to that document instance: a reopened document restarts `lsp_version`
    /// at 0, and `replace` would drop the server's fresh publishes until the
    /// new version passed the old one. Unversioned (workspace) entries stay.
    pub fn forgetVersioned(self: *Store, path: []const u8) void {
        // A path without a key never got entries (replace keys every path).
        const key = identity.key(self.allocator, self.io, path) catch return;
        defer self.allocator.free(key);
        var removed = false;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (entry.kind == .lsp and entry.version != null and identity.equalKeys(entry.path, key)) {
                entry.deinit(self.allocator);
                _ = self.entries.orderedRemove(i);
                removed = true;
            } else i += 1;
        }
        if (removed) self.revision +%= 1;
    }

    /// Convert protocol columns only after a document's text is available.
    /// Quick-open previews never show diagnostics.
    pub fn project(self: *Store, doc: *Document, kind: Kind) !void {
        if (doc.preview) return;
        const path = doc.file_path orelse return;
        const key = try identity.key(self.allocator, self.io, path);
        defer self.allocator.free(key);
        var prepared: std.ArrayList(lsp.Diagnostic) = .empty;
        errdefer {
            for (prepared.items) |diagnostic| diagnostic.deinit(doc.allocator);
            prepared.deinit(doc.allocator);
        }
        for (self.entries.items) |entry| {
            if ((entry.kind == .lsp) != (kind == .lsp) or !identity.equalKeys(entry.path, key)) continue;
            if (entry.version) |version| if (version != doc.lsp_version) continue;
            var diagnostic = entry.diagnostic;
            if (entry.columns == .utf16) {
                diagnostic.start_col = @intCast(lsp.utf16ColToByte(doc.buffer.lineContent(diagnostic.start_line), diagnostic.start_col));
                diagnostic.end_col = @intCast(lsp.utf16ColToByte(doc.buffer.lineContent(diagnostic.end_line), diagnostic.end_col));
            }
            diagnostic.message = try doc.allocator.dupe(u8, diagnostic.message);
            prepared.append(doc.allocator, diagnostic) catch |err| {
                diagnostic.deinit(doc.allocator);
                return err;
            };
        }
        const target = if (kind == .lsp) &doc.diagnostics else &doc.lint_diagnostics;
        for (target.items) |diagnostic| diagnostic.deinit(doc.allocator);
        target.deinit(doc.allocator);
        target.* = prepared;
    }
};

test "diagnostics preserve other producers and annotate a later-opened file" {
    const t = std.testing;
    var store: Store = .{ .allocator = t.allocator, .io = t.io };
    defer store.deinit();
    const diagnostic: lsp.Diagnostic = .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 1, .severity = .err, .message = "problem" };
    try store.replace("later.txt", "server", .lsp, null, .utf16, &.{diagnostic});
    try store.replace("later.txt", "linter", .lua, null, .bytes, &.{diagnostic});
    try store.replace("later.txt", "build", .task, null, .bytes, &.{diagnostic});
    try store.replace("later.txt", "linter", .lua, null, .bytes, &.{});
    try t.expectEqual(@as(usize, 2), store.entries.items.len);
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.setFilePath("later.txt");
    try doc.loadText("abc");
    try store.project(&doc, .lsp);
    try store.project(&doc, .task);
    try t.expectEqual(@as(usize, 1), doc.diagnostics.items.len);
    try t.expectEqual(@as(usize, 1), doc.lint_diagnostics.items.len);

    // A quick-open preview of the same file gets none.
    var peek = try Document.init(t.allocator);
    defer peek.deinit();
    try peek.setFilePath("later.txt");
    try peek.loadText("abc");
    peek.preview = true;
    try store.project(&peek, .lsp);
    try store.project(&peek, .task);
    try t.expectEqual(@as(usize, 0), peek.diagnostics.items.len + peek.lint_diagnostics.items.len);
}

test "closing a document forgets its versioned LSP diagnostics" {
    const t = std.testing;
    var store: Store = .{ .allocator = t.allocator, .io = t.io };
    defer store.deinit();
    const diagnostic: lsp.Diagnostic = .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 1, .severity = .err, .message = "problem" };
    try store.replace("reopened.txt", "server", .lsp, 57, .utf16, &.{diagnostic});
    try store.replace("reopened.txt", "workspace", .lsp, null, .utf16, &.{diagnostic});
    try store.replace("reopened.txt", "linter", .lua, null, .bytes, &.{diagnostic});
    try store.replace("other.txt", "server", .lsp, 57, .utf16, &.{diagnostic});
    // Without the close, a reopened document's version 1 loses to 57.
    try store.replace("reopened.txt", "server", .lsp, 1, .utf16, &.{});
    try t.expectEqual(@as(usize, 4), store.entries.items.len);
    store.forgetVersioned("reopened.txt");
    try t.expectEqual(@as(usize, 3), store.entries.items.len);
    for (store.entries.items) |entry| try t.expect(entry.version == null or std.mem.endsWith(u8, entry.path, "other.txt"));
    try store.replace("reopened.txt", "server", .lsp, 1, .utf16, &.{diagnostic});
    var doc = try Document.init(t.allocator);
    defer doc.deinit();
    try doc.setFilePath("reopened.txt");
    try doc.loadText("abc");
    doc.lsp_version = 1;
    try store.project(&doc, .lsp);
    try t.expectEqual(@as(usize, 2), doc.diagnostics.items.len);
}
