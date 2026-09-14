//! Watch a directory, change it, and print what the watcher reports.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh`
//! extracts the region between the usage markers into README.md, so the
//! snippet a reader copies is code CI executes.

const std = @import("std");
const lookout = @import("lookout");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A scratch directory beside the executable, remade on every run.
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, "lookout-example") catch {};
    defer cwd.deleteTree(io, "lookout-example") catch {};
    var scratch = try cwd.createDirPathOpen(io, "lookout-example", .{});
    defer scratch.close(io);
    const dir_path = try scratch.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);

    // --- README:usage ---

    // One watcher, one watch. `auto` means FSEvents on Apple platforms,
    // kqueue on the BSDs, inotify on Linux, ReadDirectoryChangesW on
    // Windows, and polling anywhere else.
    var watcher: lookout.Watcher = try .init(gpa, io, .{});
    defer watcher.deinit();

    const id = try watcher.add(dir_path, .{ .recursive = true });
    defer watcher.remove(id);

    // Something changes the tree. In a real program this is someone else:
    // an editor saving, a build writing, a package manager unpacking.
    try scratch.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello" });

    // `poll` blocks until something happens or the timeout expires, and
    // returns one event per path, coalesced. The slice and every path in
    // it belong to the watcher until the next call.
    for (try watcher.poll(1_000)) |event| {
        std.debug.print("{s} {s}\n", .{ @tagName(event.kind), event.path });
    }
    // --- README:usage ---

    // The rest of the run shows the other kinds, one change at a time so
    // that each one is a poll of its own.
    try scratch.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello, again" });
    try report(&watcher);

    try scratch.rename("notes.txt", scratch, "renamed.txt", io);
    try report(&watcher);

    try scratch.createDirPath(io, "sub");
    try report(&watcher);

    try scratch.writeFile(io, .{ .sub_path = "sub/inside.txt", .data = "deep" });
    try report(&watcher);

    try scratch.deleteFile(io, "renamed.txt");
    try report(&watcher);

    // A second watcher, with a filter: the ignore list keeps part of the
    // tree out of the watch entirely. Where lookout does the recursion
    // an ignored directory is never opened and never registered, so it
    // costs nothing; where the kernel recurses it is the events that are
    // dropped, and `prunesIgnored` is how a program asks which it got.
    try scratch.createDirPath(io, "build");
    var filtered: lookout.Watcher = try .init(gpa, io, .{});
    defer filtered.deinit();
    _ = try filtered.add(dir_path, .{
        .recursive = true,
        .filter = .{ .ignore = &.{ "build", "*.tmp" } },
    });

    try scratch.writeFile(io, .{ .sub_path = "build/artifact.o", .data = "ignored" });
    try scratch.writeFile(io, .{ .sub_path = "draft.tmp", .data = "ignored" });
    try scratch.writeFile(io, .{ .sub_path = "kept.txt", .data = "reported" });
    for (try filtered.poll(2_000)) |event| {
        std.debug.print("filtered: {s} {s}\n", .{ @tagName(event.kind), event.path });
    }

    // A watch on a path that is not there yet. It is parked on the
    // nearest existing ancestor, steps down as the path appears, and is
    // promoted to the real watch with the appearance reported against it.
    const later = try std.fs.path.join(gpa, &.{ dir_path, "later", "inside" });
    defer gpa.free(later);
    var pending: lookout.Watcher = try .init(gpa, io, .{});
    defer pending.deinit();
    _ = try pending.add(later, .{ .pending = true, .recursive = true });

    try scratch.createDirPath(io, "later/inside");
    for (try pending.poll(2_000)) |event| {
        std.debug.print("pending: {s} {s}\n", .{ @tagName(event.kind), event.path });
    }

    std.debug.print("backend: {s}\n", .{@tagName(watcher.backend())});
    std.debug.print("prunes ignored: {}\n", .{lookout.prunesIgnored(watcher.backend())});
}

/// Polls once and prints whatever came back, including where a renamed
/// path came from on the backends that can say.
fn report(watcher: *lookout.Watcher) !void {
    for (try watcher.poll(2_000)) |event| {
        if (event.from) |from| {
            std.debug.print("{s} {s} (from {s})\n", .{ @tagName(event.kind), event.path, from });
        } else {
            std.debug.print("{s} {s}\n", .{ @tagName(event.kind), event.path });
        }
    }
}
