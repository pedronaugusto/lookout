//! Proving tests, one per defect.
//!
//! Each of these failed before the change it stands for and passes after
//! it. They live apart from `test_suite.zig` because that file is the
//! contract every backend is held to, while these name a particular way
//! one backend, or one shared rule, was wrong.

const std = @import("std");
const builtin = @import("builtin");

const lookout = @import("lookout.zig");
const Kind = lookout.Kind;
const Watcher = lookout.Watcher;

const timeout_ms = 10_000;

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

fn writeBurst(dir: std.Io.Dir, count: usize) !void {
    for (0..count) |i| {
        var name: [64]u8 = undefined;
        try dir.writeFile(std.testing.io, .{
            .sub_path = std.fmt.bufPrint(&name, "burst-entry-{d}.txt", .{i}) catch unreachable,
            .data = "x",
        });
    }
}

/// Polls until nothing has arrived for a whole timeout, counting what did.
const Tally = struct {
    created: usize = 0,
    overflow: usize = 0,
    modified: usize = 0,

    fn count(t: *Tally, events: []const lookout.Event) void {
        for (events) |event| switch (event.kind) {
            .created => t.created += 1,
            .overflow => t.overflow += 1,
            .modified => t.modified += 1,
            else => {},
        };
    }

    fn drain(t: *Tally, watcher: *Watcher, quiet_ms: u32) !void {
        var idle: u32 = 0;
        while (idle < quiet_ms) {
            const events = try watcher.poll(200);
            if (events.len == 0) {
                idle += 200;
                continue;
            }
            idle = 0;
            for (events) |event| switch (event.kind) {
                .created => t.created += 1,
                .overflow => t.overflow += 1,
                .modified => t.modified += 1,
                else => {},
            };
        }
    }
};

test "a change inside a renamed directory is not a creation" {
    // The Apple backend remembers every path it has seen, so that an
    // accumulated `ItemCreated` flag can be told from a write. Renaming a
    // directory left every remembered path under the old name, so the
    // first write inside the new name looked like a creation.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        try tmp.dir.createDirPath(io, "sub");
        try tmp.dir.writeFile(io, .{ .sub_path = "sub/a.txt", .data = "one" });

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = backend,
            .poll_interval_ms = 20,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{ .recursive = true });
        while ((try watcher.poll(200)).len != 0) {}

        const moved = try std.fs.path.join(gpa, &.{ root, "sub2" });
        defer gpa.free(moved);

        try tmp.dir.rename("sub", tmp.dir, "sub2", io);

        // Waited for rather than slept through: the write below has to
        // happen after the watcher has taken the rename in, or what it
        // reports is a race and not a rule.
        var lost = false;
        var settled = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !settled) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (event.kind == .overflow) lost = true;
                if (std.mem.startsWith(u8, event.path, moved)) settled = true;
            }
        }
        try std.testing.expect(settled or lost);
        while (true) {
            const events = try watcher.poll(400);
            if (events.len == 0) break;
            for (events) |event| {
                if (event.kind == .overflow) lost = true;
            }
        }
        // A kernel that lost track of the rename says so, and then what
        // it remembers about the tree is not this test's to assert
        // about: the caller is being told to read the tree again.
        if (lost) continue;

        try tmp.dir.writeFile(io, .{ .sub_path = "sub2/a.txt", .data = "one and two" });

        const wanted = try std.fs.path.join(gpa, &.{ root, "sub2", "a.txt" });
        defer gpa.free(wanted);

        var saw_created = false;
        var saw_modified = false;
        waited = 0;
        while (waited < timeout_ms and !saw_modified) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (event.kind == .overflow) lost = true;
                if (!std.mem.eql(u8, event.path, wanted)) continue;
                if (event.kind == .created) saw_created = true;
                if (event.kind == .modified) saw_modified = true;
            }
        }
        if (lost) continue;
        // FSEvents can deliver the metadata change made by opening and
        // truncating the file before its content-change record. That is
        // not the creation this test guards against, so wait for the
        // content change while remembering whether a creation appeared
        // at any point on the way.
        if (saw_created or !saw_modified) {
            std.debug.print("{s}: created={}, modified={} after a directory rename\n", .{
                @tagName(backend), saw_created, saw_modified,
            });
        }
        try std.testing.expect(!saw_created);
        try std.testing.expect(saw_modified);
    }
}

test "a watch spelled in another case than the disk still reports" {
    // A path that does not exist yet cannot be canonicalised, so the
    // spelling the caller used is the spelling the watch is taken under.
    // On a volume that folds case the operating system then names the
    // same path differently, and a byte-exact comparison drops every
    // event.
    if (!lookout.folds_case) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = backend,
            .poll_interval_ms = 20,
        });
        defer watcher.deinit();

        // Asked for in upper case; created in lower case.
        const asked = try std.fs.path.join(gpa, &.{ root, "TARGET" });
        defer gpa.free(asked);
        _ = try watcher.add(asked, .{ .pending = true, .recursive = true });

        try tmp.dir.createDirPath(io, "target");

        // The path the caller asked about appeared, under the spelling
        // the caller used.
        var promoted = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !promoted) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (event.kind == .created and std.mem.eql(u8, event.path, asked)) promoted = true;
            }
        }
        if (!promoted) std.debug.print("{s}: {s} never appeared\n", .{ @tagName(backend), asked });
        try std.testing.expect(promoted);

        // And the watch on it is a real watch: what happens inside is
        // reported, though the kernel spells the path the other way.
        try tmp.dir.writeFile(io, .{ .sub_path = "target/a.txt", .data = "one" });
        var found = false;
        waited = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (std.mem.endsWith(u8, event.path, "a.txt")) found = true;
            }
        }
        if (!found) std.debug.print("{s}: nothing under {s}\n", .{ @tagName(backend), asked });
        try std.testing.expect(found);
    }
}

test "an ignore pattern in another case than the disk still excludes" {
    if (!lookout.folds_case) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        try tmp.dir.createDirPath(io, "skip");

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = backend,
            .poll_interval_ms = 20,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{
            .recursive = true,
            .filter = .{ .ignore = &.{"SKIP"} },
        });
        while ((try watcher.poll(200)).len != 0) {}

        const ignored = try std.fs.path.join(gpa, &.{ root, "skip" });
        defer gpa.free(ignored);
        const wanted = try std.fs.path.join(gpa, &.{ root, "kept.txt" });
        defer gpa.free(wanted);

        try tmp.dir.writeFile(io, .{ .sub_path = "skip/a.txt", .data = "one" });
        try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "two" });

        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                try std.testing.expect(!std.mem.startsWith(u8, event.path, ignored));
                if (std.mem.eql(u8, event.path, wanted)) found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "a slow write is one event, and it arrives after the writing stops" {
    // `settle_ms` waits for a file to stop changing. The quiet window on
    // its own is a guess -- a kernel that coalesces several writes into
    // one notification can leave it closing over a file that is still
    // growing -- so `Batch.promote` measures the file as well, and the
    // unit test beside it is what proves that. This one holds the whole
    // contract together: one event, and not before the writing is over.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var watcher: Watcher = try .init(gpa, io, .{
        .backend = .poll,
        .poll_interval_ms = 20,
        .settle_ms = 200,
        .latency_ms = 0,
    });
    defer watcher.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = "" });
    _ = try watcher.add(root, .{});
    while ((try watcher.poll(200)).len != 0) {}

    const wanted = try std.fs.path.join(gpa, &.{ root, "big.bin" });
    defer gpa.free(wanted);

    const Writer = struct {
        dir: std.Io.Dir,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            const w_io = std.testing.io;
            const chunk = "x" ** (64 * 1024);
            var file = self.dir.createFile(w_io, "big.bin", .{ .truncate = false }) catch return;
            defer file.close(w_io);
            var buffer: [4096]u8 = undefined;
            var out = file.writer(w_io, &buffer);
            for (0..20) |_| {
                out.interface.writeAll(chunk) catch break;
                out.interface.flush() catch break;
                w_io.sleep(.fromMilliseconds(25), .awake) catch break;
            }
            self.done.store(true, .release);
        }
    };
    var writer: Writer = .{ .dir = tmp.dir };
    const thread = try std.Thread.spawn(.{}, Writer.run, .{&writer});
    defer thread.join();

    var seen: usize = 0;
    var waited: u32 = 0;
    while (waited < timeout_ms and seen == 0) : (waited += 100) {
        for (try watcher.poll(100)) |event| {
            if (!std.mem.eql(u8, event.path, wanted)) continue;
            try std.testing.expectEqual(Kind.modified, event.kind);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
    // Nothing was reported while the file was still being written to.
    try std.testing.expect(writer.done.load(.acquire));
}

test "a burst of renames is paired across the reads it is split over" {
    // The kernel puts both halves of a rename in one read, but a burst
    // large enough to fill the read buffer splits one pair across two.
    // A half flushed at the end of its own read degrades into a removal
    // and a creation on a backend that says it pairs.
    //
    // The burst has to be one the kernel cannot lose, whatever else the
    // machine is doing, or what the test is left holding under load is
    // a record with holes and no claim to make about it. inotify's queue
    // is counted in events, sixteen thousand by default, and these eight
    // hundred do not reach it. The buffer Windows keeps between two reads
    // is the size of the read's, 64 KiB by default, and the records of
    // the whole burst come to under 32 KiB. Neither depends on how busy
    // the machine is, so neither loses any of it.
    //
    // FSEvents does. fseventsd, between the kernel and every client,
    // dropped part of this burst in 13 of 20 runs on a machine building
    // beside it, and nothing on lookout's side changes that. So FSEvents
    // is held to this claim in src/backend/fsevents.zig ("a rename whose
    // halves arrive in two deliveries is one rename"), where every pair
    // is split across two deliveries by hand through the callback the
    // system calls, rather than a burst being hoped to split them and
    // not to drop.
    const backend = lookout.default_backend;
    if (!lookout.pairsRenames(backend) or backend == .fsevents) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const pairs = 400;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    for (0..pairs) |i| {
        var name: [64]u8 = undefined;
        try tmp.dir.writeFile(io, .{
            .sub_path = std.fmt.bufPrint(&name, "before-{d}.txt", .{i}) catch unreachable,
            .data = "x",
        });
    }

    var watcher: Watcher = try .init(gpa, io, .{
        .backend = backend,
        .max_dir_entries = 1_000_000,
    });
    defer watcher.deinit();
    _ = try watcher.add(root, .{});
    while ((try watcher.poll(200)).len != 0) {}

    for (0..pairs) |i| {
        var from: [64]u8 = undefined;
        var to: [64]u8 = undefined;
        try tmp.dir.rename(
            std.fmt.bufPrint(&from, "before-{d}.txt", .{i}) catch unreachable,
            tmp.dir,
            std.fmt.bufPrint(&to, "after-{d}.txt", .{i}) catch unreachable,
            io,
        );
    }

    var renamed: usize = 0;
    var unpaired: usize = 0;
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
            .renamed => {
                const from = event.from orelse {
                    unpaired += 1;
                    continue;
                };
                // Each new name joined to its own old one.
                const to_name = std.fs.path.basename(event.path);
                const from_name = std.fs.path.basename(from);
                try std.testing.expect(std.mem.startsWith(u8, to_name, "after-"));
                try std.testing.expect(std.mem.startsWith(u8, from_name, "before-"));
                try std.testing.expectEqualStrings(from_name["before-".len..], to_name["after-".len..]);
                renamed += 1;
            },
            .created, .removed => unpaired += 1,
            .overflow => overflow += 1,
            else => {},
        };
    }
    if (overflow != 0 or unpaired != 0) {
        std.debug.print("{d} paired, {d} unpaired, {d} overflow\n", .{ renamed, unpaired, overflow });
    }
    try std.testing.expectEqual(@as(usize, 0), overflow);
    try std.testing.expectEqual(@as(usize, 0), unpaired);
    try std.testing.expectEqual(pairs, renamed);
}

test "the entry budget is one directory's, not a whole recursive watch's" {
    // `max_dir_entries` is documented as the entries of one watched
    // directory. The Windows backend counted every creation anywhere
    // under a recursive root against one number, so twelve directories
    // of a hundred and fifty entries overflowed a budget none of them
    // reached.
    //
    // The burst has to be one the system cannot lose, or an overflow
    // here is a loss it reported and not the budget. inotify's queue and
    // the Windows read buffer hold one directory's hundred and fifty
    // records whatever the machine is doing, and `kqueue` and `poll` list
    // the directories themselves. fseventsd does not: beside sixteen busy
    // processes it dropped part of this burst in 4 of 10 runs and said
    // so. So FSEvents is held to this claim in
    // src/test_backend_fsevents.zig ("the entry budget is one
    // directory's, with every creation delivered"), with the same
    // creations delivered by hand through the callback the system calls.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (backends) |backend| {
        if (backend == .fsevents) continue;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        for (0..12) |d| {
            var name: [16]u8 = undefined;
            try tmp.dir.createDirPath(io, std.fmt.bufPrint(&name, "d{d}", .{d}) catch unreachable);
        }

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 512,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{ .recursive = true });
        while ((try watcher.poll(200)).len != 0) {}

        // Drained as it goes, so that what is being measured is the
        // budget and not the kernel's own patience with a burst.
        var tally: Tally = .{};
        for (0..12) |d| {
            for (0..150) |i| {
                var name: [32]u8 = undefined;
                try tmp.dir.writeFile(io, .{
                    .sub_path = std.fmt.bufPrint(&name, "d{d}/f{d}.txt", .{ d, i }) catch unreachable,
                    .data = "x",
                });
            }
            try tally.drain(&watcher, 200);
        }
        try tally.drain(&watcher, 400);
        if (tally.overflow != 0) {
            std.debug.print("{s}: {d} overflow for 12 x 150 under a 512 budget\n", .{
                @tagName(backend), tally.overflow,
            });
        }
        try std.testing.expectEqual(@as(usize, 0), tally.overflow);
    }
}

test "a root deleted and recreated inside one window is not a move" {
    // `lookout.reportsRootMove` says which of three shapes a backend
    // gives when the watched path leaves the name it was added under.
    // A caller switches on it, so it is absolute. The Apple backend
    // decided between `renamed` and `removed` by asking whether the
    // root was there when the delivery was read, and a root deleted and
    // recreated before the read is there: it came back as `renamed`,
    // which is the one shape `reportsRootMove(.fsevents)` says it never
    // gives.
    //
    // What a backend may do here is say nothing at all -- a window
    // short enough closes over both halves, and a backend that learns
    // by listing may never see the gap. What none of them may do is
    // report a shape the predicate does not declare.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (backends) |backend| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        try tmp.dir.createDirPath(io, "target");
        const target = try std.fs.path.join(gpa, &.{ root, "target" });
        defer gpa.free(target);

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = backend,
            .poll_interval_ms = 20,
        });
        defer watcher.deinit();
        _ = try watcher.add(target, .{});
        while ((try watcher.poll(200)).len != 0) {}

        try tmp.dir.deleteDir(io, "target");
        try tmp.dir.createDirPath(io, "target");

        var waited: u32 = 0;
        while (waited < 2_000) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (!std.mem.eql(u8, event.path, target)) continue;
                if (event.kind != .renamed) continue;
                try std.testing.expectEqual(
                    lookout.reportsRootMove(backend),
                    lookout.RootMove.renamed,
                );
            }
        }
    }
}

test "a poll that expires before the replay begins is not the end of it" {
    // The Apple backend ended a resumed watcher's catching up at the
    // first wait that reported nothing, and two waits report nothing
    // while the replay is still coming. One is the wait a poll spends
    // before the stream has said anything at all -- the one written
    // down here, as `poll(0)`. The other is the wait the `HistoryDone`
    // sentinel lands in, which is a delivery that reports no event
    // because nothing happened to a path.
    //
    // Either one ended the catching up one delivery early, and the
    // changes made while nothing was watching arrive after it: a change
    // the system had not written to its log when the stream started is
    // delivered live and numbered after the sentinel. With the catching
    // up already over, a path that is gone and that lookout has never
    // heard of is a path that came and went between two polls, and the
    // deletion was dropped -- the half of `Options.checkpoint` a watcher
    // that only looks forward cannot report, and the reason the option
    // exists.
    if (!lookout.tracksCheckpoint(lookout.default_backend)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "one" });

    var token: []u8 = undefined;
    defer gpa.free(token);
    {
        var watcher: Watcher = try .init(gpa, io, .{});
        defer watcher.deinit();
        _ = try watcher.add(root, .{ .recursive = true });
        while ((try watcher.poll(200)).len != 0) {}
        var checkpoint = (try watcher.checkpoint(gpa)).?;
        defer checkpoint.deinit();
        token = try checkpoint.token(gpa);
    }

    try tmp.dir.deleteFile(io, "gone.txt");

    var checkpoint = try lookout.Checkpoint.parse(gpa, token);
    defer checkpoint.deinit();
    var watcher: Watcher = try .init(gpa, io, .{ .checkpoint = checkpoint });
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });

    const deleted = try std.fs.path.join(gpa, &.{ root, "gone.txt" });
    defer gpa.free(deleted);

    var saw_deleted = false;
    // The boundary, stated: a non-blocking wait issued immediately after
    // the stream starts. With immediate FSEvents delivery the replay may
    // win that race, so consume anything it already brought rather than
    // assuming the boundary must be empty.
    for (try watcher.poll(0)) |event| {
        if (std.mem.eql(u8, event.path, deleted) and event.kind == .removed) saw_deleted = true;
    }

    var waited: u32 = 0;
    while (waited < timeout_ms and !saw_deleted) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (std.mem.eql(u8, event.path, deleted) and event.kind == .removed) saw_deleted = true;
        }
    }
    try std.testing.expect(saw_deleted);
}

test "the inotify queue filled past its limit is one overflow, and the watch goes on" {
    // The cross-backend `overflow` guarantee, from a kernel that really
    // lost something. `/proc/sys/fs/inotify/max_queued_events` bounds
    // the queue of one inotify instance -- 16384 by default -- and past
    // it "events in excess of this limit are dropped, but an
    // IN_Q_OVERFLOW event is always generated" (inotify(7)). Nothing
    // polls while the burst is written, so every creation queues, and
    // one more creation than the queue holds is a queue that overflowed
    // whatever else each creation produced.
    if (!lookout.supported(.inotify)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const limit: usize = limit: {
        var buffer: [32]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(io, "/proc/sys/fs/inotify/max_queued_events", &buffer) catch
            break :limit 16_384;
        break :limit std.fmt.parseInt(usize, std.mem.trim(u8, text, " \n"), 10) catch 16_384;
    };
    // A host tuned far past the default would take this test minutes
    // to fill, and what it asserts is the kernel's contract, not the
    // host's setting.
    if (limit > 100_000) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var watcher: Watcher = try .init(gpa, io, .{
        .backend = .inotify,
        .max_dir_entries = 1_000_000,
        .max_events = 0,
    });
    defer watcher.deinit();
    _ = try watcher.add(root, .{});
    while ((try watcher.poll(200)).len != 0) {}

    try writeBurst(tmp.dir, limit + 1);

    // The kernel keeps one overflow record and queues it once, however
    // much was dropped while it sat there.
    var tally: Tally = .{};
    try tally.drain(&watcher, 1_000);
    try std.testing.expectEqual(@as(usize, 1), tally.overflow);
    try std.testing.expect(tally.created <= limit);

    // The watch is what it was: what happens next is reported.
    try tmp.dir.writeFile(io, .{ .sub_path = "after.txt", .data = "x" });
    const after = try std.fs.path.join(gpa, &.{ root, "after.txt" });
    defer gpa.free(after);
    var found = false;
    var waited: u32 = 0;
    while (waited < timeout_ms and !found) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind == .created and std.mem.eql(u8, event.path, after)) found = true;
        }
    }
    try std.testing.expect(found);
}

// Last in the file on purpose. Ten thousand files created and then
// deleted is enough churn that the operating system loses track of what
// a watcher started just afterwards is looking at, and a test that
// asserts what a watcher remembers has no business running in that
// wake.
test "the delivery buffer is the size the caller asked for" {
    // The Apple backend held deliveries in a fixed 64 KiB buffer, which
    // at about a hundred and ten bytes a record is room for some six
    // hundred paths: a ten-thousand file burst lost 95% of itself and
    // said so as one `overflow`. The size is now the caller's, and the
    // default holds the burst.
    //
    // Nothing polls while the burst is delivered, so what the delivery
    // thread holds is read without draining it (`copyHeld`), and each
    // half waits for the delivery it is about rather than for a quiet
    // spell. A quiet spell is not the end of a burst: fseventsd was
    // measured pausing up to eight seconds in the middle of one, and
    // after losing track it reports the files it rescanned late and out
    // of order, after a file created once the burst was written.
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    if (!lookout.supported(.fsevents)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const burst = 10_000;

    // At the floor: the buffer turns deliveries away once it is full, and
    // the one poll after that reports what it held and the loss.
    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = .fsevents,
            .buffer_bytes = 64 * 1024,
            .max_dir_entries = 1_000_000,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{});
        try writeBurst(tmp.dir, burst);

        const held = try Held.await(&watcher, burst, .overflowed);
        try std.testing.expect(held.overflowed);

        var tally: Tally = .{};
        tally.count(try watcher.poll(0));
        try std.testing.expect(tally.overflow > 0);
        try std.testing.expect(tally.created < burst);
    }

    // At the default: room for all of it. The system either delivers
    // every file or says it lost track, which it does under load; either
    // way lookout's own buffer turns nothing away, and every file
    // delivered is reported. Nothing is printed on the way: a test that
    // writes to standard error is shown by the build runner as a failed
    // command, whatever it returns.
    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = .fsevents,
            .max_dir_entries = 1_000_000,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{});
        try writeBurst(tmp.dir, burst);

        const held = try Held.await(&watcher, burst, .delivered);
        try std.testing.expect(!held.overflowed);

        var tally: Tally = .{};
        tally.count(try watcher.poll(0));
        // What a caller is promised: every file, or an `overflow` saying
        // that some are missing. A file lost without one is a bug.
        if (tally.created != burst) try std.testing.expect(tally.overflow > 0);
        // And the overflow is the system's: reported when it said it lost
        // track, and only then, since lookout's buffer lost nothing.
        try std.testing.expectEqual(held.lost_track, tally.overflow > 0);
        // What arrived between the look and the poll is reported too.
        try std.testing.expect(tally.created >= held.created);
        try std.testing.expect(tally.created <= burst);
    }
}

/// What the Apple backend's delivery thread holds of a `writeBurst`, read
/// without draining it. See `the delivery buffer is the size the caller
/// asked for`.
const Held = struct {
    /// Distinct burst files the system has reported created.
    created: usize,
    /// The system said it lost track: `MustScanSubDirs` or a dropped flag.
    lost_track: bool,
    /// lookout's own buffer turned a delivery away.
    overflowed: bool,

    const Until = enum {
        /// lookout's buffer has turned a delivery away.
        overflowed,
        /// Every file has been delivered, the system has said it lost
        /// track, or lookout's buffer has turned a delivery away.
        delivered,
    };

    /// How long the system is given to deliver the burst before the test
    /// fails. A bound on a failure, not the end of the wait: the wait
    /// ends on the delivery. The slowest whole delivery measured was
    /// under ten seconds.
    const budget_ms = 60_000;

    fn await(watcher: *Watcher, burst: usize, until: Until) !Held {
        const records = @import("backend/fsevents_records.zig");
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, burst);
        defer seen.deinit(gpa);

        var waited: u32 = 0;
        while (true) : (waited += 20) {
            const copy = try watcher.impl.fsevents.copyHeld(gpa);
            defer gpa.free(copy.bytes);
            var held: Held = .{ .created = 0, .lost_track = false, .overflowed = copy.overflowed };
            seen.unsetAll();
            var it = records.iterate(copy.bytes);
            while (try it.next()) |record| {
                const lost = records.flag.must_scan_sub_dirs | records.flag.user_dropped | records.flag.kernel_dropped;
                if (record.flags & lost != 0) held.lost_track = true;
                if (record.flags & records.flag.item_created == 0) continue;
                const name = std.fs.path.basename(record.path);
                if (!std.mem.startsWith(u8, name, "burst-entry-")) continue;
                const number = name["burst-entry-".len .. name.len - ".txt".len];
                const i = std.fmt.parseInt(usize, number, 10) catch continue;
                if (i < burst and !seen.isSet(i)) {
                    seen.set(i);
                    held.created += 1;
                }
            }
            const done = switch (until) {
                .overflowed => held.overflowed,
                .delivered => held.overflowed or held.lost_track or held.created == burst,
            };
            if (done) return held;
            if (waited >= budget_ms) {
                std.debug.print("fsevents: {d}/{d} delivered in {d} ms, and no loss reported\n", .{ held.created, burst, waited });
                return error.TestBurstNotDelivered;
            }
            try std.Io.sleep(io, .fromMilliseconds(20), .awake);
        }
    }
};

// A fresh watcher for each failure index makes every allocation in its
// first delivery fallible, including allocations after a reported prefix.
test "allocation failure during delivery on polling never leaves a quiet retry" {
    try deliveryFailure(.poll);
}

test "allocation failure during delivery on kqueue never leaves a quiet retry" {
    try deliveryFailure(.kqueue);
}

test "allocation failure during delivery on FSEvents never leaves a quiet retry" {
    try deliveryFailure(.fsevents);
}

test "allocation failure during delivery on inotify never leaves a quiet retry" {
    try deliveryFailure(.inotify);
}

test "allocation failure during delivery on Windows never leaves a quiet retry" {
    try deliveryFailure(.windows);
}

fn deliveryFailure(backend: lookout.Backend) !void {
    if (!lookout.supported(backend)) return error.SkipZigTest;
    const testing = std.testing;
    for ([_]enum { create, rename, remove, modify, adopt }{ .create, .rename, .remove, .modify, .adopt }) |scenario| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var tmp = testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
            defer testing.allocator.free(root);
            if (scenario != .create and scenario != .adopt) {
                try tmp.dir.writeFile(testing.io, .{ .sub_path = "first", .data = "old" });
                try tmp.dir.writeFile(testing.io, .{ .sub_path = "last", .data = "old" });
            }
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var watcher = try Watcher.init(failing.allocator(), testing.io, .{
                .backend = backend,
                .latency_ms = 0,
                .poll_interval_ms = 1,
            });
            defer watcher.deinit();
            const id = try watcher.add(root, .{ .recursive = true });
            while ((try watcher.poll(0)).len != 0) {}
            switch (scenario) {
                .create, .modify => {
                    try tmp.dir.writeFile(testing.io, .{ .sub_path = "first", .data = "one more" });
                    try tmp.dir.writeFile(testing.io, .{ .sub_path = "last", .data = "two more" });
                },
                .rename => {
                    try tmp.dir.rename("first", tmp.dir, "first-moved", testing.io);
                    try tmp.dir.rename("last", tmp.dir, "last-moved", testing.io);
                },
                .remove => {
                    try tmp.dir.deleteFile(testing.io, "first");
                    try tmp.dir.deleteFile(testing.io, "last");
                },
                .adopt => {
                    try tmp.dir.createDirPath(testing.io, "child/deeper");
                    try tmp.dir.writeFile(testing.io, .{ .sub_path = "child/first", .data = "one" });
                    try tmp.dir.writeFile(testing.io, .{ .sub_path = "child/deeper/last", .data = "two" });
                },
            }
            failing.fail_index = failing.alloc_index + fail_index;
            const answer = watcher.poll(timeout_ms);
            failing.fail_index = std.math.maxInt(usize);
            if (answer) |events| {
                try testing.expect(events.len != 0);
                break;
            } else |err| try testing.expectEqual(error.OutOfMemory, err);

            // A wake must not let a retry return before its loss notice.
            watcher.wake();
            var first = false;
            var last = false;
            var overflow = false;
            for (try watcher.poll(0)) |event| {
                try testing.expectEqual(id, event.id);
                if (event.kind == .overflow) {
                    try testing.expectEqualStrings(root, event.path);
                    overflow = true;
                }
                if (std.mem.endsWith(u8, event.path, "first")) first = true;
                if (std.mem.endsWith(u8, event.path, "last")) last = true;
            }
            // Already collected events alone cannot claim the delivery
            // was complete when a later allocation lost its tail.
            try testing.expect(overflow or (first and last));
            // Finishing the retained delivery must also rearm the backend.
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "after", .data = "three" });
            var saw_after = false;
            var waited: u32 = 0;
            while (!saw_after and waited < timeout_ms) : (waited += 200) {
                for (try watcher.poll(200)) |event| {
                    if (event.kind == .created and std.mem.endsWith(u8, event.path, "after")) saw_after = true;
                }
            }
            try testing.expect(saw_after);
        }
        try testing.expect(fail_index > 0);
    }
}

test "allocation failure during delivery keeps every root pending through failed recovery" {
    const testing = std.testing;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "a");
        try tmp.dir.createDirPath(testing.io, "b");
        const a = try tmp.dir.realPathFileAlloc(testing.io, "a", testing.allocator);
        defer testing.allocator.free(a);
        const b = try tmp.dir.realPathFileAlloc(testing.io, "b", testing.allocator);
        defer testing.allocator.free(b);
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var watcher = try Watcher.init(failing.allocator(), testing.io, .{
            .backend = .poll,
            .debounce_ms = 60_000,
            .latency_ms = 0,
        });
        defer watcher.deinit();
        const first = try watcher.add(a, .{});
        const last = try watcher.add(b, .{});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/change", .data = "x" });
        failing.fail_index = failing.alloc_index;
        try testing.expectError(error.OutOfMemory, watcher.poll(0));
        failing.fail_index = failing.alloc_index + fail_index;
        watcher.wake();
        const answer = watcher.poll(0);
        failing.fail_index = std.math.maxInt(usize);
        if (answer) |events| {
            try expectRecoveredRoots(events, first, last);
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
        watcher.wake();
        try expectRecoveredRoots(try watcher.poll(0), first, last);
        watcher.remove(first);
        try testing.expectEqual(@as(usize, 0), (try watcher.poll(0)).len);
    }
    try testing.expect(fail_index > 0);
}

fn expectRecoveredRoots(events: []const lookout.Event, first: lookout.WatchId, last: lookout.WatchId) !void {
    var saw_first = false;
    var saw_last = false;
    for (events) |event| {
        try std.testing.expectEqual(Kind.overflow, event.kind);
        if (event.id == first) saw_first = true;
        if (event.id == last) saw_last = true;
    }
    try std.testing.expect(saw_first and saw_last);
}

test "recovery remains visible while a watch is waiting for its path" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const waiting = try std.fs.path.join(testing.allocator, &.{ root, "later" });
    defer testing.allocator.free(waiting);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var watcher = try Watcher.init(failing.allocator(), testing.io, .{
        .backend = .poll,
        .latency_ms = 20,
        .poll_interval_ms = 1,
    });
    defer watcher.deinit();
    const id = try watcher.add(waiting, .{ .pending = true });
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, watcher.poll(0));
    failing.fail_index = std.math.maxInt(usize);
    const events = try watcher.poll(1);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(id, events[0].id);
    try testing.expectEqual(Kind.overflow, events[0].kind);
    try testing.expectEqualStrings(waiting, events[0].path);
}
