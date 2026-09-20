/*
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

void fireworks_init_ref(void)
{
	int c1;
	int s1, s2, s3;

	for (c1 = 0; c1 < 20; c1++)
		rabbits[c1].used = 0;

	rabbits[0].used = 1;
	rabbits[0].colour = rnd(4);
	rabbits[0].x = (int) (150 + rnd(100)) << 16;
	rabbits[0].y = 256 << 16;
	rabbits[0].x_add = ((int) rnd(65535) << 1) - 65536;
	if (rabbits[0].x_add > 0)
		rabbits[0].direction = 0;
	else
		rabbits[0].direction = 1;
	rabbits[0].y_add = -262144 + (rnd(16384) * 5);
	rabbits[0].timer = 30 + rnd(150);
	rabbits[0].anim = 2;
	rabbits[0].frame = 0;
	rabbits[0].frame_tick = 0;
	rabbits[0].image = player_anims[rabbits[0].anim].frame[rabbits[0].frame].image + rabbits[0].colour * 18 + rabbits[0].direction * 9;

	for (c1 = 0; c1 < 300; c1++) {
		s1 = rnd(JNB_WIDTH);
		s2 = rnd(JNB_HEIGHT);
		s3 = 30 - rnd(7);
		stars[c1].x = (s1 << 16);
		stars[c1].y = (s2 << 16);
		stars[c1].col = s3;
	}
}

void fireworks_step_ref(void)
{
	int c1, c2;
	int gore_xa, gore_ya, gore_x, gore_y;

		for (c1 = 0; c1 < 300; c1++) {
			stars[c1].y -= (int) (31 - stars[c1].col) * 16384;
			if ((stars[c1].y >> 16) < 0)
				stars[c1].y += JNB_HEIGHT << 16;
			if ((stars[c1].y >> 16) >= JNB_HEIGHT)
				stars[c1].y -= JNB_HEIGHT << 16;
		}

		for (c1 = 0, c2 = 0; c1 < 20; c1++) {
			if (rabbits[c1].used == 1)
				c2++;
		}
		if ((c2 == 0 && rnd(10000) < 200) || (c2 == 1 && rnd(10000) < 150) || (c2 == 2 && rnd(10000) < 100) || (c2 == 3 && rnd(10000) < 50)) {
			for (c1 = 0; c1 < 20; c1++) {
				if (rabbits[c1].used == 0) {
					rabbits[c1].used = 1;
					rabbits[c1].colour = rnd(4);
					rabbits[c1].x = (int) (150 + rnd(100)) << 16;
					rabbits[c1].y = 256 << 16;
					rabbits[c1].x_add = ((int) rnd(65535) << 1) - 65536;
					if (rabbits[c1].x_add > 0)
						rabbits[c1].direction = 0;
					else
						rabbits[c1].direction = 1;
					rabbits[c1].y_add = -262144 + (rnd(16384) * 5);
					rabbits[c1].timer = 30 + rnd(150);
					rabbits[c1].anim = 2;
					rabbits[c1].frame = 0;
					rabbits[c1].frame_tick = 0;
					rabbits[c1].image = player_anims[rabbits[c1].anim].frame[rabbits[c1].frame].image + rabbits[c1].colour * 18 + rabbits[c1].direction * 9;
					break;
				}
			}
		}

		for (c1 = 0; c1 < 20; c1++) {
			if (rabbits[c1].used == 1) {
				rabbits[c1].y_add += 2048;
				if (rabbits[c1].y_add > 36864 && rabbits[c1].anim != 3) {
					rabbits[c1].anim = 3;
					rabbits[c1].frame = 0;
					rabbits[c1].frame_tick = 0;
					rabbits[c1].image = player_anims[rabbits[c1].anim].frame[rabbits[c1].frame].image + rabbits[c1].colour * 18 + rabbits[c1].direction * 9;
				}
				rabbits[c1].x += rabbits[c1].x_add;
				rabbits[c1].y += rabbits[c1].y_add;
				if ((rabbits[c1].x >> 16) < 16 || (rabbits[c1].x >> 16) > JNB_WIDTH || (rabbits[c1].y >> 16) > JNB_HEIGHT) {
					rabbits[c1].used = 0;
					continue;
				}
				rabbits[c1].timer--;
				if (rabbits[c1].timer <= 0) {
					rabbits[c1].used = 0;
					for (c2 = 0; c2 < 6; c2++) {
						gore_ya = rabbits[c1].y_add + (rnd(65535) - 32768) * 3;
						gore_xa = rabbits[c1].x_add + (rnd(65535) - 32768) * 3;
						gore_y = (rabbits[c1].y >> 16) + 6 + rnd(5);
						gore_x = (rabbits[c1].x >> 16) + 6 + rnd(5);
						add_object(OBJ_FUR, gore_x, gore_y, gore_xa, gore_ya, 0, 44 + rabbits[c1].colour * 8);
					}
					for (c2 = 0; c2 < 6; c2++) {
						gore_ya = rabbits[c1].y_add + (rnd(65535) - 32768) * 3;
						gore_xa = rabbits[c1].x_add + (rnd(65535) - 32768) * 3;
						gore_y = (rabbits[c1].y >> 16) + 6 + rnd(5);
						gore_x = (rabbits[c1].x >> 16) + 6 + rnd(5);
						add_object(OBJ_FLESH, gore_x, gore_y, gore_xa, gore_ya, 0, 76);
					}
					for (c2 = 0; c2 < 6; c2++) {
						gore_ya = rabbits[c1].y_add + (rnd(65535) - 32768) * 3;
						gore_xa = rabbits[c1].x_add + (rnd(65535) - 32768) * 3;
						gore_y = (rabbits[c1].y >> 16) + 6 + rnd(5);
						gore_x = (rabbits[c1].x >> 16) + 6 + rnd(5);
						add_object(OBJ_FLESH, gore_x, gore_y, gore_xa, gore_ya, 0, 77);
					}
					for (c2 = 0; c2 < 8; c2++) {
						gore_ya = rabbits[c1].y_add + (rnd(65535) - 32768) * 3;
						gore_xa = rabbits[c1].x_add + (rnd(65535) - 32768) * 3;
						gore_y = (rabbits[c1].y >> 16) + 6 + rnd(5);
						gore_x = (rabbits[c1].x >> 16) + 6 + rnd(5);
						add_object(OBJ_FLESH, gore_x, gore_y, gore_xa, gore_ya, 0, 78);
					}
					for (c2 = 0; c2 < 10; c2++) {
						gore_ya = rabbits[c1].y_add + (rnd(65535) - 32768) * 3;
						gore_xa = rabbits[c1].x_add + (rnd(65535) - 32768) * 3;
						gore_y = (rabbits[c1].y >> 16) + 6 + rnd(5);
						gore_x = (rabbits[c1].x >> 16) + 6 + rnd(5);
						add_object(OBJ_FLESH, gore_x, gore_y, gore_xa, gore_ya, 0, 79);
					}
					dj_play_sfx(SFX_DEATH, SFX_DEATH_FREQ, 64, 0, 0, -1);
					continue;
				}
				rabbits[c1].frame_tick++;
				if (rabbits[c1].frame_tick >= player_anims[rabbits[c1].anim].frame[rabbits[c1].frame].ticks) {
					rabbits[c1].frame++;
					if (rabbits[c1].frame >= player_anims[rabbits[c1].anim].num_frames)
						rabbits[c1].frame = player_anims[rabbits[c1].anim].restart_frame;
					rabbits[c1].frame_tick = 0;
				}
				rabbits[c1].image = player_anims[rabbits[c1].anim].frame[rabbits[c1].frame].image + rabbits[c1].colour * 18 + rabbits[c1].direction * 9;
				if (rabbits[c1].used == 1)
					add_pob(main_info.draw_page, rabbits[c1].x >> 16, rabbits[c1].y >> 16, rabbits[c1].image, &rabbit_gobs);
			}
		}

		update_objects();
}
