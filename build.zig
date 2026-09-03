const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("liquid", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_tests = b.addExecutable(.{
        .name = "liquid_specs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("specs/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "liquid", .module = lib_mod }},
        }),
    });

    const install_exe_tests = b.addInstallArtifact(exe_tests, .{});

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.addFileArg(b.path(b.pathJoin(&.{ "specs", b.args.?[0] })));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&install_exe_tests.step);
}
