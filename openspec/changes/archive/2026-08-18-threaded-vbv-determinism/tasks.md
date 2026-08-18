# Tasks: threaded-vbv-determinism

## 1. Check derivation

- [x] 1.1 Derive the row-committed inequality per coding mode
      (progressive frame lines / MBAFF pair rows / PAFF per-parity field
      lines) from the broadcast semantics (`fdec_filter_row`,
      `paff_filter_row`, completion sentinels) and the wait thresholds in
      `mb_analyse_init`; one row of safety margin; account for row
      reencode (stats are rewritten until the reencode finishes).
      Record the derivation in a code comment at the committed-check
      helper.  The progressive/MBAFF inequalities MUST be derived and
      line-checked against upstream `/tmp/x264-upstream` (0480cb05)
      (maintainer decision 2026-08-18): the upstreamable diff contains
      only that part of the helper, so its proof must not rely on this
      tree's PAFF-modified threading code; the PAFF branch is derived
      here as a local extension.
- [x] 1.2 Implement the committed-check helper (reference frame + row i + current
      coding row y -> provably-committed bool), correct for
      `SLICE_MBAFF`/`FIELD_PIC` index units.

## 2. Dispatch-time sites (A/B)

- [x] 2.1 Remove the `X264_MAX(frame_size_planned, frame_size_estimated)`
      refinement for in-flight slots in `update_vbv_plan` and
      `rate_estimate_qscale`, with a comment explaining the determinism
      requirement.

## 3. Row-level sites (C/D/E)

- [x] 3.1 Guard the reference-dependent part of `predict_row_size` (both the
      `f_row_qscale` condition and the `pred_t` blend) on the committed check;
      fallback is the SATD-only `pred_s`.
- [x] 3.2 Guard the `row_pred[1]` update read of `fref[0][0]->f_row_qp[y]`.
- [x] 3.3 Guard the B-frame `qp_min` clamp read of `f_row_qp[y+1]` (both
      references must have the row provably committed); fallback is the
      unclamped `qp_min`.
- [x] 3.4 (found during implementation, 2026-08-18) PAFF pair-shared row
      arrays: `row_bits_so_far` sums only the calling pass's parity rows
      and the `f_row_qp[0]` clamp reads the pass's own first coded row,
      both gated on `i_thread_frames > 1` (t1 byte-identical).  Sites
      F/G in design.md.

## 4. Determinism checks

- [x] 4.0 New harness `tools/test_vbv_determinism.sh` (maintainer decision
      2026-08-18): builds the pre-change baseline binary itself from a git
      worktree at a given ref (default: HEAD at first run, cached); clips
      are external paths via env vars, missing clip = cell skipped with a
      note; byte-repeat checks run by default, the task-5 quality matrix
      runs behind `--quality`.
- [x] 4.1 Byte-repeat: 10 identical runs, N ∈ {2,4,8,16}, CBR+VBV, 176x144,
      `--bframes 0` and default `--bframes 3` (site E coverage);
      720p (hall.mp4, full length) at t8 only.
- [x] 4.2 Same checks under `--paff --tff` (and BFF spot-check), 176x144.
- [x] 4.3 t1 byte-identity pre/post (CBR+VBV).
- [x] 4.4 Non-VBV byte-identity pre/post: CRF, CQP, ABR-no-VBV, t1 and
      threaded.

## 5. Quality and compliance

- [x] 5.1 Measure threaded CBR+VBV pre/post: bitrate error vs target,
      PSNR-Y/SSIM, filler bytes, clean JM/ffmpeg decode; no new VBV
      under/overflow.  Matrix MUST include `--bframes 0` AND default
      `--bframes 3` configs (site E fallback is otherwise unmeasured).
      Fixed matrix (maintainer decision 2026-08-18): clips {clip.yuv
      176x144, scenecut.yuv, /mnt/store2/ts/hall.mp4 720p full length}
      x {bframes 0, 3} x {t4, t8} CBR+VBV, plus a PAFF TFF spot-check;
      baseline = median of 5 pre-change runs per cell; clips are
      external files referenced by path (never committed to git),
      missing clip = cell skipped with a note.
      Acceptance thresholds (pre-registered): |bitrate error delta|
      <= 0.5%, |PSNR-Y delta| <= 0.05 dB, |SSIM delta| <= 0.002,
      filler bytes <= baseline median; tools/check_hrd.py clean on all
      post-change outputs encoded with --nal-hrd cbr.  Any exceedance
      routes to 5.2, not to discussion.
- [x] 5.2 If 5.1 shows a meaningful regression attributable to the checks,
      evaluate blanket-skip vs the committed check (design: "Alternatives") and keep the
      better one; record the outcome in design.md.

## 6. Upstream port and docs

- [x] 6.1 Apply the final diff to the clean `/tmp/x264-upstream` worktree
      (0480cb05): reproduce the bug, verify the fix, confirm no PAFF
      dependencies.
- [x] 6.2 Update `doc/threads.txt`: the fixed-thread-count determinism
      promise now covers VBV; note the sliced-threads exception.
- [x] 6.3 Update `AGENTS.md` testing notes: `tools/test_vbv_determinism.sh`
      joins the testing section (byte-repeat checks + quality matrix).
