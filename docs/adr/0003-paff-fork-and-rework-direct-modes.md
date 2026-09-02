# PAFF direct-mode / MV-prediction paths are fork-and-reworked, not shared with MBAFF

**Status: accepted**

PAFF B field pictures need field-colocated temporal direct, MV scaling, and
field-aware spatial / MV prediction (H.264 §8.4.1.2.4 / §8.4.1.3). x264's MBAFF
code already implements all of these — but it is **unreachable under PAFF** and
is the *reference shape*, not a reusable path.

`b_interlaced` (MBAFF) and `b_paff` are mutually exclusive (ADR-0002), and the
PAFF driver runs with `SLICE_MBAFF = 0` while setting `MB_INTERLACED = 1` only
to select field scans / CABAC contexts. Every interlaced branch the B-frames
change touches is gated on `PARAM_INTERLACED` (temporal direct,
`mvpred.c:195`), dispatched via `SLICE_MBAFF` (spatial, `mvpred.c:461`), or on
`SLICE_MBAFF` (`mvpred.c:563`, `x264_mb_predict_mv_ref16x16`). Under PAFF all
fall through to the *progressive* path, and the MBAFF mismatch predicate
`fref[1][0]->field[mb_xy] != MB_INTERLACED` is false for every PAFF macroblock
(the picture is uniformly one field). There is nothing to audit in place.

The alternative — refactoring the MBAFF paths to be keyed on field-picture
semantics shared with PAFF — was rejected: it would perturb the hot MBAFF paths
for a mode that cannot reach them, and MBAFF's MB-pair-field semantics (e.g.
`mb_y = (i_mb_y & ~1) + col_parity`) are the wrong model for a uniformly-field
picture anyway. PAFF instead introduces a parallel `FIELD_PIC`-keyed
field-colocated path, re-derived against §8.4.1.2.4 / §8.4.1.3, not by MBAFF
analogy.

Consequence: PAFF and MBAFF direct-mode logic now live side by side. A future
change that wants to unify them must first make the MBAFF branches reachable
under `FIELD_PIC` — a larger refactor than this change's scope.
