//! Production source layers, lowest first. Every production source has one
//! place; test code is in no layer.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/timing.zig",
        "src/filesystem.zig",
        "src/identity.zig",
        "src/backend/inotify/records.zig",
        "src/backend/windows/records.zig",
        "src/buffer.zig",
        "src/path.zig",
        "src/trace.zig",
        "src/walk.zig",
        "src/Filter.zig",
    } },
    .{ .name = "path policy", .patterns = &.{
        "src/Budget.zig",
        "src/CompiledFilter.zig",
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
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "aegis",
        "airlock",
        "airlock.testing",
        "builtin",
        "reactor",
        "shakedown",
        "std",
        "sweep",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
    "src/timing.zig",
    "src/filesystem.zig",
    "src/identity.zig",
    "src/backend/inotify/records.zig",
    "src/backend/windows/records.zig",
    "src/buffer.zig",
    "src/path.zig",
    "src/trace.zig",
    "src/walk.zig",
    "src/Budget.zig",
    "src/Filter.zig",
    "src/CompiledFilter.zig",
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
    "src/tests.zig",
};

/// Tokens only their owners may spell: each backend alone speaks to its
/// kernel interface.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "inotify backend", .tokens = &.{ "inotify_init1", "inotify_add_watch", "inotify_rm_watch" }, .owners = &.{ "src/backend/Inotify.zig", "src/backend/inotify/**" } },
    .{ .name = "fsevents backend", .tokens = &.{ "FSEventStreamCreate", "FSEventStreamStart" }, .owners = &.{ "src/backend/FsEvents.zig", "src/backend/fsevents/**" } },
    .{ .name = "kqueue backend", .tokens = &.{"kevent"}, .owners = &.{"src/backend/Kqueue.zig"} },
    .{ .name = "windows backend", .tokens = &.{ "ReadDirectoryChangesW", "CreateFileW" }, .owners = &.{ "src/backend/Windows.zig", "src/backend/windows/**" } },
    .{ .name = "windows backend", .kind = .string, .tokens = &.{"kernel32"}, .owners = &.{ "src/backend/Windows.zig", "src/backend/windows/**", "src/filesystem.zig", "src/identity.zig" } },
    // A test double is a shakedown `Clock`, `FaultIo` or `Layer`, never a
    // copied `Io` vtable with a slot replaced: such a copy keeps its state in
    // globals and cannot be stacked. The one exception is an allocator that
    // looks at a lock when it is called, which shakedown's do not offer.
    .{ .name = "test doubles on shakedown", .tokens = &.{ "vtable", "VTable" }, .owners = &.{"src/testing/LockProbe.zig"} },
};
