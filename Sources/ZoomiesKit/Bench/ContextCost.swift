import Foundation

/// What context costs on this machine: how long reading 1,000 more prompt
/// tokens takes, and how fast replies stream, as the conversation grows.
/// Useful by itself (local agents re-read files constantly) and as the
/// baseline for any context-reduction feature.
public struct ContextCostPoint: Codable, Sendable, Equatable {
    /// Tokens already in the context.
    public var depth: Int
    public var promptTPS: Double?
    public var generationTPS: Double?
    /// Seconds to process 1,000 prompt tokens at this depth (1000 / promptTPS).
    public var secondsPer1kPromptTokens: Double? { promptTPS.map { 1000 / $0 } }
    /// Milliseconds per generated token at this depth.
    public var msPerGeneratedToken: Double? { generationTPS.map { 1000 / $0 } }
}

public struct ContextCostReport: Codable, Sendable {
    public var model: ModelInfo
    public var installation: RuntimeInstallation
    public var points: [ContextCostPoint]
    public var trial: Trial
    public var measuredAt: Date
}

public enum ContextCost {
    /// Depths worth measuring for this model: within its trained context and
    /// with the KV cache comfortably inside memory.
    public static func depths(for model: ModelInfo, memoryBytes: UInt64) -> [Int] {
        let ctx = model.trainedContextLength ?? 8192
        return [0, 4096, 16384, 32768].filter { d in
            guard d < ctx else { return false }
            let kv = model.kvCacheBytesEstimate(contextTokens: d + 1024) ?? 0
            return model.weightBytes + kv < memoryBytes * 70 / 100
        }
    }

    /// One llama-bench process measuring pp1024 and tg64 at each depth.
    public static func measure(runner: BenchmarkRunner, modelURL: URL, model: ModelInfo, installation: RuntimeInstallation,
                               depths: [Int], repetitions: Int = 2, limits: SafetyLimits = SafetyLimits()) async -> ContextCostReport {
        var cmd = runner.adapter.benchmarkCommand(model: modelURL, config: .runtimeDefaults,
                                                  workload: Workload(promptTokens: 1024, genTokens: 64, depth: 0),
                                                  repetitions: repetitions, installation: installation)
        cmd += ["-d", depths.map(String.init).joined(separator: ",")]
        let guardCheck = BenchmarkRunner.makeGuard(probe: runner.probe, limits: limits,
                                                   swapAtStart: runner.probe.state().memory?.swapUsedBytes)
        let trial = await runner.execute(cmd, sequence: 0, round: 0, configIndex: 0, limits: limits, guardCheck: guardCheck)
        let points = depths.map { d -> ContextCostPoint in
            let at = trial.measurements.filter { $0.depth == d }
            return ContextCostPoint(depth: d,
                                    promptTPS: at.first { $0.kind == .promptProcessing }.map { Stats.mean($0.samplesTPS) },
                                    generationTPS: at.first { $0.kind == .generation }.map { Stats.mean($0.samplesTPS) })
        }
        return ContextCostReport(model: model, installation: installation, points: points, trial: trial, measuredAt: Date())
    }
}
