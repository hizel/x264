# Tasks: PAFF — full per-field reference management

Dependency-ordered; ends with a JM round-trip checkpoint. See `design.md` for
decisions D1–D20; D4/D10/D18 and task 3.2 are deferred to `paff-b-frames`
(DEC-B, grill round 4).

## 1. Per-field marking state

- [x] 1.1 Set `i_delta_poc = {0,1}`/`{1,0}` per TFF/BFF under PAFF and keep
      `fdec->i_poc` frame-level outside slice-header creation (D11).
      (Per-field marking state `b_field_kept_as_ref[2]` — D4 — is deferred to
      `paff-b-frames`; this change uses the existing frame-level
      `b_kept_as_ref`, since a PAFF I/P pair is uniformly ref or not.)
- [x] 1.2 DPB size accounting in **slot units** (one complementary pair = one
      DPB slot = one `x264_frame_t`, as today — D5; *not* field units);
      `max_num_ref_frames` handling; expanded RefPicList0 capped at
      `X264_REF_MAX` field entries (D6)
      *(The D20 between-pass eviction (task 3.1) landed, so the temporary
      `+1` in `set.c` collapsed to exactly `i_frame_reference` slots. The D6
      `X264_REF_MAX` cap is applied at expansion in task 2.1.)*

## 2. Reference list construction

- [x] 2.1 Field expansion per §8.2.4.2.5, run **once per pass** over the
      pair-level list that `reference_build_list` +
      `x264_reference_build_list_optimal` build **once per pair** (D13/DEC-D):
      frame list → parity-alternated field entries starting with the current
      field's parity; membership and ordering by per-field POC (D7);
      `i_fref_frame[]` mapping (D16); `--ref` caps applied in field units
      (D14)
- [x] 2.2 Complementary first field available to the second field pass
      (§8.2.4.2.2 step 1): sync its rows to `plane_fld` and generate
      borders/hpel for its parity between passes (D15)
- [x] 2.4 Field-entry → frame mapping (`i_fref_frame[]` + per-entry parity,
      D16) replacing the bare `j>>1` in MC plane selection
      (`macroblock.c:618`) and `deblock_ref_table` (`macroblock.c:471`), **and
      replacing the global `b_field_ref_opposite` flag** (`macroblock.c:55`/`:628`,
      `encoder/me.c:875`/`:1241`): remove `b_field_ref_opposite` and the
      hand-coded single-ref `ref_pic_list_order` trick from the PAFF driver;
      derive the MC chroma v-offset from per-entry parity instead; signal
      `ref_pic_list_modification` from the expanded list (DEC-C).
      `ponytail:` comment on `fdec->i_poc_l0ref0` staleness across passes
      (B-only consumer, `paff-b-frames`)
- [x] 2.3 `ref_poc` tables extended to field entries (per-field POC values,
      D8); `inv_ref_poc` computed per field pass (D12). Optimal reordering
      (`x264_reference_build_list_optimal`) needs **no** change — it stays
      frame-level / once-per-pair (D9/DEC-D); only the `i_mb_count_ref`
      doubling gate moves to field-coded pictures (D17/DEC-D)

## 3. Marking

- [x] 3.1 Sliding-window marking in **slot units** (§8.2.5.3): eviction marks
      a whole complementary pair unused; add the between-pass eviction in the
      PAFF driver so the second field's list matches the decoder's DPB after
      the first field is stored (D5/D20)
- [x] 3.2 *(Deferred to `paff-b-frames`)* MMCO support for field pictures
      (per-field marking commands, field-PicNum arithmetic per D10, per-field
      POC identity per D18) — PAFF I/P emits only sliding-window marking, so
      nothing here is exercised by this change's tests. **No-op for this
      change (DEC-B):** `i_mmco_remove_from_end` is B-pyramid/open-gop only,
      so PAFF I/P signals no MMCO and the frame-level `b_kept_as_ref` suffices.
- [x] 3.3 Lift the `paff-core-ip` validation clamps: mixed-parity and
      multi-frame references now allowed under PAFF (the weighted-prediction
      rejection stays — see design Non-Goals)
- [x] 3.4 Comment the `j >> mb_interlaced` weighting collapse in
      `common/macroblock.c` as MBAFF-only (PAFF weightp remains disabled)

## 4. Checkpoint

- [x] 4.1 JM round-trip bit-exact with multi-ref P fields (up to 16 refs),
      mixed parities
- [x] 4.2 JM round-trip bit-exact under an active sliding window (forced
      eviction, exercises D20's between-pass eviction), TFF and BFF
- [x] 4.3 checkasm green; non-PAFF outputs bit-identical
