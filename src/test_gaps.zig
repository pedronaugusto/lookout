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

        var kind: ?Kind = null;
        waited = 0;
        while (waited < timeout_ms and kind == null) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (event.kind == .overflow) lost = true;
                if (std.mem.eql(u8, event.path, wanted)) kind = event.kind;
            }
        }
        if (lost) continue;
        if (kind != Kind.modified) {
            std.debug.print("{s}: {?s} after a directory rename\n", .{
                @tagName(backend), if (kind) |k| @tagName(k) else null,
            });
        }
        try std.testing.expectEqual(Kind.modified, kind.?);
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
    if (!lookout.pairsRenames(lookout.default_backend)) return error.SkipZigTest;

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
        .backend = lookout.default_backend,
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
            .renamed => if (event.from != null) {
                renamed += 1;
            } else {
                unpaired += 1;
            },
            .created, .removed => unpaired += 1,
            .overflow => overflow += 1,
            else => {},
        };
    }
    // A kernel that lost track of the burst says so, and what it lost is
    // not this test's to make claims about. What is being tested is the
    // record when it is complete.
    if (overflow != 0) return error.SkipZigTest;
    if (unpaired != 0) std.debug.print("{d} paired, {d} unpaired\n", .{ renamed, unpaired });
    try std.testing.expectEqual(@as(usize, 0), unpaired);
    try std.testing.expectEqual(pairs, renamed);
}

test "the entry budget is one directory's, not a whole recursive watch's" {
    // `max_dir_entries` is documented as the entries of one watched
    // directory. The Windows backend counted every creation anywhere
    // under a recursive root against one number, so twelve directories
    // of a hundred and fifty entries overflowed a budget none of them
    // reached.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (backends) |backend| {
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
    // deletion was dropped -- the half of `Options.since` a watcher
    // that only looks forward cannot report, and the reason the option
    // exists.
    if (!lookout.tracksPosition(lookout.default_backend)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "one" });

    var token: [lookout.Position.max_token_len]u8 = undefined;
    var written: usize = 0;
    {
        var watcher: Watcher = try .init(gpa, io, .{});
        defer watcher.deinit();
        _ = try watcher.add(root, .{ .recursive = true });
        while ((try watcher.poll(200)).len != 0) {}
        written = watcher.position().?.token(&token).len;
    }

    try tmp.dir.deleteFile(io, "gone.txt");

    var watcher: Watcher = try .init(gpa, io, .{
        .since = try lookout.Position.parse(token[0..written]),
    });
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });

    // The boundary, stated: a wait that cannot have brought anything,
    // taken before the replay can have begun.
    try std.testing.expectEqual(@as(usize, 0), (try watcher.poll(0)).len);

    const deleted = try std.fs.path.join(gpa, &.{ root, "gone.txt" });
    defer gpa.free(deleted);

    var saw_deleted = false;
    var waited: u32 = 0;
    while (waited < timeout_ms and !saw_deleted) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (std.mem.eql(u8, event.path, deleted) and event.kind == .removed) saw_deleted = true;
        }
    }
    try std.testing.expect(saw_deleted);
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
    if (!lookout.supported(.fsevents)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const burst = 10_000;

    // At the floor. Nothing polls while the burst is written, so the
    // delivery thread has to hold all of it in the buffer it was given.
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

        var tally: Tally = .{};
        try tally.drain(&watcher, 1_000);
        try std.testing.expect(tally.overflow > 0);
        try std.testing.expect(tally.created < burst);
    }

    // At the default. Room for all of it.
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

        var tally: Tally = .{};
        try tally.drain(&watcher, 1_000);
        if (tally.created != burst) {
            std.debug.print("fsevents: {d}/{d} created, {d} overflow\n", .{
                tally.created, burst, tally.overflow,
            });
        }
        // The operating system can still lose track of a burst this
        // size and say so, which is its answer and not lookout's. What
        // must not happen again is lookout losing nineteen paths in
        // twenty to a buffer the caller could not size.
        if (tally.overflow == 0) {
            try std.testing.expectEqual(burst, tally.created);
        } else {
            try std.testing.expect(tally.created > burst / 2);
        }
    }
}
