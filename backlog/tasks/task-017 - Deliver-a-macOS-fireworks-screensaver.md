---
id: TASK-017
title: Deliver a macOS fireworks screensaver
status: To Do
assignee: []
created_date: '2026-09-15 19:14'
updated_date: '2026-09-21 19:06'
labels: []
milestone: m-8
dependencies: []
priority: low
type: task
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Parent task. Port fireworks.c's screensaver mode (bouncing/exploding rabbits, parallax starfield, its own state arrays separate from player[]) into the Zig core, then deliver it as a macOS screensaver. Must start with a spike evaluating delivery options, since embedding a full Godot runtime inside a ScreenSaverView subclass may not be viable — the likely fallback is a native Swift/Metal view linking the same Zig core and exported sprite atlases directly, bypassing Godot entirely for this delivery mechanism. Depends on Phase 3 (the Zig simulation core) being complete for the shared sim/RNG code — do not start until all Phase 3 tasks are Done.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The delivery spike task is complete and has produced a written recommendation before any screensaver-specific UI work begins
- [x] #2 fireworks.c's behavior is ported to the Zig core and verified against the C oracle
- [x] #3 The chosen delivery mechanism installs and runs as a real macOS screensaver via System Settings
<!-- AC:END -->
