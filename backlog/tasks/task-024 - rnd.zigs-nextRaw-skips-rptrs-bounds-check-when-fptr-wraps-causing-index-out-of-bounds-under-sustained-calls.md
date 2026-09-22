---
id: TASK-024
title: >-
  rnd.zig's nextRaw() skips rptr's bounds check when fptr wraps, causing
  index-out-of-bounds under sustained calls
status: Done
assignee: []
created_date: '2026-09-22 17:54'
labels: []
dependencies: []
references:
  - core/rnd.zig
  - core/flies.zig
  - backlog/tasks/task-023*
modified_files:
  - core/rnd.zig
priority: low
type: bug
ordinal: 69000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Discovered while fixing TASK-023 (steer.zig/flies.zig's own standalone Tier-A test roots failing to link): once the link issue was fixed, flies.zig's own Tier-A tests actually ran for the first time and immediately crashed with `panic: index out of bounds: index 31, len 31` inside core/rnd.zig's nextRaw().

Root cause: nextRaw() (core/rnd.zig, glibc TYPE_3 random() port) advances `fptr` and `rptr` each call, wrapping each back to 0 at `deg` (31). The `else` branch correctly bounds-checks `rptr`, but the `if (fptr >= deg)` branch increments `rptr` without checking its bound:

```zig
fptr += 1;
if (fptr >= deg) {
    fptr = 0;
    rptr += 1;              // <-- no `if (rptr >= deg) rptr = 0;` here
} else {
    rptr += 1;
    if (rptr >= deg) rptr = 0;
}
```

Since `rptr` trails `fptr` by `sep` (3), every time `fptr` wraps (every ~31 calls) `rptr`'s bound check is skipped, so `rptr` eventually walks past `state`'s length of 31 after enough *continuous* (non-reseeded) calls, causing an out-of-bounds panic.

This was never caught by core/rnd_difftest.zig's "10,000+ calls" test because that test calls `seed()` fresh before every single comparison (rndFromSeed helper), so nextRaw() only ever runs seed()'s own bounded warm-up loop plus exactly one real draw per reseed -- it never accumulates enough uninterrupted calls to hit the skipped bound check. flies.zig's own Tier-A tests call rnd() many times per tick across 200 ticks without reseeding, which is what actually exercises the bug.

Fixed as part of TASK-023 (with the user's explicit go-ahead to fix inline rather than defer): the increment/wrap logic was simplified so both fptr and rptr are always independently bounds-checked every call, matching glibc's actual algorithm (each pointer wraps independently). See core/rnd.zig's nextRaw().

Filed for the record per project convention (STOP-and-ask before expanding a task's scope); already fixed in the same session as TASK-023, not left open.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
core/rnd.zig's nextRaw() skipped rptr's bounds check whenever fptr wrapped, letting rptr walk past state[]'s length after enough continuous (non-reseeded) rnd() calls -- masked until now because every existing caller either reseeds before/around its calls or never drove enough uninterrupted calls to hit it. Discovered when TASK-023's link fix let flies.zig's own Tier-A tests actually run for the first time. Fixed by bounds-checking both fptr and rptr independently every call, matching glibc's real algorithm; difftest and all Tier-A/Tier-B/abitest suites still pass.
<!-- SECTION:FINAL_SUMMARY:END -->
