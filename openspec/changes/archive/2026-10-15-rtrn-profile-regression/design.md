# Design: rtrn-profile-regression

## Context

See proposal.md — Why. Exploration before this design verified every
assertion mechanism against a real encode (MediaInfo 24.11, ffprobe
from the installed ffmpeg, the current master x264 binary), so the
decisions below are grounded in observed behaviour, not assumptions.
During change review the load-bearing claims were re-verified against
ticket #63682 (the reference command line and the 11 requirements from
#11121) and re-run on the current tree; one exploration claim proved
wrong and is corrected in D1 — ffprobe 8.1.3 flags open-GOP
recovery-point I frames with key_frame=1 too, so IDR counting cannot
run on key_frame.

## Goals / Non-Goals

Goals:
- One command (`tools/test_paff.sh rtrn`) reproduces the customer-facing
  verification locally in under a couple of minutes.
- Every DoD-item-3 check from ticket #63682 maps to an asserted cell.
- The suite skips cleanly (not fails) when optional tools are missing.

Non-goals:
- No CI integration: CI images lack mediainfo/JM; `test_paff_ci.sh`
  stays as the CI smoke layer.
- No changes to encoder code or to the RTRN profile itself.
- No fixing the system-ffmpeg raw-PAFF remux limitation (missing
  field-AU timestamps); the TS-level cell uses a PAFF-capable ffmpeg via
  env var instead. The remux limitation is recorded as a data point for
  issue #64866.

## Decisions

### D1: Assert on the raw Annex-B stream with mediainfo; GOP geometry from ffprobe pict_type; IDR discipline from a NAL scan

MediaInfo computes `Format settings, GOP: M=4, N=28` only in a container
context; on a raw .264 it never prints the GOP line (verified with
`--ParseSpeed=1`). Remuxing raw PAFF with the installed system ffmpeg
fails (the mpegts muxer rejects timestamp-less field access units;
re-verified four ways — naive copy, `+genpts`, `-framerate`, bare
copy). Therefore:
- All field-table assertions run on the raw stream, where MediaInfo
  reports everything else (scan type/order, store method, profile@level,
  ref frames, colorimetry, range, frame rate, DAR).
- GOP cadence (M=4, N=28) is computed from `ffprobe -show_frames`
  pict_type output: consecutive-B run length gives M, distance between
  I pictures gives N; the first frame must carry key_frame=1; the
  packet count gives the 2-field-AU-per-frame check.
- IDR discipline runs on a small python3 Annex-B NAL-type scan: exactly
  one nal_unit_type-5 slice. ffprobe cannot do this — it flags
  recovery-point I frames with key_frame=1 as well (observed: key_frame
  = 1 on both the IDR and the open-GOP recovery I), so key_frame
  counting conflates the two. The NAL scan also catches a silent
  open-GOP to closed-GOP regression (a second IDR), which the cadence
  checks alone cannot see. Scanning for start codes is reliable:
  emulation prevention guarantees no start-code lookalikes inside NAL
  payloads.
- Alternative considered: parse the TS the same way the customer does,
  always. Rejected because it would hard-depend on a PAFF-capable ffmpeg
  that does not exist in most environments; kept as the optional
  `FFMPEG_PAFF` cell instead.

### D2: Field-table assertions parse MediaInfo text output, not JSON

MediaInfo 24.11's `--Output=JSON` omits the fields we care about most
(`ScanType_StoreMethod`, `Format_Settings_GOP`, `ColourRange` come back
null) while the text output carries them. Parsing the stable
`key : value` text lines (exact-string compare) is simpler and more
complete than JSON here. Risk of locale/format drift is accepted: the
suite pins exact strings and fails loudly, which is the point of a
regression test.

### D3: Clip synthesis in python3, geometry pinned

A 56-frame 720x576 clip synthesized at runtime with python3 (enough for
two full GOPs of 28), even/odd rows carrying separate motion phases so
PAFF has real field content. No media committed to git, consistent with
test_paff.sh conventions. Content is deliberately free of scene cuts so
the keyint cadence (not scenecut) governs recovery points.
Two deliberate deviations from the suite's existing recipes, both
documented in the command header:
- python3 instead of ffmpeg tinterlace: the source is byte-stable on
  every machine forever and cut-free by construction, while the
  tinterlace recipes already carry ffmpeg-version fragility (the
  ffmpeg 8 vs <=7 height-doubling workarounds elsewhere in the suite).
- the geometry is pinned (720x576, 56 frames) and WIDTH/HEIGHT/FRAMES
  env overrides are ignored: the profile assertions (SAR 16:11, DAR
  16:9, Main@L3) are geometry-bound, and a silent override would break
  cells confusingly.
python3 joins mediainfo in the skip-if-missing tool checks of the
command.

### D4: The suite documents the min-keyint clamp instead of fighting it

`--min-keyint 28` is clamped by x264 to `keyint/2+1 = 15` (upstream
behaviour, visible in the `Encoding settings` line). The reference
command line from the ticket therefore effectively runs with
keyint_min=15. The suite encodes with the reference options as-is and
asserts the *observable* contract (N=28 cadence on cut-free content,
no mid-GOP IDR), and the documentation states the clamp explicitly so
nobody "fixes" the spell later.

### D5: Live as a `tools/test_paff.sh` command, not a new script

All PAFF verification already funnels through test_paff.sh commands;
`rtrn` joins them, inherits the harness conventions (WORKDIR handling,
skip semantics, X264 env override), and keeps the entry points
discoverable in one usage block. The `all` command includes `rtrn` —
a regression suite nobody runs protects nothing, and `all` is the
habitual post-refactor entry point; cells skip visibly when
mediainfo/python3 are absent.

### D6: RC shape: ABR + VBV, no HRD — ticket requirements 4 and 11

The ticket's "CBR 2720 kbit/s" is container-level CBR (constant muxrate
is the muxer's job, sapsan territory); the elementary stream is ABR
2720 bounded by VBV 3500/1400. `--nal-hrd cbr` is impossible at
2720 != 3500 — the encoder warns "CBR HRD requires constant bitrate"
and silently downgrades to VBR — and requirement 11 explicitly
deactivates HRD, so the reference encode carries no `--nal-hrd` at all.
A checked side-run with `--nal-hrd vbr` (the only other legal mode)
passes every assertion untouched (MediaInfo merely adds a "Bit rate
mode" line); recorded here so nobody mistakes HRD-off for an accident.

### D7: Byte-repeat covers both pair drivers

Two encodes at `--threads 1` (the monolithic pair driver,
`paff_pair_write`) and two at `--threads 4` (frame-threaded pool jobs,
rendezvous, per-field reference bands) — each pair must be
byte-identical. Fixed N instead of auto: the cell's meaning is
machine-independent. An auto-threads repeat was verified too
(byte-identical at N=18) but adds nothing over fixed-N and would make
the result machine-dependent in interpretation.

## Risks / Trade-offs

- [MediaInfo output format changes across versions] → assert exact
  strings; a format drift fails the test loudly and is trivially
  re-baselined. MediaInfo is only required locally.
- [ffprobe version differences in frame metadata] → the fields used
  (pict_type, key_frame on the first frame) are ancient and stable; the
  suite deliberately does not depend on key_frame flagging of
  recovery-point I frames (version-sensitive semantics), which is why
  IDR counting runs on our own NAL scan.
- [Synthetic clip accidentally triggers scenecut, shrinking N] → clip
  content is deterministic and cut-free by construction; if a future
  x264 change alters scenecut decisions on it, the failure is a real
  signal about GOP discipline, which is what the customer requirement
  protects.
- [TS cell silently skipped forever] → skip message names the env var,
  the reason, and sapsan (#65229) as the intended build source; the
  sapsan integration work (#65229) is where the TS-level verification
  will run end-to-end anyway.

## Migration Plan

Additive tooling only. Rollback = delete the `rtrn` command.

## Open Questions

Not blocking, informational: where the PAFF-capable ffmpeg build lives
long-term (the `libx264-paff` branch was not found in the current
ffmpeg checkout) — matters for the TS cell's usefulness; the skip
message points at sapsan (#65229) until that lands.
