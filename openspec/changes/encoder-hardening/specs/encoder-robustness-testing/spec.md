# encoder-robustness-testing Specification

## Purpose

Defines the project's robustness tooling — sanitizer-matrix builds and
coverage-guided fuzz targets for the encoder — so that memory errors,
undefined behaviour, data races, and crash-level parameter handling are
hunted systematically rather than discovered in production.

## ADDED Requirements

### Requirement: Sanitizer matrix harness

The project SHALL provide a script that builds the encoder from a
pristine copy of the tree (never interfering with a configured in-tree
build) under clang with AddressSanitizer+UndefinedBehaviorSanitizer and
ThreadSanitizer configurations, and runs the existing PAFF verification
suites under each. The harness SHALL report per-configuration pass/fail
and SHALL skip (not fail) configurations whose toolchain support is
missing. A MemorySanitizer configuration SHALL be attempted as a
best-effort cell; if it proves impractical against the host libc, a
documented valgrind-memcheck recipe SHALL be provided instead.

#### Scenario: ASan+UBSan run is clean

- **WHEN** the harness runs the PAFF CI suite and selected PAFF
  round-trip commands under an ASan+UBSan build (assembly disabled)
- **THEN** all cells pass with zero sanitizer reports

#### Scenario: TSan run with documented suppressions

- **WHEN** the harness runs threaded PAFF encodes (frame threading and
  sliced threading) under a TSan build
- **THEN** no data race is reported outside the suppressions file, and
  the suppressions file documents the known by-design ratecontrol
  row-stats race with a pointer to the threaded-vbv-determinism analysis

#### Scenario: Missing toolchain support skips cleanly

- **WHEN** the host clang lacks a requested sanitizer runtime
- **THEN** that configuration is reported as skipped and the harness's
  overall result still reflects the configurations that ran

### Requirement: Encoder fuzz target

The project SHALL provide a coverage-guided fuzz target that derives
encoder parameters and input pixels from the fuzz input, opens the
encoder, encodes the frames to completion (including draining delayed
frames), and closes it. The parameter derivation SHALL cover the
PAFF/MBAFF/progressive mode choice, field dominance, B-frame settings,
reference count, rate-control mode, and GOP/keyframe settings; inputs
whose parameters fail validation SHALL terminate the run as a
non-crash. The target SHALL run single-threaded with tiny fixed frame
dimensions so that throughput stays useful for coverage-guided fuzzing.

#### Scenario: Overnight session stability

- **WHEN** the encoder target runs under libFuzzer with ASan+UBSan for
  an extended local session with the generated seed corpus
- **THEN** any crash produces a reproducer artifact in the designated
  (git-ignored) output directory, and a session with no findings exits
  reporting its coverage statistics

#### Scenario: Invalid parameters are not crashes

- **WHEN** the derived parameter set is rejected by encoder validation
- **THEN** the target returns normally and libFuzzer continues

### Requirement: Parameter-parser fuzz target

The project SHALL provide a fuzz target feeding arbitrary input as
`name=value` strings into the encoder's parameter parsing and profile
application paths.

#### Scenario: Parser survives garbage

- **WHEN** the parser target runs under libFuzzer with a dictionary of
  known parameter names
- **THEN** arbitrary inputs are handled without sanitizer reports

### Requirement: Reproducible setup documentation

The project SHALL document how to build and run the sanitizer matrix and
the fuzz targets, including required toolchain versions, how seeds and
dictionaries are generated, and where crash artifacts land.

#### Scenario: Fresh-environment reproducibility

- **WHEN** a developer follows the documentation on a machine with clang
  and the repo
- **THEN** both the sanitizer matrix and a short fuzz smoke run execute
  without undocumented steps
