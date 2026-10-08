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
policy as well. Explicit policy overrides remain in force for those paths.

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
`filter-allocation-after.txt`, and `wake-after.txt`. They exercise mixed
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

`native-ab.jsonl` preserves seven paired runs of the existing ReleaseFast
native driver; `native-ab-summary.txt` includes every backend and row.
FSEvents blocked change was 11→11 ms, kqueue 0→0 ms, polling 54→58 ms;
wake was 100→100, 100→103 and 112→117 ms respectively. Polling's round-best
medians were 55→59 and 116→122 ms. These small regressions/noise are reported,
not presented as improvements; every run stayed within the existing ceilings.
Event timings include deliberate waits and scheduling, not filter-query cost.
This macOS host does not establish Linux/Windows native probe performance.

## Published dependency evidence and landing

Sweep main `db7f389fee622d1c646dcfe92c57bc17839ca949`: fast `37823447887`,
merge `37824334064`, successful before its fast-forward publication.
Lookout is repinned to that green published main, not the retired helper-only
branch. Preflight main `b28046cc22055fcd32640117fc0e6965283a8ae5` has successful
fast `37821750595` and merge `37823307574` (its Zig-master advisory job failed,
while supported-version required gates succeeded). Airlock main
`112a6a233aa98ac831aa8b702ba0607587f367f4` and test-only shakedown main
`9357a9ab398ac25fa8a408a71e77a124bc51d311` are green published dependencies.
Lookout's exact-head fast/merge run IDs and final main SHA are recorded by
GitHub Actions and the landing report. No semantic owner blocker remains.

The book's old OS-global case assumption and raw-pattern rewriting migration
paragraph are stale; the accepted mission decisions supersede them. No book
edit accompanies this change. README remains honest about the public-cut WIP.
