//! Shared path history. A checkpoint leases a revision, not a copy of the tree.
//! Tombstones stay until no leased revision can see them; ordinary removals
//! need no allocation. Tokens flatten the revision to the existing wire format.
const std = @import("std");
const path = @import("path.zig");
const WatchId = @import("types.zig").WatchId;
const Allocator = std.mem.Allocator;
const History = @This();

gpa: Allocator,
lock: std.atomic.Mutex = .unlocked,
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

fn acquire(h: *History) void {
    while (!h.lock.tryLock()) std.atomic.spinLoopHint();
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
    h.acquire();
    defer h.lock.unlock();
    h.revision += 1;
    node.born = h.revision;
    node.prev = h.last;
    if (h.last) |last| last.next = node else h.first = node;
    h.last = node;
}

pub fn remove(h: *History, node: *Node) void {
    h.acquire();
    defer h.lock.unlock();
    std.debug.assert(node.removed == 0);
    h.revision += 1;
    node.removed = h.revision;
    if (h.leases == null) {
        h.unlink(node);
    } else h.tombstones += 1;
}

fn unlink(h: *History, node: *Node) void {
    if (node.prev) |prev| prev.next = node.next else h.first = node.next;
    if (node.next) |next| next.prev = node.prev else h.last = node.prev;
    h.discard(node);
}

fn compact(h: *History) void {
    if (h.tombstones == 0) return;
    var oldest = h.revision;
    var lease = h.leases;
    while (lease) |l| : (lease = l.next) oldest = @min(oldest, l.revision);
    var node = h.first;
    while (node) |n| {
        node = n.next;
        if (n.removed != 0 and n.removed <= oldest) {
            h.unlink(n);
            h.tombstones -= 1;
        }
    }
}

pub fn release(h: *History) void {
    h.acquire();
    h.refs -= 1;
    const gone = h.refs == 0;
    h.lock.unlock();
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
    h.acquire();
    defer h.lock.unlock();
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
        l.history.acquire();
        defer l.history.lock.unlock();
        l.refs += 1;
    }

    fn release(l: *Lease) void {
        const h = l.history;
        h.acquire();
        l.refs -= 1;
        if (l.refs != 0) {
            h.lock.unlock();
            return;
        }
        if (l.prev) |prev| prev.next = l.next else h.leases = l.next;
        if (l.next) |next| next.prev = l.prev;
        // Newer leases cannot move the oldest retained revision.
        if (l.next == null) h.compact();
        h.lock.unlock();
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
        p.shared.history.acquire();
        return .{ .lease = p.shared, .node = p.shared.history.first };
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
    node: ?*Node = null,

    pub fn next(it: *Iterator) ?[]const u8 {
        if (it.lease) |l| {
            while (it.node) |node| {
                it.node = node.next;
                if (node.born > l.revision) return null;
                if (node.id == l.id and (node.removed == 0 or node.removed > l.revision) and path.within(l.root, node.path)) return node.path;
            }
            return null;
        }
        if (it.index == it.flat.len) return null;
        const name = it.flat[it.index];
        it.index += 1;
        return name;
    }

    pub fn deinit(it: *Iterator) void {
        if (it.lease) |l| l.history.lock.unlock();
        it.* = undefined;
    }
};

test "path revisions survive removal, recreation and owner release" {
    const gpa = std.testing.allocator;
    const h = try init(gpa);
    const root = if (@import("builtin").os.tag == .windows) "C:\\tree" else "/tree";
    const first = try h.prepare(@enumFromInt(1), root);
    h.publish(first);
    const before = try h.snapshot(gpa, @enumFromInt(1), root);
    defer before.release();
    h.remove(first);
    const absent = try h.snapshot(gpa, @enumFromInt(1), root);
    defer absent.release();
    const replacement = try h.prepare(@enumFromInt(1), root);
    h.publish(replacement);
    const after = try h.snapshot(gpa, @enumFromInt(1), root);
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
    const root = if (@import("builtin").os.tag == .windows) "C:\\tree" else "/tree";
    const node = try h.prepare(@enumFromInt(1), root);
    h.publish(node);
    const before = try h.snapshot(gpa, @enumFromInt(1), root);
    h.remove(node);
    const after = try h.snapshot(gpa, @enumFromInt(1), root);
    defer after.release();
    try std.testing.expectEqual(@as(usize, 1), h.tombstones);
    before.release();
    try std.testing.expectEqual(@as(usize, 0), h.tombstones);
    try std.testing.expect(h.first == null);
}
