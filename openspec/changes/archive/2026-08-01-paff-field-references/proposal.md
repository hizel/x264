# Proposal: PAFF — full per-field reference management

> Part 2 of 4 of the PAFF series. Depends on `paff-core-ip` (field-pair coding
> of I/P pictures). Followed by: `paff-b-frames`, `paff-sei-hrd-rc`.

## Why

`paff-core-ip` ships a deliberately minimal reference model: a P field may only
reference the previous field of the same parity. Real PAFF streams need the full
model (H.264 §8.2.4.2.2, §8.2.4.2.5, §8.2.5): reference *frames* expand into
parity-alternated field references, the first field of the current pair must be
referenceable by the second, and the DPB marking process must run after each
coded field (§8.2.5.1) in slot units (§8.2.5.3). Without this, compression on
interlaced content is crippled (the nearest temporal reference — the
complementary field — is unusable). (Per-field single-field marking and MMCO
for field pictures are deferred to `paff-b-frames`; PAFF I/P emits only
sliding-window marking.)

## What Changes

- Reference pairs keep frame-level `b_kept_as_ref` (a PAFF I/P pair is
  uniformly "kept as ref" or not); per-field marking state and field-pic MMCO
  are deferred to `paff-b-frames` (design D4/D10/D18, DEC-B).
- Reference list construction: frame list → parity-alternated field entries
  using the existing `j>>1`/`j&1` convention, starting with the current field's
  parity (§8.2.4.2.5); the complementary first field is inserted as a short-term
  reference for the second field pass (§8.2.4.2.2).
- Sliding-window marking in **slot units** (one complementary pair = one DPB
  slot, as in frames today); DPB size accounting per slot; `max_num_ref_frames`
  handling (§8.2.5.3); the marking process runs after each field (§8.2.5.1), so
  the driver evicts between the two passes (design D5/D20).
- Ref-list reordering (`x264_reference_build_list_optimal`) and `ref_poc`
  tables extended to field entries.
- The validation clamps added in `paff-core-ip` (no mixed-parity/multi-ref
  under PAFF) are lifted.

## Capabilities

### Modified Capabilities
- `paff-encoding`: adds field reference lists and field reference marking
  requirements.

## Impact

- **Core encoder**: `encoder/encoder.c` (per-pass `reference_build_list`,
  slot-unit DPB bookkeeping, between-pass eviction D20, PAFF-driver rework),
  `encoder/ratecontrol.c` (`x264_reference_build_list_optimal`),
  `common/macroblock.c` + `encoder/me.c` (per-entry parity replacing
  `b_field_ref_opposite`, D16). `common/frame.h`/`common/frame.c` are **not**
  changed for marking (per-field state deferred to `paff-b-frames`).
- **Invariant**: streams produced after this change remain JM-decodable
  bit-exact; non-PAFF output untouched.
