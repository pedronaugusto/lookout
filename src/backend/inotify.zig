//! The Linux backend: `inotify`.
//!
//! The kernel names the entry that changed, so this backend keeps no
//! directory listings — only a table from kernel watch descriptor to the
//! path it stands for. A watched directory is one kernel watch; a
//! recursive watch is one kernel watch per directory, registered by
//! walking the tree at `add` time and extended as new directories appear.
//!
//! Two limits are worth knowing:
//!
//! * The number of watches is capped per user by
//!   `/proc/sys/fs/inotify/max_user_watches`. Exhausting it fails
//!   `zwatch.Watcher.add` with `error.WatchLimitReached`.
//! * The kernel event queue is bounded. When it overflows, the kernel says
//!   so and says nothing about what was lost; zwatch reports
//!   `zwatch.Kind.overflow` against every watch root and the caller should
//!   rescan.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;

const zwatch = @import("../zwatch.zig");
const Batch = @import("../Batch.zig");
const WatchId = zwatch.WatchId;

const Inotify = @This();

gpa: Allocator,
io: Io,
/// The inotify descriptor, which is what `zwatch.Watcher.fd` hands out.
ifd: posix.fd_t,
/// The caller's watches.
watches: std.AutoArrayHashMapUnmanaged(WatchId, Watch),
/// Kernel watch descriptor to the directory or file it stands for.
wds: std.AutoArrayHashMapUnmanaged(i32, Registration),

/// What the caller asked for.
const Watch = struct {
    /// Absolute, canonical path, owned by the backend.
    root: []u8,
    recursive: bool,
};

/// One kernel watch descriptor.
const Registration = struct {
    watch: WatchId,
    /// Absolute path the descriptor stands for, owned by the backend.
    path: []u8,
};

/// Everything zwatch asks the kernel to report. `IN.EXCL_UNLINK` keeps a
/// still-open but unlinked file from producing events nobody can act on;
/// `IN.DONT_FOLLOW` keeps a symbolic link from silently widening a watch.
const mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY |
    linux.IN.ATTRIB | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
    linux.IN.EXCL_UNLINK | linux.IN.DONT_FOLLOW;

/// Big enough that a burst of renames in one directory is one read. The
/// kernel refuses a read smaller than the next event, never a short one.
const read_buffer_len = 8192;

/// Creates the inotify descriptor.
pub fn init(gpa: Allocator, io: Io, options: zwatch.Options) zwatch.Watcher.InitError!Inotify {
    _ = options;
    // `linux.errno`, not `posix.errno`: these are raw syscalls, and on a
    // target that links libc `posix.errno` reads libc's thread-local
    // variable, which a raw syscall never writes.
    const rc = linux.inotify_init1(linux.IN.CLOEXEC);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    return .{
        .gpa = gpa,
        .io = io,
        .ifd = @intCast(rc),
        .watches = .empty,
        .wds = .empty,
    };
}

/// Closes the inotify descriptor and releases every watch.
pub fn deinit(n: *Inotify) void {
    for (n.wds.values()) |registration| n.gpa.free(registration.path);
    n.wds.deinit(n.gpa);
    for (n.watches.values()) |watch| n.gpa.free(watch.root);
    n.watches.deinit(n.gpa);
    _ = linux.close(n.ifd);
    n.* = undefined;
}

/// The inotify descriptor. Readable exactly when `zwatch.Watcher.poll` has
/// something to report.
pub fn fd(n: *const Inotify) ?posix.fd_t {
    return n.ifd;
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(n: *Inotify, id: WatchId, abs_path: []const u8, options: zwatch.AddOptions) zwatch.Watcher.AddError!void {
    for (n.watches.values()) |watch| {
        if (std.mem.eql(u8, watch.root, abs_path)) return error.PathAlreadyWatched;
    }
    const stat = try Io.Dir.cwd().statFile(n.io, abs_path, .{});

    const root = try n.gpa.dupe(u8, abs_path);
    errdefer n.gpa.free(root);
    try n.watches.put(n.gpa, id, .{ .root = root, .recursive = options.recursive });
    errdefer _ = n.watches.swapRemove(id);
    // A watch the kernel only half accepted is worse than none: it would
    // report a fraction of a tree and look like a quiet one.
    errdefer n.removeWatchDescriptors(id);

    try n.register(id, try n.gpa.dupe(u8, abs_path));
    if (stat.kind != .directory or !options.recursive) return;

    // One kernel watch per directory: inotify does not recurse.
    var frontier: std.ArrayList([]u8) = .empty;
    defer {
        for (frontier.items) |path| n.gpa.free(path);
        frontier.deinit(n.gpa);
    }
    try frontier.append(n.gpa, try n.gpa.dupe(u8, abs_path));

    var i: usize = 0;
    while (i < frontier.items.len) : (i += 1) {
        var dir = Io.Dir.openDirAbsolute(n.io, frontier.items[i], .{ .iterate = true }) catch continue;
        defer dir.close(n.io);
        var it = dir.iterate();
        while (try it.next(n.io)) |entry| {
            if (entry.kind != .directory) continue;
            const child = try std.fs.path.join(n.gpa, &.{ frontier.items[i], entry.name });
            errdefer n.gpa.free(child);
            n.register(id, try n.gpa.dupe(u8, child)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.WatchLimitReached => return error.WatchLimitReached,
                // A subdirectory that vanished, or that is not ours to
                // read, is reported through its parent and no further.
                else => {},
            };
            try frontier.append(n.gpa, child);
        }
    }
}

/// Stops watching `id` and releases its kernel watches.
pub fn remove(n: *Inotify, id: WatchId) void {
    const watch = n.watches.fetchSwapRemove(id) orelse return;
    n.gpa.free(watch.value.root);
    n.removeWatchDescriptors(id);
}

/// Waits on the inotify descriptor until it reports something `batch` did
/// not already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(n: *Inotify, batch: *Batch, timeout_ms: ?u32) zwatch.Watcher.PollError!void {
    const before = batch.events.items.len;
    const started: Io.Timestamp = .now(n.io, .awake);

    while (true) {
        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still performs one non-blocking check. Returning early here
        // would make `poll(0)` report nothing, ever.
        const timeout: i32 = timeout: {
            const total = timeout_ms orelse break :timeout -1;
            const elapsed = started.durationTo(Io.Timestamp.now(n.io, .awake)).toMilliseconds();
            break :timeout @intCast(@max(0, @as(i64, total) - elapsed));
        };

        var fds: [1]posix.pollfd = .{.{ .fd = n.ifd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, timeout) catch |err| switch (err) {
            error.SystemResources => return error.SystemResources,
            else => return error.Unexpected,
        };
        if (ready == 0) return;

        var buffer: [read_buffer_len]u8 align(@alignOf(linux.inotify_event)) = undefined;
        const len = posix.read(n.ifd, &buffer) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return error.Unexpected,
        };

        var offset: usize = 0;
        while (offset + @sizeOf(linux.inotify_event) <= len) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[offset]));
            offset += @sizeOf(linux.inotify_event) + event.len;
            try n.handle(event, batch);
        }
        if (batch.events.items.len > before) return;
    }
}

/// Turns one kernel event into zwatch events.
fn handle(n: *Inotify, event: *const linux.inotify_event, batch: *Batch) zwatch.Watcher.PollError!void {
    if (event.mask & linux.IN.Q_OVERFLOW != 0) {
        // The kernel does not say what was lost, so every watch is suspect.
        for (n.watches.keys(), n.watches.values()) |id, watch| {
            try batch.push(n.gpa, id, watch.root, .overflow);
        }
        return;
    }
    const registration = n.wds.get(event.wd) orelse return;
    const watch = registration.watch;

    // Copied because reporting a disappearance is also what frees it.
    const base = try n.gpa.dupe(u8, registration.path);
    defer n.gpa.free(base);

    // IN_IGNORED is the kernel saying the watch is already gone, and it
    // follows IN_DELETE_SELF, so neither asks for `inotify_rm_watch`.
    if (event.mask & linux.IN.IGNORED != 0) {
        n.drop(event.wd);
        return;
    }
    if (event.mask & linux.IN.DELETE_SELF != 0) {
        try batch.push(n.gpa, watch, base, .removed);
        n.drop(event.wd);
        return;
    }
    if (event.mask & linux.IN.MOVE_SELF != 0) {
        try batch.push(n.gpa, watch, base, .renamed);
        n.forget(event.wd);
        return;
    }

    const path = if (event.getName()) |name|
        try std.fs.path.join(n.gpa, &.{ base, name })
    else
        try n.gpa.dupe(u8, base);
    defer n.gpa.free(path);

    const is_dir = event.mask & linux.IN.ISDIR != 0;
    const recursive = (n.watches.get(watch) orelse return).recursive;

    if (event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) {
        try batch.push(n.gpa, watch, path, .created);
        if (is_dir and recursive) try n.adopt(watch, path, batch);
    }
    if (event.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0) {
        try batch.push(n.gpa, watch, path, .removed);
        if (is_dir) n.forgetSubtree(path);
    }
    if (event.mask & linux.IN.MODIFY != 0) {
        try batch.push(n.gpa, watch, path, .modified);
    }
    if (event.mask & linux.IN.ATTRIB != 0) {
        try batch.push(n.gpa, watch, path, .attributes);
    }
}

/// Registers directories that appeared inside a recursive watch, and
/// reports whatever is already inside them as created -- a directory can
/// be populated before the watch on it exists, and those events would
/// otherwise be lost.
///
/// Iterative rather than recursive: the tree being adopted is one an
/// unrelated process just created, so its depth is not this library's to
/// bound.
fn adopt(n: *Inotify, id: WatchId, path: []const u8, batch: *Batch) Allocator.Error!void {
    var frontier: std.ArrayList([]u8) = .empty;
    defer {
        for (frontier.items) |item| n.gpa.free(item);
        frontier.deinit(n.gpa);
    }
    try frontier.append(n.gpa, try n.gpa.dupe(u8, path));

    var i: usize = 0;
    while (i < frontier.items.len) : (i += 1) {
        const current = frontier.items[i];
        const owned = try n.gpa.dupe(u8, current);
        n.register(id, owned) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `register` freed it. A directory that is gone again, or is
            // not ours to read, is reported through its parent and no
            // further.
            else => continue,
        };

        var dir = Io.Dir.openDirAbsolute(n.io, current, .{ .iterate = true }) catch continue;
        defer dir.close(n.io);
        var it = dir.iterate();
        while (it.next(n.io) catch null) |entry| {
            const child = try std.fs.path.join(n.gpa, &.{ current, entry.name });
            errdefer n.gpa.free(child);
            try batch.push(n.gpa, id, child, .created);
            if (entry.kind == .directory) {
                try frontier.append(n.gpa, child);
            } else {
                n.gpa.free(child);
            }
        }
    }
}

/// Asks the kernel for a watch on `path`, taking ownership of it.
fn register(n: *Inotify, id: WatchId, path: []u8) zwatch.Watcher.AddError!void {
    const path_z = posix.toPosixPath(path) catch {
        n.gpa.free(path);
        return error.NameTooLong;
    };
    const rc = linux.inotify_add_watch(n.ifd, &path_z, mask);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOSPC => {
            n.gpa.free(path);
            return error.WatchLimitReached;
        },
        .ACCES => {
            n.gpa.free(path);
            return error.AccessDenied;
        },
        .NOENT => {
            n.gpa.free(path);
            return error.FileNotFound;
        },
        .NOMEM => {
            n.gpa.free(path);
            return error.SystemResources;
        },
        else => {
            n.gpa.free(path);
            return error.Unexpected;
        },
    }
    const wd: i32 = @intCast(rc);

    // The kernel returns the existing descriptor when the same inode is
    // registered twice, so a replaced entry frees the path it replaces.
    const gop = try n.wds.getOrPut(n.gpa, wd);
    if (gop.found_existing) n.gpa.free(gop.value_ptr.path);
    gop.value_ptr.* = .{ .watch = id, .path = path };
}

/// Asks the kernel to drop one watch, and forgets the path it stood for.
fn forget(n: *Inotify, wd: i32) void {
    if (!n.wds.contains(wd)) return;
    _ = linux.inotify_rm_watch(n.ifd, wd);
    n.drop(wd);
}

/// Forgets a watch the kernel has already dropped.
fn drop(n: *Inotify, wd: i32) void {
    const entry = n.wds.fetchSwapRemove(wd) orelse return;
    n.gpa.free(entry.value.path);
}

/// Drops the watch on `path` and on everything below it.
fn forgetSubtree(n: *Inotify, path: []const u8) void {
    var i: usize = 0;
    while (i < n.wds.count()) {
        const registered = n.wds.values()[i].path;
        const inside = std.mem.eql(u8, registered, path) or
            (registered.len > path.len and
                std.mem.startsWith(u8, registered, path) and
                registered[path.len] == std.fs.path.sep);
        if (inside) {
            _ = linux.inotify_rm_watch(n.ifd, n.wds.keys()[i]);
            n.gpa.free(registered);
            n.wds.swapRemoveAt(i);
        } else {
            i += 1;
        }
    }
}

/// Drops every kernel watch belonging to one of the caller's watches.
fn removeWatchDescriptors(n: *Inotify, id: WatchId) void {
    var i: usize = 0;
    while (i < n.wds.count()) {
        if (n.wds.values()[i].watch == id) {
            _ = linux.inotify_rm_watch(n.ifd, n.wds.keys()[i]);
            n.gpa.free(n.wds.values()[i].path);
            n.wds.swapRemoveAt(i);
        } else {
            i += 1;
        }
    }
}
