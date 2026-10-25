derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM. The chip is clocked by the PLL's second 96 MHz output, shifted about half a period (rtl/pll/pll_0002.v); as in the owner's other
# cores the pin's clock is modelled as the machine clock inverted, and the read data -- launched by the chip's edge, captured by
# aquarium_sdram's input register a few edges after the READ command -- gets a two-cycle path. sys/sys.tcl puts the SDRAM pins' registers
# in the IO cells. (The Rabbit and Hexion cores' constraints, the same PLL and controller.)
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# ==============================================================================
# The 68000 (fx68k) runs on its two phase enables (rtl/aquarium_core.sv), never closer than two clocks apart, and every register of it
# changes only on one of them (fx68k's notes: the phases are its flip-flops' clock enables): its register-to-register paths have two
# clocks. Its microcode and nanocode ROMs (block RAMs) are read every clock from addresses that change on a phase, and their words are
# taken at the next phase, which can be two clocks after the address: the paths from the RAMs keep one clock. What goes in and out of
# it (the bus, the enables) is an ordinary one-clock path.
# ==============================================================================
set FX_ALL [get_registers -nowarn {*|fx68k:u_cpu|*}]
set FX_RAM [get_registers -nowarn {*|fx68k:u_cpu|*|altsyncram:*|*}]
set FX [remove_from_collection $FX_ALL $FX_RAM]
set_multicycle_path -setup 2 -from $FX -to $FX
set_multicycle_path -hold  1 -from $FX -to $FX

# ==============================================================================
# The YM2151 (jt51) runs on its clock enables, 3.58 MHz (cen, at least 26 clocks apart) and half that (cen_p1): its registers change
# on them, but for those a register write updates, and aquarium_sound starts a write only in the clock after a cen_p1 (they have then
# settled 26 clocks before the next enable, and a held write only rewrites the same values). Its register-to-register paths get two
# clocks; what goes in and out of it, one.
# ==============================================================================
set YM [get_registers -nowarn {*|jt51:u_ym|*}]
set_multicycle_path -setup 2 -from $YM -to $YM
set_multicycle_path -hold  1 -from $YM -to $YM

# ==============================================================================
# The Z80 (tv80) steps on aquarium_sound's cpu_ce, never closer than eight clocks apart: its registers change only at those steps, so
# its own paths and its outputs (address, data, strobes) into the sound board have four clocks (the board samples the strobes four
# clocks after they change, and the decode and the RAM ports use the address only after that). What the board hands back (the read data
# register, the interrupt lines, the clock enable itself) is constrained as an ordinary one-clock path. (The Hexion core's.)
# ==============================================================================
set Z80   [get_keepers {*|tv80s_cen:*|*}]
set BOARD [get_keepers {*|aquarium_sound:*|*}]
set_multicycle_path -setup 4 -from $Z80 -to $BOARD
set_multicycle_path -hold  3 -from $Z80 -to $BOARD

# ==============================================================================
# The framework's HQ2x (sys/hq2x.sv) updates its datapath on the scandoubler's ce_x4i, four times per input pixel: for this core's
# 12-clock pixels three clocks apart. The framework does not constrain it (as in the owner's Rabbit, Mystic Warriors and Hexion
# cores).
# ==============================================================================
set HQ [get_registers -nowarn {*|Blend:*|*}]
foreach n {cyc nextpatt pattern Prev0 Prev1 Prev2 Curr0 Curr1 Curr2 Next0 Next1 Next2 A B D F G H
           curbuf prevbuf offs wrdata wrdata_finished waddr wrout_addr wrpix wrin_addr2
           old_reset_line old_reset_frame} {
    set HQ [add_to_collection $HQ [get_registers -nowarn [format {*|Hq2x:*|%s} $n]]]
    set HQ [add_to_collection $HQ [get_registers -nowarn [format {*|Hq2x:*|%s[*]} $n]]]
}
set_multicycle_path -setup 2 -from $HQ -to $HQ
set_multicycle_path -hold  1 -from $HQ -to $HQ
