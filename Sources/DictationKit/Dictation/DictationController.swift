import Foundation

/// One dictation at a time, from start to delivered text: picks the engine and polish from
/// Settings, shows the pill, mutes output, stops on its own if the stop never comes, types or
/// pastes the text, and saves it to History and Insights. A new dictation can start while the
/// last one is still being transcribed or polished (`finishing`).
///
/// A dictation can also be a command (`enter()` when nothing's in progress): its transcript goes
/// to `CommandMode`, which picks one of your commands and runs it, instead of being typed. What
/// differs by kind is in `DictationKind`.
///
/// Your vocabulary (`VocabularyStore`) fixes the terms the speech model mishears: replaced before
/// polish and again after, polish told the terms, and (Settings) the on-device speech models too.
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
    let commandMode: CommandMode
    let vocabulary: VocabularyStore
    private let muter: OutputMuter

    /// The engine for a dictation with `setup` (nil: it can't run, e.g. no API key for a cloud model).
    lazy var makeEngine: (DictationSetup) -> DictationEngine? = { [unowned self] in self.appEngine(for: $0) }
    /// The polish for a dictation with `setup`, told this vocabulary's terms.
    lazy var makePolish: (DictationSetup, Vocabulary) -> PolishService = { [unowned self] setup, vocabulary in
        setup.polishService(apiKey: self.settings.openRouterKey, vocabulary: vocabulary, onDevice: self.onDevicePolish(instructions:wrap:))
    }
    /// The mic a dictation with this preferred UID records from (tests fake it).
    /// The mics for a dictation, from the Microphone setting and whether Intelligent mic selection is
    /// on: `AudioDevices.pick`, once per start (tests swap it).
    var pickMics: (String, Bool) -> MicPick? = { AudioDevices.pick(preferredUID: $0, backups: $1) }
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
    /// Takes text back to the box it was dictated into, if you've moved on (Paste where you dictated).
    lazy var goBack = GoBack(injector: injector)
    /// *Learn from my edits*: armed after a plain paste of a dictation that isn't sent (nil: none, as in most tests).
    var editWatcher: EditWatcher?
    /// A second Enter this soon after the first started a command is a double-click: just Return.
    var doublePressWindow: TimeInterval = 0.35

    private(set) var dictating = false
    /// What the dictation in progress is for (text, between dictations).
    var kind: DictationKind { current?.kind ?? .text }
    /// Stopped dictations whose text hasn't been delivered yet.
    private(set) var finishing = 0
    var isBusy: Bool { dictating || finishing > 0 }

    private let speech = SpeechEngine()
    private let cloud = CloudEngine()
    private var local: LocalEngine?
    /// A dictation: what it's for and what was chosen for it when it started.
    struct Dictation {
        let kind: DictationKind
        let engine: DictationEngine
        /// Its setup, saved with it in History.
        let setup: DictationSetup
        /// Its polish; nil when it isn't polished.
        let polisher: PolishService?
        /// The vocabulary as it was when it started (none for a command, or with Use vocabulary off).
        let vocabulary: Vocabulary
        /// The polish half of its kept-recording JSON (nil unless Keep recordings is on).
        let note: RecordingNote?
        let started: Date
    }
    /// The dictation in progress.
    private var current: Dictation?
    /// Kept across dictations: it holds the prewarmed session. Replaced when the setup's prompt changes.
    private var onDevicePolish = OnDevicePolish()
    private var autoStop: DispatchWorkItem?
    /// The start sound (and mute) still to come, once a warming-up mic goes live.
    private var cuePending = false
    /// The last stopped dictation, while its text is still on the way.
    private var lastDelivery: Delivery?

    /// A stopped dictation on its way to the app. `send` can still be set until its text is in.
    private final class Delivery {
        var send: Bool
        var done = false
        init(send: Bool) { self.send = send }
    }

    init(settings: AppSettings, overlay: OverlayWindow, injector: TextInjector, history: HistoryStore, insights: Insights,
         archive: RecordingArchive, muter: OutputMuter, commandMode: CommandMode, vocabulary: VocabularyStore) {
        self.settings = settings
        self.vocabulary = vocabulary
        self.overlay = overlay
        self.injector = injector
        self.history = history
        self.insights = insights
        self.archive = archive
        self.muter = muter
        self.commandMode = commandMode
        self.commandMode.pressReturn = { [injector] in injector.pressReturn() }
        self.commandMode.typeText = { [injector] in injector.inject($0) }
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

    /// The dictation button (or a hotkey tap). Ignored during a command: the Enter button runs it.
    func toggle() {
        if dictating { if kind.stopsWithDictationButton { stop() } } else { start() }
    }

    /// The mouse's Enter button: during a dictation, stop it and press Return once the text is
    /// in (send it). Right after a stop, while the text is still on the way, the same: Return
    /// waits for the text instead of sending without it. During a command, run it. Otherwise
    /// start a command (or, with command mode off, just press Return); double-clicked, it presses
    /// Return instead of starting one.
    func enter() {
        if dictating, let current, current.kind == .command, Date().timeIntervalSince(current.started) < doublePressWindow {
            cancel(sound: false)
            return injector.pressReturn()
        }
        if dictating { return stop(send: kind.canBeSent) }
        if let delivery = lastDelivery, !delivery.done { return delivery.send = true }
        if settings.commandModeOn { start(.command) } else { injector.pressReturn() }
    }

    func start(_ kind: DictationKind = .text) {
        guard !dictating else { return }
        editWatcher?.newDictation()  // the last dictation's watch ends on what it has; no read here
        let setup = settings.setup
        guard let engine = makeEngine(setup) else {
            overlay.show(.plain("Add your cloud API key in Settings to use \(setup.title)", seconds: 4))
            return onMissingKey(setup)
        }
        // A command-line change since the last dictation counts (the file is only read if it changed).
        vocabulary.reloadIfChanged()
        let terms = kind.usesVocabulary ? vocabulary.vocabulary(enabled: settings.vocabularyEnabled) : .none
        // A command's words, so a short one isn't misheard; plain dictation gets your terms, if
        // that's on and the engine can take them.
        engine.context = kind == .command ? commandMode.speechContext() : speechHint(terms, setup: setup)
        if kind == .command { commandMode.prepare(model: settings.commandDecider, apiKey: settings.openRouterKey ?? "") }
        // Load the polish model while you speak instead of after you stop.
        let polisher = settings.polishEnabled && kind.polishes ? makePolish(setup, terms) : nil
        polisher?.prepare()
        let archive = settings.keepRecordings ? kind.archive(in: archive) : nil
        let note = archive.map { _ in RecordingNote(polishModel: polisher?.backend.name) }
        engine.archive = archive
        engine.note = note
        current = Dictation(kind: kind, engine: engine, setup: setup, polisher: polisher, vocabulary: terms, note: note, started: Date())
        setDictating(true)
        let mics = pickMics(settings.microphoneUID, settings.intelligentMicSelection)
        let mic = mics?.chosen
        // A Bluetooth mic takes about a second to send audio: the pill shows the wait, and the start
        // sound waits for it too, so it means "talk now".
        let warmingUp = mic?.isBluetooth == true
        overlay.showListening(micName: mic?.name, warmingUp: warmingUp, command: kind == .command)
        cuePending = warmingUp
        if !warmingUp { startCue() }
        engine.start(
            mics: mics,
            onLevel: { [weak self] level in
                guard self?.dictating == true else { return }
                self?.overlay.setLevel(level)
            },
            onMic: { [weak self] event in
                guard let self, self.dictating else { return }
                self.micEvent(event)
            },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    guard self?.dictating == true else { return }
                    self?.overlay.show(.plain(message))
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

    /// Your terms as the speech model's context words: only with Hint the on-device speech model on,
    /// and only for an on-device engine (the cloud transcription endpoint takes no prompt).
    private func speechHint(_ terms: Vocabulary, setup: DictationSetup) -> SpeechContext {
        guard settings.vocabularySpeechHint, !setup.isCloud, !terms.isEmpty else { return .none }
        return SpeechContext(words: terms.speechWords)
    }

    /// The mic went live, went silent, or a better one took over: the pill shows it, and the start
    /// cue that waited for a warming-up mic plays now.
    private func micEvent(_ event: MicEvent) {
        switch event {
        case .live:
            if cuePending { cuePending = false; startCue() }
            overlay.micLive()
        case .noAudio:
            overlay.micSilent()
        case .switched(let device):
            // Mid-sentence, so no start sound: just mute, if that's on.
            if cuePending { cuePending = false; startCue(sound: false) }
            overlay.micSwitched(to: device.name)
            settings.microphoneUID = device.uid  // the next dictation starts on it
        }
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
        guard let dictation = endDictation() else {  // nothing started, so nothing is coming
            overlay.hideUnlessMessage()
            return onIdle()
        }
        if settings.interactionSounds { InteractionSound.stop.play() }
        let duration = Date().timeIntervalSince(dictation.started)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        finishing += 1
        let delivery = Delivery(send: send)
        let kind = dictation.kind
        // Where the text goes, saved now in case you move on before it arrives.
        let target = kind == .text && settings.pasteWhereDictated ? goBack.current() : nil
        if kind.canBeSent { lastDelivery = delivery }
        // Cloud models transcribe after you stop: keep the pill up ("working") until text arrives.
        // A command keeps it up until it has run.
        let batch = dictation.engine.isBatch || kind.waitsInThePill
        if batch { overlay.showProcessing() } else { overlay.hideUnlessMessage() }
        // A new dictation may start before this one is delivered: everything below is this one's.
        dictation.engine.stop(completion: { [weak self] text in
            let transcribed = ProcessInfo.processInfo.systemUptime - stoppedAt
            let transcribedBy = dictation.engine.lastAnswer
            dictation.note?.transcribed(seconds: transcribed)
            guard let self else { return }
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case .command:
                self.runCommand(raw, delivery: delivery)
            case .text:
                // With polish to come, the pill stays up until it's done: hiding it here and showing it
                // again for the polish made it blink.
                let polishing = dictation.polisher != nil && !raw.isEmpty
                if batch && !polishing { self.overlay.hideUnlessMessage() }
                self.insights.record(text: raw, duration: duration)
                self.deliver(raw, from: dictation, duration: duration, transcribed: transcribed, transcribedBy: transcribedBy,
                             target: target, delivery: delivery)
            }
        }, failure: { [weak self] message in
            dictation.note?.transcribed(seconds: ProcessInfo.processInfo.systemUptime - stoppedAt)
            self?.overlay.show(.plain(message, seconds: 5))
            self?.finished(delivery)
        })
    }

    /// The dictation in progress is over (stopped or cancelled): no longer dictating, no auto-stop,
    /// output unmuted. What it was, for stop to finish; nil if there was none.
    private func endDictation() -> Dictation? {
        setDictating(false)
        autoStop?.cancel()
        autoStop = nil
        muter.restore()
        defer { current = nil }
        return current
    }

    /// `sound: false` for a cancel you didn't ask for as such (Enter double-clicked).
    func cancel(sound: Bool = true) {
        guard dictating else { return }
        endDictation()?.engine.cancel()
        overlay.hide()
        if sound && settings.interactionSounds { InteractionSound.cancel.play() }
        onIdle()
    }

    /// Picks and runs the command `said` asks for, then shows how it went.
    private func runCommand(_ said: String, delivery: Delivery) {
        // Decided on this Mac, a command needs no key (only "create" does, and says so).
        guard !said.isEmpty, let key = settings.openRouterKey ?? (settings.localCommandDecider ? "" : nil) else {
            overlay.hideUnlessMessage()
            return finished(delivery)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let run = await self.commandMode.handle(said, apiKey: key, model: self.settings.commandDecider)
            if !self.dictating { self.overlay.show(run.message) }  // a new dictation's pill stays
            self.finished(delivery)
        }
    }

    private func pressReturnSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + sendDelay) { [injector] in injector.pressReturn() }
    }

    /// A plain paste: where it went and what went in (the space put in front included).
    private typealias Pasted = (spot: TextSpot, text: String)

    /// Pastes `text`, then presses Return if it's being sent. If you've moved on from `target`, `GoBack`
    /// takes it there instead (nothing's pasted if it can't); `done` runs once it's all over, with the
    /// plain paste (nil when it went through `GoBack` or didn't happen).
    private func type(_ text: String, to target: TextSpot?, delivery: Delivery, done: @escaping (Pasted?) -> Void) {
        let here = goBack.current()  // asked once: for whether you moved on, and for the paste
        guard let target, !target.isSame(as: here) else {
            let pasted = injector.inject(text, in: here?.field)
            if delivery.send { pressReturnSoon() }
            return done(here.flatMap { spot in pasted.map { (spot, $0) } })
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.goBack.sendDelay = self.sendDelay
            if case .lost(let app) = await self.goBack.deliver(text, to: target, send: { delivery.send }) {
                self.overlay.show(.plain("Couldn't get back to \(app): the text is on the clipboard", seconds: 5))
            }
            done(nil)
        }
    }

    /// Replaces your terms, polishes (if on), replaces again, pastes, then saves: History, the kept
    /// recording's note, and how often each term fired, all after the paste; then arms the edit
    /// watcher (*Learn from my edits*) for a plain paste that isn't sent.
    private func deliver(_ raw: String, from dictation: Dictation, duration: TimeInterval,
                         transcribed: TimeInterval, transcribedBy: ModelAnswer?, target: TextSpot?, delivery: Delivery) {
        guard !raw.isEmpty else { return finished(delivery) }
        let setup = dictation.setup, note = dictation.note, terms = dictation.vocabulary
        // Before polish, so a polish that fails, comes back empty or runs out of time still has them.
        let replaced = terms.apply(raw)
        /// Pastes `text`, then saves it; `polish`: how long polish took and which model answered.
        func paste(_ text: String, uses: [UUID: Int], polish: (seconds: Double, by: ModelAnswer?, error: String?)?) {
            type(text, to: target, delivery: delivery) { [weak self] pasted in
                guard let self else { return }
                // After typing it, so saving it (History rewrites its whole file) adds nothing to your wait.
                let entry = self.history.add(text: text, duration: duration, raw: raw, setup: setup.id,
                                             prompt: polish == nil ? nil : setup.prompt,
                                             transcribeSeconds: transcribed, polishSeconds: polish?.seconds,
                                             transcribedBy: transcribedBy, polishedBy: polish?.by)
                if let polish { note?.polished(text, seconds: polish.seconds, error: polish.error) }
                self.vocabulary.recordUses(uses)
                // Sent text is gone from the box; text taken back by GoBack isn't where you are; one not
                // in History has nowhere to keep a capture.
                if let pasted, let entry, !delivery.send {
                    self.editWatcher?.arm(spot: pasted.spot, pasted: pasted.text, text: text, entry: entry)
                }
                self.finished(delivery)
            }
        }
        guard let polisher = dictation.polisher else { return paste(replaced.text, uses: replaced.uses, polish: nil) }
        overlay.showProcessing()
        let started = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let (polished, error, polishedBy) = await polisher.polishReporting(replaced.text)
            let seconds = ProcessInfo.processInfo.systemUptime - started
            overlay.hide()
            // Again after polish: variants are learned from polished text, and polish can write one back.
            let final = terms.apply(polished)
            paste(final.text, uses: replaced.uses.merging(final.uses, uniquingKeysWith: +), polish: (seconds, polishedBy, error))
        }
    }
}
