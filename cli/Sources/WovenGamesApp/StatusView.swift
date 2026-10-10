import SwiftUI
import WovenCore

struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRestore = false

    var body: some View {
        Form {
            Section {
                headline
            }

            Section("Setup") {
                step(done: model.runner != nil,
                     title: "Engine",
                     detail: model.runner.map { "\($0.id) · \($0.manifest.wine ?? "")" }
                        ?? (model.engineBuilt ? "Built, not installed yet" : "Not built yet: run engine/scripts/build-all.sh")) {
                    Button(model.runner == nil ? "Install" : "Reinstall") { Task { await model.installEngine() } }
                        .disabled(!model.engineBuilt)
                }
                step(done: model.steam?.injection == .wovenGames,
                     title: "Steam Play in macOS Steam",
                     detail: steamDetail) {
                    if model.steam?.injection == .wovenGames {
                        if model.hookOutdated {
                            Button("Update Hook") { Task { await model.patchSteam() } }
                                .help("Installs the newer hook into Steam.app. Quits and you restart Steam.")
                        }
                        Button("Restore Steam…", role: .destructive) { confirmRestore = true }
                    } else {
                        Button("Patch Steam") { Task { await model.patchSteam() } }
                            .disabled(model.runner == nil || model.steam?.installed != true)
                    }
                }
                if model.steam?.injection == .wovenGames {
                    Toggle(isOn: Binding(
                        get: { model.steam?.pin == .onLaunchOnly || model.steam?.pin == .full },
                        set: { on in Task { await model.pin(on) } })
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep Steam on this build")
                            Text("A Steam update can break the hook until WovenGames supports the new build.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.busy != nil || !model.activity.isEmpty || model.error != nil {
                Section(model.busy ?? "Last action") {
                    if model.busy != nil { ProgressView().controlSize(.small) }
                    ForEach(Array(model.activity.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }

            Section("Checks") {
                ForEach(Array(model.checks.enumerated()), id: \.offset) { _, check in
                    CheckRow(check: check)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy != nil)
        .navigationTitle("Status")
        .confirmationDialog("Restore Steam?", isPresented: $confirmRestore) {
            Button("Restore Steam", role: .destructive) { Task { await model.restoreSteam() } }
        } message: {
            Text("Removes the WovenGames hook from Steam.app and puts its original settings back. Windows games stop showing Install and Play until you patch again. Steam is quit if it is running.")
        }
    }

    private var steamDetail: String {
        guard let steam = model.steam else { return "" }
        guard steam.installed else { return "Steam is not installed in /Applications" }
        let build = "build \(steam.clientBuild ?? "unknown")"
        switch steam.injection {
        case .wovenGames: return "Active · \(build)"
        case .notProton: return "NotProton is installed; patching takes it over · \(build)"
        case .other(let lib): return "Another tool is injected (\(lib)) · \(build)"
        case .none: return "Not patched · \(build)"
        }
    }

    @ViewBuilder private var headline: some View {
        HStack(spacing: 14) {
            Image(systemName: model.isReady ? "checkmark.seal.fill" : "wrench.and.screwdriver")
                .font(.system(size: 34))
                .foregroundStyle(model.isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isReady ? "Ready to play" : "A few steps left").font(.title2.bold())
                Text(model.isReady
                     ? "Windows games in Steam now show Install and Play. WovenGames is the default for every Windows-only game; another tool can still be chosen under a game's Properties → Compatibility."
                     : "Install the engine, then patch Steam. Patching needs App Management permission for WovenGames.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isReady {
                Button("Open Steam") { model.openSteam() }
            }
        }
        .padding(.vertical, 4)
    }

    private func step<Action: View>(done: Bool, title: String, detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
    }
}

struct CheckRow: View {
    let check: Check

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(check.title.trimmingCharacters(in: .whitespaces))
            Spacer()
            Text(check.detail).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private var symbol: String {
        switch check.level {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.level {
        case .ok: .green
        case .info: .secondary
        case .warn: .orange
        case .fail: .red
        }
    }
}
