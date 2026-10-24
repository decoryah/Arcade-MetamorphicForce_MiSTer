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

### Fast load (the MRA's `address=` attribute)

With `address="0x32000000"` on the index-0 `<rom>`, a recent Main_MiSTer copies the whole assembled image into the DDR3 at that
byte address in one `memcpy`, bracketed by a download that has no data bytes: it starts with `ioctl_addr` = the image's length
(an ordinary download starts at 0, which is how `MetamorphicForce.sv` tells them apart: `fast_dl`) and ends with it. The core
stays in reset from the start until `mf_mem` has pushed the whole image through the loader (`fl_done`). `mf_mem` reads the image
back in 256-byte blocks (a 32-beat burst through the arbiter's client port, `ddr_arb.sv` `c_*`, into a 32 x 64-bit buffer),
swaps each little-endian halfword to the image's big-endian word and pushes it into the loader's FIFO, as long as the FIFO has
room; the dispatcher behind it is unchanged, so the layout is the one above. The memory test (`mem_test.sv`) sums the bytes of the
image as they stream in, so the replay hands it the same bytes (high, then low, one word every three clocks) and its sums are those
of the image. Nothing else of the DDR3 is touched: the window's offset 0x400000 beats (byte 0x32000000, `FL_BASE`) is clear of the
Flip Screen buffers (0x80000 beats). The loader accepts about a word per ten clocks, so the 8.65 million words take about a second;
that, not the DDR3, is the limit. `sim/emu/run_emu.sh` with `FAST=1` models the HPS side.

## Video

The 6 MHz pixel clock comes from the 96 MHz system clock (a pixel every 16 clocks; a 384-pixel line is 6,144 clocks, the budget the
renderers were designed against). The mixer's 16-clock schedule is described in `rtl/mf_mixer.sv`. Flip Screen (`flip_buf.sv`)
turns the finished picture 180 degrees through two DDR3 frame buffers, as in the other cores, with `W = 288`. CRT Adjust is
rmonic79's module, as there; with this raster the picture is 288 pixels in a line of 384, starting 80 pixels after the hsync
pulse starts and ending 16 before the next, so H-Size goes to +2 (read period 64 + n quarter-clocks) and H-Position to +12.

### The scandoubler needs the horizontal blank alone

`sys/scandoubler.v` (Scandoubler Fx, MiSTer.ini's `forced_scandoubler`) takes its line timing from the edges of
`HBlank`: `hb` falling starts a line (`hcnt`, `sd_hcnt`, `hde_start` and the sampling of `vb_in` hang on it), and it
shifts `vs_in` / `vb_in` through at those edges. It therefore expects `HBlank` to toggle on every line of the frame,
the vertical blank lines included, with `VBlank` separate. The first release gave it `~de`, where `de` is the visible
*rectangle* (`in_active_x && in_active_y`): `HBlank` stayed high through the whole vertical blank, the scandoubler's
counters, reset only on that falling edge, ran on through the blank lines, and its doubled output had no vertical sync
and no vertical blank (measured by probing the mixer in `sim/emu/run_sd.sh`: `vs_sd` and `vb_sd` constant 0 while the
mixer's `vs_g` pulsed once a frame, `hs_sd` only in the 448 picture lines of a frame). The 15 kHz path is not affected,
as `arcade_video` without the scandoubler only uses the combined blank for `VGA_DE`, so the board tests on a 15 kHz
analog output and on HDMI through a scaler with no scandoubler did not show it.

`mf_video.sv` now also outputs `hde` (the horizontal window alone, registered with `de`), through `mf_core.sv`;
`MetamorphicForce.sv` gives `arcade_video` `HBlank = ~hde` (registered with the rest in `vq_*`) and keeps `VBlank =
vblank`. `VGA_DE` comes out the same rows as before (the video mixer ANDs the two). CRT Adjust (`hb_in`) and Flip Screen
keep the combined blank (`hblank_c`), which is what they want; CRT Adjust is gated off while the scandoubler is in use.

Measured with `sim/emu/run_sd.sh` (this core's raster into `arcade_video`, nothing else): with the scandoubler on
(forced, CRT 25 / 50 / 75 %) 528 lines a frame, 448 picture rows of 288 pixels (HQ2x 576), line period 3,072 clocks,
frame period exactly 16 x 384 x 264 = 1,622,016 clocks, each source line twice in order, and a vertical sync in every
mode; with the old wiring, none.

The whole top level (`sim/emu/run_emu.sh`, skip-boot, 30 frames after the load) agrees: with the forced scandoubler,
HQ2x or CRT 50 % the monitor gets 448 rows in 528 lines (288 pixels a row, 576 with HQ2x) and every frame period is
exactly 1,622,016 clocks; the picture the scaler gets with the forced scandoubler or CRT 50 % is, on every other row,
the 15 kHz picture byte for byte. The 15 kHz run after the change gives the same log (frame periods, geometry, EEPROM
read back) and a byte-identical scaler picture as the run of the tree before it.

### Scale (integer scaling for the HDMI scaler)

The OSD's Scale item (`status[34:32]`: Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+) goes to the framework's
`video_freak` (`sys/video_freak.sv`, with `sys/math.sv`), which sits behind `arcade_video` and turns the aspect ratio plus
the picture's own size into `VIDEO_ARX` / `VIDEO_ARY`. With Normal they pass through (4:3, or the ARC entries); with an integer
mode they carry the exact size in pixels (bit 12 set) that the scaler is to give the picture: the picture's row count times
the largest whole factor that fits the scaler's height, and a width that is the aspect ratio's (V-Integer) or a whole multiple
of the 288-pixel row (the HV modes: Narrower is the multiple below the aspect width, HV-Integer+ the one above, HV-Integer the
nearer of the two). The menu's order is the user's; `video_freak`'s `SCALE` input counts 0 Normal, 1 V-Integer, 2 Narrower,
3 HV-Integer+, 4 HV-Integer, and `MetamorphicForce.sv` maps one onto the other (`scale_sel`).

Full Screen (Aspect ratio ARX = ARY = 0) has no proportions for the integer rule to size the width from, and the rule then
sizes the height from the width and asks for more rows than the screen has. With an integer Scale the core therefore hands
`video_freak` the scaler's own size (`HDMI_WIDTH` x `HDMI_HEIGHT`) as the proportions (`fs_int`), so Full Screen is the largest
whole-number picture in the screen's aspect; with the scaler's size unknown (direct video) it passes through as before.

### Colours (the board's video DAC) and the one-clock stage

`MetamorphicForce.sv` takes the machine's picture signals as `mfc_*` and gives everything downstream (the diagnostic overlay,
Flip Screen, CRT Adjust, `arcade_video`) the registered `mf_*`: the colour through the Colours table (`rtl/data/k054573_dac.hex`,
256 bytes in logic, no RAM block; `status[35]` selects MAME's palette as it is) and the pixel enable, the syncs and the blanks
one clock later, as a whole. The delay of the enable matters: the mixer's last painter's step lands in the clock before the pixel
enable (`rtl/mf_mixer.sv`: `rgb` is stable in the clock `cen_pix` is high), so a register on the colour alone is read a clock
early, which dropped the topmost layer (the "CREDIT 00" text on the first screens) in a first attempt. The check that caught it
is the one that matters: with Colours on MAME the whole top level's scaler picture is byte for byte the picture of every earlier
build (md5 `84c3fa48…`), and the Board DAC picture is, pixel for pixel and at the same place, the table applied to it
(`sim/emu/dac_check.py`: 0 of 193,536 channel values off). A run with both modes on the same frames is the first check to make.

## Verification

* `sim/tb_mf.cpp` (`tb_mf_top.sv`): `mf_core` behind `mf_mem` and a behavioural SDRAM chip, with the image streamed through the
  loader a byte at a time (or, with `BACKDOOR=1`, placed straight into the chip by the same address arithmetic). `ROMCHK=1`
  compares every tile, sprite and K053250 read the renderers complete with the image while the game runs.
* `sim/emu/run_emu.sh`: the whole `emu` module of `MetamorphicForce.sv` with the framework's own video path, the SDRAM chip and an
  Avalon DDR3 model; the loader check compares every word of the image with where the ports read it. `FX=<n>` / `FSD=1`
  turn on Scandoubler Fx / the framework's forced scandoubler and the bench then checks 448 rows in 528 lines. `FAST=1` models
  the HPS side of the MRA's `address=` attribute (the image copied into the DDR3 model, then a download with no bytes): the core
  must come out of reset on its own, the same loader check applies, and the scaler's picture must equal the streamed load's.
  `SCALE=0..4` / `AR=0..3` / `HW`, `HH` set the Scale item, the Aspect ratio and the scaler's output size, and the bench
  checks the size the core asks the scaler for against the rule above, worked out independently from the picture's rows and
  the settings. `COLOURS_MAME=1` is Colours on MAME (the default is the board DAC's curve); two runs of the same frames,
  one each, go to `sim/emu/dac_check.py`, and every run that is compared with an older one picture for picture uses it.
* `sim/emu/run_sd.sh`: `mf_video`'s raster into the framework's `arcade_video` and nothing else, with Scandoubler Fx and
  forced_scandoubler selectable (`HONLY=0` is the first release's wiring, which has no vertical sync once scandoubled).
* The built-in memory test (`mem_test.sv`, the diagnostic overlay's squares) reads every region back through the machine's own
  ports, twice: ok (read back what was loaded) and stable (the two passes agree), and tests the tile RAM with an address pattern.
  The bench (`PROBE=1`, with and without `FAST=1`) reads the test's six running sums back and compares them with the sums of
  the image's six regions: all six equal after a fast load and after a streamed one, so the replay hands the test the
  image's bytes, not just the loader.
