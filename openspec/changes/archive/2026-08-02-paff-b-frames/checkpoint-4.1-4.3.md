# Checkpoint findings — paff-b-frames tasks 4.1 / 4.2 / 4.3

> **✅ REGRESS RESOLVED (task 2.5).** The drift reported below was
> root-caused to the PAFF **P-field reference list**, not to deblock
> (`deblock.c` unchanged; the drift was luma+chroma and present with
> `--no-deblock` too, contrary to the banner's analysis).  Two bugs,
> both triggered by a BREF in the DPB (`--b-pyramid strict/normal`):
> (a) the P-field L0 was expanded from the POC-distance-ordered,
> `i_frame_reference`-capped pair list, but §8.2.4.2.2 orders a P field's
> refFrameList0ShortTerm by FrameNumWrap DESCENDING over the FULL DPB —
> with a BREF (higher frame_num, lower POC) the decoder's default list
> diverges while no ref_pic_list_modification is signalled (DEC-C); fixed
> by rebuilding the past list from `h->frames.reference` sorted by
> FrameNumWrap (8-27) in the PAFF driver.  (b) `reference_hierarchy_reset`
> evicted the old BREF from `frames.reference` IMMEDIATELY (strict
> pyramid), but its MMCO rides in the current picture's field-1 header
> and the decoder applies it AFTER building that field's list (8.2.4
> before 8.2.5); fixed by deferring the shift to the inter-pass D20
> marking.  **Result: 14/14 PAFF configs byte-exact** vs `--dump-yuv`
> (ffmpeg): TFF+BFF, hierarchical B GOPs, `--b-pyramid none/normal/strict`,
> `--ref 1-4`, all direct modes, CAVLC+CABAC, `--keyint 8/24`, 120-frame
> streams (frame_num wrap), `--no-deblock`.  checkasm8/10 green; non-PAFF
> (progressive, MBAFF, strict pyramid, ultrafast) bit-identical to the
> pre-fix build.  Task 4.1 re-closed.

> **🔴 REGRESS found on re-test (this session) — read first.** Re-running
> the round-trip on the current source tree: PAFF **B field GOPs do NOT
> round-trip byte-exact** vs `--dump-yuv` (oracle: ffmpeg), and neither do
> PAFF **P** pictures once `--ref 1` starts evicting (~frame 6+). The drift is
> **chroma-only** (luma, MBAFF and progressive are byte-exact; `--no-deblock`
> is byte-exact, so the defect is in the deblock operation, not in
> reconstruction/MC). Reproducer (128×64, PAFF TFF, ffmpeg 8.x):
> ```sh
> ./x264 in.yuv --input-res 128x64 --frames 4 --paff --tff --qp 24 \
>     --bframes 2 --ref 1 --direct spatial --dump-yuv d.yuv -o o.264
> ffmpeg -y -i o.264 -f rawvideo -pix_fmt yuv420p dec.yuv
> cmp d.yuv dec.yuv   # DIFFERS (chroma only)
> ```
> The earlier "24/24 configs byte-exact" claim below (SUPERSEDED banner) **does
> not reproduce** on the current source. `deblock.c` was not touched by this
> change; the field-chroma deblock path is the prime suspect. Task **2.5** is
> opened to fix it; **4.1 is reopened.** Forensic notes retained below.

> **⚠️ SUPERSEDED (later session) — read first.** The findings below were
> written BEFORE four in-scope PAFF conformance bugs were found and fixed:
> (a) mvpred `--ref 1` segfault, (b) field-PicNum `CurrPicNum = 2*frame_num+1`,
> (c) B-field reference-list construction (§8.2.4.2.4/8.2.4.2.5), (d) inter-pass
> sliding-window threshold. **Current reality:** ffmpeg decodes PAFF **I/P AND
> B field GOPs byte-exact** vs `--dump-yuv` — including hierarchical
> `--b-pyramid normal`, TFF+BFF, `--ref 1/2/3`, all direct modes (24/24
> configs). The earlier “PAFF P-only fails / pre-existing non-conformance”
> conclusion was WRONG: PAFF I/P was always conformant; **JM 19.0 `ldecod` is
> itself buggy for PAFF** (it grays out bottom fields on conformant streams),
> so it cannot serve as the PAFF oracle — ffmpeg is used instead (see
> `CONTEXT.md`). Tasks 4.1 and 2.4 are now considered done in substance.
> The detailed forensic notes below are retained for provenance only.

Run on branch `paff-core-ip-spec-review`, working tree = full paff-b-frames
implementation (621 insertions, uncommitted). x264/checkasm8/checkasm10 rebuilt
clean from current source before testing. JM reference decoder **was available**
(`/tmp/JM/bin/ldecod.exe`, JM 19.0 FRExt) — so the round-trip was actually run,
not just documented.

## Summary table

| task | runnable? | result |
|------|-----------|--------|
| 4.3 checkasm + non-PAFF bit-identity | **RUNNABLE, PASS** | checkasm8/10 green; 6/6 non-PAFF configs byte-identical vs pre-paff-b-frames baseline. |
| 4.1 JM round-trip bit-exact (TFF/BFF) | **BLOCKED** (pre-existing PAFF non-conformance) | Progressive sanity round-trip is **BIT-IDENTICAL** (procedure validated). PAFF P-only **and** B-field streams do **not** round-trip — JM `ldecod` warns `zero_byte shall exist`, drifts `num_ref_idx_l0_active`, aborts with *"Max. number of reference frames exceeded. Invalid stream."*, and (B-field) **segfaults**. Not a paff-b-frames regression: P-only fields fail too. |
| 4.2 PSNR/SSIM vs MBAFF | **PARTIALLY RUN** (synthetic clip) | First measurement taken on a woven-interlaced synthetic clip: PAFF-B is within **~0.2–0.3 dB PSNR** of MBAFF across QP 20–32 (comfortably inside any reasonable D3 bound). Real interlaced test set still needed for the bound to be authoritative. |
| 2.4 JM B-field direct-mode checklist | doc written | `jm-checklist.md`. |

---

## 4.3 — checkasm + non-PAFF bit-identity  ✅ PASS

```
./checkasm8  -t1   →  x264: All tests passed Yeah :)   (exit 0)
./checkasm10 -t1   →  x264: All tests passed Yeah :)   (exit 0)
```

Non-PAFF bit-identity: encode `/tmp/in.yuv` (128×72, 6 frames, seed 42) with
the **current** paff-b-frames binary, then `git stash` the implementation,
**clean-rebuild** the pre-paff-b-frames baseline (HEAD = `b4a9c2d0`), re-encode
the same configs, `git stash pop`, rebuild, and `cmp`. (A plain `make` after
`stash` does **not** recompile — the `.o` files keep a newer mtime, so the
objects must be force-removed before rebuilding the baseline.)

| config (non-PAFF) | cmp vs baseline |
|---|---|
| progressive default | **IDENTICAL** (38823 B) |
| progressive `--bframes 3 --b-pyramid normal --ref 3 --direct temporal` | **IDENTICAL** (38823 B) |
| progressive `--direct spatial --weightb --subme 9` | **IDENTICAL** (39225 B) |
| `--interlaced --tff --bframes 2` (MBAFF) | **IDENTICAL** (41542 B) |
| `--interlaced --bframes 0 --preset ultrafast` (MBAFF) | **IDENTICAL** (60772 B) |
| `--output-depth 10` (multi-depth build: `X264_BIT_DEPTH=0`) | **IDENTICAL** (38795 B) |

→ paff-b-frames leaves non-PAFF (progressive + MBAFF + 10-bit) output
bit-identical. **4.3 passes.**

---

## 4.1 — JM round-trip bit-exact  ❌ BLOCKED (pre-existing PAFF non-conformance)

### Procedure validated on progressive (sanity)
```
x264 seq.yuv --input-res 128x72 --frames 30 --threads 1 \
    --preset medium --bframes 3 --b-pyramid normal --ref 3 --direct temporal \
    --dump-yuv prog_fdec.yuv -o prog.264
ldecod.exe -d decoder.cfg -p InputFile="prog.264" -p OutputFile="prog_ref.yuv" \
           -p RefFile="prog_fdec.yuv" -p Silent=1
cmp prog_fdec.yuv prog_ref.yuv   →  BIT-IDENTICAL (30/30 frames, 0 warnings)
```
This proves the `--dump-yuv` / ldecod / `cmp` pipeline and JM 19.0 are a
trustworthy oracle.

### PAFF does NOT round-trip (P-only **and** B-field)

ffmpeg reproduction (matches the prior chunk's finding):
```
ffmpeg -i paff_p.264 -f rawvideo -pix_fmt yuv420p out.yuv
  → [h264] error while decoding MB 1 5, bytestream -39
  → corrupt decoded frame ; decoded 1/30 frames
```

JM `ldecod` (the actual conformance oracle) **also** fails:
- **PAFF P-only** (`--paff --tff --bframes 0 --ref 2 --qp 24`): decodes with
  `warning: zero_byte shall exist` on **every** frame, `num_ref_idx_l0_active`
  drifts (1→3→4→5 — wrong active-count signalling), then
  *"Max. number of reference frames exceeded. Invalid stream."* and produces a
  wrong frame count (17 vs 16). `cmp` → DIFFERS.
- **PAFF B-field** (`--paff --tff --bframes 2 --qp 24`): same warnings, then
  **ldecod SEGFAULTS** (exit 244) after frame 4.

Defect categories: (a) missing leading `zero_byte` before certain NAL start
codes (Annex B), (b) wrong `num_ref_idx_l0_active` in the slice header, (c) DPB
overflow / broken reference marking. All present on **P-only** fields → the root
cause is in the `paff-field-references` / `paff-core-ip` lineage, **not** in
paff-b-frames' B-field work.

### Two x264 ENCODER crashes found (deterministic)

1. `--paff --ref 1` (any B-frame setting incl. `--bframes 0`) → **SEGFAULT**
   (rc 139), truncated 8 KiB stream. Pre-existing PAFF single-reference bug.
2. `--paff --bframes 3 --b-pyramid normal --ref {1,2}` → **SEGFAULT** (3/3 runs).
   This is exactly the **BREF MMCO eviction** scenario named in task 2.4
   ("`--ref 2 --b-pyramid normal` reaching the DPB cap"). `--ref ≥ 3` is fine.
   → the crash is in the BREF-eviction path (task 2.1, per-field MMCO opcode
   emission). Blocks task 2.4 row 9 and is a real bug to fix.

### Status
**4.1 stays `[ ]` / BLOCKED.** Two independent blockers, neither caused by this
change's B-field logic:
1. Pre-existing PAFF bitstream non-conformance (P-only fails JM). Must be fixed
   upstream in the PAFF lineage before any PAFF stream can round-trip.
2. x264 encoder segfaults on `--paff --ref 1` and on the BREF-eviction config
   (`--b-pyramid normal --ref ≤2`).

Caveat noted: do not read x264's exit code through `| tail` — the pipe returns
`tail`'s rc (0) and hides the segfault. Always `x264 … >log 2>&1; echo $?`.

---

## 4.2 — PSNR/SSIM vs MBAFF  🟡 PARTIAL (first measurement)

Synthesised a genuinely-interlaced clip by weaving fields from two moving
progressive sequences in Python (30 frames, 128×72, top field = prog[2n],
bottom field = prog[2n+1]; verified rows differ). Ran x264 PAFF-B and MBAFF
with `--psnr --ssim`, CQP sweep, `--threads 1`:

| QP | mode | kb/s | PSNR Avg | SSIM Y |
|----|------|------|----------|--------|
| 20 | MBAFF b2      | 1784.71 | 43.343 | 0.9916828 |
| 20 | **PAFF-B b2** | 1771.65 | 43.198 | 0.9914314 |
| 24 | MBAFF b2      | 1498.15 | 39.355 | 0.9786418 |
| 24 | **PAFF-B b2** | 1483.13 | 39.193 | 0.9777409 |
| 28 | MBAFF b2      | 1213.88 | 35.238 | 0.9431903 |
| 28 | **PAFF-B b2** | 1200.82 | 35.055 | 0.9399500 |
| 32 | MBAFF b2      |  936.71 | 30.965 | 0.8177761 |
| 32 | **PAFF-B b2** |  920.47 | 30.710 | 0.8040234 |

**Δ(PSNR) = PAFF-B − MBAFF ≈ −0.15 / −0.16 / −0.18 / −0.26 dB** at QP
20/24/28/32, and PAFF-B is at slightly *lower* bitrate at each QP (so the
rate-distortion gap is even smaller). On SSIM-dB the gap is ≤ 0.4 dB.

→ On this synthetic clip, **PAFF-B sits comfortably within ~0.3 dB of MBAFF**.
Per D3 the threshold is "recorded from the first measurement"; this first
measurement gives a bound on the order of **0.3 dB PSNR / 0.4 dB SSIM**, which
would be PASSED — i.e. the per-field lowres work (D1 / task 3.1) does **not**
need to be pulled into scope on this evidence.

### Caveats (why 4.2 is not fully closed)
- Synthetic 128×72 × 30-frame clip woven from progressive — **not** the real
  interlaced test set; numbers are a first-measurement sanity bound only.
- `--psnr` ran with psy on (x264 warns); affects both encoders equally so the
  *relative* comparison holds, but absolute PSNR is not psy-free.
- PSNR is x264's self-reported reconstruction quality; the PAFF streams are
  non-JM-conformant (4.1), so this is not a decoder-validated measurement.
- **`--b-pyramid normal` is inert under PAFF**: PAFF-B `b2` and `bpyr` produce
  byte-identical output (same kb/s/PSNR/SSIM) at every QP, whereas MBAFF shows
  a small b2↔bpyr difference. The pyramid structure is not being applied to
  field pictures — separate bug to investigate, does not affect the b2
  comparison above.

### What "done" looks like for 4.2
Re-run the sweep on the project's real interlaced test set (or a proper
`tinterlace`-derived clip at full resolution), record the BD-rate/BD-PSNR of
PAFF-B vs MBAFF, and confirm it stays within the bound recorded above. PAFF
bitstream conformance (4.1) should be fixed first so the PSNR is decoder-
validated.

---

## How to reproduce

```sh
cd /home/hizel/dev/x264
make -j$(nproc) x264 checkasm8 checkasm10
./checkasm8  -t1 && ./checkasm10 -t1          # 4.3 gate
# 4.1 progressive sanity (expect BIT-IDENTICAL):
./x264 /tmp/seq.yuv --input-res 128x72 --frames 30 --threads 1 \
  --bframes 3 --b-pyramid normal --ref 3 --direct temporal \
  --dump-yuv /tmp/jmtest/prog_fdec.yuv -o /tmp/jmtest/prog.264
/tmp/JM/bin/ldecod.exe -d /tmp/JM/bin/decoder.cfg \
  -p InputFile=\"/tmp/jmtest/prog.264\" -p OutputFile=\"/tmp/jmtest/prog_ref.yuv\" \
  -p RefFile=\"/tmp/jmtest/prog_fdec.yuv\" -p Silent=1
cmp /tmp/jmtest/prog_fdec.yuv /tmp/jmtest/prog_ref.yuv
# 4.1 PAFF (expect DIFFERS / ldecod crash):
./x264 /tmp/seq.yuv --input-res 128x72 --frames 16 --threads 1 \
  --paff --tff --bframes 2 --qp 24 --dump-yuv /tmp/jmtest/pb_fdec.yuv -o /tmp/jmtest/pb.264
/tmp/JM/bin/ldecod.exe -d /tmp/JM/bin/decoder.cfg \
  -p InputFile=\"/tmp/jmtest/pb.264\" -p OutputFile=\"/tmp/jmtest/pb_ref.yuv\" \
  -p RefFile=\"/tmp/jmtest/pb_fdec.yuv\" -p Silent=1 ; echo "ldecod rc=$?"
# 4.2 sweep: see table above (interlaced.yuv = /tmp/jmtest/interlaced.yuv)
```
