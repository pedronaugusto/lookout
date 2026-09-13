//! What one watched directory looked like the last time it was scanned.
//!
//! `kqueue` says that a directory changed but not how, and the `poll`
//! backend is not told anything at all, so both learn what happened by
//! listing the directory and comparing it against the listing they kept.
//! `inotify` is told the name by the kernel and does not use this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const lookout = @import("lookout.zig");
const Kind = lookout.Kind;

const Snapshot = @This();

/// One remembered directory entry, keyed by name. Keys are owned by the
/// snapshot.
entries: std.StringArrayHashMapUnmanaged(Meta),
/// Set when the directory held more entries than the scan was allowed to
/// track, so the comparison above is known to be incomplete.
truncated: bool,

/// The metadata a scan compares. Deliberately small: a rescan of a large
/// directory touches one of these per entry.
pub const Meta = struct {
    /// Size in bytes. Compared for `Kind.modified`.
    size: u64,
    /// Modification time in nanoseconds since the Unix epoch. Compared for
    /// `Kind.modified`.
    mtime_ns: i96,
    /// Status-change time in nanoseconds since the Unix epoch. Compared
    /// for `Kind.attributes` when the contents look unchanged.
    ctime_ns: i96,
    /// What kind of file-system object the entry is. A name that changes
    /// kind is reported as `Kind.created`: the object at that path is a
    /// different one.
    file_kind: Io.File.Kind,
};

/// One difference between the remembered listing and the current one. The
/// caller owns `name` and must free it with the same allocator it passed
/// to `refresh`.
pub const Change = struct {
    /// Entry name, not a path: join it with the directory to spell the
    /// event.
    name: []u8,
    /// What happened to it.
    kind: Kind,
    /// What the entry is now, or was before it was removed. Lets a
    /// recursive watch notice a new subdirectory.
    file_kind: Io.File.Kind,
};

/// Errors a scan can return.
pub const RefreshError = Allocator.Error || Io.Dir.Iterator.Error || Io.Dir.StatFileError;

/// A snapshot of nothing, which makes the first `refresh` report every
/// entry as `Kind.created`. A caller that only wants changes from now on
/// runs one `refresh` and discards its changes.
pub const empty: Snapshot = .{ .entries = .empty, .truncated = false };

/// Releases the remembered listing.
pub fn deinit(s: *Snapshot, gpa: Allocator) void {
    for (s.entries.keys()) |name| gpa.free(name);
    s.entries.deinit(gpa);
    s.* = undefined;
}

/// Lists `dir`, appends how it differs from the remembered listing to
/// `changes`, and remembers the new listing.
///
/// At most `max_entries` entries are tracked. A directory with more sets
/// `truncated`, which the caller reports as `Kind.overflow`, because
/// changes past the limit cannot be seen.
///
/// On error the snapshot is left as it was, so a scan that fails halfway —
/// the directory was deleted under it — does not turn the next successful
/// scan into a flood of false `created` events.
pub fn refresh(
    s: *Snapshot,
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    max_entries: usize,
    changes: *std.ArrayList(Change),
) RefreshError!void {
    var next: std.StringArrayHashMapUnmanaged(Meta) = .empty;
    var truncated = false;
    errdefer {
        for (next.keys()) |name| gpa.free(name);
        next.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (next.count() >= max_entries) {
            truncated = true;
            break;
        }
        // An entry can be gone between the listing and the stat; that is a
        // removal the next scan reports, not an error.
        const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try next.put(gpa, name, .{
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
            .file_kind = stat.kind,
        });
    }

    // Everything below only appends to `changes`, so a failure there leaves
    // the caller with a prefix of the real changes and the old snapshot —
    // the next scan re-derives the rest.
    const start = changes.items.len;
    errdefer {
        for (changes.items[start..]) |change| gpa.free(change.name);
        changes.shrinkRetainingCapacity(start);
    }

    for (next.keys(), next.values()) |name, meta| {
        const before = s.entries.get(name) orelse {
            try append(changes, gpa, name, .created, meta.file_kind);
            continue;
        };
        if (before.file_kind != meta.file_kind) {
            try append(changes, gpa, name, .created, meta.file_kind);
        } else if (before.size != meta.size or before.mtime_ns != meta.mtime_ns) {
            try append(changes, gpa, name, .modified, meta.file_kind);
        } else if (before.ctime_ns != meta.ctime_ns) {
            try append(changes, gpa, name, .attributes, meta.file_kind);
        }
    }
    for (s.entries.keys(), s.entries.values()) |name, meta| {
        if (next.contains(name)) continue;
        try append(changes, gpa, name, .removed, meta.file_kind);
    }

    for (s.entries.keys()) |name| gpa.free(name);
    s.entries.deinit(gpa);
    s.entries = next;
    s.truncated = truncated;
}

fn append(
    changes: *std.ArrayList(Change),
    gpa: Allocator,
    name: []const u8,
    kind: Kind,
    file_kind: Io.File.Kind,
) Allocator.Error!void {
    const owned = try gpa.dupe(u8, name);
    errdefer gpa.free(owned);
    try changes.append(gpa, .{ .name = owned, .kind = kind, .file_kind = file_kind });
}

/// Frees the names of a change list and empties it.
pub fn freeChanges(gpa: Allocator, changes: *std.ArrayList(Change)) void {
    for (changes.items) |change| gpa.free(change.name);
    changes.clearRetainingCapacity();
}

test "first refresh reports every entry, second reports the difference" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var snapshot: Snapshot = .empty;
    defer snapshot.deinit(gpa);
    var changes: std.ArrayList(Snapshot.Change) = .empty;
    defer {
        freeChanges(gpa, &changes);
        changes.deinit(gpa);
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    try snapshot.refresh(gpa, io, tmp.dir, 128, &changes);
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expectEqualStrings("a.txt", changes.items[0].name);
    try std.testing.expectEqual(Kind.created, changes.items[0].kind);

    freeChanges(gpa, &changes);
    try snapshot.refresh(gpa, io, tmp.dir, 128, &changes);
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);

    freeChanges(gpa, &changes);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one and two" });
    try snapshot.refresh(gpa, io, tmp.dir, 128, &changes);
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expectEqual(Kind.modified, changes.items[0].kind);

    freeChanges(gpa, &changes);
    try tmp.dir.deleteFile(io, "a.txt");
    try snapshot.refresh(gpa, io, tmp.dir, 128, &changes);
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expectEqual(Kind.removed, changes.items[0].kind);
}

test "a directory over the limit is tracked up to it and marked truncated" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    for (0..8) |i| {
        var name: [16]u8 = undefined;
        try tmp.dir.writeFile(io, .{
            .sub_path = std.fmt.bufPrint(&name, "f{d}", .{i}) catch unreachable,
            .data = "x",
        });
    }

    var snapshot: Snapshot = .empty;
    defer snapshot.deinit(gpa);
    var changes: std.ArrayList(Snapshot.Change) = .empty;
    defer {
        freeChanges(gpa, &changes);
        changes.deinit(gpa);
    }

    try snapshot.refresh(gpa, io, tmp.dir, 3, &changes);
    try std.testing.expect(snapshot.truncated);
    try std.testing.expectEqual(@as(usize, 3), changes.items.len);
}
