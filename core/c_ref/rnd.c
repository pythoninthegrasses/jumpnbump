/*
 * Renamed-C reference for core/rnd.zig (TASK-011.01).
 *
 * main.c's rnd() (main.c:3562) with the rnd_call_count bookkeeping
 * stripped — that counter is checksum scaffolding (docs/checksum-format.md),
 * not part of the RNG formula, and it lives in the ported module instead.
 * Compiled as the renamed-C-reference side of the difftest harness
 * (core/build.zig's compileRenamedCRef renames this to c_rnd) so
 * core/rnd_difftest.zig can drive both sides over 10,000+-call sequences.
 * Keep in sync with main.c's rnd() by hand.
 *
 * jnb_srand()/jnb_rand() below are a byte-for-byte duplicate of the
 * top-level rnd_glibc.c/.h main.c links against — hand-kept in sync the
 * same way this whole file hand-mirrors main.c's rnd(), rather than wired
 * into this build via an extra cross-directory C source (every other
 * *_c_ref object in core/build.zig is a single self-contained source file;
 * this keeps that pattern). See rnd_glibc.h for why libc rand()/srand()
 * aren't used here: they aren't portable across libcs (TASK-021), which is
 * exactly the divergence this reference and core/rnd.zig must not have
 * between them.
 */
#include <stdint.h>

#define JNB_RND_DEG 31
#define JNB_RND_SEP 3

static int32_t state[JNB_RND_DEG];
static int fptr;
static int rptr;
static int seeded;

unsigned int jnb_rand(void)
{
	uint32_t result;

	state[fptr] = (int32_t)((uint32_t)state[fptr] + (uint32_t)state[rptr]);
	result = ((uint32_t)state[fptr] >> 1) & 0x7fffffffu;

	fptr++;
	if (fptr >= JNB_RND_DEG) {
		fptr = 0;
		rptr++;
	} else {
		rptr++;
		if (rptr >= JNB_RND_DEG)
			rptr = 0;
	}

	return result;
}

void jnb_srand(unsigned int seed)
{
	int32_t word;
	int i;

	seeded = 1;

	if (seed == 0)
		seed = 1;

	state[0] = (int32_t)seed;
	for (i = 1; i < JNB_RND_DEG; i++) {
		int64_t hi = (int64_t)16807 * state[i - 1] % 2147483647;
		word = (int32_t)hi;
		if (word < 0)
			word += 2147483647;
		state[i] = word;
	}

	fptr = JNB_RND_SEP;
	rptr = 0;

	for (i = 0; i < JNB_RND_DEG * 10; i++)
		jnb_rand();
}

/* Unseeded rnd()/rand() behaves, per the C standard, as though srand(1) had
 * already run — matched here so this reference's Tier-A unit-test callers
 * (which never call jnb_srand()/seed() themselves) see the same nonzero,
 * deterministic stream libc rand() gave them before TASK-021. */
static void ensure_seeded(void)
{
	if (!seeded)
		jnb_srand(1);
}

unsigned short rnd(unsigned short max)
{
	ensure_seeded();
	return (unsigned short)(jnb_rand() % (int)max);
}
