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
    private let speech = SpeechEngine()
    private let cloud = CloudEngine()
    /// Engine for the dictation in progress (chosen from Settings when it starts).
    private var engine: DictationEngine?
    private let overlay = OverlayWindow()
    private let injector = TextInjector()
    /// Kept across dictations: it holds the prewarmed session. Replaced when the setup's prompt changes.
    private var onDevicePolish = OnDevicePolish()
    /// This dictation's polish, chosen when it starts; nil when it isn't polished.
    private var polisher: PolishService?
    /// This dictation's setup, saved with it in History.
    private var dictationSetup = DictationSetup.onDevice
    /// The polish half of the current dictation's kept-recording JSON (nil unless Keep recordings is on).
    private var note: RecordingNote?
    private var dictating = false
    private var autoStop: DispatchWorkItem?
    private var dictationStart = Date()
    /// Set while a "type as you speak" dictation is running.
    private var streaming: StreamingOutput?
    private let settings = AppSettings.shared
    private let mainWindow = MainWindowController()
    private let muter = OutputMuter()
    /// Stopped dictations whose text hasn't been delivered yet (one can start before the last is polished).
    private var finishing = 0
    private let relaunch = AppRelaunch()
    private var bundleWatcher: BundleWatcher?
    private lazy var exclusion = ExclusionWatcher(excluded: settings.excludedApps)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Diagnostics.runIfRequested() { return }
        muter.restore()  // undo a mute left behind if the app quit mid-dictation
        defer { signalReady() }
        watchForNewBuild()
        applyAppearanceAndDock()
        buildMenu()
        installEditMenu()
        overlay.onCancel = { [weak self] in self?.cancelDictation() }
        overlay.onConfirm = { [weak self] in self?.stopDictation() }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        exclusion.onChange = { [weak self] in self?.updateStatusIcon(); self?.updateMenu() }
        exclusion.start()
        Permissions.requestAll { [weak self] granted in
            guard let self = self else { return }
            // HotkeyManager prompts for Accessibility itself when needed.
            let hotkey = HotkeyManager(hotkey: self.settings.hotkey, mode: self.settings.mode,
                                       mouseButton: self.settings.mouseButton)
            hotkey.enterButton = self.settings.effectiveEnterButton
            hotkey.onPress = { [weak self] in self?.startDictation() }
            hotkey.onRelease = { [weak self] in self?.stopDictation() }
            hotkey.onCancel = { [weak self] in self?.cancelDictation() }
            hotkey.onTap = { [weak self] in self?.toggleDictation() }
            hotkey.onEnter = { [weak self] in self?.injector.pressReturn() }
            hotkey.onEscape = { [weak self] in self?.cancelDictation() }
            hotkey.isRecording = { [weak self] in self?.dictating == true }
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
            if dictating { cancelDictation() }
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
        relaunch.isBusy = { [weak self] in self.map { $0.dictating || $0.finishing > 0 } ?? false }
        bundleWatcher = BundleWatcher(executable: executable) { [weak self] in self?.relaunch.updateInstalled() }
        bundleWatcher?.start()
    }

    /// A stopped dictation is done (delivered, empty or failed).
    private func finished() {
        finishing = max(finishing - 1, 0)
        relaunch.relaunchIfIdle()
    }

    private func setDictating(_ value: Bool) {
        dictating = value
        updateStatusIcon()
    }

    /// The on-device polisher for this prompt, reusing the kept one (and its prewarmed session) if it matches.
    private func onDevicePolish(instructions: String, wrap: Bool) -> PolishBackend {
        if onDevicePolish.instructions != instructions || onDevicePolish.wrap != wrap {
            onDevicePolish = OnDevicePolish(instructions: instructions, wrap: wrap)
        }
        return onDevicePolish
    }

    func startDictation() {
        guard !dictating else { return }
        let setup = settings.setup
        let archive = settings.keepRecordings ? RecordingArchive.shared : nil
        let engine: DictationEngine
        let key = settings.openRouterKey
        if setup.isCloud {
            guard let key, !key.isEmpty else {
                overlay.showMessage("Add your cloud API key in Settings to use \(setup.title)", hideAfter: 4)
                mainWindow.show(.settings)
                return
            }
            cloud.use(setup, apiKey: key, backupWhenSlow: settings.effectiveBackup)
            engine = cloud
        } else {
            speech.localeIdentifier = settings.localLanguage.rawValue
            engine = speech
        }
        self.engine = engine
        dictationSetup = setup
        // Load the polish model while you speak instead of after you stop.
        polisher = settings.polishEnabled && !settings.effectiveStreaming
            ? setup.polishService(apiKey: key, onDevice: onDevicePolish(instructions:wrap:))
            : nil
        polisher?.prepare()
        note = archive.map { _ in RecordingNote(polishModel: polisher?.backend.name) }
        engine.archive = archive
        engine.note = note
        setDictating(true)
        dictationStart = Date()
        overlay.showListening(micName: AudioDevices.activeInputName(preferredUID: settings.microphoneUID))
        if settings.interactionSounds { InteractionSound.start.play() }
        if settings.muteWhileDictating {
            // Let the start sound finish before silencing output.
            let delay: TimeInterval = settings.interactionSounds ? 0.25 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if self?.dictating == true { self?.muter.mute() }
            }
        }
        if settings.effectiveStreaming {
            streaming = StreamingOutput(
                // A held ⌘/⌥/⌃/⇧ would turn typed letters into shortcuts/capitals; Fn is harmless.
                canTypeNow: { [weak self] in
                    guard let hotkey = self?.hotkey else { return true }
                    return !(hotkey.held && hotkey.hotkey != .fn)
                },
                type: { [weak self] text in self?.injector.type(text) })
        } else {
            streaming = nil
        }
        let output = streaming
        engine.start(
            inputUID: settings.microphoneUID,
            onLevel: { [weak self] level in
                guard self?.dictating == true else { return }
                self?.overlay.setLevel(level)
            },
            onUtterance: output.map { output in { [weak self] chunk in
                guard self?.dictating == true else { return }
                output.utteranceFinished(chunk)
            } },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    guard self?.dictating == true else { return }
                    self?.overlay.showMessage(message)
                }
            }
        )
        // Safety: auto-stop in case the key-up (hold) or second tap (toggle) never comes,
        // so the mic can't stay open indefinitely.
        let limit: TimeInterval = settings.mode == .hold ? 90 : 300
        let work = DispatchWorkItem { [weak self] in self?.stopDictation() }
        autoStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
    }

    func toggleDictation() {
        if dictating { stopDictation() } else { startDictation() }
    }

    func stopDictation() {
        guard dictating else { return }
        setDictating(false)
        autoStop?.cancel()
        autoStop = nil
        muter.restore()
        if settings.interactionSounds { InteractionSound.stop.play() }
        let duration = Date().timeIntervalSince(dictationStart)
        let output = streaming
        streaming = nil
        let note = self.note
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        guard let engine = engine else {
            overlay.hideUnlessMessage()
            return relaunch.relaunchIfIdle()
        }
        finishing += 1
        // Cloud models transcribe after you stop: keep the pill up ("working") until text arrives.
        let batch = engine.isBatch
        if batch { overlay.showProcessing() } else { overlay.hideUnlessMessage() }
        engine.stop(completion: { [weak self] text in
            note?.transcribed(seconds: ProcessInfo.processInfo.systemUptime - stoppedAt)
            if batch { self?.overlay.hideUnlessMessage() }
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Insights.shared.record(text: raw, duration: duration)
            if let output = output {
                // Already typed as you spoke; finish the tail. No polish: it needs the whole text.
                output.finish(fullText: raw)
                if !raw.isEmpty { HistoryStore.shared.add(text: raw, duration: duration) }
                self?.finished()
            } else {
                self?.deliver(raw, duration: duration, note: note)
            }
        }, failure: { [weak self] message in
            note?.transcribed(seconds: ProcessInfo.processInfo.systemUptime - stoppedAt)
            self?.overlay.showMessage(message, hideAfter: 5)
            self?.finished()
        })
    }

    func cancelDictation() {
        guard dictating else { return }
        setDictating(false)
        autoStop?.cancel()
        autoStop = nil
        engine?.cancel()
        streaming = nil  // what's already typed stays; nothing more is added
        overlay.hide()
        muter.restore()
        if settings.interactionSounds { InteractionSound.cancel.play() }
        relaunch.relaunchIfIdle()
    }

    private func deliver(_ raw: String, duration: TimeInterval, note: RecordingNote?) {
        guard !raw.isEmpty else { return finished() }
        let setup = dictationSetup  // a new dictation may start before polish finishes
        if let polisher {
            overlay.showProcessing()
            let started = ProcessInfo.processInfo.systemUptime
            Task { [weak self] in
                guard let self = self else { return }
                let (polished, error) = await polisher.polishReporting(raw)
                let seconds = ProcessInfo.processInfo.systemUptime - started
                await MainActor.run {
                    self.overlay.hide()
                    HistoryStore.shared.add(text: polished, duration: duration, raw: raw,
                                            setup: setup.id, prompt: setup.prompt)
                    self.injector.inject(polished)
                    // After typing it, so saving it adds nothing to your wait.
                    note?.polished(polished, seconds: seconds, error: error)
                    self.finished()
                }
            }
        } else {
            HistoryStore.shared.add(text: raw, duration: duration, setup: setup.id)
            injector.inject(raw)
            finished()
        }
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
