# Spec: PAFF encoding

## ADDED Requirements

### Requirement: Field reference lists

Reference picture lists for field pictures SHALL be constructed per H.264
§8.2.4.2.2 and §8.2.4.2.5: each available reference frame expands into field
references alternating parity, starting with the parity of the current field;
the first field of the current complementary pair SHALL be available as a
short-term reference when coding the second field.

#### Scenario: Second field references first field
- **WHEN** the second field of a complementary pair is coded as P
- **THEN** its reference list contains the already-coded first field of the same
  pair as an available short-term reference

#### Scenario: Parity-alternated ordering
- **WHEN** a P field picture builds its initial RefPicList0 from multiple
  reference frames
- **THEN** field references alternate parity beginning with the current field's
  parity, per §8.2.4.2.5

### Requirement: Field reference marking

The decoded-reference-picture marking process (§8.2.5) SHALL run after each
coded field (§8.2.5.1). Sliding-window marking (§8.2.5.3, the default mode
emitted by PAFF I/P) SHALL operate in DPB-slot units: each complementary
reference field pair is one DPB slot, `max_num_ref_frames` accounting SHALL
count slots (not individual fields), and eviction SHALL mark an entire pair
"unused for reference". Consequently the second field of a pair SHALL build its
reference list against the DPB state that results from storing the first field.
Per-field (single-field) marking and MMCO for field pictures are out of scope
here — deferred to `paff-b-frames` (design D4/D10/D18). Long-term marking is out
of scope (design D19): the encoder never emits it, matching the x264 baseline.

#### Scenario: Sliding window on pairs
- **WHEN** the number of stored reference pairs (DPB slots) reaches
  `max_num_ref_frames` and a new pair's first field is stored as a reference
- **THEN** the oldest short-term reference pair is marked "unused for reference"
  (both its fields), the second field's reference list excludes that pair, and
  the stream remains decodable by JM without reference errors

### Requirement: Multi-reference field conformance

PAFF streams whose P fields use multiple reference fields of mixed parity SHALL
decode bit-exactly with the JM reference decoder.

#### Scenario: JM round-trip with 16 reference fields
- **WHEN** a PAFF stream is encoded with RefPicList0 filled up to 16 reference
  field entries (the `X264_REF_MAX` ceiling on the expanded list, D6) and
  decoded by JM ldecod
- **THEN** its output YUV matches the encoder's `--dump-yuv` reconstruction
  byte-for-byte
