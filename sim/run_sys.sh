#!/bin/sh
# The whole-machine bench: aquarium_core behind aquarium_sdram and a behavioural SDRAM, the image downloaded through aquarium_loader.
#   sim/run_sys.sh <aquarium.rom> <frames> <out prefix> [+plusargs: +DSW=.. +DUMPDIR=.. etc., sim/tb_top.sv]
# (tools/aquarium_rom.py <aquarium.zip> aquarium x.rom makes the image.)
# Environment: see sim/tb_aquarium.cpp (SNAPEVERY, SNAPFRAMES, SCHED, AUDIO, TRACE); REBUILD=1 rebuilds the model; THREADS=n.
# The model is built with MAME_FRAME (MAME's frame, 1,600,000 clocks, for the comparisons with MAME: rtl/aquarium_video.sv) unless
# RASTER=hw (the core's own raster: 60.009 Hz, or 59.997 with +M263), in its own OBJ (obj_sys_hw).
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
IMG="$1"
[ -f "$IMG" ] && [ -n "$2" ] && [ -n "$3" ] || { echo "usage: $0 <aquarium.rom> <frames> <prefix>" >&2; exit 2; }
if [ "$RASTER" = hw ]; then OBJ=${OBJ:-obj_sys_hw}; RDEF=; else OBJ=${OBJ:-obj_sys}; RDEF=+define+MAME_FRAME; fi
M=../modules
if [ ! -x $OBJ/Vtb_top ] || [ -n "$REBUILD" ]; then
ln -sf ../modules/fx68k/microrom.mem ../modules/fx68k/nanorom.mem . 2>/dev/null || [ -e microrom.mem ]     # two runs at once
verilator --cc --exe --build -j ${JOBS:-16} -O3 --no-assert ${THREADS:+--threads $THREADS} -CFLAGS "-O2 -march=native" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME \
    -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
    -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSINIT -Wno-SYNCASYNCNET -Wno-BLKSEQ -Wno-ALWCOMBORDER \
    -Wno-INITIALDLY -Wno-COMBDLY -Wno-ASCRANGE -Wno-SELRANGE -Wno-ENUMVALUE \
    waivers.vlt $RDEF $VFLAGS -I../rtl -I$M/fx68k --top-module tb_top --prefix Vtb_top -Mdir $OBJ \
    ../rtl/aquarium_core.sv ../rtl/aquarium_ram.sv ../rtl/aquarium_video.sv ../rtl/aquarium_tmap.sv ../rtl/aquarium_sprites.sv \
    ../rtl/aquarium_sound.sv ../rtl/aquarium_oki.sv ../rtl/aquarium_cache.sv ../rtl/aquarium_sdram.sv ../rtl/aquarium_loader.sv \
    $M/fx68k/fx68k.sv $M/fx68k/fx68kAlu.sv $M/fx68k/uaddrPla.sv \
    +define+TV80_REFRESH $M/cpu-tv80/tv80s_cen.v $M/cpu-tv80/tv80_core.v $M/cpu-tv80/tv80_alu.v $M/cpu-tv80/tv80_mcode.v $M/cpu-tv80/tv80_reg.v \
    $M/jt51/jt51*.v \
    sdram_model.sv tb_top.sv tb_aquarium.cpp > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head -40; tail -20 $OBJ.log; exit 1; }
fi
mkdir -p "$(dirname "$3")"
PRE="$3"; FR="$2"; shift 3
./$OBJ/Vtb_top +IMAGE="$IMG" "$@" "$FR" "$PRE"
