// Port of main.c's steer_players() (main.c:2069) and position_player()
// (main.c:2363) — TASK-011.02: horizontal acceleration per tile type, the
// jump/gravity/jetpack/pogostick velocity rules, and the x/y integration
// with wall, ceiling, spring, and water contact handling, all in 16.16
// fixed-point (docs/porting-playbook.md's no-float rule).
//
// The C reaches this through game_loop() once per tick, after cpu_move()
// and update_player_actions() have written player[].action_* (TASK-011.05
// and the input layer own those; this module treats them as inputs, same as
// the C does — the prologue's two calls are the only lines of the function
// this port does not reproduce).
//
// State: this module owns the backing storage for everything steer_players
// touches — player[]/objects[]/ban_map (in core/world.zig's canonical
// layout, the playbook's globals-ownership rule naming this subsystem's
// module as their home on the Zig side), the anim tables, and the
// physics-mode globals (pogostick/bunnies_in_space/jetpack/
// blood_is_thicker_than_water, main.c:240) — as exported globals under the
// original C names. The difftest (core/steer_difftest.zig) points the C
// reference side at this same storage, so both sides mutate one world; the
// later ABI/game-loop layers reach it the same way. rnd()/rnd_call_count
// come from core/rnd.zig through the playbook's extern-fn cross-module
// pattern (no @import between ported modules).
//
// Audio: the C's dj_play_sfx(SFX_x, (unsigned short)(SFX_x_FREQ + rnd(2000)
// - cut), ...) call sites are exactly where steer_players' checksummed
// rnd() draws happen (docs/checksum-format.md), so sfxAt() below evaluates
// the same frequency expression — draw included — and drops the result.
// The body is a no-op placeholder (core purity, TASK-011.08); the
// TASK-011.07 pump replaces it with event-stream emission.
//
// Arithmetic: every fixed-point operation routes through core/fixed16.zig's
// wrapping helpers so Zig's trapping arithmetic and @intCast range checks
// can never diverge from the C's silent two's-complement wraparound. Array
// indexing by raw anim/frame fields uses @bitCast (never @intCast) to keep
// the C's unchecked-memory semantics, including reads that run off the end
// of player_anims[] when a frame counter sits at the C's 0x7fff animation
// sentinel (the table is followed by other globals in main.c's data
// segment; the harness pads it the same way, so identical inputs give
// identical reads).
const std = @import("std");
const fixed16 = @import("fixed16.zig");
const world = @import("world.zig");

const Fixed = fixed16.Fixed;
const Player = world.Player;
const Object = world.Object;
const max_players = world.max_players;
const num_objects = world.num_objects;

pub const ban_void: u32 = 0; // BAN_VOID
pub const ban_solid: u32 = 1; // BAN_SOLID
pub const ban_water: u32 = 2; // BAN_WATER
pub const ban_ice: u32 = 3; // BAN_ICE
pub const ban_spring: u32 = 4; // BAN_SPRING

const obj_spring: c_int = 0; // OBJ_SPRING
const obj_splash: c_int = 1; // OBJ_SPLASH
const obj_smoke: c_int = 2; // OBJ_SMOKE
const obj_anim_splash: c_int = 1; // OBJ_ANIM_SPLASH
const obj_anim_smoke: c_int = 2; // OBJ_ANIM_SMOKE

/// player_anim_t (globals.pre:218) — mirrored struct twin for the anim
/// tables steer_players reads.
pub const PlayerAnim = extern struct {
    num_frames: c_int = 0,
    restart_frame: c_int = 0,
    frame: [4]AnimFrame = [_]AnimFrame{.{}} ** 4,
};

/// One row of main.c's object_anims (main.c:96-103): 10 frames.
pub const ObjectAnim = extern struct {
    num_frames: c_int = 0,
    restart_frame: c_int = 0,
    frame: [10]AnimFrame = [_]AnimFrame{.{}} ** 10,
};

pub const AnimFrame = extern struct {
    image: c_int = 0,
    ticks: c_int = 0,
};

// ---------------------------------------------------------------------------
// World storage. player[]/objects[]/ban_map use core/world.zig's
// canonical layout, but their *definition* lives in the one shared C
// harness the differential binaries link (core/c_ref/sim_harness.c): this
// module reaches them through extern mirrors named *_raw, and the
// extracted C references' `#define player player_raw` (and friends) bind
// to that very same memory. One world, exactly one definition per link --
// two storages is precisely the vacuity trap the coverage probe below
// catches. The weak exports further down back the mirrors when steer.zig
// is its own test root (standalone `zig build test`); a difftest or the
// game-loop link supplies the real storage instead and the weak symbols
// lose. The game-loop layer will fill the same storage from init_level().
//
// The defaults mirror a cold-start main.c: zeroed player[]/objects[] and
// the built-in grid of main.c:74 (what read_level()/levelmap.txt overwrite
// once the level-loading port owns it).
// ---------------------------------------------------------------------------

extern var player_raw: [max_players]Player;
extern var objects_raw: [num_objects]Object;
extern var ban_map_raw: [world.ban_rows][world.ban_cols]u32;
const player_ptr: *[max_players]Player = @constCast(&player_raw);
const objects_ptr: *[num_objects]Object = @constCast(&objects_raw);
const ban_map_ptr: *[world.ban_rows][world.ban_cols]u32 = @constCast(&ban_map_raw);

/// The anim tables (player_anim_t from globals.pre:218 / main.c's
/// object_anims). Owned and exported here — like the mode flags below and
/// rnd_call_count in core/rnd.zig: the harness configures them through
/// these same variables, so there is one storage by construction. (The C
/// reference binds same-named externs to these exports at link time.)
pub export var player_anims: [7]PlayerAnim = [_]PlayerAnim{.{}} ** 7;
pub export var object_anims: [8]ObjectAnim = [_]ObjectAnim{.{}} ** 8;

/// Loads player_anims/object_anims from main.c's own static initializers
/// (main.c:3105-3112's player_anim_data[]/main.c:96-171's object_anims) —
/// the literal table main.c populates once at program start, before any
/// level or player is set up. No core module ports that literal load as its
/// own task (it lives in main() before init_level(), out of TASK-011.*'s
/// per-subsystem scope), so this is the one shared place that transcribes
/// both tables, called by every real entry point that needs a functioning
/// world (core/abi.zig's jnb_world_init, core/game_loop_difftest.zig's Tier-B
/// corpus replay) instead of each duplicating its own copy.
///
/// NOTE: core/collision_difftest.zig's own loadObjectAnims has transcription
/// errors relative to main.c (smoke's num_frames is 5, not 6; the two pink
/// butterfly rows are their own distinct 32-37/38-43 image ranges, not a
/// copy of yellow's 26-31; flesh_trace is nf=4 with images 76-79, not nf=8
/// with 32-39) that its own tests don't happen to exercise (it never reads a
/// pink butterfly's or flesh_trace's frame images) — this transcribes the
/// table fresh from main.c rather than copying that one.
pub fn loadDefaultAnims() void {
    // main.c:3105's player_anim_data[]: num_frames, restart_frame, then 4
    // (image, ticks) pairs per row, flat.
    const player_data = [_]c_int{
        1, 0, 0, 0x7fff, 0, 0, 0, 0, 0, 0,
        4, 0, 0, 4, 1, 4, 2, 4, 3, 4,
        1, 0, 4, 0x7fff, 0, 0, 0, 0, 0, 0,
        4, 2, 5, 8, 6, 10, 7, 3, 6, 3,
        1, 0, 6, 0x7fff, 0, 0, 0, 0, 0, 0,
        2, 1, 5, 8, 4, 0x7fff, 0, 0, 0, 0,
        1, 0, 8, 5, 0, 0, 0, 0, 0, 0,
    };
    for (0..7) |a| {
        player_anims[a].num_frames = player_data[a * 10];
        player_anims[a].restart_frame = player_data[a * 10 + 1];
        for (0..4) |f| {
            player_anims[a].frame[f].image = player_data[a * 10 + f * 2 + 2];
            player_anims[a].frame[f].ticks = player_data[a * 10 + f * 2 + 3];
        }
    }

    // main.c:96-171's object_anims[8] static initializer, transcribed row
    // for row: spring, splash, smoke, yel_butfly_right, yel_butfly_left,
    // pink_butfly_right, pink_butfly_left, flesh_trace.
    const ObjRow = struct { nf: c_int, rf: c_int, frames: [10][2]c_int };
    const object_rows = [_]ObjRow{
        .{ .nf = 6, .rf = 0, .frames = .{ .{ 0, 3 }, .{ 1, 3 }, .{ 2, 3 }, .{ 3, 3 }, .{ 4, 3 }, .{ 5, 3 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } } },
        .{ .nf = 9, .rf = 0, .frames = .{ .{ 6, 2 }, .{ 7, 2 }, .{ 8, 2 }, .{ 9, 2 }, .{ 10, 2 }, .{ 11, 2 }, .{ 12, 2 }, .{ 13, 2 }, .{ 14, 2 }, .{ 0, 0 } } },
        .{ .nf = 5, .rf = 0, .frames = .{ .{ 15, 3 }, .{ 16, 3 }, .{ 16, 3 }, .{ 17, 3 }, .{ 18, 3 }, .{ 19, 3 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } } },
        .{ .nf = 10, .rf = 0, .frames = .{ .{ 20, 2 }, .{ 21, 2 }, .{ 22, 2 }, .{ 23, 2 }, .{ 24, 2 }, .{ 25, 2 }, .{ 24, 2 }, .{ 23, 2 }, .{ 22, 2 }, .{ 21, 2 } } },
        .{ .nf = 10, .rf = 0, .frames = .{ .{ 26, 2 }, .{ 27, 2 }, .{ 28, 2 }, .{ 29, 2 }, .{ 30, 2 }, .{ 31, 2 }, .{ 30, 2 }, .{ 29, 2 }, .{ 28, 2 }, .{ 27, 2 } } },
        .{ .nf = 10, .rf = 0, .frames = .{ .{ 32, 2 }, .{ 33, 2 }, .{ 34, 2 }, .{ 35, 2 }, .{ 36, 2 }, .{ 37, 2 }, .{ 36, 2 }, .{ 35, 2 }, .{ 34, 2 }, .{ 33, 2 } } },
        .{ .nf = 10, .rf = 0, .frames = .{ .{ 38, 2 }, .{ 39, 2 }, .{ 40, 2 }, .{ 41, 2 }, .{ 42, 2 }, .{ 43, 2 }, .{ 42, 2 }, .{ 41, 2 }, .{ 40, 2 }, .{ 39, 2 } } },
        .{ .nf = 4, .rf = 0, .frames = .{ .{ 76, 4 }, .{ 77, 4 }, .{ 78, 4 }, .{ 79, 4 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } } },
    };
    for (object_rows, 0..) |row, i| {
        object_anims[i].num_frames = row.nf;
        object_anims[i].restart_frame = row.rf;
        for (row.frames, 0..) |fr, f| {
            object_anims[i].frame[f].image = fr[0];
            object_anims[i].frame[f].ticks = fr[1];
        }
    }
}

// TASK-022/TASK-023: this module used to carry its own weak-linked
// player_raw/objects_raw/ban_map_raw fallback here, gated on
// `@import("root") == @This()` so it only fired when steer.zig was
// genuinely the compilation's own root (a difftest or the game-loop link
// supplies the shared harness storage instead). That gate is false under
// `zig build test` (`b.addTest` wraps the root module in Zig's own
// synthesized test-runner shim, so `@import("root")` never equals
// steer.zig's own module there), which left steer.zig's own standalone
// Tier-A test unable to link at all. The fallback now lives in
// core/unit_steer_globals.zig, compiled as a separate object and linked
// explicitly into steer.zig's own Tier-A test only (see
// core/build.zig's addTestStep) -- see that file's header comment for the
// full account, including why a weak `@export` couldn't just be fixed to
// fire unconditionally instead (Zig 0.16.0 compiles a weak `@export` of a
// file-scope `var` as a non-external/private symbol, invisible outside
// the object file).

/// pogostick/bunnies_in_space/jetpack/blood_is_thicker_than_water
/// (main.c:240) — keyboard-cheat mode flags steer_players() reads. Owned
/// and exported here (like rnd_call_count in core/rnd.zig: subsystem state
/// with no C-side twin to share — the harness sets them through these same
/// exports, so there is one storage by construction).
pub export var pogostick: c_int = 0;
pub export var bunnies_in_space: c_int = 0;
pub export var jetpack: c_int = 0;
pub export var blood_is_thicker_than_water: c_int = 0;

/// GET_BAN_MAP_XY (main.c:94) — ban_map[(y) >> 4][(x) >> 4] read unguarded,
/// exactly like the C macro: steer_players clamps s2 but never s1, so
/// out-of-grid probes happen and read neighbouring memory. The flat
/// pointer keeps that byte-for-byte as long as the surrounding storage
/// matches (the difftest shares one grid, so it matches by construction).
inline fn banTile(x: Fixed, y: Fixed) u32 {
    // row/col can be negative (an out-of-grid probe) — the C reads that as
    // a negative pointer offset from ban_map's base, landing on whatever
    // memory sits just before it. Truncating a negative row/col through a
    // u32 bitcast first (as an isize->usize widening would if done at the
    // wrong width) turns a small backward offset into a many-gigabyte
    // forward one and reads unmapped memory instead — so the offset is
    // computed and wrapped at full pointer width, matching two's-complement
    // pointer arithmetic exactly.
    const row: isize = @intCast(y >> 4);
    const col: isize = @intCast(x >> 4);
    const flat: isize = row *% @as(isize, world.ban_cols) +% col;
    const base = @intFromPtr(@as([*]const u32, @ptrCast(ban_map_ptr)));
    const addr = base +% @as(usize, @bitCast(flat *% @as(isize, @sizeOf(u32))));
    return @as(*const u32, @ptrFromInt(addr)).*;
}

/// GET_BAN_MAP_IN_WATER (main.c:2066) — void above the feet at +7 px and
/// water at +8 px across either half of the 16-px-wide sprite.
inline fn banMapInWater(s1: Fixed, s2: Fixed) bool {
    return (banTile(s1, s2 + 7) == ban_void or banTile(s1 + 15, s2 + 7) == ban_void) and
        (banTile(s1, s2 + 8) == ban_water or banTile(s1 + 15, s2 + 8) == ban_water);
}

/// player_anims[anim].frame[frame].image + direction * 9 — the image
/// recompute repeated ~15 times across steer_players(). Unchecked
/// (bit-punned) indexing: the C reads straight past the 4-frame row when
/// frame sits at the 0x7fff idle sentinel, landing on whatever follows the
/// table, and the port reproduces that read from the same shared table
/// rather than clamping and disagreeing about it.
inline fn playerImage(p: *const Player) c_int {
    const anims = @as([*]const PlayerAnim, @ptrCast(&player_anims));
    const anim: usize = @as(u32, @bitCast(p.anim));
    const fr: usize = @as(u32, @bitCast(p.frame));
    return anims[anim].frame[fr].image +% (p.direction *% 9);
}

inline fn playerAnimTicks(anim: c_int, frame: c_int) c_int {
    const anims = @as([*]const PlayerAnim, @ptrCast(&player_anims));
    return anims[@as(u32, @bitCast(anim))].frame[@as(u32, @bitCast(frame))].ticks;
}

inline fn playerAnimFrames(anim: c_int) c_int {
    const anims = @as([*]const PlayerAnim, @ptrCast(&player_anims));
    return anims[@as(u32, @bitCast(anim))].num_frames;
}

inline fn playerAnimRestart(anim: c_int) c_int {
    const anims = @as([*]const PlayerAnim, @ptrCast(&player_anims));
    return anims[@as(u32, @bitCast(anim))].restart_frame;
}

/// player_action_left (main.c:1771) — static in the C; file-private here
/// too, reached only through steer_players().
fn playerActionLeft(p: *Player) void {
    const s1: Fixed = fixed16.shr16(p.x);
    const s2: Fixed = fixed16.shr16(p.y);
    const below_left = banTile(s1, s2 + 16);
    const below = banTile(s1 + 8, s2 + 16);
    const below_right = banTile(s1 + 15, s2 + 16);

    if (below == ban_ice) {
        if (p.x_add > 0) {
            p.x_add = fixed16.sub(p.x_add, 1024);
        } else {
            p.x_add = fixed16.sub(p.x_add, 768);
        }
    } else if ((below_left != ban_solid and below_right == ban_ice) or (below_left == ban_ice and below_right != ban_solid)) {
        if (p.x_add > 0) {
            p.x_add = fixed16.sub(p.x_add, 1024);
        } else {
            p.x_add = fixed16.sub(p.x_add, 768);
        }
    } else {
        if (p.x_add > 0) {
            p.x_add = fixed16.sub(p.x_add, 16384);
            if (p.x_add > -98304 and p.in_water == 0 and below == ban_solid) smokePuff(p);
        } else {
            p.x_add = fixed16.sub(p.x_add, 12288);
        }
    }
    if (p.x_add < -98304) p.x_add = -98304;
    p.direction = 1;
    if (p.anim == 0) {
        p.anim = 1;
        p.frame = 0;
        p.frame_tick = 0;
        p.image = playerImage(p);
    }
}

/// player_action_right (main.c:1812).
fn playerActionRight(p: *Player) void {
    const s1: Fixed = fixed16.shr16(p.x);
    const s2: Fixed = fixed16.shr16(p.y);
    const below_left = banTile(s1, s2 + 16);
    const below = banTile(s1 + 8, s2 + 16);
    const below_right = banTile(s1 + 15, s2 + 16);

    if (below == ban_ice) {
        if (p.x_add < 0) {
            p.x_add = fixed16.add(p.x_add, 1024);
        } else {
            p.x_add = fixed16.add(p.x_add, 768);
        }
    } else if ((below_left != ban_solid and below_right == ban_ice) or (below_left == ban_ice and below_right != ban_solid)) {
        if (p.x_add > 0) {
            p.x_add = fixed16.add(p.x_add, 1024);
        } else {
            p.x_add = fixed16.add(p.x_add, 768);
        }
    } else {
        if (p.x_add < 0) {
            p.x_add = fixed16.add(p.x_add, 16384);
            if (p.x_add < 98304 and p.in_water == 0 and below == ban_solid) smokePuff(p);
        } else {
            p.x_add = fixed16.add(p.x_add, 12288);
        }
    }
    if (p.x_add > 98304) p.x_add = 98304;
    p.direction = 0;
    if (p.anim == 0) {
        p.anim = 1;
        p.frame = 0;
        p.frame_tick = 0;
        p.image = playerImage(p);
    }
}

/// The add_object(OBJ_SMOKE, ...) call shared by both action handlers
/// (main.c:1800, main.c:1841). C's per-call argument evaluation order is
/// unspecified, and the reference binary evaluates right to left (verified
/// against the corpus — see the gore-spray draws in collision.zig's
/// furGore/fleshGore), so the three rnd() draws (8192, 5, 9) happen in the
/// reverse of the source's left-to-right reading order: y_add's rnd(8192)
/// first, then y's rnd(5), then x's rnd(9).
fn smokePuff(p: *const Player) void {
    const y_add = fixed16.sub(-16384, rnd(8192));
    const y = fixed16.add(fixed16.add(fixed16.shr16(p.y), 13), rnd(5));
    const x = fixed16.add(fixed16.add(fixed16.shr16(p.x), 2), rnd(9));
    add_object(obj_smoke, x, y, 0, y_add, obj_anim_smoke, 0);
}

/// steer_players (main.c:2069) minus the cpu_move()/update_player_actions()
/// prologue (TASK-011.05 owns the AI; the input layer owns action_*),
/// exported under the original C name. s1/s2 are the C's scratch pixel
/// coordinates, reused across blocks exactly as the C reuses them — the
/// jetpack branch's GET_BAN_MAP_IN_WATER reads whatever s1/s2 the last
/// block left behind, and that stale read is observable state (it clears
/// in_water or it doesn't), so the carry-over is reproduced bit-for-bug.
pub export fn steer_players() void {
    var s1: Fixed = 0;
    var s2: Fixed = 0;


    for (player_ptr, 0..) |*p, c1| {
        if (p.enabled != 1) continue;

        if (p.dead_flag == 0) {
            if (p.action_left != 0 and p.action_right != 0) {
                if (p.direction == 0) {
                    if (p.action_right != 0) playerActionRight(p);
                } else {
                    if (p.action_left != 0) playerActionLeft(p);
                }
            } else if (p.action_left != 0) {
                playerActionLeft(p);
            } else if (p.action_right != 0) {
                playerActionRight(p);
            } else if (p.action_left == 0 and p.action_right == 0) {
                s1 = fixed16.shr16(p.x);
                s2 = fixed16.shr16(p.y);
                const below_left = banTile(s1, s2 + 16);
                const below = banTile(s1 + 8, s2 + 16);
                const below_right = banTile(s1 + 15, s2 + 16);
                if (below == ban_solid or below == ban_spring or
                    ((below_left == ban_solid or below_left == ban_spring) and below_right != ban_ice) or
                    (below_left != ban_ice and (below_right == ban_solid or below_right == ban_spring)))
                {
                    if (p.x_add < 0) {
                        p.x_add = fixed16.add(p.x_add, 16384);
                        if (p.x_add > 0) p.x_add = 0;
                    } else {
                        p.x_add = fixed16.sub(p.x_add, 16384);
                        if (p.x_add < 0) p.x_add = 0;
                    }
                    if (p.x_add != 0 and banTile(s1 + 8, s2 + 16) == ban_solid) {
                        // Reference binary evaluates add_object()'s arguments
                        // right to left; draw order is y_add, y, x (see
                        // smokePuff above).
                        const y_add = fixed16.sub(-16384, rnd(8192));
                        const y = fixed16.add(fixed16.add(fixed16.shr16(p.y), 13), rnd(5));
                        const x = fixed16.add(fixed16.add(fixed16.shr16(p.x), 2), rnd(9));
                        add_object(obj_smoke, x, y, 0, y_add, obj_anim_smoke, 0);
                    }
                }
                if (p.anim == 1) {
                    p.anim = 0;
                    p.frame = 0;
                    p.frame_tick = 0;
                    p.image = playerImage(p);
                }
            }
            if (jetpack == 0) {
                // no jetpack
                if (pogostick == 1 or (p.jump_ready == 1 and p.action_up != 0)) {
                    s1 = fixed16.shr16(p.x);
                    s2 = fixed16.shr16(p.y);
                    if (s2 < -16) s2 = -16;
                    // jump
                    if (banTile(s1, s2 + 16) == ban_solid or banTile(s1, s2 + 16) == ban_ice or
                        banTile(s1 + 15, s2 + 16) == ban_solid or banTile(s1 + 15, s2 + 16) == ban_ice)
                    {
                        p.y_add = -280000;
                        p.anim = 2;
                        p.frame = 0;
                        p.frame_tick = 0;
                        p.image = playerImage(p);
                        p.jump_ready = 0;
                        p.jump_abort = 1;
                        if (pogostick == 0) {
                            sfxAt(sfx_jump, sfx_jump_freq, 1000);
                        } else {
                            sfxAt(sfx_spring, sfx_spring_freq, 1000);
                        }
                    }
                    // jump out of water
                    if (banMapInWater(s1, s2)) {
                        p.y_add = -196608;
                        p.in_water = 0;
                        p.anim = 2;
                        p.frame = 0;
                        p.frame_tick = 0;
                        p.image = playerImage(p);
                        p.jump_ready = 0;
                        p.jump_abort = 1;
                        if (pogostick == 0) {
                            sfxAt(sfx_jump, sfx_jump_freq, 1000);
                        } else {
                            sfxAt(sfx_spring, sfx_spring_freq, 1000);
                        }
                    }
                }
                // fall down by gravity
                if (pogostick == 0 and p.action_up == 0) {
                    p.jump_ready = 1;
                    if (p.in_water == 0 and p.y_add < 0 and p.jump_abort == 1) {
                        if (bunnies_in_space == 0) {
                            // normal gravity
                            p.y_add = fixed16.add(p.y_add, 32768);
                        } else {
                            // light gravity
                            p.y_add = fixed16.add(p.y_add, 16384);
                        }
                        if (p.y_add > 0) p.y_add = 0;
                    }
                }
            } else {
                // with jetpack
                if (p.action_up != 0) {
                    p.y_add = fixed16.sub(p.y_add, 16384);
                    if (p.y_add < -400000) p.y_add = -400000;
                    if (banMapInWater(s1, s2)) p.in_water = 0;
                    if (rnd(100) < 50) {
                        // Draw order y_add, y, x — see smokePuff above.
                        const y_add = fixed16.add(16384, rnd(8192));
                        const y = fixed16.add(fixed16.add(fixed16.shr16(p.y), 10), rnd(5));
                        const x = fixed16.add(fixed16.add(fixed16.shr16(p.x), 6), rnd(5));
                        add_object(obj_smoke, x, y, 0, y_add, obj_anim_smoke, 0);
                    }
                }
            }

            p.x = fixed16.add(p.x, p.x_add);
            if (fixed16.shr16(p.x) < 0) {
                p.x = 0;
                p.x_add = 0;
            }
            if (fixed16.add(fixed16.shr16(p.x), 15) > 351) {
                p.x = fixed16.shl16Raw(336);
                p.x_add = 0;
            }
            {
                if (p.y > 0) {
                    s2 = fixed16.shr16(p.y);
                } else {
                    // check top line only
                    s2 = 0;
                }

                s1 = fixed16.shr16(p.x);
                if (banTile(s1, s2) == ban_solid or banTile(s1, s2) == ban_ice or banTile(s1, s2) == ban_spring or
                    banTile(s1, s2 + 15) == ban_solid or banTile(s1, s2 + 15) == ban_ice or banTile(s1, s2 + 15) == ban_spring)
                {
                    p.x = fixed16.wrapDownToTile(s1);
                    p.x_add = 0;
                }

                s1 = fixed16.shr16(p.x);
                if (banTile(s1 + 15, s2) == ban_solid or banTile(s1 + 15, s2) == ban_ice or banTile(s1 + 15, s2) == ban_spring or
                    banTile(s1 + 15, s2 + 15) == ban_solid or banTile(s1 + 15, s2 + 15) == ban_ice or banTile(s1 + 15, s2 + 15) == ban_spring)
                {
                    p.x = fixed16.wrapDownToTilePrev(s1);
                    p.x_add = 0;
                }
            }

            p.y = fixed16.add(p.y, p.y_add);

            s1 = fixed16.shr16(p.x);
            s2 = fixed16.shr16(p.y);
            if (banTile(s1 + 8, s2 + 15) == ban_spring or
                (banTile(s1, s2 + 15) == ban_spring and banTile(s1 + 15, s2 + 15) != ban_solid) or
                (banTile(s1, s2 + 15) != ban_solid and banTile(s1 + 15, s2 + 15) == ban_spring))
            {
                p.y = fixed16.snapFixedToTile(p.y);
                p.y_add = -400000;
                p.anim = 2;
                p.frame = 0;
                p.frame_tick = 0;
                p.image = playerImage(p);
                p.jump_ready = 0;
                p.jump_abort = 0;
                springAnimation(s1, s2);
                sfxAt(sfx_spring, sfx_spring_freq, 1000);
            }
            s1 = fixed16.shr16(p.x);
            s2 = fixed16.shr16(p.y);
            if (s2 < 0) s2 = 0;
            if (banTile(s1, s2) == ban_solid or banTile(s1, s2) == ban_ice or banTile(s1, s2) == ban_spring or
                banTile(s1 + 15, s2) == ban_solid or banTile(s1 + 15, s2) == ban_ice or banTile(s1 + 15, s2) == ban_spring)
            {
                p.y = fixed16.wrapDownToTile(s2);
                p.y_add = 0;
                p.anim = 0;
                p.frame = 0;
                p.frame_tick = 0;
                p.image = playerImage(p);
            }
            s1 = fixed16.shr16(p.x);
            s2 = fixed16.shr16(p.y);
            if (s2 < 0) s2 = 0;
            if (banTile(s1 + 8, s2 + 8) == ban_water) {
                if (p.in_water == 0) {
                    // falling into water
                    p.in_water = 1;
                    p.anim = 4;
                    p.frame = 0;
                    p.frame_tick = 0;
                    p.image = playerImage(p);
                    if (p.y_add >= 32768) {
                        const splash_x = fixed16.add(fixed16.shr16(p.x), 8);
                        const splash_y = fixed16.add(fixed16.shr16(p.y) & 0xfff0, 15);
                        add_object(obj_splash, splash_x, splash_y, 0, 0, obj_anim_splash, 0);
                        if (blood_is_thicker_than_water == 0) {
                            sfxAt(sfx_splash, sfx_splash_freq, 1000);
                        } else {
                            sfxAt(sfx_splash, sfx_splash_freq, 5000);
                        }
                    }
                }
                // slowly move up to water surface
                p.y_add = fixed16.sub(p.y_add, 1536);
                if (p.y_add < 0 and p.anim != 5) {
                    p.anim = 5;
                    p.frame = 0;
                    p.frame_tick = 0;
                    p.image = playerImage(p);
                }
                if (p.y_add < -65536) p.y_add = -65536;
                if (p.y_add > 65535) p.y_add = 65535;
                if (banTile(s1, s2 + 15) == ban_solid or banTile(s1, s2 + 15) == ban_ice or
                    banTile(s1 + 15, s2 + 15) == ban_solid or banTile(s1 + 15, s2 + 15) == ban_ice)
                {
                    p.y = fixed16.wrapDownToTilePrev(s2);
                    p.y_add = 0;
                }
            } else if (banTile(s1, s2 + 15) == ban_solid or banTile(s1, s2 + 15) == ban_ice or banTile(s1, s2 + 15) == ban_spring or
                banTile(s1 + 15, s2 + 15) == ban_solid or banTile(s1 + 15, s2 + 15) == ban_ice or banTile(s1 + 15, s2 + 15) == ban_spring)
            {
                p.in_water = 0;
                p.y = fixed16.wrapDownToTilePrev(s2);
                p.y_add = 0;
                if (p.anim != 0 and p.anim != 1) {
                    p.anim = 0;
                    p.frame = 0;
                    p.frame_tick = 0;
                    p.image = playerImage(p);
                }
            } else {
                if (p.in_water == 0) {
                    if (bunnies_in_space == 0) {
                        p.y_add = fixed16.add(p.y_add, 12288);
                    } else {
                        p.y_add = fixed16.add(p.y_add, 6144);
                    }
                    if (p.y_add > 327680) p.y_add = 327680;
                } else {
                    // (y & 0xffff0000) + 0x10000: next whole pixel up with
                    // the fraction dropped — a snap fixed16 has no named
                    // helper for, so it wraps through u32 explicitly.
                    p.y = @bitCast((@as(u32, @bitCast(p.y)) & 0xffff_0000) +% 0x1_0000);
                    p.y_add = 0;
                }
                p.in_water = 0;
            }
            if (p.y_add > 36864 and p.anim != 3 and p.in_water == 0) {
                p.anim = 3;
                p.frame = 0;
                p.frame_tick = 0;
                p.image = playerImage(p);
            }
        }

        p.frame_tick +%= 1;
        if (p.frame_tick >= playerAnimTicks(p.anim, p.frame)) {
            p.frame +%= 1;
            if (p.frame >= playerAnimFrames(p.anim)) {
                if (p.anim != 6) {
                    p.frame = playerAnimRestart(p.anim);
                } else {
                    position_player(@intCast(c1));
                }
            }
            p.frame_tick = 0;
        }
        p.image = playerImage(p);
    }
}

/// The spring-contact objects[] scan (main.c:2232-2259): restart the
/// OBJ_SPRING object sitting in the tile the player's foot landed on —
/// middle foot probe first, then either outer probe. The C compares the
/// object's 16-px tile (x >> 20) against the pixel probe's tile (s >> 4).
fn springAnimation(s1: Fixed, s2: Fixed) void {
    for (objects_ptr) |*o| {
        if (o.used == 1 and o.type == obj_spring) {
            if (banTile(s1 + 8, s2 + 15) == ban_spring) {
                if (fixed16.shr20(o.x) == (s1 + 8) >> 4 and fixed16.shr20(o.y) == (s2 + 15) >> 4) {
                    resetSpringObject(o);
                    return;
                }
            } else {
                if (banTile(s1, s2 + 15) == ban_spring) {
                    if (fixed16.shr20(o.x) == s1 >> 4 and fixed16.shr20(o.y) == (s2 + 15) >> 4) {
                        resetSpringObject(o);
                        return;
                    }
                } else if (banTile(s1 + 15, s2 + 15) == ban_spring) {
                    if (fixed16.shr20(o.x) == (s1 + 15) >> 4 and fixed16.shr20(o.y) == (s2 + 15) >> 4) {
                        resetSpringObject(o);
                        return;
                    }
                }
            }
        }
    }
}

fn resetSpringObject(o: *Object) void {
    o.frame = 0;
    o.ticks = objectAnimRow(o.anim)[0].ticks;
    o.image = objectAnimRow(o.anim)[0].image;
}

/// position_player (main.c:2363): pick a random void tile with solid or ice
/// under it, far enough from the other enabled players, and drop the player
/// there. Exported under the C name; steer_players' anim-6 reset path calls
/// it directly.
pub export fn position_player(player_num: c_int) void {
    const pn: usize = @intCast(player_num);
    while (true) {
        var s1: c_int = 0;
        var s2: c_int = 0;
        while (true) {
            s1 = @intCast(rnd(22));
            s2 = @intCast(rnd(16));
            if (banMapCell(s2, s1) == ban_void and
                (banMapCell(s2 + 1, s1) == ban_solid or banMapCell(s2 + 1, s1) == ban_ice)) break;
        }
        var c1: usize = 0;
        while (c1 < max_players) : (c1 += 1) {
            if (c1 != pn and player_ptr[c1].enabled == 1) {
                // abs() over the C's int differences: wrapping subtract,
                // magnitude taken without @abs's INT_MIN trap.
                if (cAbs((s1 << 4) -% fixed16.shr16(player_ptr[c1].x)) < 32 and
                    cAbs((s2 << 4) -% fixed16.shr16(player_ptr[c1].y)) < 32) break;
            }
        }
        if (c1 == max_players) {
            const p = &player_ptr[pn];
            // (long) s << 20 truncated back into the int field: a wrapping
            // 32-bit shift, like fixed16's shl helpers.
            p.x = @bitCast(@as(u32, @bitCast(s1)) << 20);
            p.y = @bitCast(@as(u32, @bitCast(s2)) << 20);
            p.x_add = 0;
            p.y_add = 0;
            p.direction = 0;
            p.jump_ready = 1;
            p.in_water = 0;
            p.anim = 0;
            p.frame = 0;
            p.frame_tick = 0;
            p.image = player_anims[0].frame[0].image;

            // main.c:2393-2400 — dead_flag resets under is_server (the
            // serverSendAlive() inside the same C block additionally needs
            // is_net, which nothing headless sets).
            if (is_server != 0) {
                p.dead_flag = 0;
            }
            break;
        }
    }
}

/// is_server (main.c:261) — gates position_player's dead_flag reset
/// (main.c:2393-2400; serverSendAlive() inside the same C block also needs
/// is_net, which nothing headless sets). Bound at link time like the world
/// arrays: the net layer (TASK-011.05+/game-loop) owns the real storage
/// where the -net startup flag is parsed; the difftest and the unit-test
/// link publish it = 1 (the headless server path).
extern var is_server: c_int;

/// The C's abs(int). Inputs are tile/pixel differences well inside the
/// range, so the 64-bit round trip never changes the value; it only keeps
/// Zig from trapping at INT_MIN.
inline fn cAbs(v: c_int) u31 {
    const w: i64 = v;
    return @intCast(if (w < 0) -w else w);
}

/// add_object (main.c:2408) — the first-free-slot allocator steer_players()
/// reaches through for splash/smoke spawns. TASK-011.04 moved its canonical
/// home to core/objects.zig (the particles own the allocator); this module
/// reaches it through the playbook's cross-module extern-fn pattern, exactly
/// like rnd(), so there is one definition. The difftest/abi/game-loop builds
/// resolve it against objects.zig's export; the standalone steer.zig unit-test
/// compilation links the same export (see core/build.zig's addTestStep).
extern fn add_object(type_: c_int, x: c_int, y: c_int, x_add: c_int, y_add: c_int, anim: c_int, frame: c_int) void;

/// Raw pointer into object_anims (main.c indexes the rows directly). The
/// gore frames (44..79) deliberately run past the 10-frame rows: main.c
/// reads the same out-of-row memory (the 40 ints past an OBJ_FUR frame land
/// in the next rows of the same table), and the harness pads the table the
/// same way, so identical inputs give identical reads.
inline fn objectAnimFrame(anim: c_int, frame: c_int) *const AnimFrame {
    const flat = @as([*]const AnimFrame, @ptrCast(&object_anims));
    const stride: u32 = @divExact(@sizeOf(ObjectAnim), @sizeOf(AnimFrame));
    const idx: u64 = @as(u64, @as(u32, @bitCast(anim)) *% stride +% @as(u32, @bitCast(frame)));
    return &flat[idx];
}

inline fn objectAnimRow(anim: c_int) *const [10]AnimFrame {
    const rows = @as([*]const ObjectAnim, @ptrCast(&object_anims));
    return &rows[@as(u32, @bitCast(anim))].frame;
}

/// rnd (core/rnd.zig) — reached through the cross-module extern-fn pattern
/// (playbook: no @import between ported modules). Linked, never @imported:
/// the difftest/abi/game-loop compilations resolve it against core/rnd.zig's
/// exported rnd (sharing libc's rand() state and rnd_call_count with the C
/// reference); this module's standalone unit-test compilation (it is in
/// build.zig's unit_test_files list) has nothing to resolve it against, so
/// the Tier-A tests below drive the one function that reaches it —
/// position_player — through the C reference instead (rnd_c_ref is linked
/// into every unit-test module, see core/build.zig).
extern fn rnd(max: c_ushort) c_ushort;

const sfx_jump: c_int = 1; // SFX_JUMP
const sfx_spring: c_int = 2; // SFX_SPRING
const sfx_splash: c_int = 3; // SFX_SPLASH
const sfx_jump_freq: c_int = 15000; // SFX_JUMP_FREQ
const sfx_spring_freq: c_int = 15000; // SFX_SPRING_FREQ
const sfx_splash_freq: c_int = 12000; // SFX_SPLASH_FREQ

/// The dj_play_sfx() call sites: evaluate the C's frequency argument
/// expression — (unsigned short)(SFX_x_FREQ + rnd(2000) - cut), including
/// its checksummed rnd(2000) draw — then drop everything. The TASK-011.07
/// pump turns the dropped value into an sfx event; the legacy binary keeps
/// main.c's own dj_play_sfx.
inline fn sfxAt(id: c_int, freq_base: c_int, cut: c_int) void {
    const freq: c_ushort = @truncate(@as(c_uint, @bitCast(fixed16.add(freq_base, rnd(2000)) -% cut)));
    sfxDrop(id, freq);
}

// SFX event streams, recorded per-tick by both sides (the C side via the
// harness's dj_play_sfx export, the Zig side via sfxDrop) so the differential
// compares the *evaluated* frequency arguments, not just the rnd() draws
// that feed them. id*100000+freq keeps the pair in one slot.
pub const sfx_trace_len = 512;
pub var sfx_trace_c: [sfx_trace_len]c_int = .{0} ** sfx_trace_len;
pub var sfx_trace_z: [sfx_trace_len]c_int = .{0} ** sfx_trace_len;
var sfx_n_c: usize = 0;
var sfx_n_z: usize = 0;
pub fn sfxRecordC(id: c_int, freq: c_int) void {
    if (sfx_n_c < sfx_trace_c.len) sfx_trace_c[sfx_n_c] = id * 100000 + freq;
    sfx_n_c += 1;
}
pub fn sfxReset() void {
    sfx_n_c = 0;
    sfx_n_z = 0;
}
pub fn sfxCountC() usize {
    return sfx_n_c;
}
pub fn sfxCountZ() usize {
    return sfx_n_z;
}
fn sfxDrop(id: c_int, freq: c_ushort) void {
    if (sfx_n_z < sfx_trace_z.len) sfx_trace_z[sfx_n_z] = id * 100000 + @as(c_int, freq);
    sfx_n_z += 1;
}

/// Cross-module entry points for other ported modules' dj_play_sfx drops
/// (core/collision.zig's kill sfx): the same trace, reached without an
/// @import between ported modules (playbook rule).
pub export fn sfxRecordZ(id: c_int, freq: c_int) void {
    sfxDrop(id, @truncate(@as(c_uint, @bitCast(freq))));
}
pub export fn sfxResetZ() void {
    sfxReset();
}

inline fn banMapCell(row: c_int, col: c_int) u32 {
    const flat = @as([*]const u32, @ptrCast(ban_map_ptr));
    const idx: i64 = @as(i64, @as(i32, @bitCast(row))) * @as(i64, world.ban_cols) +% @as(i64, @as(i32, @bitCast(col)));
    return flat[@as(u64, @bitCast(idx))];
}

// ---------------------------------------------------------------------------
// Tier-A unit tests.
//
// They run against the module's own exported storage — the same variables
// the difftest drives — so no test-owned arena is needed (and none would
// be possible: the storage is single-instance by design).
// ---------------------------------------------------------------------------

/// Sets up the fixed floor/water/ice fixture the two tests below assume.
/// These tests run standalone against this module's own storage (Tier-A),
/// but game_loop_difftest.zig also pulls this module in transitively into
/// a shared Tier-B binary where a linked C reference's strong ban_map_raw
/// definition can win instead of this module's own default and other
/// tests can leave it holding whatever a corpus trace last loaded — so
/// each test seeds the exact grid it needs rather than trusting ambient
/// state.
fn setTestBanMap() void {
    for (ban_map_ptr) |*row| row.* = [_]u32{ban_void} ** world.ban_cols;
    ban_map_ptr[16] = [_]u32{ban_solid} ** world.ban_cols; // force-filled floor
    ban_map_ptr[14] = [_]u32{ban_water} ** world.ban_cols; // water row
    ban_map_ptr[9][12] = ban_ice; // ice tile
}

test "world storage mirrors the canonical layout and cold-start state" {
    setTestBanMap();
    try std.testing.expectEqual(@as(usize, 4), player_ptr.len);
    try std.testing.expectEqual(@as(usize, 200), objects_ptr.len);
    try std.testing.expectEqual(@as(u32, 1), ban_map_ptr[16][0]); // force-filled floor
    try std.testing.expectEqual(@as(u32, 2), ban_map_ptr[14][0]); // water row
    try std.testing.expectEqual(@as(u32, 3), ban_map_ptr[9][12]); // ice tile
}

test "position_player lands on a void tile with ground beneath" {
    setTestBanMap();
    player_anims = @import("std").mem.zeroes([7]PlayerAnim);
    player_anims[0] = .{ .num_frames = 1, .restart_frame = 0, .frame = .{ .{ .image = 0, .ticks = 0x7fff }, .{}, .{}, .{} } };
    for (player_ptr) |*p| p.* = .{};
    player_ptr[0].enabled = 1;

    position_player(0);
    const px: usize = @intCast(@as(i32, @bitCast(player_ptr[0].x)) >> 20);
    const py: usize = @intCast(@as(i32, @bitCast(player_ptr[0].y)) >> 20);
    try std.testing.expectEqual(@as(u32, ban_void), ban_map_ptr[py][px]);
    try std.testing.expect(ban_map_ptr[py + 1][px] == ban_solid or ban_map_ptr[py + 1][px] == ban_ice);
    try std.testing.expectEqual(@as(c_int, 0), player_ptr[0].x_add);
    try std.testing.expectEqual(@as(c_int, 1), player_ptr[0].jump_ready);
}

test "steer_players leaves a disabled player untouched" {
    for (player_ptr) |*p| p.* = .{};
    player_ptr[0].enabled = 0;
    player_ptr[0].x = 12345;

    steer_players();
    try std.testing.expectEqual(@as(c_int, 12345), player_ptr[0].x);
}
