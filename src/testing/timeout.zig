//! What the test files share: the timeouts they hand
//! `lookout.Watcher.poll`, how they wait for what it reports, and the
//! backends they run against.
//!
//! A wait is paced by the system's own deliveries, never by the clock
//! (`Pace`): a loaded machine delivers late, and a wait on a wall-clock
//! budget turns its lateness into a red.

const std = @import("std");
const Io = std.Io;
const lookout = @import("../lookout.zig");

/// A timeout of `n` milliseconds on the monotonic clock: how long one
/// `poll` blocks, never how long a wait lasts.
pub fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

/// How many control rounds, each with the watched watcher quiet at its end,
/// end a wait.
const quiet_rounds = 2;

/// A wait for what a watcher reports, paced by the system's own deliveries.
/// A control watcher of the same backend and pacing, on a directory of its
/// own, writes a sentinel there, and the next once the last is reported. The
/// wait runs while the watched watcher may still report what it waits for:
/// it ends after `quiet_rounds` sentinels in a row each found the watched
/// watcher quiet through their round (no poll in it reported anything,
/// nothing held at its end, no progress the caller noted with `moved`),
/// all written after the wait began. What the test caused before it began is then past in the
/// system's own order, whatever the load: a late machine is late for the
/// control too. A wait for an event that must not come ends the same way,
/// and so does a drain.
///
/// A sentinel is delivered by any event naming it: with
/// `Options.debounce` a path reports the kind seen last, so its creation
/// may come as the close that followed it. A control that loses track
/// (`Kind.overflow`) reports no event for the sentinel at all; its round
/// is not counted, and the next sentinel is written.
///
/// No clock gives a wait up. A system that delivers nothing at all, the
/// control's sentinels as well, holds the test, and the run's watchdog
/// names it.
pub const Pace = struct {
    watched: *const lookout.Watcher,
    control: lookout.Watcher,
    tmp: std.testing.TmpDir,
    /// Sentinels written so far; the last is the one awaited while `pending`.
    sent: u32 = 0,
    pending: bool = false,
    /// Rounds in a row that found the watched watcher quiet.
    quiet: u8 = 0,
    /// The watched watcher reported, held or (`moved`) progressed during
    /// the current round.
    busy: bool = false,
    /// Set by the round that ends the wait: one more look at the watched
    /// watcher, after the system is past, before `running` says no.
    last: bool = false,

    pub fn start(watched: *const lookout.Watcher) !Pace {
        const io = std.testing.io;
        const gpa = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);
        const options = watched.options;
        var control: lookout.Watcher = try .init(gpa, io, .{
            .backend = watched.backend(),
            .poll_interval = options.poll_interval,
            .latency = options.latency,
            .settle = options.settle,
            .debounce = options.debounce,
        });
        errdefer control.deinit(io);
        _ = try add(&control, io, root, .{});
        return .{ .watched = watched, .control = control, .tmp = tmp };
    }

    pub fn end(p: *Pace) void {
        p.control.deinit(std.testing.io);
        p.tmp.cleanup();
        p.* = undefined;
    }

    /// Whether the watched watcher may still report something caused before
    /// the wait began: true until the control's rounds say the system is past
    /// it, and once more after, for the look that follows.
    pub fn running(p: *Pace) !bool {
        if (p.last) return false;
        const io = std.testing.io;
        var buffer: [32]u8 = undefined;
        if (!p.pending) {
            p.sent += 1;
            try p.tmp.dir.writeFile(io, .{ .sub_path = try sentinel(&buffer, p.sent), .data = "" });
            p.pending = true;
        }
        const stats = p.watched.stats();
        if (stats.events != 0 or stats.held != 0) p.busy = true;
        const awaited = try sentinel(&buffer, p.sent);
        var delivered = false;
        var lost = false;
        for (try p.control.poll(io, ms(0))) |event| switch (event.kind) {
            .overflow, .unwatched => lost = true,
            else => if (std.mem.eql(u8, std.Io.Dir.path.basename(event.path), awaited)) {
                delivered = true;
            },
        };
        if (lost) {
            p.pending = false;
        } else if (delivered) {
            p.pending = false;
            p.quiet = if (p.busy) 0 else p.quiet + 1;
            p.busy = false;
            if (p.quiet == quiet_rounds) p.last = true;
        }
        return true;
    }

    /// Notes progress the watched watcher made that its `stats` do not show,
    /// such as deliveries a test reads before `poll`: the round does not
    /// count as quiet.
    pub fn moved(p: *Pace) void {
        p.busy = true;
    }

    fn sentinel(buffer: []u8, n: u32) ![]const u8 {
        return std.mem.print(buffer, "control-sentinel-{d}", .{n});
    }
};

/// Polls until the system is past everything caused before (`Pace`),
/// dropping what is reported: the next assertion starts clean.
pub fn drain(w: *lookout.Watcher, io: Io) !void {
    var pace: Pace = try .start(w);
    defer pace.end();
    while (try pace.running()) _ = try w.poll(io, ms(20));
}

/// What a wait for an event that ended without it fails with: the event was
/// not reported, or the system said it lost track first (`Stats.overflows`),
/// or, on FSEvents, refused a stream, a control watcher's own as well.
pub const Missed = error{ EventNotObserved, EventsDropped, FsEventsRefused };

/// The failure of a wait that ended without its event: the control's
/// sentinels came, so the system was delivering, and the event did not. A
/// watcher that handed out an overflow notice first was told the system lost
/// track, and says so. Never a pass.
pub fn missed(w: *const lookout.Watcher) Missed {
    const overflows = w.stats().overflows;
    if (overflows != 0) {
        std.debug.print("the system lost track before the wait ended: the watcher handed out {d} overflow notice(s); the event was not reported\n", .{overflows});
        return error.EventsDropped;
    }
    std.debug.print("the control's sentinels were reported after it, and the event was not\n", .{});
    return error.EventNotObserved;
}

/// `found`, or the failure of the wait that looked for it (`missed`).
pub fn seen(w: *const lookout.Watcher, found: bool) Missed!void {
    if (!found) return missed(w);
}

/// `Watcher.add`, whose `WatchLimitReached` on FSEvents asks the system
/// first: fseventsd refusing a control watcher's stream as well is
/// `FsEventsRefused`, the machine's red, not the watcher's.
pub fn add(w: *lookout.Watcher, io: Io, path: []const u8, options: lookout.Watcher.AddOptions) (lookout.Watcher.AddError || Missed)!lookout.WatchId {
    return w.add(io, path, options) catch |err| switch (err) {
        error.WatchLimitReached => if (w.backend() == .fsevents and controlRefused(io)) refused() else err,
        else => err,
    };
}

fn refused() Missed {
    std.debug.print("the system's FSEvents refused a new stream (fseventsd unavailable, restarting or at its client limit): a control watcher's own stream would not start\n", .{});
    return error.FsEventsRefused;
}

/// Whether the system's FSEvents refuses a stream of a control watcher's own,
/// on a directory of its own.
fn controlRefused(io: Io) bool {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir.realPathFileAlloc(io, ".", gpa) catch return false;
    defer gpa.free(root);
    var watcher: lookout.Watcher = lookout.Watcher.init(gpa, io, .{ .backend = .fsevents }) catch return false;
    defer watcher.deinit(io);
    _ = watcher.add(io, root, .{}) catch |err| return err == error.WatchLimitReached;
    return false;
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
