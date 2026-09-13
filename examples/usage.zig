//! Watch a directory, change it, and print what the watcher reports.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh`
//! extracts the region between the usage markers into README.md, so the
//! snippet a reader copies is code CI executes.

const std = @import("std");
const zwatch = @import("zwatch");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A scratch directory beside the executable, remade on every run.
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, "zwatch-example") catch {};
    defer cwd.deleteTree(io, "zwatch-example") catch {};
    var scratch = try cwd.createDirPathOpen(io, "zwatch-example", .{});
    defer scratch.close(io);
    const dir_path = try scratch.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);

    // --- README:usage ---

    // One watcher, one watch. `auto` means kqueue on macOS and the BSDs,
    // inotify on Linux, and polling anywhere else.
    var watcher: zwatch.Watcher = try .init(gpa, io, .{});
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

    std.debug.print("backend: {s}\n", .{@tagName(watcher.backend())});
}

/// Polls once and prints whatever came back, including where a renamed
/// path came from on the backends that can say.
fn report(watcher: *zwatch.Watcher) !void {
    for (try watcher.poll(2_000)) |event| {
        if (event.from) |from| {
            std.debug.print("{s} {s} (from {s})\n", .{ @tagName(event.kind), event.path, from });
        } else {
            std.debug.print("{s} {s}\n", .{ @tagName(event.kind), event.path });
        }
    }
}
