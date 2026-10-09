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
const aegis = @import("aegis");
const path = @import("../path.zig");
const WatchId = @import("../types.zig").WatchId;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const History = @This();

/// A point in the history's own order of changes. Distinct from the event
/// batch's counter, which only says whether something moved.
const Revision = aegis.id.Id(struct {}, u64);
const Issuer = aegis.id.Counter(Revision.Domain, u64);
/// No revision: before the first change, and the `removed` of a node nothing
/// has removed.
const none: Revision = .fromRaw(0);

/// What the lock guards: the list, its leases and the counts that say what
/// may be freed. A lease's `refs`, `prev` and `next` and a node's links are
/// guarded by it too, and are touched only while a guard is held.
const State = struct {
    /// Set when the oldest lease is released: tombstones it alone could see
    /// can go, on the watcher's thread's next `publish` or `remove`.
    compact_due: bool = false,
    refs: usize = 1,
    /// The last revision issued.
    revision: Revision = none,
    first: ?*Node = null,
    last: ?*Node = null,
    leases: ?*Lease = null,
    tombstones: usize = 0,

    /// Issues the next revision; a history that has changed 2^64 times has
    /// no order left to keep, and stops rather than reuse one.
    fn advance(s: *State) Revision {
        var issuer: Issuer = .init(s.revision.raw());
        s.revision = issuer.next() catch @panic("path history revisions exhausted");
        return s.revision;
    }

    /// Detaches the tombstones no lease can see any more, if a release asked
    /// for it, and returns them linked by `next`; the caller frees them once
    /// the lock is released. Rare, so kept out of line: `publish` and
    /// `remove` stay small.
    noinline fn compact(s: *State) ?*Node {
        assert(s.compact_due);
        s.compact_due = false;
        if (s.tombstones == 0) return null;
        var oldest = s.revision;
        var lease = s.leases;
        while (lease) |l| : (lease = l.next) {
            if (l.revision.compare(oldest) == .lt) oldest = l.revision;
        }
        var gone: ?*Node = null;
        var node = s.first;
        while (node) |n| {
            node = n.next;
            if (n.removed != none and n.removed.compare(oldest) != .gt) {
                s.detach(n);
                s.tombstones -= 1;
                n.next = gone;
                gone = n;
            }
        }
        return gone;
    }

    /// Takes a node out of the list; the caller frees it once the lock is
    /// released.
    fn detach(s: *State, node: *Node) void {
        if (node.prev) |prev| prev.next = node.next else s.first = node.next;
        if (node.next) |next| next.prev = node.prev else s.last = node.prev;
        node.prev = null;
        node.next = null;
    }
};

gpa: Allocator,
/// Short sections only: a pointer update or one step of an iterator, never
/// an allocation, a free or a caller's writer.
state: aegis.Guarded(State) = .init(.{}),

pub const Node = struct {
    path: []const u8,
    id: WatchId,
    born: Revision = none,
    removed: Revision = none,
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
    assert(node.born == none);
    assert(node.removed == none);
    assert(node.prev == null);
    assert(node.next == null);
    var gone: ?*Node = null;
    {
        var held = h.state.acquire();
        defer held.deinit();
        const s = held.value();
        node.born = s.advance();
        // The list is in order of birth, which is what lets an iterator stop
        // at the first node born after its lease.
        if (s.last) |last| assert(last.born.compare(node.born) == .lt);
        node.prev = s.last;
        if (s.last) |last| last.next = node else s.first = node;
        s.last = node;
        if (s.compact_due) gone = s.compact();
    }
    h.discardAll(gone);
}

pub fn remove(h: *History, node: *Node) void {
    var free_now = false;
    var gone: ?*Node = null;
    {
        var held = h.state.acquire();
        defer held.deinit();
        const s = held.value();
        assert(node.born != none);
        assert(node.removed == none);
        node.removed = s.advance();
        if (s.leases == null) {
            s.detach(node);
            free_now = true;
        } else s.tombstones += 1;
        if (s.compact_due) gone = s.compact();
    }
    if (free_now) h.discard(node);
    h.discardAll(gone);
}

/// Frees a chain of detached nodes, linked by `next`, outside the lock.
fn discardAll(h: *History, chain: ?*Node) void {
    var node = chain;
    while (node) |n| {
        node = n.next;
        h.discard(n);
    }
}

pub fn release(h: *History) void {
    var first: ?*Node = null;
    {
        var held = h.state.acquire();
        defer held.deinit();
        const s = held.value();
        assert(s.refs != 0);
        s.refs -= 1;
        if (s.refs != 0) return;
        first = s.first;
    }
    var node = first;
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
    var held = h.state.acquire();
    defer held.deinit();
    const s = held.value();
    // Leases are kept newest first: only the last one can hold the oldest
    // revision, which is what `Lease.release` compacts on.
    if (s.leases) |newest| assert(newest.revision.compare(s.revision) != .gt);
    lease.* = .{ .history = h, .gpa = gpa, .id = id, .root = owned, .revision = s.revision, .next = s.leases };
    if (s.leases) |first| first.prev = lease;
    s.leases = lease;
    s.refs += 1;
    return .{ .shared = lease };
}

const Lease = struct {
    history: *History,
    gpa: Allocator,
    refs: usize = 1,
    id: WatchId,
    root: []const u8,
    revision: Revision,
    prev: ?*Lease = null,
    next: ?*Lease,

    fn retain(l: *Lease) void {
        var held = l.history.state.acquire();
        defer held.deinit();
        assert(l.refs != 0);
        l.refs += 1;
    }

    fn release(l: *Lease) void {
        const h = l.history;
        {
            var held = h.state.acquire();
            defer held.deinit();
            const s = held.value();
            assert(l.refs != 0);
            l.refs -= 1;
            if (l.refs != 0) return;
            if (l.prev) |prev| prev.next = l.next else s.leases = l.next;
            if (l.next) |next| next.prev = l.prev;
            // Newer leases cannot move the oldest retained revision.
            if (l.next == null) s.compact_due = true;
        }
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
            var held = l.history.state.acquire();
            defer held.deinit();
            const s = held.value();
            var node = if (it.node) |at| at.next else s.first;
            while (node) |n| : (node = n.next) {
                if (n.born.compare(l.revision) == .gt) break;
                if (n.id == l.id and (n.removed == none or n.removed.compare(l.revision) == .gt) and path.within(l.root, n.path)) {
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

fn tombstones(h: *History) usize {
    var held = h.state.acquire();
    defer held.deinit();
    return held.value().tombstones;
}

fn firstNode(h: *History) ?*Node {
    var held = h.state.acquire();
    defer held.deinit();
    return held.value().first;
}

test "path revisions survive removal, recreation and owner release" {
    const gpa = std.testing.allocator;
    const h = try init(gpa);
    const root = if (builtin.target.os.tag == .windows) "C:\\tree" else "/tree";
    const first = try h.prepare(.fromRaw(1), root);
    h.publish(first);
    const before = try h.snapshot(gpa, .fromRaw(1), root);
    defer before.release();
    h.remove(first);
    const absent = try h.snapshot(gpa, .fromRaw(1), root);
    defer absent.release();
    const replacement = try h.prepare(.fromRaw(1), root);
    h.publish(replacement);
    const after = try h.snapshot(gpa, .fromRaw(1), root);
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
    const node = try h.prepare(.fromRaw(1), root);
    h.publish(node);
    const before = try h.snapshot(gpa, .fromRaw(1), root);
    h.remove(node);
    const after = try h.snapshot(gpa, .fromRaw(1), root);
    defer after.release();
    try std.testing.expectEqual(@as(usize, 1), tombstones(h));
    before.release();
    // Released on whatever thread held it, the tombstone is freed by the
    // next change the watcher's thread makes, and never by the release.
    try std.testing.expectEqual(@as(usize, 1), tombstones(h));
    const later = try h.prepare(.fromRaw(1), root);
    h.publish(later);
    try std.testing.expectEqual(@as(usize, 0), tombstones(h));
    try std.testing.expectEqual(later, firstNode(h).?);
    h.remove(later);
}

test "a lease read on another thread while the watcher changes the history" {
    const gpa = std.testing.allocator;
    const h = try init(gpa);
    defer h.release();
    const root = if (builtin.target.os.tag == .windows) "C:\\tree" else "/tree";
    var nodes: [64]*Node = undefined;
    for (&nodes) |*slot| {
        slot.* = try h.prepare(.fromRaw(1), root);
        h.publish(slot.*);
    }
    const leased = try h.snapshot(gpa, .fromRaw(1), root);
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
    for (0..32) |_| h.publish(try h.prepare(.fromRaw(1), root));
    reader.join();
    try std.testing.expectEqual(@as(usize, nodes.len), seen);
    for (nodes[32..]) |node| h.remove(node);
    var node = firstNode(h);
    while (node) |n| {
        node = n.next;
        if (n.removed == none) h.remove(n);
    }
}
