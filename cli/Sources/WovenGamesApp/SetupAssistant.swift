import AppKit
import SwiftUI
import WovenCore

/// First-run walkthrough: Mac checks, engine, App Management permission, Steam patch.
/// Opens by itself until everything is ready; Window > Setup Assistant reopens it.
struct SetupAssistant: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable { case mac, engine, permission, steam }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    card(.mac, title: "Your Mac", done: macReady) { macStep }
                    card(.engine, title: "Install the engine", done: model.runner != nil) { engineStep }
                    card(.permission, title: "Allow WovenGames to update Steam", done: model.access == .granted) { permissionStep }
                    card(.steam, title: "Turn on Steam Play in macOS Steam", done: steamPatched) { steamStep }
                    if let busy = model.busy {
                        HStack { ProgressView().controlSize(.small); Text(busy) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.activity.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.activity.suffix(6).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .task { await model.checkAccess() }
    }

    // MARK: state

    private var current: Step {
        if !macReady { return .mac }
        if model.runner == nil { return .engine }
        if steamPatched { return .steam }
        if model.access != .granted { return .permission }
        return .steam
    }

    private var macReady: Bool {
        !model.checks.isEmpty
            && !model.checks.contains { ["Apple Silicon", "macOS", "Rosetta 2"].contains($0.title) && $0.level == .fail }
            && model.steam?.installed == true
    }

    private var steamPatched: Bool { model.steam?.injection == .wovenGames && !model.hookOutdated }

    // MARK: steps

    @ViewBuilder private var macStep: some View {
        ForEach(Array(model.checks.filter { ["Apple Silicon", "macOS", "Rosetta 2", "Free disk space"].contains($0.title) }.enumerated()), id: \.offset) { _, check in
            CheckRow(check: check)
        }
        if model.checks.contains(where: { $0.title == "Rosetta 2" && $0.level == .fail }) {
            Text("Windows games run through Rosetta 2. Install it in Terminal, then click Check Again:")
            commandBox("softwareupdate --install-rosetta --agree-to-license")
        }
        if model.steam?.installed != true {
            HStack {
                Text("Install Steam for Mac into /Applications and sign in once.")
                Spacer()
                Button("Get Steam") { model.open(URL(string: "https://store.steampowered.com/about/")!) }
            }
        }
    }

    @ViewBuilder private var engineStep: some View {
        Text(model.engineBuilt
             ? "Installs the engine you built in this repository."
             : "Downloads the WovenGames engine (about 300 MB). Apple's D3DMetal and Valve's Steam files are then fetched from their own servers and checked against known fingerprints.")
            .fixedSize(horizontal: false, vertical: true)
        Button(model.runner == nil ? "Install Engine" : "Reinstall") { Task { await model.installEngine() } }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy != nil)
    }

    @ViewBuilder private var permissionStep: some View {
        Group {
            Text(steamPatched
                 ? "Steam is already patched. WovenGames needs this to update the hook or restore Steam later, under **Privacy & Security → App Management**."
                 : "WovenGames adds its Steam Play hook to Steam.app. macOS asks you to allow that once, under **Privacy & Security → App Management**.")
                .fixedSize(horizontal: false, vertical: true)
            switch model.access {
            case .granted?:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied?:
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Click **Open Privacy & Security**.")
                    Text("2. Turn on **WovenGames** in the list (macOS may ask for your password).")
                    Text("3. Come back and click **Check Again**. If it still says not allowed, use **Quit & Reopen**: macOS applies the change when WovenGames restarts.")
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Privacy & Security") { model.openAppManagementSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Check Again") { Task { await model.checkAccess() } }
                    Button("Quit & Reopen") { model.relaunch() }
                }
            case .notWritable(let why)?:
                Label("Steam.app cannot be changed (\(why)). It may belong to another user: reinstall Steam from steampowered.com while signed in as yourself.",
                      systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Button("Check Again") { Task { await model.checkAccess() } }
            case .steamMissing?:
                Text("Install Steam first.").foregroundStyle(.secondary)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder private var steamStep: some View {
        if steamPatched {
            Label("Windows games in Steam now show Install and Play.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        } else {
            Text("Adds the hook to Steam.app and keeps Steam on this build. Steam quits if it is running; start it again afterwards.")
                .fixedSize(horizontal: false, vertical: true)
            Button(model.hookOutdated ? "Update Hook" : "Patch Steam") { Task { await model.patchSteam() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy != nil || model.runner == nil || model.access != .granted)
        }
    }

    // MARK: chrome

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 30)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up WovenGames").font(.title2.bold())
                Text("Play your Windows games from macOS Steam: four steps, a few minutes.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Check Again") { Task { await model.refresh(); await model.checkAccess() } }
                .disabled(model.busy != nil)
            Spacer()
            if model.isReady && !model.hookOutdated {
                Button("Open Steam") { model.openSteam(); dismiss() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }

    private func card<Content: View>(_ step: Step, title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        let active = step == current
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(done ? Color.green : (active ? Color.accentColor : Color.secondary.opacity(0.3)))
                        .frame(width: 26, height: 26)
                    if done {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                    } else {
                        Text("\(step.rawValue + 1)").font(.callout.bold()).foregroundStyle(active ? .white : .secondary)
                    }
                }
                Text(title).font(.headline).foregroundStyle(active || done ? .primary : .secondary)
                Spacer()
            }
            if active || (step == .mac && !done) || (step == .permission && model.access == .denied) {
                VStack(alignment: .leading, spacing: 10) { content() }
                    .padding(.leading, 36)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(active ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Color.accentColor.opacity(0.4) : .clear))
    }

    private func commandBox(_ command: String) -> some View {
        HStack {
            Text(command).font(.callout.monospaced()).textSelection(.enabled)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }
}
