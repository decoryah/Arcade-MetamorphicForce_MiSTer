# Metamorphic Force for MiSTer

Konami's **Metamorphic Force** (1993, GX224 "pre-GX" hardware; sets EAA / UAA / JAA / AAA) for the MiSTer FPGA platform.

The machine descends from the Monster Maulers core for MiSTer, which descends from the Gaiapolis core that **plasticbugs**
wrote for the Analogue Pocket ([analogue-pocket-gaiapolis](https://github.com/plasticbugs/analogue-pocket-gaiapolis)):
Gaiapolis, Monster Maulers and Metamorphic Force are boards of one family (MAME's `mystwarr.cpp`; the same 68000, Z80, two
K054539s, K056832 tilemaps, K053247/K055673 sprites and K055555 mixer). What this repository changes in the machine is what
this game does differently -- 4bpp tiles with per-tile mix codes, 4bpp sprites with z codes, the **K053250 line-scroll /
zoom plane** where the other games have a K053936 rotating plane, the K056832's global Y flip, two scanline interrupts
instead of the vblank one, four players, no protection chip -- and everything around it is the MiSTer platform layer:
memories, clocks, video, audio, controls and ROM/NVRAM loading (`MetamorphicForce.sv`, `target/mister/`, `rtl/pll*`, `mra/`).

No ROMs or other copyrighted data are in this repository; you supply your own MAME `metamrph.zip`.

## Status

**Run on a real MiSTer, by one tester so far.** The repository owner has played 20261011 and 20261012 on a board with all five MRAs,
on HDMI through a RetroTINK 4K and on a 15 kHz analog output: the game runs fine overall and CRT Adjust works. That is one person's test on one board, not a comparison with
the arcade PCB, so please report what yours shows.

Everything else below is simulation and the Quartus tool flow, against MAME 0.289 (the reference for every comparison;
MAME marks these sets `MACHINE_IMPERFECT_GRAPHICS`):

* **Video, frame for frame.** `sim/tb_frame*`: a frozen MAME machine state (the Lua probes in `tools/lua/` dump the video
  chips' registers and RAMs) is rendered through the core's tilemap, K053250, sprite and mixer pipeline and compared with
  MAME's own snapshot of that frame. Three corpora: 48 frames of the attract mode, 7 frames that use the K053250, and 60
  frames spread over a scripted play-through of stages 1-6 (every 1,000th frame to 60,000). **101 of the 115 are
  pixel-identical.** The other 14 differ only where MAME's software mixer does what the chips' pipeline cannot (see "Known
  differences"): 10 by overlapping translucent sprites, 4 by a pixel shadowed twice. For 13 of them MAME was run again
  with each layer set enabled alone: the tile layers and the K053250 alone are pixel-identical in every one, and the
  differences are in the sprites-only render. The slowest line of any corpus frame takes 3,303 of the 6,144 clocks a line allows
  (the K053250's columns, with the memory ideal; the whole-machine bench's sprite ROM port latency is 35 clocks on average,
  97 at worst, and its renderers never overran a line in the 310 frames of the final run).
* **K053250.** `sim/tb_lvc*`: the plane's renderer against a transcription of MAME's `k053250_device::draw` on random
  line RAM, registers, ROM and frame timing, in every orientation / source-size mode: exact. With `+slow=1` the finished
  row is scanned out at the real pixel rate while a DMA (2,050 clocks, holding the 68000) delays the next row, which
  checks that the line buffer's banks hold: a first version flipped them when the row started rather than at the line's
  start, and the whole-machine bench's overrun trace (one line a frame, at a fixed raster line, where the game's DMA
  fell) pointed at it.
* **ROM path.** `tools/make_mra.py`, `tools/mf_rom.py` and `tools/mra_build.py` rebuild MAME's memory regions from the zip
  and `tools/check_regions.py` compares them with what MAME actually loaded (38 slices, all identical); all five MRAs
  build the same 17,301,504-byte image.
* **Whole machine.** `sim/tb_mf*`: the real 68000 and Z80 programs from reset, through the loader and the SDRAM memory
  subsystem, video and audio out. With the power-on tests and two splash delays cut (the same patch applied to MAME's
  run), the machine reaches the game's main loop within 8 frames and at frames 100, 200 and 300 every register and RAM
  of the video chips (K056832 / K053246 / K055673 / K055555 / K054338 / K053250 registers, the K053250 line buffer,
  palette, sprite RAM, all sixteen tile RAM pages) equals MAME's and the **picture is pixel-identical** to MAME's
  snapshot. The only differences are two registers that the bench reads at another instant of the frame than MAME's
  dump. Over 5.5 s of the attract mode's sound the two channels follow MAME's within 1 dB per half second and 0.1 dB
  overall, envelopes correlating at 0.90.
* **The power-on tests.** The same bench with no shortcut, 830 frames from reset: the game's own RAM tests (work RAM,
  K053250 RAM, sprite RAM and the 12 KB of plain RAM behind it, palette, all sixteen tile RAM pages), the sound CPU's
  self-test handshake, the checksum of the 1.5 MB program ROM (through the cache and the SDRAM) and both splash delays
  pass, and at frame 830 the video chips' state and the picture are identical to MAME's of the same frame number. (This
  run found that only 4 KB of that plain RAM was implemented where the test checks 12 KB; the game halted at its "NG"
  screen. Fixed.)
* **The MiSTer top level.** `sim/emu/run_emu.sh`: `MetamorphicForce.sv` itself (only `hps_io` and the PLL stubbed; the
  framework's `arcade_video`, scandoubler and gamma modules and the SDRAM interface are the real ones) with the 17 MB image
  streamed in a byte at a time through the ioctl port, then the EEPROM default. Every word of the image is where the ports
  read it (8,650,752 compared with the SDRAM chip's array), the raster is 384 x 264 x 16 clocks = 59.1856 Hz in every
  frame, the picture is 224 rows of 288 pixels, and the EEPROM reads back through the save path.
* **Quartus Prime Lite 17.0.2** (MiSTer's toolchain) compiles the project for the 5CSEBA6U23I7 (the figures are 20261012's;
  each release's summaries are in `releases/`): 43 % of the ALMs (18,043 of 41,910), 94 % of the block RAM (520 of 553
  M10K, so little is left), 69 DSPs, and timing closes at 96 MHz with every check positive (setup +0.29 ns on the core's
  clock, hold +0.24, recovery +1.51, removal +1.02 in the slow 100 C model; the framework's own HDMI clock domain closes
  with +0.42 ns). `tools/check_ram_depth.py` finds all 34 RAM
  blocks the RTL declares built at their declared depth (an earlier core's fit built two-bank line buffers shallower than
  declared, which no simulator shows).

## Release history

**20261011** -- the first release. Built from this tree; its fitter and timing summaries are
`releases/metamorphicforce_20261011.fit.summary` and `.sta.summary`. Run on a MiSTer by the repository owner (see
"Status"). Two faults the benches found on the way, and which a board would have shown, are fixed in it: the game's
power-on RAM test checks 12 KB of plain RAM behind the sprite RAM (it halted at its "NG" screen with 4 KB implemented), and
the K053250's line buffer flipped banks when a row started rather than at the line's start (a line a frame, where the
game's DMA falls, would have shown the next row's pixels from the middle of the line on).

**20261012** -- Scandoubler Fx and MiSTer.ini's `forced_scandoubler` give a picture (see the paragraph under the OSD
table). In 20261011 they produced no vertical sync, so a monitor or an HDMI scaler fed from the scandoubled output would
have shown a frozen picture; the core now hands the framework's scandoubler the horizontal blank alone (`hde` from
`mf_video.sv`). The machine and the 15 kHz output are unchanged: the whole-machine bench's 15 kHz run gives the same log
and a byte-identical scaler picture as the tree of 20261011. Checked in simulation (`sim/emu/run_sd.sh`; the top level with
`FSD=1` / `FX=n`: 448 rows in 528 lines, exact frame period) and run on a MiSTer by the repository owner: it works. Fitter and timing summaries:
`releases/metamorphicforce_20261012.fit.summary` and `.sta.summary` (setup +0.29 ns on the core's clock; the fit of
20261011 had +0.87 ns there, the same logic closes with less margin on another placement).

## Install

1. Unzip `MetamorphicForce_MiSTer_20261012.zip` over the root of the SD card, or copy by hand the RBF
   (`releases/metamorphicforce_20261012.rbf`) to `/media/fat/_Arcade/cores/` and the `.mra` files from `mra/` to
   `/media/fat/_Arcade/`. Keep the RBF's `metamorphicforce_` name and date: MiSTer finds the core by the MRA's `<rbf>` name
   plus the date, and takes the newest if there are several, so delete older `metamorphicforce_*.rbf` files.
2. Put your MAME 0.289 `metamrph.zip` in `/media/fat/games/mame/` (the parent set; the USA, Japan and Asia versions' ROMs
   are in the merged set, or in `metamrphu.zip` / `metamrphj.zip` / `metamrpha.zip` next to it). No ROMs are distributed.
3. Start `Metamorphic Force (World ver EAA)` from the Arcade menu. The ROM image is 17 MB and takes a few seconds to load.
   The game's power-on tests take about 11 seconds, as on the board.

## OSD options

| Option | Values | |
|---|---|---|
| Aspect ratio | Original, Full Screen, [ARC1], [ARC2] | Original is 4:3 |
| Flip Screen | Off, On | The picture turned 180 degrees on every output. Done on the finished picture through a frame buffer in the DDR3, so it adds one frame (17 ms) of delay while it is on and nothing when it is off |
| Scandoubler Fx | None, HQ2x, CRT 25%, CRT 50%, CRT 75% | |
| CRT Adjust | submenu: CRT Adjust Off, On; then CRT H-Size 0..+2 / -16..-1, CRT H-Position -48..+12, CRT V-Shift -16..+15 | Fits the picture to a 15 kHz analog (CRT) output without the monitor losing sync. Does nothing while the scandoubler is in use. Off by default |
| Number of Players | 2, 4 | The board's DIP: with 4, the game takes players 3 and 4 (joysticks 3 and 4; keyboard 3 / 4 start, 7 / 8 coin) |
| Coin Mechanism | Common, Independent | The board's DIP |
| Continuous Energy Increment | No, Yes | The board's DIP |
| Audio | Stereo, Mono | The board's mono/stereo input; Mono puts the left mix on both channels |
| Test Mode | Off, On | The board's test switch: the game's service menu |
| Diagnostic overlay | Off, On | Three rows of 32 squares along the bottom of the picture, and the built-in memory test (a few seconds, black screen) after each ROM load |
| SDRAM read capture | Normal, Late | Late samples SDRAM reads one clock later, for a module that answers slowly. At this core's clock phase it is expected to make no difference |
| Reset | | Restarts the machine (the ROM stays loaded) |

Scandoubler Fx and MiSTer.ini's `forced_scandoubler` make the core's 15 kHz picture a 31 kHz one (every line twice; HQ2x and
the CRT filters on top). In `metamorphicforce_20261011` they gave no vertical sync at all, so the monitor or the HDMI
scaler would have seen a stream without frames: a frozen picture with the sound still playing. The framework's scandoubler
takes its line timing from the horizontal blank's edges and needs them on every line, vertical blanking included, and
this core's blank was the picture window, high through the whole vertical blank. Fixed in `metamorphicforce_20261012`:
the core gives it the horizontal blank alone (`hde` from `mf_video.sv`) with the vertical blank separate. The 15 kHz
output and HDMI without Scandoubler Fx, which is what the board tests used, are as they were. (Found from a report on the
Gaiapolis core, which had the same wiring.)

**Reading the diagnostic overlay.** Turn it on *before* the ROM loads (OSD, then load the game again), or the memory test
is skipped and its squares stay dark. Row 0: frame counter, PLL locked, memory ready, download, test hold, core reset, IRQ5,
68000 stepped, core resets seen, test done / running, tile RAM ok, tile RAM bad words (log scale), Z80 stepped. Row 1: the
68000's address, then the six regions read back equal to what was loaded (prog, snd, tile, lvc, pcm, spr), then sound heard.
Row 2: the same regions read stably twice, DDR3 FIFO overflow, lines overrun last frame, sprites in the list / 4, then
flags: unsupported tile-layer mode met, a second shadow on a pixel, K053250 DMA seen, IRQ6 seen, flip buffer underrun, and
which renderers (tilemap, K053250, sprites) were still busy when a line started. Row 1's first 24 squares are the live 68000
bus address and flicker.

The game is horizontal (ROT0). On a gamepad the default mapping is A / B / R for buttons 1 / 2 / 3, Start for Start and
Select for Coin (remap it in MiSTer's usual way); up to four joysticks. From the keyboard: 1-4 start, 5-8 coin and F2 for the
test switch, on top of MiSTer's usual keyboard-as-joystick. The game's own settings and high scores live in its EEPROM,
which MiSTer saves and restores.

## What differs from Monster Maulers

| | Monster Maulers | Metamorphic Force |
|---|---|---|
| picture | 288 x 224, MAME visarea y 17 | the same raster; MAME's visarea starts at line 15 (the benches account for the 2 lines) |
| program | 1.5 MB | 1.5 MB, same layout |
| tiles (K056832) | 5bpp, layers covering the whole page map | 4bpp, per-tile mix codes (category 1), the chip's global Y flip |
| sprites (K055673) | `LAYOUT_GX` 5bpp, offsets (-42, -22), z codes suppressed | `LAYOUT_RNG` 4bpp, offsets (-51, -24), z codes honoured |
| SUB1 plane | K053936 ROZ, 8bpp, per-line registers | **K053250** line-scroll / zoom, 4bpp, 256 KB ROM, double-buffered line RAM with a DMA |
| protection | K055550 memset engine | none |
| interrupts | IRQ5 at vblank | IRQ6 at MAME line 24, IRQ5 at line 248 (if the K053246's sprite IRQ is enabled) |
| inputs | P1 + coin, P2 | four players: P1_P3 / P2_P4, IN0 (4 coins), IN1 (DIPs) |
| ROM image | 22 MB; DDR3 for the ROZ plane | 17 MB; no DDR3 client but Flip Screen |

The hardware, region by region (map, chips, the K053250, timing), is in `docs/hardware.md`; the memory partition in
`docs/mister-memory.md`.

## Known differences from MAME

Both are cases where MAME's software mixer does something one pixel at a time that the chips' pipeline cannot; the
frame bench's single-layer renders (below) show that tiles and the K053250 are identical in every frame and that the
differences live in the sprite layer.

* **Overlapping translucent sprites.** MAME blends sprite by sprite in turn (each blended onto what is there, including
  an earlier translucent sprite); this core's renderer resolves one sprite pixel per screen pixel and the mixer blends
  it once, as the hardware's pipeline would. They differ where two translucent sprites overlap: the water reflections
  of the later stages (two reflection sprites over the same pixels blend to 0.70 where one blends to 0.45) and one text
  effect of the attract mode. 10 of the 115 frames of the corpus show it, in 10 to 3,707 pixels.
* **A pixel shadowed twice.** The renderer keeps one shadow flag per pixel; MAME's mixer darkens a pixel once for every
  shadow sprite that covers it. The core sets `dbg_shadow_overlap` (the overlay's row 2) when it happens. 4 frames of the
  corpus have such pixels (28 to 543 of them, each one shadow step darker in MAME). Whether the real K055673 darkens
  twice is not known.
* **The 68000's pace.** The kernel is TG68K.C paced by a token bucket calibrated against MAME's frame timing; state
  dumps of the video chips' registers and RAMs are what is compared, and they agree.
* The power-on test chain (about 660 frames, 11 s) and two splash delays (about 140 frames) run as on the board.

## Repository layout

| Path | |
|---|---|
| `MetamorphicForce.sv`, `MetamorphicForce.q*`, `MetamorphicForce.sdc`, `files.qip` | the MiSTer top level (`emu`), Quartus project, timing constraints |
| `rtl/` | the machine: `mf_core` (the board), `mf_main` (68000 map), `mf_video`, `mf_mixer`, `mf_sound`, renderers (`k056832_tilemap`, `k053250_lvc`, `k053247_*`), `k054539`, `k054321`, `er5911` (`rtl/data/` generated tables, `rtl/pll*` the clock PLL) |
| `target/mister/` | the memory subsystem (`mf_mem`, `rom_cache`, `ddr_arb`), SDRAM controller, memory test, Flip Screen |
| `modules/` | vendored TG68K.C, tv80 and CRT Adjust (`modules/VENDOR.md`) |
| `sys/` | the MiSTer framework (identical to Template_MiSTer) |
| `mra/` | the five MRAs, generated by `tools/make_mra.py` |
| `sim/` | Verilator benches: frozen-state frames, the K053250 differential bench, whole machine, Flip Screen, the MiSTer top level end to end |
| `tools/` | MRA generator and ROM image builder, comparison tools, MAME Lua probes, the generators of `rtl/data` (`gen_*.py`), `release.py` / `package.py` |
| `docs/` | `hardware.md`, `mister-memory.md` |

## Building

Quartus Prime Lite 17.0.2 (the version MiSTer's framework is built with):

```
quartus_sh --flow compile MetamorphicForce
```

`tools/make_mra.py metamrph.zip` regenerates the MRAs. The simulation benches need Verilator 5 and a C++ compiler, and a
ROM image you build yourself from your own romset (it checks every part's CRC and the image's md5):

```
python tools/mra_build.py "mra/Metamorphic Force (World ver EAA).mra" metamrph.zip metamrph.rom   # 17,301,504 bytes
```

Run the benches from a Linux filesystem (WSL's own, not `/mnt/c`); the whole-machine bench simulates at about a tenth
of a MHz, so a hundred frames takes about twenty minutes.

## Credits

* **plasticbugs** -- the Gaiapolis core for the Analogue Pocket, the machine this one is built on (`rtl/`, the SDRAM
  controller `target/mister/sdram_ctrl.sv` and the memory test `mem_test.sv`, adapted; `tools/mra_build.py`), and through
  it the MAME team's work as the reference, **Tobias Gubener**'s TG68K.C (LGPL-3.0) and **Guy Hutchison**'s tv80 (MIT),
  vendored under `modules/`.
* **Claude** (Anthropic's AI model, used through Claude Code) -- the Metamorphic Force machine changes and the MiSTer
  layer, written together with the repository owner: the K053250 plane, the 4bpp renderers, the Y-flip tilemap, the
  mixer's changes, the memory subsystem, the MRAs, the simulation benches and this documentation.
* **Sorgelig** and the MiSTer team -- the framework (`sys/`, GPL).
* **rmonic79** (Umberto Parisi), with help from **Andrea Bogazzi** (asturur) --
  [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust), the module behind the CRT Adjust options
  (`modules/crt-adjust/crt_adjust.sv`; GPL-3.0 or later).
* **furrtek** -- [SiliconRE](https://github.com/furrtek/SiliconRE/tree/master/Konami)'s silicon-traced models and notes of
  the K053252 timing chip (the raster), the K054338 and K055555.
* **Jose Tejada (jotego)** -- JTFRAME's MiSTer SDRAM clock phase and read-capture timing, which this core's PLL and
  controller settings follow; and, with the other authors of the independent Konami cores read as references (jlrh's
  `konami-fpga`, ppriest's `Arcade-KonamiGX_MiSTer`), the cross-checks of the K053250, K054338, K055555, K056832 and K055673.

## Licence

Copyright (C) 2026 decoryah. GPL-3.0, as the Pocket core this is built on (see `LICENSE`). The vendored TG68K.C (LGPL-3.0), CRT Adjust (GPL-3.0 or
later) and tv80 (MIT) in `modules/` keep their own licences (`modules/VENDOR.md`), and the MiSTer framework in `sys/` is
GPL (see the headers of its files).
