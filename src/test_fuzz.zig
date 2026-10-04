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
//! decoded from; and the work and the memory are bounded by the input's
//! length. The two over the FSEvents records hold one more, being the
//! two that pair: the matching is symmetric -- if this record is that
//! one's other half, that one is this one's.
//!
//! The decoders are out of the backends, in files that compile on every
//! target, so all four run on whatever host is in front of the change.
//! Run them with `zig build test --fuzz`.

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

//=========================================================================
// Paths, patterns, a tree compared with its baseline, and a checkpoint
// token. None of these is handed bytes by a kernel, but each is handed a
// spelling it did not choose: a root as the caller wrote it, a pattern
// from a configuration file, a tree somebody else changed, and a token
// that spent a restart on a disk.
//=========================================================================

const path_cmp = @import("path.zig");
const Filter = @import("Filter.zig");
const Baseline = @import("Baseline.zig");
const Checkpoint = @import("Checkpoint.zig");
const builtin = @import("builtin");

/// A path out of the pieces two spellings of one path differ by: case,
/// composition, both separators and runs of them, the dot components, a
/// drive and the Windows prefixes, a NUL and bytes that are not UTF-8.
fn generatePath(smith: *testing.Smith, buf: []u8) []u8 {
    @disableInstrumentation();
    const pieces = [_][]const u8{
        "/",        "\\",   "a",       "B",       "\u{e9}",  "e\u{301}", "\u{c9}", "E\u{301}",
        "\xff",     "\xc3", "..",      ".",       "C:",      "\\\\?\\",  "//",     "\u{65e5}",
        "\u{df}",   "\x00", "\u{301}", "\u{416}", "\u{436}", "\u{d7}",   "*",      "?",
        "\\\\h\\s", "a/",   "/a",      "\u{c5}",
    };
    var end: usize = 0;
    while (!smith.eosWeightedSimple(4, 1)) {
        const piece = pieces[smith.index(pieces.len)];
        if (end + piece.len > buf.len) break;
        @memcpy(buf[end..][0..piece.len], piece);
        end += piece.len;
    }
    return buf[0..end];
}

/// The code points `path_cmp.Folder` yields for `p`, and for each the offset
/// it starts at when that is a place the spelling can be cut -- null in
/// the middle of a decomposed letter -- with one more entry for the end.
const Spelled = struct {
    points: std.ArrayList(u21) = .empty,
    cuts: std.ArrayList(?usize) = .empty,

    fn of(gpa: std.mem.Allocator, p: []const u8) !Spelled {
        @disableInstrumentation();
        var s: Spelled = .{};
        var folder: path_cmp.Folder = .init(p);
        while (true) {
            try s.cuts.append(gpa, if (folder.settled()) folder.at else null);
            try s.points.append(gpa, folder.next() orelse break);
        }
        return s;
    }

    fn deinit(s: *Spelled, gpa: std.mem.Allocator) void {
        s.points.deinit(gpa);
        s.cuts.deinit(gpa);
    }
};

/// `path_cmp.relative`, said the long way round: the root's code points are
/// the path's first ones, the path can be cut there, and what is left is
/// empty or starts at a separator.
fn referenceRelative(gpa: std.mem.Allocator, root: []const u8, p: []const u8) !?[]const u8 {
    @disableInstrumentation();
    var r = try Spelled.of(gpa, root);
    defer r.deinit(gpa);
    var s = try Spelled.of(gpa, p);
    defer s.deinit(gpa);
    if (s.points.items.len < r.points.items.len) return null;
    if (!std.mem.eql(u21, r.points.items, s.points.items[0..r.points.items.len])) return null;
    const split = s.cuts.items[r.points.items.len] orelse return null;
    var rest = p[split..];
    if (rest.len == 0) return rest;
    if ((root.len == 0 or !path_cmp.isSep(root[root.len - 1])) and !path_cmp.isSep(rest[0])) return null;
    while (rest.len != 0 and path_cmp.isSep(rest[0])) rest = rest[1..];
    return rest;
}

fn trimSeparators(p: []const u8) []const u8 {
    var end = p.len;
    while (end != 0 and path_cmp.isSep(p[end - 1])) end -= 1;
    return p[0..end];
}

fn checkPaths(a: []const u8, b: []const u8) !void {
    const gpa = testing.allocator;
    var sa = try Spelled.of(gpa, a);
    defer sa.deinit(gpa);
    var sb = try Spelled.of(gpa, b);
    defer sb.deinit(gpa);

    // One spelling, one answer, from every function that compares.
    const same = path_cmp.eql(a, b);
    try testing.expectEqual(std.mem.eql(u21, sa.points.items, sb.points.items), same);
    try testing.expectEqual(same, path_cmp.eql(b, a));
    try testing.expect(path_cmp.eql(a, a));
    if (same) try testing.expectEqual(path_cmp.hash(a), path_cmp.hash(b));
    if (!path_cmp.folds_case) try testing.expectEqual(std.mem.eql(u8, a, b), same);

    for ([_][2][]const u8{ .{ a, b }, .{ b, a }, .{ a, a } }) |pair| {
        const root = pair[0];
        const p = pair[1];
        const rest = path_cmp.relative(root, p);
        const expected = try referenceRelative(gpa, root, p);
        try testing.expectEqual(expected == null, rest == null);
        try testing.expectEqual(rest != null, path_cmp.within(root, p));
        const r = rest orelse continue;
        // A slice of the path, its tail, and never starting at a
        // separator.
        try testing.expectEqual(@intFromPtr(p.ptr) + p.len, @intFromPtr(r.ptr) + r.len);
        try testing.expectEqualStrings(expected.?, r);
        if (r.len != 0) try testing.expect(!path_cmp.isSep(r[0]));
        // And what was cut off it is the root: the rest never begins
        // above it.
        try testing.expect(path_cmp.eql(trimSeparators(root), trimSeparators(p[0 .. p.len - r.len])));
    }
}

test "paths compare, hash and cut the way their folded spelling says" {
    try testing.fuzz({}, fuzzPaths, .{});
}

fn fuzzPaths(_: void, smith: *testing.Smith) !void {
    @disableInstrumentation();
    var left: [96]u8 = undefined;
    var right: [96]u8 = undefined;
    const a = generatePath(smith, &left);
    // Often the same path in another spelling, or one under it.
    const b = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => generatePath(smith, &right),
        1 => respelled: {
            var end: usize = 0;
            for (a) |byte| {
                right[end] = if (std.ascii.isAlphabetic(byte) and smith.boolWeighted(1, 1)) byte ^ 0x20 else byte;
                end += 1;
            }
            break :respelled right[0..end];
        },
        else => under: {
            @memcpy(right[0..a.len], a);
            const tail = generatePath(smith, right[a.len..]);
            break :under right[0 .. a.len + tail.len];
        },
    };
    try checkPaths(a, b);
}

/// A pattern as the matcher reads it: the folded code points, with `**`
/// and `*` and `?` taken out as what they are.
const Token = union(enum) { any_depth, any, one, literal: u21 };

fn tokenize(gpa: std.mem.Allocator, pattern: []const u8) !std.ArrayList(Token) {
    @disableInstrumentation();
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);
    var folder: path_cmp.Folder = .init(pattern);
    while (folder.next()) |c| {
        try tokens.append(gpa, switch (c) {
            '*' => if (folder.peek() == '*') double: {
                _ = folder.next();
                break :double .any_depth;
            } else .any,
            '?' => .one,
            else => .{ .literal = c },
        });
    }
    return tokens;
}

/// The four rules of `Filter.ignore`, matched over every pair of
/// positions once rather than by backtracking.
fn referenceMatches(gpa: std.mem.Allocator, pattern: []const u8, name: []const u8) !bool {
    @disableInstrumentation();
    var tokens = try tokenize(gpa, pattern);
    defer tokens.deinit(gpa);
    var spelled = try Spelled.of(gpa, name);
    defer spelled.deinit(gpa);
    const t = tokens.items;
    const n = spelled.points.items;
    // `can[i][j]`: the tokens from `i` match the name from `j`.
    const can = try gpa.alloc(bool, (t.len + 1) * (n.len + 1));
    defer gpa.free(can);
    const w = n.len + 1;
    var i = t.len + 1;
    while (i > 0) {
        i -= 1;
        var j = n.len + 1;
        while (j > 0) {
            j -= 1;
            can[i * w + j] = if (i == t.len) j == n.len else switch (t[i]) {
                .literal => |c| j < n.len and n[j] == c and can[(i + 1) * w + j + 1],
                .one => j < n.len and n[j] != '/' and can[(i + 1) * w + j + 1],
                .any => can[(i + 1) * w + j] or (j < n.len and n[j] != '/' and can[i * w + j + 1]),
                .any_depth => any: {
                    // Any run, separators included; and a separator just
                    // after it may stand for no directory at all.
                    const skip = if (i + 1 < t.len and t[i + 1] == .literal and t[i + 1].literal == '/') i + 2 else i + 1;
                    break :any can[(i + 1) * w + j] or can[skip * w + j] or (j < n.len and can[i * w + j + 1]);
                },
            };
        }
    }
    return can[0];
}

/// A pattern built from wildcards, separators and the letters the paths
/// below are made of.
fn generatePattern(smith: *testing.Smith, buf: []u8) []u8 {
    @disableInstrumentation();
    const pieces = [_][]const u8{ "*", "**", "?", "/", "a", "b", "A", "\u{e9}", "e\u{301}", "**/", "/**", "." };
    var end: usize = 0;
    while (!smith.eosWeightedSimple(3, 1)) {
        const piece = pieces[smith.index(pieces.len)];
        if (end + piece.len > buf.len) break;
        @memcpy(buf[end..][0..piece.len], piece);
        end += piece.len;
    }
    return buf[0..end];
}

/// A path below `/w`, one to four components of the same letters.
fn generateBelow(smith: *testing.Smith, buf: []u8) []u8 {
    @disableInstrumentation();
    const root = if (builtin.os.tag == .windows) "C:\\w" else "/w";
    const names = [_][]const u8{ "a", "b", "ab", "ba", "A", "\u{e9}", "e\u{301}", "a.b", "aa" };
    @memcpy(buf[0..root.len], root);
    var end: usize = root.len;
    const depth = smith.valueRangeAtMost(u8, 1, 4);
    for (0..depth) |_| {
        buf[end] = std.fs.path.sep;
        end += 1;
        const parts = smith.valueRangeAtMost(u8, 1, 2);
        for (0..parts) |_| {
            const name = names[smith.index(names.len)];
            @memcpy(buf[end..][0..name.len], name);
            end += name.len;
        }
    }
    return buf[0..end];
}

/// The pattern with `/` as the platform spells a separator.
fn native(buf: []u8, pattern: []const u8) []const u8 {
    @memcpy(buf[0..pattern.len], pattern);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, buf[0..pattern.len], '/', '\\');
    return buf[0..pattern.len];
}

test "a filter keeps what its patterns name and walks to it" {
    try testing.fuzz({}, fuzzFilter, .{});
}

fn fuzzFilter(_: void, smith: *testing.Smith) !void {
    @disableInstrumentation();
    const gpa = testing.allocator;
    const root = if (builtin.os.tag == .windows) "C:\\w" else "/w";
    var pattern_buf: [48]u8 = undefined;
    var native_buf: [48]u8 = undefined;
    const pattern = native(&native_buf, generatePattern(smith, &pattern_buf));
    var subject_buf: [128]u8 = undefined;
    const subject = generateBelow(smith, &subject_buf);
    const rel = path_cmp.relative(root, subject).?;
    errdefer std.debug.print("pattern '{s}' subject '{s}'\n", .{ pattern, subject });

    // The matcher is the reference's answer for the path and for the
    // name alone.
    const ignore: Filter = .{ .ignore = &.{pattern} };
    const only: Filter = .{ .only = &.{pattern} };
    const bare = std.mem.indexOfAny(u8, pattern, path_cmp.separators) == null;
    const named = pattern.len != 0 and (try referenceMatches(gpa, pattern, rel) or
        (bare and try referenceMatches(gpa, pattern, std.fs.path.basename(rel))));

    // The root is what was asked for, whatever the patterns say.
    try testing.expect(!ignore.excludes(root, root));
    try testing.expect(!only.excludes(root, root));
    try testing.expect(!only.prunes(root, root));

    // A path a pattern names is left out by `ignore` and kept by `only`;
    // and kept means reachable: no directory on the way to it is pruned.
    if (named) {
        try testing.expect(ignore.excludes(root, subject));
        try testing.expect(!only.excludes(root, subject));
    }
    var end: usize = root.len + 1;
    while (std.mem.indexOfAnyPos(u8, subject, end, path_cmp.separators)) |at| : (end = at + 1) {
        const ancestor = subject[0..at];
        // An excluded directory takes everything below it.
        if (ignore.excludes(root, ancestor)) try testing.expect(ignore.excludes(root, subject));
        if (only.prunes(root, ancestor)) try testing.expect(only.excludes(root, subject));
        if (named) try testing.expect(!only.prunes(root, ancestor));
    }
    // Pruning a directory is a stronger claim than not reporting it.
    if (only.prunes(root, subject)) try testing.expect(only.excludes(root, subject));
    if (ignore.prunes(root, subject)) try testing.expect(ignore.excludes(root, subject));
}

test "a baseline of an arbitrary tree diffs to what changed in it" {
    try testing.fuzz({}, fuzzBaseline, .{});
}

/// A tree: relative path to a file's contents, or to null for a directory.
const Model = std.StringArrayHashMapUnmanaged(?[]const u8);

fn applyModel(dir: std.Io.Dir, model: *const Model) !void {
    const io = testing.io;
    for (model.keys(), model.values()) |key, value| {
        if (value) |contents| {
            try dir.writeFile(io, .{ .sub_path = key, .data = contents });
        } else try dir.createDirPath(io, key);
    }
}

/// `std.testing.io` around one input of `zig build test --fuzz`: the test
/// runner sets it up around each test of an ordinary run, and leaves it
/// uninitialised around the inputs a fuzzing run feeds one target.
fn fuzzingIo() void {
    if (builtin.fuzz) testing.io_instance = .init(testing.allocator, .{});
}

fn fuzzedIo() void {
    if (builtin.fuzz) testing.io_instance.deinit();
}

fn fuzzBaseline(_: void, smith: *testing.Smith) !void {
    @disableInstrumentation();
    fuzzingIo();
    defer fuzzedIo();
    const gpa = testing.allocator;
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    // Names that stay distinct on a volume that folds case and
    // composition, so the model and the disk agree on what is there.
    const names = [_][]const u8{ "a", "b", "c d", "\u{65e5}", "e.txt" };
    var before: Model = .empty;
    var generated: usize = 0;
    while (generated < 12 and !smith.eosWeightedSimple(3, 1)) : (generated += 1) {
        // Below an existing directory or at the top.
        const dirs = blk: {
            var list: std.ArrayList([]const u8) = .empty;
            try list.append(a, "");
            for (before.keys(), before.values()) |key, value| if (value == null) try list.append(a, key);
            break :blk list.items;
        };
        const parent = dirs[smith.index(dirs.len)];
        const name = names[smith.index(names.len)];
        const key = if (parent.len == 0) try a.dupe(u8, name) else try std.fs.path.join(a, &.{ parent, name });
        if (before.contains(key)) continue;
        const contents: ?[]const u8 = if (smith.boolWeighted(1, 2)) null else try a.dupe(u8, "x" ** 3);
        try before.put(a, key, contents);
    }
    try applyModel(tmp.dir, &before);

    const recursive = smith.boolWeighted(1, 3);
    var base = try Baseline.seed(gpa, io, root, .{ .recursive = recursive });
    defer base.deinit(gpa);

    // Change some of it: remove a path (and what is below it), rewrite a
    // file to another length, turn one kind into the other, add new ones.
    var after: Model = .empty;
    for (before.keys(), before.values()) |key, value| try after.put(a, key, value);
    var changes: usize = 0;
    while (changes < 6 and after.count() != 0 and !smith.eosWeightedSimple(2, 1)) : (changes += 1) {
        const at = smith.index(after.count());
        const key = after.keys()[at];
        switch (smith.valueRangeAtMost(u8, 0, 3)) {
            0, 2 => {
                // Gone, with everything below it; or gone and back as the
                // other kind.
                const was_dir = after.values()[at] == null;
                if (was_dir) try tmp.dir.deleteTree(io, key) else try tmp.dir.deleteFile(io, key);
                var i: usize = 0;
                while (i < after.count()) {
                    const other = after.keys()[i];
                    if (std.mem.eql(u8, other, key) or (std.mem.startsWith(u8, other, key) and path_cmp.isSep(other[key.len]))) {
                        after.swapRemoveAt(i);
                    } else i += 1;
                }
                if (smith.boolWeighted(1, 1)) {
                    const contents: ?[]const u8 = if (was_dir) "y" else null;
                    try after.put(a, key, contents);
                    if (contents) |c| try tmp.dir.writeFile(io, .{ .sub_path = key, .data = c }) else try tmp.dir.createDirPath(io, key);
                }
            },
            1 => if (after.values()[at]) |old| {
                const contents = try std.mem.concat(a, u8, &.{ old, "z" });
                after.values()[at] = contents;
                try tmp.dir.writeFile(io, .{ .sub_path = key, .data = contents });
            },
            else => if (after.values()[at] == null) {
                const name = names[smith.index(names.len)];
                const child = try std.fs.path.join(a, &.{ key, name });
                if (!after.contains(child)) {
                    try after.put(a, child, "new");
                    try tmp.dir.writeFile(io, .{ .sub_path = child, .data = "new" });
                }
            },
        }
    }

    // The diff, against the two models: what is in one and not the other,
    // and the files whose contents changed. A path below the root is in
    // a non-recursive baseline's view only when it is the root's child.
    const Expected = struct { kind: lookout.Kind, target: lookout.Target };
    var expected: std.StringArrayHashMapUnmanaged(Expected) = .empty;
    const visible = struct {
        fn f(key: []const u8, deep: bool) bool {
            return deep or std.mem.indexOfAny(u8, key, path_cmp.separators) == null;
        }
    }.f;
    for (after.keys(), after.values()) |key, value| {
        if (!visible(key, recursive)) continue;
        const target: lookout.Target = if (value == null) .directory else .file;
        const old = before.get(key) orelse {
            try expected.put(a, key, .{ .kind = .created, .target = target });
            continue;
        };
        if ((old == null) != (value == null)) {
            try expected.put(a, key, .{ .kind = .created, .target = target });
            // What a directory held, gone with it when it became a file.
            if (old == null) for (before.keys(), before.values()) |inner, inner_value| {
                if (visible(inner, recursive) and std.mem.startsWith(u8, inner, key) and inner.len > key.len and path_cmp.isSep(inner[key.len]) and !after.contains(inner))
                    try expected.put(a, inner, .{ .kind = .removed, .target = if (inner_value == null) .directory else .file });
            };
        } else if (value != null and !std.mem.eql(u8, old.?, value.?)) {
            try expected.put(a, key, .{ .kind = .modified, .target = .file });
        }
    }
    for (before.keys(), before.values()) |key, value| {
        if (!visible(key, recursive) or after.contains(key) or expected.contains(key)) continue;
        try expected.put(a, key, .{ .kind = .removed, .target = if (value == null) .directory else .file });
    }

    const found = try base.diff(gpa);
    for (found) |change| {
        const rel = path_cmp.relative(root, change.path) orelse return error.TestChangeOutsideRoot;
        const wanted = expected.get(rel) orelse {
            std.debug.print("unexpected {t} {s}\n", .{ change.kind, rel });
            return error.TestUnexpectedChange;
        };
        try testing.expectEqual(wanted.kind, change.kind);
        try testing.expectEqual(wanted.target, change.target);
    }
    for (expected.keys()) |key| {
        for (found) |change| {
            if (std.mem.eql(u8, path_cmp.relative(root, change.path).?, key)) break;
        } else {
            std.debug.print("missed {t} {s}\n", .{ expected.get(key).?.kind, key });
            return error.TestMissedChange;
        }
    }
    try testing.expectEqual(expected.count(), found.len);
    // And the tree is now the baseline: nothing more to say.
    try testing.expectEqual(@as(usize, 0), (try base.diff(gpa)).len);
}

test "a checkpoint token reads back as itself or not at all" {
    try testing.fuzz({}, fuzzCheckpoint, .{});
}

fn fuzzCheckpoint(_: void, smith: *testing.Smith) !void {
    @disableInstrumentation();
    const gpa = testing.allocator;
    const absolute = if (builtin.os.tag == .windows) "\"C:\\\\w\"" else "\"/w\"";
    const pieces = [_][]const u8{
        "{\"version\":1,\"backend\":\"fsevents\",\"watches\":[",                                                             "]}",
        "{\"root\":" ++ absolute ++ ",\"cursor\":1,\"recursive\":true,\"identity\":{\"volume\":[",                           "],\"log\":[",
        "]}",                                                                                                                "}",
        "48,",                                                                                                               "48",
        ",\"changes\":[{\"path\":" ++ absolute ++ ",\"kind\":\"renamed\",\"from\":" ++ absolute ++ ",\"target\":\"file\"}]", ",\"half\":{\"path\":" ++ absolute ++ ",\"flags\":2048,\"event\":3}",
        ",",                                                                                                                 "\"\\u0000\"",
        "\"\\ud800\"",                                                                                                       "18446744073709551615",
        "-1",                                                                                                                "null",
        " ",
    };
    var buf: [1024]u8 = undefined;
    var end: usize = 0;
    while (!smith.eosWeightedSimple(8, 1)) {
        var chunk: [16]u8 = undefined;
        const piece = if (smith.boolWeighted(1, 6)) chunk[0..smith.slice(&chunk)] else pieces[smith.index(pieces.len)];
        if (end + piece.len > buf.len) break;
        @memcpy(buf[end..][0..piece.len], piece);
        end += piece.len;
    }
    var parsed = Checkpoint.parse(gpa, buf[0..end]) catch |err| {
        try testing.expectEqual(error.InvalidCheckpoint, err);
        return;
    };
    defer parsed.deinit();
    // What was accepted writes a token that is accepted, and reads back
    // to the same token.
    const token = try parsed.token(gpa);
    defer gpa.free(token);
    var again = try Checkpoint.parse(gpa, token);
    defer again.deinit();
    const second = try again.token(gpa);
    defer gpa.free(second);
    try testing.expectEqualStrings(token, second);
}

test "the path, pattern, baseline and checkpoint properties hold over seeded rounds" {
    var prng: std.Random.DefaultPrng = .init(0x100c);
    var bytes: [256]u8 = undefined;
    for (0..64) |i| {
        for (&bytes) |*byte| byte.* = switch (prng.random().uintLessThan(u8, 10)) {
            0...6 => 0,
            7, 8 => prng.random().uintLessThan(u8, 16),
            else => prng.random().int(u8),
        };
        inline for (.{ fuzzPaths, fuzzFilter, fuzzBaseline, fuzzCheckpoint, fuzzBaselineStorage }) |property| {
            var smith: testing.Smith = .{ .in = &bytes };
            property({}, &smith) catch |err| {
                std.debug.print("seeded round {d}: {t}\n", .{ i, err });
                return err;
            };
        }
    }
}

test "a persisted baseline loader accepts only intact validated storage" {
    try testing.fuzz({}, fuzzBaselineStorage, .{});
}

fn fuzzBaselineStorage(_: void, smith: *testing.Smith) !void {
    @disableInstrumentation();
    const format = @import("baseline_format.zig");
    const gpa = testing.allocator;
    var buf: [2048]u8 = undefined;
    const bytes = buf[0..smith.slice(&buf)];
    var parsed = format.parse(gpa, bytes) catch |err| {
        try testing.expect(err == error.InvalidBaseline or err == error.UnsupportedBaselineVersion or err == error.ForeignBaseline);
        // Exercise the JSON parser behind a valid checksum as well.
        const wrapped = try gpa.alloc(u8, 44 + bytes.len);
        defer gpa.free(wrapped);
        @memcpy(wrapped[0..8], "LOOKBASE");
        std.mem.writeInt(u32, wrapped[8..12], 1, .little);
        std.crypto.hash.sha2.Sha256.hash(bytes, wrapped[12..44], .{});
        @memcpy(wrapped[44..], bytes);
        var inner = format.parse(gpa, wrapped) catch return;
        defer inner.deinit();
        return;
    };
    defer parsed.deinit();
    const encoded = try format.encode(gpa, parsed.value);
    defer gpa.free(encoded);
    var again = try format.parse(gpa, encoded);
    defer again.deinit();
}
