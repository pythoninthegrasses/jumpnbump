#!/usr/bin/env -S uv run --script

# /// script
# requires-python = ">=3.13,<3.14"
# dependencies = ["soundfile>=0.14.0", "numpy>=2.5.3"]
#
# [tool.uv]
# exclude-newer = "2026-09-22"
# ///

# soundfile>=0.14.0 and numpy>=2.5.3 are their latest stable releases as of
# this pin (TASK-020); exclude-newer caps uv's resolution to that same day
# so re-runs stay reproducible instead of drifting to newer releases.

"""
Renders bump.mod/jump.mod/scores.mod to looping OGG Vorbis under
game/content/audio/music/ (TASK-013.03), via a pinned openmpt123 build
(tools/game_toolchain.lock) -- since sdl/sound.c's Mix_PlayMusic(mus, -1)
loops the whole track from the start indefinitely (see main.c's
play_music()), "the loop point" is simply (0, full length); that's recorded
in the emitted manifest.json for a later Godot-side task to wire into each
AudioStreamOggVorbis's loop/loop_offset properties.

Two chained external steps, same shape as ~/git/neo_snake's
tools/render_music.py (Furnace -> WAV -> soundfile -> OGG):

  1. the pinned `openmpt123` binary renders the full track once
     (`--render`, one pass -- MODs have no fixed "duration" beyond playing
     every order once) to a 16-bit PCM stereo WAV.
  2. `soundfile` re-encodes that WAV to OGG (its bundled libsndfile has
     Vorbis support compiled in).

--self-test confirms two openmpt123 renders of the same .mod are
byte-identical WAV, same as neo_snake's Furnace self-test.

The committed .ogg files are NOT byte-reproducible across renders --
libvorbis/libogg embeds a randomized per-stream serial number in the OGG
container (confirmed by hand, same as neo_snake's finding) -- but two
independent encodes of the same WAV decode back to bit-identical PCM, so
--check decodes both the committed .ogg and a fresh render with soundfile
and compares sample arrays. libopenmpt's own renderer is not guaranteed
bit-identical across platforms/CPU codepaths either, so `task audio:check`
is wired to run on Linux CI only, matching the neo_snake precedent the
parent task cites.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data"
OUT_DIR = REPO_ROOT / "game" / "content" / "audio" / "music"
LOCK_FILE = Path(__file__).resolve().parent / "game_toolchain.lock"

MOD_NAMES = ["bump", "jump", "scores"]
SAMPLE_RATE = 44100


def die(message: str) -> None:
    raise SystemExit(message)


def load_pins() -> dict[str, str]:
    pins: dict[str, str] = {}
    for line in LOCK_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        pins[key.strip()] = value.strip().strip('"')
    for key in pins:
        if key in os.environ:
            pins[key] = os.environ[key]
    return pins


def resolve_openmpt123() -> Path:
    import shutil

    binary = shutil.which("openmpt123")
    if binary is None:
        die(
            "openmpt123 is not on PATH (install it via your distro's package, e.g. `dnf install openmpt123`)"
        )

    pinned = load_pins()["OPENMPT123_VERSION"]
    result = subprocess.run(
        [binary, "--short-version"], capture_output=True, text=True, check=True
    )
    actual = result.stdout.strip().split(" / ")[0]
    if actual != pinned:
        die(
            f"openmpt123 is version {actual}, but tools/game_toolchain.lock pins {pinned}"
        )
    return Path(binary)


def render_mod_to_wav(openmpt123: Path, mod_path: Path, wav_path: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        staged_mod = Path(tmp) / mod_path.name
        staged_mod.write_bytes(mod_path.read_bytes())
        # not check=True: a nonzero exit is handled explicitly below so the
        # die() message can include stdout/stderr.
        result = subprocess.run(
            [
                str(openmpt123),
                "--render",
                "--quiet",
                "--samplerate",
                str(SAMPLE_RATE),
                "--channels",
                "2",
                "--no-float",
                # dither defaults to "auto" (randomized noise-shaping), which
                # makes renders non-reproducible byte-for-byte -- confirmed
                # by hand (~20% of PCM bytes differ between two renders of
                # the same .mod with dither left on).
                "--dither",
                "0",
                "--output-type",
                "wav",
                staged_mod.name,
            ],
            cwd=tmp,
            capture_output=True,
            text=True,
            check=False,
        )
        staged_wav = staged_mod.with_suffix(staged_mod.suffix + ".wav")
        if result.returncode != 0 or not staged_wav.exists():
            die(
                f"openmpt123 failed to render {mod_path}:\n{result.stdout}\n{result.stderr}"
            )
        wav_path.write_bytes(staged_wav.read_bytes())


WRITE_CHUNK_FRAMES = 65536


def wav_to_ogg_bytes(wav_path: Path) -> bytes:
    data, sample_rate = sf.read(str(wav_path))
    ogg_path = wav_path.with_suffix(".ogg")
    # A single sf.write() call segfaults in this environment's libsndfile
    # for tracks longer than ~48s (confirmed by hand: 2,000,000 stereo
    # frames writes fine, 2,100,000 crashes) -- streaming the same data
    # through SoundFile.write() in chunks avoids whatever internal buffer
    # overflow that one-shot path hits, with identical output.
    with sf.SoundFile(
        str(ogg_path),
        "w",
        samplerate=sample_rate,
        channels=data.shape[1],
        format="OGG",
        subtype="VORBIS",
    ) as f:
        for start in range(0, len(data), WRITE_CHUNK_FRAMES):
            f.write(data[start : start + WRITE_CHUNK_FRAMES])
    return ogg_path.read_bytes()


def render_track(openmpt123: Path, mod_path: Path) -> tuple[bytes, int]:
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = Path(tmp) / f"{mod_path.stem}.wav"
        render_mod_to_wav(openmpt123, mod_path, wav_path)
        frame_count = sf.info(str(wav_path)).frames
        return wav_to_ogg_bytes(wav_path), frame_count


def discover_mods(src_dir: Path) -> list[Path]:
    return [
        src_dir / f"{name}.mod"
        for name in MOD_NAMES
        if (src_dir / f"{name}.mod").exists()
    ]


def render_all(openmpt123: Path, src_dir: Path, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = {"tracks": []}
    for mod_path in discover_mods(src_dir):
        ogg_bytes, frame_count = render_track(openmpt123, mod_path)
        (out_dir / f"{mod_path.stem}.ogg").write_bytes(ogg_bytes)
        manifest["tracks"].append(
            {
                "name": mod_path.stem,
                "file": f"{mod_path.stem}.ogg",
                "loop_start_sample": 0,
                "loop_end_sample": frame_count,
                "sample_rate": SAMPLE_RATE,
            }
        )
        print(
            f"render_music: wrote {mod_path.stem}.ogg ({frame_count} frames, loops from 0)"
        )

    import json

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def ogg_samples(ogg_bytes: bytes) -> np.ndarray:
    with tempfile.NamedTemporaryFile(suffix=".ogg") as tmp:
        tmp.write(ogg_bytes)
        tmp.flush()
        data, _ = sf.read(tmp.name)
    return data


def check_all(openmpt123: Path, src_dir: Path, committed_dir: Path) -> int:
    mods = discover_mods(src_dir)
    if not mods:
        print(f"render_music: no .mod files under {src_dir} -- nothing to check")
        return 0
    failures = []
    for mod_path in mods:
        ogg_bytes, _ = render_track(openmpt123, mod_path)
        committed_path = committed_dir / f"{mod_path.stem}.ogg"
        if not committed_path.exists():
            failures.append(
                f"{committed_path} does not exist (run `tools/render_music.py --all` and commit it)"
            )
            continue
        if not np.array_equal(
            ogg_samples(ogg_bytes), ogg_samples(committed_path.read_bytes())
        ):
            failures.append(
                f"{committed_path} does not decode to the same samples as a fresh render of {mod_path}"
            )
    if failures:
        print("render_music: check FAILED", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"render_music: {len(mods)} track(s) decode identically to a fresh render of their .mod source"
    )
    return 0


def run_self_test(openmpt123: Path, src_dir: Path) -> int:
    mods = discover_mods(src_dir)
    if not mods:
        die(f"render_music: no .mod files under {src_dir} to self-test against")
    mod_path = mods[0]
    with tempfile.TemporaryDirectory() as tmp:
        wav_a = Path(tmp) / "a.wav"
        wav_b = Path(tmp) / "b.wav"
        render_mod_to_wav(openmpt123, mod_path, wav_a)
        render_mod_to_wav(openmpt123, mod_path, wav_b)
        if wav_a.read_bytes() != wav_b.read_bytes():
            print(
                f"render_music: self-test FAILED -- two renders of {mod_path} differ",
                file=sys.stderr,
            )
            return 1
    print(
        f"render_music: self-test PASSED ({mod_path.name}, byte-identical WAV across two renders)"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help=f"render every .mod in --src-dir (default {DATA_DIR})",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="with --all, diff fresh renders against --out-dir instead of writing",
    )
    parser.add_argument("--src-dir", type=Path, default=DATA_DIR)
    parser.add_argument("--out-dir", type=Path, default=OUT_DIR)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="render the first .mod twice and assert byte-identical WAV output",
    )
    args = parser.parse_args()

    openmpt123 = resolve_openmpt123()

    if args.self_test:
        return run_self_test(openmpt123, args.src_dir)
    if args.all:
        if args.check:
            return check_all(openmpt123, args.src_dir, args.out_dir)
        render_all(openmpt123, args.src_dir, args.out_dir)
        return 0

    parser.error("one of --all or --self-test is required")


if __name__ == "__main__":
    sys.exit(main())
