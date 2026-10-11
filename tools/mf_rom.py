#!/usr/bin/env python3
"""MAME's memory regions for Metamorphic Force, rebuilt byte for byte from a romset, and
the check that an image built from an .mra (tools/mra_build.py) holds them in the
layout target/mister/mf_mem.sv expects.

The regions follow ROM_START( metamrph ) in MAME 0.289 src/mame/konami/mystwarr.cpp:

    maincpu    0x200000   ROM_LOAD16_BYTE  01.15h / 02.15f at 0x000000, 224a03 / 224a04 at 0x100000
    soundcpu   0x040000
    k056832    0x500000   ROM_LOADTILE_WORD (GROUPWORD | SKIP(3) | REVERSE) x2: 5-byte groups, the
                          fifth plane's byte is never loaded (ROMREGION_ERASE00): this game's tiles are 4bpp
    k055673    0x800000   ROM_LOAD64_WORD x4 (K055673_LAYOUT_RNG, 4bpp)
    k053250_1  0x040000   the K053250 LVC's ROM, two pixels a byte (high nibble first)
    k054539    0x400000   PCM (2 MB + 1 MB loaded)

    python tools/mf_rom.py metamrph.zip [image.rom]    # verifies the image if given
    MFSET=metamrphu python tools/mf_rom.py metamrph.zip
"""
import sys, zipfile, os, zlib, hashlib

# set -> (the two program-half files: odd byte 15h, even byte 15f)
SETS = {
    "metamrph":  ("224eaa01.15h", "224eaa02.15f"),
    "metamrphe": ("3.15h",        "224eaa02.15f"),
    "metamrpha": ("224aaa01.15h", "224aaa02.15f"),
    "metamrphu": ("224uaa01.15h", "224uaa02.15f"),
    "metamrphj": ("224jaa01.15h", "224jaa02.15f"),
}
NVRAM = {   # the factory EEPROM, inside the merged zip
    "metamrph": "metamrph.nv", "metamrphe": "metamrph.nv", "metamrpha": "metamrpha.nv",
    "metamrphu": "metamrphu.nv", "metamrphj": "metamrphj.nv",
}
CRC = {
    "224a03": 0xa5bedb01, "224a04": 0xada53ba4, "224a05": 0x4b4c985c,
    "224a09": 0x1931afce, "224a08": 0xdc94d53a,
    "224a10": 0x161287f0, "224a11": 0xdf5960e1, "224a12": 0xca72a4b3, "224a13": 0x86b58feb,
    "224a14": 0x3c79b404,
    "224a06": 0x972f6abe, "224a07": 0x61b2f97a,
    "224eaa01.15h": 0x30962c2b, "224eaa02.15f": 0xe314330a,
    "3.15h": 0x8b9f1ba3,
    "224aaa01.15h": 0x12515518, "224aaa02.15f": 0x04ed41df,
    "224uaa01.15h": 0xe1d9b516, "224uaa02.15f": 0x289c926b,
    "224jaa01.15h": 0x558d2602, "224jaa02.15f": 0x9b252ace,
    "metamrph.nv": 0x2c51229a, "metamrpha.nv": 0x6d34a4f2, "metamrphu.nv": 0x1af2f855, "metamrphj.nv": 0x30497478,
}

# image layout: name -> (offset, size)
IMG = {
    "prog":  (0x0000000, 0x200000),   # 68000 program, the map's 2 MB (0x80000..0xfffff zero)
    "snd":   (0x0200000, 0x040000),   # Z80 program
    "tile":  (0x0240000, 0x200000),   # K056832 tile ROM, 4 chunky bytes a row of 8 pixels
    "lvc":   (0x0440000, 0x040000),   # K053250 ROM
    "pcm":   (0x0480000, 0x400000),   # K054539 PCM, 3 MB + 1 MB of zeros
    "spr":   (0x0880000, 0x800000),   # K055673 sprite ROM, a 64-bit word a 16-pixel row
}
IMG_END = 0x1080000


def load_files(path):
    out = {}
    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for f in files:
                with open(os.path.join(root, f), "rb") as fh:
                    d = fh.read()
                out.setdefault(f.lower(), []).append(d)
    else:
        with zipfile.ZipFile(path) as z:
            for i in z.infolist():
                if not i.is_dir():
                    out.setdefault(os.path.basename(i.filename).lower(), []).append(z.read(i))
    return out


def rom(files, name):
    want = CRC[name]
    for d in files.get(name.lower(), []):
        if zlib.crc32(d) & 0xffffffff == want:
            return d
    raise SystemExit("%s: missing or wrong crc" % name)


def regions(path, setname="metamrph"):
    files = load_files(path)
    p1, p0 = SETS[setname]               # 15h = odd bytes, 15f = even bytes
    r = {}
    # maincpu: ROM_LOAD16_BYTE(15h, 0x000001), (15f, 0x000000), (224a03, 0x100001), (224a04, 0x100000)
    m = bytearray(0x200000)
    for name, base in ((p0, 0), (p1, 1), ("224a04", 0x100000), ("224a03", 0x100001)):
        d = rom(files, name)
        m[base:base + 2 * len(d):2] = d
    r["maincpu"] = bytes(m)
    r["soundcpu"] = rom(files, "224a05")
    # k056832: 5-byte groups. ROM_LOADTILE_WORD: 16-bit groups, 3 bytes skipped, REVERSE swaps the pair
    t = bytearray(0x500000)
    for name, off in (("224a09", 0), ("224a08", 2)):
        d = rom(files, name)
        n = len(d) // 2
        t[off + 0: off + 5 * n: 5] = d[1::2]       # file byte 2n+1 first (reversed)
        t[off + 1: off + 1 + 5 * n: 5] = d[0::2]
    r["k056832"] = bytes(t)
    # k055673: ROM_LOAD64_WORD (8-byte stride, 16-bit groups, file order)
    s = bytearray(0x800000)
    for name, off in (("224a10", 0), ("224a11", 2), ("224a12", 4), ("224a13", 6)):
        d = rom(files, name)
        n = len(d) // 2
        s[off + 0: off + 8 * n: 8] = d[0::2]
        s[off + 1: off + 1 + 8 * n: 8] = d[1::2]
    r["k055673"] = bytes(s)
    r["k053250_1"] = rom(files, "224a14")
    r["k054539"] = rom(files, "224a06") + rom(files, "224a07") + bytes(0x100000)
    r["eeprom"] = rom(files, NVRAM[setname])
    return r


def image(reg):
    """The flat image the core loads, from MAME's regions."""
    img = bytearray(IMG_END)
    def put(name, data):
        off, size = IMG[name]
        assert len(data) <= size, name
        img[off:off + len(data)] = data
    put("prog", reg["maincpu"])
    put("snd", reg["soundcpu"])
    k = reg["k056832"]
    n = 0x80000                                   # 512K groups of 5 bytes, 4 of them loaded
    t = bytearray(n * 4)
    for i in range(4):
        t[i::4] = k[i:5 * n:5]
    assert not any(k[4:5 * n:5]), "the fifth plane is expected to be empty"
    put("tile", t)
    put("lvc", reg["k053250_1"])
    put("pcm", reg["k054539"])
    put("spr", reg["k055673"])
    return bytes(img)


def verify(reg, img):
    exp = image(reg)
    if len(img) != len(exp):
        print("image is %d bytes, expected %d" % (len(img), len(exp)))
        return False
    ok = True
    for name, (off, size) in IMG.items():
        a, b = img[off:off + size], exp[off:off + size]
        if a == b:
            print("  %-5s ok" % name)
        else:
            i = next(i for i in range(size) if a[i] != b[i])
            print("  %-5s MISMATCH at +0x%x (image %02x, MAME %02x)" % (name, i, a[i], b[i]))
            ok = False
    return ok


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    setname = os.environ.get("MFSET", "metamrph")
    reg = regions(sys.argv[1], setname)
    for k, v in reg.items():
        print("%-9s %8d bytes  md5 %s" % (k, len(v), hashlib.md5(v).hexdigest()))
    if len(sys.argv) > 2:
        with open(sys.argv[2], "rb") as f:
            ok = verify(reg, f.read())
        print("IMAGE MATCHES MAME'S REGIONS" if ok else "IMAGE DOES NOT MATCH")
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
