#!/usr/bin/env python3
"""cmp_trace.py <mame trace> <core trace> <image> [n]: MAME's debugger trace of the 68000 (`trace <file>,maincpu,noloop,{tracelog
"%d ",totalcycles}`) against the system bench's +ITRACE lines ("I <clock> <pc> <opcode>", 96 MHz clocks of MAME's time),
instruction by instruction: where the cycle count of an instruction's start first differs (the delta in 16 MHz cycles, the core
to MAME, each time it changes, up to n changes), or the program goes another way. fx68k's IR => IRD transfer comes 17 clocks
before MAME's instruction hook (with the core's bus accesses on MAME's: rtl/aquarium_core.sv START_EARLY), so a core line's cycle
is (clock + 17) / 6. A core line whose opcode is not the program's word at its address (fx68k's early IR => IRD transfer
of some instructions) is dropped, as is a second line at the same address within 6 cycles (a branch not taken transfers twice)."""
import sys

IRD_LEAD = 17          # clocks from fx68k's IR => IRD transfer to MAME's instruction hook


def mame(p):
    out = []
    for l in open(p):
        s = l.split()
        if len(s) >= 2 and s[0].isdigit() and s[1].endswith(':'):
            out.append((int(s[0]), int(s[1][:-1], 16), ' '.join(s[2:])))
    return out


def core(p, rom):
    out = []
    for l in open(p):
        s = l.split()
        if not s or s[0] != 'I':
            continue
        cyc, pc, op = (int(s[1]) + IRD_LEAD) / 6, int(s[2], 16), int(s[3], 16)
        if pc < len(rom) - 1 and (rom[pc] << 8 | rom[pc + 1]) != op:
            continue
        if out and out[-1][1] == pc and cyc - out[-1][0] <= 6:     # a second transfer (a branch not taken), in cycles
            continue
        out.append((cyc, pc))
    return out


def main():
    rom = open(sys.argv[3], 'rb').read()[:0x80000]
    m, c = mame(sys.argv[1]), core(sys.argv[2], rom)
    nshow = int(sys.argv[4]) if len(sys.argv) > 4 else 10
    j = 0
    while j < len(c) and (c[j][0] < m[0][0] - 50 or c[j][1] != m[0][1]):
        j += 1
    i, last, shown = 0, None, 0
    hist = {}
    while i < len(m) and j < len(c):
        mc, mpc, ins = m[i]
        cc, cpc = c[j]
        if cpc != mpc:
            print(f'the program differs at MAME instruction {i}: MAME {mc} {mpc:06x} {ins}; core {cc} {cpc:06x}')
            for x in range(max(0, i - 8), min(len(m), i + 2)):
                print('   MAME', m[x][0], f'{m[x][1]:06x}', m[x][2])
            for x in range(max(0, j - 8), min(len(c), j + 2)):
                print('   core', c[x][0], f'{c[x][1]:06x}')
            break
        d = round(cc - mc, 2)
        hist[d] = hist.get(d, 0) + 1
        if d != last:
            if shown < nshow:
                print(f'{i:8d} {mpc:06x} MAME {mc} core {cc}: delta {d}' + (f'  (after {m[i-1][2]} at {m[i-1][1]:06x})' if i else ''))
            last = d
            shown += 1
        i += 1
        j += 1
    print(f'compared {i} instructions of {len(m)}; the delta changed {shown} times, the last {last}; deltas: ' +
          ', '.join(f'{k}: {v}' for k, v in sorted(hist.items())))


if __name__ == '__main__':
    main()
