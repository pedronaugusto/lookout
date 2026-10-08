//! The symbolic links one recursive watch follows, and the directories
//! they lead to. See `@import("options.zig").AddOptions.follow_symlinks`.
//!
//! A followed link is a registration of its own, on the directory the
//! link leads to, made with whatever backend the watcher uses for any
//! other path. `Batch` spells what that registration reports under the
//! link and records it as the watch's, so no backend knows that links
//! exist; this is what decides which ones are followed.
//!
//! That decision is by identity -- device and inode, or volume and file
//! id -- and the identities are kept here and nowhere else: the root's,
//! and each followed link's target. A link is not followed into a
//! directory the watch already reaches, nor into one that holds such a
//! directory, so a cycle is never walked and no directory is reported
//! under two names by one watch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const Batch = @import("Batch.zig");
const Filter = @import("Filter.zig");
const CompiledFilter = @import("CompiledFilter.zig");
const airlock = @import("airlock");
const names = @import("identity.zig");
const path_cmp = @import("path.zig");
const types = @import("types.zig");
const walk = @import("walk.zig");
const builtin = @import("builtin");
const Identity = airlock.FileId;
const WatchId = types.WatchId;

/// What `Links` asks of the watcher that owns it: an id for, and a
/// registration on, each directory a followed link leads to. Spelled out
/// here rather than taken as a type of the watcher's, so that the
/// watcher can answer with functions of its own that nobody else can
/// call: issuing an id and registering under it outside `add` would break
/// what every id promises.
pub const Host = struct {
    context: *anyopaque,
    issue_fn: *const fn (context: *anyopaque) WatchId,
    /// Registers the link's target under the link's id.
    register_fn: *const fn (io: Io, context: *anyopaque, link: *Link) RegisterError!void,
    unregister_fn: *const fn (io: Io, context: *anyopaque, id: WatchId) void,

    fn issue(h: Host) WatchId {
        return h.issue_fn(h.context);
    }

    /// All a refusal means here is a hole in the watch: the link is
    /// reported `Kind.unwatched`, whatever the system's reason.
    pub const RegisterError = Allocator.Error || error{Refused};

    fn register(h: Host, io: Io, link: *Link) RegisterError!void {
        return h.register_fn(io, h.context, link);
    }

    fn unregister(h: Host, io: Io, id: WatchId) void {
        h.unregister_fn(io, h.context, id);
    }
};

const Links = @This();

gpa: Allocator,
io: Io,
identity_override: ?names.Policy,
/// The watch the links are in.
owner: WatchId,
/// Its root, canonical. Owned.
root: []u8,
/// Its filter, copied: a link it prunes is not followed, and the
/// registrations on links' targets ask it of every path below them.
filter: CompiledFilter,
/// `AddOptions.max_followed_links`.
max: usize,
/// What the root is.
identity: Identity,
followed: std.ArrayList(*Link) = .empty,
/// Links seen and not followed: they lead to no directory, or to one the
/// watch reaches another way. Each is looked at again when it changes,
/// and all of them whenever a followed link is let go. Owned.
idle: std.ArrayList([]u8) = .empty,
/// A change went unread, or reading one failed half way: every link is
/// looked at again on the next `settle`.
stale: bool = false,

/// One followed link. Heap-allocated and never moved: the batch holds its
/// alias, and its registration's filter holds the link.
pub const Link = struct {
    links: *const Links,
    /// The registration on the target, issued by the watcher.
    id: WatchId,
    /// The link, spelled as the watch reaches it. Owned.
    path: []u8,
    /// Where it leads, canonical. Owned.
    target: []u8,
    /// What it leads to, when it was followed.
    identity: Identity,
    alias: Batch.Alias,

    /// The filter the registration on the target is made with: the
    /// watch's own, asked of each path as it is spelled under the link.
    /// It answers whether a directory is worth walking into, the weaker
    /// of the two questions; what is reported is decided when the change
    /// is spelled, by the watch's filter. See `CompiledFilter.prunes`.
    pub fn filter(link: *Link) Filter {
        return .{ .allow = admits, .context = link };
    }

    fn admits(context: ?*anyopaque, subject: []const u8) bool {
        const link: *const Link = @ptrCast(@alignCast(context.?)); // safe: the filter's context is the Link it was made with, which outlives its registration
        var buffer: [4096]u8 = undefined;
        // Too long to spell here: let it through, the report decides.
        const spelled = link.alias.spell(&buffer, subject) orelse return true;
        return !link.links.prunes(link.links.io, spelled);
    }
};

fn prunes(l: *const Links, io: Io, subject: []const u8) bool {
    if (l.filter.isEmpty()) return false;
    const parent = std.Io.Dir.path.dirname(subject) orelse l.root;
    return l.filter.prunesPolicy(names.read(l.gpa, io, parent).policy(l.identity_override), l.root, subject);
}

/// The links of the watch `owner`, of which none are followed yet. Null
/// when the root's identity cannot be read: without it no link can be
/// shown not to lead back.
pub fn create(gpa: Allocator, io: Io, owner: WatchId, root: []const u8, filter: Filter, policy: names.Policy, identity_override: ?names.Policy, max: usize) Allocator.Error!?*Links {
    const identity = identityOf(io, root) orelse return null;
    const l = try gpa.create(Links);
    errdefer gpa.destroy(l);
    const owned = try gpa.dupe(u8, root);
    errdefer gpa.free(owned);
    l.* = .{
        .gpa = gpa,
        .io = io,
        .identity_override = identity_override,
        .owner = owner,
        .root = owned,
        .filter = try CompiledFilter.recompile(gpa, filter, policy),
        .max = max,
        .identity = identity,
    };
    return l;
}

/// Lets go of every followed link through `host`, and frees the set.
pub fn destroy(l: *Links, io: Io, host: Host) void {
    while (l.followed.items.len != 0) l.unfollow(io, host, l.followed.items[l.followed.items.len - 1]);
    l.followed.deinit(l.gpa);
    for (l.idle.items) |item| l.gpa.free(item);
    l.idle.deinit(l.gpa);
    l.filter.deinit();
    l.gpa.free(l.root);
    l.gpa.destroy(l);
}

/// What `consider` found at a path.
pub const Verdict = union(enum) {
    /// A link to a directory the watch does not reach yet: where it leads,
    /// canonical and the caller's, and what that is.
    follow: struct { target: []u8, identity: Identity },
    /// Not a link.
    none,
    /// A link that leads to no directory, or nowhere.
    idle,
    /// A link already followed.
    followed: *Link,
    /// A link to a directory the watch reaches another way.
    reached,
    /// A link past `max`.
    full,
};

/// Whether the link at `subject` leads somewhere this watch should follow.
pub fn consider(l: *const Links, io: Io, subject: []const u8) Allocator.Error!Verdict {
    const named = Io.Dir.cwd().statFile(io, subject, .{ .follow_symlinks = false }) catch return .none;
    if (named.kind != .sym_link) return .none;
    if (l.find(subject)) |link| return .{ .followed = link };
    const real = names.canonical(l.gpa, io, subject) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Leads nowhere, or nowhere this process may look.
        else => return .idle,
    };
    defer l.gpa.free(real);
    const reached = Io.Dir.cwd().statFile(io, real, .{}) catch return .idle;
    if (reached.kind != .directory) return .idle;
    const identity = identityOf(io, real) orelse return .idle;
    if (l.reaches(io, real, identity)) return .reached;
    if (l.followed.items.len >= l.max) return .full;
    return .{ .follow = .{ .target = try l.gpa.dupe(u8, real), .identity = identity } };
}

/// Whether the watch reaches the directory `target`, which is `identity`,
/// already: it is the root or a followed link's target, it is below one
/// of them, or it holds one of them -- a link back to an ancestor.
fn reaches(l: *const Links, io: Io, target: []const u8, identity: Identity) bool {
    if (l.holds(identity)) return true;
    var above = std.Io.Dir.path.dirname(target);
    while (above) |dir| : (above = std.Io.Dir.path.dirname(dir)) {
        if (l.holds(identityOf(io, dir) orelse continue)) return true;
    }
    if (isAbove(io, identity, l.root)) return true;
    for (l.followed.items) |link| if (isAbove(io, identity, link.target)) return true;
    return false;
}

/// Whether `identity` is the root's or a followed link target's.
fn holds(l: *const Links, identity: Identity) bool {
    if (l.identity.eql(identity)) return true;
    for (l.followed.items) |link| if (link.identity.eql(identity)) return true;
    return false;
}

/// The identity of what `path` names, symbolic links followed: device and
/// inode, or volume and file id. Null when it cannot be read.
fn identityOf(io: Io, path: []const u8) ?Identity {
    return Identity.ofPath(io, Io.Dir.cwd(), path, .{}) catch null;
}

/// Whether the directory that is `identity` is a proper ancestor of `inner`.
fn isAbove(io: Io, identity: Identity, inner: []const u8) bool {
    var above = std.Io.Dir.path.dirname(inner);
    while (above) |dir| : (above = std.Io.Dir.path.dirname(dir)) {
        const there = identityOf(io, dir) orelse continue;
        if (there.eql(identity)) return true;
    }
    return false;
}

/// The followed link at `subject`.
pub fn find(l: *const Links, subject: []const u8) ?*Link {
    for (l.followed.items) |link| if (path_cmp.eql(link.path, subject)) return link;
    return null;
}

/// Follows every link below `dir` that leads somewhere new, and every
/// link below the directories those lead to. `dir` is spelled as the
/// watch reaches it.
pub fn followBelow(l: *Links, io: Io, host: Host, batch: *Batch, dir: []const u8) Allocator.Error!void {
    var found: std.ArrayList([]u8) = .empty;
    defer {
        for (found.items) |item| l.gpa.free(item);
        found.deinit(l.gpa);
    }
    try l.discover(io, dir, &found);
    var i: usize = 0;
    while (i < found.items.len) : (i += 1) {
        const link = try l.follow(io, host, batch, found.items[i]) orelse continue;
        try l.discover(io, link.path, &found);
    }
}

/// Appends every link below `dir` to `found`, leaving out what the filter
/// prunes. Links are listed, not walked through: `followBelow` decides
/// which to go into.
fn discover(l: *const Links, io: Io, dir: []const u8, found: *std.ArrayList([]u8)) Allocator.Error!void {
    const Finding = struct {
        l: *const Links,
        found: *std.ArrayList([]u8),

        const Self = @This();

        fn visit(f: Self, entry: walk.Entry) anyerror!walk.Step {
            if (f.l.prunes(f.l.io, entry.path)) return .over;
            switch (entry.kind) {
                .directory => return .into,
                .sym_link => {
                    const owned = try f.l.gpa.dupe(u8, entry.path);
                    errdefer f.l.gpa.free(owned);
                    try f.found.append(f.l.gpa, owned);
                    return .over;
                },
                else => return .over,
            }
        }
    };
    walk.tree(Finding, Finding.visit, l.gpa, io, dir, Finding{ .l = l, .found = found }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // gone again, or not ours to read: nothing to follow there
        else => {},
    };
}

/// Follows the link at `subject` if it leads somewhere the watch does
/// not reach yet, registering its target through `host`. Returns the
/// link, or the one already followed there.
///
/// A link past `max`, or one whose target the system refuses to watch,
/// is a hole in the watch and is reported `Kind.unwatched`. A link that
/// leads to no directory, or to one the watch reaches another way, is
/// remembered as idle.
pub fn follow(l: *Links, io: Io, host: Host, batch: *Batch, subject: []const u8) Allocator.Error!?*Link {
    if (l.prunes(io, subject)) return null;
    switch (try l.consider(io, subject)) {
        .none => return null,
        .followed => |link| return link,
        .idle, .reached => {
            try l.remember(subject);
            return null;
        },
        .full => {
            try batch.trouble(l.gpa, l.owner, subject, .directory);
            return null;
        },
        .follow => |found| {
            const link = try l.adopt(subject, found.target, found.identity, host.issue());
            host.register(io, link) catch |err| {
                l.forget(link);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                try batch.trouble(l.gpa, l.owner, subject, .directory);
                return null;
            };
            return link;
        },
    }
}

/// Makes the record of a link about to be followed, taking `target`.
fn adopt(l: *Links, subject: []const u8, target: []u8, identity: Identity, id: WatchId) Allocator.Error!*Link {
    // `consider` says `full` at the ceiling, so a link adopted is within it.
    assert(l.followed.items.len < l.max);
    errdefer l.gpa.free(target);
    try l.followed.ensureUnusedCapacity(l.gpa, 1);
    const link = try l.gpa.create(Link);
    errdefer l.gpa.destroy(link);
    const owned = try l.gpa.dupe(u8, subject);
    link.* = .{
        .links = l,
        .id = id,
        .path = owned,
        .target = target,
        .identity = identity,
        .alias = .{ .gpa = l.gpa, .io = l.io, .identity_override = l.identity_override, .owner = l.owner, .root = l.root, .filter = &l.filter, .physical = target, .logical = owned },
    };
    l.followed.appendAssumeCapacity(link);
    return link;
}

/// Drops the record of a link that was never registered, or no longer is.
fn forget(l: *Links, link: *Link) void {
    for (l.followed.items, 0..) |held, i| {
        if (held != link) continue;
        _ = l.followed.orderedRemove(i);
        break;
    }
    l.gpa.free(link.path);
    l.gpa.free(link.target);
    l.gpa.destroy(link);
}

/// Lets go of `link` and of every link followed below it.
fn unfollow(l: *Links, io: Io, host: Host, link: *Link) void {
    var i: usize = l.followed.items.len;
    while (i > 0) {
        i -= 1;
        if (i >= l.followed.items.len) continue;
        const below = l.followed.items[i];
        if (below == link or !path_cmp.within(link.path, below.path)) continue;
        host.unregister(io, below.id);
        l.forget(below);
    }
    host.unregister(io, link.id);
    l.forget(link);
}

fn remember(l: *Links, subject: []const u8) Allocator.Error!void {
    if (l.isIdle(subject)) return;
    const owned = try l.gpa.dupe(u8, subject);
    errdefer l.gpa.free(owned);
    try l.idle.append(l.gpa, owned);
}

fn isIdle(l: *const Links, subject: []const u8) bool {
    for (l.idle.items) |item| if (path_cmp.eql(item, subject)) return true;
    return false;
}

/// Forgets the idle links at `subject`, or at and below it.
fn wake(l: *Links, subject: []const u8, below: bool) void {
    var i: usize = 0;
    while (i < l.idle.items.len) {
        const item = l.idle.items[i];
        const named = if (below) path_cmp.within(subject, item) else path_cmp.eql(subject, item);
        if (!named) {
            i += 1;
            continue;
        }
        l.gpa.free(item);
        _ = l.idle.swapRemove(i);
    }
}

/// Whether a followed link still leads where it was followed to, and is
/// still something the watch is about.
fn stands(l: *const Links, io: Io, link: *const Link) bool {
    if (l.prunes(io, link.path)) return false;
    const named = Io.Dir.cwd().statFile(io, link.path, .{ .follow_symlinks = false }) catch return false;
    if (named.kind != .sym_link) return false;
    const now = identityOf(io, link.path) orelse return false;
    return now.eql(link.identity);
}

/// Looks again at the followed links at `subject`, or at and below it:
/// one that is gone, or leads somewhere else now, is let go with what it
/// led to, and followed again where it leads now. Whether any went.
fn recheck(l: *Links, io: Io, host: Host, batch: *Batch, subject: []const u8, below: bool) Allocator.Error!bool {
    var went = false;
    var i: usize = 0;
    while (i < l.followed.items.len) {
        const link = l.followed.items[i];
        const named = if (below) path_cmp.within(subject, link.path) else path_cmp.eql(subject, link.path);
        if (!named or l.stands(io, link)) {
            i += 1;
            continue;
        }
        const spelled = try l.gpa.dupe(u8, link.path);
        defer l.gpa.free(spelled);
        l.unfollow(io, host, link);
        went = true;
        // A link changed to lead somewhere else is followed there.
        if (try l.follow(io, host, batch, spelled)) |again| try l.followBelow(io, host, batch, again.path);
        // The list shrank by an unknown number of entries below this one.
        i = 0;
    }
    return went;
}

/// Follows, where they can be now, the idle links.
fn retry(l: *Links, io: Io, host: Host, batch: *Batch) Allocator.Error!void {
    var waited = l.idle;
    l.idle = .empty;
    defer {
        for (waited.items) |item| l.gpa.free(item);
        waited.deinit(l.gpa);
    }
    for (waited.items) |item| {
        if (try l.follow(io, host, batch, item)) |link| try l.followBelow(io, host, batch, link.path);
    }
}

/// Follows what changed under the watch since the last time: links that
/// appeared, links that changed or went, and directories that arrived
/// with links in them. `notes` may hold other watches' notes, which are
/// passed over.
pub fn settle(l: *Links, io: Io, host: Host, batch: *Batch, notes: []const Batch.Note) Allocator.Error!void {
    errdefer l.stale = true;
    if (l.stale) {
        l.stale = false;
        return l.refresh(io, host, batch);
    }
    var went = false;
    for (notes) |item| {
        if (item.id != l.owner) continue;
        if (try l.noted(io, host, batch, item)) went = true;
    }
    if (went) try l.retry(io, host, batch);
}

/// Looks at every link again: the ones followed, the idle ones, and
/// every link anywhere under the root.
pub fn refresh(l: *Links, io: Io, host: Host, batch: *Batch) Allocator.Error!void {
    errdefer l.stale = true;
    _ = try l.recheck(io, host, batch, l.root, true);
    try l.retry(io, host, batch);
    try l.followBelow(io, host, batch, l.root);
}

/// What one change means for the links. Whether a followed link went.
fn noted(l: *Links, io: Io, host: Host, batch: *Batch, item: Batch.Note) Allocator.Error!bool {
    switch (item.kind) {
        // Retargeting a link in place shows as a change to its metadata
        // on the backends that compare listings.
        .modified, .attributes => {
            if (l.find(item.path) != null) return l.recheck(io, host, batch, item.path, false);
            if (!l.isIdle(item.path)) return false;
            l.wake(item.path, false);
            if (try l.follow(io, host, batch, item.path)) |link| try l.followBelow(io, host, batch, link.path);
            return false;
        },
        // A name that went may be back already: FSEvents can report a
        // link replaced in one breath as removed while the new one stands.
        .removed, .created, .renamed => {
            l.wake(item.path, true);
            const went = try l.recheck(io, host, batch, item.path, true);
            const named = Io.Dir.cwd().statFile(io, item.path, .{ .follow_symlinks = false }) catch return went;
            switch (named.kind) {
                .sym_link => if (try l.follow(io, host, batch, item.path)) |link| try l.followBelow(io, host, batch, link.path),
                .directory => try l.followBelow(io, host, batch, item.path),
                else => {},
            }
            return went;
        },
        .closed, .overflow, .unwatched => return false,
    }
}

/// Replaces the filter the links are judged by. The registrations keep
/// asking it; the caller refilters them and then refreshes.
pub fn refilter(l: *Links, next: Filter) Allocator.Error!void {
    const replacement = try CompiledFilter.recompile(l.gpa, next, l.filter.policy);
    l.filter.deinit();
    l.filter = replacement;
}

test "a link is followed only into a directory the watch does not reach" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/sub");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/plain", .data = "x" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const root = try std.Io.Dir.path.join(gpa, &.{ base, "root" });
    defer gpa.free(root);

    const Case = struct { link: []const u8, target: []const u8, verdict: std.meta.Tag(Verdict) };
    const cases = [_]Case{
        .{ .link = "back", .target = "root", .verdict = .reached },
        .{ .link = "inside", .target = "root/sub", .verdict = .reached },
        .{ .link = "above", .target = ".", .verdict = .reached },
        .{ .link = "out", .target = "outside", .verdict = .follow },
        .{ .link = "to-file", .target = "file", .verdict = .idle },
        .{ .link = "dangling", .target = "missing", .verdict = .idle },
    };
    for (cases) |case| {
        const target = try std.Io.Dir.path.join(gpa, &.{ base, case.target });
        defer gpa.free(target);
        const at = try std.Io.Dir.path.join(gpa, &.{ "root", case.link });
        defer gpa.free(at);
        tmp.dir.symLink(io, target, at, .{ .is_directory = case.verdict != .idle }) catch |err| {
            // Windows asks for a privilege to make a symbolic link.
            if (builtin.target.os.tag == .windows) return error.SkipZigTest;
            return err;
        };
    }

    // Nothing is followed here, so nothing is registered or let go.
    const Idle = struct {
        fn issue(_: *anyopaque) WatchId {
            unreachable;
        }
        fn register(_: Io, _: *anyopaque, _: *Link) Host.RegisterError!void {
            unreachable;
        }
        fn unregister(_: Io, _: *anyopaque, _: WatchId) void {}
    };
    var nothing: u8 = 0;
    const idle: Host = .{ .context = &nothing, .issue_fn = Idle.issue, .register_fn = Idle.register, .unregister_fn = Idle.unregister };
    const l = (try create(gpa, io, @fromBackingInt(@intCast(0)), root, .none, .{}, null, 64)) orelse return error.SkipZigTest;
    defer l.destroy(io, idle);
    for (cases) |case| {
        const subject = try std.Io.Dir.path.join(gpa, &.{ root, case.link });
        defer gpa.free(subject);
        const verdict = try l.consider(io, subject);
        defer if (verdict == .follow) gpa.free(verdict.follow.target);
        try testing.expectEqual(case.verdict, std.meta.activeTag(verdict));
    }
    const plain = try std.Io.Dir.path.join(gpa, &.{ root, "plain" });
    defer gpa.free(plain);
    try testing.expectEqual(Verdict.none, try l.consider(io, plain));

    // Past the most a watch follows, the one link that would be followed is not.
    l.max = 0;
    const out = try std.Io.Dir.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out);
    try testing.expectEqual(Verdict.full, try l.consider(io, out));
}

test "one directory has one identity by every name, and another has its own" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "one/inner");
    try tmp.dir.createDirPath(io, "two");
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const one = try std.Io.Dir.path.join(gpa, &.{ root, "one" });
    defer gpa.free(one);
    const again = try std.Io.Dir.path.join(gpa, &.{ root, "one", "inner", ".." });
    defer gpa.free(again);
    const two = try std.Io.Dir.path.join(gpa, &.{ root, "two" });
    defer gpa.free(two);
    const missing = try std.Io.Dir.path.join(gpa, &.{ root, "missing" });
    defer gpa.free(missing);

    const first = identityOf(io, one).?;
    try std.testing.expect(first.eql(identityOf(io, again).?));
    try std.testing.expect(!first.eql(identityOf(io, two).?));
    try std.testing.expect(identityOf(io, missing) == null);
}
