# Tasks: paff-sliced-threads

Design references: D1 architecture, D2 band geometry, D3 serial sweep,
D4 field budgets, D5 accumulator hygiene, D6 stride fixes, D7 determinism,
D8 validation. Hard gates throughout: progressive/MBAFF/non-sliced-PAFF
byte-identity pre/post; JM bit-exactness for every new PAFF+sliced stream.

## 1. Validation and band geometry (D2, D8)

- [x] 1.1 Replace the `b_paff && b_sliced_threads` validation error
      (encoder.c:505) with acceptance; add rejections with clear errors:
      (a) `--paff --sliced-threads` + any of `--slice-max-size` /
      `--slice-max-mbs` / `--slices`; (b) drive-by: `--paff` +
      `--slice-max-mbs` / `--slices` at ANY thread count (today: silent
      empty output, exit 0).  Check the USER-SUPPLIED `i_slice_count`
      at the PAFF validation block (encoder.c:505), i.e. before the
      sliced-threads override at encoder.c:1095 rewrites it to
      `i_threads`
- [x] 1.2 Halve `max_sliced_threads` under PAFF (field MB rows, not frame
      MB rows): `((i_height/2 + 15)/16) / 4` — as a LOCAL value at the
      sliced-threads clamp (encoder.c:637) gated on
      `b_paff && b_sliced_threads`; do NOT halve the shared variable
      (encoder.c:627): it also clamps `i_lookahead_threads`
      (encoder.c:1360) in all modes, and the lookahead is
      frame-granular (D8)
- [x] 1.3 Rework the band split in `threaded_slices_write` for
      `FIELD_PIC`: `field_rows = i_mb_height/2`; per-thread
      `i_threadslice_start = parity + 2*b0`,
      `i_threadslice_end = parity + 2*b1 - 1` (end is one PAST the last
      coded row; the last band then equals the monolithic
      `i_mb_height-1+parity`, and the flush gate
      `sh.i_last_mb == i_threadslice_end*width-1` fires — a `parity +
      2*b1` end never fires it and the join deadlocks),
      `sh.i_first_mb/i_last_mb = start/end * width ∓ 1`;
      keep the contiguous path byte-identical for non-field pictures
- [x] 1.4 Smoke (validation/geometry only — slices are still
      monolithic until task 2.1 reroutes the dispatch):
      `--paff --sliced-threads --threads 2` encodes without crash;
      `--threads 8` on 576i clamps to the field-row cap (4) with a
      warning

## 2. Per-pass dispatch in the pair driver (D1)

- [x] 2.1 In the monolithic pair driver (`paff_pair_write` path), route
      each pass through `threaded_slices_write` when
      `b_sliced_threads` is set, keeping the plain `slices_write` call
      otherwise; verify the per-pass state (fref lists, parity maps,
      `mb.pic`) reaches worker contexts via the existing
      `i_frame..rc` memcpy
- [x] 2.2 Verify NAL merge order and `i_paff_au_boundary` placement:
      pass-0 merge completes before the boundary index is recorded,
      pass-1 merge before `ratecontrol_end`; AUD/SEI emission unchanged.
      Per-pass worker output reset (D3e): `t->out.i_nal = 0` for
      `i > 0` ONLY at each dispatch under FIELD_PIC — h (thread[0])
      keeps its monolithic `i_nal`/`bs` (resetting h would clobber the
      merged pass-0 AU and the pass-1 SEI written on h before the
      dispatch); the encoder-level reset runs once per PAIR, so without
      the worker reset pass 1 re-merges pass 0's worker NALs.  NO
      per-pass `bs_init` (merged pass-0 NAL payloads point into worker
      buffers — they must keep growing); instead, at the pass-0 join
      DEEP-COPY each worker's pass-0 NAL payloads into pair-owned
      scratch (freed after the pair's output is consumed) — a worker
      buffer realloc mid-pass-1 moves the buffer and fixes up only that
      worker's own nal entries, leaving h's merged pass-0 pointers
      dangling.  Pass-1 `i_misc_bits` correction, two formulas (D3e):
      workers subtract their bare pass-0 `bs_pos` baseline (their
      `i_nal` was reset — no NALU_OVERHEAD term); h subtracts pass-0
      `bs_pos + i_nal*NALU_OVERHEAD*8` captured post-merge (the
      existing `shared_out_bits` shape).  ALL pass-1 misc corrections
      run BETWEEN the join and `x264_threads_merge_ratecontrol` — the
      merge's per-slice `update_predictor` consumes
      `t->stat.frame.i_misc_bits` inside `threaded_slices_write`, so a
      correction applied after return teaches the predictors
      double-counted bits
- [x] 2.3 JM round-trip smoke (CRF, TFF, I+P, N=2) bit-exact vs
      `--dump-yuv` before proceeding; ffprobe confirms 2 slices per
      field picture (moved here from 1.4 — the count is only observable
      once 2.1 reroutes the passes through `threaded_slices_write`)
- [x] 2.4 Weightp shadow sync (D9): copy `h->paff_weighted[]` into each
      worker's shadow in `threaded_slices_write` under `b_paff`, per
      pass, after `weighted_pred_init`/upfront weight analysis on `h`;
      workers read thread 0's buffers read-only.  Smoke:
      `--paff --sliced-threads --threads 2 --weightp 2` encodes a P
      chain without crash and JM-decodes
- [x] 2.5 mb_info lifetime (D3d): under `b_paff && b_sliced_threads`
      NO worker frees `fdec->mb_info` (pass 0's last worker would free
      the pair-shared buffer that pass 1's analysis still reads —
      analyse.c:3035/3057); the main context frees once after the
      second pass's join.  Smoke: API-level encode with `b_mb_info` +
      `b_mb_info_update` set, both fields honor the input (callback
      fires once per pair, after the pair completes)

## 3. Filtering under sliced threads (D3)

- [x] 3.1 Give `paff_filter_row` a sliced-threads branch: no reference
      band work (bands run post-join), NO cadence deblock at all (no
      consumer under `i_thread_frames == 1`; all deblock moves to the
      slice end, pixel-identical) — keep only the intra-border-backup
      rotation (needed by intra prediction of the next own row)
- [x] 3.2 Rework the end-of-slice flush (encoder.c:3747-3783) under
      FIELD_PIC: (a) do NOT call `paff_filter_row(h, i_mb_height +
      parity)` (it would deblock a foreign row and fire band work);
      (b) deblock ALL own band rows `[i_threadslice_start,
      i_threadslice_end)` stride 2 in one loop, subject to `idc != 1 &&
      (b_kept_as_ref || b_full_recon || psz_dump_yuv)`, BEFORE the
      completion signal; (c) of the progressive sliced-threads block,
      keep ONLY `x264_threadslice_cond_broadcast(h, 1)` (the join
      signal) — skip the hpel pass and the boundary-row wait entirely;
      (d) relocate the `mb_info_free` handoff (D3d): under
      `b_paff && b_sliced_threads` workers never free — pass 0's last
      worker would free the pair-shared `fdec->mb_info` that pass 1's
      analysis still reads (analyse.c:3035/3057); the main context frees
      after the second pass's join
- [x] 3.3 Implement the serial post-join sweep on the main context: loop
      `paff_reference_band(2*kb, b_end, parity)` over all bands of the
      pass's parity after `threaded_slices_write` returns, `b_end` on the
      last band; skip `paff_pass_finish`'s band in this mode (sentinel
      already gated off)
- [x] 3.4 Verify reference pixels: encode a P-chain PAFF stream sliced
      N=4 vs `--threads 1`, decode both in JM, confirm both decode
      cleanly (bitstreams differ by construction; both must be
      conformant) and `--dump-yuv` matches JM bit-exactly for the sliced
      run
- [x] 3.5 PSNR/SSIM: `paff_frame_finish` quality measurement runs once
      per pair after both sweeps; check logged values are sane vs the
      `--threads 1` run

## 4. Rate control (D4, D5, D6)

- [x] 4.1 Stride fixes: `row_bits_so_far` step 2 under
      `FIELD_PIC && (i_thread_frames > 1 || b_sliced_threads)` — NOT a
      bare FIELD_PIC gate (the t1 step-1 sum is load-bearing for
      non-sliced byte-identity); `predict_row_size_to_end` iterates
      own-parity rows within the band (pin the START, not just the step:
      the loop begins at `y+1`, which is the SIBLING parity's row —
      correct form `i = y+1+FIELD_PIC; i += 1+FIELD_PIC`);
      distribute/merge band SATD sums
      and `mb_count` stride-2
- [x] 4.2 Extend the `f_row_qp` QP-lowering guard read (ratecontrol.c:1833)
      to the sliced band's first row under `FIELD_PIC`
- [x] 4.3 Per-field budgets at distribute: pass 0 `frame_size_planned`
      scaled by parity satd share, pass 1 set to pair plan minus pass-0
      actual bits CLAMPED BELOW at 5% of the pair plan (D4: an
      overshooting first field must not hand normalization a
      zero/negative plan); scale `frame_size_maximum` by the same factor;
      normalization to the field budget.  Observability: emit one
      `X264_LOG_DEBUG` line per field budget at distribute (greppable;
      the budgets have no API/log surface today).  After the pass-1
      dispatch, restore the pair-level `frame_size_planned` on `h->rc`
      (the update_vbv plan-error tracker reads it at pair end;
      ratecontrol.c:2380)
- [x] 4.4 Accumulator hygiene: zero `qpa_rc`/`qpa_aq` in each NON-MAIN
      worker's (`t != h`) rc copy at distribute after the state memcpy —
      `h->thread[0] == h` and merge folds only `i >= 1`, so the main
      context's rc carries the running pair total (D5); verify pair
      average QP and 2-pass stats against the `--threads 1` PAFF run
      via the OBSERVABLE surrogate (logged pair q= within a stated
      tolerance) — the per-pair decomposition itself is not logged
- [x] 4.5 CBR+VBV PAFF sliced encodes complete without underflow floods:
      warnings count comparable to the frame-threaded PAFF run

## 5. Test matrix (spec scenarios)

- [x] 5.1 `tools/test_paff.sh`: new `sliced` command — JM round-trips
      {TFF,BFF} × {I-only, I+P, I+P+B} × N∈{2,4}, including `--weightp 1`
      and `--weightp 2` cells (D9); band-geometry edges
      (height not divisible by N, N=2, N above the cap); CBR+VBV and
      2-pass cells; `--nal-hrd cbr` cells through `check_hrd.py`; an
      API-level `b_mb_info` + `b_mb_info_update` cell (task 2.5); a
      budget-sum assertion cell (pass-0 + pass-1 field budgets sum to
      the pair plan within the D4 floor's slack, read from the DEBUG
      budget lines); CAVLC cells (`--no-cabac`): one JM round-trip and
      one non-VBV byte-repeat, CRF, N∈{2,4} — the entropy coder takes
      a different flush path in slice_write and has zero coverage
      today; one 10-bit sliced PAFF cell (4:2:0; 4:2:2 if the harness
      supports it) — ffmpeg conformance decode (clean decode, exact
      frame count; JM bit-exactness stays 8-bit-only as today), since
      the worker-buffer growth window D3e guards is depth-dependent
- [x] 5.2 `tools/test_vbv_determinism.sh`: PAFF+sliced cells — byte-repeat
      10/10 for CRF and CQP at N∈{2,4,8} ±B-frames; CBR+VBV cells assert
      check_hrd pass + zero underflow warnings instead of byte-repeat;
      overshoot cell: deliberately undersized `--vbv-bufsize` at N=4 to
      force a first-field budget overshoot (D4 floor) — assert check_hrd
      passes and no crash/NaN/garbage normalization, and RECORD the
      underflow warning count as a number (do NOT compare it against
      frame-threaded PAFF: the floor by design spends bits a
      frame-threaded pass 1 would not, so "not worse" is unsatisfiable
      in exactly the cell that exercises the floor); ABR-without-VBV
      byte-repeat cell at N∈{2,4} (the spec scenario lists it alongside
      CRF/CQP — same harness, one more mode)
- [x] 5.3 Regression byte-identity cells: progressive+sliced pre/post,
      PAFF non-sliced (threads 1 and frame threads) pre/post
- [x] 5.4 `tools/test_paff_hw.sh`: add multi-slice PAFF streams (TFF+BFF,
      I+P+B, CBR+VBV with filler) — clean decode, exact frame count,
      pixel match vs software ffmpeg
- [x] 5.5 `tools/test_paff_ci.sh`/`paff_matrix.sh`: CI cells for
      sliced PAFF (quick JM subset + the SPS/validation checks)

## 6. Measurement and acceptance

- [x] 6.1 Quality: BD-rate overhead of sliced-PAFF vs PAFF `--threads 1`,
      CRF sweep, N∈{2,4} for 1080i and N∈{2,4} for 576i (576i has 18
      field MB rows → the cap is 4, so "N=8" there silently encodes at
      N=4 and corrupts the monotonicity check); the reference penalty is
      progressive sliced at the SAME N on a HALF-HEIGHT progressive clip
      (equal band height AND equal slice count — the Open Questions
      anchor), not progressive N on the full-height clip
- [x] 6.2 Speed: wall-clock speedup vs sliced-t1 at N∈{2,4,8}; serial
      sweep share measured (profiling) to confirm/refute the D3 estimate
- [x] 6.3 Fix the acceptance numbers in docs per the measure-then-fix
      procedure; if the sweep tail exceeds expectation, document variant
      B (boundary-window parallelization) as the follow-up trigger

## 7. Documentation and final review

- [x] 7.1 `doc/paff.txt`: Threading section (sliced mode description,
      per-field budgets), Unsupported combinations (remove sliced; add
      sliced+slice-max-size, sliced+slice-max-mbs, sliced+slices, and
      the PAFF-wide slice-max-mbs/slices rejection), Future work
      (variant B, stride-aware sub-slicing, deterministic CBR+VBV
      stand-ins), quality/speed numbers from 6.x
- [x] 7.2 `doc/threads.txt`: sliced-under-PAFF paragraph incl. the VBV
      determinism exception
- [x] 7.3 AGENTS.md architectural-facts paragraph: sliced threads no
      longer listed as rejected under PAFF
- [x] 7.4 Final full matrix run (`test_paff.sh all` + sliced + vbv
      determinism + checkasm8/10) green; small commits per upstream
      style
