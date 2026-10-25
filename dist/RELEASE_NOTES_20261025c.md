## Aquarium for MiSTer - 20261025c

Excellent System's **Aquarium** (1996), the falling-fish puzzle game, on the ES-9206 board (a 68000 at 16 MHz, a Z80B with a
YM2151 and an MSM6295, three tilemaps and a sprite generator), with two MRAs: Aquarium (US) and Aquarium (Japan).

**First release. Tested on a real MiSTer by the repository owner, with a RetroTINK 4K and a Sony PVM: it works.** It was also
checked in simulation against MAME 0.289 (below).

### Install

1. Unzip `Aquarium_MiSTer_20261025c.zip` over the root of the SD card. It adds `Aquarium (US).mra` to `_Arcade/`,
   `Aquarium (Japan).mra` to `_Arcade/_alternatives/_Aquarium/` and `_Arcade/cores/aquarium_20261025c.rbf`.
2. Put your own MAME 0.289 romset `aquarium.zip` (the merged set holds both versions) in `games/mame/`. No ROMs are included. The
   MRAs check the romset's md5 the way MiSTer computes it: another dump of the set gives "md5 mismatch", and MiSTer then does not
   load it.
3. Start the game from the Arcade menu. The ROM image is 3.4 MB: with a recent Main_MiSTer it is copied to the DDR3 in one go (the
   MRAs' `address=` attribute), with an older one it is streamed, with the same RBF and MRAs. The game's power-on RAM and ROM
   tests then run, as on the board.

The OSD's version line reads `v261025`. The game's settings are its DIP switches (the OSD's DIP page); it has no NVRAM.

### Video Timing: pick the one for your display

| Your display | Video Timing | The signal |
|---|---|---|
| PVM / BVM / arcade monitor | **270 lines (CRT)**, the default | 16.20 kHz, 60.009 Hz; all 256 picture lines with 14 blank lines; CRT Adjust |
| Consumer CRT TV | **263 lines (CRT 240p)** | 15.76 kHz, 59.937 Hz, a standard 240p signal; the middle 240 lines (8 blanked at the top and the bottom, rows such a set hides anyway); CRT Adjust |
| RetroTINK 4K in direct video (DV1) | **263 lines (RT4K DV1)** | 15.76 kHz, 59.937 Hz; all 256 lines with 7 blank lines (too few for a CRT); the RT4K's "MiSTer 240p" profile |
| HDMI through MiSTer's scaler | any; 270 lines (CRT) is fine | |

All three have a 6.4 MHz dot, so the 320-dot picture fills 50 us of the line, as wide as a usual 320-dot arcade board's, and every
line is the same length and every dot the same width, so monitors and scalers lock to them. The game's picture is 256 lines: on a
CRT at its usual vertical size the top and bottom rows fall outside the visible area, as with other 256-line arcade games; a
monitor's underscan or vertical size control shows them all.

**CRT Adjust** (the two CRT timings): rmonic79's module for a 15 kHz analog output. H-Size -16 to +1, H-Position -48 to +16 (it
stops where the picture would reach into the hsync pulse or past the line's end, so a row is always whole), V-Shift -16 to +15.

### Controls

An 8-way joystick and two buttons, **Rotate Right** and **Rotate Left** (MAME's buttons 1 and 2; both together are the game's
"Magic"), Start and Coin, for two players. The names are what the buttons do, measured in MAME and as the game's own control panel
picture names them. Keyboard: 1 / 2 start, 5 / 6 coin, 9 service, T tilt, F2 the service mode switch (while held).

### OSD

Aspect ratio, Scale (Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+), Scandoubler Fx (None, HQ2x, CRT 25 / 50 /
75 %), Video Timing, CRT Adjust, the DIP switches (MAME's: difficulty, winning rounds, coinage, flip screen, demo sounds), Service
Mode, Volume (Normal, -6 dB, -12 dB, +6 dB), Audio (Stereo, Mono), Swap stereo, Reset.

- **Flip Screen** (a DIP): the core turns the picture 180 degrees, as the board does. Reset after changing it.
- **Service Mode:** the board's service mode switch. The game looks at it when it starts: set it, then Reset, for the test menu;
  button 1 enters a section, both buttons together leave it; set it Off and Reset to leave.

### Checked

- **On a real MiSTer:** by the repository owner, with a RetroTINK 4K and a Sony PVM: the game, the controls and the fast load; the
  RT4K takes RT4K DV1 as "MiSTer 240p" with a steady 4:3 picture; the PVM's picture fills its width with 270 lines and with CRT
  240p; CRT Adjust with both CRT timings; Flip Screen, Service Mode and its menu, Audio Mono / Stereo, Swap stereo.
- **ROM path:** `tools/make_mra.py` assembles both MRAs' images by the MiSTer MRA rules (the md5 as MiSTer computes it, over the
  files as read, before the interleave) and compares them with the image `tools/aquarium_rom.py` builds by MAME's loading rules:
  identical.
- **The 68000 and the Z80 against MAME, cycle by cycle:** MAME's debugger traces against the bench's: the 68000's first 96,098
  instructions and its vblank IRQ handler, and all 529,345 Z80 instructions of the first 60 frames, start on MAME's cycle.
- **The video chip against MAME's snapshots** (`sim/run_frames.sh`, MAME's video state drawn by the core's video module behind the
  SDRAM path): pixel-identical at all 8 frames tried.
- **The whole machine** (`sim/run_sys.sh`: both CPUs running the game's programs, the ROM image loaded through the SDRAM controller
  into an SDRAM model, the video, both sound chips), 1,200 frames of scripted play (the boot tests, the attract mode, a coin,
  start, the player select, a game with moves and both buttons) under MAME's inputs:
  - built with MAME's frame: every 50th frame's picture pixel-identical to MAME's, the video memories (VRAM, palette, sprite RAM,
    scroll) byte for byte MAME's at all 121 dumps;
  - on the core's own 270-line raster (60.009 Hz): all 25 pictures MAME's, the video memories at 120 of 121 dumps (at frame 40 the
    game's boot clear of its text layer is caught 0.1 ms earlier);
  - with the Flip Screen DIP on: every 50th picture to frame 900 is MAME's unflipped picture turned 180 degrees, dot for dot;
  - the test mode (the service switch from power-on, a walk through its menu): all pictures and video memories compared MAME's.
- **The sound against MAME's recording** (`-wavwrite`) of the same 1,200 frames, the loudness frame by frame: a correlation of
  0.993 at 1.003 of MAME's level on the core's raster (0.996 at 0.999 with MAME's frame).
- **The MiSTer top level** (`sim/emu/run_emu.sh`, the framework's own video path): both loads leave the SDRAM byte for byte as
  expected; in each Video Timing every line and every dot exactly the same length, the frame 60.0094 or 59.9374 Hz, every picture
  dot inside the framework's direct-video DE; CRT Adjust's extremes keep every row whole and V-Shift counts each timing's own
  lines; Scandoubler Fx (HQ2x, CRT 25 / 75 %) and forced_scandoubler keep the vertical sync (31.5-32.4 kHz).
- **Quartus 17.0.2:** 38 % of the ALMs (15,826), 299 of 553 M10K, 38 DSPs; every clock's slack positive (the 96 MHz machine clock
  +0.323 ns setup, +0.246 ns hold; the HDMI clock +0.595 / +0.255 ns). `releases/aquarium_20261025c.fit.summary` / `.sta.summary`.

### Where the core is not MAME

- **The frame rate:** 60.009 Hz (270 lines) or 59.937 Hz (263 lines), not MAME's 60.000. MAME's screen for this driver is a
  placeholder (512 lines, a 30.7 kHz raster); MAME's frame is not a whole number of equal lines near 15 kHz, and unequal lines made
  a RetroTINK 4K's picture shake. The game runs 0.016 % faster or 0.1 % slower.
- **The sound latch's handshake:** at the game's first sound command MAME's 68000 sees the Z80's acknowledge only at the next
  vblank, an artifact of MAME's scheduler; the board's Z80, and the core's, answer within microseconds. From then on the core runs
  one frame ahead of MAME, with the same pictures and sound; only stale bytes in the game's task stacks differ.
- **Flip Screen:** MAME does not flip this game. With the DIP on the game sets two bits of a video register MAME does not have and
  moves its text layer by 8 dots; the core turns MAME's picture 180 degrees.
- **The YM2151 is jt51**, not MAME's ymfm; fed the same register writes the two follow each other closely.

### Known differences / open points

- MAME's own open points stay open: the CPUs' and the MSM6295's clocks are MAME's "not verified" values; the board's own raster
  (its CRTC registers are written but not decoded) and where it puts the flipped picture are not known; which of the two flip bits
  turns which axis is a guess (the game sets both).
- The sound is compared with MAME's recording by its loudness frame by frame, not sample by sample.
- The comparisons cover the boot tests, the attract mode, the test menu and scripted one-player play; two-player play was not
  compared. The CRT 240p timing was seen on a PVM, not yet on a consumer TV.

### Credits

MAME (the aquarium driver and the Excellent System sprite device by David Haywood, the MSM6295, the generic latch, the MB3773,
ymfm by Aaron Giles, the cycle-exact 68000 by Olivier Galibert), Jorge Cwik's fx68k, Guy Hutchison's tv80, Jose Tejada's jt51,
rmonic79's CRT Adjust (with Andrea Bogazzi), the repository owner's Rabbit core (the SDRAM controller and model, the fast load, the
program cache), Hexion core (the platform layer, the OKI, the benches) and Gunpey core (the MRA md5 rule, the packaging), and the
MiSTer framework.
