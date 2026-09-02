# Per-field `ref_poc` / `i_ref` stored with a parity dimension

**Status: accepted**

Under PAFF a B field's temporal-direct `map_col_to_list0` reads the *stored*
colocated picture's `ref_poc[0]` (`macroblock.c:460`). A field pair has only
one `ref_poc[0]`, reflecting a single parity's expansion, so a later B field
colocating to the *other* parity reads the wrong POCs. Both parities must
coexist on the stored frame.

Decision: add a parity dimension to the existing arrays in `common/frame.h` —
`int i_ref[2][2]` and `int ref_poc[2][2][X264_REF_MAX]`
(`[list][parity][ref]`) — rather than a parallel parity-keyed array. Reasons:
`inv_ref_poc[2]` already took a parity slot in `paff-field-references`
(`macroblock.c:502`), so `ref_poc` matches its shape; adding the dimension
turns a forgotten per-parity update from a silent bug into a compile error at
the few read sites (`macroblock.c:460`, `mvpred.c:592`); and the frame-level
slot is genuinely insufficient, so keeping a parallel "frame-level" copy
invites divergence.

Consequence: every `ref_poc[list][i]` / `i_ref[list]` access site gains a
parity index. The change is mechanical and localized — which is the point: a
mode that needs both parities should not be able to read either by accident.
