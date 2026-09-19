//! The portable backend: re-stat and re-list the watched paths on a timer.
//!
//! It needs nothing from the kernel, so it is the backend on every target
//! lookout has no notification mechanism for, and it is selectable
//! everywhere else, which is what lets one test suite hold every backend
//! to the same contract.
//!
//! The costs are the obvious ones: a change is seen up to
//! `lookout.Options.poll_interval_ms` after it happens, every watched
//! directory is listed and stat-ed on every tick, and a file created and
//! deleted between two ticks is never seen at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const lookout = @import("../lookout.zig");
const Batch = @import("../Batch.zig");
const Deadline = @import("../Deadline.zig");
const Snapshot = @import("../Snapshot.zig");
const Tree = @import("../Tree.zig");
const path_cmp = @import("../path.zig");
const WatchId = lookout.WatchId;

const Poll = @This();

gpa: Allocator,
io: Io,
interval_ms: u32,
tree: Tree,
/// Set by `wake` from another thread. There is nothing to interrupt
/// here, only a sleep to cut short, so the sleep is taken in slices and
/// this is read between them.
woken: std.atomic.Value(bool),

/// The longest this backend sleeps without looking at `woken`. A wake
/// is answered within this even when `poll_interval_ms` is minutes.
const slice_ms = 100;

/// Creates a backend that watches nothing. Never actually fails -- this
/// backend holds no kernel resource -- and returns the error union every
/// backend returns, so that `lookout.Watcher.init` can treat them alike.
pub fn init(gpa: Allocator, io: Io, options: lookout.Options) lookout.Watcher.InitError!Poll {
    return .{
        .gpa = gpa,
        .io = io,
        .interval_ms = options.poll_interval_ms,
        .tree = .init(gpa, io, options.max_dir_entries, false),
        .woken = .init(false),
    };
}

/// Releases the watch tables and the directory handles they hold open.
pub fn deinit(p: *Poll) void {
    p.tree.deinit();
    p.* = undefined;
}

/// No descriptor: this backend has nothing to wait on, so a program
/// cannot fold it into a wait loop of its own and must call
/// `lookout.Watcher.poll`.
pub fn fd(p: *const Poll) ?std.posix.fd_t {
    _ = p;
    return null;
}

/// Nothing to resume from: a listing comparison has no sequence of its
/// own to name a point in. See `lookout.tracksPosition`.
pub fn position(p: *const Poll) ?u64 {
    _ = p;
    return null;
}

/// Cuts the sleep short. See `lookout.Watcher.wake`.
pub fn wake(p: *Poll) void {
    p.woken.store(true, .release);
}

/// How many paths this backend re-lists or re-stats on every tick. See
/// `lookout.Watcher.Stats`.
pub fn registrationCount(p: *const Poll) usize {
    return p.tree.nodes.count();
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(
    p: *Poll,
    id: WatchId,
    abs_path: []const u8,
    options: lookout.AddOptions,
    batch: *Batch,
) lookout.Watcher.AddError!void {
    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(p.gpa);
    try p.tree.addWatch(id, abs_path, options, &added, batch);
}

/// Stops watching `id`.
pub fn remove(p: *Poll, id: WatchId) void {
    p.tree.removeWatch(id);
}

/// Scans, then sleeps and scans again until the scan produces an event
/// `batch` did not already hold or `timeout_ms` expires. `null` never
/// gives up.
pub fn wait(p: *Poll, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const before = batch.revision;
    const deadline: Deadline = .start(p.io, timeout_ms);

    while (true) {
        try p.scan(batch);
        if (batch.revision != before) return;
        if (p.woken.swap(false, .acquire)) return;

        var napped: u32 = 0;
        const nap_ms = nap: {
            const remaining = deadline.remainingMs() orelse break :nap p.interval_ms;
            if (remaining == 0) return;
            break :nap @min(p.interval_ms, remaining);
        };
        // Slept in slices so that `wake` is answered without waiting out
        // a whole tick, which on a long interval is a long time.
        while (napped < nap_ms) {
            const slice = @min(slice_ms, nap_ms - napped);
            try p.io.sleep(.fromMilliseconds(slice), .awake);
            napped += slice;
            if (p.woken.load(.acquire)) break;
        }
    }
}

/// Re-examines every watched path once.
fn scan(p: *Poll, batch: *Batch) Tree.ScanError!void {
    try p.checkRoots(batch);

    // The node list is copied first: a scan can both add nodes, when a
    // recursive watch sees a new subdirectory, and drop them, when a
    // watched directory disappears.
    var ids: std.ArrayList(Tree.NodeId) = .empty;
    defer ids.deinit(p.gpa);
    try ids.appendSlice(p.gpa, p.tree.nodes.keys());

    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(p.gpa);

    for (ids.items) |id| {
        const role = (p.tree.nodes.get(id) orelse continue).role;
        switch (role) {
            .directory => try p.tree.rescanDirectory(id, batch, &added),
            .file => try p.tree.rescanFile(id, batch),
        }
    }
}

/// Reports a watch root that is no longer there, and stops watching
/// below it.
///
/// A directory node is listed through the handle opened for it, and on
/// POSIX that handle outlives the name: the listing of a deleted
/// directory still succeeds and still says nothing changed, so the one
/// disappearance the comparison cannot see is the watch's own. The name
/// is what the caller asked for, so the name is what is checked -- one
/// `stat` per watch per tick, which is nothing beside the listing the
/// tick is already doing.
///
/// A move is reported as `lookout.Kind.removed` rather than
/// `lookout.Kind.renamed`, because a comparison of names cannot tell the
/// two apart. See `lookout.reportsRootMove`.
fn checkRoots(p: *Poll, batch: *Batch) Tree.ScanError!void {
    var gone: std.ArrayList([]u8) = .empty;
    defer {
        for (gone.items) |path| p.gpa.free(path);
        gone.deinit(p.gpa);
    }

    for (p.tree.watches.keys(), p.tree.watches.values()) |id, watch| {
        // Only a watch that still has nodes: one already reported gone
        // keeps its id, and must not be reported twice.
        if (!p.hasNodes(id)) continue;
        _ = Io.Dir.cwd().statFile(p.io, watch.root, .{ .follow_symlinks = false }) catch {
            try gone.append(p.gpa, try p.gpa.dupe(u8, watch.root));
            continue;
        };
    }

    for (gone.items) |root| {
        try batch.push(p.gpa, p.watchOf(root), root, .removed, .directory);
        p.tree.removeSubtree(root);
    }
}

/// Whether any node of `id` is still registered.
fn hasNodes(p: *const Poll, id: WatchId) bool {
    for (p.tree.nodes.values()) |node| {
        if (node.watch == id) return true;
    }
    return false;
}

/// The watch whose root is `root`.
fn watchOf(p: *const Poll, root: []const u8) WatchId {
    for (p.tree.watches.keys(), p.tree.watches.values()) |id, watch| {
        if (path_cmp.eql(watch.root, root)) return id;
    }
    unreachable;
}
