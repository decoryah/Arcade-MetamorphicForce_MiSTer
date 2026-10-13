#!/usr/bin/env python3
"""MAME's k056832_device::tilemap_draw_common, scroll-entry bookkeeping only (mame0289, k054156_k054157_k056832.cpp 1309-1647),
transcribed to find which scroll-RAM entry each screen row of a layer uses, and to check a closed form against it.

For one layer: rowspan (1, 2, 4 pages), the layer's Y scroll dy (= register + flip correction, before the layer offset),
the offset, flipy, scrollmode (0 line, 2 row). Returns, for every absolute screen row y in 0..255, the list of
(entry index, page row r) pairs MAME draws that row with (a row drawn by two pages would show in the list)."""
import itertools, sys

PAGE_H = 256

def mame_entries(rowspan, dy, offs_y, flipy, scrollmode, cminy=0, cmaxy=255):
    height = rowspan * PAGE_H
    ay = (dy - offs_y) % height          # (unsigned)(dy - layer_offs) % height, height a power of two times 256
    dy_ = dy - 0                         # dy used for the one-page sdat_start (dy already includes corr)
    if scrollmode == 0:
        line_height, wrapmask, adv = 1, 0x3ff, 2
    elif scrollmode == 2:
        line_height, wrapmask, adv = 8, 0x3ff, 16
    else:
        raise ValueError
    if flipy: adv = -adv
    used = {y: [] for y in range(256)}
    for r in range(rowspan):
        if rowspan > 1:
            sy = ay
            ty = r * PAGE_H
            if not flipy:
                if r == 0 and sy > height - PAGE_H: sy -= height
                if sy + PAGE_H <= ty or sy - PAGE_H >= ty: continue
                ty -= sy
                if ty >= 0:
                    cliph = PAGE_H - ty; clipy = line_starty = ty; line_endy = PAGE_H; sdat_start = 0
                else:
                    cliph = PAGE_H + ty; ty = -ty; clipy = line_starty = 0; line_endy = cliph; sdat_start = ty
                    if scrollmode == 2:
                        sdat_start &= ~7; line_starty -= ty & 7
            else:
                ty += PAGE_H
                if r == rowspan - 1 and sy < PAGE_H: sy += height
                if sy + PAGE_H <= ty or sy - PAGE_H >= ty: continue
                ty -= sy
                if ty <= 0:
                    cliph = PAGE_H + ty; clipy = line_starty = -ty; line_endy = PAGE_H; sdat_start = PAGE_H - 1
                    if scrollmode == 2: sdat_start &= ~7
                else:
                    cliph = PAGE_H - ty; clipy = line_starty = 0; line_endy = cliph; sdat_start = cliph - 1
                    if scrollmode == 2:
                        sdat_start &= ~7; line_starty -= ty & 7
        else:
            cliph = line_endy = PAGE_H; clipy = line_starty = 0
            sdat_start = dy_ if not flipy else PAGE_H - 1
            if scrollmode == 2:
                sdat_start &= ~7; line_starty -= dy_ & 7
        sdat_start += r * PAGE_H
        sdat_start <<= 1
        clipmaxy = clipy + cliph - 1
        sdat_walk = sdat_start; line_y = line_starty
        while line_y < line_endy:
            dminy = line_y; dmaxy = line_y + line_height - 1
            if dminy < clipy: dminy = clipy
            if dmaxy > clipmaxy: dmaxy = clipmaxy
            if not (dminy > cmaxy or dmaxy < cminy):
                ent = (sdat_walk & wrapmask) >> 1       # entry (pair) index in the layer's 1,024-word area
                lo = max(dminy, cminy); hi = min(dmaxy, cmaxy)
                for y in range(lo, hi + 1):
                    used[y].append((ent, r))
            sdat_walk += adv; line_y += line_height
    return used

def closed_form(rowspan, dy, offs_y, flipy, scrollmode, y):
    """the entry the RTL should read for absolute row y"""
    ay = (dy - offs_y) % (rowspan * PAGE_H)
    if rowspan == 1:
        if not flipy:
            e = (dy + y) & 0x1ff                       # existing (checked) one-page rule: raw dy, 9 bits
            if scrollmode == 2: e &= ~7
        else:
            if scrollmode == 0: e = (255 - y) & 0x1ff
            else: e = (248 - 8 * ((y + (dy & 7)) >> 3)) & 0x1ff
    else:
        if not flipy:
            e = (ay + y) & 0x1ff
        else:
            e = (ay - 1 - y) & 0x1ff
        if scrollmode == 2: e &= ~7
    return e

if __name__ == '__main__':
    bad = 0; n = 0; multi = 0
    for rowspan in (1, 2, 4):
        for flipy in (0, 1):
            for scrollmode in (0, 2):
                for dy in range(-600, 600, 1):
                    for offs_y in (0, 3):
                        used = mame_entries(rowspan, dy, offs_y, flipy, scrollmode)
                        for y in range(256):
                            n += 1
                            u = used[y]
                            if len(u) != 1:
                                multi += 1
                                if multi < 6: print('rows covered by', len(u), 'pages:', dict(rowspan=rowspan, dy=dy, offs=offs_y, flipy=flipy, sm=scrollmode, y=y, u=u))
                                continue
                            e = closed_form(rowspan, dy, offs_y, flipy, scrollmode, y)
                            if u[0][0] != e:
                                bad += 1
                                if bad < 10:
                                    print('MISMATCH', dict(rowspan=rowspan, dy=dy, offs=offs_y, flipy=flipy, sm=scrollmode, y=y), 'mame', u[0], 'form', e)
    print('checked', n, 'rows;', bad, 'mismatches;', multi, 'rows not covered exactly once')
