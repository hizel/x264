# Spec: Field-aware SEI

## ADDED Requirements

### Requirement: Per-field pic_timing SEI

When field pictures are coded (PAFF), a `pic_timing` SEI message SHALL be emitted
in every access unit (i.e. per coded field, not per frame) whenever pic_timing
SEI is emitted at all (VUI `pic_struct_present_flag` or HRD parameters
present), carrying
`pic_struct = 1` for a top field and `pic_struct = 2` for a bottom field, as
required by Table D-1 for pictures with `field_pic_flag = 1`. Clock timestamp
count (`NumClockTS`) SHALL be 1 per field picture.

#### Scenario: Top field access unit
- **WHEN** a top field picture is emitted in PAFF mode with pic_timing
  signaling enabled
- **THEN** its access unit contains a pic_timing SEI with `pic_struct = 1`

#### Scenario: Bottom field access unit
- **WHEN** a bottom field picture is emitted in PAFF mode with pic_timing
  signaling enabled
- **THEN** its access unit contains a pic_timing SEI with `pic_struct = 2`

#### Scenario: Frame modes unchanged
- **WHEN** the encoder runs in progressive or MBAFF mode
- **THEN** pic_timing SEI emission is bit-identical to the pre-PAFF implementation

### Requirement: Field-unit HRD timing

When PAFF is active with HRD parameters present, `buffering_period` and
`pic_timing` delays (`cpb_removal_delay`, `dpb_output_delay`) SHALL be expressed
per field access unit, and `buffering_period` SEI SHALL be emitted at the
required AU boundaries per Annex C/D.

#### Scenario: CBR stream with fields
- **WHEN** a PAFF stream is encoded with `--nal-hrd cbr`
- **THEN** every field access unit carries consistent CPB/DPB delays such that an
  HRD-conformant decoder neither underflows nor overflows the CPB at field
  granularity

### Requirement: Honest dec_ref_pic_marking SEI

When `dec_ref_pic_marking` SEI repetition is active under PAFF, the message
SHALL carry the true `original_field_pic_flag` (and `original_bottom_field_flag`
where applicable) of the reference picture instead of the currently hardcoded 0.

#### Scenario: Field picture marking repetition
- **WHEN** dec_ref_pic_marking SEI is emitted for a field picture in PAFF mode
- **THEN** `original_field_pic_flag = 1` and the field parity flag matches the
  coded picture
