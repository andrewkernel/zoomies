import AppKit
import SwiftUI
import ZoomiesKit

@main
struct ZoomiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Zoomies") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear { Snapshot.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Tune") {
                Button("Start Tune") { model.startTune() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Stop") { model.cancelTune() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Choose Model File…") { model.chooseModelFile() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Rescan Model Folders") { model.refreshLibrary() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Built by SwiftPM, the binary may start as a background process; make it a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Snapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop any benchmark process still running; nothing may outlive the app.
        ChildRegistry.shared.reapOrphans()
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.calmMotion) private var calmMotion = false
    @State private var benchPath = ""
    @State private var allowBattery = false
    @State private var minBattery = 30.0
    @State private var guardrail = 5.0
    @State private var folders: [String] = []

    var body: some View {
        Form {
            Section("Runtime") {
                HStack {
                    TextField("llama-bench", text: $benchPath, prompt: Text(app.installation?.executable ?? "Auto-detect"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { app.llamaBenchPath = benchPath }
                    Button("Choose…") { pickBench() }
                    Button("Auto") { benchPath = ""; app.llamaBenchPath = nil }
                }
                Text(app.installation.map { "Using build \($0.buildNumber.map(String.init) ?? "?") at \($0.executable)" }
                     ?? (app.runtimeError ?? "Not found. Install with: brew install llama.cpp"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Safety") {
                Toggle("Allow tuning on battery", isOn: $allowBattery)
                    .onChange(of: allowBattery) { _, v in app.allowBattery = v }
                Text("Battery results differ from plugged-in results and drain the battery.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Stop below battery level")
                    Slider(value: $minBattery, in: 10...80, step: 5).onChange(of: minBattery) { _, v in app.minBattery = Int(v) }
                    Text("\(Int(minBattery))%").monospacedDigit().frame(width: 40)
                }
                HStack {
                    Text("Guardrail for the other metric")
                    Slider(value: $guardrail, in: 1...15, step: 1).onChange(of: guardrail) { _, v in app.guardrail = v }
                    Text("\(Int(guardrail))%").monospacedDigit().frame(width: 40)
                }
                Text("Zoomies also stops on serious heat, critical memory pressure, more than 1 GiB of new swap, or a switch to battery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Model folders") {
                Text("Always scanned: ~/Models, LM Studio, Ollama, llama.cpp and Hugging Face caches.").font(.caption).foregroundStyle(.secondary)
                ForEach(folders, id: \.self) { f in
                    HStack {
                        Text(f).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { folders.removeAll { $0 == f }; app.extraFolders = folders } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { addFolder() }
            }
            Section("Appearance") {
                Toggle("Calm background (slow the swirl)", isOn: $calmMotion)
            }
            Section("Data") {
                HStack {
                    Text(AppPaths.database.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.database]) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .onAppear {
            benchPath = app.llamaBenchPath ?? ""
            allowBattery = app.allowBattery
            minBattery = Double(app.minBattery)
            guardrail = app.guardrail
            folders = app.extraFolders
        }
    }

    private func pickBench() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.message = "Choose a llama-bench executable"
        if p.runModal() == .OK, let u = p.url { benchPath = u.path; app.llamaBenchPath = u.path }
    }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        if p.runModal() == .OK, let u = p.url, !folders.contains(u.path) { folders.append(u.path); app.extraFolders = folders }
    }
}

/// Developer hook for checking the UI without screen-recording permission:
/// `ZOOMIES_SNAPSHOT=/path/out.png` saves an image of the app's own window
/// after a short delay; `ZOOMIES_SNAPSHOT_MENU=goal|model|context|budget|system`
/// opens that menu first; `ZOOMIES_SNAPSHOT_TUNE=<tune id>` shows a stored receipt.
/// Does nothing unless the variable is set.
enum Snapshot {
    @MainActor static var model: AppModel?

    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ZOOMIES_SNAPSHOT"] else { return }
        let menu = env["ZOOMIES_SNAPSHOT_MENU"]
        let tab = env["ZOOMIES_SNAPSHOT_TAB"]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                if let tab, let t = AppTab(rawValue: tab) { model?.tab = t }
                if let id = env["ZOOMIES_SNAPSHOT_TUNE"] { model?.openTune(id) }
                switch menu {
                case "goal": model?.openMenu = .goal
                case "model": model?.openMenu = .model
                case "context": model?.openMenu = .context
                case "budget": model?.openMenu = .budget
                case "system": model?.openMenu = .system
                default: break
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            if env["ZOOMIES_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }
}
