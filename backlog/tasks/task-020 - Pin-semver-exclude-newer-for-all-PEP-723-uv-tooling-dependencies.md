---
id: TASK-020
title: Pin semver + exclude-newer for all PEP 723 uv tooling dependencies
status: To Do
assignee: []
created_date: '2026-09-21 20:27'
labels: []
dependencies: []
references:
  - 'https://github.com/pythoninthegrasses/jumpnbump/actions/runs/35649945194'
priority: medium
type: chore
ordinal: 65000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Several `tools/*.py` scripts are PEP 723 `uv run --script` files with unpinned third-party dependencies (bare package names, no lower-bound version and no `[tool.uv] exclude-newer` date). This lets `uv` silently resolve a different dependency version on every run/date, which is not reproducible over time.

Concretely today this affects `tools/build_sprite_atlas.py`, `tools/build_level_layers.py`, and `tools/build_app_icon.py` (all declare bare `dependencies = ["Pillow"]`) and `tools/render_music.py` (bare `dependencies = ["soundfile", "numpy"]`). It was diagnosed via a CI failure where `assets:sprites:check` and `assets:levels:check` reported committed PNG atlases not matching a fresh render — decoded pixels were identical, only the PNG's internal zlib/IDAT compression bytes differed, traced to an unpinned Pillow resolving non-reproducible encoder output across environments.

Other repos in this GitHub account already use a two-part convention for exactly this: a semver lower bound on each dependency (e.g. `"Pillow>=11.3.0"`) plus a `[tool.uv]` `exclude-newer = "<ISO8601 date>"` cutoff in the script's PEP 723 header, so `uv` always resolves the same locked version. That convention is absent from every script under `tools/` in this repo.

Note: pinning alone is a partial fix for the sprite/level atlas byte-for-byte check specifically — testing during triage showed the same Pillow version (12.3.0) can still produce non-identical compressed PNG bytes for identical pixels (suspected zlib/zlib-ng CPU-dependent codepath variance), so pinning closes the "which version resolves" gap but may not by itself make `assets:sprites:check` / `assets:levels:check` pass across machines. That check's own byte-vs-pixel comparison strategy is being handled separately; this task is scoped to the dependency-pinning convention itself, not to fixing those specific check tasks.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every tools/*.py PEP 723 script that declares third-party `dependencies` (currently build_sprite_atlas.py, build_level_layers.py, build_app_icon.py, render_music.py) pins each dependency with an explicit semver lower bound (e.g. `Pillow>=11.3.0`) instead of a bare package name
- [ ] #2 Every such script adds a `[tool.uv]` `exclude-newer` date cutoff in its PEP 723 header, matching the convention already used in this account's other repos (e.g. image_resizer.py)
- [ ] #3 Chosen version bounds and exclude-newer dates are documented (e.g. in the script header or a short note) explaining why that specific cutoff/version was picked
- [ ] #4 Re-running each pinned script resolves the same dependency versions on repeated invocations and across machines with network access to PyPI
- [ ] #5 PEP 723 scripts with no third-party dependencies (bootstrap.py, validate_game_boundary.py, validate_abi_exporter.py, test_validate_game_boundary.py, validate_abi_test_purity.py) are left unchanged unless they gain dependencies in the future
<!-- AC:END -->
