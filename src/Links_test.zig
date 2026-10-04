//! Following symbolic links, on every backend this target runs. See
//! `AddOptions.follow_symlinks`.
//!
//! Each scenario watches `watched` under a scratch directory and keeps
//! what the links lead to beside it, in `outside`, so that a change
//! reported under the link can only have come through the link.

const std = @import("std");
const builtin = @import("builtin");
const lookout = @import("lookout.zig");
const Deadline = @import("Deadline.zig");
const path_cmp = @import("path.zig");

const Kind = lookout.Kind;
const Watcher = lookout.Watcher;
const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

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

const timeout_ms = 5_000;
/// How long a scenario listens for something that must not arrive.
const quiet_ms = 600;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    watcher: Watcher,

    fn init(backend: lookout.Backend) !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "watched");
        try tmp.dir.createDirPath(io, "outside");
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(root);
        return .{
            .tmp = tmp,
            .root = root,
            .watcher = try .init(gpa, io, .{ .backend = backend, .poll_interval_ms = 20, .latency_ms = 20 }),
        };
    }

    fn deinit(f: *Fixture) void {
        f.watcher.deinit();
        gpa.free(f.root);
        f.tmp.cleanup();
    }

    /// The absolute path of `sub_path`, spelled as an event spells it.
    fn path(f: *const Fixture, sub_path: []const u8) ![]u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        try parts.append(gpa, f.root);
        var it = std.mem.splitScalar(u8, sub_path, '/');
        while (it.next()) |part| try parts.append(gpa, part);
        return std.fs.path.join(gpa, parts.items);
    }

    fn watch(f: *Fixture, options: lookout.AddOptions) !lookout.WatchId {
        const root = try f.path("watched");
        defer gpa.free(root);
        var with = options;
        with.recursive = true;
        with.follow_symlinks = true;
        const id = try f.watcher.add(root, with);
        try f.settle();
        return id;
    }

    fn write(f: *Fixture, sub_path: []const u8) !void {
        try f.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "x" });
    }

    /// Makes `link` lead to the directory `target`. On Windows it is a
    /// junction, which needs no privilege where a symbolic link does, and
    /// is a link to lookout all the same.
    fn link(f: *Fixture, target: []const u8, at: []const u8) !void {
        const absolute = if (std.mem.eql(u8, target, ".")) try gpa.dupe(u8, f.root) else try f.path(target);
        defer gpa.free(absolute);
        if (builtin.os.tag != .windows) return f.tmp.dir.symLink(io, absolute, at, .{ .is_directory = true });
        try f.tmp.dir.createDir(io, at, .default_dir);
        const spelled = try f.path(at);
        defer gpa.free(spelled);
        try junction(spelled, absolute);
    }

    fn unlink(f: *Fixture, at: []const u8) !void {
        if (builtin.os.tag == .windows) return f.tmp.dir.deleteDir(io, at);
        try f.tmp.dir.deleteFile(io, at);
    }

    /// Drains whatever is pending.
    fn settle(f: *Fixture) !void {
        while ((try f.watcher.poll(150)).len != 0) {}
    }

    /// Polls until `sub_path` is reported -- as `kind`, or as anything
    /// when `kind` is null -- failing on any event at or below one of
    /// `forbidden` on the way.
    fn expect(f: *Fixture, sub_path: []const u8, kind: ?Kind, forbidden: []const []const u8) !void {
        const want = try f.path(sub_path);
        defer gpa.free(want);
        const deadline = Deadline.start(io, timeout_ms);
        while (!deadline.expired()) {
            for (try f.watcher.poll(100)) |event| {
                try f.allowed(event, forbidden);
                if (!path_cmp.eql(event.path, want)) continue;
                if (kind == null or kind.? == event.kind) return;
            }
        }
        std.debug.print("{s}: no {s} event for {s}\n", .{ @tagName(f.watcher.backend()), if (kind) |k| @tagName(k) else "", want });
        return error.EventNotObserved;
    }

    /// Polls until the watcher holds `wanted` registrations, or more than
    /// `wanted` when `above` is set. A link's change can arrive as two
    /// events in two polls, and what is written below it is only seen
    /// once it is followed again.
    fn await(f: *Fixture, wanted: usize, above: bool) !void {
        const deadline = Deadline.start(io, timeout_ms);
        while (!deadline.expired()) {
            const held = f.watcher.stats().registrations;
            if (if (above) held > wanted else held == wanted) return;
            _ = try f.watcher.poll(100);
        }
        std.debug.print("{s}: {d} registrations, wanted {s}{d}\n", .{ @tagName(f.watcher.backend()), f.watcher.stats().registrations, if (above) "more than " else "", wanted });
        return error.EventNotObserved;
    }

    /// Listens for a while, failing on any event at or below `forbidden`.
    fn quiet(f: *Fixture, forbidden: []const []const u8) !void {
        const deadline = Deadline.start(io, quiet_ms);
        while (!deadline.expired()) {
            for (try f.watcher.poll(100)) |event| try f.allowed(event, forbidden);
        }
    }

    fn allowed(f: *Fixture, event: lookout.Event, forbidden: []const []const u8) !void {
        for (forbidden) |sub_path| {
            const spelled = try f.path(sub_path);
            defer gpa.free(spelled);
            if (!path_cmp.within(spelled, event.path)) continue;
            std.debug.print("{s}: unexpected {s} event for {s}\n", .{ @tagName(f.watcher.backend()), @tagName(event.kind), event.path });
            return error.UnexpectedEvent;
        }
    }

    /// What a plain recursive watch of `watched` costs, with no links
    /// followed: the registrations a following watch must come back to.
    fn plainRegistrations(f: *Fixture, backend: lookout.Backend, filter: lookout.Filter) !usize {
        var plain = try Watcher.init(gpa, io, .{ .backend = backend });
        defer plain.deinit();
        const root = try f.path("watched");
        defer gpa.free(root);
        _ = try plain.add(root, .{ .recursive = true, .filter = filter });
        return plain.stats().registrations;
    }
};

/// Turns the empty directory `at` into a junction leading to `target`,
/// both absolute: an `IO_REPARSE_TAG_MOUNT_POINT` reparse point set with
/// `FSCTL_SET_REPARSE_POINT`, which is what `mklink /J` does.
fn junction(at: []const u8, target: []const u8) !void {
    const w = std.os.windows;
    const nt_at = try std.unicode.wtf8ToWtf16LeAlloc(gpa, at);
    defer gpa.free(nt_at);
    const prefixed_at = try std.mem.concat(gpa, u16, &.{ std.unicode.wtf8ToWtf16LeStringLiteral("\\??\\"), nt_at });
    defer gpa.free(prefixed_at);
    var handle: w.HANDLE = undefined;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    var object_name = w.UNICODE_STRING.init(prefixed_at);
    const attributes: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = null, .ObjectName = &object_name };
    switch (w.ntdll.NtCreateFile(
        &handle,
        .{ .GENERIC = .{ .READ = true, .WRITE = true }, .STANDARD = .{ .SYNCHRONIZE = true } },
        &attributes,
        &iosb,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true },
        null,
        0,
    )) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    defer _ = w.ntdll.NtClose(handle);

    // REPARSE_DATA_BUFFER with its MountPointReparseBuffer: the tag, the
    // length of what follows the eight-byte header, four offsets and
    // lengths in bytes, then the NT name and the printed name, each
    // terminated. The lengths leave the terminators out.
    const print = try std.unicode.wtf8ToWtf16LeAlloc(gpa, target);
    defer gpa.free(print);
    const substitute = try std.mem.concat(gpa, u16, &.{ std.unicode.wtf8ToWtf16LeStringLiteral("\\??\\"), print });
    defer gpa.free(substitute);
    const names = (substitute.len + 1 + print.len + 1) * 2;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    const little = std.builtin.Endian.little;
    try appendInt(&data, u32, 0xA000_0003, little);
    try appendInt(&data, u16, @intCast(8 + names), little);
    try appendInt(&data, u16, 0, little);
    try appendInt(&data, u16, 0, little);
    try appendInt(&data, u16, @intCast(substitute.len * 2), little);
    try appendInt(&data, u16, @intCast((substitute.len + 1) * 2), little);
    try appendInt(&data, u16, @intCast(print.len * 2), little);
    for ([_][]const u16{ substitute, print }) |name| {
        for (name) |unit| try appendInt(&data, u16, unit, little);
        try appendInt(&data, u16, 0, little);
    }
    switch (w.ntdll.NtFsControlFile(handle, null, null, null, &iosb, .SET_REPARSE_POINT, data.items.ptr, @intCast(data.items.len), null, 0)) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn appendInt(data: *std.ArrayList(u8), comptime T: type, value: T, endian: std.builtin.Endian) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, endian);
    try data.appendSlice(gpa, &bytes);
}

test "a followed link reports what happens below it under its own path" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/target");
        try f.link("outside/target", "watched/link");
        _ = try f.watch(.{});

        try f.write("outside/target/inside.txt");
        try f.expect("watched/link/inside.txt", .created, &.{"outside"});
        try f.tmp.dir.createDirPath(io, "outside/target/sub");
        try f.write("outside/target/sub/deep.txt");
        try f.expect("watched/link/sub/deep.txt", .created, &.{"outside"});
    }
}

test "a link that leads back into the watch, or above it, is not walked again" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "watched/a");
        try f.link("watched", "watched/a/up");
        try f.link("watched/a", "watched/a/self");
        try f.link("watched/a", "watched/twin");
        try f.link(".", "watched/a/top");
        const plain = try f.plainRegistrations(backend, .none);
        _ = try f.watch(.{});
        // Every link here leads where the watch already is: following
        // none of them costs nothing beyond the watch itself.
        try testing.expectEqual(plain, f.watcher.stats().registrations);

        const through = [_][]const u8{ "watched/a/up", "watched/a/self", "watched/twin", "watched/a/top" };
        try f.write("watched/a/file.txt");
        try f.expect("watched/a/file.txt", .created, &through);
        try f.quiet(&through);
    }
}

test "a link to a directory another link reached first takes over when that one goes" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/target");
        try f.link("outside/target", "watched/first");
        const plain = try f.plainRegistrations(backend, .none);
        _ = try f.watch(.{});
        try f.link("outside/target", "watched/second");
        try f.expect("watched/second", null, &.{});

        try f.write("outside/target/one.txt");
        try f.expect("watched/first/one.txt", .created, &.{"watched/second/one.txt"});

        try f.unlink("watched/first");
        try f.expect("watched/first", null, &.{});
        try f.await(plain, true);
        try f.write("outside/target/two.txt");
        try f.expect("watched/second/two.txt", .created, &.{"watched/first/two.txt"});
    }
}

test "a link made after the watch is followed" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/target/old");
        _ = try f.watch(.{});
        const plain = f.watcher.stats().registrations;
        try f.link("outside/target", "watched/link");
        try f.expect("watched/link", null, &.{});
        try f.await(plain, true);

        try f.write("outside/target/new.txt");
        try f.expect("watched/link/new.txt", .created, &.{"outside"});
        try f.write("outside/target/old/deeper.txt");
        try f.expect("watched/link/old/deeper.txt", .created, &.{"outside"});
    }
}

test "a link changed to lead elsewhere is reported on its path and follows the new directory" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/one");
        // A target of another length, so that the change shows in a
        // listing of the link's own metadata as well.
        try f.tmp.dir.createDirPath(io, "outside/second");
        try f.link("outside/one", "watched/link");
        const id = try f.watch(.{});
        const followed = f.watcher.stats().registrations;

        try f.unlink("watched/link");
        try f.link("outside/second", "watched/link");
        try f.expect("watched/link", null, &.{});
        try f.await(followed, false);

        try f.write("outside/one/old.txt");
        try f.write("outside/second/new.txt");
        try f.expect("watched/link/new.txt", .created, &.{ "outside", "watched/link/old.txt" });
        try f.quiet(&.{"watched/link/old.txt"});
        f.watcher.remove(id);
        try testing.expectEqual(@as(usize, 0), f.watcher.stats().registrations);
    }
}

test "a link that leads nowhere is an entry until it is changed to lead somewhere" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/target");
        try f.link("outside/missing", "watched/link");
        _ = try f.watch(.{});
        const plain = try f.plainRegistrations(backend, .none);
        try testing.expectEqual(plain, f.watcher.stats().registrations);

        try f.unlink("watched/link");
        try f.link("outside/target", "watched/link");
        try f.expect("watched/link", null, &.{});
        try f.await(plain, true);
        try f.write("outside/target/now.txt");
        try f.expect("watched/link/now.txt", .created, &.{"outside"});
    }
}

test "removing a followed link stops watching what it led to" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/target");
        try f.link("outside/target", "watched/link");
        const plain = try f.plainRegistrations(backend, .none);
        _ = try f.watch(.{});
        try testing.expect(f.watcher.stats().registrations > plain);

        try f.unlink("watched/link");
        try f.expect("watched/link", null, &.{});
        try f.await(plain, false);
        try f.write("outside/target/after.txt");
        try f.quiet(&.{ "watched/link", "outside" });
    }
}

test "a link past the most a watch follows is reported unwatched" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/one");
        try f.tmp.dir.createDirPath(io, "outside/two");
        try f.link("outside/one", "watched/first");
        try f.link("outside/two", "watched/second");
        const root = try f.path("watched");
        defer gpa.free(root);
        _ = try f.watcher.add(root, .{ .recursive = true, .follow_symlinks = true, .max_followed_links = 1 });

        const deadline = Deadline.start(io, timeout_ms);
        var unwatched: ?[]u8 = null;
        defer if (unwatched) |p| gpa.free(p);
        while (unwatched == null and !deadline.expired()) {
            for (try f.watcher.poll(100)) |event| {
                if (event.kind == .unwatched) unwatched = try gpa.dupe(u8, event.path);
            }
        }
        const hole = unwatched orelse return error.EventNotObserved;
        // Which of the two is listed first is the file system's to say;
        // the other one is followed.
        const first = try f.path("watched/first");
        defer gpa.free(first);
        const first_is_hole = path_cmp.eql(hole, first);
        const written: []const u8 = if (first_is_hole) "outside/two/seen.txt" else "outside/one/seen.txt";
        const expected: []const u8 = if (first_is_hole) "watched/second/seen.txt" else "watched/first/seen.txt";
        try f.write(written);
        try f.expect(expected, .created, &.{});
    }
}

test "a followed link's changes pass through the watch's filter" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/target");
        try f.tmp.dir.createDirPath(io, "outside/other");
        try f.tmp.dir.createDirPath(io, "watched/skipped");
        try f.link("outside/target", "watched/link");
        try f.link("outside/other", "watched/skipped/link");
        const filter: lookout.Filter = .{ .ignore = &.{ "*.tmp", "skipped" } };
        const plain = try f.plainRegistrations(backend, filter);
        const id = try f.watch(.{ .filter = filter });

        try f.write("outside/target/a.tmp");
        try f.write("outside/target/b.txt");
        try f.write("outside/other/c.txt");
        try f.expect("watched/link/b.txt", .created, &.{ "watched/link/a.tmp", "watched/skipped", "outside" });

        // A filter that leaves the link out lets go of what it led to.
        try f.watcher.refilter(id, .{ .ignore = &.{ "*.tmp", "skipped", "link" } });
        try testing.expectEqual(plain, f.watcher.stats().registrations);
        try f.write("outside/target/d.txt");
        try f.quiet(&.{ "watched/link", "outside" });
    }
}

test "a pending watch follows the links of the directory it becomes" {
    for (backends) |backend| {
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/target");
        const later = try f.path("later");
        defer gpa.free(later);
        _ = try f.watcher.add(later, .{ .pending = true, .recursive = true, .follow_symlinks = true });
        try f.tmp.dir.createDirPath(io, "later");
        try f.link("outside/target", "later/link");
        try f.expect("later", .created, &.{});
        try f.settle();

        try f.write("outside/target/x.txt");
        try f.expect("later/link/x.txt", .created, &.{"outside"});
    }
}

test "a watch that follows a link produces no checkpoint" {
    for (backends) |backend| {
        if (!lookout.tracksCheckpoint(backend)) continue;
        var f = try Fixture.init(backend);
        defer f.deinit();
        try f.tmp.dir.createDirPath(io, "outside/target");
        _ = try f.watch(.{});
        var before = (try f.watcher.checkpoint(gpa)) orelse return error.TestUnexpectedResult;
        before.deinit();
        const plain = f.watcher.stats().registrations;
        try f.link("outside/target", "watched/link");
        try f.expect("watched/link", null, &.{});
        try f.await(plain, true);
        try testing.expect(try f.watcher.checkpoint(gpa) == null);
    }
}
