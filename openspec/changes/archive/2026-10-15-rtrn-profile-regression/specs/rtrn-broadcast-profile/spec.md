# rtrn-broadcast-profile Specification

## Purpose

Defines the RTRN broadcast delivery profile — the H.264 stream shape the
RTRN customer (Russian Television and Radio Broadcasting Network, РТРС;
requirements from ticket #11121, profile from ticket #63682) requires
(field pictures, open GOP, fixed GOP geometry, Main@L3, BT.601
colorimetry) — as a verifiable contract, and requires a regression
suite that checks an encoded stream against it.

## ADDED Requirements

### Requirement: RTRN profile parameter mapping

The project SHALL document the RTRN parameter set (the "RTRN profile")
that satisfies the customer requirements: PAFF field pictures with TFF
dominance, open GOP (no IDR except at stream start or at explicitly
requested keyframes), 3 B-frames with adaptive decision off, keyframe
interval 28, 4 reference frames, Main profile at Level 3.0, ABR 2720
kbit/s bounded by VBV (maxrate 3500 kbit/s, bufsize 1400 kbit/s) with
no HRD signaling (HRD deactivated), AUD units on, BT.601 PAL
colorimetry (primaries, transfer, matrix), limited range, SAR 16:11,
25 fps.

#### Scenario: Mapping documented

- **WHEN** a reader opens the PAFF documentation
- **THEN** the RTRN profile is documented with each of the 11 customer
  requirements mapped to the x264 option that satisfies it, including
  the notes that `--min-keyint 28` is clamped by the encoder to
  `keyint/2+1`, that "CBR 2720 kbit/s" is container-level CBR (the
  elementary stream is ABR bounded by the VBV; `--nal-hrd cbr` is
  impossible at bitrate != vbv-maxrate and HRD is deactivated anyway),
  and that IDR at SCTE marks is an API-level concern (forced
  keyframes) while open GOP keeps the default stream IDR-free

### Requirement: MediaInfo-visible stream properties

A stream encoded with the RTRN profile SHALL present the following
properties to MediaInfo on the raw Annex-B stream: scan type
`Interlaced`, scan type store method `Separated fields`, scan order
`Top Field First` (or `Bottom Field First` for the BFF variant), format
profile `Main@L3`, `CABAC / 4 Ref Frames`, color primaries `BT.601 PAL`,
transfer characteristics and matrix coefficients `BT.470 System B/G`,
limited color range, frame rate 25.000 fps, display aspect ratio 16:9.

#### Scenario: TFF stream passes the field table

- **WHEN** the regression suite encodes the RTRN profile with TFF
  dominance and inspects the output with mediainfo
- **THEN** every property above matches exactly

#### Scenario: BFF variant passes

- **WHEN** the suite encodes the same profile with BFF dominance
- **THEN** the scan order reads `Bottom Field First` and all other
  properties match

### Requirement: GOP geometry and keyframe discipline

A stream encoded with the RTRN profile on scene-cut-free content SHALL
exhibit, per decoded frame: exactly one IDR (the stream start), recovery
(non-IDR I) keyframes at a cadence of 28 frames, and a picture-type
cadence of one non-B picture per 4 frames (`I B B B P` repetition).
Every decoded frame SHALL consist of exactly two field access units.

#### Scenario: GOP geometry verified from stream metadata

- **WHEN** the suite inspects the encoded stream with ffprobe and scans
  the Annex-B NAL unit types
- **THEN** the pict_type sequence matches the cadence above over at
  least two GOPs, the first frame is a keyframe, the NAL scan finds
  exactly one IDR slice (nal_unit_type 5), and the ffprobe packet count
  is twice the frame count

#### Scenario: Closed-GOP regression caught

- **WHEN** the encoder stops honouring open GOP (the mid-GOP recovery I
  becomes an IDR)
- **THEN** the NAL scan finds a second IDR slice and the cell fails,
  even though the ffprobe cadence is unchanged

### Requirement: Bit-exact repeatability of the reference encode

Encoding the RTRN profile twice with identical inputs and thread count
SHALL produce byte-identical output, both at `--threads 1` (the
monolithic pair driver) and at `--threads 4` (the frame-threaded pair
driver).

#### Scenario: Byte repeat

- **WHEN** the suite runs the reference encode twice at `--threads 1`
  and twice at `--threads 4`
- **THEN** each pair of outputs is byte-identical

### Requirement: Container-level GOP reporting

When a PAFF-capable ffmpeg build is available, the suite SHALL be able
to run the full reference command line (including mpegts muxing) and
verify that MediaInfo reports `Format settings, GOP: M=4, N=28` on the
container. Without such a build the check SHALL be skipped, because
MediaInfo derives the GOP line only in a container context and the
installed system ffmpeg cannot remux raw PAFF streams (missing field-AU
timestamps).

#### Scenario: TS-level check with PAFF-capable ffmpeg

- **WHEN** the environment provides a PAFF-capable ffmpeg binary
- **THEN** the suite encodes the reference command line to mpegts and
  mediainfo reports `GOP: M=4, N=28` along with the field table of the
  MediaInfo-visible properties requirement

#### Scenario: Graceful skip

- **WHEN** no PAFF-capable ffmpeg is available
- **THEN** the TS-level check is reported as skipped — the message
  names the env var, the reason, and sapsan (#65229) as the intended
  build source — and the suite's overall result is unaffected
