const std = @import("std");
pub const Direction = enum { forward, backward };
pub const Mode = enum { normal, pingpong };
pub const Repeat = union(enum) { inf, count: u32 };

pub const Timer = struct {
    const Self = @This();

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
        const transition: bool = blk: switch (self.dir) {
            .forward => {
                self.elapsed += dt;
                break :blk self.elapsed > self.duration;
            },
            .backward => {
                self.elapsed -= dt;
                break :blk self.elapsed < 0;
            },
        };

        if (transition) {
            switch (self.loop) {
                .count => |*c| c.* = c.* -| 1,
                .inf => {},
            }

            if (self.finished()) return transition;

            switch (self.mode) {
                .normal => {
                    self.elapsed = 0;
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
        }

        return transition;
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
