# Checkpoint 2.2: ABR/CBR/CRF validation + RD comparison vs MBAFF

Runs: `tools/test_paff_rd.sh` (new) — 352x288, 100 interlaced frames
(testsrc2 @50 fps -> tinterlace), all encodes `--threads 1 --psnr --ssim`.
Conformance re-verified with `tools/test_paff.sh` plus JM round-trips of
the RC modes (`/tmp/paff_test`, 176x144, 25 frames).

## Bug found and fixed (commit with this checkpoint)

**2-pass undershot the target bitrate by ~35% under PAFF** (263 of 400 kb/s;
MBAFF/prog: 391/390).  Root cause: `slice_write` accounts
`i_misc_bits = bs_pos(&h->out.bs) + i_nal*NALU_OVERHEAD*8 - tex - mv`, and
`h->out.bs` spans BOTH field passes of a PAFF pair (it is re-initialised per
frame, not per field).  The second pass therefore counted the first field's
bytes a second time, inflating the merged pair stats by ~50%.  The 2-pass
bit model converged exactly onto the inflated stats (pass-3 reproduces the
undershoot bit-for-bit).

Fix (`encoder/encoder.c`, PAFF pair driver): snapshot
`bs_pos + i_nal*NALU_OVERHEAD*8` at the end of the first field's AU and
subtract it from pass 1's `i_misc_bits`.  After the fix the recorded stats
match the actual stream size to within 1 byte/pair in both passes, and the
per-field `i_field_bits[]` accounting (task 2.3's input) is exact too.

## Rate accuracy (250-frame run, target 400 kb/s)

| mode                         | PAFF TFF | MBAFF |
|------------------------------|----------|-------|
| 1-pass ABR                   | 413.9    | 440.7 |
| 2-pass (turbo first pass)    | 360.0    | 391.4 |
| 2-pass `--slow-firstpass`    | 394.5    | 382.1 |

- 1-pass ABR: PAFF is closer to target than MBAFF.
- 2-pass with the default TURBO first pass still undershoots ~10% (MBAFF 2%).
  Root cause: the turbo pass-1 -> full-settings pass-2 bit-model mismatch is
  amplified by field pictures (field ME gains more from subme/trellis in the
  second pass).  With `--slow-firstpass` PAFF lands within 1.5% of target
  (better than MBAFF).  **Recommendation for `doc/paff.txt` (task 4.1): use
  `--slow-firstpass` for PAFF 2-pass.**
- CRF is constant-quality by definition; see RD curves below.

## Rate-distortion vs MBAFF (CRF sweep, PSNR-Y, log-rate interpolation)

Detailed clip (testsrc2 tinterlace, 400-1200 kb/s common range):

| comparison    | avg PSNR delta at matched bitrate |
|---------------|-----------------------------------|
| PAFF vs MBAFF | **+2.88 dB**                      |
| PAFF vs prog  | +0.25 dB                          |
| MBAFF vs prog | -2.36 dB                          |

Blurred/"natural" variant (gblur sigma=1.5): same ordering, PAFF ~+3.5 dB
over MBAFF at matched bitrate (e.g. 45.5 dB @441 kb/s vs ~41.9 dB).

Same-CRF tables are misleading here: PAFF codes genuinely interlaced content
much more efficiently, so at equal CRF it simply spends fewer bits (CRF 20:
806 vs 1078 kb/s).  At matched bitrate PAFF is uniformly ahead of MBAFF on
interlaced content and competitive with progressive coding.  The design.md
risk "RC quality regression vs MBAFF" does not materialize — no RC-quality
gap to document for ABR/CRF/2-pass.

## Remaining gaps (owned by later tasks)

- **CBR/VBV overshoots the target**: `--bitrate 400 --vbv-bufsize 400
  --vbv-maxrate 400 --bframes 0` gives PAFF +22% (487 kb/s) vs MBAFF/prog
  +11% (444/445).  Expected: the VBV buffer model still steps per PAIR with
  a double-sized picture instead of per field access unit — this is exactly
  task 2.3 (per-field VBV, OQ1).  Re-measure after 2.3.
- **CBR + B-frames stays hard-rejected** at validation until 2.3 lands.
- Turbo-first-pass 2-pass undershoot (above) — document, don't fix.
- Frame threads still forced to 1 (task 3.1).

## Conformance after the misc fix

- `tools/test_paff.sh`: 12/12 PASS (progressive + MBAFF baselines decoded
  identical — non-PAFF output untouched; all PAFF round-trips bit-exact).
- JM round-trips of RC modes, all BIT-EXACT vs `--dump-yuv`:
  `--bitrate 100` (ABR), ABR + `--bframes 3`,
  `--bitrate 100 --slow-firstpass --pass 2`,
  `--bitrate 100 --vbv-bufsize 100 --vbv-maxrate 100 --bframes 0` (CBR).
