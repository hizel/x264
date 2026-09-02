# Delta spec: paff-encoding (paff-weightb-remeasure)

Outcome: KILL.  The stage-1 positive control failed (results-stage1.md):
no clip reached the pre-registered 1.0% progressive gain (largest:
+0.526% on the legacy synthetic clip; the real-scene crossfade gained
+0.457% at QCIF and +0.275% at 720x576), so the PAFF measurement was
moot and never ran.  The force-off stays; the rationale recorded in the
requirement below now rests on the real-content re-measurement.

## MODIFIED Requirements

### Requirement: Unsupported combinations under PAFF

Combinations of PAFF with features that have no defined field-picture
semantics SHALL be rejected at validation time with a clear error naming the
unsupported combination, rather than silently ignored or mis-encoded. Weighted
prediction (`--weightp`) SHALL either produce conformant output under PAFF or
be rejected the same way. Weighted biprediction (`--weightb`) SHALL be
force-disabled under PAFF with a one-shot warning: conformance-correct but
measured gainless — `doc/paff.txt` records both the original
synthetic-dissolve numbers and the real-content re-measurement with its
progressive positive control.

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
  but measured gainless twice — a CRF 18/23/28/33 sweep on a synthetic
  dissolve clip gained only 0.272% BD-rate (PSNR-Y), below the 0.5%
  acceptance floor fixed before measuring, and the controlled
  re-measurement with a progressive positive control (real-scene
  crossfade, grained synthetic crossfade, dip-to-black, legacy synthetic,
  non-dissolve control) failed its gate on all tested content including
  progressive (largest gain +0.526%, gate >= 1.0%), leaving the PAFF
  question moot
