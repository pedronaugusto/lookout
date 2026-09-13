//! One suite, run once per backend this target can execute.
//!
//! The point of the repetition is the package's central claim: a program
//! written against `zwatch.Watcher` sees the same events whichever
//! mechanism is underneath. A behaviour that only the kernel backend has
//! is a behaviour a caller cannot rely on, so it does not belong in the
//! contract, and the way to keep it out is to hold the `poll` backend to
//! the same assertions on the same machine.

const std = @import("std");
const zwatch = @import("zwatch.zig");

const Kind = zwatch.Kind;
const Watcher = zwatch.Watcher;

/// Every backend this target was built with. The suite runs whole
/// against each of them, which is the package's central claim made
/// checkable: a program written against `zwatch.Watcher` sees the same
/// events whichever mechanism is underneath.
const backends: []const zwatch.Backend = all: {
    const names = @typeInfo(zwatch.Backend).@"enum".fields;
    var list: [names.len]zwatch.Backend = undefined;
    var len: usize = 0;
    for (names) |field| {
        const backend: zwatch.Backend = @enumFromInt(field.value);
        if (backend == .auto or !zwatch.supported(backend)) continue;
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

    fn init(backend: zwatch.Backend) !Fixture {
        // A short interval keeps the poll backend's latency in the same
        // order as the kernel backends' so one timeout fits both.
        return initOptions(.{ .backend = backend, .poll_interval_ms = 20 });
    }

    fn initOptions(options: zwatch.Options) !Fixture {
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

    fn path(f: *Fixture, sub_path: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ f.root, sub_path });
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
        // backend produces is `zwatch.pairsRenames`, and it is asserted
        // rather than accepted either way: a table in the README nobody
        // checks is a table that goes stale.
        if (zwatch.pairsRenames(backend)) {
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
    try std.testing.expectEqual(zwatch.Backend.poll, polling.backend());
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
    const absent: zwatch.Backend = if (zwatch.supported(.inotify)) .kqueue else .inotify;
    try std.testing.expect(!zwatch.supported(absent));
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
        watcher.add("zwatch-no-such-path-exists-here", .{}),
    );
}

test "polling a watcher with nothing to report returns nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var watcher: Watcher = try .init(gpa, io, .{ .poll_interval_ms = 20 });
    defer watcher.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try watcher.poll(100)).len);
}
