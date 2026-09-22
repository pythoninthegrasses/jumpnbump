# Headless canonical-state checksum format

TASK-008.02. This is the format the Zig port's differential tests (TASK-008.04)
and the JSONL corpus (TASK-008.03) diff against.

## When it's emitted

Once per simulation tick, only in `-headless` mode, from `game_loop()` in
`main.c` — after `update_objects()` and `update_flies()` have run for the
tick, before any rendering/paging work (which is itself skipped headless).
One line to stdout per tick:

```
FRAME <frame_num> CHECKSUM <hash>
```

- `frame_num`: zero-based tick counter, `%u`.
- `hash`: 8 lowercase hex digits, `%08x`.

## Byte layout folded into the checksum

The checksum is FNV-1a, 32-bit, offset basis `2166136261`, prime `16777619`.
Each `unsigned int` value below is folded into the hash 4 bytes at a time,
**little-endian**, regardless of host byte order (`checksum_fold_u32()` in
`main.c` shifts and masks explicitly rather than reading through the value's
native representation), so the algorithm produces the same result on any
host. Fields are folded in this fixed order:

1. `frame_num` (the same value that's printed).
2. `rnd_call_count` — a global counter incremented on every call to `rnd()`.
   `rand()`'s internal PRNG state isn't introspectable through libc, so this
   count stands in for it: given the fixed `-seed`, the same call count
   implies the same underlying `rand()` state.
3. `player[JNB_MAX_PLAYERS]` (4 players), each serialized in `player_t`
   declaration order (`globals.pre`): `action_left`, `action_up`,
   `action_right`, `enabled`, `dead_flag`, `bumps`, `bumped[0..3]`, `x`, `y`,
   `x_add`, `y_add`, `direction`, `jump_ready`, `jump_abort`, `in_water`,
   `anim`, `frame`, `frame_tick`, `image` — 22 ints per player, 88 total.
4. `objects[NUM_OBJECTS]` (200 slots), each serialized in `object_t`
   declaration order: `used`, `type`, `x`, `y`, `x_add`, `y_add`, `x_acc`,
   `y_acc`, `anim`, `frame`, `ticks`, `image` — 12 ints per slot, 2400 total.
   All 200 slots are folded in regardless of `used`, so a slot's transition
   between unused and used is itself part of the checksum.
5. `ban_map[17][22]`, row-major, 374 `unsigned int` values.

Every `int` field is folded as its bit pattern reinterpreted as `unsigned
int` (a plain C cast — two's-complement negative values fold to their
unsigned bit pattern, which is what `checksum_fold_u32` expects).

## Determinism

Given the same `-seed` and the same `-input` trace, two headless runs emit
byte-identical `FRAME`/`CHECKSUM` sequences (verified by diffing two runs of
`tests/fixtures/headless-smoke.jsonl`). Checksums are expected to change from
frame to frame during active gameplay and to stay reproducible across
repeated runs of the same input.

This holds across hosts, not just across repeated runs on one host: `rnd()`
(field 2 above, and every player-position/object-spawn value it seeds)
reimplements glibc's specific `rand()` algorithm directly (TASK-021) rather
than calling host libc, since libc `rand()` isn't one algorithm — glibc's,
Apple's, and musl's all disagree on the same seed. Before TASK-021, the
`-seed`+`-input` reproducibility above only held per-host; the checksummed
corpus (`tests/corpus/`) was recorded on an x86_64/glibc host and silently
never reproduced on any other libc.
