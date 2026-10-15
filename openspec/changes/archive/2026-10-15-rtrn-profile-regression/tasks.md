# Tasks

## 1. Clip synthesis and reference encode

- [x] 1.1 Add the `rtrn` command skeleton to `tools/test_paff.sh` following the existing command conventions (usage block entry, WORKDIR handling, skip-if-tool-missing semantics for mediainfo/ffprobe/python3); verify `tools/test_paff.sh rtrn` runs and reports "not implemented" cleanly or such placeholder output
- [x] 1.2 Implement runtime synthesis of the 56-frame 720x576 interlaced clip in python3 (even/odd rows carry separate motion phases, scene-cut-free, deterministic, geometry pinned — WIDTH/HEIGHT/FRAMES overrides ignored); verify the clip encodes and the frame count matches
- [x] 1.3 Implement the reference-profile encode (PAFF TFF, open GOP, bf 3, b-adapt 0, keyint 28, ref 4, Main@L3, ABR 2720k, VBV 3500k/1400k, no `--nal-hrd` — ticket requirement 11, AUD, BT.601 PAL colorimetry, limited range, SAR 16:11, fps 25, raw Annex-B output); verify the encode succeeds and `mediainfo` on the output shows `Separated fields`

## 2. Field-table and stream-structure assertions

- [x] 2.1 Assert the mediainfo field table on the TFF raw stream (scan type Interlaced, store method Separated fields, scan order TFF, Main@L3, CABAC / 4 Ref Frames, BT.601 PAL primaries, BT.470 B/G transfer+matrix, Limited range, 25.000 fps, DAR 16:9) via exact-string compare of the text output; verify a deliberately wrong expectation fails the cell
- [x] 2.2 Assert GOP geometry: from `ffprobe -show_frames` — I-picture cadence of 28 frames and non-B cadence of 4 frames (M=4) from pict_type, key_frame=1 on the first frame, packet count = 2x frame count; IDR discipline from a python3 Annex-B NAL-type scan (exactly one nal_unit_type-5 slice — ffprobe cannot do this, it flags recovery-point I with key_frame=1 too); verify against the encoded stream and verify the negative path: an encode without `--open-gop` (second IDR) fails the NAL-scan cell
- [x] 2.3 Add the BFF variant cell (same encode with `--bff`); verify scan order reads `Bottom Field First` and all other assertions hold
- [x] 2.4 Add the byte-repeat cells: two encodes at `--threads 1` and two at `--threads 4` (both PAFF pair drivers — monolithic and frame-threaded), `cmp` within each pair; verify both pairs pass

## 3. Optional TS-level cell

- [x] 3.1 Implement the `FFMPEG_PAFF`-gated cell: full reference command line through the PAFF-capable ffmpeg (including `-vf setparams`, mpegts muxing, mp2 audio omitted or silent-source as the environment allows), then mediainfo on the TS asserting `Format settings, GOP: M=4, N=28` plus the field table; verify the skip path prints the reason and names sapsan (#65229) as the intended build source when the env var is unset, and (if such a build is at hand) the full path passes

## 4. Documentation and integration

- [x] 4.1 Document the RTRN profile mapping in `doc/paff.txt` (each customer requirement -> x264 option) covering all 11 requirements from #11121 as quoted in #63682, including row 11 (HRD deactivated -> default, no `--nal-hrd`), the note that "CBR 2720k" is container-level CBR (the ES is ABR+VBV; `--nal-hrd cbr` is impossible at bitrate != vbv-maxrate), and row 1 (IDR only at SCTE marks -> open GOP keeps the default stream IDR-free; SCTE-driven forced keyframes are an API/sapsan concern, the suite checks the default path), plus the min-keyint clamp note and the raw-PAFF remux limitation of system ffmpeg; verify the mapping table covers all 11 rows
- [x] 4.2 Update the `tools/test_paff.sh` usage header so `rtrn` is described like the other commands and `all` lists it; verify `tools/test_paff.sh` with no arguments shows `rtrn` in `all`
- [x] 4.3 Full run: `tools/test_paff.sh rtrn` passes end-to-end on a clean workdir (mediainfo/ffprobe/python3 present, TS cell skipped visibly without FFMPEG_PAFF); record the run in the ticket
