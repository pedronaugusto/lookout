//! What a watcher costs, held to a budget.
//!
//! These are the three numbers a caller notices: how long after a change
//! `lookout.Watcher.poll` comes back, how much of a burst arrives, and
//! how much memory a watched directory costs. Each was measured once and
//! is asserted here against a budget several times the measurement, so
//! that a change which makes one of them worse says so rather than being
//! found later on somebody's machine.
//!
//! The budgets are deliberately loose. A hosted runner is a shared
//! machine and a tight budget on one is a test that fails for reasons
//! that have nothing to do with this package; what these catch is a
//! regression of the kind the buffer defect was -- an order of
//! magnitude, not a percentage.

const std = @import("std");
const builtin = @import("builtin");

const lookout = @import("lookout.zig");
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

/// An allocator that counts what is outstanding, so that "what a watched
/// directory costs" is a number and not an impression.
const Counting = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn take(c: *Counting, n: usize) void {
        c.live += n;
        if (c.live > c.peak) c.peak = c.live;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const out = c.child.rawAlloc(len, alignment, ra) orelse return null;
        c.take(len);
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (!c.child.rawResize(memory, alignment, new_len, ra)) return false;
        c.live -= memory.len;
        c.take(new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const out = c.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        c.live -= memory.len;
        c.take(new_len);
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.child.rawFree(memory, alignment, ra);
        c.live -= memory.len;
    }
};

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

test "a change that happens while poll is blocked comes back promptly" {
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

test "a burst arrives whole, or says what it lost" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const burst = 2_000;

    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 1_000_000,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{});

        for (0..burst) |i| {
            var name: [64]u8 = undefined;
            try tmp.dir.writeFile(io, .{
                .sub_path = std.fmt.bufPrint(&name, "a-name-long-enough-to-measure-{d}.txt", .{i}) catch unreachable,
                .data = "x",
            });
        }

        var created: usize = 0;
        var overflow: usize = 0;
        var idle: u32 = 0;
        while (idle < 1_000) {
            const events = try watcher.poll(200);
            if (events.len == 0) {
                idle += 200;
                continue;
            }
            idle = 0;
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
            try tmp.dir.createDirPath(io, std.fmt.bufPrint(&name, "d{d}", .{d}) catch unreachable);
            for (0..4) |i| {
                var entry: [48]u8 = undefined;
                try tmp.dir.writeFile(io, .{
                    .sub_path = std.fmt.bufPrint(&entry, "d{d}/f{d}.txt", .{ d, i }) catch unreachable,
                    .data = "x",
                });
            }
        }

        var counting: Counting = .{ .child = std.testing.allocator };
        {
            var watcher: Watcher = try .init(counting.allocator(), io, .{
                .backend = backend,
                .poll_interval_ms = 20,
                // The delivery buffer is one per watcher rather than one
                // per directory, so it is not what is being measured
                // here; the floor keeps it out of the number.
                .buffer_bytes = 4 * 1024,
            });
            defer watcher.deinit();
            _ = try watcher.add(root, .{ .recursive = true });

            const per_directory = counting.live / dirs;
            if (per_directory > directoryBudget(backend)) {
                std.debug.print("{s}: {d} B per directory, budget {d} B\n", .{
                    @tagName(backend), per_directory, directoryBudget(backend),
                });
            }
            try std.testing.expect(per_directory <= directoryBudget(backend));
        }
        // And all of it goes back, which is the other half of a budget.
        try std.testing.expectEqual(@as(usize, 0), counting.live);
    }
}
