import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An app in which the hotkey and mouse button are left alone, e.g. a game that uses them.
/// The name is saved with the bundle ID so the list shows it even when the app is gone.
struct ExcludedApp: Codable, Hashable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    /// The app bundle at `url` (from Choose…); nil if it isn't one.
    init?(appAt url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        self.init(bundleID: id, name: name)
    }

    /// Apps with a window that are running now, by name, minus this app.
    static func running() -> [ExcludedApp] {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> ExcludedApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own else { return nil }
            return ExcludedApp(bundleID: id, name: app.localizedName ?? id)
        }
        return Set(apps).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Whether the app in front is one of the excluded apps. HotkeyManager's event tap asks on every
/// event, so the answer is worked out when apps switch, not then.
final class ExclusionWatcher {
    var excluded: [ExcludedApp] {
        didSet { update() }
    }
    /// The excluded app in front, if any; dictation shortcuts are paused while it's set.
    private(set) var pausedFor: ExcludedApp?
    var isPaused: Bool { pausedFor != nil }
    var onChange: () -> Void = {}
    private var frontmost: String?
    private var observer: NSObjectProtocol?

    init(excluded: [ExcludedApp]) {
        self.excluded = excluded
    }

    deinit {
        if let observer = observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func start() {
        let workspace = NSWorkspace.shared
        frontmostChanged(to: workspace.frontmostApplication?.bundleIdentifier)
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostChanged(to: app?.bundleIdentifier)
        }
    }

    func frontmostChanged(to bundleID: String?) {
        frontmost = bundleID
        update()
    }

    private func update() {
        let now = excluded.first { $0.bundleID == frontmost }
        guard now != pausedFor else { return }
        pausedFor = now
        onChange()
    }
}

// MARK: - View

/// Settings → Shortcuts: the excluded apps, with Add and Remove.
struct ExcludedAppsList: View {
    @ObservedObject var settings: AppSettings
    /// Listed when Settings opens and as apps launch or quit, not on every redraw (~10 ms with many apps).
    @State private var running: [ExcludedApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pause in these apps").font(.body.weight(.medium))
                    Text("While one of them is in front, the hotkey and mouse button are ignored and keep their normal action — e.g. in a game.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Menu("Add App") {
                    ForEach(running.filter { app in !settings.excludedApps.contains { $0.bundleID == app.bundleID } }) { app in
                        Button(app.name) { settings.exclude(app) }
                    }
                    Divider()
                    Button("Choose…") { chooseApps() }
                }
                .accessibilityIdentifier("setting.Pause in these apps")
                .fixedSize()
            }
            ForEach(settings.excludedApps) { app in
                HStack {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary)
                    Text(app.name)
                    Spacer()
                    Button { settings.include(app) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(app.name)")
                    .accessibilityIdentifier("excluded.remove." + app.bundleID)
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 3)
        .onTabShown {
            let now = ExcludedApp.running()
            if now != running { running = now }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))) { _ in
            running = ExcludedApp.running()
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        panel.urls.compactMap(ExcludedApp.init(appAt:)).forEach(settings.exclude)
    }
}
