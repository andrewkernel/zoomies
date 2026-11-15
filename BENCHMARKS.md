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

### Tuning (`zoomies tune`)

The tuner reuses the method above, in three stages:

1. **Screen.** For each setting in the search space, one llama-bench process runs all its values (comma list, model loaded once, `-r` = budget repetitions). Each value's score is compared with the default value's score *from the same process*, which cancels load-to-load variation. A value survives if it is at least 1.5% better (memory goal: if it plausibly shrinks buffers and keeps speed within the guardrail). Screening only ranks; it never decides.
2. **Narrow.** The best value per setting alone, all best values combined, and the top two combined, up to the budget's candidate cap, run against the defaults as separate processes in seeded, shuffled order (successive halving: 2 rounds on quick; 2 + 3 on standard; 3 + 4 on thorough). Each stage keeps the better half, and only candidates whose point estimate beats the defaults.
3. **Verify.** The survivor and the defaults run on fresh rounds (4 / 6 / 10). Per round, Zoomies takes the ratio winner/defaults, then a t-interval on the log-ratios (paired comparison). The verdict is "improved" only if the 95% CI is entirely above 0, the gain is at least 2% (5% for memory), and the secondary metric is not significantly worse than the guardrail (5% by default). Otherwise the defaults are kept, and that result is saved too.

Objective scores: generation = tg; response = pp at a 2,048-token prompt; balanced = √(pp ratio × tg ratio); memory = baseline footprint / candidate footprint, with tg within the guardrail.

### Known limitations

- **TTFT is derived, not measured** (prompt / pp + 1 / tg). Real TTFT needs `llama-server` (Phase 2/6).
- **Memory** is reported two ways, because neither is complete [M]. Peak footprint (`ri_lifetime_max_phys_footprint`) excludes memory-mapped weights. Peak RSS includes them, but misses some GPU-side buffers. Neither has been checked against `footprint`/`vmmap` yet.
- The tuner's screen compares values at a single moment in one process; a disturbance during that process can mis-rank a value. Narrowing and verification are what protect the decision.
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

### 3. First real tune: 1.5B, fastest first token, standard budget (2026-11-14)

Conditions this time: plugged in, Low Power Mode off, browser and chat apps closed, memory pressure normal (~5.5 GiB free, 2.7 GiB swap).

```bash
zoomies tune qwen2.5 --goal response --budget standard --seed 11      # pp2048 + tg32
```

**Screen** (each value compared with the default in the same process):

| Setting | Values (vs default) |
|---|---|
| Flash attention (default `auto`) | `on` +1.7% · `off` **−8.0%** |
| Micro-batch (default 512) | 256 +2.2% · 1024 −3.6% · 2048 **−8.5%** |
| Threads (default 4) | 2 −3.7% · 6 −2.1% · 10 −4.3% |
| Polling (default 50) | 0 −0.9% · 100 −3.9% |

**Narrow** (2 rounds): `ub=256 fa=on` +1.1%, `fa=on` −0.2%, `ub=256` −3.3%. That last figure includes a disturbed first-round process at 2768 t/s.

**Verify** (6 fresh rounds, paired): `ub=256 fa=on` vs defaults, prompt speed **+0.3% [−1.7%, +2.3%]**, generation −2.2% [−8.1%, +4.1%]. Round 6 was disturbed (pp 2906, tg 92.5 against ~3040 / ~107).

**Decision: keep the defaults.** The best candidate's gain is below the 2% relevance threshold and inside the noise. Default prompt speed was 3002–3011 t/s across the six verification rounds, a spread of about 0.3%: far quieter than the noise floor measured earlier with a browser open.

What this says about llama.cpp b12359 on the M5 with a small model:
- `fa=auto` already picks the fast path. Forcing FA off costs about 8% of prompt speed, and about 7% of generation speed in the earlier functional run.
- Larger micro-batches are slower here, not faster: 2048 is 8.5% slower than the default 512 at a 2,048-token prompt.
- The CPU thread count barely matters with full GPU offload, and changing it from the default only made things slightly worse.

24 processes, 2 min 42 s. Tune id `6AED4DD3-3032-4A42-B85C-9768BE5BAE4A`.

### 4. 14B model, fastest replies, quick budget (2026-11-14)

Model: [Qwen3-14B-GGUF](https://huggingface.co/Qwen/Qwen3-14B-GGUF) `Qwen3-14B-Q4_K_M.gguf`, 8.38 GiB, SHA-256 `500a8806…6b81f0`.

```bash
zoomies tune qwen3-14b --goal generation --budget quick --seed 21    # pp512 + tg128
```

Two earlier attempts were stopped by the safety guards, correctly:
1. **Critical memory pressure during model load.** This led to the 5-second grace period described in RESEARCH.md.
2. **Swap grew 1 GiB in 11 s.** macOS paged other apps out to make room. After stopping the Colima Docker VM (2 GiB) and the browser pane, the run completed.

| Setting | pp512 (t/s) | tg128 (t/s) | Screen score (tg vs default) |
|---|---|---|---|
| fa `auto` (default) | 316.8 | 13.66 | — |
| fa `on` | 309.7 | 13.80 | +1.1% |
| fa `off` | 307.2 | 13.64 | −0.1% |
| ub 512 (default) | 314.0 | 14.02 | — |
| ub 256 | 365.7 | 14.12 | +0.7% |

**Decision: keep the defaults** for generation. No setting cleared the 1.5% screening bar, so the tune stopped after 2 processes (2 min). Generation runs at about 13.7–14.1 t/s, about 80% of the ~17 t/s ceiling that 153 GB/s of memory bandwidth allows for a 9.0 GB model (a derived bound, not a measurement).

`ub=256` showed **+16% prompt speed** inside its screening process. That is not a decision, since screening only ranks, but it prompted the next tune.

### 4b. 14B model, fastest first token, quick budget: verified improvement (2026-11-14)

```bash
zoomies tune qwen3-14b --goal response --budget quick --seed 31      # pp2048 + tg32
```

**Screen:**

| Setting | Values (prompt speed vs default, same process) |
|---|---|
| Flash attention (default `auto`) | `on` −1.9% · `off` **−9.8%** |
| Micro-batch (default 512) | **256 +6.2%** · 1024 **−15.2%** · 2048 **−22.6%** |

**Verify** (4 fresh rounds, defaults and `ub=256` interleaved, paired):

| Round | defaults pp / tg | `ub=256` pp / tg |
|---|---|---|
| 1 | 303.0 / 11.9 | 323.0 / 12.6 |
| 2 | 310.4 / 14.1 | 353.1 / 14.1 |
| 3 | 315.3 / 14.2 | 353.9 / 14.2 |
| 4 | 310.0 / 14.2 | 352.0 / 14.0 |

- **Prompt speed: +11.5%, 95% CI [+6.2%, +17.0%] → improved.**
- **Generation speed:** +1.1% [−3.4%, +5.9%], no detectable difference (inside the 5% guardrail).
- **Round 1 was disturbed:** both configs were slow, probably still settling after the first load of the 8.4 GiB model. Zoomies flagged it and kept it, which widens the interval. The report also warned that baseline generation speed drifted +18.9% from round 1 to round 4, for the same reason.

**Decision: `-ub 256`** for prompt-heavy work with this model on this Mac. For a 2,048-token prompt that is about 5.8 s instead of 6.6 s of prompt processing. Saved as a profile; `zoomies export qwen3-14b` prints:

```
llama-server -m Qwen3-14B-Q4_K_M.gguf -t 4 -ngl all -ub 256
```

On this machine, smaller micro-batches beat larger ones, which contradicts the usual "bigger batch, faster prompt" advice. The 1.5B model showed the same direction, but there the difference was within noise. Why (kernel tiling, cache size, the M5 tensor API) is open; see RESEARCH.md.

10 processes, 6 min 40 s. Tune id `A362BF3A-F5C0-40AD-A2DB-2992015F1F45`.

### 5. Context cost, 1.5B (2026-11-14)

```bash
zoomies cost qwen2.5        # pp1024 and tg64 at 0 / 4k / 16k tokens of context, one process, 2 repetitions
```

| Context | Seconds per 1k prompt tokens | Reply speed |
|---|---|---|
| empty | 0.31 s | 110.3 t/s |
| 4k | 0.44 s | 92.3 t/s |
| 16k | 0.86 s | 71.2 t/s |

One process, so there is no confidence interval. At 16k tokens of context, replies are about 35% slower and reading is about 2.8× slower per token than on an empty context. That is why `--context` matters when tuning, and why context-reduction ideas (read gating) pay off more in long sessions.

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
