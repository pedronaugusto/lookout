//! The private, versioned checkpoint wire format.

const name_policy = @import("../identity.zig");
const sweep = @import("sweep");
const lookout = @import("../types.zig");

/// The format a watcher writes and the only one `parse` reads, versioned
/// independently of the package.
pub const version = 3;

/// A checkpoint as a watcher holds it: its baselines may be revisions of
/// the history it shares (`Paths`).
pub const State = StateOf(Watch);
pub const Watch = WatchOf(Paths);

/// A checkpoint as its token spells it: every baseline a list of names.
pub const Wire = struct {
    pub const State = StateOf(Wire.Watch);
    pub const Watch = WatchOf([]const []const u8);
};

/// The serialized format is versioned independently of the package.
fn StateOf(comptime W: type) type {
    return struct {
        version: u8,
        backend: lookout.Backend,
        watches: []const W,
    };
}

/// Internal watch state. Requested roots are canonical watch identities.
/// Recreate the same scopes and filters.
fn WatchOf(comptime Baseline: type) type {
    return struct {
        root: []const u8,
        cursor: u64,
        identity: Identity,
        recursive: bool,
        /// The path baseline at this cursor, persisted with the checkpoint.
        baseline: Baseline,
        changes: []const Change = &.{},
        half: ?Half = null,
        /// `Filter.ignore` and `Filter.only` as the watch had them. A resume
        /// under other patterns would read the baseline and the changes as
        /// though they covered paths they never did, so it is refused.
        ignore: []const []const u8 = &.{},
        only: []const []const u8 = &.{},
        case: ?sweep.Case = null,
        normalization: ?name_policy.Policy.Normalization = null,
        policy: name_policy.Policy = .{},
        identity_override: ?name_policy.Policy = null,
        /// The patterns are the bytes a filter was given: text when they are UTF-8.
        pub const strand = .{ .fields = .{ .ignore = .{ .as = .text_or_bytes }, .only = .{ .as = .text_or_bytes } } };
    };
}

/// The same watch with another baseline.
fn rebased(comptime To: type, from: anytype, baseline: @FieldType(To, "baseline")) To {
    var to: To = undefined;
    inline for (@typeInfo(To).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "baseline")) to.baseline = baseline else @field(to, name) = @field(from, name);
    }
    return to;
}

/// Stable volume identity and the identity of its current FSEvents log.
pub const Identity = struct {
    volume: [32]u8,
    log: [32]u8,
    /// Each a UUID's lowercase hex, written as text.
    pub const strand = .{ .fields = .{ .volume = .{ .as = .text }, .log = .{ .as = .text } } };
};

pub const Change = struct {
    path: []const u8,
    kind: lookout.Kind,
    from: ?[]const u8 = null,
    target: lookout.Target,
};

pub const Half = struct {
    path: []const u8,
    flags: u32,
    event: u64,
};

const std = @import("std");
const strand = @import("strand");
const Allocator = std.mem.Allocator;
const path_cmp = @import("../path.zig");
const Paths = @import("History.zig").Paths;
pub const ParseError = error{ OutOfMemory, InvalidCheckpoint };

pub const Owned = struct {
    value: State,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(state: Owned) void {
        for (state.value.watches) |watch| watch.baseline.release();
        const gpa = state.arena.child_allocator;
        state.arena.deinit();
        gpa.destroy(state.arena);
    }
};

pub fn parse(gpa: Allocator, text: []const u8) ParseError!Owned {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    var state: Owned = .{ .arena = arena, .value = undefined };
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    // The names read borrow from the token's copy in the arena. A token is
    // bounded by its own length: every name in it is spelled there.
    const held = try arena.allocator().dupe(u8, text);
    const wire = strand.json.parseLeaky(Wire.State, arena.allocator(), held, .{ .limits = .sized(text.len) }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCheckpoint,
    };
    const watches = try arena.allocator().alloc(Watch, wire.watches.len);
    for (wire.watches, watches) |from, *to| to.* = rebased(Watch, from, .{ .flat = from.baseline });
    state.value = .{ .version = wire.version, .backend = wire.backend, .watches = watches };
    if (state.value.version != version or state.value.backend != .fsevents) return error.InvalidCheckpoint;
    var halves: usize = 0;
    for (state.value.watches, 0..) |watch, index| {
        if (!sound(watch.root)) return error.InvalidCheckpoint;
        // One watcher watches a root once, so a token naming one twice
        // was not written by a watcher, and a resume could not say which
        // of the two a refused registration used.
        for (state.value.watches[0..index]) |earlier| {
            if (path_cmp.eql(earlier.root, watch.root)) return error.InvalidCheckpoint;
        }
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(gpa);
        var paths = watch.baseline.iterator();
        defer paths.deinit();
        while (paths.next()) |known| {
            if (!path_cmp.within(watch.root, known) or !sound(known)) return error.InvalidCheckpoint;
            const entry = try names.getOrPut(gpa, known);
            if (entry.found_existing) return error.InvalidCheckpoint;
        }
        // A change and a held half are spelled as the baseline is. Which
        // of them the watch still wants -- its root may be parked on an
        // ancestor, and an overflow is reported there -- is the resuming
        // backend's to decide against the registration it makes.
        for (watch.changes) |change| {
            if (!sound(change.path)) return error.InvalidCheckpoint;
            if ((change.kind == .renamed) != (change.from != null)) return error.InvalidCheckpoint;
            if (change.from) |from| if (!sound(from)) return error.InvalidCheckpoint;
        }
        if (watch.half) |half| {
            halves += 1;
            if (halves > 1 or !sound(half.path) or half.flags & 0x800 == 0) return error.InvalidCheckpoint;
        }
    }
    return state;
}

/// Whether a path in a token is one a watcher could have written: absolute,
/// without a NUL, and without `.` or `..` components that would let it
/// name something other than what it spells.
fn sound(subject: []const u8) bool {
    if (!std.Io.Dir.path.isAbsolute(subject) or std.mem.findScalar(u8, subject, 0) != null) return false;
    var components = std.mem.tokenizeAny(u8, subject, path_cmp.separators);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

/// The token of `state`, which the caller frees with `gpa`. A shared
/// baseline's names are listed first, borrowed from the revision it holds.
pub fn write(gpa: Allocator, state: State) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const watches = try a.alloc(Wire.Watch, state.watches.len);
    for (state.watches, watches) |from, *to| {
        var names: std.ArrayList([]const u8) = .empty;
        var it = from.baseline.iterator();
        defer it.deinit();
        while (it.next()) |name| try names.append(a, name);
        to.* = rebased(Wire.Watch, from, names.items);
    }
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    const wire: Wire.State = .{ .version = state.version, .backend = state.backend, .watches = watches };
    strand.json.write(&text.writer, wire, .{ .limits = .sized(std.math.maxInt(usize)) }) catch |err| return switch (err) {
        error.WriteFailed, error.OutOfMemory => error.OutOfMemory,
        // unreachable: a watcher's state is JSON within limits as large as memory: its names are
        // UTF-8, the only names FSEvents gives, and its patterns text or bytes
        else => unreachable,
    };
    return text.toOwnedSlice();
}

/// Copies borrowed internal state into an owned snapshot.
pub fn copy(gpa: Allocator, state: State) Allocator.Error!Owned {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const a = arena.allocator();
    const watches = try a.alloc(Watch, state.watches.len);
    var copied: usize = 0;
    errdefer for (watches[0..copied]) |watch| watch.baseline.release();
    for (state.watches, watches) |watch, *owned| {
        owned.* = watch;
        owned.root = try a.dupe(u8, watch.root);
        const changes = try a.alloc(Change, watch.changes.len);
        for (watch.changes, changes) |change, *out| {
            out.* = change;
            out.path = try a.dupe(u8, change.path);
            if (change.from) |from| out.from = try a.dupe(u8, from);
        }
        owned.changes = changes;
        owned.ignore = try dupeList(a, watch.ignore);
        owned.only = try dupeList(a, watch.only);
        if (watch.half) |half| owned.half = .{ .path = try a.dupe(u8, half.path), .flags = half.flags, .event = half.event };
        owned.baseline = switch (watch.baseline) {
            .flat => |names| blk: {
                const paths = try a.alloc([]const u8, names.len);
                for (names, paths) |name, *out| out.* = try a.dupe(u8, name);
                break :blk .{ .flat = paths };
            },
            .shared => watch.baseline.retain(),
        };
        copied += 1;
    }
    std.debug.assert(copied == state.watches.len);
    return .{ .arena = arena, .value = .{ .version = state.version, .backend = state.backend, .watches = watches } };
}

fn dupeList(a: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const copied = try a.alloc([]const u8, list.len);
    for (list, copied) |pattern, *out| out.* = try a.dupe(u8, pattern);
    return copied;
}
