import SwiftUI
import WovenCore

/// Collects a problem report into a zip on the Desktop, then helps the user attach it to a GitHub issue.
struct ReportProblemView: View {
    @Environment(AppModel.self) private var model

    @State private var description = ""
    @State private var running = false
    /// true when the last Create Report attempt failed, so model.error belongs to it
    @State private var failed = false
    @State private var output: ProblemReport.Output?
    @State private var files: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let output {
                result(output)
            } else {
                form
            }

            if failed, let error = model.error {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("Report a problem")
                    .font(.title2.bold())
            }
            Text("WovenGames puts its logs, your game settings and details about this Mac into a zip on your Desktop. Your user name, home folder, Steam account and email addresses are removed first. Nothing is sent anywhere: you look it over and attach it to a GitHub issue yourself.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: form

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What happened?")
            TextEditor(text: $description)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 120)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Which game, what you did, and what you saw.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                }
                Button("Create Report") { Task { await createReport() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
    }

    private func createReport() async {
        running = true
        failed = false
        model.error = nil
        defer { running = false }
        guard let written = await model.writeProblemReport(description: description) else {
            failed = true
            return
        }
        let folder = written.folder
        files = await Task.detached { Self.relativeFiles(in: folder) }.value
        output = written
    }

    /// Regular files under `folder`, as sorted paths relative to it.
    nonisolated private static func relativeFiles(in folder: URL) -> [String] {
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            paths.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent)
        }
        return paths.sorted()
    }

    // MARK: result

    private func result(_ output: ProblemReport.Output) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Report saved to your Desktop")
                    .font(.headline)
                Text(output.zip.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            List(files, id: \.self) { file in
                Label(file, systemImage: "doc.text")
            }
            .listStyle(.bordered)
            .frame(maxHeight: 180)

            HStack(spacing: 8) {
                Button("Show in Finder") { model.reveal(output.zip) }
                Button("Look Inside") { model.open(output.folder) }
                Button("New Report") { reset() }
                Spacer()
                Button("Open GitHub Issue") { model.open(model.newIssueURL) }
                    .buttonStyle(.borderedProminent)
            }

            Text("On GitHub, drag the zip into the issue's text box.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reset() {
        output = nil
        files = []
        description = ""
        failed = false
    }
}
