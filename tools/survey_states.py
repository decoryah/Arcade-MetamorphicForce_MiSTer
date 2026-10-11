#!/usr/bin/env python3
"""Summarise a directory of frozen states (tools/lua/dump_state.lua) and arrange MAME's
snapshots into contact sheets.

    python tools/survey_states.py <dir> [--sheet N]

MAME names its snapshots 0000.png, 0001.png ... in the order they were taken; the
frames are the sorted state_<frame>.txt files, so snapshot i is state i. The
snapshots are renamed snap_<frame>.png here.

For each frame: the K055555 input enables, layer priorities, whether the K053250 is
on and its control byte, how many sprites are active, how many carry a mix code or a
shadow code, how many non-empty tile cells carry a mix code (attribute bits 1:0), and the
K054338 blend registers.
"""
import sys, os, re, glob, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio


def parse(path):
    st = {}
    for line in open(path):
        k, _, rest = line.partition(" ")
        if k in ("#",):
            continue
        st.setdefault(k, []).append(rest.split())
    return st


def ints(row):
    return [int(x, 16) for x in row]


def main():
    d = sys.argv[1]
    sheet_n = int(sys.argv[sys.argv.index("--sheet") + 1]) if "--sheet" in sys.argv else 24
    files = sorted(glob.glob(os.path.join(d, "state_*.txt")), key=lambda p: int(re.search(r"state_(\d+)", p).group(1)))
    frames = [int(re.search(r"state_(\d+)", p).group(1)) for p in files]
    snaps = sorted(glob.glob(os.path.join(d, "*", "[0-9][0-9][0-9][0-9].png")))
    if snaps and len(snaps) == len(frames):
        for p, fr in zip(snaps, frames):
            shutil.move(p, os.path.join(d, "snap_%d.png" % fr))
    print("frame  en   k50(on ctl)  sprites(act mix shd)  tiles(mixcode)  k38.13 k38.14  pri(A B C D SUB1 OBJ)")
    for fr, p in zip(frames, files):
        st = parse(p)
        k55 = ints(st["K55REGS"][0]); k50 = ints(st["K50REGS"][0]); k38 = ints(st["K38REGS"][0])
        spr = ints(st["SPRITERAM"][0])
        act = mix = shd = 0
        for e in range(256):
            w0, w6 = spr[e * 8], spr[e * 8 + 6]
            if w0 & 0x8000:
                act += 1
                if (w6 >> 8) & 3: mix += 1
                if (w6 >> 10) & 3: shd += 1
        tmix = 0
        for row in st.get("VRAM", []):
            v = ints(row[1:])
            for t in range(0, 4096, 2):
                if (v[t] & 3) and v[t + 1]:
                    tmix += 1
        en = k55[45]
        on = bool(en & 0x20)
        pri = (k55[7], k55[10], k55[13], k55[14], k55[16], k55[8])
        print("%5d  %02x   %-3s %02x       %3d %3d %3d        %5d       %04x   %04x    %s" % (
            fr, en, "ON" if on else "-", k50[4], act, mix, shd, tmix, k38[13], k38[14],
            " ".join("%02x" % x for x in pri)))
    # contact sheets
    shots = [(fr, os.path.join(d, "snap_%d.png" % fr)) for fr in frames if os.path.exists(os.path.join(d, "snap_%d.png" % fr))]
    cols = 4
    for s0 in range(0, len(shots), sheet_n):
        chunk = shots[s0:s0 + sheet_n]
        rows = (len(chunk) + cols - 1) // cols
        W, H = 288 + 4, 224 + 4
        out = bytearray(bytes([40]) * (cols * W * rows * H * 3))
        for i, (fr, path) in enumerate(chunk):
            w, h, rgb = pngio.read(path)
            ox, oy = (i % cols) * W, (i // cols) * H
            for y in range(min(h, 224)):
                o = ((oy + y) * cols * W + ox) * 3
                out[o:o + min(w, 288) * 3] = rgb[y * w * 3:y * w * 3 + min(w, 288) * 3]
        name = os.path.join(d, "sheet_%02d.png" % (s0 // sheet_n))
        pngio.write(name, cols * W, rows * H, out)
        print("wrote", name, "frames", [f for f, _ in chunk])


if __name__ == "__main__":
    main()
