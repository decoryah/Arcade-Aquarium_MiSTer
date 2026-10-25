#!/bin/sh
# Verilator lint of the machine and the platform modules: sim/lint.sh [max lines] (the vendored modules are waived, waivers.vlt)
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
M=../modules
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET \
    -Wno-TIMESCALEMOD waivers.vlt -I../rtl -I$M/fx68k --top-module aquarium_core \
    ../rtl/aquarium_core.sv ../rtl/aquarium_ram.sv ../rtl/aquarium_video.sv ../rtl/aquarium_tmap.sv ../rtl/aquarium_sprites.sv \
    ../rtl/aquarium_sound.sv ../rtl/aquarium_oki.sv ../rtl/aquarium_cache.sv \
    $M/fx68k/fx68k.sv $M/fx68k/fx68kAlu.sv $M/fx68k/uaddrPla.sv $M/jt51/jt51*.v \
    +define+TV80_REFRESH $M/cpu-tv80/tv80s_cen.v $M/cpu-tv80/tv80_core.v $M/cpu-tv80/tv80_alu.v $M/cpu-tv80/tv80_mcode.v \
    $M/cpu-tv80/tv80_reg.v 2>&1 | grep -E "^%(Error|Warning)" | head -${1:-80}
echo "--- loader, sdram, fastload"
for m in aquarium_loader aquarium_sdram aquarium_fastload; do
    verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME --top-module $m ../rtl/$m.sv 2>&1 | grep -E "^%(Error|Warning)" | head -${1:-40}
done
