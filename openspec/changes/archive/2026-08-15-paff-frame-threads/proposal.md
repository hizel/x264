# Proposal: PAFF — frame-threaded encoding (hybrid readiness)

## Why

PAFF today forces `i_threads = 1` (warned down from any requested `--threads
N`), making it roughly single-core speed — "the main throughput cost of PAFF
today" per `doc/paff.txt`. The deferral recorded in the archived change
`2026-08-15-paff-sei-hrd-rc` (design D3, task 3.1) was based on reading pair
readiness as all-or-nothing.

The originally sketched fix — phase-granular readiness (broadcast after the
intermediate sweep, when the first field becomes a valid reference) — does
**not** create cross-pair overlap, and this change does not build it. The
decoder's default field list (H.264 8.2.4.2.5, reproduced by
`paff_expand_field_list`) alternates parity per reference pair: for either
coding parity the active list starts `[p(N), !p(N), p(N-1), !p(N-1), ...]`.
Every pass of pair N+1 therefore reads **both** fields of pair N; the field-0
pass waits for pair N's completion just as much as the field-1 pass does, and
the dependency chain `field1(N) -> finish(N) -> field0(N+1) -> ...` stays
fully serial (~1.0x, no matter the thread count).

What does create overlap is row-granular readiness of the **second field**:
rows of the coding parity become referenceable as the second pass progresses
(copy to field layout, hpel, borders at row cadence), and dependent passes
gate through the standard motion-vector-range machinery, exactly as
progressive frame threads do. The intermediate sweep keeps the first field
phase-complete. Expected scaling is a pass-level pipeline: second-field rows
of pair N gate pass 0 of pair N+1, and both passes of a pair are serial
inside one job, so a P-chain tops out at ~2x (pair time / pass time) minus
MV-clamp losses no matter the thread count; B-pyramid siblings gate on the
same anchor and overlap more. The target is ~2x on two cores for 1080i-class
input (measured by task 7.3); the plateau beyond two threads is documented,
not treated as a regression.

## What Changes

- Enable frame-based threading under PAFF (`i_thread_frames > 1`), one
  complementary field pair per frame-thread slot (unchanged unit).
- Track per-parity readiness on `x264_frame_t`: `i_lines_completed_fld[2]`
  sharing the frame's mutex/cv. Parity of the first field: sentinel broadcast
  at the end of the intermediate `paff_sync_references` sweep. Parity of the
  second field: real row counts broadcast at row cadence during the second
  pass; completion at `paff_frame_finish`.
- Move the second field's reference-data generation (field-layout copy, hpel,
  border expansion) from the final full-frame sweep to row cadence inside
  `paff_filter_row`; the intermediate sweep between the passes stays
  full-frame; the final sweep reduces to residual rows + quality measurement.
- Rework the frame-thread wait sites in `encoder/analyse.c` for the PAFF
  field-expanded reference list shape: per-entry parity maps
  (`i_fref_frame`/`i_fref_parity`) instead of the MBAFF `ref >>
  MB_INTERLACED` indexing, wait thresholds in field coordinates, standard
  `thread_mvy_range` clamping from completed rows, self-reference entries
  (`fref == h->fdec`) skipped.
- Restructure dispatch: the PAFF pair driver becomes a pool job. Strict
  caller/job boundary: the job writes only what progressive `slices_write`
  writes (out, stat.frame, mb, fdec pixels). The first field's DPB marking
  (D20 evictions), the P-pair past-list rebuild (FrameNumWrap sort) and
  `i_frame_num` advancement move to the caller before dispatch; the job
  receives pre- and post-marking pair-list snapshots and never reads
  `h->frames.reference`. Both passes' field-list expansions also move to the
  caller (their inputs are the snapshots; expansion reads no pixels), so
  per-parity list metadata (`i_ref[]`, `ref_poc[]`, `i_poc_l0ref0[]`) is
  published serially before dispatch exactly as progressive does — no
  cross-job handshake. The job receives the expanded per-pass lists, parity
  maps and the pre-increment `i_frame_num` in a job-parameter struct, writes
  `h->sh` directly per pass and restores the pair-level view at the end (no
  snapshot: the only read-before-overwrite consumer is MMCO application, a
  no-op after the caller-side marking — design D3.4).
- Determinism contract: deterministic at a fixed thread count (matching
  progressive x264, including `--non-deterministic` semantics). Byte-identity
  to `--threads 1` is **not** required: row-granular references require the
  standard `i_mv_range_thread` clamp (default computed from field height),
  which changes motion search exactly as progressive frame threads do.
- Remove the `assert( h->i_thread_frames == 1 )` in the PAFF pair driver and
  the forced `i_threads = 1` validation; sliced threads stay rejected.
- Update `doc/paff.txt` (Threading section rewrite), `doc/threads.txt`
  (benchmark notes), and `AGENTS.md` (PAFF threading facts).

Non-goals:
- Slice-based threading under PAFF (still rejected at validation; low-latency
  slicing stays future work).
- Row-granular readiness for the **first** field (the intermediate sweep
  stays a phase) — recorded as future work in design.
- Field-granular RC decisions (unchanged from the archived D2).

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `paff-encoding`: the "Threading behavior under PAFF" requirement changes —
  frame threads become supported with a fixed-N determinism contract instead
  of forced single-threading; the "Frame threads deferred" bailout scenario
  is kept as an explicit merge condition; the "Frame threads work" scenario
  is rewritten from byte-identity to per-N determinism + JM decodability +
  same frame-type/reference structure; readiness gating is generalized to
  both fields (phase for the first, rows for the second). The "Threading
  restricted under PAFF" scenario under "Field-picture coding mode selection"
  already reflects that only sliced threads remain rejected.

## Impact

- Code: `encoder/encoder.c` (dispatch split, marking/f-num in caller, job
  body, `paff_filter_row` row-cadence sweep, `paff_sync_references`,
  validation), `encoder/analyse.c` (wait sites), `common/frame.c` /
  `common/frame.h` (per-parity progress counters), `encoder/ratecontrol.c`
  (`i_mv_range_thread` defaulting, sync audit).
- Docs: `doc/paff.txt`, `doc/threads.txt`, `AGENTS.md`.
- Tests: PAFF multi-thread validation (determinism per N, JM round-trip,
  threaded-vs-single-threaded PSNR/bitrate tolerance), existing regression
  matrix re-run for `--paff`.
- Risk: the caller/job boundary and the `thread_sync_context` memcpy region
  are the least-audited areas (own tasks with TSAN gates); row-cadence hpel
  correctness (deblock lag, field-coordinate thresholds) is the main new
  machinery.
