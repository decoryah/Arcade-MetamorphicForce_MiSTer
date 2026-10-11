#!/usr/bin/env python3
"""List the active sprite entries of a frozen state (tools/lua/dump_state.lua): position (in MAME's absolute
coordinates, as the K053247 draw routine computes them for an unzoomed object), size, zoom, code, colour,
priority group, shadow and mix codes, flips.

    python tools/spr_list.py state_N.txt [--at X Y]   (only entries whose box covers the picture point)
"""
import sys


def main():
    p = sys.argv[1]
    at = None
    if "--at" in sys.argv:
        i = sys.argv.index("--at"); at = (int(sys.argv[i + 1]), int(sys.argv[i + 2]))
    st = {}
    for line in open(p):
        k, _, rest = line.partition(" ")
        st[k] = rest.split()
    spr = [int(x, 16) for x in st["SPRITERAM"]]
    k46 = [int(x, 16) for x in st["K46REGS"]]
    k47 = [int(x, 16) for x in st["K47REGS"]]
    offx = (k46[0] << 8) | k46[1]; offy = (k46[2] << 8) | k46[3]
    r5 = k46[5]
    opset = k47[6]
    wrap = 512 if opset & 0x40 else 1024
    print("k046 offx %04x offy %04x reg5 %02x opset %04x" % (offx, offy, r5, opset))
    print("ent  z   size      xy(abs)        zoom(x,y)  code  color pri shd mix  flags")
    n = 0
    for e in range(256):
        w = spr[e * 8:(e + 1) * 8]
        if not (w[0] & 0x8000):
            continue
        n += 1
        szx = 1 << ((w[0] >> 8) & 3); szy = 1 << ((w[0] >> 10) & 3)
        x = w[3] & 0x3ff; y = w[2] & 0x3ff
        ox = (x - 51 - offx) & (wrap - 1)
        oy = ((-(y + 24)) - offy) & (wrap - 1)
        flags = ("A" if w[0] & 0x4000 else "") + ("Y" if w[0] & 0x2000 else "") + ("X" if w[0] & 0x1000 else "") \
            + ("my" if w[6] & 0x8000 else "") + ("mx" if w[6] & 0x4000 else "")
        zx = w[5] & 0x3ff; zy = w[4] & 0x3ff
        if at is not None:
            # a rough box: unzoomed unless zoom != 0x40 (then scaled by 0x40/zoom)
            wpx = szx * 16 * 0x40 // max(zx, 1); hpx = szy * 16 * 0x40 // max(zy, 1)
            if not (ox <= at[0] + 0 < ox + wpx + 64 and oy - hpx - 64 <= at[1] <= oy + 64):
                continue
        print("%3d  %02x  %dx%d   x%4d y%4d   %03x,%03x  %04x  %02x    %d   %d   %d   %s" % (
            e, w[0] & 0xff, szx, szy, ox, oy, zx, zy, w[1], w[6] & 0xff, (w[6] >> 5) & 7,
            (w[6] >> 10) & 3, (w[6] >> 8) & 3, flags))
    print("%d active" % n)


if __name__ == "__main__":
    main()
