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
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const airlock = @import("airlock");
const intake = @import("intake.zig");

const lookout = @import("types.zig");
const Filter = @import("Filter.zig");
const CompiledFilter = @import("CompiledFilter.zig");
const Snapshot = @import("Snapshot.zig");
const identity = @import("identity.zig");
const path_cmp = @import("path.zig");
const format = @import("Baseline/format.zig");
const Kind = lookout.Kind;
const Target = lookout.Target;

const Baseline = @This();

/// Kept for the listings and the last diff, and released by `deinit`.
gpa: Allocator,
/// Absolute, canonical path of the tree, owned here.
root: []u8,
/// Mirrors `Options.recursive`.
recursive: bool,
/// Mirrors `Options.max_dir_entries`.
max_dir_entries: usize,
/// Mirrors `Options.filter`, copied.
filter: CompiledFilter,
identity_override: ?identity.Policy = null,
/// One remembered listing per directory, keyed by absolute path. Keys
/// owned here.
dirs: std.array_hash_map.String(Remembered),
/// What the last `diff` found. Every path is owned here and is dropped by
/// the next `diff` or by `deinit`.
changes: std.ArrayList(Change),
/// Scratch the listing comparison writes into, reused between directories.
scratch: std.ArrayList(Snapshot.Change),

/// One directory's remembered listing.
const Remembered = struct {
    snapshot: Snapshot,
    policy: identity.Policy = .{},
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
    /// Caller policy independent of the directory capability query.
    identity: ?identity.Policy = null,
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

/// Errors `seed` can return, on top of the file-system errors of reading
/// the tree.
/// `InvalidPattern` and `PatternTooLong` name a filter pattern refused.
pub const SeedError = DiffError || CompiledFilter.Error;

/// Errors `diff` can return: the reads `seed` makes, made again.
pub const DiffError = Allocator.Error || Io.Dir.OpenError ||
    Io.Dir.RealPathFileAllocError || Snapshot.RefreshError;

/// Remembers what is in `path` now, so that a later `diff` can say what
/// has changed since.
///
/// `path` must be a directory and must exist; a file has no listing to
/// compare and `error.NotDir` says so. Call this where the watch is
/// taken, so that the two cover the same tree from the same moment.
///
/// `gpa` is kept until `deinit`; `io` is used here and not kept.
pub fn seed(gpa: Allocator, io: Io, path: []const u8, options: Options) Baseline.SeedError!Baseline {
    const real = try identity.canonical(gpa, io, path);
    defer gpa.free(real);

    // Everything is owned by `b` from here, so there is one thing to
    // undo on failure rather than three that would undo each other.
    var b: Baseline = .{
        .gpa = gpa,
        .root = try gpa.dupe(u8, real),
        .recursive = options.recursive,
        .max_dir_entries = options.max_dir_entries,
        .filter = .none,
        .identity_override = options.identity,
        .dirs = .empty,
        .changes = .empty,
        .scratch = .empty,
    };
    errdefer b.deinit();
    b.filter = try .compilePolicy(gpa, options.filter, identity.read(io, real).policy(options.identity));
    try b.scan(gpa, io, false);
    return b;
}

/// Releases the remembered listings and the last diff.
pub fn deinit(b: *Baseline) void {
    const gpa = b.gpa;
    b.forgetAll(gpa);
    b.dirs.deinit(gpa);
    b.clearChanges(gpa);
    b.changes.deinit(gpa);
    Snapshot.freeChanges(gpa, &b.scratch);
    b.scratch.deinit(gpa);
    b.filter.deinit();
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
pub fn diff(b: *Baseline, io: Io) Baseline.DiffError![]const Change {
    try b.scan(b.gpa, io, true);
    return b.changes.items;
}

/// Errors `save` can return.
pub const SaveError = Allocator.Error || airlock.WriteFileOrRefuseError || error{UnsupportedBaselineFilter};
/// Errors `load` can return.
pub const LoadError = format.ParseError || aegis.own.ReadFileError || Io.Dir.RealPathFileAllocError ||
    CompiledFilter.Error || error{UnsupportedBaselineFilter};

/// How `save` writes the file.
pub const SaveOptions = struct {
    /// Make the new file survive a power cut once `save` returns: its
    /// contents are synced before it replaces the old one, and its
    /// directory after. A filesystem that refuses those syncs is
    /// `error.LevelUnavailable` and the old file stays; Linux learns that
    /// a directory refuses only after the replacement, which is then
    /// `error.PublishedNotDurable`.
    durable: bool = false,
};

/// The prefix of the temporary file `save` writes next to the baseline.
/// A crash during a save can leave one behind; `airlock.pruneTemps`
/// removes them by this prefix.
pub const temp_prefix = ".lookout-";

/// Atomically replaces the caller-named file with this baseline, without
/// walking again: readers see the old file or the new one. Keep it outside
/// the watched tree. Predicate filters cannot be serialized and return
/// UnsupportedBaselineFilter. A failure before the replacement leaves the
/// old file as it was; `error.PublishedNotDurable` means the new file is
/// in place and its directory's sync failed.
pub fn save(b: *const Baseline, io: Io, filename: []const u8, options: SaveOptions) Baseline.SaveError!void {
    if (b.filter.allow != null) return error.UnsupportedBaselineFilter;
    var arena: std.heap.ArenaAllocator = .init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dirs = try a.alloc(format.Directory, b.dirs.count());
    for (b.dirs.keys(), b.dirs.values(), dirs) |path, remembered, *dir| {
        const entries = try a.alloc(format.Entry, remembered.snapshot.entries.count());
        for (remembered.snapshot.entries.keys(), remembered.snapshot.entries.values(), entries) |name, meta, *entry| entry.* = .{ .name = name, .meta = .of(meta) };
        dir.* = .{ .path = path, .truncated = remembered.snapshot.truncated, .check_contents = remembered.snapshot.check_contents, .entries = entries, .policy = remembered.policy };
    }
    const bytes = try format.encode(a, .{ .platform = format.platform, .root = b.root, .recursive = b.recursive, .max_dir_entries = b.max_dir_entries, .ignore = b.filter.ignore, .only = b.filter.only, .case = b.filter.case, .normalization = b.filter.normalization, .policy = b.filter.policy, .identity_override = b.identity_override, .dirs = dirs });
    _ = try airlock.writeFileOrRefuse(io, Io.Dir.cwd(), filename, bytes, .{
        .create = .{ .temp = .{ .random = temp_prefix } },
        .commit = .{ .level = if (options.durable) .data else .none },
    });
}

/// Loads an owned baseline without walking. The root, scope, budget and
/// pattern filters must match those supplied by the caller. Corrupt, foreign
/// and old-version files return InvalidBaseline, ForeignBaseline and
/// UnsupportedBaselineVersion respectively. A later diff costs one walk.
/// `gpa` is kept until `deinit`, as by `seed`.
pub fn load(gpa: Allocator, io: Io, filename: []const u8, root: []const u8, options: Options) Baseline.LoadError!Baseline {
    if (options.filter.allow != null) return error.UnsupportedBaselineFilter;
    const read = intake.readFile(io, .cwd(), filename, gpa, .fromRaw(format.file_limit)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidBaseline,
        else => return err,
    };
    const bytes = read.readForParse();
    defer gpa.free(bytes);
    var parsed = try format.parse(gpa, bytes);
    defer parsed.deinit();
    const state = parsed.value;
    const real = identity.canonical(gpa, io, root) catch |err| switch (err) {
        error.FileNotFound => if (std.Io.Dir.path.isAbsolute(root)) try gpa.dupe(u8, root) else return err,
        else => return err,
    };
    defer gpa.free(real);
    if (!path_cmp.eql(real, state.root) or options.recursive != state.recursive or
        options.max_dir_entries != state.max_dir_entries or !samePatterns(options.filter.ignore, state.ignore) or
        !samePatterns(options.filter.only, state.only) or options.filter.case != state.case or options.filter.normalization != state.normalization or !std.meta.eql(options.identity, state.identity_override)) return error.ForeignBaseline;
    var b: Baseline = .{ .gpa = gpa, .root = try gpa.dupe(u8, state.root), .recursive = state.recursive, .max_dir_entries = state.max_dir_entries, .filter = .none, .identity_override = options.identity, .dirs = .empty, .changes = .empty, .scratch = .empty };
    errdefer b.deinit();
    b.filter = try .compilePolicy(gpa, options.filter, identity.read(io, real).policy(options.identity));
    for (state.dirs) |dir| {
        const owned = try gpa.dupe(u8, dir.path);
        errdefer gpa.free(owned);
        var snapshot: Snapshot = .{ .entries = .empty, .truncated = dir.truncated, .check_contents = dir.check_contents };
        errdefer snapshot.deinit(gpa);
        for (dir.entries) |entry| {
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);
            try snapshot.entries.put(gpa, name, entry.meta.snapshot());
        }
        try b.dirs.put(gpa, owned, .{ .snapshot = snapshot, .policy = dir.policy });
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
fn scan(b: *Baseline, gpa: Allocator, io: Io, report: bool) DiffError!void {
    // The scan owns new listings and paths until all traversal and reporting
    // have succeeded. The remembered tree stays available for comparison
    // throughout; publishing the result needs no allocation.
    var next: Scan = .{ .baseline = b, .scratch = b.scratch };
    b.scratch = .empty;
    defer {
        b.scratch = next.scratch;
        next.deinit(gpa);
    }
    try next.run(gpa, io, report);
    std.mem.swap(@TypeOf(b.dirs), &b.dirs, &next.dirs);
    std.mem.swap(@TypeOf(b.changes), &b.changes, &next.changes);
}

/// Owns only the listings and returned paths being prepared. The root and
/// scan options belong to the baseline, which is borrowed until commit.
const Scan = struct {
    baseline: *const Baseline,
    dirs: std.array_hash_map.String(Remembered) = .empty,
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
        s.* = undefined;
    }

    /// A directory no scan has listed yet. Its entries are checked by
    /// content while their timestamps are racy, as polling checks them: a
    /// rewrite to the same size within the timestamp's granularity (a
    /// kernel tick on Linux) leaves size and times as they were.
    const unseen: Snapshot = .{ .entries = .empty, .truncated = false, .check_contents = true };

    fn run(s: *Scan, gpa: Allocator, io: Io, report: bool) DiffError!void {
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
            var dir = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
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
            defer dir.close(io);

            const index = try s.remember(gpa, path);
            const policy = identity.read(io, path).policy(b.identity_override);
            s.dirs.values()[index].policy = policy;
            Snapshot.freeChanges(gpa, &s.scratch);
            const before = if (b.dirs.getPtr(path)) |remembered| &remembered.snapshot else &unseen;
            s.dirs.values()[index].snapshot = try before.read(gpa, io, dir, b.max_dir_entries);

            if (report) {
                try s.dirs.values()[index].snapshot.compare(gpa, before, &s.scratch);
                try s.reportChanges(gpa, path, index);
            }
            if (!b.recursive) continue;

            // The listing just taken is the list of subdirectories to walk,
            // so descending costs no syscall of its own.
            const snapshot = &s.dirs.values()[index].snapshot;
            for (snapshot.entries.keys(), snapshot.entries.values()) |name, meta| {
                if (meta.file_kind != .directory) continue;
                const child = try std.Io.Dir.path.join(gpa, &.{ path, name });
                errdefer gpa.free(child);
                if (b.filter.prunesPolicy(policy, b.root, child)) {
                    gpa.free(child);
                    continue;
                }
                try frontier.append(gpa, child);
            }
        }

        if (report) try s.reportLost(gpa);
    }

    /// Turns one directory's comparison into changes.
    fn reportChanges(s: *Scan, gpa: Allocator, path: []const u8, index: usize) DiffError!void {
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

            const child = try std.Io.Dir.path.join(gpa, &.{ path, change.name });
            defer gpa.free(child);
            if (b.filter.excludesPolicy(s.dirs.values()[index].policy, b.root, child)) continue;
            try s.record(gpa, child, change.kind, .of(change.file_kind));
        }
    }

    /// Reports the contents of directories the scan did not reach. Their
    /// listings still belong to the previous baseline until the scan commits.
    /// The directory itself is reported by its parent's comparison.
    fn reportLost(s: *Scan, gpa: Allocator) DiffError!void {
        const b = s.baseline;
        for (b.dirs.keys(), b.dirs.values()) |path, remembered| {
            if (s.dirs.contains(path)) continue;
            for (remembered.snapshot.entries.keys(), remembered.snapshot.entries.values()) |name, meta| {
                const child = try std.Io.Dir.path.join(gpa, &.{ path, name });
                defer gpa.free(child);
                if (b.filter.excludesPolicy(remembered.policy, b.root, child)) continue;
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
