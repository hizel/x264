# Proposal: PAFF — motion-vector limits in field units

## Why

Under PAFF every coded picture is a field and every motion vector is expressed
in field lines, but the vertical MV-limit geometry in the analysis pass is
still computed from the full frame height (`h->mb.i_mb_height`, frame-row
`i_mb_y`).  The limit is therefore about 2x wider than the field's reference
planes plus their emulated edge, so motion search can walk off into the
padding whenever the level-derived `i_mv_range` exceeds the field border
(high levels, large `--mvrange`, HD+ resolutions).  Symmetrically, the
lookahead has the opposite defect: it analyzes whole frames (design D3 of
the PAFF series), yet its lowres MV range is derived from the PAFF-halved
`i_mv_range`, giving it half the vertical search range progressive encoding
gets for the same content and the same temporal distance.  Both defects are
quality-only (the padding read is memory-safe; conformance is unaffected),
but they cost bits and search time on exactly the interlaced material PAFF
targets.  Recorded as a known pre-existing issue in `doc/paff.txt`.

## What Changes

- **Coding-pass MV limits in field geometry** (`encoder/analyse.c`): under
  PAFF compute the vertical `mv_min/max[1]` (and the derived spel/fpel row
  limits) from the field MB grid — field row `i_mb_y >> 1`, field height
  `i_mb_height >> 1` — instead of the frame grid.  Horizontal limits are
  unchanged.  The frame-thread wait thresholds and `i_mv_range_thread`
  clamp are already in field lines and become consistent with the geometry
  they clamp.
- **Lookahead lowres range in frame units** (`encoder/slicetype.c`): the
  lookahead is frame-based under PAFF (lowres planes are full frames), so
  its `mv_range = 2 * i_mv_range` must undo the `PARAM_FIELDCODE` halving
  that sizes the coding pass.  Scenecut/mbtree decisions see the same
  vertical range as progressive encoding.
- **Unit-consistency audit** of the remaining `i_mv_range` consumers:
  MV cost tables (`init_costs`, sized by the halved value — must stay the
  coding-pass value), VUI `log2_max_mv_length_vertical` (field units are
  correct for field pictures), the level `CHECK("MV range")` (halved value
  is more lenient — fine), the horizontal spel clamp (shares the halved
  value — pre-existing over-strictness, consistent with the VUI signal;
  out of scope), and predictor clipping in `common/macroblock.c`
  (consumes `mv_min/max` — inherits the fix).  Document the verdict for
  each in the design; change code only where the units are wrong.
- **Re-baseline**: PAFF streams with large vertical search range may change
  bytes; the full conformance matrix (CRF/2-pass/CBR × TFF/BFF × I/P/B)
  is re-run and re-baselined, with before/after bitrate + search-time
  numbers on clips that exercise the wide range.  Non-PAFF output
  (progressive, MBAFF) SHALL remain bit-identical.
- **Docs**: remove the known-issue paragraph from `doc/paff.txt`;
  a `--longhelp` note that under `--paff` `--mvrange` is in field lines;
  `CONTEXT.md` glossary entry if a term needs sharpening.

Non-goals:

- Row-granular readiness for the first field of a pair (dropping the
  intermediate sweep) — separate threading change.
- Weighted biprediction (`--weightb`) explicit weights for field bipred —
  separate change.
- Per-field mbtree propagation (`slicetype.c` D3 caveat): explicitly gated
  on a PSNR/SSIM bound that the archived series verified as passing —
  checked, deliberately excluded.
- Sliced threads / low-latency slicing and AVC-Intra under PAFF — stay
  rejected.
- Un-halving the horizontal MV range clamp under PAFF (pre-existing
  over-strictness, consistent with VUI signaling) — separate change, if
  ever.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `paff-encoding`: add a requirement pinning the units of motion-vector
  limits under PAFF — field geometry for the coding passes, frame geometry
  for the frame-based lookahead — with scenarios for the over-search fix,
  the lookahead range parity with progressive, and the non-PAFF
  bit-identity invariant.

## Impact

- Code: `encoder/analyse.c` (y-limit computation), `encoder/slicetype.c`
  (lookahead `mv_range`), possibly small touches in `encoder/set.c` /
  `common/macroblock.c` if the audit finds a real unit bug.
- Bitstreams: PAFF output may change for configurations where
  `4 * i_mv_range` exceeds the field border; progressive and MBAFF output
  must not change by a single byte.
- Tests: `tools/test_paff.sh` matrix re-baseline; JM round-trip unchanged
  in procedure; `checkasm` unaffected (no DSP changes).
- Docs: `doc/paff.txt`, `CONTEXT.md`.
- No public API / ABI impact; no `x264.h` change.
