// Port of main.c's game_loop() (main.c:1239-1430) — TASK-011.07, the last
// and most integrative Phase 3 subtask. Everything else in core/ (rnd,
// fixed16, world, steer, cpu_move, collision, objects, flies) is already
// ported and individually differential-tested; this module is just their
// call order plus an event stream, matching neo_snake's ns_step/ns_pump
// split: step() is exactly one simulation tick, pump() is the 60Hz
// accumulator on top of it.
//
// What step() replaces: main.c's inner `while (update_count)` body minus
// everything presentation/audio (dj_mix(), the pob/page bookkeeping,
// draw_begin/draw_pobs/draw_flies/draw_end, the palette ramp and its
// backoff re-run, flippage/redraw_*). None of that is checksummed
// (docs/checksum-format.md folds only frame_num/rnd_call_count/player[]/
// objects[]/ban_map[]) and none of it feeds back into simulation state, so
// dropping it cannot change a tick's outcome — it only ever decided when an
// extra display frame got drawn while colors eased into place. The
// netcode blocks (#ifdef USE_NET) are dropped too: is_net is always 0 for
// a local/headless run, and multiplayer networking is a later phase.
//
// Call order, main.c:1360-1381 (steer_players already carries the
// cpu_move()/update_player_actions() prologue in the original — see
// core/steer.zig's own header comment for why the port moved that prologue
// here instead): cpu_move() -> updatePlayerActions() -> steer_players() ->
// collision_check() -> update_objects() -> update_flies() if flies_enabled.
//
// State outside the shared world: is_server/is_net/flies_enabled (mode
// flags with no home until now — every earlier difftest only ever defined
// throwaway local copies) get their one real definition here, the same
// globals-ownership pattern core/steer.zig's pogostick/jetpack/etc use.
// keyb[]/player_raw[]/objects_raw[]/ban_map_raw[] stay core/c_ref/
// sim_harness.c's single shared arrays (extern mirrors here, like every
// other subsystem module).
const std = @import("std");
const rnd_mod = @import("rnd.zig");
const world = @import("world.zig");
const steer = @import("steer.zig");
const cpu_move_mod = @import("cpu_move.zig");
const collision = @import("collision.zig");
const objects_mod = @import("objects.zig");
const flies_mod = @import("flies.zig");

const max_players = world.max_players;
const num_objects = world.num_objects;

extern var player_raw: [max_players]world.Player;
extern var objects_raw: [num_objects]world.Object;
extern var ban_map_raw: [world.ban_rows][world.ban_cols]u32;
extern var keyb: [256]i8;
const player_ptr: *[max_players]world.Player = @constCast(&player_raw);

/// is_server (main.c:261)/is_net (main.c:262) — mode flags every earlier
/// difftest pinned to a local throwaway copy (1/0, the headless-server
/// case); this is their one real home. flies_enabled (main.c:219) defaults
/// to 1, matching the C's file-scope initializer.
pub export var is_server: c_int = 1;
pub export var is_net: c_int = 0;
pub export var flies_enabled: c_int = 1;

/// serverSendAlive (main.c:688) — core/collision.zig's link-boundary extern
/// for the is_net-gated net side effect on the kill path. Never reached
/// with is_net pinned to 0 above; the real net layer binds the real one.
pub export fn serverSendAlive(playerid: c_int) void {
    _ = playerid;
}

/// update_player_actions (sdl/input.c:42), headless/no-joystick path: keyb[]
/// read through the same (unsigned char) index key_pressed() uses. Callers
/// (Inputs -> keyb[]) run first each tick, then cpu_move() overwrites the
/// AI-driven players' three bits before this reads them, exactly like the
/// C's cpu_move(); update_player_actions(); pair.
fn updatePlayerActions() void {
    for (player_ptr, 0..) |*p, i| {
        const keys = cpu_move_mod.key_pl[i];
        p.action_left = @intFromBool(keyb[@intCast(keys[0] & 0x7f)] == 1);
        p.action_right = @intFromBool(keyb[@intCast(keys[1] & 0x7f)] == 1);
        p.action_up = @intFromBool(keyb[@intCast(keys[2] & 0x7f)] == 1);
    }
}

/// One tick's held-key state for the up-to-4 human-controlled players (an
/// AI-driven player's bits are ignored: cpu_move() overwrites keyb[] for
/// that player before updatePlayerActions() reads it, same as the C).
pub const Inputs = struct {
    left: [max_players]bool = .{false} ** max_players,
    right: [max_players]bool = .{false} ** max_players,
    jump: [max_players]bool = .{false} ** max_players,
};

fn applyInputs(inputs: Inputs) void {
    for (0..max_players) |i| {
        if (cpu_move_mod.ai[i] != 0) continue; // cpu_move() drives this player instead
        const keys = cpu_move_mod.key_pl[i];
        keyb[@intCast(keys[0] & 0x7f)] = @intFromBool(inputs.left[i]);
        keyb[@intCast(keys[1] & 0x7f)] = @intFromBool(inputs.right[i]);
        keyb[@intCast(keys[2] & 0x7f)] = @intFromBool(inputs.jump[i]);
    }
}

/// The event stream (AC#4): sfx triggers, object spawns, player deaths,
/// score changes, draws, and sfx-channel-volume changes, in the order the
/// tick produces them. `a`/`b`/`c`/`d` carry per-kind payloads (documented
/// at each push() call site below) rather than a union, matching the
/// fixed-shape event records already established by core/steer.zig's/
/// core/collision.zig's own sfx traces — the Godot event consumer (Phase 5)
/// reads one flat record shape. `.draw` and `.sfx_volume` exist because
/// core/objects.zig and core/flies.zig carry no renderer or audio
/// implementation of their own (docs/porting-playbook.md "Core purity",
/// TASK-011.08): what the C would have drawn or set the fly-swarm channel
/// volume to is recorded here as inert data instead, for whatever consumer
/// (audio, Godot) wants to act on it.
pub const EventKind = enum(c_int) {
    sfx = 1,
    object_spawn = 2,
    player_death = 3,
    score_change = 4,
    draw = 5,
    sfx_volume = 6,
};

pub const GameEvent = struct {
    kind: EventKind,
    a: c_int = 0,
    b: c_int = 0,
    c: c_int = 0,
    d: c_int = 0,
};

pub const max_events_per_tick = 256;

pub const Events = struct {
    items: [max_events_per_tick]GameEvent = undefined,
    count: usize = 0,

    fn push(self: *Events, e: GameEvent) void {
        if (self.count < max_events_per_tick) self.items[self.count] = e;
        self.count += 1;
    }

    /// The events actually stored (silently truncated past
    /// max_events_per_tick, like core/steer.zig's sfx_trace_z).
    pub fn slice(self: *const Events) []const GameEvent {
        return self.items[0..@min(self.count, max_events_per_tick)];
    }
};

/// Everything step() needs across ticks beyond the shared world itself
/// (AC#2's "no global mutable state outside the world struct"): explicitly
/// threaded through by the caller, not a hidden module-level var. The
/// world proper (player[]/objects[]/ban_map[]/anim tables/mode flags) stays
/// the extern-mirror storage every other TASK-011.* module already
/// established; this struct is the *additional* bookkeeping the event
/// classifier alone needs (which objects were live and which players were
/// dead as of the previous tick).
pub const State = struct {
    prev_dead: [max_players]bool = .{false} ** max_players,
    prev_used: [num_objects]bool = .{false} ** num_objects,
};

/// The killer of a just-dead victim: the one other player whose bumped[]
/// tally against them is nonzero (core/collision.zig's processKillPacket
/// increments player[killer].bumped[victim] on the same kill that sets
/// player[victim].dead_flag). Matches every corpus trace's scope (each
/// victim dies at most once), not a fully general kill-history lookup.
fn findKiller(victim: usize) i32 {
    for (0..max_players) |k| {
        if (k == victim) continue;
        if (player_ptr[k].bumped[victim] != 0) return @intCast(k);
    }
    return -1;
}

/// One simulation tick: apply `inputs`, run the four subsystems in
/// main.c's own order, then classify what changed into events. Pure other
/// than the extern world storage and `state`, both passed in by the
/// caller.
pub fn step(state: *State, inputs: Inputs) Events {
    applyInputs(inputs);
    cpu_move_mod.cpu_move();
    updatePlayerActions();
    steer.steer_players();
    collision.collision_check();
    objects_mod.update_objects();
    if (flies_enabled != 0) flies_mod.update_flies(1);

    var events: Events = .{};

    // sfx first: core/steer.zig's shared trace already carries both its own
    // dj_play_sfx sites and core/collision.zig's death cue (sfxRecordZ), in
    // the call order the tick just ran them, so reading it (and resetting
    // for the next tick) is the whole classification.
    const sfx_count = steer.sfxCountZ();
    for (0..sfx_count) |i| {
        const packed_val = steer.sfx_trace_z[i];
        events.push(.{ .kind = .sfx, .a = @divTrunc(packed_val, 100000), .b = @rem(packed_val, 100000), .c = 0 });
    }
    steer.sfxReset();

    // deaths + the score change each death caused, rising edge only
    // (dead_flag stays set for the rest of the run, same as main.c).
    for (0..max_players) |i| {
        const dead = player_ptr[i].dead_flag != 0;
        if (dead and !state.prev_dead[i]) {
            const killer = findKiller(i);
            events.push(.{ .kind = .player_death, .a = @intCast(i), .b = killer, .c = 0 });
            if (killer >= 0) {
                const k: usize = @intCast(killer);
                events.push(.{ .kind = .score_change, .a = killer, .b = player_ptr[k].bumps -% 1, .c = player_ptr[k].bumps });
            }
        }
        state.prev_dead[i] = dead;
    }

    // object spawns: any slot that flipped unused -> used this tick, from
    // any of the four subsystems (steer_players' splash/smoke, collision's
    // gore spray, or a future spawner) — one event per newly-live slot,
    // carrying (type, x, y) in pixels for the Godot consumer to spawn.
    for (0..num_objects) |i| {
        const used_now = objects_raw[i].used != 0;
        if (used_now and !state.prev_used[i]) {
            const o = &objects_raw[i];
            events.push(.{ .kind = .object_spawn, .a = o.type, .b = o.x >> 16, .c = o.y >> 16 });
        }
        state.prev_used[i] = used_now;
    }

    // draws: core/objects.zig's draw_trace_z carries what update_objects()
    // would have drawn this tick (main.c's add_pob calls as `.a = 0`,
    // add_leftovers' pair as `.a = 0`/`.a = 1`), in call order.
    const draw_count = objects_mod.drawCountZ();
    for (0..draw_count) |i| {
        const d = objects_mod.draw_trace_z[i];
        events.push(.{ .kind = .draw, .a = d.kind, .b = d.a, .c = d.b, .d = d.image });
    }
    objects_mod.drawResetZ();

    // fly-swarm channel volume: main.c sets this at most once per tick
    // (update_flies() only when update_count == 1, always true here).
    if (flies_enabled != 0 and flies_mod.volumeWasSetZ()) {
        events.push(.{ .kind = .sfx_volume, .a = flies_mod.volume_trace_channel, .b = flies_mod.volume_trace_volume });
    }
    flies_mod.volumeResetZ();

    return events;
}

/// pump()'s fixed-timestep accumulator (AC#3): main.c's headless path always
/// reports update_count == 1 per intr_sysupdate() call (one tick per call,
/// no skipping) since the recording harness feeds it frame-by-frame; the
/// interactive build's own intr_sysupdate() (sdl/interrpt.c:357) instead
/// paces real wall-clock time against a 60Hz clock via SDL_GetTicks(). This
/// accumulator generalizes that pacing for any host (a live client polling
/// real elapsed milliseconds, or a test harness feeding a fixed delta): it
/// derives however many whole 60Hz ticks a delta is worth, in integer
/// arithmetic only (no float, per the no-float simulation rule) — delta_ms
/// is scaled by 3 so one tick is exactly 50 of these units (1000ms * 3 /
/// 60 == 50), which stays exact over arbitrarily many accumulated ticks
/// rather than losing fractions of a millisecond the way repeated
/// `1000/60`-per-tick subtraction would.
const ticks_per_1000ms = 60;
const accum_unit_scale = 3; // 1000 * accum_unit_scale / ticks_per_1000ms must be an integer
const accum_per_tick = (1000 * accum_unit_scale) / ticks_per_1000ms; // 50

pub const PumpState = struct {
    accum_units: u32 = 0,
};

/// How many whole 60Hz ticks `delta_ms` is worth, advancing
/// `pump_state.accum_units` by exactly that much (the fractional remainder
/// carries to the next call). Pure accumulator arithmetic, no stepping —
/// shared by pump() below and core/abi.zig's jnb_fireworks_pump, which
/// drives core/fireworks.zig's step() on the same 60Hz clock instead of
/// this module's step().
pub fn ticksFor(pump_state: *PumpState, delta_ms: u32) usize {
    pump_state.accum_units += delta_ms *% accum_unit_scale;
    var ticks: usize = 0;
    while (pump_state.accum_units >= accum_per_tick) {
        pump_state.accum_units -= accum_per_tick;
        ticks += 1;
    }
    return ticks;
}

/// Run every whole tick `delta_ms` is worth (state.accum_units carries the
/// fractional remainder to the next call), returning how many ticks ran.
/// Ticks are run back to back with the same `inputs` for the whole delta —
/// callers wanting per-tick-varying input (e.g. a human's held keys
/// changing mid-delta) should call step() directly instead.
pub fn pump(pump_state: *PumpState, state: *State, delta_ms: u32, inputs: Inputs) usize {
    const ticks = ticksFor(pump_state, delta_ms);
    for (0..ticks) |_| _ = step(state, inputs);
    return ticks;
}

test "accum_per_tick divides 1000ms*scale by 60 exactly" {
    try std.testing.expectEqual(@as(u32, 50), accum_per_tick);
    try std.testing.expectEqual(@as(u32, 0), (1000 * accum_unit_scale) % ticks_per_1000ms);
}

test "ticksFor derives 60 ticks from a 1000ms delta with zero drift" {
    var pump_state: PumpState = .{};
    var total: usize = 0;
    // Feeding the delta in small, uneven chunks (not just one 1000ms call)
    // is the real test: the accumulator must not lose or gain ticks to
    // rounding across many calls, since that is exactly the failure mode a
    // float delta or a bare `ms / (1000/60)` division would have.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        total += ticksFor(&pump_state, 10);
    }
    try std.testing.expectEqual(@as(usize, 60), total);
}
