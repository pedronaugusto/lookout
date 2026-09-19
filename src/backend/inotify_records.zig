//! The bytes one `inotify` read brings back, decoded.
//!
//! The kernel writes a run of `struct inotify_event` back to back: a
//! fixed header of four numbers and then `len` bytes of name, NUL-padded
//! to an alignment the header does not state. How many records one read
//! holds is however many fitted, so reading them is a walk and not an
//! indexing.
//!
//! It lives in a file of its own, compiled on every target rather than
//! only on Linux, because a walk over bytes somebody else wrote is a
//! parser. It is fuzzed in src/test_fuzz.zig, and a decoder that exists
//! only on Linux can only be fuzzed there.

const std = @import("std");
const builtin = @import("builtin");

/// `wd`, `mask`, `cookie` and `len`, in the kernel's own byte order. The
/// name follows.
pub const header_len = 16;

/// One kernel event.
pub const Record = struct {
    /// The kernel watch descriptor the event arrived on.
    wd: i32,
    /// Which of the `IN_*` bits the kernel set.
    mask: u32,
    /// What pairs the two halves of a move. Zero for everything else.
    cookie: u32,
    /// The entry's name, a slice of the buffer the record was read from
    /// with the padding taken off, or `null` for an event about the
    /// watched path itself.
    name: ?[]const u8,
};

pub const Error = error{
    /// The read ends part-way through a record. The kernel does not
    /// return one of these, and a decoder that trusted it to would read
    /// past the end of the read.
    TruncatedRecord,
};

/// Walks the records of one read.
pub const Iterator = struct {
    bytes: []const u8,
    offset: usize,

    /// The next record, or `null` at the end of the read.
    pub fn next(it: *Iterator) Error!?Record {
        const rest = it.bytes[it.offset..];
        if (rest.len == 0) return null;
        if (rest.len < header_len) return error.TruncatedRecord;

        const endian = builtin.cpu.arch.endian();
        const len = std.mem.readInt(u32, rest[12..16], endian);
        if (len > rest.len - header_len) return error.TruncatedRecord;

        const padded = rest[header_len..][0..len];
        it.offset += header_len + len;
        const name = std.mem.sliceTo(padded, 0);
        return .{
            .wd = std.mem.readInt(i32, rest[0..4], endian),
            .mask = std.mem.readInt(u32, rest[4..8], endian),
            .cookie = std.mem.readInt(u32, rest[8..12], endian),
            .name = if (name.len == 0) null else name,
        };
    }
};

pub fn iterate(bytes: []const u8) Iterator {
    return .{ .bytes = bytes, .offset = 0 };
}

/// Writes one record the way the kernel writes it, and answers how many
/// bytes that took. The inverse of `Iterator.next`, for the tests below
/// and for the corpus the fuzz target starts from.
pub fn encode(out: []u8, record: Record) usize {
    const name = record.name orelse "";
    const endian = builtin.cpu.arch.endian();
    std.mem.writeInt(i32, out[0..4], record.wd, endian);
    std.mem.writeInt(u32, out[4..8], record.mask, endian);
    std.mem.writeInt(u32, out[8..12], record.cookie, endian);
    std.mem.writeInt(u32, out[12..16], @intCast(name.len), endian);
    @memcpy(out[header_len..][0..name.len], name);
    return header_len + name.len;
}

const testing = std.testing;

test "two records in one read" {
    var buffer: [128]u8 = undefined;
    var len: usize = 0;
    len += encode(buffer[len..], .{ .wd = 3, .mask = 0x100, .cookie = 0, .name = "one.txt\x00" });
    len += encode(buffer[len..], .{ .wd = 4, .mask = 0x200, .cookie = 7, .name = "two.txt\x00\x00\x00\x00\x00" });

    var it = iterate(buffer[0..len]);
    const first = (try it.next()).?;
    try testing.expectEqual(@as(i32, 3), first.wd);
    try testing.expectEqualStrings("one.txt", first.name.?);
    const second = (try it.next()).?;
    try testing.expectEqual(@as(u32, 7), second.cookie);
    try testing.expectEqualStrings("two.txt", second.name.?);
    try testing.expectEqual(@as(?Record, null), try it.next());
}

test "an event about the watched path itself names nothing" {
    var buffer: [64]u8 = undefined;
    const len = encode(&buffer, .{ .wd = 1, .mask = 0x400, .cookie = 0, .name = null });

    var it = iterate(buffer[0..len]);
    const record = (try it.next()).?;
    try testing.expectEqual(@as(?[]const u8, null), record.name);
}

test "a name that runs past the end of the read is a named error" {
    var buffer: [64]u8 = undefined;
    const len = encode(&buffer, .{ .wd = 1, .mask = 0x100, .cookie = 0, .name = "notes.txt" });

    var it = iterate(buffer[0 .. len - 3]);
    try testing.expectError(error.TruncatedRecord, it.next());
}

test "a read that ends part-way through a header is a named error" {
    var buffer: [64]u8 = undefined;
    _ = encode(&buffer, .{ .wd = 1, .mask = 0x100, .cookie = 0, .name = "a" });

    var it = iterate(buffer[0 .. header_len - 1]);
    try testing.expectError(error.TruncatedRecord, it.next());
}
