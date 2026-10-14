import SwiftUI
import WovenCore

struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRestore = false
    @State private var confirmSteamUpdate = false
    @State private var engineVersion: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            if let update = model.availableUpdate {
                Section {
                    updateBanner(update)
                }
            }

            Section {
                headline
            }

            Section("Setup") {
                step(done: model.runner != nil,
                     title: "Engine",
                     detail: model.runner.map { "\($0.id) · \($0.manifest.wine ?? "")" }
                        ?? (model.engineBuilt ? "Built locally, not installed yet" : "Downloads the latest release (about 300 MB)")) {
                    Button(model.runner == nil ? "Install" : "Reinstall") { Task { await model.installEngine() } }
                }
                step(done: model.steam?.injection == .wovenGames,
                     title: "Steam Play in macOS Steam",
                     detail: steamDetail) {
                    if model.steam?.injection == .wovenGames {
                        if model.hookOutdated {
                            Button("Update Hook") { Task { await model.patchSteam() } }
                                .help("Installs the newer hook into Steam.app. Steam restarts if it is open.")
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

            if let builds = model.builds, model.steam?.installed == true {
                Section {
                    buildRow("Installed", builds.installed, builds)
                    if let pending = builds.pending { buildRow("Downloaded update", pending, builds) }
                    if builds.latestPublic != builds.installed { buildRow("Newest from Valve", builds.latestPublic, builds) }
                    if let beta = builds.latestBeta { buildRow("Newest beta", beta, builds) }
                    if model.canUpdateSteam, let newest = builds.latestPublic {
                        Button("Update Steam to \(newest)") { confirmSteamUpdate = true }
                            .buttonStyle(.bordered)
                    }
                } header: {
                    Text("Steam builds")
                } footer: {
                    Text(buildAdvice(builds)).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Checks") {
                ForEach(Array(model.checks.enumerated()), id: \.offset) { _, check in
                    CheckRow(check: check)
                }
            }

            Section("About") {
                LabeledContent("WovenGames", value: model.appVersion)
                LabeledContent("Engine", value: engineVersion ?? "unknown")
                LabeledContent("Updates") {
                    HStack {
                        Text(model.lastUpdateCheck.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet")
                            .foregroundStyle(.secondary)
                        if model.checkingForUpdates { ProgressView().controlSize(.small) }
                        Button("Check Now") { Task { await model.checkForUpdates(manual: true) } }
                            .disabled(model.checkingForUpdates)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Game recommendations")
                        Text("Known-good settings for games, fetched from GitHub")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh") { Task { await model.syncRecommendations() } }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.busy != nil)
        .navigationTitle("Status")
        .task(id: "\(model.runner?.id ?? "")|\(model.busy ?? "")") {
            // re-read when the engine changes or an action (install, update) ends
            let file = model.paths.engineVersionFile
            engineVersion = await Task.detached {
                (try? String(contentsOf: file, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
            }.value
        }
        .confirmationDialog("Update Steam?", isPresented: $confirmSteamUpdate) {
            Button("Update Steam") { Task { await model.updateSteam() } }
        } message: {
            Text("Steam quits, installs build \(model.builds?.latestPublic ?? ""), and starts again. WovenGames checks that the hook works on it, then keeps Steam on that build. This takes a few minutes; don't start a game meanwhile.")
        }
        .confirmationDialog("Restore Steam?", isPresented: $confirmRestore) {
            Button("Restore Steam", role: .destructive) { Task { await model.restoreSteam() } }
        } message: {
            Text("Removes the WovenGames hook from Steam.app and puts its original settings back. Windows games stop showing Install and Play until you patch again. Steam restarts if it is open.")
        }
    }

    @ViewBuilder private func buildRow(_ title: String, _ build: String?, _ report: SteamBuildReport) -> some View {
        if let build {
            let verdict = report.verdict(for: build)
            HStack {
                Image(systemName: verdict.isSafe ? "checkmark.circle.fill" : (verdict == .unchecked ? "questionmark.circle" : "xmark.octagon.fill"))
                    .foregroundStyle(verdict.isSafe ? .green : (verdict == .unchecked ? .orange : .red))
                Text(title)
                Spacer()
                Text("\(build) · \(verdict.label)").foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func buildAdvice(_ r: SteamBuildReport) -> String {
        if case .broken = r.verdict(for: r.installed) {
            return "The hook does not work on the installed Steam build. Restore Steam, or wait for a WovenGames update that supports it."
        }
        if let newest = r.latestPublic, newest != r.installed {
            return r.verdict(for: newest).isSafe
                ? (model.canUpdateSteam
                    ? "Steam \(newest) is checked. Update Steam installs it and keeps WovenGames working."
                    : "Steam \(newest) is checked. To update: turn off \"Keep Steam on this build\", restart Steam, then turn it back on.")
                : "Keep Steam on this build: WovenGames has not checked Steam \(newest) yet."
        }
        return "You are on Valve's newest Steam build."
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

    private func updateBanner(_ update: GitHubRelease) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("WovenGames \(update.version?.description ?? update.tag_name) is available\(update.prerelease ? " · Beta" : "")")
                    .font(.headline)
                Text("Installs the new engine, then replaces this app and reopens it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("What's New") {
                if let url = URL(string: update.html_url) { openURL(url) }
            }
            Button("Update") { Task { await model.installUpdate() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy != nil)
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
            } else {
                Button("Setup Assistant…") { model.showSetup = true }
                    .buttonStyle(.borderedProminent)
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
