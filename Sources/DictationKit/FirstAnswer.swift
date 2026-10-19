import Foundation

/// The first answer from a main model, or from a backup asked once the main one is late or failed,
/// within an optional deadline. The same plan as `UploadRace` (speech), in async form, for polish.
enum FirstAnswer {
    private enum Event<T: Sendable>: Sendable { case answer(T, byBackup: Bool), failed(Error), backupDue, timeUp }

    struct TimedOut: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { String(format: "No answer within %g s.", seconds) }
    }

    /// Runs `main`. `backup` is also run `backupAfter` seconds in (at once when 0), or as soon as
    /// `main` fails. The first success wins and the other is cancelled; if both fail, the first error
    /// is thrown; after `deadline` seconds, `TimedOut`. Returns the value, whether `backup` gave it,
    /// and whether `backup` was asked at all.
    static func race<T: Sendable>(main: @escaping @Sendable () async throws -> T,
                                  backup: (@Sendable () async throws -> T)? = nil, backupAfter: TimeInterval = 0,
                                  deadline: TimeInterval? = nil) async throws -> (value: T, byBackup: Bool, backupAsked: Bool) {
        return try await withThrowingTaskGroup(of: Event<T>.self) { group in
            defer { group.cancelAll() }  // the loser and the timers stop; a returned group waits for them
            group.addTask { do { return .answer(try await main(), byBackup: false) } catch { return .failed(error) } }
            if let deadline {
                group.addTask { try? await Task.sleep(for: .seconds(deadline)); return .timeUp }
            }
            var running = 1, backupAsked = false, firstError: Error?
            func askBackup() {
                guard let backup, !backupAsked else { return }
                backupAsked = true
                running += 1
                group.addTask { do { return .answer(try await backup(), byBackup: true) } catch { return .failed(error) } }
            }
            if backup != nil {
                if backupAfter <= 0 { askBackup() } else {
                    group.addTask { try? await Task.sleep(for: .seconds(backupAfter)); return .backupDue }
                }
            }
            for try await event in group {
                switch event {
                case .answer(let value, let byBackup):
                    return (value, byBackup, backupAsked)
                case .failed(let error):
                    running -= 1
                    firstError = firstError ?? error
                    askBackup()  // don't wait out the delay after a failure
                    if running == 0 { throw firstError! }
                case .backupDue:
                    askBackup()
                case .timeUp:
                    throw TimedOut(seconds: deadline ?? 0)
                }
            }
            throw firstError ?? CancellationError()  // cancelled from outside
        }
    }
}
