#!/usr/bin/env python3
"""Find true frame alignment: compare each coded frame to ref frames k-2..k+2."""
import subprocess, sys

FF = '/home/hizel/dev/FFmpeg/ffmpeg'
W, H = 1280, 720
FSZ = W*H*3//2

def raw(path):
    return subprocess.run([FF,'-hide_banner','-v','error','-i',path,
        '-c:v','rawvideo','-pix_fmt','yuv420p','-f','rawvideo','-'], capture_output=True).stdout

ref = raw('/tmp/paff_mb/amv_p.y4m')
dec = raw('/tmp/paff_mb/amv_p_prog_1_18.mkv')
nref, ndec = len(ref)//FSZ, len(dec)//FSZ
print(f"ref frames={nref} dec frames={ndec}")

def mse_y(a, b):
    # luma plane only, subsample every 16th byte for speed
    diff = 0; n = 0
    ya = memoryview(a)[:W*H]; yb = memoryview(b)[:W*H]
    for i in range(0, W*H, 16):
        d = ya[i] - yb[i]; diff += d*d; n += 1
    return diff / n

bad = [7,10,12,13,18,21,23,26,29,32]
for k1 in bad:           # 1-based
    k = k1-1
    d = dec[k*FSZ:(k+1)*FSZ]
    row = []
    for j in range(max(0,k-2), min(nref,k+3)):
        m = mse_y(ref[j*FSZ:(j+1)*FSZ], d)
        row.append(f"ref{j+1}:mse={m:8.1f}")
    print(f"dec{k1}: " + "  ".join(row))
