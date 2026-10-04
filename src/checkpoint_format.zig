//! The private, versioned checkpoint wire format.

const lookout = @import("types.zig");

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
    baseline: []const []const u8 = &.{},
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
pub const ParseError = Allocator.Error || error{InvalidCheckpoint};

pub fn parse(gpa: Allocator, text: []const u8) ParseError!std.json.Parsed(State) {
    var state = std.json.parseFromSlice(State, gpa, text, .{ .allocate = .alloc_always }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCheckpoint,
    };
    errdefer state.deinit();
    if (state.value.version != 2 or state.value.backend != .fsevents) return error.InvalidCheckpoint;
    var halves: usize = 0;
    for (state.value.watches) |watch| {
        if (!std.fs.path.isAbsolute(watch.root)) return error.InvalidCheckpoint;
        for (watch.baseline) |known| {
            if (!@import("path.zig").within(watch.root, known) or std.mem.indexOfScalar(u8, known, 0) != null) return error.InvalidCheckpoint;
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
    return state;
}

/// Copies borrowed internal state into an owned snapshot.
pub fn copy(gpa: Allocator, state: State) Allocator.Error!std.json.Parsed(State) {
    const text = try std.json.Stringify.valueAlloc(gpa, state, .{});
    defer gpa.free(text);
    return parse(gpa, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCheckpoint => unreachable,
    };
}
