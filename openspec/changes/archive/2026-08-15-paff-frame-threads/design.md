# Design: PAFF — frame-threaded encoding (hybrid readiness)

## Context

PAFF forces `i_threads = 1` (validation in `x264_encoder_open`,
`encoder.c:505-510`), and the pair driver asserts `h->i_thread_frames == 1`
(`encoder.c:4442`). The deferral rationale lives in the archived change
`2026-08-15-paff-sei-hrd-rc` (design D3, task 3.1 resolution).

A premise check killed the originally sketched design. The default field
reference list (8.2.4.2.5, implemented in `paff_expand_field_list`) is built
by two parity cursors over the frame list and **alternates parity per pair**:
coding parity p sees `[p(N), !p(N), p(N-1), !p(N-1), ...]`. Both fields of the
adjacent pair are therefore in the active window of every dependent pass, so
a first-field-only phase broadcast has no cross-pair consumer — the only
reader of the first field before pair completion is the second pass of the
same pair, which runs in the same job and must not wait on itself.
Phase-granular readiness alone is a fully serial pipeline (~1.0x).

Two facts make row-granular readiness of the second field cheap:

1. **Row-capable primitives already exist.** `x264_frame_filter`
   (`common/mc.c`) and `x264_frame_expand_border_filtered`
   (`common/frame.c`) already handle field layouts (`FIELD_PIC`,
   `filtered_fld` with doubled stride), and `fdec_filter_row` already
   contains a per-row `plane -> plane_fld` copy for MBAFF.
2. **The deblock cadence already exists.** `paff_filter_row` already runs at
   each same-parity MB-row start of both passes (lag 2 same-parity rows),
   deblocking the previous same-parity row. Attaching the field-layout copy,
   hpel, border expansion and the progress broadcast to that cadence is a
   small extension.

The frame-thread unit is unchanged: one complementary field pair per
frame-thread slot, both field passes coded synchronously by one worker.

## Goals / Non-Goals

**Goals:**
- `--threads N` (N > 1) under PAFF: working frame threads, no deadlock,
  deterministic at fixed N (including `--non-deterministic` semantics),
  conformant output, ~2x on two cores for 1080i-class input (the P-chain
  ceiling, see D1); the plateau beyond two threads is documented.
- Keep non-PAFF bitstreams byte-identical (progressive and MBAFF paths
  untouched).
- Prepare the ground for a later row-granular first field (removing the
  intermediate sweep) without building it.

**Non-Goals:**
- Row-granular readiness for the first field — future work; the intermediate
  sweep stays a phase.
- Slice-based threading / low-latency under PAFF — still rejected.
- Field-granular RC decisions (archived D2 unchanged).
- Any public API change (`x264_param_t`, `x264.h` untouched).

## Decisions

### D1: Readiness model — hybrid (phase for field 0, rows for field 1)

Recorded as ADR-0005.

```
worker A: [field0 N][sweep][field1 N: rows become ready 0,16,32,...][finish]
worker B:                 ......wait......[field0 N+1]  (gated by rows of
                            ^ sweep done:     field1 N through thread_mvy_range)
                              field0 of N usable
                              (only for field1 N, same job)
```

Dependent passes gate through the standard progressive mechanism: at each MB
row start, wait on each reference entry until its completed count covers the
search window (`pix_y + i_mv_range_thread`), then clamp
`thread_mvy_range = completed - pix_y`. Self-reference entries (the pair's
own first field, `fref == h->fdec`) are produced by the same job and are
always complete — waiting on them would deadlock, so they are skipped.

Scaling: the dependency edge is `field1(N) rows -> field0(N+1)` with a
bounded row lag. Both passes of a pair are serial inside one job and every
pass references both fields of the previous pair, so the pipeline alternates
`pass1(N) ∥ pass0(N+1)`: at most two passes of consecutive pairs overlap and
a P-chain tops out at ~2x (pair time / pass time) minus MV-clamp losses, no
matter the thread count. B-pyramid siblings gate on the same anchor rather
than on each other, so B-heavy hierarchies overlap more. This ceiling is
different in shape from progressive frame threads (which scale past 2x); it
is documented in `doc/threads.txt`, and any speedup > 1x ships (D7).

Alternative rejected: phase-granular only (original sketch) — see Context;
~1.0x, pointless. Alternative deferred: row-granular both fields (dropping
the intermediate sweep) — larger surgery (first-field deblock must also run
ahead of the second pass), everything built here carries over.

### D2: Per-parity counters and the MV-range machinery

`x264_frame_t` gains `i_lines_completed_fld[2]`, sharing the existing
`mutex`/`cv` of the frame, in **field lines** (the field's own line count):

- first-field parity: initialized -1; set to the sentinel (10000, as
  progressive end-of-frame) at the end of the intermediate sweep, guarded by
  `b_kept_as_ref` and `i_thread_frames > 1` (mirroring the guard in
  `fdec_filter_row`);
- second-field parity: initialized -1; advanced from `paff_filter_row`'s
  row-cadence work (D5) to `filtered_rows*16 - X264_THREAD_HEIGHT` in **field
  lines**, mirroring the progressive broadcast `mb_y*16 - X264_THREAD_HEIGHT`
  (16 lines for the in-flight hpel batch plus the 8-line safety: 4 lines the
  next row's deblock may still modify + 3 taps of the 6-tap filter, rounded).
  The margin guarantees `[0, completed)` field lines are final, borders and
  hpel included. Set to the sentinel at `paff_frame_finish`.

New helpers `x264_frame_cond_broadcast_fld` / `x264_frame_cond_wait_fld`
(`common/frame.c`); the progressive `i_lines_completed` counter and its
callers are untouched. Alternative rejected: encoding both parities into the
single existing counter (field1 offset trick) — opaque and fragile next to
MBAFF usage of the same field.

**MV range / determinism.** Because rows of the second field are exposed
partially, PAFF now uses the standard thread machinery, unchanged from
progressive: keep the `i_mv_range_thread` defaulting that
`i_thread_frames > 1` triggers, with the default formula computed from the
**field height** (`param.i_height/2`) since wait thresholds are in field
lines; clamp `thread_mvy_range` from completed rows at the wait sites; as in
progressive, `b_deterministic` (the default) discards the clamp in favor of
the fixed `i_mv_range_thread`, while `--non-deterministic` keeps the clamped
(timing-dependent, slightly higher-quality) range. The
normative contract is determinism at fixed N. Byte-identity to `--threads 1`
is **not** expected and not checked: the MV-range clamp changes motion
search, exactly as progressive `--threads N` differs from `--threads 1`.

### D3: Dispatch and the caller/job boundary

The PAFF pair driver runs inline in `x264_encoder_encode` today. Enabling
frame threads splits it:

**Caller thread (serial, before dispatch):** fenc setup, frame-type
decision, `reference_hierarchy_reset`/MMCO population, pair-level
`reference_build_list`, `ratecontrol_start`, `x264_thread_sync_ratecontrol`,
the first field's DPB marking (D20: MMCO opcode-1 application and the
sliding-window eviction, including `x264_frame_shift` +
`x264_frame_push_unused`), `i_frame_num` advancement, AUD/headers writing,
job dispatch.

**Pool job (`paff` work item, `h == thread_current`,
`b_thread_active = 1`):** the pair body — per-pass list expansion, `slice_init`
+ SEI + `slices_write`, sweeps, restores, `paff_frame_finish`, returning
through `encoder_frame_end`'s existing `x264_threadpool_wait( h->threadpool,
h )` harvest (it keys on the work-item argument). The job writes **only**
what progressive `slices_write` writes: `out`, `stat.frame`, `mb`, `fdec`
pixels/progress. Everything shared is either passed by value (job
parameters) or written serially by the caller before dispatch (D3.3).

Sub-decisions:

1. **Marking snapshots.** The caller computes the first field's marking
   before dispatch and prepares **two** pair-list snapshots: pre-marking (for
   pass 0) and post-marking (for pass 1, evicted pairs removed). The P-pair
   past-list rebuild (the FrameNumWrap-descending sort over
   `h->frames.reference`, 8.2.4.2.2) moves caller-side into the pass-0
   snapshot for the same reason. After this, the job never reads
   `h->frames.reference` or the unused-frame pool at all. (Today the driver
   mutates the snapshots in place between passes; the eviction inputs —
   `sh.mmco`, DPB, `b_kept_as_ref` — are all known before coding.)
2. **`i_frame_num`.** The canonical counter advances caller-side before
   dispatch (as progressive does between `slice_init` and dispatch), so
   `thread_sync_context`'s bulk copy at the next encode call always sees an
   up-to-date value. The slice headers need the **pre-increment** value: the
   job receives it as a parameter and overrides `sh.i_frame_num` after each
   `slice_init` (the driver already overrides `i_poc`/`b_field_pic`/
   `i_first_mb`/`i_last_mb` the same way). The job never writes
   `h->i_frame_num`.
3. **List metadata: caller-side expansion.** (Recorded as ADR-0006.) A B
   pair reads older pairs'
   per-parity metadata (`i_ref[]`, `ref_poc[]`, `i_poc_l0ref0[]`) when
   building `map_col_to_list0` and the direct-mode flag. Progressive
   guarantees this data is ready by writing it in the caller (`slice_init` →
   `x264_macroblock_slice_init`, serial, before dispatch). PAFF keeps the
   same invariant: the caller performs **both** passes' field-list
   expansions before dispatch (the inputs are the two snapshots from D3.1;
   expansion reads no pixels) and writes the per-parity metadata onto
   `h->fdec` serially. The expanded per-pass lists and parity maps travel in
   a job-parameter struct (`x264_paff_job_t`) on `x264_t` (safe from the
   `thread_sync_context` memcpy: written after this slot's sync, before
   dispatch, and only read by the job); the job loads each pass's stored
   lists into `h->fref`/`mb.pic` at pass start instead of expanding.
   Storing the lists on `x264_frame_t` was rejected: frames are pooled, the
   data lives only for the job's duration, and other pairs read only the
   per-parity metadata that already lives on `fdec`. No lists-published
   flag, no cross-job metadata wait: the wait graph is row waits only. Rejected alternative:
   publish per-parity metadata from inside the job with a "lists published"
   broadcast — the parity-1 metadata only exists after pass-0 coding, so the
   wait would last ~half of the older job and add a second wait kind to the
   deadlock argument.
4. **`sh` written per pass, no snapshot.** The job writes `h->sh` directly:
   each pass runs `paff_slice_init` (`slice_header_init` plus the per-pass
   overrides) against the live struct, and the pair-level view is restored
   at job end for frame-end consumers — the restore the driver already
   performs. `thread_sync_context` memcpy's the region containing `h->sh`
   into the next slot concurrently with the job, so every field the next
   slot reads before overwriting must be race-benign. The 6.1 audit found
   exactly one such consumer — `reference_update`'s MMCO application — and
   it is a no-op for every observable state (pair-level, pass-0, pass-1, or
   any torn combination) because the pair's caller already applied the
   marking (D3.1); all other `sh` fields are overwritten before read. The
   local-snapshot variant (both `slice_init` calls against a copy, a single
   `h->sh` write at job end) was rejected as unnecessary: it would relocate
   the writes, not shrink the audited set.
5. **Reads of memcpy-region fields inside the job** (e.g.
   `i_cpb_delay_pir_offset` for per-field SEI) must be finalized by the
   caller before dispatch — the pool's internal lock gives the needed
   happens-before. This is an audit item of D6.

Deadlock freedom: the wait graph is a DAG over pair order — row waits go
to strictly older pairs with monotone counters, the self-entry is skipped,
and each job's own progress never waits on younger pairs. The pool always
makes progress.

### D4: Wait sites — parity maps and field-coordinate thresholds

Two sites in `encoder/analyse.c` wait on references:

- the per-row-start loop (`x264_frame_cond_wait` on `h->fref[i][j]->orig`,
  clamping `thread_mvy_range`): for PAFF, wait via
  `x264_frame_cond_wait_fld` on `fref[i][j]->orig` with the per-entry parity
  (`mb.pic.i_fref_parity[j]` / `i_fref_parity_l1[j]` — already maintained
  for MC), threshold converted to field lines from the MB position
  (`(i_mb_y >> 1) * 16 + i_mv_range_thread` shape; chroma planes wait on the
  same luma counter as progressive does), skip entries where `fref ==
  h->fdec`, clamp `thread_mvy_range = completed - pix_y_field`;
- the NDEBUG MV-out-of-range check (indexing
  `h->fref[l][ ref >> MB_INTERLACED ]->orig`): use the parity map for PAFF
  lists, compare the MV (already in field units per MB_INTERLACED) against
  the per-parity counter.

`x264_analyse_weight_frame` reads reference planes under the same row gating
(`pix_y + thread_mvy_range` in field lines); audit its call sites so no
weighted-read path bypasses the waits (task 4.3).

PAFF keeps the existing frame-geometry vertical MV limits (the progressive
else-branch, sized by the full `i_mb_height` — about 2x wider than a field
needs): tightening them to field geometry would change `--threads 1` output
and break the bit-identity invariant of tasks 2.3/5.2. Only
`thread_mvy_range` is computed in field units; it is the binding clamp via
`X264_MIN3(..., 4*thread_mvy_range)`. The pre-existing over-search into the
padding is recorded in `doc/paff.txt` as future work (task 8.1), not fixed
here.

### D5: Sweep restructure — row cadence for the second field

The intermediate `paff_sync_references` (between passes) stays full-frame:
copy all rows `plane -> plane_fld`, hpel + borders for both parities (the
stale second-field rows are never read before the second pass overwrites
them), then the phase broadcast for the first-field parity.

The **final** sweep disappears as a full-frame pass. Instead, during the
second pass, `paff_filter_row` (already invoked at each same-parity row
start, deblocking row `mb_y-2`) additionally performs, for the just-deblocked
coding-parity rows: the `plane -> plane_fld` copy, `x264_frame_filter` +
`x264_frame_expand_border_filtered` (with `b_end` at the pass end), and the
row-granular broadcast (D2). Residual work at `paff_frame_finish`: the last
deblock-lag rows, the sentinel broadcast for both parities, and quality
measurement. Even-parity (first-field) rows are byte-stable during the
second pass (field deblock writes only its own parity's rows; field edges are
>= 2 frame rows apart), so the intermediate sweep's even-row output survives
untouched.

`x264_frame_filter` under field coding early-returns on odd `mb_y` and its
field branch filters **both** parities (a two-iteration loop over the doubled
stride). Row-cadence calls therefore use even-aligned `mb_y` and re-filter
the first field's rows along with the second's. The first field's `plane_fld`
rows are not modified during the second pass, so the re-filter is idempotent
(byte-identical, keeping the task-2.3 gate) at the cost of ~2x hpel work in
those calls; parameterizing `frame_filter` by parity is deferred unless
profiling shows the overhead. Whether the SATD `integral` plane is allocated
or used under PAFF is a task-2 audit item; if used, its row-cadence update
follows the same even-aligned cadence.

This must be a pure rescheduling at `--threads 1`: per-row copy/hpel/border
produce byte-identical output to the full sweep (row operations are
row-local), asserted by the task-2 regression gate.

### D6: Cross-thread context and rate-control sync audit

`thread_sync_context` memcpy's the context region (`i_frame .. mb.base`)
between slots at the next encode call, concurrently with the in-flight job.
With D3's boundary (job writes only out/stat.frame/mb/fdec + per-pass
`h->sh` writes, pair-level `h->sh` restore at job end) the audited questions are: (a)
is the job-end `h->sh` restore guaranteed to happen before the *next*
dispatch reads it? (No — the restore is only ordered before
`encoder_frame_end`'s harvest; but the caller overwrites the fields it
consumes (`sh.i_type`, mmco population) before dispatch, mirroring
progressive — verify each consumer); (b) per-parity frame state
(`i_field_bits[2]`, `b_field_kept_as_ref[2]`, per-parity `i_poc_l0ref0[]`)
lives on `x264_frame_t`, shared by pointer, not memcpy'd — verify no torn
reads; (c) `x264_thread_sync_ratecontrol` operates per "RC frame" = pair
(archived D2), matching caller-side serial `ratecontrol_start` ordering;
per-AU VBV stepping state (`previous_cpb_final_arrival_time`,
`initial_cpb_removal_delay*`) updated inside the job must be confirmed
thread-safe through the existing `cur/next` copy pattern; (d) `i_frame_num`
canonicalization (D3.2) — confirm no other memcpy-region field is
job-written.

Verification tool: TSAN build (`-fsanitize=thread`) running a small PAFF
encode at `--threads 4`, plus stress (loop 100x) for nondeterminism at fixed
N.

### D7: Validation, docs, merge criteria

- `x264_encoder_open`: remove the PAFF `i_threads = 1` forcing and its
  warning; keep the sliced-threads rejection.
- `doc/paff.txt`: rewrite the Threading section (hybrid readiness model,
  determinism contract, no byte-identity, future work: row-granular first
  field, low-latency).
- `doc/threads.txt`: PAFF note (row-granular second field, MV-range clamp
  semantics, benchmark table).
- `AGENTS.md`: update the PAFF threading facts ("PAFF forces i_threads=1",
  determinism note) to the new reality.
- Regression: JM round-trip for `--threads 2/4` PAFF runs; threaded-vs-
  single-threaded PSNR/bitrate tolerance (same tolerance used for
  progressive threads N vs 1); determinism check (encode twice per N,
  compare).

**Merge criteria:** correctness blockers only — JM conformance, fixed-N
determinism, quality regression beyond tolerance, TSAN/stress failures, or a
hang. Throughput is not a merge blocker: any speedup > 1x ships, and the
measured numbers are recorded in `doc/threads.txt` as-is.

## Risks / Trade-offs

- [Row-cadence correctness: hpel reading not-yet-deblocked neighbor rows,
  field-coordinate threshold arithmetic] → D5 keeps the existing 2-row
  same-parity deblock lag and reuses `x264_frame_filter`'s existing
  FIELD_PIC handling; task-2 gate asserts `--threads 1` bit-identity (pure
  rescheduling); NDEBUG wait-site check (D4) catches range violations in
  test builds.
- [`thread_sync_context` region races] → D3's boundary removes the job's
  shared writes by construction; D6 audits the residual consumers; TSAN is
  a dedicated gate before merge.
- [Caller-side expansion grows the serial prologue] → expansion is list
  arithmetic only (no pixel reads), negligible next to coding; moving it out
  of the job also shortens the critical path of the pass pipeline.
- [Throughput plateaus beyond two threads on P-chains] → the designed
  ceiling (D1), not a regression: documented in `doc/threads.txt`; any
  speedup > 1x ships (D7).
- [Restructured dispatch breaks non-PAFF output] → non-PAFF paths take the
  same branch shapes as before; bit-identity of progressive/MBAFF streams is
  asserted by the regression matrix re-run.
- [Byte-identity expectations] → explicitly not required (D2); the quality
  tolerance gate replaces it.

## Migration Plan

Single commits per task section, in dependency order (counters and
row-cadence sweep first, dispatch split and wait sites next, validation
removal last), each keeping `--paff --threads 1` regression-green; the
forced-single-thread behavior simply disappears at the final task — callers
requesting N threads then get them (previously: warned down to 1). Rollback =
revert the change; no on-disk or API migration.

## Implementation audit results (tasks 6.1/6.2/6.3)

Recorded after implementation; these complement D3/D6.

**Deferred eviction push.** The D20 eviction removes pairs from
`frames.reference` in the caller, but a pass-0 expanded list may still
reference an evicted pair (the decoder applies the first field's marking
only after building that field's list; reachable e.g. `--bframes 0 --ref N`
where the sliding window evicts an in-window pair).  An immediate
`push_unused` would let the frame be recycled while the job still reads it.
The push is therefore deferred to the slot's harvest (`paff_evicted`,
released in `encoder_frame_end` / `x264_encoder_close`).

**memcpy-region audit (6.1).** For every field of the
`i_frame .. mb.base` region the job writes, the next slot's
read-before-overwrite consumers are safe:

- `h->sh` (per-pass view, pair-level restored at job end): the only
  read-before-overwrite consumer on the next slot is `reference_update`'s
  MMCO application, and every observable state (pair-level, pass-0,
  pass-1/suppressed, or any torn combination) is a no-op because the pair's
  caller already applied the marking.  All other `sh` fields are overwritten
  before read (type decision, `reference_hierarchy_reset`, the job's
  `paff_slice_init`).
- `h->i_nal_type`, `h->i_ref[]`, `h->fref[]`, `h->mb.*` (pic maps,
  `b_direct_auto_write`, caches), `h->stat.frame`: overwritten by the next
  caller (`reference_build_list`, `macroblock_slice_init`, `slices_write`
  memset) before any read; `encoder_frame_end` consumers read them only
  after the harvest wait.
- `h->i_frame_num`, `h->i_idr_pic_id`, `h->b_ref_reorder`, `h->b_sh_backup`/
  `sh_backup`: caller-only writes (job receives values via `paff_job`).
- `fdec` metadata read by later pairs (`i_ref`/`ref_poc`/`i_poc_l0ref0`/
  `i_field_avail`, `i_frame_num`, `i_delta_poc`, `inv_ref_poc`): published
  by the caller serially before dispatch (the last three moved out of
  `paff_slice_init`/`x264_macroblock_slice_init` after TSAN flagged
  job-side writes racing later pairs' reads).
- `i_cpb_delay_pir_offset` (per-field SEI): finalized by the caller before
  dispatch; never job-written.

**Rate-control sync (6.2).** RC runs pair-level in the caller
(`ratecontrol_start`) like progressive; the per-AU VBV stepping state
(`previous_cpb_final_arrival_time`, `initial_cpb_removal_delay*`,
`nrt_first_access_unit`) is written only in `x264_ratecontrol_end`
(harvest thread, after job completion) and propagated by the existing
`cur -> next` copies in `x264_thread_sync_ratecontrol`; the job never
writes them.  Per-field AU sizes travel on `fdec->i_field_bits[]` +
`out.i_paff_au_boundary`, read after harvest.

**TSAN (6.3).** `-fsanitize=thread` build, `--paff --threads 4`.
Progressive `--threads 4` shows the same known-benign classes
(`thread_sync_context` memcpy vs job writes to `sh`/mb scratch/cabac,
~100 warnings); PAFF shows the same classes plus, initially, three real
races, all fixed: (a) job-side writes of `fdec->i_frame_num`/
`i_delta_poc`/`inv_ref_poc` (moved to the caller), (b) a no-op
`fdec->i_poc` write in the job (removed), (c) the `ref_blind_dupe`
uninitialised-read bug below.  `i_field_avail` writes were made
same-value-conditional so no writer ever races the mvpred readers with a
different value.  One residual known-benign class remains:
`weights_analyse` (lookahead thread) vs `adaptive_quant_frame` (caller)
on recycled frames' `i_pixel_sum/ssd` -- generic x264 machinery,
untouched by this change, observed once in ~1000 encode runs on both PAFF
and non-PAFF paths.

**Pre-existing bug found and fixed (required for the determinism
contract).** `h->mb.ref_blind_dupe` was never assigned under PAFF (the
duplicate block is skipped), stayed 0 from the zeroed context, and
`mb_analyse_inter_p16x16`/`p8x8` therefore treated `i_ref == 0` as a
duplicate, taking the refdupe ME branch whose start MV is read from
uninitialised analysis-struct stack state.  Deterministic at
`i_threads == 1` (same call history every run), nondeterministic across
pool workers.  Fixed by assigning `ref_blind_dupe = -1` under PAFF;
`--paff --threads 1` output changes accordingly (new regression
baseline), slightly smaller files.

**Review findings (post-implementation, tasks 9.1-9.3).**  Two
weighted-reference bugs were found by review and fixed (9.1/9.2): the
lazy weight-plane fill computed its extent in frame rows from a
field-line `end` and used the MBAFF i_padv, leaving the lower ~half of
the weighted plane as scratch memory read by motion estimation
(reproducible as a 0.16 dB t1-vs-t4 PSNR divergence on a fade clip at
weightp 2; the matrix had no brightness-trend clip, so weights never
activated); and the weighting slot was indexed MBAFF-style (`j >> 1`)
although PAFF's pass-1 complementary entry shifts the field-entry
parity mid-list (pre-existing from the field-pictures change).
The determinism blocker found by review (9.3) was root-caused
with rr record/replay and fixed: `reference_build_list` early-returns
for I slices before the PAFF `ref_blind_dupe = -1` assignment, so IDR
pairs kept the slot context's stale (calloc-zero) index; the pair's
P-coded second field then took the weightp-refdupe ME branch, whose
start MV is seeded from uninitialised analysis-struct stack bytes --
i.e. the executing pool worker's stack history, which is why every
concurrency-shaped experiment (serialization, full-completion waits,
single-threaded lookahead, ASLR off, single CPU, arena pinning,
valgrind/MSan) was neutral and only -ftrivial-auto-var-init=pattern
determinized the output.  The assignment is hoisted above the early
return; fixed-N determinism is restored at N=2/4/8 (repeated-run
byte-compare), progressive/MBAFF outputs stay bit-identical, and the
PAFF `--threads 1` baseline moves a second time (garbage-seeded IDR
second-field decisions removed), same precedent as the first
ref_blind_dupe fix.

**Review follow-ups (2026-08-15, second pass).**  The D3.4 wording was
brought in line with the as-built code (the job writes `h->sh` per
pass; the local-snapshot variant is recorded as rejected with the 6.1
audit as the argument).  Nits fixed: the never-read
`x264_paff_job_t.i_nal_ref_idc` field removed (the job codes against
the live `h->i_nal_ref_idc`), the redundant `i_lines_completed >= 0`
guard dropped from `x264_frame_cond_wait_fld` (the counter starts at
-1 and only grows, so a negative threshold already fails the wait
test), stray double blank lines removed.  9.4 closed the matrix gap:
the fade (weights on 100% of P pairs) and mid-stream scenecut clips
now run the 5.3/6.4/7.2 gates -- t2/4/8 no-hang, 12x byte-identical
per N, t1-vs-t4 Y-PSNR divergence 0.001-0.011 dB against the 0.000-
0.004 dB progressive same-clip reference.  Docs re-check:
`doc/threads.txt` (throughput table) is unaffected by the 9.1-9.3
fixes (no hot-path change); the `doc/paff.txt` RD claims were
re-measured with `tools/test_paff_rd.sh` post-fix (CRF sweep: PAFF
~+3.0 dB vs MBAFF, ~+0.5 dB vs prog, MBAFF ~-2.5 dB vs prog at
matched bitrate); the detailed-clip approximations stand, and the
blurred-clip figure was corrected from ~+3.5 to ~+3 dB (the old
example point no longer reproduces on either side; the PAFF curve
itself is unchanged -- 45.7 dB @441 kb/s vs the recorded 45.5).

## Open Questions

- None blocking. (Row-granular first field and low-latency slicing are
  deliberately deferred to future changes.)
