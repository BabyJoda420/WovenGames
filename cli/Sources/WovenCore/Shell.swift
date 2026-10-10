// Running other programs

import Foundation

public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
    }

    /// Runs a program to completion and captures stdout and stderr together.
    @discardableResult
    public static func capture(_ executable: String, _ arguments: [String] = [],
                               environment: [String: String]? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return Result(status: -1, output: "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Runs a program with this process's terminal, optionally appending its output to a log.
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                           log: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let log {
            FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle
            process.standardError = handle
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
