/*
 * Portable, glibc-compatible replacement for rand()/srand() (TASK-021).
 *
 * main.c's rnd() (main.c:3562) reduces a raw rand() draw mod max and folds
 * rnd_call_count into the canonical checksum (docs/checksum-format.md), so
 * the corpus's recorded checksums are only reproducible on a host whose
 * libc rand() implements the same PRNG glibc does. It doesn't: glibc uses a
 * degree-31 additive-feedback generator (its TYPE_3 `random()`), while e.g.
 * Apple's libc rand() is a simple Lehmer/minstd generator — same seed,
 * completely different output stream. That divergence is TASK-021's root
 * cause (all 10 corpus traces mismatching at frame 0 on macOS/ARM64).
 *
 * jnb_srand()/jnb_rand() reimplement glibc's TYPE_3 generator directly, so
 * every consumer that needs the corpus's exact stream (main.c, the
 * C-reference rnd() core/c_ref/rnd.c compiles for the Tier-B difftest, and
 * core/rnd.zig's pure-Zig port) can produce it on any host.
 */
#ifndef JNB_RND_GLIBC_H
#define JNB_RND_GLIBC_H

void jnb_srand(unsigned int seed);
unsigned int jnb_rand(void);

#endif
