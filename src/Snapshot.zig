//! What one watched directory looked like the last time it was scanned.
//!
//! `kqueue` says that a directory changed but not how, and the `poll`
//! backend is not told anything at all, so both learn what happened by
//! listing the directory and comparing it against the listing they kept.
//! `inotify` is told the name by the kernel and does not use this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const lookout = @import("types.zig");
const Kind = lookout.Kind;

const Snapshot = @This();

/// One remembered directory entry, keyed by name. Keys are owned by the
/// snapshot.
entries: std.array_hash_map.String(Meta),
/// Set when the directory held more entries than the scan was allowed to
/// track, so the comparison above is known to be incomplete.
truncated: bool,
/// Polling checks content when timestamps can still hide a write.
check_contents: bool = false,

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
    /// The timestamps share or follow the snapshot's filesystem tick.
    racy: bool = false,
    /// Content remembered for a racy entry, or null if it cannot be read
    /// within the cap. A null hash never proves a racy entry unchanged.
    content_hash: ?u64 = null,

    /// Compares content before trusting unchanged timestamps, including
    /// the last scan before a racy entry becomes old enough to trust.
    pub fn contentChanged(old: Meta, next: Meta) bool {
        return old.racy and (old.content_hash == null or next.content_hash == null or
            old.content_hash.? != next.content_hash.?);
    }
};

/// Hash at most 1 MiB per entry per scan, using an 8 KiB stack buffer.
/// Larger or unreadable racy entries conservatively report modification.
pub const content_hash_cap = 1024 * 1024;

// Use a conservative two-second tick on every platform: FAT modification
// times have that resolution, and the stat API exposes no filesystem tick.
// Finer filesystems may need extra hashes, but never miss a same-tick write.
const timestamp_tick_ns = 2 * std.time.ns_per_s;

/// Captures metadata and, for polling, content while its timestamp is racy.
/// taken_ns is sampled before stat so a scan crossing a tick stays racy.
pub fn capture(io: Io, dir: Io.Dir, path: []const u8, stat: Io.File.Stat, taken_ns: i96, check_contents: bool, was_racy: bool) Meta {
    const tick = @divFloor(taken_ns, timestamp_tick_ns);
    const racy = check_contents and stat.kind != .directory and
        (@divFloor(stat.mtime.nanoseconds, timestamp_tick_ns) >= tick or
            @divFloor(stat.ctime.nanoseconds, timestamp_tick_ns) >= tick);
    return .{
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .ctime_ns = stat.ctime.nanoseconds,
        .file_kind = stat.kind,
        .racy = racy,
        .content_hash = if (racy or was_racy) hashContent(io, dir, path, stat) else null,
    };
}

fn hashContent(io: Io, dir: Io.Dir, path: []const u8, stat: Io.File.Stat) ?u64 {
    // Never open a special file or follow a symlink to hash its target.
    if (stat.kind != .file or stat.size > content_hash_cap) return null;
    var file = dir.openFile(io, path, .{ .follow_symlinks = false, .allow_directory = false }) catch return null;
    defer file.close(io);
    var hash = std.hash.Wyhash.init(0);
    var buffer: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const count: usize = @intCast(@min(buffer.len, stat.size - offset));
        const n = file.readPositionalAll(io, buffer[0..count], offset) catch return null;
        if (n != count) return null;
        hash.update(buffer[0..n]);
        offset += n;
    }
    return hash.final();
}

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
/// changes past the limit cannot be seen. Once entries are remembered,
/// a truncated scan keeps them until a complete listing can be compared.
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
) Snapshot.RefreshError!void {
    var next = try s.prepare(gpa, io, dir, max_entries, changes);
    s.accept(gpa, &next);
}

/// Prepares a listing and its changes without advancing the baseline.
/// The caller owns the result until every change has been accounted for.
pub fn prepare(s: *const Snapshot, gpa: Allocator, io: Io, dir: Io.Dir, max_entries: usize, changes: *std.ArrayList(Change)) Snapshot.RefreshError!Snapshot {
    var next = try s.readListing(gpa, io, dir, max_entries);
    errdefer next.deinit(gpa);
    try next.compare(gpa, s, changes);
    return next;
}

/// Publishes a prepared listing without allocation. A truncated listing
/// reports only what it read and keeps the last complete baseline.
pub fn accept(s: *Snapshot, gpa: Allocator, next: *Snapshot) void {
    if (next.truncated and s.entries.count() != 0) {
        s.truncated = true;
        next.deinit(gpa);
        return;
    }
    s.deinit(gpa);
    s.* = next.*;
    next.* = undefined;
}

/// Reads a listing without advancing the snapshot it will be compared to.
/// If it is truncated, keeps the remembered entries: an omitted name is
/// not evidence of a removal. The caller owns the result.
pub fn read(before: *const Snapshot, gpa: Allocator, io: Io, dir: Io.Dir, max_entries: usize) Snapshot.RefreshError!Snapshot {
    var next = try before.readListing(gpa, io, dir, max_entries);
    errdefer next.deinit(gpa);
    if (next.truncated and before.entries.count() != 0) {
        next.deinit(gpa);
        next = .{ .entries = .empty, .truncated = true, .check_contents = before.check_contents };
        for (before.entries.keys(), before.entries.values()) |name, meta| {
            const owned = try gpa.dupe(u8, name);
            errdefer gpa.free(owned);
            try next.entries.put(gpa, owned, meta);
        }
    }
    return next;
}

fn readListing(before: *const Snapshot, gpa: Allocator, io: Io, dir: Io.Dir, max_entries: usize) RefreshError!Snapshot {
    var next: Snapshot = .empty;
    next.check_contents = before.check_contents;
    errdefer next.deinit(gpa);
    const taken_ns = Io.Clock.real.now(io).nanoseconds;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (next.entries.count() >= max_entries) {
            next.truncated = true;
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
        const was_racy = if (before.entries.get(entry.name)) |old| old.racy else false;
        try next.entries.put(gpa, name, capture(io, dir, entry.name, stat, taken_ns, next.check_contents, was_racy));
    }
    // A listing holds at most its budget, and is cut short only there.
    assert(next.entries.count() <= max_entries);
    assert(!next.truncated or next.entries.count() == max_entries);
    return next;
}

/// Appends the differences without changing either listing. On error,
/// nothing is appended and the caller can retry against the same pair.
pub fn compare(s: *const Snapshot, gpa: Allocator, before: *const Snapshot, changes: *std.ArrayList(Change)) Allocator.Error!void {
    const start = changes.items.len;
    errdefer {
        for (changes.items[start..]) |change| gpa.free(change.name);
        changes.shrinkRetainingCapacity(start);
    }

    for (s.entries.keys(), s.entries.values()) |name, meta| {
        const old = before.entries.get(name) orelse {
            try append(gpa, changes, name, .created, meta.file_kind);
            continue;
        };
        if (old.file_kind != meta.file_kind) {
            try append(gpa, changes, name, .created, meta.file_kind);
        } else if (old.size != meta.size or old.mtime_ns != meta.mtime_ns or old.contentChanged(meta)) {
            try append(gpa, changes, name, .modified, meta.file_kind);
        } else if (old.ctime_ns != meta.ctime_ns) {
            try append(gpa, changes, name, .attributes, meta.file_kind);
        }
    }
    if (s.truncated) return;
    for (before.entries.keys(), before.entries.values()) |name, meta| {
        if (s.entries.contains(name)) continue;
        try append(gpa, changes, name, .removed, meta.file_kind);
    }
}

fn append(
    gpa: Allocator,
    changes: *std.ArrayList(Change),
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

const shakedown = @import("shakedown");

test "racy content checks stop reading at the cap and after timestamps age" {
    const testing = std.testing;
    const fio = try shakedown.FaultIo.init(testing.allocator, testing.io, .{});
    defer fio.deinit();
    const io = fio.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "file", .{ .read = true });
    defer file.close(io);
    try file.setLength(io, content_hash_cap);
    var stat = try file.stat(io);
    stat.mtime.nanoseconds = 2 * std.time.ns_per_s;
    stat.ctime.nanoseconds = 0;
    const taken_ns = 3 * std.time.ns_per_s + 500 * std.time.ns_per_ms;
    const before = capture(io, tmp.dir, "file", stat, taken_ns, true, false);
    try testing.expect(before.racy);
    try testing.expect(before.content_hash != null);
    try testing.expect(fio.count(.fileReadPositional) > 0);

    // Even an entry aging on this scan needs its final content comparison.
    const aged = capture(io, tmp.dir, "file", stat, 4 * std.time.ns_per_s, true, before.racy);
    try testing.expect(!aged.racy);
    try testing.expect(!before.contentChanged(aged));
    const reads = fio.count(.fileReadPositional);
    const quiet = capture(io, tmp.dir, "file", stat, 4 * std.time.ns_per_s, true, aged.racy);
    try testing.expect(!quiet.racy);
    try testing.expectEqual(reads, fio.count(.fileReadPositional));

    try file.setLength(io, content_hash_cap + 1);
    stat.size = content_hash_cap + 1;
    const large = capture(io, tmp.dir, "file", stat, taken_ns, true, false);
    try testing.expect(large.racy);
    try testing.expect(large.content_hash == null);
    try testing.expect(large.contentChanged(large));
    try testing.expectEqual(reads, fio.count(.fileReadPositional));

    stat.size = content_hash_cap;
    try fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .fileReadPositional, .n = 1 } }, .fault = .{ .fail = error.AccessDenied }, .times = 0 }});
    const unreadable = capture(io, tmp.dir, "file", stat, taken_ns, true, false);
    try testing.expect(unreadable.racy);
    try testing.expect(unreadable.content_hash == null);
    try testing.expect(before.contentChanged(unreadable));

    // Equality, ctime alone and future times all stay conservative; a
    // strictly older tick permits the metadata-only comparison.
    stat.mtime.nanoseconds = 0;
    stat.ctime.nanoseconds = 2 * std.time.ns_per_s;
    try testing.expect(capture(io, tmp.dir, "file", stat, taken_ns, true, false).racy);
    stat.ctime.nanoseconds = 8 * std.time.ns_per_s;
    try testing.expect(capture(io, tmp.dir, "file", stat, taken_ns, true, false).racy);
    stat.ctime.nanoseconds = 0;
    try testing.expect(capture(io, tmp.dir, "file", stat, 0, true, false).racy);
    try testing.expect(!capture(io, tmp.dir, "file", stat, taken_ns, true, false).racy);
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
            .sub_path = std.mem.print(&name, "f{d}", .{i}) catch unreachable,
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

test "a truncated refresh keeps the last listing for later comparison" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "kept", .data = "one" });
    var snapshot: Snapshot = .empty;
    defer snapshot.deinit(gpa);
    var changes: std.ArrayList(Change) = .empty;
    defer {
        freeChanges(gpa, &changes);
        changes.deinit(gpa);
    }
    try snapshot.refresh(gpa, io, tmp.dir, 1, &changes);
    freeChanges(gpa, &changes);
    try snapshot.refresh(gpa, io, tmp.dir, 0, &changes);
    try std.testing.expect(snapshot.truncated);
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);
    try std.testing.expect(snapshot.entries.contains("kept"));
    try tmp.dir.deleteFile(io, "kept");
    try snapshot.refresh(gpa, io, tmp.dir, 1, &changes);
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expectEqual(Kind.removed, changes.items[0].kind);
}
