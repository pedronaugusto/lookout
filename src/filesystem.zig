//! The filesystem fact behind automatic per-watch backend selection.
const std = @import("std");
const builtin = @import("builtin");

/// Native notifications on network and FUSE mounts may miss external writes.
/// Unknown means the OS query failed or this target has no type query.
pub const Kind = enum { local, network, fuse, unknown };

pub const Source = *const fn (std.mem.Allocator, std.Io, []const u8) Kind;
pub const test_access = if (builtin.is_test) struct {
    pub threadlocal var source: ?Source = null;
} else struct {};

pub fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Kind {
    if (builtin.is_test) if (test_access.source) |source| return source(gpa, io, path);
    if (builtin.os.tag == .windows) return readWindows(gpa, io, path);
    if (builtin.os.tag == .dragonfly) {
        const name = gpa.dupeZ(u8, path) catch return .unknown;
        defer gpa.free(name);
        var stat: DragonflyStatfs = undefined;
        if (dragonfly.statfs(name, &stat) != 0) return .unknown;
        return named(std.mem.sliceTo(&stat.name, 0), stat.flags & 0x1000 != 0);
    }
    if (builtin.os.tag == .linux) {
        const name = gpa.dupeZ(u8, path) catch return .unknown;
        defer gpa.free(name);
        // statfs writes a native-word structure; its first word is f_type.
        // This storage exceeds every Linux ABI's statfs structure.
        var storage: [64]usize = undefined;
        const rc = std.os.linux.syscall2(.statfs, @intFromPtr(name.ptr), @intFromPtr(&storage)); // safe: the syscall borrows the terminated name and writable aligned statfs storage
        if (std.os.linux.errno(rc) != .SUCCESS) return .unknown;
        return linuxType(storage[0]);
    }
    if (builtin.os.tag.isDarwin() or builtin.os.tag == .freebsd or builtin.os.tag == .openbsd or builtin.os.tag == .netbsd) {
        const c = @cImport({
            if (builtin.os.tag == .netbsd) @cDefine("_Pragma(x)", "");
            @cInclude("sys/param.h");
            if (builtin.os.tag == .netbsd) @cInclude("sys/statvfs.h") else @cInclude("sys/mount.h");
        });
        const name = gpa.dupeZ(u8, path) catch return .unknown;
        defer gpa.free(name);
        if (builtin.os.tag == .netbsd) {
            var stat: c.struct_statvfs = undefined;
            if (c.statvfs(name, &stat) != 0) return .unknown;
            return named(std.mem.sliceTo(&stat.f_fstypename, 0), stat.f_flag & 0x1000 != 0);
        } else {
            var stat: c.struct_statfs = undefined;
            if (c.statfs(name, &stat) != 0) return .unknown;
            return named(std.mem.sliceTo(&stat.f_fstypename, 0), stat.f_flags & 0x1000 != 0);
        }
    }
    return .unknown;
}

fn linuxType(number: usize) Kind {
    return switch (number) {
        0x65735546 => .fuse,
        0x6969, 0x517B, 0xff534d42, 0xfe534d42, 0x73757245, 0x5346414f, 0x6B414653, 0x564c, 0x01021997 => .network,
        else => .local,
    };
}

fn named(name: []const u8, local: bool) Kind {
    if (std.mem.indexOf(u8, name, "fuse") != null or std.mem.indexOf(u8, name, "puffs") != null) return .fuse;
    return if (local) .local else .network;
}

fn readWindows(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Kind {
    const w = std.os.windows;
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch return .unknown;
    defer gpa.free(wide);
    var volume: [32768]u16 = undefined;
    if (GetVolumePathNameW(wide, &volume, volume.len) == .FALSE) return .unknown;
    const drive = GetDriveTypeW(@ptrCast(&volume)); // safe: GetVolumePathNameW returns a terminated WCHAR volume path
    if (drive == 0 or drive == 1) return .unknown;
    if (drive == 4 or std.mem.startsWith(u8, path, "\\\\")) return .network;
    // A redirector or mounted remote device need not have a UNC spelling.
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .unknown;
    defer file.close(io);
    var status: w.IO_STATUS_BLOCK = undefined;
    var device: w.FILE.FS_DEVICE_INFORMATION = undefined;
    const result = w.ntdll.NtQueryVolumeInformationFile(file.handle, &status, &device, @sizeOf(@TypeOf(device)), .Device);
    if (result != .SUCCESS) return .unknown;
    if (device.Characteristics & 0x10 != 0) return .network; // FILE_REMOTE_DEVICE
    var attributes: extern struct { flags: u32, max_component: i32, name_bytes: u32, name: [128]u16 } = undefined;
    if (w.ntdll.NtQueryVolumeInformationFile(file.handle, &status, &attributes, @sizeOf(@TypeOf(attributes)), .Attribute) == .SUCCESS) {
        if (attributes.name_bytes <= @sizeOf(@TypeOf(attributes.name)) and attributes.name_bytes % 2 == 0) {
            var utf8: [512]u8 = undefined;
            const n = std.unicode.utf16LeToUtf8(&utf8, attributes.name[0 .. attributes.name_bytes / 2]) catch return .unknown;
            const fs_name = utf8[0..n];
            if (std.ascii.eqlIgnoreCase(fs_name, "FUSE") or std.ascii.eqlIgnoreCase(fs_name, "WinFsp")) return .fuse;
        }
    }
    return .local;
}

// DragonFly's stable statfs ABI; Zig ships no DragonFly C headers.
const DragonflyStatfs = extern struct {
    counts: [8]c_long,
    fsid: [2]i32,
    owner: u32,
    fs_type: c_int,
    flags: c_int,
    sync_writes: c_long,
    async_writes: c_long,
    name: [16]u8,
    mounted_on: [80]u8,
    sync_reads: c_long,
    async_reads: c_long,
    spare1: c_short,
    mounted_from: [80]u8,
    spare2: c_short,
    spare: [2]c_long,
};
const dragonfly = struct {
    extern "c" fn statfs([*:0]const u8, *DragonflyStatfs) c_int;
};

/// What a directory is, rather than what it is called: two paths with one
/// identity reach one directory. The device and inode number on POSIX, the
/// volume serial number and file id on Windows.
pub const Identity = struct {
    device: u64,
    file: u128,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.device == b.device and a.file == b.file;
    }
};

/// The identity of what `path` names, symbolic links followed. Null when it
/// cannot be read, or on a target with no way to ask.
pub fn identity(io: std.Io, path: []const u8) ?Identity {
    if (builtin.os.tag == .windows) return identityWindows(io, path);
    const name = std.posix.toPosixPath(path) catch return null;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, &name, 0, .{ .INO = true }, &stat);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .device = @as(u64, stat.dev_major) << 32 | stat.dev_minor, .file = stat.ino };
    }
    switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            var stat: std.c.Stat = undefined;
            if (std.c.fstatat(std.c.AT.FDCWD, &name, &stat, 0) != 0) return null;
            return .{ .device = unsigned(stat.dev), .file = unsigned(stat.ino) };
        },
        else => return null,
    }
}

/// A device or inode number of whatever width and sign the C library
/// gives it, as the bits it holds.
fn unsigned(value: anytype) u64 {
    return @as(@Int(.unsigned, @bitSizeOf(@TypeOf(value))), @bitCast(value));
}

fn identityWindows(io: std.Io, path: []const u8) ?Identity {
    const w = std.os.windows;
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return null;
    defer dir.close(io);
    // FILE_ID_INFO: the volume serial number and a 128-bit file id, which
    // ReFS needs and NTFS fills the low half of.
    var info: extern struct { volume: u64, file: [16]u8 } = undefined;
    var status: w.IO_STATUS_BLOCK = undefined;
    if (w.ntdll.NtQueryInformationFile(dir.handle, &status, &info, @sizeOf(@TypeOf(info)), .Id) != .SUCCESS) return null;
    return .{ .device = info.volume, .file = std.mem.readInt(u128, &info.file, .little) };
}

extern "kernel32" fn GetVolumePathNameW([*:0]const u16, [*]u16, u32) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetDriveTypeW([*:0]const u16) callconv(.winapi) u32;

test "filesystem types select network and FUSE without misclassifying tmpfs" {
    try std.testing.expectEqual(Kind.fuse, linuxType(0x65735546));
    try std.testing.expectEqual(Kind.network, linuxType(0x6969));
    try std.testing.expectEqual(Kind.network, linuxType(0xff534d42));
    try std.testing.expectEqual(Kind.local, linuxType(0x01021994)); // tmpfs
    try std.testing.expectEqual(Kind.local, named("apfs", true));
    try std.testing.expectEqual(Kind.network, named("nfs", false));
    try std.testing.expectEqual(Kind.fuse, named("osxfuse", true));
}

test "a real scratch filesystem is local on each supported host" {
    if (!(builtin.os.tag.isDarwin() or builtin.os.tag == .linux or builtin.os.tag == .windows or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd or builtin.os.tag == .dragonfly)) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    try std.testing.expectEqual(Kind.local, read(gpa, std.testing.io, root));
}

test "procfs is local while the legacy network filesystem types require polling" {
    try std.testing.expectEqual(Kind.local, linuxType(0x9fa0));
    try std.testing.expectEqual(Kind.network, linuxType(0x564c));
    try std.testing.expectEqual(Kind.network, linuxType(0x6B414653));
}

test "one directory has one identity by every name, and another has its own" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "one/inner");
    try tmp.dir.createDirPath(io, "two");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const one = try std.fs.path.join(gpa, &.{ root, "one" });
    defer gpa.free(one);
    const again = try std.fs.path.join(gpa, &.{ root, "one", "inner", ".." });
    defer gpa.free(again);
    const two = try std.fs.path.join(gpa, &.{ root, "two" });
    defer gpa.free(two);
    const missing = try std.fs.path.join(gpa, &.{ root, "missing" });
    defer gpa.free(missing);

    const first = identity(io, one) orelse return error.SkipZigTest;
    try std.testing.expect(first.eql(identity(io, again).?));
    try std.testing.expect(!first.eql(identity(io, two).?));
    try std.testing.expect(identity(io, missing) == null);
}
