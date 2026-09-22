#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.13,<3.14"
# dependencies = ["Pillow>=12.3.0"]
#
# [tool.uv]
# exclude-newer = "2026-09-22"
# ///

# Pillow>=12.3.0 is the version this icon crop was diagnosed and tested
# against (TASK-020); exclude-newer pins uv's resolution to the day this was
# reviewed so re-runs stay reproducible instead of drifting to newer Pillow
# releases.

"""
Generates game/icon.png (TASK-009) by cropping one frame out of the already
-committed game/content/sprites/rabbit_atlas.png -- no .gob decoding, this
just reuses tools/build_sprite_atlas.py's output.

Frame 6 (colour 0, direction 0, frame 6 -- see rabbit_atlas.json's
sprite_index_formula) is the idle standing pose, and is the only 16x16
(square, hotspot 0,0) frame in the first colour's direction-0 set, which
makes it crop cleanly to a square icon with no letterboxing.

Godot builds the macOS .icns from this PNG at export time (see
game/export_presets.cfg's application/icon), so no .icns is committed.
"""

import sys
from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parent.parent
ATLAS_PATH = REPO_ROOT / "game" / "content" / "sprites" / "rabbit_atlas.png"
OUT_PATH = REPO_ROOT / "game" / "icon.png"

FRAME_INDEX = 6
FRAME_X, FRAME_Y, FRAME_W, FRAME_H = 114, 0, 16, 16
ICON_SIZE = 512


def main() -> int:
    atlas = Image.open(ATLAS_PATH)
    frame = atlas.crop((FRAME_X, FRAME_Y, FRAME_X + FRAME_W, FRAME_Y + FRAME_H))
    icon = frame.resize((ICON_SIZE, ICON_SIZE), resample=Image.NEAREST)
    icon.save(OUT_PATH)
    print(f"build_app_icon: wrote {OUT_PATH} ({ICON_SIZE}x{ICON_SIZE})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
