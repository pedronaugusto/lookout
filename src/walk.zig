//! Walking a tree that somebody else made.
//!
//! Three places need the same walk: the Apple backend seeding what it
//! knows is there, and the Linux backend both registering a tree at
//! `add` and adopting one that has just appeared. Each wrote out the
//! same loop, and each had to get the same two things right -- a
//! frontier rather than recursion, because the depth of a tree an
//! unrelated process created is not this library's to bound, and a
//! directory that vanishes or is not ours to read being skipped rather
//! than failing the walk.
//!
//! The backends that compare directory listings do not use this. They
//! already hold a listing of every directory and descend through it, so
//! walking with a second listing would cost a pass over the tree that
//! their own snapshots have already paid for.

const std = @import("std");
const aegis = @import("aegis");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;
const stamp = @import("stamp.zig");
const shakedown = @import("shakedown");

/// The metadata `treeWithMeta` reads with each name: what a later `lstat`
/// of the same unchanged entry returns.
pub const Meta = struct {
    inode: Io.File.INode,
    size: u64,
    mtime: stamp.Stamp,
    ctime: stamp.Stamp,
    kind: Io.File.Kind,

    pub fn of(stat: Io.File.Stat) Meta {
        return .{ .inode = stat.inode, .size = stat.size, .mtime = stamp.of(stat.mtime), .ctime = stamp.of(stat.ctime), .kind = stat.kind };
    }
};

/// One entry the walk found.
pub const Entry = struct {
    /// The directory being listed, absolute.
    dir: []const u8,
    /// The entry's name inside it.
    name: []const u8,
    /// What the entry is, as the listing reports it.
    kind: Io.File.Kind,
    /// The entry's absolute path. Owned by the walk and valid only for
    /// the duration of the call; copy anything kept.
    path: []const u8,
    /// The entry's metadata, from `treeWithMeta` only. Null when it was not
    /// asked for or could not be read with the listing.
    meta: ?Meta = null,
};

/// What to do with an entry the walk found.
pub const Step = enum {
    /// Leave it alone. A directory answered with this is not descended
    /// into, and nothing below it is visited.
    over,
    /// Descend into it, when it is a directory.
    into,
};

/// Lists `root` and everything the visitor steps into, breadth first.
///
/// `visit` is called once per entry and says whether to go in. The root
/// itself is not visited: the caller already has it, and what it wants
/// done with it differs at all three call sites.
///
/// A directory that cannot be opened is skipped rather than failing the
/// walk: it has gone again, or it is not ours to read, and either way
/// its parent has already reported what it could.
pub fn tree(
    comptime Context: type,
    comptime visit: fn (Context, Entry) anyerror!Step,
    gpa: Allocator,
    io: Io,
    root: []const u8,
    context: Context,
) !void {
    return whole(Context, false, visit, gpa, io, root, context);
}

/// `tree`, with each entry's metadata read as the directory is listed.
///
/// On Apple systems one `getattrlistbulk` call returns the names and
/// metadata of many entries, without a lookup or `lstat` per entry: in a
/// 50,000-file tree, about half the time of a listing and an `lstat` each.
/// Elsewhere each entry is `lstat`ed.
pub fn treeWithMeta(
    comptime Context: type,
    comptime visit: fn (Context, Entry) anyerror!Step,
    gpa: Allocator,
    io: Io,
    root: []const u8,
    context: Context,
) !void {
    return whole(Context, true, visit, gpa, io, root, context);
}

fn whole(
    comptime Context: type,
    comptime with_meta: bool,
    comptime visit: fn (Context, Entry) anyerror!Step,
    gpa: Allocator,
    io: Io,
    root: []const u8,
    context: Context,
) !void {
    var walker = try Walker.init(gpa, root);
    defer walker.deinit(gpa);
    while (try walker.step(Context, with_meta, visit, gpa, io, context)) {}
}

/// A walk taken one directory at a time, for a caller that spreads it
/// over time and keeps working while it is under way. `tree` and
/// `treeWithMeta` are one run to its end.
///
/// The order is breadth first, the same as theirs, and a directory the
/// visitor steps into is listed by a later `step`, not at once. What the
/// walk has not listed yet can still change before it does, and `ahead`
/// is how a caller tells a path the walk is still to reach from one it
/// has passed.
pub const Walker = struct {
    /// The directories stepped into, in the order they are listed; those
    /// before `next` are done and already freed. Owned.
    frontier: std.ArrayList([]u8) = .empty,
    next: usize = 0,
    /// The directories from `next` on, by path, to answer `ahead`. Keys
    /// borrow `frontier`.
    unlisted: std.StringHashMapUnmanaged(void) = .empty,

    /// A walk of `root`, which its first `step` lists.
    pub fn init(gpa: Allocator, root: []const u8) Allocator.Error!Walker {
        var w: Walker = .{};
        errdefer w.deinit(gpa);
        try w.enqueue(gpa, try gpa.dupe(u8, root));
        return w;
    }

    pub fn deinit(w: *Walker, gpa: Allocator) void {
        for (w.frontier.items[w.next..]) |item| gpa.free(item);
        w.frontier.deinit(gpa);
        w.unlisted.deinit(gpa);
        w.* = undefined;
    }

    /// Whether every directory the walk stepped into has been listed.
    pub fn done(w: *const Walker) bool {
        return w.next == w.frontier.items.len;
    }

    /// Whether the directory `path` is in, or one above it, is still to
    /// be listed, so that the walk has not yet seen what is there and will
    /// see it as it is when it does. A path outside the walk is not ahead
    /// of it, and neither is the root.
    pub fn ahead(w: *const Walker, path: []const u8) bool {
        if (w.unlisted.count() == 0) return false;
        var dir = std.Io.Dir.path.dirname(path);
        while (dir) |d| : (dir = std.Io.Dir.path.dirname(d)) {
            if (w.unlisted.contains(d)) return true;
        }
        return false;
    }

    /// After `from` was renamed to `to`: what the walk was still to list
    /// under the old name it lists under the new one, where it is now, and
    /// what it was to list under the new name has gone with whatever the
    /// rename replaced.
    pub fn rename(w: *Walker, gpa: Allocator, from: []const u8, to: []const u8) Allocator.Error!void {
        var i = w.next;
        while (i < w.frontier.items.len) {
            const item = w.frontier.items[i];
            if (!under(to, item)) {
                i += 1;
                continue;
            }
            aegis.assert.invariant(w.unlisted.remove(item), "w.unlisted.remove(item)");
            gpa.free(w.frontier.orderedRemove(i));
        }
        for (w.frontier.items[w.next..]) |*item| {
            if (!under(from, item.*)) continue;
            const moved = try std.mem.concat(gpa, u8, &.{ to, item.*[from.len..] });
            errdefer gpa.free(moved);
            try w.unlisted.ensureUnusedCapacity(gpa, 1);
            aegis.assert.invariant(w.unlisted.remove(item.*), "w.unlisted.remove(item.*)");
            w.unlisted.putAssumeCapacityNoClobber(moved, {});
            gpa.free(item.*);
            item.* = moved;
        }
    }

    /// Lists `dir` too, unless the walk already has it to list.
    pub fn add(w: *Walker, gpa: Allocator, dir: []const u8) Allocator.Error!void {
        if (w.unlisted.contains(dir)) return;
        try w.enqueue(gpa, try gpa.dupe(u8, dir));
    }

    /// Whether `path` is `dir` or below it.
    fn under(dir: []const u8, path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, dir)) return false;
        return path.len == dir.len or std.Io.Dir.path.isSep(path[dir.len]);
    }

    /// Lists the next directory, calling `visit` for each entry in it, and
    /// answers whether there is more to list after it.
    ///
    /// An error from `visit` or an allocation leaves the walk where it was
    /// in the order, with what this directory held partly visited: a
    /// caller that goes on after one lists it again from the start.
    pub fn step(
        w: *Walker,
        comptime Context: type,
        comptime with_meta: bool,
        comptime visit: fn (Context, Entry) anyerror!Step,
        gpa: Allocator,
        io: Io,
        context: Context,
    ) !bool {
        if (w.done()) return false;
        const current = w.frontier.items[w.next];
        listing: {
            var dir = Io.Dir.openDirAbsolute(io, current, .{ .iterate = true }) catch |err| switch (err) {
                // Gone again, or not ours to read: skipped, as the header says.
                error.FileNotFound, error.NotDir, error.AccessDenied => break :listing,
                else => |e| return e,
            };
            defer dir.close(io);
            var it = if (with_meta and builtin.target.os.tag.isDarwin()) Bulk.init(dir) else dir.iterate();
            while (try it.next(io)) |listed| {
                const child = try std.Io.Dir.path.join(gpa, &.{ current, listed.name });
                var kept = false;
                defer if (!kept) gpa.free(child);

                const meta: ?Meta = if (!with_meta)
                    null
                else if (@TypeOf(listed) == Bulk.Listed)
                    listed.meta
                else if (dir.statFile(io, listed.name, .{ .follow_symlinks = false })) |stat| .of(stat) else |err| switch (err) {
                    // Gone since the listing, or not ours to read: no metadata.
                    error.FileNotFound, error.AccessDenied => null,
                    else => |e| return e,
                };
                const step_into = try visit(context, .{
                    .dir = current,
                    .name = listed.name,
                    .kind = listed.kind,
                    .path = child,
                    .meta = meta,
                });
                if (step_into == .into and listed.kind == .directory and !w.unlisted.contains(child)) {
                    kept = true;
                    try w.enqueue(gpa, child);
                }
            }
        }
        aegis.assert.invariant(w.unlisted.remove(current), "w.unlisted.remove(current)");
        gpa.free(current);
        w.next += 1;
        // What is done is dropped from the front once it is most of the
        // list, so a long walk holds what it has still to list and not
        // everything it has listed.
        if (w.next >= 64 and w.next * 2 >= w.frontier.items.len) {
            const left = w.frontier.items.len - w.next;
            @memmove(w.frontier.items[0..left], w.frontier.items[w.next..]);
            w.frontier.shrinkRetainingCapacity(left);
            w.next = 0;
        }
        return !w.done();
    }

    /// Takes `path`, owned, as the last directory to list.
    fn enqueue(w: *Walker, gpa: Allocator, path: []u8) Allocator.Error!void {
        errdefer gpa.free(path);
        try w.frontier.ensureUnusedCapacity(gpa, 1);
        try w.unlisted.put(gpa, path, {});
        w.frontier.appendAssumeCapacity(path);
    }
};

/// A directory listed by `getattrlistbulk`, many entries per call.
const Bulk = struct {
    fd: std.posix.fd_t,
    buffer: [16 * 1024]u8 align(8) = undefined,
    /// Entries left in the buffer, and where the next one starts.
    left: usize = 0,
    at: usize = 0,

    const Listed = struct { name: []const u8, kind: Io.File.Kind, meta: ?Meta };

    const AttrList = extern struct {
        count: u16 = 5,
        reserved: u16 = 0,
        common: u32 = 0,
        volume: u32 = 0,
        directory: u32 = 0,
        file: u32 = 0,
        fork: u32 = 0,
    };
    /// What each entry carries, in the order the buffer holds it.
    const name = 0x0000_0001;
    const objtype = 0x0000_0008;
    const modtime = 0x0000_0400;
    const chgtime = 0x0000_0800;
    const fileid = 0x0200_0000;
    const err = 0x2000_0000;
    const returned = 0x8000_0000;
    const dir_datalength = 0x0000_0020;
    const file_datalength = 0x0000_0200;
    const meta_common = objtype | modtime | chgtime | fileid;

    // aegis: boundary(A019): libc's getattrlistbulk, declared as the system documents it, called only from this file
    extern "c" fn getattrlistbulk(c_int, *AttrList, *anyopaque, usize, u64) c_int;

    fn init(dir: Io.Dir) Bulk {
        return .{ .fd = dir.handle };
    }

    fn next(b: *Bulk, _: Io) error{Unexpected}!?Listed {
        while (b.left == 0) {
            var attrs: AttrList = .{
                .common = returned | err | name | meta_common,
                .directory = dir_datalength,
                .file = file_datalength,
            };
            const count = getattrlistbulk(b.fd, &attrs, &b.buffer, b.buffer.len, 0);
            if (count == 0) return null;
            if (count < 0) return error.Unexpected;
            b.left = @intCast(count);
            b.at = 0;
        }
        b.left -= 1;
        const start = b.at;
        const length = b.read(u32, start);
        if (length < 4 or start + length > b.buffer.len) return error.Unexpected;
        b.at = start + length;
        var field = start + 4;
        const set = [5]u32{ b.read(u32, field), b.read(u32, field + 4), b.read(u32, field + 8), b.read(u32, field + 12), b.read(u32, field + 16) };
        field += 20;
        var failed = false;
        if (set[0] & err != 0) {
            failed = b.read(u32, field) != 0;
            field += 4;
        }
        if (set[0] & name == 0) return error.Unexpected;
        const name_offset = b.read(i32, field);
        const name_length = b.read(u32, field + 4);
        const name_start: usize = @intCast(@as(isize, @intCast(field)) + name_offset);
        if (name_length == 0 or name_start + name_length > b.at) return error.Unexpected;
        const entry_name = b.buffer[name_start..][0 .. name_length - 1];
        field += 8;
        if (set[0] & objtype == 0) return error.Unexpected;
        const kind = kindOf(b.read(u32, field));
        field += 4;
        if (failed or set[0] & meta_common != meta_common) return .{ .name = entry_name, .kind = kind, .meta = null };
        const mtime = b.time(field);
        const ctime = b.time(field + 16);
        const inode = b.read(u64, field + 32);
        field += 40;
        const sized = if (kind == .directory) set[2] & dir_datalength != 0 else set[3] & file_datalength != 0;
        if (!sized) return .{ .name = entry_name, .kind = kind, .meta = null };
        const size = b.read(i64, field);
        return .{ .name = entry_name, .kind = kind, .meta = .{
            .inode = inode,
            .size = @bitCast(size),
            .mtime = mtime,
            .ctime = ctime,
            .kind = kind,
        } };
    }

    /// Fields are packed at four-byte alignment.
    fn read(b: *const Bulk, comptime T: type, at: usize) T {
        return std.mem.readInt(T, b.buffer[at..][0..@sizeOf(T)], builtin.target.cpu.arch.endian());
    }

    fn time(b: *const Bulk, at: usize) stamp.Stamp {
        return stamp.ofTimespec(b.read(i64, at), b.read(i64, at + 8));
    }

    fn kindOf(vtype: u32) Io.File.Kind {
        return switch (vtype) {
            1 => .file,
            2 => .directory,
            3 => .block_device,
            4 => .character_device,
            5 => .sym_link,
            6 => .unix_domain_socket,
            7 => .named_pipe,
            else => .unknown,
        };
    }
};

const testing = std.testing;

test "a walk visits every entry it is let into, and nothing below one it is not" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "keep/deeper");
    try tmp.dir.createDirPath(io, "skip/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "keep/deeper/a.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skip/deeper/b.txt", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const Seen = struct {
        gpa: Allocator,
        names: std.ArrayList([]u8),

        const Self = @This();

        fn visit(s: *Self, entry: Entry) anyerror!Step {
            try s.names.append(s.gpa, try s.gpa.dupe(u8, entry.name));
            if (std.mem.eql(u8, entry.name, "skip")) return .over;
            return .into;
        }
        fn holds(s: *const Self, name: []const u8) bool {
            for (s.names.items) |seen| {
                if (std.mem.eql(u8, seen, name)) return true;
            }
            return false;
        }
    };
    var seen: Seen = .{ .gpa = gpa, .names = .empty };
    defer {
        for (seen.names.items) |name| gpa.free(name);
        seen.names.deinit(gpa);
    }

    try tree(*Seen, Seen.visit, gpa, io, root, &seen);
    try testing.expect(seen.holds("keep"));
    try testing.expect(seen.holds("deeper"));
    try testing.expect(seen.holds("a.txt"));
    try testing.expect(seen.holds("skip"));
    // `skip` was visited and refused, so nothing inside it was.
    try testing.expect(!seen.holds("b.txt"));
}

test "a walk of an empty or unreadable tree visits nothing and does not fail" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const Count = struct {
        seen: usize = 0,
        const Self = @This();

        fn visit(c: *Self, _: Entry) anyerror!Step {
            c.seen += 1;
            return .into;
        }
    };
    var count: Count = .{};
    try tree(*Count, Count.visit, gpa, io, root, &count);
    try testing.expectEqual(@as(usize, 0), count.seen);

    const absent = try std.Io.Dir.path.join(gpa, &.{ root, "not-there" });
    defer gpa.free(absent);
    try tree(*Count, Count.visit, gpa, io, absent, &count);
    try testing.expectEqual(@as(usize, 0), count.seen);
}

test "a walk with metadata reads what lstat reads, across listing batches" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/file", .data = "contents" });
    if (builtin.target.os.tag != .windows) try tmp.dir.symLink(io, "file", "dir/link", .{});
    // Long names so one directory takes several bulk listings.
    var name_buffer: [200]u8 = undefined;
    for (0..300) |i| {
        const name = try std.mem.print(&name_buffer, "{d:0>3}{s}", .{ i, &@as([190]u8, @splat('n')) });
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = name[0 .. i % name.len] });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const Check = struct {
        seen: usize = 0,
        const Self = @This();

        fn visit(c: *Self, entry: Entry) anyerror!Step {
            c.seen += 1;
            const stat = try Io.Dir.cwd().statFile(testing.io, entry.path, .{ .follow_symlinks = false });
            try testing.expectEqual(stat.kind, entry.kind);
            try testing.expectEqual(Meta.of(stat), entry.meta.?);
            return .into;
        }
    };
    var check: Check = .{};
    try treeWithMeta(*Check, Check.visit, gpa, io, root, &check);
    const links: usize = if (builtin.target.os.tag == .windows) 0 else 1;
    try testing.expectEqual(300 + 2 + links, check.seen);
}

test "a failed walk frontier allocation releases its root" {
    const Visitor = struct {
        fn visit(_: void, _: Entry) anyerror!Step {
            return .over;
        }
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, tree(void, Visitor.visit, failing.allocator(), testing.io, "/unused", {}));
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "a walker lists one directory a step, and says what it has yet to reach" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/c.txt", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const in_b = try std.Io.Dir.path.join(gpa, &.{ root, "a", "b", "c.txt" });
    defer gpa.free(in_b);
    const in_a = try std.Io.Dir.path.join(gpa, &.{ root, "a", "b" });
    defer gpa.free(in_a);

    const Count = struct {
        seen: usize = 0,
        fn visit(c: *@This(), _: Entry) anyerror!Step {
            c.seen += 1;
            return .into;
        }
    };
    var count: Count = .{};
    var walker = try Walker.init(gpa, root);
    defer walker.deinit(gpa);
    try testing.expect(walker.ahead(in_a));
    try testing.expect(!walker.ahead(root));
    try testing.expect(try walker.step(*Count, false, Count.visit, gpa, io, &count));
    try testing.expectEqual(@as(usize, 1), count.seen);
    // The root is listed and `a` is not: what is in `a` is ahead.
    try testing.expect(walker.ahead(in_a));
    try testing.expect(try walker.step(*Count, false, Count.visit, gpa, io, &count));
    try testing.expect(!walker.ahead(in_a));
    try testing.expect(walker.ahead(in_b));
    try testing.expect(!try walker.step(*Count, false, Count.visit, gpa, io, &count));
    try testing.expectEqual(@as(usize, 3), count.seen);
    try testing.expect(walker.done());
    try testing.expect(!walker.ahead(in_b));
}

test "a directory not ours to read is skipped; a cancel, or a listing that fails, ends the walk with it" {
    const gpa = testing.allocator;
    const fio = try shakedown.FaultIo.init(gpa, testing.io, .{});
    defer fio.deinit();
    const io = fio.io();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a/b");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);

    const Count = struct {
        seen: usize = 0,
        fn visit(c: *@This(), _: Entry) anyerror!Step {
            c.seen += 1;
            return .into;
        }
    };
    // `a` refused: skipped, and `b` in it never reached.
    var count: Count = .{};
    try fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .dirOpenDir, .n = 2 } }, .fault = .{ .fail = error.AccessDenied } }});
    try tree(*Count, Count.visit, gpa, io, root, &count);
    try testing.expectEqual(@as(usize, 1), count.seen);
    // Before, a cancel there was a walk that ended early and said nothing.
    count = .{};
    try fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .dirOpenDir, .n = 2 } }, .fault = .{ .fail = error.Canceled } }});
    try testing.expectError(error.Canceled, tree(*Count, Count.visit, gpa, io, root, &count));
    count = .{};
    try fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .dirRead, .n = 1 } }, .fault = .{ .fail = error.Canceled } }});
    try testing.expectError(error.Canceled, tree(*Count, Count.visit, gpa, io, root, &count));
    try testing.expectEqual(@as(usize, 0), count.seen);
}

test "a walker follows a rename of what it has yet to list, and drops what the rename replaced" {
    const gpa = testing.allocator;
    var walker = try Walker.init(gpa, "/w");
    defer walker.deinit(gpa);
    try walker.add(gpa, "/w/a");
    try walker.add(gpa, "/w/a/b");
    try walker.add(gpa, "/w/ab");
    try walker.add(gpa, "/w/z/old");
    try walker.add(gpa, "/w/a");
    try testing.expectEqual(@as(usize, 5), walker.frontier.items.len);
    try walker.rename(gpa, "/w/a", "/w/z");
    try testing.expectEqual(@as(usize, 4), walker.frontier.items.len);
    try testing.expectEqualStrings("/w/z", walker.frontier.items[1]);
    try testing.expectEqualStrings("/w/z/b", walker.frontier.items[2]);
    // A sibling whose name only starts the same is not moved.
    try testing.expectEqualStrings("/w/ab", walker.frontier.items[3]);
    try testing.expect(walker.ahead("/w/z/b/file"));
    try testing.expect(!walker.ahead("/elsewhere/file"));
}
