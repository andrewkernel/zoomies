import Foundation

/// Settings a run can change. `nil` means "leave it to the runtime's default",
/// which is different from writing the default value explicitly: defaults
/// move between runtime versions, and results must say which one was used.
///
/// Not every runtime supports every field. Adapters validate configs against
/// the installed runtime and reject what it does not understand.
public struct InferenceConfig: Codable, Sendable, Hashable {
    public enum Toggle: String, Codable, Sendable, Hashable { case on, off, auto }

    public var gpuLayers: Int?
    public var threads: Int?
    public var batchSize: Int?
    public var ubatchSize: Int?
    public var flashAttention: Toggle?
    public var cacheTypeK: String?
    public var cacheTypeV: String?
    /// How weights are loaded (llama.cpp `-lm/--load-mode`: auto, none, mmap,
    /// mlock, mmap+mlock, dio). Replaced the old `-mmp` flag in mid-2026.
    public var loadMode: String?
    public var poll: Int?

    public init(gpuLayers: Int? = nil, threads: Int? = nil, batchSize: Int? = nil, ubatchSize: Int? = nil,
                flashAttention: Toggle? = nil, cacheTypeK: String? = nil, cacheTypeV: String? = nil,
                loadMode: String? = nil, poll: Int? = nil) {
        self.gpuLayers = gpuLayers
        self.threads = threads
        self.batchSize = batchSize
        self.ubatchSize = ubatchSize
        self.flashAttention = flashAttention
        self.cacheTypeK = cacheTypeK
        self.cacheTypeV = cacheTypeV
        self.loadMode = loadMode
        self.poll = poll
    }

    public static let runtimeDefaults = InferenceConfig()

    /// Short human label, e.g. "ngl=99 t=4 fa=on" or "defaults".
    public var label: String {
        var p: [String] = []
        if let v = gpuLayers { p.append("ngl=\(v)") }
        if let v = threads { p.append("t=\(v)") }
        if let v = batchSize { p.append("b=\(v)") }
        if let v = ubatchSize { p.append("ub=\(v)") }
        if let v = flashAttention { p.append("fa=\(v.rawValue)") }
        if let v = cacheTypeK { p.append("ctk=\(v)") }
        if let v = cacheTypeV { p.append("ctv=\(v)") }
        if let v = loadMode { p.append("lm=\(v)") }
        if let v = poll { p.append("poll=\(v)") }
        return p.isEmpty ? "defaults" : p.joined(separator: " ")
    }

    /// Parses "ngl=99,t=4,fa=on" (comma or space separated). Unknown keys are errors.
    public static func parse(_ text: String) throws -> InferenceConfig {
        var c = InferenceConfig()
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        for part in parts where part != "defaults" {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { throw ConfigError.malformed(part) }
            let (k, v) = (kv[0].lowercased(), kv[1])
            func int() throws -> Int {
                guard let n = Int(v) else { throw ConfigError.badValue(key: k, value: v) }
                return n
            }
            switch k {
            case "ngl", "gpu_layers": c.gpuLayers = try int()
            case "t", "threads": c.threads = try int()
            case "b", "batch": c.batchSize = try int()
            case "ub", "ubatch": c.ubatchSize = try int()
            case "fa", "flash_attn":
                switch v.lowercased() {
                case "on", "1", "true": c.flashAttention = .on
                case "off", "0", "false": c.flashAttention = .off
                case "auto": c.flashAttention = .auto
                default: throw ConfigError.badValue(key: k, value: v)
                }
            case "ctk", "cache_type_k": c.cacheTypeK = v.lowercased()
            case "ctv", "cache_type_v": c.cacheTypeV = v.lowercased()
            case "lm", "load_mode": c.loadMode = v.lowercased()
            case "poll": c.poll = try int()
            default: throw ConfigError.unknownKey(k)
            }
        }
        return c
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unknownKey(String)
    case badValue(key: String, value: String)

    public var description: String {
        switch self {
        case .malformed(let p): "expected key=value, got '\(p)'"
        case .unknownKey(let k): "unknown setting '\(k)' (known: ngl, t, b, ub, fa, ctk, ctv, lm, poll)"
        case .badValue(let k, let v): "bad value '\(v)' for \(k)"
        }
    }
}

/// A finding from validating a config against a runtime + model + machine.
public struct ValidationIssue: Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var severity: Severity
    public var field: String
    public var message: String

    public init(_ severity: Severity, _ field: String, _ message: String) {
        self.severity = severity
        self.field = field
        self.message = message
    }

    public var description: String { "\(severity.rawValue): \(field): \(message)" }
}

/// An installed runtime as found on disk.
public struct RuntimeInstallation: Codable, Sendable, Equatable {
    public var runtimeID: String
    public var executable: String
    public var version: String?
    public var buildNumber: Int?
    public var commit: String?
    /// Flags the binary advertises in --help, for capability checks.
    public var flags: Set<String>
    /// Raw `--help` usage lines keyed by flag, so value syntax can be checked
    /// (e.g. `-fa <on|off|auto>` vs older `-fa <0|1>`).
    public var flagUsage: [String: String]
    public var devices: [String]
    /// Facts the backend logs at startup, e.g. Metal "has tensor" (M5 Neural
    /// Accelerators), residency sets, and which CPU backend variant loaded.
    /// Recorded per run so a build that silently loses a feature is visible.
    public var backendFacts: [String: String]? = nil

    public init(runtimeID: String, executable: String, version: String?, buildNumber: Int?, commit: String?,
                flags: Set<String>, flagUsage: [String: String], devices: [String]) {
        self.runtimeID = runtimeID
        self.executable = executable
        self.version = version
        self.buildNumber = buildNumber
        self.commit = commit
        self.flags = flags
        self.flagUsage = flagUsage
        self.devices = devices
    }
}

/// What one benchmark workload asks for.
public struct Workload: Codable, Sendable, Hashable {
    /// Prompt-processing test size (tokens); 0 skips it.
    public var promptTokens: Int
    /// Generation test size (tokens); 0 skips it.
    public var genTokens: Int
    /// Tokens already in the KV cache when the tests start.
    public var depth: Int

    public init(promptTokens: Int = 512, genTokens: Int = 128, depth: Int = 0) {
        self.promptTokens = promptTokens
        self.genTokens = genTokens
        self.depth = depth
    }
}

public enum TestKind: String, Codable, Sendable, Hashable {
    /// Prompt processing ("pp"): tokens/s while ingesting the prompt.
    case promptProcessing = "pp"
    /// Token generation ("tg"): tokens/s while generating one token at a time.
    case generation = "tg"
}

/// One measured test from one runtime process: several repetitions of the same thing.
public struct TestMeasurement: Codable, Sendable, Equatable {
    public var kind: TestKind
    public var tokens: Int
    public var depth: Int
    /// Per-repetition throughput in tokens/s, as reported by the runtime.
    public var samplesTPS: [Double]
    /// Runtime-reported metadata (build, backends, effective settings...).
    public var runtimeFields: [String: String]

    public init(kind: TestKind, tokens: Int, depth: Int, samplesTPS: [Double], runtimeFields: [String: String]) {
        self.kind = kind
        self.tokens = tokens
        self.depth = depth
        self.samplesTPS = samplesTPS
        self.runtimeFields = runtimeFields
    }
}

/// Every runtime (llama.cpp now; MLX and Ollama later) implements this. The
/// benchmark runner and optimizer only talk to runtimes through it.
public protocol RuntimeAdapter: Sendable {
    var runtimeID: String { get }

    /// Finds and fingerprints the installed runtime.
    func discover() throws -> RuntimeInstallation

    /// Errors make a config unusable; warnings are shown but allowed.
    func validate(_ config: InferenceConfig, installation: RuntimeInstallation, model: ModelInfo?,
                  hardware: HardwareInfo?) -> [ValidationIssue]

    /// The exact command line that would run this benchmark (for dry runs,
    /// reproduction instructions and the results database).
    func benchmarkCommand(model: URL, config: InferenceConfig, workload: Workload, repetitions: Int,
                          installation: RuntimeInstallation) -> [String]

    /// Turns the process output into measurements; throws when it holds none.
    func parseBenchmarkOutput(stdout: String, stderr: String) throws -> [TestMeasurement]
}
