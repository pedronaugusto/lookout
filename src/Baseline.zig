//! What a tree looked like, and what has changed in it since.
//!
//! `lookout.Kind.overflow` says that the watcher's record of a tree is
//! incomplete and the tree has to be read again. It does not say what was
//! missed, because nothing underneath it knows: the kernel queue
//! overflowed, or a directory went past `@import("options.zig").Options.max_dir_entries`,
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

const lookout = @import("types.zig");
const Filter = @import("Filter.zig");
const Snapshot = @import("Snapshot.zig");
const format = @import("baseline_format.zig");
const Kind = lookout.Kind;
const Target = lookout.Target;

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
/// Scratch the listing comparison writes into, reused between directories.
scratch: std.ArrayList(Snapshot.Change),

/// One directory's remembered listing.
const Remembered = struct {
    snapshot: Snapshot,
};

/// What a baseline covers, which should be what the watch covers: a
/// baseline narrower than its watch misses changes the watch would have
/// reported, and a wider one reports extra paths and costs more to take.
pub const Options = struct {
    /// Cover every directory below `path` as well.
    recursive: bool = false,
    /// The largest number of entries to track in one directory. A
    /// directory holding more puts a `Kind.overflow` against the root
    /// into the diff, meaning the same thing there as it does in an
    /// event: this part of the answer is incomplete.
    max_dir_entries: usize = 4096,
    /// What to leave out, on the same terms as `@import("options.zig").AddOptions.filter`.
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
    /// Whether the path is a file or a directory, as the listing that
    /// noticed the change found it: the one taken now for a path that is
    /// there, the remembered one for a path that has gone — which no `stat`
    /// can ask after it. A name that changed kind is the kind it is now.
    /// The root, removed or overflowing, is a `directory`. Never `unknown`.
    target: Target = .unknown,
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
/// An error leaves the remembered tree unchanged, so retrying reports
/// changes that have not yet been returned.
pub fn diff(b: *Baseline, gpa: Allocator) Error![]const Change {
    try b.scan(gpa, true);
    return b.changes.items;
}

pub const SaveError = Allocator.Error || Io.Dir.CreateFileAtomicError || Io.File.WritePositionalError ||
    Io.File.Atomic.ReplaceError || Io.Dir.OpenError || Io.File.SyncError ||
    error{ UnsupportedBaselineFilter, UnsupportedBaselineDurability };
pub const LoadError = format.ParseError || Io.Dir.ReadFileAllocError || Io.Dir.RealPathFileAllocError ||
    error{UnsupportedBaselineFilter};

/// Atomically replaces the caller-named file with this baseline, without
/// walking again. Keep it outside the watched tree. Predicate filters cannot
/// be serialized and return UnsupportedBaselineFilter. Replacement is atomic;
/// this does not promise power-loss durability (no fsync).
pub fn save(b: *const Baseline, gpa: Allocator, filename: []const u8) SaveError!void {
    return b.saveWithOptions(gpa, filename, .{});
}

pub const SaveOptions = struct {
    /// Sync the temporary file before replacement and its parent directory
    /// afterwards. Windows returns UnsupportedBaselineDurability before writing:
    /// std.Io cannot promise a durable directory replacement there.
    durable: bool = false,
};

/// Saves with optional filesystem durability. A failure of the directory sync
/// happens after replacement, so the new file may already be visible.
pub fn saveWithOptions(b: *const Baseline, gpa: Allocator, filename: []const u8, options: SaveOptions) SaveError!void {
    if (b.filter.allow != null) return error.UnsupportedBaselineFilter;
    if (options.durable and @import("builtin").os.tag == .windows) return error.UnsupportedBaselineDurability;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dirs = try a.alloc(format.Directory, b.dirs.count());
    for (b.dirs.keys(), b.dirs.values(), dirs) |path, remembered, *dir| {
        const entries = try a.alloc(format.Entry, remembered.snapshot.entries.count());
        for (remembered.snapshot.entries.keys(), remembered.snapshot.entries.values(), entries) |name, meta, *entry| entry.* = .{ .name = name, .meta = meta };
        dir.* = .{ .path = path, .truncated = remembered.snapshot.truncated, .check_contents = remembered.snapshot.check_contents, .entries = entries };
    }
    const bytes = try format.encode(a, .{ .platform = format.platform, .root = b.root, .recursive = b.recursive, .max_dir_entries = b.max_dir_entries, .ignore = b.filter.ignore, .only = b.filter.only, .dirs = dirs });
    // An explicit parent handle is needed for fsync even for a relative name;
    // cwd may be the POSIX AT_FDCWD sentinel rather than an open descriptor.
    const parent: ?Io.Dir = if (options.durable)
        try Io.Dir.cwd().openDir(b.io, std.fs.path.dirname(filename) orelse ".", .{})
    else
        null;
    defer if (parent) |dir| dir.close(b.io);
    var file = try (parent orelse Io.Dir.cwd()).createFileAtomic(b.io, if (parent != null) std.fs.path.basename(filename) else filename, .{ .replace = true });
    defer file.deinit(b.io);
    try file.file.writePositionalAll(b.io, bytes, 0);
    if (options.durable) try file.file.sync(b.io);
    try file.replace(b.io);
    if (parent) |dir| {
        const directory: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
        try directory.sync(b.io);
    }
}

/// Loads an owned baseline without walking. The root, scope, budget and
/// pattern filters must match those supplied by the caller. Corrupt, foreign
/// and old-version files return InvalidBaseline, ForeignBaseline and
/// UnsupportedBaselineVersion respectively. A later diff costs one walk.
pub fn load(gpa: Allocator, io: Io, filename: []const u8, root: []const u8, options: Options) LoadError!Baseline {
    if (options.filter.allow != null) return error.UnsupportedBaselineFilter;
    const bytes = Io.Dir.cwd().readFileAlloc(io, filename, gpa, .limited(format.file_limit)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidBaseline,
        else => return err,
    };
    defer gpa.free(bytes);
    var parsed = try format.parse(gpa, bytes);
    defer parsed.deinit();
    const state = parsed.value;
    const real = Io.Dir.cwd().realPathFileAlloc(io, root, gpa) catch |err| switch (err) {
        error.FileNotFound => if (std.fs.path.isAbsolute(root)) try gpa.dupeZ(u8, root) else return err,
        else => return err,
    };
    defer gpa.free(real);
    if (!@import("path.zig").eql(real, state.root) or options.recursive != state.recursive or
        options.max_dir_entries != state.max_dir_entries or !samePatterns(options.filter.ignore, state.ignore) or
        !samePatterns(options.filter.only, state.only)) return error.ForeignBaseline;
    var b: Baseline = .{ .io = io, .root = try gpa.dupe(u8, state.root), .recursive = state.recursive, .max_dir_entries = state.max_dir_entries, .filter = .none, .dirs = .empty, .changes = .empty, .scratch = .empty };
    errdefer b.deinit(gpa);
    b.filter = try options.filter.dupe(gpa);
    for (state.dirs) |dir| {
        const owned = try gpa.dupe(u8, dir.path);
        errdefer gpa.free(owned);
        var snapshot: Snapshot = .{ .entries = .empty, .truncated = dir.truncated, .check_contents = dir.check_contents };
        errdefer snapshot.deinit(gpa);
        for (dir.entries) |entry| {
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);
            try snapshot.entries.put(gpa, name, entry.meta);
        }
        try b.dirs.put(gpa, owned, .{ .snapshot = snapshot });
    }
    return b;
}

fn samePatterns(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

/// Walks the tree, refreshing every directory's listing. With `report`
/// set, every difference found becomes a `Change`; without it the walk is
/// only there to take the listings, which is what `seed` wants.
fn scan(b: *Baseline, gpa: Allocator, report: bool) Error!void {
    // The scan owns new listings and paths until all traversal and reporting
    // have succeeded. The remembered tree stays available for comparison
    // throughout; publishing the result needs no allocation.
    var next: Scan = .{ .baseline = b, .scratch = b.scratch };
    b.scratch = .empty;
    defer {
        b.scratch = next.scratch;
        next.deinit(gpa);
    }
    try next.run(gpa, report);
    std.mem.swap(@TypeOf(b.dirs), &b.dirs, &next.dirs);
    std.mem.swap(@TypeOf(b.changes), &b.changes, &next.changes);
}

/// Owns only the listings and returned paths being prepared. The root and
/// scan options belong to the baseline, which is borrowed until commit.
const Scan = struct {
    baseline: *const Baseline,
    dirs: std.StringArrayHashMapUnmanaged(Remembered) = .empty,
    changes: std.ArrayList(Change) = .empty,
    scratch: std.ArrayList(Snapshot.Change),

    fn deinit(s: *Scan, gpa: Allocator) void {
        for (s.dirs.keys(), s.dirs.values()) |path, *remembered| {
            gpa.free(path);
            remembered.snapshot.deinit(gpa);
        }
        s.dirs.deinit(gpa);
        for (s.changes.items) |change| gpa.free(change.path);
        s.changes.deinit(gpa);
    }

    fn run(s: *Scan, gpa: Allocator, report: bool) Error!void {
        const b = s.baseline;
        var frontier: std.ArrayList([]u8) = .empty;
        defer {
            for (frontier.items) |path| gpa.free(path);
            frontier.deinit(gpa);
        }
        {
            const root = try gpa.dupe(u8, b.root);
            errdefer gpa.free(root);
            try frontier.append(gpa, root);
        }

        var i: usize = 0;
        while (i < frontier.items.len) : (i += 1) {
            const path = frontier.items[i];
            var dir = Io.Dir.openDirAbsolute(b.io, path, .{ .iterate = true }) catch |err| {
                switch (err) {
                    error.FileNotFound, error.NotDir => {},
                    else => return err,
                }
                // A subdirectory that has gone is reported by its parent's
                // own comparison, so there is nothing to say here. The root
                // has no parent to report it.
                if (i != 0) continue;
                if (!report) return err;
                if (b.dirs.count() != 0) try s.record(gpa, b.root, .removed, .directory);
                return;
            };
            defer dir.close(b.io);

            const index = try s.remember(gpa, path);
            Snapshot.freeChanges(gpa, &s.scratch);
            const before = if (b.dirs.getPtr(path)) |remembered| &remembered.snapshot else &Snapshot.empty;
            s.dirs.values()[index].snapshot = try before.read(gpa, b.io, dir, b.max_dir_entries);

            if (report) {
                try s.dirs.values()[index].snapshot.compare(before, gpa, &s.scratch);
                try s.reportChanges(gpa, path, index);
            }
            if (!b.recursive) continue;

            // The listing just taken is the list of subdirectories to walk,
            // so descending costs no syscall of its own.
            const snapshot = &s.dirs.values()[index].snapshot;
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

        if (report) try s.reportLost(gpa);
    }

    /// Turns one directory's comparison into changes.
    fn reportChanges(s: *Scan, gpa: Allocator, path: []const u8, index: usize) Error!void {
        const b = s.baseline;
        if (s.dirs.values()[index].snapshot.truncated) {
            try s.record(gpa, b.root, .overflow, .directory);
        }
        for (s.scratch.items) |change| {
            // A directory's own times move whenever anything inside it
            // moves, and reporting that would put an entry in the diff for
            // every ancestor of every change. It is left out here for the
            // same reason the backends leave it out of their events.
            if (change.file_kind == .directory and
                (change.kind == .modified or change.kind == .attributes)) continue;

            const child = try std.fs.path.join(gpa, &.{ path, change.name });
            defer gpa.free(child);
            if (b.filter.excludes(b.root, child)) continue;
            try s.record(gpa, child, change.kind, .of(change.file_kind));
        }
    }

    /// Reports the contents of directories the scan did not reach. Their
    /// listings still belong to the previous baseline until the scan commits.
    /// The directory itself is reported by its parent's comparison.
    fn reportLost(s: *Scan, gpa: Allocator) Error!void {
        const b = s.baseline;
        for (b.dirs.keys(), b.dirs.values()) |path, remembered| {
            if (s.dirs.contains(path)) continue;
            for (remembered.snapshot.entries.keys(), remembered.snapshot.entries.values()) |name, meta| {
                const child = try std.fs.path.join(gpa, &.{ path, name });
                defer gpa.free(child);
                if (b.filter.excludes(b.root, child)) continue;
                try s.record(gpa, child, .removed, .of(meta.file_kind));
            }
        }
    }

    /// Gives the scan ownership of a directory's new listing.
    fn remember(s: *Scan, gpa: Allocator, path: []const u8) Allocator.Error!usize {
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try s.dirs.put(gpa, owned, .{ .snapshot = .empty });
        return s.dirs.getIndex(path).?;
    }

    fn record(s: *Scan, gpa: Allocator, path: []const u8, kind: Kind, target: Target) Allocator.Error!void {
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try s.changes.append(gpa, .{ .path = owned, .kind = kind, .target = target });
    }
};

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

/// The target the diff gives `sub_path`, which it must hold once.
fn targetOf(changes: []const Change, root: []const u8, sub_path: []const u8) !Target {
    const gpa = testing.allocator;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    try parts.append(gpa, root);
    var it = std.mem.splitScalar(u8, sub_path, '/');
    while (it.next()) |part| try parts.append(gpa, part);
    const wanted = try std.fs.path.join(gpa, parts.items);
    defer gpa.free(wanted);
    var found: ?Target = null;
    for (changes) |change| if (std.mem.eql(u8, change.path, wanted)) {
        try testing.expect(found == null);
        found = change.target;
    };
    return found orelse error.TestExpectedChange;
}

test "a change says whether its path is a file or a directory, gone or not" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/a.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/deep/b.txt", .data = "two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "edited.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "turns.txt", .data = "a file" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit(gpa);

    // Gone: no stat could say what these were, and the diff still does.
    try tmp.dir.deleteTree(io, "tree");
    try tmp.dir.writeFile(io, .{ .sub_path = "edited.txt", .data = "longer now" });
    try tmp.dir.createDirPath(io, "made/inner");
    try tmp.dir.deleteFile(io, "turns.txt");
    try tmp.dir.createDir(io, "turns.txt", .default_dir);

    const changes = try base.diff(gpa);
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "tree"));
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "tree/deep"));
    try testing.expectEqual(Target.file, try targetOf(changes, root, "tree/a.txt"));
    try testing.expectEqual(Target.file, try targetOf(changes, root, "tree/deep/b.txt"));
    try testing.expectEqual(Target.file, try targetOf(changes, root, "edited.txt"));
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "made"));
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "made/inner"));
    // A name that changed kind is what it is now.
    try testing.expectEqual(Target.directory, try targetOf(changes, root, "turns.txt"));
    for (changes) |change| try testing.expect(change.target != .unknown);
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

test "a baseline reports its root removal only once" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "target");
    const root = try tmp.dir.realPathFileAlloc(io, "target", gpa);
    defer gpa.free(root);
    var base = try Baseline.seed(gpa, io, root, .{});
    defer base.deinit(gpa);
    try tmp.dir.deleteTree(io, "target");
    try testing.expectEqual(@as(usize, 1), (try base.diff(gpa)).len);
    try testing.expectEqual(@as(usize, 0), (try base.diff(gpa)).len);
    try tmp.dir.createDirPath(io, "target");
    _ = try base.diff(gpa);
    try tmp.dir.deleteTree(io, "target");
    try testing.expectEqual(@as(usize, 1), (try base.diff(gpa)).len);
    try testing.expectEqual(@as(usize, 0), (try base.diff(gpa)).len);
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

test "directory access failures are not removals" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "blocked/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked/deep/kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    inline for (.{ error.AccessDenied, error.Canceled, error.SystemResources }) |failure| {
        inline for (.{ false, true }) |subtree| {
            var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
            defer base.deinit(gpa);
            const before = base.dirs.count();
            var vtable = io.vtable.*;
            vtable.dirOpenDir = struct {
                fn open(userdata: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
                    if (!subtree or std.mem.eql(u8, std.fs.path.basename(path), "blocked")) return failure;
                    return testing.io.vtable.dirOpenDir(userdata, dir, path, options);
                }
            }.open;
            base.io.vtable = &vtable;
            try testing.expectError(failure, base.diff(gpa));
            try testing.expectEqual(before, base.dirs.count());
            try testing.expectEqual(@as(usize, 0), count(base.changes.items, .removed));
            base.io = io;
            try testing.expectEqual(@as(usize, 0), (try base.diff(gpa)).len);
        }
    }
}

test "a failed baseline traversal leaves changes for the retry" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "blocked");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit(gpa);
    try tmp.dir.writeFile(io, .{ .sub_path = "new", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked/new", .data = "two" });

    var vtable = io.vtable.*;
    vtable.dirOpenDir = struct {
        fn open(userdata: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
            if (std.mem.eql(u8, std.fs.path.basename(path), "blocked")) return error.AccessDenied;
            return testing.io.vtable.dirOpenDir(userdata, dir, path, options);
        }
    }.open;
    base.io.vtable = &vtable;
    try testing.expectError(error.AccessDenied, base.diff(gpa));
    base.io = io;
    const changes = try base.diff(gpa);
    try testing.expect(try holds(changes, root, "new", .created));
    try testing.expect(try holds(changes, root, "blocked/new", .created));
    try testing.expectEqual(@as(usize, 0), (try base.diff(gpa)).len);
}

test "a failed baseline allocation leaves every change for the retry" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        try tmp.dir.writeFile(io, .{ .sub_path = "old", .data = "one" });
        try tmp.dir.writeFile(io, .{ .sub_path = "sub/changed", .data = "one" });
        var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
        defer base.deinit(gpa);
        try tmp.dir.deleteFile(io, "old");
        try tmp.dir.writeFile(io, .{ .sub_path = "new", .data = "one" });
        try tmp.dir.writeFile(io, .{ .sub_path = "sub/changed", .data = "one and two" });
        defer tmp.dir.deleteFile(io, "new") catch unreachable;

        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        if (base.diff(failing.allocator())) |_| {
            try testing.expect(!failing.has_induced_failure);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            const changes = try base.diff(gpa);
            try testing.expect(try holds(changes, root, "old", .removed));
            try testing.expect(try holds(changes, root, "new", .created));
            try testing.expect(try holds(changes, root, "sub/changed", .modified));
            try testing.expectEqual(@as(usize, 0), (try base.diff(gpa)).len);
        }
    }
}

test "a truncated baseline keeps remembered subtrees until a complete scan" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deep/kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var base = try Baseline.seed(gpa, io, root, .{ .recursive = true });
    defer base.deinit(gpa);

    // No entries can be read with this budget. Nothing about a path's
    // existence follows from its absence in that listing.
    base.max_dir_entries = 0;
    const incomplete = try base.diff(gpa);
    try testing.expect(count(incomplete, .overflow) > 0);
    try testing.expectEqual(@as(usize, 0), count(incomplete, .removed));
    try testing.expectEqual(@as(usize, 3), base.dirs.count());
    try tmp.dir.deleteFile(io, "sub/deep/kept");
    base.max_dir_entries = 4096;
    const complete = try base.diff(gpa);
    try testing.expect(try holds(complete, root, "sub/deep/kept", .removed));
    try testing.expectEqual(@as(usize, 0), (try base.diff(gpa)).len);
}

test "a saved baseline reports changes since last run and replaces its file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/sub/gone", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, "tree", gpa);
    defer gpa.free(root);
    const parent = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(parent);
    const file = try std.fs.path.join(gpa, &.{ parent, "baseline" });
    defer gpa.free(file);
    const options: Options = .{ .recursive = true, .filter = .{ .ignore = &.{"*.tmp"} } };
    {
        var base = try seed(gpa, io, root, options);
        defer base.deinit(gpa);
        try base.save(gpa, file);
    }
    try tmp.dir.deleteTree(io, "tree/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/kept", .data = "changed size" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/new", .data = "new" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/ignore.tmp", .data = "new" });
    var loaded = try load(gpa, io, file, root, options);
    defer loaded.deinit(gpa);
    const changes = try loaded.diff(gpa);
    try testing.expectEqual(@as(usize, 4), changes.len);
    try testing.expect(try holds(changes, root, "sub/gone", .removed));
    try testing.expectEqual(Target.file, try targetOf(changes, root, "sub/gone"));
    try testing.expect(try holds(changes, root, "sub", .removed));
    try testing.expect(try holds(changes, root, "kept", .modified));
    try testing.expect(try holds(changes, root, "new", .created));
    try loaded.save(gpa, file);
    var again = try load(gpa, io, file, root, options);
    defer again.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), (try again.diff(gpa)).len);
    try testing.expectError(error.ForeignBaseline, load(gpa, io, file, parent, options));
    try testing.expectError(error.ForeignBaseline, load(gpa, io, file, root, .{}));
    try tmp.dir.deleteTree(io, "tree");
    var missing = try load(gpa, io, file, root, options);
    defer missing.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), (try missing.diff(gpa)).len);
    try testing.expectEqual(@as(usize, 0), (try missing.diff(gpa)).len);
}

test "baseline storage refuses corrupt foreign and old files by name" {
    const gpa = testing.allocator;
    const root = if (@import("builtin").os.tag == .windows) "C:\\tree" else "/tree";
    const state: format.State = .{ .platform = format.platform, .root = root, .recursive = false, .max_dir_entries = 4096, .ignore = &.{}, .only = &.{}, .dirs = &.{} };
    const bytes = try format.encode(gpa, state);
    defer gpa.free(bytes);
    bytes[bytes.len - 1] ^= 1;
    try testing.expectError(error.InvalidBaseline, format.parse(gpa, bytes));
    bytes[bytes.len - 1] ^= 1;
    bytes[8] = 0;
    try testing.expectError(error.UnsupportedBaselineVersion, format.parse(gpa, bytes));
    var foreign = state;
    foreign.platform = "foreign";
    const other = try format.encode(gpa, foreign);
    defer gpa.free(other);
    try testing.expectError(error.ForeignBaseline, format.parse(gpa, other));
}

test "a failed baseline replacement leaves the previous file intact" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree");
    const root = try tmp.dir.realPathFileAlloc(io, "tree", gpa);
    defer gpa.free(root);
    const parent = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(parent);
    const filename = try std.fs.path.join(gpa, &.{ parent, "saved" });
    defer gpa.free(filename);
    var b = try seed(gpa, io, root, .{});
    defer b.deinit(gpa);
    try b.save(gpa, filename);
    const original = try tmp.dir.readFileAlloc(io, "saved", gpa, .unlimited);
    defer gpa.free(original);
    const Broken = struct {
        fn write(context: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
            // Write only a prefix into the temporary file, then fail.
            if (offset != 0) return error.NoSpaceLeft;
            return testing.io.vtable.fileWritePositional(context, file, header, &.{data[0][0..8]}, splat, offset);
        }
    };
    var vtable = io.vtable.*;
    vtable.fileWritePositional = Broken.write;
    b.io = .{ .userdata = io.userdata, .vtable = &vtable };
    try testing.expectError(error.NoSpaceLeft, b.save(gpa, filename));
    b.io = io;
    const after = try tmp.dir.readFileAlloc(io, "saved", gpa, .unlimited);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, original, after);
    var it = tmp.dir.iterate();
    var entries: usize = 0;
    while (try it.next(io)) |_| entries += 1;
    try testing.expectEqual(@as(usize, 2), entries); // tree and saved; no leaked temporary file
}

test "baseline storage validates checksummed paths before trusting them" {
    const gpa = testing.allocator;
    const root = if (@import("builtin").os.tag == .windows) "C:\\tree" else "/tree";
    const bad = try std.fs.path.join(gpa, &.{ root, "..", "outside" });
    defer gpa.free(bad);
    const directory: format.Directory = .{ .path = bad, .truncated = false, .check_contents = false, .entries = &.{} };
    const state: format.State = .{ .platform = format.platform, .root = root, .recursive = true, .max_dir_entries = 4096, .ignore = &.{}, .only = &.{}, .dirs = &.{directory} };
    const bytes = try format.encode(gpa, state);
    defer gpa.free(bytes);
    try testing.expectError(error.InvalidBaseline, format.parse(gpa, bytes));
}

test "durable baseline saves sync before and after replacement and preserve named failures" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree");
    const root = try tmp.dir.realPathFileAlloc(io, "tree", gpa);
    defer gpa.free(root);
    const parent = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(parent);
    const filename = try std.fs.path.join(gpa, &.{ parent, "saved" });
    defer gpa.free(filename);
    var b = try seed(gpa, io, root, .{});
    defer b.deinit(gpa);
    try b.save(gpa, filename);
    const original = try tmp.dir.readFileAlloc(io, "saved", gpa, .unlimited);
    defer gpa.free(original);
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/new", .data = "one" });
    _ = try b.diff(gpa);
    if (@import("builtin").os.tag == .windows) {
        try testing.expectError(error.UnsupportedBaselineDurability, b.saveWithOptions(gpa, filename, .{ .durable = true }));
        const after = try tmp.dir.readFileAlloc(io, "saved", gpa, .unlimited);
        defer gpa.free(after);
        try testing.expectEqualSlices(u8, original, after);
        return;
    }
    const Sync = struct {
        var calls: usize = 0;
        var fail_at: usize = 0;
        fn sync(context: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
            calls += 1;
            if (calls == fail_at) return error.NoSpaceLeft;
            return testing.io.vtable.fileSync(context, file);
        }
    };
    var vtable = io.vtable.*;
    vtable.fileSync = Sync.sync;
    b.io = .{ .userdata = io.userdata, .vtable = &vtable };
    Sync.calls = 0;
    Sync.fail_at = 1;
    try testing.expectError(error.NoSpaceLeft, b.saveWithOptions(gpa, filename, .{ .durable = true }));
    const unchanged = try tmp.dir.readFileAlloc(io, "saved", gpa, .unlimited);
    defer gpa.free(unchanged);
    try testing.expectEqualSlices(u8, original, unchanged);
    Sync.calls = 0;
    Sync.fail_at = 2;
    try testing.expectError(error.NoSpaceLeft, b.saveWithOptions(gpa, filename, .{ .durable = true }));
    var replaced = try load(gpa, io, filename, root, .{});
    defer replaced.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), (try replaced.diff(gpa)).len);
    Sync.calls = 0;
    Sync.fail_at = 0;
    try b.saveWithOptions(gpa, filename, .{ .durable = true });
    try testing.expectEqual(@as(usize, 2), Sync.calls);
    Sync.calls = 0;
    try b.save(gpa, filename);
    try testing.expectEqual(@as(usize, 0), Sync.calls);
}
