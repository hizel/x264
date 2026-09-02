# Proposal: paff-sliced-threads

## Why

PAFF currently rejects `--sliced-threads` at validation, so the only
threaded PAFF mode is frame threading. Frame threading costs latency:
N slots keep N/2 field *pairs* in flight, each pair paying a two-pass
rendezvous before harvest. Low-latency interlaced contribution links (the
niche sliced threads serve in progressive encoding) have no PAFF option at
all. The exploration showed the combination is feasible with moderate,
well-localized work: PAFF already expresses its per-pass "every second
row" geometry through the same `i_threadslice_start/end` machinery that
sliced threads partition, and the frame-thread pipeline (the hard part)
is not involved at all — under sliced threads `i_thread_frames == 1`, so
the monolithic pair driver runs and each field pass is split into
per-thread slice bands.

## What Changes

- Allow `--paff --sliced-threads --threads N` (N > 1): each field pass of
  the complementary pair is coded by the monolithic pair driver, and each
  pass's field rows are split into N parity-interleaved slice bands coded
  in parallel (one slice per band per field picture).
- Band geometry: a slice band covers field rows `[b0, b1)` of one parity,
  i.e. frame-coordinate MB rows `p+2*b0 .. p+2*(b1-1)` stride 2. The
  existing field-raster translation in `slice_header_write` is unchanged.
- Reference-data work (plane_fld copy, borders, hpel) under sliced
  threads: slice threads deblock their own band rows; after the join, the
  main context runs the serial per-parity reference sweep (the proven
  pre-`paff-pass-threads` sweep shape, byte-identical to the cadence
  result by construction). No cross-thread pixel synchronization is
  introduced.
- Row-VBV budget granularity moves from pair to field under sliced
  threads: pass 0 receives the pair plan scaled by its parity's satd
  share; pass 1 receives the leftover (pair plan minus pass 0's actual
  bits). This directly bounds the documented weak point of pair-level
  VBV (first-field overshoot invisible to a pair-level CPB step).
- Threaded ratecontrol accumulator hygiene: per-pass distribute/merge
  cycles zero the pair-level accumulators (`qpa_rc`, `qpa_aq`) in each
  worker's copied state, so the pass-0 base is not counted N times.
- Validation: the `b_paff && b_sliced_threads` error is removed; the
  sliced-thread count cap (`max_sliced_threads`) is computed from field
  rows (half the frame MB height). `--paff --sliced-threads` combined
  with any explicit sub-slicing (`--slice-max-size`, `--slice-max-mbs`,
  `--slices`) is rejected; drive-by fix: `--paff` with
  `--slice-max-mbs`/`--slices` is rejected at ANY thread count (today
  it silently produces empty output with exit code 0).
- Determinism: PAFF+sliced inherits upstream's documented sliced-threads
  exception — CBR+VBV output is timing-dependent (cross-slice reads of
  live `bits_so_far`/`frame_size_estimated`); CRF/CQP/ABR-without-VBV
  output is byte-identical across repeat runs at a fixed thread count.
  No PAFF+sliced output is byte-identical to `--threads 1` PAFF (slice
  boundaries, CABAC reinit, per-slice deblock disable), same as
  progressive sliced threads.
- `doc/paff.txt`, `doc/threads.txt`: sliced-threads entries move from
  "rejected" to supported, with the determinism exception and the
  measured quality/speed numbers recorded.

Non-goals:

- Parallelizing the post-join reference sweep (progressive-style
  pass-1/pass-2 boundary-window dance). Documented as a future
  optimization if profiling shows the sweep matters.
- Byte-deterministic CBR+VBV under sliced threads (deterministic
  stand-ins for cross-slice live reads, in the spirit of
  `vbv_inflight_bits`). Possible future work; upstream deliberately keeps
  the exception.
- Sliced threads combined with PAFF *frame* threading (the modes are
  mutually exclusive by construction: `b_sliced_threads` forces
  `i_thread_frames == 1`).
- AVC-Intra II-pair support, per-field mbtree propagation (both remain
  future work per `doc/paff.txt`).

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `paff-encoding`: the "slice-based threading is rejected" requirements
  change to "supported with field-level slice bands"; threading,
  rate-control and determinism requirements gain the sliced-threads
  behavior (band geometry, per-field VBV budgeting, the VBV determinism
  exception, non-VBV byte-repeatability).

## Impact

- **Code**: `encoder/encoder.c` (validation, `threaded_slices_write`
  band geometry, per-pass dispatch in the pair driver, serial sweep
  wiring, `paff_filter_row` sliced branch, `max_sliced_threads` cap),
  `encoder/ratecontrol.c` (stride-2 row loops in
  distribute/merge/`row_bits_so_far`/`predict_row_size_to_end`, per-field
  budget split, accumulator zeroing, band-start `f_row_qp` guard).
- **Tests**: `tools/test_paff.sh` (new `sliced` command: JM round-trips,
  HRD cells, band-geometry edges), `tools/test_vbv_determinism.sh`
  (PAFF+sliced byte-repeat cells for non-VBV modes; HRD/no-underflow
  cells for CBR+VBV), `tools/test_paff_hw.sh` (multi-slice field-picture
  streams in the hardware-decoder set), `tools/test_paff_ci.sh` /
  `paff_matrix.sh` (CI coverage).
- **Docs**: `doc/paff.txt` (threading section, unsupported-combinations
  list, future-work list, quality numbers), `doc/threads.txt`
  (sliced-under-PAFF paragraph).
- **API/ABI**: none. `x264.h` unchanged; the combination moves from
  hard error to accepted, which is source- and ABI-compatible for
  existing callers.  One behavior tightening for existing PAFF callers:
  `--slice-max-mbs`/`--slices` under PAFF now fail loudly at encoder
  open instead of silently producing empty output.
- **Out of scope for performance acceptance**: peak throughput; sliced
  threads target latency. Speedup floor is checked to catch pathologies
  (serial sweep cost measured and recorded).
