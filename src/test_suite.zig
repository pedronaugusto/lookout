//! One suite, run once per backend this target can execute.
//!
//! The point of the repetition is the package's central claim: a program
//! written against `lookout.Watcher` sees the same events whichever
//! mechanism is underneath. A behaviour that only the kernel backend has
//! is a behaviour a caller cannot rely on, so it does not belong in the
//! contract, and the way to keep it out is to hold the `poll` backend to
//! the same assertions on the same machine.

const std = @import("std");
const lookout = @import("lookout.zig");

const Kind = lookout.Kind;
const Watcher = lookout.Watcher;

/// Every backend this target was built with. The suite runs whole
/// against each of them, which is the package's central claim made
/// checkable: a program written against `lookout.Watcher` sees the same
/// events whichever mechanism is underneath.
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

/// Long enough that a loaded machine still gets there, short enough that
/// the suite stays a suite. Nothing waits a fixed time: every assertion
/// polls until the event arrives or this expires.
const timeout_ms = 5_000;

/// A temporary directory, a watcher, and the plumbing to ask it questions.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    watcher: Watcher,
    /// `Event.from` of the last event `expectEvents` matched, copied
    /// before the next poll invalidates it.
    seen_from: ?[]u8,

    fn init(backend: lookout.Backend) !Fixture {
        // A short interval keeps the poll backend's latency in the same
        // order as the kernel backends' so one timeout fits both.
        return initOptions(.{ .backend = backend, .poll_interval_ms = 20 });
    }

    fn initOptions(options: lookout.Options) !Fixture {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();

        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(root);

        return .{
            .tmp = tmp,
            .root = root,
            .watcher = try .init(gpa, io, options),
            .seen_from = null,
        };
    }

    fn deinit(f: *Fixture) void {
        f.watcher.deinit();
        if (f.seen_from) |from| std.testing.allocator.free(from);
        std.testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn write(f: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    /// The absolute path an event for `sub_path` will carry.
    ///
    /// The suite writes its sub-paths with `/`, which is not what an
    /// event carries on Windows: a path is spelled with the platform's
    /// separator all the way down, so the expectation has to be built
    /// component by component rather than by pasting the two together.
    fn path(f: *Fixture, sub_path: []const u8) ![]u8 {
        const gpa = std.testing.allocator;
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        try parts.append(gpa, f.root);
        var it = std.mem.splitScalar(u8, sub_path, '/');
        while (it.next()) |part| try parts.append(gpa, part);
        return std.fs.path.join(gpa, parts.items);
    }

    /// One event the suite is waiting for.
    const Want = struct { sub_path: []const u8, kind: Kind };

    /// Polls until `sub_path` is reported with `kind`, or gives up.
    ///
    /// Waiting for a specific event rather than for a fixed time is what
    /// makes the suite the same on a fast kernel backend and on a backend
    /// that only looks every 20 ms.
    fn expectEvent(f: *Fixture, sub_path: []const u8, kind: Kind) !void {
        return f.expectEvents(&.{.{ .sub_path = sub_path, .kind = kind }});
    }

    /// Polls until every one of `wants` has been reported, or gives up.
    ///
    /// One call rather than one per event, because a single poll can
    /// return several of them and the caller must not throw the rest
    /// away: one rename is a removal and a creation in the same window.
    fn expectEvents(f: *Fixture, wants: []const Want) !void {
        const gpa = std.testing.allocator;
        const paths = try gpa.alloc([]u8, wants.len);
        defer {
            for (paths) |p| gpa.free(p);
            gpa.free(paths);
        }
        for (wants, paths) |want, *p| p.* = try f.path(want.sub_path);

        const seen = try gpa.alloc(bool, wants.len);
        defer gpa.free(seen);
        @memset(seen, false);

        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                for (wants, paths, seen) |want, p, *hit| {
                    if (event.kind != want.kind or !std.mem.eql(u8, event.path, p)) continue;
                    hit.* = true;
                    if (event.from) |from| {
                        if (f.seen_from) |old| gpa.free(old);
                        f.seen_from = try gpa.dupe(u8, from);
                    }
                }
            }
            if (std.mem.allEqual(bool, seen, true)) return;
        }
        for (wants, paths, seen) |want, p, hit| {
            if (!hit) std.debug.print("no {s} event for {s} within {d} ms\n", .{
                @tagName(want.kind), p, timeout_ms,
            });
        }
        return error.EventNotObserved;
    }

    /// Drains whatever is pending so the next assertion starts clean.
    fn settle(f: *Fixture) !void {
        while ((try f.watcher.poll(120)).len != 0) {}
    }
};

test "a fresh watch reports nothing that was already there as new" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("a.txt", "one");
        try f.tmp.dir.createDirPath(std.testing.io, "sub");
        try f.write("sub/deep.txt", "two");

        _ = try f.watcher.add(f.root, .{ .recursive = true });

        // A watch is about what changes from now on, so nothing that was
        // there when it was taken may arrive as a creation, and the
        // watched directory itself is not news at all. On a backend that
        // is handed accumulated flags rather than a sequence of facts,
        // that is the harder half of the contract.
        for (try f.watcher.poll(400)) |event| {
            try std.testing.expect(event.kind != .created);
            try std.testing.expect(!std.mem.eql(u8, event.path, f.root));
        }
    }
}

test "a file appearing in a watched directory is created" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{});

        try f.write("a.txt", "one");
        try f.expectEvent("a.txt", .created);
    }
}

test "a file written in a watched directory is modified" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("a.txt", "one");
        _ = try f.watcher.add(f.root, .{});
        try f.settle();

        try f.write("a.txt", "one and two");
        try f.expectEvent("a.txt", .modified);
    }
}

test "a file deleted from a watched directory is removed" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("a.txt", "one");
        _ = try f.watcher.add(f.root, .{});
        try f.settle();

        try f.tmp.dir.deleteFile(std.testing.io, "a.txt");
        try f.expectEvent("a.txt", .removed);
    }
}

test "a rename is reported in the shape the backend documents" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("before.txt", "one");
        _ = try f.watcher.add(f.root, .{});
        try f.settle();

        try f.tmp.dir.rename("before.txt", f.tmp.dir, "after.txt", std.testing.io);

        // The two shapes describe the same thing happening. Which one a
        // backend produces is `lookout.pairsRenames`, and it is asserted
        // rather than accepted either way: a table in the README nobody
        // checks is a table that goes stale.
        if (lookout.pairsRenames(backend)) {
            try f.expectEvents(&.{.{ .sub_path = "after.txt", .kind = .renamed }});
            const from = try f.path("before.txt");
            defer std.testing.allocator.free(from);
            try std.testing.expectEqualStrings(from, f.seen_from.?);
        } else {
            try f.expectEvents(&.{
                .{ .sub_path = "before.txt", .kind = .removed },
                .{ .sub_path = "after.txt", .kind = .created },
            });
        }
    }
}

test "settling holds a modification back until the writing stops" {
    // The poll backend only: this is about the clock, and the clock is
    // the one thing a kernel backend adds jitter to. What is being
    // tested lives in `Batch` and is the same code under every backend.
    var f = try Fixture.initOptions(.{
        .backend = .poll,
        .poll_interval_ms = 20,
        .settle_ms = 400,
        .latency_ms = 0,
    });
    defer f.deinit();
    try f.write("a.txt", "one");
    _ = try f.watcher.add(f.root, .{});
    try f.settle();

    const gpa = std.testing.allocator;
    const wanted = try f.path("a.txt");
    defer gpa.free(wanted);

    // Four writes inside the settle window, each a different length so no
    // backend can miss one for want of clock resolution.
    const chunks = [_][]const u8{ "two.", "three..", "four....", "five....." };
    const started: std.Io.Timestamp = .now(std.testing.io, .awake);
    for (chunks) |chunk| {
        try f.write("a.txt", chunk);
        _ = try f.watcher.poll(40);
    }

    var seen: usize = 0;
    var waited: u32 = 0;
    while (waited < timeout_ms and seen == 0) : (waited += 100) {
        for (try f.watcher.poll(100)) |event| {
            if (std.mem.eql(u8, event.path, wanted)) {
                try std.testing.expectEqual(Kind.modified, event.kind);
                seen += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), seen);

    // And it arrived after the window, not during it: a debounce that
    // fires early is not a debounce.
    const elapsed = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake));
    try std.testing.expect(elapsed.toMilliseconds() >= 400);
}

test "a watch on a single file reports writes to it" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("a.txt", "one");

        const target = try f.path("a.txt");
        defer std.testing.allocator.free(target);
        _ = try f.watcher.add(target, .{});
        try f.settle();

        try f.write("a.txt", "one and two");
        try f.expectEvent("a.txt", .modified);
    }
}

test "a burst of writes on one path is one event" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("a.txt", "one");
        _ = try f.watcher.add(f.root, .{});
        try f.settle();

        // Each write leaves a different size, so no backend can miss one
        // for want of clock resolution -- and yet one event is expected.
        try f.write("a.txt", "two.");
        try f.write("a.txt", "three..");
        try f.write("a.txt", "four....");

        const gpa = std.testing.allocator;
        const wanted = try f.path("a.txt");
        defer gpa.free(wanted);

        var seen: usize = 0;
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 200) {
            const events = try f.watcher.poll(200);
            for (events) |event| {
                if (std.mem.eql(u8, event.path, wanted)) seen += 1;
            }
            if (seen != 0) break;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

test "removing a watch stops its events" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const id = try f.watcher.add(f.root, .{});
        try f.write("a.txt", "one");
        try f.expectEvent("a.txt", .created);

        f.watcher.remove(id);
        try f.settle();

        try f.write("b.txt", "two");
        try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(400)).len);
    }
}

test "a recursive watch follows directories created after it" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{ .recursive = true });

        try f.tmp.dir.createDirPath(std.testing.io, "sub");
        try f.expectEvent("sub", .created);

        try f.write("sub/deep.txt", "one");
        try f.expectEvent("sub/deep.txt", .created);
    }
}

test "a directory that arrives with a tree in it reports the tree" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{ .recursive = true });
        try f.settle();

        // Built in one go, with no poll in between for the watcher to
        // register the directory before it has anything in it -- an
        // archive unpacked, a build writing a tree. Whatever is inside
        // when lookout first sees the directory is new, and a watcher
        // that took it for a baseline would report none of it and would
        // not watch the directories among it either.
        try f.tmp.dir.createDirPath(std.testing.io, "tree/deep");
        try f.write("tree/a.txt", "one");
        try f.write("tree/deep/b.txt", "two");

        try f.expectEvents(&.{
            .{ .sub_path = "tree", .kind = .created },
            .{ .sub_path = "tree/a.txt", .kind = .created },
            .{ .sub_path = "tree/deep", .kind = .created },
            .{ .sub_path = "tree/deep/b.txt", .kind = .created },
        });

        // And the deepest of them is watched, not merely listed once.
        try f.settle();
        try f.write("tree/deep/c.txt", "three");
        try f.expectEvent("tree/deep/c.txt", .created);
    }
}

test "a non-recursive watch ignores what happens below it" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "sub");
        _ = try f.watcher.add(f.root, .{});
        try f.settle();

        try f.write("sub/deep.txt", "one");

        const gpa = std.testing.allocator;
        const wanted = try f.path("sub/deep.txt");
        defer gpa.free(wanted);
        for (try f.watcher.poll(400)) |event| {
            try std.testing.expect(!std.mem.eql(u8, event.path, wanted));
        }
    }
}

test "an ignored subtree is watched by nobody" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "keep");
        try f.tmp.dir.createDirPath(std.testing.io, "skip/deeper");

        _ = try f.watcher.add(f.root, .{
            .recursive = true,
            .filter = .{ .ignore = &.{ "skip", "*.tmp" } },
        });
        try f.settle();

        const gpa = std.testing.allocator;
        const ignored = try f.path("skip");
        defer gpa.free(ignored);
        const scratch = try f.path("keep/notes.tmp");
        defer gpa.free(scratch);
        const wanted = try f.path("keep/notes.txt");
        defer gpa.free(wanted);

        try f.write("skip/a.txt", "one");
        try f.write("skip/deeper/b.txt", "two");
        try f.write("keep/notes.tmp", "three");
        try f.write("keep/notes.txt", "four");

        // Every poll until the wanted event arrives is also an assertion:
        // nothing from the ignored subtree, and nothing matching the
        // ignored glob, may appear in any of them.
        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(!std.mem.startsWith(u8, event.path, ignored));
                try std.testing.expect(!std.mem.eql(u8, event.path, scratch));
                if (event.kind == .created and std.mem.eql(u8, event.path, wanted)) found = true;
            }
        }
        try std.testing.expect(found);
    }
}

/// Excludes anything whose name starts with a dot, which is the kind of
/// rule a pattern list cannot state and a caller can.
fn notHidden(context: ?*anyopaque, path: []const u8) bool {
    _ = context;
    return !std.mem.startsWith(u8, std.fs.path.basename(path), ".");
}

test "a caller predicate excludes what a pattern cannot say" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, ".hidden");

        _ = try f.watcher.add(f.root, .{
            .recursive = true,
            .filter = .{ .allow = notHidden },
        });
        try f.settle();

        const gpa = std.testing.allocator;
        const hidden = try f.path(".hidden");
        defer gpa.free(hidden);
        const wanted = try f.path("visible.txt");
        defer gpa.free(wanted);

        try f.write(".hidden/a.txt", "one");
        try f.write("visible.txt", "two");

        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(!std.mem.startsWith(u8, event.path, hidden));
                if (event.kind == .created and std.mem.eql(u8, event.path, wanted)) found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "an ignored subtree costs nothing where lookout does the recursion" {
    for (backends) |backend| {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        try tmp.dir.createDirPath(io, "keep");
        try tmp.dir.createDirPath(io, "skip/one");
        try tmp.dir.createDirPath(io, "skip/two");

        var plain: Watcher = try .init(gpa, io, .{ .backend = backend, .poll_interval_ms = 20 });
        defer plain.deinit();
        _ = try plain.add(root, .{ .recursive = true });

        var filtered: Watcher = try .init(gpa, io, .{ .backend = backend, .poll_interval_ms = 20 });
        defer filtered.deinit();
        _ = try filtered.add(root, .{
            .recursive = true,
            .filter = .{ .ignore = &.{"skip"} },
        });

        // The claim in README.md, asserted rather than described: where
        // lookout recurses, an excluded directory is never registered;
        // where the kernel recurses, it was never told and the filter
        // can only drop the events.
        if (lookout.prunesIgnored(backend)) {
            try std.testing.expect(filtered.stats().registrations < plain.stats().registrations);
        } else {
            try std.testing.expectEqual(
                plain.stats().registrations,
                filtered.stats().registrations,
            );
        }
    }
}

test "a directory past the entry limit reports overflow against the watch root" {
    for (backends) |backend| {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 2,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{});

        for (0..6) |i| {
            var name: [8]u8 = undefined;
            try tmp.dir.writeFile(io, .{
                .sub_path = std.fmt.bufPrint(&name, "f{d}", .{i}) catch unreachable,
                .data = "x",
            });
        }

        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (event.kind == .overflow and std.mem.eql(u8, event.path, root)) found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "the descriptor is present exactly when the backend has one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var polling: Watcher = try .init(gpa, io, .{ .backend = .poll });
    defer polling.deinit();
    try std.testing.expectEqual(lookout.Backend.poll, polling.backend());
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), polling.fd());

    for (backends) |backend| {
        if (backend == .poll) continue;
        var kernel: Watcher = try .init(gpa, io, .{ .backend = backend });
        defer kernel.deinit();
        try std.testing.expectEqual(backend, kernel.backend());
        // Windows waits on a completion port, which nothing else can
        // wait on, so it has no descriptor to give either.
        try std.testing.expectEqual(backend != .windows, kernel.fd() != null);
    }
}

test "a backend this target was not built with is refused, not a compile error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const absent: lookout.Backend = if (lookout.supported(.inotify)) .kqueue else .inotify;
    try std.testing.expect(!lookout.supported(absent));
    try std.testing.expectError(
        error.BackendUnavailable,
        Watcher.init(gpa, io, .{ .backend = absent }),
    );
}

test "one watcher watches a path once" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{});
        try std.testing.expectError(
            error.PathAlreadyWatched,
            f.watcher.add(f.root, .{}),
        );
    }
}

test "a zero timeout is one check, not a refusal to look" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{});
        // Nothing has happened, so a zero timeout must come straight back
        // empty rather than block.
        try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(0)).len);

        try f.write("a.txt", "one");

        // And it must still ask the kernel. A zero timeout that returned
        // before making the call reported nothing, ever, which no amount
        // of retrying would have fixed.
        const gpa = std.testing.allocator;
        const wanted = try f.path("a.txt");
        defer gpa.free(wanted);

        const started: std.Io.Timestamp = .now(std.testing.io, .awake);
        var found = false;
        while (!found) {
            for (try f.watcher.poll(0)) |event| {
                if (event.kind == .created and std.mem.eql(u8, event.path, wanted)) found = true;
            }
            const elapsed = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake));
            if (elapsed.toMilliseconds() > timeout_ms) break;
        }
        try std.testing.expect(found);
    }
}

test "adding a path that does not exist fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var watcher: Watcher = try .init(gpa, io, .{});
    defer watcher.deinit();
    try std.testing.expectError(
        error.FileNotFound,
        watcher.add("lookout-no-such-path-exists-here", .{}),
    );
}

test "polling a watcher with nothing to report returns nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var watcher: Watcher = try .init(gpa, io, .{ .poll_interval_ms = 20 });
    defer watcher.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try watcher.poll(100)).len);
}

test "the watched path's own removal is reported against it" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "target");

        const target = try f.path("target");
        defer std.testing.allocator.free(target);
        _ = try f.watcher.add(target, .{});
        try f.settle();

        try f.tmp.dir.deleteDir(std.testing.io, "target");
        try f.expectEvent("target", .removed);
    }
}

test "the watched path's own move is reported in the shape the backend documents" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "target");

        const target = try f.path("target");
        defer std.testing.allocator.free(target);
        _ = try f.watcher.add(target, .{});
        try f.settle();

        try f.tmp.dir.rename("target", f.tmp.dir, "moved", std.testing.io);

        // Three shapes, one fact: the watched path is no longer at the
        // name it was added under. Which one a backend produces is
        // `lookout.reportsRootMove`, and each is asserted rather than
        // accepted either way, so the table in the README cannot go
        // stale without the suite saying so -- the silence included,
        // which is the one a caller would otherwise wait out.
        switch (lookout.reportsRootMove(backend)) {
            .renamed => try f.expectEvent("target", .renamed),
            .removed => try f.expectEvent("target", .removed),
            .silent => {
                var waited: u32 = 0;
                while (waited < 1_000) : (waited += 200) {
                    for (try f.watcher.poll(200)) |event| {
                        try std.testing.expect(!std.mem.eql(u8, event.path, target));
                    }
                }
            },
        }
    }
}

test "stats count what the watcher holds" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "sub");

        try std.testing.expectEqual(@as(usize, 0), f.watcher.stats().watches);
        try std.testing.expectEqual(@as(usize, 0), f.watcher.stats().registrations);

        const id = try f.watcher.add(f.root, .{ .recursive = true });
        const added = f.watcher.stats();
        try std.testing.expectEqual(@as(usize, 1), added.watches);
        // How many registrations one watch costs is the whole difference
        // between the backends -- one stream, one handle, or one per
        // directory -- so the contract is only that it holds at least one
        // and releases all of them.
        try std.testing.expect(added.registrations >= 1);

        f.watcher.remove(id);
        const removed = f.watcher.stats();
        try std.testing.expectEqual(@as(usize, 0), removed.watches);
        try std.testing.expectEqual(@as(usize, 0), removed.registrations);
    }
}

test "an event carries when it was seen" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{});

        const before: std.Io.Timestamp = .now(std.testing.io, .awake);
        try f.write("a.txt", "one");
        try f.expectEvent("a.txt", .created);
        const after: std.Io.Timestamp = .now(std.testing.io, .awake);

        var found = false;
        for (f.watcher.batch.events.items) |event| {
            if (event.kind != .created) continue;
            try std.testing.expect(event.time.nanoseconds >= before.nanoseconds);
            try std.testing.expect(event.time.nanoseconds <= after.nanoseconds);
            found = true;
        }
        try std.testing.expect(found);
    }
}

test "a symbolic link is an entry, not a doorway" {
    // Creating one on Windows needs a privilege the CI runner does not
    // have, and the claim being tested is about the POSIX backends.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "real");
        try f.tmp.dir.symLink(std.testing.io, "real", "link", .{ .is_directory = true });

        _ = try f.watcher.add(f.root, .{ .recursive = true });
        try f.settle();

        try f.write("real/inside.txt", "one");
        try f.expectEvent("real/inside.txt", .created);

        // The same file is reachable through the link. A watcher that
        // followed links would report it twice, under two names, and a
        // watch would silently widen into a tree nobody asked for.
        const gpa = std.testing.allocator;
        const through_link = try f.path("link");
        defer gpa.free(through_link);
        var waited: u32 = 0;
        while (waited < 600) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(!std.mem.startsWith(u8, event.path, through_link) or
                    event.path.len == through_link.len);
            }
        }
    }
}

test "debouncing reports one event per path carrying the kind seen last" {
    // The poll backend only: this is about the clock, and the clock is
    // the one thing a kernel backend adds jitter to. What is being
    // tested lives in `Batch` and is the same code under every backend.
    var f = try Fixture.initOptions(.{
        .backend = .poll,
        .poll_interval_ms = 20,
        .debounce_ms = 300,
        .latency_ms = 0,
    });
    defer f.deinit();
    _ = try f.watcher.add(f.root, .{});

    const gpa = std.testing.allocator;
    const wanted = try f.path("a.txt");
    defer gpa.free(wanted);

    // The file appears and is then written. Coalescing would report
    // `created`, which outranks `modified`; a debounce reports the end
    // state, which is the whole point of having both.
    try f.write("a.txt", "one");
    try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(100)).len);
    try f.write("a.txt", "one and two");

    var seen: usize = 0;
    var kind: Kind = undefined;
    var waited: u32 = 0;
    while (waited < timeout_ms and seen == 0) : (waited += 100) {
        for (try f.watcher.poll(100)) |event| {
            if (!std.mem.eql(u8, event.path, wanted)) continue;
            kind = event.kind;
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
    try std.testing.expectEqual(Kind.modified, kind);
}

test "the watch limit is one error, named the same on every backend" {
    // Exhausting the limit takes a machine configured to have a small
    // one, which a test may not assume. What a test can hold is the
    // shape: one error, in the set `add` publishes, whichever backend is
    // underneath -- so a caller writes one arm and not five.
    const set = @typeInfo(Watcher.AddError).error_set.?;
    var named = false;
    for (set) |err| {
        if (std.mem.eql(u8, err.name, "WatchLimitReached")) named = true;
    }
    try std.testing.expect(named);
}
