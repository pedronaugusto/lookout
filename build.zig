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
    const bundled_sdk = b.option(bool, "bundled-macos-sdk", "Use the pinned framework SDK for cross-linking Apple targets") orelse
        (b.graph.host.result.os.tag != .macos);

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
        if (bundled_sdk) break :frameworks null;
        const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse
            break :frameworks null;
        b.sysroot = sdk;
        break :frameworks .{
            .cwd_relative = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" }),
        };
    };

    const sdk_dep = if (darwin and bundled_sdk and b.sysroot == null) b.lazyDependency("macos_sdk", .{}) else null;

    const module = b.addModule("lookout", .{
        .root_source_file = b.path("src/lookout.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = darwin,
    });
    if (darwin) {
        if (frameworks) |path| module.addSystemFrameworkPath(path);
        if (sdk_dep) |sdk| addSdkPaths(module, sdk);
        module.linkFramework("CoreServices", .{});
    }

    //=====================================================================
    // Tests.
    //
    // The suite in src/testing/suite_test.zig runs once per backend this target
    // can execute, so the poll backend is held to the same contract as the
    // kernel one rather than to a weaker one of its own.
    //=====================================================================

    // A watcher is handed its changes on a thread the platform owns and
    // reads them on the caller's, and the suite writes to the tree from a
    // thread of its own while it waits. Whether that crossing is free of
    // races is a claim a race detector can check and a reader cannot:
    // `zig build test -Dthread-sanitizer`.
    const thread_sanitizer = b.option(
        bool,
        "thread-sanitizer",
        "Build the tests with ThreadSanitizer",
    ) orelse false;

    const tests = b.addTest(.{
        .name = "lookout-tests",
        .filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = darwin,
            .sanitize_thread = if (thread_sanitizer) true else null,
            // The fuzz targets in src/testing/fuzz_test.zig are the reason: the
            // fuzzing runner in Zig 0.16.0 will not build a module that
            // carries error return traces.
            .error_tracing = false,
        }),
    });
    if (darwin) {
        if (frameworks) |path| tests.root_module.addSystemFrameworkPath(path);
        if (sdk_dep) |sdk| addSdkPaths(tests.root_module, sdk);
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
    // README.md's Usage block comes from -- see zig build docs -- usage -- so
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

    //=====================================================================
    // CI wiring
    //
    // Only in lookout's own tree. preflight is a lazy dependency, and a
    // lazy package's build.zig can only be reached through `lazyImport`: a
    // plain `@import` of it fails to compile in any project that depends
    // on lookout and has not fetched preflight, which is every such
    // project.
    //=====================================================================

    if (b.pkg_hash.len != 0) return;
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true });
        // The build a consumer gets: nothing lookout fetches for itself.
        preflight.addConsumerCheck(b, .{ .package = "lookout", .program = b.path("ci/consumer.zig") });
    }
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/since.zig",
};

// Framework search paths come from the pinned package root.
fn addSdkPaths(module: *std.Build.Module, sdk: *std.Build.Dependency) void {
    module.addSystemFrameworkPath(sdk.path("Frameworks"));
    module.addSystemIncludePath(sdk.path("include"));
    module.addLibraryPath(sdk.path("lib"));
}
