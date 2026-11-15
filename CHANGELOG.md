# Changelog

## 0.2.0 — 2026-11-14

### Added
- **Auto-tuner** (`ZoomiesKit/Tune`, `zoomies tune`). Screen → narrow → verify:
  - **Screen:** each setting is swept in one llama-bench process (comma lists, model loaded once) and compared with its default inside the same process. A setting falls back to one process per value if the sweep fails.
  - **Narrow:** successive halving of candidates against the defaults, interleaved.
  - **Verify:** a fresh-data duel with a paired per-round comparison. The win must be significant and at least 2%, and the other metric must stay within a guardrail (5% by default).
  - Objectives: fastest replies (tg), fastest first token (pp), balanced (geometric mean), least memory (footprint, with a speed guardrail).
  - Budgets: quick, standard, thorough. A time limit and seeds make runs reproducible.
  - Search space rules: settings the build lacks are skipped; a ubatch larger than the prompt is never tried; KV quantization only runs when allowed, since it changes output; partial offload only when the model exceeds the GPU working set; thread pinning is never tried on macOS.
- **Profiles:** save, apply, roll back (an append-only activation history) and export (`zoomies profiles/apply/rollback/export`). Each profile is exported as a `llama-server` command that pins threads and GPU layers, because llama-server's defaults differ from llama-bench's (`-t -1` and `-ngl auto` vs `-t 4` and `-ngl -1`). `zoomies serve` starts llama-server with the active profile, with `LLAMA_ARG_*` removed.
- **Model library** (`zoomies models`): finds GGUFs in ~/Models, LM Studio, the llama.cpp and Hugging Face caches, and Ollama's blob store (via its manifests). Commands accept a model name as well as a path.
- **Split GGUF models** (`-00001-of-0000N`): all parts are read, so size and memory checks are right. A missing part is an error.
- **`zoomies cost`:** seconds per 1k prompt tokens and reply speed at 0/4k/16k/32k context, in one process.
- **Mac app** (`ZoomiesApp`, `scripts/build-app.sh`):
  - Layout: a centre card with chips for model, context, goal and budget, plus a readiness chip; floating menus; live stages with live tokens/s; a receipt with CI bars, Apply, Undo, and copying the server command; Profiles and History tabs; Settings (⌘,).
  - Background: an animated ASCII swirl, rendered off the main thread. It uses about 5% CPU when idle and drops to 6 fps during tunes, so it doesn't disturb measurements.
- Distribution: MIT `LICENSE`; `install.sh`, which builds from source (no Gatekeeper warning); a Homebrew tap formula; an ad-hoc signed `.app` and `.dmg` build script.
- Store schema v3: `tune_runs`, `profiles`, `profile_activations`.
- Statistics: `Comparison.pairedRatio`, a paired comparison on log-ratios.

### Changed
- The runner's guard and single-process execution are reusable (`BenchmarkRunner.makeGuard`, `execute`); a tune measures swap growth from its own start.
- The fake llama-bench used in tests now behaves like the real one: comma-list cross products and effective settings in each JSONL record.

## 0.1.0-dev

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
