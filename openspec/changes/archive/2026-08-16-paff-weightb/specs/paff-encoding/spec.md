# Delta spec: paff-encoding (paff-weightb)

Outcome: the conformance gate passed but the quality gate failed (dissolve
BD-rate gain 0.272%, below the pre-registered 0.5% floor), so the kill-switch
path was taken: weighted biprediction stays force-disabled under PAFF, now
permanently and with the measurement recorded as the reason.

## MODIFIED Requirements

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

#### Scenario: Non-PAFF output unchanged
- **WHEN** the same encodes run without `--paff`
- **THEN** progressive and MBAFF outputs are bit-identical to the
  pre-change encoder at every tested configuration
