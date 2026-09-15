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

    /// Convert protocol columns only after a document's text is available.
    pub fn project(self: *Store, doc: *Document, kind: Kind) !void {
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
}
