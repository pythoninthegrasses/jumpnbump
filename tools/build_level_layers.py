#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.13,<3.14"
# dependencies = ["Pillow"]
# ///

"""
Converts level.pcx/mask.pcx (gameplay) and menu.pcx/menumask.pcx (menu) into
Godot-ready PNG layers (TASK-013.02): an opaque background PNG plus an
alpha-keyed masked-foreground PNG that must draw on top of sprites.

Decoding is delegated to core/asset_dump_cli.zig (`zig build asset-dump`),
the Phase 2 pcx.zig codec's CLI wrapper.

Layer semantics, read out of sdl/gfx.c's put_pob and main.c's init_level:
  - level.pcx / menu.pcx carry their own embedded 256-colour palette and are
    the single flat image blitted as the screen background every frame --
    it already contains both background AND foreground art baked together.
  - mask.pcx / menumask.pcx carry no palette; put_pob only ever tests
    `mask_ptr == 0`, so it is a boolean stencil, not a second image: a
    nonzero pixel there means "a foreground element occupies this pixel in
    level.pcx, so don't draw a moving sprite over it" (put_pob skips drawing
    the sprite's pixel and lets the already-blitted background show through
    instead).

  So the background layer is level.pcx as-is, and the masked-foreground
  layer is level.pcx's own colours again, but with alpha=0 everywhere
  mask.pcx is 0 and alpha=255 everywhere mask.pcx is nonzero -- drawn on top
  of sprites in Godot to reproduce the same occlusion.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parent.parent
CORE_DIR = REPO_ROOT / "core"
DATA_DIR = REPO_ROOT / "data"
OUT_DIR = REPO_ROOT / "game" / "content" / "levels"

WIDTH = 400
HEIGHT = 256

# (output stem, background pcx, mask pcx)
LAYER_SETS = [
    ("level", "level.pcx", "mask.pcx"),
    ("menu", "menu.pcx", "menumask.pcx"),
]


def die(message: str) -> None:
    raise SystemExit(message)


def build_asset_dump() -> Path:
    # ReleaseFast, not the default Debug: asset-dump's DebugAllocator prints
    # a leak report per allocPrint() call on process exit (harmless in a
    # short-lived CLI, but noisy enough to bury the pipeline's own output).
    subprocess.run(
        ["zig", "build", "asset-dump", "-Doptimize=ReleaseFast"],
        cwd=CORE_DIR,
        check=True,
    )
    binary = CORE_DIR / "zig-out" / "bin" / "asset-dump"
    if not binary.is_file():
        die(f"asset-dump was not produced at {binary}")
    return binary


def dump_pcx(
    asset_dump: Path, pcx_path: Path, out_dir: Path, stem: str, with_palette: bool
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(asset_dump),
            "pcx",
            str(pcx_path),
            str(out_dir),
            stem,
            str(WIDTH),
            str(HEIGHT),
            "1" if with_palette else "0",
        ],
        check=True,
    )


def load_palette(path: Path) -> list[tuple[int, int, int]]:
    raw = path.read_bytes()
    return [(raw[i], raw[i + 1], raw[i + 2]) for i in range(0, len(raw), 3)]


def render_pair(
    asset_dump: Path, stem: str, bg_pcx: str, mask_pcx: str, dump_dir: Path
) -> tuple[Image.Image, Image.Image]:
    dump_pcx(asset_dump, DATA_DIR / bg_pcx, dump_dir, "bg", with_palette=True)
    dump_pcx(asset_dump, DATA_DIR / mask_pcx, dump_dir, "mask", with_palette=False)

    palette = load_palette(dump_dir / "bg.palette.rgb")
    bg_idx = (dump_dir / "bg.idx").read_bytes()
    mask_idx = (dump_dir / "mask.idx").read_bytes()

    background = bytearray(WIDTH * HEIGHT * 4)
    foreground = bytearray(WIDTH * HEIGHT * 4)
    for i in range(WIDTH * HEIGHT):
        r, g, b = palette[bg_idx[i]]
        off = i * 4
        background[off : off + 4] = bytes((r, g, b, 255))
        alpha = 255 if mask_idx[i] != 0 else 0
        foreground[off : off + 4] = bytes((r, g, b, alpha))

    bg_image = Image.frombytes("RGBA", (WIDTH, HEIGHT), bytes(background))
    fg_image = Image.frombytes("RGBA", (WIDTH, HEIGHT), bytes(foreground))
    return bg_image, fg_image


def render_all(out_dir: Path) -> None:
    asset_dump = build_asset_dump()
    out_dir.mkdir(parents=True, exist_ok=True)
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        for stem, bg_pcx, mask_pcx in LAYER_SETS:
            bg_image, fg_image = render_pair(
                asset_dump, stem, bg_pcx, mask_pcx, Path(tmp) / stem
            )
            bg_image.save(out_dir / f"{stem}_background.png", format="PNG")
            fg_image.save(out_dir / f"{stem}_foreground.png", format="PNG")
            print(
                f"build_level_layers: wrote {stem}_background.png and {stem}_foreground.png"
            )

    manifest = {
        "layers": [
            {
                "name": stem,
                "background": f"{stem}_background.png",
                "foreground": f"{stem}_foreground.png",
                "note": "foreground must draw on top of sprites; alpha=0 where the source mask pcx is 0",
            }
            for stem, _, _ in LAYER_SETS
        ]
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def check_all(committed_dir: Path) -> int:
    # Compares decoded pixels, not encoded PNG bytes: Pillow's PNG encoder is
    # not guaranteed to produce byte-identical output across versions or
    # platforms even when the source pixels are unchanged (observed directly:
    # the same Pillow version re-encoded identical pixels to a different
    # compressed IDAT size). Pixel content is the actual invariant this check
    # protects.
    asset_dump = build_asset_dump()
    failures = []
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        for stem, bg_pcx, mask_pcx in LAYER_SETS:
            bg_image, fg_image = render_pair(
                asset_dump, stem, bg_pcx, mask_pcx, Path(tmp) / stem
            )
            for suffix, fresh_image in (
                (f"{stem}_background.png", bg_image),
                (f"{stem}_foreground.png", fg_image),
            ):
                committed_path = committed_dir / suffix
                if not committed_path.exists():
                    failures.append(
                        f"{committed_path} does not exist (run `tools/build_level_layers.py --all` and commit it)"
                    )
                    continue
                committed_image = Image.open(committed_path)
                committed_image.load()
                if fresh_image.tobytes() != committed_image.convert("RGBA").tobytes():
                    failures.append(f"{committed_path} does not match a fresh render")
    if failures:
        print("build_level_layers: check FAILED", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"build_level_layers: {len(LAYER_SETS) * 2} layer(s) match a fresh render pixel-for-pixel"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--all", action="store_true", help="render both layer sets (level + menu)"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="diff fresh renders against --out-dir instead of writing",
    )
    parser.add_argument("--out-dir", type=Path, default=OUT_DIR)
    args = parser.parse_args()

    if not args.all:
        parser.error("--all is required (there is no single-file mode)")

    if args.check:
        return check_all(args.out_dir)
    render_all(args.out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
