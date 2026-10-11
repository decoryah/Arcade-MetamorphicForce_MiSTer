#!/usr/bin/env python3
"""Where do an RTL frame dump and a MAME snapshot differ? Groups the differing pixels into rectangles
(8-connected, via a coarse grid) and prints a few RTL / MAME colours of each.

    python tools/diff_regions.py rtl.rgb mame.png [--w 288 --h 224] [--n 12]
"""
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    W, H = 288, 224
    N = int(sys.argv[sys.argv.index("--n") + 1]) if "--n" in sys.argv else 12
    rtl = open(args[0], "rb").read()
    a = struct.unpack("<%dI" % (len(rtl) // 4), rtl)
    mw, mh, rgb = pngio.read(args[1])
    def mame(x, y):
        o = (y * mw + x) * 3
        return (rgb[o] << 16) | (rgb[o + 1] << 8) | rgb[o + 2]
    bad = [(x, y) for y in range(H) for x in range(W) if (a[y * W + x] & 0xffffff) != mame(x, y)]
    print("%d differing pixels" % len(bad))
    # flood fill on the set, 8-connected
    s = set(bad)
    seen = set()
    regions = []
    for p in bad:
        if p in seen:
            continue
        stack = [p]; seen.add(p); pts = []
        while stack:
            x, y = stack.pop(); pts.append((x, y))
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    q = (x + dx, y + dy)
                    if q in s and q not in seen:
                        seen.add(q); stack.append(q)
        regions.append(pts)
    regions.sort(key=len, reverse=True)
    for pts in regions[:N]:
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
        x, y = pts[0]
        print("region %4d px  x %3d..%3d  y %3d..%3d   e.g. (%d,%d): RTL %06x  MAME %06x" % (
            len(pts), min(xs), max(xs), min(ys), max(ys), x, y, a[y * W + x] & 0xffffff, mame(x, y)))
    print("%d regions" % len(regions))


if __name__ == "__main__":
    main()
