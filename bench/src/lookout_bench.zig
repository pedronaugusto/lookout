const std = @import("std");
const lookout = @import("lookout");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Watcher = lookout.Watcher;
const smoke = @import("bench_options").smoke;

const Config = struct {
    latency_gap_ms: u32,
    burst_counts: []usize,
    idle_seconds: u32,
    baseline_sizes: []const BaselineSize = &.{},
    baseline_change_every: usize = 100,
    checkpoint_files: usize = 0,
    poll_window_ms: u32 = 0,
};

const BaselineSize = struct {
    name: []const u8,
    files: usize,
    dirs: usize,
};

const Manifest = struct {
    data: []u8,
    lines: [][]const u8,

    fn deinit(m: *Manifest, gpa: Allocator) void {
        gpa.free(m.lines);
        gpa.free(m.data);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 4) return error.InvalidArguments;

    var out_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &out_writer.interface;
    const workload = args[1];
    const inputs = args[2];
    const root = args[3];

    if (std.mem.eql(u8, workload, "latency")) {
        try latency(gpa, io, out, inputs, root);
    } else if (std.mem.eql(u8, workload, "burst")) {
        try burst(gpa, io, out, inputs, root);
    } else if (std.mem.eql(u8, workload, "rename")) {
        try renameWork(gpa, io, out, inputs, root);
    } else if (std.mem.eql(u8, workload, "idle")) {
        try idle(gpa, io, out, inputs, root);
    } else if (std.mem.eql(u8, workload, "tree_setup")) {
        try treeSetup(gpa, io, out, root);
    } else if (std.mem.eql(u8, workload, "backend_setup")) {
        try backendSetup(gpa, io, out, inputs, root);
    } else if (std.mem.eql(u8, workload, "poll_cpu")) {
        try pollCpu(gpa, io, out, inputs, root);
    } else if (std.mem.eql(u8, workload, "baseline")) {
        try baselineWork(gpa, io, out, inputs, root);
    } else if (std.mem.eql(u8, workload, "checkpoint")) {
        try checkpointWork(gpa, io, out, inputs, root);
    } else if (std.mem.eql(u8, workload, "filter")) {
        try filterWork(gpa, io, out, inputs, root);
    } else if (std.mem.eql(u8, workload, "path")) {
        try pathWork(gpa, io, out, inputs, root);
    } else return error.UnknownWorkload;
    try out.flush();
}

fn readConfig(gpa: Allocator, io: Io, inputs: []const u8) !std.json.Parsed(Config) {
    const path = try std.fs.path.join(gpa, &.{ inputs, "config.json" });
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(bytes);
    // Always copied: `bytes` is freed on return, and the names are strings.
    return std.json.parseFromSlice(Config, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn readManifest(gpa: Allocator, io: Io, path: []const u8) !Manifest {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024));
    errdefer gpa.free(data);
    var count: usize = 0;
    var first = std.mem.splitScalar(u8, data, '\n');
    while (first.next()) |line| if (line.len != 0) {
        count += 1;
    };
    const lines = try gpa.alloc([]const u8, count);
    errdefer gpa.free(lines);
    var second = std.mem.splitScalar(u8, data, '\n');
    var index: usize = 0;
    while (second.next()) |line| {
        if (line.len == 0) continue;
        lines[index] = line;
        index += 1;
    }
    return .{ .data = data, .lines = lines };
}

fn manifestAt(gpa: Allocator, io: Io, inputs: []const u8, name: []const u8) !Manifest {
    const path = try std.fs.path.join(gpa, &.{ inputs, name });
    defer gpa.free(path);
    return readManifest(gpa, io, path);
}

fn metric(out: *std.Io.Writer, workload: []const u8, name: []const u8, value: anytype, unit: []const u8) !void {
    try out.print("lookout\t{s}\t{s}\t{}\t{s}\n", .{ workload, name, value, unit });
}

fn now(io: Io) Io.Timestamp {
    return .now(io, .awake);
}

fn openRoot(io: Io, root: []const u8) !Io.Dir {
    return Io.Dir.openDirAbsolute(io, root, .{});
}

fn makeWatcher(gpa: Allocator, io: Io) !Watcher {
    return .init(gpa, io, .{
        .backend = .fsevents,
        .latency_ms = 0,
        // Do not turn the flat burst into a deliberate policy overflow.
        .max_dir_entries = 1_000_000,
    });
}

// Before a trial the harness removes the previous side's watch root, up to
// the largest burst's files, and macOS delivers those removals to whoever
// watches next: a stream can be seconds behind. A write made just after a
// watch starts can also be lost (`before`, fixed since in 5249e23). So write
// until the warm-up file's own event arrives, however long the backlog takes
// (a minute at most), then take everything still pending until the stream is
// quiet, so nothing from before the trial is counted in it. Warm-up is not
// measured. The Go and Rust comparisons warm up the same way.
fn warmUp(watcher: *Watcher, dir: Io.Dir, io: Io) !void {
    var waited: u32 = 0;
    const seen = seen: while (waited < 60_000) : (waited += 100) {
        var digits: [10]u8 = undefined;
        const data = std.fmt.bufPrint(&digits, "{d}", .{waited}) catch unreachable;
        try dir.writeFile(io, .{ .sub_path = ".warmup", .data = data });
        for (try watcher.poll(100)) |event| {
            if (std.mem.endsWith(u8, event.path, ".warmup")) break :seen true;
        }
    } else false;
    if (!seen) return error.WarmupNotObserved;
    while ((try watcher.poll(200)).len != 0) {}
}

fn latency(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    var cfg = try readConfig(gpa, io, inputs);
    defer cfg.deinit();
    var names = try manifestAt(gpa, io, inputs, "latency.txt");
    defer names.deinit(gpa);
    var dir = try openRoot(io, root);
    defer dir.close(io);
    var watcher = try makeWatcher(gpa, io);
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });
    try warmUp(&watcher, dir, io);

    const samples = try gpa.alloc(i64, names.lines.len);
    defer gpa.free(samples);
    for (names.lines, 0..) |name, index| {
        const started = benchmarkNow(io);
        try dir.writeFile(io, .{ .sub_path = name, .data = "x" });
        var waited: u32 = 0;
        var seen = false;
        while (waited < 5_000 and !seen) : (waited += 100) {
            for (try watcher.poll(100)) |event| {
                if (std.mem.endsWith(u8, event.path, name)) {
                    samples[index] = started.durationTo(benchmarkNow(io)).toMicroseconds();
                    seen = true;
                    break;
                }
            }
        }
        if (!seen) return error.LatencyEventNotObserved;
        try io.sleep(.fromMilliseconds(cfg.value.latency_gap_ms), .awake);
    }
    std.mem.sort(i64, samples, {}, std.sort.asc(i64));
    const median = samples[(samples.len - 1) / 2];
    const p99_index = ((samples.len * 99 + 99) / 100) - 1;
    try metric(out, "latency", "latency_median", median, "us");
    try metric(out, "latency", "latency_p99", samples[p99_index], "us");
}

fn pathIndex(path: []const u8, prefix: []const u8, suffix: []const u8, count: usize) ?usize {
    const base = std.fs.path.basename(path);
    if (!std.mem.startsWith(u8, base, prefix) or !std.mem.endsWith(u8, base, suffix)) return null;
    const digits = base[prefix.len .. base.len - suffix.len];
    const index = std.fmt.parseInt(usize, digits, 10) catch return null;
    return if (index < count) index else null;
}

const FileWriter = struct {
    io: Io,
    dir: Io.Dir,
    names: []const []const u8,
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    started_us: std.atomic.Value(i64) = .init(0),

    fn run(w: *FileWriter) void {
        w.io.sleep(.fromMilliseconds(20), .awake) catch {};
        w.started_us.store(benchmarkNow(w.io).toMicroseconds(), .release);
        for (w.names) |name| {
            w.dir.writeFile(w.io, .{ .sub_path = name, .data = "x" }) catch {
                w.failed.store(true, .release);
                break;
            };
        }
        w.done.store(true, .release);
    }
};

/// How long a burst waits in silence for files still missing. FSEvents
/// delivers a burst seconds behind on a busy machine, and a two-second
/// window ended the comparison sides on different subsets of it.
const burst_patience_ms: u32 = 30_000;

fn burst(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    var cfg = try readConfig(gpa, io, inputs);
    defer cfg.deinit();
    var dir = try openRoot(io, root);
    defer dir.close(io);
    var watcher = try makeWatcher(gpa, io);
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });
    try warmUp(&watcher, dir, io);

    for (cfg.value.burst_counts) |count| {
        const filename = try std.fmt.allocPrint(gpa, "burst_{d}.txt", .{count});
        defer gpa.free(filename);
        var names = try manifestAt(gpa, io, inputs, filename);
        defer names.deinit(gpa);
        const seen = try gpa.alloc(bool, count);
        defer gpa.free(seen);
        @memset(seen, false);

        var writer: FileWriter = .{ .io = io, .dir = dir, .names = names.lines };
        const thread = try std.Thread.spawn(.{}, FileWriter.run, .{&writer});
        var delivered: usize = 0;
        var observed_so_far: usize = 0;
        var overflow = false;
        var last_us: ?i64 = null;
        var quiet: u32 = 0;
        // Two quiet seconds end the burst once every file has arrived or an
        // overflow says some will not; while files are still missing, up to
        // thirty, so that every side's last event is the same 10,000th one.
        while (quiet < (if (smoke) @as(u32, 200) else if (observed_so_far < count and !overflow) burst_patience_ms else @as(u32, 2_000))) {
            const events = try watcher.poll(100);
            if (events.len == 0 and writer.done.load(.acquire)) {
                quiet += 100;
                continue;
            }
            if (events.len != 0) quiet = 0;
            for (events) |event| {
                if (event.kind == .overflow) overflow = true;
                if (pathIndex(event.path, "f", ".txt", count)) |index| {
                    delivered += 1;
                    if (!seen[index]) observed_so_far += 1;
                    seen[index] = true;
                    const started = writer.started_us.load(.acquire);
                    if (started != 0) last_us = benchmarkNow(io).toMicroseconds() - started;
                }
            }
        }
        thread.join();
        if (writer.failed.load(.acquire)) return error.BurstWriteFailed;
        var observed: usize = 0;
        for (seen) |value| if (value) {
            observed += 1;
        };
        const workload = try std.fmt.allocPrint(gpa, "burst_{d}", .{count});
        defer gpa.free(workload);
        try metric(out, workload, "events_delivered", delivered, "events");
        try metric(out, workload, "files_missed", count - observed, "files");
        try metric(out, workload, "overflow_reported", @intFromBool(overflow), "bool");
        if (last_us) |value| {
            try metric(out, workload, "time_to_last_event", value, "us");
        } else {
            try out.print("lookout\t{s}\ttime_to_last_event\tn/a\tus\n", .{workload});
        }
    }
}

const RenameWriter = struct {
    io: Io,
    dir: Io.Dir,
    rows: []const []const u8,
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(w: *RenameWriter) void {
        w.io.sleep(.fromMilliseconds(20), .awake) catch {};
        for (w.rows) |row| {
            const tab = std.mem.indexOfScalar(u8, row, '\t') orelse {
                w.failed.store(true, .release);
                break;
            };
            w.dir.rename(row[0..tab], w.dir, row[tab + 1 ..], w.io) catch {
                w.failed.store(true, .release);
                break;
            };
        }
        w.done.store(true, .release);
    }
};

fn renameWork(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    var rows = try manifestAt(gpa, io, inputs, "rename.tsv");
    defer rows.deinit(gpa);
    const count = rows.lines.len;
    var dir = try openRoot(io, root);
    defer dir.close(io);
    var watcher = try makeWatcher(gpa, io);
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });
    try warmUp(&watcher, dir, io);

    const old_seen = try gpa.alloc(bool, count);
    defer gpa.free(old_seen);
    const new_seen = try gpa.alloc(bool, count);
    defer gpa.free(new_seen);
    const paired = try gpa.alloc(bool, count);
    defer gpa.free(paired);
    @memset(old_seen, false);
    @memset(new_seen, false);
    @memset(paired, false);

    var writer: RenameWriter = .{ .io = io, .dir = dir, .rows = rows.lines };
    const thread = try std.Thread.spawn(.{}, RenameWriter.run, .{&writer});
    var quiet: u32 = 0;
    while (quiet < (if (smoke) @as(u32, 200) else 2_000)) {
        const events = try watcher.poll(100);
        if (events.len == 0 and writer.done.load(.acquire)) {
            quiet += 100;
            continue;
        }
        if (events.len != 0) quiet = 0;
        for (events) |event| {
            const new_index = pathIndex(event.path, "r", "-new.txt", count);
            const old_index = if (event.from) |from| pathIndex(from, "r", "-old.txt", count) else pathIndex(event.path, "r", "-old.txt", count);
            if (old_index) |index| old_seen[index] = true;
            if (new_index) |index| new_seen[index] = true;
            if (old_index != null and new_index != null and old_index.? == new_index.?) paired[old_index.?] = true;
        }
    }
    thread.join();
    if (writer.failed.load(.acquire)) return error.RenameWriteFailed;
    var paired_count: usize = 0;
    var split_count: usize = 0;
    for (0..count) |index| {
        if (paired[index]) paired_count += 1 else if (old_seen[index] and new_seen[index]) split_count += 1;
    }
    try metric(out, "rename", "paired", paired_count, "renames");
    try metric(out, "rename", "split", split_count, "renames");
    try metric(out, "rename", "unmatched", count - paired_count - split_count, "renames");
}

fn cpuMicros() i64 {
    if (smoke) return 0;
    const usage = std.posix.getrusage(std.c.rusage.SELF);
    return @intCast(usage.utime.sec * 1_000_000 + usage.utime.usec + usage.stime.sec * 1_000_000 + usage.stime.usec);
}

const PacedWriter = struct {
    io: Io,
    dir: Io.Dir,
    names: []const []const u8,
    started: Io.Timestamp,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(w: *PacedWriter) void {
        for (w.names, 0..) |name, index| {
            w.dir.writeFile(w.io, .{ .sub_path = name, .data = "x" }) catch {
                w.failed.store(true, .release);
                return;
            };
            const target = w.started.addDuration(.fromMilliseconds(@intCast((index + 1) * 10)));
            const current = now(w.io);
            if (current.nanoseconds < target.nanoseconds) {
                w.io.sleep(.fromNanoseconds(target.nanoseconds - current.nanoseconds), .awake) catch return;
            }
        }
    }
};

fn idle(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    var cfg = try readConfig(gpa, io, inputs);
    defer cfg.deinit();
    var names = try manifestAt(gpa, io, inputs, "idle.txt");
    defer names.deinit(gpa);
    var dir = try openRoot(io, root);
    defer dir.close(io);
    var watcher = try makeWatcher(gpa, io);
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });
    try warmUp(&watcher, dir, io);

    const duration_ms = cfg.value.idle_seconds * 1_000;
    const idle_cpu_start = cpuMicros();
    const idle_start = now(io);
    while (idle_start.durationTo(now(io)).toMilliseconds() < duration_ms) _ = try watcher.poll(100);
    const idle_cpu = cpuMicros() - idle_cpu_start;

    const active_start = now(io);
    const active_cpu_start = cpuMicros();
    var writer: PacedWriter = .{ .io = io, .dir = dir, .names = names.lines, .started = active_start };
    const thread = try std.Thread.spawn(.{}, PacedWriter.run, .{&writer});
    while (active_start.durationTo(now(io)).toMilliseconds() < duration_ms) _ = try watcher.poll(100);
    thread.join();
    if (writer.failed.load(.acquire)) return error.ActiveWriteFailed;
    const active_cpu = cpuMicros() - active_cpu_start;
    try metric(out, "idle", "idle_cpu", idle_cpu, "us");
    try metric(out, "idle", "active_100ps_cpu", active_cpu, "us");
}

fn treeSetup(gpa: Allocator, io: Io, out: *std.Io.Writer, root: []const u8) !void {
    var samples: std.ArrayList(i64) = .empty;
    defer samples.deinit(gpa);
    var total_us: i64 = 0;
    while (samples.items.len == 0 or (!smoke and total_us < 200_000)) {
        var watcher = try makeWatcher(gpa, io);
        const started = benchmarkNow(io);
        _ = watcher.add(root, .{ .recursive = true }) catch |err| {
            watcher.deinit();
            std.debug.print("lookout setup failed: {s}\n", .{@errorName(err)});
            try out.writeAll("lookout\ttree_setup\tsetup_time\tn/a\tus\n");
            try metric(out, "tree_setup", "setup_success", 0, "bool");
            return;
        };
        const elapsed = started.durationTo(benchmarkNow(io)).toMicroseconds();
        try samples.append(gpa, elapsed);
        total_us += elapsed;
        watcher.deinit();
    }
    std.mem.sort(i64, samples.items, {}, std.sort.asc(i64));
    try metric(out, "tree_setup", "setup_time", samples.items[(samples.items.len - 1) / 2], "us");
    try metric(out, "tree_setup", "setup_success", 1, "bool");
}

/// Runs `op.once()` until 200 ms of it have been measured, once in smoke,
/// and returns the median sample in microseconds. `once` times only the
/// operation; anything it needs set up or torn down stays outside.
fn medianOf(gpa: Allocator, op: anytype) !i64 {
    var samples: std.ArrayList(i64) = .empty;
    defer samples.deinit(gpa);
    var total: i64 = 0;
    while (samples.items.len == 0 or (!smoke and total < 200_000)) {
        const us = try op.once();
        try samples.append(gpa, us);
        total += us;
    }
    std.mem.sort(i64, samples.items, {}, std.sort.asc(i64));
    return samples.items[(samples.items.len - 1) / 2];
}

fn since(started: Io.Timestamp, io: Io) i64 {
    return started.durationTo(benchmarkNow(io)).toMicroseconds();
}

/// kqueue holds a descriptor per watched file and directory. Go raises its
/// soft descriptor limit to the hard one at start; every side does the same
/// before a kqueue workload, capped where macOS caps it.
fn raiseDescriptorLimit() void {
    var limit = std.posix.getrlimit(.NOFILE) catch return;
    var cap: c_int = 0;
    var len: usize = @sizeOf(c_int);
    if (std.c.sysctlbyname("kern.maxfilesperproc", &cap, &len, null, 0) == 0 and cap > 0) {
        limit.cur = @min(limit.max, @as(std.posix.rlim_t, @intCast(cap)));
    } else limit.cur = limit.max;
    std.posix.setrlimit(.NOFILE, limit) catch {};
}

/// Half the setup tree's directories, by the patterns `refilter` narrows to.
const narrow_filter: lookout.Filter = .{ .ignore = &.{ "d000?", "d001?", "d002?", "d003?", "d004?" } };

/// The FSEvents and poll backends' recursive add, refilter and remove over
/// the setup tree, and one polling scan of it. The poll interval is an
/// hour, so nothing scans between the timed calls.
///
/// kqueue's are timed over the 1,000- and 10,000-file baseline trees
/// instead, and so are its comparisons': it checks each file it adds
/// against every node already in the tree, so its time grows with the
/// square of the tree, and one add of the 50,000-file tree took three and
/// a half minutes.
fn backendSetup(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    raiseDescriptorLimit();
    const Cycle = struct {
        gpa: Allocator,
        io: Io,
        root: []const u8,
        backend: lookout.Backend,
        filter: lookout.Filter = narrow_filter,
        narrow: std.ArrayList(i64) = .empty,
        widen: std.ArrayList(i64) = .empty,
        remove: std.ArrayList(i64) = .empty,
        registrations: usize = 0,
        narrowed: usize = 0,

        fn deinit(c: *@This()) void {
            c.narrow.deinit(c.gpa);
            c.widen.deinit(c.gpa);
            c.remove.deinit(c.gpa);
        }

        fn once(c: *@This()) !i64 {
            var watcher: Watcher = try .init(c.gpa, c.io, .{
                .backend = c.backend,
                .latency_ms = 0,
                .poll_interval_ms = 3_600_000,
                .max_dir_entries = 1_000_000,
            });
            defer watcher.deinit();
            var started = benchmarkNow(c.io);
            const id = try watcher.add(c.root, .{ .recursive = true });
            const setup = since(started, c.io);
            c.registrations = watcher.stats().registrations;
            started = benchmarkNow(c.io);
            try watcher.refilter(id, c.filter);
            try c.narrow.append(c.gpa, since(started, c.io));
            c.narrowed = watcher.stats().registrations;
            started = benchmarkNow(c.io);
            try watcher.refilter(id, .none);
            try c.widen.append(c.gpa, since(started, c.io));
            if (watcher.stats().registrations != c.registrations) return error.RefilterDidNotRestore;
            started = benchmarkNow(c.io);
            watcher.remove(id);
            try c.remove.append(c.gpa, since(started, c.io));
            return setup;
        }

        fn report(c: *@This(), out_: *std.Io.Writer, setup: i64, suffix: []const u8) !void {
            var name: [64]u8 = undefined;
            const tag = @tagName(c.backend);
            const setup_name = try std.fmt.bufPrint(&name, "setup_{s}{s}", .{ tag, suffix });
            try metric(out_, setup_name, "setup_time", setup, "us");
            try metric(out_, setup_name, "registrations", c.registrations, "records");
            const refilter_name = try std.fmt.bufPrint(&name, "refilter_{s}{s}", .{ tag, suffix });
            try metric(out_, refilter_name, "narrow_time", medianSample(c.narrow.items), "us");
            try metric(out_, refilter_name, "widen_time", medianSample(c.widen.items), "us");
            try metric(out_, refilter_name, "registrations_narrowed", c.narrowed, "records");
            try metric(out_, try std.fmt.bufPrint(&name, "remove_{s}{s}", .{ tag, suffix }), "remove_time", medianSample(c.remove.items), "us");
        }
    };
    for ([_]lookout.Backend{ .fsevents, .poll }) |backend| {
        var cycle: Cycle = .{ .gpa = gpa, .io = io, .root = root, .backend = backend };
        defer cycle.deinit();
        const setup = try medianOf(gpa, &cycle);
        try cycle.report(out, setup, "");
    }
    for (kqueue_trees) |size| {
        // The first half of the tree's directories, by name.
        var patterns: std.ArrayList([]const u8) = .empty;
        defer {
            for (patterns.items) |pattern| gpa.free(pattern);
            patterns.deinit(gpa);
        }
        const dirs = try countDirs(gpa, io, inputs, size);
        for (0..dirs / 2) |d| try patterns.append(gpa, try std.fmt.allocPrint(gpa, "d{d:0>4}", .{d}));
        const tree = try std.fs.path.join(gpa, &.{ inputs, "baseline_trees", size });
        defer gpa.free(tree);
        var cycle: Cycle = .{ .gpa = gpa, .io = io, .root = tree, .backend = .kqueue, .filter = .{ .ignore = patterns.items } };
        defer cycle.deinit();
        // Once for the larger tree: its add and widening take seconds.
        const setup = if (std.mem.eql(u8, size, "small")) try medianOf(gpa, &cycle) else try cycle.once();
        var suffix: [16]u8 = undefined;
        try cycle.report(out, setup, try std.fmt.bufPrint(&suffix, "_{s}", .{size}));
    }

    // One polling scan: `poll(0)` lists and compares every watched
    // directory once and returns.
    var watcher: Watcher = try .init(gpa, io, .{
        .backend = .poll,
        .latency_ms = 0,
        .poll_interval_ms = 3_600_000,
        .max_dir_entries = 1_000_000,
    });
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });
    const Scan = struct {
        io: Io,
        watcher: *Watcher,
        events: usize = 0,
        fn once(c: *@This()) !i64 {
            const started = benchmarkNow(c.io);
            c.events += (try c.watcher.poll(0)).len;
            return since(started, c.io);
        }
    };
    var scan: Scan = .{ .io = io, .watcher = &watcher };
    const scan_us = try medianOf(gpa, &scan);
    try metric(out, "scan_poll", "scan_time", scan_us, "us");
    try metric(out, "scan_poll", "events", scan.events, "events");
}

/// The baseline trees kqueue's add, refilter and remove are timed over.
const kqueue_trees = [_][]const u8{ "small", "medium" };

fn countDirs(gpa: Allocator, io: Io, inputs: []const u8, size: []const u8) !usize {
    var cfg = try readConfig(gpa, io, inputs);
    defer cfg.deinit();
    for (cfg.value.baseline_sizes) |entry| {
        if (std.mem.eql(u8, entry.name, size)) return entry.dirs;
    }
    return error.UnknownTree;
}

fn medianSample(values: []i64) i64 {
    std.mem.sort(i64, values, {}, std.sort.asc(i64));
    return values[(values.len - 1) / 2];
}

/// The CPU a polling watcher over the setup tree costs at a 100 ms
/// interval, over one window in which nothing changes.
fn pollCpu(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    var cfg = try readConfig(gpa, io, inputs);
    defer cfg.deinit();
    var watcher: Watcher = try .init(gpa, io, .{
        .backend = .poll,
        .latency_ms = 0,
        .poll_interval_ms = 100,
        .max_dir_entries = 1_000_000,
    });
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });
    var events: usize = 0;
    const cpu_start = cpuMicros();
    const started = now(io);
    while (true) {
        const elapsed: u32 = @intCast(started.durationTo(now(io)).toMilliseconds());
        if (elapsed >= cfg.value.poll_window_ms) break;
        events += (try watcher.poll(cfg.value.poll_window_ms - elapsed)).len;
    }
    if (cfg.value.poll_window_ms == 0) events += (try watcher.poll(0)).len;
    try metric(out, "poll_cpu", "cpu", cpuMicros() - cpu_start, "us");
    try metric(out, "poll_cpu", "events", events, "events");
}

/// Applies or undoes the baseline workload's changes: in each directory,
/// every `every`th file rewritten with a different size, the next one
/// removed, and a new name created beside the one after.
fn mutateTree(io: Io, dir: Io.Dir, size: BaselineSize, every: usize, undo: bool) !void {
    for (0..size.dirs) |d| {
        const count = size.files / size.dirs + @intFromBool(d < size.files % size.dirs);
        for (0..count) |i| {
            var name: [64]u8 = undefined;
            switch (i % every) {
                0 => try dir.writeFile(io, .{
                    .sub_path = try std.fmt.bufPrint(&name, "d{d:0>4}/f{d:0>6}.txt", .{ d, i }),
                    .data = if (undo) "x" else "yy",
                }),
                1 => {
                    const sub = try std.fmt.bufPrint(&name, "d{d:0>4}/f{d:0>6}.txt", .{ d, i });
                    if (undo) try dir.writeFile(io, .{ .sub_path = sub, .data = "x" }) else try dir.deleteFile(io, sub);
                },
                2 => {
                    const sub = try std.fmt.bufPrint(&name, "d{d:0>4}/n{d:0>6}.txt", .{ d, i });
                    if (undo) try dir.deleteFile(io, sub) else try dir.writeFile(io, .{ .sub_path = sub, .data = "x" });
                },
                else => {},
            }
        }
    }
}

const ChangeCount = struct {
    created: usize = 0,
    modified: usize = 0,
    removed: usize = 0,
    other: usize = 0,

    fn of(changes: []const lookout.Baseline.Change) ChangeCount {
        var c: ChangeCount = .{};
        for (changes) |change| {
            const base = std.fs.path.basename(change.path);
            if (change.kind == .created and base[0] == 'n') {
                c.created += 1;
            } else if (change.kind == .modified and base[0] == 'f') {
                c.modified += 1;
            } else if (change.kind == .removed and base[0] == 'f') {
                c.removed += 1;
            } else c.other += 1;
        }
        return c;
    }
};

/// `Baseline.seed` and `diff` over three tree sizes: seeding, a diff with
/// nothing changed, and a diff after one change in a hundred files of each
/// kind. The trees are restored after each diff, so every side starts from
/// the same tree.
fn baselineWork(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    var cfg = try readConfig(gpa, io, inputs);
    defer cfg.deinit();
    for (cfg.value.baseline_sizes) |size| {
        const path = try std.fs.path.join(gpa, &.{ root, size.name });
        defer gpa.free(path);
        var dir = try openRoot(io, path);
        defer dir.close(io);

        const Seed = struct {
            gpa: Allocator,
            io: Io,
            path: []const u8,
            fn once(c: *@This()) !i64 {
                const started = benchmarkNow(c.io);
                var b = try lookout.Baseline.seed(c.gpa, c.io, c.path, .{ .recursive = true, .max_dir_entries = 1_000_000 });
                const us = since(started, c.io);
                b.deinit(c.gpa);
                return us;
            }
        };
        var seed: Seed = .{ .gpa = gpa, .io = io, .path = path };
        const seed_us = try medianOf(gpa, &seed);

        var b = try lookout.Baseline.seed(gpa, io, path, .{ .recursive = true, .max_dir_entries = 1_000_000 });
        defer b.deinit(gpa);
        const Unchanged = struct {
            gpa: Allocator,
            io: Io,
            b: *lookout.Baseline,
            fn once(c: *@This()) !i64 {
                const started = benchmarkNow(c.io);
                const changes = try c.b.diff(c.gpa);
                const us = since(started, c.io);
                if (changes.len != 0) return error.UnchangedTreeDiffered;
                return us;
            }
        };
        var unchanged: Unchanged = .{ .gpa = gpa, .io = io, .b = &b };
        const unchanged_us = try medianOf(gpa, &unchanged);

        const Changed = struct {
            gpa: Allocator,
            io: Io,
            b: *lookout.Baseline,
            dir: Io.Dir,
            size: BaselineSize,
            every: usize,
            counts: ChangeCount = .{},
            fn once(c: *@This()) !i64 {
                try mutateTree(c.io, c.dir, c.size, c.every, false);
                const started = benchmarkNow(c.io);
                const changes = try c.b.diff(c.gpa);
                const us = since(started, c.io);
                c.counts = .of(changes);
                try mutateTree(c.io, c.dir, c.size, c.every, true);
                _ = try c.b.diff(c.gpa);
                return us;
            }
        };
        var changed: Changed = .{ .gpa = gpa, .io = io, .b = &b, .dir = dir, .size = size, .every = cfg.value.baseline_change_every };
        const changed_us = try medianOf(gpa, &changed);

        var name: [64]u8 = undefined;
        const workload = try std.fmt.bufPrint(&name, "baseline_{s}", .{size.name});
        try metric(out, workload, "seed_time", seed_us, "us");
        try metric(out, workload, "diff_unchanged_time", unchanged_us, "us");
        try metric(out, workload, "diff_changed_time", changed_us, "us");
        try metric(out, workload, "created", changed.counts.created, "records");
        try metric(out, workload, "modified", changed.counts.modified, "records");
        try metric(out, workload, "removed", changed.counts.removed, "records");
        try metric(out, workload, "other_changes", changed.counts.other, "records");
    }
}

const has_checkpoint = @hasDecl(lookout, "Checkpoint");

/// A resume position as this revision spells it: `Checkpoint` since it
/// replaced `Position`.
const Resume = if (has_checkpoint) struct {
    checkpoint: lookout.Checkpoint,

    fn take(gpa: Allocator, watcher: *const Watcher) ![]u8 {
        var checkpoint = (try watcher.checkpoint(gpa)) orelse return error.NoCheckpoint;
        defer checkpoint.deinit();
        return checkpoint.token(gpa);
    }
    fn parse(gpa: Allocator, token: []const u8) !@This() {
        return .{ .checkpoint = try lookout.Checkpoint.parse(gpa, token) };
    }
    fn deinit(r: *@This()) void {
        r.checkpoint.deinit();
    }
    fn options(r: *const @This()) lookout.Options {
        return .{ .backend = .fsevents, .latency_ms = 0, .checkpoint = r.checkpoint };
    }
} else struct {
    position: lookout.Position,

    fn take(gpa: Allocator, watcher: *const Watcher) ![]u8 {
        const position = watcher.position() orelse return error.NoCheckpoint;
        var buffer: [lookout.Position.max_token_len]u8 = undefined;
        return gpa.dupe(u8, position.token(&buffer));
    }
    fn parse(_: Allocator, token: []const u8) !@This() {
        return .{ .position = try lookout.Position.parse(token) };
    }
    fn deinit(_: *@This()) void {}
    fn options(r: *const @This()) lookout.Options {
        return .{ .backend = .fsevents, .latency_ms = 0, .since = r.position };
    }
};

/// Checkpoint, token and parse, and a resume that reports the files
/// removed while nothing watched.
fn checkpointWork(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    var cfg = try readConfig(gpa, io, inputs);
    defer cfg.deinit();
    const count = cfg.value.checkpoint_files;
    var dir = try openRoot(io, root);
    defer dir.close(io);

    var token: []u8 = undefined;
    var take_us: i64 = 0;
    var parse_us: i64 = 0;
    {
        var watcher = try makeWatcher(gpa, io);
        defer watcher.deinit();
        _ = try watcher.add(root, .{ .recursive = true });
        try warmUp(&watcher, dir, io);
        const Take = struct {
            gpa: Allocator,
            io: Io,
            watcher: *const Watcher,
            fn once(c: *@This()) !i64 {
                const started = benchmarkNow(c.io);
                const text = try Resume.take(c.gpa, c.watcher);
                const us = since(started, c.io);
                c.gpa.free(text);
                return us;
            }
        };
        var take: Take = .{ .gpa = gpa, .io = io, .watcher = &watcher };
        take_us = try medianOf(gpa, &take);
        token = try Resume.take(gpa, &watcher);
    }
    defer gpa.free(token);
    const Parse = struct {
        gpa: Allocator,
        io: Io,
        token: []const u8,
        fn once(c: *@This()) !i64 {
            const started = benchmarkNow(c.io);
            var parsed = try Resume.parse(c.gpa, c.token);
            const us = since(started, c.io);
            parsed.deinit();
            return us;
        }
    };
    var parse: Parse = .{ .gpa = gpa, .io = io, .token = token };
    parse_us = try medianOf(gpa, &parse);

    for (0..count) |i| {
        var name: [32]u8 = undefined;
        try dir.deleteFile(io, try std.fmt.bufPrint(&name, "c{d:0>4}.txt", .{i}));
    }

    const seen = try gpa.alloc(bool, count);
    defer gpa.free(seen);
    @memset(seen, false);
    var resumed = try Resume.parse(gpa, token);
    defer resumed.deinit();
    const started = benchmarkNow(io);
    var watcher: Watcher = try .init(gpa, io, resumed.options());
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });
    const add_us = since(started, io);
    var observed: usize = 0;
    var last_us: ?i64 = null;
    var quiet: u32 = 0;
    // Until every removal has come, or ten seconds have brought none.
    while (observed < count and quiet < 10_000) {
        const events = try watcher.poll(100);
        if (events.len == 0) quiet += 100 else quiet = 0;
        for (events) |event| {
            if (event.kind != .removed) continue;
            const index = pathIndex(event.path, "c", ".txt", count) orelse continue;
            if (seen[index]) continue;
            seen[index] = true;
            observed += 1;
            last_us = since(started, io);
        }
    }
    try metric(out, "checkpoint", "take_time", take_us, "us");
    try metric(out, "checkpoint", "parse_time", parse_us, "us");
    try metric(out, "checkpoint", "resume_add_time", add_us, "us");
    if (last_us) |value| {
        try metric(out, "checkpoint", "resume_last_removal", value, "us");
    } else try out.writeAll("lookout\tcheckpoint\tresume_last_removal\tn/a\tus\n");
    try metric(out, "checkpoint", "removals_missed", count - observed, "files");
}

/// Absolute paths for every entry of the setup tree, from its manifest,
/// and, with `outside`, the same names under a sibling that shares the
/// root's name as a prefix.
fn subjects(gpa: Allocator, names: []const []const u8, root: []const u8, outside: bool) ![][]u8 {
    const list = try gpa.alloc([]u8, names.len * @as(usize, if (outside) 2 else 1));
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |item| gpa.free(item);
        gpa.free(list);
    }
    for (names) |name| {
        list[filled] = try std.fs.path.join(gpa, &.{ root, name });
        filled += 1;
    }
    if (outside) {
        const sibling = try std.mem.concat(gpa, u8, &.{ root, "x" });
        defer gpa.free(sibling);
        for (names) |name| {
            list[filled] = try std.fs.path.join(gpa, &.{ sibling, name });
            filled += 1;
        }
    }
    return list;
}

fn freeSubjects(gpa: Allocator, list: [][]u8) void {
    for (list) |item| gpa.free(item);
    gpa.free(list);
}

/// `Filter.excludes` over every path of the setup tree.
fn filterWork(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    var names = try manifestAt(gpa, io, inputs, "paths.txt");
    defer names.deinit(gpa);
    const list = try subjects(gpa, names.lines, root, false);
    defer freeSubjects(gpa, list);
    const filter: lookout.Filter = .{ .ignore = &.{ "d001?", "*7.txt", "d009?/**" } };
    const Pass = struct {
        io: Io,
        root: []const u8,
        list: []const []const u8,
        filter: lookout.Filter,
        excluded: usize = 0,
        fn once(c: *@This()) !i64 {
            var excluded: usize = 0;
            const started = benchmarkNow(c.io);
            for (c.list) |subject| excluded += @intFromBool(c.filter.excludes(c.root, subject));
            const us = since(started, c.io);
            c.excluded = excluded;
            return us;
        }
    };
    var pass: Pass = .{ .io = io, .root = root, .list = list, .filter = filter };
    const us = try medianOf(gpa, &pass);
    try metric(out, "filter", "excludes_time", us, "us");
    try metric(out, "filter", "excluded", pass.excluded, "records");
    try metric(out, "filter", "paths", list.len, "records");
}

/// `path.relative` and `path.within` over every path of the setup tree and
/// as many beside it.
fn pathWork(gpa: Allocator, io: Io, out: *std.Io.Writer, inputs: []const u8, root: []const u8) !void {
    var names = try manifestAt(gpa, io, inputs, "paths.txt");
    defer names.deinit(gpa);
    const list = try subjects(gpa, names.lines, root, true);
    defer freeSubjects(gpa, list);
    const Pass = struct {
        io: Io,
        root: []const u8,
        list: []const []const u8,
        within: bool,
        inside: usize = 0,
        bytes: usize = 0,
        fn once(c: *@This()) !i64 {
            var inside: usize = 0;
            var bytes: usize = 0;
            const started = benchmarkNow(c.io);
            for (c.list) |subject| {
                if (c.within) {
                    inside += @intFromBool(lookout.path.within(c.root, subject));
                } else if (lookout.path.relative(c.root, subject)) |rest| {
                    inside += 1;
                    bytes += rest.len;
                }
            }
            const us = since(started, c.io);
            c.inside = inside;
            c.bytes = bytes;
            return us;
        }
    };
    var relative: Pass = .{ .io = io, .root = root, .list = list, .within = false };
    const relative_us = try medianOf(gpa, &relative);
    var within: Pass = .{ .io = io, .root = root, .list = list, .within = true };
    const within_us = try medianOf(gpa, &within);
    if (relative.inside != within.inside) return error.PathHelpersDisagree;
    try metric(out, "path", "relative_time", relative_us, "us");
    try metric(out, "path", "within_time", within_us, "us");
    try metric(out, "path", "inside", relative.inside, "records");
    try metric(out, "path", "relative_bytes", relative.bytes, "bytes");
    try metric(out, "path", "paths", list.len, "records");
}

var smoke_ticks = std.atomic.Value(i64).init(1);
fn benchmarkNow(io: Io) Io.Timestamp {
    if (smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1_000, .monotonic) };
    return now(io);
}
