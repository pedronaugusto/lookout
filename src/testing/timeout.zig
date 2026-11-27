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

/// The name of every control sentinel: an event naming one is the wait's.
const sentinel_prefix = "lookout-pace-";

/// How many control rounds, each with the watched watcher quiet at its end,
/// end a wait on a backend whose watchers share one order (`Pace`).
const quiet_rounds = 2;

/// A wait for what a watcher reports, paced by deliveries, never by the
/// clock. What says the watched watcher is past everything the test caused
/// before the wait began depends on what order its backend promises:
///
/// * `inotify`, `kqueue` and Windows notify during the call that made the
///   change: the kernel queues the event before that call returns, for
///   every watcher at once. A control watcher of the same backend, on a
///   directory of its own, is given a sentinel, and the next once the last
///   is reported; the wait ends after `quiet_rounds` sentinels in a row
///   each found the watched watcher quiet through their round. What was
///   queued before the sentinel was written is in the watched watcher's
///   queue by then.
/// * FSEvents promises an order within one stream and none between two,
///   and each watch is a stream of its own, so a control's sentinel alone
///   says nothing of the watched streams. It does say fseventsd has read
///   the change: fseventsd reads the kernel's queue in order and numbers
///   what it reads in that order, so a sentinel written after the change
///   is read after it. The control is the same as above, and each
///   sentinel's delivery is followed by `FSEventStreamFlushSync` on every
///   watched stream, which delivers every event fseventsd holds for it,
///   the change among them. The flush alone is no bound: it returns
///   without an event fseventsd has not read yet.
/// * Polling has no events and promises no order between directories, on
///   a network share none at all; what it has is the scan. A `poll` that
///   returns nothing has scanned the whole watch since the wait began and
///   found nothing new, so the wait ends at the first such `poll` with
///   nothing held.
///
/// The loop calls `poll` here, not on the watcher, so the wait sees what is
/// delivered. No clock gives a wait up. A watcher that delivers nothing at
/// all holds the test, and the run's watchdog names it.
pub const Pace = struct {
    watched: *lookout.Watcher,
    how: How,
    /// Set by the round that ends the wait: one more look at the watched
    /// watcher, then `running` says no.
    last: bool = false,

    const How = union(enum) {
        control: Control,
        /// The bound is the scan inside each `poll`.
        empty_poll,
    };

    const Control = struct {
        watcher: lookout.Watcher,
        tmp: std.testing.TmpDir,
        sent: u32 = 0,
        pending: bool = false,
        quiet: u8 = 0,
        /// The watched watcher reported or held something this round.
        busy: bool = false,
    };

    /// A wait over every watch `watched` holds.
    pub fn start(watched: *lookout.Watcher) !Pace {
        return switch (watched.backend()) {
            .poll => .{ .watched = watched, .how = .empty_poll },
            else => startControl(watched),
        };
    }

    fn startControl(watched: *lookout.Watcher) !Pace {
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
        return .{ .watched = watched, .how = .{ .control = .{ .watcher = control, .tmp = tmp } } };
    }

    pub fn end(p: *Pace) void {
        switch (p.how) {
            .control => |*c| {
                c.watcher.deinit(std.testing.io);
                c.tmp.cleanup();
            },
            .empty_poll => {},
        }
        p.* = undefined;
    }

    /// Whether the watched watcher may still report something caused before
    /// the wait began: true until the backend's bound says it is past it.
    pub fn running(p: *Pace) !bool {
        if (p.last) return false;
        switch (p.how) {
            .control => |*c| try p.controlRound(c),
            .empty_poll => {},
        }
        return true;
    }

    fn controlRound(p: *Pace, c: *Control) !void {
        const io = std.testing.io;
        var buffer: [32]u8 = undefined;
        if (!c.pending) {
            c.sent += 1;
            try c.tmp.dir.writeFile(io, .{ .sub_path = try std.mem.print(&buffer, sentinel_prefix ++ "{d}", .{c.sent}), .data = "" });
            c.pending = true;
        }
        if (p.watched.stats().held != 0) c.busy = true;
        const awaited = try std.mem.print(&buffer, sentinel_prefix ++ "{d}", .{c.sent});
        var delivered = false;
        var lost = false;
        for (try c.watcher.poll(io, ms(0))) |event| switch (event.kind) {
            .overflow, .unwatched => lost = true,
            else => if (std.mem.eql(u8, std.Io.Dir.path.basename(event.path), awaited)) {
                delivered = true;
            },
        };
        if (lost) {
            c.pending = false;
        } else if (delivered) {
            // What fseventsd read before the sentinel reaches the watched
            // streams' queue; the next `poll` reads it.
            flush(p.watched);
            c.pending = false;
            c.quiet = if (c.busy) 0 else c.quiet + 1;
            c.busy = false;
            if (c.quiet == quiet_rounds) p.last = true;
        }
    }

    /// `Watcher.poll` on the watched watcher. Valid until the next call, as
    /// `poll`'s slice is.
    pub fn poll(p: *Pace, io: Io, timeout: Io.Timeout) ![]const lookout.Event {
        const events = try p.watched.poll(io, timeout);
        switch (p.how) {
            .control => |*c| if (events.len != 0) {
                c.busy = true;
            },
            .empty_poll => if (events.len == 0 and p.watched.stats().held == 0) {
                p.last = true;
            },
        }
        return events;
    }
};

/// Every event fseventsd holds for the watcher's streams in its queue, on
/// FSEvents (`Pace`); every other backend has nothing to flush.
fn flush(w: *lookout.Watcher) void {
    if (comptime @hasField(@TypeOf(w.impl), "fsevents")) {
        if (w.impl == .fsevents) w.impl.fsevents.flush();
    }
}

/// Polls until the watcher is past everything caused before (`Pace`),
/// dropping what is reported: the next assertion starts clean.
pub fn drain(w: *lookout.Watcher, io: Io) !void {
    var pace: Pace = try .start(w);
    defer pace.end();
    while (try pace.running()) _ = try pace.poll(io, ms(20));
}

/// What a wait for an event that ended without it fails with: the event was
/// not reported, or the system said it lost track first (`Stats.overflows`),
/// or, on FSEvents, refused a stream, a control watcher's own as well.
pub const Missed = error{ EventNotObserved, EventsDropped, FsEventsRefused };

/// The failure of a wait that ended without its event: the backend's bound
/// (`Pace`) says the watcher is past it, and the event did not come. A
/// watcher that handed out an overflow notice first was told the system lost
/// track, and says so. Never a pass.
pub fn missed(w: *const lookout.Watcher) Missed {
    const overflows = w.stats().overflows;
    if (overflows != 0) {
        std.debug.print("{t}: the system lost track before the wait ended: the watcher handed out {d} overflow notice(s); the event was not reported\n", .{ w.backend(), overflows });
        return error.EventsDropped;
    }
    std.debug.print("{t}: the watcher is past the change by its backend's bound (wait.Pace), and did not report it\n", .{w.backend()});
    return error.EventNotObserved;
}

/// `found`, or the failure of the wait that looked for it (`missed`).
pub fn seen(w: *const lookout.Watcher, found: bool) Missed!void {
    if (!found) return missed(w);
}

/// `seen`, for an event naming the entry `name` of `dir`: a wait that
/// ended without it also says whether a listing of `dir` shows the entry
/// now. Shown, the watcher did not report what the system holds; not
/// shown, the system had not made it visible by the time the backend's
/// bound (`Pace`) said the watcher was past it.
pub fn seenIn(w: *const lookout.Watcher, found: bool, dir: Io.Dir, name: []const u8) Missed!void {
    if (found) return;
    const shown: []const u8 = if (listed(dir, name)) |is| (if (is) "shows" else "does not show") else |_| "could not be read for";
    std.debug.print("{t}: a listing of the directory now {s} {s}, with {d} registration(s)\n", .{ w.backend(), shown, name, w.stats().registrations });
    return missed(w);
}

/// Prints what a look of its own finds in the directory `path`: each entry
/// a listing through a handle opened now names, and what a stat of it by
/// name says. Beside a miss it tells the watcher's side from the system's:
/// an entry the fresh listing names and stats, the watcher did not report;
/// one it does not name, or names and cannot stat, the system was not
/// showing when the watcher looked either.
pub fn describe(w: *const lookout.Watcher, path: []const u8) void {
    const io = std.testing.io;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.print("{t}: {s} could not be opened for a fresh listing: {t}\n", .{ w.backend(), path, err });
        return;
    };
    defer dir.close(io);
    std.debug.print("{t}: a fresh listing of {s}:\n", .{ w.backend(), path });
    var it = dir.iterate();
    var names: usize = 0;
    while (it.next(io) catch |err| {
        std.debug.print("  the listing failed after {d} entries: {t}\n", .{ names, err });
        return;
    }) |entry| {
        names += 1;
        if (dir.statFile(io, entry.name, .{ .follow_symlinks = false })) |stat| {
            std.debug.print("  {s}: {t}\n", .{ entry.name, stat.kind });
        } else |err| {
            std.debug.print("  {s}: listed, and its stat by name fails: {t}\n", .{ entry.name, err });
        }
    }
    std.debug.print("  {d} entries\n", .{names});
}

fn listed(dir: Io.Dir, name: []const u8) !bool {
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
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
