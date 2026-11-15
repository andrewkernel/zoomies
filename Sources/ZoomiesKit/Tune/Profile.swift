import Foundation

/// A named, saved set of settings for one model on one machine. Zoomies never
/// edits the user's own configs; it keeps its own profiles and exports them.
public struct TuningProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modelPath: String
    public var modelName: String
    public var modelFingerprint: String
    public var hardwareFingerprint: String
    public var runtimeBuild: Int?
    public var objective: TuneObjective?
    public var config: InferenceConfig
    /// The settings' evidence in one line, e.g. "+8.2% generation speed [+5.1%, +11.4%]".
    public var headline: String
    public var tuneRunID: UUID?
    /// Context length the profile was tuned at (llama-bench -d).
    public var contextTokens: Int?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), modelPath: String, modelName: String,
                modelFingerprint: String, hardwareFingerprint: String, runtimeBuild: Int?, objective: TuneObjective?,
                config: InferenceConfig, headline: String, tuneRunID: UUID?, contextTokens: Int?) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modelPath = modelPath
        self.modelName = modelName
        self.modelFingerprint = modelFingerprint
        self.hardwareFingerprint = hardwareFingerprint
        self.runtimeBuild = runtimeBuild
        self.objective = objective
        self.config = config
        self.headline = headline
        self.tuneRunID = tuneRunID
        self.contextTokens = contextTokens
    }

    /// A profile from a finished tune (also for "keep defaults": that is a result worth recording).
    public static func from(_ r: TuneReport, modelURL: URL) -> TuningProfile {
        let name: String
        switch r.decision.kind {
        case .improved: name = "\(r.request.objective.title) · \(r.decision.config.label)"
        default: name = "Defaults (verified best)"
        }
        var headline = r.decision.headline
        if let p = r.decision.primary, let m = r.decision.primaryMetric, r.decision.kind == .improved {
            headline = "\(fmtComparison(p)) \(m)"
        }
        return TuningProfile(name: name, modelPath: modelURL.path, modelName: r.model.name ?? modelURL.lastPathComponent,
                             modelFingerprint: r.model.quickFingerprint, hardwareFingerprint: r.hardware.fingerprint,
                             runtimeBuild: r.installation.buildNumber, objective: r.request.objective,
                             config: r.decision.config, headline: headline, tuneRunID: r.id,
                             contextTokens: r.workload.depth)
    }
}

/// Turns a profile into a `llama-server` command line.
///
/// llama-bench and llama-server do not share every default (build 12359):
/// threads are 4 in llama-bench but -1 (auto) in llama-server, and GPU layers
/// are -1 (all) in llama-bench but `auto` (fit to memory) in llama-server.
/// Those two are always written explicitly, so the server runs what was measured.
public enum ServerCommand {
    /// `llama-server` from the same installation as the measured llama-bench.
    public static func executable(near benchPath: String) -> String {
        let dir = (benchPath as NSString).deletingLastPathComponent
        let sibling = (dir as NSString).appendingPathComponent("llama-server")
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : "llama-server"
    }

    public static func arguments(config c: InferenceConfig, modelPath: String, installation: RuntimeInstallation,
                                 adapter: RuntimeAdapter = LlamaBenchAdapter(), contextTokens: Int? = nil) -> [String] {
        var a = [executable(near: installation.executable), "-m", modelPath]
        let threads = c.threads.map(String.init) ?? adapter.defaultValue(.threads, installation: installation)
        if let t = threads { a += ["-t", t] }
        let ngl = c.gpuLayers.map { $0 < 0 ? "all" : String($0) } ?? "all"
        a += ["-ngl", ngl]
        if let v = c.batchSize { a += ["-b", "\(v)"] }
        if let v = c.ubatchSize { a += ["-ub", "\(v)"] }
        if let v = c.flashAttention { a += ["-fa", v.rawValue] }
        if let v = c.cacheTypeK { a += ["-ctk", v] }
        if let v = c.cacheTypeV { a += ["-ctv", v] }
        if let v = c.loadMode { a += ["-lm", v] }
        if let v = c.poll { a += ["--poll", "\(v)"] }
        if let ctx = contextTokens, ctx > 0 { a += ["-c", "\(ctx)"] }
        return a
    }

    /// Shell-safe single line for copying.
    public static func shellLine(_ args: [String]) -> String {
        args.map { arg in
            arg.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:+,".contains($0) } ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
