const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module.
    //
    // Pure Zig, no dependencies, nothing to link: which backend is
    // compiled in is decided by `builtin.os.tag` inside src/zwatch.zig, so
    // a consumer adds the import and nothing else.
    //=====================================================================

    // FSEvents lives in CoreServices, and the externs that reach it are
    // the only thing in the package that needs a system library. Every
    // other target stays free-standing Zig.
    const darwin = target.result.os.tag.isDarwin();

    const module = b.addModule("zwatch", .{
        .root_source_file = b.path("src/zwatch.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = darwin,
    });
    if (darwin) module.linkFramework("CoreServices", .{});

    //=====================================================================
    // Tests.
    //
    // The suite in src/test_suite.zig runs once per backend this target
    // can execute, so the poll backend is held to the same contract as the
    // kernel one rather than to a weaker one of its own.
    //=====================================================================

    const tests = b.addTest(.{
        .name = "zwatch-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zwatch.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = darwin,
        }),
    });
    if (darwin) tests.root_module.linkFramework("CoreServices", .{});

    const test_step = b.step("test", "Run the zwatch tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that
    // is only compiled proves the names still resolve; running it is what
    // proves the library still works. examples/usage.zig is also where
    // README.md's Usage block comes from -- see ci/readme_usage.sh -- so
    // the snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.fs.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zwatch", .module = module }},
            }),
        });
        const run = b.addRunArtifact(example);
        run.step.dependOn(b.getInstallStep());
        run.setCwd(b.path("zig-out"));
        examples_step.dependOn(&run.step);
    }
    test_step.dependOn(examples_step);

    //=====================================================================
    // The default step: compile everything for the selected target,
    // without running any of it.
    //
    // A library archive is not enough to prove a target builds. Zig
    // analyses a function when something reaches it, and nothing in an
    // archive of this module reaches the backend code, so a Linux-only
    // typo would survive `zig build -Dtarget=x86_64-linux-gnu`. The test
    // binary reaches all of it, so the default step compiles that too and
    // the cross-compile matrix means what it says.
    //=====================================================================

    b.installArtifact(b.addLibrary(.{
        .name = "zwatch",
        .root_module = module,
    }));
    b.getInstallStep().dependOn(&tests.step);
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
};
