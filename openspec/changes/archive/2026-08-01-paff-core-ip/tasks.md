# Tasks: PAFF core — field-pair coding of I/P pictures

Sections are dependency-ordered. The change ends with a verifiable checkpoint
(JM round-trip). See `design.md` for decisions D1–D5.

## 1. Test infrastructure

- [x] 1.1 Set up the JM reference decoder build (per `doc/regression_test.txt`,
      but fetch the current JM 19.x, not 17.2) and script the round-trip:
      `x264 --dump-yuv` vs `ldecod` output diff
- [x] 1.2 Write a PAFF round-trip script (`tools/test_paff.sh`) that encodes a
      known interlaced test clip in PAFF mode and diffs against JM. Test clips
      are synthesized from progressive sources with ffmpeg `tinterlace` (small,
      deterministic, CI-friendly); the SVT 1080i25 set is used for manual
      quality runs only. No test media committed to git. The script is written
      now but run only after PAFF encoding is implemented (section 3).
- [x] 1.3 Baseline: confirm current master passes checkasm and the
      progressive/MBAFF JM round-trips (regression reference for
      "bit-identical when PAFF is off")

## 2. API and validation

- [x] 2.1 Add `int b_paff` to `x264_param_t` in `x264.h` (D2); bump
      `X264_BUILD`; update `x264_param_parse` to handle `--paff`; add named
      constants (`X264_INTERLACED_OFF`, `X264_INTERLACED_MBAFF`) for
      `b_interlaced` documentation clarity
- [x] 2.2 Validation: reject `b_paff && b_interlaced` and `b_paff &&
      b_fake_interlaced` and `b_paff && avcintra_class`; for this change also
      reject PAFF + B-frames / weightp (D3); reject `b_sliced_threads` under
      PAFF and force `i_threads = 1` with a warning (threading policy is
      deferred to `paff-sei-hrd-rc`); CLI: `--paff` force-disables
      bframes/weightp with a warning in `x264.c` (library stays strict —
      API callers get an init error, CLI users get a working default)

## 3. Headers and field-pair driver

- [x] 3.1 SPS/PPS in `encoder/set.c`: `frame_mbs_only_flag=0` when
      `b_interlaced || b_fake_interlaced || b_paff`; `mb_adaptive_frame_field_flag`
      stays `= b_interlaced` (unchanged, only MBAFF sets it to 1);
      field-height `pic_height_in_map_units_minus1`; VUI field flags;
      poc_type 0 also when `b_paff` (`|| param->b_paff` at `set.c:173`)
- [x] 3.2 Field-pair driver in `encoder/encoder.c` (D1): internal loop after
      rate control init that calls `slice_init` + `slices_write` twice per frame
      with per-pass: `sh.b_field_pic=1`, `sh.b_bottom_field` per TFF/BFF and
      pass number, per-field POC (`base_poc + pass`), shared `frame_num`
      across both passes; IDR pairs: both passes are IDR and share one
      `idr_pic_id` (§7.4.3)
- [x] 3.3 Per-field POC (D4): `h->fdec->i_poc = base_poc + pass` set by the
      driver before each pass (read by `slice_init` at `encoder.c:2658` and
      `reference_build_list` at `encoder.c:3583`); `h->fenc->i_poc` stays at
      the even frame-level base POC; restore `h->fdec->i_poc = base_poc` after
      the pair so reference frames keep uniform frame-level POCs;
      `pic_order_cnt_lsb` written per field (already supported by slice header
      code at `encoder/encoder.c:241`)
- [x] 3.4 Reference lists (D3): same-parity previous field as ref0, enforced
      via `ref_pic_list_modification` in the slice header (infrastructure at
      `encoder/encoder.c:256+`); `num_ref_idx_l0_active=1`; exception: the
      first P field after an IDR pair references the opposite-parity survivor
      field (`b_field_ref_opposite`, no reordering command); chroma MV offset
      for opposite-parity references in `common/macroblock.c` + `encoder/me.c`
- [x] 3.5 Force field-mode MB coding picture-wide (D1): `MB_INTERLACED=1`,
      `SLICE_MBAFF=0`; MBs stay in frame coordinates with each pass iterating
      its own parity rows (`i_mb_y += 2`); gate MBAFF pair-structure neighbour
      logic in `common/macroblock.c` (`i_neighbour_skip`, `b_allow_skip`) on
      `b_mbaff && !FIELD_PIC`; audit `common/macroblock.c` and
      `encoder/macroblock.c` for remaining `MB_INTERLACED`/`SLICE_MBAFF`
      coupling
- [x] 3.6 Verify 8x8dct/trellis field paths work with `SLICE_MBAFF=0` /
      `MB_INTERLACED=1` (open question 1 from design); verify chroma MV
      offset in `encoder/me.c:875` with field-based MB row indexing
      (open question 2 from design)

## 4. Checkpoint

- [x] 4.1 JM round-trip bit-exact for I-only and I+P PAFF streams (TFF and BFF),
      encoded with `--qp 20 --threads 1` (constant QP isolates bitstream
      conformance from the deferred rate control); plus a default-CRF smoke
      run: no crash, JM decodes to the end, sane PSNR — not a bit-exact gate
- [x] 4.2 checkasm8/checkasm10 green; progressive/MBAFF decoded outputs
      identical to the baseline from 1.3 (pixel-level compare via JM, robust
      to SEI version-string changes)
