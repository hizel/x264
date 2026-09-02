# Tasks: PAFF — B field pictures and field MV prediction

Dependency-ordered; ends with a byte-exact round-trip checkpoint (oracle:
ffmpeg — see `design.md` D10). See `design.md` for
decisions D1–D9.

## 1. B field pictures

- [x] 1.1a L0 field expansion — exists (`paff_expand_field_list`); re-verify it
      still feeds L0 for B slices.
- [x] 1.1b L1 field expansion — **net-new** (§8.2.4.2.5 is a two-step build:
      opposite-parity-first then future-POC ordering, not a symmetry of L0).
      Write the L1 builder, a per-entry parity map (`i_fref_parity_l1[]` /
      `i_fref_frame_l1[]`), and `ref_poc[1]` with the per-field `i_delta_poc`
      term — today `ref_poc[1][i] = fref[1][i]->i_poc` has no delta. Mirror the
      L0 active-count re-size (`encoder.c:2985`): set
      `sh.i_num_ref_idx_l1_active = out_l1` and recompute
      `b_num_ref_idx_override`, or `num_ref_idx_l1_active_minus1` is the pair
      count while the list holds 2× entries → illegal ref_idx. Also verify/
      assert the emitted L1 order equals §8.2.4.2.5's default field order (so
      `b_ref_pic_list_reordering[1]=0` stays valid), else signal L1 reordering.
- [x] 1.1c Store the field-expanded `ref_poc[0]` (and `i_ref[0]`) **per field
      pass** on the frame, computed *after* the per-pass expansion. Today the
      loop runs before it (pair-level, `macroblock.c` ponytail "PAFF emits no
      B"). Storage layout — **decided D7 / ADR-0004**: add a parity dimension
      to the existing arrays in `common/frame.h` (`int i_ref[2][2]`,
      `int ref_poc[2][2][X264_REF_MAX]`, i.e. `[list][parity][ref]`), matching
      the parity slot `inv_ref_poc` already took in `paff-field-references`
      (`macroblock.c:502`). Both parities coexist so a later B field colocating
      to either parity selects via `i_fref_parity_l1[0]`; without per-field
      storage its `map_col_to_list0` reads pair-level POCs and temporal direct
      silently zeros out.
- [x] 1.1d Recompute `i_poc_l0ref0` per field pass from the field-expanded
      `L0[0]` and store per-parity (same layout as 1.1c). The spatial-vs-
      temporal direct selection (`slice_header_init`,
      `fref[1][0]->i_poc_l0ref0 == fref[0][0]->i_poc`) reads a pair-level value
      today (`encoder.c:4125`, ponytail "revisited in paff-b-frames"); without
      this it writes the wrong `direct_spatial_mv_pred` flag into both field
      slice headers.
- [x] 1.2 B field mode decision in `encoder/analyse.c` on the field-pair passes

## 2. Reference marking and direct modes

- [x] 2.1 Per-field reference marking + MMCO (deferred from `paff-field-references`
      task 3.2 / decisions D4, D10, D18; see **D4**): add `b_field_kept_as_ref[2]`
      per stored frame; MMCO opcode 1 with `field_pic_flag=1` using per-field
      PicNum arithmetic (§8.2.4.1: `PicNum = 2*FrameNumWrap + (same_parity?1:0)`)
      in `reference_hierarchy_reset` and `i_mmco_remove_from_end`. **Opcode
      count:** removing a BREF *pair* needs TWO opcodes, one per parity — emit
      both in field 1's slice header, then zero `i_mmco_command_count` before
      field 2's `slice_header_init` (today it runs pair-level and is duplicated
      into both headers). Match the marked reference in `reference_update` by
      `(frame, parity)`, not by frame-level `i_poc`.
      **Promoted ahead of 2.2/2.3 — gates checkpoint 4.1.**
- [x] 2.2 Temporal direct mode for fields (§8.4.1.2.4) — **fork-and-rework, not
      audit (D2):** the MBAFF interlaced branches (`mvpred.c:195`, `:343`,
      `:461`) are unreachable under PAFF (`PARAM_INTERLACED` mutex,
      `SLICE_MBAFF=0`) and fall through to the progressive path. Add a
      `FIELD_PIC`-keyed field-colocated path: colocated field selection with the
      available-parity mask (2.2a), MV scaling distances in field POC units, and
      colocated addressing `col_row = (col_parity == cur_parity) ? i_mb_y
      : i_mb_y ^ 1` (the MBAFF `mb_y=(i_mb_y&~1)+col_parity` assumes interleaved
      pair rows). Also fix the colocated→L0 match (`macroblock.c:463`):
      compare against `fref[0][j]->i_poc + i_delta_poc[i_fref_parity[j]]`, not
      bare frame-level `i_poc`, or odd-parity colocated fields never match.
- [x] 2.2a Carry the per-reference available-parity mask (the `ent_avail`
      bitmask already computed in `paff_expand_field_list`) onto the frame, so
      colocated selection skips an absent field (IDR second-field survivor,
      field-references D6; §8.4.1.2.4 single-field rule).
- [x] 2.2b Enumerate every consumer of the `(j>>1, j&1)` MBAFF decomposition
      (`dist_scale_factor_buf`, `map_col_to_list0`, and any `>>MB_INTERLACED` /
      `i_ref&1` site near `fref`/`ref_poc`/`dist_scale_factor`) and route through
      `i_fref_frame`/`i_fref_parity` as MC already does (D16).
- [x] 2.2c Route B-bipred chroma vertical subpel offsets through
      `i_fref_parity` under `FIELD_PIC` — `macroblock.c:139-141` and
      `me.c:1050-1051` key the offset on raw `i_ref0/i_ref1` (truthy) and
      `(i_mb_y&1)` (row-within-field, not parity). Mirror the single-ref sites
      (`macroblock.c:55`, `me.c:875`). Add a chroma JM comparison to the
      B-field gate.
- [x] 2.2d Build the bipred tables per PAFF pass: `x264_macroblock_bipred_init`
      runs in the non-PAFF path only (`encoder.c:4245`), so the PAFF driver
      returns before it and `dist_scale_factor_buf[1][parity]` /
      `bipred_weight_buf[1][parity]` are read uninitialised for B fields
      (`macroblock.c:1343-1344`). Call it per pass and fill the `[1][parity]`
      slots with field POCs (`i_poc + i_delta_poc[parity]`).
- [x] 2.2e Cap the field-doubled L1 to fit the bipred tables — **decided D9**:
      `dist_scale_factor_buf[…][4]` / `bipred_weight_buf[…][4]` cap the L1
      index at 4 (`common.h:688,690`); L1 ≥ 6 field entries overflows.
      **Clamp PAFF-B L1 at 4 field entries with an `x264_log` notice** (the
      list stays conformant via `num_ref_idx_l1_active`), rather than widening
      the dim and auditing every `[…][i_ref1]` consumer. Feed an `--ref`/L1
      ceiling into the BREF-eviction scenario.
- [x] 2.3 Spatial direct and field-aware MV prediction (§8.4.1.3) — same
      fork-and-rework shape: neighbours in a uniformly-field picture; the
      `b_interlaced` predicate (`fref[1][0]->field[mb_xy] != MB_INTERLACED`) is
      false for every PAFF MB. Carry-over from `paff-field-references`:
      `x264_mb_predict_mv_ref16x16` (`mvpred.c:585`) uses `i_ref & 1` as ref
      parity — under PAFF route through `i_fref_parity[i_ref]` and the constant
      picture field parity (latent today: non-spec ME candidate generator).
- [x] 2.4 Targeted JM comparisons for B fields with direct/spatial/temporal
      before the checkpoint
      **DONE via ffmpeg oracle:** B-field GOPs (TFF+BFF, `--b-pyramid
      none/normal`, `--direct temporal/spatial`, `--ref 1/2/3`) decode
      byte-exact vs `--dump-yuv`. JM 19.0 is an unreliable PAFF oracle (its
      own bottom-field bug), so the comparison used ffmpeg. Checklist in
      `jm-checklist.md`; findings in `checkpoint-4.1-4.3.md`.
- [x] 2.5 PAFF field chroma deblock — fix round-trip drift (opened after
      re-testing 4.1; see `checkpoint-4.1-4.3.md` "REGRESS" banner).
      **DONE — the deblock hypothesis was WRONG; `deblock.c` needed no
      changes.**  Root-caused (ffmpeg oracle, JM trace for headers): the
      drift was LUMA+chroma, present with `--no-deblock` too, triggered by
      any BREF in the DPB (`--b-pyramid strict/normal`; `--b-pyramid none`
      was clean).  Two conformance bugs in the PAFF P-field reference list:
      (a) the P-field L0 was expanded from the POC-distance-ordered,
      `i_frame_reference`-capped pair list, but §8.2.4.2.2 orders a P
      field's refFrameList0ShortTerm by FrameNumWrap DESCENDING over the
      FULL DPB — with a BREF in the DPB (higher frame_num, lower POC) the
      orders and the truncation window diverge, and no
      ref_pic_list_modification is signalled (DEC-C).  Fixed: the PAFF
      driver rebuilds the past list from `h->frames.reference` sorted by
      FrameNumWrap (8-27) for P pairs; the 2*i_frame_reference field cap
      now mirrors the decoder's truncation to num_ref_idx_l0_active.
      (b) `reference_hierarchy_reset` evicted the old BREF from
      `frames.reference` IMMEDIATELY (strict pyramid) while the MMCO
      opcodes ride in the current picture's field-1 slice header — the
      decoder applies them only AFTER building that field's list (8.2.4
      runs before 8.2.5), so the pair must stay visible for the current
      pass.  Fixed: under PAFF the shift is deferred to the inter-pass D20
      marking (which already applies the opcodes between the passes).
      Verified byte-exact vs `--dump-yuv` (ffmpeg) on 14/14 configs:
      TFF+BFF, ref 1-4, all direct modes, strict/normal pyramid, CAVLC,
      keyint 8/24, 120-frame streams (frame_num wrap), `--no-deblock`.
      Non-PAFF outputs bit-identical; checkasm8/10 green.

## 3. Lookahead and slice types

- [x] 3.1 Verify mbtree/lookahead frame-granular decisions (D1) map sanely to
      both fields; `macroblock_tree_propagate` uses frame-level
      `average_duration`, so propagation weights are ~2× off per field — pull
      per-field lowres work into scope only if checkpoint 4.2 fails its bound
      (D3).
- [x] 3.2 Lift the `paff-core-ip` B-frames validation clamp (`encoder.c`
      PAFF block); at the same time hard-disable `b_weighted_bipred`
      (`--weightb`) for PAFF — the block clamps B-frames and P-weightp but not
      weighted-bipred, which routes through the uninitialised
      `bipred_weight_buf[1][parity]` (2.2d). Keep field pairs inheriting the
      frame's slice type (no mixed P/B).
- [x] 3.3 Threading invariant (D5): assert/disable sliced threading under PAFF;
      confirm the frame-thread pool is never used for a PAFF pair (`slices_write`
      direct call). Non-PAFF paths stay bit-identical.
- [x] 3.4 Rate-control soundness boundary — **decided D8**: PAFF B **hard-errors**
      ABR/CBR/VBV/2-pass (rate control runs once per pair with a merged
      bit-count, so the HRD sees a non-conformant double-sized picture per
      pair; only `--qp`/1-pass is bit-exact) until `paff-sei-hrd-rc`. Hard-error,
      not warn-and-disable, to keep users from shipping invalid streams.

## 4. Checkpoint

- [x] 4.1 Round-trip bit-exact for hierarchical B-field GOPs, TFF and BFF
      (oracle: ffmpeg — see design D10 / spec "Verification oracle"; JM 19.0 is
      itself buggy for PAFF and is not the operative oracle)
      **RE-CLOSED after task 2.5:** the "REGRESS" drift was root-caused to
      the PAFF P-field reference list (two bugs: §8.2.4.2.2 FrameNumWrap
      ordering over the full DPB, and the premature strict-pyramid BREF
      eviction ahead of its MMCO marking point) — NOT to deblock.  With
      both fixed, 14/14 configs round-trip byte-exact vs `--dump-yuv`
      (ffmpeg): hierarchical B-field GOPs, TFF+BFF, `--b-pyramid
      none/normal/strict`, `--ref 1-4`, all direct modes, CAVLC+CABAC,
      `--keyint 8/24`, 120-frame streams (frame_num wraparound),
      `--no-deblock`.  A non-fatal `mmco: unref short failure` ffmpeg
      warning may appear (field-sliding-window artifact); output stays
      byte-exact.
      **DONE (substance) via ffmpeg:** four in-scope PAFF conformance bugs were
      found and fixed during this checkpoint -- (a) mvpred `--ref 1` segfault
      (lowres `idx=-1` OOB); (b) field-PicNum `CurrPicNum = 2*frame_num+1`
      (8.2.4.1, was `+cur_parity`); (c) B-field reference-list construction
      (8.2.4.2.4/8.2.4.2.5 default list, was past-only + wrong expansion);
      (d) inter-pass sliding-window eviction threshold `i_frame_reference`->
      `sps->i_num_ref_frames`. ffmpeg now decodes PAFF **I/P AND B field GOPs
      byte-exact** vs `--dump-yuv`, incl. hierarchical `--b-pyramid normal`,
      TFF+BFF, `--ref 1/2/3`, all direct modes (24/24 configs verified). JM 19.0
      `ldecod` is itself buggy for PAFF (grays bottom fields even on conformant
      streams), so it cannot serve as the oracle; ffmpeg (rigorous, independent)
      is used. A non-fatal `mmco: unref short failure` warning may appear
      (ffmpeg field-sliding-window artifact around the IDR second-field
      single-field case, 8.2.1); output stays byte-exact.
- [x] 4.2 PSNR/SSIM **pass/fail** comparison vs MBAFF on interlaced test clips:
      B-field PAFF must fall within a fixed bound of MBAFF (threshold recorded
      from the first measurement); if it fails, D3 lowres work becomes in-scope.
      **PASS (D3 bound met with margin; no per-field lowres work needed).**
      Oracle: ffmpeg-synthesized interlaced clip (testsrc2 progressive @50fps,
      fields interleaved from adjacent frames -> true 25i TFF temporal interlace,
      720x576, 100 frames). Same clip encoded PAFF-B (`--paff --tff --bframes 2
      --b-pyramid normal`) vs MBAFF (`--interlaced --tff ...`), CQP sweep.
      At matched QP PAFF-B is 0.5-0.9 dB lower PSNR but at ~80% of MBAFF bitrate;
      at MATCHED BITRATE PAFF-B **beats** MBAFF by +2.6 to +3.8 dB PSNR (and
      +2.5 dB SSIM) -- expected, since pure field prediction dominates MBAFF on
      real interlace motion. Decisively within bound; D3 lowres work stays out of
      scope. (Single synthesized clip; real-content validation would strengthen
      but is not required for the gate. PAFF B cannot use --bitrate, so the
      comparison is CQP + matched-bitrate interpolation.)

- [x] 4.3 checkasm green; non-PAFF outputs bit-identical
      (PASS: checkasm8/10 green; 6/6 non-PAFF configs incl. 10-bit byte-identical
      vs baseline; the `--paff --ref 1` segfault regression found during the
      checkpoint was root-caused and fixed — `mvpred.c` lowres predictor OOB on
      `idx=-1` when L0[0] is the complementary field under `--ref 1`.)
