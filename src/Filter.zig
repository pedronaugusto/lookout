//! Which paths under a watch the caller wants, and which are not worth
//! watching at all.
//!
//! A filter is three things a caller can combine: a list of patterns
//! naming what to leave out, a list naming what to keep and nothing
//! else, and a predicate of their own for everything a pattern cannot
//! say. All three answer the same question -- is this path part of the
//! watch -- and all three are asked about every ancestor of a path, so
//! excluding a directory excludes everything below it without naming any
//! of it.
//!
//! Where lookout does the recursion itself -- `inotify`, `kqueue` and
//! `poll` -- an excluded directory is never opened and never registered,
//! so it costs neither a kernel watch nor a descriptor. Where the kernel
//! recurses -- FSEvents and `ReadDirectoryChangesW` -- the work is the
//! kernel's and the filter can only save the caller the event. That
//! difference is `lookout.prunesIgnored`.
//!
//! Every comparison here is the file system's: on a volume that folds
//! case, `*.TMP` excludes `notes.tmp`. See `path.folds_case`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const path = @import("path.zig");

const Filter = @This();

/// Patterns naming what this watch is not about, matched against each
/// path below the watch root.
///
/// A pattern is matched against the path relative to the watch root,
/// spelled with the platform's separator, unless it is itself absolute,
/// in which case it is matched against the absolute path. Four rules,
/// and nothing else:
///
/// * `*` matches any run of characters within one path component, and
///   `?` matches exactly one. Neither crosses a separator.
/// * `**` matches any run of characters, separators included, so
///   `build/**` is everything below `build`. Between two separators it
///   also matches no directory at all, so `src/**/*.zig` covers
///   `src/main.zig` as well as `src/deep/main.zig`.
/// * A pattern holding no separator is also matched against the final
///   component alone, so `node_modules` excludes one at any depth and
///   `*.tmp` excludes the temporary files wherever they are written.
/// * A pattern that matches a directory excludes everything below it,
///   because every ancestor of a path is tested as well as the path.
///
/// Borrowed only for the duration of `lookout.Watcher.add`, which copies
/// what it keeps.
ignore: []const []const u8 = &.{},

/// Patterns naming what this watch *is* about, matched by the same four
/// rules. Empty, the default, means everything the other two allow.
///
/// A path is kept when it matches one of these, and a directory is kept
/// when a pattern could still match something inside it -- otherwise
/// `only = &.{"src/**/*.zig"}` would exclude `src` and take the files
/// under it with it. So an include list narrows the events without
/// narrowing the walk further than it has to.
///
/// `ignore` wins: a path named by both is excluded.
only: []const []const u8 = &.{},

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
    return f.ignore.len == 0 and f.only.len == 0 and f.allow == null;
}

/// A copy owning its pattern lists, for a backend that keeps a filter
/// past the `add` that was given it.
pub fn dupe(f: Filter, gpa: Allocator) Allocator.Error!Filter {
    const ignore = try dupeList(f.ignore, gpa);
    errdefer freeList(ignore, gpa);
    const only = try dupeList(f.only, gpa);
    return .{ .ignore = ignore, .only = only, .allow = f.allow, .context = f.context };
}

fn dupeList(list: []const []const u8, gpa: Allocator) Allocator.Error![]const []const u8 {
    if (list.len == 0) return &.{};
    const patterns = try gpa.alloc([]const u8, list.len);
    var filled: usize = 0;
    errdefer {
        for (patterns[0..filled]) |pattern| gpa.free(pattern);
        gpa.free(patterns);
    }
    for (list, patterns) |source, *slot| {
        slot.* = try gpa.dupe(u8, source);
        filled += 1;
    }
    return patterns;
}

fn freeList(list: []const []const u8, gpa: Allocator) void {
    for (list) |pattern| gpa.free(pattern);
    if (list.len != 0) gpa.free(list);
}

/// Releases a copy made by `dupe`.
pub fn deinit(f: *Filter, gpa: Allocator) void {
    freeList(f.ignore, gpa);
    freeList(f.only, gpa);
    f.* = .none;
}

/// Whether `subject` is outside the part of `root` this watch is about,
/// so that no event for it is reported.
///
/// The root itself is never excluded: it is what the caller asked for.
/// Everything below it is tested one ancestor at a time, closest to the
/// root first, so a directory that is excluded takes its whole subtree
/// with it whether or not the backend ever sees the subtree.
pub fn excludes(f: Filter, root: []const u8, subject: []const u8) bool {
    return f.outside(root, subject, .report);
}

/// Whether a directory is so far outside the watch that lookout need not
/// look inside it at all.
///
/// The same answer as `excludes` for everything but an include list,
/// where the two differ and have to: `only = &.{"src/**/*.zig"}` reports
/// no event for `src/deep`, and lookout still has to walk into it to
/// find the files that were asked for. This is the question the
/// backends that recurse themselves ask before registering a directory,
/// and `excludes` is the one every backend asks before reporting a path.
pub fn prunes(f: Filter, root: []const u8, subject: []const u8) bool {
    return f.outside(root, subject, .walk);
}

/// Which of the two questions is being asked. They differ only for
/// `only`, and only about the path itself: every ancestor above it is a
/// directory on the way either way.
const Purpose = enum { report, walk };

fn outside(f: Filter, root: []const u8, subject: []const u8, purpose: Purpose) bool {
    if (f.isEmpty()) return false;
    const rest = path.relative(root, subject) orelse return false;
    if (rest.len == 0) return false;
    // `rest` is a suffix of `subject`, which is what lets one ancestor be
    // spelled both ways without joining anything.
    const base = subject.len - rest.len;

    var end: usize = 0;
    while (end < rest.len) {
        end = if (std.mem.indexOfAnyPos(u8, rest, end + 1, path.separators)) |next|
            next
        else
            rest.len;
        const relative = rest[0..end];
        const absolute = subject[0 .. base + end];
        if (f.ignores(relative, absolute)) return true;
        if (f.only.len != 0) {
            const itself = end == rest.len;
            const enough: Purpose = if (itself) purpose else .walk;
            if (!wanted(f.only, relative, absolute, enough)) return true;
        }
        if (f.allow) |allow| {
            if (!allow(f.context, absolute)) return true;
        }
    }
    return false;
}

/// Whether one ancestor -- relative to the root, and absolute -- is named
/// by the ignore list.
fn ignores(f: Filter, relative: []const u8, absolute: []const u8) bool {
    for (f.ignore) |pattern| {
        if (pattern.len == 0) continue;
        const subject = if (std.fs.path.isAbsolute(pattern)) absolute else relative;
        if (matches(pattern, subject)) return true;
        // A pattern naming no directory is about the name alone, so that
        // one written once excludes the thing wherever it turns up.
        if (std.mem.indexOfAny(u8, pattern, path.separators) == null and
            matches(pattern, std.fs.path.basename(subject))) return true;
    }
    return false;
}

/// Whether the include list has anything to say about this ancestor:
/// for a path being reported, that a pattern names it; for a directory
/// being walked into, that one names it or could name something inside
/// it.
fn wanted(only: []const []const u8, relative: []const u8, absolute: []const u8, purpose: Purpose) bool {
    for (only) |pattern| {
        if (pattern.len == 0) continue;
        const rooted = std.fs.path.isAbsolute(pattern);
        const subject = if (rooted) absolute else relative;
        if (matches(pattern, subject)) return true;
        const bare = !rooted and std.mem.indexOfAny(u8, pattern, path.separators) == null;
        // A pattern naming no directory is about the name alone, so it
        // can turn up at any depth -- which makes every directory one
        // on the way to it.
        if (bare and matches(pattern, std.fs.path.basename(subject))) return true;
        if (purpose == .walk and (bare or leadsTo(pattern, subject))) return true;
    }
    return false;
}

/// Whether `subject` is a proper prefix of something `pattern` could
/// match: the directory on the way to the files an include list asked
/// for.
fn leadsTo(pattern: []const u8, subject: []const u8) bool {
    var patterns = std.mem.splitAny(u8, pattern, path.separators);
    var subjects = std.mem.splitAny(u8, subject, path.separators);
    while (subjects.next()) |component| {
        const want = patterns.next() orelse return false;
        // Past a `**` the pattern can reach any depth, so every
        // directory from here down is on the way.
        if (std.mem.eql(u8, want, "**")) return true;
        if (!matches(want, component)) return false;
    }
    return patterns.next() != null;
}

/// Whether `pattern` matches `name`.
///
/// Recursive, and only ever at a `*`: the loops inside walk the name,
/// and the depth is therefore the number of wildcards in the pattern
/// rather than the length of either string.
fn matches(pattern: []const u8, name: []const u8) bool {
    return matchFrom(.init(pattern), .init(name));
}

fn matchFrom(pattern: path.Folder, name: path.Folder) bool {
    var p = pattern;
    var n = name;
    while (true) {
        const want = p.next() orelse return n.peek() == null;
        switch (want) {
            '*' => {
                var after = p;
                if (after.peek() == '*') {
                    _ = after.next();
                    // `**` crosses separators. Between two of them it
                    // also stands for no directory at all, so the
                    // separator that follows it is optional.
                    var skipped = after;
                    if (skipped.peek() == '/') _ = skipped.next();
                    if (matchFrom(after, n) or matchFrom(skipped, n)) return true;
                    while (n.next() != null) {
                        if (matchFrom(after, n) or matchFrom(skipped, n)) return true;
                    }
                    return false;
                }
                // A single `*` names an entry, not a path, so it stops
                // at a separator.
                if (matchFrom(after, n)) return true;
                while (n.peek()) |c| {
                    if (c == '/') return false;
                    _ = n.next();
                    if (matchFrom(after, n)) return true;
                }
                return false;
            },
            '?' => {
                const c = n.next() orelse return false;
                if (c == '/') return false;
            },
            else => {
                const c = n.next() orelse return false;
                if (c != want) return false;
            },
        }
    }
}

const testing = std.testing;
const builtin = @import("builtin");

fn sep(comptime p: []const u8) []const u8 {
    if (builtin.os.tag != .windows) return p;
    comptime var buffer: [p.len]u8 = undefined;
    comptime for (p, &buffer) |c, *slot| {
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

test "two stars cross a separator and stand for no directory at all" {
    const f: Filter = .{ .ignore = &.{sep("build/**")} };
    try testing.expect(f.excludes(sep("/w"), sep("/w/build/a.o")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/build/deep/deeper/a.o")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/src/a.zig")));

    const g: Filter = .{ .ignore = &.{sep("src/**/*.tmp")} };
    try testing.expect(g.excludes(sep("/w"), sep("/w/src/a.tmp")));
    try testing.expect(g.excludes(sep("/w"), sep("/w/src/deep/a.tmp")));
    try testing.expect(g.excludes(sep("/w"), sep("/w/src/deep/deeper/a.tmp")));
    try testing.expect(!g.excludes(sep("/w"), sep("/w/src/a.zig")));
    try testing.expect(!g.excludes(sep("/w"), sep("/w/other/a.tmp")));
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

test "an include list keeps what it names and the way to it" {
    const f: Filter = .{ .only = &.{sep("src/**/*.zig")} };
    // The files asked for, at any depth.
    try testing.expect(!f.excludes(sep("/w"), sep("/w/src/main.zig")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/src/deep/main.zig")));
    // The directories on the way are not events of their own, and the
    // walk still has to reach them.
    try testing.expect(!f.prunes(sep("/w"), sep("/w/src")));
    try testing.expect(!f.prunes(sep("/w"), sep("/w/src/deep")));
    try testing.expect(f.prunes(sep("/w"), sep("/w/docs")));
    // Everything else.
    try testing.expect(f.excludes(sep("/w"), sep("/w/src/notes.txt")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/docs")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/docs/a.zig")));
}

test "an include list and an ignore list together, with the ignore winning" {
    const f: Filter = .{
        .only = &.{"*.zig"},
        .ignore = &.{"vendor"},
    };
    try testing.expect(!f.excludes(sep("/w"), sep("/w/main.zig")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/main.txt")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/vendor")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/vendor/main.zig")));
    // A bare name can turn up at any depth, so no directory is pruned
    // for it -- but a deep .zig file is still reported.
    try testing.expect(!f.prunes(sep("/w"), sep("/w/deep")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/deep/main.zig")));
    try testing.expect(f.prunes(sep("/w"), sep("/w/vendor")));
}

test "the predicate is asked about every ancestor" {
    const rule = struct {
        fn allow(context: ?*anyopaque, p: []const u8) bool {
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
            return std.mem.indexOf(u8, p, "private") == null;
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

test "a pattern is matched the way the file system compares names" {
    const f: Filter = .{ .ignore = &.{"*.TMP"} };
    try testing.expectEqual(path.folds_case, f.excludes(sep("/w"), sep("/w/notes.tmp")));

    const g: Filter = .{ .ignore = &.{"Node_Modules"} };
    try testing.expectEqual(path.folds_case, g.excludes(sep("/w"), sep("/w/node_modules/a.js")));
}

test "a copy owns its patterns" {
    const gpa = testing.allocator;
    var ignore: [1][]const u8 = undefined;
    var only: [1][]const u8 = undefined;
    {
        const owned_ignore = try gpa.dupe(u8, "target");
        defer gpa.free(owned_ignore);
        const owned_only = try gpa.dupe(u8, "*.zig");
        defer gpa.free(owned_only);
        ignore[0] = owned_ignore;
        only[0] = owned_only;

        var copy = try (Filter{ .ignore = &ignore, .only = &only }).dupe(gpa);
        defer copy.deinit(gpa);
        try testing.expect(copy.excludes(sep("/w"), sep("/w/target/a")));
        try testing.expect(!copy.excludes(sep("/w"), sep("/w/a.zig")));
        // The original lists and their strings are gone after this
        // block; the copy still answers.
        try testing.expect(copy.ignore[0].ptr != owned_ignore.ptr);
        try testing.expect(copy.only[0].ptr != owned_only.ptr);
    }
}
