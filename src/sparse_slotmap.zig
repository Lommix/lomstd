const std = @import("std");
const s2b = @import("s2b.zig");

const SlotMap = @import("slotmap.zig").SlotMap;

/// A generational handle to data map with O(1) access backed by a dense array.
pub fn SparseSlotMap(comptime T: type) type {
    return struct {
        // ---------------
        slotmap: SlotMap(usize) = .{},
        dense: std.ArrayList(T) = .{},
        dense_to_handle: std.ArrayList(Handle) = .{},
        // ---------------

        const Self = @This();
        pub const Handle = SlotMap(usize).Handle;

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.dense.deinit(gpa);
            self.dense_to_handle.deinit(gpa);
            self.slotmap.deinit(gpa);
        }

        pub fn items(self: *Self) []T {
            return self.dense.items;
        }

        pub fn handles(self: *Self) []Handle {
            return self.dense_to_handle.items;
        }

        pub fn itemsConst(self: *const Self) []const T {
            return self.dense.items;
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, val: T) !Handle {
            try self.dense.append(gpa, val);
            const id = self.dense.items.len - 1;
            const handle = try self.slotmap.insert(gpa, id);
            try self.dense_to_handle.append(gpa, handle);
            return handle;
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            const id = self.slotmap.get(handle) orelse return null;
            return &self.dense.items[id];
        }

        pub fn getConst(self: *Self, handle: Handle) ?*const T {
            const id = self.slotmap.get(handle) orelse return null;
            return &self.dense.items[id];
        }

        pub fn remove(self: *Self, gpa: std.mem.Allocator, handle: Handle) !T {
            const id = self.slotmap.get(handle) orelse return error.NotFound;
            try self.slotmap.remove(gpa, handle);

            const val = self.dense.swapRemove(id);
            _ = self.dense_to_handle.swapRemove(id);

            if (id < self.dense.items.len) {
                const end_handle = self.dense_to_handle.items[id];
                const end_id = self.slotmap.getPtr(end_handle).?;
                end_id.* = id;
            }

            return val;
        }

        /// !!Only for primitive data, pointers are not resolved!!
        pub fn serialize(self: *const Self, writer: *std.Io.Writer) !void {
            // Serialize the underlying slotmap
            try self.slotmap.serialize(writer);

            // Serialize dense array length and contents
            try writer.writeInt(u32, @intCast(self.dense.items.len), .little);
            for (self.dense.items) |item| {
                try s2b.binarySerialize(T, item, writer);
            }

            // Serialize dense_to_handle mapping
            try writer.writeInt(u32, @intCast(self.dense_to_handle.items.len), .little);
            for (self.dense_to_handle.items) |handle| {
                try s2b.binarySerialize(Handle, handle, writer);
            }

            try writer.flush();
        }

        pub fn deserialize(gpa: std.mem.Allocator, reader: *std.Io.Reader) !Self {
            // Deserialize the underlying slotmap
            const slotmap_inst = try SlotMap(usize).deserialize(gpa, reader);

            var self = Self{
                .slotmap = slotmap_inst,
                .dense = .{},
                .dense_to_handle = .{},
            };

            // Deserialize dense array
            const dense_len = try reader.takeInt(u32, .little);
            for (0..dense_len) |_| {
                const item = try s2b.binaryDeserialize(T, gpa, reader);
                try self.dense.append(gpa, item);
            }

            // Deserialize dense_to_handle mapping
            const handle_count = try reader.takeInt(u32, .little);
            for (0..handle_count) |_| {
                const item = try s2b.binaryDeserialize(Handle, gpa, reader);
                try self.dense_to_handle.append(gpa, item);
            }

            return self;
        }
    };
}

test "sparse_slot_map insert" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var ssm = SparseSlotMap(u32){};
    defer ssm.deinit(alloc);

    const h1 = try ssm.insert(alloc, 42);
    try expect(ssm.get(h1).?.* == 42);
    try expect(ssm.dense.items.len == 1);

    const h2 = try ssm.insert(alloc, 100);
    const h3 = try ssm.insert(alloc, 200);
    try expect(ssm.dense.items.len == 3);

    try expect(ssm.get(h1).?.* == 42);
    try expect(ssm.get(h2).?.* == 100);
    try expect(ssm.get(h3).?.* == 200);
}

test "sparse_slot_map remove" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var ssm = SparseSlotMap(u32){};
    defer ssm.deinit(alloc);

    const h1 = try ssm.insert(alloc, 10);
    const h2 = try ssm.insert(alloc, 20);
    const h3 = try ssm.insert(alloc, 30);
    try expect(ssm.dense.items.len == 3);

    const removed = try ssm.remove(alloc, h2);
    try expect(removed == 20);
    try expect(ssm.dense.items.len == 2);
    try expect(ssm.get(h2) == null); // h2 should be invalid

    const removed2 = try ssm.remove(alloc, h1);
    try expect(removed2 == 10);
    try expect(ssm.dense.items.len == 1);
    try expect(ssm.get(h2) == null); // h2 should be invalid

    try expect(ssm.get(h3).?.* == 30);
}

test "sparse_slot_map insert and remove interleaved" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var ssm = SparseSlotMap(u32){};
    defer ssm.deinit(alloc);

    const h1 = try ssm.insert(alloc, 1);
    const h2 = try ssm.insert(alloc, 2);
    const h3 = try ssm.insert(alloc, 3);
    const h4 = try ssm.insert(alloc, 4);
    try expect(ssm.dense.items.len == 4);

    const r1 = try ssm.remove(alloc, h1);
    try expect(r1 == 1);
    try expect(ssm.dense.items.len == 3);
    try expect(ssm.get(h1) == null);

    const h5 = try ssm.insert(alloc, 5);
    try expect(ssm.dense.items.len == 4);
    try expect(ssm.get(h5).?.* == 5);

    const r2 = try ssm.remove(alloc, h3);
    try expect(r2 == 3);
    try expect(ssm.dense.items.len == 3);

    try expect(ssm.get(h2).?.* == 2);
    try expect(ssm.get(h4).?.* == 4);
    try expect(ssm.get(h5).?.* == 5);
}

test "sparse_slot_map remove first then all" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var ssm = SparseSlotMap(u32){};
    defer ssm.deinit(alloc);

    const h1 = try ssm.insert(alloc, 100);
    const h2 = try ssm.insert(alloc, 200);
    const h3 = try ssm.insert(alloc, 300);

    _ = try ssm.remove(alloc, h1);
    try expect(ssm.dense.items.len == 2);
    try expect(ssm.get(h1) == null);
    try expect(ssm.get(h2).?.* == 200);
    try expect(ssm.get(h3).?.* == 300);

    _ = try ssm.remove(alloc, h2);
    try expect(ssm.dense.items.len == 1);
    try expect(ssm.get(h2) == null);
    try expect(ssm.get(h3).?.* == 300);

    _ = try ssm.remove(alloc, h3);
    try expect(ssm.dense.items.len == 0);
    try expect(ssm.get(h3) == null);
}

test "sparse_slot_map many operations" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var ssm = SparseSlotMap(u32){};
    defer ssm.deinit(alloc);

    var handles: [100]SparseSlotMap(u32).Handle = undefined;

    for (0..100) |i| {
        handles[i] = try ssm.insert(alloc, @intCast(i));
    }
    try expect(ssm.dense.items.len == 100);

    for (0..100) |i| {
        try expect(ssm.get(handles[i]).?.* == @as(u32, @intCast(i)));
    }

    for (0..50) |i| {
        const val = try ssm.remove(alloc, handles[i * 2]);
        try expect(val == i * 2);
    }
    try expect(ssm.dense.items.len == 50);

    for (0..50) |i| {
        const idx = i * 2 + 1;
        try expect(ssm.get(handles[idx]).?.* == @as(u32, @intCast(idx)));
    }
}

test "sparse_slot_map serialize deserialize" {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const alloc = std.testing.allocator;

    var ssm = SparseSlotMap(u32){};
    defer ssm.deinit(alloc);

    const h1 = try ssm.insert(alloc, 42);
    const h2 = try ssm.insert(alloc, 100);
    const h3 = try ssm.insert(alloc, 200);

    _ = try ssm.remove(alloc, h2);

    var buffer: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try ssm.serialize(&w);

    var r = std.Io.Reader.fixed(&buffer);
    var ssm2 = try SparseSlotMap(u32).deserialize(alloc, &r);
    defer ssm2.deinit(alloc);

    try expectEqual(ssm2.dense.items.len, @as(usize, 2));
    try expect(ssm2.get(h1) != null);
    try expectEqual(ssm2.get(h1).?.*, @as(u32, 42));
    try expect(ssm2.get(h2) == null); // h2 was removed
    try expect(ssm2.get(h3) != null);
    try expectEqual(ssm2.get(h3).?.*, @as(u32, 200));
}
