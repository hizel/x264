#!/bin/bash
# clean re-run: unique cell names, everything re-encoded
FF=~/dev/FFmpeg/ffmpeg
cd /tmp/paff_mb
CRFS="18 23 28 33"
: > results2.csv

enc_cell() {
    local src=$1 mode=$2 mb=$3 crf=$4
    local base="${src%.y4m}"
    local name="${base}_${mode}_mb${mb}_crf${crf}"
    local extra=""
    case $mode in
        mbaff) extra="-flags +ildct" ;;
        paff)  extra="-paff 1" ;;
    esac
    [ -s ${name}.mkv ] || $FF -hide_banner -y -v error -i $src -c:v libx264 -preset medium -crf $crf -mbtree $mb $extra -an ${name}.mkv || { echo "FAIL-ENC $name"; return; }
    echo "enc-ok $name"
}

for src in hall_25i.y4m relax_25i.y4m amv_i.y4m; do
    for mb in 1 0; do for crf in $CRFS; do
        enc_cell $src prog  $mb $crf
        enc_cell $src mbaff $mb $crf
        enc_cell $src paff  $mb $crf
    done; done
done
for src in hall_25p.y4m relax_25p.y4m amv_p.y4m; do
    for mb in 1 0; do for crf in $CRFS; do
        enc_cell $src prog $mb $crf
    done; done
done
echo ENCODES DONE
