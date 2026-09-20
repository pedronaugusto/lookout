//! What a tree looked like, and what has changed in it since.
//!
//! `lookout.Kind.overflow` says that the watcher's record of a tree is
//! incomplete and the tree has to be read again. It does not say what was
//! missed, because nothing underneath it knows: the kernel queue
//! overflowed, or a directory went past `lookout.Options.max_dir_entries`,
//! and either way the names are gone.
//!
//! A caller that seeds one of these when it takes the watch can ask
//! afterwards. `diff` re-reads the tree and returns the creations,
//! modifications, attribute changes and removals that happened since the
//! last look -- the events that would have arrived had nothing been lost.
//!
//! It is the same listing comparison the `kqueue` and polling backends
//! make to name the entry that changed, kept for the caller instead of
//! for the watcher. It costs one listing and one `stat` per entry per
//! directory, which is the price of the question.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const lookout = @import("lookout.zig");
const Filter = @import("Filter.zig");
const Snapshot = @import("Snapshot.zig");
const Kind = lookout.Kind;

const Baseline = @This();

/// The `std.Io` every listing goes through, captured at `seed`.
io: Io,
/// Absolute, canonical path of the tree, owned here.
root: []u8,
/// Mirrors `Options.recursive`.
recursive: bool,
/// Mirrors `Options.max_dir_entries`.
max_dir_entries: usize,
/// Mirrors `Options.filter`, copied.
filter: Filter,
/// One remembered listing per directory, keyed by absolute path. Keys
/// owned here.
dirs: std.StringArrayHashMapUnmanaged(Remembered),
/// What the last `diff` found. Every path is owned here and is dropped by
/// the next `diff` or by `deinit`.
changes: std.ArrayList(Change),
/// Scratch the listing comparison writes into, reused between scans so
/// that a steady tree costs no allocation per diff.
scratch: std.ArrayList(Snapshot.Change),

/// One directory's remembered listing.
const Remembered = struct {
    snapshot: Snapshot,
    /// Whether the scan in progress reached it. A directory nothing
    /// reached is one that is no longer there.
    seen: bool,
};

/// What a baseline covers, which should be what the watch covers: a
/// baseline narrower than its watch reports changes the watch would not
/// have, and a wider one misses none but costs more to take.
pub const Options = struct {
    /// Cover every directory below `path` as well.
    recursive: bool = false,
    /// The largest number of entries to track in one directory. A
    /// directory holding more puts a `Kind.overflow` against the root
    /// into the diff, meaning the same thing there as it does in an
    /// event: this part of the answer is incomplete.
    max_dir_entries: usize = 4096,
    /// What to leave out, on the same terms as `lookout.AddOptions.filter`.
    /// The patterns are copied by `seed`.
    filter: Filter = .none,
};

/// One difference between the remembered tree and the tree now, spelled
/// the way an event is.
pub const Change = struct {
    /// Absolute path, owned by the baseline until the next `diff`.
    path: []const u8,
    /// `created`, `modified`, `attributes` or `removed` for a path, and
    /// `overflow` against the root when a directory was too large to
    /// compare. Never `renamed`: a comparison of listings cannot tell a
    /// rename from a removal and a creation, which is the same thing
    /// `lookout.pairsRenames` says about the backends that work this
    /// way. Never `closed` either: a listing is not told about a writer
    /// finishing.
    kind: Kind,
};

/// Errors seeding or diffing can return, on top of the file-system errors
/// of reading the tree.
pub const Error = Allocator.Error || Io.Dir.OpenError ||
    Io.Dir.RealPathFileAllocError || Snapshot.RefreshError;

/// Remembers what is in `path` now, so that a later `diff` can say what
/// has changed since.
///
/// `path` must be a directory and must exist; a file has no listing to
/// compare and `error.NotDir` says so. Call this where the watch is
/// taken, so that the two cover the same tree from the same moment.
pub fn seed(gpa: Allocator, io: Io, path: []const u8, options: Options) Error!Baseline {
    const real = try Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    defer gpa.free(real);

    // Everything is owned by `b` from here, so there is one thing to
    // undo on failure rather than three that would undo each other.
    var b: Baseline = .{
        .io = io,
        .root = try gpa.dupe(u8, real),
        .recursive = options.recursive,
        .max_dir_entries = options.max_dir_entries,
        .filter = .none,
        .dirs = .empty,
        .changes = .empty,
        .scratch = .empty,
    };
    errdefer b.deinit(gpa);
    b.filter = try options.filter.dupe(gpa);
    try b.scan(gpa, false);
    return b;
}

/// Releases the remembered listings and the last diff.
pub fn deinit(b: *Baseline, gpa: Allocator) void {
    b.forgetAll(gpa);
    b.dirs.deinit(gpa);
    b.clearChanges(gpa);
    b.changes.deinit(gpa);
    Snapshot.freeChanges(gpa, &b.scratch);
    b.scratch.deinit(gpa);
    b.filter.deinit(gpa);
    gpa.free(b.root);
    b.* = undefined;
}

/// Re-reads the tree and returns what has changed since the last look,
/// which the baseline then becomes.
///
/// The returned slice and every path in it belong to the baseline and are
/// invalidated by the next `diff` or by `deinit` -- the same terms as
/// `lookout.Watcher.poll`, so that the two can be handled by one piece of
/// code. Calling it twice in a row returns nothing the second time.
pub fn diff(b: *Baseline, gpa: Allocator) Error![]const Change {
    b.clearChanges(gpa);
    try b.scan(gpa, true);
    return b.changes.items;
}

/// Walks the tree, refreshing every directory's listing. With `report`
/// set, every difference found becomes a `Change`; without it the walk is
/// only there to take the listings, which is what `seed` wants.
fn scan(b: *Baseline, gpa: Allocator, report: bool) Error!void {
    for (b.dirs.values()) |*remembered| remembered.seen = false;

    var frontier: std.ArrayList([]u8) = .empty;
    defer {
        for (frontier.items) |path| gpa.free(path);
        frontier.deinit(gpa);
    }
    try frontier.append(gpa, try gpa.dupe(u8, b.root));

    var i: usize = 0;
    while (i < frontier.items.len) : (i += 1) {
        const path = frontier.items[i];
        var dir = Io.Dir.openDirAbsolute(b.io, path, .{ .iterate = true }) catch |err| {
            // A subdirectory that has gone is reported by its parent's
            // own comparison, so there is nothing to say here. The root
            // has no parent to report it.
            if (i != 0) continue;
            if (!report) return err;
            try b.record(gpa, b.root, .removed);
            b.forgetAll(gpa);
            return;
        };
        defer dir.close(b.io);

        const index = try b.remember(gpa, path);
        Snapshot.freeChanges(gpa, &b.scratch);
        try b.dirs.values()[index].snapshot.refresh(
            gpa,
            b.io,
            dir,
            b.max_dir_entries,
            &b.scratch,
        );

        if (report) try b.reportChanges(gpa, path, index);
        if (!b.recursive) continue;

        // The listing just taken is the list of subdirectories to walk,
        // so descending costs no syscall of its own.
        const snapshot = &b.dirs.values()[index].snapshot;
        for (snapshot.entries.keys(), snapshot.entries.values()) |name, meta| {
            if (meta.file_kind != .directory) continue;
            const child = try std.fs.path.join(gpa, &.{ path, name });
            errdefer gpa.free(child);
            if (b.filter.prunes(b.root, child)) {
                gpa.free(child);
                continue;
            }
            try frontier.append(gpa, child);
        }
    }

    try b.reportLost(gpa, report);
}

/// Turns one directory's comparison into changes.
fn reportChanges(b: *Baseline, gpa: Allocator, path: []const u8, index: usize) Error!void {
    if (b.dirs.values()[index].snapshot.truncated) {
        try b.record(gpa, b.root, .overflow);
    }
    for (b.scratch.items) |change| {
        // A directory's own times move whenever anything inside it
        // moves, and reporting that would put an entry in the diff for
        // every ancestor of every change. It is left out here for the
        // same reason the backends leave it out of their events.
        if (change.file_kind == .directory and
            (change.kind == .modified or change.kind == .attributes)) continue;

        const child = try std.fs.path.join(gpa, &.{ path, change.name });
        defer gpa.free(child);
        if (b.filter.excludes(b.root, child)) continue;
        try b.record(gpa, child, change.kind);
    }
}

/// Drops the directories the scan did not reach, reporting what was in
/// them as removed.
///
/// The directory itself is reported by its parent's comparison; what was
/// inside it is only remembered here, and a caller rebuilding from a diff
/// wants the files by name.
fn reportLost(b: *Baseline, gpa: Allocator, report: bool) Error!void {
    var i: usize = 0;
    while (i < b.dirs.count()) {
        if (b.dirs.values()[i].seen) {
            i += 1;
            continue;
        }
        const path = b.dirs.keys()[i];
        if (report) {
            const snapshot = b.dirs.values()[i].snapshot;
            for (snapshot.entries.keys()) |name| {
                const child = try std.fs.path.join(gpa, &.{ path, name });
                defer gpa.free(child);
                if (b.filter.excludes(b.root, child)) continue;
                try b.record(gpa, child, .removed);
            }
        }
        gpa.free(path);
        b.dirs.values()[i].snapshot.deinit(gpa);
        b.dirs.swapRemoveAt(i);
    }
}

/// The index of `path`'s remembered listing, creating an empty one the
/// first time. Marks it as reached by the scan in progress.
fn remember(b: *Baseline, gpa: Allocator, path: []const u8) Allocator.Error!usize {
    if (b.dirs.getIndex(path)) |index| {
        b.dirs.values()[index].seen = true;
        return index;
    }
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    try b.dirs.put(gpa, owned, .{ .snapshot = .empty, .seen = true });
    return b.dirs.getIndex(path).?;
}

fn record(b: *Baseline, gpa: Allocator, path: []const u8, kind: Kind) Allocator.Error!void {
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    try b.changes.append(gpa, .{ .path = owned, .kind = kind });
}

fn clearChanges(b: *Baseline, gpa: Allocator) void {
    for (b.changes.items) |change| gpa.free(change.path);
    b.changes.clearRetainingCapacity();
}

fn forgetAll(b: *Baseline, gpa: Allocator) void {
    for (b.dirs.keys(), b.dirs.values()) |path, *remembered| {
        gpa.free(path);
        remembered.snapshot.deinit(gpa);
    }
    b.dirs.clearRetainingCapacity();
}

const testing = std.testing;

/// How many changes of `kind` the diff holds, and the path of the first.
fn count(changes: []const Change, kind: Kind) usize {
    var found: usize = 0;
    for (changes) |change| {
        if (change.kind == kind) found += 1;
    }
    return found;
}

fn holds(changes: []const Change, root: []const u8, sub_path: []const u8, kind: Kind) !bool {
    const gpa = testing.allocator;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    try parts.append(gpa, root);
    var it = std.mem.splitScalar(u8, sub_path, '/');
    while (it.next()) |part| try parts.append(gpa, part);
    const wanted = try std.fs.path.join(gpa, parts.items);
    defer gpa.free(wanted);

    for (changes) |change| {
        if (change.kind == kind and std.mem.eql(u8, change.path, wanted)) return true;
    }
    return false;
}

test "a seeded baseline has nothing to report until something changes" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{});
    defer base.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), (try base.diff(gpa)).len);
}

test "a diff names what was created, changed and removed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{});
    defer base.deinit(gpa);

    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "one and two" });
    try tmp.dir.deleteFile(io, "old.txt");

    const changes = try base.diff(gpa);
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expect(try holds(changes, root, "new.txt", .created));
    try testing.expect(try holds(changes, root, "kept.txt", .modified));
    try testing.expect(try holds(changes, root, "old.txt", .removed));

    // The baseline is now what it found, so the same diff twice says
    // nothing the second time.
    try testing.expectEqual(@as(usize, 0), (try base.diff(gpa)).len);
}

test "a recursive baseline follows subdirectories" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit(gpa);

    try tmp.dir.createDirPath(io, "sub/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deeper/a.txt", .data = "one" });

    const changes = try base.diff(gpa);
    try testing.expect(try holds(changes, root, "sub/deeper", .created));
    try testing.expect(try holds(changes, root, "sub/deeper/a.txt", .created));

    // A non-recursive one covers the root and nothing below it.
    var shallow = try Baseline.seed(gpa, io, root, .{});
    defer shallow.deinit(gpa);
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deeper/b.txt", .data = "two" });
    try testing.expectEqual(@as(usize, 0), (try shallow.diff(gpa)).len);
}

test "a removed directory takes everything it held with it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/a.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/deep/b.txt", .data = "two" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit(gpa);

    try tmp.dir.deleteTree(io, "tree");

    // Every path that is gone, not only the directory the caller could
    // have worked out for itself.
    const changes = try base.diff(gpa);
    try testing.expect(try holds(changes, root, "tree", .removed));
    try testing.expect(try holds(changes, root, "tree/a.txt", .removed));
    try testing.expect(try holds(changes, root, "tree/deep", .removed));
    try testing.expect(try holds(changes, root, "tree/deep/b.txt", .removed));
}

test "a filter keeps a subtree out of the diff" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skip");
    try tmp.dir.createDirPath(io, "keep");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{
        .recursive = true,
        .filter = .{ .ignore = &.{ "skip", "*.tmp" } },
    });
    defer base.deinit(gpa);

    try tmp.dir.writeFile(io, .{ .sub_path = "skip/a.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep/b.tmp", .data = "two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep/b.txt", .data = "three" });

    const changes = try base.diff(gpa);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expect(try holds(changes, root, "keep/b.txt", .created));
}

test "an only filter traverses ancestors of matching descendants" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/deep");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{
        .recursive = true,
        .filter = .{ .only = &.{"src/**/*.zig"} },
    });
    defer base.deinit(gpa);

    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/main.zig", .data = "const x = 1;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/deep/notes.txt", .data = "ignored" });

    const changes = try base.diff(gpa);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expect(try holds(changes, root, "src/deep/main.zig", .created));
}

test "a directory past the entry limit says the diff is incomplete" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{ .max_dir_entries = 2 });
    defer base.deinit(gpa);

    for (0..6) |i| {
        var name: [8]u8 = undefined;
        try tmp.dir.writeFile(io, .{
            .sub_path = std.fmt.bufPrint(&name, "f{d}", .{i}) catch unreachable,
            .data = "x",
        });
    }

    // The same word the watcher uses, meaning the same thing: this answer
    // is not the whole answer.
    const changes = try base.diff(gpa);
    try testing.expect(count(changes, .overflow) >= 1);
    try testing.expectEqualStrings(root, changes[0].path);
}

test "a baseline whose root is gone says so" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "target/a.txt", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, "target", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{});
    defer base.deinit(gpa);

    try tmp.dir.deleteTree(io, "target");
    const changes = try base.diff(gpa);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings(root, changes[0].path);
    try testing.expectEqual(Kind.removed, changes[0].kind);
}

test "seeding a file rather than a directory is refused" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const path = try tmp.dir.realPathFileAlloc(io, "a.txt", gpa);
    defer gpa.free(path);

    try testing.expectError(error.NotDir, Baseline.seed(gpa, io, path, .{}));
}
