import Foundation

/// What "faster" means for this user. Every objective is checked against the
/// runtime's defaults with fresh measurements before anything is recommended.
public enum TuneObjective: String, Codable, CaseIterable, Sendable {
    /// Fastest token generation: how quickly replies stream out.
    case generation
    /// Fastest prompt ingestion: shortest wait before the first token.
    case response
    /// Both, weighted equally (geometric mean of the two speed ratios).
    case balanced
    /// Smallest memory use that keeps generation within the guardrail.
    case memory

    public var title: String {
        switch self {
        case .generation: "Fastest replies"
        case .response: "Fastest first token"
        case .balanced: "Balanced"
        case .memory: "Least memory"
        }
    }

    public var summary: String {
        switch self {
        case .generation: "Maximise generation speed (tokens/s while streaming)."
        case .response: "Maximise prompt processing, so long prompts start answering sooner."
        case .balanced: "Improve prompt and generation speed together."
        case .memory: "Cut memory use while keeping generation speed."
        }
    }
}

/// How much measuring the user will pay for. More time means more rounds,
/// narrower confidence intervals and smaller detectable gains.
public enum TuneBudget: String, Codable, CaseIterable, Sendable {
    case quick, standard, thorough

    public var title: String { rawValue.capitalized }

    /// llama-bench repetitions per process.
    public var repetitions: Int { switch self { case .quick: 2; case .standard: 3; case .thorough: 4 } }
    /// Rounds per narrowing stage; each stage halves the field.
    public var narrowingRounds: [Int] { switch self { case .quick: [2]; case .standard: [2, 3]; case .thorough: [3, 4] } }
    /// Fresh rounds for the final defaults-vs-winner check.
    public var validationRounds: Int { switch self { case .quick: 4; case .standard: 6; case .thorough: 10 } }
    public var maxCandidates: Int { switch self { case .quick: 3; case .standard: 5; case .thorough: 8 } }

    public var dimensions: [TuneDimension] {
        switch self {
        case .quick: [.flashAttention, .ubatch, .kvCache]
        case .standard: [.flashAttention, .ubatch, .kvCache, .threads, .poll]
        case .thorough: [.flashAttention, .ubatch, .batch, .kvCache, .threads, .poll, .gpuLayers]
        }
    }
}

/// One setting the tuner may change. Values are strings in llama.cpp's own
/// spelling ("on", "1024", "q8_0") so they render directly into commands.
public enum TuneDimension: String, Codable, CaseIterable, Sendable, Hashable {
    case flashAttention = "fa"
    case ubatch = "ub"
    case batch = "b"
    case threads = "t"
    case poll = "poll"
    /// K and V cache type together (same type for both).
    case kvCache = "kv"
    case gpuLayers = "ngl"

    public var title: String {
        switch self {
        case .flashAttention: "Flash attention"
        case .ubatch: "Micro-batch"
        case .batch: "Batch"
        case .threads: "CPU threads"
        case .poll: "Polling"
        case .kvCache: "KV cache type"
        case .gpuLayers: "GPU layers"
        }
    }

    /// True when a non-default value changes model output (not just speed).
    public var affectsQuality: Bool { self == .kvCache }
}

extension InferenceConfig {
    /// The value this config sets for `d`, or nil when it leaves the runtime default.
    public func value(_ d: TuneDimension) -> String? {
        switch d {
        case .flashAttention: flashAttention?.rawValue
        case .ubatch: ubatchSize.map(String.init)
        case .batch: batchSize.map(String.init)
        case .threads: threads.map(String.init)
        case .poll: poll.map(String.init)
        case .kvCache: cacheTypeK == cacheTypeV ? cacheTypeK : cacheTypeK.map { "\($0)/\(cacheTypeV ?? "f16")" }
        case .gpuLayers: gpuLayers.map(String.init)
        }
    }

    /// A copy with `d` set to `value` (nil restores the runtime default).
    public func setting(_ d: TuneDimension, _ value: String?) -> InferenceConfig {
        var c = self
        switch d {
        case .flashAttention: c.flashAttention = value.flatMap(Toggle.init(rawValue:))
        case .ubatch: c.ubatchSize = value.flatMap { Int($0) }
        case .batch: c.batchSize = value.flatMap { Int($0) }
        case .threads: c.threads = value.flatMap { Int($0) }
        case .poll: c.poll = value.flatMap { Int($0) }
        case .kvCache: c.cacheTypeK = value; c.cacheTypeV = value
        case .gpuLayers: c.gpuLayers = value.flatMap { Int($0) }
        }
        return c
    }

    /// Settings changed relative to the runtime defaults.
    public var changedDimensions: [TuneDimension] { TuneDimension.allCases.filter { value($0) != nil } }
}

public struct TuneConstraints: Codable, Sendable, Equatable {
    /// Tokens already in the conversation when measuring (llama-bench `-d`).
    /// Speed at depth is what long chats feel like; 0 measures an empty context.
    public var contextTokens: Int
    /// Prompt size for the response and balanced objectives.
    public var promptTokens: Int?
    /// Quantized KV caches save memory but change model output slightly.
    /// Off unless the user opts in; never changed silently.
    public var allowKVQuantization: Bool
    /// The secondary metric (e.g. prompt speed when tuning generation) may not
    /// get significantly slower than this many percent.
    public var guardrailPercent: Double
    /// Whole-tune time budget in seconds; stages are shortened to fit.
    public var maxSeconds: Double?
    public var limits: SafetyLimits

    public init(contextTokens: Int = 0, promptTokens: Int? = nil, allowKVQuantization: Bool = false,
                guardrailPercent: Double = 5, maxSeconds: Double? = nil, limits: SafetyLimits = SafetyLimits()) {
        self.contextTokens = contextTokens
        self.promptTokens = promptTokens
        self.allowKVQuantization = allowKVQuantization
        self.guardrailPercent = guardrailPercent
        self.maxSeconds = maxSeconds
        self.limits = limits
    }
}

public struct TuneRequest: Codable, Sendable {
    public var objective: TuneObjective
    public var budget: TuneBudget
    public var constraints: TuneConstraints
    public var seed: UInt64

    public init(objective: TuneObjective = .generation, budget: TuneBudget = .standard,
                constraints: TuneConstraints = TuneConstraints(), seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.objective = objective
        self.budget = budget
        self.constraints = constraints
        self.seed = seed
    }

    /// The benchmark shape for this objective.
    public var workload: Workload {
        let d = constraints.contextTokens
        switch objective {
        case .generation: return Workload(promptTokens: 512, genTokens: 128, depth: d)
        case .response: return Workload(promptTokens: constraints.promptTokens ?? 2048, genTokens: 32, depth: d)
        case .balanced: return Workload(promptTokens: constraints.promptTokens ?? 1024, genTokens: 128, depth: d)
        // KV savings only show with something in the cache.
        case .memory: return Workload(promptTokens: 512, genTokens: 128, depth: max(d, 4096))
        }
    }
}

// MARK: Results

public enum TuneStageKind: String, Codable, Sendable, CaseIterable {
    case screen, narrow, verify

    public var title: String {
        switch self {
        case .screen: "Screen"
        case .narrow: "Narrow"
        case .verify: "Verify"
        }
    }
}

/// Screening result for one value of one setting, measured inside a single
/// llama-bench process next to the default value.
public struct ScreenValue: Codable, Sendable, Equatable {
    public var value: String
    public var isDefault: Bool
    public var ppTPS: Double?
    public var tgTPS: Double?
    /// Objective score relative to the default value in the same process (+0.04 = 4% better).
    public var relativeScore: Double?
    public var kept: Bool
}

public struct ScreenResult: Codable, Sendable, Equatable {
    public var dimension: TuneDimension
    public var defaultValue: String
    public var values: [ScreenValue]
    public var note: String?
    public var wallSeconds: Double
}

public struct StageCandidate: Codable, Sendable, Equatable {
    public var config: InferenceConfig
    public var label: String
    /// Objective score relative to the baseline in the same stage.
    public var relativeScore: Double?
    public var kept: Bool
}

public struct TuneStage: Codable, Sendable {
    public var kind: TuneStageKind
    public var benchmarkRunID: UUID?
    public var candidates: [StageCandidate]
    public var note: String?
}

public struct TuneDecision: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The winner beat the defaults on fresh measurements.
        case improved
        /// Nothing beat the defaults by a detectable margin.
        case keepDefaults = "keep_defaults"
        /// The tune stopped (safety guard, budget, cancel, failure) before deciding.
        case incomplete
    }

    public var kind: Kind
    /// The recommended config; `.runtimeDefaults` unless `kind == .improved`.
    public var config: InferenceConfig
    public var headline: String
    /// Primary metric: winner vs defaults on the verification data.
    public var primary: Comparison?
    public var primaryMetric: String?
    public var secondary: Comparison?
    public var secondaryMetric: String?
    public var details: [String]
}

public struct TuneReport: Codable, Sendable, Identifiable {
    public var id: UUID
    public var toolVersion: String
    public var startedAt: Date
    public var finishedAt: Date
    public var request: TuneRequest
    public var workload: Workload
    public var hardware: HardwareInfo
    public var model: ModelInfo
    public var installation: RuntimeInstallation
    public var screen: [ScreenResult]
    public var stages: [TuneStage]
    public var decision: TuneDecision
    public var warnings: [String]
    /// Every measurement process this tune ran.
    public var processCount: Int
}

public enum TuneEvent: Sendable {
    case stageStarted(TuneStageKind, detail: String)
    case screening(TuneDimension, values: [String])
    case screened(ScreenResult)
    case candidates([InferenceConfig])
    case bench(BenchmarkEvent)
    case stageFinished(TuneStage)
    /// Seconds still expected, from measured process times so far.
    case estimate(remainingSeconds: Double)
    case note(String)
    case finished(TuneReport)
}
