//! A `Filter` a watch keeps: its pattern lists copied, and compiled into
//! sweep sets that answer for any path in one pass over it, whatever the
//! number of patterns.
//!
//! Sweep parses original patterns and applies scalar normalization itself.
//! A query moves the sets' caches: one thread asks at
//! a time, which is the watcher's own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const sweep = @import("sweep");

const Filter = @import("Filter.zig");
const path = @import("path.zig");
const identity = @import("identity.zig");

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
matcher: [2]?*Matcher = @splat(null),
/// Measured directory policy; caller preferences are retained separately.
policy: identity.Policy = .{},
case: ?sweep.Case = null,
normalization: ?identity.Policy.Normalization = null,
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
    return compilePolicy(gpa, filter, .{});
}
/// Compile the original patterns with the measured or explicit name policy.
pub fn compilePolicy(gpa: Allocator, filter: Filter, policy: identity.Policy) Error!CompiledFilter {
    const ignore = try dupeList(gpa, filter.ignore);
    errdefer freeList(gpa, ignore);
    const only = try dupeList(gpa, filter.only);
    errdefer freeList(gpa, only);
    var matchers: [2]?*Matcher = @splat(null);
    errdefer for (matchers) |m| if (m) |made| made.destroy(gpa);
    for (&matchers, 0..) |*slot, i| {
        var opts = pattern_options;
        opts.case = filter.case orelse if (i & 1 != 0) .unicode else .sensitive;
        opts.normalization = if ((filter.normalization orelse policy.normalization) == .nfc) .nfc else .exact;
        slot.* = try Matcher.create(gpa, ignore, only, opts);
    }
    return .{ .ignore = ignore, .only = only, .allow = filter.allow, .context = filter.context, .matcher = matchers, .gpa = gpa, .case = filter.case, .normalization = filter.normalization, .policy = policy };
}

/// `compile`, for a filter whose patterns have compiled once already: a
/// second copy for another registration of the same watch. Only memory
/// can fail.
pub fn recompile(gpa: Allocator, filter: Filter, policy: identity.Policy) Allocator.Error!CompiledFilter {
    return compilePolicy(gpa, filter, policy) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // unreachable: the caller compiled these exact patterns before
        error.InvalidPattern, error.PatternTooLong => unreachable,
    };
}

/// The filter this was compiled from, borrowing this copy's patterns.
pub fn spec(c: *const CompiledFilter) Filter {
    return .{ .ignore = c.ignore, .only = c.only, .allow = c.allow, .context = c.context, .case = c.case, .normalization = c.normalization };
}

/// Releases a compiled filter. `none` owns nothing.
pub fn deinit(c: *CompiledFilter) void {
    const gpa = c.gpa orelse return;
    for (c.matcher) |m| if (m) |made| made.destroy(gpa);
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
    return c.outside(c.policy, root, subject, .report);
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
    return c.outside(c.policy, root, subject, .walk);
}

/// Which of the two questions is being asked. They differ only for
/// `only`: a directory on the way to what it names is walked, and not
/// reported.
const Purpose = enum { report, walk };

/// Query with the policy measured on the entry's parent directory.
pub fn excludesPolicy(c: *const CompiledFilter, policy: identity.Policy, root: []const u8, subject: []const u8) bool {
    return c.outside(policy, root, subject, .report);
}
pub fn prunesPolicy(c: *const CompiledFilter, policy: identity.Policy, root: []const u8, subject: []const u8) bool {
    return c.outside(policy, root, subject, .walk);
}
fn outside(c: *const CompiledFilter, policy: identity.Policy, root: []const u8, subject: []const u8, purpose: Purpose) bool {
    if (c.isEmpty()) return false;
    const rest = path.relative(root, subject) orelse return false;
    if (rest.len == 0) return false;
    // `rest` is a suffix of `subject`, which is what lets one ancestor be
    // spelled both ways without joining anything.
    const base = subject.len - rest.len;
    const which: usize = @intFromBool(!policy.case_sensitive);
    if (c.matcher[which]) |m| if (m.outside(subject, base, purpose)) return true;
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
/// sweep reads both separator spellings directly, and there is no escape.
const pattern_options: sweep.Options = .{
    .syntax = .{ .unit = .utf8, .escape = builtin.target.os.tag != .windows, .alternate_separator = if (builtin.target.os.tag == .windows) '\\' else null },
    .anywhere = true,
};

/// The patterns, compiled: one set per list and per anchoring, each with
/// the cache a query runs on.
const Matcher = struct {
    /// Indexed by `Which`; null for a list with no such patterns.
    parts: [4]?Part,
    const Which = enum(u2) { ignore, ignore_absolute, only, only_absolute };

    const Part = struct {
        set: sweep.Set,
        cache: sweep.Set.Cache,
    };

    /// The most a cache takes: a filter holds few patterns, so a reading uses
    /// well under this, and a full cache only clears, it never changes an
    /// answer.
    const cache_options: sweep.Set.Cache.Options = .{ .capacity = .fromRaw(1 << 16) };

    /// Null when no list holds a pattern.
    fn create(gpa: Allocator, ignore: []const []const u8, only: []const []const u8, options: sweep.Options) Error!?*Matcher {
        var builders: [4]?sweep.Set.Builder = @splat(null);
        defer for (&builders) |*b| if (b.*) |*builder| builder.deinit();

        for ([_][]const []const u8{ ignore, only }, [_]Which{ .ignore, .only }) |list, relative| {
            for (list) |pattern| {
                if (pattern.len == 0) continue;
                const which: Which = if (std.Io.Dir.path.isAbsolute(pattern)) @fromBackingInt(@backingInt(relative) + 1) else relative;
                const slot = &builders[@backingInt(which)];
                if (slot.* == null) slot.* = .init(gpa);
                _ = slot.*.?.add(pattern, .{ .options = options }) catch |err| switch (err) {
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
        m.* = .{
            .parts = @splat(null),
        };
        errdefer m.release();
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
        m.release();
        gpa.destroy(m);
    }

    fn release(m: *Matcher) void {
        for (&m.parts) |*p| if (p.*) |*part| {
            part.cache.deinit();
            part.set.deinit();
            p.* = null;
        };
    }

    fn find(m: *Matcher, which: Which) ?*Part {
        if (m.parts[@backingInt(which)]) |*p| return p;
        return null;
    }

    /// Whether the patterns put `subject` outside the watch; `subject[base..]`
    /// is the part below the root.
    fn outside(m: *Matcher, subject: []const u8, base: usize, purpose: Purpose) bool {
        const absolute = subject;
        const start = base;
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
    for (f.matcher) |m| try testing.expect(m == null);
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
    // Exact UTF-8 mode keeps the precomposed scalar intact.
    try testing.expectEqual(true, f.excludes(sep("/w"), sep("/w/caf\u{e9}")));
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
    for (f.matcher) |m| try testing.expect(m == null);

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
    try testing.expectEqual(false, f.excludes(sep("/w"), sep("/w/notes.tmp")));

    var g = try expectCompiled(.{ .ignore = &.{"Node_Modules"} });
    defer g.deinit();
    try testing.expectEqual(false, g.excludes(sep("/w"), sep("/w/node_modules/a.js")));

    // A Latin-1 letter written composed in the pattern and decomposed in
    // the name, as a volume that stores it decomposed spells it.
    var h = try expectCompiled(.{ .ignore = &.{"caf\u{e9}"} });
    defer h.deinit();
    try testing.expectEqual(false, h.excludes(sep("/w"), sep("/w/cafe\u{301}/a")));
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

test "a composed filter releases all allocations when compilation fails" {
    const Exercise = struct {
        fn run(backing: Allocator) !void {
            var no_resize: shakedown.alloc.NoResize = .init(backing);
            var c = try compilePolicy(no_resize.allocator(), .{ .ignore = &.{ "[é]", sep("/w/abs"), "a*b*c" }, .only = &.{ sep("src/**/*.zig"), sep("/w/x/**") } }, .{ .normalization = .nfc });
            defer c.deinit();
            try testing.expect(c.excludes(sep("/w"), sep("/w/e\u{301}")));
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Exercise.run, .{});
}

// F07: a class member must never turn into two independent members.
test "normalization preserves an accented class member" {
    var f = try expectCompiled(.{ .ignore = &.{"[é]"} });
    defer f.deinit();
    try testing.expect(!f.excludes(sep("/w"), sep("/w/e")));
    try testing.expect(!f.excludes(sep("/w"), sep("/w/\u{301}")));
}

test "normalized root policies preserve grammar classes and raw patterns" {
    const gpa = testing.allocator;
    var composed = try compilePolicy(gpa, .{ .ignore = &.{"[é]"} }, .{ .normalization = .nfc });
    defer composed.deinit();
    try testing.expectEqualStrings("[é]", composed.ignore[0]);
    try testing.expect(composed.excludes(sep("/w"), sep("/w/e\u{301}")));
    try testing.expect(!composed.excludes(sep("/w"), sep("/w/e")));
    var exact = try compilePolicy(gpa, .{ .ignore = &.{"[é]"} }, .{});
    defer exact.deinit();
    try testing.expect(!exact.excludes(sep("/w"), sep("/w/e\u{301}")));
    var sensitive = try compilePolicy(gpa, .{ .ignore = &.{"[É]"} }, .{ .case_sensitive = true, .normalization = .nfc });
    defer sensitive.deinit();
    try testing.expect(!sensitive.excludes(sep("/w"), sep("/w/e\u{301}")));
    try testing.expect(sensitive.excludesPolicy(.{ .case_sensitive = false, .normalization = .nfc }, sep("/w"), sep("/w/e\u{301}")));
    var override = try compilePolicy(gpa, .{ .ignore = &.{"[É]"}, .case = .sensitive, .normalization = .nfc }, .{ .case_sensitive = false });
    defer override.deinit();
    try testing.expect(!override.excludes(sep("/w"), sep("/w/e\u{301}")));
    try testing.expectError(error.InvalidPattern, compilePolicy(gpa, .{ .ignore = &.{"[q\u{301}]"} }, .{ .normalization = .nfc }));
    var multi = try compilePolicy(gpa, .{ .ignore = &.{"[q\u{301}]"} }, .{});
    defer multi.deinit();
}
