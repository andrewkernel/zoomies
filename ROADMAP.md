# Roadmap

## Phase 1: audit and research ✅ (2026-11-14)

- [x] llama-autotune audit: license, architecture, macOS support, limitations ([docs/AUDIT-llama-autotune.md](docs/AUDIT-llama-autotune.md))
- [x] Research on llama.cpp, Metal, Apple Silicon and telemetry ([RESEARCH.md](RESEARCH.md))
- [x] Integration decision: an independent Swift implementation, with llama-autotune as reference and comparison baseline
- [x] Smallest useful benchmark prototype: `zoomies probe / inspect / runtime / bench / history`, 26 tests

## Phase 2: macOS benchmark foundation (next)

Prioritized backlog. **P0** blocks everything after it.

| # | Pri | Item | Done when |
|---|---|---|---|
| 1 | P0 | ✅ Install llama.cpp and one small GGUF | Homebrew 1.0.0 (b12359), Qwen2.5-1.5B Q4_K_M in `~/Models/gguf` |
| 2 | P0 | ✅ First real runs; save real JSONL and stderr as test fixtures | `Fixtures/real-b12359-*` |
| 3 | P0 | ◐ Validate memory metrics. Done: footprint excludes mmapped weights, so RSS is now recorded too. Left: check both against `footprint`/`vmmap` with a multi-GB model | documented in RESEARCH.md as [M] |
| 4 | P0 | ◐ Noise floor. Done under memory pressure: pp ±6.4%, tg ±3.4% CI over 10 rounds. Left: repeat with other apps closed | BENCHMARKS.md |
| 5 | P1 | ✅ Parse the M5 tensor-API status from stderr into a structured field | `backendFacts` in each report; `zoomies runtime` |
| 5b | P1 | Resolve what `fa=auto` / `lm=auto` chose (verbose logs) and record it | baseline's effective FA state stored per run |
| 5c | P1 | Re-run disturbed rounds automatically (flagging already exists), within the time budget | report notes re-runs |
| 6 | P1 | Sustained-load test: 15–30 min of tg, tracking throughput against time and thermal state | drift curve for this MacBook Pro |
| 7 | P1 | Periodic baseline re-measurement (from llama.cpp `tools/tuning`) with drift rejection | runner discards rounds that drift > threshold |
| 8 | P2 | `llama-server` adapter for real TTFT and end-to-end latency | TTFT reported as measured, not derived |

## Phase 3: optimization engine

1. A search-space builder per runtime and hardware. On Metal it covers `fa`, `ub`/`b`, `ctk`/`ctv`, and `t`/`poll` (if Phase 2 shows they matter). It never covers `-C`, `--cpu-strict` or `--numa` on macOS. Partial `ngl` only when the model exceeds the working set.
2. **Coarse screen:** one llama-bench process with comma lists, so the model loads once (llama-autotune's technique). Ranking only; it never decides on its own.
3. **Successive halving:** survivors get more rounds, interleaved.
4. **Final validation:** an interleaved duel against the defaults with CIs; the winner must be `faster`.
5. Objectives: max generation, fastest response (TTFT), memory (smallest footprint with tg ≥ X% of the best), balanced (documented weights). Constraints: memory cap, time budget, minimum throughput, max thermal, battery allowed, context cap. Quantization and context are never changed silently.
6. Profiles: save, export as `llama-server` args, keep the baseline profile, roll back.
7. **Benchmark the optimizer:** compare against exhaustive grids on 2–3 models, and against llama-autotune `search` with equal benchmark budgets. Measure tuning time, evaluations, best config, validated throughput, repeatability and failure rate.

## Phase 4: Apple Silicon performance engineering

Depth sweeps (FA crossover), the KV-quantization cost/benefit curve, MoE models, and battery vs AC behaviour. If more Macs become available, compare MacBook Air against MacBook Pro cooling.

## Phase 5: SwiftUI app

A native app on ZoomiesKit, organized around the flow select model → objective → constraints → optimize → results → apply/rollback. Dashboard, model library (references files, never copies them), live progress, and an advanced mode with logs. Note: a proper `.app` bundle and notarization need full Xcode; the dev Mac currently has only the Command Line Tools.

## Phase 6: runtime integration

Launch `llama-server` with a validated profile, then verify the speedup with an A/B run.

## Phase 7: energy

Validate a no-root whole-system energy method (battery-discharge telemetry on battery power) against an external meter. Enable energy objectives only if it holds up.

## Phase 8: cross-platform

Linux/Windows `HardwareProbe`, CUDA/ROCm/Vulkan search spaces, and swift-crypto for hashing off Apple platforms. Port llama-autotune's CPU memory model and topology code (MIT, attributed).
