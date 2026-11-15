import Foundation
import Testing
@testable import ZoomiesKit

@Suite(.serialized) struct TunerTests {
    func setup(flashAttentionHelps: Bool = true) throws -> (Tuner, RuntimeInstallation, URL, ModelInfo) {
        let dir = tempDir()
        let exe = fakeLlamaBench(in: dir, flashAttentionHelps: flashAttentionHelps)
        let adapter = LlamaBenchAdapter(explicitPath: exe.path)
        let inst = try adapter.discover()
        let (url, model) = try tinyModelFile()
        var tuner = Tuner(runner: BenchmarkRunner(adapter: adapter, probe: FakeProbe(),
                                                  registry: ChildRegistry(directory: dir.appendingPathComponent("children"))))
        tuner.cooldownSeconds = 0
        return (tuner, inst, url, model)
    }

    @Test func findsAndVerifiesFlashAttention() async throws {
        let (tuner, inst, url, model) = try setup()
        let req = TuneRequest(objective: .generation, budget: .quick, seed: 42)
        let r = await tuner.tune(request: req, modelURL: url, model: model, installation: inst)
        #expect(r.decision.kind == .improved, "\(r.decision.headline) \(r.decision.details)")
        #expect(r.decision.config.flashAttention == .on)
        #expect(r.decision.primary?.verdict == .faster)
        // With a 512-token prompt, micro-batches above 512 are not even tried.
        let ub = try #require(r.screen.first { $0.dimension == .ubatch })
        #expect(!ub.values.contains { Int($0.value)! > 512 })
        #expect(!ub.values.contains { $0.kept })
        // KV quantization changes output: not tried unless allowed.
        #expect(!r.screen.contains { $0.dimension == .kvCache })
        #expect(r.warnings.contains { $0.contains("KV cache quantization") })
        #expect(r.stages.last?.kind == .verify)
        #expect(r.processCount > 0)
    }

    @Test func keepsDefaultsWhenNothingHelps() async throws {
        let (tuner, inst, url, model) = try setup(flashAttentionHelps: false)
        let r = await tuner.tune(request: TuneRequest(objective: .generation, budget: .quick, seed: 1),
                                 modelURL: url, model: model, installation: inst)
        #expect(r.decision.kind == .keepDefaults, "\(r.decision.headline)")
        #expect(r.decision.config == .runtimeDefaults)
        #expect(r.decision.headline.contains("already the fastest"))
    }

    @Test func responseObjectiveCombinesSettings() async throws {
        let (tuner, inst, url, model) = try setup()
        let req = TuneRequest(objective: .response, budget: .standard, seed: 7)  // 2048-token prompt
        let r = await tuner.tune(request: req, modelURL: url, model: model, installation: inst)
        #expect(r.decision.kind == .improved, "\(r.decision.headline) \(r.decision.details)")
        #expect(r.decision.config.flashAttention == .on)
        #expect((r.decision.config.ubatchSize ?? 0) >= 1024)
        // Threads and poll change nothing in the fake, so they must not be in the winner.
        #expect(r.decision.config.threads == nil && r.decision.config.poll == nil)
    }

    @Test func kvQuantizationOnlyWhenAllowed() async throws {
        let (tuner, inst, url, model) = try setup()
        var req = TuneRequest(objective: .generation, budget: .quick, seed: 3)
        req.constraints.allowKVQuantization = true
        let r = await tuner.tune(request: req, modelURL: url, model: model, installation: inst)
        let kv = try #require(r.screen.first { $0.dimension == .kvCache })
        #expect(kv.values.map(\.value).sorted() == ["f16", "q4_0", "q8_0"])
        #expect(!kv.values.contains { $0.kept })  // they cost speed, so a speed objective drops them
    }

    @Test func blockedStartChangesNothing() async throws {
        var (tuner, inst, url, model) = try setup()
        var p = FakeProbe()
        p.st.power.source = .battery
        tuner.runner.probe = p
        let r = await tuner.tune(request: TuneRequest(budget: .quick), modelURL: url, model: model, installation: inst)
        #expect(r.decision.kind == .incomplete && r.processCount == 0)
        #expect(r.decision.headline.contains("battery"))
    }

    @Test func storeKeepsTunesProfilesAndRollsBack() async throws {
        let (tuner, inst, url, model) = try setup()
        let r = await tuner.tune(request: TuneRequest(objective: .generation, budget: .quick, seed: 42),
                                 modelURL: url, model: model, installation: inst)
        let store = try ResultStore(url: tempDir().appendingPathComponent("t.sqlite"))
        try store.save(r)
        #expect(try store.recentTunes().first?.decision == "improved")
        #expect(try store.tune(id: r.id.uuidString)?.decision.config == r.decision.config)

        let prof = TuningProfile.from(r, modelURL: url)
        try store.save(prof)
        let (m, h) = (prof.modelFingerprint, prof.hardwareFingerprint)
        #expect(try store.activeProfile(modelFingerprint: m, hardwareFingerprint: h) == nil)  // defaults until applied
        try store.activate(prof.id, modelFingerprint: m, hardwareFingerprint: h)
        #expect(try store.activeProfile(modelFingerprint: m, hardwareFingerprint: h)?.id == prof.id)
        #expect(try store.rollback(modelFingerprint: m, hardwareFingerprint: h) == nil)  // back to defaults
        #expect(try store.activeProfile(modelFingerprint: m, hardwareFingerprint: h) == nil)
        #expect(try store.rollback(modelFingerprint: m, hardwareFingerprint: h)?.id == prof.id)  // and forward again
    }
}

@Suite struct TuneSupportTests {
    func installation() throws -> RuntimeInstallation {
        let help = try String(contentsOf: fixture("llama-bench-b12359-help.txt"), encoding: .utf8)
        return LlamaBenchAdapter.installation(executable: "/opt/homebrew/bin/llama-bench", versionText: "version: 1.0.0 (build 12359, commit b1b770d90)",
                                              helpText: help, devicesText: "")
    }

    @Test func defaultsComeFromTheBuildsHelp() throws {
        let inst = try installation(), a = LlamaBenchAdapter()
        #expect(a.defaultValue(.flashAttention, installation: inst) == "auto")
        #expect(a.defaultValue(.ubatch, installation: inst) == "512")
        #expect(a.defaultValue(.threads, installation: inst) == "4")
        #expect(a.defaultValue(.poll, installation: inst) == "50")
        #expect(a.defaultValue(.kvCache, installation: inst) == "f16")
        #expect(a.defaultValue(.gpuLayers, installation: inst) == "-1")
    }

    @Test func sweepCommandAndAttribution() throws {
        let inst = try installation(), a = LlamaBenchAdapter()
        let cmd = try #require(a.sweepCommand(model: URL(fileURLWithPath: "/m.gguf"), dimension: .kvCache, values: ["f16", "q8_0"],
                                              workload: Workload(), repetitions: 2, installation: inst))
        #expect(cmd.suffix(4) == ["-ctk", "f16,q8_0", "-ctv", "f16,q8_0"])
        // Attribution uses the effective settings in real b12359 JSONL.
        let out = try String(contentsOf: fixture("real-b12359-m5-qwen1.5b.jsonl"), encoding: .utf8)
        let m = try a.parseBenchmarkOutput(stdout: out, stderr: "")
        #expect(a.effectiveValue(.flashAttention, of: m[0]) == "auto")
        #expect(a.effectiveValue(.ubatch, of: m[0]) == "512")
        #expect(a.effectiveValue(.threads, of: m[0]) == "4")
        #expect(a.effectiveValue(.kvCache, of: m[0]) == "f16")
    }

    @Test func searchSpaceRespectsWorkloadAndHardware() throws {
        let inst = try installation(), a = LlamaBenchAdapter()
        let (_, model) = try tinyModelFile()
        let space = SearchSpace.build(request: TuneRequest(objective: .response, budget: .thorough), model: model,
                                      hardware: FakeProbe().hw, installation: inst, adapter: a)
        let ub = try #require(space.first { $0.dimension == .ubatch })
        #expect(ub.values == ["512", "256", "1024", "2048"])
        let t = try #require(space.first { $0.dimension == .threads })
        #expect(t.values.first == "4" && t.values.allSatisfy { Int($0)! <= 10 })
        // A tiny model fits the GPU: partial offload is never searched.
        #expect(space.first { $0.dimension == .gpuLayers }?.values.count ?? 1 == 1)
    }

    @Test func serverCommandPinsDefaultsThatDiffer() throws {
        let inst = try installation()
        let args = ServerCommand.arguments(config: try .parse("fa=on,ub=1024"), modelPath: "/m/a b.gguf", installation: inst, contextTokens: 8192)
        #expect(args.dropFirst() == ["-m", "/m/a b.gguf", "-t", "4", "-ngl", "all", "-ub", "1024", "-fa", "on", "-c", "8192"])
        #expect(ServerCommand.shellLine(["llama-server", "-m", "/m/a b.gguf"]) == "llama-server -m '/m/a b.gguf'")
    }

    @Test func pairedRatioVerdicts() {
        #expect(Comparison.pairedRatio([1.10, 1.09, 1.11, 1.10]).verdict == .faster)
        #expect(Comparison.pairedRatio([1.01, 0.99, 1.00, 1.02]).verdict == .noDetectableDifference)
        #expect(Comparison.pairedRatio([0.90, 0.91, 0.89]).verdict == .slower)
        #expect(Comparison.pairedRatio([1.2]).verdict == .insufficientData)
        let c = Comparison.pairedRatio([1.10, 1.10, 1.10])
        #expect(abs(c.relativePercent - 10) < 0.01)
    }
}

/// Swap jumps by 2 GiB once the flag file exists (the fake llama-bench creates it
/// when it reaches ub=2048), like a big compute buffer pushing a 16 GB Mac into swap.
final class FlagSwapProbe: HardwareProbe, @unchecked Sendable {
    let base = FakeProbe()
    let flag: URL
    init(flag: URL) { self.flag = flag }
    func hardware() -> HardwareInfo { base.hw }
    func state() -> SystemState {
        var s = base.st
        if FileManager.default.fileExists(atPath: flag.path) { s.memory?.swapUsedBytes = 2 << 30 }
        return s
    }
}

@Suite(.serialized) struct TunerMemoryTests {
    /// Regression: on the 16 GB M5, ub=2048 for Qwen3-14B pushed the Mac into swap and
    /// the guard ended the whole tune. Now that value is skipped and the tune goes on.
    @Test func valueThatDoesNotFitIsSkipped() async throws {
        let dir = tempDir()
        let flag = dir.appendingPathComponent("hog")
        let exe = fakeLlamaBench(in: dir, memoryHogFlag: flag)
        let adapter = LlamaBenchAdapter(explicitPath: exe.path)
        let inst = try adapter.discover()
        let (url, model) = try tinyModelFile()
        var tuner = Tuner(runner: BenchmarkRunner(adapter: adapter, probe: FlagSwapProbe(flag: flag),
                                                  registry: ChildRegistry(directory: dir.appendingPathComponent("children"))))
        tuner.cooldownSeconds = 0
        let r = await tuner.tune(request: TuneRequest(objective: .response, budget: .quick, seed: 9),
                                 modelURL: url, model: model, installation: inst)
        let ub = try #require(r.screen.first { $0.dimension == .ubatch })
        #expect(ub.note?.contains("did not fit in memory") == true, "\(ub.note ?? "no note")")
        #expect(ub.values.first { $0.value == "2048" }?.relativeScore == nil)
        #expect(ub.values.first { $0.value == "1024" }?.relativeScore != nil)  // measured before the stop
        #expect(r.decision.kind != .incomplete, "\(r.decision.headline)")
        #expect(r.decision.config.ubatchSize != 2048)
    }
}

@Suite struct ServerPathTests {
    /// Regression: exports pointed at …/Cellar/llama.cpp/1.0.0/bin/llama-server, which
    /// disappears on `brew upgrade`. The stable …/bin link must be used instead.
    @Test func prefersTheStableHomebrewLink() throws {
        let fm = FileManager.default
        let prefix = tempDir()
        let cellarBin = prefix.appendingPathComponent("Cellar/llama.cpp/1.0.0/bin")
        let bin = prefix.appendingPathComponent("bin")
        try fm.createDirectory(at: cellarBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["llama-bench", "llama-server"] {
            let real = cellarBin.appendingPathComponent(tool)
            try "#!/bin/sh\n".write(to: real, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
            try fm.createSymbolicLink(atPath: bin.appendingPathComponent(tool).path,
                                      withDestinationPath: "../Cellar/llama.cpp/1.0.0/bin/\(tool)")
        }
        let bench = cellarBin.appendingPathComponent("llama-bench").path  // what discovery records (resolved)
        #expect(ServerCommand.executable(near: bench, searchPath: "") == bin.appendingPathComponent("llama-server").path)
        // Without a stable link that points at the same binary, fall back to the sibling.
        try fm.removeItem(at: bin.appendingPathComponent("llama-server"))
        #expect(ServerCommand.executable(near: bench, searchPath: "") == cellarBin.appendingPathComponent("llama-server").path)
    }

    @Test func profilesFromAnotherBuildAreStale() {
        var p = TuningProfile(name: "x", modelPath: "/m.gguf", modelName: "m", modelFingerprint: "f", hardwareFingerprint: "h",
                              runtimeBuild: 12359, objective: .response, config: InferenceConfig(ubatchSize: 256),
                              headline: "", tuneRunID: nil, contextTokens: 0)
        var inst = RuntimeInstallation(runtimeID: "llama.cpp", executable: "/x", version: nil, buildNumber: 12359, commit: nil,
                                       flags: [], flagUsage: [:], devices: [])
        #expect(!p.isStale(for: inst))
        inst.buildNumber = 12400
        #expect(p.isStale(for: inst))
        p.runtimeBuild = nil
        #expect(!p.isStale(for: inst))  // unknown build: don't cry wolf
    }
}
