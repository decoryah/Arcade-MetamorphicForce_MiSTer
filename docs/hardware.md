# Metamorphic Force -- Konami "pre-GX" hardware (GX224)

Source of truth: MAME 0.289 `src/mame/konami/mystwarr.cpp` (machine `metamrph`, sets `metamrph`, `metamrphe`,
`metamrphu`, `metamrphj`, `metamrpha`), `mystwarr_v.cpp`, `konamigx_v.cpp`, `k053250.cpp` and the other device files
named below; SiliconRE (furrtek) for the K053252's timing and the K054338 / K055555 notes. Everything else was measured
with the Lua probes in `tools/lua/`. The video chain here was cross-checked against two independent FPGA
implementations (the ppriest System GX core for the K054338 / K055555 / K056832 / K055673, and jlrh's Konami core set
for the K053250 as Xexex uses it).

## 1. Board

| | |
|---|---|
| Game | Metamorphic Force (EAA / UAA / JAA / AAA), Konami 1993 |
| Board | GX224, the "pre-GX" family it shares with Mystic Warriors, Monster Maulers, Violent Storm, Martial Champion, Gaiapolis |
| Main CPU | MC68000 @ 16.000 MHz (32 MHz / 2) |
| Sound CPU | Z80 @ 8.000 MHz (32 MHz / 4) |
| Sound | 2 x K054539 @ 18.432 MHz, stereo (+ K054321 latch / master volume) |
| EEPROM | ER5911, 128 x 8 |
| Display | 288 x 224 visible, ROT0, 6.000 MHz pixel clock, 384 x 264 -> 15.625 kHz, 59.1856 Hz |
| Palette | 2048 entries, xRGB_888, shadows + highlights |
| ROM | 1.5 MB program, 256 KB sound program, 2 MB tiles (4bpp), 8 MB sprites (4bpp), 256 KB K053250 plane, 3 MB PCM |

Raster: the K053252 timing of the Monster Maulers board, unchanged (the game writes the same registers). MAME's
`metamrph` sets the visible area at lines 15..238 where Monster Maulers has 17..240; the raster here keeps the picture
at line 17 and every line number taken from MAME below is +2 (the benches run both on the same game moment).

## 2. Custom chips

| Chip | Function | Here |
|---|---|---|
| K056832 | tilemap generator, 4 layers over a 4 x 4 grid of 64 x 32 tile pages | `K056832_BPP_5` configured, but only four planes are loaded (the fifth byte is zero); `viostorm_tile_callback`; the game uses the **global Y flip** (reg 0 bit 5, with the correction in reg 0x1e) |
| K055673 | sprite generator (K053246/7 family) | `K055673_LAYOUT_RNG` (4bpp), offsets (-51, -24), z codes honoured |
| K055555 | priority encoder / layer mixer | 4 tile layers + OBJ + SUB1 (the K053250's plane) |
| K054338 | alpha / shadow / brightness colour stage | backdrop, 3 shadow tables, 3 brightness codes, 3 mix levels |
| K053250 ("LVC") | line-scroll / zoom plane, 4bpp | the SUB1 layer: see section 4 |
| K053252 | CRTC / interrupt controller | timing above |
| K054321 | main <-> sound latches, master volume | as Gaiapolis |
| ER5911 | serial EEPROM | as Gaiapolis |

There is no K055550 / K054000 (the protection / memset chips of Monster Maulers and Gaiapolis) and no K053936.

## 3. Main CPU memory map (`metamrph_map`)

| Range | | Function |
|---|---|---|
| `000000-1FFFFF` | R | program ROM (1.5 MB fitted: 000000-07FFFF the 15h / 15f pair of 256 KB, which differ per set, and 100000-1FFFFF the 224a03 / 224a04 pair) |
| `200000-20FFFF` | RW | work RAM (the stack grows down from `210000`: the reset code starts with `lea $210000,a7`) |
| `210000-210FFF` | RW | K053247 sprite RAM (2048 words) |
| `211000-21FFFF` | RW | plain RAM |
| `240000-240007` | W | K053246 registers |
| `244000-24400F` | R | K055673 ROM read-back (`k055673_rom_word_r`, 4bpp) |
| `244010-24401F` | W | K055673 registers |
| `24C000-24FFFF` | RW | K053250 line RAM (16 KB) |
| `250000-25000F` | RW | K053250 registers (a byte each, low half of a word) |
| `254000-25401F` | W | K054338 |
| `258000-2580FF` | W | K055555 |
| `260000-26001F` | RW | K053252 (low byte) |
| `264000` | W | sound IRQ (Z80 IRQ0) |
| `268000-26801F` | RW | K054321 (low byte) |
| `26C000-26C007`, `270000-27003F` | W | K056832 VSCCS, VACSET |
| `274000`, `274002` | R | `P1_P3`, `P2_P4` (player 1 / 2 in the low byte, 3 / 4 in the high) |
| `278000` | R | `IN0`: coins 1-4 (bits 3:0), service 1 / 2 (bits 5:4) |
| `278002` | R | `IN1`: EEPROM DO (bit 0) / READY (bit 1), bit 2 unassigned, bit 3 test, DIPs 7:4 |
| `27C000` | W | EEPROM (DI / CS / CLK on bits 0/1/2) and the watchdog |
| `300000-303FFF` | RW | K056832 tile RAM window (8 KB, mirrored; 16 pages behind regs[0x19]) |
| `310000-311FFF` | R | K056832 ROM read-back (`mw_rom_word_r`: 2048 groups of four chunky bytes behind regs 0x1a / 0x1b) |
| `320000-321FFF` | R | K053250 ROM read-back (`rom_r`: a byte of its ROM at `0x800 * regs[7] + offset / 2`) |
| `330000-331FFF` | RW | palette, 2048 x 32 bit |

The three read-back windows (`244000`, `310000`, `320000`) are there for the game's own ROM self-test; they are real
windows here (the arbiter gives the renderers priority) rather than reading zeros, and the whole-machine bench's `ROMCHK`
compares the renderers' own ROM reads with the image. The power-on tests (about 660 frames) are RAM tests of the work RAM,
sprite RAM, K053250 RAM, palette and all sixteen tile RAM pages, with the results printed on screen.

## 4. Video

### Tiles (K056832, 4bpp)
Pages are 64 x 32 tiles of 8 x 8; a layer takes a rectangle of pages from the 4 x 4 grid. Pixel data: the tile ROM
(`224a08` / `224a09`) holds four chunky bytes a row (byte k = pixels 2k, 2k+1, high nibble first); the K056832's fifth-plane
byte is absent (0). `viostorm_tile_callback`: `color = layer_colorbase | (color >> 2 & 0x0f)` and a non-zero
`attr & 3` marks the tile as category 1 with that value as its **mix code**. The palette entry is
`(color * 16 + pixel) mod 2048` = `{color[6:0], pixel[3:0]}`.

The game's tile layers use **flipped Y** (reg 0 bit 5): MAME flips the whole tilemap, the line-scroll words and the
`regs[0x1e]` correction (11-bit signed) with it, and `rtl/k056832_tilemap.sv` derives the same row mapping. Scroll mode
3 (xy scroll, the attract mode and stage 1) and, from stage 2 on, mode 0 (**line scroll**, layer D) are used with the flip.
The scroll words of a one-page-high layer are source-oriented: with the Y flip the walk starts at entry 255 and runs
backwards (MAME's override for the "software flipped" games, whatever the layer's Y scroll is); unflipped it starts at
the Y scroll. Row scroll (mode 2) steps eight lines to an entry the same way.

The **Hall of Fame** screen (the attract mode's score table) uses row scroll (mode 2) on layers C and D, which are *two
pages high* (`regs[10]` = 0x0011: start row 2, 2 pages; `regs[11]` = 0x0001: start row 0, 2 pages), with the Y flip: the
title "HALL OF FAME" slides in with its own offset for each strip of eight rows. Line scroll (mode 0) on a two-page layer is
used on the lead-in and lead-out of the same screen (layer D, then layer C). For a layer more than one page high MAME walks the page rows one after the other
and the per-page walks join into a single run: with `ay` the layer's Y scroll modulo its height, a row `y` takes entry
`ay - 1 - y` (flipped; `ay + y` unflipped), modulo 512 entries (the layer's 1,024-word area), and a row scroll takes the entry
rounded down to a multiple of eight. This differs from the one-page rule above (entry 255 - y whatever the scroll is). It was
written out from `k056832_device::tilemap_draw_common` and checked against a transcription of that loop (`tools/ls_model.py`:
7.4 million rows for 1 / 2 / 4 pages, flipped or not, line and row scroll, scrolls -600..599, each row drawn by exactly one page,
no difference) and against MAME's own frames of the screen. Before 20261014 the layer was read as one page, the title's
strips took the wrong entries and the picture showed the strips displaced. X flip and a span of three pages are flagged
`unsupported` (never seen).

### Sprites (K055673 RNG layout, 4bpp)
Entry format as the other games (8 words, 256 entries). `metamrph_sprite_callback`:
`priority_mask = (color & 0xe0) >> 2`, `color = colorbase | (color & 0x1f) | mix << 8 | (shadow == 3 ? SKIPSHADOW : 0)`
with `mix = attr[9:8]` and `shadow = attr[11:10]`. The 4bpp layout is one 64-bit word a 16-pixel row (four planes of
two bytes) from the 8 MB sprite ROM; the colour unit is 16 entries and the shadow pen is 15 (1 for a full shadow).
Unlike Monster Maulers (`primode 1`: every z code taken to 0) this game's z codes are honoured: sprites are ordered by
priority, then z, then entry index. The core's renderer keeps a per-pixel z buffer and a separate one for shadows
(`rtl/k053247_draw.sv`).

### K053250 line-scroll plane (SUB1)
The chip is write-only for registers and a RAM for the 68000; the picture comes from an internal double-buffered copy.

* **RAM / DMA.** 16 KB at `24C000`. Writing register 4 with bit 1 going from 1 to 0 triggers the DMA (at most once a
  frame in MAME's model): the first 2048 words are copied into one of two buffers and the page toggles; the picture is drawn
  from the buffer of the *other* page (the second-most-recent DMA). The core latches this at MAME's update instant (the
  end of the frame's active period, line 253 of MAME's count) and holds the 68000 for the copy.
* **Scanline entry** (4 words): colour, ROM offset (256-pixel units), zoom and a signed scroll. Register 4: bit 0 = the
  lines are rows (set) or columns (clear: X and Y swapped), bit 2 = no source clipping, bit 3 / 4 = flip X / Y, bits 7:5 the
  source size and wrap (0: 0xff wide, 256 high; 1: 0x1ff; 4: 0xff with a wrap at 500; others 0x3ff).
* **Pixels** are 4 bits, high nibble first; 0 is transparent; the palette entry is `{K055555 PALBASE_SUB1[2:0], colour[3:0],
  pixel[3:0]}` (the `pix` output of `rtl/k053250_lvc.sv`).
* **Game use** (measured in MAME): ctrl 0x82 (columns, the boss arena's swirl), 0x87 (rows, stage 3's cave backgrounds);
  the attract mode draws nothing with it.

The K053250 is never blended: `rtl/mf_mixer.sv` draws it solid or not at all.

### Mixer (`konamigx_mixer`, K055555 + K054338)
As Monster Maulers (objects in descending priority painted over the backdrop; `d' = (s * a + d * (256 - a)) >> 8`;
brightness set as each enabled tile layer is drawn; shadows). Differences: SUB1 does not blend; a tile layer's mix code
takes its level from the K055555 `V_INMIX` / `V_INMIX_ON` fields (this game's `V_INMIX_ON` is 0xff, so tile mix codes
have no effect in any dumped frame); a sprite's own mix code blends it, and **MAME blends sprite by sprite in turn**
where this core blends the final sprite pixel once: they differ where two translucent sprites overlap (the later
stages' water reflections; 10 of the 115 corpus frames). See the README's "Known differences".

### Interrupts and timing
`ddd_interrupt` is replaced here by `metamrph_interrupt`: IRQ6 (`HOLD_LINE`) at MAME line 24, and IRQ5 at line 248 when
the K053246's register 5 bit 4 (sprite DMA / IRQ enable) is set. The game writes the sprite RAM in vpos 48..160, triggers the
K053250 DMA in 84..157 and rewrites palette / scroll in the IRQ5 handler (248 onward). The renderers build the sprite
list and the K053250's buffer at raster line 255 (MAME's 253).

## 5. Sound

As Gaiapolis (`docs/hardware.md` of that core): Z80 with ROM banks at `8000-BFFF` (regs `F800` bits 3:0), the K054539s at
`E000-E22F` and `E400-E62F`, K054321 at `F000-F003`, timer NMI gated by `F800` bit 4. MAME's `metamrph` sets the
route gains and the per-channel gains of the first chip (channels 4-7 at 1.8, 0-3 at 0.8; the second chip at 0.8
throughout), which `rtl/mf_sound.sv` applies.

## 6. Inputs

`P1_P3` / `P2_P4`: each byte a player: bit 0 left, 1 right, 2 up, 3 down, 4-6 buttons 1-3 (the cabinet has two, Attack and Jump; MAME's third is not used by the game's play), 7 start (active low); the
low byte is players 1 / 2 and the high byte players 3 / 4. `IN0`: coin 1-4 (bits 0-3), service 1-2 (bits 4-5).
`IN1` low byte: bit 0 EEPROM DO, bit 1 READY, bit 2 unassigned (the game polls for 0), bit 3 service mode (low = on),
bit 4 sound output (1 = mono), bit 5 coin mechanism (1 = common), bit 6 number of players (1 = 2, 0 = 4), bit 7
continuous energy increment (0 = yes).
