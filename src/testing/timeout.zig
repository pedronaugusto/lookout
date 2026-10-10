//! What the test files share: the timeouts they hand
//! `lookout.Watcher.poll` and the backends they run against.

const std = @import("std");
const Io = std.Io;
const lookout = @import("../lookout.zig");

/// A timeout of `n` milliseconds on the monotonic clock.
pub fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

/// Every backend this target was built with. A suite that runs whole
/// against each of them makes the package's central claim checkable: a
/// program written against `lookout.Watcher` sees the same events whichever
/// mechanism is underneath.
pub const backends: []const lookout.Backend = all: {
    const values = std.enums.values(lookout.Backend);
    var list: [values.len]lookout.Backend = undefined;
    var len: usize = 0;
    for (values) |backend| {
        if (backend == .auto or !lookout.supported(backend)) continue;
        list[len] = backend;
        len += 1;
    }
    const final = list[0..len].*;
    break :all &final;
};
