#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.13,<3.14"
# dependencies = ["Pillow"]
# ///

"""
Converts rabbit.gob, objects.gob, numbers.gob, and font.gob (TASK-013.01)
into Godot-ready PNG sprite atlases plus AtlasTexture .tres resources.

Decoding is delegated to core/asset_dump_cli.zig (`zig build asset-dump`),
the Phase 2 gob.zig/pcx.zig codecs' CLI wrapper -- this script never
re-implements .gob/.pcx parsing, it only packs the decoded palette-index
frames into an RGBA atlas and writes Godot resources.

All four .gob files share a single palette: main.c loads menu.pcx once at
startup and calls register_gob() for rabbit/objects/font/numbers against
that same global VGA palette (main.c's `pal` local, read via read_pcx just
before the four register_gob calls) -- there is no per-gob palette.

Atlas layout intentionally mirrors core/gobpack_cli.zig's doUnpack (a
uniform tile_w=max_width+2 x tile_h=max_height+2 grid, including its
preserved y_count=atlas_h/tile_w bug) so the generated atlas geometry lines
up 1:1 with the already-committed data/<name>.txt frame tables -- a free
correctness cross-check, not a design requirement of Godot's AtlasTexture.

Sprite selection at runtime is colour*18 + direction*9 + frame (main.c:
`player[i].image + i*18` selects the player's colour slot, then
`player_anims[...].frame[...].image + direction*9` selects the directional
sub-frame within it) -- documented in the emitted manifest.json, not
reproduced here since this script only extracts the frame geometry.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parent.parent
CORE_DIR = REPO_ROOT / "core"
DATA_DIR = REPO_ROOT / "data"
OUT_DIR = REPO_ROOT / "game" / "content" / "sprites"
PALETTE_SOURCE = DATA_DIR / "menu.pcx"

GOB_NAMES = ["rabbit", "objects", "numbers", "font"]

ATLAS_W = 400
ATLAS_H = 256


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


def dump_gob(asset_dump: Path, name: str, out_dir: Path) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(asset_dump),
            "gob",
            str(DATA_DIR / f"{name}.gob"),
            str(PALETTE_SOURCE),
            str(out_dir),
        ],
        check=True,
    )
    return json.loads((out_dir / "manifest.json").read_text())


def load_palette(path: Path) -> list[tuple[int, int, int]]:
    raw = path.read_bytes()
    return [(raw[i], raw[i + 1], raw[i + 2]) for i in range(0, len(raw), 3)]


def tile_grid(frames: list[dict]) -> tuple[int, int, int, int]:
    max_w = max(f["width"] for f in frames)
    max_h = max(f["height"] for f in frames)
    tile_w = max_w + 2
    tile_h = max_h + 2
    x_count = ATLAS_W // tile_w
    # Preserves core/gobpack_cli.zig's y_count = atlas_h / tile_w bug so the
    # generated layout matches the committed data/<name>.txt tables exactly.
    y_count = ATLAS_H // tile_w
    return tile_w, tile_h, x_count, y_count


def build_atlas(
    manifest: dict, dump_dir: Path, palette: list[tuple[int, int, int]]
) -> tuple[Image.Image, list[dict]]:
    frames = manifest["frames"]
    tile_w, tile_h, x_count, y_count = tile_grid(frames)

    atlas = bytearray(ATLAS_W * ATLAS_H * 4)
    placements = []

    for i, frame in enumerate(frames):
        if i >= x_count * y_count:
            die(
                f"atlas grid ({x_count}x{y_count} tiles) is too small for {len(frames)} frames"
            )
        xi = i % x_count
        yi = i // x_count
        dst_x = xi * tile_w
        dst_y = yi * tile_h
        w, h = frame["width"], frame["height"]

        idx_bytes = (dump_dir / frame["file"]).read_bytes()
        for row in range(h):
            for col in range(w):
                palette_index = idx_bytes[row * w + col]
                dst_off = ((dst_y + row) * ATLAS_W + (dst_x + col)) * 4
                if palette_index == 0:
                    atlas[dst_off : dst_off + 4] = b"\x00\x00\x00\x00"
                else:
                    r, g, b = palette[palette_index]
                    atlas[dst_off : dst_off + 4] = bytes((r, g, b, 255))

        placements.append(
            {
                "index": i,
                "x": dst_x,
                "y": dst_y,
                "width": w,
                "height": h,
                "hotspot_x": frame["hotspot_x"],
                "hotspot_y": frame["hotspot_y"],
            }
        )

    image = Image.frombytes("RGBA", (ATLAS_W, ATLAS_H), bytes(atlas))
    return image, placements


def write_tres(name: str, placements: list[dict], out_dir: Path) -> Path:
    atlas_res_path = f"res://content/sprites/{name}_atlas.png"
    lines = [
        f'[gd_resource type="Resource" load_steps={len(placements) + 1} format=3]',
        "",
    ]
    lines.append(f'[ext_resource type="Texture2D" path="{atlas_res_path}" id="1"]')
    lines.append("")
    for p in placements:
        lines.append(
            f'[sub_resource type="AtlasTexture" id="AtlasTexture_{name}_{p["index"]}"]'
        )
        lines.append('atlas = ExtResource("1")')
        lines.append(f"region = Rect2({p['x']}, {p['y']}, {p['width']}, {p['height']})")
        lines.append("")
    tres_path = out_dir / f"{name}_atlas.tres"
    tres_path.write_text("\n".join(lines) + "\n")
    return tres_path


def render_one(
    asset_dump: Path, name: str, dump_root: Path
) -> tuple[Image.Image, list[dict]]:
    dump_dir = dump_root / name
    manifest = dump_gob(asset_dump, name, dump_dir)
    palette = load_palette(dump_dir / manifest["palette_file"])
    return build_atlas(manifest, dump_dir, palette)


def render_all(out_dir: Path) -> None:
    asset_dump = build_asset_dump()
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name in GOB_NAMES:
            image, placements = render_one(asset_dump, name, Path(tmp))
            image.save(out_dir / f"{name}_atlas.png", format="PNG")
            manifest_out = {
                "sprite_index_formula": "colour * 18 + direction * 9 + frame (main.c: player[i].image + i*18, then + direction*9)",
                "frames": placements,
            }
            (out_dir / f"{name}_atlas.json").write_text(
                json.dumps(manifest_out, indent=2) + "\n"
            )
            write_tres(name, placements, out_dir)
            print(
                f"build_sprite_atlas: wrote {name}_atlas.png ({len(placements)} frames)"
            )


def check_all(committed_dir: Path) -> int:
    # Compares decoded pixels, not encoded PNG bytes: Pillow's PNG encoder is
    # not guaranteed to produce byte-identical output across versions or
    # platforms even when the source pixels are unchanged (observed directly:
    # the same Pillow version re-encoded identical pixels to a different
    # compressed IDAT size). Pixel content is the actual invariant this check
    # protects.
    asset_dump = build_asset_dump()
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for name in GOB_NAMES:
            fresh_image, _ = render_one(asset_dump, name, Path(tmp))
            committed_path = committed_dir / f"{name}_atlas.png"
            if not committed_path.exists():
                failures.append(
                    f"{committed_path} does not exist (run `tools/build_sprite_atlas.py --all` and commit it)"
                )
                continue
            committed_image = Image.open(committed_path)
            committed_image.load()
            if fresh_image.tobytes() != committed_image.convert("RGBA").tobytes():
                failures.append(f"{committed_path} does not match a fresh render")
    if failures:
        print("build_sprite_atlas: check FAILED", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"build_sprite_atlas: {len(GOB_NAMES)} atlas(es) match a fresh render pixel-for-pixel"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--all", action="store_true", help="render every gob atlas")
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
