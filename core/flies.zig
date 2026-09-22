// Port of main.c's update_flies (main.c:1025) — TASK-011.06, the 20-slot
// fly swarm that flees (or chases, under lord_of_the_flies) the closest
// player. get_closest_player_to_point (main.c:1007), the helper the swarm
// queries once for its center and once per fly, is ported here too; it is
// static in scope everywhere the swarm is reached.
//
// Unlike player/object positions, flies[] holds plain pixel coordinates —
// the spawn in main_loop scatters them with rnd(101) offsets and the
// update clamps to the 0..351/0..239 pixel playfield — so this module is
// integer-pixel arithmetic throughout and needs no fixed16 helper.
//
// rnd() and the audio boundary follow the playbook's cross-module rules:
// rnd() is reached as an extern fn (rnd.zig owns the definition; no
// @import between ported modules). dj_set_sfx_channel_volume has no home in
// core — the simulation carries no audio implementation
// (docs/porting-playbook.md "Core purity", TASK-011.08) — so the one audio
// call inside the swarm's tick is recorded into a plain data slot instead
// (volume_trace_channel/volume_trace_volume below); core/game_loop.zig's
// step() drains it into the `.sfx_volume` event stream once per tick.
const std = @import("std");

/// seed() (core/rnd.zig) — rnd.zig owns the definition; reached as an
/// extern fn per the no-@import rule, same as rnd() above. TASK-023: these
/// tests used to seed via libc's srand(), which has no effect on rnd.zig's
/// own pure-Zig generator (TASK-021 dropped rnd.zig's libc dependency) --
/// the tests never actually seeded the generator they exercise.
extern fn seedZ(seed_val: c_uint) void;

pub const num_flies = 20; // NUM_FLIES
pub const max_player = 0x7fff; // get_closest_player_to_point's initial *dist

const ban_rows = 17;
const ban_cols = 22;
const ban_void: c_uint = 0; // BAN_VOID

/// The flies[] array (main.c:220) — x/old_x etc. are all plain `int`s of
// pixel coordinates; the back/back_defined draw bookkeeping stays with the
// renderer and never enters the simulation's state.
pub const Fly = extern struct {
    x: c_int = 0,
    y: c_int = 0,
    old_x: c_int = 0,
    old_y: c_int = 0,
    old_draw_x: c_int = 0,
    old_draw_y: c_int = 0,
};

/// Backing storage for flies[] (playbook globals-ownership rule: defined
/// exactly once, here; callers mirror it with an extern var — the way
/// rnd.zig's rnd_call_count comment prescribes).
pub export var flies: [num_flies]Fly = [_]Fly{.{}} ** num_flies;

/// lord_of_the_flies (main.c:240) — the "seilfehtfodrol" cheat flips it and
/// the swarm flees the closest player instead of chasing; the cheat handler
/// lives outside this module until its own port, so the storage stays
/// here with the swarm that reads it.
pub export var lord_of_the_flies: c_int = 0;

/// player_t (globals.pre:207) — struct twin; the swarm only reads x, y and
/// enabled, but the layout mirrors the C so the extern mirror of player[]
/// below addresses the same bytes whatever module comes to own it.
pub const Player = extern struct {
    action_left: c_int = 0,
    action_up: c_int = 0,
    action_right: c_int = 0,
    enabled: c_int = 0,
    dead_flag: c_int = 0,
    bumps: c_int = 0,
    bumped: [4]c_int = [_]c_int{0} ** 4,
    x: c_int = 0,
    y: c_int = 0,
    x_add: c_int = 0,
    y_add: c_int = 0,
    direction: c_int = 0,
    jump_ready: c_int = 0,
    jump_abort: c_int = 0,
    in_water: c_int = 0,
    anim: c_int = 0,
    frame: c_int = 0,
    frame_tick: c_int = 0,
    image: c_int = 0,
};

/// player[JNB_MAX_PLAYERS] (main.c:54) — extern mirror, resolved through
/// the `player_ptr` alias below. The module that owns the backing storage
/// (TASK-011.02's steer port, per the globals rule) defines the real array
/// once; the tests at the bottom of this file export a scratch definition
/// under the same symbol.
extern var player_raw: [4]Player;
const player_ptr: *[4]Player = @constCast(&player_raw);

/// ban_map[17][22] (main.c:74) — extern mirror, resolved through the
/// `ban_map_ptr` alias below; main.c owns the backing array and the
/// checksum fold reads its cells as `unsigned int`, so the cell type here
/// matches the C. Same scratch-definition arrangement as player_raw above.
extern var ban_map_raw: [ban_rows][ban_cols]c_uint;
const ban_map_ptr: *[ban_rows][ban_cols]c_uint = @constCast(&ban_map_raw);

/// rnd(max) (main.c:3562) — rnd.zig owns the definition; reached as an
/// extern fn per the no-@import rule.
extern fn rnd(max: u16) u16;

/// dj_set_sfx_channel_volume — audio boundary, see the header comment. The
/// fly swarm sound lives on channel 4 (main.c:1382's caller context).
pub var volume_trace_channel: c_int = -1;
pub var volume_trace_volume: i8 = 0;
var volume_trace_set: bool = false;

fn setSfxVolume(channel: c_int, volume: i8) void {
    volume_trace_channel = channel;
    volume_trace_volume = volume;
    volume_trace_set = true;
}
/// Whether update_flies() set the swarm's channel volume this tick
/// (main.c only does this once, when update_count == 1).
pub fn volumeWasSetZ() bool {
    return volume_trace_set;
}
pub fn volumeResetZ() void {
    volume_trace_set = false;
}

/// GET_BAN_MAP_XY(x,y) (main.c:94) — the 16-pixel tile under a pixel
/// coordinate. C's `>>` on the signed coordinates floors toward -1, which
/// Zig's signed `>>` matches, and the negative results index outside the
/// array exactly like the C would; the callers keep fly coordinates in
/// 0..351/0..255, where the index stays inside [0,16]x[0,21] (fly y can
/// reach 255 while the map is 16 playable rows plus the force-solid row —
/// still in range).
fn banMapXy(x: c_int, y: c_int) c_uint {
    return ban_map_ptr[@intCast(y >> 4)][@intCast(x >> 4)];
}

/// Integer stand-in for `(int)sqrt(dx*dx + dy*dy)` (main.c:1015, one of the
/// playbook's two FP call sites). The arguments are non-negative pixel
/// deltas — at most 359, so each square fits an int and the sum an unsigned
/// — and IEEE-754 sqrt is correctly rounded, so for every reachable
/// argument the double sqrt lands within a half-ulp of the exact root:
/// strictly below k+1 for a perfect k², strictly above k for anything
/// between consecutive squares. Truncation therefore equals floor(sqrt(n))
/// exactly, which is what this integer loop returns. (The `(int)` cast is
/// itself truncation toward zero, and the root is non-negative, so no
/// rounding-mode difference can show up either.)
fn isqrtFloor(n: u32) u32 {
    var r: u32 = 0;
    while ((r + 1) * (r + 1) <= n) r += 1;
    return r;
}

/// get_closest_player_to_point (main.c:1007) — Euclidean pixel distance to
/// each enabled player, +8 toward their center like the fly target point.
/// `closest_player` keeps the caller's value when no player is enabled
/// (the C only writes through on a strict improvement over the 0x7fff
/// initial distance), and ties resolve to the lowest index, first enabled
/// win.
pub export fn get_closest_player_to_point(x: c_int, y: c_int, dist: *c_int, closest_player: *c_int) void {
    var c1: c_int = 0;
    var cur_dist: c_int = 0;

    dist.* = max_player;
    while (c1 < 4) : (c1 += 1) {
        if (player_ptr[@intCast(c1)].enabled == 1) {
            const dx: u32 = @bitCast(x - ((player_ptr[@intCast(c1)].x >> 16) + 8));
            const dy: u32 = @bitCast(y - ((player_ptr[@intCast(c1)].y >> 16) + 8));
            cur_dist = @bitCast(@as(u32, isqrtFloor(dx *% dx +% dy *% dy)));
            if (cur_dist < dist.*) {
                closest_player.* = c1;
                dist.* = cur_dist;
            }
        }
    }
}

/// update_flies (main.c:1025) — one tick of the swarm: fold the swarm
/// center, re-aim the channel-4 fly sound at the swarm center when
/// update_count == 1, then nudge each fly one pixel toward the center
/// (toward a player within 30px when lord_of_the_flies is on, away from
/// them when off) plus a rnd(3)-1 jitter, refusing any step that would
/// leave the 16..351/0..239 playfield or a non-BAN_VOID tile. The C's
/// `s1 += flies[c1].x` sums and `/= NUM_FLIES` are plain int ops; 20
/// in-range fly positions never overflow them, and the division truncates
/// toward zero, which Zig's `/` on signed ints matches.
pub export fn update_flies(update_count: c_int) void {
    var c1: c_int = 0;
    var closest_player: c_int = 0;
    var dist: c_int = 0;
    var s1: c_int = 0;
    var s2: c_int = 0;

    // get center of fly swarm
    s1 = 0;
    s2 = 0;
    while (c1 < num_flies) : (c1 += 1) {
        s1 +%= flies[@intCast(c1)].x;
        s2 +%= flies[@intCast(c1)].y;
    }
    s1 = @divTrunc(s1, @as(c_int, num_flies));
    s2 = @divTrunc(s2, @as(c_int, num_flies));

    if (update_count == 1) {
        // get closest player to fly swarm
        get_closest_player_to_point(s1, s2, &dist, &closest_player);
        // update fly swarm sound
        // C precedence: `32 - dist / 3` divides before subtracting; the
        // clamp to zero rides on the same temporary the C reuses.
        var s3: c_int = 32 -% @divTrunc(dist, 3);
        if (s3 < 0) s3 = 0;
        setSfxVolume(4, @truncate(s3));
    }

    c1 = 0;
    while (c1 < num_flies) : (c1 += 1) {
        const fly = &flies[@intCast(c1)];
        // get closest player to fly
        get_closest_player_to_point(fly.x, fly.y, &dist, &closest_player);
        fly.old_x = fly.x;
        fly.old_y = fly.y;

        var s3: c_int = 0;
        if ((s1 -% fly.x) > 30)
            s3 += 1
        else if ((s1 -% fly.x) < -30)
            s3 -= 1;
        if (dist < 30) {
            if (((player_ptr[@intCast(closest_player)].x >> 16) +% 8) > fly.x) {
                if (lord_of_the_flies == 0)
                    s3 -= 1
                else
                    s3 += 1;
            } else {
                if (lord_of_the_flies == 0)
                    s3 += 1
                else
                    s3 -= 1;
            }
        }
        // The C's `rnd(3) - 1 + s3`: rnd's u16 widens into the int math.
        var s4: c_int = @as(c_int, @intCast(rnd(3))) -% 1 +% s3;
        if ((fly.x +% s4) < 16)
            s4 = 0;
        if ((fly.x +% s4) > 351)
            s4 = 0;
        if (banMapXy(fly.x +% s4, fly.y) != ban_void)
            s4 = 0;
        fly.x +%= s4;

        s3 = 0;
        if ((s2 -% fly.y) > 30)
            s3 += 1
        else if ((s2 -% fly.y) < -30)
            s3 -= 1;
        if (dist < 30) {
            if (((player_ptr[@intCast(closest_player)].y >> 16) +% 8) > fly.y) {
                if (lord_of_the_flies == 0)
                    s3 -= 1
                else
                    s3 += 1;
            } else {
                if (lord_of_the_flies == 0)
                    s3 += 1
                else
                    s3 -= 1;
            }
        }
        s4 = @as(c_int, @intCast(rnd(3))) -% 1 +% s3;
        if ((fly.y +% s4) < 0)
            s4 = 0;
        if ((fly.y +% s4) > 239)
            s4 = 0;
        if (banMapXy(fly.x, fly.y +% s4) != ban_void)
            s4 = 0;
        fly.y +%= s4;
    }
}

/// The flies_enabled spawn block from main_loop (main.c:1581-1595): scatter
/// the swarm around a seeded center, re-drawing any fly that lands on a
/// non-BAN_VOID tile. The dj_play_sfx(SFX_FLY, ...) that follows the spawn
/// is pure audio and stays outside the core. Exported as spawn_flies — this
/// block has no C function of its own to keep the name of; the name records
/// what it is, the call sites in main.c are in its comment.
pub export fn spawn_flies() void {
    var c1: c_int = 0;
    const s1 = @as(c_int, @intCast(rnd(250))) +% 50;
    const s2 = @as(c_int, @intCast(rnd(150))) +% 50;

    while (c1 < num_flies) : (c1 += 1) {
        while (true) {
            flies[@intCast(c1)].x = s1 +% @as(c_int, @intCast(rnd(101))) -% 50;
            flies[@intCast(c1)].y = s2 +% @as(c_int, @intCast(rnd(101))) -% 50;
            if (banMapXy(flies[@intCast(c1)].x, flies[@intCast(c1)].y) == ban_void)
                break;
        }
    }
}

/// Tier-A fixture for the extern ban_map mirror below (main.c:74's default
/// grid). Unit tests define their own storage for the extern mirrors via
/// the `export var` aliases at the bottom of this file — the real link
/// supplies the oracle's globals instead and the linker resolves each
/// extern to exactly one definition.
const default_ban_map = [ban_rows][ban_cols]c_uint{
    .{ 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0 },
    .{ 1, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1 },
    .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1 },
    .{ 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 },
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1, 0, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1 },
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
    .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1 },
    .{ 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 0, 0, 0, 0, 0, 1, 3, 3, 3, 1, 1, 1 },
    .{ 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
};

const testing = std.testing;

test "isqrtFloor truncates sqrt exactly over the reachable distance range" {
    // get_closest_player_to_point's largest argument: dx and dy up to
    // 359+8 (a fly at one playfield corner, the reference point at the
    // other), so n fits well inside u32. Every n up to 1000^2 is checked
    // against the defining inequality of the integer root.
    var n: u32 = 0;
    while (n <= 1_000_000) : (n += 1) {
        const r = isqrtFloor(n);
        try testing.expect(r *% r <= n);
        try testing.expect((r +% 1) *% (r +% 1) > n);
    }
}

fn resetSwarm(x0: c_int, y0: c_int) void {
    // Through the pointer aliases, not some test-only storage directly:
    // core/unit_flies_globals.zig's weak fallback is only the live backing
    // store when this file is its own test root (no competing strong
    // extern definition); linked into another binary (e.g.
    // flies_difftest.zig, core/game_loop.zig) that supplies real
    // player_raw/ban_map_raw storage, writing a test-only shadow variable
    // directly would silently leave the actual extern arrays untouched.
    ban_map_ptr.* = default_ban_map;
    lord_of_the_flies = 0;
    player_ptr.* = [_]Player{.{}} ** 4;
    volume_trace_channel = -1;
    volume_trace_volume = 0;
    volumeResetZ();
    for (&flies) |*fly| {
        fly.* = .{};
        fly.x = x0;
        fly.y = y0;
    }
}

fn checkSwarmInBounds() !void {
    for (&flies) |*fly| {
        try testing.expect(fly.x >= 16 and fly.x <= 351);
        try testing.expect(fly.y >= 0 and fly.y <= 239);
    }
}

test "get_closest_player_to_point walks enabled players only, first tie wins" {
    resetSwarm(0, 0);
    var dist: c_int = -1;
    var closest: c_int = -1;

    // No player enabled: dist reports the 0x7fff ceiling and the caller's
    // closest_player survives untouched.
    get_closest_player_to_point(100, 100, &dist, &closest);
    try testing.expectEqual(@as(c_int, max_player), dist);
    try testing.expectEqual(@as(c_int, -1), closest);

    player_ptr[2].enabled = 1;
    player_ptr[2].x = (100 - 8) << 16; // center point == query point
    player_ptr[2].y = (100 - 8) << 16;
    get_closest_player_to_point(100, 100, &dist, &closest);
    try testing.expectEqual(@as(c_int, 0), dist);
    try testing.expectEqual(@as(c_int, 2), closest);

    // A second, farther enabled player must not take the slot...
    player_ptr[1].enabled = 1;
    player_ptr[1].x = (200 - 8) << 16;
    player_ptr[1].y = (100 - 8) << 16;
    get_closest_player_to_point(100, 100, &dist, &closest);
    try testing.expectEqual(@as(c_int, 2), closest);

    // ...and an equal distance goes to the lower index, first win: player 0
    // placed at the exact same distance (0) as the already-closest player 2.
    player_ptr[0].enabled = 1;
    player_ptr[0].x = (100 - 8) << 16;
    player_ptr[0].y = (100 - 8) << 16;
    get_closest_player_to_point(100, 100, &dist, &closest);
    try testing.expectEqual(@as(c_int, 0), dist);
    try testing.expectEqual(@as(c_int, 0), closest);
}

fn swarmAverageX() i64 {
    var sum: i64 = 0;
    for (&flies) |*fly| sum += fly.x;
    return @divTrunc(sum, num_flies);
}

test "update_flies flees an adjacent player, jittered rnd(3)-1" {
    // A single fly's final position is noisy (swarm cohesion competes with
    // the flee force, plus per-tick rnd(3)-1 jitter), so this checks the
    // 20-fly swarm's average, which converges far more reliably toward the
    // expected drift than any one fly's absolute endpoint.
    var seed: u32 = 1;
    while (seed <= 25) : (seed += 1) {
        seedZ(seed);
        resetSwarm(160, 120);
        player_ptr[0].enabled = 1;
        player_ptr[0].x = (140 - 8) << 16;
        player_ptr[0].y = (120 - 8) << 16;

        var tick: usize = 0;
        while (tick < 200) : (tick += 1) {
            update_flies(1);
            try checkSwarmInBounds();
        }
        // The player sits 20px left of the initial swarm center, inside the
        // 30px flee radius (lord_of_the_flies == 0, the default), so the
        // swarm has to widen the gap.
        try testing.expect(swarmAverageX() > 165);
    }
}

test "update_flies chases the player under lord_of_the_flies" {
    var seed: u32 = 1;
    while (seed <= 25) : (seed += 1) {
        seedZ(seed);
        resetSwarm(160, 120);
        lord_of_the_flies = 1;
        player_ptr[0].enabled = 1;
        player_ptr[0].x = (140 - 8) << 16;
        player_ptr[0].y = (120 - 8) << 16;

        var tick: usize = 0;
        while (tick < 200) : (tick += 1) {
            update_flies(1);
            try checkSwarmInBounds();
        }
        try testing.expect(swarmAverageX() < 155);
    }
}

test "update_flies keeps every fly on a void tile" {
    // The default level's walls sit right where a wandering swarm would
    // walk into them: the C refuses any step onto a non-BAN_VOID tile.
    seedZ(7);
    resetSwarm(160, 120);
    player_ptr[0].enabled = 1;
    player_ptr[0].x = (140 - 8) << 16;
    player_ptr[0].y = (120 - 8) << 16;

    var tick: usize = 0;
    while (tick < 2000) : (tick += 1) {
        update_flies(1);
        for (&flies) |*fly| {
            try testing.expectEqual(@as(c_uint, ban_void), ban_map_ptr[@intCast(fly.y >> 4)][@intCast(fly.x >> 4)]);
        }
    }
}

// rnd.zig owns the definition of both of these; reached as externs per the
// no-@import rule so this test can pin the swarm's draw count.
extern var rnd_call_count: c_uint;

test "update_flies drives rnd(3) twice per fly" {
    seedZ(3);
    resetSwarm(160, 120);
    const before = rnd_call_count;
    update_flies(1);
    // One tick = 2 draws per fly = 40; a skipped swarm would drift the
    // checksummed rnd stream by exactly that.
    try testing.expectEqual(@as(c_uint, before + 40), rnd_call_count);
}
