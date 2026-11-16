//! macOS's one call that reads a directory's entries with their attributes, getattrlistbulk(2),
//! declared as the system documents it: glint's P007 seam for it (glint.json), and nothing else
//! lives here. `walk.zig` reads what it returns.
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");

/// getattrlistbulk's `struct attrlist`: which attributes each entry carries.
pub const AttrList = extern struct {
    count: u16 = 5,
    reserved: u16 = 0,
    common: u32 = 0,
    volume: u32 = 0,
    directory: u32 = 0,
    file: u32 = 0,
    fork: u32 = 0,
};

extern "c" fn getattrlistbulk(c_int, *AttrList, *anyopaque, usize, u64) c_int;

/// Fills `buffer` with the next entries of the open directory `fd` with the attributes `attrs`
/// names: how many it wrote, 0 at the end, negative on failure. `buffer` holds at least one
/// entry's attributes, which the system requires and the caller sizes.
pub fn list(fd: c_int, attrs: *AttrList, buffer: []u8) c_int {
    comptime std.debug.assert(builtin.os.tag.isDarwin());
    aegis.assert.invariant(buffer.len != 0, "getattrlistbulk takes a buffer for at least one entry");
    return getattrlistbulk(fd, attrs, buffer.ptr, buffer.len, 0);
}
