//! An owned resume snapshot. Each watch keeps its own log cursor and the
//! changes already read from that log but not handed out by poll.

const std = @import("std");
const lookout = @import("lookout.zig");
const Checkpoint = @This();
const Allocator = std.mem.Allocator;
const format = @import("checkpoint_format.zig");

state: std.json.Parsed(format.State),

/// Frees the snapshot. No watcher or token borrows its storage.
pub fn deinit(p: *Checkpoint) void {
    p.state.deinit();
    p.* = undefined;
}

/// Writes an owned text token. The caller frees it with gpa.
pub fn token(p: Checkpoint, gpa: Allocator) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, p.state.value, .{});
}

pub const ParseError = Allocator.Error || error{InvalidCheckpoint};

/// Reads an owned snapshot. The input is borrowed only during this call.
/// Old scalar position tokens cannot describe unhanded changes and are
/// refused. Call deinit when the snapshot is no longer needed.
pub fn parse(gpa: Allocator, text: []const u8) ParseError!Checkpoint {
    return .{ .state = try format.parse(gpa, text) };
}

test "checkpoint tokens own their paths and refuse unknown formats" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const root = if (@import("builtin").os.tag == .windows) "C:\\watch" else "/watch";
    var original: Checkpoint = .{ .state = try format.copy(gpa, .{ .version = 1, .backend = .fsevents, .watches = &.{.{
        .root = root,
        .recursive = true,
        .cursor = 1234,
        .changes = &.{.{ .path = root, .kind = .modified, .target = .file }},
    }} }) };
    const text = try original.token(gpa);
    original.deinit();
    var parsed = try parse(gpa, text);
    gpa.free(text);
    defer parsed.deinit();
    try testing.expectEqual(@as(u64, 1234), parsed.state.value.watches[0].cursor);
    try testing.expectEqualStrings(root, parsed.state.value.watches[0].changes[0].path);
    for ([_][]const u8{ "", "1.fsevents.1234", "{}", "{\"version\":2,\"backend\":\"fsevents\",\"watches\":[]}", "{\"version\":1,\"backend\":\"poll\",\"watches\":[]}" }) |bad| {
        try testing.expectError(error.InvalidCheckpoint, parse(gpa, bad));
    }
}
