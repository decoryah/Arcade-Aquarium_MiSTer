// The whole-machine bench's driver: sim/run_sys.sh builds it.
//   Vtb_top +IMAGE=<aquarium.rom> [+DSW=FFFF] [+M263] [+DUMPDIR=<dir> +DUMPFROM=f +DUMPTO=f +DUMPEVERY=n] <frames> <out prefix>
// Environment: SNAPEVERY=n (a picture every n frames), SNAPFRAMES=a,b,c, SCHED=play|test (the scripted inputs, the same as
// tools/lua/dump.lua's), AUDIO=1 (<prefix>.wav, 48 kHz stereo, the core's 16-bit output; AUDIO=2: the YM2151's left output and
// the OKI's sum, x2, unmixed), TRACE=1 (a line per frame).
// Pictures are written as <prefix>.f<frame>.ppm (320 x 256): frame f is the picture drawn from the vblank of frame f (MAME's
// snapshot of frame f: MAME draws it at that vblank), which the raster shows in the frame after it.
#include "Vtb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <set>
#include <string>
#include <vector>

static std::set<int> parse_list(const char *s) {
    std::set<int> r;
    if (!s) return r;
    const char *p = s;
    while (*p) { r.insert(atoi(p)); while (*p && *p != ',') p++; if (*p) p++; }
    return r;
}

static const int W = 320, H = 256;

static void write_ppm(const std::string &fn, const std::vector<uint8_t> &fb) {
    FILE *f = fopen(fn.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", W, H);
    fwrite(fb.data(), 1, fb.size(), f);
    fclose(f);
}

// The scripted inputs, the same as tools/lua/dump.lua's sched(): MAME takes the values set in frame f's frame_done from the vblank
// that ends frame f on, the frame_tick at which `frame` here is f. Bits as MAME's ports (active low): INPUTS 8 P1 up, 9 down,
// 10 left, 11 right, 12 button 1, 13 button 2, 15 start 1 (the low byte P2's, 7 start 2); SYSTEM 8 coin 2, 9 coin 1, 11 service,
// 12 the service mode.
struct In { uint16_t inputs, system; };
static In sched_in(const char *sched, int f) {
    In in = {0xffff, 0x7fff};
    if (!sched) return in;
    if (!strcmp(sched, "test")) {                          // the service mode switch held from power-on (read at the start)
        in.system &= ~0x1000;                              // the menu: button 1 at 300 (COLOR CHECK), button 2 at 400 (back),
        if ((f >= 300 && f < 306) || (f >= 500 && f < 506)) in.inputs &= ~0x1000;   // down at 450 and 470 (OBJ CHECK), button 1 at 500
        if (f >= 400 && f < 406) in.inputs &= ~0x2000;
        if ((f >= 450 && f < 456) || (f >= 470 && f < 476)) in.inputs &= ~0x0200;
        return in;
    }
    if (f >= 300 && f < 306) in.system &= ~0x0200;         // coin 1
    if (f >= 400 && f < 406) in.inputs &= ~0x8000;         // start 1
    if (!strcmp(sched, "play") && f >= 600) {
        if ((f / 10) % 6 == 0) in.inputs &= ~0x1000;       // button 1
        if ((f / 10) % 6 == 3) in.inputs &= ~0x2000;       // button 2
        if ((f / 45) % 4 == 1) in.inputs &= ~0x0400;       // left
        if ((f / 45) % 4 == 3) in.inputs &= ~0x0800;       // right
        if ((f / 30) % 5 == 4) in.inputs &= ~0x0200;       // down
        if ((f / 30) % 5 == 2) in.inputs &= ~0x0100;       // up
    }
    return in;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<const char *> pos;
    for (int i = 1; i < argc; i++) if (argv[i][0] != '+') pos.push_back(argv[i]);
    if (pos.size() < 2) { fprintf(stderr, "usage: Vtb_top +IMAGE=<file> <frames> <out prefix>\n"); return 2; }
    int frames = atoi(pos[0]);
    std::string pre = pos[1];
    int snap_every = getenv("SNAPEVERY") ? atoi(getenv("SNAPEVERY")) : 0;
    std::set<int> snaps = parse_list(getenv("SNAPFRAMES"));
    const char *sched = getenv("SCHED");
    bool audio = getenv("AUDIO") && atoi(getenv("AUDIO"));
    bool audio_split = getenv("AUDIO") && atoi(getenv("AUDIO")) == 2;
    bool trace = getenv("TRACE") && atoi(getenv("TRACE"));
    int lagfrom = 1 << 30;                                      // +LAG=<frame> (sim/tb_top.sv): from there frames are numbered one ahead
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "+LAG=", 5)) lagfrom = atoi(argv[i] + 5);

    Vtb_top *top = new Vtb_top;
    std::vector<uint8_t> fb(W * H * 3, 0);
    std::vector<int16_t> wav;
    int x = 0, y = 0, frame = 0, shown = -1;
    bool prev_hb = true, line_had = false, prev_vb = true;
    uint64_t cyc = 0, run_at = 0;
    In in = sched_in(nullptr, 0);
    top->in_inputs = in.inputs; top->in_system = in.system;

    top->reset_in = 1;
    for (int i = 0; i < 20; i++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
    top->reset_in = 0;

    while (!Verilated::gotFinish()) {
        bool ce = top->ce_pix;
        bool ft = top->frame_tick;
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        cyc++;
        if (!top->running) { run_at = cyc; continue; }
        if (audio && ((cyc - run_at) % 2000) == 0) {
            if (audio_split) { wav.push_back(top->ym_l); wav.push_back((int16_t)((int16_t)(top->oki_s << 2) >> 2) * 2); }
            else { wav.push_back(top->audio_l); wav.push_back(top->audio_r); }
        }
        if (ft) {
            if (trace) printf("F %d cyc %llu a %06x\n", frame, (unsigned long long)(cyc - run_at), top->dbg_pc);
            // frame_done of this frame: MAME's Lua sets the inputs of sched(frame) here
            int lbl = frame >= lagfrom ? frame + 1 : frame;
            in = sched_in(sched, lbl);
            top->in_inputs = in.inputs; top->in_system = in.system;
            // the picture just shown (lines 0-255 before this vblank) was drawn from the vblank before
            if (shown >= 0 && ((snap_every && shown % snap_every == 0) || snaps.count(shown)))
                write_ppm(pre + ".f" + std::to_string(shown) + ".ppm", fb);
            shown = lbl;                // the raster now shows the picture drawn from this vblank
            frame++;
            if (frame > frames) break;
        }
        if (ce) {
            // the outputs of this dot appeared at this edge
            bool hb = top->hblank, vb = top->vblank;
            prev_vb = vb;
            if (vb) { y = 0; x = 0; line_had = false; }
            else if (!hb) {
                if (x < W && y < H) {
                    uint8_t *p = &fb[(y * W + x) * 3];
                    p[0] = top->r; p[1] = top->g; p[2] = top->b;
                }
                x++; line_had = true;
            } else if (!prev_hb && line_had) { y++; x = 0; line_had = false; }
            prev_hb = hb;
        }
    }
    if (audio) {
        FILE *f = fopen((pre + ".wav").c_str(), "wb");
        if (f) {
            uint32_t n = wav.size() * 2, rate = 48000, br = rate * 4;
            fwrite("RIFF", 1, 4, f); uint32_t v = 36 + n; fwrite(&v, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
            v = 16; fwrite(&v, 4, 1, f); uint16_t s = 1; fwrite(&s, 2, 1, f); s = 2; fwrite(&s, 2, 1, f);
            fwrite(&rate, 4, 1, f); fwrite(&br, 4, 1, f); s = 4; fwrite(&s, 2, 1, f); s = 16; fwrite(&s, 2, 1, f);
            fwrite("data", 1, 4, f); fwrite(&n, 4, 1, f); fwrite(wav.data(), 2, wav.size(), f); fclose(f);
        }
    }
    top->final();
    printf("done: %d frames, %llu clocks\n", frame, (unsigned long long)cyc);
    delete top;
    return 0;
}
