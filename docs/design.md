# lookout design

lookout is one API for watching files and directory trees over FSEvents,
`kqueue`, `inotify`, `ReadDirectoryChangesW` and polling. This page says how it
is put together and why: the layers, who owns which state, what always holds,
and the decisions that shaped it. The README says what it does and how to use
it.

## The claim

A program written against `Watcher` sees the same events whichever mechanism is
underneath. Where a mechanism cannot give the same thing, the difference is not
hidden and not guessed at: it is a predicate the program can ask before it
depends on it (`pairsRenames`, `reportsRootMove`, `reportsCloses`,
`prunesIgnored`, `tracksCheckpoint`), and each answer is absolute, so a caller
can `switch` on it without a fallback arm. A kind of event that silently meant
nothing on four backends out of five would be worse than no kind at all, so
`closed` is off by default and `reportsCloses` says who can tell.

The contract is held by test, not by promise. One suite runs once for every
backend the target can execute, and the polling backend, which is built and
selectable everywhere, is held to the same assertions on the same machine. A
behaviour only a kernel backend has is a behaviour a caller cannot rely on, so
it does not belong in the contract.

## Layers

From the top, as `ci/layers.zig` lists them from the bottom:

```
 watcher            Watcher: the set of watches, their ids, poll, wake, pending watches
 platform backends  FsEvents, Kqueue, Inotify, Windows, Poll, and which of them a target has
 operation contracts  the results watcher and backends share
 watch trees        Tree (a registration per node), Links (followed symbolic links)
 batching           Batch: the events of one window, coalescing, holds, the ceiling
 configuration      Options, AddOptions
 snapshots          Baseline, Checkpoint
 baseline storage   the versioned, checksummed file format
 records            Snapshot (a directory's listing), checkpoint records, FSEvents records
 event contracts    Kind, Event, WatchId, Backend and the predicates
 path policy        Budget (entries per directory), CompiledFilter
 primitives         timing, path, walk, buffer sizing, filesystem facts, name identity, Filter, trace
```

Each layer imports only the ones below it. The rule is not a convention:
every production source has exactly one place in that list, and gantry's lint
fails a source that imports upward or has none.

The decoders of bytes someone else wrote (the `inotify` read, the
`FILE_NOTIFY_INFORMATION` chain, an FSEvents delivery) are files of their own,
compiled on every target. A parser is fuzzed, and a decoder that only exists on
one operating system can only be fuzzed there, which for a backend whose host is
a CI runner would be nowhere a change is written.

`backend.zig` writes the union of backends out per target instead of
generating it, because the set really differs per target and a reader should
see which. A comptime check holds `supported` equal to what the union contains.

## One owner per state

| State | Owner |
|---|---|
| The watches, and the ids issued for them | `Watcher`; ids come from a checked counter and are never reissued, and a watcher that has issued them all refuses the next `add` |
| The events of one window; coalescing; what is held back; the ceiling | `Batch` |
| Entries counted per directory, against `max_dir_entries` | `Budget` |
| A registration per directory of a recursive watch (`kqueue`, polling) | `Tree` |
| A directory's last listing, to name what changed by comparison | `Snapshot` (kept by `kqueue` and polling; `inotify` is told the name and keeps none) |
| Which symbolic links a watch follows, by device and inode or volume and file id | `Links`, and nowhere else: no backend knows links exist |
| What a pattern matches | sweep, through `CompiledFilter`; `Filter` is data a caller fills and owns nothing |
| What a filesystem does with names | `filesystem` and `identity`, measured per root and per directory |
| The FSEvents delivery buffer | the delivery `Sink`, behind an aegis lock the system's thread and `poll` share |
| The history an FSEvents checkpoint resumes from | `Checkpoint.History`, a shared revision a checkpoint leases rather than copies |
| A tree as it was, for answering an overflow or a restart | `Baseline`, the caller's; its file is written through airlock |
| How another thread ends a blocked `poll` | The watcher's `reactor.Wake`, made at `init` and only signaled after; on Windows also the completion port, fixed at `init` |
| How a backend waits, and the arithmetic on timeouts around it | `timing`, over reactor's `waitAny`; the backends hold no clock arithmetic of their own |

`Watcher` is not thread-safe, and only three of its fields are touched by
another thread: the `woken` flag, the `Wake` and, on Windows, the port. `wake`
never reads the backend's state, because reading any of it, even to learn which
backend this is, races with the polling thread's writes. `woken` is the fact
and the `Wake` only ends a sleep, so a wake that finds nothing waiting is kept
by the flag, and the object it left set costs the next wait one early return
that the loop absorbs.

## What always holds

- **lookout starts no thread and calls nothing back.** Everything happens on the
  thread that calls `poll`. On Apple targets the system delivers on a dispatch
  queue it owns; that thread copies each path and its flags into a fixed
  buffer under a short lock and writes one byte to a pipe, and nothing else.
  A test counts allocations made while that lock is held: there are none.
- **`std.Io` is never stored.** `init`, `add`, `remove`, `refilter`, `poll` and
  `deinit` each take the `io` they go through; `init`'s only makes the object
  `wake` sets. A baseline keeps its allocator and takes `io` per call; a
  checkpoint can outlive its watcher.
- **`poll` is a cancellation point on every backend, and a cancellation never
  costs an event.** Kernel backends read what the kernel handed them under
  cancel protection, because an event read and not yet recorded would be lost;
  the wait for the descriptor to have something takes nothing, so it alone is
  open to a cancellation, and one that lands anywhere else is reported after,
  with the batch intact for the next poll.
- **Loss is a notice, never silence.** A kernel queue that overflowed, a buffer
  that filled, a directory past `max_dir_entries`, a window past `max_events`
  and a watch the system had no room for all become `overflow` or `unwatched`
  events against the watch root, and an allocation failure that may have cost
  events does the same on the next `poll`. Those two kinds bypass every wait
  and outrank ordinary changes.
- **Every change within a watch's scope and filters made after `add` returns is
  reported**, subject to coalescing: one event per watch and path per window,
  keeping the most significant kind (`attributes` < `modified` < `closed` <
  `created` < `renamed` < `removed` < `overflow` < `unwatched`).
- **An event slice and its paths belong to the watcher until the next `poll`
  or `deinit`.** A `poll` that failed handed nothing out, and what it gathered
  is the next one's to return.
- **Kernel spellings are kept as they came.** Event paths and canonical roots
  are the kernel's; `WatchInfo.requested` keeps the caller's root. lookout makes
  no guess about Unicode equivalence or case that no query established.
- **A returned error set is one for all backends.** The backend is chosen when
  the watcher is made, not when the program is compiled, so a set per backend
  would be a set per value of an option.

## Decisions

### Backends

- **FSEvents is the Apple default, and `kqueue` an opt-in.** FSEvents recurses in
  the kernel, so a tree costs one stream and no descriptors; it names the entry
  that changed; it pairs the two halves of a rename; and it alone can say what
  happened before the watch existed. `kqueue` answers faster on a small tree
  but splits a rename in two and holds a descriptor per
  directory and per file. FSEvents has a measured system-delivery floor of
  about ten milliseconds even with `latency` zero, and the API says so rather
  than promising what the system will not give.
- **The backend is chosen per watch under `auto`.** A network or FUSE filesystem
  gets polling, since notification APIs do not see changes made elsewhere; local
  watches in the same watcher keep the native backend, and a watcher holds a
  polling registry beside it for the ones that do not. The type is measured
  with `statfs`/`statvfs`, or drive type and the remote-device flag on
  Windows. A failed or unavailable query reports `unknown` and keeps the
  default; an explicit backend choice is always kept.
- **Polling is a backend, not a fallback.** It needs nothing from the kernel, so
  it covers every target without a mechanism and every filesystem the mechanism
  cannot see, and it lets one suite hold every backend to one contract. A
  conservative tick checks entries whose times are not strictly older than their
  snapshot by content until they age, so a change within the timestamp's
  granularity is not missed.
- **`kqueue` and polling compare listings**; `inotify` and Windows are told the
  name. The comparison is the same one `Baseline` offers the caller, kept by the
  watcher instead.
- **fanotify is left out**: it needs `CAP_SYS_ADMIN`, which a library cannot ask
  of its program.
- **`ReadDirectoryChangesW` is read through a completion port** with one handle
  per watch, opened with `FILE_SHARE_DELETE` so watching a directory does not
  stop anyone deleting it. A completion port is not waitable by another loop,
  so `fd` is null there. A read completed with zero bytes means the kernel's
  buffer filled, and is `overflow`. A rename of the watched root happens in the
  parent, which the watch is not on, and is `silent`; the answer is a
  predicate, not a surprise.
- **The port stays lookout's; only its wait is reactor's.** reactor's
  `kernel.overlapped` issues one call from a task of its own runtime and
  answers `Unsupported` on any other `Io`. A watcher keeps one read outstanding
  per watch with no task to hold it, and runs on whatever `Io` its caller has,
  so the reads, their buffers and the port are lookout's and the one call that
  waits on the port goes through `reactor.blocking`. The port cannot be waited
  on beside a `Wake`, which is why `wake` also posts to it.

### Events and waiting

- **Three windows, each answering a different question.** `latency` merges what
  arrives together after the first event and reports the most significant kind.
  `settle` holds `modified` until the file has stopped changing, and nothing
  else, since a creation, a removal and a rename are facts about a name rather
  than contents. `debounce` holds every ordinary change until the path has been
  quiet and reports the kind seen last, which is what a caller rebuilding from
  the end state wants (a file created and removed in one window is one
  `removed`, removed and recreated one `created`, which coalescing by
  significance cannot say). `debounce` supersedes the other two.
- **A held path has a deadline of its own**, and the wait is the shorter of the
  caller's timeout and the next one due, so a `poll` with no timeout cannot
  sleep through a deadline the watcher set itself. A backend waits until the
  batch has *changed*, not until it has grown, for the same reason.
- **Time is `Io.Duration` and `Io.Timeout`, and the rounding is reactor's.** A
  backend waits through `reactor.waitAny` on its descriptor and the watcher's
  `Wake`, which rounds up so a wait never ends before its deadline, and an
  expired timeout still gets one non-blocking look, so a zero duration makes a
  check. Only the Windows port is waited on in milliseconds, which `timing`
  rounds the same way.
- **Every wait is reactor's, and what a cancellation can do follows.** On a
  reactor runtime the wait is an operation of the task's own loop: it holds no
  thread and a cancellation ends it. On any other `std.Io` it is the calling
  thread, looking for a cancellation every few milliseconds, which costs a
  wakeup in each. Windows is the exception: its wait is a call on the
  completion port that nothing interrupts, made through reactor's `blocking`
  so that it holds up no worker, and a cancellation lands when it returns.
- **`wake` is the one way to let go of a blocked `poll` from another thread.**
  It sets a flag and signals the `Wake` every backend's wait includes, and on
  Windows posts to the port; a wake that lands between two polls is kept for
  the next, which is why a task stops with a flag it reads between polls plus a
  `wake`, and not with either alone.
- **A rename is `renamed` with `from` where the backend pairs it**, and
  `removed` plus `created` where it cannot. A name a filter excludes is
  treated exactly as a name outside the watch, so a file saved by writing an
  excluded temporary and renaming it over a watched name is `created`, and an
  event never names an excluded path.

### Trees, links and filters

- **Pending watches.** A path that does not exist yet is registered on its
  nearest existing ancestor and promoted when it appears, under the id the
  caller already holds. Several can wait in one folder.
- **Symbolic links are not followed unless asked, and then by identity.** With
  `follow_symlinks` a link to a directory is watched as if the directory were
  there; a link into a directory the watch already reaches, or into one holding
  such a directory, is not followed, so a cycle is never walked and no
  directory is reported under two names. The decision is by device and inode,
  or volume and file id, never by path. Each followed link is a registration of
  its own, made with whatever backend the watcher uses, and `Links` spells what
  it reports under the link, so no backend learns that links exist. At most
  `max_followed_links` are followed; one past that is `unwatched`. A watch that
  follows links produces no checkpoint, since its history is not the log's.
- **Patterns are git's, and matching is sweep's.** One grammar for every site
  that matches a path in the family, so an exponential matcher is closed by
  construction and `a**/c` means what git means. A pattern git refuses is
  `InvalidPattern`. A watch's patterns are compiled into sets that answer for a
  path in one pass over it, whatever their number. lookout keeps the
  include/exclude policy and the predicate; it does not read ignore files,
  because negation, directory-only rules and precedence belong to a
  repository's own matcher, which a caller backs a predicate with.
- **Excluded directories are pruned where lookout recurses** (`inotify`,
  `kqueue`, polling): never opened, never registered. Where the kernel recurses
  (FSEvents, Windows) the filter can only drop the events; `prunesIgnored` is
  that difference.
- **Name matching follows what was measured.** Case sensitivity is read per
  volume (Darwin), per directory flag (Windows) or per supported
  filesystem/directory flag (Linux); normalization is unknown wherever no query
  establishes it. Unknown selects exact spelling and sensitive matching. The
  measured facts and the caller's policy are separate things: `AddOptions.identity`
  overrides the policy without changing what is reported, and `Filter.case` and
  `Filter.normalization` are independent preferences, with `.nfc` meaning
  canonical equivalence on composed scalars.
- **Entries are budgeted per directory, not per watch**: a recursive watch over
  twenty directories of three hundred entries is twenty directories inside a
  budget of a thousand. Every backend reaches the same signal, `overflow`, by
  its own route, so the code a caller writes to handle it is one.

### Answering a loss

- **`overflow` says the record is incomplete, not what was missed**, because
  nothing underneath knows. A `Baseline` makes the question answerable: seeded
  when the watch is taken, `diff` reads the tree again and returns the
  creations, modifications, attribute changes and removals since the last look,
  at the cost of one listing and one `stat` per entry per directory. It does
  not follow links, so for a watch that does it answers for the tree and not
  for what lies below its links.
- **A baseline can be saved and loaded on every backend**, so a restart can ask
  what changed while the program was away, with one walk. The file is versioned
  and SHA-256 checksummed, the checksum checked before any JSON is read. It is
  written through airlock: a temporary beside the destination, renamed over it,
  so a reader sees the old file or the new one, and durably (the temporary
  synced before the rename and the directory after) when asked. A file made on
  another platform, root, scope, budget or set of patterns is refused as
  `ForeignBaseline`, and a predicate filter, which cannot be stored, as
  `UnsupportedBaselineFilter`; the format refuses what it does not know.
- **A checkpoint is FSEvents' log, resumed.** Where the system keeps a
  persistent log, a checkpoint holds each watch's volume and log identity, its
  cursor, the changes read but not yet handed out, and the path baseline the
  watch knew, so a resumed watch reports a deletion since the checkpoint once,
  whatever order the records arrive in. Capture leases a shared revision rather
  than copying the tree; a path removed since is a tombstone kept until no
  lease can see it, and freed only on the watcher's thread, so a thread that
  merely drops a checkpoint never uses the watcher's allocator. A changed volume
  or log is `InvalidCheckpoint`; other backends return null. A checkpoint is
  taken after the events were processed, so a crash replays rather than loses.
- **Neither a baseline nor a checkpoint recovers transient changes** absent from
  both snapshots. lookout does not turn overflow recovery into a history.

### Tests

- **Counts and fakes before peers.** Resource cleanup, allocation under the
  delivery lock, cancellation, settling, filters and pending paths are tested
  on shakedown's clock, fault injection and counting allocator; the durable
  save's syncs are counted and failed through airlock's test seam.
- **Parsers are fuzzed** from any host, because their files compile everywhere.
- **Speed claims are ceilings, not rows.** `zig build bench` holds each claim
  (a change reaching a blocked poll, a rename then delete, a cancel before a
  poll, a wake from a thread, stopping by flag) to its ceiling on every backend
  the target has, in ReleaseFast, on a quiet machine. CI runs each once with
  `--smoke` and judges nothing.
- **Environment is read once, for a trace.** `LOOKOUT_TRACE` turns on one log
  line per backend decision; unset, the cost is one relaxed load.

## Left out, and why

- **Guaranteed delivery of every intermediate write or rename.** The mechanisms
  coalesce and drop; lookout reports the end state and says when it lost track.
- **A history of transient changes** after an overflow, or on a backend with no
  persistent log.
- **Reading ignore files.** See above: a pattern is one line, the rest is a
  predicate's.
- **An application event loop or a rebuild policy.** `fd` hands out a pollable
  descriptor where the backend has one, and `wake` and `poll`'s timeout cover the
  rest; what to do with an event is the program's.
- **fanotify**, for its privilege.
