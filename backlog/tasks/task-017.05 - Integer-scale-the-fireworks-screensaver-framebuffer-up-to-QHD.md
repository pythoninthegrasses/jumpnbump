---
id: TASK-017.05
title: Integer-scale the fireworks screensaver framebuffer up to QHD
status: To Do
assignee: []
created_date: '2026-09-21 19:07'
labels: []
milestone: m-8
dependencies: []
parent_task_id: TASK-017
priority: low
type: enhancement
ordinal: 63000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-017.03 renders fireworks mode into a fixed 400x256 software framebuffer (screensaver/Sources/FireworksKit/Framebuffer.swift), presented via one nearest-neighbour Metal quad computed by PresentationGeometry (screensaver/Sources/FireworksKit/PresentationGeometry.swift). PresentationGeometry already picks the largest integer scale that fits both view dimensions and letterboxes the remainder, so on a QHD (2560x1440) display it currently scales to 5x (2000x1280) and letterboxes ~280px on each side/top-bottom -- correct behavior, but a visibly small margin at that specific resolution, and worth confirming (or tuning) deliberately rather than leaving as an untested side effect.

This task is about verifying and, if needed, improving that experience specifically at QHD (and other display sizes between exact integer multiples): confirm PresentationGeometry's scale/letterbox choice looks right on a real QHD display when run via `task screensaver:host` or installed via `task screensaver:install`, and decide whether the letterboxing is acceptable as-is or whether a different strategy (e.g. allowing a non-integer "fill" scale as a fallback when the letterbox margin exceeds some threshold, matching fireworks.c's own borderless full-screen feel more closely) is worth adding.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The screensaver's letterboxing/scaling behavior is verified on an actual QHD (2560x1440) display via task screensaver:host or a real screensaver preview/full-screen run
- [ ] #2 A decision is recorded (in this task or a short doc note) on whether pure integer-scale-with-letterbox stays the policy at QHD or whether PresentationGeometry gains a fallback for large letterbox margins
- [ ] #3 If PresentationGeometry changes, PresentationGeometryTests.swift covers the new QHD-relevant case(s)
<!-- AC:END -->
