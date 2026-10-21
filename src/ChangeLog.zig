//! What a watcher has handed out, kept in memory so that it can say what
//! changed since a moment of its own: `Watcher.clock` names the moment,
//! `Watcher.since` answers for it, and `Watcher.sync` makes the answer
//! reach a change made just before the question. It is the question git
//! asks a file monitor (its hook, its daemon) and relic's `ChangeSource`
//! asks a program.
//!
//! Every watch keeps each path that changed, once, with the tick of the
//! `poll` that handed it out last. A watch answers only for what it has
//! seen whole: a clock from before the watch was added, before it lost
//! changes (`overflow`, an allocation failure), before its filter changed,
//! or before the history forgot its paths for want of room, is answered
//! with null, which says look at everything. A watch that stopped (its
//! root removed or moved) or that has a hole in it (`unwatched`) answers
//! null from then on.
//!
//! The watcher's thread writes it as `poll` hands out; any thread reads
//! it, under a blocking lock. Nothing here survives the watcher: a clock
//! names the watcher it came from, and another watcher's, or one from an
//! earlier run, is answered with null.

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const types = @import("types.zig");
const Event = types.Event;
const Target = types.Target;
const WatchId = types.WatchId;

const ChangeLog = @This();

gpa: Allocator,
/// Names this watcher's clocks, so that one from another is not misread.
epoch: u64,
/// The most paths kept across every watch; past it the history forgets
/// them all.
limit: usize,
state: aegis.BlockingGuarded(State),
/// Signaled whenever `poll` hands out one of `sync`'s files.
seen: aegis.Condition,

/// A moment in one watcher's history, as `Watcher.clock` gives it: what
/// that watcher had handed out by then.
pub const Clock = struct {
    /// The watcher's own, chosen at random when it was made.
    epoch: u64,
    /// How far the history had gone: one step for each `poll` that
    /// handed out a change, and for each watch added or refiltered.
    tick: u64,

    /// The longest text `format` writes.
    pub const max_text = "lookout:".len + 16 + 1 + 20;

    /// `lookout:<epoch, 16 hexadecimal digits>:<tick>`: a token for a
    /// program to keep, as git keeps a monitor's token in the index.
    pub fn format(c: Clock, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("lookout:{x:0>16}:{d}", .{ c.epoch, c.tick });
    }

    /// The clock `format` wrote, or null for any other text: a token from
    /// some other monitor is not an error, only not this one's.
    pub fn parse(text: []const u8) ?Clock {
        const rest = if (std.mem.startsWith(u8, text, "lookout:")) text["lookout:".len..] else return null;
        if (rest.len < 18 or rest[16] != ':') return null;
        const epoch_text = rest[0..16];
        const tick_text = rest[17..];
        for (epoch_text) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return null;
        if (tick_text.len == 0 or tick_text.len > 20) return null;
        for (tick_text) |c| if (!std.ascii.isDigit(c)) return null;
        if (tick_text.len > 1 and tick_text[0] == '0') return null;
        return .{
            .epoch = std.fmt.parseInt(u64, epoch_text, 16) catch return null,
            .tick = std.fmt.parseInt(u64, tick_text, 10) catch return null,
        };
    }
};

/// One path that changed.
pub const Change = struct {
    /// Absolute and canonical, spelled as `Event.path` is.
    path: []const u8,
    /// What the path was when it last changed, as `Event.target` said.
    target: Target,
};

/// `Watcher.since`'s answer.
pub const Changes = struct {
    /// The moment this answer reaches: the clock to ask with next time.
    clock: Clock,
    /// Every path of the watch that changed after the clock asked with,
    /// once each, in no order. A rename names both its paths.
    paths: []const Change,
};

const State = struct {
    tick: u64 = 0,
    /// Paths kept across every watch.
    count: usize = 0,
    watches: std.array_hash_map.Auto(WatchId, Watch) = .empty,
    /// The files `sync` is waiting for, by path (owned here), and how many
    /// times `poll` has handed one out.
    cookies: std.array_hash_map.String(u8) = .empty,
    next_cookie: u64 = 0,
};

const Watch = struct {
    /// The watch's root, owned here.
    root: []u8,
    /// The first tick this watch answers from: a clock before it is null.
    from: u64,
    /// The watch stopped or has a hole: it answers nothing any more.
    holed: bool = false,
    /// Each path that changed, owned here, and the tick it last did.
    paths: std.array_hash_map.String(Entry) = .empty,

    fn forget(w: *Watch, gpa: Allocator, state: *State, from: u64) void {
        for (w.paths.keys()) |p| gpa.free(p);
        state.count -= w.paths.count();
        w.paths.clearRetainingCapacity();
        w.from = from;
    }

    fn deinit(w: *Watch, gpa: Allocator, state: *State) void {
        w.forget(gpa, state, 0);
        w.paths.deinit(gpa);
        gpa.free(w.root);
    }
};

const Entry = struct { tick: u64, target: Target };

pub fn create(gpa: Allocator, io: Io, limit: usize) Allocator.Error!*ChangeLog {
    const h = try gpa.create(ChangeLog);
    var raw: [8]u8 = undefined;
    io.random(&raw);
    h.* = .{
        .gpa = gpa,
        .epoch = std.mem.readInt(u64, &raw, .little),
        .limit = limit,
        .state = .init(.{}),
        .seen = .init(),
    };
    return h;
}

/// Only once nothing else can reach the history.
pub fn destroy(h: *ChangeLog) void {
    const state = h.state.teardown();
    for (state.watches.values()) |*w| w.deinit(h.gpa, state);
    state.watches.deinit(h.gpa);
    for (state.cookies.keys()) |p| h.gpa.free(p);
    state.cookies.deinit(h.gpa);
    h.gpa.destroy(h);
}

/// `Watcher.add` took the watch `id` on `root`: it answers from the next
/// tick, which a clock taken before the watch never is.
pub fn added(h: *ChangeLog, io: Io, id: WatchId, root: []const u8) Allocator.Error!void {
    const owned = try h.gpa.dupe(u8, root);
    errdefer h.gpa.free(owned);
    var guard = h.state.acquireUncancelable(io);
    defer guard.deinit(io);
    const state = guard.value();
    try state.watches.ensureUnusedCapacity(h.gpa, 1);
    state.tick += 1;
    state.watches.putAssumeCapacity(id, .{ .root = owned, .from = state.tick });
}

/// `Watcher.remove` let `id` go.
pub fn removed(h: *ChangeLog, io: Io, id: WatchId) void {
    var guard = h.state.acquireUncancelable(io);
    defer guard.deinit(io);
    const state = guard.value();
    var entry = state.watches.fetchSwapRemove(id) orelse return;
    entry.value.deinit(h.gpa, state);
}

/// `id`'s filter changed: what it now admits had no changes kept, so no
/// clock taken before answers.
pub fn refiltered(h: *ChangeLog, io: Io, id: WatchId) void {
    var guard = h.state.acquireUncancelable(io);
    defer guard.deinit(io);
    const state = guard.value();
    const w = state.watches.getPtr(id) orelse return;
    state.tick += 1;
    w.forget(h.gpa, state, state.tick);
}

/// The name of every file `sync` writes, before its number.
fn cookiePrefix(h: *const ChangeLog, buffer: *[32]u8) []const u8 {
    return std.mem.print(buffer, ".lookout-sync-{x:0>16}-", .{h.epoch}) catch unreachable; // unreachable: 30 bytes fit in 32
}

/// Whether `event` is about one of `sync`'s files, whatever became of its
/// wait: never handed out.
pub fn discards(h: *const ChangeLog, event: Event) bool {
    var buffer: [32]u8 = undefined;
    const prefix = h.cookiePrefix(&buffer);
    return std.mem.startsWith(u8, std.fs.path.basename(event.path), prefix);
}

/// What `poll` is about to hand out, `events`: each path is kept with the
/// tick it is handed out at, and each of `sync`'s files is counted and not
/// kept (the batch takes them out next: `discards`). Never fails: what
/// cannot be kept is forgotten, which makes the watch answer null for any
/// earlier clock.
pub fn record(h: *ChangeLog, io: Io, events: []const Event) void {
    var guard = h.state.acquireUncancelable(io);
    defer guard.deinit(io);
    const state = guard.value();
    var signal = false;
    var changed = false;
    for (events) |event| {
        if (!h.discards(event)) {
            changed = true;
            continue;
        }
        if (state.cookies.getPtr(event.path)) |sightings| {
            sightings.* +|= 1;
            signal = true;
        }
    }
    if (signal) h.seen.broadcast(io);
    if (!changed) return;
    state.tick += 1;
    const tick = state.tick;
    for (events) |event| {
        if (h.discards(event)) continue;
        const w = state.watches.getPtr(event.id) orelse continue;
        if (w.holed) continue;
        switch (event.kind) {
            .overflow => {
                w.forget(h.gpa, state, tick);
                continue;
            },
            .unwatched => {
                w.forget(h.gpa, state, tick);
                w.holed = true;
                continue;
            },
            else => {},
        }
        h.keep(state, w, event.path, event.target, tick);
        if (event.from) |from| h.keep(state, w, from, event.target, tick);
        // A watch on a path is about that path: once it is gone or moved
        // the watch reports nothing more, and so answers for nothing.
        if ((event.kind == .removed or event.kind == .renamed) and std.mem.eql(u8, event.path, w.root)) {
            w.forget(h.gpa, state, tick);
            w.holed = true;
        }
    }
    if (state.count > h.limit) {
        for (state.watches.values()) |*w| w.forget(h.gpa, state, tick);
    }
}

fn keep(h: *ChangeLog, state: *State, w: *Watch, path: []const u8, target: Target, tick: u64) void {
    if (w.paths.getPtr(path)) |entry| {
        entry.* = .{ .tick = tick, .target = target };
        return;
    }
    const owned = h.gpa.dupe(u8, path) catch return w.forget(h.gpa, state, tick);
    w.paths.put(h.gpa, owned, .{ .tick = tick, .target = target }) catch {
        h.gpa.free(owned);
        return w.forget(h.gpa, state, tick);
    };
    state.count += 1;
}

pub fn clock(h: *ChangeLog, io: Io) Clock {
    var guard = h.state.acquireUncancelable(io);
    defer guard.deinit(io);
    return .{ .epoch = h.epoch, .tick = guard.value().tick };
}

/// What `id` saw change after `since`, in `arena`, or null where it cannot
/// say: see the file's top.
pub fn changes(h: *ChangeLog, io: Io, arena: Allocator, id: WatchId, since: Clock) Allocator.Error!?Changes {
    var guard = h.state.acquireUncancelable(io);
    defer guard.deinit(io);
    const state = guard.value();
    if (since.epoch != h.epoch or since.tick > state.tick) return null;
    const w = state.watches.getPtr(id) orelse return null;
    if (w.holed or since.tick < w.from) return null;
    var paths: std.ArrayList(Change) = .empty;
    for (w.paths.keys(), w.paths.values()) |p, entry| {
        if (entry.tick <= since.tick) continue;
        try paths.append(arena, .{ .path = try arena.dupe(u8, p), .target = entry.target });
    }
    return .{ .clock = .{ .epoch = h.epoch, .tick = state.tick }, .paths = paths.items };
}

pub const SyncError = error{
    /// `poll` did not hand out the file in time: nothing polls, the
    /// directory is not one the watch reports, or the timeout was short.
    SyncTimeout,
    /// `dir` is not absolute.
    RelativePath,
    /// Another wait was already as many as one history takes.
    WaiterLimit,
} || Io.Cancelable || Allocator.Error || Io.File.OpenError || Io.Dir.DeleteFileError;

/// Writes a file of the history's own in `dir`, and waits until `poll` has
/// handed it out, and then its removal: by then `poll` has handed out every
/// change the watch reported before it, on the backends whose kernel
/// reports in order, and, on a polling registration, a whole scan begun
/// after the file was seen. Called from any thread but the one that polls,
/// which must be polling meanwhile. The file is never handed out.
pub fn sync(h: *ChangeLog, io: Io, dir: []const u8, timeout: Io.Timeout) SyncError!void {
    if (!std.fs.path.isAbsolute(dir)) return error.RelativePath;
    const deadline = timeout.toDeadline(io);
    var buffer: [32]u8 = undefined;
    const prefix = h.cookiePrefix(&buffer);
    const path = path: {
        var guard = try h.state.acquire(io);
        defer guard.deinit(io);
        const state = guard.value();
        const number = state.next_cookie;
        state.next_cookie += 1;
        var name_buffer: [64]u8 = undefined;
        const name = std.mem.print(&name_buffer, "{s}{d}", .{ prefix, number }) catch unreachable; // unreachable: 30 + 20 bytes fit in 64
        const owned = try std.fs.path.join(h.gpa, &.{ dir, name });
        errdefer h.gpa.free(owned);
        try state.cookies.put(h.gpa, owned, 0);
        break :path owned;
    };
    defer {
        var guard = h.state.acquireUncancelable(io);
        _ = guard.value().cookies.swapRemove(path);
        guard.deinit(io);
        h.gpa.free(path);
    }
    const file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    file.close(io);
    var present = true;
    defer if (present) Io.Dir.cwd().deleteFile(io, path) catch {}; // glint-ignore: Z026 -- a file left by a failed wait is never handed out, and the next sync writes another
    try h.waitFor(io, path, 1, deadline);
    try Io.Dir.cwd().deleteFile(io, path);
    present = false;
    try h.waitFor(io, path, 2, deadline);
}

fn waitFor(h: *ChangeLog, io: Io, path: []const u8, sightings: u8, deadline: Io.Timeout) SyncError!void {
    var guard = try h.state.acquire(io);
    defer guard.deinit(io);
    while (guard.value().cookies.get(path).? < sightings) {
        h.seen.wait(io, &guard, deadline) catch |err| switch (err) {
            error.Timeout => return error.SyncTimeout,
            else => |e| return e,
        };
    }
}

test "a clock is written and read back, and no other text is one" {
    const testing = std.testing;
    var buffer: [Clock.max_text]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const c: Clock = .{ .epoch = 0x00ab_cdef_0123_4567, .tick = std.math.maxInt(u64) };
    try w.print("{f}", .{c});
    try testing.expectEqualStrings("lookout:00abcdef01234567:18446744073709551615", w.buffered());
    try testing.expectEqual(c, Clock.parse(w.buffered()).?);
    for ([_][]const u8{
        "",                            "builtin:fake",
        "lookout:00abcdef01234567",    "lookout:00abcdef01234567:",
        "lookout:00ABCDEF01234567:1",  "lookout:00abcdef0123456:1",
        "lookout:00abcdef01234567:01", "lookout:00abcdef01234567:18446744073709551616",
        "lookout:00abcdef01234567:1 ", "lookout:00abcdef01234567:-1",
    }) |text| try testing.expect(Clock.parse(text) == null);
}

test "a watch answers for what it saw whole, and null for the rest" {
    const testing = std.testing;
    const io = testing.io;
    const gpa = testing.allocator;
    const h = try ChangeLog.create(gpa, io, 4);
    defer h.destroy();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a: WatchId = .fromRaw(1);
    const b: WatchId = .fromRaw(2);
    try h.added(io, a, "/w");
    const start = h.clock(io);
    h.record(io, &.{
        .{ .id = a, .path = "/w/one", .kind = .created, .target = .file },
        .{ .id = a, .path = "/w/new", .from = "/w/old", .kind = .renamed, .target = .file },
    });
    const first = h.clock(io);
    h.record(io, &.{.{ .id = a, .path = "/w/one", .kind = .modified, .target = .file }});
    try h.added(io, b, "/v");

    const all = (try h.changes(io, arena, a, start)).?;
    try testing.expectEqual(h.clock(io), all.clock);
    try testing.expectEqual(3, all.paths.len);
    const later = (try h.changes(io, arena, a, first)).?;
    try testing.expectEqual(1, later.paths.len);
    try testing.expectEqualStrings("/w/one", later.paths[0].path);
    try testing.expectEqual(0, (try h.changes(io, arena, a, h.clock(io))).?.paths.len);

    // Before b was added; another watcher's clock; one from the future.
    try testing.expect(try h.changes(io, arena, b, start) == null);
    try testing.expect(try h.changes(io, arena, a, .{ .epoch = h.epoch +% 1, .tick = 0 }) == null);
    try testing.expect(try h.changes(io, arena, a, .{ .epoch = h.epoch, .tick = 99 }) == null);

    // An overflow forgets what came before it, but not what follows.
    h.record(io, &.{.{ .id = a, .path = "/w", .kind = .overflow, .target = .directory }});
    const lost = h.clock(io);
    try testing.expect(try h.changes(io, arena, a, first) == null);
    try testing.expectEqual(0, (try h.changes(io, arena, a, lost)).?.paths.len);

    // Past the limit everything is forgotten.
    h.record(io, &.{
        .{ .id = b, .path = "/v/1", .kind = .created, .target = .file },
        .{ .id = b, .path = "/v/2", .kind = .created, .target = .file },
        .{ .id = b, .path = "/v/3", .kind = .created, .target = .file },
        .{ .id = a, .path = "/w/4", .kind = .created, .target = .file },
        .{ .id = a, .path = "/w/5", .kind = .created, .target = .file },
    });
    try testing.expect(try h.changes(io, arena, a, lost) == null);
    try testing.expectEqual(0, (try h.changes(io, arena, b, h.clock(io))).?.paths.len);

    // A changed filter forgets; a hole or a removed root answers no more.
    const now = h.clock(io);
    h.refiltered(io, a);
    try testing.expect(try h.changes(io, arena, a, now) == null);
    const refiltered_at = h.clock(io);
    h.record(io, &.{.{ .id = a, .path = "/w/6", .kind = .created, .target = .file }});
    try testing.expectEqual(1, (try h.changes(io, arena, a, refiltered_at)).?.paths.len);
    h.record(io, &.{.{ .id = a, .path = "/w/sub", .kind = .unwatched, .target = .directory }});
    h.record(io, &.{.{ .id = b, .path = "/v", .kind = .removed, .target = .directory }});
    try testing.expect(try h.changes(io, arena, a, h.clock(io)) == null);
    try testing.expect(try h.changes(io, arena, b, h.clock(io)) == null);

    h.removed(io, a);
    try testing.expect(try h.changes(io, arena, a, h.clock(io)) == null);
}
