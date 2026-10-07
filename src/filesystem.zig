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
    if (builtin.target.os.tag == .windows) return readWindows(gpa, io, path);
    if (builtin.target.os.tag == .dragonfly) {
        const name = gpa.dupeSentinel(u8, path, 0) catch return .unknown;
        defer gpa.free(name);
        var stat: DragonflyStatfs = undefined;
        if (dragonfly.statfs(name, &stat) != 0) return .unknown;
        return named(std.mem.sliceTo(&stat.name, 0), stat.flags & 0x1000 != 0);
    }
    if (builtin.target.os.tag == .linux) {
        const name = gpa.dupeSentinel(u8, path, 0) catch return .unknown;
        defer gpa.free(name);
        // statfs writes a native-word structure; its first word is f_type.
        // This storage exceeds every Linux ABI's statfs structure.
        var storage: [64]usize = undefined;
        const rc = std.os.linux.syscall2(.statfs, @intFromPtr(name.ptr), @intFromPtr(&storage)); // safe: the syscall borrows the terminated name and writable aligned statfs storage
        if (std.os.linux.errno(rc) != .SUCCESS) return .unknown;
        return linuxType(storage[0]);
    }
    if (mount != void) {
        const name = gpa.dupeSentinel(u8, path, 0) catch return .unknown;
        defer gpa.free(name);
        var stat: mount.Stat = undefined;
        if (mount.stat(name, &stat) != 0) return .unknown;
        return named(std.mem.sliceTo(&stat.type_name, 0), stat.flags & mount.local != 0);
    }
    return .unknown;
}

/// The BSD mount query, declared by hand: lookout compiles no C, and std
/// declares none of it. Each `Stat` is the system header's structure field
/// for field, under shorter names for the two fields read.
const mount = switch (builtin.target.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => struct {
        /// `struct statfs` with 64-bit inodes, the only layout on arm64.
        const Stat = extern struct {
            block_size: u32,
            io_size: i32,
            counts: [5]u64,
            fsid: [2]i32,
            owner: u32,
            type: u32,
            flags: u32,
            subtype: u32,
            type_name: [16]u8,
            mounted_on: [1024]u8,
            mounted_from: [1024]u8,
            flags_ext: u32,
            reserved: [7]u32,
        };
        const local = 0x1000; // MNT_LOCAL
        // x86_64 keeps the 32-bit inode layout under the plain name.
        const stat = if (builtin.target.cpu.arch == .x86_64) externs.@"statfs$INODE64" else externs.statfs;
        const externs = struct {
            extern "c" fn statfs(path: [*:0]const u8, buf: *Stat) c_int;
            extern "c" fn @"statfs$INODE64"(path: [*:0]const u8, buf: *Stat) c_int;
        };
    },
    .freebsd => struct {
        /// `struct statfs` as of STATFS_VERSION 0x20140518.
        const Stat = extern struct {
            version: u32,
            type: u32,
            flags: u64,
            sizes: [2]u64,
            counts: [5]u64,
            io_counts: [4]u64,
            vnodes: u32,
            spare0: u32,
            spare: [9]u64,
            name_max: u32,
            owner: u32,
            fsid: [2]i32,
            char_spare: [80]u8,
            type_name: [16]u8,
            mounted_from: [1024]u8,
            mounted_on: [1024]u8,
        };
        const local = 0x1000; // MNT_LOCAL
        const stat = externs.statfs;
        const externs = struct {
            extern "c" fn statfs(path: [*:0]const u8, buf: *Stat) c_int;
        };
    },
    .openbsd => struct {
        const Stat = extern struct {
            flags: u32,
            block_size: u32,
            io_size: u32,
            counts: [6]u64,
            io_counts: [4]u64,
            fsid: [2]i32,
            name_max: u32,
            owner: u32,
            ctime: u64,
            type_name: [16]u8,
            mounted_on: [90]u8,
            mounted_from: [90]u8,
            mounted_spec: [90]u8,
            /// `union mount_info`, whose largest member is its 160-byte
            /// `__align`.
            mount_info: extern union { bytes: [160]u8, alignment: u64 },
        };
        const local = 0x1000; // MNT_LOCAL
        const stat = externs.statfs;
        const externs = struct {
            extern "c" fn statfs(path: [*:0]const u8, buf: *Stat) c_int;
        };
    },
    .netbsd => struct {
        /// `struct statvfs` of NetBSD 10, the one `__statvfs90` fills.
        const Stat = extern struct {
            flags: c_ulong,
            sizes: [3]c_ulong,
            counts: [8]u64,
            io_counts: [4]u64,
            fsidx: [2]i32,
            fsid: c_ulong,
            name_max: c_ulong,
            owner: u32,
            spare: [4]u64,
            type_name: [32]u8,
            mounted_on: [1024]u8,
            mounted_from: [1024]u8,
            mounted_label: [1024]u8,
        };
        const local = 0x1000; // ST_LOCAL
        // The header renames statvfs; the plain name is the old ABI.
        const stat = externs.__statvfs90;
        const externs = struct {
            extern "c" fn __statvfs90(path: [*:0]const u8, buf: *Stat) c_int;
        };
    },
    else => void,
};

fn linuxType(number: usize) Kind {
    return switch (number) {
        0x65735546 => .fuse,
        0x6969, 0x517B, 0xff534d42, 0xfe534d42, 0x73757245, 0x5346414f, 0x6B414653, 0x564c, 0x01021997 => .network,
        else => .local,
    };
}

fn named(name: []const u8, local: bool) Kind {
    if (std.mem.find(u8, name, "fuse") != null or std.mem.find(u8, name, "puffs") != null) return .fuse;
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
    if (!(builtin.target.os.tag.isDarwin() or builtin.target.os.tag == .linux or builtin.target.os.tag == .windows or builtin.target.os.tag == .freebsd or builtin.target.os.tag == .netbsd or builtin.target.os.tag == .openbsd or builtin.target.os.tag == .dragonfly)) return error.SkipZigTest;
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
