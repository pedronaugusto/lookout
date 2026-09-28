//! A running account of what a backend did, for diagnosing an event that
//! did not arrive.
//!
//! Off unless `LOOKOUT_TRACE` is set in the environment, and compiled out
//! entirely where the environment cannot be read without an allocator:
//! where libc is not linked, except on Windows, whose environment block
//! the process holds as one piece of memory that can be read in place.
//! Every Apple target links libc. The Apple and Windows backends are the
//! ones whose kernels speak in records that need a trace to follow.
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
    else if (builtin.os.tag == .windows)
        windowsHas("LOOKOUT_TRACE")
    else
        false;
    resolved.store(if (asked) on else off, .monotonic);
    return asked;
}

/// Whether the process environment names `name`, read from the block
/// the process parameters point at: `NAME=value` strings in WTF-16, each
/// ended by a zero and the whole ended by an empty one. Names are
/// compared without case, as Windows compares them.
fn windowsHas(comptime name: []const u8) bool {
    var entry: [*:0]const u16 = std.os.windows.peb().ProcessParameters.Environment;
    while (entry[0] != 0) {
        const len = std.mem.len(entry);
        const text = entry[0..len];
        if (text.len > name.len and text[name.len] == '=') {
            var same = true;
            for (name, text[0..name.len]) |want, unit| {
                if (unit > 0x7f or std.ascii.toUpper(@intCast(unit)) != want) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        entry = entry + len + 1;
    }
    return false;
}

/// One traced line. A no-op, and not even a formatting call, when tracing
/// is off.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!enabled()) return;
    std.debug.print("lookout: " ++ fmt ++ "\n", args);
}
