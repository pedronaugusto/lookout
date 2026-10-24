//! How a test waits for what a watcher reports: on the clock, never by
//! counting polls. A poll returns as soon as anything is ready, so a count
//! of them is no measure of time, and a busy machine delivers late.

const std = @import("std");
const Io = std.Io;
const timing = @import("../timing.zig");

/// How long a test waits for an event it caused. A passing test never
/// waits it out, so it is as long as a loaded machine's file-system events
/// can take; only a failure pays it.
pub const event_ms = 30_000;

/// How long a test watches for an event that must not come: a window, which
/// every passing test waits out.
pub const quiet_ms = 2_000;

/// A point on the monotonic clock a wait gives up at.
pub const Deadline = struct {
    timeout: Io.Timeout,

    pub fn after(io: Io, ms: u32) Deadline {
        return .{ .timeout = timing.within(ms).toDeadline(io) };
    }

    /// Whether there is time left.
    pub fn running(d: Deadline, io: Io) bool {
        return !timing.expired(io, d.timeout);
    }
};
