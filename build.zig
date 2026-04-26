const std = @import("std");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *Build) void {
    const zmath_options = b.addOptions();
    zmath_options.addOption(bool, "enable_cross_platform_determinism", true);

    const lom = b.addModule("lomstd", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = .ReleaseFast,
    });
    lom.addOptions("zmath_options", zmath_options);

    // const test_step = b.step("test", "");
    // const uts = b.addTest(.{ .name = "knoedel_test", .root_source_file = b.path("src/ecs_test.zig") });
    // const run_uts = b.addRunArtifact(uts);
    // test_step.dependOn(&run_uts.step);
}
