//! Delivery completeness and allocator costs, counted without speed limits.
//! Poll timeouts bound a missing event; allocation budgets count bytes.

const std = @import("std");
const lookout = @import("../lookout.zig");
const ms = @import("timeout.zig").ms;
const shakedown = @import("shakedown");
const Watcher = lookout.Watcher;

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

test "poll reports each change from another thread" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const rounds = 5;
    const interval_ms = 200;

    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, .{
            .backend = backend,
            .poll_interval = .fromMilliseconds(interval_ms),
            // Collect the backend's delivery without a coalescing tail.
            .latency = .fromMilliseconds(0),
        });
        defer watcher.deinit(io);
        _ = try watcher.add(io, root, .{});
        while ((try watcher.poll(io, ms(200))).len != 0) {}

        const Toucher = struct {
            dir: std.Io.Dir,
            round: usize = 0,
            failed: ?std.Io.Dir.WriteFileError = null,

            const Self = @This();

            fn run(self: *Self) void {
                const w_io = std.testing.io;
                // The writer runs independently of the polling thread.
                w_io.sleep(.fromMilliseconds(150), .awake) catch return;
                var name: [32]u8 = undefined;
                self.dir.writeFile(w_io, .{
                    .sub_path = std.mem.print(&name, "w{d}.txt", .{self.round}) catch unreachable,
                    .data = "x",
                }) catch |err| {
                    self.failed = err;
                };
            }
        };

        var observed: usize = 0;
        for (0..rounds) |round| {
            var toucher: Toucher = .{ .dir = tmp.dir, .round = round };
            const thread = try std.Thread.spawn(.{}, Toucher.run, .{&toucher});
            var name: [32]u8 = undefined;
            const expected = try std.Io.Dir.path.join(gpa, &.{ root, try std.mem.print(&name, "w{d}.txt", .{round}) });
            defer gpa.free(expected);
            var seen = false;
            while (!seen) {
                const events = try watcher.poll(io, ms(5_000));
                if (events.len == 0) break;
                for (events) |event| {
                    if (event.kind == .created and std.mem.eql(u8, event.path, expected)) seen = true;
                }
            }
            thread.join();
            if (toucher.failed) |err| return err;
            try std.testing.expect(seen);
            observed += 1;
        }
        try std.testing.expectEqual(rounds, observed);
    }
}

test "a burst arrives whole, or says what it lost" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const burst = 2_000;

    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, .{
            .backend = backend,
            .poll_interval = .fromMilliseconds(20),
            .max_dir_entries = 1_000_000,
        });
        defer watcher.deinit(io);
        _ = try watcher.add(io, root, .{});

        for (0..burst) |i| {
            var name: [64]u8 = undefined;
            try tmp.dir.writeFile(io, .{
                .sub_path = std.mem.print(&name, "a-name-long-enough-to-measure-{d}.txt", .{i}) catch unreachable,
                .data = "x",
            });
        }

        // Waited for arrival, not for silence: on a machine whose event
        // daemon is busy elsewhere a burst can pause for more than a second
        // and still arrive whole, and a pause is not a loss. What decides
        // is the count, or an overflow, or the deadline -- and a burst that
        // is short at the deadline with no overflow is exactly the failure
        // this test exists to catch.
        var created: usize = 0;
        var overflow: usize = 0;
        var waited_ms: u32 = 0;
        while (created < burst and overflow == 0 and waited_ms < 30_000) {
            const events = try watcher.poll(io, ms(200));
            if (events.len == 0) waited_ms += 200;
            for (events) |event| switch (event.kind) {
                .created => created += 1,
                .overflow => overflow += 1,
                else => {},
            };
        }

        // The measurement that started this: 465 of 10 000, reported as
        // one overflow. The budget is that a burst either arrives or is
        // declared lost -- never quietly decimated.
        if (overflow != 0) continue;
        if (created != burst) {
            std.debug.print("{s}: {d}/{d} created with no overflow\n", .{
                @tagName(backend), created, burst,
            });
        }
        try std.testing.expectEqual(burst, created);
    }
}

/// The most a watched directory may cost, in bytes of the allocator
/// lookout was handed.
///
/// Measured over a thousand directories of four files: FSEvents 841 B
/// per directory, `kqueue` 2317 B, polling 956 B. The budgets are
/// several times that, because the shape of the tree moves the number
/// and a budget that tracks it would fail on a different tree.
fn directoryBudget(backend: lookout.Backend) usize {
    return switch (backend) {
        .kqueue => 8 * 1024,
        .inotify, .poll => 4 * 1024,
        else => 3 * 1024,
    };
}

test "a watched directory costs what it is budgeted" {
    const io = std.testing.io;
    const dirs = 200;

    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);

        for (0..dirs) |d| {
            var name: [32]u8 = undefined;
            try tmp.dir.createDirPath(io, std.mem.print(&name, "d{d}", .{d}) catch unreachable);
            for (0..4) |i| {
                var entry: [48]u8 = undefined;
                try tmp.dir.writeFile(io, .{
                    .sub_path = std.mem.print(&entry, "d{d}/f{d}.txt", .{ d, i }) catch unreachable,
                    .data = "x",
                });
            }
        }

        // Counts what is outstanding, so that "what a watched directory
        // costs" is a number and not an impression.
        var counting: shakedown.alloc.Counting = .init(std.testing.allocator);
        {
            var watcher: Watcher = try .init(counting.allocator(), .{
                .backend = backend,
                .poll_interval = .fromMilliseconds(20),
                // The delivery buffer is one per watcher rather than one
                // per directory, so it is not what is being measured
                // here; the floor keeps it out of the number.
                .buffer_bytes = .fromRaw(4 * 1024),
            });
            defer watcher.deinit(io);
            _ = try watcher.add(io, root, .{ .recursive = true });

            const per_directory = counting.live_bytes / dirs;
            if (per_directory > directoryBudget(backend)) {
                std.debug.print("{s}: {d} B per directory, budget {d} B\n", .{
                    @tagName(backend), per_directory, directoryBudget(backend),
                });
            }
            try std.testing.expect(per_directory <= directoryBudget(backend));
        }
        // And all of it goes back, which is the other half of a budget.
        try std.testing.expectEqual(@as(usize, 0), counting.live_bytes);
    }
}
