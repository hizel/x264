# PAFF frame threads: caller-side list expansion, no cross-job handshake

**Status: proposed (design of `openspec/changes/paff-frame-threads`)**

A B pair reads older pairs' per-parity reference metadata (`i_ref[]`,
`ref_poc[]`, `i_poc_l0ref0[]`) when building `map_col_to_list0` and the
direct-mode flag. Progressive frame threads get this data for free: the
caller writes it serially in `slice_init` → `x264_macroblock_slice_init`
before dispatch, so by the time any job runs, every older frame's metadata
is final. The single-threaded PAFF driver instead computes each pass's
field-list expansion mid-driver, and the parity-1 metadata only exists
after pass-0 coding. Once the driver becomes a pool job, that metadata is
produced halfway through the job — too late for a younger B pair that needs
it at its own start.

Three options were weighed:

1. **Publish from inside the job** with a per-frame "lists published" flag
   and a cond-wait in younger jobs. Rejected: the parity-1 wait would last
   ~half of the older job (publication is mid-job), and it adds a second
   kind of cross-job wait to the deadlock argument for no benefit — the row
   waits already order the jobs.
2. **Expand both passes at job start** (the inputs are the caller-prepared
   pre/post-marking snapshots; expansion reads no pixels), publish, then
   code. Workable, but the publication is still job-side state that other
   jobs poll, and it re-runs or stashes the pass-1 expansion.
3. **Caller-side expansion**: the caller already prepares both snapshots
   (the D20 marking moved caller-side), so it runs both passes'
   `paff_expand_field_list` before dispatch and writes the per-parity
   metadata onto `h->fdec` serially — exactly the progressive invariant.

Decision: option 3. The expanded per-pass lists and parity maps travel to
the job in a job-parameter struct (`x264_paff_job_t`) on `x264_t` — safe
from the `thread_sync_context` memcpy because it is written after this
slot's sync, before dispatch, and read only by the job. Storing the lists
on `x264_frame_t` was rejected: frames are pooled, the data lives only for
the job's duration, and other pairs read only the per-parity metadata that
already lives on `fdec`. For the same boundary reason the P-pair past-list
rebuild (the FrameNumWrap-descending sort over `h->frames.reference`,
8.2.4.2.2) also moves caller-side: after this, the job never reads
`h->frames.reference` or the unused-frame pool, which the next pair's
caller mutates concurrently.

Consequences: the caller's serial prologue grows by two list expansions —
list arithmetic only, no pixel reads, negligible next to coding — and the
job gets shorter, which helps the pass-level pipeline (ADR-0005). The wait
graph reduces to row waits over strictly older pairs, so the deadlock
argument is a plain DAG with no second wait kind. Colocated-metadata reads
(`map_col_to_list0`, direct-mode flag) need no synchronization at all: they
read `fdec` fields that were final before the owning pair was dispatched.
