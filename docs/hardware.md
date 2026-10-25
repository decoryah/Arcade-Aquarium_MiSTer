# Aquarium: the hardware as the core implements it

Everything here is MAME 0.289's (`src/mame/excellent/aquarium.cpp`, `excellent_spr.cpp`, `src/devices/machine/gen_latch.cpp`,
`mb3773.cpp`, `src/devices/sound/okim6295.cpp`, `ymopm.cpp` with ymfm, `src/emu/tilemap.cpp`, `drawgfx.cpp`, `emupal.cpp`,
`screen.cpp`, `src/devices/cpu/m68000/`) unless it says otherwise; where a value was measured in MAME (Lua, the debugger), it says
so.

## The board (Excellent System ES-9206, 1996)

| | |
|---|---|
| CPU | TMP68HC000P-16 at 16 MHz (32 MHz / 2; MAME: "clock not verified on PCB") |
| Sound CPU | Z80B at 5.333 MHz (32 MHz / 6; not verified either) |
| Sound | YM2151 at 3.579545 MHz (14.31818 MHz / 4) with a YM3012; MSM6295 at 1.056 MHz, pin 7 high (MAME: not verified) |
| Video | custom ES-9208 / ES 9207 / ES-9303: three tilemaps, a sprite generator (MAME's `excellent_spr_device`, shared with Grand Cross Pinball), a 2,048-colour palette |
| Other | MB3773 watchdog, the sound latch (MAME's `generic_latch_8` with a separate acknowledge) |

## The 68000's memory map

| address | read | write |
|---|---|---|
| 000000-07ffff | program ROM (512 KB) | |
| c00000-c00fff | mid VRAM (32 x 32 tiles, 2 words each) | mid VRAM |
| c01000-c01fff | bak VRAM (the same) | bak VRAM |
| c02000-c03fff | txt VRAM (64 x 64 tiles, 1 word each) | txt VRAM |
| c80000-c81fff | sprite RAM: 4 KB on the low byte lane (the high byte reads 0) | sprite RAM |
| d00000-d00fff | palette (2,048 words, RRRRGGGGBBBBRGBx) | palette |
| d80010-d80013 | | MAME: unmapped. The game writes 000c, 0001 (00ad, 00e2 with its Flip Screen DIP on): sprite offsets? The core ignores them |
| d80014-d8001f | 0 (write only) | the scroll words: mid x, mid y, bak x, bak y, txt x, txt y |
| d80020 | | MAME: unmapped. The game writes 01a0, and 01a3 with the Flip Screen DIP on: the core takes bits 1:0 as the picture's flip ("Flip") |
| d80040-d8005a | | MAME: unmapped. Written once at the start (a CRTC's settings?); d80054-d8005a differ with the Flip Screen DIP on. Ignored |
| d80060-d80076 | | MAME: unmapped (d80068 a no-op). Written once at the start. Ignored |
| d80080 | DSW (the 16 DIP switches) | |
| d80084 | INPUTS: P1 in bits 15:8, P2 in 7:0 | |
| d80086 | SYSTEM: bit 15 the sound latch's pending flag (1 = not yet acknowledged) | |
| d80088 (byte) | | the MB3773's clock: bit 7 (bits 1:0 "also used", MAME: unknown) |
| d8008b (byte) | | the sound latch |
| ff0000-ffffff | work RAM (64 KB) | work RAM |

Nothing is mirrored; anything else reads 0 (MAME's unmapped value) and ignores writes. IRQ 1 (autovectored) comes at every vblank
and is held until acknowledged (`irq1_line_hold`). The MB3773 resets the machine when its clock has not fallen for 5 s.

## The sound board

| address | read | write |
|---|---|---|
| 0000-3fff | ROM: the first 16 KB of the 256 KB | |
| 7800-7fff | RAM (2 KB) | RAM |
| 8000-ffff | ROM: a 32 KB bank of the 256 KB (`z80_bank_w`) | |

I/O (8-bit): 00 / 01 the YM2151 (a read of 00 gives 0xff, of 01 the status), 02 the MSM6295 (both ways through `snd_bitswap`: the
byte's bits reversed), 04 the sound latch, 06 the latch's acknowledge (written with 0), 08 the bank: the byte bitswapped 7, 6, 5, 2,
3, 1, 4, 0, its bits 2:0 the bank (so the written bits 1, 4, 0). The NMI is the latch's pending flag (the program's NMI handler
queues the byte and writes 06); the IRQ (IM 1) is the YM2151's. The MSM6295 addresses 256 KB: the sample ROM's second half is 0xFF.

MAME's mix: a stereo speaker; the YM2151's left and right outputs at 0.45 each, the MSM6295 at 0.47 to both.

### The sound latch, and where MAME's scheduling shows

The 68000 sends a command by waiting for the pending flag to be clear (SYSTEM bit 15), writing the latch, and (at its first
command, `036b6`) waiting for the flag to rise and then to clear again: the Z80's NMI handler (`0066`) queues the byte and writes 06.
The first command, `c3`, comes at frame 47 (MAME 0.289, measured with a Lua write tap). In MAME the Z80 runs after the 68000 in each
of the scheduler's timeslices, so the 68000 sees the Z80's acknowledge only when its timeslice ends: MAME's instruction trace shows
the 68000 writing `c3` at cycle 12,789,718 and spinning in the wait loop (`036fc`) until cycle 12,800,004, the vblank that ends frame
47 (12,800,000 = 48 frames), 0.64 ms later. On the board (and in the core) the Z80 answers the NMI within microseconds, so the 68000
leaves the loop in the same frame and from then on runs exactly one frame ahead of MAME: every byte of the machine's RAM at the
core's vblank n is MAME's at vblank n + 1 (the benches number the core's frames one ahead from frame 47, `+LAG=47`, and shift
their scripted inputs with them). Later commands go out one a frame, when the flag is clear at the game's frame tick (`375a`), which
the Z80 has long acknowledged in either.

## Video

MAME's screen: 60 Hz, 512 x 512, the visible area 320 x 256 at x 16, y 16, no vertical blank time. MAME draws the whole frame at the
start of the vblank (line 272 of 512) from the state of that instant; at time 0 the screen is at the start of its vblank, without the
callbacks: the first vblank (the IRQ, the sprite buffer's copy, frame_done 0) is a frame later, at 16.667 ms (measured in MAME with
Lua: frame_done times 0.016667, 0.033333, ...).

The game writes its video memory all through the frame (measured in MAME with Lua write taps over 3,000 frames, the time of each
write after the vblank): VRAM and palette from 1.5 ms to 9 ms after it, the sprite list in its first 1.5 ms, the scroll words at
its very start. On a 15 kHz raster with 256 visible lines most of that falls while the beam draws.

### Tilemaps

| layer | tiles | VRAM | gfx | colours |
|---|---|---|---|---|
| bak | 32 x 32 of 16 x 16 | word 0: code (11:0); word 1: colour (4:0), category (5), flip x (8), flip y (9) | 5 bits: 4-bit packed `excellent_8.14g` plus the 1-bit `excellent_7.17g` as bit 4 | 0x400 + colour * 32 |
| mid | the same | the same | `excellent_1.15b` plus `excellent_6.15d` | 0x400 + colour * 32 |
| txt | 64 x 64 of 8 x 8 | one word: code (11:0), colour (15:12); its bit 15 is also the category | 4-bit packed `excellent_2.17e` | 0x200 + colour * 16 |

Pen 0 is transparent. The scroll (MAME's tilemap rule, `effective_rowscroll`): MAME's bitmap pixel (x, y) shows the layer's pixel
((x + scrollx) & 511, (y + scrolly) & 511); the screen's first pixel is bitmap (16, 16).

### Sprites

512 sprites of 8 bytes on the sprite RAM's low byte lane: x (bytes 1:0) and y (3:2), signed 16 bits; byte 4: bit 7 off, bit 5 flip x,
bit 4 flip y, bit 3 the chain's direction (1 down, 0 across), bits 2:0 the chain's length - 1; bytes 6:5 the code (& 0x3fff); byte 7
bits 3:0 the colour (colour base 0x300, 16 pens), bit 3 also the priority. A chain of n + 1 tiles: code, code + 1, ..., across 16
pixels apart from x (from x + n * 16 leftwards with flip x) or down from y (from y + n * 16 upwards with flip y); every tile is drawn
at y and again at y + 256 (MAME's wrap). The tiles are 16 x 16 x 4 planar (`d23c8000.1f`, planes at bits 48, 16, 32, 0 of a 64-bit
row); codes from 0x2000 are past the 1 MB ROM, zero in MAME's 2 MB region, so transparent.

`excellent_spr_device::vblank` copies the sprite RAM into its buffer at each vblank, after the frame has been drawn: a frame shows
the list as it was at the vblank before.

### The mix (`screen_update`)

Over palette entry 0, with MAME's priority bitmap:

1. bak, category 0 (priority 1)
2. mid, category 0 (priority 2)
3. txt, category 1 (priority 4)
4. bak, category 1 (priority 8)
5. the sprites, from the last to the first, with `prio_transpen`: a sprite with colour bit 3 is not drawn where the priority has
   bit 1 or 2 (`aquarium_colpri_cb`: GFX_PMASK_2 | GFX_PMASK_4 | GFX_PMASK_8); every opaque sprite pixel, drawn or not, sets the
   priority to 31, so the first sprite drawn at a pixel (the highest-numbered) owns it
6. mid, category 1
7. txt, category 0

The palette: RRRRGGGGBBBBRGBx, 5 bits a component (`RRRRGGGGBBBBRGBx_decoder`), expanded to 8 bits as `pal5bit`.

### Flip

MAME does not flip this game (MACHINE_NO_COCKTAIL). With the Flip Screen DIP on, the game changes only its writes to the video
chip's registers at the start (MAME 0.289 with a Lua write tap on d80000-d800ff, both settings, 600 frames): d80020 01a3 instead of
01a0, d80010 / d80012 00ad / 00e2 instead of 000c / 0001, d80054-d8005a 008a, 0000, 00e2, 0007 instead of 00ea, 0001, 0002, 0001,
and the txt layer's x scroll 8 instead of 0. Everything else it writes is the same, so the board's video chip turns the picture
itself, and the game moves the txt layer by 8 to line it up with the others in the flipped picture: MAME, which applies only that
scroll, shows the unflipped picture with its text 8 dots to the left.

The core: d80020's bits 1:0 flip the picture (bit 0 x, bit 1 y: a guess, the game sets both), taken at the vblank with the scroll
words. Flipped, line y is drawn from the bitmap's row 271 - y and read out from its end, and the txt layer's x scroll is 8 less:
the picture is MAME's unflipped one turned 180 degrees, dot for dot. The other registers' values are not used (where the board puts
the flipped picture on the raster is not known).

## Controls

INPUTS (active low), P1 in bits 15:8 and P2 in 7:0: 0 up, 1 down, 2 left, 3 right, 4 button 1, 5 button 2, 6 unknown (MAME: "used in
test mode"), 7 start. SYSTEM (active low): 8 coin 2, 9 coin 1, 10 tilt, 11 service 1, 12 the service mode switch, 15 the latch's
pending flag (active high). DSW (MAME's defaults FFFF): bits 1:0 difficulty (3 Normal, 2 Easy, 1 Hard, 0 Hardest), 3:2 and 5:4 the
winning rounds against the computer and against a player (3 and 0 1/1, 2 2/3, 1 3/5), 10:8 the coinage (7 1C/1C, 6 1C/2C, 5 1C/3C,
4 1C/4C, 3 2C/1C, 2 3C/1C, 1 4C/1C, 0 5C/1C), 12 flip screen (0 on; MAME does not flip: MACHINE_NO_COCKTAIL; the core does, "Flip"),
13 demo sounds (1 on).

## The core's timing

One 96 MHz clock (the Rabbit and Hexion cores' PLL and SDRAM controller).

**The raster.** MAME's 512-line screen would be a 30.7 kHz raster, so the core draws the 320 x 256 picture on a 15 kHz raster of its
own, every line the same length and every dot the same width:

| Video Timing | dot | line | lines (front porch / vsync / back porch) | frame |
|---|---|---|---|---|
| 270 lines (CRT), the default | 6.4 MHz, 15 clocks | 395 dots, 5,925 clocks (16.20 kHz); hsync dots 330-359 | 270 (3 / 3 / 8) | 1,599,750 clocks, 60.009 Hz |
| 263 lines (CRT 240p) | 6.4 MHz, 15 clocks | 406 dots, 6,090 clocks (15.76 kHz); hsync dots 334-363 | 263: lines 8-247 shown (3 / 3 / 17) | 1,601,670 clocks, 59.937 Hz |
| 263 lines (RT4K DV1) | 6.4 MHz, 15 clocks | 406 dots, 6,090 clocks (15.76 kHz); hsync dots 334-363 | 263 (2 / 2 / 3) | 1,601,670 clocks, 59.937 Hz |

The vblank (the game's) begins at line 256 in all three. The 270-line raster puts the picture in 50 us of the 61.7 us line, as a usual 320-dot arcade board
does on a CRT (the first release's 8 MHz dot filled 40 us: a narrow picture), with 1.6 us of front porch, a 4.7 us hsync and 5.5 us
of back porch. The RT4K DV1 one is for a RetroTINK 4K in direct video (DV1), which sorts 262-264 lines as "MiSTer 240p" and, like
a CRT, takes a picture's width from its time in the line: with the 8 MHz dot of 20261024b-20261025b (507 dots a line) the picture
came out narrow on it too, so it has the CRT timings' 6.4 MHz dot; all 256 lines with only 7 blank ones, too few for a CRT's
flyback; the framework's direct-video DE is exactly its 256 picture lines. The CRT 240p one is a standard 240p signal for a consumer CRT, which
may not lock to the 270-line raster's 16.2 kHz: the same dot as the 270-line raster, 240 of the picture's lines (8 blanked at the top
and the bottom: the drawing and the game's vblank stay where they are, only the output's blank is longer), and the OSD's Original
aspect ratio 64:45 for the 320 x 240 shown.

None is MAME's frame, 1,600,000 clocks (60.000 Hz): that is not a whole number of equal lines of whole dots near 15 kHz. The
first release kept it with lines of 6,083 and 6,084 clocks and an 11-clock last dot on the short ones, and a RetroTINK 4K showed
single lines shifted sideways (the owner's video), so the core now runs the game at 60.009 or 59.937 frames a second. The
benches' MAME_FRAME define makes the frame's last line (in the vertical blank) 6,175 or 4,420 clocks, for MAME's frame in the
comparisons with MAME; the core is built without it.

**The snapshot.** As MAME draws the frame at the vblank's instant, the core copies the video memories at the vblank into display
copies (5.3 us: 512 entries of 64 bits, the txt VRAM's 1,024 in two banks side by side) and draws the following frame from them; the
sprite list goes into one of two buffers and a frame shows the one copied at the vblank before. A 68000 write to an entry the copy has
not reached yet waits for it (the CPU's phases are held, then given back).

**The CPUs' start.** MAME's 68000 and Z80 start at time 0, the screen at the start of a vblank. The core starts the 68000 32 clocks
before a vblank of its raster (the time-0 vblank, whose callbacks it skips; the raster signals that clock, `vbl_pre`) and the sound
board 32 clocks later, at time 0. 32 clocks:
MAME makes a bus access at the start of its bus cycle, the core when AS has gone low, and fx68k leaves reset a cycle later than MAME's
68000; with them the core's writes land in the clock MAME's time reaches them (measured: the bench's write log against MAME's
instruction trace).

**The 68000.** fx68k, with its two phase enables one every 3 clocks. DTACK is asserted at once (MAME has no wait states). Where the
data is not there yet when the CPU takes it (a program ROM cache miss: an SDRAM burst), or a write waits for the snapshot, the phases
are held and the missed ones given back at one every 2 clocks; the IRQ, raised while the CPU owes phases, reaches it after them. A
write is made when AS goes low, with fx68k's data and the byte lanes it will assert (a local output of the vendored fx68k), as MAME
makes it at the start of its bus cycle.

**The Z80.** tv80 with the Hexion core's changes, one step per 18 clocks, with the Hexion core's owed-cycle scheme for its ROM cache's
misses and its interrupts.

**The YM2151.** jt51, its clock enable 3,579,545 times a second of 96 MHz (a fractional accumulator), restarted at time 0. It runs
while the board is held in reset too: jt51 keeps its operators' state in shift registers, which take their reset values (the
envelopes silent, in release) only as they shift; without the clock in reset they start at full level in attack, and a channel the
program never keys on sounds from the start (measured: a tone under the attract mode's music that MAME's ymfm does not have). The
Z80's register writes go through a short queue and reach jt51 one at a time at its own pace.
