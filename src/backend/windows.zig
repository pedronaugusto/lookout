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
const WatchId = lookout.WatchId;

const Windows = @This();

gpa: Allocator,
io: Io,
/// The completion port every watch's reads land on.
port: windows.HANDLE,
watches: std.AutoArrayHashMapUnmanaged(WatchId, *Watch),
/// Watches whose handle is closed but whose buffer the kernel may not
/// have finished with. Freed when their completion arrives, or at
/// `deinit` once the port is closed.
retiring: std.ArrayList(*Watch),
/// Mirrors `lookout.Options.max_dir_entries`.
max_dir_entries: usize,

/// How much change the kernel may buffer between two reads. Past this a
/// read completes with zero bytes and lookout reports
/// `lookout.Kind.overflow`.
const read_buffer_len = 64 * 1024;

/// One watch: one directory handle with one read outstanding.
///
/// Heap-allocated and never moved, because the kernel writes into
/// `buffer` and `overlapped` for as long as a read is pending.
const Watch = struct {
    id: WatchId,
    /// The path the caller named, absolute and canonical, in WTF-8.
    root: []u8,
    /// The directory the read is posted on: `root`, or its parent when
    /// the caller named a file.
    handle: windows.HANDLE,
    /// Set when the caller named a file: only this name, relative to the
    /// directory the handle is on, is the watch.
    only: ?[]u8,
    recursive: bool,
    overlapped: c.OVERLAPPED,
    buffer: [read_buffer_len]u8 align(@alignOf(u32)),
    /// The old name of a rename whose new name has not arrived yet.
    pending_rename: ?[]u8,
    /// How many entries the watched directory holds, for the
    /// `lookout.Options.max_dir_entries` budget.
    entries: usize,
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
        .retiring = .empty,
        .max_dir_entries = options.max_dir_entries,
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
    // The port is closed before the retiring buffers are freed: after
    // that no completion can reference them.
    _ = c.CloseHandle(w.port);
    for (w.retiring.items) |watch| w.free(watch);
    w.retiring.deinit(w.gpa);
    w.* = undefined;
}

/// No descriptor: a completion port is not something another wait loop
/// can take, so a Windows program drives the watcher by calling
/// `lookout.Watcher.poll`.
pub fn fd(w: *const Windows) ?std.posix.fd_t {
    _ = w;
    return null;
}

/// Registers `abs_path`, a copy of which the backend keeps.
pub fn add(w: *Windows, id: WatchId, abs_path: []const u8, options: lookout.AddOptions) lookout.Watcher.AddError!void {
    for (w.watches.values()) |existing| {
        if (std.mem.eql(u8, existing.root, abs_path)) return error.PathAlreadyWatched;
    }
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

    watch.* = .{
        .id = id,
        .root = root,
        .handle = handle,
        .only = only,
        .recursive = options.recursive and is_dir,
        .overlapped = std.mem.zeroes(c.OVERLAPPED),
        .buffer = undefined,
        .pending_rename = null,
        .entries = countEntries(w.io, dir_path),
    };

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
    _ = w;
    watch.overlapped = std.mem.zeroes(c.OVERLAPPED);
    const filter: u32 = c.FILE_NOTIFY_CHANGE_FILE_NAME | c.FILE_NOTIFY_CHANGE_DIR_NAME |
        c.FILE_NOTIFY_CHANGE_ATTRIBUTES | c.FILE_NOTIFY_CHANGE_SIZE |
        c.FILE_NOTIFY_CHANGE_LAST_WRITE | c.FILE_NOTIFY_CHANGE_CREATION |
        c.FILE_NOTIFY_CHANGE_SECURITY;
    if (c.ReadDirectoryChangesW(
        watch.handle,
        &watch.buffer,
        watch.buffer.len,
        @intFromBool(watch.recursive),
        filter,
        null,
        &watch.overlapped,
        null,
    ) == 0) return switch (c.GetLastError()) {
        c.ERROR_IO_PENDING => {},
        c.ERROR_NOT_ENOUGH_MEMORY, c.ERROR_OUTOFMEMORY => error.SystemResources,
        else => error.Unexpected,
    };
}

/// Stops watching `id`.
pub fn remove(w: *Windows, id: WatchId) void {
    const entry = w.watches.fetchSwapRemove(id) orelse return;
    const watch = entry.value;
    _ = c.CancelIoEx(watch.handle, &watch.overlapped);
    _ = c.CloseHandle(watch.handle);
    // The buffer outlives the handle until the cancelled read's
    // completion has been taken off the port.
    w.retiring.append(w.gpa, watch) catch w.free(watch);
}

fn free(w: *Windows, watch: *Watch) void {
    w.gpa.free(watch.root);
    if (watch.only) |name| w.gpa.free(name);
    if (watch.pending_rename) |name| w.gpa.free(name);
    w.gpa.destroy(watch);
}

/// Waits on the completion port until a read produces something `batch`
/// did not already hold, or `timeout_ms` expires. `null` never gives up.
pub fn wait(w: *Windows, batch: *Batch, timeout_ms: ?u32) lookout.Watcher.PollError!void {
    const before = batch.events.items.len;
    const started: Io.Timestamp = .now(w.io, .awake);

    while (true) {
        // Clamped rather than returned on, so that a `timeout_ms` of zero
        // still takes one look at the port.
        const timeout: u32 = timeout: {
            const total = timeout_ms orelse break :timeout c.INFINITE;
            const elapsed = started.durationTo(Io.Timestamp.now(w.io, .awake)).toMilliseconds();
            break :timeout @intCast(@max(0, @as(i64, total) - elapsed));
        };

        var transferred: u32 = 0;
        var key: usize = 0;
        var overlapped: ?*c.OVERLAPPED = null;
        const ok = c.GetQueuedCompletionStatus(w.port, &transferred, &key, &overlapped, timeout);
        if (ok == 0) {
            if (overlapped == null) return switch (c.GetLastError()) {
                // Nothing arrived in time, or the port is gone.
                c.WAIT_TIMEOUT => {},
                else => error.Unexpected,
            };
            // A failed read: the watch is going away, or its directory
            // did. Retire whatever it belonged to and carry on.
            w.retire(@enumFromInt(@as(u32, @truncate(key))));
            continue;
        }

        const id: WatchId = @enumFromInt(@as(u32, @truncate(key)));
        const watch = w.watches.get(id) orelse {
            w.retire(id);
            continue;
        };
        if (transferred == 0) {
            // The kernel had more change than it could hold between two
            // reads and says so by transferring nothing.
            try batch.push(w.gpa, id, watch.root, .overflow);
        } else {
            try w.report(watch, transferred, batch);
        }
        w.arm(watch) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        if (batch.events.items.len > before) return;
    }
}

/// Frees a retiring watch once its cancelled read has been accounted for.
fn retire(w: *Windows, id: WatchId) void {
    for (w.retiring.items, 0..) |watch, i| {
        if (watch.id != id) continue;
        _ = w.retiring.swapRemove(i);
        w.free(watch);
        return;
    }
}

/// Turns one completed read into events.
fn report(w: *Windows, watch: *Watch, transferred: u32, batch: *Batch) lookout.Watcher.PollError!void {
    const dir = if (watch.only == null) watch.root else std.fs.path.dirname(watch.root) orelse watch.root;

    var offset: usize = 0;
    while (offset + @sizeOf(c.FILE_NOTIFY_INFORMATION) <= transferred) {
        const info: *align(4) const c.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(&watch.buffer[offset]));
        const name_bytes = watch.buffer[offset + @sizeOf(c.FILE_NOTIFY_INFORMATION) ..][0..info.FileNameLength];
        const name_wide = std.mem.bytesAsSlice(u16, @as([]align(2) const u8, @alignCast(name_bytes)));

        const relative = try std.unicode.wtf16LeToWtf8Alloc(w.gpa, name_wide);
        defer w.gpa.free(relative);
        // The kernel spells a nested path with backslashes already, so
        // joining is only about the root.
        const path = try std.fs.path.join(w.gpa, &.{ dir, relative });
        defer w.gpa.free(path);

        if (watch.only == null or std.mem.eql(u8, path, watch.root)) {
            try w.reportOne(watch, info.Action, path, batch);
        }

        if (info.NextEntryOffset == 0) break;
        offset += info.NextEntryOffset;
    }

    // A rename whose second half never came: the file left the watch.
    if (watch.pending_rename) |old| {
        try batch.push(w.gpa, watch.id, old, .removed);
        w.gpa.free(old);
        watch.pending_rename = null;
    }
}

fn reportOne(w: *Windows, watch: *Watch, action: u32, path: []const u8, batch: *Batch) lookout.Watcher.PollError!void {
    switch (action) {
        c.FILE_ACTION_ADDED => {
            try batch.push(w.gpa, watch.id, path, .created);
            watch.entries += 1;
        },
        c.FILE_ACTION_REMOVED => {
            try batch.push(w.gpa, watch.id, path, .removed);
            watch.entries -|= 1;
        },
        c.FILE_ACTION_MODIFIED => try batch.push(w.gpa, watch.id, path, .modified),
        c.FILE_ACTION_RENAMED_OLD_NAME => {
            if (watch.pending_rename) |old| w.gpa.free(old);
            watch.pending_rename = try w.gpa.dupe(u8, path);
        },
        c.FILE_ACTION_RENAMED_NEW_NAME => {
            if (watch.pending_rename) |old| {
                defer w.gpa.free(old);
                watch.pending_rename = null;
                try batch.pushRename(w.gpa, watch.id, path, old);
            } else {
                // Renamed in from outside the watch: a creation as far as
                // anyone watching this tree can tell.
                try batch.push(w.gpa, watch.id, path, .created);
                watch.entries += 1;
            }
        },
        else => {},
    }
    if (watch.entries > w.max_dir_entries) {
        try batch.push(w.gpa, watch.id, watch.root, .overflow);
    }
}

fn countEntries(io: Io, path: []const u8) usize {
    var dir = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(io) catch null) |_| count += 1;
    return count;
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
    const ERROR_IO_PENDING: DWORD = 997;

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

    /// A variable-length record: `FileName` of `FileNameLength` bytes
    /// follows, and `NextEntryOffset` steps to the next one.
    const FILE_NOTIFY_INFORMATION = extern struct {
        NextEntryOffset: DWORD,
        Action: DWORD,
        FileNameLength: DWORD,
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
