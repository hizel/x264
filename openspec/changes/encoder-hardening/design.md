# Design: encoder-hardening

## Context

See proposal.md — Why. Key environmental facts established during
exploration: clang 23 with libFuzzer/ASan/UBSan/TSan runtimes is
installed; out-of-tree builds work but refuse to run while the source
dir holds an in-tree `config.h`; an ASan+UBSan build of master runs a
threaded PAFF encode clean; x264 has no presence in OSS-Fuzz, so no
harness can be borrowed, only a model (openh264's encoder fuzzer is the
closest public reference).

## Goals / Non-Goals

Goals:
- One-command sanitizer matrix runnable locally before merges.
- Two libFuzzer targets buildable with one script; a meaningful overnight
  session possible with zero extra setup.
- Known benign races documented, not rediscovered.

Non-goals:
- No fuzzing of the CLI input modules (y4m/avs/lavf) — the product at
  risk is the library; CLI-only parsers are a separate, lower-value
  surface.
- No decoder-side bitstream mutation fuzzing (that tests decoders, not
  our encoder).
- No CI wiring: sanitizer/fuzz runs are local or nightly-developer
  workflows for now.
- No fixing of found bugs in this change.

## Decisions

### D1: Build sanitizer configs from a `git archive` copy, in /tmp

Out-of-tree builds refuse to run when the source dir contains an
in-tree `config.h`, and the developer's tree normally has one. Copying
via `git archive HEAD` into a temp dir sidesteps this without touching
the working tree, makes the three sanitizer builds parallel-safe, and
guarantees the tested code matches the commit. Alternative considered:
`git worktree add` — writes metadata into the repo and needs cleanup
discipline; a plain archive copy is dumber and sufficient.

### D2: Sanitizer build flags

Common: `CC=clang`, `--disable-asm` (sanitizers cannot instrument the
hand-written asm; asm correctness remains checkasm's job), debug info,
frame pointers. ASan+UBSan share one build (`-fsanitize=address,
undefined` compose fine — verified). TSan is its own build and is
incompatible with ASan. MSan is its own build, single-threaded runs
only; it is the best-effort cell because uninstrumented host libc
corners may force the valgrind fallback instead.

### D3: TSan suppressions are data, committed

The known by-design race (threaded ratecontrol reading in-flight row
statistics — the exact issue the threaded-vbv-determinism change made
byte-repeatable by other means) gets a suppressions file in `tools/`
with a comment pointing at the analysis. Anything TSan reports outside
that file fails the cell. This converts "we know it's noisy" into
"noise is enumerated".

### D4: Fuzzer input layout is structured, not raw

`fuzz_encoder.c` consumes the input deterministically: a fixed-size
header region selects parameters from curated lists via modulo (mode
paff/mbaff/progressive, dominance, bframes 0-4, refs 1-5, rc mode,
keyint class, weightp, cabac, ...), the remainder is pixel data for
2-4 frames at fixed tiny dimensions (even width, height multiple of 4
so PAFF banding and field geometry are always legal). Rationale: raw
byte-bashing on an encoder wastes cycles on validation rejections;
structured selection keeps the fuzzer inside the interesting space.
Validation rejections return 0 — never abort — so the fuzzer learns
the boundary instead of bouncing off it.

### D5: Fuzz single-threaded; threads belong to TSan

Threading inside a fuzz target makes crashes non-reproducible and
libFuzzer unhappy, and ASan/TSan cannot combine. Threaded correctness
is the TSan cell's job; the fuzzer keeps `threads=1`.

### D6: Seeds and dictionary generated, not committed

Seeds are synthesized by the run script (a few valid parameter headers
plus gradient/noise pixels); the dictionary lists x264 option names
for the parser target. No binary media in git, consistent with the
existing suites. Crash artifacts land in a git-ignored dir.

### D7: No Makefile surgery

The harnesses build via their own script driving `configure` in the
temp copy and linking against the built `libx264.a`. The main Makefile
and default build stay untouched; if the harnesses prove their worth,
a `make fuzz` convenience target can be proposed separately.

## Risks / Trade-offs

- [MSan impractical against host glibc] → best-effort cell with a
  documented valgrind fallback; the change succeeds either way.
- [TSan flags upstream races beyond the known one (threadpool,
  lookahead)] → each gets evaluated: real bug = new change; by-design =
  suppression entry with justification. The cell is allowed to start
  life with a short curated suppressions list.
- [Fuzzer finds a flood of trivial validation-boundary issues] →
  triage cadence documented; encoder fixes land in separate changes
  (proposal states this explicitly).
- [Slow encoder limits fuzz throughput] → tiny frames, threads=1,
  `-max_len` tuned; measured throughput recorded in the docs after the
  first real session.

## Migration Plan

Additive tooling; nothing existing changes. Rollback = delete
`tools/test_sanitize.sh` and `tools/fuzz/`.

## Open Questions

None blocking. (Long-term: upstreaming the fuzz targets would make
x264 eligible for OSS-Fuzz enrollment — a nice follow-up if the
upstream MR ever moves, but independent of this change.)
