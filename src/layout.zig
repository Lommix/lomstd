const std = @import("std");

pub const Area = struct {
    const Self = @This();
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

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

pub const Constraint = union(enum) {
    pixel: f32,
    percent: f32,
    fill,
};

/// # Creates horizontal layout from left to right
/// Y┌─────┬─────┬─────┐
/// ││  0  │  1  │  2  │
/// │└─────┴─────┴─────┘
/// 0──────────────────X
pub fn bufRow(area: Area, buf: []Area, constraints: []const Constraint) []Area {
    std.debug.assert(constraints.len == buf.len);
    var total_fixed_width: f32 = 0;
    var fill_count: u32 = 0;

    for (constraints) |constraint| {
        switch (constraint) {
            .pixel => |width| total_fixed_width += width,
            .percent => |pct| total_fixed_width += area.width * pct,
            .fill => fill_count += 1,
        }
    }

    const remaining_width = area.width - total_fixed_width;
    const fill_width = if (fill_count > 0) remaining_width / @as(f32, @floatFromInt(fill_count)) else 0;

    var current_x = area.x;

    for (constraints, 0..) |constraint, i| {
        const width = switch (constraint) {
            .pixel => |w| w,
            .percent => |pct| area.width * pct,
            .fill => fill_width,
        };

        buf[i] = Area{
            .x = current_x,
            .y = area.y,
            .width = width,
            .height = area.height,
        };

        current_x += width;
    }

    return buf[0..constraints.len];
}

/// # Creates horizontal layout from left to right
/// Y┌─────┬┬─────┬┬────┐
/// ││  0  ││  1  ││ 2  │
/// │└─────┴┴─────┴┴────┘
/// 0──────────────────X
pub fn bufRowGap(area: Area, buf: []Area, constraints: []const Constraint, gap: Constraint) []Area {
    const gap_count = if (constraints.len > 1) constraints.len - 1 else 0;
    const gap_size = switch (gap) {
        .pixel => |g| g,
        .percent => |pct| area.height * pct,
        .fill => 0,
    };
    const total_gap_height = gap_size * @as(f32, @floatFromInt(gap_count));

    var total_fixed_width: f32 = total_gap_height;
    var fill_count: u32 = 0;

    for (constraints) |constraint| {
        switch (constraint) {
            .pixel => |width| total_fixed_width += width,
            .percent => |pct| total_fixed_width += area.width * pct,
            .fill => fill_count += 1,
        }
    }

    const remaining_width = area.width - total_fixed_width;
    const fill_width = if (fill_count > 0) remaining_width / @as(f32, @floatFromInt(fill_count)) else 0;

    var current_x = area.x;

    for (constraints, 0..) |constraint, i| {
        const width = switch (constraint) {
            .pixel => |w| w,
            .percent => |pct| area.width * pct,
            .fill => fill_width,
        };

        buf[i] = Area{
            .x = current_x,
            .y = area.y,
            .width = width,
            .height = area.height,
        };

        // Add gap after each element except the last one
        if (i < constraints.len - 1) {
            current_x += gap_size;
        }

        current_x += width;
    }

    return buf[0..constraints.len];
}

/// # Creates vertical layout from top to bottom
/// Y┌───┐
/// ││ 0 │
/// │├───┤
/// ││ 1 │
/// │├───┤
/// ││ 2 │
/// │└───┘
/// 0────X
pub fn bufCol(area: Area, buf: []Area, constraints: []const Constraint) []Area {
    var total_fixed_height: f32 = 0;
    var fill_count: u32 = 0;

    for (constraints) |constraint| {
        switch (constraint) {
            .pixel => |height| total_fixed_height += height,
            .percent => |pct| total_fixed_height += area.height * pct,
            .fill => fill_count += 1,
        }
    }

    const remaining_height = area.height - total_fixed_height;
    const fill_height = if (fill_count > 0) remaining_height / @as(f32, @floatFromInt(fill_count)) else 0;

    var current_y = area.y + area.height;

    for (constraints, 0..) |constraint, i| {
        const height = switch (constraint) {
            .pixel => |h| h,
            .percent => |pct| area.height * pct,
            .fill => fill_height,
        };

        current_y -= height;
        buf[i] = Area{
            .x = area.x,
            .y = current_y,
            .width = area.width,
            .height = height,
        };
    }

    return buf[0..constraints.len];
}

/// # Creates vertical layout from top to bottom with gaps
/// Y┌───┐
/// ││ 0 │
/// │├───┤
/// │├───┤
/// ││ 1 │
/// │├───┤
/// │├───┤
/// ││ 2 │
/// │└───┘
/// 0────X
pub fn bufColGap(area: Area, buf: []Area, constraints: []const Constraint, gap: Constraint) []Area {
    const gap_count = if (constraints.len > 1) constraints.len - 1 else 0;
    const gap_size = switch (gap) {
        .pixel => |g| g,
        .percent => |pct| area.height * pct,
        .fill => 0,
    };
    const total_gap_height = gap_size * @as(f32, @floatFromInt(gap_count));

    var total_fixed_height: f32 = total_gap_height;
    var fill_count: u32 = 0;

    for (constraints) |constraint| {
        switch (constraint) {
            .pixel => |height| total_fixed_height += height,
            .percent => |pct| total_fixed_height += area.height * pct,
            .fill => fill_count += 1,
        }
    }

    const remaining_height = area.height - total_fixed_height;
    const fill_height = if (fill_count > 0) remaining_height / @as(f32, @floatFromInt(fill_count)) else 0;

    var current_y = area.y + area.height;

    for (constraints, 0..) |constraint, i| {
        const height = switch (constraint) {
            .pixel => |h| h,
            .percent => |pct| area.height * pct,
            .fill => fill_height,
        };

        current_y -= height;
        buf[i] = Area{
            .x = area.x,
            .y = current_y,
            .width = area.width,
            .height = height,
        };

        // Add gap after each element except the last one
        if (i < constraints.len - 1) {
            current_y -= gap_size;
        }
    }

    return buf[0..constraints.len];
}

/// # Creates horizontal layout from left to right
/// @comptime sugar
/// Y┌─────┬─────┬─────┐
/// ││  0  │  1  │  2  │
/// │└─────┴─────┴─────┘
/// 0──────────────────X
pub fn Row(area: Area, comptime constraints: anytype) [constraints.len]Area {
    var out: [constraints.len]Area = undefined;
    _ = bufRow(area, &out, &constraints);
    return out;
}

/// # Creates horizontal layout from left to right
/// @comptime sugar
/// Y┌─────┬┬─────┬┬────┐
/// ││  0  ││  1  ││ 2  │
/// │└─────┴┴─────┴┴────┘
/// 0──────────────────X
pub fn RowGap(area: Area, comptime constraints: anytype, gap: Constraint) [constraints.len]Area {
    var areas: [constraints.len]Area = undefined;
    _ = bufRowGap(area, &areas, &constraints, gap);
    return areas;
}

/// # Creates vertical layout from top to bottom with gaps
/// @comptime sugar
/// Y┌───┐
/// ││ 0 │
/// │├───┤
/// │├───┤
/// ││ 1 │
/// │├───┤
/// │├───┤
/// ││ 2 │
/// │└───┘
/// 0────X
pub fn ColGap(area: Area, comptime constraints: anytype, gap: Constraint) [constraints.len]Area {
    var areas: [constraints.len]Area = undefined;
    _ = bufColGap(area, &areas, &constraints, gap);
    return areas;
}

/// # Creates vertical layout from top to bottom
/// @comptime sugar
/// Y┌───┐
/// ││ 0 │
/// │├───┤
/// ││ 1 │
/// │├───┤
/// ││ 2 │
/// │└───┘
/// 0────X
pub fn Col(area: Area, comptime constraints: anytype) [constraints.len]Area {
    var areas: [constraints.len]Area = undefined;
    _ = bufCol(area, &areas, &constraints);
    return areas;
}

/// # Creates area with custom padding on each side
/// Y┌─────────┐
/// ││    T    │
/// ││  ┌───┐  │
/// ││L │ A │ R│
/// ││  └───┘  │
/// ││    B    │
/// │└─────────┘
/// 0─────────X
pub fn Pad(area: Area, comptime left: Constraint, comptime right: Constraint, comptime top: Constraint, comptime bottom: Constraint) Area {
    const row = Row(area, .{ left, Constraint.fill, right });
    const col = Col(row[1], .{ top, Constraint.fill, bottom });
    return col[1];
}

/// # Creates area with custom padding on each side
/// Y┌─────────┐
/// ││    Y    │
/// ││  ┌───┐  │
/// ││X │ A │ X│
/// ││  └───┘  │
/// ││    Y    │
/// │└─────────┘
/// 0─────────X
pub fn PadAxis(area: Area, comptime x: Constraint, comptime y: Constraint) Area {
    const row = Row(area, .{ x, Constraint.fill, x });
    const col = Col(row[1], .{ y, Constraint.fill, y });
    return col[1];
}

/// # Creates area with custom padding on each side
/// Y┌───────┐
/// ││ ┌─W─┐ │
/// ││ H A │ │
/// ││ └───┘ │
/// │└───────┘
/// 0─────────X
pub fn Centered(area: Area, comptime width: Constraint, comptime heigth: Constraint) Area {
    const row = Row(area, .{ Constraint.fill, width, Constraint.fill });
    const col = Col(row[1], .{ Constraint.fill, heigth, Constraint.fill });
    return col[1];
}

/// # Creates area with uniform padding on all sides
/// Y┌─────────┐
/// ││    P    │
/// ││  ┌───┐  │
/// ││P │ A │ P│
/// ││  └───┘  │
/// ││    P    │
/// │└─────────┘
/// 0─────────X
pub fn PadAll(area: Area, comptime pad: Constraint) Area {
    const row = Row(area, .{ pad, Constraint.fill, pad });
    const col = Col(row[1], .{ pad, Constraint.fill, pad });
    return col[1];
}
