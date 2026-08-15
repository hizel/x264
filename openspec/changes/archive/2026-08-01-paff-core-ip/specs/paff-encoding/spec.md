# Spec: PAFF encoding

## ADDED Requirements

### Requirement: Field-picture coding mode selection

The encoder SHALL support Picture-Adaptive Frame/Field (PAFF) coding,
selectable via a dedicated `b_paff` field in `x264_param_t`, distinct from
the existing `b_interlaced` field (0 = off, 1 = MBAFF).  When PAFF is selected,
every coded picture of the sequence SHALL be a coded field
(`field_pic_flag = 1`), and the SPS SHALL signal `frame_mbs_only_flag = 0`
and `mb_adaptive_frame_field_flag = 0`.  PAFF and MBAFF SHALL be mutually
exclusive within one encoded sequence; encoder initialization SHALL fail if
both are requested.

#### Scenario: PAFF mode enabled via API
- **WHEN** the application sets `b_paff=1` and opens the encoder
- **THEN** the emitted SPS has `frame_mbs_only_flag=0` and
  `mb_adaptive_frame_field_flag=0`, and every slice header has `field_pic_flag=1`

#### Scenario: MBAFF mode unchanged
- **WHEN** the application selects MBAFF interlaced mode (as before this change)
- **THEN** the bitstream is bit-identical to the pre-PAFF implementation

#### Scenario: PAFF and MBAFF conflict rejected
- **WHEN** the application requests `b_paff=1` together with `b_interlaced=1`
  or `--fake-interlaced`
- **THEN** encoder initialization fails with a validation error

#### Scenario: Threading restricted under PAFF
- **WHEN** PAFF is enabled while frame threading or sliced threads are requested
- **THEN** the encoder runs single-threaded (with a warning for frame threads,
  with a validation error for sliced threads) until the follow-up change
  defines the threading policy

### Requirement: Complementary field pairs per access unit

The encoder SHALL code each input frame as a complementary field pair within a
single access unit: two coded pictures sharing one `frame_num`, with
`bottom_field_flag` selecting parity of each picture.  Both fields SHALL be
returned in a single `x264_encoder_encode` call with one frame-level PTS in
`pic_out`.  The display/coding order of the pair SHALL follow the configured
field order (top-first or bottom-first).

#### Scenario: Top-field-first pair
- **WHEN** PAFF is enabled with top-field-first order and one frame is encoded
- **THEN** the first coded picture in decoding order has `bottom_field_flag=0`
  and the second has `bottom_field_flag=1`, both with the same `frame_num`

#### Scenario: Bottom-field-first pair
- **WHEN** PAFF is enabled with bottom-field-first order
- **THEN** the first coded picture in decoding order has `bottom_field_flag=1`

### Requirement: Per-field picture order count

Each coded field SHALL carry its own picture order count such that the derived
`TopFieldOrderCnt` and `BottomFieldOrderCnt` reflect display order of the fields
per H.264 §8.2.1.

#### Scenario: POC continuity across a GOP
- **WHEN** a sequence of frames is encoded in PAFF mode
- **THEN** decoding the stream with the JM reference decoder produces pictures in
  the same display order as the input, with field order counts increasing per
  field

### Requirement: Field deblocking boundary

Deblocking filtering SHALL NOT be applied across the boundary between the two
fields of a complementary pair.  Since each field is a separate coded picture
with its own picture boundaries, the deblock filter SHALL naturally stop at
picture edges — no special pair-boundary logic is required.

#### Scenario: Pair boundary not filtered
- **WHEN** both fields of a pair are reconstructed as separate coded pictures
- **THEN** each field's deblock filter operates within its own picture bounds,
  and reconstruction matches JM ldecod bit-exactly

### Requirement: I/P field bitstream conformance

Any PAFF stream using only I and P field pictures SHALL decode bit-exactly with
the JM reference decoder: the encoder's reconstructed pictures (`--dump-yuv`)
SHALL equal the JM decoder output for every picture.

#### Scenario: JM round-trip for I and P fields
- **WHEN** a PAFF stream with I and P field pictures (TFF and BFF) is decoded by
  JM ldecod
- **THEN** its output YUV matches the encoder's `--dump-yuv` reconstruction
  byte-for-byte

#### Scenario: checkasm regression
- **WHEN** PAFF support is added
- **THEN** `checkasm8` and `checkasm10` pass without failures on all supported
  architectures (no new asm introduced, no existing asm broken)

### Requirement: CLI access

The CLI SHALL expose PAFF mode (e.g. `--paff`) composable with `--tff`/`--bff`,
and SHALL keep auto-detect-and-warn behavior unchanged for non-PAFF modes.

#### Scenario: CLI encoding
- **WHEN** the user runs `x264 --paff --tff input.yuv -o out.264`
- **THEN** the output is a conformant PAFF stream with top-field-first pairs
