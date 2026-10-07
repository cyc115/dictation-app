import Foundation

/// Version stamped into Info.plist by build.sh:
/// 1.0.<commit count> (+"-dev" with uncommitted changes), the git commit, and the build time.
struct AppVersion {
    let version: String
    let commit: String
    let built: Date?

    static let current = AppVersion(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "dev"
        commit = info["CFBundleVersion"] as? String ?? "-"
        built = (info["DictationBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// "Version 1.0.25 (525e456)"
    var short: String { "Version \(version) (\(commit))" }

    /// "Version 1.0.25 (525e456) · built Oct 7, 1:05 AM"
    var long: String {
        guard let built = built else { return short }
        return short + " · built " + built.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
