//! A running account of what a backend did, for diagnosing an event that
//! did not arrive: one line per decision.
//!
//! A library reads no environment, so the program asks for the lines: it
//! names the `lookout` scope in its `std_options.log_scope_levels` at the
//! debug level, and they go to `std.log` under that scope, where the
//! program's log function decides where they land:
//!
//!     pub const std_options: std.Options = .{
//!         .log_scope_levels = &.{.{ .scope = .lookout, .level = .debug }},
//!     };
//!
//! A program that does not name the scope so compiles every line out,
//! whatever its log level: a Debug build is not handed a line per event
//! it never asked for. The Apple and Windows backends are the ones whose
//! kernels speak in records that need a trace to follow.

const std = @import("std");

/// Whether the program asked for the lines; known when it compiles.
pub fn enabled() bool {
    return comptime asked(std.options.log_scope_levels);
}

/// Whether `levels` names the `lookout` scope at the debug level.
fn asked(comptime levels: []const std.log.ScopeLevel) bool {
    for (levels) |entry| {
        if (entry.scope == .lookout) return entry.level == .debug;
    }
    return false;
}

/// One traced line; compiled out when the program did not ask for them.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (comptime !enabled()) return;
    std.log.scoped(.lookout).debug(fmt, args);
}

test "the lines are the program's to ask for: the lookout scope named at the debug level, and nothing else" {
    comptime {
        std.debug.assert(!asked(&.{}));
        std.debug.assert(asked(&.{.{ .scope = .lookout, .level = .debug }}));
        std.debug.assert(!asked(&.{.{ .scope = .lookout, .level = .info }}));
        std.debug.assert(!asked(&.{.{ .scope = .other, .level = .debug }}));
        std.debug.assert(asked(&.{ .{ .scope = .other, .level = .err }, .{ .scope = .lookout, .level = .debug } }));
    }
    // The tests name no scope: every line is compiled out, the environment never read.
    try std.testing.expect(!enabled());
    log("never printed {d}", .{1});
}
