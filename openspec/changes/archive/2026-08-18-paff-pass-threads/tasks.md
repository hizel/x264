## 1. Parity-scoped band primitives (no scheduling change)

- [x] 1.1 Parameterize the field branch of `x264_frame_filter` and the
       reference-band work (plane→plane_fld copy, borders, hpel) by coding
       parity so a band call touches only its own parity's rows; keep the
       both-parity path for the full-sweep callers if any remain after 2.x
- [x] 1.2 Gate: `--paff --threads 1` byte-identity on the full
       `tools/test_paff.sh` matrix; verify the cadence-call hpel waste is
       gone (no behavior change expected at this stage)

## 2. First-field cadence; sweep removal

- [x] 2.1 Extend `paff_filter_row` to produce the reference band and
       advance `i_lines_completed_fld[pass0_parity]` at row cadence during
       the FIRST pass (same one-field-row trail as the second pass); move
       residual work (last band, sentinel broadcast) to the end of the
       first pass; delete `paff_sync_references`
- [x] 2.2 Keep pair-granular jobs in this stage (pass 1 still runs in the
       same job after pass 0; its reads of the first field are satisfied
       by the cadence data) and gate: t1 byte-identity, fixed-N determinism
       at N=2/4/8, `test_paff.sh all`, JM round-trip spot checks
- [x] 2.3 Measure: no throughput regression at t1/t6/t16 on the reference
       clip (expect ~neutral: sweep work rescheduled, 2x hpel waste gone)

## 3. Pass self-containment audit (D6)

- [x] 3.1 Enumerate every `x264_t`-carried state the second pass reads
       that the first pass wrote; for each, either prove it re-initialized
       per pass or marshal it through `paff_job` / the shared pair fdec;
       record the findings in design.md. Checklist (design D6): border
       backups; out continuity (stitching); stat (harvest merge);
       mb/cabac residue; `h->rc` — pass-1 row VBV runs on PREDICTED
       pass-0 bits (accepted, progressive semantics): seed the
       dispatch-time view, merge `qpa_rc`/`qpa_aq` at harvest
       (`x264_threads_merge_ratecontrol` pattern), rebuild the
       ratecontrol end-chain sync for two slots per pair;
       `h->paff_evicted` — pair-level stash, release after both jobs;
       frame pools/refcounts — shared pair `fdec` returned exactly once
       with phase+2; the end-of-driver "restore pair-level view" block
       moves to harvest; `h->fenc` — both jobs point at the pair's fenc,
       pushed unused exactly once (same rule as the shared fdec)
- [x] 3.2 Define the pass-1 job's `h->fdec` handling (shared pair fdec
       pointer via job params) and the parity-disjointness argument
       (plane/filtered_fld/integral rows, VBV re-encode confinement)

## 4. Job split and two-slot dispatch

- [x] 4.1 Split `paff_pair_write` into per-pass job entry points loading
       their pass parameters from `paff_job` (lists, maps, num_ref_idx,
       nal overrides, fdec); move per-pass bit accounting
       (`i_field_bits`, AU boundary, misc-bits undo) into the owning job.
       The prologue fills BOTH `[pass]` halves of `paff_job` into BOTH
       slots identically; each job reads only its own half (design D3)
- [x] 4.2 Caller: advance the slot round-robin by two per PAFF encode
       call, dispatch F0(N) and F1(N) jobs from the same prologue, context
       sync for both slots from the serial view; account
       `h->frames.i_delay` by pairs in flight (`(N+1)/2 - 1`) instead of
       `N - 1`, keeping frame-pool sizing consistent
- [x] 4.3 Harvest: wait for both jobs of the oldest pair (rendezvous),
       run the pair-level frame end on the PASS-0 slot's context (design
       D3): merge the pass-1 slot's `stat.frame` into it, stitch NAL
       arrays into its `out` (F0's then F1's, payloads in slot buffers), run pair-level frame end unchanged
       (ratecontrol_end, reference_update, deferred eviction push); set
       the stitched `out.i_paff_au_boundary` to F0's `i_nal` BEFORE any
       harvest-side consumer (per-field VBV/HRD split, buffering-period
       SEI insertion, encapsulation) reads the merged array; release the
       pair's `paff_evicted` stash here, after both jobs
- [x] 4.4 Wait sites: drop the `fref == h->fdec` skip for the
       complementary entry (pass 1 waits its own first field, row-bounded);
       verify the NDEBUG MV-range check covers it
- [x] 4.5 Re-run the memcpy-region audit (6.1-style) for the new job shape
       (per-slot sh/stat/out/mb writes, shared fdec parity rows,
       `thread_sync_context` chain with two slots per pair)
- [x] 4.6 Fail path: a failing pass job broadcasts the completion
       sentinel for its own parity on the shared pair fdec before
       returning -1, so row waiters wake instead of hanging the pool
       (design D5); the harvest still propagates the error

## 5. Validation and hardening

- [x] 5.1 Full gate matrix: t1 byte-identity vs pre-change; fixed-N
       determinism (two runs, byte-compare) at N=2/4/8/16 in the default
       deterministic mode — `--non-deterministic` is validated by
       decodability and JM round-trip only (timing-dependent
       completed-row ranges are by design, as in progressive threading);
       no-hang soak at each N
- [x] 5.2 JM round-trip (`--dump-yuv`) for threaded PAFF runs across the
       type matrix (I/P/B, b-pyramid, open-gop, --tff/--bff); ffmpeg
       decode check on the reference clip with `-threads 1` decoder
- [x] 5.3 Non-PAFF bit-identity: progressive and MBAFF outputs unchanged
       at every tested thread count (the new paths are b_paff-gated)
- [x] 5.4 TSAN build at `--paff --threads 4/8`; diff report classes
       against a progressive control; fix every new real race
- [x] 5.5 Quality tolerance: t1-vs-tN PSNR/bitrate divergence within the
       progressive-threading reference on the fade and scenecut clips
       (reuse the 9.4 clips from paff-frame-threads)

## 6. Performance acceptance and docs

- [x] 6.1 Benchmark matrix on the reference clip (hall.mp4, maintainer's
       CBR+VBV params) at t1/t2/t4/t6/t8/t16 + the 1080i testsrc2 clip;
       add a VBV-drift column (filler bits and buffer-fill deviation vs
       t1) for t6/t16 — pass-1 row VBV runs on predicted pass-0 bits
       (design D6); record in `doc/threads.txt`; acceptance per design
       D8 three zones (<2x at t6 stop; 2-4x profile + explicit approval;
       ≥4x at t6 and ≥5x at t16 pass)
- [x] 6.2 Update `doc/paff.txt` Threading section (pass-granular jobs,
       row-cadence both fields, sweep removal, halved pairs-in-flight
       note) and prune the stale future-work entry
- [x] 6.3 Update `AGENTS.md` PAFF threading facts; commit series per the
       migration plan with caveman-commit style
- [x] 6.4 Glossary: rewrite the CONTEXT.md entries that describe the old
       model — Frame-thread slot (PAFF unit becomes the field pass),
       Readiness (both fields row-granular; "hybrid" becomes historical),
       Intermediate sweep (removed; keep as a historical term pointing to
       the cadence model); add Field pass (one coding pass of a PAFF pair,
       codes one field; pass 0 = first by coding order, parity set by
       TFF/BFF; pass ≠ parity) and Reference band (one field row's worth
       of reference data: plane_fld copy + hpel + borders)
- [x] 6.5 ADR: write `docs/adr/0007-paff-pass-granular-threading.md`
       (decision D1+D3 — job split and row cadence are one change, not
       two; rejected alternatives; three-zone acceptance) and mark
       ADR-0005 "Superseded in part by ADR-0007"
