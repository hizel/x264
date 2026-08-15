#!/bin/bash
# PAFF rate-control validation + rate-distortion comparison vs MBAFF
# (openspec change paff-sei-hrd-rc, task 2.2).
#
# Encodes a synthesized interlaced clip with PAFF (TFF/BFF), MBAFF and
# (for reference) progressive coding across the RC matrix
# (CRF x2, 1-pass ABR, 2-pass ABR, CBR/VBV), and prints a PSNR/SSIM/bitrate
# table.  Deterministic: clips are synthesized from lavfi sources, all
# encodes are single-threaded.
#
# Usage:
#   tools/test_paff_rd.sh
#
# Environment:
#   X264      path to the x264 CLI binary   (default: ./x264)
#   WORKDIR   scratch dir for clips/outputs (default: /tmp/paff_rd)

set -u

cd "$(dirname "$0")/.."

X264=${X264:-./x264}
WORKDIR=${WORKDIR:-/tmp/paff_rd}

WIDTH=352
HEIGHT=288
FRAMES=100
BITRATE=400   # kbps target for ABR/CBR runs

[ -x "$X264" ] || { echo "ERROR: x264 binary not found: $X264" >&2; exit 2; }
command -v ffmpeg >/dev/null || { echo "ERROR: ffmpeg not found" >&2; exit 2; }

mkdir -p "$WORKDIR"
CLIP=$WORKDIR/clip_${WIDTH}x${HEIGHT}.yuv

# Interlaced clip with real field motion: 50 fps progressive pattern,
# tinterlace merges consecutive frame pairs -> 100 interlaced frames at
# 25 fps.
if [ ! -f "$CLIP" ]; then
    ffmpeg -y -loglevel error \
        -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=50:duration=4" \
        -vf tinterlace -frames:v $FRAMES -pix_fmt yuv420p "$CLIP" \
        || { echo "ERROR: clip synthesis failed" >&2; exit 2; }
fi

# $1 = name, $2... = x264 options (mode options included)
run() {
    local name=$1; shift
    local log=$WORKDIR/$name.log
    "$X264" "$CLIP" --input-res ${WIDTH}x${HEIGHT} --frames $FRAMES \
        --threads 1 --psnr --ssim -o "$WORKDIR/$name.264" "$@" >"$log" 2>&1 \
        || { echo "$name: ENCODE FAILED"; return 1; }
    local kbps psnr ssim
    kbps=$(sed -n 's/.*, \([0-9.]*\) kb\/s.*/\1/p' "$log" | tail -1)
    psnr=$(sed -n 's/.*PSNR Mean Y:\([0-9.]*\).*/\1/p' "$log" | tail -1)
    ssim=$(sed -n 's/.*SSIM Mean Y:\([0-9.]*\).*/\1/p' "$log" | tail -1)
    printf '%-28s %10s %10s %10s\n' "$name" "${kbps:-?}" "${psnr:-?}" "${ssim:-?}"
}

echo "clip: $CLIP (${WIDTH}x${HEIGHT}, $FRAMES interlaced frames, target ${BITRATE} kb/s)"
echo
printf '%-28s %10s %10s %10s\n' "encode" "kb/s" "PSNR-Y" "SSIM-Y"
echo "-----------------------------------------------------------------"

for crf in 20 27; do
    run crf${crf}_paff_tff  --paff --tff --crf $crf
    run crf${crf}_paff_bff  --paff --bff --crf $crf
    run crf${crf}_mbaff     --interlaced --tff --crf $crf
    run crf${crf}_prog      --crf $crf
    echo
done

run abr1_paff_tff  --paff --tff --bitrate $BITRATE
run abr1_paff_bff  --paff --bff --bitrate $BITRATE
run abr1_mbaff     --interlaced --tff --bitrate $BITRATE
run abr1_prog      --bitrate $BITRATE
echo

# 2-pass with --slow-firstpass: with the default turbo first pass the
# pass-1->pass-2 bit model mismatch is amplified by field pictures
# (field ME gains more from the full-settings second pass), undershooting
# the target by ~10% under PAFF; --slow-firstpass brings it to ~1-2%.
for mode in "paff_tff --paff --tff" "paff_bff --paff --bff" "mbaff --interlaced --tff" "prog"; do
    set -- $mode
    name=$1; shift
    run abr2_${name} "$@" --bitrate $BITRATE --slow-firstpass --pass 1 --stats $WORKDIR/abr2_${name}.stats
    run abr2_${name} "$@" --bitrate $BITRATE --slow-firstpass --pass 2 --stats $WORKDIR/abr2_${name}.stats
done
echo

# CBR with VBV (per-field AU buffer model since task 2.3).
run cbr_nb_paff_tff --paff --tff --bitrate $BITRATE --vbv-bufsize $BITRATE --vbv-maxrate $BITRATE --bframes 0
run cbr_nb_paff_bff --paff --bff --bitrate $BITRATE --vbv-bufsize $BITRATE --vbv-maxrate $BITRATE --bframes 0
run cbr_nb_mbaff    --interlaced --tff --bitrate $BITRATE --vbv-bufsize $BITRATE --vbv-maxrate $BITRATE --bframes 0
run cbr_nb_prog     --bitrate $BITRATE --vbv-bufsize $BITRATE --vbv-maxrate $BITRATE --bframes 0
echo
run cbr_b_paff_tff  --paff --tff --bitrate $BITRATE --vbv-bufsize $BITRATE --vbv-maxrate $BITRATE
run cbr_b_paff_bff  --paff --bff --bitrate $BITRATE --vbv-bufsize $BITRATE --vbv-maxrate $BITRATE
run cbr_b_mbaff     --interlaced --tff --bitrate $BITRATE --vbv-bufsize $BITRATE --vbv-maxrate $BITRATE
run cbr_b_prog      --bitrate $BITRATE --vbv-bufsize $BITRATE --vbv-maxrate $BITRATE
