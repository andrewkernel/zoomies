# Technical audit: llama-autotune

Audited 2026-11-14 at commit `0e66e62` (main, 2026-11-10, v0.5.0 + unreleased fixes), on a MacBook Pro (Mac17,2, Apple M5, 16 GB, macOS 26.5.2).
Repository: <https://github.com/Najafu/llama-autotune>

**Summary.** llama-autotune is a careful, well-tested CPU tuner for llama.cpp, and its measurement protocol is better than most. Its main command, `tune`, refuses to run on Apple Silicon with a Metal build of llama.cpp, and its macOS hardware detection misreports the CPU. **Recommendation:** don't fork it. Build Zoomies as an independent Swift implementation that reuses its *ideas*, with attribution, and use llama-autotune itself as the comparison baseline.

## 1. License

| Item | Finding |
|---|---|
| Project license | **MIT** (`LICENSE`; `pyproject.toml` says `license = {text = "MIT"}`) |
| Copyright line | "Copyright (c) 2026 llama-autotune". The holder is the project name, not a person. All 25 commits are by one author (Philipp H. Rubner). |
| Runtime dependencies | typer (MIT), pydantic (MIT), rich (MIT), optuna (MIT), psutil (BSD-3-Clause). All permissive. |
| Dev dependency | pytest (MIT) |
| Compatibility | Reusing its code or test data in a proprietary or open product is allowed if the MIT notice is kept. |

Zoomies copies **no source code** from llama-autotune. It copies one test fixture: `llama-bench-b11347-help.txt`, which is llama.cpp's own `--help` output (llama.cpp is also MIT). Ideas adopted from it are credited in [LICENSES.md](../LICENSES.md).

## 2. Architecture

The project is Python, about 6,300 lines of source plus about 5,000 lines of tests, with a Typer CLI.

| Module | Role |
|---|---|
| `cli.py` (1,074) | Commands: `setup`, `doctor`, `tune`, `launch`, `search`, `benchmark`, `models`, `export`, ... |
| `tuner.py` (732) | `tune`: the CPU measurement protocol (predict → baseline → screen → confirm → duel → prompt settings → long chat) |
| `optimizer.py` (497) | `search`: rule baseline, then one-at-a-time grid, then Optuna TPE, then a final duel |
| `compat.py` (703) | Reads `--help`/`--version` of the installed build, keeps a flag registry, renders only flags that build accepts |
| `constraints.py`, `memory.py` | Memory gate: weights + repacked copy + KV + compute buffer + runtime, checked against free RAM minus a margin |
| `model_inspector.py` | GGUF parser (architecture, MoE, per-layer attention layout) |
| `benchmark.py` | llama-bench subprocess, JSONL parser, RAM watchdog (psutil, 4 Hz) |
| `resources.py`, `hardware.py` | CPU topology (Win32, Linux sysfs), RAM, bandwidth probe; GPUs taken from `llama-bench --list-devices` |
| `database.py` | SQLite at `~/.llama-autotune/benchmarks.db` |

## 3. Hardware detection

- **Windows:** strong. `GetLogicalProcessorInformationEx` gives efficiency classes, processor groups and NUMA.
- **Linux:** hybrid Intel P/E split via `/sys/devices/cpu_core` and `cpu_atom`.
- **macOS: falls back to psutil.** No `hw.perflevel*` sysctls are read. On this M5 the result is:

  ```
  physical_cores=10 performance_cores=10 efficiency_cores=0 gpu_count=0 backend=cpu ram_available_gb=3.56
  ```

  So the 6 efficiency cores are treated as performance cores, and its "never use efficiency cores" rule cannot take effect on Macs. The GPU is unknown unless llama.cpp is installed.

## 4. Search algorithms

- **`tune` (CPU only).** It screens all candidates in one llama-bench process using comma lists, so the model loads only once. It then confirms the best third with 3 repetitions (a form of successive halving), adds the untested neighbouring thread counts, and runs an **interleaved duel** against the defaults: three or more pairs, deciding on the median of the paired ratios. A setting must win by more than max(4%, 2 × the relative standard deviation) to replace a default. It then tests a long chat at depth 2,048 with flash attention both on and off. The protocol is well reasoned and documented with measured examples.
- **`search` (experimental, GPU allowed).** It runs a rule-based baseline, sweeps `threads`/`batch`/`ubatch`/`n_gpu_layers` one at a time, then runs Optuna TPE, and finishes with a duel. The README tells users to prefer `tune`.

## 5. Benchmark methodology

**Strengths, which Zoomies adopts:**
- runs interleave
- noise thresholds instead of trusting the single best run
- `LLAMA_ARG_*` environment variables are scrubbed
- flags come from the build's own `--help`
- tests run at depth as well as on an empty context
- the memory watchdog
- the llama.cpp build is stored with every result

**Gaps:**
- There are no confidence intervals. Decisions use thresholds, and the reports show point estimates.
- Repetitions inside one llama-bench process are treated as independent samples, in screening and confirmation.
- Peak memory is the psutil RSS of llama-bench. On Apple Silicon, Metal buffers are not necessarily RSS (hypothesis, not yet measured).
- The watchdog kills only the direct child (`proc.kill()`), not its process group.
- `flash_attn` is a `bool | None`, so the build's actual default, `auto`, cannot be pinned explicitly.
- It has no time-to-first-token (TTFT) or energy measurement.

## 6. llama.cpp parameters covered

`SearchConfig` has fields for threads, threads_batch, batch, ubatch, ctx, n_gpu_layers, flash_attn, tensor_split, split_mode, main_gpu, cache_type_k/v, load_mode, repack, numa, cpu_affinity, parallel, no_kv_offload, n_cpu_moe, cache_ram, ctx_checkpoints. `tune` actively searches only threads, `-tb`, `-fa`, `--repack`, `-ub` and `--numa`.

## 7. macOS / Apple Silicon compatibility

| Area | Status |
|---|---|
| Install and unit tests | Pass: **252 passed, 9 skipped** on this Mac (Python 3.14.6). CI runs macOS, Linux and Windows on Python 3.12 to 3.14. |
| `tune` with Metal llama.cpp | **Refused.** `cli.py:394`: `if hw.backend != Backend.CPU: ... "GPU tuning comes in a later version"; raise typer.Exit(code=1)`. Homebrew and the official macOS release are Metal builds, so `tune` does not work on a normal Apple Silicon setup. |
| E-core handling | Wrong on macOS (see §3) |
| Memory gate on unified memory | Based on psutil `available` (3.56 GB here, while `memory_pressure` reported 32% free). It does not use Metal's `recommendedMaxWorkingSetSize`. |
| Thread affinity / NUMA options | Offered generally, but no-ops on macOS: ggml's affinity code is empty under `__APPLE__` (see RESEARCH.md) |
| M5 Neural Accelerator (Metal tensor API) status | Not detected or recorded |

## 8. Bugs and limitations, by importance for us

1. **No Metal tuning at all** in the main command (`tune`).
2. macOS core topology is misdetected (E-cores counted as P-cores).
3. No uncertainty reporting (no confidence intervals) and pseudo-replication within one process.
4. The memory model and watchdog are calibrated for CPU RAM, not unified memory or the GPU working set.
5. `flash_attn` cannot represent `auto`.
6. Watchdog cleanup does not cover the process group.
7. No TTFT, sustained-load or thermal-drift detection, and no energy measurement.

## 9. Tests, releases and maintenance

- 26 test files with mocked llama-bench output and a GGUF writer. CI runs on 3 operating systems × 3 Python versions.
- Releases are git tags (v0.1.0, v0.3.0, v0.4.0, v0.5.0) with a maintained CHANGELOG. There is no PyPI release; users install from git with `uv tool install`.
- One maintainer, 25 commits between 2026-06-30 and 2026-11-10. Actively maintained, but with a bus factor of one.

## 10. Integration decision

| Option | Assessment |
|---|---|
| Fork and extend | We would inherit a Windows-first CPU design, a Python runtime to bundle inside a Mac app, and a `tune` pipeline that needs restructuring for GPU anyway. Reasonable for a Python CLI product, a poor fit for a native SwiftUI product. **No.** |
| Use as an optimization backend | It has no Metal support and is not a library (CLI only, Python). **No**, except as below. |
| **Independent Swift implementation (chosen)** | Native macOS APIs are first-class: Metal working set, `proc_pid_rusage` footprint, IOKit power, the thermal state API. It ships as a single binary inside the app. We reuse its proven *ideas* with credit and keep its code as a reference. |

What we keep from llama-autotune:
1. **Comparison baseline.** Equal-budget comparisons run its `search` command (it allows GPUs), and its `tune` for CPU-only (`-ngl 0`) comparisons.
2. **Design reference** for features we port later: the memory model (repacked copy, compute buffer), Windows and Linux topology, and the CPU screening protocol.
3. **Upstream contributions** (optional, offered to its maintainer): reading `hw.perflevel*` on macOS, and a `flash_attn` tri-state.
