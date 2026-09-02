# PAFF frame threads: hybrid readiness, not phase-granular

**Status: SUPERSEDED in part by ADR-0007** (`0007-paff-pass-granular-threading.md`):
the hybrid-readiness model and the ~2x P-chain ceiling are replaced by
pass-granular jobs with row-cadence readiness for both fields.  The
rejection of phase-granular readiness below still stands — ADR-0007
builds on exactly that dependency analysis.

Enabling frame threads under PAFF, the tempting small change is phase-
granular readiness: broadcast after the intermediate `paff_sync_references`
sweep (the code comment documents that the first field is then a valid
reference) and again at `paff_frame_finish`, so dependent pairs never see
partial data and no MV-range machinery is needed. That design was sketched
and rejected: the decoder's default field reference list (H.264 8.2.4.2.5,
reproduced by `paff_expand_field_list`) alternates parity per reference
pair, so the active window of *either* coding parity starts
`[p(N), !p(N), p(N-1), ...]` — every pass of pair N+1 reads **both** fields
of pair N. A first-field-only phase broadcast has no cross-pair consumer
(the only reader of the first field before pair completion is the second
pass of the same pair, coded by the same worker); the dependency chain
`field1(N) -> finish(N) -> field0(N+1) -> ...` stays fully serial (~1.0x at
any thread count).

Decision: hybrid readiness. The first field stays phase-complete (the
intermediate sweep is the broadcast point). The second field becomes
row-granular: rows of the coding parity get their field-layout copy, hpel
and borders at `paff_filter_row` cadence, and dependent passes gate through
the standard progressive machinery — wait at MB-row start, clamp
`thread_mvy_range` from completed rows, `i_mv_range_thread` defaulted from
the field height, `--non-deterministic` respected. The ceiling is ~2x on
P-chains — both passes of a pair are serial inside one job and every pass
references both fields of the previous pair, so at most two passes of
consecutive pairs overlap; B-pyramid siblings gate on the same anchor and
overlap more. That replaces the ~1.0x serial chain, but it does not scale
past two threads the way progressive frame threads do.

Consequences: threaded PAFF output is deterministic at fixed N but not
byte-identical to `--threads 1` (the MV-range clamp changes motion search,
as it does for progressive threads); row-granular readiness for the *first*
field (dropping the intermediate sweep) remains possible future work that
reuses everything built here.
