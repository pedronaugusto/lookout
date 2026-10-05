//! Portable baseline storage. The checksum is checked before JSON is read.
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Snapshot = @import("../Snapshot.zig");
const path = @import("../path.zig");

pub const State = struct {
    platform: []const u8,
    root: []const u8,
    recursive: bool,
    max_dir_entries: usize,
    ignore: []const []const u8,
    only: []const []const u8,
    dirs: []const Directory,
};
pub const Directory = struct {
    path: []const u8,
    truncated: bool,
    check_contents: bool,
    entries: []const Entry,
};
pub const Entry = struct { name: []const u8, meta: Snapshot.Meta };
pub const ParseError = error{ OutOfMemory, InvalidBaseline, UnsupportedBaselineVersion, ForeignBaseline };
const magic = "LOOKBASE";
/// The layout `encode` writes and `parse` reads: the magic, the version,
/// then the checksum of the JSON after them.
const version: u32 = 1;
const version_at = magic.len;
const digest_at = version_at + @sizeOf(u32);
const Sha256 = std.crypto.hash.sha2.Sha256;
const header_size = 44;

comptime {
    assert(header_size == digest_at + Sha256.digest_length);
}
pub const platform = @tagName(builtin.os.tag);
pub const file_limit = 256 * 1024 * 1024;

pub fn encode(gpa: std.mem.Allocator, state: State) std.mem.Allocator.Error![]u8 {
    const payload = try std.json.Stringify.valueAlloc(gpa, state, .{});
    defer gpa.free(payload);
    const bytes = try gpa.alloc(u8, header_size + payload.len);
    @memcpy(bytes[0..version_at], magic);
    std.mem.writeInt(u32, bytes[version_at..digest_at], version, .little);
    Sha256.hash(payload, bytes[digest_at..header_size], .{});
    @memcpy(bytes[header_size..], payload);
    return bytes;
}

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!std.json.Parsed(State) {
    if (bytes.len < header_size or bytes.len > file_limit or !std.mem.eql(u8, bytes[0..version_at], magic)) return error.InvalidBaseline;
    if (std.mem.readInt(u32, bytes[version_at..digest_at], .little) != version) return error.UnsupportedBaselineVersion;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes[header_size..], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[digest_at..header_size])) return error.InvalidBaseline;
    var parsed = std.json.parseFromSlice(State, gpa, bytes[header_size..], .{ .allocate = .alloc_always }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidBaseline,
    };
    errdefer parsed.deinit();
    const state = parsed.value;
    if (!std.mem.eql(u8, state.platform, @tagName(builtin.os.tag))) return error.ForeignBaseline;
    if (!std.fs.path.isAbsolute(state.root) or !safePath(state.root)) return error.InvalidBaseline;
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
            if (entry.name.len == 0 or !safePath(entry.name) or std.mem.indexOfAny(u8, entry.name, path.separators) != null) return error.InvalidBaseline;
            const named = try names.getOrPut(gpa, entry.name);
            if (named.found_existing) return error.InvalidBaseline;
        }
    }
    if (state.dirs.len != 0 and !dirs.contains(state.root)) return error.InvalidBaseline;
    return parsed;
}

fn safePath(text: []const u8) bool {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return false;
    var it = std.mem.tokenizeAny(u8, text, path.separators);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}
