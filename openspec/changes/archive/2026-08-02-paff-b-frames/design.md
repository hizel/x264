# Design: PAFF — B field pictures and field MV prediction

## Context

After `paff-field-references`, P fields have full field reference lists. B fields
add a second list (L1) and the direct modes, where the spec's field semantics
diverge most from frame semantics: the "colocated picture" for temporal direct
is a *field*, and MV scaling uses field POC distances (§8.4.1.2.4).

x264's MBAFF code already implements field MV prediction and direct mode
(`common/mvpred.c`) — but under MBAFF the *picture* is a frame and only MB pairs
are field. Under PAFF the picture is uniformly a field; the MBAFF paths are the
right foundation but must be audited for frame-picture assumptions (neighbor
availability, colocated indexing).

## Goals / Non-Goals

**Goals:**
- Conformant B field pictures, including hierarchical B-field GOPs, JM
  bit-exact.
- Temporal and spatial direct modes for fields per §8.4.1.2.4/§8.4.1.3.
- mbtree/lookahead untouched: frame-level costs map to both fields of the pair.

**Non-Goals:**
- Field-granular slice types (one field P, the other B — legal per spec, no
  practical value).
- Rate-control adaptation → `paff-sei-hrd-rc`. **Soundness boundary:** the
  current rate control runs once per pair (`ratecontrol_start`/`end` are
  pair-level, one `i_global_qp` feeds both passes, `ratecontrol_end` gets the
  merged bit-count). Under `--qp`/1-pass this is bit-exact; under ABR/CBR/VBV/
  2-pass the HRD sees one double-sized picture per pair (§C.3.1 accounts bits
  per picture) → silently non-conformant. Until `paff-sei-hrd-rc`, PAFF B
  **hard-errors** ABR/CBR/VBV/2-pass (D8): a warning risks a user shipping a
  silently non-conformant stream; the failure is trivially relaxed later.

## Decisions

### D1: Slice-type decisions stay frame-granular

Lookahead and slicetype continue to analyze whole frames (existing lowres path);
both fields of a pair inherit the frame's slice type and reference set. This
avoids a rewrite of `encoder/lookahead.c`/`slicetype.c`. Field-granular slice
types are a possible later optimization, not required for conformance.

### D2: Fork-and-rework the direct/prediction paths — MBAFF code is unreachable under PAFF

`PARAM_INTERLACED` (MBAFF) is mutually exclusive with PAFF (`encoder.c`), and
the PAFF driver runs with `SLICE_MBAFF = 0`. Every interlaced branch this change
touches is gated on `PARAM_INTERLACED` (temporal direct, `mvpred.c:195`),
dispatched via `SLICE_MBAFF` (spatial, `mvpred.c:461`), or on `SLICE_MBAFF`
(`mvpred.c:563`, `x264_mb_predict_mv_ref16x16`). Under PAFF all fall through to
the *progressive* path — there is nothing to audit. The MBAFF mismatch
predicate `fref[1][0]->field[mb_xy] != MB_INTERLACED` is false for every PAFF
MB (the picture is uniformly a field), so the field-colocated code never runs.
The work is fork-and-rework: introduce a `FIELD_PIC`-keyed field-colocated path
that re-derives colocated selection, MV scaling, and neighbour predictors for a
uniformly-field picture, verified against §8.4.1.2.4/§8.4.1.3 — not by MBAFF
analogy. The MBAFF code is the *reference shape*, not a reusable path.
(grill round 1; recorded as ADR-0003)

### D3: Lowres/mbtree mapping

mbtree costs are computed on frame lowres; both fields consume the frame-level
decision. `macroblock_tree_propagate` (`slicetype.c`) uses frame-level
`average_duration`, so under PAFF (a "frame" is a field pair) per-field
propagation weights are systematically ~2× off. Correctness (decoder
bit-exactness — see D10) does not depend on it, but quality may. **Gate:** checkpoint 4.2 is pass/fail —
B-field PAFF PSNR/SSIM must fall within a fixed bound of MBAFF on the
interlaced test set (threshold recorded from the first measurement); only if it
fails is per-field lowres work pulled into scope. (grill round 1)

### D4: Per-field PicNum MMCO (carried from paff-field-references D4/D10/D18)

Hierarchical B-field GOPs emit MMCO: BREF removal via `i_difference_of_pic_nums`
and DPB trim via `i_mmco_remove_from_end`. For field pictures §8.2.4.1 mandates
field PicNum arithmetic (`PicNum = 2·FrameNumWrap + parity`), but the current
paths are frame-level — `reference_hierarchy_reset` derives `difference_of_pic_nums`
from `i_frame_num`, the opcode-1 emit writes frame-level `i_poc`, and
`reference_update` matches by `i_poc`. A BREF field picture that fails this gets
no DPB match in JM → overflow or wrong reference → not bit-exact. This is the
sibling state model (`b_field_kept_as_ref[2]`) plus the computation:

(a) `i_difference_of_pic_nums` and `i_mmco_remove_from_end` computed in field
    PicNum units (§8.2.4.1);
(b) MMCO opcode *count* and emit site: `reference_hierarchy_reset` runs once
    per pair and writes one frame-level opcode per removed BREF; under field
    PicNum semantics (§8.2.5.4.1) removing a BREF *pair* needs TWO opcodes,
    one per parity. Emit both field-PicNum opcodes in field 1's slice header
    (§8.2.5.4 allows multiple opcodes per header), then zero
    `i_mmco_command_count` before field 2's `slice_header_init` so it is not
    duplicated. The marking *process* runs per coded field (§8.2.5.1); this
    keeps it conformant without a per-pass call into `reference_hierarchy_reset`.
(c) `reference_update` matches the marked reference by `(frame, parity)`, not
    by frame-level `i_poc`.

This gates checkpoint 4.1; task 2.1 is promoted ahead of the direct-mode work.
(grill round 1)

### D5: PAFF pair is encoded synchronously — no frame-thread pool for the pair

The PAFF branch calls `slices_write` directly per pass (both field passes run
inline in `encoder_encode`), bypassing the frame-thread pool the non-PAFF path
uses when `i_thread_frames > 1`. Both passes mutate shared `h->fdec` state
(`ref_poc`, `i_ref`, mb cache, reference sync), which is safe *only* because
the pair is serialized. Invariant: a PAFF complementary pair is always encoded
synchronously; the frame-thread pool is never used for the pair. Sliced
threading under PAFF is not validated — disable or assert it until a test
exists. (grill round 2)

### D6: B-pyramid needs no extra per-field `i_delta_poc` (resolves Open Q 1)

Resolved as a fact by reading code + §8.2.1: `i_delta_poc[parity]` is a fixed
{0,1}/{1,0} intra-pair field offset (`encoder.c:2733-2734`, TFF→{0,1},
BFF→{1,0}) — a field picture carries one POC per field, and §8.2.1 makes a
complementary pair's bottom-field POC = top-field + 1. The offset does NOT
depend on slice type or pyramid level. B-pyramid levels are already baked into
`base_poc` (`fdec->i_poc`), assigned frame-level by `slicetype.c` before the
PAFF driver runs (D1 frame-granular); the driver just adds the delta
(`sh.i_poc = base_poc + i_delta_poc[parity]`, `encoder.c:4164`), correct for
I/P/B alike. Field pictures never signal `delta_poc_bottom` (§7.4.3 gates it on
`!b_field_pic`) — the per-field POC is written to `sh.i_poc` directly. No
additional per-field adjustment is needed. (grill round 3)

### D7: Per-field `ref_poc`/`i_ref` storage — add a parity dimension

A B field's temporal direct reads the *stored* colocated picture's
`ref_poc[0]` (`macroblock.c:460`, `h->fref[1][0]->ref_poc[0][i]`). Under PAFF
the stored picture is a field pair whose single `ref_poc[0]` reflects only one
parity's expansion; a later B field colocating to the *other* parity reads the
wrong POCs and `map_col_to_list0` silently zeros out — so both parities must
coexist on the frame. Decision: add a parity dimension to the existing arrays
in `common/frame.h` — `int i_ref[2][2]` and `int ref_poc[2][2][X264_REF_MAX]`
(`[list][parity][ref]`) — not a parallel parity-keyed array. Three reasons:
(1) precedent — `inv_ref_poc[2]` already took a parity slot in
`paff-field-references` (`macroblock.c:502`), and `ref_poc` should match its
shape; (2) adding the dim turns a forgotten per-parity update from a silent
bug into a compile error at every read site (there are few:
`macroblock.c:460`, `mvpred.c:592`); (3) the frame-level slot is genuinely
insufficient, so keeping a parallel "frame-level" copy invites divergence.
Recorded as ADR-0004. (grill round 4)

### D8: Rate-control soundness boundary is a hard error, not a warning

The Non-Goals soundness boundary is enforced as a **hard error**, not
warn-and-disable: rate control runs once per pair with a merged bit-count, so
under ABR/CBR/VBV/2-pass the HRD sees one double-sized picture per pair
(§C.3.1) and the stream is silently non-conformant. A warning lets the user
ignore it and ship an invalid stream; this is a *conformance* defect, not a
quality one, matching how x264 already fails on other invalid param
combinations. Trivially relaxed when `paff-sei-hrd-rc` lands. (grill round 4)

### D9: PAFF-B L1 is clamped at 4 field entries (bipred-table cap)

`dist_scale_factor_buf[2][2][X264_REF_MAX*2][4]` /
`bipred_weight_buf[2][2][X264_REF_MAX*2][4]` cap the L1 index at 4
(`common.h:688,690`); a field-doubled L1 ≥ 6 entries overflows. Decision:
**clamp PAFF-B L1 at 4 field entries with an `x264_log` notice**, not widen
the dim. Rationale: correctness-first (the series priority); L1 ≥ 2 frame
references is uncommon for hierarchical B (L1 is usually the single future
ref), and the clamp is signalled via `num_ref_idx_l1_active` so it stays
conformant — just fewer refs. Widening would grow a per-thread `x264_t` table
sized for the worst case and require auditing every `[…][i_ref1]` consumer;
the clamp is trivially reversible if checkpoint 4.2 (D3) shows it bites.
(grill round 4)

### D10: Verification oracle is ffmpeg, not JM 19.0 (PAFF field pictures)

The conformance criterion is byte-exact round-trip (decoder output ==
`--dump-yuv`). JM `ldecod` is the canonical ITU reference for frame/MBAFF
streams, but **JM 19.0 cannot verify PAFF field pictures**: it fails to
reconstruct the bottom field of a PAFF field pair (emits gray/128) even on
streams a second conformant decoder decodes byte-exactly — confirmed by
decoding the same PAFF I/P stream with both JM (gray bottom fields, aborts) and
ffmpeg (byte-exact vs `--dump-yuv`). This is a JM bug, not an encoder defect.
The PAFF verification oracle is therefore **ffmpeg** (`ffmpeg -i <stream>
-pix_fmt yuv420p`), a conformant, independent decoder. The checkpoint's
"JM bit-exact" criterion is satisfied in substance by ffmpeg byte-exactness.
Recorded so the criterion stays honest: do not gate PAFF conformance on a JM
version known broken for field pictures. (Discovered during the 4.1 checkpoint;
see `CONTEXT.md` and `checkpoint-4.1-4.3.md` SUPERSEDED banner.)

## Risks / Trade-offs

- [PAFF field chroma deblock (RESOLVED, task 2.5)] → the suspected
  chroma-deblock drift was root-caused to the PAFF P-field reference
  list instead: (a) §8.2.4.2.2 orders a P field's refFrameList0ShortTerm
  by FrameNumWrap descending over the full DPB (the POC-sorted, capped
  pair list diverges once a BREF is in the DPB); (b) strict-pyramid BREF
  eviction in `reference_hierarchy_reset` ran ahead of its own MMCO
  marking point.  Both fixed; `deblock.c` untouched.  See tasks 2.5/4.1.
- [Direct-mode corner cases (colocated parity, scaling)] → targeted JM
  comparisons for B fields with direct/spatial/temporal before enabling the
  gate.
- [MBAFF code unreachable under PAFF (D2)] → the direct/MV-pred paths are
  fork-and-reworked for uniformly-field pictures, not audited in place; verify
  the new `FIELD_PIC`-keyed path against §8.4.1.2.4/§8.4.1.3, not by MBAFF
  analogy.
- [Colocated `ref_poc[0]` frozen pair-level] → a field picture's stored
  `ref_poc[0]` must be recomputed after the per-pass expansion and stored per
  field on the frame, or later B fields' `map_col_to_list0` read pair-level POCs
  and temporal direct silently zeros out. Resolved by D7 (parity dim, ADR-0004).
- [`(j>>1, j&1)` MBAFF consumers] → `dist_scale_factor_buf` and
  `map_col_to_list0` decompose post-expansion field-entry indices as
  (frame, parity); enumerate every such consumer and route through
  `i_fref_parity`/`i_fref_frame` as MC already does (D16).
- [Single-field colocated reference] → the IDR second-field survivor
  (field-references D6) contributes one field only; carry its available-parity
  mask onto the frame so colocated selection skips the absent field per
  §8.4.1.2.4.
- [B-bipred chroma subpel offset] → the bipred sites (`macroblock.c:139-141`,
  `me.c:1050-1051`) key the chroma vertical offset on raw `i_ref0/i_ref1`
  (truthy) and `(i_mb_y&1)`; under PAFF route through `i_fref_parity[i_ref]`
  like the single-ref sites, and add a chroma JM comparison to the gate.
- [Stale pair-level `i_poc_l0ref0`] → the spatial-vs-temporal direct selection
  (`slice_header_init`, `fref[1][0]->i_poc_l0ref0 == fref[0][0]->i_poc`) reads a
  pair-level value (`encoder.c:4125`, ponytail "revisited in paff-b-frames");
  recompute per field pass and store per-parity, or the wrong
  `direct_spatial_mv_pred` flag is written.
- [Colocated→L0 parity match] → `map_col_to_list0`'s match compares
  frame-level `fref[0][j]->i_poc` against the stored per-field `poc`; compare
  against `i_poc + i_delta_poc[i_fref_parity[j]]` or odd-parity colocated
  fields never match.
- [Colocated-list signaling] → temporal direct assumes `fref[1][0]` is the
  colocated picture, but no `col_from_l0_flag`/`col_ref_idx` is emitted;
  confirm the §7.4.3.1 inferred default resolves to L1[0] for *field* pictures
  (§8.4.1.2.4 parity-dependent, unlike frame §8.4.1.2.3), or emit the signal.
- [Bipred tables never built under PAFF] → `x264_macroblock_bipred_init` runs
  in the non-PAFF path; the PAFF driver returns before it, so
  `dist_scale_factor_buf[1][parity]`/`bipred_weight_buf[1][parity]` are read
  uninitialised for B fields.
- [L1 bipred-table cap] → `dist_scale_factor_buf[…][4]`/`bipred_weight_buf[…][4]`
  cap the L1 index at 4; a field-doubled L1 ≥ 6 entries overflows. PAFF-B L1 is
  clamped at 4 field entries with a log (D9).
- [Quality regression vs MBAFF on interlaced content] → measure PSNR/SSIM at
  the gate (pass/fail per D3, threshold from first measurement); correctness
  first.

## Open Questions

1. _(resolved → D6)_ Do hierarchical B pyramids interact with field-pair POC
   assignment in a way that needs per-field `i_delta_poc` adjustment beyond
   what `paff-field-references` established? — No: `i_delta_poc` is a fixed
   intra-pair offset; B-pyramid levels live in `base_poc`. See D6.

_(none open)_
