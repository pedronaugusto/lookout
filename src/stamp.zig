//! The times a filesystem stamps on a file, and the readings of the clock
//! they are compared with: instants on the real clock, in nanoseconds, as
//! std's stat gives them.

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// A time a filesystem stamped, or a reading of the clock it stamps from.
pub const Stamp = aegis.units.Instant(.real, .nanosecond, i96);

/// A span between two stamps.
pub const Span = aegis.units.Duration(.nanosecond, i96);

/// The stamp std's stat gives: `stat.mtime`, `stat.ctime`.
pub fn of(time: Io.Timestamp) Stamp {
    return .fromTimestamp(time, .exact);
}

/// The real clock's reading now.
pub fn now(io: Io) Stamp {
    return of(Io.Clock.real.now(io));
}

/// A C `timespec`'s stamp: whole seconds since the epoch and the
/// nanoseconds past them.
pub fn ofTimespec(seconds: i64, nanoseconds: i64) Stamp {
    const whole = aegis.units.Instant(.real, .second, i64).fromRaw(seconds).convert(.nanosecond, i96, .exact);
    return whole.saturatingAdd(.fromRaw(nanoseconds));
}

test "a timespec's seconds and nanoseconds are one stamp, before the epoch too" {
    try std.testing.expectEqual(@as(i96, 1_500_000_002), ofTimespec(1, 500_000_002).raw());
    try std.testing.expectEqual(@as(i96, -999_999_999), ofTimespec(-1, 1).raw());
    try std.testing.expectEqual(of(.fromNanoseconds(7)), ofTimespec(0, 7));
}
