const std = @import("std");
/// airlock's build, for its test seam.
const airlock_build = @import("airlock");

/// What a project that depends on lookout builds: the `lookout` module, on
/// aegis, airlock, reactor and sweep, and the options for linking CoreServices
/// against a named Apple SDK.
pub fn build(b: *std.Build) void {
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
}

/// lookout's development: its tests, examples, checks and benchmarks, under
/// preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const darwin = target.result.os.tag.isDarwin();
    // The options of `build`, passed on to lookout.
    macos_sdk_option = b.option([]const u8, "macos-sdk", "The Apple SDK to link a named Apple target against");
    bundled_sdk_option = b.option(bool, "bundled-macos-sdk", "Use the pinned framework SDK for cross-linking Apple targets");
    use_aegis = tools.shakedown.useAegis;
    const preflight = tools.preflight;
    const package = lookoutPackage(b, target, optimize);
    const p = package.builder;
    const module = package.module("lookout");
    const airlock_dependency = p.dependency("airlock", .{ .target = target, .optimize = optimize });
    const reactor_dependency = p.dependency("reactor", .{ .target = target, .optimize = optimize });
    const imports = lookoutImports(p, target, optimize);

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
    // `bay test -Dthread-sanitizer`.
    const thread_sanitizer = b.option(
        bool,
        "thread-sanitizer",
        "Build the tests with ThreadSanitizer",
    ) orelse false;

    const tests = b.addTest(.{
        .name = "lookout-tests",
        .filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = darwin,
            .sanitize_thread = if (thread_sanitizer) true else null,
            .imports = imports,
        }),
    });
    // airlock's seam, which is lazy: its error ends this configure pass until
    // it is fetched. One shakedown in the graph: the one the seam is built on,
    // bound to airlock's aegis, which is lookout's.
    const seam = airlock_build.testing(airlock_dependency) catch return;
    tests.root_module.addImport("airlock.testing", seam);
    tests.root_module.addImport("shakedown", seam.import_table.get("shakedown").?);
    if (darwin) linkLike(module, tests.root_module);

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
    // README.md's Usage block comes from -- see bay docs -- usage -- so
    // the snippet a reader copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = p.path(source),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "lookout", .module = module }},
            }),
        });
        const run = b.addRunArtifact(example);
        run.step.dependOn(b.getInstallStep());
        run.setCwd(p.path("zig-out"));
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
    //=====================================================================

    // What `LOOKOUT_TRACE` prints is at the info level. `bay bench` holds
    // lookout's speed claims to their ceilings, on every backend the target
    // has, in ReleaseFast on a quiet machine; `bay test` runs each once with
    // `--smoke`, judging nothing.
    preflight.addCi(b, p, .{
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
    preflight.addConsumerCheck(b, p, .{
        .package = "lookout",
        .program = p.path("ci/consumer.zig"),
        .packages = &.{
            p.dependency("aegis", .{}),
            p.dependency("airlock", .{}),
            reactor_dependency,
            // The aegis reactor was built with is its own to pin.
            reactor_dependency.builder.dependency("aegis", .{}),
            p.dependency("sweep", .{}),
        },
    });
}

/// `-Dmacos-sdk` and `-Dbundled-macos-sdk`, as `dev` read them, for the
/// benchmarks' imports.
var macos_sdk_option: ?[]const u8 = null;
var bundled_sdk_option: ?bool = null;

/// `tools.shakedown.useAegis`, set by `dev` for the benchmark imports, which are built without `tools`.
var use_aegis: *const fn (*std.Build.Dependency, *std.Build.Module) void = undefined;

/// lookout as the development build has it: the package, with the options passed on.
fn lookoutPackage(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Dependency {
    return b.dependency("lookout", .{ .target = target, .optimize = optimize, .@"macos-sdk" = macos_sdk_option, .@"bundled-macos-sdk" = bundled_sdk_option });
}

/// What lookout imports, from the package's own build `p`.
fn lookoutImports(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    return p.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
        .{ .name = "airlock", .module = p.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock") },
        .{ .name = "reactor", .module = p.dependency("reactor", .{ .target = target, .optimize = optimize }).module("reactor") },
        .{ .name = "sweep", .module = p.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep") },
    }) catch @panic("OOM");
}

/// CoreServices, linked against the Apple SDK the published module `published`
/// links against, as `build` chose it.
fn linkLike(published: *std.Build.Module, m: *std.Build.Module) void {
    for (published.include_dirs.items) |dir| switch (dir) {
        .framework_path_system => |path| m.addSystemFrameworkPath(path),
        .path_system => |path| m.addSystemIncludePath(path),
        else => {},
    };
    for (published.lib_paths.items) |path| m.addLibraryPath(path);
    m.linkFramework("CoreServices", .{});
}

/// lookout, and its filter on its own, in the mode a benchmark builds in:
/// an imported module keeps its own mode, so a ReleaseFast benchmark over
/// the Debug module would time the Debug module. The filter is internal to
/// lookout, so the filter benchmark builds it as a module of its own rather
/// than reaching it through `lookout`. And shakedown, bound to lookout's aegis.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const package = lookoutPackage(b, target, optimize);
    const p = package.builder;
    const filter = b.createModule(.{
        .root_source_file = p.path("src/CompiledFilter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = lookoutImports(p, target, optimize),
    });
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    use_aegis(shakedown, p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "lookout", .module = package.module("lookout") },
        .{ .name = "filter", .module = filter },
        .{ .name = "shakedown", .module = shakedown.module("shakedown") },
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
