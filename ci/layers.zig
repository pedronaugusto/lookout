//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/SpinLock.zig",
        "src/Waker.zig",
        "src/filesystem.zig",
        "src/backend/inotify/records.zig",
        "src/backend/windows/records.zig",
        "src/buffer.zig",
        "src/path.zig",
        "src/testing/clock.zig",
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
        "src/backend/fsevents/records.zig",
        "src/Checkpoint/**",
    } },
    .{ .name = "baseline storage", .patterns = &.{"src/Baseline/**"} },
    .{ .name = "snapshots", .patterns = &.{
        "src/Baseline.zig",
        "src/Checkpoint.zig",
        "src/backend/fsevents/Volume.zig",
    } },
    .{ .name = "configuration", .patterns = &.{
        "src/options.zig",
    } },
    .{ .name = "batching", .patterns = &.{
        "src/Batch.zig",
    } },
    .{ .name = "watch trees", .patterns = &.{
        "src/Links.zig",
        "src/Tree.zig",
    } },
    .{ .name = "operation contracts", .patterns = &.{
        "src/watch_contract.zig",
    } },
    .{ .name = "platform backends", .patterns = &.{
        "src/backend/FsEvents.zig",
        "src/backend/Inotify.zig",
        "src/backend/Kqueue.zig",
        "src/backend/Poll.zig",
        "src/backend/Windows.zig",
        "src/backend.zig",
    } },
    .{ .name = "watcher", .patterns = &.{
        "src/lookout.zig",
    } },
    .{ .name = "scenarios", .patterns = &.{
        "src/backend/fsevents_test.zig",
        "src/backend/inotify_test.zig",
        "src/backend/windows_test.zig",
        "src/testing/fuzz_test.zig",
        "src/testing/gaps_test.zig",
        "src/testing/resources_test.zig",
        "src/testing/suite_test.zig",
        "src/links_test.zig",
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

pub const required = [_][]const u8{
    "src/SpinLock.zig",
    "src/Waker.zig",
    "src/filesystem.zig",
    "src/backend/inotify/records.zig",
    "src/backend/windows/records.zig",
    "src/buffer.zig",
    "src/path.zig",
    "src/testing/clock.zig",
    "src/trace.zig",
    "src/walk.zig",
    "src/Budget.zig",
    "src/Deadline.zig",
    "src/Filter.zig",
    "src/types.zig",
    "src/Snapshot.zig",
    "src/backend/fsevents/records.zig",
    "src/Checkpoint/format.zig",
    "src/Checkpoint/History.zig",
    "src/Baseline/format.zig",
    "src/Baseline.zig",
    "src/Checkpoint.zig",
    "src/backend/fsevents/Volume.zig",
    "src/options.zig",
    "src/Batch.zig",
    "src/Links.zig",
    "src/Tree.zig",
    "src/watch_contract.zig",
    "src/backend/FsEvents.zig",
    "src/backend/Inotify.zig",
    "src/backend/Kqueue.zig",
    "src/backend/Poll.zig",
    "src/backend/Windows.zig",
    "src/backend.zig",
    "src/lookout.zig",
    "src/backend/fsevents_test.zig",
    "src/backend/inotify_test.zig",
    "src/backend/windows_test.zig",
    "src/testing/fuzz_test.zig",
    "src/testing/gaps_test.zig",
    "src/testing/resources_test.zig",
    "src/testing/suite_test.zig",
    "src/links_test.zig",
    "src/tests.zig",
};

/// Tokens only their owners may spell: each backend alone speaks to its
/// kernel interface.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "inotify backend", .token = "inotify_init1", .owners = &.{ "src/backend/Inotify.zig", "src/backend/inotify/**" } },
    .{ .name = "inotify backend", .token = "inotify_add_watch", .owners = &.{ "src/backend/Inotify.zig", "src/backend/inotify/**" } },
    .{ .name = "inotify backend", .token = "inotify_rm_watch", .owners = &.{ "src/backend/Inotify.zig", "src/backend/inotify/**" } },
    .{ .name = "fsevents backend", .token = "FSEventStreamCreate", .owners = &.{ "src/backend/FsEvents.zig", "src/backend/fsevents/**" } },
    .{ .name = "fsevents backend", .token = "FSEventStreamStart", .owners = &.{ "src/backend/FsEvents.zig", "src/backend/fsevents/**" } },
    .{ .name = "kqueue backend", .token = "kevent", .owners = &.{"src/backend/Kqueue.zig"} },
    .{ .name = "windows backend", .token = "ReadDirectoryChangesW", .owners = &.{ "src/backend/Windows.zig", "src/backend/windows/**" } },
    .{ .name = "windows backend", .token = "CreateFileW", .owners = &.{ "src/backend/Windows.zig", "src/backend/windows/**" } },
    .{ .name = "windows backend", .kind = .string, .token = "kernel32", .owners = &.{ "src/backend/Windows.zig", "src/backend/windows/**", "src/filesystem.zig" } },
};
