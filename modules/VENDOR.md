# Vendored modules

Third-party HDL copied into the tree (no submodules, so the build is self-contained and reproducible). Each keeps its own licence
alongside.

| module | upstream | licence |
|---|---|---|
| fx68k | https://github.com/ijor/fx68k @ 0602ee4627b10f301298f2673d826cdd6baa9327 (Jorge Cwik's cycle-exact 68000: `fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`, the microcode ROMs `microrom.mem` / `nanorom.mem`); two local changes, below | GPL-3.0 or later |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's tv80), with the `tv80s_cen.v` clock-enable wrapper from plasticbugs/punchout; copied from the owner's Hexion core with its local changes (below) | MIT |
| jt51 | https://github.com/jotego/jt51 @ 2ca6601e6e69e1a3a529920506ee0657ccd30513 (Jose Tejada's YM2151, its `hdl/*.v`), unchanged | GPL-3.0 or later |
| crt-adjust | https://github.com/rmonic79/MiSTer-CRT-Adjust @ c682de9f4acc61d8f4c7779efb48149d3baa3a8e (upstream's `rtl/crt_adjust.sv`), by rmonic79 (Umberto Parisi) with Andrea Bogazzi (asturur); copied from the owner's Hexion core with its two local changes, and one of this core's (below) | GPL-3.0 or later |

To update one: re-copy from upstream at the new commit and record it here.

## fx68k

Local change (`fx68k.sv`, the three `typedef struct` of its decoded signals): declared `packed`. Upstream's unpacked structs have
some fields assigned in `always_ff` blocks and others by continuous `assign`s, which Verilator rejects (BLKANDNBLK on an unpacked
variable); as packed vectors the same assignments are to different bits, which it accepts. Quartus builds either the same way.

Local change (`fx68k.sv`, marked "Aquarium core"): a new output `oWrDSn`, the data strobes {UDS, LDS} a write cycle will assert
(`busControl`'s own expression for them, from the cycle's byte flag and A0), valid from AS on. The 68000 asserts a write's strobes
two phases after AS (at S4); MAME's 68000 makes the write at the start of its bus cycle. With the lanes known at AS the core makes
the write in the same clock MAME's time reaches it (`rtl/aquarium_core.sv`), so the state at a vblank (the video snapshot, the
benches' dumps) is MAME's to the bus cycle.

The microcode ROMs are read with `$readmemb("microrom.mem")` / `"nanorom.mem"`: Quartus finds them through the search path
(`files.qip`), the benches link them into `sim/`.

## cpu-tv80 (the Hexion core's changes, kept)

tv80 is built with its `TV80_REFRESH` option (files.qip, the benches' scripts): the R register, which MAME counts as a Z80 does
(every opcode fetch, every interrupt taken); without it tv80 reads R as 0.

`tv80_core.v`, `tv80_reg.v` (marked "Hexion core"): the registers' power-on values are MAME 0.289's (`z80_device::device_start`:
AF = 0 with the zero flag set, SP = 0, IX = IY = FFFF, the alternate set 0) instead of tv80's.

`tv80_core.v` `Auto_Wait`, `tv80_mcode.v` the NMI's M-cycles 2 and 3 (marked "Hexion core"): the NMI's acknowledge takes 11
T-states (an M1 of 5 and two writes of 3), as a Z80's and MAME's do; tv80 gave it 15. Aquarium's sound Z80 takes an NMI for every
command the 68000 writes to the latch.

## crt-adjust (the Hexion core's changes, kept, and one of this core's)

`crt_adjust.sv` (marked "Hexion core"): the line buffer's size `AW` is a parameter (upstream a localparam, 10). Aquarium.sv uses 10
(upstream's): the longest line, the CRT 240p raster's, is 406 dots.

`crt_adjust.sv` (marked "Aquarium core"): a new input, `vtotal`, the frame's lines, takes the place of the `VTOTAL` parameter in
a negative V-Shift's tap (`vtotal - |N|`); `VTOTAL` stays the vsync shift register's length, the most lines a frame can have. The
core has two CRT rasters, 270 and 263 lines, and switches between them while running; upstream's tap would move the vsync of a
263-line frame by 7 lines too many.

`crt_adjust.sv` (one line, `hoff_s`): the conditional mixes `$signed(hoffset)` with an unsigned replication, so by the Verilog
rules (and in Verilator) the result is unsigned and a negative H-Position is zero-extended (-1 becomes 511), which moves the
picture window out of the line and blanks the picture. The line sign-extends `hoffset` explicitly, which is what the module is
meant to do and gives the same result in every tool.
