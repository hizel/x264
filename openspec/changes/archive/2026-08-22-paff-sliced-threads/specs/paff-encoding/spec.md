# paff-encoding delta: paff-sliced-threads

## REMOVED Requirements

### Requirement: Threading behavior under PAFF

**Reason**: Slice-based threading becomes supported under PAFF, so the
requirement's central rejection clause ("slice-based threading SHALL be
rejected") is no longer true. The requirement is replaced by the successor
requirement "Threaded encoding under PAFF". The retired scenarios are
"Slice threads rejected" (the behavior being introduced) and "Frame threads
deferred" (a change-management fallback of the landed paff-pass-threads
change, not runtime behavior).

**Migration**: All frame-threading guarantees — pass-granular pool jobs,
fixed-N byte determinism, row-granular per-field reference readiness,
single-thread bit-identity, pair output integrity — are carried forward
verbatim into the successor requirement. Only the sliced-threads rejection
changes: the combination moves from a validation error to a supported mode.

## MODIFIED Requirements

### Requirement: Field-picture coding mode selection

The encoder SHALL support Picture-Adaptive Frame/Field (PAFF) coding,
selectable via a dedicated `b_paff` field in `x264_param_t`, distinct from
the existing `b_interlaced` field (0 = off, 1 = MBAFF).  When PAFF is selected,
every coded picture of the sequence SHALL be a coded field
(`field_pic_flag = 1`), and the SPS SHALL signal `frame_mbs_only_flag = 0`
and `mb_adaptive_frame_field_flag = 0`.  PAFF and MBAFF SHALL be mutually
exclusive within one encoded sequence; encoder initialization SHALL fail if
both are requested.

#### Scenario: PAFF mode enabled via API
- **WHEN** the application sets `b_paff=1` and opens the encoder
- **THEN** the emitted SPS has `frame_mbs_only_flag=0` and
  `mb_adaptive_frame_field_flag=0`, and every slice header has `field_pic_flag=1`

#### Scenario: MBAFF mode unchanged
- **WHEN** the application selects MBAFF interlaced mode (as before this change)
- **THEN** the bitstream is bit-identical to the pre-PAFF implementation

#### Scenario: PAFF and MBAFF conflict rejected
- **WHEN** the application requests `b_paff=1` together with `b_interlaced=1`
  or `--fake-interlaced`
- **THEN** encoder initialization fails with a validation error

#### Scenario: Threading restricted under PAFF
- **WHEN** PAFF is enabled together with sliced threads and any explicit
  sub-slicing option (`--slice-max-size`, `--slice-max-mbs`, or
  `--slices`): slice-max-size restarts recode earlier rows (breaking the
  row-monotonicity assumption of the row-level ratecontrol guarantees),
  and slice-max-mbs/slices boundary arithmetic assumes a contiguous
  raster that field-picture bands do not have
- **THEN** encoder initialization fails with a validation error naming the
  unsupported combination; PAFF with frame threads (`--threads N`, N > 1)
  or with sliced threads alone (`--sliced-threads --threads N`) is accepted

#### Scenario: Explicit MB/count slicing rejected under PAFF
- **WHEN** PAFF is enabled together with `--slice-max-mbs` or `--slices`,
  at any thread count
- **THEN** encoder initialization fails with a validation error naming the
  unsupported combination (previously this silently produced empty
  output); `--slice-max-size` without sliced threads remains accepted

### Requirement: Rate control per field pair

Under PAFF, rate control SHALL keep frame-level QP decisions while emitting a QP
per coded field (each field picture carries its own slice header and therefore
its own QP), and SHALL account bits per field for ABR/CBR/CRF and 2-pass modes.

Under PAFF with slice-based threading, the row-level VBV budget SHALL be
field-granular: the first field pass SHALL receive the pair-level planned
frame size scaled by its parity's share of the pair's measured complexity
(SATD), and the second field pass SHALL receive the pair plan minus the
first pass's actual coded bits. Pair-level ratecontrol accumulators (average
QP sums) SHALL be accumulated exactly once per pair across the two passes'
distribute/merge cycles.

#### Scenario: CBR PAFF stream
- **WHEN** a PAFF stream is encoded in CBR mode
- **THEN** the output respects the target bitrate and VBV constraints at field
  access-unit granularity

#### Scenario: Sliced CBR PAFF field budgets
- **WHEN** a PAFF stream is encoded with `--sliced-threads --threads N` in
  CBR+VBV mode
- **THEN** row-level VBV decisions within each field pass are made against
  that field's budget (satd share for the first field, leftover for the
  second), the pair's average-QP accounting equals the sum over both fields
  exactly once, and the output passes the Annex C CPB simulation

## ADDED Requirements

### Requirement: Threaded encoding under PAFF

Under PAFF with frame threading, each field pass of a complementary field
pair SHALL be coded as its own pool job (two jobs per pair, two frame-thread
slots per pair). Frame-threaded PAFF encoding (`--threads N`, N > 1)
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

Under PAFF with slice-based threading (`--sliced-threads --threads N`,
N > 1), frame threading SHALL be off (one pair in flight, monolithic pair
driver) and each field pass SHALL be split into N horizontal bands, one
slice per band, coded in parallel by the slice threads. A band SHALL cover
a contiguous range of the field's own MB rows (every second frame-coordinate
MB row of the pass's parity), and slice headers SHALL carry the field-raster
addresses required for field pictures. Deblocking across band boundaries
SHALL be disabled within each field picture
(`i_disable_deblocking_filter_idc = 2`), exactly as in progressive sliced
threading. Reference-data filtering (field-layout copy, borders,
half-pixel interpolation) for a pass SHALL produce results identical to the
single-threaded PAFF row-cadence pipeline; the number of slice threads
SHALL be capped so that a band is never thinner than four field MB rows
(half the progressive cap, since a field has half the frame's MB rows).

Slice-threaded PAFF with CBR+VBV rate control is NOT required to be
byte-deterministic at a fixed thread count: it inherits the documented
progressive sliced-threads exception (cross-slice reads of live ratecontrol
state are timing-dependent). Slice-threaded PAFF with CRF, CQP, or ABR
without VBV SHALL be byte-identical across repeat runs at a fixed thread
count. No slice-threaded output is required to be byte-identical to any
non-sliced output of the same parameters (slice headers, CABAC reinit, and
disabled cross-slice deblocking change the bitstream by construction);
every slice-threaded output SHALL remain a conformant, reference-decodable
PAFF bitstream.

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

#### Scenario: Sliced threads accepted and conformant
- **WHEN** a PAFF stream is encoded with `--sliced-threads --threads N`
  (N > 1) across TFF/BFF, I/P/B slice-type combinations, CRF/CQP/2-pass/
  CBR rate-control modes, and weighted prediction (`--weightp 1/2`) on P
  fields
- **THEN** every field picture is coded as N slices with field-raster
  addressing, cross-slice deblocking is disabled within each field picture,
  and every output decodes bit-exactly against the encoder reconstruction
  in the reference decoder (JM)

#### Scenario: Sliced threads non-VBV byte-repeat
- **WHEN** a PAFF stream is encoded with `--sliced-threads --threads N` in
  CRF, CQP, or ABR-without-VBV mode, repeatedly with identical parameters
- **THEN** all repeat runs produce byte-identical output

#### Scenario: Sliced threads VBV compliance without byte-determinism
- **WHEN** a PAFF stream is encoded with `--sliced-threads --threads N` in
  CBR+VBV mode with `--nal-hrd cbr`, using a VBV configuration under which
  the equivalent non-sliced PAFF run (same content, same rate-control
  parameters) produces no buffer underflow warnings
- **THEN** the output passes the Annex C CPB simulation and the sliced run
  produces no more buffer underflow warnings than the non-sliced reference
  run, while byte-determinism at a fixed thread count is not required (the
  progressive sliced-threads exception).  Deliberately undersized-buffer
  robustness (forcing a first-field budget overshoot against the budget
  floor) is exercised by the test plan as a robustness cell, not by this
  scenario

#### Scenario: Sliced threads band cap
- **WHEN** a PAFF stream is encoded with `--sliced-threads --threads N`
  where N exceeds four field MB rows per thread
- **THEN** the thread count is clamped so that each band covers at least
  four field MB rows (half the progressive cap)
