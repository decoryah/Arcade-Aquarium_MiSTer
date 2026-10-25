#!/usr/bin/env python3
"""cmp_ztrace.py <mame trace> <core trace> [n]: MAME's debugger trace of the Z80 (`trace <file>,audiocpu,noloop,{tracelog "%d ",totalcycles}`, tools/lua/trace_z80.lua) against
the system bench's +ZTRACE lines ("Z <cycle> <pc>"), instruction by instruction: where the cycle count of an instruction's start first
differs, or the program goes another way. A prefixed instruction is one line in MAME's trace, one per M1 fetch in the core's; an
interrupt's acknowledge is an M1 at the interrupted address in the core's, none in MAME's: both are skipped."""
import sys

def mame(p):
    out = []
    for l in open(p):
        s = l.split()
        if len(s) >= 2 and s[0].isdigit() and s[1].endswith(':'):
            out.append((int(s[0]), int(s[1][:-1], 16), ' '.join(s[2:])))
    return out

def core(p):
    return [(int(s[1]), int(s[2], 16)) for s in (l.split() for l in open(p)) if s and s[0] == 'Z']

m, c = mame(sys.argv[1]), core(sys.argv[2])
nshow = int(sys.argv[3]) if len(sys.argv) > 3 else 10
j = 0
while j < len(c) and c[j][0] < m[0][0]: j += 1
i, last, shown = 0, None, 0
while i < len(m) and j < len(c):
    mc, mpc, ins = m[i]
    cc, cpc = c[j]
    if cpc != mpc:
        k = j
        while k < len(c) and c[k][1] != mpc and k - j < 3: k += 1
        if k < len(c) and c[k][1] == mpc and (c[k][0] - cc <= 8 or c[k][0] == mc + (cc - mc if last is None else last)):
            j = k; continue
        print(f'the program differs at MAME instruction {i}: MAME {mc} {mpc:04x} {ins}; core {cc} {cpc:04x}')
        for x in range(max(0, i - 6), i + 1): print('   MAME', m[x][0], f'{m[x][1]:04x}', m[x][2])
        for x in range(max(0, j - 6), j + 2): print('   core', c[x][0], f'{c[x][1]:04x}')
        break
    d = cc - mc
    if d != last:
        print(f'{i:7d} {mpc:04x} MAME {mc} core {cc}: delta {d}' + (f'  (after {m[i-1][2]} at {m[i-1][1]:04x})' if i else ''))
        last = d; shown += 1
        if shown > nshow: break
    i += 1; j += 1
print(f'compared {i} instructions of {len(m)}')
