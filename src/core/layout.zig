const std = @import("std");
const Allocator = std.mem.Allocator;

/// Content type for a pane — either an editor document or a terminal.
pub const PaneContent = union(enum) {
    editor: usize, // doc_idx
    terminal: usize, // terminal_idx
};

/// A pane is a leaf in the layout tree.
pub const Pane = struct {
    content: PaneContent,
};

/// Direction of a split.
pub const SplitDirection = enum {
    horizontal, // first pane on left, second on right
    vertical, // first pane on top, second on bottom
};

/// A node in the binary layout tree.
pub const LayoutNode = union(enum) {
    leaf: u8, // pane index into Layout.panes
    split: Split,

    pub const Split = struct {
        direction: SplitDirection,
        ratio: f32,
        first: u8, // index into Layout.nodes
        second: u8, // index into Layout.nodes
    };
};

/// The layout tree: manages panes and their spatial arrangement.
pub const Layout = struct {
    nodes: std.ArrayList(LayoutNode),
    panes: std.ArrayList(Pane),
    /// Recyclable node slots orphaned by closePane. Without reuse the u8
    /// index space (255 slots) ran out after ~127 splits in a session.
    free_nodes: std.ArrayList(u8),
    /// Recyclable pane slots orphaned by closePane.
    free_panes: std.ArrayList(u8),
    allocator: Allocator,

    /// Sentinel pane id for orphaned node slots. allocPane never hands out
    /// 255, so a dead leaf can never match a live pane lookup.
    const dead_pane: u8 = 255;

    pub fn init(allocator: Allocator) !Layout {
        var layout = Layout{
            .nodes = .empty,
            .panes = .empty,
            .free_nodes = .empty,
            .free_panes = .empty,
            .allocator = allocator,
        };
        errdefer layout.deinit();
        // Start with a single pane (pane 0) showing document 0
        try layout.panes.append(allocator, .{ .content = .{ .editor = 0 } });
        // Root node is a leaf pointing to pane 0
        try layout.nodes.append(allocator, .{ .leaf = 0 });
        return layout;
    }

    pub fn deinit(self: *Layout) void {
        self.nodes.deinit(self.allocator);
        self.panes.deinit(self.allocator);
        self.free_nodes.deinit(self.allocator);
        self.free_panes.deinit(self.allocator);
    }

    /// Number of live panes (leaves reachable from the root — the panes list
    /// itself retains recyclable orphaned slots).
    pub fn paneCount(self: *const Layout) usize {
        return self.countLeaves(0);
    }

    fn countLeaves(self: *const Layout, node_idx: u8) usize {
        if (node_idx >= self.nodes.items.len) return 0;
        return switch (self.nodes.items[node_idx]) {
            .leaf => 1,
            .split => |s| self.countLeaves(s.first) + self.countLeaves(s.second),
        };
    }

    /// Get a node slot: reuse a recycled slot or append a new one.
    fn allocNode(self: *Layout, node: LayoutNode) !u8 {
        if (self.free_nodes.pop()) |idx| {
            self.nodes.items[idx] = node;
            return idx;
        }
        if (self.nodes.items.len >= 255) return error.LayoutFull;
        const idx: u8 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return idx;
    }

    /// Get a pane slot: reuse a recycled slot or append a new one.
    fn allocPane(self: *Layout, content: PaneContent) !u8 {
        if (self.free_panes.pop()) |idx| {
            self.panes.items[idx] = .{ .content = content };
            return idx;
        }
        if (self.panes.items.len >= dead_pane) return error.LayoutFull;
        const idx: u8 = @intCast(self.panes.items.len);
        try self.panes.append(self.allocator, .{ .content = content });
        return idx;
    }

    /// Split a pane into two. The existing pane stays as the first child,
    /// a new pane becomes the second child.
    /// Returns the new pane's index.
    pub fn splitPane(self: *Layout, pane_id: u8, direction: SplitDirection, new_content: PaneContent) !u8 {
        // Find the leaf node for this pane
        const leaf_node_idx = self.findLeafNode(pane_id) orelse return error.PaneNotFound;

        // Create the new pane
        const new_pane_id = try self.allocPane(new_content);
        errdefer self.free_panes.append(self.allocator, new_pane_id) catch {};

        // Create two new leaf nodes
        const first_leaf_idx = try self.allocNode(.{ .leaf = pane_id });
        errdefer self.free_nodes.append(self.allocator, first_leaf_idx) catch {};
        const second_leaf_idx = try self.allocNode(.{ .leaf = new_pane_id });

        // Replace the original leaf with a split node
        self.nodes.items[leaf_node_idx] = .{ .split = .{
            .direction = direction,
            .ratio = 0.5,
            .first = first_leaf_idx,
            .second = second_leaf_idx,
        } };

        return new_pane_id;
    }

    /// Close a pane. Replaces its parent split with the sibling and recycles
    /// the orphaned node and pane slots.
    /// Returns the pane that should take focus: the first leaf of the closed
    /// pane's sibling subtree — its spatial neighbour (in `[A | [B / C]]`
    /// closing C gives B, where traversal order would wrap to A). Null when
    /// nothing was closed (the last pane, or an id not in the live tree).
    pub fn closePane(self: *Layout, pane_id: u8) ?u8 {
        if (self.paneCount() <= 1) return null;

        const leaf_node_idx = self.findLeafNode(pane_id) orelse return null;
        const parent_info = self.findParent(leaf_node_idx) orelse return null;
        const parent_idx = parent_info.parent_idx;
        const split = self.nodes.items[parent_idx].split;

        // Determine sibling node index
        const sibling_idx = if (split.first == leaf_node_idx) split.second else split.first;

        // Replace parent split with sibling content
        self.nodes.items[parent_idx] = self.nodes.items[sibling_idx];

        // Recycle the orphaned slots. Overwrite with dead content so stale
        // split/terminal references can never confuse linear scans
        // (findParent walks ALL node slots, including recycled ones).
        self.nodes.items[leaf_node_idx] = .{ .leaf = dead_pane };
        self.nodes.items[sibling_idx] = .{ .leaf = dead_pane };
        self.free_nodes.append(self.allocator, @intCast(leaf_node_idx)) catch {};
        self.free_nodes.append(self.allocator, @intCast(sibling_idx)) catch {};
        self.panes.items[pane_id] = .{ .content = .{ .editor = 0 } };
        self.free_panes.append(self.allocator, pane_id) catch {};

        // The sibling's subtree now lives at the parent's slot.
        return self.firstLeafPane(@intCast(parent_idx));
    }

    /// Find the node index of the leaf that contains the given pane_id.
    /// Only searches the live tree reachable from the root node, ignoring
    /// orphaned nodes left behind by closePane.
    pub fn findLeafNode(self: *const Layout, pane_id: u8) ?usize {
        return self.findLeafNodeFrom(0, pane_id);
    }

    fn findLeafNodeFrom(self: *const Layout, node_idx: u8, pane_id: u8) ?usize {
        if (node_idx >= self.nodes.items.len) return null;
        switch (self.nodes.items[node_idx]) {
            .leaf => |pid| {
                if (pid == pane_id) return node_idx;
                return null;
            },
            .split => |s| {
                if (self.findLeafNodeFrom(s.first, pane_id)) |found| return found;
                return self.findLeafNodeFrom(s.second, pane_id);
            },
        }
    }

    /// Find the parent split node of a given node index.
    /// Returns the parent node index and whether the child is the first or second.
    pub fn findParent(self: *const Layout, child_idx: usize) ?struct { parent_idx: usize, is_first: bool } {
        for (self.nodes.items, 0..) |node, i| {
            switch (node) {
                .split => |s| {
                    if (s.first == child_idx) return .{ .parent_idx = i, .is_first = true };
                    if (s.second == child_idx) return .{ .parent_idx = i, .is_first = false };
                },
                .leaf => {},
            }
        }
        return null;
    }

    /// Get the pane ID of the first leaf found by traversing from a node.
    pub fn firstLeafPane(self: *const Layout, node_idx: u8) ?u8 {
        if (node_idx >= self.nodes.items.len) return null;
        switch (self.nodes.items[node_idx]) {
            .leaf => |pid| return pid,
            .split => |s| return self.firstLeafPane(s.first),
        }
    }

    /// Get the ratio pointer for a split node (so DVUI PanedWidget can read/write it).
    pub fn ratioPtr(self: *Layout, node_idx: usize) ?*f32 {
        if (node_idx >= self.nodes.items.len) return null;
        switch (self.nodes.items[node_idx]) {
            .split => |*s| return &s.ratio,
            .leaf => return null,
        }
    }

    /// Collect all leaf pane IDs in order (left-to-right / top-to-bottom).
    pub fn collectLeaves(self: *const Layout, node_idx: u8, out: *std.ArrayList(u8)) !void {
        if (node_idx >= self.nodes.items.len) return;
        switch (self.nodes.items[node_idx]) {
            .leaf => |pid| try out.append(self.allocator, pid),
            .split => |s| {
                try self.collectLeaves(s.first, out);
                try self.collectLeaves(s.second, out);
            },
        }
    }

    /// Find the next pane in traversal order after the given pane_id.
    /// Wraps around to the first pane if at the end.
    pub fn nextPane(self: *const Layout, current_pane: u8) ?u8 {
        var leaves: std.ArrayList(u8) = .empty;
        defer leaves.deinit(self.allocator);
        self.collectLeaves(0, &leaves) catch return null;
        if (leaves.items.len <= 1) return null;
        for (leaves.items, 0..) |pid, i| {
            if (pid == current_pane) {
                return leaves.items[(i + 1) % leaves.items.len];
            }
        }
        return null;
    }

    /// Find the previous pane in traversal order before the given pane_id.
    pub fn prevPane(self: *const Layout, current_pane: u8) ?u8 {
        var leaves: std.ArrayList(u8) = .empty;
        defer leaves.deinit(self.allocator);
        self.collectLeaves(0, &leaves) catch return null;
        if (leaves.items.len <= 1) return null;
        for (leaves.items, 0..) |pid, i| {
            if (pid == current_pane) {
                if (i == 0) return leaves.items[leaves.items.len - 1];
                return leaves.items[i - 1];
            }
        }
        return null;
    }
};

// ---- Tests ----

test "layout init" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(allocator);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 1), layout.paneCount());
    try std.testing.expectEqual(@as(usize, 1), layout.nodes.items.len);
    try std.testing.expectEqual(LayoutNode{ .leaf = 0 }, layout.nodes.items[0]);
}

test "layout split pane" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(allocator);
    defer layout.deinit();

    const new_pane = try layout.splitPane(0, .horizontal, .{ .editor = 1 });
    try std.testing.expectEqual(@as(u8, 1), new_pane);
    try std.testing.expectEqual(@as(usize, 2), layout.paneCount());

    // Root should now be a split
    switch (layout.nodes.items[0]) {
        .split => |s| {
            try std.testing.expectEqual(SplitDirection.horizontal, s.direction);
            try std.testing.expectEqual(@as(f32, 0.5), s.ratio);
        },
        .leaf => return error.ExpectedSplit,
    }
}

test "layout close pane" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(allocator);
    defer layout.deinit();

    _ = try layout.splitPane(0, .horizontal, .{ .editor = 1 });
    try std.testing.expectEqual(@as(usize, 2), layout.paneCount());

    // Close pane 1 — root should become a leaf again, focus goes to pane 0
    try std.testing.expectEqual(@as(?u8, 0), layout.closePane(1));

    switch (layout.nodes.items[0]) {
        .leaf => |pid| try std.testing.expectEqual(@as(u8, 0), pid),
        .split => return error.ExpectedLeaf,
    }
}

test "layout cannot close last pane" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(allocator);
    defer layout.deinit();

    try std.testing.expectEqual(@as(?u8, null), layout.closePane(0));
    // An id that is not in the live tree closes nothing either
    _ = try layout.splitPane(0, .horizontal, .{ .editor = 1 });
    try std.testing.expectEqual(@as(?u8, null), layout.closePane(7));
    try std.testing.expectEqual(@as(usize, 2), layout.paneCount());
}

test "layout closePane returns the closed pane's sibling leaf" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(allocator);
    defer layout.deinit();

    // [A | [B / C]] with A = pane 0, B = pane 1, C = pane 2.
    _ = try layout.splitPane(0, .horizontal, .{ .editor = 1 });
    const c = try layout.splitPane(1, .vertical, .{ .editor = 2 });
    try std.testing.expectEqual(@as(u8, 2), c);
    // Traversal order wraps from C to the far pane A; the neighbour is B.
    try std.testing.expectEqual(@as(?u8, 0), layout.nextPane(c));
    try std.testing.expectEqual(@as(?u8, 1), layout.closePane(c));
    try std.testing.expectEqual(@as(usize, 2), layout.paneCount());

    // [A | [B / C]] again: closing A hands focus to the first leaf of [B / C].
    const c2 = try layout.splitPane(1, .vertical, .{ .editor = 2 });
    try std.testing.expectEqual(@as(?u8, 1), layout.closePane(0));
    try std.testing.expectEqual(@as(usize, 2), layout.paneCount());
    // [B / C]: closing B leaves C, and C is then the last pane.
    try std.testing.expectEqual(@as(?u8, c2), layout.closePane(1));
    try std.testing.expectEqual(@as(?u8, null), layout.closePane(c2));
    try std.testing.expectEqual(@as(usize, 1), layout.paneCount());
}

test "layout survives split/close churn past 255 slots" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(allocator);
    defer layout.deinit();

    // Each split adds 2 nodes; without slot recycling this panicked at
    // ~127 splits when the u8 index space ran out.
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const new_pane = try layout.splitPane(0, .horizontal, .{ .editor = 1 });
        try std.testing.expectEqual(@as(usize, 2), layout.paneCount());
        try std.testing.expectEqual(@as(?u8, 0), layout.closePane(new_pane));
        try std.testing.expectEqual(@as(usize, 1), layout.paneCount());
    }
    // Slot recycling keeps the backing arrays tiny
    try std.testing.expect(layout.nodes.items.len < 8);
    try std.testing.expect(layout.panes.items.len < 8);
}

test "layout next/prev pane" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(allocator);
    defer layout.deinit();

    _ = try layout.splitPane(0, .horizontal, .{ .editor = 1 });
    _ = try layout.splitPane(1, .vertical, .{ .editor = 2 });

    try std.testing.expectEqual(@as(?u8, 1), layout.nextPane(0));
    try std.testing.expectEqual(@as(?u8, 0), layout.prevPane(1));
    try std.testing.expectEqual(@as(?u8, 0), layout.nextPane(2)); // wraps
}
