/*
 * Portable, glibc-compatible replacement for rand()/srand() (TASK-021).
 * See rnd_glibc.h for why this exists.
 *
 * This is glibc's TYPE_3 `random()` algorithm (degree 31, separation 3)
 * reimplemented from its published seeding/advance rules — not linked
 * from glibc, so it works identically on any host/libc. Verified against
 * known glibc output: srand(1) yields 1804289383, 846930886, 1681692777,
 * 1714636915, 1957747793, 424238335, ... and srand(42) yields 71876166,
 * 708592740, 1483128881, 907283241, ...
 */
#include "rnd_glibc.h"

#include <stdint.h>

#define JNB_RND_DEG 31
#define JNB_RND_SEP 3

static int32_t state[JNB_RND_DEG];
static int fptr;
static int rptr;

void jnb_srand(unsigned int seed)
{
	int32_t word;
	int i;

	if (seed == 0)
		seed = 1;

	state[0] = (int32_t)seed;
	for (i = 1; i < JNB_RND_DEG; i++) {
		/* word = 16807LL * state[i - 1] % 2147483647, folded into
		 * signed 32-bit result the way glibc's Schrage-style update
		 * does; state[i-1] is always in [1, 2147483646] here so the
		 * 64-bit product never overflows. */
		int64_t hi = (int64_t)16807 * state[i - 1] % 2147483647;
		word = (int32_t)hi;
		if (word < 0)
			word += 2147483647;
		state[i] = word;
	}

	fptr = JNB_RND_SEP;
	rptr = 0;

	/* glibc discards deg*10 outputs after seeding so early output isn't
	 * a thin function of the seed. */
	for (i = 0; i < JNB_RND_DEG * 10; i++)
		jnb_rand();
}

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
