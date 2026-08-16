# x264

The H.264/AVC encoder from VideoLAN. This file is the domain glossary used
in discussions and documentation. Definitions are intentionally plain;
for normative wording consult the H.264 spec.

## Language

**Interlaced video**:
A frame consists of two fields captured at different moments in time:
the top field is the even lines, the bottom field is the odd lines.

**Field**:
Half of a frame: only the even lines (top) or only the odd lines (bottom).
_Avoid_: half-frame

**Complementary field pair**:
The top and bottom fields of one frame, coded as two separate pictures.
_Avoid_: field couple

**Field line**:
A single row of samples within one field. Vertical distances inside a
field (MV components, search ranges, thread wait thresholds under PAFF)
are measured in field lines; one field line spans two frame lines.
_Avoid_: half-line

**Field units (MV)**:
Expressing a vertical quantity in field lines (or quarter-field-lines
for MV components) rather than frame lines. Under PAFF `i_mv_range`,
the coding-pass MV limits and the VUI max-MV signal are in field units;
the level table and the lookahead lowres range are in frame units.

**Emulated edge**:
The margin around a reference plane made by replicating edge samples,
letting motion compensation read slightly outside the picture. Reading
there is memory-safe but finds only smeared edge, not real content.
Under PAFF each parity gets its own vertical edge (32 field lines),
expanded separately.

**PAFF**:
A coding mode where every field is its own coded picture with its own
slice header. What this project adds.
_Avoid_: field-picture mode

**MBAFF**:
The pre-existing x264 mode: the frame is coded as a whole, but individual
macroblock pairs inside it may be treated as field pairs.
_Avoid_: macroblock-level interlacing

**Uniformly-field picture**:
A coded picture whose every macroblock row belongs to one parity — the
whole field, not a macroblock pair inside a frame. Every picture in PAFF
is like this; in MBAFF "field" is a property of a macroblock pair, not of
the picture. This is where the PAFF/MBAFF incompatibility of direct /
MV-prediction field modes comes from.
_Avoid_: pure-field picture

**Field order (TFF/BFF)**:
Which field is displayed first: top (TFF) or bottom (BFF).

## Threading

**Frame-thread slot**:
One of the `i_thread_frames` encoder contexts. Each slot codes one unit at
a time (progressive: a frame; PAFF: a complementary field pair) and slots
rotate round-robin per coded unit; the output of a slot is returned to the
caller several units later.
_Avoid_: frame thread (that is the thread, not the slot)

**Readiness**:
How much of an in-flight reference picture is final and safe to read from
another slot's motion search. **Phase-granular**: fixed points only (after
the intermediate sweep, after the pair finishes). **Row-granular**: rows of
the picture become readable as the coding pass progresses. Row-granular
readiness forces a motion-vector range clamp, exactly as progressive frame
threads do. **Hybrid**: the PAFF model — the first field of a pair is
phase-granular, the second is row-granular.
_Avoid_: progress (of a reference)

**Intermediate sweep**:
The reference-data generation run between the two field passes
(`paff_sync_references`): copies the reconstructed rows into the field
layout and builds field borders + half-pixel data, making the first field
usable as a reference before the second pass starts.
_Avoid_: sync pass

## Bitstream

**Coded picture**:
The unit of coding: one frame (in frame mode) or one field (in PAFF).
The slice header and the POC belong to a picture.
_Avoid_: access unit (that is the picture's container in the stream)

**POC (picture order count)**:
The picture's number for display order. In PAFF every field has its own
POC.
_Avoid_: display index

**Reference picture**:
An already-coded picture that later pictures refer to for motion
compensation.

**DPB (decoded picture buffer)**:
The decoder's "warehouse" of finished pictures from which references are
taken. It has a limited size.
The unit of capacity is not a field but a **slot**: a whole frame, a
complementary field pair, or an unpaired field (§8.2.5). Capacity is
`max_num_ref_frames` slots. Under field coding (PAFF) a field pair
therefore occupies one slot, not two.

**MMCO**:
Commands controlling the DPB: which pictures to drop, which to mark as
long-term references.
_Avoid_: marking commands (without spelling out)

**Field PicNum**:
The picture number used by MMCO commands when the picture is a field:
`2·FrameNumWrap + parity` (§8.2.4.1). It differs from the frame PicNum,
so marking commands for field pictures must count it in field units.
_Avoid_: field picture number

**Keyframe pair (IDR pair)**:
The field pair at a GOP boundary. Coded as "Ip": the first field is an
IDR, the second is a P field referencing the first (like QSV/libmfx
does). Not "II".
_Avoid_: IDR frame (PAFF has no single IDR frame)

**Colocated field**:
The single field taken from `RefPicList1[0]` as the template in temporal
direct mode (§8.4.1.2.4). In MBAFF it is picked by parity from the frame;
in PAFF the whole picture is one field.
_Avoid_: collocated picture

**dist_scale_factor**:
The motion-vector scaling factor `tb/td` (§8.4.1.2.4), precomputed for
every reference pair (L0 ref, L1 ref).
_Avoid_: MV scale ratio

**num_ref_idx active override**:
A slice-header flag: the encoder overrides the number of active
references in L0/L1 (`num_ref_idx_active_minus1`) when it expands the
field list to 2x the pair-level size. Without it the decoder uses the
pair-level size → invalid ref_idx.
_Avoid_: ref count flag

**Bipred tables (`dist_scale_factor_buf` / `bipred_weight_buf`)**:
Arrays of `[…][4]` (the last dimension is the L1 index, capped at 4).
They overflow when L1 is field-doubled (≥6 entries); under PAFF the
`[1][parity]` slots are written with field POCs and always read.

**SEI**:
Service messages in the stream next to pictures: timing, field order,
etc. They do not affect pixel decoding but are needed for presentation.

**HRD / VBV**:
The decoder buffer model: a check that a stream at a given bitrate
neither overflows nor drains the buffer during reception.

## Process

**Change (openspec change)**:
A unit of work in openspec: proposal, design, tasks, delta specs.
_Avoid_: change (without context)

**Milestone**:
A part of a change ending in a verifiable result.
_Avoid_: milestone

**Checkpoint**:
The verification at the end of a milestone: usually a byte-exact
comparison of x264 output against the JM reference decoder.
_Avoid_: gate

**JM / ldecod**:
The ITU reference H.264 decoder. The correctness criterion: its output
must match the x264 reconstruction (`--dump-yuv`) byte for byte.
**For PAFF:** JM reconstructs field pictures correctly when the stream
carries per-field `pic_timing` SEI with `pic_struct` (without it, JM 19.0
output the bottom fields as flat grey 128 — which was the real cause of
the old "JM is broken for PAFF" caveat). Verified: `tools/test_paff.sh`
passes the full matrix (30/30) against stock ldecod. ffmpeg remains the
second independent decoder for cases where JM is unstable (e.g. a SIGSEGV
on some 2-pass B variants, see task 6.2 of the `paff-sei-hrd-rc` change).
_Avoid_: reference decoder (without spelling out)
