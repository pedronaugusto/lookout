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
//! An excluded path is treated exactly as a path outside the watch. A
//! rename between a name the filter keeps and one it excludes is
//! reported as a rename in or out of the watch would be: `created` at the
//! kept new name, `removed` at the kept old one. See
//! `lookout.pairsRenames`.
//!
//! On Apple and Windows targets, comparisons fold ASCII and Latin-1 case
//! and composition, so `*.TMP` excludes `notes.tmp`. Other Unicode
//! scripts are compared as written. See `path.folds_case`.

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
/// It is asked about a directory before that directory is registered,
/// as the patterns are, so where lookout does the recursion a directory
/// it excludes is never opened and never costs a kernel watch or a
/// descriptor. A predicate backed by a repository's ignore rules prunes
/// the ignored trees exactly as `ignore` would. It is not told whether
/// the path is a directory; a rule that applies only to directories
/// has to look.
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
    const ignore = try dupeList(gpa, f.ignore);
    errdefer freeList(gpa, ignore);
    const only = try dupeList(gpa, f.only);
    return .{ .ignore = ignore, .only = only, .allow = f.allow, .context = f.context };
}

fn dupeList(gpa: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
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

fn freeList(gpa: Allocator, list: []const []const u8) void {
    for (list) |pattern| gpa.free(pattern);
    if (list.len != 0) gpa.free(list);
}

/// Releases a copy made by `dupe`.
pub fn deinit(f: *Filter, gpa: Allocator) void {
    freeList(gpa, f.ignore);
    freeList(gpa, f.only);
    f.* = undefined;
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
        end = if (std.mem.findAnyPos(u8, rest, end + 1, path.separators)) |next|
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
///
/// The pattern is matched against `subject` as against a name, until the
/// subject runs out; it leads on when what is left of the pattern can
/// begin with a separator. A `**` met on the way can, wherever it is
/// written -- `a**/c` crosses `ax/y` to reach `ax/y/c` -- so from a `**`
/// every directory is on the way.
fn leadsTo(pattern: []const u8, subject: []const u8) bool {
    return matchFrom(.prefix, .init(pattern), .init(subject));
}

/// Whether `pattern` matches `name`.
fn matches(pattern: []const u8, name: []const u8) bool {
    return matchFrom(.whole, .init(pattern), .init(name));
}

/// Whether the pattern has to match the whole name, or only a name that
/// goes on past this one as a directory does.
const Extent = enum { whole, prefix };

/// Whether what is left of a pattern can match something that begins
/// with a separator: a `*` can match nothing first, and a `**` can match
/// the separator itself.
fn opensDirectory(pattern: path.Folder) bool {
    var p = pattern;
    while (p.next()) |c| switch (c) {
        '/' => return true,
        '*' => if (p.peek() == '*') return true,
        else => return false,
    };
    return false;
}

/// Where a wildcard was met: the pattern just after it, and the name
/// where the next attempt resumes once the wildcard takes one more
/// character.
const Resume = struct { pattern: path.Folder, name: path.Folder };

/// The matcher, in time proportional to the pattern times the name
/// however many wildcards the pattern holds: the name is a string anyone
/// who can write in the watched tree chooses, and this runs for every
/// event on the watcher's thread.
///
/// A mismatch never goes back further than two places: the last `*`, and
/// the last `**`. The pieces of pattern between wildcards are each
/// placed as early in the name as they fit, and the earliest is never
/// worse for what follows -- a later `*` or `**` can take up whatever an
/// earlier placement left. A `*` cannot take a separator, so one that
/// reaches a separator gives up to the last `**`, which can; and once
/// the last `**` has taken the rest of the name, nothing earlier could
/// do better.
fn matchFrom(comptime extent: Extent, pattern: path.Folder, name: path.Folder) bool {
    var p = pattern;
    var n = name;
    var star: ?Resume = null;
    var deep: ?Resume = null;
    while (true) {
        const mismatch = step: {
            if (extent == .prefix and n.peek() == null and n.settled()) {
                if (opensDirectory(p)) return true;
                break :step true;
            }
            const want = p.next() orelse {
                if (n.peek() == null) return true;
                break :step true;
            };
            switch (want) {
                '*' => if (p.peek() == '*') {
                    // The rest of the name, a separator and whatever the
                    // rest of the pattern wants are all one run.
                    if (extent == .prefix) return true;
                    _ = p.next();
                    // `**` crosses separators. Between two of them it
                    // also stands for no directory at all, so the
                    // separator that follows it is optional -- and a run
                    // that may end in a separator already covers it.
                    if (p.peek() == '/') _ = p.next();
                    deep = .{ .pattern = p, .name = n };
                    star = null;
                } else {
                    star = .{ .pattern = p, .name = n };
                },
                '?' => {
                    const c = n.next() orelse break :step true;
                    if (c == '/') break :step true;
                },
                else => {
                    const c = n.next() orelse break :step true;
                    if (c != want) break :step true;
                },
            }
            break :step false;
        };
        if (!mismatch) continue;
        // A single `*` names an entry, not a path, so it stops at a
        // separator.
        if (star) |*s| {
            if (s.name.next()) |c| if (c != '/') {
                p = s.pattern;
                n = s.name;
                continue;
            };
            star = null;
        }
        if (deep) |*d| {
            if (d.name.next() != null) {
                p = d.pattern;
                n = d.name;
                continue;
            }
        }
        return false;
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

test "two stars inside a name lead through the directories they cross" {
    // `**` crosses separators wherever it is written, so `a**/c` names
    // `ax/y/c`; the walk has to reach it through `ax` and `ax/y`.
    const f: Filter = .{ .only = &.{sep("a**/c")} };
    try testing.expect(!f.excludes(sep("/w"), sep("/w/ax/y/c")));
    try testing.expect(!f.prunes(sep("/w"), sep("/w/ax")));
    try testing.expect(!f.prunes(sep("/w"), sep("/w/ax/y")));
    try testing.expect(f.prunes(sep("/w"), sep("/w/b")));
    // A single star stays inside its name, and a name it cannot reach
    // past is pruned.
    const one: Filter = .{ .only = &.{sep("a*c/d")} };
    try testing.expect(!one.prunes(sep("/w"), sep("/w/abc")));
    try testing.expect(one.prunes(sep("/w"), sep("/w/ab")));
    try testing.expect(one.prunes(sep("/w"), sep("/w/abc/x")));
    // A star that can match nothing before the separator still leads on.
    const empty: Filter = .{ .only = &.{sep("ab*/d")} };
    try testing.expect(!empty.prunes(sep("/w"), sep("/w/ab")));
    // What the fuzzer found first: two stars in the middle of a name, after
    // a whole name that does not hold them.
    const found: Filter = .{ .only = &.{sep("a*?a/**a**/")} };
    try testing.expect(!found.excludes(sep("/w"), sep("/w/aba/b/a.b")));
    try testing.expect(!found.prunes(sep("/w"), sep("/w/aba/b")));
}

test "a name built against the wildcards costs no more than its length" {
    // Each `*` once tried every place in the name for the rest of the
    // pattern, so k of them cost the name's length to the k-th power: a
    // file named by whoever can write in the tree stalled the watcher for
    // most of a minute on `*a*a*a*a*b`. A run of `a` up to a component's
    // limit is the worst case, and a path of many is the worst for `**`.
    // Spelled at run time: these are too long to respell at compile time.
    const root = sep("/w");
    var name_buf: [512]u8 = undefined;
    const name = spellRun(&name_buf, root, 1, 255);
    var deep_buf: [4096]u8 = undefined;
    const deep = spellRun(&deep_buf, root, 60, 60);
    deep_buf[deep.len] = 'a';
    const deep_file = deep_buf[0 .. deep.len + 1];
    inline for (.{ "*a*a*a*a*a*a*a*a*b", "*a*a*a*a*a*a*a*a*" }, .{ false, true }) |pattern, expected| {
        const f: Filter = .{ .ignore = &.{pattern} };
        try testing.expectEqual(expected, f.excludes(root, name));
    }
    const g: Filter = .{ .ignore = &.{"**a**a**a**a**a**a**b"} };
    try testing.expect(!g.excludes(root, deep_file));
    const h: Filter = .{ .only = &.{sep("**a*a*a*a*a*a*/b")} };
    try testing.expect(h.excludes(root, deep_file));
}

/// `root`, then `count` components of `len` letters `a`, each after a
/// separator.
fn spellRun(buf: []u8, root: []const u8, count: usize, len: usize) []u8 {
    @memcpy(buf[0..root.len], root);
    var end = root.len;
    for (0..count) |_| {
        buf[end] = std.fs.path.sep;
        @memset(buf[end + 1 ..][0..len], 'a');
        end += 1 + len;
    }
    return buf[0..end];
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
