# JM comparison checklist for PAFF B fields (task 2.4)

Reference procedure: `doc/regression_test.txt` — encode with `--dump-yuv`,
decode with the JM reference decoder `ldecod`, byte-compare the two
reconstructions.

## Tooling present on this machine

| tool       | status                                                    |
|------------|-----------------------------------------------------------|
| `ldecod`   | **PRESENT** — JM 19.0 (FRExt), `/tmp/JM/bin/ldecod.exe` (ELF, despite the `.exe` suffix). Decodes cleanly. |
| `lencod`   | **ABSENT** — only source under `/tmp/JM/lencod/`; not built. Not needed for the round-trip (x264 is the encoder). |
| `ffmpeg`   | present (`/usr/bin/ffmpeg`, v8.1.2). Useful only as a second decoder; **fails on PAFF** (see 4.1 notes). |

So the round-trip **was run** (see `checkpoint-4.1-4.3.md`). The blocker is
not tooling — it is that **PAFF output is not yet JM-conformant** (P-only fields
included), so the B-field comparisons below cannot yet reach "bit-exact". They
are listed here as the exact matrix to re-run once the PAFF bitstream-conformance
defects in the `paff-field-references` / `paff-core-ip` lineage are fixed.

## Canonical round-trip command pair

```sh
X264=/home/hizel/dev/x264/x264
LDEC=/tmp/JM/bin/ldecod.exe
# 1. x264 encodes and dumps its own reconstruction (fdec.yuv)
$X264 input.yuv --input-res WxH --frames N --threads 1 \
    --paff --tff --bframes 2 --qp 24 \
    --dump-yuv fdec.yuv -o stream.264
# 2. JM reference decoder reconstructs the SAME bitstream
$LDEC -d /tmp/JM/bin/decoder.cfg \
    -p InputFile=\"stream.264\" -p OutputFile=\"ref.yuv\" -p RefFile=\"fdec.yuv\" \
    -p Silent=1
# 3. must be byte-identical
cmp fdec.yuv ref.yuv
```

Notes:
- Use `--threads 1` for determinism.
- PAFF B requires `--qp` or `--crf` (1-pass); ABR/CBR/VBV/2-pass are hard-errored
  by D8 until `paff-sei-hrd-rc`. Use `--qp` for a clean CQP comparison.
- JM `-p RefFile=...` lets ldecod print SNR/PSNR against the reference; the
  authoritative check is still the `cmp` of the two reconstructions.
- Do **not** trust the shell exit code after `x264 ... | tail` — the pipe masks
  a possible x264 segfault. Capture rc directly: `x264 ... >log 2>&1; echo $?`.

## Targeted B-field matrix (run each for TFF and BFF)

For each row: encode → JM decode → `cmp`. Expect BIT-IDENTICAL once PAFF is
conformant. Record PSNR/SSIM with `--psnr --ssim` on the x264 side too.

| # | x264 args (add `--paff --tff` or `--paff --bff`, `--threads 1`, `--qp 24`) | what it exercises |
|---|----------------------------------------------------------------------------|-------------------|
| 1 | (baseline) `--bframes 0`                                                    | P/I field pictures only — isolate the pre-existing PAFF conformance defect. |
| 2 | `--bframes 2`                                                               | basic B fields, default `--direct` (auto). |
| 3 | `--bframes 3 --direct temporal`                                             | temporal direct (§8.4.1.2.4): colocated-field parity, MV scaling in field-POC units. |
| 4 | `--bframes 3 --direct spatial`                                              | spatial direct (§8.4.1.3): uniformly-field neighbours. |
| 5 | `--bframes 3 --direct auto`                                                 | per-MB direct selection. |
| 6 | `--bframes 3 --ref 2`                                                       | multi-ref L0/L1 with a small DPB. |
| 7 | `--bframes 3 --ref 3`                                                       | multi-ref L0/L1 with a larger DPB (also ≥3 avoids the BREF-eviction crash, see 4.1 notes). |
| 8 | `--bframes 3 --b-pyramid normal --ref 3`                                    | hierarchical B-field pyramid (POC / ref marking). |
| 9 | `--bframes 3 --b-pyramid normal --ref 2`                                    | **BREF MMCO eviction** — pair removal needs two opcodes (one per parity); reaches the DPB cap. **Currently segfaults the x264 encoder** (see 4.1 notes); must be fixed before this row is meaningful. |

Rows 1–8 must additionally be run with the chroma-JM comparison added per task
2.2c (bipred chroma vertical subpel offset keyed on `i_fref_parity`).

## Current observed results (JM 19.0, this run)

| row | x264 encode        | JM `ldecod` decode                | `cmp fdec ref` |
|-----|--------------------|-----------------------------------|----------------|
| prog (non-PAFF sanity) | OK  | 30/30 frames, 0 warnings          | **BIT-IDENTICAL** |
| 1 (`--bframes 0 --ref 1`) | **SEGFAULT (x264)** | — | — |
| 1 (`--bframes 0 --ref 2`) | OK | decodes but `zero_byte shall exist` ×N, `num_ref_idx_l0_active` drifts (1→3→4→5), **"Max. number of reference frames exceeded. Invalid stream."**, wrong frame count (17 vs 16) | DIFFERS |
| 2 (`--bframes 2 --qp 24`) | OK | **SEGFAULT (ldecod)** after frame 4, same warnings + "Max. number of reference frames exceeded" | DIFFERS (crash) |
| 9 (`--b-pyramid normal --ref 2`) | **SEGFAULT (x264)** | — | — |

Conclusion: **every PAFF case is blocked by pre-existing PAFF bitstream
non-conformance** (defects: missing `zero_byte` before certain NAL start codes,
wrong `num_ref_idx_l0_active`, DPB overflow) plus two encoder crashes
(`--paff --ref 1`, and `--paff --b-pyramid normal --ref ≤2`). These are traced
to the `paff-field-references` / `paff-core-ip` lineage (row 1 is P-only, no
B-frames) and to the BREF-eviction path (task 2.1) respectively. The B-field
direct-mode comparisons (rows 3–8) cannot be validated until the baseline PAFF
stream round-trips bit-exact.

## What "done" looks like for task 2.4

Row 1 (P-only) and row 2 (basic B) round-trip **BIT-IDENTICAL** through JM
ldecod for **both** `--tff` and `--bff`, with zero `zero_byte`/DPB warnings.
Only then are the direct-mode-specific rows (3–8) meaningful, and they too
must each be bit-identical.
