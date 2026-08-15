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
#   all             baseline-check + paff + matrix + rc (default)
#
# Environment:
#   X264      path to the x264 CLI binary      (default: ./x264)
#   LDECOD    path to the JM ldecod binary     (default: $JM_HOME/bin/ldecod.exe,
#                                                else ../JM/bin/ldecod.exe)
#   WORKDIR   scratch dir for clips/outputs    (default: /tmp/paff_test)

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

check_tools() {
    [ -x "$X264" ]   || die "x264 binary not found/executable: $X264"
    [ -x "$LDECOD" ] || die "JM ldecod not found/executable: $LDECOD (set LDECOD or JM_HOME)"
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
    local clip=$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv
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

check_tools
mkdir -p "$WORKDIR"

cmds=${@:-all}
for cmd in $cmds; do
    case $cmd in
        baseline-save)  cmd_baseline_save ;;
        baseline-check) cmd_baseline_check ;;
        paff)           cmd_paff ;;
        matrix)         cmd_matrix ;;
        rc)             cmd_rc ;;
        all)            cmd_baseline_check; cmd_paff; cmd_matrix; cmd_rc ;;
        *)              die "unknown command: $cmd" ;;
    esac
done

echo "---"
echo "passed: $PASS, failed: $FAIL"
[ $FAIL -eq 0 ]
