# Architecture

```
┌────────────────────┐   ┌────────────────────────┐
│ zoomies CLI        │   │ Zoomies.app (SwiftUI)  │   front ends: no logic of their own
│ Sources/zoomies    │   │ Sources/ZoomiesApp     │
└─────────┬──────────┘   └───────────┬────────────┘
          └──────────────┬───────────┘
                    ZoomiesKit (Swift library)
 ┌──────────────┬──────────────┬───────────────┬──────────────┬─────────────┐
 │ Hardware     │ Model        │ Runtime       │ Bench / Tune │ Store       │
 │ HardwareProbe│ GGUF reader  │ RuntimeAdapter│ Plan/Runner  │ SQLite v3   │
 │  Mac (now)   │ ModelInfo    │  llama.cpp ✓  │ Stats, CI    │ runs, tunes │
 │  Linux/Win … │ ModelLibrary │  MLX, Ollama …│ Tuner,Search │ profiles    │
 └──────────────┴──────────────┴───────┬───────┴──────┬───────┴─────────────┘
                                       │              │
                                Process/ChildProcess (posix_spawn, process group,
                                footprint sampling, guards, orphan reaping)
```

## Modules (`Sources/ZoomiesKit`)

| Path | Responsibility |
|---|---|
| `Hardware/HardwareInfo.swift` | Platform-neutral types. `HardwareInfo` holds static facts and feeds the fingerprint. `SystemState` holds what changes: memory, thermal, power, disk. `Sourced<T>` records where every value came from, or why it is unavailable. The `HardwareProbe` protocol. |
| `Hardware/MacHardwareProbe.swift` | sysctl (`hw.perflevelN.*`, `hw.memsize`, `kern.memorystatus_vm_pressure_level`, `vm.swapusage`); Mach `host_statistics64`; Metal (`recommendedMaxWorkingSetSize`, `hasUnifiedMemory`); IORegistry `gpu-core-count` (an undocumented key, labelled as such); IOKit power sources; `ProcessInfo.thermalState`. No root, no private frameworks. |
| `Model/GGUF.swift` | GGUF v2/v3 header, metadata and tensor-table parser over a memory-mapped file. Tensor data is never read. Large arrays such as tokenizer vocabularies are skipped. Throws a clear error for truncated or corrupt files. |
| `Model/ModelInfo.swift` | The summary the rest of the system uses: architecture, quantization, parameters, bytes per tensor type, attention shape, MoE, a quick fingerprint (SHA-256 of size + first and last 4 MiB), an optional full SHA-256, and the KV cache estimate. |
| `Runtime/RuntimeAdapter.swift` | `InferenceConfig` (nil means "runtime default", which differs from writing the default explicitly); `Workload`; `TestMeasurement`; the `RuntimeAdapter` protocol (`discover`, `validate`, `benchmarkCommand`, `parseBenchmarkOutput`). |
| `LlamaCpp/LlamaBenchAdapter.swift` | Finds llama-bench (never in the current directory). Fingerprints the build from `--version`, `--help` and `--list-devices`. Validates configs against the flags that build actually has: an old build without `-lm`, or `-fa` without `auto`, is rejected. Renders the command and parses JSONL. |
| `Process/ChildProcess.swift` | Runs a benchmark child via `posix_spawn` in its own process group, with default signal handling and only fds 0–2 inherited. stdout and stderr go to files, so the child can never block on a full pipe. Samples `proc_pid_rusage` v6 every 250 ms: the lifetime-max footprint (which excludes mmapped weights), resident size (which includes them), CPU time and `ri_energy_nj`. It also takes `ru_maxrss` from wait4. Timeout, Swift task cancellation, and guard callbacks stop the whole group with SIGTERM, then SIGKILL. `ChildRegistry` writes a pid file per child so the next start can stop orphans after a crash; it checks `proc_pidpath` first, so a reused pid is left alone. |
| `Bench/BenchmarkRunner.swift` | `BenchmarkPlan` (seeded schedule with a shuffled order per round), preflight checks, the run loop with safety guards, aggregation and drift warnings. |
| `Bench/Stats.swift` | Mean, standard deviation, median, MAD outliers (reported, never dropped), 95% t-intervals, and a Welch comparison with a relevance threshold. |
| `Bench/ContextCost.swift` | Prompt and generation speed at several context depths in one process (`zoomies cost`). |
| `Tune/TuneTypes.swift` | Objectives, budgets, dimensions, constraints, the tune report and decision, events. |
| `Tune/SearchSpace.swift` | Which values of which settings are worth trying for this build, model, workload and machine, and why the others are skipped. |
| `Tune/Tuner.swift` | The staged engine: screen (one-process sweeps, compared within the process), compose, narrow (successive halving against the defaults), verify (fresh paired rounds, relevance threshold, guardrail). |
| `Tune/Profile.swift` | Saved profiles and `ServerCommand`, which turns a profile into a `llama-server` command that pins the defaults where llama-server and llama-bench differ. |
| `Model/ModelLibrary.swift` | Finds GGUFs in common folders and Ollama's blob store; skips vision projectors and parts 2..N of split models. |
| `Store/TuneStore.swift` | Tune runs, profiles and the append-only activation history behind apply and rollback. |
| `Store/ResultStore.swift` | SQLite with versioned migrations. Queryable tables (`runs`, `trials`, `samples`, `summaries`), plus the full report as JSON so nothing is lost. |

## Key design decisions

1. **Swift, not a fork of the Python llama-autotune.** The reasoning is in [docs/AUDIT-llama-autotune.md §10](docs/AUDIT-llama-autotune.md). Swift runs on Linux and Windows too. Platform specifics stay behind `HardwareProbe` and `RuntimeAdapter`; the optimizer will only see platform-neutral types.
2. **The round, not the repetition, is the unit of replication.** Repetitions inside one llama-bench process share the load placement, caches and thermal moment, so they are not independent. Confidence intervals use per-round means, n = rounds. All repetitions are still stored, and are used for outlier and spread reporting.
3. **"Faster" needs significance *and* relevance.** The whole 95% CI must sit above zero, and the gain must be at least 2%. Anything else is reported as "no detectable difference".
4. **Runtime defaults are a first-class config.** The baseline is "whatever this build does with no flags", and it is recorded exactly. Defaults change between builds; for example, `-fa` became `auto`.
5. **Validate before spending GPU time.** Configs a build cannot run (missing flags, a quantized V cache without FA, a bad KV type) are blocked in preflight. Unwise ones, such as partial offload on unified memory, get a warning.
6. **Never invent telemetry.** An unavailable value is `nil` with a reason. Derived numbers, such as the TTFT estimate, are named as derived everywhere they appear.

## The app (`Sources/ZoomiesApp`)

`AppModel` (`@Observable`, main actor) owns the state and calls ZoomiesKit. The tuner runs in a detached task; its events hop back to the main actor. Views: `RootView` (tabs, centre card, chips with floating menus anchored above them, a fixed-height result area so nothing shifts), `ResultViews` (live run, receipt with CI bars, details, profiles, history), `Theme`, and `AsciiField`. `AsciiField` renders the background swirl off the main thread into a reused alpha-only bitmap: per frame, all glyphs of a brightness band go to CoreText in one call. It drops to 6 fps while a tune runs, so the decoration never competes with the measurement. `scripts/build-app.sh` wraps the binary into an ad-hoc-signed `Zoomies.app` (and a DMG) with the Command Line Tools alone.

## Planned additions

- **`LlamaCpp/LlamaServerAdapter`**: real TTFT and end-to-end latency via `llama-server` streaming; A/B verification of profiles through the server.
- **More runtimes** behind `RuntimeAdapter`: MLX, and Ollama as a runtime (Ollama's models are already found).
