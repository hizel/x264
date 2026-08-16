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
# weightb (the only command that never round-trips through JM).
check_tools() {
    [ -x "$X264" ]   || die "x264 binary not found/executable: $X264"
    case " $* " in
        *" baseline-save "*|*" baseline-check "*|*" paff "*|*" matrix "*|*" rc "*|*" la_range "*|*" wide_range "*|*" motion "*|*" opengop "*|*" all "*)
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
        --threads 1 --dump-yuv "$fdec" -o "$out" "$@" >/dev/null 2>&1 \
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
        --threads 1 --pass 1 --slow-firstpass --stats "$stats" \
        -o /dev/null "$@" >/dev/null 2>&1 \
        || { bad "$name: pass 1 failed"; return; }
    "$X264" "$clip" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads 1 --pass 2 --slow-firstpass --stats "$stats" \
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
        --threads 1 -o "$out" "$@" >/dev/null 2>&1 \
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
}

cmd_baseline_check() {
    make_clip "$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv"
    baseline_encode progressive check --crf 20
    baseline_encode mbaff       check --crf 20 --interlaced --tff
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
        la_range)       cmd_la_range ;;
        wide_range)     cmd_wide_range ;;
        motion)         cmd_motion ;;
        weightb)        cmd_weightb ;;
        opengop)        cmd_opengop ;;
        all)            cmd_baseline_check; cmd_paff; cmd_matrix; cmd_rc; cmd_la_range; cmd_wide_range; cmd_motion; cmd_opengop ;;
        *)              die "unknown command: $cmd" ;;
    esac
done

echo "---"
echo "passed: $PASS, failed: $FAIL"
[ $FAIL -eq 0 ]
