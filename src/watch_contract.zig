//! Operation results shared by the watcher and its platform adapters.
const std = @import("std");
const Io = std.Io;
const Tree = @import("Tree.zig");
const types = @import("types.zig");
const WatchId = types.WatchId;
const Filter = @import("Filter.zig");

/// Errors `init` can return when creating the backend's resources.
/// FSEvents also allocates its delivery sink and `Options.buffer_bytes`
/// buffer here, even with no watches. Allocator failures are
/// `OutOfMemory`. Other backends allocate as watches are added.
pub const InitError = error{
    /// `Options.backend` names a backend this target was not built
    /// with. See `supported`.
    BackendUnavailable,
    /// The system-wide descriptor table is full.
    SystemFdQuotaExceeded,
    /// This process may not open another descriptor.
    ProcessFdQuotaExceeded,
    /// The system could not create the notification queue.
    SystemResources,
    /// The allocator could not create the FSEvents delivery sink or buffer.
    OutOfMemory,
} || UnexpectedError;

/// Errors `add` can return, on top of the file-system errors of
/// resolving and opening the path.
pub const AddError = error{
    /// The checkpoint belongs to a different volume or FSEvents log.
    InvalidCheckpoint,
    /// The kernel refused another watch: the per-process or
    /// system-wide limit on watches or descriptors is reached.
    WatchLimitReached,
    /// This watcher already watches that path. See `add`.
    PathAlreadyWatched,
} || Tree.AddError || UnexpectedError;

/// Errors changing a live watch's filter.
pub const RefilterError = AddError || error{UnknownWatch};

/// Errors `poll` can return, on top of the file-system errors of
/// re-reading watched directories.
///
/// One set for every backend, and true for every one of them.
/// `error.Canceled` is in it because `poll` is a cancellation point on
/// all five: see `poll` for where. The backend is chosen when the
/// watcher is made, not when the program is compiled, so a set per
/// backend would be a set per value of `Options.backend` — and every
/// backend re-reads directories through `std.Io`, whose file-system
/// errors carry `error.Canceled` anyway.
pub const PollError = Tree.ScanError || Io.Cancelable || UnexpectedError;

/// A system call failed with a code lookout does not model. This is
/// the escape hatch every backend shares, so that an error set is a
/// promise about the whole API rather than about one platform.
pub const UnexpectedError = error{Unexpected};

/// One watch, as `watches` reports it.
pub const WatchInfo = struct {
    /// The id `add` returned.
    id: WatchId,
    /// The path the caller asked for. Owned by the watcher and valid
    /// until the next `add`, `remove` or `deinit`.
    path: []const u8,
    /// `AddOptions.recursive`.
    recursive: bool,
    /// Whether the path is still not there, so the watch is parked
    /// on an ancestor. See `AddOptions.pending`.
    waiting: bool,
};
