//! How many entries each watched directory holds, against
//! `lookout.Watcher.Options.max_dir_entries`.
//!
//! The backends that compare directory listings know when a directory is
//! past the budget because the listing itself is truncated -- see
//! `Snapshot.truncated`. The backends the kernel names entries for do
//! not list anything, so for them the count is kept here: seeded once by
//! reading the directory, moved by the creations and removals the kernel
//! reports, and read again when the system says it lost some of them.
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
/// Mirrors `lookout.Watcher.Options.max_dir_entries`.
max: usize,
/// The entries of each directory the backend has been told about, by
/// name: a set, so that a creation reported twice, or a removal of a
/// name never counted, moves nothing. Keys and names owned here, compared
/// as the file system compares them.
counts: path.Set(Remembered),
/// The directories the walk under way started counting, and so the only
/// ones whose entries it adds. Keys borrowed from `counts`. See `begin`.
walking: path.Set(void),

/// One directory's entries, by name.
pub const Names = path.Set(void);

const Remembered = struct {
    names: Names = .empty,
    complete: bool = true,
};

/// What happened to a directory's entry count.
pub const Move = enum { appeared, vanished, unchanged };

pub fn init(gpa: Allocator, max: usize) Budget {
    return .{ .gpa = gpa, .max = max, .counts = .empty, .walking = .empty };
}

pub fn deinit(b: *Budget) void {
    for (b.counts.keys(), b.counts.values()) |key, *remembered| {
        freeNames(b.gpa, &remembered.names);
        b.gpa.free(key);
    }
    b.counts.deinit(b.gpa);
    b.walking.deinit(b.gpa);
    b.* = undefined;
}

/// How many entries `dir` is counted as holding, when it is counted.
pub fn count(b: *const Budget, dir: []const u8) ?usize {
    const names = b.counts.getPtr(dir) orelse return null;
    return names.names.count();
}

/// Counts what `dir` holds now, so that a directory that is already too
/// big says so at the first sign of life rather than after the budget's
/// worth of changes.
///
/// A directory already counted is read again and its count replaced, as
/// `begin` counts it again from a walk: what another watch left may be
/// only what it heard. A failed read retains the old names as uncertain.
pub fn seed(b: *Budget, io: Io, dir: []const u8) Allocator.Error!void {
    var names = namesIn(b.gpa, io, dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Incomplete => {
            if (b.counts.getPtr(dir)) |remembered| {
                remembered.complete = false;
                return;
            }
            const owned = try b.gpa.dupe(u8, dir);
            errdefer b.gpa.free(owned);
            try b.counts.put(b.gpa, owned, .{ .complete = false });
            return;
        },
    };
    errdefer freeNames(b.gpa, &names);
    if (b.counts.getPtr(dir)) |remembered| {
        freeNames(b.gpa, &remembered.names);
        remembered.* = .{ .names = names };
        return;
    }
    const owned = try b.gpa.dupe(u8, dir);
    errdefer b.gpa.free(owned);
    try b.counts.put(b.gpa, owned, .{ .names = names });
}

/// Starts accounting for a directory a tree walk is about to list.
/// `found` adds the entries from that same walk, avoiding a second
/// listing solely to establish the budget, and `end` closes the walk.
///
/// A directory already counted is counted again from what the walk finds:
/// the count is a set of names, so a second watch walking a folder another
/// holds counts each entry once, and the walk is the truth of what is
/// there. A watch parked on a folder for one name in it lets every other
/// change there go by, and the count it left is only what it heard.
pub fn begin(b: *Budget, dir: []const u8) Allocator.Error!void {
    try b.walking.ensureUnusedCapacity(b.gpa, 1);
    if (b.counts.getEntry(dir)) |counted| {
        for (counted.value_ptr.names.keys()) |name| b.gpa.free(name);
        counted.value_ptr.names.clearRetainingCapacity();
        counted.value_ptr.complete = true;
        b.walking.putAssumeCapacity(counted.key_ptr.*, {});
        return;
    }
    const owned = try b.gpa.dupe(u8, dir);
    errdefer b.gpa.free(owned);
    try b.counts.put(b.gpa, owned, .{});
    b.walking.putAssumeCapacity(owned, {});
}

/// Accounts for one entry, `name`, an existing tree walk found in `dir`.
pub fn found(b: *Budget, dir: []const u8, name: []const u8) Allocator.Error!void {
    if (!b.walking.contains(dir)) return;
    const names = b.counts.getPtr(dir) orelse return;
    try addName(b.gpa, &names.names, name);
}

/// Closes the walk `begin` opened: what it counted is the count now.
pub fn end(b: *Budget) void {
    b.walking.clearRetainingCapacity();
}

/// Records what happened to the entry `name` of `dir` and answers whether
/// the directory is now past the budget. A directory nothing has been
/// said about yet is counted first, from disk, where the change already
/// is.
///
/// A name that appears is counted once however often it is reported,
/// and one that goes is uncounted only if it was counted: the count is
/// the folder's, whichever watch hears of the change, and whether or not
/// one heard of it before -- a watch parked on a folder for one name in
/// it, which lets every other change there go by, leaves the count as
/// true as any other.
pub fn note(b: *Budget, io: Io, dir: []const u8, name: []const u8, move: Move) Allocator.Error!bool {
    if (b.counts.getPtr(dir)) |remembered| {
        if (!remembered.complete) {
            const fresh = namesIn(b.gpa, io, dir) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Incomplete => return true,
            };
            freeNames(b.gpa, &remembered.names);
            remembered.* = .{ .names = fresh };
            // The scan already includes this change.
            return fresh.count() > b.max;
        }
        const names = &remembered.names;
        switch (move) {
            .appeared => try addName(b.gpa, names, name),
            .vanished => if (names.fetchSwapRemove(name)) |kv| b.gpa.free(kv.key),
            .unchanged => {},
        }
        return names.count() > b.max;
    }

    // Publish only a complete listing. Until the map takes it, this scope
    // owns both the directory key and every entry name.
    var names = namesIn(b.gpa, io, dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Incomplete => return true,
    };
    errdefer freeNames(b.gpa, &names);
    const owned = try b.gpa.dupe(u8, dir);
    errdefer b.gpa.free(owned);
    try b.counts.put(b.gpa, owned, .{ .names = names });
    return names.count() > b.max;
}

/// Drops `dir` and every directory under it, for a subtree that has gone.
pub fn forget(b: *Budget, dir: []const u8) void {
    var i: usize = 0;
    while (i < b.counts.count()) {
        if (path.within(dir, b.counts.keys()[i])) {
            b.dropAt(i);
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
/// their way.
pub fn release(
    b: *Budget,
    comptime Context: type,
    comptime counted: fn (Context, []const u8) bool,
    dir: []const u8,
    context: Context,
) void {
    var i: usize = 0;
    while (i < b.counts.count()) {
        const key = b.counts.keys()[i];
        if (path.within(dir, key) and !counted(context, key)) {
            b.dropAt(i);
        } else {
            i += 1;
        }
    }
}

fn dropAt(b: *Budget, i: usize) void {
    const key = b.counts.keys()[i];
    _ = b.walking.swapRemove(key);
    freeNames(b.gpa, &b.counts.values()[i].names);
    b.gpa.free(key);
    b.counts.swapRemoveAt(i);
}

/// For a test: the count of `dir` as a lost read would leave it, `real`
/// names forgotten and `made_up` names that are not on disk in their
/// place (a NUL is in no real name). A directory not counted is left
/// alone.
pub fn misread(b: *Budget, dir: []const u8, forget_real: bool, made_up: usize) Allocator.Error!void {
    const remembered = b.counts.getPtr(dir) orelse return;
    const names = &remembered.names;
    var i: usize = 0;
    while (i < names.count()) {
        const name = names.keys()[i];
        if (forget_real or std.mem.findScalar(u8, name, 0) != null) {
            b.gpa.free(name);
            names.swapRemoveAt(i);
        } else i += 1;
    }
    const prefix = "\x00made-up ";
    var buf: [32]u8 = undefined;
    comptime std.debug.assert(prefix.len + std.fmt.count("{d}", .{std.math.maxInt(usize)}) <= buf.len);
    for (0..made_up) |k| {
        // unreachable: the assertion above sizes the buffer for the prefix and any usize
        const name = std.mem.print(&buf, prefix ++ "{d}", .{k}) catch unreachable;
        try addName(b.gpa, names, name);
    }
}

/// Reads again from disk the entries of every directory `stale(context,
/// dir)` names, for a read that was lost.
///
/// The entries are kept by the changes a watch is told about, so a read
/// the system lost -- a queue that overflowed, a buffer it could not
/// hold, a stream it lost track of -- leaves them short of, or past, what
/// the directory holds. Reading the directory again is the one way back
/// to what it holds. A change made after the loss and before this read,
/// and read after it, finds its name already there, or already gone, and
/// moves nothing. A failed read keeps the entries it had and marks them
/// uncertain; the next change retries the read and reports overflow
/// until a complete listing establishes the budget again.
pub fn reread(
    b: *Budget,
    comptime Context: type,
    comptime stale: fn (Context, []const u8) bool,
    io: Io,
    context: Context,
) void {
    for (b.counts.keys(), b.counts.values()) |dir, *remembered| {
        if (!stale(context, dir)) continue;
        const fresh = namesIn(b.gpa, io, dir) catch {
            remembered.complete = false;
            continue;
        };
        freeNames(b.gpa, &remembered.names);
        remembered.* = .{ .names = fresh };
    }
}

/// Whether the count of `dir` rests on what `loser` reads, on a backend
/// that hands every watch its own copy of each change: `loser` reaches
/// `dir`, and no watch with a lower id reaches it and keeps every entry
/// in it. That one's copy of each change there is the one `counter`
/// counts, and a read `loser` lost took nothing from it -- reading such
/// a count again would only count a second time the changes that watch
/// has still to read.
///
/// `watches` is a slice of anything with an `id` field, a `reach()`
/// returning `?Reach` (`null` for a watch that reaches no directory),
/// and a `filter` whose `isEmpty()` says it keeps every entry. `loser`
/// is one of them.
pub fn restsOn(watches: anytype, loser: anytype, dir: []const u8) bool {
    const reach = loser.reach() orelse return false;
    if (!reach.covers(dir)) return false;
    for (watches) |other| {
        if (rank(other.id) >= rank(loser.id)) continue;
        const other_reach = other.reach() orelse continue;
        if (other_reach.covers(dir) and other.filter.isEmpty()) return false;
    }
    return true;
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
/// `Item` is anything with an `id` field, an integer or an enum.
/// `reads(context, watch)` answers for one of `watches`.
pub fn counter(
    comptime Item: type,
    comptime Context: type,
    comptime reads: fn (Context, Item) bool,
    watches: []const Item,
    context: Context,
) ?Item {
    var first: ?Item = null;
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
        .@"enum" => @backingInt(id),
        else => id,
    };
}

/// A complete directory listing. A partial read owns no published count.
fn namesIn(gpa: Allocator, io: Io, dir_path: []const u8) (Allocator.Error || error{Incomplete})!Names {
    var names: Names = .empty;
    errdefer freeNames(gpa, &names);
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return error.Incomplete;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return error.Incomplete) |entry| try addName(gpa, &names, entry.name);
    return names;
}

fn addName(gpa: Allocator, names: *Names, name: []const u8) Allocator.Error!void {
    const gop = try names.getOrPut(gpa, name);
    if (gop.found_existing) return;
    gop.key_ptr.* = gpa.dupe(u8, name) catch |err| {
        _ = names.swapRemove(name);
        return err;
    };
}

fn freeNames(gpa: Allocator, names: *Names) void {
    for (names.keys()) |name| gpa.free(name);
    names.deinit(gpa);
}

const testing = std.testing;
const shakedown = @import("shakedown");

test "a failed first budget count leaves no directory for the retry" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "entry", .data = "x" });

    // Exercise the map, directory path, listing and entry-name allocations.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var budget: Budget = .init(failing.allocator(), 8);
        defer budget.deinit();
        if (budget.note(testing.io, root, "entry", .appeared)) |_| {
            try testing.expectEqual(@as(usize, 1), budget.count(root).?);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), budget.counts.count());
            failing.fail_index = std.math.maxInt(usize);
            try testing.expect(!try budget.note(testing.io, root, "entry", .appeared));
            try testing.expectEqual(@as(usize, 1), budget.count(root).?);
        }
    }
}

test "a directory is counted once and then kept current" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "x" });

    var b: Budget = .init(gpa, 3);
    defer b.deinit();

    try b.seed(io, root);
    try testing.expectEqual(@as(usize, 2), b.count(root).?);
    try testing.expect(!try b.note(io, root, "c.txt", .appeared));
    try testing.expect(try b.note(io, root, "d.txt", .appeared));
    try testing.expect(!try b.note(io, root, "d.txt", .vanished));
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

    const one = try std.Io.Dir.path.join(gpa, &.{ root, "one" });
    defer gpa.free(one);
    const two = try std.Io.Dir.path.join(gpa, &.{ root, "two" });
    defer gpa.free(two);

    var b: Budget = .init(gpa, 2);
    defer b.deinit();

    // The first mention of a directory counts what is in it, because the
    // change being reported is already on disk by then.
    try b.seed(io, one);
    try b.seed(io, two);
    try testing.expect(!try b.note(io, one, "a", .appeared));
    try testing.expect(!try b.note(io, one, "b", .appeared));
    try testing.expect(try b.note(io, one, "c", .appeared));
    // The other directory has spent nothing of its own.
    try testing.expect(!try b.note(io, two, "a", .appeared));

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
    const kept = try std.Io.Dir.path.join(gpa, &.{ root, "kept" });
    defer gpa.free(kept);
    const gone = try std.Io.Dir.path.join(gpa, &.{ root, "gone" });
    defer gpa.free(gone);

    var b: Budget = .init(gpa, 8);
    defer b.deinit();
    try b.seed(io, root);
    try b.seed(io, kept);
    try b.seed(io, gone);
    // A count that differs from what is on disk, so that a count read
    // again from disk would show.
    _ = try b.note(io, kept, "counted", .appeared);

    const Left = struct {
        dir: []const u8,
        const Self = @This();

        fn counts(left: Self, counted_dir: []const u8) bool {
            return path.eql(left.dir, counted_dir);
        }
    };
    b.release(Left, Left.counts, root, Left{ .dir = kept });
    try testing.expectEqual(@as(usize, 1), b.counts.count());
    try testing.expectEqual(@as(usize, 1), b.count(kept).?);
}

test "a lost read has its counts read again from disk, and only those" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.createDirPath(io, "lost");
    try tmp.dir.createDirPath(io, "kept");
    const lost = try std.Io.Dir.path.join(gpa, &.{ root, "lost" });
    defer gpa.free(lost);
    const kept = try std.Io.Dir.path.join(gpa, &.{ root, "kept" });
    defer gpa.free(kept);

    var b: Budget = .init(gpa, 2);
    defer b.deinit();
    try b.seed(io, lost);
    try b.seed(io, kept);
    // Three entries each, which neither count was told about.
    for ([_][]const u8{ "lost/a", "lost/b", "lost/c", "kept/a", "kept/b", "kept/c" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }

    const Lost = struct {
        dir: []const u8,
        const Self = @This();

        fn stale(l: Self, dir: []const u8) bool {
            return path.eql(l.dir, dir);
        }
    };
    b.reread(Lost, Lost.stale, io, Lost{ .dir = lost });
    try testing.expectEqual(@as(usize, 3), b.count(lost).?);
    try testing.expectEqual(@as(usize, 0), b.count(kept).?);
    // And the next change is measured against what is there.
    try testing.expect(try b.note(io, lost, "d", .appeared));
}

test "a count rests on the lowest watch that keeps every entry" {
    const Keeps = struct {
        all: bool,
        const Self = @This();

        fn isEmpty(k: Self) bool {
            return k.all;
        }
    };
    const Watch = struct {
        id: u32,
        within: ?Reach,
        filter: Keeps,
        const Self = @This();

        fn reach(w: Self) ?Reach {
            return w.within;
        }
    };
    const file: Watch = .{ .id = 0, .within = null, .filter = .{ .all = true } };
    const filtered: Watch = .{ .id = 1, .within = .{ .dir = "/w", .recursive = true }, .filter = .{ .all = false } };
    const folder: Watch = .{ .id = 2, .within = .{ .dir = "/w/sub", .recursive = false }, .filter = .{ .all = true } };
    const tree: Watch = .{ .id = 3, .within = .{ .dir = "/w", .recursive = true }, .filter = .{ .all = true } };
    const watches = [_]Watch{ tree, folder, file, filtered };

    // A watch on a file reaches no directory, and keeps no count.
    try testing.expect(!restsOn(&watches, file, "/w"));
    // A filtered watch may be the one that counted some entries.
    try testing.expect(restsOn(&watches, filtered, "/w/sub"));
    // Nothing below it keeps every entry of `/w/sub` before it.
    try testing.expect(restsOn(&watches, folder, "/w/sub"));
    // `folder` keeps every entry of `/w/sub` and has the lower id.
    try testing.expect(!restsOn(&watches, tree, "/w/sub"));
    // `/w` is `tree`'s: `filtered`, before it, keeps only some.
    try testing.expect(restsOn(&watches, tree, "/w"));
    // Not a directory it reaches.
    try testing.expect(!restsOn(&watches, folder, "/w"));
}

test "an existing walk seeds a directory without listing it again" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var b: Budget = .init(gpa, 2);
    defer b.deinit();

    try b.begin(root);
    try b.found(root, "a");
    try b.found(root, "b");
    b.end();
    try testing.expectEqual(@as(usize, 2), b.count(root).?);
    try testing.expect(try b.note(io, root, "c", .appeared));
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
    const sub = try std.Io.Dir.path.join(gpa, &.{ root, "sub" });
    defer gpa.free(sub);

    var b: Budget = .init(gpa, 3);
    defer b.deinit();

    try b.begin(root);
    try b.found(root, "a");
    try b.found(root, "sub");
    b.end();

    // The second walk also meets a directory nobody counted yet, and
    // that one it does count.
    try b.begin(root);
    try b.found(root, "a");
    try b.begin(sub);
    try b.found(root, "sub");
    try b.found(sub, "x");
    b.end();

    try testing.expectEqual(@as(usize, 2), b.count(root).?);
    try testing.expectEqual(@as(usize, 1), b.count(sub).?);
    try testing.expect(!try b.note(io, root, "b", .appeared));
    try testing.expect(try b.note(io, root, "c", .appeared));
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
    const folder = try std.Io.Dir.path.join(gpa, &.{ parent, "folder" });
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

        const Self = @This();

        fn reads(copy: Self, watch: *const Watch) bool {
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
        var b: Budget = .init(gpa, 3);
        defer b.deinit();
        try b.seed(io, folder);

        // Three entries: at the budget and not past it, whichever watch
        // reads its copy first. `later` reaches all three watches.
        var passed = false;
        for ([_][]const u8{ "a", "later", "b" }) |name| {
            const copy: Copy = .{ .dir = folder, .name = name };
            for (order) |i| {
                const watch = pointers[i];
                if (!copy.reads(watch)) continue;
                if (counter(*const Watch, Copy, Copy.reads, &pointers, copy) != watch) continue;
                if (try b.note(io, folder, name, .appeared)) passed = true;
            }
        }
        try testing.expect(!passed);
        try testing.expectEqual(@as(usize, 3), b.count(folder).?);

        // The fourth is past it, and is counted once too.
        const copy: Copy = .{ .dir = folder, .name = "c" };
        var counted: usize = 0;
        for (order) |i| {
            const watch = pointers[i];
            if (!copy.reads(watch)) continue;
            if (counter(*const Watch, Copy, Copy.reads, &pointers, copy) != watch) continue;
            counted += 1;
            try testing.expect(try b.note(io, folder, "c", .appeared));
        }
        try testing.expectEqual(@as(usize, 1), counted);
        try testing.expectEqual(@as(usize, 4), b.count(folder).?);
    }
}

test "a change is counted by the lowest id it reached and was kept by" {
    const Watch = struct { id: u32, reach: Reach, keeps: bool };
    const Change = struct {
        dir: []const u8,

        const Self = @This();

        fn reads(change: Self, watch: Watch) bool {
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
    try testing.expectEqual(@as(u32, 1), counter(Watch, Change, Change.reads, &watches, Change{ .dir = "/w" }).?.id);
    try testing.expectEqual(@as(u32, 2), counter(Watch, Change, Change.reads, &watches, Change{ .dir = "/w/sub" }).?.id);
    try testing.expectEqual(@as(u32, 2), counter(Watch, Change, Change.reads, &watches, Change{ .dir = "/w/sub/deep" }).?.id);
    // A folder whose name starts the same way is not below `/w/sub`.
    try testing.expectEqual(@as(u32, 3), counter(Watch, Change, Change.reads, &watches, Change{ .dir = "/w/subway/x" }).?.id);
    try testing.expect(counter(Watch, Change, Change.reads, &watches, Change{ .dir = "/elsewhere" }) == null);
}

test "a name reported twice is one entry, and one never counted goes without taking another with it" {
    // The count a parked watch left behind, or a change heard again after
    // a lost read, is the folder's as it is on disk.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "x" });

    var b: Budget = .init(gpa, 2);
    defer b.deinit();
    try b.seed(io, root);
    try testing.expectEqual(@as(usize, 1), b.count(root).?);
    // `a` was on disk when the folder was counted: its creation, heard
    // late, is already in
    try testing.expect(!try b.note(io, root, "a", .appeared));
    try testing.expectEqual(@as(usize, 1), b.count(root).?);
    // a removal of a name never counted takes nothing
    try testing.expect(!try b.note(io, root, "never", .vanished));
    try testing.expectEqual(@as(usize, 1), b.count(root).?);
    try testing.expect(!try b.note(io, root, "b", .appeared));
    try testing.expect(!try b.note(io, root, "b", .appeared));
    try testing.expect(try b.note(io, root, "c", .appeared));
    try testing.expect(!try b.note(io, root, "c", .vanished));
    try testing.expect(!try b.note(io, root, "c", .vanished));
    try testing.expectEqual(@as(usize, 2), b.count(root).?);
}

test "a failed budget reread keeps its names and reports uncertainty until complete" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "one", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var budget: Budget = .init(gpa, 2);
    defer budget.deinit();
    try budget.seed(io, root);
    try tmp.dir.writeFile(io, .{ .sub_path = "three", .data = "x" });
    const fio = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .dirRead, .n = 1 } },
        .fault = .{ .fail = error.AccessDenied },
        .times = 0,
    }} });
    defer fio.deinit();
    const failing = fio.io();
    budget.reread(void, struct {
        fn stale(_: void, _: []const u8) bool {
            return true;
        }
    }.stale, failing, {});
    try testing.expectEqual(@as(usize, 2), budget.count(root).?);
    try testing.expect(try budget.note(failing, root, "three", .unchanged));
    try testing.expectEqual(@as(usize, 2), budget.count(root).?);
    try testing.expect(try budget.note(io, root, "three", .appeared));
    try testing.expectEqual(@as(usize, 3), budget.count(root).?);
}
