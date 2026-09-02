# Design: paff-mbtree-remeasure

## Context

See proposal.md. The measurement itself is already done (2026-08-30 session,
stand in `/tmp/paff_mb`); this design records the protocol so it can be
re-run, and pins down how the results are written into the tree. The change is
docs + tooling only, so the design focus is the measurement protocol (what
exactly was measured and why the gates are shaped this way) and the
measurement pitfall we hit, which the stand must avoid.

## Goals / Non-Goals

**Goals:**
- Preserve the measurement as a reproducible stand (`tools/test_paff.sh mbtree`
  + `tools/bdrate.py`), clips supplied via env vars like the other cells.
- Close the "Per-field mbtree propagation" future-work item in `doc/paff.txt`
  with the recorded numbers and the pre-registered gates.
- Update the `macroblock_tree_propagate` comment so it cites the measurement.

**Non-Goals:**
- Any encoder code change (the whole point: nothing to fix).
- Per-field lowres/lookahead work (explicitly rejected by the measurement).
- Expanding the clip corpus further, or SSIM-based gates (PSNR-Y matched the
  existing quality sections and is sufficient for a relative gate).

## Decisions

### D1: Protocol (pre-registered before measuring, weightb2-style)

Clips (all real broadcast/user content, interlaced variants synthesized by
field-merging adjacent progressive frames — true temporal field separation):

| clip     | source                     | synth                                    | out |
|----------|----------------------------|------------------------------------------|-----|
| hall     | `/mnt/store2/ts/hall.mp4` 720p25  | `scale=1280:360,tinterlace=merge` (first 800 frames) | 400f 1280x720 TFF @12.5 fps |
| relax    | `/mnt/store2/ts/relax.mp4` 1080p50 | `scale=1920:540,tinterlace=merge` @t=300s | 400f 1920x1080 TFF @25 fps (true 50 Hz field cadence) |
| amv      | `/mnt/store2/ts/amv1.mp4` 720p29.97 | `scale=1280:360,tinterlace=merge` @t=60s | 400f 1280x720 TFF @15000/1001 fps, hard cuts every 2-4 frames |

(Frame counts corrected post-measurement against the archived clips: the
interlaced variants carry 400 coded frames, not 200 -- the table above
originally said "frames 1-400, 200f".  The progressive controls are 200
frames of the same segment (relax resampled to 25 fps first); only G0 uses
them, so the count asymmetry touches no gate.)

Progressive controls: same segments without tinterlace.

Matrix: prog / MBAFF (`-flags +ildct`) / PAFF (`-paff 1`) x mbtree on/off x
CRF {18,23,28,33}, preset medium, default threads, via the patched ffmpeg
(`~/dev/FFmpeg`, libx264 from this tree). Metrics: PSNR-Y + bitrate per cell,
BD-rate (4-point cubic, `tools/bdrate.py`) for comparisons.

Gates, fixed before measuring:
- **G0 (rig control):** mbtree on-vs-off on the progressive control must give
  BD-rate <= -3%, else the stand can't see mbtree and results are void.
- **Q1 (replication of the paff-b-frames 4.2 bound on real content):** PAFF vs
  MBAFF on the interlaced clip, mbtree on; PAFF must not be worse than MBAFF
  by > 1% BD-rate.
- **Q2 (the actual question):** mbtree gain (BD-rate on vs off) of PAFF vs
  prog *on the same interlaced clip*. Ratio >= 0.50 means the ~2x pair-level
  weight error does not measurably impair mbtree under PAFF. (0.50 is a
  judgment call, recorded here like weightb2's 1.0% floor.)  Denominator
  guard, pre-registered with the rest: if |prog gain| < 1% BD-rate on a
  clip, that clip is inconclusive for Q2 -- the ratio is noise when mbtree
  does nothing in weave mode anyway.

### D2: Results (measured 2026-08-30, Ryzen-class machine)

| gate | hall | relax | amv |
|------|------|-------|-----|
| G0   | -13.2% | -12.0% | -16.7% |
| Q1 (mbtree on)  | -16.6% | -11.0% | -12.7% |
| Q1 (mbtree off) | -15.5% | -10.5% | -10.7% |
| Q2 prog gain   | -5.26%  | -10.00% | -4.36% |
| Q2 MBAFF gain  | -8.86%  | -9.73%  | -8.30% |
| Q2 PAFF gain   | -10.37% | -9.76%  | -10.61% |
| Q2 ratio PAFF/prog | 1.97 | 0.98 | 2.43 |

The Q1 (mbtree off) row is informational: it checks that the PAFF/MBAFF
gap is not an mbtree artifact; no gate is registered on it.

All gates pass on all three clips. PAFF's mbtree gain is never below
progressive's; on cut-heavy content (amv) it is 2.4x progressive's. The ~2x
per-field weight error is arithmetically real but buys no measurable deficit.

### D3: Close, don't fix

The future-work item moves to "Measured and closed". Rationale: implementing
per-field propagation (any variant — duration fudge, per-field qp_offset maps,
field-level lowres DAG) would change every PAFF bitstream and invalidate the
regression corpus, in exchange for a gain the measurement says does not exist.
Same outcome class as weightb, except nothing needs disabling — the existing
code already performs at full strength. The D3 gate from paff-b-frames ("pull
per-field work into scope only if the bound fails") is thereby resolved: the
bound holds on three real clips, work stays out of scope permanently unless a
future regression makes it fail.

### D4: PSNR pairing must be timestamp-free (measurement pitfall)

First amv run produced flat ~17.9 dB garbage. Root cause: ffmpeg's dual-input
`psnr`/`ssim` filters pair frames by PTS through framesync; a 30000/1001 y4m
round-tripped through mkv (1/1000 timebase) mis-pairs every few frames, and on
cut-heavy content each mis-pair is a 1000+ MSE spike that dominates the mean.
Frame-exact python comparison proved the bitstream was perfect (dec k == ref k,
MSE < 1). Fix, mandatory in the stand: decode both sides to rawvideo first,
then run psnr on the rawvideo inputs (framerate forced equal). 25/12.5 fps
clips paired fine (their frame durations are exact in the mkv timebase — spot
checks confirmed), but the stand uses the rawvideo pipe uniformly so the trap
can't fire again.

### D5: Stand integration

`tools/test_paff.sh mbtree` follows the existing cell conventions: clip paths
via env vars, missing clip = cell skipped.

- **Encoding** goes through the x264 CLI (`$X264`), not the patched ffmpeg:
  the libx264 wrapper is one less variable, and `--paff` / `--interlaced`
  map one-to-one.  (The session itself went through the wrapper, which is
  why its PSNR pairing had to fight container timestamps -- D4.)
- **PSNR-Y is measured externally**: each output is decoded and compared
  against the reference with ffmpeg's psnr filter over rawvideo inputs
  (the D4-safe recipe, and exactly the session's statistic).  x264's own
  `--psnr` was considered and rejected: its `PSNR Mean Y` is a mean of
  per-picture PSNRs (per-FIELD pictures under PAFF), while the session
  statistic is PSNR of pooled per-frame MSE -- the two differ by ~1 dB
  content-dependently (measured on a testsrc2 probe), which would silently
  re-baseline every gate and break the "reproduces D2" promise.
- **kbps** is computed from output bytes and per-clip duration constants
  kept next to each clip's synthesis recipe.  The session's constants
  assumed 200-frame interlaced clips while the archived clips actually
  carry 400 (hall_i/amv_i kbps were 2x true); the stand uses true
  durations (frames/fps).  Either way BD-rate is invariant to a per-clip
  kbps scale, so no gate moves.
- **Threads stay at default** (session protocol).  Numbers are therefore
  machine-dependent -- thread count changes the PAFF MV-range clamp; the
  gates carry wide margins and the stand says so in its header.
- **Gate semantics** (weightb2 model): G0 is a validity check and aborts
  non-zero -- a stand that cannot see mbtree must be loud.  Q1/Q2 are
  report-only PASS/FAIL with exit 0: the closure decision is already taken
  and recorded, the stand is evidence-on-demand, not CI.
- The always-run lavfi testsrc2 smoke clip is a pipeline self-check only:
  the matrix runs to completion, PSNR lines parse, the CRF-18 progressive
  sanity bound holds; no gates are asserted and the output is labeled
  `SMOKE (synthetic) -- gates not asserted`.
- The session's point sets and reference scripts are archived in the
  change's `measurement/` directory (`/tmp/paff_mb` was volatile);
  `bdrate.py` verification runs against the archived copy.  `bdrate.py`
  is pure python stdlib (no numpy in this environment).

## Risks / Trade-offs

- [Closing a future-work item makes it invisible] → Mitigation: the doc keeps
  the full protocol + numbers and the stand stays in-tree, so the question is
  re-answerable in one command if anyone doubts it.
- [Three clips is not the universe] → Accepted: same evidence level as the
  weightb closure; the gate is "no deficit found where mbtree matters most",
  not a proof over all content.
- [Stand depends on external clips] → Same convention as existing cells:
  missing clip = skipped, CI unaffected.

## Open Questions

None.
