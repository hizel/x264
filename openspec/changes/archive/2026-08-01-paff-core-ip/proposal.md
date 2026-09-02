# Proposal: PAFF core — field-pair coding of I/P pictures

> Part 1 of 4 of the PAFF series, split from the original `add-paff-encoding`
> umbrella change. Followed by: `paff-field-references`, `paff-b-frames`,
> `paff-sei-hrd-rc`.

## Why

x264 cannot produce field pictures (`field_pic_flag = 1`, H.264 §7.3.3): the code
says so itself (`encoder/encoder.c:139`, `x264.h` "PAFF only" note). PAFF is
required by legacy decoders, broadcast workflows, and conformance suites that
mandate field-picture bitstreams.

This change lays the foundation: the encoder learns to turn one input frame into
two coded field pictures (a complementary pair) and to emit conformant bitstream
headers for them. Scope is deliberately minimal — I and P field pictures with
same-parity references only — so the risky "two coded pictures per frame" rework
of the frame-centric main loop is validated in isolation, before B-frames, full
reference management, and rate control arrive in later changes.

## What Changes

- Public API: new `b_paff` field in `x264_param_t` (0 = off, 1 = PAFF).
  `b_interlaced` semantics unchanged (0 = off, 1 = MBAFF).  PAFF and MBAFF
  rejected together in validation.  `X264_BUILD` bumped because struct
  grew.  CLI: `--paff`, composable with `--tff`/`--bff`.
- Validation: PAFF rejected with `--fake-interlaced`, AVC-Intra, and
  MBAFF-only features.
- SPS/PPS/slice headers: `frame_mbs_only_flag=0`,
  `mb_adaptive_frame_field_flag=0` (already correct: `encoder/set.c:185`
  derives it from `b_interlaced`, which stays 0 under PAFF), field-height
  picture dimensions,
  per-field slice headers with `field_pic_flag`, `bottom_field_flag`,
  shared `frame_num` per complementary pair.
- Field-pair driver: one `x264_encoder_encode` call produces two field
  picture passes (per §7.4.3 access unit semantics — both fields in one AU
  with one frame-level PTS).  Each pass operates on `plane_fld` with
  `MB_INTERLACED=1` / `SLICE_MBAFF=0`; source stride fixed in 3 load
  sites (`encoder/macroblock.c`) to avoid doubling on deinterleaved data.
- Per-field POC (§8.2.1, poc_type 0 — already selected when interlaced).
- Minimal references: same-parity previous field as ref0, enforced via
  `ref_pic_list_modification` in the slice header (default H.264 list puts
  opposite-parity first).  B pictures, weighted prediction, and
  mixed-parity lists are force-disabled under PAFF until the follow-up
  changes.
- Deblocking: automatic — each field is a separate coded picture so the
  deblock filter stops at picture boundaries; no special code needed.
- Test infrastructure: JM reference decoder round-trip scripted (per
  `doc/regression_test.txt`) — the verification basis for the whole series.

## Capabilities

### New Capabilities
- `paff-encoding`: PAFF coding mode, complementary field pairs, per-field POC,
  field-pair deblock boundary, I/P field conformance, CLI access. (Extended by
  the follow-up changes.)

## Impact

- **Public API/ABI**: `x264.h` (param semantics, `X264_BUILD` bump),
  `x264.c`/`x264cli.h` (CLI option).
- **Core encoder**: `encoder/encoder.c` (field-pair driver), `encoder/set.c`
  (SPS/PPS/slice headers), `encoder/macroblock.c` (stride fix for PAFF
  source loads), `common/frame.c` (field-pair lifetime),
  `common/macroblock.c` (picture-wide field mode).
- **Tools**: `tools/` — JM round-trip script.
- **Out of scope** (later changes): mixed-parity and multi-frame reference
  lists, MMCO, B fields, per-field SEI/HRD, rate control, threading policy.
- **Invariant**: progressive/MBAFF output bit-identical when PAFF is off;
  `checkasm` stays green (no new asm).
