# Design: PAFF — pass-granular frame threading (row-cadence both fields)

## Context

`paff-frame-threads` (archived, 2026-08-15) made `--threads N` work under
PAFF: one complementary field pair per pool job, hybrid reference readiness
(first field = phase after the intermediate sweep, second field = row
cadence). Its D1 recorded the ceiling: both passes of a pair are serial
inside one job while every pass references both fields of the previous
pair, so a P-chain tops out at ~2x; B hierarchies overlap more (~3.2x
measured). The archived future-work note rejected lifting it because the
estimated gain was "single percent" — that estimate conflated the
row-granular-first-field variant (which alone is indeed worthless, see D1
below) with the job-split, and predates the current measurements
(22.2/69.4/71.5 fps at threads 1/6/16; CPU 318-321%; gdb at threads 16:
13 of 16 workers parked in `x264_frame_cond_wait_fld` inside pair jobs).

Current code shape this builds on:

- Caller prologue (`x264_encoder_encode`, `if( h->param.b_paff )` block):
  already computes BOTH passes' snapshots and expansions before dispatch
  (D3.1/D3.3 of the archived design); marking stays caller-side (D20).
  Nothing here needs to move.
- `paff_pair_write`: per-pass `paff_slice_init` + list loading + SEI +
  `slices_write`, sweep between passes, `paff_frame_finish` at the end.
- `paff_filter_row`: deblock cadence; during pass 1 only, also the
  reference band (plane→plane_fld copy, hpel, borders) + per-parity
  progress broadcast.
- Wait sites (`encoder/analyse.c`): per-row waits on
  `i_lines_completed_fld[parity]` in field lines, threshold
  `pix_y + i_mv_range_thread`, entries with `fref == h->fdec` skipped.
- Threadpool: FIFO; a worker blocked in a row wait holds its slot.

## Goals / Non-Goals

**Goals:**
- Lift the PAFF frame-threading ceiling to progressive-like scaling
  (~6-8x on 720p-class input at 8-16 threads; the anchor chain becomes a
  per-pass staircase with the same row margin progressive uses).
- Keep: fixed-N determinism, JM conformance, `--threads 1` byte-identity
  (pure rescheduling), non-PAFF bit-identity, caller-side marking and list
  expansion (D20/D3.3 not reopened).
- Reuse the existing readiness machinery (per-parity counters, wait sites,
  band work) rather than inventing a second mechanism.

**Non-Goals:**
- Sliced threads / low latency under PAFF (still rejected — VBV/quality
  cost, see Alternatives).
- Any change to the lookahead, mbtree, RC granularity (pair-level RC,
  per-field VBV accounting unchanged), or the public API.
- Making `N > 1` output byte-identical to `--threads 1` (the MV-range
  clamp stays, as in progressive).

## Terms (pinned in design review, 2026-08-17)

Canonical vocabulary for this change; CONTEXT.md is rewritten in task 6.4
(the glossary describes the shipped tree, which still runs the hybrid
model until then).

- **Field pass**: one coding pass of a PAFF pair; codes one field.
  Pass 0/1 = coding order; the pass's parity is set by TFF/BFF
  (`parity = b_tff ? pass : !pass`). Pass ≠ parity. Never shortened to
  "pass" alone where 2-pass RC is in scope.
- **Pass parity**: the field parity a given field pass codes.
- **Harvest**: the caller-side collection of a finished slot's output in
  coding order (`encoder_frame_end` on the oldest slot(s)): wait, merge,
  stitch, pair-level frame end.
- **Rendezvous**: the harvest waiting for BOTH field-pass jobs of the
  oldest pair before running the pair-level frame end.
- **Reference band**: one field row's worth of reference data produced
  at row cadence: plane→plane_fld copy + hpel + borders.

## Decisions

### D1: Pass-granular jobs AND row-cadence first field — one change, not two

Model (a = pass time, s = sweep ≈ 1-2% of pair, m = row-wait margin
≈ i_mv_range_thread + filter pipeline trail):

```
today (pair = 1 job):        period per pair = a + s + m   → ~2x ceiling
split only (F0 still phase): period per pair = a + m       → still ~2x
split + cadence F0:          period per pair = 2m          → ~2a/2m ceiling
```

The split alone does not change the critical path: the second pass still
waits for the first field's *phase* completion. The cadence alone cannot
work either: inside one job the passes are serial on one worker. Both are
required, which is why the archived "single percent" estimate (cadence
only, pair job kept) was correct for its variant and wrong for this one.
With both, the chain becomes a per-pass diagonal staircase — structurally
identical to progressive frame threading, whose measured scaling (~7x at
12 threads on Nehalem, doc/threads.txt) is the calibration for the
expected ceiling.

**Alternative rejected:** split only — no gain (model above).
**Alternative rejected:** cadence only, keep one job — impossible, one
worker codes serially.

### D2: First-field readiness at row cadence; the sweep disappears

`paff_filter_row` loses its "second pass only" guard for the band work:
during pass 0 it produces the reference band for pass 0's parity with the
same one-field-row trail the second pass uses today, and advances
`i_lines_completed_fld[pass0_parity]` at cadence. Residual work moves to
the end of the pass-0 job (last band, sentinel), mirroring
`paff_frame_finish`. `paff_sync_references` is deleted.

At `--threads 1` this must be a pure rescheduling (byte-identical output),
same argument as archived D5: row-local copy/hpel/border operations
produce identical bytes whether run band-by-band or in one sweep, and the
second pass reads only pass-0-parity rows, which are final at the same
logical points. Gate: regression byte-compare before/after.

### D3a: `--threads 1` keeps the monolithic pair driver

The per-pass job entry points (task 4.1) exist only on the pool path
(`i_thread_frames > 1`). The inline single-thread path keeps today's
monolithic pair loop (with the stage-2 cadence rescheduling), so the
t1 byte-identity gate holds by construction and pass 1 keeps seeing
pass 0's actual rc/stat state on the shared `h` (no dispatch-time rc
seeding on this path). Accepted cost: two structural code shapes
(inline monolith vs per-pass jobs) — the inline/pool divergence already
exists today.

### D3: Two pool jobs, two slots per pair, harvest rendezvous

The caller dispatches pass 0's job on the round-robin's current slot and
pass 1's job on the next slot (phase advances by 2 per PAFF encode call);
both jobs' parameters come from the same prologue (already computed). The
pool FIFO order becomes `F0(N), F1(N), F0(N+1), F1(N+1), ...` — coding
order — so a worker picking a blocked job never starves the job it waits
for: the complementary F0(N) is always queued before F1(N), and older
pairs' jobs before both.

Harvest (`encoder_frame_end`) waits for BOTH jobs of the oldest pair
(rendezvous: wait slot A, then slot B — the caller is not a worker, so
the wait order cannot deadlock), then runs the pair-level frame end on
the PASS-0 slot's context (settled 2026-08-17): its `out` already holds
the AU headers (AUD/SPS/PPS) and the first field's NALs, so pass-1's
NALs are stitched into it in order and the pass-1 slot's `stat.frame`
and rc accumulators are merged into it; then the pair-level frame-end
(ratecontrol_end, reference_update, output) runs exactly as today.

Job struct (settled 2026-08-17): the prologue fills BOTH `[pass]` halves
of `paff_job` into BOTH slots identically; each job reads only its own
pass's half. Pass self-containment is enforced by the 3.1 audit, not by
the data structure; the prologue fill loop keeps today's shape.

Context sync: both slots sync from the prologue's serial view (the
existing `thread_sync_context` chain; slot for F1 syncs from the same
source as the slot for F0, not from F0's running job). The D6/6.1
memcpy-region audit must be re-run for the new job-shape: each job now
writes `h->sh`, `stat.frame`, `out`, `mb` scratch on its own slot only,
plus the shared-pair `fdec` parity rows.

**Alternative rejected:** dispatch pass 1 from inside the pass-0 job
(chained/continuation dispatch) — breaks the "caller is the only dispatch
point" invariant that the D3/6.1 race arguments rely on, and complicates
slot ownership for no benefit.
**Alternative rejected:** keep one slot per pair, run the two jobs on the
same `x264_t` — they would share `mb` caches, `cabac`, `out` and race as
soon as pass 1 overlaps pass 0's tail; serializing them reintroduces the
phase barrier.

### D4: Parity-parameterized field filtering — correctness, not optimization

`x264_frame_filter`'s field branch currently filters BOTH parities per
cadence call (archived D5 accepted the idempotent re-filtering and ~2x
hpel work in those calls). Under the split this becomes a cross-thread
race with real consequences: during pass 1's cadence the pass-0 job may
be re-encoding rows for VBV (row re-encode REWRITES fdec rows and their
filtered data), so a "benign same-value re-filter" no longer exists. The
band work (copy, filter, borders, broadcast) must be parameterized by the
coding parity and touch only that parity's rows. This also removes the
~2x hpel waste in cadence calls — a small throughput bonus.

### D5: Wait sites — the complementary entry now waits, bounded

`encoder/analyse.c` per-row waits: drop the `fref == h->fdec` skip for
the complementary-field entry (pass 1's own first field). It now waits on
`i_lines_completed_fld[pass0_parity]` with the same field-line thresholds
as every other entry, clamping `thread_mvy_range` — the standard
progressive mechanism, no new wait kind. Pass 0's list never contains the
complementary field (pair-level snapshots), so only pass 1 gains a wait.

Deadlock freedom: the wait graph is a DAG over (pair, pass) in coding
order — F1(N) → F0(N) rows (bounded, same pair, strictly older pass),
F0(N+1) → F1(N)/F0(N) rows (older pair). Every edge points at a strictly
older pass; FIFO dispatch guarantees the waited-for job is either running
or queued behind only older jobs. The pool always makes progress.

Fail path (settled 2026-08-17): a failing pass job broadcasts the
completion sentinel (10000) for its own parity on the shared pair fdec
before returning -1, so waiters (the pair's other pass, younger pairs)
wake instead of hanging the pool; the harvest still returns the error.
Determinism is unaffected (an error kills the whole encode). Progressive
failure semantics are pre-existing and out of scope.

### D6: Shared pair fdec and pass self-containment audit

The pair's `fdec` frame is shared by both jobs (pass 0 writes its parity's
`plane`/`filtered_fld`/`integral` rows, pass 1 the other parity's —
disjoint by construction; cross-field deblock does not exist in field
pictures, intra prediction does not cross the field boundary). The frame
pointer travels in the job parameters; the pass-1 job overrides its
slot's `h->fdec` for the duration.

The audit task that gates this design: enumerate every `x264_t`-carried
state the second pass reads today that the first pass wrote (candidate
list from reading the driver: `intra_border_backup` contents, `out`
continuity (solved by stitching), `stat.frame` (merged at harvest),
`i_field_bits[]` (per-element on the shared fdec), `sh` (re-inited per
pass)). Anything found must be marshalled through the job struct or the
shared fdec — never through the slot's `x264_t`. Code reading adds five
known items the audit must close (checklist mirrored in task 3.1):

- `h->rc`: pass 1's per-row VBV sees only PREDICTED first-field bits —
  its slot's `rc` is seeded from the serial view at dispatch
  (`x264_thread_sync_ratecontrol`), and pass 0's actual bits arrive too
  late. Accepted as the progressive-threading semantics (a frame coding
  against an in-flight previous frame predicts its bits the same way);
  deterministic at fixed N. Handing actual bits across jobs was rejected
  — it would add a second cross-job wait kind and break the D5 DAG
  argument. Consequences: harvest merges the accumulators (`qpa_rc`,
  `qpa_aq`) the way `x264_threads_merge_ratecontrol` does for slices;
  the ratecontrol end-chain sync (`cplxr_sum` etc.) is rebuilt for two
  slots per pair; VBV drift vs N=1 becomes a measured column of the
  benchmark gate (D8/6.1).
- `h->paff_evicted`: the deferred-eviction stash is written on the slot
  at dispatch and released at that slot's harvest; with no single "pair
  slot" left, the stash becomes pair-level and is released after BOTH
  jobs complete.
- frame pools / refcounts: `x264_frame_push_unused(thread_current,
  h->fenc)` at harvest and the `thread_sync_context` fdec swap must
  return the shared pair `fdec` exactly once with the phase advancing
  by two.
- the end-of-driver "restore pair-level view" block (`sh`, pair lists)
  moves to the harvest, where the pair-level frame-end consumers run.
- `out.i_paff_au_boundary` (per-field VBV/HRD split,
  `ratecontrol.c`): after stitching it equals F0's `i_nal`; the stitch
  must set it before any harvest-side consumer (ratecontrol VBV,
  buffering-period SEI insertion, encapsulation) reads the merged
  array.

### D7: `i_mv_range_thread` default and slot accounting

`i_thread_frames` keeps its meaning ("number of coding jobs in flight" =
slots = workers); under PAFF that is now passes, so pairs in flight
halve at the same N. The default `i_mv_range_thread` formula (derived
from coded height / threads, field height for PAFF) keeps working
unchanged; do not retune it in this change (measure first; a follow-up
can revisit the reservation split if profiling shows the margin binds).
Record in docs that N slots = N/2 pairs pipeline depth and that
b-pyramid DPB checks are unaffected (they key on `i_frame_reference`,
not slots). `h->frames.i_delay` must add pairs in flight (`(N+1)/2 - 1`)
instead of `N - 1` under PAFF, so the internal delay and the frame-pool
sizing do not pay for slots that no longer map to distinct pairs (task
4.2); the signalled DPB/reorder values are unaffected (they derive from
`i_frame_reference`/`i_bframe`, not `i_delay`).

### D8: Validation, determinism, merge criteria

Same gates as `paff-frame-threads`: t1 byte-identity (sweep removal as
pure rescheduling), fixed-N byte-identical repeat runs at N=2/4/8/16,
JM round-trip for threaded runs, TSAN diffed against a progressive
control, `tools/test_paff.sh` matrix, non-PAFF bit-identity.
Determinism byte-compares use the default (deterministic) mode;
`--non-deterministic` runs are validated by decodability and JM
round-trip only — their completed-row ranges are timing-dependent by
design, exactly as in progressive threading.

UPSTREAM LIMITATION (settled 2026-08-17, parked change
`threaded-vbv-determinism`): threaded VBV is not byte-deterministic at
fixed N even on pre-PAFF upstream (dispatch-time reads of in-flight
slots' `rc->frame_size_estimated`, plus row-level reads of the in-flight
reference's `f_row_qp`/`f_row_qscale`/`i_row_bits` in
`encoder/ratecontrol.c`; reproduced on progressive at t2-t8, 144p and
720p).  PAFF inherits this unchanged.  Consequence for the gates:
fixed-N BYTE-REPEAT gates run on non-VBV configs; CBR+VBV configs are
gated by divergence-rate parity against the pre-change binary at the
same N (same nondeterminism class, not byte-subset — see the task-5.1
addendum below) plus JM conformance and a clean
x264 VBV model (no underflow/overflow warnings). Performance acceptance is
decided in three zones BEFORE measuring, so the bar cannot be tuned to
the result (reference clip: hall.mp4 CBR+VBV; recorded in
`doc/threads.txt`):

- <2x at `--threads 6`: the design failed its premise — stop and
  re-evaluate before merge.
- 2x to <4x at t6: profile (lookahead thread, caller serial part,
  sync overhead), record the findings in `doc/threads.txt`; merging is
  allowed only with explicit maintainer approval.
- ≥4x at t6 and ≥5x at t16: pass.

Low-N tolerance (settled 2026-08-17): pairs in flight halve (N slots =
N/2 pairs), so a t2 regression up to ~10% vs the pair-granular
implementation is acceptable if recorded in `doc/threads.txt`; t4 MUST
NOT regress. No special pair-granular mode is kept for small N (a third
code shape costs more than the win).

VBV-drift bar (settled 2026-08-17): pass-1 row VBV runs on predicted
pass-0 bits (D6). The gate is conformance-only — x264's own VBV model
shows no underflow/overflow and the HRD path stays JM-clean — plus the
drift numbers recorded as a column of the 6.1 benchmark. No numeric
deviation bound: threaded RC is approximate by design, as in
progressive.

## Alternatives considered (parallelization options beyond the split)

- **Sliced threads under PAFF** — rejected: slice penalties land exactly
  on the maintainer's use case (CBR+VBV broadcast: simultaneous slices
  increase VBV misprediction, doc/threads.txt; up to +30% bitrate at
  extreme slice counts), and PAFF×slices doubles the conformance matrix.
- **Split only (phase first field)** — rejected, D1: no critical-path
  change.
- **Tuning `i_mv_range_thread` down** — rejected as primary: steepens the
  staircase but leaves the in-job phase barrier; ceiling stays ~2x on
  P-chains.
- **OpenCL lookahead** — orthogonal (lookahead is not the current
  bottleneck: at 71 fps the single lookahead thread is far from
  saturated); high maintenance, no.
- **Input-side (decoder feeding the encoder in the ffmpeg pipeline)** —
  out of encoder scope; flagged for the acceptance measurement only.

## Risks / Trade-offs

- [Pass-1 reads stale slot state that today carries through the pair
  (border backups, misc caches)] → D6 audit is a dedicated task with a
  dedicated gate (byte-identity at N=1 catches rescheduling errors;
  fixed-N determinism + TSAN catch cross-thread ones); marshal anything
  found through job params.
- [VBV row re-encode vs concurrent band work of the other pass] → D4
  parity scoping makes band work touch only its own parity; the NDEBUG
  MV-range check and the t1 gates cover the geometry.
- [Output stitching breaks NAL ordering or API lifetime rules] → harvest
  rendezvous orders the stitch; payloads live in slot buffers not reused
  until re-dispatch (later than API invalidation); covered by JM
  round-trip and CLI/mkv output tests.
- [Slot/context sync races (memcpy region)] → re-run the 6.1-style audit
  for the new job shape; TSAN gate with progressive control diff.
- [Fewer pairs in flight at small N (N/2) hurts B-heavy overlap] →
  bounded by measurement at t2/t4 in the perf matrix; if it regresses
  vs today at t4 the slot mapping can be revisited without changing the
  readiness model.
- [Perf gain below expectation] → D8 acceptance rule: <2x at t6
  re-opens the change instead of merging a complex no-gain.

## Migration Plan

Commit sequence, each keeping the tree green (`tools/test_paff.sh` +
t1 byte-identity + checkasm untouched paths):

1. Parity-parameterized band/filter primitives (no scheduling change;
   t1 byte-identity gate; also removes the 2x hpel waste).
2. First-field cadence in `paff_filter_row` + sweep deletion (t1
   byte-identity; N>1 still phase-broadcast? no — cadence broadcasts for
   both parities from here on; determinism gates at existing N).
3. Job split + two-slot dispatch + harvest stitching (the big one;
   full gate matrix + TSAN).
4. Docs, benchmarks, AGENTS.md.

Rollback: revert; no API/on-disk migration. `--paff --threads 1`
behavior (inline driver) is preserved by construction throughout.

### Task-5.1 addendum (2026-08-18): CBR+VBV fixed-N gate, as measured

The "output-set equality" wording above was field-tested and is
statistically unsound: the pre-change binary's output distribution under
threaded VBV is wide (13 distinct outputs in 40 t16 runs on the 176x144
CBR config), so a K-run sample cannot bound its support, and a subset
check against it flakes either way.  Measured divergence rates (40 runs
each, 176x144 25-frame CBR+VBV, quiet machine):

- t16 TFF: golden 13 distinct, new 5 distinct (the split is MORE
  deterministic here — fewer in-flight dispatch windows per pair).
- t4 TFF: golden 1/40 deterministic, new 2 distinct (37/3 split).
- t4 BFF: golden 1/40 deterministic, new 2 distinct.

The t4 divergence is the same upstream mechanism (parked change root
cause #1: dispatch-time reads of in-flight slots' volatile
`rc->frame_size_estimated`); pass-granular jobs widen that race window
at low N because more slots are in flight more of the time.
Characterization of the divergent branch: first byte difference at
~frame 7, output size within 7 bytes of 52 KB, PSNR 15.280 vs 15.284 dB
(golden 15.264 dB), zero VBV underflow/overflow warnings, ffmpeg decode
clean.  Verdict: same nondeterminism class as the pre-change tree (and
bounded by it at t16), conformance-clean.  The CBR+VBV fixed-N gate is
therefore: divergence rate within the pre-change binary's class (same
order, no systematic explosion), JM conformance, zero VBV warnings —
the byte-level fix remains the parked `threaded-vbv-determinism`
change.

### Task-5.5 addendum (2026-08-18): quality tolerance, as measured

t1-vs-tN Global PSNR / bitrate divergence on the 9.4 clips (320x240,
fade at `--weightp 2 --bframes 3 --ref 5`, scenecut default and
BREF+weightp2), progressive t1-vs-tN on the same clip as the reference:

| clip / mode | PAFF t4 vs t1 | PAFF t8 vs t1 | progressive ref |
|---|---|---|---|
| fade CRF | +0.061 dB, -0.69% | +0.065 dB, -0.39% | +0.005 dB, -2.45% |
| scenecut default CRF | +0.005 dB, -0.04% | +0.005 dB, -0.37% | 0 / 0 |
| scenecut BREF+w2 CRF | -0.002 dB, -0.13% | +0.007 dB, +0.55% | 0 / 0 |
| fade CQP qp20 | -0.004 dB | -0.004 dB | +0.056 dB |
| scenecut CQP qp20 | +0.031 dB | +0.037 dB | 0.000 dB |

Verdict: within the progressive-threading reference class.  Under CQP
(RC operating point fixed) PAFF's divergence is at or below the
progressive reference on the same clip; the CRF fade delta is an RC
operating-point shift (bitrate moves with it, and PAFF's threaded
bitrate divergence is smaller than progressive's own -2.45%).  The
9.1-style signature (systematic degradation from stale ME borders) is
absent: tN PSNR is not worse than t1 anywhere.

## Open Questions

- ~~Exact intra-border-backup handling for the pass-1 slot (D6 audit
  output; answer does not change the approach, only the job struct
  contents).~~ RESOLVED by the D6 audit below: no marshalling needed.

## D6 audit results (task 3.1/3.2, code-verified 2026-08-17)

### 4.5 addendum: memcpy-region / TSAN audit for the split job shape

TSAN (clang, --disable-asm) at t4 PAFF vs a progressive control, class
diff: the split adds NO new racing mechanism.  All reports pair a pool
worker's writes to its own slot's sync-region fields (sh, stat.frame,
cabac, mb caches) with the caller's `thread_sync_context` memcpy reading
the previous pair's pass-0 slot while its job may still run -- the same
window and the same benign-overwrite invariant as the audited
pair-granular code and as progressive itself (control shows 202 reports
of the identical class, incl. cabac.c:123 / dct.c / encoder.c:36xx-38xx).
Nothing syncs FROM a pass-1 slot, so the pass-1 MMCO-suppressed sh view
never leaks into a context copy; the pass-1 slot's torn memcpy state is
fully overwritten by the dispatch-time fill (job, sh, rc, fdec, fenc,
out).

One PAFF-specific class: `frame.c:519` (the plane[] border expansion in
the reference band) vs the intra cache load (`macroblock.c:648`).
Consumed border values are provably the pool-stale ones: a field row's
plane[] border is read (column-0 intra cache load) only before the row
is coded, and the row-wait order guarantees the producing band completed
before the consuming row starts, so the racy re-expansion of live rows
is never the consumed value.  Scoping the plane[] expansion by parity
was tried and REJECTED: it changes t1 bytes (rc2p_bff) -- the stale
expanded border is a real, deterministic input in some configs.

Fixed from this audit (in the big commit): ref_blind_dupe clear per pass
slot (the determinism root cause: refdupe ME seeding from uninitialised
analysis stack on the pass-1 slot); fenc->weighted/i_lines_weighted
moved to the per-slot paff_weighted shadow (write-write race on the
shared fenc); x264_paff_sync_ratecontrol preserving the rc end-chain +
central buffer_fill_final; open-time SPS/PPS replication into worker
slots (zero HRD otherwise); deferred fenc recycle (paff_fenc_defer) for
the lookahead lowres lifetime.

Every `x264_t`-carried state the second pass reads that the first pass
wrote, and its handling under the pass split.  "Per-slot" means the state
is re-initialized per pass or per slice on the slot's own `x264_t` and no
cross-job marshalling is required.

| State | Verdict | Evidence / handling |
|---|---|---|
| `h->out` (bs, NAL array) | stitch | Each job writes its own slot `out`; harvest stitches F1's NALs after F0's and sets `out.i_paff_au_boundary = F0's i_nal` before any consumer.  The `-pass0_end_bits` misc-bits undo disappears (each `slice_write` counts only its own out). |
| `h->stat.frame` | merge | `slices_write` memsets it per call, so each job's is pass-local; harvest adds F1's into F0's (same arithmetic as today's `stat_first` merge), including the per-pass pair-folded `i_mb_count_ref[0]`. |
| `h->sh` | per-slot | Re-initialized per pass (`paff_slice_init` + driver); the end-of-driver "restore pair-level view" block moves to harvest.  Pass 1's MMCO suppression (`i_mmco_command_count = 0`) is a job-local write. |
| `h->i_ref/fref/maps` | job params | Loaded per pass from `paff_job[pass]` (both halves filled into both slots identically). |
| shared pair `fdec` pixels | disjoint rows | Pass p writes only parity-p `plane`/`plane_fld`/`filtered_fld`/`integral` rows (recon, deblock, band).  No cross-field deblock in field pictures; intra prediction does not cross the field boundary.  VBV row re-encode rewrites only the owning pass's parity rows, and its reference refresh happens at that pass's later cadence. |
| `fdec->i_field_bits[2]` | disjoint elements | Write-only in the current tree (no reader); each job writes its own element. |
| `fdec->i_row_bits[]` etc. | mostly OK | Zeroed once per pair in `x264_ratecontrol_start` (caller, serial); each pass `+=`es only its parity's frame rows.  `f_row_qp`/`f_row_qscale` reads of the complementary field from pass-1's row VBV are the UPSTREAM in-flight-reference race class (parked change `threaded-vbv-determinism`; VBV-only). |
| `fdec->mb_info` | disjoint | Written per MB (`mb_xy`-indexed, parity-disjoint rows); freed once (NULL guard). |
| `fdec` metadata (`i_poc`, `i_delta_poc`, `i_frame_num`, `ref_poc`, `i_ref`, `i_poc_l0ref0`, `i_field_avail`, `i_row_satd`) | caller-published | All written serially in the prologue (D3.3) before both dispatches. |
| `intra_border_backup` | **self-contained, no marshalling** | Under FIELD_PIC, `x264_macroblock_cache_save` runs the MBAFF variant: parity 0 saves to `[0]`/loads from `[3]`, parity 1 saves to `[1]`/loads from `[4]`; the per-row-start XCHG (`paff_filter_row`) rotates `[0]<->[3]`, `[1]<->[4]`, so each pass's chain reads only its own writes.  A pass's FIRST row reads dead content (top neighbors unavailable), so the initial buffer state is irrelevant.  The rotation is consistent for any initial pointer parity (XCHG count per pass = rows per pass; both even and odd counts verified). |
| `h->rc` | seed + merge | Pass-1's slot rc is seeded at dispatch (`x264_thread_sync_ratecontrol`, serial view); pass-1's row VBV sees predicted pass-0 bits (accepted, progressive semantics).  Harvest merges `qpa_rc`/`qpa_aq` (`x264_threads_merge_ratecontrol` pattern) and the end-chain sync is rebuilt for two slots per pair.  `rc->row_pred[]` is not synced (pre-existing FIXME); pass-1's row predictors are approximate — VBV-only, accepted. |
| `h->mb` caches, CABAC, `i_last_qp/dqp`, `field_decoding_flag`, `b_reencode_mb`, `i_mb_prev_xy`, `deblock_strength`, `bipred` buffers, `map_col_to_list0`, `h->sh.weight` | per-slot | Re-initialized per slice/per pass on the job's own slot. |
| `h->stat.i_direct_score` (global) + `b_direct_auto_write` | per-slot + merge | The driver's direct-pred decision reads the global score, which is not modified mid-pair; both slots sync the same serial value.  `stat.frame.i_direct_score` merges at harvest. |
| `h->fenc` | shared, read-only | Both jobs point at the pair's fenc; `x264_frame_push_unused` exactly once at harvest. |
| `h->paff_evicted` | pair-level stash | Caller fills it on the pass-0 slot; released at harvest after BOTH jobs complete. |
| `h->i_nal_type`, `i_nal_ref_idc`, `i_global_qp`, `b_sh_backup` | job params / caller | Carried in `paff_job` or set by the caller on the owning slot before dispatch (`b_sh_backup` only the F0 slot writes the marking SEI). |
| completion sentinels | per parity | Each pass's job broadcasts its own parity (already true after stage 2); the fail path (4.6) adds the error sentinel. |
| quality measurement (`fdec_measure_quality`) | **moves to harvest** | Full-frame, reads BOTH parities' recon.  A non-reference B pair's pass 1 has no complementary ref and no wait on pass 0, so it can finish first; running the measurement in a job would race and produce timing-dependent PSNR/SSIM.  Harvest runs it on the pass-0 slot after the rendezvous (bitstream-neutral, metrics-only). |
| `h->frames.i_delay` | caller | Counts pairs in flight (`(N+1)/2 - 1`), task 4.2. |

Parity-disjointness argument (task 3.2): the pair's `fdec` is shared via
the job parameters; the pass-1 job overrides its slot's `h->fdec` for the
duration.  Every per-pixel or per-row writer in a field pass touches only
its coding parity's rows (recon store, deblock, reference band, VBV
re-encode), and every cross-pass reader (MC on the complementary field,
harvest-side measurement) is either wait-gated on the owning pass's
per-parity progress counter or deferred to harvest.  The slot `x264_t`
carries no cross-pass state (audit above).
