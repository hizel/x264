# Tasks: PAFF — motion-vector limits in field units

Spec: `specs/paff-encoding/spec.md` (Requirement: Motion-vector limit units
under PAFF).  Design: `design.md` (D1–D4).

## 1. Coding-pass limits (D1)

- [x] 1.1 In `x264_mb_analyse_init` (`encoder/analyse.c`, progressive
      y-limit branch) compute the vertical limits from the field grid under
      `h->param.b_paff`, in place (no new branch):
      `mb_y = h->mb.i_mb_y >> h->param.b_paff` and a local
      `mb_height = h->mb.i_mb_height >> h->param.b_paff`; keep the single
      copy of the `X264_MIN3(..., i_fmv_range-1, 4*thread_mvy_range)`
      clamp terms intact (all terms are field qpel after this change);
      do not touch the threading block above (it has its own PAFF `pix_y`)
- [x] 1.2 Verify both parities: field-row mapping `i_mb_y >> 1` is correct
      for odd (bottom-field) rows; top-border direction for the bottom
      field is the risky one — trace it by hand and note the expected
      values in the commit message or code comment
- [x] 1.3 Confirm `checkasm8`/`checkasm10` pass (no DSP changes expected,
      but the analyse hot path was touched)

## 2. Lookahead range (D2)

- [x] 2.1 In `encoder/slicetype.c` (`mv_range = 2 * i_mv_range`) undo the
      `PARAM_FIELDCODE` halving under `h->param.b_paff` so the lookahead
      lowres range matches progressive in frame units; MBAFF path unchanged
- [x] 2.2 Sanity-check that no other lookahead/slicetype site derives a
      vertical limit from the halved `i_mv_range` (grep audit of
      slicetype.c/lookahead.c)
- [x] 2.3 Add a permanent, unconditional (not gated on `b_paff`)
      `x264_log( X264_LOG_DEBUG, ... )` of the computed lookahead lowres
      `mv_range` at encoder open (`x264_lookahead_init`, single-threaded,
      before any analysis thread exists), and a step in
      `tools/test_paff.sh` that encodes the same clip with and without
      `--paff` and compares the logged values (the spec scenario
      "Lookahead range parity with progressive" is observable only this
      way, not via the bitstream)

## 3. Unit-consistency audit (D4)

- [x] 3.1 Cost tables (`init_costs`, `x264_analyse_init_costs`,
      `x264_analyse_free_costs`): confirm table half-size covers the max
      |mv − mvp| under the field-geometry limits; record the verdict in
      design.md if it differs from D4
- [x] 3.2 VUI `log2_max_mv_length_vertical` and level `CHECK("MV range")`
      (`encoder/set.c`): confirm field-unit signaling is correct and the
      check stays non-rejecting; record verdicts
- [x] 3.3 Predictor clipping (`common/macroblock.c`) and any other site
      recomputing vertical geometry from `i_mb_height`: confirm they
      consume `mv_min/max` (inherit the fix) or fix them in place

## 4. Tests and re-baseline

- [x] 4.1 Add a wide-range configuration to the PAFF test matrix
      (`tools/test_paff.sh`): 1080-line content with explicit
      `--mvrange 1024`, TFF and BFF, `--threads 1` (a larger thread count
      would let `i_mv_range_thread` mask the geometry fix), level left
      auto or >= 6.1 (a pinned low level fails validation against the
      level table).  D1 binds only when `--mvrange` exceeds the field
      border geometry limit (552 field lines at 1080 rows), so
      `--mvrange 512` at 1080 would be a no-op; optionally duplicate with
      720-line content at `--mvrange 512` (field border ~376 there)
- [x] 4.1a For attribution of effects, build three binaries
      (pre-change / D1-only / D1+D2) and run them on the wide-range clip
      plus 2-3 regular clips; record per-build bitrate/PSNR/SSIM so a
      regression can be attributed to D1 or D2 without re-running the
      full matrix
- [x] 4.2 Synthetic vertical-motion clip test: large motion in both
      directions, TFF + BFF, JM round-trip bit-exact vs `--dump-yuv`
- [x] 4.3 Run the full conformance matrix (CRF/2-pass/CBR × TFF/BFF ×
      I/P/B): JM bit-exactness preserved; re-baseline the streams that
      changed; record before/after bitrate and encode-time
- [x] 4.4 Non-PAFF regression: progressive and MBAFF outputs bit-identical
      to the pre-change build across the baseline matrix
- [x] 4.5 Fixed-N determinism re-check (per the paff-frame-threads
      contract): repeated runs at N=1 and N>1 byte-identical
- [x] 4.6 Quality spot check on every changed stream before accepting the
      new baseline: PSNR-Y/SSIM within +/-0.05 dB at comparable bitrate
      and bitrate within +/-1% at the same QP/CRF vs the old baseline.
      Investigation trigger is symmetric on default-range clips:
      |dPSNR-Y| > 0.1 dB or |dbitrate| > 2% in either direction needs a
      recorded explanation (a large unexpected gain can mean the search
      stopped going somewhere); on the wide-range clip an improvement is
      the goal, only regressions trigger.  Anything triggering is NOT
      re-baselined silently: investigate first (rr methodology from
      paff-frame-threads, the synthetic clip from 4.2, the three-build
      attribution from 4.1a).  A regression is accepted as mere
      lookahead-retraining sensitivity only if the attribution shows it
      present in the D1+D2 build and absent in the D1-only build on the
      same clip; a D1-attributable regression is never accepted.  Free
      check: the D1-only build must be bit-identical to pre-change on
      default-range clips.  Accepted conclusions are recorded with clip,
      metrics and attribution in `doc/paff.txt`

## 5. Docs and cleanup

- [x] 5.1 Remove the field-unit-MV-limits bullet from the "Future work"
      section of `doc/paff.txt`; add the measured before/after numbers
      (incl. the per-build attribution from 4.1a); add one sentence
      noting that an explicit `--mvrange` is in field lines under PAFF
      while the level-derived default is the halved table value, and one
      sentence noting the horizontal clamp shares the halved value
      (pre-existing, out of scope).  Add the same field-lines note to the
      `--mvrange` entry of `--longhelp` in `x264.c`
- [x] 5.2 `CONTEXT.md`: glossary entries `field line`, `field units (MV)`
      and `emulated edge` were added during design review; re-check the
      wording against the final implementation
- [x] 5.3 Update design.md D4 with the final audit verdicts from task 3
      if any differed
