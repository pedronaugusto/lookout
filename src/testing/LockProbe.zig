//! An allocator that counts the calls made while a spin lock is held.
//!
//! The system's delivery thread waits on the lock it shares with `poll`,
//! and an allocation is not a bounded section. shakedown's allocators
//! count and fail calls and have no way to look at anything else when one
//! is made, so the probe is the one allocator double the tests spell
//! themselves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const LockProbe = @This();

child: Allocator,
lock: *const std.atomic.Value(bool),
calls: usize = 0,
under_lock: usize = 0,

pub fn allocator(p: *LockProbe) Allocator {
    return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

fn of(ptr: *anyopaque) *LockProbe {
    return @ptrCast(@alignCast(ptr)); // safe: the vtable is only ever paired with a *LockProbe
}

fn note(p: *LockProbe) void {
    p.calls += 1;
    if (p.lock.load(.acquire)) p.under_lock += 1;
}

fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    of(ptr).note();
    return of(ptr).child.rawAlloc(len, alignment, ret_addr);
}

fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    of(ptr).note();
    return of(ptr).child.rawResize(memory, alignment, new_len, ret_addr);
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    of(ptr).note();
    return of(ptr).child.rawRemap(memory, alignment, new_len, ret_addr);
}

fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    of(ptr).note();
    of(ptr).child.rawFree(memory, alignment, ret_addr);
}
