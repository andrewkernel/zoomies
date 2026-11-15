import SwiftUI
import ZoomiesKit

// MARK: - Live run

struct RunPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StageStepper(current: app.stage)
            HStack(alignment: .firstTextBaseline, spacing: 26) {
                LiveNumber(label: "generation", value: app.liveTG, unit: "tokens/s")
                LiveNumber(label: "prompt", value: app.livePP, unit: "tokens/s")
                Spacer()
                PillButton(title: "Stop", icon: "stop.fill") { app.cancelTune() }
            }
            Text(app.activity.isEmpty ? app.stageDetail : app.activity)
                .font(Theme.monoSmall).foregroundStyle(Theme.tertiary).lineLimit(1)
            if !app.screen.isEmpty || !app.narrowing.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(app.screen, id: \.dimension) { ScreenRow(result: $0) }
                        ForEach(Array(app.narrowing.enumerated()), id: \.offset) { _, st in
                            ForEach(st.candidates, id: \.label) { c in
                                HStack(spacing: 8) {
                                    Text("race").font(Theme.tiny).foregroundStyle(Theme.tertiary).frame(width: 96, alignment: .leading)
                                    Text(c.label).font(Theme.monoSmall).foregroundStyle(c.kept ? Theme.text : Theme.tertiary)
                                    Text(c.relativeScore.map { String(format: "%+.1f%%", $0 * 100) } ?? "n/a")
                                        .font(Theme.monoSmall).foregroundStyle(c.kept ? Theme.accent : Theme.tertiary)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

struct StageStepper: View {
    var current: TuneStageKind?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TuneStageKind.allCases, id: \.self) { k in
                let idx = TuneStageKind.allCases.firstIndex(of: k)!
                let cur = current.flatMap { TuneStageKind.allCases.firstIndex(of: $0) } ?? -1
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(idx < cur ? Theme.accent.opacity(0.7) : (idx == cur ? Theme.accent : Color.white.opacity(0.12)))
                            .frame(width: 7, height: 7)
                        if idx == cur { PulseRing() }
                    }
                    Text(k.title).font(Theme.small).foregroundStyle(idx <= cur ? Theme.text : Theme.tertiary)
                }
                if k != TuneStageKind.allCases.last {
                    Rectangle().fill(idx < cur ? Theme.accent.opacity(0.5) : Theme.hairline).frame(width: 28, height: 1)
                }
            }
        }
    }
}

struct PulseRing: View {
    @State private var on = false
    var body: some View {
        Circle().stroke(Theme.accent.opacity(on ? 0 : 0.6), lineWidth: 1)
            .frame(width: on ? 18 : 7, height: on ? 18 : 7)
            .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true } }
    }
}

struct LiveNumber: View {
    var label: String
    var value: Double?
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatTPS(value)).font(.system(size: 26, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: value)
                Text(unit).font(Theme.small).foregroundStyle(Theme.tertiary)
            }
            Text(label).font(Theme.tiny).foregroundStyle(Theme.tertiary)
        }
    }
}

struct ScreenRow: View {
    var result: ScreenResult

    var body: some View {
        HStack(spacing: 8) {
            Text(result.dimension.title).font(Theme.tiny).foregroundStyle(Theme.tertiary).frame(width: 96, alignment: .leading)
            ForEach(result.values, id: \.value) { v in
                HStack(spacing: 3) {
                    Text(v.value).foregroundStyle(v.kept ? Theme.text : Theme.secondary)
                    if v.isDefault {
                        Text("default").foregroundStyle(Theme.tertiary)
                    } else if let s = v.relativeScore {
                        Text(String(format: "%+.1f%%", s * 100)).foregroundStyle(v.kept ? Theme.accent : Theme.tertiary)
                    }
                }
                .font(Theme.monoSmall)
                .padding(.horizontal, 6).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(v.kept ? Theme.accent.opacity(0.12) : Color.white.opacity(0.04)))
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Receipt

struct ReceiptView: View {
    @Environment(AppModel.self) private var app
    var report: TuneReport

    var body: some View {
        let d = report.decision
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(d.kind)).font(.system(size: 14, weight: .semibold)).foregroundStyle(color(d.kind)).padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(d)).font(Theme.headline).foregroundStyle(Theme.text).lineLimit(2)
                    Text(subtitle).font(Theme.small).foregroundStyle(Theme.tertiary)
                }
                Spacer()
            }
            if d.kind == .improved {
                HStack(spacing: 6) {
                    ForEach(d.config.changedDimensions, id: \.self) { dim in
                        let def = report.screen.first { $0.dimension == dim }?.defaultValue ?? "default"
                        HStack(spacing: 4) {
                            Text(dim.title).foregroundStyle(Theme.tertiary)
                            Text(def).foregroundStyle(Theme.secondary)
                            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                            Text(d.config.value(dim) ?? "").foregroundStyle(Theme.accent)
                        }
                        .font(Theme.monoSmall).padding(.horizontal, 8).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                    }
                }
            }
            VStack(spacing: 8) {
                if let p = d.primary, let m = d.primaryMetric { ComparisonBar(label: m, comparison: p, minRelevant: report.request.objective == .memory ? 5 : 2) }
                if let s = d.secondary, let m = d.secondaryMetric { ComparisonBar(label: m, comparison: s, minRelevant: 2) }
            }
            VStack(alignment: .leading, spacing: 3) {
                // The bars already show both metrics; skip detail lines that repeat them.
                let shown = d.details.filter { line in
                    ![d.primaryMetric, d.secondaryMetric].compactMap { $0 }.contains { line.lowercased().hasPrefix($0.lowercased() + ":") }
                }
                ForEach(shown.prefix(3), id: \.self) { Text("· \($0)").font(Theme.small).foregroundStyle(Theme.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if d.kind == .improved, let p = app.reportProfile {
                    if app.activeProfile?.id == p.id {
                        PillButton(title: "Applied", icon: "checkmark", prominent: true) {}
                        PillButton(title: "Undo", icon: "arrow.uturn.backward") { app.rollback() }
                    } else {
                        PillButton(title: "Apply", icon: "bolt.fill", prominent: true) { app.apply(p) }
                    }
                }
                PillButton(title: "Copy llama-server command", icon: "doc.on.doc") {
                    if let c = app.serverCommand(for: d.config, modelPath: report.model.path) { app.copy(c, note: "llama-server command copied") }
                }
                Spacer()
                PillButton(title: "Details", icon: "list.bullet.rectangle") { app.showDetails = true }
                PillButton(title: "Tune again", icon: "arrow.clockwise") { app.reset() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var subtitle: String {
        let dur = formatDuration(report.finishedAt.timeIntervalSince(report.startedAt))
        return "\((report.model.fileName as NSString).deletingPathExtension) · \(report.request.objective.title) · \(report.request.budget.title) · \(report.processCount) processes in \(dur)"
    }

    private func title(_ d: TuneDecision) -> String {
        switch d.kind {
        case .improved:
            guard let p = d.primary else { return d.headline }
            return report.request.objective == .memory
                ? String(format: "%.0f%% less memory", p.relativePercent)
                : String(format: "%+.1f%% %@", p.relativePercent, d.primaryMetric ?? "")
        case .keepDefaults: return "Your defaults are already the fastest"
        case .incomplete: return d.headline
        }
    }

    private func icon(_ k: TuneDecision.Kind) -> String {
        switch k { case .improved: "bolt.fill"; case .keepDefaults: "checkmark.seal"; case .incomplete: "exclamationmark.triangle" }
    }

    private func color(_ k: TuneDecision.Kind) -> Color {
        switch k { case .improved: Theme.accent; case .keepDefaults: Theme.good; case .incomplete: Theme.warn }
    }
}

/// The confidence interval of a change, on a scale with zero and the relevance band marked.
struct ComparisonBar: View {
    var label: String
    var comparison: Comparison
    var minRelevant: Double

    var body: some View {
        let c = comparison
        let lo = c.ciLow.isFinite ? c.relativeCILowPercent : c.relativePercent
        let hi = c.ciHigh.isFinite ? c.relativeCIHighPercent : c.relativePercent
        let span = max(10, abs(lo), abs(hi), abs(c.relativePercent)) * 1.15
        HStack(spacing: 10) {
            Text(label.prefix(1).uppercased() + label.dropFirst()).font(Theme.small).foregroundStyle(Theme.secondary).frame(width: 150, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width
                let x = { (v: Double) -> CGFloat in CGFloat((v + span) / (2 * span)) * w }
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 4).clipShape(Capsule())
                    Rectangle().fill(Color.white.opacity(0.07))
                        .frame(width: x(minRelevant) - x(-minRelevant), height: 14).offset(x: x(-minRelevant))
                    Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: 16).offset(x: x(0))
                    Capsule().fill(barColor.opacity(0.85)).frame(width: max(3, x(hi) - x(lo)), height: 6).offset(x: x(lo))
                    Circle().fill(barColor).frame(width: 8, height: 8).offset(x: x(c.relativePercent) - 4)
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            Text(fmtComparison(c)).font(Theme.monoSmall).foregroundStyle(Theme.secondary).frame(width: 170, alignment: .trailing)
        }
        .help("Dot: measured change. Bar: 95% confidence interval. Shaded: ±\(Int(minRelevant))%, too small to count.")
    }

    private var barColor: Color {
        switch comparison.verdict {
        case .faster: Theme.accent
        case .slower: Theme.bad
        default: Theme.secondary
        }
    }
}

// MARK: - Details

struct DetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var report: TuneReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Receipts").font(Theme.title).foregroundStyle(Theme.text)
                Spacer()
                PillButton(title: "Done") { dismiss() }
            }
            .padding(16)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Decision") {
                        Text(report.decision.headline).font(Theme.body).foregroundStyle(Theme.text)
                        ForEach(report.decision.details, id: \.self) { Text("· \($0)").font(Theme.small).foregroundStyle(Theme.secondary) }
                    }
                    section("Workload") {
                        let w = report.workload
                        Text("pp\(w.promptTokens) + tg\(w.genTokens)\(w.depth > 0 ? " at \(w.depth) tokens of context" : ""), \(report.request.budget.repetitions) repetitions per process, seed \(report.request.seed)")
                            .font(Theme.monoSmall).foregroundStyle(Theme.secondary)
                        Text("llama.cpp build \(report.installation.buildNumber.map(String.init) ?? "?") · \(report.hardware.machineModel ?? "") \(report.hardware.cpuBrand)")
                            .font(Theme.monoSmall).foregroundStyle(Theme.tertiary)
                    }
                    section("Screen (each setting in one process, vs its default)") {
                        ForEach(report.screen, id: \.dimension) { r in
                            ScreenRow(result: r)
                            if let n = r.note { Text(n).font(Theme.tiny).foregroundStyle(Theme.tertiary).padding(.leading, 104) }
                        }
                    }
                    ForEach(Array(report.stages.enumerated()), id: \.offset) { i, st in
                        section("\(st.kind.title) \(st.kind == .narrow ? "round \(i + 1)" : "")") {
                            ForEach(st.candidates, id: \.label) { c in
                                HStack {
                                    Text(c.kept ? "kept" : "dropped").font(Theme.tiny).foregroundStyle(Theme.tertiary).frame(width: 56, alignment: .leading)
                                    Text(c.label).font(Theme.monoSmall).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(c.relativeScore.map { String(format: "%+.2f%% vs defaults", $0 * 100) } ?? "")
                                        .font(Theme.monoSmall).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                    }
                    if !report.warnings.isEmpty {
                        section("Notes") {
                            ForEach(report.warnings, id: \.self) { Text("· \($0)").font(Theme.small).foregroundStyle(Theme.tertiary) }
                        }
                    }
                }
                .padding(16)
                .textSelection(.enabled)
            }
        }
        .frame(width: 680, height: 560)
        .background(Theme.card)
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionLabel(text: title).padding(.horizontal, -10)
            content()
        }
    }
}

// MARK: - Profiles and history

struct ProfilesScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ListPage(title: "Profiles", subtitle: "Saved settings per model on this Mac. Zoomies never edits your own configs; it exports commands.") {
            if app.profiles.isEmpty {
                EmptyNote(text: "No profiles yet. Tune a model and the result is saved here.")
            }
            ForEach(app.profiles) { p in
                let active = activeID(for: p) == p.id
                HStack(spacing: 12) {
                    Image(systemName: active ? "bolt.fill" : "circle").font(.system(size: 10))
                        .foregroundStyle(active ? Theme.accent : Theme.tertiary).frame(width: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(p.modelName).font(Theme.body).foregroundStyle(Theme.text)
                            Text(p.config.label).font(Theme.monoSmall).foregroundStyle(Theme.secondary)
                        }
                        Text("\(p.headline) · \(p.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(Theme.tiny).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    Spacer()
                    PillButton(title: "Copy command", icon: "doc.on.doc") {
                        if let c = app.serverCommand(for: p.config, modelPath: p.modelPath) { app.copy(c, note: "llama-server command copied") }
                    }
                    if !active { PillButton(title: "Activate", icon: "bolt") { app.apply(p) } }
                }
                .padding(.horizontal, 14).frame(height: 56)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card.opacity(0.75)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(active ? Theme.accent.opacity(0.35) : Theme.hairline, lineWidth: 1))
            }
        }
    }

    private func activeID(for p: TuningProfile) -> UUID? {
        guard p.modelFingerprint == app.model?.quickFingerprint else { return nil }
        return app.activeProfile?.id
    }
}

struct HistoryScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ListPage(title: "History", subtitle: "Every tune, with its receipts. Benchmarks are kept in the local results database.") {
            if app.tunes.isEmpty { EmptyNote(text: "No tunes yet.") }
            ForEach(app.tunes) { t in
                Button { app.openTune(t.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: t.decision == "improved" ? "bolt.fill" : (t.decision == "keep_defaults" ? "checkmark.seal" : "exclamationmark.triangle"))
                            .font(.system(size: 10)).foregroundStyle(t.decision == "improved" ? Theme.accent : Theme.tertiary).frame(width: 14)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.headline).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                            Text("\((t.modelPath as NSString).lastPathComponent) · \(t.objective) · \(t.budget) · \(t.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(Theme.tiny).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card.opacity(0.75)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ListPage<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Theme.headline).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.tertiary).padding(.bottom, 10)
                content()
            }
            .frame(width: 700, alignment: .leading)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
    }
}

struct EmptyNote: View {
    var text: String
    var body: some View {
        Text(text).font(Theme.small).foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}
