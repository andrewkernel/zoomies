# Zoomies

**Give your local LLM the zoomies, with receipts.**

Zoomies finds the fastest settings for running a local language model on *your* machine, and backs every recommendation with measurements and confidence intervals. It starts with llama.cpp on Apple Silicon Macs. MLX, Ollama, Windows, Linux, NVIDIA, AMD and CPU-only systems come later.

> **Status: early prototype (0.1.0-dev).** Phase 1 (audit and research) is done. The benchmark foundation is a CLI. There is no optimizer and no Mac app yet. The first real measurements (one M5 MacBook Pro, one small model) are in [BENCHMARKS.md](BENCHMARKS.md#results). They are a measurement baseline, not tuning results. See [ROADMAP.md](ROADMAP.md).

## Principles

- **Measured, not assumed.** A setting is recommended only when it beats the baseline by more than the measurement uncertainty. If your defaults are already best, Zoomies says so.
- **Honest about uncertainty.** Results are means with 95% confidence intervals across separate runs, never a single fast run.
- **Safe.** Zoomies won't start on battery (unless you allow it), when the Mac is hot, or under memory pressure. It stops a run when any of those changes, and it never needs root. Your models and configs are never modified.
- **Reproducible.** Every run stores the exact command, the runtime build, a hardware fingerprint, the model fingerprint, the random run order and every sample, in a local SQLite database.

## Requirements

- macOS 14+ on Apple Silicon (Intel Macs work, but nothing is tuned for them)
- Swift 6 toolchain: the Xcode Command Line Tools are enough
- llama.cpp's `llama-bench`. Either `brew install llama.cpp`, or the `llama-*-bin-macos-arm64.tar.gz` from [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases).
- A GGUF model file

## Build

```bash
swift build -c release
```

The binary is at `.build/release/zoomies`.

## Use

```bash
zoomies probe                      # your hardware and its current state
zoomies inspect model.gguf         # model metadata, quantization, KV-cache estimates
zoomies runtime                    # which llama-bench was found and what it supports
zoomies bench model.gguf --config "fa=off" --config "ub=1024" --dry-run   # show checks and exact commands
zoomies bench model.gguf --config "fa=off" --config "ub=1024"             # measure them against the defaults
zoomies history                    # previous runs
```

`bench` always runs llama.cpp's own defaults as the baseline. Then it runs each `--config` as separate processes over several rounds, in a shuffled order each round. Its report looks like this:

```
  fa=off
    pp: 2957.3  [2713.8–3200.7]  cv 1.2%   vs baseline -8.7% [-18.3%, +0.8%] → no detectable difference
    tg: 94.8  [80.1–109.4]  cv 2.7%   vs baseline -2.5% [-74.1%, +69.1%] → no detectable difference
```

*(Real output: M5 MacBook Pro, Qwen2.5-1.5B Q4_K_M, llama.cpp b12359. Only 2 rounds, so the intervals are wide and Zoomies won't call it either way. That is the point.)*

| Metric | Source |
|---|---|
| `pp` | prompt-processing throughput, reported by llama-bench |
| `tg` | token-generation throughput, reported by llama-bench |
| peak resident memory | the llama-bench process's peak RSS. It counts memory-mapped model weights, but can miss some GPU-side buffers. |
| peak footprint | the kernel's lifetime-max physical footprint, the "Memory" column in Activity Monitor. It **excludes memory-mapped weights**, so with llama.cpp's default loading it is far below what the model really occupies (measured: 147 MiB for a 1.04 GiB model). |
| TTFT estimate | *derived*: prompt / pp + 1 / tg. Excludes load, tokenization and sampling. |

The results database lives at `~/Library/Application Support/Zoomies/results.sqlite`.

## Test

```bash
./scripts/test.sh
```

The tests use a fake `llama-bench` and synthetic GGUF files, so they need no model and no GPU time.

## Documentation

| File | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the pieces fit |
| [RESEARCH.md](RESEARCH.md) | Evidence behind the defaults, tagged by confidence |
| [BENCHMARKS.md](BENCHMARKS.md) | Methodology and (soon) results, with reproduction commands |
| [ROADMAP.md](ROADMAP.md) | Phases and prioritized backlog |
| [docs/AUDIT-llama-autotune.md](docs/AUDIT-llama-autotune.md) | Audit of the prior-art project |
| [CHANGELOG.md](CHANGELOG.md) | Changes |
| [LICENSES.md](LICENSES.md) | Third-party licenses and attribution |
