//! What a filter costs a path: the question every backend asks of every
//! event, and of every directory before it registers one. `zig build
//! bench` runs it in ReleaseFast; run it on a quiet machine. A case over its
//! ceiling fails the run. `--smoke`, which `zig build test` runs, asks a
//! hundred paths once and judges nothing.

const std = @import("std");
const CompiledFilter = @import("filter");

const root = "/Users/someone/work/project";

/// A long ignore list, as a project's would be, and an include list.
const ignore = [_][]const u8{
    "node_modules", ".git",                   "*.tmp",          "*.log",    "*.swp",
    "build/**",     "target",                 "dist",           "*.o",      "zig-cache",
    ".zig-cache",   "zig-out",                "__pycache__",    "*.pyc",    ".DS_Store",
    "coverage/**",  "src/**/generated/*.zig", "docs/_build/**", "*.min.js", "vendor/*/test/**",
};
const only = [_][]const u8{ "src/**/*.zig", "*.md", "build.zig" };

/// Paths one to eight components below the root, from a fixed seed.
fn paths(gpa: std.mem.Allocator, n: usize) ![][]u8 {
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    const names = [_][]const u8{ "src", "lib", "net", "io", "main.zig", "README.md", "util", "a.tmp", "x.log", "deep", "generated", "test", "core", "node_modules", "pkg", "index.js", "mod.rs", "notes.txt" };
    const out = try gpa.alloc([]u8, n);
    for (out) |*p| {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(gpa, root);
        for (0..r.intRangeAtMost(usize, 1, 8)) |_| {
            try buf.append(gpa, std.Io.Dir.path.sep);
            try buf.appendSlice(gpa, names[r.uintLessThan(usize, names.len)]);
        }
        p.* = try buf.toOwnedSlice(gpa);
    }
    return out;
}

/// The ceiling per question, in nanoseconds: the old matcher took about
/// 3,000 for the longest case below on an M-series Mac, and this one
/// about 500.
const ceiling_ns = 1_500;

/// A path is decided against twenty ignore patterns and three includes in
/// one pass.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke = false;
    for (args[1..]) |arg| {
        if (!std.mem.eql(u8, arg, "--smoke")) return error.UnknownArgument;
        smoke = true;
    }
    const gpa = init.gpa;
    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const subjects = try paths(arena.allocator(), if (smoke) 100 else 20_000);
    const Case = struct { name: []const u8, ignore: []const []const u8, only: []const []const u8 };
    const cases = [_]Case{
        .{ .name = "ignore_1", .ignore = ignore[2..3], .only = &.{} },
        .{ .name = "ignore_20", .ignore = &ignore, .only = &.{} },
        .{ .name = "only_3", .ignore = &.{}, .only = &only },
        .{ .name = "ignore_20_only_3", .ignore = &ignore, .only = &only },
    };
    var over = false;
    for (cases) |case| {
        var filter: CompiledFilter = try .compile(gpa, .{ .ignore = case.ignore, .only = case.only });
        defer filter.deinit();
        var best: u64 = std.math.maxInt(u64);
        var kept: usize = 0;
        for (0..if (smoke) 1 else 9) |_| {
            const start: std.Io.Timestamp = .now(io, .awake);
            kept = 0;
            for (subjects) |subject| {
                if (!filter.excludes(root, subject)) kept += 1;
                if (!filter.prunes(root, subject)) kept += 1;
            }
            best = @min(best, @as(u64, @intCast(start.durationTo(.now(io, .awake)).nanoseconds)));
        }
        std.mem.doNotOptimizeAway(kept);
        const per_question = best / (2 * subjects.len);
        try row(out, case.name, "per_question", per_question, "ns");
        if (smoke) continue;
        try row(out, case.name, "budget", ceiling_ns, "ns");
        try row(out, case.name, "within_budget", @intFromBool(per_question <= ceiling_ns), "bool");
        if (per_question > ceiling_ns) over = true;
    }
    try out.flush();
    if (over) return error.OverBudget;
}

fn row(out: *std.Io.Writer, job: []const u8, measure: []const u8, value: anytype, unit: []const u8) !void {
    try out.print("lookout\tfilter_{s}\t{s}\t{d}\t{s}\n", .{ job, measure, value, unit });
}
