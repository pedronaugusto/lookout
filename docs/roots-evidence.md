# Filesystem identity and parsed NFC filtering

Work in progress toward the public cut. F03/F07 are implemented; publication
requires successful fast and merge gates at the exact candidate head.
The original published `roots` commit and all failing-before records remain
in history. `roots-initial.md` preserves the retired worker's report verbatim.

## Accepted contracts and ownership

The owner decisions are recorded in the book's packages-released mission at
`309bd974a045b64f93863b7931831fe9d0712910`. Unknown filesystem capability is
reported as unknown and selects exact spelling and sensitive matching.
`AddOptions.identity` can explicitly set matching policy without changing
reported facts. No platform default guesses filesystem Unicode semantics.
Darwin queries volume capabilities, Windows queries directory case flags,
and Linux queries ext4/f2fs directory naming flags. Unsupported filesystems
and failed probes remain unknown. Root and supported directory policies are
separate; polling retains directory facts, native Windows/inotify queries
entry parents, and queued refiltering and followed-link filtering use parent
policy as well. Explicit policy overrides remain in force for those paths. No caller Io
context is retained in link/alias state: live and deferred events receive the
current operation's Io. A pure traversal callback without directory facts
prunes only when both possible case policies refuse; explicit policy or case
preference prunes directly. This can admit extra directories for traversal,
while actual delivered matching uses the entry parent's policy. The Windows
FaultIo regression denies the current directory probe and checks exact unknown
fallback, rather than accidentally reusing add-time Io.

Kernel spelling is identity: roots resolve links and obtain kernel spelling;
path keys, events and baseline names compare exact canonical bytes. The
original caller spelling is independently retained as `WatchInfo.requested`.
Pending promotion canonicalizes the newly existing root without rewriting the
original request. Case-insensitive matching does not collapse byte keys.

Sweep is the only grammar, folding and composition owner. Lookout passes raw
glob text and selects sweep options; it has no Unicode tables, raw-glob
rewriter or second parser. NFC applies equally to patterns and names.
`[é]` matches composed/decomposed é and never plain e; `?` consumes one
composed scalar. Classes, ranges, negation, escapes and wildcard boundaries
follow composed scalars. A class member remaining several scalars is refused
at compile time. Sweep's complete Unicode 18 normalization corpus covers
canonical ordering, composition exclusions and Hangul; invalid bytes are
barriers. Git matching remains exact by default. Sweep queries remain bounded.

Filter case and normalization preferences remain separate from measured
capabilities and caller identity policy. Baseline format 2 and checkpoint
format 3 preserve preferences, policy and overrides; older formats are
refused. Breaking changes, including canonical-only path helpers and removed
OS-global folding, are described in CHANGELOG.md.

## Reproduced evidence and validation

Baseline main: lookout `24d0986362a0ff5e968338531a6abad0cd8b10d0`.
The fresh published roots checkout reproduces both original failures:
`f03-reproduced.txt` collapses `/w/A` and `/w/a`, and `f07-reproduced.txt`
shows `[é]` excluding plain e. Original `f03-before.txt`, `f07-before.txt`,
seven-run `filter-before.tsv`, and the original reports are preserved.

Focused after logs are `f03-after.txt`, `f07-after.txt`, `unknown-after.txt`,
`filter-allocation-after.txt`, and `wake-after.txt`, `links-after.txt`, and the final cross-compile records. They exercise mixed
root/directory policies, distinct canonical keys, caller overrides without
fabricated capability, native case-distinct files where supported, Unicode
root aliases, native composed filtering, raw pattern retention, multi-scalar
class refusal, saved filter policy, pending refilter policy, and
NoResize/checkAllAllocationFailures. `roots-checks-final.txt` records final
lint/check; native, Linux and Windows compile records are also retained.
Whole native suites are run by CI, not manually.

One local Debug benchmark smoke stalled during stop-by-flag; its stack sample
is retained in `smoke-sample.txt`. Focused wake tests, subsequent smoke runs
and all seven paired native ReleaseFast runs succeeded. No causal fix or
performance claim is attributed to that isolated observation; CI's required
native gates remain the landing requirement.

The first complete fast run (`37832497597`) found one stale assertion:
a pending symbolic-link refusal expected the caller alias as its event path.
The updated regression expects the resolved canonical path, independently
asserts the original request, and retains registration-count/no-duplicate
checks. `ci-fast-37832497597-failed.txt` preserves that log. The pending
promotion walk also selects each entry parent's policy.

## Interleaved ReleaseFast measurements

Quiet Apple M3 host, Zig 0.17.0, seven interleaved rounds, reversing acquisition
order on alternate rounds. `filter-ab.jsonl` contains all 31 samples per row
per round; `filter-ab-summary.txt` gives best and median of round-best values.
Each unit asks excludes and prunes of one path; numbers below divide the
unit by two. The fixed seed builds the same 20,000-path ASCII corpus.
`bench/filter.zig` is the candidate driver; `filter-before-driver.zig` uses
the same shakedown timing/workload with the historical constructor against
baseline production code. Both use the same green sweep/shakedown pins to
isolate lookout's changes. Original baseline measurements with original pins
remain separately preserved in `filter-reproduced.tsv` and `filter-before.tsv`.

| Row | Before | Exact | Folded | NFC |
|---|---:|---:|---:|---:|
| ignore 1 | 391.796 | 146.950 | 360.245 | 360.068 |
| ignore 20 | 476.473 | 234.210 | 272.541 | 273.238 |
| only 3 | 336.060 | 89.086 | 243.230 | 258.914 |
| ignore 20 + only 3 | 513.853 | 266.982 | 358.965 | 367.616 |

Best ns/question. ASCII answers agree across these policies; this is not a
speed comparison between inequivalent Unicode answers. Raw-text rewriting
and its query scratch buffer are removed. NFC and folded matching cost more
than exact matching; both remain faster than the historical implementation
on this corpus. The benchmark is evidence, not a timing correctness gate.

`native-ab.jsonl` and its summary preserve the first seven paired native
runs. A later Debug smoke returned UnexpectedEvents during idle wake;
the driver reused a fixture name across rows and had not drained setup
notifications before idle timing. The driver now gives each fixture a unique
name and settles setup before cancel/wake/stop timing. No production wake
fix is claimed. `native-isolated-ab.jsonl` preserves seven final paired
runs using this identical corrected driver against baseline and candidate
production, both with the same green sweep/airlock dependencies.

First corrected-harness best blocked-change times (FSEvents/kqueue/polling) were 12→12, 0→0
and 60→59 ms; wake was 106→102, 102→102 and 109→108 ms. Full summaries
are in `native-isolated-ab-summary.txt`. Regressions in round-best medians
are also reported: polling blocked-change 64→66 ms, kqueue cancellation
55→60 ms, and kqueue wake 105→110 ms. Every run stayed within the existing
ceilings; timing includes deliberate waits and scheduling, not only query
cost. This macOS host does not establish Linux/Windows native probe costs.

## Published dependency evidence and landing

Sweep main `0b6c39b63a32135d1735b6d1ed8ed82e5fb26793`: fast `37846780162`,
merge `37847820345`, successful before its fast-forward publication.
Lookout is repinned to that green published main, including the native
ancestor-boundary correction. Earlier db7f389 measurements remain preserved. Preflight main `b28046cc22055fcd32640117fc0e6965283a8ae5` has successful
fast `37821750595` and merge `37823307574` (its Zig-master advisory job failed,
while supported-version required gates succeeded). Airlock main
`112a6a233aa98ac831aa8b702ba0607587f367f4` and test-only shakedown main
`0ebf97bba845a93833f90be6befc49cdc51084f6` (merge `37834210320`, published
main run `37836509861`) are green published dependencies.
Lookout's exact-head fast/merge run IDs and final main SHA are recorded by
GitHub Actions and the landing report. No semantic owner blocker remains.

The book's old OS-global case assumption and raw-pattern rewriting migration
paragraph are stale; the accepted mission decisions supersede them. No book
edit accompanies this change. README remains honest about the public-cut WIP.

## Native merge corrections

Merge 37839686847 on roots 84849437 failed on macOS and Windows; its two
failed job logs are retained in ci-merge-37839686847-*-failed.txt. macOS
exposed a missing-root baseline rejection and a checkpoint allocation-failure
rejection. Filesystem capability probes now use bounded stack path storage;
a failed allocation cannot silently change a naming policy. Persisted capability
observations are not caller configuration: baseline/checkpoint compatibility
still checks raw filters, explicit preferences, identity overrides and root
identity, while current facts may change or become unknown after deletion.
The existing baseline and allocation-failure regressions pass with this change.

Windows exposed sweep ancestor splitting that ignored its alternate separator.
That correction belongs to sweep; lookout continues passing original glob
text to one parser. The subtree-removal test also built lookup names containing
mixed separators rather than kernel spellings; it now resolves its existing
fixture paths before looking up exact node keys. Counts, dropped-node sets
and sibling preservation assertions remain intact. Probe operations receive
the current Io and retain no add-time borrowed context.


## Final paired evidence and steering targets

Owner rule db221e5 makes speed and size targets steering objectives; correctness
and green CI determine landing. No target is silently treated as achieved.
Native x86 measurements and the full release comparative memory/performance
pass remain open. This batch measures the F03/F07 hot paths on shared Apple M3
hardware with Zig 0.17.0; it makes no x86 or comparative-memory claim.
Zero query allocations and bounded matching remain deterministic test contracts.

`reproduce-final-ab.py` rebuilds the preserved original main sources at
24d0986362a0ff5e968338531a6abad0cd8b10d0 and final candidate with identical
published Sweep/Airlock/Shakedown pins and the same corrected driver. Run
`zig build check` first to materialize packages, preserve the baseline sources
under `.baseline`, and put Zig 0.17.0 on PATH (or set ZIG). The file
`final-ab-sources.json` records both source hashes and the exact manifest.
`filter-final-ab.jsonl` and `native-final-ab.jsonl` retain seven interleaved
rounds, reversing order. The filter data includes 31 samples per row/round.
`final-ab-ratios.txt` reports paired after/before median ratios and their full
seven-round ranges, plus every native target and observed range.

| Filter row | Before | Exact | Folded | NFC |
|---|---:|---:|---:|---:|
| ignore 1 | 398.512 | 152.795 | 371.453 | 372.211 |
| ignore 20 | 490.440 | 243.994 | 280.335 | 279.628 |
| only 3 | 339.721 | 90.902 | 243.210 | 258.086 |
| ignore 20 + only 3 | 524.122 | 275.989 | 371.843 | 374.066 |

Best ns/question. Exact paired ratios are respectively 0.3822
[0.3716,0.3940], 0.5021 [0.4949,0.5131], 0.2705 [0.2674,0.2760], and
0.5296 [0.5186,0.5477]. ASCII answers agree; Unicode semantic differences
are proved by regressions rather than described as equivalent speed wins.
Raw rewriting and query scratch are removed, explaining the filter improvement.

Every measured native target was met in all seven candidate runs: blocked
change 500/500/700 ms (FSEvents/kqueue/poll), rename and cancellation 2500 ms,
wake and stop 5000 ms. The full observed ranges are in final-ab-ratios.txt.
Best blocked-change times were 15→10, 1→0, 57→56 ms; best wake was 100→100,
102→100, 113→106 ms. Native polling regressions are named: blocked change's
paired median ratio is 1.0169 [0.9194,1.7031]; wake's is 1.0259
[0.9217,1.0973]. Polling now reads directory naming capabilities and selects
the corresponding matcher, adding work that the OS-global baseline skipped.
The timed waits and shared-host scheduling dominate these rows; this batch
has not isolated the syscall contribution. Other native paired ratios and
zero-timer-floor deltas are reported, including FSEvents wake 1.0092
[0.9524,1.0700]. No timing regression is hidden or used as a correctness gate.

Sweep's boundary follow-up also records shared-host spread: ancestor paired
median ratios for 100/1k/10k entries are 1.0030 [0.9830,1.0514],
0.9939 [0.6707,1.1060], 0.9828 [0.8813,1.1267]. The 100-entry regression
comes with the extra alternate-boundary branch; its spread crosses 1. Sweep's
original exact `any` best-time regressions (0.9–1.9%) accompany normalization
reader/dispatch changes and remain reported in its normalize-evidence.md.
Those small layout/dispatch effects were not separately isolated. The NFC
Unicode rows do more work and provide different answers; their times remain
explicit in Sweep's raw data and report. All earlier reports and raw series
remain preserved independently of this final batch.
