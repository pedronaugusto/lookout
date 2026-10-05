//! A frozen clock for tests of time arithmetic. Other I/O still reaches
//! the original implementation with its original userdata.

const std = @import("std");
const Io = std.Io;

/// `source` with its clock frozen. The caller owns `vtable` for the lifetime
/// of the returned Io.
pub fn frozen(source: Io, vtable: *Io.VTable) Io {
    vtable.* = source.vtable.*;
    vtable.now = now;
    return .{ .userdata = source.userdata, .vtable = vtable };
}

fn now(_: ?*anyopaque, _: Io.Clock) Io.Timestamp {
    return .{ .nanoseconds = 1_000 * std.time.ns_per_ms };
}
