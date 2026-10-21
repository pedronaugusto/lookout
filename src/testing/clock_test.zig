//! The watcher's history, on every backend: `clock`, `since` and `sync`
//! asked from one thread while another polls, as a program answering
//! git's file-monitor question asks them.

const std = @import("std");
const Io = std.Io;

const lookout = @import("../lookout.zig");
const shared = @import("timeout.zig");
const ms = shared.ms;
const Watcher = lookout.Watcher;

/// The thread that owns the watcher while the test asks it questions:
/// polls until told to stop, and notes any of `sync`'s files it is handed.
const Poller = struct {
    watcher: *Watcher,
    stopping: std.atomic.Value(bool) = .init(false),
    leaked: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(p: *Poller) void {
        const io = std.testing.io;
        while (!p.stopping.load(.acquire)) {
            const events = p.watcher.poll(io, .none) catch {
                p.failed.store(true, .release);
                return;
            };
            for (events) |event| {
                if (std.mem.find(u8, event.path, ".lookout-sync-") != null) p.leaked.store(true, .release);
            }
        }
    }

    fn stop(p: *Poller, thread: std.Thread) void {
        p.stopping.store(true, .release);
        p.watcher.wake();
        thread.join();
    }
};

fn holds(changes: lookout.Changes, wanted: []const u8) bool {
    for (changes.paths) |c| if (std.mem.eql(u8, c.path, wanted)) return true;
    return false;
}

test "since answers what changed after a clock, and sync makes it reach a write just made" {
    const testing = std.testing;
    const io = testing.io;
    const gpa = testing.allocator;
    for (shared.backends) |backend| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "sub");
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);
        var watcher = try Watcher.init(gpa, io, .{
            .backend = backend,
            .history = 1000,
            .latency = .fromMilliseconds(5),
            .poll_interval = .fromMilliseconds(20),
        });
        defer watcher.deinit(io);
        const id = try watcher.add(io, root, .{ .recursive = true });
        while ((try watcher.poll(io, ms(100))).len != 0) {}
        const start = watcher.clock(io).?;

        var poller: Poller = .{ .watcher = &watcher };
        const thread = try std.Thread.spawn(.{}, Poller.run, .{&poller});
        var stopped = false;
        defer if (!stopped) poller.stop(thread);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        try tmp.dir.writeFile(io, .{ .sub_path = "sub/a.txt", .data = "a" });
        try watcher.sync(io, root, ms(10_000));
        const first = (try watcher.since(io, arena, id, start)).?;
        const a = try Io.Dir.path.join(arena, &.{ root, "sub", "a.txt" });
        try testing.expect(holds(first, a));

        try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b" });
        try watcher.sync(io, root, ms(10_000));
        const second = (try watcher.since(io, arena, id, first.clock)).?;
        const b = try Io.Dir.path.join(arena, &.{ root, "b.txt" });
        try testing.expect(holds(second, b));
        try testing.expect(!holds(second, a));
        // The earlier clock still answers for both.
        const both = (try watcher.since(io, arena, id, start)).?;
        try testing.expect(holds(both, a) and holds(both, b));

        // A sync into a directory no watch reports gives up.
        var outside = testing.tmpDir(.{});
        defer outside.cleanup();
        const elsewhere = try outside.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(elsewhere);
        try testing.expectError(error.SyncTimeout, watcher.sync(io, elsewhere, ms(50)));

        poller.stop(thread);
        stopped = true;
        try testing.expect(!poller.failed.load(.acquire));
        try testing.expect(!poller.leaked.load(.acquire));
        for (both.paths) |c| try testing.expect(std.mem.find(u8, c.path, ".lookout-sync-") == null);
    }
}

test "a sync no poll answers times out and leaves no file behind" {
    const testing = std.testing;
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var watcher = try Watcher.init(gpa, io, .{ .history = 10 });
    defer watcher.deinit(io);
    _ = try watcher.add(io, root, .{});
    try testing.expectError(error.SyncTimeout, watcher.sync(io, root, ms(20)));
    var it = tmp.dir.iterate();
    try testing.expect(try it.next(io) == null);
    try testing.expectError(error.RelativePath, watcher.sync(io, "relative", ms(20)));
    // What the timed-out sync wrote and removed is never handed out.
    while (true) {
        const events = try watcher.poll(io, ms(200));
        if (events.len == 0) break;
        for (events) |event| try testing.expect(std.mem.find(u8, event.path, ".lookout-sync-") == null);
    }
}

test "a watcher without a history has no clock and answers nothing" {
    const testing = std.testing;
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var watcher = try Watcher.init(gpa, io, .{});
    defer watcher.deinit(io);
    const id = try watcher.add(io, root, .{});
    try testing.expect(watcher.clock(io) == null);
    try testing.expect(try watcher.since(io, gpa, id, .{ .epoch = 0, .tick = 0 }) == null);
    try testing.expectError(error.NoHistory, watcher.sync(io, root, ms(20)));
}
