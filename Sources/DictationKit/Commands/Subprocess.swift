import Foundation

/// Runs a program with no shell (what you said can't become another command) and a time limit:
/// command scripts through uv, BetterDisplay's command line, the terminal that shows a fix.
enum Subprocess {
    /// How a run ended.
    struct Finished {
        var status: Int32
        var output: String
        var errors: String
        var timedOut: Bool
    }

    enum StartError: Error {
        case notInstalled
        case couldNotStart(String)
    }

    static let uvPaths = ["/opt/homebrew/bin/uv", NSHomeDirectory() + "/.local/bin/uv", "/usr/local/bin/uv"]

    /// Runs uv with `arguments` (and `environment` added), with a command's time limit.
    static func uv(_ arguments: [String], environment extra: [String: String] = [:],
                   timeout: TimeInterval = CommandMode.timeout) -> Result<Finished, StartError> {
        guard let uv = uvPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .failure(.notInstalled)
        }
        return run(uv, arguments, environment: extra, timeout: timeout)
    }

    /// Runs `executable` with `arguments` (and `environment` added, in `directory`); after `timeout`
    /// seconds it's killed and `timedOut` says so.
    static func run(_ executable: String, _ arguments: [String], environment extra: [String: String] = [:],
                    directory: URL? = nil, timeout: TimeInterval) -> Result<Finished, StartError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failure(.couldNotStart(error.localizedDescription))
        }
        let limit = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: limit)
        // Errors are read alongside, so a script that writes a lot of them can't block on a full pipe.
        var errorData = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async { errorData = errors.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        limit.cancel()
        return .success(Finished(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                                 errors: String(decoding: errorData, as: UTF8.self), timedOut: process.terminationReason == .uncaughtSignal))
    }
}
