# Design: paff-sliced-threads

## Context

See proposal.md - Why. Current state relevant to the approach:

- `--paff --sliced-threads` is rejected at validation (encoder.c:505).
- PAFF codes each field of a pair in a per-pass body
  (`paff_pass_write`/`paff_pair_write`). A pass codes the MB rows of one
  parity in frame coordinates, stride 2: `sh.i_first_mb = parity*width`,
  `i_threadslice_start = parity`, `i_threadslice_end = i_mb_height-1+parity`
  (encoder.c:4046, 4116). `slice_header_write` already translates
  frame-coordinate MB addresses into the field raster (encoder.c:224).
- The MB loop already steps rows by `1 + FIELD_PIC` (encoder.c:3723), and
  neighbor availability treats `i_threadslice_start` as the no-top-neighbor
  boundary (macroblock.c:850) — both correct for parity-interleaved bands
  with no changes.
- Sliced threads (`threaded_slices_write`, encoder.c:3874) split one
  picture into N contiguous bands, run `slices_write` per band on
  `h->thread[i]`, then merge NALs/stats and ratecontrol state. It forces
  `i_thread_frames = 1`, so the PAFF pass-job machinery
  (`paff-pass-threads`) is entirely inactive in this mode.
- PAFF row-cadence filtering (`paff_filter_row`, encoder.c:3145) exists to
  feed row-granular reference readiness to frame threads; its progress
  broadcast is already gated on `i_thread_frames > 1`.
- Threaded-VBV determinism is guaranteed only for frame threads; sliced
  threads are a documented exception (`doc/threads.txt`, "Threaded VBV
  determinism" final paragraph).

## Goals / Non-Goals

**Goals:**

- `--paff --sliced-threads --threads N` produces conformant PAFF
  bitstreams: N slices per field picture, JM bit-exact round-trip.
- Minimal new synchronization: reuse the monolithic pair driver; add no
  cross-thread pixel dependencies.
- Row-VBV budget consistent per field (see proposal); pair-level RC
  accounting exact.
- No behavior change outside `b_paff && b_sliced_threads`: progressive,
  MBAFF, and non-sliced PAFF outputs byte-identical pre/post.

**Non-Goals:** (restating proposal scope boundaries at design level)

- No pass-1/pass-2 boundary-window parallelization of reference
  filtering; no deterministic CBR+VBV under sliced threads; no change to
  the frame-thread PAFF path.

## Decisions

### D1: Architecture — monolithic pair driver + per-pass slice dispatch

With `b_sliced_threads`, `i_thread_frames == 1`, so the pair is coded by
the existing `--threads 1` monolithic pair driver (`paff_pair_write`),
and each of the two passes calls the sliced dispatch
(`threaded_slices_write`) instead of the plain `slices_write`. The two
passes remain sequential; pass 1 references pass 0's field only after it
is fully complete — no row waits anywhere.

Why over reusing the pass-job pipeline: the pass-job machinery
(pair-list snapshots, rendezvous, per-parity progress counters) exists to
overlap pairs across slots; under sliced threads there is nothing to
overlap it with. Not touching it removes the largest risk surface.

### D2: Band geometry — stride-2 in frame coordinates

`threaded_slices_write` currently computes contiguous bands from
`i_mb_height >> PARAM_INTERLACED`; under PAFF `PARAM_INTERLACED == 0`
(b_interlaced is MBAFF-only) and `i_mb_height` is the frame MB height, so
the naive split would span both parities with the wrong step. Under
`FIELD_PIC` the band math becomes:

- `field_rows = i_mb_height / 2`;
- thread i gets field rows `[b0, b1)` with the existing round-robin bias;
- `i_threadslice_start = parity + 2*b0`,
  `i_threadslice_end = parity + 2*b1 - 1`;
- `sh.i_first_mb = i_threadslice_start * width`,
  `sh.i_last_mb = i_threadslice_end * width - 1`.

End convention (as everywhere in x264): start is the first coded
frame-coordinate MB row, end is one past the last coded row — so under
stride 2 the next band's start is this band's end + 1, the last coded row
of a band is `end - 1 = parity + 2*(b1-1)`, and for the LAST band end
equals the monolithic pass value `i_mb_height - 1 + parity` exactly.  The
`- 1` is load-bearing (grill r1): the end-of-slice flush gate
`sh.i_last_mb == i_threadslice_end*width - 1` (encoder.c:3748) and
`thread_last_mb` (encoder.c:3399) require it — a `parity + 2*b1` end
makes the gate never fire, the completion signal is never broadcast and
`threaded_slices_write`'s join deadlocks on the first encode.  With the
correct end, every stride-2 loop `for( row = start; row < end; row += 2 )`
enumerates exactly the band's coded rows.

The field-raster translation in `slice_header_write`, the stride-2 MB
loop, and the top-neighbor rule all key off these same variables, so they
work unmodified. `max_sliced_threads` is halved under PAFF (field has
half the frame's MB rows): `((i_height/2 + 15)/16) / 4` — computed as a
LOCAL value at the sliced-threads clamp only; see D8 for why the shared
variable must NOT be halved (the lookahead clip reads it in all modes).

### D3: Reference filtering — serial post-join sweep (variant C)

Under sliced threads the per-thread work is: code the band, deblock own
rows at slice end (cross-slice deblock is disabled, idc=2, so deblock is
band-local and race-free). All reference-data work — plane_fld copy,
borders, hpel — runs after `threaded_slices_write` joins, single-threaded
on the main context, as a loop of the existing `paff_reference_band` over
all bands of the coding parity with `b_end` on the last.

Rationale over the alternatives explored:

- *Keep the cadence in-band (variant A)*: the cadence's only consumer is
  frame-thread row readiness, which is inactive (`i_thread_frames == 1`);
  it would also need new guards (the band index at a slice's second row
  reaches into the previous slice's not-yet-coded rows).
- *Progressive-style pass-1/pass-2 boundary windows (variant B)*:
  correct but introduces the change's only cross-thread pixel
  synchronization (hpel taps cross band boundaries; the boundary window
  must be redone after the neighbor's broadcast). Deferred as a documented
  optimization if profiling shows the serial sweep matters.
- *Serial sweep (chosen)*: zero new synchronization; the sweep is
  literally the pre-`paff-pass-threads` shape, and `paff_reference_band`
  is documented byte-identical to it band-by-band. Cost: copy/borders/hpel
  run serially once per pass — acceptable for the latency-oriented mode
  at the thread counts sliced threads target (cap ≤ 8 at 1080i).

`paff_filter_row` under sliced threads therefore reduces to the
intra-border-backup rotation alone (needed by intra prediction of the
next own row): no reference band work (bands run post-join) and no
cadence deblock — under sliced threads the cadence has no consumer at
all (row readiness is a frame-threads mechanism, `i_thread_frames == 1`),
and deblocking is row-deterministic, so all of it moves to the slice
end without changing a single output pixel.  The end-of-slice flush
(encoder.c:3747-3783) under FIELD_PIC becomes: (a) the final
`paff_filter_row(h, i_mb_height + parity)` call is NOT made (it would
deblock a foreign, possibly not-yet-coded row and trigger band work);
(b) the thread deblocks all its own band rows (`[i_threadslice_start,
i_threadslice_end)`, stride 2, subject to `idc != 1 &&
(b_kept_as_ref || b_full_recon || psz_dump_yuv)`) BEFORE signalling
completion — cross-band edges are not filtered (idc=2), so band-local
deblock writes stay inside the band and are race-free; (c) of the
progressive sliced-threads block, only the
`x264_threadslice_cond_broadcast(h, 1)` join signal is kept — the hpel
pass and the boundary-row wait (the deferred variant-B machinery) are
skipped entirely; (d) the `mb_info_free` handoff moves out of the
workers: under `b_paff && b_sliced_threads` NO worker frees — pass 0's
last worker would free the pair-shared `fdec->mb_info` that pass 1's
analysis still reads (fast-skip at analyse.c:3035, CONSTANT-flag reset
at 3057 — both silently no-op on the freed buffer, and the app callback
fires mid-pair); the main context frees once after the second pass's
join; (e) per-pass worker output reset: at each dispatch under
FIELD_PIC, `t->out.i_nal = 0` for every NON-MAIN worker (`i > 0` only —
`h->thread[0] == h`, and resetting h would clobber the pass-0 merged
AU plus the pass-1 SEI that `paff_pass_code` writes on `h` BEFORE the
dispatch; h continues its `i_nal`/`bs` monolithically like the
threads-1 driver) — the per-frame reset in `x264_encoder_encode` runs
once per PAIR, so without this pass 1's merge re-copies pass 0's
worker NALs (duplicate slices, wrong `frame_size` for
`ratecontrol_end`, wrong `i_paff_au_boundary` split).  Do NOT `bs_init`
per pass: the `h->out.nal` entries merged after pass 0 point into the
workers' bitstream buffers, which must keep growing across the pair —
and because `bitstream_check_buffer_internal` (encoder.c:379) moves a
growing worker's buffer and fixes up ONLY that worker's own nal
entries, a mid-pass-1 realloc would leave h's merged pass-0 pointers
dangling (use-after-free at encapsulation; the window is real, e.g.
10-bit 4:4:4 lossless growth).  So at the pass-0 join, DEEP-COPY each
worker's pass-0 NAL payloads into pair-owned scratch storage (freed
after the pair's output is consumed); the borrowed-pointer merge
stays valid for pass 1 only.  The pass-1 `i_misc_bits` double count
(each worker's `bs_pos` spans both passes) needs TWO different
corrections (grill r2): workers (`i > 0`) subtract their bare pass-0
`bs_pos` baseline captured at the pass-0 join (their `i_nal` was
reset, so the NAL-overhead term must NOT be subtracted again); h
subtracts its pass-0 `bs_pos + i_nal*NALU_OVERHEAD*8` captured after
the merge folds the workers' NAL counts in — the existing
`shared_out_bits` shape (encoder.c:4129-4143).  Placement is
load-bearing (grill r3): `x264_threads_merge_ratecontrol` runs INSIDE
`threaded_slices_write` right after the join and its per-slice
`update_predictor` call consumes `t->stat.frame.i_misc_bits` — so ALL
pass-1 misc corrections must be applied between the join and the
merge (bake a per-context pass-0 base into `slice_write`'s misc
assignment, or a correction loop in `threaded_slices_write`'s PAFF
branch before the merge call).  Applying them later (e.g. only in
`paff_pass_code`'s `shared_out_bits` block, which runs after the
return) silently teaches every pass-1 band's predictor double-counted
bits, skewing `slice_size_planned` for all later frames while the
byte-repeat and HRD cells still pass.
`paff_pass_finish`'s sentinel broadcast is a no-op in this mode
(already gated on `i_thread_frames > 1`).

### D4: Row-VBV budget per field

`x264_ratecontrol_mb`'s sliced path reconstructs a picture-level estimate
from the threads' per-band values and compares it against
`rc->frame_size_planned`. Under PAFF the plan covers the whole pair but
the estimate covers one field, so the guard would see a doubled budget.
Fix at distribute time, per pass:

- pass 0: `frame_size_planned *= pass_satd / pair_satd` (row SATD is
  known for the whole frame before dispatch);
- pass 1: `frame_size_planned = pair_plan - pass0_actual_bits` (pass 0 is
  complete — exact leftover, something concurrent frame-thread passes
  cannot do), clamped below by a small floor (5% of the pair plan): an
  overshooting first field would otherwise hand the sliced normalization
  a zero/negative plan (NaN-prone trust-coefficient division, garbage
  `size_of_other_slices_planned`); with the floor the arithmetic stays
  in its normal regime and an exhausted pair budget still drives the
  second field to `qp_absolute_max` through the normal row-VBV loops.
  Units (grill r1): "pass 0's actual bits" is the pass-0 `stat.frame`
  sum of tex+mv+misc — the units `frame_size_planned` and the row
  predictors live in (`update_predictor` learns on tex+mv+misc,
  ratecontrol.c:2982) — NOT the NAL payload sum, which adds NAL/SEI
  overhead the plan units do not contain.  The test matrix asserts the
  two field budgets sum back to the pair plan within the floor's slack
  — observed via a defined observability point (grill r2): one
  `X264_LOG_DEBUG` line per field budget emitted at distribute
  (greppable by the test cells), since the budgets are internal values
  with no API/log surface today;
- `frame_size_maximum` is scaled by the same factor;
- `threads_normalize_predictors` then normalizes slice plans to the
  field budget as it already does.  Pair-end invariant (grill r3):
  restore the pair-level `frame_size_planned` on `h->rc` after the
  pass-1 dispatch — `update_vbv`'s plan-error tracker integrates
  `bits - rcc->frame_size_planned` at pair end (ratecontrol.c:2380),
  and while its consumers are inert under sliced threads today, the
  field-scaled leftover must not be left as the pair plan;

This is more than a units fix: per-field budgeting directly bounds the
first-field overshoot that the pair-level CPB step provably cannot see
(documented in `vbv_au_step`). Per-field sizes still feed the pair-level
`update_vbv` per-AU stepping unchanged.

### D5: Ratecontrol accumulator hygiene across two distribute/merge cycles

Pair-level accumulators (`qpa_rc`, `qpa_aq`) are zeroed once per pair in
`ratecontrol_start`, but sliced mode runs two distribute/merge cycles per
pair, and distribute copies the accumulated base into each worker.
Without hygiene the merge adds the base once per worker (N-fold
double-count of pass 0 in the pair's average-QP statistics, poisoning
2-pass stats). At distribute, after the state memcpy, zero the pair-level
accumulators in each worker's `rc` copy; merge then adds each pass's own
delta exactly once.

### D6: Stride fixes in the row loops

All row loops that interpret `i_threadslice_start/end` as a contiguous
range need the parity stride under `FIELD_PIC`:

- `row_bits_so_far`: step becomes 2 under
  `FIELD_PIC && (i_thread_frames > 1 || b_sliced_threads)`.  The gate
  must NOT become a bare `FIELD_PIC` (grill r2): at `--threads 1` the
  step-1 sum is load-bearing — the sibling field's rows are final and
  belong in pass 1's `bits_so_far` against the PAIR-level plan (the
  code comment in ratecontrol.c says exactly this, "byte-identity");
  changing it would move every PAFF t1 QP trajectory and break the
  non-sliced byte-identity gate;
- `predict_row_size_to_end`: pin the START, not just the step (grill
  r3): the loop is `for( i = y+1; i < end; i++ )` and y is own-parity,
  so `y+1` is the SIBLING parity's row — step-2 from there sums the
  wrong field's rows (pass 0's final data for pass 1).  Correct form:
  `for( i = y+1+FIELD_PIC; i < end; i += 1+FIELD_PIC )` (start y+2,
  step 2 under FIELD_PIC).  The other stride-2 loops all start at
  `i_threadslice_start` (own parity by construction) and are safe as
  "step 2";
- `x264_threads_distribute_ratecontrol` / `x264_threads_merge_ratecontrol`:
  band SATD sums and `mb_count` use the stride-2 row range;
- the QP-lowering guard reading `f_row_qp[...]` (ratecontrol.c:1833)
  reads the band's first row (self-written earlier in the same row's
  processing — deterministic), extending the existing
  `FIELD_PIC && i_thread_frames > 1` shape to sliced mode.

### D7: Determinism stance (spec-level)

Inherit the upstream sliced-threads exception: CBR+VBV is
timing-dependent (cross-slice live reads of `bits_so_far` /
`frame_size_estimated`); all non-VBV modes avoid that code entirely
(`if (!rc->b_vbv) return`) and are byte-repeatable at fixed N. The
reads that remain under non-VBV modes are either pre-dispatch (row SATD)
or self-writes (own band's rows). No PAFF-specific determinism machinery
is added.

### D8: Validation and combination matrix

- Remove the `b_paff && b_sliced_threads` error.
- Reject `b_paff && b_sliced_threads` combined with ANY explicit
  sub-slicing: `i_slice_max_size` (row-recode restarts break row
  monotonicity, same caveat as documented for the threaded-VBV
  guarantee), `i_slice_max_mbs` and `i_slice_count > 0` (their boundary
  arithmetic in `slices_write` assumes a contiguous raster — under
  FIELD_PIC it crosses parity rows; one band = one slice is the only
  supported shape).  Stride-aware subdivision is future work.
- Drive-by (pre-existing bug, same validation block): plain `--paff`
  with `--slice-max-mbs` or `--slices` produces EMPTY output with exit
  code 0 today at any thread count (measured: 320x192, threads 1,
  slice-max-mbs 30/40, slices 2).  Reject it for all thread counts with
  a clear error.  `--slice-max-size` under non-sliced PAFF works today
  and stays accepted.
- Sliced+PAFF is 8/10-bit and chroma-format agnostic; no new asm.
- `max_sliced_threads` halved (D2).

### D9: Weighted prediction under sliced threads — shadow pointer sync

PAFF keeps per-pass weighted-reference pointers in the slot-local shadow
`paff_weighted` (outside the `i_frame..rc` sync region — paff-pass-threads),
and `weighted_pred_init` runs on `h` only.  Under sliced threads,
`threaded_slices_write` propagates `sh.weight[j].weightfn` to workers but
not the shadow, so a worker coding a weighted P MB would dereference its
own uninitialized shadow entry (NULL after encoder open, stale from the
previous pass afterwards).  Fix: after the upfront
`x264_analyse_weight_frame` on `h` (which scales the full plane — correct
for PAFF, since field-list entries of both parities read the frame-layout
weighted plane), `threaded_slices_write` copies the `paff_weighted`
pointer array into each worker's shadow, per pass.  Workers read
thread 0's weight buffers read-only, exactly as progressive sliced
threads read `fenc->weighted`.  The pair-interleaving race the shadow
protects against cannot occur under sliced threads (the pair's passes
run sequentially on one job), so no further weight machinery changes are
needed; `x264_analyse_weight_frame` itself is untouched.


### D10: Audit of the remaining `b_sliced_threads` sites — no code change

All `b_sliced_threads` sites outside `encoder/encoder.c` and
`encoder/ratecontrol.c` were audited for the PAFF stride-2 band
geometry; verdicts (recorded so the next reader need not redo this):

- `common/deblock.c:399` + `common/macroblock.c:937` (deblock_strength
  indexing): safe.  Under sliced threads the table is one whole-frame
  array owned by thread 0 with per-thread aliases
  (`deblock_strength[1]` aliased to `[0]`, macroblock.c:379-390);
  workers write disjoint band rows keyed by full `mb_xy` and band-local
  deblock reads only own rows.  The idc=2 band edge is already handled
  by the `slice_table` comparison (deblock.c:342,370-374); PAFF MB
  neighbours are same-parity, and every row of the coding parity is
  rewritten by the current pass, so stale opposite-parity entries are
  never read as neighbours.
- `common/frame.c:845` + `common/frame.c:773` (`frame->i_slice_count` /
  `x264_frame_new_slice`): behaviour-neutral (grill r2 correction of
  this audit's own mechanism): `x264_frame_new_slice` is called only
  for a worker's NON-first slice (`!i_slice_num ||` short-circuit,
  encoder.c:3826) or on a `--slice-max-size` restart (encoder.c:3561),
  and it only touches `i_slice_count` when `i_slice_count_max` is set
  (off by default).  A PAFF+sliced worker writes exactly ONE slice per
  pass and slice-max-size is rejected (D8), so the counter never
  increments past its init value `i_threads` and the limit is never
  consulted — the earlier "accumulates ~3N-2 per pair" accounting was
  wrong (it assumed per-slice increments plain sliced mode does not
  perform; at t1 PAFF the count also stays 1, not 2).
- `common/macroblock.c:379/427` (alloc/free of the above): symmetric,
  no leak.
- NAL buffer sizing (`init_nal_count = i_slice_count + 3`,
  encoder.c:1844): ample — a worker writes one slice NAL per pass;
  SEI/AUD are emitted on `h`.

Correctness of the first two items is exercised by every JM round-trip
cell of the section-5 matrix (a band-edge deblock or neighbour-table
break diverges from `--dump-yuv` immediately); no dedicated test cells.

## Risks / Trade-offs

- [Serial sweep tail costs wall-time at high N] → measured and recorded
  in doc/paff.txt; speedup floor gate at N=4; variant B documented as the
  optimization path if the measurement is bad.
- [Per-field budgeting shifts the CBR trajectory vs frame-thread PAFF]
  → by design (D4); accepted via the HRD simulator + quality matrix, not
  byte comparison. The pair-level per-AU CPB stepping is unchanged, so
  the final buffer model still sees actual NAL sizes.
- [Multi-slice field pictures are new bitstream surface for vendor
  decoders] → hardware-interop streams added to test_paff_hw.sh
  (precedent: the keyint-1 SPS quirk caught exactly this class of issue).
- [Band-geometry off-by-one in frame↔field row translation] → JM
  round-trip over odd/even band splits and non-divisible heights; the
  translation is concentrated in D2's one function.
- [Worker `paff_weighted` sync (D9) silently missed for a new worker
  state] → JM round-trip cells with `--weightp 1` and `--weightp 2`;
  without them a NULL/stale worker shadow is invisible (workers only
  touch the shadow when a P field actually carries a weight).
- [Accumulator zeroing misses a pair-level field] → 2-pass stats and log
  QP compared against `--threads 1` PAFF run in the test matrix; the
  qpa_rc/qpa_aq pair is the complete list (verified against struct usage:
  all other accumulators are per-pass by construction).

## Migration Plan

No migration: the combination moves from hard error to accepted. All
gates on `b_paff`/`b_sliced_threads`; progressive/MBAFF/non-sliced-PAFF
byte-identity is a hard acceptance gate.

## Open Questions

- Numeric acceptance bounds are measure-then-fix (same procedure as
  paff-weightb and paff-pass-threads).  Hard gates (JM bit-exactness,
  HRD/CPB, non-VBV byte-repeat, non-sliced byte-identity) apply from the
  first commit.  The failure criteria for the soft numbers, fixed up
  front:
  1. Quality: BD-rate overhead of sliced-PAFF vs PAFF `--threads 1` is
     acceptable if it is of the same order as the documented progressive
     sliced penalty at the SAME operating point (grill r1: PAFF at N
     means N slices over a HALF-height picture, so the fair reference is
     progressive sliced at N on a half-height progressive clip — equal
     band height in MB rows AND equal slice count per picture; comparing
     against progressive N on the full-height clip would measure 2x
     taller bands and could not separate a geometry/budget bug from
     legitimately thinner bands).  Tolerance: no more than ~1.5-2x the
     reference overhead.  Worse indicates a bug (band geometry or field
     budgets), not a bad number: investigate, do not ship.  The 2N-NALs-
     per-pair overhead asymmetry is recorded alongside the numbers in
     doc/paff.txt.
  2. Speed: at 1080i the speedup must grow monotonically from N=2 to
     N=4 and be >= 1.3x at N=4.  If the serial sweep tail eats the
     growth, variant B (boundary-window parallelization) becomes a
     follow-up change before the feature ships, or the docs record a
     recommended cap (e.g. N=4).
  3. Procedure: numbers are measured on the external clips (env vars,
     as in test_vbv_determinism.sh) and recorded in doc/paff.txt with
     the hardware configuration; the change is not archived while
     criteria 1-2 are unmet.
