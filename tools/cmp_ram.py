#!/usr/bin/env python3
"""Compare the system bench's dumps with MAME's (tools/lua/dump.lua), region by region.

    python3 tools/cmp_ram.py <MAME's dir> <the bench's dir> [frames...]   (default: every ram_<f>.bin both have)

A line per frame: the regions that differ, with how many bytes and the first few addresses (in the 68000's map).
"""
import os, re, sys

REGIONS = [('wram', 0xff0000, 0x10000), ('mid', 0xc00000, 0x1000), ('bak', 0xc01000, 0x1000), ('txt', 0xc02000, 0x2000),
           ('pal', 0xd00000, 0x1000), ('spr', 0xc80000, 0x1000), ('scroll', 0xd80014, 12)]


def frames(d):
    return {int(m.group(1)) for f in os.listdir(d) for m in [re.match(r'ram_(\d+)\.bin$', f)] if m}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ref, out = sys.argv[1], sys.argv[2]
    fs = [int(x) for x in sys.argv[3:]] or sorted(frames(ref) & frames(out))
    same = 0
    for f in fs:
        a = open(os.path.join(ref, f'ram_{f}.bin'), 'rb').read()
        b = open(os.path.join(out, f'ram_{f}.bin'), 'rb').read()
        off, msgs = 0, []
        for name, base, size in REGIONS:
            ra, rb = a[off:off + size], b[off:off + size]
            diff = [i for i in range(size) if ra[i] != rb[i]]
            if diff:
                step = 2 if name == 'spr' else 1
                first = ' '.join(f'{base + i * step:06x}:{ra[i]:02x}/{rb[i]:02x}' for i in diff[:6])
                msgs.append(f'{name} {len(diff)} ({first})')
            off += size
        if msgs:
            print(f'frame {f}: ' + '; '.join(msgs))
        else:
            same += 1
    print(f'{same} of {len(fs)} frames identical')


if __name__ == '__main__':
    main()
