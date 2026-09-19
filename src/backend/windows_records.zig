//! The chain of `FILE_NOTIFY_INFORMATION` one completed read leaves in
//! the buffer, decoded.
//!
//! A record is three numbers and then `FileNameLength` bytes of UTF-16
//! name; `NextEntryOffset` counts from the start of the record to the
//! start of the next one, and zero ends the chain. Nothing in the layout
//! is aligned for the reader: the offset need not be even, so a name is
//! read as bytes and realigned rather than pointed at as `u16`.
//!
//! It lives in a file of its own, compiled on every target rather than
//! only on Windows, because a walk over bytes somebody else wrote is a
//! parser. It is fuzzed in src/test_fuzz.zig, and a decoder that exists
//! only on Windows can only be fuzzed there -- which, for a backend
//! whose host is a CI runner, would be nowhere a change is written.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `NextEntryOffset`, `Action` and `FileNameLength`. The name follows.
pub const header_len = 12;

/// One record of the chain.
pub const Record = struct {
    /// Which of the `FILE_ACTION_*` numbers the kernel used.
    action: u32,
    /// The name, as the kernel wrote it: UTF-16 code units in
    /// little-endian bytes, relative to the watched directory and
    /// already spelled with backslashes. A slice of the buffer, and not
    /// necessarily aligned for `u16`, which is what `wtf8Alloc` is for.
    name: []const u8,

    /// The name as WTF-8, allocated. The copy is what realigns it.
    pub fn wtf8Alloc(r: Record, gpa: Allocator) Allocator.Error![]u8 {
        const units = try gpa.alloc(u16, r.name.len / 2);
        defer gpa.free(units);
        @memcpy(std.mem.sliceAsBytes(units), r.name);
        return std.unicode.wtf16LeToWtf8Alloc(gpa, units);
    }
};

pub const Error = error{
    /// A record, or the name inside one, runs past the end of what the
    /// read transferred.
    TruncatedRecord,
    /// `FileNameLength` is not a whole number of UTF-16 code units, so
    /// the name the record claims to hold cannot be read as one.
    OddNameLength,
    /// `NextEntryOffset` points inside the record it follows rather
    /// than past it, which is a chain with no end to walk to.
    OverlappingRecords,
};

/// Walks the chain.
pub const Iterator = struct {
    bytes: []const u8,
    offset: usize,
    done: bool,

    /// The next record, or `null` at the end of the chain.
    pub fn next(it: *Iterator) Error!?Record {
        if (it.done) return null;
        const rest = it.bytes[it.offset..];
        if (rest.len == 0) return null;
        if (rest.len < header_len) return error.TruncatedRecord;

        const next_offset = std.mem.readInt(u32, rest[0..4], .little);
        const action = std.mem.readInt(u32, rest[4..8], .little);
        const name_len = std.mem.readInt(u32, rest[8..12], .little);
        if (name_len % 2 != 0) return error.OddNameLength;
        if (name_len > rest.len - header_len) return error.TruncatedRecord;

        const record: Record = .{ .action = action, .name = rest[header_len..][0..name_len] };
        if (next_offset == 0) {
            it.done = true;
            return record;
        }
        if (next_offset < header_len + name_len) return error.OverlappingRecords;
        // Equal is short too: the chain says another record starts where
        // the read ends.
        if (next_offset >= rest.len) return error.TruncatedRecord;
        it.offset += next_offset;
        return record;
    }
};

pub fn iterate(bytes: []const u8) Iterator {
    return .{ .bytes = bytes, .offset = 0, .done = false };
}

/// Writes one record the way the kernel writes it, and answers how many
/// bytes that took. The inverse of `Iterator.next`, for the tests below
/// and for the corpus the fuzz target starts from.
///
/// `last` ends the chain, which is what a zero `NextEntryOffset` means.
pub fn encode(out: []u8, action: u32, name: []const u8, last: bool) usize {
    const len = header_len + name.len;
    std.mem.writeInt(u32, out[0..4], if (last) 0 else @intCast(len), .little);
    std.mem.writeInt(u32, out[4..8], action, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(name.len), .little);
    @memcpy(out[header_len..][0..name.len], name);
    return len;
}

const testing = std.testing;

/// "a.txt" and "b.txt" as the kernel spells them.
const a_txt = std.mem.sliceAsBytes(&[_]u16{ 'a', '.', 't', 'x', 't' });
const b_txt = std.mem.sliceAsBytes(&[_]u16{ 'b', '.', 't', 'x', 't' });

test "a chain of two records ends at the zero offset" {
    var buffer: [128]u8 = undefined;
    var len: usize = 0;
    len += encode(buffer[len..], 1, a_txt, false);
    len += encode(buffer[len..], 2, b_txt, true);

    var it = iterate(buffer[0..len]);
    const first = (try it.next()).?;
    try testing.expectEqual(@as(u32, 1), first.action);
    const name = try first.wtf8Alloc(testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("a.txt", name);

    const second = (try it.next()).?;
    try testing.expectEqual(@as(u32, 2), second.action);
    try testing.expectEqual(@as(?Record, null), try it.next());
}

test "a name read from an odd offset is still a name" {
    // `NextEntryOffset` is not required to be even, so the second
    // record's name can start on an odd byte. Reading it as `u16`
    // where it lies is what a decoder must not do.
    var buffer: [128]u8 = undefined;
    std.mem.writeInt(u32, buffer[0..4], header_len + 1, .little);
    std.mem.writeInt(u32, buffer[4..8], 1, .little);
    std.mem.writeInt(u32, buffer[8..12], 0, .little);
    buffer[12] = 0;
    const len = header_len + 1 + encode(buffer[header_len + 1 ..], 2, b_txt, true);

    var it = iterate(buffer[0..len]);
    _ = (try it.next()).?;
    const second = (try it.next()).?;
    const name = try second.wtf8Alloc(testing.allocator);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("b.txt", name);
}

test "a name that runs past the end of the read is a named error" {
    var buffer: [128]u8 = undefined;
    const len = encode(&buffer, 1, a_txt, true);

    var it = iterate(buffer[0 .. len - 2]);
    try testing.expectError(error.TruncatedRecord, it.next());
}

test "half a code unit is a named error" {
    var buffer: [128]u8 = undefined;
    _ = encode(&buffer, 1, a_txt, true);
    std.mem.writeInt(u32, buffer[8..12], 9, .little);

    var it = iterate(buffer[0 .. header_len + 10]);
    try testing.expectError(error.OddNameLength, it.next());
}

test "an offset that points back into the record is a named error" {
    var buffer: [128]u8 = undefined;
    const len = encode(&buffer, 1, a_txt, false);
    std.mem.writeInt(u32, buffer[0..4], 4, .little);

    var it = iterate(buffer[0..len]);
    try testing.expectError(error.OverlappingRecords, it.next());
}

test "an offset that points past the read is a named error" {
    var buffer: [128]u8 = undefined;
    const len = encode(&buffer, 1, a_txt, false);
    std.mem.writeInt(u32, buffer[0..4], 4096, .little);

    var it = iterate(buffer[0..len]);
    try testing.expectError(error.TruncatedRecord, it.next());
}
