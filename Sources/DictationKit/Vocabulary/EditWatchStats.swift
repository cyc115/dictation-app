import Foundation

/// How the edit watcher has fared in each app: watches armed, readback probes that failed (the
/// app doesn't say what's in its box, so keystroke mode was used), and keystroke-mode give-ups.
/// Counts and app names only, in edit-watch.json.
final class EditWatchStats: ObservableObject {
    struct App: Codable, Equatable {
        var armed = 0
        var probesFailed = 0
        var gaveUp = 0
    }

    static let defaultFileURL = AppPaths.file("edit-watch.json")
    let fileURL: URL
    @Published private(set) var apps: [String: App]

    init(fileURL: URL = EditWatchStats.defaultFileURL) {
        self.fileURL = fileURL
        apps = JSONFile.read([String: App].self, from: fileURL) ?? [:]
    }

    func armed(in app: String) { change(app) { $0.armed += 1 } }
    func probeFailed(in app: String) { change(app) { $0.probesFailed += 1 } }
    func gaveUp(in app: String) { change(app) { $0.gaveUp += 1 } }

    private func change(_ app: String, _ update: (inout App) -> Void) {
        update(&apps[app, default: App()])
        JSONFile.save(apps, to: fileURL)
    }
}
