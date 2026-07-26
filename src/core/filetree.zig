const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Frontend-agnostic file tree model for the side panel.
///
/// Owns the directory scan, expansion state, selection, and file
/// operations. Both frontends render the same flattened `visible` list —
/// the GUI as dvui rows, the TUI as terminal rows — so expansion state
/// lives in exactly one place.
///
/// Nodes are stored in a flat ArrayList and referenced by u32 index:
/// ArrayList growth relocates the Node structs, so `*Node` pointers would
/// dangle, but indices stay valid (the list is append-only between
/// rebuilds). Node 0 is always the root; it is excluded from `visible`
/// (frontends draw a fixed header from `root_path` instead), so its
/// children render at depth 1 and indentation uses `depth - 1`.
pub const NodeKind = enum { file, dir };

/// Git working-tree status for tree-row coloring. Order matters: when one
/// path somehow gets two records, the lower (stronger) value wins.
pub const GitStatus = enum { untracked, added, deleted, modified };

pub const Node = struct {
    /// Path relative to the tree root, '/'-normalized, owned. "" = root.
    rel_path: []u8,
    /// Basename — a slice into `rel_path` (the heap data never moves,
    /// only the Node struct does, so this stays valid across growth).
    name: []const u8,
    /// Parent node index (root points at itself).
    parent: u32,
    /// Child node indices (dirs only; empty until `loaded`).
    children: std.ArrayList(u32) = .empty,
    kind: NodeKind,
    /// Root = 0, root's children = 1, ...
    depth: u16,
    expanded: bool = false,
    /// Whether children have been scanned (dirs load lazily on expand).
    loaded: bool = false,
    /// Directory mtime at scan time (dirs only) — compared by
    /// checkExternalChanges to spot files created outside ZIDE.
    scanned_mtime_ns: i96 = 0,
};

pub const FileTree = struct {
    allocator: Allocator,
    io: std.Io,
    /// Canonical absolute root path (display + absolute joins). Owned.
    root_path: []u8,
    /// Root directory handle, opened iterable.
    root_dir: std.Io.Dir,
    /// False when the handle is borrowed (test seam) — deinit won't close it.
    owns_root_dir: bool,
    nodes: std.ArrayList(Node) = .empty,
    /// Flattened DFS of expanded nodes (root excluded). What frontends draw.
    visible: std.ArrayList(u32) = .empty,
    /// Selected row (index into `visible`).
    selected: usize = 0,
    /// Set by reveal/create so frontends scroll the selection into view.
    scroll_to_selected: bool = false,
    /// Git status per rel_path (owned keys). Empty when not a git repo.
    git_map: std.StringHashMapUnmanaged(GitStatus) = .empty,
    /// Dirs with any changed descendant (owned keys) — rendered as modified.
    git_dirty_dirs: std.StringHashMapUnmanaged(void) = .empty,
    /// Row coloring by git status (editor mirrors `filetree_git_colors`
    /// onto this; off = gitRefresh never shells out).
    git_enabled: bool = true,
    /// Multi-select: node indices of the selected set. When non-empty it
    /// IS the effective selection (and includes the primary); empty means
    /// the primary `selected` row alone. Node indices die on refresh —
    /// cleared there (clearNodes).
    multi: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Range-selection anchor as a node index (resolved to a row lazily,
    /// so expand/collapse between shifts can't invalidate it).
    sel_anchor_node: ?u32 = null,
    /// The root itself is the operation target (create/paste/move dest).
    /// Set by clicking the empty space below the rows — the root has no
    /// row of its own to select. Cleared by any row selection.
    root_selected: bool = false,

    /// Open `root_path` (relative to cwd or absolute) and build the tree.
    pub fn init(allocator: Allocator, io: std.Io, root_path: []const u8) !FileTree {
        const opts: std.Io.Dir.OpenOptions = .{ .iterate = true };
        const dir = if (std.fs.path.isAbsolute(root_path))
            try std.Io.Dir.openDirAbsolute(io, root_path, opts)
        else
            try std.Io.Dir.cwd().openDir(io, root_path, opts);
        errdefer dir.close(io);
        return initFromDirInner(allocator, io, dir, root_path, true);
    }

    /// Build a tree over an already-opened iterable directory handle.
    /// The tree does NOT close the handle (test seam for tmpDir, whose
    /// cleanup() closes it itself).
    pub fn initFromDir(allocator: Allocator, io: std.Io, dir: std.Io.Dir, display_path: []const u8) !FileTree {
        return initFromDirInner(allocator, io, dir, display_path, false);
    }

    fn initFromDirInner(allocator: Allocator, io: std.Io, dir: std.Io.Dir, display_path: []const u8, owns: bool) !FileTree {
        // Canonicalize for display and absolute-path joins; fall back to
        // the caller's spelling where realpath is unsupported.
        const root_path = blk: {
            const rp = std.Io.Dir.realPathFileAlloc(dir, io, ".", allocator) catch
                break :blk try allocator.dupe(u8, display_path);
            defer allocator.free(rp);
            break :blk try allocator.dupe(u8, rp);
        };
        errdefer allocator.free(root_path);

        var self = FileTree{
            .allocator = allocator,
            .io = io,
            .root_path = root_path,
            .root_dir = dir,
            .owns_root_dir = owns,
        };
        errdefer {
            self.clearNodes();
            self.nodes.deinit(allocator);
            self.visible.deinit(allocator);
        }
        try self.initRoot();
        try self.rebuildVisible();
        return self;
    }

    pub fn deinit(self: *FileTree) void {
        self.clearNodes();
        self.nodes.deinit(self.allocator);
        self.visible.deinit(self.allocator);
        self.multi.deinit(self.allocator);
        self.clearGitMaps();
        self.git_map.deinit(self.allocator);
        self.git_dirty_dirs.deinit(self.allocator);
        self.allocator.free(self.root_path);
        if (self.owns_root_dir) self.root_dir.close(self.io);
    }

    fn clearNodes(self: *FileTree) void {
        for (self.nodes.items) |*n| {
            self.allocator.free(n.rel_path);
            n.children.deinit(self.allocator);
        }
        self.nodes.clearRetainingCapacity();
        self.visible.clearRetainingCapacity();
        self.multi.clearRetainingCapacity();
        self.sel_anchor_node = null;
    }

    fn initRoot(self: *FileTree) !void {
        const root_rel = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(root_rel);
        try self.nodes.append(self.allocator, .{
            .rel_path = root_rel,
            .name = root_rel[0..0],
            .parent = 0,
            .kind = .dir,
            .depth = 0,
        });
        try self.loadChildren(0);
        self.nodes.items[0].expanded = true;
    }

    /// Scan a directory node's entries into child nodes (sorted dirs-first,
    /// then case-insensitive). Everything is shown, dotfiles included —
    /// hiding `.git` while listing `.zig-cache` just looked inconsistent.
    fn loadChildren(self: *FileTree, idx: u32) !void {
        std.debug.assert(self.nodes.items[idx].kind == .dir);
        if (self.nodes.items[idx].loaded) return;
        // Copy the slice value before appending — the heap data behind
        // rel_path never moves even when the Node structs do.
        const rel = self.nodes.items[idx].rel_path;
        const depth = self.nodes.items[idx].depth;

        var sub: ?std.Io.Dir = null;
        defer if (sub) |d| d.close(self.io);
        const dir = if (rel.len == 0) self.root_dir else blk: {
            sub = try self.root_dir.openDir(self.io, rel, .{ .iterate = true });
            break :blk sub.?;
        };

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const kind: NodeKind = if (entry.kind == .directory) .dir else .file;
            // entry.name is invalidated by the next iteration — dupe now.
            const child_rel = if (rel.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.mem.concat(self.allocator, u8, &.{ rel, "/", entry.name });
            errdefer self.allocator.free(child_rel);
            const child_idx: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{
                .rel_path = child_rel,
                .name = child_rel[child_rel.len - entry.name.len ..],
                .parent = idx,
                .kind = kind,
                .depth = depth + 1,
            });
            try self.nodes.items[idx].children.append(self.allocator, child_idx);
        }
        self.sortChildren(idx);
        self.nodes.items[idx].loaded = true;
        self.nodes.items[idx].scanned_mtime_ns = self.dirMtimeNs(rel) orelse 0;
    }

    fn dirMtimeNs(self: *const FileTree, rel: []const u8) ?i96 {
        const sub = if (rel.len == 0) "." else rel;
        const st = self.root_dir.statFile(self.io, sub, .{}) catch return null;
        return st.mtime.nanoseconds;
    }

    /// Cheap external-change probe: a directory's mtime changes when its
    /// direct children are added/removed/renamed, so comparing the visible
    /// (loaded, expanded) dirs against the mtime stamped at scan time
    /// catches files created outside ZIDE — a few stats, no git spawn.
    /// Frontends poll this on a timer and only refresh when it fires.
    pub fn checkExternalChanges(self: *const FileTree) bool {
        for (self.nodes.items) |n| {
            if (n.kind != .dir or !n.loaded) continue;
            if (n.rel_path.len != 0 and !n.expanded) continue;
            const now_mtime = self.dirMtimeNs(n.rel_path) orelse return true; // vanished
            if (now_mtime != n.scanned_mtime_ns) return true;
        }
        return false;
    }

    fn sortChildren(self: *FileTree, idx: u32) void {
        const Ctx = struct {
            nodes: []const Node,
            fn lessThan(c: @This(), a: u32, b: u32) bool {
                const na = c.nodes[a];
                const nb = c.nodes[b];
                if (na.kind != nb.kind) return na.kind == .dir;
                return std.ascii.lessThanIgnoreCase(na.name, nb.name);
            }
        };
        std.mem.sort(u32, self.nodes.items[idx].children.items, Ctx{ .nodes = self.nodes.items }, Ctx.lessThan);
    }

    /// Rebuild the flattened visible-row list from expansion state.
    pub fn rebuildVisible(self: *FileTree) !void {
        self.visible.clearRetainingCapacity();
        try self.appendVisible(0);
        self.clampSelection();
    }

    fn appendVisible(self: *FileTree, idx: u32) !void {
        if (idx != 0) try self.visible.append(self.allocator, idx);
        const node = self.nodes.items[idx];
        if (node.kind == .dir and node.expanded) {
            for (node.children.items) |c| try self.appendVisible(c);
        }
    }

    fn clampSelection(self: *FileTree) void {
        if (self.visible.items.len == 0) {
            self.selected = 0;
        } else if (self.selected >= self.visible.items.len) {
            self.selected = self.visible.items.len - 1;
        }
    }

    /// Node index of the selected row, or null when the tree is empty.
    pub fn selectedNodeIdx(self: *const FileTree) ?u32 {
        if (self.visible.items.len == 0) return null;
        return self.visible.items[@min(self.selected, self.visible.items.len - 1)];
    }

    /// Visible row of a node, or null if collapsed out of view.
    pub fn rowOf(self: *const FileTree, idx: u32) ?usize {
        for (self.visible.items, 0..) |v, i| {
            if (v == idx) return i;
        }
        return null;
    }

    pub fn moveSelection(self: *FileTree, delta: isize) void {
        if (self.visible.items.len == 0) return;
        self.root_selected = false;
        const cur: isize = @intCast(@min(self.selected, self.visible.items.len - 1));
        const max: isize = @intCast(self.visible.items.len - 1);
        self.selected = @intCast(@max(0, @min(cur + delta, max)));
    }

    /// Directory node that receives create/paste/move-target operations:
    /// the explicit root target (empty-space click), the selected dir,
    /// or a selected file's parent.
    pub fn opTargetDir(self: *const FileTree) u32 {
        if (self.root_selected) return 0;
        const sel = self.selectedNodeIdx() orelse return 0;
        const node = self.nodes.items[sel];
        return if (node.kind == .dir) sel else node.parent;
    }

    /// Drop any multi-selection (plain click/nav semantics).
    pub fn clearMulti(self: *FileTree) void {
        self.multi.clearRetainingCapacity();
        self.sel_anchor_node = null;
    }

    pub fn isMultiSelected(self: *const FileTree, idx: u32) bool {
        return self.multi.contains(idx);
    }

    /// Number of effectively selected entries (the multi set, else the
    /// primary selection alone).
    pub fn selectionCount(self: *const FileTree) usize {
        if (self.multi.count() > 0) return self.multi.count();
        return if (self.selectedNodeIdx() != null) 1 else 0;
    }

    /// Ctrl+click: toggle `row`'s membership in the multi set. Seeds the
    /// set with the current primary so the first toggle accumulates, and
    /// collapses back to a plain selection at or below one member.
    pub fn toggleMultiAt(self: *FileTree, row: usize) !void {
        if (row >= self.visible.items.len) return;
        self.root_selected = false;
        if (self.multi.count() == 0) {
            if (self.selectedNodeIdx()) |prim| try self.multi.put(self.allocator, prim, {});
        }
        const idx = self.visible.items[row];
        if (self.multi.contains(idx)) {
            _ = self.multi.remove(idx);
        } else {
            try self.multi.put(self.allocator, idx, {});
            self.selected = row;
        }
        if (self.selectedNodeIdx()) |prim| self.sel_anchor_node = prim;
        if (self.multi.count() <= 1) {
            if (self.multi.count() == 1) {
                var it = self.multi.keyIterator();
                if (self.rowOf(it.next().?.*)) |only_row| self.selected = only_row;
            }
            self.clearMulti();
        }
    }

    /// Shift+click / Shift+arrows: replace the multi set with the visible
    /// range between the anchor (the last plain/ctrl selection) and `row`.
    pub fn selectRangeTo(self: *FileTree, row: usize) !void {
        if (self.visible.items.len == 0) return;
        self.root_selected = false;
        const r = @min(row, self.visible.items.len - 1);
        const fallback = @min(self.selected, self.visible.items.len - 1);
        const anchor_row = blk: {
            const an = self.sel_anchor_node orelse break :blk fallback;
            break :blk self.rowOf(an) orelse fallback;
        };
        if (self.sel_anchor_node == null) self.sel_anchor_node = self.visible.items[anchor_row];
        self.multi.clearRetainingCapacity();
        const lo = @min(anchor_row, r);
        const hi = @max(anchor_row, r);
        var i = lo;
        while (i <= hi) : (i += 1) {
            try self.multi.put(self.allocator, self.visible.items[i], {});
        }
        self.selected = r;
        // A single-row range is a plain selection (the anchor survives
        // for the next shift).
        if (self.multi.count() <= 1) self.multi.clearRetainingCapacity();
    }

    /// Rel paths of the effective selection, minus entries whose ancestor
    /// is also selected — a bulk delete/move on the ancestor already
    /// covers them (and the child op would then fail). Sorted; caller
    /// owns the slice and its strings.
    pub fn selectionRelPaths(self: *const FileTree, allocator: Allocator) ![][]u8 {
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |p| allocator.free(p);
            list.deinit(allocator);
        }
        if (self.multi.count() > 0) {
            var it = self.multi.keyIterator();
            while (it.next()) |k| {
                const rp = self.nodes.items[k.*].rel_path;
                if (rp.len == 0) continue;
                try list.append(allocator, try allocator.dupe(u8, rp));
            }
        } else if (self.selectedNodeIdx()) |idx| {
            if (idx != 0) try list.append(allocator, try allocator.dupe(u8, self.nodes.items[idx].rel_path));
        }
        var i: usize = 0;
        while (i < list.items.len) {
            var covered = false;
            for (list.items) |q| {
                const p = list.items[i];
                if (q.ptr == p.ptr) continue;
                if (p.len > q.len and std.mem.startsWith(u8, p, q) and p[q.len] == '/') {
                    covered = true;
                    break;
                }
            }
            if (covered) {
                allocator.free(list.items[i]);
                _ = list.swapRemove(i);
            } else {
                i += 1;
            }
        }
        std.mem.sort([]u8, list.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return try list.toOwnedSlice(allocator);
    }

    fn expandNoRebuild(self: *FileTree, idx: u32) !void {
        if (self.nodes.items[idx].kind != .dir) return;
        if (!self.nodes.items[idx].loaded) try self.loadChildren(idx);
        self.nodes.items[idx].expanded = true;
    }

    pub fn expand(self: *FileTree, idx: u32) !void {
        try self.expandNoRebuild(idx);
        try self.rebuildVisible();
    }

    pub fn collapse(self: *FileTree, idx: u32) !void {
        if (self.nodes.items[idx].kind != .dir) return;
        self.nodes.items[idx].expanded = false;
        try self.rebuildVisible();
    }

    pub fn toggle(self: *FileTree, idx: u32) !void {
        if (self.nodes.items[idx].kind != .dir) return;
        if (self.nodes.items[idx].expanded) {
            try self.collapse(idx);
        } else {
            try self.expand(idx);
        }
    }

    /// Collapse every directory (the root stays expanded so top-level
    /// entries remain visible) and reset the selection to the first row.
    pub fn collapseAll(self: *FileTree) !void {
        for (self.nodes.items[1..]) |*n| {
            if (n.kind == .dir) n.expanded = false;
        }
        try self.rebuildVisible();
        self.selected = 0;
        self.scroll_to_selected = true;
    }

    /// Find a loaded node by '/'-normalized rel path (no lazy loading).
    pub fn findByPath(self: *const FileTree, rel: []const u8) ?u32 {
        if (rel.len == 0) return 0;
        var cur: u32 = 0;
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            var found: ?u32 = null;
            for (self.nodes.items[cur].children.items) |c| {
                if (std.mem.eql(u8, self.nodes.items[c].name, seg)) {
                    found = c;
                    break;
                }
            }
            cur = found orelse return null;
        }
        return cur;
    }

    /// Expand all ancestors of `rel` (lazy-loading as needed), select it,
    /// and flag the selection for scroll-into-view. Returns the node index,
    /// or null if any segment doesn't exist.
    pub fn expandToPath(self: *FileTree, rel: []const u8) !?u32 {
        if (rel.len == 0) return 0;
        var cur: u32 = 0;
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (self.nodes.items[cur].kind != .dir) return null;
            try self.expandNoRebuild(cur);
            var found: ?u32 = null;
            for (self.nodes.items[cur].children.items) |c| {
                if (std.mem.eql(u8, self.nodes.items[c].name, seg)) {
                    found = c;
                    break;
                }
            }
            cur = found orelse {
                try self.rebuildVisible();
                return null;
            };
        }
        try self.rebuildVisible();
        if (self.rowOf(cur)) |row| {
            self.selected = row;
            self.scroll_to_selected = true;
            self.root_selected = false;
        }
        return cur;
    }

    /// Rescan from the root, preserving expansion and selection by path
    /// (indices are meaningless across a rebuild).
    pub fn refresh(self: *FileTree) !void {
        var expanded_paths: std.ArrayList([]u8) = .empty;
        defer {
            for (expanded_paths.items) |p| self.allocator.free(p);
            expanded_paths.deinit(self.allocator);
        }
        for (self.nodes.items) |n| {
            if (n.kind == .dir and n.expanded and n.rel_path.len > 0) {
                try expanded_paths.append(self.allocator, try self.allocator.dupe(u8, n.rel_path));
            }
        }
        const sel_path: ?[]u8 = if (self.selectedNodeIdx()) |si|
            try self.allocator.dupe(u8, self.nodes.items[si].rel_path)
        else
            null;
        defer if (sel_path) |p| self.allocator.free(p);

        self.clearNodes();
        try self.initRoot();
        // Shorter paths first so parents re-expand (and lazy-load) before
        // their children are looked up.
        std.mem.sort([]u8, expanded_paths.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return a.len < b.len;
            }
        }.lessThan);
        for (expanded_paths.items) |p| {
            if (self.findByPath(p)) |idx| {
                self.expandNoRebuild(idx) catch {};
            }
        }
        try self.rebuildVisible();
        self.selected = 0;
        if (sel_path) |p| {
            if (self.findByPath(p)) |idx| {
                if (self.rowOf(idx)) |row| self.selected = row;
            }
        }
        self.clampSelection();
    }

    /// Create a file or directory under `parent_idx` from prompt input.
    /// A trailing '/' (or '\') creates a directory; embedded separators
    /// create intermediate directories. Returns the created entry's
    /// rel_path, owned by `allocator`, without trailing separator.
    pub fn createEntry(self: *FileTree, allocator: Allocator, parent_idx: u32, input: []const u8) ![]u8 {
        if (input.len == 0) return error.InvalidName;
        if (std.mem.indexOf(u8, input, "..") != null) return error.InvalidName;
        if (input[0] == '/' or input[0] == '\\') return error.InvalidName;
        const is_dir = input[input.len - 1] == '/' or input[input.len - 1] == '\\';
        const trimmed = std.mem.trimEnd(u8, input, "/\\");
        if (trimmed.len == 0) return error.InvalidName;

        const parent_rel = self.nodes.items[parent_idx].rel_path;
        const rel = if (parent_rel.len == 0)
            try allocator.dupe(u8, trimmed)
        else
            try std.mem.concat(allocator, u8, &.{ parent_rel, "/", trimmed });
        errdefer allocator.free(rel);
        normalizeSeps(rel);

        if (is_dir) {
            try self.root_dir.createDirPath(self.io, rel);
        } else {
            if (std.mem.lastIndexOfScalar(u8, rel, '/')) |sep| {
                try self.root_dir.createDirPath(self.io, rel[0..sep]);
            }
            const f = try self.root_dir.createFile(self.io, rel, .{ .exclusive = true });
            f.close(self.io);
        }
        return rel;
    }

    /// Rename node `idx` to `new_name` (basename only — no separators).
    /// Refuses to clobber an existing entry (error.PathAlreadyExists).
    /// Returns the new rel_path, owned by `allocator`.
    pub fn renameEntry(self: *FileTree, allocator: Allocator, idx: u32, new_name: []const u8) ![]u8 {
        if (idx == 0) return error.InvalidName;
        if (new_name.len == 0) return error.InvalidName;
        if (std.mem.indexOfAny(u8, new_name, "/\\") != null) return error.InvalidName;
        if (std.mem.indexOf(u8, new_name, "..") != null) return error.InvalidName;
        const node = self.nodes.items[idx];
        const dir_part = node.rel_path[0 .. node.rel_path.len - node.name.len];
        const new_rel = try std.mem.concat(allocator, u8, &.{ dir_part, new_name });
        errdefer allocator.free(new_rel);
        try std.Io.Dir.renamePreserve(self.root_dir, node.rel_path, self.root_dir, new_rel, self.io);
        return new_rel;
    }

    /// Move node `idx` into directory `dest_dir_idx`, keeping its name.
    /// Rejects non-dir targets, the entry itself, its current parent
    /// (no-op), and any destination inside the moved entry; refuses to
    /// clobber (error.PathAlreadyExists, consistent with rename).
    /// Returns the new rel_path, owned by `allocator`.
    pub fn moveEntry(self: *FileTree, allocator: Allocator, idx: u32, dest_dir_idx: u32) ![]u8 {
        if (idx == 0) return error.InvalidMove;
        if (dest_dir_idx == idx) return error.InvalidMove;
        return self.moveRelTo(allocator, self.nodes.items[idx].rel_path, dest_dir_idx);
    }

    /// Path-based move core — also used by file-clipboard paste, whose
    /// sources may no longer be loaded in the tree (collapsed away).
    pub fn moveRelTo(self: *FileTree, allocator: Allocator, src_rel: []const u8, dest_dir_idx: u32) ![]u8 {
        if (src_rel.len == 0) return error.InvalidMove;
        const dest = self.nodes.items[dest_dir_idx];
        if (dest.kind != .dir) return error.InvalidMove;
        if (std.mem.eql(u8, dest.rel_path, src_rel)) return error.InvalidMove; // into itself
        const base = std.fs.path.basenamePosix(src_rel);
        const parent_len = src_rel.len - base.len;
        const src_parent = if (parent_len == 0) "" else src_rel[0 .. parent_len - 1];
        if (std.mem.eql(u8, src_parent, dest.rel_path)) return error.InvalidMove; // already there
        // Destination inside the moved entry — '/'-boundary check so
        // "src2" doesn't false-match a "src" prefix.
        if (dest.rel_path.len > src_rel.len and
            std.mem.startsWith(u8, dest.rel_path, src_rel) and
            dest.rel_path[src_rel.len] == '/')
        {
            return error.InvalidMove;
        }
        const new_rel = if (dest.rel_path.len == 0)
            try allocator.dupe(u8, base)
        else
            try std.mem.concat(allocator, u8, &.{ dest.rel_path, "/", base });
        errdefer allocator.free(new_rel);
        try std.Io.Dir.renamePreserve(self.root_dir, src_rel, self.root_dir, new_rel, self.io);
        return new_rel;
    }

    /// Delete node `idx` from disk (directories recursively).
    pub fn deleteEntry(self: *FileTree, idx: u32) !void {
        if (idx == 0) return error.InvalidName;
        const node = self.nodes.items[idx];
        switch (node.kind) {
            .file => try self.root_dir.deleteFile(self.io, node.rel_path),
            .dir => try self.root_dir.deleteTree(self.io, node.rel_path),
        }
    }

    /// Recursive copy driver: copy `src_path` (a path relative to
    /// `src_dir`) to `dest_rel` under the tree root. Symlinks are
    /// skipped — following them could walk outside the source.
    fn copyIntoRoot(self: *FileTree, src_dir: std.Io.Dir, src_path: []const u8, dest_rel: []const u8) !void {
        const st = try src_dir.statFile(self.io, src_path, .{});
        if (st.kind == .directory) {
            try self.root_dir.createDirPath(self.io, dest_rel);
            var sub = try src_dir.openDir(self.io, src_path, .{ .iterate = true });
            defer sub.close(self.io);
            var it = sub.iterate();
            while (try it.next(self.io)) |entry| {
                if (entry.kind == .sym_link) continue;
                // entry.name is invalidated by the next iteration — dupe
                // before recursing.
                const child_name = try self.allocator.dupe(u8, entry.name);
                defer self.allocator.free(child_name);
                const child_dest = try std.mem.concat(self.allocator, u8, &.{ dest_rel, "/", child_name });
                defer self.allocator.free(child_dest);
                try self.copyIntoRoot(sub, child_name, child_dest);
            }
        } else {
            try std.Io.Dir.copyFile(src_dir, src_path, self.root_dir, dest_rel, self.io, .{});
        }
    }

    /// Recursively copy `src_rel` into directory node `dest_dir_idx`,
    /// keeping its basename. No-clobber (error.PathAlreadyExists) —
    /// which also covers pasting into the source's own parent. Returns
    /// the new rel_path, owned by `allocator`.
    pub fn copyEntryTo(self: *FileTree, allocator: Allocator, src_rel: []const u8, dest_dir_idx: u32) ![]u8 {
        if (src_rel.len == 0) return error.InvalidCopy;
        const dest = self.nodes.items[dest_dir_idx];
        if (dest.kind != .dir) return error.InvalidCopy;
        // Copying a dir into its own subtree would recurse forever.
        if (std.mem.eql(u8, dest.rel_path, src_rel) or
            (dest.rel_path.len > src_rel.len and
                std.mem.startsWith(u8, dest.rel_path, src_rel) and
                dest.rel_path[src_rel.len] == '/'))
        {
            return error.InvalidCopy;
        }
        const base = std.fs.path.basenamePosix(src_rel);
        const new_rel = if (dest.rel_path.len == 0)
            try allocator.dupe(u8, base)
        else
            try std.mem.concat(allocator, u8, &.{ dest.rel_path, "/", base });
        errdefer allocator.free(new_rel);
        if (self.root_dir.access(self.io, new_rel, .{})) |_| {
            return error.PathAlreadyExists;
        } else |_| {}
        try self.copyIntoRoot(self.root_dir, src_rel, new_rel);
        return new_rel;
    }

    /// Copy an absolute path from outside the tree (OS drag & drop) into
    /// directory node `dest_dir_idx`, keeping its basename. No-clobber.
    /// Returns the new rel_path, owned by `allocator`.
    pub fn importAbsPath(self: *FileTree, allocator: Allocator, abs: []const u8, dest_dir_idx: u32) ![]u8 {
        const dest = self.nodes.items[dest_dir_idx];
        if (dest.kind != .dir) return error.InvalidCopy;
        const base = std.fs.path.basename(abs);
        if (base.len == 0) return error.InvalidCopy;
        const parent = std.fs.path.dirname(abs) orelse return error.InvalidCopy;
        const new_rel = if (dest.rel_path.len == 0)
            try allocator.dupe(u8, base)
        else
            try std.mem.concat(allocator, u8, &.{ dest.rel_path, "/", base });
        errdefer allocator.free(new_rel);
        normalizeSeps(new_rel);
        if (self.root_dir.access(self.io, new_rel, .{})) |_| {
            return error.PathAlreadyExists;
        } else |_| {}
        var pdir = try std.Io.Dir.openDirAbsolute(self.io, parent, .{});
        defer pdir.close(self.io);
        try self.copyIntoRoot(pdir, base, new_rel);
        return new_rel;
    }

    /// Absolute path of a node (root_path joined with rel_path), in
    /// native separators — rel_path is '/'-normalized internally, but
    /// user-facing consumers (clipboard, Explorer) want backslashes on
    /// Windows. Owned by `allocator`.
    pub fn absPathAlloc(self: *const FileTree, allocator: Allocator, idx: u32) ![]u8 {
        const rel = self.nodes.items[idx].rel_path;
        if (rel.len == 0) return allocator.dupe(u8, self.root_path);
        const joined = try std.fs.path.join(allocator, &.{ self.root_path, rel });
        if (builtin.os.tag == .windows) {
            for (joined) |*c| {
                if (c.* == '/') c.* = '\\';
            }
        }
        return joined;
    }

    // ---- Git status ----

    fn clearGitMaps(self: *FileTree) void {
        var kit = self.git_map.keyIterator();
        while (kit.next()) |k| self.allocator.free(k.*);
        self.git_map.clearRetainingCapacity();
        var dit = self.git_dirty_dirs.keyIterator();
        while (dit.next()) |k| self.allocator.free(k.*);
        self.git_dirty_dirs.clearRetainingCapacity();
    }

    /// Re-run `git status --porcelain -z` for the tree root and rebuild the
    /// status maps. Silently leaves them empty when git is missing or the
    /// root isn't inside a repository. Blocking one-shot — called on load,
    /// refresh, file ops, and save; never per frame.
    /// No-op (beyond clearing) when `git_enabled` is off — statusFor then
    /// returns null for everything and rows render uncolored.
    pub fn gitRefresh(self: *FileTree) void {
        self.clearGitMaps();
        if (!self.git_enabled) return;

        // Porcelain paths are repo-root-relative; --show-prefix tells us
        // where our tree root sits inside the repo (with a trailing '/').
        const prefix_res = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "git", "-C", self.root_path, "rev-parse", "--show-prefix" },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch return;
        defer self.allocator.free(prefix_res.stdout);
        defer self.allocator.free(prefix_res.stderr);
        switch (prefix_res.term) {
            .exited => |code| if (code != 0) return,
            else => return,
        }
        const prefix = std.mem.trimEnd(u8, prefix_res.stdout, "\r\n");

        // Pathspec '.' limits output to our subtree; -z gives NUL-separated
        // records with no quoting (spaces in names stay literal).
        const status_res = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "git", "-C", self.root_path, "status", "--porcelain", "-z", "--", "." },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(4096),
        }) catch return;
        defer self.allocator.free(status_res.stdout);
        defer self.allocator.free(status_res.stderr);
        switch (status_res.term) {
            .exited => |code| if (code != 0) return,
            else => return,
        }
        self.parseGitPorcelain(prefix, status_res.stdout) catch {};
    }

    /// Parse `git status --porcelain -z` output into the status maps.
    /// Records are `XY <path>\0`; rename/copy records carry a second
    /// NUL-terminated origin path that must be consumed or the parser
    /// desyncs. `prefix` (repo-relative root, trailing '/') is stripped.
    pub fn parseGitPorcelain(self: *FileTree, prefix: []const u8, bytes: []const u8) !void {
        var it = std.mem.splitScalar(u8, bytes, 0);
        while (it.next()) |rec| {
            if (rec.len < 4) continue; // "XY p" minimum
            const x = rec[0];
            const y = rec[1];
            if (rec[2] != ' ') continue;
            var path = rec[3..];
            if (x == 'R' or x == 'C' or y == 'R' or y == 'C') {
                _ = it.next(); // origin path of a rename/copy — ignored
            }
            if (prefix.len > 0) {
                if (path.len <= prefix.len or !std.mem.startsWith(u8, path, prefix)) continue;
                path = path[prefix.len..];
            }
            // Untracked directories arrive with a trailing slash
            path = std.mem.trimEnd(u8, path, "/");
            if (path.len == 0) continue;
            try self.putGitStatus(path, statusFromXY(x, y));
        }
    }

    fn putGitStatus(self: *FileTree, rel: []const u8, status: GitStatus) !void {
        if (self.git_map.getPtr(rel)) |existing| {
            if (@intFromEnum(status) < @intFromEnum(existing.*)) existing.* = status;
        } else {
            const key = try self.allocator.dupe(u8, rel);
            errdefer self.allocator.free(key);
            try self.git_map.put(self.allocator, key, status);
        }
        // Roll the change up into every ancestor directory
        var p = rel;
        while (std.mem.lastIndexOfScalar(u8, p, '/')) |sep| {
            p = p[0..sep];
            if (self.git_dirty_dirs.contains(p)) break;
            const dkey = try self.allocator.dupe(u8, p);
            errdefer self.allocator.free(dkey);
            try self.git_dirty_dirs.put(self.allocator, dkey, {});
        }
    }

    /// Git status for a node's row color: direct entry first, then the
    /// dirty-ancestor rollup for dirs, then untracked inherited from the
    /// nearest mapped ancestor (children of an untracked dir aren't listed
    /// individually by git).
    pub fn statusFor(self: *const FileTree, idx: u32) ?GitStatus {
        const node = self.nodes.items[idx];
        if (node.rel_path.len == 0) return null;
        if (self.git_map.get(node.rel_path)) |s| return s;
        if (node.kind == .dir and self.git_dirty_dirs.contains(node.rel_path)) return .modified;
        var p = node.rel_path;
        while (std.mem.lastIndexOfScalar(u8, p, '/')) |sep| {
            p = p[0..sep];
            if (self.git_map.get(p)) |s| {
                return if (s == .untracked) .untracked else null;
            }
        }
        return null;
    }

    /// Path of `abs` relative to the tree root ('/'-normalized, owned by
    /// `allocator`), or null if `abs` is outside the root.
    pub fn relFromAbs(self: *const FileTree, allocator: Allocator, abs: []const u8) !?[]u8 {
        if (abs.len < self.root_path.len) return null;
        if (!normPathEql(abs[0..self.root_path.len], self.root_path)) return null;
        var rest = abs[self.root_path.len..];
        if (rest.len == 0) return try allocator.dupe(u8, "");
        if (rest[0] != '/' and rest[0] != '\\') return null;
        rest = rest[1..];
        const out = try allocator.dupe(u8, rest);
        normalizeSeps(out);
        return out;
    }
};

/// Map porcelain X/Y status codes to a row color category. Untracked and
/// added win over modified; D in either column means deleted; everything
/// else (M, T, R, C, conflict combos) renders as modified.
fn statusFromXY(x: u8, y: u8) GitStatus {
    if (x == '?' or y == '?') return .untracked;
    if (x == 'A' or y == 'A') return .added;
    if (x == 'D' or y == 'D') return .deleted;
    return .modified;
}

/// Tail of `path` spanning at most `max_cols` codepoints — for showing
/// long paths truncated from the left (the tail is the readable part).
pub fn pathTail(path: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var start: usize = path.len;
    while (start > 0 and cols < max_cols) {
        var j = start - 1;
        while (j > 0 and (path[j] & 0xC0) == 0x80) j -= 1; // utf-8 continuations
        start = j;
        cols += 1;
    }
    return path[start..];
}

/// Replace '\' with '/' in place.
pub fn normalizeSeps(p: []u8) void {
    for (p) |*c| {
        if (c.* == '\\') c.* = '/';
    }
}

fn normPathChar(c: u8) u8 {
    const s: u8 = if (c == '\\') '/' else c;
    return if (builtin.os.tag == .windows) std.ascii.toLower(s) else s;
}

/// Separator-normalized path equality (case-insensitive on Windows).
pub fn normPathEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (normPathChar(ca) != normPathChar(cb)) return false;
    }
    return true;
}

// ---- Tests ----

const t = std.testing;

fn touch(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    const f = try dir.createFile(io, name, .{});
    f.close(io);
}

fn testTree(tmp: *std.testing.TmpDir) !FileTree {
    return FileTree.initFromDir(t.allocator, t.io, tmp.dir, "test-root");
}

test "filetree: load and sort (dirs first, case-insensitive)" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(t.io, tmp.dir, "b.txt");
    try touch(t.io, tmp.dir, "A.txt");
    try tmp.dir.createDirPath(t.io, "zdir");
    try tmp.dir.createDirPath(t.io, "adir");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    try t.expectEqual(@as(usize, 4), ft.visible.items.len);
    const names = [_][]const u8{ "adir", "zdir", "A.txt", "b.txt" };
    for (names, ft.visible.items) |want, idx| {
        try t.expectEqualStrings(want, ft.nodes.items[idx].name);
    }
    // Dirs at depth 1 (root excluded from visible)
    try t.expectEqual(@as(u16, 1), ft.nodes.items[ft.visible.items[0]].depth);
}

test "filetree: lazy expand and collapse" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "sub");
    try touch(t.io, tmp.dir, "sub/inner.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    try t.expectEqual(@as(usize, 1), ft.visible.items.len);
    const sub_idx = ft.visible.items[0];
    try t.expect(!ft.nodes.items[sub_idx].loaded);

    try ft.expand(sub_idx);
    try t.expect(ft.nodes.items[sub_idx].loaded);
    try t.expectEqual(@as(usize, 2), ft.visible.items.len);
    try t.expectEqualStrings("inner.txt", ft.nodes.items[ft.visible.items[1]].name);
    try t.expectEqualStrings("sub/inner.txt", ft.nodes.items[ft.visible.items[1]].rel_path);
    try t.expectEqual(@as(u16, 2), ft.nodes.items[ft.visible.items[1]].depth);

    try ft.collapse(sub_idx);
    try t.expectEqual(@as(usize, 1), ft.visible.items.len);
}

test "filetree: expandToPath selects and flags scroll" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "a/b");
    try touch(t.io, tmp.dir, "a/b/c.txt");
    try touch(t.io, tmp.dir, "top.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    const found = try ft.expandToPath("a/b/c.txt");
    try t.expect(found != null);
    try t.expectEqualStrings("c.txt", ft.nodes.items[found.?].name);
    try t.expectEqual(found.?, ft.selectedNodeIdx().?);
    try t.expect(ft.scroll_to_selected);
    // Missing path: ancestors stay expanded, returns null
    try t.expectEqual(@as(?u32, null), try ft.expandToPath("a/b/missing.txt"));
}

test "filetree: collapseAll folds everything but the root" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "a/b");
    try touch(t.io, tmp.dir, "a/b/c.txt");
    try touch(t.io, tmp.dir, "top.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    _ = try ft.expandToPath("a/b/c.txt");
    try t.expectEqual(@as(usize, 4), ft.visible.items.len); // a, b, c.txt, top.txt

    try ft.collapseAll();
    try t.expectEqual(@as(usize, 2), ft.visible.items.len); // a, top.txt
    try t.expectEqual(@as(usize, 0), ft.selected);
    try t.expect(ft.scroll_to_selected);
    try t.expect(!ft.nodes.items[ft.findByPath("a").?].expanded);
}

test "filetree: refresh preserves expansion and selection, drops vanished" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "keep");
    try touch(t.io, tmp.dir, "keep/k.txt");
    try tmp.dir.createDirPath(t.io, "gone");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    _ = try ft.expandToPath("keep/k.txt"); // expands keep, selects k.txt
    const gone_idx = ft.findByPath("gone").?;
    try ft.expand(gone_idx);

    // Mutate the directory behind the tree's back
    try tmp.dir.deleteTree(t.io, "gone");
    try touch(t.io, tmp.dir, "keep/new.txt");

    try ft.refresh();
    try t.expectEqual(@as(?u32, null), ft.findByPath("gone"));
    const keep_idx = ft.findByPath("keep").?;
    try t.expect(ft.nodes.items[keep_idx].expanded);
    try t.expect(ft.findByPath("keep/new.txt") != null);
    // Selection restored by path
    try t.expectEqualStrings("k.txt", ft.nodes.items[ft.selectedNodeIdx().?].name);
}

test "filetree: createEntry file, nested file, and trailing-slash dir" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var ft = try testTree(&tmp);
    defer ft.deinit();

    const f1 = try ft.createEntry(t.allocator, 0, "plain.txt");
    defer t.allocator.free(f1);
    try t.expectEqualStrings("plain.txt", f1);
    try tmp.dir.access(t.io, "plain.txt", .{});

    const d1 = try ft.createEntry(t.allocator, 0, "newdir/");
    defer t.allocator.free(d1);
    try t.expectEqualStrings("newdir", d1);
    try tmp.dir.access(t.io, "newdir", .{});

    const f2 = try ft.createEntry(t.allocator, 0, "x/y.txt");
    defer t.allocator.free(f2);
    try t.expectEqualStrings("x/y.txt", f2);
    try tmp.dir.access(t.io, "x/y.txt", .{});

    // Existing file is not clobbered
    try t.expectError(error.PathAlreadyExists, ft.createEntry(t.allocator, 0, "plain.txt"));
    // Bad names rejected
    try t.expectError(error.InvalidName, ft.createEntry(t.allocator, 0, ""));
    try t.expectError(error.InvalidName, ft.createEntry(t.allocator, 0, "../escape.txt"));
}

test "filetree: renameEntry no-clobber and doc-visible result" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(t.io, tmp.dir, "old.txt");
    try touch(t.io, tmp.dir, "taken.txt");
    try tmp.dir.createDirPath(t.io, "sub");
    try touch(t.io, tmp.dir, "sub/deep.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    const idx = ft.findByPath("old.txt").?;
    try t.expectError(error.PathAlreadyExists, ft.renameEntry(t.allocator, idx, "taken.txt"));
    const new_rel = try ft.renameEntry(t.allocator, idx, "renamed.txt");
    defer t.allocator.free(new_rel);
    try t.expectEqualStrings("renamed.txt", new_rel);
    try tmp.dir.access(t.io, "renamed.txt", .{});
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "old.txt", .{}));

    // Renaming inside a subdir keeps the dir part
    _ = try ft.expandToPath("sub/deep.txt");
    const deep_idx = ft.findByPath("sub/deep.txt").?;
    const deep_rel = try ft.renameEntry(t.allocator, deep_idx, "deeper.txt");
    defer t.allocator.free(deep_rel);
    try t.expectEqualStrings("sub/deeper.txt", deep_rel);

    try t.expectError(error.InvalidName, ft.renameEntry(t.allocator, idx, "no/seps"));
}

test "filetree: deleteEntry file and recursive dir" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(t.io, tmp.dir, "doomed.txt");
    try tmp.dir.createDirPath(t.io, "doomed_dir/nested");
    try touch(t.io, tmp.dir, "doomed_dir/nested/f.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    try ft.deleteEntry(ft.findByPath("doomed.txt").?);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "doomed.txt", .{}));

    try ft.deleteEntry(ft.findByPath("doomed_dir").?);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "doomed_dir", .{}));

    try ft.refresh();
    try t.expectEqual(@as(usize, 0), ft.visible.items.len);
    try t.expectEqual(@as(?u32, null), ft.selectedNodeIdx());
}

test "filetree: moveEntry file and dir into subdir" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(t.io, tmp.dir, "a.txt");
    try tmp.dir.createDirPath(t.io, "sub");
    try tmp.dir.createDirPath(t.io, "other");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    const moved = try ft.moveEntry(t.allocator, ft.findByPath("a.txt").?, ft.findByPath("sub").?);
    defer t.allocator.free(moved);
    try t.expectEqualStrings("sub/a.txt", moved);
    try tmp.dir.access(t.io, "sub/a.txt", .{});
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "a.txt", .{}));

    const moved_dir = try ft.moveEntry(t.allocator, ft.findByPath("other").?, ft.findByPath("sub").?);
    defer t.allocator.free(moved_dir);
    try t.expectEqualStrings("sub/other", moved_dir);
    try tmp.dir.access(t.io, "sub/other", .{});
}

test "filetree: moveEntry rejects bad targets and collisions" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "parent/child");
    try touch(t.io, tmp.dir, "f.txt");
    try touch(t.io, tmp.dir, "parent/f.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();
    _ = try ft.expandToPath("parent/child");

    const parent_idx = ft.findByPath("parent").?;
    const child_idx = ft.findByPath("parent/child").?;
    const f_idx = ft.findByPath("f.txt").?;

    // Dir into its own subtree
    try t.expectError(error.InvalidMove, ft.moveEntry(t.allocator, parent_idx, child_idx));
    // Into itself
    try t.expectError(error.InvalidMove, ft.moveEntry(t.allocator, parent_idx, parent_idx));
    // Into its current parent (root) — no-op rejected
    try t.expectError(error.InvalidMove, ft.moveEntry(t.allocator, f_idx, 0));
    // Onto a file
    try t.expectError(error.InvalidMove, ft.moveEntry(t.allocator, f_idx, ft.findByPath("parent/f.txt").?));
    // Name collision in the destination — not clobbered
    try t.expectError(error.PathAlreadyExists, ft.moveEntry(t.allocator, f_idx, parent_idx));
    try tmp.dir.access(t.io, "f.txt", .{});
}

test "filetree: moveSelection clamps and rowOf finds parent" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(t.io, tmp.dir, "one.txt");
    try touch(t.io, tmp.dir, "two.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    ft.moveSelection(-5);
    try t.expectEqual(@as(usize, 0), ft.selected);
    ft.moveSelection(10);
    try t.expectEqual(@as(usize, 1), ft.selected);
    ft.moveSelection(-1);
    try t.expectEqual(@as(usize, 0), ft.selected);
}

test "filetree: porcelain parser basics + ancestor rollup" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var ft = try testTree(&tmp);
    defer ft.deinit();

    try ft.parseGitPorcelain("", "?? new.txt\x00 M src/main.zig\x00A  staged.zig\x00 D gone.txt\x00");
    try t.expectEqual(GitStatus.untracked, ft.git_map.get("new.txt").?);
    try t.expectEqual(GitStatus.modified, ft.git_map.get("src/main.zig").?);
    try t.expectEqual(GitStatus.added, ft.git_map.get("staged.zig").?);
    try t.expectEqual(GitStatus.deleted, ft.git_map.get("gone.txt").?);
    try t.expect(ft.git_dirty_dirs.contains("src"));
    try t.expect(!ft.git_dirty_dirs.contains("new.txt"));
}

test "filetree: porcelain rename records don't desync the parser" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var ft = try testTree(&tmp);
    defer ft.deinit();

    // R record carries a second NUL field (the origin path); the entry
    // after it must still parse.
    try ft.parseGitPorcelain("", "R  new-name.txt\x00old-name.txt\x00?? after.txt\x00");
    try t.expectEqual(GitStatus.modified, ft.git_map.get("new-name.txt").?);
    try t.expectEqual(@as(?GitStatus, null), ft.git_map.get("old-name.txt"));
    try t.expectEqual(GitStatus.untracked, ft.git_map.get("after.txt").?);
}

test "filetree: porcelain prefix strip, untracked dirs, spaces" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var ft = try testTree(&tmp);
    defer ft.deinit();

    try ft.parseGitPorcelain("app/", "?? app/inner.txt\x00?? outside.txt\x00?? app/newdir/\x00 M app/has space.txt\x00");
    try t.expectEqual(GitStatus.untracked, ft.git_map.get("inner.txt").?);
    try t.expectEqual(@as(?GitStatus, null), ft.git_map.get("outside.txt"));
    try t.expectEqual(GitStatus.untracked, ft.git_map.get("newdir").?);
    try t.expectEqual(GitStatus.modified, ft.git_map.get("has space.txt").?);
}

test "filetree: statusFor rollup and untracked inheritance" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "src");
    try touch(t.io, tmp.dir, "src/main.zig");
    try tmp.dir.createDirPath(t.io, "newdir");
    try touch(t.io, tmp.dir, "newdir/child.txt");
    try touch(t.io, tmp.dir, "clean.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();
    try ft.parseGitPorcelain("", " M src/main.zig\x00?? newdir/\x00");

    // Dir containing a change rolls up as modified
    try t.expectEqual(GitStatus.modified, ft.statusFor(ft.findByPath("src").?).?);
    // The changed file itself
    _ = try ft.expandToPath("src/main.zig");
    try t.expectEqual(GitStatus.modified, ft.statusFor(ft.findByPath("src/main.zig").?).?);
    // Untracked dir + a child inheriting untracked from its ancestor
    try t.expectEqual(GitStatus.untracked, ft.statusFor(ft.findByPath("newdir").?).?);
    _ = try ft.expandToPath("newdir/child.txt");
    try t.expectEqual(GitStatus.untracked, ft.statusFor(ft.findByPath("newdir/child.txt").?).?);
    // Clean file has no status
    try t.expectEqual(@as(?GitStatus, null), ft.statusFor(ft.findByPath("clean.txt").?));
}

test "filetree: checkExternalChanges spots out-of-band file creation" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(t.io, tmp.dir, "a.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    try t.expect(!ft.checkExternalChanges());
    try touch(t.io, tmp.dir, "outside.txt"); // created behind the tree's back
    // Windows file times tick coarsely (~0.5–16ms): a fast run can create
    // the file in the same tick the scan stamped, leaving the dir mtime
    // unchanged. Churn the directory until the mtime visibly moves —
    // bounded, and exactly the self-healing the 1.5s production poll has.
    var attempts: usize = 0;
    while (!ft.checkExternalChanges() and attempts < 10_000) : (attempts += 1) {
        tmp.dir.deleteFile(t.io, "outside.txt") catch {};
        try touch(t.io, tmp.dir, "outside.txt");
    }
    try t.expect(ft.checkExternalChanges());
    try ft.refresh();
    try t.expect(!ft.checkExternalChanges());
    try t.expect(ft.findByPath("outside.txt") != null);
}

test "filetree: opTargetDir resolves root/dir/file-parent" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "sub");
    try touch(t.io, tmp.dir, "sub/inner.txt");
    try touch(t.io, tmp.dir, "top.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    // Selected dir -> itself
    ft.selected = ft.rowOf(ft.findByPath("sub").?).?;
    try t.expectEqual(ft.findByPath("sub").?, ft.opTargetDir());
    // Selected file -> its parent
    _ = try ft.expandToPath("sub/inner.txt");
    try t.expectEqual(ft.findByPath("sub").?, ft.opTargetDir());
    // Explicit root target wins; row selection clears it
    ft.root_selected = true;
    try t.expectEqual(@as(u32, 0), ft.opTargetDir());
    ft.moveSelection(1);
    try t.expect(!ft.root_selected);
}

test "filetree: multi toggle seeds, accumulates, and collapses" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(t.io, tmp.dir, "a.txt");
    try touch(t.io, tmp.dir, "b.txt");
    try touch(t.io, tmp.dir, "c.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    ft.selected = 0; // a.txt
    try ft.toggleMultiAt(2); // ctrl+click c.txt: set = {a, c}
    try t.expectEqual(@as(usize, 2), ft.selectionCount());
    try t.expectEqual(@as(usize, 2), ft.selected);
    try t.expect(ft.isMultiSelected(ft.visible.items[0]));
    try t.expect(ft.isMultiSelected(ft.visible.items[2]));

    try ft.toggleMultiAt(2); // toggle c off: collapses to plain a.txt
    try t.expectEqual(@as(usize, 1), ft.selectionCount());
    try t.expectEqual(@as(usize, 0), ft.selected);
    try t.expectEqual(@as(usize, 0), ft.multi.count());
}

test "filetree: shift range replaces and follows the anchor" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(t.io, tmp.dir, "a.txt");
    try touch(t.io, tmp.dir, "b.txt");
    try touch(t.io, tmp.dir, "c.txt");
    try touch(t.io, tmp.dir, "d.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();

    ft.selected = 1; // b.txt as anchor
    try ft.selectRangeTo(3); // b..d
    try t.expectEqual(@as(usize, 3), ft.selectionCount());
    try t.expectEqual(@as(usize, 3), ft.selected);
    try ft.selectRangeTo(0); // same anchor, other direction: a..b
    try t.expectEqual(@as(usize, 2), ft.selectionCount());
    try t.expect(ft.isMultiSelected(ft.visible.items[0]));
    try t.expect(ft.isMultiSelected(ft.visible.items[1]));
    try t.expect(!ft.isMultiSelected(ft.visible.items[3]));
    ft.clearMulti();
    try t.expectEqual(@as(usize, 1), ft.selectionCount());
}

test "filetree: selectionRelPaths drops covered descendants" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "sub");
    try touch(t.io, tmp.dir, "sub/inner.txt");
    try touch(t.io, tmp.dir, "top.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();
    _ = try ft.expandToPath("sub/inner.txt");

    const sub_row = ft.rowOf(ft.findByPath("sub").?).?;
    const inner_row = ft.rowOf(ft.findByPath("sub/inner.txt").?).?;
    const top_row = ft.rowOf(ft.findByPath("top.txt").?).?;
    ft.selected = sub_row;
    try ft.toggleMultiAt(inner_row);
    try ft.toggleMultiAt(top_row);

    const paths = try ft.selectionRelPaths(t.allocator);
    defer {
        for (paths) |p| t.allocator.free(p);
        t.allocator.free(paths);
    }
    // sub/inner.txt is covered by sub
    try t.expectEqual(@as(usize, 2), paths.len);
    try t.expectEqualStrings("sub", paths[0]);
    try t.expectEqualStrings("top.txt", paths[1]);
}

test "filetree: copyEntryTo file and recursive dir, no-clobber" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(t.io, tmp.dir, "a.txt");
    try tmp.dir.createDirPath(t.io, "src/nested");
    try touch(t.io, tmp.dir, "src/f.txt");
    try touch(t.io, tmp.dir, "src/nested/deep.txt");
    try tmp.dir.createDirPath(t.io, "dest");

    var ft = try testTree(&tmp);
    defer ft.deinit();
    const dest_idx = ft.findByPath("dest").?;

    const c1 = try ft.copyEntryTo(t.allocator, "a.txt", dest_idx);
    defer t.allocator.free(c1);
    try t.expectEqualStrings("dest/a.txt", c1);
    try tmp.dir.access(t.io, "dest/a.txt", .{});
    try tmp.dir.access(t.io, "a.txt", .{}); // source stays

    const c2 = try ft.copyEntryTo(t.allocator, "src", dest_idx);
    defer t.allocator.free(c2);
    try tmp.dir.access(t.io, "dest/src/f.txt", .{});
    try tmp.dir.access(t.io, "dest/src/nested/deep.txt", .{});

    // No-clobber, and no copying into your own subtree
    try t.expectError(error.PathAlreadyExists, ft.copyEntryTo(t.allocator, "a.txt", dest_idx));
    try ft.refresh();
    _ = try ft.expandToPath("src/nested");
    try t.expectError(error.InvalidCopy, ft.copyEntryTo(t.allocator, "src", ft.findByPath("src/nested").?));
}

test "filetree: moveRelTo works for unloaded (collapsed) sources" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "sub");
    try touch(t.io, tmp.dir, "sub/deep.txt");
    try tmp.dir.createDirPath(t.io, "dest");

    var ft = try testTree(&tmp);
    defer ft.deinit();
    // Never expanded: sub/deep.txt has no node, but the path move works.
    try t.expectEqual(@as(?u32, null), ft.findByPath("sub/deep.txt"));
    const moved = try ft.moveRelTo(t.allocator, "sub/deep.txt", ft.findByPath("dest").?);
    defer t.allocator.free(moved);
    try t.expectEqualStrings("dest/deep.txt", moved);
    try tmp.dir.access(t.io, "dest/deep.txt", .{});
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "sub/deep.txt", .{}));
}

test "filetree: importAbsPath copies from outside the root" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var outside = t.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try touch(t.io, outside.dir, "alien.txt");
    const outside_abs = try std.Io.Dir.realPathFileAlloc(outside.dir, t.io, "alien.txt", t.allocator);
    defer t.allocator.free(outside_abs);

    var ft = try testTree(&tmp);
    defer ft.deinit();

    const imported = try ft.importAbsPath(t.allocator, outside_abs, 0);
    defer t.allocator.free(imported);
    try t.expectEqualStrings("alien.txt", imported);
    try tmp.dir.access(t.io, "alien.txt", .{});
    try outside.dir.access(t.io, "alien.txt", .{}); // source untouched
    // Second import collides
    try t.expectError(error.PathAlreadyExists, ft.importAbsPath(t.allocator, outside_abs, 0));
}

test "filetree: absPathAlloc uses native separators" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "sub");
    try touch(t.io, tmp.dir, "sub/deep.txt");

    var ft = try testTree(&tmp);
    defer ft.deinit();
    _ = try ft.expandToPath("sub/deep.txt");

    const abs = try ft.absPathAlloc(t.allocator, ft.findByPath("sub/deep.txt").?);
    defer t.allocator.free(abs);
    if (builtin.os.tag == .windows) {
        try t.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, abs, '/'));
    }
    try t.expect(std.mem.endsWith(u8, abs, if (builtin.os.tag == .windows) "sub\\deep.txt" else "sub/deep.txt"));
}

test "filetree: pathTail left-truncation" {
    try t.expectEqualStrings("C:\\code\\zide", pathTail("C:\\code\\zide", 50));
    try t.expectEqualStrings("ide", pathTail("C:\\code\\zide", 3));
    try t.expectEqualStrings("", pathTail("abc", 0));
}

test "filetree: path helpers" {
    try t.expect(normPathEql("a/b", "a/b"));
    try t.expect(normPathEql("a\\b", "a/b"));
    if (builtin.os.tag == .windows) {
        try t.expect(normPathEql("C:\\Foo\\Bar", "c:/foo/bar"));
    }
    try t.expect(!normPathEql("a/b", "a/c"));

    var buf = "a\\b\\c".*;
    normalizeSeps(&buf);
    try t.expectEqualStrings("a/b/c", &buf);
}
