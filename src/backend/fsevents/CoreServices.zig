//! The CoreFoundation and CoreServices functions lookout calls, opened from
//! the system's CoreServices framework when the first FSEvents watcher is
//! made, rather than linked. A build for an Apple target then needs nothing
//! but what Zig ships: no SDK, no framework stubs, on any host.
//!
//! Each field is one symbol: its name is the symbol's, and its type is the
//! declaration, in Apple's C ABI. The CoreFoundation symbols resolve
//! through CoreServices, which links CoreFoundation, as they did when
//! lookout linked the framework.

const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");

const CoreServices = @This();

// Apple's names, in Zig's casing: `CFStringRef` is `CfStringRef`.
pub const CfAllocatorRef = ?*anyopaque;
pub const CfStringRef = *anyopaque;
pub const CfArrayRef = *anyopaque;
pub const CfUuidRef = *anyopaque;
pub const FsEventStreamRef = *anyopaque;
pub const dispatch_queue_t = *anyopaque;

pub const FsEventStreamContext = extern struct {
    version: c_long = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copyDescription: ?*const anyopaque = null,
};

pub const FsEventStreamCallback = *const fn (
    stream: FsEventStreamRef,
    info: ?*anyopaque,
    num_events: usize,
    event_paths: ?*anyopaque,
    event_flags: [*]const u32,
    event_ids: [*]const u64,
) callconv(.c) void;

pub const CfUuidBytes = extern struct { bytes: [16]u8 };

/// Where the framework is on every macOS: in the dyld shared cache since
/// macOS 11, which `dlopen` reads by this path.
pub const path = "/System/Library/Frameworks/CoreServices.framework/CoreServices";

// CoreFoundation.

/// A data symbol: its address is the `CFArrayCallBacks` FSEvents' path
/// array is made with.
kCFTypeArrayCallBacks: *const anyopaque,
CFStringCreateWithBytes: *const fn (
    alloc: CfAllocatorRef,
    bytes: [*]const u8,
    num_bytes: c_long,
    encoding: u32,
    is_external_representation: u8,
) callconv(.c) ?CfStringRef,
CFArrayCreate: *const fn (
    allocator: CfAllocatorRef,
    values: [*]const ?*const anyopaque,
    num_values: c_long,
    call_backs: ?*const anyopaque,
) callconv(.c) ?CfArrayRef,
CFRelease: *const fn (cf: *anyopaque) callconv(.c) void,
CFAbsoluteTimeGetCurrent: *const fn () callconv(.c) f64,
CFUUIDGetUUIDBytes: *const fn (uuid: CfUuidRef) callconv(.c) CfUuidBytes,

// CoreServices: FSEvents.

FSEventStreamCreate: *const fn (
    allocator: CfAllocatorRef,
    callback: FsEventStreamCallback,
    context: ?*FsEventStreamContext,
    paths_to_watch: CfArrayRef,
    since_when: u64,
    latency: f64,
    flags: u32,
) callconv(.c) ?FsEventStreamRef,
FSEventStreamCreateRelativeToDevice: *const fn (
    allocator: CfAllocatorRef,
    callback: FsEventStreamCallback,
    context: ?*FsEventStreamContext,
    device: i32,
    paths: CfArrayRef,
    since: u64,
    latency: f64,
    flags: u32,
) callconv(.c) ?FsEventStreamRef,
FSEventStreamSetDispatchQueue: *const fn (stream: FsEventStreamRef, q: ?dispatch_queue_t) callconv(.c) void,
FSEventStreamStart: *const fn (stream: FsEventStreamRef) callconv(.c) u8,
FSEventStreamStop: *const fn (stream: FsEventStreamRef) callconv(.c) void,
FSEventStreamInvalidate: *const fn (stream: FsEventStreamRef) callconv(.c) void,
FSEventStreamRelease: *const fn (stream: FsEventStreamRef) callconv(.c) void,
FSEventStreamGetLatestEventId: *const fn (stream: FsEventStreamRef) callconv(.c) u64,
FSEventStreamGetDeviceBeingWatched: *const fn (stream: FsEventStreamRef) callconv(.c) i32,
FSEventsGetCurrentEventId: *const fn () callconv(.c) u64,
FSEventsGetLastEventIdForDeviceBeforeTime: *const fn (device: i32, time: f64) callconv(.c) u64,
FSEventsCopyUUIDForDevice: *const fn (device: i32) callconv(.c) ?CfUuidRef,

/// The one table in the process, filled by the first `load` to succeed.
var loaded: aegis.Lazy(CoreServices) = .init();

/// The functions, opened the first time this is called; later calls,
/// from any thread, return the same table. `io` is what a caller that
/// arrives while another is opening the framework waits through.
/// `error.BackendUnavailable` when the framework or one of its symbols is
/// not there; the next call tries again.
pub fn load(io: Io) error{BackendUnavailable}!*const CoreServices {
    return loaded.getOrInit(io, @as([]const u8, path), open);
}

/// The table `load` returned, for code that runs only after it has: a
/// stream exists only once its watcher's `load` succeeded.
pub fn get() ?*const CoreServices {
    return loaded.get();
}

/// Every symbol, looked up in the library at `framework` into `table`,
/// which is left alone on failure.
fn open(framework: []const u8, table: *CoreServices) error{BackendUnavailable}!void {
    var library = std.DynLib.open(framework) catch return error.BackendUnavailable;
    var resolved: CoreServices = undefined;
    const symbols = @typeInfo(CoreServices).@"struct";
    inline for (symbols.field_names, symbols.field_types) |name, Symbol| {
        @field(resolved, name) = library.lookup(Symbol, name) orelse {
            library.close();
            return error.BackendUnavailable;
        };
    }
    // The library stays open: the table points into it for the life of
    // the process.
    table.* = resolved;
}

test "every symbol resolves from the system framework" {
    const table = try load(std.testing.io);
    try std.testing.expectEqual(table, try load(std.testing.io));
    try std.testing.expect(table.FSEventsGetCurrentEventId() > 0);
}

test "a missing framework or symbol is an error, not a crash" {
    var table: CoreServices = undefined;
    try std.testing.expectError(error.BackendUnavailable, open("/System/Library/Frameworks/Missing.framework/Missing", &table));
    // CoreFoundation is there, and FSEvents is not in it.
    try std.testing.expectError(error.BackendUnavailable, open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", &table));
}
