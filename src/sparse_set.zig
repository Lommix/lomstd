const std = @import("std");
const s2b = @import("s2b.zig");

// 4byte packed ID
pub const SlotID = packed struct {
    id: u31 = 0,
    empty: bool = true,

    pub fn get(self: SlotID) ?u32 {
        return if (self.empty) null else @intCast(self.id);
    }

    pub fn new(id: u32) SlotID {
        return SlotID{
            .id = @intCast(id),
            .empty = false,
        };
    }

    pub const NULL = SlotID{};
};

/// Sparse Set, paginated
pub fn SparseSet(comptime T: type) type {
    return struct {
        // ----------------
        dense: std.ArrayList(T) = .{},
        dense_to_sparse: std.ArrayList(u32) = .{},
        sparse: std.ArrayList([1024]SlotID) = .{},
        // ----------------

        const Self = @This();

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.sparse.deinit(gpa);
            self.dense.deinit(gpa);
            self.dense_to_sparse.deinit(gpa);
        }

        pub inline fn insert(self: *Self, gpa: std.mem.Allocator, id: u32, data: T) !*T {
            const page_index = id >> 10;
            const page_slot = id & 1023;

            // Ensure sparse array has enough pages
            while (self.sparse.items.len <= page_index) {
                try self.sparse.append(gpa, @splat(SlotID.NULL));
            }

            if (self.sparse.items[page_index][page_slot].get()) |existing_dense_id| {
                self.dense.items[existing_dense_id] = data;
                return &self.dense.items[existing_dense_id];
            } else {
                try self.dense.append(gpa, data);
                try self.dense_to_sparse.append(gpa, id);
                const dense_id = self.dense.items.len - 1;
                self.sparse.items[page_index][page_slot] = SlotID.new(@intCast(dense_id));
                return &self.dense.items[dense_id];
            }
        }

        pub inline fn getConst(self: *const Self, id: u32) ?*const T {
            const page_index = id >> 10;
            const page_slot = id & 1023;
            if (page_index >= self.sparse.items.len) return null;
            const dense_id = self.sparse.items[page_index][page_slot].get() orelse return null;
            return &self.dense.items[dense_id];
        }

        pub inline fn get(self: *Self, id: u32) ?*T {
            const page_index = id >> 10;
            const page_slot = id & 1023;
            if (page_index >= self.sparse.items.len) return null;
            const dense_id = self.sparse.items[page_index][page_slot].get() orelse return null;
            return &self.dense.items[dense_id];
        }

        pub fn items(self: *Self) []T {
            return self.dense.items;
        }

        pub fn remove(self: *Self, id: u32) void {
            const page_index = id >> 10;
            const page_slot = id & 1023;
            // check len
            const dense_id = self.sparse.items[page_index][page_slot].get() orelse return;
            self.sparse.items[page_index][page_slot] = SlotID.NULL;

            // do not swap on last item in list
            const back_id = self.dense_to_sparse.items[self.dense.items.len - 1];
            if (back_id != id) {
                const back_page_index = back_id >> 10;
                const back_page_slot = back_id & 1023;
                self.sparse.items[back_page_index][back_page_slot] = SlotID.new(dense_id);
            }

            _ = self.dense.swapRemove(dense_id);
            _ = self.dense_to_sparse.swapRemove(dense_id);
        }

        pub fn clear(self: *Self, gpa: std.mem.Allocator) void {
            self.dense.clearAndFree(gpa);
            self.dense_to_sparse.clearAndFree(gpa);
            self.sparse.clearAndFree(gpa);
        }

        pub inline fn len(self: *Self) usize {
            return self.dense.items.len;
        }

        pub inline fn empty(self: *Self) bool {
            return self.dense.items == 0;
        }

        pub fn serialize(self: *const Self, w: *std.Io.Writer) !void {
            // Serialize only the items slices, not the ArrayList structs
            // This avoids issues with capacity/allocator fields
            try s2b.binarySerialize(@TypeOf(self.dense.items), self.dense.items, w);
            try s2b.binarySerialize(@TypeOf(self.dense_to_sparse.items), self.dense_to_sparse.items, w);
            try s2b.binarySerialize(@TypeOf(self.sparse.items), self.sparse.items, w);
        }

        pub fn deserialize(gpa: std.mem.Allocator, r: *std.Io.Reader) !Self {
            var self = Self{
                .dense = std.ArrayList(T){},
                .dense_to_sparse = std.ArrayList(u32){},
                .sparse = std.ArrayList([1024]SlotID){},
            };

            // Deserialize items slices and append to ArrayLists
            const dense_items = try s2b.binaryDeserialize([]T, gpa, r);
            const dense_to_sparse_items = try s2b.binaryDeserialize([]u32, gpa, r);
            const sparse_items = try s2b.binaryDeserialize([][1024]SlotID, gpa, r);

            try self.dense.appendSlice(gpa, dense_items);
            try self.dense_to_sparse.appendSlice(gpa, dense_to_sparse_items);
            try self.sparse.appendSlice(gpa, sparse_items);

            return self;
        }
    };
}

test "serialize deserialize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const En = enum {
        a,
        b,
    };

    const Un = union(En) {
        a: f32,
        b: u8,
    };
    const Other = struct {
        a: ?u32 = null,
        b: f32 = 0.5,
    };

    const E = enum {};
    const Some = struct {
        a: u32,
        b: f32,
        c: [4]u8,
        k: std.ArrayList(u32) = .{},
        e: En = .a,
        f: Un = .{ .a = 0.5 },
        o: Other = .{},
        i: E = undefined,
        s: []u8,
        z: *u32,
        l: std.ArrayList(u32) = .{},
    };

    var ss = SparseSet(Some){};
    var ids: [10]u32 = undefined;

    for (0..10) |i| {
        const s = try gpa.alloc(u8, 10);
        for (0..10) |k| s[k] = 0;

        const z = try gpa.create(u32);
        z.* = 69;

        var list = std.ArrayList(u32){};
        try list.append(gpa, 420);
        try list.append(gpa, 421);

        const id: u32 = @intCast(i * 100);
        ids[i] = id;
        _ = try ss.insert(gpa, id, .{
            .a = @intCast(i),
            .b = @floatFromInt(i * 10),
            .c = @splat(@intCast(i)),
            .s = s,
            .z = z,
            .l = list,
        });
    }

    var buffer: [32768]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try ss.serialize(&w);

    var r = std.Io.Reader.fixed(&buffer);
    var ss2 = try SparseSet(Some).deserialize(gpa, &r);

    for (0..10) |i| {
        const val = ss2.get(ids[i]).?;
        try std.testing.expect(val.a == @as(u32, @intCast(i)));
        try std.testing.expect(val.b == @as(f32, @floatFromInt(i * 10)));
        const b: [4]u8 = @splat(@intCast(i));
        try std.testing.expect(std.mem.eql(u8, &val.c, &b));
        try std.testing.expectEqual(val.s[0], 0);
        try std.testing.expectEqual(val.z.*, 69);

        try std.testing.expectEqual(val.l.items[0], 420);
        try std.testing.expectEqual(val.l.items[1], 421);
    }
}
