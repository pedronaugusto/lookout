//! The watcher on a reactor runtime, where every wait a backend makes is
//! the runtime's own: a readiness operation of the task's loop that holds
//! no thread and that a cancellation ends.
//!
//! The suite proper runs on std's `Io.Threaded`, where the same waits take
//! reactor's fallback path. These hold the runtime path to the claims that
//! differ: a poll is woken, canceled and fed while its task is parked, and
//! none of it went to the fallback.

const std = @import("std");
const reactor = @import("reactor");
const lookout = @import("../lookout.zig");
const timeout = @import("timeout.zig");

const Watcher = lookout.Watcher;
const ms = timeout.ms;
const backends = timeout.backends;

/// A runtime with no thread of its own: the test's thread is the home
/// thread, and runs the task that polls whenever it waits in the `Io`.
const options: reactor.Runtime.Options = .{
    .workers = 0,
    .offload = .none,
    .stack_size = .fromRaw(4 << 20),
    .max_tasks = 64,
};

/// Builds and starts a runtime, or skips where this system has no evented
/// backend for it.
fn start(runtime: *reactor.Runtime) !void {
    runtime.init(std.testing.allocator, options) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    errdefer runtime.deinit();
    try runtime.start();
}

/// Sleeps `millis` on the test I/O from a thread the test started, which
/// nothing cancels.
fn nap(millis: i64) void {
    std.testing.io.sleep(.fromMilliseconds(millis), .awake) catch |err| switch (err) {
        error.Canceled => {},
    };
}

/// A watched temporary directory on a runtime's `Io`.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    watcher: Watcher,

    fn init(io: std.Io, backend: lookout.Backend) !Fixture {
        const gpa = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
        errdefer gpa.free(root);
        var watcher: Watcher = try .init(gpa, io, .{ .backend = backend, .poll_interval = .fromMilliseconds(20) });
        errdefer watcher.deinit(io);
        _ = try watcher.add(io, root, .{});
        return .{ .tmp = tmp, .root = root, .watcher = watcher };
    }

    fn deinit(f: *Fixture, io: std.Io) void {
        f.watcher.deinit(io);
        std.testing.allocator.free(f.root);
        f.tmp.cleanup();
        f.* = undefined;
    }
};

fn pollOnce(io: std.Io, watcher: *Watcher) Watcher.PollError!usize {
    return (try watcher.poll(io, .none)).len;
}

test "a poll parked on a runtime is fed by a change made on another thread" {
    for (backends) |backend| {
        var runtime: reactor.Runtime = undefined;
        try start(&runtime);
        defer runtime.deinit();
        const io = runtime.io();
        var f = try Fixture.init(io, backend);
        defer f.deinit(io);

        const Writer = struct {
            dir: std.Io.Dir,
            failed: ?std.Io.Dir.WriteFileError = null,

            const Self = @This();

            fn run(writer: *Self) void {
                nap(100);
                writer.dir.writeFile(std.testing.io, .{ .sub_path = "fed.txt", .data = "x" }) catch |err| {
                    writer.failed = err;
                };
            }
        };
        const before = reactor.fallbacks();
        var writer: Writer = .{ .dir = f.tmp.dir };
        const thread = try std.Thread.spawn(.{}, Writer.run, .{&writer});
        defer {
            thread.join();
        }

        var seen = false;
        const deadline = std.Io.Timeout.toDeadline(ms(5_000), io);
        while (!seen) {
            for (try f.watcher.poll(io, deadline)) |event| {
                if (std.mem.endsWith(u8, event.path, "fed.txt")) seen = true;
            }
            if (!seen and deadline.toDurationFromNow(io).?.raw.nanoseconds <= 0) break;
        }
        try std.testing.expect(seen);
        if (writer.failed) |err| return err;
        // Every wait was the runtime's own.
        try std.testing.expectEqual(before, reactor.fallbacks());
    }
}

test "a poll parked on a runtime is canceled while it waits" {
    for (backends) |backend| {
        // A completion port is waited on by a call nothing can interrupt.
        if (backend == .windows) continue;
        var runtime: reactor.Runtime = undefined;
        try start(&runtime);
        defer runtime.deinit();
        const io = runtime.io();
        var f = try Fixture.init(io, backend);
        defer f.deinit(io);

        const before = reactor.fallbacks();
        var future = try io.concurrent(pollOnce, .{ io, &f.watcher });
        try io.sleep(.fromMilliseconds(30), .awake);
        try std.testing.expectError(error.Canceled, future.cancel(io));
        try std.testing.expectEqual(before, reactor.fallbacks());

        // Nothing was lost to it: the watcher goes on.
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "after.txt", .data = "x" });
        var seen = false;
        const deadline = std.Io.Timeout.toDeadline(ms(5_000), io);
        while (!seen) {
            for (try f.watcher.poll(io, deadline)) |event| {
                if (std.mem.endsWith(u8, event.path, "after.txt")) seen = true;
            }
            if (!seen and deadline.toDurationFromNow(io).?.raw.nanoseconds <= 0) break;
        }
        try std.testing.expect(seen);
    }
}

test "a poll parked on a runtime is woken from another thread" {
    for (backends) |backend| {
        var runtime: reactor.Runtime = undefined;
        try start(&runtime);
        defer runtime.deinit();
        const io = runtime.io();
        var f = try Fixture.init(io, backend);
        defer f.deinit(io);

        const Waker = struct {
            fn run(watcher: *Watcher) void {
                nap(100);
                watcher.wake();
            }
        };
        const before = reactor.fallbacks();
        const thread = try std.Thread.spawn(.{}, Waker.run, .{&f.watcher});
        defer thread.join();
        try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(io, .none)).len);
        try std.testing.expectEqual(before, reactor.fallbacks());
    }
}
