# Spec: PAFF encoding

## Verification oracle

The conformance criterion is **byte-exact round-trip**: a PAFF bitstream decoded
by a conformant H.264 decoder SHALL reproduce the encoder's `--dump-yuv`
reconstruction byte-for-byte.

JM `ldecod` is the canonical ITU reference decoder for *frame* / *MBAFF*
streams. **It cannot serve as the oracle for PAFF field pictures**: JM 19.0
fails to reconstruct the bottom field of a PAFF field pair (emits gray/128)
even on streams a second conformant decoder decodes byte-exactly — a JM bug,
not an encoder defect. The PAFF verification oracle is therefore **ffmpeg**
(`ffmpeg -i <stream> -pix_fmt yuv420p`), a conformant, independent decoder.
Where the requirements below say "a conformant H.264 decoder", verification is
performed with ffmpeg; the legacy "JM ldecod" wording is retained only as the
nominal reference name and is not the operative oracle for PAFF.

## ADDED Requirements

### Requirement: B field pictures

The encoder SHALL support B field pictures: both field pictures of a
complementary pair MAY be of slice type B, with RefPicList0 and RefPicList1
constructed per H.264 §8.2.4.2.4 and §8.2.4.2.5. Both fields of a pair SHALL
share the slice type decided for their frame (field-granular slice types are
not produced).

#### Scenario: Hierarchical B-field GOP
- **WHEN** a PAFF stream is encoded with a hierarchical B-frame GOP structure
- **THEN** B field pictures carry conformant L0/L1 field reference lists and
  the stream decodes byte-exactly (decoder output matches `--dump-yuv`)

### Requirement: Field direct modes and MV prediction

Temporal direct mode for field pictures SHALL select the colocated field and
scale motion vectors per §8.4.1.2.4; spatial direct mode and motion vector
prediction SHALL derive neighbors in a uniformly-field picture per §8.4.1.3.

#### Scenario: Temporal direct with colocated fields
- **WHEN** a B field contains temporal-direct macroblocks
- **THEN** the derived motion vectors reproduce the spec derivation
  bit-exactly (verified by byte-exact decode vs `--dump-yuv`)

#### Scenario: Spatial direct in a uniformly-field picture
- **WHEN** a B field contains spatial-direct macroblocks
- **THEN** the neighbour-derived motion vectors reproduce the spec derivation
  bit-exactly (verified by byte-exact decode vs `--dump-yuv`)

### Requirement: Full GOP conformance

Any PAFF stream with I, P, and B field pictures SHALL decode byte-exactly with
a conformant H.264 decoder (verified via ffmpeg; see "Verification oracle").

#### Scenario: Round-trip with all slice types
- **WHEN** a PAFF stream with I, P, and B field pictures is decoded by a
  conformant H.264 decoder
- **THEN** its output YUV matches the encoder's `--dump-yuv` reconstruction
  byte-for-byte

#### Scenario: BREF field-pair eviction at the DPB slot cap
- **WHEN** a PAFF stream with `--ref >= 2` and a hierarchical B-pyramid reaches
  the DPB slot cap
- **THEN** MMCO opcode 1 removes the old BREF field pair with field PicNum
  arithmetic (§8.2.4.1), the stream's `adaptive_ref_pic_marking_mode_flag` is
  asserted non-empty, and a conformant decoder decodes it byte-exactly
