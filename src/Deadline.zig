//! How much of a caller's timeout is left.
//!
//! Every backend blocks on something different -- a descriptor, a kernel
//! queue, a completion port, a sleep -- and every one of them has to
//! answer the same question first: the caller asked for `timeout_ms`,
//! some of it has gone, how much may this call wait for?
//!
//! The arithmetic is short and was written out five times, once per
//! backend, with the same two rules each time. The rules are what matter
//! and they are stated here once: a timeout of `null` never expires, and
//! an expired timeout is clamped to zero rather than returned on, so
//! that `lookout.Watcher.poll(0)` still performs one non-blocking check
//! instead of reporting nothing, ever.

const std = @import("std");
const Io = std.Io;

const Deadline = @This();

io: Io,
started: Io.Timestamp,
/// The caller's timeout in milliseconds, or `null` for no timeout.
total: ?u32,

/// Starts the clock now.
pub fn start(io: Io, timeout_ms: ?u32) Deadline {
    return .{ .io = io, .started = .now(io, .awake), .total = timeout_ms };
}

/// Milliseconds left, or `null` when there is no timeout at all. Zero
/// means it has expired.
pub fn remainingMs(d: Deadline) ?u32 {
    const total = d.total orelse return null;
    const elapsed = d.started.durationTo(Io.Timestamp.now(d.io, .awake)).toMilliseconds();
    return @intCast(@max(0, @as(i64, total) - elapsed));
}

/// Whether the timeout has run out. A deadline with no timeout never has.
pub fn expired(d: Deadline) bool {
    return (d.remainingMs() orelse return false) == 0;
}

/// What `poll(2)` wants: milliseconds, or `-1` to block indefinitely.
pub fn pollMs(d: Deadline) i32 {
    return @intCast(d.remainingMs() orelse return -1);
}

/// What `GetQueuedCompletionStatus` wants: milliseconds, or `INFINITE`.
pub fn windowsMs(d: Deadline) u32 {
    return d.remainingMs() orelse std.math.maxInt(u32);
}

const testing = std.testing;

test "no timeout never expires and never clamps" {
    const d: Deadline = .start(testing.io, null);
    try testing.expectEqual(@as(?u32, null), d.remainingMs());
    try testing.expect(!d.expired());
    try testing.expectEqual(@as(i32, -1), d.pollMs());
    try testing.expectEqual(std.math.maxInt(u32), d.windowsMs());
}

test "a timeout that has run out clamps to zero rather than going negative" {
    var d: Deadline = .start(testing.io, 10);
    // Reaching back in time is the same as waiting, and a test that
    // waits on a wall clock is a test that fails on a loaded machine.
    d.started.nanoseconds -= 100 * std.time.ns_per_ms;
    try testing.expectEqual(@as(?u32, 0), d.remainingMs());
    try testing.expect(d.expired());
    try testing.expectEqual(@as(i32, 0), d.pollMs());
    try testing.expectEqual(@as(u32, 0), d.windowsMs());
}

test "a deadline in the future has time left on it" {
    const d: Deadline = .start(testing.io, 2_500);
    const left = d.remainingMs().?;
    try testing.expect(left > 0 and left <= 2_500);
    try testing.expect(!d.expired());
}
