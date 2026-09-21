---
id: TASK-017.05
title: Integer-scale the fireworks screensaver framebuffer up to QHD
status: Done
assignee: []
created_date: '2026-09-21 19:07'
updated_date: '2026-09-21 19:47'
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
- [x] #1 The screensaver's letterboxing/scaling behavior is verified on an actual QHD (2560x1440) display via task screensaver:host or a real screensaver preview/full-screen run
- [x] #2 A decision is recorded (in this task or a short doc note) on whether pure integer-scale-with-letterbox stays the policy at QHD or whether PresentationGeometry gains a fallback for large letterbox margins
- [x] #3 If PresentationGeometry changes, PresentationGeometryTests.swift covers the new QHD-relevant case(s)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Verified via a screen recording of the fireworks screensaver running full-screen on a real QHD (2560x1440) display (~/Desktop/jumpnbump_screensaver.mp4, provided by Lance). Extracted frames with ffmpeg (fps=3, scale=-1:800) to /tmp scratch and reviewed them directly.

Confirms PresentationGeometry's computed 5x scale (2000x1280, destX=280, destY=80) matches what's on screen: symmetric black letterbox bars, wider on left/right (~280px, ~11% of width) than top/bottom (~80px, ~5.5% of height). Fireworks and stars render crisply with no visible scaling artifacts; the letterboxing reads as intentional framing, not a bug -- comparable to how other pixel-art-precise macOS screensavers present a fixed-aspect canvas.

Decision: keep pure integer-scale-with-letterbox as policy. Do not add a non-integer "fill" fallback for large margins. Reasons:
- Matches the deliberate crisp-pixel-art convention already established in game/ (TASK-014.04); a fill fallback would reintroduce non-integer scaling blur exactly where this codebase has chosen to avoid it elsewhere.
- The QHD margin, while the largest of common desktop resolutions tested against, is not visually distracting in the recording -- it reads as letterboxing, not as "broken" full-screen coverage.
- Task is low priority polish; no reported/observed problem beyond "worth confirming deliberately," which this verification satisfies.

No PresentationGeometry.swift change made, so AC #3 (test coverage for a geometry change) does not apply.

Prototyping an anisotropicFill alternative per Lance's follow-up: PresentationGeometry now takes a FillMode (.uniform default, .anisotropicFill new) that scales X and Y independently -- scaleX=6, scaleY=5 at QHD (2400x1280, 80px margins each side, down from the uniform mode's 280px/80px asymmetric margins) -- still nearest-neighbor crisp, no blur, but pixels are non-square so sprites stretch ~20% wider than tall. JNBFireworksView.animateOneFrame is temporarily wired to .anisotropicFill for a real on-device QHD comparison; revert to the default .uniform arg (or drop the fillMode arg entirely) if the stretch reads as worse than the uniform letterbox. Added PresentationGeometryTests coverage for both axes and the both-axes-agree case. Decision (AC #2) is reopened pending Lance eyeballing this on the real QHD display via `task screensaver:host`.

Final decision: anisotropicFill is the shipped policy, not uniform-with-letterbox. Verified via `task screensaver:host` at QHD (2560x1440) -- System Settings' Screen Saver pane (`task screensaver:install`) turned out to be unreliable for this comparison, caching the previously-loaded .saver bundle across a process it respawns (killing legacyScreenSaver.appex/Screen Saver.appex didn't clear it; a fresh, byte-identical install still rendered stale). Confirmed the installed binary was in fact fresh (cmp against host's build: identical) before ruling out install as the verification path and using host instead. JNBFireworksView now passes fillMode: .anisotropicFill; PresentationGeometry.FillMode.uniform stays the default for other callers/tests. AC #3 satisfied by the two new PresentationGeometryTests cases added earlier in this task.
<!-- SECTION:NOTES:END -->
