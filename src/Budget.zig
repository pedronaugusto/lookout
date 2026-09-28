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
/// The directories the walk under way started counting, and so the only
/// ones whose entries it adds. Keys borrowed from `counts`. See `begin`.
walking: path.Set(void),

/// What happened to a directory's entry count.
pub const Move = enum { appeared, vanished, unchanged };

pub fn init(gpa: Allocator, io: Io, max: usize) Budget {
    return .{ .gpa = gpa, .io = io, .max = max, .counts = .empty, .walking = .empty };
}

pub fn deinit(b: *Budget) void {
    for (b.counts.keys()) |key| b.gpa.free(key);
    b.counts.deinit(b.gpa);
    b.walking.deinit(b.gpa);
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
/// listing solely to establish the budget, and `end` closes the walk.
///
/// A directory already counted is left as it is, and so are its entries
/// when the walk finds them: they are counted already. A second watch
/// taken on a folder another one holds walks it again, and adding what
/// that walk found counted every entry once per watch.
pub fn begin(b: *Budget, dir: []const u8) Allocator.Error!void {
    if (b.counts.contains(dir)) return;
    try b.walking.ensureUnusedCapacity(b.gpa, 1);
    const owned = try b.gpa.dupe(u8, dir);
    errdefer b.gpa.free(owned);
    try b.counts.put(b.gpa, owned, 0);
    b.walking.putAssumeCapacity(owned, {});
}

/// Accounts for one entry an existing tree walk found in `dir`.
pub fn found(b: *Budget, dir: []const u8) void {
    if (!b.walking.contains(dir)) return;
    const count = b.counts.getPtr(dir) orelse return;
    count.* += 1;
}

/// Closes the walk `begin` opened: what it counted is the count now.
pub fn end(b: *Budget) void {
    b.walking.clearRetainingCapacity();
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
            _ = b.walking.swapRemove(b.counts.keys()[i]);
            b.gpa.free(b.counts.keys()[i]);
            b.counts.swapRemoveAt(i);
        } else {
            i += 1;
        }
    }
}

/// Drops the counts of `dir` and every directory under it that no watch
/// left counts, for a watch that has been removed. `counted(context,
/// counted_dir)` says whether another watch still counts one.
///
/// A folder another watch still reaches keeps its count. Dropping it,
/// as `forget` does, had the next change there count the folder again
/// from disk -- which by then held entries whose changes were still on
/// their way, and each of those was then counted a second time.
pub fn release(
    b: *Budget,
    dir: []const u8,
    context: anytype,
    comptime counted: fn (@TypeOf(context), []const u8) bool,
) void {
    var i: usize = 0;
    while (i < b.counts.count()) {
        const key = b.counts.keys()[i];
        if (path.within(dir, key) and !counted(context, key)) {
            _ = b.walking.swapRemove(key);
            b.gpa.free(key);
            b.counts.swapRemoveAt(i);
        } else {
            i += 1;
        }
    }
}

/// How far one watch's own reads reach, on a backend that hands every
/// watch its own copy of each change: Windows, where each watch posts its
/// reads on a directory handle of its own, however many other handles
/// are open on the same directory.
pub const Reach = struct {
    /// The directory the reads are posted on.
    dir: []const u8,
    /// Whether they are told about everything below `dir` as well.
    recursive: bool,

    /// Whether a change to an entry of `dir` reaches this watch.
    pub fn covers(r: Reach, dir: []const u8) bool {
        return if (r.recursive) path.within(r.dir, dir) else path.eql(r.dir, dir);
    }
};

/// Of several watches that each read their own copy of one change, the
/// one whose copy is counted.
///
/// Counting every copy counts one entry once per watch that reads it, so
/// a folder two watches share reaches its budget at half its size -- and
/// the budget is the folder's, not the watches'. The copy that counts is
/// the one read by the lowest id of the watches that `reads` says the
/// change reached and kept: a choice each copy can make alone, without
/// knowing whether the others have been read yet, so the change is
/// counted once whatever order the copies are read in.
///
/// `watches` is a slice of anything with an `id` field, an integer or an
/// enum. `reads(context, watch)` answers for one of them.
pub fn counter(
    watches: anytype,
    context: anytype,
    comptime reads: fn (@TypeOf(context), std.meta.Elem(@TypeOf(watches))) bool,
) ?std.meta.Elem(@TypeOf(watches)) {
    var first: ?std.meta.Elem(@TypeOf(watches)) = null;
    for (watches) |watch| {
        if (!reads(context, watch)) continue;
        if (first) |so_far| {
            if (rank(watch.id) >= rank(so_far.id)) continue;
        }
        first = watch;
    }
    return first;
}

fn rank(id: anytype) u64 {
    return switch (@typeInfo(@TypeOf(id))) {
        .@"enum" => @intFromEnum(id),
        else => id,
    };
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

test "a watch removed leaves the counts another watch still holds" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "kept");
    try tmp.dir.createDirPath(io, "gone");
    const kept = try std.fs.path.join(gpa, &.{ root, "kept" });
    defer gpa.free(kept);
    const gone = try std.fs.path.join(gpa, &.{ root, "gone" });
    defer gpa.free(gone);

    var b: Budget = .init(gpa, io, 8);
    defer b.deinit();
    try b.seed(root);
    try b.seed(kept);
    try b.seed(gone);
    // A count that differs from what is on disk, so that a count read
    // again from disk would show.
    _ = try b.note(kept, .appeared);

    const Left = struct {
        dir: []const u8,
        fn counts(left: @This(), counted_dir: []const u8) bool {
            return path.eql(left.dir, counted_dir);
        }
    };
    b.release(root, Left{ .dir = kept }, Left.counts);
    try testing.expectEqual(@as(usize, 1), b.counts.count());
    try testing.expectEqual(@as(usize, 1), b.counts.get(kept).?);
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
    b.end();
    try testing.expectEqual(@as(usize, 2), b.counts.get(root).?);
    try testing.expect(try b.note(root, .appeared));
}

test "a second walk of a directory already counted adds nothing" {
    // Two watches taken on one folder each walk it. The folder has two
    // entries, not four.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const sub = try std.fs.path.join(gpa, &.{ root, "sub" });
    defer gpa.free(sub);

    var b: Budget = .init(gpa, io, 3);
    defer b.deinit();

    try b.begin(root);
    b.found(root);
    b.found(root);
    b.end();

    // The second walk also meets a directory nobody counted yet, and
    // that one it does count.
    try b.begin(root);
    b.found(root);
    try b.begin(sub);
    b.found(root);
    b.found(sub);
    b.end();

    try testing.expectEqual(@as(usize, 2), b.counts.get(root).?);
    try testing.expectEqual(@as(usize, 1), b.counts.get(sub).?);
    try testing.expect(!try b.note(root, .appeared));
    try testing.expect(try b.note(root, .appeared));
}

test "a change every watch reads its own copy of is counted once" {
    // Three watches over one folder, the way Windows sees them: one on
    // the folder's parent, recursive; one on the folder itself; and one
    // parked in the folder waiting for `later`, which keeps nothing
    // else. Each reads its own copy of every change it reaches. Each
    // copy is offered to the budget in turn, in every order, and the
    // folder is to be counted once per entry however they are read.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const parent = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(parent);
    try tmp.dir.createDirPath(io, "folder");
    const folder = try std.fs.path.join(gpa, &.{ parent, "folder" });
    defer gpa.free(folder);

    const Watch = struct {
        id: u32,
        reach: Reach,
        /// The one name this watch keeps, or `null` for every name.
        only: ?[]const u8,
    };
    const Copy = struct {
        dir: []const u8,
        name: []const u8,

        fn reads(copy: @This(), watch: *const Watch) bool {
            if (!watch.reach.covers(copy.dir)) return false;
            const only = watch.only orelse return true;
            return std.mem.eql(u8, only, copy.name);
        }
    };
    const watches = [_]Watch{
        .{ .id = 2, .reach = .{ .dir = folder, .recursive = false }, .only = "later" },
        .{ .id = 0, .reach = .{ .dir = parent, .recursive = true }, .only = null },
        .{ .id = 1, .reach = .{ .dir = folder, .recursive = false }, .only = null },
    };
    var pointers: [watches.len]*const Watch = undefined;
    for (&pointers, &watches) |*p, *watch| p.* = watch;

    const orders = [_][3]usize{ .{ 0, 1, 2 }, .{ 2, 1, 0 }, .{ 1, 2, 0 } };
    for (orders) |order| {
        var b: Budget = .init(gpa, io, 3);
        defer b.deinit();
        try b.seed(folder);

        // Three entries: at the budget and not past it, whichever watch
        // reads its copy first. `later` reaches all three watches.
        var passed = false;
        for ([_][]const u8{ "a", "later", "b" }) |name| {
            const copy: Copy = .{ .dir = folder, .name = name };
            for (order) |i| {
                const watch = pointers[i];
                if (!copy.reads(watch)) continue;
                if (counter(&pointers, copy, Copy.reads) != watch) continue;
                if (try b.note(folder, .appeared)) passed = true;
            }
        }
        try testing.expect(!passed);
        try testing.expectEqual(@as(usize, 3), b.counts.get(folder).?);

        // The fourth is past it, and is counted once too.
        const copy: Copy = .{ .dir = folder, .name = "c" };
        var counted: usize = 0;
        for (order) |i| {
            const watch = pointers[i];
            if (!copy.reads(watch)) continue;
            if (counter(&pointers, copy, Copy.reads) != watch) continue;
            counted += 1;
            try testing.expect(try b.note(folder, .appeared));
        }
        try testing.expectEqual(@as(usize, 1), counted);
        try testing.expectEqual(@as(usize, 4), b.counts.get(folder).?);
    }
}

test "a change is counted by the lowest id it reached and was kept by" {
    const Watch = struct { id: u32, reach: Reach, keeps: bool };
    const Change = struct {
        dir: []const u8,

        fn reads(change: @This(), watch: Watch) bool {
            return watch.reach.covers(change.dir) and watch.keeps;
        }
    };
    const watches = [_]Watch{
        // Reaches everything below `/w`, but keeps none of it.
        .{ .id = 0, .reach = .{ .dir = "/w", .recursive = true }, .keeps = false },
        // Not recursive: only the entries of `/w` itself are its.
        .{ .id = 1, .reach = .{ .dir = "/w", .recursive = false }, .keeps = true },
        .{ .id = 3, .reach = .{ .dir = "/w/subway", .recursive = true }, .keeps = true },
        .{ .id = 2, .reach = .{ .dir = "/w/sub", .recursive = true }, .keeps = true },
    };
    try testing.expectEqual(@as(u32, 1), counter(&watches, Change{ .dir = "/w" }, Change.reads).?.id);
    try testing.expectEqual(@as(u32, 2), counter(&watches, Change{ .dir = "/w/sub" }, Change.reads).?.id);
    try testing.expectEqual(@as(u32, 2), counter(&watches, Change{ .dir = "/w/sub/deep" }, Change.reads).?.id);
    // A folder whose name starts the same way is not below `/w/sub`.
    try testing.expectEqual(@as(u32, 3), counter(&watches, Change{ .dir = "/w/subway/x" }, Change.reads).?.id);
    try testing.expect(counter(&watches, Change{ .dir = "/elsewhere" }, Change.reads) == null);
}
