import AppKit
import AVFoundation
import Speech
import ApplicationServices

// MARK: - Entry point
public enum DictationAppMain {
    /// NSApplication holds its delegate weakly, so keep it alive here.
    private static var delegate: AppDelegate?

    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

// MARK: - App delegate: menu bar + orchestration
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var polishItem: NSMenuItem!
    private var hintItem: NSMenuItem!
    private var hotkey: HotkeyManager?
    private let overlay = OverlayWindow()
    private let injector = TextInjector()
    private let settings = AppSettings.shared
    private let mainWindow = MainWindowController()
    private let muter = OutputMuter()
    private lazy var dictation = DictationController(
        settings: settings, overlay: overlay, injector: injector, history: .shared, insights: .shared,
        archive: .shared, muter: muter)
    private let relaunch = AppRelaunch()
    private var bundleWatcher: BundleWatcher?
    private lazy var exclusion = ExclusionWatcher(excluded: settings.excludedApps)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Diagnostics.runIfRequested() { return }
        muter.restore()  // undo a mute left behind if the app quit mid-dictation
        HistoryStore.shared.backfillTimings(from: RecordingArchive.shared.infos)  // once
        defer { signalReady() }
        watchForNewBuild()
        applyAppearanceAndDock()
        buildMenu()
        installEditMenu()
        overlay.onCancel = { [weak self] in self?.dictation.cancel() }
        overlay.onConfirm = { [weak self] in self?.dictation.stop() }
        dictation.onDictatingChanged = { [weak self] in self?.updateStatusIcon() }
        dictation.onIdle = { [weak self] in self?.relaunch.relaunchIfIdle() }
        dictation.onMissingKey = { [weak self] _ in self?.mainWindow.show(.settings) }
        // A held ⌘/⌥/⌃/⇧ would turn typed letters into shortcuts/capitals; Fn is harmless.
        dictation.canTypeNow = { [weak self] in
            guard let hotkey = self?.hotkey else { return true }
            return !(hotkey.held && hotkey.hotkey != .fn)
        }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        exclusion.onChange = { [weak self] in self?.updateStatusIcon(); self?.updateMenu() }
        exclusion.start()
        Permissions.requestAll { [weak self] granted in
            guard let self = self else { return }
            // HotkeyManager prompts for Accessibility itself when needed.
            let hotkey = HotkeyManager(hotkey: self.settings.hotkey, mode: self.settings.mode,
                                       mouseButton: self.settings.mouseButton)
            hotkey.enterButton = self.settings.effectiveEnterButton
            hotkey.onPress = { [weak self] in self?.dictation.start() }
            hotkey.onRelease = { [weak self] in self?.dictation.stop() }
            hotkey.onCancel = { [weak self] in self?.dictation.cancel() }
            hotkey.onTap = { [weak self] in self?.dictation.toggle() }
            hotkey.onEnter = { [weak self] in self?.dictation.enter() }
            hotkey.onEscape = { [weak self] in self?.dictation.cancel() }
            hotkey.isRecording = { [weak self] in self?.dictation.dictating == true }
            hotkey.isPaused = { [weak self] in self?.exclusion.isPaused == true }
            self.hotkey = hotkey
            hotkey.start()
            if !granted {
                DispatchQueue.main.async { Permissions.showInstructions() }
            }
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.addItem(.separator())
        polishItem = NSMenuItem(title: "AI polish", action: #selector(togglePolish), keyEquivalent: "")
        polishItem.target = self
        menu.addItem(polishItem)
        menu.addItem(.separator())
        for (title, action, key) in [("Insights…", #selector(openHome), ""),
                                     ("History…", #selector(openHistory), "y"),
                                     ("Settings…", #selector(openSettings), ",")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: AppVersion.current.long, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: "Quit DictationApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateMenu()
    }

    private func updateMenu() {
        hintItem.title = exclusion.pausedFor.map { "Paused while \($0.name) is in front" } ?? settings.hint
        polishItem.state = settings.polishEnabled ? .on : .off
    }

    private func settingsChanged() {
        if let hotkey = hotkey, hotkey.hotkey != settings.hotkey || hotkey.mode != settings.mode {
            dictation.cancel()
            hotkey.hotkey = settings.hotkey
            hotkey.mode = settings.mode
        }
        hotkey?.mouseButton = settings.mouseButton
        hotkey?.enterButton = settings.effectiveEnterButton
        exclusion.excluded = settings.excludedApps
        applyAppearanceAndDock()
        updateMenu()
    }

    /// For scripts/perf.sh: write a timestamp once launch finishes, if asked to.
    private func signalReady() {
        guard let path = ProcessInfo.processInfo.environment["DICTATIONAPP_READY_FILE"] else { return }
        try? String(Date().timeIntervalSince1970).write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func applyAppearanceAndDock() {
        NSApp.appearance = settings.appearance.nsAppearance
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .accessory { NSApp.activate(ignoringOtherApps: true) }  // keep an open window in front
        }
    }

    /// Clicking the Dock icon opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.show(.home) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        muter.restore()
        HistoryStore.shared.flush()
    }

    /// Menu-bar apps have no main menu, so ⌘C / ⌘A / ⌘F wouldn't work in the window without this.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appItem.submenu?.addItem(NSMenuItem(title: "Quit DictationApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func openHome() { mainWindow.show(.home) }
    @objc private func openHistory() { mainWindow.show(.history) }
    @objc private func openSettings() { mainWindow.show(.settings) }
    @objc private func togglePolish() { settings.polishEnabled.toggle() }

    /// Waveform glyph matching the app icon; red while the mic is open, struck through while paused.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let dictating = dictation.dictating
        let symbol = exclusion.isPaused && !dictating ? "waveform.slash" : "waveform"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DictationApp")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image?.isTemplate = !dictating
        button.image = image
        button.contentTintColor = dictating ? .systemRed : nil
    }

    /// Relaunch into a build installed while this one runs (it would lose the mic otherwise).
    private func watchForNewBuild() {
        guard Bundle.main.bundleURL.pathExtension == "app", let executable = Bundle.main.executableURL else { return }
        relaunch.isBusy = { [weak self] in self?.dictation.isBusy ?? false }
        bundleWatcher = BundleWatcher(executable: executable) { [weak self] in self?.relaunch.updateInstalled() }
        bundleWatcher?.start()
    }
}

// MARK: - Permissions
enum Permissions {
    static func requestAll(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { micGranted in
            SFSpeechRecognizer.requestAuthorization { status in
                let speechGranted = (status == .authorized)
                let axGranted = AXIsProcessTrusted()
                DispatchQueue.main.async {
                    completion(micGranted && speechGranted && axGranted)
                }
            }
        }
    }

    static func showInstructions() {
        let alert = NSAlert()
        alert.messageText = "DictationApp needs 3 permissions"
        alert.informativeText = """
            1. Microphone — allowed via the system prompt at launch.
            2. Speech Recognition — allowed via the system prompt at launch.
               (If you denied either: System Settings → Privacy & Security → \
               Microphone / Speech Recognition → enable DictationApp, then relaunch.)
            3. Accessibility — System Settings → Privacy & Security → Accessibility → \
               enable DictationApp. Needed for the hotkey, the mouse buttons and pasting text.

            The mic opens only while you dictate. On-device is completely private; \
            cloud models send your audio to the cloud for transcription and polish.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
