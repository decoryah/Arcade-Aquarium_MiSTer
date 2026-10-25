#!/usr/bin/env python3
"""audio_cmp.py <bench.wav> <mame.wav> [--from F] [--to F]: the core's sound (the system bench's AUDIO=1 output: 48 kHz, 16-bit
stereo, from the CPUs' start) against MAME's -wavwrite recording of the same scripted run (after the owner's Hexion core's tool).

Per frame of the game (1/60 s) the RMS of each channel is computed; the two envelopes are aligned by the lag (in frames, -30 .. +30)
that correlates best, and their ratio and correlation reported over frames F .. T, for left, right and their mean."""
import sys, struct, math, argparse

FRAME = 1 / 60

ap = argparse.ArgumentParser()
ap.add_argument('ours'); ap.add_argument('wav')
ap.add_argument('--from', dest='f0', type=int, default=60); ap.add_argument('--to', dest='f1', type=int, default=0)
a = ap.parse_args()


def read_wav(p):
    d = open(p, 'rb').read()
    i = 12
    rate = ch = None
    while i < len(d):
        cid, ln = d[i:i + 4], struct.unpack('<I', d[i + 4:i + 8])[0]
        if cid == b'fmt ':
            _, ch, rate = struct.unpack('<HHI', d[i + 8:i + 16])
        elif cid == b'data':
            s = struct.unpack('<%dh' % (len(d[i + 8:i + 8 + ln]) // 2), d[i + 8:i + 8 + ln])
            if ch == 2:
                return rate, list(s[0::2]), list(s[1::2])
            return rate, list(s), list(s)
        i += 8 + ln
    sys.exit('no data chunk')


def env(s, rate):
    per = rate * FRAME
    out, f = [], 0
    while int((f + 1) * per) <= len(s):
        s0, s1 = int(f * per), int((f + 1) * per)
        out.append(math.sqrt(sum(v * v for v in s[s0:s1]) / (s1 - s0)))
        f += 1
    return out


def corr(x, y):
    n = len(x)
    if n == 0: return 0
    mx, my = sum(x) / n, sum(y) / n
    sxy = sum((p - mx) * (q - my) for p, q in zip(x, y))
    sxx = sum((p - mx) ** 2 for p in x); syy = sum((q - my) ** 2 for q in y)
    return sxy / math.sqrt(sxx * syy) if sxx > 0 and syy > 0 else 0


ro, ol, orr = read_wav(a.ours)
rm, ml, mr = read_wav(a.wav)
for name, so, sm in (('left', ol, ml), ('right', orr, mr), ('mean', [(p + q) / 2 for p, q in zip(ol, orr)], [(p + q) / 2 for p, q in zip(ml, mr)])):
    o, m = env(so, ro), env(sm, rm)
    f1 = a.f1 or min(len(o), len(m))
    best = None
    for lag in range(-30, 31):
        xs = [o[f] for f in range(a.f0, f1) if 0 <= f + lag < len(m) and f < len(o)]
        ys = [m[f + lag] for f in range(a.f0, f1) if 0 <= f + lag < len(m) and f < len(o)]
        c = corr(xs, ys)
        if best is None or c > best[0]: best = (c, lag, xs, ys)
    c, lag, xs, ys = best
    ratio = (sum(xs) / sum(ys)) if sum(ys) > 0 else float('nan')
    print(f'{name:5s} frames {a.f0}-{f1}: best lag {lag:+d} frames (MAME later when +), envelope correlation {c:.4f}, '
          f'level ours/MAME {ratio:.3f}, mean RMS ours {sum(xs)/max(1,len(xs)):.0f} MAME {sum(ys)/max(1,len(ys)):.0f}')
