//! A running account of what a backend did, for diagnosing an event that
//! did not arrive.
//!
//! Off unless `LOOKOUT_TRACE` is set in the environment, and compiled out
//! entirely where libc is not linked, which is where the environment
//! cannot be read without an allocator. Every Apple target links it, and
//! the Apple backend is what this exists for.
//!
//! Lines go to standard error, one per decision, prefixed so that a run
//! can be grepped for one path. Nothing here is on a path a caller takes
//! when the variable is unset: the check is one relaxed load.

const std = @import("std");
const builtin = @import("builtin");

const unknown: u8 = 0;
const off: u8 = 1;
const on: u8 = 2;

var resolved: std.atomic.Value(u8) = .init(unknown);

/// Whether tracing was asked for. Read from the environment once and
/// remembered, because a watcher asks per event.
pub fn enabled() bool {
    switch (resolved.load(.monotonic)) {
        on => return true,
        off => return false,
        else => {},
    }
    const asked = if (builtin.link_libc)
        std.c.getenv("LOOKOUT_TRACE") != null
    else
        false;
    resolved.store(if (asked) on else off, .monotonic);
    return asked;
}

/// One traced line. A no-op, and not even a formatting call, when tracing
/// is off.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!enabled()) return;
    std.debug.print("lookout: " ++ fmt ++ "\n", args);
}
