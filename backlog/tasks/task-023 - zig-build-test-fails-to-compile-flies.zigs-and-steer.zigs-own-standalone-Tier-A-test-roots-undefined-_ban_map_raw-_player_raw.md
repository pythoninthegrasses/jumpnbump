---
id: TASK-023
title: >-
  zig build test fails to compile flies.zig's and steer.zig's own standalone
  Tier-A test roots (undefined _ban_map_raw/_player_raw)
status: To Do
assignee: []
created_date: '2026-09-22 16:38'
labels: []
dependencies: []
references:
  - core/steer.zig
  - core/build.zig
  - core/unit_flies_globals.zig
  - >-
    backlog/completed/task-022 -
    Corpus-trace-05-four-players-ai-diverges-from-frame-324-onward-—-objects.zig-porting-bug-unrelated-to-RNG.md
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
