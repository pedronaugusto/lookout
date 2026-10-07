//! lookout's speed claims, each held to its ceiling on every backend this
//! target was built with. `zig build bench` runs them; run it on a quiet
//! machine, in a release mode. Every other step only compiles them.

const std = @import("std");
const lookout = @import("lookout");
const Watcher = lookout.Watcher;
const Io = std.Io;

/// Every backend this target was built with.
const backends: []const lookout.Backend = all: {
    const values = std.enums.values(lookout.Backend);
    var list: [values.len]lookout.Backend = undefined;
    var len: usize = 0;
    for (values) |backend| {
        if (backend == .auto or !lookout.supported(backend)) continue;
        list[len] = backend;
        len += 1;
    }
    const final = list[0..len].*;
    break :all &final;
};

const timeout_ms = 5_000;

/// A wait of `ms` milliseconds on the monotonic clock.
fn within(ms: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    watcher: Watcher,

    fn init(backend: lookout.Backend) !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(root);
        return .{ .tmp = tmp, .root = root, .watcher = try Watcher.init(std.testing.allocator, .{ .backend = backend, .poll_interval = .fromMilliseconds(20) }) };
    }
    fn deinit(f: *Fixture) void {
        f.watcher.deinit(std.testing.io);
        std.testing.allocator.free(f.root);
        f.tmp.cleanup();
    }
    fn write(f: *Fixture, name: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
    }
    fn settle(f: *Fixture) !void {
        while ((try f.watcher.poll(std.testing.io, within(200))).len != 0) {}
    }
    fn path(f: *Fixture, name: []const u8) ![]u8 {
        return std.Io.Dir.path.join(std.testing.allocator, &.{ f.root, name });
    }
};
fn Held(comptime Result: type, comptime then: anytype) type {
    return struct {
        watcher: *Watcher,
        path: []const u8 = "",
        go: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) Result {
            while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
            return then(self);
        }

        /// Lets the task go from another thread, after `delay_ms`.
        fn release(self: *@This(), delay_ms: i64) void {
            std.testing.io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
            self.go.store(true, .release);
        }
    };
}

fn pollOnce(self: anytype) Watcher.PollError![]const lookout.Event {
    return self.watcher.poll(std.testing.io, within(timeout_ms));
}

/// The longest a backend may take to come back with a change that
/// happened while `poll` was already blocked, in milliseconds.
fn wakeBudgetMs(backend: lookout.Backend, interval_ms: u32) u32 {
    return switch (backend) {
        .poll => interval_ms + 500,
        else => 500,
    };
}

test "quiet: a change that happens while poll is blocked comes back promptly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const rounds = 5;
    const interval_ms = 200;

    var over = false;
    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, .{
            .backend = backend,
            .poll_interval = .fromMilliseconds(interval_ms),
            // The wait being measured is the backend's, not the
            // coalescing tail's.
            .latency = .zero,
        });
        defer watcher.deinit(io);
        _ = try watcher.add(io, root, .{});
        while ((try watcher.poll(io, within(200))).len != 0) {}

        const Toucher = struct {
            dir: std.Io.Dir,
            round: usize = 0,
            stamped: std.Io.Timestamp = .zero,

            fn run(self: *@This()) void {
                const w_io = std.testing.io;
                // Long enough that the main thread is certainly blocked
                // in the backend's wait rather than on its way there.
                w_io.sleep(.fromMilliseconds(150), .awake) catch return;
                var name: [32]u8 = undefined;
                self.stamped = benchmarkNow(w_io);
                self.dir.writeFile(w_io, .{
                    // unreachable: "w" and a usize's digits fit in 32 bytes
                    .sub_path = std.mem.print(&name, "w{d}.txt", .{self.round}) catch unreachable,
                    .data = "x",
                }) catch {};
            }
        };

        var worst: i64 = 0;
        for (0..rounds) |round| {
            var toucher: Toucher = .{ .dir = tmp.dir, .round = round };
            const thread = try std.Thread.spawn(.{}, Toucher.run, .{&toucher});
            var seen: ?std.Io.Timestamp = null;
            while (seen == null) {
                const events = try watcher.poll(io, within(5_000));
                if (events.len == 0) break;
                for (events) |event| {
                    if (event.kind == .created) seen = benchmarkNow(io);
                }
            }
            thread.join();
            const arrived = seen orelse return error.EventNotObserved;
            const took = toucher.stamped.durationTo(arrived).toMilliseconds();
            if (took > worst) worst = took;
        }

        const budget = wakeBudgetMs(backend, interval_ms);
        if (worst > budget) {
            std.debug.print("{s}: worst wake {d} ms, budget {d} ms\n", .{
                @tagName(backend), worst, budget,
            });
        }
        metric("blocked_change", backend, worst);
        over = !judged("blocked_change", backend, budget, worst <= budget) or over;
    }
    try std.testing.expect(!over);
}

test "quiet: a file saved by a rename and then deleted is reported gone at once, in a long wait" {
    // An editor saves by writing a new file and renaming it over the old
    // one; the file is later deleted. FSEvents keeps a path's flags, so the
    // deletion arrives as a rename half with no partner, which is held for
    // one. A wait with no deadline of its own must still decide it within
    // the pairing grace, not when the next unrelated change comes.
    var over = false;
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("next.md", "one");
        _ = try f.watcher.add(std.testing.io, f.root, .{ .recursive = true });
        try f.settle();

        try f.write("next.new", "two");
        try f.tmp.dir.rename("next.new", f.tmp.dir, "next.md", std.testing.io);
        try f.settle();

        try f.tmp.dir.deleteFile(std.testing.io, "next.md");
        const gone = try f.path("next.md");
        defer std.testing.allocator.free(gone);
        const started = benchmarkNow(std.testing.io);
        var seen = false;
        while (!seen) {
            const events = try f.watcher.poll(std.testing.io, within(timeout_ms));
            if (events.len == 0) break;
            for (events) |event| {
                if (std.mem.eql(u8, event.path, gone) and (event.kind == .removed or event.kind == .renamed)) seen = true;
            }
        }
        const waited_ms = @divTrunc(started.durationTo(benchmarkNow(std.testing.io)).nanoseconds, std.time.ns_per_ms);
        try std.testing.expect(seen);
        metric("rename_then_delete", backend, waited_ms);
        over = !judged("rename_then_delete", backend, timeout_ms / 2, waited_ms < timeout_ms / 2) or over;
    }
    try std.testing.expect(!over);
}
test "quiet: a cancellation requested before poll is reported at once" {
    var over = false;
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(std.testing.io, f.root, .{});

        const Task = Held(Watcher.PollError![]const lookout.Event, pollOnce);
        var task: Task = .{ .watcher = &f.watcher };
        var future = std.testing.io.concurrent(Task.run, .{&task}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.SkipZigTest,
        };
        const thread = try std.Thread.spawn(.{}, Task.release, .{ &task, 50 });
        defer thread.join();

        // The cancellation lands while the task is not in `std.Io` at
        // all. Nothing will happen to the tree, so a poll that did not
        // look for it before waiting would wait out its whole timeout,
        // and on a kernel backend would not be told about it even then.
        const started: std.Io.Timestamp = benchmarkNow(std.testing.io);
        try std.testing.expectError(error.Canceled, future.cancel(std.testing.io));
        const elapsed = started.durationTo(benchmarkNow(std.testing.io));
        metric("cancel_before_poll", backend, elapsed.toMilliseconds());
        over = !judged("cancel_before_poll", backend, timeout_ms / 2, elapsed.toMilliseconds() < timeout_ms / 2) or over;
    }
    try std.testing.expect(!over);
}

test "quiet: a watcher can be woken from another thread" {
    var over = false;
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(std.testing.io, f.root, .{});

        const Waker = struct {
            watcher: *Watcher,
            fn run(self: *@This()) void {
                std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
                self.watcher.wake();
            }
        };
        var waker: Waker = .{ .watcher = &f.watcher };
        const thread = try std.Thread.spawn(.{}, Waker.run, .{&waker});
        defer thread.join();

        // Nothing is going to happen to the tree, so without the wake
        // this blocks for as long as the caller is prepared to wait --
        // and with `null`, forever.
        const started: std.Io.Timestamp = benchmarkNow(std.testing.io);
        const events = try f.watcher.poll(std.testing.io, .none);
        const elapsed = started.durationTo(benchmarkNow(std.testing.io));
        try std.testing.expectEqual(@as(usize, 0), events.len);
        metric("wake", backend, elapsed.toMilliseconds());
        over = !judged("wake", backend, timeout_ms, elapsed.toMilliseconds() < timeout_ms) or over;
    }
    try std.testing.expect(!over);
}

test "quiet: a polling task is stopped by a flag and a wake on every backend" {
    var over = false;
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(std.testing.io, f.root, .{});

        // The recipe `Watcher.wake` gives, as written there.
        const Task = struct {
            watcher: *Watcher,
            stopping: std.atomic.Value(bool) = .init(false),
            polls: usize = 0,

            fn run(self: *@This()) Watcher.PollError!void {
                while (!self.stopping.load(.acquire)) {
                    _ = try self.watcher.poll(std.testing.io, .none);
                    self.polls += 1;
                }
            }
        };
        var task: Task = .{ .watcher = &f.watcher };
        var future = std.testing.io.concurrent(Task.run, .{&task}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.SkipZigTest,
        };
        std.testing.io.sleep(.fromMilliseconds(50), .awake) catch {};

        const started: std.Io.Timestamp = benchmarkNow(std.testing.io);
        task.stopping.store(true, .release);
        f.watcher.wake();
        try future.await(std.testing.io);
        const elapsed = started.durationTo(benchmarkNow(std.testing.io));
        metric("stop_by_flag", backend, elapsed.toMilliseconds());
        over = !judged("stop_by_flag", backend, timeout_ms, elapsed.toMilliseconds() < timeout_ms) or over;
    }
    try std.testing.expect(!over);
}

/// One row of the report, `lookout <job>_<backend> <measure> <value> <unit>`,
/// tab-separated on standard error: standard output carries the test
/// runner's own protocol.
fn row(job: []const u8, backend: lookout.Backend, measure: []const u8, value: anytype, unit: []const u8) void {
    var buffer: [256]u8 = undefined;
    var stderr = Io.File.stderr().writer(std.testing.io, &buffer);
    const out = &stderr.interface;
    out.print("lookout\t{s}_{s}\t{s}\t{d}\t{s}\n", .{ job, @tagName(backend), measure, value, unit }) catch return;
    out.flush() catch return;
}

fn metric(job: []const u8, backend: lookout.Backend, milliseconds: anytype) void {
    row(job, backend, "elapsed", milliseconds, "ms");
}

/// Reports a speed ceiling and whether the measurement kept to it, and
/// returns that verdict. A backend over its ceiling fails the test only
/// once every backend has been measured, so one slow backend does not
/// hide the others' numbers.
fn judged(job: []const u8, backend: lookout.Backend, budget_ms: anytype, kept: bool) bool {
    row(job, backend, "budget", budget_ms, "ms");
    row(job, backend, "within_budget", @intFromBool(kept), "bool");
    return kept;
}

fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    return .now(io, .awake);
}
