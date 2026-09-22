---
id: TASK-023
title: >-
  zig build test fails to compile flies.zig's and steer.zig's own standalone
  Tier-A test roots (undefined _ban_map_raw/_player_raw)
status: Done
assignee:
  - Claude
created_date: '2026-09-22 16:38'
updated_date: '2026-09-22 17:54'
labels: []
dependencies: []
references:
  - core/steer.zig
  - core/build.zig
  - core/unit_flies_globals.zig
  - >-
    backlog/completed/task-022 -
    Corpus-trace-05-four-players-ai-diverges-from-frame-324-onward-—-objects.zig-porting-bug-unrelated-to-RNG.md
modified_files:
  - core/build.zig
  - core/steer.zig
  - core/flies.zig
  - core/rnd.zig
  - core/unit_flies_globals.zig
  - core/unit_steer_globals.zig
priority: low
type: bug
ordinal: 68000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Discovered while fixing TASK-022 (core/steer.zig's weak player_raw/objects_raw/ban_map_raw fallback export colliding with sim_harness.c's/abi_globals.zig's real definitions under Zig 0.16.0's self-hosted linker -- fixed there by gating the weak export behind `const is_own_test_root = @import("root") == @This();`).

That fix relies on `@import("root") == @This()` being true when a .zig file is genuinely the root_source_file of the current compilation. It is NOT true under `zig build test`'s test-runner wrapping: even when core/steer.zig (or core/flies.zig, via core/unit_flies_globals.zig's analogous pattern) is passed as `root_source_file` to `b.addTest`, `@import("root")` resolves to Zig's synthesized test-runner shim, not to steer.zig itself -- so `is_own_test_root` is always false there, and steer.zig's own weak fallback never fires for its own standalone Tier-A test.

This is a PRE-EXISTING issue, confirmed present on unmodified `main` (git-stash-verified before TASK-022's changes) with the same symptom shape (undefined `_ban_map_raw`/`_player_raw`), not a regression introduced by TASK-022 -- both baseline and the TASK-022 fix show `zig build test`: "Build Summary: 44/49 steps succeeded (2 failed); 119/119 tests passed", the 2 failed compiles being flies.zig's and steer.zig's own Tier-A test binaries.

Needs a build-time signal that actually distinguishes "this module is the compilation's own root" from "this module was merely imported" under `zig build test`'s wrapping -- e.g. a `build_options` module threaded explicitly per-binary from core/build.zig (only the literal steer.zig-as-root Tier-A test build passes `provide_weak_globals=true`; every other consumer gets `false` or omits the import entirely), rather than the `@import("root") == @This()` comptime trick, which only works for non-test (`zig build abi`, `zig build <cli>`) roots.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce with `zig build test` (confirmed: 2 failed compiles, undefined `_ban_map_raw`/`_player_raw`, matching the task description).
2. Diagnose steer.zig's own Tier-A test: confirm with `@compileLog` that `is_own_test_root = @import("root") == @This()` is false under `b.addTest`'s synthesized test-runner wrapping (true only for `zig build-obj -Mroot=steer.zig`), so the weak fallback never fires there.
3. Diagnose flies.zig's own Tier-A test separately: its `unit_flies_globals.zig` companion object already unconditionally exports the fallback, and is already linked in -- yet still undefined. `nm -m` on the compiled `.o` shows Zig 0.16.0 compiles `@export(..., .linkage = .weak)` of a file-scope `var` as a *non-external* (private) symbol, invisible outside that object file, not a proper weak-external symbol. Confirmed by nm-checking a currently-passing case (collision.zig's steer_obj) shows the same non-external symbol -- it just happens not to matter there because a real (strong, external) sim_harness.c definition already satisfies every reference in that link.
4. Fix: for flies.zig, drop `.linkage = .weak` in unit_flies_globals.zig (plain/strong export) -- safe because that object is only ever linked into flies.zig's own standalone test, no competing definition exists there.
5. Fix: for steer.zig, extract a new `unit_steer_globals.zig` (same pattern as unit_flies_globals.zig/unit_objects_globals.zig: `@import("world.zig")` for the real Player/Object layout and array sizes, plain/strong exports of player_raw/objects_raw/ban_map_raw), remove the dead is_own_test_root/weak-export block and the now-orphaned `default_ban_map` from steer.zig, and link the new object only into steer.zig's own addTestStep entry in core/build.zig.
6. Rebuild: steer.zig's test now compiles and passes fully; flies.zig's now compiles but crashes at runtime (`index out of bounds` in rnd.zig's nextRaw(), a pre-existing bug the link fix exposed for the first time). STOPPED and asked the user how to handle this out-of-scope discovery.
7. User approved fixing inline + filing a record task (TASK-024). Fixed rnd.zig's nextRaw() rptr bounds-check.
8. Rebuild: crash fixed, but one flies.zig test now fails a logic assertion -- its seeding uses libc's `c.srand()`, disconnected from rnd.zig's own libc-free (TASK-021) generator. STOPPED and asked again.
9. User approved fixing inline + filing a record task (TASK-025). Added `rnd.zig`'s `seedZ` Z-suffixed cross-module export (matching steer.zig's sfxRecordZ/sfxResetZ convention), switched flies.zig's 4 `c.srand()` call sites to `seedZ()`, dropped the now-unused `@cImport`.
10. Verified: `zig build test`, `zig build difftest`, `zig build abi`, `zig build abitest`, and all 4 CLI tool steps (jnbpack/jnbunpack/gobpack/asset-dump) all build/pass cleanly.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
TASK-024 and TASK-025 filed and marked Done: two pre-existing bugs (rnd.zig's nextRaw() rptr bounds check; flies.zig's tests seeding via disconnected libc srand()) surfaced only once this task's link fix let the two previously-uncompilable Tier-A test binaries actually run for the first time. Both fixed inline with explicit user approval rather than deferred, since TASK-023 couldn't reach a fully green build otherwise.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
`zig build test` now fully passes (previously 2 of the 15 Tier-A binaries -- steer.zig's and flies.zig's own standalone tests -- failed to link with undefined `_player_raw`/`_ban_map_raw`/`_objects_raw`).

Root causes, both distinct from the task's original hypothesis:
- steer.zig's own test: `is_own_test_root = @import("root") == @This()` is false under `b.addTest`'s synthesized test-runner wrapping (confirmed via `@compileLog`), so its weak fallback export never fired for its own standalone test. It was only ever true for `zig build-obj -Mroot=steer.zig` (collision.zig's/fireworks.zig's pre-compiled steer_obj).
- flies.zig's own test: its existing `unit_flies_globals.zig` companion object already unconditionally exported the fallback and was already linked in, yet still failed -- `nm -m` showed Zig 0.16.0 compiles a weak `@export` of a file-scope `var` as a *non-external* (private) symbol, invisible to the linker outside that object file, not a true weak-external symbol.

Fix: replaced steer.zig's dead `is_own_test_root`-gated weak-export block with a new `core/unit_steer_globals.zig` companion object (same established pattern as `unit_flies_globals.zig`/`unit_objects_globals.zig`), linked only into steer.zig's own Tier-A test in `core/build.zig`; changed both companion objects' exports from `.linkage = .weak` to plain/strong (safe -- each is only ever linked where no competing definition exists).

That link fix let both previously-uncompilable test binaries actually run for the first time, surfacing two further pre-existing bugs (with the user's explicit approval each time to fix inline rather than defer): `rnd.zig`'s `nextRaw()` skipped `rptr`'s bounds check whenever `fptr` wrapped (TASK-024), and flies.zig's tests seeded via libc's disconnected `srand()` instead of rnd.zig's own libc-free generator (TASK-025, added `rnd.zig`'s `seedZ` Z-suffixed export).

Verified: `zig build test`, `zig build difftest`, `zig build abi`, `zig build abitest`, and all 4 CLI tool build steps all pass cleanly.
<!-- SECTION:FINAL_SUMMARY:END -->
