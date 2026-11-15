import Foundation
import ZoomiesKit

// zoomies — CLI front end over ZoomiesKit.
//
//   zoomies probe [--json]
//   zoomies inspect <model.gguf> [--json] [--full-hash]
//   zoomies runtime [--llama-bench PATH] [--json]
//   zoomies bench <model.gguf> [--config "ngl=99,fa=on"]... [options]
//   zoomies history [--limit N]
//   zoomies show <run-id> [--json]
//   zoomies tune <model> [--goal G] [--budget B] ...
//   zoomies profiles / apply / rollback / export / serve / models / cost

let usage = """
zoomies \(zoomiesVersion) — measured speedups for local LLMs

USAGE
  zoomies tune MODEL [options]           Find faster settings and prove them against the defaults
  zoomies models                         Models found on this Mac (incl. Ollama, LM Studio)
  zoomies profiles [MODEL]               Saved profiles; * marks the active one
  zoomies apply PROFILE_ID | --defaults MODEL
                                         Make a profile (or llama.cpp's defaults) active
  zoomies rollback MODEL                 Return to the previously active profile
  zoomies export MODEL [-c N]            Print the llama-server command for the active profile
  zoomies serve MODEL [-c N] [-- ARGS]   Start llama-server with the active profile
  zoomies cost MODEL                     Seconds per 1k prompt tokens as the context grows
  zoomies probe [--json]                 Hardware and current system state
  zoomies inspect MODEL [--json] [--full-hash]
                                         Read a GGUF model's header (no weights loaded)
  zoomies runtime [--llama-bench PATH]   Find llama-bench and list what it supports
  zoomies bench MODEL [options]          Benchmark configs against llama.cpp's defaults
  zoomies history [--limit N]            Recent runs from the results database
  zoomies show RUN_ID [--json]           One stored run

MODEL can be a path or a name from `zoomies models` (e.g. qwen3-14b, llama3.2:3b).

TUNE OPTIONS
  --goal G          generation (default) | response | balanced | memory
  --budget B        quick | standard (default) | thorough
  --context N       Tokens already in the conversation while measuring (default 0)
  --prompt N        Prompt size for response/balanced goals (default 2048/1024)
  --allow-kv-quant  Also try quantized KV caches (saves memory; output changes slightly)
  --max-minutes M   Stop after M minutes
  --apply           Make the result the active profile
  --dry-run         Show the search space and commands; run nothing
  --allow-battery, --llama-bench P, --db PATH, --seed N, --json

BENCH OPTIONS
  --config SPEC     Add a config to compare, e.g. "ngl=99,fa=off,ub=1024" (repeatable).
                    llama.cpp's defaults are always run first, as the baseline.
                    Keys: ngl t b ub fa(on|off|auto) ctk ctv lm(load mode) poll
  -p N              Prompt tokens for the prompt-processing test   (default 512)
  -n N              Tokens for the generation test                 (default 128)
  -d N              Tokens already in the KV cache (depth)         (default 0)
  --rounds N        Separate processes per config; CI is across rounds (default 3)
  --reps N          llama-bench repetitions per process            (default 3)
  --seed N          Run-order seed (default: random, recorded)
  --cooldown S      Seconds between runs                           (default 2)
  --budget S        Stop after S seconds total
  --allow-battery   Permit running on battery (results will differ from AC)
  --llama-bench P   Path to llama-bench
  --db PATH         Results database (default ~/Library/Application Support/Zoomies/results.sqlite)
  --dry-run         Show checks and exact commands; run nothing
  --json            Print the full report as JSON
"""

var args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

func option(_ names: String...) -> String? {
    for name in names {
        if let i = args.firstIndex(of: name), i + 1 < args.count {
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
    }
    return nil
}

func options(_ name: String) -> [String] {
    var out: [String] = []
    while let v = option(name) { out.append(v) }
    return out
}

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(code)
}

func printJSON<T: Encodable>(_ v: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    print(String(decoding: (try? enc.encode(v)) ?? Data(), as: UTF8.self))
}

func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }


func store(_ path: String?) -> ResultStore {
    do { return try ResultStore(url: path.map { URL(fileURLWithPath: $0) } ?? AppPaths.database) } catch { die("\(error)") }
}

/// A path, or a unique name match from the model library.
func resolveModel(_ arg: String) -> URL {
    let fm = FileManager.default
    let expanded = (arg as NSString).expandingTildeInPath
    if fm.fileExists(atPath: expanded) { return URL(fileURLWithPath: expanded) }
    let lib = ModelLibrary.scan()
    if let exact = lib.first(where: { $0.displayName.caseInsensitiveCompare(arg) == .orderedSame }) { return exact.url }
    let hits = lib.filter { $0.displayName.localizedCaseInsensitiveContains(arg) }
    if hits.count == 1 { return hits[0].url }
    if hits.isEmpty { die("no model file or library model matches '\(arg)'. See `zoomies models`.") }
    die("'\(arg)' matches several models:\n" + hits.map { "  \($0.displayName)  (\($0.url.path))" }.joined(separator: "\n"))
}

func inspectOrDie(_ url: URL) -> ModelInfo {
    do { return try ModelInspector.inspect(url) } catch { die("\(error)") }
}

func discoverOrDie(_ path: String?) -> (LlamaBenchAdapter, RuntimeInstallation) {
    let a = LlamaBenchAdapter(explicitPath: path)
    do { return (a, try a.discover()) } catch { die("\(error)") }
}

/// Runs an async job; Ctrl+C cancels it so children stop and partial results are kept.
func runCancellable<T: Sendable>(_ message: String = "Stopping (keeping finished results)...", _ job: @escaping @Sendable () async -> T) async -> T {
    let task = Task { await job() }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { print("\n" + message); task.cancel() }
    sigint.resume()
    let v = await task.value
    sigint.cancel()
    signal(SIGINT, SIG_DFL)
    return v
}

func fmtDuration(_ s: Double) -> String {
    s >= 90 ? String(format: "%.0f min", s / 60) : String(format: "%.0f s", s)
}

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered so progress and results interleave correctly

guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()
let asJSON = flag("--json")
let probe = HardwareProbes.current()

switch command {
case "probe":
    struct Out: Encodable { var hardware: HardwareInfo; var fingerprint: String; var state: SystemState }
    let hw = probe.hardware()
    let st = probe.state()
    if asJSON { printJSON(Out(hardware: hw, fingerprint: hw.fingerprint, state: st)); break }
    print("Machine      \(hw.machineModel ?? "?")  (\(hw.osName) \(hw.osVersion)\(hw.osBuild.map { " \($0)" } ?? ""))")
    print("CPU          \(hw.cpuBrand): \(hw.physicalCores) cores")
    for c in hw.clusters {
        print("               \(c.name): \(c.physicalCores) cores\(c.l2CacheBytes.map { ", L2 \(fmtBytes(UInt64($0)))" } ?? "")")
    }
    print("Memory       \(fmtBytes(hw.memoryBytes)) unified")
    for g in hw.gpus {
        print("GPU          \(g.name): \(g.coreCount.value.map { "\($0) cores" } ?? "core count unavailable")")
        if let ws = g.recommendedMaxWorkingSetBytes { print("               Metal recommended working set: \(fmtBytes(ws))") }
    }
    print("Fingerprint  \(hw.fingerprint)")
    print("")
    if let m = st.memory {
        print("Memory now   ~\(fmtBytes(m.availableEstimateBytes)) available (estimate), pressure \(m.pressure.rawValue), "
              + "compressed \(fmtBytes(m.compressedBytes)), swap \(m.swapUsedBytes.map(fmtBytes) ?? "?")")
    }
    print("Thermal      \(st.thermal.rawValue)")
    let p = st.power
    print("Power        \(p.source.rawValue)\(p.batteryPercent.map { ", battery \($0)%" } ?? "")\(p.lowPowerMode ? ", Low Power Mode ON" : "")")
    if let d = st.diskAvailableBytes { print("Disk free    \(fmtBytes(d))") }

case "inspect":
    guard let path = args.first else { die("inspect needs a model path") }
    let full = flag("--full-hash")
    do {
        let m = try ModelInspector.inspect(URL(fileURLWithPath: path), fullHash: full)
        if asJSON { printJSON(m); break }
        print("Model        \(m.name ?? m.fileName)")
        print("Architecture \(m.architecture ?? "?")\(m.isMoE ? " (MoE: \(m.expertUsedCount ?? 0) of \(m.expertCount ?? 0) experts)" : "")")
        print("Quantization \(m.quantization ?? "?")")
        print("Parameters   \(String(format: "%.2f", Double(m.parameterCount) / 1e9)) B (elements of all tensors in this file)")
        print("Weights      \(fmtBytes(m.weightBytes)) (file \(fmtBytes(m.fileSize)))")
        print("Layers       \(m.blockCount.map(String.init) ?? "?"), heads \(m.headCount.map(String.init) ?? "?")/\(m.headCountKV.map(String.init) ?? "?") (q/kv)")
        print("Context      trained for \(m.trainedContextLength.map(String.init) ?? "?") tokens")
        for ctx in [4096, 8192, 32768] {
            if let kv = m.kvCacheBytesEstimate(contextTokens: ctx) {
                print("KV cache     \(ctx) tokens f16: ~\(fmtBytes(kv)) (estimate, full attention)")
            }
        }
        print("Tensor types \(m.tensorTypeBytes.sorted { $0.value > $1.value }.map { "\($0.key) \(fmtBytes($0.value))" }.joined(separator: ", "))")
        print("Fingerprint  \(m.quickFingerprint)\(m.fullSHA256.map { "\nSHA-256      \($0)" } ?? "")")
    } catch {
        die("\(error)")
    }

case "runtime":
    let adapter = LlamaBenchAdapter(explicitPath: option("--llama-bench"))
    do {
        let inst = try adapter.discover()
        if asJSON { printJSON(inst); break }
        print("Runtime      llama.cpp at \(inst.executable)")
        print("Version      \(inst.version ?? "unknown (build \(inst.buildNumber.map(String.init) ?? "?"), commit \(inst.commit ?? "?"))")")
        if let f = inst.backendFacts {
            print("Backend      " + f.keys.sorted().map { "\($0)=\(f[$0]!)" }.joined(separator: ", "))
        }
        print("Devices      \(inst.devices.isEmpty ? "(none reported: CPU only)" : inst.devices.joined(separator: "; "))")
        print("Options      \(inst.flags.count) flags; load mode: \(inst.flags.contains("-lm") ? "yes" : "no"), flash attention: \(inst.flagUsage["-fa"] ?? "no")")
    } catch {
        die("\(error)")
    }

case "bench":
    let llamaBench = option("--llama-bench")
    let configSpecs = options("--config")
    let p = Int(option("-p") ?? "512") ?? 512
    let n = Int(option("-n") ?? "128") ?? 128
    let d = Int(option("-d") ?? "0") ?? 0
    let rounds = Int(option("--rounds") ?? "3") ?? 3
    let reps = Int(option("--reps") ?? "3") ?? 3
    let seed = option("--seed").flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64.max)
    let cooldown = Double(option("--cooldown") ?? "2") ?? 2
    let budget = option("--budget").flatMap(Double.init)
    let dbPath = option("--db")
    let dryRun = flag("--dry-run")
    var limits = SafetyLimits()
    limits.allowBattery = flag("--allow-battery")
    limits.maxTotalSeconds = budget
    guard let path = args.first else { die("bench needs a model path") }
    let modelURL = URL(fileURLWithPath: path)

    let model: ModelInfo
    do { model = try ModelInspector.inspect(modelURL) } catch { die("\(error)") }
    var configs = [InferenceConfig.runtimeDefaults]
    do { configs += try configSpecs.map(InferenceConfig.parse) } catch { die("\(error)") }
    let plan = BenchmarkPlan(workload: Workload(promptTokens: p, genTokens: n, depth: d), configs: configs,
                             rounds: rounds, repetitions: reps, seed: seed, cooldownSeconds: cooldown, limits: limits)
    let adapter = LlamaBenchAdapter(explicitPath: llamaBench)
    let inst: RuntimeInstallation
    do { inst = try adapter.discover() } catch { die("\(error)") }

    ChildRegistry.shared.reapOrphans()
    let runner = BenchmarkRunner(adapter: adapter, probe: probe)
    let total = plan.schedule().count
    print("Model: \(model.name ?? model.fileName) [\(model.quantization ?? "?")]  runtime: llama.cpp build \(inst.buildNumber.map(String.init) ?? "?")")
    print("Plan:  \(configs.count) configs x \(rounds) rounds x \(reps) reps, pp\(p) + tg\(n)\(d > 0 ? " @ depth \(d)" : ""), seed \(seed)")
    if dryRun {
        print("\nCommands (each runs once per round, order shuffled per round):")
        for c in configs {
            print("  " + adapter.benchmarkCommand(model: modelURL, config: c, workload: plan.workload, repetitions: reps, installation: inst)
                .map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))
        }
    }

    // Ctrl+C: cancel the task so the running child is stopped and partial results are kept.
    let task = Task { () -> BenchmarkReport in
        await runner.run(plan: plan, modelURL: modelURL, model: model, installation: inst, dryRun: dryRun) { ev in
            switch ev {
            case .preflight(let issues):
                for i in issues { print("  \(i)") }
            case .trialStarted(let idx, _, let round, let label):
                print("[\(idx + 1)/\(total)] round \(round + 1)  \(label) ... ", terminator: "")
                fflush(stdout)
            case .trialFinished(let t):
                if case .aborted(let reason) = t.outcome { print("STOPPED (\(reason))"); return }
                if let e = t.error { print("FAILED (\(e.prefix(300)))"); return }
                let parts = t.measurements.map { "\($0.kind.rawValue) \(f1(Stats.mean($0.samplesTPS))) t/s" }
                print(parts.joined(separator: ", ") + (t.peakResidentBytes.map { ", peak RSS \(fmtBytes($0))" } ?? "")
                      + (t.peakFootprintBytes.map { ", footprint \(fmtBytes($0))" } ?? ""))
            case .note(let s):
                print(s)
            }
        }
    }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        print("\nStopping (keeping finished results)...")
        task.cancel()
    }
    sigint.resume()

    let report = await task.value
    if report.status == .dryRun { exit(report.preflight.contains(where: \.blocking) ? 2 : 0) }
    if report.status == .blocked { die("not started: \(report.statusDetail ?? "")", code: 2) }

    if !report.trials.isEmpty {
        do {
            let store = try ResultStore(url: dbPath.map { URL(fileURLWithPath: $0) } ?? AppPaths.database)
            try store.save(report)
        } catch {
            FileHandle.standardError.write(Data("warning: results not saved: \(error)\n".utf8))
        }
    }
    if asJSON { printJSON(report); break }

    print("\nResults (mean of per-round means, 95% CI across \(rounds) rounds; tokens/s)")
    for r in report.results {
        print("  \(r.configIndex == 0 ? "baseline " : "")\(r.label)")
        for k in r.kinds {
            let s = k.summary
            var line = "    \(k.kind.rawValue): \(f1(s.mean))  [\(s.ciLow.isFinite ? f1(s.ciLow) : "-")–\(s.ciHigh.isFinite ? f1(s.ciHigh) : "-")]  cv \(f1(k.sampleSummary.cvPercent))%"
            if let c = k.vsBaseline {
                line += String(format: "   vs baseline %+.1f%% [%+.1f%%, %+.1f%%] → %@", c.relativePercent,
                               c.relativeCILowPercent, c.relativeCIHighPercent, c.verdict.rawValue.replacingOccurrences(of: "_", with: " "))
            }
            if !k.outlierSamples.isEmpty { line += "  (\(k.outlierSamples.count) outlier sample(s) kept)" }
            if let rs = k.outlierRounds, !rs.isEmpty {
                line += "  (disturbed round(s) \(rs.map { String($0 + 1) }.joined(separator: ", ")) kept; consider re-running)"
            }
            print(line)
        }
        if let rss = r.peakResidentBytes { print("    peak resident memory: \(fmtBytes(rss)) (RSS: counts mapped weights, may miss GPU-only buffers)") }
        if let pk = r.peakFootprintBytes { print("    peak footprint: \(fmtBytes(pk)) (Activity Monitor \"Memory\": excludes memory-mapped weights)") }
        if let t = r.derivedTTFTEstimateSeconds { print("    TTFT estimate (derived, excludes load/tokenize/sampling): \(f2(t * 1000)) ms") }
        if r.failedTrials > 0 { print("    \(r.failedTrials) run(s) failed") }
    }
    for w in report.warnings { print("warning: \(w)") }
    print("\nStatus: \(report.status.rawValue)\(report.statusDetail.map { " — \($0)" } ?? "")   run id \(report.id.uuidString)")
    switch report.status {
    case .completed: break
    case .partial, .cancelled: exit(3)
    default: exit(1)
    }

case "history":
    let limit = Int(option("--limit") ?? "20") ?? 20
    do {
        let store = try ResultStore(url: option("--db").map { URL(fileURLWithPath: $0) } ?? AppPaths.database)
        for r in try store.recentRuns(limit: limit) {
            print("\(r.id)  \(ISO8601DateFormatter().string(from: r.startedAt))  \(r.status)  b\(r.runtimeBuild.map(String.init) ?? "?")  \(r.quantization ?? "?")  \((r.modelPath as NSString).lastPathComponent)")
        }
    } catch { die("\(error)") }

case "show":
    guard let id = args.first else { die("show needs a run id") }
    do {
        let store = try ResultStore(url: option("--db").map { URL(fileURLWithPath: $0) } ?? AppPaths.database)
        guard let r = try store.report(id: id) else { die("no run \(id)") }
        printJSON(r)
    } catch { die("\(error)") }

case "tune":
    let llamaBench = option("--llama-bench")
    let goal = option("--goal") ?? "generation"
    let budgetName = option("--budget") ?? "standard"
    let context = Int(option("--context") ?? "0") ?? 0
    let promptTokens = option("--prompt").flatMap(Int.init)
    let maxMinutes = option("--max-minutes").flatMap(Double.init)
    let seed = option("--seed").flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64.max)
    let dbPath = option("--db")
    let allowKV = flag("--allow-kv-quant")
    let applyResult = flag("--apply")
    let tuneDryRun = flag("--dry-run")
    var limits = SafetyLimits()
    limits.allowBattery = flag("--allow-battery")
    guard let objective = TuneObjective(rawValue: goal) else { die("--goal must be generation, response, balanced or memory") }
    guard let budget = TuneBudget(rawValue: budgetName) else { die("--budget must be quick, standard or thorough") }
    guard let arg = args.first else { die("tune needs a model") }
    let modelURL = resolveModel(arg)
    let model = inspectOrDie(modelURL)
    let (adapter, inst) = discoverOrDie(llamaBench)
    let request = TuneRequest(objective: objective, budget: budget,
                              constraints: TuneConstraints(contextTokens: context, promptTokens: promptTokens,
                                                           allowKVQuantization: allowKV, maxSeconds: maxMinutes.map { $0 * 60 },
                                                           limits: limits),
                              seed: seed)
    if tuneDryRun {
        let space = SearchSpace.build(request: request, model: model, hardware: probe.hardware(), installation: inst, adapter: adapter)
        print("Search space for \(objective.title.lowercased()) (\(budget.rawValue)); default value first:")
        for d in space {
            print("  \(d.dimension.title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(d.values.joined(separator: " | "))")
            for n in d.notes { print("      \(n)") }
            if d.values.count >= 2, let cmd = adapter.sweepCommand(model: modelURL, dimension: d.dimension, values: d.values,
                                                                    workload: request.workload, repetitions: budget.repetitions, installation: inst) {
                print("      " + ServerCommand.shellLine(cmd))
            }
        }
        let pre = BenchmarkRunner.preflight(plan: BenchmarkPlan(workload: request.workload, configs: [.runtimeDefaults], rounds: 2, limits: limits),
                                            model: model, hardware: probe.hardware(), state: probe.state())
        for i in pre { print("  \(i)") }
        print("Then: up to \(budget.maxCandidates) candidates narrowed over \(budget.narrowingRounds.map(String.init).joined(separator: "+")) rounds, "
              + "and the winner verified against the defaults on \(budget.validationRounds) fresh rounds.")
        exit(pre.contains(where: \.blocking) ? 2 : 0)
    }
    ChildRegistry.shared.reapOrphans()
    let db = store(dbPath)
    let tuner = Tuner(runner: BenchmarkRunner(adapter: adapter, probe: probe))
    let w = request.workload
    print("Tuning \((model.fileName as NSString).deletingPathExtension) [\(model.quantization ?? "?")] for \(objective.title.lowercased()), \(budget.rawValue) budget")
    print("Workload pp\(w.promptTokens) + tg\(w.genTokens)\(w.depth > 0 ? " at \(w.depth) tokens of context" : ""); llama.cpp build \(inst.buildNumber.map(String.init) ?? "?"); seed \(seed)\n")

    let report = await runCancellable { () -> TuneReport in
        await tuner.tune(request: request, modelURL: modelURL, model: model, installation: inst, onEvent: { ev in
            switch ev {
            case .stageStarted(let k, let detail): print("\n== \(k.title): \(detail)")
            case .screening(let d, let values): print("  \(d.title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(values.joined(separator: " | ")) ... ", terminator: ""); fflush(stdout)
            case .screened(let r):
                let parts = r.values.map { v -> String in
                    let mark = v.isDefault ? " (default)" : (v.kept ? " ✓" : "")
                    return v.isDefault ? "\(v.value)\(mark)" : "\(v.value) \(v.relativeScore.map { String(format: "%+.1f%%", $0 * 100) } ?? "n/a")\(mark)"
                }
                print(parts.joined(separator: ", ") + (r.note.map { "  [\($0)]" } ?? ""))
            case .candidates(let cs): if !cs.isEmpty { print("\nCandidates: " + cs.map(\.label).joined(separator: " · ")) }
            case .bench(.trialStarted(let i, let total, let round, let label)) where total > 0:
                print("  [\(i + 1)/\(total)] round \(round + 1)  \(label) ... ", terminator: ""); fflush(stdout)
            case .bench(.trialFinished(let t)) where t.configIndex < 0 && t.error != nil:
                if case .aborted(let r) = t.outcome { print("STOPPED (\(r))") } else { print("FAILED (\(t.error!.prefix(120)))") }
            case .bench(.trialFinished(let t)) where t.configIndex >= 0:
                if let e = t.error { print("FAILED (\(e.prefix(160)))"); break }
                print(t.measurements.map { "\($0.kind.rawValue) \(f1(Stats.mean($0.samplesTPS)))" }.joined(separator: ", "))
            case .stageFinished(let st) where st.kind == .narrow:
                for c in st.candidates {
                    print("    \(c.kept ? "keep" : "drop")  \(c.label)  \(c.relativeScore.map { String(format: "%+.1f%%", $0 * 100) } ?? "n/a") vs defaults")
                }
            case .estimate(let s): print("  (about \(fmtDuration(s)) left)")
            case .note(let n): print("  \(n)")
            default: break
            }
        }, onBenchmarkReport: { rep in
            if !rep.trials.isEmpty { try? ResultStore(url: dbPath.map { URL(fileURLWithPath: $0) } ?? AppPaths.database).save(rep) }
        })
    }
    do { try db.save(report) } catch { FileHandle.standardError.write(Data("warning: tune not saved: \(error)\n".utf8)) }
    var profile: TuningProfile?
    if report.decision.kind != .incomplete {
        let p = TuningProfile.from(report, modelURL: modelURL)
        try? db.save(p)
        profile = p
        if applyResult { try? db.activate(report.decision.kind == .improved ? p.id : nil, modelFingerprint: p.modelFingerprint, hardwareFingerprint: p.hardwareFingerprint) }
    }
    if asJSON { printJSON(report); break }

    let d = report.decision
    print("\n" + String(repeating: "─", count: 60))
    print(d.headline)
    for line in d.details { print("  · \(line)") }
    for wline in report.warnings { print("  note: \(wline)") }
    print("  \(report.processCount) measurement processes in \(fmtDuration(report.finishedAt.timeIntervalSince(report.startedAt))); tune id \(report.id.uuidString)")
    if d.kind == .improved {
        let cmd = ServerCommand.arguments(config: d.config, modelPath: modelURL.path, installation: inst, adapter: adapter,
                                          contextTokens: context > 0 ? context + 4096 : nil)
        print("\nRun it:\n  \(ServerCommand.shellLine(cmd))")
        if let p = profile {
            print(applyResult ? "\nApplied as the active profile (\(p.id.uuidString.prefix(8))). Undo: zoomies rollback \(arg)"
                              : "\nSaved as profile \(p.id.uuidString.prefix(8)). Make it active: zoomies apply \(p.id.uuidString.prefix(8))")
        }
    }
    exit(d.kind == .incomplete ? 3 : 0)

case "models":
    let lib = ModelLibrary.scan()
    if asJSON { printJSON(lib); break }
    if lib.isEmpty { print("No GGUF models found in ~/Models, LM Studio, Ollama, llama.cpp or Hugging Face caches."); break }
    for m in lib {
        print("\(m.displayName.padding(toLength: 40, withPad: " ", startingAt: 0)) \(fmtBytes(m.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(m.source.padding(toLength: 18, withPad: " ", startingAt: 0)) \(m.url.path)")
    }

case "profiles":
    let db = store(option("--db"))
    let hw = probe.hardware()
    var modelFP: String?
    if let a = args.first { modelFP = inspectOrDie(resolveModel(a)).quickFingerprint }
    do {
        let list = try db.profiles(modelFingerprint: modelFP, hardwareFingerprint: hw.fingerprint)
        if asJSON { printJSON(list); break }
        if list.isEmpty { print("No profiles yet. Run `zoomies tune MODEL`."); break }
        let currentInstall = try? LlamaBenchAdapter(explicitPath: option("--llama-bench")).discover()
        var active: [String: UUID?] = [:]
        for p in list where active[p.modelFingerprint] == nil {
            active[p.modelFingerprint] = try db.activeProfile(modelFingerprint: p.modelFingerprint, hardwareFingerprint: hw.fingerprint)?.id
        }
        for p in list {
            let mark = (active[p.modelFingerprint] ?? nil) == p.id ? "*" : " "
            let stale = p.isStale(for: currentInstall) ? "  (tuned on build \(p.runtimeBuild.map(String.init) ?? "?"); re-tune)" : ""
            print("\(mark) \(p.id.uuidString.prefix(8))  \(p.modelName.padding(toLength: 28, withPad: " ", startingAt: 0))  \(p.config.label.padding(toLength: 24, withPad: " ", startingAt: 0))  \(p.headline)\(stale)")
        }
    } catch { die("\(error)") }

case "apply":
    let db = store(option("--db"))
    let hw = probe.hardware()
    do {
        if flag("--defaults") {
            guard let a = args.first else { die("apply --defaults needs a model") }
            let m = inspectOrDie(resolveModel(a))
            try db.activate(nil, modelFingerprint: m.quickFingerprint, hardwareFingerprint: hw.fingerprint)
            print("llama.cpp's defaults are now active for \(m.name ?? m.fileName).")
            break
        }
        guard let idPrefix = args.first?.uppercased() else { die("apply needs a profile id (see `zoomies profiles`)") }
        let matches = try db.profiles(hardwareFingerprint: hw.fingerprint).filter { $0.id.uuidString.hasPrefix(idPrefix) }
        guard matches.count == 1, let p = matches.first else { die(matches.isEmpty ? "no profile \(idPrefix) for this Mac" : "ambiguous id \(idPrefix)") }
        try db.activate(p.config == .runtimeDefaults ? nil : p.id, modelFingerprint: p.modelFingerprint, hardwareFingerprint: p.hardwareFingerprint)
        print("Active for \(p.modelName): \(p.config.label)  (\(p.headline))")
    } catch { die("\(error)") }

case "rollback":
    let db = store(option("--db"))
    guard let a = args.first else { die("rollback needs a model") }
    let m = inspectOrDie(resolveModel(a))
    do {
        let now = try db.rollback(modelFingerprint: m.quickFingerprint, hardwareFingerprint: probe.hardware().fingerprint)
        print("Active for \(m.name ?? m.fileName): \(now.map { "\($0.config.label)  (\($0.headline))" } ?? "llama.cpp defaults")")
    } catch { die("\(error)") }

case "export", "serve":
    let db = store(option("--db"))
    let ctx = option("-c", "--ctx-size").flatMap(Int.init)
    let profileID = option("--profile")?.uppercased()
    var passthrough: [String] = []
    if let dd = args.firstIndex(of: "--") { passthrough = Array(args[(dd + 1)...]); args.removeSubrange(dd...) }
    guard let a = args.first else { die("\(command) needs a model") }
    let url = resolveModel(a)
    let m = inspectOrDie(url)
    let (adapter, inst) = discoverOrDie(option("--llama-bench"))
    let hw = probe.hardware()
    var profile: TuningProfile?
    do {
        if let pid = profileID {
            profile = try db.profiles(modelFingerprint: m.quickFingerprint, hardwareFingerprint: hw.fingerprint).first { $0.id.uuidString.hasPrefix(pid) }
            if profile == nil { die("no profile \(pid) for this model on this Mac") }
        } else {
            profile = try db.activeProfile(modelFingerprint: m.quickFingerprint, hardwareFingerprint: hw.fingerprint)
        }
    } catch { die("\(error)") }
    let config = profile?.config ?? .runtimeDefaults
    if let p = profile, p.isStale(for: inst) {
        FileHandle.standardError.write(Data("""
            warning: this profile was tuned on llama.cpp build \(p.runtimeBuild.map(String.init) ?? "?"), but build \(inst.buildNumber.map(String.init) ?? "?") is installed.
                     The best settings can change between builds. Re-tune: zoomies tune \(a) --goal \(p.objective?.rawValue ?? "generation")

            """.utf8))
    }
    let argv = ServerCommand.arguments(config: config, modelPath: url.path, installation: inst, adapter: adapter, contextTokens: ctx) + passthrough
    if command == "export" {
        if !asJSON { print("# \(profile.map { "\($0.name): \($0.headline)" } ?? "llama.cpp defaults (no profile active)")") }
        print(ServerCommand.shellLine(argv))
        break
    }
    print("Starting llama-server with \(profile.map { "profile \($0.name)" } ?? "llama.cpp defaults")")
    print(ServerCommand.shellLine(argv))
    // Replace this process, so Ctrl+C and exit codes behave exactly like llama-server.
    // LLAMA_ARG_* variables are removed: they would silently override the profile.
    let env = ChildProcess.sanitizedEnvironment().map { "\($0.key)=\($0.value)" }
    var cArgs = argv.map { strdup($0) } + [nil]
    var cEnv = env.map { strdup($0) } + [nil]
    execve(argv[0].hasPrefix("/") ? argv[0] : "/opt/homebrew/bin/llama-server", &cArgs, &cEnv)
    die("could not start llama-server: \(String(cString: strerror(errno)))")

case "cost":
    guard let a = args.first else { die("cost needs a model") }
    let url = resolveModel(a)
    let m = inspectOrDie(url)
    let (adapter, inst) = discoverOrDie(option("--llama-bench"))
    var limits = SafetyLimits()
    limits.allowBattery = flag("--allow-battery")
    let depths = ContextCost.depths(for: m, memoryBytes: probe.hardware().memoryBytes)
    print("Measuring \(m.name ?? m.fileName) at \(depths.map(String.init).joined(separator: ", ")) tokens of context (one process)...")
    let runner = BenchmarkRunner(adapter: adapter, probe: probe)
    let costLimits = limits
    let rep = await runCancellable { await ContextCost.measure(runner: runner, modelURL: url, model: m, installation: inst, depths: depths, limits: costLimits) }
    if let e = rep.trial.error { die(e) }
    if asJSON { printJSON(rep); break }
    print("\n  context     1k prompt tokens    reply speed")
    for p in rep.points {
        let ctxs = (p.depth == 0 ? "empty" : "\(p.depth / 1024)k").padding(toLength: 10, withPad: " ", startingAt: 0)
        let pp = p.secondsPer1kPromptTokens.map { String(format: "%6.2f s", $0) } ?? "   n/a"
        let tg = p.generationTPS.map { String(format: "%6.1f tokens/s", $0) } ?? "n/a"
        print("  \(ctxs)  \(pp)            \(tg)")
    }
    print("\nA 2,000-token file costs about \(rep.points.first?.secondsPer1kPromptTokens.map { String(format: "%.1f", $0 * 2) } ?? "?") s to read on an empty context. One run, not a confidence interval.")

case "-h", "--help", "help":
    print(usage)

default:
    die("unknown command '\(command)'\n\n\(usage)")
}
