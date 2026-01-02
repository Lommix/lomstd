const std = @import("std");
const assert = std.debug.assert;

pub fn fBTree(comptime T: type) type {
    return BTree(T, f32, default_cmpr(f32));
}

pub fn iBTree(comptime T: type) type {
    return BTree(T, i32, default_cmpr(i32));
}

fn default_cmpr(comptime T: type) fn (T, T) bool {
    return (struct {
        fn cmp(a: T, b: T) bool {
            return a > b;
        }
    }).cmp;
}

pub fn BTree(
    comptime T: type,
    comptime ID: type,
    comptime CMP: fn (a: ID, b: ID) bool,
) type {
    return struct {
        const Self = @This();
        const Node = struct { val: T, idx: ID, left: ?u32 = null, right: ?u32 = null };
        const Direction = enum { left, right };
        const Mode = enum { ascending, descending };

        nodes: std.MultiArrayList(Node) = .{},
        capacity: usize = 0,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) !Self {
            var self = Self{};
            try self.setCapacity(gpa, capacity);
            return self;
        }

        pub fn setCapacity(self: *Self, gpa: std.mem.Allocator, capacity: usize) !void {
            try self.nodes.ensureTotalCapacity(gpa, capacity);
            self.capacity = capacity;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.nodes.deinit(gpa);
        }

        inline fn highestId(self: *Self) u32 {
            assert(self.nodes.len > 0);
            return self.follow(0, .right);
        }

        inline fn lowestId(self: *Self) u32 {
            assert(self.nodes.len > 0);
            return self.follow(0, .left);
        }

        inline fn follow(self: *Self, node: u32, order: Direction) u32 {
            var current: u32 = node;
            for (0..self.capacity) |_| {
                switch (order) {
                    .left => {
                        if (self.nodes.items(.left)[current]) |next| {
                            current = next;
                        } else break;
                    },
                    .right => {
                        if (self.nodes.items(.right)[current]) |next| {
                            current = next;
                        } else break;
                    },
                }
            }

            return current;
        }

        pub fn insert(self: *Self, val: T, id: ID) !void {
            if (self.nodes.len >= self.capacity) return error.TreeIsFull;

            self.nodes.appendAssumeCapacity(.{ .val = val, .idx = id });
            const insert_id: u32 = @intCast(self.nodes.len - 1);

            if (insert_id == 0) return;

            var current_id: u32 = 0;
            var timeout: u32 = 0;
            blk: while (true) {
                const sort_key = self.nodes.items(.idx)[current_id];

                if (CMP(sort_key, id)) {
                    // left
                    const left: *?u32 = &self.nodes.items(.left)[current_id];

                    if (left.*) |next| {
                        current_id = next;
                    } else {
                        left.* = insert_id;
                        break :blk;
                    }
                } else {
                    // right
                    const right: *?u32 = &self.nodes.items(.right)[current_id];

                    if (right.*) |next| {
                        current_id = next;
                    } else {
                        right.* = insert_id;
                        break :blk;
                    }
                }

                timeout += 1;
                if (timeout > self.capacity) return error.TreeIsLooping;
            }
        }

        pub const Iterator = struct {
            const MAXSTACK: usize = 64;
            tree: *Self,
            mode: Mode,
            stack: []u32,
            stack_len: usize,

            pub const Entry = struct {
                val: *T,
                key: *ID,
            };

            fn pushDescendants(self: *Iterator, start: u32, dir: Direction) void {
                var current: ?u32 = start;
                while (current) |node| {
                    self.stack[self.stack_len] = node;
                    self.stack_len += 1;

                    current = switch (dir) {
                        .left => self.tree.nodes.items(.left)[node],
                        .right => self.tree.nodes.items(.right)[node],
                    };
                }
            }

            pub fn next(self: *Iterator) ?Entry {
                if (self.stack_len == 0) return null;
                assert(self.stack_len < MAXSTACK);

                switch (self.mode) {
                    .ascending => {
                        // In-order traversal: left -> node -> right
                        self.stack_len -= 1;
                        const current = self.stack[self.stack_len];
                        const result = Entry{
                            .val = &self.tree.nodes.items(.val)[current],
                            .key = &self.tree.nodes.items(.idx)[current],
                        };

                        // If right child exists, push all left nodes from right subtree
                        if (self.tree.nodes.items(.right)[current]) |right| {
                            self.pushDescendants(right, .right);
                        }

                        return result;
                    },
                    .descending => {
                        // Reverse in-order: right -> node -> left
                        self.stack_len -= 1;
                        const current = self.stack[self.stack_len];
                        const result = Entry{
                            .val = &self.tree.nodes.items(.val)[current],
                            .key = &self.tree.nodes.items(.idx)[current],
                        };

                        // If left child exists, push all right nodes from left subtree
                        if (self.tree.nodes.items(.left)[current]) |left| {
                            self.pushDescendants(left, .left);
                        }

                        return result;
                    },
                }
            }

            pub fn reset(self: *Iterator) void {
                self.stack_len = 0;
                if (self.tree.nodes.len == 0) return;

                switch (self.mode) {
                    .ascending => self.pushDescendants(0, .left),
                    .descending => self.pushDescendants(0, .right),
                }
            }

            pub fn deinit(self: *Iterator, gpa: std.mem.Allocator) void {
                gpa.free(self.stack);
            }
        };

        // alloc a stack
        pub fn iterAlloc(self: *Self, gpa: std.mem.Allocator, mode: Mode) !Iterator {
            var it = Iterator{
                .mode = mode,
                .tree = self,
                .stack = try gpa.alloc(u32, self.capacity),
                .stack_len = 0,
            };

            if (self.nodes.len > 0) {
                switch (mode) {
                    .ascending => it.pushDescendants(0, .left),
                    .descending => it.pushDescendants(0, .right),
                }
            }

            return it;
        }

        // supply a stack
        pub fn iterBuffered(self: *Self, mode: Mode, stack: []u32) Iterator {
            var it = Iterator{
                .mode = mode,
                .tree = self,
                .stack = stack,
                .stack_len = 0,
            };

            if (self.nodes.len > 0) {
                switch (mode) {
                    .ascending => it.pushDescendants(0, .left),
                    .descending => it.pushDescendants(0, .right),
                }
            }

            return it;
        }
    };
}

test "btree" {
    var tree = try fBTree([]const u8).init(std.testing.allocator, 100);
    defer tree.deinit(std.testing.allocator);

    try tree.insert("one", 5);
    try tree.insert("tow", 12);
    try tree.insert("three", 2);
    try tree.insert("four", 25);
    try tree.insert("five", 95);
    try tree.insert("six", 1);
    try tree.insert("seven", 9);

    var buf: [64]u32 = undefined;

    var it = tree.iterBuffered(.ascending, &buf);
    while (it.next()) |en| {
        std.debug.print("[{d}]{s}-", .{ en.key.*, en.val.* });
    }
}
