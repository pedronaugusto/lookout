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
        0x6969, 0x517B, 0xff534d42, 0xfe534d42, 0x73757245, 0x5346414f, 0x9fa0, 0x01021997 => .network,
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
