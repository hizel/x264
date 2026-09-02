# Tasks: PAFF — frame-threaded encoding (hybrid readiness)

Dependency-ordered; ends with validation and doc checkpoints. See
`design.md` for decisions D1–D7. Regression invariant: until task 5.3
removes the forced single-threading, `--paff --threads 1` output is
bit-identical to the current tree (tasks 2.x must be pure rescheduling);
after 5.3, `--threads 1` must stay identical by construction
(single-threaded never broadcasts or waits).

## 1. Readiness counters (D2)

- [x] 1.1 Add `i_lines_completed_fld[2]` to `x264_frame_t`
      (`common/frame.h`, units: field lines); initialize in frame setup
      paths alongside `i_lines_completed`.
- [x] 1.2 Implement `x264_frame_cond_broadcast_fld(frame, parity, completed)`
      and `x264_frame_cond_wait_fld(frame, parity, completed)` in
      `common/frame.c` (reuse the frame `mutex`/`cv`; prototypes in
      `common/frame.h`).
- [x] 1.3 Broadcast the first-field phase: end of the intermediate
      `paff_sync_references` sets the parity-of-pass-0 counter to the
      sentinel, guarded by `b_kept_as_ref` and `i_thread_frames > 1`
      (mirror the guard in `fdec_filter_row`). (Row-granular broadcasts for
      the second field are wired in task 2.)

## 2. Row-cadence sweep for the second field (D5)

- [x] 2.1 Extend `paff_filter_row`: after deblocking the previous
      same-parity row, perform the coding-parity rows' reference-data work —
      `plane -> plane_fld` copy, `x264_frame_filter` +
      `x264_frame_expand_border_filtered` (with `b_end` at pass end) — and
      broadcast the second-field parity counter as
      `filtered_rows*16 - X264_THREAD_HEIGHT` in field lines (the D2 margin:
      16 lines in-flight hpel batch + 8-line deblock/tap safety), sentinel at
      `paff_frame_finish`. `x264_frame_filter` under field coding needs
      even-aligned `mb_y` and re-filters both parities; the re-filter of the
      first field is idempotent and accepted (D5). Audit whether the SATD
      `integral` plane is allocated/used under PAFF; if used, update it on
      the same cadence. Guard broadcasts with `b_kept_as_ref` and
      `i_thread_frames > 1`.
- [x] 2.2 Reduce the final `paff_sync_references` to residual rows only
      (last deblock-lag rows + sentinel broadcast for both parities) plus
      quality measurement in `paff_frame_finish`; the intermediate
      (between-passes) sweep stays full-frame.
- [x] 2.3 Regression gate: `--paff --threads 1` output bit-identical to the
      pre-change tree on the existing PAFF matrix (pure-rescheduling
      invariant of 2.1/2.2).

## 3. Dispatch split and caller/job boundary (D3)

- [x] 3.1 Move the first field's DPB marking (D20 MMCO opcode-1 application
      and sliding-window eviction, incl. `x264_frame_shift` +
      `x264_frame_push_unused`) from the driver into the caller, before
      dispatch; prepare the two pair-list snapshots (pre-marking for pass 0 —
      including the P-pair past-list rebuild from `h->frames.reference` with
      the FrameNumWrap-descending sort — and post-marking for pass 1) and
      pass both to the job. After this task the job never reads
      `h->frames.reference` or the unused-frame pool.
- [x] 3.2 Advance `i_frame_num` caller-side before dispatch; pass the
      pre-increment value to the job and override `sh.i_frame_num` after
      each `slice_init` (same pattern as the existing `i_poc`/
      `b_field_pic`/`i_first_mb` overrides). The job never writes
      `h->i_frame_num`.
- [x] 3.3 Extract the pair-driver body into a pool work item (`paff` job
      taking `h`), preserving internal order except the per-pass list
      expansion (3.4); the job writes `h->sh` directly per pass
      (`paff_slice_init` + overrides against the live struct; pair-level
      view restored at job end) — the local-snapshot variant was rejected
      after the 6.1 audit showed the only read-before-overwrite consumer
      (`reference_update`'s MMCO application) is a no-op for every
      observable state (D3.4). The job receives
      the two snapshots, the expanded per-pass lists + parity maps and the
      pre-increment `i_frame_num` (3.2) via the `x264_paff_job_t`
      job-parameter struct on `x264_t`, and loads each pass's stored lists into
      `h->fref`/`mb.pic` at pass start. `weighted_pred_init`,
      `map_col_to_list0` and `x264_macroblock_bipred_init_paff` stay job-side
      per pass (they need the live `h->fref`) but now read caller-published
      metadata. Submit with `x264_threadpool_run` when `i_thread_frames > 1`
      (set `b_thread_active`), else call inline — the progressive
      `slices_write` dispatch shape.
- [x] 3.4 Caller-side expansion: run both passes' `paff_expand_field_list`
      calls (L0 and L1, both parities) in the caller before dispatch and
      write the per-parity metadata (`i_ref[]`, `ref_poc[]`,
      `i_poc_l0ref0[]`, `i_field_avail`) onto `h->fdec` serially, restoring
      the progressive publish-in-caller invariant (D3.3). Fill the
      job-parameter struct with the expanded lists and parity/frame maps.
      No lists-published handshake is introduced.
- [x] 3.5 Remove `assert( h->i_thread_frames == 1 )` from the driver body.
      Keep the forced `i_threads = 1` in place until task 5 (the dispatch
      split stays dormant at `i_thread_frames == 1`).

## 4. Wait sites (D4)

- [x] 4.1 Rework the per-row wait loop in `encoder/analyse.c`: for PAFF,
      wait via `x264_frame_cond_wait_fld` on `fref[i][j]->orig` using the
      per-entry parity maps (`i_fref_parity` / `i_fref_parity_l1`); convert
      thresholds to field lines from the MB position; skip entries where
      `fref == h->fdec` (self/complementary field); clamp
      `thread_mvy_range = completed - pix_y_field`; mirror the progressive
      `b_deterministic` handling exactly (deterministic: discard the clamp,
      use the fixed `i_mv_range_thread`; `--non-deterministic`: keep the
      clamped range). Vertical MV-limit geometry stays frame-based
      (pre-existing); only the clamp is in field units — tightening the
      geometry would break `--threads 1` bit-identity.
- [x] 4.2 Rework the NDEBUG MV-out-of-range check in `encoder/analyse.c`
      to use the parity map instead of `ref >> MB_INTERLACED` for PAFF
      lists (keep the MBAFF/progressive branch untouched).
- [x] 4.3 Audit `x264_analyse_weight_frame` and every weighted-reference
      read path: all must sit behind the same row gating (field-coordinate
      `pix_y + thread_mvy_range`); confirm no read path bypasses the waits.
- [x] 4.4 Enable the standard `i_mv_range_thread` defaulting for PAFF at
      `i_thread_frames > 1`, computed from the field height
      (`param.i_height/2`), and the `thread_mvy_range` clamp path.

## 5. Validation removal and deadlock matrix

- [x] 5.1 Remove the forced `i_threads = 1` + warning from
      `x264_encoder_open`; keep the sliced-threads rejection.
- [x] 5.2 Verify `--paff --threads 1` output is still bit-identical to the
      pre-change tree (same clip, same flags).
- [x] 5.3 Deadlock matrix: run `--paff --threads 2/4/8` over I/P/B clips
      (incl. BREF, `--bframes 3`, `--ref 5`); no hang, no
      partial-reference artifacts (NDEBUG build to catch "MV out of thread
      range").  Clip set extended by 9.4: the brightness-fade clip
      (`--weightp 2`, weights on ~100% of P pairs) and the mid-stream
      scenecut clip (IDR pairs at 16/32/48) run the same 2/4/8 sweep.

## 6. Cross-thread sync audit (D6)

- [x] 6.1 Audit `thread_sync_context`'s memcpy region against the job's
      writes, with a formal pass criterion: enumerate every field of the
      region (including `h->sh` wholesale) that is read by the caller,
      `encoder_frame_end` or the lookahead after dispatch, and show for each
      field exactly one of: (1) overwritten by the caller before dispatch,
      (2) passed to the job by value, (3) restored by the job before the
      harvest wait. Record the list in `design.md` or a code comment; move
      anything that fits none of the three to the explicit copy pattern.
- [x] 6.2 Audit `x264_thread_sync_ratecontrol` for pair-level RC state and
      per-AU VBV stepping state (`previous_cpb_final_arrival_time`,
      `initial_cpb_removal_delay*`) updated inside the pool job.
- [x] 6.3 TSAN build (`-fsanitize=thread`) with a small `--paff --threads 4`
      encode: no data races on frame/rc state.
- [x] 6.4 Determinism stress: 100x repeated `--paff --threads 4` encode,
      byte-compare all runs (fixed-N determinism gate).  Extended by 9.4:
      12x repeated runs per N (2/4/8) on the fade (`--weightp 2 --bframes 3
      --ref 5`) and scenecut (default and BREF+weightp2) clips.

## 7. Measurement and regression

- [x] 7.1 JM round-trip regression at `--threads 2/4` for the existing PAFF
      matrix (I/P/B, BREF, multi-ref, TFF/BFF, `--nal-hrd cbr`), per
      `doc/regression_test.txt`.
- [x] 7.2 Quality gate (replaces the old byte-identity checkpoint):
      `--paff --threads 4` vs `--threads 1` PSNR/bitrate divergence within
      the tolerance used for progressive threads N vs 1.  Extended by 9.4:
      the fade and scenecut clips get the same t1-vs-t4 PSNR check, with
      the progressive t1-vs-t4 divergence on the same clip as the
      tolerance reference.
- [x] 7.3 Throughput: benchmark 1080i content at threads 1/2/4/8; record
      speedup in `doc/threads.txt`. Not a merge blocker (D7); any > 1x
      ships, numbers recorded as measured.
- [x] 7.4 Non-PAFF regression: progressive + MBAFF encodes bit-identical to
      pre-change tree; `make checkasm` clean.

## 8. Documentation

- [x] 8.1 Rewrite the Threading section of `doc/paff.txt` (hybrid readiness
      model, determinism contract, no byte-identity, Tier 2 + low-latency as
      future work); record the frame-geometry MV-limit over-search (D4) as a
      known pre-existing issue, future work.
- [x] 8.2 Add the PAFF note to `doc/threads.txt` (row gating, MV-range
      clamp semantics, benchmark table from 7.3).
- [x] 8.3 Update `AGENTS.md`: replace the "PAFF forces i_threads=1" and
      determinism-only-at-threads-1 facts with the frame-threaded reality.

## 9. Post-review findings (code review, 2026-08-15)

- [x] 9.1 Lazy weight-plane fill under PAFF frame threads mixed units
      (encoder/analyse.c): the fill extent treated the field-line `end`
      as frame rows and used i_padv = PADV << PARAM_INTERLACED (32)
      where the buffer and weighted_pred_init use PARAM_FIELDCODE (64).
      The lower ~half of the weighted plane stayed scratch memory read
      by ME: 0.16 dB t1-vs-t4 Y-PSNR divergence on a fade clip at
      weightp 2 (weights on 100% of P pairs) vs the ~0.005 dB
      progressive tolerance; gone at weightp 0.  Fixed: need =
      2*(16+end)+1 frame rows under PAFF, i_padv = PADV <<
      PARAM_FIELDCODE.  Progressive/MBAFF/PAFF-weightp-0 bit-identical.
- [x] 9.2 Weighting-slot indexing (common/macroblock.c):
      macroblock_load_pic_pointers used weighted[j >> mb_interlaced],
      valid for MBAFF's 2k/2k+1 adjacency but not for PAFF's pass-1
      list where the complementary entry shifts the entry parity
      mid-list; the second entry of a weighted pair read a foreign
      slot.  Fixed: index j directly under FIELD_PIC (matches
      weighted_pred_init's pair_slot).  Pre-existing from the
      field-pictures change (affects --threads 1); baselines move.
- [x] 9.3 BLOCKER (RESOLVED): fixed-N determinism broken at N >= 2 on
      scenecut-IDR clips.  Root cause (proven via rr record/replay on a
      diverging pair): `reference_build_list` early-returns for I slices
      BEFORE the PAFF `ref_blind_dupe = -1` assignment, so every IDR pair
      keeps the slot context's stale value (calloc-zero in practice:
      `i_ref == 0 == ref_blind_dupe`).  An IDR pair's second field is coded
      as a P slice whose L0[0] is the complementary first field, so
      `mb_analyse_inter_p16x16` took the weightp-refdupe ME branch, whose
      start MV is seeded from `a->l0.mvc[0][0]` -- uninitialised bytes of
      the stack-resident analysis struct, i.e. the pool worker's stack
      history.  Evidence chain: diverging unit = first MB of the IDR pair's
      P field (entry state, ref pixels, mvp, limits all byte-identical;
      me start MV garbage, e.g. (-13824,21893); predict_mv_ref16x16 never
      called); 1700 differing bytes inside the uninitialised analysis
      struct at mb_analyse_init; -ftrivial-auto-var-init=pattern fully
      determinizes (mechanism proof); job serialization / full-completion
      waits / single-threaded lookahead / ASLR-off / single-CPU /
      MALLOC_ARENA_MAX / valgrind / MSan all neutral -- the trigger is
      worker IDENTITY (stack history), not concurrency.  Fix: hoist the
      PAFF assignment above the I-slice early return (encoder.c).
      Validation: t2/t4/t8 x12 -> 1 unique output each; t4 x40 -> 1;
      t4 BREF+weightp2 x12 -> 1; progressive and MBAFF bit-identical;
      PAFF t1 baseline moves again (garbage-seeded decisions removed from
      IDR-pair second fields -- same precedent as the first
      ref_blind_dupe fix; quality t1-vs-t4 stays within the progressive
      tolerance).
- [x] 9.4 Close the matrix gap that let 9.1-9.3 through: add a
      brightness-fade clip (weights active at --weightp 2; target
      "Weighted P-Frames: Y: ~100%") and mid-stream scenecut clips to
      tasks 5.3/6.4/7.2, with repeated-run byte-compare per N
      (determinism) and t1-vs-tN PSNR tolerance (weighted paths).
      DONE (2026-08-15): clips = /tmp/fade.yuv (320x240, 40f, 9.1's
      generator; "Weighted P-Frames: Y:100.0%" at --weightp 2) and a new
      /tmp/scenecut.yuv (320x240, 64f, 4 noise/gradient scenes, hard cuts
      at 16/32/48 -- all three detected as scenecuts, 4 IDR pairs total).
      5.3: t2/4/8 complete with no hang for fade --weightp 2 --bframes 3
      --ref 5, scenecut default, scenecut BREF+weightp2.  6.4: 12x per N
      (2/4/8) byte-identical for all three configs.  7.2: t1-vs-t4 Y-PSNR
      divergence = 0.011 dB (fade_w2), 0.001 dB (sc_def), 0.003 dB
      (sc_bref) against the progressive same-clip reference of 0.004 dB
      (fade) / 0.000 dB (scenecut) -- same progressive class the 9.1 fix
      validation recorded (+0.025 dB from the MV-range clamp).
- [x] 9.5 Review nits (second code review, 2026-08-15):
      (a) x264_frame_cond_wait_fld dropped the progressive variant's
      `i_lines_completed >= 0` guard on the premise that the per-parity
      counter "starts at -1 and only grows" -- false: the band-0
      broadcast writes 16 - X264_THREAD_HEIGHT = -8, so a -1 peek (the
      NDEBUG MV-range check, analyse.c) could block until the reference
      pair's next band (no deadlock: references are earlier in coding
      order; debug-only path).  Fixed: guard restored, matching the
      progressive semantics.
      (b) x264_analyse_weight_frame's PAFF both-parities wait had no
      i_thread_frames > 1 guard of its own -- safe only because the sole
      PAFF caller is guarded and threaded_slices_write is unreachable
      under PAFF; at i_thread_frames == 1 the counters are never
      broadcast, so any future unguarded call site would deadlock.
      Fixed: guard added in the function itself.  Both: --paff output
      bit-identical at t1 and t4 (md5-verified), t1 weightp-2 no hang.
