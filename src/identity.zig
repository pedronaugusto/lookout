//! Filesystem name capabilities, measured on each root or directory.
//! Unknown facts preserve exact spelling. Matching policy is caller data;
//! node and event keys retain the canonical spelling returned by the kernel.
const std = @import("std");
const builtin = @import("builtin");

pub const Policy = struct {
    case_sensitive: bool = true,
    normalization: Normalization = .exact,
    pub const Normalization = enum { exact, nfc };
};
pub const Capabilities = struct {
    case_sensitive: ?bool = null,
    normalization: ?Policy.Normalization = null,
    pub fn policy(c: Capabilities, explicit: ?Policy) Policy {
        return explicit orelse .{ .case_sensitive = c.case_sensitive orelse true, .normalization = c.normalization orelse .exact };
    }
};

pub fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Capabilities {
    if (builtin.target.os.tag.isDarwin()) {
        const name = gpa.dupeSentinel(u8, path, 0) catch return .{};
        defer gpa.free(name);
        const Attr = extern struct { count: u16 = 5, reserved: u16 = 0, common: u32 = 0, volume: u32 = 0x80020000, directory: u32 = 0, file: u32 = 0, fork: u32 = 0 };
        var attrs: Attr = .{};
        const Result = extern struct { len: u32, capabilities: [4]u32, valid: [4]u32 };
        var result: Result = undefined;
        if (getattrlist(name, &attrs, &result, @sizeOf(Result), 0) != 0 or result.len != @sizeOf(Result)) return .{};
        return .{ .case_sensitive = if (result.valid[0] & 0x100 != 0) result.capabilities[0] & 0x100 != 0 else null };
    }
    if (builtin.target.os.tag == .windows) {
        const measured = directoryPath(io, path);
        const directory = std.Io.Dir.cwd().openDir(io, measured, .{}) catch return .{};
        defer directory.close(io);
        var flags: u32 = undefined;
        if (GetFileInformationByHandleEx(directory.handle, 23, &flags, @sizeOf(u32)) == .FALSE) return .{};
        return .{ .case_sensitive = flags & 1 != 0, .normalization = .exact };
    }
    if (builtin.target.os.tag == .linux) {
        const name = gpa.dupeSentinel(u8, path, 0) catch return .{};
        defer gpa.free(name);
        var storage: [256]usize = undefined;
        const rc = std.os.linux.syscall2(.statfs, @intFromPtr(name.ptr), @intFromPtr(&storage)); // safe: the syscall borrows the terminated name and aligned writable statfs buffer
        if (std.os.linux.errno(rc) != .SUCCESS) return .{};
        switch (storage[0]) {
            0xef53, 0xf2f52010 => {
                const dir = std.Io.Dir.cwd().openDir(io, directoryPath(io, path), .{}) catch return .{};
                defer dir.close(io);
                var flags: c_long = 0;
                const request: usize = if (@sizeOf(c_long) == 8) 0x80086601 else 0x80046601;
                const query = std.os.linux.syscall3(.ioctl, @intCast(dir.handle), request, @intFromPtr(&flags)); // safe: GETFLAGS writes one native long into flags while the directory handle is open
                if (std.os.linux.errno(query) != .SUCCESS) return .{};
                return .{ .case_sensitive = flags & 0x40000000 == 0, .normalization = if (flags & 0x40000000 == 0) .exact else null };
            },
            // A filesystem type alone does not establish its naming flags.
            else => return .{},
        }
    }
    return .{};
}
extern "c" fn getattrlist([*:0]const u8, *const anyopaque, *anyopaque, usize, c_ulong) c_int;
extern "kernel32" fn GetFileInformationByHandleEx(std.os.windows.HANDLE, c_int, *anyopaque, u32) callconv(.winapi) std.os.windows.BOOL;

test "unknown filesystem facts keep exact policy and explicit override independent" {
    const unknown: Capabilities = .{};
    try std.testing.expectEqual(Policy{}, unknown.policy(null));
    try std.testing.expectEqual(Policy{ .case_sensitive = false, .normalization = .nfc }, unknown.policy(.{ .case_sensitive = false, .normalization = .nfc }));
    try std.testing.expectEqual(@as(?bool, null), unknown.case_sensitive);
}

pub const CanonicalError = std.Io.Dir.RealPathFileAllocError;
/// Resolve links and obtain the kernel spelling, without Unicode rewriting.
pub fn canonical(gpa: std.mem.Allocator, io: std.Io, requested: []const u8) CanonicalError![]u8 {
    const real = try std.Io.Dir.cwd().realPathFileAlloc(io, requested, gpa);
    defer gpa.free(real);
    if (builtin.target.os.tag.isDarwin()) {
        const file = std.Io.Dir.cwd().openFile(io, real, .{}) catch return gpa.dupe(u8, real);
        defer file.close(io);
        var buffer: [std.Io.Dir.max_path_bytes]u8 = @splat(0);
        if (fcntl(file.handle, 50, &buffer) != 0) return gpa.dupe(u8, real); // F_GETPATH
        const spelling = std.mem.sliceTo(&buffer, 0);
        return gpa.dupe(u8, spelling);
    }
    return gpa.dupe(u8, real);
}
extern "c" fn fcntl(c_int, c_int, ...) c_int;

fn directoryPath(io: std.Io, path: []const u8) []const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return path;
    return if (stat.kind == .directory) path else std.Io.Dir.path.dirname(path) orelse path;
}
