//! Walking a tree that somebody else made.
//!
//! Three places need the same walk: the Apple backend seeding what it
//! knows is there, and the Linux backend both registering a tree at
//! `add` and adopting one that has just appeared. Each wrote out the
//! same loop, and each had to get the same two things right -- a
//! frontier rather than recursion, because the depth of a tree an
//! unrelated process created is not this library's to bound, and a
//! directory that vanishes or is not ours to read being skipped rather
//! than failing the walk.
//!
//! The backends that compare directory listings do not use this. They
//! already hold a listing of every directory and descend through it, so
//! walking with a second listing would cost a pass over the tree that
//! their own snapshots have already paid for.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One entry the walk found.
pub const Entry = struct {
    /// The directory being listed, absolute.
    dir: []const u8,
    /// The entry's name inside it.
    name: []const u8,
    /// What the entry is, as the listing reports it.
    kind: Io.File.Kind,
    /// The entry's absolute path. Owned by the walk and valid only for
    /// the duration of the call; copy anything kept.
    path: []const u8,
};

/// What to do with an entry the walk found.
pub const Step = enum {
    /// Leave it alone. A directory answered with this is not descended
    /// into, and nothing below it is visited.
    over,
    /// Descend into it, when it is a directory.
    into,
};

/// Lists `root` and everything the visitor steps into, breadth first.
///
/// `visit` is called once per entry and says whether to go in. The root
/// itself is not visited: the caller already has it, and what it wants
/// done with it differs at all three call sites.
///
/// A directory that cannot be opened is skipped rather than failing the
/// walk: it has gone again, or it is not ours to read, and either way
/// its parent has already reported what it could.
pub fn tree(
    gpa: Allocator,
    io: Io,
    root: []const u8,
    context: anytype,
    comptime visit: fn (@TypeOf(context), Entry) anyerror!Step,
) !void {
    var frontier: std.ArrayList([]u8) = .empty;
    defer {
        for (frontier.items) |item| gpa.free(item);
        frontier.deinit(gpa);
    }
    try frontier.append(gpa, try gpa.dupe(u8, root));

    var i: usize = 0;
    while (i < frontier.items.len) : (i += 1) {
        const current = frontier.items[i];
        var dir = Io.Dir.openDirAbsolute(io, current, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            const child = try std.fs.path.join(gpa, &.{ current, entry.name });
            var kept = false;
            defer if (!kept) gpa.free(child);

            const step = try visit(context, .{
                .dir = current,
                .name = entry.name,
                .kind = entry.kind,
                .path = child,
            });
            if (step == .into and entry.kind == .directory) {
                try frontier.append(gpa, child);
                kept = true;
            }
        }
    }
}

const testing = std.testing;

test "a walk visits every entry it is let into, and nothing below one it is not" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "keep/deeper");
    try tmp.dir.createDirPath(io, "skip/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "keep/deeper/a.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skip/deeper/b.txt", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const Seen = struct {
        gpa: Allocator,
        names: std.ArrayList([]u8),

        fn visit(s: *@This(), entry: Entry) anyerror!Step {
            try s.names.append(s.gpa, try s.gpa.dupe(u8, entry.name));
            if (std.mem.eql(u8, entry.name, "skip")) return .over;
            return .into;
        }
        fn holds(s: *const @This(), name: []const u8) bool {
            for (s.names.items) |seen| {
                if (std.mem.eql(u8, seen, name)) return true;
            }
            return false;
        }
    };
    var seen: Seen = .{ .gpa = gpa, .names = .empty };
    defer {
        for (seen.names.items) |name| gpa.free(name);
        seen.names.deinit(gpa);
    }

    try tree(gpa, io, root, &seen, Seen.visit);
    try testing.expect(seen.holds("keep"));
    try testing.expect(seen.holds("deeper"));
    try testing.expect(seen.holds("a.txt"));
    try testing.expect(seen.holds("skip"));
    // `skip` was visited and refused, so nothing inside it was.
    try testing.expect(!seen.holds("b.txt"));
}

test "a walk of an empty or unreadable tree visits nothing and does not fail" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const Count = struct {
        seen: usize = 0,
        fn visit(c: *@This(), _: Entry) anyerror!Step {
            c.seen += 1;
            return .into;
        }
    };
    var count: Count = .{};
    try tree(gpa, io, root, &count, Count.visit);
    try testing.expectEqual(@as(usize, 0), count.seen);

    const absent = try std.fs.path.join(gpa, &.{ root, "not-there" });
    defer gpa.free(absent);
    try tree(gpa, io, absent, &count, Count.visit);
    try testing.expectEqual(@as(usize, 0), count.seen);
}
