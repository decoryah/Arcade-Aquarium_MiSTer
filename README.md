# Aquarium for MiSTer

A MiSTer FPGA core for **Aquarium** (Excellent System, 1996), the falling-fish puzzle game, on the ES-9206 board: a 68000, a Z80B with
a YM2151 and an MSM6295, three tilemaps and a sprite generator. Written from MAME 0.289's driver (`src/mame/excellent/aquarium.cpp`,
with `excellent_spr.cpp` and the devices it uses), with MAME as the reference for everything; the platform layer follows the owner's
Rabbit and Hexion cores.

No ROMs or other copyrighted data are in this repository; you supply your own MAME `aquarium.zip`.

**Status.** Simulated with the game's real programs and compared with MAME 0.289 (see "What is verified"); built with Quartus 17.0.2
(38 % of the ALMs, 54 % of the RAM blocks, 34 % of the DSPs; the timing met at 96 MHz with 0.32 ns of setup and 0.25 ns of hold
slack, and on the HDMI clock). **Release 20261025c, tested on a real MiSTer by the owner with a RetroTINK 4K and a Sony PVM:**
the game, the controls and the fast load; the RT4K takes Video Timing RT4K DV1 as "MiSTer 240p" with a steady 4:3 picture (and
270 lines as "MiSTer Gen."); the PVM's picture fills its width with 270 lines and with CRT 240p (the 256 lines overscan at the top
and bottom, all shown with its underscan); CRT Adjust with both CRT timings; Flip Screen, Service Mode and its menu, Audio Mono /
Stereo, Swap stereo. Test builds before it (on the owner's hardware) found the shaking RT4K picture (unequal lines), the narrow
picture (an 8 MHz dot) and the Flip Screen DIP doing nothing; all fixed. CRT 240p has not yet been seen on a consumer TV.

## Install

1. Unzip `Aquarium_MiSTer_<date>.zip` (`tools/package.py` writes it to `dist/`) over the root of the SD card (`/media/fat/`): the
   core goes to `_Arcade/cores/`, `Aquarium (US).mra` to `_Arcade/` and the Japanese version's MRA to
   `_Arcade/_alternatives/_Aquarium/`. (By hand from the repository: `releases/aquarium_<date>.rbf` to `_Arcade/cores/`, the
   contents of `mra/` to `_Arcade/`. Keep the RBF's `aquarium_` name: MiSTer finds the core by the MRA's `<rbf>`.)
2. Put your MAME 0.289 `aquarium.zip` (the merged set holds both versions) in `/media/fat/games/mame/`.
3. Start `Aquarium (US)` (or the Japanese version) from the Arcade menu. A recent Main_MiSTer copies the 3.4 MB image to the DDR3
   in one go (the MRAs' `address=`, the fast load) and the core reads it from there; an older one streams it.

| Set | MRA |
|---|---|
| `aquarium` | Aquarium (US) |
| `aquariumj` | Aquarium (Japan) |

## Controls and OSD

An 8-way joystick and two buttons per player, Start and Coin. The buttons are named for what they do (measured in MAME 0.289, and as
the game's own control panel picture on the player select screen names them): **Rotate Right** (MAME's button 1) turns the falling
piece clockwise, **Rotate Left** (button 2) counter-clockwise; both together are the game's "Magic". Keyboard: 1 / 2 start, 5 / 6
coin, 9 service, T tilt, F2 the service mode switch (while held).

| Option | Values |
|---|---|
| Aspect ratio | Original (4:3; 64:45 for the 320 x 240 of CRT 240p), Full Screen, [ARC1], [ARC2] |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ (the framework's integer scaling for HDMI) |
| Scandoubler Fx | None, HQ2x, CRT 25 / 50 / 75 % |
| Video Timing | **270 lines (CRT)**, the default: 16.20 kHz, a 6.4 MHz dot (the 320-dot picture fills 50 us of the 61.7 us line, as wide as a usual 320-dot arcade board's), 14 blank lines; 60.009 Hz. **263 lines (CRT 240p)**: 15.76 kHz, the 6.4 MHz dot, a standard 240p signal for a consumer CRT, which may not lock to 16.2 kHz: the middle 240 of the 256 lines (8 blanked at the top and the bottom, rows such a set hides anyway), 23 blank lines; 59.937 Hz. **263 lines (RT4K DV1)**: 15.76 kHz, the 6.4 MHz dot, all 256 lines with 7 blank lines, for a RetroTINK 4K in direct video (DV1), which sorts 262-264 lines as "MiSTer 240p" (the 270 lines it takes as "MiSTer Gen.") and shows the 6.4 MHz dot's picture 4:3 wide (an 8 MHz dot came out narrow on it); too little vertical blank for a CRT; 59.937 Hz. Every line the same length and every dot the same width in all three (below). The 256 lines overscan a CRT at its usual vertical size: a monitor's underscan or vertical size control shows them all |
| CRT Adjust (page) | Off, On (with the CRT Video Timings, 270 lines and CRT 240p; greyed out with RT4K DV1); H-Size 0, +1 and -16 to -1, H-Position -48 to +16, V-Shift -16 to +15: rmonic79's CRT Adjust (`modules/crt-adjust`) for a 15 kHz analog output, the picture moved and sized through a line buffer while the sync keeps its timing, so the monitor stays locked. A size step is 1/60 of a dot (5.3 dots across the picture); +1 is the most that ends before the next hsync pulse (the picture is already as wide as a CRT shows). The position stops where the picture would reach into the hsync pulse or past the line's end, so a row is always whole: with 270 lines at H-Size 0 from -34 to +9, at +1 from -34 to +2, at -16 from -22 to +16; with CRT 240p (a longer line, the picture further from the hsync) from 7 dots further left, to +13 at H-Size 0 and +6 at +1. V-Shift counts the frame's own lines in both. It does nothing while the scandoubler is on (31 kHz) |
| DIP switches | MAME's: Difficulty, Winning Rounds (vs. CPU, vs. player), Coinage, Flip Screen (the core turns the picture, below), Demo Sounds |
| Service Mode | Off, On: the board's service mode switch (as F2). The game looks at it when it starts: set it, then Reset, for the test menu (button 1 enters a section, both buttons together leave it); set it Off and Reset to leave |
| Volume | Normal, -6 dB, -12 dB, +6 dB |
| Audio | Stereo, Mono (both channels their mean) |
| Swap stereo | No, Yes |

The video is the game's 320 x 256 picture (MAME's visible area) on a 15 kHz raster of the core's own: MAME's screen for this driver
is a placeholder (60 Hz, 512 lines: 30.7 kHz). The first release kept MAME's frame time exactly, 1,600,000 clocks of 96 MHz, by
making some lines a clock longer than others, and a RetroTINK 4K in direct video showed single lines shifted sideways; every line
is now the same, so the frame is 1,599,750 clocks with 270 lines (60.009 Hz) or 1,601,670 with 263 (59.937 Hz), and the game runs
that much faster or slower than MAME (`docs/hardware.md`, "The core's timing").

## What is verified

| | |
|---|---|
| ROM image | `tools/make_mra.py aquarium.zip` assembles both MRAs' images (`tools/mra_build.py`, the MiSTer MRA rules, the md5 as MiSTer computes it) and compares them with the image `tools/aquarium_rom.py` builds by MAME's loading rules: identical |
| The 68000 against MAME, cycle by cycle | MAME's debugger trace with each instruction's cycle count against the bench's (`sim/tb_top.sv` +ITRACE, `tools/cmp_trace.py`): the first 96,098 instructions (frames 0-3, the RAM and ROM tests) start on MAME's cycle, and the vblank IRQ's handler too (frames 68-70). fx68k's bus accesses are placed on MAME's (`docs/hardware.md`, "The core's timing"): the core's writes land in the clock MAME's time reaches them (+WLOG against MAME's trace) |
| The Z80 against MAME, cycle by cycle | MAME's debugger trace of the audiocpu (`tools/lua/trace_z80.lua`) against the bench's (+ZTRACE, `tools/cmp_ztrace.py`): all 529,345 instructions of frames 0-60 start on MAME's cycle, with the YM2151's timer interrupts and the NMI of the game's first sound command |
| The video chip | `sim/run_frames.sh`: MAME's video state (the VRAM, the palette, the sprite RAM and the scroll words of frames f-1 and f, `tools/lua/dump.lua`) drawn by the core's video module behind the real SDRAM path: pixel-identical to MAME's snapshots at all 8 frames tried (the FBI logo, the title, the versus screen, the playfield with its fish) |
| Whole machine | `sim/run_sys.sh`: the 68000 and the Z80 running the game's programs, the ROM image downloaded through the loader into the SDRAM controller and a behavioural SDRAM (which checks its timing: no violation), the video, both sound chips. 1,200 frames of scripted play (the RAM and ROM tests, the attract mode, a coin, start, the player select, a game with moves and both buttons) against MAME 0.289 under the same inputs, built with MAME's frame (MAME_FRAME, the default build of the bench): **the pictures pixel-identical to MAME's at every 50th frame**, and the video memories (VRAM, palette, sprite RAM, scroll) byte for byte MAME's at all 121 dumps (every 10th frame); the work RAM differs only in stale stack bytes ("Where the core is not MAME"). On the core's own raster (`RASTER=hw`, 60.009 Hz): all 25 pictures again MAME's, the video memories at 120 of the 121 dumps (at frame 40 the game's boot clear of the txt layer is 74 bytes behind MAME's: its 40th vblank comes 0.1 ms earlier); the work RAM differs in stale stack bytes (86 addresses) and, at one dump, two counters a tick apart. With the Flip Screen DIP on (`+DSW=EFFF`, the core's raster): every 50th picture to frame 900 is MAME's unflipped one turned 180 degrees, pixel for pixel (`tools/cmp_frames.py --rot180`). The test mode (`SCHED=test`: the service mode switch held from power-on, then a walk through its menu: COLOR CHECK, back, OBJ CHECK; with the first release's build): 800 frames, the pictures at all 7 frames compared and the video memories at all 7 dumps MAME's, the work RAM again only stale stack bytes (37 addresses, among them a popped call's arguments). |
| Sound | The same 1,200 frames' sound (`AUDIO=1`, 48 kHz stereo) against MAME's recording (`-wavwrite`): `tools/audio_cmp.py` compares their loudness frame by frame (the RMS of each 1/60 s): with MAME's frame, over frames 60-1,200 a correlation of 0.996 and a level of 0.999 of MAME's; the attract mode's music (60-420) 0.982 and 0.989, the game's (420-1,200) 0.995 and 0.999. On the core's raster: 0.993 and 1.003; 0.978 and 0.982; 0.991 and 1.003. (MAME's sound runs one frame later, as its machine does from frame 47.) |
| MiSTer top level | `sim/emu/run_emu.sh`: `Aquarium.sv` with the framework's video path (`arcade_video`, the scaler's input), `hps_io` and the PLL stubbed, the SDRAM and the DDR3 modelled: the fast load (`FAST=1`) and the streamed one leave the SDRAM byte-identical to the expected layout, the DIP switches arrive. Video Timing 270 (the default): every frame 1,599,750 clocks (60.0094 Hz) with 256 rows of 320 pixels in 270 lines, every hsync exactly 5,925 clocks after the last and every pixel enable 15 clocks after the last, the rows 975 clocks (10.2 us) after the hsync and 4,800 clocks (50 us) wide, every picture dot inside the framework's direct-video DE (`sys_top.v`'s logic, modelled in the bench). Video Timing RT4K DV1: every frame 1,601,670 clocks (59.9374 Hz), 263 lines of exactly 6,090 clocks, pixel enables exactly 15 clocks apart, 256 rows 4,800 clocks (50 us) wide, the direct-video DE exactly the picture's 256 lines; HQ2x 512 rows in 526 lines. Video Timing CRT 240p: every frame 1,601,670 clocks (59.9374 Hz), 263 lines of exactly 6,090 clocks, pixel enables exactly 15 clocks apart, 240 rows of 320 pixels 4,800 clocks wide, every picture dot inside the direct-video DE, the scaler asked for 64:45; HQ2x 480 rows in 526 lines; CRT Adjust with it: every row whole at the extremes (4,880, 4,885, 3,520, 4,800 clocks), V-Shift counting its 263 lines (+3: the first row 22.2 lines after the vsync, 19.2 without; with 270 lines 13.2 and 10.2). CRT Adjust at its extremes (H-Size +1 and -16 with H-Position -48 and +16, V-Shift -16 and +15, H-Size -1 and 0): every row whole (4,880, 3,520, 4,720, 4,800 clocks), after the hsync pulse and before the line's end. HQ2x: 512 rows in 540 lines |
| Lint | Verilator `-Wall` (`sim/lint.sh`): nothing in the core's own RTL |

## Where the core is not MAME

* **The sound latch's handshake, and MAME's scheduler.** At its first sound command (frame 47) the game writes the latch and waits for
  the Z80 to acknowledge it. MAME runs the Z80 after the 68000 in each of its scheduler's timeslices, so its 68000 sees the
  acknowledge only at the next vblank: MAME's own trace shows it spinning in the wait loop for 0.64 ms until exactly the vblank
  (`docs/hardware.md`, "The sound latch"). The board's Z80, and the core's, answer within microseconds, so from frame 47 on the core
  runs one frame ahead of MAME: its state at vblank n is MAME's at vblank n + 1 (the benches compare with that offset, `+LAG=47`).
  The game's idle task is then interrupted at another point of its two-instruction idle loop now and then, which leaves different
  stale bytes in the task stacks (at most 41 addresses of the work RAM in 1,200 frames, all of them stack contents or the scheduler's
  and the watchdog's toggle bytes); nothing the game shows or plays changes. (The benches' `MAME_SYNC` build makes the 68000 see the
  acknowledge at the next vblank, as MAME does: it then needs no offset, with the same stale stack bytes.)
* **The raster and the frame rate.** MAME's screen for this driver is a placeholder (512 lines at 60 Hz, a 30.7 kHz raster); the
  core draws the same 320 x 256 picture on a 15 kHz raster of equal lines (270 or 263), so its frame is 60.009 or 59.937 Hz,
  not MAME's 60.000 (above), and the game runs 0.016 % faster or 0.1 % slower. Its picture is MAME's: the core takes the
  video state at the vblank, as MAME draws it then (with CRT 240p, all but its top and bottom 8 lines).
* **Flip Screen.** MAME does not flip this game; the board does (the game sets two bits of a video register MAME does not have and
  moves its text layer by 8 dots to suit). The core turns MAME's unflipped picture 180 degrees (`docs/hardware.md`, "Flip"); where
  the board puts the flipped picture on its raster is not known.
* **The video snapshot's wait.** The copy of the video memories at the vblank takes 5.3 us; a 68000 write to an entry it has not
  reached yet waits for it, and the CPU gets the cycles back right after (at one and a half times its speed), so its program stays on
  MAME's timeline, and the vblank IRQ reaches it after the cycles it still owes.
* **The YM2151 is jt51**, not MAME's ymfm. Fed the same register writes (the bench's `+YMLOG` replayed into a standalone ymfm and a
  standalone jt51) the two follow each other closely; the core's sound against MAME's recording: see "What is verified".
* **The sound's resampling.** The MSM6295's 8 kHz samples and the YM2151's 55.9 kHz ones are held between samples and mixed as MAME
  mixes them (the YM2151 at 0.45, the OKI at 0.47); MAME resamples its streams with its own filter.

## Repository layout

| Path | |
|---|---|
| `Aquarium.sv`, `Aquarium.q*`, `Aquarium.sdc`, `files.qip` | the MiSTer top level (`emu`), Quartus project, timing constraints |
| `rtl/` | the machine: `aquarium_core` (the 68000's bus, its memories, I/O, the IRQ, the watchdog, the start), `aquarium_video` (the video memories and their vblank snapshot, the raster, the mix, the palette) with `aquarium_tmap` (a tilemap layer) and `aquarium_sprites`, `aquarium_sound` (the Z80, the YM2151's glue, the latch, the mix), `aquarium_oki` (MSM6295), `aquarium_cache` (the CPUs' ROM caches), `aquarium_ram`; the platform: `aquarium_sdram`, `aquarium_loader`, `aquarium_fastload` |
| `modules/` | vendored: fx68k (with two local changes), tv80 (the Hexion core's changes), jt51, rmonic79's CRT Adjust (the Hexion core's changes and one of this core's) (`modules/VENDOR.md`) |
| `sys/` | the MiSTer framework |
| `mra/` | the MRAs (`tools/make_mra.py`) |
| `sim/` | Verilator benches: the whole machine (`run_sys.sh`: the 68000's trace +ITRACE, the Z80's +ZTRACE, the write log +WLOG, the sound logs +SNDLOG / +YMLOG, the one-frame offset +LAG, MAME's frame or the core's raster RASTER=hw), the video chip on MAME's state (`run_frames.sh`), the MiSTer top level (`emu/run_emu.sh`), lint |
| `tools/` | ROM image builder (`aquarium_rom.py`), MRA writer and builder, MAME's Lua dumps and traces (`lua/`) and their runner (`mame_dump.sh`), comparisons (`cmp_ram.py`, `cmp_frame.py`, `cmp_frames.py`, `cmp_trace.py`, `cmp_ztrace.py`, `audio_cmp.py`), release zip (`package.py`) |
| `docs/` | `hardware.md`: the hardware as MAME describes it, the measurements, the core's timing |
| `releases/` | the released RBF with its fitter and timing summaries; `dist/` its release notes (the SD card zip is built there, not committed) |

## Building

Quartus Prime Lite 17.0.2:

    quartus_sh --flow compile Aquarium

Copy `output_files/Aquarium.rbf` to `releases/aquarium_<YYYYMMDD>.rbf` (a later build of the same day: `<YYYYMMDD>b`, ...);
`python3 tools/package.py` then writes the SD card zip (`dist/Aquarium_MiSTer_<YYYYMMDD>.zip`).

The system bench is built with MAME_FRAME (MAME's frame, 1,600,000 clocks, so it can be compared with MAME cycle for cycle) unless
`RASTER=hw` (the core's own raster, as the RBF has it).

The benches need Verilator 5 (in WSL), Python 3 and your romset:

    python3 tools/aquarium_rom.py aquarium.zip aquarium aquarium.rom
    SCHED=play SNAPEVERY=50 AUDIO=1 sim/run_sys.sh aquarium.rom 1200 out/a +LAG=47 +DUMPDIR=out +DUMPFROM=0 +DUMPTO=1200 +DUMPEVERY=10
    DUMPFROM=0 DUMPTO=1200 DUMPEVERY=10 SCHED=play tools/mame_dump.sh ref                           # MAME's (Git Bash)
    NOSNAP=1 LAST=1200 SCHED=play WAV=ref/mame.wav tools/mame_dump.sh ref2                           # MAME's sound
    python3 tools/cmp_ram.py ref out; python3 tools/cmp_frames.py ref out/a; python3 tools/audio_cmp.py out/a.wav ref/mame.wav
    DUMPFRAMES=99,100 tools/mame_dump.sh st; sim/run_frames.sh aquarium.rom st 100 fr/a; python3 tools/cmp_frames.py st fr/a
    RASTER=hw SCHED=play SNAPEVERY=50 sim/run_sys.sh aquarium.rom 900 flip/a +LAG=47 +DSW=EFFF      # the core's raster, flipped
    python3 tools/cmp_frames.py --rot180 ref flip/a
    sim/emu/run_emu.sh /full/path/aquarium.rom 120 emu/a                                              # the MiSTer top level (FAST=1, M263=1, CRT=1, ...)

The instruction traces: MAME's debugger, `tools/lua/trace_68k.lua` / `trace_z80.lua` (with `-debug -debugger none`), against
`sim/run_sys.sh ... +ITRACEFROM=<cycle> +ITRACE=<cycle>` / `+ZTRACE=<cycle>`, compared by `tools/cmp_trace.py` / `cmp_ztrace.py`.

MAME's captures, the images and the benches' pictures go to a scratch folder `work/` next to the repository (never committed):
`tools/mame_dump.sh` takes the romset from `work/roms` and runs MAME in `work/mame_run` unless `ROMPATH` / `WORK` say otherwise.

## Credits

* **MAME**: the aquarium driver and the Excellent System sprite device (David Haywood), the MSM6295 and its ADPCM, the generic latch,
  the MB3773, ymfm (Aaron Giles), the cycle-exact 68000 (Olivier Galibert); the hardware knowledge and the reference for every
  comparison.
* **Jorge Cwik**: fx68k (GPL-3.0-or-later).
* **Guy Hutchison**: tv80 (MIT), with its clock-enable wrapper from plasticbugs/punchout.
* **Jose Tejada (jotego)**: jt51 (GPL-3.0-or-later).
* **rmonic79 (Umberto Parisi)**, with Andrea Bogazzi (asturur): CRT Adjust (GPL-3.0-or-later).
* The owner's Rabbit core: the SDRAM controller and its simulation model (via decoryah/Arcade-Metro_MiSTer, from searchsolved's
  Arcade-HyperDuel_MiSTer), the fast load (from the Metro core), the program cache (after the Mystic Warriors core's), the DDR3 model,
  the MRA tools; the Hexion core: the platform layer, the OKI, tv80 with its changes, the owed-cycle scheme, the benches and tools;
  the Gunpey core: the MRA md5 rule and the release packaging.
* The MiSTer framework (Sorgelig and contributors).

## Licence

GPL-3.0-or-later (`LICENSE`); vendored modules keep their own licences.
