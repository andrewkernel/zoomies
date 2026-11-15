import Foundation

public let zoomiesVersion = "0.2.0"

public struct SafetyLimits: Codable, Sendable, Equatable {
    /// Benchmarks on battery are slower, noisier and drain it; off unless asked.
    public var allowBattery = false
    public var minBatteryPercent = 30
    /// Highest thermal state allowed when a run *starts*.
    public var maxStartThermal: ThermalLevel = .fair
    /// Runs are stopped at this thermal state.
    public var abortThermal: ThermalLevel = .serious
    public var abortMemoryPressure: MemoryPressureLevel = .critical
    /// Memory pressure must stay at `abortMemoryPressure` this long before a run
    /// is stopped. macOS reports brief critical spikes while it evicts file cache
    /// to map a large model; those are harmless. Sustained pressure is not, and
    /// real swapping is caught by `maxSwapGrowthBytes`. nil means 5 s.
    public var memoryPressureGraceSeconds: Double?
    /// Stop a benchmark process if system swap grows by more than this while it
    /// runs: that process is being disturbed by paging (it does not fit).
    public var maxSwapGrowthBytes: UInt64 = 1 << 30
    /// Stop the whole plan or tune if swap grows by more than this from its start.
    /// Separate from the per-process limit because memory macOS pages out once
    /// stays in swap and should not count against every later process. nil = 3 GiB.
    public var maxTotalSwapGrowthBytes: UInt64?
    public var perRunTimeoutSeconds: Double = 900
    /// Whole-plan budget; remaining runs are skipped once exceeded.
    public var maxTotalSeconds: Double?

    public init() {}
}

public struct BenchmarkPlan: Codable, Sendable {
    public var workload: Workload
    /// configs[0] is the baseline every other config is compared with.
    public var configs: [InferenceConfig]
    /// Separate runtime processes per config. Confidence intervals are computed
    /// across rounds, because repetitions inside one process share its state
    /// (load placement, caches, thermal moment) and are not independent.
    public var rounds: Int
    /// llama-bench repetitions per process (`-r`).
    public var repetitions: Int
    /// Order of configs is reshuffled every round with this seed, so slow drift
    /// (heat, background load) cannot systematically favour one config.
    public var seed: UInt64
    public var cooldownSeconds: Double
    public var limits: SafetyLimits

    public init(workload: Workload = Workload(), configs: [InferenceConfig], rounds: Int = 3, repetitions: Int = 3,
                seed: UInt64 = UInt64.random(in: 1...UInt64.max), cooldownSeconds: Double = 2, limits: SafetyLimits = SafetyLimits()) {
        self.workload = workload
        self.configs = configs
        self.rounds = rounds
        self.repetitions = repetitions
        self.seed = seed
        self.cooldownSeconds = cooldownSeconds
        self.limits = limits
    }

    /// (round, configIndex) in execution order.
    public func schedule() -> [(round: Int, config: Int)] {
        var rng = SplitMix64(seed: seed)
        var out: [(Int, Int)] = []
        for r in 0..<rounds {
            var order = Array(configs.indices)
            order.shuffle(using: &rng)
            out += order.map { (r, $0) }
        }
        return out
    }
}

public struct PreflightIssue: Codable, Sendable, Equatable, CustomStringConvertible {
    public var blocking: Bool
    public var message: String
    public var description: String { (blocking ? "BLOCKED: " : "warning: ") + message }
}

public struct Trial: Codable, Sendable {
    public var sequence: Int
    public var round: Int
    public var configIndex: Int
    public var command: [String]
    public var outcome: ChildOutcome
    public var measurements: [TestMeasurement]
    public var wallSeconds: Double
    /// Excludes memory-mapped weights; see `ChildResult.peakFootprintBytes`.
    public var peakFootprintBytes: UInt64?
    public var energyNanojoules: UInt64?
    public var stateBefore: SystemState
    public var stateAfter: SystemState
    public var notableLog: [String]
    public var error: String?
    /// Includes resident mapped weights; see `ChildResult.peakResidentBytes`.
    public var peakResidentBytes: UInt64? = nil
}

public struct KindResult: Codable, Sendable {
    public var kind: TestKind
    /// One mean per round (process). The CI is over these.
    public var roundMeans: [Double]
    public var summary: Summary
    /// Every repetition, for spread and outlier reporting.
    public var sampleSummary: Summary
    public var outlierSamples: [Double]
    /// nil for the baseline itself.
    public var vsBaseline: Comparison?
    /// Rounds (0-based) whose mean is a MAD outlier among the round means: a
    /// disturbed process, e.g. background load. Kept in the CI, but reported.
    public var outlierRounds: [Int]? = nil
}

public struct ConfigResult: Codable, Sendable {
    public var configIndex: Int
    public var config: InferenceConfig
    public var label: String
    public var kinds: [KindResult]
    public var peakFootprintBytes: UInt64?
    public var failedTrials: Int
    /// prompt / pp_tps + 1 / tg_tps. Excludes tokenization, sampling, HTTP and
    /// load; a lower bound on real TTFT, labelled as an estimate everywhere.
    public var derivedTTFTEstimateSeconds: Double?
    public var peakResidentBytes: UInt64? = nil

    public func kind(_ k: TestKind) -> KindResult? { kinds.first { $0.kind == k } }
}

public struct BenchmarkReport: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case completed, partial, blocked, failed, cancelled, dryRun = "dry_run" }

    public var id: UUID
    public var toolVersion: String
    public var startedAt: Date
    public var finishedAt: Date
    public var status: Status
    public var statusDetail: String?
    public var hardware: HardwareInfo
    public var model: ModelInfo
    public var installation: RuntimeInstallation
    public var plan: BenchmarkPlan
    public var preflight: [PreflightIssue]
    public var trials: [Trial]
    public var results: [ConfigResult]
    public var warnings: [String]
}

public enum BenchmarkEvent: Sendable {
    case preflight([PreflightIssue])
    case trialStarted(index: Int, total: Int, round: Int, label: String)
    case trialFinished(Trial)
    case note(String)
}

public struct BenchmarkRunner: Sendable {
    public var adapter: RuntimeAdapter
    public var probe: HardwareProbe
    public var registry: ChildRegistry?

    public init(adapter: RuntimeAdapter, probe: HardwareProbe = HardwareProbes.current(), registry: ChildRegistry? = .shared) {
        self.adapter = adapter
        self.probe = probe
        self.registry = registry
    }

    // MARK: Preflight

    public static func preflight(plan: BenchmarkPlan, model: ModelInfo, hardware: HardwareInfo, state: SystemState) -> [PreflightIssue] {
        var out: [PreflightIssue] = []
        let l = plan.limits
        if state.power.source == .battery && !l.allowBattery {
            out.append(.init(blocking: true, message: "running on battery; plug in, or allow battery testing explicitly"))
        }
        if state.power.source == .battery, let pct = state.power.batteryPercent, pct < l.minBatteryPercent {
            out.append(.init(blocking: true, message: "battery at \(pct)% (minimum \(l.minBatteryPercent)%)"))
        }
        if state.power.lowPowerMode {
            out.append(.init(blocking: false, message: "Low Power Mode is on; results will not represent normal performance"))
        }
        if state.thermal != .unavailable && state.thermal > l.maxStartThermal {
            out.append(.init(blocking: true, message: "thermal state is \(state.thermal.rawValue); let the Mac cool down first"))
        }
        if let m = state.memory {
            if m.pressure >= l.abortMemoryPressure {
                out.append(.init(blocking: true, message: "memory pressure is \(m.pressure.rawValue)"))
            } else if m.pressure == .warning {
                out.append(.init(blocking: false, message: "memory pressure is elevated; close other apps for stable results"))
            }
            let ctx = plan.workload.promptTokens + plan.workload.genTokens + plan.workload.depth
            let kv = plan.configs.compactMap {
                model.kvCacheBytesEstimate(contextTokens: ctx, typeK: $0.cacheTypeK ?? "f16", typeV: $0.cacheTypeV ?? "f16")
            }.max() ?? 0
            let need = model.weightBytes + kv
            if need > m.totalBytes * 85 / 100 {
                out.append(.init(blocking: true, message: "model needs ~\(fmtBytes(need)) of \(fmtBytes(m.totalBytes)) RAM; it will not run safely"))
            } else if need > m.availableEstimateBytes {
                out.append(.init(blocking: false, message: "model needs ~\(fmtBytes(need)), about \(fmtBytes(m.availableEstimateBytes)) looks available; macOS may compress or swap"))
            }
            if let gpu = hardware.gpus.first, let ws = gpu.recommendedMaxWorkingSetBytes, need > ws {
                out.append(.init(blocking: false, message: "model needs ~\(fmtBytes(need)), above the GPU working-set recommendation of \(fmtBytes(ws))"))
            }
        }
        if plan.configs.isEmpty {
            out.append(.init(blocking: true, message: "no configurations to run"))
        }
        if plan.rounds < 2 {
            out.append(.init(blocking: false, message: "with 1 round no confidence interval can be computed"))
        }
        return out
    }

    // MARK: Run

    /// `swapBaseline`: swap usage to measure growth from (a tune passes the value
    /// from its own start, so growth across stages is caught). Defaults to now.
    public func run(plan: BenchmarkPlan, modelURL: URL, model: ModelInfo, installation: RuntimeInstallation,
                    dryRun: Bool = false, swapBaseline: UInt64? = nil,
                    onEvent: @escaping @Sendable (BenchmarkEvent) -> Void = { _ in }) async -> BenchmarkReport {
        let started = Date()
        let hw = probe.hardware()
        let state0 = probe.state()
        var report = BenchmarkReport(id: UUID(), toolVersion: zoomiesVersion, startedAt: started, finishedAt: started,
                                     status: .completed, statusDetail: nil, hardware: hw, model: model,
                                     installation: installation, plan: plan, preflight: [], trials: [], results: [], warnings: [])

        var issues = Self.preflight(plan: plan, model: model, hardware: hw, state: state0)
        for (i, c) in plan.configs.enumerated() {
            for v in adapter.validate(c, installation: installation, model: model, hardware: hw) {
                issues.append(.init(blocking: v.severity == .error, message: "config \(i) [\(c.label)]: \(v)"))
            }
        }
        report.preflight = issues
        onEvent(.preflight(issues))
        if dryRun {
            report.status = .dryRun
            report.finishedAt = Date()
            return report
        }
        if issues.contains(where: \.blocking) {
            report.status = .blocked
            report.statusDetail = issues.filter(\.blocking).map(\.message).joined(separator: "; ")
            report.finishedAt = Date()
            return report
        }

        let schedule = plan.schedule()
        let limits = plan.limits
        let guardCheck = Self.makeGuard(probe: probe, limits: limits, swapAtStart: swapBaseline ?? state0.memory?.swapUsedBytes)

        for (seq, item) in schedule.enumerated() {
            if Task.isCancelled { report.status = .cancelled; break }
            if let max = limits.maxTotalSeconds, Date().timeIntervalSince(started) > max {
                report.status = .partial
                report.statusDetail = "time budget of \(Int(max)) s used up after \(seq) of \(schedule.count) runs"
                break
            }
            let config = plan.configs[item.config]
            onEvent(.trialStarted(index: seq, total: schedule.count, round: item.round, label: config.label))
            let cmd = adapter.benchmarkCommand(model: modelURL, config: config, workload: plan.workload,
                                               repetitions: plan.repetitions, installation: installation)
            let trial = await execute(cmd, sequence: seq, round: item.round, configIndex: item.config,
                                      limits: limits, guardCheck: guardCheck)
            report.trials.append(trial)
            onEvent(.trialFinished(trial))

            if case .aborted(let reason) = trial.outcome {
                report.status = .partial
                report.statusDetail = "stopped by safety guard: \(reason)"
                break
            }
            if trial.outcome == .cancelled { report.status = .cancelled; break }
            if plan.cooldownSeconds > 0 && seq + 1 < schedule.count {
                try? await Task.sleep(nanoseconds: UInt64(plan.cooldownSeconds * 1e9))
            }
        }

        report.results = Self.aggregate(plan: plan, trials: report.trials)
        report.warnings += Self.driftWarnings(plan: plan, trials: report.trials)
        if report.status == .completed, report.trials.allSatisfy({ $0.error != nil }) {
            report.status = .failed
            report.statusDetail = report.trials.first?.error
        }
        report.finishedAt = Date()
        return report
    }

    /// The safety guard polled while a benchmark process runs. Swap growth is
    /// measured from `swapAtStart`, the start of the whole plan or tune.
    public static func makeGuard(probe: HardwareProbe, limits: SafetyLimits, swapAtStart: UInt64?) -> ChildGuard {
        let pressureSince = PressureClock()
        let grace = limits.memoryPressureGraceSeconds ?? 5
        return {
            let s = probe.state()
            if s.thermal != .unavailable && s.thermal >= limits.abortThermal { return "thermal state reached \(s.thermal.rawValue)" }
            if let m = s.memory {
                if m.pressure != .unavailable && m.pressure >= limits.abortMemoryPressure {
                    if pressureSince.elapsed(now: Date()) >= grace {
                        return "memory pressure \(m.pressure.rawValue) for \(Int(grace)) s"
                    }
                } else {
                    pressureSince.reset()
                }
                let total = limits.maxTotalSwapGrowthBytes ?? (3 << 30)
                if let a = swapAtStart, let b = m.swapUsedBytes, b > a, b - a > total {
                    return "system swap grew by \(fmtBytes(b - a)) since the run started; memory is tight, close other apps"
                }
            }
            if s.power.source == .battery && !limits.allowBattery { return "switched to battery power" }
            if s.power.source == .battery, let p = s.power.batteryPercent, p < limits.minBatteryPercent { return "battery below \(limits.minBatteryPercent)%" }
            return nil
        }
    }

    /// Runs one benchmark process under the guard and turns it into a Trial.
    /// A process Zoomies stopped is reported as stopped, never as a runtime failure.
    public func execute(_ cmd: [String], sequence: Int, round: Int, configIndex: Int,
                        limits: SafetyLimits, guardCheck: ChildGuard?) async -> Trial {
        let before = probe.state()
        var trial = Trial(sequence: sequence, round: round, configIndex: configIndex, command: cmd, outcome: .cancelled,
                          measurements: [], wallSeconds: 0, peakFootprintBytes: nil, energyNanojoules: nil,
                          stateBefore: before, stateAfter: before, notableLog: [], error: nil)
        // Per-process swap check, measured from this process's start.
        let probe = self.probe
        let swap0 = before.memory?.swapUsedBytes
        let perProcess: ChildGuard = {
            guard let a = swap0, let b = probe.state().memory?.swapUsedBytes, b > a, b - a > limits.maxSwapGrowthBytes else { return nil }
            return "system swap grew by \(fmtBytes(b - a)) during this measurement; it does not fit in memory alongside your other apps"
        }
        let combined: ChildGuard = { guardCheck?() ?? perProcess() }
        do {
            let r = try await ChildProcess.run(cmd, timeout: limits.perRunTimeoutSeconds, guardCheck: combined, registry: registry)
            trial.outcome = r.outcome
            trial.wallSeconds = r.wallSeconds
            trial.peakFootprintBytes = r.peakFootprintBytes
            trial.peakResidentBytes = r.peakResidentBytes
            trial.energyNanojoules = r.energyNanojoules
            trial.notableLog = LlamaBenchAdapter.notableLogLines(r.stderr)
            switch r.outcome {
            case .aborted(let reason):
                trial.error = "stopped by safety guard: \(reason)"
                // Tests that finished before the stop are complete and valid; keep them.
                trial.measurements = (try? adapter.parseBenchmarkOutput(stdout: r.stdout, stderr: r.stderr)) ?? []
            case .timedOut: trial.error = "timed out after \(Int(limits.perRunTimeoutSeconds)) s"
            case .cancelled: trial.error = "cancelled"
            case .exited, .signaled:
                do {
                    trial.measurements = try adapter.parseBenchmarkOutput(stdout: r.stdout, stderr: r.stderr)
                } catch {
                    trial.error = "\(error)"
                }
                if !r.outcome.isSuccess && trial.error == nil {
                    trial.error = "process ended: \(r.outcome); stderr tail: \(LlamaBenchAdapter.errorTail(r.stderr))"
                }
            }
        } catch {
            trial.error = "could not start: \(error)"
            trial.outcome = .aborted(reason: "launch failed")
        }
        trial.stateAfter = probe.state()
        return trial
    }

    // MARK: Analysis

    public static func aggregate(plan: BenchmarkPlan, trials: [Trial]) -> [ConfigResult] {
        var results: [ConfigResult] = []
        var baselineRounds: [TestKind: [Double]] = [:]
        for (i, config) in plan.configs.enumerated() {
            let mine = trials.filter { $0.configIndex == i }
            let ok = mine.filter { $0.error == nil }
            var kinds: [KindResult] = []
            for kind in [TestKind.promptProcessing, .generation] {
                let withM = ok.compactMap { t in t.measurements.first { $0.kind == kind }.map { (t.round, $0) } }
                let ms = withM.map(\.1)
                guard !ms.isEmpty else { continue }
                let roundMeans = ms.map { Stats.mean($0.samplesTPS) }
                let samples = ms.flatMap(\.samplesTPS)
                let outliers = Stats.outlierIndices(samples).map { samples[$0] }
                var kr = KindResult(kind: kind, roundMeans: roundMeans, summary: Stats.summarize(roundMeans),
                                    sampleSummary: Stats.summarize(samples), outlierSamples: outliers, vsBaseline: nil)
                kr.outlierRounds = Stats.outlierIndices(roundMeans).map { withM[$0].0 }
                if i == 0 {
                    baselineRounds[kind] = roundMeans
                } else if let base = baselineRounds[kind] {
                    kr.vsBaseline = Comparison.welch(baseline: base, candidate: roundMeans)
                }
                kinds.append(kr)
            }
            var ttft: Double?
            if let pp = kinds.first(where: { $0.kind == .promptProcessing })?.summary.mean,
               let tg = kinds.first(where: { $0.kind == .generation })?.summary.mean, pp > 0, tg > 0 {
                ttft = Double(plan.workload.promptTokens) / pp + 1 / tg
            }
            results.append(ConfigResult(configIndex: i, config: config, label: config.label, kinds: kinds,
                                        peakFootprintBytes: ok.compactMap(\.peakFootprintBytes).max(),
                                        failedTrials: mine.count - ok.count, derivedTTFTEstimateSeconds: ttft,
                                        peakResidentBytes: ok.compactMap(\.peakResidentBytes).max()))
        }
        return results
    }

    /// Flags runs where the baseline's own speed moved between its first and
    /// last round by more than 5%, or where the Mac heated up mid-plan.
    public static func driftWarnings(plan: BenchmarkPlan, trials: [Trial]) -> [String] {
        var out: [String] = []
        let base = trials.filter { $0.configIndex == 0 && $0.error == nil }.sorted { $0.sequence < $1.sequence }
        for kind in [TestKind.generation, .promptProcessing] {
            let means = base.compactMap { t in t.measurements.first { $0.kind == kind }.map { Stats.mean($0.samplesTPS) } }
            guard means.count >= 2, let first = means.first, let last = means.last, first > 0 else { continue }
            let change = (last - first) / first
            if abs(change) > 0.05 {
                out.append(String(format: "baseline %@ speed drifted %+.1f%% from first to last round (heat or background load?); comparisons are less reliable",
                                  kind.rawValue, change * 100))
            }
        }
        let worst = trials.map(\.stateAfter.thermal).filter { $0 != .unavailable }.max()
        if let w = worst, w > .nominal {
            out.append("thermal state reached \(w.rawValue) during the plan")
        }
        if trials.contains(where: { $0.stateBefore.power.source != $0.stateAfter.power.source }) {
            out.append("power source changed during the plan")
        }
        return out
    }
}

/// When memory pressure first reached the abort level; reset when it drops.
final class PressureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var since: Date?
    func elapsed(now: Date) -> Double {
        lock.lock(); defer { lock.unlock() }
        if since == nil { since = now }
        return now.timeIntervalSince(since!)
    }
    func reset() { lock.lock(); since = nil; lock.unlock() }
}

/// Small deterministic RNG so a plan's run order can be reproduced from its seed.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public func fmtBytes(_ b: UInt64) -> String {
    let gib = Double(b) / 1_073_741_824
    return gib >= 1 ? String(format: "%.2f GiB", gib) : String(format: "%.0f MiB", Double(b) / 1_048_576)
}
