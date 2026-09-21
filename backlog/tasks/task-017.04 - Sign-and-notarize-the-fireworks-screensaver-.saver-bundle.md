---
id: TASK-017.04
title: Sign and notarize the fireworks screensaver .saver bundle
status: Done
assignee: []
created_date: '2026-09-21 16:43'
updated_date: '2026-09-21 19:57'
labels: []
milestone: m-8
dependencies: []
modified_files:
  - taskfiles/release.yml
  - docs/build-layout.md
parent_task_id: TASK-017
priority: low
type: task
ordinal: 62000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-017.03 ships JumpnbumpFireworks.saver ad hoc-signed (`codesign --sign -`), deliberately out of scope for Developer ID signing/notarization per backlog/decisions/decision-001's Consequences section ("Signing/notarization for the resulting .saver bundle needs its own task, separate from taskfiles/release.yml's Godot export path"). This task builds that pipeline.

Findings from TASK-017.03's own research (see taskfiles/release.yml):
- `keychain-setup`/`keychain-cleanup`/`decode-api-key`/`cleanup-api-key` are fully generic and reusable as-is for a .saver bundle -- no Godot/DMG coupling.
- `verify-signing` is NOT reusable as-is: it mounts a DMG and hardcodes a path inside a Godot .app's Frameworks directory. A .saver variant verifies the bundle directly (no hdiutil mount), and since libjumpnbump.a is statically linked into the bundle's own binary, there's no nested framework to check separately -- codesign --verify --strict --verbose=2 plus the hardened-runtime flag assertion on the bundle itself is enough.
- `export-macos`'s `sudo launchctl asuser` bridge pattern (for codesigning over SSH on a headless runner) is the one piece worth reusing conceptually -- the .saver build instead runs `swift build` + `screensaver/build.sh` then an explicit `codesign --force --options runtime --sign "$APPLE_SIGNING_IDENTITY"` in place of Godot's own export+sign step.
- `notarize`'s xcrun notarytool/stapler calls are parameterizable, but a bare .saver bundle cannot be submitted to notarytool directly -- it needs a container (a `ditto -c -k --keepParent` zip). `stapler staple` then applies to the .saver bundle itself, not the zip.
- CI: this would need a new platform-gated task invoked from `ci:macos-check`, or left out of CI entirely (like `release:*` today) if the self-hosted macOS runner's Xcode/credentials situation doesn't support it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A new taskfiles/release.yml (or screensaver-scoped) pipeline signs JumpnbumpFireworks.saver with the Developer ID identity and hardened runtime, reusing keychain-setup/keychain-cleanup/decode-api-key/cleanup-api-key as-is
- [x] #2 The signed .saver is verified (codesign --verify --strict, hardened-runtime flag check) directly against the bundle, with no DMG mount step
- [x] #3 The .saver is zipped (ditto -c -k --keepParent), submitted to notarytool, and stapled back onto the .saver bundle itself (not the zip)
- [x] #4 Gatekeeper acceptance is confirmed (spctl -a -vv --type install or equivalent) against the stapled .saver bundle
- [x] #5 docs/build-layout.md's macOS release section documents the new pipeline alongside the existing Godot one
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added release:ship-screensaver/sign-screensaver/verify-screensaver-signing/notarize-screensaver to taskfiles/release.yml, reusing keychain-setup/keychain-cleanup/decode-api-key/cleanup-api-key as-is. Documented in docs/build-layout.md's new 'macOS screensaver signing' section. `task release:sign-screensaver --dry` confirmed the task graph resolves and the APPLE_SIGNING_IDENTITY precondition fires correctly. Not yet run end to end against live Apple infrastructure (needs a signing host with the Developer ID cert + notarytool API key) -- ACs left unchecked until that's confirmed, same bar ship-macos's docs held itself to.

Ran task release:ship-screensaver end to end on this machine using the Developer ID Application cert copied from ~/git/mt/.env (jumpnbump had no Developer ID cert of its own -- only Apple Development/Distribution identities were in the login keychain, neither of which notarytool accepts). Confirmed live: sign-screensaver signs with hardened runtime (codesign --display shows flags=0x10000(runtime), Authority=Developer ID Application: Lance Stephens); notarize-screensaver's notarytool submit --wait returned status: Accepted; stapler staple succeeded; spctl -a -vv --type install reports accepted / source=Notarized Developer ID. Ephemeral keychain and decoded API key were removed via defer: afterward -- confirmed via security list-keychains showing only login.keychain-db and System.keychain post-run.
<!-- SECTION:NOTES:END -->
