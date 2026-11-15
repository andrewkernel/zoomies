import SwiftUI
import ZoomiesKit

struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.calmMotion) private var calmMotion = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            AsciiField(speed: calmMotion ? 0.05 : app.swirlSpeed, warmth: app.swirlWarmth, lowPower: app.phase == .running || calmMotion)
                .ignoresSafeArea()
            RadialGradient(colors: [.clear, Theme.background.opacity(0.85)], center: .center, startRadius: 220, endRadius: 760)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            if app.openMenu != nil {
                Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { app.openMenu = nil }
            }
            VStack(spacing: 0) {
                TopBar()
                Group {
                    switch app.tab {
                    case .tune: TuneScreen()
                    case .profiles: ProfilesScreen()
                    case .history: HistoryScreen()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let t = app.toast {
                VStack {
                    Spacer()
                    Text(t).font(Theme.small).foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).frame(height: 28).cardStyle(radius: 8, fill: Theme.menu)
                        .padding(.bottom, 22)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: app.toast)
        .frame(minWidth: 900, minHeight: 660)
        .onKeyPress(.escape) {
            if app.openMenu != nil { app.openMenu = nil; return .handled }
            return .ignored
        }
    }
}

/// Tabs in the title bar area, right of the window buttons.
struct TopBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { t in
                TabButton(title: t.rawValue, selected: app.tab == t) { app.tab = t; app.openMenu = nil }
            }
            Spacer()
            if app.phase == .running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                    Text("Tuning").font(Theme.small).foregroundStyle(Theme.secondary)
                }
                .padding(.trailing, 6)
            }
            SettingsLink {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.leading, 82).padding(.trailing, 12)
        .frame(height: 38)
    }
}

struct TabButton: View {
    var title: String
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.small)
                .foregroundStyle(selected ? Theme.text : (hover ? Theme.secondary : Theme.tertiary))
                .padding(.horizontal, 11).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.white.opacity(0.08) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? Theme.hairline : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Tune screen

struct TuneScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)
            TuneCard().frame(width: 660)
            // Fixed-height area: what appears here fades in place, never pushes the card.
            ZStack(alignment: .top) {
                switch app.phase {
                case .idle: IdleHints().transition(.opacity)
                case .running: RunPanel().transition(.opacity)
                case .finished: if let r = app.report { ReceiptView(report: r).transition(.opacity) }
                }
            }
            .frame(width: 660, height: 330, alignment: .top)
            .animation(.easeInOut(duration: 0.25), value: app.phase)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: Binding(get: { app.showDetails }, set: { app.showDetails = $0 })) {
            if let r = app.report { DetailsSheet(report: r) }
        }
    }
}

struct TuneCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    sentence.font(Theme.title).lineLimit(1)
                    Text(statusLine).font(Theme.small).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                GoButton()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack(spacing: 2) {
                SystemChip()
                ModelChip()
                ContextChip()
                Spacer(minLength: 6)
                GoalChip()
                BudgetChip()
            }
            .padding(.horizontal, 8).frame(height: 38)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: Theme.radius, bottomTrailingRadius: Theme.radius, style: .continuous)
                .fill(Color.black.opacity(0.18)))
        }
        .cardStyle()
        .zIndex(1)
    }

    private var sentence: Text {
        let goal: String
        switch app.objective {
        case .generation: goal = "reply as fast as possible"
        case .response: goal = "start answering sooner"
        case .balanced: goal = "faster all round"
        case .memory: goal = "use less memory"
        }
        return Text("Make ").foregroundColor(Theme.secondary)
            + Text(app.modelDisplayName).foregroundColor(Theme.text)
            + Text(" \(goal)").foregroundColor(Theme.text)
            + Text(" on this Mac").foregroundColor(Theme.secondary)
    }

    private var statusLine: String {
        switch app.phase {
        case .running:
            let elapsed = app.runStarted.map { Date().timeIntervalSince($0) } ?? 0
            let left = app.remainingSeconds.map { " · about \(formatDuration($0)) left" } ?? ""
            return "\(app.stage?.title ?? "Starting") · \(app.stageDetail) · \(formatDuration(elapsed))\(left)"
        case .finished:
            return app.report?.decision.headline ?? ""
        case .idle:
            let r = app.readiness
            if let b = r.blocking.first { return "Can't start: \(b)" }
            if let w = r.warnings.first { return "Ready, but \(w)" }
            if let a = app.activeProfile { return "Active profile: \(a.config.label) · \(a.headline)" }
            return "Measures llama.cpp's defaults and the best alternatives; keeps only proven wins. ⌘↩ to start."
        }
    }
}

struct GoButton: View {
    @Environment(AppModel.self) private var app
    @State private var hover = false

    var body: some View {
        let running = app.phase == .running
        let blocked = !running && !app.readiness.blocking.isEmpty
        Button {
            running ? app.cancelTune() : app.startTune()
        } label: {
            Image(systemName: running ? "stop.fill" : "arrow.up")
                .font(.system(size: running ? 10 : 12, weight: .bold))
                .foregroundStyle(blocked ? Theme.tertiary : Color.black.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(blocked ? Color.white.opacity(0.08) : (running ? Theme.text : Theme.accent).opacity(hover ? 1 : 0.92)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .onHover { hover = $0 }
        .help(running ? "Stop (⌘.)" : (blocked ? app.readiness.blocking.joined(separator: "\n") : "Tune (⌘↩)"))
    }
}

// MARK: - Chips and their menus

/// Anchors a floating menu above a chip without affecting layout.
struct MenuAnchor<Menu: View>: ViewModifier {
    var open: Bool
    var trailing = false
    @ViewBuilder var menu: () -> Menu

    func body(content: Content) -> some View {
        // Bottom edges aligned, then lifted by the chip's height plus a gap: the menu floats above the chip.
        content.overlay(alignment: trailing ? .bottomTrailing : .bottomLeading) {
            if open {
                menu()
                    .fixedSize()
                    .offset(y: -(24 + 10))
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: trailing ? .bottomTrailing : .bottomLeading)))
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.12), value: open)
    }
}

extension View {
    func menu<M: View>(_ open: Bool, trailing: Bool = false, @ViewBuilder _ menu: @escaping () -> M) -> some View {
        modifier(MenuAnchor(open: open, trailing: trailing, menu: menu))
    }
}

extension AppModel {
    func toggle(_ m: MenuID) { openMenu = openMenu == m ? nil : m }
}

struct SystemChip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let r = app.readiness
        let color = !r.blocking.isEmpty ? Theme.bad : (r.warnings.isEmpty ? Theme.good : Theme.warn)
        let power = app.system.power
        Chip(isOpen: app.openMenu == .system, action: { app.toggle(.system) }) {
            Circle().fill(color).frame(width: 6, height: 6)
            Image(systemName: power.source == .battery ? "battery.75percent" : "bolt.fill").font(.system(size: 10))
            Text(power.source == .battery ? "\(power.batteryPercent ?? 0)%" : "AC")
        }
        .menu(app.openMenu == .system) { SystemMenu() }
        .help("Machine readiness")
    }
}

struct SystemMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let r = app.readiness
        let s = app.system
        MenuPanel(width: 320) {
            MenuSectionLabel(text: "This Mac")
            InfoRow(label: "Machine", value: "\(app.hardware.machineModel ?? "Mac") · \(app.hardware.cpuBrand)")
            InfoRow(label: "Memory", value: "\(formatBytes(app.hardware.memoryBytes)) · GPU budget \(app.hardware.gpus.first?.recommendedMaxWorkingSetBytes.map(formatBytes) ?? "?")")
            InfoRow(label: "Power", value: s.power.source == .battery ? "Battery \(s.power.batteryPercent ?? 0)%\(s.power.lowPowerMode ? " · Low Power" : "")" : "Plugged in")
            InfoRow(label: "Thermal", value: s.thermal.rawValue.capitalized)
            if let m = s.memory {
                InfoRow(label: "Free memory", value: "~\(formatBytes(m.availableEstimateBytes)) · pressure \(m.pressure.rawValue)")
            }
            MenuDivider()
            MenuSectionLabel(text: "Runtime")
            if let inst = app.installation {
                InfoRow(label: "llama.cpp", value: "build \(inst.buildNumber.map(String.init) ?? "?")")
                if let t = inst.backendFacts?["metal.has_tensor"] {
                    InfoRow(label: "Neural Accelerators", value: t == "true" ? "on (tensor API)" : "off")
                }
                InfoRow(label: "Path", value: inst.executable, mono: true)
            } else {
                Text("llama.cpp isn't installed (or not found).").font(Theme.small).foregroundStyle(Theme.secondary).padding(.horizontal, 10)
                MenuRow(icon: "doc.on.doc", title: "Copy install command", subtitle: "brew install llama.cpp") {
                    app.copy("brew install llama.cpp")
                }
            }
            if !r.blocking.isEmpty || !r.warnings.isEmpty {
                MenuDivider()
                ForEach(r.blocking, id: \.self) { Notice(text: $0, color: Theme.bad) }
                ForEach(r.warnings, id: \.self) { Notice(text: $0, color: Theme.warn) }
            }
        }
    }
}

struct InfoRow: View {
    var label: String
    var value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.small).foregroundStyle(Theme.tertiary).frame(width: 118, alignment: .leading)
            Text(value).font(mono ? Theme.monoSmall : Theme.small).foregroundStyle(Theme.secondary)
                .lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 2.5)
    }
}

struct Notice: View {
    var text: String
    var color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(color).frame(width: 5, height: 5).padding(.top, 5)
            Text(text).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
    }
}

struct ModelChip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Chip(isOpen: app.openMenu == .model, action: { app.toggle(.model) }) {
            Image(systemName: "cube").font(.system(size: 10))
            Text(shortened(app.modelDisplayName, 30)).lineLimit(1)
            if let q = app.model?.quantization, !app.modelDisplayName.localizedCaseInsensitiveContains(q) {
                Text(q).foregroundStyle(Theme.tertiary)
            }
        }
        .menu(app.openMenu == .model) { ModelMenu() }
    }
}

struct ModelMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        MenuPanel(width: 360) {
            MenuSectionLabel(text: "Models on this Mac")
            if app.library.isEmpty {
                Text("No GGUF models found in ~/Models, LM Studio, Ollama or the llama.cpp cache.")
                    .font(Theme.small).foregroundStyle(Theme.tertiary).padding(.horizontal, 10).padding(.vertical, 4)
            }
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(app.library) { m in
                        MenuRow(icon: "cube", title: m.displayName,
                                subtitle: "\(formatBytes(m.sizeBytes)) · \(m.source)\(m.splitParts.map { " · \($0) parts" } ?? "")",
                                selected: m.url == app.selectedURL) {
                            app.select(m.url)
                            app.openMenu = nil
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            MenuDivider()
            MenuRow(icon: "folder", iconColor: Theme.secondary, title: "Choose a GGUF file…") {
                app.openMenu = nil
                app.chooseModelFile()
            }
            MenuRow(icon: "arrow.clockwise", iconColor: Theme.secondary, title: "Rescan folders") { app.refreshLibrary() }
            if let m = app.model {
                MenuDivider()
                InfoRow(label: "Weights", value: "\(formatBytes(m.weightBytes)) · \(m.quantization ?? "?")")
                InfoRow(label: "Layers", value: "\(m.blockCount.map(String.init) ?? "?") · trained for \(m.trainedContextLength.map { "\($0 / 1024)k" } ?? "?") tokens")
            } else if let e = app.modelError {
                Notice(text: e, color: Theme.bad)
            }
        }
    }
}

struct ContextChip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Chip(isOpen: app.openMenu == .context, action: { app.toggle(.context) }) {
            Image(systemName: "text.alignleft").font(.system(size: 10))
            Text(app.contextTokens == 0 ? "Empty chat" : "\(app.contextTokens / 1024)k context")
        }
        .menu(app.openMenu == .context) { ContextMenu() }
        .help("How much conversation is already in context while measuring")
    }
}

struct ContextMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let trained = app.model?.trainedContextLength ?? 32768
        let options: [(Int, String, String)] = [
            (0, "Empty chat", "Measures a fresh conversation"),
            (2048, "Short chat", "2k tokens already in context"),
            (8192, "Long chat or a few files", "8k tokens already in context"),
            (32768, "Very long context", "32k tokens already in context"),
        ].filter { $0.0 < trained }
        MenuPanel(width: 300) {
            MenuSectionLabel(text: "Measure with")
            ForEach(options, id: \.0) { o in
                let kv = o.0 > 0 ? app.model?.kvCacheBytesEstimate(contextTokens: o.0).map { " · KV cache ~\(formatBytes($0))" } ?? "" : ""
                MenuRow(icon: "text.alignleft", iconColor: Theme.secondary, title: o.1, subtitle: o.2 + kv, selected: app.contextTokens == o.0) {
                    app.contextTokens = o.0
                    app.openMenu = nil
                }
            }
            MenuDivider()
            Text("Longer contexts are slower per token and make flash attention matter more. Pick what your real chats look like.")
                .font(Theme.tiny).foregroundStyle(Theme.tertiary).padding(.horizontal, 10).padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GoalChip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Chip(isOpen: app.openMenu == .goal, action: { app.toggle(.goal) }) {
            Image(systemName: "asterisk").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
            Text(app.objective.title)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(Theme.tertiary)
        }
        .menu(app.openMenu == .goal, trailing: true) { GoalMenu() }
    }
}

struct GoalMenu: View {
    @Environment(AppModel.self) private var app

    static func icon(_ o: TuneObjective) -> String {
        switch o {
        case .generation: "text.bubble"
        case .response: "timer"
        case .balanced: "circle.lefthalf.filled"
        case .memory: "memorychip"
        }
    }

    var body: some View {
        @Bindable var app = app
        MenuPanel(width: 300) {
            MenuSectionLabel(text: "Optimize for")
            ForEach(TuneObjective.allCases, id: \.self) { o in
                MenuRow(icon: Self.icon(o), title: o.title, subtitle: o.summary, selected: false) {
                    app.objective = o
                    app.openMenu = nil
                } trailing: {
                    if app.objective == o {
                        Text("In use").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 5).frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                    }
                }
            }
            MenuDivider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow KV cache quantization").font(Theme.body).foregroundStyle(Theme.text)
                    Text("Saves memory at long context. Output can change slightly, so it's off unless you allow it.")
                        .font(Theme.tiny).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $app.allowKV).toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.accent)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }
}

struct BudgetChip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Chip(isOpen: app.openMenu == .budget, action: { app.toggle(.budget) }) {
            Image(systemName: app.budget == .thorough ? "bolt.fill" : "gauge.with.dots.needle.33percent").font(.system(size: 10))
            Text(app.budget.title)
        }
        .menu(app.openMenu == .budget, trailing: true) { BudgetMenu() }
        .help("How long to measure")
    }
}

struct BudgetMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        MenuPanel(width: 290) {
            MenuSectionLabel(text: "Measurement budget")
            Segmented(options: [(.quick, "Quick", nil), (.standard, "Standard", nil), (.thorough, "Thorough", "bolt.fill")],
                      selection: $app.budget)
                .padding(.horizontal, 8).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                let b = app.budget
                Text("\(b.dimensions.count) settings screened · up to \(b.maxCandidates) candidates")
                Text("Winner verified on \(b.validationRounds) fresh rounds against the defaults")
                Text(b == .quick ? "Finds big wins fast; small gains may go undetected."
                     : b == .standard ? "Good default: detects gains of a few percent."
                     : "Narrowest confidence intervals. Best for big models you use daily.")
                    .foregroundStyle(Theme.tertiary)
            }
            .font(Theme.small).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Idle

struct IdleHints: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 10) {
            if let a = app.activeProfile {
                ActiveProfileStrip(profile: a)
            }
            HStack(spacing: 10) {
                HintTile(icon: "scope", title: "Screen", text: "Each setting is swept in one process, next to the default.")
                HintTile(icon: "line.3.horizontal.decrease", title: "Narrow", text: "Promising combinations race the defaults, in shuffled order.")
                HintTile(icon: "checkmark.seal", title: "Verify", text: "The winner must beat the defaults again on fresh runs, by ≥ 2%.")
            }
        }
        .padding(.top, 6)
    }
}

struct HintTile: View {
    var icon: String
    var title: String
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            Text(text).font(Theme.small).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct ActiveProfileStrip: View {
    @Environment(AppModel.self) private var app
    var profile: TuningProfile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Active: \(profile.config.label)").font(Theme.body).foregroundStyle(Theme.text)
                Text(profile.headline).font(Theme.tiny).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer()
            PillButton(title: "Copy server command", icon: "doc.on.doc") {
                if let c = app.serverCommand(for: profile.config) { app.copy(c, note: "llama-server command copied") }
            }
            PillButton(title: "Undo", icon: "arrow.uturn.backward") { app.rollback() }
        }
        .padding(.horizontal, 12).frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Middle-truncates long names ("Qwen3-Coder-30B…Q4_K_M") so both ends stay readable.
func shortened(_ s: String, _ max: Int) -> String {
    guard s.count > max else { return s }
    let head = s.prefix(max / 2), tail = s.suffix(max - max / 2 - 1)
    return "\(head)…\(tail)"
}
