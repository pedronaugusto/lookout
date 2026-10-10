//! lookout's speed claims, each held to its ceiling on every backend this
//! target was built with. `zig build bench` runs them in ReleaseFast; run it
//! on a quiet machine. A claim over its ceiling fails the run, once every
//! claim has been measured, so one slow backend does not hide the others'
//! numbers. `--smoke`, which `zig build test` runs, makes each claim once
//! and judges none.
//!
//! Each row is `lookout <job>_<backend> <measure> <value> <unit>`,
//! tab-separated on standard output.

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

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var claims: Claims = .{ .io = init.io, .gpa = init.gpa, .smoke = false };
    for (args[1..]) |arg| {
        if (!std.mem.eql(u8, arg, "--smoke")) return error.UnknownArgument;
        claims.smoke = true;
    }
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &stdout_buffer);
    claims.out = &stdout.interface;
    var kept = true;
    inline for (.{ Claims.blockedChange, Claims.renameThenDelete, Claims.cancelBeforePoll, Claims.wakeFromThread, Claims.stopByFlag }) |claim| {
        for (backends) |backend| kept = try claim(&claims, backend) and kept;
    }
    try stdout.interface.flush();
    if (!kept) return error.OverBudget;
}

const Claims = struct {
    io: Io,
    gpa: std.mem.Allocator,
    /// Each claim once, judged against no ceiling.
    smoke: bool,
    out: *Io.Writer = undefined,

    /// The longest a backend may take to come back with a change that
    /// happened while `poll` was already blocked, in milliseconds.
    fn wakeBudgetMs(backend: lookout.Backend, interval_ms: u32) u32 {
        return switch (backend) {
            .poll => interval_ms + 500,
            else => 500,
        };
    }

    /// A change that happens while poll is blocked comes back promptly.
    fn blockedChange(c: *Claims, backend: lookout.Backend) !bool {
        const io = c.io;
        const rounds: usize = if (c.smoke) 1 else 5;
        const interval_ms = 200;
        var f = try Fixture.init(c, .{
            .backend = backend,
            .poll_interval = .fromMilliseconds(interval_ms),
            // The wait being measured is the backend's, not the
            // coalescing tail's.
            .latency = .zero,
        });
        defer f.deinit();
        _ = try f.watcher.add(io, f.root, .{});
        try f.settle();

        const Toucher = struct {
            io: Io,
            dir: Io.Dir,
            round: usize = 0,
            stamped: Io.Timestamp = .zero,

            fn run(self: *@This()) void {
                // Long enough that the main thread is certainly blocked
                // in the backend's wait rather than on its way there.
                self.io.sleep(.fromMilliseconds(150), .awake) catch return;
                var name: [32]u8 = undefined;
                self.stamped = .now(self.io, .awake);
                self.dir.writeFile(self.io, .{
                    // unreachable: "w" and a usize's digits fit in 32 bytes
                    .sub_path = std.mem.print(&name, "w{d}.txt", .{self.round}) catch unreachable,
                    .data = "x",
                }) catch {};
            }
        };

        var worst: i64 = 0;
        for (0..rounds) |round| {
            var toucher: Toucher = .{ .io = io, .dir = f.dir, .round = round };
            const thread = try std.Thread.spawn(.{}, Toucher.run, .{&toucher});
            var seen: ?Io.Timestamp = null;
            while (seen == null) {
                const events = try f.watcher.poll(io, within(5_000));
                if (events.len == 0) break;
                for (events) |event| {
                    if (event.kind == .created) seen = .now(io, .awake);
                }
            }
            thread.join();
            const arrived = seen orelse return error.EventNotObserved;
            worst = @max(worst, toucher.stamped.durationTo(arrived).toMilliseconds());
        }
        try c.metric("blocked_change", backend, worst);
        const budget = wakeBudgetMs(backend, interval_ms);
        return c.judged("blocked_change", backend, budget, worst <= budget);
    }

    /// A file saved by a rename and then deleted is reported gone at once,
    /// in a long wait. An editor saves by writing a new file and renaming it
    /// over the old one; the file is later deleted. FSEvents keeps a path's
    /// flags, so the deletion arrives as a rename half with no partner,
    /// which is held for one. A wait with no deadline of its own must still
    /// decide it within the pairing grace, not when the next unrelated
    /// change comes.
    fn renameThenDelete(c: *Claims, backend: lookout.Backend) !bool {
        const io = c.io;
        var f = try Fixture.init(c, .{ .backend = backend, .poll_interval = .fromMilliseconds(20) });
        defer f.deinit();
        try f.write("next.md", "one");
        _ = try f.watcher.add(io, f.root, .{ .recursive = true });
        try f.settle();

        try f.write("next.new", "two");
        try f.dir.rename("next.new", f.dir, "next.md", io);
        try f.settle();

        try f.dir.deleteFile(io, "next.md");
        const gone = try std.Io.Dir.path.join(c.gpa, &.{ f.root, "next.md" });
        defer c.gpa.free(gone);
        const started: Io.Timestamp = .now(io, .awake);
        var seen = false;
        while (!seen) {
            const events = try f.watcher.poll(io, within(timeout_ms));
            if (events.len == 0) break;
            for (events) |event| {
                if (std.mem.eql(u8, event.path, gone) and (event.kind == .removed or event.kind == .renamed)) seen = true;
            }
        }
        if (!seen) return error.EventNotObserved;
        const waited_ms = started.durationTo(.now(io, .awake)).toMilliseconds();
        try c.metric("rename_then_delete", backend, waited_ms);
        return c.judged("rename_then_delete", backend, timeout_ms / 2, waited_ms < timeout_ms / 2);
    }

    /// A cancellation requested before poll is reported at once.
    fn cancelBeforePoll(c: *Claims, backend: lookout.Backend) !bool {
        const io = c.io;
        var f = try Fixture.init(c, .{ .backend = backend, .poll_interval = .fromMilliseconds(20) });
        defer f.deinit();
        _ = try f.watcher.add(io, f.root, .{});
        try f.settle();

        const Task = struct {
            io: Io,
            watcher: *Watcher,
            go: std.atomic.Value(bool) = .init(false),

            fn run(self: *@This()) Watcher.PollError![]const lookout.Event {
                while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
                return self.watcher.poll(self.io, within(timeout_ms));
            }

            /// Lets the task go from another thread, after 50 ms.
            fn release(self: *@This()) void {
                self.io.sleep(.fromMilliseconds(50), .awake) catch {};
                self.go.store(true, .release);
            }
        };
        var task: Task = .{ .io = io, .watcher = &f.watcher };
        var future = io.concurrent(Task.run, .{&task}) catch |err| switch (err) {
            // No second task to cancel: there is nothing to claim.
            error.ConcurrencyUnavailable => return true,
        };
        const thread = try std.Thread.spawn(.{}, Task.release, .{&task});
        defer thread.join();

        // The cancellation lands while the task is not in `std.Io` at
        // all. Nothing will happen to the tree, so a poll that did not
        // look for it before waiting would wait out its whole timeout,
        // and on a kernel backend would not be told about it even then.
        const started: Io.Timestamp = .now(io, .awake);
        if (future.cancel(io)) |_| return error.NotCanceled else |err| switch (err) {
            error.Canceled => {},
            else => |e| return e,
        }
        const elapsed = started.durationTo(.now(io, .awake)).toMilliseconds();
        try c.metric("cancel_before_poll", backend, elapsed);
        return c.judged("cancel_before_poll", backend, timeout_ms / 2, elapsed < timeout_ms / 2);
    }

    /// A watcher can be woken from another thread.
    fn wakeFromThread(c: *Claims, backend: lookout.Backend) !bool {
        const io = c.io;
        var f = try Fixture.init(c, .{ .backend = backend, .poll_interval = .fromMilliseconds(20) });
        defer f.deinit();
        _ = try f.watcher.add(io, f.root, .{});
        try f.settle();

        const Waker = struct {
            io: Io,
            watcher: *Watcher,
            fn run(self: *@This()) void {
                self.io.sleep(.fromMilliseconds(100), .awake) catch {};
                self.watcher.wake();
            }
        };
        var waker: Waker = .{ .io = io, .watcher = &f.watcher };
        const thread = try std.Thread.spawn(.{}, Waker.run, .{&waker});
        defer thread.join();

        // Nothing is going to happen to the tree, so without the wake
        // this blocks for as long as the caller is prepared to wait --
        // and with `.none`, forever.
        const started: Io.Timestamp = .now(io, .awake);
        const events = try f.watcher.poll(io, .none);
        const elapsed = started.durationTo(.now(io, .awake)).toMilliseconds();
        if (events.len != 0) {
            for (events) |event| try c.out.print("wake {s}: unexpected {s} {s}\n", .{ @tagName(backend), @tagName(event.kind), event.path });
            try c.out.flush();
            return error.UnexpectedEvents;
        }
        try c.metric("wake", backend, elapsed);
        return c.judged("wake", backend, timeout_ms, elapsed < timeout_ms);
    }

    /// A polling task is stopped by a flag and a wake on every backend: the
    /// recipe `Watcher.wake` gives, as written there.
    fn stopByFlag(c: *Claims, backend: lookout.Backend) !bool {
        const io = c.io;
        var f = try Fixture.init(c, .{ .backend = backend, .poll_interval = .fromMilliseconds(20) });
        defer f.deinit();
        _ = try f.watcher.add(io, f.root, .{});
        try f.settle();

        const Task = struct {
            io: Io,
            watcher: *Watcher,
            stopping: std.atomic.Value(bool) = .init(false),
            polls: usize = 0,

            fn run(self: *@This()) Watcher.PollError!void {
                while (!self.stopping.load(.acquire)) {
                    _ = try self.watcher.poll(self.io, .none);
                    self.polls += 1;
                }
            }
        };
        var task: Task = .{ .io = io, .watcher = &f.watcher };
        var future = io.concurrent(Task.run, .{&task}) catch |err| switch (err) {
            // No second task to stop: there is nothing to claim.
            error.ConcurrencyUnavailable => return true,
        };
        io.sleep(.fromMilliseconds(50), .awake) catch {};

        const started: Io.Timestamp = .now(io, .awake);
        task.stopping.store(true, .release);
        f.watcher.wake();
        try future.await(io);
        const elapsed = started.durationTo(.now(io, .awake)).toMilliseconds();
        try c.metric("stop_by_flag", backend, elapsed);
        return c.judged("stop_by_flag", backend, timeout_ms, elapsed < timeout_ms);
    }

    fn row(c: *Claims, job: []const u8, backend: lookout.Backend, measure: []const u8, value: anytype, unit: []const u8) !void {
        try c.out.print("lookout\t{s}_{s}\t{s}\t{d}\t{s}\n", .{ job, @tagName(backend), measure, value, unit });
        try c.out.flush();
    }

    fn metric(c: *Claims, job: []const u8, backend: lookout.Backend, milliseconds: anytype) !void {
        try c.row(job, backend, "elapsed", milliseconds, "ms");
    }

    /// Reports a speed ceiling and whether the measurement kept to it, and
    /// returns that verdict; under `--smoke` nothing is judged.
    fn judged(c: *Claims, job: []const u8, backend: lookout.Backend, budget_ms: anytype, kept: bool) !bool {
        if (c.smoke) return true;
        try c.row(job, backend, "budget", budget_ms, "ms");
        try c.row(job, backend, "within_budget", @intFromBool(kept), "bool");
        return kept;
    }
};

/// A watcher over a fresh directory in the working directory.
const Fixture = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: Io.Dir,
    root: [:0]u8,
    watcher: Watcher,
    name: []u8,

    fn init(c: *Claims, options: Watcher.Options) !Fixture {
        const cwd = Io.Dir.cwd();
        // A delayed native record from a previous fixture must not name
        // the tree whose idle wake is being measured now.
        const name = try std.fmt.allocPrint(c.gpa, "fixture-{d}", .{Io.Clock.awake.now(c.io).nanoseconds});
        errdefer c.gpa.free(name);
        var dir = try cwd.createDirPathOpen(c.io, name, .{ .open_options = .{ .iterate = true } });
        errdefer dir.close(c.io);
        const root = try dir.realPathFileAlloc(c.io, ".", c.gpa);
        errdefer c.gpa.free(root);
        return .{ .io = c.io, .gpa = c.gpa, .dir = dir, .root = root, .watcher = try Watcher.init(c.gpa, c.io, options), .name = name };
    }

    fn deinit(f: *Fixture) void {
        f.watcher.deinit(f.io);
        f.gpa.free(f.root);
        f.dir.close(f.io);
        Io.Dir.cwd().deleteTree(f.io, f.name) catch {};
        f.gpa.free(f.name);
    }

    fn write(f: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try f.dir.writeFile(f.io, .{ .sub_path = sub_path, .data = data });
    }

    fn settle(f: *Fixture) !void {
        while ((try f.watcher.poll(f.io, within(200))).len != 0) {}
    }
};
