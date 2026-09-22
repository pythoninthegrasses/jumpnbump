---
id: TASK-022
title: >-
  Corpus trace 05 (four-players-ai) diverges from frame 324 onward — objects.zig
  porting bug, unrelated to RNG
status: Done
assignee: []
created_date: '2026-09-22 15:25'
updated_date: '2026-09-22 16:37'
labels: []
dependencies: []
references:
  - docs/checksum-format.md
  - docs/porting-playbook.md
  - tests/corpus/README.md
  - core/objects_difftest.zig
  - core/objects.zig
  - >-
    backlog/tasks/task-021 -
    Debug-macOS-ARM64-corpus-replay-checksum-mismatch-all-10-traces-fail-at-frame-0.md
modified_files:
  - core/steer.zig
  - core/build.zig
priority: high
type: bug
ordinal: 67000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Discovered while fixing TASK-021 (macOS/ARM64 corpus-replay checksum mismatch, caused by `rnd()` wrapping non-portable host libc `rand()`). TASK-021's fix (an in-repo, glibc-compatible `rnd()` reimplementation in `core/rnd.zig`/`core/c_ref/rnd.c`/`rnd_glibc.c`) took `test_every_corpus_trace_replays_with_matching_checksums` from 0/10 to 9/10 passing on macOS/ARM64 — every trace now matches from frame 0. One trace still fails, but demonstrably for an unrelated reason:

```
05-four-players-ai: frame 324: checksum mismatch (got e29841d9, corpus expects d9d89e29)
```

Frames 0-323 match exactly; frame 324 is the first divergence, and everything after it is fully decorrelated (expected once any single field flips, since all 200 object slots are folded into the checksum regardless of `used`).

**This is proven NOT an RNG-portability issue** (i.e., not TASK-021's bug reappearing):
- `rnd_glibc.c`'s generator was diffed against real glibc `rand()` (via `docker run gcc:13`) for 100,000 consecutive draws from seed 1 — zero mismatches, bit-for-bit identical.
- Trace 05 only consumes ~23,738 `rnd()` calls through frame 324 (read from `jnb_world_dump`'s embedded `rnd_call_count`), well inside the 100,000-draw verified range.
- Frame 323's checksum matches exactly, which requires every one of those ~23,655 draws to already be correct — the generator is proven correct well past the divergence point.
- A direct ABI replay harness (small C program linking `core/zig-out/lib/libjumpnbump.a` via `include/jumpnbump.h`, replaying `tests/corpus/05-four-players-ai.jsonl` through `jnb_world_init`/`jnb_step`/`jnb_world_dump`/`jnb_checksum`) reproduces the exact same frame-324 mismatch (`e29841d9` vs `d9d89e29`) outside Godot entirely, and per-tick `rnd_call_count` deltas around frame 324 (81-90 calls/tick) show nothing anomalous — ruling out an obvious extra/missing-draw bug in that specific tick.
- No player `bumps`/`dead_flag` change happens at frame 324 (checked via `jnb_player_view_get` for all 4 players, frames 315-330) — the divergence isn't tied to a kill event landing exactly there. `used`-object count churns normally (~102-120 of 200) with nothing unusual at 324 specifically.

**Likely same root cause as an already-confirmed, separate pre-existing bug**: `core/objects_difftest.zig`'s "splash_smoke" scenario already fails on unmodified `main` (confirmed via `git worktree` comparison against commit `9599516`, i.e. before any TASK-021 changes) — `zig build difftest` reports position/`ticks`/`image` fields off by small, consistent amounts (e.g. `objects[1].ticks: zig=1 != c=2`) starting at that scenario's very first tick. This has the same signature (small object-state drift, not a wrong rnd() value) as what's needed to explain frame 324: some particle/object-spawn code path in `core/objects.zig` (or its interaction with `core/steer.zig`/`core/cpu_move.zig`) doesn't exactly match `main.c`'s `update_objects()`/`add_object()` — `add_object()` itself was checked and matches `main.c` exactly (identical first-fit linear slot search), so the bug is more likely in `update_objects()`'s per-type particle physics/spawn-timing logic. Trace 05 is the longest, most object-churning corpus trace (4 AI players, 594+ ticks, "multiple concurrent bump-kills" per `tests/corpus/README.md`), which is plausibly why it's the only trace both long and busy enough to reach the buggy code path within its recorded length.

Reproduction (fast, no Godot needed): build `core/zig-out/lib/libjumpnbump.a` (`task core:build-abi`), then use `game/tests/corpus/levelmap.txt` as level bytes with `jnb_config{seed=1, player_count=4, player_ai_mask=15, flies_enabled=1, no_gore=0}`, replay `tests/corpus/05-four-players-ai.jsonl` via `jnb_step`, and diff `jnb_checksum(jnb_world_dump(...))` per line against the trace's `"checksum"` field — this matches gdUnit4's own `test_corpus_replay.gd`/`game/tests/corpus_replay.gd` harness exactly and reproduces the frame-324 mismatch outside Godot in under a second per run, much faster than `task game:test`.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Root cause of the objects_difftest.zig "splash_smoke" scenario mismatch (present on unmodified main) is identified in update_objects()/add_object()-adjacent logic
- [x] #2 05-four-players-ai replays with matching checksums through its full length (currently first fails at frame 324)
- [x] #3 objects_difftest.zig's particle-scenario test passes with zero mismatches
- [x] #4 Fix doesn't change any other corpus trace's recorded checksums (only trace 05 is currently short/busy enough to reach the bug)
- [x] #5 test_every_corpus_trace_replays_with_matching_checksums passes 10/10 on macOS/ARM64 (currently 9/10 after TASK-021's fix)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause was NOT an objects.zig porting bug -- it was a Zig 0.16.0 self-hosted linker defect (both the `--listen=-` test-server incremental linker AND the ordinary `zig build abi` static-lib build) that fails to merge a `.weak`-linkage Zig `@export` with a same-named strong C/Zig definition into one symbol. `nm -m` on the built binaries showed two distinct addresses for `objects_raw`/`player_raw`/`ban_map_raw` (one from steer.zig's `unit_objects`/`unit_player`/`unit_ban_map` weak fallback, one from the real owner) in EVERY binary that imports steer.zig alongside another definition -- including production's core/abi_globals.zig, not just the Tier-B difftest harnesses.

Fix: steer.zig's weak fallback export is now gated behind `const is_own_test_root = @import("root") == @This();` so it only fires when steer.zig is genuinely the compilation's own root (its own standalone Tier-A test) -- every other binary that merely imports it never emits the competing symbol, so there is exactly one definition by construction instead of relying on the linker's (broken) weak/strong resolution. Verified with `nm -m`: duplicate symbols gone from both the difftest binaries and libjumpnbump.a.

core/build.zig: objects_difftest.zig/steer_difftest.zig/collision_difftest.zig's sim_harness.c now pre-compiled as a separate object (matching game_loop_difftest.zig/fireworks_difftest.zig's existing pattern) -- this alone did NOT fix the duplication (confirmed by testing), the steer.zig gate was the actual fix, but the pre-compiled-object pattern is kept for consistency/robustness.

Verification: `zig build difftest` 212/212 passing (was hanging indefinitely on game_loop_difftest/fireworks_difftest before the fix -- root ban_map_raw split caused seedLevelObjects()'s void-tile search to spin forever); a from-scratch C harness driving libjumpnbump.a directly reproduced trace 05's exact frame-324 mismatch (e29841d9 vs d9d89e29) on unmodified main and confirmed it vanishes with the fix (all 10 corpus traces, 400/400 frames on trace 05); `task game:test`'s real gdUnit4 suite now passes 56/56 (was 55/56, same frame-324 failure). core/objects.zig's add_object()/update_objects() port was not touched -- it was already correct.

Known pre-existing, out-of-scope issue: `zig build test` (Tier-A) still fails to compile flies.zig's and steer.zig's own standalone test roots (undefined _ban_map_raw/_player_raw) on both baseline and this fix -- same underlying Zig weak-export unreliability, opposite direction (steer.zig's own root now correctly wants its weak fallback, but Zig's test-runner wrapping means `@import("root") != @This()` even when steer.zig genuinely is the named root_source_file). Not caused by this change; left as a follow-up.
<!-- SECTION:NOTES:END -->
