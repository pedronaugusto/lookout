//! Test assembly above the watcher.
test {
    if (comptime @import("lookout.zig").supported(.inotify)) _ = @import("backend/inotify_test.zig");
    _ = @import("backend/windows_test.zig");
    if (comptime @import("lookout.zig").supported(.fsevents)) _ = @import("backend/fsevents_test.zig");
    _ = @import("lookout.zig");
    _ = @import("suite_test.zig");
    _ = @import("resources_test.zig");
    _ = @import("gaps_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("testing/links.zig");
}
