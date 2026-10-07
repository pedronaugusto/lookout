//! How much of a caller's timeout is left.
//!
//! Every backend blocks on something different -- a descriptor, a kernel
//! queue, a completion port, a sleep -- and every one of them has to
//! answer the same question first: the caller gave a `std.Io.Timeout`,
//! some of it has gone, how many milliseconds may this call wait for?
//!
//! The arithmetic is short and was written out five times, once per
//! backend, with the same rules each time. The rules are what matter and
//! they are stated here once: `.none` never expires; what is left is
//! rounded up to the millisecond, so a wait never ends before its
//! deadline; and an expired timeout is clamped to zero rather than
//! returned on, so that a `lookout.Watcher.poll` given a zero duration
//! still performs one non-blocking check instead of reporting nothing,
//! ever.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Deadline = @This();

/// When the timeout runs out, on the clock it was given in, or `null` when
/// it never does.
due: ?Io.Clock.Timestamp,

/// Fixes the deadline `timeout` names, as of now.
pub fn start(io: Io, timeout: Io.Timeout) Deadline {
    return .{ .due = timeout.toTimestamp(io) };
}

/// A deadline `ms` milliseconds from now on the monotonic clock, or none
/// for `null`: the form the watcher hands its backends a wait in.
pub fn fromMs(io: Io, ms: ?u32) Deadline {
    const span = ms orelse return .{ .due = null };
    return .start(io, .{ .duration = .{ .raw = .fromMilliseconds(span), .clock = .awake } });
}

/// Milliseconds left, rounded up, or `null` when there is no timeout at
/// all. Zero means it has expired.
pub fn remainingMs(d: Deadline, io: Io) ?u32 {
    const due = d.due orelse return null;
    const left = due.durationFromNow(io).raw.nanoseconds;
    if (left <= 0) return 0;
    const ms = @divFloor(left - 1, std.time.ns_per_ms) + 1;
    return @intCast(@min(ms, std.math.maxInt(u32)));
}

/// Whether the timeout has run out. A deadline with no timeout never has.
pub fn expired(d: Deadline, io: Io) bool {
    return (d.remainingMs(io) orelse return false) == 0;
}

/// What `poll(2)` wants: milliseconds, or `-1` to block indefinitely.
pub fn pollMs(d: Deadline, io: Io) i32 {
    const remaining = d.remainingMs(io) orelse return -1;
    return @intCast(@min(remaining, std.math.maxInt(i32)));
}

/// What `GetQueuedCompletionStatus` wants: milliseconds, or `INFINITE`.
pub fn windowsMs(d: Deadline, io: Io) u32 {
    const remaining = d.remainingMs(io) orelse return std.math.maxInt(u32);
    const ms = @min(remaining, std.math.maxInt(u32) - 1);
    // A timeout, however long, is never the value that means none.
    assert(ms != std.math.maxInt(u32));
    return ms;
}

const testing = std.testing;
const clock = @import("testing/clock.zig");

test "no timeout never expires and never clamps" {
    var vtable: Io.VTable = undefined;
    const io = clock.frozen(testing.io, &vtable);
    const d: Deadline = .start(io, .none);
    try testing.expectEqual(@as(?u32, null), d.remainingMs(io));
    try testing.expect(!d.expired(io));
    try testing.expectEqual(@as(i32, -1), d.pollMs(io));
    try testing.expectEqual(std.math.maxInt(u32), d.windowsMs(io));
}

test "a timeout that has run out clamps to zero rather than going negative" {
    var vtable: Io.VTable = undefined;
    const io = clock.frozen(testing.io, &vtable);
    var d: Deadline = .fromMs(io, 10);
    // Reaching back in time is the same as waiting, and a test that
    // waits on a wall clock is a test that fails on a loaded machine.
    d.due.?.raw.nanoseconds -= 100 * std.time.ns_per_ms;
    try testing.expectEqual(@as(?u32, 0), d.remainingMs(io));
    try testing.expect(d.expired(io));
    try testing.expectEqual(@as(i32, 0), d.pollMs(io));
    try testing.expectEqual(@as(u32, 0), d.windowsMs(io));
}

test "a deadline in the future has time left on it" {
    var vtable: Io.VTable = undefined;
    const io = clock.frozen(testing.io, &vtable);
    const d: Deadline = .fromMs(io, 2_500);
    try testing.expectEqual(@as(?u32, 2_500), d.remainingMs(io));
    try testing.expect(!d.expired(io));
}

test "what is left rounds up, so a wait never ends before its deadline" {
    var vtable: Io.VTable = undefined;
    const io = clock.frozen(testing.io, &vtable);
    const d: Deadline = .start(io, .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } });
    try testing.expectEqual(@as(?u32, 1), d.remainingMs(io));
    const past: Deadline = .start(io, .{ .deadline = .{ .raw = .zero, .clock = .awake } });
    try testing.expectEqual(@as(?u32, 0), past.remainingMs(io));
}

test "finite waits are clamped to each operating system API" {
    var vtable: Io.VTable = undefined;
    const io = clock.frozen(testing.io, &vtable);
    const posix_long: Deadline = .fromMs(io, @as(u32, std.math.maxInt(i32)) + 1);
    try testing.expectEqual(std.math.maxInt(i32), posix_long.pollMs(io));

    const windows_long: Deadline = .fromMs(io, std.math.maxInt(u32));
    try testing.expectEqual(std.math.maxInt(u32) - 1, windows_long.windowsMs(io));
}
