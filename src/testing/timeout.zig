//! The timeout the tests hand `lookout.Watcher.poll`.

const std = @import("std");
const Io = std.Io;

/// A timeout of `n` milliseconds on the monotonic clock.
pub fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}
