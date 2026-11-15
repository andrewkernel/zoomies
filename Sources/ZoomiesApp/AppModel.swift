import AppKit
import Foundation
import Observation
import ZoomiesKit

/// Lets background tuning callbacks reach the model without keeping it alive.
struct WeakModel: @unchecked Sendable {
    weak var model: AppModel?
    init(_ m: AppModel) { model = m }
}

enum MenuID: Hashable { case model, goal, context, budget, runtime, system }
enum AppTab: String, CaseIterable, Hashable { case tune = "Tune", profiles = "Profiles", history = "History" }

/// Settings the user can change (⌘,). Stored in UserDefaults.
enum SettingsKey {
    static let llamaBenchPath = "llamaBenchPath"
    static let allowBattery = "allowBattery"
    static let minBattery = "minBattery"
    static let guardrail = "guardrailPercent"
    static let extraFolders = "extraModelFolders"
    static let calmMotion = "calmMotion"
    static let objective = "objective"
    static let budget = "budget"
    static let context = "contextTokens"
    static let allowKV = "allowKV"
    static let lastModel = "lastModelPath"
}

@MainActor @Observable
final class AppModel {
    // Machine and runtime
    var hardware: HardwareInfo
    var system: SystemState
    var installation: RuntimeInstallation?
    var runtimeError: String?

    // Models
    var library: [LibraryModel] = []
    var selectedURL: URL?
    var model: ModelInfo?
    var modelError: String?

    // Choices (persisted)
    var objective: TuneObjective { didSet { defaults.set(objective.rawValue, forKey: SettingsKey.objective) } }
    var budget: TuneBudget { didSet { defaults.set(budget.rawValue, forKey: SettingsKey.budget) } }
    var contextTokens: Int { didSet { defaults.set(contextTokens, forKey: SettingsKey.context) } }
    var allowKV: Bool { didSet { defaults.set(allowKV, forKey: SettingsKey.allowKV) } }

    // Run state
    enum Phase: Equatable { case idle, running, finished }
    var phase: Phase = .idle
    var stage: TuneStageKind?
    var stageDetail = ""
    var activity = ""
    var liveTG: Double?
    var livePP: Double?
    var remainingSeconds: Double?
    var runStarted: Date?
    var screen: [ScreenResult] = []
    var narrowing: [TuneStage] = []
    var candidates: [InferenceConfig] = []
    var report: TuneReport?
    var reportProfile: TuningProfile?
    var showDetails = false

    // Profiles and history
    var activeProfile: TuningProfile?
    var profiles: [TuningProfile] = []
    var tunes: [ResultStore.TuneRow] = []

    // UI
    var openMenu: MenuID?
    var tab: AppTab = .tune
    var toast: String?

    private let defaults = UserDefaults.standard
    private let probe = HardwareProbes.current()
    fileprivate var store: ResultStore?
    private var task: Task<Void, Never>?
    private var refreshTimer: Timer?

    init() {
        hardware = probe.hardware()
        system = probe.state()
        objective = TuneObjective(rawValue: defaults.string(forKey: SettingsKey.objective) ?? "") ?? .generation
        budget = TuneBudget(rawValue: defaults.string(forKey: SettingsKey.budget) ?? "") ?? .standard
        contextTokens = defaults.integer(forKey: SettingsKey.context)
        allowKV = defaults.bool(forKey: SettingsKey.allowKV)
        store = try? ResultStore()
        ChildRegistry.shared.reapOrphans()
        discoverRuntime()
        refreshLibrary()
        if let last = defaults.string(forKey: SettingsKey.lastModel), FileManager.default.fileExists(atPath: last) {
            select(URL(fileURLWithPath: last))
        } else if let first = library.first {
            select(first.url)
        }
        reloadStored()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.system = self.probe.state()
            }
        }
    }

    // MARK: Settings

    var llamaBenchPath: String? {
        get { defaults.string(forKey: SettingsKey.llamaBenchPath).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: SettingsKey.llamaBenchPath); discoverRuntime() }
    }
    var allowBattery: Bool {
        get { defaults.bool(forKey: SettingsKey.allowBattery) }
        set { defaults.set(newValue, forKey: SettingsKey.allowBattery) }
    }
    var minBattery: Int {
        get { let v = defaults.integer(forKey: SettingsKey.minBattery); return v == 0 ? 30 : v }
        set { defaults.set(newValue, forKey: SettingsKey.minBattery) }
    }
    var guardrail: Double {
        get { let v = defaults.double(forKey: SettingsKey.guardrail); return v == 0 ? 5 : v }
        set { defaults.set(newValue, forKey: SettingsKey.guardrail) }
    }
    var extraFolders: [String] {
        get { defaults.stringArray(forKey: SettingsKey.extraFolders) ?? [] }
        set { defaults.set(newValue, forKey: SettingsKey.extraFolders); refreshLibrary() }
    }

    var limits: SafetyLimits {
        var l = SafetyLimits()
        l.allowBattery = allowBattery
        l.minBatteryPercent = minBattery
        return l
    }

    // MARK: Discovery

    func discoverRuntime() {
        do {
            installation = try LlamaBenchAdapter(explicitPath: llamaBenchPath).discover()
            runtimeError = nil
        } catch {
            installation = nil
            runtimeError = "\(error)"
        }
    }

    func refreshLibrary() {
        library = ModelLibrary.scan(extraFolders: extraFolders.map { URL(fileURLWithPath: $0) })
    }

    func select(_ url: URL) {
        selectedURL = url
        defaults.set(url.path, forKey: SettingsKey.lastModel)
        do {
            model = try ModelInspector.inspect(url)
            modelError = nil
        } catch {
            model = nil
            modelError = "\(error)"
        }
        if phase == .finished { phase = .idle; report = nil }
        reloadStored()
    }

    func chooseModelFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GGUF model. Zoomies reads it where it is and never modifies it."
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }

    func reloadStored() {
        guard let store else { return }
        profiles = (try? store.profiles(hardwareFingerprint: hardware.fingerprint)) ?? []
        tunes = (try? store.recentTunes()) ?? []
        if let m = model {
            activeProfile = try? store.activeProfile(modelFingerprint: m.quickFingerprint, hardwareFingerprint: hardware.fingerprint)
        } else {
            activeProfile = nil
        }
    }

    // MARK: Readiness

    /// Why a tune can't start right now (blocking), and what would make it less reliable.
    var readiness: (blocking: [String], warnings: [String]) {
        var blocking: [String] = []
        if installation == nil { blocking.append("llama.cpp not found") }
        guard let m = model else { return (blocking + ["Choose a model"], []) }
        let req = request
        let pre = BenchmarkRunner.preflight(plan: BenchmarkPlan(workload: req.workload, configs: [.runtimeDefaults], rounds: 2, limits: limits),
                                            model: m, hardware: hardware, state: system)
        blocking += pre.filter(\.blocking).map(\.message)
        return (blocking, pre.filter { !$0.blocking }.map(\.message))
    }

    var request: TuneRequest {
        TuneRequest(objective: objective, budget: budget,
                    constraints: TuneConstraints(contextTokens: contextTokens, allowKVQuantization: allowKV,
                                                 guardrailPercent: guardrail, limits: limits))
    }

    // MARK: Tuning

    func startTune() {
        guard phase != .running, let url = selectedURL, let m = model, let inst = installation, readiness.blocking.isEmpty else { return }
        openMenu = nil
        phase = .running
        stage = nil
        stageDetail = "Preparing"
        activity = ""
        liveTG = nil
        livePP = nil
        remainingSeconds = nil
        runStarted = Date()
        screen = []
        narrowing = []
        candidates = []
        report = nil
        reportProfile = nil
        let req = request
        let adapter = LlamaBenchAdapter(explicitPath: llamaBenchPath)
        let tuner = Tuner(runner: BenchmarkRunner(adapter: adapter))
        let ref = WeakModel(self)
        task = Task.detached {
            let r = await tuner.tune(request: req, modelURL: url, model: m, installation: inst, onEvent: { ev in
                Task { @MainActor in ref.model?.handle(ev) }
            }, onBenchmarkReport: { rep in
                Task { @MainActor in if !rep.trials.isEmpty { try? ref.model?.store?.save(rep) } }
            })
            await MainActor.run { ref.model?.finish(r, modelURL: url) }
        }
    }

    func cancelTune() {
        task?.cancel()
        stageDetail = "Stopping…"
    }

    fileprivate func handle(_ ev: TuneEvent) {
        switch ev {
        case .stageStarted(let k, let detail):
            stage = k
            stageDetail = detail
        case .screening(let d, let values):
            activity = "\(d.title): \(values.joined(separator: " · "))"
        case .screened(let r):
            screen.append(r)
            if let def = r.values.first(where: \.isDefault) {
                liveTG = def.tgTPS ?? liveTG
                livePP = def.ppTPS ?? livePP
            }
        case .candidates(let c):
            candidates = c
        case .bench(.trialStarted(_, let total, let round, let label)) where total > 0:
            activity = "Round \(round + 1) · \(label)"
        case .bench(.trialFinished(let t)):
            if let g = t.measurements.first(where: { $0.kind == .generation }) { liveTG = Stats.mean(g.samplesTPS) }
            if let p = t.measurements.first(where: { $0.kind == .promptProcessing }) { livePP = Stats.mean(p.samplesTPS) }
        case .stageFinished(let s):
            if s.kind == .narrow { narrowing.append(s) }
        case .estimate(let s):
            remainingSeconds = s
        default:
            break
        }
    }

    fileprivate func finish(_ r: TuneReport, modelURL: URL) {
        report = r
        phase = .finished
        stage = nil
        task = nil
        try? store?.save(r)
        if r.decision.kind != .incomplete {
            let p = TuningProfile.from(r, modelURL: modelURL)
            try? store?.save(p)
            reportProfile = p
        }
        reloadStored()
    }

    func reset() {
        phase = .idle
        report = nil
        reportProfile = nil
    }

    // MARK: Profiles

    func apply(_ p: TuningProfile) {
        guard let store else { return }
        try? store.activate(p.config == .runtimeDefaults ? nil : p.id, modelFingerprint: p.modelFingerprint,
                            hardwareFingerprint: p.hardwareFingerprint)
        reloadStored()
        flash("Active: \(p.config.label)")
    }

    func rollback() {
        guard let store, let m = model else { return }
        let now = try? store.rollback(modelFingerprint: m.quickFingerprint, hardwareFingerprint: hardware.fingerprint)
        reloadStored()
        flash("Active: \(now?.config.label ?? "llama.cpp defaults")")
    }

    func serverCommand(for config: InferenceConfig, modelPath: String? = nil) -> String? {
        guard let inst = installation, let path = modelPath ?? selectedURL?.path else { return nil }
        let ctx = contextTokens > 0 ? contextTokens + 4096 : nil
        return ServerCommand.shellLine(ServerCommand.arguments(config: config, modelPath: path, installation: inst, contextTokens: ctx))
    }

    func copy(_ text: String, note: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(note)
    }

    func openTune(_ id: String) {
        guard let r = try? store?.tune(id: id) else { return }
        if FileManager.default.fileExists(atPath: r.model.path) { select(URL(fileURLWithPath: r.model.path)) }
        report = r
        reportProfile = profiles.first { $0.tuneRunID == r.id }
        phase = .finished
        tab = .tune
    }

    func flash(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if toast == message { toast = nil }
        }
    }

    // MARK: Derived

    var swirlSpeed: Double {
        switch phase {
        case .running: return 0.6 + min(2.0, (liveTG ?? 30) / 60)
        case .finished: return 0.25
        case .idle: return 0.12
        }
    }

    var swirlWarmth: Double {
        phase == .finished && report?.decision.kind == .improved ? 1 : (phase == .running ? 0.35 : 0)
    }

    /// The file name is what people recognise (GGUF `general.name` is often a
    /// converter's label); Ollama blobs use their library name instead.
    var modelDisplayName: String {
        guard let url = selectedURL else { return "Choose a model" }
        if let lib = library.first(where: { $0.url == url }) { return lib.displayName }
        return (url.lastPathComponent as NSString).deletingPathExtension
    }
}
