# Design: paff-weightb

## Context

See proposal.md — Why.  Current state, verified in code:

- Validation (`x264_encoder_open`, `encoder/encoder.c`) force-disables
  `analyse.b_weighted_bipred` under PAFF with a one-shot warning, claiming
  the tables "do not honour explicit weights".
- x264 never writes explicit bipred weights: `x264_pps_init` signals
  `weighted_bipred_idc = 2` (implicit).  The decoder derives bipred weights
  from POC distances (8.4.3); the encoder mirrors that derivation in
  `bipred_weight_buf`.
- `x264_macroblock_bipred_init_paff` (`common/macroblock.c`) already fills
  `dist_scale_factor_buf[1][parity]` / `bipred_weight_buf[1][parity]` per
  pass with per-field POCs (`i_poc + i_delta_poc[parity]`), including the
  `b_weighted_bipred` branch (`64 - (dist_scale_factor >> 2)` with the
  `[-64, 128]` guard).  The per-MB load (`macroblock_slice_init`) already
  reads the `[1][parity]` slot, and B-field direct modes (the dist_scale
  half of the same tables) pass the JM matrix today.
- `weighted_pred_init` early-returns for non-P slices, so `h->sh.weight`
  stays NULL for B slices and the slice header writes no
  `pred_weight_table` for B fields (correct for idc = 2).
- weightb defaults to 1 and is only dropped by the fastest presets, so the
  force-off hits default-preset PAFF encodes.

So the expected code delta is the validation block alone; everything
downstream is already field-correct.  The change is fundamentally a
*validation* change with two gates deciding whether the lift ships.

## Goals / Non-Goals

**Goals:**
- Determine whether implicit weighted biprediction is correct for B field
  pictures (encoder tables vs decoder derivation) and, if yes, enable it.
- Quantify the quality effect on dissolve content; enable only if a real
  gain exists.
- Record the outcome either way so the question stays closed.

**Non-Goals:**
- Explicit bipred weights (`weighted_bipred_idc = 1`) — x264 has no such
  path for any picture type; adding one is out of scope.
- Touching the weightp (P-field) path, which is already supported.
- Any change to direct-mode MV scaling (the dist_scale half of the tables
  is already validated by the B-field matrix).
- Non-PAFF behavior (bit-identical output, asserted by the regression
  gate).

## Decisions

### D1: Lift the force-off unchanged; let the conformance gate judge

Remove the warn-and-disable block so `b_weighted_bipred` flows through
under PAFF, with NO changes to `x264_macroblock_bipred_init_paff`.  The
implicit-weight derivation for a field picture uses that field's POC and
the referenced field pictures' POCs; the PAFF table init already computes
exactly this.  The B-field JM matrix (extended with weightb-on configs)
decides: if the decoder's field-POC derivation matches, every stream
round-trips bit-exactly.

Alternative considered: pre-verifying the derivation by reading JM source.
Rejected as the primary gate — the round-trip *is* the verification.
The gate is three-pronged: (a) the extended B-field JM matrix, (b) ffmpeg
software decode, pixel-exact vs `--dump-yuv`, and (c) hardware decode,
bit-exact vs `--dump-yuv`, on one weightb-on B-field stream — NVDEC
(`h264_cuvid`) and AMD (VAAPI) on the dev host; H.264 decoding is fully
specified (integer IDCT), so conformant hardware decoders are bit-exact
and (c) is a real gate, not best-effort.  Any mismatch fails the gate and
triggers D3.  JM source reading stays a debugging tool.

Gate sensitivity: the round-trip only proves something if the matrix
content actually exercises `bipred_weight_buf` values ≠ 32 (on both
sides of 32, including the `[-64, 128]` guard neighbourhood).  This is
verified once with a temporary instrumented build (debug counter in
`x264_macroblock_bipred_init_paff`, not committed); the gate does not
count as passed without this evidence.

### D2: Quality gate on dissolve content decides keep-vs-revert

Implicit bipred weights matter on dissolves/blends (crossfade between two
scenes), not on fades to/from black (that is weightp territory).  Test
content: two synthetic 50 fps progressive sources crossfaded with ffmpeg,
then `tinterlace` to interlaced, mirroring the existing `make_clip`
pattern.  Encode under PAFF at a CRF sweep, weightb on vs off, plus a
non-dissolve control clip.

Acceptance (thresholds fixed here, before any measurement): BD-rate,
PSNR-Y, piecewise log-linear interpolation (Bjøntegaard-style) over a
4-point CRF sweep (18/23/28/33), computed by an awk helper — no new
tooling dependency.  Dissolve clip: gain ≥ 1.0% → keep; ≤ 0.5% → kill;
in between → one extended sweep, then kill by default.  Control clip:
regression beyond ±0.5% BD-rate fails the gate.  If the outcome is kill,
the force-off is reinstated permanently and `doc/paff.txt` records the
measurement with numbers (same disposition as the
row-granular-first-field item).

Accepted limitation: the gate deliberately decides on synthetic dissolve
content only; real-world dissolve footage is not tested.  This keeps the
test reproducible (generator in-tree, no external assets).

Kill-switch disposition of the test surface: the weightb matrix rows
(task 1.2) are reverted — with the force-off reinstated they would
silently encode weightb-off duplicates of existing rows — but the
dissolve generator and the `weightb` command stay, so the measurement
recorded in `doc/paff.txt` remains reproducible.

### D3: Failure handling

If the conformance gate fails (JM mismatch with weightb on): diagnose
whether the mismatch is the weight derivation (compare JM's implicit
weights against `bipred_weight_buf` for the failing MBs; JM source at
`8.4.3`) or a pre-existing B-field issue exposed by the new configs.
A derivation fix inside `x264_macroblock_bipred_init_paff` is in scope if
small and provably correct; anything larger reverts to the permanent
disable + documented measurement.

### D4: Test-surface extension

`tools/paff_matrix.sh` gains weightb variants of its B-field configs (the
matrix already sweeps TFF/BFF x b-pyramid x ref x direct x CABAC/CAVLC —
weightb multiplies only the B configs, not the I/P ones).
`tools/test_paff.sh` gains a `weightb` command: matrix run with weightb
forced on, plus the dissolve-clip generator and the CRF-sweep quality
comparison (PSNR-Y via the encoder's own reported metrics, as the existing
scripts already collect).

## Risks / Trade-offs

- [JM's implicit-weight derivation for field pictures disagrees with the
  encoder's tables] → that is precisely what the conformance gate tests;
  D3 bounds the fallout.
- [Quality gate is inconclusive on synthetic dissolves] → the kill-switch
  outcome (D2) is an acceptable, documented result; a permanent measured
  disable is better than an unmeasured feature.
- [The enable flips RD decisions on all B-field content, not just
  dissolves] → covered by the non-dissolve control in D2 and by the
  full-matrix round-trip (conformance is content-independent).
- [Non-PAFF regression] → the validation change is gated on
  `param.b_paff`; `test_paff.sh baseline-check` asserts progressive/MBAFF
  bit-identity.
- [Threading interaction] → the tables are per-slot state filled inside
  the pass; no cross-thread surface.  Fixed-N determinism re-checked at
  N = 1/4/8 anyway.

## Migration Plan

Single spike commit first (force-off removal + matrix extension) behind
the two gates; the enable ships only if both gates pass.  Rollback =
revert; no ABI or bitstream-format migration.  The feature needs no
option: `--weightb`/`--no-weightb` already exist.

## Open Questions

- Exact dissolve-clip parameters (durations, source pair) that maximize
  weightb sensitivity — tuned during task implementation, does not affect
  the gates themselves.
