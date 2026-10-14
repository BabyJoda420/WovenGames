// Games running right now, and stopping one that hangs.
//
// Each launch writes the run script's pid to launchers/<appid>/run.pid. Force Quit sends that
// script TERM, which is what Steam's Stop does: the script kills the game's Wine prefix and
// exits, and Steam sees the game end. If the script does not finish in time, the prefix's
// wineserver and the game's launcher are killed directly.

import Darwin
import Foundation

public struct GameSessions: Sendable {
    public var paths: Paths

    public init(paths: Paths = Paths()) { self.paths = paths }

    var launchers: URL { paths.support.appending(path: "launchers") }

    func pidFile(_ appID: String) -> URL { launchers.appending(path: "\(appID)/run.pid") }

    /// The run script's pid for a game, if it is still the run script.
    public func runScript(appID: String) -> pid_t? {
        let file = pidFile(appID)
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        // a stale file (the script was killed outright) can name a pid that now belongs to
        // another process, even another game's run script: the script writes the file after
        // it starts, so a process that started later is not the one that wrote it
        if let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           let started = Self.startTime(of: pid), started > written.addingTimeInterval(1) {
            return nil
        }
        // Steam starts the script as ".../compatibilitytools.d/wovengames-proton/./run"
        let command = Shell.capture("/bin/ps", ["-p", "\(pid)", "-o", "command="]).output
        return command.contains("/wovengames-proton/") || command.contains("compat_run") ? pid : nil
    }

    /// When a process started; nil when there is no such process.
    static func startTime(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }

    /// App IDs of games whose launch script is running.
    public func running() -> [String] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: launchers.path(percentEncoded: false))) ?? []
        return ids.filter { $0.allSatisfy(\.isNumber) && runScript(appID: $0) != nil }.sorted()
    }

    /// Stops a game the way Steam's Stop does, harder if that does not work.
    public func forceQuit(appID: String, prefix: URL, grace: TimeInterval = 30, log: @Sendable (String) -> Void = { _ in }) async {
        if let pid = runScript(appID: appID) {
            log("asking the game to stop")
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline, kill(pid, 0) == 0 {
                try? await Task.sleep(for: .milliseconds(300))
            }
            if kill(pid, 0) != 0 {
                log("stopped")
                return
            }
            log("the game did not stop; ending it")
        }
        // kill the prefix's Wine processes, then anything left from the game's launcher bundle
        if let runner = try? RunnerStore(paths: paths).current() {
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = prefix.path(percentEncoded: false)
            _ = Shell.capture(runner.server.path(percentEncoded: false), ["-k"], environment: env)
        }
        _ = Shell.capture("/usr/bin/pkill", ["-9", "-f", launchers.appending(path: "\(appID)/").path(percentEncoded: false)])
        if let pid = runScript(appID: appID) { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFile(appID))
        log("ended")
    }
}
