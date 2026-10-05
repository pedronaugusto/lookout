# Watcher invariants

- A watcher issues each watch id once, from a counter that only grows: an id
  `add` returns is in the watch table and below every id still to come, and
  `remove` leaves it in neither the table, the pending list nor the followed
  links. A pending watch waits on an ancestor of its path, narrowed to the one
  step below that ancestor on the way to it.
- The backend union a target builds holds exactly the backends `supported`
  names, and the poll backend in every shape; `Poll.init` cannot fail.
- A batch keeps one event per watch and path. Its index holds one position per
  event and names the event recorded for that watch and path. Only a paired
  rename carries `from`. Kinds rank in the order `Kind` documents, each kind on
  its own rank, with the two loss notices above every ordinary change. Notes
  for followed links stop at their limit and say they were lost.
- A polling tree keeps one index entry per node, and never reuses a node id.
  A directory listing holds at most its entry budget and is marked truncated
  only when it reached it.
- Buffer sizes stay within their backend's bounds and are whole words; the
  bounds are ordered and their floor is a whole word. A remaining timeout never
  exceeds the timeout, and one handed to Windows is never `INFINITE`.
- FSEvents records are a 20-byte header (id, flags and path length in 32 bits,
  event id in 64) and the path; inotify records a 16-byte header the size of
  `struct inotify_event`; Windows records a 12-byte header and a UTF-16 name.
  Encoders are given room for the whole record, decoders never step past the
  bytes they walk, and a Windows chain that continues continues inside the read.
  The FSEvents sink never fills past its buffer. A Windows read reports no more
  bytes than the buffer it was offered, which is never more than it has.
- A baseline file is the magic, a 32-bit version and the SHA-256 of the JSON
  after them, written and read at the same offsets. A checkpoint token carries
  the format version the watcher writes, names each root once, and its copy
  holds every watch.
- The shared path history is a list in order of birth: a node is published
  once, removed once after it was published, and the leases on it are kept
  newest first, so only the oldest can release what compaction frees. Every
  reference count is released no more often than it was taken.
- A followed link is adopted only below the watch's ceiling of followed links.
- Allocation failures during delivery are reported as overflow against every
  live root before a poll succeeds; best-effort work that cannot fail but for
  memory propagates `OutOfMemory`, and test threads record the error a write
  returned for the test to fail on.
