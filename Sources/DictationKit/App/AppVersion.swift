import Foundation

/// Version stamped into Info.plist by build.sh:
/// 1.0.<commit count> (+"-dev" with uncommitted changes), the git commit, the build time, and the
/// source folder it was built from.
struct AppVersion {
    let version: String
    let commit: String
    let built: Date?
    /// The repo it was built from: where command mode's "fix" works on a built-in command.
    let source: URL?

    static let current = AppVersion(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "dev"
        commit = info["CFBundleVersion"] as? String ?? "-"
        built = (info["DictationBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        source = (info["DictationSource"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// "Version 1.0.25 (525e456)"
    var short: String { "Version \(version) (\(commit))" }

    /// How the build time is written: "Oct 7, 1:05 AM" (here and in the sidebar).
    static let builtStyle: Date.FormatStyle = .dateTime.month(.abbreviated).day().hour().minute()

    /// "Version 1.0.25 (525e456) · built Oct 7, 1:05 AM"
    var long: String {
        guard let built = built else { return short }
        return short + " · built " + built.formatted(Self.builtStyle)
    }
}
