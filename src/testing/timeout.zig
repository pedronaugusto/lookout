//! What the test files share: the timeouts they hand
//! `lookout.Watcher.poll`, how they wait for what it reports, and the
//! backends they run against.
//!
//! A wait is on the clock, never a count of polls: a poll returns as soon as
//! anything is ready, so a count of them is no measure of time.

const std = @import("std");
const Io = std.Io;
const lookout = @import("../lookout.zig");
const timing = @import("../timing.zig");

/// A timeout of `n` milliseconds on the monotonic clock.
pub fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

/// How long a test waits for an event it caused. A passing test never
/// waits it out, so it is as long as a loaded machine's file-system events
/// can take; only a failure pays it.
pub const event_ms = 30_000;

/// How long a test watches for an event that must not come: a window, which
/// every passing test waits out.
pub const quiet_ms = 2_000;

/// A point on the monotonic clock a wait gives up at.
pub const Deadline = struct {
    timeout: Io.Timeout,

    pub fn after(io: Io, millis: u32) Deadline {
        return .{ .timeout = timing.within(millis).toDeadline(io) };
    }

    /// Whether there is time left.
    pub fn running(d: Deadline, io: Io) bool {
        return !timing.expired(io, d.timeout);
    }
};

/// How long the control in `missed` waits for its own sentinel.
pub const control_ms = 10_000;

/// What a wait for an event that ran out fails with: the event was not
/// reported, or the system's FSEvents delivered nothing at all (`control`).
pub const Missed = error{ EventNotObserved, FsEventsBackedUp };

/// The failure of a wait for an event that ran out. On FSEvents it first
/// asks the system's journal itself (`control`): when that delivers nothing
/// either, the red names the machine, not the watcher. Never a pass.
pub fn missed(io: Io, backend: lookout.Backend) Missed {
    if (backend != .fsevents) return error.EventNotObserved;
    switch (control(io)) {
        .delivered => |delivered_ms| std.debug.print("the system's FSEvents delivered a control sentinel in {d} ms; the event was not reported\n", .{delivered_ms}),
        .unavailable => |err| std.debug.print("the system's FSEvents could not be measured ({t}); the event was not reported\n", .{err}),
        .silent => {
            std.debug.print("the system's FSEvents delivered nothing for {d} s (fseventsd backed up): a control watcher's own sentinel write was not reported\n", .{control_ms / 1000});
            return error.FsEventsBackedUp;
        },
    }
    return error.EventNotObserved;
}

/// `found`, or the failure of the wait that looked for it (`missed`).
pub fn seen(io: Io, backend: lookout.Backend, found: bool) Missed!void {
    if (!found) return missed(io, backend);
}

/// What the control measured: its sentinel reported after so many
/// milliseconds, nothing within `control_ms`, or no control to be had.
const Control = union(enum) { delivered: i64, silent, unavailable: anyerror };

/// The system's FSEvents measured: a watcher of its own on a directory of
/// its own writes a sentinel there and waits for its creation.
fn control(io: Io) Control {
    return measure(io) catch |err| .{ .unavailable = err };
}

fn measure(io: Io) !Control {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var watcher: lookout.Watcher = try .init(gpa, io, .{ .backend = .fsevents });
    defer watcher.deinit(io);
    _ = try watcher.add(io, root, .{});
    const start = Io.Clock.awake.now(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "control-sentinel", .data = "" });
    const deadline: Deadline = .after(io, control_ms);
    while (deadline.running(io)) {
        for (try watcher.poll(io, ms(200))) |event| if (std.mem.endsWith(u8, event.path, "control-sentinel")) {
            return .{ .delivered = start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() };
        };
    }
    return .silent;
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
