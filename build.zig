const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module.
    //
    // Pure Zig, no dependencies, nothing to link: which backend is
    // compiled in is decided by `builtin.target.os.tag` inside src/lookout.zig, so
    // a consumer adds the import and nothing else.
    //=====================================================================

    // FSEvents lives in CoreServices, and the externs that reach it are
    // the only thing in the package that needs a system library. Every
    // other target stays free-standing Zig.
    const darwin = target.result.os.tag.isDarwin();

    // Zig finds the host's SDK by itself for a native build and not for a
    // named target, so `-Dtarget=aarch64-macos` fails to find CoreServices
    // even on a Mac. A named Apple target links against the SDK given here
    // (`-Dmacos-sdk=$(xcrun --show-sdk-path)`) or, without one, against the
    // pinned framework SDK. build.zig cannot ask xcrun itself: the build
    // configuration is cached, and a path read from a process at configure
    // time would outlive the SDK it names.
    const macos_sdk = b.option([]const u8, "macos-sdk", "The Apple SDK to link a named Apple target against");
    const bundled_sdk = b.option(bool, "bundled-macos-sdk", "Use the pinned framework SDK for cross-linking Apple targets") orelse
        (macos_sdk == null and !target.query.isNative());

    const sdk: ?Sdk = sdk: {
        if (!darwin) break :sdk null;
        if (macos_sdk) |root| break :sdk .{
            .frameworks = .{ .cwd_relative = b.pathJoin(&.{ root, "System", "Library", "Frameworks" }) },
            .include = .{ .cwd_relative = b.pathJoin(&.{ root, "usr", "include" }) },
            .lib = .{ .cwd_relative = b.pathJoin(&.{ root, "usr", "lib" }) },
        };
        if (!bundled_sdk) break :sdk null;
        const pinned = b.dependencyLazy("macos_sdk", .{}) catch break :sdk null;
        break :sdk .{ .frameworks = pinned.path("Frameworks"), .include = pinned.path("include"), .lib = pinned.path("lib") };
    };

    const module = b.addModule("lookout", .{
        .root_source_file = b.path("src/lookout.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = darwin,
    });
    if (darwin) {
        if (sdk) |paths| paths.addTo(module);
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
        }),
    });
    if (darwin) {
        if (sdk) |paths| paths.addTo(tests.root_module);
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
            .name = std.Io.Dir.path.stem(source),
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
        // What `LOOKOUT_TRACE` prints is at the info level.
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true, .test_log_level = .info });
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

/// Where an Apple SDK keeps what CoreServices links against.
const Sdk = struct {
    frameworks: std.Build.LazyPath,
    include: std.Build.LazyPath,
    lib: std.Build.LazyPath,

    fn addTo(sdk: Sdk, module: *std.Build.Module) void {
        module.addSystemFrameworkPath(sdk.frameworks);
        module.addSystemIncludePath(sdk.include);
        module.addLibraryPath(sdk.lib);
    }
};
