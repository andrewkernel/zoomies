# Research notes

Evidence behind Zoomies' defaults and search spaces. Each claim is tagged:

- **[V] verified-source**: read in source code or official docs
- **[C] community evidence**: benchmarks or discussions by others
- **[H] hypothesis**: plausible, not yet confirmed
- **[M] measured by Zoomies**: on our hardware, with the command recorded in [BENCHMARKS.md](BENCHMARKS.md)

Collected 2026-11-14 against llama.cpp `master` (latest release b12387). The sources below come from a research pass on that date. The local facts (sysctl, SDK headers) were checked on the dev Mac. **[M] results so far come from one machine** (MacBook Pro M5, 16 GB, macOS 26.5.2) with Homebrew llama.cpp 1.0.0 (build 12359) and one small model; see [Measured on the dev Mac](#measured-on-the-dev-mac-2026-11-14).

## llama-bench as a measurement tool

- **Flags.** `-p`, `-n`, `-pg`, `-d`, `-b` (2048), `-ub` (512), `-ctk`/`-ctv` (f16), `-t`, `-C`, `--cpu-strict`, `--poll` (50), `-ngl` (-1 = all), `-ncmoe`, `-sm`, `-mg`, `-nkvo`, `-fa on|off|auto` (default **auto**), `-dev`, `-lm/--load-mode`, `-lzm`, `-embd`, `-ts`, `-ot`, `-nopo`, `--no-host`, `--repack`, `-r` (5), `--prio`, `--delay`, `-o jsonl`, `--no-warmup`, `-fitt`/`-fitc` [V] ([llama-bench.cpp](https://github.com/ggml-org/llama.cpp/blob/master/tools/llama-bench/llama-bench.cpp), [README](https://github.com/ggml-org/llama.cpp/blob/master/tools/llama-bench/README.md)).
- **`-mmp` was removed** and folded into `-lm` ([PR #20834](https://github.com/ggml-org/llama.cpp/pull/20834), [#26934](https://github.com/ggml-org/llama.cpp/pull/26934)) [V]. Zoomies checks for flags against `--help` instead of assuming they exist.
- **Sweeping.** Every test option except `-r`, `-o` and `-v` takes comma lists or ranges, and the tests run the cross product [V].
- **Context per test.** Each test uses `n_ctx = n_prompt + n_gen + n_depth` [V].
- **JSONL fields:** `build_commit`, `build_number`, `cpu_info`, `gpu_info`, `backends`, `model_type`, `model_size`, `model_n_params`, all effective settings, `n_prompt`, `n_gen`, `n_depth`, `avg_ts`, `stddev_ts`, `samples_ts`, `samples_ns` [V].
- **What llama-bench does not measure.**
  - **There is no TTFT or peak-memory metric [V].** Tokenization and sampling are outside the timings.
  - **TTFT** needs `llama-server` per-request `timings.prompt_ms` ([server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)) [V].
  - **Peak memory**: Zoomies samples `ri_lifetime_max_phys_footprint` and `ri_resident_size` via `proc_pid_rusage`, plus `ru_maxrss` from wait4 [V]. **The footprint excludes memory-mapped weights** [M]; see the measurements below.

## Apple Silicon / Metal

- **Full offload (`-ngl`).**
  - The default is all layers. The input embedding layer always stays on the CPU by design ([llama-model.cpp](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-model.cpp)) [V].
  - Partial offload on unified memory is usually slower [H]. Zoomies only warns about it; it is not searched unless the model exceeds the GPU working set.
- **Threads.**
  - `-t` defaults to `hw.perflevel0.physicalcpu` (4 on the M5) ([common.cpp](https://github.com/ggml-org/llama.cpp/blob/master/common/common.cpp)) [V].
  - The Metal backend's submit-thread count is fixed and independent of `-t` ([ggml-metal.cpp](https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-metal/ggml-metal.cpp)) [V].
  - So with full offload, `-t` should matter little [H], and `--poll 50` busy-waiting may cost power [H]. Both need measuring.
- **Affinity is not possible on macOS.**
  - ggml's affinity code is a no-op under `__APPLE__` ([ggml-cpu.c](https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-cpu/ggml-cpu.c)) [V].
  - Apple's [Thread Affinity API notes](https://developer.apple.com/library/archive/releasenotes/Performance/RN-AffinityAPI/index.html) say explicit binding is unsupported [V].
  - **Zoomies never searches `-C`, `--cpu-strict` or `--numa` on macOS.**
- **Flash attention.**
  - `auto` is the default, and turns FA on when the op runs on the same device as its layer ([llama-context.cpp](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-context.cpp)) [V]. With full Metal offload, `auto` means on.
  - The benefit grows with context depth [C]: on M5 Pro, pp512 at depth 32,768 went from 174 to 253 t/s ([PR #29570](https://github.com/ggml-org/llama.cpp/pull/29570)).
  - **Zoomies therefore tests FA at depth > 0, not only on an empty context.**
- **Quantized KV cache.**
  - A quantized V cache requires FA [V]; Zoomies rejects `fa=off` with a quantized V cache before running.
  - Metal FA supports F16, Q4_0, Q4_1, Q5_0, Q5_1 and Q8_0 for K and V, and the non-vec kernels dequantize to F16 first ([ggml-metal-device.m](https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-metal/ggml-metal-device.m)) [V]. A pp cost is likely [H].
- **M5 Neural Accelerators.**
  - Each of the base M5's 10 GPU cores has one, and memory bandwidth is 153 GB/s ([Apple Newsroom](https://www.apple.com/newsroom/2025/10/apple-unleashes-m5-the-next-big-leap-in-ai-performance-for-apple-silicon/)) [V].
  - llama.cpp enables the Metal 4 tensor API only for M5/M6/A19/A20 device names, after a test-compile [V].
  - A probe bug that silently disabled it was fixed in [#27461](https://github.com/ggml-org/llama.cpp/pull/27461) [V]. Reported gains are about +26% geomean pp on M5 Max ([#20962](https://github.com/ggml-org/llama.cpp/pull/20962)) [C].
  - **Zoomies keeps the "tensor API" stderr lines with every run**, so a build that silently lost it is visible.
  - MLX uses the same hardware on macOS 26.2+ ([Apple ML Research](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)) [V].
- **Environment variables.** `GGML_METAL_*` covers `TENSOR_ENABLE/DISABLE`, `CONCURRENCY_DISABLE`, `GRAPH_OPTIMIZE_DISABLE`, `FUSION_DISABLE`, `NO_RESIDENCY`, `RESIDENCY_KEEP_ALIVE_S` (default 180 s), and others [V]. The residency keep-alive may make back-to-back runs share warm state [H]; this is one reason Zoomies shuffles the run order.
- **Batch and ubatch.**
  - `-ub` matters only when `-p` > `-ub` [V].
  - pp is expected to plateau between 512 and 2,048 [H]. No clean Metal sweep has been published, so it must be measured.

## Memory on unified-memory Macs

- **mmap.**
  - Under `-lm auto`, Metal uses mmap and wraps the weights zero-copy (`newBufferWithBytesNoCopy`) [V] ([#26081](https://github.com/ggml-org/llama.cpp/pull/26081)).
  - `none`/`dio` read the weights into new buffers [V]: slower load, more memory pressure [H].
- **GPU working set.**
  - `recommendedMaxWorkingSetSize` is Apple's limit for good GPU performance ([docs](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize)) [V]. The default fraction is undocumented; about 2/3 of RAM for 32 GB or less is a community report [C].
  - **Measured on the dev Mac: 11.84 GiB of 16 GiB (74%)**, read via Metal.
  - Raising it needs `sudo sysctl iogpu.wired_limit_mb`. **Zoomies never changes it.**
- **KV cache size.** `n_ctx × Σ_layers (n_head_kv × head_dim_k × bytes_k + n_head_kv × head_dim_v × bytes_v)` [V] ([llama-kv-cache.cpp](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-kv-cache.cpp)). Sliding-window and hybrid layers use less. Zoomies' estimate assumes full attention on every layer, so it is an upper bound.
- **"Available memory" is an estimate.** Zoomies uses total − (app memory − purgeable) − wired − compressed, following Activity Monitor's breakdown. On the dev Mac this gave 2.6–3.4 GiB, while psutil said 3.56 GiB and `memory_pressure` said 32% free. Those three numbers disagree, so the preflight warns rather than blocks unless the model exceeds 85% of RAM.

## Power, energy and thermals (no root)

| Source | Root? | Status | Use in Zoomies |
|---|---|---|---|
| `powermetrics` | yes [V] | public tool; values are estimates per its man page | not used |
| IOReport "Energy Model" | no | private framework [C] ([macmon](https://github.com/vladkens/macmon)) | not used (could break with any update) |
| `AppleSmartBattery` IORegistry keys (`InstantAmperage`, `Voltage`, `SystemPowerIn`, ...) | no | undocumented keys [V: present] | candidate for whole-system energy on battery, **to validate** |
| `ri_energy_nj` from `proc_pid_rusage` v6 | no | public SDK [V]; likely CPU-only [H] | recorded, never used for decisions |
| `ProcessInfo.thermalState` | no | public; 4 levels only [V] | preflight and abort guard |

Energy-efficiency claims stay disabled until a method has been validated against a reference meter.

## Prior art

| Project | Approach |
|---|---|
| [llama-autotune](https://github.com/Najafu/llama-autotune) | See [docs/AUDIT-llama-autotune.md](docs/AUDIT-llama-autotune.md) |
| [llama-optimus](https://github.com/BrunoArsioli/llama-optimus) | Optuna over b/ub/t/ngl, then a grid over fa/-ot [C] |
| [llama-dyno (PyPI)](https://pypi.org/project/llama-dyno/) | Coarse ngl × FA × KV sweep, then hill-climbing; throughput only [C] |
| [llama-parameter-scout](https://github.com/LStoneyy/llama-parameter-scout) | llama-bench combinations with a TUI [C] |
| In-tree [`tools/tuning`](https://github.com/ggml-org/llama.cpp/blob/master/tools/tuning/README.md) | Kernel-level Metal tuner. **Its drift guard is worth copying:** re-measure a fixed baseline periodically and discard results on > 10% drift. |
| `llama-fit-params` / `-fit` | Fits ngl, ctx and `-ot` to free memory |

## Measured on the dev Mac (2026-11-14)

MacBook Pro Mac17,2 (M5, 4 Super + 6 Efficiency cores, 10-core GPU, 16 GB), macOS 26.5.2, plugged in. Homebrew `llama.cpp` 1.0.0 (build 12359, commit b1b770d90). Model: Qwen2.5-1.5B-Instruct Q4_K_M (1.04 GiB, SHA-256 `6a1a2eb6…407e`). Memory pressure varied between normal and warning, with 14–15 GiB of swap in use from other apps, so these are **not** idle-machine numbers. Commands and full results are in [BENCHMARKS.md](BENCHMARKS.md#results).

- **Process footprint excludes memory-mapped weights** [M]. With the default load mode the llama-bench footprint peaked at 141–147 MiB for a 1.04 GiB model on the GPU. With `lm=none` (weights copied into anonymous memory) it was 1.36–1.37 GiB.
- **Resident size counts the mapped weights, but misses some GPU-side memory** [M]. Peak RSS was 1.10–1.20 GiB with the default and 1.16 GiB with `lm=none`, where the footprint shows about 200 MiB more. Neither number alone is "total memory". Zoomies records and labels both. Still to do: check both against `footprint`/`vmmap` with a multi-GB model.
- **Homebrew 1.0.0 uses dynamically loaded ggml backends** [M]: `libggml-metal`, `libggml-blas` (listed as a device, "BLAS: Accelerate") and `libggml-cpu-apple_m4.so`. There is no M5-specific CPU variant, so the M4 one loads on the M5. Zoomies records the variant as `cpu_backend_variant`.
- **The M5 tensor API is on in the Homebrew bottle** [M]: `has tensor = true`, GPU families Apple10 and Metal4. Zoomies records this per run as `metal.has_tensor`.
- **One-time Metal compile after install** [M]. The first llama.cpp process compiled 36 Metal libraries in about 5 s. Later processes load them in about 13 ms. llama-bench excludes this from tokens/s, but it inflates the first process's wall time after an install or upgrade.
- **"auto" settings are not resolved in the output** [M]. The JSONL reports `flash_attn: -1` and `load_mode: "auto"`, not what auto chose. Whether the baseline ran with FA on needs verbose logs (open question 8).
- **Noise floor** [M]: 10 rounds × 5 repetitions of the defaults (pp512, tg128). pp 3074.5 t/s, 95% CI ±6.4%; tg 99.1 t/s, CI ±3.4%. Round 7 was disturbed (one pp repetition at 945 t/s, round mean −27%). Without that round the CIs would be ±1.9% (pp) and ±2.2% (tg). The official result keeps it. Since this run, Zoomies flags disturbed rounds automatically.
- **Tuning results, 1.5B model, prompt-heavy workload (pp2048)** [M] (BENCHMARKS.md §3):
  - **Flash attention:** `fa=auto` already picks the fast path. Forcing it off costs about 8% of prompt speed (and about 7% of generation speed in a pp512/tg128 run).
  - **Micro-batch:** larger is *slower* on this setup. `ub=2048` was 8.5% slower than the default 512, and `ub=1024` 3.6% slower.
  - **Threads and polling:** with full GPU offload they barely matter, and every non-default value was slightly slower.
  - Net result: the defaults were verified as best (the top candidate was +0.3% [−1.7%, +2.3%]).
- **14B: a smaller micro-batch is faster for prompts** [M]. On Qwen3-14B Q4_K_M with a 2,048-token prompt, `-ub 256` gave **+11.5% prompt speed [+6.2%, +17.0%]** over the default 512 (verified on fresh paired rounds), with no change in generation speed. Larger values were much worse: 1024 −15%, 2048 −23%. The cause is unknown (hypotheses [H]: Metal kernel tiling or the tensor-API path favouring smaller tiles, L2/SLC working-set size, or compute-buffer pressure on a 16 GB machine). Open question 9.
- **Quiet machine, low noise** [M]. With browsers and chat apps closed, the default prompt speed varied by about 0.3% across six verification rounds. Background apps, not the hardware, set most of the noise floor measured earlier.
- **Loading a 14B model spikes memory pressure** [M]. Mapping Qwen3-14B Q4_K_M (8.4 GiB) on the 16 GB Mac made macOS report *critical* pressure for a moment while it evicted file cache; a minute later it was normal, with 8+ GiB free. The guard now requires critical pressure to last 5 s before stopping. Sustained pressure and real swapping (more than 1 GiB) still stop a run.
- **Consequence:** under these conditions, 10 rounds can detect differences of roughly 3–6%. The 2% relevance threshold only binds on a quieter machine. Re-measure with other apps closed.

## Open questions (next experiments)

1. ~~Does `phys_footprint` include Metal buffers?~~ Partly answered [M]: it excludes mmapped weights. Still to do: validate footprint and RSS against `footprint`/`vmmap` with a 4+ GB model.
2. ~~What is the noise floor?~~ Measured under memory pressure [M] (above). Repeat on an idle machine.
3. ~~Does `-t` or `--poll` matter with full offload?~~ Not for speed on the 1.5B model [M]: every non-default value was 1–4% slower. CPU power is still unmeasured.
4. What does the `-ub` sweep (128 to 2,048) do to pp on Metal at depth 0 and at depth 8,192?
5. What is the `-fa on` vs `off` crossover depth on the M5?
6. How much pp and tg do q8_0 and q4_0 KV caches cost against the memory they save?
7. Does the 180 s residency keep-alive bias the first run of a round?
9. Why is `-ub 256` faster than 512 for prompts on the M5 with a 14B model, and does it hold for other sizes, quantizations, and on M1–M4? (A sweep of 128/256/384/512 across models would answer it.)
8. What does `-fa auto` resolve to on Metal for this model? Run `llama-bench -v` and read the context log.
