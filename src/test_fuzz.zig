//! Fuzz targets, one per decoder.
//!
//! Three of lookout's backends are handed bytes by the operating system
//! and have to find the changes in them: a run of `struct inotify_event`,
//! a chain of `FILE_NOTIFY_INFORMATION`, and the flags-and-paths buffer
//! the FSEvents delivery thread fills. Walking those is parsing, and the
//! fourth target is the matching that decides which two records of a
//! delivery are the two halves of one rename.
//!
//! Each target holds the same contract: any input yields records or a
//! named error, never a crash and never a read past the end of the
//! input; every name a record carries is a slice of the input it was
//! decoded from; the work and the memory are bounded by the input's
//! length; and a rename pairs symmetrically -- if this record is that
//! one's other half, that one is this one's.
//!
//! The decoders are in files of their own, compiled on every target, so
//! all four run on whatever host is in front of the change. Run them
//! with `zig build test --fuzz`.

const std = @import("std");
const testing = std.testing;

const fsevents_records = @import("backend/fsevents_records.zig");
const inotify_records = @import("backend/inotify_records.zig");
const windows_records = @import("backend/windows_records.zig");
const lookout = @import("lookout.zig");
const WatchId = lookout.WatchId;

/// How much of one read a target builds. Large enough for a run of
/// records and small enough that a failing input is readable.
const buffer_len = 512;

/// Whether `needle` is a slice of `haystack` -- the invariant that a
/// decoded name points into the input and not past it or beside it.
fn inside(haystack: []const u8, needle: []const u8) bool {
    @disableInstrumentation();
    const start = @intFromPtr(haystack.ptr);
    const at = @intFromPtr(needle.ptr);
    return at >= start and at + needle.len <= start + haystack.len;
}

/// Fills `out` with either bytes of the fuzzer's own choosing or a
/// record written the way the kernel writes one, and answers how much
/// of `out` was used.
///
/// Records alone would never reach the error paths and raw bytes alone
/// would almost never reach the decoding, so the two are spliced: a
/// well-formed run with a damaged record in the middle of it is the
/// input that matters.
fn splice(
    smith: *testing.Smith,
    out: []u8,
    room: usize,
    encoder: *const fn (*testing.Smith, []u8) usize,
) usize {
    @disableInstrumentation();
    var len: usize = 0;
    while (!smith.eosWeightedSimple(4, 1)) {
        if (out.len - len < room) break;
        len += if (smith.boolWeighted(1, 3))
            encoder(smith, out[len..])
        else
            smith.slice(out[len..][0..@min(room, out.len - len)]);
    }
    return len;
}

test "the inotify read buffer decodes or says why" {
    try testing.fuzz({}, fuzzInotify, .{});
}

fn writeInotify(smith: *testing.Smith, out: []u8) usize {
    @disableInstrumentation();
    var name: [24]u8 = undefined;
    const name_len = smith.slice(&name);
    return inotify_records.encode(out, .{
        .wd = smith.value(i8),
        .mask = smith.value(u32),
        .cookie = smith.value(u8),
        .name = name[0..name_len],
    });
}

fn fuzzInotify(_: void, smith: *testing.Smith) !void {
    @disableInstrumentation();
    var buffer: [buffer_len]u8 = undefined;
    const bytes = buffer[0..splice(smith, &buffer, 64, writeInotify)];

    var it = inotify_records.iterate(bytes);
    var seen: usize = 0;
    while (true) {
        const record = it.next() catch |err| switch (err) {
            error.TruncatedRecord => break,
        } orelse break;
        seen += 1;
        // A record costs at least a header, so a read cannot hold more
        // of them than its own length allows. Asserted inside the loop
        // rather than after it, so that a decoder that stopped making
        // progress fails rather than hangs.
        try testing.expect(seen <= bytes.len / inotify_records.header_len);
        const name = record.name orelse continue;
        try testing.expect(inside(bytes, name));
        try testing.expect(name.len != 0);
        // The kernel pads the name with NULs and the length counts the
        // padding; what comes back is the name without it.
        try testing.expect(std.mem.indexOfScalar(u8, name, 0) == null);
    }
}

test "the ReadDirectoryChangesW chain decodes or says why" {
    try testing.fuzz({}, fuzzWindows, .{});
}

fn writeWindows(smith: *testing.Smith, out: []u8) usize {
    @disableInstrumentation();
    var name: [24]u8 = undefined;
    // An even length, because a whole number of UTF-16 code units is
    // what the kernel writes; the fuzzer reaches the odd ones by
    // damaging a header rather than by being handed one.
    const name_len = smith.slice(&name) / 2 * 2;
    return windows_records.encode(
        out,
        smith.value(u3),
        name[0..name_len],
        smith.boolWeighted(1, 3),
    );
}

fn fuzzWindows(_: void, smith: *testing.Smith) !void {
    @disableInstrumentation();
    const gpa = testing.allocator;
    var buffer: [buffer_len]u8 = undefined;
    const bytes = buffer[0..splice(smith, &buffer, 64, writeWindows)];

    var it = windows_records.iterate(bytes);
    var seen: usize = 0;
    while (true) {
        const record = it.next() catch |err| switch (err) {
            error.TruncatedRecord, error.OddNameLength, error.OverlappingRecords => break,
        } orelse break;
        seen += 1;
        try testing.expect(seen <= bytes.len / windows_records.header_len);
        try testing.expect(inside(bytes, record.name));
        try testing.expect(record.name.len % 2 == 0);

        const name = try record.wtf8Alloc(gpa);
        defer gpa.free(name);
        // The transcoding is bounded by the name: three bytes per code
        // unit at most, and a surrogate pair is two units for four.
        try testing.expect(name.len <= record.name.len / 2 * 3);
    }
}

test "the FSEvents delivery decodes or says why" {
    try testing.fuzz({}, fuzzDelivery, .{});
}

fn writeDelivery(smith: *testing.Smith, out: []u8) usize {
    @disableInstrumentation();
    var path: [24]u8 = undefined;
    const path_len = smith.slice(&path);
    return fsevents_records.encode(
        out,
        @enumFromInt(smith.value(u2)),
        flagsOf(smith),
        smith.value(u16),
        path[0..path_len],
    );
}

/// A combination of the flags FSEvents sets, weighted towards the ones
/// the backend reads rather than spread over thirty-two bits that mean
/// nothing to it.
fn flagsOf(smith: *testing.Smith) u32 {
    @disableInstrumentation();
    const flag = fsevents_records.flag;
    const named = [_]u32{
        flag.must_scan_sub_dirs,  flag.user_dropped,   flag.kernel_dropped,
        flag.history_done,        flag.root_changed,   flag.item_created,
        flag.item_removed,        flag.item_renamed,   flag.item_modified,
        flag.item_inode_meta_mod, flag.item_xattr_mod, flag.item_is_dir,
    };
    var flags: u32 = smith.value(u8);
    while (!smith.eosWeightedSimple(2, 1)) {
        flags |= named[smith.index(named.len)];
    }
    return flags;
}

fn fuzzDelivery(_: void, smith: *testing.Smith) !void {
    @disableInstrumentation();
    const gpa = testing.allocator;
    var buffer: [buffer_len]u8 = undefined;
    const bytes = buffer[0..splice(smith, &buffer, 64, writeDelivery)];

    var delivered: std.ArrayList(fsevents_records.Record) = .empty;
    defer delivered.deinit(gpa);
    var it = fsevents_records.iterate(bytes);
    while (true) {
        const record = it.next() catch |err| switch (err) {
            error.TruncatedRecord => break,
        } orelse break;
        try testing.expect(delivered.items.len <= bytes.len / fsevents_records.header_len);
        try testing.expect(inside(bytes, record.path));
        // Every flag combination has an answer to both of these, and
        // neither is allowed to be a third thing.
        _ = record.target();
        _ = record.renamed();
        try delivered.append(gpa, record);
    }

    const fake: Fake = .{ .seed = smith.value(u32) };
    const used = try gpa.alloc(bool, delivered.items.len);
    defer gpa.free(used);
    @memset(used, false);

    for (delivered.items) |a| {
        for (delivered.items) |b| {
            // The matching is a relation between two records and not a
            // question one of them answers about the other.
            try testing.expectEqual(
                fsevents_records.pairs(a, b, fake),
                fsevents_records.pairs(b, a, fake),
            );
        }
    }
    for (delivered.items, 0..) |record, at| {
        const partner = fsevents_records.partnerOf(record, delivered.items, used, at + 1, fake) orelse
            continue;
        try testing.expect(partner > at);
        try testing.expect(fsevents_records.pairs(record, delivered.items[partner], fake));
    }
}

test "a rename pairs across the boundary of a delivery" {
    try testing.fuzz({}, fuzzCarry, .{});
}

/// Drives `fsevents_records.Pairing` over a run of deliveries the way
/// the backend drives it, and counts what went in and what came back.
fn fuzzCarry(_: void, smith: *testing.Smith) !void {
    @disableInstrumentation();
    const gpa = testing.allocator;
    const fake: Fake = .{ .seed = smith.value(u32) };

    var pairing: fsevents_records.Pairing = .{};
    defer if (pairing.held) |half| gpa.free(half.path);

    // A half is either joined to a partner, given back alone, or still
    // waiting when the run ends. Nothing else may become of one.
    var carried: usize = 0;
    var joined: usize = 0;
    var alone: usize = 0;

    var deliveries: usize = 0;
    while (!smith.eosWeightedSimple(3, 1) and deliveries < 8) : (deliveries += 1) {
        var buffer: [buffer_len]u8 = undefined;
        const bytes = buffer[0..splice(smith, &buffer, 64, writeDelivery)];

        var delivered: std.ArrayList(fsevents_records.Record) = .empty;
        defer delivered.deinit(gpa);
        var it = fsevents_records.iterate(bytes);
        while (true) {
            const record = it.next() catch |err| switch (err) {
                error.TruncatedRecord => break,
            } orelse break;
            try delivered.append(gpa, record);
        }

        const used = try gpa.alloc(bool, delivered.items.len);
        defer gpa.free(used);
        @memset(used, false);

        if (pairing.take(delivered.items, used, fake)) |taken| {
            defer gpa.free(taken.half.path);
            try testing.expectEqual(@as(?fsevents_records.Half, null), pairing.held);
            if (taken.partner) |at| {
                try testing.expect(at < delivered.items.len);
                try testing.expect(used[at]);
                try testing.expect(fsevents_records.pairs(taken.half.record(), delivered.items[at], fake));
                try testing.expect(fsevents_records.pairs(delivered.items[at], taken.half.record(), fake));
                joined += 1;
            } else {
                alone += 1;
            }
        }

        for (delivered.items, 0..) |record, at| {
            if (used[at]) continue;
            if (!record.renamed() or !fake.wanted(record.id, record.path)) continue;
            if (fsevents_records.partnerOf(record, delivered.items, used, at + 1, fake)) |partner| {
                used[partner] = true;
                continue;
            }
            // The half a delivery could not settle, copied because the
            // buffer it points into is gone by the next one.
            const owned = try gpa.dupe(u8, record.path);
            carried += 1;
            if (pairing.carry(.{
                .id = record.id,
                .path = owned,
                .flags = record.flags,
                .event = record.event,
            })) |stale| {
                gpa.free(stale.path);
                alone += 1;
            }
        }
    }

    try testing.expectEqual(carried, joined + alone + @intFromBool(pairing.held != null));
}

/// A file system and a filter, answered from the path itself.
///
/// The matching must be a pure function of what it is told, or the
/// symmetry it is held to would be a property of the order it asked
/// its questions in. A hash of the path gives the same answer however
/// often it is asked.
const Fake = struct {
    seed: u32,

    pub fn wanted(f: Fake, id: WatchId, subject: []const u8) bool {
        @disableInstrumentation();
        _ = id;
        return f.bit(subject, 1) != 0;
    }

    pub fn exists(f: Fake, subject: []const u8) bool {
        @disableInstrumentation();
        return f.bit(subject, 2) != 0;
    }

    fn bit(f: Fake, subject: []const u8, mask: u64) u64 {
        @disableInstrumentation();
        return std.hash.Wyhash.hash(f.seed, subject) & mask;
    }
};
