const std = @import("std");
/// airlock's build, for its test seam.
const airlock_build = @import("airlock");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module.
    //
    // Pure Zig over four packages of its own, aegis for the typed state
    // and counts, airlock for the durable baseline file, reactor for the
    // waits and sweep for the filter patterns, all std-only:
    // which backend is compiled in is decided by `builtin.target.os.tag`
    // inside src/lookout.zig, so a consumer adds the import and nothing
    // else.
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

    const airlock_dependency = b.dependency("airlock", .{ .target = target, .optimize = optimize });
    const airlock = airlock_dependency.module("airlock");
    const sweep = b.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep");
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const reactor_dependency = b.dependency("reactor", .{ .target = target, .optimize = optimize });
    const reactor = reactor_dependency.module("reactor");
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "aegis", .module = aegis },
        .{ .name = "airlock", .module = airlock },
        .{ .name = "reactor", .module = reactor },
        .{ .name = "sweep", .module = sweep },
    };

    const module = b.addModule("lookout", .{
        .root_source_file = b.path("src/lookout.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = darwin,
        .imports = imports,
    });
    if (darwin) {
        if (sdk) |paths| paths.addTo(module);
        module.linkFramework("CoreServices", .{});
    }

    // Everything below is lookout's own: a project depending on lookout
    // builds the module and nothing else, and fetches nothing for it.
    if (b.pkg_hash.len != 0) return;

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
            .imports = imports,
        }),
    });
    // shakedown, and airlock's seam on it, are lazy and test-only: no
    // production source imports them. Their error is returned last, so one
    // configure pass asks for them and for preflight together.
    var needed: error{LazyDependencyNeeded}!void = {};
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    } else |err| needed = err;
    if (airlock_build.testing(airlock_dependency)) |seam| {
        tests.root_module.addImport("airlock.testing", seam);
    } else |err| needed = err;
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

    if (b.lazyImport(@This(), "preflight")) |preflight| {
        // What `LOOKOUT_TRACE` prints is at the info level. `zig build
        // bench` holds lookout's speed claims to their ceilings, on every
        // backend the target has, in ReleaseFast on a quiet machine; `zig
        // build test` runs each once with `--smoke`, judging nothing.
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            .test_log_level = .info,
            .bench = .{
                .programs = &.{
                    .{ .name = "lookout-bench", .source = "bench/speed_claims.zig" },
                    .{ .name = "lookout-filter-bench", .source = "bench/filter.zig" },
                },
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
                .link_libc = darwin,
            },
        });
        // The build a consumer gets: aegis, airlock, reactor and sweep, and
        // nothing lookout fetches for itself.
        preflight.addConsumerCheck(b, .{
            .package = "lookout",
            .program = b.path("ci/consumer.zig"),
            .packages = &.{
                b.dependency("aegis", .{}),
                b.dependency("airlock", .{}),
                reactor_dependency,
                // The aegis reactor was built with is its own to pin.
                reactor_dependency.builder.dependency("aegis", .{}),
                b.dependency("sweep", .{}),
            },
        });
    }
    return needed;
}

/// lookout, and its filter on its own, in the mode a benchmark builds in:
/// an imported module keeps its own mode, so a ReleaseFast benchmark over
/// the Debug module would time the Debug module. The filter is internal to
/// lookout, so the filter benchmark builds it as a module of its own rather
/// than reaching it through `lookout`.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "aegis", .module = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
        .{ .name = "airlock", .module = b.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock") },
        .{ .name = "reactor", .module = b.dependency("reactor", .{ .target = target, .optimize = optimize }).module("reactor") },
        .{ .name = "sweep", .module = b.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep") },
    };
    const darwin = target.result.os.tag.isDarwin();
    const lookout = b.createModule(.{
        .root_source_file = b.path("src/lookout.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = darwin,
        .imports = imports,
    });
    if (darwin) {
        // The Apple SDK the published module links against, as `build`
        // chose it.
        const published = b.modules.get("lookout").?;
        for (published.include_dirs.items) |dir| switch (dir) {
            .framework_path_system => |path| lookout.addSystemFrameworkPath(path),
            .path_system => |path| lookout.addSystemIncludePath(path),
            else => {},
        };
        for (published.lib_paths.items) |path| lookout.addLibraryPath(path);
        lookout.linkFramework("CoreServices", .{});
    }
    const filter = b.createModule(.{
        .root_source_file = b.path("src/CompiledFilter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        return b.allocator.dupe(std.Build.Module.Import, &.{
            .{ .name = "lookout", .module = lookout },
            .{ .name = "filter", .module = filter },
            .{ .name = "shakedown", .module = shakedown.module("shakedown") },
        }) catch @panic("OOM");
    } else |_| return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "lookout", .module = lookout },
        .{ .name = "filter", .module = filter },
    }) catch @panic("OOM");
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
