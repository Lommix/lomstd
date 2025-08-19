const std = @import("std");

pub const Area = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
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
