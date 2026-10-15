# Tasks

## 1. Sanitizer matrix harness

- [ ] 1.1 Create `tools/test_sanitize.sh` skeleton: `git archive HEAD` into a temp dir, per-config out-of-tree configure+build with clang, per-config pass/fail reporting, skip semantics for missing sanitizer runtimes; verify it builds the ASan+UBSan config and runs `./x264 --version`
- [ ] 1.2 Wire the ASan+UBSan config to run `test_paff_ci.sh` plus selected `test_paff.sh` commands (paff, sliced, opengop, rc) with the built binary; verify the full run passes clean on master
- [ ] 1.3 Add the TSan config running threaded PAFF encodes (frame threads and sliced threads, fixed N, CRF mode); triage reports against the known by-design row-stats race; verify the cell passes with the suppressions file in place
- [ ] 1.4 Commit `tools/tsan_suppressions.txt` with one documented entry per accepted race (justification + pointer to the threaded-vbv-determinism analysis); verify a run with an emptied suppressions file fails, proving the net works
- [ ] 1.5 Attempt the MSan config (single-threaded short encodes); if the host libc makes it impractical, replace it with the documented valgrind-memcheck recipe; verify the chosen variant runs and reports clean

## 2. Encoder fuzz target

- [ ] 2.1 Create `tools/fuzz/fuzz_encoder.c`: structured header -> parameter derivation (mode paff/mbaff/progressive, dominance, bframes 0-4, refs 1-5, rc mode, keyint class, weightp, cabac) over fixed tiny dimensions, encode-to-completion including delayed-frame drain, validation rejection as a normal return; verify it builds with `clang -fsanitize=fuzzer,address,undefined` against `libx264.a` and runs a smoke session
- [ ] 2.2 Create `tools/fuzz/run_fuzz.sh`: archive-copy build, runtime seed corpus generation, dictionary emission, git-ignored artifact dir, short smoke mode + long session mode; verify a smoke run of both targets completes and reports coverage stats
- [ ] 2.3 Create `tools/fuzz/fuzz_param_parse.c` feeding arbitrary bytes as `name=value` into `x264_param_parse` and profile application; verify a smoke run with the dictionary passes
- [ ] 2.4 Run an extended fuzz_encoder session (at least 30 minutes or 1M execs, whichever first) on master; triage any crash into a new openspec change; verify the session summary (execs, coverage, artifacts) is recorded in the run log

## 3. Documentation

- [ ] 3.1 Document both harnesses (prerequisites, build, run modes, artifact locations, suppressions policy, valgrind fallback if used) in `doc/paff.txt` or a new `doc/fuzzing.txt`; verify a fresh-environment reader can follow it without undocumented steps
- [ ] 3.2 Note the tooling in the ticket with first-session results; verify links/paths in the note match the tree
