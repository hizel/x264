# Proposal

## Why

The PAFF work added ~3.5k lines to the encoder core, all of it in
security-relevant C (bitstream writing, reference management, threaded
pipelines). Today the correctness net is conformance (JM round-trips)
and determinism harnesses — both prove the *output* is right on the
inputs we thought of. Nothing systematically hunts memory errors,
undefined behaviour, data races, or crashes on parameter/pixel
combinations nobody tried. x264 is notably absent from OSS-Fuzz
(dav1d, libaom, libvpx, openh264 are fuzzed; x264 is not), so no
ready-made harness exists. Meanwhile two of the three hardest PAFF bugs
we already fixed (`ref_blind_dupe`, the VBV-recode CABAC desync) were
uninitialized/stale-read classes that MSan-style tooling targets
directly, and threaded VBV had a confirmed data race.

## What Changes

- New `tools/test_sanitize.sh`: builds the tree (from a `git archive`
  copy, so an in-tree configured build never blocks it) out-of-tree with
  clang under three sanitizer configs and runs the existing PAFF suites
  under each:
  - **ASan+UBSan** (`--disable-asm`, since sanitizers cannot see
    assembly): `test_paff_ci.sh` plus selected `test_paff.sh` commands.
  - **TSan**: threaded encodes (frame threads and sliced threads) with a
    suppressions file documenting the known by-design row-stats race in
    upstream ratecontrol.
  - **MSan** (optional cell, best-effort): single-threaded short encodes;
    falls back to a documented valgrind recipe if MSan proves impractical
    against the system libc.
- New `tools/fuzz/` directory with two libFuzzer targets and a build/run
  script (clang `-fsanitize=fuzzer,address,undefined`):
  - `fuzz_encoder.c`: input bytes are laid out as a structured parameter
    selector (PAFF/MBAFF/progressive, tff/bff, bframes, refs, threading
    within a single thread, open-gop, weightp, rc mode, ...) followed by
    pixel data for 2–4 tiny frames; the encoder is opened, run to
    completion (including delayed frames), and closed. Parameter
    combinations rejected by validation are a normal exit path.
  - `fuzz_param_parse.c`: arbitrary bytes as `name=value` strings fed to
    `x264_param_parse` / profile application.
  - Runtime-generated seed corpus (no binary media in git) plus a
    dictionary of x264 parameter names; crash artifacts go to a
    git-ignored directory.
- Documentation: how to run the sanitizer matrix and an overnight fuzz
  session (in `doc/paff.txt` or a new `doc/fuzzing.txt`).
- Bugs found by these tools are fixed in separate changes, not here.

## Capabilities

### New Capabilities

- `encoder-robustness-testing`: sanitizer-matrix and fuzzing harnesses
  as project tooling — what they must cover, how they are built, and the
  reproducibility/skip semantics they must have.

### Modified Capabilities

(none)

## Impact

- New files only: `tools/test_sanitize.sh`, `tools/fuzz/*` (plus
  suppressions and docs). No encoder, build-system-default, or CI
  changes; `make` output is unchanged.
- Requires clang (libFuzzer + MSan + TSan are clang features); gcc
  builds remain the default and are untouched.
- ASM is excluded from sanitizer coverage (`--disable-asm`); ASM
  correctness stays with checkasm. Fuzz targets run single-threaded —
  threading bugs are TSan's job.
- Verified during exploration: clang 23 on this machine builds and runs
  libFuzzer targets out of the box; an ASan+UBSan build of master runs a
  threaded PAFF encode clean; out-of-tree builds work from a pristine
  copy (an in-tree `config.h` blocks them, hence `git archive`).
