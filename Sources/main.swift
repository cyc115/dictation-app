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
    private var hotkeyItems: [NSMenuItem] = []
    private var hotkey: HotkeyManager?
    private let speech = SpeechEngine()
    private let overlay = OverlayWindow()
    private let injector = TextInjector()
    private let polisher = PolishService()
    private var dictating = false
    private var autoStop: DispatchWorkItem?

    private var polishEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "aiPolishEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "aiPolishEnabled")
            polishItem.state = newValue ? .on : .off
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        overlay.onCancel = { [weak self] in self?.cancelDictation() }
        overlay.onConfirm = { [weak self] in self?.stopDictation() }
        Permissions.requestAll { [weak self] granted in
            guard let self = self else { return }
            // HotkeyManager prompts for Accessibility itself when needed.
            self.hotkey = HotkeyManager(
                hotkey: Hotkey.saved,
                onPress: { [weak self] in self?.startDictation() },
                onRelease: { [weak self] in self?.stopDictation() },
                onCancel: { [weak self] in self?.cancelDictation() }
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
        let hotkeyMenu = NSMenu()
        for key in Hotkey.allCases {
            let item = NSMenuItem(title: key.title, action: #selector(chooseHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            hotkeyMenu.addItem(item)
            hotkeyItems.append(item)
        }
        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)
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
        polishItem.state = polishEnabled ? .on : .off
        menu.addItem(polishItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DictationApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateHotkeyMenu()
    }

    private func updateHotkeyMenu() {
        let current = Hotkey.saved
        hintItem.title = "Hold \(current.shortName) to dictate — release to paste"
        for item in hotkeyItems {
            item.state = (item.representedObject as? String) == current.rawValue ? .on : .off
        }
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Hotkey(rawValue: raw) else { return }
        if dictating { cancelDictation() }
        Hotkey.saved = key
        hotkey?.hotkey = key
        updateHotkeyMenu()
    }

    @objc private func togglePolish() { polishEnabled = !polishEnabled }
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
        overlay.showListening()
        speech.start(
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
        // Safety: auto-stop after 90 seconds in case the key-up is missed.
        let work = DispatchWorkItem { [weak self] in self?.stopDictation() }
        autoStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    }

    func stopDictation() {
        guard dictating else { return }
        setDictating(false)
        autoStop?.cancel()
        autoStop = nil
        overlay.hideUnlessMessage()
        speech.stop { [weak self] text in
            self?.deliver(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func cancelDictation() {
        guard dictating else { return }
        setDictating(false)
        autoStop?.cancel()
        autoStop = nil
        speech.cancel()
        overlay.hide()
    }

    private func deliver(_ raw: String) {
        guard !raw.isEmpty else { return }
        if polishEnabled {
            overlay.showProcessing()
            Task { [weak self] in
                guard let self = self else { return }
                let polished = await self.polisher.polish(raw)
                await MainActor.run {
                    self.overlay.hide()
                    self.injector.inject(polished)
                }
            }
        } else {
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
