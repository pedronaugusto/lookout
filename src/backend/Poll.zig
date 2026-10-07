//! The portable backend: re-stat and re-list the watched paths on a timer.
//!
//! It needs nothing from the kernel, so it is the backend on every target
//! lookout has no notification mechanism for, and it is selectable
//! everywhere else, which is what lets one test suite hold every backend
//! to the same contract.
//!
//! The costs are the obvious ones: a change is seen up to
//! `@import("../options.zig").Options.poll_interval` after it happens, every watched
//! directory is listed and stat-ed on every tick, and a file created and
//! deleted between two ticks is never seen at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const lookout = @import("../types.zig");
const Batch = @import("../Batch.zig");
const Deadline = @import("../Deadline.zig");
const Tree = @import("../Tree.zig");
const Waker = @import("../Waker.zig");
const Options = @import("../options.zig").Options;
const AddOptions = @import("../options.zig").AddOptions;
const milliseconds = @import("../options.zig").milliseconds;
const contract = @import("../watch_contract.zig");
const Target = lookout.Target;
const WatchId = lookout.WatchId;

const Poll = @This();

gpa: Allocator,
interval_ms: u32,
tree: Tree,

/// The longest this backend sleeps without looking at the flag `wake`
/// sets. A wake is answered within this even when `poll_interval` is
/// minutes.
const slice_ms = 100;

/// Creates a backend that watches nothing. It holds no kernel resource
/// and allocates nothing, so its error set is empty: `lookout.Watcher.init`
/// still treats it as every other backend's init, and a watcher building
/// one beside its native backend needs no error path for it.
pub fn init(gpa: Allocator, options: Options) error{}!Poll {
    var tree: Tree = .init(gpa, options.max_dir_entries, false);
    tree.check_contents = true;
    return .{
        .gpa = gpa,
        .interval_ms = @max(1, milliseconds(options.poll_interval)),
        .tree = tree,
    };
}

test "a zero polling interval still sleeps between quiet scans" {
    const io = std.testing.io;
    var p = try Poll.init(std.testing.allocator, .{ .poll_interval = .fromMilliseconds(0) });
    defer p.deinit(io);
    try std.testing.expectEqual(@as(u32, 1), p.interval_ms);
}

const shakedown = @import("shakedown");

test "polling racy entries compare bytes even when size and timestamps match" {
    const testing = std.testing;
    const gpa = testing.allocator;
    // Files whose stat holds both timestamps fixed across positional
    // writes, as a coarse filesystem tick does.
    const Stamped = struct {
        mtime_ns: i96,
        ctime_ns: i96,

        const L = shakedown.Layer(@This(), .{ .dirStatFile = stat });

        fn stat(userdata: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
            const l = L.of(userdata);
            var result = try dir.statFile(l.base, path, options);
            if (result.kind == .file) {
                result.mtime.nanoseconds = l.state.mtime_ns;
                result.ctime.nanoseconds = l.state.ctime_ns;
            }
            return result;
        }
    };
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "nested", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const nested = try tmp.dir.realPathFileAlloc(io, "nested", gpa);
    defer gpa.free(nested);
    const file_path = try std.Io.Dir.path.join(gpa, &.{ root, "nested", "file" });
    defer gpa.free(file_path);

    // The clock is in the same two-second filesystem tick as the stamps,
    // then crosses its edge.
    for ([_]bool{ false, true }) |ctime_only| {
        for (0..3) |scope| {
            var clock: shakedown.Clock = .init(io, .{ .real = .fromNanoseconds(3 * std.time.ns_per_s + 500 * std.time.ns_per_ms) });
            var stamped: Stamped.L = .init(clock.io(), .{
                .mtime_ns = if (ctime_only) 0 else 2 * std.time.ns_per_s,
                .ctime_ns = if (ctime_only) 2 * std.time.ns_per_s else 0,
            });
            const timed = stamped.io();
            try tmp.dir.writeFile(io, .{ .sub_path = "nested/file", .data = "one" });
            var p = try Poll.init(gpa, .{});
            defer p.deinit(timed);
            var batch: Batch = .init(.{});
            defer batch.deinit(gpa);
            const watch_path = if (scope == 2) file_path else if (scope == 1) root else nested;
            try p.add(timed, @fromBackingInt(@intCast(0)), watch_path, .{ .recursive = scope == 1 }, &batch);
            try p.scan(timed, &batch);
            try testing.expectEqual(@as(usize, 0), batch.events.items.len);

            const file = try tmp.dir.openFile(io, "nested/file", .{ .mode = .read_write });
            defer file.close(io);
            for ([_][]const u8{ "two", "six", "ten" }, 0..) |bytes, index| {
                batch.reset(gpa);
                try file.writePositionalAll(io, bytes, 0);
                // A racy baseline must still compare content on the scan
                // where the timestamps first become strictly older.
                if (index == 2) clock.advance(.fromMilliseconds(500));
                try p.scan(timed, &batch);
                try testing.expectEqual(@as(usize, 1), batch.events.items.len);
                try testing.expectEqual(lookout.Kind.modified, batch.events.items[0].kind);
                try testing.expectEqualStrings(file_path, batch.events.items[0].path);
            }
            batch.reset(gpa);
            try p.scan(timed, &batch);
            try testing.expectEqual(@as(usize, 0), batch.events.items.len);
        }
    }
}

/// Releases the watch tables and the directory handles they hold open.
pub fn deinit(p: *Poll, io: Io) void {
    p.tree.deinit(io);
    p.* = undefined;
}

/// No descriptor: this backend has nothing to wait on, so a program
/// cannot fold it into a wait loop of its own and must call
/// `lookout.Watcher.poll`.
pub fn fd(p: *const Poll) ?std.posix.fd_t {
    _ = p;
    return null;
}

/// Nothing to poke: there is nothing to interrupt here, only a sleep to
/// cut short, and `wait` reads the flag `lookout.Watcher.wake` sets
/// between the slices it sleeps in. That flag lives in the watcher rather
/// than here because this struct is what the polling thread writes, and
/// a thread that wakes it must not touch it. See `Waker`.
pub fn waker(p: *const Poll) Waker {
    _ = p;
    return .none;
}

/// How many paths this backend re-lists or re-stats on every tick. See
/// `lookout.Watcher.Stats`.
pub fn registrationCount(p: *const Poll) usize {
    return p.tree.nodes.count();
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(
    p: *Poll,
    io: Io,
    id: WatchId,
    abs_path: []const u8,
    options: AddOptions,
    batch: *Batch,
) contract.AddError!void {
    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(p.gpa);
    try p.tree.addWatch(io, id, abs_path, options, &added, batch);
}

/// Stops watching `id`.
pub fn remove(p: *Poll, io: Io, id: WatchId) void {
    p.tree.removeWatch(io, id);
}

/// Changes a watch's filter while retaining its root and snapshots.
pub fn refilter(p: *Poll, io: Io, id: WatchId, filter: lookout.Filter, batch: *Batch) contract.RefilterError!void {
    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(p.gpa);
    try p.tree.refilter(io, id, filter, &added, batch);
}

/// Scans, then sleeps and scans again until the scan produces an event
/// `batch` did not already hold, `woken` is set, or `timeout_ms` expires.
/// `null` never gives up.
///
/// `woken` is `lookout.Watcher`'s own flag, and it is only read here:
/// clearing it is the watcher's, which answers the wake.
pub fn wait(
    p: *Poll,
    io: Io,
    batch: *Batch,
    timeout_ms: ?u32,
    woken: *const std.atomic.Value(bool),
) contract.PollError!void {
    const before = batch.revision;
    const deadline: Deadline = .fromMs(io, timeout_ms);

    while (true) {
        try p.scan(io, batch);
        if (batch.revision != before) return;
        if (woken.load(.acquire)) return;

        var napped: u32 = 0;
        const nap_ms = nap: {
            const remaining = deadline.remainingMs(io) orelse break :nap p.interval_ms;
            if (remaining == 0) return;
            break :nap @min(p.interval_ms, remaining);
        };
        // Slept in slices so that `wake` is answered without waiting out
        // a whole tick, which on a long interval is a long time.
        while (napped < nap_ms) {
            const slice = @min(slice_ms, nap_ms - napped);
            try io.sleep(.fromMilliseconds(slice), .awake);
            napped += slice;
            if (woken.load(.acquire)) break;
        }
    }
}

/// Re-examines every watched path once.
///
/// Under cancel protection: a scan compares every directory with what it
/// held before and records the difference, and one stopped half way would
/// have taken some of the differences and not reported them. The sleep
/// between scans is where a cancellation ends this backend's wait; see
/// `Watcher.poll`.
pub fn scan(p: *Poll, io: Io, batch: *Batch) Tree.ScanError!void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    try p.checkRoots(io, batch);

    // The node list is copied first: a scan can both add nodes, when a
    // recursive watch sees a new subdirectory, and drop them, when a
    // watched directory disappears.
    var ids: std.ArrayList(Tree.NodeId) = .empty;
    defer ids.deinit(p.gpa);
    try ids.appendSlice(p.gpa, p.tree.nodes.keys());

    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(p.gpa);

    for (ids.items) |id| {
        const role = (p.tree.nodes.get(id) orelse continue).role;
        switch (role) {
            .directory => try p.tree.rescanDirectory(io, id, batch, &added),
            .file => try p.tree.rescanFile(io, id, batch),
        }
    }
}

/// Reports a watch root that is no longer there, and stops watching
/// below it.
///
/// A directory node is listed through the handle opened for it, and on
/// POSIX that handle outlives the name: the listing of a deleted
/// directory still succeeds and still says nothing changed, so the one
/// disappearance the comparison cannot see is the watch's own. The name
/// is what the caller asked for, so the name is what is checked -- one
/// `stat` per watch per tick, which is nothing beside the listing the
/// tick is already doing.
///
/// A move is reported as `lookout.Kind.removed` rather than
/// `lookout.Kind.renamed`, because a comparison of names cannot tell the
/// two apart. See `lookout.reportsRootMove`.
fn checkRoots(p: *Poll, io: Io, batch: *Batch) Tree.ScanError!void {
    const Gone = struct { id: WatchId, path: []u8, target: Target };
    var gone: std.ArrayList(Gone) = .empty;
    defer {
        for (gone.items) |item| p.gpa.free(item.path);
        gone.deinit(p.gpa);
    }

    for (p.tree.watches.keys(), p.tree.watches.values()) |id, watch| {
        // Only a watch that still has nodes: one already reported gone
        // keeps its id, and must not be reported twice.
        if (!p.hasNodes(id)) continue;
        _ = Io.Dir.cwd().statFile(io, watch.root, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                const owned = try p.gpa.dupe(u8, watch.root);
                errdefer p.gpa.free(owned);
                try gone.append(p.gpa, .{
                    .id = id,
                    .path = owned,
                    .target = watch.target,
                });
                continue;
            },
            else => return err,
        };
    }

    for (gone.items) |item| {
        try batch.push(p.gpa, io, item.id, item.path, .removed, item.target);
        p.tree.removeSubtree(io, item.id, item.path);
    }
}

/// Whether any node of `id` is still registered: its root's, without
/// which it has none. One lookup, not a pass over every node per watch.
fn hasNodes(p: *const Poll, id: WatchId) bool {
    return p.tree.hasNode(id, p.tree.watchRoot(id));
}

test "a failed polling removal allocation releases its staged path" {
    const io = std.testing.io;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "gone", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, "gone", testing.allocator);
    defer testing.allocator.free(root);
    var poll = try Poll.init(testing.allocator, .{});
    defer poll.deinit(io);
    var batch: Batch = .init(.{});
    defer batch.deinit(testing.allocator);
    try poll.add(io, @fromBackingInt(@intCast(0)), root, .{}, &batch);
    try tmp.dir.deleteFile(testing.io, "gone");

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    poll.gpa = failing.allocator();
    try testing.expectError(error.OutOfMemory, poll.checkRoots(io, &batch));
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try testing.expectEqual(@as(usize, 0), batch.events.items.len);
    try testing.expectEqual(@as(usize, 1), poll.registrationCount());
    poll.gpa = testing.allocator;
    try poll.checkRoots(io, &batch);
    try testing.expectEqual(@as(usize, 1), batch.events.items.len);
    try testing.expectEqual(lookout.Kind.removed, batch.events.items[0].kind);
    try testing.expectEqual(@as(usize, 0), poll.registrationCount());
}
