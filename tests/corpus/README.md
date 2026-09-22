# Headless input-trace corpus

TASK-008.03. This is the checksummed oracle corpus: scripted per-tick input,
recorded from the headless C build (TASK-008.01), paired with the
per-frame canonical-state checksums it produces (TASK-008.02). The Zig
differential-test harness (TASK-008.04) replays these traces through both
the renamed-C reference and a ported Zig module and diffs the checksums.

This directory is distinct from `tests/fixtures/`, which holds a single
ad-hoc smoke-test trace with no checksums; everything here is a real,
checksummed oracle recording.

## File format

Each `<name>.jsonl` is directly usable as `-input <name>.jsonl` — the
headless input reader only looks for a `"keys"` array per line and ignores
unrecognized fields, so the corpus files double as executable traces. One
JSON object per line, one line per tick:

```json
{"frame": 3, "keys": ["p1_right", "p1_jump"], "checksum": "df943235"}
```

- `frame`: zero-based tick index (must match the line's position).
- `keys`: any of `p{1,2,3,4}_{left,right,jump}` held that tick; omitted
  keys are up. Ignored for a player index whose `-headless-ai` bit is set —
  cpu_move() drives that player instead (see below).
- `checksum`: the 8-hex-digit value from that tick's `FRAME n CHECKSUM
  <hex>` oracle output (docs/checksum-format.md), captured by running the
  real `jumpnbump -headless` binary over this exact trace.

Each `<name>.meta.json` records the CLI invocation needed to reproduce the
trace's checksums exactly (the trace file alone doesn't carry player count,
AI mask, or flags like `-nogore`/`-noflies`):

```json
{
  "seed": 1,
  "headless_players": 2,
  "headless_ai_mask": 1,
  "extra_flags": ["-nogore"],
  "mechanic": "human-readable description of what this trace exercises"
}
```

To reproduce a trace's checksums:

```sh
./jumpnbump -headless -seed <seed> -dat data/jumpbump.dat \
  -headless-players <headless_players> -headless-ai <headless_ai_mask> \
  <extra_flags...> -input tests/corpus/<name>.jsonl
```

The C build always emits a few extra `FRAME`/`CHECKSUM` lines past the
trace's last line — once the input file is exhausted, headless mode treats
that as an ESC keypress and the game runs its (deterministic) fade-out
before exiting. That tail is itself byte-identical across repeated runs of
the same trace, so it's intentionally **not** embedded per-line here; only
checksums for frames the trace actually scripts are recorded. A harness
replaying these traces should compare checksums up through the trace's
last frame and can ignore anything the oracle prints after that.

## Cross-platform determinism (TASK-021)

Every checksum recorded here depends on `rnd()`'s exact output sequence
(docs/checksum-format.md), and until TASK-021, `rnd()` was a thin wrapper
over host libc `rand()`. That's not one algorithm: glibc's `rand()` is a
degree-31 additive-feedback generator, while e.g. Apple's libc `rand()` is
a Lehmer/minstd generator — the same `-seed` produced completely different
draws, and therefore completely different checksums, depending on which
libc replayed a trace. This corpus was originally recorded on an x86_64/
glibc host, so it silently only ever "passed" there; `game:test`'s gdUnit4
replay reached this test in CI for the first time on 2026-09-21 and failed
all 10 traces at frame 0 on the macOS/ARM64 runner — not a regression, just
the first time CI exercised this test on a non-glibc host at all.

`rnd()` (`main.c`, `core/c_ref/rnd.c`, `core/rnd.zig`) now reimplements
glibc's specific generator directly instead of calling into host libc, so
the "Adding a new trace" procedure below reproduces byte-identical
checksums on any host, and the recorded checksums here don't need
per-architecture variants. If a checksum here is ever wrong on some host
again, that's a bug in the shared generator, not a reason to re-record a
platform-specific fixture.

## Mechanic coverage

| File | Players | AI mask | Flags | Mechanic |
| --- | --- | --- | --- | --- |
| `01-single-player-basic` | 1 | 0 | — | baseline walk/jump/land |
| `02-two-player-manual` | 2 | 0 | — | 2 human-controlled players, horizontal approach |
| `03-two-player-ai-kill` | 2 | 1 (p0) | — | AI chases and bump-kills the idle player; gore on (default) |
| `04-two-player-ai-kill-nogore` | 2 | 1 (p0) | `-nogore` | same scenario as 03, gore off — diverges from 03 starting at the kill frame |
| `05-four-players-ai` | 4 | 15 (all) | — | full 4-player roster, all CPU-controlled, multiple concurrent kills |
| `06-water-immersion` | 2 | 0 | — | player falls into a `BAN_WATER` tile (`in_water` toggles; this game's only "drowning"-adjacent mechanic — there is no water death, just buoyancy/swim-out) |
| `07-spring-bounce` | 2 | 0 | — | player lands on a `BAN_SPRING` tile, large upward launch |
| `08-ice-slide` | 1 | 0 | — | player stands/slides on a `BAN_ICE` tile, reduced-friction acceleration |
| `09-flies-off` | 1 | 0 | `-noflies` | identical input to 01, flies disabled — diverges from frame 0 because `flies_enabled` gates rnd() draws that feed the checksummed `rnd_call_count` |

Across the set: 1, 2, and 4 enabled players; AI on and off; gore on and off;
flies on and off; water, ice, and spring tile contact; and CPU-driven
bump-kills (this game's only kill mechanic — there's no direct-hit combat,
just landing on top of another player).

## Adding a new trace

1. Build the release binary (`make`) and run it with `-headless -seed <n>
   -dat data/jumpbump.dat -headless-players <n> -headless-ai <mask>
   -input <draft.jsonl>` to see what a candidate input trace does. Iterating
   on level-geometry-dependent traces (reaching a specific tile, timing a
   kill) by hand is slow and error-prone — see the debug aid below.
2. Once the trace does what you want, run the same command and capture
   stdout: each `FRAME <n> CHECKSUM <hex>` line's checksum belongs to the
   trace line with matching `frame`.
3. Merge the checksums into the trace's `"checksum"` field per line, write
   the `.meta.json` sidecar (seed, player count, AI mask, extra flags, a
   one-line `mechanic` description), and re-run once more to confirm two
   runs produce byte-identical checksums for every line.
4. Add a row to the coverage table above.

### Debug aid for finding level-geometry-dependent traces

`main.c`'s headless checksum block has a `JNB_HEADLESS_DEBUG_STATE` compile
guard (off by default — the committed Makefile never defines it) that
prints one `DEBUG f=<frame> p=<player> x=<..> y=<..> xa=<x_add> ya=<y_add>
inw=<in_water> bumps=<bumps> feet=<ban_map tile under the player's feet>`
line per enabled player per tick, to stderr. Rebuild with it defined to
watch exact positions/tile contact while iterating on a trace, e.g.:

```sh
cc -Wall -O2 -Dstricmp=strcasecmp -Dstrnicmp=strncasecmp -DUSE_SDL -DNDEBUG \
  -DJNB_HEADLESS_DEBUG_STATE -I. `sdl-config --cflags` -DUSE_NET \
  -DZLIB_SUPPORT -DBZLIB_SUPPORT -c -o main.o main.c
cc -o jumpnbump fireworks.o main.o menu.o filter.o -lm `sdl-config --libs` \
  -lSDL_mixer -lSDL_net -lbz2 -lz sdl.a
```

`feet` is the `ban_map` tile constant (`globals.pre`: 0 void, 1 solid, 2
water, 3 ice, 4 spring) under the player's feet that tick — the fastest way
to confirm a trace actually reaches the tile type it's meant to exercise.
Rebuild without the define (plain `make`) before recording real corpus
checksums — the debug output only goes to stderr and doesn't affect stdout
or the checksums, but corpus recordings should come from the same binary
everyone else builds.
