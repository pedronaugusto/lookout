//! The volume a device-relative stream uses: stable identity, current device
//! number and the prefix translating its paths into the caller's namespace.

const std = @import("std");
const format = @import("../../Checkpoint/format.zig");
const path = @import("../../path.zig");
const Volume = @This();

device: i32,
prefix: []u8,
identity: ?format.Identity,

pub fn read(gpa: std.mem.Allocator, root: []const u8) !Volume {
    const name = try gpa.dupeZ(u8, root);
    defer gpa.free(name);
    var attrs: AttrList = .{ .common = 0x2, .volume = 0x80001000 }; // DEVID, VOL_INFO | MOUNTPOINT
    var mount: Mount = undefined;
    if (getattrlist(name, &attrs, &mount, @sizeOf(Mount), 0) != 0) return error.Unexpected;
    const start: usize = @intCast(@as(i64, @offsetOf(Mount, "offset")) + mount.offset);
    if (mount.path_len == 0 or start + mount.path_len > @sizeOf(Mount)) return error.Unexpected;
    const mounted = std.mem.asBytes(&mount)[start..][0 .. mount.path_len - 1];
    // APFS's Data volume is also visible through firmlinks in the root
    // namespace. FSEvents still names those entries relative to that volume.
    const prefix = if (path.within(mounted, root)) mounted else if (std.mem.eql(u8, mounted, "/System/Volumes/Data")) "/" else return error.Unexpected;
    return .{ .device = mount.device, .prefix = try gpa.dupe(u8, prefix), .identity = readIdentity(name, mount.device) };
}

pub fn deinit(v: *Volume, gpa: std.mem.Allocator) void {
    gpa.free(v.prefix);
    v.* = undefined;
}

pub fn relative(v: Volume, absolute: []const u8) []const u8 {
    const tail = absolute[v.prefix.len..];
    return std.mem.trimStart(u8, tail, "/");
}

pub fn readIdentity(name: [*:0]const u8, device: i32) ?format.Identity {
    var attrs: AttrList = .{ .volume = 0x80040000 }; // VOL_INFO | UUID
    var volume: extern struct { len: u32, uuid: [16]u8 } = undefined;
    if (getattrlist(name, &attrs, &volume, @sizeOf(@TypeOf(volume)), 0) != 0) return null;
    const log = FSEventsCopyUUIDForDevice(device) orelse return null;
    defer CFRelease(log);
    return .{ .volume = std.fmt.bytesToHex(volume.uuid, .lower), .log = std.fmt.bytesToHex(CFUUIDGetUUIDBytes(log).bytes, .lower) };
}

pub fn deviceOf(name: [*:0]const u8) ?i32 {
    var attrs: AttrList = .{ .common = 0x2 }; // DEVID
    var result: extern struct { len: u32, device: i32 } = undefined;
    if (getattrlist(name, &attrs, &result, @sizeOf(@TypeOf(result)), 0) != 0) return null;
    return result.device;
}

pub fn matches(a: format.Identity, b: format.Identity) bool {
    return std.mem.eql(u8, &a.volume, &b.volume) and std.mem.eql(u8, &a.log, &b.log);
}

const AttrList = extern struct {
    count: u16 = 5,
    reserved: u16 = 0,
    common: u32 = 0,
    volume: u32 = 0,
    directory: u32 = 0,
    file: u32 = 0,
    fork: u32 = 0,
};
const Mount = extern struct {
    len: u32,
    device: i32,
    offset: i32,
    path_len: u32,
    storage: [1024]u8,
};
extern "c" fn getattrlist([*:0]const u8, *AttrList, *anyopaque, usize, c_ulong) c_int;
extern "c" fn FSEventsCopyUUIDForDevice(i32) ?*anyopaque;
extern "c" fn CFUUIDGetUUIDBytes(*anyopaque) extern struct { bytes: [16]u8 };
extern "c" fn CFRelease(*anyopaque) void;
