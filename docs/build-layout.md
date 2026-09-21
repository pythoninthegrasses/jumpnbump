# Build layout

This documents the target directory layout for the mid-port Jump'n'Bump tree and how
`core/`, `include/`, `extension/`, `game/`, and `tools/` fit together, plus the retained
legacy build. It's a forward-looking spec of the target shape, not a per-task rationale
ledger — the reasoning behind a specific decision lives in that decision's task record
under `backlog/tasks/`.

## Directory layout

```text
core/          Zig simulation: physics, collision, AI, particles, game loop
include/       jumpnbump.h — the frozen C ABI between core/ and its consumers
extension/     godot-cpp GDExtension shim, 1:1 forwarding to the C ABI
game/          Godot 4.7.1 project (simulation/ presentation/ platform/ content/)
screensaver/   native Swift/Metal fireworks screensaver, linking core/'s ABI directly
tools/         Python asset pipeline + boundary/purity validator scripts
third_party/   godot-cpp, vendored as a SHA-pinned git submodule

main.c, menu.c, filter.c, fireworks.c, sdl/, modify/, data/
               legacy SDL/C game, retained forever as the Tier-B/oracle reference
```

- **`core/`** — the deterministic Zig simulation core, ported line-for-line from `main.c`
  and differential-tested against it. Never links libc file I/O (outside asset loading),
  SDL, or Godot — see `docs/porting-playbook.md`'s "Core purity" rule.
- **`include/`** — `jumpnbump.h`, the frozen ABI boundary. `core/abi.zig` is the sole
  exporter of this surface; nothing else in `core/` may define a `jnb_*` symbol.
- **`extension/`** — the GDExtension shim linking `core/`'s ABI into Godot: a SConstruct
  build, `register_types.cpp` with standard godot-cpp init/terminate boilerplate, and a
  `JumpnbumpWorld : RefCounted` GDCLASS whose methods forward 1:1 to `jnb_*` calls with no
  game logic of its own. Depends on `third_party/godot-cpp` being vendored (done, `TASK-004`).
- **`game/`** — the Godot project, split into four layers (mirroring
  `~/git/neo_snake/game/`'s convention):
  - `simulation/` — the only layer allowed to reference the GDExtension class
  - `presentation/` — sprites, level layers, scoreboard rendering
  - `platform/` — input routing, settings persistence, app lifecycle
  - `content/` — data-driven config (palettes, tuning, audio manifests)

  A boundary-validator script fails `task check` if any script outside `simulation/`
  touches the GDExtension class (`TASK-014.01`).
- **`tools/`** — Python scripts converting original `.gob` sprites, PCX levels, and
  `.mod`/`.smp` audio into Godot-native PNG/OGG/WAV resources (`TASK-013`), plus the
  boundary/purity validators wired into `task check`
  (`validate_abi_test_purity.py`).
- **`third_party/godot-cpp`** — pinned to commit SHA `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`,
  no branch or tag in `.gitmodules` — the pin is the contract, bumped only by committing a
  new gitlink. See `extension/README.md` for the full rationale (no 4.7 tag exists upstream;
  `api_version=4.7` is an SCons option, not a checkout).
- **`screensaver/`** — a native Swift/Metal macOS `ScreenSaverView` (`TASK-017.03`) delivering
  `core/fireworks.zig`'s screensaver mode, linking `core/`'s Zig static library directly through
  `include/jumpnbump.h`'s `jnb_fireworks_*` group — the same header `extension/`'s GDExtension
  shim consumes, but with zero Godot involvement (`backlog/decisions/decision-001`). Reads
  `game/content/sprites/*.json`'s already-exported atlases and `data/level.pcx`'s palette
  directly; no `.tres`/`AtlasTexture` resources, those are Godot-specific. A SwiftPM package
  (`Package.swift`), not an Xcode project — see its own README for the package layout and the
  `build.sh` step that links it into a `.saver` bundle.
- **Legacy tree** (`main.c`, `sdl/`, `modify/`, `data/`) — retained forever, never deleted.
  It's the Tier-B differential-test oracle (`docs/porting-playbook.md`); any behavioral
  drift in the port shows up as a failing diff against it.

## Build systems

Four build systems are siblings — none absorbs another:

- **`core/build.zig`** — scoped to `core/`, not the repo root.
- **`extension/SConstruct`** — godot-cpp's SCons build, linking the Zig static lib via
  `env.File(...)` so a core rebuild triggers a relink (never a bare `-l`/`-L` flag)
  (`TASK-012.04`).
- **`screensaver/Package.swift` + `screensaver/build.sh`** — SwiftPM builds the `FireworksKit`
  library (and its `swift test` suite); `build.sh` then links it, `core/zig-out/lib/libjumpnbump.a`,
  and the compiled Metal shader into the `.saver` bundle SwiftPM alone can't produce
  (`TASK-017.03`).
- **The legacy top-level `Makefile`** — unchanged, still the only way to build the SDL
  binary, `gobpack`/`jnbpack`/`jnbunpack`, and `data/jumpbump.dat` (`task legacy:build`,
  TASK-015.05 — no longer part of the default `task check` gate).

`taskfile.yml` is the single entry point above all four, via `taskfiles/core.yml`
(`zig build abi`), `taskfiles/extension.yml` (the SCons build, vendoring
`third_party/godot-cpp` on demand), `taskfiles/game.yml`, and `taskfiles/screensaver.yml`
(darwin-only, not part of `task check` — see that section below). `task run` chains
`extension:build` then `game:run` as the one-shot way to play the Godot build from a
clean clone.

## `zig build` steps

Defined in `core/build.zig`. Zig 0.16.0-specific notes worth not rediscovering: there is no
`b.addStaticLibrary` — static libraries go through
`b.addLibrary(.{ .linkage = .static, ... })`; `Module.linkLibrary` lives on the module, not
on `Build.Step.Compile`.

- **`test`** — Tier-A unit tests. Iterates `unit_test_files`, currently empty; each
  `TASK-011.*` port appends its module's test file.
- **`difftest`** — Tier-B differential tests: compiles the pre-port `.c` a second time with
  preprocessor-renamed symbols (zelda3's `compileRenamedCRef` technique, ported into
  `core/build.zig`), links it against the Zig port, and replays the `TASK-008` corpus,
  diffing checksums per tick. Iterates `diff_test_files`, which holds `rnd_difftest.zig`
  (`TASK-008.04`'s trivial passthrough pilot — no real per-tick corpus replay yet, since
  that needs an actual ported module's state; real entries land as `TASK-011.*` ports do).
- **`abi`** — builds `core/abi.zig` as a static library named `jumpnbump`, `.pic = true`
  (Zig library code, positioned for a later `ld -shared` step — matches neo_snake's
  convention, since non-PIC relocations in a static archive fail there). Installs the
  artifact.
- **`abitest`** — Tier-C ABI conformance suite, links `abi_lib` via `Module.linkLibrary`.
  Once `include/jumpnbump.h` exists (`TASK-012.01`), reaches `core/abi.zig` exclusively
  through `@cImport`, never by importing core Zig modules directly — enforced separately by
  `tools/validate_abi_test_purity.py`.

## `task check` wiring

Today: `check` runs `make` (the legacy build) — the only gate that exists yet.

Target ordering, cheapest static check first:

1. `core:test` (Tier-A)
2. `core:abi-header-check` — `zig cc -std=c11 -c core/abi_header_check.c -o /dev/null`,
   proving `include/jumpnbump.h` compiles standalone with zero warnings
3. `core:abi-symbols` — `zig build abi` (runs `core/localize_abi_symbols.py`'s post-link
   `objcopy --keep-global-symbols` pass), then `nm -g --defined-only` on the built
   `libjumpnbump.a`, asserting every symbol matches `^_?jnb_`
4. `core:abi-exporter-purity` — `tools/validate_abi_exporter.py`, a source-level check
   that no `core/*.zig` file other than `core/abi.zig`/`core/abi_globals.zig` defines a
   `jnb_`-prefixed export (faster-failing than #3, though #3 alone is sufficient)
5. `core:abitest-purity` — the `@cImport`-only enforcement script
6. `core:abitest` (Tier-C)
7. `core:difftest` (Tier-B)
8. The Godot/gdUnit4 Tier-D replay step (Phase 5)

Each step lands as its owning task completes; `check` is only extended, never reordered
around a step that doesn't exist yet.

`screensaver:build`/`screensaver:test` (`taskfiles/screensaver.yml`, `TASK-017.03`) are
deliberately **not** part of `check` — `check` is the gate expected to run on every CI platform,
and the screensaver is darwin-only, `platforms: [darwin]`, same treatment as `release:*`.

## Toolchain

Pinned in `.tool-versions`, resolved via mise:

- `zig 0.16.0`
- `godot 4.7.1-stable`
- `pipx:scons 4.11.1`
- `python 3.13.14`, `uv 0.11.32`, `ruff 0.15.20`
- `task 3.49.1`, `prek 0.3.2`, `node 24.12.0`

`taskfile.yml` prepends `~/.local/share/mise/shims` ahead of the system `PATH` so pinned
versions always win, and sets `ZIG_GLOBAL_CACHE_DIR` to a repo-local
`.cache/zig` directory rather than the user cache.

## macOS release (TASK-009)

`task release:ship-macos` turns a clean checkout into a signed, notarized, stapled
`game/build/macos/Jump'n'Bump.dmg`. It runs, in order: `keychain-setup` (imports the Developer
ID certificate into an ephemeral keychain), `export-macos` (builds the release GDExtension
framework and headlessly exports+signs via Godot), `verify-signing`, `decode-api-key`,
`notarize` (submits, staples, then asserts Gatekeeper acceptance). `keychain-cleanup` and
`cleanup-api-key` are registered via Task's `defer:`, so both run even if an earlier step
fails — confirmed by forcing a mid-pipeline export failure and checking `security
list-keychains` no longer lists the ephemeral keychain afterward.

Credentials (`APPLE_SIGNING_IDENTITY`, `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`,
`KEYCHAIN_PASSWORD`, `APPLE_API_KEY_B64`, `APPLE_API_KEY`, `APPLE_API_ISSUER`) come from `.env`
(loaded automatically by the root `taskfile.yml`'s `dotenv: ['.env']` — no need to `source` it
yourself), never committed; see `.env.example`. The signing identity string in
`game/export_presets.cfg`'s `codesign/identity` is **not** treated as a secret — it's a Common
Name embedded in every signed binary regardless — only the certificate, its password, and the
API key are env-only.

**GDExtension architecture is arm64-only; the export preset's engine architecture is
`universal`.** `core/build.zig` and `extension/SConstruct` only ever build for the host arch
(`task extension:build-macos` builds `libjumpnbump.macos.template_debug.framework` and
`.../template_release.framework`, both arm64). Godot 4.7's macOS export templates, however,
ship only a `universal` (arm64+x86_64 fat) engine binary — there is no arm64-only template to
select, so `game/export_presets.cfg`'s `binary_format/architecture` must be `"universal"` or
export fails with "Requested template binary godot_macos_release.arm64 not found". The
resulting `.app`'s main engine executable is genuinely universal; the embedded GDExtension
`.framework` is not. It dlopens the arm64 slice fine on Apple Silicon; it would fail to load
under Rosetta on Intel Macs. A true universal build is future work (cross-compile `core/`
for `x86_64-macos` via a second `-Dtarget` pass, `lipo` the two static libs, build the
extension twice and `lipo` the two framework binaries).

**Export templates must be extracted, not just downloaded.** `~/Library/Application
Support/Godot/export_templates/4.7.1-stable/macos.zip` is downloaded by mise/the editor but
not auto-extracted; `godot --headless --export-release` fails to find the template binary
until `macos.zip` is unzipped in place (one-time, per-machine, not something `task` provisions).

**Signing hosts reached only over SSH need a `launchctl asuser` bridge** (mirrors
`~/git/neo_snake`'s TASK-044/decision-027). macOS's Security framework won't release an
imported private key to a process outside the GUI console login session's audit/bootstrap
namespace, and a bare SSH session is always outside it. `export-macos` wraps its `godot`
invocation in `sudo launchctl asuser "$(id -u)" ...` to re-attach into that namespace before
signing starts, and routes the DMG's ownership fix (`launchctl asuser` keeps root's EUID)
through the identical invocation so one narrowly-scoped sudoers.d entry covers both:
`lance ALL=(root) NOPASSWD: /bin/launchctl asuser *`. That entry must be installed directly by
a human with sudo access — an agent must never be given or asked for a sudo password — so it's
a manual, one-time signing-host prerequisite, not something `task release:ship-macos`
provisions itself. It's a no-op wrapper on a machine driven from a real console session.

**`verify-signing` mounts the exported DMG.** Godot's DMG export mode builds and signs the
`.app` inside a private temp directory and never leaves a loose bundle under
`game/build/macos/` — only the final signed `.dmg`. `verify-signing` mounts it read-only via
`hdiutil attach -nobrowse -readonly`, verifies the embedded
`libjumpnbump.macos.template_release.framework` directly (it's `dlopen`'d at runtime, so
`codesign --verify --deep --strict` on the `.app` alone doesn't walk into it) plus its
hardened-runtime flag, then the `.app`'s own nested signatures, then the DMG's own signature,
and always detaches the mounted volume via a `trap ... EXIT` regardless of which check fails.

Confirmed end to end against live Apple infrastructure on `mini`: real notarization (Accepted),
real stapling, `spctl -a -vv --type open --context context:primary-signature` reporting
`accepted` / `source=Notarized Developer ID`, both the `.framework` and `.app` independently
verified signed with the hardened-runtime flag set.

A recurring, benign warning during export — `"libjumpnbump.macos.template_release.framework":
Info.plist missing or invalid, new Info.plist generated` — is expected and not chased:
`extension/SConstruct`'s macOS branch deliberately builds a flat framework directory with no
`Contents/Info.plist` (that nesting is only required for *dependency* frameworks), and Godot
regenerates one at export time regardless.

## macOS screensaver signing (TASK-017.04)

`task release:ship-screensaver` is the `.saver`-bundle counterpart to `ship-macos`, kept in
`taskfiles/release.yml` (not `taskfiles/screensaver.yml`) so it can call
`keychain-setup`/`keychain-cleanup`/`decode-api-key`/`cleanup-api-key` directly rather than
reaching across a Task namespace — those four steps are fully generic and reused as-is, no
Godot/DMG coupling. It runs, in order: `keychain-setup`, `sign-screensaver` (builds
`JumpnbumpFireworks.saver` via `screensaver:build`, ad hoc-signed by `screensaver/build.sh`,
then re-signs it with `APPLE_SIGNING_IDENTITY` and `--options runtime`), `verify-screensaver-signing`,
`decode-api-key`, `notarize-screensaver`. `keychain-cleanup` and `cleanup-api-key` run via
`defer:`, same LIFO teardown order as `ship-macos`.

Three differences from the Godot `.app`/DMG pipeline, all following from `decision-001`
(native Swift/Metal, no Godot involvement) and TASK-017.03's own research:

- **No DMG mount.** `verify-screensaver-signing` runs `codesign --verify --strict` and the
  hardened-runtime flag check directly against the `.saver` bundle. `libjumpnbump.a` is
  statically linked into the bundle's own binary (`screensaver/build.sh`'s `swiftc -all_load`
  link), so there's no nested framework to check separately the way `export-macos`'s embedded
  GDExtension `.framework` needs.
- **No `launchctl asuser` bridge.** `sign-screensaver`'s `codesign` call isn't nested inside
  another tool's own shell-out (unlike Godot's internal signing during `export-macos`), so it
  inherits the calling shell's security-session context directly — the same reasoning
  `verify-signing`'s plain `codesign` calls already rely on. No sudoers prerequisite needed for
  this pipeline even over SSH.
- **The bundle is zipped for submission, then stapled directly.** `notarytool` can't accept a
  bare `.saver` bundle, so `notarize-screensaver` wraps it first via `ditto -c -k --keepParent`.
  `stapler staple` and the final `spctl -a -vv --type install` Gatekeeper check then run against
  the `.saver` bundle itself, not the zip — `--type install` is the assessment type for a
  loadable bundle, where `notarize`'s own `--type open` is for something the user double-clicks
  to launch.

Not wired into CI (same treatment as `release:*`): the self-hosted macOS runner's Xcode/credentials
situation for this path is untested, and `ci:macos-check` stays the CI entrypoint gate.

Confirmed end to end against live Apple infrastructure: real notarization (Accepted), real
stapling, `spctl -a -vv --type install` reporting `accepted` / `source=Notarized Developer ID`,
and `codesign --display --verbose=4` on the stapled bundle showing `flags=0x10000(runtime)` under
a `Developer ID Application` authority chain.

## Constraints

- **No allocator, no libc in `core/` library code**, outside `core/abi.zig` — this is a
  property of the ported simulation code itself, not something `build.zig` can assert.
  `core/abi.zig` is the deliberate exception: it is the FFI boundary and owns
  caller-provided memory.
- **`include/jumpnbump.h` may only be exported from `core/abi.zig`.** No other `core/*.zig`
  file may define a symbol matching the frozen ABI surface.
- **One build graph.** Future `core/*.zig` files extend the existing `core/build.zig`
  rather than inventing a second one.
