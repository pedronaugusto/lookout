//! Portable baseline storage. The checksum is checked before JSON is read.
const std = @import("std");
const strand = @import("strand");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Snapshot = @import("../Snapshot.zig");
const identity = @import("../identity.zig");
const sweep = @import("sweep");
const path = @import("../path.zig");

pub const State = struct {
    platform: []const u8,
    root: []const u8,
    recursive: bool,
    max_dir_entries: usize,
    ignore: []const []const u8,
    only: []const []const u8,
    dirs: []const Directory,
    case: ?sweep.Case = null,
    normalization: ?identity.Policy.Normalization = null,
    policy: identity.Policy = .{},
    identity_override: ?identity.Policy = null,
    /// A root and a name are bytes the system gave: text when they are UTF-8.
    pub const strand = .{ .fields = .{ .root = .{ .as = .text_or_bytes }, .ignore = .{ .as = .text_or_bytes }, .only = .{ .as = .text_or_bytes } } };
};
pub const Directory = struct {
    path: []const u8,
    truncated: bool,
    check_contents: bool,
    entries: []const Entry,
    policy: identity.Policy = .{},
    pub const strand = .{ .fields = .{ .path = .{ .as = .text_or_bytes } } };
};
pub const Entry = struct {
    name: []const u8,
    meta: Snapshot.Meta,
    pub const strand = .{ .fields = .{ .name = .{ .as = .text_or_bytes } } };
};
pub const ParseError = error{ OutOfMemory, InvalidBaseline, UnsupportedBaselineVersion, ForeignBaseline };
const magic = "LOOKBASE";
/// The layout `encode` writes and `parse` reads: the magic, the version,
/// then the checksum of the JSON after them.
const version: u32 = 2;
const version_at = magic.len;
const digest_at = version_at + @sizeOf(u32);
const Sha256 = std.crypto.hash.sha2.Sha256;
const header_size = 44;

comptime {
    assert(header_size == digest_at + Sha256.digest_length);
}
pub const platform = @tagName(builtin.target.os.tag);
pub const file_limit = 256 * 1024 * 1024;

pub fn encode(gpa: std.mem.Allocator, state: State) std.mem.Allocator.Error![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    strand.json.write(&text.writer, state, .{ .limits = .sized(std.math.maxInt(usize)) }) catch |err| return switch (err) {
        error.WriteFailed, error.OutOfMemory => error.OutOfMemory,
        // unreachable: names and patterns are text or bytes, within limits as large as memory
        else => unreachable,
    };
    const payload = text.written();
    const bytes = try gpa.alloc(u8, header_size + payload.len);
    @memcpy(bytes[0..version_at], magic);
    std.mem.writeInt(u32, bytes[version_at..digest_at], version, .little);
    Sha256.hash(payload, bytes[digest_at..header_size], .{});
    @memcpy(bytes[header_size..], payload);
    return bytes;
}

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!strand.json.Parsed(State) {
    if (bytes.len < header_size or bytes.len > file_limit or !std.mem.eql(u8, bytes[0..version_at], magic)) return error.InvalidBaseline;
    if (std.mem.readInt(u32, bytes[version_at..digest_at], .little) != version) return error.UnsupportedBaselineVersion;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes[header_size..], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[digest_at..header_size])) return error.InvalidBaseline;
    // A baseline is bounded by its file: every name in it is spelled there.
    var parsed = strand.json.parseOwned(State, gpa, bytes[header_size..], .{ .limits = .sized(bytes.len) }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidBaseline,
    };
    errdefer parsed.deinit();
    const state = parsed.value;
    if (!std.mem.eql(u8, state.platform, @tagName(builtin.target.os.tag))) return error.ForeignBaseline;
    if (!std.Io.Dir.path.isAbsolute(state.root) or !safePath(state.root)) return error.InvalidBaseline;
    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    defer dirs.deinit(gpa);
    for (state.dirs) |dir| {
        const rel = path.relative(state.root, dir.path) orelse return error.InvalidBaseline;
        if ((!state.recursive and rel.len != 0) or !safePath(rel)) return error.InvalidBaseline;
        const found = try dirs.getOrPut(gpa, dir.path);
        if (found.found_existing) return error.InvalidBaseline;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(gpa);
        for (dir.entries) |entry| {
            if (entry.name.len == 0 or !safePath(entry.name) or std.mem.findAny(u8, entry.name, path.separators) != null) return error.InvalidBaseline;
            const named = try names.getOrPut(gpa, entry.name);
            if (named.found_existing) return error.InvalidBaseline;
        }
    }
    if (state.dirs.len != 0 and !dirs.contains(state.root)) return error.InvalidBaseline;
    return parsed;
}

fn safePath(text: []const u8) bool {
    if (std.mem.findScalar(u8, text, 0) != null) return false;
    var it = std.mem.tokenizeAny(u8, text, path.separators);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}
