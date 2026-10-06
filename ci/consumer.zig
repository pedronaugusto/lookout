//! What a project that depends on lookout writes.
const std = @import("std");
const lookout = @import("lookout");

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var watcher: lookout.Watcher = try .init(std.heap.page_allocator, threaded.io(), .{});
    defer watcher.deinit();
}
