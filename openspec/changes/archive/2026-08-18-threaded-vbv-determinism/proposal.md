# Proposal: threaded-vbv-determinism

Status: **ready for implementation**.  Un-parked 2026-08-18.  The root-cause
investigation record from the parked revision is preserved in the "Root
cause" section (nothing was re-derived; site E was added).

## Why

`doc/threads.txt` promises "output is deterministic at a fixed thread
count".  With VBV enabled this is not true on current upstream (verified at
commit `0480cb05`) nor on this tree: repeat runs of the same encode at the
same thread count diverge.

Reproducer:

```sh
# 176x144, t8, CBR+VBV: ~half the runs differ (10 runs -> 3-8 distinct .264)
for i in $(seq 1 10); do
  x264 clip.yuv --input-res 176x144 --frames 25 --threads 8 --bframes 0 \
      --bitrate 300 --vbv-maxrate 300 --vbv-bufsize 300 -o run_$i.264
done
md5sum run_*.264
```

Also reproduces at 720p, at t2/t4, and under `--paff`.  CRF, CQP, and
ABR-without-VBV are always deterministic.  First divergence in the observed
case: a scenecut I-frame gets a different QP; everything downstream follows.

The maintainer's CBR+VBV broadcast use case needs byte-repeatable runs;
today only non-VBV rate control can offer that.

## Root cause (confirmed by patch experiments)

Threaded VBV decisions read timing-dependent state in `encoder/ratecontrol.c`:

| site | location | read | row read relative to the coding row |
|------|----------|------|-------------------------------------|
| A | `update_vbv_plan` (~2301) | in-flight slots' `frame_size_estimated` (volatile, updated per row by workers) via `X264_MAX(frame_size_planned, ...)` | dispatch-time |
| B | `rate_estimate_qscale` (~2561) | same expression | dispatch-time |
| C | `predict_row_size` (~1549), via `predict_row_size_to_end` | `fref[0][0]` row stats (`f_row_qscale`, `i_row_bits`, `i_row_satd`) | future rows (y+1..end) |
| D | `x264_ratecontrol_mb` (~1615), `row_pred[1]` update | `fref[0][0]->f_row_qp[y]` | current row |
| E | `x264_ratecontrol_mb` (~1661), B-frame `qp_min` clamp | `f_row_qp[y+1]` of `fref[0][0]` AND `fref[1][0]` | future row |
| F | `row_bits_so_far`, via `x264_ratecontrol_mb` (PAFF only) | the pair's SHARED `fdec->i_row_bits[]` across both parities -- the sibling pass's rows are live writes while both pass jobs are in flight | sibling pass's in-flight rows |
| G | `x264_ratecontrol_mb` (~1696), `rc->qpm > fdec->f_row_qp[0]` (PAFF only) | pass 1 reads row 0 of the shared pair frame, written live by pass 0's worker | sibling pass's first row |

Sites F/G were found on 2026-08-18 during implementation (task 4.2):
the parked experiment predates pass-granular PAFF threading, so its site
list has no PAFF-shared-array entries.  Both are reads of the pair frame's
row arrays from the wrong pass; neither has an upstream counterpart.

Sites A–D were found in the parked investigation: a worktree patch
(`/tmp/x264-upstream`, git-diffable) bypassing A+B+C+D produced 12/12
byte-identical t8 CBR runs; each single-site patch alone was insufficient
(the dispatch-time read dominates: 9/10).  NOTE: the 12/12 result was
measured with site D DISABLED; the design's "keep D behind a committed
check" configuration has zero experimental coverage and is validated only by
the task-4 byte-repeat checks.  Site E was found on 2026-08-18
during spec review: it reads a FUTURE row of both references and was not
covered by the experiment (its reproducer used `--bframes 0`), so B-frame
CBR+VBV may stay nondeterministic until E is guarded too.

Key structural facts (verified in code):

- All row-level sites (C/D/E) run only under `rc->b_vbv`
  (`x264_ratecontrol_mb` returns early otherwise), and without VBV
  `frame_size_estimated` always equals `frame_size_planned` (workers never
  update it), so removing the `X264_MAX` refinement is a byte-no-op for
  CRF/CQP/ABR-no-VBV — provable, not just measured.
- `bits_so_far` (also volatile) is read only on the sliced-threads path and
  is out of scope (see below).
- The frame-thread row wait in `mb_analyse_init`
  (`x264_frame_cond_wait(fref, y*16 + i_mv_range_thread)`) runs in both
  deterministic and `--non-deterministic` modes; only the MV-range clamp
  differs.  "Reference row i's stats are committed" is therefore a deterministic
function
  of `(i, coding row, i_mv_range_thread)`, so row-level reads can be
  guarded
  on a deterministic completeness condition.

## What changes

- **Dispatch-time (A, B)**: drop the `X264_MAX(frame_size_planned,
  frame_size_estimated)` refinement for in-flight slots; planning uses the
  predicted size only.  No deterministic alternative exists (any live
  progress value is timing-dependent); this moves threaded planning closer
  to the t1 behaviour, which never sees in-flight slots.
- **Row-level (C, D, E)**: guard each reference-row read on a deterministic
  completeness condition derived from the row-wait guarantee, with one row
  of safety margin; when the row is not provably committed, take the existing
  no-reference fallback branch.  With default settings (mvrange-thread 24)
  this keeps site D's read (current row is covered) while C/E fall back —
  better prediction retention than a blanket skip, at the cost of deriving
  the coverage inequality per coding mode (progressive frame lines / MBAFF
  pair rows / PAFF field lines).  If quality/bitrate measurements show no
  difference vs a blanket skip, simplify to the blanket skip.
- **Pair-shared row arrays (F, G; PAFF only)**: under frame threading the
  pair's two passes run as concurrent pool jobs on one shared fdec, so a
  pass may only read row-array entries of its own parity (its own writes).
  `row_bits_so_far` sums only the pass's parity rows; the `f_row_qp[0]`
  clamp reads the pass's own first coded row (`i_threadslice_start`).
  Both keep the t1 code path byte-identical (gated on
  `i_thread_frames > 1`): at t1 the sibling field is final when read.
- All checks are `i_thread_frames > 1` only; `--non-deterministic` takes the
  same path (one code path, matching the verified experiment).
- `doc/threads.txt` updated: the fixed-thread-count determinism promise
  becomes true for VBV configs.

## Out of scope

- Slice-based threading determinism (the volatile `bits_so_far` /
  `frame_size_estimated` reads there are a different, harder problem; PAFF
  rejects sliced threads anyway).
- Making threaded output byte-identical to `--threads 1` (the MV-range
  clamp alone forbids it, as in progressive).
- VBV algorithm accuracy improvements beyond restoring determinism.

## Impact

- `encoder/ratecontrol.c` only (plus docs/tests).
- Threaded CBR+VBV output bytes change (they are nondeterministic today, so
  no stable baseline is lost); t1 byte-identity is the regression check.
- Quality/bitrate impact of the dropped refinement and the row-level checks
  must be measured (the reads exist to improve VBV prediction accuracy);
  acceptance requires no new VBV under/overflow and regression within
  measurement noise or explicitly documented.
- Unblocks strict fixed-N byte-repeat checks for CBR+VBV configs and makes
  the maintainer's CBR+VBV broadcast use case deterministic.
- Upstreamable: the patch has no PAFF dependencies; reproduce on clean
  upstream (`/tmp/x264-upstream` worktree at `0480cb05`) and propose with
  measurements.
