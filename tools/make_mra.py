#!/usr/bin/env python3
"""Writes the five Metamorphic Force MRAs (mra/*.mra) from a MAME metamrph.zip.

The image layout is the one target/mister/mf_mem.sv loads (docs/mister-memory.md):
the regions in the order below, 0x1080000 bytes. The default EEPROM is a
separate download (index 2): the HPS then also saves and restores it
(<nvram index="2">), so the game's settings and records persist.

    python tools/make_mra.py "/path/to/MAME 0.289 ROMs (merged)/metamrph.zip"
"""
import sys, zipfile, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mf_rom

SETS = [
    # setname, title, region, nvram file inside the zip
    ("metamrph",  "Metamorphic Force (World ver EAA)",           "World", "metamrph.nv"),
    ("metamrphe", "Metamorphic Force (World ver EAA, alternate)", "World", "metamrph.nv"),
    ("metamrphu", "Metamorphic Force (USA ver UAA)",             "USA",   "metamrphu/metamrphu.nv"),
    ("metamrphj", "Metamorphic Force (Japan ver JAA)",           "Japan", "metamrphj/metamrphj.nv"),
    ("metamrpha", "Metamorphic Force (Asia ver AAA)",            "Asia",  "metamrpha/metamrpha.nv"),
]
CRC = {k: "%08x" % v for k, v in mf_rom.CRC.items()}


def hexdump(data):
    lines = []
    for i in range(0, len(data), 16):
        lines.append(" ".join("%02X" % b for b in data[i:i + 16]))
    return "\n".join(lines)


def mra(setname, title, region, nvdata):
    p1, p0 = mf_rom.SETS[setname]            # 15h = odd bytes, 15f = even bytes
    return f"""<misterromdescription>
    <rotation>horizontal</rotation>
    <name>{title}</name>
    <setname>{setname}</setname>
    <mameversion>0289</mameversion>
    <year>1993</year>
    <manufacturer>Konami</manufacturer>
    <players>4</players>
    <joystick>8</joystick>
    <rbf>metamorphicforce</rbf>
    <region>{region}</region>
    <platform>Konami pre-GX</platform>

    <!--
      Flat image for the Metamorphic Force core (target/mister/mf_mem.sv):

        0x0000000  0x200000  68000 program: 2 x 256 KB at 0, 2 x 512 KB at 0x100000 (the map's 2 MB)
        0x0200000  0x040000  Z80 sound program, 16 x 16 KB banks
        0x0240000  0x200000  K056832 tile ROM, 4bpp: per 8-pixel row 4 chunky bytes
                             (the board's fifth plane is not populated)
        0x0440000  0x040000  K053250 LVC ROM, two pixels a byte
        0x0480000  0x400000  K054539 PCM (3 MB, then 1 MB of zeros)
        0x0880000  0x800000  K055673 sprite ROM, 64-bit words: a 16-pixel row of the four planes
        0x1080000            end

      Expects the MAME 0.289 merged romset (metamrph.zip holding the parent and the
      clones) or the split sets: parts are found by name, whatever folder holds them.
    -->
    <rom index="0" zip="{setname}.zip|metamrph.zip" md5="None">

        <!-- 68000 program, 16-bit big-endian words: the even byte is the 15f half, the odd byte the 15h half -->
        <interleave output="16">
            <part name="{p0}" crc="{CRC[p0]}" map="01"/>
            <part name="{p1}" crc="{CRC[p1]}" map="10"/>
        </interleave>
        <part repeat="0x80000">00</part>
        <interleave output="16">
            <part name="224a04" crc="{CRC['224a04']}" map="01"/>
            <part name="224a03" crc="{CRC['224a03']}" map="10"/>
        </interleave>

        <!-- Z80 sound program -->
        <part name="224a05" crc="{CRC['224a05']}"/>

        <!--
          K056832 tile ROM. MAME's ROM_LOADTILE_WORD is ROM_GROUPWORD|ROM_SKIP(3)|ROM_REVERSE: 5-byte
          groups, one per 8-pixel row, of which this game loads the four packed-chunky bytes (the low 4
          bits of each pixel); the fifth plane's byte is empty (ROMREGION_ERASE00).
        -->
        <interleave output="32">
            <part name="224a09" crc="{CRC['224a09']}" map="0012"/>
            <part name="224a08" crc="{CRC['224a08']}" map="1200"/>
        </interleave>

        <!-- K053250 LVC ROM (224a14) -->
        <part name="224a14" crc="{CRC['224a14']}"/>

        <!-- K054539 PCM samples, shared by both chips -->
        <part name="224a06" crc="{CRC['224a06']}"/>
        <part name="224a07" crc="{CRC['224a07']}"/>
        <part repeat="0x100000">00</part>

        <!--
          K055673 sprite ROM, 64-bit words (ROM_LOAD64_WORD, 8-byte stride): one 64-bit word
          is the four planes of one 16-pixel row (left 8 pixels in bytes 0-3, right 8 in
          bytes 4-7, one byte a plane): K055673_LAYOUT_RNG.
        -->
        <interleave output="64">
            <part name="224a10" crc="{CRC['224a10']}" map="00000021"/>
            <part name="224a11" crc="{CRC['224a11']}" map="00002100"/>
            <part name="224a12" crc="{CRC['224a12']}" map="00210000"/>
            <part name="224a13" crc="{CRC['224a13']}" map="21000000"/>
        </interleave>
    </rom>

    <!-- the board's factory EEPROM: without it the game boots upside down with an error -->
    <rom index="2">
        <part>
{hexdump(nvdata)}
        </part>
    </rom>
    <nvram index="2" size="128"/>

    <buttons names="Button 1,Button 2,Button 3,Start,Coin" default="A,B,R,Start,Select" count="3"/>
</misterromdescription>
"""


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    z = zipfile.ZipFile(sys.argv[1])
    names = {}
    for i in z.infolist():
        names.setdefault(os.path.basename(i.filename), []).append(i)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mra")
    os.makedirs(out, exist_ok=True)
    for base, want in CRC.items():
        if base in names and not any(("%08x" % i.CRC) == want for i in names[base]):
            raise SystemExit("%s: no copy with crc %s" % (base, want))
    for setname, title, region, nv in SETS:
        info = z.getinfo(nv)
        data = z.read(nv)
        assert len(data) == 128, (nv, len(data))
        for n in mf_rom.SETS[setname]:
            assert any(("%08x" % i.CRC) == CRC[n] for i in names[n]), (n, CRC[n])
        path = os.path.join(out, title + ".mra")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(mra(setname, title, region, data))
        print("wrote", os.path.normpath(path), "(nvram crc %08x)" % info.CRC)


if __name__ == "__main__":
    sys.exit(main())
