# Design: PAFF — motion-vector limits in field units

## Context

See proposal.md — Why.  The relevant as-built facts (verified in code):

- `sps->i_mb_height` is the **frame** MB height (`encoder/set.c:107`); the SPS
  signals `i_mb_height >> 1` as `pic_height_in_map_units` for PAFF.
- A PAFF coding pass iterates **frame MB rows with step 2**
  (`encoder/encoder.c:3170`), so `h->mb.i_mb_y` is a frame-row index and the
  field row is `i_mb_y >> 1` (same parity for the whole pass).
- Vertical limits are computed in the **progressive** branch of
  `x264_mb_analyse_init` (`encoder/analyse.c:433-440`) because
  `PARAM_INTERLACED` is MBAFF-only (`common/common.h:74`); PAFF is covered
  only by `PARAM_FIELDCODE` (`common/common.h:82`).
- `i_mv_range` is halved for PAFF via `PARAM_FIELDCODE`
  (`encoder/encoder.c:1321-1323`) — the level table value (256–512 px for
  levels 2.1–5.2, `common/tables.c`) becomes 128–256 px, and
  `i_fmv_range = 4 * i_mv_range` clamps the spel limits
  (`analyse.c:437`).  The halving is normatively exact: Annex A (A.3.1
  item k) bounds the vertical MV component range "in units of luma
  **frame** samples", and one field line of displacement spans two frame
  samples, so the field-unit limit is half the table value.
- Consequence: at levels ≤ 5.2 the level clamp (128–256 px) is tighter than
  even the field border of SD content, so the frame-geometry defect is
  **inert at default settings** — it binds only at level 6.x or with an
  explicit large `--mvrange` (and on HD+ material).  The lookahead defect
  (halved `2 * i_mv_range`, `slicetype.c:550`) bites at **every** level.
- The frame-thread wait thresholds and the `i_mv_range_thread` clamp are
  already in field lines (`analyse.c:378-397`, `encoder.c:1386`).
- The **horizontal** spel clamp shares the halved value: `mv_min/max_spel[0]`
  are clamped to `±i_fmv_range` (`analyse.c:357-358`), so under PAFF the
  horizontal search range is half of what progressive gets at the same
  level.  Horizontally a field sample is a frame sample, so the halving is
  not normatively required there; it is pre-existing over-strictness.  It
  is internally consistent (the VUI horizontal signal is computed from the
  same value, `set.c:263`, and the cost tables are sized accordingly).
  Un-halving it is out of scope — see D4.

## Goals / Non-Goals

**Goals:**

- Vertical MV limits of the coding passes sized by field geometry.
- Lookahead lowres vertical range equal to what progressive encoding gets
  for the same content.
- A documented unit verdict for every other `i_mv_range` consumer.
- Non-PAFF output bit-identical; PAFF conformance matrix re-baselined.

**Non-Goals:**

- Changing the `i_mv_range` halving itself (it is the spec-correct level
  semantic per field picture and feeds VUI signaling).
- Touching MBAFF behavior, including the same halved-lookahead-range quirk
  upstream MBAFF has (non-PAFF bit-identity forbids it).
- Anything in the proposal's non-goal list (first-field row readiness,
  weightb, mbtree per-field propagation, sliced threads, AVC-Intra).

## Decisions

### D1: Field geometry in the progressive limit branch, gated on `b_paff`

In `x264_mb_analyse_init`, under `h->param.b_paff` compute the vertical
limits from the field grid.  Done **in place** in the progressive branch
(no new branch): `mb_y = h->mb.i_mb_y >> h->param.b_paff` and a local
`mb_height = h->mb.i_mb_height >> h->param.b_paff`, used as:

    mv_min[1] = 4*( -16*mb_y - 24 );
    mv_max[1] = 4*( 16*( mb_height - mb_y - 1 ) + 24 );

(MBAFF never reaches this branch — `PARAM_INTERLACED` takes the 3-row
path above — so gating on `b_paff` alone is exact, and for progressive
`b_paff == 0` the shifts are identity, making non-PAFF bit-identity
visible from the diff itself.  The threading block above keeps its own
PAFF `pix_y` and is untouched.)

Everything derived (`mv_min/max_spel[1]`, `mv_limit_fpel`, the
`X264_MIN3` with `4*thread_mvy_range`) then works in field qpel on both
sides of every comparison — the thread clamp is already field-line based,
so no conversion factors anywhere.

Alternatives considered:

- **Reuse the MBAFF 3-row machinery** (`mv_miny_row[3]` etc.): rejected.
  Those arrays exist because MBAFF mixes frame and field macroblock pairs
  in one picture; a PAFF picture is uniformly-field, one pair of limits
  per row is sufficient, and dragging `PARAM_INTERLACED` paths into PAFF
  re-opens MBAFF-only corner cases.
- **Halve `i_mb_height` for PAFF passes globally**: rejected.  Far too
  invasive — `i_mb_height` drives slice loops, border setup, threading
  and rate control, all of which currently think in frame rows with
  parity steps.

### D2: Undo the range halving for the lookahead only, gated on `b_paff`

`slicetype.c:550`: `mv_range = 2 * i_mv_range` becomes frame-unit under
PAFF (shift back by one, or equivalently use the unhalved level value).
The lookahead's lowres planes are full frames and consecutive lookahead
entries are one input-frame period apart — exactly progressive's
geometry and temporal distance — so progressive's range is the correct
one.

Alternative: leave it, matching upstream MBAFF's halved lookahead range.
Rejected: for MBAFF the halving is the same latent defect, but fixing it
would change MBAFF bitstreams (bit-identity constraint); PAFF has no such
constraint and targets precisely the high-vertical-motion interlaced
content where a halved range misleads scenecut/mbtree.

Verification: the parity-with-progressive scenario is not observable in
the bitstream, so the computed lowres `mv_range` gets a permanent
`x264_log( X264_LOG_DEBUG, ... )` and `tools/test_paff.sh` compares the
logged value between a PAFF and a progressive run of the same clip.

### D3: Keep the single halved `i_mv_range`; rescale locally at frame-based consumers

Rather than storing two range values (frame + field), keep the halved
`i_mv_range` as *the* coding-pass value and rescale at the one frame-based
consumer (lookahead, D2).  Less state, no new invariants.

### D4: Audit verdicts for the remaining consumers (no code change expected)

Final verdicts after implementation (task 3 of tasks.md) confirmed all
of the below; two sharpened facts are recorded at the end of this
section.

- **MV cost tables** (`analyse.c:148,181,206`, `init_costs`): sized by
  `i_mv_range << PARAM_INTERLACED` = the halved value under PAFF.  MVs are
  clamped to `i_fmv_range = 4 * i_mv_range` (the MIN3 keeps that term), so
  the max |mv − mvp| delta is exactly covered by the table half-size
  `2*4*mv_range`.  Consistent — **no change**; the clamp term must not be
  dropped when touching the MIN3 in D1.
- **VUI `log2_max_mv_length_vertical`** (`set.c:264`): computed from the
  halved value.  E.2.1 defines the signal as the MV component range "in ¼
  luma sample units, for all pictures in the coded video sequence"; in an
  all-field sequence every picture is a field, so per-picture (field)
  sample units are exactly what a decoder observes, and signaling the
  field-unit range is correct — **no change**; after D1 the actual maximum
  only gets smaller (field border ≤ frame border).
- **Horizontal spel clamp** (`analyse.c:357-358`): shares the halved
  `i_fmv_range` (see Context).  Over-strict but consistent with the VUI
  horizontal signal and the cost-table sizing; un-halving would change
  PAFF bitstreams and force a VUI / cost-table revisit — **no change**,
  deliberate non-goal, one sentence in `doc/paff.txt`.
- **Level `CHECK("MV range")`** (`set.c:954`): validates the halved value
  against the table — strictly more lenient, never a false rejection —
  **no change**.
- **Predictor clipping** (`common/macroblock.c:41-42` etc.): consumes
  `mv_min/max`, inherits D1 automatically — **no change**; verified that no
  other site recomputes vertical geometry from `i_mb_height`: the
  frame.c border/hpel code is field-aware (`b_fld = SLICE_MBAFF ||
  FIELD_PIC`, per-parity edges), slicetype.c:579's lowres y-limit uses the
  frame grid (correct for the frame-based lookahead, especially with D2's
  frame-unit range), mbtree propagation clamps to the frame lowres grid,
  and the OpenCL lookahead derives its window from `i_me_range` (never
  halved).

Sharpened facts found during implementation/testing:

- **D1 is not bit-inert at default range in general.**  The unclamped
  `mv_min/max[1]` (which bound derived MVs: P skip at macroblock.c:41-42,
  temporal B direct at :80-81) change under D1 whenever a derived MV would
  cross the field border, so temporal-direct B configs and HD clips change
  at default levels too (ME limits remain clamp-bounded and unchanged
  there).  Measured quality effect of D1 alone: <= 0.009 dB PSNR-Y
  (neutral).  The risk bullet's "free check" therefore holds only for
  configs whose derived MVs never cross the field border (e.g. the 176x144
  P-only and spatial-direct test configs).
- **The old limits were not memory-safe at extreme search ranges.**  The
  frame-grid geometry exceeds the field planes + padding by up to a field
  height; with a wide search (`--me umh --merange 64`, 1080 lines) the
  pre-change build segfaulted once (unreproducible in retries) — reads can
  cross the allocation.  D1 removes the mechanism (all vertical reads are
  within field plane + emulated edge by construction).
- **Lowres cost-table coverage after D2**: lowres |mv| <= 2*unhalved range
  − 1 and mvp is the median of MVs already clamped to the same window, so
  max |mv − mvp| <= 8H−1 = half-size 8H − 1 (H = halved i_mv_range) — the
  lookahead reuses the coding-pass table with the coverage the
  "4 qpel / 2 sign / 2 opposite-mvp" sizing argument promises, by exactly
  one table element.

## Risks / Trade-offs

- [D1 is inert at default levels (≤ 5.2) — the standard matrix would
  "re-baseline" a no-op and prove nothing] → Add a wide-range
  configuration to the test matrix so the new limits are actually
  exercised; verify with a debug build that search candidates no longer
  cross the field border.  The trigger threshold is exact: at 1080 rows
  the field-border geometry limit is `16*(34-1)+24 = 552` field lines, so
  `--mvrange` must exceed 552 (`--mvrange 512` at 1080 would be a
  bit-identical no-op); use `--mvrange 1024` at 1080 rows, or
  `--mvrange 512` at 720 rows (border ~376).  Run it with `--threads 1`
  (else `i_mv_range_thread` can mask the geometry term) and leave the
  level auto / ≥ 6.1 (a pinned low level fails validation against the
  level table).
- [D2 may shift mbtree QP offsets and scenecuts on many clips, turning the
  re-baseline into a large diff] → Expected and acceptable (PAFF has no
  bit-identity constraint vs itself).  Acceptance bar, fixed up front: PSNR-Y/SSIM within ±0.05 dB at
  comparable bitrate and bitrate within ±1% at the same QP/CRF vs the old
  baseline.  The investigation trigger is **symmetric** on default-range
  clips: |ΔPSNR-Y| > 0.1 dB or |Δbitrate| > 2% in *either* direction needs
  a recorded explanation (a large unexpected gain can mean the search
  stopped going somewhere — a bug, not a win); on the wide-range clip an
  improvement is the goal of the change and only regressions trigger.
  Anything triggering is investigated (rr methodology, synthetic clip,
  three-build attribution) rather than silently re-baselined.  A
  regression is accepted as mere lookahead-retraining sensitivity only if
  the three-build attribution shows it present in the D1+D2 build and
  **absent in the D1-only build** on the same clip (i.e. caused by D2);
  a regression attributable to D1 is never accepted — D1 is pure geometry
  and must be inert at default ranges, which also gives a free check: the
  D1-only build must be bit-identical to pre-change on default-range
  clips.  Attribution: build three binaries
  (pre-change / D1-only / D1+D2) and run them on the wide-range clip and
  2–3 regular clips, so a regression is attributable to D1 or D2 without
  re-running the full matrix.
- [Sign/parity mistakes for the bottom field (odd `i_mb_y`) — the top
  border direction is the one that changes most] → Test with a synthetic
  clip of large vertical motion in both directions, TFF and BFF, JM
  round-trip + visual/dump comparison.
- [Fixed-N determinism regression from touching the analyse hot path] →
  Re-run the fixed-thread-count determinism check from the
  paff-frame-threads change (N=1 and N>1, repeated runs byte-identical).
- [An unnoticed fourth consumer of frame geometry] → The D4 audit is a
  required task, not optional; any consumer found to recompute geometry is
  fixed in the same change.

## Migration Plan

1. Implement D1 + D2 behind `b_paff` gates (no behavior change for
   non-PAFF by construction); the two decisions may land as separate
   commits, but the matrix is run once on the final state.
2. Build the three attribution binaries (pre-change / D1-only / D1+D2)
   and collect per-build numbers on the wide-range clip and 2–3 regular
   clips.
3. Run the full PAFF matrix incl. the new wide-range config; JM
   round-trip; re-baseline the changed streams subject to the acceptance
   bar above (±0.05 dB PSNR-Y/SSIM, ±1% bitrate, symmetric investigation
   trigger, D2-only attribution rule for accepted regressions).
4. Record before/after bitrate, encode-time and per-build attribution
   numbers in `doc/paff.txt`; remove the known-issue paragraph; add the
   `--mvrange`-in-field-lines note.
5. Rollback: revert the commit; baselines are kept in the test scripts, so
   reverting restores the previous expected outputs.

## Open Questions

(none)
