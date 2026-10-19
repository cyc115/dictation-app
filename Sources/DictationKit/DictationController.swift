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
    /// The mic a dictation with this preferred UID records from (tests fake it).
    var activeInput: (String) -> AudioInputDevice? = { AudioDevices.activeInput(preferredUID: $0) }
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
    private var local: LocalEngine?
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
    /// The last stopped dictation, while its text is still on the way.
    private var lastDelivery: Delivery?

    /// A stopped dictation on its way to the app. `send` can still be set until its text is in.
    private final class Delivery {
        var send: Bool
        var done = false
        init(send: Bool) { self.send = send }
    }

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
        switch ModelSpec(setup.speech) {
        case .local(let id):
            let model = MainActor.assumeIsolated { settings.localModel(id) }
            if let local { local.model = model } else { local = LocalEngine(model: model) }
            return local
        case .apple(let locale):
            speech.localeIdentifier = locale ?? "en-US"
            return speech
        case .openRouter, nil:
            guard let key = settings.openRouterKey, !key.isEmpty else { return nil }
            cloud.use(setup, apiKey: key, backupWhenSlow: settings.effectiveBackup)
            return cloud
        }
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
    private func finished(_ delivery: Delivery) {
        delivery.done = true
        if lastDelivery === delivery { lastDelivery = nil }
        finishing = max(finishing - 1, 0)
        onIdle()
    }

    func toggle() {
        if dictating { stop() } else { start() }
    }

    /// The mouse's Enter button: during a dictation, stop it and press Return once the text is
    /// in (send it). Right after a stop, while the text is still on the way, the same: Return
    /// waits for the text instead of sending without it. Otherwise just press Return.
    func enter() {
        if dictating { return stop(send: true) }
        if let delivery = lastDelivery, !delivery.done { delivery.send = true } else { injector.pressReturn() }
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
        polisher = settings.polishEnabled ? makePolish(setup) : nil
        polisher?.prepare()
        let archive = settings.keepRecordings ? archive : nil
        note = archive.map { _ in RecordingNote(polishModel: polisher?.backend.name) }
        engine.archive = archive
        engine.note = note
        setDictating(true)
        dictationStart = Date()
        let mic = activeInput(settings.microphoneUID)
        // A Bluetooth mic takes about a second to send audio: the pill shows the wait, and the start
        // sound waits for it too, so it means "talk now".
        let warmingUp = mic?.isBluetooth == true
        overlay.showListening(micName: mic?.name, warmingUp: warmingUp)
        var cuePending = warmingUp
        if !warmingUp { startCue() }
        engine.start(
            inputUID: settings.microphoneUID,
            backups: settings.intelligentMicSelection,
            onLevel: { [weak self] level in
                guard self?.dictating == true else { return }
                self?.overlay.setLevel(level)
            },
            onMic: { [weak self] event in
                guard let self, self.dictating else { return }
                switch event {
                case .live:
                    if cuePending { cuePending = false; self.startCue() }
                    self.overlay.micLive()
                case .noAudio:
                    self.overlay.micSilent()
                case .switched(let device):
                    // Mid-sentence, so no start sound: just mute, if that's on.
                    if cuePending { cuePending = false; self.startCue(sound: false) }
                    self.overlay.micSwitched(to: device.name)
                    self.settings.microphoneUID = device.uid  // the next dictation starts on it
                }
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
        let limit = settings.mode == .hold ? autoStopAfter.hold : autoStopAfter.toggle
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        autoStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
    }

    /// The start sound, then muting output (after the sound, so it isn't cut off).
    private func startCue(sound: Bool = true) {
        let sound = sound && settings.interactionSounds
        if sound { InteractionSound.start.play() }
        if settings.muteWhileDictating {
            let delay: TimeInterval = sound ? 0.25 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if self?.dictating == true { self?.muter.mute() }
            }
        }
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
        let note = self.note
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        guard let engine = engine else {
            overlay.hideUnlessMessage()
            return onIdle()
        }
        finishing += 1
        let delivery = Delivery(send: send)
        lastDelivery = delivery
        // Cloud models transcribe after you stop: keep the pill up ("working") until text arrives.
        let batch = engine.isBatch
        if batch { overlay.showProcessing() } else { overlay.hideUnlessMessage() }
        // A new dictation may start before this one is delivered.
        let setup = dictationSetup, polisher = self.polisher
        engine.stop(completion: { [weak self] text in
            let transcribed = ProcessInfo.processInfo.systemUptime - stoppedAt
            let transcribedBy = engine.lastAnswer
            note?.transcribed(seconds: transcribed)
            guard let self else { return }
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // With polish to come, the pill stays up until it's done: hiding it here and showing it
            // again for the polish made it blink.
            let polishing = polisher != nil && !raw.isEmpty
            if batch && !polishing { self.overlay.hideUnlessMessage() }
            self.insights.record(text: raw, duration: duration)
            self.deliver(raw, duration: duration, setup: setup, polisher: polisher, transcribed: transcribed,
                         transcribedBy: transcribedBy, note: note, delivery: delivery)
        }, failure: { [weak self] message in
            note?.transcribed(seconds: ProcessInfo.processInfo.systemUptime - stoppedAt)
            self?.overlay.showMessage(message, hideAfter: 5)
            self?.finished(delivery)
        })
    }

    func cancel() {
        guard dictating else { return }
        setDictating(false)
        autoStop?.cancel()
        autoStop = nil
        engine?.cancel()
        overlay.hide()
        muter.restore()
        if settings.interactionSounds { InteractionSound.cancel.play() }
        onIdle()
    }

    private func pressReturnSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + sendDelay) { [injector] in injector.pressReturn() }
    }

    private func deliver(_ raw: String, duration: TimeInterval, setup: DictationSetup, polisher: PolishService?,
                         transcribed: TimeInterval, transcribedBy: ModelAnswer?, note: RecordingNote?, delivery: Delivery) {
        guard !raw.isEmpty else { return finished(delivery) }
        if let polisher {
            overlay.showProcessing()
            let started = ProcessInfo.processInfo.systemUptime
            Task { [weak self] in
                guard let self = self else { return }
                let (polished, error, polishedBy) = await polisher.polishReporting(raw)
                let seconds = ProcessInfo.processInfo.systemUptime - started
                await MainActor.run {
                    self.overlay.hide()
                    self.history.add(text: polished, duration: duration, raw: raw, setup: setup.id, prompt: setup.prompt,
                                     transcribeSeconds: transcribed, polishSeconds: seconds,
                                     transcribedBy: transcribedBy, polishedBy: polishedBy)
                    self.injector.inject(polished)
                    if delivery.send { self.pressReturnSoon() }
                    // After typing it, so saving it adds nothing to your wait.
                    note?.polished(polished, seconds: seconds, error: error)
                    self.finished(delivery)
                }
            }
        } else {
            history.add(text: raw, duration: duration, setup: setup.id, transcribeSeconds: transcribed,
                        transcribedBy: transcribedBy)
            injector.inject(raw)
            if delivery.send { pressReturnSoon() }
            finished(delivery)
        }
    }
}
