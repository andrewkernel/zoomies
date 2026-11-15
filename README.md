# Zoomies

**Give your local LLM the zoomies, with receipts.**

Zoomies finds faster settings for running a local language model on *your* Mac, and only recommends a change after it has beaten llama.cpp's defaults on fresh, repeated measurements. If your defaults are already the best, it tells you so.

It comes as a Mac app and a command-line tool. It works with any GGUF model, including the ones you already have in Ollama, LM Studio or the llama.cpp cache.

> **Status: 0.2.0, early.** Apple Silicon Macs with llama.cpp. MLX, Ollama as a runtime, and Linux/Windows come later. See [ROADMAP.md](ROADMAP.md) and the measured results in [BENCHMARKS.md](BENCHMARKS.md).

## Install

You need macOS 14 or newer, Apple's free Command Line Tools (`xcode-select --install`), and llama.cpp (`brew install llama.cpp`).

**Homebrew** (the command-line tool; also installs llama.cpp):

```bash
brew install andrewkernel/zoomies/zoomies
```

**Install script** (the command-line tool and the Mac app, built on your Mac):

```bash
curl -fsSL https://raw.githubusercontent.com/andrewkernel/zoomies/main/install.sh | sh
```

**From source:**

```bash
git clone https://github.com/andrewkernel/zoomies && cd zoomies
swift build -c release            # .build/release/zoomies
./scripts/build-app.sh            # .build/Zoomies.app
```

Zoomies isn't signed with an Apple Developer ID yet. Building it yourself (all three routes above) avoids macOS's "unidentified developer" warning entirely. If you download a prebuilt `Zoomies.app` from Releases instead, open it once, then go to System Settings → Privacy & Security and click **Open Anyway**.

## Use

### The app

Open Zoomies, pick a model and a goal, press **↑**. The centre card holds every setting:

| Chip | What it sets |
|---|---|
| ● AC / battery | Whether this Mac is ready to measure (plugged in, cool, enough memory), plus runtime details |
| Model | Any GGUF on this Mac, or choose a file |
| Context | How much conversation is already in context while measuring (empty, 2k, 8k, 32k) |
| Goal | Fastest replies · fastest first token · balanced · least memory, and whether quantized KV caches may be tried |
| Budget | Quick · Standard · Thorough |

While it runs, you see each stage live, and the background swirl spins with the measured speed. The result is a receipt: the change, its 95% confidence interval, what happened to the other metric, and buttons to **Apply**, **Undo**, or **Copy the llama-server command**.

### The command line

```bash
zoomies models                          # GGUF models on this Mac (incl. Ollama, LM Studio)
zoomies tune qwen3-14b                  # find faster settings and verify them
zoomies tune qwen3-14b --goal response --context 8192 --budget thorough
zoomies tune qwen3-14b --dry-run        # what would be tried, and the exact commands
zoomies profiles                        # saved results; * = active
zoomies apply 3f2a91c0                  # make a profile active
zoomies rollback qwen3-14b              # back to the previous one
zoomies export qwen3-14b -c 8192        # the llama-server command for the active profile
zoomies serve qwen3-14b -c 8192         # start llama-server with it
zoomies cost qwen3-14b                  # seconds per 1k prompt tokens as the context grows
zoomies bench model.gguf --config "fa=off" --config "ub=1024"   # compare settings yourself
```

Models can be given by path or by name from `zoomies models`.

## How tuning works

1. **Screen.** For each setting (flash attention, micro-batch, threads, polling, optionally the KV cache type), one llama-bench process tries every value with the model loaded once. Each value is compared with the default *in the same process*.
2. **Narrow.** The best values, alone and combined, race the defaults as separate processes in a shuffled order; the bottom half is dropped each round.
3. **Verify.** The survivor and the defaults run again on fresh rounds. A change is recommended only if the 95% confidence interval of the paired difference is above zero, the gain is at least 2%, and the other metric didn't get more than 5% worse.

Fresh data in step 3 matters: picking the best of several noisy measurements flatters the winner, so the measurements that picked it can't also judge it.

Settings that can't matter are never tried (a micro-batch larger than the prompt, partial GPU offload for a model that fits, thread pinning, which macOS doesn't support). Settings that change the model's output (quantized KV cache) are tried only if you allow it.

**Safety.** Zoomies won't start on battery (unless you allow it), when the Mac is hot, or under memory pressure, and stops if any of that changes mid-run, including more than 1 GiB of new swap. It never needs root, never modifies your models, and never edits your own configs: profiles live in Zoomies and are exported as commands.

**Receipts.** Every measurement, command line, runtime build, hardware and model fingerprint, and random seed is stored in `~/Library/Application Support/Zoomies/results.sqlite`.

## What it measures

| Metric | Source |
|---|---|
| prompt speed (pp) | prompt-processing tokens/s, reported by llama-bench |
| generation speed (tg) | generation tokens/s, reported by llama-bench |
| peak resident memory | the llama-bench process's peak RSS; counts memory-mapped weights, can miss some GPU buffers |
| peak footprint | Activity Monitor's "Memory"; **excludes memory-mapped weights** (measured: 147 MiB for a 1.04 GiB model) |
| time-to-first-token estimate | *derived*: prompt / pp + 1 / tg; excludes load, tokenization and sampling |

## Development

```bash
./scripts/test.sh                 # 45+ tests; a fake llama-bench, no model or GPU needed
./scripts/build-app.sh --dmg      # app bundle and disk image
```

| File | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the pieces fit |
| [RESEARCH.md](RESEARCH.md) | Evidence behind the defaults, tagged by confidence |
| [BENCHMARKS.md](BENCHMARKS.md) | Methodology and measured results, with reproduction commands |
| [ROADMAP.md](ROADMAP.md) | Phases and backlog |
| [docs/AUDIT-llama-autotune.md](docs/AUDIT-llama-autotune.md) | Audit of the prior-art project |
| [CHANGELOG.md](CHANGELOG.md) | Changes |
| [LICENSE](LICENSE) · [LICENSES.md](LICENSES.md) | MIT; third-party notices |
