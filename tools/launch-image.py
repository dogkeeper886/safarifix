#!/usr/bin/env python3
"""Writes a plain launch image for the iPhone 5's 4-inch screen, Default-568h@2x.png (640x1136), into an app
bundle. Without one, iOS runs the app in the 3.5-inch screen's 640x960, with black bars.
  python3 tools/launch-image.py APP_DIR [RRGGBB]"""
import struct
import sys
import zlib


def png(width, height, rgb):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    row = b"\x00" + bytes(rgb) * width
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * height, 9)) + chunk(b"IEND", b""))


app = sys.argv[1]
color = bytes.fromhex(sys.argv[2] if len(sys.argv) > 2 else "efeff4")
with open(app + "/Default-568h@2x.png", "wb") as f:
    f.write(png(640, 1136, color))
