const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Run one tiny iteration") orelse false);
    const optimize = b.standardOptimizeOption(.{});
    const lookout_dep = b.dependency(if (b.option(bool, "snapshot", "Build the archived local revision") orelse false) "lookout" else "after", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "lookout-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lookout_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lookout", .module = lookout_dep.module("lookout") }},
        }),
    });
    exe.root_module.addOptions("bench_options", options);
    b.installArtifact(exe);
    // Install without running: quiet.py chooses smoke or the timed pass.
    const speed = b.addTest(.{
        .name = "speed-claims",
        .filters = &.{"quiet:"},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/speed_claims.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag == .macos,
            .imports = &.{.{ .name = "lookout", .module = lookout_dep.module("lookout") }},
        }),
    });
    speed.root_module.addOptions("bench_options", options);
    b.installArtifact(speed);
}
