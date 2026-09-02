# Proposal: paff-weightb

## Why

Under `--paff`, weighted biprediction (`--weightb`, on by default in most
presets) is force-disabled at validation with a warning. The disable was
conservative: the bipred weight tables were already filled per field pass
with field POCs (paff-field-references task 2.2d), but nobody verified that
x264's implicit-weight derivation matches what reference decoders compute
for field pictures. Meanwhile default-preset PAFF encodes silently lose a
default-on quality feature. During exploration we established that x264
signals `weighted_bipred_idc = 2` (implicit, decoder derives weights from
POC distances per 8.4.3) — there are no explicit weights in the
bitstream at all — so the original "explicit weights not honoured"
rationale does not match the code, and the feature may already be correct.

## What Changes

- Lift the validation force-off of `analyse.b_weighted_bipred` under PAFF,
  gated on two acceptance checks (below).
- Conformance gate: the B-field JM round-trip matrix must pass with
  weightb enabled (proves encoder/decoder implicit-weight agreement for
  field pictures).
- Quality gate (decides the feature's fate): CRF sweep on synthetic
  dissolve (crossfade) clips comparing weightb on vs off under PAFF.
  Implicit bipred weights target dissolves/blends, so dissolve content is
  where a gain must show. If there is no measurable gain, or conformance
  fails, the force-off stays permanently and the measurement is recorded
  in `doc/paff.txt` (same pattern as the measured-and-rejected
  row-granular-first-field item).
- Extend `tools/test_paff.sh` / `tools/paff_matrix.sh` with weightb
  configurations and a dissolve-clip generator.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `paff-encoding`: weighted biprediction moves from "disabled with a
  warning" to "supported for B field pictures" (or, if the gates fail, the
  disable becomes permanent and documented as measured).

## Impact

- `encoder/encoder.c`: validation block (the warn-and-disable).
- `common/macroblock.c`: `x264_macroblock_bipred_init_paff` — expected no
  change (tables already carry field-POC implicit weights); any fix here
  would come from a conformance-gate failure.
- `tools/test_paff.sh`, `tools/paff_matrix.sh`: new weightb configs and
  dissolve-clip generation.
- `doc/paff.txt`: the weighted-prediction paragraph and the Future-work
  item.
- No public API change; non-PAFF output must stay bit-identical (the
  validation change is gated on `param.b_paff`).
