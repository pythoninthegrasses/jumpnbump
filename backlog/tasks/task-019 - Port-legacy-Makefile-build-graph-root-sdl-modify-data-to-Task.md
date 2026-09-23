---
id: TASK-019
title: Port legacy Makefile build graph (root + sdl/modify/data) to Task
status: Done
assignee: []
created_date: '2026-09-21 20:13'
updated_date: '2026-09-22 22:13'
labels:
  - build
  - legacy
  - task-migration
dependencies: []
modified_files:
  - taskfiles/legacy.yml
  - Makefile
  - sdl/Makefile
  - modify/Makefile
  - data/Makefile
  - docs/build-layout.md
  - docs/porting-playbook.md
  - AGENTS.md
  - README.md
priority: medium
ordinal: 64000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The legacy SDL build (`jumpnbump`, `gobpack`/`jnbpack`/`jnbunpack`, `sdl.a`, packed `data/jumpbump.dat`) is still driven by GNU Make: the root `Makefile` plus sub-Makefiles in `sdl/`, `modify/`, and `data/`. Everything else in this repo (Godot game, Zig core, GDExtension, screensaver, asset pipeline, CI orchestration) is already driven by `taskfile.yml`/`taskfiles/*.yml`, with `taskfiles/legacy.yml:build` currently just shelling out to `make`.

The intent is to retire `make` from this repo entirely and express the same build graph (compile `sdl.a`, compile `modify/`'s `gobpack`/`jnbpack`/`jnbunpack`, pack `data/jumpbump.dat` via `jnbpack`, compile+link the `jumpnbump` binary, substitute `globals.pre`/`jnbmenu.pre` templates) as Task targets, so a fresh clone never needs a `make` toolchain.

This was surfaced while setting up local CI testing (`act` via mise, TASK unrelated) after finding and fixing a real link-order bug in the root Makefile (`$(SDL_TARGET)` must precede `$(LIBS)` in the final link command since `sdl.a`'s `sound.o` is what references `-lSDL_mixer`'s symbols, and GNU ld's single-pass resolution drops them otherwise -- fixed directly in the Makefile in the interim, both locally via `act -j linux -W .github/workflows/ci.yml` and confirmed against the real GitHub Actions failure history). That fix should carry over correctly to the ported Task version (i.e. don't reintroduce the wrong link order).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 taskfiles/legacy.yml's build task (and any new task(s) it's split into) reproduce every artifact the current `make all` produces (jumpnbump, gobpack, jnbpack, jnbunpack, jumpnbump.svgalib, jumpnbump.fbcon, jnbmenu.tcl, sdl.a, data/jumpbump.dat) without invoking `make`
- [x] #2 The link order in the ported build keeps sdl.a's object files ahead of -lSDL_mixer/-lSDL_net/-lbz2/-lz on the final link command, verified by a from-clean build succeeding on both macOS and Linux
- [x] #3 task legacy:build (or its replacement) passes locally via `act -j linux -W .github/workflows/ci.yml` and on a real macOS run
- [x] #4 The root Makefile and sdl/, modify/, data/ sub-Makefiles are removed once the Task-based build is verified equivalent
- [x] #5 docs/build-layout.md is updated to describe the Task-based legacy build instead of referencing make
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Ported the legacy root/`sdl/`/`modify/`/`data/` Makefiles' build graph into `taskfiles/legacy.yml` as Task tasks (`globals-h`, `jnbmenu-tcl`, `sdl-a`, `modify`, `data`, `build`, `clean`) using freshness-checked `sources`/`generates` and `deps` (not inline `task:` calls, which caused a checksum chicken-and-egg bug where a task's own sources included a file its own cmds generated). `task legacy:build` reproduces every artifact `make all` did (jumpnbump, gobpack, jnbpack, jnbunpack, sdl.a, data/jumpbump.dat, globals.h, jnbmenu.tcl; jumpnbump.svgalib/jumpnbump.fbcon are static checked-in wrapper scripts, never build outputs). The critical link-order fix (sdl.a ahead of -lSDL_mixer/-lSDL_net/-lbz2/-lz) carried over correctly. `sdl-config`-dependent vars (SDL_CFLAGS/SDL_LIBS) had to be scoped to the specific tasks that need them rather than file-level, since file-level vars in an included Taskfile evaluate eagerly and broke a fresh Linux CI runner (sdl-config not yet installed when ci:linux-check starts). Verified via `act -j linux --container-architecture=linux/amd64` (56/56 tests, job succeeded) and a real `task ci:macos-check` run. Removed the four Makefiles and updated docs/build-layout.md, docs/porting-playbook.md, AGENTS.md, and README.md to stop referencing `make`.
<!-- SECTION:FINAL_SUMMARY:END -->
