# Spec: PAFF encoding

## ADDED Requirements

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
clear error. Multi-frame-thread encoding SHOULD remain deterministic as with
frame coding; if determinism cannot be guaranteed within this change, PAFF
SHALL force single-threaded encoding with a documented warning instead.

#### Scenario: Slice threads rejected
- **WHEN** the user requests PAFF together with slice-based threading
- **THEN** encoder initialization fails with a validation error naming the
  unsupported combination

#### Scenario: Frame threads work
- **WHEN** a PAFF stream is encoded with `--threads N` (N > 1) and frame
  threads are enabled under PAFF
- **THEN** the output is byte-identical to the `--threads 1` output of the
  same encode (the x264 frame-thread determinism invariant) and JM-decodable
  bit-exactly

#### Scenario: Frame threads deferred
- **WHEN** frame threads under PAFF cannot be made deterministic within this
  change
- **THEN** PAFF forces `i_threads = 1`, logs a warning, and the limitation is
  documented in `doc/paff.txt`

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
be rejected the same way.

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

### Requirement: Full-matrix conformance

PAFF streams across the full feature matrix (CRF/2-pass/CBR × TFF/BFF × I/P/B)
SHALL decode bit-exactly with the JM reference decoder, and non-PAFF output
SHALL remain bit-identical to the pre-PAFF implementation.

#### Scenario: Full matrix JM round-trip
- **WHEN** the PAFF conformance suite runs the full matrix
- **THEN** every stream matches `--dump-yuv` byte-for-byte under JM ldecod
