import AppKit
import AVFoundation
import Speech
import ApplicationServices

// MARK: - Entry point
let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.run()

// MARK: - App delegate: menu bar + orchestration
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var polishItem: NSMenuItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var hintItem: NSMenuItem!
    private var hotkey: HotkeyManager?
    private let speech = SpeechEngine()
    private let overlay = OverlayWindow()
    private let injector = TextInjector()
    private let polisher = PolishService()
    private var dictating = false
    private var autoStop: DispatchWorkItem?
    private var dictationStart = Date()
    private let settings = AppSettings.shared
    private let mainWindow = MainWindowController()
    private let muter = OutputMuter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        muter.restore()  // undo a mute left behind if the app quit mid-dictation
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
            self.hotkey?.start()
            if !granted {
                DispatchQueue.main.async { Permissions.showInstructions() }
            }
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "🎙"
        let menu = NSMenu()
        hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.addItem(.separator())
        startItem = NSMenuItem(title: "Start dictation", action: #selector(startFromMenu), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
        stopItem = NSMenuItem(title: "Stop & paste", action: #selector(stopFromMenu), keyEquivalent: "")
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(stopItem)
        menu.addItem(.separator())
        polishItem = NSMenuItem(title: "AI polish (on-device)", action: #selector(togglePolish), keyEquivalent: "")
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
    @objc private func startFromMenu() { startDictation() }
    @objc private func stopFromMenu() { stopDictation() }

    private func setDictating(_ value: Bool) {
        dictating = value
        statusItem.button?.title = value ? "🔴" : "🎙"
        startItem.isEnabled = !value
        stopItem.isEnabled = value
    }

    func startDictation() {
        guard !dictating else { return }
        setDictating(true)
        dictationStart = Date()
        overlay.showListening()
        if settings.interactionSounds { InteractionSound.start.play() }
        if settings.muteWhileDictating {
            // Let the start sound finish before silencing output.
            let delay: TimeInterval = settings.interactionSounds ? 0.25 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if self?.dictating == true { self?.muter.mute() }
            }
        }
        speech.start(
            inputUID: settings.microphoneUID,
            onLevel: { [weak self] level in
                guard self?.dictating == true else { return }
                self?.overlay.setLevel(level)
            },
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
        overlay.hideUnlessMessage()
        muter.restore()
        if settings.interactionSounds { InteractionSound.stop.play() }
        let duration = Date().timeIntervalSince(dictationStart)
        speech.stop { [weak self] text in
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Insights.shared.record(text: raw, duration: duration)
            self?.deliver(raw, duration: duration)
        }
    }

    func cancelDictation() {
        guard dictating else { return }
        setDictating(false)
        autoStop?.cancel()
        autoStop = nil
        speech.cancel()
        overlay.hide()
        muter.restore()
        if settings.interactionSounds { InteractionSound.cancel.play() }
    }

    private func deliver(_ raw: String, duration: TimeInterval) {
        guard !raw.isEmpty else { return }
        if settings.polishEnabled {
            overlay.showProcessing()
            Task { [weak self] in
                guard let self = self else { return }
                let polished = await self.polisher.polish(raw)
                await MainActor.run {
                    self.overlay.hide()
                    HistoryStore.shared.add(text: polished, duration: duration)
                    self.injector.inject(polished)
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
