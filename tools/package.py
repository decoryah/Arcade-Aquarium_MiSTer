#!/usr/bin/env python3
"""Build the release zip in MiSTer's SD card structure from the repository (the Gunpey core's tools/package.py, after the Rabbit and Mystic Warriors cores'):

  _Arcade/Aquarium (US).mra                                   the MRA                       (mra/*.mra)
  _Arcade/_alternatives/_Aquarium/Aquarium (Japan).mra       the Japanese version's MRA    (mra/_alternatives/...)
  _Arcade/cores/aquarium_<YYYYMMDD>[x].rbf                      the core                      (releases/aquarium_<YYYYMMDD>[x].rbf)

  python3 tools/package.py [YYYYMMDD[x]]     (default: the newest RBF in releases/; a letter after the date is a later build
                                              of that day, as in the Hexion core)

Writes dist/Aquarium_MiSTer_<YYYYMMDD>[x].zip (dist/ is not in the repository). Unzip it over the root of the SD card. No ROMs are in it:
the MAME 0.289 romset (aquarium.zip) goes to /media/fat/games/mame/.
"""
import glob
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DIST = os.path.join(REPO, 'dist')


def main(argv):
    rbfs = sorted(r for r in glob.glob(os.path.join(REPO, 'releases', 'aquarium_*.rbf')) if re.search(r'aquarium_\d{8}[a-z]?\.rbf$', r))
    if argv:
        rbfs = [r for r in rbfs if r.endswith('aquarium_%s.rbf' % argv[0])]
    if not rbfs:
        print('no releases/aquarium_YYYYMMDD.rbf')
        return 1
    rbf = rbfs[-1]
    date = re.search(r'aquarium_(\d{8}[a-z]?)\.rbf$', rbf).group(1)
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'Aquarium_MiSTer_%s.zip' % date)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for full in sorted(glob.glob(os.path.join(REPO, 'mra', '**', '*.mra'), recursive=True)):
            z.write(full, '_Arcade/' + os.path.relpath(full, os.path.join(REPO, 'mra')).replace(os.sep, '/'))
        z.write(rbf, '_Arcade/cores/' + os.path.basename(rbf))
    print(out)
    with zipfile.ZipFile(out) as z:
        for n in z.namelist():
            print('  ' + n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
