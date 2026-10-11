// A transcription of MAME 0.289's k053250_device::draw() and pdraw_scanline32()
// (src/devices/video/k053250.cpp, BSD-3-Clause, Olivier Galibert) onto plain arrays,
// as the specification the K053250 RTL (rtl/k053250_lvc.sv) is tested against.
//
// The bitmap is the visible area in MAME's absolute coordinates, [miny..maxy] x [minx..maxx];
// a drawn pixel is stored as 0x1000 | (colour & 0x1f) << 4 | pixel (the palette offset within
// the layer's 512-entry window), an undrawn one as 0.
#pragma once
#include <cstdint>
#include <cstring>
#include <vector>

struct LvcRef {
    static const int ORIENTATION_SWAP_XY = 1, ORIENTATION_FLIP_X = 2, ORIENTATION_FLIP_Y = 4;
    int offx = -7, offy = 0;
    int minx = 24, maxx = 311, miny = 15, maxy = 238;       // cliprect = the visible area
    int vis_max_x = 311, vis_max_y = 238;
    std::vector<uint8_t> unpacked;                           // the ROM, a nibble each
    uint16_t line_ram[0x800];                                // the buffer the picture is drawn from
    uint8_t  regs[8];
    std::vector<uint16_t> bitmap;                            // (maxy + 1) x (maxx + 1)
    int W() const { return maxx + 1; }

    size_t rom_nibbles = 0;                                  // the ROM's true size (the array is padded)
    void set_rom(const uint8_t *rom, size_t n) {
        rom_nibbles = n * 2;
        unpacked.assign(n * 2 + 4096, 0);                    // MAME reads past the end for a last block's far indices
        for (size_t i = 0; i < n; i++) { unpacked[2 * i] = rom[i] >> 4; unpacked[2 * i + 1] = rom[i] & 0xf; }
    }

    void pdraw_scanline32(int linepos, int scroll, int zoom, uint32_t clipmask, uint32_t wrapmask,
                          uint32_t orientation, const uint8_t *source, int color) {
        const uint32_t FIXPOINT_PRECISION = 16;
        const uint32_t FIXPOINT_PRECISION_HALF = 1 << (FIXPOINT_PRECISION - 1);
        int end_pixel, flip, dst_min, dst_max, dst_start, dst_length;
        uint32_t src_wrapmask;
        int src_fx, src_fdx;
        int pix_data;
        int dst_adv;

        if (!(orientation & ORIENTATION_SWAP_XY)) {
            flip = orientation & ORIENTATION_FLIP_X; dst_min = minx; dst_max = maxx;
        } else {
            flip = orientation & ORIENTATION_FLIP_Y; dst_min = miny; dst_max = maxy;
        }
        if (clipmask) {
            dst_start = -scroll;
            if (dst_start > dst_max) return;
            dst_length = clipmask + 1;
            if (zoom) dst_length = (dst_length << 6) / zoom;
            end_pixel = dst_start + dst_length - 1;
            if (end_pixel < dst_min) return;
            if ((end_pixel -= dst_max) > 0) dst_length -= end_pixel;
            if (dst_length <= 0) return;
            src_fdx = (int)((uint32_t)zoom << (FIXPOINT_PRECISION - 6));
            end_pixel = dst_min;
            if ((end_pixel -= dst_start) > 0) {
                dst_length -= end_pixel;
                dst_start = dst_min;
                src_fx = (int)((uint32_t)end_pixel * (uint32_t)src_fdx + FIXPOINT_PRECISION_HALF);
            } else src_fx = FIXPOINT_PRECISION_HALF;
            if (flip) {
                dst_start = dst_max + dst_min - dst_start - (dst_length - 1);
                src_fx += (dst_length - 1) * src_fdx - 1;
                src_fdx = -src_fdx;
            }
        } else {
            dst_start = dst_min;
            dst_length = dst_max - dst_min + 1;
            src_fdx = (int)((uint32_t)zoom << (FIXPOINT_PRECISION - 6));
            if (!flip) src_fx = (int)((uint32_t)(scroll + dst_min) * (uint32_t)src_fdx + FIXPOINT_PRECISION_HALF);
            else {
                src_fx = (int)((uint32_t)(scroll + dst_max) * (uint32_t)src_fdx + FIXPOINT_PRECISION_HALF - 1);
                src_fdx = -src_fdx;
            }
        }
        src_wrapmask = clipmask ? ~0u : wrapmask;
        dst_adv = 1;
        for (int i = 0; i < dst_length; i++) {
            pix_data = source[((uint32_t)src_fx >> FIXPOINT_PRECISION) & src_wrapmask];
            src_fx = (int)((uint32_t)src_fx + (uint32_t)src_fdx);
            if (pix_data) {
                int pos = dst_start + i * dst_adv;
                if (!(orientation & ORIENTATION_SWAP_XY)) bitmap[linepos * W() + pos] = 0x1000 | ((color & 0x1f) << 4) | pix_data;
                else                                      bitmap[pos * W() + linepos] = 0x1000 | ((color & 0x1f) << 4) | pix_data;
            }
        }
    }

    void draw() {
        bitmap.assign((size_t)(maxy + 1) * W(), 0);
        bool wrap500 = false;
        int map_scrollx = (int16_t)(regs[0] << 8 | regs[1]) - offx;
        int map_scrolly = (int16_t)(regs[2] << 8 | regs[3]) - offy;
        uint8_t ctrl = regs[4];
        int dst_minx = minx, dst_maxx = maxx, dst_miny = miny, dst_maxy = maxy;
        int orientation = 0, dst_height = 512, linedata_adv = 4;
        uint32_t src_wrapmask, src_clipmask, dst_wrapmask;
        int line_start, line_end, scroll_corr, linedata_offs, passes;

        if (!(ctrl & 0x01)) orientation |= ORIENTATION_SWAP_XY;
        if (ctrl & 0x08) orientation |= ORIENTATION_FLIP_X;
        if (ctrl & 0x10) orientation |= ORIENTATION_FLIP_Y;
        switch (ctrl >> 5) {
            case 0: src_wrapmask = src_clipmask = 0xff; dst_height = 0x100; break;
            case 1: src_wrapmask = src_clipmask = 0x1ff; break;
            case 4: src_wrapmask = src_clipmask = 0xff; wrap500 = true; break;
            default: src_wrapmask = src_clipmask = 0x3ff; break;
        }
        if (ctrl & 0x04) src_clipmask = 0;

        if (!(orientation & ORIENTATION_SWAP_XY)) {
            line_start = dst_miny; line_end = dst_maxy;
            scroll_corr = map_scrollx; linedata_offs = map_scrolly;
            if (orientation & ORIENTATION_FLIP_X) scroll_corr = -scroll_corr;
            if (orientation & ORIENTATION_FLIP_Y) { linedata_adv = -linedata_adv; linedata_offs += vis_max_y; }
            dst_wrapmask = ~0u; passes = 1;
        } else {
            line_start = dst_minx; line_end = dst_maxx;
            scroll_corr = map_scrolly; linedata_offs = map_scrollx;
            if (orientation & ORIENTATION_FLIP_Y) {
                scroll_corr = 0x100 - scroll_corr;
                scroll_corr -= 2;
                linedata_offs -= 5;
            }
            if (orientation & ORIENTATION_FLIP_X) { linedata_adv = -linedata_adv; linedata_offs += vis_max_x; }
            if (src_clipmask) { dst_wrapmask = dst_height - 1; passes = 2; }
            else { dst_wrapmask = ~0u; passes = 1; }
        }
        linedata_offs *= 4;
        linedata_offs &= 0x7ff;
        linedata_offs += line_start * linedata_adv;

        for (int line_pos = line_start; line_pos <= line_end; linedata_offs += linedata_adv, line_pos++) {
            linedata_offs &= 0x7ff;
            int color = line_ram[linedata_offs];
            if (color == 0xffff) continue;
            int offset = line_ram[linedata_offs + 1];
            if (!(color & 0xff) && !offset) continue;
            const uint8_t *pix_ptr = &unpacked[((size_t)offset << 8) % rom_nibbles];
            int zoom = line_ram[linedata_offs + 2];
            int scroll = (short)line_ram[linedata_offs + 3];
            if (wrap500 && scroll >= 0x500) scroll -= 0x800;
            scroll += scroll_corr;
            scroll &= dst_wrapmask;
            int i = passes;
            do {
                pdraw_scanline32(line_pos, scroll, zoom, src_clipmask, src_wrapmask, orientation, pix_ptr, color);
                scroll -= dst_height;
            } while (--i);
        }
    }
};
