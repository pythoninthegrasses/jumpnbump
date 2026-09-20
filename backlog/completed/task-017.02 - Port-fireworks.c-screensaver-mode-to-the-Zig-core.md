---
id: TASK-017.02
title: Port fireworks.c screensaver mode to the Zig core
status: Done
assignee: []
created_date: '2026-09-15 19:16'
updated_date: '2026-09-20 03:55'
labels: []
milestone: m-8
dependencies: []
parent_task_id: TASK-017
priority: low
ordinal: 59000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Port fireworks.c's screensaver behavior (bouncing/exploding rabbits, parallax starfield with per-pixel background caching, its own state arrays entirely separate from player[]) into the Zig simulation core, verified against the C oracle. Depends on the delivery spike being complete so the porting target (embedded Godot vs. native) is known.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The ported fireworks behavior matches the C original via a difftest-style comparison using a dedicated corpus of fireworks-mode traces
- [x] #2 The rabbits[20] and stars[300] state arrays are represented in the Zig core exactly as separate from the main player[] simulation state, matching the original's design
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Ported fireworks.c's fireworks() (bouncing/exploding rocket-rabbits + scrolling starfield) into core/fireworks.zig, following the TASK-011.* playbook exactly: module-owned rabbits[20]/stars[300] (flies.zig's pattern, not objects.zig's shared-storage one, since this state never touches player[]), cross-module extern fns for rnd()/add_object()/update_objects() (no @import between ported modules), and a local draw/sfx trace for the two presentation boundaries (add_pob, a fixed-frequency SFX_DEATH cue) this module owns.

Scope decisions (all documented in the module's own header comments): stars[] drops old_x/old_y/back[2] (fireworks.c's own rendering double-buffer cache, zero effect on future ticks); the "corpus" is hand-authored {seed,ticks} scenarios (fireworks() takes no external input at all, so there's nothing to record -- matches core/objects_difftest.zig's own precedent, not game_loop_difftest.zig's corpus-replay one); the C reference (core/c_ref/extract_fireworks.py -> core/c_ref/fireworks.c) is a deletion-based extraction (not a pure contiguous cut, since fireworks() interleaves sim state with presentation calls throughout one function) with strict per-line content assertions guarding against silent drift.

Two real bugs found only by actually running the differential, not from precedent alone:
1. Argument-evaluation-order hazard (core/collision.zig's furGore/fleshGore precedent: the shipped oracle evaluates right-to-left, Zig's bundled clang left-to-right) applies identically to fireworks' 5 add_object() call sites in the explosion loops -- both core/fireworks.zig's rabbitFurGore/rabbitFleshGore and the generated C reference sequence the rnd() draws explicitly in that order.
2. A real bug caught by the difftest itself: updateRabbits() pre-shifted rabbit x/y to pixels before calling rabbitFurGore/rabbitFleshGore, whose goreCoord() shifts >>16 again -- a double-shift that produced ~8px gore positions instead of the correct ~180px. Fixed by passing raw fixed-point x/y (matching collision.zig's furGore/fleshGore call convention exactly).

add_object()/update_objects() are declared but never redefined in the C reference (collision.c's own "declare, don't rename" precedent) -- both the C-reference run and the Zig run call through to the SAME real core/objects.zig exports, so the differential only exercises fireworks.zig's own new logic (what arguments it computes), not update_objects' own correctness (already proven by objects_difftest.zig).

Verified: zig build test (Tier-A, fireworks.zig's own unit test passes, 115/115 total) and zig build difftest (Tier-B, fireworks_difftest.zig's 4 seed scenarios / 1620 replayed ticks pass with zero mismatches across rabbits[]/stars[]/objects[]/rnd_call_count/draw-trace/sfx-trace). Two pre-existing, unrelated failures (objects_difftest.zig's butterflies scenario, game_loop_difftest.zig's 10-spring-water-mix corpus trace) confirmed present on a clean, cache-wiped main before any of this work -- not caused by or fixed in this task. tools/validate_simulation_boundary.py flags add_pob/dj_play_sfx references in fireworks_difftest.zig, but that script isn't wired into any task (grep confirms) and already fails identically on every pre-existing difftest harness file (collision_difftest.zig, steer_difftest.zig, etc.) -- an unmaintained, unwired script, not a real gate.

No ABI/core/abi.zig change -- confirmed nothing about it is fireworks-aware or needs to be yet (decision-001's own Consequences section already states TASK-017.02 stays scoped to core/ with zero ABI surface; TASK-017.03 wires jnb_fireworks_* entry points later).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Ported fireworks.c's screensaver simulation (rocket-rabbit spawn/physics/explosion + scrolling starfield) into core/fireworks.zig, differential-tested against a generated C reference (core/c_ref/extract_fireworks.py) via core/fireworks_difftest.zig. rabbits[20]/stars[300] are module-owned state, structurally separate from player[]. Zero ABI surface added, per decision-001 -- pure core/ addition, TASK-017.03 wires delivery.

Caught and fixed a real double-shift bug in the explosion's gore-coordinate computation via the differential itself (rnd()-consumption/argument-order correctness was otherwise already covered by reusing core/collision.zig's established right-to-left evaluation precedent). Tier-A and Tier-B both pass; two pre-existing, confirmed-unrelated failures elsewhere in the suite were verified present on clean main before this work began.
<!-- SECTION:FINAL_SUMMARY:END -->
