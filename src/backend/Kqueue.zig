//! The BSD backend: `kqueue` with the `EVFILT_VNODE` filter.
//!
//! `EVFILT_VNODE` watches an open descriptor, not a name, and it reports
//! that a directory changed without saying which entry changed. So this
//! backend holds one descriptor per watched file and per watched
//! directory, and answers "which entry" by re-listing the directory and
//! comparing it against `Snapshot` — the same comparison the `poll`
//! backend makes, driven by the kernel instead of by a timer.
//!
//! Two consequences follow from watching descriptors:
//!
//! * A watched tree costs one descriptor per directory, against the
//!   per-process descriptor limit.
//! * A watched file that is replaced rather than written — the
//!   write-to-temporary-and-rename an editor does — reports `renamed` or
//!   `removed` and then stops producing events, because the descriptor
//!   still refers to the old file. Watch the containing directory to
//!   follow a path rather than a file.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;

const lookout = @import("../types.zig");
const Batch = @import("../Batch.zig");
const Deadline = @import("../Deadline.zig");
const Tree = @import("../Tree.zig");
const Waker = @import("../Waker.zig");
const Options = @import("../options.zig").Options;
const contract = @import("../watch_contract.zig");
const AddOptions = @import("../options.zig").AddOptions;
const WatchId = lookout.WatchId;

const Kqueue = @This();

gpa: Allocator,
/// The kqueue descriptor, which is what `lookout.Watcher.fd` hands out.
kq: posix.fd_t,
tree: Tree,
/// Only registrations the kernel has accepted. Files own their descriptor
/// here; directory descriptors remain owned by Tree. A node missing from
/// this table still needs registration, even after its creation was scanned.
registrations: std.array_hash_map.Auto(Tree.NodeId, Registration),
retry_registration: bool = false,

/// EV_CLEAR has already removed these flags from the kernel queue.
/// Keep the delivery and its position across failed reporting attempts.
delivery: [events_per_call]posix.Kevent = undefined,
delivery_len: usize = 0,
delivery_at: usize = 0,

const Registration = struct {
    fd: posix.fd_t,
    owns_file: bool,
};

/// Everything `EVFILT_VNODE` can report. lookout asks for all of it and
/// decides what to do with each bit when it arrives.
const interest: u32 = std.c.NOTE.DELETE | std.c.NOTE.WRITE | std.c.NOTE.EXTEND |
    std.c.NOTE.ATTRIB | std.c.NOTE.LINK | std.c.NOTE.RENAME | std.c.NOTE.REVOKE;

/// How many events one `kevent` call collects. A larger batch costs a
/// larger stack frame; the kernel keeps whatever does not fit.
const events_per_call = 64;

/// The identifier of the user event `wake` triggers. An `EVFILT_USER`
/// identifier shares no namespace with the descriptors `EVFILT_VNODE`
/// uses, so any value will do and this one is the first.
const wake_ident: usize = 1;

/// `O_EVTONLY` on Darwin opens a descriptor that does not count as a
/// reference for unmounting, which is what a watcher wants. The other BSDs
/// have no equivalent.
const file_open_flags: posix.O = switch (builtin.target.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => .{
        .ACCMODE = .RDONLY,
        .EVTONLY = true,
        .CLOEXEC = true,
    },
    else => .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
};

/// Creates the kernel queue.
pub fn init(gpa: Allocator, options: Options) contract.InitError!Kqueue {
    const rc = std.c.kqueue();
    if (rc < 0) return switch (posix.errno(rc)) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
    var k: Kqueue = .{
        .gpa = gpa,
        .kq = rc,
        .tree = .init(gpa, options.max_dir_entries, true),
        .registrations = .empty,
    };
    // A file's descriptor is this backend's, and goes with its node.
    k.tree.keeps_dropped = true;
    // The one thing on this queue that is not a file: how another
    // thread makes a blocked `wait` come back.
    const change: posix.Kevent = .{
        .ident = wake_ident,
        .filter = std.c.EVFILT.USER,
        .flags = std.c.EV.ADD | std.c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    if (std.c.kevent(k.kq, (&change)[0..1], 1, undefined, 0, null) < 0) {
        _ = std.c.close(k.kq);
        return error.Unexpected;
    }
    return k;
}

/// Closes the kernel queue and every watched descriptor.
pub fn deinit(k: *Kqueue, io: Io) void {
    for (k.registrations.values()) |registration| {
        if (registration.owns_file) _ = std.c.close(registration.fd);
    }
    k.registrations.deinit(k.gpa);
    k.tree.deinit(io);
    _ = std.c.close(k.kq);
    k.* = undefined;
}

/// The kqueue descriptor. Readable exactly when `lookout.Watcher.poll` has
/// something to report.
pub fn fd(k: *const Kqueue) ?posix.fd_t {
    return k.kq;
}

/// How another thread pokes a blocked `wait`: the kernel queue itself,
/// which is fixed for the life of the watcher. See
/// `lookout.Watcher.wake`.
pub fn waker(k: *const Kqueue) Waker {
    return .{ .context = @intCast(k.kq), .call = trigger };
}

/// Triggers the user event a blocked `wait` is also listening for.
fn trigger(context: usize) void {
    const change: posix.Kevent = .{
        .ident = wake_ident,
        .filter = std.c.EVFILT.USER,
        .flags = 0,
        .fflags = std.c.NOTE.TRIGGER,
        .data = 0,
        .udata = 0,
    };
    _ = std.c.kevent(@intCast(context), (&change)[0..1], 1, undefined, 0, null);
}

/// How many paths the kernel queue has accepted. Nodes awaiting a retry
/// are not registrations yet. See `lookout.Watcher.Stats`.
pub fn registrationCount(k: *const Kqueue) usize {
    return k.registrations.count();
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(
    k: *Kqueue,
    io: Io,
    id: WatchId,
    abs_path: []const u8,
    options: AddOptions,
    batch: *Batch,
) contract.AddError!void {
    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(k.gpa);
    // A watch the kernel only half accepted is worse than none: it would
    // report a fraction of a tree and look like a quiet one.
    errdefer k.remove(io, id);

    try k.tree.addWatch(io, id, abs_path, options, &added, batch);
    try k.register(io, added.items, batch);
}

/// Stops watching `id` and closes its descriptors.
pub fn remove(k: *Kqueue, io: Io, id: WatchId) void {
    k.tree.removeWatch(io, id);
    k.closeOrphanedRegistrations();
}

/// Reconciles descriptors with a live watch's new filter.
pub fn refilter(k: *Kqueue, io: Io, id: WatchId, filter: lookout.Filter, batch: *Batch) contract.RefilterError!void {
    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(k.gpa);
    try k.tree.refilter(io, id, filter, &added, batch);
    try k.register(io, added.items, batch);
    k.closeOrphanedRegistrations();
}

/// Waits on the kernel queue until it reports something `batch` did not
/// already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(k: *Kqueue, io: Io, batch: *Batch, timeout_ms: ?u32) contract.PollError!void {
    // `kevent` both waits and takes the events off the queue, so once it
    // has returned, what it returned is recorded before anything stops:
    // see `Watcher.poll`. The wait itself is out of `std.Io`'s reach.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    const before = batch.revision;
    if (k.retry_registration) try k.retryRegistrations(io, batch);
    const deadline: Deadline = .fromMs(io, timeout_ms);

    while (true) {
        const woken = try k.drain(io, batch);
        if (woken or batch.revision != before) return;
        // The one thing the shared deadline does not hand out: this is
        // the only backend that wants a `timespec`, and Windows gives
        // the name no shape to build one from.
        var storage: std.c.timespec = undefined;
        const timeout_ptr: ?*const std.c.timespec = ptr: {
            const remaining = deadline.remainingMs(io) orelse break :ptr null;
            storage = .{
                .sec = @intCast(remaining / std.time.ms_per_s),
                .nsec = @intCast((remaining % std.time.ms_per_s) * std.time.ns_per_ms),
            };
            break :ptr &storage;
        };

        const empty: [0]posix.Kevent = .{};
        const count = std.c.kevent(k.kq, &empty, 0, &k.delivery, k.delivery.len, timeout_ptr);
        if (count < 0) switch (posix.errno(count)) {
            .INTR => continue,
            else => return error.Unexpected,
        };
        if (count == 0 and timeout_ptr != null) return;

        k.delivery_len = @intCast(count);
        k.delivery_at = 0;
    }
}

fn drain(k: *Kqueue, io: Io, batch: *Batch) contract.PollError!bool {
    var woken = false;
    while (k.delivery_at < k.delivery_len) : (k.delivery_at += 1) {
        const event = k.delivery[k.delivery_at];
        if (event.filter == std.c.EVFILT.USER) {
            woken = true;
            continue;
        }
        try k.handle(io, event, batch);
    }
    k.delivery_len = 0;
    k.delivery_at = 0;
    return woken;
}

/// Turns one kernel event into lookout events.
fn handle(k: *Kqueue, io: Io, event: posix.Kevent, batch: *Batch) contract.PollError!void {
    // A C/OS boundary: `udata` is the node id given at registration.
    const node_id: Tree.NodeId = .fromRaw(event.udata);
    const node = k.tree.nodes.get(node_id) orelse return;
    const flags = event.fflags;

    // The path is copied first: reporting the disappearance of a node is
    // also what frees it.
    const path = try k.gpa.dupe(u8, node.path);
    defer k.gpa.free(path);
    const watch = node.watch;
    const target: lookout.Target = switch (node.role) {
        .directory => .directory,
        .file => .file,
    };

    const gone: ?lookout.Kind = gone: {
        if (flags & (std.c.NOTE.DELETE | std.c.NOTE.REVOKE) != 0) break :gone .removed;
        if (flags & std.c.NOTE.RENAME != 0) break :gone .renamed;
        break :gone null;
    };
    if (gone) |kind| {
        try batch.push(k.gpa, io, watch, path, kind, target);
        k.tree.removeSubtree(io, watch, path);
        k.closeOrphanedRegistrations();
        return;
    }

    switch (node.role) {
        .directory => {
            if (flags & (std.c.NOTE.WRITE | std.c.NOTE.EXTEND) != 0) {
                var added: std.ArrayList(Tree.NodeId) = .empty;
                defer added.deinit(k.gpa);
                try k.tree.rescanDirectory(io, node_id, batch, &added);
                k.closeOrphanedRegistrations();
                k.register(io, added.items, batch) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // The descriptor limit, reached while registering
                    // the path the caller named. `register` has already
                    // said which paths it could not take.
                    else => {},
                };
            }
            // NOTE_LINK on a directory only says its subdirectory count
            // moved, which the listing already reports as a creation or a
            // removal, so only a real metadata change is an event here.
            if (flags & std.c.NOTE.ATTRIB != 0) {
                try batch.push(k.gpa, io, watch, path, .attributes, target);
            }
        },
        .file => {
            if (flags & (std.c.NOTE.WRITE | std.c.NOTE.EXTEND) != 0) {
                try batch.push(k.gpa, io, watch, path, .modified, target);
            }
            if (flags & (std.c.NOTE.ATTRIB | std.c.NOTE.LINK) != 0) {
                try batch.push(k.gpa, io, watch, path, .attributes, target);
            }
        },
    }
}

/// Tells the kernel about newly created nodes.
fn register(k: *Kqueue, io: Io, ids: []const Tree.NodeId, batch: *Batch) contract.AddError!void {
    errdefer k.retry_registration = true;
    for (ids) |id| {
        if (k.registrations.contains(id)) continue;
        const node = k.tree.nodes.get(id) orelse continue;
        // Reserve the ownership handoff before asking the kernel.
        try k.registrations.ensureUnusedCapacity(k.gpa, 1);
        const target: posix.fd_t = switch (node.role) {
            .directory => node.dir.handle,
            .file => file: {
                const opened = posix.openat(posix.AT.FDCWD, node.path, file_open_flags, 0) catch |err| {
                    // Failing to watch the path the caller named is an
                    // error. Failing to watch a file that merely happens
                    // to sit inside a watched directory is not: the
                    // directory still reports it appearing, disappearing
                    // and being renamed, and this is the path a process
                    // near its descriptor limit takes.
                    if (std.mem.eql(u8, node.path, k.tree.watchRoot(node.watch)))
                        return translateOpen(err);
                    try batch.trouble(k.gpa, io, node.watch, node.path, .file);
                    k.tree.removeSubtree(io, node.watch, node.path);
                    continue;
                };
                break :file opened;
            },
        };
        var installed = false;
        defer if (node.role == .file and !installed) {
            _ = std.c.close(target);
        };
        const change: posix.Kevent = .{
            .ident = @intCast(target),
            .filter = std.c.EVFILT.VNODE,
            // EV_CLEAR: report the flags accumulated since the last read
            // and then reset them, so a quiet file does not keep waking us.
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
            .fflags = interest,
            .data = 0,
            // A C/OS boundary: the kernel hands this back with the event.
            .udata = id.raw(),
        };
        const rc = std.c.kevent(k.kq, (&change)[0..1], 1, undefined, 0, null);
        if (rc < 0) {
            const root = std.mem.eql(u8, node.path, k.tree.watchRoot(node.watch));
            switch (posix.errno(rc)) {
                .NOMEM => {
                    if (root) return error.WatchLimitReached;
                    try batch.trouble(k.gpa, io, node.watch, node.path, .directory);
                    k.tree.removeSubtree(io, node.watch, node.path);
                    continue;
                },
                .NOENT, .BADF => continue,
                else => return error.Unexpected,
            }
        }
        k.registrations.putAssumeCapacity(id, .{ .fd = target, .owns_file = node.role == .file });
        installed = true;
    }
}

/// Reconciles an interrupted registration pass without depending on the
/// caller's temporary list of newly created nodes. Only failures need
/// this full traversal; ordinary waits still do work per kernel event.
fn retryRegistrations(k: *Kqueue, io: Io, batch: *Batch) contract.PollError!void {
    k.closeOrphanedRegistrations();
    var i: usize = 0;
    while (i < k.tree.nodes.count()) {
        const id = k.tree.nodes.keys()[i];
        k.register(io, &.{id}, batch) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unexpected => return error.Unexpected,
            else => {},
        };
        if (k.tree.nodes.contains(id)) i += 1;
    }
    k.retry_registration = false;
}

/// Closes the file descriptors of nodes the tree no longer holds. Closing
/// a descriptor is also what removes its registration from the queue, so
/// there is nothing else to undo.
///
/// The tree says which nodes went, so this costs what went rather than
/// a pass over every registration after every event; only when it could
/// not keep that list are all of them compared with the tree.
fn closeOrphanedRegistrations(k: *Kqueue) void {
    defer k.tree.clearDropped();
    const dropped = k.tree.takeDropped() orelse {
        var i: usize = 0;
        while (i < k.registrations.count()) {
            if (k.tree.nodes.contains(k.registrations.keys()[i])) {
                i += 1;
            } else {
                k.release(i);
            }
        }
        return;
    };
    for (dropped) |id| {
        const at = k.registrations.getIndex(id) orelse continue;
        k.release(at);
    }
}

fn release(k: *Kqueue, at: usize) void {
    const registration = k.registrations.values()[at];
    if (registration.owns_file) _ = std.c.close(registration.fd);
    k.registrations.swapRemoveAt(at);
}

/// Maps the POSIX open errors onto the error set `lookout.Watcher.add`
/// publishes, which is the same on every backend.
fn translateOpen(err: posix.OpenError) contract.AddError {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.NotDir => error.NotDir,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.SymLinkLoop => error.SymLinkLoop,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.NoDevice => error.NoDevice,
        else => error.Unexpected,
    };
}

test "allocation failure during delivery retains unread kqueue flags" {
    const io = std.testing.io;
    const testing = std.testing;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "first", .data = "x" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "last", .data = "x" });
        const first = try tmp.dir.realPathFileAlloc(testing.io, "first", testing.allocator);
        defer testing.allocator.free(first);
        const last = try tmp.dir.realPathFileAlloc(testing.io, "last", testing.allocator);
        defer testing.allocator.free(last);
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var k = try Kqueue.init(failing.allocator(), .{});
        defer k.deinit(io);
        var batch = Batch.init(.{});
        defer batch.deinit(failing.allocator());
        try k.add(io, .fromRaw(0), first, .{}, &batch);
        try k.add(io, .fromRaw(1), last, .{}, &batch);
        try k.wait(io, &batch, 0);
        batch.reset(failing.allocator());
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "first", .data = "changed" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "last", .data = "changed" });
        failing.fail_index = failing.alloc_index + fail_index;
        const answer = k.wait(io, &batch, 0);
        failing.fail_index = std.math.maxInt(usize);
        if (answer) |_| break else |err| try testing.expectEqual(error.OutOfMemory, err);
        try k.wait(io, &batch, 0);
        var saw_first = false;
        var saw_last = false;
        for (batch.events.items) |event| {
            if (std.mem.eql(u8, event.path, first)) saw_first = true;
            if (std.mem.eql(u8, event.path, last)) saw_last = true;
        }
        try testing.expect(saw_first and saw_last);
    }
    try testing.expect(fail_index > 0);
}

test "a failed kqueue registration is retried before waiting again" {
    const io = std.testing.io;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var k = try Kqueue.init(failing.allocator(), .{});
    defer k.deinit(io);
    var batch = Batch.init(.{});
    defer batch.deinit(failing.allocator());
    try k.add(io, .fromRaw(0), root, .{ .recursive = true }, &batch);
    const parent = k.tree.nodes.keys()[0];
    try tmp.dir.createDirPath(testing.io, "child");
    for (0..40) |i| {
        var name: [64]u8 = undefined;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.mem.print(&name, "child/file{d}", .{i}), .data = "one" });
    }
    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(failing.allocator());
    try k.tree.rescanDirectory(io, parent, &batch, &added);
    // The snapshot is now committed, but the kernel has not accepted
    // these nodes. A later scan cannot rediscover their creation.
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, k.register(io, added.items, &batch));
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(k.registrations.count(), k.registrationCount());
    try k.wait(io, &batch, 0);
    batch.reset(failing.allocator());
    for (0..40) |i| {
        var name: [64]u8 = undefined;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.mem.print(&name, "child/file{d}", .{i}), .data = "changed size" });
    }
    try k.wait(io, &batch, 0);
    var modified: usize = 0;
    for (batch.events.items) |event| {
        if (event.kind == .modified) modified += 1;
    }
    try testing.expectEqual(@as(usize, 40), modified);
}
