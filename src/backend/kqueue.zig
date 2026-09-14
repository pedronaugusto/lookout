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

const lookout = @import("../lookout.zig");
const Batch = @import("../Batch.zig");
const Tree = @import("../Tree.zig");
const WatchId = lookout.WatchId;

const Kqueue = @This();

gpa: Allocator,
io: Io,
/// The kqueue descriptor, which is what `lookout.Watcher.fd` hands out.
kq: posix.fd_t,
tree: Tree,
/// The descriptors opened for watched files. Directories are registered
/// through the handle `Tree` already holds open.
file_fds: std.AutoArrayHashMapUnmanaged(Tree.NodeId, posix.fd_t),

/// Everything `EVFILT_VNODE` can report. lookout asks for all of it and
/// decides what to do with each bit when it arrives.
const interest: u32 = std.c.NOTE.DELETE | std.c.NOTE.WRITE | std.c.NOTE.EXTEND |
    std.c.NOTE.ATTRIB | std.c.NOTE.LINK | std.c.NOTE.RENAME | std.c.NOTE.REVOKE;

/// How many events one `kevent` call collects. A larger batch costs a
/// larger stack frame; the kernel keeps whatever does not fit.
const events_per_call = 64;

/// `O_EVTONLY` on Darwin opens a descriptor that does not count as a
/// reference for unmounting, which is what a watcher wants. The other BSDs
/// have no equivalent.
const file_open_flags: posix.O = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => .{
        .ACCMODE = .RDONLY,
        .EVTONLY = true,
        .CLOEXEC = true,
    },
    else => .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
};

/// Creates the kernel queue.
pub fn init(gpa: Allocator, io: Io, options: lookout.Options) lookout.Watcher.InitError!Kqueue {
    const rc = std.c.kqueue();
    if (rc < 0) return switch (posix.errno(rc)) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
    return .{
        .gpa = gpa,
        .io = io,
        .kq = rc,
        .tree = .init(gpa, io, options.max_dir_entries, true),
        .file_fds = .empty,
    };
}

/// Closes the kernel queue and every watched descriptor.
pub fn deinit(k: *Kqueue) void {
    for (k.file_fds.values()) |file_fd| _ = std.c.close(file_fd);
    k.file_fds.deinit(k.gpa);
    k.tree.deinit();
    _ = std.c.close(k.kq);
    k.* = undefined;
}

/// The kqueue descriptor. Readable exactly when `lookout.Watcher.poll` has
/// something to report.
pub fn fd(k: *const Kqueue) ?posix.fd_t {
    return k.kq;
}

/// How many watches the caller has added. See `lookout.Watcher.Stats`.
pub fn watchCount(k: *const Kqueue) usize {
    return k.tree.watches.count();
}

/// How many descriptors this backend holds open for watched paths. See
/// `lookout.Watcher.Stats`.
pub fn registrationCount(k: *const Kqueue) usize {
    return k.tree.nodes.count();
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(k: *Kqueue, id: WatchId, abs_path: []const u8, options: lookout.AddOptions) lookout.Watcher.AddError!void {
    var added: std.ArrayList(Tree.NodeId) = .empty;
    defer added.deinit(k.gpa);
    // A watch the kernel only half accepted is worse than none: it would
    // report a fraction of a tree and look like a quiet one.
    errdefer k.remove(id);

    try k.tree.addWatch(id, abs_path, options, &added);
    try k.register(added.items);
}

/// Stops watching `id` and closes its descriptors.
pub fn remove(k: *Kqueue, id: WatchId) void {
    k.tree.removeWatch(id);
    k.closeOrphanedFiles();
}

/// Waits on the kernel queue until it reports something `batch` did not
/// already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(k: *Kqueue, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const before = batch.revision;
    const started: Io.Timestamp = .now(k.io, .awake);

    while (true) {
        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still performs one non-blocking call. Returning early here would
        // make `poll(0)` report nothing, ever.
        var timeout: std.c.timespec = undefined;
        const timeout_ptr: ?*const std.c.timespec = ptr: {
            const total = timeout_ms orelse break :ptr null;
            const elapsed = started.durationTo(Io.Timestamp.now(k.io, .awake)).toMilliseconds();
            const remaining: u64 = @intCast(@max(0, @as(i64, total) - elapsed));
            timeout = .{
                .sec = @intCast(remaining / std.time.ms_per_s),
                .nsec = @intCast((remaining % std.time.ms_per_s) * std.time.ns_per_ms),
            };
            break :ptr &timeout;
        };

        var events: [events_per_call]posix.Kevent = undefined;
        const empty: [0]posix.Kevent = .{};
        const count = std.c.kevent(k.kq, &empty, 0, &events, events.len, timeout_ptr);
        if (count < 0) switch (posix.errno(count)) {
            .INTR => continue,
            else => return error.Unexpected,
        };
        if (count == 0 and timeout_ptr != null) return;

        for (events[0..@intCast(count)]) |event| try k.handle(event, batch);
        if (batch.revision != before) return;
    }
}

/// Turns one kernel event into lookout events.
fn handle(k: *Kqueue, event: posix.Kevent, batch: *Batch) lookout.Watcher.PollError!void {
    const node_id: Tree.NodeId = @enumFromInt(event.udata);
    const node = k.tree.nodes.get(node_id) orelse return;
    const flags = event.fflags;

    // The path is copied first: reporting the disappearance of a node is
    // also what frees it.
    const path = try k.gpa.dupe(u8, node.path);
    defer k.gpa.free(path);
    const watch = node.watch;

    const gone: ?lookout.Kind = gone: {
        if (flags & (std.c.NOTE.DELETE | std.c.NOTE.REVOKE) != 0) break :gone .removed;
        if (flags & std.c.NOTE.RENAME != 0) break :gone .renamed;
        break :gone null;
    };
    if (gone) |kind| {
        try batch.push(k.gpa, watch, path, kind);
        k.tree.removeSubtree(path);
        k.closeOrphanedFiles();
        return;
    }

    switch (node.role) {
        .directory => {
            if (flags & (std.c.NOTE.WRITE | std.c.NOTE.EXTEND) != 0) {
                var added: std.ArrayList(Tree.NodeId) = .empty;
                defer added.deinit(k.gpa);
                try k.tree.rescanDirectory(node_id, batch, &added);
                k.closeOrphanedFiles();
                k.register(added.items) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // A subdirectory that cannot be registered — the
                    // descriptor limit, or it is already gone — is
                    // reported through its parent and nothing below it.
                    else => {},
                };
            }
            // NOTE_LINK on a directory only says its subdirectory count
            // moved, which the listing already reports as a creation or a
            // removal, so only a real metadata change is an event here.
            if (flags & std.c.NOTE.ATTRIB != 0) {
                try batch.push(k.gpa, watch, path, .attributes);
            }
        },
        .file => {
            if (flags & (std.c.NOTE.WRITE | std.c.NOTE.EXTEND) != 0) {
                try batch.push(k.gpa, watch, path, .modified);
            }
            if (flags & (std.c.NOTE.ATTRIB | std.c.NOTE.LINK) != 0) {
                try batch.push(k.gpa, watch, path, .attributes);
            }
        },
    }
}

/// Tells the kernel about newly created nodes.
fn register(k: *Kqueue, ids: []const Tree.NodeId) lookout.Watcher.AddError!void {
    for (ids) |id| {
        const node = k.tree.nodes.get(id) orelse continue;
        const target: posix.fd_t = switch (node.role) {
            .directory => node.dir.handle,
            .file => file: {
                if (k.file_fds.get(id)) |existing| break :file existing;
                const opened = posix.openat(posix.AT.FDCWD, node.path, file_open_flags, 0) catch |err| {
                    // Failing to watch the path the caller named is an
                    // error. Failing to watch a file that merely happens
                    // to sit inside a watched directory is not: the
                    // directory still reports it appearing, disappearing
                    // and being renamed, and this is the path a process
                    // near its descriptor limit takes.
                    if (std.mem.eql(u8, node.path, k.tree.watchRoot(node.watch)))
                        return translateOpen(err);
                    k.tree.removeSubtree(node.path);
                    continue;
                };
                errdefer _ = std.c.close(opened);
                try k.file_fds.put(k.gpa, id, opened);
                break :file opened;
            },
        };
        const change: posix.Kevent = .{
            .ident = @intCast(target),
            .filter = std.c.EVFILT.VNODE,
            // EV_CLEAR: report the flags accumulated since the last read
            // and then reset them, so a quiet file does not keep waking us.
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
            .fflags = interest,
            .data = 0,
            .udata = @intFromEnum(id),
        };
        const rc = std.c.kevent(k.kq, (&change)[0..1], 1, undefined, 0, null);
        if (rc < 0) return switch (posix.errno(rc)) {
            .NOMEM => error.WatchLimitReached,
            .NOENT, .BADF => continue,
            else => error.Unexpected,
        };
    }
}

/// Closes the file descriptors of nodes the tree no longer holds. Closing
/// a descriptor is also what removes its registration from the queue, so
/// there is nothing else to undo.
fn closeOrphanedFiles(k: *Kqueue) void {
    var i: usize = 0;
    while (i < k.file_fds.count()) {
        if (k.tree.nodes.contains(k.file_fds.keys()[i])) {
            i += 1;
        } else {
            _ = std.c.close(k.file_fds.values()[i]);
            k.file_fds.swapRemoveAt(i);
        }
    }
}

/// Maps the POSIX open errors onto the error set `lookout.Watcher.add`
/// publishes, which is the same on every backend.
fn translateOpen(err: posix.OpenError) lookout.Watcher.AddError {
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
