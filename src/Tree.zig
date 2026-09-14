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
const Io = std.Io;

const lookout = @import("lookout.zig");
const Batch = @import("Batch.zig");
const Filter = @import("Filter.zig");
const Snapshot = @import("Snapshot.zig");
const WatchId = lookout.WatchId;

const Tree = @This();

gpa: Allocator,
io: Io,
/// Mirrors `lookout.Options.max_dir_entries`.
max_dir_entries: usize,
/// Whether a directory node also gets a node per regular file inside it.
///
/// The `kqueue` backend needs this: `EVFILT_VNODE` on a directory fires
/// when an entry appears, disappears or is renamed, and says nothing when
/// an entry's contents change, so a file inside a watched directory is
/// only seen to be modified if it is watched itself. The `poll` backend
/// re-stats every entry anyway and leaves this off.
track_entries: bool,
/// Every registered path, keyed by an id that is never reused.
nodes: std.AutoArrayHashMapUnmanaged(NodeId, Node),
/// The caller's watches, keyed by the id `lookout.Watcher.add` returned.
watches: std.AutoArrayHashMapUnmanaged(WatchId, Watch),
next_node: u64,
/// Scratch reused by every scan so that a steady-state watcher does not
/// allocate per event.
changes: std.ArrayList(Snapshot.Change),

/// Identifies one registered path within one tree. Never reused, so a
/// stale kernel event naming a freed node simply finds nothing.
pub const NodeId = enum(u64) { _ };

/// What the caller asked for.
pub const Watch = struct {
    /// Absolute, canonical path, owned by the tree. This is the path
    /// `lookout.Kind.overflow` is reported against.
    root: []u8,
    /// `lookout.AddOptions.recursive`.
    recursive: bool,
    /// `lookout.AddOptions.filter`, copied: the patterns are borrowed
    /// only for the duration of the `add` that supplied them.
    filter: Filter,
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

    /// What a node stands for.
    pub const Role = enum { file, directory };
};

/// Errors adding a watch can return.
pub const AddError = error{
    /// This watcher already watches that path. See `lookout.Watcher.add`.
    PathAlreadyWatched,
} || Allocator.Error || Io.Dir.OpenError || Io.Dir.StatFileError ||
    Io.Dir.RealPathFileAllocError || Snapshot.RefreshError;

/// Errors rescanning a watch can return.
pub const ScanError = Allocator.Error || Snapshot.RefreshError;

/// A tree that holds nothing.
pub fn init(gpa: Allocator, io: Io, max_dir_entries: usize, track_entries: bool) Tree {
    return .{
        .gpa = gpa,
        .io = io,
        .max_dir_entries = max_dir_entries,
        .track_entries = track_entries,
        .nodes = .empty,
        .watches = .empty,
        .next_node = 0,
        .changes = .empty,
    };
}

/// Closes every directory handle and frees every path.
pub fn deinit(t: *Tree) void {
    for (t.nodes.values()) |*node| t.destroy(node);
    t.nodes.deinit(t.gpa);
    for (t.watches.values()) |*watch| {
        t.gpa.free(watch.root);
        watch.filter.deinit(t.gpa);
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
    id: WatchId,
    abs_path: []const u8,
    options: lookout.AddOptions,
    added: *std.ArrayList(NodeId),
) AddError!void {
    if (t.watched(abs_path)) return error.PathAlreadyWatched;
    const stat = try Io.Dir.cwd().statFile(t.io, abs_path, .{});
    const recursive = options.recursive;

    const root = try t.gpa.dupe(u8, abs_path);
    errdefer t.gpa.free(root);
    var filter = try options.filter.dupe(t.gpa);
    errdefer filter.deinit(t.gpa);
    try t.watches.put(t.gpa, id, .{ .root = root, .recursive = recursive, .filter = filter });
    errdefer _ = t.watches.swapRemove(id);

    const start = added.items.len;
    errdefer t.rollback(added, start);

    const node_path = try t.gpa.dupe(u8, abs_path);
    {
        // Scoped so that the node takes ownership on success and this
        // frees it on failure, without the two ever both happening.
        errdefer t.gpa.free(node_path);
        if (stat.kind != .directory) {
            _ = try t.createFile(id, node_path, .{
                .size = stat.size,
                .mtime_ns = stat.mtime.nanoseconds,
                .ctime_ns = stat.ctime.nanoseconds,
                .file_kind = stat.kind,
            }, added);
            return;
        }
        _ = try t.createDirectory(id, node_path, added);
    }
    if (!recursive) return;

    // The initial listing of each directory is the list of subdirectories
    // to descend into, so the walk costs no extra syscalls. The frontier
    // is an index into `added` rather than a pointer because creating a
    // node can rehash `nodes`.
    var frontier = start;
    while (frontier < added.items.len) : (frontier += 1) {
        try t.descend(added.items[frontier], added);
    }
}

/// Undoes the nodes one `addWatch` created, for an `addWatch` that fails
/// partway: a half-registered watch would report a fraction of a tree.
fn rollback(t: *Tree, added: *std.ArrayList(NodeId), start: usize) void {
    for (added.items[start..]) |node_id| {
        const node = t.nodes.getPtr(node_id) orelse continue;
        t.destroy(node);
        _ = t.nodes.swapRemove(node_id);
    }
    added.shrinkRetainingCapacity(start);
}

/// Creates a node for every subdirectory already listed in `parent`'s
/// snapshot.
fn descend(t: *Tree, parent_id: NodeId, added: *std.ArrayList(NodeId)) AddError!void {
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
        const child_path = try std.fs.path.join(t.gpa, &.{ parent_path, name });
        errdefer t.gpa.free(child_path);
        // An excluded directory is not opened and not registered, which
        // is the whole point of filtering here rather than on the way
        // out: the tree below it costs nothing.
        if (t.excluded(watch, child_path)) {
            t.gpa.free(child_path);
            continue;
        }
        _ = t.createDirectory(watch, child_path, added) catch |err| switch (err) {
            // A subdirectory that vanished between the listing and the
            // open is not an error; the parent's next scan reports it.
            error.FileNotFound, error.AccessDenied, error.NotDir => {
                t.gpa.free(child_path);
                continue;
            },
            else => |e| return e,
        };
    }
}

fn createDirectory(t: *Tree, watch: WatchId, path: []u8, added: *std.ArrayList(NodeId)) AddError!NodeId {
    var dir = try Io.Dir.openDirAbsolute(t.io, path, .{ .iterate = true });
    errdefer dir.close(t.io);

    const id: NodeId = @enumFromInt(t.next_node);
    try t.nodes.put(t.gpa, id, .{
        .watch = watch,
        .path = path,
        .role = .directory,
        .dir = dir,
        .snapshot = .empty,
        .meta = undefined,
    });
    errdefer _ = t.nodes.swapRemove(id);
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
    try node.snapshot.refresh(t.gpa, t.io, dir, t.max_dir_entries, &baseline);

    try added.append(t.gpa, id);
    if (t.track_entries) try t.trackEntries(id, added);
    return id;
}

/// Gives every regular file already listed in a directory node its own
/// node, so a backend that watches descriptors can watch them too.
fn trackEntries(t: *Tree, dir_id: NodeId, added: *std.ArrayList(NodeId)) AddError!void {
    var i: usize = 0;
    while (true) : (i += 1) {
        // Re-resolved each round: creating a node can rehash `nodes`.
        const dir_node = t.nodes.getPtr(dir_id) orelse return;
        if (i >= dir_node.snapshot.entries.count()) return;
        const meta = dir_node.snapshot.entries.values()[i];
        if (meta.file_kind != .file) continue;
        const name = dir_node.snapshot.entries.keys()[i];
        const child = try std.fs.path.join(t.gpa, &.{ dir_node.path, name });
        errdefer t.gpa.free(child);
        if (t.excluded(dir_node.watch, child)) {
            t.gpa.free(child);
            continue;
        }
        _ = try t.createFile(dir_node.watch, child, meta, added);
    }
}

fn createFile(t: *Tree, watch: WatchId, path: []u8, meta: Snapshot.Meta, added: *std.ArrayList(NodeId)) Allocator.Error!NodeId {
    const id: NodeId = @enumFromInt(t.next_node);
    try t.nodes.put(t.gpa, id, .{
        .watch = watch,
        .path = path,
        .role = .file,
        .dir = undefined,
        .snapshot = undefined,
        .meta = meta,
    });
    errdefer _ = t.nodes.swapRemove(id);
    t.next_node += 1;
    try added.append(t.gpa, id);
    return id;
}

/// Drops `id` and every node it created, releasing their descriptors.
/// Unknown ids are ignored.
pub fn removeWatch(t: *Tree, id: WatchId) void {
    var watch = t.watches.fetchSwapRemove(id) orelse return;
    t.gpa.free(watch.value.root);
    watch.value.filter.deinit(t.gpa);

    var i: usize = 0;
    while (i < t.nodes.count()) {
        if (t.nodes.values()[i].watch == id) {
            t.destroy(&t.nodes.values()[i]);
            t.nodes.swapRemoveAt(i);
        } else {
            i += 1;
        }
    }
}

/// Drops the node at `path` and every node below it. Used when a watched
/// directory itself disappears.
pub fn removeSubtree(t: *Tree, path: []const u8) void {
    var i: usize = 0;
    while (i < t.nodes.count()) {
        const node_path = t.nodes.values()[i].path;
        const inside = std.mem.eql(u8, node_path, path) or
            (node_path.len > path.len and
                std.mem.startsWith(u8, node_path, path) and
                node_path[path.len] == std.fs.path.sep);
        if (inside) {
            t.destroy(&t.nodes.values()[i]);
            t.nodes.swapRemoveAt(i);
        } else {
            i += 1;
        }
    }
}

fn destroy(t: *Tree, node: *Node) void {
    if (node.role == .directory) {
        node.dir.close(t.io);
        node.snapshot.deinit(t.gpa);
    }
    t.gpa.free(node.path);
}

/// Whether some watch already has `abs_path` as its root.
pub fn watched(t: *const Tree, abs_path: []const u8) bool {
    for (t.watches.values()) |watch| {
        if (std.mem.eql(u8, watch.root, abs_path)) return true;
    }
    return false;
}

/// The absolute path of the watch a node belongs to, for reporting
/// `lookout.Kind.overflow`.
pub fn watchRoot(t: *Tree, id: WatchId) []const u8 {
    return (t.watches.get(id) orelse return "").root;
}

/// Whether the watch a node belongs to asked for recursion.
pub fn isRecursive(t: *Tree, id: WatchId) bool {
    return (t.watches.get(id) orelse return false).recursive;
}

/// Whether `path` is outside what the watch `id` is about. See
/// `lookout.AddOptions.filter`.
pub fn excluded(t: *const Tree, id: WatchId, path: []const u8) bool {
    const watch = t.watches.get(id) orelse return false;
    return watch.filter.excludes(watch.root, path);
}

/// Re-lists the directory node `id`, pushes what changed into `batch`, and
/// appends the ids of nodes created for newly appeared subdirectories to
/// `added`.
///
/// A node whose directory has disappeared is dropped along with everything
/// below it, and reported as `lookout.Kind.removed`.
pub fn rescanDirectory(
    t: *Tree,
    id: NodeId,
    batch: *Batch,
    added: *std.ArrayList(NodeId),
) ScanError!void {
    return t.rescanOne(id, batch, added);
}

fn rescanOne(
    t: *Tree,
    id: NodeId,
    batch: *Batch,
    added: *std.ArrayList(NodeId),
) ScanError!void {
    const node = t.nodes.getPtr(id) orelse return;
    if (node.role != .directory) return;
    const watch = node.watch;
    const recursive = t.isRecursive(watch);

    Snapshot.freeChanges(t.gpa, &t.changes);
    defer Snapshot.freeChanges(t.gpa, &t.changes);
    node.snapshot.refresh(t.gpa, t.io, node.dir, t.max_dir_entries, &t.changes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The directory is gone, or is no longer a directory. Report it and
        // stop watching what is below it.
        else => {
            const path = try t.gpa.dupe(u8, node.path);
            defer t.gpa.free(path);
            try batch.push(t.gpa, watch, path, .removed);
            t.removeSubtree(path);
            return;
        },
    };

    if (t.nodes.getPtr(id).?.snapshot.truncated) {
        try batch.push(t.gpa, watch, t.watchRoot(watch), .overflow);
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

        const child = try std.fs.path.join(t.gpa, &.{ dir_path, change.name });
        defer t.gpa.free(child);
        // Excluded before it is reported and before a node is made for
        // it, so an excluded directory never becomes a registration.
        if (t.excluded(watch, child)) continue;
        try batch.push(t.gpa, watch, child, change.kind);

        if (change.file_kind == .file) {
            if (!t.track_entries) continue;
            switch (change.kind) {
                .created => {
                    const meta = (t.nodes.getPtr(id) orelse return).snapshot.entries.get(change.name) orelse continue;
                    const owned = try t.gpa.dupe(u8, child);
                    errdefer t.gpa.free(owned);
                    _ = try t.createFile(watch, owned, meta, added);
                },
                .removed => t.removeSubtree(child),
                else => {},
            }
            continue;
        }
        if (!recursive or change.file_kind != .directory) continue;
        switch (change.kind) {
            .created => try t.adopt(watch, child, batch, added),
            .removed => t.removeSubtree(child),
            else => {},
        }
    }
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
    watch: WatchId,
    root: []const u8,
    batch: *Batch,
    added: *std.ArrayList(NodeId),
) ScanError!void {
    var frontier: std.ArrayList([]u8) = .empty;
    defer {
        for (frontier.items) |path| t.gpa.free(path);
        frontier.deinit(t.gpa);
    }
    try frontier.append(t.gpa, try t.gpa.dupe(u8, root));

    var i: usize = 0;
    while (i < frontier.items.len) : (i += 1) {
        const current = frontier.items[i];
        const owned = try t.gpa.dupe(u8, current);
        const id = t.createDirectory(watch, owned, added) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Created and gone again, or not ours to open: reported
            // through its parent and no further.
            else => {
                t.gpa.free(owned);
                continue;
            },
        };

        var j: usize = 0;
        while (true) : (j += 1) {
            // Re-resolved each round: the node table is rehashed by the
            // next directory this loop creates.
            const node = t.nodes.getPtr(id) orelse break;
            if (j >= node.snapshot.entries.count()) break;
            const name = node.snapshot.entries.keys()[j];
            const file_kind = node.snapshot.entries.values()[j].file_kind;

            const entry = try std.fs.path.join(t.gpa, &.{ current, name });
            errdefer t.gpa.free(entry);
            if (t.excluded(watch, entry)) {
                t.gpa.free(entry);
                continue;
            }
            try batch.push(t.gpa, watch, entry, .created);
            if (file_kind == .directory) {
                try frontier.append(t.gpa, entry);
            } else {
                t.gpa.free(entry);
            }
        }
    }
}

/// Re-stats the file node `id` and pushes what changed into `batch`. Used
/// by the `poll` backend, which is told nothing by the kernel.
pub fn rescanFile(t: *Tree, id: NodeId, batch: *Batch) ScanError!void {
    const node = t.nodes.getPtr(id) orelse return;
    if (node.role != .file) return;

    const stat = Io.Dir.cwd().statFile(t.io, node.path, .{ .follow_symlinks = false }) catch {
        const path = try t.gpa.dupe(u8, node.path);
        defer t.gpa.free(path);
        try batch.push(t.gpa, node.watch, path, .removed);
        t.removeSubtree(path);
        return;
    };
    const before = node.meta;
    node.meta = .{
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .ctime_ns = stat.ctime.nanoseconds,
        .file_kind = stat.kind,
    };
    if (before.size != stat.size or before.mtime_ns != stat.mtime.nanoseconds) {
        try batch.push(t.gpa, node.watch, node.path, .modified);
    } else if (before.ctime_ns != stat.ctime.nanoseconds) {
        try batch.push(t.gpa, node.watch, node.path, .attributes);
    }
}
