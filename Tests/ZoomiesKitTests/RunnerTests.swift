import Darwin
import Foundation
import Testing
@testable import ZoomiesKit

@Suite(.serialized) struct RunnerTests {
    func setup(sleep: Int = 0, fail: Bool = false) throws -> (BenchmarkRunner, RuntimeInstallation, URL, ModelInfo) {
        let dir = tempDir()
        let exe = fakeLlamaBench(in: dir, sleepSeconds: sleep, fail: fail)
        let adapter = LlamaBenchAdapter(explicitPath: exe.path)
        let inst = try adapter.discover()
        let (url, model) = try tinyModelFile()
        let runner = BenchmarkRunner(adapter: adapter, probe: FakeProbe(), registry: ChildRegistry(directory: dir.appendingPathComponent("children")))
        return (runner, inst, url, model)
    }

    @Test func endToEndWithFakeRuntime() async throws {
        let (runner, inst, url, model) = try setup()
        #expect(inst.buildNumber == 7100 && inst.devices.count == 1)
        let plan = BenchmarkPlan(configs: [.runtimeDefaults, try .parse("fa=on"), try .parse("t=2")], rounds: 3, repetitions: 3,
                                 seed: 7, cooldownSeconds: 0)
        let report = await runner.run(plan: plan, modelURL: url, model: model, installation: inst)
        #expect(report.status == .completed)
        #expect(report.trials.count == 9)
        #expect(report.trials.allSatisfy { $0.error == nil && $0.measurements.count == 2 })
        #expect(report.trials.allSatisfy { $0.notableLog.contains { $0.contains("tensor API") } })

        let base = report.results[0], fa = report.results[1], t2 = report.results[2]
        #expect(base.kind(.promptProcessing)!.summary.n == 3)
        #expect(base.kind(.promptProcessing)!.vsBaseline == nil)
        #expect(fa.kind(.promptProcessing)!.vsBaseline!.verdict == .faster)
        #expect(fa.kind(.generation)!.vsBaseline!.verdict == .faster)
        #expect(t2.kind(.promptProcessing)!.vsBaseline!.verdict == .noDetectableDifference)
        #expect(base.derivedTTFTEstimateSeconds! > 0.5)  // 512 / ~1000 + 1/50
        #expect(base.peakFootprintBytes != nil && base.peakResidentBytes != nil)

        // Persist and read back.
        let store = try ResultStore(url: tempDir().appendingPathComponent("r.sqlite"))
        try store.save(report)
        #expect(try store.count("runs") == 1)
        #expect(try store.count("trials") == 9)
        #expect(try store.count("samples") == 9 * 2 * 3)
        #expect(try store.count("summaries") == 6)
        let back = try #require(try store.report(id: report.id.uuidString))
        #expect(back.results.count == 3 && back.plan.seed == 7)
        #expect(try store.recentRuns().first?.runtimeBuild == 7100)
    }

    @Test func failuresAreRecordedNotHidden() async throws {
        let (runner, inst, url, model) = try setup(fail: true)
        let plan = BenchmarkPlan(configs: [.runtimeDefaults], rounds: 2, repetitions: 1, seed: 1, cooldownSeconds: 0)
        let report = await runner.run(plan: plan, modelURL: url, model: model, installation: inst)
        #expect(report.status == .failed)
        #expect(report.trials.count == 2 && report.trials.allSatisfy { $0.error != nil })
        #expect(report.results[0].failedTrials == 2 && report.results[0].kinds.isEmpty)
    }

    @Test func blockedRunDoesNothing() async throws {
        let (runner, inst, url, model) = try setup()
        var r = runner
        var p = FakeProbe()
        p.st.power.source = .battery
        r.probe = p
        let report = await r.run(plan: BenchmarkPlan(configs: [.runtimeDefaults]), modelURL: url, model: model, installation: inst)
        #expect(report.status == .blocked && report.trials.isEmpty)
    }

    @Test func dryRunRunsNothing() async throws {
        let (runner, inst, url, model) = try setup()
        let report = await runner.run(plan: BenchmarkPlan(configs: [.runtimeDefaults, try .parse("fa=off,ctv=q8_0")]),
                                      modelURL: url, model: model, installation: inst, dryRun: true)
        #expect(report.status == .dryRun && report.trials.isEmpty)
        #expect(report.preflight.contains { $0.blocking && $0.message.contains("cacheTypeV") })
    }

    @Test func cancellationStopsTheChild() async throws {
        let (runner, inst, url, model) = try setup(sleep: 30)
        let plan = BenchmarkPlan(configs: [.runtimeDefaults], rounds: 3, repetitions: 1, seed: 1, cooldownSeconds: 0)
        let start = Date()
        let task = Task { await runner.run(plan: plan, modelURL: url, model: model, installation: inst) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        let report = await task.value
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(report.status == .cancelled)
        #expect(report.trials.count == 1 && report.trials[0].outcome == .cancelled)
    }

    @Test func timeoutAndGuard() async throws {
        let dir = tempDir()
        let sleeper = fakeLlamaBench(in: dir, sleepSeconds: 30)
        let r1 = try await ChildProcess.run([sleeper.path, "-m", "x"], timeout: 0.5, registry: nil)
        #expect(r1.outcome == .timedOut && r1.wallSeconds < 10)
        let r2 = try await ChildProcess.run([sleeper.path, "-m", "x"], timeout: 60, guardCheck: { "memory pressure critical" }, registry: nil)
        #expect(r2.outcome == .aborted(reason: "memory pressure critical"))
    }

    @Test func orphanReaping() async throws {
        let dir = tempDir()
        let reg = ChildRegistry(directory: dir)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        reg.register(pid: p.processIdentifier, executable: "/bin/sleep")
        // A stale entry whose pid now runs something else must be left alone.
        reg.register(pid: getpid(), executable: "/usr/bin/not-us")
        let stopped = reg.reapOrphans()
        #expect(stopped == [p.processIdentifier])
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal)
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).isEmpty)
    }
}

#if os(macOS)
@Suite struct MacProbeTests {
    @Test func probeReportsThisMac() {
        let p = MacHardwareProbe()
        let hw = p.hardware()
        #expect(hw.memoryBytes > 0 && hw.physicalCores > 0)
        #expect(hw.fingerprint == p.hardware().fingerprint)
        #if arch(arm64)
        #expect(!hw.clusters.isEmpty)
        #expect(hw.clusters.reduce(0) { $0 + $1.physicalCores } == hw.physicalCores)
        #expect(hw.gpus.first?.unifiedMemory == true)
        #endif
        let s = p.state()
        let m = try! #require(s.memory)
        #expect(m.totalBytes == hw.memoryBytes)
        #expect(m.availableEstimateBytes <= m.totalBytes)
    }
}
#endif

/// Swap jumps by 2 GiB a fixed time after creation, as when other apps push the Mac into swap mid-run.
final class SwapGrowingProbe: HardwareProbe, @unchecked Sendable {
    let base = FakeProbe()
    let start = Date()
    let after: TimeInterval
    init(after: TimeInterval) { self.after = after }
    func hardware() -> HardwareInfo { base.hw }
    func state() -> SystemState {
        var s = base.st
        if Date().timeIntervalSince(start) > after { s.memory?.swapUsedBytes = 2 << 30 }
        return s
    }
}

@Suite(.serialized) struct GuardReportingTests {
    /// Regression: a process the swap guard killed was reported as "llama-bench produced no results"
    /// with Metal compile chatter, instead of as stopped by the guard (seen on the dev Mac, 2026-11-14).
    @Test func guardStopIsReportedAsSuch() async throws {
        let dir = tempDir()
        let exe = fakeLlamaBench(in: dir, sleepSeconds: 3)
        let adapter = LlamaBenchAdapter(explicitPath: exe.path)
        let inst = try adapter.discover()
        let (url, model) = try tinyModelFile()
        let runner = BenchmarkRunner(adapter: adapter, probe: SwapGrowingProbe(after: 1),
                                     registry: ChildRegistry(directory: dir.appendingPathComponent("children")))
        let plan = BenchmarkPlan(configs: [.runtimeDefaults], rounds: 3, repetitions: 1, seed: 1, cooldownSeconds: 0)
        let report = await runner.run(plan: plan, modelURL: url, model: model, installation: inst)
        #expect(report.status == .partial)
        let last = try #require(report.trials.last)
        #expect(last.error?.hasPrefix("stopped by safety guard: system swap grew") == true)
        #expect(last.error?.contains("no results") == false)
    }

    @Test func errorTailDropsMetalCompileChatter() {
        let err = (0..<40).map { "ggml_metal_library_compile_all: compiled 'x\($0)' library in 0.01 sec" }.joined(separator: "\n")
            + "\nllama_model_load: error loading model: bad magic\n"
        #expect(LlamaBenchAdapter.errorTail(err) == "llama_model_load: error loading model: bad magic")
    }
}

/// Critical memory pressure for the first `seconds` after creation, then normal.
final class PressureSpikeProbe: HardwareProbe, @unchecked Sendable {
    let base = FakeProbe()
    let start = Date()
    let seconds: TimeInterval
    init(criticalFor seconds: TimeInterval) { self.seconds = seconds }
    func hardware() -> HardwareInfo { base.hw }
    func state() -> SystemState {
        var s = base.st
        if Date().timeIntervalSince(start) < seconds { s.memory?.pressure = .critical }
        return s
    }
}

@Suite(.serialized) struct PressureGraceTests {
    /// Regression: loading a 14B model made macOS report critical pressure for a
    /// moment, and the guard stopped the run although pressure recovered (2026-11-14).
    @Test func briefSpikeIsTolerated() async throws {
        var limits = SafetyLimits()
        limits.memoryPressureGraceSeconds = 2
        let g = BenchmarkRunner.makeGuard(probe: PressureSpikeProbe(criticalFor: 0.6), limits: limits, swapAtStart: 0)
        var stops: [String] = []
        for _ in 0..<12 {
            if let r = g() { stops.append(r) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(stops.isEmpty)
    }

    @Test func sustainedPressureStops() async throws {
        var limits = SafetyLimits()
        limits.memoryPressureGraceSeconds = 0.5
        let g = BenchmarkRunner.makeGuard(probe: PressureSpikeProbe(criticalFor: 60), limits: limits, swapAtStart: 0)
        var stop: String?
        for _ in 0..<12 where stop == nil {
            stop = g()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(stop?.hasPrefix("memory pressure critical") == true)
    }
}
