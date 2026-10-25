// The frame bench's driver (sim/run_frames.sh): MAME's video state into the core's video chip, its picture out.
//   Vtb_frame +IMAGE=<aquarium.rom> [+M263] <state dir> <frames f,g,...> <out prefix>
// For each frame f, <state dir>/ram_<f-1>.bin and ram_<f>.bin (tools/lua/dump.lua: the work RAM, the mid, bak and txt VRAM, the
// palette, the sprite RAM's bytes, the scroll words) are written into the live video memories, frame f-1's before a vblank and frame
// f's before the next: the snapshot of the second gives the frame f's layers with frame f-1's sprite list, as MAME draws frame f (its
// sprite buffer is copied after the frame is drawn). The picture shown after that vblank is <prefix>.f<f>.ppm (320 x 256).
#include "Vtb_frame.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

static Vtb_frame *t;
static uint64_t cyc = 0;
static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); cyc++; }

static std::vector<uint8_t> slurp(const std::string &fn) {
    std::vector<uint8_t> v;
    FILE *f = fopen(fn.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", fn.c_str()); exit(2); }
    fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(v.data(), 1, v.size(), f) != v.size()) exit(2);
    fclose(f);
    return v;
}

// one word through the 68000's port (waits while the snapshot holds it)
static void cwrite(int region, int addr, int data, int be) {
    t->c_mid = region == 0; t->c_bak = region == 1; t->c_txt = region == 2; t->c_spr = region == 3; t->c_pal = region == 4;
    t->c_scr = region == 5;
    t->c_addr = addr; t->c_wdata = data; t->c_be = be;
    t->eval();
    while (t->c_hold) { tick(); t->eval(); }
    t->c_we = 1; tick(); t->c_we = 0;
    t->c_mid = t->c_bak = t->c_txt = t->c_spr = t->c_pal = t->c_scr = 0;
}

static void write_state(const std::vector<uint8_t> &s) {
    size_t o = 0x10000;                                         // after the work RAM
    for (int w = 0; w < 2048; w++) cwrite(0, w, s[o + 2 * w] << 8 | s[o + 2 * w + 1], 3);
    o += 0x1000;
    for (int w = 0; w < 2048; w++) cwrite(1, w, s[o + 2 * w] << 8 | s[o + 2 * w + 1], 3);
    o += 0x1000;
    for (int w = 0; w < 4096; w++) cwrite(2, w, s[o + 2 * w] << 8 | s[o + 2 * w + 1], 3);
    o += 0x2000;
    for (int w = 0; w < 2048; w++) cwrite(4, w, s[o + 2 * w] << 8 | s[o + 2 * w + 1], 3);
    o += 0x1000;
    for (int i = 0; i < 4096; i++) cwrite(3, i, s[o + i], 1);
    o += 0x1000;
    for (int i = 0; i < 6; i++) cwrite(5, i, s[o + 2 * i] << 8 | s[o + 2 * i + 1], 3);
}

static void wait_vbl() { while (!t->vbl_ev) tick(); tick(); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<const char *> pos;
    for (int i = 1; i < argc; i++) if (argv[i][0] != '+') pos.push_back(argv[i]);
    if (pos.size() < 3) { fprintf(stderr, "usage: Vtb_frame +IMAGE=<file> <state dir> <frames> <prefix>\n"); return 2; }
    std::string dir = pos[0], pre = pos[2];
    std::vector<int> frames;
    for (const char *p = pos[1]; *p;) { frames.push_back(atoi(p)); while (*p && *p != ',') p++; if (*p) p++; }

    t = new Vtb_frame;
    t->c_we = 0;
    t->reset_in = 1;
    for (int i = 0; i < 20; i++) tick();
    t->reset_in = 0;
    while (!t->loaded) tick();

    const int W = 320, H = 256;
    for (int f : frames) {
        auto a = slurp(dir + "/ram_" + std::to_string(f - 1) + ".bin");
        auto b = slurp(dir + "/ram_" + std::to_string(f) + ".bin");
        wait_vbl();
        write_state(a);
        wait_vbl();                     // the snapshot: frame f-1's sprite list into a buffer
        write_state(b);
        wait_vbl();                     // the snapshot: frame f's layers; the frame shows f-1's sprite list
        std::vector<uint8_t> fb(W * H * 3, 0);
        int x = 0, y = 0;
        bool prev_hb = true, had = false;
        while (!t->vbl_ev) {
            bool ce = t->ce_pix;
            tick();
            if (!ce) continue;
            bool hb = t->hblank, vb = t->vblank;
            if (vb) { x = 0; y = 0; had = false; }
            else if (!hb) {
                if (x < W && y < H) { uint8_t *p = &fb[(y * W + x) * 3]; p[0] = t->r; p[1] = t->g; p[2] = t->b; }
                x++; had = true;
            } else if (!prev_hb && had) { y++; x = 0; had = false; }
            prev_hb = hb;
        }
        FILE *o = fopen((pre + ".f" + std::to_string(f) + ".ppm").c_str(), "wb");
        fprintf(o, "P6\n%d %d\n255\n", W, H); fwrite(fb.data(), 1, fb.size(), o); fclose(o);
        printf("frame %d\n", f); fflush(stdout);
    }
    t->final();
    delete t;
    return 0;
}
