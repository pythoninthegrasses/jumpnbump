//! The C ABI wrapper — implementation of ../include/jumpnbump.h (TASK-012.02).
//!
//! The only Zig file that exports the `jnb_*` surface: every `export fn`
//! matching that prefix here has a matching declaration in
//! ../include/jumpnbump.h, and nothing here adds behavior beyond wrapping
//! core/game_loop.zig, core/world.zig, core/levelmap.zig, and core/rnd.zig
//! behind that exact surface.
//!
//! Divergence from neo_snake's core/abi.zig (see ../include/jumpnbump.h's
//! own header comment for the full rationale): jumpnbump's Phase 3 modules
//! (core/steer.zig, core/objects.zig, core/collision.zig, core/flies.zig,
//! core/cpu_move.zig) reach the live simulation state through `extern var`
//! declarations bound to fixed link-time symbol names — player_raw[],
//! objects_raw[], ban_map_raw[], keyb[] — rather than a runtime pointer.
//! core/c_ref/sim_harness.c supplies those symbols for the Tier-A/B test
//! binaries; this file is their production-build replacement, so it must
//! define them itself (as `export var`, the same C-linkage names) rather
//! than treat them as caller-relocatable. That makes the real simulation
//! state a process-wide singleton: at most one `jnb_world` is meaningful at
//! a time. What `jnb_world_size()` bytes actually hold is the genuinely
//! per-instance bookkeeping core/game_loop.zig's step()/pump() already take
//! as explicit parameters (State/PumpState) plus this file's own event
//! queue and frame counter — see `Instance` below.
//!
//! Reaching the rest of the simulation: `@import("game_loop.zig")` pulls in
//! game_loop.zig's own transitive `@import` of steer/cpu_move/collision/
//! objects/flies/rnd into this one compilation (the same "integration root"
//! precedent game_loop.zig itself already established for its own Tier-A/B
//! builds — see core/build.zig's game_loop.zig/game_loop_difftest.zig
//! wiring). This file additionally `@import`s steer.zig/objects.zig/
//! cpu_move.zig/flies.zig directly (TASK-018) — a compile-graph no-op, since
//! game_loop.zig already reaches all four transitively, but it names them so
//! jnb_world_init can call steer.loadDefaultAnims()/steer.position_player(),
//! objects.seedLevelObjects(), and flies.spawn_flies() to run main.c's own
//! headless/init_level() setup (main.c:1549-1598) before the first tick,
//! instead of leaving every player disabled and every level object unseeded
//! forever. Everything those modules reach via `extern fn` (rnd, add_object,
//! sfxRecordZ, is_server, player_anims, ...) resolves inside that same
//! compilation with no extra linking, except the draw-boundary stubs
//! (add_pob/add_leftovers) and the four world-storage arrays plus no_gore,
//! which this file supplies below in place of core/c_ref/sim_harness.c.
//!
//! Post-link symbol surface: because `export fn`/`export var` always emit a
//! default-visibility global symbol in Zig, and every module above already
//! legitimately uses `export fn`/`export var` for its own C-named surface
//! (TASK-011.*'s cross-module-linkage convention, predating this ABI), the
//! static library `zig build abi` produces would otherwise expose
//! `steer_players`, `rnd`, `is_server`, `player_anims`, `pogostick`, and
//! more alongside the `jnb_*` surface. core/build.zig's `abi` step runs a
//! post-link `objcopy --keep-global-symbols` pass (core/localize_abi_symbols.py)
//! to demote everything else to a local symbol — see that script's header
//! comment for why neo_snake never needed an equivalent step.
const std = @import("std");
const world = @import("world.zig");
const levelmap = @import("levelmap.zig");
const rnd_mod = @import("rnd.zig");
const game_loop = @import("game_loop.zig");
const steer = @import("steer.zig");
const objects_mod = @import("objects.zig");
const cpu_move_mod = @import("cpu_move.zig");
const flies_mod = @import("flies.zig");
const dat = @import("dat.zig");
const asset_runtime = @import("asset_runtime.zig");
const mod_player = @import("mod_player.zig");
const fireworks = @import("fireworks.zig");

const max_players = world.max_players;
const num_objects = world.num_objects;
const ban_rows = world.ban_rows;
const ban_cols = world.ban_cols;

// --- Real world storage ---------------------------------------------------
//
// Replaces core/c_ref/sim_harness.c's role for the production/ABI build:
// every ported module's `extern var player_raw`/`objects_raw`/`ban_map_raw`
// (core/steer.zig, core/objects.zig, core/collision.zig, core/flies.zig,
// core/game_loop.zig) and `extern var keyb`/`no_gore` (core/cpu_move.zig via
// core/game_loop.zig's Inputs plumbing / core/collision.zig) bind to these
// definitions at link time. One process, one world.

// Defined in core/abi_globals.zig, a separate compilation unit linked in by
// core/build.zig's addAbiStep — see that file's header comment for why this
// can't be `export var` directly inside this file.
extern var player_raw: [max_players]world.Player;
extern var objects_raw: [num_objects]world.Object;
extern var ban_map_raw: [ban_rows][ban_cols]u32;
extern var keyb: [256]i8;
extern var no_gore: c_int;

// add_pob()/add_leftovers() are the C's draw-side calls (main.c), which
// core/objects.zig reaches as `extern fn` — the renderer boundary is out of
// core (docs/porting-playbook.md "Core purity", TASK-011.08). This ABI
// drops the same draws core/game_loop.zig's own event stream already
// records as `.draw` events (core/objects.zig's draw_trace_z, drained by
// game_loop.step()'s Events), so real behavior is preserved: these two
// stubs only ever discard the actual pixel-drawing call, never simulation
// state. Mirrors core/unit_objects_draw.zig's same no-op pattern for the
// Tier-A/B builds.
fn noopAddPob(page: ?*anyopaque, x: c_int, y: c_int, image: c_int, gobs: ?*anyopaque) callconv(.c) void {
    _ = page;
    _ = x;
    _ = y;
    _ = image;
    _ = gobs;
}
fn noopAddLeftovers(which: c_int, x: c_int, y: c_int, frame: c_int, gobs: ?*anyopaque) callconv(.c) void {
    _ = which;
    _ = x;
    _ = y;
    _ = frame;
    _ = gobs;
}
comptime {
    @export(&noopAddPob, .{ .name = "add_pob" });
    @export(&noopAddLeftovers, .{ .name = "add_leftovers" });
}

// --- Result codes, mirroring ../include/jumpnbump.h ------------------------

pub const Result = i32;
pub const JNB_OK: Result = 0;
pub const JNB_ERR_INVALID_ARGUMENT: Result = 1;
pub const JNB_ERR_BUFFER_TOO_SMALL: Result = 2;
pub const JNB_ERR_ABI_VERSION_MISMATCH: Result = 3;
pub const JNB_ERR_LEVEL_PARSE_FAILED: Result = 4;
pub const JNB_ERR_ASSET_NOT_FOUND: Result = 5;
pub const JNB_ERR_ASSET_DECODE_FAILED: Result = 6;

const JNB_ABI_VERSION: u16 = 4;

const JNB_EVENT_SFX: u8 = 1;
const JNB_EVENT_OBJECT_SPAWN: u8 = 2;
const JNB_EVENT_PLAYER_DEATH: u8 = 3;
const JNB_EVENT_SCORE_CHANGE: u8 = 4;
const JNB_EVENT_DRAW: u8 = 5;
const JNB_EVENT_SFX_VOLUME: u8 = 6;

// --- ABI-crossing structs, mirroring ../include/jumpnbump.h field-for-field

pub const Config = extern struct {
    abi_version: u16,
    _pad0: u16,
    rng_seed: u32,
    flies_enabled: u8,
    /// Number of players to enable, indices 0..player_count-1 (main.c's own
    /// headless setup, main.c:1549-1561, only ever enables a contiguous run
    /// starting at player 0 -- there is no real-game path that enables an
    /// arbitrary subset). Clamped to [0, JNB_MAX_PLAYERS].
    player_count: u8,
    /// Bit i set means player i is AI-controlled (core/cpu_move.zig drives
    /// it instead of jnb_step/jnb_pump's per-tick input) -- main.c's ai[]
    /// (main.c:1559). Bits at or past player_count are ignored.
    player_ai_mask: u8,
    /// 0 or 1; core/collision.zig's no_gore flag (main.c's `-nogore` CLI
    /// flag) -- suppresses OBJ_FUR/OBJ_FLESH gore object spawns on a kill
    /// without changing whether the kill itself happens.
    no_gore: u8,
};
comptime {
    std.debug.assert(@sizeOf(Config) == 12);
}

pub const Input = extern struct {
    left: u8,
    right: u8,
    jump: u8,
    _pad: u8,
};
comptime {
    std.debug.assert(@sizeOf(Input) == 4);
}

pub const AtlasFrame = extern struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    hotspot_x: i32,
    hotspot_y: i32,
};
comptime {
    std.debug.assert(@sizeOf(AtlasFrame) == 24);
}

pub const PlayerView = extern struct {
    enabled: u8,
    dead_flag: u8,
    direction: u8,
    jump_ready: u8,
    jump_abort: u8,
    in_water: u8,
    _pad0: [2]u8,
    x: i32,
    y: i32,
    x_add: i32,
    y_add: i32,
    bumps: i32,
    anim: i32,
    frame: i32,
    image: i32,
};
comptime {
    std.debug.assert(@sizeOf(PlayerView) == 40);
}

pub const ObjectView = extern struct {
    used: u8,
    _pad0: [3]u8,
    type: i32,
    x: i32,
    y: i32,
    x_add: i32,
    y_add: i32,
    anim: i32,
    frame: i32,
    image: i32,
};
comptime {
    std.debug.assert(@sizeOf(ObjectView) == 36);
}

pub const Event = extern struct {
    kind: u8,
    _pad: [3]u8,
    a: i32,
    b: i32,
    c: i32,
    d: i32,
};
comptime {
    std.debug.assert(@sizeOf(Event) == 20);
}

pub const FireworksConfig = extern struct {
    abi_version: u16,
    _pad0: u16,
    rng_seed: u32,
};
comptime {
    std.debug.assert(@sizeOf(FireworksConfig) == 8);
}

pub const StarView = extern struct {
    x: i32,
    y: i32,
    col: i32,
};
comptime {
    std.debug.assert(@sizeOf(StarView) == 12);
}

// --- Per-instance bookkeeping (the real payload of jnb_world_size()) ------
//
// docs/checksum-format.md's frame_num has no production tracker anywhere in
// core/ today (only test/difftest code builds a World snapshot with a
// frame_num it already knows from a corpus trace) — this instance's own
// counter, incremented once per tick in stepOneTick, is that ABI's home for
// it.
//
// frame_num starts at the wrapping equivalent of -1 (0xffffffff), not 0:
// main.c's own headless_frame_num (main.c:1386-1391) folds its CURRENT
// value into a tick's checksum, THEN increments for the next tick --
// headless_emit_checksum(0) fires for the very first tick, not
// headless_emit_checksum(1). Starting at 0 and incrementing before use
// would make jnb_world_dump report frame_num=1 after exactly one jnb_step
// call, one off from what the same tick's real checksum was folded with.
// Wrapping -1 + 1 = 0 on the first stepOneTick call reproduces the C's
// exact numbering; a never-stepped (or just-reset) instance's dump
// reporting 0xffffffff instead of 0 is the harmless flip side of that same
// fix -- "no tick has completed yet" isn't the same state as "tick 0 just
// completed", so they no longer collide on the same stored value.
const EVENT_QUEUE_CAP: usize = 512;
const no_ticks_completed: u32 = 0xffffffff;

const Instance = struct {
    state: game_loop.State = .{},
    pump_state: game_loop.PumpState = .{},
    frame_num: u32 = no_ticks_completed,
    events: [EVENT_QUEUE_CAP]Event = undefined,
    event_head: usize = 0,
    event_len: usize = 0,
};

/// TASK-017.03's fireworks singleton — see ../include/jumpnbump.h's file
/// header comment for why this is a second, jnb_world-sized-and-shaped but
/// independent, per-process singleton rather than a jnb_world extension.
/// No `state`/`frame_num`: core/fireworks.zig's step() takes no input and
/// core/world.zig's checksum/dump format is jnb_world-specific, neither of
/// which fireworks mode uses.
const FireworksInstance = struct {
    pump_state: game_loop.PumpState = .{},
    events: [EVENT_QUEUE_CAP]Event = undefined,
    event_head: usize = 0,
    event_len: usize = 0,
};

fn storageOf(ptr: *anyopaque) *Instance {
    return @ptrCast(@alignCast(ptr));
}

fn storageOfConst(ptr: *const anyopaque) *const Instance {
    return @ptrCast(@alignCast(ptr));
}

fn fireworksStorageOf(ptr: *anyopaque) *FireworksInstance {
    return @ptrCast(@alignCast(ptr));
}

fn fireworksStorageOfConst(ptr: *const anyopaque) *const FireworksInstance {
    return @ptrCast(@alignCast(ptr));
}

/// Queues one event, dropping the oldest queued event to make room on
/// overflow — an undrained caller loses only history, never live world
/// state (still queryable via jnb_player_view_get/jnb_objects_copy
/// regardless). Mirrors neo_snake's core/abi.zig pushEvent. Generic over
/// `*Instance`/`*FireworksInstance` (identical event_head/event_len/events
/// shape) rather than duplicated for the second singleton.
fn pushEvent(inst: anytype, e: Event) void {
    if (inst.event_len == EVENT_QUEUE_CAP) {
        inst.event_head = (inst.event_head + 1) % EVENT_QUEUE_CAP;
        inst.event_len -= 1;
    }
    const idx = (inst.event_head + inst.event_len) % EVENT_QUEUE_CAP;
    inst.events[idx] = e;
    inst.event_len += 1;
}

fn toInputs(inp: Input) game_loop.Inputs {
    var out: game_loop.Inputs = .{};
    for (0..max_players) |i| {
        const bit: u8 = @as(u8, 1) << @intCast(i);
        out.left[i] = (inp.left & bit) != 0;
        out.right[i] = (inp.right & bit) != 0;
        out.jump[i] = (inp.jump & bit) != 0;
    }
    return out;
}

/// Runs exactly one tick and queues the events it produced, in order.
///
/// Zeroes every player's 3 keyb[] slots first, matching sdl/interrpt.c's
/// headless_load_frame_keys() (reached from main.c's `-headless` path,
/// which recorded the Phase 1 corpus): a jnb_input is a complete per-tick
/// snapshot, not an incremental key-down/up delta, so nothing should carry
/// over between calls. This is a no-op for manually-controlled players
/// (game_loop.zig's applyInputs() unconditionally overwrites their 3 bits
/// from `inputs` every tick regardless), but it matters for an AI-driven
/// player: cpu_move() owns that player's keyb bits and reads its own
/// previous write back for one hysteresis check ("is my jump key still
/// held") before overwriting them for this tick -- without zeroing first,
/// that check would see cpu_move()'s OWN prior-tick decision instead of a
/// fresh snapshot, diverging from the corpus a few dozen ticks into any
/// AI-driven trace (core/game_loop_difftest.zig's own Tier-B replay
/// performs this exact same zeroing for the identical reason).
fn stepOneTick(inst: *Instance, inputs: game_loop.Inputs) void {
    for (cpu_move_mod.key_pl) |keys| {
        keyb[@intCast(keys[0] & 0x7f)] = 0;
        keyb[@intCast(keys[1] & 0x7f)] = 0;
        keyb[@intCast(keys[2] & 0x7f)] = 0;
    }
    const events = game_loop.step(&inst.state, inputs);
    inst.frame_num +%= 1;
    for (events.slice()) |ge| {
        pushEvent(inst, .{
            .kind = @intCast(@intFromEnum(ge.kind)),
            ._pad = .{ 0, 0, 0 },
            .a = ge.a,
            .b = ge.b,
            .c = ge.c,
            .d = ge.d,
        });
    }
}

// --- World lifecycle --------------------------------------------------

export fn jnb_world_size() callconv(.c) usize {
    return @sizeOf(Instance);
}

export fn jnb_world_align() callconv(.c) usize {
    return @alignOf(Instance);
}

export fn jnb_world_init(world_ptr: ?*anyopaque, config: ?*const Config, level_bytes: ?[*]const u8, level_len: usize) callconv(.c) Result {
    const cfg = config orelse return JNB_ERR_INVALID_ARGUMENT;
    const wp = world_ptr orelse return JNB_ERR_INVALID_ARGUMENT;
    if (cfg.abi_version != JNB_ABI_VERSION) return JNB_ERR_ABI_VERSION_MISMATCH;
    if (cfg.rng_seed == 0) return JNB_ERR_INVALID_ARGUMENT;

    const bytes: []const u8 = if (level_bytes) |lb| lb[0..level_len] else &[_]u8{};
    const parsed = levelmap.parse(bytes, false) catch return JNB_ERR_LEVEL_PARSE_FAILED;

    const inst = storageOf(wp);
    inst.* = .{};

    // Mirrors main.c's own startup sequence in order (main.c:1549-1598):
    // seed the one continuous rnd() stream, load the level's ban_map, reset
    // player/object state, enable+AI-mask the headless players, position
    // each enabled player (main.c:2896-2903's init_level() loop),  seed the
    // level's spring/butterfly objects (init_level()'s own object seeding),
    // then spawn the fly swarm if enabled -- every one of those last three
    // steps draws from the same rnd() stream this function just seeded, so
    // the order is checksum-significant, not cosmetic.
    rnd_mod.seed(cfg.rng_seed);
    player_raw = [_]world.Player{.{}} ** max_players;
    objects_raw = [_]world.Object{.{}} ** num_objects;
    for (0..ban_rows) |r| {
        for (0..ban_cols) |c| ban_map_raw[r][c] = parsed[r][c];
    }
    game_loop.flies_enabled = if (cfg.flies_enabled != 0) 1 else 0;
    no_gore = if (cfg.no_gore != 0) 1 else 0;
    steer.loadDefaultAnims();

    const player_count = @min(cfg.player_count, max_players);
    for (0..player_count) |i| {
        player_raw[i].enabled = 1;
        cpu_move_mod.ai[i] = @intCast((cfg.player_ai_mask >> @intCast(i)) & 1);
    }
    for (0..player_count) |i| {
        player_raw[i].bumps = 0;
        player_raw[i].bumped = [_]c_int{0} ** max_players;
        steer.position_player(@intCast(i));
    }
    objects_mod.seedLevelObjects();
    if (game_loop.flies_enabled != 0) flies_mod.spawn_flies();

    return JNB_OK;
}

export fn jnb_world_reset(world_ptr: ?*anyopaque) callconv(.c) Result {
    const inst = storageOf(world_ptr orelse return JNB_ERR_INVALID_ARGUMENT);
    inst.* = .{};
    player_raw = [_]world.Player{.{}} ** max_players;
    objects_raw = [_]world.Object{.{}} ** num_objects;
    return JNB_OK;
}

// --- Stepping --------------------------------------------------------------

export fn jnb_step(world_ptr: ?*anyopaque, inputs: Input) callconv(.c) Result {
    const inst = storageOf(world_ptr orelse return JNB_ERR_INVALID_ARGUMENT);
    stepOneTick(inst, toInputs(inputs));
    return JNB_OK;
}

/// Drives core/game_loop.zig's ticksFor() accumulator directly (rather than
/// calling pump()) so each individual tick's Events can be captured — pump()
/// itself discards step()'s return value, same reasoning neo_snake's own
/// ns_pump gives for not delegating to core/world.zig's pump(). Shared with
/// jnb_fireworks_pump below, which drives the same 60Hz clock over
/// core/fireworks.zig's step() instead.
export fn jnb_pump(world_ptr: ?*anyopaque, delta_ms: u32, inputs: Input, out_ticks: ?*u32) callconv(.c) Result {
    const inst = storageOf(world_ptr orelse return JNB_ERR_INVALID_ARGUMENT);
    const out = out_ticks orelse return JNB_ERR_INVALID_ARGUMENT;
    const conv_inputs = toInputs(inputs);

    const ticks = game_loop.ticksFor(&inst.pump_state, delta_ms);
    for (0..ticks) |_| stepOneTick(inst, conv_inputs);
    out.* = @intCast(ticks);
    return JNB_OK;
}

// --- Per-player / per-object state ------------------------------------------

export fn jnb_player_view_get(world_ptr: ?*const anyopaque, player: u8, out_view: ?*PlayerView) callconv(.c) Result {
    _ = world_ptr orelse return JNB_ERR_INVALID_ARGUMENT;
    const view = out_view orelse return JNB_ERR_INVALID_ARGUMENT;
    if (player >= max_players) return JNB_ERR_INVALID_ARGUMENT;
    const p = &player_raw[player];
    view.* = .{
        .enabled = @intCast(p.enabled),
        .dead_flag = @intCast(p.dead_flag),
        .direction = @intCast(p.direction),
        .jump_ready = @intCast(p.jump_ready),
        .jump_abort = @intCast(p.jump_abort),
        .in_water = @intCast(p.in_water),
        ._pad0 = .{ 0, 0 },
        .x = p.x,
        .y = p.y,
        .x_add = p.x_add,
        .y_add = p.y_add,
        .bumps = p.bumps,
        .anim = p.anim,
        .frame = p.frame,
        .image = p.image,
    };
    return JNB_OK;
}

export fn jnb_objects_copy(world_ptr: ?*const anyopaque, out_objects: ?[*]ObjectView, out_capacity: usize, out_required: ?*usize) callconv(.c) Result {
    _ = world_ptr orelse return JNB_ERR_INVALID_ARGUMENT;
    const required = out_required orelse return JNB_ERR_INVALID_ARGUMENT;
    required.* = num_objects;
    if (out_objects == null or out_capacity == 0) return JNB_OK;
    if (out_capacity < num_objects) return JNB_ERR_BUFFER_TOO_SMALL;

    for (0..num_objects) |i| {
        const o = &objects_raw[i];
        out_objects.?[i] = .{
            .used = @intCast(o.used),
            ._pad0 = .{ 0, 0, 0 },
            .type = o.type,
            .x = o.x,
            .y = o.y,
            .x_add = o.x_add,
            .y_add = o.y_add,
            .anim = o.anim,
            .frame = o.frame,
            .image = o.image,
        };
    }
    return JNB_OK;
}

// --- Canonical serialization -------------------------------------------------

export fn jnb_world_dump_len() callconv(.c) usize {
    return world.dump_len;
}

export fn jnb_world_dump(world_ptr: ?*const anyopaque, out_buf: ?[*]u8, out_capacity: usize, out_written: ?*usize) callconv(.c) Result {
    const wp = world_ptr orelse return JNB_ERR_INVALID_ARGUMENT;
    const written = out_written orelse return JNB_ERR_INVALID_ARGUMENT;
    written.* = world.dump_len;
    if (out_capacity < world.dump_len) return JNB_ERR_BUFFER_TOO_SMALL;
    const buf = out_buf orelse return JNB_ERR_INVALID_ARGUMENT;

    const inst = storageOfConst(wp);
    const snapshot: world.World = .{
        .frame_num = inst.frame_num,
        .rnd_call_count = rnd_mod.rnd_call_count,
        .players = player_raw,
        .objects = objects_raw,
        .ban_map = ban_map_raw,
    };

    // Sized to exactly world.dump_len (not out_capacity): dumpTo appends
    // world.dump_len bytes total (checked by core/world.zig's own test
    // suite), and pre-allocating that exact capacity up front means
    // appendSlice's growth check never fires (ensureUnusedCapacity is a
    // no-op once capacity already covers every append) — appending into a
    // FixedBufferAllocator sized to out_capacity instead let ArrayList's
    // doubling-growth strategy request more than was available and fail
    // with OutOfMemory even when out_capacity == dump_len exactly. This
    // also writes directly into the caller's buf, so no extra copy is
    // needed (the removed `@memcpy(buf[0..out.items.len], out.items)`
    // aliased its own source and destination, since out.items already lived
    // inside buf).
    var fba = std.heap.FixedBufferAllocator.init(buf[0..world.dump_len]);
    var out = std.ArrayList(u8).initCapacity(fba.allocator(), world.dump_len) catch unreachable;
    world.dumpTo(&out, fba.allocator(), &snapshot) catch unreachable;
    written.* = out.items.len;
    return JNB_OK;
}

export fn jnb_checksum(bytes: ?[*]const u8, len: usize, out_checksum: ?*u32) callconv(.c) Result {
    const b = bytes orelse return JNB_ERR_INVALID_ARGUMENT;
    const out = out_checksum orelse return JNB_ERR_INVALID_ARGUMENT;
    out.* = world.fnv1a32(b[0..len]);
    return JNB_OK;
}

// --- Ordered event drain --------------------------------------------------

export fn jnb_event_count(world_ptr: ?*const anyopaque) callconv(.c) usize {
    const wp = world_ptr orelse return 0;
    return storageOfConst(wp).event_len;
}

export fn jnb_event_drain(world_ptr: ?*anyopaque, out_events: ?[*]Event, out_capacity: usize, out_count: ?*usize) callconv(.c) Result {
    const inst = storageOf(world_ptr orelse return JNB_ERR_INVALID_ARGUMENT);
    const count = out_count orelse return JNB_ERR_INVALID_ARGUMENT;
    const n = @min(inst.event_len, out_capacity);
    if (out_events) |dst| {
        for (0..n) |i| {
            const idx = (inst.event_head + i) % EVENT_QUEUE_CAP;
            dst[i] = inst.events[idx];
        }
    }
    inst.event_head = (inst.event_head + n) % EVENT_QUEUE_CAP;
    inst.event_len -= n;
    count.* = n;
    return JNB_OK;
}

// --- Runtime .dat asset decoding (TASK-016.01) ----------------------------
//
// Pure buffer-in/buffer-out: no jnb_world involved, no file I/O. Decoding
// needs short-lived heap allocations gob.zig/pcx.zig's decode() makes
// internally (a duplicated input buffer, an images/pixels slice); that is
// an asset-loading concern, not part of the fixed-memory simulation state
// this ABI otherwise never allocates for, so these functions alone use
// page_allocator, freed before returning.

export fn jnb_dat_find(buf: ?[*]const u8, buf_len: usize, name: ?[*]const u8, name_len: usize, out_offset: ?*usize, out_size: ?*usize) callconv(.c) Result {
    const b = buf orelse return JNB_ERR_INVALID_ARGUMENT;
    const n = name orelse return JNB_ERR_INVALID_ARGUMENT;
    const offset_out = out_offset orelse return JNB_ERR_INVALID_ARGUMENT;
    const size_out = out_size orelse return JNB_ERR_INVALID_ARGUMENT;

    const entry = dat.find(b[0..buf_len], n[0..name_len]) orelse return JNB_ERR_ASSET_NOT_FOUND;
    offset_out.* = entry.offset;
    size_out.* = entry.size;
    return JNB_OK;
}

export fn jnb_pcx_palette_decode(pcx_buf: ?[*]const u8, pcx_len: usize, out_palette_rgb768: ?[*]u8, palette_capacity: usize) callconv(.c) Result {
    const buf = pcx_buf orelse return JNB_ERR_INVALID_ARGUMENT;
    const out = out_palette_rgb768 orelse return JNB_ERR_INVALID_ARGUMENT;
    if (palette_capacity != asset_runtime.palette_size) return JNB_ERR_INVALID_ARGUMENT;

    const palette = asset_runtime.decodeDisplayPalette(std.heap.page_allocator, buf[0..pcx_len]) catch return JNB_ERR_ASSET_DECODE_FAILED;
    @memcpy(out[0..asset_runtime.palette_size], &palette);
    return JNB_OK;
}

export fn jnb_gob_frame_count(gob_buf: ?[*]const u8, gob_len: usize, out_count: ?*usize) callconv(.c) Result {
    const buf = gob_buf orelse return JNB_ERR_INVALID_ARGUMENT;
    const out = out_count orelse return JNB_ERR_INVALID_ARGUMENT;

    out.* = asset_runtime.gobFrameCount(std.heap.page_allocator, buf[0..gob_len]) catch return JNB_ERR_ASSET_DECODE_FAILED;
    return JNB_OK;
}

export fn jnb_gob_atlas_build(
    gob_buf: ?[*]const u8,
    gob_len: usize,
    palette_rgb768: ?[*]const u8,
    out_frames: ?[*]AtlasFrame,
    frames_capacity: usize,
    out_frame_count: ?*usize,
    out_pixels: ?[*]u8,
    pixels_capacity: usize,
) callconv(.c) Result {
    const buf = gob_buf orelse return JNB_ERR_INVALID_ARGUMENT;
    const required = out_frame_count orelse return JNB_ERR_INVALID_ARGUMENT;

    required.* = asset_runtime.gobFrameCount(std.heap.page_allocator, buf[0..gob_len]) catch return JNB_ERR_ASSET_DECODE_FAILED;
    if (out_frames == null or frames_capacity == 0) return JNB_OK;
    if (frames_capacity < required.*) return JNB_ERR_BUFFER_TOO_SMALL;

    const palette_ptr = palette_rgb768 orelse return JNB_ERR_INVALID_ARGUMENT;
    if (pixels_capacity != asset_runtime.rgba_len) return JNB_ERR_INVALID_ARGUMENT;
    const pixels = out_pixels orelse return JNB_ERR_INVALID_ARGUMENT;

    var palette: [asset_runtime.palette_size]u8 = undefined;
    @memcpy(&palette, palette_ptr[0..asset_runtime.palette_size]);

    // AtlasFrame (this file) and asset_runtime.AtlasFrame are separately
    // declared extern structs with identical field layout (six i32 fields,
    // same order) -- one mirrors ../include/jumpnbump.h's jnb_atlas_frame
    // for the ABI boundary, the other is asset_runtime.zig's own pure-Zig
    // type. @ptrCast between them is layout-safe.
    const frame_slice: []AtlasFrame = out_frames.?[0..required.*];
    const asset_frames: []asset_runtime.AtlasFrame = @ptrCast(frame_slice);
    const written = asset_runtime.buildSpriteAtlas(
        std.heap.page_allocator,
        buf[0..gob_len],
        palette,
        asset_frames,
        pixels[0..pixels_capacity],
    ) catch return JNB_ERR_ASSET_DECODE_FAILED;
    required.* = written;
    return JNB_OK;
}

export fn jnb_level_layers_build(
    pcx_buf: ?[*]const u8,
    pcx_len: usize,
    mask_buf: ?[*]const u8,
    mask_len: usize,
    out_background_rgba: ?[*]u8,
    background_capacity: usize,
    out_foreground_rgba: ?[*]u8,
    foreground_capacity: usize,
) callconv(.c) Result {
    const pcx_bytes = pcx_buf orelse return JNB_ERR_INVALID_ARGUMENT;
    const mask_bytes = mask_buf orelse return JNB_ERR_INVALID_ARGUMENT;
    const bg = out_background_rgba orelse return JNB_ERR_INVALID_ARGUMENT;
    const fg = out_foreground_rgba orelse return JNB_ERR_INVALID_ARGUMENT;
    if (background_capacity != asset_runtime.rgba_len or foreground_capacity != asset_runtime.rgba_len) {
        return JNB_ERR_INVALID_ARGUMENT;
    }

    asset_runtime.buildLevelLayers(
        std.heap.page_allocator,
        pcx_bytes[0..pcx_len],
        mask_bytes[0..mask_len],
        bg[0..background_capacity],
        fg[0..foreground_capacity],
    ) catch return JNB_ERR_ASSET_DECODE_FAILED;
    return JNB_OK;
}

// Runtime .mod music playback (TASK-016.03). Same page_allocator-scratch
// discipline as the asset-decoding functions above: core/mod_player.zig's
// parse() duplicates mod_buf internally, freed via defer before this
// returns -- no allocation crosses the ABI boundary except the caller's own
// out_pcm_i16 buffer.

export fn jnb_mod_count_frames(mod_buf: ?[*]const u8, mod_len: usize, sample_rate_hz: u32, out_frame_count: ?*usize) callconv(.c) Result {
    const buf = mod_buf orelse return JNB_ERR_INVALID_ARGUMENT;
    const out = out_frame_count orelse return JNB_ERR_INVALID_ARGUMENT;

    var mf = mod_player.parse(std.heap.page_allocator, buf[0..mod_len]) catch return JNB_ERR_ASSET_DECODE_FAILED;
    defer mf.deinit();

    out.* = mod_player.countFrames(&mf, sample_rate_hz);
    return JNB_OK;
}

export fn jnb_mod_render(
    mod_buf: ?[*]const u8,
    mod_len: usize,
    sample_rate_hz: u32,
    out_pcm_i16: ?[*]i16,
    pcm_capacity: usize,
    out_frame_count: ?*usize,
) callconv(.c) Result {
    const buf = mod_buf orelse return JNB_ERR_INVALID_ARGUMENT;
    const required = out_frame_count orelse return JNB_ERR_INVALID_ARGUMENT;

    var mf = mod_player.parse(std.heap.page_allocator, buf[0..mod_len]) catch return JNB_ERR_ASSET_DECODE_FAILED;
    defer mf.deinit();

    required.* = mod_player.countFrames(&mf, sample_rate_hz);
    if (out_pcm_i16 == null or pcm_capacity == 0) return JNB_OK;
    if (pcm_capacity < required.* * 2) return JNB_ERR_BUFFER_TOO_SMALL;

    const pcm = mod_player.renderToPcm(std.heap.page_allocator, &mf, sample_rate_hz) catch return JNB_ERR_ASSET_DECODE_FAILED;
    defer std.heap.page_allocator.free(pcm);

    const out = out_pcm_i16.?;
    @memcpy(out[0..pcm.len], pcm);
    required.* = pcm.len / 2;
    return JNB_OK;
}

// --- Fireworks screensaver mode (TASK-017.03) -------------------------------
//
// core/fireworks.zig's rabbits[]/stars[] are its own `export var` globals
// (not caller storage), so FireworksInstance above holds only the same
// per-instance bookkeeping Instance does minus frame_num/state — see
// ../include/jumpnbump.h's file header comment for the shared-singleton
// divergence this and jnb_world both have, and why the two are mutually
// exclusive within one process.

export fn jnb_fireworks_size() callconv(.c) usize {
    return @sizeOf(FireworksInstance);
}

export fn jnb_fireworks_align() callconv(.c) usize {
    return @alignOf(FireworksInstance);
}

export fn jnb_fireworks_init(fireworks_ptr: ?*anyopaque, config: ?*const FireworksConfig) callconv(.c) Result {
    const cfg = config orelse return JNB_ERR_INVALID_ARGUMENT;
    const fp = fireworks_ptr orelse return JNB_ERR_INVALID_ARGUMENT;
    if (cfg.abi_version != JNB_ABI_VERSION) return JNB_ERR_ABI_VERSION_MISMATCH;
    if (cfg.rng_seed == 0) return JNB_ERR_INVALID_ARGUMENT;

    const inst = fireworksStorageOf(fp);
    inst.* = .{};

    // fireworks.c:64's memset(ban_map, 0, ...), the shared particle pool
    // reset, and reloading the animation table rabbitImage() reads --
    // exactly core/fireworks_difftest.zig's setupWorld(), the already
    // Tier-B-proven init sequence for this module.
    objects_raw = [_]world.Object{.{}} ** num_objects;
    ban_map_raw = std.mem.zeroes([ban_rows][ban_cols]u32);
    steer.loadDefaultAnims();

    // rabbits[]/stars[] are export var globals, not part of
    // FireworksInstance -- a fresh init must zero them itself (matching
    // core/fireworks_difftest.zig's own re-init between scenarios) since a
    // prior run may have left live rabbits/stars behind.
    fireworks.rabbits = std.mem.zeroes([fireworks.num_rabbits]fireworks.Rabbit);
    fireworks.stars = std.mem.zeroes([fireworks.num_stars]fireworks.Star);
    rnd_mod.seed(cfg.rng_seed);
    fireworks.init();
    fireworks.drawResetZ();
    fireworks.sfxResetZ();
    objects_mod.drawResetZ();

    return JNB_OK;
}

/// Runs one fireworks tick and queues the events it produced: the
/// detonation sfx cue (if any), then every rabbit sprite draw
/// (core/fireworks.zig's own draw_trace_z, `a = 2`), then every gore
/// object draw update_objects() produced this tick (core/objects.zig's
/// draw_trace_z, `a = d.kind`) -- fireworks.step()'s own call order
/// (advanceStars -> maybeSpawnRabbit -> updateRabbits -> update_objects).
fn fireworksStepOneTick(inst: *FireworksInstance) void {
    fireworks.step();

    for (0..fireworks.sfxCountZ()) |i| {
        const packed_val = fireworks.sfx_trace_z[i];
        pushEvent(inst, .{
            .kind = JNB_EVENT_SFX,
            ._pad = .{ 0, 0, 0 },
            .a = @divTrunc(packed_val, 100000),
            .b = @rem(packed_val, 100000),
            .c = 0,
            .d = 0,
        });
    }
    fireworks.sfxResetZ();

    for (0..fireworks.drawCountZ()) |i| {
        const d = fireworks.draw_trace_z[i];
        pushEvent(inst, .{
            .kind = JNB_EVENT_DRAW,
            ._pad = .{ 0, 0, 0 },
            .a = 2,
            .b = d.x,
            .c = d.y,
            .d = d.image,
        });
    }
    fireworks.drawResetZ();

    for (0..objects_mod.drawCountZ()) |i| {
        const d = objects_mod.draw_trace_z[i];
        pushEvent(inst, .{
            .kind = JNB_EVENT_DRAW,
            ._pad = .{ 0, 0, 0 },
            .a = d.kind,
            .b = d.a,
            .c = d.b,
            .d = d.image,
        });
    }
    objects_mod.drawResetZ();
}

export fn jnb_fireworks_step(fireworks_ptr: ?*anyopaque) callconv(.c) Result {
    const inst = fireworksStorageOf(fireworks_ptr orelse return JNB_ERR_INVALID_ARGUMENT);
    fireworksStepOneTick(inst);
    return JNB_OK;
}

export fn jnb_fireworks_pump(fireworks_ptr: ?*anyopaque, delta_ms: u32, out_ticks: ?*u32) callconv(.c) Result {
    const inst = fireworksStorageOf(fireworks_ptr orelse return JNB_ERR_INVALID_ARGUMENT);
    const out = out_ticks orelse return JNB_ERR_INVALID_ARGUMENT;

    const ticks = game_loop.ticksFor(&inst.pump_state, delta_ms);
    for (0..ticks) |_| fireworksStepOneTick(inst);
    out.* = @intCast(ticks);
    return JNB_OK;
}

export fn jnb_fireworks_stars_copy(fireworks_ptr: ?*const anyopaque, out_stars: ?[*]StarView, out_capacity: usize, out_required: ?*usize) callconv(.c) Result {
    _ = fireworks_ptr orelse return JNB_ERR_INVALID_ARGUMENT;
    const required = out_required orelse return JNB_ERR_INVALID_ARGUMENT;
    required.* = fireworks.num_stars;
    if (out_stars == null or out_capacity == 0) return JNB_OK;
    if (out_capacity < fireworks.num_stars) return JNB_ERR_BUFFER_TOO_SMALL;

    for (0..fireworks.num_stars) |i| {
        const s = &fireworks.stars[i];
        out_stars.?[i] = .{ .x = s.x, .y = s.y, .col = s.col };
    }
    return JNB_OK;
}

export fn jnb_fireworks_event_count(fireworks_ptr: ?*const anyopaque) callconv(.c) usize {
    const fp = fireworks_ptr orelse return 0;
    return fireworksStorageOfConst(fp).event_len;
}

export fn jnb_fireworks_event_drain(fireworks_ptr: ?*anyopaque, out_events: ?[*]Event, out_capacity: usize, out_count: ?*usize) callconv(.c) Result {
    const inst = fireworksStorageOf(fireworks_ptr orelse return JNB_ERR_INVALID_ARGUMENT);
    const count = out_count orelse return JNB_ERR_INVALID_ARGUMENT;
    const n = @min(inst.event_len, out_capacity);
    if (out_events) |dst| {
        for (0..n) |i| {
            const idx = (inst.event_head + i) % EVENT_QUEUE_CAP;
            dst[i] = inst.events[idx];
        }
    }
    inst.event_head = (inst.event_head + n) % EVENT_QUEUE_CAP;
    inst.event_len -= n;
    count.* = n;
    return JNB_OK;
}
