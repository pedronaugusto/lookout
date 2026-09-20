//! How many entries each watched directory holds, against
//! `lookout.Options.max_dir_entries`.
//!
//! The backends that compare directory listings know when a directory is
//! past the budget because the listing itself is truncated -- see
//! `Snapshot.truncated`. The backends the kernel names entries for do
//! not list anything, so for them the count is kept here: seeded once by
//! reading the directory, and moved by the creations and removals the
//! kernel reports.
//!
//! It exists so that the signal a caller handles is the same one on
//! every platform. It is counted per directory and not per watch: a
//! recursive watch over twenty directories of three hundred entries is
//! twenty directories inside a budget of a thousand, not one of six
//! thousand past it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const path = @import("path.zig");

const Budget = @This();

gpa: Allocator,
io: Io,
/// Mirrors `lookout.Options.max_dir_entries`.
max: usize,
/// One count per directory the backend has been told about. Keys owned
/// here, compared as the file system compares them.
counts: path.Set(usize),

/// What happened to a directory's entry count.
pub const Move = enum { appeared, vanished, unchanged };

pub fn init(gpa: Allocator, io: Io, max: usize) Budget {
    return .{ .gpa = gpa, .io = io, .max = max, .counts = .empty };
}

pub fn deinit(b: *Budget) void {
    for (b.counts.keys()) |key| b.gpa.free(key);
    b.counts.deinit(b.gpa);
    b.* = undefined;
}

/// Counts what `dir` holds now, so that a directory that is already too
/// big says so at the first sign of life rather than after the budget's
/// worth of changes.
pub fn seed(b: *Budget, dir: []const u8) Allocator.Error!void {
    if (b.counts.contains(dir)) return;
    const owned = try b.gpa.dupe(u8, dir);
    errdefer b.gpa.free(owned);
    try b.counts.put(b.gpa, owned, entriesIn(b.io, dir));
}

/// Starts accounting for a directory a tree walk is about to list.
/// `found` adds the entries from that same walk, avoiding a second
/// listing solely to establish the budget.
pub fn begin(b: *Budget, dir: []const u8) Allocator.Error!void {
    if (b.counts.contains(dir)) return;
    const owned = try b.gpa.dupe(u8, dir);
    errdefer b.gpa.free(owned);
    try b.counts.put(b.gpa, owned, 0);
}

/// Accounts for one entry an existing tree walk found in `dir`.
pub fn found(b: *Budget, dir: []const u8) void {
    const count = b.counts.getPtr(dir) orelse return;
    count.* += 1;
}

/// Records one change in `dir` and answers whether it is now past the
/// budget. A directory nothing has been said about yet is counted first.
pub fn note(b: *Budget, dir: []const u8, move: Move) Allocator.Error!bool {
    const gop = try b.counts.getOrPut(b.gpa, dir);
    if (!gop.found_existing) {
        const owned = b.gpa.dupe(u8, dir) catch |err| {
            _ = b.counts.swapRemove(dir);
            return err;
        };
        gop.key_ptr.* = owned;
        gop.value_ptr.* = entriesIn(b.io, dir);
    } else switch (move) {
        .appeared => gop.value_ptr.* += 1,
        .vanished => gop.value_ptr.* -|= 1,
        .unchanged => {},
    }
    return gop.value_ptr.* > b.max;
}

/// Drops `dir` and every directory under it, for a subtree that has gone.
pub fn forget(b: *Budget, dir: []const u8) void {
    var i: usize = 0;
    while (i < b.counts.count()) {
        if (path.within(dir, b.counts.keys()[i])) {
            b.gpa.free(b.counts.keys()[i]);
            b.counts.swapRemoveAt(i);
        } else {
            i += 1;
        }
    }
}

/// How many entries `path` holds, or zero when it is not a directory or
/// cannot be read. An unreadable directory is a budget of nothing rather
/// than a failed `add`.
pub fn entriesIn(io: Io, dir_path: []const u8) usize {
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(io) catch null) |_| count += 1;
    return count;
}

const testing = std.testing;

test "a directory is counted once and then kept current" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "x" });

    var b: Budget = .init(gpa, io, 3);
    defer b.deinit();

    try b.seed(root);
    try testing.expectEqual(@as(usize, 2), b.counts.get(root).?);
    try testing.expect(!try b.note(root, .appeared));
    try testing.expect(try b.note(root, .appeared));
    try testing.expect(!try b.note(root, .vanished));
}

test "each directory has its own budget" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "one");
    try tmp.dir.createDirPath(io, "two");

    const one = try std.fs.path.join(gpa, &.{ root, "one" });
    defer gpa.free(one);
    const two = try std.fs.path.join(gpa, &.{ root, "two" });
    defer gpa.free(two);

    var b: Budget = .init(gpa, io, 2);
    defer b.deinit();

    // The first mention of a directory counts what is in it, because the
    // change being reported is already on disk by then.
    try b.seed(one);
    try b.seed(two);
    try testing.expect(!try b.note(one, .appeared));
    try testing.expect(!try b.note(one, .appeared));
    try testing.expect(try b.note(one, .appeared));
    // The other directory has spent nothing of its own.
    try testing.expect(!try b.note(two, .appeared));

    b.forget(root);
    try testing.expectEqual(@as(usize, 0), b.counts.count());
}

test "an existing walk seeds a directory without listing it again" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var b: Budget = .init(gpa, io, 2);
    defer b.deinit();

    try b.begin(root);
    b.found(root);
    b.found(root);
    try testing.expectEqual(@as(usize, 2), b.counts.get(root).?);
    try testing.expect(try b.note(root, .appeared));
}
