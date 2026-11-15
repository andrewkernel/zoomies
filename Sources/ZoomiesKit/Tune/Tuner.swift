import Foundation

/// Finds better runtime settings, and proves them against the defaults.
///
/// 1. **Screen.** For each setting, one process sweeps all its values with the
///    model loaded once (llama-bench comma lists). Values are compared with the
///    default *inside the same process*, which cancels load-to-load variation.
///    Cheap, and used for ranking only: it never decides on its own.
/// 2. **Compose.** The best value of each setting alone, plus the combinations
///    of the best values, become candidates.
/// 3. **Narrow.** Candidates and the defaults run as separate processes, in a
///    shuffled order per round; the bottom half is dropped each stage
///    (successive halving).
/// 4. **Verify.** The survivor and the defaults run again on *fresh* rounds.
///    Picking the best of several noisy measurements flatters the winner
///    (the winner's curse), so the data that chose it is not reused to judge it.
///    The win must be significant and at least 2%, using a paired comparison
///    per round, and the other metric must stay within the guardrail.
public struct Tuner: Sendable {
    public var runner: BenchmarkRunner
    /// Values within the same process must beat the default by this much to survive screening.
    public var screenThreshold = 0.015
    public var cooldownSeconds: Double = 1

    public init(runner: BenchmarkRunner) {
        self.runner = runner
    }

    public func tune(request: TuneRequest, modelURL: URL, model: ModelInfo, installation: RuntimeInstallation,
                     onEvent: @escaping @Sendable (TuneEvent) -> Void = { _ in },
                     onBenchmarkReport: @escaping @Sendable (BenchmarkReport) -> Void = { _ in }) async -> TuneReport {
        var session = Session(tuner: self, request: request, modelURL: modelURL, model: model,
                              installation: installation, onEvent: onEvent, onBenchmarkReport: onBenchmarkReport)
        let report = await session.run()
        onEvent(.finished(report))
        return report
    }
}

// MARK: - Session

private struct Session {
    let tuner: Tuner
    let request: TuneRequest
    let modelURL: URL
    let model: ModelInfo
    let installation: RuntimeInstallation
    let onEvent: @Sendable (TuneEvent) -> Void
    let onBenchmarkReport: @Sendable (BenchmarkReport) -> Void

    let started = Date()
    var hardware: HardwareInfo
    var swap0: UInt64?
    var guardCheck: ChildGuard
    var report: TuneReport
    var secondsPerProcess: Double?

    var runner: BenchmarkRunner { tuner.runner }
    var adapter: RuntimeAdapter { tuner.runner.adapter }
    var workload: Workload { report.workload }
    var limits: SafetyLimits { request.constraints.limits }

    init(tuner: Tuner, request: TuneRequest, modelURL: URL, model: ModelInfo, installation: RuntimeInstallation,
         onEvent: @escaping @Sendable (TuneEvent) -> Void, onBenchmarkReport: @escaping @Sendable (BenchmarkReport) -> Void) {
        self.tuner = tuner
        self.request = request
        self.modelURL = modelURL
        self.model = model
        self.installation = installation
        self.onEvent = onEvent
        self.onBenchmarkReport = onBenchmarkReport
        hardware = tuner.runner.probe.hardware()
        let s0 = tuner.runner.probe.state()
        swap0 = s0.memory?.swapUsedBytes
        guardCheck = BenchmarkRunner.makeGuard(probe: tuner.runner.probe, limits: request.constraints.limits, swapAtStart: swap0)
        report = TuneReport(id: UUID(), toolVersion: zoomiesVersion, startedAt: Date(), finishedAt: Date(), request: request,
                            workload: request.workload, hardware: hardware, model: model, installation: installation,
                            screen: [], stages: [],
                            decision: TuneDecision(kind: .incomplete, config: .runtimeDefaults, headline: "Not started",
                                                   primary: nil, primaryMetric: nil, secondary: nil, secondaryMetric: nil, details: []),
                            warnings: [], processCount: 0)
    }

    // MARK: Flow

    mutating func run() async -> TuneReport {
        defer { report.finishedAt = Date() }

        // Preflight once, on the plain defaults.
        let state = runner.probe.state()
        let pre = BenchmarkRunner.preflight(plan: BenchmarkPlan(workload: workload, configs: [.runtimeDefaults], rounds: 2,
                                                                 limits: limits),
                                            model: model, hardware: hardware, state: state)
        report.warnings += pre.filter { !$0.blocking }.map(\.message)
        if let blocked = pre.first(where: \.blocking) {
            return stop("Can't start: \(blocked.message)")
        }

        // 1. Screen
        let space = SearchSpace.build(request: request, model: model, hardware: hardware,
                                      installation: installation, adapter: adapter)
        for d in space { report.warnings += d.notes.map { "\(d.dimension.title): \($0)" } }
        let searchable = space.filter { $0.values.count >= 2 }
        guard !searchable.isEmpty else {
            return stop("Nothing to tune: this llama.cpp build exposes none of the settings Zoomies searches")
        }
        onEvent(.stageStarted(.screen, detail: "\(searchable.count) settings, one process each"))
        for dim in searchable {
            if let reason = interruption() { return stop(reason) }
            emitEstimate(remainingScreens: searchable.count - report.screen.count)
            guard let result = await screen(dim) else {
                return stop(report.decision.headline == "Not started" ? "Screening stopped" : report.decision.headline)
            }
            report.screen.append(result)
            onEvent(.screened(result))
        }

        // 2. Compose
        let candidates = compose()
        onEvent(.candidates(candidates))
        guard !candidates.isEmpty else {
            let best = report.screen.flatMap { r in r.values.filter { !$0.isDefault }.map { (r.dimension, $0) } }
                .max { ($0.1.relativeScore ?? -1) < ($1.1.relativeScore ?? -1) }
            var details = ["Every setting was screened next to its default in the same process; none was \(pct(tuner.screenThreshold)) better."]
            if let (d, v) = best, let s = v.relativeScore {
                details.append("Best alternative: \(d.title) = \(v.value), \(signedPct(s)) vs the default in screening.")
            }
            return finish(.keepDefaults, config: .runtimeDefaults,
                          headline: "Your defaults are already the fastest for \(request.objective.title.lowercased())",
                          details: details)
        }

        // 3. Narrow
        var field = candidates
        for (i, rounds) in request.budget.narrowingRounds.enumerated() where field.count > 1 {
            if let reason = interruption() { return stop(reason) }
            onEvent(.stageStarted(.narrow, detail: "\(field.count) candidates + defaults, \(rounds) rounds"))
            emitEstimate(processes: rounds * (field.count + 1) + request.budget.validationRounds * 2)
            let plan = BenchmarkPlan(workload: workload, configs: [.runtimeDefaults] + field, rounds: rounds,
                                     repetitions: request.budget.repetitions, seed: request.seed &+ UInt64(i + 1),
                                     cooldownSeconds: tuner.cooldownSeconds, limits: stageLimits())
            guard let rep = await bench(plan) else { return report }
            let scored = rep.results.dropFirst().map { r in (r, score(r, vs: rep.results[0])) }
                .sorted { ($0.1 ?? -.infinity) > ($1.1 ?? -.infinity) }
            let keep = max(1, (scored.count + 1) / 2)
            var survivors: [InferenceConfig] = []
            var stage = TuneStage(kind: .narrow, benchmarkRunID: rep.id, candidates: [], note: nil)
            for (idx, (r, s)) in scored.enumerated() {
                let kept = idx < keep && (s ?? -1) > 0
                if kept { survivors.append(r.config) }
                stage.candidates.append(StageCandidate(config: r.config, label: r.label, relativeScore: s, kept: kept))
            }
            report.stages.append(stage)
            onEvent(.stageFinished(stage))
            guard !survivors.isEmpty else {
                let top = scored.first
                return finish(.keepDefaults, config: .runtimeDefaults,
                              headline: "Your defaults are already the fastest for \(request.objective.title.lowercased())",
                              details: ["Screening looked promising, but measured as separate processes no candidate beat the defaults."]
                                + (top.flatMap { t in t.1.map { "Best candidate \(t.0.label): \(signedPct($0)) vs defaults." } }.map { [$0] } ?? []))
            }
            field = survivors
        }

        // 4. Verify
        if let reason = interruption() { return stop(reason) }
        let winner = field[0]
        onEvent(.stageStarted(.verify, detail: "\(winner.label) vs defaults, \(request.budget.validationRounds) fresh rounds"))
        emitEstimate(processes: request.budget.validationRounds * 2)
        let plan = BenchmarkPlan(workload: workload, configs: [.runtimeDefaults, winner], rounds: request.budget.validationRounds,
                                 repetitions: request.budget.repetitions, seed: request.seed &+ 100,
                                 cooldownSeconds: tuner.cooldownSeconds, limits: stageLimits())
        guard let rep = await bench(plan) else { return report }
        return decide(winner: winner, verification: rep)
    }

    // MARK: Screening

    /// Sweeps one setting. Returns nil when the tune must stop (the reason is in the decision).
    mutating func screen(_ dim: SearchDimension) async -> ScreenResult? {
        onEvent(.screening(dim.dimension, values: dim.values))
        let t0 = Date()
        var byValue: [String: (pp: [Double], tg: [Double])] = [:]
        var note: String?
        var doesNotFit = Set<String>()

        func collect(_ trial: Trial) {
            for m in trial.measurements {
                guard let v = adapter.effectiveValue(dim.dimension, of: m) ?? (dim.values.count == 1 ? dim.values[0] : nil) else { continue }
                var e = byValue[v] ?? ([], [])
                if m.kind == .promptProcessing { e.pp += m.samplesTPS } else { e.tg += m.samplesTPS }
                byValue[v] = e
            }
        }

        if let cmd = adapter.sweepCommand(model: modelURL, dimension: dim.dimension, values: dim.values, workload: workload,
                                          repetitions: request.budget.repetitions, installation: installation) {
            let trial = await runOne(cmd, configIndex: -1)
            if let unfit = memoryStop(trial) {
                // Values finished before the stop are valid; the one running when memory ran out,
                // and larger ones of the same setting, don't fit next to the user's other apps.
                collect(trial)
                let w = workload
                func complete(_ v: String) -> Bool {
                    guard let e = byValue[v] else { return false }
                    return (w.promptTokens == 0 || !e.pp.isEmpty) && (w.genTokens == 0 || !e.tg.isEmpty)
                }
                let stoppedAt = dim.values.first { !complete($0) }
                if let v = stoppedAt { byValue[v] = nil }  // half-measured while memory ran out: not trustworthy
                let measured = dim.values.filter { byValue[$0] != nil }
                if let v = stoppedAt { doesNotFit = Set(dim.values.drop { $0 != v }) }
                note = "\(stoppedAt.map { "\($0) and later values" } ?? "a value") did not fit in memory (\(unfit)); measured: \(measured.joined(separator: ", "))"
            } else if let stop = stopReason(trial) {
                report.decision.headline = stop
                return nil
            } else if trial.error == nil {
                collect(trial)
            } else {
                note = "the combined sweep failed (\(trial.error!.prefix(120))); values were measured one by one"
            }
        }
        // Fallback, and salvage for values the sweep could not attribute: one process per value.
        let missing = dim.values.filter { byValue[$0] == nil && !doesNotFit.contains($0) }
        if !missing.isEmpty && (missing.count < dim.values.count || note != nil || byValue.isEmpty) {
            for v in missing {
                let config = InferenceConfig.runtimeDefaults.setting(dim.dimension, v == dim.defaultValue ? nil : v)
                let cmd = adapter.benchmarkCommand(model: modelURL, config: config, workload: workload,
                                                   repetitions: request.budget.repetitions, installation: installation)
                let trial = await runOne(cmd, configIndex: -1)
                if memoryStop(trial) != nil { doesNotFit.insert(v); continue }
                if let stop = stopReason(trial) { report.decision.headline = stop; return nil }
                if trial.error == nil {
                    for m in trial.measurements {
                        var e = byValue[v] ?? ([], [])
                        if m.kind == .promptProcessing { e.pp += m.samplesTPS } else { e.tg += m.samplesTPS }
                        byValue[v] = e
                    }
                }
            }
        }

        let base = byValue[dim.defaultValue]
        var values: [ScreenValue] = []
        for v in dim.values {
            let e = byValue[v]
            let pp = e.flatMap { $0.pp.isEmpty ? nil : Stats.mean($0.pp) }
            let tg = e.flatMap { $0.tg.isEmpty ? nil : Stats.mean($0.tg) }
            var rel: Double?
            if v != dim.defaultValue, let b = base {
                rel = relative(pp: pp, tg: tg, basePP: b.pp.isEmpty ? nil : Stats.mean(b.pp), baseTG: b.tg.isEmpty ? nil : Stats.mean(b.tg))
            }
            values.append(ScreenValue(value: v, isDefault: v == dim.defaultValue, ppTPS: pp, tgTPS: tg, relativeScore: rel, kept: false))
        }
        if base == nil { note = (note.map { $0 + "; " } ?? "") + "the default value produced no measurement, so nothing could be compared" }

        // Keep the best value (two on a thorough budget) that clears the screen threshold.
        let keepCount = request.budget == .thorough ? 2 : 1
        let ranked = values.indices.filter { !values[$0].isDefault && values[$0].relativeScore != nil }
            .sorted { values[$0].relativeScore! > values[$1].relativeScore! }
        for i in ranked.prefix(keepCount) where keepable(dim.dimension, values[i]) { values[i].kept = true }

        let wall = Date().timeIntervalSince(t0)
        let perProcess = wall / Double(max(1, dim.values.count))
        secondsPerProcess = secondsPerProcess.map { ($0 + perProcess) / 2 } ?? perProcess
        return ScreenResult(dimension: dim.dimension, defaultValue: dim.defaultValue, values: values, note: note, wallSeconds: wall)
    }

    func keepable(_ d: TuneDimension, _ v: ScreenValue) -> Bool {
        guard let rel = v.relativeScore else { return false }
        if request.objective == .memory {
            // Memory can't be measured per value inside one process; keep values that
            // plausibly shrink buffers, as long as speed holds up.
            let shrinks = (d == .kvCache && v.value != "f16") || (d == .ubatch && (Int(v.value) ?? .max) < 512)
            return shrinks && rel >= -request.constraints.guardrailPercent / 100
        }
        return rel >= tuner.screenThreshold
    }

    // MARK: Composition

    func compose() -> [InferenceConfig] {
        var best: [(TuneDimension, String, Double)] = []
        for r in report.screen {
            for v in r.values where v.kept { best.append((r.dimension, v.value, v.relativeScore ?? 0)) }
        }
        best.sort { $0.2 > $1.2 }
        var out: [InferenceConfig] = []
        func add(_ c: InferenceConfig) {
            guard c != .runtimeDefaults, !out.contains(c),
                  !adapter.validate(c, installation: installation, model: model, hardware: hardware).contains(where: { $0.severity == .error })
            else { return }
            out.append(c)
        }
        // Best value per setting, combined: usually the strongest candidate.
        var seen = Set<TuneDimension>()
        var combo = InferenceConfig.runtimeDefaults
        for (d, v, _) in best where !seen.contains(d) {
            combo = combo.setting(d, v)
            seen.insert(d)
        }
        if seen.count >= 2 { add(combo) }
        // Each change alone, strongest first.
        for (d, v, _) in best { add(InferenceConfig.runtimeDefaults.setting(d, v)) }
        // The top two settings together, when there are more than two.
        let topDims = Array(seen.prefix(2))
        if seen.count > 2, topDims.count == 2 {
            var pair = InferenceConfig.runtimeDefaults
            for (d, v, _) in best where topDims.contains(d) && pair.value(d) == nil { pair = pair.setting(d, v) }
            add(pair)
        }
        return Array(out.prefix(request.budget.maxCandidates))
    }

    // MARK: Scoring

    /// Objective score relative to a reference (+0.05 = 5% better). nil if unmeasurable.
    func relative(pp: Double?, tg: Double?, basePP: Double?, baseTG: Double?) -> Double? {
        func ratio(_ a: Double?, _ b: Double?) -> Double? { guard let a, let b, b > 0 else { return nil }; return a / b }
        switch request.objective {
        case .generation: return ratio(tg, baseTG).map { $0 - 1 }
        case .response: return ratio(pp, basePP).map { $0 - 1 }
        case .balanced:
            guard let a = ratio(pp, basePP), let b = ratio(tg, baseTG) else { return nil }
            return (a * b).squareRoot() - 1
        case .memory: return ratio(tg, baseTG).map { $0 - 1 }  // speed guard during screening
        }
    }

    func score(_ r: ConfigResult, vs base: ConfigResult) -> Double? {
        if request.objective == .memory {
            guard let a = r.peakFootprintBytes, let b = base.peakFootprintBytes, a > 0,
                  let speed = relative(pp: nil, tg: r.kind(.generation)?.summary.mean, basePP: nil,
                                       baseTG: base.kind(.generation)?.summary.mean),
                  speed >= -request.constraints.guardrailPercent / 100 else { return nil }
            return Double(b) / Double(a) - 1
        }
        return relative(pp: r.kind(.promptProcessing)?.summary.mean, tg: r.kind(.generation)?.summary.mean,
                        basePP: base.kind(.promptProcessing)?.summary.mean, baseTG: base.kind(.generation)?.summary.mean)
    }

    // MARK: Decision

    mutating func decide(winner: InferenceConfig, verification rep: BenchmarkReport) -> TuneReport {
        report.stages.append(TuneStage(kind: .verify, benchmarkRunID: rep.id,
                                       candidates: [StageCandidate(config: winner, label: winner.label, relativeScore: nil, kept: true)],
                                       note: nil))
        // Per-round pairs: defaults and winner measured in the same round.
        var pairs: [(base: Trial, win: Trial)] = []
        for round in 0..<rep.plan.rounds {
            let inRound = rep.trials.filter { $0.round == round && $0.error == nil }
            if let b = inRound.first(where: { $0.configIndex == 0 }), let w = inRound.first(where: { $0.configIndex == 1 }) {
                pairs.append((b, w))
            }
        }
        func mean(_ t: Trial, _ k: TestKind) -> Double? {
            t.measurements.first { $0.kind == k }.map { Stats.mean($0.samplesTPS) }
        }
        func ratios(_ k: TestKind) -> [Double] {
            pairs.compactMap { p in guard let w = mean(p.win, k), let b = mean(p.base, k), b > 0 else { return nil }; return w / b }
        }
        let pp = Comparison.pairedRatio(ratios(.promptProcessing))
        let tg = Comparison.pairedRatio(ratios(.generation))
        let guardrail = request.constraints.guardrailPercent

        let primary: Comparison, primaryName: String
        var secondary: Comparison?, secondaryName: String?
        switch request.objective {
        case .generation: (primary, primaryName, secondary, secondaryName) = (tg, "generation speed", pp, "prompt speed")
        case .response: (primary, primaryName, secondary, secondaryName) = (pp, "prompt speed", tg, "generation speed")
        case .balanced:
            let both = pairs.compactMap { p -> Double? in
                guard let wp = mean(p.win, .promptProcessing), let bp = mean(p.base, .promptProcessing),
                      let wt = mean(p.win, .generation), let bt = mean(p.base, .generation), bp > 0, bt > 0 else { return nil }
                return ((wp / bp) * (wt / bt)).squareRoot()
            }
            primary = Comparison.pairedRatio(both)
            primaryName = "combined speed"
        case .memory:
            let mem = pairs.compactMap { p -> Double? in
                guard let w = p.win.peakFootprintBytes, let b = p.base.peakFootprintBytes, w > 0 else { return nil }
                return Double(b) / Double(w)
            }
            primary = Comparison.pairedRatio(mem, minRelevant: 0.05)
            primaryName = "memory (process footprint)"
            (secondary, secondaryName) = (tg, "generation speed")
        }

        var details: [String] = []
        details.append("Verified on \(pairs.count) fresh rounds, defaults and \(winner.label) interleaved; paired 95% CI.")
        if request.objective == .balanced {
            details.append("Prompt speed \(fmtComparison(pp)); generation speed \(fmtComparison(tg)).")
        }
        if let s = secondary, let n = secondaryName { details.append("\(n.prefix(1).uppercased() + n.dropFirst()): \(fmtComparison(s)).") }
        // Name disturbed rounds (a MAD outlier among the per-round ratios); they stay in the CI.
        let primaryRatios = request.objective == .response ? ratios(.promptProcessing) : ratios(.generation)
        let disturbed = Stats.outlierIndices(primaryRatios)
        if !disturbed.isEmpty {
            details.append("Round\(disturbed.count > 1 ? "s" : "") \(disturbed.map { String($0 + 1) }.joined(separator: ", ")) looked disturbed (an outlier among the rounds); kept in the interval, which widens it.")
        }
        if winner.changedDimensions.contains(where: \.affectsQuality) {
            details.append("Uses a quantized KV cache (\(winner.cacheTypeK ?? "")): output can differ slightly from the defaults.")
        }
        if request.objective == .memory {
            details.append("Footprint excludes memory-mapped weights; the saving is in KV and compute buffers.")
        }
        if rep.status != .completed {
            details.append("Verification ended early: \(rep.statusDetail ?? rep.status.rawValue).")
        }
        report.warnings += rep.warnings

        let secondaryBroken = secondary.map { $0.verdict == .slower && $0.relativePercent < -guardrail } ?? false
        if primary.verdict == .faster && !secondaryBroken && rep.status == .completed {
            let what = request.objective == .memory ? "less memory" : primaryName
            let ci = String(format: "[%+.1f%%, %+.1f%%]", primary.relativeCILowPercent, primary.relativeCIHighPercent)
            let headline = request.objective == .memory
                ? String(format: "%.0f%% %@ %@ with %@", primary.relativePercent, what, ci, winner.label)
                : String(format: "%+.1f%% %@ %@ with %@", primary.relativePercent, what, ci, winner.label)
            return finish(.improved, config: winner, headline: headline, primary: primary, primaryName: primaryName,
                          secondary: secondary, secondaryName: secondaryName, details: details)
        }
        if secondaryBroken, let n = secondaryName {
            details.insert("Rejected: it made \(n) \(String(format: "%.1f", -(secondary?.relativePercent ?? 0)))% slower, beyond the \(Int(guardrail))% guardrail.", at: 0)
        } else if rep.status == .completed {
            details.insert("Best candidate \(winner.label): \(primaryName) \(fmtComparison(primary)), not a detectable gain of at least \(request.objective == .memory ? 5 : 2)%.", at: 0)
        }
        let kind: TuneDecision.Kind = rep.status == .completed ? .keepDefaults : .incomplete
        return finish(kind, config: .runtimeDefaults,
                      headline: kind == .keepDefaults ? "Your defaults are already the fastest for \(request.objective.title.lowercased())"
                                                      : "Verification didn't finish; keeping the defaults",
                      primary: primary, primaryName: primaryName, secondary: secondary, secondaryName: secondaryName, details: details)
    }

    // MARK: Plumbing

    mutating func runOne(_ cmd: [String], configIndex: Int) async -> Trial {
        let idx = report.processCount
        onEvent(.bench(.trialStarted(index: idx, total: 0, round: 0, label: "screen")))
        let trial = await runner.execute(cmd, sequence: idx, round: 0, configIndex: configIndex,
                                         limits: limits, guardCheck: guardCheck)
        report.processCount += 1
        onEvent(.bench(.trialFinished(trial)))
        if tuner.cooldownSeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(tuner.cooldownSeconds * 1e9)) }
        return trial
    }

    /// A per-process memory stop: this value doesn't fit, but the tune can go on.
    func memoryStop(_ t: Trial) -> String? {
        guard case .aborted(let r) = t.outcome, r.contains("during this measurement") else { return nil }
        return "swap grew while it ran"
    }

    func stopReason(_ t: Trial) -> String? {
        switch t.outcome {
        case .aborted(let r): return "Stopped by safety guard: \(r)"
        case .cancelled: return "Cancelled"
        case .timedOut: return nil  // one slow value is a failed measurement, not a reason to stop
        default: return Task.isCancelled ? "Cancelled" : nil
        }
    }

    /// Runs a benchmark plan as a stage. nil (with the decision set) when the tune must stop.
    mutating func bench(_ plan: BenchmarkPlan) async -> BenchmarkReport? {
        let onEvent = self.onEvent
        let rep = await runner.run(plan: plan, modelURL: modelURL, model: model, installation: installation,
                                   swapBaseline: swap0, onEvent: { onEvent(.bench($0)) })
        onBenchmarkReport(rep)
        report.processCount += rep.trials.count
        if let d = rep.trials.first.map({ $0.wallSeconds }) { secondsPerProcess = secondsPerProcess.map { ($0 + d) / 2 } ?? d }
        switch rep.status {
        case .completed: return rep
        case .partial where rep.statusDetail?.hasPrefix("time budget") == true && plan.configs.count == 2: return rep
        default:
            _ = stop(rep.statusDetail.map { "Stopped: \($0)" } ?? "Stopped (\(rep.status.rawValue))")
            return nil
        }
    }

    func stageLimits() -> SafetyLimits {
        var l = limits
        if let max = request.constraints.maxSeconds { l.maxTotalSeconds = Swift.max(30, max - Date().timeIntervalSince(started)) }
        return l
    }

    func interruption() -> String? {
        if Task.isCancelled { return "Cancelled" }
        if let max = request.constraints.maxSeconds, Date().timeIntervalSince(started) > max {
            return "Time budget of \(Int(max / 60)) min used up"
        }
        return nil
    }

    func emitEstimate(remainingScreens: Int) {
        guard let s = secondsPerProcess else { return }
        let b = request.budget
        let later = b.narrowingRounds.reduce(0) { $0 + $1 * (b.maxCandidates / 2 + 1) } + b.validationRounds * 2
        onEvent(.estimate(remainingSeconds: s * Double(remainingScreens * 3 + later)))
    }

    func emitEstimate(processes: Int) {
        guard let s = secondsPerProcess else { return }
        onEvent(.estimate(remainingSeconds: (s + tuner.cooldownSeconds) * Double(processes)))
    }

    mutating func stop(_ reason: String) -> TuneReport {
        report.decision = TuneDecision(kind: .incomplete, config: .runtimeDefaults, headline: reason,
                                       primary: nil, primaryMetric: nil, secondary: nil, secondaryMetric: nil,
                                       details: ["Nothing was changed. Results measured so far are saved."])
        report.finishedAt = Date()
        return report
    }

    mutating func finish(_ kind: TuneDecision.Kind, config: InferenceConfig, headline: String, primary: Comparison? = nil,
                         primaryName: String? = nil, secondary: Comparison? = nil, secondaryName: String? = nil,
                         details: [String]) -> TuneReport {
        report.decision = TuneDecision(kind: kind, config: config, headline: headline, primary: primary, primaryMetric: primaryName,
                                       secondary: secondary, secondaryMetric: secondaryName, details: details)
        report.finishedAt = Date()
        return report
    }
}

func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
func signedPct(_ x: Double) -> String { String(format: "%+.1f%%", x * 100) }
public func fmtComparison(_ c: Comparison) -> String {
    guard c.ciLow.isFinite else { return String(format: "%+.1f%% (not enough data for a CI)", c.relativePercent) }
    return String(format: "%+.1f%% [%+.1f%%, %+.1f%%]", c.relativePercent, c.relativeCILowPercent, c.relativeCIHighPercent)
}
