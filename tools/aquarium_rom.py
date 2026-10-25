#!/usr/bin/env python3
"""The Aquarium core's ROM image by MAME 0.289's loading rules (src/mame/excellent/aquarium.cpp), independent of the MRAs: the image
the simulations run, and what tools/make_mra.py checks every MRA's image against.

    python3 tools/aquarium_rom.py <aquarium.zip> <aquarium|aquariumj> <out.rom>

The romset is MAME 0.289's merged aquarium.zip (the Japanese set's program in aquariumj/) or the split sets; files are found by
CRC. The layout is rtl/aquarium_loader.sv's: MAME's regions in MAME's byte order (ROM_LOAD16_WORD_SWAP files swapped back):
    0x000000  maincpu    0x80000   aquar3.13h / excellent_3.13h   (word swapped)
    0x080000  audiocpu   0x40000   excellent_5.10c
    0x0C0000  oki        0x40000   excellent_4.7d, its first 256 KB (the MSM6295's address space; the rest of the ROM is 0xFF)
    0x100000  txt        0x20000   excellent_2.17e                (word swapped)
    0x120000  mid        0x80000   excellent_1.15b                (word swapped)
    0x1A0000  mid_hi     0x20000   excellent_6.15d
    0x1C0000  bak        0x80000   excellent_8.14g                (word swapped)
    0x240000  bak_hi     0x20000   excellent_7.17g
    0x260000  spritegen  0x100000  d23c8000.1f                    (word swapped)
    0x360000  (end)
"""
import sys, zipfile, zlib

PROG = {'aquarium': ('aquar3.13h', 0xf197991e), 'aquariumj': ('excellent_3.13h', 0x344509a1)}

# (region, offset in the image, size, name, crc, word swapped)
COMMON = [
    ('audiocpu',  0x080000, 0x40000,  'excellent_5.10c', 0xfa555be1, False),
    ('oki',       0x0C0000, 0x40000,  'excellent_4.7d',  0x9a4af531, False),
    ('txt',       0x100000, 0x20000,  'excellent_2.17e', 0xaa071b05, True),
    ('mid',       0x120000, 0x80000,  'excellent_1.15b', 0x575df6ac, True),
    ('mid_hi',    0x1A0000, 0x20000,  'excellent_6.15d', 0x9065b146, False),
    ('bak',       0x1C0000, 0x80000,  'excellent_8.14g', 0x915520c4, True),
    ('bak_hi',    0x240000, 0x20000,  'excellent_7.17g', 0xb96b2b82, False),
    ('spritegen', 0x260000, 0x100000, 'd23c8000.1f',     0x14758b3c, True),
]
END = 0x360000


def files(path):
    """Every file of a zip (or of several, 'a.zip|b.zip'), by CRC."""
    out = {}
    for one in path.split('|'):
        with zipfile.ZipFile(one) as zf:
            for info in zf.infolist():
                if not info.is_dir():
                    d = zf.read(info)
                    out.setdefault(zlib.crc32(d) & 0xffffffff, d)
    return out


def swap16(d):
    b = bytearray(len(d))
    b[0::2] = d[1::2]
    b[1::2] = d[0::2]
    return bytes(b)


def regions(setname):
    name, crc = PROG[setname]
    return [('maincpu', 0x000000, 0x80000, name, crc, True)] + COMMON


def build(zpath, setname):
    by_crc = files(zpath)
    img = bytearray(END)
    for region, off, size, name, crc, swapped in regions(setname):
        if crc not in by_crc:
            sys.exit(f'{setname}: {name} (crc {crc:08x}) is missing from {zpath}')
        data = by_crc[crc]
        if swapped:
            data = swap16(data)
        data = data[:size]
        if len(data) != size:
            sys.exit(f'{setname}: region {region} is {len(data):#x} bytes, expected {size:#x}')
        img[off:off + size] = data
    return img


def main():
    if len(sys.argv) != 4 or sys.argv[2] not in PROG:
        sys.exit(__doc__)
    img = build(sys.argv[1], sys.argv[2])
    with open(sys.argv[3], 'wb') as f:
        f.write(img)
    print(f'wrote {sys.argv[3]}: {len(img):#x} bytes')


if __name__ == '__main__':
    main()
