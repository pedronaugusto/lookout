//! Baseline's tests: seeding, diffing, saving and loading against a scratch
//! tree, with airlock's seam failing the writes and shakedown's allocators
//! the allocations.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const shakedown = @import("shakedown");
const seam = @import("airlock.testing");
const Baseline = @import("Baseline.zig");
const format = @import("Baseline/format.zig");
const types = @import("types.zig");
const Snapshot = @import("Snapshot.zig");
const Kind = types.Kind;
const Target = types.Target;
const Options = Baseline.Options;
const Change = Baseline.Change;

/// How many changes of `kind` the diff holds, and the path of the first.
fn count(changes: []const Change, kind: Kind) usize {
    var found: usize = 0;
    for (changes) |change| {
        if (change.kind == kind) found += 1;
    }
    return found;
}

fn holds(changes: []const Change, root: []const u8, sub_path: []const u8, kind: Kind) !bool {
    const gpa = testing.allocator;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    try parts.append(gpa, root);
    var it = std.mem.splitScalar(u8, sub_path, '/');
    while (it.next()) |part| try parts.append(gpa, part);
    const wanted = try std.Io.Dir.path.join(gpa, parts.items);
    defer gpa.free(wanted);

    for (changes) |change| {
        if (change.kind == kind and std.mem.eql(u8, change.path, wanted)) return true;
    }
    return false;
}

test "a seeded baseline has nothing to report until something changes" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{});
    defer base.deinit();
    try testing.expectEqual(@as(usize, 0), (try base.diff(io)).len);
}

test "a diff names what was created, changed and removed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{});
    defer base.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one and two" });
    try tmp.dir.deleteFile(io, "old.txt");

    const changes = try base.diff(io);
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expect(try holds(changes, root, "new.txt", .created));
    try testing.expect(try holds(changes, root, "kept.txt", .modified));
    try testing.expect(try holds(changes, root, "old.txt", .removed));

    // The baseline is now what it found, so the same diff twice says
    // nothing the second time.
    try testing.expectEqual(@as(usize, 0), (try base.diff(io)).len);
}

test "a rewrite that keeps the size and the modification time is a modification" {
    // As a rewrite within one tick of the file system's clock leaves them:
    // the timestamps are racy, so the contents decide.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const was = try tmp.dir.statFile(io, "a.txt", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{});
    defer base.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "two" });
    const file = try tmp.dir.openFile(io, "a.txt", .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = was.mtime } });

    const changes = try base.diff(io);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expect(try holds(changes, root, "a.txt", .modified));
}

test "a recursive baseline follows subdirectories" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit();

    try tmp.dir.createDirPath(io, "sub/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deeper/a.txt", .data = "one" });

    const changes = try base.diff(io);
    try testing.expect(try holds(changes, root, "sub/deeper", .created));
    try testing.expect(try holds(changes, root, "sub/deeper/a.txt", .created));

    // A non-recursive one covers the root and nothing below it.
    var shallow = try Baseline.seed(gpa, io, root, .{});
    defer shallow.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deeper/b.txt", .data = "two" });
    try testing.expectEqual(@as(usize, 0), (try shallow.diff(io)).len);
}

test "a removed directory takes everything it held with it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/a.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/deep/b.txt", .data = "two" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit();

    try tmp.dir.deleteTree(io, "tree");

    // Every path that is gone, not only the directory the caller could
    // have worked out for itself.
    const changes = try base.diff(io);
    try testing.expect(try holds(changes, root, "tree", .removed));
    try testing.expect(try holds(changes, root, "tree/a.txt", .removed));
    try testing.expect(try holds(changes, root, "tree/deep", .removed));
    try testing.expect(try holds(changes, root, "tree/deep/b.txt", .removed));
}

/// The target the diff gives `sub_path`, which it must hold once.
fn targetOf(changes: []const Change, root: []const u8, sub_path: []const u8) !Target {
    const gpa = testing.allocator;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    try parts.append(gpa, root);
    var it = std.mem.splitScalar(u8, sub_path, '/');
    while (it.next()) |part| try parts.append(gpa, part);
    const wanted = try std.Io.Dir.path.join(gpa, parts.items);
    defer gpa.free(wanted);
    var found: ?Target = null;
    for (changes) |change| if (std.mem.eql(u8, change.path, wanted)) {
        try testing.expect(found == null);
        found = change.target;
    };
    return found orelse error.TestExpectedChange;
}

test "a change says whether its path is a file or a directory, gone or not" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/a.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/deep/b.txt", .data = "two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "edited.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "turns.txt", .data = "a file" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit();

    // Gone: no stat could say what these were, and the diff still does.
    try tmp.dir.deleteTree(io, "tree");
    try tmp.dir.writeFile(io, .{ .sub_path = "edited.txt", .data = "longer now" });
    try tmp.dir.createDirPath(io, "made/inner");
    try tmp.dir.deleteFile(io, "turns.txt");
    try tmp.dir.createDir(io, "turns.txt", .default_dir);

    const changes = try base.diff(io);
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "tree"));
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "tree/deep"));
    try testing.expectEqual(Target.file, try targetOf(changes, root, "tree/a.txt"));
    try testing.expectEqual(Target.file, try targetOf(changes, root, "tree/deep/b.txt"));
    try testing.expectEqual(Target.file, try targetOf(changes, root, "edited.txt"));
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "made"));
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "made/inner"));
    // A name that changed kind is what it is now.
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "turns.txt"));
    for (changes) |change| try testing.expect(change.target != .unknown);
}

test "a filter keeps a subtree out of the diff" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skip");
    try tmp.dir.createDirPath(io, "keep");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{
        .recursive = true,
        .filter = .{ .ignore = &.{ "skip", "*.tmp" } },
    });
    defer base.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "skip/a.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep/b.tmp", .data = "two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep/b.txt", .data = "three" });

    const changes = try base.diff(io);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expect(try holds(changes, root, "keep/b.txt", .created));
}

test "an only filter traverses ancestors of matching descendants" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/deep");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{
        .recursive = true,
        .filter = .{ .only = &.{"src/**/*.zig"} },
    });
    defer base.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/main.zig", .data = "const x = 1;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/notes.txt", .data = "ignored" });

    const changes = try base.diff(io);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expect(try holds(changes, root, "src/deep/main.zig", .created));
}

test "a directory past the entry limit says the diff is incomplete" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{ .max_dir_entries = 2 });
    defer base.deinit();

    for (0..6) |i| {
        var name: [8]u8 = undefined;
        try tmp.dir.writeFile(io, .{
            .sub_path = std.mem.print(&name, "f{d}", .{i}) catch unreachable,
            .data = "x",
        });
    }

    // The same word the watcher uses, meaning the same thing: this answer
    // is not the whole answer.
    const changes = try base.diff(io);
    try testing.expect(count(changes, .overflow) >= 1);
    try testing.expectEqualStrings(root, changes[0].path);
}

test "a baseline whose root is gone says so" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "target/a.txt", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, "target", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{});
    defer base.deinit();

    try tmp.dir.deleteTree(io, "target");
    const changes = try base.diff(io);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings(root, changes[0].path);
    try testing.expectEqual(Kind.removed, changes[0].kind);
}

test "a baseline reports its root removal only once" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "target");
    const root = try tmp.dir.realPathFileAlloc(io, "target", gpa);
    defer gpa.free(root);
    var base = try Baseline.seed(gpa, io, root, .{});
    defer base.deinit();
    try tmp.dir.deleteTree(io, "target");
    try testing.expectEqual(@as(usize, 1), (try base.diff(io)).len);
    try testing.expectEqual(@as(usize, 0), (try base.diff(io)).len);
    try tmp.dir.createDirPath(io, "target");
    _ = try base.diff(io);
    try tmp.dir.deleteTree(io, "target");
    try testing.expectEqual(@as(usize, 1), (try base.diff(io)).len);
    try testing.expectEqual(@as(usize, 0), (try base.diff(io)).len);
}

test "seeding a file rather than a directory is refused" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const path = try tmp.dir.realPathFileAlloc(io, "a.txt", gpa);
    defer gpa.free(path);

    try testing.expectError(error.NotDir, Baseline.seed(gpa, io, path, .{}));
}

test "directory access failures are not removals" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "blocked/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked/deep/kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    inline for (.{ error.AccessDenied, error.Canceled, error.SystemResources }) |failure| {
        inline for (.{ false, true }) |subtree| {
            var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
            defer base.deinit();
            const before = base.dirs.count();
            const fio = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{.{
                .at = .{ .nth = .{ .call = .dirOpenDir, .n = 1, .path = if (subtree) .{ .suffix = "blocked" } else .any } },
                .fault = .{ .fail = failure },
                .times = 0,
            }} });
            defer fio.deinit();
            try testing.expectError(failure, base.diff(fio.io()));
            try testing.expectEqual(before, base.dirs.count());
            try testing.expectEqual(@as(usize, 0), count(base.changes.items, .removed));
            try testing.expectEqual(@as(usize, 0), (try base.diff(io)).len);
        }
    }
}

test "a failed baseline traversal leaves changes for the retry" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "blocked");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "new", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked/new", .data = "two" });

    const fio = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .dirOpenDir, .n = 1, .path = .{ .suffix = "blocked" } } },
        .fault = .{ .fail = error.AccessDenied },
        .times = 0,
    }} });
    defer fio.deinit();
    try testing.expectError(error.AccessDenied, base.diff(fio.io()));
    const changes = try base.diff(io);
    try testing.expect(try holds(changes, root, "new", .created));
    try testing.expect(try holds(changes, root, "blocked/new", .created));
    try testing.expectEqual(@as(usize, 0), (try base.diff(io)).len);
}

test "a failed baseline allocation leaves every change for the retry" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        try tmp.dir.writeFile(io, .{ .sub_path = "old", .data = "one" });
        try tmp.dir.writeFile(io, .{ .sub_path = "sub/changed", .data = "one" });
        var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
        defer base.deinit();
        try tmp.dir.deleteFile(io, "old");
        try tmp.dir.writeFile(io, .{ .sub_path = "new", .data = "one" });
        try tmp.dir.writeFile(io, .{ .sub_path = "sub/changed", .data = "one and two" });
        defer tmp.dir.deleteFile(io, "new") catch unreachable;

        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        base.gpa = failing.allocator();
        const result = base.diff(io);
        base.gpa = gpa;
        if (result) |_| {
            try testing.expect(!failing.has_induced_failure);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            const changes = try base.diff(io);
            try testing.expect(try holds(changes, root, "old", .removed));
            try testing.expect(try holds(changes, root, "new", .created));
            try testing.expect(try holds(changes, root, "sub/changed", .modified));
            try testing.expectEqual(@as(usize, 0), (try base.diff(io)).len);
        }
    }
}

test "a truncated baseline keeps remembered subtrees until a complete scan" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deep/kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit();

    // No entries can be read with this budget. Nothing about a path's
    // existence follows from its absence in that listing.
    base.max_dir_entries = 0;
    const incomplete = try base.diff(io);
    try testing.expect(count(incomplete, .overflow) > 0);
    try testing.expectEqual(@as(usize, 0), count(incomplete, .removed));
    try testing.expectEqual(@as(usize, 3), base.dirs.count());
    try tmp.dir.deleteFile(io, "sub/deep/kept");
    base.max_dir_entries = 4096;
    const complete = try base.diff(io);
    try testing.expect(try holds(complete, root, "sub/deep/kept", .removed));
    try testing.expectEqual(@as(usize, 0), (try base.diff(io)).len);
}

test "a saved baseline reports changes since last run and replaces its file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/sub/gone", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, "tree", gpa);
    defer gpa.free(root);
    const parent = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(parent);
    const file = try std.Io.Dir.path.join(gpa, &.{ parent, "baseline" });
    defer gpa.free(file);
    const options: Options = .{ .recursive = true, .filter = .{ .ignore = &.{"*.tmp"} } };
    {
        var base = try Baseline.seed(gpa, io, root, options);
        defer base.deinit();
        try base.save(io, file, .{});
    }
    try tmp.dir.deleteTree(io, "tree/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/kept", .data = "changed size" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/new", .data = "new" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/ignore.tmp", .data = "new" });
    var loaded = try Baseline.load(gpa, io, file, root, options);
    defer loaded.deinit();
    const changes = try loaded.diff(io);
    try testing.expectEqual(@as(usize, 4), changes.len);
    try testing.expect(try holds(changes, root, "sub/gone", .removed));
    try testing.expectEqual(Target.file, try targetOf(changes, root, "sub/gone"));
    try testing.expect(try holds(changes, root, "sub", .removed));
    try testing.expect(try holds(changes, root, "kept", .modified));
    try testing.expect(try holds(changes, root, "new", .created));
    try loaded.save(io, file, .{});
    var again = try Baseline.load(gpa, io, file, root, options);
    defer again.deinit();
    try testing.expectEqual(@as(usize, 0), (try again.diff(io)).len);
    try testing.expectError(error.ForeignBaseline, Baseline.load(gpa, io, file, parent, options));
    try testing.expectError(error.ForeignBaseline, Baseline.load(gpa, io, file, root, .{}));
    try tmp.dir.deleteTree(io, "tree");
    var missing = try Baseline.load(gpa, io, file, root, options);
    defer missing.deinit();
    try testing.expectEqual(@as(usize, 1), (try missing.diff(io)).len);
    try testing.expectEqual(@as(usize, 0), (try missing.diff(io)).len);
}

test "a cancel that lands on a saved baseline's length is load's Canceled" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    const file = try std.Io.Dir.path.join(gpa, &.{ root, "baseline" });
    defer gpa.free(file);
    {
        var base = try Baseline.seed(gpa, testing.io, root, .{});
        defer base.deinit();
        try base.save(testing.io, file, .{});
    }
    // The file's length is the one stat the read makes. std's whole-file
    // read took a cancel there for a length it could not learn, and read on.
    const fio = try shakedown.FaultIo.init(gpa, testing.io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .fileStat, .n = 1 } },
        .fault = .cancel,
    }} });
    defer fio.deinit();
    try testing.expectError(error.Canceled, Baseline.load(gpa, fio.io(), file, root, .{}));
    var loaded = try Baseline.load(gpa, testing.io, file, root, .{});
    defer loaded.deinit();
}

test "a cancel while the root's names are measured is returned, not taken for names that say nothing" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    // The kernel's spelling of the root (Darwin), whether it is a
    // directory, and the directory opened to read its naming flags
    // (Linux on ext4 or f2fs, Windows). Where the system makes no such
    // call, the plan never fires and the seed stands.
    const looks = [_]shakedown.IoPlan.At{
        .{ .nth = .{ .call = .dirOpenFile, .n = 1, .path = .{ .exact = root } } },
        .{ .nth = .{ .call = .dirStatFile, .n = 1, .path = .{ .exact = root } } },
        .{ .nth = .{ .call = .dirOpenDir, .n = 1, .path = .{ .exact = root } } },
    };
    for (looks) |at| {
        const fio = try shakedown.FaultIo.init(gpa, testing.io, .{ .plan = &.{.{ .at = at, .fault = .cancel, .times = 1 }} });
        defer fio.deinit();
        if (Baseline.seed(gpa, fio.io(), root, .{})) |seeded| {
            var base = seeded;
            defer base.deinit();
            try testing.expectEqual(@as(usize, 0), fio.fired().len);
        } else |err| try testing.expectEqual(error.Canceled, err);
    }
}

test "baseline storage refuses corrupt foreign and old files by name" {
    const gpa = testing.allocator;
    const root = if (builtin.target.os.tag == .windows) "C:\\tree" else "/tree";
    const state: format.State = .{ .platform = format.platform, .root = root, .recursive = false, .max_dir_entries = 4096, .ignore = &.{}, .only = &.{}, .dirs = &.{} };
    const bytes = try format.encode(gpa, state);
    defer gpa.free(bytes);
    bytes[bytes.len - 1] ^= 1;
    try testing.expectError(error.InvalidBaseline, format.parse(gpa, bytes));
    bytes[bytes.len - 1] ^= 1;
    bytes[8] = 0;
    try testing.expectError(error.UnsupportedBaselineVersion, format.parse(gpa, bytes));
    var foreign = state;
    foreign.platform = "foreign";
    const other = try format.encode(gpa, foreign);
    defer gpa.free(other);
    try testing.expectError(error.ForeignBaseline, format.parse(gpa, other));
}

test "a failed baseline replacement leaves the previous file intact" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree");
    const root = try tmp.dir.realPathFileAlloc(io, "tree", gpa);
    defer gpa.free(root);
    const parent = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(parent);
    const filename = try std.Io.Dir.path.join(gpa, &.{ parent, "saved" });
    defer gpa.free(filename);
    var b = try Baseline.seed(gpa, io, root, .{});
    defer b.deinit();
    try b.save(io, filename, .{});
    const original = try tmp.dir.readFileAlloc(io, "saved", gpa, .unlimited);
    defer gpa.free(original);
    // Write only a prefix into the temporary file, then fail.
    const fio = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .fileWritePositional, .n = 1 } }, .fault = .{ .short = 8 } },
        .{ .at = .{ .nth = .{ .call = .fileWritePositional, .n = 2 } }, .fault = .{ .fail = error.NoSpaceLeft } },
    } });
    defer fio.deinit();
    try testing.expectError(error.NoSpaceLeft, b.save(fio.io(), filename, .{}));
    const after = try tmp.dir.readFileAlloc(io, "saved", gpa, .unlimited);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, original, after);
    try testing.expectEqual(@as(usize, 2), try countEntries(tmp.dir)); // tree and saved; no leaked temporary file
}

test "baseline storage validates checksummed paths before trusting them" {
    const gpa = testing.allocator;
    const root = if (builtin.target.os.tag == .windows) "C:\\tree" else "/tree";
    const bad = try std.Io.Dir.path.join(gpa, &.{ root, "..", "outside" });
    defer gpa.free(bad);
    const directory: format.Directory = .{ .path = bad, .truncated = false, .check_contents = false, .entries = &.{} };
    const state: format.State = .{ .platform = format.platform, .root = root, .recursive = true, .max_dir_entries = 4096, .ignore = &.{}, .only = &.{}, .dirs = &.{directory} };
    const bytes = try format.encode(gpa, state);
    defer gpa.free(bytes);
    try testing.expectError(error.InvalidBaseline, format.parse(gpa, bytes));
}

test "a durable save syncs the file before the replacement and its directory after" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree");
    const root = try tmp.dir.realPathFileAlloc(io, "tree", gpa);
    defer gpa.free(root);
    const parent = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(parent);
    const filename = try std.Io.Dir.path.join(gpa, &.{ parent, "saved" });
    defer gpa.free(filename);
    var b = try Baseline.seed(gpa, io, root, .{});
    defer b.deinit();
    try b.save(io, filename, .{});
    const original = try tmp.dir.readFileAlloc(io, "saved", gpa, .unlimited);
    defer gpa.free(original);
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/new", .data = "one" });
    _ = try b.diff(io);

    // The temp's sync is whichever call the platform makes for it, the
    // first of these on a path with the temp's prefix.
    const file_sync = [_]seam.Plan.Entry{
        .{ .at = .{ .nth = .{ .call = .sync_data, .n = 1, .path = .{ .prefix = Baseline.temp_prefix } } }, .fault = .{ .code = seam.io_error } },
        .{ .at = .{ .nth = .{ .call = .sync_full, .n = 1, .path = .{ .prefix = Baseline.temp_prefix } } }, .fault = .{ .code = seam.io_error } },
        .{ .at = .{ .nth = .{ .call = .sync_barrier, .n = 1, .path = .{ .prefix = Baseline.temp_prefix } } }, .fault = .{ .code = seam.io_error } },
        .{ .at = .{ .nth = .{ .call = .sync_plain, .n = 1, .path = .{ .prefix = Baseline.temp_prefix } } }, .fault = .{ .code = seam.io_error } },
        .{ .at = .{ .nth = .{ .call = .sync_writeout, .n = 1, .path = .{ .prefix = Baseline.temp_prefix } } }, .fault = .{ .code = seam.io_error } },
    };

    // A failed sync of the new contents leaves the old file, and no temp.
    {
        const hooked = try seam.Seam.create(gpa, io, .{ .plan = &file_sync });
        defer hooked.destroy();
        try testing.expectError(error.InputOutput, b.save(hooked.io(), filename, .{ .durable = true }));
        const unchanged = try tmp.dir.readFileAlloc(io, "saved", gpa, .unlimited);
        defer gpa.free(unchanged);
        try testing.expectEqualSlices(u8, original, unchanged);
        try testing.expectEqual(@as(usize, 2), try countEntries(tmp.dir));
    }
    // A failed directory sync comes after the replacement: the new file
    // is what a reader sees, and the save says it is not durable.
    {
        const hooked = try seam.Seam.create(gpa, io, .{ .plan = &.{seam.fail(.sync_dir, 1, seam.io_error)} });
        defer hooked.destroy();
        try testing.expectError(error.PublishedNotDurable, b.save(hooked.io(), filename, .{ .durable = true }));
        var replaced = try Baseline.load(gpa, io, filename, root, .{});
        defer replaced.deinit();
        try testing.expectEqual(@as(usize, 0), (try replaced.diff(io)).len);
    }
    // Two syncs make a durable save, on every platform, and none a plain one.
    {
        const hooked = try seam.Seam.create(gpa, io, .{});
        defer hooked.destroy();
        try b.save(hooked.io(), filename, .{ .durable = true });
        try testing.expectEqual(@as(u32, 2), hooked.syncs());
        hooked.reset();
        try b.save(hooked.io(), filename, .{});
        try testing.expectEqual(@as(u32, 0), hooked.syncs());
        try testing.expectEqual(@as(usize, 2), try countEntries(tmp.dir));
    }
}

/// How many entries `dir` holds.
fn countEntries(dir: Io.Dir) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |_| n += 1;
    return n;
}

test "a save keeps the permissions of the baseline it replaces" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree");
    const root = try tmp.dir.realPathFileAlloc(io, "tree", gpa);
    defer gpa.free(root);
    const parent = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(parent);
    const filename = try std.Io.Dir.path.join(gpa, &.{ parent, "saved" });
    defer gpa.free(filename);
    var b = try Baseline.seed(gpa, io, root, .{});
    defer b.deinit();
    try b.save(io, filename, .{});
    {
        const file = try tmp.dir.openFile(io, "saved", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o600));
    }
    // A replace never widens who can read the baseline.
    for ([_]bool{ false, true }) |durable| {
        try b.save(io, filename, .{ .durable = durable });
        const stat = try tmp.dir.statFile(io, "saved", .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
}

test "baseline storage retains explicit name policy and normalized filter preferences" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree");
    const root = try tmp.dir.realPathFileAlloc(io, "tree", gpa);
    defer gpa.free(root);
    const parent = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(parent);
    const file = try std.Io.Dir.path.join(gpa, &.{ parent, "saved" });
    defer gpa.free(file);
    const options: Options = .{ .filter = .{ .ignore = &.{"[é]"}, .case = .sensitive, .normalization = .nfc }, .identity = .{ .case_sensitive = false } };
    var before = try Baseline.seed(gpa, io, root, options);
    defer before.deinit();
    try before.save(io, file, .{});
    var after = try Baseline.load(gpa, io, file, root, options);
    defer after.deinit();
    var changed = options;
    changed.filter.normalization = .exact;
    try testing.expectError(error.ForeignBaseline, Baseline.load(gpa, io, file, root, changed));
    changed = options;
    changed.identity = null;
    try testing.expectError(error.ForeignBaseline, Baseline.load(gpa, io, file, root, changed));
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/e\u{301}", .data = "accent" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/e", .data = "plain" });
    const changes = try after.diff(io);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expect(std.mem.endsWith(u8, changes[0].path, std.Io.Dir.path.sep_str ++ "e"));
}

test "a baseline reads and writes the bytes std.json wrote, names that are not UTF-8 among them" {
    const gpa = std.testing.allocator;
    const root = if (builtin.target.os.tag == .windows) "C:\\tree" else "/tree";
    const meta: Snapshot.Meta = .{ .size = 3, .mtime = .fromRaw(1_761_300_000_123_456_789), .ctime = .fromRaw(-1), .file_kind = .file, .racy = true, .content_hash = 7 };
    const entries = [_]format.Entry{ .{ .name = "caf\u{e9}", .meta = .of(meta) }, .{ .name = "a\xffb", .meta = .of(meta) } };
    const dirs = [_]format.Directory{.{ .path = root, .truncated = false, .check_contents = true, .entries = &entries }};
    const state: format.State = .{ .platform = format.platform, .root = root, .recursive = true, .max_dir_entries = 4096, .ignore = &.{ "*.o", "\xfe" }, .only = &.{}, .dirs = &dirs, .case = .ascii };
    // The payload as baselines before strand were written.
    const standard = try std.json.Stringify.valueAlloc(gpa, state, .{});
    defer gpa.free(standard);
    const bytes = try format.encode(gpa, state);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.endsWith(u8, bytes, standard));
    // An entry's times are written as the integers of nanoseconds they were.
    try std.testing.expect(std.mem.find(u8, bytes, "{\"size\":3,\"mtime_ns\":1761300000123456789,\"ctime_ns\":-1,\"file_kind\":\"file\",\"racy\":true,\"content_hash\":7}") != null);
    var parsed = try format.parse(gpa, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, "a\xffb", parsed.value.dirs[0].entries[1].name);
    try std.testing.expectEqualSlices(u8, "\xfe", parsed.value.ignore[1]);
    try std.testing.expectEqual(meta, parsed.value.dirs[0].entries[1].meta.snapshot());
}
