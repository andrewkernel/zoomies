import Foundation
import Testing
@testable import ZoomiesKit

@Suite struct GGUFTests {
    @Test func parsesMetadataAndTensors() throws {
        let g = try GGUFFile.parse(GGUFBuilder.tinyLlama().build())
        #expect(g.version == 3)
        #expect(g.metadata["general.architecture"] == .string("llama"))
        #expect(g.tensors.count == 3)
        #expect(g.tensors[1].typeName == "Q4_K")
        #expect(g.tensors[1].byteSize == 256 * 64 / 256 * 144)
        // The 1000-entry vocabulary is skipped, not stored.
        if case .array(_, let count, let values) = g.metadata["tokenizer.ggml.tokens"]! {
            #expect(count == 1000 && values == nil)
        } else { Issue.record("expected array") }
        #expect(g.dataOffset % 32 == 0)
    }

    @Test func modelSummary() throws {
        let (_, m) = try tinyModelFile()
        #expect(m.architecture == "llama")
        #expect(m.quantization == "Q4_K_M")
        #expect(m.blockCount == 2 && m.headCount == 8 && m.headCountKV == 2)
        #expect(m.parameterCount == 64 * 1000 + 256 * 64 * 2)
        #expect(m.tensorTypeBytes["F32"] == 64 * 1000 * 4)
        #expect(m.quickFingerprint.count == 32)
        // 2 layers x 2 kv heads x (8 + 8) dims x 2 bytes = 128 bytes per token.
        #expect(m.kvCacheBytesEstimate(contextTokens: 1000) == 128_000)
        // q8_0 K and V: 34/32 bytes per element.
        #expect(m.kvCacheBytesEstimate(contextTokens: 1000, typeK: "q8_0", typeV: "q8_0") == 68_000)
    }

    @Test func perLayerKVHeadArrayUsesLargest() throws {
        var b = GGUFBuilder.tinyLlama()
        b.kv.removeAll { $0.0 == "llama.attention.head_count_kv" }
        b.i32Array("llama.attention.head_count_kv", [2, 4])
        let url = tempDir().appendingPathComponent("m.gguf")
        try b.build().write(to: url)
        #expect(try ModelInspector.inspect(url).headCountKV == 4)
    }

    @Test func rejectsBadFiles() {
        #expect(throws: GGUFError.notGGUF) { try GGUFFile.parse(Data("NOPE1234".utf8)) }
        #expect(throws: GGUFError.self) { try GGUFFile.parse(GGUFBuilder.tinyLlama().build().prefix(40)) }
        #expect(throws: GGUFError.self) { try GGUFFile.parse(GGUFBuilder.tinyLlama().build(truncateData: true)) }
        var v9 = Data("GGUF".utf8) + GGUFBuilder.le(UInt32(9))
        v9 += Data(count: 16)
        #expect(throws: GGUFError.unsupportedVersion(9)) { try GGUFFile.parse(v9) }
    }
}

@Suite struct StatsTests {
    @Test func basics() {
        let x = [2.0, 4, 4, 4, 5, 5, 7, 9]
        #expect(Stats.mean(x) == 5)
        #expect(abs(Stats.stddev(x) - 2.138) < 0.001)
        #expect(Stats.median(x) == 4.5)
        #expect(Stats.mad([1, 1, 2, 2, 4, 6, 9]) == 1)
    }

    @Test func confidenceInterval() {
        // n=3, mean 10, s=1 -> half width 4.303 / sqrt(3) = 2.484
        let s = Stats.summarize([9, 10, 11])
        #expect(abs((s.ciHigh - s.ciLow) / 2 - 2.484) < 0.001)
        #expect(Stats.summarize([5]).ciHigh == .infinity)
        #expect(Stats.t95(df: 2.7) == 4.303)
        #expect(Stats.t95(df: 1000) == 1.980)
    }

    @Test func outliersAreFlagged() {
        #expect(Stats.outlierIndices([50, 51, 50, 49, 50, 20]) == [5])
        #expect(Stats.outlierIndices([50, 50, 50]) == [])
    }

    /// Real pp512 round means from the first noise-floor run (M5, Qwen2.5-1.5B Q4_K_M, b12359, seed 1).
    /// Round 7 was disturbed; rounds 9–10 were merely slower and must not be flagged.
    @Test func disturbedRoundIsFlaggedOnRealData() {
        let pp = [3207.0, 3238.7, 3215.1, 3217.2, 3145.7, 3214.7, 2321.8, 3100.0, 3034.0, 3051.0]
        #expect(Stats.outlierIndices(pp) == [6])
    }

    @Test func welchVerdicts() {
        let base = [100.0, 101, 99, 100]
        #expect(Comparison.welch(baseline: base, candidate: [110, 111, 109, 110]).verdict == .faster)
        #expect(Comparison.welch(baseline: base, candidate: [90, 91, 89, 90]).verdict == .slower)
        #expect(Comparison.welch(baseline: base, candidate: [100.5, 99.5, 101, 100]).verdict == .noDetectableDifference)
        // Statistically real but below the 2% relevance threshold.
        #expect(Comparison.welch(baseline: [100, 100.1, 99.9], candidate: [101, 101.1, 100.9]).verdict == .noDetectableDifference)
        #expect(Comparison.welch(baseline: [100], candidate: [120, 121]).verdict == .insufficientData)
        let c = Comparison.welch(baseline: base, candidate: [110, 111, 109, 110])
        #expect(abs(c.relativePercent - 10) < 0.001)
    }
}

@Suite struct ConfigTests {
    @Test func parseAndLabel() throws {
        let c = try InferenceConfig.parse("ngl=99,t=4 fa=on ub=1024 ctk=q8_0 lm=mmap")
        #expect(c.gpuLayers == 99 && c.threads == 4 && c.flashAttention == .on && c.ubatchSize == 1024)
        #expect(c.cacheTypeK == "q8_0" && c.loadMode == "mmap")
        #expect(c.label == "ngl=99 t=4 ub=1024 fa=on ctk=q8_0 lm=mmap")
        #expect(try InferenceConfig.parse("defaults") == .runtimeDefaults)
        #expect(InferenceConfig.runtimeDefaults.label == "defaults")
    }

    @Test func parseErrors() {
        #expect(throws: ConfigError.unknownKey("mmp")) { try InferenceConfig.parse("mmp=1") }
        #expect(throws: ConfigError.badValue(key: "t", value: "x")) { try InferenceConfig.parse("t=x") }
        #expect(throws: ConfigError.malformed("ngl")) { try InferenceConfig.parse("ngl") }
        #expect(throws: ConfigError.badValue(key: "fa", value: "maybe")) { try InferenceConfig.parse("fa=maybe") }
    }
}

@Suite struct LlamaBenchTests {
    func installation() throws -> RuntimeInstallation {
        let help = try String(contentsOf: fixture("llama-bench-b11347-help.txt"), encoding: .utf8)
        return LlamaBenchAdapter.installation(executable: "/x/llama-bench", versionText: "version: 7100 (abc1234)\n",
                                              helpText: help, devicesText: "Available devices:\n  MTL0: Apple M5 (12124 MiB, 12124 MiB free)\n")
    }

    @Test func versionFormats() {
        let a = LlamaBenchAdapter.parseVersion("load_backend: x\nversion: 0.5.0-dev (build 11347, commit 5fc4f3c8c)\nbuilt with Clang")
        #expect(a.1 == 11347 && a.2 == "5fc4f3c8c")
        let b = LlamaBenchAdapter.parseVersion("version: 7100 (abc1234)")
        #expect(b.1 == 7100 && b.2 == "abc1234")
        #expect(LlamaBenchAdapter.parseVersion("garbage").1 == nil)
    }

    @Test func helpFlags() throws {
        let inst = try installation()
        for f in ["-ngl", "-fa", "--flash-attn", "-lm", "--load-mode", "-ub", "-ctk", "--poll", "--no-warmup", "-d"] {
            #expect(inst.flags.contains(f), "missing \(f)")
        }
        #expect(!inst.flags.contains("-mmp"))
        #expect(inst.flagUsage["-fa"]?.contains("auto") == true)
        #expect(inst.devices == ["MTL0: Apple M5 (12124 MiB, 12124 MiB free)"])
    }

    /// Real `--help` from Homebrew llama.cpp 1.0.0 (build 12359) on an M5. Backend log lines are mixed in, as in real use.
    @Test func realHelpB12359() throws {
        let help = try String(contentsOf: fixture("llama-bench-b12359-help.txt"), encoding: .utf8)
        let inst = LlamaBenchAdapter.installation(executable: "/x/llama-bench", versionText: "version: 1.0.0 (build 12359, commit b1b770d90)",
                                                  helpText: help, devicesText: "")
        for f in ["-ngl", "-fa", "-lm", "-ub", "-ctk", "-ctv", "--poll", "-d", "-lzm", "--repack", "-fitt"] {
            #expect(inst.flags.contains(f), "missing \(f)")
        }
        #expect(!inst.flags.contains("--rpc"))  // this Homebrew build has no RPC backend
        #expect(LlamaBenchAdapter.choices(inst.flagUsage["-lm"]) == ["auto", "none", "mmap", "mlock", "mmap+mlock", "dio"])
        let a = LlamaBenchAdapter(), hw = FakeProbe().hw
        #expect(a.validate(try .parse("lm=dio,fa=auto"), installation: inst, model: nil, hardware: hw).isEmpty)
        // Substrings of a valid choice are not valid choices.
        #expect(a.validate(try .parse("lm=map"), installation: inst, model: nil, hardware: hw).contains { $0.field == "loadMode" })
    }

    /// Real output of `llama-bench -r 2 -o jsonl -p 512 -n 128` (b12359, M5, Qwen2.5-1.5B Q4_K_M; model path anonymized).
    @Test func realJSONLAndStderrB12359() throws {
        let out = try String(contentsOf: fixture("real-b12359-m5-qwen1.5b.jsonl"), encoding: .utf8)
        let err = try String(contentsOf: fixture("real-b12359-m5-qwen1.5b.stderr.txt"), encoding: .utf8)
        let m = try LlamaBenchAdapter().parseBenchmarkOutput(stdout: out, stderr: err)
        #expect(m.count == 2)
        #expect(m[0].kind == .promptProcessing && m[0].tokens == 512 && m[0].samplesTPS.count == 2)
        #expect(m[1].kind == .generation && m[1].tokens == 128 && m[1].samplesTPS.count == 2)
        #expect(m.allSatisfy { $0.samplesTPS.allSatisfy { $0 > 0 } && $0.runtimeFields["build_number"] == "12359" })
        let facts = LlamaBenchAdapter.backendFacts(err)
        #expect(facts["metal.has_tensor"] == "true")
        #expect(facts["cpu_backend_variant"] == "apple_m4")
        #expect(facts["metal.gpu_families"] == "Apple10,Metal4")
        #expect(LlamaBenchAdapter.notableLogLines(err).contains { $0.contains("has tensor") })
    }

    @Test func jsonlParsing() throws {
        let out = """
        ggml_init: hello
        {"n_prompt": 512, "n_gen": 0, "n_depth": 0, "avg_ts": 1000.0, "samples_ts": [990.0, 1000.0, 1010.0], "build_number": 7100}
        not json
        {"unrelated": true}
        {"n_prompt": 0, "n_gen": 128, "n_depth": 4096, "avg_ts": 42.5}
        {"n_prompt": 512, "n_gen": 128, "avg_ts": 30}
        """
        let m = try LlamaBenchAdapter().parseBenchmarkOutput(stdout: out, stderr: "")
        #expect(m.count == 3)
        #expect(m[0].kind == .promptProcessing && m[0].samplesTPS == [990, 1000, 1010] && m[0].runtimeFields["build_number"] == "7100")
        #expect(m[1].kind == .generation && m[1].depth == 4096 && m[1].samplesTPS == [42.5])
        #expect(m[2].kind == .generation)  // combined pp+tg counts as generation
        #expect(throws: LlamaBenchError.self) { try LlamaBenchAdapter().parseBenchmarkOutput(stdout: "error", stderr: "boom") }
    }

    @Test func validation() throws {
        let inst = try installation()
        let a = LlamaBenchAdapter()
        let hw = FakeProbe().hw
        let (_, model) = try tinyModelFile()
        #expect(a.validate(try .parse("ngl=99,t=4,fa=on,ub=512,ctk=q8_0,ctv=q8_0,lm=mmap"), installation: inst, model: model, hardware: hw).isEmpty)
        let bad = a.validate(try .parse("fa=off,ctv=q4_0,t=0,lm=floppy"), installation: inst, model: model, hardware: hw)
        #expect(bad.contains { $0.field == "cacheTypeV" && $0.severity == .error })
        #expect(bad.contains { $0.field == "threads" && $0.severity == .error })
        #expect(bad.contains { $0.field == "loadMode" && $0.severity == .error })
        #expect(a.validate(try .parse("ctk=q3_k"), installation: inst, model: model, hardware: hw).contains { $0.severity == .error })
        // Partial offload on unified memory: allowed, but warned about.
        let partial = a.validate(try .parse("ngl=1"), installation: inst, model: model, hardware: hw)
        #expect(partial.count == 1 && partial[0].severity == .warning)
        // A build without -lm (older llama.cpp) rejects load-mode configs.
        var old = inst
        old.flags.remove("-lm")
        #expect(a.validate(try .parse("lm=mmap"), installation: old, model: model, hardware: hw).contains { $0.severity == .error })
    }

    @Test func commandLine() throws {
        let inst = try installation()
        let cmd = LlamaBenchAdapter().benchmarkCommand(model: URL(fileURLWithPath: "/m/a b.gguf"), config: try .parse("ngl=99,fa=on,lm=mmap"),
                                                       workload: Workload(promptTokens: 256, genTokens: 64, depth: 1024),
                                                       repetitions: 4, installation: inst)
        #expect(cmd == ["/x/llama-bench", "-m", "/m/a b.gguf", "-r", "4", "-o", "jsonl", "-p", "256", "-n", "64", "-d", "1024",
                        "-ngl", "99", "-fa", "on", "-lm", "mmap"])
        let d = LlamaBenchAdapter().benchmarkCommand(model: URL(fileURLWithPath: "/m.gguf"), config: .runtimeDefaults,
                                                     workload: Workload(), repetitions: 3, installation: inst)
        #expect(!d.contains("-ngl") && !d.contains("-d"))
    }

    @Test func environmentIsSanitized() {
        let env = ChildProcess.sanitizedEnvironment(["PATH": "/bin", "LLAMA_ARG_N_GPU_LAYERS": "0", "HOME": "/h"])
        #expect(env == ["PATH": "/bin", "HOME": "/h"])
    }
}

@Suite struct PlanTests {
    @Test func scheduleIsSeededAndBalanced() {
        let configs = [InferenceConfig(), InferenceConfig(threads: 2), InferenceConfig(threads: 3)]
        let p = BenchmarkPlan(configs: configs, rounds: 4, seed: 42)
        let s = p.schedule()
        #expect(s.count == 12)
        for r in 0..<4 { #expect(Set(s.filter { $0.round == r }.map(\.config)) == [0, 1, 2]) }
        #expect(s.map(\.config) == BenchmarkPlan(configs: configs, rounds: 4, seed: 42).schedule().map(\.config))
        let other = BenchmarkPlan(configs: configs, rounds: 4, seed: 43).schedule().map(\.config)
        #expect(s.map(\.config) != other)
    }

    @Test func preflightBlocksUnsafeStarts() throws {
        let (_, model) = try tinyModelFile()
        var probe = FakeProbe()
        let plan = BenchmarkPlan(configs: [.runtimeDefaults])
        #expect(BenchmarkRunner.preflight(plan: plan, model: model, hardware: probe.hw, state: probe.st).filter(\.blocking).isEmpty)

        probe.st.power = PowerState(source: .battery, batteryPercent: 80, isCharging: false, lowPowerMode: false)
        #expect(BenchmarkRunner.preflight(plan: plan, model: model, hardware: probe.hw, state: probe.st).contains { $0.blocking })
        var allowed = plan
        allowed.limits.allowBattery = true
        #expect(!BenchmarkRunner.preflight(plan: allowed, model: model, hardware: probe.hw, state: probe.st).contains { $0.blocking })
        probe.st.power.batteryPercent = 10
        #expect(BenchmarkRunner.preflight(plan: allowed, model: model, hardware: probe.hw, state: probe.st).contains { $0.blocking })

        probe = FakeProbe()
        probe.st.thermal = .serious
        #expect(BenchmarkRunner.preflight(plan: plan, model: model, hardware: probe.hw, state: probe.st).contains { $0.blocking })

        probe = FakeProbe()
        var huge = model
        huge.weightBytes = 15 << 30
        #expect(BenchmarkRunner.preflight(plan: plan, model: huge, hardware: probe.hw, state: probe.st).contains { $0.blocking })
    }
}
