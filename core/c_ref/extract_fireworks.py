#!/usr/bin/env python3
"""Generate core/c_ref/fireworks.c from fireworks.c.

TASK-017.02's renamed-C reference is not a hand-copied excerpt: every
simulation-relevant span below is sliced verbatim (by line range, re-read
from the current checkout every run, not retyped) out of fireworks.c's
single `fireworks()` function. Unlike main.c's `add_object`/`update_objects`
(core/c_ref/extract_objects.py), fireworks() is not a clean function to cut
as one contiguous range: it interleaves rabbit/star simulation state with
dj_mix()/intr_sysupdate()/draw_begin()/draw_end()/flippage()/wait_vrt()/
redraw_pob_backgrounds() calls throughout one function body. So this script
also drops a short, explicit list of presentation-only spans (each
individually non-load-bearing for exactly the reason core/game_loop.zig's
own header comment gives for dropping game_loop()'s equivalent calls: none
of them ever feed back into rabbits[]/stars[]/objects[]/ban_map[] state) and
rewrites two small spans:

  - The two-buffer star position (fireworks.c:103-104) is a duplicate
    assignment (`stars[c1].x = stars[c1].old_x = ...`) that this port has no
    old_x/old_y field for (TASK-017.02's stars[] drops old_x/old_y/back[2] --
    a pure rendering double-buffer cache with zero effect on future ticks).
    Rewritten to drop the `old_x =`/`old_y =` half only.
  - The five add_object() calls inside the detonation's explosion loops
    (fireworks.c:181-190) are rewritten into explicitly sequenced local
    variables in the oracle's actual right-to-left argument-evaluation
    order, exactly like core/c_ref/collision.c's furGore/fleshGore
    equivalent already does (and for the identical reason: recompiling this
    text with Zig's bundled clang evaluates left-to-right, which would
    silently diverge from the shipped gcc oracle if the call expression
    were kept verbatim).

Every other line either stays verbatim or is dropped outright (dj_mix,
intr_sysupdate, draw_begin/draw_end, the palette/gob/mask/level-pcx setup,
the two star background-cache loops, flippage, wait_vrt,
redraw_pob_backgrounds, and the trailing dj_set_nosound calls). add_object(),
update_objects(), dj_play_sfx() and add_pob() are declared but never
redefined here: add_object/update_objects are main.c's own, mirrored by
core/objects.zig's real exports (core/c_ref/collision.c already establishes
this exact "declare, don't rename" convention); dj_play_sfx/add_pob resolve
to core/fireworks_difftest.zig's own capture sinks.

A handful of literal-text assertions below guard against silent drift: if
fireworks.c's shape ever changes, this script fails loudly instead of
quietly emitting a reference that no longer matches the real oracle.
Regenerate after any change to fireworks.c:

    python3 core/c_ref/extract_fireworks.py
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "fireworks.c"
OUT = Path(__file__).resolve().parent / "fireworks.c"

PREAMBLE = """/*
 * GENERATED FILE - do not edit by hand.
 *
 * Renamed-C reference for core/fireworks.zig (TASK-017.02): fireworks.c's
 * fireworks() function, split into fireworks_init_ref() (the one-time
 * rabbit-0/star setup) and fireworks_step_ref() (one loop iteration),
 * extracted by core/c_ref/extract_fireworks.py -- see that script's
 * docstring for exactly which spans are kept verbatim, dropped, or
 * rewritten, and why. Re-run it if fireworks.c changes; editing this file
 * by hand reintroduces exactly the transcription drift the extraction
 * exists to prevent. core/build.zig compiles it through
 * compileRenamedCRefSanitized, which prefixes fireworks_init_ref/
 * fireworks_step_ref with c_ so they link alongside the Zig port (which
 * owns the original names) -- everything else in this file (rnd,
 * add_object, update_objects, dj_play_sfx, add_pob, ban_map, player_anims,
 * rabbits, stars) is deliberately NOT in that rename list, so those tokens
 * resolve to the real shared symbols the harness and the already-ported
 * Zig modules provide -- one world, exactly like every other TASK-011.*
 * differential.
 *
 * rabbits[]/stars[] are function-local in the real fireworks.c; they are
 * hoisted to file scope here (as `extern`, defined by the harness --
 * core/fireworks.zig's own exported storage) so the harness can read and
 * compare them after each call. stars[] carries only x/y/col: old_x/old_y/
 * back[2] are fireworks.c's own rendering double-buffer cache, which this
 * port does not carry (see this file's own docstring).
 */

#define SFX_DEATH 2
#define SFX_DEATH_FREQ 20000
#define JNB_WIDTH 400
#define JNB_HEIGHT 256
#define OBJ_FUR 5
#define OBJ_FLESH 6

typedef struct {
	int used, direction, colour;
	int x, y;
	int x_add, y_add;
	int timer;
	int anim, frame, frame_tick, image;
} rabbit_t;

typedef struct {
	int x, y;
	int col;
} star_t;

typedef struct {
	int num_frames;
	int restart_frame;
	struct {
		int image;
		int ticks;
	} frame[4];
} player_anim_t;

/* Defined by the harness (core/fireworks_difftest.zig): core/fireworks.zig's
 * own exported rabbits[]/stars[] storage. player_anims[] is core/steer.zig's
 * export under its own name (core/c_ref/collision.c's own precedent: no
 * _raw alias needed). ban_map[] is core/steer.zig's ban_map_raw storage --
 * aliased back to the bare name the extracted text uses, the same way
 * core/c_ref/collision.c aliases player[]/objects[]/ban_map[]. */
extern rabbit_t rabbits[20];
extern star_t stars[300];
extern player_anim_t player_anims[7];
extern unsigned int ban_map_raw[17][22];
#define ban_map ban_map_raw

/* Harness-provided (core/fireworks_difftest.zig). c_rnd_from() serves both
 * sides the same libc rand() stream, matching every other difftest's own
 * copy of this bridge. add_object()/update_objects() are main.c's own,
 * mirrored by core/objects.zig's real exports -- declared, never redefined
 * here (core/c_ref/collision.c's own precedent). dj_play_sfx()/add_pob()
 * are capture sinks: dj_play_sfx records (id, freq) verbatim (this call
 * site has no rnd() jitter to evaluate, unlike the player-death cue); add_pob
 * records (x, y, image) and drops the page/gobs operands, the same shape
 * core/c_ref/objects.c's own add_pob stub already established. */
unsigned short c_rnd_from(unsigned short max);
void add_object(int type, int x, int y, int x_add, int y_add, int anim, int frame);
void update_objects(void);
void dj_play_sfx(int id, int freq, int vol, int pan, int unused, int channel);
void add_pob(void *page, int x, int y, int image, void *gobs);
#define rnd(max) c_rnd_from((max))

/* main_info.draw_page and &rabbit_gobs are the two draw-boundary operands
 * the extracted add_pob() call site passes through; the sink drops both, so
 * opaque placeholders declared by the harness are enough for this text to
 * compile (core/c_ref/objects.c's own main_info/object_gobs precedent). */
typedef struct { void *draw_page; } main_info_t;
extern main_info_t main_info;
extern int rabbit_gobs;
"""


def die(msg: str) -> None:
    sys.exit(f"extract_fireworks.py: {msg}")


def expect(lines: list[str], lineno: int, text: str) -> None:
    """1-indexed content assertion (whitespace-insensitive -- indentation
    doesn't affect C semantics, so this only guards against a real content
    change, not a cosmetic one): fails loudly on any drift."""
    got = lines[lineno - 1].strip()
    if got != text.strip():
        die(f"fireworks.c:{lineno} changed shape.\n  expected: {text!r}\n  got:      {got!r}")


def span(lines: list[str], start: int, end: int) -> str:
    """1-indexed inclusive verbatim slice, joined with the original newlines."""
    return "\n".join(lines[start - 1 : end])


def main() -> None:
    lines = SRC.read_text().split("\n")

    # Anchor checks: the shape this extraction depends on. Any change to
    # these exact lines means the span line numbers above (and the rewrite
    # below) must be revisited by hand, not silently reused.
    expect(lines, 30, "void fireworks(void)")
    expect(lines, 79, "	for (c1 = 0; c1 < 20; c1++)")
    expect(lines, 82, "	rabbits[0].used = 1;")
    expect(lines, 99, "	for (c1 = 0; c1 < 300; c1++) {")
    expect(lines, 103, "		stars[c1].x = stars[c1].old_x = (s1 << 16);")
    expect(lines, 104, "		stars[c1].y = stars[c1].old_y = (s2 << 16);")
    expect(lines, 117, "	while (key_pressed(1) == 0) {")
    expect(lines, 122, "		for (c1 = 0; c1 < 300; c1++) {")
    expect(lines, 136, "		if ((c2 == 0 && rnd(10000) < 200) || (c2 == 1 && rnd(10000) < 150) || (c2 == 2 && rnd(10000) < 100) || (c2 == 3 && rnd(10000) < 50)) {")
    expect(lines, 163, "		for (c1 = 0; c1 < 20; c1++) {")
    expect(lines, 181, "					for (c2 = 0; c2 < 6; c2++)")
    expect(lines, 182, "						add_object(OBJ_FUR, (rabbits[c1].x >> 16) + 6 + rnd(5), (rabbits[c1].y >> 16) + 6 + rnd(5), rabbits[c1].x_add + (rnd(65535) - 32768) * 3, rabbits[c1].y_add + (rnd(65535) - 32768) * 3, 0, 44 + rabbits[c1].colour * 8);")
    expect(lines, 191, "					dj_play_sfx(SFX_DEATH, SFX_DEATH_FREQ, 64, 0, 0, -1);")
    expect(lines, 202, "				if (rabbits[c1].used == 1)")
    expect(lines, 203, "					add_pob(main_info.draw_page, rabbits[c1].x >> 16, rabbits[c1].y >> 16, rabbits[c1].image, &rabbit_gobs);")
    expect(lines, 209, "			update_objects();")
    expect(lines, 244, "	}")
    expect(lines, 248, "}")

    # --- fireworks_init_ref(): fireworks.c:79-107, minus the double-buffer
    # star-position half and the render-cache line. ---
    init_body = "\n".join([
        span(lines, 79, 80),  # rabbits[c1].used = 0 loop
        "",
        span(lines, 82, 96),  # rabbit 0 seed
        "",
        span(lines, 99, 102),  # star loop header + s1/s2/s3 draws
        "\t\tstars[c1].x = (s1 << 16);",
        "\t\tstars[c1].y = (s2 << 16);",
        span(lines, 105, 105),  # stars[c1].col = s3;
        span(lines, 107, 107),  # }
    ])

    # --- fireworks_step_ref(): fireworks.c:122-209, minus every
    # presentation call and the star old_x/old_y bookkeeping, with the five
    # add_object() explosion calls rewritten into sequenced right-to-left
    # local variables (see this script's docstring). ---
    explosion_counts = [(6, "OBJ_FUR", "44 + rabbits[c1].colour * 8"), (6, "OBJ_FLESH", "76"), (6, "OBJ_FLESH", "77"), (8, "OBJ_FLESH", "78"), (10, "OBJ_FLESH", "79")]
    explosion_lines: list[str] = []
    for count, kind, frame in explosion_counts:
        explosion_lines.append(f"\t\t\t\t\tfor (c2 = 0; c2 < {count}; c2++) {{")
        explosion_lines.append("\t\t\t\t\t\tgore_ya = rabbits[c1].y_add + (rnd(65535) - 32768) * 3;")
        explosion_lines.append("\t\t\t\t\t\tgore_xa = rabbits[c1].x_add + (rnd(65535) - 32768) * 3;")
        explosion_lines.append("\t\t\t\t\t\tgore_y = (rabbits[c1].y >> 16) + 6 + rnd(5);")
        explosion_lines.append("\t\t\t\t\t\tgore_x = (rabbits[c1].x >> 16) + 6 + rnd(5);")
        explosion_lines.append(f"\t\t\t\t\t\tadd_object({kind}, gore_x, gore_y, gore_xa, gore_ya, 0, {frame});")
        explosion_lines.append("\t\t\t\t\t}")

    step_body = "\n".join([
        span(lines, 122, 122),  # star loop header
        span(lines, 125, 130),  # y scroll + wrap, closing brace
        "",
        span(lines, 132, 157),  # live-count + spawn check/body
        "",
        span(lines, 163, 180),  # rabbit physics through timer<=0 -> used=0
        "\n".join(explosion_lines),
        span(lines, 191, 192),  # dj_play_sfx + continue;
        span(lines, 193, 205),  # frame_tick/frame/image walk, add_pob, closing braces
        "",
        span(lines, 209, 209),  # update_objects();
    ])

    out = PREAMBLE
    out += "\nvoid fireworks_init_ref(void)\n{\n\tint c1;\n\tint s1, s2, s3;\n\n"
    out += init_body + "\n}\n"
    out += "\nvoid fireworks_step_ref(void)\n{\n\tint c1, c2;\n\tint gore_xa, gore_ya, gore_x, gore_y;\n\n"
    out += step_body + "\n}\n"

    OUT.write_text(out)
    print(f"{OUT.name}: generated from fireworks.c (init: lines 79-107, step: lines 122-209, minus presentation)")


if __name__ == "__main__":
    main()
