//! Which paths under a watch the caller wants, and which are not worth
//! watching at all.
//!
//! A filter is three things a caller can combine: a list of patterns
//! naming what to leave out, a list naming what to keep and nothing
//! else, and a predicate of their own for everything a pattern cannot
//! say. All three answer the same question -- is this path part of the
//! watch -- and the patterns to leave out and the predicate are asked
//! about every ancestor of a path, so excluding a directory excludes
//! everything below it without naming any of it.
//!
//! Where lookout does the recursion itself -- `inotify`, `kqueue` and
//! `poll` -- an excluded directory is never opened and never registered,
//! so it costs neither a kernel watch nor a descriptor. Where the kernel
//! recurses -- FSEvents and `ReadDirectoryChangesW` -- the work is the
//! kernel's and the filter can only save the caller the event. That
//! difference is `lookout.prunesIgnored`.
//!
//! An excluded path is treated exactly as a path outside the watch. A
//! rename between a name the filter keeps and one it excludes is
//! reported as a rename in or out of the watch would be: `created` at the
//! kept new name, `removed` at the kept old one. See
//! `lookout.pairsRenames`.
//!
//! On Apple and Windows targets, comparisons fold ASCII and Latin-1 case
//! and composition, so `*.TMP` excludes `notes.tmp`. Other Unicode
//! scripts are compared as written. See `path.folds_case`.

const Filter = @This();

/// Patterns naming what this watch is not about, matched against each
/// path below the watch root.
///
/// A pattern is matched against the path relative to the watch root,
/// unless it is itself absolute, in which case it is matched against the
/// absolute path. The syntax is git's, as in a `.gitignore` line, matched
/// by [sweep](https://github.com/pedronaugusto/sweep):
///
/// * `*` matches any run of characters within one path component, `?`
///   exactly one character, and `[a-z]` or `[!a-z]` one character from a
///   set or outside it. None of them matches a separator.
/// * `**` standing as a whole component matches any number of
///   components, none included: `build/**` is everything below `build`,
///   and `src/**/*.zig` covers `src/main.zig` as well as
///   `src/deep/main.zig`. Anywhere else, as in `a**b`, it is `*`.
/// * `\` makes the character after it literal, except on Windows, where
///   it is a separator like `/`.
/// * A pattern holding no separator is matched against the final
///   component at any depth, so `node_modules` excludes one wherever it
///   is and `*.tmp` excludes the temporary files wherever they are
///   written.
/// * A pattern that matches a directory excludes everything below it,
///   because every ancestor of a path is tested as well as the path.
///
/// A pattern git would refuse -- an unclosed `[`, an unknown `[:class:]`,
/// a trailing `\` -- makes `lookout.Watcher.add` return
/// `error.InvalidPattern`. Empty patterns are ignored.
///
/// Borrowed only for the duration of `lookout.Watcher.add`, which copies
/// what it keeps.
ignore: []const []const u8 = &.{},

/// Patterns naming what this watch *is* about, in the same syntax. Empty,
/// the default, means everything the other two allow.
///
/// A path is reported when it matches one of these, and a directory is
/// walked into when a pattern could still match something inside it --
/// otherwise `only = &.{"src/**/*.zig"}` would exclude `src` and take
/// the files under it with it. So an include list narrows the events
/// without narrowing the walk further than it has to.
///
/// `ignore` wins: a path named by both is excluded.
only: []const []const u8 = &.{},

/// The caller's own answer, asked for every path a pattern did not
/// already exclude, and for each of its ancestors. Returning `false`
/// excludes the path, and with it everything below it when the path is a
/// directory.
///
/// It is asked about a directory before that directory is registered,
/// as the patterns are, so where lookout does the recursion a directory
/// it excludes is never opened and never costs a kernel watch or a
/// descriptor. A predicate backed by a repository's ignore rules prunes
/// the ignored trees exactly as `ignore` would. It is not told whether
/// the path is a directory; a rule that applies only to directories
/// has to look.
///
/// `path` is absolute, and is the path as lookout spells it. `context` is
/// whatever was put in `context`, which lookout only passes back.
allow: ?*const fn (context: ?*anyopaque, path: []const u8) bool = null,

/// Passed to `allow` untouched. lookout never dereferences it; keeping
/// whatever it points at alive for the life of the watch is the caller's.
context: ?*anyopaque = null,

/// A filter that excludes nothing, which is what a watch has unless the
/// caller says otherwise.
pub const none: Filter = .{};
