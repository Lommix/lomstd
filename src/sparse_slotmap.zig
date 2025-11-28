const std = @import("std");

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
    };
}

test "sparse_slot_map insert" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var ssm = SparseSlotMap(u32){};
    defer ssm.deinit(alloc);

    // Insert single value
    const h1 = try ssm.insert(alloc, 42);
    try expect(ssm.get(h1).?.* == 42);
    try expect(ssm.dense.items.len == 1);

    // Insert multiple values
    const h2 = try ssm.insert(alloc, 100);
    const h3 = try ssm.insert(alloc, 200);
    try expect(ssm.dense.items.len == 3);

    // Verify all values are correct
    try expect(ssm.get(h1).?.* == 42);
    try expect(ssm.get(h2).?.* == 100);
    try expect(ssm.get(h3).?.* == 200);
}

test "sparse_slot_map remove" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var ssm = SparseSlotMap(u32){};
    defer ssm.deinit(alloc);

    // Insert values
    const h1 = try ssm.insert(alloc, 10);
    const h2 = try ssm.insert(alloc, 20);
    const h3 = try ssm.insert(alloc, 30);
    try expect(ssm.dense.items.len == 3);

    // Remove middle value
    const removed = try ssm.remove(alloc, h2);
    try expect(removed == 20);
    try expect(ssm.dense.items.len == 2);
    try expect(ssm.get(h2) == null); // h2 should be invalid

    const removed2 = try ssm.remove(alloc, h1);
    try expect(removed2 == 10);
    try expect(ssm.dense.items.len == 1);
    try expect(ssm.get(h2) == null); // h2 should be invalid

    // Remaining values should still be accessible
    try expect(ssm.get(h3).?.* == 30);
}

test "sparse_slot_map insert and remove interleaved" {
    const expect = std.testing.expect;
    const alloc = std.testing.allocator;

    var ssm = SparseSlotMap(u32){};
    defer ssm.deinit(alloc);

    // Insert some values
    const h1 = try ssm.insert(alloc, 1);
    const h2 = try ssm.insert(alloc, 2);
    const h3 = try ssm.insert(alloc, 3);
    const h4 = try ssm.insert(alloc, 4);
    try expect(ssm.dense.items.len == 4);

    // Remove first
    const r1 = try ssm.remove(alloc, h1);
    try expect(r1 == 1);
    try expect(ssm.dense.items.len == 3);
    try expect(ssm.get(h1) == null);

    // Insert new value (should reuse slot in slotmap)
    const h5 = try ssm.insert(alloc, 5);
    try expect(ssm.dense.items.len == 4);
    try expect(ssm.get(h5).?.* == 5);

    // Remove another
    const r2 = try ssm.remove(alloc, h3);
    try expect(r2 == 3);
    try expect(ssm.dense.items.len == 3);

    // Verify remaining values
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

    // Remove first
    _ = try ssm.remove(alloc, h1);
    try expect(ssm.dense.items.len == 2);
    try expect(ssm.get(h1) == null);
    try expect(ssm.get(h2).?.* == 200);
    try expect(ssm.get(h3).?.* == 300);

    // Remove second (first in dense array now)
    _ = try ssm.remove(alloc, h2);
    try expect(ssm.dense.items.len == 1);
    try expect(ssm.get(h2) == null);
    try expect(ssm.get(h3).?.* == 300);

    // Remove last
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

    // Insert 100 values
    for (0..100) |i| {
        handles[i] = try ssm.insert(alloc, @intCast(i));
    }
    try expect(ssm.dense.items.len == 100);

    // Verify all are accessible
    for (0..100) |i| {
        try expect(ssm.get(handles[i]).?.* == @as(u32, @intCast(i)));
    }

    // Remove every other element
    for (0..50) |i| {
        const val = try ssm.remove(alloc, handles[i * 2]);
        try expect(val == i * 2);
    }
    try expect(ssm.dense.items.len == 50);

    // Verify remaining odd-indexed elements
    for (0..50) |i| {
        const idx = i * 2 + 1;
        try expect(ssm.get(handles[idx]).?.* == @as(u32, @intCast(idx)));
    }
}
