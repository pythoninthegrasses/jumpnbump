#!/usr/bin/env bash
# Assembles JumpnbumpFireworks.saver (TASK-017.03): builds FireworksKit via
# SwiftPM, compiles the Metal shader, then links everything into a loadable
# bundle with `swiftc` (not `clang`) as the final linker driver -- swiftc
# keeps setting up the Swift runtime's search paths even when told to emit
# an MH_BUNDLE via `-Xlinker -bundle`, which a raw `clang`/`ld` invocation
# against the prebuilt static libs would not. `-all_load` forces every
# object in libFireworksKit.a to link, which is what keeps
# NSPrincipalClass (JNBFireworksView, named in Info.plist) resolvable --
# a plain static link only pulls in symbols something else already
# references, and nothing in this bundle calls JNBFireworksView directly,
# ScreenSaverView's host process does, by class name, at load time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="${1:-release}"
CORE_LIB="$SCRIPT_DIR/../core/zig-out/lib/libjumpnbump.a"
BUNDLE_NAME="JumpnbumpFireworks.saver"
BUNDLE="$SCRIPT_DIR/.build/$BUNDLE_NAME"

if [[ ! -f "$CORE_LIB" ]]; then
    echo "error: $CORE_LIB not found -- run 'task core:build-abi' first" >&2
    exit 1
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product FireworksKit

SWIFT_LIB=".build/$CONFIG/libFireworksKit.a"
if [[ ! -f "$SWIFT_LIB" ]]; then
    echo "error: $SWIFT_LIB not produced by swift build" >&2
    exit 1
fi

echo "==> compiling fireworks.metal"
mkdir -p .build/metal
xcrun -sdk macosx metal -c Sources/FireworksShaders/fireworks.metal -o .build/metal/fireworks.air
xcrun -sdk macosx metallib .build/metal/fireworks.air -o .build/metal/default.metallib

echo "==> assembling $BUNDLE_NAME"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp Resources/Info.plist.in "$BUNDLE/Contents/Info.plist"
cp .build/metal/default.metallib "$BUNDLE/Contents/Resources/default.metallib"
cp ../game/content/sprites/rabbit_atlas.png "$BUNDLE/Contents/Resources/rabbit_atlas.png"
cp ../game/content/sprites/rabbit_atlas.json "$BUNDLE/Contents/Resources/rabbit_atlas.json"
cp ../game/content/sprites/objects_atlas.png "$BUNDLE/Contents/Resources/objects_atlas.png"
cp ../game/content/sprites/objects_atlas.json "$BUNDLE/Contents/Resources/objects_atlas.json"
cp ../data/level.pcx "$BUNDLE/Contents/Resources/level.pcx"

echo "==> linking $BUNDLE_NAME's binary"
swiftc \
    -Xlinker -bundle \
    -Xlinker -all_load \
    "$SWIFT_LIB" \
    "$CORE_LIB" \
    -framework ScreenSaver \
    -framework Metal \
    -framework QuartzCore \
    -framework AppKit \
    -framework ImageIO \
    -framework CoreGraphics \
    -o "$BUNDLE/Contents/MacOS/JumpnbumpFireworks"

echo "==> codesigning (ad hoc)"
codesign --force --sign - "$BUNDLE"

echo "==> built $BUNDLE"
