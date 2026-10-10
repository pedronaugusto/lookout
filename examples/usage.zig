//! Watch a directory, change it, and print what the watcher reports.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- usage`
//! extracts the region between the usage markers into README.md, so the
//! snippet a reader copies is code CI executes.

const std = @import("std");
const lookout = @import("lookout");

const two_seconds: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } };

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var display_buffer: [4096]u8 = undefined;
    var display = std.Io.File.stdout().writer(io, &display_buffer);
    const output = &display.interface;

    // A scratch directory beside the executable, remade on every run.
    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(io, "lookout-example");
    // glint-ignore: Z026 -- scratch beside the executable; the next run remakes it first
    defer cwd.deleteTree(io, "lookout-example") catch {};
    var scratch = try cwd.createDirPathOpen(io, "lookout-example", .{});
    defer scratch.close(io);
    const dir_path = try scratch.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);

    // --- README:usage ---

    var watcher: lookout.Watcher = try .init(gpa, io, .{});
    defer watcher.deinit(io);

    const id = try watcher.add(io, dir_path, .{ .recursive = true });
    defer watcher.remove(io, id);

    try scratch.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello" });

    const one_second: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };
    for (try watcher.poll(io, one_second)) |event| {
        try output.print("{s} {s}\n", .{ @tagName(event.kind), event.path });
    }
    // --- README:usage ---

    // The rest of the run shows the other kinds, one change at a time so
    // that each one is a poll of its own.
    try scratch.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello, again" });
    try report(io, &watcher, output);

    try scratch.rename("notes.txt", scratch, "renamed.txt", io);
    try report(io, &watcher, output);

    try scratch.createDirPath(io, "sub");
    try report(io, &watcher, output);

    try scratch.writeFile(io, .{ .sub_path = "sub/inside.txt", .data = "deep" });
    try report(io, &watcher, output);

    try scratch.deleteFile(io, "renamed.txt");
    try report(io, &watcher, output);

    // A second watcher, with a filter: the ignore list keeps part of the
    // tree out of the watch entirely. Where lookout does the recursion
    // an ignored directory is never opened and never registered, so it
    // costs nothing; where the kernel recurses it is the events that are
    // dropped, and `prunesIgnored` is how a program asks which it got.
    try scratch.createDirPath(io, "build");
    var filtered: lookout.Watcher = try .init(gpa, io, .{});
    defer filtered.deinit(io);
    _ = try filtered.add(io, dir_path, .{
        .recursive = true,
        .filter = .{ .ignore = &.{ "build", "*.tmp" } },
    });

    try scratch.writeFile(io, .{ .sub_path = "build/artifact.o", .data = "ignored" });
    try scratch.writeFile(io, .{ .sub_path = "draft.tmp", .data = "ignored" });
    try scratch.writeFile(io, .{ .sub_path = "kept.txt", .data = "reported" });
    for (try filtered.poll(io, two_seconds)) |event| {
        try output.print("filtered: {s} {s}\n", .{ @tagName(event.kind), event.path });
    }

    // A watch on a path that is not there yet. It is parked on the
    // nearest existing ancestor, steps down as the path appears, and is
    // promoted to the real watch with the appearance reported against it.
    const later = try std.Io.Dir.path.join(gpa, &.{ dir_path, "later", "inside" });
    defer gpa.free(later);
    var pending: lookout.Watcher = try .init(gpa, io, .{});
    defer pending.deinit(io);
    _ = try pending.add(io, later, .{ .pending = true, .recursive = true });

    try scratch.createDirPath(io, "later/inside");
    for (try pending.poll(io, two_seconds)) |event| {
        try output.print("pending: {s} {s}\n", .{ @tagName(event.kind), event.path });
    }

    // `Kind.overflow` says the watcher's record is incomplete without
    // saying what is missing. A baseline seeded where the watch was taken
    // answers that: its diff is the events that would have arrived.
    var baseline: lookout.Baseline = try .seed(gpa, io, dir_path, .{ .recursive = true });
    defer baseline.deinit();

    try scratch.writeFile(io, .{ .sub_path = "written-while-away.txt", .data = "missed" });
    for (try baseline.diff(io)) |change| {
        try output.print("baseline: {s} {s}\n", .{ @tagName(change.kind), change.path });
    }

    try output.print("backend: {s}\n", .{@tagName(watcher.backend())});
    try output.print("prunes ignored: {}\n", .{lookout.prunesIgnored(watcher.backend())});
    try output.flush();
}

/// Polls once and writes whatever came back to `output`, including where a renamed
/// path came from on the backends that can say.
fn report(io: std.Io, watcher: *lookout.Watcher, output: *std.Io.Writer) !void {
    for (try watcher.poll(io, two_seconds)) |event| {
        if (event.from) |from| {
            try output.print("{s} {s} (from {s})\n", .{ @tagName(event.kind), event.path, from });
        } else {
            try output.print("{s} {s}\n", .{ @tagName(event.kind), event.path });
        }
    }
}
