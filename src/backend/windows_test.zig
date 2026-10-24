//! Watcher integration scenarios for windows.
const std = @import("std");
const wait = @import("../testing/wait.zig");
const windows = std.os.windows;
const lookout = @import("../lookout.zig");
const ms = @import("../testing/timeout.zig").ms;
const Target = lookout.Target;

const builtin = @import("builtin");

test "a read that completes with nothing is an overflow, and the watch reads on" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    // ReadDirectoryChangesW: "If the number of changes exceeds the
    // buffer size, the entire contents of the buffer are discarded, the
    // lpBytesReturned parameter contains zero": a read that ends having
    // transferred nothing. `overflowForTest` holds one in the kernel's
    // place, the one overflow signal a test can make: a burst the kernel
    // cannot hold between two reads is not something a test can order.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var watcher: lookout.Watcher = try .init(gpa, std.testing.io, .{ .backend = .windows });
    defer watcher.deinit(io);
    const id = try watcher.add(io, root, .{});
    while ((try watcher.poll(io, ms(200))).len != 0) {}
    const w = &watcher.impl.windows;

    // The read that is outstanding is taken back first, so that the
    // completion held stands in for it rather than beside it: a watch
    // re-armed while a read is still pending would have two reads on
    // one buffer, which is not a state the kernel ever puts it in.
    try w.overflowForTest(io, id);

    var overflows: usize = 0;
    var deadline: wait.Deadline = .after(io, wait.event_ms);
    while (deadline.running(io) and overflows == 0) {
        for (try watcher.poll(io, ms(200))) |event| {
            if (event.kind != .overflow) continue;
            try testing.expectEqual(id, event.id);
            try testing.expectEqualStrings(root, event.path);
            try testing.expectEqual(Target.directory, event.target);
            overflows += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), overflows);

    // Re-armed: the watch is still held, and the next change is read.
    try testing.expect(w.watches.contains(id));
    try tmp.dir.writeFile(io, .{ .sub_path = "after.txt", .data = "x" });
    const after = try std.Io.Dir.path.join(gpa, &.{ root, "after.txt" });
    defer gpa.free(after);
    var found = false;
    deadline = .after(io, wait.event_ms);
    while (deadline.running(io) and !found) {
        for (try watcher.poll(io, ms(200))) |event| {
            if (event.kind == .created and std.mem.eql(u8, event.path, after)) found = true;
        }
    }
    try testing.expect(found);
}

test "a lost read reads the entry counts again, so the budget holds after it" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    // Three creations, read and counted; then the count set back to what
    // it would have been had the kernel discarded them, which is what a
    // read it could not hold does ("the entire contents of the buffer
    // are discarded"). The completion that says so is posted by hand,
    // as above. A count that is not read again stays three short for as
    // long as the watch lasts.
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    var watcher: lookout.Watcher = try .init(gpa, std.testing.io, .{ .backend = .windows, .max_dir_entries = 3 });
    defer watcher.deinit(io);
    const id = try watcher.add(io, root, .{});
    while ((try watcher.poll(io, ms(200))).len != 0) {}
    const w = &watcher.impl.windows;

    for ([_][]const u8{ "a", "b", "c" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }
    var created: usize = 0;
    var deadline: wait.Deadline = .after(io, wait.event_ms);
    while (deadline.running(io) and created < 3) {
        for (try watcher.poll(io, ms(200))) |event| {
            if (event.kind == .created) created += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), created);
    try w.budget.misread(root, true, 0);

    try w.overflowForTest(io, id);

    var overflowed = false;
    deadline = .after(io, wait.event_ms);
    while (deadline.running(io) and !overflowed) {
        for (try watcher.poll(io, ms(200))) |event| {
            if (event.kind == .overflow) overflowed = true;
        }
    }
    try testing.expect(overflowed);
    // Three entries: at the budget, as the folder is.
    try testing.expectEqual(@as(usize, 3), w.budget.count(root).?);

    // So the fourth is past it, and the watch is told.
    try tmp.dir.writeFile(io, .{ .sub_path = "d", .data = "x" });
    overflowed = false;
    deadline = .after(io, wait.event_ms);
    while (deadline.running(io) and !overflowed) {
        for (try watcher.poll(io, ms(200))) |event| {
            if (event.kind == .overflow and event.id == id and std.mem.eql(u8, event.path, root)) overflowed = true;
        }
    }
    try testing.expect(overflowed);
}

test "allocation failure during delivery releases a removed Windows completion" {
    const io = std.testing.io;
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var watcher = try lookout.Watcher.init(failing.allocator(), std.testing.io, .{ .backend = .windows });
    defer watcher.deinit(io);
    const id = try watcher.add(io, root, .{});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "change", .data = "x" });
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, watcher.poll(io, ms(10_000)));
    failing.fail_index = std.math.maxInt(usize);
    // The packet has been taken and no replacement read is outstanding.
    // Removing it has no later completion to wait for before freeing it.
    watcher.remove(io, id);
    try testing.expect(watcher.impl.windows.retiring == null);
}
