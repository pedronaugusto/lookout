//! How another thread makes a blocked `lookout.Watcher.poll` come back.
//!
//! Taken from the backend once, by `lookout.Watcher.init`, and never
//! written again, so `lookout.Watcher.wake` reaches the backend without
//! reading the backend's state. That is the whole point of it: that state
//! is the polling thread's to write while `wake` runs on another, and
//! reading any of it -- even only to find out which backend this is,
//! which a switch on the backend union is free to do by loading the whole
//! union -- is a data race with those writes.
//!
//! So what a backend hands over here is something that does not move and
//! does not change: a descriptor, a handle, or a pointer to state it
//! allocated once and shares with other threads on purpose.

const Waker = @This();

/// What `call` needs, as the backend packed it.
context: usize,
/// Pokes the backend's wait. Called from any thread.
call: *const fn (context: usize) void,

/// Makes the backend's wait come back.
pub fn wake(w: Waker) void {
    w.call(w.context);
}

/// For a backend with nothing to interrupt. The `poll` backend sleeps in
/// slices and reads `lookout.Watcher`'s own flag between them.
pub const none: Waker = .{ .context = 0, .call = nothing };

fn nothing(context: usize) void {
    _ = context;
}
