const std = @import("std");
const m = @import("zmath.zig");
const tr = @import("tree.zig");
// const hashStr = @import("hash.zig").hashStr;
const UiTree = tr.MultiTree(Node);

// full responsive layout engine

tree: UiTree = .{},
states: std.ArrayList(State) = .{},
hash_to_index: std.AutoHashMapUnmanaged(u32, usize) = .{},
mouse_in_ui: bool = false,

pub const Node = struct {
    state_hash: ?u32 = null,
    ctx: ?*anyopaque = null,
    style: Style = .{},
    computed: Area = .{},
    /// user provided render function
    render: ?*const fn (gpa: std.mem.Allocator, node: *Node, ctx: ?*anyopaque) anyerror!void = null,
    /// user provided size function
    size: *const fn (node: *Node) Area = &default_size,
};

pub const State = struct {
    hash: u32,
    used: bool = false,
    flags: Flags = .{},
    hover_dt: f32 = 0,
    pressed_dt: f32 = 0,
};

const Flags = packed struct {
    hovered: bool = false,
    pressed: bool = false,
    just_pressed: bool = false,
    just_released: bool = false,
    entered: bool = false,
    exited: bool = false,
    // focus: bool = false,
    updated: bool = false,
    active: bool = false,
    entered_active: bool = false,
    exit_active: bool = false,
    dragged: bool = false,
};

pub const Area = struct {
    const Self = @This();
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    clip: [4]f32 = .{ -std.math.inf(f32), -std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },

    pub fn pad(self: Self, val: f32) Self {
        var s = self;
        s.x += val;
        s.y += val;
        s.width = @max(0, s.width - val * 2);
        s.height = @max(0, s.height - val * 2);
        return s;
    }

    pub fn padX(self: Self, val: f32) Self {
        var s = self;
        s.x += val;
        s.width = @max(0, s.width - val * 2);
        return s;
    }

    pub fn padY(self: Self, val: f32) Self {
        var s = self;
        s.y += val;
        s.height = @max(0, s.height - val * 2);
        return s;
    }

    pub fn center(self: Self, width: f32, height: f32) Self {
        const hw = @divTrunc(@max(0, self.width - width), 2);
        const hh = @divTrunc(@max(0, self.height - height), 2);

        var s = self;
        s.x += hw;
        s.y += hh;
        s.width = @max(0, s.width - hw * 2);
        s.height = @max(0, s.height - hh * 2);
        return s;
    }

    pub fn intersect_point(self: *const Self, x: f32, y: f32) bool {
        return self.x < x and self.y < y and self.x + self.width > x and self.y + self.height > y;
    }

    pub fn intersect(self: *const Self, x: f32, y: f32) bool {
        return self.x < x and x < self.x + self.width and self.y > y and y > self.y - self.height;
    }

    pub fn offset(self: Self, x: f32, y: f32) Self {
        return Self{
            .x = self.x + x,
            .y = self.y + y,
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn grow(self: Self, percent: f32) Self {
        return Self{
            .x = self.x,
            .y = self.y,
            .width = self.width * percent,
            .height = self.height * percent,
        };
    }

    pub fn lerp(self: Self, lhs: *Self, r: f32) Self {
        return Self{
            .x = std.math.lerp(self.x, lhs.x, r),
            .y = std.math.lerp(self.y, lhs.y, r),
            .width = std.math.lerp(self.width, lhs.width, r),
            .height = std.math.lerp(self.height, lhs.height, r),
        };
    }
};

pub const Val = union(enum) {
    px: f32,
    perc: f32,
    grow,
    shrink,

    pub fn get(self: Val) f32 {
        return switch (self) {
            .px => |p| p,
            else => 0,
        };
    }
};

pub const Padding = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
    pub fn axis(_x: f32, _y: f32) Padding {
        return .{ .top = _y, .right = _x, .bottom = _y, .left = _x };
    }
    pub fn all(v: f32) Padding {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }
    pub fn x(v: f32) Padding {
        return .{ .right = v, .left = v };
    }
    pub fn y(v: f32) Padding {
        return .{ .top = v, .bottom = v };
    }
    pub fn getX(self: *const Padding) f32 {
        return self.right + self.left;
    }
    pub fn getY(self: *const Padding) f32 {
        return self.top + self.bottom;
    }
};

pub const Position = enum {
    relative,
    absolute,
};

pub fn default_size(node: *Node) Area {
    return .{
        .x = 0,
        .y = 0,
        .width = node.style.width.get(),
        .height = node.style.height.get(),
    };
}

pub const Style = struct {
    width: Val = .shrink,
    height: Val = .shrink,
    padding: Padding = .{},
    gap: f32 = 0,
    display: Display = .col,
    position: Position = .relative,
    align_x: Align = .start,
    align_y: Align = .start,
    delay: f32 = 200,
    bg: m.Vec = @splat(0),
    fg: m.Vec = @splat(1),
    rect: ?m.Vec = null,
    patch: m.Vec = @splat(0),
    top: Val = .shrink,
    left: Val = .shrink,
    font_size: f32 = 16,
    z: f32 = 0,
    min_width: ?f32 = null,
    max_width: ?f32 = null,
    min_height: ?f32 = null,
    max_height: ?f32 = null,
    overflow: Overflow = .visible,
};

pub const Overflow = enum {
    visible,
    hidden,
};

pub const Display = union(enum) {
    row,
    col,
    grid: u32,
};

pub const Align = enum {
    start,
    center,
    end,
};

pub const Context = struct {
    const Self = @This();
    const MAXDEPTH: u32 = 32;
    hash: u32,
    parent: UiTree.NodeID,
    hash_stack: [MAXDEPTH]u32 = undefined,
    hash_stack_len: u32 = 0,

    pub fn salt(self: *Context, hash: u32) u32 {
        std.debug.assert(self.hash_stack_len < MAXDEPTH);
        self.hash ^= hash;
        self.hash_stack[self.hash_stack_len] = hash;
        self.hash_stack_len += 1;
        return self.hash;
    }

    pub fn pop(self: *Context) void {
        if (self.hash_stack_len == 0) return;

        self.hash_stack_len -|= 1;
        self.hash ^= self.hash_stack[self.hash_stack_len];
    }
};

pub fn compute_ui(
    self: *@This(),
    world_gpa: std.mem.Allocator,
    frame_gpa: std.mem.Allocator,
    dt: f32,
    mouse: MouseState,
) !void {
    self.mouse_in_ui = false;

    for (self.tree.roots.items) |root_id| {
        var nodes: std.ArrayList(u32) = .{};
        var it = self.tree.IterateBreathedFirst(frame_gpa, root_id);
        while (it.next()) |entry| try nodes.append(frame_gpa, entry.node_id);
        // const root = ui.res.tree.getValue(root_id);
        // _ = root; // autofix

        // 1.) fit size width bottom up
        for (0..nodes.items.len) |i| {
            const id = nodes.items[nodes.items.len - i -| 1];
            compute_fit_axis(true, &self.tree, id);
        }

        // 2.) grow & shrink width
        for (nodes.items) |id| {
            compute_grow_axis(true, &self.tree, id);
        }

        // 3.) wrap text
        for (nodes.items) |id| {
            const node = self.tree.getValue(id);
            const size = node.size(node);
            node.computed.height = size.height;
            // node.computed.width = size.width;
            // std.debug.print("{d}\n", .{size.width});
        }

        // 4.) fit sizing heights
        for (0..nodes.items.len) |i| {
            const id = nodes.items[nodes.items.len - i -| 1];
            compute_fit_axis(false, &self.tree, id);
        }
        // 5.) grow & shrink heights
        for (nodes.items) |id| {
            compute_grow_axis(false, &self.tree, id);
        }

        // 6.) Position
        for (nodes.items) |id| {
            compute_position(&self.tree, id);
            self.compute_state(world_gpa, mouse, dt, id);
        }

        for (0..self.states.items.len) |i| {
            const index = self.states.items.len - i - 1;
            if (!self.states.items[index].used) {
                _ = self.states.swapRemove(index);
            }
        }
    }
}

pub const MouseState = struct {
    pressed: bool = false,
    just_pressed: bool = false,
    just_released: bool = false,
    x: f32 = 0,
    y: f32 = 0,
};

fn compute_state(self: *@This(), gpa: std.mem.Allocator, mouse: MouseState, delta: f32, id: u32) void {
    const node = self.tree.getValue(id);
    const hash = node.state_hash orelse return;
    const state = self.getState(gpa, hash) catch return;

    const dt = delta * (1 / (node.style.delay / 1000));
    const mx = mouse.x;
    const my = mouse.y;

    state.flags.hovered = node.computed.intersect(mx, my);
    state.flags.pressed = mouse.pressed and state.flags.hovered;
    state.flags.updated = true;
    state.flags.just_pressed = mouse.just_pressed and state.flags.hovered;
    state.flags.just_released = mouse.just_pressed and state.flags.hovered;

    self.mouse_in_ui = self.mouse_in_ui | state.flags.hovered;

    if (state.flags.just_pressed) state.flags.dragged = true;
    if (mouse.just_released) state.flags.dragged = false;

    const was_active = state.flags.active;
    if (state.flags.just_pressed) state.flags.active = !state.flags.active;
    state.flags.entered_active = !was_active and state.flags.active;
    state.flags.exit_active = was_active and !state.flags.active;
    if (state.flags.pressed) state.pressed_dt = @min(1, state.pressed_dt + dt) else state.pressed_dt = @max(0, state.pressed_dt - dt);
    if (state.flags.hovered) state.hover_dt = @min(1, state.hover_dt + dt) else state.hover_dt = @max(0, state.hover_dt - dt);
}

fn clamp_size(value: f32, min_val: ?f32, max_val: ?f32) f32 {
    var v = value;
    if (min_val) |mn| v = @max(v, mn);
    if (max_val) |mx| v = @min(v, mx);
    return v;
}

fn compute_fit_axis(x_axis: bool, tree: *UiTree, id: u32) void {
    const node = tree.getValue(id);
    var child_itr = tree.IterateChildren(id);
    var child_count: u32 = 0;
    var value: f32 = 0;
    const should_sum = x_axis and node.style.display == .row or !x_axis and node.style.display == .col;

    // Handle grid layout separately
    if (node.style.display == .grid) {
        var count: u32 = 0;
        var current: f32 = 0;
        var rows: u32 = 0;
        const columns = node.style.display.grid;
        var max_cols: bool = false;

        while (child_itr.next()) |child| {
            if (x_axis) {
                current += child.value.computed.width;
                count += 1;
                if (count >= columns) {
                    value = @max(current, value);
                    current = 0;
                    count = 0;
                    rows += 1;
                    max_cols = true;
                }
            } else {
                current = @max(current, child.value.computed.height);
                count += 1;
                if (count >= columns) {
                    value += current;
                    current = 0;
                    count = 0;
                    rows += 1;
                    max_cols = true;
                }
            }
        }

        if (x_axis) {
            value = @max(current, value);
            node.computed.width = value + node.style.padding.getX();
            if (max_cols) {
                node.computed.width += @as(f32, @floatFromInt(columns)) * node.style.gap;
            } else {
                node.computed.width += @as(f32, @floatFromInt(count)) * node.style.gap;
            }
            node.computed.width = clamp_size(node.computed.width, node.style.min_width, node.style.max_width);
        } else {
            value += current;
            node.computed.height = value + node.style.padding.getY();
            node.computed.height += @as(f32, @floatFromInt(rows)) * node.style.gap;
            node.computed.height = clamp_size(node.computed.height, node.style.min_height, node.style.max_height);
        }

        return;
    }

    while (child_itr.next()) |child| {
        if (child.value.style.position == .absolute) continue;

        const axis = if (x_axis) child.value.computed.width else child.value.computed.height;
        child_count += 1;

        if (should_sum) {
            value += axis;
        } else {
            value = @max(value, axis);
        }
    }
    // gap
    value += if (should_sum) node.style.gap * @as(f32, @floatFromInt(child_count -| 1)) else 0;
    // pad
    value += if (x_axis) node.style.padding.getX() else node.style.padding.getY();

    if (x_axis) {
        node.computed.width = @max(value, @max(node.style.width.get(), node.computed.width));
        if (node.style.position == .absolute) node.computed.width -= node.style.padding.getX();
        node.computed.width = clamp_size(node.computed.width, node.style.min_width, node.style.max_width);
    } else {
        node.computed.height = @max(value, @max(node.style.height.get(), node.computed.height));
        if (node.style.position == .absolute) node.computed.height -= node.style.padding.getY();
        node.computed.height = clamp_size(node.computed.height, node.style.min_height, node.style.max_height);
    }
}

fn compute_grow_axis(x_axis: bool, tree: *UiTree, id: u32) void {
    const node = tree.getValue(id);
    var child_itr = tree.IterateChildren(id);
    var child_count: u32 = 0;
    var grow_count: u32 = 0;
    var remaining = if (x_axis) node.computed.width else node.computed.height;
    const should_sum = x_axis and node.style.display == .row or !x_axis and node.style.display == .col;

    while (child_itr.next()) |child| {
        if (child.value.style.position == .absolute) continue;
        const child_axis = if (x_axis) child.value.style.width else child.value.style.height;
        child_count += 1;

        switch (child_axis) {
            .grow => grow_count += 1,
            .perc => grow_count += 1,
            .px => |p| {
                if (should_sum) remaining -= @max(0, p);
            },
            .shrink => {
                if (should_sum) remaining -= @max(0, if (x_axis) child.value.computed.width else child.value.computed.height);
            },
        }
    }

    remaining -= if (x_axis) node.style.padding.getX() else node.style.padding.getY();
    if (should_sum) remaining -= node.style.gap;

    child_itr.reset();
    const step = if (should_sum) remaining / @as(f32, @floatFromInt(@max(1, grow_count))) else remaining;
    while (child_itr.next()) |child| {
        const val = if (x_axis) &child.value.computed.width else &child.value.computed.height;
        const child_axis = if (x_axis) child.value.style.width else child.value.style.height;

        switch (child_axis) {
            .grow => val.* = step,
            .perc => |p| {
                var r = remaining;
                if (child.value.style.position == .absolute) {
                    r -= if (x_axis) child.value.style.padding.getX() else child.value.style.padding.getY();
                }

                val.* = r * p;
            },
            else => {},
        }

        if (x_axis) {
            val.* = clamp_size(val.*, child.value.style.min_width, child.value.style.max_width);
        } else {
            val.* = clamp_size(val.*, child.value.style.min_height, child.value.style.max_height);
        }
    }
}

fn compute_position(tree: *UiTree, id: u32) void {
    const node = tree.getValue(id);
    var child_itr = tree.IterateChildren(id);
    var child_count: u32 = 0;

    var total_x: f32 = 0;
    var total_y: f32 = 0;

    var col_count: u32 = 0;
    var col_w: f32 = 0;
    var col_h: f32 = 0;

    while (child_itr.next()) |child| {
        child_count += 1;
        child.value.computed.z = node.computed.z + 50 + child.value.style.z;

        if (child.value.style.position == .absolute) continue;

        switch (node.style.display) {
            .row => {
                total_x += child.value.computed.width;
                total_y = @max(total_y, child.value.computed.height);
            },
            .col => {
                total_y += child.value.computed.height;
                total_x = @max(total_x, child.value.computed.width);
            },
            .grid => |columns| {
                col_w += child.value.computed.width;
                col_h = @max(col_h, child.value.computed.height);

                col_count += 1;

                if (col_count >= columns) {
                    total_x = @max(total_x, col_w);
                    total_y += col_h;
                    col_count = 0;
                    col_w = 0;
                    col_h = 0;
                }
            },
        }
    }

    // finishe grid
    if (node.style.display == .grid) {
        total_x = @max(total_x, col_w);
        total_y += col_h;
        col_h = 0;
        col_w = 0;
        col_count = 0;
    }

    // calc x start
    var x = switch (node.style.align_x) {
        .center => node.computed.x + node.computed.width * 0.5 - total_x * 0.5,
        .start => node.computed.x + node.style.padding.left,
        .end => node.computed.x + node.computed.width - node.style.padding.right - total_x,
    };

    var y = switch (node.style.align_y) {
        .center => node.computed.y - node.computed.height * 0.5 + total_y * 0.5,
        .start => node.computed.y - node.style.padding.top,
        .end => (node.computed.y - node.computed.height) + node.style.padding.bottom + total_y,
    };

    switch (node.style.display) {
        .row => total_x += node.style.gap * @as(f32, @floatFromInt(child_count -| 1)),
        .col => total_y += node.style.gap * @as(f32, @floatFromInt(child_count -| 1)),
        .grid => {},
    }

    // compute effective clip rect for children
    var node_clip = node.computed.clip;
    if (node.style.overflow == .hidden) {
        node_clip[0] = @max(node_clip[0], node.computed.x);
        node_clip[1] = @max(node_clip[1], node.computed.y - node.computed.height);
        node_clip[2] = @min(node_clip[2], node.computed.x + node.computed.width);
        node_clip[3] = @min(node_clip[3], node.computed.y);
    }

    child_itr.reset();

    var gap_count = child_count -| 1;
    while (child_itr.next()) |child| {
        child.value.computed.clip = node_clip;
        const left = switch (child.value.style.left) {
            .perc => |p| p * node.computed.width,
            .px => |p| p,
            else => 0,
        };
        const top = switch (child.value.style.top) {
            .perc => |p| p * node.computed.height,
            .px => |p| p,
            else => 0,
        };

        if (child.value.style.position == .absolute) {
            child.value.computed.x = node.computed.x + child.value.computed.x + child.value.style.padding.left + left;
            child.value.computed.y = node.computed.y - child.value.computed.y - child.value.style.padding.top - top;
            continue;
        }

        child.value.computed.x = x;
        child.value.computed.y = y;

        switch (node.style.display) {
            .row => {
                // align y
                switch (node.style.align_y) {
                    .center => child.value.computed.y = node.computed.y - node.computed.height * 0.5 + child.value.computed.height * 0.5,
                    .end => child.value.computed.y = node.computed.y - node.computed.height + child.value.computed.height + node.style.padding.bottom,
                    .start => {},
                }

                x += child.value.computed.width;
                if (gap_count > 0) {
                    x += node.style.gap;
                    gap_count -|= 1;
                }
            },
            .col => {

                // align x
                switch (node.style.align_x) {
                    .center => child.value.computed.x = node.computed.x + node.computed.width * 0.5 - child.value.computed.width * 0.5,
                    .end => child.value.computed.x = node.computed.x + node.computed.width - child.value.computed.width - node.style.padding.right,
                    .start => {},
                }

                y -= child.value.computed.height;
                if (gap_count > 0) {
                    y -= node.style.gap;
                    gap_count -|= 1;
                }
            },

            .grid => |columns| {
                col_count += 1;
                x += child.value.computed.width + node.style.gap;
                col_w += child.value.computed.width + node.style.gap;
                col_h = @max(col_h, child.value.computed.height);

                if (col_count >= columns) {
                    y -= col_h + node.style.gap;
                    x -= col_w;

                    col_w = 0;
                    col_h = 0;
                    col_count = 0;
                }
            },
        }
    }
}

pub fn render(self: *@This(), gpa: std.mem.Allocator, ctx: ?*anyopaque) !void {
    for (self.tree.nodes.items(.value)) |*node| {
        if (node.render) |func| {
            try func(gpa, node, ctx);
        }
    }
}

pub fn getState(self: *@This(), gpa: std.mem.Allocator, hash: u32) !*State {
    const res = try self.hash_to_index.getOrPut(gpa, hash);
    if (!res.found_existing) {
        try self.states.append(gpa, .{ .hash = hash, .used = true });
        res.value_ptr.* = self.states.items.len - 1;
    }
    self.states.items[res.value_ptr.*].used = true;
    return &self.states.items[res.value_ptr.*];
}

// TODO:
// move Context and basic builder funcs here
