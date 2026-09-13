//! The events one `zwatch.Watcher.poll` call has collected so far, and
//! the writes it is still waiting to see the end of.
//!
//! Backends push raw, uncoalesced events in as they read them from the
//! operating system. The batch keeps at most one `Event` per absolute
//! path and merges each new kind into the one already recorded, which is
//! what turns a burst of writes on one file into a single `modified`.
//!
//! When `zwatch.Options.settle_ms` is set, `modified` does not go into
//! the batch at all until the path has been still for that long; see
//! `promote`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zwatch = @import("zwatch.zig");
const Event = zwatch.Event;
const Kind = zwatch.Kind;
const WatchId = zwatch.WatchId;

const Batch = @This();

/// Read for the timestamps `settle_ms` compares. Unused when it is zero.
io: Io,
/// `zwatch.Options.settle_ms` in nanoseconds. Zero means report a
/// modification as soon as it is seen.
settle_ns: i96,
/// The events of the current window, in the order their paths were first
/// touched. Every `path` and every `from` is owned by this batch.
events: std.ArrayList(Event),
/// Maps an event's path to its index in `events`. Keys are the same
/// allocations as `Event.path`, owned by `events`.
index: std.StringHashMapUnmanaged(u32),
/// Paths that have been modified but not yet been still for `settle_ns`.
/// Survives `reset`, because a file still being written is not news that
/// expires with the poll that noticed it. Keys are owned here.
settling: std.StringArrayHashMapUnmanaged(Settling),

/// A modification that has not stopped happening yet.
const Settling = struct {
    id: WatchId,
    /// When the most recent modification of this path was seen.
    last_ns: i96,
};

/// A batch that owns nothing.
pub fn init(io: Io, options: zwatch.Options) Batch {
    return .{
        .io = io,
        .settle_ns = @as(i96, options.settle_ms) * std.time.ns_per_ms,
        .events = .empty,
        .index = .empty,
        .settling = .empty,
    };
}

/// Releases the events, their paths, and anything still settling.
pub fn deinit(b: *Batch, gpa: Allocator) void {
    b.reset(gpa);
    b.events.deinit(gpa);
    b.index.deinit(gpa);
    for (b.settling.keys()) |path| gpa.free(path);
    b.settling.deinit(gpa);
    b.* = undefined;
}

/// Drops every event of the previous window. This is what invalidates the
/// slice the previous `poll` returned.
pub fn reset(b: *Batch, gpa: Allocator) void {
    for (b.events.items) |event| {
        gpa.free(event.path);
        if (event.from) |from| gpa.free(from);
    }
    b.events.clearRetainingCapacity();
    b.index.clearRetainingCapacity();
}

/// Records that `kind` happened to `path`, merging with anything already
/// recorded for that path in this window. `path` is copied.
pub fn push(b: *Batch, gpa: Allocator, id: WatchId, path: []const u8, kind: Kind) Allocator.Error!void {
    return b.pushDetail(gpa, id, path, kind, null);
}

/// Records that `from` is now `path`: one event rather than a removal and
/// a creation, for the backends whose kernel pairs the two halves. Both
/// paths are copied.
pub fn pushRename(b: *Batch, gpa: Allocator, id: WatchId, path: []const u8, from: []const u8) Allocator.Error!void {
    return b.pushDetail(gpa, id, path, .renamed, from);
}

fn pushDetail(
    b: *Batch,
    gpa: Allocator,
    id: WatchId,
    path: []const u8,
    kind: Kind,
    from: ?[]const u8,
) Allocator.Error!void {
    if (kind == .modified and b.settle_ns > 0) {
        const now = Io.Timestamp.now(b.io, .awake).nanoseconds;
        if (b.settling.getPtr(path)) |entry| {
            entry.last_ns = now;
            return;
        }
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try b.settling.put(gpa, owned, .{ .id = id, .last_ns = now });
        return;
    }
    // Anything else that happens to a path ends the question of whether
    // its contents have stopped changing: the name has been created,
    // removed or moved since.
    if (b.settling.fetchSwapRemove(path)) |entry| gpa.free(entry.key);

    if (b.index.get(path)) |i| {
        const existing = &b.events.items[i];
        if (rank(kind) > rank(existing.kind)) existing.kind = kind;
        if (from) |source| {
            if (existing.from == null and existing.kind == .renamed) {
                existing.from = try gpa.dupe(u8, source);
            }
        }
        return;
    }

    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    const owned_from = if (from) |source| try gpa.dupe(u8, source) else null;
    errdefer if (owned_from) |f| gpa.free(f);
    try b.events.append(gpa, .{ .id = id, .path = owned_path, .kind = kind, .from = owned_from });
    errdefer _ = b.events.pop();
    try b.index.put(gpa, owned_path, @intCast(b.events.items.len - 1));
}

/// Moves into the batch every path that has now been still for
/// `settle_ns`. A no-op when `settle_ms` is zero, because nothing was
/// ever held back.
pub fn promote(b: *Batch, gpa: Allocator) Allocator.Error!void {
    if (b.settling.count() == 0) return;
    const now = Io.Timestamp.now(b.io, .awake).nanoseconds;

    var i: usize = 0;
    while (i < b.settling.count()) {
        const entry = b.settling.values()[i];
        if (now - entry.last_ns < b.settle_ns) {
            i += 1;
            continue;
        }
        const path = b.settling.keys()[i];
        b.settling.swapRemoveAt(i);
        defer gpa.free(path);
        // Straight to `pushDetail`: going through `push` would put it
        // back, because `settle_ns` is still set.
        try b.record(gpa, entry.id, path, .modified);
    }
}

/// How long until the earliest settling path is due, or `null` when none
/// is. `zwatch.Watcher.poll` uses it to wake in time rather than sleep
/// through a deadline it set itself.
pub fn nextDueMs(b: *const Batch) ?u32 {
    if (b.settling.count() == 0) return null;
    const now = Io.Timestamp.now(b.io, .awake).nanoseconds;
    var soonest: i96 = std.math.maxInt(i96);
    for (b.settling.values()) |entry| {
        const remaining = b.settle_ns - (now - entry.last_ns);
        if (remaining < soonest) soonest = remaining;
    }
    if (soonest <= 0) return 0;
    return @intCast(@divTrunc(soonest, std.time.ns_per_ms) + 1);
}

/// `pushDetail` without the settling detour.
fn record(b: *Batch, gpa: Allocator, id: WatchId, path: []const u8, kind: Kind) Allocator.Error!void {
    if (b.index.get(path)) |i| {
        const existing = &b.events.items[i];
        if (rank(kind) > rank(existing.kind)) existing.kind = kind;
        return;
    }
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    try b.events.append(gpa, .{ .id = id, .path = owned, .kind = kind });
    errdefer _ = b.events.pop();
    try b.index.put(gpa, owned, @intCast(b.events.items.len - 1));
}

/// How much a kind outranks another when two land on one path in one
/// window. The order is documented on `zwatch.Kind`: a stronger statement
/// about the path wins, and `overflow` — which says the record is
/// incomplete — wins over every claim that it is complete.
fn rank(kind: Kind) u3 {
    return switch (kind) {
        .attributes => 0,
        .modified => 1,
        .created => 2,
        .renamed => 3,
        .removed => 4,
        .overflow => 5,
    };
}

const testing = std.testing;

fn testBatch(settle_ms: u32) Batch {
    return .init(testing.io, .{ .settle_ms = settle_ms });
}

test "one event per path, strongest kind wins" {
    const gpa = testing.allocator;
    var b = testBatch(0);
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/tmp/a", .modified);
    try b.push(gpa, id, "/tmp/a", .created);
    try b.push(gpa, id, "/tmp/a", .attributes);
    try b.push(gpa, id, "/tmp/b", .modified);

    try testing.expectEqual(@as(usize, 2), b.events.items.len);
    try testing.expectEqualStrings("/tmp/a", b.events.items[0].path);
    try testing.expectEqual(Kind.created, b.events.items[0].kind);
    try testing.expectEqual(Kind.modified, b.events.items[1].kind);
}

test "removal outranks creation and overflow outranks everything" {
    const gpa = testing.allocator;
    var b = testBatch(0);
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(7);
    try b.push(gpa, id, "/tmp/a", .created);
    try b.push(gpa, id, "/tmp/a", .removed);
    try testing.expectEqual(Kind.removed, b.events.items[0].kind);

    try b.push(gpa, id, "/tmp/a", .overflow);
    try testing.expectEqual(Kind.overflow, b.events.items[0].kind);
}

test "reset drops the previous window" {
    const gpa = testing.allocator;
    var b = testBatch(0);
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created);
    b.reset(gpa);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified);
    try testing.expectEqual(Kind.modified, b.events.items[0].kind);
}

test "a paired rename is one event carrying where it came from" {
    const gpa = testing.allocator;
    var b = testBatch(0);
    defer b.deinit(gpa);

    try b.pushRename(gpa, @enumFromInt(0), "/tmp/new", "/tmp/old");
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.renamed, b.events.items[0].kind);
    try testing.expectEqualStrings("/tmp/new", b.events.items[0].path);
    try testing.expectEqualStrings("/tmp/old", b.events.items[0].from.?);
}

test "a settling modification is held back until it is due" {
    const gpa = testing.allocator;
    var b = testBatch(50);
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified);
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);
    try testing.expect(b.nextDueMs().? > 0);

    // Reaching back in time is the same as waiting, and a test that waits
    // on a wall clock is a test that fails on a loaded machine.
    b.settling.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.modified, b.events.items[0].kind);
    try testing.expectEqual(@as(?u32, null), b.nextDueMs());
}

test "a name event settles the question of the contents" {
    const gpa = testing.allocator;
    var b = testBatch(50);
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified);
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .removed);
    try testing.expectEqual(@as(usize, 0), b.settling.count());
    try testing.expectEqual(Kind.removed, b.events.items[0].kind);
}
