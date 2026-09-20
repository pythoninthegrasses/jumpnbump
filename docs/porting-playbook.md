# Porting playbook (`main.c`/`sdl/*.c` → `core/*.zig`)

Read this before starting any `TASK-010.*`, `TASK-011.*`, or `TASK-012.*` port. It's the
procedure every porting subtask would otherwise re-derive by hand. `docs/build-layout.md`
owns the "where do files go" half — this doc owns "how do you port a subsystem without
breaking the oracle."

## Procedure

1. Read the C function being ported, plus every caller, in `main.c` (or `sdl/*.c`). Function
   names are the map — there is no per-subsystem file split in the legacy tree.
2. Write `core/<name>.zig`, preserving the C ABI: `pub export fn` with the *exact* original C
   name, no renaming. See "C-ABI conventions" below.
3. Append the new module to `unit_test_files` (Tier-A) and `diff_test_files` (Tier-B) in
   `core/build.zig`.
4. Run the verify gauntlet below. Every check must pass before the port is done.
5. Finalize per the "Finalize" section.

**Never delete or edit the `.c` file being ported.** `main.c`, `sdl/`, and `modify/` are
retained forever — they are the Tier-B/oracle reference the Zig core is diffed against
frame-by-frame (`TASK-008`, AGENTS.md "Target layout"). A behavioral difference between the
port and the original must show up as a failing diff, never as a silent edit to the oracle
itself.

## Verify gauntlet

Run from `core/` unless noted. `taskfile.yml`'s `includes: {}` is deliberately empty until
Phase 2, so these are the raw `zig build` forms for now — they move behind `task core:*`
once `taskfiles/core.yml` lands.

```sh
zig build test       # Tier-A: unit tests for ported modules
zig build difftest    # Tier-B: Zig vs renamed-C reference over the TASK-008 corpus
zig build abi          # builds core/abi.zig as a static lib (grows real exports at TASK-012.02)
zig build abitest      # Tier-C: ABI conformance suite
zig fmt --check .      # every ported .zig file
(cd .. && task check) # the legacy make build must still link unchanged
```

## Verification tiers

| Tier | Command | Proves | Required when |
| ------ | --------- | -------- | ---------------- |
| A | `zig build test` | The ported module's own unit tests pass | Every port, from the first line of `core/<name>.zig` |
| B | `zig build difftest` | The port is behaviorally identical to the pre-port `.c`, replayed over the TASK-008 corpus, checksum-per-frame | Every Phase 3 (`TASK-011.*`) subtask, before the next subtask begins (`TASK-011` AC#3) |
| C | `zig build abitest` | The frozen `include/jumpnbump.h` surface and `core/abi.zig`'s exports stay in lockstep, reached only via `@cImport` | Any change touching `core/abi.zig` or `include/jumpnbump.h` (Phase 4, `TASK-012.*`) |
| D | gdUnit4 corpus replay | The GDExtension-driven Godot build reproduces the same per-frame checksums as Tier-B, through the real extension boundary | Phase 5 (`TASK-014.07`), before any presentation code is trusted |

Tier-B is the load-bearing tier for the porting phase: it *is* the oracle-differential check
the task description calls "oracle" verification. A subtask is not done until its module
passes Tier-B with zero mismatches.

## Cross-module rule: no `@import` between ported modules

Each ported `.zig` file is its own translation unit. `@import`-ing another ported module
duplicates its `pub export fn` symbols and fails to link. If module `steer.zig` needs
something from `objects.zig`, declare an `extern fn` against a small accessor that
`objects.zig` exports — do not `@import` it directly.

## Struct-twin rule

- Small, stable structs shared across modules (`player_t`, `object_t`) get mirrored as a
  local `extern struct` in each module that needs them.
- Large or evolving state (the eventual sim world handle) is reached through an opaque
  pointer plus accessor functions — don't mirror its layout in more than one place.

## Globals ownership

Backing storage for shared arrays (`player[]`, `objects[]`, `ban_map`, `flies[]`) is defined
exactly once, in the module that owns that subsystem (e.g. `objects.zig` owns
`objects: [MAX_OBJECTS]object_t`). Every other module that needs it declares an
`extern var` mirror, never a second definition.

## The no-float rule

This is what makes bit-exact Tier-B differential testing possible at all: **zero `float`/
`double` variables exist anywhere in `main.c`, `menu.c`, `filter.c`, `fireworks.c`, or
`sdl/*.c`.** Positions and velocities are entirely 16.16 fixed-point integers —
`player[].x >> 16` recovers a pixel coordinate, thresholds are written `(12L << 16)`, and
object velocities are raw fixed-point magnitudes like `-16384` (a quarter pixel per frame).
Ported Zig code must stay integer-only to match.

There are exactly **two floating-point call sites in the entire simulation**, both
implicit-double through libm, both with the result immediately `(int)`-cast. Both need an
integer-exact replacement before their owning subsystem is ported, and both are made worse
by the legacy Makefile building the oracle with `-ffast-math`:

- `main.c:1011` — `cur_dist = (int)sqrt(...)` in `get_closest_player_to_point()`, used by
  the fly AI (`TASK-011.06`). Replace with an integer isqrt.
- `main.c:2529` — `s1 = (int)(atan2(objects[c1].y_add, objects[c1].x_add) * 4 / M_PI)`,
  selecting one of 8 sprite direction octants in the particle update (`TASK-011.04`).
  Replace with a comparison-based integer octant selector — no `atan2` needed for 8 fixed
  directions.

`M_PI` is defined locally at `main.c:44-45`; `<math.h>` itself only arrives transitively
(neither `main.c`'s own `#include` list names it). Pin both call sites down before
`TASK-008.02` starts checksumming frames, or the oracle corpus will encode `-ffast-math`
rounding as "correct" behavior.

## Core purity

The Zig simulation core must be a pure, deterministic state machine: no presentation
concept (pob lists, page flipping, draw calls), no audio symbol, and no libc file I/O
outside explicitly asset-loading paths (`core/dat.zig`, `core/levelmap.zig`, and the
asset-packager CLIs under `core/*_cli.zig`). `core/c_ref/` (the extracted C oracle) is
exempt, and the `*_difftest.zig`/`unit_*.zig` test harnesses legitimately name the real C
functions they compare a port against or link stub definitions for.

Presentation/audio side effects a ported function used to call directly (`add_pob`,
`add_leftovers`, `dj_play_sfx`, `dj_set_*_volume`, …) become plain-data trace records
instead — `draw_trace_z`/`sfx_trace_z`-shaped fields, drained into `core/game_loop.zig`'s
event stream — never a real call into presentation/audio code. `core/objects.zig`'s and
`core/steer.zig`'s header comments show the pattern for any new port to follow.

This was previously enforced by an automated symbol-scanner
(`tools/validate_simulation_boundary.py`, TASK-011.08), wired into `.pre-commit-config.yaml`
as a `prek` hook. That hook never actually ran in practice — this repo's `.git/hooks/`
were never installed from the pre-commit config — and enforcement for AI agents in this
project goes through Claude Code's own `settings.json` hooks rather than git-level ones, so
the script was dead weight and was removed. Treat this section as a standing review
convention for every future change to `core/`, not an automated gate — check by eye (or
`grep`) whenever a new module is ported that it names no presentation/audio symbol.

## C-ABI conventions

- Export with `pub export fn`, using the exact original C name — never rename a ported
  function.
- Any function reached through libc varargs needs `callconv(.c)`.

## Finalize

- Branch name: `task-XXX-<slug>`.
- Two commits:

  ```text
  feat(port): <file>.c → core/<name>.zig (TASK-XXX)
  chore(backlog): mark TASK-XXX done
  ```

- Conventional-commit types throughout. No `Co-Authored-By` trailers — `pythoninthegrass`
  is the sole author on every commit.
