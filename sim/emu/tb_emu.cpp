// End-to-end bench of the MiSTer top (MetamorphicForce.sv): plays the HPS. It
//   * resets, waits for the PLL stand-in and the memories,
//   * streams the ROM image through the ioctl port (MRA index 0), a byte per
//     STRIDE clocks and held off by ioctl_wait, then the EEPROM default (index 2),
//   * sets OSD options and runs frames, capturing the picture as the scaler gets it
//     (VGA_*, 288x224) and checking the raster (frame period, rows, geometry),
//   * with PROBE=1, checks Flip Screen: the picture is the flip stage's input turned
//     180 degrees, one frame late,
//   * reads the EEPROM back through the upload path (the save) and compares it.
//
//   tb_emu <image> <eeprom-default-file> <frames> <out-prefix> [diag] [noload]
// <image> is the MiSTer-layout image (0x1080000 bytes, tools/mra_build.py on a mra/*.mra);
// the EEPROM default is the 128-byte .nv file.
#include "Vtb_emu_top.h"
#include "Vtb_emu_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vtb_emu_top *dut;
static unsigned long long cycles = 0;
#define HPSV(n) dut->rootp->tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__##n
static inline void tick() { dut->CLK_50M = 0; dut->eval(); dut->CLK_50M = 1; dut->eval(); cycles++; }

static const int VIS_W = 288, VIS_H = 224;
static const long IMG_LEN = 0x1080000;
static const unsigned long long LINE_CLK = 16ull * 384, FRAME_CLK = LINE_CLK * 264;
// the framework's scandoubler (Scandoubler Fx, forced_scandoubler): every line twice, HQ2x also twice as wide
static int sd_mul = 1; static bool sd_hq = false;
static std::vector<unsigned> frame_now(VIS_W * VIS_H), frame_last(VIS_W * VIS_H);
static int de_count = 0, frames_done = 0, de_last_count = 0;
static bool prev_vs = false;
static unsigned long long last_frame_cycle = 0, frame_period = 0;
static std::vector<unsigned long long> periods;
static bool record_periods = false;
static long long audio_nonzero = 0;
static unsigned errors = 0;

#ifdef PROBE
// signals inside the top level (the bench is built with --public-flat-rw when PROBE is set)
#define EMUV(n) dut->rootp->tb_emu_top__DOT__u_emu__DOT__##n
static unsigned pk_ovl = 0, pk_core = 0, pk_gade = 0, pk_cen = 0, pk_en = 0, pk_arc = 0, pk_vga_any = 0;
static unsigned pk_fix = 0, pk_frz = 0, pk_sd = 0, pk_rt = 0, gb_or = 0, gb_and = 0x3fffff;
// the picture entering the flip stage (the overlay's output), three frames deep, for the Flip Screen check
static std::vector<unsigned> ovl_now(288 * 224), ovl_f1(288 * 224), ovl_f2(288 * 224), ovl_f3(288 * 224);
static int ovl_count = 0; static bool prev_gavs = false;
static void probe() {
    {
        bool gavs = EMUV(mf_vs);
        if (gavs && !prev_gavs) {
            if (ovl_count == 288 * 224) { ovl_f3 = ovl_f2; ovl_f2 = ovl_f1; ovl_f1 = ovl_now; }
            ovl_count = 0;
        }
        prev_gavs = gavs;
        if (EMUV(mf_cen_pix) && EMUV(mf_de)) {
            if (ovl_count < 288 * 224) ovl_now[ovl_count] = ((unsigned)EMUV(ovl_r) << 16) | ((unsigned)EMUV(ovl_g) << 8) | (unsigned)EMUV(ovl_b);
            ovl_count++;
        }
    }
    unsigned ovl = ((unsigned)EMUV(ovl_r) << 16) | ((unsigned)EMUV(ovl_g) << 8) | (unsigned)EMUV(ovl_b);
    if (ovl > pk_ovl) pk_ovl = ovl;
    if ((unsigned)EMUV(mf_rgb) > pk_core) pk_core = EMUV(mf_rgb);
    if (EMUV(mf_de)) pk_gade++;
    if (EMUV(mf_cen_pix)) pk_cen++;
    pk_en = (EMUV(status)[0] >> 9) & 1;
    {
        { unsigned gb = EMUV(gamma_bus); gb_or |= gb; gb_and &= gb; }
        unsigned fix = EMUV(arcade_video__DOT__RGB_fix);
        if (fix > pk_fix) pk_fix = fix;
        if (EMUV(arcade_video__DOT__video_mixer__DOT__frz)) pk_frz++;
        if (EMUV(arcade_video__DOT__video_mixer__DOT__scandoubler)) pk_sd++;
        unsigned rt = EMUV(arcade_video__DOT__video_mixer__DOT__rt) | EMUV(arcade_video__DOT__video_mixer__DOT__gt) | EMUV(arcade_video__DOT__video_mixer__DOT__bt);
        if (rt) pk_rt++;
    }
    if (dut->VGA_R | dut->VGA_G | dut->VGA_B) pk_vga_any++;
    if (dut->VGA_DE && (dut->VGA_R | dut->VGA_G | dut->VGA_B)) pk_arc++;
}
#endif
// the geometry of the analog picture as the monitor gets it: lines from the vsync pulse to the first row with picture,
// the number of rows, and where each row starts and how wide it is, in clocks from the hsync pulse before it
static bool g_prev_hs = false, g_prev_de = false;
static unsigned long long g_hs_clk = 0, g_de_clk = 0;
static int g_line = 0, g_rows = 0, g_lines_frame = 0; static long g_first = -1; static unsigned long long g_vs_clk = 0;
static long g_smin = 1 << 30, g_smax = -1, g_wmin = 1 << 30, g_wmax = -1;
static int geo_rows = 0, geo_lines = 0; static long geo_first = -1;
static long geo_smin = 0, geo_smax = 0, geo_wmin = 0, geo_wmax = 0;
static void video_watch() {
#ifdef PROBE
    probe();
#endif
    if (audio_nonzero == 0 && (dut->AUDIO_L != 0 || dut->AUDIO_R != 0)) audio_nonzero = 1;
    {   // geometry at clock level (VGA_HS, VGA_DE, and the frame's end at VGA_VS)
        bool hs = dut->VGA_HS, de = dut->VGA_DE;
        if (hs && !g_prev_hs) { g_line++; g_lines_frame++; g_hs_clk = cycles; }
        if (de && !g_prev_de) {
            long s = (long)(cycles - g_hs_clk); g_de_clk = cycles; g_rows++;
            if (g_first < 0) g_first = (long)(cycles - g_vs_clk);
            if (s < g_smin) g_smin = s; if (s > g_smax) g_smax = s;
        }
        if (!de && g_prev_de) { long w = (long)(cycles - g_de_clk); if (w < g_wmin) g_wmin = w; if (w > g_wmax) g_wmax = w; }
        g_prev_hs = hs; g_prev_de = de;
        if (dut->VGA_VS && !prev_vs) {
            geo_first = g_first; geo_rows = g_rows; geo_lines = g_lines_frame; geo_smin = g_smin; geo_smax = g_smax; geo_wmin = g_wmin; geo_wmax = g_wmax;
            g_vs_clk = cycles; g_line = 0; g_lines_frame = 0; g_first = -1; g_rows = 0; g_smin = 1 << 30; g_smax = -1; g_wmin = 1 << 30; g_wmax = -1;
        }
    }
    bool vs = dut->VGA_VS;
    if (vs && !prev_vs) {                       // a frame ends
        if (de_count == VIS_W * VIS_H * sd_mul) frame_last = frame_now;
        de_last_count = de_count;
        frame_period = cycles - last_frame_cycle; last_frame_cycle = cycles;
        if (record_periods) periods.push_back(frame_period);
        de_count = 0; frames_done++;
    }
    prev_vs = vs;
    if (dut->CE_PIXEL && dut->VGA_DE) {
        unsigned px = ((unsigned)dut->VGA_R << 16) | ((unsigned)dut->VGA_G << 8) | dut->VGA_B;
        if (sd_mul == 1) { if (de_count < VIS_W * VIS_H) frame_now[de_count] = px; }
        else {   // scandoubled: keep the even rows (and the even columns of HQ2x's double width) as the 288 x 224 picture
            int w2 = VIS_W * (sd_hq ? 2 : 1), row = de_count / w2, col = de_count % w2;
            if (!(row & 1) && !(sd_hq && (col & 1)) && row / 2 < VIS_H) frame_now[(row / 2) * VIS_W + (sd_hq ? col / 2 : col)] = px;
        }
        de_count++;
    }
}
static void run(long n) { while (n--) { tick(); video_watch(); } }

static void set_status(int bit, int v) {
    int w = bit / 32, b = bit % 32;
    unsigned x = HPSV(r_status)[w];
    HPSV(r_status)[w] = v ? (x | (1u << b)) : (x & ~(1u << b));
}

// stream bytes of data[0..n) as one download of the given index; stride = clocks per byte
static void download(int index, const unsigned char *data, long n, int stride, long addr0 = 0) {
    HPSV(r_index) = index; HPSV(r_download) = 1; HPSV(r_addr) = addr0;
    run(8);
    for (long i = 0; i < n; i++) {
        long guard = 0;
        while (HPSV(r_wait_seen) && guard++ < 1000000) run(1);
        HPSV(r_addr) = addr0 + i; HPSV(r_dout) = data[i]; HPSV(r_wr) = 1; run(1);
        HPSV(r_wr) = 0; run(stride - 1);
    }
    run(40);
    HPSV(r_download) = 0; HPSV(r_index) = 0;
    run(8);
}

static void write_ppm(const char *path, const std::vector<unsigned> &px, int w, int h) {
    FILE *f = fopen(path, "wb"); if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int i = 0; i < w * h; i++) { unsigned v = px[i]; fputc((v >> 16) & 255, f); fputc((v >> 8) & 255, f); fputc(v & 255, f); }
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: %s <image> <eeprom.nv> <frames> <out-prefix> [diag] [noload]\n", argv[0]); return 2; }
    int frames = atoi(argv[3]); const char *pre = argv[4]; bool diag = argc > 5 && atoi(argv[5]); bool noload = argc > 6 && atoi(argv[6]);
    std::vector<unsigned char> img(IMG_LEN), nv(128);
    FILE *f = fopen(argv[1], "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    if (fread(img.data(), 1, IMG_LEN, f) != (size_t)IMG_LEN) { fprintf(stderr, "short image\n"); return 1; } fclose(f);
    f = fopen(argv[2], "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }
    if (fread(nv.data(), 1, 128, f) != 128) { fprintf(stderr, "short eeprom\n"); return 1; } fclose(f);

    // simulation shortcut, as sim/tb_mf.cpp (and tools/lua/dump_state.lua for MAME) apply it to the image: the
    // power-on tests and the two splash delays cut (found by their code)
    if (getenv("SKIPBOOT") && atoi(getenv("SKIPBOOT"))) {
        auto find_code = [&](const std::vector<unsigned char> &pat) -> long {
            for (size_t a = 0x1000; a + pat.size() < 0x10000; a++) if (!memcmp(&img[a], pat.data(), pat.size())) return (long)a;
            return -1;
        };
        long post = find_code({0x13,0xfc,0x00,0x00,0x00,0x25,0x80,0x5b, 0x13,0xfc,0x00,0xfe,0x00,0x26,0x80,0x0d,
                               0x13,0xfc,0x00,0x00,0x00,0x26,0x40,0x00, 0x72,0x00});
        long cont = find_code({0x43,0xf9,0x00,0x00,0x10,0xe4, 0x4e,0xf9,0x00,0x00,0x4b,0xd6});
        long d1 = find_code({0x3e,0x3c,0x01,0x00, 0x3c,0x3c,0x20,0x00, 0x51,0xce,0xff,0xfe});
        long d2 = find_code({0x30,0x3c,0x00,0x80, 0x32,0x3c,0x30,0x00, 0x51,0xc9,0xff,0xfe});
        if (post < 0 || cont < 0 || d1 < 0 || d2 < 0) { fprintf(stderr, "SKIPBOOT: patch points not found\n"); return 1; }
        long j = post + 24;
        img[j] = 0x4e; img[j + 1] = 0xf9; img[j + 2] = 0; img[j + 3] = 0; img[j + 4] = cont >> 8; img[j + 5] = cont & 255;
        img[d1 + 2] = 0; img[d1 + 3] = 1; img[d2 + 2] = 0; img[d2 + 3] = 1;
    }

    dut = new Vtb_emu_top;
    dut->RESET = 1; run(40); dut->RESET = 0;
    if (diag) set_status(9, 1);                 // diagnostic overlay + memory test at the end of the load
    bool flip = getenv("FLIP") && atoi(getenv("FLIP"));
    if (flip) set_status(12, 1);                // Flip Screen
    {   // CRT Adjust (status[14] on, [19:15] H-Size, [26:20] H-Position, [31:27] V-Shift), values as the OSD menu counts them
        auto field = [&](int lo, int w, int v) { for (int i = 0; i < w; i++) set_status(lo + i, (v >> i) & 1); };
        if (getenv("CRT") && atoi(getenv("CRT"))) set_status(14, 1);
        if (getenv("HSIZE")) { int v = atoi(getenv("HSIZE")); field(15, 5, v >= 0 ? v : 19 + v); }
        if (getenv("HPOS")) { int v = atoi(getenv("HPOS")); field(20, 7, v >= 0 ? v : 61 + v); }
        if (getenv("VSHIFT")) field(27, 5, atoi(getenv("VSHIFT")) & 31);
    }
    {   // the framework's settings the OSD does not hold: forced_scandoubler (MiSTer.ini); Scandoubler Fx is OSD status[5:3]
        if (getenv("FSD") && atoi(getenv("FSD"))) HPSV(r_fsd) = 1;
        if (getenv("FX")) { int v = atoi(getenv("FX")); for (int i = 0; i < 3; i++) set_status(3 + i, (v >> i) & 1); }
        const bool fsd = getenv("FSD") && atoi(getenv("FSD")); const int fx = getenv("FX") ? atoi(getenv("FX")) : 0;
        if (fsd || fx) {
            sd_hq = (fx == 1); sd_mul = sd_hq ? 4 : 2;
            printf("scandoubler on (Fx %d, forced %d): expect %d rows of %d pixels, %d lines a frame\n", fx, (int)fsd, 2 * VIS_H, VIS_W * (sd_hq ? 2 : 1), 2 * 264);
        }
    }
    if (getenv("MONO") && atoi(getenv("MONO"))) set_status(8, 1);
    if (getenv("TEST") && atoi(getenv("TEST"))) set_status(6, 1);
    run(40000);                                  // SDRAM init, cache sweeps
    if (noload) {                                // a quick check of the video path: no ROM, the overlay is the test pattern
        printf("up after %llu clocks; no image download (video-path check)\n", cycles);
        download(2, nv.data(), 128, 40);
        run(200000);
    } else {
        printf("up after %llu clocks; loading %ld bytes\n", cycles, IMG_LEN);
        unsigned long long t0 = cycles;
        download(0, img.data(), IMG_LEN, 2);
        printf("image loaded in %llu clocks\n", cycles - t0);
        {   // the loader's work against the layout of target/mister/mf_mem.sv: every word of the image where the
            // memory subsystem's ports (and the backdoor of sim/tb_mf.cpp) expect it, in the SDRAM chip's array
            run(4000);
            auto &sd = dut->rootp->tb_emu_top__DOT__chip__DOT__mem;
            const unsigned SD_TILE = 0x000000, SD_PCM = 0x100000, SD_SPR = 0x300000, SD_PROG = 0x700000, SD_SND = 0x800000, SD_LVC = 0x820000;
            unsigned long long words = 0, bad_w = 0;
            auto chk_sd = [&](size_t a, unsigned v) { words++; if (sd[a] != v) { if (bad_w < 6) printf("  SDRAM word %06zx: %04x, expected %04x\n", a, (unsigned)sd[a], v); bad_w++; } };
            for (size_t wa = 0; wa < (size_t)IMG_LEN / 2; wa++) {
                unsigned v = ((unsigned)img[wa * 2] << 8) | img[wa * 2 + 1];
                size_t b = wa * 2;
                if (b < 0x200000)      chk_sd(SD_PROG + wa, v);
                else if (b < 0x240000) chk_sd(SD_SND + (wa - 0x100000), v);
                else if (b < 0x440000) chk_sd(SD_TILE + (wa - 0x120000), v);
                else if (b < 0x480000) chk_sd(SD_LVC + (wa - 0x220000), v);
                else if (b < 0x880000) chk_sd(SD_PCM + (wa - 0x240000), v);
                else                   chk_sd(SD_SPR + (wa - 0x440000), v);
            }
            printf("loader check: %llu words of the image compared with the SDRAM chip, %llu wrong\n", words, bad_w);
            if (bad_w) { printf("  FAIL: the streamed image is not where the ports read it\n"); errors++; }
        }
        download(2, nv.data(), 128, 40);
        printf("EEPROM default loaded; frames so far %d\n", frames_done);
    }

    // run frames: the first complete frame after the load
    int start_frames = frames_done;
    int target = start_frames + frames;
    unsigned long long guard = 0;
    record_periods = true;
    while (frames_done < target && guard++ < 4000000000ull) tick(), video_watch();
    printf("%d frames after the load, last frame had %d visible pixels (expect %d)\n", frames_done - start_frames, de_last_count, VIS_W * VIS_H * sd_mul);
    if (de_last_count != VIS_W * VIS_H * sd_mul) { printf("  FAIL: visible pixel count\n"); errors++; }

    {   // the raster's period: 16 clocks a pixel, 384 x 264
        printf("frame period %llu clocks (expect %llu = %.4f Hz)\n", frame_period, FRAME_CLK, 96e6 / (double)FRAME_CLK);
        if (frame_period != FRAME_CLK) { printf("  FAIL: the frame period\n"); errors++; }
        // CRT Adjust's V-Shift moves the vertical sync by whole lines, so the frame in which it takes effect (one of
        // the first after the load, when the setting is already there) is a different length; every other frame is whole
        int ok = 0, bad = 0, trans = 0;
        const bool vshift = getenv("CRT") && atoi(getenv("CRT")) && getenv("VSHIFT") && atoi(getenv("VSHIFT")) != 0;
        for (size_t i = 1; i < periods.size(); i++) {    // [0] may span the load
            if (periods[i] == FRAME_CLK) ok++;
            else if (vshift && i <= 3) { trans++; printf("  frame %zu: period %llu clocks = %.3f lines (V-Shift taking effect)\n", i, periods[i], periods[i] / (double)LINE_CLK); }
            else { bad++; printf("  frame %zu: period %llu clocks = %.3f lines\n", i, periods[i], periods[i] / (double)LINE_CLK); }
        }
        printf("frame periods after the load: %d whole, %d at a V-Shift step, %d other\n", ok, trans, bad);
        if (bad) { printf("  FAIL: a frame of the wrong length\n"); errors++; }
    }
    unsigned nonblack = 0; for (unsigned v : frame_last) if (v) nonblack++;
    printf("last captured frame: %u non-black pixels\n", nonblack);
    printf("geometry (last frame): %d rows with picture, %d lines a frame; first row %ld clocks after the vsync pulse (%.3f lines);"
           " rows start %ld..%ld clocks after hsync, %ld..%ld clocks wide\n",
           geo_rows, geo_lines, geo_first, geo_first / (double)LINE_CLK, geo_smin, geo_smax, geo_wmin, geo_wmax);
    if (sd_mul > 1 && (geo_rows != 2 * VIS_H || geo_lines != 2 * 264)) {
        printf("  FAIL: the scandoubled raster should be %d rows in %d lines\n", 2 * VIS_H, 2 * 264); errors++;
    }
#ifdef PROBE
    printf("probe: status[9]=%u  core de clocks %u  core cen_pix ticks %u  max core rgb %06x  max overlay out %06x  VGA nonzero clocks %u (in DE %u)\n",
           pk_en, pk_gade, pk_cen, pk_core, pk_ovl, pk_vga_any, pk_arc);
    printf("probe: arcade_video RGB_fix max %06x  mixer frz set on %u clocks  scandoubler set on %u clocks  mixer rt/gt/bt non-zero on %u clocks\n", pk_fix, pk_frz, pk_sd, pk_rt);
    printf("probe: gamma_bus bits ever set %06x, bits always set %06x  (bit 19 is gamma_en)\n", gb_or, gb_and);
    if (flip) {
        // Flip Screen: the picture the scaler gets is the flip stage's input turned 180 degrees, from the frame before
        auto flipped_match = [&](const std::vector<unsigned> &src) {
            long ok = 0;
            for (int y = 0; y < VIS_H; y++) for (int x = 0; x < VIS_W; x++)
                if (frame_last[y * VIS_W + x] == src[(VIS_H - 1 - y) * VIS_W + (VIS_W - 1 - x)]) ok++;
            return ok;
        };
        long m1 = flipped_match(ovl_f1), m2 = flipped_match(ovl_f2), m3 = flipped_match(ovl_f3);
        long fbest = m1 > m2 ? m1 : m2; if (m3 > fbest) fbest = m3;
        long same = 0; for (int i = 0; i < VIS_W * VIS_H; i++) if (frame_last[i] == ovl_f2[i]) same++;
        printf("flip check: the last picture equals the overlay's turned 180 degrees: %ld / %ld / %ld of %d pixels (1, 2, 3 frames back);"
               " unflipped it would match %ld\n", m1, m2, m3, VIS_W * VIS_H, same);
        if (fbest != VIS_W * VIS_H) { printf("  FAIL: the flipped picture is not the overlay turned 180 degrees\n"); errors++; }
    }
#else
    if (flip) printf("(Flip Screen check needs PROBE=1)\n");
#endif
    // a blank picture would make the checks above pass on nothing
    if (nonblack == 0) { printf("  FAIL: the picture is blank\n"); errors++; }
    write_ppm((std::string(pre) + "_scaler.ppm").c_str(), frame_last, VIS_W, VIS_H);
    printf("DDR3: reads %d, writes %d, protocol errors %d\n", (int)dut->rootp->tb_emu_top__DOT__ddr__DOT__rd_cmds,
           (int)dut->rootp->tb_emu_top__DOT__ddr__DOT__wr_cmds, (int)dut->rootp->tb_emu_top__DOT__ddr__DOT__protocol_errors);
    if (dut->rootp->tb_emu_top__DOT__ddr__DOT__protocol_errors) errors++;

    // the EEPROM through the upload path (what the save reads)
    HPSV(r_upload) = 1; unsigned bad = 0;
    for (int i = 0; i < 128; i++) { HPSV(r_addr) = i; run(6); if (HPSV(r_din_seen) != nv[i]) { if (bad < 4) printf("  eeprom byte %d: read %02x expected %02x\n", i, HPSV(r_din_seen), nv[i]); bad++; } }
    HPSV(r_upload) = 0; run(4);
    printf("EEPROM read back through the upload port: %u of 128 bytes differ\n", bad);
    if (bad) errors++;
    printf("audio samples non-zero seen: %lld; upload requests %d\n", audio_nonzero, (int)HPSV(upload_reqs));

    printf("%s: %u errors, %llu clocks\n", errors ? "FAIL" : "PASS", errors, cycles);
    delete dut; return errors ? 1 : 0;
}
