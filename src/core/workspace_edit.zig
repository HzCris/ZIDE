//! Validated, in-memory multi-document edits shared by LSP operations.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const identity = @import("file_identity.zig");
const text_file = @import("text_file.zig");
const lsp = @import("lsp.zig");

pub const Encoding = enum { utf8, utf16 };
pub const TextEdit = struct { range: lsp.LspRange, newText: []const u8 };

pub fn offset(doc: *Document, position: lsp.LspPosition, encoding: Encoding) !usize {
    if (position.line >= doc.buffer.lineCount()) return error.InvalidRange;
    const line = doc.buffer.lineContent(position.line);
    const col = switch (encoding) {
        .utf16 => try lsp.checkedUtf16ColToByte(line, position.character),
        .utf8 => blk: {
            const col = position.character;
            if (col > line.len or (col < line.len and line[col] & 0xc0 == 0x80)) return error.InvalidRange;
            break :blk col;
        },
    };
    return doc.buffer.line_starts.items[position.line] + col;
}

pub fn positionAt(doc: *Document, byte: usize, encoding: Encoding) lsp.LspPosition {
    const pos = doc.buffer.offsetToPos(byte);
    return .{ .line = @intCast(pos.line), .character = if (encoding == .utf16) lsp.byteColToUtf16(doc.buffer.lineContent(pos.line), pos.col) else @intCast(pos.col) };
}

pub const File = struct {
    path: []u8,
    key: []u8,
    id: ?u64,
    version: u64,
    stamp: ?text_file.Stamp,
    opened: ?Document = null,
    ranges: std.ArrayList(Document.RangeEdit) = .empty,
    prepared: ?Document.PreparedEdit = null,

    fn deinit(self: *File, allocator: Allocator) void {
        if (self.prepared) |*prepared| prepared.deinit();
        if (self.opened) |*doc| doc.deinit();
        for (self.ranges.items) |range| allocator.free(range.text);
        self.ranges.deinit(allocator);
        allocator.free(self.path);
        allocator.free(self.key);
    }
};

pub const Plan = struct {
    allocator: Allocator,
    files: std.ArrayList(File) = .empty,
    edit_count: usize = 0,

    pub fn deinit(self: *Plan) void {
        for (self.files.items) |*file| file.deinit(self.allocator);
        self.files.deinit(self.allocator);
    }

    /// Parse text operations only. No source file is written by this service.
    pub fn parse(editor: anytype, value: std.json.Value, encoding: Encoding) !Plan {
        if (value != .object) return error.InvalidWorkspaceEdit;
        var plan: Plan = .{ .allocator = editor.allocator };
        errdefer plan.deinit();
        if (value.object.get("changes")) |changes| {
            if (changes != .object or value.object.contains("documentChanges")) return error.InvalidWorkspaceEdit;
            var files = changes.object.iterator();
            while (files.next()) |file| try plan.add(editor, file.key_ptr.*, null, file.value_ptr.*, encoding);
        }
        if (value.object.get("documentChanges")) |changes| {
            if (changes != .array) return error.InvalidWorkspaceEdit;
            for (changes.array.items) |change| {
                if (change != .object) return error.InvalidWorkspaceEdit;
                if (change.object.contains("kind")) return error.ResourceOperationUnsupported;
                const doc = change.object.get("textDocument") orelse return error.InvalidWorkspaceEdit;
                if (doc != .object) return error.InvalidWorkspaceEdit;
                const uri = doc.object.get("uri") orelse return error.InvalidWorkspaceEdit;
                if (uri != .string) return error.InvalidWorkspaceEdit;
                const version_value = doc.object.get("version") orelse return error.InvalidWorkspaceEdit;
                const version: ?i32 = switch (version_value) {
                    .null => null,
                    .integer => |n| std.math.cast(i32, n) orelse return error.InvalidVersion,
                    else => return error.InvalidVersion,
                };
                try plan.add(editor, uri.string, version, change.object.get("edits") orelse return error.InvalidWorkspaceEdit, encoding);
            }
        }
        return plan;
    }

    fn add(self: *Plan, editor: anytype, uri: []const u8, required_version: ?i32, value: std.json.Value, encoding: Encoding) !void {
        if (value != .array) return error.InvalidWorkspaceEdit;
        if (value.array.items.len == 0) return;
        if (self.files.items.len >= 1024 or self.edit_count + value.array.items.len > 100_000) return error.EditTooLarge;
        const decoded = try lsp.uriToPath(self.allocator, uri);
        defer self.allocator.free(decoded);
        const path = try identity.absolute(self.allocator, editor.io, decoded);
        var file: File = .{ .path = path, .key = undefined, .id = null, .version = 0, .stamp = null };
        file.key = identity.key(self.allocator, editor.io, path) catch |err| {
            self.allocator.free(path);
            return err;
        };
        errdefer file.deinit(self.allocator);
        // Reject duplicate aliases rather than applying ambiguous overlapping batches.
        for (self.files.items) |existing| if (identity.equalKeys(existing.key, file.key)) return error.DuplicateDocument;
        const doc = if (try editor.findDocument(path)) |index| blk: {
            const open = &editor.documents.items[index];
            if (required_version) |version| if (version != open.lsp_version) return error.StaleDocument;
            if (open.readonly or open.preview or open.edit_depth != 0) return error.DocumentBusy;
            file.id = open.id;
            break :blk open;
        } else blk: {
            if (required_version != null) return error.StaleDocument;
            file.opened = try Document.init(self.allocator);
            try file.opened.?.openWithEncoding(editor.io, path, editor.knownEncoding(path));
            file.opened.?.history.max_size = editor.max_undo_history;
            break :blk &file.opened.?;
        };
        file.version = doc.buffer.version;
        file.stamp = doc.disk_stamp;
        for (value.array.items) |item| {
            const parsed = try std.json.parseFromValue(TextEdit, self.allocator, item, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const edit = parsed.value;
            try text_file.validate(edit.newText);
            const start = try offset(doc, edit.range.start, encoding);
            const end = try offset(doc, edit.range.end, encoding);
            if (start > end) return error.InvalidRange;
            if (start == end and edit.newText.len == 0) continue;
            const text = try self.allocator.dupe(u8, edit.newText);
            errdefer self.allocator.free(text);
            try file.ranges.append(self.allocator, .{ .start = start, .end = end, .text = text });
        }
        std.mem.sort(Document.RangeEdit, file.ranges.items, {}, struct {
            fn less(_: void, a: Document.RangeEdit, b: Document.RangeEdit) bool {
                return a.start > b.start;
            }
        }.less);
        for (file.ranges.items, 0..) |range, i| if (i > 0) {
            const previous = file.ranges.items[i - 1];
            if (range.end > previous.start or range.start == previous.start) return error.OverlappingEdits;
        };
        try self.files.append(self.allocator, file);
        self.edit_count += file.ranges.items.len;
    }

    /// Recheck everything after the preview, then reserve every transaction before commit.
    pub fn apply(self: *Plan, editor: anytype) !void {
        var new_count: usize = 0;
        for (self.files.items) |file| {
            if (file.id) |id| {
                const index = editor.docIndexForId(id) orelse return error.DocumentClosed;
                const doc = &editor.documents.items[index];
                if (doc.buffer.version != file.version or doc.edit_depth != 0 or doc.readonly or
                    doc.file_path == null or !editor.pathsEqual(doc.file_path.?, file.path)) return error.StaleDocument;
            } else {
                if ((try editor.findDocument(file.path)) != null or !std.meta.eql(file.stamp, try text_file.Stamp.read(editor.io, file.path))) return error.StaleDocument;
                new_count += 1;
            }
        }
        try editor.documents.ensureUnusedCapacity(self.allocator, new_count);
        try editor.activeWindow().tabs.ensureUnusedCapacity(self.allocator, new_count);
        // Failures here change capacity only, leaving contents, cursors and history intact.
        errdefer for (self.files.items) |*file| if (file.prepared) |*prepared| {
            prepared.deinit();
            file.prepared = null;
        };
        for (self.files.items) |*file| {
            const doc = if (file.id) |id| &editor.documents.items[editor.docIndexForId(id).?] else &file.opened.?;
            file.prepared = try doc.prepareRanges(file.ranges.items);
        }
        // No callbacks, I/O, or allocations between the first and last content mutation.
        for (self.files.items) |*file| {
            const doc = if (file.id) |id| &editor.documents.items[editor.docIndexForId(id).?] else &file.opened.?;
            file.prepared.?.commit(doc, true);
            file.prepared.?.deinit();
            file.prepared = null;
            doc.detectLineEndings();
            if (file.opened) |opened| {
                const index = editor.documents.items.len;
                editor.documents.appendAssumeCapacity(opened);
                editor.activeWindow().tabs.appendAssumeCapacity(index);
                file.opened = null;
                file.id = opened.id;
            }
        }
        for (self.files.items) |file| {
            const doc = &editor.documents.items[editor.docIndexForId(file.id.?).?];
            doc.detectLanguage(editor);
            editor.resolveFormatting(doc);
        }
    }
};
