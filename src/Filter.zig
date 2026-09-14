//! Which paths under a watch the caller wants, and which are not worth
//! watching at all.
//!
//! A filter is two things a caller can combine: a list of patterns naming
//! what to leave out, and a predicate of their own for everything a
//! pattern cannot say. Both answer the same question -- is this path part
//! of the watch -- and both are asked about every ancestor of a path, so
//! excluding a directory excludes everything below it without naming any
//! of it.
//!
//! Where lookout does the recursion itself -- `inotify`, `kqueue` and
//! `poll` -- an excluded directory is never opened and never registered,
//! so it costs neither a kernel watch nor a descriptor. Where the kernel
//! recurses -- FSEvents and `ReadDirectoryChangesW` -- the work is the
//! kernel's and the filter can only save the caller the event. That
//! difference is `lookout.prunesIgnored`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Filter = @This();

/// Patterns naming what this watch is not about, matched against each
/// path below the watch root.
///
/// A pattern is matched against the path relative to the watch root,
/// spelled with the platform's separator, unless it is itself absolute,
/// in which case it is matched against the absolute path. Three rules,
/// and nothing else:
///
/// * `*` matches any run of characters within one path component, and
///   `?` matches exactly one. Neither crosses a separator.
/// * A pattern holding no separator is also matched against the final
///   component alone, so `node_modules` excludes one at any depth and
///   `*.tmp` excludes the temporary files wherever they are written.
/// * A pattern that matches a directory excludes everything below it,
///   because every ancestor of a path is tested as well as the path.
///
/// Borrowed only for the duration of `lookout.Watcher.add`, which copies
/// what it keeps.
ignore: []const []const u8 = &.{},

/// The caller's own answer, asked for every path a pattern did not
/// already exclude. Returning `false` excludes the path, and with it
/// everything below it when the path is a directory.
///
/// `path` is absolute, and is the path as lookout spells it. `context` is
/// whatever was put in `context`, which lookout only passes back.
allow: ?*const fn (context: ?*anyopaque, path: []const u8) bool = null,

/// Passed to `allow` untouched. lookout never dereferences it; keeping
/// whatever it points at alive for the life of the watch is the caller's.
context: ?*anyopaque = null,

/// A filter that excludes nothing, which is what a watch has unless the
/// caller says otherwise.
pub const none: Filter = .{};

/// Whether this filter can exclude anything at all. The backends ask
/// first, so a watch without a filter does no work for one.
pub fn isEmpty(f: Filter) bool {
    return f.ignore.len == 0 and f.allow == null;
}

/// A copy owning its pattern list, for a backend that keeps a filter past
/// the `add` that was given it.
pub fn dupe(f: Filter, gpa: Allocator) Allocator.Error!Filter {
    if (f.ignore.len == 0) return .{ .ignore = &.{}, .allow = f.allow, .context = f.context };

    const patterns = try gpa.alloc([]const u8, f.ignore.len);
    var filled: usize = 0;
    errdefer {
        for (patterns[0..filled]) |pattern| gpa.free(pattern);
        gpa.free(patterns);
    }
    for (f.ignore, patterns) |source, *slot| {
        slot.* = try gpa.dupe(u8, source);
        filled += 1;
    }
    return .{ .ignore = patterns, .allow = f.allow, .context = f.context };
}

/// Releases a copy made by `dupe`.
pub fn deinit(f: *Filter, gpa: Allocator) void {
    for (f.ignore) |pattern| gpa.free(pattern);
    if (f.ignore.len != 0) gpa.free(f.ignore);
    f.* = .none;
}

/// Whether `path` is outside the part of `root` this watch is about.
///
/// The root itself is never excluded: it is what the caller asked for.
/// Everything below it is tested one ancestor at a time, closest to the
/// root first, so a directory that is excluded takes its whole subtree
/// with it whether or not the backend ever sees the subtree.
pub fn excludes(f: Filter, root: []const u8, path: []const u8) bool {
    if (f.isEmpty()) return false;
    if (path.len <= root.len) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (!isSep(path[root.len])) return false;

    const relative = path[root.len + 1 ..];
    var end: usize = 0;
    while (end < relative.len) {
        end = if (std.mem.indexOfAnyPos(u8, relative, end + 1, separators)) |next|
            next
        else
            relative.len;
        if (f.excludesOne(relative[0..end], path[0 .. root.len + 1 + end])) return true;
    }
    return false;
}

/// Whether one ancestor -- relative to the root, and absolute -- is
/// excluded.
fn excludesOne(f: Filter, relative: []const u8, absolute: []const u8) bool {
    for (f.ignore) |pattern| {
        if (pattern.len == 0) continue;
        const subject = if (std.fs.path.isAbsolute(pattern)) absolute else relative;
        if (matches(pattern, subject)) return true;
        // A pattern naming no directory is about the name alone, so that
        // one written once excludes the thing wherever it turns up.
        if (std.mem.indexOfAny(u8, pattern, separators) == null and
            matches(pattern, std.fs.path.basename(subject))) return true;
    }
    if (f.allow) |allow| return !allow(f.context, absolute);
    return false;
}

/// The separators a path can be spelled with. Windows takes either;
/// everywhere else a backslash is an ordinary character in a name.
const separators: []const u8 = if (builtin.os.tag == .windows) "\\/" else "/";

fn isSep(c: u8) bool {
    return std.mem.indexOfScalar(u8, separators, c) != null;
}

/// Whether `pattern` matches `name`, with `*` and `?` stopping at a
/// separator.
///
/// Iterative with one backtracking point, which is all a pattern of this
/// shape needs: there is never more than one `*` to reconsider, because
/// reconsidering the latest is the same as reconsidering any earlier one.
fn matches(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var star_n: usize = 0;

    while (n < name.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    star = p;
                    star_n = n;
                    p += 1;
                    continue;
                },
                '?' => if (!isSep(name[n])) {
                    p += 1;
                    n += 1;
                    continue;
                },
                else => if (pattern[p] == name[n] or (isSep(pattern[p]) and isSep(name[n]))) {
                    p += 1;
                    n += 1;
                    continue;
                },
            }
        }
        const resume_at = star orelse return false;
        // The `*` swallows one more character, unless that character is a
        // separator: a wildcard names an entry, not a path.
        if (isSep(name[star_n])) return false;
        star_n += 1;
        n = star_n;
        p = resume_at + 1;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const testing = std.testing;

fn sep(comptime path: []const u8) []const u8 {
    if (builtin.os.tag != .windows) return path;
    comptime var buffer: [path.len]u8 = undefined;
    comptime for (path, &buffer) |c, *slot| {
        slot.* = if (c == '/') '\\' else c;
    };
    const final = buffer;
    return &final;
}

test "an empty filter excludes nothing" {
    const f: Filter = .none;
    try testing.expect(f.isEmpty());
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a/b.txt")));
}

test "a name pattern excludes it at any depth, and everything below it" {
    const f: Filter = .{ .ignore = &.{"node_modules"} };
    try testing.expect(f.excludes(sep("/w"), sep("/w/node_modules")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/node_modules/x/y.js")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/a/node_modules/x")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/src/main.zig")));
    // The root is what the caller asked for and is never excluded.
    try testing.expect(!f.excludes(sep("/w/node_modules"), sep("/w/node_modules")));
}

test "a pattern holding a separator is the whole relative path" {
    const f: Filter = .{ .ignore = &.{sep("build/out")} };
    try testing.expect(f.excludes(sep("/w"), sep("/w/build/out")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/build/out/app")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/build/src")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a/build/out")));
}

test "a glob matches within one component and not across a separator" {
    const f: Filter = .{ .ignore = &.{ "*.tmp", sep("cache/*") } };
    try testing.expect(f.excludes(sep("/w"), sep("/w/a.tmp")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/deep/a.tmp")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a.txt")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/cache/one")));
    // `cache/*` names the entries of `cache`, and the ancestor rule is
    // what carries the exclusion further down rather than the glob.
    try testing.expect(f.excludes(sep("/w"), sep("/w/cache/one/two")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/deep/cache/one")));
}

test "a question mark is exactly one character" {
    const f: Filter = .{ .ignore = &.{"a?.txt"} };
    try testing.expect(f.excludes(sep("/w"), sep("/w/ab.txt")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/abc.txt")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a.txt")));
}

test "an absolute pattern is matched against the absolute path" {
    const f: Filter = .{ .ignore = &.{sep("/w/a/b")} };
    try testing.expect(f.excludes(sep("/w"), sep("/w/a/b")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/a/b/c")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a/c")));
}

test "the predicate is asked about every ancestor" {
    const rule = struct {
        fn allow(context: ?*anyopaque, path: []const u8) bool {
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
            return std.mem.indexOf(u8, path, "private") == null;
        }
    };
    var calls: usize = 0;
    const f: Filter = .{ .allow = rule.allow, .context = &calls };

    try testing.expect(f.excludes(sep("/w"), sep("/w/private")));
    // Excluding the directory excludes the tree under it, which the
    // predicate never has to say a second time.
    try testing.expect(f.excludes(sep("/w"), sep("/w/private/deep/a.txt")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/public/a.txt")));
    try testing.expect(calls > 0);
}

test "a copy owns its patterns" {
    const gpa = testing.allocator;
    var source: [1][]const u8 = undefined;
    {
        const owned = try gpa.dupe(u8, "target");
        defer gpa.free(owned);
        source[0] = owned;

        var copy = try (Filter{ .ignore = &source }).dupe(gpa);
        defer copy.deinit(gpa);
        try testing.expect(copy.excludes(sep("/w"), sep("/w/target/a")));
        // The original list and its strings are gone after this block;
        // the copy still answers.
        try testing.expect(copy.ignore[0].ptr != owned.ptr);
    }
}
