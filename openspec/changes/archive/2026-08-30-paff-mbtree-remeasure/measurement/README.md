# paff-mbtree-remeasure — archived measurement (2026-08-30)

Raw point sets and reference scripts from the measurement session that
closed the "Per-field mbtree propagation" future-work item (doc/paff.txt;
protocol and gates: design.md D1, results: D2).

- `results2.csv` — the full matrix point sets (PSNR-Y and bytes per cell);
  the design.md D2 table is computed from this file.
- `bdrate2.py` — the session's reference BD-rate implementation.
  `tools/bdrate.py` is the ported general-purpose version; task 1.1
  verifies it against `results2.csv`.
- `results.csv` — the FIRST amv run, whose flat ~17.9 dB PSNR exposed the
  timestamp-pairing pitfall (design.md D4).  Kept as evidence of the trap,
  not as measurement data.
- `align.py`, `encode_all.sh`, `measure_all.sh`, `run_matrix*.sh` —
  session scripts, kept for provenance.  Clips and encoded outputs are
  not archived (size); `tools/test_paff.sh mbtree` re-creates everything
  from sources.
