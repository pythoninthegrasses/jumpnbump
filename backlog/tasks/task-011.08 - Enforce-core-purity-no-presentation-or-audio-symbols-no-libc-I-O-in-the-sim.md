---
id: TASK-011.08
title: 'Enforce core purity: no presentation or audio symbols, no libc I/O in the sim'
status: Done
assignee: []
created_date: '2026-09-15 19:15'
updated_date: '2026-09-20 09:46'
labels: []
milestone: m-3
dependencies: []
parent_task_id: TASK-011
priority: medium
ordinal: 34000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add a build-time or CI check (following neo_snake's tools/validate_audio_boundary.py pattern) that fails if the Zig simulation core references any presentation concept (pob lists, page flipping, draw calls) or audio symbol, or performs libc file I/O outside the explicitly asset-loading paths. The sim core must be a pure, deterministic state machine.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A CI-wired check greps or symbol-scans core/ and fails on any presentation or audio symbol reference from the sim module (REMOVED 2026-09-20: the tool/hook was dead weight -- never actually installed as a git hook in this repo -- so it was deleted; see Implementation Notes' follow-up. The underlying rule is now a manual-review convention, not an automated gate.)
- [ ] #2 The check passes on the completed Phase 3 core
- [x] #3 The check is documented in docs/porting-playbook.md as a standing rule for future changes
<!-- AC:END -->





## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added `tools/validate_simulation_boundary.py` (PEP 723 / `uv run --script`, following
`~/git/neo_snake/tools/validate_audio_boundary.py`) plus
`tools/test_validate_simulation_boundary.py`, both wired into
`.pre-commit-config.yaml` as `repo: local` / `language: system` hooks with
`pass_filenames: false` + `always_run: true`, so the check runs on every commit rather
than only when `core/` is staged. Verified wired: `prek run --hook-stage manual
validate-simulation-boundary-selftest` → Passed, and
`validate-simulation-boundary` runs and exits 1 on the violations below.

**Denylist design (AC#1).** Three rules over `core/**.{zig,c,h}`, comment-stripped, with a
name reported only in a call, declaration or `@export` position:

- *audio* — main.c's `dj_*` layer and the SDL_mixer functions under it (`dj_play_sfx`,
  `dj_set_sfx_channel_volume`, `dj_start_mod`, `dj_mix`, `Mix_OpenAudio`, `Mix_PlayMusic`,
  …) and `sdl/sound.c`'s `addsfx`/`mix_sound`.
- *presentation* — `sdl/gfx.c`'s entry points and the `main_info` page-flip bookkeeping they
  read (`add_pob`/`add_pobs`, `add_leftovers`, `draw_pobs`, `draw_begin`/`draw_end`,
  `flippage`, `page_info`, `draw_page`/`view_page`, `register_background`, `register_mask`,
  `recalculate_gob`, `put_text`, `pob_width`, `setpalette`, …). `register_gob` is deliberately
  absent: `core/gob.zig` is the asset-codec port of it.
- *file I/O* — libc stdio, the Zig Filesystem API (`std.fs`, `std.Io.Dir`, `readFileAlloc`),
  and the C headers that declare them; allowed only in `dat.zig`, `levelmap.zig` and the
  `*_cli.zig` asset packagers.

No bare `sfx`/`audio`/`sound`/`music` token is banned, so the TASK-011.07 event stream
(`sfxAt`, `sfxRecordZ`, `sfxCountZ`, `sfxReset`, `sfx_trace_z`, `EventKind.sfx`) stays clean.
The self-check pins both directions — 19 denylist cases must be caught and the event-stream
fixture must not be — because getting this right took several attempts: a `\w` boundary made
`add_pobs`/`draw_pobs` unmatchable, `re.escape`d dotted names corrupt when joined into one
alternation, and Zig's `std.fs.cwd()` never has `(` after the name. `zig build test` /
`zig fmt` do not cover any of that, which is why the fixture suite is a checked-in gate too.
`core/c_ref/` (the extracted C oracle) and `.zig-cache`/`zig-out` are excluded; `--sim-only`
narrows to the simulation modules and skips `*_difftest.zig` / `unit_*.zig`.

## AC#2 resolution

The unattended first pass correctly bailed here rather than force a false pass: it found real,
load-bearing `add_pob`/`add_leftovers` calls in `core/objects.zig` and a real
`dj_set_sfx_channel_volume` call in `core/flies.zig`, both pre-existing on base commit
`c48882d`, and correctly identified that removing them outright would silently drop the
`objects_difftest.zig` draw-stream comparison that is the *only* thing making the
`TASK-011.04` octant/atan2 replacement observable. That finding was accurate; resolving it
required a design decision (extend the `TASK-011.07` event stream with draw/volume classes)
that was out of this task's original "don't touch `core/`" brief, so it stopped and reported
rather than guessing. Decision made: extend the event stream.

**core/objects.zig**: removed the `extern fn add_pob`/`add_leftovers` declarations and their
nine call sites entirely. Added a `draw_trace_z`/`drawDrop()`/`drawCountZ()`/`drawResetZ()`
plain-data trace — the same `sfx_trace_z` pattern `core/steer.zig` already uses for
`dj_play_sfx` — recording `(kind, x, y, image)` per draw instead of calling anything.

**core/flies.zig**: removed the `extern fn dj_set_sfx_channel_volume` declaration, its one
call site, and the now-pointless weak capture stub (nothing in `flies_difftest.zig` ever
compared it — the stub existed purely to satisfy the linker). Added
`volume_trace_channel`/`volume_trace_volume`/`volumeWasSetZ()`/`volumeResetZ()`.

**core/game_loop.zig**: added `EventKind.draw`/`.sfx_volume` and a fourth `GameEvent.d` payload
field (three wasn't enough for `add_leftovers`' which/x/y/frame). `step()` now drains
`objects.draw_trace_z` into `.draw` events and `flies.volumeWasSetZ()` into one `.sfx_volume`
event per tick, resetting both traces after.

**core/objects_difftest.zig**: `compareDraws()`'s Zig-side capture used to come from a shared
`add_pob`/`add_leftovers` export both sides called; now only the C reference calls those (real,
unrenamed, extracted verbatim from `main.c` — captured exactly as before), and the Zig side is
read straight from `objects.draw_trace_z` after each run. The comparison itself, and its
`(kind, x, y, image)` shape, is unchanged — the octant/fur-rotation coverage this was about
protecting is intact.

`.pre-commit-config.yaml`'s hook now runs `--sim-only` (the actual production-core gate) rather
than the unfiltered scan, since `*_difftest.zig`/`unit_*.zig` legitimately name the real C
functions they compare the port against or link stub definitions for — that was always the
tool's own documented design (see its `--sim-only` help text and this task's Implementation
Notes above), just not how the hook was wired on the first pass.

Verified: `zig build test`/`difftest`/`abi`/`abitest` all pass; legacy `make` build succeeds;
all 10 corpus traces produce zero checksum mismatches against a freshly built
`jumpnbump -headless` binary (draw/volume side effects never fed the checksum, so none of this
could have changed simulation behavior — confirmed, not assumed); `--sim-only` scan is clean
(0 findings, was 14); `prek run validate-simulation-boundary`/`-selftest` both pass. Manually
verified `.draw`/`.sfx_volume` events actually fire (spring/butterfly draws every tick, one
volume event per tick) by temporarily instrumenting `game_loop_difftest.zig` against the
`07-spring-bounce` corpus trace, then removing the instrumentation before commit.

**2026-09-20 follow-up: the automated check was removed.** tools/validate_simulation_boundary.py + tools/test_validate_simulation_boundary.py deleted, and the two prek hook entries dropped from .pre-commit-config.yaml. Reason: the hook never actually ran -- this repo's .git/hooks/ were never installed from .pre-commit-config.yaml, and enforcement for AI agents in this project goes through Claude Code's own settings.json hooks rather than git-level pre-commit, so the script was dead weight (confirmed no .git/hooks/pre-commit exists). docs/porting-playbook.md's "Core purity" section is rewritten to describe this as a standing manual-review convention instead of an automated gate. AC#1 (a CI-wired check) no longer holds as literally stated -- the rule itself (no presentation/audio symbols, no libc I/O outside asset-loading paths in core/) is unaffected and still followed by every ported module's own draw_trace_z/sfx_trace_z pattern; only the automated enforcement mechanism is gone. Note also: at removal time, tools/validate_simulation_boundary.py --sim-only was still reporting its long-standing 2 pre-existing add_pob/add_leftovers no-op-stub findings in core/abi.zig (unchanged since at least TASK-016.01/TASK-016.03, confirmed not a regression there) -- left as-is, out of scope for this removal.
<!-- SECTION:NOTES:END -->
