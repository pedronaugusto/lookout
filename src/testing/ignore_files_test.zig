//! A watch's ignore files (`Filter.ignore_files`): read as git reads
//! them, read again when an event names one, an unreadable one listed,
//! and a read that runs out of memory a failure, never an answer.

const std = @import("std");
const builtin = @import("builtin");
const lookout = @import("../lookout.zig");
const CompiledFilter = @import("../CompiledFilter.zig");
const IgnoreState = @import("../IgnoreState.zig");
const wait = @import("timeout.zig");
const ms = wait.ms;
const Watcher = lookout.Watcher;
const testing = std.testing;

/// Polls until the system is past what was caused before, and says whether
/// an event named `expected` among what was reported.
fn reported(w: *Watcher, io: std.Io, expected: []const u8) !bool {
    var seen = false;
    var pace: wait.Pace = try .start(w);
    defer pace.end();
    while (try pace.running()) {
        for (try pace.poll(io, ms(50))) |event| {
            if (std.mem.eql(u8, event.path, expected)) seen = true;
        }
    }
    return seen;
}

/// Writes `name` under `dir` and fails unless the watch reported it exactly
/// when `wanted` says it should, naming the backend and the stage.
fn expectWrite(w: *Watcher, io: std.Io, dir: std.Io.Dir, root: []const u8, stage: []const u8, name: []const u8, wanted: bool) !void {
    const got = try writeReported(w, io, dir, root, name);
    if (got == wanted) return;
    std.debug.print("{t}: with the ignore file {s}, {s} was {s}\n", .{ w.backend(), stage, name, if (got) "reported, and the ignore file excludes it" else "not reported, and nothing excludes it" });
    if (!got) return wait.missed(w);
    return error.TestUnexpectedResult;
}

/// Writes `name` under `dir` and says whether the watch reported it.
fn writeReported(w: *Watcher, io: std.Io, dir: std.Io.Dir, root: []const u8, name: []const u8) !bool {
    try dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    const native = try testing.allocator.dupe(u8, name);
    defer testing.allocator.free(native);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, native, '/', '\\');
    const full = try std.Io.Dir.path.join(testing.allocator, &.{ root, native });
    defer testing.allocator.free(full);
    return reported(w, io, full);
}

test "a .gitignore added, changed and removed under a live watch admits and drops the right trees" {
    const gpa = testing.allocator;
    const io = testing.io;
    for (wait.backends) |backend| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "build");
        try tmp.dir.createDirPath(io, "kept");
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{ .backend = backend, .poll_interval = .fromMilliseconds(20) });
        defer watcher.deinit(io);
        const id = try wait.add(&watcher, io, root, .{ .recursive = true, .filter = .{ .ignore_files = .{} } });
        try wait.drain(&watcher, io);

        // No ignore file: every tree is the watch's.
        try expectWrite(&watcher, io, tmp.dir, root, "absent", "build/a.txt", true);
        try expectWrite(&watcher, io, tmp.dir, root, "absent", "kept/a.txt", true);

        // Added: what it names is dropped, what it does not is kept.
        try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "build/\n" });
        try wait.drain(&watcher, io);
        try expectWrite(&watcher, io, tmp.dir, root, "added", "build/b.txt", false);
        try expectWrite(&watcher, io, tmp.dir, root, "added", "kept/b.txt", true);

        // Changed: the tree it named is admitted again, and the one it
        // names now is dropped.
        try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "kept/\n" });
        try wait.drain(&watcher, io);
        try expectWrite(&watcher, io, tmp.dir, root, "changed", "build/c.txt", true);
        try expectWrite(&watcher, io, tmp.dir, root, "changed", "kept/c.txt", false);

        // Removed: every tree is the watch's again.
        try tmp.dir.deleteFile(io, ".gitignore");
        try wait.drain(&watcher, io);
        try expectWrite(&watcher, io, tmp.dir, root, "removed", "build/d.txt", true);
        try expectWrite(&watcher, io, tmp.dir, root, "removed", "kept/d.txt", true);
        try testing.expectEqual(@as(usize, 0), watcher.unreadIgnoreFiles(id).len);
    }
}

test "an unreadable ignore file is listed, not silently skipped" {
    // Windows has no mode bits to take reading away with.
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    for (wait.backends) |backend| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.txt\n" });
        var unreadable = try tmp.dir.openFile(io, ".gitignore", .{});
        try unreadable.setPermissions(io, .fromMode(0));
        unreadable.close(io);
        defer {
            var restored = tmp.dir.openFile(io, ".gitignore", .{ .mode = .write_only }) catch null;
            if (restored) |*f| {
                f.setPermissions(io, .fromMode(0o644)) catch {};
                f.close(io);
            }
        }
        // A process that reads it anyway (root) has nothing to test.
        if (tmp.dir.readFileAlloc(io, ".gitignore", gpa, .limited(64))) |bytes| {
            gpa.free(bytes);
            return error.SkipZigTest;
        } else |_| {}
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);

        var watcher: Watcher = try .init(gpa, io, .{ .backend = backend, .poll_interval = .fromMilliseconds(20) });
        defer watcher.deinit(io);
        const id = try wait.add(&watcher, io, root, .{ .filter = .{ .ignore_files = .{} } });
        try wait.drain(&watcher, io);

        // It counts as absent, as git warns and goes on: what it would
        // have excluded is reported.
        try testing.expect(try writeReported(&watcher, io, tmp.dir, root, "a.txt"));
        const listed = watcher.unreadIgnoreFiles(id);
        const expected = try std.Io.Dir.path.join(gpa, &.{ root, ".gitignore" });
        defer gpa.free(expected);
        try testing.expectEqual(@as(usize, 1), listed.len);
        try testing.expectEqualStrings(expected, listed[0]);
    }
}

test "an ignore file read out of memory fails the question, and never answers kept" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "deep/er");
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "deep/.gitignore", .data = "er/\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const ignored_file = try std.Io.Dir.path.join(testing.allocator, &.{ root, "deep", "x.log" });
    defer testing.allocator.free(ignored_file);
    const ignored_dir = try std.Io.Dir.path.join(testing.allocator, &.{ root, "deep", "er", "y.txt" });
    defer testing.allocator.free(ignored_dir);

    // Every allocation the reading makes fails in turn: each question then
    // either fails or answers right.
    var fail_index: usize = 0;
    var failed_at_least_once = false;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        const state = IgnoreState.create(failing.allocator()) catch {
            failed_at_least_once = true;
            continue;
        };
        defer state.destroy(io);
        var filter: CompiledFilter = try .compile(testing.allocator, .{ .ignore_files = .{ .state = state } });
        defer filter.deinit();
        var answered = true;
        for ([_][]const u8{ ignored_file, ignored_dir }) |subject| {
            const excluded = filter.excludes(io, root, subject) catch |err| switch (err) {
                error.OutOfMemory => {
                    answered = false;
                    failed_at_least_once = true;
                    continue;
                },
                error.Canceled => return err,
            };
            try testing.expect(excluded);
        }
        if (answered and !failing.has_induced_failure) break;
    }
    try testing.expect(failed_at_least_once);
}
