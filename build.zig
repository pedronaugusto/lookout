const std = @import("std");
/// airlock's build, for its test seam.
const airlock_build = @import("airlock");

/// What a project that depends on lookout builds: the `lookout` module, on
/// aegis, airlock, reactor and sweep.
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

    // FSEvents lives in CoreServices, which the backend opens when the
    // first watcher is made rather than linking it, so an Apple target
    // links only libSystem, from what Zig ships: it builds on any host,
    // with no SDK.
    const darwin = target.result.os.tag.isDarwin();

    const airlock_dependency = b.dependency("airlock", .{ .target = target, .optimize = optimize });
    const airlock = airlock_dependency.module("airlock");
    const sweep = b.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep");
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const reactor_dependency = b.dependency("reactor", .{ .target = target, .optimize = optimize });
    const reactor = reactor_dependency.module("reactor");
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand");
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "aegis", .module = aegis },
        .{ .name = "airlock", .module = airlock },
        .{ .name = "reactor", .module = reactor },
        .{ .name = "strand", .module = strand },
        .{ .name = "sweep", .module = sweep },
    };

    _ = b.addModule("lookout", .{
        .root_source_file = b.path("src/lookout.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = darwin,
        .imports = imports,
    });
}

/// lookout's development: its tests, examples, checks and benchmarks, under
/// preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const darwin = target.result.os.tag.isDarwin();
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

    const tests = b.addTest(.{
        .name = "lookout-tests",
        .filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = darwin,
            .imports = imports,
        }),
    });
    // shakedown, and airlock's seam built on it.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    tests.root_module.addImport("airlock.testing", airlock_build.testing(airlock_dependency, shakedown.module("shakedown")));
    tests.root_module.addImport("shakedown", shakedown.module("shakedown"));

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
        // The release tier fuzzes the readers' properties and runs the suite
        // under ThreadSanitizer. A watcher is handed its changes on a thread
        // the platform owns and reads them on the caller's, and the suite
        // writes to the tree from a thread of its own while it waits: whether
        // that crossing is free of races is a claim a race detector checks and
        // a reader cannot (`bay hardened-tsan` on Linux).
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
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
    // The build a consumer gets: aegis, airlock, reactor, strand and sweep, and
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
            p.dependency("strand", .{}),
            p.dependency("sweep", .{}),
        },
    });
}

/// lookout as the development build has it: the package, for `target` and `optimize`.
fn lookoutPackage(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Dependency {
    return b.dependency("lookout", .{ .target = target, .optimize = optimize });
}

/// What lookout imports, from the package's own build `p`.
fn lookoutImports(p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    return p.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
        .{ .name = "airlock", .module = p.dependency("airlock", .{ .target = target, .optimize = optimize }).module("airlock") },
        .{ .name = "reactor", .module = p.dependency("reactor", .{ .target = target, .optimize = optimize }).module("reactor") },
        .{ .name = "strand", .module = p.dependency("strand", .{ .target = target, .optimize = optimize }).module("strand") },
        .{ .name = "sweep", .module = p.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep") },
    }) catch @panic("OOM");
}

/// lookout, and its filter on its own, in the mode a benchmark builds in:
/// an imported module keeps its own mode, so a ReleaseFast benchmark over
/// the Debug module would time the Debug module. The filter is internal to
/// lookout, so the filter benchmark builds it as a module of its own rather
/// than reaching it through `lookout`. And shakedown.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const package = lookoutPackage(b, target, optimize);
    const p = package.builder;
    const filter = b.createModule(.{
        .root_source_file = p.path("src/CompiledFilter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = lookoutImports(p, target, optimize),
    });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "lookout", .module = package.module("lookout") },
        .{ .name = "filter", .module = filter },
    }) catch @panic("OOM");
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
    "examples/since.zig",
};
