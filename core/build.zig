const std = @import("std");

// Phase 0 (TASK-003) of the C -> Zig port: wire up the four build steps the
// rest of the porting plan hangs off of, against an empty/stub core/. No
// simulation code exists yet, so `test` and `difftest` are empty step
// aggregators (populated incrementally as TASK-011.* ports land) while `abi`
// and `abitest` build/exercise real (currently empty) stub files, since
// TASK-012.02/TASK-012.03 need a concrete module to grow into rather than a
// step that starts from nothing. Targets Zig 0.16.0, pinned in
// ../.tool-versions and verified via `mise which zig`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    addTestStep(b, target, optimize);
    addDiffTestStep(b, target, optimize);
    const abi_lib = addAbiStep(b, target, optimize);
    addAbiTestStep(b, target, optimize, abi_lib);
    addCliTools(b, target, optimize);
}

// TASK-010.05: Zig CLI rewrites of modify/jnbpack.c, modify/jnbunpack.c, and
// modify/gobpack.c, built on the dat/gob/pcx codecs above. Not part of the
// pure simulation core (they do real file I/O against argv), so each gets
// its own `zig build <name>` install step rather than joining `test`.
const cli_tools = [_]struct { name: []const u8, file: []const u8 }{
    .{ .name = "jnbpack", .file = "jnbpack_cli.zig" },
    .{ .name = "jnbunpack", .file = "jnbunpack_cli.zig" },
    .{ .name = "gobpack", .file = "gobpack_cli.zig" },
    .{ .name = "asset-dump", .file = "asset_dump_cli.zig" },
};

fn addCliTools(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    inline for (cli_tools) |tool| {
        const mod = b.createModule(.{
            .root_source_file = b.path(tool.file),
            .target = target,
            .optimize = optimize,
        });
        const exe = b.addExecutable(.{ .name = tool.name, .root_module = mod });
        const install = b.addInstallArtifact(exe, .{});
        const step = b.step(tool.name, "Build the Zig " ++ tool.name ++ " CLI");
        step.dependOn(&install.step);
    }
}

// Tier-A unit tests for ported Zig modules (docs/porting-playbook.md).
// Empty until TASK-011.* ports a main.c subsystem into its own core/*.zig
// module; each porting subtask appends its module's test file here.
const unit_test_files = [_][]const u8{ "dat.zig", "gob.zig", "pcx.zig", "levelmap.zig", "fixed16.zig", "world.zig", "rnd.zig", "flies.zig", "steer.zig", "objects.zig", "collision.zig", "game_loop.zig", "asset_runtime.zig", "mod_player.zig", "fireworks.zig" };

fn addTestStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const step = b.step("test", "Run Tier-A unit tests for ported Zig modules");
    // steer.zig (and every future port that reaches another subsystem's
    // C-named global through the playbook's extern pattern — extern fn rnd,
    // extern var is_server) needs those names resolvable when its module is
    // built standalone. Compile the originals for this step only: rnd from
    // the same c_ref/rnd.c the Tier-B reference is built from (byte-identical
    // logic to core/rnd.zig's export, so unit tests exercise the identical
    // libc rand()-backed stream), with the rename suppressed so it keeps the
    // original name; is_server as an exported Zig global pinned to the
    // single-player value.
    const rnd_native_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rnd_native_mod.addCSourceFile(.{ .file = b.path("c_ref/rnd.c"), .flags = &.{"-fwrapv"} });
    const rnd_native = b.addObject(.{ .name = "rnd_unit_ref", .root_module = rnd_native_mod });
    for (unit_test_files) |file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.linkSystemLibrary("bz2", .{});
        // TASK-011.06: flies.zig reaches rnd() as an extern fn (the
        // no-@import rule), so its Tier-A binary links rnd.zig's object the
        // same way the difftest entries link their renamed-C references.
        if (std.mem.eql(u8, file, "flies.zig")) {
            const rnd_obj = b.addObject(.{
                .name = "flies_unit_rnd",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("rnd.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            mod.addObjectFile(rnd_obj.getEmittedBin());
            // TASK-011.07: player_raw/ban_map_raw's weak fallback moved out
            // of flies.zig itself into this opt-in file (see its header
            // comment) so core/game_loop.zig can @import both flies.zig and
            // core/steer.zig without their weak fallbacks colliding; this
            // module's own standalone Tier-A test still needs it linked
            // explicitly, same as core/objects.zig's unit_objects_globals.zig.
            const flies_globals_obj = b.addObject(.{
                .name = "unit_flies_globals",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("unit_flies_globals.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            mod.addObjectFile(flies_globals_obj.getEmittedBin());
        }
        // TASK-011.03: collision.zig's extern mirrors (player_raw/
        // ban_map_raw) get the same shared-storage C definitions the Tier-B
        // link uses, so its Tier-A tests exercise the real layout; the
        // weak in-module fallbacks only apply when the module is its own
        // test root. add_object lands on steer.zig's object (the port
        // collision.zig reaches through extern fn), which drags steer.zig's
        // own externs onto the same resolution list.
        if (std.mem.eql(u8, file, "collision.zig") or std.mem.eql(u8, file, "fireworks.zig")) {
            const harness_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            harness_mod.addCSourceFile(.{ .file = b.path("c_ref/sim_harness.c"), .flags = &.{"-fwrapv"} });
            const harness_obj = b.addObject(.{ .name = "collision_unit_harness", .root_module = harness_mod });
            mod.addObjectFile(harness_obj.getEmittedBin());
            const steer_obj = b.addObject(.{
                .name = "collision_unit_steer",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("steer.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            mod.addObjectFile(steer_obj.getEmittedBin());
        }
        // TASK-011.02: steer.zig (and every future port that reaches
        // another subsystem's C-named global through the playbook's extern
        // pattern — extern fn rnd, extern var is_server) needs those names
        // resolvable when its module is built standalone. TASK-017.02's
        // fireworks.zig has the identical dependency profile as collision.zig
        // (rnd, add_object/update_objects via objects.zig, player_anims via
        // steer.zig above), so it joins this same list.
        if (std.mem.eql(u8, file, "steer.zig") or std.mem.eql(u8, file, "collision.zig") or std.mem.eql(u8, file, "fireworks.zig")) {
            mod.addObjectFile(rnd_native.getEmittedBin());
            // The Zig TU exporting is_server/is_net for standalone module
            // builds (see core/unit_net_globals.zig's header comment): compiled
            // as an object, not a test runner, so the module's own test binary
            // stays the single entry point.
            const net_globals_mod = b.createModule(.{
                .root_source_file = b.path("unit_net_globals.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            const net_globals_obj = b.addObject(.{ .name = "unit_net_globals", .root_module = net_globals_mod });
            mod.addObjectFile(net_globals_obj.getEmittedBin());
            // TASK-011.04: steer_players() reaches add_object() as an extern fn
            // (its canonical home moved to objects.zig). Link objects.zig's
            // export for the standalone steer unit-test build. objects.zig's
            // own extern globals (objects[]/object_anims[]/ban_map[]) resolve to
            // steer.zig's exports in this compilation, so no separate backing TU
            // is needed; only add_pob/add_leftovers (which neither steer.zig nor
            // objects.zig defines) need stubs, and those come from
            // unit_objects_globals' weak-free fn-only path below.
            const objects_obj = b.addObject(.{
                .name = "steer_unit_objects",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("objects.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            mod.addObjectFile(objects_obj.getEmittedBin());
            // add_pob/add_leftovers stubs (objects.zig references them; the
            // renderer boundary is out of the core). Only the two fns are
            // exported here — the world arrays come from steer.zig above, so
            // the arrays-exporting unit_objects_globals.zig would collide.
            const obj_draw_obj = b.addObject(.{
                .name = "steer_unit_objects_draw",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("unit_objects_draw.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            mod.addObjectFile(obj_draw_obj.getEmittedBin());
        }
        // TASK-011.04: objects.zig reaches rnd() as an extern fn (the
        // no-@import rule) and links libm's atan2 only inside its octant()
        // self-check (the reference the port replaces), so its Tier-A binary
        // needs the same rnd object steer.zig uses plus libm.
        if (std.mem.eql(u8, file, "objects.zig")) {
            mod.addObjectFile(rnd_native.getEmittedBin());
            mod.linkSystemLibrary("m", .{});
            // The Zig TU exporting objects[]/object_anims[]/ban_map[]/add_pob/
            // add_leftovers for standalone module builds (see
            // core/unit_objects_globals.zig's header comment): objects.zig
            // declares them extern (steer.zig owns them in the full build), so
            // its own test binary needs backing definitions compiled as an
            // object, not a test runner.
            const obj_globals_mod = b.createModule(.{
                .root_source_file = b.path("unit_objects_globals.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            const obj_globals_obj = b.addObject(.{ .name = "unit_objects_globals", .root_module = obj_globals_mod });
            mod.addObjectFile(obj_globals_obj.getEmittedBin());
        }
        // TASK-011.07: game_loop.zig @imports every subsystem module
        // directly (steer/cpu_move/collision/objects/flies/rnd), so their
        // mutual extern-fn cross-references (rnd, add_object, etc.) and
        // world-storage weak fallbacks all resolve inside this one
        // compilation with no extra linking -- except add_pob/
        // add_leftovers, which no core module defines (the draw boundary),
        // so this needs the same no-op stubs objects.zig's own Tier-A test
        // links above.
        if (std.mem.eql(u8, file, "game_loop.zig")) {
            mod.linkSystemLibrary("m", .{});
            const gl_draw_obj = b.addObject(.{
                .name = "game_loop_unit_objects_draw",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("unit_objects_draw.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            mod.addObjectFile(gl_draw_obj.getEmittedBin());
        }
        const mod_test = b.addTest(.{ .root_module = mod });
        step.dependOn(&b.addRunArtifact(mod_test).step);
    }
}

// Tier-B differential tests: behavioral-equivalence checks between a
// pre-port C reference (symbols renamed via the preprocessor, following
// zelda3's compileRenamedCRef technique) and its ported .zig module, replayed
// over the TASK-008 corpus. rnd_difftest.zig started as the TASK-008.04
// harness pilot; as of TASK-011.01 it carries the real rnd(), fixed16 and
// world-layout differentials, and steer_difftest.zig (TASK-011.02) is the
// first per-tick stateful replay: the C reference is extracted verbatim from
// main.c by core/c_ref/extract_steered.py into core/c_ref/steer.c. Corpus-
// replay entries join as later TASK-011.* ports land.
const diff_test_files = [_][]const u8{ "rnd_difftest.zig", "cpu_move_difftest.zig", "flies_difftest.zig", "steer_difftest.zig", "objects_difftest.zig", "collision_difftest.zig", "game_loop_difftest.zig", "fireworks_difftest.zig" };

fn addDiffTestStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const step = b.step("difftest", "Run Tier-B differential tests against renamed C references");

    // -fwrapv (added inside compileRenamedCRef) matters most here: rnd()'s
    // `%` against a value that can be INT_MIN is UB the oracle relies on
    // wrapping through, and UBSan checks would abort the difftest binary
    // instead.
    const rnd_ref = compileRenamedCRef(b, target, optimize, "rnd_c_ref", "c_ref/rnd.c", &.{"rnd"});
    // TASK-011.01: the fixed16 helpers are renamed at their _ref suffix so
    // each C expression keeps a name distinct from the Zig helper it mirrors.
    const cpu_move_ref = compileRenamedCRefSanitized(b, target, optimize, "cpu_move_c_ref", "c_ref/cpu_move.c", &.{ "cpu_move_ref", "map_tile_ref" }, .off);
    const fixed16_ref = compileRenamedCRef(b, target, optimize, "fixed16_c_ref", "c_ref/fixed16.c", &.{
        "fp_add_ref",
        "fp_sub_ref",
        "fp_neg_ref",
        "fp_mul_small_ref",
        "fp_pixel_shr16_ref",
        "fp_pixel_shr20_ref",
        "fp_sar_int_ref",
        "fp_bounce_quarter_ref",
        "fp_to_fixed_ref",
        "fp_from_pixel_shl_ref",
        "fp_wrap_mask_shl16_ref",
        "fp_wrap_mask_sub_shl16_ref",
        "fp_wrap_hi_shl16_ref",
        "fp_wrap_hi_plus15_shl16_ref",
        "fp_pixel_shl4_ref",
        "fp_to_tile20_ref",
    });
    // TASK-011.06: get_closest_player_to_point/update_flies/spawn_flies
    // renamed so they don't collide with flies.zig's own exports of those
    // names.
    const flies_ref = compileRenamedCRef(b, target, optimize, "flies_c_ref", "c_ref/flies.c", &.{
        "get_closest_player_to_point",
        "update_flies",
        "spawn_flies",
    });
    // TASK-011.02: steer.c is generated from main.c (see the script's
    // docstring); the rename list is its two ported entry points — the
    // reference's own helpers are file-static or already c_-prefixed.
    const steer_ref = compileRenamedCRef(b, target, optimize, "steer_c_ref", "c_ref/steer.c", &.{
        "steer_players",
        "position_player",
    });
    // TASK-011.04: objects.c is generated from main.c (see the script's
    // docstring); the rename list is its two ported entry points. add_pob/
    // add_leftovers are unrenamed (harness-owned, shared with the Zig port);
    // the C's internal update_objects -> add_object call resolves to
    // c_add_object through the same -D rename.
    // sanitize_c = .off: the particle physics reads ban_map[y >> 20][x >> 20]
    // at raw (sometimes negative or past-the-edge) indices exactly as the
    // oracle does — a butterfly climbing to y < 0 or a fur blob flying off to
    // x < -5*65536 — and the real binary falls through to whatever memory
    // follows ban_map. Zig's C frontend instruments static-array indexing with
    // runtime bounds checks that would trap instead; .off restores the oracle's
    // actual (unsafe, but shared-memory-safe here) behaviour for this reference,
    // the same way c_ref/cpu_move.c's map_tile mixup needs it. The harness pads
    // ban_map's backing identically on both sides, so identical inputs give
    // identical reads.
    const objects_ref = compileRenamedCRefSanitized(b, target, optimize, "objects_c_ref", "c_ref/objects.c", &.{
        "add_object",
        "update_objects",
    }, .off);
    // TASK-011.03: collision.c is generated from main.c too (see that
    // script's docstring); process_kill_packet is exported to the harness's
    // kill_dispatch, while player_kill/collision_check are collision.zig's
    // own names (player_kill file-static there, exported here for the
    // targeted probes).
    // The rename list keeps the extracted definitions distinct from the
    // Zig port's own exports; the file-static pair and the packet entry are
    // reachable through the wrappers at the bottom of collision.c
    // (collision_tick / player_kill_gate / kill_packet_entry), which the
    // rename leaves untouched.
    const collision_ref = compileRenamedCRef(b, target, optimize, "collision_c_ref", "c_ref/collision.c", &.{
        "processKillPacket",
    });
    // TASK-017.02: fireworks.c is split into fireworks_init_ref/
    // fireworks_step_ref by core/c_ref/extract_fireworks.py (see that
    // script's docstring). add_object/update_objects are unrenamed
    // (harness-owned, resolving to core/objects.zig's real exports, same as
    // objects_ref above) so a mismatch can only come from fireworks.zig's
    // own new logic. sanitize_c = .off for the same reason objects_ref
    // needs it: fireworks mode zeroes ban_map for its whole run, and the
    // shared update_objects() still reads it at raw indices.
    const fireworks_ref = compileRenamedCRefSanitized(b, target, optimize, "fireworks_c_ref", "c_ref/fireworks.c", &.{
        "fireworks_init_ref",
        "fireworks_step_ref",
    }, .off);

    for (diff_test_files) |file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.linkSystemLibrary("m", .{});
        const mod_test = b.addTest(.{ .root_module = mod });
        if (std.mem.eql(u8, file, "rnd_difftest.zig")) {
            mod_test.root_module.addObjectFile(rnd_ref);
            mod_test.root_module.addObjectFile(fixed16_ref);
        }
        if (std.mem.eql(u8, file, "cpu_move_difftest.zig")) {
            mod_test.root_module.addCSourceFile(.{ .file = b.path("c_ref/sim_harness.c"), .flags = &.{"-fwrapv"} });
            mod_test.root_module.addCSourceFile(.{ .file = b.path("c_ref/cpu_move_harness.c"), .flags = &.{"-fwrapv"} });
            mod_test.root_module.addObjectFile(cpu_move_ref);
        }
        if (std.mem.eql(u8, file, "flies_difftest.zig")) {
            mod_test.root_module.addCSourceFile(.{ .file = b.path("c_ref/flies_harness.c"), .flags = &.{"-fwrapv"} });
            mod_test.root_module.addObjectFile(flies_ref);
        }
        if (std.mem.eql(u8, file, "steer_difftest.zig")) {
            // Pre-compiled as its own object, not addCSourceFile straight into
            // this root module: this binary @imports core/steer.zig, whose own
            // weak player_raw/objects_raw/ban_map_raw fallbacks (for when
            // steer.zig is its own standalone Tier-A test root) collide with
            // sim_harness.c's real definitions if Zig's own module graph has to
            // reconcile a weak Zig-level export against a C source folded into
            // the same module -- see game_loop_difftest.zig's identical fix
            // below. Pre-compiling sim_harness.c and linking the object lets
            // ordinary weak-symbol override (strong beats weak) resolve it at
            // the final link step instead, where it actually works.
            const steer_dt_harness_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            steer_dt_harness_mod.addCSourceFile(.{ .file = b.path("c_ref/sim_harness.c"), .flags = &.{"-fwrapv"} });
            const steer_dt_harness_obj = b.addObject(.{ .name = "steer_dt_harness", .root_module = steer_dt_harness_mod });
            mod_test.root_module.addObjectFile(steer_dt_harness_obj.getEmittedBin());
            mod_test.root_module.addObjectFile(rnd_ref);
            mod_test.root_module.addObjectFile(steer_ref);
            // TASK-011.04: add_object()/update_objects() now live in
            // objects.zig, which steer_difftest.zig @imports directly (so its
            // root module already carries those exports — linking objects.zig a
            // second time here would duplicate them). Only the draw stubs
            // (add_pob/add_leftovers), which neither steer.zig nor objects.zig
            // defines, are added as a separate object.
            const steer_draw_obj = b.addObject(.{
                .name = "steer_dt_objects_draw",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("unit_objects_draw.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            mod_test.root_module.addObjectFile(steer_draw_obj.getEmittedBin());
        }
        if (std.mem.eql(u8, file, "objects_difftest.zig")) {
            // TASK-011.03's world-storage consolidation made steer.zig's
            // player_raw/objects_raw/ban_map_raw `extern var` (no longer
            // `export var`), so @importing steer.zig no longer supplies real
            // storage for objects_raw/ban_map_raw the way it used to; this
            // binary needs sim_harness.c's definitions directly, same as
            // steer_difftest.zig/cpu_move_difftest.zig/collision_difftest.zig.
            //
            // TASK-022: pre-compiled as its own object, not addCSourceFile
            // straight into this root module -- this binary @imports
            // core/steer.zig for object_anims/ObjectAnim/AnimFrame, and its
            // weak player_raw/objects_raw/ban_map_raw fallbacks silently split
            // from sim_harness.c's real definitions into two distinct
            // addresses when the C source is folded into the same Zig module
            // graph instead of linked as a separate object (confirmed with
            // `nm -m`: two `objects_raw` symbols at different addresses, one
            // `(__DATA,__bss) non-external` the Zig side binds, one
            // `(__DATA,__common) external` the C side binds) -- every Zig-side
            // read/write (seedObject, snapshot/restore, compareObjects) landed
            // on a world the C reference's add_object()/update_objects() never
            // touched, so every scenario after the vacuously-empty "springs"
            // one (default_ban_map has no BAN_SPRING tile, so it seeds
            // nothing) was comparing live Zig state against an untouched C
            // snapshot -- not a real add_object()/update_objects() porting
            // bug. Same fix game_loop_difftest.zig/fireworks_difftest.zig
            // already use: pre-compile sim_harness.c and link the resulting
            // object so ordinary weak-symbol override (strong beats weak)
            // resolves it at the final link step instead.
            const objects_dt_harness_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            objects_dt_harness_mod.addCSourceFile(.{ .file = b.path("c_ref/sim_harness.c"), .flags = &.{"-fwrapv"} });
            const objects_dt_harness_obj = b.addObject(.{ .name = "objects_dt_harness", .root_module = objects_dt_harness_mod });
            mod_test.root_module.addObjectFile(objects_dt_harness_obj.getEmittedBin());
            // The C reference's rnd() goes through c_rnd_from -> rnd_mod.rnd
            // (the harness's export), and objects.zig reaches rnd as an extern
            // fn; both bind rnd.zig's export, so link it like the difftests
            // above link rnd_ref. objects.c's atan2 is the oracle's own, kept
            // intact in the reference for the octant comparison.
            mod_test.root_module.addObjectFile(rnd_ref);
            mod_test.root_module.addObjectFile(objects_ref);
        }
        if (std.mem.eql(u8, file, "collision_difftest.zig")) {
            // TASK-022: pre-compiled as its own object for the same reason as
            // objects_difftest.zig/steer_difftest.zig above -- this binary
            // @imports core/steer.zig too, so folding sim_harness.c straight
            // into this root module splits player_raw/objects_raw/ban_map_raw
            // into two addresses instead of one shared world.
            const collision_dt_harness_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            collision_dt_harness_mod.addCSourceFile(.{ .file = b.path("c_ref/sim_harness.c"), .flags = &.{"-fwrapv"} });
            const collision_dt_harness_obj = b.addObject(.{ .name = "collision_dt_harness", .root_module = collision_dt_harness_mod });
            mod_test.root_module.addObjectFile(collision_dt_harness_obj.getEmittedBin());
            mod_test.root_module.addObjectFile(rnd_ref);
            mod_test.root_module.addObjectFile(collision_ref);
            // The replayed tick runs the extracted steer_players (the pair
            // only overlaps because physics moved them there), so TASK-
            // 011.02's reference is linked into this binary as well.
            mod_test.root_module.addObjectFile(steer_ref);
            // collision.zig's kill/gore path (furGore) reaches add_object,
            // which @imports objects.zig into this binary too, so its
            // extern add_pob/add_leftovers (never defined in core) need the
            // same no-op draw stubs steer_difftest.zig links.
            const collision_draw_obj = b.addObject(.{
                .name = "collision_dt_objects_draw",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("unit_objects_draw.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            mod_test.root_module.addObjectFile(collision_draw_obj.getEmittedBin());
        }
        // TASK-011.07: no renamed-C reference at all -- the oracle is the
        // corpus's own recorded checksums (tests/corpus/*.jsonl), not a
        // second implementation of game_loop's order. game_loop_difftest.zig
        // @imports every subsystem module directly (same as game_loop.zig's
        // own Tier-A wiring above), so it only needs the real world storage
        // and the draw-boundary stubs, not any compileRenamedCRef object.
        if (std.mem.eql(u8, file, "game_loop_difftest.zig")) {
            // Loads data/jumpbump.dat's real levelmap.txt (core/dat.zig +
            // core/levelmap.zig, TASK-010.01/010.04) for the actual
            // corpus-recorded level, so it needs libbz2 like core/dat.zig's
            // own Tier-A test does.
            mod_test.root_module.linkSystemLibrary("bz2", .{});
            // Pre-compiled as its own object (not addCSourceFile straight
            // into this root module): this binary @imports both
            // core/steer.zig and core/flies.zig, whose own weak
            // player_raw/ban_map_raw fallbacks (for when either is its own
            // standalone Tier-A test root) collide if Zig's own module
            // graph has to reconcile two weak Zig-level exports of the same
            // name -- pre-compiling sim_harness.c and linking the object
            // lets ordinary ELF weak-symbol override (strong beats weak)
            // resolve it at the final link step instead.
            const gl_dt_harness_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            gl_dt_harness_mod.addCSourceFile(.{ .file = b.path("c_ref/sim_harness.c"), .flags = &.{"-fwrapv"} });
            const gl_dt_harness_obj = b.addObject(.{ .name = "game_loop_dt_harness", .root_module = gl_dt_harness_mod });
            mod_test.root_module.addObjectFile(gl_dt_harness_obj.getEmittedBin());
            const gl_dt_draw_obj = b.addObject(.{
                .name = "game_loop_dt_objects_draw",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("unit_objects_draw.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            mod_test.root_module.addObjectFile(gl_dt_draw_obj.getEmittedBin());
        }
        // TASK-017.02: fireworks_difftest.zig @imports both core/objects.zig
        // (add_object/update_objects) and core/steer.zig (player_anims), the
        // same multi-import shape game_loop_difftest.zig has -- so
        // sim_harness.c is pre-compiled as its own object rather than added
        // straight into this root module, for the identical reason: letting
        // ordinary weak-symbol override resolve player_raw/objects_raw/
        // ban_map_raw at the final link step instead of inside Zig's own
        // module graph.
        if (std.mem.eql(u8, file, "fireworks_difftest.zig")) {
            mod_test.root_module.linkSystemLibrary("m", .{});
            const fw_dt_harness_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            fw_dt_harness_mod.addCSourceFile(.{ .file = b.path("c_ref/sim_harness.c"), .flags = &.{"-fwrapv"} });
            const fw_dt_harness_obj = b.addObject(.{ .name = "fireworks_dt_harness", .root_module = fw_dt_harness_mod });
            mod_test.root_module.addObjectFile(fw_dt_harness_obj.getEmittedBin());
            mod_test.root_module.addObjectFile(rnd_ref);
            mod_test.root_module.addObjectFile(fireworks_ref);
        }
        step.dependOn(&b.addRunArtifact(mod_test).step);
    }
}

// Compile a pre-port C source to an object with each of `syms` renamed to
// c_<name>, so it can link alongside the ported Zig module (which owns the
// original names) without colliding. The rename happens at the preprocessor
// level (`-D<sym>=c_<sym>`) rather than post-hoc with objcopy: the
// preprocessor rewrites every token occurrence in the TU (the definition and
// any same-TU references), which matches objcopy's symbol-table rewrite
// (definitions plus undefined cross-TU references) and, unlike objcopy,
// needs no external tool and works identically on ELF and Mach-O (whose
// leading-underscore symbol names silently defeat a bare-name objcopy
// invocation on macOS). Ported verbatim from zelda3's build.zig
// (compileRenamedCRef).
fn compileRenamedCRef(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, src: []const u8, syms: []const []const u8) std.Build.LazyPath {
    return compileRenamedCRefSanitized(b, target, optimize, name, src, syms, null);
}

// cpu_move.c (TASK-011.05) deliberately exercises main.c's own map_tile
// bounds-check mixup (pos_x checked against 17, pos_y against 22, on a
// 22-column/17-row grid), reading past ban_map[][] the same way the real
// oracle binary does. Zig's C frontend instruments static-array indexing
// with the same runtime bounds checks as Zig's own arrays in Debug/
// ReleaseSafe, which would trap on that read instead of letting it fall
// through to whatever memory follows — sanitize_c = .off restores the
// oracle's actual (unsafe, but not undefined for this shared-memory
// harness) behavior for just this one reference object.
fn compileRenamedCRefSanitized(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, src: []const u8, syms: []const []const u8, sanitize_c: ?std.zig.SanitizeC) std.Build.LazyPath {
    const ref_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = sanitize_c,
    });
    // -fwrapv: signed overflow is UB in the abstract and this codebase
    // relies on two's-complement wraparound in practice (the oracle
    // Makefile builds main.c with -ffast-math, which implies the same
    // no-trapping stance). Without it, Zig's own clang emits UBSan checks
    // into the reference's arithmetic — which aborts the difftest binary
    // the moment a helper is probed at an overflow corner, instead of
    // returning the wrap the compiled oracle actually performs. The
    // difftest asserts zig-vs-reference agreement, which holds for any
    // flag set where the reference doesn't trap.
    const dflags = b.allocator.alloc([]const u8, syms.len + 1) catch @panic("OOM");
    dflags[0] = "-fwrapv";
    for (syms, 1..) |sym, i|
        dflags[i] = b.fmt("-D{s}=c_{s}", .{ sym, sym });
    ref_mod.addCSourceFile(.{ .file = b.path(src), .flags = dflags });
    const ref_obj = b.addObject(.{
        .name = name,
        .root_module = ref_mod,
    });
    return ref_obj.getEmittedBin();
}

// abi.zig (TASK-012.02) is the sole Zig file permitted to `export fn` the
// surface declared in ../include/jumpnbump.h. Built as a static library so
// the GDExtension shim (extension/, TASK-012.04) and the abitest suite below
// can link against it without depending on Zig's own module system. `.pic`
// matches neo_snake's convention: it ends up in a `ld -shared` step later,
// where non-PIC relocations in a static archive fail.
fn addAbiStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const abi = b.createModule(.{
        .root_source_file = b.path("abi.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        // dat.zig @cImports bzlib.h (bz2 decompression); rnd.zig no longer
        // needs libc as of TASK-021 (it reimplements its generator in pure
        // Zig instead of wrapping libc rand(), which wasn't portable).
        .link_libc = true,
    });
    // core/abi_globals.zig (TASK-012.02): the real player_raw/objects_raw/
    // ban_map_raw/keyb/no_gore storage, compiled as its own object rather
    // than @imported directly — see that file's header comment for why
    // (steer.zig/collision.zig's own weak fallbacks of the same names would
    // otherwise collide with a strong definition in the same compilation).
    const globals_obj = b.addObject(.{
        .name = "abi_globals",
        .root_module = b.createModule(.{
            .root_source_file = b.path("abi_globals.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        }),
    });
    abi.addObjectFile(globals_obj.getEmittedBin());

    const abi_lib = b.addLibrary(.{
        .name = "jumpnbump",
        .linkage = .static,
        .root_module = abi,
    });
    const install = b.addInstallArtifact(abi_lib, .{});

    // TASK-012.02: post-link symbol localization. abi.zig transitively
    // @imports every ported module (via game_loop.zig), which drags each
    // module's own pre-existing `export fn`/`export var` (steer_players,
    // rnd, is_server, player_anims, pogostick, ... — TASK-011.*'s
    // cross-module-linkage convention, non-jnb_-prefixed, predating this
    // ABI) into the same static archive. Zig's `export` keyword always
    // emits a default-visibility global symbol and there is no way to make
    // one file-local from inside Zig itself, so this demotes every defined
    // global symbol not matching the frozen jnb_ ABI surface to local,
    // post-link. neo_snake never needed an equivalent step: its own modules
    // never use bare `export fn` outside abi.zig.
    const localize = b.addSystemCommand(&.{ "uv", "run" });
    localize.addFileArg(b.path("localize_abi_symbols.py"));
    localize.addArg(b.getInstallPath(.lib, abi_lib.out_lib_filename));
    localize.addFileArg(b.path("../include/jumpnbump.h"));
    localize.step.dependOn(&install.step);

    const abi_step = b.step("abi", "Build the static library exporting the C ABI (core/abi.zig), localized to only the jnb_ symbol surface");
    abi_step.dependOn(&localize.step);
    return abi_lib;
}

// abitest.zig (TASK-012.03) is the Tier-C ABI conformance suite: it reaches
// abi_lib exclusively through @cImport(jumpnbump.h), never by importing core
// Zig modules directly (checked separately by tools/validate_abi_test_purity.py,
// following neo_snake's script of the same name).
fn addAbiTestStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, abi_lib: *std.Build.Step.Compile) void {
    const abitest = b.createModule(.{
        .root_source_file = b.path("abitest.zig"),
        .target = target,
        .optimize = optimize,
        // link_libc is required for @cImport to work at all.
        .link_libc = true,
    });
    abitest.addIncludePath(b.path("../include"));
    abitest.linkLibrary(abi_lib);
    const abitest_exe = b.addTest(.{ .root_module = abitest });
    const run_abitest = b.addRunArtifact(abitest_exe);
    const abitest_step = b.step("abitest", "Run the Tier-C ABI conformance tests (core/abitest.zig)");
    abitest_step.dependOn(&run_abitest.step);
}
