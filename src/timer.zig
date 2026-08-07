const std = @import("std");

pub const Timer = struct {
    const Self = @This();

    pub const Direction = enum { forward, backward };
    pub const Mode = enum { normal, pingpong };
    pub const Repeat = union(enum) { inf, count: u32 };

    elapsed: f32 = 0,
    duration: f32 = 1,
    loop: Repeat = .{ .count = 1 },
    mode: Mode = .normal,
    dir: Direction = .forward,

    pub fn fract(self: *const Self) f32 {
        std.debug.assert(self.duration > 0);
        return @min(1, @max(0, self.elapsed / self.duration));
    }

    pub fn tick(self: *Self, dt: f32) bool {
        std.debug.assert(self.duration > 0);
        std.debug.assert(dt >= 0);

        var remaining = dt;
        var transitioned = false;
        while (remaining > 0) {
            const to_boundary = switch (self.dir) {
                .forward => @max(0, self.duration - self.elapsed),
                .backward => @max(0, self.elapsed),
            };

            if (remaining < to_boundary) {
                switch (self.dir) {
                    .forward => self.elapsed += remaining,
                    .backward => self.elapsed -= remaining,
                }
                break;
            }

            remaining -= to_boundary;
            self.elapsed = if (self.dir == .forward) self.duration else 0;
            transitioned = true;

            switch (self.loop) {
                .count => |*c| c.* = c.* -| 1,
                .inf => {},
            }

            if (self.finished()) return true;

            switch (self.mode) {
                .normal => {
                    self.elapsed = if (self.dir == .forward) 0 else self.duration;
                },
                .pingpong => {
                    switch (self.dir) {
                        .forward => {
                            self.dir = .backward;
                            self.elapsed = self.duration;
                        },
                        .backward => {
                            self.dir = .forward;
                            self.elapsed = 0;
                        },
                    }
                },
            }

            if (remaining == 0) break;
        }

        return transitioned;
    }

    pub fn finished(self: *const Self) bool {
        switch (self.loop) {
            .count => |c| return c == 0,
            .inf => return false,
        }
    }

    pub fn reset(self: *Self) void {
        switch (self.mode) {
            .normal => {
                self.elapsed = if (self.dir == .forward) 0 else self.duration;
            },
            .pingpong => {
                self.dir = .forward;
                self.elapsed = 0;
            },
        }
    }
};

test "repeating timer preserves overshoot" {
    var timer = Timer{ .duration = 0.25, .loop = .inf };

    try std.testing.expect(timer.tick(0.3125));
    try std.testing.expectApproxEqAbs(0.0625, timer.elapsed, 0.00001);
    try std.testing.expect(timer.tick(0.1875));
    try std.testing.expectApproxEqAbs(0, timer.elapsed, 0.00001);
}

test "pingpong timer applies multiple transitions" {
    var timer = Timer{
        .duration = 1,
        .loop = .{ .count = 3 },
        .mode = .pingpong,
    };

    try std.testing.expect(timer.tick(2.5));
    try std.testing.expectEqual(Timer.Direction.forward, timer.dir);
    try std.testing.expectApproxEqAbs(0.5, timer.elapsed, 0.00001);
}
