#!/bin/bash
# PAFF CI smoke test -- JM-free, ffmpeg-free.
#
# The full PAFF round-trip (tools/test_paff.sh) needs the JM reference decoder
# (ldecod), which is not available in the CI images.  This script covers the
# part that CAN run in CI with only the x264 binary and python3:
#
#   - several PAFF configs encode without error and produce non-empty output
#     (CRF TFF/BFF, B-frames + pyramid, CBR + VBV, CBR+B, 2-pass, weightp);
#   - the 14-config B-field regression matrix (tools/paff_matrix.sh) encodes
#     without error (encode-only; the byte-exact round-trip is test_paff.sh);
#   - PAFF is deterministic at a fixed thread count (two --threads 4 runs
#     are byte-identical);
#   - an --nal-hrd cbr stream is CPB-compliant at field granularity per the
#     independent Annex C simulator (tools/check_hrd.py);
#   - sliced-threads PAFF cells (paff-sliced-threads): N=4 encode with the
#     expected 4 slices per field picture, the field-row thread-count clamp,
#     fixed-N byte repeatability, and a sliced CBR+VBV CPB check;
#   - unsupported combinations are rejected at validation (non-zero exit):
#     PAFF+sliced with explicit sub-slicing, PAFF+slice-max-mbs/--slices at
#     any thread count, --pulldown, --avcintra-class.
#
# It uses raw YUV input (--input-res) and raw Annex-B output, so it needs no
# lavf/swscale linkage and no ffmpeg.  The clip is synthesized with python3.
#
# Usage: tools/test_paff_ci.sh
# Env:   X264  path to the x264 CLI binary  (default: ./x264)
# Exit:  0 if all checks pass, 1 otherwise.

set -u

cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
X264=${X264:-./x264}

WIDTH=176
HEIGHT=128          # multiple of 32 so each field is a whole number of MB rows
FRAMES=30
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
die()  { echo "ERROR: $*" >&2; exit 2; }

[ -x "$X264" ] || die "x264 binary not found/executable: $X264"
command -v python3 >/dev/null || die "python3 not found in PATH"

# B-field regression matrix (shared with tools/test_paff.sh).
# shellcheck source=paff_matrix.sh
. "$REPO_ROOT/tools/paff_matrix.sh"

CLIP="$WORKDIR/in.yuv"
python3 - "$CLIP" "$WIDTH" "$HEIGHT" "$FRAMES" <<'PY' || die "clip generation failed"
import sys
path, w, h, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
frame = w*h*3//2
data = bytearray()
for f in range(n):
    for i in range(frame):
        data.append((i*7 + f*13 + (i//w)*5) & 0xff)
with open(path, "wb") as fh:
    fh.write(data)
PY

COMMON=(--input-res ${WIDTH}x${HEIGHT} --fps 25)

# Encode a config; on success the output must be non-empty.
encode_ok() {
    desc=$1; shift
    out=$1; shift
    if "$X264" "$CLIP" "${COMMON[@]}" -o "$out" "$@" >"$WORKDIR/log" 2>&1; then
        if [ -s "$out" ]; then ok "$desc"; else bad "$desc (empty output)"; fi
    else
        bad "$desc (x264 failed)"; tail -n 4 "$WORKDIR/log" >&2
    fi
}

# Encode must FAIL (validation rejection).
encode_fail() {
    desc=$1; shift
    if "$X264" "$CLIP" "${COMMON[@]}" -o "$WORKDIR/reject.264" "$@" >"$WORKDIR/log" 2>&1; then
        bad "$desc (expected failure, got success)"
    else
        ok "$desc (rejected as expected)"
    fi
}

echo "== PAFF CI smoke: ${WIDTH}x${HEIGHT} ${FRAMES}f =="

# 1. Encode matrix (all must succeed + non-empty).
encode_ok "CRF TFF"                  "$WORKDIR/crf_tff.264"  --paff --tff --crf 23
encode_ok "CRF BFF"                  "$WORKDIR/crf_bff.264"  --paff --bff --crf 23
encode_ok "I-only keyint 1"           "$WORKDIR/ki1.264"      --paff --tff --crf 23 --keyint 1 --bframes 0
encode_ok "B-frames + pyramid"       "$WORKDIR/bf.264"       --paff --tff --crf 23 --bframes 3 --b-pyramid normal
encode_ok "CBR + VBV"                "$WORKDIR/cbr.264"      --paff --tff --bframes 0 --bitrate 300 --vbv-maxrate 300 --vbv-bufsize 300
encode_ok "weightp 2"                "$WORKDIR/w2.264"       --paff --tff --crf 23 --weightp 2

# 1b. SPS sanity for the keyint-1 stream: the I-only num_ref_frames = 0
#     carve-out in set.c is progressive-only.  Under PAFF every keyframe
#     pair's second field is a reference P field, so num_ref_frames must
#     stay >= 1; signalling 0 sized vendor DPBs to zero and broke NVDEC-
#     CUVID and AMD VCN decode (task 8.3 root cause).
if python3 - "$WORKDIR/ki1.264" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
i = data.find(b'\x00\x00\x01') + 3
while i < len(data) and (data[i] & 0x1f) != 7:
    j = data.find(b'\x00\x00\x01', i)
    if j < 0: sys.exit(1)
    i = j + 3
body = bytearray(data[i+1:])
k = body.find(b'\x00\x00\x01')
if k >= 0: del body[k:]
class R:
    def __init__(s): s.b = bytes(body); s.p = 0
    def u(s, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((s.b[s.p >> 3] >> (7 - (s.p & 7))) & 1); s.p += 1
        return v
    def ue(s):
        z = 0
        while s.u(1) == 0: z += 1
        return (1 << z) - 1 + (s.u(z) if z else 0)
r = R(); prof = r.u(8); r.u(8); r.u(8); r.ue()
if prof in (100,110,122,244,44,83,86,118,128,138,139,134,135):
    if r.ue() == 3: r.u(1)
    r.ue(); r.ue(); r.u(1); r.u(1)
r.ue()                  # log2_max_frame_num_minus4
if r.ue() == 0:         # poc_type; type 0 carries log2_max_poc_lsb_minus4
    r.ue()
num_ref = r.ue()
sys.exit(0 if num_ref >= 1 else 1)
PY
then ok "SPS num_ref_frames >= 1 under PAFF keyint 1"
else bad "SPS num_ref_frames == 0 under PAFF keyint 1 (regression)"
fi

# 2-pass (needs the first pass to write stats).
if "$X264" "$CLIP" "${COMMON[@]}" -o /dev/null --paff --tff --bitrate 300 \
        --pass 1 --slow-firstpass --stats "$WORKDIR/p.stats" >"$WORKDIR/log" 2>&1; then
    encode_ok "2-pass" "$WORKDIR/2p.264" --paff --tff --bitrate 300 \
        --pass 2 --slow-firstpass --stats "$WORKDIR/p.stats"
else
    bad "2-pass (pass 1 failed)"; tail -n 4 "$WORKDIR/log" >&2
fi

# 2. Determinism: two --threads 4 runs must be byte-identical.  Threaded
#    output intentionally differs from --threads 1 (the per-reference-row
#    vertical MV-range clamp, same as progressive frame threading), so the
#    check is repeatability at a fixed thread count, not cross-count equality.
"$X264" "$CLIP" "${COMMON[@]}" -o "$WORKDIR/det4a.264" --paff --tff --crf 23 --threads 4 >"$WORKDIR/log" 2>&1 \
    || die "threads=4 encode failed"
"$X264" "$CLIP" "${COMMON[@]}" -o "$WORKDIR/det4b.264" --paff --tff --crf 23 --threads 4 >"$WORKDIR/log" 2>&1 \
    || die "threads=4 encode failed"
if cmp -s "$WORKDIR/det4a.264" "$WORKDIR/det4b.264"; then ok "determinism: --threads 4 repeatable"
else bad "determinism: --threads 4 not repeatable"; fi

# 3. HRD: --nal-hrd cbr stream must be CPB-compliant at field granularity.
HRD="$WORKDIR/hrd.264"
"$X264" "$CLIP" "${COMMON[@]}" -o "$HRD" --paff --tff --bframes 0 \
    --bitrate 300 --vbv-maxrate 300 --vbv-bufsize 300 --nal-hrd cbr >"$WORKDIR/log" 2>&1 \
    || die "nal-hrd cbr encode failed"
if python3 "$REPO_ROOT/tools/check_hrd.py" "$HRD" >"$WORKDIR/hrd.log" 2>&1; then
    ok "Annex C CPB check (field granularity)"; sed 's/^/    /' "$WORKDIR/hrd.log"
else
    bad "Annex C CPB check"; cat "$WORKDIR/hrd.log" >&2
fi

# 4. Unsupported combinations must be rejected.
#    paff-sliced-threads: sliced threads are now ACCEPTED under PAFF; the
#    rejections are the explicit sub-slicing combinations (band = the only
#    slice shape) and PAFF + slice-max-mbs/--slices at any thread count
#    (previously silent empty output).
encode_fail "--paff --sliced-threads --slice-max-size"   --paff --sliced-threads --threads 2 --slice-max-size 1500
encode_fail "--paff --sliced-threads --slice-max-mbs"   --paff --sliced-threads --threads 2 --slice-max-mbs 30
encode_fail "--paff --sliced-threads --slices"          --paff --sliced-threads --threads 2 --slices 2
encode_fail "--paff --slice-max-mbs (any threads)"      --paff --slice-max-mbs 30
encode_fail "--paff --slices (any threads)"             --paff --slices 2
encode_fail "--paff --pulldown"         --paff --pulldown 1
encode_fail "--paff --avcintra-class"   --paff --avcintra-class 50

# 5. B-field matrix (14 configs from paff-b-frames/checkpoint-4.1-4.3.md):
#    encode-only smoke -- CI has no JM/ffmpeg oracle, so this only checks that
#    each config encodes without error and produces non-empty output.  That is
#    enough to catch the kind of PAFF segfault the matrix was created for
#    (--ref 1, --b-pyramid --ref 2 eviction).  The full byte-exact JM
#    round-trip of the same configs is tools/test_paff.sh `matrix`.
i=0
for entry in "${PAFF_MATRIX[@]}"; do
    name=${entry%%|*}
    opts=${entry#*|}
    encode_ok "matrix/$name" "$WORKDIR/mx_$((i++)).264" --paff $opts
done

# 6. Sliced-threads PAFF (paff-sliced-threads 5.5): encode-only CI cells.
#    Sliced bands need >= 4 field MB rows per thread, so these run on a
#    dedicated 352x512 clip (16 field rows -> field cap 4); the main clip
#    (128 lines) clamps sliced PAFF to one thread and exercises nothing.
SL_WIDTH=352 SL_HEIGHT=512
SL_CLIP="$WORKDIR/in_sliced.yuv"
python3 - "$SL_CLIP" "$SL_WIDTH" "$SL_HEIGHT" "$FRAMES" <<'PY' || die "sliced clip generation failed"
import sys
path, w, h, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
frame = w*h*3//2
data = bytearray()
for f in range(n):
    for i in range(frame):
        data.append((i*11 + f*17 + (i//w)*3) & 0xff)
with open(path, "wb") as fh:
    fh.write(data)
PY
SL_COMMON=(--input-res ${SL_WIDTH}x${SL_HEIGHT} --fps 25)

# 6a. encode + multi-slice geometry: N=4 must produce exactly N slices per
#     field picture (2*FRAMES fields -> 2*FRAMES*N slice NALs).
SL_OUT="$WORKDIR/sliced_n4.264"
if "$X264" "$SL_CLIP" "${SL_COMMON[@]}" -o "$SL_OUT" --paff --tff --sliced-threads \
        --threads 4 --crf 23 >"$WORKDIR/log" 2>&1 && [ -s "$SL_OUT" ] \
   && python3 - "$SL_OUT" $((FRAMES*2*4)) <<'PY'
import re, sys
data = open(sys.argv[1], 'rb').read()
nal_types = [data[m.start()+3] & 0x1f for m in re.finditer(b'\x00\x00\x01', data)]
slices = sum(1 for t in nal_types if t in (1, 5))
sys.exit(0 if slices == int(sys.argv[2]) else 1)
PY
then ok "sliced N=4: encode + $((FRAMES*2*4)) slice NALs (4 per field)"
else bad "sliced N=4: encode/slice-count check failed"; fi

# 6b. thread-count clamp: 8 threads over 16 field rows reduces to the cap
#     (4) with the warning that makes the clamp observable.
if "$X264" "$SL_CLIP" "${SL_COMMON[@]}" -o /dev/null --paff --tff --sliced-threads \
        --threads 8 --crf 23 --frames 4 >"$WORKDIR/log" 2>&1 \
   && grep -q "reducing to 4" "$WORKDIR/log"; then
    ok "sliced clamp: --threads 8 reduces to the field cap (4)"
else bad "sliced clamp: not clamped/warned"; fi

# 6c. determinism: two N=4 runs byte-identical (non-VBV modes are
#     byte-repeatable; CBR+VBV inherits the progressive sliced exception).
"$X264" "$SL_CLIP" "${SL_COMMON[@]}" -o "$WORKDIR/sdet_a.264" --paff --tff \
    --sliced-threads --threads 4 --crf 23 >"$WORKDIR/log" 2>&1 \
    || die "sliced determinism encode A failed"
"$X264" "$SL_CLIP" "${SL_COMMON[@]}" -o "$WORKDIR/sdet_b.264" --paff --tff \
    --sliced-threads --threads 4 --crf 23 >"$WORKDIR/log" 2>&1 \
    || die "sliced determinism encode B failed"
if cmp -s "$WORKDIR/sdet_a.264" "$WORKDIR/sdet_b.264"; then ok "sliced determinism: N=4 repeatable"
else bad "sliced determinism: N=4 not repeatable"; fi

# 6d. HRD: sliced CBR+VBV stream must be CPB-compliant per field AU.
SL_HRD="$WORKDIR/shrd.264"
"$X264" "$SL_CLIP" "${SL_COMMON[@]}" -o "$SL_HRD" --paff --tff --sliced-threads \
    --threads 4 --bframes 0 --bitrate 300 --vbv-maxrate 300 --vbv-bufsize 300 \
    --nal-hrd cbr >"$WORKDIR/log" 2>&1 || die "sliced nal-hrd cbr encode failed"
if python3 "$REPO_ROOT/tools/check_hrd.py" "$SL_HRD" >"$WORKDIR/shrd.log" 2>&1; then
    ok "sliced Annex C CPB check (field granularity)"
else bad "sliced Annex C CPB check"; cat "$WORKDIR/shrd.log" >&2; fi

echo
echo "PAFF CI smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
