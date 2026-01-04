const std = @import("std");
const tree = @import("tree.zig");
const Allocator = std.mem.Allocator;
// ----------
// to stay sane
const Rect = @Vector(4, f32);
const Vec = @Vector(4, f32);
fn vecs(val: f32) Vec {
    return @splat(val);
}

pub fn Node(comptime T: type) type {
    return struct {
        bounds: Rect, // todo vec align
        val: union(enum) {
            leaf: std.ArrayList(Slot(T)),
            branch,
        } = .{ .leaf = .{} },
    };
}

pub fn Slot(comptime T: type) type {
    return struct {
        aabb: Rect,
        v: T,
        mask: u32,
    };
}

const Direction = enum {
    bottomLeft,
    topLeft,
    topRight,
    bottomRight,
};

/// Quadtree
pub fn Quadtree(
    comptime T: type,
    comptime CMP: fn (a: T, b: T) bool,
    MINSIZE: comptime_int,
    MAXITEMS: comptime_int,
) type {
    return struct {
        const Tree = tree.MultiTree(Node(T));
        const Self = @This();

        count: u32 = 0,
        tree: Tree = .{},
        root: ?Tree.NodeID = null,

        pub fn insert(self: *Self, gpa: Allocator, bounds: Rect, value: T, mask: u32) !void {
            const root = self.root orelse blk: {
                const id = try self.tree.root(gpa, Node(T){
                    .bounds = .{ -1024, -1024, 1024, 1024 },
                });
                self.root = id;
                break :blk id;
            };

            try self.insertAt(gpa, bounds, value, mask, root, 0);
            self.count += 1;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (self.tree.values()) |*node| {
                switch (node.val) {
                    .leaf => |*list| list.deinit(gpa),
                    else => {},
                }
            }

            self.tree.deinit(gpa);
            self.* = .{};
        }

        pub fn clearLeaky(self: *Self) void {
            self.tree = .{};
            self.root = null;
            self.count = 0;
        }

        pub fn insertAt(self: *Self, allocator: Allocator, bounds: Rect, value: T, mask: u32, id: Tree.NodeID, depth: u32) !void {
            const node = self.tree.getValue(id);
            const intersecs = intersect4(bounds, node.bounds);

            // has children or leaf?
            switch (node.val) {
                .leaf => |*ar| {
                    const needs_split = (ar.items.len > MAXITEMS) and ((node.bounds[2] - node.bounds[0]) > MINSIZE); // or depth < 6;
                    // const needs_split = depth < 5;

                    if (needs_split) {
                        const min_x = node.bounds[0];
                        const min_y = node.bounds[1];
                        const max_x = node.bounds[2];
                        const max_y = node.bounds[3];
                        const mid_x = (min_x + max_x) * 0.5;
                        const mid_y = (min_y + max_y) * 0.5;

                        // -------------
                        // create children
                        // cw order
                        _ = try self.tree.insert(allocator, id, Node(T){ .bounds = .{ min_x, min_y, mid_x, mid_y } }); //bottom left
                        _ = try self.tree.insert(allocator, id, Node(T){ .bounds = .{ min_x, mid_y, mid_x, max_y } }); //top left
                        _ = try self.tree.insert(allocator, id, Node(T){ .bounds = .{ mid_x, mid_y, max_x, max_y } }); //top right
                        _ = try self.tree.insert(allocator, id, Node(T){ .bounds = .{ mid_x, min_y, max_x, mid_y } }); //bottom right

                        var n = self.tree.getValue(id);
                        var list = n.val.leaf;
                        defer list.deinit(allocator);
                        n.val = .branch;

                        while (list.pop()) |slot| {
                            try self.insertAt(allocator, slot.aabb, slot.v, slot.mask, id, depth + 1);
                        }

                        // Insert the new item that triggered the split
                        try self.insertAt(allocator, bounds, value, mask, id, depth + 1);
                        return;
                    } else {
                        try ar.append(allocator, Slot(T){
                            .aabb = bounds,
                            .v = value,
                            .mask = mask,
                        });
                    }
                },
                .branch => {
                    // no hits at all, expand outside -> reinsert
                    if (@as(u4, @bitCast(intersecs)) == 0) {
                        if (self.tree.getParent(id) != null) {
                            //TODO: skip for now
                            return;
                        }
                        const min_x = node.bounds[0];
                        const min_y = node.bounds[1];
                        const max_x = node.bounds[2];
                        const max_y = node.bounds[3];
                        const width = max_x - min_x;
                        const height = max_y - min_y;

                        const dir = bounds - node.bounds;
                        const dirN = parseDir(std.math.sign(dir));

                        switch (dirN) {
                            Direction.topRight => {
                                // |0|0|
                                // |#|0|

                                const new_parent_id = try self.tree.root(allocator, Node(T){ .bounds = .{ min_x, min_y, max_x + width, max_y + height } });

                                try self.tree.appendChild(allocator, new_parent_id, id); // bottom left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ min_x, max_y, max_x, max_y + height } }); // top left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ max_x, max_y, max_x + width, max_y + height } }); //top right
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ max_x, min_y, max_x + width, max_y } }); //bottom right

                                self.root = new_parent_id;
                                try self.insertAt(allocator, bounds, value, mask, new_parent_id, depth);
                            },
                            Direction.bottomRight => {
                                // |#|0|
                                // |0|0|

                                const new_min_y = min_y - height;

                                const new_parent_id = try self.tree.root(allocator, Node(T){ .bounds = .{ min_x, new_min_y, max_x + width, max_y } });

                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ min_x, new_min_y, max_x, min_y } }); // bottom left
                                try self.tree.appendChild(allocator, new_parent_id, id); // top left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ max_x, min_y, max_x + width, max_y } }); //top right
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ max_x, new_min_y, max_x + width, min_y } }); //bottom right

                                self.root = new_parent_id;
                                try self.insertAt(allocator, bounds, value, mask, new_parent_id, depth);
                            },
                            Direction.bottomLeft => {
                                // |0|#|
                                // |0|0|

                                const new_min_x = min_x - width;
                                const new_min_y = min_y - height;

                                const new_parent_id = try self.tree.root(allocator, Node(T){ .bounds = .{ new_min_x, new_min_y, max_x, max_y } });

                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ new_min_x, new_min_y, min_x, min_y } }); // bottom left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ new_min_x, min_y, min_x, max_y } }); // top left
                                try self.tree.appendChild(allocator, new_parent_id, id); // top right
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ min_x, new_min_y, max_x, min_y } }); //bottom right

                                self.root = new_parent_id;
                                try self.insertAt(allocator, bounds, value, mask, new_parent_id, depth);
                            },
                            Direction.topLeft => {
                                // |0|0|
                                // |0|#|

                                const new_min_x = min_x - width;

                                const new_parent_id = try self.tree.root(allocator, Node(T){ .bounds = .{ new_min_x, min_y, max_x, max_y + height } });

                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ new_min_x, min_y, min_x, max_y } }); // bottom left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ new_min_x, max_y, min_x, max_y + height } }); // top left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ min_x, max_y, max_x, max_y + height } }); //top right
                                try self.tree.appendChild(allocator, new_parent_id, id);

                                self.root = new_parent_id;
                                try self.insertAt(allocator, bounds, value, mask, new_parent_id, depth);
                            },
                        }
                    } else {
                        const children = self.childrenInOrder(id);
                        if (intersecs[0]) try self.insertAt(allocator, bounds, value, mask, children[0], depth + 1); //bottom left
                        if (intersecs[1]) try self.insertAt(allocator, bounds, value, mask, children[1], depth + 1); //top left
                        if (intersecs[2]) try self.insertAt(allocator, bounds, value, mask, children[2], depth + 1); //top right
                        if (intersecs[3]) try self.insertAt(allocator, bounds, value, mask, children[3], depth + 1); //bottm right
                    }
                },
            }
        }

        pub fn query(self: *const Self, aabb: Rect, values: *std.ArrayList(T), mask: u32) !void {
            const id = self.root orelse return error.EmptyTree;
            try self.queryAtFiltered(id, aabb, values, mask, .{});
        }

        pub const Filter = struct {
            const FilterFn = *const fn (filter: *const Filter, *const T) bool;
            ctx: ?*anyopaque = null,
            func: ?FilterFn = null,
        };

        pub fn queryFiltered(self: *const Self, aabb: Rect, values: *std.ArrayList(T), mask: u32, filter: Filter) !void {
            const id = self.root orelse return error.EmptyTree;
            try self.queryAtFiltered(id, aabb, values, mask, filter);
        }

        pub fn queryAtFiltered(
            self: *const Self,
            id: Tree.NodeID,
            aabb: Rect,
            values: *std.ArrayList(T),
            mask: u32,
            filter: Filter,
        ) !void {
            const root_node = self.tree.getValueConst(id);
            switch (root_node.val) {
                .leaf => |*list| {
                    blk: for (list.items) |*slot| {
                        if (!intersect(slot.aabb, aabb)) continue;
                        if ((slot.mask & mask) == 0) continue;
                        if (filter.func) |func| if (!func(&filter, &slot.v)) continue;
                        for (values.items) |t| if (CMP(t, slot.v)) continue :blk;

                        values.appendBounded(slot.v) catch return;
                    }
                    return;
                },
                .branch => {},
            }

            const res = intersect4(aabb, root_node.bounds);
            const children = self.childrenInOrder(id);
            for (0..4) |i| if (res[i]) try self.queryAtFiltered(children[i], aabb, values, mask, filter);
        }

        pub fn raycast(self: *const Self, gpa: Allocator, ray_start: Vec, ray_end: Vec, values: *std.ArrayList(T), mask: u32) !void {
            const id = self.root orelse return error.EmptyTree;
            try self.raycastAt(gpa, id, ray_start, ray_end, values, mask);
        }

        pub fn raycastAt(self: *const Self, gpa: Allocator, id: Tree.NodeID, ray_start: Vec, ray_end: Vec, values: *std.ArrayList(T), mask: u32) !void {
            const root_node = self.tree.getValueConst(id);

            if (!rayIntersectsRect(ray_start, ray_end, root_node.bounds)) {
                return;
            }

            switch (root_node.val) {
                .leaf => |*list| {
                    for (list.items) |slot| {
                        if (!rayIntersectsRect(ray_start, ray_end, slot.aabb)) continue;
                        if ((slot.mask & mask) == 0) continue;
                        try values.append(gpa, slot.v);
                    }
                    return;
                },
                .branch => {},
            }

            const children = self.childrenInOrder(id);

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
        }

        fn childrenInOrder(self: *const Self, parent: Tree.NodeID) [4]Tree.NodeID {
            var children: [4]Tree.NodeID = undefined;
            var it = self.tree.IterateChildren(parent);
            for (0..4) |i| {
                children[i] = it.next().?.node_id;
            }
            return children;
        }
    };
}

pub inline fn intersect(a: Rect, b: Rect) bool {
    const x_overlap = a[0] < b[2] and a[2] > b[0];
    const y_overlap = a[1] < b[3] and a[3] > b[1];
    return x_overlap and y_overlap;
}

inline fn parseDir(vec: Vec) Direction {
    if (vec[0] == -1 and vec[1] == -1) return Direction.bottomLeft;
    if (vec[0] == -1 and vec[1] == 1) return Direction.topLeft;
    if (vec[0] == 1 and vec[1] == 1) return Direction.topRight;
    if (vec[0] == 1 and vec[1] == -1) return Direction.bottomRight;

    @panic("impossible");
}

/// quadtree 4x intersect in cw
/// x---x---x
/// |   |   |
/// 1---2---x
/// |   |   |
/// 0---3---x
/// o = xy
/// x = hw
/// cw order
/// rect layout: {min_x, min_y, max_x, max_y}
pub inline fn intersect4(query: Rect, area: Rect) @Vector(4, bool) {
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

    const query_min_x = vecs(query[0]);
    const query_min_y = vecs(query[1]);
    const query_max_x = vecs(query[2]);
    const query_max_y = vecs(query[3]);

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

    var out = std.ArrayList(u32){};
    defer out.deinit(gpa);

    try qtree.query(.{ 0, 0, 9, 15 }, &out, 0xFFFFFFFF);

    std.debug.print("\n{any}\n", .{out.items});
    // try std.testing.expect(out.items.len == 1);
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

    var out = std.ArrayList(u32){};
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
