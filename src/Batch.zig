//! The events one `lookout.Watcher.poll` call has collected so far, and
//! the paths it is still holding back.
//!
//! Backends push raw, uncoalesced events in as they read them from the
//! operating system. The batch keeps at most one `Event` per watch and
//! absolute path and merges each new kind into the one already recorded,
//! which is what turns a burst of writes on one file into one `modified`.
//!
//! Two options hold a path back rather than recording it at once.
//! `@import("options.zig").Options.settle_ms` holds `modified` until the file has
//! stopped changing; `@import("options.zig").Options.debounce_ms` holds ordinary changes
//! until the path has been quiet, and then reports the kind seen last.
//! Loss notices are recorded at once and outrank ordinary changes in
//! every mode: `overflow` < `unwatched`. See `promote`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const lookout = @import("types.zig");
const path_cmp = @import("path.zig");
const Event = lookout.Event;
const Kind = lookout.Kind;
const Target = lookout.Target;
const WatchId = lookout.WatchId;

const Batch = @This();
const checkpoint_format = @import("checkpoint_format.zig");

/// Read for the timestamps every event carries and the ones the holding
/// rules compare.
io: Io,
/// How long a held path must be quiet before it is reported, in
/// nanoseconds. Zero means nothing is ever held.
hold_ns: i96,
/// Whether every ordinary kind is held (`@import("options.zig").Options.debounce_ms`) or only
/// `modified` (`@import("options.zig").Options.settle_ms`).
hold_all: bool,
/// The events of the current window, in the order their paths were first
/// touched. Every `path` and every `from` is owned by this batch.
events: std.ArrayList(Event),
/// Maps an event's watch and path to its index in `events`. Path keys are
/// the same allocations as `Event.path`, owned by `events`, and are
/// compared with lookout's platform folding rules: two supported
/// spellings of one path under one watch are one event, not two.
index: std.HashMapUnmanaged(EventKey, u32, EventKeyContext, std.hash_map.default_max_load_percentage),
/// Paths that have changed but have not been quiet long enough to be
/// reported. Survives `reset`, because a file still being written is not
/// news that expires with the poll that noticed it. Keys are owned here,
/// and so is each `Held.from`.
held: std.ArrayHashMapUnmanaged(EventKey, Held, EventKeyArrayContext, true),
/// The most events one window may hold, or zero for no ceiling. See
/// `@import("options.zig").Options.max_events`.
limit: usize,
/// Changes queued during add: registration troubles and restored checkpoint
/// changes. They survive reset and move into the next delivery in flush.
deferred: std.ArrayList(Deferred),
/// The watches whose events the ceiling has turned away, which
/// `lookout.Watcher.poll` answers with `lookout.Kind.overflow` against
/// their roots -- the batch knows it had to stop, and only the watcher
/// knows what to say so against.
dropped: std.AutoArrayHashMapUnmanaged(WatchId, void),
/// Counts every push, whether it produced an event or was held back.
///
/// A backend waits until the batch has changed, not until it has grown:
/// under `@import("options.zig").Options.debounce_ms` a push produces no event for a
/// while, and a backend watching `events.items.len` would sleep through
/// its own deadline and, with no timeout at all, forever.
revision: u64,

/// A change produced before the next poll can take ownership of it.
const Deferred = struct {
    id: WatchId,
    /// Absolute path, owned here.
    path: []u8,
    target: Target,
    kind: Kind,
    from: ?[]u8,
};

const Held = struct {
    id: WatchId,
    /// What happened. Under `debounce_ms` this is the kind seen last.
    kind: Kind,
    /// Where a paired rename came from, owned here.
    from: ?[]u8,
    /// What the path is. Becomes `Event.target`.
    target: Target,
    /// When this path first changed in this window. Becomes `Event.time`.
    first_ns: i96,
    /// When it last changed, which is what the quiet window is measured
    /// from.
    last_ns: i96,
    /// How large the file was when it was last looked at, or `null` for
    /// a path `settle_ms` does not measure this way. See `promote`.
    size: ?u64,
};

const EventKey = struct {
    id: WatchId,
    path: []const u8,
};

const EventKeyContext = struct {
    pub fn hash(_: EventKeyContext, key: EventKey) u64 {
        return path_cmp.hash(key.path) ^ (@as(u64, @intFromEnum(key.id)) *% 0x9e3779b97f4a7c15);
    }

    pub fn eql(_: EventKeyContext, a: EventKey, b: EventKey) bool {
        return a.id == b.id and path_cmp.eql(a.path, b.path);
    }
};

const EventKeyArrayContext = struct {
    pub fn hash(_: EventKeyArrayContext, key: EventKey) u32 {
        return @truncate(EventKeyContext.hash(.{}, key));
    }

    pub fn eql(_: EventKeyArrayContext, a: EventKey, b: EventKey, _: usize) bool {
        return EventKeyContext.eql(.{}, a, b);
    }
};

/// A batch that owns nothing.
///
/// `debounce_ms` supersedes `settle_ms`: it already holds every ordinary kind
/// until the path is quiet, which is the stronger of the two rules.
pub fn init(io: Io, options: @import("options.zig").Options) Batch {
    const debouncing = options.debounce_ms > 0;
    const hold_ms: u32 = if (debouncing) options.debounce_ms else options.settle_ms;
    return .{
        .io = io,
        .hold_ns = @as(i96, hold_ms) * std.time.ns_per_ms,
        .hold_all = debouncing,
        .events = .empty,
        .index = .empty,
        .held = .empty,
        .limit = options.max_events,
        .deferred = .empty,
        .dropped = .empty,
        .revision = 0,
    };
}

/// Releases the events, their paths, and anything still held.
pub fn deinit(b: *Batch, gpa: Allocator) void {
    b.reset(gpa);
    b.events.deinit(gpa);
    b.index.deinit(gpa);
    for (b.held.keys(), b.held.values()) |key, entry| {
        gpa.free(key.path);
        if (entry.from) |from| gpa.free(from);
    }
    b.held.deinit(gpa);
    for (b.deferred.items) |t| {
        gpa.free(t.path);
        if (t.from) |from| gpa.free(from);
    }
    b.deferred.deinit(gpa);
    b.dropped.deinit(gpa);
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
pub fn push(
    b: *Batch,
    gpa: Allocator,
    id: WatchId,
    subject: []const u8,
    kind: Kind,
    target: Target,
) Allocator.Error!void {
    return b.pushDetail(gpa, id, subject, kind, null, target);
}

/// Records that `from` is now `path`: one event rather than a removal and
/// a creation, for the backends whose kernel pairs the two halves. Both
/// paths are copied.
pub fn pushRename(
    b: *Batch,
    gpa: Allocator,
    id: WatchId,
    subject: []const u8,
    from: []const u8,
    target: Target,
) Allocator.Error!void {
    return b.pushDetail(gpa, id, subject, .renamed, from, target);
}

pub fn pushDetail(
    b: *Batch,
    gpa: Allocator,
    id: WatchId,
    subject: []const u8,
    kind: Kind,
    from: ?[]const u8,
    target: Target,
) Allocator.Error!void {
    const source = if (kind == .renamed and from != null and !path_cmp.eql(subject, from.?)) from else null;
    const replaced_hold: usize = if (source) |path| @intFromBool(b.held.contains(.{ .id = id, .path = path })) else 0;
    try b.pushAtPath(gpa, id, subject, kind, from, target, replaced_hold);
    // Only a successfully recorded destination ends the source's hold.
    // This applies to native renames and restored deferred changes alike.
    if (source) |path| b.release(gpa, id, path);
}

fn pushAtPath(b: *Batch, gpa: Allocator, id: WatchId, subject: []const u8, kind: Kind, from: ?[]const u8, target: Target, replaced_hold: usize) Allocator.Error!void {
    b.revision += 1;
    const now = Io.Timestamp.now(b.io, .awake);

    // A loss notice ends the hold for this path. Later changes in the
    // same delivery merge into that notice rather than starting a new
    // hold that could outlive it and imply a complete answer next time.
    const recorded_loss = if (b.index.get(.{ .id = id, .path = subject })) |i|
        isLoss(b.events.items[i].kind)
    else
        false;
    if (!isLoss(kind) and !recorded_loss and b.hold_ns > 0 and (b.hold_all or kind == .modified)) {
        if (b.held.getPtr(.{ .id = id, .path = subject })) |entry| {
            entry.last_ns = now.nanoseconds;
            if (kind == .modified) entry.size = b.sizeOf(subject);
            entry.target = target;
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
        if (b.limit != 0 and b.events.items.len + b.held.count() - replaced_hold >= b.limit) {
            try b.dropped.put(gpa, id, {});
            return;
        }
        const owned_path = try gpa.dupe(u8, subject);
        errdefer gpa.free(owned_path);
        const owned_from = if (from) |source| try gpa.dupe(u8, source) else null;
        errdefer if (owned_from) |f| gpa.free(f);
        try b.held.put(gpa, .{ .id = id, .path = owned_path }, .{
            .id = id,
            .kind = kind,
            .from = owned_from,
            .target = target,
            .first_ns = now.nanoseconds,
            .last_ns = now.nanoseconds,
            .size = if (kind == .modified) b.sizeOf(subject) else null,
        });
        return;
    }
    // Anything else that happens to a path ends the question of whether
    // its contents have stopped changing: the name has been created,
    // removed or moved since.
    try b.record(gpa, id, subject, kind, from, target, now);
    b.release(gpa, id, subject);
}

/// How large a file is now, or `null` when it cannot be asked. Read only
/// for a path `settle_ms` is holding, so a watcher without that option
/// set never makes this call.
fn sizeOf(b: *const Batch, subject: []const u8) ?u64 {
    const stat = Io.Dir.cwd().statFile(b.io, subject, .{ .follow_symlinks = false }) catch
        return null;
    return stat.size;
}

/// Drops every event, and everything held back, belonging to `id`.
///
/// A watch whose path does not exist yet is registered on an ancestor
/// while it waits, and the ancestor's own comings and goings are not what
/// the caller asked about. This is how they are kept out of the batch
/// without the backends having to know why.
pub fn discard(b: *Batch, gpa: Allocator, id: WatchId) void {
    b.discardFuture(gpa, id);
    b.discardEvents(gpa, id);
}

/// Drops held-back state belonging to `id` without touching events already
/// returned to the caller.
pub fn discardFuture(b: *Batch, gpa: Allocator, id: WatchId) void {
    _ = b.dropped.swapRemove(id);
    var t: usize = 0;
    while (t < b.deferred.items.len) {
        if (b.deferred.items[t].id != id) {
            t += 1;
            continue;
        }
        const removed = b.deferred.orderedRemove(t);
        gpa.free(removed.path);
        if (removed.from) |from| gpa.free(from);
    }
    var h: usize = 0;
    while (h < b.held.count()) {
        if (b.held.values()[h].id != id) {
            h += 1;
            continue;
        }
        const key = b.held.keys()[h];
        const entry = b.held.values()[h];
        b.held.swapRemoveAt(h);
        gpa.free(key.path);
        if (entry.from) |from| gpa.free(from);
    }
}

/// Applies a replacement filter to changes already collected for one
/// watch. A slice already handed to the caller stays valid; held and
/// unreturned changes are narrowed before the next delivery.
pub fn refilter(
    b: *Batch,
    gpa: Allocator,
    id: WatchId,
    root: []const u8,
    filter: lookout.Filter,
    handed_out: bool,
) void {
    var t: usize = 0;
    while (t < b.deferred.items.len) {
        const pending = b.deferred.items[t];
        if (pending.id == id and filter.excludes(root, pending.path)) {
            const removed = b.deferred.orderedRemove(t);
            gpa.free(removed.path);
            if (removed.from) |from| gpa.free(from);
        } else {
            if (pending.id == id and pending.kind == .renamed and pending.from != null and filter.excludes(root, pending.from.?)) {
                gpa.free(pending.from.?);
                b.deferred.items[t].from = null;
                b.deferred.items[t].kind = .created;
            }
            t += 1;
        }
    }
    var h: usize = 0;
    while (h < b.held.count()) {
        const key = b.held.keys()[h];
        const entry = b.held.values()[h];
        if (key.id != id) {
            h += 1;
        } else if (filter.excludes(root, key.path)) {
            b.held.swapRemoveAt(h);
            gpa.free(key.path);
            if (entry.from) |from| gpa.free(from);
        } else {
            if (entry.kind == .renamed and entry.from != null and
                filter.excludes(root, entry.from.?))
            {
                gpa.free(entry.from.?);
                b.held.values()[h].from = null;
                b.held.values()[h].kind = .created;
            }
            h += 1;
        }
    }
    if (handed_out) return;
    var removed = false;
    var i: usize = 0;
    while (i < b.events.items.len) {
        const event = &b.events.items[i];
        if (event.id != id) {
            i += 1;
        } else if (filter.excludes(root, event.path)) {
            const gone = b.events.orderedRemove(i);
            gpa.free(gone.path);
            if (gone.from) |from| gpa.free(from);
            removed = true;
        } else {
            if (event.kind == .renamed and event.from != null and
                filter.excludes(root, event.from.?))
            {
                gpa.free(event.from.?);
                event.from = null;
                event.kind = .created;
            }
            i += 1;
        }
    }
    if (removed) b.rebuildIndex();
}

fn discardEvents(b: *Batch, gpa: Allocator, id: WatchId) void {
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
        b.rebuildIndex();
    }
}

fn rebuildIndex(b: *Batch) void {
    b.index.clearRetainingCapacity();
    for (b.events.items, 0..) |event, at| {
        b.index.putAssumeCapacity(.{ .id = event.id, .path = event.path }, @intCast(at));
    }
}

/// Records that `subject` could not be watched, for the next `poll` to
/// report as `lookout.Kind.unwatched`. The path is copied.
pub fn trouble(
    b: *Batch,
    gpa: Allocator,
    id: WatchId,
    subject: []const u8,
    target: Target,
) Allocator.Error!void {
    try b.deferChange(gpa, id, subject, .unwatched, null, target);
}

/// Queues a change produced while add runs. It cannot join a slice the
/// previous poll already handed out; flush transfers it after poll resets.
pub fn deferChange(b: *Batch, gpa: Allocator, id: WatchId, subject: []const u8, kind: Kind, from: ?[]const u8, target: Target) Allocator.Error!void {
    const owned = try gpa.dupe(u8, subject);
    errdefer gpa.free(owned);
    const owned_from = if (from) |source| try gpa.dupe(u8, source) else null;
    errdefer if (owned_from) |source| gpa.free(source);
    try b.deferred.append(gpa, .{ .id = id, .path = owned, .target = target, .kind = kind, .from = owned_from });
    b.revision += 1;
}

/// Transfers deferred changes after poll has reset the previous delivery.
/// A failed transfer keeps the source for retry.
pub fn flush(b: *Batch, gpa: Allocator) Allocator.Error!void {
    while (b.deferred.items.len != 0) {
        const t = b.deferred.items[0];
        try b.pushDetail(gpa, t.id, t.path, t.kind, t.from, t.target);
        _ = b.deferred.orderedRemove(0);
        gpa.free(t.path);
        if (t.from) |from| gpa.free(from);
    }
}

/// Borrows paths into a newly allocated list; Checkpoint copies them before
/// the list is released. Batch alone decides what has not been handed out.
pub fn capture(b: *const Batch, gpa: Allocator, id: WatchId, include_ready: bool) Allocator.Error![]checkpoint_format.Change {
    var changes: std.ArrayList(checkpoint_format.Change) = .empty;
    errdefer changes.deinit(gpa);
    if (include_ready) for (b.events.items) |event| {
        if (event.id == id) try changes.append(gpa, .{ .path = event.path, .kind = event.kind, .from = event.from, .target = event.target });
    };
    for (b.held.keys(), b.held.values()) |key, held| {
        if (key.id == id) try changes.append(gpa, .{ .path = key.path, .kind = held.kind, .from = held.from, .target = held.target });
    }
    for (b.deferred.items) |change| {
        if (change.id == id) try changes.append(gpa, .{ .path = change.path, .kind = change.kind, .from = change.from, .target = change.target });
    }
    return changes.toOwnedSlice(gpa);
}

/// Moves into the batch every path that has now been quiet for
/// `hold_ns` and is not still growing. A no-op when nothing is held back.
///
/// The quiet window on its own is a guess about a writer nobody can see,
/// and a kernel that coalesces several writes into one notification can
/// leave the window closing over a file that is still being written --
/// which is the one thing `@import("options.zig").Options.settle_ms` exists to prevent.
/// So the file is measured as well as timed: one `stat` at the moment
/// the window closes, and a file larger than it was when the window
/// started is still being written, so the window starts again.
///
/// What no measurement can see is a writer that has stopped for longer
/// than the window and will start again. `lookout.Kind.closed` is the
/// only answer to that one, and only one backend is told it.
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
        if (entry.size) |before| {
            const subject = b.held.keys()[i].path;
            if (b.sizeOf(subject)) |after| {
                if (after != before) {
                    b.held.values()[i].size = after;
                    b.held.values()[i].last_ns = now;
                    i += 1;
                    continue;
                }
            }
        }
        const subject = b.held.keys()[i].path;
        // The event is stamped with when the path first changed, not with
        // when the window closed: the caller wants to know when it
        // happened, not when lookout stopped waiting.
        try b.record(
            gpa,
            entry.id,
            subject,
            entry.kind,
            entry.from,
            entry.target,
            .{ .nanoseconds = entry.first_ns },
        );
        b.held.swapRemoveAt(i);
        gpa.free(subject);
        if (entry.from) |from| gpa.free(from);
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
fn release(b: *Batch, gpa: Allocator, id: WatchId, subject: []const u8) void {
    const entry = b.held.fetchSwapRemove(.{ .id = id, .path = subject }) orelse return;
    gpa.free(entry.key.path);
    if (entry.value.from) |from| gpa.free(from);
}

/// Puts one change into the batch, merging it with whatever this window
/// already holds for the same path.
fn record(
    b: *Batch,
    gpa: Allocator,
    id: WatchId,
    subject: []const u8,
    kind: Kind,
    from: ?[]const u8,
    target: Target,
    time: Io.Timestamp,
) Allocator.Error!void {
    if (b.index.get(.{ .id = id, .path = subject })) |i| {
        const existing = &b.events.items[i];
        if (existing.target == .unknown) existing.target = target;
        if (b.hold_all and !isLoss(kind) and !isLoss(existing.kind)) {
            // Debouncing already decided what the window says: the kind
            // seen last, and the rename it came with or none at all.
            const owned_from = if (from) |source| try gpa.dupe(u8, source) else null;
            if (existing.from) |stale| gpa.free(stale);
            existing.from = owned_from;
            existing.kind = kind;
            return;
        }
        if (rank(kind) > rank(existing.kind)) existing.kind = kind;
        if (existing.kind != .renamed) {
            if (existing.from) |stale| gpa.free(stale);
            existing.from = null;
            return;
        }
        if (from) |source| {
            if (existing.from == null) {
                existing.from = try gpa.dupe(u8, source);
            }
        }
        return;
    }

    // Past the ceiling the batch stops holding names. The two kinds that
    // say the record is incomplete are exactly what a caller needs then,
    // so they are never the ones turned away.
    if (b.limit != 0 and b.events.items.len >= b.limit and !isLoss(kind)) {
        try b.dropped.put(gpa, id, {});
        return;
    }

    const owned_path = try gpa.dupe(u8, subject);
    errdefer gpa.free(owned_path);
    const owned_from = if (from) |source| try gpa.dupe(u8, source) else null;
    errdefer if (owned_from) |f| gpa.free(f);
    try b.events.append(gpa, .{
        .id = id,
        .path = owned_path,
        .kind = kind,
        .from = owned_from,
        .time = time,
        .target = target,
    });
    errdefer _ = b.events.pop();
    try b.index.put(gpa, .{ .id = id, .path = owned_path }, @intCast(b.events.items.len - 1));
}

fn isLoss(kind: Kind) bool {
    return kind == .overflow or kind == .unwatched;
}

/// How much a kind outranks another when two land on one path in one
/// window. The order is documented on `lookout.Kind`: a stronger statement
/// about the path wins, and loss notices win over every ordinary change.
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
        // "Look again" is beaten by "looking again is the only way you
        // will ever hear about this path".
        .unwatched => 7,
    };
}

const testing = std.testing;

test "one event per path, strongest kind wins" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{});
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/tmp/a", .modified, .file);
    try b.push(gpa, id, "/tmp/a", .created, .file);
    try b.push(gpa, id, "/tmp/a", .attributes, .file);
    try b.push(gpa, id, "/tmp/b", .modified, .file);

    try testing.expectEqual(@as(usize, 2), b.events.items.len);
    try testing.expectEqualStrings("/tmp/a", b.events.items[0].path);
    try testing.expectEqual(Kind.created, b.events.items[0].kind);
    try testing.expectEqual(Kind.modified, b.events.items[1].kind);
}

test "removal outranks creation and overflow outranks everything" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{});
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(7);
    try b.push(gpa, id, "/tmp/a", .created, .file);
    try b.push(gpa, id, "/tmp/a", .removed, .file);
    try testing.expectEqual(Kind.removed, b.events.items[0].kind);

    try b.push(gpa, id, "/tmp/a", .overflow, .file);
    try testing.expectEqual(Kind.overflow, b.events.items[0].kind);
}

test "a finished write outranks the writing, and a creation outranks both" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{});
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/tmp/a", .modified, .file);
    try b.push(gpa, id, "/tmp/a", .closed, .file);
    // The window says the writing is over rather than that it happened,
    // which is the more useful of the two statements.
    try testing.expectEqual(Kind.closed, b.events.items[0].kind);

    try b.push(gpa, id, "/tmp/a", .created, .file);
    try testing.expectEqual(Kind.created, b.events.items[0].kind);
    try b.push(gpa, id, "/tmp/a", .closed, .file);
    try testing.expectEqual(Kind.created, b.events.items[0].kind);
}

test "reset drops the previous window" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{});
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created, .file);
    b.reset(gpa);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified, .file);
    try testing.expectEqual(Kind.modified, b.events.items[0].kind);
}

test "a paired rename is one event carrying where it came from" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{});
    defer b.deinit(gpa);

    try b.pushRename(gpa, @enumFromInt(0), "/tmp/new", "/tmp/old", .file);
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.renamed, b.events.items[0].kind);
    try testing.expectEqualStrings("/tmp/new", b.events.items[0].path);
    try testing.expectEqualStrings("/tmp/old", b.events.items[0].from.?);
}

test "a stronger non-rename clears an earlier rename source" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{});
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(0);
    try b.pushRename(gpa, id, "/tmp/new", "/tmp/old", .file);
    try b.push(gpa, id, "/tmp/new", .removed, .file);

    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.removed, b.events.items[0].kind);
    try testing.expectEqual(@as(?[]const u8, null), b.events.items[0].from);
}

test "every event carries when it was seen" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{});
    defer b.deinit(gpa);

    const before: Io.Timestamp = .now(b.io, .awake);
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created, .file);
    const after: Io.Timestamp = .now(b.io, .awake);

    const stamped = b.events.items[0].time;
    try testing.expect(stamped.nanoseconds >= before.nanoseconds);
    try testing.expect(stamped.nanoseconds <= after.nanoseconds);
}

test "a settling modification is held back until it is due" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .settle_ms = 50 });
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified, .file);
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
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .settle_ms = 50 });
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified, .file);
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .removed, .file);
    try testing.expectEqual(@as(usize, 0), b.held.count());
    try testing.expectEqual(Kind.removed, b.events.items[0].kind);
}

test "loss notices bypass holding and displace held changes" {
    const gpa = testing.allocator;
    const id: WatchId = @enumFromInt(0);
    for ([_]@import("options.zig").Options{
        .{ .debounce_ms = 50, .max_events = 1 },
        .{ .settle_ms = 50, .max_events = 1 },
    }) |options| {
        for ([_]Kind{ .overflow, .unwatched }) |kind| {
            var vtable: Io.VTable = undefined;
            var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), options);
            defer b.deinit(gpa);
            try b.push(gpa, id, "/watch", .modified, .file);
            try b.push(gpa, id, "/watch", kind, .file);
            try testing.expectEqual(@as(usize, 1), b.events.items.len);
            try testing.expectEqual(kind, b.events.items[0].kind);
            try testing.expectEqual(@as(usize, 0), b.held.count());
            try testing.expectEqual(@as(?u32, null), b.nextDueMs());

            // A later change in this delivery cannot escape into the
            // next poll as a claim that the answer was complete.
            try b.pushRename(gpa, id, "/watch", "/old", .file);
            try b.push(gpa, id, "/watch", .modified, .file);
            try testing.expectEqual(kind, b.events.items[0].kind);
            try testing.expectEqual(@as(?[]const u8, null), b.events.items[0].from);
            try testing.expectEqual(@as(usize, 0), b.held.count());
        }
    }
}

test "loss notices keep their precedence in a debounced delivery" {
    const gpa = testing.allocator;
    const id: WatchId = @enumFromInt(0);
    const kinds = std.enums.values(Kind);
    for (kinds) |first| {
        for (kinds) |last| {
            if (first != .overflow and first != .unwatched and
                last != .overflow and last != .unwatched) continue;
            var vtable: Io.VTable = undefined;
            var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .debounce_ms = 50 });
            defer b.deinit(gpa);
            const now: Io.Timestamp = .now(b.io, .awake);
            // These are records ready for delivery, including promoted
            // changes and allocation recovery, which share this merge.
            try b.record(gpa, id, "/watch", first, if (first == .renamed) "/old" else null, .file, now);
            try b.record(gpa, id, "/watch", last, if (last == .renamed) "/old" else null, .file, now);
            const expected: Kind = if (first == .unwatched or last == .unwatched) .unwatched else .overflow;
            try testing.expectEqual(expected, b.events.items[0].kind);
            try testing.expectEqual(@as(?[]const u8, null), b.events.items[0].from);
        }
    }
}

test "debouncing holds ordinary kinds and reports the one seen last" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/tmp/a", .created, .file);
    try b.push(gpa, id, "/tmp/a", .modified, .file);
    try b.push(gpa, id, "/tmp/a", .removed, .file);
    try b.push(gpa, id, "/tmp/a", .modified, .file);
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
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/new", .modified, .file);
    try b.pushRename(gpa, @enumFromInt(0), "/tmp/new", "/tmp/old", .file);
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);

    try testing.expectEqual(Kind.renamed, b.events.items[0].kind);
    try testing.expectEqualStrings("/tmp/old", b.events.items[0].from.?);
}

test "debouncing stamps an event with when the path first changed" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created, .file);
    const first = b.held.values()[0].first_ns;
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified, .file);
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);

    try testing.expectEqual(first, b.events.items[0].time.nanoseconds);
}

test "a push that is held still moves the revision" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    const before = b.revision;
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created, .file);
    try testing.expect(b.revision > before);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);
}

test "discarding a watch takes its events and its held paths with it" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .debounce_ms = 50 });
    defer b.deinit(gpa);

    const kept: WatchId = @enumFromInt(1);
    const dropped: WatchId = @enumFromInt(2);
    try b.push(gpa, kept, "/tmp/a", .created, .file);
    try b.push(gpa, dropped, "/tmp/b", .created, .file);
    try b.push(gpa, kept, "/tmp/c", .created, .file);
    for (b.held.values()) |*entry| entry.last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 3), b.events.items.len);

    b.discard(gpa, dropped);
    try testing.expectEqual(@as(usize, 2), b.events.items.len);
    try testing.expectEqualStrings("/tmp/a", b.events.items[0].path);
    try testing.expectEqualStrings("/tmp/c", b.events.items[1].path);

    // The index has to survive the removal: a later push on a path the
    // batch still holds must merge rather than appear twice.
    try b.push(gpa, kept, "/tmp/c", .removed, .file);
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 2), b.events.items.len);
    try testing.expectEqual(Kind.removed, b.events.items[1].kind);

    // And what is still held for a discarded watch goes too.
    try b.push(gpa, dropped, "/tmp/d", .modified, .file);
    try testing.expectEqual(@as(usize, 1), b.held.count());
    b.discard(gpa, dropped);
    try testing.expectEqual(@as(usize, 0), b.held.count());
}

test "a held modification that is still growing is not reported yet" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = "one" });
    const target = try tmp.dir.realPathFileAlloc(io, "big.bin", gpa);
    defer gpa.free(target);

    var vtable: Io.VTable = undefined;
    var b: Batch = .init(@import("test_clock.zig").frozen(&vtable, io), .{ .settle_ms = 50 });
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), target, .modified, .file);
    try testing.expectEqual(@as(usize, 1), b.held.count());

    // The window closes, and the file is bigger than it was when it
    // opened: the writing is not over, whatever the clock says.
    tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = "one and two" }) catch unreachable;
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);
    try testing.expectEqual(@as(usize, 1), b.held.count());

    // The window closes again with the file the size it was: now it is.
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.modified, b.events.items[0].kind);
}

test "a path that cannot be measured is still reported when it goes quiet" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b: Batch = .init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .settle_ms = 50 });
    defer b.deinit(gpa);

    // Nothing is at this path, so there is no size to compare and the
    // quiet window is the whole of the answer.
    try b.push(gpa, @enumFromInt(0), "/tmp/lookout-no-such-file", .modified, .file);
    b.held.values()[0].last_ns -= 100 * std.time.ns_per_ms;
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
}

test "the ceiling turns events away and says which watch lost them" {
    const gpa = testing.allocator;
    var b: Batch = .init(testing.io, .{ .max_events = 2 });
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(3);
    try b.push(gpa, id, "/tmp/a", .created, .file);
    try b.push(gpa, id, "/tmp/b", .created, .file);
    try b.push(gpa, id, "/tmp/c", .created, .file);
    try testing.expectEqual(@as(usize, 2), b.events.items.len);
    try testing.expectEqual(@as(usize, 1), b.dropped.count());
    try testing.expectEqual(id, b.dropped.keys()[0]);

    // A path the batch already holds still merges: the ceiling is on
    // how many paths are remembered, not on how much happens to them.
    try b.push(gpa, id, "/tmp/a", .removed, .file);
    try testing.expectEqual(Kind.removed, b.events.items[0].kind);

    // And the two kinds that say the record is incomplete are never the
    // ones turned away, because they are the answer to the ceiling.
    try b.push(gpa, id, "/tmp/root", .overflow, .directory);
    try testing.expectEqual(@as(usize, 3), b.events.items.len);
}

test "the ceiling includes paths held for debouncing" {
    const gpa = testing.allocator;
    var b: Batch = .init(testing.io, .{ .max_events = 2, .debounce_ms = 50 });
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(3);
    try b.push(gpa, id, "/tmp/a", .created, .file);
    try b.push(gpa, id, "/tmp/b", .created, .file);
    try b.push(gpa, id, "/tmp/c", .created, .file);

    try testing.expectEqual(@as(usize, 2), b.held.count());
    try testing.expectEqual(@as(usize, 1), b.dropped.count());
    try testing.expectEqual(id, b.dropped.keys()[0]);
}

test "no ceiling means no ceiling" {
    const gpa = testing.allocator;
    var b: Batch = .init(testing.io, .{ .max_events = 0 });
    defer b.deinit(gpa);
    for (0..64) |i| {
        var name: [32]u8 = undefined;
        try b.push(
            gpa,
            @enumFromInt(0),
            std.fmt.bufPrint(&name, "/tmp/f{d}", .{i}) catch unreachable,
            .created,
            .file,
        );
    }
    try testing.expectEqual(@as(usize, 64), b.events.items.len);
    try testing.expectEqual(@as(usize, 0), b.dropped.count());
}

test "an event says whether the path was a file or a directory" {
    const gpa = testing.allocator;
    var b: Batch = .init(testing.io, .{});
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/d", .created, .directory);
    try testing.expectEqual(lookout.Target.directory, b.events.items[0].target);

    // A backend that could not say does not overwrite one that could.
    try b.push(gpa, @enumFromInt(0), "/tmp/d", .modified, .unknown);
    try testing.expectEqual(lookout.Target.directory, b.events.items[0].target);

    // And one that could fills in for one that could not.
    try b.push(gpa, @enumFromInt(0), "/tmp/e", .removed, .unknown);
    try testing.expectEqual(lookout.Target.unknown, b.events.items[1].target);
    try b.push(gpa, @enumFromInt(0), "/tmp/e", .removed, .file);
    try testing.expectEqual(lookout.Target.file, b.events.items[1].target);
}

test "two spellings of one path are one event" {
    const gpa = testing.allocator;
    var b: Batch = .init(testing.io, .{});
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/Notes.txt", .modified, .file);
    try b.push(gpa, @enumFromInt(0), "/tmp/notes.txt", .removed, .file);

    const merged: usize = if (path_cmp.folds_case) 1 else 2;
    try testing.expectEqual(merged, b.events.items.len);
}

test "a failed batch flush leaves trouble queued for the retry" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{});
    defer b.deinit(gpa);
    try b.trouble(gpa, @enumFromInt(0), root, .directory);
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, b.flush(failing.allocator()));
    try testing.expectEqual(@as(usize, 1), b.deferred.items.len);
    try b.flush(gpa);
    try testing.expectEqual(@as(usize, 0), b.deferred.items.len);
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.unwatched, b.events.items[0].kind);
    try testing.expectEqualStrings(root, b.events.items[0].path);
}

test "a failed batch promotion leaves the rename held for the retry" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .debounce_ms = 1 });
    defer b.deinit(gpa);
    try b.pushRename(gpa, @enumFromInt(0), root, "before", .directory);
    b.held.values()[0].last_ns -= std.time.ns_per_s;
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, b.promote(failing.allocator()));
    try testing.expectEqual(@as(usize, 1), b.held.count());
    try b.promote(gpa);
    try testing.expectEqual(@as(usize, 0), b.held.count());
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.renamed, b.events.items[0].kind);
    try testing.expectEqualStrings(root, b.events.items[0].path);
    try testing.expectEqualStrings("before", b.events.items[0].from.?);
}

test "a failed batch replacement leaves the settling event held" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .settle_ms = 1 });
    defer b.deinit(gpa);
    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, root, .modified, .directory);
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, b.push(failing.allocator(), id, root, .created, .directory));
    try testing.expectEqual(@as(usize, 1), b.held.count());
    try b.push(gpa, id, root, .created, .directory);
    try testing.expectEqual(@as(usize, 0), b.held.count());
    try testing.expectEqual(Kind.created, b.events.items[0].kind);
}

test "a paired rename ends the source path's settling hold" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .settle_ms = 50 });
    defer b.deinit(gpa);
    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/watch/old", .modified, .file);
    try b.pushRename(gpa, id, "/watch/new", "/watch/old", .file);
    try testing.expectEqual(@as(usize, 0), b.held.count());
    try testing.expectEqual(@as(usize, 1), b.events.items.len);
    try testing.expectEqual(Kind.renamed, b.events.items[0].kind);
    try testing.expectEqualStrings("/watch/old", b.events.items[0].from.?);
}

test "a debounced rename replaces its source within the same event ceiling" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .debounce_ms = 50, .max_events = 1 });
    defer b.deinit(gpa);
    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/watch/old", .modified, .file);
    try b.deferChange(gpa, id, "/watch/new", .renamed, "/watch/old", .file);
    try b.flush(gpa);
    try testing.expectEqual(@as(usize, 0), b.dropped.count());
    try testing.expectEqual(@as(usize, 1), b.held.count());
    try testing.expectEqualStrings("/watch/new", b.held.keys()[0].path);
    try testing.expectEqualStrings("/watch/old", b.held.values()[0].from.?);
}

test "a failed rename leaves its source hold available for retry" {
    const gpa = testing.allocator;
    var vtable: Io.VTable = undefined;
    var b = Batch.init(@import("test_clock.zig").frozen(&vtable, testing.io), .{ .settle_ms = 50 });
    defer b.deinit(gpa);
    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/watch/old", .modified, .file);
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, b.pushRename(failing.allocator(), id, "/watch/new", "/watch/old", .file));
    try testing.expectEqual(@as(usize, 1), b.held.count());
    try testing.expectEqualStrings("/watch/old", b.held.keys()[0].path);
    try testing.expectEqual(@as(usize, 0), b.events.items.len);
    try b.pushRename(gpa, id, "/watch/new", "/watch/old", .file);
    try testing.expectEqual(@as(usize, 0), b.held.count());
}
