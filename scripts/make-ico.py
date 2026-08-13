#!/usr/bin/env python3
"""Packs PNG renditions into a Windows .ico.

An ICO is a small container: a header, one directory entry per image, then the
image payloads. Vista and later accept PNG payloads directly, so the PNGs are
embedded as-is rather than re-encoded to BMP. Written by hand because macOS
ships no .ico tooling and pulling in Pillow for one file is not worth it.
"""
import struct
import sys
from pathlib import Path

def build_ico(png_paths, output):
    images = []
    for path in png_paths:
        data = Path(path).read_bytes()
        # PNG header: width and height are big-endian uint32 at offset 16.
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError(f"{path} is not a PNG")
        width, height = struct.unpack(">II", data[16:24])
        images.append((width, height, data))

    images.sort(key=lambda item: item[0])

    # ICONDIR: reserved, type (1 = icon), image count
    header = struct.pack("<HHH", 0, 1, len(images))
    # Payloads start after the directory.
    offset = len(header) + 16 * len(images)

    directory = b""
    payloads = b""
    for width, height, data in images:
        # 256 is stored as 0 in the single-byte fields.
        directory += struct.pack(
            "<BBBBHHII",
            width if width < 256 else 0,
            height if height < 256 else 0,
            0,      # palette size
            0,      # reserved
            1,      # colour planes
            32,     # bits per pixel
            len(data),
            offset,
        )
        payloads += data
        offset += len(data)

    Path(output).write_bytes(header + directory + payloads)
    return len(images)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: make-ico.py <png-dir> <output.ico>", file=sys.stderr)
        sys.exit(2)

    png_dir = Path(sys.argv[1])
    pngs = sorted(png_dir.glob("icon_*.png"))
    if not pngs:
        print(f"no icon_*.png found in {png_dir}", file=sys.stderr)
        sys.exit(1)

    count = build_ico(pngs, sys.argv[2])
    print(f"✅ Wrote {sys.argv[2]} with {count} sizes")
