//! Filter queries measured through shakedown in ReleaseFast.
//! Timings are evidence, never a correctness gate; --smoke checks execution.

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

const shakedown = @import("shakedown");
const Context = struct {
    filter: CompiledFilter,
    subjects: [][]u8,
    fn run(c: *Context, n: u64) error{}!void {
        var kept: usize = 0;
        for (0..n) |i| {
            const subject = c.subjects[i % c.subjects.len];
            kept += @intFromBool(!c.filter.excludes(root, subject));
            kept += @intFromBool(!c.filter.prunes(root, subject));
        }
        std.mem.doNotOptimizeAway(kept);
    }
};
/// Each iteration asks excludes and prunes for the same seeded path.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke = false;
    var folded = false;
    var nfc = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true else if (std.mem.eql(u8, arg, "--folded")) folded = true else if (std.mem.eql(u8, arg, "--nfc")) nfc = true else return error.UnknownArgument;
    }
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const subjects = try paths(arena.allocator(), 20_000);
    const Case = struct { name: []const u8, ignore: []const []const u8, only: []const []const u8 };
    const cases = [_]Case{
        .{ .name = "ignore_1", .ignore = ignore[2..3], .only = &.{} },
        .{ .name = "ignore_20", .ignore = &ignore, .only = &.{} },
        .{ .name = "only_3", .ignore = &.{}, .only = &only },
        .{ .name = "ignore_20_only_3", .ignore = &ignore, .only = &only },
    };
    for (cases) |case| {
        var c: Context = .{ .filter = try .compilePolicy(init.gpa, .{ .ignore = case.ignore, .only = case.only }, .{ .case_sensitive = !folded, .normalization = if (nfc) .nfc else .exact }), .subjects = subjects };
        defer c.filter.deinit();
        try shakedown.bench.run(error{}, init.gpa, init.io, &stdout.interface, &c, &.{.{ .name = case.name, .unit = "two-questions", .initial = 20_000, .run = Context.run }}, .{ .commit = "filesystem-policy" }, .{ .smoke = smoke });
    }
    try stdout.interface.flush();
}
