//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/Waker.zig",
        "src/backend/inotify_records.zig",
        "src/backend/windows_records.zig",
        "src/buffer.zig",
        "src/path.zig",
        "src/test_clock.zig",
        "src/trace.zig",
        "src/walk.zig",
    } },
    .{ .name = "path policy", .patterns = &.{
        "src/Budget.zig",
        "src/Deadline.zig",
        "src/Filter.zig",
    } },
    .{ .name = "event contracts", .patterns = &.{
        "src/types.zig",
    } },
    .{ .name = "records", .patterns = &.{
        "src/Snapshot.zig",
        "src/backend/fsevents_records.zig",
        "src/checkpoint_format.zig",
    } },
    .{ .name = "snapshots", .patterns = &.{
        "src/Baseline.zig",
        "src/Checkpoint.zig",
        "src/backend/fsevents_volume.zig",
    } },
    .{ .name = "configuration", .patterns = &.{
        "src/options.zig",
    } },
    .{ .name = "batching", .patterns = &.{
        "src/Batch.zig",
    } },
    .{ .name = "watch trees", .patterns = &.{
        "src/Tree.zig",
    } },
    .{ .name = "operation contracts", .patterns = &.{
        "src/watch_contract.zig",
    } },
    .{ .name = "platform backends", .patterns = &.{
        "src/backend/fsevents.zig",
        "src/backend/inotify.zig",
        "src/backend/kqueue.zig",
        "src/backend/poll.zig",
        "src/backend/windows.zig",
    } },
    .{ .name = "watcher", .patterns = &.{
        "src/lookout.zig",
    } },
    .{ .name = "scenarios", .patterns = &.{
        "src/test_backend_fsevents.zig",
        "src/test_backend_inotify.zig",
        "src/test_backend_windows.zig",
        "src/test_fuzz.zig",
        "src/test_gaps.zig",
        "src/test_resources.zig",
        "src/test_suite.zig",
    } },
    .{ .name = "tests", .patterns = &.{
        "src/tests.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};
