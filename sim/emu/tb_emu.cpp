// The MiSTer top-level bench's driver (sim/emu/run_emu.sh): plays the HPS for Aquarium.sv (after the owner's Rabbit and Hexion cores'
// benches).
//   Vtb_emu_top <image.rom> <frames after the load> <out prefix>
// The image (tools/aquarium_rom.py) is streamed through the ioctl port a byte at a time (index 0), honouring ioctl_wait; with FAST=1
// the MRA's fast load instead: the image put into the DDR3 at byte 0x32000000, then a download that carries only the length. Then the
// DIP switches (index 254, DSW=<4 hex digits>, the DSW word, default MAME's FFFF). After the load every byte the image puts in the
// SDRAM is compared with the expected layout (rtl/aquarium_loader.sv's rules, worked out here from the image). Then the machine runs:
// the picture the scaler gets (VGA_* on CE_PIXEL with VGA_DE) of every SNAPEVERY-th frame is written as <prefix>.f<n>.ppm, n the
// core's frame number (the system bench's numbering: the picture shown after vblank n, drawn from it), and the raster is checked:
// the frame period, the pixels and rows of a frame, the lines, where the rows sit, and the size the core asks of the HDMI scaler.
// The inputs: SCHED=play (sim/tb_aquarium.cpp's schedule on the joystick, at the core's vblank).
// The OSD and the framework's settings, set before the load:
//   FX=n          Scandoubler Fx (0 None, 1 HQ2x, 2-4 CRT 25/50/75 %); FSD=1 MiSTer.ini's forced_scandoubler
//   M263=1        Video Timing 263 lines (RT4K DV1; the default is 270, the CRT's), M240=1 263 lines (CRT 240p); CRT=1 HSIZE=n HPOS=n VSHIFT=n: CRT Adjust
//                 (with a CRT timing) and its values (HSIZE -16..+1, HPOS -48..+16, VSHIFT -16..+15)
//   SCALE=n (0 Normal, 1 V-Integer, 2 HV-Integer, 3 Narrower HV-Integer, 4 HV-Integer+), AR=n (Aspect ratio), HW / HH the scaler's size
// The framework's direct-video DE (sys_top.v's dv_de: from HS / VS on CE_PIXEL) is modelled too: every picture dot must be inside it.
#include "Vtb_emu_top.h"
#include "Vtb_emu_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

static Vtb_emu_top *t;
static uint64_t cyc = 0;
static void tick() { t->CLK_50M = 1; t->eval(); t->CLK_50M = 0; t->eval(); cyc++; }
#define HPSV(n) t->rootp->tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__##n

static const int VIS_W = 320;
static int VIS_H = 256;                                           // the picture's rows (CRT 240p: 240)
static unsigned long long FRAME_CLK = 270 * 5925;                 // the 270-line raster: 395 dots of 15 clocks a line (60.009 Hz)
static int LINES = 270;
static double LINE_CLK = 5925;
static long DOT_CLK = 15;

// sys_top.v's direct-video DE, sampled as there on the pixel enable from the syncs (non-blocking: every new value from the old ones)
struct DvDe {
    unsigned hss = 0, vsz = 0, vcnt = 0, vcnt_l = 0, vcnt_ll = 0;
    bool old_hs = false, old_vs = false, vde = false, de = false;
    void step(bool hs, bool vs) {
        unsigned n_hss = ((hss << 1) | hs) & 15, n_vsz = vsz, n_vcnt = vcnt, n_vcnt_l = vcnt_l, n_vcnt_ll = vcnt_ll;
        bool n_old_hs = hs, n_old_vs = old_vs, n_vde = vde;
        if (!old_hs && hs) {
            n_old_vs = vs;
            if (vcnt != 0x1fff) n_vcnt = vcnt + 1;
            if (!old_vs && vs) { if (vcnt != vcnt_ll || vcnt < vcnt_l) n_vsz = vcnt; n_vcnt_l = vcnt; n_vcnt_ll = vcnt_l; }
            if (old_vs && !vs) n_vcnt = 0;
            if (vcnt == 1) n_vde = true;
            if (vcnt == vsz - 3) n_vde = false;
        }
        de = !(hss || hs) && vde;
        hss = n_hss; vsz = n_vsz; vcnt = n_vcnt; vcnt_l = n_vcnt_l; vcnt_ll = n_vcnt_ll; old_hs = n_old_hs; old_vs = n_old_vs; vde = n_vde;
    }
};

static std::vector<uint8_t> slurp(const char *fn) {
    std::vector<uint8_t> v;
    FILE *f = fopen(fn, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", fn); exit(2); }
    fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(v.data(), 1, v.size(), f) != v.size()) exit(2);
    fclose(f);
    return v;
}
static int env(const char *n, int d = 0) { return getenv(n) ? atoi(getenv(n)) : d; }
static void set_status(int bit, int v) {
    int w = bit / 32, b = bit % 32;
    unsigned x = HPSV(r_status)[w];
    HPSV(r_status)[w] = v ? (x | (1u << b)) : (x & ~(1u << b));
}
static void set_field(int lo, int w, int v) { for (int i = 0; i < w; i++) set_status(lo + i, (v >> i) & 1); }

// sim/tb_aquarium.cpp's schedule, as MiSTer joystick bits (0 right, 1 left, 2 down, 3 up, 4 / 5 buttons, 6 start, 7 coin)
static uint32_t sched_joy(int f) {
    uint32_t j = 0;
    if (f >= 300 && f < 306) j |= 1u << 7;
    if (f >= 400 && f < 406) j |= 1u << 6;
    if (f >= 600) {
        if ((f / 10) % 6 == 0) j |= 1u << 4;
        if ((f / 10) % 6 == 3) j |= 1u << 5;
        if ((f / 45) % 4 == 1) j |= 1u << 1;
        if ((f / 45) % 4 == 3) j |= 1u << 0;
        if ((f / 30) % 5 == 4) j |= 1u << 2;
        if ((f / 30) % 5 == 2) j |= 1u << 3;
    }
    return j;
}

// rtl/aquarium_loader.sv: the SDRAM byte of image byte i (or -1: not in the SDRAM)
static long sd_of(size_t i) {
    if (i < 0x120000) return (long)i;
    if (i < 0x1A0000) { size_t b = i - 0x120000; return 0x200000 + ((b >> 7) << 8) + (((b >> 3) & 15) << 4) + (b & 7); }
    if (i < 0x1C0000) { size_t b = i - 0x1A0000; return 0x200000 + ((b >> 5) << 8) + (((b >> 1) & 15) << 4) + 8 + (b & 1); }
    if (i < 0x240000) { size_t b = i - 0x1C0000; return 0x300000 + ((b >> 7) << 8) + (((b >> 3) & 15) << 4) + (b & 7); }
    if (i < 0x260000) { size_t b = i - 0x240000; return 0x300000 + ((b >> 5) << 8) + (((b >> 1) & 15) << 4) + 8 + (b & 1); }
    if (i < 0x360000) return (long)(0x400000 + (i - 0x260000));
    return -1;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: Vtb_emu_top <image.rom> <frames> <prefix>\n"); return 2; }
    std::vector<uint8_t> img = slurp(argv[1]);
    int frames = atoi(argv[2]);
    std::string prefix = argv[3];
    int snapevery = env("SNAPEVERY", 10);
    bool play = getenv("SCHED") && !strcmp(getenv("SCHED"), "play");
    unsigned errors = 0;
    t = new Vtb_emu_top;
    auto &R = *t->rootp;
    t->HDMI_WIDTH = env("HW", 1920); t->HDMI_HEIGHT = env("HH", 1080);
    t->eval();

    // ---------------------------------------------------------------- the OSD and the framework's settings
    const int fx = env("FX"); const bool fsd = env("FSD");
    set_field(3, 3, fx);
    if (fsd) HPSV(r_fsd) = 1;
    const bool sd_on = fx || fsd, sd_hq = fx == 1;
    const int sd_mul = sd_on ? (sd_hq ? 4 : 2) : 1;
    const bool m240 = env("M240"), m270 = !env("M263") && !m240;
    if (m240) { set_status(53, 1); LINES = 263; LINE_CLK = 6090; FRAME_CLK = 263 * 6090; DOT_CLK = 15; VIS_H = 240; }   // 406 dots of 15 clocks
    if (!m270 && !m240) { set_status(54, 1); LINES = 263; LINE_CLK = 6090; FRAME_CLK = 263 * 6090; DOT_CLK = 15; }   // 406 dots of 15 clocks
    const bool crt = env("CRT") && (m270 || m240), vshift = crt && env("VSHIFT");
    if (env("CRT")) set_status(35, 1);                              // CRT Adjust: [40:36] H-Size, [47:41] H-Position, [52:48] V-Shift
    if (getenv("HSIZE")) { int v = env("HSIZE"); set_field(36, 5, v >= 0 ? v : 18 + v); }
    if (getenv("HPOS"))  { int v = env("HPOS");  set_field(41, 7, v >= 0 ? v : 65 + v); }
    if (getenv("VSHIFT")) set_field(48, 5, env("VSHIFT") & 31);
    if (getenv("SCALE")) set_field(32, 3, env("SCALE"));
    if (getenv("AR")) set_field(121, 2, env("AR"));
    unsigned dsw = getenv("DSW") ? strtoul(getenv("DSW"), nullptr, 16) : 0xFFFF;
    printf("settings: Video Timing %d lines, Scandoubler Fx %d, forced_scandoubler %d, CRT Adjust %s (H-Size %d, H-Position %d, V-Shift %d), Scale %d, Aspect %d, DSW %04X\n",
           LINES, fx, (int)fsd, crt ? "On" : "Off", env("HSIZE"), env("HPOS"), env("VSHIFT"), env("SCALE"), env("AR"), dsw);

    t->RESET = 1;
    for (int i = 0; i < 64; i++) tick();
    t->RESET = 0;
    for (int i = 0; i < 2000; i++) tick();

    // ---------------------------------------------------------------- the load
    uint64_t t0 = cyc;
    const bool fast = env("FAST");
    HPSV(r_index) = 0;
    if (fast) {
        auto &mem = R.tb_emu_top__DOT__ddr__DOT__mem;
        const size_t base = 0x400000;                 // byte 0x32000000 in the client's window at 0x30000000
        for (size_t i = 0; i < img.size(); i += 8) {
            uint64_t w = 0;
            for (int b = 0; b < 8 && i + b < img.size(); b++) w |= (uint64_t)img[i + b] << (8 * b);
            mem[base + i / 8] = w;
        }
        HPSV(r_addr) = img.size();
        HPSV(r_download) = 1;
        for (int i = 0; i < 100; i++) tick();
        HPSV(r_download) = 0;
    } else {
        HPSV(r_download) = 1;
        for (int i = 0; i < 20; i++) tick();
        for (size_t i = 0; i < img.size(); i++) {
            while (HPSV(r_wait_seen)) tick();
            HPSV(r_addr) = i;
            HPSV(r_dout) = img[i];
            HPSV(r_wr) = 1; tick();
            HPSV(r_wr) = 0; tick();
        }
        for (int i = 0; i < 20; i++) tick();
        HPSV(r_download) = 0;
    }
    for (int i = 0; i < 20; i++) tick();
    HPSV(r_index) = 254;                    // the MRA's <switches>: the DSW word's low byte, then its high byte
    for (int i = 0; i < 2; i++) {
        HPSV(r_addr) = i; HPSV(r_dout) = (dsw >> (8 * i)) & 0xff;
        HPSV(r_wr) = 1; tick(); HPSV(r_wr) = 0; tick();
    }
    HPSV(r_index) = 0;
    while (R.tb_emu_top__DOT__u_emu__DOT__mc_rst) tick();
    printf("load done after %.3f s of machine time (%s)\n", (cyc - t0) / 96e6, fast ? "fast load" : "streamed");

    // ---------------------------------------------------------------- the SDRAM against the expected layout
    {
        auto &mb = R.tb_emu_top__DOT__chip__DOT__mem_b;
        size_t bad = 0, n = 0, first = 0;
        auto chk = [&](size_t sdaddr, uint8_t v) { n++; if (mb[sdaddr] != v) { if (!bad) first = sdaddr; bad++; } };
        for (size_t i = 0; i < img.size(); i++) { long a = sd_of(i); if (a >= 0) chk((size_t)a, img[i]); }
        printf("SDRAM: %zu of %zu bytes differ from the expected layout", bad, n);
        if (bad) { printf(" (first at %#zx)", first); errors++; }
        printf("\n");
        unsigned sw0 = R.tb_emu_top__DOT__u_emu__DOT__sw[0], sw1 = R.tb_emu_top__DOT__u_emu__DOT__sw[1];
        printf("DIP switches as the core holds them: %02X%02X\n", sw1, sw0);
        if (((sw1 << 8) | sw0) != dsw) { printf("  FAIL: DIP switches\n"); errors++; }
    }

    // ---------------------------------------------------------------- the pictures and the raster
    std::vector<uint8_t> fb(VIS_W * VIS_H * 3, 0), last(VIS_W * VIS_H * 3, 0);
    int de_count = 0, de_last = -1, nvs = 0, cframe = -1;
    bool pvs = false, pft = false;
    unsigned long long last_vs = 0;
    std::vector<unsigned long long> periods;
    bool g_phs = false, g_pde = false;
    unsigned long long g_hs = 0, g_de = 0, g_vs = 0;
    int g_rows = 0, g_lines = 0; long g_first = -1, g_smin = 1L << 30, g_smax = -1, g_wmin = 1L << 30, g_wmax = -1;
    int geo_rows = 0, geo_lines = 0; long geo_first = -1, geo_smin = 0, geo_smax = 0, geo_wmin = 0, geo_wmax = 0;
    const uint64_t run0 = cyc;
    DvDe dv;
    long dv_lost = 0, dv_dots = 0, dv_frames = 0; int dv_lines = 0, dv_lines_last = -1; bool dv_pde = false;
    long hs_min = 1L << 30, hs_max = -1; unsigned long long hs_at = 0;
    long ce_min = 1L << 30, ce_max = -1; unsigned long long ce_at = 0;
    HPSV(r_joy0) = 0;
    while (cframe < frames) {
        tick();
        // the core's vblank: its frame count, and the inputs of the schedule from there on (as the system bench sets them)
        bool ft = R.tb_emu_top__DOT__u_emu__DOT__frame_tick;
        if (ft && !pft) { cframe++; if (play) HPSV(r_joy0) = sched_joy(cframe); }
        pft = ft;
        if (cyc - (last_vs ? last_vs : run0) > 4 * FRAME_CLK) {
            printf("  FAIL: no vertical sync for %llu clocks after %d syncs\n", 4 * FRAME_CLK, nvs); errors++;
            break;
        }
        {
            bool hs = t->VGA_HS, de = t->VGA_DE;
            if (hs && !g_phs) { g_lines++; g_hs = cyc; }
            if (de && !g_pde) {
                long s = (long)(cyc - g_hs); g_de = cyc; g_rows++;
                if (g_first < 0) g_first = (long)(cyc - g_vs);
                if (s < g_smin) g_smin = s;
                if (s > g_smax) g_smax = s;
            }
            if (!de && g_pde) { long w = (long)(cyc - g_de); if (w < g_wmin) g_wmin = w; if (w > g_wmax) g_wmax = w; }
            if (hs && !g_phs && cframe >= 2) {
                if (hs_at) { long d = (long)(cyc - hs_at); if (d < hs_min) hs_min = d; if (d > hs_max) hs_max = d; }
                hs_at = cyc;
            }
            g_phs = hs; g_pde = de;
        }
        if (t->CE_PIXEL && !sd_on && !crt) {   // the direct-video DE (native rate only: the framework's direct video takes the core's raster)
            dv.step(t->VGA_HS, t->VGA_VS);
            if (cframe >= 2) {
                if (ce_at) { long d = (long)(cyc - ce_at); if (d < ce_min) ce_min = d; if (d > ce_max) ce_max = d; }
                ce_at = cyc;
                if (t->VGA_DE) { dv_dots++; if (!dv.de) dv_lost++; }
                if (dv.de && !dv_pde) dv_lines++;
            }
            dv_pde = dv.de;
        }
        bool vs = t->VGA_VS;
        if (vs && !pvs) {                       // the vertical sync: the frame before it is the core's frame cframe
            if (cframe >= 2) { dv_lines_last = dv_lines; dv_frames++; }
            dv_lines = 0;
            geo_rows = g_rows; geo_lines = g_lines; geo_first = g_first; geo_smin = g_smin; geo_smax = g_smax; geo_wmin = g_wmin; geo_wmax = g_wmax;
            g_vs = cyc; g_lines = 0; g_first = -1; g_rows = 0; g_smin = 1L << 30; g_smax = -1; g_wmin = 1L << 30; g_wmax = -1;
            if (last_vs) periods.push_back(cyc - last_vs);
            last_vs = cyc;
            nvs++;
            last = fb; de_last = de_count; de_count = 0;
            if (cframe >= 0 && cframe % snapevery == 0) {
                char fn[64]; snprintf(fn, sizeof fn, ".f%d.ppm", cframe);
                FILE *o = fopen((prefix + fn).c_str(), "wb");
                fprintf(o, "P6\n%d %d\n255\n", VIS_W, VIS_H); fwrite(fb.data(), 1, fb.size(), o); fclose(o);
                printf("frame %d\n", cframe); fflush(stdout);
            }
        }
        pvs = vs;
        if (t->CE_PIXEL && t->VGA_DE) {
            int idx = -1;
            if (sd_mul == 1) idx = de_count < VIS_W * VIS_H ? de_count : -1;
            else {
                int w2 = VIS_W * (sd_hq ? 2 : 1), row = de_count / w2, col = de_count % w2;
                if (!(row & 1) && !(sd_hq && (col & 1)) && row / 2 < VIS_H) idx = (row / 2) * VIS_W + (sd_hq ? col / 2 : col);
            }
            if (idx >= 0) { uint8_t *p = &fb[idx * 3]; p[0] = t->VGA_R; p[1] = t->VGA_G; p[2] = t->VGA_B; }
            de_count++;
        }
    }
    printf("done: %d frames after the load; the last had %d visible pixels (expect %d)\n", cframe, de_last, VIS_W * VIS_H * sd_mul);
    if (!crt && de_last != VIS_W * VIS_H * sd_mul) { printf("  FAIL: visible pixel count\n"); errors++; }
    {
        printf("frame period %llu clocks (expect %llu = %.4f Hz)\n", periods.empty() ? 0ull : periods.back(), FRAME_CLK, 96e6 / (double)FRAME_CLK);
        int ok = 0, bad = 0, trans = 0;
        for (size_t i = 1; i < periods.size(); i++) {
            if (periods[i] == FRAME_CLK) ok++;
            else if (vshift && i <= 3) trans++;
            else { bad++; printf("  frame %zu: period %llu clocks = %.3f lines\n", i, periods[i], periods[i] / LINE_CLK); }
        }
        printf("frame periods after the load: %d whole, %d at a V-Shift step, %d other\n", ok, trans, bad);
        if (bad || ok == 0) { printf("  FAIL: a frame of the wrong length\n"); errors++; }
    }
    unsigned nonblack = 0;
    for (int i = 0; i < VIS_W * VIS_H; i++) if (last[i * 3] | last[i * 3 + 1] | last[i * 3 + 2]) nonblack++;
    printf("last frame: %u non-black pixels\n", nonblack);
    printf("geometry (last frame): %d rows with picture, %d lines a frame; first row %ld clocks after the vsync pulse (%.3f lines);"
           " rows start %ld..%ld clocks after hsync, %ld..%ld clocks wide\n",
           geo_rows, geo_lines, geo_first, geo_first / LINE_CLK, geo_smin, geo_smax, geo_wmin, geo_wmax);
    if (geo_rows != VIS_H * (sd_on ? 2 : 1) || geo_lines != LINES * (sd_on ? 2 : 1)) {
        printf("  FAIL: the raster should be %d rows in %d lines\n", VIS_H * (sd_on ? 2 : 1), LINES * (sd_on ? 2 : 1)); errors++;
    }
    if (crt) {   // CRT Adjust: every row whole, 320 reads of (60 + H-Size) / 4 clocks, after the hsync pulse (30 dots of 15 clocks)
        const long want = 4800L * (60 + env("HSIZE")) / 60;
        if (labs(geo_wmin - want) > 15 || labs(geo_wmax - want) > 15 || geo_smin < 450) {
            printf("  FAIL: CRT Adjust's rows should be %ld clocks wide, from after the hsync pulse\n", want); errors++;
        }
    }
    printf("hsync to hsync: %ld..%ld clocks\n", hs_min, hs_max);
    if (!sd_on && (hs_min != (long)LINE_CLK || hs_max != (long)LINE_CLK)) { printf("  FAIL: every line should be %ld clocks\n", (long)LINE_CLK); errors++; }
    if (!sd_on && !crt) {
        printf("pixel enable to pixel enable: %ld..%ld clocks\n", ce_min, ce_max);
        if (ce_min != DOT_CLK || ce_max != DOT_CLK) { printf("  FAIL: every dot should be %ld clocks\n", DOT_CLK); errors++; }
    }
    if (!sd_on && !crt) {
        printf("direct-video DE (sys_top.v's): %d lines a frame; %ld of %ld picture dots outside it (%ld frames)\n",
               dv_lines_last, dv_lost, dv_dots, dv_frames);
        if (dv_lost) { printf("  FAIL: picture outside the direct-video DE\n"); errors++; }
    }
    printf("scaler: the core asks for %s%d x %s%d (Scale %d, Aspect %d, scaler %d x %d)\n",
           ((t->VIDEO_ARX >> 12) & 1) ? "" : "ratio ", t->VIDEO_ARX & 0xfff, ((t->VIDEO_ARY >> 12) & 1) ? "" : "ratio ", t->VIDEO_ARY & 0xfff,
           env("SCALE"), env("AR"), (int)t->HDMI_WIDTH, (int)t->HDMI_HEIGHT);
    printf("%s: %u errors\n", errors ? "FAIL" : "PASS", errors);
    t->final();
    delete t;
    return errors ? 1 : 0;
}
