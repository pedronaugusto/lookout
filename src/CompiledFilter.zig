//! A `Filter` a watch keeps: its pattern lists copied, and compiled into
//! sweep sets that answer for any path in one pass over it, whatever the
//! number of patterns.
//!
//! The patterns and every path asked about are folded first the way the
//! file system compares names (`path.Folder`), so a pattern is matched as
//! `path.eql` compares. A query moves the sets' caches: one thread asks at
//! a time, which is the watcher's own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const sweep = @import("sweep");

const Filter = @import("Filter.zig");
const path = @import("path.zig");

const CompiledFilter = @This();

/// `Filter.ignore`, copied as the caller wrote it: checkpoints and
/// baselines record the patterns themselves.
ignore: []const []const u8 = &.{},
/// `Filter.only`, copied as the caller wrote it.
only: []const []const u8 = &.{},
/// `Filter.allow`.
allow: ?*const fn (context: ?*anyopaque, path: []const u8) bool = null,
/// `Filter.context`.
context: ?*anyopaque = null,
/// Private: the compiled patterns, or null when there are none.
matcher: ?*Matcher = null,
/// Private: the allocator the copies are owned in, or null for `none`.
gpa: ?Allocator = null,

/// The filter of a watch that keeps everything.
pub const none: CompiledFilter = .{};

/// Why a filter cannot be compiled: a pattern git would refuse
/// (`InvalidPattern`) or one past sweep's length (`PatternTooLong`).
pub const Error = errors: {
    // A block, so a linter reading the declaration sees a type.
    break :errors Allocator.Error || sweep.PatternError;
};

/// Copies and compiles `filter`; `deinit` releases it.
pub fn compile(gpa: Allocator, filter: Filter) Error!CompiledFilter {
    const ignore = try dupeList(gpa, filter.ignore);
    errdefer freeList(gpa, ignore);
    const only = try dupeList(gpa, filter.only);
    errdefer freeList(gpa, only);
    const matcher = try Matcher.create(gpa, ignore, only);
    return .{ .ignore = ignore, .only = only, .allow = filter.allow, .context = filter.context, .matcher = matcher, .gpa = gpa };
}

/// `compile`, for a filter whose patterns have compiled once already: a
/// second copy for another registration of the same watch. Only memory
/// can fail.
pub fn recompile(gpa: Allocator, filter: Filter) Allocator.Error!CompiledFilter {
    return compile(gpa, filter) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // unreachable: the caller compiled these exact patterns before
        error.InvalidPattern, error.PatternTooLong => unreachable,
    };
}

/// The filter this was compiled from, borrowing this copy's patterns.
pub fn spec(c: *const CompiledFilter) Filter {
    return .{ .ignore = c.ignore, .only = c.only, .allow = c.allow, .context = c.context };
}

/// Releases a compiled filter. `none` owns nothing.
pub fn deinit(c: *CompiledFilter) void {
    const gpa = c.gpa orelse return;
    if (c.matcher) |m| m.destroy(gpa);
    freeList(gpa, c.ignore);
    freeList(gpa, c.only);
    c.* = undefined;
}

/// Whether this filter keeps every path. The backends ask first, so a
/// watch without a filter does no work for one.
pub fn isEmpty(c: *const CompiledFilter) bool {
    return c.ignore.len == 0 and c.only.len == 0 and c.allow == null;
}

/// Whether `subject` is outside the part of `root` this watch is about,
/// so that no event for it is reported.
///
/// The root itself is never excluded: it is what the caller asked for.
/// Below it, a path is excluded when an `ignore` pattern or `allow` says
/// so of the path or of any ancestor below the root, or when `only` has
/// patterns and none of them matches the path.
pub fn excludes(c: *const CompiledFilter, root: []const u8, subject: []const u8) bool {
    return c.outside(root, subject, .report);
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
pub fn prunes(c: *const CompiledFilter, root: []const u8, subject: []const u8) bool {
    return c.outside(root, subject, .walk);
}

/// Which of the two questions is being asked. They differ only for
/// `only`: a directory on the way to what it names is walked, and not
/// reported.
const Purpose = enum { report, walk };

fn outside(c: *const CompiledFilter, root: []const u8, subject: []const u8, purpose: Purpose) bool {
    if (c.isEmpty()) return false;
    const rest = path.relative(root, subject) orelse return false;
    if (rest.len == 0) return false;
    // `rest` is a suffix of `subject`, which is what lets one ancestor be
    // spelled both ways without joining anything.
    const base = subject.len - rest.len;
    if (c.matcher) |m| if (m.outside(subject, base, purpose)) return true;
    const allow = c.allow orelse return false;
    var end: usize = 0;
    while (end < rest.len) {
        end = std.mem.findAnyPos(u8, rest, end + 1, path.separators) orelse rest.len;
        if (!allow(c.context, subject[0 .. base + end])) return true;
    }
    return false;
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

/// How every pattern is read: git's syntax over UTF-8 scalars, a pattern
/// with no separator at any depth. On Windows `\` is a separator, which
/// folding turns into `/`, and so no escape.
const pattern_options: sweep.Options = .{
    .syntax = .{ .unit = .utf8, .escape = builtin.target.os.tag != .windows },
    .anywhere = true,
};

/// The longest path a query folds. A path the operating system gives is
/// never longer; a longer one is let through unmatched, and the event
/// reported.
const max_subject = std.Io.Dir.max_path_bytes;

/// What folding can make of `n` bytes: a Latin-1 letter, two bytes, comes
/// out as its base letter and a combining accent, three.
fn foldedCapacity(n: usize) usize {
    return n + n / 2 + 1;
}

/// The patterns, compiled: one set per list and per anchoring, each with
/// the cache a query runs on.
const Matcher = struct {
    /// Indexed by `Which`; null for a list with no such patterns.
    parts: [4]?Part,
    /// Where a path is folded, on a target that folds; empty elsewhere.
    scratch: []u8,

    const Which = enum(u2) { ignore, ignore_absolute, only, only_absolute };

    const Part = struct {
        set: sweep.Set,
        cache: sweep.Set.Cache,
    };

    /// The smallest cache sweep takes: a filter holds few patterns, and a
    /// full cache only clears, it never changes an answer.
    const cache_options: sweep.Set.Cache.Options = .{ .capacity = 1 << 16 };

    /// Null when no list holds a pattern.
    fn create(gpa: Allocator, ignore: []const []const u8, only: []const []const u8) Error!?*Matcher {
        var builders: [4]?sweep.Set.Builder = @splat(null);
        defer for (&builders) |*b| if (b.*) |*builder| builder.deinit();
        var fold_buffer: std.ArrayList(u8) = .empty;
        defer fold_buffer.deinit(gpa);
        for ([_][]const []const u8{ ignore, only }, [_]Which{ .ignore, .only }) |list, relative| {
            for (list) |pattern| {
                if (pattern.len == 0) continue;
                const which: Which = if (std.Io.Dir.path.isAbsolute(pattern)) @fromBackingInt(@backingInt(relative) + 1) else relative;
                const slot = &builders[@backingInt(which)];
                if (slot.* == null) slot.* = .init(gpa);
                try fold_buffer.resize(gpa, foldedCapacity(pattern.len));
                const folded = fold(fold_buffer.items, pattern);
                _ = slot.*.?.add(folded, .{ .options = pattern_options }) catch |err| switch (err) {
                    // unreachable: every entry is read with one separator
                    error.SeparatorMismatch => unreachable,
                    else => |e| return e,
                };
            }
        }
        for (builders) |b| {
            if (b != null) break;
        } else return null;

        const m = try gpa.create(Matcher);
        errdefer gpa.destroy(m);
        m.* = .{ .parts = @splat(null), .scratch = &.{} };
        errdefer m.release(gpa);
        if (path.folds_case) m.scratch = try gpa.alloc(u8, foldedCapacity(max_subject));
        for (&builders, &m.parts) |*b, *part| {
            const builder = if (b.*) |*builder| builder else continue;
            // Built aside: a `try` inside the literal would mark the slot
            // filled before the set is there. The set is in its place
            // before a cache is made for it, and never moves after.
            const set = try builder.build();
            part.* = .{ .set = set, .cache = undefined };
            const made = &part.*.?;
            made.cache = sweep.Set.Cache.init(gpa, &made.set, cache_options) catch |err| {
                made.set.deinit();
                part.* = null;
                return err;
            };
        }
        return m;
    }

    fn destroy(m: *Matcher, gpa: Allocator) void {
        m.release(gpa);
        gpa.destroy(m);
    }

    fn release(m: *Matcher, gpa: Allocator) void {
        for (&m.parts) |*p| if (p.*) |*part| {
            part.cache.deinit();
            part.set.deinit();
            p.* = null;
        };
        if (m.scratch.len != 0) gpa.free(m.scratch);
        m.scratch = &.{};
    }

    fn find(m: *Matcher, which: Which) ?*Part {
        if (m.parts[@backingInt(which)]) |*p| return p;
        return null;
    }

    /// Whether the patterns put `subject` outside the watch; `subject[base..]`
    /// is the part below the root.
    fn outside(m: *Matcher, subject: []const u8, base: usize, purpose: Purpose) bool {
        // The absolute spelling, folded, and where its part below the root
        // starts: one fold serves both, since a fold goes character by
        // character and `base` is at the start of one.
        var absolute: []const u8 = subject;
        var start: usize = base;
        if (path.folds_case) {
            if (subject.len > max_subject) return false;
            start = fold(m.scratch, subject[0..base]).len;
            absolute = m.scratch[0 .. start + fold(m.scratch[start..], subject[base..]).len];
        }
        const relative = absolute[start..];

        if (m.find(.ignore)) |p| {
            var steps = p.set.ancestors(&p.cache, relative, .file);
            while (steps.next()) |step| if (step.last != null) return true;
        }
        if (m.find(.ignore_absolute)) |p| {
            var steps = p.set.ancestors(&p.cache, absolute, .file);
            // The root and what is above it are never tested.
            while (steps.next()) |step| if (step.end > start and step.last != null) return true;
        }
        const only = m.find(.only);
        const only_absolute = m.find(.only_absolute);
        if (only == null and only_absolute == null) return false;
        // The path itself decides: whatever it matches, or leads to, every
        // ancestor leads to as well.
        if (only) |p| {
            if (p.set.any(&p.cache, relative, .file)) return false;
            if (purpose == .walk and p.set.leadsTo(&p.cache, relative)) return false;
        }
        if (only_absolute) |p| {
            if (p.set.any(&p.cache, absolute, .file)) return false;
            if (purpose == .walk and p.set.leadsTo(&p.cache, absolute)) return false;
        }
        return true;
    }
};

/// Writes `text` into `out` as `path.Folder` reads it, each code point in
/// UTF-8 and each byte no encoding produced as itself, and returns the
/// written part. On a target that does not fold, a copy.
fn fold(out: []u8, text: []const u8) []const u8 {
    if (!path.folds_case) {
        @memcpy(out[0..text.len], text);
        return out[0..text.len];
    }
    var folder: path.Folder = .init(text);
    var n: usize = 0;
    while (folder.next()) |cp| {
        if (cp >= path.Folder.raw_base) {
            out[n] = @intCast(cp - path.Folder.raw_base);
            n += 1;
        } else {
            // unreachable: Folder yields only scalars it decoded or folded
            n += std.unicode.utf8Encode(cp, out[n..]) catch unreachable;
        }
    }
    return out[0..n];
}

const testing = std.testing;
const shakedown = @import("shakedown");

fn sep(comptime p: []const u8) []const u8 {
    if (builtin.target.os.tag != .windows) return p;
    comptime var buffer: [p.len]u8 = undefined;
    comptime for (p, &buffer) |ch, *slot| {
        slot.* = if (ch == '/') '\\' else ch;
    };
    const final = buffer;
    return &final;
}

fn expectCompiled(filter: Filter) !CompiledFilter {
    return compile(testing.allocator, filter);
}

test "an empty filter excludes nothing" {
    var f = try expectCompiled(.none);
    defer f.deinit();
    try testing.expect(f.isEmpty());
    try testing.expect(f.matcher == null);
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a/b.txt")));
}

test "a name pattern excludes it at any depth, and everything below it" {
    var f = try expectCompiled(.{ .ignore = &.{"node_modules"} });
    defer f.deinit();
    try testing.expect(f.excludes(sep("/w"), sep("/w/node_modules")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/node_modules/x/y.js")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/a/node_modules/x")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/src/main.zig")));
    // The root is what the caller asked for and is never excluded.
    try testing.expect(!f.excludes(sep("/w/node_modules"), sep("/w/node_modules")));
}

test "a pattern holding a separator is the whole relative path" {
    var f = try expectCompiled(.{ .ignore = &.{sep("build/out")} });
    defer f.deinit();
    try testing.expect(f.excludes(sep("/w"), sep("/w/build/out")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/build/out/app")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/build/src")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a/build/out")));
}

test "a glob matches within one component and not across a separator" {
    var f = try expectCompiled(.{ .ignore = &.{ "*.tmp", sep("cache/*") } });
    defer f.deinit();
    try testing.expect(f.excludes(sep("/w"), sep("/w/a.tmp")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/deep/a.tmp")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a.txt")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/cache/one")));
    // `cache/*` names the entries of `cache`, and the ancestor rule is
    // what carries the exclusion further down rather than the glob.
    try testing.expect(f.excludes(sep("/w"), sep("/w/cache/one/two")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/deep/cache/one")));
}

test "two stars as a whole component cross separators and stand for no directory at all" {
    var f = try expectCompiled(.{ .ignore = &.{sep("build/**")} });
    defer f.deinit();
    try testing.expect(f.excludes(sep("/w"), sep("/w/build/a.o")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/build/deep/deeper/a.o")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/src/a.zig")));

    var g = try expectCompiled(.{ .ignore = &.{sep("src/**/*.tmp")} });
    defer g.deinit();
    try testing.expect(g.excludes(sep("/w"), sep("/w/src/a.tmp")));
    try testing.expect(g.excludes(sep("/w"), sep("/w/src/deep/a.tmp")));
    try testing.expect(g.excludes(sep("/w"), sep("/w/src/deep/deeper/a.tmp")));
    try testing.expect(!g.excludes(sep("/w"), sep("/w/src/a.zig")));
    try testing.expect(!g.excludes(sep("/w"), sep("/w/other/a.tmp")));
}

test "a question mark is exactly one character, and a bracket one of a set" {
    var f = try expectCompiled(.{ .ignore = &.{ "a?.txt", "[0-9]*.log" } });
    defer f.deinit();
    try testing.expect(f.excludes(sep("/w"), sep("/w/ab.txt")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/abc.txt")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a.txt")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/7-run.log")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/run.log")));
}

test "a question mark is one character, not one byte" {
    var f = try expectCompiled(.{ .ignore = &.{"caf?"} });
    defer f.deinit();
    // On a target that folds, the accent of a Latin-1 letter is a
    // character of its own, as `path.eql` reads it.
    try testing.expectEqual(!path.folds_case, f.excludes(sep("/w"), sep("/w/caf\u{e9}")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/caf\u{3b1}")));
}

test "two stars inside a name are one star, as in git" {
    // `**` is a globstar only as a whole component, so `a**/c` is `a*/c`:
    // one directory starting with `a`, then `c`.
    var f = try expectCompiled(.{ .only = &.{sep("a**/c")} });
    defer f.deinit();
    try testing.expect(!f.excludes(sep("/w"), sep("/w/ax/c")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/ax/y/c")));
    try testing.expect(!f.prunes(sep("/w"), sep("/w/ax")));
    try testing.expect(f.prunes(sep("/w"), sep("/w/ax/y")));
    try testing.expect(f.prunes(sep("/w"), sep("/w/b")));
    // A single star stays inside its name, and a name it cannot reach
    // past is pruned.
    var one = try expectCompiled(.{ .only = &.{sep("a*c/d")} });
    defer one.deinit();
    try testing.expect(!one.prunes(sep("/w"), sep("/w/abc")));
    try testing.expect(one.prunes(sep("/w"), sep("/w/ab")));
    try testing.expect(one.prunes(sep("/w"), sep("/w/abc/x")));
    // A star that can match nothing before the separator still leads on.
    var empty = try expectCompiled(.{ .only = &.{sep("ab*/d")} });
    defer empty.deinit();
    try testing.expect(!empty.prunes(sep("/w"), sep("/w/ab")));
}

test "a pattern git refuses is refused by name" {
    for ([_][]const u8{ "[abc", "[[:nope:]]" }) |pattern| {
        try testing.expectError(error.InvalidPattern, compile(testing.allocator, .{ .ignore = &.{pattern} }));
        try testing.expectError(error.InvalidPattern, compile(testing.allocator, .{ .only = &.{pattern} }));
    }
    if (builtin.target.os.tag != .windows) {
        try testing.expectError(error.InvalidPattern, compile(testing.allocator, .{ .ignore = &.{"a\\"} }));
        // An escape makes a wildcard literal.
        var f = try expectCompiled(.{ .ignore = &.{"\\*.tmp"} });
        defer f.deinit();
        try testing.expect(f.excludes("/w", "/w/*.tmp"));
        try testing.expect(!f.excludes("/w", "/w/a.tmp"));
    }
}

test "a name built against the wildcards costs no more than its length" {
    // A backtracking matcher tries every place in the name for the rest of
    // the pattern at each `*`, so k of them cost the name's length to the
    // k-th power: a file named by whoever can write in the tree stalls the
    // watcher. A run of `a` up to a component's limit is the worst case,
    // and a path of many is the worst for `**`. Both stay within the
    // longest path every platform has.
    const root = comptime sep("/w");
    const s = std.Io.Dir.path.sep_str;
    const name = root ++ s ++ shakedown.corpus.repeat("a", 255);
    const deep_file = root ++ shakedown.corpus.repeat(s ++ shakedown.corpus.repeat("a", 60), 15) ++ s ++ "a";
    inline for (.{ "*a*a*a*a*a*a*a*a*b", "*a*a*a*a*a*a*a*a*" }, .{ false, true }) |pattern, expected| {
        var f = try expectCompiled(.{ .ignore = &.{pattern} });
        defer f.deinit();
        try testing.expectEqual(expected, f.excludes(root, name));
    }
    var g = try expectCompiled(.{ .ignore = &.{sep("**/a*a*a*a*a*a*b")} });
    defer g.deinit();
    try testing.expect(!g.excludes(root, deep_file));
    var h = try expectCompiled(.{ .only = &.{sep("**/a*a*a*a*a*a*/b")} });
    defer h.deinit();
    try testing.expect(h.excludes(root, deep_file));
}

test "an absolute pattern is matched against the absolute path below the root" {
    var f = try expectCompiled(.{ .ignore = &.{sep("/w/a/b")} });
    defer f.deinit();
    try testing.expect(f.excludes(sep("/w"), sep("/w/a/b")));
    try testing.expect(f.excludes(sep("/w"), sep("/w/a/b/c")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/a/c")));
    // The root and what is above it are what the caller asked for.
    var above = try expectCompiled(.{ .ignore = &.{sep("/w")} });
    defer above.deinit();
    try testing.expect(!above.excludes(sep("/w/a"), sep("/w/a/b")));
    var kept = try expectCompiled(.{ .only = &.{sep("/w/src/**")} });
    defer kept.deinit();
    try testing.expect(!kept.excludes(sep("/w"), sep("/w/src/a.zig")));
    try testing.expect(kept.excludes(sep("/w"), sep("/w/docs/a.zig")));
    try testing.expect(!kept.prunes(sep("/w"), sep("/w/src")));
    try testing.expect(kept.prunes(sep("/w"), sep("/w/docs")));
}

test "an include list keeps what it names and the way to it" {
    var f = try expectCompiled(.{ .only = &.{sep("src/**/*.zig")} });
    defer f.deinit();
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
    var f = try expectCompiled(.{
        .only = &.{"*.zig"},
        .ignore = &.{"vendor"},
    });
    defer f.deinit();
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
            const calls: *usize = @ptrCast(@alignCast(context.?)); // safe: the test's context is a usize counter
            calls.* += 1;
            return std.mem.find(u8, p, "private") == null;
        }
    };
    var calls: usize = 0;
    var f = try expectCompiled(.{ .allow = rule.allow, .context = &calls });
    defer f.deinit();
    try testing.expect(f.matcher == null);

    try testing.expect(f.excludes(sep("/w"), sep("/w/private")));
    // Excluding the directory excludes the tree under it, which the
    // predicate never has to say a second time.
    try testing.expect(f.excludes(sep("/w"), sep("/w/private/deep/a.txt")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/public/a.txt")));
    try testing.expect(calls > 0);
}

test "a pattern is matched the way the file system compares names" {
    var f = try expectCompiled(.{ .ignore = &.{"*.TMP"} });
    defer f.deinit();
    try testing.expectEqual(path.folds_case, f.excludes(sep("/w"), sep("/w/notes.tmp")));

    var g = try expectCompiled(.{ .ignore = &.{"Node_Modules"} });
    defer g.deinit();
    try testing.expectEqual(path.folds_case, g.excludes(sep("/w"), sep("/w/node_modules/a.js")));

    // A Latin-1 letter written composed in the pattern and decomposed in
    // the name, as a volume that stores it decomposed spells it.
    var h = try expectCompiled(.{ .ignore = &.{"caf\u{e9}"} });
    defer h.deinit();
    try testing.expectEqual(path.folds_case, h.excludes(sep("/w"), sep("/w/cafe\u{301}/a")));
    // A name that is not UTF-8 is matched byte for byte.
    var raw = try expectCompiled(.{ .ignore = &.{"\xff*"} });
    defer raw.deinit();
    try testing.expect(raw.excludes(sep("/w"), sep("/w/\xff\xfe")));
    try testing.expect(!raw.excludes(sep("/w"), sep("/w/\xfe\xff")));
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

        var copy = try compile(gpa, .{ .ignore = &ignore, .only = &only });
        defer copy.deinit();
        try testing.expect(copy.excludes(sep("/w"), sep("/w/target/a")));
        try testing.expect(!copy.excludes(sep("/w"), sep("/w/a.zig")));
        // The original lists and their strings are gone after this
        // block; the copy still answers.
        try testing.expect(copy.ignore[0].ptr != owned_ignore.ptr);
        try testing.expect(copy.only[0].ptr != owned_only.ptr);
    }
}

test "a compile that runs out of memory leaves nothing behind" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const filter: Filter = .{ .ignore = &.{ "*.tmp", sep("/w/abs"), "a*b*c" }, .only = &.{ sep("src/**/*.zig"), sep("/w/x/**") } };
        if (compile(failing.allocator(), filter)) |compiled| {
            var c = compiled;
            c.deinit();
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
}

test "a path longer than any the system gives is let through, not matched unfolded" {
    if (!path.folds_case) return error.SkipZigTest;
    var f = try expectCompiled(.{ .ignore = &.{"*"} });
    defer f.deinit();
    const root = comptime sep("/w");
    const long = root ++ std.Io.Dir.path.sep_str ++ shakedown.corpus.repeat("a", max_subject);
    try testing.expect(f.excludes(root, long[0..max_subject]));
    try testing.expect(!f.excludes(root, long));
}

// F07: a class member must never turn into two independent members.
test "normalization preserves an accented class member" {
    var f = try expectCompiled(.{ .ignore = &.{"[é]"} });
    defer f.deinit();
    try testing.expect(!f.excludes(sep("/w"), sep("/w/e")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/\u{301}")));
}
