const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module.
    //
    // Pure Zig, no dependencies, nothing to link: which backend is
    // compiled in is decided by `builtin.os.tag` inside src/lookout.zig, so
    // a consumer adds the import and nothing else.
    //=====================================================================

    // FSEvents lives in CoreServices, and the externs that reach it are
    // the only thing in the package that needs a system library. Every
    // other target stays free-standing Zig.
    const darwin = target.result.os.tag.isDarwin();

    // Cross-compiling to an Apple target from an Apple host: Zig finds
    // the SDK by itself for a native build and not for a named one, so
    // `-Dtarget=aarch64-macos` would fail to find CoreServices on the
    // very machine that has it. Asking the host where its SDK is costs
    // nothing when there is no SDK to find.
    const frameworks: ?std.Build.LazyPath = frameworks: {
        if (!darwin) break :frameworks null;
        if (b.sysroot) |root| break :frameworks .{
            .cwd_relative = b.pathJoin(&.{ root, "System", "Library", "Frameworks" }),
        };
        const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse
            break :frameworks null;
        b.sysroot = sdk;
        break :frameworks .{
            .cwd_relative = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" }),
        };
    };

    const module = b.addModule("lookout", .{
        .root_source_file = b.path("src/lookout.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = darwin,
    });
    if (darwin) {
        if (frameworks) |path| module.addSystemFrameworkPath(path);
        module.linkFramework("CoreServices", .{});
    }

    //=====================================================================
    // Tests.
    //
    // The suite in src/test_suite.zig runs once per backend this target
    // can execute, so the poll backend is held to the same contract as the
    // kernel one rather than to a weaker one of its own.
    //=====================================================================

    const tests = b.addTest(.{
        .name = "lookout-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lookout.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = darwin,
            // The fuzz targets in src/test_fuzz.zig are the reason: the
            // fuzzing runner in Zig 0.16.0 will not build a module that
            // carries error return traces.
            .error_tracing = false,
        }),
    });
    if (darwin) {
        if (frameworks) |path| tests.root_module.addSystemFrameworkPath(path);
        tests.root_module.linkFramework("CoreServices", .{});
    }

    const test_step = b.step("test", "Run the lookout tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Compile the backend-bearing test artifact without running it. This
    // is the cross-target check: unlike the library archive on its own,
    // the tests reach every backend selected for the target.
    const check_step = b.step("check", "Compile the lookout tests without running them");
    check_step.dependOn(&tests.step);

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
                .imports = &.{.{ .name = "lookout", .module = module }},
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
        .name = "lookout",
        .root_module = module,
    }));
    b.getInstallStep().dependOn(&tests.step);
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/since.zig",
};
