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
    /// "Backup model when slow" (on by default); one instance so a slow spell carries over.
    private let backup = AdaptiveBackup()
    /// Engine for the dictation in progress (chosen from Settings when it starts).
    private var engine: DictationEngine?
    private let overlay = OverlayWindow()
    private let injector = TextInjector()
    /// Kept across dictations: it holds the prewarmed session.
    private let onDevicePolish = OnDevicePolish()
    /// Chosen from Settings when a dictation starts.
    private var polisher = PolishService()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Diagnostics.runIfRequested() { return }
        muter.restore()  // undo a mute left behind if the app quit mid-dictation
        defer { signalReady() }
        applyAppearanceAndDock()
        buildMenu()
        installEditMenu()
        overlay.onCancel = { [weak self] in self?.cancelDictation() }
        overlay.onConfirm = { [weak self] in self?.stopDictation() }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        Permissions.requestAll { [weak self] granted in
            guard let self = self else { return }
            // HotkeyManager prompts for Accessibility itself when needed.
            self.hotkey = HotkeyManager(
                hotkey: self.settings.hotkey,
                mode: self.settings.mode,
                mouseButton: self.settings.mouseButton,
                onPress: { [weak self] in self?.startDictation() },
                onRelease: { [weak self] in self?.stopDictation() },
                onCancel: { [weak self] in self?.cancelDictation() },
                onTap: { [weak self] in self?.toggleDictation() }
            )
            self.hotkey?.isRecording = { [weak self] in self?.dictating == true }
            self.hotkey?.onEscape = { [weak self] in self?.cancelDictation() }
            self.hotkey?.start()
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
        hintItem.title = settings.hint
        polishItem.state = settings.polishEnabled ? .on : .off
    }

    private func settingsChanged() {
        if let hotkey = hotkey, hotkey.hotkey != settings.hotkey || hotkey.mode != settings.mode {
            if dictating { cancelDictation() }
            hotkey.hotkey = settings.hotkey
            hotkey.mode = settings.mode
        }
        hotkey?.mouseButton = settings.mouseButton
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

    /// Waveform glyph matching the app icon; red while the mic is open.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "DictationApp")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image?.isTemplate = !dictating
        button.image = image
        button.contentTintColor = dictating ? .systemRed : nil
    }

    private func setDictating(_ value: Bool) {
        dictating = value
        updateStatusIcon()
    }

    func startDictation() {
        guard !dictating else { return }
        let model = settings.transcriptionModel
        let archive = settings.keepRecordings ? RecordingArchive.shared : nil
        cloud.archive = archive
        speech.archive = archive
        let engine: DictationEngine
        if let modelID = model.openRouterID {
            guard let key = settings.openRouterKey, !key.isEmpty else {
                overlay.showMessage("Add your cloud API key in Settings to use \(model.title)", hideAfter: 4)
                mainWindow.show(.settings)
                return
            }
            cloud.modelID = modelID
            cloud.backup = settings.effectiveBackup ? backup : nil
            cloud.apiKey = key
            engine = cloud
        } else {
            speech.localeIdentifier = settings.localLanguage.rawValue
            engine = speech
        }
        self.engine = engine
        // Load the polish model while you speak instead of after you stop.
        if settings.polishEnabled && !settings.effectiveStreaming {
            polisher = PolishService(backend: settings.polishModel.backend(apiKey: settings.openRouterKey,
                                                                            onDevice: onDevicePolish))
            polisher.prepare()
        }
        let polishes = settings.polishEnabled && !settings.effectiveStreaming
        note = archive.map { _ in RecordingNote(polishEnabled: polishes, polishModel: polisher.backend.name) }
        cloud.note = note
        speech.note = note
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
        guard let engine = engine else { return overlay.hideUnlessMessage() }
        // Cloud models transcribe after you stop: keep the pill up ("working") until text arrives.
        let batch = engine.isBatch
        if batch { overlay.showProcessing() } else { overlay.hideUnlessMessage() }
        engine.stop(completion: { [weak self] text in
            if batch { self?.overlay.hideUnlessMessage() }
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Insights.shared.record(text: raw, duration: duration)
            if let output = output {
                // Already typed as you spoke; finish the tail. No polish: it needs the whole text.
                output.finish(fullText: raw)
                if !raw.isEmpty { HistoryStore.shared.add(text: raw, duration: duration) }
            } else {
                self?.deliver(raw, duration: duration, note: note)
            }
        }, failure: { [weak self] message in
            self?.overlay.showMessage(message, hideAfter: 5)
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
    }

    private func deliver(_ raw: String, duration: TimeInterval, note: RecordingNote?) {
        guard !raw.isEmpty else { return }
        if settings.polishEnabled {
            overlay.showProcessing()
            Task { [weak self] in
                guard let self = self else { return }
                let started = Date()
                let (polished, error) = await self.polisher.polishReporting(raw)
                await MainActor.run {
                    self.overlay.hide()
                    HistoryStore.shared.add(text: polished, duration: duration)
                    self.injector.inject(polished)
                    // After typing it, so saving it adds nothing to your wait.
                    note?.polished(polished, seconds: Date().timeIntervalSince(started), error: error)
                }
            }
        } else {
            HistoryStore.shared.add(text: raw, duration: duration)
            injector.inject(raw)
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
               enable DictationApp. Needed for the Fn hotkey and pasting text.

            The mic opens only while you hold Fn — never in the background — and \
            transcription runs 100% on-device. Nothing leaves your Mac.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
