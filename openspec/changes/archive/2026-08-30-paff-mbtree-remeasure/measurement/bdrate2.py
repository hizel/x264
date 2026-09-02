#!/usr/bin/env python3
"""Bjontegaard BD-rate, pure python, 4-point cubic interpolation."""
import csv, math

def cubic_solve(xs, ys):
    n = 4
    A = [[x**3, x**2, x, 1.0] for x in xs]
    M = [row[:] + [y] for row, y in zip(A, ys)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        M[c], M[p] = M[p], M[c]
        for r in range(n):
            if r != c:
                f = M[r][c] / M[c][c]
                for k in range(c, n+1):
                    M[r][k] -= f * M[c][k]
    return [M[i][n] / M[i][i] for i in range(n)]

def integ(c, lo, hi):
    a,b,cc,d = c
    F = lambda x: a*x**4/4 + b*x**3/3 + cc*x**2/2 + d*x
    return F(hi) - F(lo)

def bdrate(a, b):
    a = sorted(a); b = sorted(b)
    lo = max(a[0][0], b[0][0]); hi = min(a[-1][0], b[-1][0])
    ca = cubic_solve([p for p,_ in a], [math.log(r) for _,r in a])
    cb = cubic_solve([p for p,_ in b], [math.log(r) for _,r in b])
    return (math.exp((integ(cb,lo,hi)-integ(ca,lo,hi))/(hi-lo)) - 1) * 100

SECS = {'hall_25i':16.0, 'hall_25p':8.0, 'relax_25i':16.0, 'relax_25p':8.0,
        'amv_i':200*1001/15000.0, 'amv_p':200*1001/30000.0}

rows = list(csv.DictReader(open('/tmp/paff_mb/results2.csv')))
data = {}
for r in rows:
    key = (r['content'], r['mode'], r['mbtree'])
    data.setdefault(key, []).append((float(r['psnr_y']), int(r['bytes'])*8/SECS[r['content']]/1000))

def g(content, mode, mb): return data[(content, mode, mb)]

for clip, I, P in (('hall','hall_25i','hall_25p'), ('relax','relax_25i','relax_25p'), ('amv','amv_i','amv_p')):
    print(f"===== {clip} =====")
    g0 = bdrate(g(P,'prog','0'), g(P,'prog','1'))
    print(f"G0  prog mbtree gain on {P} (gate <= -3%): {g0:+.2f}%")
    for mb in ('1','0'):
        q = bdrate(g(I,'mbaff',mb), g(I,'paff',mb))
        print(f"Q1  paff vs mbaff on {I}, mbtree={mb} (gate: >= mbaff-1%): {q:+.2f}%")
    qp = bdrate(g(I,'prog','1'), g(I,'paff','1'))
    print(f"    (ref) paff vs prog on {I}, mbtree=1: {qp:+.2f}%")
    gains = {}
    for mode in ('prog','mbaff','paff'):
        gains[mode] = bdrate(g(I,mode,'0'), g(I,mode,'1'))
        print(f"Q2  {mode:6s} mbtree on vs off on {I}: {gains[mode]:+.2f}%")
    print(f"    PAFF/prog gain ratio (gate >= 0.50): {gains['paff']/gains['prog']:.2f}")
    print()

print("raw tables (psnr_y dB @ kbps):")
for k in sorted(data):
    pts = sorted(data[k])
    print(f"  {k}: " + "  ".join(f"{p:.2f}@{r:.0f}" for p,r in pts))
