# Proposal: paff-weightb-remeasure

## Why

The `paff-weightb` change killed weighted biprediction under PAFF on the
strength of ONE synthetic dissolve clip (an `xfade` between `testsrc2` and
`smptehdbars`): +0.272% BD-rate against a pre-registered 0.5% floor.  That
clip is weak evidence — it is a perfectly linear blend of two noise-free
test patterns, content a modern encoder handles fine without weights.
The tell: a PROGRESSIVE encode of the same clip also showed ~0% gain, so
the measurement never demonstrated that the clip exercises the feature at
all (no positive control).  The archived design records this as an
accepted limitation ("synthetic dissolve content only; real-world dissolve
footage is not tested").  The force-off therefore rests on a measurement
that may have measured nothing.  ffmpeg can synthesize far more realistic
dissolve/fade content, so a proper re-measurement is cheap.

## What Changes

- Extend the weightb measurement stand in `tools/test_paff.sh` with
  realistic ffmpeg-generated content: crossfades between two REAL scenes
  (external clips via env vars, as in `test_vbv_determinism.sh`, with a
  grained lavfi fallback), dip-to-black fades (`fade` in/out), and a
  film-grain variant (`noise`) — plus the original synthetic xfade clip
  kept as a reference cell to reproduce the 0.272% number.
- Two-stage pre-registered protocol:
  1. **Positive control (progressive)**: CRF 18/23/28/33 sweep, weightb
     on vs off, BD-rate PSNR-Y per clip.  At least one clip must show a
     progressive gain >= 1.0%, else the feature is dead on all tested
     content including progressive and the kill stands confirmed.
  2. **PAFF measurement** (only if the control passes): the same matrix
     under `--paff --tff` and `--bff`, weightb on (locally reverted
     validation force-off) vs off.  Primary-clip (crossfade clips only)
     gain >= 1.0% with a neutral (±0.5%) non-dissolve control -> lift
     the force-off; <= 0.5% -> kill permanently with the numbers
     recorded; in between -> one extended sweep: >= 1.0% there ->
     enable, otherwise kill.
- If the outcome is "enable": re-apply the conformance fix bundle
  reverted by `paff-weightb` (`bipred_weight_buf` widening, `pixel_avg`
  asm extrema on x86/LoongArch) with checkasm coverage, remove the
  validation force-off, re-run the
  full B-field JM conformance matrix with weightb on (conformance was
  already proven 28/28 in `paff-weightb`; this is a regression re-check),
  and update `doc/paff.txt` + the spec.
- If the outcome is "kill": record the new numbers (real-content BD-rate,
  progressive control) in `doc/paff.txt` as the definitive rationale.
- Either way: non-PAFF output stays bit-identical (the validation block
  is gated on `param.b_paff`).

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `paff-encoding`: the weighted-biprediction clause of "Unsupported
  combinations under PAFF" — either the force-off becomes "supported for
  B field pictures" (enable outcome), or its recorded rationale is
  replaced by the real-content measurement (kill outcome).  The delta
  spec is finalized per the measured outcome before archiving.

## Impact

- `tools/test_paff.sh`: new clip generators and a `weightb2` command;
  the old `weightb` command stays for reference.
- `encoder/encoder.c`: validation block — only touched on the enable
  outcome; the enable outcome also touches `common/common.h`
  (`bipred_weight_buf`) and the `pixel_avg` asm (x86, LoongArch) via
  the conformance fix bundle.
- `doc/paff.txt`: the weighted-biprediction paragraph rewritten with the
  new numbers either way; the `weightb` entry in CONTEXT.md updated
  with the verdict either way.
- No public API change; no dependency changes (ffmpeg lavfi only).
- Non-PAFF output bit-identical in all outcomes.
