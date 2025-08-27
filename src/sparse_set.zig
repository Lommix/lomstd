const std = @import("std");

/// Sparse Set, the regular
pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();
        const MAX_PAGE_SIZE: u32 = 1024;
        dense: std.ArrayList(T) = .{},
        dense_to_sparse: std.ArrayList(u32) = .{},
        sparse: std.ArrayList([MAX_PAGE_SIZE]?u32) = .{},

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
                try self.sparse.append(gpa, [_]?u32{null} ** MAX_PAGE_SIZE);
            }

            if (self.sparse.items[page_index][page_slot]) |existing_dense_id| {
                self.dense.items[existing_dense_id] = data;
                return &self.dense.items[existing_dense_id];
            } else {
                try self.dense.append(gpa, data);
                try self.dense_to_sparse.append(gpa, id);
                const dense_id = self.dense.items.len - 1;
                self.sparse.items[page_index][page_slot] = @intCast(dense_id);
                return &self.dense.items[dense_id];
            }
        }

        pub inline fn getConst(self: *const Self, id: u32) ?*const T {
            const page_index = id >> 10;
            const page_slot = id & 1023;
            if (page_index >= self.sparse.items.len) return null;
            const dense_id = self.sparse.items[page_index][page_slot] orelse return null;
            return &self.dense.items[dense_id];
        }

        pub inline fn get(self: *Self, id: u32) ?*T {
            const page_index = id >> 10;
            const page_slot = id & 1023;
            if (page_index >= self.sparse.items.len) return null;
            const dense_id = self.sparse.items[page_index][page_slot] orelse return null;
            return &self.dense.items[dense_id];
        }

        pub fn items(self: *Self) []T {
            return self.dense.items;
        }

        pub fn remove(self: *Self, id: u32) void {
            const page_index = id >> 10;
            const page_slot = id & 1023;
            // check len
            const dense_id = self.sparse.items[page_index][page_slot] orelse return;
            self.sparse.items[page_index][page_slot] = null;

            // do not swap on last item in list
            const back_id = self.dense_to_sparse.items[self.dense.items.len - 1];
            if (back_id != id) {
                const back_page_index = back_id >> 10;
                const back_page_slot = back_id & 1023;
                self.sparse.items[back_page_index][back_page_slot] = dense_id;
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
    };
}
