const std = @import("std");
const Allocator = std.mem.Allocator;
// ----------
// to stay sane
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
        query_gen: u32 = 0,
    };
}

/// Quadtree with flat backing array, inline leaf storage, generation-counter dedup.
pub fn Quadtree(
    comptime T: type,
    MINSIZE: comptime_int,
    MAXITEMS: comptime_int,
) type {
    return struct {
        const Self = @This();
        const NodeID = u32;

        const Node = struct {
            bounds: Rect,
            parent: ?NodeID = null,
            val: union(enum) {
                leaf: std.ArrayList(Slot(T)),
                branch: [4]NodeID,
            } = .{ .leaf = .empty },
        };

        count: u32 = 0,
        gen: u32 = 0,
        nodes: std.ArrayList(Node) = .empty,
        root: ?NodeID = null,

        pub fn insert(self: *Self, gpa: Allocator, bounds: Rect, value: T, mask: u32) !void {
            const root_id = self.root orelse blk: {
                const id = try self.addNode(gpa, .{
                    .bounds = .{ -1024, -1024, 1024, 1024 },
                });
                self.root = id;
                break :blk id;
            };

            try self.insertAt(gpa, bounds, value, mask, root_id, 0);
            self.count += 1;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.nodes.items) |*node| {
                switch (node.val) {
                    .leaf => |*list| list.deinit(gpa),
                    else => {},
                }
            }
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

        fn addNode(self: *Self, gpa: Allocator, node: Node) !NodeID {
            const id: NodeID = @intCast(self.nodes.items.len);
            try self.nodes.append(gpa, node);
            return id;
        }

        pub fn insertAt(self: *Self, allocator: Allocator, bounds: Rect, value: T, mask: u32, id: NodeID, depth: u32) !void {
            const node = &self.nodes.items[id];
            switch (node.val) {
                .leaf => |*leaf| {
                    const needs_split = (leaf.items.len > MAXITEMS) and ((node.bounds[2] - node.bounds[0]) > MINSIZE);
                    if (needs_split) {
                        const min_x = node.bounds[0];
                        const min_y = node.bounds[1];
                        const max_x = node.bounds[2];
                        const max_y = node.bounds[3];
                        const mid_x = (min_x + max_x) * 0.5;
                        const mid_y = (min_y + max_y) * 0.5;

                        // create 4 children in cw order
                        const c0 = try self.addNode(allocator, .{ .bounds = .{ min_x, min_y, mid_x, mid_y } }); //bottom left
                        const c1 = try self.addNode(allocator, .{ .bounds = .{ min_x, mid_y, mid_x, max_y } }); //top left
                        const c2 = try self.addNode(allocator, .{ .bounds = .{ mid_x, mid_y, max_x, max_y } }); //top right
                        const c3 = try self.addNode(allocator, .{ .bounds = .{ mid_x, min_y, max_x, mid_y } }); //bottom right

                        // re-fetch after potential realloc
                        const n = &self.nodes.items[id];

                        // set parent on children
                        self.nodes.items[c0].parent = id;
                        self.nodes.items[c1].parent = id;
                        self.nodes.items[c2].parent = id;
                        self.nodes.items[c3].parent = id;

                        // save leaf data, convert to branch
                        var old_leaf = n.val.leaf;
                        defer old_leaf.deinit(allocator);
                        n.val = .{ .branch = .{ c0, c1, c2, c3 } };

                        // re-insert old items
                        while (old_leaf.pop()) |slot| {
                            try self.insertAt(allocator, slot.aabb, slot.v, slot.mask, id, depth + 1);
                        }

                        // insert the new item that triggered the split
                        try self.insertAt(allocator, bounds, value, mask, id, depth + 1);
                        return;
                    } else {
                        try leaf.append(allocator, .{
                            .aabb = bounds,
                            .v = value,
                            .mask = mask,
                        });
                    }
                },
                .branch => {
                    const node_bounds = node.bounds;
                    const parent = node.parent;
                    const children = node.val.branch;
                    const intersections = intersect4(bounds, node_bounds);

                    // no hits at all, expand outside -> reinsert
                    if (@as(u4, @bitCast(intersections)) == 0) {
                        if (parent != null) {
                            // skip for now
                            return;
                        }
                        const min_x = node_bounds[0];
                        const min_y = node_bounds[1];
                        const max_x = node_bounds[2];
                        const max_y = node_bounds[3];
                        const width = max_x - min_x;
                        const height = max_y - min_y;

                        const dir = bounds - node_bounds;
                        const dirN = parseDir(std.math.sign(dir));

                        switch (dirN) {
                            .topRight => {
                                const new_bounds = Rect{ min_x, min_y, max_x + width, max_y + height };
                                const new_parent = try self.addNode(allocator, .{
                                    .bounds = new_bounds,
                                    .val = .{ .branch = undefined },
                                });

                                const nc1 = try self.addNode(allocator, .{ .bounds = .{ min_x, max_y, max_x, max_y + height }, .parent = new_parent });
                                const nc2 = try self.addNode(allocator, .{ .bounds = .{ max_x, max_y, max_x + width, max_y + height }, .parent = new_parent });
                                const nc3 = try self.addNode(allocator, .{ .bounds = .{ max_x, min_y, max_x + width, max_y }, .parent = new_parent });

                                self.nodes.items[id].parent = new_parent;
                                self.nodes.items[new_parent].val = .{ .branch = .{ id, nc1, nc2, nc3 } };
                                self.root = new_parent;
                                try self.insertAt(allocator, bounds, value, mask, new_parent, depth);
                            },
                            .bottomRight => {
                                const new_min_y = min_y - height;
                                const new_bounds = Rect{ min_x, new_min_y, max_x + width, max_y };
                                const new_parent = try self.addNode(allocator, .{
                                    .bounds = new_bounds,
                                    .val = .{ .branch = undefined },
                                });

                                const nc0 = try self.addNode(allocator, .{ .bounds = .{ min_x, new_min_y, max_x, min_y }, .parent = new_parent });
                                const nc2 = try self.addNode(allocator, .{ .bounds = .{ max_x, min_y, max_x + width, max_y }, .parent = new_parent });
                                const nc3 = try self.addNode(allocator, .{ .bounds = .{ max_x, new_min_y, max_x + width, min_y }, .parent = new_parent });

                                self.nodes.items[id].parent = new_parent;
                                self.nodes.items[new_parent].val = .{ .branch = .{ nc0, id, nc2, nc3 } };
                                self.root = new_parent;
                                try self.insertAt(allocator, bounds, value, mask, new_parent, depth);
                            },
                            .bottomLeft => {
                                const new_min_x = min_x - width;
                                const new_min_y = min_y - height;
                                const new_bounds = Rect{ new_min_x, new_min_y, max_x, max_y };
                                const new_parent = try self.addNode(allocator, .{
                                    .bounds = new_bounds,
                                    .val = .{ .branch = undefined },
                                });

                                const nc0 = try self.addNode(allocator, .{ .bounds = .{ new_min_x, new_min_y, min_x, min_y }, .parent = new_parent });
                                const nc1 = try self.addNode(allocator, .{ .bounds = .{ new_min_x, min_y, min_x, max_y }, .parent = new_parent });
                                const nc3 = try self.addNode(allocator, .{ .bounds = .{ min_x, new_min_y, max_x, min_y }, .parent = new_parent });

                                self.nodes.items[id].parent = new_parent;
                                self.nodes.items[new_parent].val = .{ .branch = .{ nc0, nc1, id, nc3 } };
                                self.root = new_parent;
                                try self.insertAt(allocator, bounds, value, mask, new_parent, depth);
                            },
                            .topLeft => {
                                const new_min_x = min_x - width;
                                const new_bounds = Rect{ new_min_x, min_y, max_x, max_y + height };
                                const new_parent = try self.addNode(allocator, .{
                                    .bounds = new_bounds,
                                    .val = .{ .branch = undefined },
                                });

                                const nc0 = try self.addNode(allocator, .{ .bounds = .{ new_min_x, min_y, min_x, max_y }, .parent = new_parent });
                                const nc1 = try self.addNode(allocator, .{ .bounds = .{ new_min_x, max_y, min_x, max_y + height }, .parent = new_parent });
                                const nc2 = try self.addNode(allocator, .{ .bounds = .{ min_x, max_y, max_x, max_y + height }, .parent = new_parent });

                                self.nodes.items[id].parent = new_parent;
                                self.nodes.items[new_parent].val = .{ .branch = .{ nc0, nc1, nc2, id } };
                                self.root = new_parent;
                                try self.insertAt(allocator, bounds, value, mask, new_parent, depth);
                            },
                        }
                    } else {
                        if (intersections[0]) try self.insertAt(allocator, bounds, value, mask, children[0], depth + 1);
                        if (intersections[1]) try self.insertAt(allocator, bounds, value, mask, children[1], depth + 1);
                        if (intersections[2]) try self.insertAt(allocator, bounds, value, mask, children[2], depth + 1);
                        if (intersections[3]) try self.insertAt(allocator, bounds, value, mask, children[3], depth + 1);
                    }
                },
            }
        }

        pub const Filter = struct {
            const FilterFn = *const fn (filter: *const Filter, *const T) bool;
            ctx: ?*anyopaque = null,
            func: ?FilterFn = null,
        };

        pub const Entry = struct {
            val: T,
            aabb: Vec,
        };

        pub fn query(self: *Self, aabb: Rect, values: *std.ArrayList(Entry), mask: u32) !void {
            const id = self.root orelse return error.EmptyTree;
            self.gen +%= 1;
            self.queryImpl(id, aabb, values, mask, .{});
        }

        pub fn queryFiltered(self: *Self, aabb: Rect, depth: *u32, values: *std.ArrayList(Entry), mask: u32, filter: Filter) !void {
            const id = self.root orelse return error.EmptyTree;
            self.gen +%= 1;
            self.queryImpl(id, aabb, values, mask, filter);
            depth.* = 0; // depth is not tracked in iterative version, kept for API compat
        }

        /// Iterative query with explicit stack. Max depth ~10 levels (2048/MINSIZE),
        /// stack holds up to 4 children per level.
        fn queryImpl(self: *Self, start: NodeID, aabb: Rect, values: *std.ArrayList(Entry), mask: u32, filter: Filter) void {
            const MAX_STACK = 128;
            var stack: [MAX_STACK]NodeID = undefined;
            var sp: u32 = 1;
            stack[0] = start;

            const current_gen = self.gen;

            while (sp > 0) {
                sp -= 1;
                const id = stack[sp];
                const node = &self.nodes.items[id];

                switch (node.val) {
                    .leaf => |*leaf| {
                        for (leaf.items) |*slot| {
                            if (!intersect(slot.aabb, aabb)) continue;
                            if ((slot.mask & mask) == 0) continue;
                            if (filter.func) |func| if (!func(&filter, &slot.v)) continue;
                            if (slot.query_gen == current_gen) continue;
                            slot.query_gen = current_gen;

                            values.appendBounded(.{
                                .val = slot.v,
                                .aabb = slot.aabb,
                            }) catch return;
                        }
                    },
                    .branch => |children| {
                        const res = intersect4(aabb, node.bounds);
                        // push in reverse order so index 0 is processed first
                        if (res[3] and sp < MAX_STACK) {
                            stack[sp] = children[3];
                            sp += 1;
                        }
                        if (res[2] and sp < MAX_STACK) {
                            stack[sp] = children[2];
                            sp += 1;
                        }
                        if (res[1] and sp < MAX_STACK) {
                            stack[sp] = children[1];
                            sp += 1;
                        }
                        if (res[0] and sp < MAX_STACK) {
                            stack[sp] = children[0];
                            sp += 1;
                        }
                    },
                }
            }
        }

        pub fn raycast(self: *Self, gpa: Allocator, ray_start: Vec, ray_end: Vec, values: *std.ArrayList(T), mask: u32) !void {
            const id = self.root orelse return error.EmptyTree;
            self.gen +%= 1;
            try self.raycastAt(gpa, id, ray_start, ray_end, values, mask);
        }

        pub fn raycastAt(self: *Self, gpa: Allocator, id: NodeID, ray_start: Vec, ray_end: Vec, values: *std.ArrayList(T), mask: u32) !void {
            const node = &self.nodes.items[id];

            if (!rayIntersectsRect(ray_start, ray_end, node.bounds)) {
                return;
            }

            switch (node.val) {
                .leaf => |*leaf| {
                    const current_gen = self.gen;
                    for (leaf.items) |*slot| {
                        if (!rayIntersectsRect(ray_start, ray_end, slot.aabb)) continue;
                        if ((slot.mask & mask) == 0) continue;
                        if (slot.query_gen == current_gen) continue;
                        slot.query_gen = current_gen;
                        try values.append(gpa, slot.v);
                    }
                    return;
                },
                .branch => |children| {
                    const dx = ray_end[0] - ray_start[0];
                    const dy = ray_end[1] - ray_start[1];

                    if (@abs(dx) > @abs(dy)) {
                        if (dx > 0) {
                            try self.raycastAt(gpa, children[0], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[3], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[1], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[2], ray_start, ray_end, values, mask);
                        } else {
                            try self.raycastAt(gpa, children[1], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[2], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[0], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[3], ray_start, ray_end, values, mask);
                        }
                    } else {
                        if (dy > 0) {
                            try self.raycastAt(gpa, children[0], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[1], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[3], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[2], ray_start, ray_end, values, mask);
                        } else {
                            try self.raycastAt(gpa, children[1], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[2], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[0], ray_start, ray_end, values, mask);
                            try self.raycastAt(gpa, children[3], ray_start, ray_end, values, mask);
                        }
                    }
                },
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

inline fn parseDir(vec: Vec) Direction {
    if (vec[0] < -0.5 and vec[1] < -0.5) return Direction.bottomLeft;
    if (vec[0] < -0.5 and vec[1] > 0.5) return Direction.topLeft;
    if (vec[0] > 0.5 and vec[1] > 0.5) return Direction.topRight;
    if (vec[0] > 0.5 and vec[1] < -0.5) return Direction.bottomRight;

    return Direction.topLeft;
}

const Direction = enum {
    bottomLeft,
    topLeft,
    topRight,
    bottomRight,
};

/// quadtree 4x intersect in cw
/// rect layout: {min_x, min_y, max_x, max_y}
pub inline fn intersect4(query_rect: Rect, area: Rect) @Vector(4, bool) {
    const min_x = area[0];
    const min_y = area[1];
    const max_x = area[2];
    const max_y = area[3];
    const mid_x = (min_x + max_x) * 0.5;
    const mid_y = (min_y + max_y) * 0.5;

    const min_x_group = Vec{ min_x, min_x, mid_x, mid_x };
    const min_y_group = Vec{ min_y, mid_y, mid_y, min_y };
    const max_x_group = Vec{ mid_x, mid_x, max_x, max_x };
    const max_y_group = Vec{ mid_y, max_y, max_y, mid_y };

    const query_min_x = vecs(query_rect[0]);
    const query_min_y = vecs(query_rect[1]);
    const query_max_x = vecs(query_rect[2]);
    const query_max_y = vecs(query_rect[3]);

    const c1 = query_min_x < max_x_group;
    const c2 = query_max_x > min_x_group;
    const c3 = query_min_y < max_y_group;
    const c4 = query_max_y > min_y_group;

    return c1 & c2 & c3 & c4;
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

    for (0..100) |_| {
        try qtree.insert(gpa, .{ 0, 0, 50, 50 }, 69, 0xFFFFFFFF);
        try qtree.insert(gpa, .{ 10, 0, 20, 10 }, 70, 0xFFFFFFFF);
        try qtree.insert(gpa, .{ 0, 10, 10, 20 }, 71, 0xFFFFFFFF);
        try qtree.insert(gpa, .{ 10, 10, 20, 20 }, 72, 0xFFFFFFFF);
    }

    const QT = Quadtree(u32, 8, 4);
    var buf: [256]QT.Entry = undefined;
    var out = std.ArrayList(QT.Entry).initBuffer(&buf);

    try qtree.query(.{ 0, 0, 9, 15 }, &out, 0xFFFFFFFF);

    std.debug.print("\nquery results: {d}\n", .{out.items.len});
    // should find all 4 unique values (69 spans entire area, others overlap the query)
    try std.testing.expect(out.items.len > 0);
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

    // Ray at y=15 intersects items 1, 2, 3 (all at y: 10-20)
    try std.testing.expect(out.items.len == 3);
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{1}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{2}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{3}));

    out.clearRetainingCapacity();

    const ray_start2 = Vec{ 15, 0, 0, 0 };
    const ray_end2 = Vec{ 15, 40, 0, 0 };
    try qtree.raycast(gpa, ray_start2, ray_end2, &out, 0xFFFFFFFF);

    // Ray at x=15 intersects items 1 (x: 10-20, y: 10-20) and 4 (x: 10-20, y: 30-40)
    try std.testing.expect(out.items.len == 2);
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{1}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{4}));

    out.clearRetainingCapacity();

    const ray_start3 = Vec{ 0, 0, 0, 0 };
    const ray_end3 = Vec{ 5, 5, 0, 0 };
    try qtree.raycast(gpa, ray_start3, ray_end3, &out, 0xFFFFFFFF);

    try std.testing.expect(out.items.len == 0);
}
