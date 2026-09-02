# Delta: threaded-ratecontrol (threaded VBV determinism)

## ADDED Requirements

### Requirement: Deterministic VBV under frame threading

Frame-threaded encoding with VBV enabled SHALL be byte-deterministic at a
fixed thread count: repeated runs with identical parameters and identical
`--threads N` (N > 1) SHALL produce byte-identical output for any supported
slice-type configuration, including B-frames and PAFF field pictures.

#### Scenario: CBR+VBV repeat runs
- **WHEN** the same clip is encoded multiple times with CBR bitrate, VBV
  constraints, and a fixed `--threads N` (N in {2, 4, 8, 16})
- **THEN** all runs produce byte-identical output files

#### Scenario: B-frame configurations
- **WHEN** the repeat-run check is performed with B-frames enabled
  (default `--bframes 3`) and with `--bframes 0`
- **THEN** both configurations are byte-deterministic at fixed N

#### Scenario: PAFF configurations
- **WHEN** the repeat-run check is performed under `--paff` (TFF and BFF)
  with CBR+VBV at a fixed thread count
- **THEN** the runs are byte-identical

### Requirement: VBV decisions read only final state

Under frame threading, every VBV decision (frame-level QP/buffer planning
at dispatch, per-row QP adjustment, per-row predictor updates) SHALL be a
function only of state that is final at decision time: the calling slot's
own ratecontrol state, completed frames' final statistics, and reference
rows provably committed under the frame-thread row-wait guarantee.  Live
per-row state of in-flight frames on other slots SHALL NOT be read.

#### Scenario: In-flight frame size estimates not read
- **WHEN** a frame's VBV plan or initial QP is computed while other frames
  are still being coded by pool workers
- **THEN** the computation uses the planned (predicted) sizes of in-flight
  frames, not their per-row-updated size estimates

#### Scenario: Reference row reads guarded by the committed check
- **WHEN** a row-level VBV decision would read a reference frame's row
  statistics (row QP, row qscale, row bits)
- **THEN** the read is performed only if the row's stats are provably committed under
  the row-wait guarantee for the current coding mode, with a safety margin;
  otherwise the existing no-reference fallback branch is taken

### Requirement: Non-VBV and single-thread invariance

The determinism changes SHALL NOT alter output of configurations that were
already deterministic: `--threads 1` output SHALL be byte-identical before
and after, and CRF, CQP, and ABR-without-VBV output SHALL be byte-identical
before and after at any thread count.

#### Scenario: Single-thread byte-identity
- **WHEN** a CBR+VBV stream is encoded with `--threads 1` before and after
  the change
- **THEN** the outputs are byte-identical

#### Scenario: Non-VBV modes byte-identity
- **WHEN** CRF, CQP, or ABR-without-VBV streams are encoded before and
  after the change, at `--threads 1` and at `--threads N` (N > 1)
- **THEN** the outputs are byte-identical

### Requirement: VBV compliance and quality preserved

The change SHALL NOT introduce VBV buffer underflow or overflow on
conforming configurations, and SHALL NOT meaningfully regress bitrate
accuracy or quality relative to the pre-change threaded behaviour.

#### Scenario: No new VBV violations
- **WHEN** threaded CBR+VBV encodes are run after the change across a clip
  matrix
- **THEN** no encode requires filler insertion beyond the pre-change
  behaviour, no underflow warnings are logged, and reference-decoder
  conformance is preserved

#### Scenario: Quality within tolerance
- **WHEN** bitrate error versus target, PSNR-Y, and SSIM are measured
  before (median of 5 runs per matrix cell) and after the change on
  threaded CBR+VBV encodes over the fixed matrix: clips {176x144,
  scenecut, 720p hall.mp4 full length} x {bframes 0, 3} x {threads 4, 8}
- **THEN** |bitrate error delta| <= 0.5%, |PSNR-Y delta| <= 0.05 dB,
  |SSIM delta| <= 0.002, filler bytes <= baseline median, and
  tools/check_hrd.py reports no violations on all post-change outputs
  encoded with --nal-hrd cbr; any exceedance routes to the committed-
  check-vs-blanket-skip evaluation, or is documented in `doc/threads.txt`
