// Port of fireworks.c's fireworks() screensaver mode — TASK-017.02:
// bouncing/exploding rocket-rabbits and a scrolling parallax starfield,
// entirely separate from player[] (rabbits[]/stars[] are this module's own
// state, never touching core/steer.zig's/core/collision.zig's player
// storage).
//
// Scope decision: stars[] drops old_x/old_y/back[2] — fireworks.c's own
// double-buffer dirty-pixel restore cache (the previous-frame position and
// the saved framebuffer pixel a star is about to overwrite, one slot per
// draw page). Those three fields are write-only presentation outputs with
// zero effect on future simulation ticks (core purity, TASK-011.08).
// rabbits[]/stars[] are otherwise a verbatim field-for-field port.
//
// State: this module owns rabbits[]/stars[] as exported globals (the
// core/flies.zig pattern — an independent array, not a borrow of
// core/steer.zig's world storage, since fireworks mode never touches
// player[]). objects_raw[]/ban_map_raw[] are reached as extern mirrors of
// core/steer.zig's exports, exactly like core/objects.zig does, since the
// rabbit explosion spawns into the shared 200-slot particle pool and this
// module calls the already-ported update_objects() once per frame, matching
// fireworks.c's own call site (fireworks.c:209).
//
// rnd()/add_object()/update_objects() are extern fns (no @import between
// ported modules, per the playbook). player_anims[] is core/steer.zig's
// export, reached the same unchecked-flat-pointer way core/collision.zig's
// playerImage() and core/objects.zig's animFrameAt() already do.
//
// Draw/audio boundary: fireworks() draws each live rabbit via add_pob()
// (fireworks.c:203) and plays a *fixed*-frequency SFX_DEATH cue on
// detonation (fireworks.c:191) — `dj_play_sfx(SFX_DEATH, SFX_DEATH_FREQ, 64,
// 0, 0, -1)`, with no rnd(2000) jitter, unlike the player-death cue's
// `SFX_DEATH_FREQ + rnd(2000) - 1000` (core/collision.zig:246). Core carries
// no renderer or audio implementation (TASK-011.08), so both become
// plain-data trace records — the same shape core/objects.zig:106-122's
// draw_trace_z established. core/abi.zig's jnb_fireworks_step drains these
// (TASK-017.03, backlog/decisions/decision-001) into the same jnb_event
// ring jnb_step's own draw/sfx traces already use.
//
// Arithmetic: every fixed-point operation routes through core/fixed16.zig's
// wrapping helpers, matching every other ported module.
const fixed16 = @import("fixed16.zig");

const Fixed = fixed16.Fixed;

pub const num_rabbits = 20;
pub const num_stars = 300;

const jnb_width: c_int = 400;
const jnb_height: c_int = 256;

/// A structurally-reduced player_t (fireworks.c:36-41): the same
/// position/anim fields main.c's player_t carries, minus every
/// input/collision/score field, plus `used` and `timer`.
pub const Rabbit = extern struct {
    used: c_int = 0,
    direction: c_int = 0,
    colour: c_int = 0,
    x: Fixed = 0,
    y: Fixed = 0,
    x_add: Fixed = 0,
    y_add: Fixed = 0,
    timer: c_int = 0,
    anim: c_int = 0,
    frame: c_int = 0,
    frame_tick: c_int = 0,
    image: c_int = 0,
};

/// fireworks.c:43-48, minus old_x/old_y/back[2] (see module header).
pub const Star = extern struct {
    x: Fixed = 0,
    y: Fixed = 0,
    col: c_int = 0,
};

pub export var rabbits: [num_rabbits]Rabbit = [_]Rabbit{.{}} ** num_rabbits;
pub export var stars: [num_stars]Star = [_]Star{.{}} ** num_stars;

// ---------------------------------------------------------------------------
// Cross-module externs (playbook: no @import between ported modules).
// ---------------------------------------------------------------------------
extern fn rnd(max: c_ushort) c_ushort;
extern fn add_object(type_: c_int, x: c_int, y: c_int, x_add: c_int, y_add: c_int, anim: c_int, frame: c_int) void;
extern fn update_objects() void;

const obj_fur: c_int = 5; // OBJ_FUR
const obj_flesh: c_int = 6; // OBJ_FLESH
const sfx_death: c_int = 2; // SFX_DEATH
const sfx_death_freq: c_int = 20000; // SFX_DEATH_FREQ

/// player_anim_t twin (core/steer.zig's PlayerAnim) — duplicated locally
/// per the playbook's no-@import rule, not reached through steer.zig's pub
/// type. Each row holds 4 frames; every anim fireworks.c uses (2 and 3)
/// fits well inside that, so no out-of-row read hazard here.
const AnimFrame = extern struct { image: c_int = 0, ticks: c_int = 0 };
const PlayerAnimRow = extern struct {
    num_frames: c_int = 0,
    restart_frame: c_int = 0,
    frame: [4]AnimFrame = [_]AnimFrame{.{}} ** 4,
};
extern var player_anims: [7]PlayerAnimRow;

inline fn animFrame(anim: c_int, frame: c_int) AnimFrame {
    const anims = @as([*]const PlayerAnimRow, @ptrCast(&player_anims));
    return anims[@as(u32, @bitCast(anim))].frame[@as(u32, @bitCast(frame))];
}
inline fn animNumFrames(anim: c_int) c_int {
    const anims = @as([*]const PlayerAnimRow, @ptrCast(&player_anims));
    return anims[@as(u32, @bitCast(anim))].num_frames;
}
inline fn animRestartFrame(anim: c_int) c_int {
    const anims = @as([*]const PlayerAnimRow, @ptrCast(&player_anims));
    return anims[@as(u32, @bitCast(anim))].restart_frame;
}

/// player_anims[anim].frame[frame].image + colour*18 + direction*9 —
/// fireworks-specific image formula (fireworks.c:96,153,170,201): normal
/// gameplay's player[] packs only one colour per rabbit_gobs page-set and
/// uses `+ direction*9` alone (core/collision.zig's playerImage); fireworks
/// packs all 4 colours out of one rabbit_gobs, so colour selects a whole
/// 18-frame block first.
inline fn rabbitImage(anim: c_int, frame: c_int, colour: c_int, direction: c_int) c_int {
    return animFrame(anim, frame).image +% (colour *% 18) +% (direction *% 9);
}

// ---------------------------------------------------------------------------
// Draw/sfx trace (core purity, TASK-011.08 — see module header).
// ---------------------------------------------------------------------------

pub const DrawRecord = struct { x: c_int, y: c_int, image: c_int };
const max_draws_per_tick = num_rabbits;
pub var draw_trace_z: [max_draws_per_tick]DrawRecord = undefined;
var draw_n_z: usize = 0;

fn drawDrop(x: c_int, y: c_int, image: c_int) void {
    if (draw_n_z < draw_trace_z.len) draw_trace_z[draw_n_z] = .{ .x = x, .y = y, .image = image };
    draw_n_z += 1;
}
/// The draws actually stored (silently truncated past max_draws_per_tick,
/// like core/objects.zig's draw_trace_z).
pub fn drawCountZ() usize {
    return @min(draw_n_z, draw_trace_z.len);
}
pub fn drawResetZ() void {
    draw_n_z = 0;
}

/// id*100000+freq, matching core/steer.zig's/core/collision.zig's sfx_trace_z
/// packing so a future consumer treats every ported module's sfx trace the
/// same way.
const sfx_trace_len = num_rabbits;
pub var sfx_trace_z: [sfx_trace_len]c_int = .{0} ** sfx_trace_len;
var sfx_n_z: usize = 0;

fn sfxDrop(id: c_int, freq: c_int) void {
    if (sfx_n_z < sfx_trace_z.len) sfx_trace_z[sfx_n_z] = id *% 100000 +% freq;
    sfx_n_z += 1;
}
pub fn sfxCountZ() usize {
    return @min(sfx_n_z, sfx_trace_z.len);
}
pub fn sfxResetZ() void {
    sfx_n_z = 0;
}

// ---------------------------------------------------------------------------
// Init (fireworks.c:79-108).
// ---------------------------------------------------------------------------

/// Spawns/respawns one rabbit into `slot` (fireworks.c:82-96 for the
/// initial rabbit, fireworks.c:139-153 for a respawn — an identical
/// sequence, deduped here since the C's duplication is pure repetition,
/// not a behavioral difference). Consumes exactly 5 rnd() draws in this
/// order: colour, x, x_add, y_add, timer.
fn spawnRabbit(slot: usize) void {
    const r = &rabbits[slot];
    r.used = 1;
    r.colour = @intCast(rnd(4));
    r.x = fixed16.shl16Raw(150 +% @as(c_int, @intCast(rnd(100))));
    r.y = fixed16.shl16Raw(256);
    // (int) rnd(65535) << 1 - 65536 — a shift, not rnd()*2 % max; folded
    // here as a wrapping multiply-by-2, numerically identical for every
    // value rnd(65535) can produce (0..65534).
    r.x_add = fixed16.sub(fixed16.mul(@as(c_int, @intCast(rnd(65535))), 2), 65536);
    r.direction = if (r.x_add > 0) 0 else 1;
    r.y_add = fixed16.add(-262144, fixed16.mul(@as(c_int, @intCast(rnd(16384))), 5));
    r.timer = 30 +% @as(c_int, @intCast(rnd(150)));
    r.anim = 2;
    r.frame = 0;
    r.frame_tick = 0;
    r.image = rabbitImage(r.anim, r.frame, r.colour, r.direction);
}

/// One star (fireworks.c:99-107). 3 rnd() draws in this order: x, y, col.
fn spawnStar(slot: usize) void {
    const s = &stars[slot];
    const sx: c_int = @intCast(rnd(jnb_width));
    const sy: c_int = @intCast(rnd(jnb_height));
    s.col = 30 -% @as(c_int, @intCast(rnd(7)));
    s.x = fixed16.shl16Raw(sx);
    s.y = fixed16.shl16Raw(sy);
}

/// fireworks.c:79-108: reset all 20 rabbits to unused, seed rabbit 0, then
/// seed all 300 stars, in that exact order (rabbit-0's 5 draws happen
/// before any star's 3).
pub fn init() void {
    for (&rabbits) |*r| r.used = 0;
    spawnRabbit(0);
    for (0..num_stars) |i| spawnStar(i);
}

// ---------------------------------------------------------------------------
// Per-frame step (fireworks.c:117-244, minus every presentation call —
// dj_mix/intr_sysupdate/draw_begin/draw_end/flippage/wait_vrt/
// redraw_pob_backgrounds and the star background-cache loops all drop out
// as pure rendering with zero effect on rabbits[]/stars[]/objects[] state).
// ---------------------------------------------------------------------------

/// fireworks.c:122-130: pure vertical parallax scroll, toroidal wrap. Zero
/// rnd() draws.
fn advanceStars() void {
    for (&stars) |*s| {
        s.y = fixed16.sub(s.y, fixed16.mul(31 -% s.col, 16384));
        if (fixed16.shr16(s.y) < 0) s.y = fixed16.add(s.y, fixed16.shl16Raw(jnb_height));
        if (fixed16.shr16(s.y) >= jnb_height) s.y = fixed16.sub(s.y, fixed16.shl16Raw(jnb_height));
    }
}

/// fireworks.c:132-157. C's short-circuit `&&`/`||` chain means exactly one
/// rnd(10000) draw when the live-rabbit count is 0..3, and zero draws
/// otherwise — never all four branches' calls. Reproduced as a switch so
/// only the matching arm's rnd() call ever executes.
fn maybeSpawnRabbit() void {
    var live: c_int = 0;
    for (rabbits) |r| {
        if (r.used == 1) live +%= 1;
    }
    const should_spawn = switch (live) {
        0 => rnd(10000) < 200,
        1 => rnd(10000) < 150,
        2 => rnd(10000) < 100,
        3 => rnd(10000) < 50,
        else => false,
    };
    if (!should_spawn) return;
    for (0..num_rabbits) |i| {
        if (rabbits[i].used == 0) {
            spawnRabbit(i);
            break;
        }
    }
}

/// (pos >> 16) + 6 + rnd(5) — one gore coordinate around the detonating
/// rabbit (fireworks.c:182 etc.), same shape as core/collision.zig's
/// goreCoord.
inline fn goreCoord(pos: c_int) c_int {
    return fixed16.add(fixed16.add(fixed16.shr16(pos), 6), @intCast(rnd(5)));
}
/// (rnd(65535) - 32768) * 3 — the velocity jitter added on top of the
/// rabbit's own x_add/y_add (the burst inherits the rocket's momentum),
/// same shape as core/collision.zig's goreVelocity.
inline fn goreVelocity() c_int {
    return fixed16.mul(fixed16.sub(@as(c_int, @intCast(rnd(65535))), 32768), 3);
}

/// One OBJ_FUR spray piece from a detonating rabbit (fireworks.c:181-182):
/// like core/collision.zig's furGore, but the velocity jitter is added on
/// top of the rabbit's own x_add/y_add instead of starting from zero.
/// Right-to-left argument evaluation (core/collision.zig:269-277's
/// precedent): y_add's rnd(65535) first, then x_add's, then y's rnd(5),
/// then x's rnd(5).
fn rabbitFurGore(x: c_int, y: c_int, x_add_base: c_int, y_add_base: c_int, frame: c_int) void {
    const y_add = fixed16.add(y_add_base, goreVelocity());
    const x_add = fixed16.add(x_add_base, goreVelocity());
    const cy = goreCoord(y);
    const cx = goreCoord(x);
    add_object(obj_fur, cx, cy, x_add, y_add, 0, frame);
}
/// One OBJ_FLESH spray piece (fireworks.c:183-190 — the same expression
/// with a fixed frame of 76/77/78/79).
fn rabbitFleshGore(x: c_int, y: c_int, x_add_base: c_int, y_add_base: c_int, frame: c_int) void {
    const y_add = fixed16.add(y_add_base, goreVelocity());
    const x_add = fixed16.add(x_add_base, goreVelocity());
    const cy = goreCoord(y);
    const cx = goreCoord(x);
    add_object(obj_flesh, cx, cy, x_add, y_add, 0, frame);
}

/// fireworks.c:163-205: gravity, apex anim switch, position integration,
/// off-screen despawn (no explosion), timer-expiry detonation (36-particle
/// burst + a fixed-frequency SFX_DEATH cue, no rnd() jitter), and the
/// animation-frame walk for every still-live rabbit.
fn updateRabbits() void {
    for (&rabbits) |*r| {
        if (r.used != 1) continue;
        r.y_add = fixed16.add(r.y_add, 2048);
        if (r.y_add > 36864 and r.anim != 3) {
            r.anim = 3;
            r.frame = 0;
            r.frame_tick = 0;
            r.image = rabbitImage(r.anim, r.frame, r.colour, r.direction);
        }
        r.x = fixed16.add(r.x, r.x_add);
        r.y = fixed16.add(r.y, r.y_add);
        if (fixed16.shr16(r.x) < 16 or fixed16.shr16(r.x) > jnb_width or fixed16.shr16(r.y) > jnb_height) {
            r.used = 0;
            continue;
        }
        r.timer -%= 1;
        if (r.timer <= 0) {
            r.used = 0;
            // Raw fixed-point x/y, not pre-shifted: rabbitFurGore/
            // rabbitFleshGore's goreCoord() does the >>16 itself (matching
            // core/collision.zig's furGore/fleshGore, which take player[]'s
            // raw fixed-point x/y the same way) -- shifting here too would
            // shift twice.
            const xb = r.x_add;
            const yb = r.y_add;
            const colour = r.colour;
            for (0..6) |_| rabbitFurGore(r.x, r.y, xb, yb, 44 +% colour *% 8);
            for (0..6) |_| rabbitFleshGore(r.x, r.y, xb, yb, 76);
            for (0..6) |_| rabbitFleshGore(r.x, r.y, xb, yb, 77);
            for (0..8) |_| rabbitFleshGore(r.x, r.y, xb, yb, 78);
            for (0..10) |_| rabbitFleshGore(r.x, r.y, xb, yb, 79);
            sfxDrop(sfx_death, sfx_death_freq);
            continue;
        }
        r.frame_tick +%= 1;
        if (r.frame_tick >= animFrame(r.anim, r.frame).ticks) {
            r.frame +%= 1;
            if (r.frame >= animNumFrames(r.anim)) r.frame = animRestartFrame(r.anim);
            r.frame_tick = 0;
        }
        r.image = rabbitImage(r.anim, r.frame, r.colour, r.direction);
        if (r.used == 1) drawDrop(fixed16.shr16(r.x), fixed16.shr16(r.y), r.image);
    }
}

/// One simulation tick (fireworks.c:117-244's non-presentation remainder):
/// stars, spawn check, rabbit physics/detonation, then the shared particle
/// pool's own per-tick update — matching fireworks.c's own call order.
pub fn step() void {
    advanceStars();
    maybeSpawnRabbit();
    updateRabbits();
    update_objects();
}
