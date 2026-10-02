//! A frozen clock for tests of time arithmetic. Other I/O still reaches
//! the original implementation with its original userdata.

const std = @import("std");
const Io = std.Io;

/// The caller owns vtable for the lifetime of the returned Io.
pub fn frozen(vtable: *Io.VTable, source: Io) Io {
    vtable.* = source.vtable.*;
    vtable.now = now;
    return .{ .userdata = source.userdata, .vtable = vtable };
}

fn now(_: ?*anyopaque, _: Io.Clock) Io.Timestamp {
    return .{ .nanoseconds = 1_000 * std.time.ns_per_ms };
}
