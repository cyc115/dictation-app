import Foundation

/// One dictation at a time, from start to delivered text: picks the engine and polish from
/// Settings, shows the pill, mutes output, stops on its own if the stop never comes, types or
/// pastes the text, and saves it to History and Insights. A new dictation can start while the
/// last one is still being transcribed or polished (`finishing`).
///
/// Everything it touches is passed in, so tests can run start → stop → polish → paste with fake
/// engines and polish (`makeEngine`, `makePolish`) and a fake paste.
final class DictationController {
    let settings: AppSettings
    let overlay: OverlayWindow
    let injector: TextInjector
    let history: HistoryStore
    let insights: Insights
    let archive: RecordingArchive
    private let muter: OutputMuter

    /// The engine for a dictation with `setup` (nil: it can't run, e.g. no API key for a cloud model).
    lazy var makeEngine: (DictationSetup) -> DictationEngine? = { [unowned self] in self.appEngine(for: $0) }
    /// The polish for a dictation with `setup`.
    lazy var makePolish: (DictationSetup) -> PolishService = { [unowned self] setup in
        setup.polishService(apiKey: self.settings.openRouterKey, onDevice: self.onDevicePolish(instructions:wrap:))
    }
    /// Whether typed text would come out as typed now (false while a ⌘/⌥/⌃/⇧ hotkey is held).
    var canTypeNow: () -> Bool = { true }
    /// A cloud model was chosen without an API key.
    var onMissingKey: (DictationSetup) -> Void = { _ in }
    /// `dictating` changed (the menu-bar icon follows it).
    var onDictatingChanged: () -> Void = {}
    /// A dictation is completely done: text delivered, failed or cancelled (relaunch waits for this).
    var onIdle: () -> Void = {}
    /// Seconds before a dictation stops on its own: (hold, toggle).
    var autoStopAfter: (hold: TimeInterval, toggle: TimeInterval) = (90, 300)
    /// Wait between pasting the text and pressing Return, so the app has taken the paste first.
    var sendDelay: TimeInterval = 0.15

    private(set) var dictating = false
    /// Stopped dictations whose text hasn't been delivered yet.
    private(set) var finishing = 0
    var isBusy: Bool { dictating || finishing > 0 }

    private let speech = SpeechEngine()
    private let cloud = CloudEngine()
    /// Engine for the dictation in progress.
    private var engine: DictationEngine?
    /// Kept across dictations: it holds the prewarmed session. Replaced when the setup's prompt changes.
    private var onDevicePolish = OnDevicePolish()
    /// This dictation's polish, chosen when it starts; nil when it isn't polished.
    private var polisher: PolishService?
    /// This dictation's setup, saved with it in History.
    private var dictationSetup = DictationSetup.onDevice
    /// The polish half of the current dictation's kept-recording JSON (nil unless Keep recordings is on).
    private var note: RecordingNote?
    private var autoStop: DispatchWorkItem?
    private var dictationStart = Date()
    /// Set while a "type as you speak" dictation is running.
    private var streaming: StreamingOutput?

    init(settings: AppSettings, overlay: OverlayWindow, injector: TextInjector,
         history: HistoryStore, insights: Insights, archive: RecordingArchive, muter: OutputMuter = OutputMuter()) {
        self.settings = settings
        self.overlay = overlay
        self.injector = injector
        self.history = history
        self.insights = insights
        self.archive = archive
        self.muter = muter
    }

    /// The app's engines, set up for `setup`.
    private func appEngine(for setup: DictationSetup) -> DictationEngine? {
        guard setup.isCloud else {
            speech.localeIdentifier = settings.localLanguage.rawValue
            return speech
        }
        guard let key = settings.openRouterKey, !key.isEmpty else { return nil }
        cloud.use(setup, apiKey: key, backupWhenSlow: settings.effectiveBackup)
        return cloud
    }

    /// The on-device polisher for this prompt, reusing the kept one (and its prewarmed session) if it matches.
    private func onDevicePolish(instructions: String, wrap: Bool) -> PolishBackend {
        if onDevicePolish.instructions != instructions || onDevicePolish.wrap != wrap {
            onDevicePolish = OnDevicePolish(instructions: instructions, wrap: wrap)
        }
        return onDevicePolish
    }

    private func setDictating(_ value: Bool) {
        dictating = value
        onDictatingChanged()
    }

    /// A stopped dictation is done (delivered, empty or failed).
    private func finished() {
        finishing = max(finishing - 1, 0)
        onIdle()
    }

    func toggle() {
        if dictating { stop() } else { start() }
    }

    /// The mouse's Enter button: during a dictation, stop it and press Return once the text is
    /// in (send it); otherwise just press Return.
    func enter() {
        if dictating { stop(send: true) } else { injector.pressReturn() }
    }

    func start() {
        guard !dictating else { return }
        let setup = settings.setup
        guard let engine = makeEngine(setup) else {
            overlay.showMessage("Add your cloud API key in Settings to use \(setup.title)", hideAfter: 4)
            return onMissingKey(setup)
        }
        self.engine = engine
        dictationSetup = setup
        // Load the polish model while you speak instead of after you stop.
        polisher = settings.polishEnabled && !settings.effectiveStreaming ? makePolish(setup) : nil
        polisher?.prepare()
        let archive = settings.keepRecordings ? archive : nil
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
            streaming = StreamingOutput(canTypeNow: { [weak self] in self?.canTypeNow() ?? true },
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
        let limit = settings.mode == .hold ? autoStopAfter.hold : autoStopAfter.toggle
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        autoStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
    }

    /// `send`: press Return after the text is delivered (nothing is sent if no text came).
    func stop(send: Bool = false) {
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
            return onIdle()
        }
        finishing += 1
        // Cloud models transcribe after you stop: keep the pill up ("working") until text arrives.
        let batch = engine.isBatch
        if batch { overlay.showProcessing() } else { overlay.hideUnlessMessage() }
        // A new dictation may start before this one is delivered.
        let setup = dictationSetup, polisher = self.polisher
        engine.stop(completion: { [weak self] text in
            let transcribed = ProcessInfo.processInfo.systemUptime - stoppedAt
            note?.transcribed(seconds: transcribed)
            guard let self else { return }
            if batch { self.overlay.hideUnlessMessage() }
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.insights.record(text: raw, duration: duration)
            if let output = output {
                // Already typed as you spoke; finish the tail. No polish: it needs the whole text.
                output.finish(fullText: raw)
                if !output.typed.isEmpty, send { self.pressReturnSoon() }
                if !raw.isEmpty {
                    self.history.add(text: raw, duration: duration, setup: setup.id, transcribeSeconds: transcribed)
                }
                self.finished()
            } else {
                self.deliver(raw, duration: duration, setup: setup, polisher: polisher, transcribed: transcribed,
                             note: note, send: send)
            }
        }, failure: { [weak self] message in
            note?.transcribed(seconds: ProcessInfo.processInfo.systemUptime - stoppedAt)
            self?.overlay.showMessage(message, hideAfter: 5)
            self?.finished()
        })
    }

    func cancel() {
        guard dictating else { return }
        setDictating(false)
        autoStop?.cancel()
        autoStop = nil
        engine?.cancel()
        streaming = nil  // what's already typed stays; nothing more is added
        overlay.hide()
        muter.restore()
        if settings.interactionSounds { InteractionSound.cancel.play() }
        onIdle()
    }

    private func pressReturnSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + sendDelay) { [injector] in injector.pressReturn() }
    }

    private func deliver(_ raw: String, duration: TimeInterval, setup: DictationSetup, polisher: PolishService?,
                         transcribed: TimeInterval, note: RecordingNote?, send: Bool) {
        guard !raw.isEmpty else { return finished() }
        if let polisher {
            overlay.showProcessing()
            let started = ProcessInfo.processInfo.systemUptime
            Task { [weak self] in
                guard let self = self else { return }
                let (polished, error) = await polisher.polishReporting(raw)
                let seconds = ProcessInfo.processInfo.systemUptime - started
                await MainActor.run {
                    self.overlay.hide()
                    self.history.add(text: polished, duration: duration, raw: raw, setup: setup.id, prompt: setup.prompt,
                                     transcribeSeconds: transcribed, polishSeconds: seconds)
                    self.injector.inject(polished)
                    if send { self.pressReturnSoon() }
                    // After typing it, so saving it adds nothing to your wait.
                    note?.polished(polished, seconds: seconds, error: error)
                    self.finished()
                }
            }
        } else {
            history.add(text: raw, duration: duration, setup: setup.id, transcribeSeconds: transcribed)
            injector.inject(raw)
            if send { pressReturnSoon() }
            finished()
        }
    }
}
