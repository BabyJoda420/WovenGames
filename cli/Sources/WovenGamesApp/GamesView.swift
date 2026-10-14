import AppKit
import SwiftUI
import WovenCore

struct GamesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: InstalledGame.ID?
    /// read once per games refresh: reading every launch log on each redraw is slow with many games
    @State private var lastRuns: [InstalledGame.ID: LastRun] = [:]

    var body: some View {
        HSplitView {
            List(model.games, selection: $selection) { game in
                GameRow(game: game, lastRun: lastRuns[game.id])
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            .overlay {
                if model.games.isEmpty {
                    ContentUnavailableView("No Windows games installed",
                                           systemImage: "gamecontroller",
                                           description: Text("Install a Windows game in Steam; it runs through WovenGames automatically."))
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
        .onAppear {
            if selection == nil { selection = model.games.first?.id }
            showRequestedGame()
        }
        .task(id: model.generation) {
            let games = model.games
            lastRuns = await Task.detached {
                Dictionary(uniqueKeysWithValues: games.compactMap { g in SteamLibrary.lastRun(of: g).map { (g.id, $0) } })
            }.value
        }
        .onChange(of: model.games) { _, games in
            if selection == nil || !games.contains(where: { $0.id == selection }) { selection = games.first?.id }
            showRequestedGame()
        }
        .onChange(of: model.requestedGame) { _, _ in showRequestedGame() }
    }

    /// A notification asked for a game: select it once it is in the list, then clear the request.
    private func showRequestedGame() {
        guard let id = model.requestedGame, model.games.contains(where: { $0.id == id }) else { return }
        selection = id
        model.requestedGame = nil
    }
}

/// One game in the library list: cover, name, what it is doing and a problem marker.
private struct GameRow: View {
    @Environment(AppModel.self) private var model
    let game: InstalledGame
    let lastRun: LastRun?

    var body: some View {
        HStack(spacing: 10) {
            SteamArtImage(appID: game.appID, kinds: [.cover]) {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 51)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.body).lineLimit(2)
                subtitle.font(.caption).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let worst = model.launchFindings[game.appID]?.first, worst.severity >= .warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(worst.severity == .error ? .red : .orange)
                    .help(worst.title)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var subtitle: some View {
        if model.runningGames.contains(game.appID) {
            Text(["Playing", lastRun?.backend.map(Self.backendName)].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(Color.accentColor)
        } else if let run = lastRun, let played = Self.lastPlayed(run) {
            Text("Last played \(played)").foregroundStyle(.secondary)
        } else {
            Text("Not played yet").foregroundStyle(.secondary)
        }
    }

    /// "dxmt" → "DXMT", "d3dmetal" → "D3DMetal": the backend picker's label without its explanation
    static func backendName(_ raw: String) -> String {
        GameSettings.BackendChoice(rawValue: raw)?.label.components(separatedBy: " (").first ?? raw.uppercased()
    }

    /// A relative date ("2 days ago") when the run's start is known, else the date the log wrote.
    static func lastPlayed(_ run: LastRun) -> String? {
        let date = run.startEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? run.date.flatMap(parseLogDate)
        if let date {
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
        }
        return run.date
    }

    /// The launch script writes `date`'s default output, e.g. "Tue Oct 13 23:03:54 CEST 2026".
    static func parseLogDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return formatter.date(from: normalized)
    }
}

struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let game: InstalledGame
    @State private var settings = GameSettings()
    /// what the file holds; nil until loaded, so loading does not count as a change
    @State private var saved: GameSettings?
    @State private var detected: BackendDetection?
    @State private var recommended: GameSettings?
    @State private var lastRun: LastRun?
    @State private var saveError: String?
    @State private var confirmReset = false

    var body: some View {
        // reads model.launchFindings, which diagnose() refreshes after each run (generation bump)
        let findings = model.findings(for: game)
        VStack(spacing: 0) {
            GameHeader(game: game)
            actionRow
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Form {
                if !findings.isEmpty {
                    Section {
                        ForEach(findings) { finding in
                            ProblemCard(finding: finding, game: game, settings: $settings, confirmReset: $confirmReset)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                }

                Section("Graphics") {
                    if let recommended {
                        LabeledContent("WovenGames recommends") {
                            Text(recommended.summary)
                        }
                    }
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
                    TextField("Game arguments", text: $settings.gameArgs, prompt: Text(recommended?.gameArgs.isEmpty == false ? recommended!.gameArgs : "e.g. -dx11"))
                    Toggle("msync (faster thread synchronisation)", isOn: $settings.msync)
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
                    Text("Settings apply at the next launch from Steam. Your settings win over WovenGames' recommendations, and launch options set in Steam win over both.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .task {
            let loaded = GameSettings.load(appID: game.appID)
            saved = loaded
            settings = loaded
            recommended = GameSettings.recommended(appID: game.appID)
            let dir = game.installDir
            detected = await Task.detached { BackendDetector.detect(launchTarget: nil, installDir: dir) }.value
        }
        .task(id: model.generation) {
            let game = game
            lastRun = await Task.detached { SteamLibrary.lastRun(of: game) }.value
        }
        .onChange(of: settings) { _, new in
            guard let saved, new != saved else { return }
            do {
                try new.save(appID: game.appID)
                self.saved = new
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

    private var actionRow: some View {
        HStack(spacing: 12) {
            if model.runningGames.contains(game.appID) {
                Label("Playing", systemImage: "play.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Button("Force Quit", role: .destructive) { Task { await model.forceQuit(game) } }
                    .buttonStyle(.bordered)
                    .disabled(model.busy != nil)
            } else {
                Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.busy != nil)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file))
                Text("Launches through Steam").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The game's library hero image with its logo (or name) over the bottom-leading corner.
private struct GameHeader: View {
    let game: InstalledGame

    var body: some View {
        // the image fills a fixed box: laid out directly, its overflow would widen the box
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 170)
            .overlay {
                SteamArtImage(appID: game.appID, kinds: [.hero, .header]) {
                    Color.accentColor.opacity(0.25)
                }
            }
            .clipped()
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                SteamArtImage(appID: game.appID, kinds: [.logo], fill: false) {
                    Text(game.name)
                        .font(.title.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                        .lineLimit(2)
                }
                .frame(maxWidth: proxy.size.width * 0.6, maxHeight: 64, alignment: .bottomLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .padding(16)
        }
    }
}

/// One launch problem with its fix.
private struct ProblemCard: View {
    @Environment(AppModel.self) private var model
    let finding: LaunchFinding
    let game: InstalledGame
    @Binding var settings: GameSettings
    @Binding var confirmReset: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(finding.title).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let fix = finding.fix { fixView(fix) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var icon: (name: String, color: Color) {
        switch finding.severity {
        case .error: ("xmark.octagon.fill", .red)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .info: ("info.circle", .secondary)
        }
    }

    private var background: Color {
        switch finding.severity {
        case .error: .red.opacity(0.12)
        case .warning: .orange.opacity(0.12)
        case .info: .secondary.opacity(0.08)
        }
    }

    @ViewBuilder private func fixView(_ fix: LaunchFinding.Fix) -> some View {
        switch fix {
        case .resetPrefix:
            Button("Reset Prefix…", role: .destructive) { confirmReset = true }
                .disabled(model.busy != nil)
        case .installEngine:
            Button("Reinstall Engine") { Task { await model.installEngine() } }
                .disabled(model.busy != nil)
        case .launchOptions(let options):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(options)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(options, forType: .string)
                    }
                }
                Text("Paste into the game's Properties → General → Launch Options in Steam.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .switchBackend(let backend):
            Button("Use \(backend.label.components(separatedBy: " (").first ?? backend.rawValue)") {
                settings.backend = backend
            }
            .disabled(settings.backend == backend)
        case .openLaunchLog:
            Button("Open Launch Log") { model.open(game.runLog) }
        }
    }
}

// MARK: artwork

/// Steam library art, loaded off the main thread and kept for the app's lifetime.
private struct SteamArtImage<Placeholder: View>: View {
    let appID: String
    /// tried in order; the first one Steam has is shown
    let kinds: [SteamArt]
    var fill = true
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                if fill {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            } else if loaded || fill {
                placeholder()
            } else {
                // a logo still loading: no flash of the title it may replace
                Color.clear
            }
        }
        .task(id: key) {
            if let cached = ArtCache.shared.lookup(key) {
                image = cached.image
                loaded = true
                return
            }
            let result = await ArtCache.shared.load(appID: appID, kinds: kinds, key: key)
            image = result
            loaded = true
        }
    }

    private var key: String { appID + "|" + kinds.map(\.rawValue).joined(separator: ",") }
}

/// NSImage is not Sendable; these are created off the main thread and only read afterwards.
private struct ImageBox: @unchecked Sendable { let image: NSImage? }

@MainActor
private final class ArtCache {
    static let shared = ArtCache()
    /// by appID + kinds; a stored nil box means Steam has none of them
    private var entries: [String: ImageBox] = [:]
    /// by file URL, so two lookups resolving to the same file share one image
    private var byURL: [URL: ImageBox] = [:]

    func lookup(_ key: String) -> ImageBox? { entries[key] }

    func load(appID: String, kinds: [SteamArt], key: String) async -> NSImage? {
        // resolving the URL lists Steam's cache folder: off the main thread too
        let url = await Task.detached { kinds.lazy.compactMap { $0.url(appID: appID) }.first }.value
        var box = ImageBox(image: nil)
        if let url {
            if let known = byURL[url] {
                box = known
            } else {
                box = await Task.detached { ImageBox(image: NSImage(contentsOf: url)) }.value
                byURL[url] = box
            }
        }
        entries[key] = box
        return box.image
    }
}
