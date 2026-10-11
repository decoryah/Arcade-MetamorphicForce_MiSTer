// Full-system bench: the whole machine from reset behind the MiSTer memory subsystem, the ROM image
// streamed in through the loader, video out. Runs N frames and writes the frames asked for as raw
// RGB (288 x 224, 32-bit little-endian 0x00RRGGBB), a per-frame trace, and the audio as a WAV.
//
//   tb_mf <image.rom> <eeprom.nv> <frames> <out-prefix>
//
// Environment:
//   SNAPFRAMES=a,b,c   frames whose picture is saved as <prefix>.f<N>.rgb (default: the last)
//   SCHED=survey|play  MAME's scripted inputs of tools/lua/dump_state.lua (coin, start, buttons), by frame
//   SCHEDLAG=n         apply the SCHED inputs n frames later (this core's timeline trails MAME's by a few)
//   ENERGY=1           the "Continuous Energy Increment" DIP (IN1 bit 7) on, as ENERGY=1 in dump_state.lua
//   BACKDOOR=1         place the image straight into the SDRAM model (the loader's address arithmetic, without
//                      the 17 MB of streaming); the streamed load is the default
//   AUDIO=1            write <prefix>.wav (48 kHz stereo)
//   TRACE=1            one line a frame in <prefix>.trace
//   DUMPSTATE=a,b,c    at the end of those frames, write the video chips' registers and RAMs to
//                      <prefix>.state_<N>.txt in the sections of MAME's tools/lua/dump_state.lua
//                      (tools/cmp_state.py compares the two)
//   ROMCHK=1           compare every tile / sprite / K053250 read the renderers complete with the image
#include "Vtb_mf_top.h"
#include "Vtb_mf_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <set>
#include <map>
#include <string>
#include <algorithm>

static const int VIS_W = 288, VIS_H = 224;

static Vtb_mf_top *dut;
static unsigned long long cycles = 0;
static inline void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }

// image layout (byte offsets), mra/*.mra
static const size_t IMG_PROG = 0x000000, IMG_SND = 0x200000, IMG_TILE = 0x240000, IMG_LVC = 0x440000,
                    IMG_PCM = 0x480000, IMG_SPR = 0x880000, IMG_END = 0x1080000;

// the video chips' registers and RAMs as tools/lua/dump_state.lua writes them (a word is 4 hex digits)
static void dump_state(const char *path, int frame) {
    auto &r = *dut->rootp;
    FILE *f = fopen(path, "w"); if (!f) return;
    fprintf(f, "# metamorphic force core state, frame %d\nFRAME %d\n", frame, frame);
    auto words = [&](const char *name, int n, auto get) {
        fprintf(f, "%s", name);
        for (int i = 0; i < n; i++) fprintf(f, " %04x", (unsigned)get(i) & 0xffff);
        fprintf(f, "\n");
    };
    words("K56REGS", 32, [&](int i) { return r.tb_mf_top__DOT__u_core__DOT__k56regs[i]; });
    words("K56REGSB", 4, [&](int i) { return r.tb_mf_top__DOT__u_core__DOT__k56regsb[i]; });
    words("K46REGS", 8, [&](int i) { return r.tb_mf_top__DOT__u_core__DOT__k46regs[i]; });
    words("K47REGS", 8, [&](int i) { return r.tb_mf_top__DOT__u_core__DOT__k47regs[i]; });
    words("K55REGS", 48, [&](int i) { return r.tb_mf_top__DOT__u_core__DOT__k55regs[i]; });
    words("K38REGS", 16, [&](int i) { return r.tb_mf_top__DOT__u_core__DOT__k38regs[i]; });
    words("K50REGS", 8, [&](int i) { return r.tb_mf_top__DOT__u_core__DOT__k50regs[i]; });
    words("K50LINES", 2048, [&](int i) { return r.tb_mf_top__DOT__u_core__DOT__u_lvc__DOT__fbuf[i]; });
    words("PALETTE", 4096, [&](int i) {
        unsigned e = i >> 1;
        return (i & 1) ? r.tb_mf_top__DOT__u_core__DOT__u_main__DOT__pal1[e] : r.tb_mf_top__DOT__u_core__DOT__u_main__DOT__pal0[e]; });
    words("SPRITERAM", 2048, [&](int i) { return r.tb_mf_top__DOT__u_core__DOT__u_main__DOT__sram[i]; });
    for (int pg = 0; pg < 16; pg++) {
        char nm[16]; snprintf(nm, sizeof nm, "VRAM %d", pg);
        words(nm, 4096, [&](int i) {
            unsigned a = (pg << 12) | i;
            return ((unsigned)r.tb_mf_top__DOT__u_mem__DOT__u_vram__DOT__ram_hi[a] << 8) | r.tb_mf_top__DOT__u_mem__DOT__u_vram__DOT__ram_lo[a]; });
    }
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: %s <image.rom> <eeprom.nv> <frames> <out-prefix>\n", argv[0]); return 2; }
    int frames = atoi(argv[3]);
    std::string prefix = argv[4];

    std::vector<unsigned char> img;
    { FILE *f = fopen(argv[1], "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
      fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET); img.resize(n);
      if (fread(img.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); return 1; } fclose(f); }
    if (img.size() != IMG_END) fprintf(stderr, "warning: image is %zu bytes, expected %zu\n", img.size(), IMG_END);
    std::vector<unsigned char> nv(128, 0);
    { FILE *f = fopen(argv[2], "rb"); if (f) { if (fread(nv.data(), 1, 128, f) != 128) fprintf(stderr, "short nv\n"); fclose(f); } }

    // SKIPBOOT=1: cut ~800 frames of power-on RAM tests and two splash delays (simulation shortcuts, not part
    // of any image; tools/lua/dump_state.lua applies the same with SKIPBOOT=1). Found by their code, so every
    // set is handled alike: the POST's first instructions after its three register writes become a jmp to
    // the continuation it ends with, and the two splash screens' outer delay counts become 1.
    if (getenv("SKIPBOOT") && atoi(getenv("SKIPBOOT"))) {
        auto find_code = [&](const std::vector<unsigned char> &pat) -> long {
            for (size_t a = 0x1000; a + pat.size() < 0x10000 && a + pat.size() < img.size(); a++)
                if (!memcmp(&img[a], pat.data(), pat.size())) return (long)a;
            return -1;
        };
        long post = find_code({0x13,0xfc,0x00,0x00,0x00,0x25,0x80,0x5b, 0x13,0xfc,0x00,0xfe,0x00,0x26,0x80,0x0d,
                               0x13,0xfc,0x00,0x00,0x00,0x26,0x40,0x00, 0x72,0x00});
        long cont = find_code({0x43,0xf9,0x00,0x00,0x10,0xe4, 0x4e,0xf9,0x00,0x00,0x4b,0xd6});
        long d1 = find_code({0x3e,0x3c,0x01,0x00, 0x3c,0x3c,0x20,0x00, 0x51,0xce,0xff,0xfe});
        long d2 = find_code({0x30,0x3c,0x00,0x80, 0x32,0x3c,0x30,0x00, 0x51,0xc9,0xff,0xfe});
        if (post < 0 || cont < 0 || d1 < 0 || d2 < 0) { fprintf(stderr, "SKIPBOOT: patch points not found\n"); return 1; }
        // POSTJMP=<hex>: enter the power-on test chain at that address instead of leaving it (to run one of its
        // RAM tests alone: in the EAA set 6208 is the work RAM test, 62f8 the K053250 RAM, 63e8 the 0x210000 RAM)
        if (getenv("POSTJMP")) cont = strtol(getenv("POSTJMP"), nullptr, 16);
        long j = post + 24;
        img[j] = 0x4e; img[j + 1] = 0xf9; img[j + 2] = 0x00; img[j + 3] = 0x00; img[j + 4] = cont >> 8; img[j + 5] = cont & 255;
        img[d1 + 2] = 0x00; img[d1 + 3] = 0x01;
        img[d2 + 2] = 0x00; img[d2 + 3] = 0x01;
        printf("SKIPBOOT: POST $%06lx -> jmp $%06lx, delays at $%06lx $%06lx\n", post, cont, d1, d2);
    }

    std::set<int> snaps;
    if (getenv("SNAPFRAMES")) { char *w = strdup(getenv("SNAPFRAMES")); for (char *t = strtok(w, ","); t; t = strtok(nullptr, ",")) snaps.insert(atoi(t)); }
    std::set<int> dumps;
    if (getenv("DUMPSTATE")) { char *w = strdup(getenv("DUMPSTATE")); for (char *t = strtok(w, ","); t; t = strtok(nullptr, ",")) dumps.insert(atoi(t)); }
    const char *sch = getenv("SCHED");
    bool survey = sch && !strcmp(sch, "survey"), play = sch && !strcmp(sch, "play");
    int schedlag = getenv("SCHEDLAG") ? atoi(getenv("SCHEDLAG")) : 0;   // the machine's timeline runs this many frames behind MAME's
    bool energy = getenv("ENERGY") && atoi(getenv("ENERGY"));
    bool want_audio = getenv("AUDIO") && atoi(getenv("AUDIO"));
    FILE *tr = (getenv("TRACE") && atoi(getenv("TRACE"))) ? fopen((prefix + ".trace").c_str(), "w") : nullptr;

    dut = new Vtb_mf_top;
    const unsigned IN1_IDLE = 0xeb;           // MAME's idle word of 278002: DIPs at their defaults, test switch off
    unsigned in1_val = energy ? (IN1_IDLE & ~0x80u) : IN1_IDLE;
    dut->reset = 1; dut->dl_hold = 1; dut->dl_start = 0; dut->dl_we = 0; dut->eep_we = 0;
    dut->in_p1_p3 = 0xffff; dut->in_p2_p4 = 0xffff; dut->in0 = 0xff; dut->in1 = in1_val;
    for (int i = 0; i < 16; i++) tick();
    dut->reset = 0;
    // wait for the SDRAM's initialisation and the caches
    long w = 0;
    while (!dut->mem_ready) { tick(); if (++w > 2000000) { fprintf(stderr, "memory never became ready\n"); return 1; } }
    printf("memory ready after %llu clocks; loading %zu bytes\n", cycles, img.size());

    bool backdoor = getenv("BACKDOOR") && atoi(getenv("BACKDOOR"));
    unsigned long long t0 = cycles;
    if (backdoor) {
        // straight into the SDRAM model, in the places the loader (target/mister/mf_mem.sv) puts the words
        auto &sd = dut->rootp->tb_mf_top__DOT__chip__DOT__mem;
        const unsigned SD_TILE = 0x000000, SD_PCM = 0x100000, SD_SPR = 0x300000, SD_PROG = 0x700000, SD_SND = 0x800000, SD_LVC = 0x820000;
        for (size_t wa = 0; wa < img.size() / 2; wa++) {
            unsigned v = ((unsigned)img[wa * 2] << 8) | img[wa * 2 + 1];
            size_t b = wa * 2;
            if (b < IMG_SND)       sd[SD_PROG + wa] = v;
            else if (b < IMG_TILE) sd[SD_SND  + (wa - IMG_SND / 2)] = v;
            else if (b < IMG_LVC)  sd[SD_TILE + (wa - IMG_TILE / 2)] = v;
            else if (b < IMG_PCM)  sd[SD_LVC  + (wa - IMG_LVC / 2)] = v;
            else if (b < IMG_SPR)  sd[SD_PCM  + (wa - IMG_PCM / 2)] = v;
            else if (b < IMG_END)  sd[SD_SPR  + (wa - IMG_SPR / 2)] = v;
        }
        printf("image placed by the backdoor\n");
    } else {
        // the image, a byte at a time as the HPS delivers it, held off while the loader's FIFO is full
        dut->dl_start = 1; tick(); dut->dl_start = 0;
        for (size_t i = 0; i < img.size(); i++) {
            while (dut->dl_wait) tick();
            dut->dl_we = 1; dut->dl_addr = (unsigned)i; dut->dl_data = img[i]; tick();
            dut->dl_we = 0;
            if ((i & 0xfffff) == 0xfffff) { printf("  %zu MB loaded\n", (i + 1) >> 20); fflush(stdout); }
        }
        dut->dl_we = 0;
        for (int i = 0; i < 4000; i++) tick();                         // the loader drains
    }
    for (int i = 0; i < 128; i++) { dut->eep_we = 1; dut->eep_waddr = i; dut->eep_wdata = nv[i]; tick(); }
    dut->eep_we = 0;
    printf("image loaded in %llu clocks\n", cycles - t0);
    dut->dl_hold = 0;

    std::vector<unsigned> fb(VIS_W * VIS_H, 0);
    std::vector<short> audio;
    int frame = 0, x = 0, y = 0;
    bool prev_vblank = true;
    unsigned long long steps = 0, frame_steps = 0;
    unsigned irq5 = 0, irq6 = 0, zsteps = 0, dma_clk = 0, overruns = 0, de_px = 0;
    bool irq5_seen = false, irq6_seen = false, prev_irq5 = false, prev_irq6 = false;
    unsigned vc_last = 0xffff;
    unsigned ovl_events = 0, ovl_n = 0, ovl_line[4] = {0}, ovl_src[4] = {0};   // overrunning lines of the frame (first four)
    bool lat_in = false; unsigned long long lat_t0 = 0; std::map<unsigned, unsigned> lat_hist;
    unsigned last_pc = 0;
    std::map<unsigned, unsigned> pc_hist;
    // the input words in the core's form (bit set = released): 274000 / 274002 low byte P1/P2, high byte P3/P4
    auto sched = [&](int n, unsigned &p1, unsigned &c) {
        p1 = 0xff; c = 0xff;                 // P1's byte (bit0 left, 1 right, 2 up, 3 down, 4-6 buttons, 7 start); coins
        auto press = [&](unsigned &v, unsigned m, bool on) { if (on) v &= ~m; };
        if (survey) {
            press(c,  0x01, n > 200 && (n % 120) < 8);
            press(p1, 0x80, n > 260 && (n % 90) < 8 && (n % 120) >= 8);
            if (n > 500) {
                press(p1, 0x10, n % 11 < 4);
                press(p1, 0x20, n % 29 < 3);
                press(p1, 0x40, n % 43 < 3);
                press(p1, 0x02, n % 97 < 40);
                press(p1, 0x01, n % 131 > 100);
                press(p1, 0x04, n % 53 < 20);
                press(p1, 0x08, n % 71 > 60);
            }
        } else if (play) {
            press(c,  0x01, n > 200 && (n % 240) < 8);
            press(p1, 0x80, n > 260 && (n % 90) < 8 && (n % 240) >= 8);
            if (n > 500) {
                press(p1, 0x10, n % 7 < 3);
                press(p1, 0x20, n % 61 < 2);
                press(p1, 0x40, n % 83 < 2);
                press(p1, 0x02, n % 160 < 130);
                press(p1, 0x01, (n + 40) % 400 < 12);
                press(p1, 0x04, n % 97 < 18);
                press(p1, 0x08, n % 131 > 112);
            }
        }
    };

    unsigned long long ck0 = cycles;
    bool romchk = getenv("ROMCHK") && atoi(getenv("ROMCHK"));
    unsigned long long chk_n[3] = {0, 0, 0}, chk_bad[3] = {0, 0, 0};
    bool prev_tack = false, prev_sack = false, prev_lack = false;
    while (frame < frames) {
        tick();
        if (romchk) {
            auto &r = *dut->rootp;
            bool ta = r.tb_mf_top__DOT__chk_tile_ack, sa = r.tb_mf_top__DOT__chk_spr_ack, la = r.tb_mf_top__DOT__chk_lvc_ack;
            if (ta && !prev_tack) {
                unsigned a = r.tb_mf_top__DOT__chk_tile_addr; unsigned long long q = r.tb_mf_top__DOT__chk_tile_q;
                unsigned long long e = 0; for (int b = 0; b < 4; b++) e = (e << 8) | img[IMG_TILE + (size_t)a * 4 + b];
                e <<= 8;                                // the port's fifth byte is 0
                chk_n[0]++;
                if (q != e) { if (chk_bad[0] < 6) printf("TILE a=%05x got %010llx want %010llx (frame %d)\n", a, q, e, frame); chk_bad[0]++; }
            }
            if (sa && !prev_sack) {
                unsigned a = r.tb_mf_top__DOT__chk_spr_addr;
                // 80 bits: [79:16] = the row's 8 bytes, [15:0] = 0
                unsigned long long hi = 0; for (int b = 0; b < 8; b++) hi = (hi << 8) | img[IMG_SPR + (size_t)a * 8 + b];
                auto &q = r.tb_mf_top__DOT__chk_spr_q;
                unsigned long long qhi = ((unsigned long long)q[2] << 48) | ((unsigned long long)q[1] << 16) | (q[0] >> 16);
                unsigned qlo = q[0] & 0xffff;
                chk_n[1]++;
                if (qhi != hi || qlo != 0) { if (chk_bad[1] < 6) printf("SPR a=%05x got %016llx/%04x want %016llx (frame %d)\n", a, qhi, qlo, hi, frame); chk_bad[1]++; }
            }
            if (la && !prev_lack) {
                unsigned a = r.tb_mf_top__DOT__chk_lvc_addr; unsigned long long q = r.tb_mf_top__DOT__chk_lvc_q;
                unsigned long long e = 0; for (int b = 0; b < 8; b++) e = (e << 8) | img[IMG_LVC + (size_t)a * 8 + b];
                chk_n[2]++;
                if (q != e) { if (chk_bad[2] < 6) printf("LVC a=%04x got %016llx want %016llx (frame %d)\n", a, q, e, frame); chk_bad[2]++; }
            }
            prev_tack = ta; prev_sack = sa; prev_lack = la;
        }
        {   // the sprite ROM port's latency, request to ack (the memory subsystem under the machine's own traffic)
            auto &r = *dut->rootp;
            bool sr = r.tb_mf_top__DOT__chk_spr_req, sa = r.tb_mf_top__DOT__chk_spr_ack;
            if (sr && !lat_in) { lat_in = true; lat_t0 = cycles; }
            if (sa && lat_in) { lat_hist[(unsigned)(cycles - lat_t0)]++; lat_in = false; }
            if (!sr) lat_in = false;
        }
        if (want_audio && dut->snd_valid) { audio.push_back((short)dut->snd_l); audio.push_back((short)dut->snd_r); }
        if (dut->dbg_zstep) zsteps++;
        if (dut->dbg_lvc_dma) dma_clk++;
        if (dut->dbg_vcount != vc_last) { vc_last = dut->dbg_vcount; if (dut->dbg_overrun) overruns++; }
        if (dut->dbg_overrun_line) {
            ovl_events++;
            if (ovl_n < 4) { ovl_line[ovl_n] = dut->dbg_vcount; ovl_src[ovl_n] = dut->dbg_overrun_src; ovl_n++; }
        }
        if (dut->dbg_step) {
            steps++; frame_steps++;
            if (dut->dbg_busstate == 0) { last_pc = dut->dbg_addr; pc_hist[last_pc]++; }
        }
        if (dut->dbg_irq5 && !prev_irq5) irq5_seen = true;
        if (dut->dbg_irq6 && !prev_irq6) irq6_seen = true;
        prev_irq5 = dut->dbg_irq5; prev_irq6 = dut->dbg_irq6;
        if (dut->cen_pix) {
            if (dut->de) {
                if (y >= 0 && y < VIS_H && x < VIS_W) fb[y * VIS_W + x] = dut->rgb;
                x++; de_px++;
            } else if (x) { x = 0; y++; }
            if (dut->vblank && !prev_vblank) {          // the end of a frame
                frame++;
                if (tr) {
                    unsigned hot = 0, hotn = 0;
                    for (auto &kv : pc_hist) if (kv.second > hotn) { hotn = kv.second; hot = kv.first; }
                    fprintf(tr, "frame %d: steps=%llu irq5=%d irq6=%d objs=%u overrun=%u unsup=%d de_px=%u pc=%06x hot=%06x(%u) zsteps=%u dma=%u eep_dirty=%d\n",
                            frame, frame_steps, irq5_seen, irq6_seen, (unsigned)dut->dbg_objcount, overruns, (int)dut->dbg_unsupported,
                            de_px, last_pc, hot, hotn, zsteps, dma_clk, (int)dut->eep_dirty);
                    fseek(tr, -1, SEEK_CUR);       // the line's newline: append the overrunning lines (raster line : renderers busy)
                    fprintf(tr, " ovl=%u[%u:%u %u:%u %u:%u %u:%u]\n", ovl_events, ovl_line[0], ovl_src[0], ovl_line[1], ovl_src[1],
                            ovl_line[2], ovl_src[2], ovl_line[3], ovl_src[3]);
                    fflush(tr);
                }
                pc_hist.clear(); zsteps = 0; dma_clk = 0; overruns = 0; frame_steps = 0; de_px = 0;
                ovl_events = 0; ovl_n = 0;
                if (irq5_seen) irq5++;
                if (irq6_seen) irq6++;
                irq5_seen = false; irq6_seen = false;
                if (snaps.count(frame) || (snaps.empty() && frame == frames)) {
                    char path[512]; snprintf(path, sizeof path, "%s.f%d.rgb", prefix.c_str(), frame);
                    FILE *o = fopen(path, "wb"); if (o) { fwrite(fb.data(), 4, fb.size(), o); fclose(o); }
                }
                if (dumps.count(frame)) {
                    char path[512]; snprintf(path, sizeof path, "%s.state_%d.txt", prefix.c_str(), frame);
                    dump_state(path, frame);
                }
                if (frame % 50 == 0) {
                    double mcps = (double)(cycles - ck0) / 1e6;
                    printf("frame %d (%.1f M clocks)\n", frame, mcps); fflush(stdout);
                }
                if (survey || play) {
                    unsigned p1, c; sched(frame - schedlag, p1, c);
                    dut->in_p1_p3 = 0xff00 | p1;
                    dut->in0 = c;
                }
                y = 0; x = 0;
            }
            prev_vblank = dut->vblank;
        }
    }
    if (romchk) printf("ROM check: tile reads %llu (%llu wrong), sprite reads %llu (%llu wrong), K053250 reads %llu (%llu wrong)\n",
                       chk_n[0], chk_bad[0], chk_n[1], chk_bad[1], chk_n[2], chk_bad[2]);
    printf("%d frames, %llu clocks, %llu 68000 steps (%.0f a frame); IRQ5 in %u frames, IRQ6 in %u; unsupported=%d shadow_overlap=%d\n",
           frames, cycles, steps, (double)steps / frames, irq5, irq6, (int)dut->dbg_unsupported, (int)dut->dbg_shadow_overlap);
    if (!lat_hist.empty()) {
        unsigned long long tot = 0, sum = 0;
        for (auto &kv : lat_hist) { tot += kv.second; sum += (unsigned long long)kv.first * kv.second; }
        auto pct = [&](double q) { unsigned long long acc = 0; for (auto &kv : lat_hist) { acc += kv.second; if (acc >= q * tot) return kv.first; } return 0u; };
        printf("sprite ROM port latency (clocks, request to ack): %llu requests, mean %.1f, p50 %u, p90 %u, p99 %u, max %u\n",
               tot, (double)sum / tot, pct(0.5), pct(0.9), pct(0.99), lat_hist.rbegin()->first);
    }
    if (want_audio) {
        std::string wp = prefix + ".wav";
        FILE *wf = fopen(wp.c_str(), "wb");
        if (wf) {
            unsigned data_bytes = audio.size() * 2, rate = 48000;
            auto u32 = [&](unsigned v) { fputc(v & 255, wf); fputc((v >> 8) & 255, wf); fputc((v >> 16) & 255, wf); fputc((v >> 24) & 255, wf); };
            auto u16 = [&](unsigned v) { fputc(v & 255, wf); fputc((v >> 8) & 255, wf); };
            fwrite("RIFF", 1, 4, wf); u32(36 + data_bytes); fwrite("WAVEfmt ", 1, 8, wf);
            u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16);
            fwrite("data", 1, 4, wf); u32(data_bytes);
            fwrite(audio.data(), 2, audio.size(), wf); fclose(wf);
            printf("audio: %zu stereo samples -> %s\n", audio.size() / 2, wp.c_str());
        }
    }
    if (tr) fclose(tr);
    delete dut;
    return 0;
}
