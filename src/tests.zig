//! Test assembly above the watcher.
const lookout = @import("lookout.zig");
test {
    if (comptime lookout.supported(.inotify)) _ = @import("backend/inotify_test.zig");
    _ = @import("backend/windows_test.zig");
    if (comptime lookout.supported(.fsevents)) _ = @import("backend/fsevents_test.zig");
    _ = @import("lookout.zig");
    _ = @import("testing/suite_test.zig");
    _ = @import("testing/resources_test.zig");
    _ = @import("testing/gaps_test.zig");
    _ = @import("testing/fuzz_test.zig");
    _ = @import("Links_test.zig");
    _ = @import("Checkpoint/paths.zig");
    if (comptime lookout.supported(.kqueue)) _ = @import("backend/kqueue.zig");
    _ = @import("backend/windows/records.zig");
}
