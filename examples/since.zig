//! Stop watching, let the tree change, and be told what was missed.
//!
//! A tool that runs, exits and runs again has a gap it cannot see into.
//! `Watcher.checkpoint` closes it where the operating system keeps a log
//! of what changed: the checkpoint is an owned snapshot the program
//! writes down, and `Options.checkpoint` takes it back.
//!
//! `zig build examples` builds AND runs this. On a target whose backend
//! cannot answer -- `tracksCheckpoint` says which -- it prints that and
//! stops, because a program that pretends to resume is worse than one
//! that says it cannot.

const std = @import("std");
const lookout = @import("lookout");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var display_buffer: [4096]u8 = undefined;
    var display = std.Io.File.stdout().writer(io, &display_buffer);
    const output = &display.interface;

    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(io, "lookout-since");
    defer cwd.deleteTree(io, "lookout-since") catch {};
    var scratch = try cwd.createDirPathOpen(io, "lookout-since", .{});
    defer scratch.close(io);
    const dir_path = try scratch.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);

    if (!lookout.tracksCheckpoint(lookout.default_backend)) {
        try output.print(
            "{s} keeps no log to resume from, so there is no checkpoint to take\n",
            .{@tagName(lookout.default_backend)},
        );
        try output.flush();
        return;
    }

    // The first run. It watches, does its work, and writes down where
    // it got to before it stops.
    var token: []u8 = undefined;
    defer gpa.free(token);
    {
        var watcher: lookout.Watcher = try .init(gpa, io, .{});
        defer watcher.deinit();
        _ = try watcher.add(dir_path, .{ .recursive = true });
        try scratch.writeFile(io, .{ .sub_path = "seen.txt", .data = "while watching" });
        for (try watcher.poll(2_000)) |event| {
            try output.print("first run: {s} {s}\n", .{ @tagName(event.kind), event.path });
        }

        var checkpoint = (try watcher.checkpoint(gpa)).?;
        defer checkpoint.deinit();
        token = try checkpoint.token(gpa);
        try output.print("checkpoint: {s}\n", .{token});
    }

    // Nothing is watching now, which is when the interesting changes
    // happen to a tool that is not running.
    try scratch.writeFile(io, .{ .sub_path = "missed.txt", .data = "while away" });
    try scratch.deleteFile(io, "seen.txt");

    // The second run hands the token back.
    var resumed = try lookout.Checkpoint.parse(gpa, token);
    defer resumed.deinit();
    var watcher: lookout.Watcher = try .init(gpa, io, .{ .checkpoint = resumed });
    defer watcher.deinit();
    _ = try watcher.add(dir_path, .{ .recursive = true });

    // A replayed change is reported against the tree as it is now, so
    // what matters is the path, not which of the kinds it arrives as.
    for (try watcher.poll(2_000)) |event| {
        try output.print("since: {s} {s}\n", .{ @tagName(event.kind), event.path });
    }
    try output.flush();
}
