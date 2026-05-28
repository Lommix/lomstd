const std = @import("std");
const Allocator = std.mem.Allocator;

const Rect = @Vector(4, f32);
const Vec = @Vector(4, f32);

fn vecs(val: f32) Vec {
    return @splat(val);
}

pub fn Slot(comptime T: type) type {
    return struct {
        aabb: Rect,
        v: T,
        mask: u32,
    };
}

/// Quadtree with flat backing arrays, dense item storage, inline node ID buffers,
/// and subtree mask pruning.
pub fn Quadtree(
    comptime T: type,
    MINSIZE: comptime_int,
    MAXITEMS: comptime_int,
) type {
    return struct {
        const Self = @This();
        const NodeID = u32;
        const ItemID = u32;

        comptime {
            if (MAXITEMS == 0) @compileError("MAXITEMS must be greater than zero");
        }

        const Node = struct {
            bounds: Rect,
            parent: ?NodeID = null,
            children: ?[4]NodeID = null,
            subtree_mask: u32 = 0,
            ids: [MAXITEMS]ItemID = undefined,
            ids_len: u32 = 0,
        };

        count: u32 = 0,
        nodes: std.ArrayList(Node) = .empty,
        items: std.ArrayList(Slot(T)) = .empty,
        root: ?NodeID = null,

        pub const Filter = struct {
            const FilterFn = *const fn (filter: *const Filter, *const T) bool;
            ctx: ?*anyopaque = null,
            func: ?FilterFn = null,
        };

        pub const Entry = struct {
            val: T,
            aabb: Vec,
        };

        pub fn insert(self: *Self, gpa: Allocator, bounds: Rect, value: T, mask: u32) !void {
            _ = self.root orelse blk: {
                const id = try self.addNode(gpa, .{
                    .bounds = .{ -1024, -1024, 1024, 1024 },
                });
                self.root = id;
                break :blk id;
            };
            const root_id = try self.ensureRootContains(gpa, bounds);

            const item_id: ItemID = @intCast(self.items.items.len);
            try self.items.append(gpa, .{
                .aabb = bounds,
                .v = value,
                .mask = mask,
            });
            errdefer _ = self.items.pop();
            try self.insertItem(gpa, item_id, root_id);
            self.count += 1;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.nodes.deinit(gpa);
            self.items.deinit(gpa);
            self.* = .{};
        }

        pub fn clearLeaky(self: *Self) void {
            self.nodes = .empty;
            self.items = .empty;
            self.root = null;
            self.count = 0;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.nodes.clearRetainingCapacity();
            self.items.clearRetainingCapacity();
            self.root = null;
            self.count = 0;
        }

        fn addNode(self: *Self, gpa: Allocator, node: Node) !NodeID {
            const id: NodeID = @intCast(self.nodes.items.len);
            try self.nodes.append(gpa, node);
            return id;
        }

        fn ensureRootContains(self: *Self, gpa: Allocator, bounds: Rect) !NodeID {
            var root_id = self.root.?;
            while (!contains(self.nodes.items[root_id].bounds, bounds)) {
                try self.growRootToward(gpa, bounds);
                root_id = self.root.?;
            }
            return root_id;
        }

        fn growRootToward(self: *Self, gpa: Allocator, bounds: Rect) !void {
            const old_root = self.root.?;
            const old_bounds = self.nodes.items[old_root].bounds;
            const min_x = old_bounds[0];
            const min_y = old_bounds[1];
            const max_x = old_bounds[2];
            const max_y = old_bounds[3];
            const width = max_x - min_x;
            const height = max_y - min_y;
            const center_x = (min_x + max_x) * 0.5;
            const center_y = (min_y + max_y) * 0.5;
            const item_center_x = (bounds[0] + bounds[2]) * 0.5;
            const item_center_y = (bounds[1] + bounds[3]) * 0.5;

            const grow_right = if (bounds[2] > max_x) true else if (bounds[0] < min_x) false else item_center_x >= center_x;
            const grow_up = if (bounds[3] > max_y) true else if (bounds[1] < min_y) false else item_center_y >= center_y;

            const new_min_x = if (grow_right) min_x else min_x - width;
            const new_max_x = if (grow_right) max_x + width else max_x;
            const new_min_y = if (grow_up) min_y else min_y - height;
            const new_max_y = if (grow_up) max_y + height else max_y;
            const mid_x = (new_min_x + new_max_x) * 0.5;
            const mid_y = (new_min_y + new_max_y) * 0.5;

            const child_bounds = [4]Rect{
                .{ new_min_x, new_min_y, mid_x, mid_y },
                .{ new_min_x, mid_y, mid_x, new_max_y },
                .{ mid_x, mid_y, new_max_x, new_max_y },
                .{ mid_x, new_min_y, new_max_x, mid_y },
            };
            const old_child_index: usize = if (grow_right)
                if (grow_up) 0 else 1
            else if (grow_up)
                3
            else
                2;

            const new_root = try self.addNode(gpa, .{
                .bounds = .{ new_min_x, new_min_y, new_max_x, new_max_y },
                .subtree_mask = self.nodes.items[old_root].subtree_mask,
            });

            var children: [4]NodeID = undefined;
            inline for (0..4) |i| {
                if (i == old_child_index) {
                    children[i] = old_root;
                } else {
                    children[i] = try self.addNode(gpa, .{
                        .bounds = child_bounds[i],
                        .parent = new_root,
                    });
                }
            }

            self.nodes.items[old_root].parent = new_root;
            self.nodes.items[new_root].children = children;
            self.root = new_root;
        }

        fn appendToNode(self: *Self, id: NodeID, item_id: ItemID) !void {
            var node = &self.nodes.items[id];
            if (node.ids_len >= MAXITEMS) return error.CapacityReached;
            node.ids[node.ids_len] = item_id;
            node.ids_len += 1;
        }

        fn nodeItemCount(self: *const Self, id: NodeID) u32 {
            const node = &self.nodes.items[id];
            return node.ids_len;
        }

        fn childIndexContaining(self: *const Self, id: NodeID, bounds: Rect) ?usize {
            const children = self.nodes.items[id].children orelse return null;

            inline for (0..4) |i| {
                if (contains(self.nodes.items[children[i]].bounds, bounds)) return i;
            }

            return null;
        }

        fn split(self: *Self, gpa: Allocator, id: NodeID) anyerror!void {
            const node_bounds = self.nodes.items[id].bounds;
            const min_x = node_bounds[0];
            const min_y = node_bounds[1];
            const max_x = node_bounds[2];
            const max_y = node_bounds[3];
            const mid_x = (min_x + max_x) * 0.5;
            const mid_y = (min_y + max_y) * 0.5;

            const c0 = try self.addNode(gpa, .{ .bounds = .{ min_x, min_y, mid_x, mid_y }, .parent = id });
            const c1 = try self.addNode(gpa, .{ .bounds = .{ min_x, mid_y, mid_x, max_y }, .parent = id });
            const c2 = try self.addNode(gpa, .{ .bounds = .{ mid_x, mid_y, max_x, max_y }, .parent = id });
            const c3 = try self.addNode(gpa, .{ .bounds = .{ mid_x, min_y, max_x, mid_y }, .parent = id });

            const old_ids = self.nodes.items[id].ids;
            const old_ids_len: usize = @intCast(self.nodes.items[id].ids_len);

            self.nodes.items[id].children = .{ c0, c1, c2, c3 };
            self.nodes.items[id].subtree_mask = 0;
            self.nodes.items[id].ids_len = 0;

            for (old_ids[0..old_ids_len]) |item_id| {
                try self.insertItem(gpa, item_id, id);
            }
        }

        fn insertItem(self: *Self, gpa: Allocator, item_id: ItemID, id: NodeID) anyerror!void {
            const item = self.items.items[item_id];

            if (self.nodes.items[id].children) |children| {
                if (self.childIndexContaining(id, item.aabb)) |child_index| {
                    try self.insertItem(gpa, item_id, children[child_index]);
                    self.nodes.items[id].subtree_mask |= item.mask;
                    return;
                }

                try self.appendToNode(id, item_id);
                self.nodes.items[id].subtree_mask |= item.mask;
                return;
            }

            const bounds = self.nodes.items[id].bounds;
            const can_split = (bounds[2] - bounds[0]) > MINSIZE and (bounds[3] - bounds[1]) > MINSIZE;
            if (self.nodeItemCount(id) >= MAXITEMS) {
                if (!can_split) return error.CapacityReached;
                try self.split(gpa, id);
                try self.insertItem(gpa, item_id, id);
                return;
            }

            try self.appendToNode(id, item_id);
            self.nodes.items[id].subtree_mask |= item.mask;
        }

        pub fn query(self: *const Self, aabb: Rect, values: *std.ArrayList(Entry), mask: u32) !void {
            const id = self.root orelse return error.EmptyTree;
            try self.queryImpl(id, aabb, values, mask, .{});
        }

        pub fn queryFiltered(self: *const Self, aabb: Rect, depth: *u32, values: *std.ArrayList(Entry), mask: u32, filter: Filter) !void {
            const id = self.root orelse return error.EmptyTree;
            try self.queryImpl(id, aabb, values, mask, filter);
            depth.* = 0; // depth is not tracked in iterative version, kept for API compat
        }

        fn queryImpl(self: *const Self, start: NodeID, aabb: Rect, values: *std.ArrayList(Entry), mask: u32, filter: Filter) !void {
            const MAX_STACK = 128;
            var stack: [MAX_STACK]NodeID = undefined;
            var sp: u32 = 1;
            stack[0] = start;

            while (sp > 0) {
                sp -= 1;
                const id = stack[sp];
                const node = &self.nodes.items[id];
                if ((node.subtree_mask & mask) == 0) continue;

                const ids_len: usize = @intCast(node.ids_len);
                try self.queryNodeItems(node.ids[0..ids_len], aabb, values, mask, filter);

                if (node.children) |children| {
                    if (self.shouldQueryChild(children[3], aabb, mask) and sp < MAX_STACK) {
                        stack[sp] = children[3];
                        sp += 1;
                    }
                    if (self.shouldQueryChild(children[2], aabb, mask) and sp < MAX_STACK) {
                        stack[sp] = children[2];
                        sp += 1;
                    }
                    if (self.shouldQueryChild(children[1], aabb, mask) and sp < MAX_STACK) {
                        stack[sp] = children[1];
                        sp += 1;
                    }
                    if (self.shouldQueryChild(children[0], aabb, mask) and sp < MAX_STACK) {
                        stack[sp] = children[0];
                        sp += 1;
                    }
                }
            }
        }

        fn queryNodeItems(self: *const Self, ids: []const ItemID, aabb: Rect, values: *std.ArrayList(Entry), mask: u32, filter: Filter) !void {
            for (ids) |item_id| {
                const slot = &self.items.items[item_id];
                if ((slot.mask & mask) == 0) continue;
                if (!intersect(slot.aabb, aabb)) continue;
                if (filter.func) |func| if (!func(&filter, &slot.v)) continue;

                try values.appendBounded(.{
                    .val = slot.v,
                    .aabb = slot.aabb,
                });
            }
        }

        fn shouldQueryChild(self: *const Self, id: NodeID, aabb: Rect, mask: u32) bool {
            const node = &self.nodes.items[id];
            return (node.subtree_mask & mask) != 0 and intersect(node.bounds, aabb);
        }

        pub fn raycast(self: *const Self, gpa: Allocator, ray_start: Vec, ray_end: Vec, values: *std.ArrayList(T), mask: u32) !void {
            const id = self.root orelse return error.EmptyTree;
            try self.raycastAt(gpa, id, ray_start, ray_end, values, mask);
        }

        pub fn raycastAt(self: *const Self, gpa: Allocator, id: NodeID, ray_start: Vec, ray_end: Vec, values: *std.ArrayList(T), mask: u32) anyerror!void {
            const node = &self.nodes.items[id];
            if ((node.subtree_mask & mask) == 0) return;

            const ids_len: usize = @intCast(node.ids_len);
            try self.raycastNodeItems(gpa, node.ids[0..ids_len], ray_start, ray_end, values, mask);

            const children = node.children orelse return;
            const dx = ray_end[0] - ray_start[0];
            const dy = ray_end[1] - ray_start[1];

            if (@abs(dx) > @abs(dy)) {
                if (dx > 0) {
                    try self.raycastChild(gpa, children[0], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[3], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[1], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[2], ray_start, ray_end, values, mask);
                } else {
                    try self.raycastChild(gpa, children[1], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[2], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[0], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[3], ray_start, ray_end, values, mask);
                }
            } else {
                if (dy > 0) {
                    try self.raycastChild(gpa, children[0], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[1], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[3], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[2], ray_start, ray_end, values, mask);
                } else {
                    try self.raycastChild(gpa, children[1], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[2], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[0], ray_start, ray_end, values, mask);
                    try self.raycastChild(gpa, children[3], ray_start, ray_end, values, mask);
                }
            }
        }

        fn raycastChild(self: *const Self, gpa: Allocator, id: NodeID, ray_start: Vec, ray_end: Vec, values: *std.ArrayList(T), mask: u32) anyerror!void {
            const node = &self.nodes.items[id];
            if ((node.subtree_mask & mask) == 0) return;
            if (!rayIntersectsRect(ray_start, ray_end, node.bounds)) return;
            try self.raycastAt(gpa, id, ray_start, ray_end, values, mask);
        }

        fn raycastNodeItems(self: *const Self, gpa: Allocator, ids: []const ItemID, ray_start: Vec, ray_end: Vec, values: *std.ArrayList(T), mask: u32) !void {
            for (ids) |item_id| {
                const slot = &self.items.items[item_id];
                if ((slot.mask & mask) == 0) continue;
                if (!rayIntersectsRect(ray_start, ray_end, slot.aabb)) continue;
                try values.append(gpa, slot.v);
            }
        }

        /// Access all nodes (for debug rendering etc.)
        pub fn nodeSlice(self: *const Self) []const Node {
            return self.nodes.items;
        }
    };
}

pub inline fn intersect(a: Rect, b: Rect) bool {
    const x_overlap = a[0] < b[2] and a[2] > b[0];
    const y_overlap = a[1] < b[3] and a[3] > b[1];
    return x_overlap and y_overlap;
}

pub inline fn contains(container: Rect, item: Rect) bool {
    return item[0] >= container[0] and item[1] >= container[1] and
        item[2] <= container[2] and item[3] <= container[3];
}

pub inline fn rayIntersectsRect(ray_start: Vec, ray_end: Vec, rect: Rect) bool {
    const dx = ray_end[0] - ray_start[0];
    const dy = ray_end[1] - ray_start[1];

    if (dx == 0 and dy == 0) return false;

    const rect_min = Vec{ rect[0], rect[1], 0, 0 };
    const rect_max = Vec{ rect[2], rect[3], 0, 0 };

    const inv_dx = if (dx != 0) 1.0 / dx else std.math.inf(f32);
    const inv_dy = if (dy != 0) 1.0 / dy else std.math.inf(f32);

    const t1 = (rect_min[0] - ray_start[0]) * inv_dx;
    const t2 = (rect_max[0] - ray_start[0]) * inv_dx;
    const t3 = (rect_min[1] - ray_start[1]) * inv_dy;
    const t4 = (rect_max[1] - ray_start[1]) * inv_dy;

    const tmin = @max(@min(t1, t2), @min(t3, t4));
    const tmax = @min(@max(t1, t2), @max(t3, t4));

    return tmax >= 0 and tmin <= tmax and tmin <= 1.0;
}

test "quadtree" {
    const gpa = std.testing.allocator;
    var qtree: Quadtree(u32, 8, 4) = .{};
    defer qtree.deinit(std.testing.allocator);

    try qtree.insert(gpa, .{ 0, 0, 50, 50 }, 69, 0xFFFFFFFF);
    try qtree.insert(gpa, .{ 10, 0, 20, 10 }, 70, 0xFFFFFFFF);
    try qtree.insert(gpa, .{ 0, 10, 10, 20 }, 71, 0xFFFFFFFF);
    try qtree.insert(gpa, .{ 10, 10, 20, 20 }, 72, 0xFFFFFFFF);

    const QT = Quadtree(u32, 8, 4);
    var buf: [4]QT.Entry = undefined;
    var out = std.ArrayList(QT.Entry).initBuffer(&buf);

    try qtree.query(.{ 0, 0, 9, 15 }, &out, 0xFFFFFFFF);

    std.debug.print("\nquery results: {d}\n", .{out.items.len});
    try std.testing.expect(out.items.len == 2);
}

test "quadtree insert returns CapacityReached at minimum leaf size" {
    const gpa = std.testing.allocator;
    var qtree: Quadtree(u32, 2048, 2) = .{};
    defer qtree.deinit(gpa);

    try qtree.insert(gpa, .{ 0, 0, 10, 10 }, 1, 0xFFFFFFFF);
    try qtree.insert(gpa, .{ 20, 20, 30, 30 }, 2, 0xFFFFFFFF);
    try std.testing.expectError(error.CapacityReached, qtree.insert(gpa, .{ 40, 40, 50, 50 }, 3, 0xFFFFFFFF));
    try std.testing.expect(qtree.count == 2);
    try std.testing.expect(qtree.items.items.len == 2);
}

test "quadtree raycast" {
    const gpa = std.testing.allocator;
    var qtree: Quadtree(u32, 8, 4) = .{};
    defer qtree.deinit(gpa);

    try qtree.insert(gpa, .{ 10, 10, 20, 20 }, 1, 0xFFFFFFFF);
    try qtree.insert(gpa, .{ 30, 10, 40, 20 }, 2, 0xFFFFFFFF);
    try qtree.insert(gpa, .{ 50, 10, 60, 20 }, 3, 0xFFFFFFFF);
    try qtree.insert(gpa, .{ 10, 30, 20, 40 }, 4, 0xFFFFFFFF);
    try qtree.insert(gpa, .{ 100, 100, 110, 110 }, 5, 0xFFFFFFFF);

    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);

    const ray_start = Vec{ 0, 15, 0, 0 };
    const ray_end = Vec{ 60, 15, 0, 0 };
    try qtree.raycast(gpa, ray_start, ray_end, &out, 0xFFFFFFFF);

    try std.testing.expect(out.items.len == 3);
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{1}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{2}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{3}));

    out.clearRetainingCapacity();

    const ray_start2 = Vec{ 15, 0, 0, 0 };
    const ray_end2 = Vec{ 15, 40, 0, 0 };
    try qtree.raycast(gpa, ray_start2, ray_end2, &out, 0xFFFFFFFF);

    try std.testing.expect(out.items.len == 2);
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{1}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{4}));

    out.clearRetainingCapacity();

    const ray_start3 = Vec{ 0, 0, 0, 0 };
    const ray_end3 = Vec{ 5, 5, 0, 0 };
    try qtree.raycast(gpa, ray_start3, ray_end3, &out, 0xFFFFFFFF);

    try std.testing.expect(out.items.len == 0);
}

test "quadtree wraps root when inserting outside current bounds" {
    const gpa = std.testing.allocator;
    var qtree: Quadtree(u32, 8, 4) = .{};
    defer qtree.deinit(gpa);

    try qtree.insert(gpa, .{ 0, 0, 10, 10 }, 1, 0xFFFFFFFF);
    const old_root = qtree.root.?;
    const old_bounds = qtree.nodes.items[old_root].bounds;

    try qtree.insert(gpa, .{ 1500, 1500, 1510, 1510 }, 2, 0xFFFFFFFF);

    const new_root = qtree.root.?;
    try std.testing.expect(new_root != old_root);
    try std.testing.expect(qtree.nodes.items[old_root].parent == new_root);
    try std.testing.expect(qtree.nodes.items[new_root].children != null);
    try std.testing.expect(contains(qtree.nodes.items[new_root].bounds, old_bounds));
    try std.testing.expect(contains(qtree.nodes.items[new_root].bounds, .{ 1500, 1500, 1510, 1510 }));

    const children = qtree.nodes.items[new_root].children.?;
    try std.testing.expect(children[0] == old_root);

    const QT = Quadtree(u32, 8, 4);
    var buf: [4]QT.Entry = undefined;
    var out = std.ArrayList(QT.Entry).initBuffer(&buf);

    try qtree.query(.{ 1490, 1490, 1520, 1520 }, &out, 0xFFFFFFFF);
    try std.testing.expect(out.items.len == 1);
    try expectEntry(out.items, 2);
}

test "quadtree repeatedly wraps root across directions" {
    const gpa = std.testing.allocator;
    var qtree: Quadtree(u32, 8, 2) = .{};
    defer qtree.deinit(gpa);

    try qtree.insert(gpa, .{ 0, 0, 10, 10 }, 1, 0x1);
    try qtree.insert(gpa, .{ 6000, 6000, 6010, 6010 }, 2, 0x2);
    try qtree.insert(gpa, .{ -7000, -7000, -6990, -6990 }, 3, 0x4);
    try qtree.insert(gpa, .{ -9000, 8000, -8990, 8010 }, 4, 0x8);

    const root_bounds = qtree.nodes.items[qtree.root.?].bounds;
    try std.testing.expect(contains(root_bounds, .{ 0, 0, 10, 10 }));
    try std.testing.expect(contains(root_bounds, .{ 6000, 6000, 6010, 6010 }));
    try std.testing.expect(contains(root_bounds, .{ -7000, -7000, -6990, -6990 }));
    try std.testing.expect(contains(root_bounds, .{ -9000, 8000, -8990, 8010 }));

    const QT = Quadtree(u32, 8, 2);
    var buf: [4]QT.Entry = undefined;
    var out = std.ArrayList(QT.Entry).initBuffer(&buf);

    try qtree.query(.{ -10000, -10000, 7000, 9000 }, &out, 0xFFFFFFFF);
    try std.testing.expect(out.items.len == 4);
    try expectEntry(out.items, 1);
    try expectEntry(out.items, 2);
    try expectEntry(out.items, 3);
    try expectEntry(out.items, 4);
}

test "quadtree query mask pruning" {
    const gpa = std.testing.allocator;
    var qtree: Quadtree(u32, 8, 2) = .{};
    defer qtree.deinit(gpa);

    const layer_a: u32 = 0x1;
    const layer_b: u32 = 0x2;
    const layer_c: u32 = 0x4;

    try qtree.insert(gpa, .{ 0, 0, 40, 40 }, 10, layer_a);
    try qtree.insert(gpa, .{ 100, 100, 130, 130 }, 20, layer_b);
    try qtree.insert(gpa, .{ 200, 200, 230, 230 }, 30, layer_c);
    try qtree.insert(gpa, .{ 5, 5, 12, 12 }, 11, layer_a | layer_b);

    const QT = Quadtree(u32, 8, 2);
    var buf: [8]QT.Entry = undefined;
    var out = std.ArrayList(QT.Entry).initBuffer(&buf);

    try qtree.query(.{ -10, -10, 150, 150 }, &out, layer_a);
    try std.testing.expect(out.items.len == 2);
    try expectEntry(out.items, 10);
    try expectEntry(out.items, 11);

    out.clearRetainingCapacity();
    try qtree.query(.{ -10, -10, 150, 150 }, &out, layer_b);
    try std.testing.expect(out.items.len == 2);
    try expectEntry(out.items, 20);
    try expectEntry(out.items, 11);

    out.clearRetainingCapacity();
    try qtree.query(.{ -10, -10, 150, 150 }, &out, layer_c);
    try std.testing.expect(out.items.len == 0);

    out.clearRetainingCapacity();
    try qtree.query(.{ -10, -10, 250, 250 }, &out, layer_a | layer_c);
    try std.testing.expect(out.items.len == 3);
    try expectEntry(out.items, 10);
    try expectEntry(out.items, 11);
    try expectEntry(out.items, 30);

    out.clearRetainingCapacity();
    try qtree.query(.{ -10, -10, 250, 250 }, &out, 0x80);
    try std.testing.expect(out.items.len == 0);
}

test "quadtree raycast mask pruning" {
    const gpa = std.testing.allocator;
    var qtree: Quadtree(u32, 8, 2) = .{};
    defer qtree.deinit(gpa);

    const layer_a: u32 = 0x1;
    const layer_b: u32 = 0x2;
    const layer_c: u32 = 0x4;

    try qtree.insert(gpa, .{ 10, 10, 20, 20 }, 1, layer_a);
    try qtree.insert(gpa, .{ 30, 10, 40, 20 }, 2, layer_b);
    try qtree.insert(gpa, .{ 50, 10, 60, 20 }, 3, layer_a | layer_b);
    try qtree.insert(gpa, .{ 10, 30, 20, 40 }, 4, layer_c);

    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);

    const ray_start = Vec{ 0, 15, 0, 0 };
    const ray_end = Vec{ 70, 15, 0, 0 };

    try qtree.raycast(gpa, ray_start, ray_end, &out, layer_a);
    try std.testing.expect(out.items.len == 2);
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{1}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{3}));

    out.clearRetainingCapacity();
    try qtree.raycast(gpa, ray_start, ray_end, &out, layer_b);
    try std.testing.expect(out.items.len == 2);
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{2}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{3}));

    out.clearRetainingCapacity();
    try qtree.raycast(gpa, ray_start, ray_end, &out, layer_c);
    try std.testing.expect(out.items.len == 0);

    out.clearRetainingCapacity();
    try qtree.raycast(gpa, ray_start, ray_end, &out, 0x80);
    try std.testing.expect(out.items.len == 0);
}

fn expectEntry(items: []const Quadtree(u32, 8, 2).Entry, value: u32) !void {
    for (items) |item| {
        if (item.val == value) return;
    }
    return error.MissingEntry;
}
