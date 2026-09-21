# Jump'n'Bump Fireworks screensaver

TASK-017.03: delivers `core/fireworks.zig`'s ported fireworks mode (bouncing/exploding
rocket-rabbits over a scrolling parallax starfield) as a native macOS `.saver` bundle —
`backlog/decisions/decision-001`'s chosen delivery mechanism, a Swift/Metal
`ScreenSaverView` linking `core/`'s Zig static library directly through
`include/jumpnbump.h`. No Godot involvement at all.

## Layout

- `Package.swift` — SwiftPM package: `CJumpnbump` (a system-library wrapper around
  `../include/jumpnbump.h`) and `FireworksKit` (the actual screensaver logic and view,
  linked against `../core/zig-out/lib/libjumpnbump.a`), plus its `FireworksKitTests` suite.
- `Sources/FireworksKit/` — atlas/palette decoding, the software framebuffer compositor,
  the `FireworksSimulation`/`FireworksSimulationCoordinator` ABI wrapper, and
  `JNBFireworksView`, the actual `ScreenSaverView` subclass.
- `Sources/FireworksShaders/fireworks.metal` — the one full-screen nearest-neighbour quad
  shader. Compiled separately by `build.sh` (`xcrun metal`/`metallib`), not by SwiftPM —
  SwiftPM has no native Metal shader build step.
- `Tests/FireworksKitTests/` — the real TDD surface; `swift test` (`task screensaver:test`).
- `Resources/Info.plist.in` — the `.saver` bundle's `Info.plist` template (`NSPrincipalClass`
  = `JNBFireworksView`).
- `build.sh` — assembles `.build/JumpnbumpFireworks.saver`.
- `host/main.swift` — a tiny dev harness that loads the built `.saver` bundle the same way
  System Settings does (`NSBundle` + `NSPrincipalClass`) and hosts the view in a plain
  window, so the animation can be eyeballed without touching System Settings at all
  (`task screensaver:host`).

## Building and installing

```sh
task screensaver:build     # -> screensaver/.build/JumpnbumpFireworks.saver
task screensaver:test      # swift test
task screensaver:host      # visual check in a plain window
task screensaver:install   # copies into ~/Library/Screen Savers
task screensaver:uninstall
```

After `task screensaver:install`, open System Settings > Screen Saver — "Jump'n'Bump
Fireworks" should appear and preview. macOS may require an explicit Gatekeeper allow on
first load for an ad hoc-signed bundle (`build.sh` signs with `codesign --sign -`); proper
Developer ID signing/notarization is TASK-017.04, deliberately out of scope here per
`decision-001`'s Consequences section.

## Design notes

- **No `.tres`/`AtlasTexture`, no Godot project involvement whatsoever.** `FireworksKit`
  reads `game/content/sprites/rabbit_atlas.{png,json}` and `objects_atlas.{png,json}`
  directly (`Atlas`/`AtlasImage`) and decodes `data/level.pcx`'s palette at runtime via the
  existing `jnb_pcx_palette_decode` ABI call (`Palette`) — the same PNG/JSON atlases
  `game/`'s own presentation layer consumes, TASK-013.01's committed output.
- **Known deviation**: the committed atlases were baked against `menu.pcx`'s palette
  (`tools/build_sprite_atlas.py`'s `PALETTE_SOURCE`), but fireworks mode runs under
  `level.pcx`'s in the original. A handful of gob palette indices differ between the two
  (index 1, and 178..182) — a few sprite pixels render at a very slightly different shade
  than the original C. Stars and the horizon gradient are unaffected (`level.pcx`'s palette
  is read live, not baked). Accepted as-is; see the TASK-017.03 backlog record for the
  decision.
- **Shared-singleton discipline.** `include/jumpnbump.h`'s file header documents that at
  most one `jnb_fireworks_*` instance is meaningful per process. System Settings can host
  several `ScreenSaverView` previews concurrently in its picker UI (one process). Every live
  `JNBFireworksView` acquires/releases `FireworksSimulationCoordinator.shared` instead of
  owning its own `FireworksSimulation`; the coordinator advances the shared clock by at most
  one real-time step per call window and hands every concurrent caller the identical latest
  composed frame, rather than letting two views double-pump the same simulation.
- **Rendering**: a software 400x256 RGBA8 `Framebuffer` is composed once per tick (clear,
  `fireworks.c`'s own horizon gradient, stars, then every rabbit/gore draw event in
  tick-produced order) and presented as one nearest-neighbour, integer-scaled, letterboxed
  Metal quad (`PresentationGeometry`) — no per-sprite GPU draw calls, so the composition
  logic stays fully unit-testable without a GPU.
- **Golden checksum parity with Tier-C.** `core/abitest.zig` and
  `Tests/FireworksKitTests/FireworksSimulationTests.swift` both pin the identical
  `jnb_fireworks_stars_copy` checksum after 600 ticks from seed `0xC0FFEE`
  (`0x3ae19a6a`) — the two sides of the ABI can never silently drift apart on
  determinism. If that value ever needs to change, both files change together, in the same
  commit.
