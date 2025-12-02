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

        /// !!Only for primitave data, pointers are not resolved!!
        pub fn serialize(self: *const Self, writer: *std.Io.Writer) !void {
            try writer.writeInt(u32, @intCast(self.items.items.len), .little);

            for (self.items.items) |slot| {
                try writer.writeAll(std.mem.asBytes(&slot));
            }

            try writer.writeInt(u32, @intCast(self.unused.items.len), .little);
            for (self.unused.items) |handle| {
                try writer.writeAll(std.mem.asBytes(&handle));
            }

            try writer.flush();
        }

        pub fn deserialize(gpa: std.mem.Allocator, reader: *std.Io.Reader) !Self {
            const items_size = try reader.takeInt(u32, .little);

            var self = Self{
                .items = .{},
                .unused = .{},
            };

            for (0..items_size) |_| {
                var slot: Slot = undefined;
                const slot_bytes = std.mem.asBytes(&slot);
                const bytes = try reader.take(slot_bytes.len);
                @memcpy(slot_bytes, bytes);
                try self.items.append(gpa, slot);
            }

            const unused_size = try reader.takeInt(u32, .little);
            for (0..unused_size) |_| {
                var handle: Handle = undefined;
                const handle_bytes = std.mem.asBytes(&handle);
                const bytes = try reader.take(handle_bytes.len);
                @memcpy(handle_bytes, bytes);
                try self.unused.append(gpa, handle);
            }

            return self;
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

test "serialize deserialize" {
    const Some = struct {
        a: u32,
        b: f32,
        c: [4]u8,
    };

    var sm = SlotMap(Some){};
    defer sm.deinit(std.testing.allocator);

    var handles: [10]SlotMap(Some).Handle = undefined;

    for (0..10) |i| {
        handles[i] = try sm.insert(std.testing.allocator, .{
            .a = @intCast(i),
            .b = @floatFromInt(i * 10),
            .c = @splat(@intCast(i)),
        });
    }

    var buffer: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try sm.serialize(&w);

    var r = std.Io.Reader.fixed(&buffer);
    var sm2 = try SlotMap(Some).deserialize(std.testing.allocator, &r);
    defer sm2.deinit(std.testing.allocator);

    for (0..0) |i| {
        const val = sm2.get(handles[i]).?;
        try std.testing.expect(val.a == @as(u32, @intCast(i)));
        try std.testing.expect(val.b == @as(f32, @floatFromInt(i * 10)));
        const b: [4]u8 = @splat(@intCast(i));
        try std.testing.expect(std.mem.eql(u8, val.c, b));
    }
}
