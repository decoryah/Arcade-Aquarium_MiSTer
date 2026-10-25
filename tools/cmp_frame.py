#!/usr/bin/env python3
"""cmp_frame.py <a.png|a.ppm> <b.png|b.ppm> [diff.png]: the number of pixels that differ between two 320 x 256 pictures (MAME's
snapshot, the reference renderer's, the bench's), the rows they are on, and optionally a picture of them (white on dark)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio


def load(p):
    if p.endswith('.ppm'):
        d = open(p, 'rb').read()
        parts = d.split(b'\n', 3)
        w, h = map(int, parts[1].split())
        return w, h, bytearray(parts[3][:w * h * 3])
    return pngio.read(p)


def main():
    wa, ha, a = load(sys.argv[1])
    wb, hb, b = load(sys.argv[2])
    if (wa, ha) != (wb, hb):
        sys.exit(f'sizes differ: {wa}x{ha} / {wb}x{hb}')
    rows, n = set(), 0
    diff = bytearray(len(a))
    for i in range(0, len(a), 3):
        if a[i:i + 3] != b[i:i + 3]:
            n += 1
            rows.add((i // 3) // wa)
            diff[i:i + 3] = b'\xff\xff\xff'
        else:
            diff[i:i + 3] = bytes(v // 4 for v in a[i:i + 3])
    rs = sorted(rows)
    print(f'{n} pixels differ' + (f' on {len(rs)} rows ({rs[0]}..{rs[-1]})' if rs else ''))
    if len(sys.argv) > 3:
        pngio.write(sys.argv[3], wa, ha, diff)
    sys.exit(1 if n else 0)


if __name__ == '__main__':
    main()
