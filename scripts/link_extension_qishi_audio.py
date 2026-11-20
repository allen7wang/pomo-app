#!/usr/bin/env python3
"""Hardlink qishi mp3s into the unpacked extension so web pomo can play offline.

The extension does not commit these files. It prefers app/audio/qishi/<id>.mp3
and falls back to the public Pages URL when the link is absent.
"""
import os
import pathlib
import sys

POMO = pathlib.Path(__file__).resolve().parent.parent
QISHI = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / "GitHub/qishi-meditation")
SRC = QISHI / "public/audio"
DST = POMO / "app/audio/qishi"
CATALOG = POMO / "app/audio/qishi_presets.json"

def main():
    import json
    presets = json.loads(CATALOG.read_text())["presets"]
    files = sorted({track["file"] for preset in presets for track in preset["tracks"]})
    DST.mkdir(parents=True, exist_ok=True)
    linked = 0
    for name in files:
        src = SRC / name
        dst = DST / name
        if not src.is_file():
            sys.exit(f"missing source audio: {src}")
        if dst.exists() and dst.stat().st_ino == src.stat().st_ino:
            linked += 1
            continue
        if dst.exists() or dst.is_symlink():
            dst.unlink()
        os.link(src, dst)
        linked += 1
    print(f"linked {linked} files -> {DST}")

if __name__ == "__main__":
    main()
