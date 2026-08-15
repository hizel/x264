# PAFF mode selection via separate `b_paff` field

**Status: accepted** — supersedes ADR-0001.

PAFF is exposed in the public API as a new `int b_paff` field in
`x264_param_t` (0 = off, 1 = PAFF); `b_interlaced` remains boolean
(0 = off, 1 = MBAFF) and the two are mutually exclusive. `X264_BUILD` is
bumped because the struct grew.

ADR-0001 chose overloading `b_interlaced` with value 2 to avoid growing the
param struct, fearing out-of-bounds struct copies by applications built
against an old header. That concern is already covered by the project's
established practice: `X264_BUILD` is bumped on every ABI change and
`x264_encoder_open` is a versioned symbol, so a mismatched app fails to
link/load rather than reading out of bounds. Meanwhile the overload had a
real cost: `b_interlaced` is used as a boolean throughout the codebase
(`PARAM_INTERLACED`, truthiness in `set.c`, OPT handlers in `base.c`), and a
single missed site would silently enable MBAFF semantics under PAFF —
including third-party code testing `if (param.b_interlaced)`. A separate
field leaves all existing code untouched.

Consequence: PAFF-aware callers must check `b_paff` explicitly; code testing
only `b_interlaced` sees a PAFF sequence as non-interlaced, which is correct
for the MBAFF semantics that flag actually controls.
