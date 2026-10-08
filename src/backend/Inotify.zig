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
const assert = std.debug.assert;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;

const lookout = @import("../types.zig");
const Batch = @import("../Batch.zig");
const Budget = @import("../Budget.zig");
const Deadline = @import("../Deadline.zig");
const identity = @import("../identity.zig");
const CompiledFilter = @import("../CompiledFilter.zig");
const path_cmp = @import("../path.zig");
const records = @import("inotify/records.zig");
const walk = @import("../walk.zig");
const Waker = @import("../Waker.zig");
const Options = @import("../options.zig").Options;
const contract = @import("../watch_contract.zig");
const AddOptions = @import("../options.zig").AddOptions;
const builtin = @import("builtin");
const Target = lookout.Target;
const WatchId = lookout.WatchId;

const Inotify = @This();

gpa: Allocator,
/// The inotify descriptor, which is what `lookout.Watcher.fd` hands out.
ifd: posix.fd_t,
/// Read and write ends of the pipe `wake` pokes. Both non-blocking, so
/// neither a waker nor a waiter can be held up by the other.
wake_r: posix.fd_t,
wake_w: posix.fd_t,
/// The caller's watches.
watches: std.array_hash_map.Auto(WatchId, Watch),
/// Kernel watch descriptor to the directory or file it stands for.
wds: std.array_hash_map.Auto(i32, Registration),
/// How many entries each watched directory holds, against
/// `@import("../options.zig").Options.max_dir_entries`.
budget: Budget,
/// What every kernel watch is registered with: `base_mask`, plus
/// `IN_CLOSE_WRITE` when `@import("../options.zig").Options.report_closes` asked for it.
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
pending_renames: std.array_hash_map.Auto(PendingKey, Pending),
/// A read belongs to the backend until all its records are accounted for.
read_buffer: [read_buffer_len]u8 align(@alignOf(linux.inotify_event)) = undefined,
read_len: usize = 0,
read_offset: usize = 0,

/// What the caller asked for.
const Watch = struct {
    /// Absolute, canonical path, owned by the backend.
    root: []u8,
    target: Target,
    recursive: bool,
    /// `@import("../options.zig").AddOptions.filter`, copied. An excluded directory is
    /// never registered, so the kernel is never asked for a watch on it.
    filter: CompiledFilter,
    identity_override: ?identity.Policy = null,
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
pub fn init(gpa: Allocator, options: Options) contract.InitError!Inotify {
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
        .ifd = ifd,
        .wake_r = fds[0],
        .wake_w = fds[1],
        .watches = .empty,
        .wds = .empty,
        .budget = .init(gpa, options.max_dir_entries),
        .mask = if (options.report_closes)
            base_mask | linux.IN.CLOSE_WRITE
        else
            base_mask,
        .pending_renames = .empty,
    };
}

/// Closes the descriptors and releases every watch.
pub fn deinit(n: *Inotify, io: Io) void {
    _ = io; // Every backend takes it; this one closes nothing through it.
    for (n.wds.values()) |*registration| {
        n.gpa.free(registration.path);
        registration.watches.deinit(n.gpa);
    }
    n.wds.deinit(n.gpa);
    for (n.watches.values()) |*watch| {
        n.gpa.free(watch.root);
        watch.filter.deinit();
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

/// How another thread pokes a blocked `wait`: the write end of the pipe
/// it is also polling, which is fixed for the life of the watcher. See
/// `lookout.Watcher.wake`.
pub fn waker(n: *const Inotify) Waker {
    return .{ .context = @intCast(n.wake_w), .call = poke };
}

/// Writes one byte to the pipe. Non-blocking, so a full pipe costs
/// nothing: one byte pending is as good as a thousand.
fn poke(context: usize) void {
    const byte: [1]u8 = .{0};
    _ = linux.write(@intCast(context), &byte, 1);
}

/// How many kernel watches this backend holds, which is what the
/// per-user `max_user_watches` cap counts. See `lookout.Watcher.Stats`.
pub fn registrationCount(n: *const Inotify) usize {
    return n.wds.count();
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(
    n: *Inotify,
    io: Io,
    id: WatchId,
    abs_path: []const u8,
    options: AddOptions,
    batch: *Batch,
) contract.AddError!void {
    const stat = try Io.Dir.cwd().statFile(io, abs_path, .{});

    const root = try n.gpa.dupe(u8, abs_path);
    errdefer n.gpa.free(root);
    var filter = try CompiledFilter.compilePolicy(n.gpa, options.filter, identity.read(n.gpa, io, abs_path).policy(options.identity));
    errdefer filter.deinit();
    try n.watches.put(n.gpa, id, .{
        .root = root,
        .target = .of(stat.kind),
        .recursive = options.recursive,
        .filter = filter,
        .identity_override = options.identity,
    });
    errdefer _ = n.watches.swapRemove(id);
    // A watch the kernel only half accepted is worse than none: it would
    // report a fraction of a tree and look like a quiet one.
    errdefer n.removeWatchDescriptors(id);

    try n.register(id, try n.gpa.dupe(u8, abs_path));
    if (stat.kind == .directory) try n.budget.seed(io, abs_path);
    if (stat.kind != .directory or !options.recursive) return;

    // One kernel watch per directory: inotify does not recurse.
    const Registering = struct {
        n: *Inotify,
        io: Io,
        id: WatchId,
        batch: *Batch,

        const Self = @This();

        fn visit(r: *Self, entry: walk.Entry) anyerror!walk.Step {
            if (entry.kind != .directory) return .over;
            // An excluded directory costs no kernel watch and is not
            // descended into, so its whole tree costs nothing.
            if (r.n.pruned(r.io, r.id, entry.path)) return .over;
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
    var registering: Registering = .{ .n = n, .io = io, .id = id, .batch = batch };
    walk.tree(*Registering, Registering.visit, n.gpa, io, abs_path, &registering) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
}

/// Stops watching `id` and releases its kernel watches.
pub fn remove(n: *Inotify, io: Io, id: WatchId) void {
    _ = io; // Every backend takes it; this one closes nothing through it.
    var watch = n.watches.fetchSwapRemove(id) orelse return;
    n.removeWatchDescriptors(id);
    n.budget.release(*const Inotify, stillCounted, watch.value.root, n);
    n.gpa.free(watch.value.root);
    watch.value.filter.deinit();
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

/// Reconciles this watch's directory registrations with a new filter.
/// New directories are registered before excluded ones are released.
pub fn refilter(n: *Inotify, io: Io, id: WatchId, next: lookout.Filter, batch: *Batch) contract.RefilterError!void {
    const watch = n.watches.getPtr(id) orelse return error.UnknownWatch;
    const replacement = try CompiledFilter.compilePolicy(n.gpa, next, watch.filter.policy);
    var previous = watch.filter;
    watch.filter = replacement;
    errdefer {
        watch.filter.deinit();
        watch.filter = previous;
        var rollback: usize = 0;
        while (rollback < n.wds.count()) {
            const registration = &n.wds.values()[rollback];
            if (!path_cmp.eql(registration.path, watch.root) and
                previous.prunes(watch.root, registration.path))
            {
                if (!n.removeOwner(rollback, id)) rollback += 1;
            } else rollback += 1;
        }
        n.budget.release(*const Inotify, stillCounted, watch.root, n);
    }

    if (watch.recursive and watch.target == .directory) {
        const Registering = struct {
            n: *Inotify,
            io: Io,
            id: WatchId,
            batch: *Batch,

            const Self = @This();

            fn visit(r: *Self, entry: walk.Entry) anyerror!walk.Step {
                if (entry.kind != .directory or r.n.pruned(r.io, r.id, entry.path)) return .over;
                if (!r.n.ownsPath(r.id, entry.path)) {
                    r.n.register(r.id, try r.n.gpa.dupe(u8, entry.path)) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            try r.batch.trouble(r.n.gpa, r.id, entry.path, .directory);
                            return .over;
                        },
                    };
                    try r.n.budget.seed(r.io, entry.path);
                }
                return .into;
            }
        };
        var registering: Registering = .{ .n = n, .io = io, .id = id, .batch = batch };
        walk.tree(*Registering, Registering.visit, n.gpa, io, watch.root, &registering) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unexpected,
        };
    }
    var i: usize = 0;
    while (i < n.wds.count()) {
        const registration = &n.wds.values()[i];
        if (!path_cmp.eql(registration.path, watch.root) and n.pruned(io, id, registration.path)) {
            if (!n.removeOwner(i, id)) i += 1;
        } else i += 1;
    }
    n.budget.release(*const Inotify, stillCounted, watch.root, n);
    previous.deinit();
}

fn ownsPath(n: *const Inotify, id: WatchId, subject: []const u8) bool {
    for (n.wds.values()) |registration| {
        if (!path_cmp.eql(registration.path, subject)) continue;
        for (registration.watches.items) |owner| if (owner == id) return true;
    }
    return false;
}

/// Whether the kernel still watches `dir` for a watch that is left, so
/// that its count outlives the watch being removed. See
/// `Budget.release`.
fn stillCounted(n: *const Inotify, dir: []const u8) bool {
    for (n.wds.values()) |registration| {
        if (path_cmp.eql(registration.path, dir)) return true;
    }
    return false;
}

/// Whether `subject` is outside what the watch `id` is about, so no
/// event for it is reported. See `@import("../options.zig").AddOptions.filter`.
fn excluded(n: *const Inotify, io: Io, id: WatchId, subject: []const u8) bool {
    const watch = n.watches.get(id) orelse return false;
    if (watch.filter.isEmpty()) return false;
    const parent = std.Io.Dir.path.dirname(subject) orelse watch.root;
    return watch.filter.excludesPolicy(identity.read(n.gpa, io, parent).policy(watch.identity_override), watch.root, subject);
}

/// Whether a directory is so far outside the watch that it need not be
/// registered at all. See `CompiledFilter.prunes`.
fn pruned(n: *const Inotify, io: Io, id: WatchId, subject: []const u8) bool {
    const watch = n.watches.get(id) orelse return false;
    if (watch.filter.isEmpty()) return false;
    const parent = std.Io.Dir.path.dirname(subject) orelse watch.root;
    return watch.filter.prunesPolicy(identity.read(n.gpa, io, parent).policy(watch.identity_override), watch.root, subject);
}

/// Waits on the inotify descriptor until it reports something `batch` did
/// not already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(n: *Inotify, io: Io, batch: *Batch, timeout_ms: ?u32) contract.PollError!void {
    // A read takes records off the descriptor, and a directory that
    // appears is registered below it one directory at a time, so nothing
    // in here is a place to stop: see `Watcher.poll`. The wait itself is
    // out of `std.Io`'s reach.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    try n.collect(io, batch, timeout_ms);
    // Whatever is still held when the wait is over never found its other
    // half, however many reads it waited through.
    try n.flushRenames(io, batch);
}

fn collect(n: *Inotify, io: Io, batch: *Batch, timeout_ms: ?u32) contract.PollError!void {
    const before = batch.revision;
    const deadline: Deadline = .fromMs(io, timeout_ms);

    while (true) {
        if (n.read_len != 0) {
            _ = try n.read(io, batch);
            while (n.pending_renames.count() != 0) {
                if (!try n.read(io, batch)) break;
            }
            if (batch.revision != before) return;
        }
        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still performs one non-blocking check. Returning early here
        // would make a zero-timeout `poll` report nothing, ever.
        var fds: [2]posix.pollfd = .{
            .{ .fd = n.ifd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = n.wake_r, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, deadline.pollMs(io)) catch |err| switch (err) {
            error.SystemResources => return error.SystemResources,
            else => return error.Unexpected,
        };
        if (ready == 0) {
            if (!deadline.expired(io)) continue;
            return;
        }

        var woken = false;
        if (fds[1].revents & posix.POLL.IN != 0) {
            n.drainWake();
            woken = true;
        }
        if (fds[0].revents & posix.POLL.IN != 0) {
            if (!try n.read(io, batch)) continue;
        }
        if (!woken and batch.revision == before) continue;
        // A half with no partner yet is worth one more look: the other
        // half is in the queue if the burst was simply longer than one
        // read, and flushing here would turn a rename into a removal and
        // a creation on a backend that says it pairs them.
        while (n.pending_renames.count() != 0) {
            if (!try n.read(io, batch)) break;
        }
        return;
    }
}

/// Reads one buffer of kernel events and turns them into lookout events.
/// `false` when there was nothing to read.
fn read(n: *Inotify, io: Io, batch: *Batch) contract.PollError!bool {
    if (n.read_len == 0) {
        n.read_len = posix.read(n.ifd, &n.read_buffer) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return error.Unexpected,
        };
        n.read_offset = 0;
        if (n.read_len == 0) return false;
    }
    // A read held across calls is resumed where its walk stopped.
    assert(n.read_len <= n.read_buffer.len);
    assert(n.read_offset <= n.read_len);
    try n.consume(io, n.read_buffer[0..n.read_len], &n.read_offset, batch);
    n.read_len = 0;
    return true;
}

/// Turns one buffer the kernel filled into lookout events.
///
/// A queue overflow among them lost changes nobody was told about, so
/// every entry count is off by them; they are read again from disk once
/// the buffer is done -- see `Budget.reread`. Once it is done and not at
/// the overflow record, because the records after that one are changes
/// made since: counted from their records and then taken in again by a
/// re-read made before them, they would be counted twice.
fn handleRead(n: *Inotify, io: Io, bytes: []const u8, batch: *Batch) contract.PollError!void {
    var offset: usize = 0;
    try n.consume(io, bytes, &offset, batch);
}

fn consume(n: *Inotify, io: Io, bytes: []const u8, offset: *usize, batch: *Batch) contract.PollError!void {
    assert(offset.* <= bytes.len);
    // Partial bookkeeping can no longer supply reliable entry counts.
    errdefer n.budget.reread(void, everyDirectory, io, {});
    var lost = false;
    defer if (lost) n.budget.reread(void, everyDirectory, io, {});
    var it = records.iterate(bytes);
    it.offset = offset.*;
    while (true) {
        // The kernel refuses a read smaller than the next record rather
        // than returning half of one, so a tail this cannot decode is
        // not something it produced. What has been decoded is already
        // reported; the rest of the buffer says nothing that can be
        // acted on.
        const event = it.next() catch |err| switch (err) {
            error.TruncatedRecord => return,
        } orelse return;
        if (event.mask & linux.IN.Q_OVERFLOW != 0) lost = true;
        try n.handle(io, event, batch);
        offset.* = it.offset;
    }
}

/// The queue is the whole watcher's, and so is what it lost.
fn everyDirectory(_: void, _: []const u8) bool {
    return true;
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
    /// Whether the kernel named an entry of `dir`, rather than reporting
    /// on the watched path itself -- a watched file, say.
    named: bool,
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
fn handle(n: *Inotify, io: Io, event: records.Record, batch: *Batch) contract.PollError!void {
    if (event.mask & linux.IN.Q_OVERFLOW != 0) {
        // The kernel does not say what was lost, so every watch is suspect.
        for (n.watches.keys(), n.watches.values()) |id, watch| {
            try batch.push(n.gpa, io, id, watch.root, .overflow, watch.target);
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
            try batch.push(n.gpa, io, watch, base, .removed, n.targetOfWatchPath(watch, base));
        }
        n.drop(event.wd);
        return;
    }
    if (event.mask & linux.IN.MOVE_SELF != 0) {
        for (owners) |watch| {
            try batch.push(n.gpa, io, watch, base, .renamed, n.targetOfWatchPath(watch, base));
        }
        n.forget(event.wd);
        return;
    }

    // The folder's entries move with the change whatever the watches
    // make of it: before any of them is asked, and whether or not one
    // keeps the entry. A pending watch parked on the folder, which is
    // about one name in it, lets every other change there go by, and a
    // directory watch taken there later counts on what this keeps.
    if (event.name) |name| {
        const move: Budget.Move = if (event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0)
            .appeared
        else if (event.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0)
            .vanished
        else
            .unchanged;
        if (move != .unchanged and n.budget.count(base) != null) _ = try n.budget.note(io, base, name, move);
    }
    for (owners) |watch| {
        var change = (try n.decode(io, event, watch, base)) orelse continue;
        defer {
            n.gpa.free(change.path);
            n.gpa.free(change.dir);
        }
        const paired = try n.pair(io, &change, batch);
        try n.emit(io, change, paired, batch);
        try n.bookkeep(io, change, paired, batch);
    }
}

/// Reads the flags, and answers everything that is over before an entry
/// is named: the queue overflowing, a watch going away, and the watched
/// path itself being deleted or moved.
fn decode(n: *Inotify, io: Io, event: records.Record, watch: WatchId, watched: []const u8) contract.PollError!?Change {
    const base = try n.gpa.dupe(u8, watched);
    errdefer n.gpa.free(base);

    const full = if (event.name) |name|
        try std.Io.Dir.path.join(n.gpa, &.{ base, name })
    else
        try n.gpa.dupe(u8, base);
    errdefer n.gpa.free(full);

    // Excluded before anything is reported, registered or counted: the
    // path is not part of this watch at all.
    if (n.excluded(io, watch, full) and n.pruned(io, watch, full)) {
        n.gpa.free(full);
        n.gpa.free(base);
        return null;
    }

    return .{
        .watch = watch,
        .wd = event.wd,
        .dir = base,
        .path = full,
        .named = event.name != null,
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
///
/// The halves are paired before the filter is asked, and a name it
/// excludes is then treated exactly as a name outside the watch: both
/// names kept is `renamed`; only the new one kept is `created` there;
/// only the old one kept is `removed` there; neither is nothing.
fn pair(n: *Inotify, io: Io, change: *const Change, batch: *Batch) contract.PollError!bool {
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
        const half = n.pending_renames.get(key) orelse return false;
        const keeps_to = !n.excluded(io, change.watch, change.path);
        const keeps_from = !n.excluded(io, change.watch, half.path);
        if (keeps_to and keeps_from) {
            try batch.pushRename(n.gpa, io, change.watch, change.path, half.path, change.target());
        } else if (keeps_to) {
            try batch.push(n.gpa, io, change.watch, change.path, .created, change.target());
        } else if (keeps_from) {
            try batch.push(n.gpa, io, change.watch, half.path, .removed, change.target());
        }
        // The watches below a moved directory are still on the right
        // inodes but under the wrong names, so they are dropped and
        // taken again at the name the tree now has.
        if (change.is_dir) {
            n.forgetSubtree(change.watch, half.path);
            n.budget.forget(half.path);
        }
        _ = n.pending_renames.swapRemove(key);
        n.gpa.free(half.path);
        return true;
    }
    return false;
}

/// Reports what happened to the entry, for everything a pairing did not
/// already answer.
fn emit(n: *Inotify, io: Io, change: Change, paired: bool, batch: *Batch) contract.PollError!void {
    if (n.excluded(io, change.watch, change.path)) return;
    const target = change.target();
    if (change.appeared and !paired) {
        try batch.push(n.gpa, io, change.watch, change.path, .created, target);
    }
    if (change.vanished and !paired) {
        try batch.push(n.gpa, io, change.watch, change.path, .removed, target);
    }
    if (change.modified) {
        try batch.push(n.gpa, io, change.watch, change.path, .modified, target);
    }
    // Only asked for when `@import("../options.zig").Options.report_closes` is set, so a
    // watcher that did not ask never sees one of these.
    if (change.closed) {
        try batch.push(n.gpa, io, change.watch, change.path, .closed, target);
    }
    if (change.attributes) {
        try batch.push(n.gpa, io, change.watch, change.path, .attributes, target);
    }
}

/// Keeps the entry budget and the registrations current.
fn bookkeep(
    n: *Inotify,
    io: Io,
    change: Change,
    paired: bool,
    batch: *Batch,
) contract.PollError!void {
    // Checked on every event for the directory rather than only on the
    // ones that move the count, so that a watch added to a directory
    // that is already too big says so at the first sign of life, which
    // is what the listing backends do. The count itself moved in
    // `handle`, once for the folder. A change to a watched file is no
    // entry of anything: the file is no directory, and has no count.
    if (change.named and try n.budget.note(io, change.dir, std.Io.Dir.path.basename(change.path), .unchanged)) {
        const watch = n.watches.get(change.watch) orelse return;
        try batch.push(n.gpa, io, change.watch, watch.root, .overflow, watch.target);
    }

    if (!change.is_dir) return;
    if (change.appeared and !paired and n.recursive(change.watch)) {
        try n.adopt(io, change.watch, change.path, batch);
    }
    if (change.moved_to and paired and n.recursive(change.watch)) {
        try n.adopt(io, change.watch, change.path, batch);
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
/// from inside the watch is indistinguishable from a deletion. A half on
/// a name the filter excludes is held only so that its partner can be
/// told apart from a rename in, and is not reported.
fn flushRenames(n: *Inotify, io: Io, batch: *Batch) contract.PollError!void {
    while (n.pending_renames.count() != 0) {
        const key = n.pending_renames.keys()[0];
        const half = n.pending_renames.values()[0];
        if (!n.excluded(io, key.watch, half.path)) try batch.push(
            n.gpa,
            io,
            key.watch,
            half.path,
            .removed,
            if (half.is_dir) .directory else .file,
        );
        if (half.is_dir) {
            n.forgetSubtree(key.watch, half.path);
            n.budget.forget(half.path);
        }
        n.pending_renames.swapRemoveAt(0);
        n.gpa.free(half.path);
    }
}

/// Registers directories that appeared inside a recursive watch, and
/// reports whatever is already inside them as created -- a directory can
/// be populated before the watch on it exists, and those events would
/// otherwise be lost.
fn adopt(n: *Inotify, io: Io, id: WatchId, root: []const u8, batch: *Batch) contract.PollError!void {
    n.register(id, try n.gpa.dupe(u8, root)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try batch.trouble(n.gpa, id, root, .directory);
            return;
        },
    };
    try n.budget.seed(io, root);

    const Adopting = struct {
        n: *Inotify,
        io: Io,
        id: WatchId,
        batch: *Batch,

        const Self = @This();

        fn visit(a: *Self, entry: walk.Entry) anyerror!walk.Step {
            if (a.n.pruned(a.io, a.id, entry.path)) return .over;
            if (!a.n.excluded(a.io, a.id, entry.path)) {
                try a.batch.push(a.n.gpa, a.io, a.id, entry.path, .created, .of(entry.kind));
            }
            if (entry.kind != .directory) return .over;
            a.n.register(a.id, try a.n.gpa.dupe(u8, entry.path)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try a.batch.trouble(a.n.gpa, a.id, entry.path, .directory);
                    return .over;
                },
            };
            try a.n.budget.seed(a.io, entry.path);
            return .into;
        }
    };
    var adopting: Adopting = .{ .n = n, .io = io, .id = id, .batch = batch };
    walk.tree(*Adopting, Adopting.visit, n.gpa, io, root, &adopting) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
}

/// Asks the kernel for a watch on `path`, taking ownership of it.
fn register(n: *Inotify, id: WatchId, watched: []u8) contract.AddError!void {
    if (n.ownsPath(id, watched)) {
        n.gpa.free(watched);
        return;
    }
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
        for (registration.watches.items) |owner| {
            if (owner == id) {
                n.gpa.free(watched);
                return;
            }
        }
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

pub const test_access = if (builtin.is_test) struct {
    pub const handleRead = handleReadFixture;
} else struct {};
const handleReadFixture = handleRead;

test {
    _ = records;
}
