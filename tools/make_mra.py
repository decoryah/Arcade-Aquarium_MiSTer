#!/usr/bin/env python3
"""Writes the Aquarium MRAs (mra/*.mra) from MAME 0.289's ROM lists and input ports (src/mame/excellent/aquarium.cpp).

    python3 tools/make_mra.py <aquarium.zip>

The romset (MAME 0.289's merged aquarium.zip, the Japanese program in aquariumj/) is needed for the md5 each MRA carries (MiSTer's:
of the parts' bytes as it reads them, before the interleave; it does not load a ROM whose md5 does not match). Every MRA is
assembled by tools/mra_build.py and compared with the image tools/aquarium_rom.py builds by MAME's loading rules (the image the
simulations run); they must be identical. The layout is rtl/aquarium_loader.sv's.
"""
import os, sys, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
sys.path.insert(0, HERE)

SWITCHES = '''    <!--
      DIP switches (ioctl index 254): byte 0 is the DSW word's bits 7:0 (SW1), byte 1 its bits 15:8 (SW2), bit for bit as MAME reads
      d80080; a 1 is "off". MAME's defaults: FF, FF. The service mode is a switch of its own (SYSTEM bit 12): F2 on a keyboard.
    -->
    <switches default="FF,FF" base="16">
        <dip bits="0,1"   name="Difficulty" ids="Hardest,Hard,Easy,Normal"/>
        <dip bits="2,3"   name="Winning Rounds (vs. CPU)" ids="1/1 (not in the manual),3/5,2/3,1/1"/>
        <dip bits="4,5"   name="Winning Rounds (vs. player)" ids="1/1 (not in the manual),3/5,2/3,1/1"/>
        <dip bits="8,10"  name="Coinage" ids="5C/1C,4C/1C,3C/1C,2C/1C,1C/4C,1C/3C,1C/2C,1C/1C"/>
        <dip bits="12"    name="Flip Screen" ids="On,Off"/>
        <dip bits="13"    name="Demo Sounds" ids="Off,On"/>
    </switches>'''

TEMPLATE = '''<misterromdescription>
    <name>{name}</name>
    <setname>{setname}</setname>
    <mameversion>0289</mameversion>
    <year>1996</year>
    <manufacturer>Excellent System</manufacturer>
    <players>2</players>
    <joystick>8</joystick>
    <rotation>horizontal</rotation>
    <rbf>aquarium</rbf>
    <platform>Aquarium</platform>

    <!--
      The image of the Aquarium core (rtl/aquarium_loader.sv, tools/aquarium_rom.py), MAME's regions in MAME's byte order (the
      ROM_LOAD16_WORD_SWAP ROMs swapped back by a one-part interleave), the same layout for both sets:
        0x000000  0x080000  maincpu    the 68000's program
        0x080000  0x040000  audiocpu   the Z80's program and its banks
        0x0C0000  0x040000  oki        the MSM6295's samples (the first half of the ROM; the second is 0xFF and out of its reach)
        0x100000  0x020000  txt        the 8 x 8 tiles
        0x120000  0x080000  mid        the 16 x 16 tiles' low 4 bits
        0x1A0000  0x020000  mid_hi     their fifth bit
        0x1C0000  0x080000  bak        the other layer's
        0x240000  0x020000  bak_hi
        0x260000  0x100000  spritegen  the sprites
      Expects the MAME 0.289 merged romset or the split sets: parts are found by name and CRC. The md5 is MiSTer's (of the parts'
      bytes as read, before the interleave; the image itself is {img_md5}).
      address= is the fast load: a recent Main_MiSTer copies the image into the DDR3 at that byte and the core reads it from there
      (rtl/aquarium_fastload.sv); an older one streams it.
    -->

{switches}

    <!-- what the buttons do, measured in MAME 0.289 and as the game's control panel picture names them: button 1 turns the falling piece
         clockwise ("Rotation Right"), button 2 counter-clockwise ("Rotation Left"); both together are "Magic" -->
    <buttons names="Rotate Right,Rotate Left,Start,Coin" default="A,B,Start,Select"/>

    <rom index="0" zip="{zips}" md5="{md5}" address="0x32000000">
{parts}
    </rom>
</misterromdescription>
'''

COMMON = [
    ('audiocpu', 'excellent_5.10c', 'fa555be1', False, None),
    ('oki: the first 256 KB', 'excellent_4.7d', '9a4af531', False, 0x40000),
    ('txt', 'excellent_2.17e', 'aa071b05', True, None),
    ('mid', 'excellent_1.15b', '575df6ac', True, None),
    ('mid_hi', 'excellent_6.15d', '9065b146', False, None),
    ('bak', 'excellent_8.14g', '915520c4', True, None),
    ('bak_hi', 'excellent_7.17g', 'b96b2b82', False, None),
    ('spritegen', 'd23c8000.1f', '14758b3c', True, None),
]

SETS = [
    dict(setname='aquarium', name='Aquarium (US)', zips='aquarium.zip',
         parts=[('maincpu', 'aquar3.13h', 'f197991e', True, None)] + COMMON),
    dict(setname='aquariumj', name='Aquarium (Japan)', zips='aquariumj.zip|aquarium.zip',
         parts=[('maincpu', 'excellent_3.13h', '344509a1', True, None)] + COMMON),
]


def parts_text(parts):
    out = []
    for label, name, crc, swapped, length in parts:
        ln = f' length="0x{length:X}"' if length else ''
        if swapped:
            out.append(f'        <!-- {label} (ROM_LOAD16_WORD_SWAP: the bytes of each word swapped) -->')
            out.append('        <interleave output="16">')
            out.append(f'            <part name="{name}" crc="{crc}"{ln} map="12"/>')
            out.append('        </interleave>')
        else:
            out.append(f'        <!-- {label} -->')
            out.append(f'        <part name="{name}" crc="{crc}"{ln}/>')
    return '\n'.join(out)


def mra_text(s, md5, img_md5):
    return TEMPLATE.format(name=s['name'], setname=s['setname'], zips=s['zips'], md5=md5, img_md5=img_md5,
                           switches=SWITCHES, parts=parts_text(s['parts']))


def path_of(s):
    if s['setname'] == 'aquarium':
        return os.path.join(ROOT, 'mra', f"{s['name']}.mra")
    return os.path.join(ROOT, 'mra', '_alternatives', '_Aquarium', f"{s['name']}.mra")


def main():
    if len(sys.argv) != 2 or not os.path.isfile(sys.argv[1]):         # before anything overwrites the MRAs
        sys.exit(__doc__)
    import aquarium_rom, mra_build
    z = sys.argv[1]
    for s in SETS:
        p = path_of(s)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        # first without the md5, to compute it the way MiSTer does; then with it, and check
        open(p, 'w', newline='\n').write(mra_text(s, 'None', '?'))
        img, md5 = mra_build.build(p, z)
        img_md5 = hashlib.md5(img).hexdigest()
        open(p, 'w', newline='\n').write(mra_text(s, md5, img_md5))
        img2, md5b = mra_build.build(p, z)
        ref = bytes(aquarium_rom.build(z, s['setname']))
        ok = (img2 == ref) and (md5b == md5)
        print(f"wrote {os.path.relpath(p, ROOT)}: image {len(img2):#x} bytes, md5 {img_md5}, MiSTer's md5 {md5}: "
              + ('identical to aquarium_rom.py' if ok else 'DIFFERS from aquarium_rom.py'))
        if not ok:
            sys.exit(f'{sum(1 for i in range(min(len(img2), len(ref))) if img2[i] != ref[i])} bytes differ, lengths {len(img2)} / {len(ref)}')


if __name__ == '__main__':
    main()
