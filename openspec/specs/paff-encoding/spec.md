# paff-encoding Specification

## Purpose

Picture-Adaptive Frame/Field (PAFF) coding: encoding each input frame as a
complementary field pair (field_pic_flag=1), as an alternative to MBAFF.
## Requirements
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
- **WHEN** PAFF is enabled while sliced threads are requested
- **THEN** encoder initialization fails with a validation error naming the
  unsupported combination; requesting frame threads (`--threads N`, N > 1)
  is accepted and enables frame-threaded PAFF encoding

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

### Requirement: Motion-vector limit units under PAFF

Under PAFF, vertical motion-vector limits SHALL be expressed in the units of
the data they constrain.  For the coding passes, where every coded picture is
a field and reference planes are stored in field layout with per-field
emulated edges, the vertical search window SHALL be derived from the field
macroblock grid (field row index, field picture height), so motion search
cannot select candidates outside the field's reference planes plus their
emulated edge regardless of level or `--mvrange`.  For the lookahead, which
analyzes whole frames on frame lowres planes, the lowres search range SHALL
be derived from frame geometry and SHALL match the range progressive
encoding applies to the same content.  Horizontal geometry is frame/field
symmetric and unaffected by this change; the horizontal range clamp shares
the halved `i_mv_range` value (pre-existing behavior) and is out of scope.  The
level-derived `i_mv_range` halving for field coding (shared with MBAFF) and
the frame-thread vertical MV clamp in field lines are already correct and
SHALL be preserved.

#### Scenario: No over-search into reference padding
- **WHEN** a PAFF stream is encoded at a level or `--mvrange` whose vertical
  search range exceeds the field picture border (e.g. high level at HD
  resolution)
- **THEN** every motion candidate evaluated by the coding-pass search stays
  within the referenced field's planes plus emulated edge, for both parities
  and for the second field of a pair referencing the first

#### Scenario: Lookahead range parity with progressive
- **WHEN** the same interlaced source is encoded with `--paff` and without
  (progressive path) using identical analysis settings
- **THEN** the lookahead's vertical lowres search range is the same in both
  runs (in frame units), so scenecut and mbtree decisions are not biased by
  a halved range under PAFF; the range is observable via the debug-level
  log of the computed lowres `mv_range`, which the PAFF test script
  compares between the two runs (it is not observable in the bitstream)

#### Scenario: Non-PAFF bit-identity
- **WHEN** progressive or MBAFF streams are encoded before and after this
  change with identical parameters
- **THEN** the outputs are bit-identical (all PAFF paths are gated on
  `param.b_paff`)

#### Scenario: PAFF conformance preserved
- **WHEN** the PAFF conformance matrix (CRF/2-pass/CBR × TFF/BFF × I/P/B) is
  re-run after the change
- **THEN** every stream still matches `--dump-yuv` byte-for-byte under JM
  ldecod, and changed PAFF streams are re-baselined with before/after
  bitrate and encoding-time recorded

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

### Requirement: Rate control per field pair

Under PAFF, rate control SHALL keep frame-level QP decisions while emitting a QP
per coded field (each field picture carries its own slice header and therefore
its own QP), and SHALL account bits per field for ABR/CBR/CRF and 2-pass modes.

#### Scenario: CBR PAFF stream
- **WHEN** a PAFF stream is encoded in CBR mode
- **THEN** the output respects the target bitrate and VBV constraints at field
  access-unit granularity

### Requirement: Threading behavior under PAFF

Under PAFF, a complementary field pair SHALL be coded within one frame-thread
slot, and slice-based threading SHALL be rejected at validation time with a
clear error. Frame-threaded PAFF encoding (`--threads N`, N > 1) SHALL be
deterministic at a fixed thread count: two runs with identical parameters and
identical N SHALL produce byte-identical output, matching the frame-thread
determinism invariant of progressive encoding (including the semantics of
`--non-deterministic`). Output produced with N > 1 threads is not required to
be byte-identical to the single-threaded output of the same parameters,
because the motion-vector range clamp of frame threading applies as in
progressive encoding; every threaded output SHALL remain a conformant,
reference-decodable PAFF bitstream with the same frame types and reference
structure as the single-threaded run. Reference readiness SHALL be enforced
per field and per phase: the first field of a pair SHALL become usable as a
reference only after it has been fully reconstructed and its reference data
generated by the intermediate sweep, and rows of the second field SHALL
become usable only as their reconstruction and row filtering complete, with
dependent threads restricting their motion-vector range accordingly instead
of reading incomplete reference data.

#### Scenario: Slice threads rejected
- **WHEN** the user requests PAFF together with slice-based threading
- **THEN** encoder initialization fails with a validation error naming the
  unsupported combination

#### Scenario: Frame threads work
- **WHEN** a PAFF stream is encoded with `--threads N` (N > 1) and with
  `--threads 1` using otherwise identical parameters
- **THEN** both runs are deterministic at their fixed thread count (repeated
  runs with the same N are byte-identical), both outputs decode bit-exactly
  in the reference decoder (JM), share the same frame-type and reference
  structure, and diverge in encoded bytes and quality only within the
  tolerance established for progressive frame threading (N > 1 vs N = 1)

#### Scenario: Frame threads deferred
- **WHEN** frame-threaded PAFF encoding cannot be validated (deadlock,
  nondeterminism at fixed N, conformance failure, quality regression beyond
  the progressive-threading tolerance, or a data race surfaced during
  implementation)
- **THEN** the change is not merged with the forced-`i_threads = 1` path
  removed: the v1 bailout (PAFF forces single-threaded encoding with a
  warning, documented in `doc/paff.txt`) stays in place until the failure is
  fixed, and sliced threads remain rejected in all cases

#### Scenario: Reference readiness gating
- **WHEN** a dependent frame thread could reference a field of an in-flight
  pair whose relevant rows are not yet fully reconstructed and filtered
  (first field before the intermediate sweep completes; second-field rows
  beyond the completed row count)
- **THEN** the dependent thread waits instead of reading incomplete reference
  data, restricts its motion-vector range to the completed rows, and no
  deadlock or partial-reference read occurs for any supported thread count;
  the pair's own first field (referenced by its second field) is never
  waited on, since both are coded by the same thread

### Requirement: IDR field pair structure

Under PAFF, a keyframe (IDR) complementary field pair SHALL be coded as an
IDR first field followed by a non-IDR P second field that references the
pair's first field (QSV/libmfx-compatible structure). Both fields of the
pair SHALL share one `frame_num`, and the second field SHALL be a reference
field (`nal_ref_idc` != 0), as required by §7.4.3 for two fields of opposite
parity sharing one `frame_num`.

#### Scenario: Keyframe pair
- **WHEN** a PAFF stream hits a keyframe
- **THEN** the first field's access unit is an IDR access unit and the
  second field is coded as a P field picture referencing the first field
  of the same pair

#### Scenario: Buffering period SEI on keyframes
- **WHEN** a PAFF keyframe pair is emitted with HRD parameters present
- **THEN** the buffering_period SEI is present in the IDR (first field)
  access unit, satisfying D.2.2

### Requirement: Unsupported combinations under PAFF

Combinations of PAFF with features that have no defined field-picture
semantics SHALL be rejected at validation time with a clear error naming the
unsupported combination, rather than silently ignored or mis-encoded. Weighted
prediction (`--weightp`) SHALL either produce conformant output under PAFF or
be rejected the same way. Weighted biprediction (`--weightb`) SHALL be
force-disabled under PAFF with a one-shot warning: the implicit-weight
derivation was verified conformance-correct for B field pictures, but the
measured quality gain on dissolve content (the content implicit bipred
weights exist for) is below the acceptance floor fixed before measuring, and
the rejection rationale with the measurement numbers SHALL be recorded in
`doc/paff.txt`.

#### Scenario: CLI pulldown rejected
- **WHEN** the user requests `--pulldown` together with `--paff`
- **THEN** encoder initialization fails with a validation error naming the
  unsupported combination

#### Scenario: Library per-frame pic_struct clamped
- **WHEN** a library client feeds frames with `pic.i_pic_struct` other than
  AUTO under PAFF
- **THEN** the value is clamped to AUTO with a one-shot warning (each input
  frame is coded as one field pair, so per-frame pulldown patterns do not
  apply)

#### Scenario: AVC-Intra rejected
- **WHEN** the user requests PAFF together with an AVC-Intra class
- **THEN** encoder initialization fails with a validation error naming the
  unsupported combination (II-pair AVC-Intra support is future work)

#### Scenario: Weighted prediction enabled
- **WHEN** `--weightp` is used under PAFF and the streams pass the JM
  conformance round-trip
- **THEN** weighted prediction for field pictures is enabled and documented

#### Scenario: Weighted prediction rejected
- **WHEN** `--weightp` under PAFF fails the JM conformance round-trip
- **THEN** the combination is rejected at validation with a clear error and
  the limitation is documented in `doc/paff.txt`

#### Scenario: Weighted biprediction force-disabled with recorded measurement
- **WHEN** weighted biprediction (`--weightb`, on by default in most
  presets) is in effect together with `--paff`
- **THEN** validation disables `analyse.b_weighted_bipred` with a one-shot
  warning and encoding continues weightb-off, and `doc/paff.txt` records
  the rationale: implicit weights proved conformance-correct (28/28 B-field
  JM round-trip with weightb forced on, ffmpeg/NVDEC/VAAPI pixel-exact)
  but a CRF 18/23/28/33 sweep on a synthetic dissolve clip gained only
  0.272% BD-rate (PSNR-Y), below the 0.5% acceptance floor fixed before
  measuring

### Requirement: Full-matrix conformance

PAFF streams across the full feature matrix (CRF/2-pass/CBR × TFF/BFF × I/P/B)
SHALL decode bit-exactly with the JM reference decoder, and non-PAFF output
SHALL remain bit-identical to the pre-PAFF implementation.

#### Scenario: Full matrix JM round-trip
- **WHEN** the PAFF conformance suite runs the full matrix
- **THEN** every stream matches `--dump-yuv` byte-for-byte under JM ldecod
