# Proposal

## Why

Ticket #63682 (PAFF in libx264 + `-paff` in ffmpeg, closing the RTRN
broadcast requirements — RTRN, Russian Television and Radio Broadcasting
Network, РТРС; the requirements originate in ticket #11121) lists three
DoD items; item 1 (reference config, validated once by hand against the
RTRN dump) and the encoder work are done and merged to master. DoD item
3 — regression tests against the concrete customer requirements — does
not exist: nothing in the tree checks that the encoded stream keeps
showing `Interlaced / Separated fields / Top Field First`, `Main@L3`,
`CABAC / 4 Ref Frames`, `GOP: M=4, N=28`, BT.601 colorimetry, or that
no IDR appears outside requested keyframes. One stray refactor could
silently break the customer-visible stream shape and we would only
notice at the next manual check.

## What Changes

- New `rtrn` command in `tools/test_paff.sh`: a self-contained
  regression suite encoding the RTRN profile (PAFF TFF, open GOP,
  `-bf 3 -b-adapt 0`, keyint 28, ref 4, Main@L3, ABR 2720k with VBV
  3500k/1400k and no HRD signaling, AUD, BT.601 PAL colorimetry, SAR
  16:11, 25 fps) on a synthesized interlaced clip and asserting the
  customer-visible stream properties. ("CBR 2720k" in the customer
  requirements is delivered at the container level by the muxer; in the
  elementary stream it is ABR 2720 bounded by the VBV, and HRD is
  deactivated anyway — ticket requirement 11.)
- Assertions via `mediainfo` (scan type / store method / scan order /
  profile@level / ref frames / colorimetry / range / frame rate / DAR)
  on the raw Annex-B stream, via `ffprobe` on decoded frame metadata
  (I-picture cadence N=28 from the pict_type sequence, non-B cadence
  M=4, field-AU count = 2 per frame), and via a python3 Annex-B
  NAL-type scan for the IDR discipline (ffprobe flags open-GOP
  recovery-point I frames with key_frame=1 too, so key_frame counting
  cannot distinguish IDR from recovery I; the NAL scan can: exactly one
  nal_unit_type-5 slice, which also catches a silent open-GOP to
  closed-GOP regression).
- BFF parity variant of the same encode.
- Byte-repeat cells: the reference encode run twice at `--threads 1`
  and twice at `--threads 4` must each be bit-identical — the two pairs
  cover both PAFF pair drivers (the monolithic pair driver and the
  frame-threaded pool jobs).
- Optional env-gated cell (`FFMPEG_PAFF` pointing at a PAFF-capable
  ffmpeg): runs the exact reference command line from the ticket,
  including mpegts muxing, and asserts the full MediaInfo field table
  including `Format settings, GOP: M=4, N=28` (which MediaInfo only
  computes in a container context). Skipped when the env var is unset;
  the skip message names sapsan (#65229) as the intended build source.
- No encoder code changes. `doc/paff.txt` gains a section documenting
  the suite and the profile mapping. The `all` command gains `rtrn`
  (cells skip visibly, not silently, when mediainfo or python3 is
  absent).

## Capabilities

### New Capabilities

- `rtrn-broadcast-profile`: the RTRN broadcast delivery profile as a
  verifiable contract — the parameter mapping from the customer
  requirements (all 11 from #11121 as quoted in #63682, including HRD
  deactivated and the CBR-at-container note) to x264 settings and the
  stream properties the encoded output must exhibit, plus the
  requirement that a regression suite exists and passes.

### Modified Capabilities

(none)

## Impact

- `tools/test_paff.sh`: new `rtrn` command; `all` includes it; no other
  command changes.
- `doc/paff.txt`: documentation section.
- External tools required: `mediainfo`, `ffprobe` and `python3` on PATH
  (ffprobe is already used elsewhere in the suite); the command skips
  with a clear message when mediainfo or python3 is absent. CI
  (`test_paff_ci.sh`) is untouched — it deliberately stays
  mediainfo/ffmpeg-free.
- Verified against a real encode during change review (MediaInfo 24.11,
  ffprobe 8.1.3, the current x264 binary): the full field table on the
  raw stream; the double key_frame flagging of recovery-point I;
  byte-identity at threads 1/4/auto; that the system ffmpeg cannot
  remux raw PAFF into TS (naive copy, `+genpts`, `-framerate`, bare
  copy — all rejected by the mpegts muxer over timestamp-less field
  AUs), hence the env-gated TS cell instead of a hard dependency.
