# Proposal: threaded-vbv-determinism (FUTURE / parked)

Status: **parked finding** — recorded 2026-08-17 from the `paff-pass-threads`
implementation session. Not scheduled. This file is the full record of the
investigation so the future fix does not have to rediscover it.

## Why

`doc/threads.txt` promises "output is deterministic at a fixed thread count".
With VBV enabled this is not true on current upstream (verified at commit
`0480cb05`, pre-PAFF) nor on this tree: repeat runs of the same encode at the
same thread count diverge.

Reproducer (upstream worktree binary behaves identically to this tree):

```sh
# 176x144, t8, CBR+VBV: ~half the runs differ (10 runs -> 3-8 distinct .264)
for i in $(seq 1 10); do
  x264 clip.yuv --input-res 176x144 --frames 25 --threads 8 --bframes 0 \
      --bitrate 300 --vbv-maxrate 300 --vbv-bufsize 300 -o run_$i.264
done
md5sum run_*.264
```

Also reproduces at 720p (5 runs -> 5 distinct), at t2/t4, and under `--paff`.
CRF, CQP, and ABR-without-VBV are always deterministic. First divergence in
the observed case: frame 14 (scenecut I-frame) gets a different QP;
everything downstream follows.

## Root cause (confirmed by patch experiments)

Threaded VBV decisions read timing-dependent state in three places in
`encoder/ratecontrol.c`:

1. **Dispatch-time, dominant**: `update_vbv_plan` (~line 2301) and
   `rate_estimate_qscale` (~line 2561) read `t->rc->frame_size_estimated` of
   other, still-in-flight frame-thread slots (`X264_MAX(frame_size_planned,
   frame_size_estimated)`). The field is `volatile float` and is updated
   per-row by pool workers in `x264_ratecontrol_mb`, so the value the caller
   sees depends on how far the worker has progressed.
2. **Row-level**: `x264_ratecontrol_mb` reads `h->fref[0][0]->f_row_qp[y]`
   (~line 1617); the reference frame may not have coded row `y` yet when the
   MV-range margin is small (small frames / small `--mvrange-thread`).
3. **Row-level**: `predict_row_size` reads `h->fref[0][0]->f_row_qscale[y]`
   and `h->fref[0][0]->i_row_bits[y]` (~line 1546-1557), and
   `predict_row_size_to_end` does so for *future* rows that no wait ever
   covers.

A worktree patch (`/tmp/x264-upstream`, git-diffable) that bypasses all three
reads under `i_thread_frames > 1` produced 12/12 byte-identical t8 CBR runs;
each single-read patch alone was insufficient (the dispatch-time read
dominates: 9/10).

`bits_so_far` (also `volatile`) is only read on the sliced-threads path and
is not implicated here.

## What changes (sketch)

- Dispatch-time VBV planning uses only deterministic state: e.g. drop the
  `X264_MAX(..., frame_size_estimated)` refinement for in-flight slots (use
  `frame_size_planned`), or snapshot the estimate at harvest.
- Row-level predictor reads are gated to reference rows provably complete:
  in deterministic mode the wait guarantee is itself deterministic
  (`pix_y + i_mv_range_thread`), so the fallback branch (no reference
  predictor) can be chosen on a deterministic condition.
- Gates: byte-identical repeat runs at N=2/4/8/16 with CBR+VBV (small and
  realistic clips); quality/bitrate regression vs current threaded CBR
  measured (the reads exist to improve VBV prediction accuracy); t1 output
  must stay byte-identical.
- Upstreamable: reproduce on clean upstream, propose with measurements.

## Impact

- `encoder/ratecontrol.c` only, all paths gated on `i_thread_frames > 1`.
- Changes threaded CBR output bytes (they are nondeterministic today, so no
  stable baseline is lost); t1 byte-identity is the regression gate.
- Unblocks strict fixed-N byte-repeat gates for CBR+VBV configs in
  `paff-pass-threads` (tasks 5.1/6.1) and makes the maintainer's CBR+VBV
  broadcast use case deterministic.
