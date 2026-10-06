//! A lock for critical sections short enough that waiting is cheaper
//! than sleeping, taken from threads that have no `std.Io` to block on.
//!
//! `std.Io.Mutex` needs an `Io`, and a system callback has none. Every
//! section held under one of these is bounded -- a copy, a few pointer
//! updates -- with no syscall, no allocation and no lookout logic inside,
//! so there is nothing to wait through.

const std = @import("std");

const SpinLock = @This();

held: std.atomic.Value(bool) = .init(false),

pub fn acquire(l: *SpinLock) void {
    while (l.held.swap(true, .acquire)) std.atomic.spinLoopHint();
}

pub fn release(l: *SpinLock) void {
    l.held.store(false, .release);
}
