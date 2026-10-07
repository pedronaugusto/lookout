//! What one FSEvents delivery says, and which of its records are the
//! two halves of one rename.
//!
//! The system hands a delivery to a thread lookout does not own, which
//! may not allocate and may not run lookout's logic, so it copies each
//! path and its flags into a flat buffer -- `fsevents.Sink` -- and the
//! polling thread reads the buffer back. Both ends of that are here:
//! `encode` writes a record, `Iterator` walks them, and `partnerOf`
//! answers which two of them are one rename.
//!
//! It lives in a file of its own, compiled on every target rather than
//! only on Apple ones, because a walk over bytes and a matching over
//! records are both parsers. They are fuzzed in src/testing/fuzz_test.zig, and
//! a decoder that exists only on macOS can only be fuzzed there.

const std = @import("std");
const assert = std.debug.assert;

const lookout = @import("../../types.zig");
const path_cmp = @import("../../path.zig");
const Target = lookout.Target;
const WatchId = lookout.WatchId;

/// The flags FSEvents sets on a record.
///
/// Apple spells these `kFSEventStreamEventFlagItemRenamed` and so on;
/// the values are the ones in `FSEvents.h`. They are not a sequence of
/// things that happened: the system keeps them per path and does not
/// clear them, so a file created an hour ago and written now still
/// arrives with `item_created` set beside `item_modified`.
pub const flag = struct {
    pub const must_scan_sub_dirs: u32 = 0x0000_0001;
    pub const user_dropped: u32 = 0x0000_0002;
    pub const kernel_dropped: u32 = 0x0000_0004;
    pub const history_done: u32 = 0x0000_0010;
    pub const mount: u32 = 0x0000_0040;
    pub const root_changed: u32 = 0x0000_0020;
    pub const item_created: u32 = 0x0000_0100;
    pub const item_removed: u32 = 0x0000_0200;
    pub const item_inode_meta_mod: u32 = 0x0000_0400;
    pub const item_renamed: u32 = 0x0000_0800;
    pub const item_modified: u32 = 0x0000_1000;
    pub const item_finder_info_mod: u32 = 0x0000_2000;
    pub const item_change_owner: u32 = 0x0000_4000;
    pub const item_xattr_mod: u32 = 0x0000_8000;
    pub const item_is_dir: u32 = 0x0002_0000;
};

/// Watch id, flags, path length and the system's event id. The path
/// follows. Read back with unaligned loads, because the path lengths do
/// not align.
pub const header_len = 20;

comptime {
    // The id, the flags and the path length are 32 bits, the event 64.
    assert(header_len == 3 * @sizeOf(u32) + @sizeOf(u64));
}

/// One delivered change.
pub const Record = struct {
    id: WatchId,
    flags: u32,
    /// The system's own number for this change.
    event: u64,
    /// Absolute path, a slice of the buffer the record was read from.
    path: []const u8,

    pub fn target(r: Record) Target {
        return if (r.flags & flag.item_is_dir != 0) .directory else .file;
    }

    pub fn renamed(r: Record) bool {
        return r.flags & flag.item_renamed != 0;
    }
};

pub const Error = error{
    /// The buffer ends part-way through a record: a delivery the
    /// polling thread read while the delivery thread was still writing
    /// it, or a path whose length outlives its bytes.
    TruncatedRecord,
};

/// Walks the records of one drained buffer.
pub const Iterator = struct {
    bytes: []const u8,
    offset: usize,

    /// The next record, or `null` at the end of the buffer.
    pub fn next(it: *Iterator) Error!?Record {
        const rest = it.bytes[it.offset..];
        if (rest.len == 0) return null;
        if (rest.len < header_len) return error.TruncatedRecord;

        const len = std.mem.readInt(u32, rest[8..12], .little);
        if (len > rest.len - header_len) return error.TruncatedRecord;

        it.offset += header_len + len;
        assert(it.offset <= it.bytes.len);
        return .{
            .id = @fromBackingInt(@intCast(std.mem.readInt(u32, rest[0..4], .little))),
            .flags = std.mem.readInt(u32, rest[4..8], .little),
            .event = std.mem.readInt(u64, rest[12..20], .little),
            .path = rest[header_len..][0..len],
        };
    }
};

pub fn iterate(bytes: []const u8) Iterator {
    return .{ .bytes = bytes, .offset = 0 };
}

/// How many bytes `encode` needs for `path`.
pub fn encodedLen(path: []const u8) usize {
    return header_len + path.len;
}

/// Writes one record into `out`, which must hold `encodedLen(path)`
/// bytes. Called from the system's delivery thread, so it allocates
/// nothing and can fail in no way.
pub fn encode(out: []u8, id: WatchId, flags: u32, event: u64, path: []const u8) usize {
    assert(out.len >= encodedLen(path));
    encodeHeader(out, id, flags, event, path.len);
    @memcpy(out[header_len..][0..path.len], path);
    return encodedLen(path);
}

/// Encodes a volume-relative path with its absolute mount prefix. Both
/// pieces are borrowed and the output is written once, without allocating.
pub fn encodeVolumePath(out: []u8, id: WatchId, flags: u32, event: u64, prefix: []const u8, relative: []const u8) usize {
    const separator: usize = @intFromBool(relative.len != 0 or prefix.len == 0);
    const length = encodedVolumePathLen(prefix, relative);
    assert(out.len >= length);
    encodeHeader(out, id, flags, event, length - header_len);
    @memcpy(out[header_len..][0..prefix.len], prefix);
    if (separator != 0) out[header_len + prefix.len] = '/';
    @memcpy(out[header_len + prefix.len + separator ..][0..relative.len], relative);
    return length;
}

/// The complete record length, including the separator only where needed.
pub fn encodedVolumePathLen(prefix: []const u8, relative: []const u8) usize {
    return header_len + prefix.len + relative.len + @intFromBool(relative.len != 0 or prefix.len == 0);
}

fn encodeHeader(out: []u8, id: WatchId, flags: u32, event: u64, length: usize) void {
    // `Iterator.next` reads the length back as 32 bits.
    assert(length <= std.math.maxInt(u32));
    std.mem.writeInt(u32, out[0..4], @backingInt(id), .little);
    std.mem.writeInt(u32, out[4..8], flags, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(length), .little);
    std.mem.writeInt(u64, out[12..20], event, .little);
}

/// Whether `a` and `b` are the two halves of one rename.
///
/// A rename arrives as two `item_renamed` records naming one inode at
/// two paths, and exactly one of the two resolves: the inode moved, so
/// the name it came from is not there and the name it went to is. When
/// both resolve or neither does -- the file was renamed and then
/// deleted, or renamed in from outside the watch -- the two are not a
/// pair and neither is guessed at.
///
/// `ctx` answers two questions about a path: `wanted(id, path)`,
/// whether it is inside that watch's scope, and `exists(path)`, whether
/// the file system has it now. Scope and not the watch's filter: a name
/// the filter excludes is still the other half of a rename, and which
/// half the caller hears about is decided on the pair.
///
/// Symmetric: every test it makes is made of both records.
pub fn pairs(a: Record, b: Record, ctx: anytype) bool {
    return pairsKnowing(a, ctx.exists(a.path), b, ctx);
}

/// `pairs`, for a caller that already knows whether `a` is there.
///
/// The answer costs a `stat`, and `partnerOf` asks it of one record
/// against many.
fn pairsKnowing(a: Record, a_exists: ?bool, b: Record, ctx: anytype) bool {
    if (a.id != b.id) return false;
    if (!a.renamed() or !b.renamed()) return false;
    if (path_cmp.eql(a.path, b.path)) return false;
    if (!ctx.wanted(a.id, a.path) or !ctx.wanted(b.id, b.path)) return false;
    const there = a_exists orelse return false;
    const other: ?bool = ctx.exists(b.path);
    return (other orelse return false) != there;
}

/// Where in `records` the other half of `subject` is, at or after
/// `from`, if it is there at all.
///
/// Anywhere in the delivery and not only next door: FSEvents can name
/// the directory the two names are in between them.
pub fn partnerOf(
    subject: Record,
    records: []const Record,
    used: []const bool,
    from: usize,
    ctx: anytype,
) ?usize {
    assert(used.len == records.len);
    assert(from <= records.len);
    const subject_exists = ctx.exists(subject.path);
    for (records[from..], from..) |record, at| {
        if (used[at]) continue;
        if (pairsKnowing(subject, subject_exists, record, ctx)) return at;
    }
    return null;
}

/// The half of a rename that carries from one delivery to the next.
pub const Half = struct {
    id: WatchId,
    /// Absolute path. `Pairing` does not own it: the buffer the half
    /// was read from is emptied before its partner arrives, so the
    /// caller keeps a copy of its own and frees it when the half comes
    /// back.
    path: []u8,
    flags: u32,
    event: u64,

    pub fn record(h: Half) Record {
        return .{ .id = h.id, .flags = h.flags, .event = h.event, .path = h.path };
    }
};

/// The one rename half a delivery may leave behind.
///
/// FSEvents puts both halves in one delivery, but "one delivery" is
/// about the system's queue and not about the buffer lookout reads it
/// into: a burst long enough splits a pair across two. Deciding at the
/// end of a delivery turns one `renamed` into a removal and a creation
/// on a backend that says it pairs them, so the decision waits.
pub const Pairing = struct {
    /// What the last delivery left, if it left anything.
    held: ?Half = null,

    /// A half taken back, and where its partner was.
    pub const Taken = struct {
        half: Half,
        /// Where in the delivery the partner was, or `null` when it was
        /// not there at all: the path was renamed out of the watch, or
        /// renamed and then deleted, and the half is on its own.
        partner: ?usize,
    };

    /// Takes the held half back, with the partner this delivery brought
    /// for it, and strikes that partner off. `null` when nothing was
    /// held.
    ///
    /// The half comes back either way, because the caller has it to
    /// report and its path to free.
    pub fn take(p: *Pairing, records: []const Record, used: []bool, ctx: anytype) ?Taken {
        const half = p.held orelse return null;
        p.held = null;
        const at = partnerOf(half.record(), records, used, 0, ctx) orelse
            return .{ .half = half, .partner = null };
        used[at] = true;
        return .{ .half = half, .partner = at };
    }

    /// Carries `half` to the next delivery, and gives back whatever was
    /// already carried -- which has waited as long as it is going to.
    pub fn carry(p: *Pairing, half: Half) ?Half {
        const stale = p.held;
        p.held = half;
        return stale;
    }
};

const testing = std.testing;

/// A file system and a scope, answered from a list.
const Fake = struct {
    present: []const []const u8,

    fn wanted(_: Fake, _: WatchId, subject: []const u8) bool {
        return !std.mem.startsWith(u8, subject, "!");
    }

    fn exists(f: Fake, subject: []const u8) bool {
        for (f.present) |p| if (std.mem.eql(u8, p, subject)) return true;
        return false;
    }
};

fn made(id: u32, flags: u32, path: []const u8) Record {
    return .{ .id = @fromBackingInt(@intCast(id)), .flags = flags, .event = 0, .path = path };
}

test "a buffer of two records" {
    var buffer: [256]u8 = undefined;
    var len: usize = 0;
    len += encode(buffer[len..], @fromBackingInt(@intCast(1)), flag.item_created, 9, "/a/one");
    len += encode(buffer[len..], @fromBackingInt(@intCast(2)), flag.item_is_dir, 10, "/a/two");

    var it = iterate(buffer[0..len]);
    const first = (try it.next()).?;
    try testing.expectEqual(@as(u64, 9), first.event);
    try testing.expectEqualStrings("/a/one", first.path);
    try testing.expectEqual(Target.file, first.target());
    const second = (try it.next()).?;
    try testing.expectEqual(Target.directory, second.target());
    try testing.expectEqual(@as(?Record, null), try it.next());
}

test "a path that runs past the end of the buffer is a named error" {
    var buffer: [256]u8 = undefined;
    const len = encode(&buffer, @fromBackingInt(@intCast(1)), 0, 0, "/a/one");

    var it = iterate(buffer[0 .. len - 2]);
    try testing.expectError(error.TruncatedRecord, it.next());
}

test "the halves of a rename are the two that disagree about existing" {
    const fake: Fake = .{ .present = &.{"/a/new"} };
    const old = made(1, flag.item_renamed, "/a/old");
    const new = made(1, flag.item_renamed, "/a/new");

    try testing.expect(pairs(old, new, fake));
    try testing.expect(pairs(new, old, fake));

    // Both gone: renamed and then deleted, and there is nothing to pair.
    const gone = made(1, flag.item_renamed, "/a/gone");
    try testing.expect(!pairs(old, gone, fake));
    // A different watch's record is not this watch's other half.
    try testing.expect(!pairs(made(2, flag.item_renamed, "/a/new"), old, fake));
    // Neither is a record that is not a rename at all.
    try testing.expect(!pairs(made(1, flag.item_created, "/a/new"), old, fake));
}

test "a half waits for the delivery that brings its partner" {
    const fake: Fake = .{ .present = &.{"/a/new"} };
    var pairing: Pairing = .{};

    var old: [6]u8 = "/a/old".*;
    try testing.expectEqual(@as(?Half, null), pairing.carry(.{
        .id = @fromBackingInt(@intCast(1)),
        .path = &old,
        .flags = flag.item_renamed,
        .event = 1,
    }));

    const records: []const Record = &.{made(1, flag.item_renamed, "/a/new")};
    var used = [_]bool{false};
    const taken = pairing.take(records, &used, fake).?;
    try testing.expectEqual(@as(?usize, 0), taken.partner);
    try testing.expect(used[0]);
    try testing.expectEqual(@as(?Half, null), pairing.held);
    try testing.expectEqual(@as(?Pairing.Taken, null), pairing.take(records, &used, fake));
}

test "a half whose partner never comes is given back alone" {
    const fake: Fake = .{ .present = &.{} };
    var pairing: Pairing = .{};

    var old: [6]u8 = "/a/old".*;
    _ = pairing.carry(.{ .id = @fromBackingInt(@intCast(1)), .path = &old, .flags = flag.item_renamed, .event = 1 });

    const records: []const Record = &.{made(1, flag.item_modified, "/a/other")};
    var used = [_]bool{false};
    const taken = pairing.take(records, &used, fake).?;
    try testing.expectEqual(@as(?usize, null), taken.partner);
    try testing.expectEqualStrings("/a/old", taken.half.path);
}

test "volume-relative records retain their absolute namespace and event identity" {
    var bytes: [256]u8 = undefined;
    const id: WatchId = @fromBackingInt(@intCast(7));
    for ([_]struct { prefix: []const u8, tail: []const u8, absolute: []const u8 }{
        .{ .prefix = "", .tail = "Users/watch/file", .absolute = "/Users/watch/file" },
        .{ .prefix = "/Volumes/Data", .tail = "watch/file", .absolute = "/Volumes/Data/watch/file" },
        .{ .prefix = "/Volumes/Data", .tail = "", .absolute = "/Volumes/Data" },
    }) |case| {
        const len = encodeVolumePath(&bytes, id, flag.item_modified, 42, case.prefix, case.tail);
        var it = iterate(bytes[0..len]);
        const record = (try it.next()).?;
        try std.testing.expectEqualStrings(case.absolute, record.path);
        try std.testing.expectEqual(id, record.id);
        try std.testing.expectEqual(@as(u64, 42), record.event);
        try std.testing.expectEqual(flag.item_modified, record.flags);
        try std.testing.expectEqual(@as(?Record, null), try it.next());
    }
}

test "volume-root records preserve the canonical root spelling" {
    var bytes: [128]u8 = undefined;
    const id: WatchId = @fromBackingInt(@intCast(0));
    for ([_][]const u8{ "", "/Volumes/Data" }) |prefix| {
        const len = encodeVolumePath(&bytes, id, flag.item_created, 1, prefix, "");
        var it = iterate(bytes[0..len]);
        try std.testing.expectEqualStrings(if (prefix.len == 0) "/" else prefix, (try it.next()).?.path);
    }
}
