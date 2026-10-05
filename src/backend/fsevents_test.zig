//! Watcher integration scenarios for fsevents.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const lookout = @import("../lookout.zig");
const Batch = @import("../Batch.zig");
const Volume = @import("fsevents/volume.zig");
const checkpoint_format = @import("../Checkpoint/format.zig");
const Budget = @import("../Budget.zig");
const Deadline = @import("../Deadline.zig");
const Filter = @import("../Filter.zig");
const buffer = @import("../buffer.zig");
const path_cmp = @import("../path.zig");
const records = @import("fsevents/records.zig");
const trace = @import("../trace.zig");
const walk = @import("../walk.zig");
const Waker = @import("../Waker.zig");
const Record = records.Record;
const Target = lookout.Target;
const WatchId = lookout.WatchId;
const flag = records.flag;
const FsEvents = @import("fsevents.zig");

const bounds: buffer.Bounds = .{
    .min = 4 * 1024,
    .max = 64 * 1024 * 1024,
    .default = 4 * 1024 * 1024,
};
const grace_ms = 25;
const grace_rounds = 4;

const lost_track: u32 = flag.must_scan_sub_dirs | flag.user_dropped | flag.kernel_dropped;
pub const Held = struct {
    bytes: []u8,
    overflowed: bool,
};

const Asking = access.Asking;
const settled = access.settled;
const access = @import("fsevents.zig").test_access;
const Baseline = @import("../Baseline.zig");
const clock = @import("../testing/clock.zig");
const Checkpoint = @import("../Checkpoint.zig");
const c = access.c;
const synthesize = access.synthesize;

test "FSEvents access failures preserve known paths and report an incomplete answer" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const kept = try std.fs.path.join(gpa, &.{ root, "kept" });
    defer gpa.free(kept);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .fsevents });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    const f = &watcher.impl.fsevents;
    const stream = f.streams.get(id).?;
    inline for (.{ error.AccessDenied, error.Canceled, error.SystemResources }) |failure| {
        var vtable = io.vtable.*;
        vtable.dirStatFile = struct {
            fn stat(userdata: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
                if (std.mem.eql(u8, std.fs.path.basename(path), "kept")) return failure;
                return testing.io.vtable.dirStatFile(userdata, dir, path, options);
            }
        }.stat;
        f.io.vtable = &vtable;
        try testing.expect(!records.pairs(
            .{ .id = id, .path = kept, .flags = flag.item_renamed, .event = 0 },
            .{ .id = id, .path = root, .flags = flag.item_renamed, .event = 0 },
            Asking{ .f = f },
        ));
        try access.reportPlain(f, &watcher.batch, .{ .id = id, .path = kept, .flags = flag.item_removed, .event = 0 }, stream);
        try testing.expectEqual(@as(usize, 1), watcher.batch.events.items.len);
        try testing.expectEqual(lookout.Kind.overflow, watcher.batch.events.items[0].kind);
        try testing.expectEqualStrings(root, watcher.batch.events.items[0].path);
        try testing.expect(f.known.contains(.{ .id = id, .path = kept }));
        f.io = io;
        watcher.batch.reset(gpa);
    }
}

test "the flags that say the system lost track are one overflow, and the watch goes on" {
    // FSEvents.h on `kFSEventStreamEventFlagMustScanSubDirs`: "Your
    // application must rescan not just the directory given in the event,
    // but all its children, recursively. This can happen if there was a
    // problem whereby events were coalesced hierarchically", with
    // `UserDropped` and `KernelDropped` set beside it to say where. A
    // hundred thousand creations against the smallest buffer this
    // backend takes did not make the kernel set any of the three -- the
    // callback is a bounded copy, so this process is never the
    // bottleneck -- so the delivery is made by hand, through the
    // callback the system calls and the buffer it writes.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const sub = try std.fs.path.join(gpa, &.{ root, "sub" });
    defer gpa.free(sub);
    const file = try std.fs.path.join(gpa, &.{ root, "a.txt" });
    defer gpa.free(file);

    // The caller's half of the contract: seeded where the watch is taken.
    var baseline: Baseline = try .seed(gpa, io, root, .{ .recursive = true });
    defer baseline.deinit(gpa);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .fsevents });
    defer watcher.deinit();
    const tree = try watcher.add(root, .{ .recursive = true });
    const single = try watcher.add(file, .{});
    while ((try watcher.poll(200)).len != 0) {}
    const f = &watcher.impl.fsevents;

    // What the lost events would have carried.
    try tmp.dir.writeFile(io, .{ .sub_path = "missed.txt", .data = "x" });

    // One delivery, the three flags across it, at the root and below it:
    // one overflow, against the root.
    try synthesize(gpa, f.streams.get(tree).?, &.{
        .{ .path = root, .flags = flag.must_scan_sub_dirs | flag.kernel_dropped },
        .{ .path = sub, .flags = flag.must_scan_sub_dirs | flag.user_dropped },
        .{ .path = root, .flags = flag.must_scan_sub_dirs },
    });
    try expectOneOverflow(&watcher, tree, root, .directory);

    // The tree read again, which is what the event asks for.
    var recovered = false;
    for (try baseline.diff(gpa)) |change| {
        if (change.kind == .created and std.mem.endsWith(u8, change.path, "missed.txt")) recovered = true;
    }
    try testing.expect(recovered);

    // A watch on a file has its stream on the parent directory, and the
    // loss is reported there: a path the watch wants no event for, and
    // the one place its events could have been lost.
    try synthesize(gpa, f.streams.get(single).?, &.{
        .{ .path = root, .flags = flag.must_scan_sub_dirs | flag.kernel_dropped },
    });
    try expectOneOverflow(&watcher, single, file, .file);

    // A loss coalesced above the root took the root's events with it.
    try synthesize(gpa, f.streams.get(tree).?, &.{
        .{ .path = std.fs.path.dirname(root).?, .flags = flag.user_dropped },
    });
    try expectOneOverflow(&watcher, tree, root, .directory);

    // And both watches are still watching.
    try tmp.dir.writeFile(io, .{ .sub_path = "after.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one and two" });
    const after = try std.fs.path.join(gpa, &.{ root, "after.txt" });
    defer gpa.free(after);
    var saw_after = false;
    var saw_file = false;
    var waited: u32 = 0;
    while (waited < 10_000 and !(saw_after and saw_file)) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.id == tree and event.kind == .created and std.mem.eql(u8, event.path, after)) saw_after = true;
            if (event.id == single and event.kind == .modified and std.mem.eql(u8, event.path, file)) saw_file = true;
        }
    }
    try testing.expect(saw_after);
    try testing.expect(saw_file);
}

test "a loss the system reports reads the entry counts again, so the budget holds after it" {
    // Three folders made and counted; then the count set back to what it
    // would have been had their records been lost, and the loss said
    // the two ways it is said here -- by the system, through the
    // callback it calls, and by the delivery buffer when a delivery does
    // not fit. A count that is not read again stays three short for as
    // long as the watch lasts.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "sub");
    const sub = try std.fs.path.join(gpa, &.{ root, "sub" });
    defer gpa.free(sub);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .fsevents, .max_dir_entries = 3 });
    defer watcher.deinit();
    const tree = try watcher.add(root, .{ .recursive = true });
    while ((try watcher.poll(200)).len != 0) {}
    const f = &watcher.impl.fsevents;

    for ([_][]const u8{ "sub/a", "sub/b", "sub/c" }) |name| try tmp.dir.createDirPath(io, name);
    var created: usize = 0;
    var waited: u32 = 0;
    while (waited < 10_000 and created < 3) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind == .created) created += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), created);
    while ((try watcher.poll(200)).len != 0) {}
    try testing.expectEqual(@as(usize, 3), f.budget.count(sub).?);
    const root_count = f.budget.count(root).?;

    // Lost track at `sub`: its count is read again, and nothing above it.
    try f.budget.misread(sub, true, 0);
    try f.budget.misread(root, false, 5);
    try synthesize(gpa, f.streams.get(tree).?, &.{
        .{ .path = sub, .flags = flag.must_scan_sub_dirs | flag.user_dropped },
    });
    try expectOneOverflow(&watcher, tree, root, .directory);
    try testing.expectEqual(@as(usize, 3), f.budget.count(sub).?);
    try testing.expectEqual(root_count + 5, f.budget.count(root).?);
    try f.budget.misread(root, false, 0);

    // So the fourth is past it, and the watch is told.
    try tmp.dir.createDirPath(io, "sub/d");
    var overflowed = false;
    waited = 0;
    while (waited < 10_000 and !overflowed) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind == .overflow and event.id == tree) overflowed = true;
        }
    }
    try testing.expect(overflowed);
    // `sub` is past the budget now, so each record left of `sub/d` says
    // so again; they are read out before the next loss is made.
    while ((try watcher.poll(200)).len != 0) {}

    // A delivery that did not fit: every watch lost it, so every count
    // is read again.
    try f.budget.misread(sub, true, 0);
    {
        access.acquire(&f.sink.lock);
        defer access.release(&f.sink.lock);
        f.sink.overflowed = true;
        access.signal(f.sink);
    }
    try expectOneOverflow(&watcher, tree, root, .directory);
    try testing.expectEqual(@as(usize, 4), f.budget.count(sub).?);
}

/// No delivery of the system's from here on: the stream stopped, the
/// delivery it may be making waited out on its serial queue, and what it
/// left thrown away. What a test drains after this is what it delivered.
fn stopDeliveries(f: *FsEvents, stream: anytype) void {
    c.FSEventStreamStop(stream.ref);
    c.dispatch_sync_f(f.queue, null, settled);
    {
        access.acquire(&f.sink.lock);
        defer access.release(&f.sink.lock);
        f.sink.len = 0;
        f.sink.overflowed = false;
    }
    _ = access.readable(f, 0);
}

test "a rename whose halves arrive in two deliveries is one rename" {
    // FSEvents puts both halves of a rename in one delivery unless a
    // burst is long enough to split them, and then the old name ends one
    // delivery and the new name starts the next. A burst long enough to
    // do that is also long enough for fseventsd, on a busy machine, to
    // drop part of it -- it did in 13 of 20 runs beside a build -- so a
    // real burst cannot be told to split and cannot be told not to drop.
    // The split is made here instead: every pair across two deliveries,
    // made through the callback the system calls and each drained on its
    // own, as a burst that split every one of its pairs would be. The
    // renames are real, so the file system answers which name is there
    // exactly as it would; the stream is stopped first, so what is
    // drained is only what this test delivered.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    const pairs = 100;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var before: [pairs][]u8 = undefined;
    var after: [pairs][]u8 = undefined;
    for (0..pairs) |i| {
        var name: [32]u8 = undefined;
        before[i] = try std.fs.path.join(gpa, &.{ root, std.fmt.bufPrint(&name, "before-{d}.txt", .{i}) catch unreachable });
        after[i] = try std.fs.path.join(gpa, &.{ root, std.fmt.bufPrint(&name, "after-{d}.txt", .{i}) catch unreachable });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = before[i], .data = "x" });
    }
    defer for (before, after) |b, a| {
        gpa.free(b);
        gpa.free(a);
    };

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .fsevents });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    const f = &watcher.impl.fsevents;
    const stream = f.streams.get(id).?;

    stopDeliveries(f, stream);

    for (before, after) |b, a| try Io.Dir.renameAbsolute(b, a, io);

    const renamed = flag.item_renamed;
    try synthesize(gpa, stream, &.{.{ .path = before[0], .flags = renamed }});
    try access.drain(f, &watcher.batch);
    for (1..pairs) |i| {
        try synthesize(gpa, stream, &.{
            .{ .path = after[i - 1], .flags = renamed },
            .{ .path = before[i], .flags = renamed },
        });
        try access.drain(f, &watcher.batch);
    }
    try synthesize(gpa, stream, &.{.{ .path = after[pairs - 1], .flags = renamed }});
    try access.drain(f, &watcher.batch);
    try access.resolveHeld(f, &watcher.batch);

    // Every pair one `renamed`, from its old name to its new one, and
    // nothing else.
    try testing.expectEqual(@as(usize, pairs), watcher.batch.events.items.len);
    for (watcher.batch.events.items, 0..) |event, i| {
        try testing.expectEqual(lookout.Kind.renamed, event.kind);
        try testing.expectEqualStrings(after[i], event.path);
        try testing.expectEqualStrings(before[i], event.from.?);
    }
}

test "the entry budget is one directory's, with every creation delivered" {
    // The FSEvents half of the claim in src/testing/gaps_test.zig ("the entry
    // budget is one directory's, not a whole recursive watch's"): twelve
    // directories of a hundred and fifty creations under a budget of 512
    // are twelve directories inside it. Made live, the burst is one
    // fseventsd may drop part of on a busy machine -- it said
    // `MustScanSubDirs` with `UserDropped` in 4 of 10 runs beside sixteen
    // busy processes -- and lookout then rightly reports an overflow that
    // is the system's and not the budget's. So the creations are real and
    // their records are made here, through the callback the system calls,
    // with the stream stopped first: what is drained is every creation
    // and nothing the system lost.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    const dirs = 12;
    const files = 150;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    for (0..dirs) |d| {
        var name: [16]u8 = undefined;
        try tmp.dir.createDirPath(io, std.fmt.bufPrint(&name, "d{d}", .{d}) catch unreachable);
    }

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .fsevents, .max_dir_entries = 512 });
    defer watcher.deinit();
    const id = try watcher.add(root, .{ .recursive = true });
    const f = &watcher.impl.fsevents;
    const stream = f.streams.get(id).?;

    stopDeliveries(f, stream);

    // Each directory's creations in deliveries of their own, drained as
    // they go, as the live test drains them.
    for (0..dirs) |d| {
        for (0..files) |i| {
            var name: [32]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&name, "d{d}/f{d}.txt", .{ d, i }) catch unreachable;
            try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "x" });
            const full = try std.fs.path.join(gpa, &.{ root, sub_path });
            defer gpa.free(full);
            try synthesize(gpa, stream, &.{.{ .path = full, .flags = flag.item_created | flag.item_modified }});
        }
        try access.drain(f, &watcher.batch);
    }

    var created: usize = 0;
    var overflow: usize = 0;
    for (watcher.batch.events.items) |event| switch (event.kind) {
        .created => created += 1,
        .overflow => overflow += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 0), overflow);
    try testing.expectEqual(@as(usize, dirs * files), created);
    for (0..dirs) |d| {
        var name: [16]u8 = undefined;
        const dir = try std.fs.path.join(gpa, &.{ root, std.fmt.bufPrint(&name, "d{d}", .{d}) catch unreachable });
        defer gpa.free(dir);
        try testing.expectEqual(@as(usize, files), f.budget.count(dir).?);
    }
}

test "a poll that expires before the replay begins is not the end of it" {
    // The persisted path baseline reports the real deletion before the
    // system has delivered anything. Neither a quiet poll nor HistoryDone
    // changes that answer, and the late replay cannot report it twice.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "one" });

    var token: []u8 = undefined;
    defer gpa.free(token);
    {
        var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .fsevents });
        defer watcher.deinit();
        const first = try watcher.add(root, .{ .recursive = true });
        // Taken before the deletion, and holding nothing unread.
        stopDeliveries(&watcher.impl.fsevents, watcher.impl.fsevents.streams.get(first).?);
        var checkpoint = (try watcher.checkpoint(gpa)).?;
        defer checkpoint.deinit();
        token = try checkpoint.token(gpa);
    }

    try tmp.dir.deleteFile(io, "gone.txt");
    const deleted = try std.fs.path.join(gpa, &.{ root, "gone.txt" });
    defer gpa.free(deleted);

    var vtable: Io.VTable = undefined;
    const frozen = clock.frozen(io, &vtable);
    var checkpoint = try lookout.Checkpoint.parse(gpa, token);
    defer checkpoint.deinit();
    var watcher: lookout.Watcher = try .init(gpa, frozen, .{
        .backend = .fsevents,
        .checkpoint = checkpoint,
        .latency_ms = 0,
    });
    defer watcher.deinit();
    const id = try watcher.add(root, .{ .recursive = true });
    const f = &watcher.impl.fsevents;
    const stream = f.streams.get(id).?;

    stopDeliveries(f, stream);

    // The boundary: a wait before the stream has said anything.
    const initial = try watcher.poll(0);
    try testing.expectEqual(@as(usize, 1), initial.len);
    try testing.expectEqual(lookout.Kind.removed, initial[0].kind);
    try testing.expectEqualStrings(deleted, initial[0].path);
    // The sentinel, alone in its delivery: nothing happened to a path.
    try synthesize(gpa, stream, &.{.{ .path = root, .flags = flag.history_done }});
    try testing.expectEqual(@as(usize, 0), (try watcher.poll(0)).len);
    try testing.expect(stream.replayed != null);
    // The tail, live after the sentinel.
    try synthesize(gpa, stream, &.{.{ .path = deleted, .flags = flag.item_created | flag.item_removed }});
    const events = try watcher.poll(0);
    try testing.expectEqual(@as(usize, 0), events.len);
}

test "a deletion numbered after the checkpoint marker is reported exactly once however late" {
    // Reuse the real checkpoint/deletion and stopped callback fixture from
    // the rejected marker-barrier experiment. The clock advances fifteen
    // seconds and the deletion is numbered after the checkpoint and sentinel.
    // Only the persisted baseline can establish that this path was known.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "one" });

    var token: []u8 = undefined;
    defer gpa.free(token);
    {
        var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .fsevents });
        defer watcher.deinit();
        const first = try watcher.add(root, .{ .recursive = true });
        // Taken before the deletion, and holding nothing unread.
        stopDeliveries(&watcher.impl.fsevents, watcher.impl.fsevents.streams.get(first).?);
        var checkpoint = (try watcher.checkpoint(gpa)).?;
        defer checkpoint.deinit();
        token = try checkpoint.token(gpa);
    }

    try tmp.dir.deleteFile(io, "gone.txt");
    const deleted = try std.fs.path.join(gpa, &.{ root, "gone.txt" });
    defer gpa.free(deleted);

    const Late = struct {
        var ms: i96 = 1_000;
        fn now(_: ?*anyopaque, _: Io.Clock) Io.Timestamp {
            return .{ .nanoseconds = ms * std.time.ns_per_ms };
        }
    };
    Late.ms = 1_000;
    var vtable = io.vtable.*;
    vtable.now = Late.now;
    const frozen: Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var checkpoint = try lookout.Checkpoint.parse(gpa, token);
    defer checkpoint.deinit();
    var watcher: lookout.Watcher = try .init(gpa, frozen, .{
        .backend = .fsevents,
        .checkpoint = checkpoint,
        .latency_ms = 0,
    });
    defer watcher.deinit();
    const id = try watcher.add(root, .{ .recursive = true });
    const f = &watcher.impl.fsevents;
    const stream = f.streams.get(id).?;

    stopDeliveries(f, stream);

    // The boundary: a wait before the stream has said anything.
    const initial = try watcher.poll(0);
    try testing.expectEqual(@as(usize, 1), initial.len);
    try testing.expectEqual(lookout.Kind.removed, initial[0].kind);
    try testing.expectEqualStrings(deleted, initial[0].path);
    // The sentinel, alone in its delivery: nothing happened to a path.
    try synthesize(gpa, stream, &.{.{ .path = root, .flags = flag.history_done }});
    try testing.expectEqual(@as(usize, 0), (try watcher.poll(0)).len);
    try testing.expect(stream.replayed != null);
    // Numbered after the checkpoint and sentinel, delivered well beyond the
    // former one-second replay window. No id-space barrier can bound it.
    const marker_at = stream.cursor + 1_000;
    Late.ms += 15_000;
    // The tail, live after the sentinel.
    try synthesize(gpa, stream, &.{.{ .path = deleted, .flags = flag.item_created | flag.item_removed, .event = marker_at + 1 }});
    const events = try watcher.poll(0);
    try testing.expectEqual(@as(usize, 0), events.len);
    try synthesize(gpa, stream, &.{.{ .path = deleted, .flags = flag.item_removed, .event = marker_at + 2 }});
    try testing.expectEqual(@as(usize, 0), (try watcher.poll(0)).len);
}

test "checkpoints preserve independent cursors and unread stream records" {
    if (!lookout.supported(.fsevents)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var watcher = try lookout.Watcher.init(gpa, std.testing.io, .{ .backend = .fsevents });
    defer watcher.deinit();
    try tmp.dir.createDirPath(std.testing.io, "first");
    try tmp.dir.createDirPath(std.testing.io, "second");
    const first = try tmp.dir.realPathFileAlloc(std.testing.io, "first", gpa);
    defer gpa.free(first);
    const second = try tmp.dir.realPathFileAlloc(std.testing.io, "second", gpa);
    defer gpa.free(second);
    const a = try watcher.add(first, .{});
    const b = try watcher.add(second, .{});
    const backend = &watcher.impl.fsevents;
    backend.streams.get(a).?.cursor = 101;
    backend.streams.get(b).?.cursor = 202;
    // Unread callbacks cannot affect either saved cursor.
    access.acquire(&backend.sink.lock);
    access.append(backend.sink, a, flag.item_modified, 303, first);
    access.release(&backend.sink.lock);
    var checkpoint = (try watcher.checkpoint(gpa)).?;
    defer checkpoint.deinit();
    try std.testing.expectEqual(@as(u64, 101), checkpoint.state.value.watches[0].cursor);
    try std.testing.expectEqual(@as(u64, 202), checkpoint.state.value.watches[1].cursor);
    var resumed = try lookout.Watcher.init(gpa, std.testing.io, .{ .backend = .fsevents, .checkpoint = checkpoint });
    defer resumed.deinit();
    // Registration order does not determine which cursor belongs to it.
    const rb = try resumed.add(second, .{});
    const ra = try resumed.add(first, .{});
    try std.testing.expectEqual(@as(u64, 101), resumed.impl.fsevents.streams.get(ra).?.cursor);
    try std.testing.expectEqual(@as(u64, 202), resumed.impl.fsevents.streams.get(rb).?.cursor);
}

test "a checkpoint refuses a different volume or FSEvents log before restoring changes" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var watcher = try lookout.Watcher.init(gpa, testing.io, .{ .backend = .fsevents });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    try testing.expectEqual(watcher.impl.fsevents.streams.get(id).?.volume.device, c.FSEventStreamGetDeviceBeingWatched(watcher.impl.fsevents.streams.get(id).?.ref));
    try watcher.batch.deferChange(gpa, id, root, .modified, null, .directory);
    var saved = (try watcher.checkpoint(gpa)).?;
    defer saved.deinit();
    for ([_]bool{ true, false }) |volume| {
        var changed = try checkpoint_format.copy(gpa, saved.state.value);
        defer changed.deinit();
        const watches = @constCast(changed.value.watches);
        if (volume) watches[0].identity.volume[0] ^= 1 else watches[0].identity.log[0] ^= 1;
        var resumed = try lookout.Watcher.init(gpa, testing.io, .{ .backend = .fsevents, .checkpoint = .{ .state = changed } });
        defer resumed.deinit();
        try testing.expectError(error.InvalidCheckpoint, resumed.add(root, .{}));
        try testing.expectEqual(@as(usize, 0), resumed.impl.fsevents.streams.count());
        try testing.expectEqual(@as(usize, 0), resumed.batch.held.count());
        try testing.expect(!resumed.impl.fsevents.resume_used[0]);
    }
}

test "a checkpoint is unavailable without an unchanged persistent log" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var watcher = try lookout.Watcher.init(gpa, testing.io, .{ .backend = .fsevents });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    const stream = watcher.impl.fsevents.streams.get(id).?;
    const original = stream.volume.identity;
    defer stream.volume.identity = original;
    try watcher.batch.deferChange(gpa, id, root, .modified, null, .directory);
    stream.volume.identity = null;
    try testing.expectEqual(@as(?Checkpoint, null), try watcher.checkpoint(gpa));
    stream.volume.identity = original;
    stream.volume.identity.?.log[0] ^= 1;
    try testing.expectEqual(@as(?Checkpoint, null), try watcher.checkpoint(gpa));
}

test "a recursive mount keeps live coverage and refuses a single-device checkpoint" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var watcher = try lookout.Watcher.init(gpa, testing.io, .{ .backend = .fsevents, .latency_ms = 0 });
    defer watcher.deinit();
    const id = try watcher.add(root, .{ .recursive = true });
    const backend = &watcher.impl.fsevents;
    try synthesize(gpa, backend.streams.get(id).?, &.{.{ .path = root, .flags = 0x40 }});
    try access.drain(backend, &watcher.batch);
    try testing.expectEqual(@as(i32, 0), c.FSEventStreamGetDeviceBeingWatched(backend.streams.get(id).?.ref));
    try testing.expectEqual(@as(?Checkpoint, null), try watcher.checkpoint(gpa));
    try testing.expectEqual(@as(usize, 1), watcher.batch.events.items.len);
    try testing.expectEqual(lookout.Kind.overflow, watcher.batch.events.items[0].kind);
    try testing.expectEqualStrings(root, watcher.batch.events.items[0].path);
    _ = try watcher.poll(0);
    const wanted = try std.fs.path.join(gpa, &.{ root, "live" });
    defer gpa.free(wanted);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "live", .data = "x" });
    var saw = false;
    var waited: u32 = 0;
    while (waited < 10_000 and !saw) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (std.mem.eql(u8, event.path, wanted) and event.kind == .created) saw = true;
        }
    }
    try testing.expect(saw);
}

test "an absent pending root refuses a checkpoint from another volume" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    const absent = try std.fs.path.join(gpa, &.{ root, "absent" });
    defer gpa.free(absent);
    var watcher = try lookout.Watcher.init(gpa, testing.io, .{ .backend = .fsevents });
    defer watcher.deinit();
    _ = try watcher.add(absent, .{ .pending = true });
    var saved = (try watcher.checkpoint(gpa)).?;
    defer saved.deinit();
    @constCast(saved.state.value.watches)[0].identity.volume[0] ^= 1;
    var resumed = try lookout.Watcher.init(gpa, testing.io, .{ .backend = .fsevents, .checkpoint = saved });
    defer resumed.deinit();
    try testing.expectError(error.InvalidCheckpoint, resumed.add(absent, .{ .pending = true }));
    try testing.expectEqual(@as(usize, 0), resumed.pending.items.len);
    try testing.expectEqual(@as(usize, 0), resumed.table.count());
    try testing.expectEqual(@as(usize, 0), resumed.impl.fsevents.streams.count());
}

test "a pending promotion rescans when its saved log identity is refused" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    const absent = try std.fs.path.join(gpa, &.{ root, "absent" });
    defer gpa.free(absent);
    var first = try lookout.Watcher.init(gpa, testing.io, .{ .backend = .fsevents });
    defer first.deinit();
    _ = try first.add(absent, .{ .pending = true });
    var saved = (try first.checkpoint(gpa)).?;
    defer saved.deinit();
    var resumed = try lookout.Watcher.init(gpa, testing.io, .{ .backend = .fsevents, .checkpoint = saved });
    defer resumed.deinit();
    const id = try resumed.add(absent, .{ .pending = true });
    const backend = &resumed.impl.fsevents;
    // An anchor that had not consumed its snapshot encounters a different
    // log when the requested path appears. Force that identity transition.
    backend.resume_used[0] = false;
    @constCast(backend.restarting.?.state.value.watches)[0].identity.log[0] ^= 1;
    try tmp.dir.createDirPath(testing.io, "absent");
    const events = try resumed.poll(0);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(lookout.Kind.overflow, events[0].kind);
    try testing.expectEqual(id, events[0].id);
    try testing.expectEqualStrings(absent, events[0].path);
    try testing.expect(backend.resume_used[0]);
    _ = try resumed.poll(0);
    try testing.expectEqual(@as(usize, 0), resumed.pending.items.len);
    try testing.expect(backend.streams.contains(id));
}

test "fresh FSEvents replay reports no pre-add state or sibling paths" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "watched");
    try tmp.dir.writeFile(io, .{ .sub_path = "watched/old.txt", .data = "before" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sibling.txt", .data = "before" });
    const root = try tmp.dir.realPathFileAlloc(io, "watched", gpa);
    defer gpa.free(root);
    const old = try std.fs.path.join(gpa, &.{ root, "old.txt" });
    defer gpa.free(old);
    const wanted = try std.fs.path.join(gpa, &.{ root, "new.txt" });
    defer gpa.free(wanted);
    var watcher = try lookout.Watcher.init(gpa, io, .{ .backend = .fsevents, .latency_ms = 0 });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "watched/new.txt", .data = "after" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sibling.txt", .data = "after" });
    const stream = watcher.impl.fsevents.streams.get(id).?;
    var found = false;
    const deadline = Deadline.start(io, 5_000);
    while (!deadline.expired()) {
        for (try watcher.poll(100)) |event| {
            try testing.expectEqual(id, event.id);
            try testing.expect(path_cmp.within(root, event.path));
            try testing.expect(!path_cmp.eql(old, event.path));
            if (path_cmp.eql(wanted, event.path) and event.kind == .created) found = true;
        }
    }
    try testing.expect(found);
    // Every fresh stream now replays from a captured boundary. Its marker
    // is consumed even though this watch did not ask to resume a checkpoint.
    try testing.expect(stream.replayed != null);
    try testing.expect(!stream.resumed);
}

fn expectOneOverflow(watcher: *lookout.Watcher, id: WatchId, root: []const u8, target: Target) !void {
    var overflows: usize = 0;
    var waited: u32 = 0;
    while (waited < 10_000 and overflows == 0) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind != .overflow) continue;
            try std.testing.expectEqual(id, event.id);
            try std.testing.expectEqualStrings(root, event.path);
            try std.testing.expectEqual(target, event.target);
            overflows += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), overflows);
    while (true) {
        const events = try watcher.poll(200);
        if (events.len == 0) return;
        for (events) |event| try std.testing.expect(event.kind != .overflow);
    }
}

fn expectInitAllocationFailure(fail_index: usize) !void {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
    try std.testing.expectError(error.OutOfMemory, lookout.Watcher.init(
        failing.allocator(),
        std.testing.io,
        .{ .backend = .fsevents },
    ));
}

test "FSEvents initialization preserves sink allocator failure" {
    try expectInitAllocationFailure(0);
}

test "FSEvents initialization preserves buffer allocator failure" {
    try expectInitAllocationFailure(1);
}

fn expectHeldRenameFailure(comptime transfer: enum { resolve, replace, rejoin }) !void {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "old", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const old = try std.fs.path.join(testing.allocator, &.{ root, "old" });
    defer testing.allocator.free(old);
    var watcher = try lookout.Watcher.init(testing.allocator, testing.io, .{ .backend = .fsevents });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    const backend = &watcher.impl.fsevents;
    try tmp.dir.deleteFile(testing.io, "old");
    const record: Record = .{ .id = id, .path = old, .flags = flag.item_renamed, .event = 1 };
    try access.hold(backend, &watcher.batch, record);
    const original = backend.pairing.held.?.path.ptr;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = if (transfer == .replace) 1 else 0 });
    backend.gpa = failing.allocator();
    defer backend.gpa = testing.allocator;
    var used = [_]bool{};
    const result = switch (transfer) {
        .resolve => access.resolveHeld(backend, &watcher.batch),
        .replace => access.hold(backend, &watcher.batch, record),
        .rejoin => access.rejoin(backend, &watcher.batch, &.{}, &used),
    };
    try testing.expectError(error.OutOfMemory, result);
    try testing.expect(backend.pairing.held != null);
    try testing.expectEqual(original, backend.pairing.held.?.path.ptr);
    try testing.expectEqualStrings(old, backend.pairing.held.?.path);
    // With replacement, equality by contents is not enough: the original
    // allocation must still be held and the incoming copy released.
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    backend.gpa = testing.allocator;
    try access.resolveHeld(backend, &watcher.batch);
    try testing.expect(backend.pairing.held == null);
    try testing.expectEqual(@as(usize, 1), watcher.batch.events.items.len);
    try testing.expectEqual(lookout.Kind.removed, watcher.batch.events.items[0].kind);
}

test "a failed FSEvents held rename transfer keeps its path" {
    try expectHeldRenameFailure(.resolve);
}

test "a failed FSEvents held rename replacement keeps its path" {
    try expectHeldRenameFailure(.replace);
}

test "a failed FSEvents held rename rejoin keeps its path" {
    try expectHeldRenameFailure(.rejoin);
}

test "a recursive pending checkpoint resumes on its nonrecursive ancestor" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const absent = try std.fs.path.join(gpa, &.{ root, "pending" });
    defer gpa.free(absent);
    var first = try lookout.Watcher.init(gpa, io, .{ .backend = .fsevents });
    defer first.deinit();
    _ = try first.add(absent, .{ .pending = true, .recursive = true });
    var checkpoint = (try first.checkpoint(gpa)).?;
    defer checkpoint.deinit();
    var resumed = try lookout.Watcher.init(gpa, io, .{ .backend = .fsevents, .checkpoint = checkpoint });
    defer resumed.deinit();
    const id = try resumed.add(absent, .{ .pending = true, .recursive = true });
    try testing.expectEqual(@as(usize, 1), resumed.pending.items.len);
    try tmp.dir.createDirPath(io, "pending/sub");
    _ = try resumed.poll(0);
    try testing.expectEqual(@as(usize, 0), resumed.pending.items.len);
    try testing.expectEqual(id, resumed.table.keys()[0]);
    try testing.expect(resumed.table.values()[0].recursive);
}

test "checkpoint capture allocation does not grow with the remembered tree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var bytes: [2]usize = undefined;
    for (0..2) |round| {
        if (round == 1) for (0..256) |i| {
            var name: [32]u8 = undefined;
            try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "file-{d}", .{i}), .data = "" });
        };
        var watcher = try lookout.Watcher.init(gpa, io, .{ .backend = .fsevents });
        defer watcher.deinit();
        _ = try watcher.add(root, .{ .recursive = true });
        var counting: std.testing.FailingAllocator = .init(gpa, .{});
        var saved = (try watcher.checkpoint(counting.allocator())).?;
        defer saved.deinit();
        bytes[round] = counting.allocated_bytes;
    }
    try std.testing.expectEqual(bytes[0], bytes[1]);
}

test "a shared checkpoint token keeps its revision after the watch is removed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var saved: lookout.Checkpoint = undefined;
    {
        var watcher = try lookout.Watcher.init(gpa, io, .{ .backend = .fsevents });
        defer watcher.deinit();
        const id = try watcher.add(root, .{});
        saved = (try watcher.checkpoint(gpa)).?;
        watcher.remove(id);
        try tmp.dir.deleteFile(io, "kept");
    }
    defer saved.deinit();
    const token = try saved.token(gpa);
    defer gpa.free(token);
    var parsed = try lookout.Checkpoint.parse(gpa, token);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.state.value.watches[0].baseline.flat.len);
    var resumed = try lookout.Watcher.init(gpa, io, .{ .backend = .fsevents, .checkpoint = saved, .latency_ms = 0 });
    defer resumed.deinit();
    const restored = try resumed.add(root, .{});
    stopDeliveries(&resumed.impl.fsevents, resumed.impl.fsevents.streams.get(restored).?);
    const events = try resumed.poll(0);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(lookout.Kind.removed, events[0].kind);
}
