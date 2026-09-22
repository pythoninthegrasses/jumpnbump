// Port of main.c's rnd() (main.c:3562) — TASK-011.01, the leaf dependency
// every other TASK-011.* module draws random values from.
//
// Despite the task description's "LCG" phrasing, rnd() is a thin wrapper
// over rand(), not a custom linear congruential generator. It was
// originally ported as a direct @cImport of libc's rand()/srand(), which
// is where TASK-021 found the cross-platform bug: libc's rand() isn't one
// algorithm — glibc's is a degree-31 additive-feedback generator, while
// e.g. Apple's libc rand() is a Lehmer/minstd generator, so the same seed
// produced completely different streams (and therefore completely
// different checksums) depending on the host running the corpus test.
// This module now reimplements glibc's specific TYPE_3 `random()`
// algorithm directly — no libc dependency at all, which also brings it in
// line with docs/porting-playbook.md's "pure, deterministic state machine,
// no libc" rule for the simulation core. core/c_ref/rnd.c and the
// top-level rnd_glibc.c (main.c's copy) hand-mirror the identical
// algorithm; core/rnd_difftest.zig checks this port against the C
// reference bit-for-bit. This module keeps owning rnd() plus the checksum
// scaffolding counter around it.

/// rnd_call_count (main.c:72): incremented on every rnd() call; stands in
/// for rand()'s unobservable internal PRNG state in the canonical
/// checksum (docs/checksum-format.md). main.c declares it `unsigned int`;
/// exported like the C's global so later modules mirror it with
/// `extern var` per the playbook's globals-ownership rule.
pub export var rnd_call_count: c_uint = 0;

// glibc's TYPE_3 `random()`: a degree-31, separation-3 additive-feedback
// generator. state[] is a circular buffer; fptr/rptr walk it 3 apart.
const deg = 31;
const sep = 3;

var state: [deg]i32 = [_]i32{0} ** deg;
var fptr: usize = 0;
var rptr: usize = 0;

/// The next raw draw in [0, 0x7fffffff], glibc's random()/rand() algorithm
/// bit-for-bit (verified against known output: srand(1) yields 1804289383,
/// 846930886, 1681692777, ...; srand(42) yields 71876166, 708592740, ...).
fn nextRaw() u32 {
    const f: u32 = @bitCast(state[fptr]);
    const r: u32 = @bitCast(state[rptr]);
    state[fptr] = @bitCast(f +% r);
    const result: u32 = (@as(u32, @bitCast(state[fptr])) >> 1) & 0x7fffffff;

    fptr += 1;
    if (fptr >= deg) fptr = 0;
    rptr += 1;
    if (rptr >= deg) rptr = 0;

    return result;
}

/// rnd(max) (main.c:3562): the next raw draw reduced mod max, returned
/// as u16 — the C's (unsigned short) cast keeps the low 16 bits, so this
/// must truncate, not range-check, even though the draw's low bits stay
/// inside u16 for every max this game calls with.
pub export fn rnd(max: u16) u16 {
    rnd_call_count +%= 1;
    const r: u16 = @intCast(@mod(nextRaw(), @as(u32, max)));
    return r;
}

/// Seed both halves of the RNG state main.c seeds together at startup
/// (main.c:3250): the generator's internal state and rnd_call_count (the
/// counter's zeroing rides along here so a harness can reset both sides
/// with one call). Matches glibc's srandom() seeding exactly, including
/// its zero-seed guard and its degree*10 discarded warm-up draws.
pub fn seed(seed_: u32) void {
    rnd_call_count = 0;

    const s: u32 = if (seed_ == 0) 1 else seed_;
    state[0] = @bitCast(s);
    for (1..deg) |i| {
        const prev: i64 = state[i - 1];
        var word: i64 = @mod(16807 * prev, 2147483647);
        if (word < 0) word += 2147483647;
        state[i] = @intCast(word);
    }

    fptr = sep;
    rptr = 0;

    for (0..deg * 10) |_| _ = nextRaw();
}

/// Cross-module entry point for other ported modules that reach rnd() as an
/// extern fn per the no-@import rule (core/flies.zig's own Tier-A tests):
/// the same seed(), reached without an @import between ported modules
/// (playbook rule), the same arrangement core/steer.zig's sfxRecordZ/
/// sfxResetZ use for its own cross-module entry points.
pub export fn seedZ(seed_val: c_uint) void {
    seed(seed_val);
}

test "seed(1) reproduces glibc's srandom(1) raw draw sequence" {
    const std = @import("std");
    seed(1);
    const want = [_]u32{ 1804289383, 846930886, 1681692777, 1714636915, 1957747793, 424238335 };
    for (want) |w| try std.testing.expectEqual(w, nextRaw());
}

test "seed(42) reproduces glibc's srandom(42) raw draw sequence" {
    const std = @import("std");
    seed(42);
    const want = [_]u32{ 71876166, 708592740, 1483128881, 907283241 };
    for (want) |w| try std.testing.expectEqual(w, nextRaw());
}

test "seed(0) is treated like seed(1), matching glibc's zero-seed guard" {
    const std = @import("std");
    seed(0);
    try std.testing.expectEqual(@as(u32, 1804289383), nextRaw());
}

test "seed() resets rnd_call_count" {
    const std = @import("std");
    _ = rnd(100);
    _ = rnd(100);
    try std.testing.expect(rnd_call_count > 0);
    seed(1);
    try std.testing.expectEqual(@as(c_uint, 0), rnd_call_count);
}
