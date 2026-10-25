#!/bin/sh
# End-to-end bench of the MiSTer top level (Aquarium.sv): hps_io and the PLL stubbed, everything else real (after the owner's Rabbit and
# Hexion cores').
#   sim/emu/run_emu.sh <image.rom> [frames after the load, default 30] [out prefix]
# FAST=1 loads through the DDR3 fast-load path; SNAPEVERY=n (default 10); the OSD settings and the inputs: tb_emu.cpp. REBUILD=1
# rebuilds the model (in OBJ, default obj_emu).
set -e
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
cd "$(dirname "$0")"
IMG="$1"; FR="${2:-30}"; PRE="${3:-emu}"
[ -f "$IMG" ] || { echo "usage: $0 <image.rom> [frames] [prefix]" >&2; exit 2; }
S=../../sys
OBJ=${OBJ:-obj_emu}
mkdir -p $OBJ
# The framework's video_mixer.sv declares R_in/G_in/B_in inside an unnamed generate block and uses them outside it; Quartus accepts
# that, Verilator does not: the bench builds a copy with the wires declared at module level (as the owner's other cores' benches do)
python3 - $S/video_mixer.sv $OBJ/video_mixer_sim.sv <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'generate\s+if\(GAMMA && HALF_DEPTH\) begin.*?end else begin(.*?)end\s+endgenerate', s, re.S)
assert m, 'video_mixer.sv: the R_in generate block was not found'
open(sys.argv[2], 'w').write(s[:m.start()] + m.group(1).strip() + chr(10) + s[m.end():])
PY
if [ ! -x $OBJ/Vtb_emu_top ] || [ -n "$REBUILD" ]; then
echo '`define BUILD_DATE "000000"' > $OBJ/build_id.v
ln -sf ../../modules/fx68k/microrom.mem ../../modules/fx68k/nanorom.mem . 2>/dev/null || [ -e microrom.mem ]   # two runs at once
M=../../modules
verilator --cc --exe --build -j ${JOBS:-16} -O2 --no-assert -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSWIRE \
    -Wno-PROCASSINIT -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-ALWCOMBORDER -Wno-INITIALDLY -Wno-COMBDLY -Wno-ASCRANGE -Wno-SELRANGE -Wno-ENUMVALUE \
    +1364-2005ext+v -I$OBJ -I. -I../.. -I../../rtl -I$M/fx68k ../waivers.vlt --public-flat-rw \
    --top-module tb_emu_top --prefix Vtb_emu_top -Mdir $OBJ \
    ../../Aquarium.sv ../../rtl/aquarium_*.sv $M/crt-adjust/crt_adjust.sv \
    $M/fx68k/fx68k.sv $M/fx68k/fx68kAlu.sv $M/fx68k/uaddrPla.sv $M/jt51/jt51*.v \
    +define+TV80_REFRESH $M/cpu-tv80/tv80s_cen.v $M/cpu-tv80/tv80_core.v $M/cpu-tv80/tv80_alu.v \
    $M/cpu-tv80/tv80_mcode.v $M/cpu-tv80/tv80_reg.v \
    $S/arcade_video.v $OBJ/video_mixer_sim.sv $S/scandoubler.v $S/scanlines.v $S/gamma_corr.sv $S/hq2x.sv $S/video_freezer.sv $S/video_freak.sv $S/math.sv \
    hps_io_stub.sv pll_stub.sv sync_fix.sv ../sdram_model.sv ../ddr_model.sv tb_emu_top.sv tb_emu.cpp \
    > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head -30; tail -5 $OBJ.log; exit 1; }
fi
mkdir -p "$(dirname "$PRE")"
stdbuf -oL ./$OBJ/Vtb_emu_top "$IMG" "$FR" "$PRE"
