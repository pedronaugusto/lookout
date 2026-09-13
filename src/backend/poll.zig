//! The portable backend: re-stat and re-list the watched paths on a timer.
//!
//! It needs nothing from the kernel, so it is the backend on every target
//! lookout has no notification mechanism for — Windows today — and it is
//! selectable everywhere else, which is what lets one test suite hold
//! every backend to the same contract.
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
const Snapshot = @import("../Snapshot.zig");
const Tree = @import("../Tree.zig");
const WatchId = lookout.WatchId;

const Poll = @This();

gpa: Allocator,
io: Io,
interval_ms: u32,
tree: Tree,

/// Creates a backend that watches nothing. Never actually fails -- this
/// backend holds no kernel resource -- and returns the error union every
/// backend returns, so that `lookout.Watcher.init` can treat them alike.
pub fn init(gpa: Allocator, io: Io, options: lookout.Options) lookout.Watcher.InitError!Poll {
    return .{
        .gpa = gpa,
        .io = io,
        .interval_ms = options.poll_interval_ms,
        .tree = .init(gpa, io, options.max_dir_entries, false),
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

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(p: *Poll, id: WatchId, abs_path: []const u8, options: lookout.AddOptions) lookout.Watcher.AddError!void {
    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(p.gpa);
    try p.tree.addWatch(id, abs_path, options.recursive, &added);
}

/// Stops watching `id`.
pub fn remove(p: *Poll, id: WatchId) void {
    p.tree.removeWatch(id);
}

/// Scans, then sleeps and scans again until the scan produces an event
/// `batch` did not already hold or `timeout_ms` expires. `null` never
/// gives up.
pub fn wait(p: *Poll, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const before = batch.events.items.len;
    const started: Io.Timestamp = .now(p.io, .awake);

    while (true) {
        try p.scan(batch);
        if (batch.events.items.len > before) return;

        const nap_ms = nap: {
            const timeout = timeout_ms orelse break :nap p.interval_ms;
            const elapsed = started.durationTo(Io.Timestamp.now(p.io, .awake)).toMilliseconds();
            if (elapsed >= timeout) return;
            const remaining: u32 = @intCast(@as(i64, timeout) - elapsed);
            break :nap @min(p.interval_ms, remaining);
        };
        if (nap_ms == 0) return;
        try p.io.sleep(.fromMilliseconds(nap_ms), .awake);
    }
}

/// Re-examines every watched path once.
fn scan(p: *Poll, batch: *Batch) Tree.ScanError!void {
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
