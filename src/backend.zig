//! The backends, and which of them this target is built with.
//!
//! Each file under `backend/` is one mechanism, a struct that a `Watcher`
//! holds one of. Which of them a target has is `Impl`, written out per
//! target rather than generated, because the set really is different per
//! target and a reader should be able to see which.

const std = @import("std");
const builtin = @import("builtin");

const types = @import("types.zig");
const Backend = types.Backend;

pub const FsEvents = @import("backend/FsEvents.zig");
pub const Kqueue = @import("backend/Kqueue.zig");
pub const Inotify = @import("backend/Inotify.zig");
pub const Windows = @import("backend/Windows.zig");
/// The backend every target has, so every shape of `Impl` holds it, and a
/// watcher keeps one beside its native backend for the watches it polls.
pub const Poll = @import("backend/Poll.zig");

/// Every backend this target was built with, one of which a watcher
/// chose. The tag names match `Backend`'s, which is what lets
/// `Watcher.init`, `supported` and `Watcher.backend` be one line each.
pub const Impl = switch (builtin.target.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => union(enum) {
        fsevents: FsEvents,
        kqueue: Kqueue,
        poll: Poll,
    },
    .dragonfly, .freebsd, .netbsd, .openbsd => union(enum) {
        kqueue: Kqueue,
        poll: Poll,
    },
    .linux => union(enum) {
        inotify: Inotify,
        poll: Poll,
    },
    .windows => union(enum) {
        windows: Windows,
        poll: Poll,
    },
    else => union(enum) {
        poll: Poll,
    },
};

// `supported` answers from a list of its own, below the backends, so the
// two lists are held to each other here: a backend is built exactly where
// `supported` says it is.
comptime {
    for (std.enums.values(Backend)) |backend| {
        if (backend == .auto) continue;
        std.debug.assert(@hasField(Impl, @tagName(backend)) == types.supported(backend));
    }
}

test {
    _ = Poll;
    // Held-event transfers use no Windows calls and are tested on every host.
    _ = @import("backend/Windows.zig");
}
