#!/bin/bash
# tools/test_vbv_determinism.sh -- threaded-VBV determinism + quality harness
# (openspec change threaded-vbv-determinism, tasks 4.x and 5.x)
#
# Default mode: byte-repeat checks (tasks 4.1/4.2) and pre/post byte-identity
# checks (tasks 4.3/4.4).  --quality: the task-5.1 quality/compliance matrix
# (slow; baseline = median of 5 pre-change runs per cell).
#
# The pre-change baseline binary is built by this script from a git worktree:
# the ref comes from --baseline-ref, else from the cached ref of a previous
# run, else PRE_CHANGE_REF below (the last commit before this change landed).
#
# NOTE on --quality: it compares the binary under test against the
# PRE-change baseline, so the deltas documented in doc/threads.txt
# ("Threaded VBV determinism": short-clip bitrate-error correction, +27%
# filler on 720p-bf3-t8, the pre-existing end-of-stream check_hrd finding
# on 720p bf3 cells) show up as threshold exceedances BY DESIGN.  Treat
# those cells as expected; investigate anything else.
#
# Clips are external files (never committed); a missing clip skips its cells
# with a note.  Configuration via env vars:
#   X264_DET_CLIP1      raw clip A   (default /tmp/clip.yuv)
#   X264_DET_CLIP1_RES               (default 320x240)
#   X264_DET_CLIP2     raw clip B    (default /tmp/scenecut.yuv)
#   X264_DET_CLIP2_RES               (default 320x240)
#   X264_DET_CLIP720   720p input, any lavf-readable container
#                      (default /mnt/store2/ts/hall.mp4)
#   X264_DET_X264      binary under test (default ./x264)
#   X264_DET_RUNS      repeat runs per byte-repeat cell (default 10)
#   X264_DET_WORK      work dir (default /tmp/x264-vbv-det)
#   X264_DET_JOBS      parallel jobs for the quality matrix (default nproc)

set -u
cd "$(dirname "$0")/.."
REPO=$PWD

# Last commit before threaded-vbv-determinism landed.
PRE_CHANGE_REF=aa2b5a22838434a98757ecce2bf534f4e90ddbd4

CLIP1="${X264_DET_CLIP1:-/tmp/clip.yuv}"
CLIP1_RES="${X264_DET_CLIP1_RES:-320x240}"
CLIP2="${X264_DET_CLIP2:-/tmp/scenecut.yuv}"
CLIP2_RES="${X264_DET_CLIP2_RES:-320x240}"
CLIP720="${X264_DET_CLIP720:-/mnt/store2/ts/hall.mp4}"
X264="${X264_DET_X264:-./x264}"
RUNS="${X264_DET_RUNS:-10}"
WORK="${X264_DET_WORK:-/tmp/x264-vbv-det}"
JOBS="${X264_DET_JOBS:-$(nproc)}"

mkdir -p "$WORK/out"

PASS=0; FAIL=0; SKIP=0
note() { echo "NOTE: $*"; }
pass() { PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $*"; }

# --------------------------------------------------------------------------
# one encode; prints md5 or ENCODE-ERROR.  args: OUTFILE -- CMD...
# (the x264 output option -o OUTFILE is appended by this function)
run1()
{
    local out="$1"; shift; shift
    "$@" -o "$out" >"$out.log" 2>&1 || { echo "ENCODE-ERROR"; return 1; }
    md5sum "$out" | cut -d' ' -f1
}

# byte_repeat LABEL REPS -- BINARY X264ARGS...
byte_repeat()
{
    local label="$1" reps="$2"; shift 2; shift
    local sums="" i s distinct
    for i in $(seq 1 "$reps"); do
        s=$(run1 "$WORK/out/rep_${label//[^a-zA-Z0-9]/_}_$i.264" -- "$@") \
            || { fail "$label (encode error)"; return; }
        sums="$sums $s"
    done
    distinct=$(echo $sums | tr ' ' '\n' | sort -u | wc -l)
    if [ "$distinct" = 1 ]; then pass "$label: $reps/$reps identical"
    else fail "$label: $distinct distinct outputs in $reps runs"; fi
}

# byte_identical LABEL -- BIN_A BIN_B -- X264ARGS...
byte_identical()
{
    local label="$1"; shift; shift
    local bina="$1" binb="$2"; shift 2; shift
    local sa sb tag="${label//[^a-zA-Z0-9]/_}"
    sa=$(run1 "$WORK/out/id_${tag}_a.264" -- "$bina" "$@") || { fail "$label (encode error, pre)"; return; }
    sb=$(run1 "$WORK/out/id_${tag}_b.264" -- "$binb" "$@") || { fail "$label (encode error, post)"; return; }
    if [ "$sa" = "$sb" ]; then pass "$label: pre == post"
    else fail "$label: pre != post"; fi
}

# CBR+VBV args per clip class
cbr_qcif() { echo "--bitrate 400 --vbv-maxrate 400 --vbv-bufsize 400"; }
cbr_720()  { echo "--bitrate 3000 --vbv-maxrate 3000 --vbv-bufsize 3000"; }

# CBR+VBV compliance cell for modes exempt from byte-determinism
# (paff-sliced-threads 5.2): encode with --nal-hrd cbr, then assert the
# independent Annex C CPB simulation passes and the log carries zero VBV
# underflow warnings.  hrd_check LABEL -- CMD...  (adds -o/--nal-hrd cbr).
hrd_check()
{
    local label="$1"; shift; shift
    local out="$WORK/out/hrd_${label//[^a-zA-Z0-9]/_}.264"
    if ! "$@" --nal-hrd cbr -o "$out" >"$out.log" 2>&1; then
        fail "$label: encode error (see $out.log)"; return
    fi
    local warn
    warn=$(grep -ci "VBV underflow" "$out.log" || true)
    if python3 "$REPO/tools/check_hrd.py" "$out" >"$out.hrd" 2>&1 \
       && [ "$warn" = 0 ]; then
        pass "$label: check_hrd clean, 0 underflow warnings"
    else
        fail "$label: hrd/warnings (count=$warn, see $out.hrd)"
    fi
}

# --------------------------------------------------------------------------
# baseline binary (pre-change), built from a git worktree, cached
baseline_bin()
{
    local dir="$WORK/baseline" reffile="$WORK/baseline.ref"
    if [ -z "$BASELINE_REF" ] && [ -f "$reffile" ]; then
        BASELINE_REF=$(cat "$reffile")
    fi
    [ -n "$BASELINE_REF" ] || BASELINE_REF=$PRE_CHANGE_REF
    if [ "$BASELINE_REF" = "$(git rev-parse HEAD)" ] && [ -z "$(git status --porcelain)" ]; then
        note "WARNING: baseline ref == HEAD with a clean tree; identity checks are self-comparison" >&2
    fi
    if [ -x "$dir/x264" ] && [ -f "$reffile" ] && [ "$(cat "$reffile")" = "$BASELINE_REF" ]; then
        note "baseline binary (cached): $dir/x264 @ $BASELINE_REF" >&2
        echo "$dir/x264"; return 0
    fi
    note "building baseline binary @ $BASELINE_REF in $dir (one-off)" >&2
    rm -rf "$dir"
    git worktree prune >&2   # clear stale registration if $dir was deleted externally
    git worktree add --detach "$dir" "$BASELINE_REF" >&2 || return 1
    ( cd "$dir" && ./configure >/dev/null 2>&1 ) || return 1
    # version.sh needs a .git DIRECTORY; a worktree has a .git file, so the
    # baseline's version came out empty and its version SEI would differ
    # from the binary under test.  Copy the main tree's version defines so
    # both binaries embed the identical string.
    sed -i '/^#define X264_\(REV\|REV_DIFF\|VERSION\|POINTVER\)/d' "$dir/x264_config.h"
    grep -E '^#define X264_(REV|REV_DIFF|VERSION|POINTVER)' "$REPO/x264_config.h" >> "$dir/x264_config.h"
    ( cd "$dir" && make -j"$JOBS" x264 >&2 ) || return 1
    echo "$BASELINE_REF" > "$reffile"
    echo "$dir/x264"
}

# --------------------------------------------------------------------------
# quality-matrix helpers

filler_py()
{
    cat > "$WORK/filler.py" <<'EOF'
import sys
data = open(sys.argv[1], 'rb').read()
n = len(data); i = 0; starts = []
while i < n - 4:
    if data[i] == 0 and data[i+1] == 0 and data[i+2] == 1:
        starts.append(i); i += 3
    elif data[i] == 0 and data[i+1] == 0 and data[i+2] == 0 and data[i+3] == 1:
        starts.append(i); i += 4
    else:
        i += 1
total = 0
for k, pos in enumerate(starts):
    s = pos + (4 if data[pos+2] == 0 else 3)
    if s >= n:
        break
    if data[s] & 0x1f == 12:  # filler_data_rbsp
        end = starts[k+1] if k+1 < len(starts) else n
        total += end - pos
print(total)
EOF
}

quality_metrics() # OUTFILE -> "bitrate psnr_y ssim_y filler"
{
    local out="$1" log="$1.log" br psnr ssim fill
    br=$(grep -o 'kb/s:[0-9.]*' "$log" | tail -1 | cut -d: -f2)
    psnr=$(grep -o 'PSNR Mean Y:[0-9.]*' "$log" | tail -1 | cut -d: -f2)
    ssim=$(grep -o 'SSIM Mean Y:[0-9.]*' "$log" | tail -1 | cut -d: -f2)
    fill=$(python3 "$WORK/filler.py" "$out")
    echo "${br:-NaN} ${psnr:-NaN} ${ssim:-NaN} ${fill:-NaN}"
}

# one matrix run; args: CSV CELL KIND IDX TARGET HRDCHECK -- BIN X264ARGS...
quality_run()
{
    local csv="$1" cell="$2" kind="$3" idx="$4" target="$5" hrdcheck="$6"
    shift 6; shift
    local out="$WORK/out/q_${cell}_${kind}_${idx}.264" m hrd=-1
    "$@" --psnr --ssim --nal-hrd cbr -o "$out" >"$out.log" 2>&1 \
        || { echo "$cell,$kind,$idx,$target,ERROR,,,," >> "$csv"; return; }
    m=$(quality_metrics "$out")
    if [ "$hrdcheck" = 1 ]; then
        python3 "$REPO/tools/check_hrd.py" "$out" >"$out.hrd" 2>&1 && hrd=0 || hrd=1
    fi
    echo "$cell,$kind,$idx,$target,$(echo $m | tr ' ' ','),$hrd" >> "$csv"
}

# internal worker entry: $0 __run CSV CELL KIND IDX TARGET HRDCHECK -- BIN ARGS...
if [ "${1:-}" = "__run" ]; then
    shift
    quality_run "$@"
    exit 0
fi

quality_matrix()
{
    local csv="$WORK/quality.csv" runlist="$WORK/quality.runs"
    : > "$csv"; : > "$runlist"
    filler_py

    # add_cell CELL TARGET X264ARGS... : 5 pre runs + 1 post run (+HRD check)
    add_cell()
    {
        local cell="$1" target="$2"; shift 2
        local i
        for i in 1 2 3 4 5; do
            printf '%s\n' "$(printf '%q ' "$0" __run "$csv" "$cell" pre $i "$target" 0 -- "$BASE" "$@")" >> "$runlist"
        done
        printf '%s\n' "$(printf '%q ' "$0" __run "$csv" "$cell" post 0 "$target" 1 -- "$X264" "$@")" >> "$runlist"
    }

    local bf t
    if [ -f "$CLIP1" ]; then
        for bf in 0 3; do for t in 4 8; do
            add_cell "clip1-bf$bf-t$t" 400 "$CLIP1" --input-res "$CLIP1_RES" \
                --bframes $bf --threads $t $(cbr_qcif)
        done; done
        add_cell "clip1-paff-tff-bf3-t8" 400 "$CLIP1" --input-res "$CLIP1_RES" \
            --paff --tff --bframes 3 --threads 8 $(cbr_qcif)
    else
        skip "clip1 quality cells ($CLIP1 missing)"
    fi
    if [ -f "$CLIP2" ]; then
        for bf in 0 3; do for t in 4 8; do
            add_cell "clip2-bf$bf-t$t" 400 "$CLIP2" --input-res "$CLIP2_RES" \
                --bframes $bf --threads $t $(cbr_qcif)
        done; done
    else
        skip "clip2 quality cells ($CLIP2 missing)"
    fi
    if [ -f "$CLIP720" ]; then
        for bf in 0 3; do for t in 4 8; do
            add_cell "720p-bf$bf-t$t" 3000 "$CLIP720" \
                --bframes $bf --threads $t $(cbr_720)
        done; done
    else
        skip "720p quality cells ($CLIP720 missing)"
    fi

    note "quality matrix: $(wc -l < "$runlist") encodes, $JOBS parallel jobs"
    xargs -d '\n' -P "$JOBS" -I CMD bash -c "CMD" < "$runlist"

    python3 - "$csv" <<'EOF'
import csv, sys, statistics
rows = [r for r in csv.reader(open(sys.argv[1])) if r]
cells = {}
for r in rows:
    if len(r) != 9:
        continue
    cell, kind, idx, target, br, psnr, ssim, fill, hrd = r
    c = cells.setdefault(cell, {'target': float(target), 'pre': [], 'post': []})
    c[kind].append(None if br == 'ERROR' else dict(
        br=float(br), psnr=float(psnr), ssim=float(ssim),
        fill=float(fill), hrd=int(hrd)))
fails = 0
if not cells:
    print("FAIL: quality matrix: no data rows"); sys.exit(1)
for cell in sorted(cells):
    c = cells[cell]
    if not c['pre'] or not c['post'] or any(r is None for r in c['pre'] + c['post']):
        print(f"FAIL: {cell}: encode error"); fails += 1; continue
    t = c['target']
    med = lambda k: statistics.median(r[k] for r in c['pre'])
    p = c['post'][0]
    d_br = abs((p['br'] - t) / t * 100 - (med('br') - t) / t * 100)
    d_psnr = abs(p['psnr'] - med('psnr'))
    d_ssim = abs(p['ssim'] - med('ssim'))
    ok = (d_br <= 0.5 and d_psnr <= 0.05 and d_ssim <= 0.002
          and p['fill'] <= med('fill') and p['hrd'] == 0)
    if not ok:
        fails += 1
    print(f"{'PASS' if ok else 'FAIL'}: {cell}: "
          f"|dBrErr|={d_br:.3f}% |dPSNR|={d_psnr:.4f}dB |dSSIM|={d_ssim:.5f} "
          f"fill {p['fill']:.0f}<={med('fill'):.0f} "
          f"hrd={'clean' if p['hrd'] == 0 else 'VIOLATION'} "
          f"(br pre-med {med('br'):.2f} / post {p['br']:.2f} / target {t:.0f})")
sys.exit(1 if fails else 0)
EOF
    if [ $? -ne 0 ]; then
        fail "quality matrix has exceedances (cells matching the deltas documented in doc/threads.txt are expected vs the pre-change baseline; investigate anything else)"
    else
        pass "quality matrix within thresholds"
    fi
}

# ==========================================================================
# main
# ==========================================================================

QUALITY=0
BASELINE_REF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quality) QUALITY=1 ;;
        --baseline-ref) BASELINE_REF="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

echo "== threaded-VBV determinism: byte-repeat (binary under test: $X264) =="
[ -x "$X264" ] || { echo "binary under test not found: $X264" >&2; exit 2; }
X264=$(readlink -f "$X264")

if [ -f "$CLIP1" ]; then
    for bf in 0 3; do
        for n in 2 4 8 16; do
            byte_repeat "repeat clip1 bf$bf t$n" "$RUNS" -- \
                "$X264" "$CLIP1" --input-res "$CLIP1_RES" \
                --bframes $bf --threads $n $(cbr_qcif)
        done
    done
else
    skip "clip1 byte-repeat cells ($CLIP1 missing)"
fi

if [ -f "$CLIP720" ]; then
    byte_repeat "repeat 720p bf3 t8" "$RUNS" -- \
        "$X264" "$CLIP720" --threads 8 $(cbr_720)
else
    skip "720p byte-repeat cell ($CLIP720 missing)"
fi

if [ -f "$CLIP1" ]; then
    for bf in 0 3; do
        for n in 2 4 8; do
            byte_repeat "repeat clip1 PAFF-TFF bf$bf t$n" "$RUNS" -- \
                "$X264" "$CLIP1" --input-res "$CLIP1_RES" --paff --tff \
                --bframes $bf --threads $n $(cbr_qcif)
        done
    done
    byte_repeat "repeat clip1 PAFF-BFF bf3 t8" "$RUNS" -- \
        "$X264" "$CLIP1" --input-res "$CLIP1_RES" --paff --bff \
        --bframes 3 --threads 8 $(cbr_qcif)
fi

# PAFF + sliced threads (paff-sliced-threads 5.2).  Small clips clamp N to
# the field-row cap (a 240-line clip caps at 2); the clamped cells still
# gate repeatability of the effective configuration.
if [ -f "$CLIP1" ]; then
    echo
    echo "== PAFF+sliced: non-VBV byte-repeat, CBR+VBV compliance =="
    for bf in 0 3; do
        for mode in "--crf 23" "--qp 22"; do
            for n in 2 4 8; do
                byte_repeat "repeat clip1 PAFF-sliced [${mode}] bf$bf t$n" "$RUNS" -- \
                    "$X264" "$CLIP1" --input-res "$CLIP1_RES" --paff --tff --sliced-threads \
                    --bframes $bf --threads $n $mode
            done
        done
    done
    # ABR-without-VBV is byte-repeatable too (avoids the sliced VBV live reads)
    for n in 2 4; do
        byte_repeat "repeat clip1 PAFF-sliced ABR bf0 t$n" "$RUNS" -- \
            "$X264" "$CLIP1" --input-res "$CLIP1_RES" --paff --tff --sliced-threads \
            --bframes 0 --threads $n --bitrate 400
    done
    # CBR+VBV inherits the progressive sliced-threads exception (cross-slice
    # live reads of bits_so_far/frame_size_estimated): assert HRD compliance
    # instead of byte-repeat.
    for n in 2 4; do
        hrd_check "clip1 PAFF-sliced CBR bf0 t$n" -- \
            "$X264" "$CLIP1" --input-res "$CLIP1_RES" --paff --tff --sliced-threads \
            --bframes 0 --threads $n $(cbr_qcif)
    done
else
    skip "clip1 PAFF+sliced cells ($CLIP1 missing)"
fi

if [ -f "$CLIP720" ]; then
    # Overshoot robustness (D4 floor), two flavours on the multi-band size:
    #  a) undersized buffer, still compliant: check_hrd must pass, warnings
    #     recorded as a number (NOT compared: the floor by design spends
    #     bits a frame-threaded pass 1 would not).
    #  b) qpmax-capped overshoot forcing the 5% floor to actually bind:
    #     compliance is impossible by construction (the encoder cannot
    #     raise QP), so the gates are no-crash and no-NaN/negative budgets,
    #     with the warning count recorded.
    ov="$WORK/out/overshoot_small.264"
    if "$X264" "$CLIP720" --frames 40 --paff --tff --sliced-threads --bframes 0 \
            --threads 4 --bitrate 3000 --vbv-maxrate 3000 --vbv-bufsize 300 \
            --nal-hrd cbr -o "$ov" >"$ov.log" 2>&1 \
       && python3 "$REPO/tools/check_hrd.py" "$ov" >"$ov.hrd" 2>&1; then
        note "PAFF-sliced overshoot (undersized bufsize 300): $(grep -ci 'VBV underflow' "$ov.log" || true) underflow warnings (recorded, not compared)"
        pass "720p PAFF-sliced undersized-bufsize: check_hrd clean"
    else
        fail "720p PAFF-sliced undersized-bufsize: encode/HRD (see $ov.hrd)"
    fi
    ov="$WORK/out/overshoot_floor.264"
    if "$X264" "$CLIP720" --frames 40 --paff --tff --sliced-threads --bframes 0 \
            --threads 4 --bitrate 600 --vbv-maxrate 600 --vbv-bufsize 600 --qpmax 26 \
            --nal-hrd cbr --log-level debug -o "$ov" >"$ov.log" 2>&1 \
       && python3 - "$ov.log" <<'PYEOF'
import re, sys
plans = []
for l in open(sys.argv[1]):
    m = re.search(r'pass (\d) plan ([-\w.]+) bits \(pair plan ([-\w.]+)\)', l)
    if m:
        try:
            plans.append((int(m.group(1)), float(m.group(2)), float(m.group(3))))
        except ValueError:
            print('non-numeric budget line:', l.strip()); sys.exit(1)
bad = [p for p in plans if p[1] <= 0 or p[2] <= 0 or p[1] != p[1] or p[2] != p[2]]
floored = [p for p in plans if p[0] == 1 and p[1] <= 0.05 * p[2] + 1]
if bad:
    print('NaN/non-positive budgets:', bad[:3]); sys.exit(1)
if not floored:
    print('the 5% floor never bound'); sys.exit(1)
print(f'{len(plans)} budget lines, floor bound on {len(floored)} pass-1 pairs')
PYEOF
    then
        note "PAFF-sliced overshoot (qpmax-forced): $(grep -ci 'VBV underflow' "$ov.log" || true) underflow warnings (recorded, not compared)"
        pass "720p PAFF-sliced qpmax-forced overshoot: no crash/NaN, floor exercised"
    else
        fail "720p PAFF-sliced qpmax-forced overshoot: see $ov.log"
    fi
else
    skip "720p PAFF+sliced cells ($CLIP720 missing)"
fi

echo
echo "== pre/post byte-identity (baseline vs binary under test) =="
BASE=$(baseline_bin) || { echo "baseline build failed" >&2; exit 2; }

ident_cells()
{
    local clip="$1" res="$2" tag="$3"
    # 4.3: t1 CBR+VBV byte-identity pre/post
    byte_identical "identity $tag t1 CBR+VBV" -- "$BASE" "$X264" -- \
        "$clip" --input-res "$res" --threads 1 $(cbr_qcif)
    # 4.4: non-VBV modes byte-identity pre/post, t1 and threaded
    local mode n
    for mode in "--crf 23" "--qp 22" "--bitrate 400"; do
        for n in 1 8; do
            byte_identical "identity $tag [$mode] t$n" -- "$BASE" "$X264" -- \
                "$clip" --input-res "$res" $mode --threads $n
        done
    done
    # PAFF variants: the committed-check helper has a PAFF branch and the
    # pre-change tree has PAFF too, so PAFF must also stay byte-identical.
    byte_identical "identity $tag PAFF t1 CBR+VBV" -- "$BASE" "$X264" -- \
        "$clip" --input-res "$res" --paff --tff --threads 1 $(cbr_qcif)
    byte_identical "identity $tag PAFF t8 crf23" -- "$BASE" "$X264" -- \
        "$clip" --input-res "$res" --paff --tff --crf 23 --threads 8
    # paff-sliced-threads (task 5.3): progressive sliced (the shared
    # dispatch/deblock paths) and PAFF non-sliced at both drivers
    # (monolithic t1, frame threads) must stay byte-identical pre/post.
    for n in 2 4; do
        byte_identical "identity $tag progressive-sliced t$n crf23" -- "$BASE" "$X264" -- \
            "$clip" --input-res "$res" --sliced-threads --threads $n --crf 23
    done
    byte_identical "identity $tag PAFF t4 crf23" -- "$BASE" "$X264" -- \
        "$clip" --input-res "$res" --paff --tff --crf 23 --threads 4
}

if [ -f "$CLIP1" ]; then ident_cells "$CLIP1" "$CLIP1_RES" "clip1"; fi
if [ -f "$CLIP2" ]; then ident_cells "$CLIP2" "$CLIP2_RES" "clip2"; else skip "clip2 identity cells ($CLIP2 missing)"; fi

if [ "$QUALITY" = 1 ]; then
    echo
    echo "== quality matrix (task 5.1) =="
    quality_matrix
fi

echo
echo "== summary: $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" = 0 ]
