import AppKit
import Combine
import os
import Sparkle

/// What Updates needs from Sparkle's updater; tests fake it.
protocol UpdaterBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

extension SPUUpdater: UpdaterBackend {}

/// App updates (Sparkle): reads the appcast scripts/release.sh attaches to every GitHub release
/// (Info.plist's `SUFeedURL`), and installs a newer release, checked against `SUPublicEDKey`.
///
/// Checks once a day. A found update never pops up on its own (a window taking focus would catch
/// the paste of a dictation): the menu and Settings › Updates offer it, and opening it shows
/// Sparkle's window. Relaunching into it waits for the dictation in progress, as `AppRelaunch` does.
final class Updates: NSObject, ObservableObject {
    static let log = Logger(subsystem: "com.mikechen.DictationApp", category: "updates")

    /// nil when not running as an installed app (tests, `swift run`): nothing to update.
    private(set) var backend: UpdaterBackend?
    /// The newer version found by a scheduled check, until it's opened.
    @Published private(set) var available: String?
    /// Last check, to show in Settings.
    @Published private(set) var lastChecked: Date?
    /// Runs when `available` changes (the menu shows it).
    var onChange: () -> Void = {}
    /// Holds Sparkle's relaunch until no dictation is running; set `isBusy` to the dictation's.
    let relaunch = AppRelaunch()

    init(backend: UpdaterBackend?) {
        self.backend = backend
        lastChecked = backend?.lastUpdateCheckDate
    }

    /// Sparkle for this app, if it's an installed .app; call `start()` once launch is done.
    static func live() -> Updates {
        let updates = Updates(backend: nil)
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", bundle.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return updates }
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: updates)
        updates.backend = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: updates)
        return updates
    }

    var isAvailable: Bool { backend != nil }

    func start() {
        guard let updater = backend as? SPUUpdater else { return }
        do {
            try updater.start()
        } catch {
            Self.log.error("updater didn't start: \(error.localizedDescription, privacy: .public)")
        }
        lastChecked = updater.lastUpdateCheckDate
    }

    var automaticallyChecks: Bool {
        get { backend?.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            backend?.automaticallyChecksForUpdates = newValue
        }
    }

    /// "Check for Updates…": Sparkle's window, with the update a scheduled check already found if there is one.
    func checkNow() {
        guard let backend, backend.canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        backend.checkForUpdates()
    }

    /// Call whenever a dictation finishes: installs an update that was waiting for it.
    func relaunchIfIdle() { relaunch.relaunchIfIdle() }

    /// Sparkle is about to quit the app to install: let it, unless a dictation is running.
    func shouldPostpone(install: @escaping () -> Void) -> Bool {
        guard relaunch.isBusy() else { return false }
        Self.log.info("update ready; installing after the dictation")
        relaunch.relaunch = install
        relaunch.updateInstalled()
        return true
    }

    func setAvailable(_ version: String?) {
        guard version != available else { return }
        available = version
        onChange()
    }

    func checked() { lastChecked = backend?.lastUpdateCheckDate ?? Date() }
}

extension Updates: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        shouldPostpone(install: installHandler)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        checked()
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never show a scheduled check's update by itself: `available` puts it in the menu instead.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        setAvailable(handleShowingUpdate ? nil : update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { setAvailable(nil) }

    func standardUserDriverWillFinishUpdateSession() { setAvailable(nil) }
}
