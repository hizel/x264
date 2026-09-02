# Tasks: paff-weightb

## 1. Spike: enable and judge conformance

- [x] 1.1 Remove the warn-and-disable of `analyse.b_weighted_bipred` under
      PAFF in `x264_encoder_open` (keep the surrounding PAFF validation
      block intact); update the stale comment above it.
- [x] 1.2 Extend `tools/paff_matrix.sh` with weightb-on variants of the
      B-field configs (do not multiply the I/P configs).
- [x] 1.3 Run the extended matrix as a JM round-trip (`test_paff.sh
      matrix`).  Gate: every weightb-on B-field stream matches
      `--dump-yuv` byte-for-byte.  On mismatch, diagnose per design D3
      (JM implicit-weight derivation vs `bipred_weight_buf`); small
      provable fix in `x264_macroblock_bipred_init_paff` is in scope,
      otherwise stop and take the kill-switch path (task 4).
- [x] 1.3a Gate sensitivity: with a temporary instrumented build (debug
      counter in `x264_macroblock_bipred_init_paff`, not committed),
      confirm the weightb-on matrix runs actually produce
      `bipred_weight_buf` values != 32 on both sides of 32 (including
      the `[-64, 128]` guard neighbourhood).  The gate does not count as
      passed without this evidence.
- [x] 1.4 Hardware/software decoder cross-check on one weightb-on B-field
      stream (`tools/test_paff_hw.sh` pattern): ffmpeg software decode
      pixel-exact vs `--dump-yuv`, plus hardware decode bit-exact vs
      `--dump-yuv` on NVDEC (`h264_cuvid`) and AMD (VAAPI).  Part of the
      conformance gate; any mismatch triggers D3 diagnosis.

## 2. Regression guards

- [x] 2.1 `test_paff.sh baseline-check`: progressive and MBAFF outputs
      bit-identical to saved baselines (validation change gated on
      `param.b_paff`).
- [x] 2.2 Fixed-N determinism with weightb on under PAFF: encode twice at
      `--threads 1`, `--threads 4`, `--threads 8`, byte-compare per N.
- [x] 2.3 `make checkasm` clean (no DSP changes expected; assert it).

## 3. Quality gate (design D2)

- [x] 3.1 Add a dissolve-clip generator to `tools/test_paff.sh`
      (crossfade of two synthetic 50 fps sources + `tinterlace`,
      mirroring `make_clip`), plus a non-dissolve control.
- [x] 3.2 Add a `weightb` command to `tools/test_paff.sh`: CRF sweep
      (18/23/28/33) on the dissolve clip and the control, PAFF weightb
      on vs off, collect PSNR-Y/bitrate (encoder-reported, as existing
      scripts do), and compute BD-rate (PSNR-Y, piecewise log-linear
      interpolation, Bjøntegaard-style) with an awk helper — no new
      tooling dependency.
- [x] 3.3 Evaluate against the acceptance rule fixed in design D2:
      BD-rate gain >= 1.0% on dissolves → keep; <= 0.5% → kill; in
      between → one extended sweep, then kill by default; control
      regression beyond ±0.5% BD-rate fails the gate.

## 4. Decision point

Outcome: conformance gate PASSED (28/28 JM matrix with weightb on, ffmpeg
sw pixel-exact, NVDEC + AMD VAAPI bit-exact; two latent bugs found and
fixed along the way, reverted with the enable).  Quality gate FAILED:
dissolve BD-rate gain 0.272% (floor 0.5%), control 0.085%, progressive
same-clip control ~0%.  Kill-switch path (4.2) taken.

- [x] 4.1 Both gates pass: keep the lift, remove the kill-switch wording,
      done.  **Branch not taken** (quality gate failed, 4.2 executed).
- [x] 4.2 Either gate fails: reinstate the force-off (permanent now),
      revert the weightb matrix rows from task 1.2 (with the force-off
      they silently duplicate the weightb-off rows), keep the dissolve
      generator and the `weightb` command (they reproduce the recorded
      measurement), and record the failing measurement with numbers in
      `doc/paff.txt` as the reason.

## 5. Docs

- [x] 5.1 `doc/paff.txt`: rewrite the weighted-biprediction sentences in
      "Rate control and VBV"/"Unsupported combinations" and drop the
      weightb Future-work bullet (either outcome: enabled, or disabled
      with the recorded measurement).  `CONTEXT.md`: the weightb glossary
      entry already added; adjust its wording if the outcome is kill.
- [x] 5.2 `AGENTS.md`: no change expected; verify the PAFF summary still
      matches reality.
