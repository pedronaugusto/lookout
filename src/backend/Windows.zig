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
//! `x86_64-windows-msvc`, and the shared suite in src/testing/suite_test.zig is
//! what runs it on a Windows host.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;
const windows = std.os.windows;

const lookout = @import("../types.zig");
const Batch = @import("../Batch.zig");
const Budget = @import("../Budget.zig");
const Deadline = @import("../Deadline.zig");
const Filter = @import("../Filter.zig");
const buffer = @import("../buffer.zig");
const path_cmp = @import("../path.zig");
const records = @import("windows/records.zig");
const Waker = @import("../Waker.zig");
const trace = @import("../trace.zig");
const Options = @import("../options.zig").Options;
const contract = @import("../watch_contract.zig");
const AddOptions = @import("../options.zig").AddOptions;
const builtin = @import("builtin");
const Target = lookout.Target;
const WatchId = lookout.WatchId;

const Windows = @This();

gpa: Allocator,
io: Io,
/// The completion port every watch's reads land on.
port: windows.HANDLE,
watches: std.array_hash_map.Auto(WatchId, *Watch),
/// Watches whose handle is closed but whose buffer the kernel may not
/// have finished with. An intrusive list so retiring a watch cannot fail
/// for want of an allocation while overlapped I/O still references it.
retiring: ?*Watch,
/// How many entries each watched directory holds, against
/// `@import("../options.zig").Options.max_dir_entries`.
budget: Budget,
/// `@import("../options.zig").Options.buffer_bytes`, clamped and rounded to what
/// `ReadDirectoryChangesW` will take. See `bounds`.
buffer_len: usize,

/// What `@import("../options.zig").Options.buffer_bytes` may ask for here.
///
/// The floor is 4 KiB; a record with a long relative name can exceed it
/// and require an overflow notice and a rescan. The ceiling is a size
/// past which the call is a bad idea
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
    /// `@import("../options.zig").AddOptions.filter`, copied.
    ///
    /// `ReadDirectoryChangesW` recurses in the kernel and cannot be told
    /// to leave a directory out, so here the filter drops the events
    /// rather than saving the work -- see `lookout.prunesIgnored`.
    filter: Filter,
    overlapped: c.Overlapped,
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
    /// A wanted name whose removal was the last thing a read said, held
    /// for the next read to decide. See `reportRemoval`.
    ///
    /// The kernel completes a read as soon as there is one record for
    /// it, so the replaced entry's removal can end one read and the
    /// rename that replaced it open the next. Reported at once, the
    /// removal and the creation fall into one window where the removal
    /// outranks it. Held rather than reported, the next read says which
    /// it was, and `collect` gives that read a short grace to come.
    held_removal: ?[]u8,
    /// How much of the buffer the kernel is willing to take. Lowered
    /// once, to `share_buffer_len`, if the size asked for is refused.
    accepted_len: usize,
    retiring_next: ?*Watch,
    /// Taking a packet off the port does not release its buffer. Keep it
    /// until reporting and posting the next read have both succeeded.
    completion: ?Completion = null,
    reported: bool = false,
    cursor: ?records.Iterator = null,

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
        return if (watch.only == null) watch.root else std.Io.Dir.path.dirname(watch.root) orelse watch.root;
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
pub fn init(gpa: Allocator, io: Io, options: Options) contract.InitError!Windows {
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

/// How another thread pokes a blocked `wait`: the completion port, which
/// is fixed for the life of the watcher. See `lookout.Watcher.wake`.
pub fn waker(w: *const Windows) Waker {
    return .{ .context = @intFromPtr(w.port), .call = post }; // safe: the port's handle value, fixed for the watcher's life, turned back by post alone
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
    options: AddOptions,
    batch: *Batch,
) contract.AddError!void {
    _ = batch;
    const stat = try Io.Dir.cwd().statFile(w.io, abs_path, .{});
    const is_dir = stat.kind == .directory;

    // `ReadDirectoryChangesW` reads directories, so a watch on a file is
    // a read on its parent filtered down to the one name.
    const dir_path = if (is_dir) abs_path else std.Io.Dir.path.dirname(abs_path) orelse abs_path;
    const only: ?[]u8 = if (is_dir) null else try w.gpa.dupe(u8, std.Io.Dir.path.basename(abs_path));
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
        .overlapped = std.mem.zeroes(c.Overlapped),
        .buffer = bytes,
        .pending_rename = null,
        .held_removal = null,
        .accepted_len = w.buffer_len,
        .retiring_next = null,
    };
    if (is_dir) try w.budget.seed(dir_path);

    if (c.CreateIoCompletionPort(handle, w.port, @backingInt(id), 0) == null)
        return error.WatchLimitReached;
    try w.watches.put(w.gpa, id, watch);
    errdefer _ = w.watches.swapRemove(id);
    try w.arm(watch);
}

/// Opens a directory for overlapped change notification.
fn open(gpa: Allocator, path: []const u8) contract.AddError!windows.HANDLE {
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.BadPathName,
    };
    defer gpa.free(wide);

    const handle = c.CreateFileW(
        wide.ptr,
        c.file_list_directory,
        // FILE_SHARE_DELETE is the one that matters: without it, watching
        // a directory would stop anyone else from deleting or renaming
        // it, which is not what a watcher is for.
        c.file_share_read | c.file_share_write | c.file_share_delete,
        null,
        c.open_existing,
        c.file_flag_backup_semantics | c.file_flag_overlapped,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return switch (c.GetLastError()) {
        c.error_file_not_found, c.error_path_not_found => error.FileNotFound,
        c.error_access_denied => error.AccessDenied,
        c.error_too_many_open_files => error.ProcessFdQuotaExceeded,
        else => error.Unexpected,
    };
    return handle;
}

/// Posts the outstanding read for a watch. Every completion re-posts,
/// because a change that arrives while no read is outstanding is a change
/// the kernel has to buffer.
fn arm(w: *Windows, watch: *Watch) contract.AddError!void {
    // The kernel is offered at most the buffer it writes into.
    assert(watch.accepted_len <= watch.buffer.len);
    watch.overlapped = std.mem.zeroes(c.Overlapped);
    const filter: u32 = c.file_notify_change_file_name | c.file_notify_change_dir_name |
        c.file_notify_change_attributes | c.file_notify_change_size |
        c.file_notify_change_last_write | c.file_notify_change_creation |
        c.file_notify_change_security;
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
        c.error_io_pending => {},
        c.error_not_enough_memory, c.error_outofmemory => error.SystemResources,
        // A remote directory refuses a buffer over 64 KiB outright
        // rather than clamping it. Coming down to what a share takes is
        // the difference between a smaller buffer and a dead watch.
        c.error_invalid_parameter => {
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
    w.budget.release(*const Windows, stillCounted, watch.root, w);
    _ = c.CancelIoEx(watch.handle, &watch.overlapped);
    _ = c.CloseHandle(watch.handle);
    // A retained completion has already ended the kernel's ownership.
    // No packet remains to retire this watch on a later wait.
    if (watch.completion != null) {
        w.free(watch);
        return;
    }
    // The buffer outlives the handle until the cancelled read's
    // completion has been taken off the port.
    watch.retiring_next = w.retiring;
    w.retiring = watch;
}

/// Replaces the delivery filter; the kernel's recursive read stays armed.
pub fn refilter(w: *Windows, id: WatchId, next: lookout.Filter, batch: *Batch) contract.RefilterError!void {
    _ = batch;
    const watch = w.watches.get(id) orelse return error.UnknownWatch;
    const replacement = try next.dupe(w.gpa);
    var previous = watch.filter;
    watch.filter = replacement;
    previous.deinit(w.gpa);
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
    if (watch.held_removal) |name| w.gpa.free(name);
    w.gpa.destroy(watch);
}

/// Waits on the completion port until a read produces something `batch`
/// did not already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(w: *Windows, batch: *Batch, timeout_ms: ?u32) contract.PollError!void {
    // A completion is taken off the port by the call that waits for it,
    // and the read it completes is re-armed before the next, so nothing
    // in here is a place to stop: see `Watcher.poll`. The wait itself is
    // out of `std.Io`'s reach.
    const protection = w.io.swapCancelProtection(.blocked);
    defer _ = w.io.swapCancelProtection(protection);
    try w.collect(batch, timeout_ms);
    // Whatever is still held when the wait is over never found its other
    // half: the path moved somewhere this watch cannot see it. A removal
    // is resolved first, being the older of the two.
    try w.resolveRemovals(batch);
    try w.flushRenames(batch);
}

/// Reports every held old name whose new name never came as a removal.
/// An old name the watch does not want was held only so that its new
/// name could be told apart from a rename in, and is not reported.
fn flushRenames(w: *Windows, batch: *Batch) contract.PollError!void {
    for (w.watches.values()) |watch| {
        const old = watch.pending_rename orelse continue;
        if (wants(watch, old))
            try batch.push(w.gpa, watch.id, old, .removed, watch.goneTarget());
        watch.pending_rename = null;
        w.gpa.free(old);
    }
}

fn collect(w: *Windows, batch: *Batch, timeout_ms: ?u32) contract.PollError!void {
    const before = batch.revision;
    const deadline: Deadline = .start(w.io, timeout_ms);

    while (true) {
        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still takes one look at the port.
        const timeout: u32 = if (timeout_ms == null) c.infinite else deadline.windowsMs();
        switch (try w.take(batch, timeout)) {
            .woken => return,
            // A finite timeout may have been clamped to what this API
            // can represent, so only the original deadline ends it.
            .quiet => if (deadline.expired()) return else continue,
            .taken => {},
        }
        // A removal that ended its read is worth waiting a moment for:
        // the rename that replaced the entry is on its way in the next
        // one, and deciding now would report the name gone while a file
        // stands there. See `Watch.held_removal`.
        var round: usize = 0;
        while (w.holdsRemoval() and round < grace_rounds) : (round += 1) {
            switch (try w.take(batch, grace_ms)) {
                .taken => {},
                .quiet, .woken => break,
            }
        }
        // A removal no move followed within the grace is decided now,
        // not when the next change happens to come, which a wait with no
        // deadline could make never.
        try w.resolveRemovals(batch);
        if (batch.revision != before) return;
    }
}

/// How long a removal that ended its read is held for the next read,
/// and how many reads in a row. See `Watch.held_removal`.
///
/// Paid only when a read ends on a removal. The kernel writes the rename
/// that replaced an entry in the same call as the removal, so what is
/// missing is already buffered, or completes the read posted next, within
/// microseconds of the removal: the grace is for the thread to be
/// scheduled, not for anything to happen.
const grace_ms = 25;
const grace_rounds = 4;

const Taken = enum {
    /// A completion was taken and dealt with.
    taken,
    /// `timeout` passed with nothing on the port.
    quiet,
    /// `wake` posted.
    woken,
};

/// Takes one completion off the port, waiting up to `timeout`, and turns
/// it into events.
const Completion = struct {
    transferred: u32,
    failure: ?u32,
};

fn take(w: *Windows, batch: *Batch, timeout: u32) contract.PollError!Taken {
    // A completion already taken is ready even if the port is quiet.
    for (w.watches.values()) |watch| {
        if (watch.completion != null) {
            try w.complete(watch, batch);
            return .taken;
        }
    }
    var transferred: u32 = 0;
    var key: usize = 0;
    var overlapped: ?*c.Overlapped = null;
    const ok = c.GetQueuedCompletionStatus(w.port, &transferred, &key, &overlapped, timeout);
    const failure: ?u32 = if (ok == 0) c.GetLastError() else null;
    if (overlapped == null and ok == 0) {
        if (failure.? != c.wait_timeout) return error.Unexpected;
        return .quiet;
    }
    if (key == wake_key) return .woken;
    const id: WatchId = @fromBackingInt(@intCast(@as(u32, @truncate(key))));
    const watch = w.live(id, overlapped) orelse {
        w.retire(overlapped);
        return .taken;
    };
    watch.completion = .{ .transferred = transferred, .failure = failure };
    try w.complete(watch, batch);
    return .taken;
}

/// Finishes a retained completion before its buffer can be overwritten.
fn complete(w: *Windows, watch: *Watch, batch: *Batch) contract.PollError!void {
    const completion = watch.completion.?;
    const id = watch.id;
    if (!watch.reported) {
        if (completion.failure) |err| {
            try w.resolveRemoval(watch, batch);
            if (err != c.error_notify_enum_dir) {
                try batch.push(w.gpa, id, watch.root, .removed, .directory);
                w.discard(id);
                return;
            }
            try batch.push(w.gpa, id, watch.root, .overflow, .directory);
            w.lost(watch);
        } else {
            if (watch.only == null) switch (w.rootState(watch)) {
                .stands => {},
                .gone => {
                    try w.resolveRemoval(watch, batch);
                    try batch.push(w.gpa, id, watch.root, .removed, .directory);
                    w.discard(id);
                    return;
                },
                .moved, .unknown => {
                    try w.resolveRemoval(watch, batch);
                    try batch.push(w.gpa, id, watch.root, .unwatched, .directory);
                    w.discard(id);
                    return;
                },
            };
            if (completion.transferred == 0) {
                try w.resolveRemoval(watch, batch);
                try batch.push(w.gpa, id, watch.root, .overflow, .directory);
                w.lost(watch);
            } else {
                w.report(watch, completion.transferred, batch) catch |err| {
                    w.lost(watch);
                    return err;
                };
            }
        }
        watch.reported = true;
    }
    // rearm may discard the watch; keep no reference to it afterwards.
    const armed = try w.rearm(watch, batch);
    if (armed) {
        watch.completion = null;
        watch.reported = false;
        watch.cursor = null;
    }
}

/// Whether a watch holds a removal for its next read to decide.
fn holdsRemoval(w: *const Windows) bool {
    for (w.watches.values()) |watch| {
        if (watch.held_removal != null) return true;
    }
    return false;
}

/// Reports every held removal as the removal it is: no move onto its
/// name came.
fn resolveRemovals(w: *Windows, batch: *Batch) contract.PollError!void {
    for (w.watches.values()) |watch| try w.resolveRemoval(watch, batch);
}

/// Reports `watch`'s held removal, if it holds one.
fn resolveRemoval(w: *Windows, watch: *Watch, batch: *Batch) contract.PollError!void {
    const gone = watch.held_removal orelse return;
    trace.log("windows push removed held path={s}", .{gone});
    try batch.push(w.gpa, watch.id, gone, .removed, watch.goneTarget());
    watch.held_removal = null;
    w.gpa.free(gone);
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

        const Self = @This();

        fn stale(loss: Self, dir: []const u8) bool {
            return Budget.restsOn(loss.w.watches.values(), loss.watch, dir);
        }
    };
    w.budget.reread(Loss, Loss.stale, .{ .w = w, .watch = watch });
}

/// Posts the next read, and says so when it cannot be posted.
///
/// A watch whose read cannot be armed again reports nothing ever after.
/// That used to be swallowed, which left the caller with a live watch id
/// over a tree that had gone quiet; now the watch is dropped and the
/// root is reported as `lookout.Kind.unwatched`, which is what it is.
fn rearm(w: *Windows, watch: *Watch, batch: *Batch) contract.PollError!bool {
    w.arm(watch) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const root = try w.gpa.dupe(u8, watch.root);
            defer w.gpa.free(root);
            const id = watch.id;
            try batch.push(w.gpa, id, root, .unwatched, .directory);
            w.discard(id);
            return false;
        },
    };
    return true;
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
fn live(w: *Windows, id: WatchId, overlapped: ?*c.Overlapped) ?*Watch {
    const watch = w.watches.get(id) orelse return null;
    if (overlapped != &watch.overlapped) return null;
    return watch;
}

/// Frees a retiring watch once its cancelled read has been accounted for.
fn retire(w: *Windows, overlapped: ?*c.Overlapped) void {
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
fn report(w: *Windows, watch: *Watch, transferred: u32, batch: *Batch) contract.PollError!void {
    // A completed read wrote no more than `arm` offered.
    assert(transferred <= watch.accepted_len);
    const dir = watch.dir();

    if (watch.cursor == null) {
        const it = records.iterate(watch.buffer[0..transferred]);
        if (watch.held_removal) |gone| {
            // The last read ended on this removal; this one says whether a
            // move onto the name came next.
            const replaced = switch (records.arrival(it)) {
                .moved => |record| try w.sameName(record, dir, gone),
                .none, .unsaid => false,
            };
            if (replaced) {
                trace.log("windows drop replaced held path={s}", .{gone});
                watch.held_removal = null;
                w.gpa.free(gone);
            } else {
                try w.resolveRemoval(watch, batch);
            }
        }
        watch.cursor = it;
    }
    while (true) {
        var it = watch.cursor.?;
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
        const path = try std.Io.Dir.path.join(w.gpa, &.{ dir, relative });
        defer w.gpa.free(path);
        trace.log("windows record watch={d} action={s} path={s}", .{
            @backingInt(watch.id), actionName(record.action), path,
        });

        // The kernel walked the tree whatever the filter says; what the
        // filter can still do is keep the event from the caller. The two
        // names of a rename are the exception: they are paired first and
        // the filter is applied to the pair -- see `reportRename`.
        switch (record.action) {
            c.file_action_renamed_old_name, c.file_action_renamed_new_name => {
                try w.reportRename(watch, record.action, path, batch);
            },
            c.file_action_removed => if (wants(watch, path)) {
                try w.reportRemoval(watch, it, dir, path, batch);
            },
            else => if (wants(watch, path)) {
                try w.reportOne(watch, record.action, path, batch);
            },
        }
        watch.cursor = it;
    }
}

/// Reports the removal of `path`, unless the records `rest` has still to
/// walk go on to move an entry onto its name.
///
/// Replacing an entry by a rename, `ReadDirectoryChangesW` writes as the
/// replaced entry's `FILE_ACTION_REMOVED` and then the rename: an old
/// name and a new name within the directory, or an `ADDED` from another.
/// Reported as it comes, the removal lands in the window with the
/// creation or the rename, and the removal outranks both, so a file saved
/// by renaming over a watched name was reported `removed` while it stood
/// there. The rename says everything: on `inotify` and FSEvents it is the
/// only record of the move, and what the caller hears is `created` or
/// `renamed` at the name, by the rule `reportRename` keeps. When the read
/// ends before it says, the removal is held for the next one:
/// `Watch.held_removal`.
///
/// The records carry no more than that. An entry deleted and another
/// created at the same name, back to back, is written the same way as a
/// move onto it from another directory, and is reported as that move:
/// `created`, which says the name holds an entry it did not before.
///
/// Either way the entry that was at `path` left, so the count moves now.
fn reportRemoval(w: *Windows, watch: *Watch, rest: records.Iterator, dir: []const u8, path: []const u8, batch: *Batch) contract.PollError!void {
    switch (records.arrival(rest)) {
        .moved => |record| if (try w.sameName(record, dir, path)) {
            trace.log("windows drop replaced path={s}", .{path});
            return w.recount(watch, path, .vanished, batch);
        },
        .none => {},
        .unsaid => {
            trace.log("windows hold removed path={s}", .{path});
            try w.resolveRemoval(watch, batch);
            watch.held_removal = try w.gpa.dupe(u8, path);
            return w.recount(watch, path, .vanished, batch);
        },
    }
    try w.reportOne(watch, c.file_action_removed, path, batch);
}

/// Whether `record`, read on `dir`, names `path`.
fn sameName(w: *Windows, record: records.Record, dir: []const u8, path: []const u8) Allocator.Error!bool {
    const relative = try record.wtf8Alloc(w.gpa);
    defer w.gpa.free(relative);
    const there = try std.Io.Dir.path.join(w.gpa, &.{ dir, relative });
    defer w.gpa.free(there);
    return path_cmp.eql(there, path);
}

/// A record's action as the documentation spells it, for the trace.
fn actionName(action: u32) []const u8 {
    return switch (action) {
        c.file_action_added => "ADDED",
        c.file_action_removed => "REMOVED",
        c.file_action_modified => "MODIFIED",
        c.file_action_renamed_old_name => "RENAMED_OLD_NAME",
        c.file_action_renamed_new_name => "RENAMED_NEW_NAME",
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
fn reportRename(w: *Windows, watch: *Watch, action: u32, subject: []const u8, batch: *Batch) contract.PollError!void {
    const wanted = wants(watch, subject);
    if (action == c.file_action_renamed_old_name) {
        // Copied before the one it replaces is freed, so a copy that
        // fails leaves the watch holding what it held.
        const owned = try w.gpa.dupe(u8, subject);
        if (watch.pending_rename) |old| w.gpa.free(old);
        watch.pending_rename = owned;
        if (wanted) try w.recount(watch, subject, .vanished, batch);
        return;
    }
    const from = watch.pending_rename;
    var transferred = false;
    defer if (transferred) {
        watch.pending_rename = null;
        if (from) |old| w.gpa.free(old);
    };
    const keeps_from = if (from) |old| wants(watch, old) else false;
    // The new name is where the entry is now, so it can be asked what the
    // entry is, whichever name is reported.
    const target = w.targetOf(subject);
    if (!wanted) {
        if (keeps_from) {
            const gone = if (target != .unknown) target else watch.goneTarget();
            try batch.push(w.gpa, watch.id, from.?, .removed, gone);
        }
        transferred = true;
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
    transferred = true;
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

fn reportOne(w: *Windows, watch: *Watch, action: u32, subject: []const u8, batch: *Batch) contract.PollError!void {
    var move: Budget.Move = .unchanged;
    switch (action) {
        c.file_action_added => {
            const target = w.targetOf(subject);
            watch.noteRoot(target);
            try batch.push(w.gpa, watch.id, subject, .created, target);
            move = .appeared;
        },
        c.file_action_removed => {
            try batch.push(w.gpa, watch.id, subject, .removed, watch.goneTarget());
            move = .vanished;
        },
        c.file_action_modified => {
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
fn recount(w: *Windows, watch: *Watch, subject: []const u8, move: Budget.Move, batch: *Batch) contract.PollError!void {
    const change: Change = .{
        .dir = std.Io.Dir.path.dirname(subject) orelse return,
        .subject = subject,
    };
    if (Budget.counter(*Watch, Change, Change.reaches, w.watches.values(), change) != watch) return;
    if (!try w.budget.note(change.dir, std.Io.Dir.path.basename(subject), move)) return;
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

/// The Win32 surface lookout uses, declared against `std.os.windows`'
/// types.
///
/// `std.os.windows` in Zig 0.17.0 declares neither
/// `ReadDirectoryChangesW` nor the completion-port calls, so they are
/// written out here. Hand-written rather than `@cImport`ed, for the same
/// reason as everywhere else in this package: no C compilation step.
const c = struct {
    // Win32's names, in Zig's casing: `ERROR_IO_PENDING` is
    // `error_io_pending` and `OVERLAPPED` is `Overlapped`. Functions keep
    // their symbol names and parameters their documented ones.
    const Bool = c_int;

    const infinite: windows.DWORD = 0xFFFF_FFFF;
    const wait_timeout: windows.DWORD = 258;

    const error_file_not_found: windows.DWORD = 2;
    const error_path_not_found: windows.DWORD = 3;
    const error_access_denied: windows.DWORD = 5;
    const error_not_enough_memory: windows.DWORD = 8;
    const error_outofmemory: windows.DWORD = 14;
    const error_too_many_open_files: windows.DWORD = 4;
    const error_invalid_parameter: windows.DWORD = 87;
    const error_io_pending: windows.DWORD = 997;
    /// The kernel could not hold everything that changed between two
    /// reads: the buffer overflowed and the tree must be re-read.
    const error_notify_enum_dir: windows.DWORD = 1022;

    const file_list_directory: windows.DWORD = 0x0001;
    const file_share_read: windows.DWORD = 0x0001;
    const file_share_write: windows.DWORD = 0x0002;
    const file_share_delete: windows.DWORD = 0x0004;
    const open_existing: windows.DWORD = 3;
    const file_flag_backup_semantics: windows.DWORD = 0x0200_0000;
    const file_flag_overlapped: windows.DWORD = 0x4000_0000;

    const file_notify_change_file_name: windows.DWORD = 0x001;
    const file_notify_change_dir_name: windows.DWORD = 0x002;
    const file_notify_change_attributes: windows.DWORD = 0x004;
    const file_notify_change_size: windows.DWORD = 0x008;
    const file_notify_change_last_write: windows.DWORD = 0x010;
    const file_notify_change_creation: windows.DWORD = 0x040;
    const file_notify_change_security: windows.DWORD = 0x100;

    const file_action_added: windows.DWORD = records.Action.added;
    const file_action_removed: windows.DWORD = records.Action.removed;
    const file_action_modified: windows.DWORD = records.Action.modified;
    const file_action_renamed_old_name: windows.DWORD = records.Action.renamed_old_name;
    const file_action_renamed_new_name: windows.DWORD = records.Action.renamed_new_name;

    const Overlapped = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: windows.DWORD,
        OffsetHigh: windows.DWORD,
        hEvent: ?windows.HANDLE,
    };

    const SecurityAttributes = extern struct {
        nLength: windows.DWORD,
        lpSecurityDescriptor: ?*anyopaque,
        bInheritHandle: Bool,
    };

    const OverlappedCompletionRoutine = *const fn (windows.DWORD, windows.DWORD, *Overlapped) callconv(.winapi) void;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const windows.WCHAR,
        dwDesiredAccess: windows.DWORD,
        dwShareMode: windows.DWORD,
        lpSecurityAttributes: ?*SecurityAttributes,
        dwCreationDisposition: windows.DWORD,
        dwFlagsAndAttributes: windows.DWORD,
        hTemplateFile: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) Bool;
    extern "kernel32" fn CancelIoEx(hFile: windows.HANDLE, lpOverlapped: ?*Overlapped) callconv(.winapi) Bool;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn CreateIoCompletionPort(
        FileHandle: windows.HANDLE,
        ExistingCompletionPort: ?windows.HANDLE,
        CompletionKey: usize,
        NumberOfConcurrentThreads: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn PostQueuedCompletionStatus(
        CompletionPort: windows.HANDLE,
        dwNumberOfBytesTransferred: windows.DWORD,
        dwCompletionKey: usize,
        lpOverlapped: ?*Overlapped,
    ) callconv(.winapi) Bool;
    extern "kernel32" fn GetQueuedCompletionStatus(
        CompletionPort: windows.HANDLE,
        lpNumberOfBytesTransferred: *windows.DWORD,
        lpCompletionKey: *usize,
        lpOverlapped: *?*Overlapped,
        dwMilliseconds: windows.DWORD,
    ) callconv(.winapi) Bool;
    extern "kernel32" fn ReadDirectoryChangesW(
        hDirectory: windows.HANDLE,
        lpBuffer: *anyopaque,
        nBufferLength: windows.DWORD,
        bWatchSubtree: Bool,
        dwNotifyFilter: windows.DWORD,
        lpBytesReturned: ?*windows.DWORD,
        lpOverlapped: ?*Overlapped,
        lpCompletionRoutine: ?OverlappedCompletionRoutine,
    ) callconv(.winapi) Bool;
};

test "a failed Windows removal transfer keeps its held path" {
    try expectHeldTransferFailure(.removal);
}

test "a failed Windows rename flush keeps its held path" {
    try expectHeldTransferFailure(.flush);
}

test "a failed Windows rename pair transfer keeps its held path" {
    try expectHeldTransferFailure(.pair);
}

fn expectHeldTransferFailure(comptime transfer: enum { removal, flush, pair }) !void {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const old_path = try std.Io.Dir.path.join(testing.allocator, &.{ root, "old" });
    defer testing.allocator.free(old_path);
    const new_path = try std.Io.Dir.path.join(testing.allocator, &.{ root, "new" });
    defer testing.allocator.free(new_path);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    // Only the state used by these platform-independent transfers is live.
    var backend: Windows = undefined;
    backend.gpa = failing.allocator();
    backend.io = testing.io;
    backend.watches = .empty;
    defer backend.watches.deinit(testing.allocator);
    backend.budget = .init(testing.allocator, testing.io, 8);
    defer backend.budget.deinit();
    var watch: Watch = undefined;
    watch.id = @fromBackingInt(@intCast(0));
    watch.root = root;
    watch.only = null;
    watch.filter = .none;
    watch.root_target = .directory;
    watch.recursive = false;
    watch.held_removal = null;
    watch.pending_rename = null;
    defer if (watch.held_removal) |held| testing.allocator.free(held);
    defer if (watch.pending_rename) |held| testing.allocator.free(held);
    try backend.watches.put(testing.allocator, watch.id, &watch);
    var batch: Batch = .init(testing.io, .{});
    defer batch.deinit(testing.allocator);
    const held = try testing.allocator.dupe(u8, old_path);
    if (transfer == .removal) watch.held_removal = held else watch.pending_rename = held;

    const result = switch (transfer) {
        .removal => backend.resolveRemoval(&watch, &batch),
        .flush => backend.flushRenames(&batch),
        .pair => backend.reportRename(&watch, c.file_action_renamed_new_name, new_path, &batch),
    };
    try testing.expectError(error.OutOfMemory, result);
    const kept = if (transfer == .removal) watch.held_removal else watch.pending_rename;
    try testing.expect(kept != null);
    try testing.expectEqualStrings(old_path, kept.?);
    try testing.expectEqual(@as(usize, 0), batch.events.items.len);
    backend.gpa = testing.allocator;
    switch (transfer) {
        .removal => try backend.resolveRemoval(&watch, &batch),
        .flush => try backend.flushRenames(&batch),
        .pair => try backend.reportRename(&watch, c.file_action_renamed_new_name, new_path, &batch),
    }
    try testing.expectEqual(@as(usize, 1), batch.events.items.len);
    try testing.expectEqual(if (transfer == .pair) lookout.Kind.renamed else .removed, batch.events.items[0].kind);
    try testing.expect(watch.held_removal == null and watch.pending_rename == null);
}

// Integration fixtures use the adapter’s own callback and native declarations.
pub const test_access = if (builtin.is_test) struct {
    pub const c = cAccess;
} else struct {};

const cAccess = struct {
    pub const CancelIoEx = c.CancelIoEx;
    pub const GetQueuedCompletionStatus = c.GetQueuedCompletionStatus;
    pub const Overlapped = c.Overlapped;
    pub const PostQueuedCompletionStatus = c.PostQueuedCompletionStatus;
};
