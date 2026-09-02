# Proposal: paff-mbtree-remeasure — close the per-field mbtree future-work item by measurement

## Why

`doc/paff.txt` lists "Per-field mbtree propagation" under Future work: the
lookahead/mbtree analyze whole frames, so under PAFF the pair-level propagate
weights are ~2x off per field. The `paff-b-frames` design (D3) gated the fix on
a PSNR/SSIM bound vs MBAFF (checkpoint 4.2), which passed once on a single
synthetic clip — leaving the item in limbo: too weak to implement, too open to
delete. We ran a weightb-style pre-registered measurement on three real clips
and found that mbtree under PAFF performs at or above its progressive
effectiveness everywhere, so the rework has no headroom. The item should be
closed and the measurement stand kept, so nobody reopens it on a hunch.

## What Changes

Documentation and test tooling only. **No encoder behavior change.**

- `doc/paff.txt`: remove the "Per-field mbtree propagation" bullet from Future
  work; add a "Measured and closed" note (protocol, thresholds, results table)
  next to the weightb precedent.
- `encoder/slicetype.c`: rewrite the PAFF caveat comment in
  `macroblock_tree_propagate` to reference the measurement instead of the
  open-ended "do not touch unless the bound fails" gate.
- `tools/bdrate.py` (new): pure-python Bjøntegaard BD-rate (4-point cubic),
  used by the stand.
- `tools/test_paff.sh`: new `mbtree` cell running the full matrix (3 clips via
  env vars, prog/MBAFF/PAFF x mbtree on/off x CRF sweep, gates G0/Q1/Q2);
  PSNR measured through a rawvideo pipe (timestamp-free pairing — the
  dual-input `psnr` filter mis-pairs 30000/1001 content and produces garbage).

## Capabilities

No spec-level behavior changes: encoder output is bit-identical before/after
(this change touches docs, one comment, and test tooling). Opted out via
`skip_specs: true`.

## Impact

- Docs: `doc/paff.txt`.
- Comment-only: `encoder/slicetype.c` (no code touched).
- Tooling: `tools/test_paff.sh`, `tools/bdrate.py`.
- Change archive: `measurement/` — the session's point sets
  (`results2.csv`) and reference scripts, so the design.md D2 numbers stay
  verifiable after `/tmp/paff_mb` is gone.
- No API/ABI impact, no bitstream impact; checkasm unaffected.
