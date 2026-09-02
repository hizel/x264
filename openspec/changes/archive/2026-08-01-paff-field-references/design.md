# Design: PAFF — full per-field reference management

## Context

After `paff-core-ip`, a PAFF sequence codes two field pictures per frame, but a
P field can only reference the previous same-parity field. The H.264 reference
model for field pictures (§8.2.4.2, §8.2.5) is richer: the DPB stores pictures
(a complementary field pair is one DPB slot), lists are built from frames and
expanded into field entries, and the marking process runs after each coded
field (§8.2.5.1) in slot units (§8.2.5.3).

x264's `h->frames.reference[]` stores frames. The MBAFF machinery already uses
the expanded-list convention in MC: reference index `j` encodes frame `j>>1`
and parity `j&1` (`common/macroblock.c:617-647`) — exactly the §8.2.4.2.5 model.

## Goals / Non-Goals

**Goals:**
- Spec-conformant field reference lists (§8.2.4.2.2, §8.2.4.2.5) for P fields.
- Sliding-window marking that runs after each coded field (§8.2.5.1) in
  DPB-slot units (§8.2.5.3). (Per-field single-field marking and field-pic
  MMCO are deferred to `paff-b-frames` — see Non-Goals.)
- Complementary first field referenceable by the second field of the pair.
- JM bit-exact with up to 16 reference fields, mixed parities.

**Non-Goals:**
- B field pictures and L1 lists → `paff-b-frames`.
- Per-field (single-field) marking state and MMCO for field pictures →
  `paff-b-frames`. PAFF I/P emits only the sliding-window (default) marking
  mode — `i_mmco_remove_from_end` is B-pyramid/open-gop only — so a pair is
  uniformly "kept as ref" or not and the existing frame-level `b_kept_as_ref`
  suffices (DEC-B, grill round 4; verified against JM
  `lencod`/`ldecod` `store_picture_in_dpb` and QSV `DpbFrame` slots).
- HRD/DPB *timing* (cpb/dpb delays) → `paff-sei-hrd-rc`.
- Weighted prediction under PAFF stays disabled: the `paff-core-ip` hard
  error is *not* lifted (task 3.3 lifts only the mixed-parity/multi-ref
  clamps). Enabling it later needs per-field `weighted[]` slots — the
  `j >> mb_interlaced` collapse in `common/macroblock.c` maps both fields of
  a frame to one weighting slot (MBAFF assumption). (grill round 1)

## Decisions

### D1: Frames stored, lists expanded with parity

`h->frames.reference[]` keeps storing frames; each reference frame is one DPB
slot (a complementary pair), kept or not as a whole via the existing
frame-level `b_kept_as_ref` (per-field marking is deferred — D4). List
construction builds
the frame list as today (`reference_build_list`), then expands each frame into
two field entries using the existing `j>>1`/`j&1` convention, ordered by
alternating parity starting with the current field's parity (§8.2.4.2.5).

*Alternative — store fields as separate DPB entries:* rejected; it would fork
frame lifetime management (allocation, lowres, threading) for no gain — the
spec's frame-based short-term marking maps cleanly onto per-parity flags.

### D2: Complementary field as short-term reference

The already-coded first field of the current pair is inserted into RefPicList0
of the second field pass per §8.2.4.2.2 step 1 (same `frame_num`, opposite
parity). It leaves the DPB scope together with its pair — no special lifetime.

### D3: POC bookkeeping per field

Per-field `TopFieldOrderCnt`/`BottomFieldOrderCnt`; `i_delta_poc[2]` already
exists per frame. `ref_poc` tables (used by reordering and direct-mode scaling
later) are extended to field entries. `frame_num` continues to increment once
per pair.

### D4: Per-field marking state on `x264_frame_t` — DEFERRED to `paff-b-frames`

**Deferred (DEC-B, grill round 4).** PAFF I/P uses only the sliding-window
marking mode, which marks an entire complementary pair at once (D5/D20), so a
pair is uniformly "kept as ref" or not and the existing frame-level
`b_kept_as_ref` is sufficient for this change. The per-parity state below is
the model `paff-b-frames` will need when MMCO opcode 1 (field_pic_flag=1) is
actually emitted.

One byte flag per parity on each stored frame: `b_field_kept_as_ref[2]`
(`[0]`=top, `[1]`=bottom). Long-term marking is deliberately omitted (D19).
A frame stays in
`h->frames.reference[]` while either field is kept; list building skips a
*field* entry whose parity is unmarked, and skips a *frame* only when both
fields are unmarked (or `b_corrupt`). Minimal change to frame lifetime
management; mirrors the spec's per-field marking (§8.2.5) on frame storage
(D1). (grill round 1)

### D5: Slot-unit sliding window; pair = one DPB slot

A complementary field pair is one DPB slot, stored as one `x264_frame_t`
exactly as today. Verified in JM `ldecod` `store_picture_in_dpb` /
`sliding_window_memory_management`: the check is
`ref_frames_in_buffer == num_ref_frames` and `unmark_for_reference(fs)` clears
*both* fields of the whole `FrameStore`; QSV stores the same way (`DpbFrame`
slots, ref index = `frame | (parity<<7)`). So §8.2.5.3 counts **slots**
(frames / complementary pairs / non-paired fields) against `max_num_ref_frames`,
not individual fields, and eviction marks an entire pair unused. The existing
slot accounting in `reference_update` (`encoder.c:2611`,
`if( h->frames.reference[i_num_ref_frames] ) x264_frame_shift(...)`) is already
correct and needs **no field-unit rework**. (The earlier "field-unit" wording
was wrong; single-field removal is an MMCO-only operation, deferred — D4.)
(grill round 1; corrected to slot-unit in grill round 4 after checking spec +
JM + QSV)

### D20: Marking runs per field — between-pass eviction in the PAFF driver

The decoded-reference-picture marking process runs after each coded picture
(§8.2.5.1), i.e. after each field, not once per pair. The decoder stores the
first field of pair N — which may trigger sliding-window eviction to make
room — and then *merges* the second field into the same slot with no further
eviction (JM `store_picture_in_dpb` early-returns on the complementary
field). The encoder must mirror this: after pass 1 of pair N and before pass
2 builds its list (D13), run the sliding-window check once — if
`h->frames.reference[]` is at the `i_num_ref_frames` slot cap, evict the oldest
pair. Without this, the second field's list references a pair the decoder
already dropped after the first field (e.g. `--ref 2`: after P2's first field
the decoder evicts P0, so P2's second field references {P1, P2f1}, not
{P0, P1, P2f1}) → JM mismatch, fails checkpoint 4.2. (grill round 4)

### D6: Expanded list capped at `X264_REF_MAX`

RefPicList0 field entries (the complementary first field + two entries per
stored reference pair, parity-alternated) are truncated to `X264_REF_MAX`
(16) at list-build time, combined with the `2 * i_frame_reference` cap of
D14. Per-field marking is deferred (D4), so every reference pair contributes
*both* fields — there is no per-MMCO single-marked-field case to special-case.
There IS one non-MMCO single-field case: an IDR complementary pair clears the
DPB when its SECOND field is decoded (§8.2.1), so only that second field
remains marked "used for reference"; a subsequent P pair can therefore
reference only the IDR pair's second field. The expansion mirrors §8.2.4.2.5's
missing-field rule for it (contributes only parity `b_tff?1:0`). This is
§8.2.1 (IDR clearing), not per-field MMCO marking (D4), so it stays in this
change. The existing `i_ref[0] + i_ref[1] <= X264_REF_MAX` assert stays as the
safety net. `ref_poc` arrays need no resize for this change. (grill round 1;
clamp policy corrected in grill round 3; single-field case dropped in round 4;
IDR §8.2.1 exception added in implementation review)

### D7: List construction ordered by per-field POC

L0 membership and ordering use per-field POCs (`i_poc + i_delta_poc[parity]`),
not the frame-level even POC: build the frame list, expand to field entries —
applying the membership filter per entry during expansion (a field entry
whose per-field POC is >= the current field's POC is excluded) — then order
short-term fields per §8.2.4.2.2. Frame-level `i_poc` comparison
(`encoder.c:2360`) misclassifies the opposite-parity field whose POC
interleaves with the current pair's fields. (grill round 1; filter placement
clarified in grill round 3)

### D8: `ref_poc` stores per-field POCs

After expansion, `h->fdec->ref_poc[0][j]` holds the POC of field entry `j`
(per D7), not the even frame POC; `inv_ref_poc` and temporal MV scaling use
these values. Keeps MV scaling correct for mixed-parity lists and prepares
B-field direct modes (`paff-b-frames`). (grill round 1)

### D9: Optimal reordering stays frame-level (once per pair)

`x264_reference_build_list_optimal` runs **once per pair, on the frame-level
`h->fref[0]`** (as today, `encoder.c:3981`), before the per-pass field
expansion — so it reorders reference *pairs* normally and needs no special
`2k`/`2k+1` swapping: the field expansion (D7/D13) preserves pair order, and
parity alternation is produced during expansion. The complementary-first-field
entry is inserted during pass-2 expansion (after reorder), so reorder never
touches it. (grill round 1; simplified to frame-level in grill round 4, DEC-D)

### D10: MMCO in field PicNum units — DEFERRED to `paff-b-frames`

**Deferred (DEC-B, grill round 4):** PAFF I/P emits no MMCO
(`i_mmco_remove_from_end` is B-pyramid/open-gop only), so field-PicNum
arithmetic is not exercised here. Kept for `paff-b-frames`, where MMCO opcode
1 with field_pic_flag=1 is actually emitted.

For field pictures, `difference_of_pic_nums` is computed with per-field
PicNums (§8.2.4.1: PicNum = 2·FrameNum + parity term), not `i_frame_num`
differences, and MMCO marking targets individual fields (§8.2.5.4.1).
Frame-level arithmetic yields wrong eviction commands. (grill round 1)

### D11: Reference frames carry per-field `i_delta_poc`; `fdec->i_poc` stays frame-level

Under PAFF, `slice_init` currently sets `fdec->i_delta_poc = {0,0}` (the
`PARAM_INTERLACED` branch is MBAFF-only, `encoder.c:2715-2723`) and the PAFF
driver mutates `fdec->i_poc` per pass (`encoder.c:4001`) — so the
`i_poc + i_delta_poc[parity]` formula (D7/D8) has no valid inputs. Fix:
stored frames get `i_delta_poc = {0,1}` (TFF) or `{1,0}` (BFF); the driver
sets the per-field POC only for slice-header creation (`sh.i_poc`), and
`fdec->i_poc` is restored to the even frame POC before macroblock init, so
`curpoc = i_poc + i_delta_poc[field]` (`macroblock.c:482`) evaluates
correctly per pass. Explicit contract (avoids a fragile restore step):
(1) `h->fdec->i_poc = base_poc` for the whole pair — never mutated;
(2) after `slice_init`, the PAFF driver overwrites `h->sh.i_poc` with the
per-field POC directly; (3) `reference_build_list` receives the per-field POC
via its existing `i_poc` parameter (D13). Prerequisite repair of the
`paff-core-ip` baseline, not a new model. (grill round 2; contract pinned in
grill round 3)

### D12: `inv_ref_poc` computed per field pass

`inv_ref_poc[parity]` is computed during that parity's pass from the pass's
own `fref[0][0]` (for the second pass: the complementary first field, one
field-POC-unit away). TMVP/direct-mode consumers are B-only
(`mvpred.c:585`), so correctness is validated in `paff-b-frames`; this change
only keeps the stored values self-consistent per field. Same deferral for
`fdec->i_poc_l0ref0` (`encoder.c:3986`), consumed only by the B direct-mode
check (`encoder.c:159`) — marked with a `ponytail:` comment. (grill round 2)

### D13: Field expansion per pass; build_list + optimal reorder once per pair

`reference_build_list` (`encoder.c:3699`) and `x264_reference_build_list_optimal`
(`encoder.c:3981`) run **once per pair, frame-level**, exactly as today — the
PAFF I/P membership filter (D7) excludes nothing because every reference pair
is strictly in the past. The **per-pass** work is the field *expansion* of the
already-built, already-reordered frame-level `fref[0]`: emit field entries
alternating parity starting with the current field's parity (D7), populate
`i_fref_frame[]` (D16), and insert the complementary first field only in pass 2
(§8.2.4.2.2, D2). Weighted-pred duplication is off under PAFF, so the per-pass
expansion has no weightp interactions. (grill round 2; corrected in grill round
4, DEC-D: build_list/optimal_reorder do NOT move per pass — only the expansion
does)

### D14: `--ref` keeps frame-pair semantics; caps applied in field units

User-facing `--ref N` means N reference frame pairs. The caps in
`reference_build_list` (`encoder.c:2416-2417`,
`X264_MIN( i_ref[0], i_frame_reference )`) are applied as
`2 * i_frame_reference` under PAFF (field units), analogously to the
`i_num_ref_frames *= 2` SPS accounting in `paff-core-ip`; combined with the
D6 ceiling of `X264_REF_MAX` field entries. (grill round 2)

### D15: First field's pixels made referenceable between passes

Before the second pass, the first field's reconstructed rows are synced from
`plane[]` to `plane_fld[]` and its borders + hpel (`filtered_fld`) are
generated for that parity — the work `paff_frame_finish` currently does only
after both passes (`encoder.c:2832`). MC reads `plane_fld`/`filtered_fld` via
`macroblock.c:617-637`, so without this the complementary-field reference
(D2) would read stale planes. (grill round 2)

### D16: Field-entry → frame mapping replaces the bare `j>>1` convention

On pass 2 the complementary first field is a **single-field slot among full
pairs** (§8.2.4.2.2: it enters `refFrameList0ShortTerm` at the highest
`FrameNumWrap`; §8.2.4.2.5 then places it mid-list), so expanded-list index
`j` no longer satisfies "frame = `j>>1`". (Pass 1 has no complementary field,
so `j>>1` would hold there — but the mapping is applied uniformly.) Expansion
builds a parallel `i_fref_frame[]` (field-entry index → frame index) plus a
per-entry parity, used by MC plane selection (`macroblock.c:618`) and
`deblock_ref_table` (`macroblock.c:471`) instead of `j>>1`, and as the
**replacement for the single global `b_field_ref_opposite` flag**, which
cannot scale to multi-ref mixed parity (DEC-C). Parity is recorded per entry
at expansion; list order must mirror the decoder's exactly (no placeholder
padding, which would shift `ref_idx` coding). (grill round 3; reason corrected
from 'per-field marking' to 'complementary field' in grill round 4, DEC-C)

### D17: Ratecontrol ref statistics — only the stat-doubling gate

Because optimal reordering stays frame-level (D9/DEC-D), `rce->refs`/`refcount`
and the `x264_reference_build_list_optimal` equality check
(`ratecontrol.c:592`) stay **frame/pair-level** — no field-unit change. The
only ratecontrol change needed: the 2-pass stats doubling at
`ratecontrol.c:1877` (`i_mb_count_ref[0][i*2]`) is gated on field-coded
pictures (PAFF included), not `PARAM_INTERLACED` alone — otherwise pass-1
refcounts are collected wrong (single index instead of `i*2`/`i*2+1` summed
per pair) and optimal reordering misbehaves in pass 2. (grill round 3; narrowed
in grill round 4, DEC-D)

### D18: MMCO commands carry per-field POC identity — DEFERRED to `paff-b-frames`

**Deferred (DEC-B, grill round 4)** together with D10/D4: PAFF I/P emits no
MMCO, so the frame-level `i_poc` MMCO matching at `encoder.c:2607` is unused
under PAFF I/P and needs no change here.

`sh.mmco[].i_poc` stores the per-field POC (`i_poc + i_delta_poc[parity]`) of
the target field, and `reference_update`'s MMCO apply loop matches per frame
× parity, un-marking only that field (D4). Frame-level `i_poc` matching
(`encoder.c:2607`) cannot address one field of a pair. Complements D10
(PicNum arithmetic in the bitstream) with the encoder-side bookkeeping.
(grill round 3)

### D19: No long-term field marking (resolves Open Question 1)

Per-field long-term marking is NOT implemented. This matches the x264
baseline, which never emits long-term marking at all — its only MMCO use is
opcode 1 (mark short-term "unused") for DPB trimming
(`i_mmco_remove_from_end`); the codebase itself notes long-term refs as a
never-taken path (`macroblock.c:1903`). Since PAFF I/P emits no MMCO at all
(DEC-B, D10/D18 deferred), there is no field-level marking to worry about in
this change. If a real consumer ever needs long-term fields, this is
revisited in a follow-up change. (user decision after grill round 3; scope
narrowed in grill round 4)

## Risks / Trade-offs

- [Marking bugs are silent until reference drift] → gate on JM round-trip with
  multi-ref P fields under an active sliding window (forces eviction); D20's
  between-pass eviction is the specific hazard to exercise (checkpoint 4.2).
- [Spec DPB accounting is slot-unit, not field-unit] → resolved by D5's
  slot-unit model (a pair is one slot = one `x264_frame_t`, as today); the
  earlier field-unit draft would have diverged from JM. Assert that
  `h->frames.reference[]` length matches the decoder's slot count after each
  pass.

## Open Questions

None. (Former Q1 — per-field long-term marking — resolved by D19: not
implemented, matching the x264 baseline. Per-field marking state and field-pic
MMCO — D4, D10, D18 — deferred to `paff-b-frames` by DEC-B, grill round 4,
since PAFF I/P emits only sliding-window marking.)
