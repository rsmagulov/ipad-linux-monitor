"""Draws the app icon (a laptop and a tablet joined by a cable) as a PNG, stdlib only."""
import struct, sys, zlib

S = int(sys.argv[2]) if len(sys.argv) > 2 else 152
img = [[(24, 28, 38)] * S for _ in range(S)]

def rect(x0, y0, x1, y1, c):
    for y in range(int(y0 * S), int(y1 * S)):
        for x in range(int(x0 * S), int(x1 * S)):
            img[y][x] = c

accent, screen = (90, 170, 255), (40, 60, 90)
rect(0.10, 0.30, 0.56, 0.62, accent)   # laptop lid
rect(0.13, 0.33, 0.53, 0.59, screen)
rect(0.05, 0.62, 0.61, 0.66, accent)   # laptop base
rect(0.66, 0.34, 0.92, 0.70, accent)   # tablet
rect(0.68, 0.37, 0.90, 0.67, screen)
rect(0.56, 0.74, 0.79, 0.765, (200, 200, 210))  # cable
rect(0.56, 0.66, 0.575, 0.765, (200, 200, 210))
rect(0.775, 0.70, 0.79, 0.765, (200, 200, 210))

raw = b"".join(b"\0" + bytes(v for px in row for v in px) for row in img)
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
