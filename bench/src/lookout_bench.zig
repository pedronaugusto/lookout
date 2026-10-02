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
    } else return error.UnknownWorkload;
    try out.flush();
}

fn readConfig(gpa: Allocator, io: Io, inputs: []const u8) !std.json.Parsed(Config) {
    const path = try std.fs.path.join(gpa, &.{ inputs, "config.json" });
    defer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(bytes);
    return std.json.parseFromSlice(Config, gpa, bytes, .{ .ignore_unknown_fields = true });
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

fn warmUp(watcher: *Watcher, dir: Io.Dir, io: Io) !void {
    try dir.writeFile(io, .{ .sub_path = ".warmup", .data = "x" });
    var waited: u32 = 0;
    while (waited < 5_000) : (waited += 100) {
        for (try watcher.poll(100)) |event| {
            if (std.mem.endsWith(u8, event.path, ".warmup")) return;
        }
    }
    return error.WarmupNotObserved;
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
        const started = now(io);
        try dir.writeFile(io, .{ .sub_path = name, .data = "x" });
        var waited: u32 = 0;
        var seen = false;
        while (waited < 5_000 and !seen) : (waited += 100) {
            for (try watcher.poll(100)) |event| {
                if (std.mem.endsWith(u8, event.path, name)) {
                    samples[index] = started.durationTo(now(io)).toMicroseconds();
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
        w.started_us.store(now(w.io).toMicroseconds(), .release);
        for (w.names) |name| {
            w.dir.writeFile(w.io, .{ .sub_path = name, .data = "x" }) catch {
                w.failed.store(true, .release);
                break;
            };
        }
        w.done.store(true, .release);
    }
};

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
        var overflow = false;
        var last_us: ?i64 = null;
        var quiet: u32 = 0;
        while (quiet < (if (smoke) @as(u32, 200) else 2_000)) {
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
                    seen[index] = true;
                    const started = writer.started_us.load(.acquire);
                    if (started != 0) last_us = now(io).toMicroseconds() - started;
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
        const started = now(io);
        _ = watcher.add(root, .{ .recursive = true }) catch |err| {
            watcher.deinit();
            std.debug.print("lookout setup failed: {s}\n", .{@errorName(err)});
            try out.writeAll("lookout\ttree_setup\tsetup_time\tn/a\tus\n");
            try metric(out, "tree_setup", "setup_success", 0, "bool");
            return;
        };
        const elapsed = started.durationTo(now(io)).toMicroseconds();
        try samples.append(gpa, elapsed);
        total_us += elapsed;
        watcher.deinit();
    }
    std.mem.sort(i64, samples.items, {}, std.sort.asc(i64));
    try metric(out, "tree_setup", "setup_time", samples.items[(samples.items.len - 1) / 2], "us");
    try metric(out, "tree_setup", "setup_success", 1, "bool");
}
