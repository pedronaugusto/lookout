//! A watch's reading of its ignore files (`Filter.ignore_files`): one per
//! watch, owned by the `Watcher` and shared by every filter compiled for
//! the watch, so each file is read once whichever backend registration,
//! followed link or pending ancestor asks.
//!
//! The files are read as git reads them (sweep's `ignore.Checker`): those
//! above a path the first time a path below it is asked about, none inside
//! a directory they exclude. A file that is there and cannot be read
//! counts as absent, as git warns and goes on, and is listed (`unread`). A
//! read that runs out of memory, or is canceled, fails the question, and
//! the operation that asked it fails with it.
//!
//! An event naming an ignore file under the watch marks it `changed`; the
//! watcher then drops every reading (`reset`) and refilters the watch, so
//! the next question reads the files afresh.
//!
//! One thread asks at a time: the watcher's.

const std = @import("std");
const builtin = @import("builtin");
const sweep = @import("sweep");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const State = @This();

gpa: Allocator,
/// One reading per root asked about: the watch's own, or a followed link's.
readings: std.ArrayList(Reading) = .empty,
/// An event named an ignore file under the watch since the last `reset`.
changed: bool = false,
/// Absolute paths of the ignore files read as absent because they could not
/// be read, oldest first. Owned.
unread: std.ArrayList([]u8) = .empty,

const Reading = struct {
    /// Owned.
    root: []u8,
    /// The names and case the checker reads with; a question asked with
    /// others builds the reading again. Owned.
    names: []const []const u8,
    case: sweep.Case,
    /// Null where the root could not be opened: nothing above a path there
    /// is read, and the root is in `unread` unless it is simply gone.
    checker: ?sweep.ignore.Checker,
    /// The root the checker reads under, closed with the reading.
    dir: ?aegis.own.Dir,
    /// How many of the checker's skipped files are in `unread`.
    listed: usize = 0,

    fn deinit(r: *Reading, gpa: Allocator, io: Io) void {
        if (r.checker) |*c| c.deinit();
        if (r.dir) |*d| d.deinit(io);
        for (r.names) |name| gpa.free(name);
        gpa.free(r.names);
        gpa.free(r.root);
        r.* = undefined;
    }
};

/// What a question can fail with: a read that ran out of memory, or a
/// cancel while a file was read.
pub const Error = error{ OutOfMemory, Canceled };

pub fn create(gpa: Allocator) Allocator.Error!*State {
    const s = try gpa.create(State);
    s.* = .{ .gpa = gpa };
    return s;
}

pub fn destroy(s: *State, io: Io) void {
    s.reset(io);
    s.readings.deinit(s.gpa);
    s.unread.deinit(s.gpa);
    const gpa = s.gpa;
    gpa.destroy(s);
}

/// Drops every reading and what it listed: the next question reads the
/// files again.
pub fn reset(s: *State, io: Io) void {
    for (s.readings.items) |*r| r.deinit(s.gpa, io);
    s.readings.clearRetainingCapacity();
    for (s.unread.items) |path| s.gpa.free(path);
    s.unread.clearRetainingCapacity();
    s.changed = false;
}

/// Whether `subject`, below `root`, is the name of an ignore file: the
/// event naming it is a change to the rules.
pub fn namesFile(names: []const []const u8, root: []const u8, subject: []const u8) bool {
    if (subject.len <= root.len) return false;
    const base = std.Io.Dir.path.basename(subject);
    for (names) |name| if (std.mem.eql(u8, base, name)) return true;
    return false;
}

/// Whether the ignore files under `root` exclude `rest`, the path below it
/// in the platform's spelling. A directory being walked into is asked as a
/// directory; a path to report is asked both ways, and only where a
/// directory's line decides is `root`/`rest` looked at to say which it is.
pub fn excludes(
    s: *State,
    io: Io,
    names: []const []const u8,
    case: sweep.Case,
    root: []const u8,
    subject: []const u8,
    rest: []const u8,
    walk: bool,
) Error!bool {
    const r = try s.reading(io, names, case, root) orelse return false;
    const checker = if (r.checker) |*c| c else return false;
    // sweep's paths are `/`-separated.
    var spelled: ?[]u8 = null;
    defer if (spelled) |copy| s.gpa.free(copy);
    if (builtin.target.os.tag == .windows) {
        spelled = try s.gpa.dupe(u8, rest);
        std.mem.replaceScalar(u8, spelled.?, '\\', '/');
    }
    const slashed = spelled orelse rest;

    if (walk) {
        const excluded = (try ask(checker, io, slashed, .dir)).excluded;
        try s.listSkipped(r);
        return excluded;
    }
    const as_file = (try ask(checker, io, slashed, .file)).excluded;
    const as_dir = (try ask(checker, io, slashed, .dir)).excluded;
    try s.listSkipped(r);
    if (as_file == as_dir) return as_file;
    // A line for directories alone decides: the path says which it is. One
    // that is gone is no directory.
    const stat = Io.Dir.cwd().statFile(io, subject, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return as_file,
    };
    return if (stat.kind == .directory) as_dir else as_file;
}

fn ask(checker: *sweep.ignore.Checker, io: Io, path: []const u8, kind: sweep.Kind) Error!sweep.ignore.Match {
    return checker.match(io, path, kind) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        // unreachable: a reading skips what it cannot read (`.skip`), so
        // only memory and a cancel fail a question
        else => unreachable,
    };
}

/// The reading for `root` with these names and case, made on first ask;
/// null while the root is not there.
fn reading(s: *State, io: Io, names: []const []const u8, case: sweep.Case, root: []const u8) Error!?*Reading {
    for (s.readings.items, 0..) |*r, i| {
        if (!std.mem.eql(u8, r.root, root)) continue;
        if (r.case == case and sameNames(r.names, names)) return r;
        r.deinit(s.gpa, io);
        _ = s.readings.swapRemove(i);
        break;
    }
    try s.readings.ensureUnusedCapacity(s.gpa, 1);
    const owned_root = try s.gpa.dupe(u8, root);
    errdefer s.gpa.free(owned_root);
    const owned_names = try dupeNames(s.gpa, names);
    errdefer freeNames(s.gpa, owned_names);
    var r: Reading = .{ .root = owned_root, .names = owned_names, .case = case, .checker = null, .dir = null };
    const dir = Io.Dir.cwd().openDir(io, root, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.SystemResources => return error.OutOfMemory,
        // A root that is not there yet, a pending watch's, has no files to
        // read, and is asked again: nothing is kept that would outlive its
        // appearing.
        error.FileNotFound, error.NotDir => {
            s.gpa.free(owned_root);
            freeNames(s.gpa, owned_names);
            return null;
        },
        else => {
            try s.listUnread(root);
            s.readings.appendAssumeCapacity(r);
            return &s.readings.items[s.readings.items.len - 1];
        },
    };
    r.dir = .init(dir);
    r.checker = .init(.init(s.gpa, .{ .case = case, .file_names = owned_names, .unreadable = .skip }), dir);
    s.readings.appendAssumeCapacity(r);
    return &s.readings.items[s.readings.items.len - 1];
}

/// Lists what the reading skipped since it last looked.
fn listSkipped(s: *State, r: *Reading) Allocator.Error!void {
    const checker = if (r.checker) |*c| c else return;
    const skipped = checker.stack.skipped();
    while (r.listed < skipped.len) : (r.listed += 1) {
        const source = try s.gpa.dupe(u8, skipped[r.listed].source);
        defer s.gpa.free(source);
        if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, source, '/', '\\');
        const full = try std.Io.Dir.path.join(s.gpa, &.{ r.root, source });
        defer s.gpa.free(full);
        try s.listUnread(full);
    }
}

fn listUnread(s: *State, path: []const u8) Allocator.Error!void {
    for (s.unread.items) |seen| if (std.mem.eql(u8, seen, path)) return;
    const owned = try s.gpa.dupe(u8, path);
    errdefer s.gpa.free(owned);
    try s.unread.append(s.gpa, owned);
}

fn sameNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

pub fn dupeNames(gpa: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, names.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |n| gpa.free(n);
        gpa.free(out);
    }
    for (names, out) |n, *slot| {
        slot.* = try gpa.dupe(u8, n);
        filled += 1;
    }
    return out;
}

pub fn freeNames(gpa: Allocator, names: []const []const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}
