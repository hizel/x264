#!/bin/bash
# amv clip cells, appends to results.csv (filenames carry content prefix)
FF=~/dev/FFmpeg/ffmpeg
cd /tmp/paff_mb
CRFS="18 23 28 33"

run_cell() {
    local src=$1 mode=$2 mb=$3 crf=$4
    local base="${src%.y4m}"
    local name="${base}_${mode}_${mb}_${crf}"
    local extra=""
    case $mode in
        mbaff) extra="-flags +ildct" ;;
        paff)  extra="-paff 1" ;;
    esac
    $FF -hide_banner -y -v error -i $src -c:v libx264 -preset medium -crf $crf -mbtree $mb $extra -an ${name}.mkv || { echo "FAIL $name"; return; }
    local bytes=$(stat -c %s ${name}.mkv)
    local psnr=$($FF -hide_banner -i ${name}.mkv -i $src -lavfi psnr -f null - 2>&1 | sed -n 's/.*PSNR y:\([0-9.inf]*\).*/\1/p' | tail -1)
    echo "${name},${base},${mode},${mb},${crf},${bytes},${psnr}" >> results.csv
    echo "done $name psnr_y=$psnr bytes=$bytes"
}

for mb in 1 0; do
    for crf in $CRFS; do
        run_cell amv_i.y4m prog  $mb $crf
        run_cell amv_i.y4m mbaff $mb $crf
        run_cell amv_i.y4m paff  $mb $crf
        run_cell amv_p.y4m prog  $mb $crf
    done
done
echo ALL DONE
