# Tasks: paff-mbtree-remeasure

Protocol, gates and measured numbers: design.md D1/D2. Stand shape: D4/D5.
No encoder code changes anywhere in this change.

## 1. BD-rate tool

- [x] 1.1 Add `tools/bdrate.py`: pure-python (stdlib only, no numpy)
      Bjøntegaard BD-rate from (PSNR-Y, kbps) point lists, 4-point cubic
      interpolation; CLI takes two CSV/space-separated point files.
      Port from the reference implementation archived in
      `openspec/changes/paff-mbtree-remeasure/measurement/bdrate2.py`.
      Verify: `python3 tools/bdrate.py a.txt b.txt` on point sets derived
      from the archived `measurement/results2.csv` reproduces the
      design.md D2 numbers (e.g. hall PAFF mbtree cell: -10.37% within
      0.05).

## 2. Test stand cell

- [x] 2.1 Add `cmd_mbtree` to `tools/test_paff.sh` + `mbtree` entry in the
      usage header. Clip synthesis at runtime via ffmpeg tinterlace (same
      recipe as design D1), real sources via env vars
      (`PAFF_MB_SRC_HALL` / `PAFF_MB_SRC_RELAX` / `PAFF_MB_SRC_AMV`),
      missing source = clip skipped (existing cell convention); a lavfi
      testsrc2-based synthetic clip always runs as a smoke fallback --
      pipeline self-check only: the matrix runs to completion, PSNR lines
      parse, the CRF-18 sanity bound holds, but NO gates are asserted on
      it and its output is labeled `SMOKE (synthetic) -- gates not
      asserted` (design D5).
      Verify: command runs with no env vars set (smoke only, skips noted)
      and with all three env vars set (full matrix).
- [x] 2.2 Encode matrix in `cmd_mbtree` via the x264 CLI (`$X264`): modes
      prog / `--interlaced --tff` / `--paff --tff` x `--no-mbtree` /
      default x `--crf 18 23 28 33`, preset medium, default threads
      (session protocol; numbers are machine-dependent via the thread
      count -- the cell header says so).  PSNR-Y is measured EXTERNALLY:
      decode each output and compare against the reference with ffmpeg's
      psnr filter over rawvideo inputs (the D4-safe recipe -- exactly
      the session's statistic; x264's own `--psnr` was rejected, see
      design D5).  kbps = output bytes * 8 / clip duration, per-clip
      duration constants next to each synthesis recipe.  Verify: one PSNR
      value logged per encode and CRF-18 rows are > 40 dB on the
      progressive controls (pipeline self-check).
- [x] 2.3 Gate evaluation in `cmd_mbtree` (semantics: design D5).
      G0 (prog mbtree gain <= -3% BD-rate) is a validity check -- abort
      non-zero on failure.  Q1 (PAFF not worse than MBAFF +1%, mbtree
      on) and Q2 (PAFF mbtree gain >= 50% of prog gain on the same clip)
      are report-only: print PASS/FAIL with the numbers, exit 0
      regardless.  Q2 denominator guard: if |prog gain| < 1% BD-rate,
      print INCONCLUSIVE for that clip instead of a ratio.  Verify: with
      the three session clips the output reproduces design.md D2 within
      rerun noise (+-0.3 pp) and all gates report PASS.

## 3. Documentation

- [x] 3.1 `doc/paff.txt`: remove the "Per-field mbtree propagation" bullet
      from "Future work"; add a "Measured and closed" subsection in the
      "Quality" section with: the question, the pre-registered gates
      (G0/Q1/Q2, incl. the Q2 denominator guard), the 3-clip results
      table from design.md D2, the D4 rawvideo-pairing pitfall note, and
      a pointer to `tools/test_paff.sh mbtree`.  Add a one-line
      cross-reference to it from the weightb measured-and-rejected note
      in "Rate control and VBV" (so the two closed items find each
      other).  Verify:
      `rg -n "mbtree" doc/paff.txt` shows no Future-work bullet and one
      closed-item note.
- [x] 3.2 `encoder/slicetype.c` (`macroblock_tree_propagate`, ~line 1062):
      rewrite the PAFF caveat comment — replace "do nothing here unless
      that bound fails" with the resolved status: measured 2026-08
      (paff-mbtree-remeasure), no deficit on 3 clips, gates in
      doc/paff.txt / `tools/test_paff.sh mbtree`. Comment-only edit.
      Verify: file diff touches comment lines only.

## 4. Checkpoint

- [x] 4.1 Non-PAFF bit-identity: `tools/test_paff.sh baseline-check` (the
      only code-adjacent file changed is a comment, so this must pass
      trivially). Verify: all baselines bit-identical.
- [x] 4.2 `make -j$(nproc)` clean build + `tools/test_paff_ci.sh` green.
      Verify: no new warnings, CI smoke passes.
- [x] 4.3 Full cell run recorded: paste the `tools/test_paff.sh mbtree`
      output (3 clips) into the change's closing notes; confirm every gate
      PASS. Verify: output archived in the change directory.
