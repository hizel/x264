#!/usr/bin/env python3
"""Bjontegaard BD-rate between two rate-distortion curves.

Pure python (stdlib only, no numpy).  4-point cubic interpolation of
log(rate) as a function of PSNR, integrated over the common PSNR range
(Bjontegaard, VCEG-M33).  Prints the average rate change of curve B
relative to curve A in percent: negative means B reaches the same
quality in fewer bits.

Usage: bdrate.py A.points B.points

Each point file holds exactly 4 lines "psnr_y kbps" (whitespace or comma
separated; blank lines and '#' comments are ignored).  Exit status is
non-zero on any input or numeric error.

Used by tools/test_paff.sh mbtree (paff-mbtree-remeasure).  Ported from
the session's reference implementation, archived in
openspec/changes/paff-mbtree-remeasure/measurement/bdrate2.py.
"""
import math
import sys


def cubic_solve(xs, ys):
    """Solve for the cubic through 4 (x, y) points by Gaussian elimination."""
    n = 4
    M = [[x**3, x**2, x, 1.0, y] for x, y in zip(xs, ys)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) < 1e-12:
            raise ValueError("degenerate point set (duplicate PSNR values?)")
        M[c], M[p] = M[p], M[c]
        for r in range(n):
            if r != c:
                f = M[r][c] / M[c][c]
                for k in range(c, n + 1):
                    M[r][k] -= f * M[c][k]
    return [M[i][n] / M[i][i] for i in range(n)]


def integ(c, lo, hi):
    """Integral of the cubic c over [lo, hi]."""
    a, b, cc, d = c
    F = lambda x: a * x**4 / 4 + b * x**3 / 3 + cc * x**2 / 2 + d * x
    return F(hi) - F(lo)


def bdrate(a, b):
    """BD-rate (%) of curve B vs curve A; a/b are lists of (psnr, kbps)."""
    a = sorted(a)
    b = sorted(b)
    lo = max(a[0][0], b[0][0])
    hi = min(a[-1][0], b[-1][0])
    if hi <= lo:
        raise ValueError("no common PSNR range between the curves")
    ca = cubic_solve([p for p, _ in a], [math.log(r) for _, r in a])
    cb = cubic_solve([p for p, _ in b], [math.log(r) for _, r in b])
    return (math.exp((integ(cb, lo, hi) - integ(ca, lo, hi)) / (hi - lo)) - 1) * 100


def read_points(path):
    pts = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.split('#', 1)[0].replace(',', ' ').strip()
            if not line:
                continue
            fields = line.split()
            if len(fields) != 2:
                raise ValueError("%s:%d: want 2 columns (psnr_y kbps), got %d"
                                 % (path, lineno, len(fields)))
            psnr, kbps = float(fields[0]), float(fields[1])
            if kbps <= 0:
                raise ValueError("%s:%d: non-positive bitrate" % (path, lineno))
            pts.append((psnr, kbps))
    if len(pts) != 4:
        raise ValueError("%s: want exactly 4 points, got %d" % (path, len(pts)))
    return pts


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    try:
        print("%.4f" % bdrate(read_points(argv[1]), read_points(argv[2])))
    except (OSError, ValueError) as e:
        sys.stderr.write("bdrate: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
