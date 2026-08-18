# Delta: paff-encoding (pass-granular frame threading)

## MODIFIED Requirements

### Requirement: Threading behavior under PAFF

Under PAFF with frame threading, each field pass of a complementary field
pair SHALL be coded as its own pool job (two jobs per pair, two frame-thread
slots per pair), and slice-based threading SHALL be rejected at validation
time with a clear error. Frame-threaded PAFF encoding (`--threads N`, N > 1)
SHALL be deterministic at a fixed thread count: two runs with identical
parameters and identical N SHALL produce byte-identical output, matching the
frame-thread determinism invariant of progressive encoding (including the
semantics of `--non-deterministic`). Output produced with N > 1 threads is
not required to be byte-identical to the single-threaded output of the same
parameters, because the motion-vector range clamp of frame threading applies
as in progressive encoding; every threaded output SHALL remain a conformant,
reference-decodable PAFF bitstream with the same frame types and reference
structure as the single-threaded run.

Reference readiness SHALL be enforced per field and per row for BOTH fields
of a pair: rows of each field SHALL become usable as reference data only as
their reconstruction and row filtering complete at pass cadence, and no
separate full-frame intermediate phase SHALL be required between the passes.
Dependent jobs — including the pair's own second pass referencing its first
field — SHALL wait per row and restrict their motion-vector range to the
completed rows instead of reading incomplete reference data, without
deadlock for any supported thread count. The intermediate full-frame sweep
between the passes is thereby removed; its work is rescheduled into the
first pass's row cadence, and `--threads 1` output SHALL remain
byte-identical to the pre-change single-threaded output (pure rescheduling).

#### Scenario: Slice threads rejected
- **WHEN** the user requests PAFF together with slice-based threading
- **THEN** encoder initialization fails with a validation error naming the
  unsupported combination

#### Scenario: Frame threads work
- **WHEN** a PAFF stream is encoded with `--threads N` (N > 1) and with
  `--threads 1` using otherwise identical parameters
- **THEN** both runs are deterministic at their fixed thread count (repeated
  runs with the same N are byte-identical), both outputs decode bit-exactly
  in the reference decoder (JM), share the same frame-type and reference
  structure, and diverge in encoded bytes and quality only within the
  tolerance established for progressive frame threading (N > 1 vs N = 1)

#### Scenario: Single-thread bit-identity
- **WHEN** a PAFF stream is encoded with `--threads 1` before and after the
  sweep-to-cadence rescheduling
- **THEN** the outputs are byte-identical

#### Scenario: Frame threads deferred
- **WHEN** pass-granular PAFF frame threading cannot be validated (deadlock,
  nondeterminism at fixed N, conformance failure, quality regression beyond
  the progressive-threading tolerance, or a data race surfaced during
  implementation)
- **THEN** the change is not merged: the pair-granular threading of the
  prior implementation (or the forced `i_threads = 1` bailout, whichever is
  the last-known-good state) stays in place until the failure is fixed, and
  sliced threads remain rejected in all cases

#### Scenario: Reference readiness gating
- **WHEN** a dependent job — a later pair's pass, or the pair's own second
  field — could reference a field of an in-flight pair whose relevant rows
  are not yet fully reconstructed and filtered
- **THEN** the dependent job waits instead of reading incomplete reference
  data and restricts its motion-vector range to the completed rows; the
  second pass's wait on its own first field is bounded by that field's
  completed row count, and no deadlock or partial-reference read occurs for
  any supported thread count

#### Scenario: Pair output integrity
- **WHEN** a pair's two passes complete on different frame-thread slots
- **THEN** the encoder returns a single output picture whose NAL units are
  the first field's access unit followed by the second field's access unit,
  with pair-level statistics, rate control and DPB marking applied once per
  pair, identical to the single-threaded structure
