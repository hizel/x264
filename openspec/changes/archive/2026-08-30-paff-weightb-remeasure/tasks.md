# Tasks: paff-weightb-remeasure

## 1. Clip generators (tools/test_paff.sh)

- [x] 1.1 Add the C1 real-scene crossfade generator: env vars
      `PAFF_WB_SRC_A` / `PAFF_WB_SRC_B`, trim both to 4 s, scale/pad to
      `${WIDTH}x${HEIGHT}`, `xfade=transition=fade:duration=1.5:offset=0.5`
      (blend zone t=0.5..2.0 s, inside the ~2 s coded window on BOTH
      ffmpeg lines — tinterlace merge doubles the height on ffmpeg 8,
      so 100 coded frames cover only the first ~2 s of the timeline);
      write the progressive variant and the `tinterlace`'d variant (BFF
      cells re-encode the same file with `--bff` — no field-swapped
      file); also write a 720x576 pair for the duplicate C1 cell;
      missing env vars -> skip with a message.  Verify: generated clips
      play back with ffprobe showing the expected frame count and
      geometry, AND mid-window decoded frames are real blends
      (checksum matches neither source), so the blend provably sits
      inside the coded window.
      Done: `make_wb2_c1` + `wb2_check_c1` (frames at 10/37/98% of the
      window mutually distinct => distinct scenes, real mid-window
      blend); window width detected empirically via a tinterlace probe
      (`wb2_detect_window`), not version parsing.  Verified on ffmpeg
      8.1.2 with real sources, both geometries.
- [x] 1.2 Add the C2 dip-to-black generator (source A + `fade=t=out`
      1.5 s + `fade=t=in` 1.5 s).  Verify: clip exists, middle frames
      are near-black (spot-check with `signalstats` or a decoded frame).
      Done: `make_wb2_c2` + `wb2_check_c2`.  Two traps documented in
      results-stage1.md: `fade=t:in` forces black before its start time
      (chaining it after fade-out blacks the whole clip — fixed with
      split/concat), and blackdetect trips early on dark real content
      (the gate is YAVG at the plateau vs pre-fade instead).
- [x] 1.3 Add the C3 grained synthetic crossfade generator (the old
      testsrc2/smptehdbars xfade recipe + `noise=alls=10:allf=t+u`).
      Verify: clip differs from the C4 clip (distinct checksums).
      Done: `make_wb2_c3` (grain seed pinned, `all_seed=42`); the C3/C4
      checksum gate runs in `cmd_weightb2`.
- [x] 1.4 Keep C4 (existing `make_dissolve_clip` output) and add C5
      (source A straight, no fades, 100 frames; when `PAFF_WB_SRC_A` is
      unset, fall back to the lavfi control recipe — C5 never skips).
      Verify: C4 numbers reproduce the archived 0.272% within noise
      when re-run on the same ffmpeg line.
      Done: C5 = `make_wb2_c5` (ran with the real variant; the variant
      is echoed for the results).  The C4-PAFF reproduction cell is
      moot under the failed stage-1 gate — it exists to validate
      stage-2 numbers, and stage 2 never ran (recorded in
      results-stage1.md).

## 2. weightb2 measurement command

- [x] 2.1 Implement `cmd_weightb2` in `tools/test_paff.sh`: per clip
      (C1..C5, C1 at both 176x144 and 720x576), per mode (progressive /
      paff-tff / paff-bff), CRF
      18/23/28/33, `--threads 1`, weightb on vs off, PSNR-Y and kbps
      parsed from `--psnr` logs, BD-rate via the existing `bdrate`
      helper; results table printed per clip per mode.  Verify: a smoke
      run on C4 completes and prints a BD-rate line per mode.
      Done: full stage-1 run (all clips, mode prog) printed tables +
      BD-rate lines; progressive mode needs no revert.
- [x] 2.2 Add the force-off guard: the command greps the weightb-on
      PAFF logs for the validation warning and FAILS the run if it
      appears (means the local revert is missing).  Verify: without the
      revert the command aborts with a clear message; with the revert
      it runs.
      Done: without the revert the run aborts at the first PAFF on-row
      ("the PAFF force-off ate --weightb -- apply the local validation
      revert ..."); with the hunk applied the warning is gone (2.3).
- [x] 2.3 Document the local revert hunk (the exact validation lines in
      `x264_encoder_open`) in the command's header comment.  Verify:
      applying the documented hunk to a clean tree builds and removes
      the warning.
      Done: hunk documented on `cmd_weightb2`; applied, rebuilt,
      `--paff --weightb` encodes warning-free; then restored
      (`git checkout encoder/encoder.c`) and the warning is back.

## 3. Stage 1 — progressive positive control

- [x] 3.1 Run the progressive cells for C1..C5 (C1 at both
      geometries) and record the per-clip
      BD-rate table.  Verify: table committed into the change directory
      as `results-stage1.md` with clip provenance (env-clip paths or
      lavfi fallback, including which C5 variant ran) and the ffmpeg
      version.
- [x] 3.2 Evaluate the stage-1 gate (>= 1 clip with progressive gain
      >= 1.0%).  If FAILED: skip to section 5 (kill path), noting
      "feature dead on all tested content incl. progressive".
      Verify: the gate verdict is recorded in `results-stage1.md`.

## Decision point

Stage-1 gate FAILED: largest progressive gain +0.526% (c4, legacy
synthetic), real-scene crossfade +0.457% (QCIF) / +0.275% (720x576),
grained synthetic -0.339%, dip-to-black -0.288%, control -0.242% — no
clip reached 1.0%.  Per design D2 the PAFF measurement is moot:
KILL confirmed on all tested content including progressive.  Kill path
(section 5) taken; sections 4 and 6 not executed.

## 4. Stage 2 — PAFF measurement (only if the stage-1 gate passed)

- [x] 4.1 Apply the local validation revert (task 2.3), rebuild, run the
      paff-tff and paff-bff cells for C1..C5.  Verify: no force-off
      warnings in the on-rows' logs (the task-2.2 guard passes).
      **Branch not taken** (stage-1 gate failed; the revert was applied
      and restored only to verify 2.2/2.3).
- [x] 4.2 Record per-clip BD-rate in `results-stage2.md`; check the BFF
      sign-agreement rule and the C1 QCIF-vs-576i sign-agreement rule
      (disagreement is not averaged: a >= 1.0% gain at 576i with ~0 at
      QCIF is decided by 576i; the reverse means the QCIF gain was
      noise -> KILL by the primary cell).  Verify: verdict per the
      pre-registered thresholds (primary — the largest stage-1 gain
      among C1/C3/C4 only — >= 1.0% AND |C5| <= 0.5% -> ENABLE /
      <= 0.5% -> KILL / middle -> extended sweep CRF 15/20/25/30/35 at
      200 frames, extended >= 1.0% -> ENABLE otherwise KILL) is
      recorded.
      **Branch not taken** (no stage 2; no results-stage2.md exists).
- [x] 4.3 Divergence check: if the primary clip gained in progressive
      but not in PAFF, verify the field weight path first
      (spot-check derived weights against `bipred_weight_buf` on the
      failing MBs per the archived paff-weightb debug procedure) before
      accepting a KILL verdict.  Note: the archived procedure uses a
      temporary instrumented build (debug counter / weight dump in
      `x264_macroblock_bipred_init_paff`, never committed) — budget for
      building it again.  Verify: the check outcome is recorded
      in `results-stage2.md`.
      **Branch not taken** (no PAFF/progressive divergence to explain:
      progressive itself gained nothing).

## 5. Kill path

- [x] 5.1 Rewrite the weighted-biprediction paragraph in `doc/paff.txt`:
      the synthetic-dissolve numbers AND the new real-content numbers
      with the positive-control result; update the `weightb` glossary
      entry in CONTEXT.md with the new rationale in the same commit as
      the verdict.  Verify: the paragraph cites
      both measurements and the force-off stays in place.
- [x] 5.2 Finalize the delta spec with the KILL variant (remove the
      ENABLE variant and the OUTCOME-PENDING header).  Verify:
      `openspec validate paff-weightb-remeasure` passes.

## 6. Enable path (only on an ENABLE verdict)

- [x] 6.1 Re-apply the conformance fix bundle reverted by paff-weightb
      (design D3): widen `bipred_weight_buf` beyond `int8_t` (boundary
      weight 128) and fix the signed-byte-multiply `pixel_avg` asm
      extrema (-64/128: x86 SSSE3/AVX2/AVX-512, LoongArch LSX/LASX);
      run `checkasm8` for every function touched; re-run the
      instrumented gate-sensitivity proof (temporary build, debug
      counter in `x264_macroblock_bipred_init_paff`: the matrix must
      exercise weights != 32 including the [-64, 128] neighbourhood).
      Verify: checkasm clean on every arch touched; the sensitivity
      evidence is recorded in `results-stage2.md`.
      **Branch not taken** (verdict is KILL).
- [x] 6.2 Remove the force-off warning-and-disable in
      `x264_encoder_open` permanently.  Verify: `--paff --weightb`
      encodes warning-free; `--paff` defaults keep weightb per preset.
      **Branch not taken** (verdict is KILL; force-off stays).
- [x] 6.3 Re-run the full B-field JM conformance matrix with weightb on
      (test_paff.sh weightb matrix cells).  Verify: all cells bit-exact
      vs `--dump-yuv`.
      **Branch not taken** (verdict is KILL).
- [x] 6.4 Rewrite the weighted-biprediction paragraph in `doc/paff.txt`
      (supported; numbers recorded), update the `weightb` glossary
      entry in CONTEXT.md in the same commit as the verdict, and
      finalize the delta spec with the ENABLE variant.  Verify:
      `openspec validate paff-weightb-remeasure` passes.
      **Branch not taken** (verdict is KILL; 5.1/5.2 executed instead).

## 7. Wrap-up

- [x] 7.1 Non-PAFF regression: progressive and MBAFF outputs bit-identical
      pre/post (the validation block is the only code change, gated on
      `param.b_paff`).  Verify: checksum comparison on a short matrix.
      Done: the change touches no encoder code at all
      (`git diff -- '*.c' '*.h' '*.asm' '*.S'` is empty — pre/post
      identity holds vacuously); byte-repeat runs of a short
      progressive/MBAFF matrix (CRF 20/28, TFF/BFF) are identical.
      JM was unavailable on this machine, so the pixel-level
      baseline-check could not run — moot given the empty code diff.
- [x] 7.2 Finalize `results-stage*.md`, prune the delta spec to the
      surviving variant, update AGENTS.md only if the enable path
      changes documented behavior.  Verify: `openspec validate` clean;
      small commits per upstream style.
      Done: results-stage1.md finalized (no stage-2 file — the stage
      never ran); the delta spec carries the KILL variant; AGENTS.md
      unchanged (no behavior change — the force-off stays).
