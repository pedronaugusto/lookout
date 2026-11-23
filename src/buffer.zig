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
const aegis = @import("aegis");
const assert = aegis.assert.invariant;

/// A size in bytes: the one kind of number a buffer's size is, kept from
/// meeting the counts of events and entries beside it in `Options`.
pub const Bytes = aegis.units.Bytes(usize);

/// What asks for the backend's own size.
const unset: Bytes = .fromRaw(0);

/// The ends of the range a backend will pass on, and what it uses when
/// the caller asks for nothing.
pub const Bounds = struct {
    /// The smallest size the backend accepts. A record larger than the
    /// buffer can still cost an overflow notice and a rescan.
    min: Bytes,
    /// The largest size, past which the request is a mistake rather than
    /// a refusal.
    max: Bytes,
    /// What zero means.
    default: Bytes,
};

/// The caller's size held inside `bounds` and rounded down to a multiple
/// of four, because both kernels align the records they write to a
/// 32-bit word and measure the buffer in whole ones.
pub fn clamp(asked: Bytes, bounds: Bounds) Bytes {
    assert(bounds.min.compare(bounds.default) != .gt, "min <= default");
    assert(bounds.default.compare(bounds.max) != .gt, "default <= max");
    // A whole number of words at the floor, so rounding down never
    // takes a size below it.
    assert(wholeWords(bounds.min).eql(bounds.min), "min is whole words");
    const wanted = if (asked.eql(unset)) bounds.default else asked;
    const bounded = if (wanted.compare(bounds.min) == .lt) bounds.min else if (wanted.compare(bounds.max) == .gt) bounds.max else wanted;
    const size = wholeWords(bounded);
    assert(size.compare(bounds.min) != .lt, "size >= min");
    assert(size.compare(bounds.max) != .gt, "size <= max");
    return size;
}

/// `size` rounded down to a whole number of 32-bit words.
fn wholeWords(size: Bytes) Bytes {
    const word = @alignOf(u32);
    const words = size.divTrunc(word) catch aegis.assert.never("a word is not zero bytes");
    return words.mul(word) catch aegis.assert.never("the whole words of a size are no more than it");
}

const testing = std.testing;

const example: Bounds = .{ .min = .fromRaw(4 * 1024), .max = .fromRaw(16 * 1024 * 1024), .default = .fromRaw(64 * 1024) };

fn bytes(n: usize) Bytes {
    return .fromRaw(n);
}

test "zero is the default, and the default is passed on unchanged" {
    try testing.expectEqual(example.default, clamp(bytes(0), example));
    try testing.expectEqual(example.default, clamp(example.default, example));
}

test "a size outside the range is brought to the nearer end" {
    try testing.expectEqual(example.min, clamp(bytes(1), example));
    try testing.expectEqual(example.min, clamp(try example.min.sub(bytes(1)), example));
    try testing.expectEqual(example.max, clamp(try example.max.add(bytes(1)), example));
    try testing.expectEqual(example.max, clamp(bytes(std.math.maxInt(usize)), example));
}

test "a size that is not a whole number of words is rounded down" {
    try testing.expectEqual(bytes(8 * 1024), clamp(bytes(8 * 1024 + 3), example));
    try testing.expectEqual(bytes(8 * 1024 + 4), clamp(bytes(8 * 1024 + 7), example));
    // Rounding never takes a size below the floor.
    try testing.expect(clamp(try example.min.add(bytes(1)), example).compare(example.min) != .lt);
}
