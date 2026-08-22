#!/bin/bash
# PAFF hardware-decoder interop smoke test (openspec paff-sei-hrd-rc, 8.3).
#
# Encodes the 8.1 PAFF stream set (paff + 14-config matrix + rc + one
# --nal-hrd cbr stream) with this tree's x264, then decodes EVERY stream
# with a hardware H.264 decoder and checks:
#   - decode exits 0 with zero warnings/errors at -v warning;
#   - the decoder emits exactly 25 frames (= 50 fields: no dropped,
#     duplicated or merged field pictures);
#   - pixel cross-check (default for hw backends): the decoded output is
#     bit-identical to ffmpeg's software H.264 decoder in NV12.  H.264
#     decoding is deterministic, so a hardware decoder that disagrees is
#     mishandling the PAFF field pictures (field pairing, complementary
#     references, per-field deblocking) -- exactly what 8.3 must catch.
#
# Backends (first argument, default "soft"):
#   soft   ffmpeg software decoder -- harness dry-run, no hardware needed
#   cuvid  NVIDIA NVDEC via NVIDIA's own parser (-c:v h264_cuvid; ffmpeg
#          built with ffnvcodec headers)
#   nvdec  NVIDIA NVDEC driven by ffmpeg's h264 decoder (-hwaccel cuda) --
#          same silicon, spec-conformant DPB/field pairing in libavcodec
#   qsv    Intel QSV (-c:v h264_qsv; Intel GPU + libvpl/libmfx build)
#   vaapi  VAAPI hwaccel (e.g. AMD VCN via radeonsi; set DEVICE)
#
# NOTE on gate 1's output sink: decoding to a rawvideo sink instead of
# "-f null" avoids the null MUXER's "non monotonically increasing dts"
# complaint, which is a container-timestamp artifact of raw Annex-B input
# (no real timestamps), not a decoder error.  Frame-count and pixel-md5
# gates carry the actual correctness.
#
# Usage: tools/test_paff_hw.sh [soft|cuvid|nvdec|qsv|vaapi] [--md5|--no-md5]
# Env:   X264     x264 CLI binary                (default: ./x264)
#        FFMPEG   ffmpeg binary                  (default: ffmpeg)
#        FFPROBE  ffprobe binary                 (default: ffprobe)
#        WORKDIR  scratch dir for clips/streams  (default: /tmp/paff_hw)
#        DEVICE   vaapi render node              (default: /dev/dri/renderD129)
#
# NOTE: rebuild x264 (make) before running if encoder sources changed;
# streams are re-encoded on every run so they always match the current
# binary.

set -u

cd "$(dirname "$0")/.."
REPO_ROOT=$PWD

# Same stream set as tools/test_paff.sh (task 8.1) -- keep in sync.
# shellcheck source=paff_matrix.sh
. "$REPO_ROOT/tools/paff_matrix.sh"

X264=${X264:-./x264}
FFMPEG=${FFMPEG:-ffmpeg}
FFPROBE=${FFPROBE:-ffprobe}
WORKDIR=${WORKDIR:-/tmp/paff_hw}
DEVICE=${DEVICE:-/dev/dri/renderD129}

WIDTH=176
HEIGHT=144
FRAMES=25

BACKEND=soft
MD5_POLICY=auto          # auto: on for hw backends, off for soft
for arg in "$@"; do
    case $arg in
        soft|cuvid|nvdec|qsv|vaapi) BACKEND=$arg ;;
        --md5)                MD5_POLICY=on ;;
        --no-md5)             MD5_POLICY=off ;;
        *) echo "ERROR: unknown argument: $arg" >&2
           echo "usage: $0 [soft|cuvid|qsv|vaapi] [--md5|--no-md5]" >&2
           exit 2 ;;
    esac
done

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
die()  { echo "ERROR: $*" >&2; exit 2; }

[ -x "$X264" ]       || die "x264 binary not found/executable: $X264"
command -v "$FFMPEG"  >/dev/null || die "ffmpeg not found: $FFMPEG"
command -v "$FFPROBE" >/dev/null || die "ffprobe not found: $FFPROBE"
mkdir -p "$WORKDIR"

# Per-backend decoder options and the -vf that normalizes decoded output
# to NV12 for the md5 cross-check (hwdownload only where the decoder
# outputs hardware frames).
case $BACKEND in
soft)   DEC_OPTS=(-c:v h264);                                  MD5_VF=format=nv12 ;;
cuvid)  DEC_OPTS=(-c:v h264_cuvid);                            MD5_VF=format=nv12 ;;
nvdec)  DEC_OPTS=(-hwaccel cuda -c:v h264);                    MD5_VF=format=nv12 ;;
qsv)    DEC_OPTS=(-c:v h264_qsv);                              MD5_VF=format=nv12 ;;
vaapi)  DEC_OPTS=(-hwaccel vaapi -hwaccel_device "$DEVICE" -hwaccel_output_format vaapi -c:v h264)
        MD5_VF=hwdownload,format=nv12 ;;
esac

verify_backend() {
    local have
    case $BACKEND in
    cuvid)
        have=$("$FFMPEG" -hide_banner -decoders 2>/dev/null | grep -c h264_cuvid)
        [ "$have" -ge 1 ] || die "this ffmpeg has no h264_cuvid decoder (build it against ffnvcodec/nv-codec-headers)" ;;
    nvdec)
        "$FFMPEG" -hide_banner -hwaccels 2>/dev/null | grep -q cuda \
            || die "this ffmpeg has no cuda hwaccel (build it against ffnvcodec/nv-codec-headers)" ;;
    qsv)
        have=$("$FFMPEG" -hide_banner -decoders 2>/dev/null | grep -c h264_qsv)
        [ "$have" -ge 1 ] || die "this ffmpeg has no h264_qsv decoder (build it with --enable-libvpl or --enable-libmfx)" ;;
    vaapi)
        "$FFMPEG" -hide_banner -hwaccels 2>/dev/null | grep -q vaapi \
            || die "this ffmpeg has no vaapi hwaccel (build it with --enable-vaapi)"
        [ -e "$DEVICE" ] || die "vaapi render node not found: $DEVICE (set DEVICE=)" ;;
    esac
}
verify_backend

[ "$MD5_POLICY" = auto ] && [ "$BACKEND" != soft ] && MD5_POLICY=on
[ "$MD5_POLICY" = auto ] && MD5_POLICY=off

# Deterministic interlaced clip, identical to tools/test_paff.sh's
# make_clip (progressive 50 fps test pattern, tinterlace -> 25 interlaced
# frames with real field motion).
CLIP=$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv
if [ ! -f "$CLIP" ]; then
    "$FFMPEG" -y -loglevel error \
        -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=50:duration=1" \
        -vf tinterlace -frames:v $FRAMES -pix_fmt yuv420p "$CLIP" \
        || die "clip synthesis failed"
fi

encode() { # name opts...
    local name=$1; shift
    "$X264" "$CLIP" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads 1 -o "$WORKDIR/$name.264" "$@" >"$WORKDIR/$name.enc.log" 2>&1 \
        || die "$name: x264 encode failed (see $WORKDIR/$name.enc.log)"
}

encode_2pass() { # name opts...
    local name=$1; shift
    local stats=$WORKDIR/$name.stats
    "$X264" "$CLIP" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads 1 --pass 1 --slow-firstpass --stats "$stats" \
        -o /dev/null "$@" >"$WORKDIR/$name.enc.log" 2>&1 \
        || die "$name: x264 pass 1 failed (see $WORKDIR/$name.enc.log)"
    "$X264" "$CLIP" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads 1 --pass 2 --slow-firstpass --stats "$stats" \
        -o "$WORKDIR/$name.264" "$@" >>"$WORKDIR/$name.enc.log" 2>&1 \
        || die "$name: x264 pass 2 failed (see $WORKDIR/$name.enc.log)"
}

# Decode one stream through the backend and apply the 8.3 gates.
hw_check() { # name
    local name=$1
    local stream=$WORKDIR/$name.264
    local err=$WORKDIR/$name.hw.err

    [ -s "$stream" ] || { bad "$name: stream missing/empty"; return; }

    # Gate 1: clean decode (exit 0, no warning/error output at all).
    # Raw sink (not "-f null"): see the note on gate 1's output sink above.
    if ! "$FFMPEG" -v warning "${DEC_OPTS[@]}" -i "$stream" \
            -vf "$MD5_VF" -f rawvideo -y /dev/null 2>"$err"; then
        bad "$name: decode failed"
        sed 's/^/    /' "$err"
        return
    fi
    if [ -s "$err" ]; then
        bad "$name: decoder emitted warnings/errors"
        sed 's/^/    /' "$err"
        return
    fi

    # Gate 2: exact frame count (25 frames = 50 fields).
    local n
    n=$("$FFPROBE" -v error -count_frames -select_streams v:0 \
        -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$stream")
    if [ "$n" != "$FRAMES" ]; then
        bad "$name: decoded $n frames, expected $FRAMES"
        return
    fi

    # Gate 3: pixels bit-identical to the software decoder (NV12).
    if [ "$MD5_POLICY" = on ]; then
        local sw hw
        sw=$("$FFMPEG" -v error -i "$stream" -vf format=nv12 -f md5 - 2>/dev/null)
        hw=$("$FFMPEG" -v error "${DEC_OPTS[@]}" -i "$stream" \
             -vf "$MD5_VF" -f md5 - 2>"$err")
        if [ -s "$err" ] || [ -z "$hw" ]; then
            bad "$name: md5 decode failed"
            sed 's/^/    /' "$err"
            return
        fi
        if [ "$sw" != "$hw" ]; then
            bad "$name: hw pixels differ from software decoder (sw $sw vs hw $hw)"
            return
        fi
    fi

    ok "$name"
}

echo "== PAFF hardware interop (8.3): backend=$BACKEND md5=$MD5_POLICY =="
"$FFMPEG" -version | head -1 | sed 's/^/ffmpeg: /'

# --- task 8.1 stream set, verbatim from tools/test_paff.sh ---------------
encode paff_tff_intra --paff --tff --qp 20 --keyint 1 --bframes 0 --weightp 0
encode paff_tff_ip    --paff --tff --qp 20 --bframes 0 --weightp 0
encode paff_bff_ip    --paff --bff --qp 20 --bframes 0 --weightp 0
encode paff_tff_ref4  --paff --tff --qp 20 --bframes 0 --weightp 0 --ref 4
encode paff_bff_ref4  --paff --bff --qp 20 --bframes 0 --weightp 0 --ref 4
encode paff_tff_ref2_evict --paff --tff --qp 20 --bframes 0 --weightp 0 --ref 2
encode paff_bff_ref2_evict --paff --bff --qp 20 --bframes 0 --weightp 0 --ref 2
encode paff_tff_ref8_16fld --paff --tff --qp 20 --bframes 0 --weightp 0 --ref 8
encode paff_bff_ref8_16fld --paff --bff --qp 20 --bframes 0 --weightp 0 --ref 8
encode paff_tff_crf   --paff --tff

for entry in "${PAFF_MATRIX[@]}"; do
    encode "${entry%%|*}" --paff ${entry#*|}
done

encode    rc_cbr_tff --paff --tff --bframes 0 --bitrate 300 --vbv-maxrate 300 --vbv-bufsize 300
encode    rc_cbr_bff --paff --bff --bframes 0 --bitrate 300 --vbv-maxrate 300 --vbv-bufsize 300
encode_2pass rc_2p_tff --paff --tff --bframes 0 --bitrate 300
encode_2pass rc_2p_bff --paff --bff --bframes 0 --bitrate 300

# SEI-heavy stream (8.2 flavor): buffering_period + pic_timing per field AU.
encode hrd_tff --paff --tff --bframes 0 --bitrate 300 \
    --vbv-maxrate 300 --vbv-bufsize 300 --nal-hrd cbr

# --- paff-sliced-threads (5.4): multi-slice field-picture streams --------
# Sliced PAFF needs >= 4 field MB rows per thread, so these run on a 576i
# clip (the default 144-line clip clamps to one thread and is not
# multi-slice).  TFF+BFF, I+P+B and CBR+VBV with filler (maxrate == bitrate
# forces filler NALs), N=4 -> 4 slices per field picture.
SL_WIDTH=704
SL_HEIGHT=576
SL_CLIP=$WORKDIR/clip_${SL_WIDTH}x${SL_HEIGHT}.yuv
if [ ! -f "$SL_CLIP" ]; then
    "$FFMPEG" -y -loglevel error \
        -f lavfi -i "testsrc2=size=${SL_WIDTH}x${SL_HEIGHT}:rate=50:duration=1" \
        -vf tinterlace -frames:v $FRAMES -pix_fmt yuv420p "$SL_CLIP" \
        || die "576i clip synthesis failed"
fi

sliced_encode() { # name opts...
    local name=$1; shift
    "$X264" "$SL_CLIP" --input-res ${SL_WIDTH}x${SL_HEIGHT} --frames $FRAMES \
        --threads 4 --sliced-threads -o "$WORKDIR/$name.264" "$@" >"$WORKDIR/$name.enc.log" 2>&1 \
        || die "$name: x264 encode failed (see $WORKDIR/$name.enc.log)"
}

sliced_encode sl_tff_intra --paff --tff --qp 20 --keyint 1 --bframes 0 --weightp 0
sliced_encode sl_tff_ipb   --paff --tff --crf 23 --bframes 3
sliced_encode sl_bff_ipb   --paff --bff --crf 23 --bframes 3
# filler-flavoured CBR: a high target with a QP floor keeps the encoder
# underspending, so update_vbv pads the field AUs with filler NALs
# (23+ of them on the deterministic clip) -- decode must ignore them.
sliced_encode sl_cbr_filler --paff --tff --bframes 0 --bitrate 5000 \
    --vbv-maxrate 5000 --vbv-bufsize 5000 --qpmin 35 --nal-hrd cbr

# --- run the gate over every stream ---------------------------------------
for entry in "${PAFF_MATRIX[@]}"; do
    hw_check "${entry%%|*}"
done
for name in paff_tff_intra paff_tff_ip paff_bff_ip paff_tff_ref4 paff_bff_ref4 \
            paff_tff_ref2_evict paff_bff_ref2_evict paff_tff_ref8_16fld \
            paff_bff_ref8_16fld paff_tff_crf \
            rc_cbr_tff rc_cbr_bff rc_2p_tff rc_2p_bff hrd_tff; do
    hw_check "$name"
done
for name in sl_tff_intra sl_tff_ipb sl_bff_ipb sl_cbr_filler; do
    hw_check "$name"
done

echo "---"
echo "backend: $BACKEND, passed: $PASS, failed: $FAIL (streams in $WORKDIR)"
[ $FAIL -eq 0 ]
