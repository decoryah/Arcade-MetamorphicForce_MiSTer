# The MiSTer memory partition

The machine (`rtl/mf_core.sv`) sees six ROM ports and a tile RAM port, all level request / one-cycle ack. What sits behind them is
`target/mister/mf_mem.sv`, derived from the Monster Maulers core's memory system (itself the Gaiapolis core's; `docs/mister-memory.md`
of gaiapolis-mister has the reasoning for the partition and the caches, which carries over unchanged). What differs here is the data:
this game's tiles and sprites have four bit planes (no fifth-plane byte to carry), there is no rotating plane (so no DDR3 client at
all), and the K053250's 256 KB ROM takes its place as a fourth burst client.

| | MiSTer (DE10-Nano + SDRAM module) |
|---|---|
| SDRAM | 32 MB, 16 bit |
| DDR3 | the HPS's 1 GB, 64 bit, shared with Linux and the scaler: Flip Screen's frame buffers only |
| block RAM | 5.6 Mbit (553 M10K) |

## The partition

```
SDRAM   tiles         2 MB     2-word bursts   a tile row = 4 chunky bytes                                              K056832
        sprites       8 MB     4-word bursts   a 16-pixel row = 4 words (the four planes)                               K055673
        K053250 ROM   256 KB   4-word bursts   a group of 16 pixels = 8 bytes                                          K053250
        PCM           4 MB     single words    (3 MB of ROM and 1 MB of zeros: the K054539 address space is 4 MB)        two K054539s
        68000 program 2 MB     behind a 16 KB cache, 8-word line fills
        Z80 program   256 KB   behind a  4 KB cache, 8-word line fills
DDR3    Flip Screen   2 frame buffers (flip_buf.sv), the finished picture
block   K056832 tile RAM  64K x 16, byte enables
RAM
```

SDRAM word addresses (24 bits): tiles `0x000000`, PCM `0x100000`, sprites `0x300000`, program `0x700000`, sound program
`0x800000`, K053250 ROM `0x820000` (17 MB of the 32).

The image is stored as it comes: the four regions with a row of more than one word keep the image's own order, so the loader
needs no address arithmetic beyond a region base, and a row's words are consecutive in the SDRAM and one burst. The tile port
returns `{w0, w1, 8'h00}` (40 bits: the fifth plane's byte is always 0 on this board, which keeps the ports and the renderers
the Monster Maulers ones), the sprite port `{w0..w3, 16'h0000}` (80 bits) and the K053250 port `{w0..w3}` (64 bits).

## The loader

The ROM image (`mra/*.mra`, `0x1080000` bytes, layout in the MRA header and `mf_mem.sv`) arrives from the HPS a byte at a time.
Pairs are merged into words, queued in a 64-entry FIFO (`dl_wait` holds the HPS off at 32), and a dispatcher classifies each
word by image offset, computes its address (a region base) and writes it as a byte-enabled SDRAM word. The caches are swept on
every download start. The default EEPROM is a separate download (MRA index 2), and the same index is used to save and restore
it (`<nvram>`).

## Video

The 6 MHz pixel clock comes from the 96 MHz system clock (a pixel every 16 clocks; a 384-pixel line is 6,144 clocks, the budget the
renderers were designed against). The mixer's 16-clock schedule is described in `rtl/mf_mixer.sv`. Flip Screen (`flip_buf.sv`)
turns the finished picture 180 degrees through two DDR3 frame buffers, as in the other cores, with `W = 288`. CRT Adjust is
rmonic79's module, as there; with this raster the picture is 288 pixels in a line of 384, starting 80 pixels after the hsync
pulse starts and ending 16 before the next, so H-Size goes to +2 (read period 64 + n quarter-clocks) and H-Position to +12.

## Verification

* `sim/tb_mf.cpp` (`tb_mf_top.sv`): `mf_core` behind `mf_mem` and a behavioural SDRAM chip, with the image streamed through the
  loader a byte at a time (or, with `BACKDOOR=1`, placed straight into the chip by the same address arithmetic). `ROMCHK=1`
  compares every tile, sprite and K053250 read the renderers complete with the image while the game runs.
* `sim/emu/run_emu.sh`: the whole `emu` module of `MetamorphicForce.sv` with the framework's own video path, the SDRAM chip and an
  Avalon DDR3 model; the loader check compares every word of the image with where the ports read it.
* The built-in memory test (`mem_test.sv`, the diagnostic overlay's squares) reads every region back through the machine's own
  ports, twice: ok (read back what was loaded) and stable (the two passes agree), and tests the tile RAM with an address pattern.
