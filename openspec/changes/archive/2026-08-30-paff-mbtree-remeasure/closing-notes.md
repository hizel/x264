# Closing notes: paff-mbtree-remeasure

## Full stand run (task 4.3), 2026-08-30, Ryzen 7 9800X3D, ffmpeg 8.1.2

    PAFF_MB_SRC_HALL=/mnt/store2/ts/hall.mp4 \
    PAFF_MB_SRC_RELAX=/mnt/store2/ts/relax.mp4 \
    PAFF_MB_SRC_AMV=/mnt/store2/ts/amv1.mp4 \
    tools/test_paff.sh mbtree

All gates PASS on all three clips; every number reproduces design.md D2
well within the pre-registered +-0.3 pp rerun noise (worst deviation
0.07 pp; Q2 prog/MBAFF/PAFF gains match to 0.02 pp).  The synthesized
clips were verified pixel-identical (MSE 0.0) to the archived session
clips, and the _p progressive-control PSNRs match results2.csv to six
decimals (bit-identical encodes via the x264 CLI).

Two protocol corrections fell out of the verification (design.md D1/D5
updated): the interlaced variants carry 400 coded frames, not 200 (the
archived y4m files and mkv outputs prove it; the session's duration
constants for hall_i/amv_i were 2x off -- harmless, BD-rate is invariant
to a per-clip kbps scale), and the stand uses true durations.  Two
toolchain pitfalls found and coded into the stand: a frame-dropping
filter before tinterlace duplicates its first output frame (use input
-ss, not trim), and ffmpeg's default timestamp scaling duplicates frames
when decoding a raw Annex-B stream whose VUI framerate differs from the
raw default (decode with -fps_mode passthrough).

Full output:

mbtree: ffmpeg 8.1.2 Copyright (c) 2000-2026 the FFmpeg developers, tinterlace height-doubling
mbtree: encodes via ./x264, preset medium, default threads -- numbers are machine-dependent (design D5)
mbtree: clip hall source /mnt/store2/ts/hall.mp4
mbtree: clip relax source /mnt/store2/ts/relax.mp4
mbtree: clip amv source /mnt/store2/ts/amv1.mp4
===== hall =====
  cell                        crf         kbps     psnr_y
  hall_i_prog_mb1_crf18        18     3120.017  48.031489
PASS: mbtree hall/i: CRF-18 prog PSNR-Y 48.031489 dB > 40
  hall_i_prog_mb1_crf23        23     1633.250  44.808642
  hall_i_prog_mb1_crf28        28      853.922  41.573710
  hall_i_prog_mb1_crf33        33      454.213  38.296305
  hall_i_prog_mb0_crf18        18     4781.727  49.981767
PASS: mbtree hall/i: CRF-18 prog PSNR-Y 49.981767 dB > 40
  hall_i_prog_mb0_crf23        23     2551.341  46.763803
  hall_i_prog_mb0_crf28        28     1338.905  43.552115
  hall_i_prog_mb0_crf33        33      705.783  40.309855
  hall_i_mbaff_mb1_crf18       18     2656.764  49.721196
  hall_i_mbaff_mb1_crf23       23     1445.120  46.949830
  hall_i_mbaff_mb1_crf28       28      778.753  44.185576
  hall_i_mbaff_mb1_crf33       33      440.862  41.379203
  hall_i_mbaff_mb0_crf18       18     3797.131  51.146450
  hall_i_mbaff_mb0_crf23       23     2092.732  48.278846
  hall_i_mbaff_mb0_crf28       28     1142.233  45.459399
  hall_i_mbaff_mb0_crf33       33      624.536  42.583378
  hall_i_paff_mb1_crf18        18     2179.331  49.639365
  hall_i_paff_mb1_crf23        23     1194.361  46.925445
  hall_i_paff_mb1_crf28        28      651.874  44.225419
  hall_i_paff_mb1_crf33        33      377.219  41.422231
  hall_i_paff_mb0_crf18        18     3218.089  51.192381
  hall_i_paff_mb0_crf23        23     1801.478  48.368676
  hall_i_paff_mb0_crf28        28      995.330  45.603262
  hall_i_paff_mb0_crf33        33      553.692  42.767191
  hall_p_prog_mb1_crf18        18     2414.193  51.290132
PASS: mbtree hall/p: CRF-18 prog PSNR-Y 51.290132 dB > 40
  hall_p_prog_mb1_crf23        23     1597.017  48.862215
  hall_p_prog_mb1_crf28        28     1016.109  45.429490
  hall_p_prog_mb1_crf33        33      604.385  42.147879
  hall_p_prog_mb0_crf18        18     3836.999  52.614163
PASS: mbtree hall/p: CRF-18 prog PSNR-Y 52.614163 dB > 40
  hall_p_prog_mb0_crf23        23     2303.834  50.330957
  hall_p_prog_mb0_crf28        28     1529.490  47.551033
  hall_p_prog_mb0_crf33        33      993.314  44.085554
G0 hall: prog-control mbtree gain -13.1733% (validity gate <= -3%) OK
Q1 hall: PAFF vs MBAFF mbtree-on BD-rate -16.6730% (gate <= +1%) PASS   [mbtree off: -15.4728%, informational]
Q2 hall: mbtree gains (BD-rate on vs off): prog -5.2619%  MBAFF -8.8669%  PAFF -10.3853%
Q2 hall: PAFF/prog gain ratio 1.974 (gate >= 0.50) PASS
===== relax =====
  cell                        crf         kbps     psnr_y
  relax_i_prog_mb1_crf18       18    10667.189  44.568602
PASS: mbtree relax/i: CRF-18 prog PSNR-Y 44.568602 dB > 40
  relax_i_prog_mb1_crf23       23     5338.366  40.647155
  relax_i_prog_mb1_crf28       28     2255.845  36.675461
  relax_i_prog_mb1_crf33       33      846.898  33.221149
  relax_i_prog_mb0_crf18       18    10881.633  44.209630
PASS: mbtree relax/i: CRF-18 prog PSNR-Y 44.209630 dB > 40
  relax_i_prog_mb0_crf23       23     5346.974  40.129715
  relax_i_prog_mb0_crf28       28     2257.695  36.242388
  relax_i_prog_mb0_crf33       33      869.182  32.866339
  relax_i_mbaff_mb1_crf18      18    10872.038  44.673626
  relax_i_mbaff_mb1_crf23      23     5417.865  40.758552
  relax_i_mbaff_mb1_crf28      28     2306.767  36.784719
  relax_i_mbaff_mb1_crf33      33      872.548  33.313459
  relax_i_mbaff_mb0_crf18      18    11012.626  44.283801
  relax_i_mbaff_mb0_crf23      23     5380.914  40.203763
  relax_i_mbaff_mb0_crf28      28     2278.213  36.311581
  relax_i_mbaff_mb0_crf33      33      881.422  32.927495
  relax_i_paff_mb1_crf18       18     8737.146  44.490719
  relax_i_paff_mb1_crf23       23     4321.690  40.225215
  relax_i_paff_mb1_crf28       28     1760.848  36.138249
  relax_i_paff_mb1_crf33       33      681.646  32.463436
  relax_i_paff_mb0_crf18       18     8907.410  43.966266
  relax_i_paff_mb0_crf23       23     4282.244  39.648584
  relax_i_paff_mb0_crf28       28     1745.707  35.679995
  relax_i_paff_mb0_crf33       33      686.069  32.102628
  relax_p_prog_mb1_crf18       18     8745.838  44.540263
PASS: mbtree relax/p: CRF-18 prog PSNR-Y 44.540263 dB > 40
  relax_p_prog_mb1_crf23       23     5234.774  40.750700
  relax_p_prog_mb1_crf28       28     2303.032  36.362797
  relax_p_prog_mb1_crf33       33      862.334  32.674177
  relax_p_prog_mb0_crf18       18     9179.590  44.010102
PASS: mbtree relax/p: CRF-18 prog PSNR-Y 44.010102 dB > 40
  relax_p_prog_mb0_crf23       23     5190.691  39.872509
  relax_p_prog_mb0_crf28       28     2200.758  35.654280
  relax_p_prog_mb0_crf33       33      874.575  32.190326
G0 relax: prog-control mbtree gain -12.0262% (validity gate <= -3%) OK
Q1 relax: PAFF vs MBAFF mbtree-on BD-rate -10.9750% (gate <= +1%) PASS   [mbtree off: -10.4895%, informational]
Q2 relax: mbtree gains (BD-rate on vs off): prog -10.0029%  MBAFF -9.7345%  PAFF -9.7705%
Q2 relax: PAFF/prog gain ratio 0.977 (gate >= 0.50) PASS
===== amv =====
  cell                        crf         kbps     psnr_y
  amv_i_prog_mb1_crf18         18     5788.917  45.121713
PASS: mbtree amv/i: CRF-18 prog PSNR-Y 45.121713 dB > 40
  amv_i_prog_mb1_crf23         23     3526.318  41.325537
  amv_i_prog_mb1_crf28         28     2102.259  37.372808
  amv_i_prog_mb1_crf33         33     1220.160  33.482325
  amv_i_prog_mb0_crf18         18     7937.566  47.074479
PASS: mbtree amv/i: CRF-18 prog PSNR-Y 47.074479 dB > 40
  amv_i_prog_mb0_crf23         23     4897.113  43.400551
  amv_i_prog_mb0_crf28         28     2946.996  39.624098
  amv_i_prog_mb0_crf33         33     1738.194  35.804293
  amv_i_mbaff_mb1_crf18        18     4192.822  47.708928
  amv_i_mbaff_mb1_crf23        23     2626.674  44.578580
  amv_i_mbaff_mb1_crf28        28     1667.512  41.364023
  amv_i_mbaff_mb1_crf33        33     1067.173  38.112679
  amv_i_mbaff_mb0_crf18        18     5290.462  48.599390
  amv_i_mbaff_mb0_crf23        23     3270.951  45.467094
  amv_i_mbaff_mb0_crf28        28     2054.590  42.258156
  amv_i_mbaff_mb0_crf33        33     1309.516  38.996199
  amv_i_paff_mb1_crf18         18     3394.335  47.261747
  amv_i_paff_mb1_crf23         23     2138.323  44.131562
  amv_i_paff_mb1_crf28         28     1361.118  40.856368
  amv_i_paff_mb1_crf33         33      874.460  37.512699
  amv_i_paff_mb0_crf18         18     4665.826  48.558312
  amv_i_paff_mb0_crf23         23     2895.240  45.447719
  amv_i_paff_mb0_crf28         28     1825.540  42.187292
  amv_i_paff_mb0_crf33         33     1163.009  38.869007
  amv_p_prog_mb1_crf18         18     4724.651  46.555584
PASS: mbtree amv/p: CRF-18 prog PSNR-Y 46.555584 dB > 40
  amv_p_prog_mb1_crf23         23     2974.733  43.543466
  amv_p_prog_mb1_crf28         28     1882.562  40.369882
  amv_p_prog_mb1_crf33         33     1189.181  37.117784
  amv_p_prog_mb0_crf18         18     5575.320  46.506914
PASS: mbtree amv/p: CRF-18 prog PSNR-Y 46.506914 dB > 40
  amv_p_prog_mb0_crf23         23     3469.735  43.400987
  amv_p_prog_mb0_crf28         28     2195.963  40.122159
  amv_p_prog_mb0_crf33         33     1392.407  36.819950
G0 amv: prog-control mbtree gain -16.7182% (validity gate <= -3%) OK
Q1 amv: PAFF vs MBAFF mbtree-on BD-rate -12.7230% (gate <= +1%) PASS   [mbtree off: -10.6621%, informational]
Q2 amv: mbtree gains (BD-rate on vs off): prog -4.3606%  MBAFF -8.3049%  PAFF -10.6212%
Q2 amv: PAFF/prog gain ratio 2.436 (gate >= 0.50) PASS
===== smoke =====
SMOKE (synthetic) -- gates not asserted
  cell                        crf         kbps     psnr_y
  smoke_i_prog_mb1_crf18       18     2204.193  50.059058
PASS: mbtree smoke/i: CRF-18 prog PSNR-Y 50.059058 dB > 40
  smoke_i_prog_mb1_crf23       23     1561.696  44.990003
  smoke_i_prog_mb1_crf28       28      929.317  39.521886
  smoke_i_prog_mb1_crf33       33      565.482  35.972883
  smoke_i_prog_mb0_crf18       18     2850.055  54.067948
PASS: mbtree smoke/i: CRF-18 prog PSNR-Y 54.067948 dB > 40
  smoke_i_prog_mb0_crf23       23     2163.620  49.598646
  smoke_i_prog_mb0_crf28       28     1523.713  44.477016
  smoke_i_prog_mb0_crf33       33      908.558  39.185651
  smoke_i_mbaff_mb1_crf18      18     2606.062  50.720204
  smoke_i_mbaff_mb1_crf23      23     1852.476  45.660237
  smoke_i_mbaff_mb1_crf28      28     1131.995  40.115050
  smoke_i_mbaff_mb1_crf33      33      701.644  36.900825
  smoke_i_mbaff_mb0_crf18      18     3280.503  54.525686
  smoke_i_mbaff_mb0_crf23      23     2475.222  49.835644
  smoke_i_mbaff_mb0_crf28      28     1734.171  44.705630
  smoke_i_mbaff_mb0_crf33      33     1040.004  39.477142
  smoke_i_paff_mb1_crf18       18     2656.909  50.414886
  smoke_i_paff_mb1_crf23       23     1869.539  45.300731
  smoke_i_paff_mb1_crf28       28     1117.786  39.875693
  smoke_i_paff_mb1_crf33       33      698.354  36.860006
  smoke_i_paff_mb0_crf18       18     3437.626  54.572137
  smoke_i_paff_mb0_crf23       23     2582.595  49.841550
  smoke_i_paff_mb0_crf28       28     1802.014  44.727558
  smoke_i_paff_mb0_crf33       33     1074.264  39.282173
  smoke_p_prog_mb1_crf18       18     2231.903  49.741188
PASS: mbtree smoke/p: CRF-18 prog PSNR-Y 49.741188 dB > 40
  smoke_p_prog_mb1_crf23       23     1491.239  44.403868
  smoke_p_prog_mb1_crf28       28      791.846  39.254934
  smoke_p_prog_mb1_crf33       33      445.143  36.220727
  smoke_p_prog_mb0_crf18       18     2996.350  54.190247
PASS: mbtree smoke/p: CRF-18 prog PSNR-Y 54.190247 dB > 40
  smoke_p_prog_mb0_crf23       23     2235.414  49.528497
  smoke_p_prog_mb0_crf28       28     1486.377  44.119792
  smoke_p_prog_mb0_crf33       33      804.444  38.928079
---
passed: 16, failed: 0
