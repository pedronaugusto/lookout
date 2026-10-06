const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const lookout = b.dependency("lookout", .{ .target = target });
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .imports = &.{.{ .name = "lookout", .module = lookout.module("lookout") }},
    }) });
    b.installArtifact(exe);
}
