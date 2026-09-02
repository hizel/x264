# Design: threaded-vbv-determinism

## Context

x264 promises deterministic output at a fixed thread count
(`doc/threads.txt`).  Frame-threaded encoding with VBV violates the promise:
VBV decisions read live, per-row-updated state of frames still being coded
by other pool workers, so the decision depends on how far those workers have
progressed when the read happens.  The parked investigation (see proposal)
confirmed the mechanism by patching the reads away and obtaining 12/12
byte-identical repeat runs.

This design makes every threaded VBV decision a function of state that is
final at decision time.  Nothing else about the VBV algorithm changes.

## Determinism model

```
            state a VBV decision may read
            ─────────────────────────────
  ALLOWED                         FORBIDDEN (timing-dependent)
  ──────────────────────────────  ───────────────────────────────
  own slot's rc state             in-flight slots' rc fields
  completed frames' final stats   (frame_size_estimated, ...)
  reference rows provably committed   reference rows not covered by the
  under the row-wait guarantee    row-wait guarantee
```

The row-wait guarantee: `mb_analyse_init` waits, for every reference of the
current frame, until that frame's completed-line counter reaches
`pix_y + i_mv_range_thread` (progressive frame lines; field lines per
parity under PAFF; pair rows under MBAFF).  The wait runs in both
deterministic and `--non-deterministic` modes — only the subsequent MV
clamp differs — so "reference row i is final when row y is coded" is a
pure function of `(i, y, i_mv_range_thread, coding mode)`.  Reads guarded on
that function are deterministic at a fixed thread count.

## Per-site decisions

### A/B — dispatch-time planning (update_vbv_plan, rate_estimate_qscale)

Remove the `X264_MAX(frame_size_planned, frame_size_estimated)` refinement
for in-flight slots.

- The live estimate is timing-dependent by construction, so the refinement
  must go.  Implementation finding (2026-08-18): the bare plan charge is
  NOT conformant — the model drifts optimistic exactly when an in-flight
  frame overshoots its plan (a scenecut I-frame can reach 2x plan; row-VBV
  cannot hard-cap it), and a deterministic CPB underflow resulted
  (clip2, bf0, t8).  The pre-change code underflows on the same cell in
  ~1/12 runs (nondeterministic luck); the fix must be deterministic AND
  at least as safe.
- Deterministic replacement (`vbv_inflight_bits`): charge each in-flight
  frame `plan * max(1, I(actual)/I(planned)) + I(max(0, actual-plan))`,
  where the integrators `I(x) = 0.95*I(x) + sample` (steady state 20x the
  mean sample; the factor cancels in the ratio but applies to the additive
  overshoot term, making the margin deliberately conservative) run over
  FINISHED frames at harvest — final
  state, updated serially in coding order.  The one-sided terms cover the
  plan-overshoot of in-flight frames; steady-state cost is small.
- Applied in `update_vbv_plan` only (the buffer model that drives the plan
  clamp and the row caps — the conformance path).  `rate_estimate_qscale`
  keeps the bare plan: padding there did not change outcomes measurably.
- Effect: threaded planning treats in-flight frames as their (error-
  adjusted) prediction, moving the threaded VBV trajectory closer to t1.
  On long content (720p full length) the trajectory matches the baseline
  to 0.000% bitrate / <= 0.07 dB; on short clips (25-64 frames, startup-
  transient dominated) the baseline overshot the target by 11-16% and the
  new trajectory lands on target — a large pre-registered-threshold
  exceedance that is a trajectory CORRECTION (see design.md "Measured
  outcomes").

### C — colocated-row predictor (predict_row_size, via predict_row_size_to_end)

`predict_row_size_to_end(h, y, ...)` predicts rows `i = y+1 .. end` and the
reference branch reads reference row `i`.  Gate the reference-dependent
part (both the `qscale >= f_row_qscale[i]` condition and the `pred_t`
blend) on row `i` being provably committed; otherwise return `pred_s` (the
SATD-only prediction, which reads only the current frame's own row stats).

NOTE: which future rows (if any) are covered at the default
mvrange-thread (24) is to be settled by the task-1.1 derivation; the
earlier "no future row is covered" claim was a rough guess.

### D — row_pred[1] update (x264_ratecontrol_mb)

The `rc->qpm < fref[0][0]->f_row_qp[y]` read covers the CURRENT row, which
is provably committed with default settings (coverage needs
`i_mv_range_thread >= 16`).  Apply the committed check; keep the read in the
common case.  (This is the main quality argument for gating over the
blanket skip, which discards the predictor whenever threaded.)

### E — B-frame qp_min clamp (x264_ratecontrol_mb)

`qp_min = max(qp_min, fref[0][0]->f_row_qp[y+1], fref[1][0]->f_row_qp[y+1])`
reads a FUTURE row of both references; the arrays are zeroed at
`ratecontrol_start`, so an uncoded row silently contributes 0 — the clamp
applies or not depending on worker timing.  Apply the committed check to row
y+1 in BOTH references; fall back to the unclamped `qp_min` otherwise
(maintainer decision 2026-08-18: no deterministic substitute clamp; a
frame-level substitute using `f_qp_avg_rc` is held in reserve if the
task-5 quality matrix shows a regression on B-frame configs).
NOTE: the earlier claim "with default settings the check always falls
back" is PRELIMINARY — a quick estimate suggests rows y+1..y+2 may be
covered at the default mvrange-thread (24); task 1.1's derivation
settles which rows are actually covered per coding mode.

Derivation outcome (task 1.1, 2026-08-18): with the default
i_mv_range_thread (24) the current row (D) and one future row (E) are
provably committed in all three coding modes; deeper future rows (C)
fall back except row y+1.

### F/G — PAFF pair-shared row arrays (found during implementation, 2026-08-18)

Under pass-granular PAFF threading the pair's two passes share ONE fdec
and its row stat arrays, and run as concurrent pool jobs.  Two reads
cross the parity boundary into the sibling pass's live writes:

- F: `row_bits_so_far` sums `fdec->i_row_bits[0..y]` across both
  parities -- the sibling pass's rows are timing-dependent (coded or not,
  reencoded or not).
- G: the `rc->qpm > fdec->f_row_qp[0]` clamp reads row 0, which for a
  bottom-field pass is the sibling pass's first row.

Fix (PAFF-only, gated on `i_thread_frames > 1`; t1 keeps the original
full-pair semantics byte-identically): `row_bits_so_far` sums only the
calling pass's parity rows (step 2 from `i_threadslice_start`), and the
clamp reads the pass's own first coded row (`i_threadslice_start`)
instead of row 0.  This also matches the per-field VBV model better:
each field's row budget is accounted in its own field's bits.  No
upstream counterpart (upstream has no PAFF); the upstreamable diff is
unaffected.

## The committed check

One helper, used by C/D/E, answering "is reference frame `f`'s row `i`
provably committed while the caller codes row `y`":

```
final(i, y)  ⟺  coverage(i) ≤ guarantee(y) − safety_margin
```

- `guarantee(y)` comes from the row wait: `pix_y(y) + i_mv_range_thread`
  in the units of the current coding mode.
- `coverage(i)` is the completion-counter value that implies row `i`'s
  stats are written: the counter trails the deblock by
  `X264_THREAD_HEIGHT`, and row stats are written during the row's coding,
  before the corresponding broadcast; derive the exact value from the
  broadcast sites and add one row of safety margin.  NOTE: row stats are
  REWRITTEN on row reencode, so "committed" means the reencode has
  finished (the coding has moved past the row), not merely "written once".
- Units are per coding mode: progressive = frame lines, MBAFF = MB-pair
  rows, PAFF = field lines of the entry's parity (the PAFF wait is
  `x264_frame_cond_wait_fld`, per-parity).  The progressive/MBAFF
  inequalities are derived against UPSTREAM semantics
  (`/tmp/x264-upstream`, 0480cb05) so the upstreamable part of the helper
  has a proof free of this tree's PAFF modifications; the PAFF branch is
  a local extension.  Deriving the three inequalities
  and proving each against the broadcast semantics is implementation task
  1; the derivations go into code comments at the helper.

## Measured outcomes (implementation, 2026-08-18)

Determinism checks (tools/test_vbv_determinism.sh): all byte-repeat cells
10/10 identical (N in {2,4,8,16}, bf0/bf3, PAFF TFF/BFF, 720p t8); t1 and
non-VBV pre/post byte-identity holds (including PAFF).

Task 5.2 evaluation — blanket skip vs committed check (5 representative
cells, CBR+VBV --nal-hrd cbr): the committed check wins 4 of 5 (largest:
clip2 bf3 t8, +0.87 dB PSNR and +0.013 SSIM at +2.5% bits; blanket wins
only clip2 bf0 t4, +0.42 dB at -2.1% bits).  KEEP the committed check.

Quality matrix (5.1) vs the pre-registered thresholds:
- 720p full length: |dBrErr| 0.000%, |dPSNR| <= 0.071 dB, |dSSIM| <= 0.00005;
  filler +6.7% (bf0 t8) / +27% (bf3 t8) over the baseline median; the two
  bf3 cells trip a PRE-EXISTING check_hrd.py end-of-stream finding
  ("AU 2148: removal time not increasing", byte-identical pre/post — an
  artifact of the last flushing AUs, not attributable to this change).
- Short clips (startup-transient dominated): post lands ON target
  (397-401 kb/s at 400; 372 under --paff) while the baseline median was
  11-16% OVER target (32% over under --paff; t1 overshoots ~8% on the
  same cells), so the raw deltas (|dBrErr| up to
  15%, |dPSNR| up to 2 dB at 13% fewer bits) exceed the thresholds.  The
  PSNR/SSIM drop is commensurate with the bits no longer spent, not with
  less efficient spending.
- Conformance: no CPB under/overflow in any post-change cell; the
  baseline itself violates ~1/12 runs on clip2-bf0-t8 (the cell is
  borderline: every variant's margin at the scenecut AU is only ~1.5% of
  the buffer).
- PAFF note: the plan-error tracker lives on thread[0]->rc, which is a
  pass-1 slot in some round-robin cycles; x264_paff_sync_ratecontrol
  save/restores the tracker fields around its snapshot memcpy for the
  same reason as buffer_fill_final.

Resolution per the spec ("exceedance routes to the blanket-skip evaluation,
or is documented in doc/threads.txt"): the exceedances persist after 5.2
(they stem from the A/B dispatch charge, not the row checks), so they are
documented in doc/threads.txt (task 6.2).

## Alternatives considered

- **Blanket skip of all reference-row reads when threaded** (the
  experiment patch).  Simpler, already verified 12/12 — but discards the
  site-D predictor even when the row is provably committed.  Held as the
  fallback: if measurements show no quality/bitrate difference, simplify.
- **Live reads under `--non-deterministic`** (guard on `b_deterministic`
  too).  Preserves VBV accuracy for users who opted out of determinism,
  but doubles the test surface for a niche flag; rejected.
- **Snapshot the in-flight estimate at a deterministic point.**  Any such
  value still depends on worker progress at the snapshot moment; rejected.
- **Locking / waiting until the needed rows are final.**  Serialises the
  pipeline (the whole point of frame threading is overlapping) and can
  deadlock the pool FIFO; rejected.

## Risks

- **VBV accuracy regression**: planning without the in-flight refinement
  and with fewer row predictions may shift the buffer trajectory.
  Mitigation: acceptance checks require no new under/overflow (filler,
  decoder conformance) and bitrate/PSNR within noise or documented, on a
  clip matrix.
- **Check inequality wrong** (reads a not-yet-committed row believing it
  committed):
  reintroduces nondeterminism.  Mitigation: the byte-repeat check at
  N=2/4/8/16 with B-frames is the exact detector; plus the one-row margin.
  Empirical note (2026-08-18 re-run of the parked experiment): stock
  upstream gives 12/12 DISTINCT outputs; the A+B+C+D bypass gives 12/12
  identical; A+B+C bypass with site D live also gives 12/12 identical
  (byte-equal to A+B+C+D) — but that run is weak evidence for D, because
  with C bypassed `row_pred[1]` (the only consumer of D's read) is never
  consulted.  The real D-coverage test is task 4.1 on the actual
  implementation.
- **PAFF units mistake**: PAFF counters are per-parity field lines; a
  frame-line assumption would be subtly wrong.  Called out in task 1.

## Validation plan

1. Byte-repeat: 10 runs identical, N ∈ {2,4,8,16} on 176x144, CBR+VBV,
   `--bframes 0` AND default `--bframes 3` (site E!); 720p (hall.mp4,
   full length) at t8 only; TFF PAFF included (176x144).
2. Regression: t1 output byte-identical pre/post; CRF/CQP/ABR-no-VBV output
   byte-identical pre/post at t1 and threaded.
3. Quality/compliance: threaded CBR+VBV pre/post — bitrate error vs target,
   PSNR-Y/SSIM, filler bytes, JM/ffmpeg decode clean.
4. Upstream port: apply the final patch to the clean `/tmp/x264-upstream`
   worktree, reproduce the bug there, verify the fix, keep the diff free of
   PAFF dependencies.
