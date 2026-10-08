# Per-root filesystem identity and parsed glob normalization

Work in progress. Neither F03 nor F07 is fixed yet.

Published baseline: lookout `24d0986362a0ff5e968338531a6abad0cd8b10d0`,
with green merge CI run `37673716956`; sweep
`ca2549467b9e3830f75eb81ec5e1072d8e3c615a`, green merge CI run
`37766731595`. Sources: the respective GitHub repositories; book
`workspaces/tycho/inbox/020334-mac.md` F03/F07 and
`workspaces/tycho/missions/packages-released/designs/sweep.md`.

## Ownership

Sweep owns Unicode default simple case folding, including its Unicode 18
scalar table. Its public scalar mapping will be `foldCase(code: u21) u21`;
it does not normalize, expand, apply Turkic folding, or map invalid UTF-8
bytes to scalars. Lookout owns filesystem identity and normalization policy,
probed per root and per directory where supported. Caller filter preference
is separate from identity. Kernel spelling must remain available unchanged.
No second Unicode fold engine or glob parser belongs in lookout.

## Owner decisions still required

The book's existing scalar-unit contract does not decide what a wildcard
or bracket consumes across normalization. F07 explicitly asks the owner.
Options raised: canonically composed scalar (ranges over original scalar
values), original input scalar, or normalized decomposed scalar with
expanding class members refused. Grapheme semantics would require a new
contract beyond the current scalar design.

F03 explicitly asks how an unknown filesystem behaves. Options raised:
require caller policy and otherwise return a named error; preserve exact
spelling and report unknown capability; or documented platform fallback
with unknown capability reported. No fallback has been silently selected.

The existing OS-global assumption and raw pattern rewriting in the sweep
design's migration paragraph are stale. The repository pages correctly
retain sweep ownership of grammar and lookout ownership of watch state.

## Reproduction and baseline timing

Both targeted regressions fail on the original production implementation
on macOS with Zig 0.17.0. `f03-before.txt` shows `Tree.KeyContext` collapsing
`/w/A` and `/w/a`. `f07-before.txt` shows `[é]` excluding plain `e`.
Each targeted build has one failed test and four passing assembly tests.
The tests are retained as failing-first specifications; this branch is
not a fixed candidate for main.

Seven original-filter ReleaseFast runs are in `filter-before.tsv`; each
row is the best of nine passes within that run. These are baseline data,
not completed paired A/B. Preserve the original executable until pairing
with the implementation; repeat before/after interleaved on the same host.

| Original filter row | Best ns/question | Median ns/question |
|---|---:|---:|
| filter_ignore_1 | 371 | 379 |
| filter_ignore_20 | 471 | 476 |
| filter_only_3 | 341 | 344 |
| filter_ignore_20_only_3 | 508 | 510 |

The generic Unicode mapping is not itself a promise of filesystem identity:
APFS and NTFS may use different Unicode versions/rules. Detection and
kernel canonicalization must establish each root/directory's identity
contract before using a fold; a global Unicode case option cannot supply it.

No fixes, dependency pin to an unpublished branch, or final merge gate
have been claimed. Main is unchanged.
