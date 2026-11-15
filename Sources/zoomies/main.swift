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

let usage = """
zoomies \(zoomiesVersion) — measured speedups for local LLMs

USAGE
  zoomies probe [--json]                 Hardware and current system state
  zoomies inspect MODEL [--json] [--full-hash]
                                         Read a GGUF model's header (no weights loaded)
  zoomies runtime [--llama-bench PATH]   Find llama-bench and list what it supports
  zoomies bench MODEL [options]          Benchmark configs against llama.cpp's defaults
  zoomies history [--limit N]            Recent runs from the results database
  zoomies show RUN_ID [--json]           One stored run

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

case "-h", "--help", "help":
    print(usage)

default:
    die("unknown command '\(command)'\n\n\(usage)")
}
