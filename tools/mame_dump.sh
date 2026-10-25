#!/bin/sh
# MAME 0.289 runs with tools/lua/dump.lua (Git Bash on Windows), so runs repeat (no nvram: the game has none).
#   tools/mame_dump.sh <out dir> [aquarium|aquariumj]     with DUMPFRAMES / DUMPFROM / DUMPTO / DUMPEVERY / SCHED / NOSNAP in the environment
# MAME, its ROM path and a work directory are taken from MAME / ROMPATH / WORK (defaults: the owner's MAME; the ROMs and the work
# directory in the scratch folder work/ next to the repository). WAV=<file> also records MAME's sound (-wavwrite).
HERE=$(cd "$(dirname "$0")" && pwd)
SCRATCH=$(cd "$HERE/../.." && pwd)/work
MAME=${MAME:-/c/repos/mame0289/mame.exe}
ROMPATH=${ROMPATH:-$(cygpath -m "$SCRATCH/roms" 2>/dev/null || echo "$SCRATCH/roms")}
WORK=${WORK:-$SCRATCH/mame_run}
OUT="$1"; SET=${2:-aquarium}
mkdir -p "$OUT" "$WORK"
OUT=$(cd "$OUT" && pwd)
[ -n "$WAV" ] && WAV=$(cd "$(dirname "$WAV")" && pwd)/$(basename "$WAV")
cd "$WORK" && rm -f "cfg/$SET.cfg"     # MAME keeps DIP settings in its cfg: every run starts from the defaults
SND="-sound none"
[ -n "$WAV" ] && SND="-volume -32 -wavwrite $(cygpath -m "$WAV" 2>/dev/null || echo "$WAV")"
DUMPDIR="$(cygpath -m "$OUT" 2>/dev/null || echo "$OUT")" "$MAME" $SET -rompath "$ROMPATH" -video none $SND -nothrottle \
    -skip_gameinfo -window -cfg_directory cfg -nvram_directory nvram -autoboot_script "$(cygpath -m "$HERE/lua/dump.lua")" \
    -seconds_to_run 100000 2>&1 | tail -2
