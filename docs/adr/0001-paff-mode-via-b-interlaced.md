# PAFF mode selection via `b_interlaced = 2`

**Status: SUPERSEDED by ADR-0002** (`0002-paff-mode-via-b-paff-field.md`).
PAFF is exposed via a separate `x264_param_t.b_paff` field; `b_interlaced`
remains boolean (0 = off, 1 = MBAFF). Rationale: boolean use sites of
`b_interlaced` are numerous and a missed one would silently enable MBAFF
semantics under PAFF; the ABI concern below is already handled by the
established `X264_BUILD` bump practice.

---

PAFF is exposed in the public API by overloading `x264_param_t.b_interlaced`:
0 = progressive, 1 = MBAFF (unchanged), 2 = PAFF. Field order stays in the
separate `b_tff` knob; CLI adds `--paff` which sets `b_interlaced=2`.

Adding a new field to `x264_param_t` was rejected: libx264 copies the param
struct using the `sizeof` it was compiled with, so an application built against
an old header would expose the library to out-of-bounds reads. Overloading the
existing int is ABI-safe. `X264_BUILD` is still bumped because API semantics
changed. Named constants are added to `x264.h` so call sites don't use the bare
literal 2.

Consequence: third-party code testing `if (param.b_interlaced)` sees PAFF as
"interlaced", which is semantically acceptable. *(Retracted: this silently
enables MBAFF code paths under PAFF — one of the reasons this ADR was
superseded.)*
