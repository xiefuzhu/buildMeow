#!/usr/bin/env python3
"""Builds the two subsetted Noto Sans SC fonts the app ships.

Why subset at all: the full Simplified Chinese font is 17 MB, and the app needs
it for one thing — the labels on the blueprint sheets. It can only ever print
the characters that appear in this repository, so the rest are dead weight. The
subset comes out around 1% of the size.

Why not do it at build time: it needs `fonttools`, and a Flutter build should not
depend on a Python environment. The output is committed, and this script is only
run when the set of characters the app can print changes — which is what the
coverage check below is for.

Usage, from the `app` directory:

    pip install fonttools
    python tool/subset_font.py

The source font is downloaded into `build/fonts/` (gitignored) on first run.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
REPO = APP.parent
SOURCE_URL = (
    "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/"
    "NotoSansSC%5Bwght%5D.ttf"
)
SOURCE = APP / "build" / "fonts" / "NotoSansSC[wght].ttf"
OUT = APP / "assets" / "fonts"

# The weights the blueprint sheets use. Two instanced subsets rather than one
# variable font: the `pdf` package's TrueType reader does not do `gvar`.
WEIGHTS = {"Regular": 400, "Bold": 700}

# Everything printable ASCII, so ids, numbers and coordinates render even if a
# source file stops mentioning one of them.
ASCII = "".join(chr(c) for c in range(0x20, 0x7F))

# Characters that appear in the sheets but not in any Dart source: the degree
# sign in a heading, the multiplication sign in "128 x 128", the middle dot
# separators, and the arrows the export page prints.
EXTRA = "×·→←↑↓°±—–…“”‘’、。,.!?:;()[]{}<>/\\|+-=_~@#$%^&*'\"`"


def glyphs() -> set[str]:
    """Every character the app can put on a sheet."""
    chars: set[str] = set(ASCII) | set(EXTRA)

    # The Chinese block names, which are the bulk of it.
    names = json.loads(
        (REPO / "packages/mapart_core/assets/lang/zh_cn_blocks.json").read_text(
            encoding="utf-8"
        )
    )
    for name in names["blocks"].values():
        chars.update(name)

    capabilities = REPO / "packages/mapart_core/assets/colors/block_capabilities.json"
    if capabilities.exists():
        reasons = json.loads(capabilities.read_text(encoding="utf-8"))
        for key in ("mapReasons", "textureReasons"):
            for reason in reasons[key].values():
                chars.update(reason)

    # And every non-ASCII character in the app's own sources, which is how the
    # interface strings get in without a second list to keep in step.
    for path in list((APP / "lib").rglob("*.dart")) + list(
        (REPO / "packages/mapart_core/lib").rglob("*.dart")
    ):
        text = path.read_text(encoding="utf-8")
        for ch in text:
            if ord(ch) > 0x7F:
                chars.add(ch)

    # A subset must not contain a character the font has no glyph for, or
    # pyftsubset fails; the printable ASCII set is the only risky part.
    return {ch for ch in chars if ch.isprintable() and ch != "\n"}


def ensure_source() -> None:
    if SOURCE.exists() and SOURCE.stat().st_size > 1_000_000:
        return
    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    print(f"downloading {SOURCE_URL} -> {SOURCE}")
    urllib.request.urlretrieve(SOURCE_URL, SOURCE)


def run(*args: str) -> None:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit(f"failed: {' '.join(args)}")


def main() -> None:
    try:
        import fontTools  # noqa: F401
    except ImportError:
        raise SystemExit("fonttools is missing; run: pip install fonttools")

    ensure_source()
    OUT.mkdir(parents=True, exist_ok=True)

    chars = glyphs()
    text_file = APP / "build" / "fonts" / "glyphs.txt"
    text_file.write_text("".join(sorted(chars)), encoding="utf-8")
    print(f"{len(chars)} distinct characters the app can print")

    for name, weight in WEIGHTS.items():
        instanced = APP / "build" / "fonts" / f"NotoSansSC-{name}-full.ttf"
        target = OUT / f"NotoSansSC-{name}.ttf"
        run(
            sys.executable,
            "-m",
            "fontTools.varLib.instancer",
            str(SOURCE),
            f"wght={weight}",
            "-o",
            str(instanced),
        )
        run(
            sys.executable,
            "-m",
            "fontTools.subset",
            str(instanced),
            f"--text-file={text_file}",
            f"--output-file={target}",
            "--layout-features=",
            "--no-hinting",
            "--desubroutinize",
            "--name-IDs=*",
            "--drop-tables+=DSIG",
        )
        instanced.unlink()
        print(f"{target.name}: {target.stat().st_size / 1024:.0f} KB")

    check_missing(text_file, OUT)


def check_missing(text_file: Path, out: Path) -> None:
    """Fails if a character the app can print is not in the subset.

    The alternative is a blank box on a printed sheet, which is the kind of
    thing nobody notices until they are holding the paper.
    """
    from fontTools.ttLib import TTFont

    wanted = set(text_file.read_text(encoding="utf-8"))
    font = TTFont(out / "NotoSansSC-Regular.ttf")
    cmap = set()
    for table in font["cmap"].tables:
        cmap.update(table.cmap.keys())
    missing = sorted(ch for ch in wanted if ord(ch) not in cmap)
    if missing:
        print(f"MISSING {len(missing)} characters: {''.join(missing)}")
        raise SystemExit(1)
    print("every character the app can print is in the subset")


if __name__ == "__main__":
    main()
