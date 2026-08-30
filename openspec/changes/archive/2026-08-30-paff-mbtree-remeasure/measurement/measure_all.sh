#!/bin/bash
# measure PSNR-Y via rawvideo pipes (timestamp-free pairing)
FF=~/dev/FFmpeg/ffmpeg
cd /tmp/paff_mb
echo "name,content,mode,mbtree,crf,bytes,psnr_y" > results2.csv

measure() {
    local src=$1 mode=$2 mb=$3 crf=$4
    local base="${src%.y4m}"
    local name="${base}_${mode}_mb${mb}_crf${crf}"
    [ -s ${name}.mkv ] || { echo "MISSING $name"; return; }
    local bytes=$(stat -c %s ${name}.mkv)
    $FF -hide_banner -y -v error -i ${name}.mkv -c:v rawvideo -pix_fmt yuv420p -f rawvideo /tmp/paff_mb/.dec.yuv
    $FF -hide_banner -y -v error -i ${src}     -c:v rawvideo -pix_fmt yuv420p -f rawvideo /tmp/paff_mb/.ref.yuv
    local wh=$(ffprobe -v error -show_entries stream=width,height -of csv=p=0 $src)
    local W=${wh%,*} H=${wh#*,}
    local psnr=$($FF -hide_banner -s ${W}x${H} -pix_fmt yuv420p -framerate 30 -i /tmp/paff_mb/.dec.yuv \
                     -s ${W}x${H} -pix_fmt yuv420p -framerate 30 -i /tmp/paff_mb/.ref.yuv \
                     -lavfi psnr -f null - 2>&1 | sed -n 's/.*PSNR y:\([0-9.inf]*\).*/\1/p' | tail -1)
    echo "${name},${base},${mode},${mb},${crf},${bytes},${psnr}" >> results2.csv
    echo "meas $name psnr_y=$psnr"
}

for src in hall_25i.y4m relax_25i.y4m amv_i.y4m; do
    for mb in 1 0; do for crf in 18 23 28 33; do
        measure $src prog  $mb $crf
        measure $src mbaff $mb $crf
        measure $src paff  $mb $crf
    done; done
done
for src in hall_25p.y4m relax_25p.y4m amv_p.y4m; do
    for mb in 1 0; do for crf in 18 23 28 33; do
        measure $src prog $mb $crf
    done; done
done
rm -f /tmp/paff_mb/.dec.yuv /tmp/paff_mb/.ref.yuv
echo MEASURE DONE
