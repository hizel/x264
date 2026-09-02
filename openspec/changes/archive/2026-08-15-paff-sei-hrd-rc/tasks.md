# Tasks: PAFF — SEI/HRD per field, rate control, threading, docs

Dependency-ordered; ends with the full-matrix checkpoint. See `design.md` for
decisions D1–D5.

## 1. SEI and HRD per field

- [x] 1.1 Move SEI emission to per-access-unit (field): `pic_timing` with
      `pic_struct=1/2` (Table D-1), `NumClockTS=1`
- [x] 1.2 `buffering_period` + CPB/DPB delays in field units; verify with
      `--nal-hrd cbr` streams
- [x] 1.3 `dec_ref_pic_marking` SEI: write true `original_field_pic_flag`/parity
      (fix hardcoded 0, `encoder/set.c:803`).  NOTE: the SEI's only trigger
      (BREF pair carrying MMCO, `--bluray-compat`) is unreachable in practice
      in current x264 -- upstream logic never gives a BREF slice MMCO
      commands.  Writer verified via a forced trigger on P pairs: TFF/BFF
      parity flags correct, repeated opcodes carry field PicNums, JM parses.
- [x] 1.4 Timecode/pulldown interaction audit (D4): document unsupported
      pulldown modes under PAFF, validate in param check.
      Audit results: CLI `--pulldown` rejected under PAFF (patterns have no
      frame picture to attach to); library per-frame `pic.i_pic_struct !=
      AUTO` clamped to AUTO with a one-shot warning (pair resolves to
      TB/BT); `--tcfile-in/out`, `--timebase`, VFR verified working at
      pair-level PTS (JM round-trip OK); `param.b_pulldown` alone
      (timebase-only) is harmless and stays allowed.

## 2. Rate control and VBV

- [x] 2.1 RC per field pair (D2): frame-level QP with per-field QP rows; bit
      accounting per field; 2-pass stats per field. **Carry-over from
      `paff-field-references`:** two 2-pass-only gaps it left `ponytail:`'d —
      (a) `b_ref_pic_list_reordering[0]` is forced to 0 in the PAFF driver, so
      if `x264_reference_build_list_optimal` reorders the pair list the expanded
      field list no longer equals the decoder's default → emit field-PicNum
      `ref_pic_list_modification` commands (§8.2.4.3) or disable optimal reorder
      for PAFF; (b) `ratecontrol.c` folds merged both-pass `i_mb_count_ref`
      through the *last-pass* `i_fref_frame` map, but pass 0 and pass 1 entry
      layouts differ (pass 1 inserts the complementary field mid-list) → counts
      mis-attributed. Neither is hit by 1-pass/`--qp`; both must be fixed or
      gated before `--pass` is allowed with `--paff`.
      DONE: (a) optimal reorder disabled for PAFF (driver pins reordering=0
      and expands the decoder default); (b) refcounts folded per pass in the
      driver while each pass's map is live, published pair-level;
      `fdec->i_field_bits[2]` recorded per pass; D8 gate relaxed (ABR/CRF
      1-pass + B allowed, JM bit-exact TFF/BFF); 2-pass I/P JM bit-exact.
      ALSO FIXED: mbtree qp_buffer heap overflow (mbtree rescale init
      rounded dims only for MBAFF, not PAFF → 99-entry buffer vs 110 MBs),
      found by ASan; hit by any `--pass 1` with PAFF at QCIF-ish heights.
      GATED (not fixed): 2-pass + B default turbo first pass trips the
      pre-existing pixel bug → task 6.2; `--ref 1` + no-B → task 6.1.
      2-pass stats stay pair-level per D2 (frame-based); the "per field"
      task wording is satisfied by per-field bit accounting + per-pass
      refcount folding.
- [x] 2.2 ABR/CBR/CRF validation runs on interlaced content; compare
      rate-distortion vs MBAFF, document gaps.
      DONE (checkpoint-2.2.md): FOUND+FIXED a 2-pass target undershoot (~35%)
      -- slice_write's i_misc_bits = bs_pos - tex - mv double-counted the
      first field's bytes (out.bs spans both passes of a pair); fixed by
      snapshotting the pass-0 end position in the PAFF driver and
      subtracting it from pass 1's i_misc_bits.  Rate accuracy after fix:
      1-pass ABR on target (better than MBAFF), 2-pass on target with
      --slow-firstpass (turbo pass-1 model mismatch amplified by field ME --
      documented, recommend --slow-firstpass for PAFF 2-pass).  RD at matched
      bitrate: PAFF +2.9 dB vs MBAFF (detailed clip), ~+3.5 dB (natural clip),
      ~parity with progressive -- no RC-quality gap.  Gaps: CBR/VBV overshoot
      +22% vs +11% MBAFF -> task 2.3; CBR+B stays hard-errored until 2.3.
      JM bit-exact: ABR, ABR+B, 2-pass, CBR; test_paff.sh 12/12.
- [x] 2.3 VBV model per field AU (OQ1 resolution, see design.md): step
      `update_vbv` per field with `i_field_bits[2]` and field-period
      `buffer_rate`; per-field `hrd_timing` arrival/removal; stress-test
      small VBV buffer.
      DONE: update_vbv refactored into vbv_au_step (remove AU bits, check
      underflow, add arrival over the AU's cpb duration, check overflow;
      filler only on the last AU); under PAFF it steps twice per pair with
      the ACTUAL per-AU NAL payload sums split at the driver-recorded
      out.i_paff_au_boundary (h->out spans both passes), one field tick of
      arrival per step (i_cpb_duration/2).  Arrival-time chaining in
      ratecontrol_end stays pair-level (bit-sequential -- identical result);
      the SEI-side per-field delays were done in 1.2.  VBV+B hard-error
      removed.  Validation: CBR+B 398 kb/s of 400 target (250f), small-VBV
      (100k and 50k buffer) and CRF+maxrate runs: zero underflow warnings;
      JM bit-exact TFF/BFF for CBR no-B, CBR+B, nal-hrd cbr +B, CRF+VBV+B;
      test_paff.sh 12/12, non-PAFF baselines decoded identical.  Remaining:
      CBR no-B overshoot is a startup transient (pair-level model had it
      too: +22%@100f, decaying to +8%@250f; MBAFF +6-11%) rooted in
      pair-level QP planning, unchanged per D2; Annex C simulator gate is
      task 2.4.
- [x] 2.4 Independent HRD verification: Annex C CPB simulator
      (`tools/check_hrd.py`) checking CPB underflow/overflow at field
      granularity on `--nal-hrd cbr` streams; wire into checkpoint 8.2.
      DONE: tools/check_hrd.py parses SPS VUI HRD params, buffering_period/
      pic_timing SEI and slice headers (AU split per 7.4.1.2.3 incl. field
      pictures), simulates the CBR CPB per C.1.1/C.1.2 with absolute-tick
      tracking across mid-stream buffering periods (x264's pir_offset
      switches at the pair AFTER the keyframe).  The simulator immediately
      caught TWO encoder-side bugs the internal model hid:
      (a) vbv_au_step CLAMPED mid-pair overflow away (b_last_au=0) -- the
          decoder's true fill drifted up to 3.3% over cpb_size, sustained
          over 111 AUs; fixed by carrying the excess honestly until the
          pair's last AU emits filler for it;
      (b) the peak before the SECOND field's removal is uncorrectable by
          filler (it lands in the second field's AU and only bounds later
          removals); fixed by emitting filler once the fill exceeds
          cpb_size minus one field tick of arrival (eff_buffer_size).
      After the fixes: 8/8 --nal-hrd cbr streams pass at field granularity
      (TFF/BFF, no-B, B, scenecut keyframes, keyint 25, 100k buffer,
      progressive + MBAFF controls); negative control: the pre-fix stream
      fails with 111 violations.  JM bit-exact on all new streams;
      test_paff.sh 12/12; CBR+B rate/quality unchanged (414.5 kb/s,
      35.84 dB).  Checkpoint 8.2 wiring: run check_hrd.py on every
      --nal-hrd cbr stream of the final matrix.
- [x] 2.5 Enable weighted prediction (`--weightp`) under PAFF reusing the MBAFF
      weight path (weights on `plane_fld`); if the JM round-trip fails, keep it
      rejected in validation and document the limitation in `doc/paff.txt`.
      DONE (JM gate passed): pair-level estimated weights are mapped onto
      field-entry references in weighted_pred_init via the expansion's
      i_fref_frame; both entries of a pair share one scaled plane buffer
      (numweightbuf is 1-2, so per-entry buffers would overflow).  Three
      bugs found and fixed on the way:
      (a) p_weight_buf was sized with i_padv = PADV<<PARAM_INTERLACED while
          weighted_pred_init scales with PADV<<PARAM_FIELDCODE (covers PAFF)
          -> heap overflow (munmap_chunk) with weightp 2; allocation now
          uses PARAM_FIELDCODE;
      (b) weightp 2 reference DUPLICATES are impossible under PAFF: a dup
          only exists in the decoder's list via ref_pic_list_modification,
          which PAFF pins off (2.1) -- the decoder's default field-expanded
          list has no dupes.  Dup insertion is now skipped under PAFF
          (weightp 2 degrades to weightp 1 semantics for P fields);
      (c) deblock_ref_table + the SMART dup remap in macroblock_cache_load
          must not run under PAFF: the table is filled pair-level in
          slice_init (before the per-pass expansion) and was remapping refs
          to wrong "picture ids" -> wrong deblocking (w2 divergence at
          ref 2).  Gated on !b_paff; without dupes, L0 indices are 1:1 with
          field pictures so raw-index comparison (as for weightp 1) is
          correct.
      CLI no longer force-disables --weightp under --paff.  JM bit-exact:
      weightp 0/1/2 x ref 1/2/3 x TFF/BFF on a fade clip, plus weightp 2
      with --bframes 3 (weightb stays disabled); test_paff.sh 12/12,
      non-PAFF baselines decoded identical.

## 3. Threading

- [x] 3.1 Field pair inside one frame-thread slot (D3); PAFF + sliced threads
      rejected with a clear validation error (done, keep); verify
      `--threads N` output is byte-identical to `--threads 1`.  Bailout
      condition: if the pair driver needs deep surgery rather than local
      synchronization fixes, defer frame threads to a future change and
      keep/document the forced `i_threads=1` (low-latency slicing remains
      future work either way, see `doc/paff.txt`)
      DECISION: BAILED OUT — frame threads deferred to a future change; the
      forced `i_threads=1` (encoder_open validation: sliced threads rejected
      with an error, frame threads warned down to 1) stays.  The PAFF pair
      driver is deep surgery for frame threading, not a local sync fix:
      (1) x264 frame threads are worth it only because `fdec_filter_row`
      broadcasts per-row completions so a dependent thread's ME starts before
      its reference is fully filtered, but a PAFF pair is only usable as a
      WHOLE after `paff_frame_finish` (two whole-frame plane_fld/hpel/border
      sweeps in `paff_sync_references`, the second overwriting stale
      second-field rows), and the PAFF path never calls
      `x264_frame_cond_broadcast` today, so frame threads on would deadlock;
      even a correct "broadcast once at finish" port collapses pipelining to
      "wait for the whole pair" (near-zero overlap gain).  (2)
      `paff_sync_references` mutates the full frame and toggles
      i_threadslice_start/end from inside the per-pair driver — a rewrite to
      map onto fdec_filter_row's incremental cadence, not a patch.
      (3) the wait site `x264_frame_cond_wait(fref[ref>>MB_INTERLACED]->orig)`
      assumes the standard ref-list shape; PAFF's field-expanded list injects
      h->fdec as the complementary field and reuses one pair object for both
      parities.  (4) cross-thread state sync (thread_sync_context +
      x264_thread_sync_ratecontrol) is not audited for PAFF's per-parity
      frame fields / pair-level RC (D2).  VERIFIED behaviorally: `--threads
      4/8 --paff` warns and forces to 1; `--threads N` output byte-identical
      to `--threads 1` (forcing total: i_thread_frames=1, lookahead
      single-threaded too); single-threaded self-deterministic.  See
      design.md D3 (updated) for the full rationale.  User-facing limit ->
      doc/paff.txt (task 4.1); the "Frame threads deferred" scenario in the
      spec is satisfied.

## 4. Documentation and CI

- [x] 4.1 New `doc/paff.txt` (mode description, limitations, quality notes);
      update `doc/threads.txt`/`doc/ratecontrol.txt` where PAFF differs
      DONE: doc/paff.txt written (what PAFF is; how to enable --paff +
      --tff/--bff; bitstream/timing: per-field pic_timing pic_struct 1/2,
      buffering_period in field units, dec_ref_pic_marking; current II
      keyframe structure with the Ip refinement noted as task-7 future work;
      RC/VBV: frame-level QP both fields, per-field bit accounting, VBV steps
      per field AU, recommend --slow-firstpass for 2-pass, CBR no-B startup
      overshoot transient; threading: forced single-threaded, sliced rejected,
      frame threads deferred; unsupported combinations list; quality numbers
      +2.9/+3.5 dB vs MBAFF and parity vs progressive; progressive/MBAFF
      bit-identical; testing pointers test_paff.sh/check_hrd.py/regression).
      doc/threads.txt: appended a PAFF+threads note (forced i_threads=1,
      whole-pair availability does not pipeline on per-row filter completion,
      frame threads deferred -> doc/paff.txt).  doc/ratecontrol.txt: appended
      a PAFF note (pair = frame-level QP both fields, per-field bit
      accounting, 2-pass pair-level, VBV per field AU, --slow-firstpass,
      CBR overshoot -> doc/paff.txt).
- [x] 4.2 Update `AGENTS.md` interlacing section; CLI `--fullhelp` text; bash
      completion
      DONE: AGENTS.md "Key architectural facts" gained an Interlacing/PAFF
      bullet (parallel to the Threading bullet) -- two modes (MBAFF vs PAFF),
      PAFF pair-driver location, frame-level RC + per-field bit accounting +
      per-field VBV/SEI, forced i_threads=1, mutually exclusive with MBAFF,
      non-PAFF bit-identical invariant, -> doc/paff.txt.  x264.c --fullhelp:
      the --paff text was stale ("Incompatible with ... B-frames, weighted
      prediction and threads" -- all three wrong now); rewritten to "Each input
      frame is coded as a complementary field pair. Incompatible with MBAFF,
      AVC-Intra, sliced threads and pulldown; forces single-threaded encoding.
      See doc/paff.txt." (verified in ./x264 --fullhelp).  autocomplete.c:
      --paff already present in the bash-completion option list (no-arg flag,
      no value completion needed); --tff/--bff already present.  No code-path
      change beyond the help string.
- [x] 4.3 Add PAFF jobs to `.gitlab-ci.yml` (build + scripted JM round-trip or
      internal conformance smoke test)
      DONE: internal conformance smoke (JM is not in the CI images, so a JM
      round-trip is not runnable in CI).  New tools/test_paff_ci.sh: JM-free,
      ffmpeg-free (raw YUV input via a python3 generator, raw Annex-B output,
      so no lavf/swscale linkage or ffmpeg needed).  Runs the forced-single-
      thread PAFF encoder through a config matrix (CRF TFF/BFF, B-frames +
      pyramid, CBR+VBV, weightp 2, 2-pass with --slow-firstpass), checks
      thread determinism (--threads 4 == --threads 1 byte-identical), verifies
      an --nal-hrd cbr stream against the Annex C CPB simulator
      (tools/check_hrd.py, field granularity), and asserts the validation
      rejections (--sliced-threads, --pulldown, --avcintra-class).  Verified
      locally: 11/11 PASS.  New .gitlab-ci.yml job test-paff-debian-amd64
      (stage: test, depends on build-debian-amd64 for the x264 artifact,
      vlc-debian-unstable image has python3, runs tools/test_paff_ci.sh);
      YAML validated, job wired into the test stage.  The full JM round-trip
      (tools/test_paff.sh) stays a local/developer procedure
      (doc/regression_test.txt) since JM/ldecod is not packaged in CI.

## 5. Follow-ups from the paff-b-frames code review

Carried over from the post-archive review of `paff-b-frames` (commits
`efe2cc98`/`efce190e`).

- [x] 5.1 Root-cause the ffmpeg `mmco: unref short failure` warning.  Repro:
      `--paff --tff --bframes 3 --b-pyramid normal --ref 3 --direct auto`
      (default pyramid!).  Output is byte-exact, but a conformant decoder
      reports an MMCO opcode-1 whose field PicNum matches nothing in its DPB.
      Find which opcode on which pair fails (prime suspect: the two-opcode
      emit vs the IDR-survivor single-field DPB model) and either fix the
      marking or document it as a proven decoder artifact.  **Blocks the
      8.3 hardware-interop claim** -- a stricter decoder may treat it as
      fatal or drop a different picture.  (Repro widened in paff-sei-hrd-rc:
      also fires with `--paff --tff --bframes 0 --nal-hrd cbr --bitrate 300
      --vbv-bufsize 300 --vbv-maxrate 300`, i.e. no B-frames needed.)
      ROOT-CAUSED (definitive, via an instrumented ffmpeg built from
      ~/src/ffmpeg-trunk): the warning is NOT an MMCO opcode x264 emits --
      x264 emits ZERO marking opcodes for no-B (pure sliding window,
      adaptive_ref_pic_marking_mode_flag = 0; confirmed by instrumenting
      slice_header_write).  ffmpeg's own `generate_sliding_window_mmcos`
      (libavcodec/h264_refs.c) synthesizes the eviction opcodes, and for
      FIELD_PICTURE always emits TWO MMCO_SHORT2UNUSED (opcode-1) per
      evicted pair (pic_num 2*fn and 2*fn+1).  The failing pair is the IDR
      pair (frame_num 0, the keyframe): at its eviction the instrumented DPB
      dump shows `... 0(ref=2)` -- pair0 survives in the DPB with
      reference = BOTTOM only (PICT_BOTTOM_FIELD=2), i.e. ONE field.  The
      TOP field (the pair's first-coded IDR field) was wiped by the SECOND
      field's IDR decoded-reference-picture-marking (8.2.5.1, IdrPicFlag
      clears all reference pictures) -- exactly the "II" keyframe structure
      (D5).  ffmpeg's two eviction opcodes then over-fire:
        opcode pic_num=0 -> unreference_pic(pair0, refmask=TOP): does
          `reference &= refmask` (KEEPS refmask bits, does not clear them),
          so 2 & 1 = 0 -> pair0 reference 0 -> pair0 removed entirely from
          short_ref;
        opcode pic_num=1 -> find_short(0) = NULL -> "unref short failure".
      A healthy 2-field pair (ref=3=TOP|BOTTOM) evicts cleanly: the same
      two opcodes leave one field after the first and remove on the second
      (verified: the non-IDR pairs fn=1,2,... produce no warning).
      CONFIRMATION: the failure count scales with the number of IDR pairs
      (--keyint 25 over 120 frames -> ~5-6 failures; --keyint 250 -> 1,
      = the single II IDR pair at the start).
      CONCLUSION: this is NOT a decoder artifact (ffmpeg's behavior follows
      the spec's IDR marking + its own 2-opcode field eviction model) and
      NOT an x264 marking bug (x264 emits no opcodes here).  It is the II
      keyframe structure itself: two consecutive IDR access units leave the
      keyframe pair single-field-referenced.  FIX = task 7.1 (D5, Ip pairs:
      first field IDR, second field a non-IDR P referencing the first),
      which eliminates the second IDR -> no DPB wipe -> pair stays
      2-field -> ffmpeg's eviction is clean.  The warning is BENIGN for
      ffmpeg (it sets AVERROR_INVALIDDATA but continues; decode stays
      byte-exact, no picture is actually lost -- the failed opcode tries to
      unreference something already unreferenced), but a stricter decoder
      could treat it as fatal, so 5.1 stays OPEN until 7.1 lands and the
      warning is verified gone across the matrix.  See design.md D5.
      5.1 is therefore ROOT-CAUSED and FIXED (via task 7.1, which removed the
      II structure entirely): with Ip keyframe pairs the single-field IDR
      survivor does not exist, the decoder's sliding-window eviction is clean,
      and `mmco: unref short failure` no longer fires across the full matrix
      (verified byte-exact vs ffmpeg, 0 warnings).
- [x] 5.2 Scripted PAFF round-trip regression: turn the 14-config matrix from
      `paff-b-frames/checkpoint-4.1-4.3.md` (TFF/BFF × pyramid × ref 1-4 ×
      direct modes × CAVLC/CABAC × keyint × frame_num wrap) into a script /
      make target (`tools/` or `doc/regression_test.txt` procedure), wired
      into the 4.3 CI job.  The paff-b-frames history shows why: a "24/24
      byte-exact" claim later did not reproduce on the same tree.
      DONE: the matrix is now a single source of truth.
      `tools/paff_matrix.sh` defines the 14-config B-field set (TFF/BFF ×
      b-pyramid none/normal/strict × ref 1-4 × direct none/spatial/temporal/auto
      × CABAC/CAVLC × keyint 8/24 × --no-deblock), including the exact rows
      that previously crashed or drifted (mx05 = the --ref 1 crash, mx03 =
      --b-pyramid strict --ref 2 BREF-eviction crash, mx06 = ref 4 + keyint 8
      frame_num wrap, mx08 = --no-deblock isolation of the 6.2 bS work).
      `tools/test_paff.sh` gained a `matrix` command (and is now part of `all`)
      that runs each config through the existing `roundtrip` JM gate.
      `tools/test_paff_ci.sh` sources the same file and runs an encode-only
      smoke of all 14 (no JM/ffmpeg in CI images) so the CI catches the
      segfault/crash class of regression.  `doc/regression_test.txt` gained a
      PAFF-matrix section pointing at both drivers.  Verified: CI smoke
      25/25 PASS (11 prior + 14 matrix, incl. the ref-1 and strict-r2 crash
      configs), all three scripts `bash -n` clean, PAFF_MATRIX parses to 14.
      The byte-exact JM round-trip of the matrix itself is task 7.3 (needs
      JM ldecod locally; the encode half is already proven by this CI smoke).
- [x] 5.3 Replace the assert-only `mmco[]` capacity guards
      (`reference_hierarchy_reset`, `reference_build_list` trim) with a
      hard clamp -- the asserts vanish under NDEBUG.
      DONE: both `assert( i_mmco_command_count + 2 <= X264_REF_MAX )` sites
      (encoder.c `reference_build_list` DPB-tail trim, and
      `reference_hierarchy_reset` BREF-pair eviction) are now hard-clamped:
      once the opcode buffer would overflow, the eviction is skipped
      (`continue`) and the pair leaks into the DPB until the next IDR,
      rather than writing past `mmco[X264_REF_MAX]`.  A one-shot
      `X264_LOG_WARNING` (flag `b_paff_mmco_clamp_warned` in common.h,
      mirroring `b_paff_pic_struct_warned`) names the situation and points
      at `--ref`/`--b-pyramid`.  In `reference_hierarchy_reset` the clamp's
      `continue` correctly skips `n_removed++` and `b_ref_reorder[0]`, since
      the opcode was not emitted (decoder keeps the pair) -- semantics
      preserved.  Normal configs never reach the clamp (verified: ref 4 /
      b-pyramid normal / keyint 10 PAFF encode logs no warning); the clamp
      only covers the NDEBUG-release hole the assert left behind.

## 6. Follow-ups from paff-sei-hrd-rc task 2.1 validation

Found by the 2.1 validation runs (JM round-trips of the newly allowed RC
modes).  Both are PRE-EXISTING pixel-layer bugs (reproduce at the
paff-sei-hrd-rc branch point with plain `--qp`), most likely a shared
deblock/edge-handling corner for cbp=0 MBs under field pictures: the
artifacts are ±1 columns/rows at MB edges.  Root-cause with a JM trace
vs encoder-side BS comparison.

- [x] 6.1 PAFF + P-only + `--ref 1` non-conformant.  **ROOT-CAUSED AND FIXED**
      (commit with the P_SKIP chroma v-offset fix): the P_SKIP reconstruction
      paths (`macroblock_encode_internal` P_SKIP branch,
      `macroblock_probe_skip_internal`) skipped the opposite-parity chroma
      v-offset that `mb_mc_0xywh` applies (mvy += (mb_y&1)*4 - 2, 4:2:0
      field chroma phase).  With the complementary field as (sole) reference,
      fractional-MV P_SKIP chroma was interpolated half a line off vs JM.
      The ref-1 validation gate is removed; TFF/BFF bit-exact at qp 20/35.
- [x] 6.2 PAFF deblocking diverges from JM on B-field slices with
      skip/direct-MB-rich content.  **ROOT-CAUSED AND FIXED** (commit with
      the bS canonicalization): x264's `deblock_strength` only does straight
      per-list comparisons, but the spec's bS=1 test (8.7.2.1, NOTE 1)
      compares reference PICTURES regardless of list/index, which under PAFF
      bites two ways, both confirmed against an instrumented JM:
      (a) cross-list pairs -- an L0-only partition against an L1-only
      partition of the SAME reference field (first divergence: qp35 CABAC
      repro, frame 3 bottom, 6 px) -- fixed by canonicalizing the cache
      before the shared strength call: remap ref indices to picture ids,
      move single-MV L1 predictions into the L0 slot, sort two-MV
      predictions by picture id, zero MVs of unused lists;
      (b) same-picture bipred -- both blocks bipredicted from one field
      picture (first divergence with CAVLC: frame 3 TOP field, B_DIRECT
      cluster) -- the spec's last bS=1 bullet requires a large MV difference
      in BOTH the aligned AND the crossed pairing; fixed by a post-pass that
      lowers bS to 0 when the crossed pairing is small.
      Both fixes are gated on FIELD_PIC && B-slice, so progressive/MBAFF
      output is untouched (baseline-check bit-identical) and checkasm is
      unaffected (the shared strength function itself is unchanged).
      Validated bit-exact vs JM: qp 20/28/30/35, CABAC+CAVLC, TFF+BFF,
      pyramid normal/strict/none, ref 1-5, direct spatial/auto, and
      2-pass + B-frames with default TURBO first pass (the original 2.1
      trigger) and --slow-firstpass.  The `b_stat_read` + B hard-error is
      removed; VBV + B stays hard-errored until task 2.3.

## 7. IDR field pairs as Ip (D5, blocks final checkpoint 8.1)

- [x] 7.1 Second field of a keyframe pair coded as P referencing the pair's
      first field (slice type per pass diverges from pair type for keyframes).
      Sub-items:
      (a) pass-1 (second field) ref list: inject the pair's first field into
          the pass's RefPicList0 -- the complementary-field machinery exists
          for ordinary P pairs since `paff-core-ip`, but keyframe pairs
          currently build empty ref lists;
      (b) IDR DPB flush happens exactly once: the first field's AU flushes
          the DPB and the first field survives as a short-term reference
          available to the second field's pass (currently both passes of a
          keyframe pair flush);
      (c) POC: first field POC 0 via the IDR reset; second field POC counted
          from the reset base (+1 per field order) through the existing
          per-field POC path (fdec->i_poc stays the pair-level value, D11);
      (d) remove the `idr_pic_id` xor-undo hack (encoder.c ~4450): only the
          first field is an IDR AU now, slice_init's toggle applies to
          consecutive keyframes only;
      (e) 2-pass: the pair stays a frame-level keyframe stat entry (D5); the
          I/P bit split is absorbed by the per-field accounting from 2.1.
      DONE: the per-pass PAFF driver now diverges the keyframe pair's type --
      pass 0 stays the IDR field, pass 1 becomes a non-IDR P field
      (sh.i_type=P, i_nal_type=NAL_SLICE) referencing the pair's first field.
      (a) the complementary injection (paff_expand_field_list b_complementary=1
      with pair_count=0, since an I/IDR pair builds no past list) yields L0 =
      [first field] -- the existing machinery, no new code.  (b) automatic:
      only pass 0 is an IDR, so the decoder's IDR marking (8.2.5.1) flushes
      once and the first field survives 2-field; reference_reset still runs
      once before the driver.  (c) automatic: sh.i_poc = base_poc +
      i_delta_poc[parity] already yields 0 (top, TFF) / 1 (bottom).  (d) the
      `i_idr_pic_id ^= 1` xor-undo hack is removed; slice_init toggles
      idr_pic_id once per keyframe pair so consecutive keyframes alternate
      (7.4.3).  (e) verified: 2-pass byte-exact vs ffmpeg, 0 warnings.
      KEY FIX BEYOND THE DRIVER: paff_expand_field_list's PAFF_PUSH macro
      special-cased X264_TYPE_IDR references to a SINGLE available field
      (the old II-structure DPB survivor).  Under Ip an IDR pair is a full
      2-field reference, so that special case was removed (IDR ref -> avail=3,
      both fields); leaving it in made every P frame after a keyframe build a
      1-field list while the decoder built 2 -> ~68% MC divergence.  Pair-level
      sh.i_type / i_nal_type are restored after the loop for frame-end
      consumers.  VERIFIED: dump-vs-ffmpeg byte-exact across TFF/BFF x ref 1-4
      x CABAC/CAVLC x keyint 10/250 x CRF/2-pass/CBR+nal-hrd, plus B-pyramid
      (32-config matrix + extras, 0 bad frames, 0 warnings); progressive/MBAFF
      unchanged (0 bad); checkasm8/10 green; CI smoke 11/11.  This also FIXES
      task 5.1 (the II single-field survivor that tripped ffmpeg's sliding
      window no longer exists).  JM re-baseline is task 7.3.
- [x] 7.2 AVC-Intra flavor: reject PAFF + avcintra at validation with a clear
      error (OQ2 resolution); document in `doc/paff.txt`; full II-pair
      support is future work
      DONE (was already implemented during earlier tasks; verified complete):
      validation rejection at encoder_open (`encoder/encoder.c` PAFF block,
      `"PAFF is not supported with AVC-Intra"`, returns -1); documented in
      `doc/paff.txt` unsupported-combinations section ("full II-pair AVC-Intra
      support is future work"); and asserted by the CI smoke
      (`tools/test_paff_ci.sh` encodes `--paff --avcintra-class 50` and
      requires non-zero exit).  No new code needed -- task closed as already
      satisfied.
- [x] 7.3 Re-run all JM round-trips and re-baseline `tools/test_paff.sh`
      (every keyframe-containing stream changes)
      DONE: full re-baseline against JM 19.0 ldecod.  `tools/test_paff.sh
      paff matrix` = 24/24 PASS byte-exact vs `--dump-yuv`: 9 `paff` configs
      (I-only keyint-1, I+P TFF/BFF, ref 2/4/8, sliding-window eviction,
      CRF smoke) + the 14-config B-field matrix (TFF/BFF x b-pyramid
      none/normal/strict x ref 1-4 x direct none/spatial/temporal/auto x
      CABAC/CAVLC x keyint 8/24 x --no-deblock).  Every keyframe-containing
      stream now uses the Ip structure (7.1) and round-trips, including the
      previously-segfaulting I-only keyint-1 case (7.4).  JM's field-pair
      output quirk is handled by `paff_cmp` (content-match by field parity).
- [x] 7.4 PAFF + `--keyint 1` (I-only) segfaults on the keyframe pair's
      second field (the Ip P field).  ROOT-CAUSED AND FIXED.
      Root cause: `encoder.c:4076` set `b_kept_as_ref = i_nal_ref_idc !=
      NAL_PRIORITY_DISPOSABLE && h->param.i_keyint_max > 1`.  The
      `i_keyint_max > 1` carve-out is an I-only optimisation for PROGRESSIVE
      streams (an all-keyframe progressive stream never references a past
      picture, so it skips reference-plane setup).  Under PAFF that is wrong:
      a keyframe pair's first field MUST be a reference for its own second
      field (the Ip P).  At keyint 1, `b_kept_as_ref` was forced to 0, which
      cascaded three ways: (a) `b_complementary = pass==1 && b_kept_as_ref`
      became 0, so `paff_expand_field_list` injected no complementary field
      and the P second field got an EMPTY L0 (`i_fref[0]=0`); (b)
      `b_field_kept_as_ref[0/1]` cleared; (c) the hpel/subpel filter pass
      (`b_hpel = b_kept_as_ref`) was skipped, so `filtered_fld` was never
      built.  Result: `mb_mc_0xywh` dereferenced a NULL `p_fref[0][i_ref]`
      (ASAN SEGV, common/macroblock.c:44) during P-field analysis.
      Fix: gate the carve-out on PAFF -- `b_kept_as_ref = i_nal_ref_idc !=
      NAL_PRIORITY_DISPOSABLE && (h->param.b_paff || h->param.i_keyint_max > 1)`.
      Under PAFF any non-disposable frame is kept as a reference (the pair
      structure demands field references regardless of inter-pair keyframe
      cadence); progressive/MBAFF I-only behaviour is unchanged.  B-disposable
      pairs still drop out via the `nal_ref_idc != DISPOSABLE` term.
      Validation: ASAN-clean on keyint-1 PAFF (frames 25); the I-only keyint-1
      stream is now JM byte-exact (paff_tff_intra PASS); `test_paff.sh paff
      matrix` 24/24; progressive + MBAFF + progressive-keyint-1 +
      MBAFF-keyint-1 outputs byte-IDENTICAL to HEAD (stash/clean-rebuild/cmp,
      4/4); checkasm8/10 green; determinism across runs identical.

## 8. Final checkpoint

Blocked by: 2.3/2.4 (HRD), 5.1 (MMCO), 6.2 (B-field deblock), 7.x (Ip pairs).

- [x] 8.1 Full matrix (CRF/2-pass/CBR × TFF/BFF × I/P/B) JM bit-exact
      DONE: `tools/test_paff.sh all` = 30/30 byte-exact vs JM ldecod.  CRF:
      the 14-config B-field matrix (TFF/BFF x b-pyramid none/normal/strict x
      ref 1-4 x direct none/spatial/temporal/auto x CABAC/CAVLC x keyint 8/24
      x --no-deblock) + the `paff` set (I-only keyint-1, I+P TFF/BFF, ref
      2/4/8, sliding-window eviction).  2-pass and CBR: the new `rc` command
      (`rc_cbr_tff/bff` CBR+VBV no-B, `rc_2p_tff/bff` 2-pass ABR with
      --slow-firstpass).  I/P/B columns, TFF and BFF, all covered.  Every
      keyframe-containing stream uses the Ip structure (7.1) and round-trips.
- [x] 8.2 HRD streams parse cleanly in JM and ffprobe; CPB underflow/overflow
      checked by the Annex C simulator (2.4); SEI content verified by dump tool
      DONE.  `--nal-hrd cbr` PAFF stream (TFF, no-B): JM ldecod decodes
      byte-exact (all field parities covered) with ZERO warnings; ffprobe
      parses with no error; the independent Annex C CPB simulator
      (tools/check_hrd.py) reports `CPB check passed: no underflow/overflow
      at AU granularity` (50 field AUs, max fill 90%).  ROOT-CAUSED AND FIXED
      a pre-existing Annex B framing nit surfaced by the JM parse: the second
      field access unit of a PAFF pair was emitted with a 3-byte start code
      (no leading zero_byte), tripping JM's strict `zero_byte shall exist`
      warning (Annex B 7.4.1/B.1.1 require a zero_byte before the first NAL of
      every access unit; progressive did not warn because it has one AU per
      frame).  Fix in `x264_nal_encode_nals` (encoder.c): `b_long_startcode`
      now also asserts true at `h->out.i_paff_au_boundary` (the second-field
      AU start tracked since task 2.3) -- gated on `b_paff`, so progressive/
      MBAFF output is byte-identical (verified).  After the fix the stream has
      51 four-byte / 53 three-byte start codes (one long per field AU) and JM
      reports zero warnings on every PAFF stream (HRD and plain B-pyramid).
- [x] 8.3 Hardware interop smoke test: the PAFF streams from 8.1 decode on
      the Intel machine's QSV hardware decoder without errors
      DONE (QSV substituted -- no Intel GPU on any available host; the
      machine has NVIDIA RTX 5060 Ti + AMD iGPU).  New
      tools/test_paff_hw.sh encodes the 8.1 stream set (9 paff + 14 matrix
      + 4 rc + 1 --nal-hrd cbr = 29 streams) and decodes each with three
      gates: clean decode (exit 0, zero warnings), exact frame count
      (25 = 50 fields, no dropped/merged pictures), and pixel md5
      bit-identical to ffmpeg's software decoder in NV12 (H.264 decode is
      deterministic; divergence = hw mishandling field pairing/deblock).
      Results (ffmpeg 8.1.2, driver 595.84 / Mesa 26.1.6):
      - soft (control): 29/29 PASS.
      - NVDEC via ffmpeg's h264 decoder + -hwaccel cuda (libavcodec DPB and
        field pairing, NVDEC silicon): 29/29 PASS, all bit-exact.
      - NVDEC via NVIDIA's CUVID parser (-c:v h264_cuvid): 28/29 PASS
        bit-exact (TFF/BFF, pyramids, ref 1-8, CAVLC, frame_num wrap,
        CBR+VBV, 2-pass, nal-hrd).  The single FAIL is paff_tff_intra
        (--keyint 1, an IDR first field in EVERY pair): CUVID reconstructs
        wrong pictures (all 25 output frames' bottom fields match no
        reference decode; even frame 0 -- and the same bitstream in mp4
        behaves identically, so it is not an Annex-B/timestamps artifact)
        and on raw Annex-B also stalls, emitting only 14 frames.
      - VA-API on the AMD iGPU (Mesa radeonsi, VCN v3; set up during this
        task: VIDEO_CARDS="amdgpu radeonsi" + USE=vaapi in mesa): 28/29
        PASS bit-exact, same stream set, same single failing config
        (--keyint 1) but a loud failure mode: vaEndPicture returns an
        error per picture, zero frames output.  Selectivity identical to
        CUVID: progressive --keyint 1 and PAFF --keyint 2 are bit-exact.
      ROOT-CAUSE (decoder side, x264 stream is conformant): JM 19.0 decodes
      the keyint-1 stream bit-exact (8.1), ffmpeg software and
      ffmpeg-h264+NVDEC-hwaccel are bit-exact, progressive --keyint 1 and
      PAFF --keyint 2 are bit-exact through CUVID, so the breakage is
      exactly "IDR first field in every pair" x "NVIDIA's own parser".
      With keyint 1 all fields carry frame_num = 0 and POC regresses
      (0,1,0,1,... -- every IDR resets PicOrderCnt), which trips CUVID's
      opaque reorder/pairing.  Spec-wise the pairing stays unique
      (3.37: a complementary reference field pair's SECOND field is not an
      IDR, so only (IDR_i, P_i) pairs, never (P_i, IDR_i+1)), and frame_num
      reuse is legal (7-25 note: the preceding reference picture is an
      IDR).  Documented as a known decoder quirk in doc/paff.txt with the
      workaround "use keyint >= 2 for CUVID-based consumers"; --keyint 1
      PAFF is a stress config with no practical use.  Two independent hw
      vendors (NVIDIA parser, AMD VA-API driver) trip on exactly this one
      construct while the reference decoder JM, ffmpeg software and
      NVDEC-driven-by-libavcodec are bit-exact -- a legal-but-never-emitted
      corner (no mainstream encoder produces all-IDR PAFF) that vendor
      firmware simply does not exercise.  Documented as a known decoder
      quirk in doc/paff.txt with the workaround "use keyint >= 2".
      QSV itself remains untested for lack of hardware; the Ip keyframe
      structure it was designed for (design D5) is unchanged by this
      result.
      ADDENDUM (user-requested follow-up, Intel hosts + II A/B + TRUE ROOT
      CAUSE FOUND AND FIXED -- the "vendor bug" was ours):
      (1) Intel hosts tried: core-hizel-nuc (Broadwell HD 6000, Gen8) --
      the QSV API is dead on it (libmfx 22.5.4/oneVPL require Gen9+,
      session init fails); Intel fixed-function decode validated through
      VA-API/iHD on the same chip: 32/32 bit-exact INCLUDING keyint 1.
      core-hizel-nuc2 (Alder Lake i3-1220P, ffmpeg 8.1.2 --enable-libvpl
      + libmfx-gen1.2 runtime): REAL QSV validated, 34/34 bit-exact (all
      8.1 streams + controls + both A/B streams below), and the QSV
      ENCODER itself, driven at keyint 1 with interlaced flags, emits
      exactly the Ip structure (IDR field + non-IDR P field per pair,
      NAL-verified) -- empirical confirmation of design D5.
      (2) "Is Ip itself wrong, should keyframes be II?" tested with a
      throwaway X264_PAFF_FORCE_II build (not committed): ffmpeg software
      decodes both bit-exact; AMD VA-API passed II but failed Ip; NVIDIA
      CUVID failed BOTH; Intel passed both.  No structure satisfies all
      vendors -> the discriminator had to be something else.
      (3) TRUE ROOT CAUSE (found by bisecting our keyint-1 stream against
      the QSV encoder's keyint-1 stream, which passed everywhere): POC
      regression and frame_num=0 were red herrings (QSV's stream has the
      identical pattern and passes).  The real difference was in the SPS:
      x264's I-only carve-out set max_num_ref_frames = 0 for --keyint 1
      (encoder/set.c) -- honest for all-intra progressive, a LIE under
      PAFF, where every keyframe pair's second field is a reference P
      field predicting from the first.  Spec-wise the stream survived on
      the 8.2.5.1 Max(num_ref,1) escape hatch, but hardware decoders that
      size their DPB from the signalled value broke: AMD VCN allocated
      zero reference surfaces (vaEndPicture "operation failed", zero
      frames), NVIDIA's CUVID parser derailed its field pairing (silent
      corruption, stall at 14/25 on raw Annex-B).  Lenient decoders (JM,
      ffmpeg sw, libavcodec+NVDEC, Intel VA-API) derived the DPB from the
      level and worked -- which is exactly why 8.1/8.2 had passed.
      This also explains the II pass on AMD: with II no picture references
      another, so num_ref_frames=0 was semantically right.
      FIX: gate the I-only zeroing on !b_paff (one line + comment,
      encoder/set.c) -- same pattern as the 7.4 b_kept_as_ref fix.  After
      the fix: num_ref_frames=1 under PAFF keyint 1; progressive/MBAFF
      outputs byte-identical (verified); tools/test_paff.sh all = 30/30
      JM bit-exact (JM 19.0 rebuilt locally, /tmp/JM); hardware matrix
      ALL GREEN: soft 29/29, cuvid 29/29, nvdec 29/29, vaapi-AMD 29/29,
      QSV (Alder Lake) fixed keyint-1 stream bit-exact, Intel VA-API
      bit-exact.  CI guard added: tools/test_paff_ci.sh encodes a PAFF
      keyint-1 stream and asserts SPS num_ref_frames >= 1 (27/27).
      SECOND FOLLOW-UP (QSV structural comparison, GOP=1s/CBR/open-GOP
      vs the Intel encoder on Alder Lake): matching our stream against
      the QSV encoder's at keyint 25 / CBR / B-pyramid / open-GOP
      caught that 1.1's per-field pic_struct was silently NOT emitted:
      the b_pic_struct auto-enable in encoder_open fired only for
      PARAM_INTERLACED (MBAFF), so under pure --paff the SPS carried
      pic_struct_present_flag = 0, gating the pic_struct (and, without
      --nal-hrd, the whole pic_timing SEI) out of the stream.  Fixed by
      enabling b_pic_struct for PAFF too (one-line gate next to the
      MBAFF one, commit 9622f8f6).  Verified: h264_analyze shows
      pic_struct_present=1, JM 30/30 bit-exact, CI smoke 27/27 (Annex C
      sim unchanged), and the new stream decodes bit-exact on
      sw/cuvid/vaapi-AMD/qsv.  Structural parity with QSV confirmed
      on: High 3.1, PAFF field pictures, per-GOP SPS/PPS repeat, Ip
      keyframe pairs, POC cadence, frame_num-per-pair,
      buffering_period + per-AU pic_timing.  Legit differences remain
      (nal_ref_idc levels 3/2 vs 1/0, log2fn 4 vs 8, num_ref 4 vs 3,
      B-field ratio, full HRD + fixed timing in VUI vs QSV's none,
      x264 recovery_point SEI under open-GOP vs QSV's absence,
      idr_pic_id 0/1 alternation vs monotonic).
- [x] 8.4 checkasm green; progressive/MBAFF outputs bit-identical to baseline
      DONE: checkasm8/10 both "All tests passed Yeah :)".  Progressive and
      MBAFF outputs verified byte-identical to the pre-change baseline by a
      stash/clean-rebuild/cmp across four configs (progressive default,
      progressive --keyint 1, MBAFF --bframes 2, MBAFF --keyint 1) — all 4/4
      IDENTICAL, confirming 5.3 (mmco clamp) and 7.4 (keyint b_kept_as_ref
      fix) are fully gated on `b_paff`.  `tools/test_paff.sh baseline-check`
      (progressive + MBAFF decoded through JM, 2/2 identical to saved
      baseline) is the maintained regression gate for this invariant.
