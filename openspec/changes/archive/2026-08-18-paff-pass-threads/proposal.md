# Proposal: paff-pass-threads

## Why

PAFF frame threading saturates at ~3.2x no matter the thread count (measured
on the maintainer's 720p25 CBR+VBV clip: 22.2 / 69.4 / 71.5 fps at
`--threads 1/6/16`; CPU utilization 318-321% — workers wait, they do not
work). The cause is structural: one complementary field pair is one pool job,
so the second pass always starts only after the first pass plus the
intermediate sweep complete inside that job, while every pass references
both fields of the previous pair. A gdb stack snapshot at `--threads 16`
shows 13 of 16 workers parked in `x264_frame_cond_wait_fld`. The archived
`paff-frame-threads` design documented this ~2x P-chain ceiling and deferred
the structural fix; the deferral note estimated the gain as "single percent",
which today's measurements contradict.

## What Changes

- Split each complementary field pair into **two pool jobs** (one per field
  pass) under `--paff` with frame threads, so passes of different pairs (and
  of the same pair) can execute concurrently.
- Give the **first field row-granular readiness**: its reference data
  (plane_fld copy, hpel, borders) is produced at row cadence during its own
  pass and broadcast per field line, replacing the intermediate full-frame
  sweep phase. The second pass trails the first at a bounded row margin,
  exactly like dependent pairs already trail the second field today.
- Parameterize the field branch of `x264_frame_filter` (and the band copy)
  by parity: under the split, re-filtering the other parity's rows from the
  second pass would race the first pass's in-flight rows (including VBV row
  re-encode rewrites), so per-parity filtering becomes correctness-required,
  not just an optimization.
- Consume **two frame-thread slots per pair** (one per pass) in the caller's
  round-robin; harvest waits for both jobs of the oldest pair and stitches
  their NAL arrays into the single per-pair output picture.
- Keep the caller-side serial prologue exactly as is (both passes' list
  expansions, DPB marking snapshots, `i_frame_num` advancement — decisions
  D3.1/D3.2/D3.3/D20 of `paff-frame-threads` are not reopened; only the D3
  job boundary moves from pair to pass).
- Determinism contract unchanged: deterministic at fixed N (default mode
  uses the fixed `i_mv_range_thread`), not byte-identical to `--threads 1`.
  `--threads 1` PAFF output stays byte-identical (pure rescheduling of the
  sweep, gated by regression).
- Non-PAFF outputs (progressive, MBAFF) stay bit-identical at every thread
  count (all new paths gated on `param.b_paff`).

Not in scope: sliced threads under PAFF (still rejected), any public API
change, field-granular rate control, lookahead/mbtree changes.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `paff-encoding`: the "Threading behavior under PAFF" requirement changes —
  the frame-thread unit becomes the field pass (two slots per pair) instead
  of the pair; reference readiness for BOTH fields becomes row-granular at
  pass cadence (the intermediate-sweep phase requirement is dropped);
  determinism-at-fixed-N, JM conformance, and the non-PAFF bit-identity
  invariants are restated unchanged.

## Impact

- `encoder/encoder.c`: `paff_pair_write` split into per-pass job entry
  points; caller dispatch/harvest/slot-round-robin changes; sweep removal;
  `paff_filter_row` extended to generate first-field reference data at
  cadence; residual end-of-pass work (last band + sentinels + quality
  measurement) per pass.
- `common/mc.c` (`x264_frame_filter` field branch parity parameter),
  `common/frame.c` (per-parity counters already exist; broadcast sites).
- `encoder/analyse.c`: wait sites — the complementary-field entry of the
  second pass now waits (row-bounded) instead of being skipped as
  `fdec == h->fdec`; thresholds already in field lines.
- Slot/context machinery: two `x264_t` slots per pair, context sync chain,
  per-pass `h->out` buffers with NAL stitching at harvest, per-slot stat
  merge, shared pair `fdec` frame across the two jobs (disjoint parity
  rows; audit for the intra-border-backup and any other h-carried state
  read by the second pass).
- `doc/paff.txt`, `doc/threads.txt`, `AGENTS.md`: threading model rewrite,
  new benchmark table, future-work note updated.
- Tests: `tools/test_paff.sh` threading gates extended (t1 byte-identity
  after sweep removal, fixed-N determinism at N=2/4/8/16, JM round-trip,
  TSAN).

Expected outcome on the reference clip: P-chain ceiling lifts from ~2x to
progressive-like scaling (field height / row margin ≈ 7x at 720p), i.e.
roughly 5-6x at `--threads 6` and beyond at higher counts until the
lookahead/caller serial parts bind.
