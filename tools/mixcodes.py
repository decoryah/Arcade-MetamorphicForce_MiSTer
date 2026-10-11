#!/usr/bin/env python3
"""How the tile attribute's mix bits (attr & 3, K056832 attribute word bits 1:0) and the K055555 / K054338
blend registers are used in a directory of frozen states (tools/lua/dump_state.lua).

    python tools/mixcodes.py <dir>

Per frame: the histogram of attr & 3 over the non-empty cells of each page that a layer shows, the
K055555 V_INMIX (33) / V_INMIX_ON (34) and the K054338 levels for mix codes 1..3.
"""
import sys, os, glob, re


def ints(row):
    return [int(x, 16) for x in row]


def main():
    d = sys.argv[1]
    files = sorted(glob.glob(os.path.join(d, "state_*.txt")), key=lambda p: int(re.search(r"state_(\d+)", p).group(1)))
    for p in files:
        fr = int(re.search(r"state_(\d+)", p).group(1))
        st = {}
        pages = {}
        for line in open(p):
            k, _, rest = line.partition(" ")
            if k == "VRAM":
                parts = rest.split()
                pages[int(parts[0])] = ints(parts[1:])
            elif k in ("K55REGS", "K38REGS", "K56REGS"):
                st[k] = ints(rest.split())
        k55, k38, k56 = st["K55REGS"], st["K38REGS"], st["K56REGS"]
        hist = {}
        per_layer = []
        for layer in range(4):
            # pages the layer covers: rows regs[8+l] bits 4:3 (start) and 1:0 (span-1); cols regs[12+l]
            rs, rn = (k56[8 + layer] >> 3) & 3, (k56[8 + layer] & 3) + 1
            cs, cn = (k56[12 + layer] >> 3) & 3, (k56[12 + layer] & 3) + 1
            h = [0, 0, 0, 0]
            for r in range(rn):
                for c in range(cn):
                    pg = (((rs + r) & 3) << 2) | ((cs + c) & 3)
                    v = pages.get(pg)
                    if not v:
                        continue
                    for t in range(0, 4096, 2):
                        if v[t + 1] != 0 or v[t] != 0:
                            h[v[t] & 3] += 1
            per_layer.append(h)
        def lvl(reg, hi):
            v = (reg >> 8) if hi else (reg & 0xff)
            return ((~v & 0x1f) << 3) | ((~v & 0x1f) >> 2), (v >> 5) & 1
        l1, a1 = lvl(k38[13], False)
        l2, a2 = lvl(k38[14], True)
        l3, a3 = lvl(k38[14], False)
        print("frame %5d  V_INMIX %02x V_INMIX_ON %02x  levels c1=%3d%s c2=%3d%s c3=%3d%s  en %02x  layers(attr&3 hist):" % (
            fr, k55[33], k55[34], l1, "+" if a1 else " ", l2, "+" if a2 else " ", l3, "+" if a3 else " ", k55[45]),
            " ".join("%c:%s" % ("ABCD"[i], "/".join(str(x) for x in per_layer[i])) for i in range(4)))


if __name__ == "__main__":
    main()
