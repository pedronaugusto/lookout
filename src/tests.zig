//! Test assembly above the watcher.
test {
    if (comptime @import("lookout.zig").supported(.inotify)) _ = @import("test_backend_inotify.zig");
    _ = @import("test_backend_windows.zig");
    if (comptime @import("lookout.zig").supported(.fsevents)) _ = @import("test_backend_fsevents.zig");
    _ = @import("lookout.zig");
    _ = @import("test_suite.zig");
    _ = @import("test_links.zig");
    _ = @import("test_resources.zig");
    _ = @import("test_gaps.zig");
    _ = @import("test_fuzz.zig");
}
