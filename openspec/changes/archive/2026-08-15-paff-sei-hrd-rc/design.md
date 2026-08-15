# Design: PAFF — SEI/HRD per field, rate control, threading

## Context

The first three changes made the pixel layer conformant. What remains is the
"plumbing" that assumes one coded picture per frame: SEI emission, HRD delay
modeling, rate-control accounting, and thread scheduling.

## Goals / Non-Goals

**Goals:**
- Per-field SEI and field-unit HRD timing, clean parse in JM and ffprobe.
- Rate control that produces sane per-field QPs and VBV compliance for PAFF.
- Defined threading behavior; documentation and CI coverage.

**Non-Goals:**
- Field-granular RC *decisions* (independent QP search per field) — frame-level
  decisions are kept.
- HRD verification against hardware decoders beyond parse-level checks (JM does
  not check HRD).

## Decisions

### D1: SEI emission per coded picture (field)

SEI emission moves from "once per frame" to "once per coded picture":
`pic_timing` with `pic_struct = 1` (top) / `2` (bottom) as required by Table D-1
for field pictures; `NumClockTS = 1`; `buffering_period` CPB/DPB delays in field
units; `dec_ref_pic_marking` writes the true `original_field_pic_flag` (fixes
the hardcoded 0 at `encoder/set.c:803` when PAFF is active). Progressive/MBAFF
SEI output stays bit-identical.

### D2: Rate control per field pair

RC keeps frame-level statistics and QP decisions; each field gets its own QP row
in the bitstream (separate slice headers make per-picture QP mandatory), derived
from the frame QP — v1 uses the same QP for both fields. Frame-level RC
accounting splits bits 50/50 as fallback if per-field predictors misbehave.
2-pass/mbtree remain frame-based.

### D3: Threading — pair inside one frame-thread slot

A complementary field pair is coded within one frame-thread slot (the existing
frame-thread unit is one frame, which now yields two coded pictures). PAFF +
sliced threads is **rejected at validation** in v1 (a clear error, not silent
disablement): slicing half-height field pictures doubles the verification
surface of every milestone. Low-latency slicing is documented as future work —
the broadcast-contribution audience will want it eventually.

**Resolution (task 3.1, frame threads DEFERRED):** v1 takes the bailout the
task offered and forces `i_threads = 1` under PAFF (validation in
`encoder_open`; sliced threads rejected, frame threads warned down to 1).
The pair driver is deep surgery for frame threading, not a local sync fix:

- x264 frame threads are valuable because `fdec_filter_row` broadcasts row
  completions (`x264_frame_cond_broadcast`) so a dependent thread's ME can
  start before its reference is fully filtered (`x264_frame_cond_wait` in
  `analyse.c`, on a per-MB pixel threshold). A PAFF reference pair is only
  usable as a *whole* after `paff_frame_finish`: `paff_sync_references` does
  two whole-frame `plane[]->plane_fld[]` + hpel + border sweeps (between the
  passes and after both), the second of which overwrites the stale
  second-field rows. So at best you broadcast "10000" once at finish —
  correct, but it collapses pipelining to "wait for the whole pair", i.e.
  near-zero overlap gain. The PAFF path (`paff_filter_row` /
  `paff_frame_finish`) never calls `x264_frame_cond_broadcast` at all today,
  so leaving frame threads on would deadlock the dependent thread.
- `paff_sync_references` mutates the full frame and toggles
  `i_threadslice_start/end` from *inside* the per-pair driver; mapping that
  onto `fdec_filter_row`'s incremental per-row broadcast cadence is a
  rewrite, not a patch.
- The wait site (`analyse.c: x264_frame_cond_wait(fref[ref>>MB_INTERLACED]->orig)`)
  assumes the standard ref-list shape; PAFF's field-expanded list injects
  `h->fdec` as the complementary field and reuses one pair object for both
  parities, so the `orig`/`i_lines_completed` semantics and the
  `ref>>MB_INTERLACED` indexing need dedicated auditing.
- Cross-thread state sync (`thread_sync_context` +
  `x264_thread_sync_ratecontrol`) is not audited for PAFF's per-parity frame
  fields (`i_field_bits[2]`, `b_field_kept_as_ref[2]`, per-parity
  `i_ref[]/ref_poc[]/i_poc_l0ref0[]`) or pair-level ratecontrol (D2) —
  exactly the gaps that only surface under the 8.1 full matrix, which itself
  is blocked by 5.1/6.2/7.x.

Verified behaviorally: `--threads 4/8 --paff` warns and forces down to 1;
`--threads N` output is byte-identical to `--threads 1` (forcing is total,
`i_thread_frames = 1`, lookahead single-threaded too); single-threaded is
self-deterministic. Frame threads + low-latency slicing are future work,
documented in `doc/paff.txt` (task 4.1).

### D4: Pulldown/timecode restrictions

Audit which pulldown modes and timecode flows are meaningful under PAFF; reject
unsupported combinations in `x264_param_validate` and document them in
`doc/paff.txt`.

### D5: IDR field pairs coded as Ip (QSV-compatible)

The second field of a keyframe pair is coded as a **P field referencing the
pair's first field**, not as a second IDR field.  This matches industry
practice: QSV/libmfx does exactly this (`ExtendFrameType` in MediaSDK:
"second field can't be IDR", I→P; ffmpeg's qsvenc only passes a frame-level
type through).  It also fixes two formal conformance violations of the "II"
structure: two consecutive IDR access units (the two fields) carried equal
`idr_pic_id`, forbidden by §7.4.3, and a pair whose second field is IDR is
not a complementary reference field pair at all (§3.37).  Consequences:
- Only the first field's AU is an IDR access unit, so D.2.2
  ("buffering_period SEI in every IDR access unit") is satisfied by the
  existing single BP SEI — the "BP SEI in both IDR fields" option is dropped,
  no tick rebasing needed.
- The `idr_pic_id` xor-undo hack in the PAFF driver is removed.
- The second field inter-predicts from the first → cheaper keyframes.
- The per-pass reference machinery already exists (ordinary P pairs
  reference the pair's first field since `paff-core-ip`).
- All previously validated keyframe-containing streams change → full
  re-baseline at the final checkpoint.
- 2-pass: the pair stays a frame-level keyframe entry; per-field bit
  accounting (D2) absorbs the I/P split.

**Resolution (task 7.1, IMPLEMENTED):** the per-pass PAFF driver diverges the
keyframe pair's slice/nal type: pass 0 stays the IDR field (frame_num 0,
POC 0), pass 1 becomes a non-IDR P field (sh.i_type = P, i_nal_type =
NAL_SLICE) referencing the pair's first field via the existing complementary
injection (paff_expand_field_list b_complementary=1 with an empty past list,
so L0 = [first field]).  Both fields share one frame_num; frame_num still
increments once per pair.  POC needs no change (the per-field path
sh.i_poc = base_poc + i_delta_poc[parity] already yields 0/1).  The pair is
restored to its pair-level I/IDR type after the loop for frame-end consumers.
Key finding (the actual blocker beyond the driver): `paff_expand_field_list`'s
`PAFF_PUSH` macro special-cased X264_TYPE_IDR references to a SINGLE
available field (the old II-structure DPB survivor, parity b_tff?1:0).
Under Ip an IDR pair is a full 2-field reference like any other, so that
special case was removed -- an IDR reference now gets avail=3 (both fields).
With the old macro left in, P frames referencing the Ip keyframe built a
1-field list while the decoder built a 2-field list -> reference-list/
MC divergence (every P frame after a keyframe mismatched by ~68%).  Verified:
dump-vs-ffmpeg byte-exact across TFF/BFF x ref 1-4 x CABAC/CAVLC x keyint
10/250 x CRF/2-pass/CBR+nal-hrd, plus B-pyramid; progressive/MBAFF
unchanged; the task-5.1 ffmpeg `mmco: unref short failure` warning is GONE
(the II single-field survivor that tripped the decoder's sliding window no
longer exists); checkasm green.  The `--aud` pic_type still reflects the pair
(I) for both field AUs (a pre-existing per-pair AUD, off by default); not
regressed by Ip and tracked separately if per-field AUD is ever wanted.
- AVC-Intra flavor: combination rejected at validation (OQ2 below).

## Risks / Trade-offs

- [HRD CBR with field AUs is not checked by JM] → build an independent
  Annex C CPB simulator (`tools/check_hrd.py`: SPS VUI HRD params +
  buffering_period/pic_timing SEI + AU sizes, buffer modeled at field
  ticks) and gate `--nal-hrd cbr` streams on it; parse-level JM/ffprobe
  checks remain as smoke tests.
- [RC quality regression vs MBAFF on interlaced content] → acceptable for v1;
  measure with `--tune ssim` metrics vs MBAFF and document in `doc/paff.txt`.
- [Weighted prediction for field pictures] → reuse the MBAFF weight path
  (weights on `plane_fld`); disable under PAFF only if it fails the JM gate.

## Open Questions

1. ~~Exact VBV accounting granularity~~ RESOLVED: per-field AU removal timing,
   per Annex C (C-1/C-2: arrival and removal are per access unit; each field
   is its own AU; tick = field period via `time_scale = timebase_den*2`).
   A pair-level model provably misses CPB underflow when the first field is
   large (pair bits arrive by tick 2, but field 1 is removed at tick 1).
   Task 2.3: step the internal VBV per field AU with per-field bits
   (`i_field_bits[2]`) and halved `buffer_rate`; acceptance gate is the
   Annex C simulator from task 2.4.
2. ~~AVC-Intra + PAFF~~ RESOLVED: rejected at validation in v1 with a clear
   error and documented in `doc/paff.txt`.  Full support (II pairs preserving
   the all-intra class plus class-specific padding/slice constraints over
   field pairs) is a separate future change.
