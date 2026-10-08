//! Canonical kernel spelling comparisons. No Unicode equivalence is
//! inferred here: directory listings and native events already name entries.
const std = @import("std");
const builtin = @import("builtin");

/// The separators a path can be spelled with. Windows takes either;
/// everywhere else a backslash is an ordinary character in a name.
pub const separators: []const u8 = if (builtin.target.os.tag == .windows) "\\/" else "/";

pub fn isSep(c: u8) bool {
    return std.mem.findScalar(u8, separators, c) != null;
}

/// Whether two paths name the same thing.
pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The part of `path` below `root`: empty when the two name the same
/// path, and `null` when `path` is not under `root` at all.
///
/// Both arguments have canonical kernel spelling; the suffix borrows `path`.
pub fn relative(root: []const u8, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, root)) return null;
    var rest = path[root.len..];
    if (rest.len == 0) return rest;
    if ((root.len == 0 or !isSep(root[root.len - 1])) and !isSep(rest[0])) return null;
    while (rest.len != 0 and isSep(rest[0])) rest = rest[1..];
    return rest;
}

/// Whether `path` is `root` or something under it.
pub fn within(root: []const u8, path: []const u8) bool {
    return relative(root, path) != null;
}

/// A hash of the canonical kernel spelling, so that two paths `eql` calls equal
/// land in one bucket.
pub fn hash(p: []const u8) u64 {
    return std.hash.Wyhash.hash(0, p);
}

/// `hash` of a path held by one of several owners -- a watch, say -- so
/// that the same path under two owners lands in two buckets. The one
/// mixing every map keyed by owner and path uses.
pub fn hashOwned(owner: u64, p: []const u8) u64 {
    return hash(p) ^ (owner *% 0x9e3779b97f4a7c15);
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
    return std.array_hash_map.Custom([]const u8, V, ArrayMapContext, true);
}

test "canonical kernel paths retain case composition invalid bytes and boundaries" {
    const testing = std.testing;
    try testing.expect(!eql("/w/A", "/w/a"));
    try testing.expect(!eql("/w/café", "/w/cafe\u{301}"));
    const broken = "/w/\xff\xfe";
    try testing.expect(eql(broken, broken));
    try testing.expect(!eql(broken, "/w/\xff\xfd"));
    try testing.expectEqualStrings("\xff\xfe", relative("/w", broken).?);
    try testing.expectEqualStrings("", relative("/w", "/w").?);
    try testing.expectEqualStrings("a/b", relative("/w", "/w/a/b").?);
    try testing.expect(relative("/w", "/wider/a") == null);
    try testing.expectEqualStrings("tmp/a", relative("/", "/tmp/a").?);
    if (builtin.target.os.tag == .windows) {
        try testing.expectEqualStrings("tmp\\a", relative("C:\\", "C:\\tmp\\a").?);
    }
}
