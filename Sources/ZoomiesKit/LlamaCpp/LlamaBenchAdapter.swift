import Foundation

public enum LlamaBenchError: Error, CustomStringConvertible {
    case notFound(searched: [String])
    case noResults(stderrTail: String)

    public var description: String {
        switch self {
        case .notFound(let s): "llama-bench not found. Looked in: \(s.joined(separator: ", ")). Set ZOOMIES_LLAMA_BENCH or pass --llama-bench."
        case .noResults(let tail): "llama-bench produced no results.\n\(tail)"
        }
    }
}

/// llama.cpp via its `llama-bench` tool.
///
/// What llama-bench measures itself: per-repetition prompt-processing and
/// generation throughput (`samples_ts`), with model load excluded and a warmup
/// run by default. What it does not measure: time to first token, peak memory,
/// energy. Zoomies adds peak memory from the process footprint; TTFT needs
/// llama-server and is not claimed here.
public struct LlamaBenchAdapter: RuntimeAdapter {
    public let runtimeID = "llama.cpp"
    public var explicitPath: String?

    public init(explicitPath: String? = nil) {
        self.explicitPath = explicitPath
    }

    // MARK: Discovery

    public func locate() throws -> String {
        var candidates: [String] = []
        if let p = explicitPath { candidates.append(p) }
        let env = ProcessInfo.processInfo.environment
        if let p = env["ZOOMIES_LLAMA_BENCH"] { candidates.append(p) }
        if let d = env["LLAMA_CPP_DIR"] { candidates.append((d as NSString).appendingPathComponent("llama-bench")) }
        // PATH, but never the current directory (a planted binary there would run).
        for dir in (env["PATH"] ?? "").split(separator: ":") where !dir.isEmpty && dir != "." {
            candidates.append("\(dir)/llama-bench")
        }
        candidates += ["/opt/homebrew/bin/llama-bench", "/usr/local/bin/llama-bench"]
        let fm = FileManager.default
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit).resolvingSymlinksInPath().path
        }
        var searched = [explicitPath, env["ZOOMIES_LLAMA_BENCH"], env["LLAMA_CPP_DIR"]].compactMap { $0 }
        searched += ["PATH", "/opt/homebrew/bin", "/usr/local/bin"]
        throw LlamaBenchError.notFound(searched: searched)
    }

    public func discover() throws -> RuntimeInstallation {
        let exe = try locate()
        let version = ShortCommand.run(exe, ["--version"])
        let help = ShortCommand.run(exe, ["--help"])
        let devices = ShortCommand.run(exe, ["--list-devices"])
        return Self.installation(executable: exe, versionText: version, helpText: help, devicesText: devices)
    }

    static func installation(executable: String, versionText: String, helpText: String, devicesText: String) -> RuntimeInstallation {
        let (version, build, commit) = parseVersion(versionText)
        let (flags, usage) = parseHelp(helpText)
        var inst = RuntimeInstallation(runtimeID: "llama.cpp", executable: executable, version: version, buildNumber: build,
                                       commit: commit, flags: flags, flagUsage: usage, devices: parseDevices(devicesText))
        let facts = backendFacts(versionText)
        inst.backendFacts = facts.isEmpty ? nil : facts
        return inst
    }

    /// Pulls startup facts out of ggml's log lines (format as of b12359):
    ///   "ggml_metal_device_init: has tensor            = true"
    ///   "ggml_metal_device_init: GPU family: MTLGPUFamilyApple10  (1010)"
    ///   "load_backend: loaded CPU backend from .../libggml-cpu-apple_m4.so"
    static func backendFacts(_ log: String) -> [String: String] {
        var facts: [String: String] = [:]
        var families: [String] = []
        for raw in log.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("ggml_metal_device_init:") {
                let body = line.dropFirst("ggml_metal_device_init:".count).trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("GPU family:") {
                    if let fam = body.split(separator: " ").first(where: { $0.hasPrefix("MTLGPUFamily") }) {
                        families.append(String(fam.dropFirst("MTLGPUFamily".count)))
                    }
                } else if let eq = body.firstIndex(of: "="), body.hasPrefix("has ") || body.hasPrefix("use ") {
                    let key = "metal." + body[..<eq].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
                    facts[key] = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("load_backend: loaded CPU backend from "),
                      let r = line.range(of: #"libggml-cpu-?([A-Za-z0-9_]*)\.(so|dylib)"#, options: .regularExpression) {
                let name = line[r].replacingOccurrences(of: #"\.(so|dylib)$"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "libggml-cpu", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                facts["cpu_backend_variant"] = name.isEmpty ? "generic" : name
            }
        }
        if !families.isEmpty { facts["metal.gpu_families"] = families.joined(separator: ",") }
        return facts
    }

    /// Handles "version: 7100 (abc1234)" and "version: 0.5.0-dev (build 11347, commit 5fc4f3c8c)".
    static func parseVersion(_ text: String) -> (String?, Int?, String?) {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("version:") }) else { return (nil, nil, nil) }
        let v = line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
        let head = v.split(separator: " ").first.map(String.init)
        var build: Int?
        var commit: String?
        if let r = v.range(of: #"build (\d+)"#, options: .regularExpression) {
            build = Int(v[r].dropFirst(6))
        } else if let h = head, let n = Int(h) {
            build = n
        }
        if let r = v.range(of: #"commit ([0-9a-f]+)"#, options: .regularExpression) {
            commit = String(v[r].dropFirst(7))
        } else if let r = v.range(of: #"\(([0-9a-f]{6,})\)"#, options: .regularExpression) {
            commit = String(v[r].dropFirst().dropLast())
        }
        return (v, build, commit)
    }

    /// Collects every flag spelling in `--help` ("-fa, --flash-attn <on|off|auto>").
    static func parseHelp(_ text: String) -> (Set<String>, [String: String]) {
        var flags = Set<String>()
        var usage: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") else { continue }
            // Flags come first, separated by ", " or " "; stop at the first token that is not a flag.
            let head = line.components(separatedBy: "  ").first ?? line
            for tok in head.replacingOccurrences(of: ",", with: " ").split(separator: " ") {
                guard tok.hasPrefix("-"), tok.count > 1 else { break }
                flags.insert(String(tok))
                usage[String(tok)] = line
            }
        }
        return (flags, usage)
    }

    /// The `<a|b|c>` choices in a help line, e.g. "-lm, --load-mode <auto|none|mmap> (default: auto)" → [auto, none, mmap].
    /// nil if the line has no choice list, so callers skip the check rather than guess.
    static func choices(_ usageLine: String?) -> Set<String>? {
        guard let line = usageLine, let open = line.firstIndex(of: "<"),
              let close = line[open...].firstIndex(of: ">") else { return nil }
        let inner = line[line.index(after: open)..<close]
        guard inner.contains("|") else { return nil }
        return Set(inner.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// The last lines of stderr that could explain a failure, without the
    /// per-library Metal compile chatter that fills the first seconds.
    public static func errorTail(_ stderr: String, maxLines: Int = 12) -> String {
        stderr.split(separator: "\n")
            .filter { !$0.contains("ggml_metal_library_compile") && !$0.contains("dummy_kernel") }
            .suffix(maxLines).joined(separator: "\n")
    }

    static func parseDevices(_ text: String) -> [String] {
        var out: [String] = []
        var inList = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Available devices") { inList = true; continue }
            if inList, !line.isEmpty, line != "(none)" { out.append(line) }
        }
        return out
    }

    // MARK: Validation

    public func validate(_ c: InferenceConfig, installation inst: RuntimeInstallation, model: ModelInfo?,
                         hardware: HardwareInfo?) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func need(_ field: String, _ flag: String) {
            if !inst.flags.contains(flag) {
                issues.append(.init(.error, field, "this llama-bench build has no \(flag) option"))
            }
        }
        if c.gpuLayers != nil { need("gpuLayers", "-ngl") }
        if let t = c.threads {
            need("threads", "-t")
            if t < 1 { issues.append(.init(.error, "threads", "must be at least 1")) }
            if let hw = hardware, t > hw.logicalCores {
                issues.append(.init(.warning, "threads", "\(t) threads on a \(hw.logicalCores)-thread CPU oversubscribes it"))
            }
        }
        if let b = c.batchSize {
            need("batchSize", "-b")
            if b < 1 { issues.append(.init(.error, "batchSize", "must be at least 1")) }
        }
        if let ub = c.ubatchSize {
            need("ubatchSize", "-ub")
            if ub < 1 { issues.append(.init(.error, "ubatchSize", "must be at least 1")) }
            if let b = c.batchSize, ub > b {
                issues.append(.init(.warning, "ubatchSize", "ubatch \(ub) > batch \(b); llama.cpp caps ubatch at batch"))
            }
        }
        if let fa = c.flashAttention {
            need("flashAttention", "-fa")
            if fa == .auto, let choices = Self.choices(inst.flagUsage["-fa"]), !choices.contains("auto") {
                issues.append(.init(.error, "flashAttention", "this build's -fa does not accept 'auto'"))
            }
        }
        for (field, flag, value) in [("cacheTypeK", "-ctk", c.cacheTypeK), ("cacheTypeV", "-ctv", c.cacheTypeV)] {
            guard let v = value else { continue }
            need(field, flag)
            if GGMLType.kvBytesPerElement(v) == nil {
                issues.append(.init(.error, field, "unknown KV cache type '\(v)'"))
            }
        }
        // A quantized V cache needs flash attention (llama-context.cpp refuses otherwise).
        if let v = c.cacheTypeV, !["f16", "bf16", "f32"].contains(v), c.flashAttention == .off {
            issues.append(.init(.error, "cacheTypeV", "a quantized V cache (\(v)) requires flash attention"))
        }
        if let lm = c.loadMode {
            need("loadMode", "-lm")
            if let choices = Self.choices(inst.flagUsage["-lm"]), !choices.contains(lm) {
                issues.append(.init(.error, "loadMode", "this build's --load-mode does not list '\(lm)'"))
            }
        }
        if let p = c.poll {
            need("poll", "--poll")
            if !(0...100).contains(p) { issues.append(.init(.error, "poll", "must be 0...100")) }
        }
        if let ngl = c.gpuLayers, let layers = model?.blockCount, ngl >= 0, ngl < layers + 1,
           hardware?.gpus.first?.unifiedMemory == true {
            issues.append(.init(.warning, "gpuLayers",
                                "partial offload (\(ngl) of \(layers + 1) layers) on unified memory is usually slower than full offload"))
        }
        return issues
    }

    // MARK: Running

    public func benchmarkCommand(model: URL, config c: InferenceConfig, workload w: Workload, repetitions: Int,
                                 installation inst: RuntimeInstallation) -> [String] {
        var a = [inst.executable, "-m", model.path, "-r", "\(repetitions)", "-o", "jsonl"]
        a += ["-p", "\(w.promptTokens)", "-n", "\(w.genTokens)"]
        if w.depth > 0 { a += ["-d", "\(w.depth)"] }
        if let v = c.gpuLayers { a += ["-ngl", "\(v)"] }
        if let v = c.threads { a += ["-t", "\(v)"] }
        if let v = c.batchSize { a += ["-b", "\(v)"] }
        if let v = c.ubatchSize { a += ["-ub", "\(v)"] }
        if let v = c.flashAttention { a += ["-fa", v.rawValue] }
        if let v = c.cacheTypeK { a += ["-ctk", v] }
        if let v = c.cacheTypeV { a += ["-ctv", v] }
        if let v = c.loadMode { a += ["-lm", v] }
        if let v = c.poll { a += ["--poll", "\(v)"] }
        return a
    }

    public func parseBenchmarkOutput(stdout: String, stderr: String) throws -> [TestMeasurement] {
        let records = Self.parseJSONL(stdout)
        guard !records.isEmpty else {
            throw LlamaBenchError.noResults(stderrTail: Self.errorTail(stderr))
        }
        return records
    }

    // MARK: Tuning support

    static func flag(for d: TuneDimension) -> String {
        switch d {
        case .flashAttention: "-fa"
        case .ubatch: "-ub"
        case .batch: "-b"
        case .threads: "-t"
        case .poll: "--poll"
        case .kvCache: "-ctk"
        case .gpuLayers: "-ngl"
        }
    }

    /// "(default: 512)" in this build's --help line for the flag.
    static func helpDefault(_ usageLine: String?) -> String? {
        guard let line = usageLine, let r = line.range(of: #"\(default: ([^)]*)\)"#, options: .regularExpression) else { return nil }
        let v = line[r].dropFirst("(default: ".count).dropLast().trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    public func defaultValue(_ d: TuneDimension, installation inst: RuntimeInstallation) -> String? {
        let f = Self.flag(for: d)
        guard inst.flags.contains(f) else { return nil }
        if let v = Self.helpDefault(inst.flagUsage[f]) { return v }
        // Fallbacks for builds whose help omits a default (llama.cpp master as of 2026-11).
        switch d {
        case .flashAttention: return Self.choices(inst.flagUsage[f])?.contains("auto") == true ? "auto" : nil
        case .ubatch: return "512"
        case .batch: return "2048"
        case .poll: return "50"
        case .kvCache: return "f16"
        case .gpuLayers: return "-1"
        case .threads: return nil
        }
    }

    /// llama-bench runs the cross product of comma-separated values in one
    /// process, with the model loaded once. For the KV cache, K and V get the
    /// same list; mixed pairs from the cross product are reported as "mixed".
    public func sweepCommand(model: URL, dimension d: TuneDimension, values: [String], workload: Workload,
                             repetitions: Int, installation inst: RuntimeInstallation) -> [String]? {
        guard !values.isEmpty, inst.flags.contains(Self.flag(for: d)) else { return nil }
        var a = benchmarkCommand(model: model, config: .runtimeDefaults, workload: workload,
                                 repetitions: repetitions, installation: inst)
        let list = values.joined(separator: ",")
        a += [Self.flag(for: d), list]
        if d == .kvCache { a += ["-ctv", list] }
        return a
    }

    public func effectiveValue(_ d: TuneDimension, of m: TestMeasurement) -> String? {
        let f = m.runtimeFields
        switch d {
        case .flashAttention:
            switch f["flash_attn"] {
            case "-1", "auto": return "auto"
            case "0", "off", "false": return "off"
            case "1", "on", "true": return "on"
            default: return nil
            }
        case .ubatch: return f["n_ubatch"]
        case .batch: return f["n_batch"]
        case .threads: return f["n_threads"]
        case .poll: return f["poll"]
        case .gpuLayers: return f["n_gpu_layers"]
        case .kvCache:
            guard let k = f["type_k"], let v = f["type_v"] else { return nil }
            return k == v ? k : "mixed:\(k)/\(v)"
        }
    }

    /// One JSON object per line. Log lines and unrelated JSON are ignored. A
    /// test with both n_prompt and n_gen (older builds, or -pg) counts as generation.
    static func parseJSONL(_ text: String) -> [TestMeasurement] {
        var out: [TestMeasurement] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let nPrompt = obj["n_prompt"] as? Int, let nGen = obj["n_gen"] as? Int else { continue }
            let kind: TestKind = nGen > 0 ? .generation : .promptProcessing
            var samples = (obj["samples_ts"] as? [Double]) ?? (obj["samples_ts"] as? [NSNumber])?.map(\.doubleValue) ?? []
            if samples.isEmpty, let avg = obj["avg_ts"] as? Double { samples = [avg] }
            guard !samples.isEmpty else { continue }
            var fields: [String: String] = [:]
            for (k, v) in obj where !["samples_ts", "samples_ns"].contains(k) {
                fields[k] = "\(v)"
            }
            out.append(TestMeasurement(kind: kind, tokens: nGen > 0 ? nGen : nPrompt, depth: obj["n_depth"] as? Int ?? 0,
                                       samplesTPS: samples, runtimeFields: fields))
        }
        return out
    }

    /// Lines from stderr worth keeping with a run: what backend actually ran and
    /// whether M5-class GPUs used the Metal tensor API (Neural Accelerators).
    public static func notableLogLines(_ stderr: String) -> [String] {
        let keys = ["tensor API", "ggml_metal_device_init", "GPU name", "has tensor", "recommendedMaxWorkingSetSize",
                    "load_backend", "error", "failed"]
        return stderr.split(separator: "\n").map(String.init)
            .filter { line in keys.contains { line.localizedCaseInsensitiveContains($0) } }
            .prefix(40).map { $0 }
    }
}

/// Runs a short informational command (`--version`, `--help`) and returns
/// stdout + stderr. Not for benchmarks: no watchdog, 20 s limit.
enum ShortCommand {
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 20) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ChildProcess.sanitizedEnvironment()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("zoomies-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        guard let h = try? FileHandle(forWritingTo: out) else { return "" }
        p.standardOutput = h
        p.standardError = h
        do { try p.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        try? h.close()
        return (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    }
}
