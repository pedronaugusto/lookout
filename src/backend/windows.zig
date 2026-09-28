//! The Windows backend: `ReadDirectoryChangesW`, read through an I/O
//! completion port.
//!
//! One directory handle per watch, opened for overlapped I/O and
//! associated with a port the watcher owns. Each watch keeps one read
//! outstanding; when it completes, the buffer holds a chain of
//! `FILE_NOTIFY_INFORMATION` records naming what changed, and the read is
//! posted again. Recursion is a flag on the call, so a tree costs one
//! handle rather than one per directory.
//!
//! Three things follow from that shape:
//!
//! * `lookout.Watcher.fd` is `null` here. A completion port is not a
//!   waitable object another loop can fold in, so a program on Windows
//!   drives the watcher by calling `poll`.
//! * The kernel buffers changes between reads, and says so by completing
//!   a read with zero bytes when it could not. That becomes
//!   `lookout.Kind.overflow`.
//! * The handle is opened with `FILE_SHARE_DELETE` so that watching a
//!   directory does not stop anyone from deleting it.
//!
//! This file has never been executed on the machine it was written on;
//! see README.md. It compiles for `x86_64-windows-gnu` and
//! `x86_64-windows-msvc`, and the shared suite in src/test_suite.zig is
//! what runs it on a Windows host.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const windows = std.os.windows;

const lookout = @import("../lookout.zig");
const Batch = @import("../Batch.zig");
const Budget = @import("../Budget.zig");
const Deadline = @import("../Deadline.zig");
const Filter = @import("../Filter.zig");
const buffer = @import("../buffer.zig");
const path_cmp = @import("../path.zig");
const records = @import("windows_records.zig");
const Waker = @import("../Waker.zig");
const trace = @import("../trace.zig");
const Target = lookout.Target;
const WatchId = lookout.WatchId;

const Windows = @This();

gpa: Allocator,
io: Io,
/// The completion port every watch's reads land on.
port: windows.HANDLE,
watches: std.AutoArrayHashMapUnmanaged(WatchId, *Watch),
/// Watches whose handle is closed but whose buffer the kernel may not
/// have finished with. An intrusive list so retiring a watch cannot fail
/// for want of an allocation while overlapped I/O still references it.
retiring: ?*Watch,
/// How many entries each watched directory holds, against
/// `lookout.Options.max_dir_entries`.
budget: Budget,
/// `lookout.Options.buffer_bytes`, clamped and rounded to what
/// `ReadDirectoryChangesW` will take. See `bounds`.
buffer_len: usize,

/// What `lookout.Options.buffer_bytes` may ask for here.
///
/// The floor is a few times the largest single record -- twelve bytes and
/// a name of up to 32767 UTF-16 units -- so that one change can always be
/// reported. The ceiling is a size past which the call is a bad idea
/// rather than a refusal: the buffer is non-paged pool while a read is
/// outstanding, one per watch. The default is what a network share will
/// take, which is the one size that works everywhere.
const bounds: buffer.Bounds = .{
    .min = 4 * 1024,
    .max = 16 * 1024 * 1024,
    .default = 64 * 1024,
};

/// What a share will take when it refuses the size the caller asked for.
/// `ReadDirectoryChangesW` on a remote directory fails with
/// `ERROR_INVALID_PARAMETER` for a buffer over 64 KiB rather than
/// clamping it, so a caller who raised the size for a local disk and
/// then pointed the watcher at a share would otherwise get a watch that
/// died without an event and without an error.
const share_buffer_len = 64 * 1024;

/// The completion key `wake` posts under. No watch can have it: ids are
/// handed out from zero upwards.
const wake_key: usize = std.math.maxInt(usize);

/// One watch: one directory handle with one read outstanding.
///
/// Heap-allocated and never moved, because the kernel writes into
/// `buffer` and `overlapped` for as long as a read is pending.
const Watch = struct {
    id: WatchId,
    /// The path the caller named, absolute and canonical, in WTF-8.
    root: []u8,
    /// Identity of `root` at add time, used to detect a renamed root even
    /// if another entry is created under its old name.
    root_inode: Io.File.INode,
    /// The directory the read is posted on: `root`, or its parent when
    /// the caller named a file.
    handle: windows.HANDLE,
    /// Set when the caller named a file: only this name, relative to the
    /// directory the handle is on, is the watch.
    only: ?[]u8,
    /// What `root` was when the watch was added, and when it was last
    /// seen to appear. A `FILE_NOTIFY_INFORMATION` record carries an
    /// action and a name and no attributes, so the root's own removal
    /// cannot be asked what it was; this is the answer kept from before.
    root_target: Target,
    recursive: bool,
    /// `lookout.AddOptions.filter`, copied.
    ///
    /// `ReadDirectoryChangesW` recurses in the kernel and cannot be told
    /// to leave a directory out, so here the filter drops the events
    /// rather than saving the work -- see `lookout.prunesIgnored`.
    filter: Filter,
    overlapped: c.OVERLAPPED,
    /// Where the kernel writes the change records. Owned by the watch,
    /// and not released until its outstanding read has completed, which
    /// is why `remove` retires a watch rather than freeing it.
    buffer: []align(@alignOf(u32)) u8,
    /// The old name of a rename whose new name has not arrived yet.
    ///
    /// Held across completions rather than dropped at the end of each
    /// one: a burst of renames long enough to fill the buffer puts one
    /// pair either side of a read, and deciding at the end of the read
    /// turns one `renamed` into a removal and a creation on a backend
    /// that says it pairs them. `flushRenames` is what lets it go.
    pending_rename: ?[]u8,
    /// How much of the buffer the kernel is willing to take. Lowered
    /// once, to `share_buffer_len`, if the size asked for is refused.
    accepted_len: usize,
    retiring_next: ?*Watch,

    /// The target of a path this watch has just lost. A watch on a file
    /// only ever reports its root, whose type it remembers; a watch on a
    /// directory reports entries the kernel never typed, and once they
    /// are gone there is nothing left to ask.
    fn goneTarget(watch: *const Watch) Target {
        return if (watch.only != null) watch.root_target else .unknown;
    }

    /// The directory the reads are posted on: `root`, or its parent
    /// for a watch on a file.
    fn dir(watch: *const Watch) []const u8 {
        return if (watch.only == null) watch.root else std.fs.path.dirname(watch.root) orelse watch.root;
    }

    /// The directories whose entries this watch reports, and so whose
    /// entry budget it keeps; `null` for a watch on a file.
    ///
    /// A watch on a file reads its folder only to see the file. It is
    /// told nothing about the folder's other entries, so it cannot keep
    /// the folder's count, and on no other backend is a file watch told
    /// when its folder is past the budget. Counting the folder through
    /// it moved the count only when the file came or went, and that
    /// count outlived the folder's own watch.
    pub fn reach(watch: *const Watch) ?Budget.Reach {
        if (watch.only != null) return null;
        return .{ .dir = watch.root, .recursive = watch.recursive };
    }

    /// Keeps what the root was last seen to be, so that a file watch
    /// whose root is replaced by a directory of the same name reports
    /// the next removal as what actually left.
    fn noteRoot(watch: *Watch, target: Target) void {
        if (watch.only != null and target != .unknown) watch.root_target = target;
    }
};

/// Creates the completion port.
pub fn init(gpa: Allocator, io: Io, options: lookout.Options) lookout.Watcher.InitError!Windows {
    const port = c.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 0) orelse
        return error.SystemResources;
    return .{
        .gpa = gpa,
        .io = io,
        .port = port,
        .watches = .empty,
        .retiring = null,
        .budget = .init(gpa, io, options.max_dir_entries),
        .buffer_len = buffer.clamp(options.buffer_bytes, bounds),
    };
}

/// Closes every directory handle and the port.
pub fn deinit(w: *Windows) void {
    for (w.watches.values()) |watch| {
        _ = c.CancelIoEx(watch.handle, &watch.overlapped);
        _ = c.CloseHandle(watch.handle);
        w.free(watch);
    }
    w.watches.deinit(w.gpa);
    w.budget.deinit();
    // The port is closed before the retiring buffers are freed: after
    // that no completion can reference them.
    _ = c.CloseHandle(w.port);
    while (w.retiring) |watch| {
        w.retiring = watch.retiring_next;
        w.free(watch);
    }
    w.* = undefined;
}

/// No descriptor: a completion port is not something another wait loop
/// can take, so a Windows program drives the watcher by calling
/// `lookout.Watcher.poll`.
pub fn fd(w: *const Windows) ?std.posix.fd_t {
    _ = w;
    return null;
}

/// Nothing to resume from: the change records start when the read does.
/// See `lookout.tracksPosition`.
pub fn position(w: *const Windows) ?u64 {
    _ = w;
    return null;
}

/// How another thread pokes a blocked `wait`: the completion port, which
/// is fixed for the life of the watcher. See `lookout.Watcher.wake`.
pub fn waker(w: *const Windows) Waker {
    return .{ .context = @intFromPtr(w.port), .call = post };
}

/// Posts a completion under a key no watch has, which a blocked `wait`
/// takes as its cue to come back.
fn post(context: usize) void {
    const port: windows.HANDLE = @ptrFromInt(context);
    _ = c.PostQueuedCompletionStatus(port, 0, wake_key, null);
}

/// How many directory handles this backend holds: one per watch, because
/// recursion is a flag on the read rather than a handle per directory.
/// See `lookout.Watcher.Stats`.
pub fn registrationCount(w: *const Windows) usize {
    return w.watches.count();
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(
    w: *Windows,
    id: WatchId,
    abs_path: []const u8,
    options: lookout.AddOptions,
    batch: *Batch,
) lookout.Watcher.AddError!void {
    _ = batch;
    const stat = try Io.Dir.cwd().statFile(w.io, abs_path, .{});
    const is_dir = stat.kind == .directory;

    // `ReadDirectoryChangesW` reads directories, so a watch on a file is
    // a read on its parent filtered down to the one name.
    const dir_path = if (is_dir) abs_path else std.fs.path.dirname(abs_path) orelse abs_path;
    const only: ?[]u8 = if (is_dir) null else try w.gpa.dupe(u8, std.fs.path.basename(abs_path));
    errdefer if (only) |name| w.gpa.free(name);

    const watch = try w.gpa.create(Watch);
    errdefer w.gpa.destroy(watch);
    const root = try w.gpa.dupe(u8, abs_path);
    errdefer w.gpa.free(root);

    const handle = try open(w.gpa, dir_path);
    errdefer _ = c.CloseHandle(handle);

    var filter = try options.filter.dupe(w.gpa);
    errdefer filter.deinit(w.gpa);

    const bytes = try w.gpa.alignedAlloc(u8, .of(u32), w.buffer_len);
    errdefer w.gpa.free(bytes);

    watch.* = .{
        .id = id,
        .root = root,
        .root_inode = stat.inode,
        .handle = handle,
        .only = only,
        .root_target = .of(stat.kind),
        .recursive = options.recursive and is_dir,
        .filter = filter,
        .overlapped = std.mem.zeroes(c.OVERLAPPED),
        .buffer = bytes,
        .pending_rename = null,
        .accepted_len = w.buffer_len,
        .retiring_next = null,
    };
    if (is_dir) w.budget.seed(dir_path) catch {};

    if (c.CreateIoCompletionPort(handle, w.port, @intFromEnum(id), 0) == null)
        return error.WatchLimitReached;
    try w.watches.put(w.gpa, id, watch);
    errdefer _ = w.watches.swapRemove(id);
    try w.arm(watch);
}

/// Opens a directory for overlapped change notification.
fn open(gpa: Allocator, path: []const u8) lookout.Watcher.AddError!windows.HANDLE {
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.BadPathName,
    };
    defer gpa.free(wide);

    const handle = c.CreateFileW(
        wide.ptr,
        c.FILE_LIST_DIRECTORY,
        // FILE_SHARE_DELETE is the one that matters: without it, watching
        // a directory would stop anyone else from deleting or renaming
        // it, which is not what a watcher is for.
        c.FILE_SHARE_READ | c.FILE_SHARE_WRITE | c.FILE_SHARE_DELETE,
        null,
        c.OPEN_EXISTING,
        c.FILE_FLAG_BACKUP_SEMANTICS | c.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return switch (c.GetLastError()) {
        c.ERROR_FILE_NOT_FOUND, c.ERROR_PATH_NOT_FOUND => error.FileNotFound,
        c.ERROR_ACCESS_DENIED => error.AccessDenied,
        c.ERROR_TOO_MANY_OPEN_FILES => error.ProcessFdQuotaExceeded,
        else => error.Unexpected,
    };
    return handle;
}

/// Posts the outstanding read for a watch. Every completion re-posts,
/// because a change that arrives while no read is outstanding is a change
/// the kernel has to buffer.
fn arm(w: *Windows, watch: *Watch) lookout.Watcher.AddError!void {
    watch.overlapped = std.mem.zeroes(c.OVERLAPPED);
    const filter: u32 = c.FILE_NOTIFY_CHANGE_FILE_NAME | c.FILE_NOTIFY_CHANGE_DIR_NAME |
        c.FILE_NOTIFY_CHANGE_ATTRIBUTES | c.FILE_NOTIFY_CHANGE_SIZE |
        c.FILE_NOTIFY_CHANGE_LAST_WRITE | c.FILE_NOTIFY_CHANGE_CREATION |
        c.FILE_NOTIFY_CHANGE_SECURITY;
    if (c.ReadDirectoryChangesW(
        watch.handle,
        watch.buffer.ptr,
        @intCast(watch.accepted_len),
        @intFromBool(watch.recursive),
        filter,
        null,
        &watch.overlapped,
        null,
    ) == 0) return switch (c.GetLastError()) {
        c.ERROR_IO_PENDING => {},
        c.ERROR_NOT_ENOUGH_MEMORY, c.ERROR_OUTOFMEMORY => error.SystemResources,
        // A remote directory refuses a buffer over 64 KiB outright
        // rather than clamping it. Coming down to what a share takes is
        // the difference between a smaller buffer and a dead watch.
        c.ERROR_INVALID_PARAMETER => {
            if (watch.accepted_len <= share_buffer_len) return error.Unexpected;
            watch.accepted_len = share_buffer_len;
            return w.arm(watch);
        },
        else => error.Unexpected,
    };
}

/// Stops watching `id`.
pub fn remove(w: *Windows, id: WatchId) void {
    const entry = w.watches.fetchSwapRemove(id) orelse return;
    const watch = entry.value;
    w.budget.release(watch.root, w, stillCounted);
    _ = c.CancelIoEx(watch.handle, &watch.overlapped);
    _ = c.CloseHandle(watch.handle);
    // The buffer outlives the handle until the cancelled read's
    // completion has been taken off the port.
    watch.retiring_next = w.retiring;
    w.retiring = watch;
}

/// Whether a watch still held reads the entries of `dir`, so that its
/// count outlives the watch being removed. See `Budget.release`.
fn stillCounted(w: *const Windows, dir: []const u8) bool {
    for (w.watches.values()) |watch| {
        const reach = watch.reach() orelse continue;
        if (reach.covers(dir)) return true;
    }
    return false;
}

fn free(w: *Windows, watch: *Watch) void {
    w.gpa.free(watch.buffer);
    w.gpa.free(watch.root);
    watch.filter.deinit(w.gpa);
    if (watch.only) |name| w.gpa.free(name);
    if (watch.pending_rename) |name| w.gpa.free(name);
    w.gpa.destroy(watch);
}

/// Waits on the completion port until a read produces something `batch`
/// did not already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(w: *Windows, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    // A completion is taken off the port by the call that waits for it,
    // and the read it completes is re-armed before the next, so nothing
    // in here is a place to stop: see `Watcher.poll`. The wait itself is
    // out of `std.Io`'s reach.
    const protection = w.io.swapCancelProtection(.blocked);
    defer _ = w.io.swapCancelProtection(protection);
    const result = w.collect(batch, timeout_ms);
    // Whatever is still held when the wait is over never found its other
    // half: the path moved somewhere this watch cannot see it.
    try w.flushRenames(batch);
    return result;
}

/// Reports every held old name whose new name never came as a removal.
/// An old name the watch does not want was held only so that its new
/// name could be told apart from a rename in, and is not reported.
fn flushRenames(w: *Windows, batch: *Batch) lookout.Watcher.PollError!void {
    for (w.watches.values()) |watch| {
        const old = watch.pending_rename orelse continue;
        watch.pending_rename = null;
        defer w.gpa.free(old);
        if (!wants(watch, old)) continue;
        try batch.push(w.gpa, watch.id, old, .removed, watch.goneTarget());
    }
}

fn collect(w: *Windows, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const before = batch.revision;
    const deadline: Deadline = .start(w.io, timeout_ms);

    while (true) {
        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still takes one look at the port.
        const timeout: u32 = if (timeout_ms == null) c.INFINITE else deadline.windowsMs();

        var transferred: u32 = 0;
        var key: usize = 0;
        var overlapped: ?*c.OVERLAPPED = null;
        const ok = c.GetQueuedCompletionStatus(w.port, &transferred, &key, &overlapped, timeout);
        if (ok == 0) {
            if (overlapped == null) {
                // A finite timeout may have been clamped to what this API
                // can represent, so only the original deadline ends it.
                if (c.GetLastError() != c.WAIT_TIMEOUT) return error.Unexpected;
                if (!deadline.expired()) continue;
                return;
            }
            if (key == wake_key) return;
            const failed: WatchId = @enumFromInt(@as(u32, @truncate(key)));
            const err = c.GetLastError();
            const watch = w.live(failed, overlapped) orelse {
                // The completion of a read cancelled by `remove`. Its
                // buffer has been waiting for exactly this.
                w.retire(overlapped);
                continue;
            };
            if (err == c.ERROR_NOTIFY_ENUM_DIR) {
                // The kernel's other way of saying the buffer overflowed:
                // more change than it could hold, so re-read the tree.
                // The handle is still good, so the watch is re-armed.
                try batch.push(w.gpa, failed, watch.root, .overflow, .directory);
                w.lost(watch);
                try w.rearm(watch, batch);
                if (batch.revision != before) return;
                continue;
            }
            // Anything else means the directory the handle is on is gone:
            // deleted, or on a volume that went away. The handle was
            // opened with FILE_SHARE_DELETE precisely so that this can
            // happen, and a watched path that no longer exists is a
            // removal like any other.
            try batch.push(w.gpa, failed, watch.root, .removed, .directory);
            w.discard(failed);
            if (batch.revision != before) return;
            continue;
        }

        if (key == wake_key) return;
        const id: WatchId = @enumFromInt(@as(u32, @truncate(key)));
        const watch = w.live(id, overlapped) orelse {
            w.retire(overlapped);
            continue;
        };
        if (watch.only == null) switch (w.rootState(watch)) {
            .stands => {},
            .gone => {
                try batch.push(w.gpa, id, watch.root, .removed, .directory);
                w.discard(id);
                if (batch.revision != before) return;
                continue;
            },
            .moved, .unknown => {
                try batch.push(w.gpa, id, watch.root, .unwatched, .directory);
                w.discard(id);
                if (batch.revision != before) return;
                continue;
            },
        };
        if (transferred == 0) {
            // The kernel had more change than it could hold between two
            // reads and says so by transferring nothing.
            try batch.push(w.gpa, id, watch.root, .overflow, .directory);
            w.lost(watch);
        } else {
            try w.report(watch, transferred, batch);
        }
        try w.rearm(watch, batch);
        if (batch.revision != before) return;
    }
}

const RootState = enum { stands, moved, gone, unknown };

fn rootState(w: *const Windows, watch: *const Watch) RootState {
    const named = Io.Dir.cwd().statFile(w.io, watch.root, .{ .follow_symlinks = false }) catch {
        const opened: Io.File = .{ .handle = watch.handle, .flags = .{ .nonblocking = true } };
        const held = opened.stat(w.io) catch return .unknown;
        return if (held.nlink == 0) .gone else .moved;
    };
    return if (named.inode == watch.root_inode) .stands else .moved;
}

/// Reads again from disk the entry counts a lost read of `watch` leaves
/// wrong: the directories it reaches whose count rests on its reads. See
/// `Budget.reread` and `Budget.restsOn`.
///
/// Called once the read is over, before the next is posted: what the
/// kernel buffers from here on is read after the count and counted on
/// top of it, as it should be.
fn lost(w: *Windows, watch: *const Watch) void {
    const Loss = struct {
        w: *const Windows,
        watch: *const Watch,

        fn stale(loss: @This(), dir: []const u8) bool {
            return Budget.restsOn(loss.w.watches.values(), loss.watch, dir);
        }
    };
    w.budget.reread(Loss{ .w = w, .watch = watch }, Loss.stale);
}

/// Posts the next read, and says so when it cannot be posted.
///
/// A watch whose read cannot be armed again reports nothing ever after.
/// That used to be swallowed, which left the caller with a live watch id
/// over a tree that had gone quiet; now the watch is dropped and the
/// root is reported as `lookout.Kind.unwatched`, which is what it is.
fn rearm(w: *Windows, watch: *Watch, batch: *Batch) lookout.Watcher.PollError!void {
    w.arm(watch) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const root = try w.gpa.dupe(u8, watch.root);
            defer w.gpa.free(root);
            const id = watch.id;
            w.discard(id);
            try batch.push(w.gpa, id, root, .unwatched, .directory);
        },
    };
}

/// Drops a watch whose directory is gone. The read that failed is the
/// one that was outstanding, so nothing of the kernel's is left pointing
/// at the buffer and it can be freed here rather than retired.
fn discard(w: *Windows, id: WatchId) void {
    const entry = w.watches.fetchSwapRemove(id) orelse return;
    _ = c.CloseHandle(entry.value.handle);
    w.free(entry.value);
}

/// The watch a completion belongs to, or `null` when it belongs to a read
/// `remove` cancelled.
///
/// Matched on the overlapped pointer and not on the completion key alone.
/// The key is the `lookout.WatchId`, and an id can be registered a second
/// time: a watch on a path that does not exist yet is put on an ancestor
/// and then re-registered on the path itself under the same id the caller
/// holds. The cancelled read of the first registration completes after
/// the second one is armed, and keyed by id alone that completion reads
/// as the new watch's own read failing -- which closed a handle that had
/// just been opened and reported the path the caller was waiting for as
/// removed. Each `Watch` is heap-allocated and never moved, so the
/// address of its `overlapped` tells the two apart.
fn live(w: *Windows, id: WatchId, overlapped: ?*c.OVERLAPPED) ?*Watch {
    const watch = w.watches.get(id) orelse return null;
    if (overlapped != &watch.overlapped) return null;
    return watch;
}

/// Frees a retiring watch once its cancelled read has been accounted for.
fn retire(w: *Windows, overlapped: ?*c.OVERLAPPED) void {
    const completed = overlapped orelse return;
    var link = &w.retiring;
    while (link.*) |watch| {
        if (&watch.overlapped == completed) {
            link.* = watch.retiring_next;
            w.free(watch);
            return;
        }
        link = &watch.retiring_next;
    }
}

/// Turns one completed read into events.
fn report(w: *Windows, watch: *Watch, transferred: u32, batch: *Batch) lookout.Watcher.PollError!void {
    const dir = watch.dir();

    var it = records.iterate(watch.buffer[0..transferred]);
    while (true) {
        // A chain this cannot follow is a read that cannot be accounted
        // for: what is left of it is lost, and `lookout.Kind.overflow`
        // is what lookout says when it has lost something and cannot
        // say what. The caller already handles it.
        const record = it.next() catch {
            try batch.push(w.gpa, watch.id, watch.root, .overflow, .directory);
            w.lost(watch);
            return;
        } orelse return;

        const relative = try record.wtf8Alloc(w.gpa);
        defer w.gpa.free(relative);
        // The kernel spells a nested path with backslashes already, so
        // joining is only about the root.
        const path = try std.fs.path.join(w.gpa, &.{ dir, relative });
        defer w.gpa.free(path);
        trace.log("windows record watch={d} action={s} path={s}", .{
            @intFromEnum(watch.id), actionName(record.action), path,
        });

        // The kernel walked the tree whatever the filter says; what the
        // filter can still do is keep the event from the caller. The two
        // names of a rename are the exception: they are paired first and
        // the filter is applied to the pair -- see `reportRename`.
        switch (record.action) {
            c.FILE_ACTION_RENAMED_OLD_NAME, c.FILE_ACTION_RENAMED_NEW_NAME => {
                try w.reportRename(watch, record.action, path, batch);
            },
            else => if (wants(watch, path)) {
                try w.reportOne(watch, record.action, path, batch);
            },
        }
    }
}

/// A record's action as the documentation spells it, for the trace.
fn actionName(action: u32) []const u8 {
    return switch (action) {
        c.FILE_ACTION_ADDED => "ADDED",
        c.FILE_ACTION_REMOVED => "REMOVED",
        c.FILE_ACTION_MODIFIED => "MODIFIED",
        c.FILE_ACTION_RENAMED_OLD_NAME => "RENAMED_OLD_NAME",
        c.FILE_ACTION_RENAMED_NEW_NAME => "RENAMED_NEW_NAME",
        else => "unknown",
    };
}

/// Whether an event for `subject` is reported against `watch`: it is the
/// watched file, for a watch on one, and it is not excluded by the
/// filter.
fn wants(watch: *const Watch, subject: []const u8) bool {
    return if (watch.only == null)
        !watch.filter.excludes(watch.root, subject)
    else
        path_cmp.eql(subject, watch.root);
}

/// Holds an old name, or joins a new name to the old one held.
///
/// Both halves are held and joined whether or not the watch wants them,
/// and a name it does not want is then treated exactly as a name outside
/// the watch: both names wanted is `renamed`; only the new one wanted is
/// `created` there, as a rename in from outside would be; only the old
/// one wanted is `removed` there, as a rename out would be; neither is
/// nothing.
fn reportRename(w: *Windows, watch: *Watch, action: u32, subject: []const u8, batch: *Batch) lookout.Watcher.PollError!void {
    const wanted = wants(watch, subject);
    if (action == c.FILE_ACTION_RENAMED_OLD_NAME) {
        // Copied before the one it replaces is freed, so a copy that
        // fails leaves the watch holding what it held.
        const owned = try w.gpa.dupe(u8, subject);
        if (watch.pending_rename) |old| w.gpa.free(old);
        watch.pending_rename = owned;
        if (wanted) try w.recount(watch, subject, .vanished, batch);
        return;
    }
    const from = watch.pending_rename;
    watch.pending_rename = null;
    defer if (from) |old| w.gpa.free(old);
    const keeps_from = if (from) |old| wants(watch, old) else false;
    // The new name is where the entry is now, so it can be asked what the
    // entry is, whichever name is reported.
    const target = w.targetOf(subject);
    if (!wanted) {
        if (keeps_from) {
            const gone = if (target != .unknown) target else watch.goneTarget();
            try batch.push(w.gpa, watch.id, from.?, .removed, gone);
        }
        return;
    }
    watch.noteRoot(target);
    if (keeps_from) {
        try batch.pushRename(w.gpa, watch.id, subject, from.?, target);
    } else {
        // Renamed in from outside the watch, or from a name it does not
        // want: a creation as far as anyone watching it can tell.
        try batch.push(w.gpa, watch.id, subject, .created, target);
    }
    try w.recount(watch, subject, .appeared, batch);
}

/// What the path is now, for the actions that leave it there to be
/// asked. `ReadDirectoryChangesW` carries no bit saying whether a record
/// is about a directory, which is why this is a `stat` and why an entry
/// that is already gone is `unknown`; the watched path itself is the
/// exception, because `Watch.root_target` remembers it.
fn targetOf(w: *const Windows, subject: []const u8) Target {
    const stat = Io.Dir.cwd().statFile(w.io, subject, .{ .follow_symlinks = false }) catch
        return .unknown;
    return .of(stat.kind);
}

fn reportOne(w: *Windows, watch: *Watch, action: u32, subject: []const u8, batch: *Batch) lookout.Watcher.PollError!void {
    var move: Budget.Move = .unchanged;
    switch (action) {
        c.FILE_ACTION_ADDED => {
            const target = w.targetOf(subject);
            watch.noteRoot(target);
            try batch.push(w.gpa, watch.id, subject, .created, target);
            move = .appeared;
        },
        c.FILE_ACTION_REMOVED => {
            try batch.push(w.gpa, watch.id, subject, .removed, watch.goneTarget());
            move = .vanished;
        },
        c.FILE_ACTION_MODIFIED => {
            // A directory's own times move whenever anything inside it
            // moves, and no other backend reports that. The record does
            // not say which this is, so the file system is asked.
            const target = w.targetOf(subject);
            if (target != .directory) {
                try batch.push(w.gpa, watch.id, subject, .modified, target);
            }
        },
        else => {},
    }
    if (move == .unchanged) return;
    try w.recount(watch, subject, move, batch);
}

/// Keeps the entry budget of the directory `subject` is in, and reports
/// `lookout.Kind.overflow` when it is past.
///
/// The budget is one directory's, not one watch's: a recursive watch
/// over twenty directories of three hundred entries is inside a budget
/// of a thousand, and counting every creation anywhere under the root
/// against one number said it was not.
///
/// Nor is it counted once per watch. Every watch that reaches the
/// directory reads its own copy of the change -- two watches over one
/// folder, or a pending watch parked in a folder another watch holds --
/// and counting each copy reached the budget at half the folder's size.
/// One copy counts, chosen by `Budget.counter`, and when that takes the
/// directory past the budget every watch the change reached is told.
fn recount(w: *Windows, watch: *Watch, subject: []const u8, move: Budget.Move, batch: *Batch) lookout.Watcher.PollError!void {
    const change: Change = .{
        .dir = std.fs.path.dirname(subject) orelse return,
        .subject = subject,
    };
    if (Budget.counter(w.watches.values(), change, Change.reaches) != watch) return;
    if (!try w.budget.note(change.dir, move)) return;
    for (w.watches.values()) |other| {
        if (!change.reaches(other)) continue;
        try batch.push(w.gpa, other.id, other.root, .overflow, .directory);
    }
}

/// One change to an entry, as every watch reads its own copy of it.
const Change = struct {
    /// The directory the entry is in.
    dir: []const u8,
    subject: []const u8,

    /// Whether `watch` read a copy of this change and keeps it, as one
    /// of the entries of a directory it reports. See `Watch.reach`.
    fn reaches(change: Change, watch: *Watch) bool {
        const reach = watch.reach() orelse return false;
        return reach.covers(change.dir) and wants(watch, change.subject);
    }
};

test "a read that completes with nothing is an overflow, and the watch reads on" {
    // ReadDirectoryChangesW: "If the number of changes exceeds the
    // buffer size, the entire contents of the buffer are discarded, the
    // lpBytesReturned parameter contains zero". Through a completion
    // port that is a packet that transferred nothing, and
    // PostQueuedCompletionStatus can post one in the kernel's place --
    // "Posts an I/O completion packet to an I/O completion port", with
    // the byte count and the OVERLAPPED the caller gives it, dequeued by
    // GetQueuedCompletionStatus like any other. It is the one overflow
    // signal a test can make: a burst the kernel cannot hold between
    // two reads is not something a test can order.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .windows });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    while ((try watcher.poll(200)).len != 0) {}
    const w = &watcher.impl.windows;
    const watch = w.watches.get(id).?;

    // The read that is outstanding is taken back first -- cancelled,
    // and its completion taken off the port -- so that the packet
    // posted below stands in for it rather than beside it: a watch
    // re-armed while a read is still pending would have two reads on
    // one buffer, which is not a state the kernel ever puts it in.
    _ = c.CancelIoEx(watch.handle, &watch.overlapped);
    {
        var transferred: u32 = 0;
        var key: usize = 0;
        var overlapped: ?*c.OVERLAPPED = null;
        while (true) {
            const ok = c.GetQueuedCompletionStatus(w.port, &transferred, &key, &overlapped, 10_000);
            if (ok == 0 and overlapped == null) return error.TestUnexpectedResult;
            if (overlapped == &watch.overlapped) break;
        }
    }
    try testing.expect(c.PostQueuedCompletionStatus(w.port, 0, @intFromEnum(id), &watch.overlapped) != 0);

    var overflows: usize = 0;
    var waited: u32 = 0;
    while (waited < 10_000 and overflows == 0) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind != .overflow) continue;
            try testing.expectEqual(id, event.id);
            try testing.expectEqualStrings(root, event.path);
            try testing.expectEqual(Target.directory, event.target);
            overflows += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), overflows);

    // Re-armed: the watch is still held, and the next change is read.
    try testing.expect(w.watches.contains(id));
    try tmp.dir.writeFile(io, .{ .sub_path = "after.txt", .data = "x" });
    const after = try std.fs.path.join(gpa, &.{ root, "after.txt" });
    defer gpa.free(after);
    var found = false;
    waited = 0;
    while (waited < 10_000 and !found) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind == .created and std.mem.eql(u8, event.path, after)) found = true;
        }
    }
    try testing.expect(found);
}

test "a lost read reads the entry counts again, so the budget holds after it" {
    // Three creations, read and counted; then the count set back to what
    // it would have been had the kernel discarded them, which is what a
    // read it could not hold does ("the entire contents of the buffer
    // are discarded"). The completion that says so is posted by hand,
    // as above. A count that is not read again stays three short for as
    // long as the watch lasts.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .windows, .max_dir_entries = 3 });
    defer watcher.deinit();
    const id = try watcher.add(root, .{});
    while ((try watcher.poll(200)).len != 0) {}
    const w = &watcher.impl.windows;
    const watch = w.watches.get(id).?;

    for ([_][]const u8{ "a", "b", "c" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }
    var created: usize = 0;
    var waited: u32 = 0;
    while (waited < 10_000 and created < 3) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind == .created) created += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), created);
    w.budget.counts.getPtr(root).?.* = 0;

    _ = c.CancelIoEx(watch.handle, &watch.overlapped);
    {
        var transferred: u32 = 0;
        var key: usize = 0;
        var overlapped: ?*c.OVERLAPPED = null;
        while (true) {
            const ok = c.GetQueuedCompletionStatus(w.port, &transferred, &key, &overlapped, 10_000);
            if (ok == 0 and overlapped == null) return error.TestUnexpectedResult;
            if (overlapped == &watch.overlapped) break;
        }
    }
    try testing.expect(c.PostQueuedCompletionStatus(w.port, 0, @intFromEnum(id), &watch.overlapped) != 0);

    var overflowed = false;
    waited = 0;
    while (waited < 10_000 and !overflowed) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind == .overflow) overflowed = true;
        }
    }
    try testing.expect(overflowed);
    // Three entries: at the budget, as the folder is.
    try testing.expectEqual(@as(usize, 3), w.budget.counts.get(root).?);

    // So the fourth is past it, and the watch is told.
    try tmp.dir.writeFile(io, .{ .sub_path = "d", .data = "x" });
    overflowed = false;
    waited = 0;
    while (waited < 10_000 and !overflowed) : (waited += 200) {
        for (try watcher.poll(200)) |event| {
            if (event.kind == .overflow and event.id == id and std.mem.eql(u8, event.path, root)) overflowed = true;
        }
    }
    try testing.expect(overflowed);
}

/// The Win32 surface lookout uses, declared against `std.os.windows`'
/// types.
///
/// `std.os.windows` in Zig 0.16.0 declares neither
/// `ReadDirectoryChangesW` nor the completion-port calls, so they are
/// written out here. Hand-written rather than `@cImport`ed, for the same
/// reason as everywhere else in this package: no C compilation step.
const c = struct {
    const HANDLE = windows.HANDLE;
    const DWORD = windows.DWORD;
    const WCHAR = windows.WCHAR;
    const BOOL = c_int;

    const INFINITE: DWORD = 0xFFFF_FFFF;
    const WAIT_TIMEOUT: DWORD = 258;

    const ERROR_FILE_NOT_FOUND: DWORD = 2;
    const ERROR_PATH_NOT_FOUND: DWORD = 3;
    const ERROR_ACCESS_DENIED: DWORD = 5;
    const ERROR_NOT_ENOUGH_MEMORY: DWORD = 8;
    const ERROR_OUTOFMEMORY: DWORD = 14;
    const ERROR_TOO_MANY_OPEN_FILES: DWORD = 4;
    const ERROR_INVALID_PARAMETER: DWORD = 87;
    const ERROR_IO_PENDING: DWORD = 997;
    /// The kernel could not hold everything that changed between two
    /// reads: the buffer overflowed and the tree must be re-read.
    const ERROR_NOTIFY_ENUM_DIR: DWORD = 1022;

    const FILE_LIST_DIRECTORY: DWORD = 0x0001;
    const FILE_SHARE_READ: DWORD = 0x0001;
    const FILE_SHARE_WRITE: DWORD = 0x0002;
    const FILE_SHARE_DELETE: DWORD = 0x0004;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x0200_0000;
    const FILE_FLAG_OVERLAPPED: DWORD = 0x4000_0000;

    const FILE_NOTIFY_CHANGE_FILE_NAME: DWORD = 0x001;
    const FILE_NOTIFY_CHANGE_DIR_NAME: DWORD = 0x002;
    const FILE_NOTIFY_CHANGE_ATTRIBUTES: DWORD = 0x004;
    const FILE_NOTIFY_CHANGE_SIZE: DWORD = 0x008;
    const FILE_NOTIFY_CHANGE_LAST_WRITE: DWORD = 0x010;
    const FILE_NOTIFY_CHANGE_CREATION: DWORD = 0x040;
    const FILE_NOTIFY_CHANGE_SECURITY: DWORD = 0x100;

    const FILE_ACTION_ADDED: DWORD = 1;
    const FILE_ACTION_REMOVED: DWORD = 2;
    const FILE_ACTION_MODIFIED: DWORD = 3;
    const FILE_ACTION_RENAMED_OLD_NAME: DWORD = 4;
    const FILE_ACTION_RENAMED_NEW_NAME: DWORD = 5;

    const OVERLAPPED = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: DWORD,
        OffsetHigh: DWORD,
        hEvent: ?HANDLE,
    };

    const SECURITY_ATTRIBUTES = extern struct {
        nLength: DWORD,
        lpSecurityDescriptor: ?*anyopaque,
        bInheritHandle: BOOL,
    };

    const OVERLAPPED_COMPLETION_ROUTINE = *const fn (DWORD, DWORD, *OVERLAPPED) callconv(.winapi) void;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const WCHAR,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
    extern "kernel32" fn CreateIoCompletionPort(
        FileHandle: HANDLE,
        ExistingCompletionPort: ?HANDLE,
        CompletionKey: usize,
        NumberOfConcurrentThreads: DWORD,
    ) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn PostQueuedCompletionStatus(
        CompletionPort: HANDLE,
        dwNumberOfBytesTransferred: DWORD,
        dwCompletionKey: usize,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn GetQueuedCompletionStatus(
        CompletionPort: HANDLE,
        lpNumberOfBytesTransferred: *DWORD,
        lpCompletionKey: *usize,
        lpOverlapped: *?*OVERLAPPED,
        dwMilliseconds: DWORD,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadDirectoryChangesW(
        hDirectory: HANDLE,
        lpBuffer: *anyopaque,
        nBufferLength: DWORD,
        bWatchSubtree: BOOL,
        dwNotifyFilter: DWORD,
        lpBytesReturned: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?OVERLAPPED_COMPLETION_ROUTINE,
    ) callconv(.winapi) BOOL;
};
