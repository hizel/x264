## ADDED Requirements

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
the halved `i_mv_range` value (pre-existing behavior) and is out of scope.  The level-derived `i_mv_range` halving for field
coding (shared with MBAFF) and the frame-thread vertical MV clamp in field
lines are already correct and SHALL be preserved.

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
