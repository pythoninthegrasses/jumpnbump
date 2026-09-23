# Jump'n'Bump

Cute fluffy bunnies hop on each other's heads. Whoever bumps the most heads wins. Local
multiplayer (up to 4 players, human or AI, any mix), custom levels, and UDP netplay (legacy
build only, see below). Originally released by Brainchild Design in 1998; this fork is a
Linux/SDL port from 2004 that's been re-platformed onto a Zig simulation core rendered by
Godot.

## Status

The Godot build is now the primary, fully playable way to run Jump'n'Bump: a Zig simulation
core (`core/`) is exposed to Godot through a frozen C ABI (`include/jumpnbump.h`) and a
GDExtension shim (`extension/`), and `game/` wires that up into a full title -> menu ->
gameplay -> scores -> menu flow with 4-local-player input (keyboard + gamepad, remappable),
persisted settings, and pause/clean-quit handling.

The legacy SDL 1.2 C build (`main.c`, `sdl/`, `modify/`, `data/`) is kept in the repo
forever, not as a second way to play, but as the differential-test oracle the Zig core is
checked against frame-by-frame (see `docs/porting-playbook.md`) -- see "The legacy SDL
build (oracle)" below if you need to build or run it.

See `backlog/tasks/` for per-task status and `docs/porting-playbook.md` /
`docs/build-layout.md` for the full architecture.

## Playing it (Godot build)

Requires the pinned Godot version (see `.tool-versions`, installed via `mise`) available on
`PATH` as `godot`.

```sh
task run    # fetch git submodules, build the core ABI + GDExtension shim, launch the game
```

`task check` runs the boundary + test gates for the Godot build and the asset pipeline.
`task deps`/`task submodules` fetches just the git submodules (`third_party/godot-cpp`) on
their own; `task game:run` launches the game without rebuilding anything.

### Controls

Local multiplayer defaults (remappable in-game from the player-select menu):

| Player | Keys |
| --- | --- |
| Dott | arrow keys (left/right/up) |
| Jiffy | `a`, `d`, `w` |
| Fizz | `j`, `l`, `i` |
| Mijji | numpad `4`, `6`, `8` |

A gamepad can also control a player (left stick or d-pad to move, face button to jump).
Window size/fullscreen and mouse input are handled by Godot itself, not a custom flag.

### Custom levels, screensaver, and netplay

These are legacy-build-only for now (TASK-016/017 track porting them to the Godot build):

```sh
jumpnbump -dat levelname.dat            # load a custom level (see levelmaking/)
jumpnbump -fireworks -fullscreen        # fireworks screensaver mode

# netplay (UDP), same -dat level on every peer:
jumpnbump -port 7777 -net 0 <host_of_player2> <port_of_player2>   # player 1
jumpnbump -port 7777 -net 1 <host_of_player1> <port_of_player1>   # player 2
# -net 2/-net 3 add a 3rd/4th player the same way
```

## The legacy SDL build (oracle)

Not part of the default `task check` gate (TASK-015.05) -- build it on demand with
`task legacy:build` (`taskfiles/legacy.yml`, TASK-019 -- no `make` toolchain required).
Requires SDL 1.2, SDL_mixer, SDL_net, zlib, and bzip2 dev packages. Debian/Ubuntu:

```sh
apt-get install libsdl1.2-dev libsdl-mixer1.2-dev libsdl-net1.2-dev zlib1g-dev libbz2-dev
```

(macOS: see `taskfiles/ci.yml`'s `ci:_install-macos-deps` for the Homebrew + from-source
SDL_mixer/SDL_net setup used in CI.)

```sh
task legacy:build
./jumpnbump
```

`task legacy:clean` cleans `sdl/`, `modify/`, `data/`, and the top-level objects/binaries.
Its controls, custom-level, screensaver, and netplay flags/instructions are in the section
above; `f10` toggles windowed/fullscreen, `esc`/`f12` quits.

## Building and testing

`task check` is the single documented gate: it runs the Godot build's boundary check
(`task game:boundary-check`) and test suite (`task game:test`), plus the asset pipeline's
reproducibility gates (`task assets:check`). `taskfiles/ci.yml` wires
`task ci:linux-check`/`task ci:macos-check` into GitHub Actions for both platforms; both
also verify the legacy oracle still builds (`task legacy:build`) before running `task check`.

`core/build.zig` defines the Zig side, run from `core/` (`zig build <step>`):

- `test` — Tier-A unit tests for ported modules
- `difftest` — Tier-B differential tests against the legacy C oracle
- `abi` — builds `core/abi.zig` as a static library
- `abitest` — Tier-C ABI conformance tests

`task game:test` runs `game/tests/` headlessly through gdUnit4 (Tier-D, TASK-014.07).

## Architecture

| Path | Purpose |
| --- | --- |
| `core/` | Zig simulation core: physics, collision, AI, particles, game loop |
| `include/` | `jumpnbump.h`, the frozen C ABI between `core/` and `extension/` |
| `extension/` | godot-cpp GDExtension shim, forwarding 1:1 to the C ABI |
| `game/` | Godot 4.7.1 project -- the primary way to play |
| `tools/` | Asset pipeline + boundary/purity validator scripts |
| `main.c`, `sdl/`, `modify/`, `data/` | Legacy SDL/C game — retained forever as the differential-test oracle |

The legacy C tree isn't dead code to delete once the port lands: it's what the new Zig
simulation core is checked against frame-by-frame, so behavioral drift in the port shows up
as a failing diff rather than a silent regression. See `docs/build-layout.md` for the full
layout and `docs/porting-playbook.md` for the porting procedure and verification tiers.

## Credits

Original DOS game by Brainchild Design — see `readme.txt`. Linux/SDL port credits and the
upstream 2004 README are preserved in `docs/legacy-readme.md`.
