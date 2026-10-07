//! The paths one `lookout.Watcher` holds an individual registration for.
//!
//! A watch is one path the caller asked for; a node is one path the
//! operating system is told about. For a file, or for a non-recursive
//! directory, they are the same thing. For a recursive directory watch
//! there is one node per directory in the tree, because neither `kqueue`
//! nor `inotify` recurses on its own.
//!
//! The `kqueue` and `poll` backends share this; `inotify` keeps its own
//! table keyed by the kernel's watch descriptors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const lookout = @import("types.zig");
const Batch = @import("Batch.zig");
const Filter = @import("Filter.zig");
const CompiledFilter = @import("CompiledFilter.zig");
const Snapshot = @import("Snapshot.zig");
const path_cmp = @import("path.zig");
const AddOptions = @import("options.zig").AddOptions;
const Target = lookout.Target;
const WatchId = lookout.WatchId;

const Tree = @This();

gpa: Allocator,
/// Mirrors `@import("options.zig").Options.max_dir_entries`.
max_dir_entries: usize,
/// Whether a directory node also gets a node per regular file inside it.
///
/// The `kqueue` backend needs this: `EVFILT_VNODE` on a directory fires
/// when an entry appears, disappears or is renamed, and says nothing when
/// an entry's contents change, so a file inside a watched directory is
/// only seen to be modified if it is watched itself. The `poll` backend
/// re-stats every entry anyway and leaves this off.
track_entries: bool,
/// Polling enables content checks for timestamps within the snapshot tick.
check_contents: bool = false,
/// Every registered path, keyed by an id that is never reused.
nodes: std.array_hash_map.Auto(NodeId, Node),
/// The node of each watch at each path, so that asking whether a path
/// is registered, or finding its node, costs one lookup rather than a
/// pass over every node: a tree of fifty thousand files once took
/// minutes to add, every file asking that of all the others. The path
/// a key holds is the node's own. One node per watch and path: a node
/// made where another is -- the name now naming an object of another
/// kind -- replaces it. See `insert`.
index: std.array_hash_map.Custom(Key, NodeId, KeyContext, true),
/// Whether `dropped` is kept, for a backend that holds something per
/// node -- `kqueue`'s file descriptors -- and must let go of it when
/// the node goes.
keeps_dropped: bool = false,
/// The nodes dropped since the backend last took them. See
/// `takeDropped`.
dropped: std.ArrayList(NodeId) = .empty,
/// Set when `dropped` could not grow: which nodes went is then not
/// known, and the backend has to look at all of its own.
dropped_lost: bool = false,
/// The caller's watches, keyed by the id `lookout.Watcher.add` returned.
watches: std.array_hash_map.Auto(WatchId, Watch),
next_node: u64,
/// Scratch reused by every scan so that a steady-state watcher does not
/// allocate per event.
changes: std.ArrayList(Snapshot.Change),

/// Identifies one registered path within one tree. Never reused, so a
/// stale kernel event naming a freed node simply finds nothing.
pub const NodeId = enum(u64) { _ };

pub const Key = struct {
    watch: WatchId,
    path: []const u8,
};

pub const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u32 {
        return @truncate(path_cmp.hashOwned(@backingInt(key.watch), key.path));
    }

    pub fn eql(_: KeyContext, a: Key, b: Key, _: usize) bool {
        return a.watch == b.watch and path_cmp.eql(a.path, b.path);
    }
};

/// What the caller asked for.
pub const Watch = struct {
    /// Absolute, canonical path, owned by the tree. This is the path
    /// `lookout.Kind.overflow` is reported against.
    root: []u8,
    target: Target,
    /// `@import("options.zig").AddOptions.recursive`.
    recursive: bool,
    /// `@import("options.zig").AddOptions.filter`, copied: the patterns are borrowed
    /// only for the duration of the `add` that supplied them.
    filter: CompiledFilter,
};

/// One registered path.
pub const Node = struct {
    /// The watch this node belongs to.
    watch: WatchId,
    /// Absolute path of this node, owned by the tree.
    path: []u8,
    /// Whether `dir` and `snapshot` or `meta` are the live fields.
    role: Role,
    /// Open directory handle. Only meaningful when `role` is `directory`;
    /// on POSIX its `handle` is the descriptor a backend registers.
    dir: Io.Dir,
    /// The directory's remembered listing. Only meaningful when `role` is
    /// `directory`.
    snapshot: Snapshot,
    /// The file's remembered metadata. Only meaningful when `role` is
    /// `file`.
    meta: Snapshot.Meta,
    /// The node of the directory this one was listed in, or `null` for
    /// a watch's own root.
    parent: ?NodeId,
    /// The nodes listed in this one, so that dropping a directory costs
    /// what is below it and not a pass over every node.
    children: std.array_hash_map.Auto(NodeId, void) = .empty,

    /// What a node stands for.
    pub const Role = enum { file, directory };
};

/// Errors adding a watch can return.
pub const AddError = Allocator.Error || Io.Dir.OpenError || Io.Dir.StatFileError ||
    Io.Dir.RealPathFileAllocError || Snapshot.RefreshError || CompiledFilter.Error;

/// Errors rescanning a watch can return.
pub const ScanError = Allocator.Error || Snapshot.RefreshError;

/// A tree that holds nothing.
pub fn init(gpa: Allocator, max_dir_entries: usize, track_entries: bool) Tree {
    return .{
        .gpa = gpa,
        .max_dir_entries = max_dir_entries,
        .track_entries = track_entries,
        .nodes = .empty,
        .index = .empty,
        .watches = .empty,
        .next_node = 0,
        .changes = .empty,
    };
}

/// Closes every directory handle and frees every path.
pub fn deinit(t: *Tree, io: Io) void {
    for (t.nodes.values()) |*node| t.destroy(io, node);
    t.nodes.deinit(t.gpa);
    t.index.deinit(t.gpa);
    t.dropped.deinit(t.gpa);
    for (t.watches.values()) |*watch| {
        t.gpa.free(watch.root);
        watch.filter.deinit();
    }
    t.watches.deinit(t.gpa);
    Snapshot.freeChanges(t.gpa, &t.changes);
    t.changes.deinit(t.gpa);
    t.* = undefined;
}

/// Registers `abs_path` under `id`, appending the ids of every node
/// created to `added`. The path is copied; the caller keeps its own.
///
/// When `recursive` and the path is a directory, every directory below it
/// becomes a node too. On failure nothing is left registered.
pub fn addWatch(
    t: *Tree,
    io: Io,
    id: WatchId,
    abs_path: []const u8,
    options: AddOptions,
    added: *std.ArrayList(NodeId),
    batch: *Batch,
) Tree.AddError!void {
    const taken_ns = Io.Clock.real.now(io).nanoseconds;
    const stat = try Io.Dir.cwd().statFile(io, abs_path, .{});
    const recursive = options.recursive;

    const root = try t.gpa.dupe(u8, abs_path);
    errdefer t.gpa.free(root);
    var filter = try CompiledFilter.compile(t.gpa, options.filter);
    errdefer filter.deinit();
    try t.watches.put(t.gpa, id, .{
        .root = root,
        .target = .of(stat.kind),
        .recursive = recursive,
        .filter = filter,
    });
    errdefer _ = t.watches.swapRemove(id);

    const start = added.items.len;
    errdefer t.rollback(io, added, start);

    const node_path = try t.gpa.dupe(u8, abs_path);
    {
        // Scoped so that the node takes ownership on success and this
        // frees it on failure, without the two ever both happening.
        errdefer t.gpa.free(node_path);
        if (stat.kind != .directory) {
            _ = try t.createFile(io, id, null, node_path, Snapshot.capture(io, .cwd(), abs_path, stat, taken_ns, t.check_contents, false), added);
            return;
        }
        _ = try t.createDirectory(io, id, null, node_path, added);
    }
    if (!recursive) return;

    // The initial listing of each directory is the list of subdirectories
    // to descend into, so the walk costs no extra syscalls. The frontier
    // is an index into `added` rather than a pointer because creating a
    // node can rehash `nodes`.
    var frontier = start;
    while (frontier < added.items.len) : (frontier += 1) {
        try t.descend(io, added.items[frontier], added, batch);
    }
}

/// Undoes the nodes one `addWatch` created, for an `addWatch` that fails
/// partway: a half-registered watch would report a fraction of a tree.
fn rollback(t: *Tree, io: Io, added: *std.ArrayList(NodeId), start: usize) void {
    for (added.items[start..]) |node_id| {
        const at = t.nodes.getIndex(node_id) orelse continue;
        t.dropAt(io, at);
    }
    added.shrinkRetainingCapacity(start);
}

/// Creates a node for every subdirectory already listed in `parent`'s
/// snapshot.
fn descend(t: *Tree, io: Io, parent_id: NodeId, added: *std.ArrayList(NodeId), batch: *Batch) AddError!void {
    const parent = t.nodes.getPtr(parent_id) orelse return;
    if (parent.role != .directory) return;
    const watch = parent.watch;
    const parent_path = parent.path;

    var i: usize = 0;
    while (true) : (i += 1) {
        // Re-resolved each round: `createDirectory` can rehash `nodes`.
        const node = t.nodes.getPtr(parent_id) orelse return;
        if (i >= node.snapshot.entries.count()) break;
        if (node.snapshot.entries.values()[i].file_kind != .directory) continue;
        const name = node.snapshot.entries.keys()[i];
        const child_path = try std.Io.Dir.path.join(t.gpa, &.{ parent_path, name });
        errdefer t.gpa.free(child_path);
        // An excluded directory is not opened and not registered, which
        // is the whole point of filtering here rather than on the way
        // out: the tree below it costs nothing.
        if (t.pruned(watch, child_path)) {
            t.gpa.free(child_path);
            continue;
        }
        if (t.hasNode(watch, child_path)) {
            t.gpa.free(child_path);
            continue;
        }
        _ = t.createDirectory(io, watch, parent_id, child_path, added) catch |err| switch (err) {
            // A subdirectory that vanished between the listing and the
            // open is not an error; the parent's next scan reports it.
            // One that is not ours to read is neither, and it is not
            // nothing either: it is a hole in the watch, and saying so
            // is the difference between a quiet subtree and a silent one.
            error.FileNotFound, error.AccessDenied, error.NotDir => {
                if (err != error.FileNotFound) {
                    try batch.trouble(t.gpa, watch, child_path, .directory);
                }
                t.gpa.free(child_path);
                continue;
            },
            else => |e| return e,
        };
    }
}

fn createDirectory(t: *Tree, io: Io, watch: WatchId, parent: ?NodeId, path: []u8, added: *std.ArrayList(NodeId)) AddError!NodeId {
    var dir = try Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    errdefer dir.close(io);

    const id: NodeId = @fromBackingInt(@intCast(t.next_node));
    try t.insert(io, id, .{
        .watch = watch,
        .path = path,
        .role = .directory,
        .dir = dir,
        .snapshot = .{ .entries = .empty, .truncated = false, .check_contents = t.check_contents },
        .meta = undefined,
        .parent = parent,
    });
    errdefer {
        // The handle and the path are still this call's and its
        // caller's; the children, if any, have been rolled back.
        const node = t.nodes.getPtr(id).?;
        node.snapshot.deinit(t.gpa);
        node.children.deinit(t.gpa);
        t.unlink(id, node.*);
        _ = t.nodes.swapRemove(id);
    }
    t.next_node += 1;

    // The listing taken here is the baseline: the caller asked to be told
    // what changes from now on, not what already exists. It goes into a
    // local list rather than `t.changes`, which a scan in progress above
    // this call is iterating.
    var baseline: std.ArrayList(Snapshot.Change) = .empty;
    defer {
        Snapshot.freeChanges(t.gpa, &baseline);
        baseline.deinit(t.gpa);
    }
    const node = t.nodes.getPtr(id).?;
    try node.snapshot.refresh(t.gpa, io, dir, t.max_dir_entries, &baseline);

    const start = added.items.len;
    try added.append(t.gpa, id);
    errdefer {
        // This scope still owns the directory's handle and snapshot, and
        // its caller still owns the path. Child nodes have already taken
        // theirs, so roll them back before releasing this directory.
        t.rollback(io, added, start + 1);
        added.shrinkRetainingCapacity(start);
    }
    if (t.track_entries) try t.trackEntries(io, id, added);
    return id;
}

/// Gives every regular file already listed in a directory node its own
/// node, so a backend that watches descriptors can watch them too.
fn trackEntries(t: *Tree, io: Io, dir_id: NodeId, added: *std.ArrayList(NodeId)) AddError!void {
    var i: usize = 0;
    while (true) : (i += 1) {
        // Re-resolved each round: creating a node can rehash `nodes`.
        const dir_node = t.nodes.getPtr(dir_id) orelse return;
        if (i >= dir_node.snapshot.entries.count()) return;
        const meta = dir_node.snapshot.entries.values()[i];
        if (meta.file_kind != .file) continue;
        const name = dir_node.snapshot.entries.keys()[i];
        const child = try std.Io.Dir.path.join(t.gpa, &.{ dir_node.path, name });
        errdefer t.gpa.free(child);
        if (t.excluded(dir_node.watch, child)) {
            t.gpa.free(child);
            continue;
        }
        if (t.hasNode(dir_node.watch, child)) {
            t.gpa.free(child);
            continue;
        }
        _ = try t.createFile(io, dir_node.watch, dir_id, child, meta, added);
    }
}

fn createFile(t: *Tree, io: Io, watch: WatchId, parent: ?NodeId, path: []u8, meta: Snapshot.Meta, added: *std.ArrayList(NodeId)) Allocator.Error!NodeId {
    const id: NodeId = @fromBackingInt(@intCast(t.next_node));
    try t.insert(io, id, .{
        .watch = watch,
        .path = path,
        .role = .file,
        .dir = undefined,
        .snapshot = undefined,
        .meta = meta,
        .parent = parent,
    });
    errdefer {
        t.unlink(id, t.nodes.get(id).?);
        _ = t.nodes.swapRemove(id);
    }
    t.next_node += 1;
    try added.append(t.gpa, id);
    return id;
}

/// Puts `node` into the table, the index and its parent's children,
/// all or none. A node of the same watch already at the path is of an
/// object that name no longer names -- a file where a directory was --
/// and goes first, with everything below it.
fn insert(t: *Tree, io: Io, id: NodeId, node: Node) Allocator.Error!void {
    // Node ids are never reused.
    assert(!t.nodes.contains(id));
    const key: Key = .{ .watch = node.watch, .path = node.path };
    if (t.index.get(key)) |stale| t.dropSubtree(io, stale);
    try t.nodes.ensureUnusedCapacity(t.gpa, 1);
    try t.index.ensureUnusedCapacity(t.gpa, 1);
    if (node.parent) |parent| try t.nodes.getPtr(parent).?.children.put(t.gpa, id, {});
    t.nodes.putAssumeCapacity(id, node);
    t.index.putAssumeCapacity(key, id);
    // One index entry per node: a node made where another was replaced it.
    assert(t.index.count() == t.nodes.count());
}

/// Takes the node `id` out of the index and out of its parent's
/// children, leaving it in the table.
fn unlink(t: *Tree, id: NodeId, node: Node) void {
    const key: Key = .{ .watch = node.watch, .path = node.path };
    if (t.index.getIndex(key)) |at| {
        if (t.index.values()[at] == id) t.index.swapRemoveAt(at);
    }
    if (node.parent) |parent| {
        if (t.nodes.getPtr(parent)) |above| _ = above.children.swapRemove(id);
    }
}

/// Drops the node at position `at` of the table, alone: the nodes below
/// it, if any, stay, no longer anyone's children. Every caller drops
/// those too, in the same pass. The order of the table's other entries
/// changes as `swapRemoveAt` changes it.
fn dropAt(t: *Tree, io: Io, at: usize) void {
    const id = t.nodes.keys()[at];
    const node = &t.nodes.values()[at];
    t.unlink(id, node.*);
    for (node.children.keys()) |child| {
        if (t.nodes.getPtr(child)) |below| below.parent = null;
    }
    t.destroy(io, node);
    t.nodes.swapRemoveAt(at);
    t.noteDropped(id);
    assert(t.index.count() == t.nodes.count());
}

/// Drops `top` and every node below it, deepest first, at the cost of
/// what is dropped. Allocates nothing.
fn dropSubtree(t: *Tree, io: Io, top: NodeId) void {
    var current = top;
    while (true) {
        const node = t.nodes.getPtr(current) orelse return;
        if (node.children.count() != 0) {
            current = node.children.keys()[node.children.count() - 1];
            continue;
        }
        const parent = node.parent;
        t.dropAt(io, t.nodes.getIndex(current).?);
        if (current == top) return;
        current = parent orelse return;
    }
}

fn noteDropped(t: *Tree, id: NodeId) void {
    if (!t.keeps_dropped) return;
    t.dropped.append(t.gpa, id) catch {
        t.dropped_lost = true;
    };
}

/// The nodes dropped since the last call, for a backend that set
/// `keeps_dropped`; `null` when which ones is not known, and the
/// backend has to compare everything it holds with `nodes`. Valid
/// until the next change to the tree; `clearDropped` once handled.
pub fn takeDropped(t: *const Tree) ?[]const NodeId {
    return if (t.dropped_lost) null else t.dropped.items;
}

pub fn clearDropped(t: *Tree) void {
    t.dropped.clearRetainingCapacity();
    t.dropped_lost = false;
}

/// Drops `id` and every node it created, releasing their descriptors.
/// Unknown ids are ignored.
pub fn removeWatch(t: *Tree, io: Io, id: WatchId) void {
    var watch = t.watches.fetchSwapRemove(id) orelse return;
    t.gpa.free(watch.value.root);
    watch.value.filter.deinit();

    // One pass over every node rather than the root's subtree: it is
    // one pass per call, and it leaves nothing of the watch whatever
    // the links say. Every node of the watch goes, parents with their
    // children, so none is unlinked from another, and the index loses
    // its entries by position: hashing each path again to find its
    // entry made removing a watch twice as slow as its nodes.
    var i: usize = 0;
    while (i < t.index.count()) {
        if (t.index.keys()[i].watch == id) t.index.swapRemoveAt(i) else i += 1;
    }
    i = 0;
    while (i < t.nodes.count()) {
        if (t.nodes.values()[i].watch == id) {
            const node_id = t.nodes.keys()[i];
            t.destroy(io, &t.nodes.values()[i]);
            t.nodes.swapRemoveAt(i);
            t.noteDropped(node_id);
        } else {
            i += 1;
        }
    }
    assert(t.index.count() == t.nodes.count());
}

/// Reconciles the nodes of one watch with a new filter. The root remains
/// registered while newly admitted descendants are opened and then old
/// excluded descendants are released.
pub fn refilter(t: *Tree, io: Io, id: WatchId, next: Filter, added: *std.ArrayList(NodeId), batch: *Batch) Tree.AddError!void {
    const watch = t.watches.getPtr(id) orelse return;
    const replacement = try CompiledFilter.compile(t.gpa, next);
    var previous = watch.filter;
    watch.filter = replacement;
    errdefer {
        watch.filter.deinit();
        watch.filter = previous;
        t.rollback(io, added, 0);
    }

    if (watch.target == .directory) {
        var frontier: usize = 0;
        // The existing directory nodes are reconsidered, followed by the
        // nodes this pass opens. Their snapshots supply the first frontier.
        var dirs: std.ArrayList(NodeId) = .empty;
        defer dirs.deinit(t.gpa);
        for (t.nodes.keys(), t.nodes.values()) |node_id, node| {
            if (node.watch == id and node.role == .directory and
                (path_cmp.eql(node.path, watch.root) or !t.pruned(id, node.path)))
                try dirs.append(t.gpa, node_id);
        }
        while (frontier < dirs.items.len) : (frontier += 1) {
            const start = added.items.len;
            if (t.track_entries) try t.trackEntries(io, dirs.items[frontier], added);
            if (watch.recursive) try t.descend(io, dirs.items[frontier], added, batch);
            for (added.items[start..]) |node_id| {
                if ((t.nodes.get(node_id) orelse continue).role == .directory)
                    try dirs.append(t.gpa, node_id);
            }
        }
    }

    // Keep the root even when a predicate rejects its spelling: the root
    // is the watch's anchor, and filters apply to entries beneath it.
    var i: usize = 0;
    while (i < t.nodes.count()) {
        const node = t.nodes.values()[i];
        if (node.watch != id or path_cmp.eql(node.path, watch.root)) {
            i += 1;
            continue;
        }
        const rejected = switch (node.role) {
            .directory => t.pruned(id, node.path),
            .file => t.excluded(id, node.path),
        };
        if (rejected) t.dropAt(io, i) else i += 1;
    }
    previous.deinit();
}

/// Whether the watch `id` has a node at `subject`. A watch whose root
/// has none has no nodes at all: every other node was listed in one.
pub fn hasNode(t: *const Tree, id: WatchId, subject: []const u8) bool {
    return t.index.contains(.{ .watch = id, .path = subject });
}

/// Drops the node of `watch` at `root` and every node of it below.
/// Used when a watched directory itself disappears.
///
/// Only that one watch's: another watch holding a node on the same path
/// -- a pending watch parked on a folder that is also watched, or two
/// watches that overlap -- is told of the disappearance by its own node
/// and reports it itself. Dropping its nodes here would have taken its
/// event with them.
///
/// What is below a node was listed in it, so the node's children are
/// the whole subtree, and a path with no node has none below it.
/// `root` may be the path of the node being dropped: it is looked up
/// once, before anything is freed.
pub fn removeSubtree(t: *Tree, io: Io, watch: WatchId, root: []const u8) void {
    const id = t.index.get(.{ .watch = watch, .path = root }) orelse return;
    t.dropSubtree(io, id);
}

fn destroy(t: *Tree, io: Io, node: *Node) void {
    if (node.role == .directory) {
        node.dir.close(io);
        node.snapshot.deinit(t.gpa);
    }
    node.children.deinit(t.gpa);
    t.gpa.free(node.path);
}

/// The absolute path of the watch a node belongs to, for reporting
/// `lookout.Kind.overflow`.
pub fn watchRoot(t: *const Tree, id: WatchId) []const u8 {
    return (t.watches.get(id) orelse return "").root;
}

pub fn watchRootTarget(t: *Tree, id: WatchId) Target {
    return (t.watches.get(id) orelse return .unknown).target;
}

/// Whether the watch a node belongs to asked for recursion.
fn isRecursive(t: *Tree, id: WatchId) bool {
    return (t.watches.get(id) orelse return false).recursive;
}

/// Whether `subject` is outside what the watch `id` is about, so no
/// event for it is reported. See `@import("options.zig").AddOptions.filter`.
fn excluded(t: *const Tree, id: WatchId, subject: []const u8) bool {
    const watch = t.watches.get(id) orelse return false;
    return watch.filter.excludes(watch.root, subject);
}

/// Whether a directory is so far outside the watch that it need not be
/// registered at all. See `CompiledFilter.prunes`.
fn pruned(t: *const Tree, id: WatchId, subject: []const u8) bool {
    const watch = t.watches.get(id) orelse return false;
    return watch.filter.prunes(watch.root, subject);
}

/// Re-lists the directory node `id`, pushes what changed into `batch`, and
/// appends the ids of nodes created for newly appeared subdirectories to
/// `added`.
///
/// A node whose directory has disappeared is dropped along with everything
/// below it, and reported as `lookout.Kind.removed`.
/// The baseline advances only after reporting and adoption succeed.
/// Failure releases newly adopted nodes and leaves the listing retryable.
pub fn rescanDirectory(
    t: *Tree,
    io: Io,
    id: NodeId,
    batch: *Batch,
    added: *std.ArrayList(NodeId),
) Tree.ScanError!void {
    const node = t.nodes.getPtr(id) orelse return;
    if (node.role != .directory) return;
    const watch = node.watch;
    const recursive = t.isRecursive(watch);

    Snapshot.freeChanges(t.gpa, &t.changes);
    defer Snapshot.freeChanges(t.gpa, &t.changes);
    var next = node.snapshot.prepare(t.gpa, io, node.dir, t.max_dir_entries, &t.changes) catch |err| switch (err) {
        // The directory is gone, or is no longer a directory. Report it and
        // stop watching what is below it.
        error.FileNotFound, error.NotDir => {
            const gone = try t.gpa.dupe(u8, node.path);
            defer t.gpa.free(gone);
            try batch.push(t.gpa, io, watch, gone, .removed, .directory);
            t.removeSubtree(io, watch, gone);
            return;
        },
        else => return err,
    };

    errdefer next.deinit(t.gpa);
    const start = added.items.len;
    // A retry must adopt the whole newly discovered subtree, rather than
    // treating partially created nodes as a baseline it never reported.
    errdefer t.rollback(io, added, start);

    if (next.truncated) {
        try batch.push(t.gpa, io, watch, t.watchRoot(watch), .overflow, t.watchRootTarget(watch));
    }

    const dir_path = t.nodes.getPtr(id).?.path;
    for (t.changes.items) |change| {
        // A subdirectory's own modification time moves whenever anything
        // inside it moves. Reporting that would make every ancestor of a
        // change produce an event, which `inotify` does not do and a
        // caller cannot use; a recursive watch reports the change itself,
        // and a non-recursive one deliberately does not look inside.
        if (change.file_kind == .directory and
            (change.kind == .modified or change.kind == .attributes)) continue;

        const child = try std.Io.Dir.path.join(t.gpa, &.{ dir_path, change.name });
        defer t.gpa.free(child);
        // Excluded before it is reported and before a node is made for
        // it, so an excluded directory never becomes a registration.
        const pruned_here = t.pruned(watch, child);
        if (!t.excluded(watch, child)) {
            try batch.push(t.gpa, io, watch, child, change.kind, .of(change.file_kind));
        }
        if (pruned_here) continue;

        if (change.file_kind == .file) {
            if (!t.track_entries) continue;
            switch (change.kind) {
                .created => {
                    const meta = next.entries.get(change.name) orelse continue;
                    const owned = try t.gpa.dupe(u8, child);
                    errdefer t.gpa.free(owned);
                    _ = try t.createFile(io, watch, id, owned, meta, added);
                },
                .removed => t.removeSubtree(io, watch, child),
                else => {},
            }
            continue;
        }
        if (!recursive or change.file_kind != .directory) continue;
        switch (change.kind) {
            .created => try t.adopt(io, watch, id, child, batch, added),
            .removed => t.removeSubtree(io, watch, child),
            else => {},
        }
    }
    t.nodes.getPtr(id).?.snapshot.accept(t.gpa, &next);
}

/// Registers a directory that has appeared under a recursive watch, and
/// everything already inside it, reporting all of it as created.
///
/// A directory can be created and filled before lookout is told it exists
/// -- an archive unpacked, a `mkdir -p`, a build writing a tree in one
/// go -- and the listing taken when it is registered is its baseline, so
/// without this everything already inside would be taken for something
/// that had always been there, and the directories among them would
/// never be registered at all.
///
/// Iterative rather than recursive: the tree being adopted was made by
/// somebody else and its depth is not this library's to bound.
fn adopt(
    t: *Tree,
    io: Io,
    watch: WatchId,
    parent: ?NodeId,
    root: []const u8,
    batch: *Batch,
    added: *std.ArrayList(NodeId),
) ScanError!void {
    // Each directory still to register, with the node it was listed in.
    const Found = struct { path: []u8, parent: ?NodeId };
    var frontier: std.ArrayList(Found) = .empty;
    defer {
        for (frontier.items) |found| t.gpa.free(found.path);
        frontier.deinit(t.gpa);
    }
    {
        const owned = try t.gpa.dupe(u8, root);
        errdefer t.gpa.free(owned);
        try frontier.append(t.gpa, .{ .path = owned, .parent = parent });
    }

    var i: usize = 0;
    while (i < frontier.items.len) : (i += 1) {
        const current = frontier.items[i].path;
        const id = registering: {
            const owned = try t.gpa.dupe(u8, current);
            errdefer t.gpa.free(owned);
            break :registering t.createDirectory(io, watch, frontier.items[i].parent, owned, added) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Created and gone again, or not ours to open: reported
                // through its parent, and as a hole in the watch when the
                // reason is that it cannot be read rather than that it has
                // gone.
                else => {
                    if (err != error.FileNotFound) {
                        try batch.trouble(t.gpa, watch, owned, .directory);
                    }
                    t.gpa.free(owned);
                    continue;
                },
            };
        };

        var j: usize = 0;
        while (true) : (j += 1) {
            // Re-resolved each round: the node table is rehashed by the
            // next directory this loop creates.
            const node = t.nodes.getPtr(id) orelse break;
            if (j >= node.snapshot.entries.count()) break;
            const name = node.snapshot.entries.keys()[j];
            const file_kind = node.snapshot.entries.values()[j].file_kind;

            const entry = try std.Io.Dir.path.join(t.gpa, &.{ current, name });
            errdefer t.gpa.free(entry);
            if (t.pruned(watch, entry)) {
                t.gpa.free(entry);
                continue;
            }
            if (!t.excluded(watch, entry)) {
                try batch.push(t.gpa, io, watch, entry, .created, .of(file_kind));
            }
            if (file_kind == .directory) {
                try frontier.append(t.gpa, .{ .path = entry, .parent = id });
            } else {
                t.gpa.free(entry);
            }
        }
    }
}

/// Re-stats the file node `id` and pushes what changed into `batch`. Used
/// by the `poll` backend, which is told nothing by the kernel.
pub fn rescanFile(t: *Tree, io: Io, id: NodeId, batch: *Batch) Tree.ScanError!void {
    const node = t.nodes.getPtr(id) orelse return;
    if (node.role != .file) return;

    const taken_ns = Io.Clock.real.now(io).nanoseconds;
    const stat = Io.Dir.cwd().statFile(io, node.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            const gone = try t.gpa.dupe(u8, node.path);
            defer t.gpa.free(gone);
            try batch.push(t.gpa, io, node.watch, gone, .removed, .file);
            t.removeSubtree(io, node.watch, gone);
            return;
        },
        else => return err,
    };
    const before = node.meta;
    const next = Snapshot.capture(io, .cwd(), node.path, stat, taken_ns, t.check_contents, before.racy);
    if (before.size != stat.size or before.mtime_ns != stat.mtime.nanoseconds or before.contentChanged(next)) {
        try batch.push(t.gpa, io, node.watch, node.path, .modified, .of(stat.kind));
    } else if (before.ctime_ns != stat.ctime.nanoseconds) {
        try batch.push(t.gpa, io, node.watch, node.path, .attributes, .of(stat.kind));
    }
    node.meta = next;
}

const shakedown = @import("shakedown");

test "tree access failures keep registrations and report no removals" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "kept", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const file = try std.Io.Dir.path.join(gpa, &.{ root, "kept" });
    defer gpa.free(file);

    inline for (.{ error.AccessDenied, error.Canceled, error.SystemResources }) |failure| {
        var tree: Tree = .init(gpa, 4096, false);
        defer tree.deinit(io);
        var batch: Batch = .init(.{});
        defer batch.deinit(gpa);
        var added: std.ArrayList(NodeId) = .empty;
        defer added.deinit(gpa);
        try tree.addWatch(io, @fromBackingInt(@intCast(0)), root, .{}, &added, &batch);
        const directory_id = added.items[0];
        try tree.addWatch(io, @fromBackingInt(@intCast(1)), file, .{}, &added, &batch);
        const file_id = added.items[1];

        const fio = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{
            .{ .at = .{ .nth = .{ .call = .dirRead, .n = 1 } }, .fault = .{ .fail = failure }, .times = 0 },
            .{ .at = .{ .nth = .{ .call = .dirStatFile, .n = 1 } }, .fault = .{ .fail = failure }, .times = 0 },
        } });
        defer fio.deinit();
        const failing = fio.io();
        try testing.expectError(failure, tree.rescanDirectory(failing, directory_id, &batch, &added));
        try testing.expectError(failure, tree.rescanFile(failing, file_id, &batch));
        try testing.expectEqual(@as(usize, 2), tree.nodes.count());
        try testing.expectEqual(@as(usize, 0), batch.events.items.len);
        try tree.rescanDirectory(io, directory_id, &batch, &added);
        try tree.rescanFile(io, file_id, &batch);
        try testing.expectEqual(@as(usize, 0), batch.events.items.len);
    }
}

test "a failed tree registration releases every snapshot and path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "entry", .data = "x" });
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        {
            var tree: Tree = .init(gpa, 8, true);
            defer tree.deinit(io);
            var added: std.ArrayList(NodeId) = .empty;
            defer added.deinit(gpa);
            var batch: Batch = .init(.{});
            defer batch.deinit(gpa);
            if (tree.addWatch(io, @fromBackingInt(@intCast(0)), root, .{}, &added, &batch)) |_| {
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(@as(usize, 0), tree.nodes.count());
                try std.testing.expectEqual(@as(usize, 0), tree.watches.count());
                try std.testing.expectEqual(@as(usize, 0), added.items.len);
            }
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "a failed tree adoption releases every unregistered path" {
    const io = std.testing.io;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, "child/deeper");
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var succeeded = false;
        {
            var tree: Tree = .init(gpa, 8, false);
            defer tree.deinit(io);
            defer {
                const watch = tree.watches.fetchSwapRemove(@fromBackingInt(@intCast(0))).?.value;
                testing.allocator.free(watch.root);
                tree.watches.deinit(testing.allocator);
                tree.watches = .empty;
            }
            // Adoption needs the watch policy, but not a parent node.
            try tree.watches.put(testing.allocator, @fromBackingInt(@intCast(0)), .{
                .root = try testing.allocator.dupe(u8, root),
                .target = .directory,
                .recursive = true,
                .filter = .none,
            });
            var added: std.ArrayList(NodeId) = .empty;
            defer added.deinit(gpa);
            var batch: Batch = .init(.{});
            defer batch.deinit(gpa);
            if (tree.adopt(io, @fromBackingInt(@intCast(0)), null, root, &batch, &added)) |_| {
                succeeded = true;
            } else |err| try testing.expectEqual(error.OutOfMemory, err);
        }
        // The watch's policy was allocated by the underlying allocator.
        // Count only adoption's allocations, all of which are now released.
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (succeeded) break;
    }
}

test "a failed tree scan keeps its directory baseline and retries adoption" {
    const io = std.testing.io;
    const testing = std.testing;
    for ([_]bool{ false, true }) |track_entries| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var tmp = testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
            defer testing.allocator.free(root);
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var tree = Tree.init(failing.allocator(), 64, track_entries);
            defer tree.deinit(io);
            var batch = Batch.init(.{});
            defer batch.deinit(failing.allocator());
            var added: std.ArrayList(NodeId) = .empty;
            defer added.deinit(failing.allocator());
            try tree.addWatch(io, @fromBackingInt(@intCast(0)), root, .{ .recursive = true }, &added, &batch);
            const parent = added.items[0];
            added.clearRetainingCapacity();
            try tmp.dir.createDirPath(testing.io, "child/deeper");
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "child/first", .data = "one" });
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "child/deeper/last", .data = "two" });
            failing.fail_index = failing.alloc_index + fail_index;
            const answer = tree.rescanDirectory(io, parent, &batch, &added);
            failing.fail_index = std.math.maxInt(usize);
            if (answer) |_| break else |err| try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), tree.nodes.get(parent).?.snapshot.entries.count());
            try testing.expectEqual(@as(usize, 1), tree.nodes.count());
            try testing.expectEqual(@as(usize, 0), added.items.len);
            try tree.rescanDirectory(io, parent, &batch, &added);
            try testing.expectEqual(@as(usize, if (track_entries) 5 else 3), tree.nodes.count());
            var first = false;
            var last = false;
            for (batch.events.items) |event| {
                if (std.mem.endsWith(u8, event.path, "first")) first = true;
                if (std.mem.endsWith(u8, event.path, "last")) last = true;
            }
            try testing.expect(first and last);
            batch.reset(failing.allocator());
            try tree.rescanDirectory(io, parent, &batch, &added);
            try testing.expectEqual(@as(usize, 0), batch.events.items.len);
        }
        try testing.expect(fail_index > 0);
    }
}

test "a failed tree scan keeps file metadata until reporting succeeds" {
    const io = std.testing.io;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, "file", testing.allocator);
    defer testing.allocator.free(root);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var tree = Tree.init(failing.allocator(), 64, false);
    defer tree.deinit(io);
    var batch = Batch.init(.{});
    defer batch.deinit(failing.allocator());
    var added: std.ArrayList(NodeId) = .empty;
    defer added.deinit(failing.allocator());
    try tree.addWatch(io, @fromBackingInt(@intCast(0)), root, .{}, &added, &batch);
    const id = added.items[0];
    const before = tree.nodes.get(id).?.meta;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "changed size" });
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, tree.rescanFile(io, id, &batch));
    try testing.expectEqualDeep(before, tree.nodes.get(id).?.meta);
    failing.fail_index = std.math.maxInt(usize);
    try tree.rescanFile(io, id, &batch);
    try testing.expectEqual(@as(usize, 1), batch.events.items.len);
    try testing.expectEqual(lookout.Kind.modified, batch.events.items[0].kind);
}

test "refilter registers newly admitted files without recursion" {
    const io = std.testing.io;
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "old", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var tree = Tree.init(gpa, 4096, true);
    defer tree.deinit(io);
    var batch = Batch.init(.{});
    defer batch.deinit(gpa);
    var added: std.ArrayList(NodeId) = .empty;
    defer added.deinit(gpa);
    const id: WatchId = @fromBackingInt(@intCast(0));
    try tree.addWatch(io, id, root, .{ .filter = .{ .only = &.{"old"} } }, &added, &batch);
    try testing.expectEqual(@as(usize, 2), tree.nodes.count());
    added.clearRetainingCapacity();
    try tree.refilter(io, id, .{ .only = &.{"new"} }, &added, &batch);
    try testing.expectEqual(@as(usize, 1), added.items.len);
    const node = tree.nodes.get(added.items[0]).?;
    try testing.expectEqual(Node.Role.file, node.role);
    try testing.expectEqualStrings("new", std.Io.Dir.path.basename(node.path));
    try testing.expectEqual(@as(usize, 2), tree.nodes.count());
}

test "refilter releases files that only lead to an included path" {
    const io = std.testing.io;
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "prefix", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var tree = Tree.init(gpa, 4096, true);
    defer tree.deinit(io);
    var batch = Batch.init(.{});
    defer batch.deinit(gpa);
    var added: std.ArrayList(NodeId) = .empty;
    defer added.deinit(gpa);
    const id: WatchId = @fromBackingInt(@intCast(0));
    try tree.addWatch(io, id, root, .{}, &added, &batch);
    try testing.expectEqual(@as(usize, 2), tree.nodes.count());
    added.clearRetainingCapacity();
    // A directory named prefix would lead to a match. A regular file
    // cannot, so keeping its descriptor would only waste a registration.
    try tree.refilter(io, id, .{ .only = &.{"prefix/inside"} }, &added, &batch);
    try testing.expectEqual(@as(usize, 1), tree.nodes.count());
}

/// Every node is in the index under its own watch and path, and listed
/// in its parent's children, and every child names its parent.
fn expectLinked(tree: *const Tree) !void {
    const testing = std.testing;
    try testing.expectEqual(tree.nodes.count(), tree.index.count());
    for (tree.nodes.keys(), tree.nodes.values()) |id, node| {
        try testing.expectEqual(id, tree.index.get(.{ .watch = node.watch, .path = node.path }).?);
        if (node.parent) |parent| {
            try testing.expect(tree.nodes.get(parent).?.children.contains(id));
            try testing.expect(path_cmp.eql(std.Io.Dir.path.dirname(node.path).?, tree.nodes.get(parent).?.path));
        } else {
            try testing.expect(path_cmp.eql(node.path, tree.watchRoot(node.watch)));
        }
        for (node.children.keys()) |child| try testing.expectEqual(id, tree.nodes.get(child).?.parent.?);
    }
}

test "removing a directory drops its subtree and only it, and says which nodes went" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "gone/deeper");
    try tmp.dir.createDirPath(io, "kept");
    try tmp.dir.createDirPath(io, "gone-sibling");
    for ([_][]const u8{ "gone/a", "gone/deeper/b", "kept/c", "gone-sibling/d", "e" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var tree: Tree = .init(gpa, 4096, true);
    defer tree.deinit(io);
    tree.keeps_dropped = true;
    var batch: Batch = .init(.{});
    defer batch.deinit(gpa);
    var added: std.ArrayList(NodeId) = .empty;
    defer added.deinit(gpa);
    const id: WatchId = @fromBackingInt(@intCast(0));
    try tree.addWatch(io, id, root, .{ .recursive = true }, &added, &batch);
    // The root, four directories and five files.
    try testing.expectEqual(@as(usize, 10), tree.nodes.count());
    try expectLinked(&tree);
    tree.clearDropped();

    const gone = try std.Io.Dir.path.join(gpa, &.{ root, "gone" });
    defer gpa.free(gone);
    tree.removeSubtree(io, id, gone);
    try expectLinked(&tree);
    try testing.expectEqual(@as(usize, 6), tree.nodes.count());
    try testing.expectEqual(@as(usize, 4), tree.takeDropped().?.len);
    for (tree.takeDropped().?) |dropped| try testing.expect(!tree.nodes.contains(dropped));
    for (tree.nodes.values()) |node| try testing.expect(!path_cmp.within(gone, node.path));
    for ([_][]const u8{ "gone-sibling", "gone-sibling/d", "kept/c", "e" }) |name| {
        const path = try std.Io.Dir.path.join(gpa, &.{ root, name });
        defer gpa.free(path);
        try testing.expect(tree.hasNode(id, path));
    }
    // A path with no node has nothing below it to drop.
    tree.removeSubtree(io, id, gone);
    try testing.expectEqual(@as(usize, 6), tree.nodes.count());

    tree.clearDropped();
    tree.removeWatch(io, id);
    try testing.expectEqual(@as(usize, 0), tree.nodes.count());
    try testing.expectEqual(@as(usize, 0), tree.index.count());
    try testing.expectEqual(@as(usize, 6), tree.takeDropped().?.len);
}

test "a name that comes back as another kind replaces its node" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "name", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var tree: Tree = .init(gpa, 4096, true);
    defer tree.deinit(io);
    var batch: Batch = .init(.{});
    defer batch.deinit(gpa);
    var added: std.ArrayList(NodeId) = .empty;
    defer added.deinit(gpa);
    try tree.addWatch(io, @fromBackingInt(@intCast(0)), root, .{ .recursive = true }, &added, &batch);
    const directory = added.items[0];
    try testing.expectEqual(@as(usize, 2), tree.nodes.count());

    try tmp.dir.deleteFile(io, "name");
    try tmp.dir.createDirPath(io, "name");
    try tmp.dir.writeFile(io, .{ .sub_path = "name/inside", .data = "y" });
    added.clearRetainingCapacity();
    try tree.rescanDirectory(io, directory, &batch, &added);
    try expectLinked(&tree);
    // The root, the directory where the file was, and the file in it.
    try testing.expectEqual(@as(usize, 3), tree.nodes.count());
    const name = try std.Io.Dir.path.join(gpa, &.{ root, "name" });
    defer gpa.free(name);
    try testing.expectEqual(Node.Role.directory, tree.nodes.get(tree.index.get(.{ .watch = @fromBackingInt(@intCast(0)), .path = name }).?).?.role);
}
