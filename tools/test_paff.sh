#!/bin/bash
# PAFF round-trip test: encode with x264, decode with the JM reference
# decoder (ldecod), diff against the encoder's own reconstruction
# (--dump-yuv).  Also saves/checks bit-identical baselines for
# progressive and MBAFF encodes ("PAFF off must not change output").
#
# Test clips are synthesized from progressive sources with ffmpeg
# tinterlace at runtime; no test media is committed to git.
#
# Usage:
#   tools/test_paff.sh [command...]
#
# Commands:
#   baseline-save   encode progressive/MBAFF references, save outputs
#   baseline-check  re-encode, diff against saved baselines (bit-identical)
#   paff            PAFF round-trip tests against JM (TFF/BFF, I-only/I+P,
#                   plus a default-CRF smoke run)
#   sliced          sliced-threads PAFF cells (paff-sliced-threads 5.1):
#                   JM round-trips {TFF,BFF} x {I,I+P,I+P+B} x N in {2,4},
#                   weightp 1/2, CAVLC, band-geometry edges, CBR+VBV,
#                   2-pass, HRD, byte-repeat, field-budget assertion,
#                   mb_info API and 10-bit ffmpeg decode cells (576i clip)
#   matrix          14-config B-field matrix vs JM (tools/paff_matrix.sh):
#                   TFF/BFF x b-pyramid x ref 1-4 x direct x CABAC/CAVLC
#                   x keyint 8/24 x --no-deblock
#   rc              rate-control round-trips vs JM: CBR+VBV and 2-pass ABR,
#                   TFF and BFF
#   la_range        lookahead-range parity: the debug-logged lowres
#                   mv_range must match between --paff and progressive
#   wide_range      wide-search PAFF round-trips (1080 @ --mvrange 1024,
#                   720 @ --mvrange 512, TFF/BFF) where the field-geometry
#                   MV limits actually bind (D1)
#   motion          synthetic vertical-motion clip (large motion in both
#                   directions), default + wide range, TFF/BFF, vs JM
#   weightb         weightb quality measurement (paff-weightb design D2):
#                   CRF sweep 18/23/28/33 on a synthetic dissolve clip and
#                   a non-dissolve control, weightb on vs off, BD-rate
#                   (PSNR-Y).  Outcome: kill (0.272% < 0.5% floor,
#                   doc/paff.txt); kept for reproducibility.
#   weightb2        weightb re-measurement (paff-weightb-remeasure, design
#                   D1/D2): five clips (real-scene crossfade, dip-to-black,
#                   grained synthetic, legacy synthetic, non-dissolve
#                   control) x modes (progressive positive control, paff-tff,
#                   paff-bff) x CRF 18/23/28/33, weightb on vs off, BD-rate
#                   (PSNR-Y).  The PAFF weightb-on rows need the local
#                   validation revert documented on cmd_weightb2; the command
#                   aborts if the force-off warning shows up in an on-row log.
#   mbtree          mbtree-under-PAFF re-measurement (paff-mbtree-remeasure,
#                   design D1/D5): clips hall/relax/amv (real content,
#                   tinterlace-synthesized interlaced variants + progressive
#                   controls) x modes (prog/--interlaced/--paff) x mbtree
#                   on/off x CRF 18/23/28/33, BD-rate (PSNR-Y) via
#                   tools/bdrate.py, gates G0/Q1/Q2.  Encodes go through the
#                   x264 CLI at preset medium and DEFAULT threads, so numbers
#                   are machine-dependent; the gates carry wide margins.
#                   Clips without a source are skipped; a lavfi testsrc2
#                   smoke clip always runs (pipeline self-check only, no
#                   gates asserted).  Outcome: future-work item closed, no
#                   deficit anywhere (doc/paff.txt "Measured and closed").
#   opengop         open-GOP round-trips vs JM: non-IDR Ip keyframe pairs
#                   plus a hard-scene-cut clip whose GOP-tail B pairs MUST
#                   reference across the I pair to decode correctly
#   all             baseline-check + paff + matrix + rc + la_range
#                   + wide_range + motion + opengop (default)
#
# Environment:
#   X264      path to the x264 CLI binary      (default: ./x264)
#   LDECOD    path to the JM ldecod binary     (default: $JM_HOME/bin/ldecod.exe,
#                                                else ../JM/bin/ldecod.exe)
#   WORKDIR   scratch dir for clips/outputs    (default: /tmp/paff_test)
#   CLIP      override the input clip used by roundtrip()/roundtrip_2pass()
#             (default: $WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv; used by cmd_motion)
#   THREADS   encoder --threads for roundtrip()/roundtrip_2pass()
#             (default: 1; set to 4/8 for threaded JM round-trips.
#             la_range and wide_range ignore it -- they pin --threads 1
#             deliberately)
#   PAFF_WB_SRC_A / PAFF_WB_SRC_B
#             real-scene source clips for the weightb2 C1/C2 cells
#             (lavf-readable, >= 4 s each; C1/C2 skip when unset, C5 falls
#             back to the lavfi control recipe -- the skip/fallback is
#             recorded with the results)
#   PAFF_MB_SRC_HALL / PAFF_MB_SRC_RELAX / PAFF_MB_SRC_AMV
#             real source clips for the mbtree cells (lavf-readable; hall:
#             720p25 >= 32 s, relax: 1080p50 >= 316 s, amv: 720p29.97 >= 87 s).
#             A clip whose env var is unset or unreadable is skipped; the
#             lavfi smoke clip always runs.
#   WB2_MODES mode subset for weightb2 (default: "prog tff bff"); use
#             "prog" for the stage-1 positive control, which needs no
#             local validation revert

set -u

cd "$(dirname "$0")/.."
REPO_ROOT=$PWD

# B-field regression matrix (shared with tools/test_paff_ci.sh).
# shellcheck source=paff_matrix.sh
. "$REPO_ROOT/tools/paff_matrix.sh"

X264=${X264:-./x264}
if [ -z "${LDECOD:-}" ]; then
    if [ -n "${JM_HOME:-}" ]; then
        LDECOD=$JM_HOME/bin/ldecod.exe
    elif [ -x /tmp/JM/bin/ldecod.exe ]; then
        LDECOD=/tmp/JM/bin/ldecod.exe
    else
        LDECOD=$REPO_ROOT/../JM/bin/ldecod.exe
    fi
fi
WORKDIR=${WORKDIR:-/tmp/paff_test}

# Small, deterministic clip geometry.  Height must be a multiple of 32 for
# interlaced coding (frame cropped to whole MB pairs).
WIDTH=176
HEIGHT=144
FRAMES=25

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
die()  { echo "ERROR: $*" >&2; exit 2; }

# Args: the commands to run; JM ldecod is required unless every command is
# weightb/weightb2/mbtree (the only commands that never round-trip through
# JM).
check_tools() {
    [ -x "$X264" ]   || die "x264 binary not found/executable: $X264"
    case " $* " in
        *" baseline-save "*|*" baseline-check "*|*" paff "*|*" matrix "*|*" rc "*|*" sliced "*|*" la_range "*|*" wide_range "*|*" motion "*|*" opengop "*|*" all "*)
            [ -x "$LDECOD" ] || die "JM ldecod not found/executable: $LDECOD (set LDECOD or JM_HOME)" ;;
    esac
    command -v ffmpeg  >/dev/null || die "ffmpeg not found in PATH"
    command -v ffprobe >/dev/null || die "ffprobe not found in PATH"
}

# Synthesize a deterministic interlaced clip: progressive test pattern at
# 50 fps, tinterlace merges consecutive frame pairs -> 25 interlaced frames
# at 25 fps with real field motion.
make_clip() {
    local clip=$1
    if [ ! -f "$clip" ]; then
        ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=50:duration=1" \
            -vf tinterlace -frames:v $FRAMES -pix_fmt yuv420p "$clip" \
            || die "failed to synthesize $clip"
    fi
}

# Synthesize a deterministic vertical-motion clip: a $2x$3 window crops a
# double-height test pattern, the window's y position oscillates over the
# full crop range (sin, 1 Hz), giving large vertical motion in BOTH
# directions between consecutive fields, then the usual tinterlace merge.
# (As with make_clip, the merge doubles the height; encodes read the top
# half via --input-res.)
make_motion_clip() {
    local clip=$1 w=$2 h=$3
    if [ ! -f "$clip" ]; then
        ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=${w}x$((h*2)):rate=50:duration=1" \
            -vf "crop=${w}:${h}:0:'(ih-${h})/2+(ih-${h})/2*sin(2*PI*t)',tinterlace" \
            -frames:v $FRAMES -pix_fmt yuv420p "$clip" \
            || die "failed to synthesize $clip"
    fi
}

# Synthetic dissolve clip for the weightb quality gate (paff-weightb, design
# D2): two 50 fps progressive sources crossfaded, then tinterlace.  As with
# make_clip the merge doubles the height and the encode reads 144-line
# frames sequentially, i.e. only the first ~2 s of the xfade timeline are
# encoded -- so the fade runs 0.5..2.0 s and ~75% of the encoded frames are
# field-blended dissolve, the content implicit bipred weights exist for.
# (The height-doubling is ffmpeg 8 tinterlace behaviour; on ffmpeg <= 7 the
# merge keeps the height and the blended share drops to ~37%, but the clip
# still contains dissolve either way.)
# The non-dissolve control is the make_clip pattern at the same length.
WB_FRAMES=100
make_dissolve_clip() {
    local clip=$1
    if [ ! -f "$clip" ]; then
        ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=50:duration=4" \
            -f lavfi -i "smptehdbars=size=${WIDTH}x${HEIGHT}:rate=50:duration=4" \
            -filter_complex "xfade=transition=fade:duration=1.5:offset=0.5,tinterlace" \
            -frames:v $WB_FRAMES -pix_fmt yuv420p "$clip" \
            || die "failed to synthesize $clip"
    fi
}
make_control_clip() {
    local clip=$1
    if [ ! -f "$clip" ]; then
        ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=50:duration=4" \
            -vf tinterlace -frames:v $WB_FRAMES -pix_fmt yuv420p "$clip" \
            || die "failed to synthesize $clip"
    fi
}

# --------------------------------------------------------------------------
# weightb re-measurement clip set (paff-weightb-remeasure, design D1).
# Every clip exists in two variants holding the SAME pixels: the tinterlaced
# PAFF input (wb2_<name>_<W>x<H>.yuv) and the pre-tinterlace progressive
# stream (wb2_<name>_<W>x<H>_prog.yuv), so the progressive positive control
# and the PAFF measurement are comparable per clip.
#
#   C1  crossfade between two DISTINCT real scenes (PAFF_WB_SRC_A/B,
#       lavf-readable), trimmed to 4 s each, xfade fade 1.5 s at offset
#       0.5 s -- the blend zone t=0.5..2.0 s sits inside the coded window on
#       BOTH ffmpeg lines (ffmpeg 8's tinterlace merge doubles the height, so
#       100 coded frames cover only the first ~2 s of the timeline).  Also
#       generated at 720x576 (native interlace-broadcast geometry) for the
#       sign-agreement duplicate cell.  Skips when the env vars are unset.
#   C2  dip-to-black: source A, fade out 1.5 s, black, fade in 1.5 s.
#       Diagnostic only (weightp territory per the paff-weightb design),
#       never the stage-2 primary clip.  Skips when PAFF_WB_SRC_A is unset.
#   C3  the C4 xfade recipe plus film grain (noise=alls=10:allf=t+u, pinned
#       seed): tests the "the old clip was too clean to need weights"
#       hypothesis.
#   C4  the legacy synthetic xfade clip (make_dissolve_clip), unmodified --
#       reference cell that must reproduce the archived ~0.272%.
#   C5  non-dissolve control: source A straight when PAFF_WB_SRC_A is set,
#       else the lavfi control recipe (make_control_clip pattern); never
#       skips.  The variant used is echoed for the results file.

WB2_SRC_A=${PAFF_WB_SRC_A:-}
WB2_SRC_B=${PAFF_WB_SRC_B:-}
WB2_MODES=${WB2_MODES:-"prog tff bff"}

# mbtree re-measurement sources (paff-mbtree-remeasure, design D1).
MB_SRC_HALL=${PAFF_MB_SRC_HALL:-}
MB_SRC_RELAX=${PAFF_MB_SRC_RELAX:-}
MB_SRC_AMV=${PAFF_MB_SRC_AMV:-}

have_wb2_sources()  { [ -n "$WB2_SRC_A" ] && [ -n "$WB2_SRC_B" ] && [ -f "$WB2_SRC_A" ] && [ -f "$WB2_SRC_B" ]; }
have_wb2_source_a() { [ -n "$WB2_SRC_A" ] && [ -f "$WB2_SRC_A" ]; }

# How many progressive frames fill the $WB_FRAMES-coded-frame PAFF window:
# $WB_FRAMES when the tinterlace merge doubles the height (ffmpeg 8), twice
# that when it keeps the height (ffmpeg <= 7).  Detected empirically with a
# tiny probe -- version strings are unreliable across distros/nightlies.
wb2_detect_window() {
    local probe=$WORKDIR/wb2_tint_probe.yuv fsz=$((32 * 32 * 3 / 2)) sz
    ffmpeg -y -loglevel error \
        -f lavfi -i "color=red:size=32x32:rate=50:duration=0.16" \
        -vf tinterlace -frames:v 4 -pix_fmt yuv420p "$probe" \
        || die "wb2: tinterlace probe failed"
    sz=$(stat -c%s "$probe")
    rm -f "$probe"
    if [ "$sz" = $((4 * fsz)) ]; then
        WB2_PROG_FRAMES=$((2 * WB_FRAMES))   # height kept: window ~4 s
    elif [ "$sz" = $((8 * fsz)) ]; then
        WB2_PROG_FRAMES=$WB_FRAMES           # height doubled: window ~2 s
    else
        die "wb2: unexpected tinterlace probe size $sz bytes"
    fi
}

# fps/geometry-normalize a real source so it can be xfaded or tinterlaced
# alongside the lavfi clips (50 fps CFR, exact cell geometry, square SAR).
wb2_src_filter() {
    echo "fps=50,scale=$1:$2:force_original_aspect_ratio=decrease,pad=$1:$2:(ow-iw)/2:(oh-ih)/2,setsar=1,setpts=PTS-STARTPTS"
}

# C1: real-scene crossfade, both variants (args: prog tint W H).
make_wb2_c1() {
    local prog=$1 tint=$2 w=$3 h=$4
    local fa fb
    fa=$(wb2_src_filter $w $h); fb=$fa
    if [ ! -f "$prog" ]; then
        ffmpeg -y -loglevel error -t 4 -i "$WB2_SRC_A" -t 4 -i "$WB2_SRC_B" \
            -filter_complex "[0:v]$fa[a];[1:v]$fb[b];[a][b]xfade=transition=fade:duration=1.5:offset=0.5" \
            -frames:v $WB2_PROG_FRAMES -pix_fmt yuv420p "$prog" \
            || die "failed to synthesize $prog"
    fi
    if [ ! -f "$tint" ]; then
        ffmpeg -y -loglevel error -t 4 -i "$WB2_SRC_A" -t 4 -i "$WB2_SRC_B" \
            -filter_complex "[0:v]$fa[a];[1:v]$fb[b];[a][b]xfade=transition=fade:duration=1.5:offset=0.5,tinterlace" \
            -frames:v $WB_FRAMES -pix_fmt yuv420p "$tint" \
            || die "failed to synthesize $tint"
    fi
}

# C2: dip-to-black on source A, both variants (args: prog tint W H).
# Fade out 0.25..1.75 s, black plateau 1.75..2.0 s, fade in 2.0..3.5 s: the
# full fade-out and the plateau sit inside the ~2 s ffmpeg-8 window, the
# whole dip inside the ~4 s ffmpeg <= 7 window.  split/concat because
# fade=t=in forces BLACK for every frame before its start time -- chaining
# it after fade=t:out on one timeline blacks out the whole clip.
make_wb2_c2() {
    local prog=$1 tint=$2 w=$3 h=$4
    local fa fc
    fa=$(wb2_src_filter $w $h)
    fc="[0:v]$fa,split=2[x][y];[x]trim=end=2.0,fade=t=out:st=0.25:d=1.5[p];[y]trim=start=2.0:end=4,setpts=PTS-STARTPTS,fade=t=in:st=0:d=1.5[q];[p][q]concat=n=2:v=1"
    if [ ! -f "$prog" ]; then
        ffmpeg -y -loglevel error -t 4 -i "$WB2_SRC_A" \
            -filter_complex "$fc" \
            -frames:v $WB2_PROG_FRAMES -pix_fmt yuv420p "$prog" \
            || die "failed to synthesize $prog"
    fi
    if [ ! -f "$tint" ]; then
        ffmpeg -y -loglevel error -t 4 -i "$WB2_SRC_A" \
            -filter_complex "$fc,tinterlace" \
            -frames:v $WB_FRAMES -pix_fmt yuv420p "$tint" \
            || die "failed to synthesize $tint"
    fi
}

# C3: grained synthetic crossfade, both variants (args: prog tint W H).
make_wb2_c3() {
    local prog=$1 tint=$2 w=$3 h=$4
    if [ ! -f "$prog" ]; then
        ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=${w}x${h}:rate=50:duration=4" \
            -f lavfi -i "smptehdbars=size=${w}x${h}:rate=50:duration=4" \
            -filter_complex "xfade=transition=fade:duration=1.5:offset=0.5,noise=alls=10:allf=t+u:all_seed=42" \
            -frames:v $WB2_PROG_FRAMES -pix_fmt yuv420p "$prog" \
            || die "failed to synthesize $prog"
    fi
    if [ ! -f "$tint" ]; then
        ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=${w}x${h}:rate=50:duration=4" \
            -f lavfi -i "smptehdbars=size=${w}x${h}:rate=50:duration=4" \
            -filter_complex "xfade=transition=fade:duration=1.5:offset=0.5,noise=alls=10:allf=t+u:all_seed=42,tinterlace" \
            -frames:v $WB_FRAMES -pix_fmt yuv420p "$tint" \
            || die "failed to synthesize $tint"
    fi
}

# C4 progressive variant: the pre-tinterlace make_dissolve_clip stream
# (the tinterlaced variant is make_dissolve_clip itself).
make_wb2_c4_prog() {
    local prog=$1
    if [ ! -f "$prog" ]; then
        ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=50:duration=4" \
            -f lavfi -i "smptehdbars=size=${WIDTH}x${HEIGHT}:rate=50:duration=4" \
            -filter_complex "xfade=transition=fade:duration=1.5:offset=0.5" \
            -frames:v $WB2_PROG_FRAMES -pix_fmt yuv420p "$prog" \
            || die "failed to synthesize $prog"
    fi
}

# C5: non-dissolve control, both variants (args: prog tint W H).
# Sets WB2_C5_VARIANT=real|lavfi for the results provenance.
make_wb2_c5() {
    local prog=$1 tint=$2 w=$3 h=$4
    if have_wb2_source_a; then
        local fa
        fa=$(wb2_src_filter $w $h)
        if [ ! -f "$prog" ]; then
            ffmpeg -y -loglevel error -t 4 -i "$WB2_SRC_A" \
                -vf "$fa" -frames:v $WB2_PROG_FRAMES -pix_fmt yuv420p "$prog" \
                || die "failed to synthesize $prog"
        fi
        if [ ! -f "$tint" ]; then
            ffmpeg -y -loglevel error -t 4 -i "$WB2_SRC_A" \
                -vf "$fa,tinterlace" -frames:v $WB_FRAMES -pix_fmt yuv420p "$tint" \
                || die "failed to synthesize $tint"
        fi
        WB2_C5_VARIANT=real
    else
        if [ ! -f "$prog" ]; then
            ffmpeg -y -loglevel error \
                -f lavfi -i "testsrc2=size=${w}x${h}:rate=50:duration=4" \
                -frames:v $WB2_PROG_FRAMES -pix_fmt yuv420p "$prog" \
                || die "failed to synthesize $prog"
        fi
        make_control_clip "$tint"
        WB2_C5_VARIANT=lavfi
    fi
}

# md5 of one decoded frame (args: file WxH frame_idx).
wb2_frame_md5() {
    ffmpeg -v error -f rawvideo -pix_fmt yuv420p -video_size "$2" -i "$1" \
        -vf "select=eq(n\\,$3)" -frames:v 1 -f md5 - 2>/dev/null | sed 's/MD5=//'
}

# C1 generation gate (task 1.1): the blend must provably sit inside the
# coded window -- a mid-blend frame (3/8 into the window) is a real blend,
# i.e. matches neither the early (pure A) nor the late (pure/~pure B)
# frame, and the two endpoint frames differ (distinct scenes).
wb2_check_c1() {
    local prog=$1 w=$2 h=$3 tag=$4
    local e=$((WB2_PROG_FRAMES / 10)) m=$((WB2_PROG_FRAMES * 3 / 8)) l=$((WB2_PROG_FRAMES * 98 / 100))
    local me mm ml
    me=$(wb2_frame_md5 "$prog" ${w}x${h} $e)
    mm=$(wb2_frame_md5 "$prog" ${w}x${h} $m)
    ml=$(wb2_frame_md5 "$prog" ${w}x${h} $l)
    if [ -n "$me" ] && [ -n "$mm" ] && [ -n "$ml" ] \
       && [ "$me" != "$mm" ] && [ "$mm" != "$ml" ] && [ "$me" != "$ml" ]; then
        ok "$tag: blend provably inside the coded window (frames $e/$m/$l all differ)"
    else
        bad "$tag: mid-window frame is not a real blend (md5 $e=$me $m=$mm $l=$ml)"
    fi
}

# C2 generation gate (task 1.2): the plateau frame (t=1.86 s, frame 93 at
# 50 fps) must sit near the limited-range black floor (Y=16) and be clearly
# darker than a pre-fade frame (t=0.1 s).  blackdetect is unusable for this:
# dark real content trips its luma threshold before the dip even starts.
wb2_check_c2() {
    local prog=$1 w=$2 h=$3
    local y0 ydip
    y0=$(ffmpeg -v info -f rawvideo -pix_fmt yuv420p -video_size "$2x$3" -i "$1" \
        -vf "select=eq(n\,5),signalstats,metadata=print" -f null - 2>&1 \
        | sed -n 's/.*lavfi.signalstats.YAVG=\([0-9.]*\).*/\1/p' | head -1)
    ydip=$(ffmpeg -v info -f rawvideo -pix_fmt yuv420p -video_size "$2x$3" -i "$1" \
        -vf "select=eq(n\,93),signalstats,metadata=print" -f null - 2>&1 \
        | sed -n 's/.*lavfi.signalstats.YAVG=\([0-9.]*\).*/\1/p' | head -1)
    if [ -n "$y0" ] && [ -n "$ydip" ] \
       && awk "BEGIN{exit !($ydip <= 18 && $ydip < $y0 - 5)}"; then
        ok "c2: dip-to-black verified (YAVG pre-fade $y0, plateau $ydip)"
    else
        bad "c2: dip missing (YAVG pre-fade '$y0', plateau '$ydip')"
    fi
}

# Generation gate for every weightb2 clip (task 1.1/1.4 verify): the
# progressive variant holds exactly the window's frame count at the cell
# geometry, and the tinterlaced variant holds at least $WB_FRAMES coded
# frames.
wb2_check_clip() {
    local tag=$1 prog=$2 tint=$3 w=$4 h=$5
    local fsz=$((w * h * 3 / 2)) np nt
    np=$(( $(stat -c%s "$prog") / fsz ))
    nt=$(( $(stat -c%s "$tint") / fsz ))
    if [ "$np" = "$WB2_PROG_FRAMES" ] && [ "$nt" -ge "$WB_FRAMES" ]; then
        ok "$tag: clips OK (prog $np frames, tint $nt coded frames, ${w}x${h})"
    else
        bad "$tag: frame count wrong (prog $np != $WB2_PROG_FRAMES or tint $nt < $WB_FRAMES)"
    fi
}

# Hard-scene-cut clip for the open-GOP test: a constant-velocity horizontal
# pan (2 px/frame crop window over a double-width testsrc2 -- unique,
# well-predictable frames, so paff_cmp's exact-field matching stays
# unambiguous) cut to black + temporal noise at progressive frame 48.
# With --keyint 24 the cut lands exactly on a keyframe in either tinterlace
# flavour: on ffmpeg 8 (height-doubling merge, encodes read ${HEIGHT}-line
# frames sequentially) the cut is at coded frame 48, on ffmpeg <= 7 (merge
# keeps the height, 25 coded frames) at coded frame 24 -- an open-gop I
# pair sits on the cut in both cases.  The GOP-tail B pairs of the old
# content are coded AFTER that I pair and must reference across it to stay
# tiny (pure-skip fields against the pre-cut P pair), so a decoder-side DPB
# slip across the boundary shows up as a JM mismatch.
make_opengop_clip() {
    local clip=$1
    if [ ! -f "$clip" ]; then
        ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=352x${HEIGHT}:rate=50:duration=0.96" \
            -f lavfi -i "color=black:size=${WIDTH}x${HEIGHT}:rate=50:duration=1.04" \
            -filter_complex "[0]crop=${WIDTH}:${HEIGHT}:'2*n':0[p];[1]noise=alls=80:allf=t[n];[p][n]concat=n=2:v=1,tinterlace" \
            -frames:v 25 -pix_fmt yuv420p "$clip" \
            || die "failed to synthesize $clip"
    fi
}

# BD-rate (%) between two 4-point RD curves, PSNR-Y metric, piecewise
# log-linear interpolation (Bjontegaard-style, design D2): integrate
# log10(rate) over the common PSNR range and convert the mean difference
# back to a rate ratio.  Positive result = curve A saves bits vs curve B.
# Args: 8 "kbps psnr" pairs: A1..A4 (weightb on) then B1..B4 (off).
bdrate() {
    awk -v pts="$*" 'BEGIN {
        n = split(pts, v, " ")
        if (n != 16) { print "nan"; exit }
        for (i = 0; i < 4; i++) {
            ra[i] = v[2*i+1] + 0; pa[i] = v[2*i+2] + 0
            rb[i] = v[8+2*i+1] + 0; pb[i] = v[8+2*i+2] + 0
        }
        # sort each curve by PSNR ascending (insertion sort, n=4)
        for (i = 1; i < 4; i++) {
            ka = pa[i]; kr = ra[i]
            for (j = i - 1; j >= 0 && pa[j] > ka; j--) { pa[j+1] = pa[j]; ra[j+1] = ra[j] }
            pa[j+1] = ka; ra[j+1] = kr
            ka = pb[i]; kr = rb[i]
            for (j = i - 1; j >= 0 && pb[j] > ka; j--) { pb[j+1] = pb[j]; rb[j+1] = rb[j] }
            pb[j+1] = ka; rb[j+1] = kr
        }
        lo = pa[0] > pb[0] ? pa[0] : pb[0]
        hi = pa[3] < pb[3] ? pa[3] : pb[3]
        if (hi <= lo) { print "nan"; exit }
        s = 0; N = 200
        for (i = 0; i < N; i++) {
            p = lo + (hi - lo) * (i + 0.5) / N
            s += log10(interp(p, ra, pa)) - log10(interp(p, rb, pb))
        }
        printf "%.3f\n", (1 - 10^(s / N)) * 100
    }
    function log10(x) { return log(x) / log(10) }
    # piecewise log-linear interpolation of rate as a function of PSNR
    function interp(p, r, ps,   i, t) {
        for (i = 0; i < 3; i++)
            if (p <= ps[i+1]) {
                t = (p - ps[i]) / (ps[i+1] - ps[i])
                return r[i] * (r[i+1] / r[i])^t
            }
        return r[3]
    }'
}

# Wide-range PAFF round-trips (field-geometry MV limits, D1): the geometry
# term binds only when the vertical search range exceeds the field border
# (552 field lines at 1080 rows incl. SPS padding, ~376 at 720 rows), so
# push --mvrange past it (level auto-selects 6.x for --mvrange 1024; a
# pinned lower level fails level validation).  roundtrip()'s fixed
# --threads 1 keeps i_mv_range_thread from masking the geometry term.
cmd_wide_range() {
    local save_w=$WIDTH save_h=$HEIGHT
    WIDTH=1920 HEIGHT=1080
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    roundtrip wide1080_tff_mv1024 --paff --tff --qp 24 --bframes 0 --ref 4 --mvrange 1024
    roundtrip wide1080_bff_mv1024 --paff --bff --qp 24 --bframes 0 --ref 4 --mvrange 1024
    WIDTH=1280 HEIGHT=720
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    roundtrip wide720_tff_mv512 --paff --tff --qp 24 --bframes 0 --ref 4 --mvrange 512
    roundtrip wide720_bff_mv512 --paff --bff --qp 24 --bframes 0 --ref 4 --mvrange 512
    WIDTH=$save_w HEIGHT=$save_h
}

# Synthetic vertical-motion clip (D1 sign/parity coverage): large motion in
# both directions stressing the top/bottom border directions of both field
# parities; encoded at default and wide search range, TFF and BFF.
cmd_motion() {
    local save_w=$WIDTH save_h=$HEIGHT save_clip=${CLIP:-}
    WIDTH=1920 HEIGHT=1080
    make_motion_clip "$WORKDIR/motion_${WIDTH}x${HEIGHT}.yuv" $WIDTH $HEIGHT
    CLIP=$WORKDIR/motion_${WIDTH}x${HEIGHT}.yuv
    roundtrip motion_tff          --paff --tff --qp 24 --bframes 0 --ref 4
    roundtrip motion_bff          --paff --bff --qp 24 --bframes 0 --ref 4
    roundtrip motion_tff_mv1024   --paff --tff --qp 24 --bframes 0 --ref 4 --mvrange 1024
    roundtrip motion_bff_mv1024   --paff --bff --qp 24 --bframes 0 --ref 4 --mvrange 1024
    CLIP=$save_clip
    WIDTH=$save_w HEIGHT=$save_h
}

# Open-GOP round-trips (feature verified, doc/paff.txt "Working
# combinations"): non-IDR Ip keyframe pairs with a recovery_point SEI in
# the first field's AU; the GOP-tail B pairs of the previous GOP are coded
# after the I pair and keep its predecessors as references, with the pre-I
# pairs MMCO-evicted (two opcode-1 commands per pair) at the first P pair
# after the I.  The std rows cover plain keyint-driven boundaries on the
# regular clip; the cut rows use the hard-scene-cut clip where the tail Bs
# MUST cross-reference to decode correctly.  50 coded frames at keyint 12
# (std) give four non-IDR I pairs; the cut clip pins the boundary to the
# cut with keyint=min-keyint, scenecut off and a fixed b-adapt pattern.
cmd_opengop() {
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    make_opengop_clip "$WORKDIR/opengop_${WIDTH}x${HEIGHT}.yuv"
    local save_frames=$FRAMES save_clip=${CLIP:-}
    FRAMES=50
    roundtrip opengop_std_tff        --paff --tff --open-gop --keyint 12 --bframes 3 --b-pyramid normal --crf 23
    roundtrip opengop_std_bff        --paff --bff --open-gop --keyint 12 --bframes 3 --b-pyramid normal --crf 23
    CLIP=$WORKDIR/opengop_${WIDTH}x${HEIGHT}.yuv
    roundtrip opengop_cut_tff        --paff --tff --open-gop --keyint 24 --min-keyint 24 --scenecut 0 --bframes 3 --b-adapt 0 --b-pyramid normal --qp 24
    roundtrip opengop_cut_bff        --paff --bff --open-gop --keyint 24 --min-keyint 24 --scenecut 0 --bframes 3 --b-adapt 0 --b-pyramid normal --qp 24
    roundtrip opengop_cut_tff_strict --paff --tff --open-gop --keyint 24 --min-keyint 24 --scenecut 0 --bframes 3 --b-adapt 0 --b-pyramid strict --qp 24
    roundtrip opengop_cut_tff_ref4   --paff --tff --open-gop --keyint 24 --min-keyint 24 --scenecut 0 --bframes 3 --b-adapt 0 --b-pyramid normal --ref 4 --qp 24
    CLIP=$save_clip
    FRAMES=$save_frames
}

# Compare encoder reconstruction with JM output for a PAFF stream.
# JM's output structure depends on DPB pairing: the IDR pair comes out as
# two separate field pictures (only the coded parity's lines valid), while
# complementary P pairs are merged into full frames.  So instead of assuming
# a fixed picture layout, match by content: every JM picture must reproduce
# some fdec frame exactly on at least one field parity, and every fdec frame
# must get both parities covered.  $1 = field order (tff|bff),
# $2 = x264 dump-yuv, $3 = JM output
paff_cmp() {
    command -v python3 >/dev/null || die "python3 needed for PAFF field comparison"
    python3 - "$1" "$2" "$3" <<'EOF'
import sys
tff, xpath, jpath = sys.argv[1] == "tff", sys.argv[2], sys.argv[3]
x = open(xpath, 'rb').read()
j = open(jpath, 'rb').read()
W, H = map(int, open(xpath + ".dim").read().split('x'))
fsz = W * H * 3 // 2
n = len(x) // fsz
if len(j) % fsz or len(x) % fsz:
    print("truncated output file")
    sys.exit(1)
planes = [(0, W, H), (W*H, W//2, H//2), (W*H*5//4, W//2, H//2)]
# per JM picture: which (frame, parity) match exactly
covered = [[False, False] for _ in range(n)]
for pic in range(len(j) // fsz):
    jp = j[pic*fsz:(pic+1)*fsz]
    matches = []
    for f in range(n):
        xf = x[f*fsz:(f+1)*fsz]
        for par in (0, 1):
            diff = 0
            for off, pw, ph in planes:
                for l in range(par, ph, 2):
                    a = xf[off+l*pw:off+(l+1)*pw]
                    b = jp[off+l*pw:off+(l+1)*pw]
                    if a != b:
                        diff += sum(1 for k in range(pw) if a[k] != b[k])
            if diff == 0:
                matches.append((f, par))
    if not matches:
        print(f"JM picture {pic} matches no coded field of any frame")
        sys.exit(1)
    frames = {f for f, _ in matches}
    if len(frames) != 1:
        print(f"JM picture {pic} ambiguous: matches frames {sorted(frames)}")
        sys.exit(1)
    for f, par in matches:
        covered[f][par] = True
missing = [(f, par) for f in range(n) for par in (0, 1) if not covered[f][par]]
if missing:
    print(f"fields not reproduced by JM: {missing[:8]}{'...' if len(missing) > 8 else ''}")
    sys.exit(1)
EOF
}

# Encode one clip, decode with JM, compare against encoder reconstruction.
# $1 = test name, $2... = extra x264 options
roundtrip() {
    local name=$1; shift
    local clip=${CLIP:-$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv}
    local out=$WORKDIR/$name.264
    local fdec=$WORKDIR/$name.fdec.yuv
    local ref=$WORKDIR/$name.jm.yuv
    local tff=tff

    for opt in "$@"; do
        [ "$opt" = "--bff" ] && tff=bff
    done

    "$X264" "$clip" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads ${THREADS:-1} --dump-yuv "$fdec" -o "$out" "$@" >/dev/null 2>&1 \
        || { bad "$name: x264 encode failed"; return; }

    ( cd "$WORKDIR" && "$LDECOD" -i "$out" -o "$ref" >/dev/null 2>&1 ) \
        || { bad "$name: JM decode failed"; return; }

    echo "${WIDTH}x${HEIGHT}" > "$fdec.dim"
    if paff_cmp "$tff" "$fdec" "$ref"; then
        ok "$name: JM output bit-exact vs --dump-yuv"
    else
        bad "$name: JM output differs from --dump-yuv"
    fi
}

# 2-pass variant: run pass 1 (stats only) then pass 2 with --dump-yuv, then
# the usual JM decode + field-parity compare.  $1 = name, $2... = x264 opts
# (the caller's --pass/--stats are added here; --slow-firstpass is recommended
# for PAFF 2-pass per doc/paff.txt).
roundtrip_2pass() {
    local name=$1; shift
    local clip=$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv
    local out=$WORKDIR/$name.264
    local fdec=$WORKDIR/$name.fdec.yuv
    local ref=$WORKDIR/$name.jm.yuv
    local stats=$WORKDIR/$name.stats
    local tff=tff

    for opt in "$@"; do
        [ "$opt" = "--bff" ] && tff=bff
    done

    "$X264" "$clip" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads ${THREADS:-1} --pass 1 --slow-firstpass --stats "$stats" \
        -o /dev/null "$@" >/dev/null 2>&1 \
        || { bad "$name: pass 1 failed"; return; }
    "$X264" "$clip" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads ${THREADS:-1} --pass 2 --slow-firstpass --stats "$stats" \
        --dump-yuv "$fdec" -o "$out" "$@" >/dev/null 2>&1 \
        || { bad "$name: pass 2 failed"; return; }

    ( cd "$WORKDIR" && "$LDECOD" -i "$out" -o "$ref" >/dev/null 2>&1 ) \
        || { bad "$name: JM decode failed"; return; }

    echo "${WIDTH}x${HEIGHT}" > "$fdec.dim"
    if paff_cmp "$tff" "$fdec" "$ref"; then
        ok "$name: JM output bit-exact vs --dump-yuv"
    else
        bad "$name: JM output differs from --dump-yuv"
    fi
}

# Encode and compare against a saved baseline.  The comparison is done on
# JM-decoded pixels, not on the bitstreams: the SEI embeds the x264 version
# and option strings (which legitimately change between builds), while the
# gate's purpose is "encoding behavior with PAFF off must not change".
# $1 = test name, $2 = mode (save|check), $3... = extra x264 options
baseline_encode() {
    local name=$1 mode=$2; shift 2
    local clip=$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv
    local out=$WORKDIR/$name.cur.264
    local ref=$WORKDIR/baseline/$name.264

    "$X264" "$clip" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads ${THREADS:-1} -o "$out" "$@" >/dev/null 2>&1 \
        || { bad "$name: x264 encode failed"; return; }

    if [ "$mode" = save ]; then
        mkdir -p "$WORKDIR/baseline"
        cp "$out" "$ref"
        ok "$name: baseline saved"
    else
        [ -f "$ref" ] || { bad "$name: no saved baseline (run baseline-save first)"; return; }
        ( cd "$WORKDIR" && "$LDECOD" -i "$out" -o "$WORKDIR/$name.cur.yuv" >/dev/null 2>&1 ) \
            || { bad "$name: JM decode of current output failed"; return; }
        ( cd "$WORKDIR" && "$LDECOD" -i "$ref" -o "$WORKDIR/$name.ref.yuv" >/dev/null 2>&1 ) \
            || { bad "$name: JM decode of baseline failed"; return; }
        if cmp -s "$WORKDIR/$name.ref.yuv" "$WORKDIR/$name.cur.yuv"; then
            ok "$name: decoded output identical to baseline"
        else
            bad "$name: decoded output differs from baseline"
        fi
    fi
}

# Decode-to-end smoke test without a bit-exact gate, plus a PSNR sanity
# check against the source clip.
# $1 = test name, $2... = extra x264 options
smoke() {
    local name=$1; shift
    local clip=$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv
    local out=$WORKDIR/$name.264
    local ref=$WORKDIR/$name.jm.yuv
    local psnr

    "$X264" "$clip" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads 1 --psnr -o "$out" "$@" 2>&1 | tee "$WORKDIR/$name.log" >/dev/null \
        || { bad "$name: x264 encode failed"; return; }

    ( cd "$WORKDIR" && "$LDECOD" -i "$out" -o "$ref" >/dev/null 2>&1 ) \
        || { bad "$name: JM decode failed"; return; }

    psnr=$(sed -n 's/.*PSNR Mean Y:\([0-9.]*\).*/\1/p' "$WORKDIR/$name.log" | tail -1)
    if [ -n "$psnr" ] && awk "BEGIN{exit !($psnr > 30)}"; then
        ok "$name: JM decoded to end, PSNR-Y ${psnr}dB"
    else
        bad "$name: decoded but PSNR-Y suspicious ('$psnr')"
    fi
}

cmd_baseline_save() {
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    baseline_encode progressive save --crf 20
    baseline_encode mbaff       save --crf 20 --interlaced --tff
    # paff-sliced-threads (task 5.3): regression byte/pixel-identity cells
    # for the modes the change must not alter -- progressive sliced (the
    # dispatch and deblock paths it shares) and non-sliced PAFF at t1 and
    # frame threads (the monolithic/parallel pair drivers).
    THREADS=2 baseline_encode prog_sliced_t2 save --crf 20 --sliced-threads
    THREADS=4 baseline_encode prog_sliced_t4 save --crf 20 --sliced-threads
    baseline_encode paff_t1       save --crf 20 --paff --tff
    THREADS=4 baseline_encode paff_ft_t4   save --crf 20 --paff --tff
}

cmd_baseline_check() {
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    baseline_encode progressive check --crf 20
    baseline_encode mbaff       check --crf 20 --interlaced --tff
    THREADS=2 baseline_encode prog_sliced_t2 check --crf 20 --sliced-threads
    THREADS=4 baseline_encode prog_sliced_t4 check --crf 20 --sliced-threads
    baseline_encode paff_t1       check --crf 20 --paff --tff
    THREADS=4 baseline_encode paff_ft_t4   check --crf 20 --paff --tff
}

cmd_paff() {
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    # Constant QP isolates bitstream conformance from rate control.
    # I-only: keyint 1 (every pair IDR).  I+P: no B-frames, no weightp
    # (both are force-disabled by --paff anyway, spelled out for clarity).
    roundtrip paff_tff_intra --paff --tff --qp 20 --keyint 1 --bframes 0 --weightp 0
    roundtrip paff_tff_ip    --paff --tff --qp 20 --bframes 0 --weightp 0
    roundtrip paff_bff_ip    --paff --bff --qp 20 --bframes 0 --weightp 0
    # Multi-reference P fields (mixed parity, exercises the full field-list
    # expansion + the complementary first field between passes).
    roundtrip paff_tff_ref4 --paff --tff --qp 20 --bframes 0 --weightp 0 --ref 4
    roundtrip paff_bff_ref4 --paff --bff --qp 20 --bframes 0 --weightp 0 --ref 4
    # 4.2: active sliding window -- --ref 2 forces eviction every pair
    # (exercises the D20 between-pass eviction), TFF + BFF.
    roundtrip paff_tff_ref2_evict --paff --tff --qp 20 --bframes 0 --weightp 0 --ref 2
    roundtrip paff_bff_ref2_evict --paff --bff --qp 20 --bframes 0 --weightp 0 --ref 2
    # 4.1: the X264_REF_MAX=16 FIELD-ENTRY ceiling -- --ref 8 pairs => 16 field
    # entries (D6 cap), mixed parity, TFF + BFF.  (--ref 16 pairs would set
    # max_num_ref_frames=16, exceeding the level's MaxDpbFrames at this
    # resolution; --ref 8 hits the X264_REF_MAX expansion cap exactly.)
    roundtrip paff_tff_ref8_16fld --paff --tff --qp 20 --bframes 0 --weightp 0 --ref 8
    roundtrip paff_bff_ref8_16fld --paff --bff --qp 20 --bframes 0 --weightp 0 --ref 8
    # weightp: the per-slot weighted-reference shadow (paff-pass-threads
    # weightp determinism fix) is live code under PAFF; exercise it in the
    # round-trip gate (THREADS env covers the threaded jobs).  weightp 2
    # degrades to weightp 1 semantics under PAFF (no reference dupes), so
    # weightp 1 is the meaningful configuration.  B frames included to also
    # hit the weighted-pred path with a populated L1.
    roundtrip paff_tff_weightp --paff --tff --qp 20 --ref 3 --weightp 1
    roundtrip paff_bff_weightp_b --paff --bff --qp 20 --ref 3 --bframes 3 --weightp 1
    # Default-CRF smoke run: no crash, JM decodes to the end, sane PSNR.
    smoke paff_tff_crf --paff --tff
}

# The 14-config B-field matrix from paff-b-frames/checkpoint-4.1-4.3.md
# (TFF/BFF x b-pyramid none/normal/strict x ref 1-4 x direct mode x
# CABAC/CAVLC x keyint 8/24 x --no-deblock).  The list lives in
# tools/paff_matrix.sh so the CI smoke (test_paff_ci.sh) stays in sync.
# Several rows were the exact configs that previously segfaulted or drifted
# under PAFF, so they are kept verbatim as a byte-exact regression gate.
cmd_matrix() {
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    for entry in "${PAFF_MATRIX[@]}"; do
        name=${entry%%|*}
        opts=${entry#*|}
        roundtrip "$name" --paff $opts
    done
}

# Rate-control round-trips (task 8.1's CRF/2-pass/CBR × TFF/BFF gate beyond
# the qp/CRF matrix above): CBR+VBV (no-B) and 2-pass ABR, TFF and BFF.
# 2-pass uses --slow-firstpass (recommended for PAFF, doc/paff.txt).  VBV+B
# round-trips are covered by task 2.3's validation.
cmd_rc() {
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    roundtrip    rc_cbr_tff --paff --tff --bframes 0 --bitrate 300 --vbv-maxrate 300 --vbv-bufsize 300
    roundtrip    rc_cbr_bff --paff --bff --bframes 0 --bitrate 300 --vbv-maxrate 300 --vbv-bufsize 300
    roundtrip_2pass rc_2p_tff  --paff --tff --bframes 0 --bitrate 300
    roundtrip_2pass rc_2p_bff  --paff --bff --bframes 0 --bitrate 300
}

# Weightb quality measurement (paff-weightb, design D2): CRF sweep on the
# dissolve clip and the non-dissolve control, PAFF weightb on vs off, PSNR-Y
# and bitrate from the encoder's own --psnr summary, BD-rate per clip.
# Outcome: kill (dissolve gain 0.272%, floor 0.5% -- recorded in
# doc/paff.txt); weightb is permanently force-disabled under PAFF, so the
# "on" rows now warn and encode weightb-off (BD-rate 0.000%); the command
# stays so the measurement setup remains reproducible.
# Sliced-threads PAFF cells (paff-sliced-threads task 5.1): the field-band
# geometry, per-pass dispatch, serial reference sweep and field-granular
# VBV budget against JM, plus the sliced-specific edges and non-JM gates.
# Sliced bands need >= 4 field MB rows per thread, so the cells run on a
# 576i clip (18 field rows, field-thread cap 4); the default 144-line clip
# clamps sliced PAFF to one thread and would exercise nothing.
SL_WIDTH=704
SL_HEIGHT=576

cmd_sliced() {
    local save_w=$WIDTH save_h=$HEIGHT save_frames=$FRAMES
    local n log out out2 plan0 plan1 pair
    WIDTH=$SL_WIDTH HEIGHT=$SL_HEIGHT
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"

    # Thread-count clamp: 8 threads over 18 field rows must reduce to the
    # field cap (4) with the warning that makes the clamp observable.
    log=$WORKDIR/sl_cap.log
    if "$X264" "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv" --input-res ${WIDTH}x${HEIGHT} \
            --frames 3 --paff --tff --sliced-threads --threads 8 --crf 23 \
            -o /dev/null >"$log" 2>&1 \
       && grep -q "reducing to 4" "$log"; then
        ok "sl_cap: --threads 8 clamps to the field-row cap (4) with a warning"
    else
        bad "sl_cap: --threads 8 not clamped/warned (see $log)"
    fi

    # JM round-trips: {TFF,BFF} x {I-only, I+P, I+P+B} x N in {2,4},
    # plus the weighted-prediction shadow cells (D9: workers read thread
    # 0's weight buffers through the per-slot shadow) and CAVLC (the
    # entropy coder takes a different flush path in slice_write).
    for n in 2 4; do
        THREADS=$n roundtrip sl${n}_tff_intra --paff --tff --sliced-threads --qp 20 --keyint 1 --bframes 0 --weightp 0
        THREADS=$n roundtrip sl${n}_bff_intra --paff --bff --sliced-threads --qp 20 --keyint 1 --bframes 0 --weightp 0
        THREADS=$n roundtrip sl${n}_tff_ip     --paff --tff --sliced-threads --qp 20 --bframes 0 --weightp 0 --ref 4
        THREADS=$n roundtrip sl${n}_bff_ip     --paff --bff --sliced-threads --qp 20 --bframes 0 --weightp 0 --ref 4
        THREADS=$n roundtrip sl${n}_tff_ipb    --paff --tff --sliced-threads --crf 23 --bframes 3
        THREADS=$n roundtrip sl${n}_bff_ipb    --paff --bff --sliced-threads --crf 23 --bframes 3
        THREADS=$n roundtrip sl${n}_tff_wp1    --paff --tff --sliced-threads --crf 23 --bframes 0 --weightp 1
        THREADS=$n roundtrip sl${n}_tff_wp2    --paff --tff --sliced-threads --crf 23 --bframes 0 --weightp 2
        THREADS=$n roundtrip sl${n}_tff_cavlc  --paff --tff --sliced-threads --crf 23 --bframes 0 --no-cabac
    done

    # Non-VBV byte-repeat (CRF, CABAC and CAVLC): no PAFF+sliced output is
    # required to match any non-sliced output, but repeat runs at a fixed
    # thread count must be byte-identical.
    for n in 2 4; do
        for extra in "" "--no-cabac"; do
            out=$WORKDIR/sl_rep${n}.264; out2=$WORKDIR/sl_rep${n}_b.264
            "$X264" "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv" --input-res ${WIDTH}x${HEIGHT} \
                --frames $FRAMES --paff --tff --sliced-threads --threads $n --crf 23 \
                $extra -o "$out" >/dev/null 2>&1 \
                && "$X264" "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv" --input-res ${WIDTH}x${HEIGHT} \
                --frames $FRAMES --paff --tff --sliced-threads --threads $n --crf 23 \
                $extra -o "$out2" >/dev/null 2>&1 \
                && cmp -s "$out" "$out2" \
                && ok "sl_rep${n}${extra:+_cavlc}: byte-identical repeat run" \
                || bad "sl_rep${n}${extra:+_cavlc}: repeat run differs"
        done
    done

    # Rate control: CBR+VBV and 2-pass ABR round-trips.
    THREADS=4 roundtrip sl_cbr --paff --tff --sliced-threads --bframes 0 \
        --bitrate 800 --vbv-maxrate 800 --vbv-bufsize 1600
    THREADS=4 roundtrip_2pass sl_2p --paff --tff --sliced-threads --bframes 0 --bitrate 800

    # --nal-hrd cbr through the independent Annex C CPB simulator.
    out=$WORKDIR/sl_hrd.264
    "$X264" "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv" --input-res ${WIDTH}x${HEIGHT} \
        --frames $FRAMES --paff --tff --sliced-threads --threads 4 --bframes 0 \
        --bitrate 800 --vbv-maxrate 800 --vbv-bufsize 1600 --nal-hrd cbr \
        -o "$out" >/dev/null 2>&1 \
        && python3 "$REPO_ROOT/tools/check_hrd.py" "$out" >"$out.hrd" 2>&1 \
        && ok "sl_hrd: Annex C CPB check (field granularity, N slices/field)" \
        || bad "sl_hrd: CPB check failed (see $out.hrd)"

    # Field-budget assertion (D4): every pair logs both field budgets; the
    # plans must be positive, bounded by the pair plan, the pass-1 floor
    # must hold, and (where the floor is not binding) the two budgets sum
    # back to the pair plan within the plan/actual slack.
    log=$WORKDIR/sl_budget.log
    "$X264" "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv" --input-res ${WIDTH}x${HEIGHT} \
        --frames $FRAMES --paff --tff --sliced-threads --threads 4 --bframes 0 \
        --bitrate 800 --vbv-maxrate 800 --vbv-bufsize 1600 --log-level debug \
        -o /dev/null >"$log" 2>&1
    if python3 - "$log" <<'PYEOF'
import re, sys
lines = [l for l in open(sys.argv[1]) if 'paff field budget' in l]
pairs = {}
for idx, l in enumerate(lines):
    m = re.search(r'pass (\d) plan (\d+) bits \(pair plan (\d+)\)', l)
    if m:
        pairs.setdefault(idx // 2, {})[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
fail = []
for pi, p in pairs.items():
    if 0 not in p or 1 not in p:
        fail.append(f'pair {pi}: missing a pass budget'); continue
    (plan0, pair), (plan1, _) = p[0], p[1]
    if not (0 < plan0 <= pair): fail.append(f'pair {pi}: pass-0 plan {plan0} outside (0, {pair}]')
    if not (0 < plan1 <= pair): fail.append(f'pair {pi}: pass-1 plan {plan1} outside (0, {pair}]')
    if plan1 < 0.05 * pair - 1: fail.append(f'pair {pi}: pass-1 plan {plan1} below the 5% floor of {pair}')
    elif abs(plan0 + plan1 - pair) > 0.5 * pair:
        fail.append(f'pair {pi}: budgets {plan0}+{plan1} do not sum back to pair plan {pair}')
if fail:
    print('; '.join(fail)); sys.exit(1)
print(f'{len(pairs)} pairs OK')
PYEOF
    then ok "sl_budget: field budgets sum back to the pair plan ($(grep -c 'paff field budget' "$log") lines)"
    else bad "sl_budget: see above"
    fi

    # Band-geometry edge: 544 lines -> 17 field rows; N=4 splits 4/4/5/4
    # (not divisible by the thread count; the round band bias must place
    # every row exactly once).
    WIDTH=704 HEIGHT=544
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    THREADS=4 roundtrip sl_edge544_t4 --paff --tff --sliced-threads --crf 23 --bframes 0
    THREADS=2 roundtrip sl_edge544_t2 --paff --bff --sliced-threads --crf 23 --bframes 3
    WIDTH=$SL_WIDTH HEIGHT=$SL_HEIGHT

    # API-level mb_info cell (task 2.5): the pair-shared mb_info buffer
    # must be freed exactly once per pair, after the pair completes
    # (no worker frees under paff+sliced).
    if cmd_sliced_mbinfo; then :; fi

    # 10-bit sliced PAFF (worker bitstream growth is depth-dependent):
    # ffmpeg conformance decode, clean log, exact frame count.
    # (JM bit-exactness stays 8-bit-only, as everywhere in this harness.)
    out=$WORKDIR/sl_10bit.264
    # PAFF demuxes as one packet per field access unit: 2*FRAMES packets.
    if "$X264" "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv" --input-res ${WIDTH}x${HEIGHT} \
            --frames $FRAMES --paff --tff --sliced-threads --threads 4 --crf 23 \
            --output-depth 10 -o "$out" >/dev/null 2>&1 \
       && [ -z "$(ffmpeg -v error -i "$out" -f null - 2>&1)" ] \
       && [ "$(ffprobe -v error -count_packets -select_streams v -show_entries stream=nb_read_packets -of csv=p=0 "$out" 2>/dev/null | paste -sd+ | bc)" = $((FRAMES*2)) ]; then
        ok "sl_10bit: ffmpeg decodes cleanly, $FRAMES frames ($((FRAMES*2)) field AUs)"
    else
        bad "sl_10bit: encode/decode/frame-count check failed"
    fi

    WIDTH=$save_w HEIGHT=$save_h FRAMES=$save_frames
}

# API-level mb_info smoke (paff-sliced-threads task 2.5): builds a small
# harness against the repo's static lib, runs it, checks the callback
# count (one per pair).  Skips (with a FAIL, not silently) when no
# compiler or lib is available.
cmd_sliced_mbinfo() {
    local src=$WORKDIR/mbinfo_smoke.c bin=$WORKDIR/mbinfo_smoke clip=$WORKDIR/clip_${SL_WIDTH}x${SL_HEIGHT}.yuv
    cat > "$src" <<'CEOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "x264.h"
#define W 704
#define H 576
#define N_FRAMES 12
static int free_calls = 0;
static void my_mb_info_free( void *p ) { free_calls++; free( p ); }
int main( int argc, char **argv )
{
    x264_param_t param;
    x264_picture_t pic, pic_out;
    x264_t *h;
    x264_nal_t *nal;
    int i_nal, i;
    FILE *f = fopen( argv[1], "rb" );
    if( !f ) return 2;
    x264_param_default_preset( &param, "medium", "zerolatency" );
    param.i_csp = X264_CSP_I420;
    param.i_width = W; param.i_height = H;
    param.b_paff = 1; param.b_tff = 1;
    param.i_threads = 4; param.b_sliced_threads = 1;
    param.i_timebase_num = 1; param.i_timebase_den = 25;
    param.i_keyint_max = 1 << 16;
    param.analyse.b_mb_info = 1;
    param.analyse.b_mb_info_update = 1;
    h = x264_encoder_open( &param );
    if( !h ) return 1;
    x264_picture_init( &pic );
    pic.img.i_csp = X264_CSP_I420;
    int64_t fsz = (int64_t)W * H * 3 / 2;
    uint8_t *buf = malloc( fsz );
    for( i = 0; i < N_FRAMES; i++ )
    {
        if( fread( buf, 1, fsz, f ) != fsz ) return 1;
        pic.img.plane[0] = buf;
        pic.img.i_plane = 3;
        pic.img.plane[1] = buf + W*H;
        pic.img.plane[2] = buf + W*H*5/4;
        pic.img.i_stride[0] = W;
        pic.img.i_stride[1] = pic.img.i_stride[2] = W/2;
        pic.i_pts = i;
        pic.prop.mb_info = calloc( 1, (W/16) * (H/16) );
        pic.prop.mb_info_free = my_mb_info_free;
        int before = free_calls;
        if( x264_encoder_encode( h, &nal, &i_nal, &pic, &pic_out ) < 0 ) return 1;
        if( free_calls > before + 1 ) { fprintf( stderr, "freed twice in one pair\n" ); return 1; }
    }
    while( x264_encoder_encode( h, &nal, &i_nal, NULL, &pic_out ) > 0 );
    x264_encoder_close( h );
    printf( "%d\n", free_calls );
    free( buf );
    return free_calls == N_FRAMES ? 0 : 1;
}
CEOF
    command -v gcc >/dev/null || { bad "sl_mbinfo: gcc not found"; return 1; }
    [ -f "$REPO_ROOT/libx264.a" ] || { bad "sl_mbinfo: libx264.a not built"; return 1; }
    gcc -O1 -o "$bin" -I"$REPO_ROOT" "$src" "$REPO_ROOT/libx264.a" -lm -lpthread -ldl 2>>"$WORKDIR/sl_mbinfo.log" \
        || { bad "sl_mbinfo: harness build failed"; return 1; }
    if "$bin" "$clip" >"$WORKDIR/sl_mbinfo.out" 2>/dev/null \
       && [ "$(cat "$WORKDIR/sl_mbinfo.out" 2>/dev/null)" = 12 ]; then
        ok "sl_mbinfo: mb_info freed exactly once per pair"
    else
        bad "sl_mbinfo: callback count wrong (see $WORKDIR/sl_mbinfo.out)"
        return 1
    fi
}

cmd_weightb() {
    make_dissolve_clip "$WORKDIR/dissolve_${WIDTH}x${HEIGHT}.yuv"
    make_control_clip  "$WORKDIR/control_${WIDTH}x${HEIGHT}.yuv"
    local clip wt crf name log src psnr kbps
    for clip in dissolve control; do
        src=$WORKDIR/${clip}_${WIDTH}x${HEIGHT}.yuv
        local args_on="" args_off=""
        printf "%-9s %6s %4s %12s %10s\n" "$clip" weight crf kbps psnr_y
        for wt in on off; do
            for crf in 18 23 28 33; do
                name=wb_${clip}_${wt}_crf${crf}
                log=$WORKDIR/$name.log
                "$X264" "$src" --input-res ${WIDTH}x${HEIGHT} --frames $WB_FRAMES \
                    --threads 1 --paff --tff --crf $crf --psnr --$([ $wt = on ] && echo weightb || echo no-weightb) \
                    -o $WORKDIR/$name.264 > "$log" 2>&1 \
                    || { bad "$name: x264 encode failed"; continue; }
                psnr=$(sed -n 's/.*PSNR Mean Y:\([0-9.]*\).*/\1/p' "$log" | tail -1)
                kbps=$(sed -n 's/.*encoded.*frames.* \([0-9.]*\) kb\/s.*/\1/p' "$log" | tail -1)
                if [ -z "$psnr" ] || [ -z "$kbps" ]; then
                    bad "$name: could not parse psnr/kbps from log"
                    continue
                fi
                printf "%9s %6s %4d %12s %10s\n" "" "$wt" "$crf" "$kbps" "$psnr"
                if [ $wt = on ]; then args_on="$args_on $kbps $psnr"; else args_off="$args_off $kbps $psnr"; fi
            done
        done
        local bd
        bd=$(bdrate $args_on $args_off)
        echo "$clip: BD-rate saving of weightb-on vs off = ${bd}%"
        if [ "$bd" = nan ]; then
            bad "$clip: weightb BD-rate could not be computed (see table above)"
        else
            ok "$clip: weightb BD-rate ${bd}% (see table above)"
        fi
    done
}

# weightb2 re-measurement (paff-weightb-remeasure, design D1/D2): the
# two-stage pre-registered protocol.  Stage 1 (mode "prog") is the
# progressive positive control on the pre-tinterlace streams; stage 2
# (modes "tff"/"bff") is the PAFF measurement on the tinterlaced variants.
# Per clip x mode: CRF 18/23/28/33, --threads 1, weightb on vs off, PSNR-Y
# and kbps from the encoder's own --psnr summary, BD-rate via bdrate().
#
# Stage-2 prerequisite (task 2.3): the PAFF validation force-off must be
# reverted LOCALLY (never committed on the kill path).  The hunk, applied
# to encoder/encoder.c in validate_parameters():
#
#  --- a/encoder/encoder.c
#  +++ b/encoder/encoder.c
#  @@ validate_parameters(), inside if( h->param.b_paff )
#  -        if( h->param.analyse.b_weighted_bipred )
#  -        {
#  -            x264_log( h, X264_LOG_WARNING, "PAFF does not support weighted biprediction (measured: no gain): disabling\n" );
#  -            h->param.analyse.b_weighted_bipred = 0;
#  -        }
#
# (i.e. delete the warn-and-disable block; the comment above it can stay).
# The force-off guard (task 2.2) greps every weightb-on PAFF log for the
# warning and aborts the run when it appears -- without the revert the
# on-rows would silently encode weightb-off and measure nothing.
cmd_weightb2() {
    wb2_detect_window
    local clips="" spec prog tint w h

    echo "weightb2: ffmpeg $(ffmpeg -version | sed -n 's/^ffmpeg version //p' | head -1), window $WB2_PROG_FRAMES progressive frames"
    if have_wb2_sources; then
        echo "weightb2: C1/C2 sources A=$WB2_SRC_A B=$WB2_SRC_B"
    else
        echo "weightb2: PAFF_WB_SRC_A/PAFF_WB_SRC_B unset or unreadable -- C1/C2 skipped (lavfi-only fallback; record with the results)"
    fi

    if have_wb2_sources; then
        make_wb2_c1 $WORKDIR/wb2_c1_${WIDTH}x${HEIGHT}_prog.yuv $WORKDIR/wb2_c1_${WIDTH}x${HEIGHT}.yuv $WIDTH $HEIGHT
        make_wb2_c1 $WORKDIR/wb2_c1_720x576_prog.yuv         $WORKDIR/wb2_c1_720x576.yuv         720 576
        clips="$clips c1 c1_576"
    fi
    if have_wb2_source_a; then
        make_wb2_c2 $WORKDIR/wb2_c2_${WIDTH}x${HEIGHT}_prog.yuv $WORKDIR/wb2_c2_${WIDTH}x${HEIGHT}.yuv $WIDTH $HEIGHT
        clips="$clips c2"
    fi
    make_wb2_c3      $WORKDIR/wb2_c3_${WIDTH}x${HEIGHT}_prog.yuv $WORKDIR/wb2_c3_${WIDTH}x${HEIGHT}.yuv $WIDTH $HEIGHT
    make_dissolve_clip $WORKDIR/wb2_c4_${WIDTH}x${HEIGHT}.yuv
    make_wb2_c4_prog $WORKDIR/wb2_c4_${WIDTH}x${HEIGHT}_prog.yuv
    make_wb2_c5      $WORKDIR/wb2_c5_${WIDTH}x${HEIGHT}_prog.yuv $WORKDIR/wb2_c5_${WIDTH}x${HEIGHT}.yuv $WIDTH $HEIGHT
    clips="$clips c3 c4 c5"
    echo "weightb2: C5 variant = $WB2_C5_VARIANT"

    # Generation gates (tasks 1.1-1.4 verify).
    for spec in $clips; do
        wb2_clip_spec $spec
        wb2_check_clip "$spec" "$WB2_PROG" "$WB2_TINT" $WB2_W $WB2_H
    done
    if have_wb2_sources; then
        wb2_check_c1 $WORKDIR/wb2_c1_${WIDTH}x${HEIGHT}_prog.yuv $WIDTH $HEIGHT c1
        wb2_check_c1 $WORKDIR/wb2_c1_720x576_prog.yuv 720 576 c1_576
        wb2_check_c2 $WORKDIR/wb2_c2_${WIDTH}x${HEIGHT}_prog.yuv $WIDTH $HEIGHT
    fi
    # C3 must differ from C4 (the grain must actually be there).
    if [ "$(md5sum < $WORKDIR/wb2_c3_${WIDTH}x${HEIGHT}.yuv)" != "$(md5sum < $WORKDIR/wb2_c4_${WIDTH}x${HEIGHT}.yuv)" ]; then
        ok "c3: grained clip differs from the legacy C4 clip"
    else
        bad "c3: identical to C4 (grain missing?)"
    fi

    local clip mode wt crf name log src frames opts psnr kbps args_on args_off bd
    for clip in $clips; do
        wb2_clip_spec $clip
        prog=$WB2_PROG; tint=$WB2_TINT; w=$WB2_W; h=$WB2_H
        for mode in $WB2_MODES; do
            case $mode in
                prog) src=$prog; frames=$WB2_PROG_FRAMES; opts="" ;;
                tff)  src=$tint; frames=$WB_FRAMES;       opts="--paff --tff" ;;
                bff)  src=$tint; frames=$WB_FRAMES;       opts="--paff --bff" ;;
                *)    die "wb2: unknown mode $mode (WB2_MODES)" ;;
            esac
            args_on=""; args_off=""
            printf "%-7s %-4s %6s %4s %12s %10s\n" "$clip" "$mode" weight crf kbps psnr_y
            for wt in on off; do
                for crf in 18 23 28 33; do
                    name=wb2_${clip}_${mode}_${wt}_crf${crf}
                    log=$WORKDIR/$name.log
                    "$X264" "$src" --input-res ${w}x${h} --frames $frames \
                        --threads 1 $opts --crf $crf --psnr --$([ $wt = on ] && echo weightb || echo no-weightb) \
                        -o $WORKDIR/$name.264 > "$log" 2>&1 \
                        || { bad "$name: x264 encode failed"; continue; }
                    # Force-off guard (task 2.2): a weightb-on PAFF row that
                    # logged the validation warning encoded weightb-OFF.
                    if [ $wt = on ] && [ $mode != prog ] \
                       && grep -q "weighted biprediction (measured: no gain): disabling" "$log"; then
                        die "wb2: $name: the PAFF force-off ate --weightb -- apply the local validation revert documented on cmd_weightb2, rebuild, re-run"
                    fi
                    psnr=$(sed -n 's/.*PSNR Mean Y:\([0-9.]*\).*/\1/p' "$log" | tail -1)
                    kbps=$(sed -n 's/.*encoded.*frames.* \([0-9.]*\) kb\/s.*/\1/p' "$log" | tail -1)
                    if [ -z "$psnr" ] || [ -z "$kbps" ]; then
                        bad "$name: could not parse psnr/kbps from log"
                        continue
                    fi
                    printf "%7s %4s %6s %4d %12s %10s\n" "" "" "$wt" "$crf" "$kbps" "$psnr"
                    if [ $wt = on ]; then args_on="$args_on $kbps $psnr"; else args_off="$args_off $kbps $psnr"; fi
                done
            done
            bd=$(bdrate $args_on $args_off)
            echo "$clip/$mode: BD-rate saving of weightb-on vs off = ${bd}%"
            if [ "$bd" = nan ]; then
                bad "$clip/$mode: weightb BD-rate could not be computed (see table above)"
            else
                ok "$clip/$mode: weightb BD-rate ${bd}%"
            fi
        done
    done
}

# Map a weightb2 clip id to its files/geometry; sets WB2_PROG, WB2_TINT,
# WB2_W, WB2_H.
wb2_clip_spec() {
    case $1 in
        c1)     WB2_PROG=$WORKDIR/wb2_c1_${WIDTH}x${HEIGHT}_prog.yuv; WB2_TINT=$WORKDIR/wb2_c1_${WIDTH}x${HEIGHT}.yuv; WB2_W=$WIDTH;  WB2_H=$HEIGHT ;;
        c1_576) WB2_PROG=$WORKDIR/wb2_c1_720x576_prog.yuv;          WB2_TINT=$WORKDIR/wb2_c1_720x576.yuv;          WB2_W=720; WB2_H=576 ;;
        c2)     WB2_PROG=$WORKDIR/wb2_c2_${WIDTH}x${HEIGHT}_prog.yuv; WB2_TINT=$WORKDIR/wb2_c2_${WIDTH}x${HEIGHT}.yuv; WB2_W=$WIDTH;  WB2_H=$HEIGHT ;;
        c3)     WB2_PROG=$WORKDIR/wb2_c3_${WIDTH}x${HEIGHT}_prog.yuv; WB2_TINT=$WORKDIR/wb2_c3_${WIDTH}x${HEIGHT}.yuv; WB2_W=$WIDTH;  WB2_H=$HEIGHT ;;
        c4)     WB2_PROG=$WORKDIR/wb2_c4_${WIDTH}x${HEIGHT}_prog.yuv; WB2_TINT=$WORKDIR/wb2_c4_${WIDTH}x${HEIGHT}.yuv; WB2_W=$WIDTH;  WB2_H=$HEIGHT ;;
        c5)     WB2_PROG=$WORKDIR/wb2_c5_${WIDTH}x${HEIGHT}_prog.yuv; WB2_TINT=$WORKDIR/wb2_c5_${WIDTH}x${HEIGHT}.yuv; WB2_W=$WIDTH;  WB2_H=$HEIGHT ;;
        *)      die "wb2: unknown clip $1" ;;
    esac
}

# --------------------------------------------------------------------------
# mbtree-under-PAFF re-measurement stand (paff-mbtree-remeasure, design
# D1/D5).  Question (the closed "Per-field mbtree propagation" future-work
# item): lookahead/mbtree analyze whole frames, so under PAFF the pair-level
# propagate weights are ~2x off per field -- does per-field propagation buy
# measurable quality?  Answer (2026-08-30): no, gates below passed on all
# three clips; see doc/paff.txt "Measured and closed".
#
# Per clip: interlaced variant (tinterlace field-merge of adjacent
# progressive frames) encoded prog/MBAFF/PAFF x mbtree on/off x CRF
# 18/23/28/33, plus a progressive control (same segment, no tinterlace)
# encoded prog-only for the G0 validity gate.  Encodes go through the x264
# CLI (preset medium, DEFAULT threads -- the session protocol; thread count
# changes the PAFF MV-range clamp, so absolute numbers are machine-dependent
# and the gates carry wide margins).  PSNR-Y is measured EXTERNALLY through
# rawvideo pipes (the D4 timestamp-free recipe; x264's own --psnr is a mean
# of per-picture PSNRs -- per-FIELD pictures under PAFF -- and was rejected,
# design D5).  kbps = output bytes * 8 / clip duration, with the session's
# per-clip duration constants; BD-rate is invariant to a per-clip kbps
# scale, so the constants move absolute bitrates only, not the gates.
#
# Gates (pre-registered, design D1/D5):
#   G0  prog-control mbtree gain <= -3% BD-rate -- validity check, ABORTS
#       non-zero on failure (a stand that cannot see mbtree must be loud).
#   Q1  PAFF vs MBAFF on the interlaced clip, mbtree on: PAFF not worse by
#       > 1% BD-rate.  Report-only PASS/FAIL, exit 0.
#   Q2  PAFF mbtree gain >= 50% of the prog gain on the same interlaced
#       clip.  Report-only.  Denominator guard: |prog gain| < 1% prints
#       INCONCLUSIVE instead of a ratio (the ratio is noise when mbtree
#       does nothing in weave mode anyway).

# ffmpeg 8's tinterlace=merge doubles the frame height (both fields kept at
# full vertical resolution); ffmpeg <= 7 keeps the height.  Probe once so
# the synthesis below produces the design-D1 geometry on either line (the
# reference numbers in doc/paff.txt were measured with the doubling
# behaviour; on the old behaviour the field pixels differ slightly and the
# wide gate margins absorb it).
mb_detect_tinterlace() {
    local probe=$WORKDIR/mb_tint_probe.y4m h
    ffmpeg -y -loglevel error \
        -f lavfi -i "color=red:size=64x32:rate=50:duration=0.16" \
        -vf tinterlace=merge -frames:v 4 -pix_fmt yuv420p "$probe" \
        || die "mbtree: tinterlace probe failed"
    h=$(ffprobe -v error -select_streams v -show_entries stream=height \
        -of csv=p=0 "$probe")
    rm -f "$probe"
    case $h in
        32) MB_TINT_DOUBLES=0 ;;
        64) MB_TINT_DOUBLES=1 ;;
        *)  die "mbtree: unexpected tinterlace probe height '$h'" ;;
    esac
}

# Clip table (design D1, window/frame-count details verified against the
# archived session clips in openspec/changes/paff-mbtree-remeasure/
# measurement/); sets MB_W MB_H MB_SRC MB_SS MB_FPS_P MB_SECS_I MB_SECS_P.
# The interlaced variant holds 400 coded frames (800 source frames
# field-merged into pairs, top field from the even frame); the progressive
# control (used by G0 only) holds 200 source frames (at 25 fps for relax,
# whose 50 fps native rate would otherwise double the control's frame
# count).  MB_SS is the input seek in seconds (accurate seek: frames are
# decoded and discarded up to the timestamp -- do NOT use a trim filter
# here, a frame-dropping filter before tinterlace makes it duplicate its
# first output frame).  MB_SECS_* are TRUE durations (frames/fps); the
# session's constants assumed 200-frame interlaced clips but the archived
# clips carry 400 -- harmless there (BD-rate is invariant to a per-clip
# kbps scale), corrected here.
mb_clip_spec() {
    case $1 in
        hall)  MB_W=1280; MB_H=720;  MB_SRC=$MB_SRC_HALL;  MB_SS=""; MB_FPS_P=""
               MB_SECS_I=32.0;     MB_SECS_P=8.0 ;;
        relax) MB_W=1920; MB_H=1080; MB_SRC=$MB_SRC_RELAX; MB_SS=300; MB_FPS_P=25
               MB_SECS_I=16.0;     MB_SECS_P=8.0 ;;
        amv)   MB_W=1280; MB_H=720;  MB_SRC=$MB_SRC_AMV;   MB_SS=60;  MB_FPS_P=""
               MB_SECS_I=26.69333; MB_SECS_P=6.67333 ;;
        smoke) MB_W=640;  MB_H=720;  MB_SRC="";           MB_SS=""; MB_FPS_P=""
               MB_SECS_I=16.0;     MB_SECS_P=8.0 ;;
        *)     die "mbtree: unknown clip $1" ;;
    esac
}

# Synthesize the interlaced and progressive variants of one clip (design D1
# recipes; <clip>_i.y4m and <clip>_p.y4m in $WORKDIR, cached across runs).
mb_make_clip() {
    local clip=$1 psh iv pv seek vf_i vf_p n v
    mb_clip_spec $clip
    psh=$MB_H; [ "$MB_TINT_DOUBLES" = 1 ] && psh=$((MB_H / 2))
    iv=$WORKDIR/mb_${clip}_i.y4m
    pv=$WORKDIR/mb_${clip}_p.y4m
    seek=""
    [ -n "$MB_SS" ] && seek="-ss $MB_SS"
    if [ -n "$MB_SRC" ]; then
        vf_i="scale=${MB_W}:${psh},tinterlace=merge"
        vf_p="scale=${MB_W}:${MB_H}"
        [ -n "$MB_FPS_P" ] && vf_p="fps=$MB_FPS_P,$vf_p"
        [ -f "$iv" ] || ffmpeg -y -loglevel error $seek -i "$MB_SRC" -map 0:v:0 \
            -vf "$vf_i" -frames:v 400 -pix_fmt yuv420p "$iv" \
            || die "mbtree: failed to synthesize $iv"
        [ -f "$pv" ] || ffmpeg -y -loglevel error $seek -i "$MB_SRC" -map 0:v:0 \
            -vf "$vf_p" -frames:v 200 -pix_fmt yuv420p "$pv" \
            || die "mbtree: failed to synthesize $pv"
    else
        # lavfi testsrc2 smoke clip (always runs; pipeline self-check only).
        [ -f "$iv" ] || ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=${MB_W}x${psh}:rate=50:duration=16" \
            -vf tinterlace=merge -frames:v 400 -pix_fmt yuv420p "$iv" \
            || die "mbtree: failed to synthesize $iv"
        [ -f "$pv" ] || ffmpeg -y -loglevel error \
            -f lavfi -i "testsrc2=size=${MB_W}x${MB_H}:rate=25:duration=8" \
            -frames:v 200 -pix_fmt yuv420p "$pv" \
            || die "mbtree: failed to synthesize $pv"
    fi
    for v in i p; do
        local want=400; [ $v = p ] && want=200
        n=$(ffprobe -v error -count_packets -select_streams v \
            -show_entries stream=nb_read_packets -of csv=p=0 \
            "$WORKDIR/mb_${clip}_${v}.y4m")
        [ "$n" = $want ] || die "mbtree: $clip/$v: expected $want frames, got '$n' (source segment too short?)"
    done
}

# PSNR-Y of an encoded stream vs its y4m reference, paired through rawvideo
# pipes (design D4: the dual-input psnr filter pairs by PTS and mis-pairs
# 30000/1001 content round-tripped through mkv; decode both sides first,
# then compare timestamp-free with the framerate forced equal).  The
# decodes run with -fps_mode passthrough: without it ffmpeg's default
# timestamp scaling duplicates frames when the VUI framerate differs from
# the raw-stream default (e.g. 12.5 fps tinterlace output decodes to 2x
# frames).
mb_psnr() {
    local out=$1 ref=$2 wh=$3
    local dec=$WORKDIR/.mb_dec.yuv rfd=$WORKDIR/.mb_ref.yuv
    ffmpeg -hide_banner -y -v error -i "$out" -fps_mode passthrough \
           -c:v rawvideo -pix_fmt yuv420p -f rawvideo "$dec" \
        && ffmpeg -hide_banner -y -v error -i "$ref" -fps_mode passthrough \
           -c:v rawvideo -pix_fmt yuv420p -f rawvideo "$rfd" \
        || { rm -f "$dec" "$rfd"; return 1; }
    ffmpeg -hide_banner -s "$wh" -pix_fmt yuv420p -framerate 30 -i "$dec" \
           -s "$wh" -pix_fmt yuv420p -framerate 30 -i "$rfd" \
           -lavfi psnr -f null - 2>&1 \
        | sed -n 's/.*PSNR y:\([0-9.inf]*\).*/\1/p' | tail -1
    rm -f "$dec" "$rfd"
}

# BD-rate of the curve in $2 vs the curve in $1 (negative = $2 saves bits).
# Prints the value; non-zero exit on error.  NOTE: callers must check the
# exit status in the main shell (var=$(mb_bdrate ...) || die ...) -- a die
# inside command substitution would only kill the subshell.
mb_bdrate() {
    python3 "$REPO_ROOT/tools/bdrate.py" "$1" "$2"
}

# Encode one matrix cell and measure it.  Appends "psnr kbps" to the point
# file $9 and sets MB_LAST_PSNR.  Encodes are cached ($out exists => skip),
# PSNR measurement always runs so re-runs regenerate the point files.
# Args: name mode(prog|mbaff|paff) mb(0|1) crf src.y4m secs WxH frames ptsfile
mb_cell() {
    local name=$1 mode=$2 mb=$3 crf=$4 src=$5 secs=$6 wh=$7 frames=$8 pts=$9
    local out=$WORKDIR/mb_${name}.264 log=$WORKDIR/mb_${name}.log
    local opts psnr kbps bytes
    case $mode in
        prog)  opts="--no-interlaced" ;;   # y4m carries It; force the weave
        mbaff) opts="--interlaced --tff" ;;
        paff)  opts="--paff --tff" ;;
        *)     die "mbtree: unknown mode $mode" ;;
    esac
    [ "$mb" = 0 ] && opts="$opts --no-mbtree"
    if [ ! -s "$out" ]; then
        "$X264" "$src" --frames $frames --preset medium --crf $crf $opts \
            -o "$out" >"$log" 2>&1 \
            || { bad "mbtree: $name: x264 encode failed (see $log)"; return 1; }
    fi
    psnr=$(mb_psnr "$out" "$src" "$wh") || { bad "mbtree: $name: PSNR measure failed"; return 1; }
    [ -n "$psnr" ] || { bad "mbtree: $name: no PSNR line parsed"; return 1; }
    bytes=$(stat -c%s "$out")
    kbps=$(awk "BEGIN{printf \"%.3f\", $bytes * 8 / $secs / 1000}")
    printf '%s %s\n' "$psnr" "$kbps" >> "$pts"
    printf '  %-26s %4s %12s %10s\n' "$name" "$crf" "$kbps" "$psnr"
    MB_LAST_PSNR=$psnr
}

# Run the full matrix on one clip; when $2=1 evaluate the gates (G0 aborts,
# Q1/Q2 report-only), when $2=0 only the pipeline self-checks run (smoke).
mb_run_clip() {
    local clip=$1 gated=$2
    mb_clip_spec $clip
    local iv=$WORKDIR/mb_${clip}_i.y4m pv=$WORKDIR/mb_${clip}_p.y4m
    local wh=${MB_W}x${MB_H}
    local variant mode mb crf pts src secs modes nframes
    printf '  %-26s %4s %12s %10s\n' cell crf kbps psnr_y
    for variant in i p; do
        src=$iv; secs=$MB_SECS_I; modes="prog mbaff paff"; nframes=400
        if [ $variant = p ]; then src=$pv; secs=$MB_SECS_P; modes=prog; nframes=200; fi
        for mode in $modes; do
            for mb in 1 0; do
                pts=$WORKDIR/mb_pts_${clip}_${variant}_${mode}_mb${mb}.txt
                : > "$pts"
                for crf in 18 23 28 33; do
                    mb_cell ${clip}_${variant}_${mode}_mb${mb}_crf${crf} \
                        $mode $mb $crf "$src" "$secs" "$wh" $nframes "$pts"
                    # Pipeline self-check (task 2.2): CRF-18 progressive
                    # rows must exceed 40 dB on every clip.
                    if [ $mode = prog ] && [ $crf = 18 ]; then
                        if [ -n "${MB_LAST_PSNR:-}" ] \
                           && awk "BEGIN{exit !($MB_LAST_PSNR > 40)}"; then
                            ok "mbtree $clip/$variant: CRF-18 prog PSNR-Y ${MB_LAST_PSNR} dB > 40"
                        else
                            bad "mbtree $clip/$variant: CRF-18 prog PSNR-Y '${MB_LAST_PSNR:-}' <= 40"
                        fi
                    fi
                done
            done
        done
    done
    [ "$gated" = 1 ] || return 0

    local g0 q1 q1off gp gm gf ratio st
    # G0 (validity): prog-control mbtree gain (BD-rate on vs off) <= -3%.
    g0=$(mb_bdrate $WORKDIR/mb_pts_${clip}_p_prog_mb0.txt $WORKDIR/mb_pts_${clip}_p_prog_mb1.txt) \
        || die "mbtree: $clip: G0 BD-rate computation failed"
    if awk "BEGIN{exit !($g0 <= -3.0)}"; then
        echo "G0 $clip: prog-control mbtree gain ${g0}% (validity gate <= -3%) OK"
    else
        die "mbtree: $clip: G0 FAILED -- prog-control mbtree gain ${g0}% > -3%; the stand cannot see mbtree on this clip, results void"
    fi
    # Q1 (report-only): PAFF vs MBAFF, mbtree on, must not be worse by > 1%.
    q1=$(mb_bdrate $WORKDIR/mb_pts_${clip}_i_mbaff_mb1.txt $WORKDIR/mb_pts_${clip}_i_paff_mb1.txt) \
        || die "mbtree: $clip: Q1 BD-rate computation failed"
    q1off=$(mb_bdrate $WORKDIR/mb_pts_${clip}_i_mbaff_mb0.txt $WORKDIR/mb_pts_${clip}_i_paff_mb0.txt) \
        || die "mbtree: $clip: Q1(off) BD-rate computation failed"
    st=FAIL; awk "BEGIN{exit !($q1 <= 1.0)}" && st=PASS
    echo "Q1 $clip: PAFF vs MBAFF mbtree-on BD-rate ${q1}% (gate <= +1%) $st   [mbtree off: ${q1off}%, informational]"
    # Q2 (report-only): PAFF mbtree gain >= 50% of the prog gain, same clip.
    gp=$(mb_bdrate $WORKDIR/mb_pts_${clip}_i_prog_mb0.txt  $WORKDIR/mb_pts_${clip}_i_prog_mb1.txt) \
        || die "mbtree: $clip: Q2 BD-rate computation failed"
    gm=$(mb_bdrate $WORKDIR/mb_pts_${clip}_i_mbaff_mb0.txt $WORKDIR/mb_pts_${clip}_i_mbaff_mb1.txt) \
        || die "mbtree: $clip: Q2 BD-rate computation failed"
    gf=$(mb_bdrate $WORKDIR/mb_pts_${clip}_i_paff_mb0.txt  $WORKDIR/mb_pts_${clip}_i_paff_mb1.txt) \
        || die "mbtree: $clip: Q2 BD-rate computation failed"
    echo "Q2 $clip: mbtree gains (BD-rate on vs off): prog ${gp}%  MBAFF ${gm}%  PAFF ${gf}%"
    if awk "BEGIN{exit !($gp > -1.0 && $gp < 1.0)}"; then
        echo "Q2 $clip: INCONCLUSIVE -- |prog gain| ${gp}% < 1% (denominator guard)"
    else
        ratio=$(awk "BEGIN{printf \"%.3f\", $gf / $gp}")
        st=FAIL; awk "BEGIN{exit !($ratio >= 0.50)}" && st=PASS
        echo "Q2 $clip: PAFF/prog gain ratio $ratio (gate >= 0.50) $st"
    fi
}

cmd_mbtree() {
    command -v python3 >/dev/null || die "mbtree: python3 needed for tools/bdrate.py"
    mb_detect_tinterlace
    echo "mbtree: ffmpeg $(ffmpeg -version | sed -n 's/^ffmpeg version //p' | head -1), tinterlace height-$([ "$MB_TINT_DOUBLES" = 1 ] && echo doubling || echo keeping)"
    echo "mbtree: encodes via $X264, preset medium, default threads -- numbers are machine-dependent (design D5)"
    local clips="" c
    for c in hall relax amv; do
        mb_clip_spec $c
        if [ -n "$MB_SRC" ] && [ -f "$MB_SRC" ]; then
            clips="$clips $c"
            echo "mbtree: clip $c source $MB_SRC"
        else
            echo "mbtree: PAFF_MB_SRC_$(echo $c | tr '[a-z]' '[A-Z]') unset or unreadable -- clip $c skipped"
        fi
    done
    clips="$clips smoke"
    for c in $clips; do
        mb_make_clip $c
    done
    for c in $clips; do
        echo "===== $c ====="
        if [ $c = smoke ]; then
            echo "SMOKE (synthetic) -- gates not asserted"
            mb_run_clip $c 0
        else
            mb_run_clip $c 1
        fi
    done
}

# Lookahead-range parity with progressive (spec scenario, observable only
# via the debug log, not the bitstream): the lookahead analyzes whole frames
# under PAFF, so its lowres search range must equal the progressive run's.
# slicetype.c logs "lookahead lowres mv_range = N" once per encode at debug
# level; a PAFF run whose range is still halved logs half the value.
cmd_la_range() {
    local clip=$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv
    local v_paff v_prog
    make_clip "$clip"

    "$X264" "$clip" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads 1 --log-level debug --paff --tff --qp 20 --bframes 0 \
        -o /dev/null 2>"$WORKDIR/la_range.paff.log" \
        || { bad "la_range: PAFF encode failed"; return; }
    "$X264" "$clip" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads 1 --log-level debug --qp 20 --bframes 0 \
        -o /dev/null 2>"$WORKDIR/la_range.prog.log" \
        || { bad "la_range: progressive encode failed"; return; }

    v_paff=$(sed -n 's/.*lookahead lowres mv_range = \([0-9]*\).*/\1/p' \
        "$WORKDIR/la_range.paff.log" | head -1)
    v_prog=$(sed -n 's/.*lookahead lowres mv_range = \([0-9]*\).*/\1/p' \
        "$WORKDIR/la_range.prog.log" | head -1)
    if [ -z "$v_paff" ] || [ -z "$v_prog" ]; then
        bad "la_range: mv_range log line missing (paff='$v_paff' prog='$v_prog')"
    elif [ "$v_paff" = "$v_prog" ]; then
        ok "la_range: lookahead lowres mv_range matches progressive ($v_paff)"
    else
        bad "la_range: lookahead lowres mv_range differs: paff=$v_paff prog=$v_prog"
    fi
}

cmds=${@:-all}
check_tools $cmds
mkdir -p "$WORKDIR"
for cmd in $cmds; do
    case $cmd in
        baseline-save)  cmd_baseline_save ;;
        baseline-check) cmd_baseline_check ;;
        paff)           cmd_paff ;;
        matrix)         cmd_matrix ;;
        rc)             cmd_rc ;;
        sliced)         cmd_sliced ;;
        la_range)       cmd_la_range ;;
        wide_range)     cmd_wide_range ;;
        motion)         cmd_motion ;;
        weightb)        cmd_weightb ;;
        weightb2)       cmd_weightb2 ;;
        mbtree)         cmd_mbtree ;;
        opengop)        cmd_opengop ;;
        all)            cmd_baseline_check; cmd_paff; cmd_matrix; cmd_rc; cmd_sliced; cmd_la_range; cmd_wide_range; cmd_motion; cmd_opengop ;;
        *)              die "unknown command: $cmd" ;;
    esac
done

echo "---"
echo "passed: $PASS, failed: $FAIL"
[ $FAIL -eq 0 ]
