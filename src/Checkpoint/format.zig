//! The private, versioned checkpoint wire format.

const lookout = @import("../types.zig");

/// The serialized format is versioned independently of the package.
pub const State = struct {
    version: u8,
    backend: lookout.Backend,
    watches: []const Watch,
};

/// Internal watch state. Requested roots are canonical watch identities.
/// Recreate the same scopes and filters.
pub const Watch = struct {
    root: []const u8,
    cursor: u64,
    identity: Identity,
    recursive: bool,
    /// The path baseline at this cursor, persisted with the checkpoint.
    baseline: Paths,
    changes: []const Change = &.{},
    half: ?Half = null,
};

/// Stable volume identity and the identity of its current FSEvents log.
pub const Identity = struct {
    volume: [32]u8,
    log: [32]u8,
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
    var state = std.json.parseFromSlice(State, gpa, text, .{ .allocate = .alloc_always }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCheckpoint,
    };
    errdefer state.deinit();
    if (state.value.version != 2 or state.value.backend != .fsevents) return error.InvalidCheckpoint;
    var halves: usize = 0;
    for (state.value.watches, 0..) |watch, index| {
        if (!std.fs.path.isAbsolute(watch.root)) return error.InvalidCheckpoint;
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
            if (!path_cmp.within(watch.root, known) or std.mem.indexOfScalar(u8, known, 0) != null) return error.InvalidCheckpoint;
            var components = std.mem.tokenizeAny(u8, known, path_cmp.separators);
            while (components.next()) |component| {
                if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidCheckpoint;
            }
            const entry = try names.getOrPut(gpa, known);
            if (entry.found_existing) return error.InvalidCheckpoint;
        }
        for (watch.changes) |change| {
            if (!std.fs.path.isAbsolute(change.path)) return error.InvalidCheckpoint;
            if ((change.kind == .renamed) != (change.from != null)) return error.InvalidCheckpoint;
            if (change.from) |from| if (!std.fs.path.isAbsolute(from)) return error.InvalidCheckpoint;
        }
        if (watch.half) |half| {
            halves += 1;
            if (halves > 1 or !std.fs.path.isAbsolute(half.path) or half.flags & 0x800 == 0) return error.InvalidCheckpoint;
        }
    }
    return .{ .value = state.value, .arena = state.arena };
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
    return .{ .arena = arena, .value = .{ .version = state.version, .backend = state.backend, .watches = watches } };
}
