# AGENTS.md — x264

H.264/AVC video encoder from VideoLAN. Pure C with heavy hand-written assembly
optimizations. Licensed GPLv2 (a commercial license is also available; GPL-only
features can be disabled with `--disable-gpl`).

Upstream: https://code.videolan.org/videolan/x264.git

## Repository layout

- `x264.h` — **public API** of libx264. `X264_BUILD` is the ABI version; bump it
  on any ABI-breaking change (struct layout, signatures). Never change the
  public header without considering ABI.
- `x264.c`, `x264cli.h`, `autocomplete.c` — CLI frontend.
- `example.c` — minimal libx264 usage example; keep it compiling.
- `common/` — codec primitives shared by library and tests:
  - `mc.c`, `pixel.c`, `dct.c`, `quant.c`, `predict.c`, `deblock.c`,
    `cabac.c`, `bitstream.c`, ... each has a C reference implementation and
    arch-specific accelerated versions.
  - `common/x86/` — NASM/YASM assembly (`*.asm`), uses `x86inc.asm` macros.
  - `common/arm/`, `common/aarch64/` — GNU assembler (`*.S`), NEON/SVE/SVE2.
  - `common/ppc/`, `common/loongarch/`, `common/mips/` — other arch ports.
  - `common/opencl/` — OpenCL kernels (lookahead/motion search); `*.cl` files
    are embedded into `common/oclobj.h` by `tools/cltostr.sh`.
- `encoder/` — encoding pipeline: `encoder.c` (main loop), `analyse.c` (mode
  decision), `me.c` (motion estimation), `ratecontrol.c`, `lookahead.c`,
  `rdo.c`, `cabac.c`/`cavlc.c` (entropy coding), `slicetype.c`.
- `input/`, `output/`, `filters/` — CLI-only I/O modules (raw/y4m/avs/lavf/
  ffms input; raw/mkv/flv/mp4 output; video filters). Not part of the library.
- `tools/` — `checkasm.c` (ASM correctness test), `gas-preprocessor.pl`
  (needed for Apple/MSVC asm), `test_x264.py` (legacy Python 2 test driver).
- `doc/` — design notes: `ratecontrol.txt`, `threads.txt`, `standards.txt`,
  `regression_test.txt`.
- `configure`, `Makefile`, `version.sh` — build system (see below).
- Root also contains `T-REC-H.264-202606-I!!PDF-E.pdf` — the ITU-T H.264
  spec, use it as the normative reference for bitstream questions.

## Build

Custom `./configure` (bash, not autoconf) generates `config.mak`, `config.h`,
`x264_config.h`; the Makefile includes `config.mak`.

```sh
./configure                # auto-detect: threads, asm, lavf/swscale, etc.
make -j$(nproc)            # builds x264 CLI + static lib
```

Useful options: `--enable-shared`, `--enable-static`, `--disable-cli`,
`--bit-depth=8|10|all`, `--chroma-format=400|420|422|444|all`,
`--disable-asm`, `--enable-debug`, `--enable-lto`, `--enable-pic`,
`--host=... --cross-prefix=...` for cross-compilation.

Make targets: `x264` (CLI), `lib-static`, `lib-shared`, `checkasm`,
`checkasm8`, `checkasm10`, `example`, `fprofiled` (PGO build),
`clean`, `distclean`.

Build artifacts (`*.o`, `config.mak`, `x264`, `checkasm*`, ...) are
gitignored — a dirty tree usually means leftover build files; `make distclean`
before reconfiguring.

## Key architectural facts

- **Bit depth multi-build**: files in `SRCS_X` are compiled once per bit depth
  (8 and 10 bpp) with `BIT_DEPTH`/`HIGH_BIT_DEPTH` macros; headers like
  `common/common.h` and `x264.h` handle type switching (`pixel`, `dctcoef`).
  Code meant for both depths must not assume 8-bit pixels.
- **DSP dispatch pattern**: every primitive family has an `x264_*_init()`
  (C versions) plus `x264_*_init_<cpu>()` per arch filling an
  `x264_*_t` struct of function pointers at runtime based on detected CPU
  flags (`x264_cpu_detect()` in `common/cpu.c`). New ASM must keep the exact
  C prototype and be registered the same way.
- **Threading**: slice/frame threads + lookahead thread
  (`common/threadpool.c`, `encoder/lookahead.c`). See `doc/threads.txt`.
  Determinism only with `--threads 1` (used by tests).
- **Interlacing / PAFF**: two interlaced modes. MBAFF (`--interlaced`) codes a
  whole frame with optional field macroblock pairs. PAFF (`--paff`) codes each
  field as its own coded picture — a complementary field pair per input frame,
  driven by the two-pass loop in `x264_encoder_encode` (`encoder/encoder.c`,
  the `paff_*` helpers). PAFF keeps frame-level RC decisions but accounts bits
  per field and steps VBV per field access unit; per-field SEI (`pic_timing`
  pic_struct 1/2, `buffering_period`). PAFF forces `i_threads=1` (sliced
  threads rejected, frame threads deferred). PAFF and MBAFF are mutually
  exclusive. See `doc/paff.txt`. Non-PAFF output must stay bit-identical: all
  PAFF paths are gated on `param.b_paff`.
- **API versioning**: `version.sh` derives `X264_VERSION`/`X264_POINTVER`
  from git history; `x264_encoder_open` is `#define`d to
  `x264_encoder_open_<X264_BUILD>`.

## Testing

- `make checkasm` (or `checkasm8`/`checkasm10`) — **the primary test**:
  compares every ASM function against the C reference. Run it after touching
  anything in `common/` or the arch dirs. CI runs it on x86-64, aarch64,
  armv7, ppc64le and more (see `.gitlab-ci.yml`).
- Round-trip regression: encode with `--dump-yuv` and compare against the JM
  reference decoder output — procedure in `doc/regression_test.txt`.
- **Decoder-interop debugging**: a recent ffmpeg source tree is kept locally
  at `~/src/ffmpeg-trunk/` (trunk, ~7.x). Use it to read decoder internals
  when chasing warnings/errors ffmpeg's libavcodec raises on x264 output
  (e.g. PAFF MMCO/DPB-marking messages live in
  `libavcodec/h264_refs.c`). The installed binary is a separate build
  (`ffmpeg -version`); for trace decode logs use `ffmpeg -v trace`.
- `tools/test_x264.py` is legacy (Python 2, depends on bundled `digress`);
  don't rely on it for new work.
- There is no unit-test framework; correctness is checked via checkasm +
  bitstream conformance. Performance changes should be validated with
  `checkasm <function>` timing mode on the target hardware.

## Coding conventions

- C89-compatible C (declarations at block start, `/* */` comments), 4-space
  indent, no tabs, K&R braces, `snake_case`.
- Library-internal symbols prefixed `x264_`; static helpers otherwise.
  Public API only in `x264.h`.
- Avoid C99-isms in headers included by consumers; the CLI/tools are less
  strict than the library core.
- ASM: x86 uses NASM syntax + `x86inc.asm` (use `cglobal`/`cglobal_internal`,
  respect `INIT_XMM` etc.); ARM/aarch64 uses `.S` with `asm.S` macros
  (`function`, `.endfunc`). Follow the existing per-file patterns.
- No C++ constructs, no VLAs in hot paths, be careful with strict aliasing —
  the code is built with aggressive optimization (`-O3`, `-ffast-math` off).

## Discussion language

The maintainer discusses this work in Russian and has only skimmed the
H.264 spec — when replying, use plain wording, short sentences, and do not
assume familiarity with the terminology.

- Avoid machine-translated jargon: say «контрольная точка», not «гейт»;
  «блокировать» / «запрещать», not «гейтить»; «изменение» (an openspec
  change), not «чейндж»; «этап», not «майлстоун».
- Proper nouns from the spec and the code (PAFF, MBAFF, POC, SPS, SEI,
  DPB, MMCO, NAL, ...) stay as-is, but give a one-sentence explanation on
  first use in a conversation. The glossary lives in `CONTEXT.md`.
- OpenSpec artifacts (`proposal.md`, `design.md`, `tasks.md`, `specs/`)
  and code documentation are written in English — the project is
  English-language. All repository files (docs, comments, commit
  messages) must be English so the tree stays upstreamable.

## CI

`.gitlab-ci.yml` cross-compiles for many targets (Linux x86/arm/aarch64/ppc/
riscv, Windows mingw/msvc, macOS, Android) and runs `checkasm8`/`checkasm10`
where executable. A change that breaks any configure combination or asm build
fails CI — prefer feature-detecting in `configure` over assuming platform
capabilities.
