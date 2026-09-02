# Design: PAFF core — field-pair coding of I/P pictures

## Context

x264's pipeline is frame-centric: one input `x264_frame_t` → one coded picture →
one access unit. MBAFF codes frames whose MB pairs flip between frame/field mode;
`field_pic_flag` is never set (`encoder/encoder.c:139`).

The pixel-level field machinery already exists thanks to MBAFF:
field-strided planes (`plane_fld[]`, `filtered_fld[]`, `buffer_fld[]` in
`common/frame.c`), field MC with parity in the ref index (`j>>1`/`j&1`,
`common/macroblock.c:617-647`), field MV prediction (`common/mvpred.c`), field
CABAC/CAVLC contexts (`encoder/rdo.c`), field deblock mode (`common/deblock.c`).

The slice header writing code already fully supports `field_pic_flag=1`:
`encoder/encoder.c:231-233` writes `field_pic_flag` and `bottom_field_flag`;
line 242 already skips `delta_pic_order_cnt_bottom` for field pictures;
ref-pic-list reordering infrastructure exists (lines 256+).

What does NOT exist: picture-level field state (two coded pictures per frame),
field-level reference/DPB management, field-level POC, per-field SEI. This change
adds the first and third; the rest come in follow-up changes.

## Goals / Non-Goals

**Goals:**
- Conformant PAFF bitstreams with I and P field pictures, decodable bit-exact by
  JM ldecod; field order selectable (TFF/BFF).
- Reuse MBAFF field machinery; progressive/MBAFF output bit-identical when PAFF
  is off; no new assembly (`checkasm` green).
- Scripted JM round-trip infrastructure reused by all follow-up changes.

**Non-Goals:**
- Mixed-parity / multi-frame reference lists, MMCO, sliding window in field
  units → `paff-field-references`.
- B field pictures, direct modes → `paff-b-frames`.
- Per-field SEI/HRD, rate control, threading policy → `paff-sei-hrd-rc`.
- PAFF-specific SIMD; slice threading for field pictures (force-disabled).

## Decisions

### D1: Field-pair driver — one encode call, two picture passes

Keep one `x264_frame_t` per input frame (allocation, lowres, input pipeline,
frame-threading unit unchanged). For PAFF, `x264_encoder_encode` produces *two*
coded pictures from one frame in a single call — top field pass and bottom field
pass (order per `b_tff`). Both fields share one access unit with one frame-level
PTS; the caller sees one `pic_out` as for MBAFF.

The driver is an internal loop *inside* `x264_encoder_encode`, after rate control
init and before `encoder_frame_end`:

```
if( b_paff ) {
    for( int pass = 0; pass < 2; pass++ ) {
        set per-field POC (base_poc + pass);
        set sh.b_field_pic = 1;
        set sh.b_bottom_field = b_tff ? pass : !pass;
        setup_ref_list_for_parity( pass );
        slice_init( h, ... );      /* same idr_pic_id for both passes of an IDR
                                      pair (§7.4.3) */
        slices_write( h );
    }
} else {
    // existing path, untouched
}
```

SEI, SPS/PPS, and rate control operate per frame (not per field — field RC is
deferred to `paff-sei-hrd-rc`).  NALs from both passes accumulate in `h->out.bs`
and are returned together.  `frame_num` increments once per pair (after both
passes complete), matching §7.4.3.

**Buffer layout — interleaved `plane_fld` with `MB_INTERLACED=1`:**  Each pass
operates on the *interleaved* `plane_fld[]` buffers (same memory layout as
`plane[]`; field addressing is done with doubled strides, exactly as MBAFF
field MC does).  An earlier draft of this design assumed `plane_fld` held
deinterleaved field data and added stride fixes at 3 source-load sites in
`encoder/macroblock.c`; that assumption was wrong and the fixes were reverted.
MBAFF field bitstream semantics are activated via `MB_INTERLACED=1` /
`SLICE_MBAFF=0` (interlaced zigzag, interlaced CABAC contexts,
`mb_field_decoding_flag=1`).

**MB coordinates — frame-based with parity-row iteration:**  MBs are tracked in
frame coordinates; each pass iterates only the rows of its own parity
(`i_mb_y += 2`, starting at `parity`).  `i_first_mb`/`i_last_mb` are kept in
frame coordinates internally and converted to the field raster when written to
the slice header (`first_mb_in_slice` is a field-picture address, §7.4.3).
Neighbour derivation in `macroblock_cache_load_neighbours` yields field
neighbours for free: with `MB_INTERLACED=1` the "top" row is `mb_y - 2` (same
parity).

**CABAC neighbour contexts under field pictures:**  any context code gated on
the MBAFF pair structure must NOT run under PAFF.  Concretely,
`i_neighbour_skip` (skip-flag context) and `b_allow_skip` in
`common/macroblock.c:macroblock_cache_load` use MBAFF pair coordinates
(`mb_xy - stride` = the other MB of the pair); under PAFF the plain
non-MBAFF formula is correct because `i_mb_type_top`/`i_mb_type_left[0]`
already hold field neighbours.  Both blocks are gated on
`b_mbaff && !FIELD_PIC`.

*Alternative — "fields as independent frames"* (deinterleave rows at input, run
the pipeline on half-height pictures): rejected. It breaks 4:2:0 chroma phase,
loses the complementary-pair relationship needed later for reference lists
(§8.2.4.2.2), and doubles lookahead/RC state for no benefit.

*Alternative — interleaved `plane[]` with doubled stride*: rejected. MBAFF
addresses MBs in frame coordinates (row 0, 1, 2, 3…), but PAFF with
`field_pic_flag=1` requires field coordinates (row 0, 1, 2… where each row is a
field row).  Using frame coordinates would require rewriting the 4600-line
MB loop to skip alternate rows.  (Note: the implemented design still stores
pixels interleaved via `plane_fld`; what matters is that MB *coordinates*
stay frame-based, with the MB loop stepping `i_mb_y += 2` per pass.)

**Field MB height:** the original draft proposed a separate `i_mb_height_field`
variable; the implementation instead keeps frame-coordinate `i_mb_height` and
iterates parity rows, which turned out to touch far less code.

### D2: API — new `b_paff` field in `x264_param_t`

Add `int b_paff` to `x264_param_t`.  `b_interlaced` semantics unchanged
(0 = off, 1 = MBAFF).  PAFF and MBAFF are mutually exclusive — validation
rejects `b_interlaced && b_paff`.  `X264_BUILD` is bumped because struct size
grew.  CLI: `--paff` sets `b_paff=1`.

*Alternative — overload `b_interlaced` with value 2*: rejected.  `b_interlaced`
is used as boolean throughout (`PARAM_INTERLACED`, `set.c:185` truthiness
derivation, `CHECK("interlaced", …)`, OPT handlers in `base.c`).  Overloading
to 2 would require auditing every boolean usage site; missing one would silently
enable MBAFF semantics under PAFF.  A separate field leaves all existing code
untouched — zero regression risk.

### D3: Minimal references — same parity via ref_pic_list_modification

For this change, a P field references only the most recent reference field of the
*same parity*.  This exercises slice-header, POC, and reconstruction paths
without touching DPB bookkeeping.  B pictures, weighted prediction, and
mixed-parity lists are rejected in param validation under PAFF for now.

**Why `ref_pic_list_modification` is needed:**  The H.264 default reference list
(§8.2.4.2) orders by decreasing POC.  The second field of a pair always has
higher POC than the first, so it appears first in the list — opposite parity to
what we want.  With `num_ref_idx=1` we would get the wrong field.  A
`ref_pic_list_modification` command (§7.4.3.3) in the slice header moves the
same-parity field to position 0.  Infrastructure for this already exists in the
slice header code (`encoder/encoder.c:256+`).

**Exception — the first P field after an IDR pair:**  §8.2.5.1 runs the
decoded-reference-picture marking *per coded picture*.  The second field of an
IDR pair is itself an IDR picture, so its marking step ("all reference pictures
marked unused for reference") evicts the pair's *first* field from the DPB.
After an IDR pair the DPB holds only the second field (confirmed with both JM
and ffmpeg).  The first P field of the next frame therefore references the
*opposite*-parity field: no reordering command is signalled (it is the sole
reference, the default list already has it at position 0), and the encoder's MC
is flipped to the opposite-parity field of the reference frame
(`h->sh.b_field_ref_opposite`, consumed in
`common/macroblock.c:macroblock_load_pic_pointers`).  All later passes use the
same-parity rule above.

**Chroma offset for opposite-parity references (§8.4.2):**  when a field MB
predicts from a field of the opposite parity, the chroma motion vector gets a
vertical adjustment of ±2 quarter-pel (JM `chroma_vector_adjustment`: −2 for
top←bottom, +2 for bottom←top).  In MBAFF this is keyed off the parity bit of
the reference index (`i_ref & 1`); under PAFF there is only one reference index,
so the condition is `b_field_ref_opposite` instead
(`common/macroblock.c:mb_mc_0xywh`, ME side in `encoder/me.c`).

### D4: Per-field POC, poc_type 0

`TopFieldOrderCnt`/`BottomFieldOrderCnt` derived per §8.2.1; `pic_order_cnt_lsb`
per field. x264 already selects poc_type 0 when interlaced (`encoder/set.c:173`)
— add `|| param->b_paff` to the condition.  `frame_num` increments once per
complementary pair (both fields share it, §7.4.3).  POC is computed as
`base_poc = 2 * frame_offset` in the existing code (`encoder/encoder.c:3512`).
`h->fenc->i_poc` is NOT touched by the passes: it is frame-level state tied to
PTS and read by open-GOP logic (`encoder.c:3533`).  The field-pair driver sets
`h->fdec->i_poc = base_poc + pass` before each pass — this is the value read by
`slice_init` (`encoder.c:2658`) and `reference_build_list` (`encoder.c:3583`) —
and restores `h->fdec->i_poc = base_poc` after the pair, so the reconstructed
frame enters the reference buffer with a uniform even frame-level POC (matches
D3: references are frames, the field is selected by parity via `j&1`).

### D5: Deblocking — no pair-boundary logic, but row filtering is per pass

No filtering between the two fields of a pair — they are separate coded pictures
(§8.7.2).  The *bitstream semantics* come for free: each field picture is
independently deblocked, and the deblock filter naturally stops at picture
boundaries.  The top field's last MB row has no "below" neighbor; the bottom
field's first MB row has no "above" neighbor.

The *mechanics* are NOT automatic: filtering is driven row-by-row through
`fdec_filter_row` (`encoder/encoder.c:2413`) over frame rows.  Under PAFF the
driver must run row filtering per pass over field rows with `plane_fld`
addressing — part of the MB-loop audit in tasks 3.5/3.6.

## Risks / Trade-offs

- [Two-pictures-per-frame fights the frame-centric main loop] → Isolate in a
  field-pair driver loop inside `x264_encoder_encode`; `h->fdec`/`h->fenc`
  semantics per pass documented above.
- [POC/marking bugs are silent until drift] → The JM round-trip gate ends this
  change; the script is built first (tasks section 1).
- [Hidden frame-mode assumptions in MB code paths] → Audit
  `common/macroblock.c` and `encoder/macroblock.c` load paths for
  `MB_INTERLACED`/`SLICE_MBAFF` coupling before the gate.
- [Stride fix correctness] → Only 3 sites; reference MC already uses `plane_fld`
  and is unaffected; checkasm stays green by design.
- [pic timing SEI under PAFF] → Left frame-level (`pic_struct=0`) for now; SEI
  does not affect pixel decoding and the JM gate ignores it.  Conformance with
  §D.2.1 for a field pair in one AU is verified in `paff-sei-hrd-rc`.
- [Chroma formats other than 4:2:0] → The JM gate covers 4:2:0 only (the
  tinterlace-synthesized clips).  4:2:2/4:4:4 PAFF rides the same field
  machinery as MBAFF (which has no chroma-format restriction today) and is not
  separately verified in this change.

## Open Questions (resolved during implementation)

1. 8x8dct/trellis field paths — **verified**: I_8x8 and P_8x8 MBs appear in
   the bit-exact JM round-trip streams with `SLICE_MBAFF=0`, `MB_INTERLACED=1`.
2. Chroma MV offset (`encoder/me.c:875`) — **resolved**: the
   `(h->mb.i_mb_y & 1)*4 - 2` parity term is correct with frame-coordinate
   `i_mb_y` (bottom-field passes have odd `i_mb_y`); the *condition* for
   applying it is `b_field_ref_opposite` under PAFF, not the MBAFF
   reference-index parity bit.
