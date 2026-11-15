import Foundation

/// The values worth trying for one setting, always including the runtime default.
public struct SearchDimension: Codable, Sendable, Equatable {
    public var dimension: TuneDimension
    public var defaultValue: String
    /// Default first, then the alternatives.
    public var values: [String]
    /// Why values were left out, for the report.
    public var notes: [String]
}

/// Builds the per-machine, per-model search space. Rules, with the evidence
/// behind them in RESEARCH.md:
/// - Settings the installed build lacks are skipped, never guessed.
/// - `ub` above the prompt size and `b` at or above it change nothing, so they are not tried.
/// - KV quantization changes model output, so it is tried only when the user allows it.
/// - Partial GPU offload is tried only when the model does not fit the GPU working set.
/// - Thread pinning (`-C`, `--cpu-strict`) is never tried on macOS: it cannot pin threads to cores.
public enum SearchSpace {
    public static func build(request: TuneRequest, model: ModelInfo, hardware: HardwareInfo,
                             installation: RuntimeInstallation, adapter: RuntimeAdapter) -> [SearchDimension] {
        let w = request.workload
        var out: [SearchDimension] = []
        for d in request.budget.dimensions {
            guard let def = adapter.defaultValue(d, installation: installation) else { continue }
            var notes: [String] = []
            var alts: [String]
            switch d {
            case .flashAttention:
                alts = ["auto", "on", "off"]
                if let choices = LlamaBenchAdapter.choices(installation.flagUsage["-fa"]) { alts = alts.filter(choices.contains) }
            case .ubatch:
                let candidates = [256, 512, 1024, 2048]
                alts = candidates.filter { $0 <= max(w.promptTokens, 512) }.map(String.init)
                if candidates.count != alts.count {
                    notes.append("micro-batches above the \(w.promptTokens)-token prompt are skipped: they cannot change anything")
                }
            case .batch:
                guard w.promptTokens > 2048 else {
                    notes.append("batch size only matters for prompts over 2048 tokens")
                    alts = []
                    break
                }
                alts = ["2048", "4096"]
            case .threads:
                let perf = hardware.clusters.first?.physicalCores ?? max(1, hardware.physicalCores / 2)
                alts = Set([2, perf, min(perf + 2, hardware.logicalCores), hardware.logicalCores])
                    .filter { $0 >= 1 && $0 <= hardware.logicalCores }.sorted().map(String.init)
            case .poll:
                alts = ["0", "50", "100"]
            case .kvCache:
                guard request.constraints.allowKVQuantization else {
                    notes.append("KV cache quantization changes model output slightly; not tried unless allowed")
                    alts = []
                    break
                }
                alts = ["f16", "q8_0", "q4_0"]
            case .gpuLayers:
                let ws = hardware.gpus.first?.recommendedMaxWorkingSetBytes ?? .max
                guard let layers = model.blockCount, Double(model.weightBytes) > Double(ws) * 0.9 else {
                    notes.append("the model fits the GPU working set, so all layers stay on the GPU")
                    alts = []
                    break
                }
                alts = [layers * 3 / 4, layers / 2].map(String.init)
            }
            var values = [def] + alts.filter { $0 != def }
            // Drop values this build/model rejects outright.
            values = values.filter { v in
                v == def || !adapter.validate(InferenceConfig.runtimeDefaults.setting(d, v), installation: installation,
                                              model: model, hardware: hardware).contains { $0.severity == .error }
            }
            guard values.count >= 2 else {
                if !notes.isEmpty { out.append(SearchDimension(dimension: d, defaultValue: def, values: [def], notes: notes)) }
                continue
            }
            out.append(SearchDimension(dimension: d, defaultValue: def, values: values, notes: notes))
        }
        return out
    }
}
