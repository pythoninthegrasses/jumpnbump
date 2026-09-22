---
id: TASK-025
title: >-
  flies.zig's Tier-A tests seeded via libc srand(), which never actually seeded
  rnd.zig's own generator
status: Done
assignee: []
created_date: '2026-09-22 17:54'
labels: []
dependencies: []
references:
  - core/rnd.zig
  - core/flies.zig
  - backlog/tasks/task-023*
  - backlog/tasks/task-024*
modified_files:
  - core/rnd.zig
  - core/flies.zig
priority: low
type: bug
ordinal: 70000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Discovered while fixing TASK-023 (steer.zig/flies.zig's own standalone Tier-A test roots failing to link), immediately after fixing TASK-024's nextRaw() bounds-check bug: with both link and crash issues resolved, flies.zig's "update_flies flees an adjacent player, jittered rnd(3)-1" test still failed its `swarmAverageX() > 165` assertion.

Root cause: flies.zig's Tier-A tests seeded the RNG via `c.srand(seed)` (a `@cImport("stdlib.h")` binding to libc's srand()). But the rnd() flies.zig actually calls at runtime is core/rnd.zig's own pure-Zig port, reached as an `extern fn` and backed (in flies.zig's own standalone Tier-A test binary) by a separately-linked `flies_unit_rnd` object built from core/rnd.zig -- a completely separate PRNG implementation with its own internal `state`/`fptr`/`rptr`, not glibc's rand() state. TASK-021 removed rnd.zig's libc dependency (reimplementing glibc's algorithm directly for cross-platform determinism), but flies.zig's tests were never updated to seed through rnd.zig's own seed() instead -- `c.srand()` had no effect on the generator the tests actually exercise, so rnd.zig's `state[]` stayed all-zero for the whole test file, making every `rnd(n)` call return 0 deterministically.

Fixed as part of TASK-023 (user's explicit go-ahead to fix inline): added `pub export fn seedZ(seed_val: c_uint) void` to core/rnd.zig (a cross-module entry point wrapping seed(), matching core/steer.zig's existing sfxRecordZ/sfxResetZ "Z-suffix" convention for the same kind of extern-fn cross-module call), declared `extern fn seedZ(seed_val: c_uint) void;` in core/flies.zig, replaced all 4 `c.srand(...)` call sites with `seedZ(...)`, and dropped the now-unused `@cImport("stdlib.h")`.

Filed for the record per project convention (STOP-and-ask before expanding a task's scope); already fixed in the same session as TASK-023, not left open.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
flies.zig's own Tier-A tests seeded via libc's c.srand(), which has no connection to core/rnd.zig's own pure-Zig generator (TASK-021 dropped libc from rnd.zig) -- so the RNG the tests actually exercised was never seeded, leaving it at all-zero state and rnd() returning 0 deterministically. Discovered immediately after TASK-024's crash fix let the affected test actually run and fail on a swarm-drift assertion instead. Fixed by exporting rnd.zig's seed() as a Z-suffixed cross-module entry point (seedZ), matching steer.zig's existing sfxRecordZ/sfxResetZ convention, and switching flies.zig's 4 call sites from c.srand() to seedZ(); the now-unused @cImport was removed. All Tier-A/Tier-B/abitest suites still pass.
<!-- SECTION:FINAL_SUMMARY:END -->
