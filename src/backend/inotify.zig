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
//!   `lookout.Watcher.add` with `error.WatchLimitReached`.
//! * The kernel event queue is bounded. When it overflows, the kernel says
//!   so and says nothing about what was lost; lookout reports
//!   `lookout.Kind.overflow` against every watch root and the caller should
//!   rescan.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;

const lookout = @import("../lookout.zig");
const Batch = @import("../Batch.zig");
const WatchId = lookout.WatchId;

const Inotify = @This();

gpa: Allocator,
io: Io,
/// The inotify descriptor, which is what `lookout.Watcher.fd` hands out.
ifd: posix.fd_t,
/// The caller's watches.
watches: std.AutoArrayHashMapUnmanaged(WatchId, Watch),
/// Kernel watch descriptor to the directory or file it stands for.
wds: std.AutoArrayHashMapUnmanaged(i32, Registration),
/// Mirrors `lookout.Options.max_dir_entries`.
max_dir_entries: usize,
/// The `IN_MOVED_FROM` halves of renames whose `IN_MOVED_TO` has not
/// arrived, keyed by the cookie the kernel pairs them with. Paths owned
/// here.
///
/// The kernel emits the two halves back to back, so this is normally
/// empty by the end of the read that filled it. What stays behind is a
/// path that moved out of the watch, and `flushRenames` reports it as a
/// removal -- which, from inside the watch, is what it is.
pending_renames: std.AutoArrayHashMapUnmanaged(u32, Pending),

/// What the caller asked for.
const Watch = struct {
    /// Absolute, canonical path, owned by the backend.
    root: []u8,
    recursive: bool,
};

/// One half of a rename, waiting for the other.
const Pending = struct {
    watch: WatchId,
    /// Absolute path the entry moved from, owned by the backend.
    path: []u8,
    is_dir: bool,
};

/// One kernel watch descriptor.
const Registration = struct {
    watch: WatchId,
    /// Absolute path the descriptor stands for, owned by the backend.
    path: []u8,
    /// How many entries the directory holds, counted once when the watch
    /// was registered and kept current from the creations and deletions
    /// the kernel reports. Zero for a file.
    ///
    /// inotify needs no listing to name what changed, so this exists for
    /// one reason: `lookout.Options.max_dir_entries` is a budget the
    /// caller set, and a directory past it must say `lookout.Kind.overflow`
    /// here exactly as it does on the backends that compare listings.
    entries: usize,
};

/// Everything lookout asks the kernel to report. `IN.EXCL_UNLINK` keeps a
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
pub fn init(gpa: Allocator, io: Io, options: lookout.Options) lookout.Watcher.InitError!Inotify {
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
        .max_dir_entries = options.max_dir_entries,
        .pending_renames = .empty,
    };
}

/// Closes the inotify descriptor and releases every watch.
pub fn deinit(n: *Inotify) void {
    for (n.wds.values()) |registration| n.gpa.free(registration.path);
    n.wds.deinit(n.gpa);
    for (n.watches.values()) |watch| n.gpa.free(watch.root);
    n.watches.deinit(n.gpa);
    for (n.pending_renames.values()) |half| n.gpa.free(half.path);
    n.pending_renames.deinit(n.gpa);
    _ = linux.close(n.ifd);
    n.* = undefined;
}

/// The inotify descriptor. Readable exactly when `lookout.Watcher.poll` has
/// something to report.
pub fn fd(n: *const Inotify) ?posix.fd_t {
    return n.ifd;
}

/// How many watches the caller has added. See `lookout.Watcher.Stats`.
pub fn watchCount(n: *const Inotify) usize {
    return n.watches.count();
}

/// How many kernel watches this backend holds, which is what the
/// per-user `max_user_watches` cap counts. See `lookout.Watcher.Stats`.
pub fn registrationCount(n: *const Inotify) usize {
    return n.wds.count();
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(n: *Inotify, id: WatchId, abs_path: []const u8, options: lookout.AddOptions) lookout.Watcher.AddError!void {
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
pub fn wait(n: *Inotify, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const before = batch.revision;
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
        // The kernel puts both halves of a rename in one read, so a half
        // still held at the end of one is a path that left the watch.
        try n.flushRenames(batch);
        if (batch.revision != before) return;
    }
}

/// Turns one kernel event into lookout events.
fn handle(n: *Inotify, event: *const linux.inotify_event, batch: *Batch) lookout.Watcher.PollError!void {
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

    const appeared = event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0;
    const vanished = event.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0;

    // A move is held rather than reported: the kernel gives both halves a
    // cookie, and two halves make one `renamed` instead of a removal and
    // a creation nobody can connect.
    var paired = false;
    if (event.mask & linux.IN.MOVED_FROM != 0) {
        const owned = try n.gpa.dupe(u8, path);
        errdefer n.gpa.free(owned);
        if (n.pending_renames.fetchSwapRemove(event.cookie)) |stale| n.gpa.free(stale.value.path);
        try n.pending_renames.put(n.gpa, event.cookie, .{
            .watch = watch,
            .path = owned,
            .is_dir = is_dir,
        });
        paired = true;
    }
    if (event.mask & linux.IN.MOVED_TO != 0) {
        if (n.pending_renames.fetchSwapRemove(event.cookie)) |half| {
            defer n.gpa.free(half.value.path);
            try batch.pushRename(n.gpa, watch, path, half.value.path);
            // The watches below a moved directory are still on the right
            // inodes but under the wrong names, so they are dropped and
            // taken again at the name the tree now has.
            if (is_dir) {
                n.forgetSubtree(half.value.path);
                if (recursive) try n.adopt(watch, path, batch);
            }
            paired = true;
        }
    }

    if (appeared and !paired) try batch.push(n.gpa, watch, path, .created);
    if (vanished and !paired) try batch.push(n.gpa, watch, path, .removed);
    if (event.mask & linux.IN.MODIFY != 0) {
        try batch.push(n.gpa, watch, path, .modified);
    }
    if (event.mask & linux.IN.ATTRIB != 0) {
        try batch.push(n.gpa, watch, path, .attributes);
    }

    // The entry budget. Checked on every event for the directory rather
    // than only on the ones that move the count, so that a watch added to
    // a directory that is already too big says so at the first sign of
    // life, which is what the listing backends do.
    if (n.wds.getPtr(event.wd)) |current| {
        if (appeared) current.entries += 1;
        if (vanished) current.entries -|= 1;
        if (current.entries > n.max_dir_entries) {
            try batch.push(n.gpa, watch, n.watches.get(watch).?.root, .overflow);
        }
    }

    // Last, because both can rehash `wds` and invalidate the pointer above.
    if (appeared and !paired and is_dir and recursive) try n.adopt(watch, path, batch);
    if (vanished and !paired and is_dir) n.forgetSubtree(path);
}

/// Reports every held `IN_MOVED_FROM` whose other half never came as a
/// removal: the entry moved somewhere this watch cannot see it, which
/// from inside the watch is indistinguishable from a deletion.
fn flushRenames(n: *Inotify, batch: *Batch) lookout.Watcher.PollError!void {
    while (n.pending_renames.count() != 0) {
        const half = n.pending_renames.values()[0];
        const cookie = n.pending_renames.keys()[0];
        n.pending_renames.swapRemoveAt(0);
        defer n.gpa.free(half.path);
        _ = cookie;
        try batch.push(n.gpa, half.watch, half.path, .removed);
        if (half.is_dir) n.forgetSubtree(half.path);
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
fn register(n: *Inotify, id: WatchId, path: []u8) lookout.Watcher.AddError!void {
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
    const entries = n.countEntries(path);
    const gop = try n.wds.getOrPut(n.gpa, wd);
    if (gop.found_existing) n.gpa.free(gop.value_ptr.path);
    gop.value_ptr.* = .{ .watch = id, .path = path, .entries = entries };
}

/// How many entries `path` holds, or zero when it is not a directory or
/// cannot be read. The one listing inotify does, and only to start the
/// count `handle` keeps: an unreadable directory is a budget of nothing
/// rather than a failed `add`.
fn countEntries(n: *Inotify, path: []const u8) usize {
    var dir = Io.Dir.openDirAbsolute(n.io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(n.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(n.io) catch null) |_| count += 1;
    return count;
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
