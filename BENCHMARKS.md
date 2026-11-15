# Benchmarks

## Methodology (as implemented in `zoomies bench`)

1. **Preflight.** The run is blocked if:
   - the Mac is on battery (unless `--allow-battery`), or the battery is below 30%;
   - the thermal state is above `fair`;
   - memory pressure is critical;
   - the model plus the KV estimate is more than 85% of RAM;
   - any config is invalid for the installed build.

   Zoomies warns, without blocking, for Low Power Mode, elevated memory pressure, a model above the estimated available memory or the Metal working set, and partial GPU offload.
2. **Baseline.** Config 0 is always llama.cpp's own defaults: no tuning flags at all.
3. **Rounds.** Each config runs as a separate `llama-bench` process once per round, 3 rounds by default. The config order is reshuffled every round with a recorded seed (SplitMix64), so slow drift such as heat can't consistently favour one config. There is a 2 s cooldown between processes.
4. **Within a process.**
   - llama-bench's built-in warmup runs first; Zoomies does not pass `--no-warmup`.
   - Then `-r` repetitions (3 by default) of `pp<P>` and `tg<N>`, optionally at depth `-d`.
   - Model load time is excluded by llama-bench and recorded separately as process wall time.
5. **Guards during runs.** A run is stopped if:
   - the thermal state reaches `serious`;
   - memory pressure turns critical;
   - system-wide swap grows by more than 1 GiB since the run started;
   - the Mac switches to battery;
   - the per-run timeout of 900 s passes, or the total budget runs out.

   Finished results are kept, and the report is marked `partial`.
6. **Statistics.**
   - Per config and test kind, Zoomies computes the mean of the per-round means and a 95% Student-t CI (n = rounds).
   - Every config is compared with the baseline using Welch's t, with a 95% CI on the difference. The verdict is `faster` or `slower` only if the CI excludes 0 *and* the difference is at least 2%.
   - Outliers among all repetitions (modified z > 3.5) are counted and reported, never removed.
   - Disturbed rounds (a round mean that is a MAD outlier among the round means) are flagged in the report and kept in the CI.
7. **Drift.** Zoomies warns when the baseline's mean moves more than 5% between its first and last round, when the thermal state rises above nominal, or when the power source changes.
8. **Stored per run.** Timestamp; hardware JSON and fingerprint; OS version; model path, quick fingerprint and quantization; runtime build and commit; the full plan, including the seed; every command line; every repetition's tokens/s; peak footprint; system state before and after each process; the notable stderr lines (backend, tensor API status, errors); summaries; and failures.

### Known limitations

- **TTFT is derived, not measured** (prompt / pp + 1 / tg). Real TTFT needs `llama-server` (Phase 2/6).
- **Memory** is reported two ways, because neither is complete [M]. Peak footprint (`ri_lifetime_max_phys_footprint`) excludes memory-mapped weights. Peak RSS includes them, but misses some GPU-side buffers. Neither has been checked against `footprint`/`vmmap` yet.
- With 3 rounds the t multiplier is 4.30, so CIs are wide. Use `--rounds 5` or more before acting on small differences.
- No energy numbers are reported (see [RESEARCH.md](RESEARCH.md#power-energy-and-thermals-no-root)).

## Results

All results below come from one machine, under the conditions stated. They describe **this Mac and this model**, not llama.cpp on Apple Silicon in general.

| | |
|---|---|
| Machine | MacBook Pro Mac17,2, Apple M5 (4 Super + 6 Efficiency CPU cores, 10-core GPU), 16 GB, macOS 26.5.2 (25F84) |
| Runtime | Homebrew `llama.cpp` 1.0.0, build 12359, commit b1b770d90. Metal tensor API on, CPU backend variant `apple_m4` |
| Model | [Qwen2.5-1.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF) `qwen2.5-1.5b-instruct-q4_k_m.gguf`, 1.04 GiB, SHA-256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` |
| Conditions | Plugged in (100%), thermal nominal, lid open. **Not idle:** Chrome and other apps open, memory pressure between normal and warning, 14–16 GiB swap in use |
| Zoomies | 0.1.0-dev (pre-commit working tree) |

### 1. Noise floor: llama.cpp defaults, 10 rounds × 5 repetitions (2026-11-14)

```bash
zoomies bench ~/Models/gguf/qwen2.5-1.5b-instruct-q4_k_m.gguf --rounds 10 --reps 5 --seed 1
```

| Test | Mean (t/s) | 95% CI (n = 10 rounds) | CI half-width | Round-to-round CV |
|---|---|---|---|---|
| pp512 | 3074.5 | 2878.1 – 3271.0 | ±6.4% | 8.9% |
| tg128 | 99.1 | 95.8 – 102.5 | ±3.4% | 4.7% |

- **Round 7 was disturbed.** Its first pp repetition ran at 945 t/s, and its pp round mean was 2321.8 (−27%). It is kept in the result. Without it the half-widths would be ±1.9% (pp) and ±2.2% (tg); this is shown only to size the effect of one disturbance. Zoomies now flags such rounds automatically.
- Rounds 8–10 were 3–5% slower than rounds 1–6 on pp, as memory pressure rose to warning by round 10.
- **Memory:** peak RSS 1.10–1.20 GiB; peak footprint 141–146 MiB (it excludes the memory-mapped weights; see [RESEARCH.md](RESEARCH.md#measured-on-the-dev-mac-2026-11-14)).
- **Wall time:** 7.7–9.6 s per process, 1 min 41 s for the whole run.
- **Derived TTFT estimate:** 177 ms for a 512-token prompt (pp and tg only; not a measured TTFT).

**What this means for tuning:** on this machine in this state, 10 rounds can resolve differences of roughly 3–6%. Smaller claimed gains would be noise. Re-measure with other apps closed before tuning.

### 2. Settings sweep, 5 rounds: stopped by the safety guard (2026-11-14)

```bash
zoomies bench ~/Models/gguf/qwen2.5-1.5b-instruct-q4_k_m.gguf --rounds 5 --seed 2 \
  --config "fa=off" --config "ub=1024" --config "ub=2048" --config "t=1" --config "poll=0"
```

**Stopped after 6 of 30 processes**: system swap grew by 1.01 GiB from the start of the run (15.5 → 16.6 GB). Only round 1 finished, and in it the baseline was the process that got stopped. So there are **no comparisons and no conclusions** from this run. The guard did its job; the run must be repeated on a machine with memory to spare.

### Earlier exploratory runs (2 rounds; too few for conclusions)

- Defaults vs `fa=off`, 2 rounds × 2 repetitions: pp −8.7% [−18.3%, +0.8%], tg −2.5% [−74.1%, +69.1%]. Both are **no detectable difference**: the CIs include zero. It is a hint worth re-testing at ≥ 5 rounds, nothing more.
- Load modes, 2 rounds × 2 repetitions: `lm=none` peak footprint 1.36–1.37 GiB against 142–147 MiB for the default and `lm=mmap`. This is a memory-accounting finding; their throughput was not compared.

### Next measurements

Run these with the Mac plugged in and other apps closed (especially browsers):

```bash
zoomies probe                                                     # memory pressure should read "normal"
zoomies bench MODEL.gguf --rounds 10 --reps 5 --seed 11           # noise floor, idle machine
zoomies bench MODEL.gguf --rounds 5 --seed 2 \
  --config "fa=off" --config "ub=1024" --config "ub=2048" --config "t=1" --config "poll=0"
zoomies bench MODEL.gguf --rounds 5 --seed 3 -d 8192 --config "fa=off" --config "ctk=q8_0,ctv=q8_0"
```

With `-p 512`, `ub=1024` and `ub=2048` should behave like the defaults (ubatch only matters when the prompt is longer than it), so they act as null controls: if either comes out "faster" or "slower", the method is reporting noise as an effect.
