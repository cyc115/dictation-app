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
    private var hotkey: HotkeyManager?
    private let speech = SpeechEngine()
    private let overlay = OverlayWindow()
    private let injector = TextInjector()
    private let polisher = PolishService()
    private var dictating = false

    private var polishEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "aiPolishEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "aiPolishEnabled")
            polishItem.state = newValue ? .on : .off
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        Permissions.requestAll { [weak self] granted in
            guard let self = self else { return }
            // HotkeyManager prompts for Accessibility itself when needed.
            self.hotkey = HotkeyManager(
                onPress: { [weak self] in self?.startDictation() },
                onRelease: { [weak self] in self?.stopDictation() }
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
        let hint = NSMenuItem(title: "Hold Fn to dictate — release to paste", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
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
        overlay.show(message: "Listening… release Fn to paste")
        speech.start(
            onPartial: { [weak self] text in
                DispatchQueue.main.async { self?.overlay.show(message: text) }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async { self?.overlay.show(message: "Error: \(message)") }
            }
        )
        // Safety: auto-stop after 90 seconds in case the key-up is missed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            if self?.dictating == true { self?.stopDictation() }
        }
    }

    func stopDictation() {
        guard dictating else { return }
        setDictating(false)
        overlay.hide()
        let raw = speech.stop().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if polishEnabled {
            overlay.show(message: "Polishing…")
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
