//! Sizing the buffer a delivery is copied into.
//!
//! Two backends hand the operating system a buffer and are told what
//! changed by finding records in it: `ReadDirectoryChangesW` writes into
//! one per watch, and the FSEvents delivery thread appends to one per
//! watcher. Both have the same shape of problem -- the buffer is how
//! much change can accumulate while nothing is draining it, and a full
//! one costs `lookout.Kind.overflow` and a rescan -- and both take the
//! size from an option.
//!
//! What the two ends of the range mean differs per backend, so each
//! passes its own `Bounds`. The rounding and the clamping are the same,
//! and are here so that they can be tested from any host rather than
//! only from the one platform that reaches them.

const std = @import("std");

/// The ends of the range a backend will pass on, and what it uses when
/// the caller asks for nothing.
pub const Bounds = struct {
    /// The smallest size, which must still hold one record with the
    /// longest name the platform allows.
    min: usize,
    /// The largest size, past which the request is a mistake rather than
    /// a refusal.
    max: usize,
    /// What zero means.
    default: usize,
};

/// The caller's size held inside `bounds` and rounded down to a multiple
/// of four, because both kernels align the records they write to a
/// 32-bit word and measure the buffer in whole ones.
pub fn clamp(asked: usize, bounds: Bounds) usize {
    const bounded = std.math.clamp(
        if (asked == 0) bounds.default else asked,
        bounds.min,
        bounds.max,
    );
    return bounded - bounded % @alignOf(u32);
}

const testing = std.testing;

const example: Bounds = .{ .min = 4 * 1024, .max = 16 * 1024 * 1024, .default = 64 * 1024 };

test "zero is the default, and the default is passed on unchanged" {
    try testing.expectEqual(example.default, clamp(0, example));
    try testing.expectEqual(example.default, clamp(example.default, example));
}

test "a size outside the range is brought to the nearer end" {
    try testing.expectEqual(example.min, clamp(1, example));
    try testing.expectEqual(example.min, clamp(example.min - 1, example));
    try testing.expectEqual(example.max, clamp(example.max + 1, example));
    try testing.expectEqual(example.max, clamp(std.math.maxInt(usize), example));
}

test "a size that is not a whole number of words is rounded down" {
    try testing.expectEqual(@as(usize, 8 * 1024), clamp(8 * 1024 + 3, example));
    try testing.expectEqual(@as(usize, 8 * 1024 + 4), clamp(8 * 1024 + 7, example));
    // Rounding never takes a size below the floor.
    try testing.expect(clamp(example.min + 1, example) >= example.min);
}
