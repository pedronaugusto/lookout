//! An owned resume snapshot. Each watch keeps its volume and log identity,
//! its own log cursor and the changes already read from that log but not handed out by poll.

const std = @import("std");
const Checkpoint = @This();
const Allocator = std.mem.Allocator;
const format = @import("Checkpoint/format.zig");
const builtin = @import("builtin");

state: format.Owned,

/// Releases the snapshot and its retained path revision. It may outlive the
/// watcher, whose allocator must remain valid until all revisions are released.
pub fn deinit(p: *Checkpoint) void {
    p.state.deinit();
    p.* = undefined;
}

/// Writes an owned text token. The caller frees it with gpa.
pub fn token(p: Checkpoint, gpa: Allocator) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, p.state.value, .{});
}

pub const ParseError = error{ OutOfMemory, InvalidCheckpoint };

/// Reads an owned snapshot. The input is borrowed only during this call.
/// Tokens without the current baseline format, volume and log identity are refused. Call deinit when
/// the snapshot is no longer needed.
pub fn parse(gpa: Allocator, text: []const u8) Checkpoint.ParseError!Checkpoint {
    return .{ .state = try format.parse(gpa, text) };
}

test "checkpoint tokens own their paths and refuse unknown formats" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const root = if (builtin.target.os.tag == .windows) "C:\\watch" else "/watch";
    var original: Checkpoint = .{ .state = try format.copy(gpa, .{ .version = 2, .backend = .fsevents, .watches = &.{.{
        .root = root,
        .baseline = .{ .flat = &.{root} },
        .recursive = true,
        .cursor = 1234,
        .identity = .{ .volume = @splat('1'), .log = @splat('2') },
        .changes = &.{.{ .path = root, .kind = .modified, .target = .file }},
    }} }) };
    const text = try original.token(gpa);
    original.deinit();
    var parsed = try parse(gpa, text);
    gpa.free(text);
    defer parsed.deinit();
    try testing.expectEqual(@as(u64, 1234), parsed.state.value.watches[0].cursor);
    try testing.expectEqualStrings(root, parsed.state.value.watches[0].changes[0].path);
    for ([_][]const u8{ "", "1.fsevents.1234", "{}", "{\"version\":1,\"backend\":\"fsevents\",\"watches\":[]}", "{\"version\":1,\"backend\":\"poll\",\"watches\":[]}" }) |bad| {
        try testing.expectError(error.InvalidCheckpoint, parse(gpa, bad));
    }
}

// A host cursor alone cannot identify the volume or its current log.
test "checkpoint tokens require volume and log identity" {
    const root = if (builtin.target.os.tag == .windows) "C:\\watch" else "/watch";
    const text = try std.testing.allocator.print("{{\"version\":2,\"backend\":\"fsevents\",\"watches\":[{{\"root\":{f},\"baseline\":[],\"recursive\":true,\"cursor\":1234}}]}}", .{std.json.fmt(root, .{})});
    defer std.testing.allocator.free(text);
    if (parse(std.testing.allocator, text)) |value| {
        var accepted = value;
        accepted.deinit();
        return error.IdentityMissing;
    } else |err| try std.testing.expectEqual(error.InvalidCheckpoint, err);
}

test "checkpoint paths cannot omit their baseline or escape the root" {
    const gpa = std.testing.allocator;
    const root = if (builtin.target.os.tag == .windows) "C:\\watch" else "/watch";
    const escaped = try std.Io.Dir.path.join(gpa, &.{ root, "..", "outside" });
    defer gpa.free(escaped);
    const identity: format.Identity = .{ .volume = @splat('1'), .log = @splat('2') };
    const text = try std.json.Stringify.valueAlloc(gpa, format.State{ .version = 2, .backend = .fsevents, .watches = &.{.{ .root = root, .cursor = 1, .identity = identity, .recursive = true, .baseline = .{ .flat = &.{escaped} } }} }, .{});
    defer gpa.free(text);
    try std.testing.expectError(error.InvalidCheckpoint, parse(gpa, text));
    const missing = try std.json.Stringify.valueAlloc(gpa, .{ .version = 2, .backend = "fsevents", .watches = &.{.{ .root = root, .cursor = 1, .identity = identity, .recursive = true }} }, .{});
    defer gpa.free(missing);
    try std.testing.expectError(error.InvalidCheckpoint, parse(gpa, missing));
}

test "a checkpoint token naming one root twice is refused" {
    const gpa = std.testing.allocator;
    const root = if (builtin.target.os.tag == .windows) "C:\\watch" else "/watch";
    const identity: format.Identity = .{ .volume = @splat('1'), .log = @splat('2') };
    const watch: format.Watch = .{ .root = root, .cursor = 1, .identity = identity, .recursive = true, .baseline = .{ .flat = &.{root} } };
    const once = try std.json.Stringify.valueAlloc(gpa, format.State{ .version = 2, .backend = .fsevents, .watches = &.{watch} }, .{});
    defer gpa.free(once);
    var parsed = try parse(gpa, once);
    parsed.deinit();
    const twice = try std.json.Stringify.valueAlloc(gpa, format.State{ .version = 2, .backend = .fsevents, .watches = &.{ watch, watch } }, .{});
    defer gpa.free(twice);
    try std.testing.expectError(error.InvalidCheckpoint, parse(gpa, twice));
}
