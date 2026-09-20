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
//!   `lookout.Watcher.add` with `error.WatchLimitReached` for the path the
//!   caller named, and reports `lookout.Kind.unwatched` for a directory
//!   below it that there was no room for.
//! * The kernel event queue is bounded, per inotify instance, by
//!   `/proc/sys/fs/inotify/max_queued_events` -- 16384 by default. Past
//!   it the kernel drops what does not fit and queues one `IN_Q_OVERFLOW`
//!   in its place, saying nothing about what was lost; lookout reports
//!   `lookout.Kind.overflow` against every watch root and the caller should
//!   rescan. A watcher polled less often than its tree changes wants the
//!   limit raised, which is the administrator's to do.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;

const lookout = @import("../lookout.zig");
const Batch = @import("../Batch.zig");
const Budget = @import("../Budget.zig");
const Deadline = @import("../Deadline.zig");
const Filter = @import("../Filter.zig");
const path_cmp = @import("../path.zig");
const records = @import("inotify_records.zig");
const walk = @import("../walk.zig");
const Target = lookout.Target;
const WatchId = lookout.WatchId;

const Inotify = @This();

gpa: Allocator,
io: Io,
/// The inotify descriptor, which is what `lookout.Watcher.fd` hands out.
ifd: posix.fd_t,
/// Read and write ends of the pipe `wake` pokes. Both non-blocking, so
/// neither a waker nor a waiter can be held up by the other.
wake_r: posix.fd_t,
wake_w: posix.fd_t,
/// The caller's watches.
watches: std.AutoArrayHashMapUnmanaged(WatchId, Watch),
/// Kernel watch descriptor to the directory or file it stands for.
wds: std.AutoArrayHashMapUnmanaged(i32, Registration),
/// How many entries each watched directory holds, against
/// `lookout.Options.max_dir_entries`.
budget: Budget,
/// What every kernel watch is registered with: `base_mask`, plus
/// `IN_CLOSE_WRITE` when `lookout.Options.report_closes` asked for it.
/// Kept rather than recomputed, because every `register` needs it and
/// the kernel is not asked for events nobody wants.
mask: u32,
/// The `IN_MOVED_FROM` halves of renames whose `IN_MOVED_TO` has not
/// arrived, keyed by the cookie the kernel pairs them with. Paths owned
/// here.
///
/// The kernel emits the two halves back to back, but "back to back" is
/// about the queue and not about the read: a burst of renames large
/// enough to fill the read buffer puts one pair either side of a
/// boundary. So a half is held across reads and released only when the
/// whole wait is over -- see `flushRenames` -- and what stays behind
/// then is a path that moved out of the watch, which from inside the
/// watch is a removal.
pending_renames: std.AutoArrayHashMapUnmanaged(PendingKey, Pending),

/// What the caller asked for.
const Watch = struct {
    /// Absolute, canonical path, owned by the backend.
    root: []u8,
    target: Target,
    recursive: bool,
    /// `lookout.AddOptions.filter`, copied. An excluded directory is
    /// never registered, so the kernel is never asked for a watch on it.
    filter: Filter,
};

/// One half of a rename, waiting for the other.
const Pending = struct {
    /// Absolute path the entry moved from, owned by the backend.
    path: []u8,
    is_dir: bool,
};

const PendingKey = struct {
    watch: WatchId,
    cookie: u32,
};

/// One kernel watch descriptor.
const Registration = struct {
    /// Absolute path the descriptor stands for, owned by the backend.
    path: []u8,
    /// Every caller watch that owns this kernel descriptor.
    watches: std.ArrayList(WatchId),
};

/// Everything lookout asks the kernel to report. `IN.EXCL_UNLINK` keeps a
/// still-open but unlinked file from producing events nobody can act on;
/// `IN.DONT_FOLLOW` keeps a symbolic link from silently widening a watch.
const base_mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY |
    linux.IN.ATTRIB | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
    linux.IN.EXCL_UNLINK | linux.IN.DONT_FOLLOW;

/// Big enough that a burst of renames in one directory is one read. The
/// kernel refuses a read smaller than the next event, never a short one.
const read_buffer_len = 8192;

/// Creates the inotify descriptor and the pipe `wake` pokes.
pub fn init(gpa: Allocator, io: Io, options: lookout.Options) lookout.Watcher.InitError!Inotify {
    // `linux.errno`, not `posix.errno`: these are raw syscalls, and on a
    // target that links libc `posix.errno` reads libc's thread-local
    // variable, which a raw syscall never writes.
    const rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    const ifd: posix.fd_t = @intCast(rc);
    errdefer _ = linux.close(ifd);

    var fds: [2]i32 = undefined;
    switch (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }))) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => return error.Unexpected,
    }

    return .{
        .gpa = gpa,
        .io = io,
        .ifd = ifd,
        .wake_r = fds[0],
        .wake_w = fds[1],
        .watches = .empty,
        .wds = .empty,
        .budget = .init(gpa, io, options.max_dir_entries),
        .mask = if (options.report_closes)
            base_mask | linux.IN.CLOSE_WRITE
        else
            base_mask,
        .pending_renames = .empty,
    };
}

/// Closes the descriptors and releases every watch.
pub fn deinit(n: *Inotify) void {
    for (n.wds.values()) |*registration| {
        n.gpa.free(registration.path);
        registration.watches.deinit(n.gpa);
    }
    n.wds.deinit(n.gpa);
    for (n.watches.values()) |*watch| {
        n.gpa.free(watch.root);
        watch.filter.deinit(n.gpa);
    }
    n.watches.deinit(n.gpa);
    for (n.pending_renames.values()) |half| n.gpa.free(half.path);
    n.pending_renames.deinit(n.gpa);
    n.budget.deinit();
    _ = linux.close(n.wake_r);
    _ = linux.close(n.wake_w);
    _ = linux.close(n.ifd);
    n.* = undefined;
}

/// The inotify descriptor. Readable exactly when `lookout.Watcher.poll` has
/// something to report.
pub fn fd(n: *const Inotify) ?posix.fd_t {
    return n.ifd;
}

/// Nothing to resume from: the kernel queue starts empty and remembers
/// nothing from before the watch. See `lookout.tracksPosition`.
pub fn position(n: *const Inotify) ?u64 {
    _ = n;
    return null;
}

/// Writes one byte to the pipe a blocked `wait` is also polling. See
/// `lookout.Watcher.wake`.
pub fn wake(n: *Inotify) void {
    const byte: [1]u8 = .{0};
    _ = linux.write(n.wake_w, &byte, 1);
}

/// How many kernel watches this backend holds, which is what the
/// per-user `max_user_watches` cap counts. See `lookout.Watcher.Stats`.
pub fn registrationCount(n: *const Inotify) usize {
    return n.wds.count();
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(
    n: *Inotify,
    id: WatchId,
    abs_path: []const u8,
    options: lookout.AddOptions,
    batch: *Batch,
) lookout.Watcher.AddError!void {
    const stat = try Io.Dir.cwd().statFile(n.io, abs_path, .{});

    const root = try n.gpa.dupe(u8, abs_path);
    errdefer n.gpa.free(root);
    var filter = try options.filter.dupe(n.gpa);
    errdefer filter.deinit(n.gpa);
    try n.watches.put(n.gpa, id, .{
        .root = root,
        .target = .of(stat.kind),
        .recursive = options.recursive,
        .filter = filter,
    });
    errdefer _ = n.watches.swapRemove(id);
    // A watch the kernel only half accepted is worse than none: it would
    // report a fraction of a tree and look like a quiet one.
    errdefer n.removeWatchDescriptors(id);

    try n.register(id, try n.gpa.dupe(u8, abs_path));
    if (stat.kind == .directory) try n.budget.seed(abs_path);
    if (stat.kind != .directory or !options.recursive) return;

    // One kernel watch per directory: inotify does not recurse.
    const Registering = struct {
        n: *Inotify,
        id: WatchId,
        batch: *Batch,

        fn visit(r: *@This(), entry: walk.Entry) anyerror!walk.Step {
            if (entry.kind != .directory) return .over;
            // An excluded directory costs no kernel watch and is not
            // descended into, so its whole tree costs nothing.
            if (r.n.pruned(r.id, entry.path)) return .over;
            r.n.register(r.id, try r.n.gpa.dupe(u8, entry.path)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // A subdirectory that vanished, or that is not ours to
                // read -- including one past the per-user watch limit:
                // a hole in the watch, and saying so is the difference
                // between a quiet subtree and a silent one.
                else => {
                    try r.batch.trouble(r.n.gpa, r.id, entry.path, .directory);
                    return .over;
                },
            };
            return .into;
        }
    };
    var registering: Registering = .{ .n = n, .id = id, .batch = batch };
    walk.tree(n.gpa, n.io, abs_path, &registering, Registering.visit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
}

/// Stops watching `id` and releases its kernel watches.
pub fn remove(n: *Inotify, id: WatchId) void {
    var watch = n.watches.fetchSwapRemove(id) orelse return;
    n.budget.forget(watch.value.root);
    n.gpa.free(watch.value.root);
    watch.value.filter.deinit(n.gpa);
    n.removeWatchDescriptors(id);
    var i: usize = 0;
    while (i < n.pending_renames.count()) {
        if (n.pending_renames.keys()[i].watch != id) {
            i += 1;
            continue;
        }
        n.gpa.free(n.pending_renames.values()[i].path);
        n.pending_renames.swapRemoveAt(i);
    }
}

/// Whether `subject` is outside what the watch `id` is about, so no
/// event for it is reported. See `lookout.AddOptions.filter`.
fn excluded(n: *const Inotify, id: WatchId, subject: []const u8) bool {
    const watch = n.watches.get(id) orelse return false;
    return watch.filter.excludes(watch.root, subject);
}

/// Whether a directory is so far outside the watch that it need not be
/// registered at all. See `Filter.prunes`.
fn pruned(n: *const Inotify, id: WatchId, subject: []const u8) bool {
    const watch = n.watches.get(id) orelse return false;
    return watch.filter.prunes(watch.root, subject);
}

/// Waits on the inotify descriptor until it reports something `batch` did
/// not already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(n: *Inotify, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const result = n.collect(batch, timeout_ms);
    // Whatever is still held when the wait is over never found its other
    // half, however many reads it waited through.
    try n.flushRenames(batch);
    return result;
}

fn collect(n: *Inotify, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const before = batch.revision;
    const deadline: Deadline = .start(n.io, timeout_ms);

    while (true) {
        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still performs one non-blocking check. Returning early here
        // would make `poll(0)` report nothing, ever.
        var fds: [2]posix.pollfd = .{
            .{ .fd = n.ifd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = n.wake_r, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, deadline.pollMs()) catch |err| switch (err) {
            error.SystemResources => return error.SystemResources,
            else => return error.Unexpected,
        };
        if (ready == 0) {
            if (!deadline.expired()) continue;
            return;
        }

        var woken = false;
        if (fds[1].revents & posix.POLL.IN != 0) {
            n.drainWake();
            woken = true;
        }
        if (fds[0].revents & posix.POLL.IN != 0) {
            if (!try n.read(batch)) continue;
        }
        if (!woken and batch.revision == before) continue;
        // A half with no partner yet is worth one more look: the other
        // half is in the queue if the burst was simply longer than one
        // read, and flushing here would turn a rename into a removal and
        // a creation on a backend that says it pairs them.
        while (n.pending_renames.count() != 0) {
            if (!try n.read(batch)) break;
        }
        return;
    }
}

/// Reads one buffer of kernel events and turns them into lookout events.
/// `false` when there was nothing to read.
fn read(n: *Inotify, batch: *Batch) lookout.Watcher.PollError!bool {
    var buffer: [read_buffer_len]u8 align(@alignOf(linux.inotify_event)) = undefined;
    const len = posix.read(n.ifd, &buffer) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return error.Unexpected,
    };
    if (len == 0) return false;

    var it = records.iterate(buffer[0..len]);
    while (true) {
        // The kernel refuses a read smaller than the next record rather
        // than returning half of one, so a tail this cannot decode is
        // not something it produced. What has been decoded is already
        // reported; the rest of the buffer says nothing that can be
        // acted on.
        const event = it.next() catch |err| switch (err) {
            error.TruncatedRecord => return true,
        } orelse return true;
        try n.handle(event, batch);
    }
}

fn drainWake(n: *Inotify) void {
    var scratch: [256]u8 = undefined;
    while (posix.read(n.wake_r, &scratch) catch @as(usize, 0) > 0) {}
}

/// What one kernel event says, once the flags have been read.
const Change = struct {
    watch: WatchId,
    /// The kernel watch descriptor the event arrived on.
    wd: i32,
    /// The directory the watch descriptor stands for, owned by `handle`.
    dir: []u8,
    /// The absolute path of the entry, owned by `handle`.
    path: []u8,
    cookie: u32,
    is_dir: bool,
    appeared: bool,
    vanished: bool,
    moved_from: bool,
    moved_to: bool,
    modified: bool,
    closed: bool,
    attributes: bool,

    fn target(c: Change) Target {
        return if (c.is_dir) .directory else .file;
    }
};

/// Turns one kernel event into lookout events: read the flags, pair what
/// can be paired, report, then keep the books.
fn handle(n: *Inotify, event: records.Record, batch: *Batch) lookout.Watcher.PollError!void {
    if (event.mask & linux.IN.Q_OVERFLOW != 0) {
        // The kernel does not say what was lost, so every watch is suspect.
        for (n.watches.keys(), n.watches.values()) |id, watch| {
            try batch.push(n.gpa, id, watch.root, .overflow, watch.target);
        }
        return;
    }
    const registration = n.wds.get(event.wd) orelse return;
    const owners = try n.gpa.dupe(WatchId, registration.watches.items);
    defer n.gpa.free(owners);
    const base = try n.gpa.dupe(u8, registration.path);
    defer n.gpa.free(base);

    // IN_IGNORED is the kernel saying the watch is already gone, and it
    // follows IN_DELETE_SELF, so neither asks for `inotify_rm_watch`.
    if (event.mask & linux.IN.IGNORED != 0) {
        n.drop(event.wd);
        return;
    }
    if (event.mask & linux.IN.DELETE_SELF != 0) {
        for (owners) |watch| {
            try batch.push(n.gpa, watch, base, .removed, n.targetOfWatchPath(watch, base));
        }
        n.drop(event.wd);
        return;
    }
    if (event.mask & linux.IN.MOVE_SELF != 0) {
        for (owners) |watch| {
            try batch.push(n.gpa, watch, base, .renamed, n.targetOfWatchPath(watch, base));
        }
        n.forget(event.wd);
        return;
    }

    for (owners, 0..) |watch, i| {
        var change = (try n.decode(event, watch, base)) orelse continue;
        defer {
            n.gpa.free(change.path);
            n.gpa.free(change.dir);
        }
        const paired = try n.pair(&change, batch);
        try n.emit(change, paired, batch);
        try n.bookkeep(change, paired, i == 0, batch);
    }
}

/// Reads the flags, and answers everything that is over before an entry
/// is named: the queue overflowing, a watch going away, and the watched
/// path itself being deleted or moved.
fn decode(n: *Inotify, event: records.Record, watch: WatchId, watched: []const u8) lookout.Watcher.PollError!?Change {
    const base = try n.gpa.dupe(u8, watched);
    errdefer n.gpa.free(base);

    const full = if (event.name) |name|
        try std.fs.path.join(n.gpa, &.{ base, name })
    else
        try n.gpa.dupe(u8, base);
    errdefer n.gpa.free(full);

    // Excluded before anything is reported, registered or counted: the
    // path is not part of this watch at all.
    if (n.excluded(watch, full) and n.pruned(watch, full)) {
        n.gpa.free(full);
        n.gpa.free(base);
        return null;
    }

    return .{
        .watch = watch,
        .wd = event.wd,
        .dir = base,
        .path = full,
        .cookie = event.cookie,
        .is_dir = event.mask & linux.IN.ISDIR != 0,
        .appeared = event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0,
        .vanished = event.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0,
        .moved_from = event.mask & linux.IN.MOVED_FROM != 0,
        .moved_to = event.mask & linux.IN.MOVED_TO != 0,
        .modified = event.mask & linux.IN.MODIFY != 0,
        .closed = event.mask & linux.IN.CLOSE_WRITE != 0,
        .attributes = event.mask & linux.IN.ATTRIB != 0,
    };
}

/// Holds one half of a move, or joins it to the half already held.
///
/// The kernel gives both halves one cookie, and two halves make one
/// `renamed` instead of a removal and a creation nobody can connect.
fn pair(n: *Inotify, change: *const Change, batch: *Batch) lookout.Watcher.PollError!bool {
    if (change.moved_from) {
        const owned = try n.gpa.dupe(u8, change.path);
        errdefer n.gpa.free(owned);
        const key: PendingKey = .{ .watch = change.watch, .cookie = change.cookie };
        if (n.pending_renames.fetchSwapRemove(key)) |stale| n.gpa.free(stale.value.path);
        try n.pending_renames.put(n.gpa, key, .{
            .path = owned,
            .is_dir = change.is_dir,
        });
        return true;
    }
    if (change.moved_to) {
        const key: PendingKey = .{ .watch = change.watch, .cookie = change.cookie };
        const half = n.pending_renames.fetchSwapRemove(key) orelse return false;
        defer n.gpa.free(half.value.path);
        if (!n.excluded(change.watch, change.path)) {
            try batch.pushRename(n.gpa, change.watch, change.path, half.value.path, change.target());
        }
        // The watches below a moved directory are still on the right
        // inodes but under the wrong names, so they are dropped and
        // taken again at the name the tree now has.
        if (change.is_dir) {
            n.forgetSubtree(change.watch, half.value.path);
            n.budget.forget(half.value.path);
        }
        return true;
    }
    return false;
}

/// Reports what happened to the entry, for everything a pairing did not
/// already answer.
fn emit(n: *Inotify, change: Change, paired: bool, batch: *Batch) lookout.Watcher.PollError!void {
    if (n.excluded(change.watch, change.path)) return;
    const target = change.target();
    if (change.appeared and !paired) {
        try batch.push(n.gpa, change.watch, change.path, .created, target);
    }
    if (change.vanished and !paired) {
        try batch.push(n.gpa, change.watch, change.path, .removed, target);
    }
    if (change.modified) {
        try batch.push(n.gpa, change.watch, change.path, .modified, target);
    }
    // Only asked for when `lookout.Options.report_closes` is set, so a
    // watcher that did not ask never sees one of these.
    if (change.closed) {
        try batch.push(n.gpa, change.watch, change.path, .closed, target);
    }
    if (change.attributes) {
        try batch.push(n.gpa, change.watch, change.path, .attributes, target);
    }
}

/// Keeps the entry budget and the registrations current.
fn bookkeep(
    n: *Inotify,
    change: Change,
    paired: bool,
    count_budget: bool,
    batch: *Batch,
) lookout.Watcher.PollError!void {
    // Checked on every event for the directory rather than only on the
    // ones that move the count, so that a watch added to a directory
    // that is already too big says so at the first sign of life, which
    // is what the listing backends do.
    const move: Budget.Move = if (change.appeared)
        .appeared
    else if (change.vanished)
        .vanished
    else
        .unchanged;
    if (try n.budget.note(change.dir, if (count_budget) move else .unchanged)) {
        const watch = n.watches.get(change.watch) orelse return;
        try batch.push(n.gpa, change.watch, watch.root, .overflow, watch.target);
    }

    if (!change.is_dir) return;
    if (change.appeared and !paired and n.recursive(change.watch)) {
        try n.adopt(change.watch, change.path, batch);
    }
    if (change.moved_to and paired and n.recursive(change.watch)) {
        try n.adopt(change.watch, change.path, batch);
    }
    if (change.vanished and !paired) {
        n.forgetSubtree(change.watch, change.path);
        n.budget.forget(change.path);
    }
}

fn recursive(n: *const Inotify, id: WatchId) bool {
    return (n.watches.get(id) orelse return false).recursive;
}

fn targetOfWatchPath(n: *const Inotify, id: WatchId, subject: []const u8) Target {
    const watch = n.watches.get(id) orelse return .unknown;
    return if (path_cmp.eql(watch.root, subject)) watch.target else .directory;
}

/// Reports every held `IN_MOVED_FROM` whose other half never came as a
/// removal: the entry moved somewhere this watch cannot see it, which
/// from inside the watch is indistinguishable from a deletion.
fn flushRenames(n: *Inotify, batch: *Batch) lookout.Watcher.PollError!void {
    while (n.pending_renames.count() != 0) {
        const key = n.pending_renames.keys()[0];
        const half = n.pending_renames.values()[0];
        n.pending_renames.swapRemoveAt(0);
        defer n.gpa.free(half.path);
        try batch.push(
            n.gpa,
            key.watch,
            half.path,
            .removed,
            if (half.is_dir) .directory else .file,
        );
        if (half.is_dir) {
            n.forgetSubtree(key.watch, half.path);
            n.budget.forget(half.path);
        }
    }
}

/// Registers directories that appeared inside a recursive watch, and
/// reports whatever is already inside them as created -- a directory can
/// be populated before the watch on it exists, and those events would
/// otherwise be lost.
fn adopt(n: *Inotify, id: WatchId, root: []const u8, batch: *Batch) lookout.Watcher.PollError!void {
    n.register(id, try n.gpa.dupe(u8, root)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try batch.trouble(n.gpa, id, root, .directory);
            return;
        },
    };
    n.budget.seed(root) catch {};

    const Adopting = struct {
        n: *Inotify,
        id: WatchId,
        batch: *Batch,

        fn visit(a: *@This(), entry: walk.Entry) anyerror!walk.Step {
            if (a.n.pruned(a.id, entry.path)) return .over;
            if (!a.n.excluded(a.id, entry.path)) {
                try a.batch.push(a.n.gpa, a.id, entry.path, .created, .of(entry.kind));
            }
            if (entry.kind != .directory) return .over;
            a.n.register(a.id, try a.n.gpa.dupe(u8, entry.path)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try a.batch.trouble(a.n.gpa, a.id, entry.path, .directory);
                    return .over;
                },
            };
            a.n.budget.seed(entry.path) catch {};
            return .into;
        }
    };
    var adopting: Adopting = .{ .n = n, .id = id, .batch = batch };
    walk.tree(n.gpa, n.io, root, &adopting, Adopting.visit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
}

test "the kernel's queue overflow record is an overflow against every watch" {
    // inotify(7): "IN_Q_OVERFLOW: Event queue overflowed (wd is -1 for
    // this event)", and of max_queued_events: "Events in excess of this
    // limit are dropped, but an IN_Q_OVERFLOW event is always
    // generated." The record is written here the way the kernel writes
    // it and read back through the decoder a real read goes through,
    // so that what is asserted is the whole path from the bytes to the
    // batch. src/test_gaps.zig fills a real queue past the limit.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const file = try std.fs.path.join(gpa, &.{ root, "a.txt" });
    defer gpa.free(file);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .inotify });
    defer watcher.deinit();
    const dir = try watcher.add(root, .{ .recursive = true });
    const single = try watcher.add(file, .{});
    while ((try watcher.poll(200)).len != 0) {}

    var bytes: [records.header_len]u8 = undefined;
    const len = records.encode(&bytes, .{ .wd = -1, .mask = linux.IN.Q_OVERFLOW, .cookie = 0, .name = null });
    var it = records.iterate(bytes[0..len]);
    const record = (try it.next()).?;
    try testing.expectEqual(@as(?records.Record, null), try it.next());

    // Straight into the batch the next poll returns, which is where a
    // read puts it.
    const n = &watcher.impl.inotify;
    try n.handle(record, &watcher.batch);

    var dir_overflows: usize = 0;
    var file_overflows: usize = 0;
    for (watcher.batch.events.items) |event| {
        try testing.expectEqual(lookout.Kind.overflow, event.kind);
        if (event.id == dir) {
            try testing.expectEqualStrings(root, event.path);
            try testing.expectEqual(Target.directory, event.target);
            dir_overflows += 1;
        } else {
            try testing.expectEqual(single, event.id);
            try testing.expectEqualStrings(file, event.path);
            try testing.expectEqual(Target.file, event.target);
            file_overflows += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), dir_overflows);
    try testing.expectEqual(@as(usize, 1), file_overflows);

    // And nothing about the watches themselves changed: the next write
    // is reported to both.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one and two" });
    var saw_dir = false;
    var saw_file = false;
    var waited: u32 = 0;
    while (waited < 10_000 and !(saw_dir and saw_file)) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind != .modified or !std.mem.eql(u8, event.path, file)) continue;
            if (event.id == dir) saw_dir = true;
            if (event.id == single) saw_file = true;
        }
    }
    try testing.expect(saw_dir);
    try testing.expect(saw_file);
}

/// Asks the kernel for a watch on `path`, taking ownership of it.
fn register(n: *Inotify, id: WatchId, watched: []u8) lookout.Watcher.AddError!void {
    const path_z = posix.toPosixPath(watched) catch {
        n.gpa.free(watched);
        return error.NameTooLong;
    };
    const rc = linux.inotify_add_watch(n.ifd, &path_z, n.mask);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOSPC => {
            n.gpa.free(watched);
            return error.WatchLimitReached;
        },
        .ACCES => {
            n.gpa.free(watched);
            return error.AccessDenied;
        },
        .NOENT => {
            n.gpa.free(watched);
            return error.FileNotFound;
        },
        .NOMEM => {
            n.gpa.free(watched);
            return error.SystemResources;
        },
        else => {
            n.gpa.free(watched);
            return error.Unexpected;
        },
    }
    const wd: i32 = @intCast(rc);

    // The kernel returns the existing descriptor when the same inode is
    // registered twice. Keep both caller watches attached to it.
    if (n.wds.getPtr(wd)) |registration| {
        registration.watches.append(n.gpa, id) catch |err| {
            n.gpa.free(watched);
            return err;
        };
        n.gpa.free(watched);
        return;
    }

    var owners: std.ArrayList(WatchId) = .empty;
    owners.append(n.gpa, id) catch |err| {
        _ = linux.inotify_rm_watch(n.ifd, wd);
        n.gpa.free(watched);
        return err;
    };
    errdefer owners.deinit(n.gpa);
    n.wds.put(n.gpa, wd, .{ .path = watched, .watches = owners }) catch |err| {
        _ = linux.inotify_rm_watch(n.ifd, wd);
        n.gpa.free(watched);
        return err;
    };
}

/// Asks the kernel to drop one watch, and forgets the path it stood for.
fn forget(n: *Inotify, wd: i32) void {
    if (!n.wds.contains(wd)) return;
    _ = linux.inotify_rm_watch(n.ifd, wd);
    n.drop(wd);
}

/// Forgets a watch the kernel has already dropped.
fn drop(n: *Inotify, wd: i32) void {
    var entry = n.wds.fetchSwapRemove(wd) orelse return;
    n.gpa.free(entry.value.path);
    entry.value.watches.deinit(n.gpa);
}

/// Drops one caller watch's ownership of `root` and everything below it.
fn forgetSubtree(n: *Inotify, id: WatchId, root: []const u8) void {
    var i: usize = 0;
    while (i < n.wds.count()) {
        if (path_cmp.within(root, n.wds.values()[i].path)) {
            if (!n.removeOwner(i, id)) i += 1;
        } else {
            i += 1;
        }
    }
}

/// Drops every kernel watch belonging to one of the caller's watches.
fn removeWatchDescriptors(n: *Inotify, id: WatchId) void {
    var i: usize = 0;
    while (i < n.wds.count()) {
        if (!n.removeOwner(i, id)) i += 1;
    }
}

/// Removes `id`; answers whether the registration itself became empty.
fn removeOwner(n: *Inotify, registration_index: usize, id: WatchId) bool {
    const registration = &n.wds.values()[registration_index];
    for (registration.watches.items, 0..) |owner, owner_index| {
        if (owner != id) continue;
        _ = registration.watches.orderedRemove(owner_index);
        if (registration.watches.items.len != 0) return false;
        _ = linux.inotify_rm_watch(n.ifd, n.wds.keys()[registration_index]);
        n.gpa.free(registration.path);
        registration.watches.deinit(n.gpa);
        n.wds.swapRemoveAt(registration_index);
        return true;
    }
    return false;
}
