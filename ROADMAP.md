# Roadmap

## Phase 1: audit and research ✅ (2026-11-14)

- [x] llama-autotune audit: license, architecture, macOS support, limitations ([docs/AUDIT-llama-autotune.md](docs/AUDIT-llama-autotune.md))
- [x] Research on llama.cpp, Metal, Apple Silicon and telemetry ([RESEARCH.md](RESEARCH.md))
- [x] Integration decision: an independent Swift implementation, with llama-autotune as reference and comparison baseline
- [x] Smallest useful benchmark prototype: `zoomies probe / inspect / runtime / bench / history`, 26 tests

## Phase 2: macOS benchmark foundation (mostly done)

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

## Phase 3: optimization engine ✅ v1 (0.2.0)

- [x] Search-space builder per runtime, model and hardware (`SearchSpace`): fa, ub, b, KV type (opt-in), t, poll, partial ngl only when the model exceeds the GPU working set; never `-C`/`--cpu-strict`/`--numa` on macOS
- [x] Coarse screen with llama-bench comma lists, compared inside one process; per-value fallback
- [x] Successive halving, interleaved against the defaults
- [x] Fresh-data verification with a paired per-round comparison, a 2% relevance threshold and a guardrail on the other metric
- [x] Objectives: generation, response, balanced, memory. Budgets, time limit, seeds
- [x] Profiles: save, apply, roll back, export as `llama-server` args; `zoomies serve`
- [ ] Constraints: memory cap and minimum throughput as hard filters (the guardrail covers the common case)
- [ ] **Benchmark the optimizer:** against exhaustive grids on 2–3 models, and against llama-autotune `search` at equal budgets (tuning time, evaluations, validated throughput, repeatability, failure rate)
- [ ] Interaction screening (2-factor sweeps) on the thorough budget

## Phase 4: Apple Silicon performance engineering

Depth sweeps (FA crossover), the KV-quantization cost/benefit curve, MoE models, and battery vs AC behaviour. If more Macs become available, compare MacBook Air against MacBook Pro cooling.

## Phase 5: Mac app ✅ v1 (0.2.0)

- [x] One-window app: a centre card with model, context, goal and budget chips and a readiness chip; live stages; a receipt with CI bars; Apply, Undo and copying the server command; Profiles and History; Settings
- [x] Model library (references files where they are; finds Ollama, LM Studio, llama.cpp and HF caches)
- [x] App bundle and DMG built with the Command Line Tools only (ad-hoc signed)
- [ ] Developer ID signing and notarization (needs the Apple Developer Program), Sparkle updates
- [ ] "Advanced" view with raw logs and per-process tables
- [ ] Launch and manage `llama-server` from the app

## Phase 6: runtime integration

- [x] `zoomies serve`: start llama-server with the active profile, with defaults that differ from llama-bench pinned
- [ ] A/B-verify the profile through llama-server itself (measured TTFT and end-to-end latency)
- [ ] Context cost tooling (`zoomies cost`) as the baseline for context-reduction features (read gating, reranking)

## Phase 7: energy

Validate a no-root whole-system energy method (battery-discharge telemetry on battery power) against an external meter. Enable energy objectives only if it holds up.

## Phase 8: cross-platform

Linux/Windows `HardwareProbe`, CUDA/ROCm/Vulkan search spaces, and swift-crypto for hashing off Apple platforms. Port llama-autotune's CPU memory model and topology code (MIT, attributed).
