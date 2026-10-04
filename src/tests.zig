//! Test assembly above the watcher.
test {
    if (comptime @import("lookout.zig").supported(.inotify)) _ = @import("backend/inotify_test.zig");
    _ = @import("backend/windows_test.zig");
    if (comptime @import("lookout.zig").supported(.fsevents)) _ = @import("backend/fsevents_test.zig");
    _ = @import("lookout.zig");
    _ = @import("testing/suite_test.zig");
    _ = @import("testing/resources_test.zig");
    _ = @import("testing/gaps_test.zig");
    _ = @import("testing/fuzz_test.zig");
    _ = @import("Links_test.zig");
}
