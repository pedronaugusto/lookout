//! One suite, run once per backend this target can execute.
//!
//! The point of the repetition is the package's central claim: a program
//! written against `lookout.Watcher` sees the same events whichever
//! mechanism is underneath. A behaviour that only the kernel backend has
//! is a behaviour a caller cannot rely on, so it does not belong in the
//! contract, and the way to keep it out is to hold the `poll` backend to
//! the same assertions on the same machine.

const std = @import("std");
const builtin = @import("builtin");
const lookout = @import("../lookout.zig");
const trace = @import("../trace.zig");
const Deadline = @import("../Deadline.zig");
const records = @import("../backend/fsevents/records.zig");

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

/// Sleeps `ms` on the test I/O from a thread the test started. Only a
/// cancellation cuts a sleep short, and nothing cancels these threads; a
/// nap cut short would only make its loop look at its condition sooner.
fn nap(ms: i64) void {
    std.testing.io.sleep(.fromMilliseconds(ms), .awake) catch |err| switch (err) {
        error.Canceled => {},
    };
}

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
        return initIo(std.testing.io, options);
    }

    fn initIo(io: std.Io, options: lookout.Options) !Fixture {
        const gpa = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();

        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(root);

        // A test run logs below warn only when asked; a traced run asks.
        if (trace.enabled()) std.testing.log_level = .info;
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
        f.* = undefined;
    }

    fn write(f: *Fixture, sub_path: []const u8, data: []const u8) !void {
        trace.log("suite write {s}/{s} ({d} bytes)", .{ f.root, sub_path, data.len });
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn overwrite(f: *Fixture, sub_path: []const u8, data: []const u8) !void {
        const file = try f.tmp.dir.openFile(std.testing.io, sub_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, data, 0);
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

test "every write immediately after add returns is reported" {
    for (backends) |backend| {
        for (0..200) |attempt| {
            var f = try Fixture.initOptions(.{
                .backend = backend,
                .poll_interval_ms = 20,
                .latency_ms = 0,
            });
            defer f.deinit();
            const file_watch = attempt % 3 == 1;
            const recursive = attempt % 3 == 2;
            const name = if (recursive) "sub/immediate.txt" else "immediate.txt";
            if (recursive) try f.tmp.dir.createDirPath(std.testing.io, "sub");
            if (file_watch) try f.write(name, "before");
            const target = try f.path(name);
            defer std.testing.allocator.free(target);
            _ = try f.watcher.add(if (file_watch) target else f.root, .{ .recursive = recursive });
            // No settling poll or sleep may separate registration and writing.
            if (file_watch) try f.overwrite(name, "after") else try f.write(name, "one");
            f.expectEvent(name, if (file_watch) .modified else .created) catch |err| {
                std.debug.print("{s}: immediate write missing on registration {d}\n", .{ @tagName(backend), attempt });
                return err;
            };
        }
    }
}

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

test "a file saved by a rename and then deleted is reported gone at once, in a long wait" {
    // An editor saves by writing a new file and renaming it over the old
    // one; the file is later deleted. FSEvents keeps a path's flags, so the
    // deletion arrives as a rename half with no partner, which is held for
    // one. A wait with no deadline of its own must still decide it within
    // the pairing grace, not when the next unrelated change comes.
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("next.md", "one");
        _ = try f.watcher.add(f.root, .{ .recursive = true });
        try f.settle();

        try f.write("next.new", "two");
        try f.tmp.dir.rename("next.new", f.tmp.dir, "next.md", std.testing.io);
        try f.settle();

        try f.tmp.dir.deleteFile(std.testing.io, "next.md");
        const gone = try f.path("next.md");
        defer std.testing.allocator.free(gone);
        var seen = false;
        while (!seen) {
            const events = try f.watcher.poll(timeout_ms);
            if (events.len == 0) break;
            for (events) |event| {
                if (std.mem.eql(u8, event.path, gone) and (event.kind == .removed or event.kind == .renamed)) seen = true;
            }
        }
        try std.testing.expect(seen);
    }
}

/// Include lists naming one file, as a program watching its settings
/// writes them. The second is the same list spelled so that a name it
/// excludes is still walked into, which is the shape that reaches a
/// backend's rename pairing with the excluded half still attached.
const settings_filters = [_]lookout.Filter{
    .{ .only = &.{"settings.toml"} },
    .{ .only = &.{"**/*.toml"} },
};

/// Polls until `sub_path` is reported with `kind`, or with any kind when
/// `kind` is `null`, and then until the watcher is quiet, failing on any
/// event that names `never` as its path or as where it came from.
fn expectWithout(f: *Fixture, sub_path: []const u8, kind: ?Kind, never: []const u8) !void {
    const gpa = std.testing.allocator;
    const wanted = try f.path(sub_path);
    defer gpa.free(wanted);
    const excluded = try f.path(never);
    defer gpa.free(excluded);

    var seen = false;
    var quiet = false;
    var waited: u32 = 0;
    while (waited < timeout_ms and !(seen and quiet)) : (waited += 200) {
        const events = try f.watcher.poll(200);
        quiet = seen and events.len == 0;
        for (events) |event| {
            trace.log("suite saw {s} {s}", .{ @tagName(event.kind), event.path });
            try std.testing.expect(!std.mem.eql(u8, event.path, excluded));
            if (event.from) |from| try std.testing.expect(!std.mem.eql(u8, from, excluded));
            const matches = if (kind) |k| event.kind == k else true;
            if (matches and std.mem.eql(u8, event.path, wanted)) seen = true;
        }
    }
    if (!seen) {
        const name = if (kind) |k| @tagName(k) else "any";
        std.debug.print("no {s} event for {s} within {d} ms\n", .{ name, wanted, timeout_ms });
        return error.EventNotObserved;
    }
}

/// What a name renamed over from a name the watch does not see is
/// reported as. Where renames are paired, it is a rename in from outside
/// and so `created`. Where they are not, the backend learns of it from a
/// listing and a vnode that went, and says look again in whichever of
/// the shapes that gives: `modified` from the listing, `removed` from the
/// file that was replaced.
fn renamedOver(backend: lookout.Backend) ?Kind {
    return if (lookout.pairsRenames(backend)) .created else null;
}

test "a file saved by renaming another name over it is reported through an include list" {
    // An editor saves by writing a new name and renaming it over the old
    // one, and a program watching its settings names the one file it
    // wants. The temporary name is outside what the watch is about, so
    // the rename is one in from outside: the watched name is a new file.
    for (backends) |backend| {
        for (settings_filters) |filter| {
            var f = try Fixture.init(backend);
            defer f.deinit();
            try f.write("settings.toml", "one");
            _ = try f.watcher.add(f.root, .{ .filter = filter });
            try f.settle();

            try f.write("settings.new", "one and two");
            try f.tmp.dir.rename("settings.new", f.tmp.dir, "settings.toml", std.testing.io);

            try expectWithout(&f, "settings.toml", renamedOver(backend), "settings.new");
        }
    }
}

test "a watched file renamed to a name an include list leaves out is removed" {
    for (backends) |backend| {
        for (settings_filters) |filter| {
            var f = try Fixture.init(backend);
            defer f.deinit();
            try f.write("settings.toml", "one");
            _ = try f.watcher.add(f.root, .{ .filter = filter });
            try f.settle();

            try f.tmp.dir.rename("settings.toml", f.tmp.dir, "settings.old", std.testing.io);
            try expectWithout(&f, "settings.toml", .removed, "settings.old");
        }
    }
}

test "a file renamed in from outside the watch over a watched one is created" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "watched");
        try f.write("watched/a.txt", "one");
        try f.write("outside.txt", "one and two");
        const watched = try f.path("watched");
        defer std.testing.allocator.free(watched);
        _ = try f.watcher.add(watched, .{});
        try f.settle();

        try f.tmp.dir.rename("outside.txt", f.tmp.dir, "watched/a.txt", std.testing.io);

        try expectWithout(&f, "watched/a.txt", renamedOver(backend), "outside.txt");
    }
}

test "a file renamed out of the watch is removed" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "watched");
        try f.write("watched/a.txt", "one");
        const watched = try f.path("watched");
        defer std.testing.allocator.free(watched);
        _ = try f.watcher.add(watched, .{});
        try f.settle();

        try f.tmp.dir.rename("watched/a.txt", f.tmp.dir, "outside.txt", std.testing.io);
        try expectWithout(&f, "watched/a.txt", .removed, "outside.txt");
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
    // Only the clock is replaced. File I/O keeps its original userdata;
    // poll(0) scans synchronously, so this test never sleeps or races a
    // kernel notification. The test thread owns and advances the time.
    const Clock = struct {
        threadlocal var milliseconds: i96 = 0;

        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = milliseconds * std.time.ns_per_ms };
        }
    };
    Clock.milliseconds = 1_000;
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var f = try Fixture.initIo(io, .{
        .backend = .poll,
        .settle_ms = 400,
        .latency_ms = 0,
    });
    defer f.deinit();
    try f.write("a.txt", "one");
    const id = try f.watcher.add(f.root, .{});
    try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(0)).len);

    const wanted = try f.path("a.txt");
    defer std.testing.allocator.free(wanted);

    // Keep writing past the first write's deadline. Different lengths
    // make every write observable without relying on filesystem timestamps.
    const chunks = [_][]const u8{ "two.", "three..", "four....", "five....." };
    const first_write = Clock.milliseconds;
    for (chunks, 0..) |chunk, i| {
        Clock.milliseconds = first_write + @as(i96, @intCast(i)) * 200;
        try f.write("a.txt", chunk);
        try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(0)).len);
        Clock.milliseconds += 199;
        try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(0)).len);
    }

    const last_write = first_write + (chunks.len - 1) * 200;
    Clock.milliseconds = last_write + 399;
    try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(0)).len);
    Clock.milliseconds = last_write + 400;
    const events = try f.watcher.poll(0);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(id, events[0].id);
    try std.testing.expectEqual(Kind.modified, events[0].kind);
    try std.testing.expectEqual(lookout.Target.file, events[0].target);
    try std.testing.expectEqualStrings(wanted, events[0].path);
    try std.testing.expectEqual(first_write * std.time.ns_per_ms, events[0].time.nanoseconds);

    // The deadline hands the change out once, including in later windows.
    try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(0)).len);
    Clock.milliseconds += 400;
    try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(0)).len);
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

test "refilter changes a live watch's admitted paths and registrations" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const io = std.testing.io;
        const gpa = std.testing.allocator;
        try f.tmp.dir.createDirPath(io, "old/deep");
        try f.tmp.dir.createDirPath(io, "new/deep");
        const id = try f.watcher.add(f.root, .{
            .recursive = true,
            .filter = .{ .ignore = &.{"new"} },
        });
        try f.settle();
        const before = f.watcher.stats().registrations;
        try f.watcher.refilter(id, .{ .ignore = &.{"old"} });
        try std.testing.expectEqual(before, f.watcher.stats().registrations);
        const infos = try f.watcher.watches(gpa);
        defer gpa.free(infos);
        try std.testing.expectEqual(@as(usize, 1), infos.len);
        try std.testing.expectEqual(id, infos[0].id);
        try std.testing.expect(infos[0].recursive);

        const excluded = try f.path("old/deep/excluded.txt");
        defer gpa.free(excluded);
        const admitted = try f.path("new/deep/admitted.txt");
        defer gpa.free(admitted);
        try f.write("old/deep/excluded.txt", "x");
        try f.write("new/deep/admitted.txt", "x");
        var saw = false;
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(!std.mem.eql(u8, event.path, excluded));
                if (event.id == id and event.kind == .created and
                    std.mem.eql(u8, event.path, admitted)) saw = true;
            }
            if (saw) break;
        }
        try std.testing.expect(saw);
        try std.testing.expectError(error.UnknownWatch, f.watcher.refilter(@enumFromInt(0xffffffff), .none));
    }
}

test "refilter reports writes to newly admitted files without recursion" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.write("admitted", "one");
        const id = try f.watcher.add(f.root, .{ .filter = .{ .ignore = &.{"admitted"} } });
        try f.settle();
        try f.watcher.refilter(id, .none);
        try f.overwrite("admitted", "two and three");
        try f.expectEvent("admitted", .modified);
    }
}

test "refilter seeds the entry budget of newly admitted directories" {
    for (backends) |backend| {
        var f = try Fixture.initOptions(.{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 2,
        });
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "new");
        try f.write("new/a", "x");
        try f.write("new/b", "x");
        const id = try f.watcher.add(f.root, .{
            .recursive = true,
            .filter = .{ .ignore = &.{"new"} },
        });
        try f.settle();
        try f.watcher.refilter(id, .none);
        try f.write("new/c", "x");
        var overflowed = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !overflowed) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                if (event.id == id and event.kind == .overflow and
                    std.mem.eql(u8, event.path, f.root)) overflowed = true;
            }
        }
        try std.testing.expect(overflowed);
    }
}

test "refilter does not count a queued creation twice" {
    for (backends) |backend| {
        var f = try Fixture.initOptions(.{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 2,
        });
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "keep");
        const id = try f.watcher.add(f.root, .{
            .recursive = true,
            .filter = .{ .ignore = &.{"*.tmp"} },
        });
        try f.settle();
        try f.write("keep/seed.txt", "x");
        try f.expectEvent("keep/seed.txt", .created);
        try f.settle();
        // This creation may already be queued by the kernel when the
        // filter changes. Reading its directory into the budget and then
        // counting the queued creation again would invent an overflow.
        try f.write("keep/live.tmp", "x");
        try f.watcher.refilter(id, .none);
        try f.write("keep/live.tmp", "xx");
        const subject = try f.path("keep/live.tmp");
        defer std.testing.allocator.free(subject);
        var saw = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !saw) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(event.id != id or event.kind != .overflow);
                if (event.id == id and std.mem.eql(u8, event.path, subject) and
                    (event.kind == .created or event.kind == .modified)) saw = true;
            }
        }
        try std.testing.expect(saw);
    }
}

test "writes after refilter are reported while a writer runs through the change" {
    const Writer = struct {
        phase: std.atomic.Value(bool) = .init(false),
        progress: std.atomic.Value(u32) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),

        const Self = @This();

        fn run(self: *Self, dir: std.Io.Dir) void {
            var i: u32 = 0;
            while (!self.phase.load(.acquire)) : (i += 1) {
                dir.writeFile(std.testing.io, .{ .sub_path = "keep/live.txt", .data = "x" }) catch {
                    self.failed.store(true, .release);
                    return;
                };
                dir.writeFile(std.testing.io, .{ .sub_path = "new/live.txt", .data = "x" }) catch {
                    self.failed.store(true, .release);
                    return;
                };
                self.progress.store(i + 1, .release);
                nap(1);
            }
            for (0..4) |j| {
                var keep_buf: [40]u8 = undefined;
                var new_buf: [40]u8 = undefined;
                var skip_buf: [40]u8 = undefined;
                const keep = std.fmt.bufPrint(&keep_buf, "keep/post-{d}.txt", .{j}) catch unreachable;
                const new = std.fmt.bufPrint(&new_buf, "new/post-{d}.txt", .{j}) catch unreachable;
                const skip = std.fmt.bufPrint(&skip_buf, "skip/post-{d}.txt", .{j}) catch unreachable;
                dir.writeFile(std.testing.io, .{ .sub_path = keep, .data = "x" }) catch {
                    self.failed.store(true, .release);
                    return;
                };
                dir.writeFile(std.testing.io, .{ .sub_path = new, .data = "x" }) catch {
                    self.failed.store(true, .release);
                    return;
                };
                dir.writeFile(std.testing.io, .{ .sub_path = skip, .data = "x" }) catch {
                    self.failed.store(true, .release);
                    return;
                };
            }
        }
    };

    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const io = std.testing.io;
        const gpa = std.testing.allocator;
        try f.tmp.dir.createDirPath(io, "keep");
        try f.tmp.dir.createDirPath(io, "new");
        try f.tmp.dir.createDirPath(io, "skip");
        const id = try f.watcher.add(f.root, .{
            .recursive = true,
            .filter = .{ .ignore = &.{ "new", "skip" } },
        });
        try f.settle();

        var writer: Writer = .{};
        {
            const thread = try std.Thread.spawn(.{}, Writer.run, .{ &writer, f.tmp.dir });
            errdefer {
                writer.phase.store(true, .release);
                thread.join();
            }
            while (writer.progress.load(.acquire) == 0 and !writer.failed.load(.acquire))
                try io.sleep(.fromMilliseconds(1), .awake);
            try std.testing.expect(!writer.failed.load(.acquire));
            try f.watcher.refilter(id, .{ .ignore = &.{"skip"} });
            writer.phase.store(true, .release);
            thread.join();
        }
        try std.testing.expect(!writer.failed.load(.acquire));

        var wanted: [8][]u8 = undefined;
        for (0..4) |j| {
            var keep_buf: [40]u8 = undefined;
            var new_buf: [40]u8 = undefined;
            wanted[2 * j] = try f.path(try std.fmt.bufPrint(&keep_buf, "keep/post-{d}.txt", .{j}));
            wanted[2 * j + 1] = try f.path(try std.fmt.bufPrint(&new_buf, "new/post-{d}.txt", .{j}));
        }
        defer for (wanted) |path| gpa.free(path);
        const excluded = try f.path("skip");
        defer gpa.free(excluded);
        var seen: [8]bool = @splat(false);
        var waited: u32 = 0;
        while (waited < timeout_ms and !std.mem.allEqual(bool, &seen, true)) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(!lookout.path.within(excluded, event.path));
                if (event.id != id or event.kind != .created) continue;
                for (wanted, &seen) |path, *hit| {
                    if (std.mem.eql(u8, path, event.path)) hit.* = true;
                }
            }
        }
        try std.testing.expect(std.mem.allEqual(bool, &seen, true));
    }
}

/// State belongs in the failure output even when error traces are disabled.
fn dumpDelivery(f: *const Fixture, phase: []const u8) void {
    std.debug.print("refilter backend={s} phase={s} root={s} stats={any}\n", .{
        @tagName(f.watcher.backend()), phase, f.root, f.watcher.stats(),
    });
    for (f.watcher.batch.events.items) |event| {
        std.debug.print("event id={d} kind={s} path={s} from={?s}\n", .{
            @intFromEnum(event.id), @tagName(event.kind), event.path, event.from,
        });
    }
    for (f.watcher.batch.held.keys(), f.watcher.batch.held.values()) |key, held| {
        std.debug.print("held id={d} kind={s} path={s} from={?s} last_ns={d} size={?d}\n", .{
            @intFromEnum(key.id), @tagName(held.kind), key.path, held.from, held.last_ns, held.size,
        });
    }
}

test "refilter drops held events that the new filter excludes" {
    for (backends) |backend| {
        var f = try Fixture.initOptions(.{
            .backend = backend,
            .poll_interval_ms = 20,
            .debounce_ms = 200,
        });
        defer f.deinit();
        var phase: []const u8 = "setup";
        errdefer dumpDelivery(&f, phase);
        try f.tmp.dir.createDirPath(std.testing.io, "old");
        try f.tmp.dir.createDirPath(std.testing.io, "new");
        try f.write("old/held.txt", "before");
        try f.write("new/after.txt", "before");
        const id = try f.watcher.add(f.root, .{ .recursive = true });
        try f.settle();
        const old = try f.path("old/held.txt");
        defer std.testing.allocator.free(old);
        const excluded = try f.path("old");
        defer std.testing.allocator.free(excluded);
        const new = try f.path("new/after.txt");
        defer std.testing.allocator.free(new);
        try f.overwrite("old/held.txt", "after!");
        // Stage the state refilter owns. Observing a kernel event inside a
        // live 200 ms window races a descheduled test thread against promote.
        // An already due hold must also be discarded before the next poll.
        phase = "stage old hold";
        try f.watcher.batch.push(std.testing.allocator, id, old, .modified, .file);
        const held = f.watcher.batch.held.getPtr(.{ .id = id, .path = old }).?;
        held.last_ns -= 201 * std.time.ns_per_ms;
        phase = "refilter";
        try f.watcher.refilter(id, .{ .ignore = &.{"old"} });
        for (f.watcher.batch.held.keys()) |key|
            try std.testing.expect(key.id != id or !lookout.path.within(excluded, key.path));
        phase = "observe admitted write";
        try f.overwrite("new/after.txt", "after!");
        var saw = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !saw) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                try std.testing.expect(!std.mem.eql(u8, event.path, old));
                if (event.id == id and event.kind == .modified and
                    std.mem.eql(u8, event.path, new)) saw = true;
            }
        }
        try std.testing.expect(saw);
    }
}

test "a folder appearing under a newly admitted path during refilter is reached" {
    const Gate = struct {
        go: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),

        const Self = @This();

        fn allow(context: ?*anyopaque, subject: []const u8) bool {
            const gate: *Self = @ptrCast(@alignCast(context.?));
            if (std.mem.eql(u8, std.fs.path.basename(subject), "new") and
                !gate.go.swap(true, .acq_rel))
            {
                while (!gate.done.load(.acquire))
                    nap(1);
            }
            return true;
        }

        fn create(gate: *Self, dir: std.Io.Dir) void {
            while (!gate.go.load(.acquire))
                nap(1);
            dir.createDirPath(std.testing.io, "new/racing") catch {
                gate.failed.store(true, .release);
                gate.done.store(true, .release);
                return;
            };
            dir.writeFile(std.testing.io, .{ .sub_path = "new/racing/inside.txt", .data = "x" }) catch {
                gate.failed.store(true, .release);
            };
            gate.done.store(true, .release);
        }
    };

    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "new");
        const id = try f.watcher.add(f.root, .{
            .recursive = true,
            .filter = .{ .ignore = &.{"new"} },
        });
        const before = f.watcher.stats().registrations;
        var gate: Gate = .{};
        {
            const thread = try std.Thread.spawn(.{}, Gate.create, .{ &gate, f.tmp.dir });
            errdefer {
                gate.go.store(true, .release);
                thread.join();
            }
            if (backend == .windows) {
                // This backend's kernel already traverses all directories;
                // refilter does not invoke the caller's predicate itself.
                gate.go.store(true, .release);
            }
            try f.watcher.refilter(id, .{ .allow = Gate.allow, .context = &gate });
            gate.go.store(true, .release);
            thread.join();
        }
        try std.testing.expect(!gate.failed.load(.acquire));
        if (lookout.prunesIgnored(backend))
            try std.testing.expect(f.watcher.stats().registrations >= before + 2);
        try f.write("new/racing/after.txt", "x");
        try f.expectEvent("new/racing/after.txt", .created);
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

test "a tree the filter ignores gets no registration however it grows" {
    // A caller that backs `allow` with a repository's ignore rules, and
    // one that names the usual build trees by glob, both expect those
    // trees to cost nothing where lookout does the recursion -- not to be
    // watched and then filtered.
    const rules = struct {
        /// What a repository's ignore file might say: two names, at any
        /// depth. Asked about every path under the watch, directories
        /// included.
        fn allow(context: ?*anyopaque, path: []const u8) bool {
            const asked: *usize = @ptrCast(@alignCast(context.?));
            asked.* += 1;
            const name = std.fs.path.basename(path);
            return !std.mem.eql(u8, name, "build") and !std.mem.eql(u8, name, "generated");
        }
    };
    for (backends) |backend| {
        if (!lookout.prunesIgnored(backend)) continue;
        var f = try Fixture.init(backend);
        defer f.deinit();
        const gpa = std.testing.allocator;
        const io = std.testing.io;

        try f.tmp.dir.createDirPath(io, "src");
        try f.tmp.dir.createDirPath(io, "node_modules/left-pad");
        try f.tmp.dir.createDirPath(io, "zig-out/bin");
        try f.tmp.dir.createDirPath(io, "build/obj");
        try f.write("src/wanted.txt", "one");

        var asked: usize = 0;
        _ = try f.watcher.add(f.root, .{
            .recursive = true,
            .filter = .{
                .ignore = &.{ "node_modules", "zig-*" },
                .allow = rules.allow,
                .context = &asked,
            },
        });
        try f.settle();
        // The root and `src`, and nothing in or below the three ignored
        // trees -- plus, on `kqueue`, the one file it holds open to see
        // it written.
        const before = f.watcher.stats().registrations;
        try std.testing.expectEqual(@as(usize, if (backend == .kqueue) 3 else 2), before);
        try std.testing.expect(asked > 0);

        // The ignored trees grow, deep, and new ones appear beside them,
        // named by the glob and by the rule.
        try f.tmp.dir.createDirPath(io, "node_modules/left-pad/lib/deep/deeper");
        try f.write("node_modules/left-pad/lib/deep/index.js", "x");
        try f.tmp.dir.createDirPath(io, "zig-out/bin/more");
        try f.write("zig-out/bin/more/app", "x");
        try f.tmp.dir.createDirPath(io, "zig-cache/o/1234");
        try f.write("zig-cache/o/1234/obj", "x");
        try f.tmp.dir.createDirPath(io, "build/obj/deep");
        try f.write("build/obj/deep/a.o", "x");
        try f.tmp.dir.createDirPath(io, "src/generated/deep");
        try f.write("src/generated/deep/out.zig", "x");

        // A wanted file beside them is still reported, and by then
        // everything that happened before it has been seen.
        try f.write("src/wanted.txt", "one and two");

        const ignored = [_][]const u8{ "node_modules", "zig-out", "zig-cache", "build", "src/generated" };
        var roots: [ignored.len][]u8 = undefined;
        for (ignored, &roots) |sub, *slot| slot.* = try f.path(sub);
        defer for (roots) |r| gpa.free(r);
        const wanted = try f.path("src/wanted.txt");
        defer gpa.free(wanted);

        var found = false;
        var waited: u32 = 0;
        while (waited < timeout_ms and !found) : (waited += 200) {
            for (try f.watcher.poll(200)) |event| {
                for (roots) |r| try std.testing.expect(!std.mem.startsWith(u8, event.path, r));
                if (event.kind == .modified and std.mem.eql(u8, event.path, wanted)) found = true;
            }
        }
        try std.testing.expect(found);
        for (try f.watcher.poll(200)) |event| {
            for (roots) |r| try std.testing.expect(!std.mem.startsWith(u8, event.path, r));
        }
        try std.testing.expectEqual(before, f.watcher.stats().registrations);
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

test "an overflow is returned before the debounce window closes" {
    var f = try Fixture.initOptions(.{
        .backend = .poll,
        .poll_interval_ms = 20,
        .debounce_ms = 300,
        .max_dir_entries = 2,
    });
    defer f.deinit();
    const id = try f.watcher.add(f.root, .{});
    for (0..3) |i| {
        var name: [8]u8 = undefined;
        try f.write(try std.fmt.bufPrint(&name, "f{d}", .{i}), "x");
    }
    // A non-blocking poll must return the scan's actual loss notice,
    // even though no ordinary change has had time to go quiet.
    const events = try f.watcher.poll(0);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(Kind.overflow, events[0].kind);
    try std.testing.expectEqual(id, events[0].id);
    try std.testing.expectEqualStrings(f.root, events[0].path);
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
                try std.testing.io.sleep(.fromMilliseconds(20), .awake);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), f.watcher.stats().held);

        f.watcher.remove(id);
        try std.testing.expectEqual(@as(usize, 0), f.watcher.stats().held);
        try std.testing.io.sleep(.fromMilliseconds(350), .awake);
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

test "what is made in a pending path as it appears is reported by the watch it becomes" {
    // The folder and what goes into it are made before the watcher reads
    // a thing: the watch is promoted after the entries are already there,
    // and they are reported as created against it rather than lost in
    // the gap between the parked watch and the real one.
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const gpa = std.testing.allocator;
        const target = try f.path("later");
        defer gpa.free(target);

        const id = try f.watcher.add(target, .{ .pending = true, .recursive = true });
        try std.testing.expectEqual(@as(usize, 0), (try f.watcher.poll(200)).len);

        try f.tmp.dir.createDirPath(std.testing.io, "later/sub");
        try f.write("later/a.txt", "one");
        try f.write("later/sub/b.txt", "two");

        var ledger: Ledger = .{};
        defer ledger.deinit();
        try ledger.await(&f, &.{
            .{ .id = id, .sub_path = "later", .kind = .created },
            .{ .id = id, .sub_path = "later/a.txt", .kind = .created },
            .{ .id = id, .sub_path = "later/sub/b.txt", .kind = .created },
        });

        // each once, whether the backend saw it as well or not
        while (true) {
            const events = try f.watcher.poll(120);
            if (events.len == 0) break;
            try ledger.note(events);
        }
        for ([_][]const u8{ "later/a.txt", "later/sub/b.txt" }) |sub_path| {
            const p = try f.path(sub_path);
            defer gpa.free(p);
            try std.testing.expectEqual(@as(usize, 1), ledger.count(id, .created, p));
        }

        // and the watch is the real one from then on
        try f.write("later/sub/c.txt", "three");
        try ledger.await(&f, &.{.{ .id = id, .sub_path = "later/sub/c.txt", .kind = .created }});
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

/// Every event a test saw, by watch, path and kind, so a test about
/// two watches can say both that each heard what it should and that
/// neither heard anything twice or anything that was the other's.
const Ledger = struct {
    const Key = struct { id: lookout.WatchId, kind: Kind, path: []u8 };
    seen: std.ArrayList(Key) = .empty,

    fn deinit(l: *Ledger) void {
        for (l.seen.items) |key| std.testing.allocator.free(key.path);
        l.seen.deinit(std.testing.allocator);
        l.* = undefined;
    }

    fn note(l: *Ledger, events: []const lookout.Event) !void {
        for (events) |event| {
            trace.log("suite ledger id={d} {s} {s}", .{ @intFromEnum(event.id), @tagName(event.kind), event.path });
            try l.seen.append(std.testing.allocator, .{
                .id = event.id,
                .kind = event.kind,
                .path = try std.testing.allocator.dupe(u8, event.path),
            });
        }
    }

    fn count(l: *const Ledger, id: lookout.WatchId, kind: Kind, path: []const u8) usize {
        var n: usize = 0;
        for (l.seen.items) |key| {
            if (key.id == id and key.kind == kind and std.mem.eql(u8, key.path, path)) n += 1;
        }
        return n;
    }

    fn any(l: *const Ledger, id: lookout.WatchId) bool {
        for (l.seen.items) |key| if (key.id == id) return true;
        return false;
    }

    /// Polls into the ledger until every one of `wants` has been seen at
    /// least once, or gives up.
    fn await(l: *Ledger, f: *Fixture, wants: []const Want) !void {
        const gpa = std.testing.allocator;
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 200) {
            try l.note(try f.watcher.poll(200));
            var all = true;
            for (wants) |want| {
                const p = try f.path(want.sub_path);
                defer gpa.free(p);
                if (l.count(want.id, want.kind, p) == 0) all = false;
            }
            if (all) return;
        }
        for (wants) |want| {
            const p = try f.path(want.sub_path);
            defer gpa.free(p);
            if (l.count(want.id, want.kind, p) == 0) {
                std.debug.print("{s}: no {s} for watch {d} at {s} within {d} ms\n", .{
                    @tagName(f.watcher.backend()), @tagName(want.kind), @intFromEnum(want.id), p, timeout_ms,
                });
            }
        }
        return error.EventNotObserved;
    }

    /// Polls into the ledger until the watcher has been quiet for a
    /// while, so that a claim about what was not reported is made after
    /// everything that was.
    fn drain(l: *Ledger, f: *Fixture) !void {
        var quiet: u32 = 0;
        while (quiet < 600) {
            const events = try f.watcher.poll(200);
            if (events.len == 0) {
                quiet += 200;
                continue;
            }
            quiet = 0;
            try l.note(events);
        }
    }

    const Want = struct { id: lookout.WatchId, sub_path: []const u8, kind: Kind };
};

test "a pending watch does not take the folder it waits in" {
    // Both orders: the folder watched after the pending watch parked on
    // it, and before. A parked watch used to count as a watch of the
    // folder, so the first order failed with `PathAlreadyWatched`, and
    // in the second the pending watch parked on nothing at all.
    for ([_]bool{ true, false }) |pending_first| for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        try f.tmp.dir.createDirPath(io, "dir");
        const dir = try f.path("dir");
        defer gpa.free(dir);
        const later = try f.path("dir/later");
        defer gpa.free(later);

        var waiting: lookout.WatchId = undefined;
        var folder: lookout.WatchId = undefined;
        if (pending_first) {
            waiting = try f.watcher.add(later, .{ .pending = true });
            folder = try f.watcher.add(dir, .{});
        } else {
            folder = try f.watcher.add(dir, .{});
            waiting = try f.watcher.add(later, .{ .pending = true });
        }
        // Parked with a registration of its own on the folder, not on
        // nothing: the kernel tells it when its path appears, rather than
        // the next poll happening to look.
        try std.testing.expect(f.watcher.table.get(waiting).?.registered != null);
        try std.testing.expectError(error.PathAlreadyWatched, f.watcher.add(dir, .{}));
        try f.settle();

        var ledger: Ledger = .{};
        defer ledger.deinit();

        // The folder's own watch hears the folder; the parked one hears
        // nothing of it.
        try f.write("dir/a.txt", "one");
        try ledger.await(&f, &.{.{ .id = folder, .sub_path = "dir/a.txt", .kind = .created }});
        try std.testing.expect(!ledger.any(waiting));

        // The path appears: the parked watch is promoted and says so, and
        // the folder's watch hears its new entry.
        try f.tmp.dir.createDirPath(io, "dir/later");
        try ledger.await(&f, &.{
            .{ .id = waiting, .sub_path = "dir/later", .kind = .created },
            .{ .id = folder, .sub_path = "dir/later", .kind = .created },
        });
        try std.testing.expectEqual(@as(usize, 2), f.watcher.stats().watches);
        try f.settle();

        // Both are real watches now, each of its own path.
        try f.write("dir/later/b.txt", "two");
        try f.write("dir/c.txt", "three");
        try ledger.await(&f, &.{
            .{ .id = waiting, .sub_path = "dir/later/b.txt", .kind = .created },
            .{ .id = folder, .sub_path = "dir/c.txt", .kind = .created },
        });

        // And each is told when its own path goes, whichever of the two
        // registrations the system reports first.
        try f.tmp.dir.deleteTree(io, "dir");
        try ledger.await(&f, &.{
            .{ .id = waiting, .sub_path = "dir/later", .kind = .removed },
            .{ .id = folder, .sub_path = "dir", .kind = .removed },
        });
        try f.settle();

        // Nothing heard twice, and nothing heard by the wrong watch.
        for (ledger.seen.items) |key| {
            if (key.kind == .created or key.kind == .removed) {
                try std.testing.expectEqual(@as(usize, 1), ledger.count(key.id, key.kind, key.path));
            }
            if (key.id == waiting) {
                try std.testing.expect(std.mem.startsWith(u8, key.path, later));
            }
        }
    };
}

test "two pending watches may wait in one folder" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const gpa = std.testing.allocator;
        const one = try f.path("one");
        defer gpa.free(one);
        const two = try f.path("two");
        defer gpa.free(two);

        const first = try f.watcher.add(one, .{ .pending = true });
        const second = try f.watcher.add(two, .{ .pending = true });
        try std.testing.expect(f.watcher.table.get(first).?.registered != null);
        try std.testing.expect(f.watcher.table.get(second).?.registered != null);

        var ledger: Ledger = .{};
        defer ledger.deinit();
        try f.tmp.dir.createDirPath(std.testing.io, "two");
        try ledger.await(&f, &.{.{ .id = second, .sub_path = "two", .kind = .created }});
        try std.testing.expect(!ledger.any(first));
        try f.tmp.dir.createDirPath(std.testing.io, "one");
        try ledger.await(&f, &.{.{ .id = first, .sub_path = "one", .kind = .created }});
    }
}

test "the path a pending watch waits for is taken by it" {
    // The path appears, and before any `poll` has promoted the waiting
    // watch the caller asks for it again. That `add` used to succeed, and
    // the promotion that followed put a second registration on the path,
    // so every change inside it was reported under two ids.
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const gpa = std.testing.allocator;
        const later = try f.path("later");
        defer gpa.free(later);

        const waiting = try f.watcher.add(later, .{ .pending = true });
        // Before it appears, a second wait for it is refused.
        try std.testing.expectError(error.PathAlreadyWatched, f.watcher.add(later, .{ .pending = true }));

        try f.tmp.dir.createDirPath(std.testing.io, "later");
        // After it appears and before the promotion, so is a watch of it.
        try std.testing.expectError(error.PathAlreadyWatched, f.watcher.add(later, .{}));
        try std.testing.expectError(error.PathAlreadyWatched, f.watcher.add(later, .{ .pending = true }));
        try std.testing.expectEqual(@as(usize, 1), f.watcher.stats().watches);

        var ledger: Ledger = .{};
        defer ledger.deinit();
        try ledger.await(&f, &.{.{ .id = waiting, .sub_path = "later", .kind = .created }});
        try f.settle();
        const registrations = f.watcher.stats().registrations;
        // And after the promotion too.
        try std.testing.expectError(error.PathAlreadyWatched, f.watcher.add(later, .{}));
        try std.testing.expectEqual(registrations, f.watcher.stats().registrations);

        try f.write("later/a.txt", "one");
        try ledger.await(&f, &.{.{ .id = waiting, .sub_path = "later/a.txt", .kind = .created }});
        try ledger.drain(&f);
        for (ledger.seen.items) |key| {
            try std.testing.expectEqual(waiting, key.id);
            try std.testing.expectEqual(@as(usize, 1), ledger.count(key.id, key.kind, key.path));
        }
    }
}

test "a pending path that leads to one already watched is not watched twice" {
    // A symbolic link appears on the way to the path a watch waits for,
    // and leads to a path another watch has. An `add` of the link is
    // refused as that path; the promotion is refused the same way,
    // rather than registering the path a second time under another name.
    // Windows makes a symbolic link only with a privilege a test cannot
    // count on.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        try f.tmp.dir.createDirPath(io, "real/inside");
        const real = try f.path("real/inside");
        defer gpa.free(real);
        const through = try f.path("link/inside");
        defer gpa.free(through);

        const held = try f.watcher.add(real, .{});
        try f.settle();
        const registrations = f.watcher.stats().registrations;
        const waiting = try f.watcher.add(through, .{ .pending = true });

        try f.tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });
        try std.testing.expectError(error.PathAlreadyWatched, f.watcher.add(through, .{}));

        var ledger: Ledger = .{};
        defer ledger.deinit();
        try ledger.await(&f, &.{.{ .id = waiting, .sub_path = "link/inside", .kind = .unwatched }});
        try std.testing.expectEqual(@as(usize, 0), ledger.count(waiting, .created, through));
        try std.testing.expectEqual(registrations, f.watcher.stats().registrations);
        try std.testing.expectEqual(@as(usize, 2), f.watcher.stats().watches);

        // Changes inside are reported once, to the watch that has them.
        try f.write("real/inside/a.txt", "one");
        try ledger.await(&f, &.{.{ .id = held, .sub_path = "real/inside/a.txt", .kind = .created }});
        try ledger.drain(&f);
        for (ledger.seen.items) |key| {
            if (key.id == waiting) try std.testing.expectEqual(Kind.unwatched, key.kind);
        }

        // The id stays valid until it is removed.
        const infos = try f.watcher.watches(gpa);
        defer gpa.free(infos);
        for (infos) |info| if (info.id == waiting) try std.testing.expect(!info.waiting);
        f.watcher.remove(waiting);
        try std.testing.expectEqual(@as(usize, 1), f.watcher.stats().watches);
    }
}

test "a folder shared with a pending watch keeps its entry budget" {
    for (backends) |backend| {
        var f = try Fixture.initOptions(.{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 2,
        });
        defer f.deinit();
        const gpa = std.testing.allocator;
        const later = try f.path("later");
        defer gpa.free(later);

        // Parked first, so on `inotify` it is the first owner of the one
        // kernel watch the two share, and it leaves every entry but its
        // own out. The count is the folder's, not the parked watch's.
        _ = try f.watcher.add(later, .{ .pending = true });
        const folder = try f.watcher.add(f.root, .{});
        for (0..6) |i| {
            var name: [8]u8 = undefined;
            try f.write(std.fmt.bufPrint(&name, "f{d}", .{i}) catch unreachable, "x");
        }

        var ledger: Ledger = .{};
        defer ledger.deinit();
        var waited: u32 = 0;
        while (waited < timeout_ms and ledger.count(folder, .overflow, f.root) == 0) : (waited += 200) {
            try ledger.note(try f.watcher.poll(200));
        }
        try std.testing.expect(ledger.count(folder, .overflow, f.root) > 0);
    }
}

test "a folder a pending watch alone held is counted true for the watch taken there next" {
    // While only a pending watch is parked on a folder, it keeps its own
    // name and lets every other change there go by -- and on `inotify`
    // the folder's count went by with them. A directory watch taken on
    // the folder after it found the folder counted already, took that
    // count as it was, and was told nothing when the folder passed its
    // budget.
    for (backends) |backend| {
        var f = try Fixture.initOptions(.{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 2,
        });
        defer f.deinit();
        const gpa = std.testing.allocator;
        const later = try f.path("later");
        defer gpa.free(later);

        _ = try f.watcher.add(later, .{ .pending = true });
        try f.settle();
        // two entries while only the parked watch is there: at the budget
        try f.write("f0", "x");
        try f.write("f1", "x");
        try f.settle();

        const folder = try f.watcher.add(f.root, .{});
        try f.settle();
        // the third is past it
        try f.write("f2", "x");
        var ledger: Ledger = .{};
        defer ledger.deinit();
        var waited: u32 = 0;
        while (waited < timeout_ms and ledger.count(folder, .overflow, f.root) == 0) : (waited += 200) {
            try ledger.note(try f.watcher.poll(200));
        }
        try std.testing.expect(ledger.count(folder, .overflow, f.root) > 0);
    }
}

test "a folder several watches share is counted once against its budget" {
    // One folder reached by three watches: its parent's, recursive; its
    // own; and a pending one parked in it. Windows and FSEvents hand each
    // watch its own copy of every change, and each copy was counted, so
    // the folder reached its budget at a fraction of its size -- and
    // FSEvents counted what was already there once per watch taken on it.
    for (backends) |backend| {
        var f = try Fixture.initOptions(.{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 4,
        });
        defer f.deinit();
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        try f.tmp.dir.createDirPath(io, "dir");
        try f.write("dir/f0", "x");
        try f.write("dir/f1", "x");
        const dir = try f.path("dir");
        defer gpa.free(dir);
        const later = try f.path("dir/later");
        defer gpa.free(later);

        const tree = try f.watcher.add(f.root, .{ .recursive = true });
        const folder = try f.watcher.add(dir, .{});
        const waiting = try f.watcher.add(later, .{ .pending = true });
        try f.settle();

        var ledger: Ledger = .{};
        defer ledger.deinit();

        // Four entries: at the budget and not past it.
        try f.write("dir/f2", "x");
        try f.tmp.dir.createDirPath(io, "dir/later");
        try ledger.await(&f, &.{
            .{ .id = tree, .sub_path = "dir/f2", .kind = .created },
            .{ .id = tree, .sub_path = "dir/later", .kind = .created },
            .{ .id = folder, .sub_path = "dir/f2", .kind = .created },
            .{ .id = folder, .sub_path = "dir/later", .kind = .created },
            .{ .id = waiting, .sub_path = "dir/later", .kind = .created },
        });
        try ledger.drain(&f);
        for (ledger.seen.items) |key| {
            if (key.kind == .overflow) {
                std.debug.print("{s}: watch {d} overflowed at {s} with four entries under a budget of four\n", .{
                    @tagName(backend), @intFromEnum(key.id), key.path,
                });
            }
            try std.testing.expect(key.kind != .overflow);
        }

        // The fifth is past it, and both watches the folder belongs to
        // are told.
        try f.write("dir/f3", "x");
        try ledger.await(&f, &.{
            .{ .id = tree, .sub_path = "", .kind = .overflow },
            .{ .id = folder, .sub_path = "dir", .kind = .overflow },
        });
    }
}

test "a watch on a file holds no entry budget for its folder" {
    // A watch on a file is about one entry, not a directory's entries:
    // no backend reads the folder's listing for it, and none tells it
    // when the folder is past the budget. Windows and FSEvents read the
    // file's folder to see the file, and they counted the folder through
    // that watch -- seeded from disk, then moved only by the file's own
    // comings and goings -- so a count the file watch held outlived the
    // folder's own watch and was taken up, stale, by the next one.
    for (backends) |backend| {
        var f = try Fixture.initOptions(.{
            .backend = backend,
            .poll_interval_ms = 20,
            .max_dir_entries = 4,
        });
        defer f.deinit();
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        try f.tmp.dir.createDirPath(io, "dir");
        try f.write("dir/file", "x");
        try f.write("dir/a", "x");
        const dir = try f.path("dir");
        defer gpa.free(dir);
        const file = try f.path("dir/file");
        defer gpa.free(file);

        const first = try f.watcher.add(dir, .{});
        const single = try f.watcher.add(file, .{});
        try f.settle();
        f.watcher.remove(first);

        // Two entries more while only the file is watched: four, at the
        // budget. The file's watch hears nothing of them.
        try f.write("dir/b", "x");
        try f.write("dir/c", "x");
        try f.settle();

        var ledger: Ledger = .{};
        defer ledger.deinit();
        const again = try f.watcher.add(dir, .{});
        try ledger.drain(&f);
        try std.testing.expectEqual(@as(usize, 0), ledger.count(again, .overflow, dir));

        // The fifth is past it: the folder's watch is told, and the
        // file's is not. Where a watch is told of a count, every watch
        // it is for is told by the same change, so the file's watch
        // would be in what has been read by now. (A listing backend says
        // it again on every look while the folder stays too big, so this
        // does not wait for quiet.)
        try f.write("dir/d", "x");
        try ledger.await(&f, &.{
            .{ .id = again, .sub_path = "dir/d", .kind = .created },
            .{ .id = again, .sub_path = "dir", .kind = .overflow },
        });
        try std.testing.expectEqual(@as(usize, 0), ledger.count(single, .overflow, file));
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
    if (builtin.os.tag == .windows) return error.SkipZigTest;

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
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const euid = if (builtin.link_libc)
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
            calls: std.atomic.Value(usize) = .init(0),
            const Self = @This();

            fn run(self: *Self) void {
                nap(100);
                _ = self.calls.fetchAdd(1, .release);
                self.watcher.wake();
            }
        };
        var waker: Waker = .{ .watcher = &f.watcher };
        const thread = try std.Thread.spawn(.{}, Waker.run, .{&waker});
        defer thread.join();

        // Nothing is going to happen to the tree, so without the wake
        // this blocks for as long as the caller is prepared to wait --
        // and with `null`, forever.
        const events = try f.watcher.poll(null);
        try std.testing.expectEqual(@as(usize, 0), events.len);
        try std.testing.expectEqual(@as(usize, 1), waker.calls.load(.acquire));

        // And the watcher still works afterwards.
        try f.write("a.txt", "one");
        try f.expectEvent("a.txt", .created);
    }
}

/// A task that waits for `go` without touching `std.Io`, so a
/// cancellation requested meanwhile is still pending when it calls
/// `then`, and then calls it once.
fn Held(comptime Result: type, comptime then: anytype) type {
    return struct {
        watcher: *Watcher,
        path: []const u8 = "",
        go: std.atomic.Value(bool) = .init(false),

        const Self = @This();

        fn run(self: *Self) Result {
            while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
            return then(self);
        }

        /// Lets the task go from another thread, after `delay_ms`.
        fn release(self: *Self, delay_ms: i64) void {
            nap(delay_ms);
            self.go.store(true, .release);
        }
    };
}

fn addOnce(self: anytype) Watcher.AddError!lookout.WatchId {
    return self.watcher.add(self.path, .{});
}

test "a cancellation requested before poll gathers no work" {
    const Probe = struct {
        var checks: usize = 0;
        var clock_reads: usize = 0;
        fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {
            checks += 1;
            return error.Canceled;
        }
        fn now(context: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            clock_reads += 1;
            return std.testing.io.vtable.now(context, clock);
        }
    };
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{});
        var vtable = std.testing.io.vtable.*;
        vtable.checkCancel = Probe.checkCancel;
        vtable.now = Probe.now;
        Probe.checks = 0;
        Probe.clock_reads = 0;
        f.watcher.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
        defer f.watcher.io = std.testing.io;
        const revision = f.watcher.batch.revision;
        try std.testing.expectError(error.Canceled, f.watcher.poll(0));
        try std.testing.expectEqual(@as(usize, 1), Probe.checks);
        try std.testing.expectEqual(@as(usize, 0), Probe.clock_reads);
        try std.testing.expectEqual(revision, f.watcher.batch.revision);
    }
}

test "a cancellation that arrives while a poll waits costs no event" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{});

        const Poller = struct {
            fn run(watcher: *Watcher) Watcher.PollError![]const lookout.Event {
                return watcher.poll(null);
            }
        };
        var future = std.testing.io.concurrent(Poller.run, .{&f.watcher}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.SkipZigTest,
        };
        // The change comes after the cancellation has been asked for. On
        // the `poll` backend the cancellation ends the sleep and the
        // change is found by the next scan; on a kernel backend the change
        // is what ends the wait, and the poll that reports the
        // cancellation has already read it.
        const Writer = struct {
            dir: std.Io.Dir,
            failed: ?std.Io.Dir.WriteFileError = null,

            const Self = @This();

            fn run(writer: *Self) void {
                nap(150);
                writer.dir.writeFile(std.testing.io, .{ .sub_path = "late.txt", .data = "x" }) catch |err| {
                    writer.failed = err;
                };
            }
        };
        try std.testing.io.sleep(.fromMilliseconds(30), .awake);
        var writer: Writer = .{ .dir = f.tmp.dir };
        {
            const thread = try std.Thread.spawn(.{}, Writer.run, .{&writer});
            defer thread.join();
            try std.testing.expectError(error.Canceled, future.cancel(std.testing.io));
        }
        if (writer.failed) |err| return err;
        // Handed out by the next poll rather than dropped with the one
        // that was canceled.
        try f.expectEvent("late.txt", .created);
    }
}

test "a cancellation requested before add is refused, and nothing is added" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();

        const Task = Held(Watcher.AddError!lookout.WatchId, addOnce);
        var task: Task = .{ .watcher = &f.watcher, .path = f.root };
        var future = std.testing.io.concurrent(Task.run, .{&task}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.SkipZigTest,
        };
        const thread = try std.Thread.spawn(.{}, Task.release, .{ &task, 20 });
        defer thread.join();

        try std.testing.expectError(error.Canceled, future.cancel(std.testing.io));
        const held = try f.watcher.watches(std.testing.allocator);
        defer std.testing.allocator.free(held);
        try std.testing.expectEqual(@as(usize, 0), held.len);
    }
}

test "a polling task is stopped by a flag and a wake on every backend" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        _ = try f.watcher.add(f.root, .{});

        // The recipe `Watcher.wake` gives, as written there.
        const Task = struct {
            watcher: *Watcher,
            stopping: std.atomic.Value(bool) = .init(false),
            polls: usize = 0,
            entered: std.atomic.Value(bool) = .init(false),

            const Self = @This();

            fn run(self: *Self) Watcher.PollError!void {
                while (!self.stopping.load(.acquire)) {
                    self.entered.store(true, .release);
                    _ = try self.watcher.poll(null);
                    self.polls += 1;
                }
            }
        };
        var task: Task = .{ .watcher = &f.watcher };
        var future = std.testing.io.concurrent(Task.run, .{&task}) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.SkipZigTest,
        };
        // Bound a task that never starts. Readiness, rather than a sleep,
        // puts stopping and wake after the task has entered its poll loop.
        const deadline = Deadline.start(std.testing.io, timeout_ms);
        while (!task.entered.load(.acquire) and !deadline.expired()) {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        const entered = task.entered.load(.acquire);
        task.stopping.store(true, .release);
        f.watcher.wake();
        try future.await(std.testing.io);
        if (!entered) std.debug.print("{s}: polling task never entered its loop\n", .{@tagName(backend)});
        try std.testing.expect(entered);
        try std.testing.expect(task.polls >= 1);
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
    if (builtin.os.tag == .windows) return error.SkipZigTest;

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

        // And the other half of the promise: a wait loop that fires
        // when nothing has happened would spin. A `poll` that came
        // back empty has taken everything the descriptor held, so
        // right after one the descriptor is quiet -- and it stays
        // quiet, because a tree nobody touches has nothing to report.
        try f.settle();
        fds[0].revents = 0;
        try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&fds, 0));
        fds[0].revents = 0;
        try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&fds, 500));
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

test "a watcher offers checkpoints exactly where it can resume" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        var saved = try f.watcher.checkpoint(std.testing.allocator);
        defer if (saved) |*checkpoint| checkpoint.deinit();
        try std.testing.expectEqual(lookout.tracksCheckpoint(backend), saved != null);
    }
}

test "what changed while nothing was watching is reported on resuming" {
    if (!lookout.tracksCheckpoint(lookout.default_backend)) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "one" });

    var token: []u8 = undefined;
    defer gpa.free(token);
    {
        var watcher: Watcher = try .init(gpa, io, .{});
        defer watcher.deinit();
        _ = try watcher.add(root, .{ .recursive = true });
        while ((try watcher.poll(200)).len != 0) {}
        var where = (try watcher.checkpoint(gpa)).?;
        defer where.deinit();
        token = try where.token(gpa);
    }

    // Nothing is watching now, which is exactly when the interesting
    // changes happen to a tool that was not running.
    try tmp.dir.writeFile(io, .{ .sub_path = "while-away.txt", .data = "two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one and two" });
    try tmp.dir.deleteFile(io, "gone.txt");

    var checkpoint = try lookout.Checkpoint.parse(gpa, token);
    defer checkpoint.deinit();
    var watcher: Watcher = try .init(gpa, io, .{ .checkpoint = checkpoint });
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

test "resuming retains a debounced change that poll has not handed out" {
    if (comptime !lookout.supported(.fsevents)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const wanted = try std.fs.path.join(gpa, &.{ root, "held.txt" });
    defer gpa.free(wanted);
    var saved: lookout.Checkpoint = undefined;
    defer saved.deinit();
    {
        var watcher = try Watcher.init(gpa, io, .{ .backend = .fsevents, .debounce_ms = 200, .latency_ms = 0 });
        defer watcher.deinit();
        _ = try watcher.add(root, .{});
        try tmp.dir.writeFile(io, .{ .sub_path = "held.txt", .data = "one" });
        // Read the backend without promoting: stage the pending delivery
        // deterministically, independent of a pause in the test thread.
        const deadline = Deadline.start(io, timeout_ms);
        while (watcher.batch.held.count() == 0 and !deadline.expired()) {
            try watcher.impl.fsevents.wait(&watcher.batch, 0);
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expect(watcher.batch.held.count() != 0);
        saved = (try watcher.checkpoint(gpa)).?;
    }
    var resumed = try Watcher.init(gpa, io, .{ .backend = .fsevents, .checkpoint = saved, .latency_ms = 0 });
    defer resumed.deinit();
    _ = try resumed.add(root, .{});
    var saw = false;
    var waited: u32 = 0;
    while (!saw and waited < timeout_ms) : (waited += 200) {
        for (try resumed.poll(200)) |event| {
            if (std.mem.eql(u8, event.path, wanted)) saw = true;
        }
    }
    if (!saw) std.debug.print("resume skipped unhanded path={s} checkpoint={any}\n", .{ wanted, saved.state.value });
    try std.testing.expect(saw);
}

test "checkpoints keep settling and rename changes beside handed deliveries" {
    if (comptime !lookout.supported(.fsevents)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    for ([_]lookout.Options{ .{ .settle_ms = 200 }, .{ .debounce_ms = 200 } }) |holding| {
        var f = try Fixture.initOptions(.{
            .backend = .fsevents,
            .latency_ms = 0,
            .settle_ms = holding.settle_ms,
            .debounce_ms = holding.debounce_ms,
        });
        defer f.deinit();
        try f.write("held.txt", "one");
        try f.write("from.txt", "one");
        const id = try f.watcher.add(f.root, .{});
        try f.settle();
        const held = try f.path("held.txt");
        defer gpa.free(held);
        const from = try f.path("from.txt");
        defer gpa.free(from);
        const to = try f.path("to.txt");
        defer gpa.free(to);
        const handed = try f.path("handed.txt");
        defer gpa.free(handed);

        try f.watcher.batch.deferChange(gpa, id, handed, .overflow, null, .file);
        const delivered = try f.watcher.poll(0);
        try std.testing.expectEqual(@as(usize, 1), delivered.len);
        // The next changes are unhanded even though a prior delivery
        // remains borrowed by the caller. Staging avoids clock races.
        try f.watcher.batch.push(gpa, id, held, .modified, .file);
        if (holding.debounce_ms != 0) {
            try f.watcher.batch.pushRename(gpa, id, to, from, .file);
        } else {
            const stream = f.watcher.impl.fsevents.streams.get(id).?;
            f.watcher.impl.fsevents.pairing.held = .{
                .id = id,
                .path = try gpa.dupe(u8, from),
                .flags = records.flag.item_renamed,
                .event = stream.cursor,
            };
        }
        var checkpoint = (try f.watcher.checkpoint(gpa)).?;
        defer checkpoint.deinit();
        const text = try checkpoint.token(gpa);
        defer gpa.free(text);
        var parsed = try lookout.Checkpoint.parse(gpa, text);
        defer parsed.deinit();
        // Changing holding options must not lose the pending changes.
        var resumed = try Watcher.init(gpa, io, .{ .backend = .fsevents, .checkpoint = parsed, .latency_ms = 0 });
        defer resumed.deinit();
        const restored = try resumed.add(f.root, .{});
        if (holding.settle_ms != 0) {
            try std.testing.expectEqualStrings(from, resumed.impl.fsevents.pairing.held.?.path);
            try resumed.impl.fsevents.wait(&resumed.batch, 0);
        }
        const events = try resumed.poll(0);
        var saw_modified = false;
        var saw_rename = false;
        for (events) |event| {
            try std.testing.expect(event.id == restored);
            try std.testing.expect(!std.mem.eql(u8, event.path, handed));
            if (std.mem.eql(u8, event.path, held) and event.kind == .modified) saw_modified = true;
            if (std.mem.eql(u8, event.path, to) and event.kind == .renamed) {
                try std.testing.expectEqualStrings(from, event.from.?);
                saw_rename = true;
            }
        }
        try std.testing.expect(saw_modified);
        if (holding.debounce_ms != 0) {
            try std.testing.expect(saw_rename);
        } else {
            // A raw half, unlike a completed rename, is restored to the
            // pairing owner before waiting for any new native delivery.
            // poll(0) resolves it; its path remains known on this tree.
            try std.testing.expect(resumed.impl.fsevents.pairing.held == null);
        }
    }
}

test "a crash before checkpoint persistence replays the uncommitted delivery" {
    if (comptime !lookout.supported(.fsevents)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f = try Fixture.initOptions(.{ .backend = .fsevents, .latency_ms = 0 });
    defer f.deinit();
    _ = try f.watcher.add(f.root, .{});
    try f.settle();
    var before = (try f.watcher.checkpoint(gpa)).?;
    defer before.deinit();
    try f.write("delivered.txt", "one");
    try f.expectEvent("delivered.txt", .created);
    var after = (try f.watcher.checkpoint(gpa)).?;
    defer after.deinit();
    const wanted = try f.path("delivered.txt");
    defer gpa.free(wanted);
    // The saved checkpoint is the commit boundary. Choosing the previous
    // one models a crash after delivery but before processing/persistence.
    for ([_]lookout.Checkpoint{ before, after }, [_]bool{ true, false }) |saved, should_replay| {
        var resumed = try Watcher.init(gpa, std.testing.io, .{ .backend = .fsevents, .checkpoint = saved, .latency_ms = 0 });
        defer resumed.deinit();
        _ = try resumed.add(f.root, .{});
        var saw = false;
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 200) {
            for (try resumed.poll(200)) |event| {
                if (std.mem.eql(u8, event.path, wanted)) saw = true;
            }
            if (saw and should_replay) break;
        }
        if (saw != should_replay) std.debug.print("checkpoint crash replay wanted={} saw={} path={s}\n", .{ should_replay, saw, wanted });
        try std.testing.expectEqual(should_replay, saw);
    }
}

test "checkpoint allocation failures leave the delivery and snapshot owned" {
    if (comptime !lookout.supported(.fsevents)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f = try Fixture.init(.fsevents);
    defer f.deinit();
    const id = try f.watcher.add(f.root, .{});
    try f.watcher.batch.deferChange(gpa, id, f.root, .renamed, f.root, .directory);
    var failures: usize = 0;
    while (true) : (failures += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = failures });
        if (tryCheckpoint(failing.allocator(), &f.watcher)) |*snapshot| {
            var saved = snapshot.*;
            saved.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 1), f.watcher.batch.deferred.items.len);
            try std.testing.expectEqualStrings(f.root, f.watcher.batch.deferred.items[0].from.?);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
    try std.testing.expect(failures > 0);
    var saved = (try f.watcher.checkpoint(gpa)).?;
    defer saved.deinit();
    // init copies all resume state. Sweeping its allocator also checks
    // descriptors and dispatch queues are released after clone failures.
    failures = 0;
    while (true) : (failures += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = failures });
        if (Watcher.init(failing.allocator(), std.testing.io, .{ .backend = .fsevents, .checkpoint = saved })) |value| {
            var watcher = value;
            watcher.deinit();
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
    try std.testing.expect(failures > 0);
}

fn tryCheckpoint(gpa: std.mem.Allocator, watcher: *const Watcher) !lookout.Checkpoint {
    return (try watcher.checkpoint(gpa)).?;
}

test "checkpoint restoration rolls back a failed add and preserves prior slices" {
    if (comptime !lookout.supported(.fsevents)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(.fsevents);
    defer f.deinit();
    try f.tmp.dir.createDirPath(io, "later");
    const later = try f.path("later");
    defer gpa.free(later);
    const id = try f.watcher.add(later, .{});
    const moved_to = try f.path("later/new");
    defer gpa.free(moved_to);
    const moved_from = try f.path("later/old");
    defer gpa.free(moved_from);
    try f.watcher.batch.deferChange(gpa, id, moved_to, .renamed, moved_from, .file);
    var saved = (try f.watcher.checkpoint(gpa)).?;
    defer saved.deinit();
    var failures: usize = 0;
    while (true) : (failures += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{});
        var succeeded = false;
        {
            var resumed = try Watcher.init(failing.allocator(), io, .{ .backend = .fsevents, .checkpoint = saved, .latency_ms = 0 });
            defer resumed.deinit();
            const prior_id = try resumed.add(f.root, .{});
            try resumed.batch.deferChange(failing.allocator(), prior_id, f.root, .overflow, null, .directory);
            const prior = try resumed.poll(0);
            try std.testing.expectEqual(@as(usize, 1), prior.len);
            const borrowed = prior.ptr;
            const borrowed_path = prior[0].path.ptr;
            failing.fail_index = failing.alloc_index + failures;
            const answer = resumed.add(later, .{});
            failing.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(borrowed, resumed.batch.events.items.ptr);
            try std.testing.expectEqual(borrowed_path, prior[0].path.ptr);
            try std.testing.expectEqualStrings(f.root, prior[0].path);
            if (answer) |_| {
                var saw = false;
                for (try resumed.poll(0)) |event| {
                    if (std.mem.eql(u8, event.path, moved_to) and event.kind == .renamed) {
                        try std.testing.expectEqualStrings(moved_from, event.from.?);
                        saw = true;
                    }
                }
                try std.testing.expect(saw);
                succeeded = true;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(@as(usize, 1), resumed.stats().watches);
                try std.testing.expectEqual(@as(usize, 0), resumed.batch.deferred.items.len);
                _ = try resumed.add(later, .{});
                try std.testing.expectEqual(@as(usize, 1), resumed.batch.deferred.items.len);
            }
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (succeeded) break;
    }
    try std.testing.expect(failures > 0);
}
