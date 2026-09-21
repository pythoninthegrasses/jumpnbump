---
id: TASK-019
title: Port legacy Makefile build graph (root + sdl/modify/data) to Task
status: To Do
assignee: []
created_date: '2026-09-21 20:13'
labels:
  - build
  - legacy
  - task-migration
dependencies: []
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
- [ ] #1 taskfiles/legacy.yml's build task (and any new task(s) it's split into) reproduce every artifact the current `make all` produces (jumpnbump, gobpack, jnbpack, jnbunpack, jumpnbump.svgalib, jumpnbump.fbcon, jnbmenu.tcl, sdl.a, data/jumpbump.dat) without invoking `make`
- [ ] #2 The link order in the ported build keeps sdl.a's object files ahead of -lSDL_mixer/-lSDL_net/-lbz2/-lz on the final link command, verified by a from-clean build succeeding on both macOS and Linux
- [ ] #3 task legacy:build (or its replacement) passes locally via `act -j linux -W .github/workflows/ci.yml` and on a real macOS run
- [ ] #4 The root Makefile and sdl/, modify/, data/ sub-Makefiles are removed once the Task-based build is verified equivalent
- [ ] #5 docs/build-layout.md is updated to describe the Task-based legacy build instead of referencing make
<!-- AC:END -->
