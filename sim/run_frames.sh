#!/bin/sh
# The frame bench: MAME's video state (tools/lua/dump.lua, frames f-1 and f) drawn by the core's video chip (sim/tb_frame.sv).
#   sim/run_frames.sh <aquarium.rom> <state dir> <frames f,g,...> <out prefix> [+M263]
# Then: python3 tools/cmp_frames.py <state dir> <out prefix> (MAME's snap_<f>.png against <prefix>.f<f>.ppm). REBUILD=1 rebuilds.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
IMG="$1"; DIR="$2"; FR="$3"; PRE="$4"
[ -f "$IMG" ] && [ -n "$FR" ] && [ -n "$PRE" ] || { echo "usage: $0 <aquarium.rom> <state dir> <frames> <prefix>" >&2; exit 2; }
shift 4
OBJ=${OBJ:-obj_frame}
if [ ! -x $OBJ/Vtb_frame ] || [ -n "$REBUILD" ]; then
verilator --cc --exe --build -j ${JOBS:-16} -O3 --no-assert -CFLAGS "-O2 -march=native" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME \
    -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
    -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSINIT -Wno-SYNCASYNCNET -Wno-BLKSEQ \
    waivers.vlt -I../rtl --top-module tb_frame --prefix Vtb_frame -Mdir $OBJ \
    ../rtl/aquarium_video.sv ../rtl/aquarium_ram.sv ../rtl/aquarium_tmap.sv ../rtl/aquarium_sprites.sv \
    ../rtl/aquarium_sdram.sv ../rtl/aquarium_loader.sv sdram_model.sv tb_frame.sv tb_frame.cpp > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head -30; exit 1; }
fi
mkdir -p "$(dirname "$PRE")"
./$OBJ/Vtb_frame +IMAGE="$IMG" "$@" "$DIR" "$FR" "$PRE"
