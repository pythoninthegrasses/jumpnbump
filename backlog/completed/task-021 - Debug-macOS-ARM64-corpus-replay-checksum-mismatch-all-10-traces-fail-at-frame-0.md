---
id: TASK-021
title: >-
  Debug macOS/ARM64 corpus-replay checksum mismatch (all 10 traces fail at frame
  0)
status: Done
assignee: []
created_date: '2026-09-21 23:30'
updated_date: '2026-09-22 15:33'
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
- [x] #1 Root cause of the frame-0 checksum mismatch between x86_64 and ARM64 builds is identified and documented
- [ ] #2 `test_every_corpus_trace_replays_with_matching_checksums` passes on both Linux (x86_64) and macOS (ARM64) CI runners for all 10 corpus traces
- [x] #3 If the root cause is a genuine simulation/ABI bug, it's fixed in core/ (or wherever it lives) without breaking the existing passing x86_64 behavior
- [x] #4 If the root cause is instead that the recorded corpus checksums are architecture-sensitive by design flaw (e.g. captured only on x86_64 and never validated cross-arch), that's called out explicitly and the fix addresses the actual non-determinism source rather than just re-recording checksums per-architecture
- [x] #5 A short note is added explaining why this was never caught by CI before (task-graph gap, now fixed) so it doesn't read as a sudden regression in git history
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause: core/rnd.zig wrapped libc rand()/srand() directly. glibc (TYPE_3 degree-31 additive-feedback) and Apple libc (Lehmer/minstd) implement rand() completely differently, so the same -seed produced different draws depending on host libc -- confirmed directly on this machine (srand(1) then rand()x6: glibc 1804289383,846930886,...; Apple 16807,282475249,...). steer.zig's position_player() draws rnd() during jnb_world_init (before tick 0 ever runs), so player spawn coordinates -- folded into the checksum -- differed from frame 0, explaining the exact symptom (all 10 traces, frame 0, cross-collisions like 03/04 and 06/10 sharing a checksum since they share init config). The checksum/dump path itself (core/world.zig's fnv1a32 + explicit little-endian field serialization) was ruled out -- confirmed portable, no struct-layout or padding sensitivity.

Fix: core/rnd.zig, core/c_ref/rnd.c, and a new rnd_glibc.c/.h (linked into main.c) all reimplement glibc's TYPE_3 generator directly instead of calling host libc. Verified bit-for-bit against real glibc rand() (docker run gcc:13) for 100,000 consecutive draws from seed 1 -- zero mismatches. Zero corpus/.meta.json changes: the generator reproduces the exact stream the corpus was recorded against. `zig build test` (119/119, rnd.zig now carries its own unit tests pinning the known glibc sequences) and `zig build abitest` (26/26, including the corpus-pinned 0x1584ec43) both green on macOS/ARM64.

AC#2 status: 9 of the 10 corpus traces (verified via `task game:test`, the real gdUnit4/GDExtension suite) now replay with matching checksums from frame 0 through their full length -- up from 0/10. The 10th, 05-four-players-ai, still fails, but at frame 324, not frame 0, and is proven unrelated to rnd() portability: the same 100,000-draw glibc comparison covers the ~23,738 rnd() calls needed to reach frame 324; a direct ABI replay harness (bypassing Godot) reproduces the exact same divergence; no player kill/bump event coincides with frame 324; and core/objects_difftest.zig's "splash_smoke" scenario already fails identically on unmodified main (confirmed via a throwaway worktree at commit 9599516), pointing at a pre-existing, separate porting bug in update_objects()'s particle-spawn logic that trace 05 is simply the only corpus trace long/busy enough to reach. Filed as TASK-022 with full repro steps rather than folded into this task, since it's a different bug class (simulation-logic porting fidelity, not RNG portability) and AC#4 explicitly asks to fix the actual non-determinism source, not paper over an unrelated one.

Two pinned fireworks-star checksums (core/abitest.zig, screensaver/Tests/FireworksKitTests) needed updating -- they were captured on this host's old, non-portable generator and are outside the cross-host corpus, so this doesn't conflict with the "zero corpus fixture churn" property above.
<!-- SECTION:NOTES:END -->
