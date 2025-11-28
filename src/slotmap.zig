const std = @import("std");

pub const SlotState = union(enum) {
    unused,
    gen: u32,
};

pub fn SlotValue(comptime T: type) type {
    return struct {
        state: SlotState,
        data: T,
    };
}

/// A generational handle to data map with O(1) access.
pub fn SlotMap(comptime T: type) type {
    const Slot = SlotValue(T);

    return struct {
        items: std.ArrayList(Slot) = .{},
        unused: std.ArrayList(Handle) = .{},

        const Self = @This();
        pub const Handle = struct {
            id: u32,
            gen: u32,
        };

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.items.deinit(gpa);
            self.unused.deinit(gpa);
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, value: T) !Handle {
            if (self.unused.pop()) |h| {
                self.items.items[h.id].data = value;
                self.items.items[h.id].state = .{ .gen = h.gen };
                return h;
            }

            try self.items.append(gpa, .{ .data = value, .state = .{ .gen = 0 } });

            return .{
                .id = @intCast(self.items.items.len - 1),
                .gen = 0,
            };
        }

        pub fn get(self: *Self, handle: Handle) ?T {
            if (handle.id >= self.items.items.len) return null;
            switch (self.items.items[handle.id].state) {
                .unused => return null,
                .gen => |gen| if (gen != handle.gen) return null,
            }
            return self.items.items[handle.id].data;
        }

        pub fn getPtr(self: *Self, handle: Handle) ?*T {
            if (handle.id >= self.items.items.len) return null;
            switch (self.items.items[handle.id].state) {
                .unused => return null,
                .gen => |gen| if (gen != handle.gen) return null,
            }
            return &self.items.items[handle.id].data;
        }

        pub fn getPtrConst(self: *const Self, handle: Handle) ?*const T {
            if (handle.id >= self.items.items.len) return null;
            switch (self.items.items[handle.id].state) {
                .unused => return null,
                .gen => |gen| if (gen != handle.gen) return null,
            }
            return &self.items.items[handle.id].data;
        }

        pub fn remove(self: *Self, gpa: std.mem.Allocator, handle: Handle) !void {
            if (handle.id >= self.items.items.len) return;
            switch (self.items.items[handle.id].state) {
                .unused => return,
                .gen => |gen| if (gen != handle.gen) return,
            }

            self.items.items[handle.id].state = .unused;
            try self.unused.append(gpa, .{
                .gen = handle.gen +% 1,
                .id = handle.id,
            });
        }
    };
}

test "insert single entry" {
    var sm = SlotMap(u32){};
    defer sm.items.deinit(std.testing.allocator);
    defer sm.unused.deinit(std.testing.allocator);

    const h1 = try sm.insert(std.testing.allocator, 42);
    try std.testing.expectEqual(h1.id, 0);
    try std.testing.expectEqual(h1.gen, 0);
    try std.testing.expectEqual(sm.get(h1), 42);
}

test "insert multiple entries" {
    var sm = SlotMap(u32){};
    defer sm.deinit(std.testing.allocator);

    const h1 = try sm.insert(std.testing.allocator, 10);
    const h2 = try sm.insert(std.testing.allocator, 20);
    const h3 = try sm.insert(std.testing.allocator, 30);

    try std.testing.expectEqual(h1.id, 0);
    try std.testing.expectEqual(h2.id, 1);
    try std.testing.expectEqual(h3.id, 2);

    try std.testing.expectEqual(sm.get(h1), 10);
    try std.testing.expectEqual(sm.get(h2), 20);
    try std.testing.expectEqual(sm.get(h3), 30);
}

test "insert and remove single entry" {
    var sm = SlotMap(u32){};
    defer sm.deinit(std.testing.allocator);

    const h1 = try sm.insert(std.testing.allocator, 42);
    try std.testing.expectEqual(sm.get(h1), 42);

    try sm.remove(std.testing.allocator, h1);
    try std.testing.expectEqual(sm.get(h1), null);
}

test "insert and remove multiple entries" {
    var sm = SlotMap(u32){};
    defer sm.deinit(std.testing.allocator);

    const h1 = try sm.insert(std.testing.allocator, 10);
    const h2 = try sm.insert(std.testing.allocator, 20);
    const h3 = try sm.insert(std.testing.allocator, 30);

    try sm.remove(std.testing.allocator, h2);

    try std.testing.expectEqual(sm.get(h1), 10);
    try std.testing.expectEqual(sm.get(h2), null);
    try std.testing.expectEqual(sm.get(h3), 30);
}

test "remove and reinsert slot" {
    var sm = SlotMap(u32){};
    defer sm.deinit(std.testing.allocator);

    const h1 = try sm.insert(std.testing.allocator, 10);
    try sm.remove(std.testing.allocator, h1);

    // Reinserting should reuse the slot with incremented generation
    const h2 = try sm.insert(std.testing.allocator, 20);

    try std.testing.expectEqual(h2.id, h1.id);
    try std.testing.expectEqual(h2.gen, h1.gen + 1);
    try std.testing.expectEqual(sm.get(h2), 20);

    // Old handle should not work
    try std.testing.expectEqual(sm.get(h1), null);
}

test "remove multiple entries and verify handles invalid" {
    var sm = SlotMap(u32){};
    defer sm.deinit(std.testing.allocator);

    const h1 = try sm.insert(std.testing.allocator, 100);
    const h2 = try sm.insert(std.testing.allocator, 200);
    const h3 = try sm.insert(std.testing.allocator, 300);
    const h4 = try sm.insert(std.testing.allocator, 400);

    try sm.remove(std.testing.allocator, h1);
    try sm.remove(std.testing.allocator, h3);

    try std.testing.expectEqual(sm.get(h1), null);
    try std.testing.expectEqual(sm.get(h2), 200);
    try std.testing.expectEqual(sm.get(h3), null);
    try std.testing.expectEqual(sm.get(h4), 400);
}

test "insert remove insert pattern" {
    var sm = SlotMap(u32){};
    defer sm.deinit(std.testing.allocator);

    const h1 = try sm.insert(std.testing.allocator, 10);
    const h2 = try sm.insert(std.testing.allocator, 20);
    const h3 = try sm.insert(std.testing.allocator, 30);

    try sm.remove(std.testing.allocator, h1);
    try sm.remove(std.testing.allocator, h3);

    // Insert more, should reuse removed slots
    const h4 = try sm.insert(std.testing.allocator, 40);
    const h5 = try sm.insert(std.testing.allocator, 50);

    try std.testing.expectEqual(sm.get(h2), 20);
    try std.testing.expectEqual(sm.get(h4), 40);
    try std.testing.expectEqual(sm.get(h5), 50);
}

test "get with pointer" {
    var sm = SlotMap(u32){};
    defer sm.deinit(std.testing.allocator);

    const h1 = try sm.insert(std.testing.allocator, 42);
    const h2 = try sm.insert(std.testing.allocator, 100);

    if (sm.getPtr(h1)) |ptr| {
        ptr.* = 50;
    }

    try std.testing.expectEqual(sm.get(h1), 50);
    try std.testing.expectEqual(sm.get(h2), 100);
}

test "get const pointer" {
    var sm = SlotMap(u32){};
    defer sm.deinit(std.testing.allocator);

    const h1 = try sm.insert(std.testing.allocator, 42);
    const h2 = try sm.insert(std.testing.allocator, 100);

    if (sm.getPtrConst(h1)) |ptr| {
        try std.testing.expectEqual(ptr.*, 42);
    } else {
        return error.TestFailure;
    }

    try std.testing.expectEqual(sm.get(h2), 100);
}
