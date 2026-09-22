// Standalone-build backing for core/steer.zig's Tier-A unit tests: the
// player_raw/objects_raw/ban_map_raw fallback that steer.zig's extern
// mirrors bind to. Only linked into steer.zig's own standalone
// `zig build test` binary (see core/build.zig), so there is no competing
// definition in that link to override -- a plain (non-weak) export, same
// as core/unit_flies_globals.zig/core/unit_objects_globals.zig.
//
// TASK-023: this replaces the `is_own_test_root = @import("root") ==
// @This()` comptime trick steer.zig used to gate its own in-module weak
// fallback. That trick relied on `@import("root")` resolving to steer.zig
// itself whenever steer.zig is the compilation's root_source_file, which
// holds for `zig build-obj -Mroot=steer.zig` (core/build.zig's
// collision.zig/fireworks.zig Tier-A tests pre-compile steer.zig as
// exactly such an object) but not for `zig build test`: `b.addTest` wraps
// the provided root module in Zig's own synthesized test-runner shim, so
// `@import("root")` inside steer.zig resolves to that shim, not to
// steer.zig -- `is_own_test_root` was always false there (confirmed with
// `@compileLog`), so steer.zig's own Tier-A test could never link. Moving
// the fallback into this companion file, linked in explicitly and only
// for that one binary, sidesteps the root-detection problem entirely:
// this file's own export always fires when it's linked, exactly once,
// exactly there.
//
// This TU deliberately does NOT @import("steer.zig"): importing the
// module here would drag steer.zig's own steer_players/position_player
// exports into the object file a second time (steer.zig's own Tier-A test
// already links this file alongside itself as root), producing duplicate
// symbols. It only needs world.zig's Player/Object layout and array sizes
// (world.zig is the shared layout module every port mirrors, not a ported
// subsystem with its own exports to collide with), the same arrangement
// core/unit_objects_globals.zig uses.
const world = @import("world.zig");

var unit_player: [world.max_players]world.Player = [_]world.Player{.{}} ** world.max_players;
var unit_objects: [world.num_objects]world.Object = [_]world.Object{.{}} ** world.num_objects;

/// main.c:74's default level grid -- mirrors core/steer.zig's own
/// (now-removed) default_ban_map byte-for-byte.
var unit_ban_map: [world.ban_rows][world.ban_cols]u32 = .{
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

comptime {
    @export(&unit_player, .{ .name = "player_raw" });
    @export(&unit_objects, .{ .name = "objects_raw" });
    @export(&unit_ban_map, .{ .name = "ban_map_raw" });
}
