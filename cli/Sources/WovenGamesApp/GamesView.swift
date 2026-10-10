import SwiftUI
import WovenCore

struct GamesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: InstalledGame.ID?

    var body: some View {
        HSplitView {
            List(model.games, selection: $selection) { game in
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                    Text(SteamLibrary.lastRun(of: game)?.backend.map { "last run: \($0)" } ?? "not played yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            .overlay {
                if model.games.isEmpty {
                    ContentUnavailableView("No Windows games installed",
                                           systemImage: "gamecontroller",
                                           description: Text("Install one from Steam after forcing WovenGames under Properties → Compatibility."))
                }
            }

            Group {
                if let game = model.games.first(where: { $0.id == selection }) {
                    GameDetailView(game: game).id(game.id)
                } else {
                    ContentUnavailableView("Select a game", systemImage: "sidebar.left")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Games")
        .onAppear { if selection == nil { selection = model.games.first?.id } }
        .onChange(of: model.games) { _, games in
            if selection == nil || !games.contains(where: { $0.id == selection }) { selection = games.first?.id }
        }
    }
}

struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let game: InstalledGame
    @State private var settings = GameSettings()
    @State private var detected: BackendDetection?
    @State private var lastRun: LastRun?
    @State private var saveError: String?
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.name).font(.title2.bold())
                    Text("App \(game.appID) · \(ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Graphics") {
                Picker("Backend", selection: $settings.backend) {
                    ForEach(GameSettings.BackendChoice.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Automatic would pick") {
                    if let detected {
                        Text("\(detected.backend.rawValue) (\(detected.api.rawValue))")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let run = lastRun, let backend = run.backend {
                    LabeledContent("Last run") {
                        Text("\(backend) · \(run.backendReason ?? "") · \(run.date ?? "")").textSelection(.enabled)
                    }
                }
                Toggle("Metal performance HUD (FPS)", isOn: $settings.metalHUD)
                Toggle("High resolution (Retina)", isOn: $settings.retina)
            }

            Section("Advanced") {
                Toggle("msync (faster thread synchronisation)", isOn: $settings.msync)
                if let problem = lastRun?.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let saveError {
                    Label(saveError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Button("Show Game Files") { model.reveal(game.installDir) }
                    Button("Open Launch Log") { model.open(game.runLog) }
                        .disabled(!FileManager.default.fileExists(atPath: game.runLog.path(percentEncoded: false)))
                    Button("Show Prefix") { model.reveal(game.prefix) }
                        .disabled(!FileManager.default.fileExists(atPath: game.prefix.path(percentEncoded: false)))
                    Spacer()
                    Button("Reset Prefix…", role: .destructive) { confirmReset = true }
                        .disabled(!FileManager.default.fileExists(atPath: game.prefix.path(percentEncoded: false)))
                }
            } footer: {
                Text("Settings apply at the next launch from Steam. Launch options set in Steam win over these.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            settings = GameSettings.load(appID: game.appID)
            lastRun = SteamLibrary.lastRun(of: game)
            let dir = game.installDir
            detected = await Task.detached { BackendDetector.detect(launchTarget: nil, installDir: dir) }.value
        }
        .onChange(of: settings) { _, new in
            do {
                try new.save(appID: game.appID)
                saveError = nil
            } catch {
                saveError = "Could not save: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Reset \(game.name)'s prefix?", isPresented: $confirmReset) {
            Button("Move Prefix to Trash", role: .destructive) { Task { await model.resetPrefix(of: game) } }
        } message: {
            Text("The game's Windows environment is rebuilt at the next launch. Saves that are not in Steam Cloud live in the prefix; the Trash keeps them until you empty it.")
        }
    }
}
