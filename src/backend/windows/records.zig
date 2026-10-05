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
//! parser. It is fuzzed in src/testing/fuzz_test.zig, and a decoder that exists
//! only on Windows can only be fuzzed there -- which, for a backend
//! whose host is a CI runner, would be nowhere a change is written.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// `NextEntryOffset`, `Action` and `FileNameLength`. The name follows.
pub const header_len = 12;

comptime {
    assert(header_len == 3 * @sizeOf(u32));
}

/// The `FILE_ACTION_*` numbers a record carries, as winnt.h spells them.
pub const Action = struct {
    pub const added: u32 = 1;
    pub const removed: u32 = 2;
    pub const modified: u32 = 3;
    pub const renamed_old_name: u32 = 4;
    pub const renamed_new_name: u32 = 5;
};

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
        // A chain that goes on goes on inside the read.
        assert(it.offset < it.bytes.len);
        return record;
    }
};

pub fn iterate(bytes: []const u8) Iterator {
    return .{ .bytes = bytes, .offset = 0, .done = false };
}

/// What the records after a `removed` say about the name it gave up.
pub const Arrival = union(enum) {
    /// The record that moves an entry onto a name: an `added`, or the
    /// `renamed_new_name` of a rename. Whether that name is the removed
    /// one is the caller's to compare.
    moved: Record,
    /// No move comes next.
    none,
    /// The chain ends before it could say: the removal was its last
    /// record, or an old name was with no new name after it. The rest is
    /// in the next read.
    unsaid,
};

/// What the records `rest` has still to walk say about a removal just
/// before them. See `Arrival`.
///
/// A rename that replaces an entry is written by the kernel as the
/// replaced entry's `removed` and then the rename's own records:
/// `renamed_old_name` and `renamed_new_name` when the entry came from
/// the directory the read is on, `added` alone when it came from another.
/// The rename's records may be in the next read rather than this one, so
/// the same question is asked of a next read from its start, which is
/// why a new name with no old name before it is a move too. `rest` is a
/// copy, so the caller's walk is where it was, and a chain that cannot be
/// followed is no move: the caller's own walk comes to the same fault and
/// says so.
pub fn arrival(rest: Iterator) Arrival {
    var it = rest;
    const first = (it.next() catch return .none) orelse return .unsaid;
    if (first.action == Action.added or first.action == Action.renamed_new_name) {
        return .{ .moved = first };
    }
    if (first.action != Action.renamed_old_name) return .none;
    const second = (it.next() catch return .none) orelse return .unsaid;
    return if (second.action == Action.renamed_new_name) .{ .moved = second } else .none;
}

/// Writes one record the way the kernel writes it, and answers how many
/// bytes that took. The inverse of `Iterator.next`, for the tests below
/// and for the corpus the fuzz target starts from.
///
/// `last` ends the chain, which is what a zero `NextEntryOffset` means.
pub fn encode(out: []u8, action: u32, name: []const u8, last: bool) usize {
    const len = header_len + name.len;
    // A name is UTF-16 code units, which `Iterator.next` insists on.
    assert(out.len >= len);
    assert(name.len % 2 == 0);
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

test "a read that transferred nothing is an empty chain" {
    // What `ReadDirectoryChangesW` leaves when its buffer overflowed:
    // "the entire contents of the buffer are discarded, the
    // lpBytesReturned parameter contains zero". The backend reads the
    // zero as `lookout.Kind.overflow` before it decodes anything; the
    // decoder's part is to make nothing of nothing, not an error.
    var it = iterate(&.{});
    try testing.expectEqual(@as(?Record, null), try it.next());
    try testing.expectEqual(@as(?Record, null), try it.next());
}

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

test "the move that follows a removal is found, and nothing else is" {
    var bytes: [256]u8 align(4) = undefined;
    const Said = std.meta.Tag(Arrival);
    const Case = struct { actions: []const u32, said: Said, arrives: ?u32 = null };
    const cases = [_]Case{
        // Renamed over `a.txt` from `b.txt` in the same directory.
        .{ .actions = &.{ Action.removed, Action.renamed_old_name, Action.renamed_new_name }, .said = .moved, .arrives = Action.renamed_new_name },
        // Moved over `a.txt` from another directory.
        .{ .actions = &.{ Action.removed, Action.added }, .said = .moved, .arrives = Action.added },
        // The new name first, as a next read that the old name did not
        // fit in before begins.
        .{ .actions = &.{ Action.removed, Action.renamed_new_name }, .said = .moved, .arrives = Action.renamed_new_name },
        // A removal and then something else.
        .{ .actions = &.{ Action.removed, Action.modified }, .said = .none },
        .{ .actions = &.{ Action.removed, Action.renamed_old_name, Action.removed }, .said = .none },
        // The chain ends before it says.
        .{ .actions = &.{Action.removed}, .said = .unsaid },
        .{ .actions = &.{ Action.removed, Action.renamed_old_name }, .said = .unsaid },
    };
    for (cases) |case| {
        var len: usize = 0;
        for (case.actions, 0..) |action, i| {
            const name = if (action == Action.renamed_old_name) b_txt else a_txt;
            len += encode(bytes[len..], action, name, i == case.actions.len - 1);
        }
        var it = iterate(bytes[0..len]);
        const removal = (try it.next()).?;
        try testing.expectEqual(Action.removed, removal.action);
        const found = arrival(it);
        try testing.expectEqual(case.said, std.meta.activeTag(found));
        if (found == .moved) {
            try testing.expectEqual(case.arrives.?, found.moved.action);
            try testing.expectEqualSlices(u8, a_txt, found.moved.name);
        }
        // The caller's walk is untouched.
        const after: ?u32 = if (case.actions.len > 1) case.actions[1] else null;
        try testing.expectEqual(after, if (try it.next()) |r| r.action else null);
    }

    // A chain that breaks after the removal is no move.
    var len = encode(&bytes, Action.removed, a_txt, false);
    len += encode(bytes[len..], Action.added, a_txt, false);
    var it = iterate(bytes[0..len]);
    _ = try it.next();
    try testing.expectEqual(Arrival.none, arrival(it));
}
