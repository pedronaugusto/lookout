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
//! Lines go to `std.log` under the `lookout` scope at the info level, one
//! per decision, so the program's log function decides where they land
//! and a run can be grepped for one path. A build whose log level is
//! below info -- ReleaseFast and ReleaseSmall by default, and a test run
//! -- drops them unless the program raises it. Nothing here is on a path
//! a caller takes when the variable is unset: the check is one relaxed
//! load.

const std = @import("std");
const builtin = @import("builtin");

const scoped = std.log.scoped(.lookout);

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
    return blockHas(name, std.os.windows.peb().ProcessParameters.Environment);
}

/// Whether the environment block `block`, laid out as `windowsHas` says,
/// names `name`. `name` is upper case.
fn blockHas(comptime name: []const u8, block: [*:0]const u16) bool {
    var entry: [*:0]const u16 = block;
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
    scoped.info(fmt, args);
}

test "an environment block names a variable in any case, by its whole name, and only before its value" {
    const block = std.unicode.utf8ToUtf16LeStringLiteral("Path=C:\\x\x00LOOKOUT_TRACEX=1\x00lookout_trace=\x00OTHER=LOOKOUT_TRACE=1\x00\x00");
    try std.testing.expect(blockHas("LOOKOUT_TRACE", block));
    try std.testing.expect(blockHas("PATH", block));
    // a longer name that starts the same way, and the name inside a value
    const without = std.unicode.utf8ToUtf16LeStringLiteral("LOOKOUT_TRACEX=1\x00OTHER=LOOKOUT_TRACE=1\x00\x00");
    try std.testing.expect(!blockHas("LOOKOUT_TRACE", without));
    // a unit past ASCII never matches a letter of the name
    const wide = [_:0]u16{ 0x00cc, '=', '1', 0, 0 };
    try std.testing.expect(!blockHas("I", &wide));
    // an empty block
    const empty = [_:0]u16{0};
    try std.testing.expect(!blockHas("LOOKOUT_TRACE", &empty));
}

test "tracing is read once and remembered" {
    const was = resolved.load(.monotonic);
    defer resolved.store(was, .monotonic);
    resolved.store(on, .monotonic);
    try std.testing.expect(enabled());
    resolved.store(off, .monotonic);
    try std.testing.expect(!enabled());
    log("never printed {d}", .{1});
}
