const std = @import("std");
const Rect = @Vector(4, f32);
const m = @import("zmath.zig");
const tree = @import("tree.zig");
const Allocator = std.mem.Allocator;

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
    };
}

const Direction = enum {
    bottomLeft,
    topLeft,
    topRight,
    bottomRight,
};

/// Quadtree
pub fn Quadtree(comptime T: type) type {
    return struct {
        const Tree = tree.MultiTree(Node(T));
        const MINSIZE: u32 = 100;
        const MAXITEMS: u32 = 32;
        const Self = @This();

        count: u32 = 0,
        tree: Tree = .{},
        root: ?Tree.NodeID = null,

        pub fn insert(self: *Self, allocator: Allocator, bounds: Rect, value: T) !void {
            const root = self.root orelse blk: {
                const id = try self.tree.root(allocator, Node(T){
                    .bounds = m.Vec{ -1024, -1024, 2048, 2048 } * m.f32x4s(8),
                });
                self.root = id;
                break :blk id;
            };

            try self.insertAt(allocator, bounds, value, root, 0);
            self.count += 1;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.tree.values()) |*node| {
                switch (node.val) {
                    .leaf => |*list| list.deinit(allocator),
                    else => {},
                }
            }

            self.tree.deinit(allocator);
            self.* = .{};
        }

        pub fn clearLeaky(self: *Self) void {
            self.tree = .{};
            self.root = null;
            self.count = 0;
        }

        pub fn insertAt(self: *Self, allocator: Allocator, bounds: Rect, value: T, id: Tree.NodeID, depth: u32) !void {
            const node = self.tree.getValue(id);
            const intersecs = intersect4(bounds, node.bounds);

            // has children or leaf?
            switch (node.val) {
                .leaf => |*ar| {
                    const needs_split = (ar.items.len > MAXITEMS) and (node.bounds[2] > MINSIZE); // or depth < 6;
                    // const needs_split = depth < 5;

                    if (needs_split) {
                        const x = node.bounds[0];
                        const y = node.bounds[1];
                        const hw = node.bounds[2] * 0.5;
                        const hh = node.bounds[3] * 0.5;

                        // -------------
                        // create children
                        // cw order
                        _ = try self.tree.insert(allocator, id, Node(T){ .bounds = .{ x, y, hw, hh } }); //bottom left
                        _ = try self.tree.insert(allocator, id, Node(T){ .bounds = .{ x, y + hh, hw, hh } }); //top left
                        _ = try self.tree.insert(allocator, id, Node(T){ .bounds = .{ x + hw, y + hh, hw, hh } }); //top right
                        _ = try self.tree.insert(allocator, id, Node(T){ .bounds = .{ x + hw, y, hw, hh } }); //bottom right

                        var n = self.tree.getValue(id);
                        var list = n.val.leaf;
                        defer list.deinit(allocator);
                        n.val = .branch;

                        while (list.pop()) |slot| {
                            try self.insertAt(allocator, slot.aabb, slot.v, id, depth + 1);
                        }
                    } else {
                        try ar.append(allocator, Slot(T){
                            .aabb = bounds,
                            .v = value,
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

                        const _x = node.bounds[0];
                        const _y = node.bounds[1];
                        const _w = node.bounds[2];
                        const _h = node.bounds[3];

                        const dir = bounds - node.bounds;
                        const dirN = parseDir(std.math.sign(dir));

                        switch (dirN) {
                            Direction.topRight => {
                                // |0|0|
                                // |#|0|

                                const new_parent_id = try self.tree.root(allocator, Node(T){ .bounds = .{ _x, _y, _w * 2, _h * 2 } });

                                try self.tree.appendChild(allocator, new_parent_id, id); // bottom left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _x, _y + _h, _w, _h } }); // top left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _x + _w, _y + _h, _w, _h } }); //top right
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _x + _w, _y, _w, _h } }); //bottom right

                                self.root = new_parent_id;
                                try self.insertAt(allocator, bounds, value, new_parent_id, depth);
                            },
                            Direction.bottomRight => {
                                // |#|0|
                                // |0|0|

                                const _nx = _x;
                                const _ny = _y - _h;

                                const new_parent_id = try self.tree.root(allocator, Node(T){ .bounds = .{ _nx, _ny, _w * 2, _h * 2 } });

                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _nx, _ny, _w, _h } }); // bottom left
                                try self.tree.appendChild(allocator, new_parent_id, id); // top left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _nx + _w, _ny + _h, _w, _h } }); //top right
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _nx + _w, _ny, _w, _h } }); //bottom right

                                self.root = new_parent_id;
                                try self.insertAt(allocator, bounds, value, new_parent_id, depth);
                            },
                            Direction.bottomLeft => {
                                // |0|#|
                                // |0|0|

                                const _nx = _x - _w;
                                const _ny = _y - _h;

                                const new_parent_id = try self.tree.root(allocator, Node(T){ .bounds = .{ _x - _w, _y - _h, _w * 2, _h * 2 } });

                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _nx, _ny, _w, _h } }); // bottom left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _nx, _ny + _h, _w, _h } }); // bottom left
                                try self.tree.appendChild(allocator, new_parent_id, id); // top right
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _nx + _w, _ny, _w, _h } }); //bottom right

                                self.root = new_parent_id;
                                try self.insertAt(allocator, bounds, value, new_parent_id, depth);
                            },
                            Direction.topLeft => {
                                // |0|0|
                                // |0|#|

                                const _nx = _x - _w;
                                const _ny = _y;

                                const new_parent_id = try self.tree.root(allocator, Node(T){ .bounds = .{ _x - _w, _y, _w * 2, _h * 2 } });

                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _nx, _ny, _w, _h } }); // bottom left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _nx, _ny + _h, _w, _h } }); // bottom left
                                _ = try self.tree.insert(allocator, new_parent_id, Node(T){ .bounds = .{ _nx + _w, _ny + _h, _w, _h } }); //top right
                                try self.tree.appendChild(allocator, new_parent_id, id);

                                self.root = new_parent_id;
                                try self.insertAt(allocator, bounds, value, new_parent_id, depth);
                            },
                        }
                    } else {
                        const children = self.childrenInOrder(id);
                        if (intersecs[0]) try self.insertAt(allocator, bounds, value, children[0], depth + 1); //bottom left
                        if (intersecs[1]) try self.insertAt(allocator, bounds, value, children[1], depth + 1); //top left
                        if (intersecs[2]) try self.insertAt(allocator, bounds, value, children[2], depth + 1); //top right
                        if (intersecs[3]) try self.insertAt(allocator, bounds, value, children[3], depth + 1); //bottm right
                    }
                },
            }
        }

        pub fn query(self: *const Self, aabb: Rect, values: *std.ArrayList(T)) !void {
            const id = self.root orelse return error.EmptyTree;
            try self.queryAt(id, aabb, values);
        }

        pub fn queryAt(self: *const Self, id: Tree.NodeID, aabb: Rect, values: *std.ArrayList(T)) !void {
            const root_node = self.tree.getValueConst(id);
            switch (root_node.val) {
                .leaf => |*list| {
                    for (list.items) |slot| if (intersect(slot.aabb, aabb)) {
                        try values.append(slot.v);
                    };
                    return;
                },
                .branch => {},
            }

            const res = intersect4(aabb, root_node.bounds);
            const children = self.childrenInOrder(id);
            for (0..4) |i| if (res[i]) try self.queryAt(children[i], aabb, values);
        }

        pub fn raycast(self: *const Self, ray_start: m.Vec, ray_end: m.Vec, values: *std.ArrayList(T)) !void {
            const id = self.root orelse return error.EmptyTree;
            try self.raycastAt(id, ray_start, ray_end, values);
        }

        pub fn raycastAt(self: *const Self, id: Tree.NodeID, ray_start: m.Vec, ray_end: m.Vec, values: *std.ArrayList(T)) !void {
            const root_node = self.tree.getValueConst(id);

            if (!rayIntersectsRect(ray_start, ray_end, root_node.bounds)) {
                return;
            }

            switch (root_node.val) {
                .leaf => |*list| {
                    for (list.items) |slot| if (rayIntersectsRect(ray_start, ray_end, slot.aabb)) {
                        try values.append(slot.v);
                    };
                    return;
                },
                .branch => {},
            }

            const children = self.childrenInOrder(id);

            const dx = ray_end[0] - ray_start[0];
            const dy = ray_end[1] - ray_start[1];

            if (@abs(dx) > @abs(dy)) {
                if (dx > 0) {
                    try self.raycastAt(children[0], ray_start, ray_end, values);
                    try self.raycastAt(children[3], ray_start, ray_end, values);
                    try self.raycastAt(children[1], ray_start, ray_end, values);
                    try self.raycastAt(children[2], ray_start, ray_end, values);
                } else {
                    try self.raycastAt(children[1], ray_start, ray_end, values);
                    try self.raycastAt(children[2], ray_start, ray_end, values);
                    try self.raycastAt(children[0], ray_start, ray_end, values);
                    try self.raycastAt(children[3], ray_start, ray_end, values);
                }
            } else {
                if (dy > 0) {
                    try self.raycastAt(children[0], ray_start, ray_end, values);
                    try self.raycastAt(children[1], ray_start, ray_end, values);
                    try self.raycastAt(children[3], ray_start, ray_end, values);
                    try self.raycastAt(children[2], ray_start, ray_end, values);
                } else {
                    try self.raycastAt(children[1], ray_start, ray_end, values);
                    try self.raycastAt(children[2], ray_start, ray_end, values);
                    try self.raycastAt(children[0], ray_start, ray_end, values);
                    try self.raycastAt(children[3], ray_start, ray_end, values);
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

// pub inline fn extendList(area: Rect, aabb: Rect) [3]Rect {
//     var ret: [3]Rect = undefined;
//     return ret;
// }

pub inline fn intersect(a: Rect, b: Rect) bool {
    const x_overlap = a[0] < (b[0] + b[2]) and (a[0] + a[2]) > b[0];
    const y_overlap = a[1] < (b[1] + b[3]) and (a[1] + a[3]) > b[1];
    return x_overlap and y_overlap;
}

inline fn parseDir(vec: m.Vec) Direction {
    if (vec[0] == -1 and vec[1] == -1) return Direction.bottomLeft;
    if (vec[0] == -1 and vec[1] == 1) return Direction.topLeft;
    if (vec[0] == 1 and vec[1] == 1) return Direction.topRight;
    if (vec[0] == 1 and vec[1] == -1) return Direction.bottomRight;

    @panic("impossible");
    // @panic(std.fmt.comptimePrint("unkown dir: {any}", .{vec}));
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
/// rect layout: {x, y, w, h}
pub inline fn intersect4(query: m.F32x4, area: m.F32x4) m.Boolx4 {
    const x = area[0];
    const y = area[1];
    const w = area[2];
    const h = area[3];

    const x_group = m.F32x4{ x, x, x + w * 0.5, x + w * 0.5 };
    const y_group = m.F32x4{ y, y + h * 0.5, y + h * 0.5, y };
    const w_group = m.f32x4s(w * 0.5);
    const h_group = m.f32x4s(h * 0.5);

    const query_4x = m.f32x4s(query[0]);
    const query_4y = m.f32x4s(query[1]);
    const query_4w = m.f32x4s(query[2]);
    const query_4h = m.f32x4s(query[3]);

    const c1: u4 = @bitCast(query_4x < (x_group + w_group));
    const c2: u4 = @bitCast((query_4x + query_4w) > x_group);
    const c3: u4 = @bitCast(query_4y < (y_group + h_group));
    const c4: u4 = @bitCast((query_4y + query_4h) > y_group);

    return @bitCast(c1 & c2 & c3 & c4);
}

pub inline fn rayIntersectsRect(ray_start: m.Vec, ray_end: m.Vec, rect: Rect) bool {
    const dx = ray_end[0] - ray_start[0];
    const dy = ray_end[1] - ray_start[1];

    if (dx == 0 and dy == 0) return false;

    const rect_min = m.Vec{ rect[0], rect[1], 0, 0 };
    const rect_max = m.Vec{ rect[0] + rect[2], rect[1] + rect[3], 0, 0 };

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
    var qtree: Quadtree(u32) = .{};
    defer qtree.deinit(std.testing.allocator);

    for (0..100) |_| {
        try qtree.insert(std.testing.allocator, .{ 0, 0, 50, 50 }, 69);
        try qtree.insert(std.testing.allocator, .{ 10, 0, 10, 10 }, 70);
        try qtree.insert(std.testing.allocator, .{ 0, 10, 10, 10 }, 71);
        try qtree.insert(std.testing.allocator, .{ 10, 10, 10, 10 }, 72);
    }

    var out = std.ArrayList(u32).init(std.testing.allocator);
    defer out.deinit();

    try qtree.query(.{ 0, 0, 9, 15 }, &out);

    std.debug.print("\n{any}\n", .{out.items});
    // try std.testing.expect(out.items.len == 1);
}

test "quadtree raycast" {
    const gpa = std.testing.allocator;
    var qtree: Quadtree(u32) = .{};
    defer qtree.deinit(gpa);

    try qtree.insert(gpa, .{ 10, 10, 10, 10 }, 1);
    try qtree.insert(gpa, .{ 30, 10, 10, 10 }, 2);
    try qtree.insert(gpa, .{ 50, 10, 10, 10 }, 3);
    try qtree.insert(gpa, .{ 10, 30, 10, 10 }, 4);
    try qtree.insert(gpa, .{ 100, 100, 10, 10 }, 5);

    var out = std.ArrayList(u32){};
    defer out.deinit();

    const ray_start = m.Vec{ 0, 15, 0, 0 };
    const ray_end = m.Vec{ 60, 15, 0, 0 };
    try qtree.raycast(ray_start, ray_end, &out);

    try std.testing.expect(out.items.len == 3);
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{1}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{2}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{3}));

    out.clearRetainingCapacity();

    const ray_start2 = m.Vec{ 15, 0, 0, 0 };
    const ray_end2 = m.Vec{ 15, 40, 0, 0 };
    try qtree.raycast(ray_start2, ray_end2, &out);

    try std.testing.expect(out.items.len == 2);
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{1}));
    try std.testing.expect(std.mem.containsAtLeast(u32, out.items, 1, &[_]u32{4}));

    out.clearRetainingCapacity();

    const ray_start3 = m.Vec{ 0, 0, 0, 0 };
    const ray_end3 = m.Vec{ 5, 5, 0, 0 };
    try qtree.raycast(ray_start3, ray_end3, &out);

    try std.testing.expect(out.items.len == 0);
}
