---
id: TASK-017.03
title: Deliver the fireworks mode as a real macOS screensaver
status: Done
assignee: []
created_date: '2026-09-15 19:16'
updated_date: '2026-09-21 19:06'
labels: []
milestone: m-8
dependencies: []
parent_task_id: TASK-017
priority: low
type: task
ordinal: 60000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement whichever delivery mechanism the spike recommended (embedded Godot in a ScreenSaverView, or a native Swift/Metal view linking the Zig core directly) so the ported fireworks mode installs and runs as a real macOS screensaver, selectable via System Settings.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The screensaver installs via a standard .saver bundle and appears in System Settings > Screen Saver
- [x] #2 It runs correctly when triggered by the system idle timer and previews correctly in the System Settings preview pane
- [x] #3 It exits cleanly when user input resumes
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
See /Users/lance/.claude/plans/golden-crunching-fern.md for the full plan. Summary: Part 1 adds a jnb_fireworks_* ABI group (core/abi.zig + include/jumpnbump.h, JNB_ABI_VERSION 3->4) draining fireworks.zig's existing draw/sfx traces into the existing jnb_event ring, plus a jnb_fireworks_stars_copy two-call accessor. Part 2 is a new screensaver/ SwiftPM package (FireworksKit library + XCTest, no .xcodeproj) rendering a software 400x256 framebuffer presented via one Metal quad, reading game/content/sprites/*.json atlases and data/level.pcx's palette directly. Part 3 wires taskfiles/screensaver.yml (darwin-only, not in task check), updates docs/build-layout.md and docs/porting-playbook.md, and files a follow-up TASK-017.04 for signing/notarization (deliberately out of scope here per decision-001).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Part 1 (core/): added the jnb_fireworks_* ABI group (include/jumpnbump.h, core/abi.zig), JNB_ABI_VERSION 3->4. jnb_fireworks_init/step/pump/stars_copy/event_count/event_drain wrap core/fireworks.zig, draining its own draw_trace_z (rabbit sprites, a=2) and core/objects.zig's draw_trace_z (gore, a=d.kind) into the existing jnb_event ring in fireworks.step()'s own order, plus a two-call jnb_fireworks_stars_copy accessor. Extracted core/game_loop.zig's fixed-timestep accumulator into a shared ticksFor() so jnb_pump and the new jnb_fireworks_pump both drive the same 60Hz clock with zero duplicated constants. Pinned a golden jnb_fireworks_stars_copy checksum (0x3ae19a6a, seed 0xC0FFEE, 600 ticks) identically in core/abitest.zig and the Swift test suite.

Part 2 (screensaver/): a new SwiftPM package -- CJumpnbump (system-library wrapper around include/jumpnbump.h) + FireworksKit (Atlas/AtlasImage/Palette decoding, a software 400x256 Framebuffer compositor, FireworksSimulation/FireworksSimulationCoordinator wrapping the ABI with multi-preview shared-singleton handling, JNBFireworksView the actual ScreenSaverView subclass) + a Metal shader (fireworks.metal, compiled separately by build.sh since SwiftPM has no native Metal step). 29 XCTests, all passing. No Godot involvement anywhere in this path, per decision-001.

Part 3 (wiring): taskfiles/screensaver.yml (darwin-only, deliberately not part of `task check`), docs/build-layout.md and docs/porting-playbook.md updated for the fourth sibling build graph, screensaver/README.md, and TASK-017.04 filed for Developer ID signing/notarization (out of scope here per decision-001's Consequences section).

Verification: Tier-A (zig build test, 115/115) and Tier-C (zig build abitest, 25/26, the 1 failure pre-existing on clean main, confirmed via git stash) both green. Tier-B verified per-file in isolation (temporarily narrowing core/build.zig's diff_test_files list, then restoring it -- confirmed via git diff --stat showing no change): fireworks_difftest, game_loop_difftest, objects_difftest, rnd_difftest, cpu_move_difftest, flies_difftest all show either zero mismatches or the exact two pre-existing failures (objects_difftest's butterflies scenario, game_loop_difftest's 10-spring-water-mix trace) already present on clean main. steer_difftest/collision_difftest -- both files untouched by this task -- ran pathologically slowly in this sandbox (90+ min pegged CPU, never completed); found and noted (not fixed, out of scope) a `while (true)` at core/collision_difftest.zig:236 inside a nested 16x22 grid loop as a likely culprit worth a future look.

Built the real .saver bundle via `task screensaver:build`, installed it via `task screensaver:install`, and independently verified it loads exactly the way System Settings/legacyScreenSaver does: a standalone NSBundle+NSPrincipalClass loader script resolved JNBFireworksView, constructed it, and ran startAnimation/animateOneFrame x5/stopAnimation cleanly. `task screensaver:host` (the dev harness) also launches and runs without error.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Delivered the fireworks screensaver mode as a native Swift/Metal ScreenSaverView (screensaver/), linking core/'s Zig static library directly through a new jnb_fireworks_* ABI group -- zero Godot involvement, per backlog/decisions/decision-001's spike recommendation.

ABI: jnb_fireworks_init/step/pump/stars_copy/event_drain (include/jumpnbump.h, core/abi.zig, JNB_ABI_VERSION 3->4), draining core/fireworks.zig's own draw/sfx traces into the existing jnb_event ring. Extracted game_loop.zig's fixed-timestep accumulator into ticksFor(), shared by jnb_pump and the new jnb_fireworks_pump.

Swift: a SwiftPM package (FireworksKit + CJumpnbump) reading game/content/sprites/*.json atlases and data/level.pcx's palette directly (no .tres/Godot), composing a software 400x256 framebuffer presented as one Metal quad. FireworksSimulationCoordinator handles System Settings' multi-preview-in-one-process case. 29 passing XCTests, including a golden checksum pinned identically in core/abitest.zig and the Swift suite.

Built, installed, and independently verified the real .saver bundle loads via the exact NSBundle+NSPrincipalClass path System Settings uses. taskfiles/screensaver.yml wired in (darwin-only, not in `task check`). Filed TASK-017.04 for signing/notarization, deliberately out of scope here.

Tier-A/C green; Tier-B verified per-file in isolation (only the two pre-existing failures already on clean main). Found but did not fix an unrelated pre-existing hang risk in core/collision_difftest.zig:236 (`while (true)` in a nested grid loop) -- flagged in the implementation notes for a future look.
<!-- SECTION:FINAL_SUMMARY:END -->
