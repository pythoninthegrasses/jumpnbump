---
id: TASK-021
title: >-
  Debug macOS/ARM64 corpus-replay checksum mismatch (all 10 traces fail at frame
  0)
status: To Do
assignee: []
created_date: '2026-09-21 23:30'
labels: []
dependencies: []
references:
  - 'https://github.com/pythoninthegrasses/jumpnbump/actions/runs/35667041808'
  - >-
    https://github.com/pythoninthegrasses/jumpnbump/actions/runs/35667041808/job/106555014291
    (macOS failure)
  - >-
    https://github.com/pythoninthegrasses/jumpnbump/actions/runs/35667041808/job/106555013903
    (Linux passing comparison)
documentation:
  - docs/porting-playbook.md
  - docs/build-layout.md
priority: high
type: bug
ordinal: 66000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`game:test`'s gdUnit4 suite includes `res://tests/test_corpus_replay.gd > test_every_corpus_trace_replays_with_matching_checksums`, which replays each recorded corpus trace through the built GDExtension's simulation (`SimWorld`/`TickDriver`, backed by `core/zig-out/lib/libjumpnbump.a`) and compares the resulting per-frame checksum against a recorded-expected value. This test is meant to guarantee the ported Zig simulation is bit-exact and platform-independent (see `docs/porting-playbook.md`'s "no-float simulation constraints" — the whole point of this architecture is deterministic, frame-by-frame identical output across platforms).

As of 2026-09-21, CI ran this test end-to-end for the first time ever (it was previously unreachable due to unrelated CI/build-graph bugs, all now fixed). Result, from the same commit (`af7975f`) on both CI runners in the same workflow run (https://github.com/pythoninthegrasses/jumpnbump/actions/runs/35667041808):

- **Linux (`blacksmith-4vcpu-ubuntu-2404`, x86_64)**: PASSED cleanly — 56/56 test cases, 0 failures, including this one.
- **macOS (self-hosted, Apple Silicon/ARM64)**: this single test FAILED — all 10/10 corpus traces mismatched, every single one at **frame 0** (not a drift building up over many frames — wrong from the very first tick):

```
01-single-player-basic: frame 0: checksum mismatch (got 4e74da4c, corpus expects 1584ec43)
02-two-player-manual: frame 0: checksum mismatch (got a15bd4c5, corpus expects b371060b)
03-two-player-ai-kill: frame 0: checksum mismatch (got c731c122, corpus expects 01b021ab)
04-two-player-ai-kill-nogore: frame 0: checksum mismatch (got c731c122, corpus expects 01b021ab)
05-four-players-ai: frame 0: checksum mismatch (got 2f39e6bd, corpus expects add306b7)
06-water-immersion: frame 0: checksum mismatch (got 70149953, corpus expects 785de864)
07-spring-bounce: frame 0: checksum mismatch (got b7e658da, corpus expects fbfbd515)
08-ice-slide: frame 0: checksum mismatch (got 5f221610, corpus expects 6b5fb26f)
09-flies-off: frame 0: checksum mismatch (got e71932f1, corpus expects 0e115051)
10-spring-water-mix: frame 0: checksum mismatch (got 70149953, corpus expects 785de864)
```

(Full failure text: `res://tests/test_corpus_replay.gd:75`, gdUnit4 output in the "Build and test" step of macOS job `106555014291` in the run linked above.)

Every trace mismatching at the very first frame, consistently, is a strong signal this isn't a subtle physics/float-accumulation bug — it points at something structural in the frame-0 baseline: e.g. an integer/struct-layout or endianness difference between the x86_64 and ARM64 builds of `core/zig-out/lib/libjumpnbump.a`, an uninitialized-memory or padding difference exposed only cross-arch, a checksum function reading something arch-dependent (pointer-sized field, struct alignment/padding baked into the hash, etc.), or the recorded corpus checksums themselves having only ever been generated/verified on x86_64 (i.e. this may be the corpus fixtures being wrong for ARM64 rather than the simulation itself, if the corpus was captured on an x86_64 machine and genuinely is architecture-sensitive in a way it shouldn't be).

Two important framing notes for whoever picks this up:
1. This is a **pre-existing bug that was simply never exercised in CI until today** (2026-09-21) — none of the CI/build-graph fixes landing the same day introduced it. It is not a regression from that work; it's a latent bug this same work finally uncovered by making `game:test` reach this test at all on both platforms for the first time.
2. Nothing in the changes that landed today touches `core/`'s simulation logic, `core/abi.zig`, the checksum function, or the corpus fixtures themselves — those fixes were entirely task-graph wiring (`taskfiles/game.yml`), an `ar`-extraction/response-file build-tooling fix (`core/localize_abi_symbols.py`, `extension/SConstruct`), and a Godot-engine-race workaround (`--frame-delay`/retry in `game:import`). So the corpus/checksum logic itself is exactly as it's been for a while; today's changes only made it possible to *see* this failure in CI for the first time.

Where to start looking: `res://tests/test_corpus_replay.gd` (the test itself, including how it invokes the simulation and computes/compares checksums), whatever corpus fixture files it reads from (likely under `game/tests/` or a `corpus/` directory — search for where the 10 trace names like `01-single-player-basic` are defined/stored), `core/abi.zig`'s checksum-producing export (`jnb_checksum` per `nm -g` on the built archive), and `core/abi_globals.zig`. Also worth checking whether `core/build.zig`'s existing `difftest`/`abitest` steps (the Tier-B/C differential and ABI-conformance gates described in `docs/build-layout.md`) already catch or would catch this same mismatch on ARM64 — if so, that's a much faster repro loop than running gdUnit4 under Godot.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Root cause of the frame-0 checksum mismatch between x86_64 and ARM64 builds is identified and documented
- [ ] #2 `test_every_corpus_trace_replays_with_matching_checksums` passes on both Linux (x86_64) and macOS (ARM64) CI runners for all 10 corpus traces
- [ ] #3 If the root cause is a genuine simulation/ABI bug, it's fixed in core/ (or wherever it lives) without breaking the existing passing x86_64 behavior
- [ ] #4 If the root cause is instead that the recorded corpus checksums are architecture-sensitive by design flaw (e.g. captured only on x86_64 and never validated cross-arch), that's called out explicitly and the fix addresses the actual non-determinism source rather than just re-recording checksums per-architecture
- [ ] #5 A short note is added explaining why this was never caught by CI before (task-graph gap, now fixed) so it doesn't read as a sudden regression in git history
<!-- AC:END -->
