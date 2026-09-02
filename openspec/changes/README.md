# Changes

## PAFF series (order matters — each depends on the previous)

1. **paff-core-ip** — JM test rig, API/CLI (`b_interlaced=2`, `--paff`), field-pair
   coding of I/P pictures. Checkpoint: I/P streams bit-exact vs JM.
2. **paff-field-references** — full per-field reference lists and DPB marking.
   Checkpoint: multi-ref P fields bit-exact vs JM.
3. **paff-b-frames** — B field pictures, field direct modes and MV prediction.
   Checkpoint: hierarchical B-field GOPs bit-exact vs JM.
4. **paff-sei-hrd-rc** — per-field SEI/HRD, rate control, threading, docs, CI.
   Checkpoint: full matrix (CRF/2-pass/CBR × TFF/BFF × I/P/B) bit-exact vs JM.

Start with `paff-core-ip`; do not start a later change before the previous
one's checkpoint passes. Background: `docs/adr/0001-paff-mode-via-b-interlaced.md`,
glossary: `CONTEXT.md` (repo root).
