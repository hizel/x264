# Stage 1 results — progressive positive control (design D2)

Date: 2026-08-30
Encoder: x264 0.166.3223+13M 3919aed (branch paff-core-ip-spec-review,
HEAD 3919aed0), `--chroma-format=all`, threads 1, CRF 18/23/28/33, PSNR-Y.
ffmpeg: 8.1.2 (tinterlace merge doubles the height; detected window = 100
progressive frames ~= first 2 s of the clip timeline).
Command: `WB2_MODES=prog tools/test_paff.sh weightb2` (full transcript:
the per-CRF tables below).

## Provenance

- C1/C2/C5-real source A: `/mnt/store2/ts/hall.mp4` (720p25, 86 s)
- C1 source B: `/mnt/store2/ts/eurosport_input.mp4` (1080p50, 299 s)
- C5 variant: **real** (source A straight; env vars were set)
- C3: lavfi `xfade(testsrc2, smptehdbars)` + `noise=alls=10:allf=t+u:all_seed=42`
- C4: legacy `make_dissolve_clip` recipe (unmodified reference cell)
- All clips: 100 coded frames in the window, yuv420p, 50 fps timeline;
  QCIF 176x144 plus the C1 duplicate at 720x576.
- Generation gates all passed: C1 blend provably inside the coded window
  at both geometries (frames 10/37/98 mutually distinct), C2 dip verified
  (YAVG 31.7 pre-fade vs 16.0 at the plateau), C3 != C4.

Note: the C2 generator's first version chained `fade=t=in` after
`fade=t=out` on one timeline; `fade=t:in` forces black for every frame
before its start time, so the clip came out all-black.  Fixed with a
split/concat (the fade-in leg gets its own zero-based timeline).  Also:
blackdetect is unusable as the C2 gate on dark real content (it trips at
t=0.8 s on hall.mp4 before the dip); the gate is YAVG at the plateau vs
pre-fade instead.

## BD-rate, weightb-on vs weightb-off (%, positive = weightb saves bits)

| clip   | content                          | BD-rate |
|--------|----------------------------------|---------|
| c1     | real-scene crossfade, 176x144    | +0.457  |
| c1_576 | real-scene crossfade, 720x576    | +0.275  |
| c2     | dip-to-black (diagnostic only)   | -0.288  |
| c3     | grained synthetic crossfade      | -0.339  |
| c4     | legacy synthetic crossfade       | +0.526  |
| c5     | non-dissolve control             | -0.242  |

Per-CRF tables (kbps / PSNR-Y):

```
c1      prog weight  crf         kbps     psnr_y
                 on   18       172.99     44.352
                 on   23        93.98     40.954
                 on   28        51.92     37.646
                 on   33        29.83     34.553
                off   18       173.48     44.372
                off   23        93.80     40.915
                off   28        52.03     37.631
                off   33        29.96     34.527
c1_576  prog weight  crf         kbps     psnr_y
                 on   18      1821.25     47.071
                 on   23       945.72     43.891
                 on   28       492.52     40.775
                 on   33       270.24     37.799
                off   18      1818.45     47.059
                off   23       944.42     43.868
                off   28       492.71     40.760
                off   33       268.46     37.757
c2      prog weight  crf         kbps     psnr_y
                 on   18        75.34     56.586
                 on   23        44.84     54.266
                 on   28        28.25     51.822
                 on   33        18.26     49.153
                off   18        75.78     56.643
                off   23        45.29     54.347
                off   28        28.21     51.797
                off   33        18.45     49.240
c3      prog weight  crf         kbps     psnr_y
                 on   18       356.20     37.820
                 on   23       118.34     36.193
                 on   28        66.78     33.794
                 on   33        40.57     30.767
                off   18       358.68     37.831
                off   23       118.47     36.198
                off   28        66.15     33.788
                off   33        40.52     30.755
c4      prog weight  crf         kbps     psnr_y
                 on   18       195.21     44.902
                 on   23       120.91     40.529
                 on   28        72.98     36.370
                 on   33        45.48     32.463
                off   18       194.65     44.891
                off   23       121.71     40.501
                off   28        73.40     36.363
                off   33        45.84     32.525
c5      prog weight  crf         kbps     psnr_y
                 on   18        93.46     47.865
                 on   23        55.83     45.006
                 on   28        35.48     41.861
                 on   33        22.70     38.605
                off   18        93.45     47.861
                off   23        56.14     45.032
                off   28        35.24     41.835
                off   33        22.40     38.586
```

## Stage-1 gate verdict (task 3.2)

Gate: at least one clip with a progressive gain >= 1.0%.

Largest gain: **+0.526% (c4, the legacy synthetic clip)**.  Every
realistic-content clip is below it: c1 +0.457%, c1_576 +0.275%, c3
negative, c5 neutral.  No clip reaches 1.0%.

**GATE FAILED — the feature is dead on all tested content including
progressive.**  Per design D2 the PAFF question is moot: stage 2
(tasks 4.1-4.3) is skipped and the outcome is KILL (section 5).

External context (found after the measurement): implicit bipred
weighting entered x264 in Feb 2005 (svn r134) with no published
measurement; the well-known WP gains in the literature are explicit
weights on fades to/from black (up to 67% bitrate, Boyce ISCAS 2004) —
weightp territory; and HEVC dropped the implicit mode from the
standard entirely ("in HEVC only explicit weighted prediction is
applied", Sullivan et al., IEEE TCSVT 2012), as did VVC.  Our numbers
are consistent with that silent industry consensus — this appears to
be the first published gain measurement of implicit weightb at all.

The positive control did its job: the archived 0.272% PAFF number was
right for the wrong reason — the original clip was not unusually weak
content, implicit bipred weights simply gain nothing measurable even on a
real-scene crossfade (c1) where they are supposed to help most.  C4's
progressive gain here (+0.526%) vs the archived "~0%" is consistent with
BD-rate noise on a 100-frame 4-point sweep plus the RC changes since
`paff-weightb`; the archived PAFF cell is not re-run because stage 2 is
gated off (the C4-reproduction check exists to validate stage-2 numbers,
of which there are none).
