// Standalone-build backing for core/flies.zig's Tier-A unit tests: the
// player_raw/ban_map_raw fallback (TASK-011.07 moved it here) that
// flies.zig's extern mirrors bind to. Only linked into flies.zig's own
// standalone `zig build test` binary (see core/build.zig), so there is no
// competing definition in that link to override -- hence a plain (non-weak)
// export. TASK-023: this used to be `.linkage = .weak`, matching the
// intent of "yield to a real definition if one exists," but Zig 0.16.0
// compiles a weak `@export` of a file-scope `var` as a *non-external*
// (private) symbol (confirmed with `nm -m`: `non-external _player_raw`
// instead of `weak external`), which is invisible outside this
// object file and left flies.zig's own Tier-A test unable to link at all.
// A plain export doesn't have that problem and is safe here precisely
// because this object is never linked alongside another definition of the
// same symbol.
//
// This TU deliberately does NOT @import("flies.zig"): importing the module
// here would drag flies.zig's own update_flies/spawn_flies exports into
// the object file a second time (flies.zig's own Tier-A test already links
// this file alongside itself as root), producing duplicate symbols. It
// only needs Player's layout, mirrored as a local layout-identical extern
// struct -- the same arrangement core/unit_objects_globals.zig uses for
// world.Object/ObjectAnim.
const Player = extern struct {
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

const ban_rows = 17;
const ban_cols = 22;

/// main.c:74's default level grid (same data core/flies.zig's own
/// resetSwarm() resets to, mirrored here since that const isn't `pub`).
const default_ban_map = [ban_rows][ban_cols]c_uint{
    .{ 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0 },
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

var unit_player: [4]Player = [_]Player{.{}} ** 4;
var unit_ban_map: [ban_rows][ban_cols]c_uint = default_ban_map;

comptime {
    @export(&unit_player, .{ .name = "player_raw" });
    @export(&unit_ban_map, .{ .name = "ban_map_raw" });
}
