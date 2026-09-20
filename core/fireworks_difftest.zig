// Tier-B differential tests for TASK-017.02: core/fireworks.zig's port of
// fireworks.c's fireworks() vs the renamed-C reference in
// core/c_ref/fireworks.c (extracted by core/c_ref/extract_fireworks.py),
// wired up in core/build.zig via compileRenamedCRefSanitized.
//
// Method (core/objects_difftest.zig's shape, not core/game_loop_difftest.zig's
// corpus-replay shape): fireworks() takes no external input at all — it's
// driven purely by rabbits[]/stars[]/objects[] plus the rnd() stream, the
// same situation update_objects() is already in. So this is a
// hand-authored `scenarios` list of {seed, ticks} replays, not a
// tests/corpus/*.jsonl trace (that mechanism records human/AI *input*,
// which doesn't exist here).
//
// Per tick: snapshot, run the C reference, deep-copy its
// rabbits[]/stars[]/objects[] + captured draw/sfx streams, restore the
// snapshot, re-seed, run the Zig port, compare every field. Because both
// sides start each tick from the same world and the same PRNG state, the
// only source of a difference is core/fireworks.zig's own ported logic —
// the spawn-threshold short-circuit, the right-to-left explosion argument
// order, or rnd() consumption.
//
// add_object()/update_objects() are declared but never redefined in
// core/c_ref/fireworks.c (core/c_ref/collision.c's own precedent): both
// this file's C reference run and the Zig run below call through to the
// *same* real core/objects.zig exports, so a mismatch can only come from
// core/fireworks.zig's own new logic (what arguments it computes to feed
// add_object, not add_object/update_objects' own correctness — already
// proven by core/objects_difftest.zig).
const std = @import("std");
const rnd_mod = @import("rnd.zig");
const world = @import("world.zig");
const steer = @import("steer.zig");
const objects = @import("objects.zig");

// Force objects.zig's add_object/update_objects into this compilation
// (core/collision_difftest.zig's own precedent: merely @import-ing a
// module without ever naming one of its decls lets Zig prune it, so
// fireworks.zig's own `extern fn add_object`/`update_objects` would have
// nothing to link against). core/fireworks.zig calls the real exports
// directly by their C-linkage names; this reference is only here to force
// their analysis/emission.
comptime {
    _ = &objects.add_object;
    _ = &objects.update_objects;
}

/// steer.loadDefaultAnims() below pulls steer.zig's whole container into
/// this compilation, which also emits its position_player (unused here but
/// still analyzed, since Zig emits every export in an analyzed file) —
/// and that reaches extern is_server. Pinned to the headless/single-
/// player value, matching core/objects_difftest.zig's own is_server_one
/// placeholder.
var is_server_one: c_int = 1;
comptime {
    @export(&is_server_one, .{ .name = "is_server" });
}
const fireworks = @import("fireworks.zig");

extern fn c_fireworks_init_ref() void;
extern fn c_fireworks_step_ref() void;

// ---------------------------------------------------------------------------
// Shared world: steer.zig's exported storage, reached the same way every
// other *_difftest.zig declares its own extern bindings rather than
// reaching through another module's (non-pub) exports.
// ---------------------------------------------------------------------------
extern var objects_raw: [world.num_objects]world.Object;
extern var ban_map_raw: [world.ban_rows][world.ban_cols]u32;

fn setupWorld() void {
    objects_raw = std.mem.zeroes([world.num_objects]world.Object);
    ban_map_raw = std.mem.zeroes([world.ban_rows][world.ban_cols]u32); // memset(ban_map, 0, ...), fireworks.c:64
    steer.loadDefaultAnims();
}

// ---------------------------------------------------------------------------
// Capture sinks for the C reference's own draw/sfx boundary calls
// (core/objects_difftest.zig's add_pob/add_leftovers precedent).
// ---------------------------------------------------------------------------

const DrawEvent = struct { x: c_int, y: c_int, image: c_int };
var draw_c: [64]DrawEvent = undefined;
var draw_z: [64]DrawEvent = undefined;
var n_draw_c: usize = 0;
var n_draw_z: usize = 0;

var sfx_c: [64]c_int = undefined;
var sfx_z: [64]c_int = undefined;
var n_sfx_c: usize = 0;
var n_sfx_z: usize = 0;

export fn add_pob(page: ?*anyopaque, x: c_int, y: c_int, image: c_int, gobs: ?*anyopaque) void {
    _ = .{ page, gobs };
    if (n_draw_c < draw_c.len) draw_c[n_draw_c] = .{ .x = x, .y = y, .image = image };
    n_draw_c += 1;
}

export fn dj_play_sfx(id: c_int, freq: c_int, vol: c_int, pan: c_int, unused: c_int, channel: c_int) void {
    _ = .{ vol, pan, unused, channel };
    if (n_sfx_c < sfx_c.len) sfx_c[n_sfx_c] = id *% 100000 +% freq;
    n_sfx_c += 1;
}

/// The C reference's rnd() — same core/rnd.zig call the Zig port makes, so
/// both consume one libc stream.
export fn c_rnd_from(max: c_ushort) c_ushort {
    return rnd_mod.rnd(max);
}

// Placeholders for the two draw operands the extracted C's add_pob call
// passes through (dropped by the sink above) — core/objects_difftest.zig's
// object_gobs/main_info precedent.
export var rabbit_gobs: c_int = 0;
export var main_info: extern struct { draw_page: ?*anyopaque } = .{ .draw_page = null };

// ---------------------------------------------------------------------------
// Snapshot / compare.
// ---------------------------------------------------------------------------

const Snapshot = struct {
    rabbits: [fireworks.num_rabbits]fireworks.Rabbit,
    stars: [fireworks.num_stars]fireworks.Star,
    objects: [world.num_objects]world.Object,
    rnd_calls: c_uint,
};

fn snapshot() Snapshot {
    return .{
        .rabbits = fireworks.rabbits,
        .stars = fireworks.stars,
        .objects = objects_raw,
        .rnd_calls = rnd_mod.rnd_call_count,
    };
}

fn restore(s: *const Snapshot) void {
    fireworks.rabbits = s.rabbits;
    fireworks.stars = s.stars;
    objects_raw = s.objects;
    rnd_mod.rnd_call_count = s.rnd_calls;
}

fn compareArray(comptime T: type, name: []const u8, tick: usize, label: []const u8, want: []const T, got: []const T, mismatches: *usize) void {
    for (want, 0..) |w, i| {
        inline for (std.meta.fields(T)) |f| {
            const wv: c_int = @field(w, f.name);
            const zv: c_int = @field(got[i], f.name);
            if (wv != zv) {
                if (mismatches.* < 40) std.debug.print("{s} tick {d} {s}[{d}].{s}: zig={d} != c={d}\n", .{ name, tick, label, i, f.name, zv, wv });
                mismatches.* += 1;
            }
        }
    }
}

fn compareTraces(name: []const u8, tick: usize, mismatches: *usize) void {
    if (n_draw_c != n_draw_z) {
        std.debug.print("{s} tick {d}: draw count zig={d} != c={d}\n", .{ name, tick, n_draw_z, n_draw_c });
        mismatches.* += 1;
    } else {
        for (0..n_draw_c) |i| {
            const c = draw_c[i];
            const z = draw_z[i];
            if (c.x != z.x or c.y != z.y or c.image != z.image) {
                if (mismatches.* < 40) std.debug.print("{s} tick {d} draw[{d}]: zig=(x{d},y{d},im{d}) != c=(x{d},y{d},im{d})\n", .{ name, tick, i, z.x, z.y, z.image, c.x, c.y, c.image });
                mismatches.* += 1;
            }
        }
    }
    if (n_sfx_c != n_sfx_z) {
        std.debug.print("{s} tick {d}: sfx count zig={d} != c={d}\n", .{ name, tick, n_sfx_z, n_sfx_c });
        mismatches.* += 1;
    } else {
        for (0..n_sfx_c) |i| {
            if (sfx_c[i] != sfx_z[i]) {
                if (mismatches.* < 40) std.debug.print("{s} tick {d} sfx[{d}]: zig={d} != c={d}\n", .{ name, tick, i, sfx_z[i], sfx_c[i] });
                mismatches.* += 1;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Scenario replay.
// ---------------------------------------------------------------------------

const Scenario = struct { name: []const u8, seed: c_uint, ticks: usize };

fn runScenario(scn: *const Scenario, mismatches: *usize) void {
    setupWorld();

    // --- Init: C side ---
    fireworks.rabbits = std.mem.zeroes([fireworks.num_rabbits]fireworks.Rabbit);
    fireworks.stars = std.mem.zeroes([fireworks.num_stars]fireworks.Star);
    rnd_mod.seed(scn.seed);
    c_fireworks_init_ref();
    const after_init_c = snapshot();

    // --- Init: Zig side, from the same zeroed starting point and seed ---
    fireworks.rabbits = std.mem.zeroes([fireworks.num_rabbits]fireworks.Rabbit);
    fireworks.stars = std.mem.zeroes([fireworks.num_stars]fireworks.Star);
    rnd_mod.seed(scn.seed);
    fireworks.init();
    compareArray(fireworks.Rabbit, scn.name, 0, "rabbits (init)", &after_init_c.rabbits, &fireworks.rabbits, mismatches);
    compareArray(fireworks.Star, scn.name, 0, "stars (init)", &after_init_c.stars, &fireworks.stars, mismatches);
    if (after_init_c.rnd_calls != rnd_mod.rnd_call_count) {
        std.debug.print("{s} init: rnd_call_count zig={d} != c={d}\n", .{ scn.name, rnd_mod.rnd_call_count, after_init_c.rnd_calls });
        mismatches.* += 1;
    }
    // Carry forward the Zig side's post-init state (matches after_init_c if
    // the comparison above passed) as the starting point for the per-tick
    // replay below.

    for (0..scn.ticks) |tick| {
        const start = snapshot();
        const tick_seed = scn.seed +% @as(c_uint, @intCast(tick)) *% 7919;

        // --- C side ---
        rnd_mod.seed(tick_seed);
        n_draw_c = 0;
        n_sfx_c = 0;
        c_fireworks_step_ref();
        const c_result = snapshot();

        // --- Zig side: same seed, same starting world ---
        restore(&start);
        rnd_mod.seed(tick_seed);
        fireworks.drawResetZ();
        fireworks.sfxResetZ();
        fireworks.step();
        n_draw_z = 0;
        for (0..fireworks.drawCountZ()) |i| {
            const d = fireworks.draw_trace_z[i];
            if (n_draw_z < draw_z.len) draw_z[n_draw_z] = .{ .x = d.x, .y = d.y, .image = d.image };
            n_draw_z += 1;
        }
        n_sfx_z = 0;
        for (0..fireworks.sfxCountZ()) |i| {
            if (n_sfx_z < sfx_z.len) sfx_z[n_sfx_z] = fireworks.sfx_trace_z[i];
            n_sfx_z += 1;
        }

        compareArray(fireworks.Rabbit, scn.name, tick, "rabbits", &c_result.rabbits, &fireworks.rabbits, mismatches);
        compareArray(fireworks.Star, scn.name, tick, "stars", &c_result.stars, &fireworks.stars, mismatches);
        compareArray(world.Object, scn.name, tick, "objects", &c_result.objects, &objects_raw, mismatches);
        if (c_result.rnd_calls != rnd_mod.rnd_call_count) {
            std.debug.print("{s} tick {d}: rnd_call_count zig={d} != c={d}\n", .{ scn.name, tick, rnd_mod.rnd_call_count, c_result.rnd_calls });
            mismatches.* += 1;
        }
        compareTraces(scn.name, tick, mismatches);
    }
}

// Seeds picked (empirically, while implementing) so each scenario's rnd()
// stream exercises a distinct code path: a short run proving the 900-call
// star init + rabbit-0 init sequence and the early spawn thresholds; longer
// runs long enough to see at least one full timer-expiry detonation (the
// 144-rnd-call, right-to-left explosion order) and at least one rabbit
// escaping off-screen without detonating.
const scenarios = [_]Scenario{
    .{ .name = "short_init", .seed = 1, .ticks = 20 },
    .{ .name = "detonation_a", .seed = 0xC0FFEE, .ticks = 400 },
    .{ .name = "detonation_b", .seed = 0x5A5A5A, .ticks = 400 },
    .{ .name = "many_rabbits", .seed = 0xBEEF01, .ticks = 800 },
};

test "fireworks.zig matches the extracted C reference across the seed scenarios" {
    var mismatches: usize = 0;
    var total_ticks: usize = 0;
    for (&scenarios) |*scn| {
        runScenario(scn, &mismatches);
        total_ticks += scn.ticks;
    }
    if (total_ticks < 1000) {
        std.debug.print("fireworks difftest replayed only {d} ticks\n", .{total_ticks});
        mismatches += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}
