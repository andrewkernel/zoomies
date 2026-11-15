# Changelog

## [Unreleased] — 0.1.0-dev

### Added
- Phase 1 audit of llama-autotune (`docs/AUDIT-llama-autotune.md`) and research notes (`RESEARCH.md`).
- `ZoomiesKit` library:
  - macOS hardware probe: P/E core clusters, Metal working set, GPU cores, VM statistics, memory pressure, swap, thermal state, power source, Low Power Mode, disk.
  - GGUF v2/v3 reader and model summary, with a KV cache estimate and fingerprints.
  - llama.cpp `llama-bench` adapter: discovery, flag detection from `--help`, validation, command rendering, JSONL parsing.
  - Benchmark runner: preflight checks, seeded interleaved rounds, safety guards, cancellation, timeouts, process-group cleanup, orphan reaping after crashes, peak footprint sampling.
  - Statistics: t-based confidence intervals, Welch comparison with a relevance threshold, MAD outlier reporting.
  - SQLite result store with migrations.
- `zoomies` CLI: `probe`, `inspect`, `runtime`, `bench` (incl. `--dry-run`), `history`, `show`.
- Tests using a fake llama-bench and synthetic GGUF files.
- First real runs on an M5 MacBook Pro with Homebrew llama.cpp 1.0.0 (build 12359) and Qwen2.5-1.5B-Instruct Q4_K_M. Noise floor and a settings sweep are recorded in `BENCHMARKS.md`; findings are tagged [M] in `RESEARCH.md`.
- Peak resident memory (RSS), next to the footprint. The footprint was measured to exclude memory-mapped weights. The DB is migrated to schema v2.
- Disturbed-round detection: a round whose mean is a MAD outlier among the rounds is flagged in the report and kept.
- Backend facts parsed from llama.cpp's startup log and stored per run: `metal.has_tensor`, GPU families, residency sets, and the CPU backend variant.
- Real fixtures: `--help`, JSONL and stderr from build 12359. 29 tests.

### Fixed
- Load-mode and `-fa auto` checks matched substrings of the help line, so `lm=map` passed. They now compare against the exact `<a|b|c>` choices.
- The probe now reports the Apple10 and Metal4 GPU families (M5).
- `zoomies runtime` printed the build and commit twice. `zoomies inspect` now says the parameter count covers all tensors in the file: GGUFs that store tied embeddings twice show more than the model card.
