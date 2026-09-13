//! The events one `zwatch.Watcher.poll` call has collected so far.
//!
//! Backends push raw, uncoalesced events in as they read them from the
//! operating system. The batch keeps at most one `Event` per absolute path
//! and merges each new kind into the one already recorded, which is what
//! turns a burst of writes on one file into a single `modified`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zwatch = @import("zwatch.zig");
const Event = zwatch.Event;
const Kind = zwatch.Kind;
const WatchId = zwatch.WatchId;

const Batch = @This();

/// The events of the current window, in the order their paths were first
/// touched. Every `path` is owned by this batch.
events: std.ArrayList(Event),
/// Maps an event's path to its index in `events`. Keys are the same
/// allocations as `Event.path`, owned by `events`.
index: std.StringHashMapUnmanaged(u32),

/// A batch that owns nothing.
pub const empty: Batch = .{ .events = .empty, .index = .empty };

/// Releases the events and their paths.
pub fn deinit(b: *Batch, gpa: Allocator) void {
    b.reset(gpa);
    b.events.deinit(gpa);
    b.index.deinit(gpa);
    b.* = undefined;
}

/// Drops every event of the previous window. This is what invalidates the
/// slice the previous `poll` returned.
pub fn reset(b: *Batch, gpa: Allocator) void {
    for (b.events.items) |event| gpa.free(event.path);
    b.events.clearRetainingCapacity();
    b.index.clearRetainingCapacity();
}

/// Records that `kind` happened to `path`, merging with anything already
/// recorded for that path in this window. `path` is copied.
pub fn push(b: *Batch, gpa: Allocator, id: WatchId, path: []const u8, kind: Kind) Allocator.Error!void {
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

test "one event per path, strongest kind wins" {
    const gpa = std.testing.allocator;
    var b: Batch = .empty;
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(0);
    try b.push(gpa, id, "/tmp/a", .modified);
    try b.push(gpa, id, "/tmp/a", .created);
    try b.push(gpa, id, "/tmp/a", .attributes);
    try b.push(gpa, id, "/tmp/b", .modified);

    try std.testing.expectEqual(@as(usize, 2), b.events.items.len);
    try std.testing.expectEqualStrings("/tmp/a", b.events.items[0].path);
    try std.testing.expectEqual(Kind.created, b.events.items[0].kind);
    try std.testing.expectEqual(Kind.modified, b.events.items[1].kind);
}

test "removal outranks creation and overflow outranks everything" {
    const gpa = std.testing.allocator;
    var b: Batch = .empty;
    defer b.deinit(gpa);

    const id: WatchId = @enumFromInt(7);
    try b.push(gpa, id, "/tmp/a", .created);
    try b.push(gpa, id, "/tmp/a", .removed);
    try std.testing.expectEqual(Kind.removed, b.events.items[0].kind);

    try b.push(gpa, id, "/tmp/a", .overflow);
    try std.testing.expectEqual(Kind.overflow, b.events.items[0].kind);
}

test "reset drops the previous window" {
    const gpa = std.testing.allocator;
    var b: Batch = .empty;
    defer b.deinit(gpa);

    try b.push(gpa, @enumFromInt(0), "/tmp/a", .created);
    b.reset(gpa);
    try std.testing.expectEqual(@as(usize, 0), b.events.items.len);
    try b.push(gpa, @enumFromInt(0), "/tmp/a", .modified);
    try std.testing.expectEqual(Kind.modified, b.events.items[0].kind);
}
