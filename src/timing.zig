//! How a backend waits, and the arithmetic on timeouts that goes with it.
//!
//! Every backend waits for the same two things: its own descriptor to have
//! something, or the watcher's `reactor.Wake` to be set. The wait itself is
//! reactor's, over whichever `std.Io` the caller has: native on a reactor
//! runtime, a descriptor wait in slices on any other. What stays here is
//! where a cancellation may land.
//!
//! A backend runs its work under `std.Io`'s cancel protection, because an
//! event the kernel handed over and lookout has not yet recorded would be
//! lost to a cancellation. `ready` lifts that protection for exactly the
//! wait, which takes nothing off any descriptor, so a cancellation ends the
//! wait with the batch intact and the kernel's events still queued.

const std = @import("std");
const Io = std.Io;
const reactor = @import("reactor");

/// A timeout of `ms` milliseconds on the monotonic clock.
pub fn within(ms: u32) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

/// Whether `timeout` has run out. One that never does has not. A timeout
/// of zero has, which is what makes a `poll` given one still make a single
/// non-blocking check: waits check before they give up.
pub fn expired(io: Io, timeout: Io.Timeout) bool {
    const left = timeout.toDurationFromNow(io) orelse return false;
    return left.raw.nanoseconds <= 0;
}

/// Whichever of the two timeouts ends first.
pub fn soonest(io: Io, a: Io.Timeout, b: Io.Timeout) Io.Timeout {
    const left_a = a.toDurationFromNow(io) orelse return b;
    const left_b = b.toDurationFromNow(io) orelse return a;
    return if (left_a.raw.nanoseconds <= left_b.raw.nanoseconds) a else b;
}

/// Milliseconds left of `timeout`, rounded up so a wait never ends before
/// it, or null when it never runs out. Zero means it has. For the waits
/// that are not reactor's: a completion port takes milliseconds.
pub fn remainingMs(io: Io, timeout: Io.Timeout) ?u32 {
    const left = timeout.toDurationFromNow(io) orelse return null;
    if (left.raw.nanoseconds <= 0) return 0;
    const ms = @divFloor(left.raw.nanoseconds - 1, std.time.ns_per_ms) + 1;
    return @intCast(@min(ms, std.math.maxInt(u32)));
}

/// What a wait can end in besides a member being ready.
pub const Error = Io.Cancelable || error{Unexpected};

/// The index of the first member of `set` that is ready, or null when
/// `timeout` ran out first. The one place a backend's wait may be
/// canceled: see the top of this file.
pub fn ready(io: Io, set: []const reactor.Waitable, timeout: Io.Timeout) Error!?usize {
    const protection = io.swapCancelProtection(.unblocked);
    defer _ = io.swapCancelProtection(protection);
    return reactor.waitAny(io, set, timeout) catch |err| switch (err) {
        error.Timeout => null,
        error.Canceled => error.Canceled,
        error.Unsupported, error.Unexpected => error.Unexpected,
    };
}

const testing = std.testing;
const shakedown = @import("shakedown");

test "a timeout that never runs out never expires" {
    try testing.expect(!expired(testing.io, .none));
    try testing.expectEqual(@as(?u32, null), remainingMs(testing.io, .none));
}

test "a timeout that has run out is expired and has nothing left" {
    var clock: shakedown.Clock = .init(testing.io, .{});
    const io = clock.io();
    const timeout = within(10).toDeadline(io);
    try testing.expect(!expired(io, timeout));
    clock.advance(.fromMilliseconds(100));
    try testing.expect(expired(io, timeout));
    try testing.expectEqual(@as(?u32, 0), remainingMs(io, timeout));
    try testing.expect(expired(io, within(0)));
}

test "what is left rounds up, so a wait never ends before its deadline" {
    var clock: shakedown.Clock = .init(testing.io, .{});
    const io = clock.io();
    const one_ns: Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } };
    try testing.expectEqual(@as(?u32, 1), remainingMs(io, one_ns));
    try testing.expectEqual(@as(?u32, 2_500), remainingMs(io, within(2_500)));
    // Past what a completion port takes is the largest it does.
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), remainingMs(io, .{ .duration = .{ .raw = .fromSeconds(std.math.maxInt(u32)), .clock = .awake } }));
}

test "the sooner of two timeouts, and a timeout that never ends gives way" {
    var clock: shakedown.Clock = .init(testing.io, .{});
    const io = clock.io();
    const short = within(5);
    const long = within(500);
    try testing.expectEqual(short, soonest(io, short, long));
    try testing.expectEqual(short, soonest(io, long, short));
    try testing.expectEqual(short, soonest(io, .none, short));
    try testing.expectEqual(long, soonest(io, long, .none));
}
