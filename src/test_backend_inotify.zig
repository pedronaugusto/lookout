//! Watcher integration scenarios for inotify.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const lookout = @import("lookout.zig");
const Batch = @import("Batch.zig");
const Budget = @import("Budget.zig");
const Deadline = @import("Deadline.zig");
const Filter = @import("Filter.zig");
const path_cmp = @import("path.zig");
const records = @import("backend/inotify_records.zig");
const walk = @import("walk.zig");
const Waker = @import("Waker.zig");
const Target = lookout.Target;
const WatchId = lookout.WatchId;
const Inotify = @import("backend/inotify.zig");
const Watch = struct {
    /// Absolute, canonical path, owned by the backend.
    root: []u8,
    target: Target,
    recursive: bool,
    /// `@import("options.zig").AddOptions.filter`, copied. An excluded directory is
    /// never registered, so the kernel is never asked for a watch on it.
    filter: Filter,
};
const Pending = struct {
    /// Absolute path the entry moved from, owned by the backend.
    path: []u8,
    is_dir: bool,
};
const PendingKey = struct {
    watch: WatchId,
    cookie: u32,
};
const Registration = struct {
    /// Absolute path the descriptor stands for, owned by the backend.
    path: []u8,
    /// Every caller watch that owns this kernel descriptor.
    watches: std.ArrayList(WatchId),
};
const base_mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY |
    linux.IN.ATTRIB | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
    linux.IN.EXCL_UNLINK | linux.IN.DONT_FOLLOW;
const read_buffer_len = 8192;
const Change = struct {
    watch: WatchId,
    /// The kernel watch descriptor the event arrived on.
    wd: i32,
    /// The directory the watch descriptor stands for, owned by `handle`.
    dir: []u8,
    /// The absolute path of the entry, owned by `handle`.
    path: []u8,
    /// Whether the kernel named an entry of `dir`, rather than reporting
    /// on the watched path itself -- a watched file, say.
    named: bool,
    cookie: u32,
    is_dir: bool,
    appeared: bool,
    vanished: bool,
    moved_from: bool,
    moved_to: bool,
    modified: bool,
    closed: bool,
    attributes: bool,

    fn target(c: Change) Target {
        return if (c.is_dir) .directory else .file;
    }
};

test "the kernel's queue overflow record is an overflow against every watch" {
    // inotify(7): "IN_Q_OVERFLOW: Event queue overflowed (wd is -1 for
    // this event)", and of max_queued_events: "Events in excess of this
    // limit are dropped, but an IN_Q_OVERFLOW event is always
    // generated." The record is written here the way the kernel writes
    // it and read back through the decoder a real read goes through,
    // so that what is asserted is the whole path from the bytes to the
    // batch. src/test_gaps.zig fills a real queue past the limit.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const file = try std.fs.path.join(gpa, &.{ root, "a.txt" });
    defer gpa.free(file);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .inotify });
    defer watcher.deinit();
    const dir = try watcher.add(root, .{ .recursive = true });
    const single = try watcher.add(file, .{});
    while ((try watcher.poll(200)).len != 0) {}

    var bytes: [records.header_len]u8 = undefined;
    const len = records.encode(&bytes, .{ .wd = -1, .mask = linux.IN.Q_OVERFLOW, .cookie = 0, .name = null });
    var it = records.iterate(bytes[0..len]);
    _ = (try it.next()).?;
    try testing.expectEqual(@as(?records.Record, null), try it.next());

    // Straight into the batch the next poll returns, which is where a
    // read puts it.
    const n = &watcher.impl.inotify;
    try @import("backend/inotify.zig").test_access.handleRead(&n, bytes[0..len], &watcher.batch);

    var dir_overflows: usize = 0;
    var file_overflows: usize = 0;
    for (watcher.batch.events.items) |event| {
        try testing.expectEqual(lookout.Kind.overflow, event.kind);
        if (event.id == dir) {
            try testing.expectEqualStrings(root, event.path);
            try testing.expectEqual(Target.directory, event.target);
            dir_overflows += 1;
        } else {
            try testing.expectEqual(single, event.id);
            try testing.expectEqualStrings(file, event.path);
            try testing.expectEqual(Target.file, event.target);
            file_overflows += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), dir_overflows);
    try testing.expectEqual(@as(usize, 1), file_overflows);

    // And nothing about the watches themselves changed: the next write
    // is reported to both.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one and two" });
    var saw_dir = false;
    var saw_file = false;
    var waited: u32 = 0;
    while (waited < 10_000 and !(saw_dir and saw_file)) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind != .modified or !std.mem.eql(u8, event.path, file)) continue;
            if (event.id == dir) saw_dir = true;
            if (event.id == single) saw_file = true;
        }
    }
    try testing.expect(saw_dir);
    try testing.expect(saw_file);
}

test "a queue overflow reads the entry counts again, so the budget holds after it" {
    // Three creations the kernel queues and nobody reads: taken off the
    // queue here and thrown away, which is what an overflowing queue
    // does to the events it has no room for, and then the record that
    // says so, written the way the kernel writes it. The count the
    // budget kept knew nothing of the three, and a count that is not
    // read again stays three short for as long as the watch lasts.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .inotify, .max_dir_entries = 3 });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    while ((try watcher.poll(200)).len != 0) {}
    const n = &watcher.impl.inotify;

    for ([_][]const u8{ "a", "b", "c" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }
    // inotify queues an event as the call that caused it returns, so
    // the three are all there to be lost.
    var scratch: [read_buffer_len]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const len = posix.read(n.ifd, &scratch) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (len == 0) break;
    }

    var bytes: [records.header_len]u8 = undefined;
    const len = records.encode(&bytes, .{ .wd = -1, .mask = linux.IN.Q_OVERFLOW, .cookie = 0, .name = null });
    try @import("backend/inotify.zig").test_access.handleRead(&n, bytes[0..len], &watcher.batch);
    try testing.expectEqual(@as(usize, 1), watcher.batch.events.items.len);
    try testing.expectEqual(lookout.Kind.overflow, watcher.batch.events.items[0].kind);
    // Three entries: at the budget, as the folder is.
    try testing.expectEqual(@as(usize, 3), n.budget.count(root).?);

    // So the fourth is past it, and the watch is told.
    _ = try watcher.poll(0);
    try tmp.dir.writeFile(io, .{ .sub_path = "d", .data = "x" });
    var overflowed = false;
    var waited: u32 = 0;
    while (waited < 10_000 and !overflowed) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind == .overflow and event.id == id and std.mem.eql(u8, event.path, root)) overflowed = true;
        }
    }
    try testing.expect(overflowed);
}

test "a watch on a file keeps no count keyed by the file" {
    // The kernel reports a watched file's own changes on the file's
    // watch, with no name: the file was taken for a directory, and a
    // count of nothing was kept under its path for as long as the watch
    // lasted.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const file = try std.fs.path.join(gpa, &.{ root, "file" });
    defer gpa.free(file);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .inotify });
    defer watcher.deinit();
    const id = try watcher.add(file, .{});
    while ((try watcher.poll(200)).len != 0) {}
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "y" });
    var modified = false;
    var waited: u32 = 0;
    while (waited < 10_000 and !modified) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind == .modified and event.id == id) modified = true;
        }
    }
    try testing.expect(modified);
    try testing.expect(watcher.impl.inotify.budget.count(file) == null);
}
