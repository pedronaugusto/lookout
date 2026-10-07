//! Shared path history. A checkpoint leases a revision, not a copy of the tree.
//! Tombstones stay until no leased revision can see them; ordinary removals
//! need no allocation. Tokens flatten the revision to the existing wire format.
//!
//! The watcher's thread publishes and removes; a checkpoint may be read and
//! released on any other. The lock is held for a pointer update or one step
//! of an iterator and never across an allocation, a free or a caller's
//! writer: a node a live lease can see is never freed, so an iterator rests
//! on one between steps without holding anything. Tombstones are freed only
//! by the watcher's thread, in `publish` and `remove`, so the watcher's
//! allocator is not used from a thread that merely drops a checkpoint while
//! the watcher runs.
const std = @import("std");
const path = @import("../path.zig");
const WatchId = @import("../types.zig").WatchId;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const History = @This();
const SpinLock = @import("../SpinLock.zig");

gpa: Allocator,
lock: SpinLock = .{},
/// Set when the oldest lease is released: tombstones it alone could see
/// can go, on the watcher's thread's next `publish` or `remove`.
compact_due: bool = false,
refs: usize = 1,
revision: u64 = 0,
first: ?*Node = null,
last: ?*Node = null,
leases: ?*Lease = null,
tombstones: usize = 0,

pub const Node = struct {
    path: []const u8,
    id: WatchId,
    born: u64 = 0,
    removed: u64 = 0,
    prev: ?*Node = null,
    next: ?*Node = null,
};

pub fn init(gpa: Allocator) Allocator.Error!*History {
    const h = try gpa.create(History);
    h.* = .{ .gpa = gpa };
    return h;
}

pub fn prepare(h: *History, id: WatchId, name: []const u8) Allocator.Error!*Node {
    const owned = try h.gpa.dupe(u8, name);
    errdefer h.gpa.free(owned);
    return h.prepareOwned(id, owned);
}

/// Takes the path only on success. Preparing a rename does not publish it.
pub fn prepareOwned(h: *History, id: WatchId, owned: []const u8) Allocator.Error!*Node {
    const node = try h.gpa.create(Node);
    node.* = .{ .path = owned, .id = id };
    return node;
}

pub fn discard(h: *History, node: *Node) void {
    h.gpa.free(node.path);
    h.gpa.destroy(node);
}

pub fn publish(h: *History, node: *Node) void {
    // A prepared node is published once, and not linked before.
    assert(node.born == 0);
    assert(node.removed == 0);
    assert(node.prev == null);
    assert(node.next == null);
    h.lock.acquire();
    h.revision += 1;
    node.born = h.revision;
    // The list is in order of birth, which is what lets an iterator stop
    // at the first node born after its lease.
    if (h.last) |last| assert(last.born < node.born);
    node.prev = h.last;
    if (h.last) |last| last.next = node else h.first = node;
    h.last = node;
    h.lock.release();
    h.compactDue();
}

pub fn remove(h: *History, node: *Node) void {
    h.lock.acquire();
    assert(node.born != 0);
    assert(node.removed == 0);
    h.revision += 1;
    node.removed = h.revision;
    if (h.leases == null) {
        h.detach(node);
        h.lock.release();
        h.discard(node);
    } else {
        h.tombstones += 1;
        h.lock.release();
    }
    h.compactDue();
}

/// Takes a node out of the list, under the lock; the caller frees it
/// once the lock is released.
fn detach(h: *History, node: *Node) void {
    if (node.prev) |prev| prev.next = node.next else h.first = node.next;
    if (node.next) |next| next.prev = node.prev else h.last = node.prev;
    node.prev = null;
    node.next = null;
}

/// Frees the tombstones no lease can see any more, if a release asked for
/// it. Only on the watcher's thread: see the file's comment.
fn compactDue(h: *History) void {
    var gone: ?*Node = null;
    {
        h.lock.acquire();
        defer h.lock.release();
        if (!h.compact_due) return;
        h.compact_due = false;
        if (h.tombstones == 0) return;
        var oldest = h.revision;
        var lease = h.leases;
        while (lease) |l| : (lease = l.next) oldest = @min(oldest, l.revision);
        var node = h.first;
        while (node) |n| {
            node = n.next;
            if (n.removed != 0 and n.removed <= oldest) {
                h.detach(n);
                h.tombstones -= 1;
                n.next = gone;
                gone = n;
            }
        }
    }
    while (gone) |n| {
        gone = n.next;
        h.discard(n);
    }
}

pub fn release(h: *History) void {
    h.lock.acquire();
    assert(h.refs != 0);
    h.refs -= 1;
    const gone = h.refs == 0;
    h.lock.release();
    if (!gone) return;
    var node = h.first;
    while (node) |n| {
        node = n.next;
        h.discard(n);
    }
    h.gpa.destroy(h);
}

pub fn snapshot(h: *History, gpa: Allocator, id: WatchId, root: []const u8) Allocator.Error!Paths {
    const lease = try gpa.create(Lease);
    errdefer gpa.destroy(lease);
    const owned = try gpa.dupe(u8, root);
    h.lock.acquire();
    defer h.lock.release();
    // Leases are kept newest first: only the last one can hold the oldest
    // revision, which is what `Lease.release` compacts on.
    if (h.leases) |newest| assert(newest.revision <= h.revision);
    lease.* = .{ .history = h, .gpa = gpa, .id = id, .root = owned, .revision = h.revision, .next = h.leases };
    if (h.leases) |first| first.prev = lease;
    h.leases = lease;
    h.refs += 1;
    return .{ .shared = lease };
}

const Lease = struct {
    history: *History,
    gpa: Allocator,
    refs: usize = 1,
    id: WatchId,
    root: []const u8,
    revision: u64,
    prev: ?*Lease = null,
    next: ?*Lease,

    fn retain(l: *Lease) void {
        l.history.lock.acquire();
        defer l.history.lock.release();
        assert(l.refs != 0);
        l.refs += 1;
    }

    fn release(l: *Lease) void {
        const h = l.history;
        h.lock.acquire();
        assert(l.refs != 0);
        l.refs -= 1;
        if (l.refs != 0) {
            h.lock.release();
            return;
        }
        if (l.prev) |prev| prev.next = l.next else h.leases = l.next;
        if (l.next) |next| next.prev = l.prev;
        // Newer leases cannot move the oldest retained revision.
        if (l.next == null) h.compact_due = true;
        h.lock.release();
        l.gpa.free(l.root);
        l.gpa.destroy(l);
        h.release();
    }
};

pub const Paths = union(enum) {
    flat: []const []const u8,
    shared: *Lease,

    pub fn retain(p: Paths) Paths {
        if (p == .shared) p.shared.retain();
        return p;
    }

    pub fn release(p: Paths) void {
        if (p == .shared) p.shared.release();
    }

    pub fn iterator(p: Paths) Iterator {
        if (p == .flat) return .{ .flat = p.flat };
        return .{ .lease = p.shared };
    }

    pub fn jsonStringify(p: Paths, writer: anytype) !void {
        try writer.beginArray();
        var it = p.iterator();
        defer it.deinit();
        while (it.next()) |name| try writer.write(name);
        try writer.endArray();
    }

    pub fn jsonParse(gpa: Allocator, source: anytype, options: std.json.ParseOptions) !Paths {
        return .{ .flat = try std.json.innerParse([]const []const u8, gpa, source, options) };
    }
};

pub const Iterator = struct {
    flat: []const []const u8 = &.{},
    index: usize = 0,
    lease: ?*Lease = null,
    /// The last node returned: one the lease can see, and so one nothing
    /// frees while the lease is held. `null` before the first.
    node: ?*Node = null,
    done: bool = false,

    pub fn next(it: *Iterator) ?[]const u8 {
        if (it.lease) |l| {
            if (it.done) return null;
            const h = l.history;
            h.lock.acquire();
            defer h.lock.release();
            var node = if (it.node) |at| at.next else h.first;
            while (node) |n| : (node = n.next) {
                if (n.born > l.revision) break;
                if (n.id == l.id and (n.removed == 0 or n.removed > l.revision) and path.within(l.root, n.path)) {
                    it.node = n;
                    return n.path;
                }
            }
            it.done = true;
            return null;
        }
        if (it.index == it.flat.len) return null;
        const name = it.flat[it.index];
        it.index += 1;
        return name;
    }

    pub fn deinit(it: *Iterator) void {
        it.* = undefined;
    }
};

test "path revisions survive removal, recreation and owner release" {
    const gpa = std.testing.allocator;
    const h = try init(gpa);
    const root = if (builtin.target.os.tag == .windows) "C:\\tree" else "/tree";
    const first = try h.prepare(@fromBackingInt(@intCast(1)), root);
    h.publish(first);
    const before = try h.snapshot(gpa, @fromBackingInt(@intCast(1)), root);
    defer before.release();
    h.remove(first);
    const absent = try h.snapshot(gpa, @fromBackingInt(@intCast(1)), root);
    defer absent.release();
    const replacement = try h.prepare(@fromBackingInt(@intCast(1)), root);
    h.publish(replacement);
    const after = try h.snapshot(gpa, @fromBackingInt(@intCast(1)), root);
    defer after.release();
    h.release();
    for ([_]Paths{ before, absent, after }, [_]usize{ 1, 0, 1 }) |snapshot_paths, count| {
        var it = snapshot_paths.iterator();
        defer it.deinit();
        var found: usize = 0;
        while (it.next()) |name| {
            try std.testing.expectEqualStrings(root, name);
            found += 1;
        }
        try std.testing.expectEqual(count, found);
    }
}

test "releasing the oldest revision compacts obsolete paths" {
    const gpa = std.testing.allocator;
    const h = try init(gpa);
    defer h.release();
    const root = if (builtin.target.os.tag == .windows) "C:\\tree" else "/tree";
    const node = try h.prepare(@fromBackingInt(@intCast(1)), root);
    h.publish(node);
    const before = try h.snapshot(gpa, @fromBackingInt(@intCast(1)), root);
    h.remove(node);
    const after = try h.snapshot(gpa, @fromBackingInt(@intCast(1)), root);
    defer after.release();
    try std.testing.expectEqual(@as(usize, 1), h.tombstones);
    before.release();
    // Released on whatever thread held it, the tombstone is freed by the
    // next change the watcher's thread makes, and never by the release.
    try std.testing.expectEqual(@as(usize, 1), h.tombstones);
    const later = try h.prepare(@fromBackingInt(@intCast(1)), root);
    h.publish(later);
    try std.testing.expectEqual(@as(usize, 0), h.tombstones);
    try std.testing.expectEqual(later, h.first.?);
    h.remove(later);
}

test "a lease read on another thread while the watcher changes the history" {
    const gpa = std.testing.allocator;
    const h = try init(gpa);
    defer h.release();
    const root = if (builtin.target.os.tag == .windows) "C:\\tree" else "/tree";
    var nodes: [64]*Node = undefined;
    for (&nodes) |*slot| {
        slot.* = try h.prepare(@fromBackingInt(@intCast(1)), root);
        h.publish(slot.*);
    }
    const leased = try h.snapshot(gpa, @fromBackingInt(@intCast(1)), root);
    const Reader = struct {
        fn read(p: Paths, count: *usize) void {
            for (0..50) |_| {
                var it = p.iterator();
                defer it.deinit();
                var n: usize = 0;
                while (it.next()) |_| n += 1;
                count.* = n;
            }
            p.release();
        }
    };
    var seen: usize = 0;
    const reader = try std.Thread.spawn(.{}, Reader.read, .{ leased, &seen });
    // Removals and new paths race the reader; what the lease sees does not
    // move, and the watcher's thread frees what it no longer can.
    for (nodes[0..32]) |node| h.remove(node);
    for (0..32) |_| h.publish(try h.prepare(@fromBackingInt(@intCast(1)), root));
    reader.join();
    try std.testing.expectEqual(@as(usize, nodes.len), seen);
    for (nodes[32..]) |node| h.remove(node);
    var node = h.first;
    while (node) |n| {
        node = n.next;
        if (n.removed == 0) h.remove(n);
    }
}
