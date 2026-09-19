//! Comparing one path with another the way the file system does.
//!
//! Two spellings can name one file. A volume that folds case answers to
//! `Notes.txt` and `notes.txt` alike, and one that stores a letter
//! decomposed answers to `é` written as one code point and as `e`
//! followed by a combining accent. A watcher that compares paths byte for
//! byte on such a volume does not degrade: it drops every event whose
//! spelling differs from the one the caller used, and says nothing about
//! why.
//!
//! So every comparison lookout makes between two paths goes through this
//! file: the watch root against the path an event names, an ignore
//! pattern against an entry, one node against the subtree it is being
//! removed with, and the key an event is coalesced under.
//!
//! What is folded, and what is not:
//!
//! * Case, for the ASCII letters and for the Latin-1 letters.
//! * Composition, for the Latin-1 letters: a precomposed letter compares
//!   equal to its base letter followed by its accent.
//! * Nothing else. A path in another script is compared as written,
//!   which is what a volume that stores it verbatim does too.
//!
//! On a target whose file systems do not fold -- Linux and the BSDs --
//! `folds_case` is false and every comparison here is a byte comparison
//! with no decoding at all.

const std = @import("std");
const builtin = @import("builtin");

/// Whether lookout compares paths as the target's usual file systems do,
/// ignoring case and composition, or byte for byte.
///
/// A case-sensitive volume on a target that folds -- which both Apple
/// platforms and Windows can be asked for -- is compared more loosely
/// than it stores, so two paths that differ only in case are taken for
/// one. That is the same choice the platform's own tools make, and the
/// alternative, dropping every event on the volumes people actually
/// have, is worse.
pub const folds_case: bool = switch (builtin.os.tag) {
    .driverkit,
    .ios,
    .maccatalyst,
    .macos,
    .tvos,
    .visionos,
    .watchos,
    .windows,
    => true,
    else => false,
};

/// The separators a path can be spelled with. Windows takes either;
/// everywhere else a backslash is an ordinary character in a name.
pub const separators: []const u8 = if (builtin.os.tag == .windows) "\\/" else "/";

pub fn isSep(c: u8) bool {
    return std.mem.indexOfScalar(u8, separators, c) != null;
}

/// Whether two paths name the same thing.
pub fn eql(a: []const u8, b: []const u8) bool {
    if (!folds_case) return std.mem.eql(u8, a, b);
    var left: Folder = .init(a);
    var right: Folder = .init(b);
    while (true) {
        const l = left.next();
        const r = right.next();
        if (l == null and r == null) return true;
        if (l == null or r == null) return false;
        if (l.? != r.?) return false;
    }
}

/// The part of `path` below `root`: empty when the two name the same
/// path, and `null` when `path` is not under `root` at all.
///
/// A slice of `path` rather than of `root`, and found by comparison
/// rather than by offset, because the two spellings can name the same
/// prefix with different numbers of bytes.
pub fn relative(root: []const u8, path: []const u8) ?[]const u8 {
    if (!folds_case) {
        if (!std.mem.startsWith(u8, path, root)) return null;
        var rest = path[root.len..];
        if (rest.len == 0) return rest;
        if (!isSep(rest[0])) return null;
        while (rest.len != 0 and isSep(rest[0])) rest = rest[1..];
        return rest;
    }

    var left: Folder = .init(root);
    var right: Folder = .init(path);
    while (true) {
        // Only a point where neither side is mid-decomposition is a
        // place the two spellings can be cut.
        const boundary = if (right.settled()) right.at else null;
        const l = left.next() orelse {
            const split = boundary orelse return null;
            var rest = path[split..];
            if (rest.len == 0) return rest;
            if (!isSep(rest[0])) return null;
            while (rest.len != 0 and isSep(rest[0])) rest = rest[1..];
            return rest;
        };
        const r = right.next() orelse return null;
        if (l != r) return null;
    }
}

/// Whether `path` is `root` or something under it.
pub fn within(root: []const u8, path: []const u8) bool {
    return relative(root, path) != null;
}

/// A hash of the folded spelling, so that two paths `eql` calls equal
/// land in one bucket.
pub fn hash(p: []const u8) u64 {
    if (!folds_case) return std.hash.Wyhash.hash(0, p);
    var hasher: std.hash.Wyhash = .init(0);
    var folder: Folder = .init(p);
    while (folder.next()) |cp| {
        const bytes = std.mem.toBytes(cp);
        hasher.update(&bytes);
    }
    return hasher.final();
}

/// The two above under names a hash-map context can reach past its own
/// `hash` and `eql`.
const same = eql;
const digest = hash;

/// The context a hash map of paths is keyed with.
pub const MapContext = struct {
    pub fn hash(_: MapContext, key: []const u8) u64 {
        return digest(key);
    }
    pub fn eql(_: MapContext, a: []const u8, b: []const u8) bool {
        return same(a, b);
    }
};

/// The context an array hash map of paths is keyed with.
pub const ArrayMapContext = struct {
    pub fn hash(_: ArrayMapContext, key: []const u8) u32 {
        return @truncate(digest(key));
    }
    pub fn eql(_: ArrayMapContext, a: []const u8, b: []const u8, _: usize) bool {
        return same(a, b);
    }
};

/// A set of paths, compared as the file system compares them.
pub fn Set(comptime V: type) type {
    return std.ArrayHashMapUnmanaged([]const u8, V, ArrayMapContext, true);
}

/// Yields the code points a path is compared by: one per character, with
/// case folded away and a Latin-1 letter split into its base and its
/// accent. On a target that does not fold it yields the bytes, so a
/// comparison there costs no decoding at all.
///
/// Small and copyable on purpose: a pattern matcher reconsiders a `*` by
/// keeping a copy of where it was.
pub const Folder = struct {
    bytes: []const u8,
    /// Where the next code point starts. Only a cut point while
    /// `pending` is zero.
    at: usize,
    /// The accent of a letter whose base has just been yielded.
    pending: u21,

    pub fn init(bytes: []const u8) Folder {
        return .{ .bytes = bytes, .at = 0, .pending = 0 };
    }

    /// Whether the folder is between two whole characters.
    pub fn settled(f: *const Folder) bool {
        return f.pending == 0;
    }

    /// The next code point without consuming it.
    pub fn peek(f: Folder) ?u21 {
        var copy = f;
        return copy.next();
    }

    pub fn next(f: *Folder) ?u21 {
        if (!folds_case) {
            if (f.at >= f.bytes.len) return null;
            const byte = f.bytes[f.at];
            f.at += 1;
            return byte;
        }
        if (f.pending != 0) {
            const mark = f.pending;
            f.pending = 0;
            return mark;
        }
        if (f.at >= f.bytes.len) return null;

        const first = f.bytes[f.at];
        if (first < 0x80) {
            f.at += 1;
            // A path is read with the platform's separators meaning the
            // same thing, as the rest of the package spells them.
            if (isSep(first)) return '/';
            return std.ascii.toLower(first);
        }

        const len = std.unicode.utf8ByteSequenceLength(first) catch {
            f.at += 1;
            return raw(first);
        };
        if (f.at + len > f.bytes.len) {
            f.at += 1;
            return raw(first);
        }
        const cp = std.unicode.utf8Decode(f.bytes[f.at..][0..len]) catch {
            f.at += 1;
            return raw(first);
        };
        f.at += len;

        if (cp >= 0xC0 and cp <= 0xFF) {
            const entry = latin1[cp - 0xC0];
            f.pending = entry.mark;
            return entry.base;
        }
        return cp;
    }

    /// A byte no valid encoding produced, kept distinct from every real
    /// code point so that two different broken names stay different.
    fn raw(byte: u8) u21 {
        return 0x11_0000 + @as(u21, byte);
    }
};

/// What a Latin-1 letter is compared as: its lower-case base, and the
/// accent it carries or zero.
const Latin1 = struct { base: u21, mark: u21 };

/// The Latin-1 Supplement, folded. The three that are letters in their
/// own right -- æ, ð, ø, þ, ß, ÿ -- keep their own code point rather
/// than being taken apart, because no accent was ever put on them; the
/// two that are not letters at all -- × and ÷ -- are themselves.
const latin1: [64]Latin1 = blk: {
    var table: [64]Latin1 = undefined;
    // Every entry is its own lower case with no accent unless the loop
    // below says otherwise.
    for (&table, 0..) |*slot, i| {
        const cp: u21 = 0xC0 + i;
        const lower: u21 = if (cp <= 0xDE and cp != 0xD7) cp + 0x20 else cp;
        slot.* = .{ .base = lower, .mark = 0 };
    }
    const decomposed = [_]struct { u21, u21, u21 }{
        .{ 0xC0, 'a', 0x300 }, .{ 0xC1, 'a', 0x301 }, .{ 0xC2, 'a', 0x302 },
        .{ 0xC3, 'a', 0x303 }, .{ 0xC4, 'a', 0x308 }, .{ 0xC5, 'a', 0x30A },
        .{ 0xC7, 'c', 0x327 }, .{ 0xC8, 'e', 0x300 }, .{ 0xC9, 'e', 0x301 },
        .{ 0xCA, 'e', 0x302 }, .{ 0xCB, 'e', 0x308 }, .{ 0xCC, 'i', 0x300 },
        .{ 0xCD, 'i', 0x301 }, .{ 0xCE, 'i', 0x302 }, .{ 0xCF, 'i', 0x308 },
        .{ 0xD1, 'n', 0x303 }, .{ 0xD2, 'o', 0x300 }, .{ 0xD3, 'o', 0x301 },
        .{ 0xD4, 'o', 0x302 }, .{ 0xD5, 'o', 0x303 }, .{ 0xD6, 'o', 0x308 },
        .{ 0xD9, 'u', 0x300 }, .{ 0xDA, 'u', 0x301 }, .{ 0xDB, 'u', 0x302 },
        .{ 0xDC, 'u', 0x308 }, .{ 0xDD, 'y', 0x301 }, .{ 0xE0, 'a', 0x300 },
        .{ 0xE1, 'a', 0x301 }, .{ 0xE2, 'a', 0x302 }, .{ 0xE3, 'a', 0x303 },
        .{ 0xE4, 'a', 0x308 }, .{ 0xE5, 'a', 0x30A }, .{ 0xE7, 'c', 0x327 },
        .{ 0xE8, 'e', 0x300 }, .{ 0xE9, 'e', 0x301 }, .{ 0xEA, 'e', 0x302 },
        .{ 0xEB, 'e', 0x308 }, .{ 0xEC, 'i', 0x300 }, .{ 0xED, 'i', 0x301 },
        .{ 0xEE, 'i', 0x302 }, .{ 0xEF, 'i', 0x308 }, .{ 0xF1, 'n', 0x303 },
        .{ 0xF2, 'o', 0x300 }, .{ 0xF3, 'o', 0x301 }, .{ 0xF4, 'o', 0x302 },
        .{ 0xF5, 'o', 0x303 }, .{ 0xF6, 'o', 0x308 }, .{ 0xF9, 'u', 0x300 },
        .{ 0xFA, 'u', 0x301 }, .{ 0xFB, 'u', 0x302 }, .{ 0xFC, 'u', 0x308 },
        .{ 0xFD, 'y', 0x301 }, .{ 0xFF, 'y', 0x308 },
    };
    for (decomposed) |entry| {
        table[entry[0] - 0xC0] = .{ .base = entry[1], .mark = entry[2] };
    }
    break :blk table;
};

const testing = std.testing;

test "a path equals itself and nothing else" {
    try testing.expect(eql("/w/a.txt", "/w/a.txt"));
    try testing.expect(!eql("/w/a.txt", "/w/b.txt"));
    try testing.expect(!eql("/w/a.txt", "/w/a.txt2"));
    try testing.expect(!eql("/w/a.txt2", "/w/a.txt"));
    try testing.expect(eql("", ""));
}

test "case and composition are folded exactly where the target folds them" {
    const same_case = eql("/w/Notes.TXT", "/w/notes.txt");
    try testing.expectEqual(folds_case, same_case);

    // "é" written as one code point, and as "e" with a combining accent.
    const composed = "/w/caf\u{00e9}.txt";
    const decomposed = "/w/cafe\u{0301}.txt";
    try testing.expectEqual(folds_case, eql(composed, decomposed));

    // A script the table says nothing about is compared as written,
    // which is what a volume storing it verbatim does.
    try testing.expect(eql("/w/日本", "/w/日本"));
    try testing.expect(!eql("/w/日本", "/w/日"));
}

test "the folded hash agrees with the folded comparison" {
    try testing.expectEqual(hash("/w/a.txt"), hash("/w/a.txt"));
    if (folds_case) {
        try testing.expectEqual(hash("/w/A.txt"), hash("/w/a.txt"));
        try testing.expectEqual(hash("/w/caf\u{00e9}"), hash("/w/cafe\u{0301}"));
    }
    try testing.expect(hash("/w/a.txt") != hash("/w/b.txt"));
}

test "what is below a root is found by comparison, not by offset" {
    try testing.expectEqualStrings("", relative("/w", "/w").?);
    try testing.expectEqualStrings("a/b.txt", relative("/w", "/w/a/b.txt").?);
    try testing.expectEqual(@as(?[]const u8, null), relative("/w", "/wider/a"));
    try testing.expectEqual(@as(?[]const u8, null), relative("/w/a", "/w"));
    try testing.expect(within("/w", "/w/a"));
    try testing.expect(!within("/w", "/x/a"));

    if (folds_case) {
        // The two spellings of the root are not even the same length,
        // which is the whole reason this is not a byte offset.
        try testing.expectEqualStrings("a.txt", relative("/w/caf\u{00e9}", "/w/cafe\u{0301}/a.txt").?);
        try testing.expectEqualStrings("a.txt", relative("/w/CAFE", "/w/cafe/a.txt").?);
    }
}

test "a name that is not valid UTF-8 is still itself" {
    const broken: []const u8 = "/w/\xff\xfe";
    const other: []const u8 = "/w/\xff\xfd";
    try testing.expect(eql(broken, broken));
    try testing.expect(!eql(broken, other));
    try testing.expectEqualStrings("\xff\xfe", relative("/w", broken).?);
}

test "a separator is a separator whichever one the caller wrote" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expect(eql("C:\\w\\a", "C:/w/a"));
    try testing.expectEqualStrings("a", relative("C:\\w", "C:/w/a").?);
}
