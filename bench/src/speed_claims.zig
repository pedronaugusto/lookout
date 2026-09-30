//! Speed claims from the unit suite. Run only on a quiet machine.

const std = @import("std");
const lookout = @import("lookout");
const Watcher = lookout.Watcher;

/// Every backend this target was built with.
const backends: []const lookout.Backend = all: {
    const names = @typeInfo(lookout.Backend).@"enum".fields;
    var list: [names.len]lookout.Backend = undefined;
    var len: usize = 0;
    for (names) |field| {
        const backend: lookout.Backend = @enumFromInt(field.value);
        if (backend == .auto or !lookout.supported(backend)) continue;
        list[len] = backend;
        len += 1;
    }
    const final = list[0..len].*;
    break :all &final;
};

const timeout_ms = 5_000;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    watcher: Watcher,

    fn init(backend: lookout.Backend) !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        errdefer std.testing.allocator.free(root);
        return .{ .tmp = tmp, .root = root, .watcher = try Watcher.init(std.testing.allocator, std.testing.io, .{ .backend = backend, .poll_interval_ms = 20 }) };
    }
    fn deinit(f: *Fixture) void {
        f.watcher.deinit();
        std.testing.allocator.free(f.root);
        f.tmp.cleanup();
    }
    fn write(f: *Fixture, name: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
    }
    fn settle(f: *Fixture) !void {
        while ((try f.watcher.poll(200)).len != 0) {}
    }
    fn path(f: *Fixture, name: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ f.root, name });
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
    return self.watcher.poll(timeout_ms);
}

/// The longest a backend may take to come back with a change that
/// happened while `poll` was already blocked, in milliseconds.
///
/// Measured: FSEvents 11.4 ms, `kqueue` 0.2 ms, polling one tick. The
/// FSEvents floor is its own coalescing window and cannot be lowered.
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

    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = backend,
            .poll_interval_ms = interval_ms,
            // The wait being measured is the backend's, not the
            // coalescing tail's.
            .latency_ms = 0,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{});
        while ((try watcher.poll(200)).len != 0) {}

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
                self.stamped = .now(w_io, .awake);
                self.dir.writeFile(w_io, .{
                    .sub_path = std.fmt.bufPrint(&name, "w{d}.txt", .{self.round}) catch unreachable,
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
                const events = try watcher.poll(5_000);
                if (events.len == 0) break;
                for (events) |event| {
                    if (event.kind == .created) seen = .now(io, .awake);
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
        try std.testing.expect(worst <= budget);
    }
}

test "quiet: a file saved by a rename and then deleted is reported gone at once, in a long wait" {
    // An editor saves by writing a new file and renaming it over the old
    // one; the file is later deleted. FSEvents keeps a path's flags, so the
    // deletion arrives as a rename half with no partner, which is held for
    // one. A wait with no deadline of its own must still decide it within
    // the pairing grace, not when the next unrelated change comes.
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("next.md", "one");
        _ = try f.watcher.add(f.root, .{ .recursive = true });
        try f.settle();

        try f.write("next.new", "two");
        try f.tmp.dir.rename("next.new", f.tmp.dir, "next.md", std.testing.io);
        try f.settle();

        try f.tmp.dir.deleteFile(std.testing.io, "next.md");
        const gone = try f.path("next.md");
        defer std.testing.allocator.free(gone);
        const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
        var seen = false;
        while (!seen) {
            const events = try f.watcher.poll(timeout_ms);
            if (events.len == 0) break;
            for (events) |event| {
                if (std.mem.eql(u8, event.path, gone) and (event.kind == .removed or event.kind == .renamed)) seen = true;
            }
        }
        const waited_ms = @divTrunc(started.untilNow(std.testing.io).raw.nanoseconds, std.time.ns_per_ms);
        try std.testing.expect(seen);
        try std.testing.expect(waited_ms < timeout_ms / 2);
    }
}
test "quiet: a cancellation requested before poll is reported at once" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{});

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
        const started: std.Io.Timestamp = .now(std.testing.io, .awake);
        try std.testing.expectError(error.Canceled, future.cancel(std.testing.io));
        const elapsed = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake));
        try std.testing.expect(elapsed.toMilliseconds() < timeout_ms / 2);
    }
}
