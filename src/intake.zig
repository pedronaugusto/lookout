//! Where bytes from outside enter lookout: a baseline file it is handed, a watched file's
//! contents it hashes, and the kernel's event records on inotify. Each read is made here, so
//! the entry points are these few; a whole file comes back as `aegis.input.Untrusted`, which
//! its parser reads by `readForParse`. glint's A009 seam is this file alone (glint.json).
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// Bytes from outside, before a parser refines them.
pub const Bytes = aegis.input.Untrusted([]const u8);

/// A file's whole contents, at most `limit` bytes, as aegis reads them: a cancel that lands on
/// the file's length is `Canceled`. The bytes are `gpa`'s.
pub fn readFile(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: aegis.units.Bytes(u64)) aegis.own.ReadFileError!Bytes {
    return .init(try aegis.own.readFile(io, dir, path, gpa, limit));
}

/// Reads `file` at `offset` into `buffer` until it is full or the file ends, as
/// `File.readPositionalAll`: a watched file's contents, which lookout hashes and never parses.
pub fn readPositionalAll(file: Io.File, io: Io, buffer: []u8, offset: u64) Io.File.ReadPositionalError!usize {
    return file.readPositionalAll(io, buffer, offset);
}

/// One read of the descriptor `fd` into `buffer`, as `posix.read`: inotify's event records,
/// which the backend's record reader walks.
pub fn readDescriptor(fd: std.posix.fd_t, buffer: []u8) std.posix.ReadError!usize {
    return std.posix.read(fd, buffer);
}
