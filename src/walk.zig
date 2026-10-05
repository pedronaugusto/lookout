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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The metadata `treeWithMeta` reads with each name: what a later `lstat`
/// of the same unchanged entry returns.
pub const Meta = struct {
    inode: Io.File.INode,
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,
    kind: Io.File.Kind,

    pub fn of(stat: Io.File.Stat) Meta {
        return .{ .inode = stat.inode, .size = stat.size, .mtime_ns = stat.mtime.nanoseconds, .ctime_ns = stat.ctime.nanoseconds, .kind = stat.kind };
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
    gpa: Allocator,
    io: Io,
    root: []const u8,
    context: anytype,
    comptime visit: fn (@TypeOf(context), Entry) anyerror!Step,
) !void {
    return walk(false, gpa, io, root, context, visit);
}

/// `tree`, with each entry's metadata read as the directory is listed.
///
/// On Apple systems one `getattrlistbulk` call returns the names and
/// metadata of many entries, without a lookup or `lstat` per entry: in a
/// 50,000-file tree, about half the time of a listing and an `lstat` each.
/// Elsewhere each entry is `lstat`ed.
pub fn treeWithMeta(
    gpa: Allocator,
    io: Io,
    root: []const u8,
    context: anytype,
    comptime visit: fn (@TypeOf(context), Entry) anyerror!Step,
) !void {
    return walk(true, gpa, io, root, context, visit);
}

fn walk(
    comptime with_meta: bool,
    gpa: Allocator,
    io: Io,
    root: []const u8,
    context: anytype,
    comptime visit: fn (@TypeOf(context), Entry) anyerror!Step,
) !void {
    var frontier: std.ArrayList([]u8) = .empty;
    defer {
        for (frontier.items) |item| gpa.free(item);
        frontier.deinit(gpa);
    }
    {
        const owned = try gpa.dupe(u8, root);
        errdefer gpa.free(owned);
        try frontier.append(gpa, owned);
    }

    var i: usize = 0;
    while (i < frontier.items.len) : (i += 1) {
        const current = frontier.items[i];
        var dir = Io.Dir.openDirAbsolute(io, current, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = if (with_meta and builtin.os.tag.isDarwin()) Bulk.init(dir) else dir.iterate();
        while (it.next(io) catch null) |listed| {
            const child = try std.fs.path.join(gpa, &.{ current, listed.name });
            var kept = false;
            defer if (!kept) gpa.free(child);

            const meta: ?Meta = if (!with_meta)
                null
            else if (@TypeOf(listed) == Bulk.Listed)
                listed.meta
            else if (dir.statFile(io, listed.name, .{ .follow_symlinks = false })) |stat| .of(stat) else |_| null;
            const step = try visit(context, .{
                .dir = current,
                .name = listed.name,
                .kind = listed.kind,
                .path = child,
                .meta = meta,
            });
            if (step == .into and listed.kind == .directory) {
                try frontier.append(gpa, child);
                kept = true;
            }
        }
    }
}

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
            .mtime_ns = mtime,
            .ctime_ns = ctime,
            .kind = kind,
        } };
    }

    /// Fields are packed at four-byte alignment.
    fn read(b: *const Bulk, comptime T: type, at: usize) T {
        return std.mem.readInt(T, b.buffer[at..][0..@sizeOf(T)], builtin.cpu.arch.endian());
    }

    fn time(b: *const Bulk, at: usize) i96 {
        return @as(i96, b.read(i64, at)) * std.time.ns_per_s + b.read(i64, at + 8);
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

    try tree(gpa, io, root, &seen, Seen.visit);
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
    try tree(gpa, io, root, &count, Count.visit);
    try testing.expectEqual(@as(usize, 0), count.seen);

    const absent = try std.fs.path.join(gpa, &.{ root, "not-there" });
    defer gpa.free(absent);
    try tree(gpa, io, absent, &count, Count.visit);
    try testing.expectEqual(@as(usize, 0), count.seen);
}

test "a walk with metadata reads what lstat reads, across listing batches" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "dir/file", .data = "contents" });
    if (builtin.os.tag != .windows) try tmp.dir.symLink(io, "file", "dir/link", .{});
    // Long names so one directory takes several bulk listings.
    var name_buffer: [200]u8 = undefined;
    for (0..300) |i| {
        const name = try std.fmt.bufPrint(&name_buffer, "{d:0>3}{s}", .{ i, "n" ** 190 });
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
    try treeWithMeta(gpa, io, root, &check, Check.visit);
    const links: usize = if (builtin.os.tag == .windows) 0 else 1;
    try testing.expectEqual(300 + 2 + links, check.seen);
}

test "a failed walk frontier allocation releases its root" {
    const Visitor = struct {
        fn visit(_: void, _: Entry) anyerror!Step {
            return .over;
        }
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, tree(failing.allocator(), testing.io, "/unused", {}, Visitor.visit));
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
