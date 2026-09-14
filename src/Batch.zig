//! The events one `lookout.Watcher.poll` call has collected so far, and
//! the paths it is still holding back.
//!
//! Backends push raw, uncoalesced events in as they read them from the
//! operating system. The batch keeps at most one `Event` per absolute
//! path and merges each new kind into the one already recorded, which is
//! what turns a burst of writes on one file into a single `modified`.
//!
//! Two options hold a path back rather than recording it at once.
//! `lookout.Options.settle_ms` holds `modified` until the file has
//! stopped changing; `lookout.Options.debounce_ms` holds every kind until
//! the path has been quiet, and then reports the kind seen last. See
//! `promote`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const lookout = @import("lookout.zig");
const Event = lookout.Event;
const Kind = lookout.Kind;
const WatchId = lookout.WatchId;

const Batch = @This();

/// Read for the timestamps every event carries and the ones the holding
/// rules compare.
io: Io,
/// How long a held path must be quiet before it is reported, in
/// nanoseconds. Zero means nothing is ever held.
hold_ns: i96,
/// Whether every kind is held (`lookout.Options.debounce_ms`) or only
/// `modified` (`lookout.Options.settle_ms`).
hold_all: bool,
/// The events of the current window, in the order their paths were first
/// touched. Every `path` and every `from` is owned by this batch.
events: std.ArrayList(Event),
/// Maps an event's path to its index in `events`. Keys are the same
/// allocations as `Event.path`, owned by `events`.
index: std.StringHashMapUnmanaged(u32),
/// Paths that have changed but have not been quiet long enough to be
/// reported. Survives `reset`, because a file still being written is not
/// news that expires with the poll that noticed it. Keys are owned here,
/// and so is each `Held.from`.
held: std.StringArrayHashMapUnmanaged(Held),
/// Counts every push, whether it produced an event or was held back.
///
/// A backend waits until the batch has changed, not until it has grown:
/// under `lookout.Options.debounce_ms` a push produces no event for a
/// while, and a backend watching `events.items.len` would sleep through
/// its own deadline and, with no timeout at all, forever.
revision: u64,

/// A change that has not been reported yet.
const Held = struct {
    id: WatchId,
    /// What happened. Under `debounce_ms` this is the kind seen last.
    kind: Kind,
    /// Where a paired rename came from, owned here.
    from: ?[]u8,
    /// When this path first changed in this window. Becomes `Event.time`.
    first_ns: i96,
    /// When it last changed, which is what the quiet window is measured
    /// from.
    last_ns: i96,
};

/// A batch that owns nothing.
///
/// `debounce_ms` supersedes `settle_ms`: it already holds every kind
/// until the path is quiet, which is the stronger of the two rules.
pub fn init(io: Io, options: lookout.Options) Batch {
    const debouncing = options.debounce_ms > 0;
    const hold_ms: u32 = if (debouncing) options.debounce_ms else options.settle_ms;
    return .{
        .io = io,
        .hold_ns = @as(i96, hold_ms) * std.time.ns_per_ms,
        .hold_all = debouncing,
        .events = .empty,
        .index = .empty,
        .held = .empty,
        .revision = 0,
    };
}

/// Releases the events, their paths, and anything still held.
pub fn deinit(b: *Batch, gpa: Allocator) void {
    b.reset(gpa);
    b.events.deinit(gpa);
    b.index.deinit(gpa);
    for (b.held.keys(), b.held.values()) |path, entry| {
        gpa.free(path);
        if (entry.from) |from| gpa.free(from);
    }
    b.held.deinit(gpa);
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
    b.revision += 1;
    const now = Io.Timestamp.now(b.io, .awake);

    if (b.hold_ns > 0 and (b.hold_all or kind == .modified)) {
        if (b.held.getPtr(path)) |entry| {
            entry.last_ns = now.nanoseconds;
            // Under `debounce_ms` the window reports what happened last,
            // which is the end state; under `settle_ms` only `modified`
            // is ever held, so there is nothing to replace.
            if (b.hold_all) {
                const owned_from = if (from) |source| try gpa.dupe(u8, source) else null;
                if (entry.from) |stale| gpa.free(stale);
                entry.from = owned_from;
                entry.kind = kind;
            }
            return;
        }
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        const owned_from = if (from) |source| try gpa.dupe(u8, source) else null;
        errdefer if (owned_from) |f| gpa.free(f);
        try b.held.put(gpa, owned_path, .{
            .id = id,
            .kind = kind,
            .from = owned_from,
            .first_ns = now.nanoseconds,
            .last_ns = now.nanoseconds,
        });
        return;
    }
    // Anything else that happens to a path ends the question of whether
    // its contents have stopped changing: the name has been created,
    // removed or moved since.
    b.release(gpa, path);
    return b.record(gpa, id, path, kind, from, now);
}

/// Drops every event, and everything held back, belonging to `id`.
///
/// A watch whose path does not exist yet is registered on an ancestor
/// while it waits, and the ancestor's own comings and goings are not what
/// the caller asked about. This is how they are kept out of the batch
/// without the backends having to know why.
pub fn discard(b: *Batch, gpa: Allocator, id: WatchId) void {
    var removed = false;
    var i: usize = 0;
    while (i < b.events.items.len) {
        if (b.events.items[i].id != id) {
            i += 1;
            continue;
        }
        const event = b.events.orderedRemove(i);
        gpa.free(event.path);
        if (event.from) |from| gpa.free(from);
        removed = true;
    }
    if (removed) {
        // The index is a position per path, so removing from the middle
        // of the list means rebuilding it. The capacity is still there.
        b.index.clearRetainingCapacity();
        for (b.events.items, 0..) |event, at| {
            b.index.putAssumeCapacity(event.path, @intCast(at));
        }
    }

    var h: usize = 0;
    while (h < b.held.count()) {
        if (b.held.values()[h].id != id) {
            h += 1;
            continue;
        }
        const path = b.held.keys()[h];
        const entry = b.held.values()[h];
        b.held.swapRemoveAt(h);
        gpa.free(path);
        if (entry.from) |from| gpa.free(from);
    }
}

/// Moves into the batch every path that has now been quiet for
/// `hold_ns`. A no-op when nothing is held back.
pub fn promote(b: *Batch, gpa: Allocator) Allocator.Error!void {
    if (b.held.count() == 0) return;
    const now = Io.Timestamp.now(b.io, .awake).nanoseconds;

    var i: usize = 0;
    while (i < b.held.count()) {
        const entry = b.held.values()[i];
        if (now - entry.last_ns < b.hold_ns) {
            i += 1;
            continue;
        }
        const path = b.held.keys()[i];
        b.held.swapRemoveAt(i);
        defer gpa.free(path);
        defer if (entry.from) |from| gpa.free(from);
        // The event is stamped with when the path first changed, not with
        // when the window closed: the caller wants to know when it
        // happened, not when lookout stopped waiting.
        try b.record(gpa, entry.id, path, entry.kind, entry.from, .{ .nanoseconds = entry.first_ns });
    }
}

/// How long until the earliest held path is due, or `null` when none is.
/// `lookout.Watcher.poll` uses it to wake in time rather than sleep
/// through a deadline it set itself.
pub fn nextDueMs(b: *const Batch) ?u32 {
    if (b.held.count() == 0) return null;
    const now = Io.Timestamp.now(b.io, .awake).nanoseconds;
    var soonest: i96 = std.math.maxInt(i96);
    for (b.held.values()) |entry| {
        const remaining = b.hold_ns - (now - entry.last_ns);
        if (remaining < soonest) soonest = remaining;
    }
    if (soonest <= 0) return 0;
    return @intCast(@divTrunc(soonest, std.time.ns_per_ms) + 1);
}

/// Drops whatever is held for `path`, because something has happened to
/// it that answers the question the hold was waiting on.
fn release(b: *Batch, gpa: Allocator, path: []const u8) void {
    const entry = b.held.fetchSwapRemove(path) orelse return;
    gpa.free(entry.key);
    if (entry.value.from) |from| gpa.free(from);
}

/// Puts one change into the batch, merging it with whatever this window
/// already holds for the same path.
fn record(
    b: *Batch,
    gpa: Allocator,
    id: WatchId,
    path: []const u8,
    kind: Kind,
    from: ?[]const u8,
    time: Io.Timestamp,
) Allocator.Error!void {
    if (b.index.get(path)) |i| {
        const existing = &b.events.items[i];
        if (b.hold_all) {
            // Debouncing already decided what the window says: the kind
            // seen last, and the rename it came with or none at all.
            const owned_from = if (from) |source| try gpa.dupe(u8, source) else null;
            if (existing.from) |stale| gpa.free(stale);
            existing.from = owned_from;
            existing.kind = kind;
            return;
        }
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
    try b.events.append(gpa, .{
        .id = id,
        .path = owned_path,
        .kind = kind,
        .from = owned_from,
        .time = time,
    });
    errdefer _ = b.events.pop();
    try b.index.put(gpa, owned_path, @intCast(b.events.items.len - 1));
}

/// How much a kind outranks another when two land on one path in one
/// window. The order is documented on `lookout.Kind`: a stronger statement
/// about the path wins, and `overflow` — which says the record is
/// incomplete — wins over every claim that it is complete.
fn rank(kind: Kind) u3 {
    return switch (kind) {
        .attributes => 0,
        .modified => 1,
        // A write that has finished says more about the path than a
        // write in progress, and less than the name appearing or going.
        .closed => 2,
        .created => 3,
        .renamed => 4,
        .removed => 5,
        .overflow => 6,
    };
}

const testing = std.testing;

fn testBatch(options: lookout.Options) Batch {
    return .init(testing.io, options);
}

test "one event per path, strongest kind wins" {
    const gpa = testing.allocator;
    var b = testBatch(.{});
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
    var b = testBatch(.{});
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(7);
    try b.push(gpa, id, "/tmp/a", .created);
    try b.push(gpa, id, "/tmp/a", .removed);
    try testing.expectEqual(Kind.removed, b.events.items[0].kind);

    try b.push(gpa, id, "/tmp/a", .overflow);
    try testing.expectEqual(Kind.overflow, b.events.items[0].kind);
}

test "a finished write outranks the writing, and a creation outranks both" {
    const gpa = testing.allocator;
    var b = testBatch(.{});
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/tmp/a", .modified);
    try b.push(gpa, id, "/tmp/a", .closed);
    // The window says the writing is over rather than that it happened,
    // which is the more useful of the two statements.
    try testing.expectEqual(Kind.closed, b.events.items[0].kind);

    try b.push(gpa, id, "/tmp/a", .created);
    try testing.expectEqual(Kind.created, b.events.items[0].kind);
    try b.push(gpa, id, "/tmp/a", .closed);
    try testing.expectEqual(Kind.created, b.events.items[0].kind);
}

test "reset drops the previous window" {
    const gpa = testing.allocator;
    var b = testBatch(.{});
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created);
    b.reset(gpa);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified);
    try testing.expectEqual(Kind.modified, b.events.items[0].kind);
}

test "a paired rename is one event carrying where it came from" {
    const gpa = testing.allocator;
    var b = testBatch(.{});
    defer b.deinit(gpa);

    try b.pushRename(gpa, @enumFromInt(0), "/tmp/new", "/tmp/old");
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.renamed, b.events.items[0].kind);
    try testing.expectEqualStrings("/tmp/new", b.events.items[0].path);
    try testing.expectEqualStrings("/tmp/old", b.events.items[0].from.?);
}

test "every event carries when it was seen" {
    const gpa = testing.allocator;
    var b = testBatch(.{});
    defer b.deinit(gpa);

    const before: Io.Timestamp = .now(testing.io, .awake);
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created);
    const after: Io.Timestamp = .now(testing.io, .awake);

    const stamped = b.events.items[0].time;
    try testing.expect(stamped.nanoseconds >= before.nanoseconds);
    try testing.expect(stamped.nanoseconds <= after.nanoseconds);
}

test "a settling modification is held back until it is due" {
    const gpa = testing.allocator;
    var b = testBatch(.{ .settle_ms = 50 });
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified);
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);
    try testing.expect(b.nextDueMs().? > 0);

    // Reaching back in time is the same as waiting, and a test that waits
    // on a wall clock is a test that fails on a loaded machine.
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.modified, b.events.items[0].kind);
    try testing.expectEqual(@as(?u32, null), b.nextDueMs());
}

test "a name event settles the question of the contents" {
    const gpa = testing.allocator;
    var b = testBatch(.{ .settle_ms = 50 });
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified);
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .removed);
    try testing.expectEqual(@as(usize, 0), b.held.count());
    try testing.expectEqual(Kind.removed, b.events.items[0].kind);
}

test "debouncing holds every kind and reports the one seen last" {
    const gpa = testing.allocator;
    var b = testBatch(.{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/tmp/a", .created);
    try b.push(gpa, id, "/tmp/a", .modified);
    try b.push(gpa, id, "/tmp/a", .removed);
    try b.push(gpa, id, "/tmp/a", .modified);
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);

    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);

    // One event for the path, and `modified` rather than the `removed`
    // that outranks it: a debounce reports the end state, which is the
    // whole difference from coalescing.
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.modified, b.events.items[0].kind);
}

test "a debounced rename keeps where it came from" {
    const gpa = testing.allocator;
    var b = testBatch(.{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/new", .modified);
    try b.pushRename(gpa, @enumFromInt(0), "/tmp/new", "/tmp/old");
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);

    try testing.expectEqual(Kind.renamed, b.events.items[0].kind);
    try testing.expectEqualStrings("/tmp/old", b.events.items[0].from.?);
}

test "debouncing stamps an event with when the path first changed" {
    const gpa = testing.allocator;
    var b = testBatch(.{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created);
    const first = b.held.values()[0].first_ns;
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified);
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);

    try testing.expectEqual(first, b.events.items[0].time.nanoseconds);
}

test "a push that is held still moves the revision" {
    const gpa = testing.allocator;
    var b = testBatch(.{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    const before = b.revision;
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created);
    try testing.expect(b.revision > before);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);
}

test "discarding a watch takes its events and its held paths with it" {
    const gpa = testing.allocator;
    var b = testBatch(.{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    const kept: WatchId = @enumFromInt(1);
    const dropped: WatchId = @enumFromInt(2);
    try b.push(gpa, kept, "/tmp/a", .created);
    try b.push(gpa, dropped, "/tmp/b", .created);
    try b.push(gpa, kept, "/tmp/c", .created);
    for (b.held.values()) |*entry| entry.last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 3), b.events.items.len);

    b.discard(gpa, dropped);
    try testing.expectEqual(@as(usize, 2), b.events.items.len);
    try testing.expectEqualStrings("/tmp/a", b.events.items[0].path);
    try testing.expectEqualStrings("/tmp/c", b.events.items[1].path);

    // The index has to survive the removal: a later push on a path the
    // batch still holds must merge rather than appear twice.
    try b.push(gpa, kept, "/tmp/c", .removed);
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 2), b.events.items.len);
    try testing.expectEqual(Kind.removed, b.events.items[1].kind);

    // And what is still held for a discarded watch goes too.
    try b.push(gpa, dropped, "/tmp/d", .modified);
    try testing.expectEqual(@as(usize, 1), b.held.count());
    b.discard(gpa, dropped);
    try testing.expectEqual(@as(usize, 0), b.held.count());
}
