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
const trace = @import("trace.zig");

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

        trace.log("suite fixture open backend={s} root={s}", .{ @tagName(options.backend), root });
        return .{
            .tmp = tmp,
            .root = root,
            .watcher = try .init(gpa, io, options),
            .seen_from = null,
        };
    }

    fn deinit(f: *Fixture) void {
        trace.log("suite fixture close root={s}", .{f.root});
        f.watcher.deinit();
        if (f.seen_from) |from| std.testing.allocator.free(from);
        std.testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn write(f: *Fixture, sub_path: []const u8, data: []const u8) !void {
        trace.log("suite write {s}/{s} ({d} bytes)", .{ f.root, sub_path, data.len });
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

        for (wants, paths) |want, p| {
            trace.log("suite want {s} {s}", .{ @tagName(want.kind), p });
        }

        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                trace.log("suite saw {s} {s}", .{ @tagName(event.kind), event.path });
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
            if (!hit) {
                trace.log("suite MISSED {s} {s}", .{ @tagName(want.kind), p });
                std.debug.print("no {s} event for {s} within {d} ms\n", .{
                    @tagName(want.kind), p, timeout_ms,
                });
            }
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

test "inotify does not pair a move across separate watches" {
    if (!lookout.supported(.inotify)) return error.SkipZigTest;

    var f = try Fixture.init(.inotify);
    defer f.deinit();
    try f.tmp.dir.createDirPath(std.testing.io, "a");
    try f.tmp.dir.createDirPath(std.testing.io, "b");
    try f.write("a/file.txt", "one");

    const gpa = std.testing.allocator;
    const a = try f.path("a");
    defer gpa.free(a);
    const b = try f.path("b");
    defer gpa.free(b);
    const old = try f.path("a/file.txt");
    defer gpa.free(old);
    const new = try f.path("b/file.txt");
    defer gpa.free(new);

    const a_id = try f.watcher.add(a, .{});
    const b_id = try f.watcher.add(b, .{});
    try f.settle();
    try f.tmp.dir.rename("a/file.txt", f.tmp.dir, "b/file.txt", std.testing.io);

    var removed = false;
    var created = false;
    var waited: u32 = 0;
    while (waited < timeout_ms and !(removed and created)) : (waited += 200) {
        for (try f.watcher.poll(200)) |event| {
            try std.testing.expect(event.kind != .renamed);
            if (event.id == a_id and event.kind == .removed and std.mem.eql(u8, event.path, old)) {
                removed = true;
            }
            if (event.id == b_id and event.kind == .created and std.mem.eql(u8, event.path, new)) {
                created = true;
            }
        }
    }
    try std.testing.expect(removed);
    try std.testing.expect(created);
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

test "removing a directly watched file reports a file target" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("a.txt", "one");

        const target = try f.path("a.txt");
        defer std.testing.allocator.free(target);
        const id = try f.watcher.add(target, .{});
        try f.settle();
        try f.tmp.dir.deleteFile(std.testing.io, "a.txt");

        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                if (event.id != id or event.kind != .removed or
                    !std.mem.eql(u8, event.path, target)) continue;
                try std.testing.expectEqual(lookout.Target.file, event.target);
                found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "a watch on a file that is already there does not call it new" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("a.txt", "one");

        const gpa = std.testing.allocator;
        const target = try f.path("a.txt");
        defer gpa.free(target);
        _ = try f.watcher.add(target, .{});

        // The same contract as for a directory, and the one a backend
        // that resolves accumulated flags against the file system has to
        // work for: the first thing that happens to a watched file is
        // what happened to it, not its creation.
        try f.write("a.txt", "one and two");
        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                if (!std.mem.eql(u8, event.path, target)) continue;
                try std.testing.expect(event.kind != .created);
                found = true;
            }
        }
        try std.testing.expect(found);
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

test "what an overflow lost can be read back from a baseline" {
    for (backends) |backend| {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        // A budget of two entries, so the sixth file is certain to put
        // the watch past it and the watcher is certain to say so.
        var watcher: Watcher = try .init(gpa, io, .{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 2,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{});

        // Seeded where the watch is taken, which is the only moment the
        // two can be made to agree.
        var base: lookout.Baseline = try .seed(gpa, io, root, .{});
        defer base.deinit(gpa);

        for (0..6) |i| {
            var name: [8]u8 = undefined;
            try tmp.dir.writeFile(io, .{
                .sub_path = std.fmt.bufPrint(&name, "f{d}", .{i}) catch unreachable,
                .data = "x",
            });
        }

        var overflowed = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !overflowed) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (event.kind == .overflow and std.mem.eql(u8, event.path, root)) overflowed = true;
            }
        }
        try std.testing.expect(overflowed);

        // The watcher said its record was incomplete and could not say
        // what was missing. The baseline can: all six, by name.
        var created: usize = 0;
        for (try base.diff(gpa)) |change| {
            if (change.kind == .created) created += 1;
        }
        try std.testing.expectEqual(@as(usize, 6), created);
    }
}

test "a finished write is reported where the backend is told about it" {
    for (backends) |backend| {
        var f = try Fixture.initOptions(.{
            .backend = backend,
            .poll_interval_ms = 20,
            .report_closes = true,
        });
        defer f.deinit();
        try f.write("a.txt", "one");
        _ = try f.watcher.add(f.root, .{});
        try f.settle();

        const gpa = std.testing.allocator;
        const wanted = try f.path("a.txt");
        defer gpa.free(wanted);

        // Writing a file opens it, writes it and closes it, which is the
        // whole of what a backend that is told about closes can see.
        try f.write("a.txt", "one and two");

        var closed = false;
        var otherwise = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !(closed or otherwise)) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                if (!std.mem.eql(u8, event.path, wanted)) continue;
                if (event.kind == .closed) closed = true else otherwise = true;
            }
        }

        // `lookout.reportsCloses` is asserted rather than accepted either
        // way, so a kind that is one backend's truth cannot come to mean
        // nothing in particular on the others: where it is false the
        // write arrives as a write and no `closed` ever comes.
        if (lookout.reportsCloses(backend)) {
            try std.testing.expect(closed);
        } else {
            try std.testing.expect(otherwise);
            try std.testing.expect(!closed);
        }
    }
}

test "closes are not reported unless they are asked for" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("a.txt", "one");
        _ = try f.watcher.add(f.root, .{});
        try f.settle();

        const gpa = std.testing.allocator;
        const wanted = try f.path("a.txt");
        defer gpa.free(wanted);

        try f.write("a.txt", "one and two");

        // The default is the same contract on every backend: a write is
        // `modified`, and the backend that could say more is not asked.
        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(event.kind != .closed);
                if (event.kind == .modified and std.mem.eql(u8, event.path, wanted)) found = true;
            }
        }
        try std.testing.expect(found);
    }
}

/// Writes `count` files with names long enough that the change records
/// the Windows kernel keeps for them are worth measuring: each is twelve
/// bytes and the name in UTF-16.
fn writeBurst(dir: std.Io.Dir, count: usize) !void {
    for (0..count) |i| {
        var name: [96]u8 = undefined;
        const sub_path = std.fmt.bufPrint(
            &name,
            "a-rather-long-name-so-that-one-record-is-not-small-{d}.txt",
            .{i},
        ) catch unreachable;
        try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = "x" });
    }
}

test "the Windows read buffer is the size the caller asked for" {
    // `ReadDirectoryChangesW` is the only backend with a buffer of this
    // kind, and the claim is about what the kernel does with it.
    if (!lookout.supported(.windows)) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const burst = 300;

    // At the floor. Nothing polls while the burst is written, so the
    // kernel has to hold all of it in the buffer it was given, and four
    // kilobytes is a tenth of what it needs.
    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = .windows,
            .buffer_bytes = 4 * 1024,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{});
        try writeBurst(tmp.dir, burst);

        var overflowed = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !overflowed) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (event.kind == .overflow and std.mem.eql(u8, event.path, root)) overflowed = true;
            }
        }
        try std.testing.expect(overflowed);
    }

    // A megabyte, the same burst. Room for all of it, so the caller is
    // told what changed instead of being told to look again.
    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{
            .backend = .windows,
            .buffer_bytes = 1024 * 1024,
        });
        defer watcher.deinit();
        _ = try watcher.add(root, .{});
        try writeBurst(tmp.dir, burst);

        var created: usize = 0;
        var overflowed = false;
        var waited: u32 = 0;
        while (waited < 2_000) : (waited += 200) {
            for (try watcher.poll(200)) |event| {
                if (event.kind == .overflow and std.mem.eql(u8, event.path, root)) overflowed = true;
                if (event.kind == .created) created += 1;
            }
        }
        try std.testing.expect(!overflowed);
        try std.testing.expect(created > 0);
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

test "overlapping watches report the same path under both ids" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "child");

        const gpa = std.testing.allocator;
        const child = try f.path("child");
        defer gpa.free(child);
        const changed = try f.path("child/file.txt");
        defer gpa.free(changed);

        const parent_id = try f.watcher.add(f.root, .{ .recursive = true });
        const child_id = try f.watcher.add(child, .{});
        try f.settle();
        try f.write("child/file.txt", "one");

        var parent_seen = false;
        var child_seen = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !(parent_seen and child_seen)) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                if (event.kind != .created or !std.mem.eql(u8, event.path, changed)) continue;
                if (event.id == parent_id) parent_seen = true;
                if (event.id == child_id) child_seen = true;
            }
        }
        if (!parent_seen or !child_seen) {
            std.debug.print("{s}: parent={any}, child={any}\n", .{
                @tagName(backend), parent_seen, child_seen,
            });
        }
        try std.testing.expect(parent_seen);
        try std.testing.expect(child_seen);
    }
}

test "removing a watch discards events held for a quiet window" {
    for (backends) |backend| {
        var f = try Fixture.initOptions(.{
            .backend = backend,
            .poll_interval_ms = 20,
            .debounce_ms = 300,
        });
        defer f.deinit();
        try f.write("a.txt", "one");
        const id = try f.watcher.add(f.root, .{});
        try f.settle();

        try f.write("a.txt", "two");
        var waited: u32 = 0;
        while (f.watcher.stats().held == 0 and waited < timeout_ms) : (waited += 20) {
            _ = try f.watcher.poll(0);
            if (f.watcher.stats().held == 0) {
                std.testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
            }
        }
        try std.testing.expectEqual(@as(usize, 1), f.watcher.stats().held);

        f.watcher.remove(id);
        try std.testing.expectEqual(@as(usize, 0), f.watcher.stats().held);
        std.testing.io.sleep(.fromMilliseconds(350), .awake) catch {};
        try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(0)).len);
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

test "a path that does not exist yet can be watched" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();

        const gpa = std.testing.allocator;
        const target = try f.path("later/inside");
        defer gpa.free(target);

        // Two levels missing, and the options are the real watch's: they
        // are held until there is something to apply them to.
        const id = try f.watcher.add(target, .{
            .pending = true,
            .recursive = true,
            .filter = .{ .ignore = &.{"skip"} },
        });
        try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(200)).len);

        // The tree appears one level at a time; the watch steps down with
        // it and reports the path it was asked about, not the steps.
        try f.tmp.dir.createDirPath(std.testing.io, "later");
        try f.tmp.dir.createDirPath(std.testing.io, "later/inside");
        try f.expectEvent("later/inside", .created);
        for (f.watcher.batch.events.items) |event| {
            if (std.mem.eql(u8, event.path, target)) {
                try std.testing.expectEqual(id, event.id);
            }
        }

        // The promoted watch is the one watch the watcher holds. A
        // backend that took the parked watch's cancelled registration for
        // the new one's would have closed it again here.
        try std.testing.expectEqual(@as(usize, 1), f.watcher.stats().watches);
        try std.testing.expect(f.watcher.stats().registrations >= 1);
        try f.settle();

        // And it is the real watch now, recursion and filter included.
        try f.tmp.dir.createDirPath(std.testing.io, "later/inside/sub");
        try f.tmp.dir.createDirPath(std.testing.io, "later/inside/skip");
        try f.write("later/inside/skip/hidden.txt", "one");
        try f.write("later/inside/sub/deep.txt", "two");

        const ignored = try f.path("later/inside/skip");
        defer gpa.free(ignored);
        const wanted = try f.path("later/inside/sub/deep.txt");
        defer gpa.free(wanted);

        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(!std.mem.startsWith(u8, event.path, ignored));
                if (event.kind == .created and std.mem.eql(u8, event.path, wanted)) found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "a pending file is promoted with its file target" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();

        const target = try f.path("later.txt");
        defer std.testing.allocator.free(target);
        const id = try f.watcher.add(target, .{ .pending = true });
        try f.write("later.txt", "one");

        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                if (event.id != id or event.kind != .created or
                    !std.mem.eql(u8, event.path, target)) continue;
                try std.testing.expectEqual(lookout.Target.file, event.target);
                found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "what happens to the ancestor of a pending watch is not reported" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();

        const gpa = std.testing.allocator;
        const target = try f.path("later");
        defer gpa.free(target);
        _ = try f.watcher.add(target, .{ .pending = true });

        // The watch is parked on the directory the path will appear in,
        // which is busy with things the caller never asked about.
        try f.write("noise.txt", "one");
        try f.tmp.dir.createDirPath(std.testing.io, "other");
        try f.write("other/more.txt", "two");

        var waited: u32 = 0;
        while (waited < 800) : (waited += 200) {
            try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(200)).len);
        }

        try f.tmp.dir.createDirPath(std.testing.io, "later");
        try f.expectEvent("later", .created);
    }
}

test "a pending watch holds one watch and gives it back" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();

        const gpa = std.testing.allocator;
        const target = try f.path("later");
        defer gpa.free(target);

        const id = try f.watcher.add(target, .{ .pending = true });
        // Parked on an ancestor is still one watch, and one registration
        // -- a caller counting what it holds sees the same thing before
        // and after the path appears.
        try std.testing.expectEqual(@as(usize, 1), f.watcher.stats().watches);
        try std.testing.expect(f.watcher.stats().registrations >= 1);

        f.watcher.remove(id);
        try std.testing.expectEqual(@as(usize, 0), f.watcher.stats().watches);
        try std.testing.expectEqual(@as(usize, 0), f.watcher.stats().registrations);

        // And nothing is left waiting for it: the path appearing now is
        // nobody's business.
        try f.tmp.dir.createDirPath(std.testing.io, "later");
        try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(400)).len);
    }
}

test "a pending watch on a path that is already there is an ordinary watch" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{ .pending = true });
        // No creation is reported for something that was already there.
        for (try f.watcher.poll(200)) |event| {
            try std.testing.expect(event.kind != .created);
        }
        try f.write("a.txt", "one");
        try f.expectEvent("a.txt", .created);
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

test "Windows retires a renamed root before reporting stale child paths" {
    if (!lookout.supported(.windows)) return error.SkipZigTest;

    var f = try Fixture.init(.windows);
    defer f.deinit();
    try f.tmp.dir.createDirPath(std.testing.io, "target");
    const target = try f.path("target");
    defer std.testing.allocator.free(target);
    _ = try f.watcher.add(target, .{ .recursive = true });
    try f.settle();

    try f.tmp.dir.rename("target", f.tmp.dir, "moved", std.testing.io);
    try f.write("moved/child.txt", "one");

    var unwatched = false;
    var waited: u32 = 0;
    while (waited < timeout_ms and !unwatched) : (waited += 200) {
        for (try f.watcher.poll(200)) |event| {
            if (event.kind == .unwatched and std.mem.eql(u8, event.path, target)) {
                unwatched = true;
            } else {
                try std.testing.expect(!std.mem.startsWith(u8, event.path, target));
            }
        }
    }
    try std.testing.expect(unwatched);
    try std.testing.expectEqual(@as(usize, 0), f.watcher.stats().registrations);
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

test "a watcher torn down with deliveries in flight does not outlive them" {
    for (backends) |backend| {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        for (0..60) |_| {
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
            defer gpa.free(root);

            var watcher: Watcher = try .init(gpa, io, .{
                .backend = backend,
                .poll_interval_ms = 20,
            });
            _ = try watcher.add(root, .{ .recursive = true });

            // A burst that is never polled for, so that whatever the
            // operating system delivers is still in flight when the
            // watcher goes away. Anything the watcher hands to a thread
            // it does not own has to be finished with before the memory
            // behind it is released.
            for (0..24) |j| {
                var name: [16]u8 = undefined;
                try tmp.dir.writeFile(io, .{
                    .sub_path = std.fmt.bufPrint(&name, "f{d}", .{j}) catch unreachable,
                    .data = "x",
                });
            }
            watcher.deinit();
        }
    }
}

test "watches taken and dropped in quick succession keep working" {
    for (backends) |backend| {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        for (0..60) |i| {
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
            defer gpa.free(root);

            var watcher: Watcher = try .init(gpa, io, .{
                .backend = backend,
                .poll_interval_ms = 20,
            });
            defer watcher.deinit();
            _ = try watcher.add(root, .{});

            try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
            const wanted = try std.fs.path.join(gpa, &.{ root, "a.txt" });
            defer gpa.free(wanted);

            // Every watch has to work, not most of them. A registration
            // the operating system accepted and then did nothing with is
            // a watch that is silent for the life of the program, which
            // is the worst thing a watcher can be.
            var found = false;
            var waited: u32 = 0;
            while (waited < 2_000 and !found) : (waited += 100) {
                for (try watcher.poll(100)) |event| {
                    if (std.mem.eql(u8, event.path, wanted)) found = true;
                }
            }
            if (!found) {
                std.debug.print("watch {d} on {s} reported nothing\n", .{ i, root });
                return error.WatchWentSilent;
            }
        }
    }
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

test "an event says whether the path is a file or a directory" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{ .recursive = true });

        const gpa = std.testing.allocator;
        const dir_path = try f.path("made");
        defer gpa.free(dir_path);
        const file_path = try f.path("made/a.txt");
        defer gpa.free(file_path);

        try f.tmp.dir.createDirPath(std.testing.io, "made");
        try f.write("made/a.txt", "one");

        var dir_target: ?lookout.Target = null;
        var file_target: ?lookout.Target = null;
        var waited: u32 = 0;
        while (waited < timeout_ms and (dir_target == null or file_target == null)) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                if (std.mem.eql(u8, event.path, dir_path)) dir_target = event.target;
                if (std.mem.eql(u8, event.path, file_path)) file_target = event.target;
            }
        }
        // "From the path" is not an answer once the path is gone, which
        // is why this is on the event and not left to the caller.
        try std.testing.expectEqual(lookout.Target.directory, dir_target.?);
        try std.testing.expectEqual(lookout.Target.file, file_target.?);
    }
}

test "a watch that cannot cover a subtree says so instead of going quiet" {
    // Running as a user who is refused nothing makes an unreadable
    // directory readable, and there is nothing to report.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const euid = if (@import("builtin").link_libc)
        std.c.geteuid()
    else
        std.os.linux.geteuid();
    if (euid == 0) return error.SkipZigTest;

    for (backends) |backend| {
        // Only the backends that register each directory themselves can
        // be refused one; the two that recurse in the kernel are told
        // about the tree whether they could open it or not.
        if (!lookout.prunesIgnored(backend)) continue;

        var f = try Fixture.init(backend);
        defer f.deinit();
        const io = std.testing.io;
        try f.tmp.dir.createDir(io, "closed", @enumFromInt(0o000));
        // Put it back before the fixture tries to delete the tree.
        defer f.tmp.dir.setFilePermissions(io, "closed", .default_dir, .{}) catch {};

        _ = try f.watcher.add(f.root, .{ .recursive = true });

        // A subtree lookout cannot see into is a hole in the watch. It
        // used to be swallowed, and the only sign of it was a part of
        // the tree that never reported anything.
        try f.expectEvent("closed", .unwatched);
    }
}

test "a watcher can be woken from another thread" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{});

        const Waker = struct {
            watcher: *Watcher,
            fn run(self: *@This()) void {
                std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
                self.watcher.wake();
            }
        };
        var waker: Waker = .{ .watcher = &f.watcher };
        const thread = try std.Thread.spawn(.{}, Waker.run, .{&waker});
        defer thread.join();

        // Nothing is going to happen to the tree, so without the wake
        // this blocks for as long as the caller is prepared to wait --
        // and with `null`, forever.
        const started: std.Io.Timestamp = .now(std.testing.io, .awake);
        const events = try f.watcher.poll(null);
        const elapsed = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake));
        try std.testing.expectEqual(@as(usize, 0), events.len);
        try std.testing.expect(elapsed.toMilliseconds() < timeout_ms);

        // And the watcher still works afterwards.
        try f.write("a.txt", "one");
        try f.expectEvent("a.txt", .created);
    }
}

test "a watcher says what it is watching" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const gpa = std.testing.allocator;

        const later = try f.path("later");
        defer gpa.free(later);
        const here = try f.watcher.add(f.root, .{ .recursive = true });
        const waiting = try f.watcher.add(later, .{ .pending = true });

        const held = try f.watcher.watches(gpa);
        defer gpa.free(held);
        try std.testing.expectEqual(@as(usize, 2), held.len);
        try std.testing.expectEqual(here, held[0].id);
        try std.testing.expectEqualStrings(f.root, held[0].path);
        try std.testing.expect(held[0].recursive);
        try std.testing.expect(!held[0].waiting);
        try std.testing.expectEqual(waiting, held[1].id);
        try std.testing.expectEqualStrings(later, held[1].path);
        // Parked on an ancestor is still not watching what was asked
        // for, and a program diffing what it meant to watch against
        // what it has needs to be told which.
        try std.testing.expect(held[1].waiting);

        f.watcher.remove(waiting);
        const after = try f.watcher.watches(gpa);
        defer gpa.free(after);
        try std.testing.expectEqual(@as(usize, 1), after.len);
    }
}

test "the descriptor becomes readable when there is something to report" {
    // A completion port is not a descriptor anything else can wait on,
    // and `std.posix.poll` is not the call to wait for one with.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const descriptor = f.watcher.fd() orelse continue;
        _ = try f.watcher.add(f.root, .{});
        try f.settle();

        try f.write("a.txt", "one");

        // This is the whole promise: a program with a wait loop of its
        // own waits on this and calls `poll` when it fires. The suite
        // used to assert only that it was not null.
        //
        // Readable means there is something to read, not that `poll`
        // will certainly return an event -- a delivery can resolve to
        // nothing once it is looked at -- so the assertion is one way
        // round only.
        var fds: [1]std.posix.pollfd = .{.{
            .fd = descriptor,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        try std.testing.expect(try std.posix.poll(&fds, timeout_ms) > 0);
        try f.expectEvent("a.txt", .created);
    }
}

test "two watchers in one process do not disturb each other" {
    for (backends) |backend| {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);
        try tmp.dir.createDirPath(io, "one");
        try tmp.dir.createDirPath(io, "two");

        const first_root = try std.fs.path.join(gpa, &.{ root, "one" });
        defer gpa.free(first_root);
        const second_root = try std.fs.path.join(gpa, &.{ root, "two" });
        defer gpa.free(second_root);

        var first: Watcher = try .init(gpa, io, .{ .backend = backend, .poll_interval_ms = 20 });
        defer first.deinit();
        var second: Watcher = try .init(gpa, io, .{ .backend = backend, .poll_interval_ms = 20 });
        defer second.deinit();
        _ = try first.add(first_root, .{});
        _ = try second.add(second_root, .{});

        try tmp.dir.writeFile(io, .{ .sub_path = "one/a.txt", .data = "one" });
        try tmp.dir.writeFile(io, .{ .sub_path = "two/b.txt", .data = "two" });

        const wanted_first = try std.fs.path.join(gpa, &.{ first_root, "a.txt" });
        defer gpa.free(wanted_first);
        const wanted_second = try std.fs.path.join(gpa, &.{ second_root, "b.txt" });
        defer gpa.free(wanted_second);

        var saw_first = false;
        var saw_second = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !(saw_first and saw_second)) : (waited += 200) {
            for (try first.poll(100)) |event| {
                try std.testing.expect(!std.mem.eql(u8, event.path, wanted_second));
                if (std.mem.eql(u8, event.path, wanted_first)) saw_first = true;
            }
            for (try second.poll(100)) |event| {
                try std.testing.expect(!std.mem.eql(u8, event.path, wanted_first));
                if (std.mem.eql(u8, event.path, wanted_second)) saw_second = true;
            }
        }
        try std.testing.expect(saw_first);
        try std.testing.expect(saw_second);
    }
}

test "a watch can be removed from inside a poll loop" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "one");
        try f.tmp.dir.createDirPath(std.testing.io, "two");

        const gpa = std.testing.allocator;
        const first_root = try f.path("one");
        defer gpa.free(first_root);
        const second_root = try f.path("two");
        defer gpa.free(second_root);

        const first = try f.watcher.add(first_root, .{});
        _ = try f.watcher.add(second_root, .{});
        try f.settle();

        try f.write("one/a.txt", "one");
        try f.write("two/b.txt", "two");

        // Removing a watch while its events are in the caller's hands is
        // documented as supported, and is what a program that reacts to
        // an event by dropping the watch does.
        var removed = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !removed) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                if (event.id == first) {
                    f.watcher.remove(first);
                    removed = true;
                }
            }
        }
        try std.testing.expect(removed);
        try std.testing.expectEqual(@as(usize, 1), f.watcher.stats().watches);

        // The other watch still works.
        try f.write("two/c.txt", "three");
        try f.expectEvent("two/c.txt", .created);
    }
}

test "a position is a token a caller can write down and hand back" {
    const start: lookout.Position = .{ .backend = .fsevents, .value = 1234567890 };
    var storage: [lookout.Position.max_token_len]u8 = undefined;
    const token = start.token(&storage);
    const parsed = try lookout.Position.parse(token);
    try std.testing.expectEqual(start.backend, parsed.backend);
    try std.testing.expectEqual(start.value, parsed.value);

    // A token is text, and text a program did not write is refused
    // rather than guessed at.
    try std.testing.expectError(error.InvalidPosition, lookout.Position.parse(""));
    try std.testing.expectError(error.InvalidPosition, lookout.Position.parse("1.fsevents"));
    try std.testing.expectError(error.InvalidPosition, lookout.Position.parse("2.fsevents.1"));
    try std.testing.expectError(error.InvalidPosition, lookout.Position.parse("1.nosuch.1"));
    try std.testing.expectError(error.InvalidPosition, lookout.Position.parse("1.auto.1"));
    try std.testing.expectError(error.InvalidPosition, lookout.Position.parse("1.fsevents.x"));
}

test "a watcher says where it has got to, exactly where it can" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const where = f.watcher.position();
        // Asserted rather than accepted either way, so the predicate
        // beside the option cannot go stale.
        try std.testing.expectEqual(lookout.tracksPosition(backend), where != null);
        if (where) |p| try std.testing.expectEqual(backend, p.backend);
    }
}

test "an FSEvents position does not pass an undrained event" {
    if (!lookout.supported(.fsevents)) return error.SkipZigTest;

    var f = try Fixture.init(.fsevents);
    defer f.deinit();
    _ = try f.watcher.add(f.root, .{});
    try f.settle();
    const before = f.watcher.position().?.value;

    try f.write("queued.txt", "one");
    std.testing.io.sleep(.fromMilliseconds(200), .awake) catch {};
    try std.testing.expectEqual(before, f.watcher.position().?.value);

    try f.expectEvent("queued.txt", .created);
    try std.testing.expect(f.watcher.position().?.value > before);
}

test "what changed while nothing was watching is reported on resuming" {
    if (!lookout.tracksPosition(lookout.default_backend)) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "one" });

    var token: [lookout.Position.max_token_len]u8 = undefined;
    var written: usize = 0;
    {
        var watcher: Watcher = try .init(gpa, io, .{});
        defer watcher.deinit();
        _ = try watcher.add(root, .{ .recursive = true });
        while ((try watcher.poll(200)).len != 0) {}
        const where = watcher.position().?;
        const text = where.token(&token);
        written = text.len;
    }

    // Nothing is watching now, which is exactly when the interesting
    // changes happen to a tool that was not running.
    try tmp.dir.writeFile(io, .{ .sub_path = "while-away.txt", .data = "two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one and two" });
    try tmp.dir.deleteFile(io, "gone.txt");

    var watcher: Watcher = try .init(gpa, io, .{
        .since = try lookout.Position.parse(token[0..written]),
    });
    defer watcher.deinit();
    _ = try watcher.add(root, .{ .recursive = true });

    const appeared = try std.fs.path.join(gpa, &.{ root, "while-away.txt" });
    defer gpa.free(appeared);
    const changed = try std.fs.path.join(gpa, &.{ root, "kept.txt" });
    defer gpa.free(changed);
    const deleted = try std.fs.path.join(gpa, &.{ root, "gone.txt" });
    defer gpa.free(deleted);

    var saw_appeared = false;
    var saw_changed = false;
    var saw_deleted = false;
    var waited: u32 = 0;
    while (waited < timeout_ms and !(saw_appeared and saw_changed and saw_deleted)) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (std.mem.eql(u8, event.path, appeared)) saw_appeared = true;
            if (std.mem.eql(u8, event.path, changed)) saw_changed = true;
            if (std.mem.eql(u8, event.path, deleted) and event.kind == .removed) saw_deleted = true;
        }
    }
    try std.testing.expect(saw_appeared);
    try std.testing.expect(saw_changed);
    // A path that was there at the position and is not there now is the
    // half a watcher that only looks forward cannot report.
    try std.testing.expect(saw_deleted);
}

test "an include list reports what it names and nothing else" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "src/deep");

        _ = try f.watcher.add(f.root, .{
            .recursive = true,
            .filter = .{ .only = &.{"src/**/*.zig"} },
        });
        try f.settle();

        const gpa = std.testing.allocator;
        const unwanted = try f.path("src/notes.txt");
        defer gpa.free(unwanted);
        const wanted = try f.path("src/deep/main.zig");
        defer gpa.free(wanted);

        try f.write("src/notes.txt", "one");
        try f.write("notes.zig", "two");
        try f.write("src/deep/main.zig", "three");

        // The walk still reached the directory the file is in, which is
        // the half an include list gets wrong if it prunes what it does
        // not name.
        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(!std.mem.eql(u8, event.path, unwanted));
                if (std.mem.eql(u8, event.path, wanted)) found = true;
            }
        }
        try std.testing.expect(found);
    }
}
