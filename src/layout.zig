const std = @import("std");

pub const Area = struct {
    const Self = @This();
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,

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
pub fn Row(area: Area, comptime constraints: anytype) [constraints.len]Area {
    var areas: [constraints.len]Area = undefined;

    var total_fixed_width: f32 = 0;
    var fill_count: u32 = 0;

    inline for (constraints) |constraint| {
        switch (constraint) {
            .pixel => |width| total_fixed_width += width,
            .percent => |pct| total_fixed_width += area.width * pct,
            .fill => fill_count += 1,
        }
    }

    const remaining_width = area.width - total_fixed_width;
    const fill_width = if (fill_count > 0) remaining_width / @as(f32, @floatFromInt(fill_count)) else 0;

    var current_x = area.x;

    inline for (constraints, 0..) |constraint, i| {
        const width = switch (constraint) {
            .pixel => |w| w,
            .percent => |pct| area.width * pct,
            .fill => fill_width,
        };

        areas[i] = Area{
            .x = current_x,
            .y = area.y,
            .width = width,
            .height = area.height,
        };

        current_x += width;
    }

    return areas;
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
pub fn Column(area: Area, comptime constraints: anytype) [constraints.len]Area {
    var areas: [constraints.len]Area = undefined;

    var total_fixed_height: f32 = 0;
    var fill_count: u32 = 0;

    inline for (constraints) |constraint| {
        switch (constraint) {
            .pixel => |height| total_fixed_height += height,
            .percent => |pct| total_fixed_height += area.height * pct,
            .fill => fill_count += 1,
        }
    }

    const remaining_height = area.height - total_fixed_height;
    const fill_height = if (fill_count > 0) remaining_height / @as(f32, @floatFromInt(fill_count)) else 0;

    var current_y = area.y + area.height;

    inline for (constraints, 0..) |constraint, i| {
        const height = switch (constraint) {
            .pixel => |h| h,
            .percent => |pct| area.height * pct,
            .fill => fill_height,
        };

        current_y -= height;
        areas[i] = Area{
            .x = area.x,
            .y = current_y,
            .width = area.width,
            .height = height,
        };
    }

    return areas;
}

/// # Creates vertical layout from top to bottom with gaps
/// Y┌───┐
/// ││ 0 │
/// │├─G─┤
/// ││ 1 │
/// │├─G─┤
/// ││ 2 │
/// │└───┘
/// 0────X
pub fn ColumnGap(area: Area, comptime constraints: anytype, gap: Constraint) [constraints.len]Area {
    var areas: [constraints.len]Area = undefined;

    const gap_count = if (constraints.len > 1) constraints.len - 1 else 0;
    const gap_size = switch (gap) {
        .pixel => |g| g,
        .percent => |pct| area.height * pct,
        .fill => 0,
    };
    const total_gap_height = gap_size * @as(f32, @floatFromInt(gap_count));

    var total_fixed_height: f32 = total_gap_height;
    var fill_count: u32 = 0;

    inline for (constraints) |constraint| {
        switch (constraint) {
            .pixel => |height| total_fixed_height += height,
            .percent => |pct| total_fixed_height += area.height * pct,
            .fill => fill_count += 1,
        }
    }

    const remaining_height = area.height - total_fixed_height;
    const fill_height = if (fill_count > 0) remaining_height / @as(f32, @floatFromInt(fill_count)) else 0;

    var current_y = area.y + area.height;

    inline for (constraints, 0..) |constraint, i| {
        const height = switch (constraint) {
            .pixel => |h| h,
            .percent => |pct| area.height * pct,
            .fill => fill_height,
        };

        current_y -= height;
        areas[i] = Area{
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
pub fn Padding(area: Area, comptime left: Constraint, comptime right: Constraint, comptime top: Constraint, comptime bottom: Constraint) Area {
    const row = Row(area, .{ left, Constraint.fill, right });
    const col = Column(row[1], .{ top, Constraint.fill, bottom });
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
    const col = Column(row[1], .{ Constraint.fill, heigth, Constraint.fill });
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
pub fn PaddingAll(area: Area, comptime pad: Constraint) Area {
    const row = Row(area, .{ pad, Constraint.fill, pad });
    const col = Column(row[1], .{ pad, Constraint.fill, pad });
    return col[1];
}
