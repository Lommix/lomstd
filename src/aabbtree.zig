const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec = @Vector(4, f32);

pub const Aabb = struct {
    vec: Vec,

    pub fn new(min_x: f32, min_y: f32, max_x: f32, max_y: f32) Aabb {
        return .{ .vec = .{ min_x, min_y, max_x, max_y } };
    }

    pub inline fn intersect(self: Aabb, other: Aabb) bool {
        const x_overlap = self.vec[0] < other.vec[2] and self.vec[2] > other.vec[0];
        const y_overlap = self.vec[1] < other.vec[3] and self.vec[3] > other.vec[1];
        return x_overlap and y_overlap;
    }

    pub inline fn merge(lower: Aabb, upper: Aabb) Aabb {
        return .{ .vec = .{
            @min(lower.vec[0], upper.vec[0]),
            @min(lower.vec[1], upper.vec[1]),
            @max(lower.vec[2], upper.vec[2]),
            @max(lower.vec[3], upper.vec[3]),
        } };
    }

    pub inline fn surface(self: Aabb) f32 {
        return @abs(self.vec[2] - self.vec[0]) *
            @abs(self.vec[3] - self.vec[1]);
    }

    inline fn perimeter(self: Aabb) f32 {
        return 2.0 * (@abs(self.vec[2] - self.vec[0]) + @abs(self.vec[3] - self.vec[1]));
    }
};

pub fn AabbTree(comptime T: type) type {
    return struct {
        const Self = @This();
        const NodeID = u32;
        const MAX_QUERY_STACK = 256;

        nodes: std.MultiArrayList(Node) = .{},
        root: ?NodeID = null,
        count: u32 = 0,

        pub const Entry = struct {
            val: T,
            aabb: Vec,
        };

        pub const Branch = struct {
            lower: NodeID,
            upper: NodeID,
        };

        pub const Value = union(enum) {
            leaf: T,
            branch: Branch,
        };

        pub const Node = struct {
            parent: ?NodeID = null,
            aabb: Aabb,
            value: Value,
            mask: u32 = 0,
            subtree_mask: u32 = 0,
        };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.nodes.deinit(gpa);
            self.* = .{};
        }

        pub fn clearLeaky(self: *Self) void {
            self.nodes = .{};
            self.root = null;
            self.count = 0;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.nodes.clearRetainingCapacity();
            self.root = null;
            self.count = 0;
        }

        pub fn insert(self: *Self, gpa: Allocator, bounds: Aabb, value: T, mask: u32) !void {
            const leaf_id = try self.addNode(gpa, .{
                .aabb = bounds,
                .value = .{ .leaf = value },
                .mask = mask,
                .subtree_mask = mask,
            });
            errdefer _ = self.nodes.pop();

            const root_id = self.root orelse {
                self.root = leaf_id;
                self.count += 1;
                return;
            };

            const sibling_id = self.bestPick(root_id, bounds);
            const old_parent = self.nodes.items(.parent)[sibling_id];
            const parent_id = try self.addNode(gpa, .{
                .parent = old_parent,
                .aabb = Aabb.merge(self.nodes.items(.aabb)[sibling_id], bounds),
                .value = .{ .branch = .{ .lower = sibling_id, .upper = leaf_id } },
                .subtree_mask = self.nodes.items(.subtree_mask)[sibling_id] | mask,
            });

            self.nodes.items(.parent)[sibling_id] = parent_id;
            self.nodes.items(.parent)[leaf_id] = parent_id;

            if (old_parent) |old_parent_id| {
                self.replaceChild(old_parent_id, sibling_id, parent_id);
            } else {
                self.root = parent_id;
            }

            self.refit(parent_id);
            self.count += 1;
        }

        pub fn query(self: *const Self, bounds: Aabb, values: *std.ArrayList(Entry), mask: u32) !void {
            var it = self.queryIterator(bounds, mask);
            while (try it.next()) |entry| {
                try values.appendBounded(entry);
            }
        }

        pub fn queryIterator(self: *const Self, bounds: Aabb, mask: u32) QueryIterator {
            var iter = QueryIterator{
                .tree = self,
                .bounds = bounds,
                .mask = mask,
            };
            if (self.root) |root_id| {
                iter.stack[0] = root_id;
                iter.stack_len = 1;
            }
            return iter;
        }

        pub const QueryIterator = struct {
            tree: *const Self,
            bounds: Aabb,
            mask: u32,
            stack: [MAX_QUERY_STACK]NodeID = undefined,
            stack_len: usize = 0,

            pub fn next(self: *QueryIterator) !?Entry {
                while (self.stack_len > 0) {
                    self.stack_len -= 1;
                    const id = self.stack[self.stack_len];
                    const tree_node = self.tree.getNode(id);

                    if ((tree_node.subtree_mask & self.mask) == 0) continue;
                    if (!tree_node.aabb.intersect(self.bounds)) continue;

                    switch (tree_node.value) {
                        .leaf => |val| {
                            if ((tree_node.mask & self.mask) == 0) continue;
                            return .{ .val = val, .aabb = tree_node.aabb.vec };
                        },
                        .branch => |branch| {
                            try self.pushIfQueryable(branch.upper);
                            try self.pushIfQueryable(branch.lower);
                        },
                    }
                }

                return null;
            }

            fn pushIfQueryable(self: *QueryIterator, id: NodeID) !void {
                const tree_node = self.tree.getNode(id);
                if ((tree_node.subtree_mask & self.mask) == 0) return;
                if (!tree_node.aabb.intersect(self.bounds)) return;
                if (self.stack_len >= self.stack.len) return error.QueryStackOverflow;

                self.stack[self.stack_len] = id;
                self.stack_len += 1;
            }
        };

        fn addNode(self: *Self, gpa: Allocator, new_node: Node) !NodeID {
            const id: NodeID = @intCast(self.nodes.len);
            try self.nodes.append(gpa, new_node);
            return id;
        }

        fn getNode(self: *const Self, id: NodeID) Node {
            const index: usize = @intCast(id);
            return .{
                .parent = self.nodes.items(.parent)[index],
                .aabb = self.nodes.items(.aabb)[index],
                .value = self.nodes.items(.value)[index],
                .mask = self.nodes.items(.mask)[index],
                .subtree_mask = self.nodes.items(.subtree_mask)[index],
            };
        }

        fn bestPick(self: *const Self, root_id: NodeID, bounds: Aabb) NodeID {
            var id = root_id;

            while (true) {
                switch (self.nodes.items(.value)[id]) {
                    .leaf => return id,
                    .branch => |branch| {
                        const lower_id = branch.lower;
                        const upper_id = branch.upper;
                        const lower_cost = self.insertionCost(lower_id, bounds);
                        const upper_cost = self.insertionCost(upper_id, bounds);
                        id = if (lower_cost <= upper_cost) lower_id else upper_id;
                    },
                }
            }
        }

        fn insertionCost(self: *const Self, id: NodeID, bounds: Aabb) f32 {
            const current = self.nodes.items(.aabb)[id];
            const merged = Aabb.merge(current, bounds);

            return switch (self.nodes.items(.value)[id]) {
                .leaf => merged.perimeter(),
                .branch => merged.perimeter() - current.perimeter(),
            };
        }

        fn replaceChild(self: *Self, parent_id: NodeID, old_child: NodeID, new_child: NodeID) void {
            const branch = &self.nodes.items(.value)[parent_id].branch;
            if (branch.lower == old_child) {
                branch.lower = new_child;
            } else {
                std.debug.assert(branch.upper == old_child);
                branch.upper = new_child;
            }
        }

        fn refit(self: *Self, start_id: NodeID) void {
            var current: ?NodeID = start_id;

            while (current) |id| {
                switch (self.nodes.items(.value)[id]) {
                    .leaf => {
                        self.nodes.items(.subtree_mask)[id] = self.nodes.items(.mask)[id];
                    },
                    .branch => |branch| {
                        const lower_aabb = self.nodes.items(.aabb)[branch.lower];
                        const upper_aabb = self.nodes.items(.aabb)[branch.upper];
                        self.nodes.items(.aabb)[id] = Aabb.merge(lower_aabb, upper_aabb);
                        self.nodes.items(.subtree_mask)[id] =
                            self.nodes.items(.subtree_mask)[branch.lower] |
                            self.nodes.items(.subtree_mask)[branch.upper];
                    },
                }

                current = self.nodes.items(.parent)[id];
            }
        }

        inline fn isLeaf(self: *const Self, id: NodeID) bool {
            return switch (self.nodes.items(.value)[id]) {
                .leaf => true,
                .branch => false,
            };
        }
    };
}

test "aabb tree query" {
    const gpa = std.testing.allocator;
    var tree: AabbTree(u32) = .{};
    defer tree.deinit(gpa);

    try tree.insert(gpa, Aabb.new(0, 0, 50, 50), 69, 0xFFFFFFFF);
    try tree.insert(gpa, Aabb.new(10, 0, 20, 10), 70, 0xFFFFFFFF);
    try tree.insert(gpa, Aabb.new(0, 10, 10, 20), 71, 0xFFFFFFFF);
    try tree.insert(gpa, Aabb.new(10, 10, 20, 20), 72, 0xFFFFFFFF);

    const AT = AabbTree(u32);
    var buf: [4]AT.Entry = undefined;
    var out = std.ArrayList(AT.Entry).initBuffer(&buf);

    try tree.query(Aabb.new(0, 0, 9, 15), &out, 0xFFFFFFFF);

    try std.testing.expect(out.items.len == 2);
    try expectEntry(out.items, 69);
    try expectEntry(out.items, 71);
}

test "aabb tree iterator and mask pruning" {
    const gpa = std.testing.allocator;
    var tree: AabbTree(u32) = .{};
    defer tree.deinit(gpa);

    try tree.insert(gpa, Aabb.new(0, 0, 40, 40), 10, 0x1);
    try tree.insert(gpa, Aabb.new(100, 100, 130, 130), 20, 0x2);
    try tree.insert(gpa, Aabb.new(200, 200, 230, 230), 30, 0x4);
    try tree.insert(gpa, Aabb.new(5, 5, 12, 12), 11, 0x3);

    var found: u32 = 0;
    var it = tree.queryIterator(Aabb.new(-10, -10, 150, 150), 0x1);
    while (try it.next()) |entry| {
        if (entry.val == 10 or entry.val == 11) found += 1;
    }

    try std.testing.expect(found == 2);
}

fn expectEntry(items: []const AabbTree(u32).Entry, value: u32) !void {
    for (items) |item| {
        if (item.val == value) return;
    }
    return error.MissingEntry;
}
