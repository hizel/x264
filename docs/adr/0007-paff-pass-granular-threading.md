# PAFF pass-granular threading: job split and row cadence are one change

**Status: accepted** — supersedes ADR-0005 in part (the hybrid-readiness
model and its ~2x ceiling; the phase-granular rejection there stands).

`paff-frame-threads` shipped hybrid readiness: the pair is one pool job,
the first field becomes a reference at a phase boundary (the intermediate
sweep), the second field's rows at row cadence.  That caps a P-chain at
~2x: both passes of a pair are serial inside one job and every pass
references both fields of the previous pair, so at most two passes of
consecutive pairs ever overlap.

This change lifts the ceiling by coding the two field passes of a pair as
TWO pool jobs on consecutive slots (D3) with the first field's reference
band produced at row cadence during pass 0 (D2), and treats the two as a
single, indivisible decision (D1).  The model (a = pass time,
m = row-wait margin):

```
pair = 1 job (ADR-0005):     period per pair = a + s + m   → ~2x ceiling
split only (F0 stays phase): period per pair = a + m       → still ~2x
split + cadence F0:          period per pair = 2m          → ~2a/2m ceiling
```

The split alone does not shorten the critical path (pass 1 still waits
for the first field's phase completion), and cadence alone is impossible
inside one job (its passes are serial on one worker).  Only both together
turn the chain into the per-pass diagonal staircase that progressive
frame threading already has.

**Alternatives rejected:**

- *Split only, first field keeps phase readiness* — no gain (model
  above); the phase barrier stays the critical path.
- *Cadence only, keep the pair job* — structurally impossible: one worker
  cannot overlap its own two serial passes.  (This was the variant
  `paff-frame-threads` correctly rejected as "single percent"; the
  estimate does not transfer to the two-job variant.)
- *Dispatch pass 1 from inside the pass-0 job (continuation)* — breaks
  the "caller is the only dispatch point" invariant the race audits rely
  on and complicates slot ownership for no benefit.
- *One slot per pair, both jobs on the same `x264_t`* — the passes would
  share `mb` caches, CABAC state and `out` and race as soon as pass 1
  overlaps pass 0's tail; serializing them reintroduces the phase
  barrier.

Consequences: N slots keep N/2 pairs in flight (pipeline depth is
passes); pair jobs consume an even slot count, an odd slot idles; the
intermediate sweep is deleted (`paff_sync_references`); harvest becomes a
rendezvous (the caller waits for BOTH jobs of the oldest pair, then runs
the pair-level frame end on the pass-0 slot); pass 1's row VBV runs on
predicted pass-0 bits (progressive-threading semantics; VBV drift is a
measured benchmark column, not a bound).  `--threads 1` keeps the
monolithic pair driver, so the t1 byte-identity gate holds by
construction.

**Acceptance (three zones, fixed before measuring):** <2x at `--threads
6` = stop and re-evaluate; 2x–<4x at t6 = profile and merge only with
explicit maintainer approval; ≥4x at t6 and ≥5x at t16 = pass.

**Outcome:** pass zone.  Reference clip (hall.ts, 720x576i CBR+VBV, 400
frames): 4.15x at t6 and 6.27x at t16 over the same binary at t1, and
1.56x/2.2x over the pair-granular implementation at t6/t16.  Low-N
tolerance note: t2 regressed 7.7% against the pair-granular build (pairs
in flight halve; accepted bound was ~10%), t4 improves 12.7% (must not
regress).  Numbers
and the VBV-drift columns are recorded in `doc/threads.txt`.
