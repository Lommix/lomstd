const std = @import("std");
const Allocator = std.mem.Allocator;

/// # MultiTree
/// a flat multi root tree structure for UI and similar
pub fn MultiTree(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const NodeID = u32;
        pub const RelationID = u32;

        const Slot = struct {
            value: T,
            link: Link,
        };

        const Link = struct {
            first_child_relation_id: ?RelationID = null,
            parent_id: ?NodeID = null,
        };

        pub const Relation = struct {
            node_index: NodeID,
            next_child_relation_id: ?RelationID = null,
            last_child_relation_id: ?RelationID = null,
        };

        nodes: std.MultiArrayList(Slot) = .{},
        relation: std.ArrayListUnmanaged(Relation) = .{},
        roots: std.ArrayListUnmanaged(NodeID) = .{},

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (std.meta.hasMethod(T, "deinit")) {
                inline for (self.nodes.items) |*val| {
                    val.deinit();
                }
            }

            self.nodes.deinit(allocator);
            self.relation.deinit(allocator);
            self.roots.deinit(allocator);
        }

        pub fn values(self: *Self) []T {
            return self.nodes.items(.value);
        }

        pub fn root(self: *Self, allocator: Allocator, value: T) !NodeID {
            const id = try self.nextFreeId(allocator);
            self.nodes.items(.value)[id] = value;
            self.nodes.items(.link)[id] = .{};
            try self.roots.append(allocator, id);
            return id;
        }

        pub fn insert(self: *Self, allocator: Allocator, parent_id: NodeID, value: T) !NodeID {
            std.debug.assert(parent_id < self.nodes.len);
            const id = try self.nextFreeId(allocator);

            self.nodes.items(.value)[id] = value;
            self.nodes.items(.link)[id] = Link{
                .parent_id = parent_id,
                .first_child_relation_id = null,
            };

            // create new relation entry
            try self.relation.append(allocator, Relation{
                .node_index = id,
                .next_child_relation_id = null,
                .last_child_relation_id = null,
            });

            const relation_id: RelationID = @intCast(self.relation.items.len - 1);

            // set or follow to last child
            if (self.nodes.items(.link)[parent_id].first_child_relation_id) |first_relation_id| {
                const last_id = self.findLastChildRelation(first_relation_id);
                self.relation.items[last_id].next_child_relation_id = relation_id;
                self.relation.items[relation_id].last_child_relation_id = last_id;
                // set last
            } else {
                self.nodes.items(.link)[parent_id].first_child_relation_id = relation_id;
            }

            return id;
        }

        pub fn appendChild(self: *Self, allocator: Allocator, parent: NodeID, child: NodeID) !void {
            if (!self.hasChildren(parent)) {
                const rel_id = try self.addRelation(allocator, .{
                    .node_index = child,
                });

                self.nodes.items(.link)[child].parent_id = parent;
                self.nodes.items(.link)[parent].first_child_relation_id = rel_id;

                return;
            }

            var rel_id = self.getLink(parent).first_child_relation_id;
            var last_valid: ?RelationID = null;

            while (rel_id) |id| {
                rel_id = self.relation.items[id].next_child_relation_id;
                last_valid = id;
            }

            const next_rel = try self.addRelation(allocator, .{
                .node_index = child,
                .last_child_relation_id = last_valid.?,
            });

            self.relation.items[last_valid.?].next_child_relation_id = next_rel;
            self.nodes.items(.link)[child].parent_id = parent;
        }

        pub fn addRelation(self: *Self, allocator: Allocator, rel: Relation) !RelationID {
            try self.relation.append(allocator, rel);
            return @intCast(self.relation.items.len - 1);
        }

        pub fn removeChild(self: *Self, parent: NodeID, child: NodeID) !void {
            var rel_id = try self.getFirstRelation(parent);

            while (self.relation.items[rel_id].next_child_relation_id) |next| {
                if (self.relation.items[rel_id].node_index == child) {

                    //_|_0_|_1_|_2_|_
                    const left_rel_id = self.relation.items[rel_id].last_child_relation_id.?;
                    // case is first
                    // cast is last child
                    const right_rel_id = self.relation.items[rel_id].last_child_relation_id.?;
                    self.relation.items[left_rel_id].next_child_relation_id = right_rel_id;
                    self.relation.items[right_rel_id].next_child_relation_id = left_rel_id;
                }

                rel_id = next;
            }
        }

        pub inline fn getParent(self: *Self, node_id: NodeID) ?NodeID {
            return self.nodes.items(.link)[node_id].parent_id;
        }

        pub inline fn getValueConst(self: *const Self, node_id: NodeID) *const T {
            return &self.nodes.items(.value)[node_id];
        }

        pub inline fn getValue(self: *Self, node_id: NodeID) *T {
            return &self.nodes.items(.value)[node_id];
        }

        pub inline fn getLink(self: *const Self, node_id: NodeID) Link {
            return self.nodes.items(.link)[node_id];
        }

        pub inline fn getFirstRelation(self: *Self, node_id: NodeID) ?RelationID {
            return self.nodes.items(.link)[node_id].first_child_relation_id;
        }

        pub inline fn getFirstRelationOrCreate(self: *Self, allocator: Allocator, node_id: NodeID) !RelationID {
            return self.nodes.items(.link)[node_id].first_child_relation_id orelse blk: {
                try self.relation.append(allocator, Relation{ .node_index = node_id });
                const rel_id: RelationID = @intCast(self.relation.items.len - 1);
                self.nodes.items(.link)[node_id].first_child_relation_id = rel_id;
                break :blk rel_id;
            };
        }

        pub fn remove(self: *Self, node_id: NodeID) void {
            std.debug.assert(node_id < self.nodes.len);

            // Collect all nodes to be removed (including descendants)
            var to_remove = std.ArrayList(NodeID).init(std.heap.page_allocator);
            defer to_remove.deinit();

            self.collectDescendants(node_id, &to_remove);
            to_remove.append(node_id) catch unreachable;

            // Sort in descending order so we remove from the end first
            std.mem.sort(NodeID, to_remove.items, {}, std.sort.desc(NodeID));

            for (to_remove.items) |id| {
                self.removeSingleNode(id);
            }
        }

        fn collectDescendants(self: *Self, node_id: NodeID, list: *std.ArrayList(NodeID)) void {
            var rel_id = self.nodes.items(.link)[node_id].first_child_relation_id;

            while (rel_id) |current_rel| {
                const child_node = self.relation.items[current_rel].node_index;
                self.collectDescendants(child_node, list);
                list.append(child_node) catch unreachable;
                rel_id = self.relation.items[current_rel].next_child_relation_id;
            }
        }

        fn removeSingleNode(self: *Self, node_id: NodeID) void {
            const last_node_id: NodeID = @intCast(self.nodes.len - 1);

            // Remove from parent's child list or roots
            const link = self.nodes.items(.link)[node_id];
            if (link.parent_id) |parent_id| {
                self.removeFromParentChildList(parent_id, node_id);
            } else {
                self.removeFromRoots(node_id);
            }

            // If removing the last node, no fixup needed
            if (node_id == last_node_id) {
                _ = self.nodes.swapRemove(node_id);
                return;
            }

            // Swap remove will move last node to this position
            _ = self.nodes.swapRemove(node_id);

            // Fix all references to the moved node (was at last_node_id, now at node_id)
            self.fixNodeReferences(last_node_id, node_id);
        }

        fn removeFromParentChildList(self: *Self, parent_id: NodeID, child_id: NodeID) void {
            const parent_link = &self.nodes.items(.link)[parent_id];
            var rel_id = parent_link.first_child_relation_id orelse return;

            if (self.relation.items[rel_id].node_index == child_id) {
                parent_link.first_child_relation_id = self.relation.items[rel_id].next_child_relation_id;
                self.removeRelation(rel_id);
                return;
            }

            while (self.relation.items[rel_id].next_child_relation_id) |next_rel_id| {
                if (self.relation.items[next_rel_id].node_index == child_id) {
                    self.relation.items[rel_id].next_child_relation_id =
                        self.relation.items[next_rel_id].next_child_relation_id;

                    if (self.relation.items[next_rel_id].next_child_relation_id) |next_next| {
                        self.relation.items[next_next].last_child_relation_id = rel_id;
                    }

                    self.removeRelation(next_rel_id);
                    return;
                }
                rel_id = next_rel_id;
            }
        }

        fn removeFromRoots(self: *Self, node_id: NodeID) void {
            for (self.roots.items, 0..) |root_id, i| {
                if (root_id == node_id) {
                    _ = self.roots.swapRemove(i);
                    return;
                }
            }
        }

        fn removeRelation(self: *Self, rel_id: RelationID) void {
            const last_rel_id: RelationID = @intCast(self.relation.items.len - 1);

            if (rel_id == last_rel_id) {
                _ = self.relation.swapRemove(rel_id);
                return;
            }

            // Fix references to the moved relation before swap
            self.fixRelationReferences(last_rel_id, rel_id);
            _ = self.relation.swapRemove(rel_id);
        }

        fn fixNodeReferences(self: *Self, old_node_id: NodeID, new_node_id: NodeID) void {
            // Fix parent references in all relations
            for (self.relation.items) |*rel| {
                if (rel.node_index == old_node_id) {
                    rel.node_index = new_node_id;
                }
            }

            // Fix parent_id references in all nodes
            for (self.nodes.items(.link)) |*link| {
                if (link.parent_id == old_node_id) {
                    link.parent_id = new_node_id;
                }
            }

            // Fix roots array
            for (self.roots.items) |*root_id| {
                if (root_id.* == old_node_id) {
                    root_id.* = new_node_id;
                }
            }
        }

        fn fixRelationReferences(self: *Self, old_rel_id: RelationID, new_rel_id: RelationID) void {
            // Fix first_child_relation_id in all nodes
            for (self.nodes.items(.link)) |*link| {
                if (link.first_child_relation_id == old_rel_id) {
                    link.first_child_relation_id = new_rel_id;
                }
            }

            // Fix next_child_relation_id and last_child_relation_id in all relations
            for (self.relation.items) |*rel| {
                if (rel.next_child_relation_id == old_rel_id) {
                    rel.next_child_relation_id = new_rel_id;
                }
                if (rel.last_child_relation_id == old_rel_id) {
                    rel.last_child_relation_id = new_rel_id;
                }
            }
        }

        pub fn hasChildren(self: *const Self, index: NodeID) bool {
            return self.getLink(index).first_child_relation_id != null;
        }

        pub fn childCount(self: *Self, index: NodeID) u32 {
            var sum: u32 = 0;
            var current = self.nodes.items(.link)[index].first_child_relation_id;
            while (current != null) {
                sum += 1;
                current = self.relation.items[current.?].next_child_relation_id;
            }

            return sum;
        }

        // ------------------------
        // depth first

        pub const DepthFirstIter = struct {
            tree: *Self,
            stack: std.ArrayList(RelationID),
            root: NodeID,
            passed_root: bool = false,

            pub fn deinit(self: *DepthFirstIter) void {
                self.stack.deinit();
            }

            pub fn next(self: *DepthFirstIter) ?Entry {
                if (!self.passed_root) {
                    const root_link = self.tree.nodes.items(.link)[self.root]; // self.root);

                    if (root_link.first_child_relation_id) |id| {
                        self.stack.append(id) catch unreachable;
                    }

                    self.passed_root = true;
                    return Entry{
                        .node_id = self.root,
                        .value = self.tree.getValue(self.root),
                    };
                }

                const next_id: RelationID = self.stack.pop() orelse return null;
                const rel = &self.tree.relation.items[next_id];

                if (rel.next_child_relation_id) |next_sibling| {
                    self.stack.append(next_sibling) catch unreachable;
                }

                if (self.tree.nodes.items(.link)[rel.node_index].first_child_relation_id) |next_child| {
                    self.stack.append(next_child) catch unreachable;
                }

                return Entry{
                    .node_id = rel.node_index,
                    .value = &self.tree.nodes.items(.value)[rel.node_index],
                };
            }
        };

        pub fn IterateDepthFirst(self: *Self, allocator: Allocator, root_id: NodeID) DepthFirstIter {
            return DepthFirstIter{
                .tree = self,
                .stack = std.ArrayList(RelationID).init(allocator),
                .root = root_id,
            };
        }
        // ------------------------
        // breadth first

        pub const Entry = struct {
            node_id: NodeID,
            value: *T,
        };

        pub const BreadthFristIter = struct {
            tree: *Self,
            current_layer: std.ArrayList(NodeID),
            next_layer: std.ArrayList(NodeID),
            root: NodeID,
            passed_root: bool = false,

            pub fn deinit(self: *BreadthFristIter) void {
                self.current_layer.deinit();
                self.next_layer.deinit();
            }

            pub fn next(self: *BreadthFristIter) ?Entry {
                if (!self.passed_root) {
                    var it = self.tree.IterateChildren(self.root);
                    while (it.next()) |c| {
                        self.current_layer.append(c.node_id) catch unreachable;
                    }

                    std.mem.reverse(NodeID, self.current_layer.items);

                    self.passed_root = true;

                    return Entry{
                        .node_id = self.root,
                        .value = self.tree.getValue(self.root),
                    };
                }

                if (self.current_layer.pop()) |node_id| {
                    var child_iter = self.tree.IterateChildren(node_id);
                    while (child_iter.next()) |entry| {
                        self.next_layer.append(entry.node_id) catch unreachable;
                    }

                    return .{
                        .node_id = node_id,
                        .value = &self.tree.nodes.items(.value)[node_id],
                    };
                }

                if (self.next_layer.items.len == 0) {
                    return null;
                }

                while (self.next_layer.pop()) |n| {
                    self.current_layer.append(n) catch unreachable;
                }

                return self.next();
            }
        };

        pub fn IterateBreathedFirst(self: *Self, allocator: Allocator, root_id: NodeID) BreadthFristIter {
            return BreadthFristIter{
                .tree = self,
                .current_layer = std.ArrayList(NodeID).init(allocator),
                .next_layer = std.ArrayList(NodeID).init(allocator),
                .root = root_id,
            };
        }

        // ---------------------------------
        pub const ChildIter = struct {
            tree: *const Self,
            origin: ?RelationID,
            relation_index: ?RelationID,

            pub fn reset(self: *ChildIter) void {
                self.relation_index = self.origin;
            }

            pub fn next(self: *ChildIter) ?Entry {
                const index = self.relation_index orelse return null;
                const relation = &self.tree.relation.items[index];
                self.relation_index = relation.next_child_relation_id;

                return Entry{
                    .node_id = relation.node_index,
                    .value = &self.tree.nodes.items(.value)[relation.node_index],
                };
            }
        };

        pub fn IterateChildren(self: *const Self, parent_index: NodeID) ChildIter {
            return ChildIter{
                .tree = self,
                .relation_index = self.nodes.items(.link)[parent_index].first_child_relation_id,
                .origin = self.nodes.items(.link)[parent_index].first_child_relation_id,
            };
        }

        // -----------------------------------------------------
        fn findLastChildRelation(self: *const Self, relation_id: RelationID) RelationID {
            var current = relation_id;
            while (self.relation.items[current].next_child_relation_id) |next| {
                current = next;
            }
            return current;
        }

        fn nextFreeId(self: *Self, allocator: Allocator) !NodeID {
            const idx = try self.nodes.addOne(allocator);
            return @intCast(idx);
        }
    };
}

test "insert" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;
    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    const root = try tree.root(alloc, 33);

    const child = try tree.insert(alloc, root, 65);
    _ = try tree.insert(alloc, root, 62);
    _ = try tree.insert(alloc, root, 61);

    _ = try tree.insert(alloc, child, 33);

    const child2 = try tree.insert(alloc, child, 44);
    _ = try tree.insert(alloc, child2, 1);
    _ = try tree.insert(alloc, child2, 2);

    try expect(tree.childCount(root) == 3);

    var iter = tree.IterateChildren(root);
    try expect(iter.next().?.value.* == 65);
    try expect(iter.next().?.value.* == 62);
    try expect(iter.next().?.value.* == 61);

    iter = tree.IterateChildren(child);
    try expect(iter.next().?.value.* == 33);
    try expect(iter.next().?.value.* == 44);

    var biter = tree.IterateBreathedFirst(std.testing.allocator, root);
    defer biter.deinit();

    // while (biter.next()) |n| std.debug.print("->{d}", .{n.value.*});

    try expect(biter.next().?.value.* == 33);
    try expect(biter.next().?.value.* == 65);
    try expect(biter.next().?.value.* == 62);
    try expect(biter.next().?.value.* == 61);
    try expect(biter.next().?.value.* == 33);
    try expect(biter.next().?.value.* == 44);
    try expect(biter.next().?.value.* == 1);
    try expect(biter.next().?.value.* == 2);

    var diter = tree.IterateDepthFirst(std.testing.allocator, root);
    defer diter.deinit();

    try expect(diter.next().?.value.* == 33);
    try expect(diter.next().?.value.* == 65);
    try expect(diter.next().?.value.* == 33);
    try expect(diter.next().?.value.* == 44);
    try expect(diter.next().?.value.* == 1);
    try expect(diter.next().?.value.* == 2);
    try expect(diter.next().?.value.* == 62);
    try expect(diter.next().?.value.* == 61);

    // var tii = MultiTreeUnmanaged(bool).init(std.testing.allocator);
    // defer tii.deinit();
    // _ = tii.root(false);
    // _ = tii.insert(666, true);
    // try std.testing.expectError(error.Panic, tii.insert(666, true));
}

test "many" {
    const alloc = std.testing.allocator;
    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);
    const root = try tree.root(alloc, 0);
    for (0..1000) |i| {
        _ = try tree.insert(alloc, root, @intCast(i));
    }
    try std.testing.expectEqual(1000, tree.childCount(root));
}

test "parent_ids" {
    const alloc = std.testing.allocator;
    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);
    const root = try tree.root(alloc, 0);
    const child1 = try tree.insert(alloc, root, 1);
    const child2 = try tree.insert(alloc, root, 2);
    const grandchild = try tree.insert(alloc, child1, 3);

    try std.testing.expect(tree.childCount(root) == 2);

    try std.testing.expectEqual(null, tree.getParent(root));
    try std.testing.expectEqual(root, tree.getParent(child1).?);
    try std.testing.expectEqual(root, tree.getParent(child2).?);
    try std.testing.expectEqual(child1, tree.getParent(grandchild).?);
}

test "extend_parent" {
    const alloc = std.testing.allocator;
    const expect = std.testing.expect;

    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    const root1 = try tree.root(alloc, 1);
    const root2 = try tree.root(alloc, 2);

    std.debug.print("root1: {d} root2: {d} ::", .{ root1, root2 });

    try tree.appendChild(alloc, root2, root1);

    var it = tree.IterateChildren(root2);
    while (it.next()) |n| {
        std.debug.print("->{d}", .{n.node_id});
    }

    try expect(tree.childCount(root2) == 1);
}

test "remove leaf node" {
    const alloc = std.testing.allocator;
    const expect = std.testing.expect;

    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    const root = try tree.root(alloc, 0);
    _ = try tree.insert(alloc, root, 1);
    const child2 = try tree.insert(alloc, root, 2);
    _ = try tree.insert(alloc, root, 3);

    try expect(tree.childCount(root) == 3);
    try expect(tree.nodes.len == 4);

    // Remove middle child
    tree.remove(child2);

    try expect(tree.childCount(root) == 2);
    try expect(tree.nodes.len == 3);

    // Verify remaining children
    var iter = tree.IterateChildren(root);
    const first = iter.next().?;
    const second = iter.next().?;
    try expect(iter.next() == null);

    // Values should be 1 and 3 (child2 with value 2 was removed)
    try expect((first.value.* == 1 and second.value.* == 3) or (first.value.* == 3 and second.value.* == 1));
}

test "remove node with children" {
    const alloc = std.testing.allocator;
    const expect = std.testing.expect;

    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    const root = try tree.root(alloc, 0);
    const parent = try tree.insert(alloc, root, 10);
    const child1 = try tree.insert(alloc, parent, 11);
    _ = try tree.insert(alloc, parent, 12);
    _ = try tree.insert(alloc, child1, 13);

    try expect(tree.childCount(root) == 1);
    try expect(tree.childCount(parent) == 2);
    try expect(tree.childCount(child1) == 1);
    try expect(tree.nodes.len == 5);

    // Remove parent node (should remove all descendants)
    tree.remove(parent);

    try expect(tree.childCount(root) == 0);
    try expect(tree.nodes.len == 1); // Only root should remain

    // Verify root still exists and has correct value
    try expect(tree.getValue(root).* == 0);
}

test "remove root node" {
    const alloc = std.testing.allocator;
    const expect = std.testing.expect;

    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    const root1 = try tree.root(alloc, 1);
    _ = try tree.root(alloc, 2);
    _ = try tree.insert(alloc, root1, 10);
    _ = try tree.insert(alloc, root1, 11);

    try expect(tree.roots.items.len == 2);
    try expect(tree.nodes.len == 4);

    // Remove first root
    tree.remove(root1);

    try expect(tree.roots.items.len == 1);
    try expect(tree.nodes.len == 1);
    try expect(tree.getValue(tree.roots.items[0]).* == 2);
}

test "remove with swap references" {
    const alloc = std.testing.allocator;
    const expect = std.testing.expect;

    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    // Create a simpler structure to test swap references
    const root = try tree.root(alloc, 0);
    const n1 = try tree.insert(alloc, root, 1);
    _ = try tree.insert(alloc, root, 2);
    _ = try tree.insert(alloc, root, 3);

    try expect(tree.nodes.len == 4);
    try expect(tree.childCount(root) == 3);

    // Remove first child (n1) - this will cause swap references
    tree.remove(n1);

    try expect(tree.nodes.len == 3);
    try expect(tree.childCount(root) == 2);

    // Verify the structure is still intact
    var root_iter = tree.IterateChildren(root);
    var found_2 = false;
    var found_3 = false;

    while (root_iter.next()) |entry| {
        if (entry.value.* == 2) found_2 = true;
        if (entry.value.* == 3) found_3 = true;
    }

    try expect(found_2 and found_3);
}

test "remove single node tree" {
    const alloc = std.testing.allocator;
    const expect = std.testing.expect;

    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    const root = try tree.root(alloc, 42);
    try expect(tree.nodes.len == 1);
    try expect(tree.roots.items.len == 1);

    tree.remove(root);

    try expect(tree.nodes.len == 0);
    try expect(tree.roots.items.len == 0);
}

test "remove multiple nodes sequentially" {
    const alloc = std.testing.allocator;
    const expect = std.testing.expect;

    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    const root = try tree.root(alloc, 0);

    // Create 5 children
    _ = try tree.insert(alloc, root, 1);
    _ = try tree.insert(alloc, root, 2);
    _ = try tree.insert(alloc, root, 3);
    _ = try tree.insert(alloc, root, 4);
    _ = try tree.insert(alloc, root, 5);

    try expect(tree.childCount(root) == 5);
    try expect(tree.nodes.len == 6);

    // Remove children one by one from the end (safer with swap remove)
    while (tree.childCount(root) > 2) {
        // Get the first child and remove it
        var iter = tree.IterateChildren(root);
        if (iter.next()) |child| {
            tree.remove(child.node_id);
        }
    }

    try expect(tree.childCount(root) == 2);
    try expect(tree.nodes.len == 3);
}

test "remove deep nested structure" {
    const alloc = std.testing.allocator;
    const expect = std.testing.expect;

    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    // Create a deep nested structure
    const root = try tree.root(alloc, 0);
    var current = root;

    for (1..10) |i| {
        current = try tree.insert(alloc, current, @intCast(i));
    }

    try expect(tree.nodes.len == 10);

    // Remove a middle node (should remove all its descendants)
    const middle_node = try tree.insert(alloc, root, 100); // Node at depth 1
    const deep_child = try tree.insert(alloc, middle_node, 101);
    _ = try tree.insert(alloc, deep_child, 102);

    try expect(tree.nodes.len == 13);

    tree.remove(middle_node);

    try expect(tree.nodes.len == 10); // Back to original structure
}

test "remove with complex sibling relationships" {
    const alloc = std.testing.allocator;
    const expect = std.testing.expect;

    var tree = MultiTree(u32){};
    defer tree.deinit(alloc);

    const root = try tree.root(alloc, 0);
    _ = try tree.insert(alloc, root, 1);
    const b = try tree.insert(alloc, root, 2);
    _ = try tree.insert(alloc, root, 3);
    const d = try tree.insert(alloc, root, 4);

    // Add children to some of them
    _ = try tree.insert(alloc, b, 20);
    _ = try tree.insert(alloc, b, 21);
    _ = try tree.insert(alloc, d, 40);

    try expect(tree.childCount(root) == 4);
    try expect(tree.childCount(b) == 2);
    try expect(tree.childCount(d) == 1);

    // Remove middle siblings
    tree.remove(b); // This should remove b and its children (20, 21)

    try expect(tree.childCount(root) == 3);

    // Verify remaining structure
    var iter = tree.IterateChildren(root);
    var values = std.ArrayList(u32).init(alloc);
    defer values.deinit();

    while (iter.next()) |entry| {
        try values.append(entry.value.*);
    }

    try expect(values.items.len == 3);
    // Should contain 1, 3, 4 (values of a, c, d)
    std.mem.sort(u32, values.items, {}, std.sort.asc(u32));
    try expect(std.mem.eql(u32, values.items, &[_]u32{ 1, 3, 4 }));
}
