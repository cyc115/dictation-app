import Foundation
import OSLog

/// What the cloud calls did, in the system log: each request's model, HTTP status, seconds and
/// error, when a backup is asked and why, and which model's answer was used. Never the words you
/// dictated. Read it with:
///
///     log show --last 1d --info --predicate 'subsystem == "com.mikechen.DictationApp" AND category IN {"speech", "polish"}'
///
/// Errors (a failed request, even one whose race was already won) are kept longest; notices (a
/// backup asked, a slow answer) next; info (an answer on time) only for a few hours.
struct CloudLog {
    enum Level: Equatable { case info, notice, error }
    let write: (Level, String) -> Void

    func info(_ message: String) { write(.info, message) }
    func notice(_ message: String) { write(.notice, message) }
    func error(_ message: String) { write(.error, message) }

    /// The system log under the app's subsystem. Messages are public: they hold model names,
    /// statuses and API errors, no dictated text.
    static func system(_ category: String) -> CloudLog {
        let logger = Logger(subsystem: "com.mikechen.DictationApp", category: category)
        return CloudLog { level, message in
            switch level {
            case .info: logger.info("\(message, privacy: .public)")
            case .notice: logger.notice("\(message, privacy: .public)")
            case .error: logger.error("\(message, privacy: .public)")
            }
        }
    }

    static let speech = system("speech")
    static let polish = system("polish")

    /// "0.45 s", as every line writes a duration.
    static func seconds(_ value: TimeInterval) -> String { String(format: "%.2f s", value) }
}
