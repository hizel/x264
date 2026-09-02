# Proposal: PAFF — SEI/HRD per field, rate control, threading, docs

> Part 4 of 4 of the PAFF series. Depends on `paff-b-frames`. Completes the
> series split from `add-paff-encoding`.

## Why

After the first three changes the encoder produces conformant PAFF pixel data,
but a deployable feature needs more: SEI messages are still emitted once per
frame (wrong for field access units — Table D-1 mandates per-field
`pic_struct`), HRD delays are modeled in frame units, rate control accounts
bits per frame while the bitstream carries two QPs per pair, threading policy
for field pairs is undefined, and nothing is documented or covered in CI.

## What Changes

- SEI per field access unit: `pic_timing` with `pic_struct = 1 (top) / 2
  (bottom)`, `NumClockTS = 1`; `buffering_period` CPB/DPB delays in field units;
  honest `original_field_pic_flag` in `dec_ref_pic_marking` (fixes the
  hardcoded 0 at `encoder/set.c:803` under PAFF).
- Keyframe (IDR) field pairs coded as "Ip": first field IDR, second field a
  reference P field referencing the first (QSV-compatible; also fixes the
  equal-`idr_pic_id` §7.4.3 violation of the previous "II" structure).
  All keyframe-containing streams change and are re-baselined.
- Rate control per field pair: frame-level QP decisions with per-field QP rows;
  bit accounting per field; 2-pass stats per field.
- VBV model per field access unit.
- Weighted prediction (`--weightp`) under PAFF, reusing the MBAFF weight path
  (falls back to a documented validation rejection if it fails conformance).
- Threading: field pair coded within one frame-thread slot; slice threads
  force-disabled under PAFF; `--threads N` determinism verified.
- Pulldown/timecode interaction audited and validated in param checks.
- Documentation (`doc/paff.txt`, `doc/threads.txt`, `doc/ratecontrol.txt`,
  `AGENTS.md`, `--fullhelp`, bash completion) and CI coverage.

## Capabilities

### New Capabilities
- `field-aware-sei`: per-field SEI generation (pic_timing with field pic_struct,
  buffering_period, dec_ref_pic_marking) for field-picture streams.

### Modified Capabilities
- `paff-encoding`: adds rate-control and threading requirements.

## Impact

- **Core encoder**: `encoder/set.c` (SEI), `encoder/ratecontrol.c`,
  `encoder/lookahead.c`, `common/threadpool.c`, `encoder/encoder.c` (frame-threads
  boundary).
- **CLI/docs/CI**: `x264.c`, `autocomplete.c`, `doc/`, `.gitlab-ci.yml`.
- **Invariant**: non-PAFF SEI/RC/threading behavior bit-identical; JM
  bit-exactness preserved across the full matrix.
