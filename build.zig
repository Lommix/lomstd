const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *Build) void {
    _ = b.addModule("lomstd", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = .ReleaseFast,
    });

    // const test_step = b.step("test", "");
    // const uts = b.addTest(.{ .name = "knoedel_test", .root_source_file = b.path("src/ecs_test.zig") });
    // const run_uts = b.addRunArtifact(uts);
    // test_step.dependOn(&run_uts.step);
}
