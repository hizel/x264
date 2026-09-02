# Proposal: PAFF — B field pictures and field MV prediction

> Part 3 of 4 of the PAFF series. Depends on `paff-field-references`.
> Followed by: `paff-sei-hrd-rc`.

## Why

Without B field pictures a PAFF stream gives up x264's main compression tools
(bidirectional prediction, hierarchical GOPs, mbtree-driven allocation). B fields
bring the hard part of the H.264 field model: L0/L1 list construction for field
pictures (§8.2.4.2.4/8.2.4.2.5), temporal direct mode with colocated *field*
selection and MV scaling (§8.4.1.2.4), and field-aware spatial direct / MV
prediction (§8.4.1.3).

## What Changes

- B field pictures: L0/L1 expansion per §8.2.4.2.4/8.2.4.2.5, `ref_poc`/inv
  tables per field.
- Temporal direct mode for fields: colocated field selection, MV scaling —
  audit `common/mvpred.c` MBAFF paths vs picture-field semantics.
- Spatial direct and field-aware MV prediction (§8.4.1.3): neighbors in a
  uniformly-field picture.
- Slice-type decisions stay frame-granular: both fields of a pair inherit the
  frame's slice type and reference set (lookahead/mbtree unchanged).
- The B-frames validation clamp from `paff-core-ip` is lifted.

## Capabilities

### Modified Capabilities
- `paff-encoding`: adds B field picture and field MV prediction requirements.

## Impact

- **Core encoder**: `encoder/encoder.c` (B field slice path),
  `common/mvpred.c`, `encoder/me.c` (field direct/prediction — largely reusing
  MBAFF paths), `encoder/analyse.c` (B field mode decision).
- **Lookahead**: `encoder/lookahead.c`, `encoder/slicetype.c` — unchanged logic,
  verified to map sanely onto field pairs.
- **Invariant**: hierarchical B-field GOPs decode byte-exactly with a
  conformant H.264 decoder (verified via ffmpeg; JM 19.0 is itself buggy for
  PAFF field pictures and is not the operative oracle — see the spec's
  "Verification oracle" note); non-PAFF output
  untouched.
