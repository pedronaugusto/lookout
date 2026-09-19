//! Stop watching, let the tree change, and be told what was missed.
//!
//! A tool that runs, exits and runs again has a gap it cannot see into.
//! `Watcher.position` closes it where the operating system keeps a log
//! of what changed: the position is a short piece of text the program
//! writes down, and `Options.since` takes it back.
//!
//! `zig build examples` builds AND runs this. On a target whose backend
//! cannot answer -- `tracksPosition` says which -- it prints that and
//! stops, because a program that pretends to resume is worse than one
//! that says it cannot.

const std = @import("std");
const lookout = @import("lookout");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, "lookout-since") catch {};
    defer cwd.deleteTree(io, "lookout-since") catch {};
    var scratch = try cwd.createDirPathOpen(io, "lookout-since", .{});
    defer scratch.close(io);
    const dir_path = try scratch.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_path);

    if (!lookout.tracksPosition(lookout.default_backend)) {
        std.debug.print(
            "{s} keeps no log to resume from, so there is no position to take\n",
            .{@tagName(lookout.default_backend)},
        );
        return;
    }

    // The first run. It watches, does its work, and writes down where
    // it got to before it stops.
    var token: [lookout.Position.max_token_len]u8 = undefined;
    var written: usize = 0;
    {
        var watcher: lookout.Watcher = try .init(gpa, io, .{});
        defer watcher.deinit();
        _ = try watcher.add(dir_path, .{ .recursive = true });
        try scratch.writeFile(io, .{ .sub_path = "seen.txt", .data = "while watching" });
        for (try watcher.poll(2_000)) |event| {
            std.debug.print("first run: {s} {s}\n", .{ @tagName(event.kind), event.path });
        }

        const where = watcher.position().?;
        written = where.token(&token).len;
        std.debug.print("position: {s}\n", .{token[0..written]});
    }

    // Nothing is watching now, which is when the interesting changes
    // happen to a tool that is not running.
    try scratch.writeFile(io, .{ .sub_path = "missed.txt", .data = "while away" });
    try scratch.deleteFile(io, "seen.txt");

    // The second run hands the token back.
    const resumed = try lookout.Position.parse(token[0..written]);
    var watcher: lookout.Watcher = try .init(gpa, io, .{ .since = resumed });
    defer watcher.deinit();
    _ = try watcher.add(dir_path, .{ .recursive = true });

    // A replayed change is reported against the tree as it is now, so
    // what matters is the path, not which of the kinds it arrives as.
    for (try watcher.poll(2_000)) |event| {
        std.debug.print("since: {s} {s}\n", .{ @tagName(event.kind), event.path });
    }
}
